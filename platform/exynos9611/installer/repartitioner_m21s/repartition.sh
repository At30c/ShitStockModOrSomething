#!/sbin/sh
#
# Experimental repartitioner for Galaxy M21s / Galaxy F41 (SM-F415F).
#
# Original work: universal repartitioner for Exynos 7870 by @Astrako.
# This package is adapted from the A21s/Exynos 850 repartitioner supplied in
# repartitioner_A21s_Exinos850-v2024.05; the original credits are retained.
# Adaptation for the Exynos 9611 F415F target: At30c, 2026.
#
# WARNING: this rewrites the device GPT and destroys userdata. It is a
# temporary test package for the 64-GB F415F/ZTO layout. Do not flash it on
# A21s, M21, another F415F storage variant, or any other model. Keep a full
# stock firmware/PIT available before running it.

set -u

# The default M21s ext4 build uses the 11305-MiB super layout. The builder may
# inject a larger value into the packaged copy if the ext4 image set grows.
SUPERSIZE_MIB=11305
PRISM_SIZE_MIB=1024
OPTICS_SIZE_MIB=33
CACHE_SIZE_MIB=200
OMR_SIZE_MIB=3

SGDISK=""
DISK=""
BACKUP="/tmp/m21s-gpt-backup.bin"
LOGFILE="/tmp/m21s-repartitioner.log"
STATUSFILE="/tmp/m21s-repartitioner.status"
FAILED=1

: > "$LOGFILE" 2>/dev/null || true
: > "$STATUSFILE" 2>/dev/null || true
printf '%s\n' 'status=running' > "$STATUSFILE" 2>/dev/null || true

log() {
    printf '%s\n' "M21s repartitioner: $*"
    printf '%s\n' "M21s repartitioner: $*" >> "$LOGFILE" 2>/dev/null || true
}

die() {
    log "ERROR: $* (see $LOGFILE)"
    exit 1
}

restore_gpt() {
    if [ -s "$BACKUP" ] && [ "$SGDISK" ] && [ "$DISK" ]; then
        log "restoring the original GPT"
        "$SGDISK" --load-backup="$BACKUP" "$DISK" >>"$LOGFILE" 2>&1 || true
    fi
}

on_exit() {
    if [ "$FAILED" -ne 0 ]; then
        printf '%s\n' 'status=failed' > "$STATUSFILE" 2>/dev/null || true
        restore_gpt
    fi
}
trap on_exit 0

MODEL="$(getprop ro.product.model 2>/dev/null || true)"
DEVICE="$(getprop ro.product.device 2>/dev/null || true)"
BOOT_MODEL="$(getprop ro.boot.em.model 2>/dev/null || true)"
BOOT_DEVICE="$(getprop ro.boot.em.device 2>/dev/null || true)"
BOOT_HARDWARE="$(getprop ro.boot.hardware 2>/dev/null || true)"
case "$MODEL:$DEVICE:$BOOT_MODEL:$BOOT_DEVICE:$BOOT_HARDWARE" in
    SM-F415F:*:*:*:exynos9611|*:f41:*:*:exynos9611|*:f41ns:*:*:exynos9611|*:*:SM-F415F:*:exynos9611) ;;
    *) die "wrong device (product=$MODEL/$DEVICE boot=$BOOT_MODEL/$BOOT_DEVICE hw=$BOOT_HARDWARE); expected SM-F415F/f41 on exynos9611" ;;
esac

for CANDIDATE in /sbin/sgdisk /system/bin/sgdisk /tmp/sgdisk; do
    if [ -x "$CANDIDATE" ] && "$CANDIDATE" --version >>"$LOGFILE" 2>&1; then
        SGDISK="$CANDIDATE"
        break
    fi
done
[ "$SGDISK" ] || die "sgdisk is unavailable or cannot execute in this recovery (missing linker/libs)"

BYNAME=""
for BYNAME_LINK in /dev/block/by-name/super /dev/block/platform/*/by-name/super; do
    [ -e "$BYNAME_LINK" ] || continue
    BYNAME="$(readlink -f "$BYNAME_LINK" 2>/dev/null || true)"
    [ "$BYNAME" ] || BYNAME="$BYNAME_LINK"
    break
done
case "$BYNAME" in
    /dev/block/mmcblk[0-9]p[0-9]*)
        DISK="$(printf '%s\n' "$BYNAME" | sed 's/p[0-9]*$//')" ;;
    /dev/block/sd[a-z][0-9]*)
        DISK="$(printf '%s\n' "$BYNAME" | sed 's/[0-9]*$//')" ;;
    */mmcblk[0-9]p[0-9]*)
        DISK="$(printf '%s\n' "$BYNAME" | sed 's/p[0-9]*$//')" ;;
    */sd[a-z][0-9]*)
        DISK="$(printf '%s\n' "$BYNAME" | sed 's/[0-9]*$//')" ;;
esac
[ "$DISK" ] || {
    for CANDIDATE in /dev/block/sda /dev/block/mmcblk0 /dev/block/mmcblk1; do
        if [ -b "$CANDIDATE" ]; then
            DISK="$CANDIDATE"
            break
        fi
    done
}
[ "$BYNAME" ] || die "super partition link was not found in /dev/block/by-name or /dev/block/platform/*/by-name"
[ -b "$DISK" ] || die "unable to resolve the physical disk for $BYNAME"

unmount_all() {
    for MOUNTPOINT in \
        /system_root/system /system_root /system /vendor /product /odm \
        /prism /optics /cache /omr /data; do
        umount "$MOUNTPOINT" >/dev/null 2>&1 || true
    done
}

TABLE="$("$SGDISK" --print "$DISK" 2>>"$LOGFILE")" || die "cannot read the GPT from $DISK"
PARTNUM() {
    printf '%s\n' "$TABLE" | awk -v wanted="$1" '$NF == wanted { print $1; exit }'
}
PARTSTART() {
    printf '%s\n' "$TABLE" | awk -v wanted="$1" '$NF == wanted { print $2; exit }'
}
PARTEND() {
    printf '%s\n' "$TABLE" | awk -v wanted="$1" '$NF == wanted { print $3; exit }'
}

SUPER_PART="$(PARTNUM super)"
USERDATA_PART="$(PARTNUM userdata)"
PRISM_PART="$(PARTNUM prism)"
OPTICS_PART="$(PARTNUM optics)"
CACHE_PART="$(PARTNUM cache)"
OMR_PART="$(PARTNUM omr)"
CPDEBUG_PART="$(PARTNUM cp_debug)"
SPU_PART="$(PARTNUM spu)"
NADFW_PART="$(PARTNUM nad_fw)"

for REQUIRED in "$SUPER_PART" "$USERDATA_PART" "$PRISM_PART" "$OPTICS_PART" "$CACHE_PART"; do
    [ "$REQUIRED" ] || die "required partition is missing from the F415F GPT"
done

SUPER_START="$(PARTSTART super)"
USERDATA_START="$(PARTSTART userdata)"
[ "$SUPER_START" ] && [ "$USERDATA_START" ] || die "cannot determine partition boundaries"
[ "$SUPER_START" -lt "$USERDATA_START" ] || die "unexpected super/userdata order"

SECTOR_SIZE="$(printf '%s\n' "$TABLE" | awk '
    tolower($0) ~ /sector size/ {
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^[0-9]+(\/[0-9]+)?$/) {
                split($i, sizes, "/")
                print sizes[1]
                exit
            }
        }
    }')"
case "$SECTOR_SIZE" in
    512|4096) ;;
    *) die "unsupported logical sector size: $SECTOR_SIZE" ;;
esac

NADFW_SECTORS=""
if [ "$NADFW_PART" ]; then
    NADFW_START="$(PARTSTART nad_fw)"
    NADFW_END="$(PARTEND nad_fw)"
    [ "$NADFW_START" ] && [ "$NADFW_END" ] || die "cannot determine nad_fw boundaries"
    NADFW_SECTORS=$((NADFW_END - NADFW_START + 1))
    [ "$NADFW_SECTORS" -gt 0 ] || die "invalid nad_fw size"
fi
DISKCODE="$(printf '%s\n' "$TABLE" | awk '
    $NF == "super" {
        for (i = NF - 1; i > 0; i--) {
            if ($i ~ /^[[:xdigit:]][[:xdigit:]][[:xdigit:]][[:xdigit:]]$/) {
                print $i
                exit
            }
        }
    }')"
[ "$DISKCODE" ] || die "cannot determine the super partition type code"

log "product=$MODEL/$DEVICE boot=$BOOT_MODEL/$BOOT_DEVICE hw=$BOOT_HARDWARE disk=$DISK super_link=$BYNAME sgdisk=$SGDISK"
log "super=${SUPERSIZE_MIB}MiB (size supplied by this package)"
log "cache=${CACHE_SIZE_MIB}MiB, prism=${PRISM_SIZE_MIB}MiB, optics=${OPTICS_SIZE_MIB}MiB"
[ "$NADFW_SECTORS" ] && log "preserving nad_fw (${NADFW_SECTORS} sectors)"
log "the next step formats userdata and cache"

unmount_all
"$SGDISK" --backup="$BACKUP" "$DISK" >>"$LOGFILE" 2>&1 || die "cannot back up the original GPT"

delete_partition() {
    [ "$1" ] || return 0
    "$SGDISK" --delete="$1" "$DISK" >>"$LOGFILE" 2>&1 || die "failed to delete GPT entry $1"
}

# These are the same sacrificial entries used by the donor A21s package. They
# are optional on the F415F; no unknown partition is deleted implicitly.
delete_partition "$SUPER_PART"
delete_partition "$PRISM_PART"
delete_partition "$OPTICS_PART"
delete_partition "$CACHE_PART"
delete_partition "$OMR_PART"
delete_partition "$CPDEBUG_PART"
delete_partition "$SPU_PART"
delete_partition "$NADFW_PART"
delete_partition "$USERDATA_PART"

NEXT_START="$SUPER_START"
add_fixed_partition() {
    NAME="$1"
    SIZE_MIB="$2"
    # TWRP's recovery shell may use signed 32-bit arithmetic.  Multiplying
    # Multiplying a large MiB value by 1024*1024 first can overflow before the
    # division by 4096; reduce
    # the conversion factor first so the sector count stays representable.
    BYTES_PER_MIB_IN_SECTORS=$((1024 * 1024 / SECTOR_SIZE))
    [ "$BYTES_PER_MIB_IN_SECTORS" -gt 0 ] || die "invalid sector size conversion"
    SECTORS=$((SIZE_MIB * BYTES_PER_MIB_IN_SECTORS))
    [ "$SECTORS" -gt 0 ] || die "invalid size for $NAME"
    END=$((NEXT_START + SECTORS - 1))
    "$SGDISK" --new=0:"$NEXT_START":"$END" \
        --typecode=0:"$DISKCODE" --change-name=0:"$NAME" "$DISK" \
        >>"$LOGFILE" 2>&1 || die "failed to create $NAME"
    NEXT_START=$((END + 1))
}

add_fixed_partition super "$SUPERSIZE_MIB"
add_fixed_partition prism "$PRISM_SIZE_MIB"
add_fixed_partition optics "$OPTICS_SIZE_MIB"
add_fixed_partition cache "$CACHE_SIZE_MIB"
[ "$OMR_PART" ] && add_fixed_partition omr "$OMR_SIZE_MIB"

add_partition_sectors() {
    NAME="$1"
    SECTORS="$2"
    [ "$SECTORS" -gt 0 ] || die "invalid sector count for $NAME"
    END=$((NEXT_START + SECTORS - 1))
    "$SGDISK" --new=0:"$NEXT_START":"$END" \
        --typecode=0:"$DISKCODE" --change-name=0:"$NAME" "$DISK" \
        >>"$LOGFILE" 2>&1 || die "failed to create $NAME"
    NEXT_START=$((END + 1))
}

# nad_fw is located between super and userdata on the stock F415F table. It
# must be recreated, otherwise the enlarged super would consume it.
[ "$NADFW_SECTORS" ] && add_partition_sectors nad_fw "$NADFW_SECTORS"

# userdata consumes the remaining sectors, as in the original A21s package.
"$SGDISK" --new=0:"$NEXT_START":0 \
    --typecode=0:"$DISKCODE" --change-name=0:userdata "$DISK" \
    >>"$LOGFILE" 2>&1 || die "failed to create userdata"

"$SGDISK" --verify "$DISK" >>"$LOGFILE" 2>&1 || die "GPT verification failed"
NEW_TABLE="$("$SGDISK" --print "$DISK" 2>>"$LOGFILE")" || die "cannot read the new GPT"
for REQUIRED in super prism optics cache userdata; do
    printf '%s\n' "$NEW_TABLE" | awk -v wanted="$REQUIRED" '$NF == wanted { found=1 } END { exit !found }' \
        || die "new GPT is missing $REQUIRED"
done

FAILED=0
printf '%s\n' 'status=ok' > "$STATUSFILE"
log "GPT updated successfully; reboot recovery and format data/cache"
exit 0
