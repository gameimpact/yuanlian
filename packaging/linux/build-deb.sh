#!/usr/bin/env bash
# Builds the Linux client .deb and portable tar.gz from a Flutter Linux bundle.
# Run on Linux (WSL is fine) with dpkg-deb installed:
#   ./build-deb.sh <bundle-dir> <icon-png> <output-dir>
set -euo pipefail

BUNDLE=${1:?usage: build-deb.sh <bundle-dir> <icon-png> <output-dir>}
ICON=${2:?usage: build-deb.sh <bundle-dir> <icon-png> <output-dir>}
OUTDIR=${3:?usage: build-deb.sh <bundle-dir> <icon-png> <output-dir>}
VERSION=0.2.0
PKG=$(mktemp -d /tmp/yuanlian-deb.XXXXXX)
PORTABLE=$(mktemp -d /tmp/yuanlian-portable.XXXXXX)
trap 'rm -rf "$PKG" "$PORTABLE"' EXIT
mkdir -p "$OUTDIR"

mkdir -p "$PKG/DEBIAN" "$PKG/usr/lib/yuanlian" "$PKG/usr/bin" \
  "$PKG/usr/share/applications" "$PKG/usr/share/icons/hicolor/48x48/apps"
cp -r "$BUNDLE/." "$PKG/usr/lib/yuanlian/"
install -m 0644 "$ICON" "$PKG/usr/share/icons/hicolor/48x48/apps/yuanlian.png"
cat > "$PKG/usr/bin/yuanlian" <<'LAUNCHER'
#!/bin/sh
exec /usr/lib/yuanlian/yuanlian_client "$@"
LAUNCHER
chmod 0755 "$PKG/usr/bin/yuanlian"
cat > "$PKG/usr/share/applications/yuanlian.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=YuanLian
Name[zh_CN]=远联
Comment=Remote desktop client
Exec=yuanlian
Icon=yuanlian
Terminal=false
Categories=Network;RemoteAccess;
StartupWMClass=yuanlian_client
DESKTOP
SIZE=$(du -sk "$PKG/usr" | cut -f1)
cat > "$PKG/DEBIAN/control" <<EOF
Package: yuanlian-client
Version: $VERSION
Section: net
Priority: optional
Architecture: amd64
Maintainer: YuanLian <noreply@localhost>
Installed-Size: $SIZE
Depends: libc6 (>= 2.31), libgtk-3-0, libblkid1, liblzma5, libstdc++6, libglib2.0-0, libgcc-s1, libx11-6, libxkbcommon0, libwayland-client0, libegl1, libgles2, libfontconfig1, libpango-1.0-0, libcairo2, libatk1.0-0, libgdk-pixbuf-2.0-0
Description: YuanLian remote desktop client
 Flutter desktop client for the YuanLian remote control service.
EOF
dpkg-deb --build --root-owner-group "$PKG" "$OUTDIR/yuanlian-client_${VERSION}_amd64.deb"

# Portable bundle: run from any directory, no dpkg required.
mkdir -p "$PORTABLE/YuanLian-$VERSION-linux-x86_64"
cp -r "$BUNDLE/." "$PORTABLE/YuanLian-$VERSION-linux-x86_64/"
cat > "$PORTABLE/YuanLian-$VERSION-linux-x86_64/yuanlian" <<'LAUNCHER'
#!/bin/sh
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$DIR/yuanlian_client" "$@"
LAUNCHER
chmod 0755 "$PORTABLE/YuanLian-$VERSION-linux-x86_64/yuanlian"
tar -C "$PORTABLE" -czf "$OUTDIR/YuanLian-$VERSION-linux-x86_64-portable.tar.gz" \
  "YuanLian-$VERSION-linux-x86_64"

ls -lh "$OUTDIR"/yuanlian-client_*.deb "$OUTDIR"/YuanLian-*-portable.tar.gz
