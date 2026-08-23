#!/bin/sh
# Thin executor: stop tailscaled and clean up.

BIN_DIR="${TS_BIN:-$(cd "$(dirname "$0")" && pwd)}"
cd "$BIN_DIR" 2>/dev/null || exit 0

./tailscale down >/dev/null 2>&1 || true
./tailscaled -cleanup >/dev/null 2>&1 || true
killall tailscaled 2>/dev/null || true

# Sync tmpfs state back to persistent storage so node identity survives
# reboots on FAT32 devices (state lives in /tmp/tailscale, see resolveStateDir).
for f in tailscaled.state tailscaled.log.conf; do
    if [ -f "/tmp/tailscale/$f" ]; then
        cp -f "/tmp/tailscale/$f" "$BIN_DIR/$f" 2>/dev/null || true
    fi
done

exit 0
