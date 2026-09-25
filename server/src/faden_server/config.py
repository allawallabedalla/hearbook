"""Environment-based configuration, per docs/ARCHITEKTUR.md section 12."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    token: str
    library: Path
    data: Path
    port: int
    rescan_min: int
    silence_db: float
    silence_s: float
    # FADEN_GENRE_LOOKUP: look up missing genres in public catalogs after a
    # scan (section 3.7). Defaulted so Settings(...) in tests stays short.
    genre_lookup: bool = True
    # FADEN_LOG_LEVEL: level of Faden's own loggers (faden_server.*);
    # DEBUG shows e.g. the raw catalog categories of every genre lookup.
    log_level: str = "INFO"

    @property
    def db_path(self) -> Path:
        return self.data / "faden.db"

    @property
    def covers_dir(self) -> Path:
        return self.data / "covers"


_FALSE_WORDS = frozenset({"0", "false", "no", "off"})


def _flag(value: str | None, *, default: bool) -> bool:
    if value is None or not value.strip():
        return default
    return value.strip().lower() not in _FALSE_WORDS


_LOG_LEVELS = ("DEBUG", "INFO", "WARNING", "ERROR")


def _log_level(value: str | None) -> str:
    level = (value or "").strip().upper()
    return level if level in _LOG_LEVELS else "INFO"


def load_settings(env: dict[str, str] | None = None) -> Settings:
    """Read settings from the environment (or a supplied mapping, for tests)."""
    src = env if env is not None else os.environ

    token = src.get("FADEN_TOKEN")
    if not token:
        raise RuntimeError("FADEN_TOKEN is required (see .env.example)")
    if token == "change-me" or len(token) < 16:
        raise RuntimeError(
            "FADEN_TOKEN must not be the 'change-me' placeholder and must be at "
            "least 16 characters long (see .env.example, e.g. `openssl rand -hex 32`)"
        )

    return Settings(
        token=token,
        library=Path(src.get("FADEN_LIBRARY", "/library")),
        data=Path(src.get("FADEN_DATA", "/data")),
        port=int(src.get("FADEN_PORT", "8787")),
        rescan_min=int(src.get("FADEN_RESCAN_MIN", "10")),
        silence_db=float(src.get("FADEN_SILENCE_DB", "-35")),
        silence_s=float(src.get("FADEN_SILENCE_S", "0.35")),
        genre_lookup=_flag(src.get("FADEN_GENRE_LOOKUP"), default=True),
        log_level=_log_level(src.get("FADEN_LOG_LEVEL")),
    )
