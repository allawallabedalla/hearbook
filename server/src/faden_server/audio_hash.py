"""Audio-hash per docs/ARCHITEKTUR.md section 3.4.

Pure, no database access: given a file (or bytes), returns the sha256 hex
digest of the audio payload with any ID3v2 (header/footer), ID3v1 and APEv2
(with or without header) tags stripped. Tags are ignored on purpose so that
renaming or re-tagging a file never changes its hash (see decision E5).

Reads happen in bounded blocks (BLOCK_SIZE) so the whole file is never held
in memory at once.
"""

from __future__ import annotations

import hashlib
import io
import struct
from pathlib import Path
from typing import BinaryIO

BLOCK_SIZE = 1024 * 1024  # 1 MiB

_ID3_MAGIC = b"ID3"
_ID3V1_MAGIC = b"TAG"
_APE_MAGIC = b"APETAGEX"
_MAX_END_PASSES = 4


def _syncsafe_u32(b: bytes) -> int:
    return (b[0] << 21) | (b[1] << 14) | (b[2] << 7) | b[3]


def _find_start(f: BinaryIO) -> int:
    """Skip leading ID3v2 tag(s), each possibly carrying a 10-byte footer."""
    start = 0
    while True:
        f.seek(start)
        header = f.read(10)
        if len(header) < 10 or header[0:3] != _ID3_MAGIC:
            break
        size = _syncsafe_u32(header[6:10])
        has_footer = bool(header[5] & 0x10)
        start += 10 + size + (10 if has_footer else 0)
    return start


def _find_end(f: BinaryIO, file_size: int, start: int) -> int:
    """Strip trailing ID3v1 and/or APEv2 (with or without header) tags."""
    ende = file_size
    for _ in range(_MAX_END_PASSES):
        changed = False

        if ende - start >= 128:
            f.seek(ende - 128)
            if f.read(3) == _ID3V1_MAGIC:
                ende -= 128
                changed = True

        if not changed and ende - start >= 32:
            f.seek(ende - 32)
            footer = f.read(32)
            if footer[0:8] == _APE_MAGIC:
                size = struct.unpack("<I", footer[12:16])[0]
                flags = struct.unpack("<I", footer[20:24])[0]
                has_header = bool(flags & 0x80000000)
                ende -= size + (32 if has_header else 0)
                changed = True

        if not changed:
            break

    return max(ende, start)


def _hash_range(f: BinaryIO, start: int, end: int) -> str:
    h = hashlib.sha256()
    f.seek(start)
    remaining = end - start
    while remaining > 0:
        chunk = f.read(min(BLOCK_SIZE, remaining))
        if not chunk:
            break
        h.update(chunk)
        remaining -= len(chunk)
    return h.hexdigest()


def audio_hash(path: Path) -> str:
    """Hash the audio payload of a file on disk, streaming in bounded blocks."""
    size = Path(path).stat().st_size
    with open(path, "rb") as f:
        start = _find_start(f)
        end = _find_end(f, size, start)
        return _hash_range(f, start, end)


def audio_hash_bytes(data: bytes) -> str:
    """Same algorithm, for tests that build tag/audio byte combinations in memory."""
    f = io.BytesIO(data)
    start = _find_start(f)
    end = _find_end(f, len(data), start)
    return _hash_range(f, start, end)
