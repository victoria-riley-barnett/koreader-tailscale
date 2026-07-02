#!/bin/sh
# Thin executor: download tailscale binaries for the given architecture.

set -e

TS_FALLBACK_VER="1.96.2"
BIN_DIR="${TS_BIN:-$(cd "$(dirname "$0")" && pwd)}"
ARCH="${TS_ARCH:-arm}"

mkdir -p "$BIN_DIR"
cd "$BIN_DIR" || exit 1

# Fetch latest stable version
set +e
TS_VER=""
_json=$(wget -qO- "https://pkgs.tailscale.com/stable/?mode=json" 2>/dev/null)
if [ -z "$_json" ]; then
    _json=$(curl -sf "https://pkgs.tailscale.com/stable/?mode=json" 2>/dev/null)
fi
if [ -n "$_json" ]; then
    TS_VER=$(printf '%s' "$_json" | grep -o '"version":"[^"]*"' | head -1 | grep -o '[0-9][0-9.]*')
fi
[ -z "$TS_VER" ] && TS_VER="$TS_FALLBACK_VER"
set -e

# Skip if already on this version
if [ -x ./tailscale ] && [ -x ./tailscaled ]; then
    CUR_VER=$(./tailscale version 2>/dev/null | awk 'NR==1{if (match($0,/([0-9]+\.[0-9]+\.[0-9]+)/)) print substr($0,RSTART,RLENGTH)}')
    [ "$CUR_VER" = "$TS_VER" ] && exit 0 || true
fi

ARCHIVE="tailscale_${ARCH}.tgz"
rm -f "$ARCHIVE" 2>/dev/null || true

wget -q -O "$ARCHIVE" "https://pkgs.tailscale.com/stable/tailscale_${TS_VER}_${ARCH}.tgz" 2>/dev/null || \
curl -s -o "$ARCHIVE" "https://pkgs.tailscale.com/stable/tailscale_${TS_VER}_${ARCH}.tgz" 2>/dev/null || \
busybox wget -q -O "$ARCHIVE" "http://pkgs.tailscale.com/stable/tailscale_${TS_VER}_${ARCH}.tgz" 2>/dev/null || true

[ -s "$ARCHIVE" ] || exit 1

tar xzf "$ARCHIVE"
rm -f "$ARCHIVE"
mv -f tailscale_*/tailscale tailscale_*/tailscaled ./ 2>/dev/null || true
rm -rf tailscale_* 2>/dev/null || true
chmod +x ./tailscale ./tailscaled 2>/dev/null || true
[ -f auth.key ] || : > auth.key
exit 0
