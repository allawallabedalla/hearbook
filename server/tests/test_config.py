"""Tests for config.load_settings per docs/ARCHITEKTUR.md section 12."""

from __future__ import annotations

import pytest

from faden_server.config import load_settings

VALID_TOKEN = "a" * 32


def _env(**overrides) -> dict[str, str]:
    env = {"FADEN_TOKEN": VALID_TOKEN}
    env.update(overrides)
    return env


def test_missing_token_raises():
    with pytest.raises(RuntimeError, match="required"):
        load_settings({})


def test_empty_token_raises():
    with pytest.raises(RuntimeError, match="required"):
        load_settings(_env(FADEN_TOKEN=""))


def test_placeholder_token_raises():
    with pytest.raises(RuntimeError, match="change-me"):
        load_settings(_env(FADEN_TOKEN="change-me"))


def test_short_token_raises():
    with pytest.raises(RuntimeError, match="16 characters"):
        load_settings(_env(FADEN_TOKEN="short-token-123"))


def test_valid_token_is_accepted():
    settings = load_settings(_env())
    assert settings.token == VALID_TOKEN
