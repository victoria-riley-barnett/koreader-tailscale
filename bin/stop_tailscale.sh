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

# killall sends SIGTERM asynchronously; wait for tailscaled to actually exit so it no longer
# holds the filesystem busy (e.g. before KOReader enters USB storage mode). SIGKILL fallback.
i=0
while pgrep tailscaled >/dev/null 2>&1; do
    i=$((i+1))
    [ "$i" -ge 10 ] && killall -9 tailscaled 2>/dev/null
    [ "$i" -ge 20 ] && break
    sleep 0.2
done

exit 0