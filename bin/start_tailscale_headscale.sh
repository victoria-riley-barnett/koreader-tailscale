#!/bin/sh
TS_DIR="${1:-${TS_DIR:-/mnt/us/tailscale}}"
BIN_DIR="$TS_DIR/bin"
cd "$BIN_DIR" || exit 1

# POSIX-friendly headscale-aware start script

HEADSCALE_FILE="$BIN_DIR/headscale.url"
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

# State directory: use /tmp/tailscale (tmpfs, supports chmod) as runtime state.
STATE_DIR="/tmp/tailscale"
mkdir -p "$STATE_DIR" 2>/dev/null || true

_test_file="$BIN_DIR/.chmod_test_$$"
if touch "$_test_file" 2>/dev/null && chmod 0600 "$_test_file" 2>/dev/null; then
    STATE_DIR="$BIN_DIR"
    rm -f "$_test_file"
else
    rm -f "$_test_file" 2>/dev/null
    for f in tailscaled.state tailscaled.log.conf; do
        [ -f "$BIN_DIR/$f" ] && cp -f "$BIN_DIR/$f" "$STATE_DIR/$f" 2>/dev/null || true
    done
fi

export HOME="$TS_DIR"
export XDG_CACHE_HOME="$STATE_DIR"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# Ensure loopback has 127.0.0.1 (needed on PocketBook)
if [ -x /ebrmain/cramfs/bin/sudo ]; then
    /ebrmain/cramfs/bin/sudo /sbin/ifconfig lo 127.0.0.1 netmask 255.0.0.0 up 2>/dev/null || true
fi

# Try to set up TUN device if missing
TUN_FLAG=""
if [ ! -c /dev/net/tun ]; then
    modprobe tun 2>/dev/null || true
    mkdir -p /dev/net 2>/dev/null || true
    mknod /dev/net/tun c 10 200 2>/dev/null || true
    chmod 0666 /dev/net/tun 2>/dev/null || true
fi
if [ ! -c /dev/net/tun ]; then
    TUN_FLAG="--tun=userspace-networking"
fi

# Start daemon
nohup ./tailscaled --statedir="$STATE_DIR/" $TUN_FLAG --socks5-server=127.0.0.1:1055 --outbound-http-proxy-listen=127.0.0.1:1056 > tailscaled.log 2>&1 &
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
# --accept-dns=false: prevent tailscale from attempting to modify /etc/resolv.conf (read-only on PocketBook)
CMD="./tailscale up --login-server=\"$HS_URL\" $HOST_FLAG --accept-routes --accept-dns=false"
[ -n "$AUTH_KEY" ] && CMD="$CMD --auth-key=\"$AUTH_KEY\""

sh -c "$CMD" < /dev/null > tailscale.log 2>&1
RC=$?

# If failed because pref-change confirmation is needed, retry with the suggested hostname.
if [ $RC -ne 0 ]; then
    if grep -qE "requires mentioning all non-default flags|would change prefs" tailscale.log 2>/dev/null; then
        SUG_HOST=$(sed -n "s/.*--hostname=\([^[:space:]]*\).*/\1/p" tailscale.log | head -n1)
        if [ -n "$SUG_HOST" ]; then
            HOST_FLAG="--hostname=$SUG_HOST"
        fi
        CMD="./tailscale up --login-server=\"$HS_URL\" $HOST_FLAG --accept-routes --accept-dns=false"
        [ -n "$AUTH_KEY" ] && CMD="$CMD --auth-key=\"$AUTH_KEY\""
        sh -c "$CMD" < /dev/null > tailscale.log 2>&1
        RC=$?
    fi
fi

exit $RC
