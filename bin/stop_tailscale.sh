#!/bin/sh
TS_DIR="${1:-/mnt/us/tailscale}"
BIN_DIR="$TS_DIR/bin"
cd "$BIN_DIR" 2>/dev/null || exit 0

# Disconnect and stop daemon
./tailscale down >/dev/null 2>&1 || true
./tailscaled -cleanup >/dev/null 2>&1 || true
killall tailscaled 2>/dev/null || true

# Preserve state from tmpfs back to persistent storage (for PocketBook etc.)
if [ -d /tmp/tailscale ]; then
    for f in tailscaled.state tailscaled.log.conf; do
        [ -f "/tmp/tailscale/$f" ] && cp -f "/tmp/tailscale/$f" "$BIN_DIR/$f" 2>/dev/null || true
    done
fi

exit 0