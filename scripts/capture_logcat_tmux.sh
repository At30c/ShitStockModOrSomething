#!/usr/bin/env bash

# Persistent ADB logcat capture. The loop intentionally survives USB/ADB
# disconnects so the next boot receives a new timestamped capture directory.
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION_NAME="${TMUX_LOGCAT_SESSION:-m21s-logcat}"
OUTPUT_ROOT="${TMUX_LOGCAT_OUTPUT:-$ROOT_DIR/out/target/m21s}"
POLL_SECONDS="${TMUX_LOGCAT_POLL_SECONDS:-2}"

adb_cmd() {
    if [[ -n "${ADB_SERIAL:-}" ]]; then
        adb -s "$ADB_SERIAL" "$@"
    else
        adb "$@"
    fi
}

device_ready() {
    [[ "$(adb_cmd get-state 2>/dev/null || true)" == "device" ]]
}

mkdir -p "$OUTPUT_ROOT"
printf 'Persistent logcat capture active (%s)\n' "$SESSION_NAME"

while :; do
    until device_ready; do
        sleep "$POLL_SECONDS"
    done

    CONNECTED_AT="$(date '+%Y-%m-%d_%H:%M:%S%z')"
    CAPTURE_DIR="$OUTPUT_ROOT/boot-diagnostics-${CONNECTED_AT}"
    mkdir -p "$CAPTURE_DIR"
    LOG_FILE="$CAPTURE_DIR/logcat.txt"
    MARKER="==== DEVICE_CONNECTED_${CONNECTED_AT} ===="
    printf '%s\n' "$MARKER" | tee -a "$LOG_FILE"

    # Keep the capture on disk and mirror it into the tmux pane so a live
    # reproduction can be watched without opening the output file separately.
    set -o pipefail
    adb_cmd logcat -b all -v threadtime 2>"$CAPTURE_DIR/logcat.stderr" | \
        tee -a "$LOG_FILE"
    LOGCAT_STATUS="${PIPESTATUS[0]}"
    set +o pipefail

    DISCONNECTED_AT="$(date '+%Y-%m-%d_%H:%M:%S%z')"
    printf '==== LOGCAT_DISCONNECTED_%s status=%s ====\n' \
        "$DISCONNECTED_AT" "$LOGCAT_STATUS" | tee -a "$LOG_FILE"
    sleep "$POLL_SECONDS"
done
