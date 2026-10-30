#!/bin/sh
# Thin executor: download tailscale binaries for the given architecture and
# verify them before anything is installed.
#
# The transport alone proves nothing on most e-readers: busybox wget, the usual
# downloader there, falls back to its built-in TLS when no openssl binary is
# present, and that TLS does not validate certificates. So every archive is
# checked against a SHA-256 that came from a trusted source:
#   * latest release — fetched only by a downloader that validates TLS (curl or
#     GNU wget), and checked against the .sha256 Tailscale publishes beside it;
#   * pinned release — the fallback when no validating downloader works. Any
#     downloader may fetch it, because the hash it must match ships with this
#     plugin. Bump the three values below together.
# Anything that fails to verify is deleted and nothing is installed.

set -e

TS_PINNED_VER="1.104.4"
TS_PINNED_SHA256_arm="7412390619633d040dbb030c92626d10f3d056e2d9087fc1026556881bbe0de3"
TS_PINNED_SHA256_arm64="a1c249ce6bdebef62e1ae3b997595555bce2ae4709bf95a718e9ca7a129dad7e"

PKGS="https://pkgs.tailscale.com/stable"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${TS_BIN:-$SCRIPT_DIR}"
ARCH="${TS_ARCH:-arm}"

case "$ARCH" in
    arm) TS_PINNED_SHA256="$TS_PINNED_SHA256_arm" ;;
    arm64) TS_PINNED_SHA256="$TS_PINNED_SHA256_arm64" ;;
    *) echo "ERROR: unsupported architecture: $ARCH"; exit 1 ;;
esac

mkdir -p "$BIN_DIR"
cd "$BIN_DIR" || exit 1

ARCHIVE="$BIN_DIR/.tailscale_download.tgz"
STAGE="$BIN_DIR/.tailscale_stage"
cleanup() {
    rm -f "$ARCHIVE" 2>/dev/null || true
    rm -rf "$STAGE" 2>/dev/null || true
}
# Every failure must say ERROR: the plugin scans the output for it, and a silent
# `set -e` exit with old binaries still in place would read as success.
FAILED=0
fail() {
    echo "ERROR: $1"
    FAILED=1
    exit 1
}
trap 'rc=$?; cleanup; [ "$rc" -eq 0 ] || [ "$FAILED" = 1 ] || echo "ERROR: install failed"' EXIT

# Same CA bundle probe as start_tailscale.sh, anchored on this script's own
# directory (bin -> tailscale.koplugin -> plugins -> KOReader root) so it also
# works where TS_BIN lives elsewhere (PocketBook). An exported SSL_CERT_FILE wins.
CA_BUNDLE=""
for _ca in "${SSL_CERT_FILE:-}" \
           "$SCRIPT_DIR/../../../data/ca-bundle.crt" \
           /mnt/us/koreader/data/ca-bundle.crt \
           /mnt/onboard/.adds/koreader/data/ca-bundle.crt; do
    if [ -n "$_ca" ] && [ -f "$_ca" ] && [ -r "$_ca" ]; then
        CA_BUNDLE="$_ca"
        break
    fi
done

# Fetch $1 into $2 with a downloader that validates the server certificate.
# Fails rather than fall back to one that does not.
fetch_validated() {
    if command -v curl >/dev/null 2>&1; then
        if [ -n "$CA_BUNDLE" ]; then
            curl -fsSL --proto '=https' --proto-redir '=https' --cacert "$CA_BUNDLE" -o "$2" "$1" 2>/dev/null && return 0
        else
            curl -fsSL --proto '=https' --proto-redir '=https' -o "$2" "$1" 2>/dev/null && return 0
        fi
    fi
    # busybox wget also answers to `wget`, and only GNU Wget is known to verify.
    if wget --version 2>/dev/null | grep -q 'GNU Wget'; then
        if [ -n "$CA_BUNDLE" ]; then
            wget -q --https-only --ca-certificate="$CA_BUNDLE" -O "$2" "$1" 2>/dev/null && return 0
        else
            wget -q --https-only -O "$2" "$1" 2>/dev/null && return 0
        fi
    fi
    rm -f "$2" 2>/dev/null || true
    return 1
}

# Fetch $1 into $2 with whatever works. Only for downloads whose hash is pinned.
fetch_any() {
    fetch_validated "$1" "$2" && return 0
    wget -q -O "$2" "$1" 2>/dev/null && return 0
    rm -f "$2" 2>/dev/null || true
    return 1
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v busybox >/dev/null 2>&1 && busybox sha256sum "$1" >/dev/null 2>&1; then
        busybox sha256sum "$1" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    fi
}

# True when version $1 is strictly newer than version $2 (dotted numbers).
version_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        n = split(a, x, "."); m = split(b, y, ".")
        for (i = 1; i <= (n > m ? n : m); i++) {
            if (x[i] + 0 > y[i] + 0) exit 0
            if (x[i] + 0 < y[i] + 0) exit 1
        }
        exit 1
    }'
}

if [ -z "$(sha256_of "$SCRIPT_DIR/install-tailscale.sh")" ]; then
    fail "no sha256 tool (sha256sum, busybox, openssl) to verify the download"
fi

# Latest release, only over validated TLS. Any failure here drops to the pin.
TS_VER=""
TS_SHA256=""
_json="$BIN_DIR/.tailscale_versions.json"
if fetch_validated "$PKGS/?mode=json" "$_json"; then
    TS_VER=$(sed -n 's/.*"TarballsVersion"[[:space:]]*:[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' "$_json" | head -n 1)
fi
rm -f "$_json" 2>/dev/null || true
if [ -n "$TS_VER" ]; then
    _sum="$BIN_DIR/.tailscale_sum"
    if fetch_validated "$PKGS/tailscale_${TS_VER}_${ARCH}.tgz.sha256" "$_sum"; then
        TS_SHA256=$(awk 'NR==1{print $1}' "$_sum" | tr 'A-F' 'a-f')
    fi
    rm -f "$_sum" 2>/dev/null || true
    case "$TS_SHA256" in
        *[!0-9a-f]*|"") TS_SHA256="" ;;
    esac
    [ ${#TS_SHA256} -eq 64 ] || TS_SHA256=""
fi

PINNED=0
if [ -z "$TS_VER" ] || [ -z "$TS_SHA256" ]; then
    PINNED=1
    TS_VER="$TS_PINNED_VER"
    TS_SHA256="$TS_PINNED_SHA256"
fi

# Skip if already on this version; never let the pin downgrade a newer install.
if [ -x ./tailscale ] && [ -x ./tailscaled ]; then
    CUR_VER=$(./tailscale version 2>/dev/null | awk 'NR==1{if (match($0,/([0-9]+\.[0-9]+\.[0-9]+)/)) print substr($0,RSTART,RLENGTH)}')
    if [ "$CUR_VER" = "$TS_VER" ]; then
        exit 0
    fi
    if [ "$PINNED" = "1" ] && [ -n "$CUR_VER" ] && version_gt "$CUR_VER" "$TS_VER"; then
        exit 0
    fi
fi

URL="$PKGS/tailscale_${TS_VER}_${ARCH}.tgz"
rm -f "$ARCHIVE" 2>/dev/null || true
if [ "$PINNED" = "1" ]; then
    fetch_any "$URL" "$ARCHIVE" || fail "download failed"
else
    fetch_validated "$URL" "$ARCHIVE" || fail "download failed"
fi
[ -s "$ARCHIVE" ] || fail "download failed"

GOT_SHA256=$(sha256_of "$ARCHIVE")
if [ "$GOT_SHA256" != "$TS_SHA256" ]; then
    fail "checksum mismatch for tailscale ${TS_VER} (${ARCH}); nothing installed"
fi

# Extract into a private staging dir and take only the two binaries out of it.
rm -rf "$STAGE" 2>/dev/null || true
mkdir "$STAGE"
tar xzf "$ARCHIVE" -C "$STAGE"
SRC="$STAGE/tailscale_${TS_VER}_${ARCH}"
for f in tailscale tailscaled; do
    if [ -L "$SRC/$f" ] || [ ! -f "$SRC/$f" ]; then
        fail "$f missing from verified archive"
    fi
done
mv -f "$SRC/tailscale" "$SRC/tailscaled" ./
chmod +x ./tailscale ./tailscaled
if [ ! -x ./tailscale ] || [ ! -x ./tailscaled ]; then
    fail "tailscale/tailscaled not executable after extraction"
fi
exit 0
