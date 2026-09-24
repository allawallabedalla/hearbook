"""Duration via ffprobe, docs/ARCHITEKTUR.md section 3.5.

Summed from packet durations, never estimated from the bitrate (VBR files
would be wrong). Caching by hash happens in scanner.py.
"""

from __future__ import annotations

import subprocess
from pathlib import Path


class AudioProbeError(Exception):
    """Raised when ffprobe cannot read the file (unreadable/missing/corrupt)."""


def probe_duration_ms(path: Path) -> int:
    try:
        result = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-select_streams",
                "a:0",
                "-show_entries",
                "packet=duration_time",
                "-of",
                "csv=p=0",
                str(path),
            ],
            capture_output=True,
            text=True,
            timeout=120,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise AudioProbeError(f"ffprobe failed for {path}: {exc}") from exc

    if result.returncode != 0:
        raise AudioProbeError(f"ffprobe failed for {path}: {result.stderr.strip()}")

    total_s = 0.0
    saw_packet = False
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            total_s += float(line)
            saw_packet = True
        except ValueError:
            continue

    if not saw_packet:
        raise AudioProbeError(f"no audio packets found in {path}")

    return round(total_s * 1000)
