"""Background genre lookups after a scan (docs/ARCHITEKTUR.md section 3.7).

After every scan (initial, periodic, manual) `GenreRefresher.trigger()`
starts one background thread, outside `scan_lock`, that looks up every book
whose genre is still unknown: genre NULL, source not 'manual', and never
checked or last checked at least RECHECK_AFTER_S ago. A manual genre is
never overwritten, not even by a lookup that was already in flight when
the genre was set (the UPDATE itself checks the source).
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

Lookup = Callable[[str | None, str | None], tuple[str, str] | None]


def _default_lookup(title: str | None, author: str | None) -> tuple[str, str] | None:
    # Resolved at call time, so tests can patch genre_lookup.lookup.
    return genre_lookup.lookup(title, author)


def next_candidate(conn: sqlite3.Connection, now_s: int) -> sqlite3.Row | None:
    """The next book due for a lookup: never-checked books first, then the
    longest-unchecked ones."""
    return conn.execute(
        """
        SELECT book_id, title, author FROM books
        WHERE genre IS NULL
          AND genre_source IS NOT 'manual'
          AND (genre_checked_at IS NULL OR genre_checked_at <= ?)
        ORDER BY genre_checked_at IS NOT NULL, genre_checked_at, created_at, book_id
        LIMIT 1
        """,
        (now_s - RECHECK_AFTER_S,),
    ).fetchone()


def record_result(
    conn: sqlite3.Connection,
    book_id: str,
    result: tuple[str, str] | None,
    now_s: int,
) -> None:
    """Store a lookup result (or just the check time) unless the book got a
    manual genre in the meantime."""
    if result is not None:
        genre, source = result
        if genre not in GENRES or source not in AUTO_SOURCES:
            logger.warning("genre lookup: ignoring unexpected result %r", result)
            result = None
    if result is None:
        conn.execute(
            "UPDATE books SET genre_checked_at = ? "
            "WHERE book_id = ? AND genre_source IS NOT 'manual'",
            (now_s, book_id),
        )
    else:
        conn.execute(
            "UPDATE books SET genre = ?, genre_source = ?, genre_checked_at = ? "
            "WHERE book_id = ? AND genre_source IS NOT 'manual'",
            (result[0], result[1], now_s, book_id),
        )


def run_genre_pass(
    db_path: Path,
    lookup: Lookup,
    *,
    now: Callable[[], float] = time.time,
    stop_event: threading.Event | None = None,
) -> int:
    """Look up due books one at a time until none is left (books added by a
    scan while this runs are picked up too). Returns how many were looked
    up. Stops early, without marking the book checked, when no catalog is
    reachable; the next scan tries again."""
    looked_up = 0
    conn = db.connect(db_path)
    try:
        while stop_event is None or not stop_event.is_set():
            row = next_candidate(conn, int(now()))
            if row is None:
                break
            try:
                result = lookup(row["title"], row["author"])
            except genre_lookup.LookupUnavailable:
                logger.info("genre lookup: no catalog reachable, retrying after the next scan")
                break
            except Exception:
                logger.exception("genre lookup failed for book %s", row["book_id"])
                result = None
            record_result(conn, row["book_id"], result, int(now()))
            conn.commit()
            looked_up += 1
    finally:
        conn.close()
    if looked_up:
        logger.info("genre lookup: %d books looked up", looked_up)
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
        self._lookup = lookup if lookup is not None else _default_lookup
        self._now = now
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._running = False
        self._again = False
        self._thread: threading.Thread | None = None

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
            try:
                run_genre_pass(self._db_path, self._lookup, now=self._now, stop_event=self._stop)
            except Exception:
                logger.exception("genre lookup pass failed")
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
