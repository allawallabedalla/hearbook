"""Tests for pauses.py, docs/ARCHITEKTUR.md section 4."""

from __future__ import annotations

from faden_server.pauses import compute_pause_offsets

from .conftest import requires_ffmpeg


@requires_ffmpeg
def test_pause_offsets_always_include_zero(make_mp3):
    p = make_mp3(segments=[("tone", 1.0)])
    offsets = compute_pause_offsets(p, noise_db=-35, silence_s=0.35)
    assert offsets[0] == 0


@requires_ffmpeg
def test_pause_offsets_sorted(make_mp3):
    p = make_mp3(
        segments=[("tone", 1.0), ("silence", 0.5), ("tone", 1.0), ("silence", 0.5), ("tone", 1.0)]
    )
    offsets = compute_pause_offsets(p, noise_db=-35, silence_s=0.35)
    assert offsets == sorted(offsets)


@requires_ffmpeg
def test_pause_offsets_detect_silence_gaps(make_mp3):
    # tone(1s) silence(0.5s) tone(1s) silence(0.5s) tone(1s)
    # sentence starts should appear near ~1.5s and ~3.0s (after each silence)
    p = make_mp3(
        segments=[("tone", 1.0), ("silence", 0.5), ("tone", 1.0), ("silence", 0.5), ("tone", 1.0)]
    )
    offsets = compute_pause_offsets(p, noise_db=-35, silence_s=0.35)
    assert 0 in offsets
    non_zero = [o for o in offsets if o > 0]
    assert len(non_zero) >= 2
    assert any(1300 <= o <= 1700 for o in non_zero)
    assert any(2800 <= o <= 3200 for o in non_zero)


@requires_ffmpeg
def test_pause_offsets_no_silence_only_zero(make_mp3):
    p = make_mp3(segments=[("tone", 1.0)])
    offsets = compute_pause_offsets(p, noise_db=-35, silence_s=0.35)
    assert offsets == [0]


@requires_ffmpeg
def test_pause_offsets_short_gap_below_threshold_not_detected(make_mp3):
    # a 0.1s gap is shorter than the 0.35s minimum -> not a silence_end
    p = make_mp3(segments=[("tone", 1.0), ("silence", 0.1), ("tone", 1.0)])
    offsets = compute_pause_offsets(p, noise_db=-35, silence_s=0.35)
    assert offsets == [0]
