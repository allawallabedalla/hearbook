"""Normalized book genres and the mapping from catalog categories to them.

Pure module, no I/O (docs/ARCHITEKTUR.md section 3.7). Catalogs describe a
book with classification codes (DNB Sachgruppen, DDC numbers) and free-text
subjects (GND headings, VLB-Warengruppen, Google Books categories, Open
Library subjects). Both are mapped onto a small fixed set of German labels.

Both rule tables are plain data, first match wins per input string; extend
them by adding a row. An input that matches no row, or only a row mapped to
None, contributes nothing. When several inputs of one record map to
different genres, the more specific genre wins (GENRE_PRIORITY); the two
broad buckets (Sachbuch, Romane) share the lowest priority, so between them
the first one in the record wins (catalogs list the main class first).
"""

from __future__ import annotations

import re
from collections.abc import Iterable

KRIMI = "Krimi & Thriller"
FANTASY_SF = "Fantasy & Science-Fiction"
ROMANE = "Romane"
KINDER = "Kinder & Jugend"
SACHBUCH = "Sachbuch"
BIOGRAFIE = "Biografie"
KLASSIKER = "Klassiker"
HUMOR = "Humor"

# The API's label list (GET /api/v1/genres), in display order.
GENRES: tuple[str, ...] = (
    KRIMI,
    FANTASY_SF,
    ROMANE,
    KINDER,
    SACHBUCH,
    BIOGRAFIE,
    KLASSIKER,
    HUMOR,
)

# Lower wins. Sachbuch and Romane tie on purpose (see module docstring).
GENRE_PRIORITY: dict[str, int] = {
    KINDER: 0,
    KRIMI: 1,
    FANTASY_SF: 2,
    HUMOR: 3,
    KLASSIKER: 4,
    BIOGRAFIE: 5,
    SACHBUCH: 9,
    ROMANE: 9,
}

# Classification codes, matched against the normalized code (upper case,
# no spaces): DNB Sachgruppen ("B", "K", "830", "741.5"; the DNB sends them
# in MARC 082 with $2 "23sdnb", e.g. "810" and "B" for a novel) and DDC
# numbers ("833.914"). Kept conservative: no Sachgruppe says "Krimi" or
# "Fantasy", those come only from subjects. A row mapped to None marks a
# code as known-but-genreless and stops further rows for that code.
CODE_RULES: tuple[tuple[str, str | None], ...] = (
    (r"K", KINDER),  # Sachgruppe K: Kinder- und Jugendliteratur
    (r"B", ROMANE),  # Sachgruppe B: Belletristik
    (r"S", None),  # Sachgruppe S: Schulbücher
    (r"741\.5.*", None),  # Comics, Cartoons, Karikaturen
    (r"92\d(\..*)?", BIOGRAFIE),  # 920-929: Biografie, Genealogie, Heraldik
    (r"8\d7(\..*)?", HUMOR),  # DDC 8x7: humor and satire of a literature
    (r"8\d\d(\..*)?", ROMANE),  # 800-899: Literatur
    (r"\d{3}(\..*)?", SACHBUCH),  # everything else in DDC
)

# Free-text subjects, matched case-insensitively with re.search. Order
# matters within one string: the Kinder row comes first ("Juvenile Fiction /
# Mystery" is a children's book), then the rows that look like fiction but
# are not ("True Crime", "Nonfiction"), then the specific genres, and the
# broad buckets last.
SUBJECT_RULES: tuple[tuple[str, str | None], ...] = (
    (
        r"juvenile|young adult|children|kinder- und jugend|jugendliteratur|kinderliteratur"
        r"|\bkinder(buch|bücher|hörbuch|hörspiel|roman)|\bjugend(buch|bücher|hörbuch|roman)"
        r"|bilderbuch",
        KINDER,
    ),
    (r"true crime|literary criticism|literaturwissenschaft|\bnon-?fiction", SACHBUCH),
    (
        r"mystery|detective|thriller|suspense|\bcrime\b|spionage|espionage"
        r"|krimi(s|nalroman|nalerzählung|nalgeschichten?|nalhörspiel|nalliteratur)?\b",
        KRIMI,
    ),
    (r"fantasy|science[ -]?fiction|sci-fi|dystop", FANTASY_SF),
    (r"humor|humour|satire|satiri|comic fiction", HUMOR),
    (r"classics|classic literature|klassiker|hauptwerk vor 1945", KLASSIKER),
    (r"biograph|biografi|memoir|lebenserinnerung", BIOGRAFIE),
    (
        r"sachbuch|sachliteratur|ratgeber|\bhistory\b|\bgeschichte\b|science|philosoph"
        r"|psycholog|self-help|business|econom|politic|religion|health|cooking|travel"
        r"|\bnature\b",
        SACHBUCH,
    ),
    (r"\bfiction\b|\bnovels?\b|roman\b|romane\b|erzählung|belletristik", ROMANE),
)

_CODE_RULES = tuple((re.compile(pattern), genre) for pattern, genre in CODE_RULES)
_SUBJECT_RULES = tuple(
    (re.compile(pattern, re.IGNORECASE), genre) for pattern, genre in SUBJECT_RULES
)


def _normalize_code(code: str) -> str:
    return re.sub(r"\s+", "", code).upper()


def genre_for_code(code: str) -> str | None:
    """One classification code -> genre, or None if unknown/genreless."""
    normalized = _normalize_code(code)
    for pattern, genre in _CODE_RULES:
        if pattern.fullmatch(normalized):
            return genre
    return None


def genre_for_subject(subject: str) -> str | None:
    """One free-text subject/category -> genre, or None if unknown."""
    for pattern, genre in _SUBJECT_RULES:
        if pattern.search(subject):
            return genre
    return None


def pick_genre(candidates: Iterable[str | None]) -> str | None:
    """Most specific genre among candidates (GENRE_PRIORITY); ties go to the
    earliest candidate. Nones are skipped."""
    best: str | None = None
    for genre in candidates:
        if genre is None:
            continue
        if best is None or GENRE_PRIORITY[genre] < GENRE_PRIORITY[best]:
            best = genre
    return best


def map_categories(codes: Iterable[str] = (), subjects: Iterable[str] = ()) -> str | None:
    """All codes and subjects of one catalog record -> one genre or None.
    Codes come first, so they win ties between the broad buckets."""
    candidates = [genre_for_code(c) for c in codes]
    candidates += [genre_for_subject(s) for s in subjects]
    return pick_genre(candidates)
