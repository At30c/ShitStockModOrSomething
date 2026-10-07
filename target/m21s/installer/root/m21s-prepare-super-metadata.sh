#!/sbin/sh
#
# Prepare the expanded M21s super metadata before the old TWRP liblp updater
# applies dynamic_partitions_op_list.  The repartitioner changes the physical
# GPT entry, while the stock metadata still advertises the original 6.5-GiB
# super size.  Four metadata copies are used by the standard LP layout.
#
# This is deliberately restricted to the temporary 11305-MiB M21s layout.

set -u

LOGFILE="/tmp/m21s-super-metadata.log"
: > "$LOGFILE" 2>/dev/null || true

log() {
    printf '%s\n' "M21s super metadata: $*"
    printf '%s\n' "M21s super metadata: $*" >> "$LOGFILE" 2>/dev/null || true
}

die() {
    log "ERROR: $*"
    exit 1
}

META="${1:-/tmp/m21s-super-metadata.img}"
[ -s "$META" ] || die "metadata image is missing: $META"

MODEL="$(getprop ro.boot.em.model 2>/dev/null || true)"
HARDWARE="$(getprop ro.boot.hardware 2>/dev/null || true)"
case "$MODEL:$HARDWARE" in
    SM-F415F:exynos9611|SM-F415F/DS:exynos9611) ;;
    *) die "wrong device (boot=$MODEL hw=$HARDWARE); expected SM-F415F on exynos9611" ;;
esac

SUPER=""
for CANDIDATE in /dev/block/by-name/super /dev/block/platform/*/by-name/super; do
    if [ -b "$CANDIDATE" ]; then
        SUPER="$CANDIDATE"
        break
    fi
done
[ "$SUPER" ] || die "unable to resolve /dev/block/by-name/super"

BLOCKDEV="$(command -v blockdev 2>/dev/null || true)"
[ "$BLOCKDEV" ] || die "blockdev is unavailable in recovery"
SUPER_SIZE="$($BLOCKDEV --getsize64 "$SUPER" 2>/dev/null || true)"
[ "$SUPER_SIZE" -ge 11854151680 ] 2>/dev/null || \
    die "super is ${SUPER_SIZE:-unknown} bytes; expected at least 11854151680"

# lpmake's metadata image has a 4-KiB geometry prefix followed by the 592-byte
# metadata payload.  Copy one complete 4-KiB block so stale bytes after the
# payload cannot be interpreted as a second header.
SLOT="/tmp/m21s-super-metadata-slot.bin"
dd if=/dev/zero of="$SLOT" bs=4096 count=1 2>>"$LOGFILE" || \
    die "unable to allocate metadata payload buffer"
dd if="$META" of="$SLOT" bs=4096 skip=1 count=1 conv=notrunc 2>>"$LOGFILE" || \
    die "unable to extract metadata payload"

# Primary/backup geometry copies are unchanged.  These are the four standard
# metadata slot offsets for a 64-KiB metadata area and two slots:
#   0x3000, 0x13000, 0x23000 and 0x33000 (4096-byte sectors 3, 19, 35, 51).
for OFFSET in 3 19 35 51; do
    log "writing metadata slot sector $OFFSET to $SUPER"
    dd if="$SLOT" of="$SUPER" bs=4096 seek="$OFFSET" count=1 \
        conv=notrunc 2>>"$LOGFILE" || die "failed to write metadata slot $OFFSET"
done
sync

# Read back one slot.  cmp is present in the target recovery's toybox; this
# catches a read-only or incorrectly resolved super block before liblp runs.
VERIFY="/tmp/m21s-super-metadata-verify.bin"
dd if="$SUPER" of="$VERIFY" bs=4096 skip=3 count=1 2>>"$LOGFILE" || \
    die "unable to read back metadata slot"
cmp -s "$SLOT" "$VERIFY" || die "metadata read-back verification failed"

log "metadata updated for super=${SUPER_SIZE} bytes"
exit 0
