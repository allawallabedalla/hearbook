"""Tests for metadata.py, docs/ARCHITEKTUR.md section 3.6."""

from __future__ import annotations

from mutagen.id3 import APIC, ID3, TALB, TIT2, TPE1, TPOS, TRCK

from faden_server.metadata import (
    extract_embedded_cover,
    find_cover_file,
    read_book_tags,
    read_track_tags,
    resolve_title_author,
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
    title, author = read_book_tags(p)
    assert title == "Mort"
    assert author == "Terry Pratchett"


def test_resolve_title_author_prefers_id3():
    title, author = resolve_title_author("Some Folder", "Mort", "Terry Pratchett")
    assert (title, author) == ("Mort", "Terry Pratchett")


def test_resolve_title_author_falls_back_to_folder_pattern():
    title, author = resolve_title_author("Terry Pratchett - Mort", None, None)
    assert (title, author) == ("Mort", "Terry Pratchett")


def test_resolve_title_author_falls_back_to_plain_folder_name():
    title, author = resolve_title_author("Mort", None, None)
    assert (title, author) == ("Mort", None)


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
