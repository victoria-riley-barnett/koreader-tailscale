#!/bin/sh
# Quietly stop Tailscale for KOReader (invoked by Lua UI)

# Best-effort: be silent and fast; Lua handles user messaging
cd /mnt/us/tailscale/bin 2>/dev/null || exit 0

# Disconnect and stop daemon
./tailscale down >/dev/null 2>&1 || true
./tailscaled -cleanup >/dev/null 2>&1 || true
killall tailscaled 2>/dev/null || true

exit 0