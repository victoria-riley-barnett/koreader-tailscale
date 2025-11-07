#!/usr/bin/env bash
set -euo pipefail

# make_release.sh
# Create a release zip that contains repository files
# nested under a single top-level folder named `tailscale.koplugin`.
# Output file: tailscale.koplugin-v<version>.zip in the repo root.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
META_FILE="$ROOT_DIR/_meta.lua"

# Try to read version from _meta.lua, fallback to timestamp
version="$(date +%Y%m%d%H%M%S)"
if [ -f "$META_FILE" ]; then
    ver=$(sed -n 's/.*version *= *"\([^"]*\)".*/\1/p' "$META_FILE" || true)
    if [ -n "$ver" ]; then
        version="$ver"
    fi
fi

TMPDIR=$(mktemp -d)
DEST="$TMPDIR/tailscale.koplugin"
mkdir -p "$DEST"

echo "Packing repository into top-level folder: tailscale.koplugin"

# Copy repository files into destination, excluding git metadata and any existing archives
# Preserve permissions and symlinks where possible.
rsync -a --exclude='.git' --exclude='*.tar.gz' --exclude='*.zip' --exclude='$TMPDIR' --exclude='scripts/' "$ROOT_DIR/" "$DEST/"

# Create a zip archive (preferred for easy cross-platform distribution)
# Produce a stable filename `tailscale.koplugin.zip` containing a top-level
# folder named `tailscale.koplugin` as requested.
OUTZIP="$ROOT_DIR/tailscale.koplugin.zip"
echo "Creating zip: $OUTZIP"

if command -v zip >/dev/null 2>&1; then
    (cd "$TMPDIR" && zip -r "$OUTZIP" "tailscale.koplugin") >/dev/null
else
    # Fallback to python if `zip` is not available
    if command -v python3 >/dev/null 2>&1; then
        python3 - <<PY > /dev/null
import os, sys, zipfile
root = sys.argv[1]
zip_path = sys.argv[2]
with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zf:
    for base, dirs, files in os.walk(root):
        for f in files:
            full = os.path.join(base, f)
            rel = os.path.relpath(full, os.path.dirname(root))
            zf.write(full, rel)
PY
        "$DEST" "$OUTZIP"
    else
        echo "Neither zip nor python3 found to create zip archive" >&2
        rm -rf "$TMPDIR"
        exit 2
    fi
fi

echo "Created release archive: $OUTZIP"

# cleanup
rm -rf "$TMPDIR"

exit 0
