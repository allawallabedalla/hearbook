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

WORKDIR /app

# Install dependencies first (better layer caching), then the project itself.
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-install-project --no-dev

COPY src ./src
RUN uv sync --frozen --no-dev

COPY scripts ./scripts
RUN chmod +x ./scripts/backup.sh

COPY static ./static

ENV PATH="/app/.venv/bin:${PATH}"

EXPOSE 8787

CMD ["faden-server"]
