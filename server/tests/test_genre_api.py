"""Tests for the genre endpoints and fields (docs/ARCHITEKTUR.md section 10)."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from faden_server.api import create_app
from faden_server.config import Settings
from faden_server.db import connect
from faden_server.genres import BIOGRAFIE, GENRES, HUMOR, KRIMI

TOKEN = "test-token-1234567890"


@pytest.fixture
def settings(tmp_path):
    library = tmp_path / "library"
    library.mkdir()
    return Settings(
        token=TOKEN,
        library=library,
        data=tmp_path / "data",
        port=8787,
        rescan_min=10,
        silence_db=-35,
        silence_s=0.35,
    )


@pytest.fixture
def auth_headers():
    return {"Authorization": f"Bearer {TOKEN}"}


class FakeLookup:
    def __init__(self, result=(BIOGRAFIE, "dnb")):
        self.result = result
        self.calls = 0

    def __call__(self, title, author, isbn=None):
        self.calls += 1
        return self.result


@pytest.fixture
def lookup():
    return FakeLookup()


@pytest.fixture
def app(settings, lookup):
    return create_app(settings, genre_lookup=lookup)


@pytest.fixture
def client(app, settings):
    client = TestClient(app)
    conn = connect(settings.db_path)
    conn.execute(
        "INSERT INTO books (book_id, path, title, author, incomplete, created_at, "
        "genre, genre_source, genre_checked_at) "
        "VALUES ('b1', '/library/Mort', 'Mort', 'Terry Pratchett', 0, 'x', ?, 'dnb', 100)",
        (KRIMI,),
    )
    conn.commit()
    conn.close()
    return client


def row(settings):
    conn = connect(settings.db_path)
    try:
        return tuple(
            conn.execute(
                "SELECT genre, genre_source, genre_checked_at FROM books WHERE book_id = 'b1'"
            ).fetchone()
        )
    finally:
        conn.close()


def test_genres_lists_the_labels(client, auth_headers):
    resp = client.get("/api/v1/genres", headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json() == list(GENRES)


def test_genres_needs_auth(client):
    assert client.get("/api/v1/genres").status_code == 401


def test_book_list_and_detail_include_the_genre(client, auth_headers):
    books = client.get("/api/v1/books", headers=auth_headers).json()
    assert books[0]["genre"] == KRIMI
    detail = client.get("/api/v1/books/b1", headers=auth_headers).json()
    assert (detail["genre"], detail["genre_source"]) == (KRIMI, "dnb")


def test_put_sets_a_manual_genre(client, auth_headers, settings, app, lookup):
    resp = client.put("/api/v1/books/b1/genre", json={"genre": HUMOR}, headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json() == {"book_id": "b1", "genre": HUMOR, "genre_source": "manual"}
    genre, source, checked_at = row(settings)
    assert (genre, source) == (HUMOR, "manual")
    assert checked_at > 100
    assert client.get("/api/v1/books", headers=auth_headers).json()[0]["genre"] == HUMOR

    # a later scan's lookup pass leaves it alone
    app.state.genre_refresher.trigger()
    app.state.genre_refresher.join(timeout=5)
    assert row(settings)[:2] == (HUMOR, "manual")
    assert lookup.calls == 0


def test_put_null_goes_back_to_automatic(client, auth_headers, settings, app, lookup):
    client.put("/api/v1/books/b1/genre", json={"genre": HUMOR}, headers=auth_headers)
    resp = client.put("/api/v1/books/b1/genre", json={"genre": None}, headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json() == {"book_id": "b1", "genre": None, "genre_source": None}

    # clearing starts a lookup right away
    app.state.genre_refresher.join(timeout=5)
    assert lookup.calls == 1
    genre, source, _ = row(settings)
    assert (genre, source) == (BIOGRAFIE, "dnb")


@pytest.mark.parametrize(
    "body",
    [{"genre": "Horror"}, {"genre": "krimi & thriller"}, {"genre": 3}, {}, {"genres": None}],
)
def test_put_rejects_unknown_labels(client, auth_headers, settings, body):
    resp = client.put("/api/v1/books/b1/genre", json=body, headers=auth_headers)
    assert resp.status_code == 422
    assert row(settings) == (KRIMI, "dnb", 100)


def test_put_unknown_book_is_404(client, auth_headers):
    resp = client.put("/api/v1/books/nope/genre", json={"genre": HUMOR}, headers=auth_headers)
    assert resp.status_code == 404


def test_put_needs_auth(client, settings):
    resp = client.put("/api/v1/books/b1/genre", json={"genre": HUMOR})
    assert resp.status_code == 401
    resp = client.put(
        "/api/v1/books/b1/genre", json={"genre": HUMOR}, headers={"Authorization": "Bearer x"}
    )
    assert resp.status_code == 401
    assert row(settings) == (KRIMI, "dnb", 100)


def test_book_list_and_detail_include_narrator_and_isbn(client, auth_headers, settings):
    conn = connect(settings.db_path)
    conn.execute("UPDATE books SET narrator = 'Stephen Briggs', isbn = '9783837121995'")
    conn.commit()
    conn.close()
    books = client.get("/api/v1/books", headers=auth_headers).json()
    assert books[0]["narrator"] == "Stephen Briggs"
    detail = client.get("/api/v1/books/b1", headers=auth_headers).json()
    assert (detail["narrator"], detail["isbn"]) == ("Stephen Briggs", "9783837121995")
