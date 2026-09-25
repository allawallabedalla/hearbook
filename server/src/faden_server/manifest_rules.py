"""Pure ordering (3.2) and rescan (3.3) rules from docs/ARCHITEKTUR.md.

No filesystem or database access here; scanner.py does the I/O and calls
into this module with plain data.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field
from typing import Literal

OrderStatus = Literal["active", "needs_review"]
ManifestStatus = Literal["active", "pending", "needs_review"]
RescanAction = Literal[
    "none", "auto_active", "pending", "needs_review", "incomplete", "first_active"
]

_NUM_RE = re.compile(r"(\d+)")


@dataclass(frozen=True)
class FileEntry:
    file_hash: str
    filename: str
    disc_from_folder: int
    tag_disc: int | None
    tag_track: int | None
    duration_ms: int
    readable: bool = True


@dataclass(frozen=True)
class OrderResult:
    status: OrderStatus
    candidates: list[list[str]]  # 1 item normally, 2 when key A and B disagree
    reasons: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class RescanOutcome:
    action: RescanAction
    # (ordered file_hash list, status) pairs of manifests to create
    new_manifests: list[tuple[list[str], ManifestStatus]]


def natural_key(name: str) -> tuple:
    """Numbers sort numerically, rest case-insensitively, Unicode NFC."""
    normalized = unicodedata.normalize("NFC", name).casefold()
    parts = _NUM_RE.split(normalized)
    return tuple(int(p) if p.isdigit() else p for p in parts)


def _key_b(e: FileEntry) -> tuple:
    return (e.disc_from_folder, natural_key(e.filename))


def _order_b(entries: list[FileEntry]) -> list[str]:
    return [e.file_hash for e in sorted(entries, key=_key_b)]


def _order_a(entries: list[FileEntry]) -> list[str] | None:
    """Key A: (disc, track) from ID3 tags. None if invalid (see 3.2 rule 1)."""
    if any(e.tag_track is None for e in entries):
        return None
    pairs = [
        (e.tag_disc if e.tag_disc is not None else e.disc_from_folder, e.tag_track) for e in entries
    ]
    if len(set(pairs)) != len(pairs):
        return None
    order = sorted(zip(pairs, entries, strict=True), key=lambda pe: pe[0])
    return [e.file_hash for _, e in order]


def compute_order(entries: list[FileEntry]) -> OrderResult:
    """Section 3.2: pick an order, decide active vs. needs_review."""
    hashes = [e.file_hash for e in entries]
    reasons: list[str] = []
    if len(set(hashes)) != len(hashes):
        reasons.append("duplicate_hash")
    if any(e.duration_ms == 0 for e in entries):
        reasons.append("zero_duration")
    if any(not e.readable for e in entries):
        reasons.append("unreadable")

    order_a = _order_a(entries)
    order_b = _order_b(entries)

    if order_a is not None and order_a != order_b:
        return OrderResult(
            status="needs_review",
            candidates=[order_a, order_b],
            reasons=[*reasons, "order_ambiguous"],
        )

    primary = order_a if order_a is not None else order_b
    status: OrderStatus = "needs_review" if reasons else "active"
    return OrderResult(status=status, candidates=[primary], reasons=reasons)


def diff_rescan(
    active_hashes: list[str] | None,
    new_status: OrderStatus,
    new_candidates: list[list[str]],
    *,
    missing_from_active: set[str] | None = None,
) -> RescanOutcome:
    """Section 3.3: decide what a rescan does to the book's manifests.

    `active_hashes` is the current active manifest's ordered file_hash list
    (None on first import). `new_status`/`new_candidates` come straight out
    of compute_order() for the files found on disk right now.
    `missing_from_active` are file_hashes from the active manifest that are
    no longer found among the files on disk (the "files missing" row).
    """
    if missing_from_active:
        return RescanOutcome(action="incomplete", new_manifests=[])

    if new_status == "needs_review":
        return RescanOutcome(
            action="needs_review",
            new_manifests=[(c, "needs_review") for c in new_candidates],
        )

    new_list = new_candidates[0]

    if active_hashes is None:
        return RescanOutcome(action="first_active", new_manifests=[(new_list, "active")])

    if new_list == active_hashes:
        return RescanOutcome(action="none", new_manifests=[])

    is_append_only = (
        len(new_list) > len(active_hashes) and new_list[: len(active_hashes)] == active_hashes
    )
    if is_append_only:
        return RescanOutcome(action="auto_active", new_manifests=[(new_list, "active")])

    return RescanOutcome(action="pending", new_manifests=[(new_list, "pending")])
