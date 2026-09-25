"""Tests for the catalog lookup (docs/ARCHITEKTUR.md section 3.7), all from
fixture payloads: no test here touches the network."""

from __future__ import annotations

import io
import re
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import pytest

from faden_server import genre_lookup
from faden_server.genre_lookup import (
    MAX_CONSECUTIVE_FAILURES,
    MAX_RESPONSE_BYTES,
    USER_AGENT,
    CatalogLookup,
    LookupUnavailable,
    RequestThrottle,
    clean_author,
    clean_title,
    dnb_genres,
    dnb_isbn_url,
    dnb_query_url,
    google_genres,
    google_query_url,
    lookup,
    openlibrary_genres,
    openlibrary_query_url,
    parse_google_categories,
    parse_marc_records,
    parse_openlibrary_subjects,
)
from faden_server.genre_lookup import _http_get as real_http_get
from faden_server.genres import FANTASY_SF, KINDER, KRIMI, ROMANE, SACHBUCH

FIXTURES = Path(__file__).parent / "fixtures" / "genre"


def fixture(name: str) -> bytes:
    return (FIXTURES / name).read_bytes()


def no_throttle() -> None:
    pass


class FakeCatalogs:
    """fetch() stand-in: answers by host, records every URL."""

    def __init__(self, **by_host: bytes | Exception) -> None:
        self.by_host = by_host
        self.urls: list[str] = []

    def __call__(self, url: str) -> bytes:
        self.urls.append(url)
        host = urlsplit(url).hostname or ""
        key = {
            "services.dnb.de": "dnb",
            "www.googleapis.com": "google",
            "openlibrary.org": "openlibrary",
        }[host]
        answer = self.by_host.get(key, OSError("unreachable"))
        if isinstance(answer, Exception):
            raise answer
        return answer


# --- MARC21-xml --------------------------------------------------------------


def test_parse_marc_records_reads_codes_and_subjects_per_record():
    records = parse_marc_records(fixture("dnb_krimi.xml"))
    assert len(records) == 2
    assert records[0].codes == []
    assert records[0].subjects == ["Hörbuch"]
    # 084 with $2 rvk is not a DNB Sachgruppe and is dropped
    assert records[1].codes == ["830", "B"]
    assert records[1].subjects == [
        "(VLB-WN)1121: Hardcover, Softcover / Belletristik / Krimis, Thriller, Spionage"
    ]


def test_dnb_genres_maps_each_record():
    assert dnb_genres(fixture("dnb_krimi.xml")) == [None, KRIMI]
    assert dnb_genres(fixture("dnb_kinder.xml")) == [KINDER]
    assert dnb_genres(fixture("dnb_empty.xml")) == []


def test_parse_marc_records_without_namespaces_and_with_junk():
    payload = b"""<records><record>
        <datafield tag="084"><subfield code="a">B</subfield></datafield>
        <datafield tag="650">
            <subfield code="a"></subfield><subfield code="x">y</subfield>
        </datafield>
        <datafield><subfield code="a">no tag</subfield></datafield>
        <controlfield tag="001">x</controlfield>
    </record></records>"""
    records = parse_marc_records(payload)
    assert len(records) == 1
    assert records[0].codes == ["B"]
    assert records[0].subjects == []
    assert dnb_genres(payload) == [ROMANE]


def test_parse_marc_records_rejects_malformed_xml():
    with pytest.raises(Exception):  # noqa: B017 -- any parse error will do
        parse_marc_records(b"<searchRetrieveResponse><records>")


def test_dnb_query_url_has_only_title_and_author():
    url = dnb_query_url("Die Tote am Deich", "Anna Muster")
    parts = urlsplit(url)
    assert f"{parts.scheme}://{parts.netloc}{parts.path}" == "https://services.dnb.de/sru/dnb"
    params = parse_qs(parts.query)
    assert params["recordSchema"] == ["MARC21-xml"]
    assert params["operation"] == ["searchRetrieve"]
    assert params["query"] == ['tit="Die Tote am Deich" and per="Anna Muster"']
    assert set(params) == {
        "version",
        "operation",
        "query",
        "recordSchema",
        "recordPacking",
        "maximumRecords",
    }


def test_dnb_query_url_without_author():
    params = parse_qs(urlsplit(dnb_query_url("Mort", None)).query)
    assert params["query"] == ['tit="Mort"']


# --- Google Books / Open Library -------------------------------------------


def test_parse_google_categories_is_defensive():
    assert parse_google_categories(fixture("google_mystery.json")) == [
        [],
        ["Fiction / Mystery & Detective / General"],
    ]
    assert parse_google_categories(fixture("google_empty.json")) == []
    assert parse_google_categories(b"[]") == []
    assert parse_google_categories(b'{"items": "nope"}') == []


def test_google_genres():
    assert google_genres(fixture("google_mystery.json")) == [None, KRIMI]


def test_google_query_url():
    params = parse_qs(urlsplit(google_query_url("Mort", "Terry Pratchett")).query)
    assert params["q"] == ['intitle:"Mort" inauthor:"Terry Pratchett"']
    assert "key" not in params


def test_openlibrary_parsing_and_url():
    assert parse_openlibrary_subjects(fixture("openlibrary_juvenile.json")) == [
        ["Fiction", "Magic", "Juvenile fiction", "Fantasy fiction"]
    ]
    assert openlibrary_genres(fixture("openlibrary_juvenile.json")) == [KINDER]
    assert parse_openlibrary_subjects(b'{"docs": [1, {"subject": "x"}]}') == [[]]
    params = parse_qs(urlsplit(openlibrary_query_url("Mort", "Terry Pratchett")).query)
    assert params == {
        "title": ["Mort"],
        "author": ["Terry Pratchett"],
        "fields": ["subject"],
        "limit": ["5"],
    }


# --- query terms -------------------------------------------------------------


def test_clean_title_and_author():
    assert clean_title("Die Tote am Deich (Ungekürzt) [Hörbuch]") == "Die Tote am Deich"
    assert clean_title('Der "Titel"*?') == "Der Titel"
    assert clean_title("(nur Klammern)") == "nur Klammern"
    assert clean_title("") is None
    assert clean_title(None) is None
    assert clean_author("Stephen King; David Nathan") == "Stephen King"
    assert clean_author("Anna Muster/Sprecher X") == "Anna Muster"
    assert clean_author(None) is None
    assert len(clean_title("x" * 1000)) == 200


# --- lookup(): source order and failure handling ----------------------------


def test_lookup_uses_dnb_first_and_stops_there():
    fetch = FakeCatalogs(dnb=fixture("dnb_krimi.xml"), google=fixture("google_mystery.json"))
    assert lookup("Die Tote am Deich", "Anna Muster", fetch=fetch, throttle=no_throttle) == (
        KRIMI,
        "dnb",
    )
    assert len(fetch.urls) == 1


def test_lookup_falls_back_to_google_when_dnb_has_no_genre():
    fetch = FakeCatalogs(dnb=fixture("dnb_empty.xml"), google=fixture("google_mystery.json"))
    assert lookup("Die Tote am Deich", None, fetch=fetch, throttle=no_throttle) == (
        KRIMI,
        "google",
    )


def test_lookup_falls_back_to_openlibrary():
    fetch = FakeCatalogs(
        dnb=OSError("timed out"),
        google=b"not json",
        openlibrary=fixture("openlibrary_juvenile.json"),
    )
    assert lookup("Mort", "Terry Pratchett", fetch=fetch, throttle=no_throttle) == (
        KINDER,
        "openlibrary",
    )
    assert len(fetch.urls) == 3


def test_lookup_returns_none_when_reachable_catalogs_know_nothing():
    fetch = FakeCatalogs(dnb=fixture("dnb_empty.xml"), google=fixture("google_empty.json"))
    assert lookup("Unbekannt", None, fetch=fetch, throttle=no_throttle) is None


def test_lookup_raises_unavailable_only_when_no_catalog_answers():
    fetch = FakeCatalogs()  # everything unreachable
    with pytest.raises(LookupUnavailable):
        lookup("Mort", None, fetch=fetch, throttle=no_throttle)


def test_lookup_without_title_asks_nobody():
    fetch = FakeCatalogs()
    assert lookup(None, "Someone", fetch=fetch, throttle=no_throttle) is None
    assert lookup("  ", "Someone", fetch=fetch, throttle=no_throttle) is None
    assert fetch.urls == []


def test_lookup_sends_only_title_and_author():
    fetch = FakeCatalogs()
    with pytest.raises(LookupUnavailable):
        lookup("Mort", "Terry Pratchett", fetch=fetch, throttle=no_throttle)
    assert [urlsplit(u).hostname for u in fetch.urls] == [
        "services.dnb.de",
        "www.googleapis.com",
        "openlibrary.org",
    ]
    constants = {"1.1", "searchRetrieve", "MARC21-xml", "xml", "5", "books", "subject"}
    for url in fetch.urls:
        for values in parse_qs(urlsplit(url).query).values():
            for value in values:
                if value in constants:
                    continue
                rest = re.sub(r'(tit|per)="[^"]*"|in(title|author):"[^"]*"|\sand\s|\s', "", value)
                assert rest in ("", "Mort", "TerryPratchett"), value
                assert "Mort" in value or "Terry Pratchett" in value


def test_lookup_throttles_every_request():
    calls = []
    fetch = FakeCatalogs(dnb=fixture("dnb_empty.xml"))
    assert lookup("Mort", None, fetch=fetch, throttle=lambda: calls.append(1)) is None
    assert len(calls) == len(fetch.urls) == 3


# --- throttle and HTTP -------------------------------------------------------


def test_request_throttle_spaces_calls_one_second_apart():
    now = [100.0]
    sleeps: list[float] = []

    def clock() -> float:
        return now[0]

    def sleep(seconds: float) -> None:
        sleeps.append(seconds)
        now[0] += seconds

    throttle = RequestThrottle(1.0, clock=clock, sleep=sleep)
    throttle()  # first call: no wait
    now[0] += 0.25
    throttle()  # 0.75 s left
    throttle()  # a full second
    now[0] += 5
    throttle()  # long idle: no wait
    assert sleeps == [pytest.approx(0.75), pytest.approx(1.0)]


class _FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False


def test_http_get_sends_user_agent_and_timeout(monkeypatch):
    seen = {}

    def fake_urlopen(request, timeout):
        seen["ua"] = request.get_header("User-agent")
        seen["timeout"] = timeout
        return _FakeResponse(b"ok")

    monkeypatch.setattr(genre_lookup.urllib.request, "urlopen", fake_urlopen)
    assert real_http_get("https://example.invalid/") == b"ok"
    assert seen == {"ua": USER_AGENT, "timeout": 10.0}
    assert USER_AGENT.startswith("Faden/")


def test_http_get_caps_the_response_size(monkeypatch):
    monkeypatch.setattr(
        genre_lookup.urllib.request,
        "urlopen",
        lambda request, timeout: _FakeResponse(b"x" * (MAX_RESPONSE_BYTES + 10)),
    )
    with pytest.raises(ValueError):
        real_http_get("https://example.invalid/")


def test_fantasy_in_google_fixture_shape():
    payload = b'{"items": [{"volumeInfo": {"categories": ["Fiction / Fantasy / Epic"]}}]}'
    assert google_genres(payload) == [FANTASY_SF]


# --- real DNB answer (by ISBN) --------------------------------------------------


def test_real_dnb_isbn_answer_parses_to_romane():
    """Trimmed real answer for num=9783837121995 ("Der Medicus"): the DNB
    Sachgruppen sit in 082 ($2 23sdnb, several $a); 084 $2 sswd and the GND
    topics are only logged."""
    [record] = parse_marc_records(fixture("dnb_medicus_isbn.xml"))
    assert record.title == "Der Medicus"  # non-filing markers stripped
    assert record.codes == ["810", "B"]
    assert record.subjects == []
    assert record.ignored == [
        "084 $a 9.1b $a 27.1b $a 4.7p $a 27.20p $a 27.1a $q DE-101 $2 sswd",
        "600 $a Avicenna $2 gnd",
        "648 $a Geschichte 1021-1025 $2 gnd",
        "650 $a Waisenkind $2 gnd",
        "650 $a Arzt $2 gnd",
        "651 $a London $2 gnd",
    ]
    assert dnb_genres(fixture("dnb_medicus_isbn.xml")) == [ROMANE]


def test_dnb_logs_the_raw_values_at_debug(caplog):
    with caplog.at_level("DEBUG", logger="faden_server.genre_lookup"):
        dnb_genres(fixture("dnb_medicus_isbn.xml"))
    text = caplog.text
    assert "'Der Medicus'" in text
    assert "codes=['810', 'B']" in text
    assert "650 $a Arzt $2 gnd" in text


def test_gnd_topics_are_no_genre():
    payload = b"""<records><record>
        <datafield tag="650"><subfield code="a">Kriminalroman</subfield></datafield>
        <datafield tag="650"><subfield code="a">Philosophie</subfield></datafield>
        <datafield tag="689"><subfield code="a">Biografie</subfield></datafield>
    </record></records>"""
    assert dnb_genres(payload) == [None]


@pytest.mark.parametrize(
    ("codes", "genre"),
    [
        (["810", "B"], ROMANE),
        (["830", "B", "K"], KINDER),
        (["920"], "Biografie"),
        (["590"], SACHBUCH),
        (["S"], None),
    ],
)
def test_dnb_sachgruppen_in_082(codes, genre):
    subfields = "".join(f'<subfield code="a">{c}</subfield>' for c in codes)
    payload = (
        f'<records><record><datafield tag="082">{subfields}'
        f'<subfield code="2">23sdnb</subfield></datafield></record></records>'
    ).encode()
    assert dnb_genres(payload) == [genre]


def test_parse_marc_records_packed_as_string():
    inner = (
        '<record xmlns="http://www.loc.gov/MARC21/slim"><datafield tag="082">'
        '<subfield code="a">B</subfield></datafield></record>'
    )
    escaped = inner.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    payload = (
        '<searchRetrieveResponse xmlns="http://www.loc.gov/zing/srw/"><records><record>'
        f"<recordPacking>string</recordPacking><recordData>{escaped}</recordData>"
        "</record></records></searchRetrieveResponse>"
    ).encode()
    assert dnb_genres(payload) == [ROMANE]


def test_dnb_isbn_url_uses_the_num_index():
    params = parse_qs(urlsplit(dnb_isbn_url("9783837121995")).query)
    assert params["query"] == ["num=9783837121995"]
    assert params["recordSchema"] == ["MARC21-xml"]


# --- ISBN first ------------------------------------------------------------------


def test_lookup_asks_the_dnb_by_isbn_first():
    fetch = FakeCatalogs(dnb=fixture("dnb_medicus_isbn.xml"))
    result = lookup(
        "Der Medicus", "Noah Gordon", "9783837121995", fetch=fetch, throttle=no_throttle
    )
    assert result == (ROMANE, "dnb")
    assert len(fetch.urls) == 1
    assert parse_qs(urlsplit(fetch.urls[0]).query)["query"] == ["num=9783837121995"]


def test_lookup_goes_on_to_the_title_when_the_isbn_gives_no_genre():
    answers = iter([fixture("dnb_empty.xml"), fixture("dnb_krimi.xml")])
    urls = []

    def fetch(url):
        urls.append(url)
        return next(answers)

    result = lookup("Die Tote am Deich", None, "9783837121995", fetch=fetch, throttle=no_throttle)
    assert result == (KRIMI, "dnb")
    queries = [parse_qs(urlsplit(u).query)["query"][0] for u in urls]
    assert queries == ["num=9783837121995", 'tit="Die Tote am Deich"']


def test_lookup_with_only_an_isbn_asks_only_the_dnb():
    fetch = FakeCatalogs(dnb=fixture("dnb_empty.xml"))
    assert lookup(None, None, "9783837121995", fetch=fetch, throttle=no_throttle) is None
    assert [urlsplit(u).hostname for u in fetch.urls] == ["services.dnb.de"]


def test_the_isbn_goes_only_to_the_dnb():
    fetch = FakeCatalogs()
    with pytest.raises(LookupUnavailable):
        lookup("Mort", None, "9783837121995", fetch=fetch, throttle=no_throttle)
    for url in fetch.urls:
        if urlsplit(url).hostname != "services.dnb.de":
            assert "9783837121995" not in url


# --- one pass: unreachable sources ----------------------------------------------


def test_a_pass_skips_a_source_after_consecutive_failures(caplog):
    fetch = FakeCatalogs(
        dnb=OSError("timed out"),
        google=fixture("google_empty.json"),
        openlibrary=b'{"docs": []}',
    )
    session = CatalogLookup(fetch=fetch, throttle=no_throttle)
    with caplog.at_level("INFO", logger="faden_server.genre_lookup"):
        for _ in range(4):
            assert session("Mort", None) is None
    dnb_calls = [u for u in fetch.urls if "dnb.de" in u]
    assert len(dnb_calls) == MAX_CONSECUTIVE_FAILURES == 2
    assert session.skipped == ["dnb"]
    assert caplog.text.count("dnb unreachable") == 1
    assert caplog.text.count("skipped for the rest of this pass") == 1


def test_an_answer_resets_the_failure_count():
    answers = iter([OSError("blip"), fixture("dnb_empty.xml"), OSError("blip")])

    def fetch(url):
        if "dnb.de" not in url:
            return fixture("google_empty.json")
        answer = next(answers)
        if isinstance(answer, Exception):
            raise answer
        return answer

    session = CatalogLookup(fetch=fetch, throttle=no_throttle)
    for _ in range(3):
        session("Mort", None)
    assert session.skipped == []


def test_a_pass_with_every_source_skipped_is_unavailable():
    session = CatalogLookup(fetch=FakeCatalogs(), throttle=no_throttle)
    for _ in range(MAX_CONSECUTIVE_FAILURES):
        with pytest.raises(LookupUnavailable):
            session("Mort", None)
    calls = len(session._fetch.urls)
    with pytest.raises(LookupUnavailable):
        session("Eric", None)
    assert len(session._fetch.urls) == calls  # nobody asked any more
