"""Tests for POST/GET /api/v1/events per docs/ARCHITEKTUR.md section 6."""

from __future__ import annotations

import time
import uuid

import pytest
from fastapi.testclient import TestClient

from faden_server.api import create_app
from faden_server.config import Settings
from faden_server.events import PUSH_LIMIT

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


@pytest.fixture
def client(settings):
    return TestClient(create_app(settings))


def make_event(*, seq_hint: int = 0, pt: int | None = None, **overrides) -> dict:
    """A valid event body per section 5; overrides win."""
    now_ms = pt if pt is not None else int(time.time() * 1000) + seq_hint
    event = {
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
    event.update(overrides)
    return event


# --- auth --------------------------------------------------------------


def test_events_require_auth(client):
    resp = client.post("/api/v1/events", json=[])
    assert resp.status_code == 401
    resp = client.get("/api/v1/events")
    assert resp.status_code == 401


# --- push: validation ----------------------------------------------------


def test_push_reports_invalid_event_instead_of_422(client, auth_headers):
    """A well-formed request body containing one invalid event is not
    rejected wholesale (a device would otherwise retry the same batch
    forever and never sync again); it is reported per-event instead."""
    bad = make_event()
    bad["type"] = "NOT_A_TYPE"
    resp = client.post("/api/v1/events", json=[bad], headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["accepted"] == 0
    assert body["duplicates"] == 0
    assert body["max_seq"] is None
    assert body["rejected"] == [
        {"index": 0, "event_id": bad["event_id"], "error": body["rejected"][0]["error"]}
    ]
    assert "type" in body["rejected"][0]["error"]

    # and nothing was stored
    pulled = client.get("/api/v1/events", headers=auth_headers).json()
    assert pulled["events"] == []


def test_push_rejected_event_id_null_when_not_a_string(client, auth_headers):
    bad = make_event()
    bad["event_id"] = 12345  # not a string, so it fails the UUID check too
    resp = client.post("/api/v1/events", json=[bad], headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json()["rejected"][0]["event_id"] is None


def test_push_mixed_valid_and_invalid_batch_stores_the_valid_ones(client, auth_headers):
    good1 = make_event(seq_hint=1)
    bad = make_event(seq_hint=2)
    bad["type"] = "NOT_A_TYPE"
    good2 = make_event(seq_hint=3)

    resp = client.post("/api/v1/events", json=[good1, bad, good2], headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["accepted"] == 2
    assert body["duplicates"] == 0
    assert len(body["rejected"]) == 1
    assert body["rejected"][0] == {
        "index": 1,
        "event_id": bad["event_id"],
        "error": body["rejected"][0]["error"],
    }
    assert body["max_seq"] is not None

    pulled = client.get("/api/v1/events", headers=auth_headers).json()
    pulled_ids = {e["event_id"] for e in pulled["events"]}
    assert pulled_ids == {good1["event_id"], good2["event_id"]}


def test_push_rejects_data_payload_over_4kb(client, auth_headers):
    bad = make_event(data={"blob": "x" * 5000})
    resp = client.post("/api/v1/events", json=[bad], headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["accepted"] == 0
    assert len(body["rejected"]) == 1
    assert body["rejected"][0]["index"] == 0


def test_push_rejects_more_than_limit(client, auth_headers):
    events = [make_event(seq_hint=i) for i in range(PUSH_LIMIT + 1)]
    resp = client.post("/api/v1/events", json=events, headers=auth_headers)
    assert resp.status_code == 422


# --- push: acceptance and idempotency ------------------------------------


def test_push_accepts_events_and_reports_counts(client, auth_headers):
    events = [make_event(seq_hint=i) for i in range(5)]
    resp = client.post("/api/v1/events", json=events, headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["accepted"] == 5
    assert body["duplicates"] == 0
    assert body["max_seq"] == 5


def test_push_duplicate_event_id_is_ignored(client, auth_headers):
    event = make_event()
    resp1 = client.post("/api/v1/events", json=[event], headers=auth_headers)
    assert resp1.json() == {"accepted": 1, "duplicates": 0, "rejected": [], "max_seq": 1}

    resp2 = client.post("/api/v1/events", json=[event], headers=auth_headers)
    assert resp2.json() == {"accepted": 0, "duplicates": 1, "rejected": [], "max_seq": 1}

    # only one row landed in the pull, not two
    pulled = client.get("/api/v1/events", headers=auth_headers).json()
    assert len(pulled["events"]) == 1


def test_push_mixed_new_and_duplicate(client, auth_headers):
    e1 = make_event(seq_hint=1)
    e2 = make_event(seq_hint=2)
    first = client.post("/api/v1/events", json=[e1], headers=auth_headers).json()

    resp = client.post("/api/v1/events", json=[e1, e2], headers=auth_headers)
    body = resp.json()
    assert body["accepted"] == 1
    assert body["duplicates"] == 1
    # seq is monotonic but not necessarily gapless across ignored duplicate
    # inserts (an AUTOINCREMENT/INSERT OR IGNORE quirk of SQLite); e2's seq
    # must simply be higher than e1's.
    assert body["max_seq"] > first["max_seq"]


def test_events_are_committed_before_response(client, auth_headers, settings):
    """Invariant 3: the transaction is committed before the push response is
    returned, so a pull right afterwards (even a fresh connection) sees it."""
    event = make_event()
    resp = client.post("/api/v1/events", json=[event], headers=auth_headers)
    assert resp.status_code == 200

    pulled = client.get("/api/v1/events", headers=auth_headers).json()
    assert pulled["events"][0]["event_id"] == event["event_id"]


# --- pull: ordering and cursor/paging -------------------------------------


def test_pull_returns_events_in_seq_order(client, auth_headers):
    events = [make_event(seq_hint=i) for i in range(10)]
    client.post("/api/v1/events", json=events, headers=auth_headers)

    resp = client.get("/api/v1/events", headers=auth_headers)
    body = resp.json()
    assert body["has_more"] is False
    seqs = [e["seq"] for e in body["events"]]
    assert seqs == sorted(seqs)
    assert seqs == list(range(1, 11))
    event_ids = [e["event_id"] for e in body["events"]]
    assert event_ids == [e["event_id"] for e in events]


def test_pull_since_cursor_excludes_already_seen(client, auth_headers):
    events = [make_event(seq_hint=i) for i in range(5)]
    client.post("/api/v1/events", json=events, headers=auth_headers)

    resp = client.get("/api/v1/events?since=3", headers=auth_headers)
    body = resp.json()
    seqs = [e["seq"] for e in body["events"]]
    assert seqs == [4, 5]


def test_pull_paging_over_1000_events(client, auth_headers):
    total = 1000
    batch_size = PUSH_LIMIT
    all_ids = []
    for start in range(0, total, batch_size):
        batch = [make_event(seq_hint=i) for i in range(start, start + batch_size)]
        resp = client.post("/api/v1/events", json=batch, headers=auth_headers)
        assert resp.status_code == 200
        all_ids.extend(e["event_id"] for e in batch)

    cursor = 0
    pulled_ids: list[str] = []
    pages = 0
    while True:
        resp = client.get(f"/api/v1/events?since={cursor}&limit=250", headers=auth_headers)
        body = resp.json()
        pulled_ids.extend(e["event_id"] for e in body["events"])
        pages += 1
        if not body["events"]:
            break
        cursor = body["events"][-1]["seq"]
        if not body["has_more"]:
            break

    assert pulled_ids == all_ids
    assert pages == total // 250


def test_pull_limit_bounds(client, auth_headers):
    resp = client.get("/api/v1/events?limit=0", headers=auth_headers)
    assert resp.status_code == 422
    resp = client.get(f"/api/v1/events?limit={PUSH_LIMIT + 1}", headers=auth_headers)
    assert resp.status_code == 422


def test_pull_default_limit_matches_push_cap(client, auth_headers):
    events = [make_event(seq_hint=i) for i in range(PUSH_LIMIT + 10)]
    for start in (0, PUSH_LIMIT):
        batch = events[start : start + PUSH_LIMIT]
        client.post("/api/v1/events", json=batch, headers=auth_headers)

    resp = client.get("/api/v1/events", headers=auth_headers)
    body = resp.json()
    assert len(body["events"]) == PUSH_LIMIT
    assert body["has_more"] is True


# --- skew ------------------------------------------------------------------


def test_skewed_event_flagged(client, auth_headers, caplog):
    far_future_pt = int(time.time() * 1000) + 20 * 60 * 1000  # 20 min ahead
    event = make_event(pt=far_future_pt)
    with caplog.at_level("WARNING"):
        resp = client.post("/api/v1/events", json=[event], headers=auth_headers)
    assert resp.status_code == 200

    pulled = client.get("/api/v1/events", headers=auth_headers).json()
    assert pulled["events"][0]["skew_flag"] is True
    assert any("skew" in rec.message.lower() for rec in caplog.records)


def test_non_skewed_event_not_flagged(client, auth_headers):
    event = make_event()
    client.post("/api/v1/events", json=[event], headers=auth_headers)
    pulled = client.get("/api/v1/events", headers=auth_headers).json()
    assert pulled["events"][0]["skew_flag"] is False


# --- events are never mutated or deleted (invariant 2 / section 6) --------


def test_events_never_deleted_no_delete_endpoint(client, auth_headers):
    event = make_event()
    client.post("/api/v1/events", json=[event], headers=auth_headers)
    resp = client.delete("/api/v1/events", headers=auth_headers)
    assert resp.status_code in (404, 405)


@pytest.mark.slow
def test_pull_paging_over_100_000_events(client, auth_headers):
    """Slow integration test: 100k events pushed in 500-event batches, then
    pulled back fully via cursor paging, in order, none lost or duplicated."""
    total = 100_000
    batch_size = PUSH_LIMIT
    for start in range(0, total, batch_size):
        batch = [make_event(seq_hint=i) for i in range(start, start + batch_size)]
        resp = client.post("/api/v1/events", json=batch, headers=auth_headers)
        assert resp.status_code == 200
        assert resp.json()["accepted"] == batch_size

    cursor = 0
    pulled = 0
    last_seq = 0
    while True:
        resp = client.get(f"/api/v1/events?since={cursor}&limit={PUSH_LIMIT}", headers=auth_headers)
        body = resp.json()
        for e in body["events"]:
            assert e["seq"] > last_seq
            last_seq = e["seq"]
        pulled += len(body["events"])
        if not body["has_more"]:
            break
        cursor = last_seq

    assert pulled == total
    assert last_seq == total
