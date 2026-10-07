#!/sbin/sh
# Copyright (c) 2026 At30c
# SPDX-License-Identifier: GPL-3.0-or-later
#
# TWRP's edify unmount() aborts when a partition is not present in
# recovery.fstab ("No such volume"). M21s recovery does not expose every
# super child as a named volume, and Prism/Optics may be mounted as physical
# volumes, so use the actual mount table instead.
# Missing mounts are harmless; a real failure while a mount exists is fatal.

set -u

MOUNTPOINTS="/prism /optics /odm /product /system_ext /vendor /system /system_root"

is_mounted()
{
    MOUNTPOINT="$1"

    grep -Fq " $MOUNTPOINT " /proc/mounts 2>/dev/null && return 0
    mountpoint -q "$MOUNTPOINT" 2>/dev/null
}

for MOUNTPOINT in $MOUNTPOINTS; do
    if ! is_mounted "$MOUNTPOINT"; then
        echo "M21s installer: $MOUNTPOINT is not mounted; skipping"
        continue
    fi

    echo "M21s installer: unmounting $MOUNTPOINT"
    if ! umount "$MOUNTPOINT"; then
        echo "M21s installer: failed to unmount mounted path $MOUNTPOINT"
        exit 1
    fi
done

exit 0
