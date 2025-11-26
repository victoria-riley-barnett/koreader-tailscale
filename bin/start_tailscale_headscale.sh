#!/bin/sh
cd /mnt/us/tailscale/bin || exit 1

# POSIX-friendly headscale-aware start script

HEADSCALE_FILE="/mnt/us/tailscale/bin/headscale.url"
if [ ! -f "$HEADSCALE_FILE" ]; then
    echo "headscale.url not found at $HEADSCALE_FILE" >&2
    exit 2
fi
HS_URL=$(tr -d '\r\n' < "$HEADSCALE_FILE" 2>/dev/null)
[ -n "$HS_URL" ] || exit 2

# Ensure binaries exist
[ -f ./tailscaled ] || exit 1
[ -f ./tailscale ] || exit 1

# Stop any running instances
./tailscale down >/dev/null 2>&1 || true
killall tailscaled 2>/dev/null || true
sleep 2

# Start daemon
nohup ./tailscaled --statedir=/mnt/us/tailscale/bin/ > tailscaled.log 2>&1 &
sleep 3

# Get current hostname (if any)
HOSTNAME=""
if ./tailscale status --json >/dev/null 2>&1; then
    HOSTNAME=$(./tailscale status --json 2>/dev/null | sed -n 's/.*"HostName":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
fi
HOST_FLAG=""
[ -n "$HOSTNAME" ] && HOST_FLAG="--hostname=$HOSTNAME"

# Read auth key if present
AUTH_KEY=""
if [ -f auth.key ] && grep -q "^tskey-" auth.key; then
    AUTH_KEY=$(grep "^tskey-" auth.key | head -1 | tr -d ' ' | tr -d '#')
fi

# Build command with login-server
CMD="./tailscale up --login-server=\"$HS_URL\" $HOST_FLAG --accept-routes"
[ -n "$AUTH_KEY" ] && CMD="$CMD --auth-key=\"$AUTH_KEY\""

# Run and capture exit code
sh -c "$CMD" > tailscale.log 2>&1
RC=$?

# Retry on missing non-default flags by extracting suggested hostname
if [ $RC -ne 0 ]; then
    if grep -q "requires mentioning all non-default flags" tailscale.log 2>/dev/null; then
        SUG_HOST=$(sed -n "s/.*--hostname=\([^[:space:]]*\).*/\1/p" tailscale.log | head -n1)
        if [ -n "$SUG_HOST" ]; then
            HOST_FLAG="--hostname=$SUG_HOST"
            CMD="./tailscale up --login-server=\"$HS_URL\" $HOST_FLAG --accept-routes"
            [ -n "$AUTH_KEY" ] && CMD="$CMD --auth-key=\"$AUTH_KEY\""
            sh -c "$CMD" > tailscale.log 2>&1
            RC=$?
        fi
    fi
fi

exit $RC
