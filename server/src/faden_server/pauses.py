"""Pause index via ffmpeg silencedetect, docs/ARCHITEKTUR.md section 4.

Each `silence_end` reported by the filter is treated as a sentence start.
Offset 0 (file start) is always included. Caching by hash (and by the
detection params, so a parameter change forces recomputation) happens in
scanner.py.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

_SILENCE_END_RE = re.compile(r"silence_end:\s*([0-9.]+)")


class PauseDetectionError(Exception):
    """Raised when ffmpeg cannot process the file."""


def compute_pause_offsets(path: Path, *, noise_db: float, silence_s: float) -> list[int]:
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-i",
        str(path),
        "-af",
        f"silencedetect=noise={noise_db}dB:d={silence_s}",
        "-f",
        "null",
        "-",
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    except (OSError, subprocess.SubprocessError) as exc:
        raise PauseDetectionError(f"ffmpeg failed for {path}: {exc}") from exc

    if result.returncode != 0:
        raise PauseDetectionError(f"ffmpeg failed for {path}: {result.stderr.strip()}")

    offsets = {0}
    for match in _SILENCE_END_RE.finditer(result.stderr):
        offsets.add(round(float(match.group(1)) * 1000))

    return sorted(offsets)
