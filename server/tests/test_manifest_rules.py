"""Tests for the pure ordering (3.2) and rescan (3.3) rules.

One test per table case, as required by docs/ROADMAP.md M1.
"""

from __future__ import annotations

from faden_server.manifest_rules import FileEntry, compute_order, diff_rescan


def entry(hash_, *, disc_folder=1, tag_disc=None, tag_track=None, filename=None,
          duration_ms=1000, readable=True):
    return FileEntry(
        file_hash=hash_,
        filename=filename or f"{hash_}.mp3",
        disc_from_folder=disc_folder,
        tag_disc=tag_disc,
        tag_track=tag_track,
        duration_ms=duration_ms,
        readable=readable,
    )


# --- 3.2 ordering -----------------------------------------------------


def test_key_a_valid_and_equals_key_b_gives_active_order_a():
    # filenames already sorted 01,02,03 and tags match -> A == B
    entries = [
        entry("h1", tag_track=1, filename="01.mp3"),
        entry("h2", tag_track=2, filename="02.mp3"),
        entry("h3", tag_track=3, filename="03.mp3"),
    ]
    result = compute_order(entries)
    assert result.status == "active"
    assert result.candidates == [["h1", "h2", "h3"]]


def test_key_a_valid_but_differs_from_key_b_needs_review_both_candidates():
    # tags say h2 is track 1 and h1 is track 2, but filenames sort h1 before h2
    entries = [
        entry("h1", tag_track=2, filename="01.mp3"),
        entry("h2", tag_track=1, filename="02.mp3"),
    ]
    result = compute_order(entries)
    assert result.status == "needs_review"
    assert result.candidates == [["h2", "h1"], ["h1", "h2"]]
    assert "order_ambiguous" in result.reasons


def test_key_a_invalid_missing_track_uses_key_b():
    entries = [
        entry("h1", tag_track=1, filename="02.mp3"),
        entry("h2", tag_track=None, filename="01.mp3"),
    ]
    result = compute_order(entries)
    assert result.status == "active"
    assert result.candidates == [["h2", "h1"]]  # natural filename order


def test_key_a_invalid_duplicate_disc_track_pairs_uses_key_b():
    entries = [
        entry("h1", tag_track=1, filename="02.mp3"),
        entry("h2", tag_track=1, filename="01.mp3"),
    ]
    result = compute_order(entries)
    assert result.status == "active"
    assert result.candidates == [["h2", "h1"]]


def test_disc_from_subfolder_used_when_tag_disc_missing():
    entries = [
        entry("h1", disc_folder=2, tag_track=1, filename="01.mp3"),
        entry("h2", disc_folder=1, tag_track=1, filename="01.mp3"),
    ]
    result = compute_order(entries)
    # key A: (disc_folder, track) since tag_disc missing -> (2,1) and (1,1) -> h2 first
    # key B: (disc_folder, natural filename) -> same order
    assert result.status == "active"
    assert result.candidates == [["h2", "h1"]]


def test_natural_sort_numeric_and_case_insensitive():
    entries = [
        entry("h10", filename="Kapitel 10.mp3"),
        entry("h2", filename="kapitel 2.mp3"),
        entry("h1", filename="Kapitel 1.mp3"),
    ]
    result = compute_order(entries)
    assert result.candidates == [["h1", "h2", "h10"]]


# --- additional needs_review triggers (3.2, last paragraph) -----------


def test_duplicate_hash_forces_needs_review():
    entries = [
        entry("h1", tag_track=1, filename="01.mp3"),
        entry("h1", tag_track=2, filename="02.mp3"),
    ]
    result = compute_order(entries)
    assert result.status == "needs_review"
    assert "duplicate_hash" in result.reasons


def test_zero_duration_forces_needs_review():
    entries = [
        entry("h1", tag_track=1, filename="01.mp3", duration_ms=0),
        entry("h2", tag_track=2, filename="02.mp3"),
    ]
    result = compute_order(entries)
    assert result.status == "needs_review"
    assert "zero_duration" in result.reasons


def test_unreadable_file_forces_needs_review():
    entries = [
        entry("h1", tag_track=1, filename="01.mp3", readable=False),
        entry("h2", tag_track=2, filename="02.mp3"),
    ]
    result = compute_order(entries)
    assert result.status == "needs_review"
    assert "unreadable" in result.reasons


# --- 3.3 rescan table ---------------------------------------------------


def test_rescan_new_list_equals_active_list_does_nothing():
    outcome = diff_rescan(["h1", "h2"], "active", [["h1", "h2"]])
    assert outcome.action == "none"


def test_rescan_active_is_prefix_of_new_auto_activates():
    outcome = diff_rescan(["h1", "h2"], "active", [["h1", "h2", "h3"]])
    assert outcome.action == "auto_active"
    assert outcome.new_manifests == [(["h1", "h2", "h3"], "active")]


def test_rescan_anything_else_creates_pending_manifest():
    # reordered, not a pure append
    outcome = diff_rescan(["h1", "h2"], "active", [["h2", "h1"]])
    assert outcome.action == "pending"
    assert outcome.new_manifests == [(["h2", "h1"], "pending")]


def test_rescan_files_missing_on_disk_keeps_manifest_and_marks_incomplete():
    # h2 from the active manifest is no longer present among current files
    outcome = diff_rescan(["h1", "h2"], "active", [["h1"]], missing_from_active={"h2"})
    assert outcome.action == "incomplete"
    assert outcome.new_manifests == []


def test_rescan_first_import_no_prior_manifest_becomes_active():
    outcome = diff_rescan(None, "active", [["h1", "h2"]])
    assert outcome.action == "first_active"
    assert outcome.new_manifests == [(["h1", "h2"], "active")]


def test_rescan_ambiguous_order_always_needs_review_even_if_appended():
    # even though it extends the active list, ambiguous ordering must not
    # auto-activate silently (invariant 4: order never changes silently)
    outcome = diff_rescan(
        ["h1"], "needs_review", [["h1", "h3", "h2"], ["h1", "h2", "h3"]]
    )
    assert outcome.action == "needs_review"
    assert outcome.new_manifests == [
        (["h1", "h3", "h2"], "needs_review"),
        (["h1", "h2", "h3"], "needs_review"),
    ]
