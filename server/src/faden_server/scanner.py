"""Book detection (3.1), orchestration of hashing/duration/pauses/metadata,
and the rescan flow (3.3). This is the only module that touches both the
filesystem and the database; the actual ordering/rescan decisions live in
the pure manifest_rules module.
"""

from __future__ import annotations

import contextlib
import hashlib
import json
import re
import sqlite3
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from .audio_hash import audio_hash
from .duration import AudioProbeError, probe_duration_ms
from .manifest_rules import FileEntry, compute_order, diff_rescan
from .metadata import read_book_tags, read_track_tags, resolve_title_author
from .pauses import PauseDetectionError, compute_pause_offsets

_DISC_RE = re.compile(r"^(cd|disc|disk|teil|part)\s*0*(\d+)$", re.IGNORECASE)


@dataclass(frozen=True)
class BookFile:
    path: Path
    disc_from_folder: int


@dataclass(frozen=True)
class BookFolder:
    path: Path
    files: list[BookFile]


def _disc_number(dirname: str) -> int | None:
    m = _DISC_RE.match(dirname.strip())
    if not m:
        return None
    return int(m.group(2))


def _mp3_files(folder: Path) -> list[Path]:
    return sorted(
        p for p in folder.iterdir() if p.is_file() and p.suffix.lower() == ".mp3"
    )


def detect_book_folders(root: Path) -> list[BookFolder]:
    """Section 3.1: a folder of mp3 files, or a folder of only CD/Disc/Disk/
    Teil/Part-numbered subfolders, is a book. Recurses into folders that are
    neither, to find books nested deeper in the tree."""
    out: list[BookFolder] = []
    _walk(root, out)
    return out


def _walk(folder: Path, out: list[BookFolder]) -> None:
    try:
        entries = sorted(folder.iterdir())
    except OSError:
        return

    subdirs = [e for e in entries if e.is_dir() and not e.name.startswith(".")]

    mp3s = _mp3_files(folder)
    if mp3s:
        out.append(BookFolder(path=folder, files=[BookFile(p, 1) for p in mp3s]))
        return

    if subdirs:
        disc_numbers = {d: _disc_number(d.name) for d in subdirs}
        if all(n is not None for n in disc_numbers.values()):
            files: list[BookFile] = []
            for d in subdirs:
                for p in _mp3_files(d):
                    files.append(BookFile(p, disc_numbers[d]))
            if files:
                out.append(BookFolder(path=folder, files=files))
                return

    for d in subdirs:
        _walk(d, out)


def _now() -> str:
    return datetime.now(UTC).isoformat()


def _manifest_id(hashes: list[str]) -> str:
    return hashlib.sha256("\n".join(hashes).encode("utf-8")).hexdigest()


def _cached_hash(conn: sqlite3.Connection, path: Path) -> str:
    stat = path.stat()
    row = conn.execute(
        "SELECT file_hash FROM files WHERE path = ? AND size = ? AND mtime_ns = ?",
        (str(path), stat.st_size, stat.st_mtime_ns),
    ).fetchone()
    if row:
        return row["file_hash"]
    return audio_hash(path)


def scan_file(conn: sqlite3.Connection, bf: BookFile) -> FileEntry:
    """Hash (cached), probe duration (cached by hash) and read tags for one
    file, and persist the result into `files`."""
    path = bf.path
    stat = path.stat()
    file_hash = _cached_hash(conn, path)

    row = conn.execute(
        "SELECT duration_ms FROM files WHERE file_hash = ?", (file_hash,)
    ).fetchone()
    readable = True
    if row is not None and row["duration_ms"] is not None:
        duration_ms = row["duration_ms"]
    else:
        try:
            duration_ms = probe_duration_ms(path)
        except AudioProbeError:
            duration_ms = 0
            readable = False

    tags = read_track_tags(path)

    conn.execute(
        """
        INSERT INTO files (file_hash, path, size, mtime_ns, duration_ms, disc, track, title)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(file_hash) DO UPDATE SET
            path = excluded.path,
            size = excluded.size,
            mtime_ns = excluded.mtime_ns,
            duration_ms = excluded.duration_ms,
            disc = excluded.disc,
            track = excluded.track,
            title = excluded.title
        """,
        (
            file_hash,
            str(path),
            stat.st_size,
            stat.st_mtime_ns,
            duration_ms,
            tags.disc,
            tags.track,
            tags.title,
        ),
    )

    return FileEntry(
        file_hash=file_hash,
        filename=path.name,
        disc_from_folder=bf.disc_from_folder,
        tag_disc=tags.disc,
        tag_track=tags.track,
        duration_ms=duration_ms,
        readable=readable,
    )


def ensure_pauses(
    conn: sqlite3.Connection, file_hash: str, path: Path, *, noise_db: float, silence_s: float
) -> None:
    """Compute (or reuse) the pause index for a file, cached by hash and by
    the detection params (section 4)."""
    params = {"noise_db": noise_db, "silence_s": silence_s}
    row = conn.execute(
        "SELECT params FROM pauses WHERE file_hash = ?", (file_hash,)
    ).fetchone()
    if row is not None and json.loads(row["params"]) == params:
        return
    try:
        offsets = compute_pause_offsets(path, noise_db=noise_db, silence_s=silence_s)
    except PauseDetectionError:
        offsets = [0]
    conn.execute(
        """
        INSERT INTO pauses (file_hash, offsets_ms, params) VALUES (?, ?, ?)
        ON CONFLICT(file_hash) DO UPDATE SET
            offsets_ms = excluded.offsets_ms, params = excluded.params
        """,
        (file_hash, json.dumps(offsets), json.dumps(params)),
    )


def active_manifest(conn: sqlite3.Connection, book_id: str) -> sqlite3.Row | None:
    return conn.execute(
        "SELECT * FROM manifests WHERE book_id = ? AND status = 'active'", (book_id,)
    ).fetchone()


def manifest_hashes(conn: sqlite3.Connection, manifest_id: str) -> list[str]:
    rows = conn.execute(
        "SELECT file_hash FROM manifest_files WHERE manifest_id = ? ORDER BY idx",
        (manifest_id,),
    ).fetchall()
    return [r["file_hash"] for r in rows]


def _next_version(conn: sqlite3.Connection, book_id: str) -> int:
    row = conn.execute(
        "SELECT COALESCE(MAX(version), 0) AS v FROM manifests WHERE book_id = ?", (book_id,)
    ).fetchone()
    return row["v"] + 1


def _create_manifest(
    conn: sqlite3.Connection, book_id: str, hashes: list[str], status: str, version: int
) -> str:
    manifest_id = _manifest_id(hashes)
    conn.execute(
        """
        INSERT INTO manifests (manifest_id, book_id, version, status, created_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(manifest_id) DO UPDATE SET status = excluded.status
        """,
        (manifest_id, book_id, version, status, _now()),
    )
    for idx, file_hash in enumerate(hashes):
        conn.execute(
            "INSERT OR IGNORE INTO manifest_files (manifest_id, idx, file_hash) VALUES (?, ?, ?)",
            (manifest_id, idx, file_hash),
        )
    return manifest_id


def scan_book(
    conn: sqlite3.Connection,
    folder: BookFolder,
    *,
    book_id: str | None,
    noise_db: float,
    silence_s: float,
) -> str:
    """Scan a single book folder (already located on disk) and reconcile it
    with the database: hash/probe/tag every file, decide the order (3.2),
    and apply the rescan rules (3.3)."""
    entries: list[FileEntry] = []
    path_by_hash: dict[str, Path] = {}
    for bf in folder.files:
        fe = scan_file(conn, bf)
        entries.append(fe)
        path_by_hash[fe.file_hash] = bf.path

    for fe in entries:
        if fe.readable:
            ensure_pauses(
                conn,
                fe.file_hash,
                path_by_hash[fe.file_hash],
                noise_db=noise_db,
                silence_s=silence_s,
            )

    order_result = compute_order(entries)

    album, author_tag = (None, None)
    if folder.files:
        album, author_tag = read_book_tags(folder.files[0].path)
    title, author = resolve_title_author(folder.path.name, album, author_tag)

    is_new = book_id is None
    if is_new:
        book_id = str(uuid.uuid4())
        conn.execute(
            "INSERT INTO books (book_id, path, title, author, incomplete, created_at) "
            "VALUES (?, ?, ?, ?, 0, ?)",
            (book_id, str(folder.path), title, author, _now()),
        )
        active_row = None
    else:
        conn.execute(
            "UPDATE books SET path = ?, title = ?, author = ? WHERE book_id = ?",
            (str(folder.path), title, author, book_id),
        )
        active_row = active_manifest(conn, book_id)

    active_hashes = manifest_hashes(conn, active_row["manifest_id"]) if active_row else None
    current_hashes = {fe.file_hash for fe in entries}
    missing = (set(active_hashes) - current_hashes) if active_hashes else set()

    outcome = diff_rescan(
        active_hashes, order_result.status, order_result.candidates, missing_from_active=missing
    )

    if outcome.action == "incomplete":
        conn.execute("UPDATE books SET incomplete = 1 WHERE book_id = ?", (book_id,))
        return book_id

    conn.execute("UPDATE books SET incomplete = 0 WHERE book_id = ?", (book_id,))

    if outcome.action == "none":
        return book_id

    version = _next_version(conn, book_id)
    for i, (hashes, status) in enumerate(outcome.new_manifests):
        _create_manifest(conn, book_id, hashes, status, version + i)

    if outcome.action == "auto_active" and active_row is not None:
        conn.execute(
            "UPDATE manifests SET status = 'superseded' WHERE manifest_id = ?",
            (active_row["manifest_id"],),
        )

    return book_id


def _hash_only(conn: sqlite3.Connection, path: Path) -> str | None:
    with contextlib.suppress(OSError):
        return _cached_hash(conn, path)
    return None


@dataclass(frozen=True)
class ScanSummary:
    books_scanned: int
    books_new: int
    books_renamed: int
    books_missing: int


def scan_library(
    conn: sqlite3.Connection, *, library: Path, noise_db: float, silence_s: float
) -> ScanSummary:
    """Full rescan of the library folder (section 3.1-3.3)."""
    folders = detect_book_folders(library)
    folders_by_path = {str(f.path): f for f in folders}

    existing = conn.execute("SELECT book_id, path FROM books").fetchall()
    existing_paths = {r["path"] for r in existing}
    matched: set[str] = set()

    books_scanned = 0
    books_new = 0
    books_renamed = 0

    # 1) books whose folder path still exists: rescan in place.
    #
    # Committed per book (not only once at the end) so the write lock this
    # connection holds is released between books; a scan of a large library
    # can run for minutes, and a long-held single transaction would starve
    # concurrent writers (event pushes, manifest confirms) for that whole
    # time even with a generous busy_timeout.
    for row in existing:
        if row["path"] in folders_by_path:
            scan_book(
                conn,
                folders_by_path[row["path"]],
                book_id=row["book_id"],
                noise_db=noise_db,
                silence_s=silence_s,
            )
            matched.add(row["book_id"])
            books_scanned += 1
            conn.commit()

    remaining_folders = [f for f in folders if str(f.path) not in existing_paths]
    unmatched_books = [r for r in existing if r["book_id"] not in matched]

    # 2) rename detection: same set of file hashes under a new path.
    for book_row in unmatched_books:
        active = active_manifest(conn, book_row["book_id"])
        if active is None:
            continue
        active_set = set(manifest_hashes(conn, active["manifest_id"]))
        for folder in list(remaining_folders):
            hashes = set()
            ok = True
            for bf in folder.files:
                h = _hash_only(conn, bf.path)
                if h is None:
                    ok = False
                    break
                hashes.add(h)
            if ok and hashes == active_set:
                scan_book(
                    conn,
                    folder,
                    book_id=book_row["book_id"],
                    noise_db=noise_db,
                    silence_s=silence_s,
                )
                matched.add(book_row["book_id"])
                remaining_folders.remove(folder)
                books_renamed += 1
                books_scanned += 1
                conn.commit()
                break

    # 3) remaining folders are new books.
    for folder in remaining_folders:
        scan_book(conn, folder, book_id=None, noise_db=noise_db, silence_s=silence_s)
        books_new += 1
        books_scanned += 1
        conn.commit()

    # 4) books whose folder vanished entirely (not matched, not renamed).
    books_missing = 0
    for book_row in unmatched_books:
        if book_row["book_id"] not in matched:
            conn.execute(
                "UPDATE books SET incomplete = 1 WHERE book_id = ?", (book_row["book_id"],)
            )
            books_missing += 1

    conn.commit()
    return ScanSummary(
        books_scanned=books_scanned,
        books_new=books_new,
        books_renamed=books_renamed,
        books_missing=books_missing,
    )
