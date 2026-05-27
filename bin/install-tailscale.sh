#!/bin/sh
set -e

TS_FALLBACK_VER="1.98.3"
TS_DIR="${1:-${TS_DIR:-/mnt/us/tailscale}}"
TS_ARCH="${2:-}"
BIN_DIR="$TS_DIR/bin"

mkdir -p "$BIN_DIR"
cd "$BIN_DIR" || exit 1

fetch_stdout() {
    _url="$1"
    for _wget in /usr/bin/wget /bin/wget wget; do
        if [ -x "$_wget" ] || command -v "$_wget" >/dev/null 2>&1; then
            "$_wget" -q -O - "$_url" 2>/dev/null && return 0
        fi
    done
    for _curl in /usr/bin/curl /bin/curl curl; do
        if [ -x "$_curl" ] || command -v "$_curl" >/dev/null 2>&1; then
            "$_curl" -sf "$_url" 2>/dev/null && return 0
        fi
    done
    return 1
}

fetch_file() {
    _url="$1"
    _out="$2"
    for _wget in /usr/bin/wget /bin/wget wget; do
        if [ -x "$_wget" ] || command -v "$_wget" >/dev/null 2>&1; then
            "$_wget" -q -O "$_out" "$_url" 2>/dev/null && [ -s "$_out" ] && return 0
            rm -f "$_out" 2>/dev/null || true
        fi
    done
    for _curl in /usr/bin/curl /bin/curl curl; do
        if [ -x "$_curl" ] || command -v "$_curl" >/dev/null 2>&1; then
            "$_curl" -sf -o "$_out" "$_url" 2>/dev/null && [ -s "$_out" ] && return 0
            rm -f "$_out" 2>/dev/null || true
        fi
    done
    return 1
}

# Fetch latest stable version from Tailscale's JSON API.
# set -e is suspended here: grep exits 1 on no-match and would abort the script.
set +e
TS_VER=""
_json=$(fetch_stdout "https://pkgs.tailscale.com/stable/?mode=json")
if [ -n "$_json" ]; then
    if command -v grep >/dev/null 2>&1; then
        TS_VER=$(printf '%s\n' "$_json" | grep -o '"[Vv]ersion"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -1 | grep -o '[0-9][0-9.]*' 2>/dev/null | head -1)
    fi
    if [ -z "$TS_VER" ] && command -v sed >/dev/null 2>&1; then
        TS_VER=$(printf '%s\n' "$_json" | sed -n 's/.*"[Vv]ersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    fi
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
fetch_file "https://pkgs.tailscale.com/stable/tailscale_${TS_VER}_${TS_ARCH}.tgz" "$ARCHIVE" || \
    busybox wget -q -O "$ARCHIVE" "http://pkgs.tailscale.com/stable/tailscale_${TS_VER}_${TS_ARCH}.tgz" 2>/dev/null || true

[ -s "$ARCHIVE" ] || exit 1

tar xzf "$ARCHIVE"
rm -f "$ARCHIVE"
mv -f tailscale_*/tailscale tailscale_*/tailscaled ./ 2>/dev/null || true
rm -rf tailscale_* 2>/dev/null || true
chmod +x ./tailscale ./tailscaled 2>/dev/null || true
[ -f auth.key ] || : > auth.key
exit 0
