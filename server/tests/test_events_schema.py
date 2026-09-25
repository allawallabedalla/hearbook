"""Tests for event schema validation (docs/ARCHITEKTUR.md section 5) and the
skew check (section 6). Pure, no DB/HTTP involved."""

from __future__ import annotations

import copy

import pytest

from faden_server.events import MAX_DATA_BYTES, EventValidationError, is_skewed, validate_event

VALID_EVENT = {
    "event_id": "018f2f3a-0000-7000-8000-000000000001",
    "device_id": "018f2f3a-0000-7000-8000-000000000002",
    "session_id": "018f2f3a-0000-7000-8000-000000000003",
    "book_id": "018f2f3a-0000-7000-8000-000000000004",
    "manifest_id": "a3f5c9",
    "type": "PLAY",
    "file_hash": "deadbeef",
    "offset_ms": 12345,
    "hlc": {"pt": 1700000000000, "c": 0},
    "wall_ms": 1700000000000,
    "tz_min": 120,
    "source": "ui",
    "data": {},
}


def test_valid_event_passes():
    validate_event(VALID_EVENT)  # must not raise


@pytest.mark.parametrize(
    "field,value",
    [
        ("event_id", "not-a-uuid"),
        ("device_id", "not-a-uuid"),
        ("session_id", ""),
        ("book_id", 123),
        ("manifest_id", "not hex!"),
        ("file_hash", ""),
        ("type", "NOT_A_TYPE"),
        ("source", "carrier-pigeon"),
        ("offset_ms", -1),
        ("offset_ms", "12"),
        ("wall_ms", -5),
        ("tz_min", "120"),
        ("data", "not an object"),
    ],
)
def test_invalid_field_rejected(field, value):
    body = copy.deepcopy(VALID_EVENT)
    body[field] = value
    with pytest.raises(EventValidationError):
        validate_event(body)


@pytest.mark.parametrize("field", ["event_id", "device_id", "hlc", "type"])
def test_missing_field_rejected(field):
    body = copy.deepcopy(VALID_EVENT)
    del body[field]
    with pytest.raises(EventValidationError):
        validate_event(body)


def test_missing_hlc_subfield_rejected():
    body = copy.deepcopy(VALID_EVENT)
    del body["hlc"]["c"]
    with pytest.raises(EventValidationError):
        validate_event(body)


def test_data_field_optional():
    body = copy.deepcopy(VALID_EVENT)
    del body["data"]
    validate_event(body)  # must not raise; data defaults to {}


def test_all_event_types_accepted():
    for t in (
        "PLAY",
        "SEEK",
        "RESUME",
        "UNDO",
        "HEARTBEAT",
        "PAUSE",
        "AWAKE",
        "SLEEP_HINT",
        "PROBE",
        "FINISHED",
    ):
        body = copy.deepcopy(VALID_EVENT)
        body["type"] = t
        validate_event(body)


def test_body_must_be_object():
    with pytest.raises(EventValidationError):
        validate_event(["not", "a", "dict"])


# --- data size cap -------------------------------------------------------


def test_data_within_cap_accepted():
    body = copy.deepcopy(VALID_EVENT)
    # leave headroom for JSON quoting/braces so the serialized size stays
    # comfortably under the cap.
    body["data"] = {"note": "x" * (MAX_DATA_BYTES - 100)}
    validate_event(body)  # must not raise


def test_data_over_cap_rejected():
    body = copy.deepcopy(VALID_EVENT)
    body["data"] = {"note": "x" * MAX_DATA_BYTES}
    with pytest.raises(EventValidationError):
        validate_event(body)


# --- skew --------------------------------------------------------------


def test_is_skewed_false_within_tolerance():
    server_now_ms = 1_700_000_000_000
    assert is_skewed(server_now_ms + 5 * 60 * 1000, server_now_ms) is False


def test_is_skewed_true_beyond_tolerance():
    server_now_ms = 1_700_000_000_000
    assert is_skewed(server_now_ms + 11 * 60 * 1000, server_now_ms) is True


def test_is_skewed_boundary_exactly_ten_minutes_not_flagged():
    server_now_ms = 1_700_000_000_000
    assert is_skewed(server_now_ms + 10 * 60 * 1000, server_now_ms) is False
