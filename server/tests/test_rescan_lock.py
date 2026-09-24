"""Tests that scans are serialized: a concurrent rescan request while one is
already running gets 409, and a slow scan's write lock does not starve a
concurrent event push thanks to PRAGMA busy_timeout (db.py)."""

from __future__ import annotations

import threading
import time
import uuid

import pytest
from fastapi.testclient import TestClient

from faden_server.api import create_app
from faden_server.config import Settings
from faden_server.db import BUSY_TIMEOUT_MS, connect

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


@pytest.fixture
def auth_headers():
    return {"Authorization": f"Bearer {TOKEN}"}


def test_concurrent_rescan_returns_409(settings, auth_headers):
    app = create_app(settings)
    client = TestClient(app)

    # Simulate a scan already in progress without actually running one.
    assert app.state.scan_lock.acquire(blocking=False)
    try:
        resp = client.post("/api/v1/rescan", headers=auth_headers)
        assert resp.status_code == 409
    finally:
        app.state.scan_lock.release()

    # Once the "scan" is done, a rescan works normally again.
    resp = client.post("/api/v1/rescan", headers=auth_headers)
    assert resp.status_code == 200


def make_event() -> dict:
    now_ms = int(time.time() * 1000)
    return {
        "event_id": str(uuid.uuid4()),
        "device_id": str(uuid.uuid4()),
        "session_id": str(uuid.uuid4()),
        "book_id": str(uuid.uuid4()),
        "manifest_id": "a1b2c3",
        "type": "HEARTBEAT",
        "file_hash": "deadbeef",
        "offset_ms": 1000,
        "hlc": {"pt": now_ms, "c": 0},
        "wall_ms": now_ms,
        "tz_min": 60,
        "source": "ui",
        "data": {},
    }


def test_concurrent_event_write_during_long_write_transaction_succeeds(settings, auth_headers):
    """A scan holds one write transaction per book (scanner.scan_library).
    Simulate that with a raw connection holding a write lock past sqlite3's
    5s default busy timeout, and confirm a concurrent POST /api/v1/events on
    a fresh connection still succeeds instead of raising "database is
    locked" -- proving PRAGMA busy_timeout (db.py) is actually in effect.
    """
    assert BUSY_TIMEOUT_MS > 5_000  # sanity: longer than sqlite3's own default

    app = create_app(settings)
    client = TestClient(app)
    # Make sure the schema/db file exist before the blocker opens it.
    client.get("/api/v1/health")

    blocker = connect(settings.db_path)
    blocker.execute("BEGIN IMMEDIATE")
    blocker.execute("INSERT INTO settings (key, value) VALUES ('scan_in_progress', '1')")

    hold_seconds = 6.0  # longer than sqlite3's 5s default timeout

    def release_later():
        time.sleep(hold_seconds)
        blocker.commit()
        blocker.close()

    releaser = threading.Thread(target=release_later)
    releaser.start()
    try:
        started = time.monotonic()
        resp = client.post("/api/v1/events", json=[make_event()], headers=auth_headers)
        elapsed = time.monotonic() - started
    finally:
        releaser.join(timeout=hold_seconds + 5)

    assert resp.status_code == 200
    assert resp.json()["accepted"] == 1
    # It had to wait for the blocker to release the lock, not fail fast.
    assert elapsed >= hold_seconds - 0.5
