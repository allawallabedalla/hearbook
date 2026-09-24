"""Metadata and cover resolution, docs/ARCHITEKTUR.md section 3.6."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from mutagen.id3 import ID3

COVER_FILENAMES = ("cover.jpg", "cover.jpeg", "cover.png", "folder.jpg")

# "Autor - Titel"
_FOLDER_PATTERN = re.compile(r"^\s*(?P<author>.+?)\s*-\s*(?P<title>.+?)\s*$")


@dataclass(frozen=True)
class TrackTags:
    disc: int | None
    track: int | None
    title: str | None


@dataclass(frozen=True)
class EmbeddedCover:
    mime: str
    data: bytes


def _parse_leading_int(value: str) -> int | None:
    """"3/12" -> 3, "3" -> 3, garbage -> None."""
    if not value:
        return None
    head = value.split("/")[0].strip()
    try:
        return int(head)
    except ValueError:
        return None


def _read_id3(path: Path) -> ID3 | None:
    try:
        return ID3(path)
    except Exception:
        return None


def read_track_tags(path: Path) -> TrackTags:
    tags = _read_id3(path)
    if tags is None:
        return TrackTags(disc=None, track=None, title=None)

    tpos = tags.get("TPOS")
    trck = tags.get("TRCK")
    tit2 = tags.get("TIT2")
    disc = _parse_leading_int(str(tpos.text[0])) if tpos and tpos.text else None
    track = _parse_leading_int(str(trck.text[0])) if trck and trck.text else None
    title = str(tit2.text[0]) if tit2 and tit2.text else None
    return TrackTags(disc=disc, track=track, title=title)


def read_book_tags(path: Path) -> tuple[str | None, str | None]:
    """TALB (book title) and TPE1 (author) of one file."""
    tags = _read_id3(path)
    if tags is None:
        return (None, None)
    talb = tags.get("TALB")
    tpe1 = tags.get("TPE1")
    title = str(talb.text[0]) if talb and talb.text else None
    author = str(tpe1.text[0]) if tpe1 and tpe1.text else None
    return (title, author)


def resolve_title_author(
    folder_name: str, album: str | None, artist: str | None
) -> tuple[str, str | None]:
    """Title/author priority per 3.6: ID3 tags, then "Autor - Titel" folder
    name, then the plain folder name."""
    if album:
        return (album, artist)
    match = _FOLDER_PATTERN.match(folder_name)
    if match:
        return (match.group("title"), match.group("author"))
    return (folder_name, None)


def find_cover_file(folder: Path) -> Path | None:
    for name in COVER_FILENAMES:
        candidate = folder / name
        if candidate.is_file():
            return candidate
    return None


def extract_embedded_cover(path: Path) -> EmbeddedCover | None:
    tags = _read_id3(path)
    if tags is None:
        return None
    frames = tags.getall("APIC")
    if not frames:
        return None
    frame = frames[0]
    return EmbeddedCover(mime=frame.mime or "image/jpeg", data=bytes(frame.data))
