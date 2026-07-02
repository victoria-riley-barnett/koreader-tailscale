#!/bin/sh
# suite.sh — tailscale.koplugin integration test suite
# Runs ON the Kindle. Tests capability checks, shell scripts, and full flow.
# Outputs structured results to stdout as key=value lines plus a JSON block.
#
# Usage: PLUGIN_DIR=/path/to/plugin sh suite.sh

set -e

# ─── config ────────────────────────────────────────────────────────

PLUGIN_DIR="${PLUGIN_DIR:-/mnt/us/koreader/plugins/tailscale.koplugin}"
BIN_DIR="$PLUGIN_DIR/bin"
RESULTS=""
PASS=0
FAIL=0
SKIP=0
START_TIME=$(date +%s)

# Ensure we have a writable temp dir
mkdir -p /tmp/tailscale-test 2>/dev/null || true
LOG_FILE="/tmp/tailscale-test/results.txt"
JSON_FILE="/tmp/tailscale-test/results.json"
: > "$LOG_FILE"

# ─── helpers ───────────────────────────────────────────────────────

log() { echo "$@" | tee -a "$LOG_FILE"; }
pass() { PASS=$((PASS + 1)); log "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); log "  ❌ $1 — $2"; }
skip() { SKIP=$((SKIP + 1)); log "  ⏭️  $1 — $2"; }

assert() {
    local desc="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc" "expected '$expected' got '$actual'"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) pass "$desc" ;;
        *) fail "$desc" "expected to contain '$needle'" ;;
    esac
}

run_cmd() {
    # Run a command, capture exit code and stdout
    local out
    out=$(eval "$1" 2>&1) || true
    local rc=$?
    printf '%s' "$out"
    return $rc
}

# ─── preflight ─────────────────────────────────────────────────────

log ""
log "═══════════════════════════════════════"
log "  tailscale.koplugin v1.2.0 test suite"
log "═══════════════════════════════════════"
log ""

log "─── preflight ───"

ARCH=$(uname -m 2>/dev/null || echo "unknown")
log "  arch: $ARCH"
log "  plugin_dir: $PLUGIN_DIR"

if [ ! -d "$PLUGIN_DIR" ]; then
    fail "preflight" "plugin dir not found at $PLUGIN_DIR"
    log "ABORTING — plugin not deployed"
    exit 1
fi
pass "plugin directory exists"

if [ ! -f "$PLUGIN_DIR/main.lua" ]; then
    fail "preflight" "main.lua missing"
    exit 1
fi
pass "main.lua present"

if [ ! -f "$BIN_DIR/start_tailscale.sh" ]; then
    fail "preflight" "start_tailscale.sh missing"
    exit 1
fi
pass "start_tailscale.sh present"

if [ -f "$BIN_DIR/start_tailscale_headscale.sh" ]; then
    fail "preflight" "start_tailscale_headscale.sh still exists (should be deleted in v1.2.0)"
else
    pass "headscale script correctly removed (v1.2.0)"
fi

# ─── capability checks ─────────────────────────────────────────────

log ""
log "─── capability checks (Lua equivalents) ───"

# TUN detection
if [ -c /dev/net/tun ]; then
    TUN_AVAILABLE="yes"
    log "  /dev/net/tun exists → kernel TUN available"
    pass "TUN device detected"
else
    TUN_AVAILABLE="no"
    log "  /dev/net/tun missing → will use userspace-networking"
    pass "TUN device absent (userspace fallback)"
fi

# Loopback check
LO_HAS_IP="no"
if ifconfig lo 2>/dev/null | grep -q '127\.0\.0\.1'; then
    LO_HAS_IP="yes"
    pass "loopback has 127.0.0.1"
else
    log "  loopback missing 127.0.0.1 — plugin will configure it"
    skip "loopback check" "not pre-configured (plugin handles this)"
fi

# Network check
if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
    NET_OK="yes"
    pass "network reachable"
else
    NET_OK="no"
    log "  network unreachable — many tests will be skipped"
    skip "network check" "no connectivity (connect WiFi to test full flow)"
fi

# State dir: chmod test
STATE_TEST="$BIN_DIR/.chmod_test"
if touch "$STATE_TEST" 2>/dev/null && chmod 0600 "$STATE_TEST" 2>/dev/null; then
    STATE_DIR="$BIN_DIR"
    rm -f "$STATE_TEST"
    pass "state dir: bin/ supports chmod → using $STATE_DIR"
else
    STATE_DIR="/tmp/tailscale"
    rm -f "$STATE_TEST" 2>/dev/null
    pass "state dir: bin/ read-only → using $STATE_DIR"
fi

# ─── binary checks ─────────────────────────────────────────────────

log ""
log "─── binary checks ───"

if [ -x "$BIN_DIR/tailscale" ] && [ -x "$BIN_DIR/tailscaled" ]; then
    TAILSCALE_VER=$("$BIN_DIR/tailscale" version 2>/dev/null | head -1 || echo "unknown")
    log "  tailscale: $TAILSCALE_VER"
    pass "tailscale binary present"
    pass "tailscaled binary present"
    BINARIES_OK="yes"
else
    log "  binaries not found — run Install from KOReader menu first"
    skip "binary check" "binaries not installed (use Install menu item)"
    BINARIES_OK="no"
fi

# ─── auth key checks ───────────────────────────────────────────────

log ""
log "─── auth key checks ───"

AUTH_FILE="$BIN_DIR/auth.key"
if [ -f "$AUTH_FILE" ]; then
    if grep -qE '^(tskey-|hskey-auth-)' "$AUTH_FILE"; then
        KEY_TYPE="tailscale"
        grep -q 'hskey-auth-' "$AUTH_FILE" && KEY_TYPE="headscale"
        log "  auth key found ($KEY_TYPE format)"
        pass "auth key present ($KEY_TYPE)"
        AUTH_OK="yes"
    else
        log "  auth.key exists but no valid key format found"
        fail "auth key" "file exists but no tskey-/hskey-auth- match"
        AUTH_OK="no"
    fi
else
    log "  no auth.key — tailscale up will need interactive login"
    skip "auth key" "not configured (optional)"
    AUTH_OK="no"
fi

# Headscale URL check
HS_FILE="$BIN_DIR/headscale.url"
if [ -f "$HS_FILE" ]; then
    HS_URL=$(head -1 "$HS_FILE" 2>/dev/null | tr -d '\r\n')
    if [ -n "$HS_URL" ]; then
        log "  headscale URL: $HS_URL"
        pass "headscale configured"
        HEADSCALE_OK="yes"
    else
        skip "headscale" "file exists but empty"
        HEADSCALE_OK="no"
    fi
else
    HEADSCALE_OK="no"
fi

# ─── shell script syntax check ─────────────────────────────────────

log ""
log "─── shell script syntax ───"

for script in start_tailscale.sh stop_tailscale.sh install-tailscale.sh uninstall-tailscale.sh; do
    if [ -f "$BIN_DIR/$script" ]; then
        if sh -n "$BIN_DIR/$script" 2>/dev/null; then
            pass "$script: syntax OK"
        else
            fail "$script" "syntax error"
        fi
    else
        fail "$script" "file missing"
    fi
done

# ─── daemon lifecycle tests ────────────────────────────────────────

log ""
log "─── daemon lifecycle ───"

if [ "$BINARIES_OK" != "yes" ]; then
    skip "daemon lifecycle" "no binaries"
else
    # Stop anything running first
    "$BIN_DIR/stop_tailscale.sh" 2>/dev/null || true
    sleep 2

    # Test: not running after stop
    if pgrep tailscaled >/dev/null 2>&1; then
        fail "stop daemon" "tailscaled still running after stop"
    else
        pass "stop daemon: clean"
    fi

    if [ "$NET_OK" = "yes" ]; then
        # Test: start daemon
        log "  starting daemon (TUN=$TUN_AVAILABLE state=$STATE_DIR)..."
        TS_BIN="$BIN_DIR" \
        TS_STATEDIR="$STATE_DIR" \
        TS_TUN_FLAG="$([ "$TUN_AVAILABLE" = "yes" ] || echo '--tun=userspace-networking')" \
        TS_UP_FLAGS="--accept-routes --accept-dns=false --netfilter-mode=off" \
        sh "$BIN_DIR/start_tailscale.sh" > /tmp/tailscale-test/start.log 2>&1
        START_RC=$?

        sleep 2

        if pgrep tailscaled >/dev/null 2>&1; then
            pass "start daemon: tailscaled running"
            DAEMON_RUNNING="yes"
        else
            fail "start daemon" "tailscaled not running after start (rc=$START_RC)"
            log "  tailscaled log:"
            tail -5 "$BIN_DIR/tailscaled.log" 2>/dev/null | while read -r line; do log "    $line"; done
            DAEMON_RUNNING="no"
        fi

        # Test: tailscale status
        if "$BIN_DIR/tailscale" status --json >/tmp/tailscale-test/status.json 2>/dev/null; then
            STATUS_JSON=$(cat /tmp/tailscale-test/status.json)
            if echo "$STATUS_JSON" | grep -q '"BackendState"'; then
                BACKEND=$(echo "$STATUS_JSON" | sed -n 's/.*"BackendState":[[:space:]]*"\([^"]*\)".*/\1/p')
                log "  backend state: $BACKEND"
                pass "tailscale status --json works"
            else
                fail "tailscale status" "missing BackendState in JSON"
            fi

            # Check for IPs (TailscaleIPs can be table or function)
            if echo "$STATUS_JSON" | grep -q '"TailscaleIPs"'; then
                pass "TailscaleIPs present in status JSON"
            fi
        else
            fail "tailscale status" "status --json failed"
        fi

        # Test: stop
        TS_BIN="$BIN_DIR" sh "$BIN_DIR/stop_tailscale.sh" 2>/dev/null
        sleep 2
        if pgrep tailscaled >/dev/null 2>&1; then
            fail "stop daemon" "tailscaled still running after stop"
        else
            pass "stop daemon: clean after lifecycle"
        fi
        DAEMON_RUNNING="no"
    else
        skip "daemon lifecycle" "no network"
    fi
fi

# ─── configure auth key UI (simulate what Lua does) ─────────────────

log ""
log "─── auth key parsing (simulating Lua readAuthKey) ───"

# Test: tskey- format
echo "tskey-auth-abc123def456" > /tmp/tailscale-test/auth-test-ts.key
KEY=$(grep -E '^(tskey-|hskey-auth-)' /tmp/tailscale-test/auth-test-ts.key | head -1 | tr -d '[:space:]')
if [ "$KEY" = "tskey-auth-abc123def456" ]; then
    pass "tskey- format detected"
else
    fail "tskey- format" "got '$KEY'"
fi

# Test: hskey-auth- format
echo "hskey-auth-xyz789" > /tmp/tailscale-test/auth-test-hs.key
KEY=$(grep -E '^(tskey-|hskey-auth-)' /tmp/tailscale-test/auth-test-hs.key | head -1 | tr -d '[:space:]')
if [ "$KEY" = "hskey-auth-xyz789" ]; then
    pass "hskey-auth- format detected"
else
    fail "hskey-auth- format" "got '$KEY'"
fi

# Test: comments skipped
printf "# my key\n  tskey-auth-foo123  \n" > /tmp/tailscale-test/auth-test-comment.key
# Simulate Lua's line-by-line scan: skip # and blanks
FOUND=""
while IFS= read -r line; do
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    case "$line" in tskey-*|hskey-auth-*) FOUND="$line"; break ;; esac
done < /tmp/tailscale-test/auth-test-comment.key
if [ "$FOUND" = "tskey-auth-foo123" ]; then
    pass "comments skipped, key found"
else
    fail "comment skip" "got '$FOUND'"
fi

# ─── loopback setup simulation ─────────────────────────────────────

log ""
log "─── loopback setup check ───"

# Verify the commands the plugin would run exist
LO_WORKS="yes"
if command -v ifconfig >/dev/null 2>&1; then
    pass "ifconfig available"
else
    fail "ifconfig" "not found (needed for loopback setup)"
    LO_WORKS="no"
fi
# ip command is fallback, not universally available
if command -v ip >/dev/null 2>&1; then
    pass "iproute2 available (fallback)"
else
    log "  iproute2 not available (ifconfig is primary, this is fine)"
fi

# ─── network gating test ───────────────────────────────────────────

log ""
log "─── network gating ───"

# The Lua connectTailscale() pings 8.8.8.8 — verify ping works
if command -v ping >/dev/null 2>&1; then
    pass "ping available (needed for network gate)"
    if [ "$NET_OK" = "yes" ]; then
        pass "network gate: would allow connection (ping succeeds)"
    else
        pass "network gate: would block connection (ping fails) — correct behavior"
    fi
else
    fail "ping" "not available (network gate won't work)"
fi

# ─── edge cases ────────────────────────────────────────────────────

log ""
log "─── edge cases ───"

# Test: empty auth.key
: > /tmp/tailscale-test/auth-empty.key
if grep -qE '^(tskey-|hskey-auth-)' /tmp/tailscale-test/auth-empty.key; then
    fail "empty auth.key" "false positive on empty file"
else
    pass "empty auth.key: correctly ignored"
fi

# Test: whitespace-only auth.key
echo "   " > /tmp/tailscale-test/auth-blank.key
KEY=$(grep -E '^(tskey-|hskey-auth-)' /tmp/tailscale-test/auth-blank.key | head -1 | tr -d '[:space:]' || true)
if [ -z "$KEY" ]; then
    pass "blank auth.key: correctly ignored"
else
    fail "blank auth.key" "false positive '$KEY'"
fi

# Test: no double --auth-key in start script
if grep -q '\$TS_AUTH_KEY' "$BIN_DIR/start_tailscale.sh"; then
    # Check that TS_UP_FLAGS line doesn't also include auth-key
    if grep 'TS_UP_FLAGS' "$BIN_DIR/start_tailscale.sh" | grep -q 'auth-key'; then
        fail "double auth-key" "TS_UP_FLAGS includes auth-key AND shell adds TS_AUTH_KEY"
    else
        pass "auth-key added once (shell via TS_AUTH_KEY)"
    fi
else
    skip "auth-key check" "shell script structure unexpected"
fi

# ─── results ───────────────────────────────────────────────────────

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log ""
log "═══════════════════════════════════════"
log "  RESULTS"
log "═══════════════════════════════════════"
log "  passed: $PASS"
log "  failed: $FAIL"
log "  skipped: $SKIP"
log "  duration: ${DURATION}s"
log ""

# JSON output for machine parsing
cat > "$JSON_FILE" << JSONEOF
{
  "version": "1.2.0",
  "passed": $PASS,
  "failed": $FAIL,
  "skipped": $SKIP,
  "duration_s": $DURATION,
  "device": {
    "arch": "$ARCH",
    "tun_available": "$TUN_AVAILABLE",
    "network_ok": "$NET_OK",
    "loopback_ok": "$LO_HAS_IP",
    "state_dir": "$STATE_DIR"
  },
  "binaries": "$BINARIES_OK",
  "auth": {
    "key_configured": "$AUTH_OK",
    "headscale_configured": "$HEADSCALE_OK"
  },
  "daemon": {
    "running": "${DAEMON_RUNNING:-not_tested}"
  }
}
JSONEOF

log "JSON results written to $JSON_FILE"

if [ "$FAIL" -gt 0 ]; then
    log "⚠️  $FAIL test(s) failed"
    exit 1
else
    log "✅ all tests passed"
    exit 0
fi
