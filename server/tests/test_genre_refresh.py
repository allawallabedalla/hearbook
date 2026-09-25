"""Tests for when genres are looked up (docs/ARCHITEKTUR.md section 3.7):
the schema migration, the scheduling rules, FADEN_GENRE_LOOKUP, and that a
failing lookup never affects a scan."""

from __future__ import annotations

import shutil
import sqlite3
import threading
from dataclasses import replace

import pytest
from fastapi.testclient import TestClient

import faden_server.api as api_module
from faden_server import genre_lookup
from faden_server.api import _run_periodic_rescan_tick, create_app
from faden_server.config import Settings, load_settings
from faden_server.db import connect
from faden_server.genre_lookup import LookupUnavailable
from faden_server.genre_refresh import (
    RECHECK_AFTER_S,
    GenreRefresher,
    next_candidate,
    run_genre_pass,
)
from faden_server.genres import BIOGRAFIE, HUMOR, KRIMI
from faden_server.scanner import scan_library

from .conftest import requires_ffmpeg

TOKEN = "test-token-1234567890"
NOW = 1_800_000_000
DAY = 24 * 60 * 60


@pytest.fixture
def settings(tmp_path):
    library = tmp_path / "library"
    library.mkdir()
    return Settings(
        token=TOKEN,
        library=library,
        data=tmp_path / "data",
        port=8787,
        rescan_min=10,
        silence_db=-35,
        silence_s=0.35,
    )


@pytest.fixture
def auth_headers():
    return {"Authorization": f"Bearer {TOKEN}"}


def add_book(db_path, book_id, *, title=None, genre=None, source=None, checked_at=None):
    conn = connect(db_path)
    try:
        conn.execute(
            "INSERT INTO books (book_id, path, title, author, incomplete, created_at, "
            "genre, genre_source, genre_checked_at) VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?)",
            (
                book_id,
                f"/library/{book_id}",
                title or book_id,
                "Autorin",
                f"2026-01-01T00:00:{len(book_id):02d}",
                genre,
                source,
                checked_at,
            ),
        )
        conn.commit()
    finally:
        conn.close()


def book(db_path, book_id) -> sqlite3.Row:
    conn = connect(db_path)
    try:
        return conn.execute(
            "SELECT genre, genre_source, genre_checked_at FROM books WHERE book_id = ?",
            (book_id,),
        ).fetchone()
    finally:
        conn.close()


class RecordingLookup:
    def __init__(self, result=(KRIMI, "dnb")):
        self.result = result
        self.titles: list[str | None] = []

    def __call__(self, title, author):
        self.titles.append(title)
        if isinstance(self.result, BaseException):
            raise self.result
        return self.result


# --- migration ---------------------------------------------------------------


def test_connect_adds_the_genre_columns_to_an_existing_db(tmp_path):
    db_path = tmp_path / "old.db"
    old = sqlite3.connect(db_path)
    old.executescript(
        """
        CREATE TABLE books (
            book_id TEXT PRIMARY KEY, path TEXT NOT NULL, title TEXT, author TEXT,
            incomplete INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL
        );
        INSERT INTO books VALUES ('b1', '/library/b1', 'Mort', 'Pratchett', 0, 'x');
        """
    )
    old.commit()
    old.close()

    conn = connect(db_path)
    conn.close()
    conn = connect(db_path)  # second connect: nothing left to migrate
    try:
        columns = {r["name"] for r in conn.execute("PRAGMA table_info(books)")}
        row = conn.execute("SELECT * FROM books").fetchone()
    finally:
        conn.close()
    assert {"genre", "genre_source", "genre_checked_at"} <= columns
    assert (row["title"], row["genre"], row["genre_source"], row["genre_checked_at"]) == (
        "Mort",
        None,
        None,
        None,
    )


def test_genre_source_is_constrained(tmp_path):
    db_path = tmp_path / "faden.db"
    add_book(db_path, "b1")
    conn = connect(db_path)
    try:
        with pytest.raises(sqlite3.IntegrityError):
            conn.execute("UPDATE books SET genre_source = 'amazon'")
    finally:
        conn.close()


# --- scheduling rules ----------------------------------------------------------


def test_candidates_follow_the_rules(tmp_path):
    db_path = tmp_path / "faden.db"
    add_book(db_path, "never")
    add_book(db_path, "recent", checked_at=NOW - 3 * DAY)
    add_book(db_path, "stale", checked_at=NOW - 8 * DAY)
    add_book(db_path, "exactly7", checked_at=NOW - RECHECK_AFTER_S)
    add_book(db_path, "manual", genre=HUMOR, source="manual", checked_at=NOW - 30 * DAY)
    add_book(db_path, "found", genre=KRIMI, source="dnb", checked_at=NOW - 30 * DAY)

    lookup = RecordingLookup(result=None)
    assert run_genre_pass(db_path, lookup, now=lambda: NOW) == 3
    # never-checked first, then the longest-unchecked
    assert lookup.titles == ["never", "stale", "exactly7"]
    assert book(db_path, "recent")["genre_checked_at"] == NOW - 3 * DAY
    assert book(db_path, "never")["genre_checked_at"] == NOW

    conn = connect(db_path)
    try:
        assert next_candidate(conn, NOW) is None
        # a week later, the unsuccessful ones are due again
        assert next_candidate(conn, NOW + RECHECK_AFTER_S) is not None
    finally:
        conn.close()


def test_a_found_genre_is_stored_with_its_source(tmp_path):
    db_path = tmp_path / "faden.db"
    add_book(db_path, "b1")
    run_genre_pass(db_path, RecordingLookup((BIOGRAFIE, "google")), now=lambda: NOW)
    assert tuple(book(db_path, "b1")) == (BIOGRAFIE, "google", NOW)


def test_manual_genre_is_never_overwritten(tmp_path):
    db_path = tmp_path / "faden.db"
    add_book(db_path, "manual", genre=HUMOR, source="manual", checked_at=NOW - 60 * DAY)
    lookup = RecordingLookup()
    run_genre_pass(db_path, lookup, now=lambda: NOW)
    assert lookup.titles == []
    assert tuple(book(db_path, "manual")) == (HUMOR, "manual", NOW - 60 * DAY)


def test_manual_genre_set_during_a_lookup_wins(tmp_path):
    db_path = tmp_path / "faden.db"
    add_book(db_path, "b1")

    def lookup(title, author):
        # the user picks a genre while the catalog request is in flight
        conn = connect(db_path)
        conn.execute("UPDATE books SET genre = ?, genre_source = 'manual'", (HUMOR,))
        conn.commit()
        conn.close()
        return (KRIMI, "dnb")

    run_genre_pass(db_path, lookup, now=lambda: NOW)
    assert tuple(book(db_path, "b1"))[:2] == (HUMOR, "manual")


def test_unexpected_lookup_results_are_ignored(tmp_path):
    db_path = tmp_path / "faden.db"
    add_book(db_path, "b1")
    add_book(db_path, "b2")
    results = iter([("Horror", "dnb"), (KRIMI, "amazon")])
    run_genre_pass(db_path, lambda t, a: next(results), now=lambda: NOW)
    assert tuple(book(db_path, "b1")) == (None, None, NOW)
    assert tuple(book(db_path, "b2")) == (None, None, NOW)


def test_unreachable_catalogs_stop_the_pass_without_marking(tmp_path):
    db_path = tmp_path / "faden.db"
    add_book(db_path, "b1")
    add_book(db_path, "b2")
    lookup = RecordingLookup(LookupUnavailable("offline"))
    assert run_genre_pass(db_path, lookup, now=lambda: NOW) == 0
    assert len(lookup.titles) == 1
    assert book(db_path, "b1")["genre_checked_at"] is None
    assert book(db_path, "b2")["genre_checked_at"] is None


def test_a_crashing_lookup_marks_the_book_and_goes_on(tmp_path):
    db_path = tmp_path / "faden.db"
    add_book(db_path, "b1")
    add_book(db_path, "b2")
    lookup = RecordingLookup(RuntimeError("bug"))
    assert run_genre_pass(db_path, lookup, now=lambda: NOW) == 2
    assert book(db_path, "b1")["genre_checked_at"] == NOW
    assert book(db_path, "b2")["genre_checked_at"] == NOW


def test_default_lookup_offline_is_unavailable_not_checked(tmp_path):
    """The real lookup with no network (conftest blocks it) must not mark
    books as checked, or they would wait a week after the outage."""
    db_path = tmp_path / "faden.db"
    add_book(db_path, "b1")
    run_genre_pass(db_path, genre_lookup.lookup, now=lambda: NOW)
    assert book(db_path, "b1")["genre_checked_at"] is None


# --- the background refresher ------------------------------------------------


def test_refresher_runs_in_the_background_and_rearms(tmp_path):
    db_path = tmp_path / "faden.db"
    add_book(db_path, "b1")
    started = threading.Event()
    release = threading.Event()
    titles = []

    def slow_lookup(title, author):
        titles.append(title)
        started.set()
        release.wait(timeout=5)
        return (KRIMI, "dnb")

    refresher = GenreRefresher(db_path, enabled=True, lookup=slow_lookup)
    thread = refresher.trigger()
    assert started.wait(timeout=5)
    add_book(db_path, "b2")  # a new book arrives with the next scan...
    assert refresher.trigger() is thread  # ...whose trigger re-arms the pass
    release.set()
    thread.join(timeout=5)
    assert not thread.is_alive()
    assert titles == ["b1", "b2"]
    assert book(db_path, "b2")["genre"] == KRIMI


def test_refresher_disabled_never_looks_up(tmp_path):
    db_path = tmp_path / "faden.db"
    add_book(db_path, "b1")
    lookup = RecordingLookup()
    refresher = GenreRefresher(db_path, enabled=False, lookup=lookup)
    assert refresher.trigger() is None
    assert lookup.titles == []


@pytest.mark.parametrize(
    ("value", "enabled"),
    [(None, True), ("", True), ("1", True), ("true", True), ("0", False), ("off", False)],
)
def test_faden_genre_lookup_env(value, enabled):
    env = {"FADEN_TOKEN": "a" * 32}
    if value is not None:
        env["FADEN_GENRE_LOOKUP"] = value
    assert load_settings(env).genre_lookup is enabled


def test_disabled_via_settings_the_app_never_looks_up(settings, auth_headers):
    lookup = RecordingLookup()
    app = create_app(replace(settings, genre_lookup=False), genre_lookup=lookup)
    client = TestClient(app)
    add_book(settings.db_path, "b1")
    assert client.post("/api/v1/rescan", headers=auth_headers).status_code == 200
    resp = client.put("/api/v1/books/b1/genre", json={"genre": None}, headers=auth_headers)
    assert resp.status_code == 200
    assert lookup.titles == []


# --- scans and lookups ---------------------------------------------------------


def _seed_folder(make_mp3, settings, name="Mort"):
    book_dir = settings.library / name
    book_dir.mkdir()
    p = make_mp3("01.mp3", segments=[("tone", 0.2)])
    shutil.move(str(p), book_dir / "01.mp3")
    return book_dir


@requires_ffmpeg
def test_rescan_answers_before_the_lookup_and_without_holding_the_lock(
    make_mp3, settings, auth_headers
):
    _seed_folder(make_mp3, settings)
    in_lookup = threading.Event()
    release = threading.Event()
    lock_free_during_lookup = []

    app = None

    def blocking_lookup(title, author):
        lock_free_during_lookup.append(not app.state.scan_lock.locked())
        in_lookup.set()
        release.wait(timeout=10)
        return (KRIMI, "dnb")

    app = create_app(settings, genre_lookup=blocking_lookup)
    client = TestClient(app)
    resp = client.post("/api/v1/rescan", headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json()["books_new"] == 1
    assert in_lookup.wait(timeout=5), "lookup never started after the scan"
    assert lock_free_during_lookup == [True]
    book_id = client.get("/api/v1/books", headers=auth_headers).json()[0]["book_id"]
    assert client.get(f"/api/v1/books/{book_id}", headers=auth_headers).json()["genre"] is None

    release.set()
    app.state.genre_refresher.join(timeout=5)
    detail = client.get(f"/api/v1/books/{book_id}", headers=auth_headers).json()
    assert (detail["genre"], detail["genre_source"]) == (KRIMI, "dnb")


@requires_ffmpeg
@pytest.mark.parametrize("failure", [RuntimeError("boom"), LookupUnavailable("offline")])
def test_a_failing_lookup_never_breaks_scanning(make_mp3, settings, auth_headers, failure):
    _seed_folder(make_mp3, settings)
    lookup = RecordingLookup(failure)
    app = create_app(settings, genre_lookup=lookup)
    client = TestClient(app)

    for _ in range(2):
        resp = client.post("/api/v1/rescan", headers=auth_headers)
        assert resp.status_code == 200
        app.state.genre_refresher.join(timeout=5)

    books = client.get("/api/v1/books", headers=auth_headers).json()
    assert [(b["title"], b["genre"], b["status"]) for b in books] == [("Mort", None, "ok")]
    assert lookup.titles  # it was tried


def test_periodic_tick_starts_the_lookup_after_releasing_the_lock(settings, monkeypatch):
    monkeypatch.setattr(api_module, "scan_library", lambda *a, **k: None)
    lock = threading.Lock()
    seen = []
    _run_periodic_rescan_tick(
        scan_lock=lock,
        db_path=settings.db_path,
        effective_library=lambda conn: settings.library,
        noise_db=settings.silence_db,
        silence_s=settings.silence_s,
        after_scan=lambda: seen.append(lock.locked()),
    )
    assert seen == [False]


def test_periodic_tick_skips_the_lookup_when_the_scan_failed(settings, monkeypatch):
    def boom(*a, **k):
        raise RuntimeError("scan failed")

    monkeypatch.setattr(api_module, "scan_library", boom)
    seen = []
    _run_periodic_rescan_tick(
        scan_lock=threading.Lock(),
        db_path=settings.db_path,
        effective_library=lambda conn: settings.library,
        noise_db=settings.silence_db,
        silence_s=settings.silence_s,
        after_scan=lambda: seen.append(1),
    )
    assert seen == []


def test_periodic_tick_survives_a_failing_after_scan_hook(settings, monkeypatch):
    monkeypatch.setattr(api_module, "scan_library", lambda *a, **k: None)

    def boom():
        raise RuntimeError("hook failed")

    lock = threading.Lock()
    _run_periodic_rescan_tick(
        scan_lock=lock,
        db_path=settings.db_path,
        effective_library=lambda conn: settings.library,
        noise_db=settings.silence_db,
        silence_s=settings.silence_s,
        after_scan=boom,
    )
    assert not lock.locked()


@requires_ffmpeg
def test_a_new_title_forgets_the_automatic_genre_but_keeps_a_manual_one(make_mp3, settings):
    book_dir = _seed_folder(make_mp3, settings, name="Mort")
    other_dir = settings.library / "Eric"
    other_dir.mkdir()
    p = make_mp3("02.mp3", segments=[("tone", 0.3)], freq=660)
    shutil.move(str(p), other_dir / "01.mp3")

    conn = connect(settings.db_path)
    try:
        scan_library(conn, library=settings.library, noise_db=-35, silence_s=0.35)
        conn.execute(
            "UPDATE books SET genre = ?, genre_source = 'dnb', genre_checked_at = 1 "
            "WHERE title = 'Mort'",
            (KRIMI,),
        )
        conn.execute(
            "UPDATE books SET genre = ?, genre_source = 'manual', genre_checked_at = 1 "
            "WHERE title = 'Eric'",
            (HUMOR,),
        )
        conn.commit()

        book_dir.rename(settings.library / "Mort (Neuauflage)")
        other_dir.rename(settings.library / "Eric (Neuauflage)")
        scan_library(conn, library=settings.library, noise_db=-35, silence_s=0.35)
        rows = {
            r["title"]: (r["genre"], r["genre_source"], r["genre_checked_at"])
            for r in conn.execute("SELECT * FROM books")
        }
    finally:
        conn.close()
    assert rows == {
        "Mort (Neuauflage)": (None, None, None),
        "Eric (Neuauflage)": (HUMOR, "manual", 1),
    }
