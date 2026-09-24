#!/bin/sh
# Daily SQLite backup per docs/ARCHITEKTUR.md section 12.
#
# Uses sqlite3's online ".backup" (safe on a live WAL-mode database, unlike
# copying the file directly) to write a dated snapshot. Events are
# append-only and never deleted (invariant 2), so each snapshot is a valid,
# self-contained point-in-time copy; devices also keep every event they
# have already synced, as a second line of defense.
#
# Usage: backup.sh [db_path] [backup_dir]
#   db_path     defaults to $FADEN_DATA/faden.db (or /data/faden.db)
#   backup_dir  defaults to $FADEN_DATA/backup (or /data/backup)
#
# Run daily, e.g. via cron or a systemd timer on the host, or inside the
# container: `docker compose exec faden /app/scripts/backup.sh`.

set -eu

DB_PATH="${1:-${FADEN_DATA:-/data}/faden.db}"
BACKUP_DIR="${2:-${FADEN_DATA:-/data}/backup}"

if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "backup.sh: sqlite3 not found on PATH" >&2
    exit 1
fi

if [ ! -f "$DB_PATH" ]; then
    echo "backup.sh: database not found at $DB_PATH" >&2
    exit 1
fi

mkdir -p "$BACKUP_DIR"

DATUM="$(date +%Y-%m-%d)"
BACKUP_PATH="$BACKUP_DIR/faden-$DATUM.db"

sqlite3 "$DB_PATH" ".backup '$BACKUP_PATH'"

echo "backup.sh: wrote $BACKUP_PATH"
