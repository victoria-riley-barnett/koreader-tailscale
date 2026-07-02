#!/bin/sh
# Thin executor: stop tailscaled and clean up.

BIN_DIR="${TS_BIN:-$(cd "$(dirname "$0")" && pwd)}"
cd "$BIN_DIR" 2>/dev/null || exit 0

./tailscale down >/dev/null 2>&1 || true
./tailscaled -cleanup >/dev/null 2>&1 || true
killall tailscaled 2>/dev/null || true

exit 0
