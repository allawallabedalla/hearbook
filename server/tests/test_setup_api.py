"""Tests for the setup endpoints from docs/ARCHITEKTUR.md section 10
(decision E12, milestone M1b): GET /api/v1/setup/browse, GET/POST
/api/v1/setup/library, and GET /setup (the static page).
"""

from __future__ import annotations

import shutil

import pytest
from fastapi.testclient import TestClient

from faden_server.api import create_app
from faden_server.config import Settings
from faden_server.db import connect
from faden_server.library_path import get_library_path

from .conftest import requires_ffmpeg

TOKEN = "test-token-123"


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


# --- auth: all three endpoints require the same bearer token ---------------


def test_browse_requires_auth(settings):
    client = TestClient(create_app(settings))
    resp = client.get("/api/v1/setup/browse")
    assert resp.status_code == 401


def test_get_library_requires_auth(settings):
    client = TestClient(create_app(settings))
    resp = client.get("/api/v1/setup/library")
    assert resp.status_code == 401


def test_post_library_requires_auth(settings):
    client = TestClient(create_app(settings))
    resp = client.post("/api/v1/setup/library", json={"path": "books"})
    assert resp.status_code == 401


def test_browse_rejects_wrong_token(settings):
    client = TestClient(create_app(settings))
    resp = client.get(
        "/api/v1/setup/browse", headers={"Authorization": "Bearer wrong"}
    )
    assert resp.status_code == 401


# --- browse: happy path ------------------------------------------------


def test_browse_root_lists_subdirs(settings, auth_headers):
    (settings.library / "Autor A").mkdir()
    (settings.library / "Autor B").mkdir()
    (settings.library / "not-a-folder.txt").write_text("x")

    client = TestClient(create_app(settings))
    resp = client.get("/api/v1/setup/browse", headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["path"] == ""
    assert body["dirs"] == ["Autor A", "Autor B"]


def test_browse_subpath_lists_nested_subdirs(settings, auth_headers):
    (settings.library / "Autor A" / "Buch 1").mkdir(parents=True)
    (settings.library / "Autor A" / "Buch 2").mkdir(parents=True)

    client = TestClient(create_app(settings))
    resp = client.get(
        "/api/v1/setup/browse", params={"path": "Autor A"}, headers=auth_headers
    )
    assert resp.status_code == 200
    assert resp.json()["dirs"] == ["Buch 1", "Buch 2"]


def test_browse_missing_path_404(settings, auth_headers):
    client = TestClient(create_app(settings))
    resp = client.get(
        "/api/v1/setup/browse", params={"path": "does-not-exist"}, headers=auth_headers
    )
    assert resp.status_code == 404


def test_browse_on_a_file_404(settings, auth_headers):
    (settings.library / "not-a-folder.txt").write_text("x")
    client = TestClient(create_app(settings))
    resp = client.get(
        "/api/v1/setup/browse",
        params={"path": "not-a-folder.txt"},
        headers=auth_headers,
    )
    assert resp.status_code == 404


# --- browse: path traversal ----------------------------------------------


@pytest.mark.parametrize(
    "malicious_path",
    [
        "../../etc",
        "../../../etc/passwd",
        "/etc/passwd",
        "books/../../etc",
        "..",
    ],
)
def test_browse_rejects_path_traversal(settings, auth_headers, malicious_path):
    client = TestClient(create_app(settings))
    resp = client.get(
        "/api/v1/setup/browse", params={"path": malicious_path}, headers=auth_headers
    )
    assert resp.status_code == 400


def test_browse_rejects_symlink_escape(settings, auth_headers, tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "secret.txt").write_text("nope")
    (settings.library / "escape").symlink_to(outside)

    client = TestClient(create_app(settings))
    resp = client.get(
        "/api/v1/setup/browse", params={"path": "escape"}, headers=auth_headers
    )
    assert resp.status_code == 400


# --- GET /api/v1/setup/library -------------------------------------------


def test_get_library_defaults_to_empty(settings, auth_headers):
    client = TestClient(create_app(settings))
    resp = client.get("/api/v1/setup/library", headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json() == {"path": ""}


# --- POST /api/v1/setup/library -------------------------------------------


def test_post_library_stores_valid_selection(settings, auth_headers):
    (settings.library / "books" / "Mort").mkdir(parents=True)
    client = TestClient(create_app(settings))

    resp = client.post(
        "/api/v1/setup/library", json={"path": "books"}, headers=auth_headers
    )
    assert resp.status_code == 200
    assert resp.json() == {"path": "books"}

    conn = connect(settings.data / "faden.db")
    assert get_library_path(conn) == "books"
    conn.close()

    resp2 = client.get("/api/v1/setup/library", headers=auth_headers)
    assert resp2.json() == {"path": "books"}


def test_post_library_empty_path_selects_root(settings, auth_headers):
    client = TestClient(create_app(settings))
    resp = client.post("/api/v1/setup/library", json={"path": ""}, headers=auth_headers)
    assert resp.status_code == 200


def test_post_library_404_for_missing_path(settings, auth_headers):
    client = TestClient(create_app(settings))
    resp = client.post(
        "/api/v1/setup/library", json={"path": "does-not-exist"}, headers=auth_headers
    )
    assert resp.status_code == 404


def test_post_library_404_for_a_file(settings, auth_headers):
    (settings.library / "a-file.txt").write_text("x")
    client = TestClient(create_app(settings))
    resp = client.post(
        "/api/v1/setup/library", json={"path": "a-file.txt"}, headers=auth_headers
    )
    assert resp.status_code == 404


@pytest.mark.parametrize(
    "malicious_path",
    ["../../etc", "/etc", "books/../../etc", ".."],
)
def test_post_library_rejects_path_traversal(settings, auth_headers, malicious_path):
    client = TestClient(create_app(settings))
    resp = client.post(
        "/api/v1/setup/library", json={"path": malicious_path}, headers=auth_headers
    )
    assert resp.status_code == 400
    # nothing must be stored on a rejected attempt
    conn = connect(settings.data / "faden.db")
    assert get_library_path(conn) == ""
    conn.close()


def test_post_library_rejects_symlink_escape(settings, auth_headers, tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    (settings.library / "escape").symlink_to(outside)

    client = TestClient(create_app(settings))
    resp = client.post(
        "/api/v1/setup/library", json={"path": "escape"}, headers=auth_headers
    )
    assert resp.status_code == 400


def test_post_library_rejects_non_string_path(settings, auth_headers):
    client = TestClient(create_app(settings))
    resp = client.post(
        "/api/v1/setup/library", json={"path": 123}, headers=auth_headers
    )
    assert resp.status_code == 422


# --- selection actually used by the scanner --------------------------------


@requires_ffmpeg
def test_post_library_selection_triggers_immediate_rescan(make_mp3, settings, auth_headers):
    """The book lives under books/Mort, outside is a decoy directory that
    is not part of the chosen library and must not be scanned."""
    book_dir = settings.library / "books" / "Mort"
    book_dir.mkdir(parents=True)
    p = make_mp3("01.mp3", segments=[("tone", 0.2)])
    shutil.move(str(p), book_dir / "01.mp3")

    decoy_dir = settings.library / "decoy" / "Not Picked"
    decoy_dir.mkdir(parents=True)
    q = make_mp3("01.mp3", segments=[("tone", 0.2)], freq=880)
    shutil.move(str(q), decoy_dir / "01.mp3")

    client = TestClient(create_app(settings))
    # library_path unset (root) -> both books would be found once /rescan runs.
    resp = client.post(
        "/api/v1/setup/library", json={"path": "books"}, headers=auth_headers
    )
    assert resp.status_code == 200

    books = client.get("/api/v1/books", headers=auth_headers).json()
    assert len(books) == 1
    assert books[0]["title"] == "Mort"


@requires_ffmpeg
def test_rescan_endpoint_uses_stored_library_path(make_mp3, settings, auth_headers):
    book_dir = settings.library / "books" / "Mort"
    book_dir.mkdir(parents=True)
    p = make_mp3("01.mp3", segments=[("tone", 0.2)])
    shutil.move(str(p), book_dir / "01.mp3")

    other_dir = settings.library / "other" / "Anderes Buch"
    other_dir.mkdir(parents=True)
    q = make_mp3("01.mp3", segments=[("tone", 0.2)], freq=880)
    shutil.move(str(q), other_dir / "01.mp3")

    client = TestClient(create_app(settings))
    client.post("/api/v1/setup/library", json={"path": "books"}, headers=auth_headers)

    # add a second book under the same, already-selected subtree and use the
    # plain rescan endpoint (not the setup one) to pick it up.
    book_dir2 = settings.library / "books" / "Ozean"
    book_dir2.mkdir()
    r = make_mp3("01.mp3", segments=[("tone", 0.2)], freq=500)
    shutil.move(str(r), book_dir2 / "01.mp3")

    resp = client.post("/api/v1/rescan", headers=auth_headers)
    assert resp.status_code == 200

    books = client.get("/api/v1/books", headers=auth_headers).json()
    titles = {b["title"] for b in books}
    assert titles == {"Mort", "Ozean"}
    assert "Anderes Buch" not in titles


# --- static setup page -------------------------------------------------


def test_setup_page_is_served_without_auth(settings):
    client = TestClient(create_app(settings))
    resp = client.get("/setup")
    assert resp.status_code == 200
    assert "text/html" in resp.headers["content-type"]
    assert "setup" in resp.text.lower() or "bibliothek" in resp.text.lower()
