#!/usr/bin/env bash

SKIPUNZIP=1

# stage_vendor_changes.sh is shared with scripts/repack_vendor_dd.sh: it patches
# the service instance name to "exynos0" and writes the .rc and the merged
# sec_c2_manifest_default.xml, so both install paths ship the same files.
C2_STAGE="$(mktemp -d)"
bash "$MODPATH/stage_vendor_changes.sh" "$C2_STAGE" > /dev/null || {
    rm -rf "$C2_STAGE"
    ABORT "A26 Codec2 prebuilt is missing; run codec2_exynos_a26/build.sh"
    return 1
}

ADD_TO_WORK_DIR "$C2_STAGE" "vendor" "bin/hw/samsung.hardware.media.c2@1.2-service" \
    0 2000 755 "u:object_r:mediacodec_exec:s0" || return 1
for C2_LIB in "$C2_STAGE"/vendor/lib64/*.so; do
    ADD_TO_WORK_DIR "$C2_STAGE" "vendor" "lib64/$(basename "$C2_LIB")" \
        0 0 644 "u:object_r:vendor_file:s0" || return 1
done
for C2_FILE in \
    "etc/init/samsung.hardware.media.c2@1.2-service.rc" \
    "etc/vintf/manifest/sec_c2_manifest_default.xml" \
    "etc/media_codecs_c2.xml" \
    "etc/seccomp_policy/codec2.vendor.base.policy" \
    "etc/seccomp_policy/codec2.vendor.ext.policy"; do
    ADD_TO_WORK_DIR "$C2_STAGE" "vendor" "$C2_FILE" \
        0 0 644 "u:object_r:vendor_configs_file:s0" || return 1
done

VENDOR_FILE_CONTEXTS="$WORK_DIR/vendor/etc/selinux/vendor_file_contexts"
grep -q -F 'samsung\.hardware\.media\.c2@1\.2-service' "$VENDOR_FILE_CONTEXTS" || \
    echo '/(vendor|system/vendor)/bin/hw/samsung\.hardware\.media\.c2@1\.2-service u:object_r:mediacodec_exec:s0' \
        >> "$VENDOR_FILE_CONTEXTS"

rm -rf "$C2_STAGE"
LOG "- Installed A26 Exynos Codec2 HAL as IComponentStore/exynos0"
unset C2_STAGE C2_LIB C2_FILE VENDOR_FILE_CONTEXTS
