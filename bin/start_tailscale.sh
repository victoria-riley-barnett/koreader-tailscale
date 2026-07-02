#!/bin/sh
# Thin executor: all decisions (TUN mode, state dir, auth key, headscale, flags)
# are made in Lua and passed via environment variables.
# This script just stops old instances and launches tailscaled + tailscale up.

BIN_DIR="${TS_BIN:-$(cd "$(dirname "$0")" && pwd)}"
STATEDIR="${TS_STATEDIR:-$BIN_DIR}"

cd "$BIN_DIR" || exit 1

# Ensure binaries exist
[ -f ./tailscaled ] || exit 1
[ -f ./tailscale ] || exit 1

# Stop any running instances
./tailscale down >/dev/null 2>&1 || true
killall tailscaled 2>/dev/null || true
sleep 2

# Start daemon — all flags pre-built by Lua
./tailscaled \
    --statedir="$STATEDIR/" \
    ${TS_TUN_FLAG} \
    --socks5-server=127.0.0.1:1055 \
    --outbound-http-proxy-listen=127.0.0.1:1056 \
    > tailscaled.log 2>&1 &

sleep 3

# Run tailscale up — flags pre-built by Lua
CMD="./tailscale up $TS_UP_FLAGS"
[ -n "$TS_AUTH_KEY" ] && CMD="$CMD --auth-key=\"$TS_AUTH_KEY\""
[ -n "$TS_LOGIN_SERVER" ] && CMD="$CMD --login-server=\"$TS_LOGIN_SERVER\""

sh -c "$CMD" < /dev/null > tailscale.log 2>&1
RC=$?

# Retry if pref-change confirmation needed
if [ $RC -ne 0 ]; then
    if grep -qE "requires mentioning all non-default flags|would change prefs" tailscale.log 2>/dev/null; then
        SUG_HOST=$(sed -n "s/.*--hostname=\([^[:space:]]*\).*/\1/p" tailscale.log | head -n1)
        if [ -n "$SUG_HOST" ]; then
            CMD="./tailscale up --hostname='$SUG_HOST' --accept-routes --accept-dns=false --netfilter-mode=off"
            [ -n "$TS_AUTH_KEY" ] && CMD="$CMD --auth-key=\"$TS_AUTH_KEY\""
            [ -n "$TS_LOGIN_SERVER" ] && CMD="$CMD --login-server=\"$TS_LOGIN_SERVER\""
            sh -c "$CMD" < /dev/null > tailscale.log 2>&1
            RC=$?
        fi
    fi
fi

exit $RC
