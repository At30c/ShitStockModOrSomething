#!/sbin/sh
#
# Format the filesystems recreated by the temporary M21s repartitioner.
#
# This deliberately does not touch super (dynamic-partition container),
# metadata, or nad_fw (raw firmware/NAD partition). Flash the ROM images to
# super after this package and keep a stock firmware/PIT available.

set -u

LOGFILE="/tmp/m21s-format.log"
STATUSFILE="/tmp/m21s-format.status"
FAILED=1

: > "$LOGFILE" 2>/dev/null || true
printf '%s\n' 'status=running' > "$STATUSFILE" 2>/dev/null || true

log() {
    printf '%s\n' "M21s formatter: $*"
    printf '%s\n' "M21s formatter: $*" >> "$LOGFILE" 2>/dev/null || true
}

die() {
    log "ERROR: $* (see $LOGFILE)"
    exit 1
}

on_exit() {
    if [ "$FAILED" -ne 0 ]; then
        printf '%s\n' 'status=failed' > "$STATUSFILE" 2>/dev/null || true
    fi
}
trap on_exit 0

MODEL="$(getprop ro.product.model 2>/dev/null || true)"
DEVICE="$(getprop ro.product.device 2>/dev/null || true)"
BOOT_MODEL="$(getprop ro.boot.em.model 2>/dev/null || true)"
BOOT_HARDWARE="$(getprop ro.boot.hardware 2>/dev/null || true)"
case "$MODEL:$DEVICE:$BOOT_MODEL:$BOOT_HARDWARE" in
    SM-F415F:*:*:exynos9611|*:f41:*:exynos9611|*:f41ns:*:exynos9611|*:*:SM-F415F:exynos9611) ;;
    *) die "wrong device (product=$MODEL/$DEVICE boot=$BOOT_MODEL hw=$BOOT_HARDWARE); expected SM-F415F/f41 on exynos9611" ;;
esac

EXT4=""
for CANDIDATE in /system/bin/mke2fs /sbin/mke2fs; do
    if [ -x "$CANDIDATE" ] && "$CANDIDATE" -V >>"$LOGFILE" 2>&1; then
        EXT4="$CANDIDATE"
        break
    fi
done
[ "$EXT4" ] || die "mke2fs is unavailable in recovery"

F2FS=""
for CANDIDATE in /system/bin/make_f2fs /sbin/make_f2fs; do
    if [ -x "$CANDIDATE" ] && "$CANDIDATE" -V >>"$LOGFILE" 2>&1; then
        F2FS="$CANDIDATE"
        break
    fi
done
[ "$F2FS" ] || die "make_f2fs is unavailable in recovery"

resolve_partition() {
    NAME="$1"
    LINK="/dev/block/by-name/$NAME"
    [ -e "$LINK" ] || die "missing partition: $NAME"
    PART="$(readlink -f "$LINK" 2>/dev/null || true)"
    [ "$PART" ] || PART="$LINK"
    [ -b "$PART" ] || die "partition $NAME is not a block device: $PART"
    printf '%s\n' "$PART"
}

unmount_all() {
    for MOUNTPOINT in /data /cache /prism /optics /omr; do
        umount "$MOUNTPOINT" >>"$LOGFILE" 2>&1 || true
    done
}

format_ext4() {
    NAME="$1"
    PART="$(resolve_partition "$NAME")"
    log "formatting $NAME ($PART) as ext4"
    # Match the legacy Samsung ext4 layout: 4 KiB blocks, no 64-bit or
    # metadata_csum features, and 128-byte inodes.
    "$EXT4" -F -t ext4 -b 4096 -I 128 -m 0 \
        -O '^64bit,^metadata_csum,^metadata_csum_seed' "$PART" \
        >>"$LOGFILE" 2>&1 || die "failed to format $NAME as ext4"
}

format_f2fs() {
    NAME="$1"
    PART="$(resolve_partition "$NAME")"
    log "formatting $NAME ($PART) as Android F2FS"
    # -g android enables the Android feature profile; these features match
    # the stock M21s userdata superblock (encrypt/quota/verity/casefold).
    "$F2FS" -f -g android -w 4096 "$PART" \
        >>"$LOGFILE" 2>&1 || die "failed to format $NAME as f2fs"
}

log "product=$MODEL/$DEVICE boot=$BOOT_MODEL hw=$BOOT_HARDWARE"
log "super is intentionally not formatted; it is a dynamic-partition container"
log "nad_fw is intentionally not formatted; it is a raw firmware partition"
unmount_all

# The order leaves userdata last because formatting it destroys all user data
# and the recovery's /data mount depends on it.
format_ext4 prism
format_ext4 optics
format_ext4 omr
format_ext4 cache
format_f2fs userdata

FAILED=0
printf '%s\n' 'status=ok' > "$STATUSFILE"
log "all requested filesystems formatted successfully"
exit 0
