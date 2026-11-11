#!/bin/sh
# Thin executor: launch `tailscale file get --loop` in the background against
# TAILDROP_DIR and track it with its own PID file (taildrop.pid), kept apart
# from tailscaled's own process management so stopping one never races the
# other during a USB storage mode transition.
#
# --loop never returns on its own: it retries internally on error and only
# exits on a kill signal, so there is no respawn loop here — just start it
# once and track the PID. Idempotent: leaves an already-running receiver alone.

BIN_DIR="${TS_BIN:-$(cd "$(dirname "$0")" && pwd)}"
TARGET_DIR="${TAILDROP_DIR:?TAILDROP_DIR not set}"

cd "$BIN_DIR" || exit 1

[ -f ./tailscale ] || exit 1

PID_FILE="$BIN_DIR/taildrop.pid"

if [ -f "$PID_FILE" ]; then
    _pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
        exit 0
    fi
    rm -f "$PID_FILE"
fi

mkdir -p "$TARGET_DIR" 2>/dev/null || exit 1

./tailscale file get --loop --conflict=rename "$TARGET_DIR" \
    < /dev/null >> taildrop.log 2>&1 &
echo $! > "$PID_FILE"

exit 0
