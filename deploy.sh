#!/bin/bash
# deploy.sh — push the tailscale.koplugin files to a Kindle over SSH
# Usage:
#   ./deploy.sh <kindle-ip>
#   ./deploy.sh <kindle-ip> --old-way   (list files to copy by hand)
#
# SSH port defaults to 22; override for devices running sshd elsewhere:
#   KINDLE_PORT=2222 ./deploy.sh <kindle-ip>

set -euo pipefail

KINDLE_IP="${1:-}"
[ -z "$KINDLE_IP" ] && { echo "Usage: $0 <kindle-ip> [--old-way]"; exit 1; }

KINDLE_PORT="${KINDLE_PORT:-22}"
SSH=(ssh -p "$KINDLE_PORT" -o StrictHostKeyChecking=no)
SCP=(scp -P "$KINDLE_PORT" -o StrictHostKeyChecking=no)

OLD_WAY=false
for arg in "${@:2}"; do
    case "$arg" in
        --old-way) OLD_WAY=true ;;
    esac
done

# The script lives at the repo root, so the repo is the plugin directory.
PLUGIN_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_REMOTE="/mnt/us/koreader/plugins/tailscale.koplugin"

echo "=== Deploying tailscale.koplugin to $KINDLE_IP:$KINDLE_PORT ==="

# Plugin payload: everything except repo tooling. Keep this list in sync with
# the excludes in .github/workflows/release.yml.
plugin_files() {
    find "$PLUGIN_DIR" \
        -not -path '*/.git/*' \
        -not -path '*/.claude/*' \
        -not -path '*/.github/*' \
        -not -name '.gitignore' \
        -not -name '*.zip' \
        -not -name '*.md' \
        -not -name 'LICENSE' \
        -not -name 'test.sh' \
        -not -name 'deploy.sh' \
        -type f | sort
}

if $OLD_WAY; then
    echo "Copy these to $PLUGIN_REMOTE/ via the KOReader filebrowser:"
    plugin_files | while read -r f; do echo "  ${f#$PLUGIN_DIR/}"; done
    exit 0
fi

echo "Testing SSH..."
if ! "${SSH[@]}" -o ConnectTimeout=5 -o BatchMode=yes root@"$KINDLE_IP" "echo ok" 2>/dev/null; then
    echo "SSH failed. Trying to deploy via scp anyway..."
fi

echo "Copying plugin files..."
"${SSH[@]}" root@"$KINDLE_IP" "mkdir -p $PLUGIN_REMOTE/bin" 2>/dev/null || true

plugin_files | while read -r f; do
    rel="${f#$PLUGIN_DIR/}"
    if "${SCP[@]}" "$f" root@"$KINDLE_IP":"$PLUGIN_REMOTE/$rel" 2>/dev/null; then
        echo "  ok   $rel"
    else
        echo "  FAIL $rel"
    fi
done

"${SSH[@]}" root@"$KINDLE_IP" \
    "chmod +x $PLUGIN_REMOTE/bin/*.sh 2>/dev/null; echo 'done'" 2>/dev/null || true

echo ""
echo "=== Deployed to $PLUGIN_REMOTE ==="
