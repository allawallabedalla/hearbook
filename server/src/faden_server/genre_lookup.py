"""Genre lookup in public book catalogs (docs/ARCHITEKTUR.md section 3.7).

`lookup(title, author)` asks the Deutsche Nationalbibliothek (SRU, MARC21-
xml), then Google Books, then Open Library, and returns the first genre one
of them yields, mapped by the pure `genres` module. Only the book's title
and author leave the server; no key, no token, no file data.

Every request goes through one process-wide throttle (at most one request
per second, across all sources), has a 10 s timeout, a size cap, and sends
`User-Agent: Faden/<version>`. HTTP, network and parse errors of a single
source are logged and skip to the next source; `lookup` never raises them.
The one exception it does raise is `LookupUnavailable`, when *no* source
could be reached at all (typically: the NAS has no internet right now), so
the caller can retry later instead of recording the book as checked.
"""

from __future__ import annotations

import json
import logging
import re
import threading
import time
import urllib.request
import xml.etree.ElementTree as ET
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from importlib import metadata
from urllib.parse import quote, urlencode

from .genres import map_categories

logger = logging.getLogger(__name__)

DNB_SRU_URL = "https://services.dnb.de/sru/dnb"
GOOGLE_BOOKS_URL = "https://www.googleapis.com/books/v1/volumes"
OPEN_LIBRARY_URL = "https://openlibrary.org/search.json"

TIMEOUT_S = 10.0
MIN_INTERVAL_S = 1.0
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
MAX_RECORDS = 5
MAX_TERM_CHARS = 200

Fetch = Callable[[str], bytes]
Throttle = Callable[[], None]


class LookupUnavailable(Exception):
    """No catalog could be reached; the book was not actually checked."""


def _version() -> str:
    try:
        return metadata.version("faden-server")
    except metadata.PackageNotFoundError:
        return "0"


USER_AGENT = f"Faden/{_version()}"


class RequestThrottle:
    """Blocks until at least `min_interval_s` passed since the previous
    call. Thread-safe; one instance is shared by all sources."""

    def __init__(
        self,
        min_interval_s: float,
        *,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self._min_interval_s = min_interval_s
        self._clock = clock
        self._sleep = sleep
        self._lock = threading.Lock()
        self._next_allowed: float | None = None

    def __call__(self) -> None:
        with self._lock:
            if self._next_allowed is not None:
                wait = self._next_allowed - self._clock()
                if wait > 0:
                    self._sleep(wait)
            self._next_allowed = self._clock() + self._min_interval_s


_default_throttle: Throttle = RequestThrottle(MIN_INTERVAL_S)


def _http_get(url: str) -> bytes:
    request = urllib.request.Request(
        url, headers={"User-Agent": USER_AGENT, "Accept": "application/json, application/xml"}
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT_S) as response:
        body = response.read(MAX_RESPONSE_BYTES + 1)
    if len(body) > MAX_RESPONSE_BYTES:
        raise ValueError(f"response larger than {MAX_RESPONSE_BYTES} bytes")
    return body


# --- query terms ------------------------------------------------------------

_BRACKETS = re.compile(r"\([^)]*\)|\[[^\]]*\]")
# CQL/Google syntax characters: quotes, escapes, wildcards, masking.
_SPECIAL = re.compile(r'["\\*?^]')


def _squash(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip()


def clean_title(title: str | None) -> str | None:
    """Drop "(Ungekürzt)"/"[Hörbuch]"-style additions and query syntax."""
    if not title:
        return None
    cleaned = _squash(_SPECIAL.sub(" ", _BRACKETS.sub(" ", title)))
    if not cleaned:  # the whole title was in brackets: keep its words
        cleaned = _squash(_SPECIAL.sub(" ", re.sub(r"[()\[\]]", " ", title)))
    return cleaned[:MAX_TERM_CHARS] or None


def clean_author(author: str | None) -> str | None:
    """First name of a TPE1 like "Stephen King; David Nathan" or "A/B"."""
    if not author:
        return None
    first = re.split(r"[;/]", author, maxsplit=1)[0]
    cleaned = _squash(_SPECIAL.sub(" ", _BRACKETS.sub(" ", first)))
    return cleaned[:MAX_TERM_CHARS] or None


# --- DNB SRU / MARC21-xml ---------------------------------------------------


def dnb_query_url(title: str, author: str | None) -> str:
    query = f'tit="{title}"'
    if author:
        query += f' and per="{author}"'
    params = {
        "version": "1.1",
        "operation": "searchRetrieve",
        "query": query,
        "recordSchema": "MARC21-xml",
        "maximumRecords": str(MAX_RECORDS),
    }
    return f"{DNB_SRU_URL}?{urlencode(params, quote_via=quote)}"


@dataclass
class MarcCategories:
    """Classification codes and subject strings of one MARC record."""

    codes: list[str] = field(default_factory=list)
    subjects: list[str] = field(default_factory=list)


# 082/083: DDC numbers (083 also carries DNB Sachgruppen such as "B", "830").
_MARC_DDC_TAGS = frozenset({"082", "083"})
# 084: other classifications; only DNB Sachgruppen/DDC are used (by $2).
_MARC_OTHER_CLASS_TAG = "084"
# 650 topical term, 653 uncontrolled terms (VLB-Warengruppen), 655 genre/
# form, 689 RSWK subject chain.
_MARC_SUBJECT_TAGS = frozenset({"650", "653", "655", "689"})


def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _subfields(datafield: ET.Element) -> list[tuple[str, str]]:
    out = []
    for sub in datafield:
        if _local(sub.tag) == "subfield" and sub.text:
            out.append((sub.get("code", ""), sub.text.strip()))
    return out


def _is_marc_record(element: ET.Element) -> bool:
    return _local(element.tag) == "record" and any(
        _local(child.tag) == "datafield" for child in element
    )


def parse_marc_records(payload: bytes) -> list[MarcCategories]:
    """All MARC records of an SRU response, in response order. Tolerates
    missing namespaces, unknown fields and empty subfields."""
    root = ET.fromstring(payload)
    records = []
    for element in root.iter():
        if not _is_marc_record(element):
            continue
        record = MarcCategories()
        for datafield in element:
            if _local(datafield.tag) != "datafield":
                continue
            tag = datafield.get("tag", "")
            subs = _subfields(datafield)
            values_a = [value for code, value in subs if code == "a" and value]
            if tag in _MARC_DDC_TAGS:
                record.codes += values_a
            elif tag == _MARC_OTHER_CLASS_TAG:
                schemes = [value.lower() for code, value in subs if code == "2"]
                if not schemes or any("sdnb" in s or "ddc" in s for s in schemes):
                    record.codes += values_a
            elif tag in _MARC_SUBJECT_TAGS:
                record.subjects += values_a
        records.append(record)
    return records


def dnb_genres(payload: bytes) -> list[str | None]:
    return [map_categories(r.codes, r.subjects) for r in parse_marc_records(payload)]


# --- Google Books ------------------------------------------------------------


def google_query_url(title: str, author: str | None) -> str:
    query = f'intitle:"{title}"'
    if author:
        query += f' inauthor:"{author}"'
    params = {"q": query, "maxResults": str(MAX_RECORDS), "printType": "books"}
    return f"{GOOGLE_BOOKS_URL}?{urlencode(params, quote_via=quote)}"


def _strings(value: object) -> list[str]:
    if not isinstance(value, list):
        return []
    return [v for v in value if isinstance(v, str)]


def parse_google_categories(payload: bytes) -> list[list[str]]:
    """`volumeInfo.categories` (and `mainCategory`) per item, in order."""
    data = json.loads(payload)
    items = data.get("items") if isinstance(data, dict) else None
    out = []
    for item in items if isinstance(items, list) else []:
        info = item.get("volumeInfo") if isinstance(item, dict) else None
        if not isinstance(info, dict):
            continue
        categories = _strings(info.get("categories"))
        main = info.get("mainCategory")
        if isinstance(main, str):
            categories.insert(0, main)
        out.append(categories)
    return out


def google_genres(payload: bytes) -> list[str | None]:
    return [map_categories(subjects=c) for c in parse_google_categories(payload)]


# --- Open Library ------------------------------------------------------------


def openlibrary_query_url(title: str, author: str | None) -> str:
    params = {"title": title, "fields": "subject", "limit": str(MAX_RECORDS)}
    if author:
        params["author"] = author
    return f"{OPEN_LIBRARY_URL}?{urlencode(params, quote_via=quote)}"


def parse_openlibrary_subjects(payload: bytes) -> list[list[str]]:
    data = json.loads(payload)
    docs = data.get("docs") if isinstance(data, dict) else None
    return [
        _strings(doc.get("subject"))
        for doc in (docs if isinstance(docs, list) else [])
        if isinstance(doc, dict)
    ]


def openlibrary_genres(payload: bytes) -> list[str | None]:
    return [map_categories(subjects=s) for s in parse_openlibrary_subjects(payload)]


# --- lookup ------------------------------------------------------------------


@dataclass(frozen=True)
class Source:
    """One catalog: `name` is stored as books.genre_source."""

    name: str
    url: Callable[[str, str | None], str]
    genres: Callable[[bytes], list[str | None]]


SOURCES: tuple[Source, ...] = (
    Source("dnb", dnb_query_url, dnb_genres),
    Source("google", google_query_url, google_genres),
    Source("openlibrary", openlibrary_query_url, openlibrary_genres),
)


def lookup(
    title: str | None,
    author: str | None,
    *,
    fetch: Fetch | None = None,
    throttle: Throttle | None = None,
    sources: Sequence[Source] = SOURCES,
) -> tuple[str, str] | None:
    """(genre, source) of the first source whose best-matching record maps
    to a genre, else None. Raises only LookupUnavailable (see module doc)."""
    clean = clean_title(title)
    if clean is None:
        return None
    who = clean_author(author)
    do_fetch = fetch if fetch is not None else _http_get
    wait = throttle if throttle is not None else _default_throttle

    unreachable = 0
    for source in sources:
        try:
            url = source.url(clean, who)
            wait()
            payload = do_fetch(url)
        except Exception as exc:
            unreachable += 1
            logger.info("genre lookup: %s unreachable: %s", source.name, exc)
            continue
        try:
            genres = source.genres(payload)
        except Exception as exc:
            logger.warning("genre lookup: %s answer not understood: %s", source.name, exc)
            continue
        genre = next((g for g in genres if g is not None), None)
        if genre is not None:
            return (genre, source.name)

    if sources and unreachable == len(sources):
        raise LookupUnavailable("no genre catalog reachable")
    return None
