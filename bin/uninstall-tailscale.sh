#!/bin/sh
# Thin executor: remove tailscale binaries and state.

BIN_DIR="${TS_BIN:-$(cd "$(dirname "$0")" && pwd)}"

# Stop if running
if [ -d "$BIN_DIR" ]; then
    (cd "$BIN_DIR" && \
        ./tailscale down >/dev/null 2>&1 || true; \
        ./tailscaled -cleanup >/dev/null 2>&1 || true; \
        killall tailscaled 2>/dev/null || true)
fi

# Remove tailscale files
if [ -d "$BIN_DIR" ]; then
    cd "$BIN_DIR"
    rm -f tailscale tailscaled auth.key headscale.url tailscale.log tailscaled.log *.state 2>/dev/null || true
    rm -f tailscale-* 2>/dev/null || true
fi

# Clean up tmp state
rm -f /tmp/tailscale*.log /tmp/tailscale*.state 2>/dev/null || true

exit 0
