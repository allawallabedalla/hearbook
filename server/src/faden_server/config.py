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

    @property
    def db_path(self) -> Path:
        return self.data / "faden.db"

    @property
    def covers_dir(self) -> Path:
        return self.data / "covers"


def load_settings(env: dict[str, str] | None = None) -> Settings:
    """Read settings from the environment (or a supplied mapping, for tests)."""
    src = env if env is not None else os.environ

    token = src.get("FADEN_TOKEN")
    if not token:
        raise RuntimeError("FADEN_TOKEN is required (see .env.example)")

    return Settings(
        token=token,
        library=Path(src.get("FADEN_LIBRARY", "/library")),
        data=Path(src.get("FADEN_DATA", "/data")),
        port=int(src.get("FADEN_PORT", "8787")),
        rescan_min=int(src.get("FADEN_RESCAN_MIN", "10")),
        silence_db=float(src.get("FADEN_SILENCE_DB", "-35")),
        silence_s=float(src.get("FADEN_SILENCE_S", "0.35")),
    )
