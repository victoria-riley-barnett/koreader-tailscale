#!/bin/sh
# Thin executor: all decisions (TUN mode, state dir, auth key, headscale, flags)
# are made in Lua and passed via environment variables.
# This script stops old instances, launches tailscaled, then tailscale up.

BIN_DIR="${TS_BIN:-$(cd "$(dirname "$0")" && pwd)}"
STATEDIR="${TS_STATEDIR:-$BIN_DIR}"
NETWORK_MODE="${TS_NETWORK_MODE:-unknown}"

cd "$BIN_DIR" || exit 1

# Ensure binaries exist
[ -f ./tailscaled ] || exit 1
[ -f ./tailscale ] || exit 1

# Point TLS at a real CA bundle when one exists (Kindle: /mnt/us, Kobo: /mnt/onboard).
# Never export a path that does not exist.
# The relative probe is three levels up: bin -> tailscale.koplugin -> plugins -> KOReader
# root. Two levels lands in plugins/, where no bundle has ever lived.
for _ca in "$BIN_DIR/../../../data/ca-bundle.crt" \
           /mnt/us/koreader/data/ca-bundle.crt \
           /mnt/onboard/.adds/koreader/data/ca-bundle.crt; do
    if [ -f "$_ca" ] && [ -r "$_ca" ]; then
        SSL_CERT_FILE="$_ca"
        export SSL_CERT_FILE
        break
    fi
done

# TS_DAEMON_ONLY=1 is the launch path: bring the daemon up and stop there. The
# daemon keeps the node's up/down state in its own state file, so it resumes
# whatever the user last chose — connected stays connected, off stays off. Both
# of the calls below would override that, so neither runs in this mode:
#   * `tailscale down` writes WantRunning=false, turning a "connected" boot off;
#   * `tailscale up` writes WantRunning=true, turning a user's "off" back on.
if [ "${TS_DAEMON_ONLY:-0}" = "1" ]; then
    killall tailscaled 2>/dev/null || true
    sleep 2
else
    # Stop any running instances
    ./tailscale down >/dev/null 2>&1 || true
    killall tailscaled 2>/dev/null || true
    sleep 2
fi

# Start daemon and record the selected networking mode before its own logs.
printf 'Tailscale networking mode: %s\n' "$NETWORK_MODE" > tailscaled.log
./tailscaled \
    --statedir="$STATEDIR/" \
    ${TS_TUN_FLAG} \
    --socks5-server=127.0.0.1:1055 \
    --outbound-http-proxy-listen=127.0.0.1:1056 \
    >> tailscaled.log 2>&1 &

# Launch path ends here. The daemon carries the node's own up/down state, which
# is the thing that was worth resuming; everything below is the connect path and
# would call `tailscale up`, forcing WantRunning=true over the user's choice.
if [ "${TS_DAEMON_ONLY:-0}" = "1" ]; then
    exit 0
fi

sleep 3

# Detect existing hostname (requires running daemon)
HOSTNAME=""
if ./tailscale status --json >/dev/null 2>&1; then
    HOSTNAME=$(./tailscale status --json 2>/dev/null \
        | sed -n 's/.*"HostName":[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -n1)
fi
HOST_FLAG=""
[ -n "$HOSTNAME" ] && HOST_FLAG="--hostname='$HOSTNAME'"

quote_arg() {
    printf "%s" "$1" | sed "s/'/'\\\\''/g; 1s/^/'/; \$s/\$/'/"
}

# Build the `tailscale up` command: core flags come from Lua, extras appended
# here. `up` only writes the prefs you actually pass — an omitted flag keeps its
# stored value — so every flag this plugin owns has to be passed every time,
# including the ones that mean "off". That is why --exit-node is sent empty
# rather than skipped: skipping it would leave a previously chosen exit node in
# place and the menu toggle would look like it did nothing.
CMD="./tailscale up $TS_UP_FLAGS $HOST_FLAG"
[ -n "$TS_AUTH_KEY" ] && CMD="$CMD --auth-key=\"$TS_AUTH_KEY\""
[ -n "$TS_LOGIN_SERVER" ] && CMD="$CMD --login-server=\"$TS_LOGIN_SERVER\""
if [ "${USE_EXIT_NODE:-0}" = "1" ] && [ -n "${EXIT_NODE:-}" ]; then
    CMD="$CMD --exit-node=$(quote_arg "$EXIT_NODE") --exit-node-allow-lan-access"
else
    CMD="$CMD --exit-node= --exit-node-allow-lan-access=false"
fi

# Run in the background: without an auth key `tailscale up` blocks waiting for
# interactive login. The plugin polls `tailscale status --json` for login state.
sh -c "$CMD" < /dev/null > tailscale.log 2>&1 &

exit 0
