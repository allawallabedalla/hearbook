"""SQLite access, WAL mode, schema per docs/ARCHITEKTUR.md section 2."""

from __future__ import annotations

import sqlite3
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS files (
    file_hash   TEXT PRIMARY KEY,
    path        TEXT NOT NULL,
    size        INTEGER NOT NULL,
    mtime_ns    INTEGER NOT NULL,
    duration_ms INTEGER,
    disc        INTEGER,
    track       INTEGER,
    title       TEXT
);
CREATE INDEX IF NOT EXISTS idx_files_path ON files(path);

CREATE TABLE IF NOT EXISTS books (
    book_id    TEXT PRIMARY KEY,
    path       TEXT NOT NULL,
    title      TEXT,
    author     TEXT,
    incomplete INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS manifests (
    manifest_id TEXT PRIMARY KEY,
    book_id     TEXT NOT NULL REFERENCES books(book_id),
    version     INTEGER NOT NULL,
    status      TEXT NOT NULL CHECK (status IN ('active', 'pending', 'needs_review', 'superseded')),
    created_at  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_manifests_book ON manifests(book_id, status);

CREATE TABLE IF NOT EXISTS manifest_files (
    manifest_id TEXT NOT NULL REFERENCES manifests(manifest_id),
    idx         INTEGER NOT NULL,
    file_hash   TEXT NOT NULL REFERENCES files(file_hash),
    PRIMARY KEY (manifest_id, idx)
);

CREATE TABLE IF NOT EXISTS pauses (
    file_hash  TEXT PRIMARY KEY REFERENCES files(file_hash),
    offsets_ms TEXT NOT NULL,
    params     TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS covers (
    file_hash TEXT PRIMARY KEY REFERENCES files(file_hash),
    mime      TEXT NOT NULL,
    data      BLOB NOT NULL
);

-- Part of the data model (section 2); the event endpoints themselves are M2.
CREATE TABLE IF NOT EXISTS events (
    seq         INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id    TEXT UNIQUE NOT NULL,
    book_id     TEXT NOT NULL,
    device_id   TEXT NOT NULL,
    body        TEXT NOT NULL,
    received_at TEXT NOT NULL,
    skew_flag   INTEGER NOT NULL DEFAULT 0
);

-- Small server-side key/value store (section 2). Currently holds only
-- `library_path` (M1b, decision E12); see library_path.py.
CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""


# How long a connection waits for a write lock held by another connection
# before raising "database is locked" (sqlite3's default is 5000ms, which a
# multi-minute library scan can easily outlast for a concurrent writer).
BUSY_TIMEOUT_MS = 30_000


def connect(db_path: Path) -> sqlite3.Connection:
    """Open a WAL-mode connection and make sure the schema exists."""
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute(f"PRAGMA busy_timeout={BUSY_TIMEOUT_MS}")
    conn.executescript(SCHEMA)
    conn.commit()
    return conn
