#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../../.." && pwd)"
ITERATIONS="${1:-10000}"
INTERVAL="${MONITOR_INTERVAL:-2}"
REMOTE_TEST="/data/local/tmp/graphics_allocator_bridge_test"
REMOTE_MAPPER="/vendor/lib64/hw/mapper.exynos990_compat.so"
REPORT="$ROOT/monitor-$(date +%Y%m%d-%H%M%S).log"

[[ "$ITERATIONS" =~ ^[0-9]+$ ]] && [ "$ITERATIONS" -gt 0 ] || {
    echo "Usage: $0 [positive-iteration-count]" >&2
    exit 1
}

adb get-state >/dev/null
adb shell service check android.hardware.graphics.allocator.IAllocator/default |
    grep -q 'found' || {
        echo "The isolated AIDL allocator test service is not active; refusing to test." >&2
        echo "Use a controlled image with the allocator rc/VINTF only for this diagnostic." >&2
    exit 1
}

adb push "$REPO/prebuilts/exynos990/graphics_allocator_bridge/test/graphics_allocator_bridge_test" "$REMOTE_TEST" >/dev/null
adb shell chmod 0755 "$REMOTE_TEST"

adb shell "$REMOTE_TEST" "$REMOTE_MAPPER" "$ITERATIONS" &
TEST_PID=$!
trap 'kill "$TEST_PID" 2>/dev/null || true' EXIT

while kill -0 "$TEST_PID" 2>/dev/null; do
    {
        date '+timestamp=%Y-%m-%dT%H:%M:%S%z'
        adb shell su -c 'cat /sys/kernel/debug/mali0/gpu_memory 2>/dev/null' || true
        adb shell su -c 'cat /proc/meminfo | grep -E "^(MemAvailable|Slab|SReclaimable):"' || true
        adb shell su -c 'cat /sys/kernel/debug/dma_buf/bufinfo 2>/dev/null | tail -n 5' || true
    } >> "$REPORT"
    sleep "$INTERVAL"
done

wait "$TEST_PID"
trap - EXIT
echo "Monitor report: $REPORT"
