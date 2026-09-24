"""Tests for duration.py, docs/ARCHITEKTUR.md section 3.5."""

from __future__ import annotations

import pytest

from faden_server.duration import AudioProbeError, probe_duration_ms

from .conftest import requires_ffmpeg


@requires_ffmpeg
def test_duration_roughly_matches_requested_length(make_mp3):
    p = make_mp3(segments=[("tone", 2.0)])
    ms = probe_duration_ms(p)
    assert isinstance(ms, int)
    # mp3 encoding adds a little frame padding; allow some slack.
    assert 1900 <= ms <= 2200


@requires_ffmpeg
def test_duration_sums_segments(make_mp3):
    p = make_mp3(segments=[("tone", 1.0), ("silence", 0.5), ("tone", 1.0)])
    ms = probe_duration_ms(p)
    assert 2300 <= ms <= 2700


def test_duration_raises_on_unreadable_file(tmp_path):
    p = tmp_path / "not-audio.mp3"
    p.write_bytes(b"this is not an mp3 file at all")
    with pytest.raises(AudioProbeError):
        probe_duration_ms(p)


def test_duration_raises_on_missing_file(tmp_path):
    with pytest.raises(AudioProbeError):
        probe_duration_ms(tmp_path / "missing.mp3")
