# syntax=docker/dockerfile:1

# Static ffmpeg/ffprobe build (avoids relying on the distro's package
# repositories, which are not reachable from every build environment).
FROM mwader/static-ffmpeg:7.0.2 AS ffmpeg

FROM python:3.12-slim

COPY --from=ffmpeg /ffmpeg /usr/local/bin/ffmpeg
COPY --from=ffmpeg /ffprobe /usr/local/bin/ffprobe

# sqlite3 CLI: /data is a named Docker volume (docker-compose.yml), not a
# host bind mount, so `server/scripts/backup.sh` (section 12) is meant to
# run inside the container via `docker compose exec faden ...`.
RUN apt-get update && apt-get install -y --no-install-recommends sqlite3 \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir uv

# Dedicated non-root user (fixed uid/gid for reproducibility). The library
# mount stays read-only (invariant 8) regardless of who reads it; this is
# about not running the process itself as root.
RUN groupadd --system --gid 10001 faden \
    && useradd --system --uid 10001 --gid faden --no-create-home --home-dir /app faden

WORKDIR /app

# Install dependencies first (better layer caching), then the project itself.
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-install-project --no-dev

COPY src ./src
RUN uv sync --frozen --no-dev

COPY scripts ./scripts
RUN chmod +x ./scripts/backup.sh

COPY static ./static

# /data is only ever a named volume (faden-data, see docker-compose.yml),
# never a host bind mount; creating it here, owned by faden, means Docker
# initializes a fresh volume with that ownership on first use. An existing
# volume created by an older, root-run image keeps its root ownership and
# needs a one-off `chown -R 10001:10001` (e.g. via a throwaway root
# container mounting it) before this image can write to it.
RUN mkdir -p /data \
    && chown -R faden:faden /app /data

ENV PATH="/app/.venv/bin:${PATH}"

EXPOSE 8787

USER faden

CMD ["faden-server"]
