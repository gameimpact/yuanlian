#!/usr/bin/env bash
# Installs the YuanLian control server as a dedicated system user.
# Run as root from the extracted package directory.
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "run as root (sudo) from the extracted package" >&2
  exit 1
fi

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
PREFIX=/opt/yuanlian
STATE=/var/lib/yuanlian
CONF=/etc/yuanlian

if ! id yuanlian >/dev/null 2>&1; then
  useradd --system --home "$STATE" --shell /usr/sbin/nologin yuanlian
fi
install -d -m 0750 -o yuanlian -g yuanlian "$PREFIX" "$STATE"
install -d -m 0750 -o root -g yuanlian "$CONF"
install -m 0755 "$ROOT_DIR/bin/yl-server" "$PREFIX/yl-server"
install -m 0644 "$ROOT_DIR/systemd/yuanlian-server.service" /etc/systemd/system/yuanlian-server.service
if [[ ! -f "$CONF/server.env" ]]; then
  install -m 0640 -o root -g yuanlian "$ROOT_DIR/config/server.env.example" "$CONF/server.env"
fi
systemctl daemon-reload
systemctl enable --now yuanlian-server.service
echo "installed; health: curl http://127.0.0.1:18080/health"
echo "TLS reverse proxy is required before exposing this port."
