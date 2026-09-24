"""Tests for scanner.py: book detection (3.1), one test per 3.3 table row,
and the ordering (3.2) integration with real files."""

from __future__ import annotations

import shutil
import threading
from pathlib import Path

import pytest
from mutagen.id3 import ID3, TRCK

from faden_server import db, scanner
from faden_server.scanner import detect_book_folders, scan_library

from .conftest import requires_ffmpeg


def _tag_track(path, track: int):
    try:
        tags = ID3(path)
    except Exception:
        tags = ID3()
    tags.add(TRCK(text=[str(track)]))
    tags.save(path, v2_version=4)


def _manifest_id_with_status(conn, book_id: str, status: str) -> str | None:
    row = conn.execute(
        "SELECT manifest_id FROM manifests WHERE book_id = ? AND status = ?", (book_id, status)
    ).fetchone()
    return row["manifest_id"] if row else None


def _count_with_status(conn, book_id: str, status: str) -> int:
    return conn.execute(
        "SELECT COUNT(*) c FROM manifests WHERE book_id = ? AND status = ?", (book_id, status)
    ).fetchone()["c"]


# --- 3.1 book detection --------------------------------------------------


def test_flat_folder_with_mp3s_is_a_book(tmp_path):
    book = tmp_path / "Mort"
    book.mkdir()
    (book / "01.mp3").write_bytes(b"x")
    (book / "02.mp3").write_bytes(b"x")

    folders = detect_book_folders(tmp_path)
    assert len(folders) == 1
    assert folders[0].path == book
    assert [f.disc_from_folder for f in folders[0].files] == [1, 1]


@pytest.mark.parametrize(
    "name1,name2",
    [
        ("CD1", "CD2"),
        ("cd 1", "cd 2"),
        ("Disc01", "Disc02"),
        ("Disk 1", "Disk 2"),
        ("Teil1", "Teil2"),
        ("Part 1", "Part 2"),
    ],
)
def test_disc_subfolders_are_a_book_with_disc_numbers(tmp_path, name1, name2):
    book = tmp_path / "Mort"
    book.mkdir()
    (book / name1).mkdir()
    (book / name2).mkdir()
    (book / name1 / "01.mp3").write_bytes(b"x")
    (book / name2 / "01.mp3").write_bytes(b"x")

    folders = detect_book_folders(tmp_path)
    assert len(folders) == 1
    discs = sorted(f.disc_from_folder for f in folders[0].files)
    assert discs == [1, 2]


def test_mixed_subfolders_not_a_book_recurses_for_nested_books(tmp_path):
    parent = tmp_path / "Author"
    parent.mkdir()
    (parent / "CD1").mkdir()  # only one disc-like folder among others: not "only disc folders"
    (parent / "notes").mkdir()
    (parent / "CD1" / "01.mp3").write_bytes(b"x")

    nested_book = parent / "Other Book"
    nested_book.mkdir()
    (nested_book / "01.mp3").write_bytes(b"x")

    folders = detect_book_folders(tmp_path)
    paths = {f.path for f in folders}
    assert nested_book in paths
    assert parent not in paths


def test_macos_appledouble_files_are_not_chapters(tmp_path):
    book = tmp_path / "Mort"
    book.mkdir()
    for name in ("01.mp3", "02.mp3", "._01.mp3", "._02.mp3"):
        (book / name).write_bytes(b"x")

    folders = detect_book_folders(tmp_path)
    assert len(folders) == 1
    assert [f.path.name for f in folders[0].files] == ["01.mp3", "02.mp3"]


def test_nas_metadata_folders_do_not_break_disc_detection(tmp_path):
    book = tmp_path / "Mort"
    for sub in ("CD1", "CD2", "@eaDir", "#recycle", "__MACOSX"):
        (book / sub).mkdir(parents=True)
    (book / "CD1" / "01.mp3").write_bytes(b"x")
    (book / "CD2" / "01.mp3").write_bytes(b"x")
    (book / "__MACOSX" / "._01.mp3").write_bytes(b"x")
    (book / "@eaDir" / "01.mp3").mkdir()

    folders = detect_book_folders(tmp_path)
    assert [f.path for f in folders] == [book]
    assert sorted(f.disc_from_folder for f in folders[0].files) == [1, 2]


@requires_ffmpeg
def test_scan_logs_progress(make_mp3, tmp_path, conn, caplog):
    book = tmp_path / "lib" / "Mort"
    book.mkdir(parents=True)
    make_mp3(book / "01.mp3")

    with caplog.at_level("INFO", logger="faden_server.scanner"):
        scan_library(conn, library=tmp_path / "lib", noise_db=-35, silence_s=0.35)

    messages = [r.getMessage() for r in caplog.records]
    assert any("1 book folders" in m for m in messages)
    assert any("new book 1/1: Mort" in m for m in messages)
    assert any(m.startswith("scan done: 1 books, 1 new") for m in messages)


def test_empty_folder_is_not_a_book(tmp_path):
    empty = tmp_path / "Empty"
    empty.mkdir()
    assert detect_book_folders(tmp_path) == []


# --- full scan: 3.2 ordering + 3.3 rescan table --------------------------


@pytest.fixture
def conn(tmp_path):
    return db.connect(tmp_path / "data" / "faden.db")


def _make_book(make_mp3, library, name, n_files, *, tagged=True, start_freq=300):
    # Each chapter needs distinct audio content, or it would hash identically
    # to its siblings (correctly triggering the duplicate-hash rule).
    book_dir = library / name
    book_dir.mkdir(parents=True)
    for i in range(1, n_files + 1):
        p = make_mp3(f"{i:02d}.mp3", segments=[("tone", 0.2)], freq=start_freq + i * 37)
        dest = book_dir / p.name
        shutil.move(str(p), dest)
        if tagged:
            _tag_track(dest, i)
    return book_dir


@requires_ffmpeg
def test_initial_import_creates_active_manifest(make_mp3, tmp_path, conn):
    library = tmp_path / "library"
    _make_book(make_mp3, library, "Mort", 2)

    summary = scan_library(conn, library=library, noise_db=-35, silence_s=0.35)
    assert summary.books_new == 1

    books = conn.execute("SELECT * FROM books").fetchall()
    assert len(books) == 1
    manifests = conn.execute(
        "SELECT * FROM manifests WHERE book_id = ? AND status='active'", (books[0]["book_id"],)
    ).fetchall()
    assert len(manifests) == 1
    files = conn.execute(
        "SELECT file_hash FROM manifest_files WHERE manifest_id = ? ORDER BY idx",
        (manifests[0]["manifest_id"],),
    ).fetchall()
    assert len(files) == 2


@requires_ffmpeg
def test_rescan_new_equals_active_does_nothing(make_mp3, tmp_path, conn):
    library = tmp_path / "library"
    _make_book(make_mp3, library, "Mort", 2)
    scan_library(conn, library=library, noise_db=-35, silence_s=0.35)
    manifests_before = conn.execute("SELECT manifest_id, status FROM manifests").fetchall()

    scan_library(conn, library=library, noise_db=-35, silence_s=0.35)
    manifests_after = conn.execute("SELECT manifest_id, status FROM manifests").fetchall()

    assert [dict(r) for r in manifests_before] == [dict(r) for r in manifests_after]


@requires_ffmpeg
def test_rescan_append_only_auto_activates(make_mp3, tmp_path, conn):
    library = tmp_path / "library"
    book_dir = _make_book(make_mp3, library, "Mort", 2)
    scan_library(conn, library=library, noise_db=-35, silence_s=0.35)

    p = make_mp3("03.mp3", segments=[("tone", 0.2)])
    shutil.move(str(p), book_dir / "03.mp3")
    _tag_track(book_dir / "03.mp3", 3)

    scan_library(conn, library=library, noise_db=-35, silence_s=0.35)

    book = conn.execute("SELECT * FROM books").fetchone()
    active = conn.execute(
        "SELECT * FROM manifests WHERE book_id = ? AND status = 'active'", (book["book_id"],)
    ).fetchone()
    file_count = conn.execute(
        "SELECT COUNT(*) c FROM manifest_files WHERE manifest_id = ?", (active["manifest_id"],)
    ).fetchone()["c"]
    assert file_count == 3
    assert _count_with_status(conn, book["book_id"], "superseded") == 1


@requires_ffmpeg
def test_rescan_reorder_creates_pending_keeps_old_active(make_mp3, tmp_path, conn):
    library = tmp_path / "library"
    book_dir = _make_book(make_mp3, library, "Mort", 2, tagged=False)
    scan_library(conn, library=library, noise_db=-35, silence_s=0.35)
    book = conn.execute("SELECT * FROM books").fetchone()
    active_before = _manifest_id_with_status(conn, book["book_id"], "active")

    # rename files to swap their natural order (no tags, so key B decides)
    (book_dir / "01.mp3").rename(book_dir / "01-tmp.mp3")
    (book_dir / "02.mp3").rename(book_dir / "01.mp3")
    (book_dir / "01-tmp.mp3").rename(book_dir / "02.mp3")

    scan_library(conn, library=library, noise_db=-35, silence_s=0.35)

    still_active = _manifest_id_with_status(conn, book["book_id"], "active")
    assert still_active == active_before
    assert _count_with_status(conn, book["book_id"], "pending") == 1


@requires_ffmpeg
def test_rescan_missing_files_marks_book_incomplete(make_mp3, tmp_path, conn):
    library = tmp_path / "library"
    book_dir = _make_book(make_mp3, library, "Mort", 2)
    scan_library(conn, library=library, noise_db=-35, silence_s=0.35)
    book = conn.execute("SELECT * FROM books").fetchone()
    active_before = _manifest_id_with_status(conn, book["book_id"], "active")

    (book_dir / "02.mp3").unlink()

    scan_library(conn, library=library, noise_db=-35, silence_s=0.35)

    book_after = conn.execute(
        "SELECT * FROM books WHERE book_id = ?", (book["book_id"],)
    ).fetchone()
    assert book_after["incomplete"] == 1
    active_after = _manifest_id_with_status(conn, book["book_id"], "active")
    assert active_after == active_before  # manifest untouched


@requires_ffmpeg
def test_rename_keeps_book_id_same_hash_set_new_path(make_mp3, tmp_path, conn):
    library = tmp_path / "library"
    book_dir = _make_book(make_mp3, library, "Mort", 2)
    scan_library(conn, library=library, noise_db=-35, silence_s=0.35)
    book_before = conn.execute("SELECT * FROM books").fetchone()

    new_dir = library / "Mort Renamed"
    book_dir.rename(new_dir)

    scan_library(conn, library=library, noise_db=-35, silence_s=0.35)

    books = conn.execute("SELECT * FROM books").fetchall()
    assert len(books) == 1
    assert books[0]["book_id"] == book_before["book_id"]
    assert books[0]["path"] == str(new_dir)


@requires_ffmpeg
def test_ambiguous_order_needs_review_no_active_manifest(make_mp3, tmp_path, conn):
    library = tmp_path / "library"
    book_dir = library / "Mort"
    book_dir.mkdir(parents=True)
    # filenames sorted 01,02 but tags say the reverse -> key A valid, disagrees with key B
    p1 = make_mp3("01.mp3", segments=[("tone", 0.2)], freq=300)
    shutil.move(str(p1), book_dir / "01.mp3")
    p2 = make_mp3("02.mp3", segments=[("tone", 0.2)], freq=500)
    shutil.move(str(p2), book_dir / "02.mp3")
    _tag_track(book_dir / "01.mp3", 2)
    _tag_track(book_dir / "02.mp3", 1)

    scan_library(conn, library=library, noise_db=-35, silence_s=0.35)

    book = conn.execute("SELECT * FROM books").fetchone()
    active = conn.execute(
        "SELECT * FROM manifests WHERE book_id = ? AND status = 'active'", (book["book_id"],)
    ).fetchone()
    assert active is None
    needs_review = conn.execute(
        "SELECT COUNT(*) c FROM manifests WHERE book_id = ? AND status = 'needs_review'",
        (book["book_id"],),
    ).fetchone()["c"]
    assert needs_review == 2


# --- concurrency: commit per book, not only at the very end -----------------


@requires_ffmpeg
def test_scan_library_commits_per_book_not_only_at_end(make_mp3, tmp_path, conn, monkeypatch):
    """A rescan holds its write lock only for the duration of one book, so a
    concurrent reader/writer on another connection can see an already-scanned
    book while a later book in the same run is still being processed."""
    library = tmp_path / "library"
    _make_book(make_mp3, library, "Mort", 1)
    _make_book(make_mp3, library, "Ozean", 1)

    original_scan_book = scanner.scan_book
    reached_second_book = threading.Event()
    release_second_book = threading.Event()

    def patched_scan_book(conn_, folder, **kwargs):
        if folder.path.name == "Ozean":
            reached_second_book.set()
            assert release_second_book.wait(timeout=5), "test deadlocked"
        return original_scan_book(conn_, folder, **kwargs)

    monkeypatch.setattr(scanner, "scan_book", patched_scan_book)

    thread = threading.Thread(
        target=scan_library,
        args=(conn,),
        kwargs={"library": library, "noise_db": -35, "silence_s": 0.35},
    )
    thread.start()
    try:
        assert reached_second_book.wait(timeout=5), "scan never reached the second book"

        # A second connection must already see "Mort" as committed, even
        # though the overall scan_library() call has not returned yet.
        db_path = Path(conn.execute("PRAGMA database_list").fetchone()[2])
        other_conn = db.connect(db_path)
        try:
            titles = {r["title"] for r in other_conn.execute("SELECT title FROM books")}
        finally:
            other_conn.close()
        assert titles == {"Mort"}
    finally:
        release_second_book.set()
        thread.join(timeout=5)
