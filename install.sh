#!/usr/bin/env bash
# Bootstrap for the Linux control server; release binaries are built elsewhere.
set -euo pipefail

VERSION=0.3.0
CHECK_ONLY=false
case "${1:-}" in
  '') ;;
  --check) CHECK_ONLY=true ;;
  *) echo '用法：bash install.sh [--check]（--check 只下载并校验，不安装）' >&2; exit 1 ;;
esac

fail() { echo "错误：$*" >&2; exit 1; }
echo "远联 YuanLian $VERSION — Linux 控制服务端"
echo '提供账号、设备、授权与 Web 管理后台；不安装桌面客户端或被控 Host。'
[[ $(uname -s) == Linux ]] || fail '仅支持 Linux。'
[[ $(uname -m) == x86_64 ]] || fail '当前仅提供 Linux x86_64 服务端二进制。'
for command in curl tar sha256sum awk mktemp; do
  command -v "$command" >/dev/null || fail "缺少命令：$command，请先安装。"
done
if [[ $CHECK_ONLY == false ]]; then
  command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || fail '需要运行中的 systemd。'
  [[ ! -e /opt/yuanlian/yl-server ]] || fail '已存在服务端；请先备份并按服务端说明手动升级，避免覆盖现有部署。'
  if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null || fail '需要 root 或 sudo 权限。'
  fi
fi

TEMP_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEMP_DIR"' EXIT
PACKAGE="yl-server-$VERSION-linux-x86_64"
ASSET="$PACKAGE.tar.gz"
BASE_URL="https://github.com/gameimpact/yuanlian/releases/download/v$VERSION"
echo "正在下载服务端发布包 v$VERSION…"
curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
  --connect-timeout 20 --max-time 600 --retry 2 "$BASE_URL/$ASSET" -o "$TEMP_DIR/$ASSET"
curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
  --connect-timeout 20 --max-time 120 --retry 2 "$BASE_URL/SHA256SUMS.txt" -o "$TEMP_DIR/SHA256SUMS.txt"
EXPECTED=$(awk -v asset="$ASSET" '$2 == "server-linux-x86_64/" asset || $2 == asset { print $1 }' "$TEMP_DIR/SHA256SUMS.txt")
[[ $EXPECTED =~ ^[0-9a-fA-F]{64}$ ]] || fail '发布清单中缺少唯一、有效的服务端 SHA-256。'
printf '%s  %s\n' "$EXPECTED" "$TEMP_DIR/$ASSET" | sha256sum --check --status || fail '服务端包 SHA-256 校验失败。'
tar --no-same-owner -xzf "$TEMP_DIR/$ASSET" -C "$TEMP_DIR"
for required in bin/yl-server scripts/install.sh systemd/yuanlian-server.service config/server.env.example; do
  [[ -f "$TEMP_DIR/$PACKAGE/$required" ]] || fail "服务端包缺少 $required。"
done
bash -n "$TEMP_DIR/$PACKAGE/scripts/install.sh"
if [[ $CHECK_ONLY == true ]]; then
  echo '服务端发布包下载、SHA-256、目录结构与安装脚本语法校验通过；未安装。'
  exit 0
fi

if [[ $EUID -eq 0 ]]; then
  bash "$TEMP_DIR/$PACKAGE/scripts/install.sh"
else
  sudo bash "$TEMP_DIR/$PACKAGE/scripts/install.sh"
fi
for attempt in {1..20}; do
  if systemctl is-active --quiet yuanlian-server.service && \
      curl --fail --silent --show-error --max-time 2 http://127.0.0.1:18080/health >"$TEMP_DIR/health.json"; then
    echo 'Linux 控制服务端安装完成，systemd 运行与 /health 检查通过。'
    echo '管理后台：http://127.0.0.1:18080/admin（远程访问使用 SSH 隧道）。'
    echo '默认仅监听本机；公网访问前需要 TLS 反向代理。'
    exit 0
  fi
  sleep 1
done
fail '服务端健康检查未通过；请查看 systemctl status yuanlian-server.service 与 journalctl -u yuanlian-server.service。'
