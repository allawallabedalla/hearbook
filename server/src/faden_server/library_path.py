"""Library root path resolution for the M1b setup endpoints
(docs/ARCHITEKTUR.md sections 2, 10, 12; decision E12).

This is the security-critical part of the milestone: `resolve_within_root`
is the one place that turns an untrusted relative path (from the API, or
from `settings.library_path`, which section 12 says may also be edited
directly in the database) into a filesystem path, and it is the only
function that decides whether that path is allowed to leave
`FADEN_LIBRARY`.

Invariant 8 (the audiobook folder is only ever read, never written): every
function here only reads the filesystem (`Path.resolve()`,
`Path.iterdir()`) and never creates, moves or deletes anything under
`root`.
"""

from __future__ import annotations

import logging
import sqlite3
from pathlib import Path

logger = logging.getLogger(__name__)

LIBRARY_PATH_KEY = "library_path"


class PathTraversalError(ValueError):
    """A requested relative path would leave the library root, whether via
    an absolute path, a `..` segment, or a symlink resolving outside it."""


def resolve_within_root(root: Path, rel: str) -> Path:
    """Resolve `rel` against `root` and verify the result stays inside
    `root`.

    - Absolute paths are rejected outright.
    - `..` segments are rejected outright (belt and suspenders: the
      containment check below would also catch them, since it runs after
      resolving symlinks and `..`).
    - Symlinks are resolved (`Path.resolve()`) before the containment
      check, so a symlink inside `root` that points outside it is caught
      too, not just literal `..` in the request.
    """
    if "\x00" in rel:
        raise PathTraversalError("path must not contain a NUL byte")

    candidate_rel = Path(rel)
    if candidate_rel.is_absolute():
        raise PathTraversalError("path must be relative, not absolute")
    if ".." in candidate_rel.parts:
        raise PathTraversalError("path must not contain '..'")

    root_resolved = root.resolve()
    candidate = (root_resolved / candidate_rel).resolve()
    try:
        candidate.relative_to(root_resolved)
    except ValueError:
        raise PathTraversalError("path escapes the library root") from None
    return candidate


def list_subdirs(root: Path, rel: str) -> list[str]:
    """Section 10: subdirectory names (not files) of `root` / `rel`,
    sorted. Read-only (invariant 8)."""
    target = resolve_within_root(root, rel)
    if not target.exists():
        raise FileNotFoundError(str(target))
    if not target.is_dir():
        raise NotADirectoryError(str(target))
    return sorted(p.name for p in target.iterdir() if p.is_dir())


def get_library_path(conn: sqlite3.Connection) -> str:
    """The stored `settings.library_path` (section 2); "" (the root
    itself) if unset."""
    row = conn.execute("SELECT value FROM settings WHERE key = ?", (LIBRARY_PATH_KEY,)).fetchone()
    return row["value"] if row else ""


def set_library_path(conn: sqlite3.Connection, path: str) -> None:
    conn.execute(
        "INSERT INTO settings (key, value) VALUES (?, ?) "
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        (LIBRARY_PATH_KEY, path),
    )
    conn.commit()


def effective_library(root: Path, library_path: str) -> Path:
    """`FADEN_LIBRARY` + `settings.library_path` (sections 2, 12): the
    folder the scanner actually reads.

    Falls back to `root` itself when `library_path` is unset, or when the
    stored value would escape `root`. The latter re-checks, at read time,
    what the setup endpoint already validates on write: section 12 allows
    `library_path` to be edited directly in the database, bypassing that
    validation, and this must not be able to send the scanner outside
    `root` (invariant 8).
    """
    if not library_path:
        return root.resolve()
    try:
        return resolve_within_root(root, library_path)
    except PathTraversalError:
        logger.warning(
            "settings.library_path %r escapes FADEN_LIBRARY, falling back to the root",
            library_path,
        )
        return root.resolve()
