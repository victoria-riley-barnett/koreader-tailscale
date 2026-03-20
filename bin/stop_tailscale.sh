#!/bin/sh
# Determine bin directory (where this script is located)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# TS_DIR can be set by the caller (e.g., plugin) to point to tailscale installation directory
# If TS_DIR is set, use TS_DIR/bin as BIN_DIR (where binaries are installed)
# Otherwise, default to script directory
if [ -n "$TS_DIR" ]; then
    BIN_DIR="$TS_DIR/bin"
else
    BIN_DIR="$SCRIPT_DIR"
fi
mkdir -p "$BIN_DIR"
cd "$BIN_DIR" 2>/dev/null || exit 0

# Disconnect and stop daemon
./tailscale down >/dev/null 2>&1 || true
./tailscaled -cleanup >/dev/null 2>&1 || true
killall tailscaled 2>/dev/null || true

exit 0