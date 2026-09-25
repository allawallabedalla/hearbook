"""Shared test fixtures. Test audio is synthesized via ffmpeg, never committed
to the repo (see CLAUDE.md)."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

from faden_server import genre_lookup

FFMPEG = shutil.which("ffmpeg")
FFPROBE = shutil.which("ffprobe")
SQLITE3_CLI = shutil.which("sqlite3")

requires_ffmpeg = pytest.mark.skipif(
    FFMPEG is None or FFPROBE is None, reason="ffmpeg/ffprobe not installed"
)
requires_sqlite3_cli = pytest.mark.skipif(SQLITE3_CLI is None, reason="sqlite3 CLI not installed")


def synth_tone(
    path: Path,
    *,
    segments: list[tuple[str, float]],
    sample_rate: int = 22050,
    freq: int = 440,
    bitrate: str = "32k",
) -> Path:
    """Render an mp3 made of concatenated segments.

    Each segment is ("tone", seconds) or ("silence", seconds). Using digital
    silence (anullsrc) rather than a muted tone keeps silencedetect reliable.
    No ID3/APE tags are written (id3v2_version 0, no Xing/ID3v1) so the
    output is "raw" audio data for hash tests to wrap themselves.
    """
    filter_inputs = []
    concat_labels = []
    for i, (kind, seconds) in enumerate(segments):
        label = f"s{i}"
        if kind == "tone":
            filter_inputs.append(
                f"sine=frequency={freq}:duration={seconds}:sample_rate={sample_rate}[{label}]"
            )
        elif kind == "silence":
            filter_inputs.append(f"anullsrc=r={sample_rate}:cl=mono:d={seconds}[{label}]")
        else:
            raise ValueError(f"unknown segment kind: {kind}")
        concat_labels.append(f"[{label}]")
    filter_complex = ";".join(filter_inputs)
    filter_complex += f";{''.join(concat_labels)}concat=n={len(segments)}:v=0:a=1[out]"

    cmd = [
        FFMPEG,
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-filter_complex",
        filter_complex,
        "-map",
        "[out]",
        "-codec:a",
        "libmp3lame",
        "-b:a",
        bitrate,
        "-id3v2_version",
        "0",
        "-write_xing",
        "0",
        "-write_id3v1",
        "0",
        str(path),
    ]
    subprocess.run(cmd, check=True, capture_output=True)
    return path


@pytest.fixture
def make_mp3(tmp_path: Path):
    """Factory fixture: make_mp3(name, segments=[("tone", 1.0)], ...) -> Path."""

    def _make(
        name: str = "audio.mp3",
        *,
        segments: list[tuple[str, float]] | None = None,
        freq: int = 440,
        **kwargs,
    ) -> Path:
        segments = segments or [("tone", 1.0)]
        return synth_tone(tmp_path / name, segments=segments, freq=freq, **kwargs)

    return _make


@pytest.fixture(autouse=True)
def _no_catalog_requests(monkeypatch):
    """No test ever talks to a real book catalog: any genre lookup that is
    not given a fake fetch finds every source unreachable, immediately."""

    def offline(url: str) -> bytes:
        raise OSError(f"network disabled in tests: {url}")

    monkeypatch.setattr(genre_lookup, "_http_get", offline)
    monkeypatch.setattr(genre_lookup, "_default_throttle", lambda: None)
