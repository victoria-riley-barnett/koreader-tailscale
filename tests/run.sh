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
    printf '#!/bin/sh\necho "fake tailscaled started"\nexit 0\n' > "$T/bin/tailscaled"
    # Records its argv one argument per line, so quoting bugs are visible.
    cat > "$T/bin/tailscale" <<EOF
#!/bin/sh
if [ "\$1" = up ]; then
    for a in "\$@"; do printf '%s\n' "\$a"; done > "$T/up.argv"
fi
[ "\$1" = status ] && echo '{"HostName":"dev\$(touch $T/pwned)"}'
if [ "\$1" = debug ] && [ "\$2" = prefs ]; then
    printf '{"CorpDNS": %s}\n' "\${FAKE_CORPDNS:-false}"
fi
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
    # start/stop scripts kill by process name. Without these, running the tests
    # on a machine that actually uses Tailscale takes its daemon down.
    printf '#!/bin/sh\nexit 1\n' > "$T/fake/pgrep"
    printf '#!/bin/sh\nexit 0\n' > "$T/fake/killall"
    chmod +x "$T/fake/pgrep" "$T/fake/killall"
}

# Usage: start [VAR=value ...]; waits for the script's background work, then
# asserts both logs landed in the private logs dir and none is left in bin/,
# which on a device is the USB-exported user partition.
start() {
    (cd "$T/bin" && env PATH="$T/fake:$PATH" TS_BIN="$T/bin" TS_STATEDIR="$T/state" \
        "$@" sh start_tailscale.sh >/dev/null 2>&1)
    sleep 4
    _logs="${TS_LOGS_DIR:-$T/state/logs}"
    [ -f "$_logs/tailscaled.log" ] && pass "tailscaled.log under logs [$*]" \
        || fail "tailscaled.log missing from logs [$*]"
    [ -f "$_logs/tailscale.log" ] && pass "tailscale.log under logs [$*]" \
        || fail "tailscale.log missing from logs [$*]"
    if ls "$T"/bin/*.log >/dev/null 2>&1; then
        fail "*.log left in bin/ [$*]"
    else
        pass "no *.log in bin/ [$*]"
    fi
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

# A log written by an older build sits in bin/ (USB-exported) and holds the
# interactive login URL. It must move to the private logs dir, URL intact, with
# nothing left behind in bin/.
new_sandbox
printf 'https://login.tailscale.com/a/faketoken\n' > "$T/bin/tailscale.log"
printf 'old daemon log\n' > "$T/bin/tailscaled.log"
start
[ ! -f "$T/bin/tailscale.log" ] && pass "pre-existing bin/tailscale.log removed from bin" \
    || fail "pre-existing bin/tailscale.log still in bin"
grep -qF 'login.tailscale.com/a/faketoken' "$T/state/logs/tailscale.log" 2>/dev/null \
    && pass "pre-existing login URL preserved under logs" \
    || fail "pre-existing login URL lost or left in bin"
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

# The daemon's stored DNS preference is carried into `tailscale up`; the plugin
# never chooses a value itself.
new_sandbox
start
grep -qxF -- '--accept-dns=false' "$T/up.argv" 2>/dev/null \
    && pass "stored DNS preference false is carried into up" \
    || fail "stored DNS preference false missing from up"
[ "$(grep -c -- '--accept-dns=' "$T/up.argv" 2>/dev/null)" = 1 ] \
    && pass "DNS flag is passed exactly once" \
    || fail "DNS flag missing or duplicated"
rm -rf "$T"

new_sandbox
start FAKE_CORPDNS=true
grep -qxF -- '--accept-dns=true' "$T/up.argv" 2>/dev/null \
    && pass "stored DNS preference true is carried into up" \
    || fail "stored DNS preference true missing from up"
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

# Lua passes TS_LOGS_DIR: both logs must follow it, and bin/ must stay clean.
new_sandbox
export TS_LOGS_DIR="$T/private-logs"
start
[ -f "$T/private-logs/tailscale.log" ] && pass "TS_LOGS_DIR honored for tailscale.log" \
    || fail "TS_LOGS_DIR ignored for tailscale.log"
unset TS_LOGS_DIR
rm -rf "$T"

if [ "$FAILS" -eq 0 ]; then
    echo "all passed"
else
    echo "$FAILS failed"
    exit 1
fi
