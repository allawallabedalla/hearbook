"""Background genre lookups after a scan (docs/ARCHITEKTUR.md section 3.7).

Shortly after startup and after every scan (initial, periodic, manual)
`GenreRefresher.trigger()` starts one background thread, outside
`scan_lock`, that looks up every book whose genre is still unknown: genre
NULL, source not 'manual', and never checked or last checked at least
RECHECK_AFTER_S ago. A manual genre is never overwritten, not even by a
lookup that was already in flight when the genre was set, and a result
for a title/author/ISBN that changed meanwhile is dropped (the UPDATE
itself checks both).

Every pass that has work logs at INFO: how many books are due, one line
per book with its result, and a summary.
"""

from __future__ import annotations

import logging
import sqlite3
import threading
import time
from collections.abc import Callable
from pathlib import Path

from . import db, genre_lookup
from .genres import GENRES

logger = logging.getLogger(__name__)

RECHECK_AFTER_S = 7 * 24 * 60 * 60

AUTO_SOURCES = frozenset({"dnb", "google", "openlibrary"})

# (title, author, isbn) -> (genre, source) or None
Lookup = Callable[[str | None, str | None, str | None], tuple[str, str] | None]


_DUE = """
    genre IS NULL
    AND genre_source IS NOT 'manual'
    AND (genre_checked_at IS NULL OR genre_checked_at <= ?)
"""


def next_candidate(conn: sqlite3.Connection, now_s: int) -> sqlite3.Row | None:
    """The next book due for a lookup: never-checked books first, then the
    longest-unchecked ones."""
    return conn.execute(
        f"""
        SELECT book_id, title, author, isbn FROM books
        WHERE {_DUE}
        ORDER BY genre_checked_at IS NOT NULL, genre_checked_at, created_at, book_id
        LIMIT 1
        """,
        (now_s - RECHECK_AFTER_S,),
    ).fetchone()


def due_counts(conn: sqlite3.Connection, now_s: int) -> tuple[int, int]:
    """(books due now, books without genre waiting for their recheck)."""
    due = conn.execute(
        f"SELECT COUNT(*) FROM books WHERE {_DUE}", (now_s - RECHECK_AFTER_S,)
    ).fetchone()[0]
    waiting = conn.execute(
        "SELECT COUNT(*) FROM books WHERE genre IS NULL AND genre_source IS NOT 'manual' "
        "AND genre_checked_at > ?",
        (now_s - RECHECK_AFTER_S,),
    ).fetchone()[0]
    return due, waiting


def record_result(
    conn: sqlite3.Connection,
    book: sqlite3.Row,
    result: tuple[str, str] | None,
    now_s: int,
) -> bool:
    """Store a lookup result (or just the check time) unless the book got a
    manual genre, or a new title/author/ISBN, in the meantime. Returns
    whether it was stored."""
    if result is not None:
        genre, source = result
        if genre not in GENRES or source not in AUTO_SOURCES:
            logger.warning("genre lookup: ignoring unexpected result %r", result)
            result = None
    unchanged = (
        "WHERE book_id = ? AND genre_source IS NOT 'manual' "
        "AND title IS ? AND author IS ? AND isbn IS ?"
    )
    key = (book["book_id"], book["title"], book["author"], book["isbn"])
    if result is None:
        cur = conn.execute(f"UPDATE books SET genre_checked_at = ? {unchanged}", (now_s, *key))
    else:
        cur = conn.execute(
            f"UPDATE books SET genre = ?, genre_source = ?, genre_checked_at = ? {unchanged}",
            (result[0], result[1], now_s, *key),
        )
    return cur.rowcount > 0


def _describe(book: sqlite3.Row) -> str:
    text = f"'{book['title']}' / '{book['author'] or '?'}'"
    if book["isbn"]:
        text += f" (ISBN {book['isbn']})"
    return text


def run_genre_pass(
    db_path: Path,
    lookup: Lookup,
    *,
    now: Callable[[], float] = time.time,
    stop_event: threading.Event | None = None,
    log_idle: bool = False,
) -> int:
    """Look up due books one at a time until none is left (books added by a
    scan while this runs are picked up too). Returns how many were looked
    up. Stops early, without marking the book checked, when no catalog is
    reachable; the next scan tries again. `log_idle` logs the start line
    at INFO even when nothing is due (the first pass after startup)."""
    looked_up = found = 0
    started = time.monotonic()
    conn = db.connect(db_path)
    try:
        due, waiting = due_counts(conn, int(now()))
        logger.log(
            logging.INFO if due or log_idle else logging.DEBUG,
            "genre lookup: %d books due (%d more without genre wait for their weekly recheck)",
            due,
            waiting,
        )
        while stop_event is None or not stop_event.is_set():
            row = next_candidate(conn, int(now()))
            if row is None:
                break
            try:
                result = lookup(row["title"], row["author"], row["isbn"])
            except genre_lookup.LookupUnavailable:
                logger.info(
                    "genre lookup: no catalog reachable, stopping; next try after the next scan"
                )
                break
            except Exception:
                logger.exception("genre lookup failed for book %s", row["book_id"])
                result = None
            stored = record_result(conn, row, result, int(now()))
            conn.commit()
            looked_up += 1
            if not stored:
                logger.info("genre lookup: %s changed meanwhile, result dropped", _describe(row))
            elif result is None:
                logger.info("genre lookup: %s → nichts gefunden", _describe(row))
            else:
                found += 1
                logger.info("genre lookup: %s → %s (%s)", _describe(row), result[0], result[1])
    finally:
        conn.close()
    if looked_up:
        logger.info(
            "genre lookup done: %d books, %d genres found, %d without result, %.0f s",
            looked_up,
            found,
            looked_up - found,
            time.monotonic() - started,
        )
    return looked_up


class GenreRefresher:
    """Runs run_genre_pass() on a background thread, at most one at a time.
    A trigger while a pass is running makes that pass go around once more
    instead of starting a second thread."""

    def __init__(
        self,
        db_path: Path,
        *,
        enabled: bool,
        lookup: Lookup | None = None,
        now: Callable[[], float] = time.time,
    ) -> None:
        self._db_path = db_path
        self._enabled = enabled
        # None: a fresh genre_lookup.CatalogLookup per pass.
        self._lookup = lookup
        self._now = now
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._running = False
        self._again = False
        self._thread: threading.Thread | None = None
        self._passes = 0

    @property
    def enabled(self) -> bool:
        return self._enabled

    def trigger(self) -> threading.Thread | None:
        """Start (or re-arm) a pass. Returns the worker thread, or None when
        disabled or stopped. Never blocks on the lookup itself."""
        if not self._enabled or self._stop.is_set():
            return None
        with self._lock:
            if self._running:
                self._again = True
                return self._thread
            self._running = True
            self._again = False
            self._thread = threading.Thread(
                target=self._run, daemon=True, name="faden-genre-lookup"
            )
            self._thread.start()
            return self._thread

    def _run(self) -> None:
        while True:
            lookup = self._lookup if self._lookup is not None else genre_lookup.CatalogLookup()
            try:
                run_genre_pass(
                    self._db_path,
                    lookup,
                    now=self._now,
                    stop_event=self._stop,
                    log_idle=self._passes == 0,
                )
            except Exception:
                logger.exception("genre lookup pass failed")
            self._passes += 1
            with self._lock:
                if not self._again or self._stop.is_set():
                    self._running = False
                    return
                self._again = False

    def join(self, timeout: float | None = None) -> None:
        """Wait for the current pass (if any) to finish."""
        thread = self._thread
        if thread is not None:
            thread.join(timeout=timeout)

    def stop(self, timeout: float = 5.0) -> None:
        self._stop.set()
        self.join(timeout)
