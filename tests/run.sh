#!/bin/sh
# Smoke tests for the shell scripts, run against fake tailscale/tailscaled/
# iptables binaries. No device or network needed: sh tests/run.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAILS=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; FAILS=$((FAILS + 1)); }

new_sandbox() {
    T=$(mktemp -d)
    mkdir -p "$T/bin" "$T/state" "$T/fake"
    cp "$ROOT"/bin/*.sh "$T/bin/"
    printf '#!/bin/sh\nexit 0\n' > "$T/bin/tailscaled"
    # Records its argv one argument per line, so quoting bugs are visible.
    cat > "$T/bin/tailscale" <<EOF
#!/bin/sh
if [ "\$1" = up ]; then
    for a in "\$@"; do printf '%s\n' "\$a"; done > "$T/up.argv"
fi
[ "\$1" = status ] && echo '{"HostName":"dev\$(touch $T/pwned)"}'
exit 0
EOF
    # Fake iptables with a DROP default policy; rules live in a plain file.
    cat > "$T/fake/iptables" <<EOF
#!/bin/sh
op="\$1"; shift
case "\$op" in
    -S) echo "-P \$1 DROP" ;;
    -C) grep -qxF "\$*" "$T/rules" 2>/dev/null ;;
    -I) echo "\$*" >> "$T/rules" ;;
    -D) grep -qxF "\$*" "$T/rules" 2>/dev/null || exit 1
        grep -vxF "\$*" "$T/rules" > "$T/rules.new"; mv "$T/rules.new" "$T/rules" ;;
esac
EOF
    chmod +x "$T/bin/tailscale" "$T/bin/tailscaled" "$T/fake/iptables"
}

# Usage: start [VAR=value ...]; waits for the script's background work.
start() {
    (cd "$T/bin" && env PATH="$T/fake:$PATH" TS_BIN="$T/bin" TS_STATEDIR="$T/state" \
        "$@" sh start_tailscale.sh >/dev/null 2>&1)
    sleep 4
}

# State is copied back to bin/ only when the tmpfs-fallback marker exists.
new_sandbox
echo s > "$T/state/tailscaled.state"
start
[ ! -f "$T/bin/tailscaled.state" ] && pass "no state copy-back without marker" \
    || fail "state copied to bin/ without marker"
touch "$T/state/.copy_back_to_bin"
start
[ -f "$T/bin/tailscaled.state" ] && pass "state copied back with marker" \
    || fail "state not copied back with marker"
rm -rf "$T"

# A hostile hostname must reach `tailscale up` as data, never be executed.
new_sandbox
start
if [ -f "$T/pwned" ]; then
    fail "command substitution in hostname was executed"
elif grep -qF -- '--hostname=dev$(touch' "$T/up.argv" 2>/dev/null; then
    pass "hostname passed as a literal argument"
else
    fail "hostname argument missing from tailscale up"
fi
rm -rf "$T"

# Firewall rules: added for kernel TUN, idempotent, removed on stop.
new_sandbox
start TS_TUN_FLAG=--tun=tailscale0
start TS_TUN_FLAG=--tun=tailscale0
[ "$(grep -c '^INPUT -i tailscale0' "$T/rules" 2>/dev/null)" = 1 ] \
    && pass "iptables INPUT rule added once in TUN mode" \
    || fail "iptables INPUT rule missing or duplicated"
(cd "$T/bin" && env PATH="$T/fake:$PATH" TS_BIN="$T/bin" sh stop_tailscale.sh >/dev/null 2>&1)
[ ! -s "$T/rules" ] && pass "iptables rules removed on stop" \
    || fail "iptables rules left behind after stop"
rm -rf "$T"

new_sandbox
start TS_TUN_FLAG=--tun=userspace-networking
[ ! -s "$T/rules" ] && pass "no iptables changes in userspace mode" \
    || fail "iptables touched in userspace mode"
rm -rf "$T"

# Taildrop receiver: its own fake `tailscale file get --loop`, which never
# returns on its own (matching the real --loop) until it is sent SIGTERM.
new_taildrop_sandbox() {
    T=$(mktemp -d)
    mkdir -p "$T/bin"
    cp "$ROOT/bin/start_taildrop.sh" "$ROOT/bin/stop_taildrop.sh" "$T/bin/"
    cat > "$T/bin/tailscale" <<'EOF'
#!/bin/sh
if [ "$1" = file ] && [ "$2" = get ]; then
    echo started >> "$(dirname "$0")/taildrop.calls"
    trap 'echo stopped >> "$(dirname "$0")/taildrop.calls"; exit 0' TERM
    while :; do sleep 0.2; done
fi
exit 0
EOF
    chmod +x "$T/bin/tailscale"
}

new_taildrop_sandbox
TS_BIN="$T/bin" TAILDROP_DIR="$T/home/taildrop" sh "$T/bin/start_taildrop.sh"
sleep 0.3
[ -d "$T/home/taildrop" ] && pass "taildrop target dir created" \
    || fail "taildrop target dir not created"
[ -f "$T/bin/taildrop.pid" ] && pass "taildrop pid file written" \
    || fail "taildrop pid file missing"
[ "$(grep -c started "$T/bin/taildrop.calls" 2>/dev/null)" = 1 ] \
    && pass "taildrop receiver started once" \
    || fail "taildrop receiver start count wrong"

# Idempotent: a second start while one is already running must not spawn another.
TS_BIN="$T/bin" TAILDROP_DIR="$T/home/taildrop" sh "$T/bin/start_taildrop.sh"
sleep 0.2
[ "$(grep -c started "$T/bin/taildrop.calls" 2>/dev/null)" = 1 ] \
    && pass "second start is a no-op while receiver is running" \
    || fail "second start spawned a duplicate receiver"

TS_BIN="$T/bin" sh "$T/bin/stop_taildrop.sh"
sleep 0.3
[ ! -f "$T/bin/taildrop.pid" ] && pass "taildrop pid file removed on stop" \
    || fail "taildrop pid file left behind after stop"
[ "$(grep -c stopped "$T/bin/taildrop.calls" 2>/dev/null)" = 1 ] \
    && pass "taildrop receiver stopped" \
    || fail "taildrop receiver not stopped"
rm -rf "$T"

# stop_taildrop.sh never touches tailscaled's own PID/marker files, and is a
# no-op when no receiver is tracked.
new_taildrop_sandbox
if TS_BIN="$T/bin" sh "$T/bin/stop_taildrop.sh"; then
    pass "stop_taildrop.sh is a clean no-op with nothing tracked"
else
    fail "stop_taildrop.sh failed with nothing tracked"
fi
rm -rf "$T"

if [ "$FAILS" -eq 0 ]; then
    echo "all passed"
else
    echo "$FAILS failed"
    exit 1
fi
