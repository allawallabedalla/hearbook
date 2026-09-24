"""FastAPI app: the endpoints from docs/ARCHITEKTUR.md section 10."""

from __future__ import annotations

import json
import logging
import mimetypes
import sqlite3
import time
from datetime import UTC, datetime
from pathlib import Path

from fastapi import APIRouter, Depends, FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse

from . import db
from .auth import make_auth_dependency
from .config import Settings
from .events import PUSH_LIMIT, EventValidationError, is_skewed, validate_event
from .metadata import extract_embedded_cover, find_cover_file
from .scanner import active_manifest, manifest_hashes, scan_library

RANGE_BLOCK = 1024 * 1024

logger = logging.getLogger(__name__)


def _now() -> str:
    return datetime.now(UTC).isoformat()


def _manifest_files_detail(conn: sqlite3.Connection, manifest_id: str) -> list[dict]:
    rows = conn.execute(
        """
        SELECT mf.idx, f.file_hash, f.duration_ms, f.disc, f.track, f.title
        FROM manifest_files mf
        JOIN files f ON f.file_hash = mf.file_hash
        WHERE mf.manifest_id = ?
        ORDER BY mf.idx
        """,
        (manifest_id,),
    ).fetchall()
    return [dict(r) for r in rows]


def _manifest_payload(conn: sqlite3.Connection, manifest_row: sqlite3.Row) -> dict:
    return {
        "manifest_id": manifest_row["manifest_id"],
        "version": manifest_row["version"],
        "status": manifest_row["status"],
        "files": _manifest_files_detail(conn, manifest_row["manifest_id"]),
    }


def _book_status(
    conn: sqlite3.Connection, book_row: sqlite3.Row, active_row: sqlite3.Row | None
) -> str:
    if book_row["incomplete"]:
        return "incomplete"
    if conn.execute(
        "SELECT 1 FROM manifests WHERE book_id = ? AND status = 'needs_review' LIMIT 1",
        (book_row["book_id"],),
    ).fetchone():
        return "needs_review"
    if conn.execute(
        "SELECT 1 FROM manifests WHERE book_id = ? AND status = 'pending' LIMIT 1",
        (book_row["book_id"],),
    ).fetchone():
        return "pending"
    return "ok" if active_row else "empty"


def _book_duration_ms(conn: sqlite3.Connection, manifest_id: str) -> int | None:
    row = conn.execute(
        """
        SELECT SUM(f.duration_ms) AS d
        FROM manifest_files mf JOIN files f ON f.file_hash = mf.file_hash
        WHERE mf.manifest_id = ?
        """,
        (manifest_id,),
    ).fetchone()
    return row["d"]


def _get_book_or_404(conn: sqlite3.Connection, book_id: str) -> sqlite3.Row:
    book = conn.execute("SELECT * FROM books WHERE book_id = ?", (book_id,)).fetchone()
    if book is None:
        raise HTTPException(status_code=404, detail="book not found")
    return book


def _resolve_cover(
    conn: sqlite3.Connection, book_row: sqlite3.Row
) -> tuple[str, bytes] | None:
    folder = Path(book_row["path"])
    if folder.is_dir():
        cover_path = find_cover_file(folder)
        if cover_path is not None:
            mime = mimetypes.guess_type(str(cover_path))[0] or "application/octet-stream"
            return mime, cover_path.read_bytes()

    active = active_manifest(conn, book_row["book_id"])
    if active is None:
        return None
    hashes = manifest_hashes(conn, active["manifest_id"])
    if not hashes:
        return None
    first_hash = hashes[0]

    cached = conn.execute(
        "SELECT mime, data FROM covers WHERE file_hash = ?", (first_hash,)
    ).fetchone()
    if cached is not None:
        return cached["mime"], cached["data"]

    file_row = conn.execute(
        "SELECT path FROM files WHERE file_hash = ?", (first_hash,)
    ).fetchone()
    if file_row is None or not Path(file_row["path"]).is_file():
        return None

    embedded = extract_embedded_cover(Path(file_row["path"]))
    if embedded is None:
        return None

    conn.execute(
        "INSERT OR REPLACE INTO covers (file_hash, mime, data) VALUES (?, ?, ?)",
        (first_hash, embedded.mime, embedded.data),
    )
    conn.commit()
    return embedded.mime, embedded.data


def _parse_range(header: str, file_size: int) -> tuple[int, int] | None:
    """Single-range "bytes=start-end" per RFC 7233. Returns None if invalid."""
    if not header.startswith("bytes="):
        return None
    spec = header[len("bytes=") :].split(",")[0].strip()
    if "-" not in spec:
        return None
    start_s, _, end_s = spec.partition("-")
    try:
        if start_s == "":
            if end_s == "":
                return None
            length = int(end_s)
            if length <= 0:
                return None
            start = max(file_size - length, 0)
            end = file_size - 1
        else:
            start = int(start_s)
            end = int(end_s) if end_s else file_size - 1
    except ValueError:
        return None

    if start > end or start >= file_size or start < 0:
        return None
    return start, min(end, file_size - 1)


def _stream_range(path: Path, start: int, end: int):
    remaining = end - start + 1
    with open(path, "rb") as f:
        f.seek(start)
        while remaining > 0:
            chunk = f.read(min(RANGE_BLOCK, remaining))
            if not chunk:
                break
            remaining -= len(chunk)
            yield chunk


def create_app(settings: Settings) -> FastAPI:
    app = FastAPI(title="Faden")
    app.state.settings = settings

    def get_conn():
        conn = db.connect(settings.db_path)
        try:
            yield conn
        finally:
            conn.close()

    require_token = make_auth_dependency(settings.token)

    public = APIRouter()

    @public.get("/api/v1/health")
    def health() -> dict:
        return {"status": "ok"}

    api = APIRouter(dependencies=[Depends(require_token)])

    @api.get("/api/v1/books")
    def list_books(conn: sqlite3.Connection = Depends(get_conn)) -> list[dict]:
        books = conn.execute("SELECT * FROM books ORDER BY title").fetchall()
        out = []
        for book in books:
            active = active_manifest(conn, book["book_id"])
            duration_ms = _book_duration_ms(conn, active["manifest_id"]) if active else None
            out.append(
                {
                    "book_id": book["book_id"],
                    "title": book["title"],
                    "author": book["author"],
                    "duration_ms": duration_ms,
                    "status": _book_status(conn, book, active),
                }
            )
        return out

    @api.get("/api/v1/books/{book_id}")
    def get_book(book_id: str, conn: sqlite3.Connection = Depends(get_conn)) -> dict:
        book = _get_book_or_404(conn, book_id)
        active = active_manifest(conn, book_id)
        candidates = conn.execute(
            "SELECT * FROM manifests WHERE book_id = ? AND status IN ('pending', 'needs_review') "
            "ORDER BY version",
            (book_id,),
        ).fetchall()
        return {
            "book_id": book["book_id"],
            "title": book["title"],
            "author": book["author"],
            "incomplete": bool(book["incomplete"]),
            "status": _book_status(conn, book, active),
            "active_manifest": _manifest_payload(conn, active) if active else None,
            "candidates": [_manifest_payload(conn, c) for c in candidates],
        }

    @api.get("/api/v1/books/{book_id}/cover")
    def get_cover(book_id: str, conn: sqlite3.Connection = Depends(get_conn)):
        book = _get_book_or_404(conn, book_id)
        cover = _resolve_cover(conn, book)
        if cover is None:
            raise HTTPException(status_code=404, detail="no cover")
        mime, data = cover
        return StreamingResponse(iter([data]), media_type=mime)

    @api.get("/api/v1/books/{book_id}/pauses")
    def get_pauses(book_id: str, conn: sqlite3.Connection = Depends(get_conn)) -> dict:
        _get_book_or_404(conn, book_id)
        active = active_manifest(conn, book_id)
        if active is None:
            return {}
        result = {}
        for file_hash in manifest_hashes(conn, active["manifest_id"]):
            row = conn.execute(
                "SELECT offsets_ms FROM pauses WHERE file_hash = ?", (file_hash,)
            ).fetchone()
            result[file_hash] = json.loads(row["offsets_ms"]) if row else [0]
        return result

    @api.post("/api/v1/books/{book_id}/manifests/{manifest_id}/confirm")
    def confirm_manifest(
        book_id: str, manifest_id: str, conn: sqlite3.Connection = Depends(get_conn)
    ) -> dict:
        _get_book_or_404(conn, book_id)
        manifest = conn.execute(
            "SELECT * FROM manifests WHERE manifest_id = ? AND book_id = ?",
            (manifest_id, book_id),
        ).fetchone()
        if manifest is None:
            raise HTTPException(status_code=404, detail="manifest not found")
        if manifest["status"] not in ("pending", "needs_review"):
            raise HTTPException(status_code=409, detail="manifest is not a candidate")

        conn.execute(
            "UPDATE manifests SET status = 'superseded' "
            "WHERE book_id = ? AND status IN ('active', 'pending', 'needs_review') "
            "AND manifest_id != ?",
            (book_id, manifest_id),
        )
        conn.execute(
            "UPDATE manifests SET status = 'active' WHERE manifest_id = ?", (manifest_id,)
        )
        conn.execute("UPDATE books SET incomplete = 0 WHERE book_id = ?", (book_id,))
        conn.commit()
        return {"manifest_id": manifest_id, "status": "active"}

    @api.get("/api/v1/files/{file_hash}")
    def get_file(
        file_hash: str, request: Request, conn: sqlite3.Connection = Depends(get_conn)
    ):
        row = conn.execute(
            "SELECT path FROM files WHERE file_hash = ?", (file_hash,)
        ).fetchone()
        if row is None:
            raise HTTPException(status_code=404, detail="file not found")
        path = Path(row["path"])
        if not path.is_file():
            raise HTTPException(status_code=404, detail="file missing on disk")
        file_size = path.stat().st_size

        range_header = request.headers.get("range")
        if range_header is None:
            headers = {
                "Accept-Ranges": "bytes",
                "Content-Length": str(file_size),
                "ETag": file_hash,
            }
            return StreamingResponse(
                _stream_range(path, 0, file_size - 1), media_type="audio/mpeg", headers=headers
            )

        parsed = _parse_range(range_header, file_size)
        if parsed is None:
            raise HTTPException(
                status_code=416, headers={"Content-Range": f"bytes */{file_size}"}
            )
        start, end = parsed
        headers = {
            "Accept-Ranges": "bytes",
            "Content-Range": f"bytes {start}-{end}/{file_size}",
            "Content-Length": str(end - start + 1),
            "ETag": file_hash,
        }
        return StreamingResponse(
            _stream_range(path, start, end),
            status_code=206,
            media_type="audio/mpeg",
            headers=headers,
        )

    @api.post("/api/v1/events")
    def post_events(
        events: list[dict], conn: sqlite3.Connection = Depends(get_conn)
    ) -> dict:
        """Section 6: push up to 500 events, idempotent on event_id."""
        if len(events) > PUSH_LIMIT:
            raise HTTPException(
                status_code=422, detail=f"at most {PUSH_LIMIT} events per request"
            )

        for body in events:
            try:
                validate_event(body)
            except EventValidationError as exc:
                raise HTTPException(status_code=422, detail=str(exc)) from exc

        server_now_ms = int(time.time() * 1000)
        received_at = _now()
        accepted = 0
        duplicates = 0
        max_seq = 0

        for body in events:
            skewed = is_skewed(body["hlc"]["pt"], server_now_ms)
            if skewed:
                logger.warning(
                    "event %s from device %s flagged skew_flag: hlc.pt=%d, "
                    "server_now_ms=%d",
                    body["event_id"],
                    body["device_id"],
                    body["hlc"]["pt"],
                    server_now_ms,
                )
            cur = conn.execute(
                "INSERT OR IGNORE INTO events "
                "(event_id, book_id, device_id, body, received_at, skew_flag) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (
                    body["event_id"],
                    body["book_id"],
                    body["device_id"],
                    json.dumps(body),
                    received_at,
                    int(skewed),
                ),
            )
            if cur.rowcount:
                accepted += 1
                max_seq = max(max_seq, cur.lastrowid)
            else:
                duplicates += 1
                row = conn.execute(
                    "SELECT seq FROM events WHERE event_id = ?", (body["event_id"],)
                ).fetchone()
                max_seq = max(max_seq, row["seq"])

        # Invariant 3 / section 6: committed before being reported as accepted.
        conn.commit()
        return {"accepted": accepted, "duplicates": duplicates, "max_seq": max_seq}

    @api.get("/api/v1/events")
    def get_events(
        since: int = 0,
        limit: int = PUSH_LIMIT,
        conn: sqlite3.Connection = Depends(get_conn),
    ) -> dict:
        """Section 6: pull events after `since` (a seq cursor), paged."""
        if limit <= 0 or limit > PUSH_LIMIT:
            raise HTTPException(
                status_code=422, detail=f"limit must be between 1 and {PUSH_LIMIT}"
            )

        rows = conn.execute(
            "SELECT seq, body, skew_flag FROM events WHERE seq > ? ORDER BY seq LIMIT ?",
            (since, limit + 1),
        ).fetchall()
        has_more = len(rows) > limit
        rows = rows[:limit]

        out_events = []
        for row in rows:
            body = json.loads(row["body"])
            body["seq"] = row["seq"]
            body["skew_flag"] = bool(row["skew_flag"])
            out_events.append(body)

        return {"events": out_events, "has_more": has_more}

    @api.post("/api/v1/rescan")
    def rescan(conn: sqlite3.Connection = Depends(get_conn)) -> dict:
        summary = scan_library(
            conn,
            library=settings.library,
            noise_db=settings.silence_db,
            silence_s=settings.silence_s,
        )
        return {
            "books_scanned": summary.books_scanned,
            "books_new": summary.books_new,
            "books_renamed": summary.books_renamed,
            "books_missing": summary.books_missing,
        }

    app.include_router(public)
    app.include_router(api)
    return app
