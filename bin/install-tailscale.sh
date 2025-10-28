#!/bin/sh
set -e

TS_VER="1.90.2"
TS_DIR="/mnt/us/tailscale"
BIN_DIR="$TS_DIR/bin"

mkdir -p "$BIN_DIR"
cd "$BIN_DIR" || exit 1

if [ -x ./tailscale ] && [ -x ./tailscaled ]; then
  CUR_VER=$(./tailscale version 2>/dev/null | awk 'NR==1{if (match($0,/([0-9]+\.[0-9]+\.[0-9]+)/)) print substr($0,RSTART,RLENGTH)}')
  [ "$CUR_VER" = "$TS_VER" ] && exit 0 || true
fi

ARCHIVE="tailscale_arm.tgz"
rm -f "$ARCHIVE" 2>/dev/null || true

wget -q -O "$ARCHIVE" "https://pkgs.tailscale.com/stable/tailscale_${TS_VER}_arm.tgz" 2>/dev/null || \
wget -q -O "$ARCHIVE" "https://pkgs.tailscale.com/stable/tailscale_${TS_VER}_armhf.tgz" 2>/dev/null || \
curl -s -o "$ARCHIVE" "https://pkgs.tailscale.com/stable/tailscale_${TS_VER}_arm.tgz" 2>/dev/null || \
busybox wget -q -O "$ARCHIVE" "http://pkgs.tailscale.com/stable/tailscale_${TS_VER}_arm.tgz" 2>/dev/null || true

[ -s "$ARCHIVE" ] || exit 1

tar xzf "$ARCHIVE"
rm -f "$ARCHIVE"
mv -f tailscale_*/tailscale tailscale_*/tailscaled ./ 2>/dev/null || true
rm -rf tailscale_* 2>/dev/null || true
chmod +x ./tailscale ./tailscaled 2>/dev/null || true
[ -f auth.key ] || : > auth.key
exit 0

