"""Tests for library_path.py: the path-traversal protection behind the
setup endpoints (docs/ARCHITEKTUR.md sections 2, 10, 12; decision E12).

This is the security-critical part of M1b, so it gets its own file with
explicit attack-variant cases, on top of the API-level tests in
test_setup_api.py.
"""

from __future__ import annotations

import sqlite3

import pytest

from faden_server.db import connect
from faden_server.library_path import (
    PathTraversalError,
    effective_library,
    get_library_path,
    list_subdirs,
    resolve_within_root,
    set_library_path,
)


@pytest.fixture
def root(tmp_path):
    r = tmp_path / "library"
    r.mkdir()
    (r / "books").mkdir()
    (r / "books" / "Mort").mkdir()
    (r / "books" / "empty.txt").write_text("not a folder")
    return r


@pytest.fixture
def conn(tmp_path) -> sqlite3.Connection:
    c = connect(tmp_path / "data" / "faden.db")
    yield c
    c.close()


# --- resolve_within_root: happy path ---------------------------------------


def test_empty_path_resolves_to_root(root):
    assert resolve_within_root(root, "") == root.resolve()


def test_relative_subpath_resolves(root):
    assert resolve_within_root(root, "books") == (root / "books").resolve()


def test_nested_relative_subpath_resolves(root):
    assert resolve_within_root(root, "books/Mort") == (root / "books" / "Mort").resolve()


# --- resolve_within_root: attack variants -----------------------------------


def test_dotdot_traversal_rejected(root):
    with pytest.raises(PathTraversalError):
        resolve_within_root(root, "../../etc")


def test_dotdot_in_the_middle_rejected(root):
    with pytest.raises(PathTraversalError):
        resolve_within_root(root, "books/../../etc")


def test_bare_dotdot_rejected(root):
    with pytest.raises(PathTraversalError):
        resolve_within_root(root, "..")


def test_absolute_path_rejected(root):
    with pytest.raises(PathTraversalError):
        resolve_within_root(root, "/etc/passwd")


def test_absolute_path_to_root_itself_rejected(root):
    # Even an absolute path that happens to equal the root must be rejected:
    # the contract is "relative only", not "anything that resolves inside".
    with pytest.raises(PathTraversalError):
        resolve_within_root(root, str(root))


def test_nul_byte_rejected(root):
    with pytest.raises(PathTraversalError):
        resolve_within_root(root, "books\x00/../../etc")


def test_symlink_escaping_root_rejected(root, tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "secret.txt").write_text("nope")
    (root / "escape").symlink_to(outside)

    with pytest.raises(PathTraversalError):
        resolve_within_root(root, "escape")


def test_symlink_escaping_root_via_subpath_rejected(root, tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    (root / "escape").symlink_to(outside)

    with pytest.raises(PathTraversalError):
        resolve_within_root(root, "escape/secret.txt")


def test_symlink_within_root_is_allowed(root):
    (root / "alias").symlink_to(root / "books", target_is_directory=True)
    assert resolve_within_root(root, "alias") == (root / "books").resolve()


# --- list_subdirs ------------------------------------------------------------


def test_list_subdirs_returns_only_directories(root):
    assert list_subdirs(root, "books") == ["Mort"]


def test_list_subdirs_sorted(root):
    (root / "books" / "Zzz").mkdir()
    (root / "books" / "Aaa").mkdir()
    assert list_subdirs(root, "books") == ["Aaa", "Mort", "Zzz"]


def test_list_subdirs_root(root):
    assert list_subdirs(root, "") == ["books"]


def test_list_subdirs_missing_path_raises_file_not_found(root):
    with pytest.raises(FileNotFoundError):
        list_subdirs(root, "does-not-exist")


def test_list_subdirs_on_a_file_raises_not_a_directory(root):
    with pytest.raises(NotADirectoryError):
        list_subdirs(root, "books/empty.txt")


def test_list_subdirs_traversal_still_rejected(root):
    with pytest.raises(PathTraversalError):
        list_subdirs(root, "../../etc")


# --- settings.library_path get/set -----------------------------------------


def test_get_library_path_defaults_to_empty(conn):
    assert get_library_path(conn) == ""


def test_set_then_get_library_path(conn):
    set_library_path(conn, "books/Mort")
    assert get_library_path(conn) == "books/Mort"


def test_set_library_path_overwrites(conn):
    set_library_path(conn, "a")
    set_library_path(conn, "b")
    assert get_library_path(conn) == "b"


# --- effective_library --------------------------------------------------


def test_effective_library_defaults_to_root_when_unset(root):
    assert effective_library(root, "") == root.resolve()


def test_effective_library_uses_stored_subpath(root):
    assert effective_library(root, "books") == (root / "books").resolve()


def test_effective_library_falls_back_to_root_for_malicious_stored_value(root):
    # settings.library_path can also be edited directly in the database
    # (section 12), so a `..` that made it in there must not send the
    # scanner outside `root` either.
    assert effective_library(root, "../../etc") == root.resolve()


def test_effective_library_falls_back_to_root_for_escaping_symlink(root, tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    (root / "escape").symlink_to(outside)
    assert effective_library(root, "escape") == root.resolve()
