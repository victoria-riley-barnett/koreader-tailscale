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

# Matching the installed version proves parsing worked; fake downloads fail.
VERSION_TEST_DIR=$(mktemp -d)
mkdir -p "$VERSION_TEST_DIR/bin" "$VERSION_TEST_DIR/tools"
cat > "$VERSION_TEST_DIR/tools/fetch" <<'EOF'
#!/bin/sh
case "$*" in
    *'?mode=json'*) printf '%s\n' '{' '  "TarballsVersion": "9.8.7"' '}' ;;
    *) exit 1 ;;
esac
EOF
cat > "$VERSION_TEST_DIR/bin/tailscale" <<'EOF'
#!/bin/sh
echo '9.8.7'
EOF
cp "$VERSION_TEST_DIR/bin/tailscale" "$VERSION_TEST_DIR/bin/tailscaled"
chmod +x "$VERSION_TEST_DIR/tools/fetch" "$VERSION_TEST_DIR"/bin/*
for tool in wget curl busybox; do
    ln -s fetch "$VERSION_TEST_DIR/tools/$tool"
done
if PATH="$VERSION_TEST_DIR/tools:$PATH" TS_BIN="$VERSION_TEST_DIR/bin" \
        TS_ARCH=arm sh bin/install-tailscale.sh; then
    pass "installer parses TarballsVersion"
else
    fail "installer could not parse TarballsVersion"
fi
rm -rf "$VERSION_TEST_DIR"

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

# --- TUN detection and fallback ---
echo ""
echo "--- feature checks ---"
if grep -q -- '--tun=tailscale0' main.lua && grep -q -- '--tun=userspace-networking' main.lua; then
    pass "main.lua selects kernel TUN with userspace fallback"
else
    fail "main.lua missing TUN selection or userspace fallback"
fi
if grep -q 'force-userspace' main.lua; then
    pass "main.lua supports force-userspace override"
else
    fail "main.lua missing force-userspace override"
fi
if grep -q 'TS_NETWORK_MODE' bin/start_tailscale.sh; then
    pass "start_tailscale.sh logs selected networking mode"
else
    fail "start_tailscale.sh missing networking mode logging"
fi
if grep -q 'socks5-server' bin/start_tailscale.sh; then
    pass "start_tailscale.sh has SOCKS5 proxy"
else
    fail "start_tailscale.sh missing SOCKS5 proxy"
fi

# --- Summary ---
echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
