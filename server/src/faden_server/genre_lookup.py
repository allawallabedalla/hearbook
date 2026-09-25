"""Genre lookup in public book catalogs (docs/ARCHITEKTUR.md section 3.7).

`lookup(title, author, isbn)` asks the Deutsche Nationalbibliothek (SRU,
MARC21-xml; by ISBN first, then by title and author), then Google Books,
then Open Library, and returns the first genre one of them yields, mapped
by the pure `genres` module. Only the book's title, author and ISBN leave
the server; no key, no token, no file data.

Every request goes through one process-wide throttle (at most one request
per second, across all sources), has a 10 s timeout, a size cap, and sends
`User-Agent: Faden/<version>`. HTTP, network and parse errors of a single
source are logged and skip to the next source; `lookup` never raises them.
The one exception it does raise is `LookupUnavailable`, when *no* source
could be reached at all (typically: the NAS has no internet right now), so
the caller can retry later instead of recording the book as checked.

`CatalogLookup` is one pass's view of the catalogs: it logs a source's
first failure once and skips a source for the rest of the pass after
MAX_CONSECUTIVE_FAILURES failed requests in a row. The raw classification
codes and subjects of every answer are logged at DEBUG, so real catalog
answers can be inspected (FADEN_LOG_LEVEL=DEBUG).
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
MAX_CONSECUTIVE_FAILURES = 2

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


def _dnb_url(query: str) -> str:
    params = {
        "version": "1.1",
        "operation": "searchRetrieve",
        "query": query,
        "recordSchema": "MARC21-xml",
        "recordPacking": "xml",
        "maximumRecords": str(MAX_RECORDS),
    }
    return f"{DNB_SRU_URL}?{urlencode(params, quote_via=quote)}"


def dnb_query_url(title: str, author: str | None) -> str:
    query = f'tit="{title}"'
    if author:
        query += f' and per="{author}"'
    return _dnb_url(query)


def dnb_isbn_url(isbn: str) -> str:
    """`num` is the DNB's index for ISBN/ISSN/ISMN (checked against a real
    answer: num=9783837121995 finds "Der Medicus")."""
    return _dnb_url(f"num={isbn}")


@dataclass
class MarcCategories:
    """Classification codes and subject strings of one MARC record, plus
    everything classification-like that was seen but not used (for the
    DEBUG log)."""

    codes: list[str] = field(default_factory=list)
    subjects: list[str] = field(default_factory=list)
    ignored: list[str] = field(default_factory=list)
    title: str | None = None


# 082/083: DDC numbers and DNB Sachgruppen. The DNB puts its Sachgruppen in
# 082 with $2 "23sdnb" and several $a (real answer for "Der Medicus": 082
# $a 810 $a B $2 23sdnb); every $a counts.
_MARC_DDC_TAGS = frozenset({"082", "083"})
# 084: other classifications; only DNB Sachgruppen/DDC are used (by $2).
# The DNB's 084 with $2 "sswd" (SWD notations like "9.1b") is ignored.
_MARC_OTHER_CLASS_TAG = "084"
# 653 uncontrolled terms (VLB-Warengruppen), 655 genre/form. GND topics
# (600/648/650/651/689: persons, periods, topics, places) describe what a
# book is about, not its genre ("Arzt", "Geschichte 1021-1025" for a novel),
# and are only logged.
_MARC_SUBJECT_TAGS = frozenset({"653", "655"})
_MARC_TOPIC_TAGS = frozenset({"600", "648", "650", "651", "689"})
# MARC non-filing markers around a leading article ("\x98Der\x9c Medicus").
_NON_FILING = str.maketrans("", "", "\x98\x9c")


def _local(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _subfields(datafield: ET.Element) -> list[tuple[str, str]]:
    out = []
    for sub in datafield:
        if _local(sub.tag) == "subfield" and sub.text and sub.text.strip():
            out.append((sub.get("code", ""), sub.text.strip()))
    return out


def _is_marc_record(element: ET.Element) -> bool:
    return _local(element.tag) == "record" and any(
        _local(child.tag) == "datafield" for child in element
    )


def _marc_records(root: ET.Element) -> list[ET.Element]:
    """MARC <record>s in document order, also when an SRU server packed
    them as escaped text (recordPacking=string) inside <recordData>."""
    records = []
    for element in root.iter():
        if _is_marc_record(element):
            records.append(element)
        elif (
            _local(element.tag) == "recordData"
            and len(element) == 0
            and element.text
            and "<" in element.text
        ):
            records += [r for r in ET.fromstring(element.text.strip()).iter() if _is_marc_record(r)]
    return records


def _describe(tag: str, subs: list[tuple[str, str]]) -> str:
    return tag + " " + " ".join(f"${code} {value}" for code, value in subs)


def parse_marc_records(payload: bytes) -> list[MarcCategories]:
    """All MARC records of an SRU response, in response order. Tolerates
    missing namespaces, unknown fields and empty subfields."""
    root = ET.fromstring(payload)
    records = []
    for element in _marc_records(root):
        record = MarcCategories()
        for datafield in element:
            if _local(datafield.tag) != "datafield":
                continue
            tag = datafield.get("tag", "")
            subs = _subfields(datafield)
            values_a = [value for code, value in subs if code == "a"]
            if tag == "245" and values_a:
                record.title = _squash(values_a[0].translate(_NON_FILING))
            elif tag in _MARC_DDC_TAGS:
                record.codes += values_a
            elif tag == _MARC_OTHER_CLASS_TAG:
                schemes = [value.lower() for code, value in subs if code == "2"]
                if not schemes or any("sdnb" in s or "ddc" in s for s in schemes):
                    record.codes += values_a
                else:
                    record.ignored.append(_describe(tag, subs))
            elif tag in _MARC_SUBJECT_TAGS:
                record.subjects += values_a
            elif tag in _MARC_TOPIC_TAGS:
                record.ignored.append(_describe(tag, subs))
        records.append(record)
    return records


def dnb_genres(payload: bytes) -> list[str | None]:
    out = []
    for record in parse_marc_records(payload):
        genre = map_categories(record.codes, record.subjects)
        logger.debug(
            "genre lookup: dnb record %r: codes=%s subjects=%s ignored=%s -> %s",
            record.title,
            record.codes,
            record.subjects,
            record.ignored,
            genre,
        )
        out.append(genre)
    return out


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
    out = []
    for categories in parse_google_categories(payload):
        genre = map_categories(subjects=categories)
        logger.debug("genre lookup: google categories=%s -> %s", categories, genre)
        out.append(genre)
    return out


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
    out = []
    for subjects in parse_openlibrary_subjects(payload):
        genre = map_categories(subjects=subjects)
        logger.debug("genre lookup: openlibrary subjects=%s -> %s", subjects[:20], genre)
        out.append(genre)
    return out


# --- lookup ------------------------------------------------------------------


def _dnb_urls(title: str | None, author: str | None, isbn: str | None) -> list[str]:
    urls = []
    if isbn:
        urls.append(dnb_isbn_url(isbn))
    if title:
        urls.append(dnb_query_url(title, author))
    return urls


def _google_urls(title: str | None, author: str | None, isbn: str | None) -> list[str]:
    return [google_query_url(title, author)] if title else []


def _openlibrary_urls(title: str | None, author: str | None, isbn: str | None) -> list[str]:
    return [openlibrary_query_url(title, author)] if title else []


@dataclass(frozen=True)
class Source:
    """One catalog: `name` is stored as books.genre_source. `urls` gives the
    queries for a book, tried in order until one yields a genre."""

    name: str
    urls: Callable[[str | None, str | None, str | None], list[str]]
    genres: Callable[[bytes], list[str | None]]


SOURCES: tuple[Source, ...] = (
    Source("dnb", _dnb_urls, dnb_genres),
    Source("google", _google_urls, google_genres),
    Source("openlibrary", _openlibrary_urls, openlibrary_genres),
)


class CatalogLookup:
    """Looks books up for one pass. Remembers, per source, how many
    requests in a row failed: the first failure is logged, and after
    MAX_CONSECUTIVE_FAILURES the source is skipped for the rest of the pass
    (one unreachable catalog must not cost 10 s per book)."""

    def __init__(
        self,
        *,
        fetch: Fetch | None = None,
        throttle: Throttle | None = None,
        sources: Sequence[Source] = SOURCES,
    ) -> None:
        self._fetch = fetch
        self._throttle = throttle
        self._sources = tuple(sources)
        self._failures: dict[str, int] = {}
        self._logged: set[str] = set()

    @property
    def skipped(self) -> list[str]:
        return [name for name, n in self._failures.items() if n >= MAX_CONSECUTIVE_FAILURES]

    def _failed(self, source: str, exc: Exception) -> None:
        self._failures[source] = self._failures.get(source, 0) + 1
        if source not in self._logged:
            self._logged.add(source)
            logger.info("genre lookup: %s unreachable: %s", source, exc)
        if self._failures[source] == MAX_CONSECUTIVE_FAILURES:
            logger.info(
                "genre lookup: %s failed %d times in a row, skipped for the rest of this pass",
                source,
                MAX_CONSECUTIVE_FAILURES,
            )

    def __call__(
        self, title: str | None, author: str | None, isbn: str | None = None
    ) -> tuple[str, str] | None:
        """(genre, source) of the first source whose best-matching record
        maps to a genre, else None. Raises only LookupUnavailable."""
        clean = clean_title(title)
        who = clean_author(author)
        isbn = isbn or None
        # Resolved at call time, so tests can patch the module's defaults.
        do_fetch = self._fetch if self._fetch is not None else _http_get
        wait = self._throttle if self._throttle is not None else _default_throttle

        asked = False
        answered = False
        for source in self._sources:
            urls = source.urls(clean, who, isbn)
            if not urls:
                continue
            asked = True
            if self._failures.get(source.name, 0) >= MAX_CONSECUTIVE_FAILURES:
                continue
            for url in urls:
                try:
                    wait()
                    payload = do_fetch(url)
                except Exception as exc:
                    self._failed(source.name, exc)
                    break
                answered = True
                self._failures[source.name] = 0
                try:
                    genres = source.genres(payload)
                except Exception as exc:
                    logger.warning("genre lookup: %s answer not understood: %s", source.name, exc)
                    logger.debug("genre lookup: %s answer starts %r", source.name, payload[:300])
                    continue
                if not genres:
                    logger.debug("genre lookup: %s has no record for %s", source.name, url)
                genre = next((g for g in genres if g is not None), None)
                if genre is not None:
                    return (genre, source.name)

        if asked and not answered:
            raise LookupUnavailable("no genre catalog reachable")
        return None


def lookup(
    title: str | None,
    author: str | None,
    isbn: str | None = None,
    *,
    fetch: Fetch | None = None,
    throttle: Throttle | None = None,
    sources: Sequence[Source] = SOURCES,
) -> tuple[str, str] | None:
    """One book, with a fresh CatalogLookup (see there)."""
    return CatalogLookup(fetch=fetch, throttle=throttle, sources=sources)(title, author, isbn)
