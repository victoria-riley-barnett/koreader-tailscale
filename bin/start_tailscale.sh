#!/bin/sh
# Start Tailscale for KOReader plugin
cd /mnt/us/tailscale/bin

# Check binaries exist
if [ ! -f "./tailscaled" ] || [ ! -f "./tailscale" ]; then exit 1; fi

# Stop any existing instances
./tailscale down >/dev/null 2>&1 || true
killall tailscaled 2>/dev/null || true
sleep 2

# Start daemon
nohup ./tailscaled --statedir=/mnt/us/tailscale/bin/ -tun userspace-networking > tailscaled.log 2>&1 &
sleep 3

# Connect with auth key if available
if [ -f auth.key ] && grep -q "^tskey-" auth.key; then
    AUTH_KEY=$(grep "^tskey-" auth.key | head -1 | tr -d ' ' | tr -d '#')
    ./tailscale up --auth-key="$AUTH_KEY" --hostname=kindle-pw6 --accept-routes > tailscale.log 2>&1
else
    ./tailscale up --hostname=kindle-pw6 --accept-routes > tailscale.log 2>&1
fi