#!/usr/bin/env bash
# Online backup: prefers sqlite3 .backup; falls back to stop/copy/start.
# Usage: sudo ./backup.sh /var/backups/yuanlian-$(date +%F).db
set -euo pipefail

DB=${YUANLIAN_DB:-/var/lib/yuanlian/yuanlian.db}
OUT=${1:-/var/backups/yuanlian-$(date +%Y%m%d-%H%M%S).db}
mkdir -p "$(dirname "$OUT")"
chmod 0700 "$(dirname "$OUT")"

if command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 "$DB" ".backup '$OUT'"
  chmod 0600 "$OUT"
  echo "online backup written to $OUT"
  exit 0
fi

echo "sqlite3 not installed; stopping service for a consistent copy"
systemctl stop yuanlian-server.service
trap 'systemctl start yuanlian-server.service' EXIT
cp "$DB" "$OUT"
[[ -f "$DB-wal" ]] && cp "$DB-wal" "$OUT-wal"
[[ -f "$DB-shm" ]] && cp "$DB-shm" "$OUT-shm"
chmod 0600 "$OUT"
echo "offline backup written to $OUT; service restarted"
