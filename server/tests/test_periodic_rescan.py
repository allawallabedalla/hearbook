"""Tests for the periodic background rescan (docs/ARCHITEKTUR.md section 12):
FADEN_RESCAN_MIN drives a background thread that calls scan_library() on the
same cadence, and under the same app.state.scan_lock, as POST
/api/v1/rescan.
"""

from __future__ import annotations

import shutil
import threading
import time
from dataclasses import replace

import pytest
from fastapi.testclient import TestClient

import faden_server.api as api_module
from faden_server.api import (
    _periodic_rescan_loop,
    _run_periodic_rescan_tick,
    create_app,
)
from faden_server.config import Settings
from faden_server.db import connect

from .conftest import requires_ffmpeg

TOKEN = "test-token-1234567890"


@pytest.fixture
def settings(tmp_path):
    library = tmp_path / "library"
    library.mkdir()
    data = tmp_path / "data"
    return Settings(
        token=TOKEN,
        library=library,
        data=data,
        port=8787,
        rescan_min=10,
        silence_db=-35,
        silence_s=0.35,
    )


# --- _run_periodic_rescan_tick: one tick ------------------------------------


@requires_ffmpeg
def test_tick_scans_the_library_and_releases_the_lock(make_mp3, settings):
    book_dir = settings.library / "Mort"
    book_dir.mkdir()
    p = make_mp3("01.mp3", segments=[("tone", 0.2)])
    shutil.move(str(p), book_dir / "01.mp3")

    lock = threading.Lock()
    _run_periodic_rescan_tick(
        scan_lock=lock,
        db_path=settings.db_path,
        effective_library=lambda conn: settings.library,
        noise_db=settings.silence_db,
        silence_s=settings.silence_s,
    )

    assert not lock.locked()
    conn = connect(settings.db_path)
    try:
        titles = [r["title"] for r in conn.execute("SELECT title FROM books")]
    finally:
        conn.close()
    assert titles == ["Mort"]


def test_tick_skips_without_blocking_when_scan_lock_is_held(settings, monkeypatch):
    called = False

    def fake_scan_library(*args, **kwargs):
        nonlocal called
        called = True

    monkeypatch.setattr(api_module, "scan_library", fake_scan_library)

    lock = threading.Lock()
    lock.acquire()  # simulate a manual scan already running
    try:
        _run_periodic_rescan_tick(
            scan_lock=lock,
            db_path=settings.db_path,
            effective_library=lambda conn: settings.library,
            noise_db=settings.silence_db,
            silence_s=settings.silence_s,
        )
    finally:
        lock.release()

    assert called is False


def test_tick_survives_an_exception_and_still_releases_the_lock(settings, monkeypatch, caplog):
    def boom(*args, **kwargs):
        raise RuntimeError("boom")

    monkeypatch.setattr(api_module, "scan_library", boom)

    lock = threading.Lock()
    with caplog.at_level("ERROR"):
        _run_periodic_rescan_tick(
            scan_lock=lock,
            db_path=settings.db_path,
            effective_library=lambda conn: settings.library,
            noise_db=settings.silence_db,
            silence_s=settings.silence_s,
        )

    assert not lock.locked()
    assert any("periodic rescan" in rec.message.lower() for rec in caplog.records)


# --- _periodic_rescan_loop: scheduling --------------------------------------


def test_loop_runs_an_initial_tick_then_repeats_at_interval():
    stop_event = threading.Event()
    calls: list[float] = []

    def tick():
        calls.append(time.monotonic())
        if len(calls) >= 3:
            stop_event.set()

    _periodic_rescan_loop(stop_event, interval_s=0.05, initial_delay_s=0.01, tick=tick)

    assert len(calls) == 3
    assert calls[1] - calls[0] >= 0.04
    assert calls[2] - calls[1] >= 0.04


def test_loop_never_ticks_if_stopped_during_the_initial_delay():
    stop_event = threading.Event()
    stop_event.set()
    calls: list[int] = []

    _periodic_rescan_loop(
        stop_event, interval_s=999, initial_delay_s=999, tick=lambda: calls.append(1)
    )

    assert calls == []


# --- wiring: FADEN_RESCAN_MIN via the app's lifespan ------------------------


def test_rescan_min_zero_disables_the_periodic_loop(settings, monkeypatch):
    started = []
    monkeypatch.setattr(api_module, "_periodic_rescan_loop", lambda *a, **k: started.append(1))

    disabled = replace(settings, rescan_min=0)
    with TestClient(create_app(disabled)):
        pass

    assert started == []


def test_rescan_min_positive_starts_the_periodic_loop_on_startup_and_stops_on_shutdown(
    settings, monkeypatch
):
    started = threading.Event()
    stopped = threading.Event()

    def fake_loop(stop_event, **kwargs):
        started.set()
        stop_event.wait()  # block until the lifespan asks us to stop
        stopped.set()

    monkeypatch.setattr(api_module, "_periodic_rescan_loop", fake_loop)

    with TestClient(create_app(settings)):  # rescan_min=10 from the fixture
        assert started.wait(timeout=2), "periodic rescan thread never started"

    assert stopped.wait(timeout=2), "periodic rescan thread never stopped"


def test_plain_testclient_use_never_starts_the_background_thread(settings, monkeypatch):
    """Existing TestClient-based tests build a client without `with` and
    never trigger FastAPI's lifespan; make sure that really holds, so they
    do not spawn a slow real scan in the background."""
    started = []
    monkeypatch.setattr(api_module, "_periodic_rescan_loop", lambda *a, **k: started.append(1))

    client = TestClient(create_app(settings))
    client.get("/api/v1/health")

    assert started == []
