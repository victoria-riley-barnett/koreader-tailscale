#!/bin/bash
# deploy.sh — push tailscale plugin to Kindle and run test suite
# Usage:
#   ./test/deploy.sh <kindle-tailscale-ip>
#   ./test/deploy.sh <kindle-tailscale-ip> --skip-tests  (deploy only)
#   ./test/deploy.sh <kindle-tailscale-ip> --old-way      (use filebrowser method)

set -euo pipefail

KINDLE_IP="${1:-}"
[ -z "$KINDLE_IP" ] && { echo "Usage: $0 <kindle-tailscale-ip> [--skip-tests|--old-way]"; exit 1; }

SKIP_TESTS=false
OLD_WAY=false
for arg in "${@:2}"; do
    case "$arg" in
        --skip-tests) SKIP_TESTS=true ;;
        --old-way) OLD_WAY=true ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Deploying tailscale.koplugin to $KINDLE_IP ==="

# ─── Deploy ────────────────────────────────────────────────────────

PLUGIN_REMOTE="/mnt/us/koreader/plugins/tailscale.koplugin"
TEST_REMOTE="/tmp/tailscale-test"

if $OLD_WAY; then
    # Filebrowser path: user copies manually
    echo "OLD WAY: copy these files to your Kindle via KOReader filebrowser:"
    echo "  Plugin files → $PLUGIN_REMOTE/"
    echo "  Test suite  → $TEST_REMOTE/suite.sh"
    echo ""
    echo "Plugin files to copy:"
    find "$PLUGIN_DIR" -not -path '*/.git/*' -not -name '.gitignore' -not -name 'CLAUDE.md' -not -name 'AGENTS.md' -type f | sort
    echo ""
    echo "Then on the Kindle, run:"
    echo "  sh $TEST_REMOTE/suite.sh"
    exit 0
fi

# SSH deploy
echo "Testing SSH to $KINDLE_IP..."
if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@"$KINDLE_IP" "echo ok" 2>/dev/null; then
    echo "SSH failed. Trying to deploy via scp anyway..."
fi

echo "Copying plugin files..."
ssh root@"$KINDLE_IP" "mkdir -p $PLUGIN_REMOTE/bin $PLUGIN_REMOTE/test" 2>/dev/null || true

# Copy all plugin files
find "$PLUGIN_DIR" -not -path '*/.git/*' \
    -not -name '.gitignore' \
    -not -name 'CLAUDE.md' \
    -not -name 'AGENTS.md' \
    -type f | while read -r f; do
    rel="${f#$PLUGIN_DIR/}"
    echo "  $rel"
    scp -o StrictHostKeyChecking=no "$f" root@"$KINDLE_IP":"$PLUGIN_REMOTE/$rel" 2>/dev/null
done

# Make scripts executable
ssh root@"$KINDLE_IP" "chmod +x $PLUGIN_REMOTE/bin/*.sh $PLUGIN_REMOTE/test/*.sh 2>/dev/null; echo 'done'" 2>/dev/null || true

echo ""

if $SKIP_TESTS; then
    echo "=== Deploy complete (tests skipped) ==="
    echo "To run tests manually on Kindle: sh $PLUGIN_REMOTE/test/suite.sh"
    exit 0
fi

# ─── Run test suite ────────────────────────────────────────────────

echo "=== Running test suite on Kindle ==="
echo ""

ssh -o StrictHostKeyChecking=no root@"$KINDLE_IP" \
    "PLUGIN_DIR='$PLUGIN_REMOTE' sh '$PLUGIN_REMOTE/test/suite.sh'" 2>&1

echo ""
echo "=== Done ==="
