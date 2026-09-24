"""Event schema validation and skew detection per docs/ARCHITEKTUR.md
sections 5 and 6.

Pure, no I/O: given a decoded JSON event body, checks it against the shape
from section 5. The server never interprets an event beyond this shape
check (see decision E3, section 13): it is a dumb, append-only store, not
a resolver.
"""

from __future__ import annotations

import json
import uuid

EVENT_TYPES = frozenset(
    {
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
    }
)
SOURCES = frozenset({"ui", "media_button", "timer", "system", "faden"})

SKEW_TOLERANCE_MS = 10 * 60 * 1000  # section 6: hlc.pt > server time + 10 min

PUSH_LIMIT = 500  # section 6: up to 500 events per push/pull request

MAX_DATA_BYTES = 4096  # per-event `data` payload cap (serialized, UTF-8)

_UUID_FIELDS = ("event_id", "device_id", "session_id", "book_id")
_HEX_FIELDS = ("manifest_id", "file_hash")
_NONNEG_INT_FIELDS = ("offset_ms", "wall_ms")


class EventValidationError(ValueError):
    """Raised when an event body does not match the section 5 shape."""


def _is_uuid(value: object) -> bool:
    if not isinstance(value, str):
        return False
    try:
        uuid.UUID(value)
    except ValueError:
        return False
    return True


def _is_hex(value: object) -> bool:
    if not isinstance(value, str) or not value:
        return False
    try:
        int(value, 16)
    except ValueError:
        return False
    return True


def _is_int(value: object) -> bool:
    # bool is a subclass of int in Python; a JSON `true` must not pass.
    return isinstance(value, int) and not isinstance(value, bool)


def validate_event(body: object) -> None:
    """Raise EventValidationError if `body` does not match the event shape
    from docs/ARCHITEKTUR.md section 5."""
    if not isinstance(body, dict):
        raise EventValidationError("event must be a JSON object")

    for field in _UUID_FIELDS:
        if not _is_uuid(body.get(field)):
            raise EventValidationError(f"{field} must be a UUID string")

    for field in _HEX_FIELDS:
        if not _is_hex(body.get(field)):
            raise EventValidationError(f"{field} must be a non-empty hex string")

    event_type = body.get("type")
    if event_type not in EVENT_TYPES:
        raise EventValidationError(f"type must be one of {sorted(EVENT_TYPES)}")

    source = body.get("source")
    if source not in SOURCES:
        raise EventValidationError(f"source must be one of {sorted(SOURCES)}")

    for field in _NONNEG_INT_FIELDS:
        value = body.get(field)
        if not _is_int(value) or value < 0:
            raise EventValidationError(f"{field} must be a non-negative integer")

    tz_min = body.get("tz_min")
    if not _is_int(tz_min):
        raise EventValidationError("tz_min must be an integer")

    hlc = body.get("hlc")
    if not isinstance(hlc, dict):
        raise EventValidationError("hlc must be an object with pt and c")
    pt = hlc.get("pt")
    c = hlc.get("c")
    if not _is_int(pt) or pt < 0:
        raise EventValidationError("hlc.pt must be a non-negative integer")
    if not _is_int(c) or c < 0:
        raise EventValidationError("hlc.c must be a non-negative integer")

    data = body.get("data", {})
    if not isinstance(data, dict):
        raise EventValidationError("data must be an object")
    if len(json.dumps(data).encode("utf-8")) > MAX_DATA_BYTES:
        raise EventValidationError(f"data must be at most {MAX_DATA_BYTES} bytes serialized")


def is_skewed(hlc_pt_ms: int, server_now_ms: int) -> bool:
    """Section 6: an event's hlc.pt more than 10 minutes ahead of the
    server's clock gets skew_flag set (and is logged by the caller)."""
    return hlc_pt_ms > server_now_ms + SKEW_TOLERANCE_MS
