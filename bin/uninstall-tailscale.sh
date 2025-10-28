#!/bin/sh
# Uninstall Tailscale for KOReader
set -e

TS_DIR="/mnt/us/tailscale"
BIN_DIR="$TS_DIR/bin"

# Stop Tailscale if running
if [ -d "$BIN_DIR" ]; then
  (cd "$BIN_DIR" && \
    ./tailscale down >/dev/null 2>&1 || true; \
    ./tailscaled -cleanup >/dev/null 2>&1 || true; \
    killall tailscaled 2>/dev/null || true)
fi

# Remove all Tailscale files
rm -rf "$TS_DIR" 2>/dev/null || true

# Clean up temp/state files
rm -f /tmp/tailscale*.log /tmp/tailscale*.state 2>/dev/null || true

exit 0