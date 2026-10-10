#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
ENV_FILE="supabase/.env.local"
[[ -f "$ENV_FILE" ]] || { echo "Missing $ENV_FILE; copy .env.example and configure private values." >&2; exit 2; }
set +x
set -a
# shellcheck disable=SC1091
source "$ENV_FILE"
set +a
: "${SUPABASE_DB_URL:?SUPABASE_DB_URL is required}"
PG_DUMP_BIN="${PG_DUMP_BIN:-/usr/lib/postgresql/17/bin/pg_dump}"
PG_RESTORE_BIN="${PG_RESTORE_BIN:-/usr/lib/postgresql/17/bin/pg_restore}"
[[ -x "$PG_DUMP_BIN" ]] || PG_DUMP_BIN="$(command -v pg_dump || true)"
[[ -x "$PG_RESTORE_BIN" ]] || PG_RESTORE_BIN="$(command -v pg_restore || true)"
[[ -x "$PG_DUMP_BIN" && -x "$PG_RESTORE_BIN" ]] || { echo "pg_dump and pg_restore are required." >&2; exit 2; }
MAJOR="$($PG_DUMP_BIN --version | sed -E 's/.* ([0-9]+)\..*/\1/')"
(( MAJOR >= 17 )) || { echo "Use PostgreSQL 17+ client for the configured Supabase server." >&2; exit 2; }
OUT_DIR="${BACKUP_DIR:-$ROOT/.local-backups}"
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$OUT_DIR/everest-supabase-$STAMP.dump"
# Full logical backup; intentionally never included in git or frontend artifacts.
"$PG_DUMP_BIN" --format=custom --no-owner --no-acl --file="$OUT" --dbname="$SUPABASE_DB_URL"
chmod 600 "$OUT"
"$PG_RESTORE_BIN" --list "$OUT" >/dev/null
# Keep a bounded set of local copies; remote/provider retention must be checked separately.
find "$OUT_DIR" -maxdepth 1 -type f -name 'everest-supabase-*.dump' -mtime +7 -delete
printf 'Backup archive created and catalog-validated: %s (%s bytes)\n' "$OUT" "$(stat -c '%s' "$OUT")"
