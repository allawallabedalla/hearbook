"""Tests for server/scripts/backup.sh per docs/ARCHITEKTUR.md section 12.

Skipped when the sqlite3 CLI isn't installed (it isn't part of the Python
runtime; see the requires_sqlite3_cli skip below).
"""

from __future__ import annotations

import datetime
import sqlite3
import subprocess
from pathlib import Path

from .conftest import requires_sqlite3_cli

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "backup.sh"


def _make_db(path: Path) -> None:
    conn = sqlite3.connect(path)
    conn.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
    conn.execute("INSERT INTO t (v) VALUES ('hello')")
    conn.commit()
    conn.close()


@requires_sqlite3_cli
def test_backup_script_creates_dated_snapshot(tmp_path):
    db_path = tmp_path / "faden.db"
    backup_dir = tmp_path / "backup"
    _make_db(db_path)

    result = subprocess.run(
        ["sh", str(SCRIPT), str(db_path), str(backup_dir)],
        check=True,
        capture_output=True,
        text=True,
    )

    today = datetime.date.today().isoformat()
    expected = backup_dir / f"faden-{today}.db"
    assert expected.is_file()
    assert str(expected) in result.stdout

    # the backup is a real, independent, readable SQLite database.
    conn = sqlite3.connect(expected)
    rows = conn.execute("SELECT v FROM t").fetchall()
    conn.close()
    assert rows == [("hello",)]


@requires_sqlite3_cli
def test_backup_script_defaults_to_faden_data_env(tmp_path, monkeypatch):
    data_dir = tmp_path / "data"
    data_dir.mkdir()
    _make_db(data_dir / "faden.db")

    subprocess.run(
        ["sh", str(SCRIPT)],
        check=True,
        capture_output=True,
        text=True,
        env={**dict(PATH=__import__("os").environ["PATH"]), "FADEN_DATA": str(data_dir)},
    )

    today = datetime.date.today().isoformat()
    assert (data_dir / "backup" / f"faden-{today}.db").is_file()


def test_backup_script_fails_cleanly_when_db_missing(tmp_path):
    result = subprocess.run(
        ["sh", str(SCRIPT), str(tmp_path / "missing.db"), str(tmp_path / "backup")],
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0
    assert "not found" in result.stderr
