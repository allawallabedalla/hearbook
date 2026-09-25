"""Tests for metadata.py, docs/ARCHITEKTUR.md section 3.6."""

from __future__ import annotations

import pytest
from mutagen.id3 import APIC, ID3, TALB, TIT2, TPE1, TPE2, TPOS, TRCK, TXXX

from faden_server.metadata import (
    BookInfo,
    BookTags,
    clean_value,
    extract_embedded_cover,
    find_cover_file,
    is_junk,
    is_valid_isbn13,
    isbn_in_text,
    match_key,
    narrator_of,
    read_book_tags,
    read_track_tags,
    resolve_book_info,
)

from .conftest import requires_ffmpeg


def _tag(path, **frames):
    try:
        tags = ID3(path)
    except Exception:
        tags = ID3()
    for frame in frames.values():
        tags.add(frame)
    tags.save(path, v2_version=4)


@requires_ffmpeg
def test_read_track_tags_disc_and_track(make_mp3):
    p = make_mp3()
    _tag(p, tpos=TPOS(text=["1/2"]), trck=TRCK(text=["3/10"]), tit2=TIT2(text=["Kapitel 3"]))
    tags = read_track_tags(p)
    assert tags.disc == 1
    assert tags.track == 3
    assert tags.title == "Kapitel 3"


@requires_ffmpeg
def test_read_track_tags_missing_frames_are_none(make_mp3):
    p = make_mp3()
    tags = read_track_tags(p)
    assert tags.disc is None
    assert tags.track is None
    assert tags.title is None


@requires_ffmpeg
def test_read_track_tags_plain_track_number_without_slash(make_mp3):
    p = make_mp3()
    _tag(p, trck=TRCK(text=["7"]))
    tags = read_track_tags(p)
    assert tags.track == 7


@requires_ffmpeg
def test_read_book_tags_album_and_artist(make_mp3):
    p = make_mp3()
    _tag(p, talb=TALB(text=["Mort"]), tpe1=TPE1(text=["Terry Pratchett"]))
    tags = read_book_tags(p)
    assert (tags.album, tags.artist) == ("Mort", "Terry Pratchett")
    assert (tags.album_artist, tags.track_title, tags.isbn) == (None, None, None)


@requires_ffmpeg
def test_read_book_tags_album_artist_title_and_isbn(make_mp3):
    p = make_mp3()
    _tag(
        p,
        tpe2=TPE2(text=["Wolfram Huke"]),
        tit2=TIT2(text=["36 Stunden 41"]),
        comment=TXXX(desc="Comment", text=["http://etwasistimmer.de"]),
        isbn=TXXX(desc="ISBN", text=["978-3-8371-2199-5"]),
    )
    tags = read_book_tags(p)
    assert tags.album_artist == "Wolfram Huke"
    assert tags.track_title == "36 Stunden 41"
    assert tags.isbn == "978-3-8371-2199-5"


def test_read_book_tags_of_an_untagged_file(tmp_path):
    p = tmp_path / "x.mp3"
    p.write_bytes(b"not an mp3")
    assert read_book_tags(p) == BookTags()


# --- title / author resolution (3.6), from the real library ------------------

HORVATH_TAGS = BookTags(
    album="Ödön von Horváth - 36 Stunden. Die Geschichte vom Fräulein Pollinger",
    artist="Sprecher: Wolfram Huke",
    album_artist="Wolfram Huke",
    track_title="36 Stunden 41",
)

RESOLVE_CASES = [
    # --- <Author>/<Book>/ (vorleser.net downloads) ---
    pytest.param(
        "Ödön von Horváth",
        "36 Stunden Die Geschichte vom Fräulein Pollinger",
        HORVATH_TAGS,
        BookInfo(
            "36 Stunden. Die Geschichte vom Fräulein Pollinger",
            "Ödön von Horváth",
            narrator="Wolfram Huke",
        ),
        id="album-with-author-prefix-gives-the-punctuation",
    ),
    pytest.param(
        "Ludwig Bechstein",
        "Das Märchen vom Schlaraffenland",
        BookTags(album="vorleser.net", artist="Albrecht Kaltenhäuser"),
        BookInfo("Das Märchen vom Schlaraffenland", "Ludwig Bechstein"),
        id="site-as-album-and-narrator-as-artist",
    ),
    pytest.param(
        "Brüder Grimm",
        "Rumpelstilzchen",
        BookTags(album="www.vorleser.net", artist="Sprecher: Hans Muster", track_title="Teil 1"),
        BookInfo("Rumpelstilzchen", "Brüder Grimm", narrator="Hans Muster"),
        id="www-site-as-album",
    ),
    pytest.param(
        "Christian Morgenstern",
        "Das aesthetische Wiesel",
        BookTags(
            album="Christian Morgenstern: Gedichte",
            artist="Albrecht Kaltenhäuser",
            track_title="Das ästhetische Wiesel",
        ),
        BookInfo("Das ästhetische Wiesel", "Christian Morgenstern"),
        id="collection-album-poem-title-from-the-title-tag",
    ),
    pytest.param(
        "Kurt Tucholsky",
        "Augen in der Grossstadt",
        BookTags(album="Kurt Tucholsky: Gedichte und Texte", artist="Albrecht Kaltenhäuser"),
        BookInfo("Augen in der Grossstadt", "Kurt Tucholsky"),
        id="collection-album-poem-title-from-the-folder",
    ),
    pytest.param(
        "Hans Christian Andersen",
        "Des Kaisers neue Kleider",
        BookTags(album="Hans Christian Andersen: Des Kaisers neue Kleider", artist="Speech"),
        BookInfo("Des Kaisers neue Kleider", "Hans Christian Andersen"),
        id="colon-author-prefix",
    ),
    pytest.param(
        "Stephen King",
        "Stephen King - Es",
        BookTags(),
        BookInfo("Es", "Stephen King"),
        id="author-prefix-in-the-book-folder",
    ),
    pytest.param(
        "Hörbücher",
        "Terry Pratchett - Mort",
        BookTags(),
        BookInfo("Mort", "Terry Pratchett"),
        id="generic-parent-is-no-author",
    ),
    pytest.param(
        "Gekauft",
        "Gordon_Der-Medicus_9783837121995",
        BookTags(album="Der Medicus", artist="Noah Gordon"),
        BookInfo("Der Medicus", "Noah Gordon", isbn="9783837121995"),
        id="isbn-folder-below-another-folder-uses-tags",
    ),
    # --- single top-level folders (commercial audiobooks) ---
    pytest.param(
        None,
        "Gordon_Der-Medicus_9783837121995",
        BookTags(album="Der Medicus", artist=" Noah Gordon"),
        BookInfo("Der Medicus", "Noah Gordon", isbn="9783837121995"),
        id="leading-space-in-artist",
    ),
    pytest.param(
        None,
        "Herbert_Dune-_-Der-Wuestenplanet_9783837153569",
        BookTags(album="Dune ? Der Wüstenplanet", artist="Frank Herbert"),
        BookInfo("Dune – Der Wüstenplanet", "Frank Herbert", isbn="9783837153569"),
        id="lost-dash-encoding-artifact",
    ),
    pytest.param(
        None,
        "Herbert_Dune-_-Der-Wuestenplanet_9783837153569",
        BookTags(),
        BookInfo("Dune – Der Wuestenplanet", "Herbert", isbn="9783837153569"),
        id="isbn-folder-without-tags",
    ),
    pytest.param(
        None,
        "Crouch_Dark-Matter.-Der-Zeitenlaeufer_9783844526097",
        BookTags(album="Speech", artist="www.example-shop.com"),
        BookInfo("Dark Matter. Der Zeitenlaeufer", "Crouch", isbn="9783844526097"),
        id="isbn-folder-with-junk-tags",
    ),
    pytest.param(
        None,
        "Doerr_Wolkenkuckucksland_9783844545173",
        BookTags(album="Wolkenkuckucksland", artist="Anthony Doerr"),
        BookInfo("Wolkenkuckucksland", "Anthony Doerr", isbn="9783844545173"),
        id="isbn-folder-with-good-tags",
    ),
    pytest.param(
        None,
        "Doerr_Wolkenkuckucksland_9783844545170",
        BookTags(),
        BookInfo("Doerr Wolkenkuckucksland 9783844545170", None),
        id="bad-isbn-checksum-is-no-isbn",
    ),
    pytest.param(
        None,
        "Aurora",
        BookTags(album='"Aurora"_Reihe', artist="Anna Muster"),
        BookInfo('"Aurora" Reihe', "Anna Muster"),
        id="underscore-in-album",
    ),
    pytest.param(
        None,
        "Some Folder",
        BookTags(album="Mort", artist="Terry Pratchett"),
        BookInfo("Mort", "Terry Pratchett"),
        id="tags-first",
    ),
    pytest.param(
        None,
        "Terry Pratchett - Mort",
        BookTags(),
        BookInfo("Mort", "Terry Pratchett"),
        id="author-dash-title-folder",
    ),
    pytest.param(None, "Mort", BookTags(), BookInfo("Mort", None), id="plain-folder"),
    pytest.param(None, "Spider-Man", BookTags(), BookInfo("Spider-Man", None), id="hyphen"),
    pytest.param(
        None,
        "36 Stunden",
        HORVATH_TAGS,
        BookInfo(
            "36 Stunden. Die Geschichte vom Fräulein Pollinger",
            "Ödön von Horváth",
            narrator="Wolfram Huke",
        ),
        id="author-split-from-album-when-artist-is-narrator",
    ),
    pytest.param(
        None,
        "Terry Pratchett - Mort",
        BookTags(album="Terry Pratchett - Mort", artist="Read by Stephen Briggs"),
        BookInfo("Mort", "Terry Pratchett", narrator="Stephen Briggs"),
        id="folder-author-before-album-split",
    ),
    pytest.param(
        None,
        "Mort",
        BookTags(album="Hörbuch", artist="Gelesen von Stephen Briggs"),
        BookInfo("Mort", None, narrator="Stephen Briggs"),
        id="junk-album-and-narrator-only",
    ),
    pytest.param(
        None,
        "Dr No",
        BookTags(album="Dr.No", artist="Ian Fleming", isbn="978-3-8371-2199-5"),
        BookInfo("Dr.No", "Ian Fleming", isbn="9783837121995"),
        id="dotted-title-is-no-domain-and-isbn-from-tag",
    ),
]


@pytest.mark.parametrize(("parent", "folder", "tags", "expected"), RESOLVE_CASES)
def test_resolve_book_info(parent, folder, tags, expected):
    assert resolve_book_info(folder, tags, parent_name=parent) == expected


def test_resolve_book_info_is_deterministic():
    first = resolve_book_info("x", HORVATH_TAGS, parent_name="Ödön von Horváth")
    assert all(
        resolve_book_info("x", HORVATH_TAGS, parent_name="Ödön von Horváth") == first
        for _ in range(3)
    )


@pytest.mark.parametrize(
    ("value", "junk"),
    [
        ("vorleser.net", True),
        ("www.vorleser.net", True),
        ("http://etwasistimmer.de", True),
        ("etwasistimmer.de", True),
        ("Gedichte - www.vorleser.net", True),
        ("Speech", True),
        ("Audiobook", True),
        ("Hörbuch", True),
        ("Unknown", True),
        ("  ", True),
        (None, True),
        ("Dr.No", False),
        ("Mr. Mercedes", False),
        ("Der Medicus", False),
    ],
)
def test_is_junk(value, junk):
    assert is_junk(value) is junk


@pytest.mark.parametrize(
    ("value", "cleaned"),
    [
        (" Noah Gordon ", "Noah Gordon"),
        ("Dune ? Der Wüstenplanet", "Dune – Der Wüstenplanet"),
        ("Wer bin ich?", "Wer bin ich?"),
        ('"Aurora"_Reihe', '"Aurora" Reihe'),
        ("a  \t b", "a b"),
        ("", None),
        (None, None),
    ],
)
def test_clean_value(value, cleaned):
    assert clean_value(value) == cleaned


@pytest.mark.parametrize(
    ("artist", "narrator"),
    [
        ("Sprecher: Wolfram Huke", "Wolfram Huke"),
        ("Sprecherin: Anna Thalbach", "Anna Thalbach"),
        ("Gelesen von Rufus Beck", "Rufus Beck"),
        ("Read by Stephen Fry", "Stephen Fry"),
        ("Narrator: Jim Dale", "Jim Dale"),
        ("Wolfram Huke", None),
        ("Sprechergruppe", None),
        (None, None),
    ],
)
def test_narrator_of(artist, narrator):
    assert narrator_of(artist) == narrator


def test_match_key_ignores_punctuation_case_umlauts_and_accents():
    assert match_key("36 Stunden. Die Geschichte vom Fräulein Pollinger") == match_key(
        "36 stunden die geschichte vom fraeulein pollinger"
    )
    assert match_key("Horváth") == match_key("Horvath")
    assert match_key("Straße") == match_key("Strasse")
    assert match_key("") == ""


def test_isbn13_checksum_and_extraction():
    assert is_valid_isbn13("9783837121995")
    assert not is_valid_isbn13("9783837121990")
    assert not is_valid_isbn13("3837121995")
    assert isbn_in_text("Crouch_Dark-Matter.-Der-Zeitenlaeufer_9783844526097") == "9783844526097"
    assert isbn_in_text("x_97838445260970") is None  # 14 digits: not an ISBN
    assert isbn_in_text("978-3-8371-2199-5") is None
    assert isbn_in_text("978-3-8371-2199-5", separators=True) == "9783837121995"
    assert isbn_in_text(None) is None


def test_find_cover_file_prefers_cover_jpg(tmp_path):
    (tmp_path / "folder.jpg").write_bytes(b"x")
    (tmp_path / "cover.jpg").write_bytes(b"x")
    assert find_cover_file(tmp_path).name == "cover.jpg"


def test_find_cover_file_falls_back_to_folder_jpg(tmp_path):
    (tmp_path / "folder.jpg").write_bytes(b"x")
    assert find_cover_file(tmp_path).name == "folder.jpg"


def test_find_cover_file_none_when_absent(tmp_path):
    assert find_cover_file(tmp_path) is None


@requires_ffmpeg
def test_extract_embedded_cover(make_mp3):
    p = make_mp3()
    _tag(p, apic=APIC(mime="image/jpeg", data=b"\xff\xd8\xff\xe0fake-jpeg-bytes"))
    cover = extract_embedded_cover(p)
    assert cover is not None
    assert cover.mime == "image/jpeg"
    assert cover.data == b"\xff\xd8\xff\xe0fake-jpeg-bytes"


@requires_ffmpeg
def test_extract_embedded_cover_none_when_absent(make_mp3):
    p = make_mp3()
    assert extract_embedded_cover(p) is None


@requires_ffmpeg
def test_extract_embedded_cover_skipped_when_over_cap(make_mp3):
    p = make_mp3()
    _tag(p, apic=APIC(mime="image/jpeg", data=b"x" * 200))
    # a tiny max_bytes stands in for the real 10MB cap without inflating a
    # 200-byte fixture frame to actually exceed it.
    assert extract_embedded_cover(p, max_bytes=100) is None
    assert extract_embedded_cover(p, max_bytes=200) is not None
