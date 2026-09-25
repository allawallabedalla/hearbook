"""Tests for the API from docs/ARCHITEKTUR.md section 10 (without events)."""

from __future__ import annotations

import shutil

import pytest
from fastapi.testclient import TestClient
from mutagen.id3 import APIC, ID3, ID3NoHeaderError

import faden_server.api
from faden_server.api import create_app
from faden_server.config import Settings
from faden_server.db import connect
from faden_server.scanner import scan_library

from .conftest import requires_ffmpeg

TOKEN = "test-token-1234567890"


@pytest.fixture
def settings(tmp_path):
    library = tmp_path / "library"
    library.mkdir()
    data = tmp_path / "data"
    return Settings(
        token=TOKEN,
        library=library,
        data=data,
        port=8787,
        rescan_min=10,
        silence_db=-35,
        silence_s=0.35,
    )


@pytest.fixture
def auth_headers():
    return {"Authorization": f"Bearer {TOKEN}"}


def _run_scan(settings):
    conn = connect(settings.data / "faden.db")
    scan_library(
        conn, library=settings.library, noise_db=settings.silence_db, silence_s=settings.silence_s
    )
    conn.close()


def _seed_book(make_mp3, settings, *, with_cover=False, embedded_cover=False, n_files=2):
    book_dir = settings.library / "Mort"
    book_dir.mkdir()
    for i in range(1, n_files + 1):
        p = make_mp3(f"{i:02d}.mp3", segments=[("tone", 0.2)], freq=300 + i * 41)
        dest = book_dir / p.name
        shutil.move(str(p), dest)
        if embedded_cover and i == 1:
            try:
                tags = ID3(dest)
            except ID3NoHeaderError:
                tags = ID3()
            tags.add(APIC(mime="image/jpeg", data=b"\xff\xd8fake"))
            tags.save(dest, v2_version=4)
    if with_cover:
        (book_dir / "cover.jpg").write_bytes(b"\xff\xd8real-cover")

    _run_scan(settings)


# --- auth -----------------------------------------------------------------


def test_health_needs_no_auth(settings):
    client = TestClient(create_app(settings))
    resp = client.get("/api/v1/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_books_requires_auth(settings):
    client = TestClient(create_app(settings))
    resp = client.get("/api/v1/books")
    assert resp.status_code == 401


def test_books_rejects_wrong_token(settings):
    client = TestClient(create_app(settings))
    resp = client.get("/api/v1/books", headers={"Authorization": "Bearer wrong"})
    assert resp.status_code == 401


def test_books_accepts_correct_token(settings, auth_headers):
    client = TestClient(create_app(settings))
    resp = client.get("/api/v1/books", headers=auth_headers)
    assert resp.status_code == 200


# --- books / manifest -------------------------------------------------


@requires_ffmpeg
def test_list_books(make_mp3, settings, auth_headers):
    _seed_book(make_mp3, settings)
    client = TestClient(create_app(settings))
    resp = client.get("/api/v1/books", headers=auth_headers)
    assert resp.status_code == 200
    books = resp.json()
    assert len(books) == 1
    assert books[0]["title"] == "Mort"
    assert books[0]["status"] == "ok"
    assert books[0]["duration_ms"] > 0


@requires_ffmpeg
def test_book_detail_has_active_manifest_with_files(make_mp3, settings, auth_headers):
    _seed_book(make_mp3, settings)
    client = TestClient(create_app(settings))
    books = client.get("/api/v1/books", headers=auth_headers).json()
    book_id = books[0]["book_id"]

    resp = client.get(f"/api/v1/books/{book_id}", headers=auth_headers)
    assert resp.status_code == 200
    detail = resp.json()
    assert detail["active_manifest"]["status"] == "active"
    assert len(detail["active_manifest"]["files"]) == 2
    assert all(f["size_bytes"] > 0 for f in detail["active_manifest"]["files"])
    assert detail["candidates"] == []


def test_book_detail_404_for_unknown_book(settings, auth_headers):
    client = TestClient(create_app(settings))
    resp = client.get("/api/v1/books/does-not-exist", headers=auth_headers)
    assert resp.status_code == 404


@requires_ffmpeg
def test_confirm_pending_manifest_makes_it_active(make_mp3, settings, auth_headers):
    _seed_book(make_mp3, settings, n_files=2)
    # force a reorder -> pending candidate, by renaming files (no tags -> key B)
    book_dir = settings.library / "Mort"
    (book_dir / "01.mp3").rename(book_dir / "01-tmp.mp3")
    (book_dir / "02.mp3").rename(book_dir / "01.mp3")
    (book_dir / "01-tmp.mp3").rename(book_dir / "02.mp3")
    _run_scan(settings)

    client = TestClient(create_app(settings))
    books = client.get("/api/v1/books", headers=auth_headers).json()
    assert books[0]["status"] == "pending"
    book_id = books[0]["book_id"]
    detail = client.get(f"/api/v1/books/{book_id}", headers=auth_headers).json()
    pending_id = detail["candidates"][0]["manifest_id"]

    resp = client.post(
        f"/api/v1/books/{book_id}/manifests/{pending_id}/confirm", headers=auth_headers
    )
    assert resp.status_code == 200
    assert resp.json()["status"] == "active"

    detail2 = client.get(f"/api/v1/books/{book_id}", headers=auth_headers).json()
    assert detail2["active_manifest"]["manifest_id"] == pending_id
    assert detail2["candidates"] == []


# --- cover ---------------------------------------------------------------


@requires_ffmpeg
def test_cover_404_when_none(make_mp3, settings, auth_headers):
    _seed_book(make_mp3, settings)
    client = TestClient(create_app(settings))
    book_id = client.get("/api/v1/books", headers=auth_headers).json()[0]["book_id"]
    resp = client.get(f"/api/v1/books/{book_id}/cover", headers=auth_headers)
    assert resp.status_code == 404


@requires_ffmpeg
def test_cover_from_folder_file(make_mp3, settings, auth_headers):
    _seed_book(make_mp3, settings, with_cover=True)
    client = TestClient(create_app(settings))
    book_id = client.get("/api/v1/books", headers=auth_headers).json()[0]["book_id"]
    resp = client.get(f"/api/v1/books/{book_id}/cover", headers=auth_headers)
    assert resp.status_code == 200
    assert resp.content == b"\xff\xd8real-cover"


@requires_ffmpeg
def test_cover_from_embedded_image(make_mp3, settings, auth_headers):
    _seed_book(make_mp3, settings, embedded_cover=True)
    client = TestClient(create_app(settings))
    book_id = client.get("/api/v1/books", headers=auth_headers).json()[0]["book_id"]
    resp = client.get(f"/api/v1/books/{book_id}/cover", headers=auth_headers)
    assert resp.status_code == 200
    assert resp.content == b"\xff\xd8fake"


@requires_ffmpeg
def test_oversized_folder_cover_is_skipped(make_mp3, settings, auth_headers, monkeypatch):
    """A cover file over the cap must not be read into memory; with no
    smaller fallback available, the request 404s instead of erroring."""
    monkeypatch.setattr(faden_server.api, "MAX_COVER_BYTES", 10)
    _seed_book(make_mp3, settings, with_cover=True)  # cover.jpg is well over 10 bytes
    client = TestClient(create_app(settings))
    book_id = client.get("/api/v1/books", headers=auth_headers).json()[0]["book_id"]
    resp = client.get(f"/api/v1/books/{book_id}/cover", headers=auth_headers)
    assert resp.status_code == 404


@requires_ffmpeg
def test_oversized_folder_cover_falls_through_to_embedded(
    make_mp3, settings, auth_headers, monkeypatch
):
    monkeypatch.setattr(faden_server.api, "MAX_COVER_BYTES", 10)
    _seed_book(make_mp3, settings, with_cover=True, embedded_cover=True)
    client = TestClient(create_app(settings))
    book_id = client.get("/api/v1/books", headers=auth_headers).json()[0]["book_id"]
    resp = client.get(f"/api/v1/books/{book_id}/cover", headers=auth_headers)
    assert resp.status_code == 200
    assert resp.content == b"\xff\xd8fake"


# --- pauses ----------------------------------------------------------------


@requires_ffmpeg
def test_pauses_keyed_by_file_hash(make_mp3, settings, auth_headers):
    _seed_book(make_mp3, settings)
    client = TestClient(create_app(settings))
    books = client.get("/api/v1/books", headers=auth_headers).json()
    book_id = books[0]["book_id"]
    detail = client.get(f"/api/v1/books/{book_id}", headers=auth_headers).json()
    hashes = [f["file_hash"] for f in detail["active_manifest"]["files"]]

    resp = client.get(f"/api/v1/books/{book_id}/pauses", headers=auth_headers)
    assert resp.status_code == 200
    pauses = resp.json()
    assert set(pauses.keys()) == set(hashes)
    for offsets in pauses.values():
        assert offsets[0] == 0


# --- file range download ----------------------------------------------


@requires_ffmpeg
def test_file_download_full(make_mp3, settings, auth_headers):
    _seed_book(make_mp3, settings)
    client = TestClient(create_app(settings))
    book_id = client.get("/api/v1/books", headers=auth_headers).json()[0]["book_id"]
    detail = client.get(f"/api/v1/books/{book_id}", headers=auth_headers).json()
    file_hash = detail["active_manifest"]["files"][0]["file_hash"]

    resp = client.get(f"/api/v1/files/{file_hash}", headers=auth_headers)
    assert resp.status_code == 200
    assert resp.headers["accept-ranges"] == "bytes"
    assert int(resp.headers["content-length"]) == len(resp.content)


@requires_ffmpeg
def test_file_download_partial_range(make_mp3, settings, auth_headers):
    _seed_book(make_mp3, settings)
    client = TestClient(create_app(settings))
    book_id = client.get("/api/v1/books", headers=auth_headers).json()[0]["book_id"]
    detail = client.get(f"/api/v1/books/{book_id}", headers=auth_headers).json()
    file_hash = detail["active_manifest"]["files"][0]["file_hash"]

    full = client.get(f"/api/v1/files/{file_hash}", headers=auth_headers).content

    headers = dict(auth_headers)
    headers["Range"] = "bytes=0-9"
    resp = client.get(f"/api/v1/files/{file_hash}", headers=headers)
    assert resp.status_code == 206
    assert resp.content == full[0:10]
    assert resp.headers["content-range"] == f"bytes 0-9/{len(full)}"

    headers["Range"] = f"bytes={len(full) - 5}-"
    resp2 = client.get(f"/api/v1/files/{file_hash}", headers=headers)
    assert resp2.status_code == 206
    assert resp2.content == full[-5:]


@requires_ffmpeg
def test_file_download_invalid_range_416(make_mp3, settings, auth_headers):
    _seed_book(make_mp3, settings)
    client = TestClient(create_app(settings))
    book_id = client.get("/api/v1/books", headers=auth_headers).json()[0]["book_id"]
    detail = client.get(f"/api/v1/books/{book_id}", headers=auth_headers).json()
    file_hash = detail["active_manifest"]["files"][0]["file_hash"]

    headers = dict(auth_headers)
    headers["Range"] = "bytes=99999999-100000000"
    resp = client.get(f"/api/v1/files/{file_hash}", headers=headers)
    assert resp.status_code == 416


def test_file_download_404_unknown_hash(settings, auth_headers):
    client = TestClient(create_app(settings))
    resp = client.get("/api/v1/files/deadbeef", headers=auth_headers)
    assert resp.status_code == 404


# --- rescan ----------------------------------------------------------------


@requires_ffmpeg
def test_rescan_endpoint_picks_up_new_book(make_mp3, settings, auth_headers):
    client = TestClient(create_app(settings))
    assert client.get("/api/v1/books", headers=auth_headers).json() == []

    _seed_book_files_only(make_mp3, settings)
    resp = client.post("/api/v1/rescan", headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json()["books_new"] == 1

    books = client.get("/api/v1/books", headers=auth_headers).json()
    assert len(books) == 1


def _seed_book_files_only(make_mp3, settings):
    book_dir = settings.library / "Mort"
    book_dir.mkdir()
    for i in range(1, 3):
        p = make_mp3(f"{i:02d}.mp3", segments=[("tone", 0.2)], freq=300 + i * 41)
        shutil.move(str(p), book_dir / p.name)
