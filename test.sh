#!/bin/sh
# Basic validation tests for tailscale.koplugin
# Run: sh test.sh
set -e

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "  ok: $1"; PASS=$((PASS + 1)); }

echo "=== tailscale.koplugin tests ==="

# --- Version consistency ---
META_VER=$(grep 'version' _meta.lua | grep -o '[0-9][0-9.]*')
INSTALL_VER=$(grep '^TS_FALLBACK_VER=\|^TS_VER=' bin/install-tailscale.sh | head -1 | grep -o '[0-9][0-9.]*')

echo ""
echo "--- version checks ---"
[ -n "$META_VER" ] && pass "meta version: $META_VER" || fail "could not parse _meta.lua version"
[ -n "$INSTALL_VER" ] && pass "install script pins tailscale: $INSTALL_VER" || fail "could not parse TS_VER from install script"

# --- Lua syntax ---
echo ""
echo "--- lua syntax ---"
for f in main.lua _meta.lua; do
    if lua -e "loadfile('$f')()" 2>/dev/null; then
        pass "$f loads"
    else
        # loadfile alone (syntax check only)
        if lua -e "assert(loadfile('$f'))" 2>/dev/null; then
            pass "$f parses"
        else
            fail "$f has syntax errors"
        fi
    fi
done

# --- Luacheck (if available) ---
if command -v luacheck >/dev/null 2>&1; then
    echo ""
    echo "--- luacheck ---"
    if luacheck main.lua --no-unused --no-redefined --no-max-line-length --ignore 611 612 613 614 --globals require 2>&1 | grep -q 'OK'; then
        pass "luacheck main.lua"
    else
        fail "luacheck main.lua"
    fi
fi

# --- Shell script syntax ---
echo ""
echo "--- shell syntax ---"
for f in bin/*.sh; do
    if sh -n "$f" 2>/dev/null; then
        pass "$f parses"
    else
        fail "$f has syntax errors"
    fi
done

# --- Shell scripts are POSIX (no bash-isms) ---
echo ""
echo "--- posix checks ---"
for f in bin/*.sh; do
    bashism=0
    grep -n '^function ' "$f" >/dev/null 2>&1 && bashism=1
    grep -n '^declare ' "$f" >/dev/null 2>&1 && bashism=1
    # Match literal [[ but not inside sed/regex patterns
    grep -n '	\[\[' "$f" >/dev/null 2>&1 && bashism=1
    if [ "$bashism" -eq 1 ]; then
        fail "$f contains bash-isms (should be POSIX sh)"
    else
        pass "$f is POSIX-clean"
    fi
done

# --- Key files exist ---
echo ""
echo "--- structure ---"
for f in main.lua _meta.lua bin/install-tailscale.sh bin/start_tailscale.sh bin/stop_tailscale.sh bin/uninstall-tailscale.sh; do
    [ -f "$f" ] && pass "$f exists" || fail "$f missing"
done

# --- Scripts have shebangs ---
echo ""
echo "--- shebangs ---"
for f in bin/*.sh; do
    if head -1 "$f" | grep -q '^#!/bin/sh'; then
        pass "$f has #!/bin/sh"
    else
        fail "$f missing #!/bin/sh shebang"
    fi
done

# --- TUN fallback in start scripts ---
echo ""
echo "--- feature checks ---"
for f in bin/start_tailscale.sh bin/start_tailscale_headscale.sh; do
    if grep -q 'userspace-networking' "$f"; then
        pass "$f has userspace-networking fallback"
    else
        fail "$f missing userspace-networking fallback"
    fi
    if grep -q 'socks5-server' "$f"; then
        pass "$f has SOCKS5 proxy"
    else
        fail "$f missing SOCKS5 proxy"
    fi
done

# --- Summary ---
echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
