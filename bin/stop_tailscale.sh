#!/bin/sh
# Thin executor: stop tailscaled and clean up.

BIN_DIR="${TS_BIN:-$(cd "$(dirname "$0")" && pwd)}"
cd "$BIN_DIR" 2>/dev/null || exit 0

./tailscale down >/dev/null 2>&1 || true
./tailscaled -cleanup >/dev/null 2>&1 || true
killall tailscaled 2>/dev/null || true

# Remove the firewall rules start_tailscale.sh may have added for tailscale0.
# Looped so duplicates from older starts are cleared too.
for _ipt in iptables /usr/sbin/iptables /sbin/iptables; do
    command -v "$_ipt" >/dev/null 2>&1 || continue
    for _dir in "INPUT -i" "OUTPUT -o"; do
        # shellcheck disable=SC2086
        while "$_ipt" -D $_dir tailscale0 -j ACCEPT 2>/dev/null; do :; done
    done
    break
done

# killall sends SIGTERM asynchronously; wait for tailscaled to actually exit so it no longer
# holds the filesystem busy (e.g. before KOReader enters USB storage mode). SIGKILL fallback.
i=0
while pgrep tailscaled >/dev/null 2>&1; do
    i=$((i+1))
    [ "$i" -ge 10 ] && killall -9 tailscaled 2>/dev/null
    [ "$i" -ge 20 ] && break
    sleep 0.2
done

# Sync tmpfs state back to persistent storage so node identity survives
# reboots — only on devices with no private persistent dir, where Lua fell back
# to /tmp/tailscale and left the marker (see resolveStateDir). Anywhere else the
# state already lives somewhere persistent, and copying it into bin/ would put
# the node's private keys back on the USB-exported partition.
if [ -f /tmp/tailscale/.copy_back_to_bin ]; then
    for f in tailscaled.state tailscaled.log.conf; do
        if [ -f "/tmp/tailscale/$f" ]; then
            cp -f "/tmp/tailscale/$f" "$BIN_DIR/$f" 2>/dev/null || true
        fi
    done
fi

exit 0
