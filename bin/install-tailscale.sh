#!/bin/sh
set -e

TS_FALLBACK_VER="1.96.2"
TS_DIR="${1:-${TS_DIR:-/mnt/us/tailscale}}"
TS_ARCH="${2:-}"
BIN_DIR="$TS_DIR/bin"

mkdir -p "$BIN_DIR"
cd "$BIN_DIR" || exit 1

# Fetch latest stable version from Tailscale's JSON API.
# set -e is suspended here: grep exits 1 on no-match and would abort the script.
set +e
TS_VER=""
_json=$(wget -qO- "https://pkgs.tailscale.com/stable/?mode=json" 2>/dev/null)
if [ -z "$_json" ]; then
    _json=$(curl -sf "https://pkgs.tailscale.com/stable/?mode=json" 2>/dev/null)
fi
if [ -n "$_json" ]; then
    TS_VER=$(printf '%s' "$_json" | grep -o '"version":"[^"]*"' | head -1 | grep -o '[0-9][0-9.]*')
fi
# Fall back to hardcoded version if fetch failed or returned nothing
if [ -z "$TS_VER" ]; then
    TS_VER="$TS_FALLBACK_VER"
fi
set -e

if [ -x ./tailscale ] && [ -x ./tailscaled ]; then
  CUR_VER=$(./tailscale version 2>/dev/null | awk 'NR==1{if (match($0,/([0-9]+\.[0-9]+\.[0-9]+)/)) print substr($0,RSTART,RLENGTH)}')
  [ "$CUR_VER" = "$TS_VER" ] && exit 0 || true
fi

# Detect architecture if not passed as argument
if [ -z "$TS_ARCH" ]; then
    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64|arm64)
            TS_ARCH="arm64"
            ;;
        armv7l|armv7|armhf)
            TS_ARCH="arm"
            ;;
        armv6l|arm)
            TS_ARCH="armhf"
            ;;
        *)
            TS_ARCH="arm"
            ;;
    esac
fi

ARCHIVE="tailscale_${TS_ARCH}.tgz"
rm -f "$ARCHIVE" 2>/dev/null || true

# Try multiple download methods
wget -q -O "$ARCHIVE" "https://pkgs.tailscale.com/stable/tailscale_${TS_VER}_${TS_ARCH}.tgz" 2>/dev/null || \
curl -s -o "$ARCHIVE" "https://pkgs.tailscale.com/stable/tailscale_${TS_VER}_${TS_ARCH}.tgz" 2>/dev/null || \
busybox wget -q -O "$ARCHIVE" "http://pkgs.tailscale.com/stable/tailscale_${TS_VER}_${TS_ARCH}.tgz" 2>/dev/null || true

[ -s "$ARCHIVE" ] || exit 1

tar xzf "$ARCHIVE"
rm -f "$ARCHIVE"
mv -f tailscale_*/tailscale tailscale_*/tailscaled ./ 2>/dev/null || true
rm -rf tailscale_* 2>/dev/null || true
chmod +x ./tailscale ./tailscaled 2>/dev/null || true
[ -f auth.key ] || : > auth.key

if [ ! -f "$BIN_DIR/ca-certificates.crt" ]; then
    busybox wget -q -O "$BIN_DIR/ca-certificates.crt" "http://curl.se/ca/cacert.pem" 2>/dev/null || true
fi

exit 0
