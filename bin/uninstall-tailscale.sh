#!/bin/sh
# Uninstall Tailscale for KOReader
set -e

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

# Stop Tailscale if running
if [ -d "$BIN_DIR" ]; then
  (cd "$BIN_DIR" && \
    ./tailscale down >/dev/null 2>&1 || true; \
    ./tailscaled -cleanup >/dev/null 2>&1 || true; \
    killall tailscaled 2>/dev/null || true)
fi

# Remove Tailscale files from bin directory
if [ -d "$BIN_DIR" ]; then
    cd "$BIN_DIR"
    rm -f tailscale tailscaled auth.key headscale.url tailscale.log tailscaled.log *.state 2>/dev/null || true
    # Remove any other tailscale-related files but keep plugin scripts
    rm -f tailscale-* 2>/dev/null || true
fi

# Clean up temp/state files
rm -f /tmp/tailscale*.log /tmp/tailscale*.state 2>/dev/null || true

exit 0