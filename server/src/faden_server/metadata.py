"""Metadata and cover resolution, docs/ARCHITEKTUR.md section 3.6.

Reading tags touches the file system; everything that turns folder names
and tag values into a book's title, author, narrator and ISBN
(`resolve_book_info` and its helpers) is pure and deterministic.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass
from pathlib import Path

from mutagen.id3 import ID3

COVER_FILENAMES = ("cover.jpg", "cover.jpeg", "cover.png", "folder.jpg")

# Anything on the read-only library share can be arbitrarily large; cap how
# much a cover request will materialize in memory, whether it is a folder
# cover file or an embedded APIC frame.
MAX_COVER_BYTES = 10 * 1024 * 1024


@dataclass(frozen=True)
class TrackTags:
    disc: int | None
    track: int | None
    title: str | None


@dataclass(frozen=True)
class BookTags:
    """The book-level tags of a book's first file."""

    album: str | None = None  # TALB
    artist: str | None = None  # TPE1
    album_artist: str | None = None  # TPE2
    track_title: str | None = None  # TIT2
    isbn: str | None = None  # TXXX with "ISBN" in its description


@dataclass(frozen=True)
class BookInfo:
    title: str
    author: str | None
    narrator: str | None = None
    isbn: str | None = None


@dataclass(frozen=True)
class EmbeddedCover:
    mime: str
    data: bytes


def _parse_leading_int(value: str) -> int | None:
    """ "3/12" -> 3, "3" -> 3, garbage -> None."""
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


def _first_text(tags: ID3, frame_id: str) -> str | None:
    frame = tags.get(frame_id)
    if frame is None or not getattr(frame, "text", None):
        return None
    return str(frame.text[0])


def read_track_tags(path: Path) -> TrackTags:
    tags = _read_id3(path)
    if tags is None:
        return TrackTags(disc=None, track=None, title=None)

    tpos = _first_text(tags, "TPOS")
    trck = _first_text(tags, "TRCK")
    disc = _parse_leading_int(tpos) if tpos else None
    track = _parse_leading_int(trck) if trck else None
    return TrackTags(disc=disc, track=track, title=_first_text(tags, "TIT2"))


def read_book_tags(path: Path) -> BookTags:
    """Album, artist, album artist, track title and an ISBN tag of one file."""
    tags = _read_id3(path)
    if tags is None:
        return BookTags()
    isbn = None
    for frame in tags.getall("TXXX"):
        if "isbn" in (frame.desc or "").casefold() and frame.text:
            isbn = str(frame.text[0])
            break
    return BookTags(
        album=_first_text(tags, "TALB"),
        artist=_first_text(tags, "TPE1"),
        album_artist=_first_text(tags, "TPE2"),
        track_title=_first_text(tags, "TIT2"),
        isbn=isbn,
    )


# --- title / author / narrator / ISBN (pure) ---------------------------------

# Tag values that name no book and no person (compared casefolded).
JUNK_VALUES = frozenset(
    {
        "speech",
        "spoken word",
        "audiobook",
        "audiobooks",
        "audio book",
        "hörbuch",
        "hörbücher",
        "hoerbuch",
        "unknown",
        "unknown album",
        "unknown artist",
        "unbekannt",
        "unbekannter künstler",
        "various",
        "various artists",
        "diverse",
        "untitled",
        "ohne titel",
        "track",
        "other",
    }
)

# Parent folders that group books instead of naming their author; a book
# below one of them is treated like a book directly below the library root.
GENERIC_FOLDERS = JUNK_VALUES | frozenset(
    {
        "books",
        "bücher",
        "buecher",
        "hoerbuecher",
        "hörspiel",
        "hörspiele",
        "hoerspiele",
        "audio",
        "mp3",
        "downloads",
        "download",
        "incoming",
        "neu",
        "new",
        "library",
        "bibliothek",
        "medien",
        "media",
        "misc",
        "sonstige",
        "unsortiert",
    }
)

_URL = re.compile(r"https?://|\bwww\.", re.IGNORECASE)
_BARE_DOMAIN = re.compile(
    r"^[a-z0-9][a-z0-9-]*(\.[a-z0-9-]+)*"
    r"\.(de|com|net|org|at|ch|eu|info|io|fm|tv|biz|uk|us|fr|it|nl|es|be|lu|li|pl|cz|dk|se|fi)"
    r"(/\S*)?$",
    re.IGNORECASE,
)
_NARRATOR = re.compile(
    r"^(sprecher(in)?|gesprochen von|gelesen von|read by|narrated by|narrator)\b"
    r"\s*[:\-–]?\s*(?P<name>.*)$",
    re.IGNORECASE,
)
# "Autor - Titel": a dash with spaces on both sides ("Spider-Man" is one word).
_DASH_SEPARATOR = re.compile(r"\s+[-–—]\s+")
# Separators of a leading "<author> - " / "<author>: " in a title.
_PREFIX_SEPARATOR = re.compile(r"\s+[-–—]\s+|\s*:\s+")
# "Author_Title-with-dashes_ISBN13", e.g. "Gordon_Der-Medicus_9783837121995".
_ISBN_FOLDER = re.compile(r"^(?P<author>[^_]+)_(?P<title>.+)_(?P<isbn>97[89]\d{10})$")
_ISBN_IN_TEXT = re.compile(r"(?<!\d)97[89]\d{10}(?!\d)")
_UMLAUTS = str.maketrans({"ä": "ae", "ö": "oe", "ü": "ue", "ß": "ss"})


def clean_value(value: str | None) -> str | None:
    """Whitespace trimmed and squashed, underscores as spaces, and the
    " ? " a lost dash turns into (encoding artifact) back as " – "."""
    if value is None:
        return None
    cleaned = value.replace("_", " ")
    cleaned = re.sub(r"\s+\?\s+", " – ", cleaned)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    return cleaned or None


def is_junk(value: str | None) -> bool:
    """True for values that are a URL or web site ("vorleser.net",
    "www.…", "http…") or a generic placeholder ("Speech", "Hörbuch")."""
    cleaned = clean_value(value)
    if cleaned is None:
        return True
    return (
        cleaned.casefold() in JUNK_VALUES
        or _URL.search(cleaned) is not None
        or _BARE_DOMAIN.match(cleaned) is not None
    )


def _usable(value: str | None) -> str | None:
    return None if is_junk(value) else clean_value(value)


def match_key(value: str | None) -> str:
    """Comparison key: casefolded, umlauts spelled out, accents dropped,
    only letters and digits ("Fräulein" == "Fraeulein", "Horváth" ==
    "Horvath", punctuation and spacing ignored)."""
    if not value:
        return ""
    folded = value.casefold().translate(_UMLAUTS)
    decomposed = unicodedata.normalize("NFKD", folded)
    return "".join(c for c in decomposed if c.isalnum())


def narrator_of(artist: str | None) -> str | None:
    """The name in "Sprecher: X", "Gelesen von X", "Read by X",
    "Narrator: X"; None if the artist is not marked as a narrator."""
    cleaned = clean_value(artist)
    if cleaned is None:
        return None
    match = _NARRATOR.match(cleaned)
    if match is None:
        return None
    return clean_value(match.group("name"))


def is_narrator(artist: str | None) -> bool:
    cleaned = clean_value(artist)
    return cleaned is not None and _NARRATOR.match(cleaned) is not None


def strip_author_prefix(title: str, author: str | None) -> str:
    """ "Ödön von Horváth - 36 Stunden" -> "36 Stunden" when the prefix is
    the author (compared by match_key); otherwise the title unchanged."""
    author_key = match_key(author)
    if not author_key:
        return title
    for sep in _PREFIX_SEPARATOR.finditer(title):
        if match_key(title[: sep.start()]) == author_key:
            rest = title[sep.end() :].strip()
            return rest or title
    return title


def split_author_title(value: str) -> tuple[str, str] | None:
    """ "Autor - Titel" -> ("Autor", "Titel") at the first spaced dash."""
    sep = _DASH_SEPARATOR.search(value)
    if sep is None:
        return None
    author = value[: sep.start()].strip()
    title = value[sep.end() :].strip()
    if not author or not title:
        return None
    return author, title


def is_valid_isbn13(value: str) -> bool:
    if not re.fullmatch(r"97[89]\d{10}", value):
        return False
    digits = [int(c) for c in value]
    total = sum(d * (3 if i % 2 else 1) for i, d in enumerate(digits[:12]))
    return (10 - total % 10) % 10 == digits[12]


def isbn_in_text(text: str | None, *, separators: bool = False) -> str | None:
    """First checksum-valid ISBN-13 (978/979) in a folder name. With
    `separators`, hyphens and spaces inside the number are allowed too
    ("978-3-8371-2199-5", as in an ISBN tag)."""
    if not text:
        return None
    candidate = re.sub(r"[\s-]", "", text) if separators else text
    for match in _ISBN_IN_TEXT.finditer(candidate):
        if is_valid_isbn13(match.group()):
            return match.group()
    return None


def parse_isbn_folder(name: str) -> tuple[str, str, str] | None:
    """ "Herbert_Dune-_-Der-Wuestenplanet_9783837153569" -> ("Herbert",
    "Dune – Der Wuestenplanet", "9783837153569"). In this naming scheme
    spaces became "-" and a dash became "_", so "-_-" is a dash and every
    other "-" a space. Transliterations ("ue") stay; tags are better."""
    match = _ISBN_FOLDER.match(name.strip())
    if match is None or not is_valid_isbn13(match.group("isbn")):
        return None
    title = match.group("title").replace("-_-", " – ").replace("-", " ")
    author = clean_value(match.group("author"))
    title = clean_value(title)
    if author is None or title is None:
        return None
    return author, title, match.group("isbn")


def _author_folder(parent_name: str | None) -> str | None:
    if parent_name is None:
        return None
    cleaned = _usable(parent_name)
    if cleaned is None or cleaned.casefold() in GENERIC_FOLDERS:
        return None
    return cleaned


def resolve_book_info(
    folder_name: str,
    tags: BookTags | None = None,
    *,
    parent_name: str | None = None,
) -> BookInfo:
    """Title, author, narrator and ISBN of a book (section 3.6).

    `parent_name` is the name of the folder containing the book folder, or
    None when the book folder lies directly below the library root.

    - <Author>/<Book>/ (parent below the root): the author is the parent
      folder and the title the book folder; the album tag (or the first
      file's title tag), minus a leading "<author> - "/"<author>: ", only
      replaces the title when it is the same text (match_key), for its
      nicer punctuation and umlauts.
    - Directly below the root (or below a generic folder like
      "Hörbücher", or an "Author_Title_ISBN" folder): album and artist tag
      first, then the folder name ("Author_Title_ISBN", "Autor - Titel",
      the plain name).
    - Never used: URL/site or placeholder values (is_junk); an artist
      marked as narrator ("Sprecher: X") is the narrator, never the author.
    """
    tags = tags or BookTags()
    narrator = narrator_of(tags.artist) or narrator_of(tags.album_artist)
    artist = None if is_narrator(tags.artist) else _usable(tags.artist)
    album = _usable(tags.album)
    track_title = _usable(tags.track_title)
    folder = clean_value(folder_name) or folder_name
    isbn_folder = parse_isbn_folder(folder_name)
    isbn = isbn_in_text(folder_name) or isbn_in_text(tags.isbn, separators=True)

    author_folder = None if isbn_folder else _author_folder(parent_name)
    if author_folder is not None:
        title = strip_author_prefix(folder, author_folder)
        title_key = match_key(title)
        for candidate in (album, track_title):
            if candidate is None:
                continue
            candidate = strip_author_prefix(candidate, author_folder)
            if title_key and match_key(candidate) == title_key:
                title = candidate
                break
        return BookInfo(title=title, author=author_folder, narrator=narrator, isbn=isbn)

    if isbn_folder is not None:
        folder_author, folder_title = isbn_folder[0], isbn_folder[1]
    else:
        split = split_author_title(folder)
        folder_author, folder_title = split if split else (None, folder)

    author = artist
    if album is not None:
        if author is None and folder_author is not None:
            author = folder_author
        if author is None:
            split = split_author_title(album)
            if split is not None:
                author, title = split
            else:
                title = album
        else:
            title = strip_author_prefix(album, author)
    else:
        title = folder_title
        if author is None:
            author = folder_author
        else:
            title = strip_author_prefix(title, author)
    return BookInfo(title=title, author=author, narrator=narrator, isbn=isbn)


def find_cover_file(folder: Path) -> Path | None:
    for name in COVER_FILENAMES:
        candidate = folder / name
        if candidate.is_file():
            return candidate
    return None


def extract_embedded_cover(path: Path, *, max_bytes: int = MAX_COVER_BYTES) -> EmbeddedCover | None:
    tags = _read_id3(path)
    if tags is None:
        return None
    frames = tags.getall("APIC")
    if not frames:
        return None
    frame = frames[0]
    if len(frame.data) > max_bytes:
        return None
    return EmbeddedCover(mime=frame.mime or "image/jpeg", data=bytes(frame.data))
