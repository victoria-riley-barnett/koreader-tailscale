#!/bin/sh
# Thin executor: stop the Taildrop auto-receive loop started by
# start_taildrop.sh. Tracked by its own PID file (taildrop.pid), never
# tailscaled's, so this never races stop_tailscale.sh.

BIN_DIR="${TS_BIN:-$(cd "$(dirname "$0")" && pwd)}"
cd "$BIN_DIR" 2>/dev/null || exit 0

PID_FILE="$BIN_DIR/taildrop.pid"
[ -f "$PID_FILE" ] || exit 0

_pid=$(cat "$PID_FILE" 2>/dev/null)
rm -f "$PID_FILE"
[ -n "$_pid" ] || exit 0

kill "$_pid" 2>/dev/null || exit 0

# SIGTERM is asynchronous; wait for it to actually exit, same as
# stop_tailscale.sh does for tailscaled, with a SIGKILL fallback.
i=0
while kill -0 "$_pid" 2>/dev/null; do
    i=$((i+1))
    [ "$i" -ge 10 ] && kill -9 "$_pid" 2>/dev/null
    [ "$i" -ge 20 ] && break
    sleep 0.2
done

exit 0
