#!/usr/bin/env bash
# Restores a backup produced by backup.sh. Stops the service, replaces the DB,
# and starts it again. Keeps a timestamped copy of the current database.
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

BACKUP=${1:?usage: restore.sh /path/to/backup.db}
DB=${YUANLIAN_DB:-/var/lib/yuanlian/yuanlian.db}
[[ -f "$BACKUP" ]] || { echo "backup not found: $BACKUP" >&2; exit 1; }

systemctl stop yuanlian-server.service
if [[ -f "$DB" ]]; then
  cp "$DB" "$DB.before-restore-$(date +%Y%m%d-%H%M%S)"
fi
install -m 0600 -o yuanlian -g yuanlian "$BACKUP" "$DB"
rm -f "$DB-wal" "$DB-shm"
systemctl start yuanlian-server.service
sleep 1
curl --fail --silent http://127.0.0.1:18080/health >/dev/null
echo "restored and health check passed"
