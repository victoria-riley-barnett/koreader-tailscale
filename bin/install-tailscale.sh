#!/bin/sh
set -e

TS_FALLBACK_VER="1.96.2"
TS_DIR="${1:-${TS_DIR:-/mnt/us/tailscale}}"
TS_ARCH="${2:-}"
BIN_DIR="$TS_DIR/bin"

mkdir -p "$BIN_DIR"
cd "$BIN_DIR" || exit 1

<<<<<<< Updated upstream
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
=======
# TS_DIR can be set by the caller (e.g., plugin) to install binaries elsewhere
# If not set, default to BIN_DIR (plugin's bin directory)
TS_DIR="${TS_DIR:-$BIN_DIR}"
# Ensure TS_DIR exists
mkdir -p "$TS_DIR"
cd "$TS_DIR" || exit 1

# If TS_DIR is not BIN_DIR, we install binaries into TS_DIR/bin for consistency
if [ "$TS_DIR" != "$BIN_DIR" ]; then
    mkdir -p "$TS_DIR/bin"
    cd "$TS_DIR/bin" || exit 1
fi
>>>>>>> Stashed changes

if [ -x ./tailscale ] && [ -x ./tailscaled ]; then
  CUR_VER=$(./tailscale version 2>/dev/null | awk 'NR==1{if (match($0,/([0-9]+\.[0-9]+\.[0-9]+)/)) print substr($0,RSTART,RLENGTH)}')
  [ "$CUR_VER" = "$TS_VER" ] && exit 0 || true
fi

<<<<<<< Updated upstream
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
=======
# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    aarch64|arm64)
        ARCH_SUFFIX="arm64"
        ;;
    armv7l|armv7|armhf)
        ARCH_SUFFIX="arm"
        ;;
    armv6l|arm)
        ARCH_SUFFIX="armhf"
        ;;
    *)
        # Default to 32-bit ARM (most common for e-readers)
        ARCH_SUFFIX="arm"
        ;;
esac

ARCHIVE="tailscale_${ARCH_SUFFIX}.tgz"
rm -f "$ARCHIVE" 2>/dev/null || true

wget -q -O "$ARCHIVE" "https://pkgs.tailscale.com/stable/tailscale_${TS_VER}_${ARCH_SUFFIX}.tgz" 2>/dev/null || \
wget -q -O "$ARCHIVE" "https://pkgs.tailscale.com/stable/tailscale_${TS_VER}_${ARCH_SUFFIX}.tgz" 2>/dev/null || \
curl -s -o "$ARCHIVE" "https://pkgs.tailscale.com/stable/tailscale_${TS_VER}_${ARCH_SUFFIX}.tgz" 2>/dev/null || \
busybox wget -q -O "$ARCHIVE" "http://pkgs.tailscale.com/stable/tailscale_${TS_VER}_${ARCH_SUFFIX}.tgz" 2>/dev/null || true
>>>>>>> Stashed changes

[ -s "$ARCHIVE" ] || exit 1

tar xzf "$ARCHIVE"
rm -f "$ARCHIVE"
mv -f tailscale_*/tailscale tailscale_*/tailscaled ./ 2>/dev/null || true
rm -rf tailscale_* 2>/dev/null || true
chmod +x ./tailscale ./tailscaled 2>/dev/null || true
[ -f auth.key ] || : > auth.key
exit 0
