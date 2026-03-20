#!/bin/sh
TS_DIR="${1:-${TS_DIR:-/mnt/us/tailscale}}"
BIN_DIR="$TS_DIR/bin"
cd "$BIN_DIR" || exit 1

# POSIX-friendly start script for Tailscale (standard)

# Ensure binaries exist
[ -f ./tailscaled ] || exit 1
[ -f ./tailscale ] || exit 1

# Stop any running instances
./tailscale down >/dev/null 2>&1 || true
killall tailscaled 2>/dev/null || true
sleep 2

# State directory: use /tmp/tailscale (tmpfs, supports chmod) as runtime state.
# Copy any previous state from persistent storage on startup.
STATE_DIR="/tmp/tailscale"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# Test if persistent storage supports chmod; if so, use it directly
_test_file="$BIN_DIR/.chmod_test_$$"
if touch "$_test_file" 2>/dev/null && chmod 0600 "$_test_file" 2>/dev/null; then
    STATE_DIR="$BIN_DIR"
    rm -f "$_test_file"
else
    rm -f "$_test_file" 2>/dev/null
    # Copy existing state to tmpfs so we don't lose node identity on restart
    for f in tailscaled.state tailscaled.log.conf; do
        [ -f "$BIN_DIR/$f" ] && cp -f "$BIN_DIR/$f" "$STATE_DIR/$f" 2>/dev/null || true
    done
fi

# Redirect cache/home to writable storage (needed on PocketBook and similar)
export HOME="$TS_DIR"
export XDG_CACHE_HOME="$STATE_DIR"
mkdir -p "$STATE_DIR" 2>/dev/null || true

# Ensure loopback has 127.0.0.1 — required for the HTTP proxy to bind and be reachable.
# PocketBook firmware does not configure lo at boot; use the device-specific NOPASSWD sudo.
# Skipped silently on other devices (Kindle, etc.) where lo is already configured.
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
# If TUN still doesn't exist, fall back to userspace networking
if [ ! -c /dev/net/tun ]; then
    TUN_FLAG="--tun=userspace-networking"
fi

# Start daemon with the appropriate state directory
# --socks5-server / --outbound-http-proxy-listen: proxies so KOReader can reach
#   Tailscale IPs without a TUN interface (userspace-networking mode).
nohup ./tailscaled --statedir="$STATE_DIR/" $TUN_FLAG --socks5-server=127.0.0.1:1055 --outbound-http-proxy-listen=127.0.0.1:1056 > tailscaled.log 2>&1 &

# Wait for daemon socket to become available
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

# Build command
# --accept-dns=false: prevent tailscale from attempting to modify /etc/resolv.conf (read-only on PocketBook).
# --netfilter-mode=off: avoid nftables/iptables reconfig stalls on constrained e-reader kernels.
CMD="./tailscale up $HOST_FLAG --accept-routes --accept-dns=false --netfilter-mode=off"
[ -n "$AUTH_KEY" ] && CMD="$CMD --auth-key=\"$AUTH_KEY\""

# Run with stdin from /dev/null to prevent tailscale up from hanging if it
# needs interactive confirmation (e.g. pref-change prompt in v1.44+)
sh -c "$CMD" < /dev/null > tailscale.log 2>&1
RC=$?

# If failed because pref-change confirmation is needed, retry with the suggested hostname.
if [ $RC -ne 0 ]; then
    if grep -qE "requires mentioning all non-default flags|would change prefs" tailscale.log 2>/dev/null; then
        SUG_HOST=$(sed -n "s/.*--hostname=\([^[:space:]]*\).*/\1/p" tailscale.log | head -n1)
        if [ -n "$SUG_HOST" ]; then
            HOST_FLAG="--hostname=$SUG_HOST"
        fi
        CMD="./tailscale up $HOST_FLAG --accept-routes --accept-dns=false --netfilter-mode=off"
        [ -n "$AUTH_KEY" ] && CMD="$CMD --auth-key=\"$AUTH_KEY\""
        sh -c "$CMD" < /dev/null > tailscale.log 2>&1
        RC=$?
    fi
fi

exit $RC
