#!/usr/bin/env bash

SKIPUNZIP=1

if [[ "$TARGET_CODENAME" != "y2s" && "$TARGET_CODENAME" != "y2slte" ]]; then
    LOG "- Composer3 HWC2 bridge is limited to y2s/y2slte; skipping target"
    return 0
fi

BRIDGE_ROOT="$SRC_DIR/prebuilts/exynos990/composer3_hwc2_bridge/vendor"
BRIDGE_SERVICE="bin/hw/android.hardware.graphics.composer3-service.exynos990"
BRIDGE_LIBRARY="lib64/libexynos990_composer3_contract.so"
BRIDGE_RUNTIME_LIBS=(
    "lib64/android.hardware.graphics.composer3-V5-ndk.so"
    "lib64/android.hardware.graphics.common-V7-ndk.so"
    "lib64/android.hardware.common-V2-ndk.so"
    "lib64/android.hardware.drm.common-V1-ndk.so"
    "lib64/libcomposer3_cxxshim.so"
)
for BRIDGE_FILE in "$BRIDGE_SERVICE" "$BRIDGE_LIBRARY"; do
    [ -f "$BRIDGE_ROOT/$BRIDGE_FILE" ] || {
        ABORT "Composer3 HWC2 bridge prebuilt is missing: $BRIDGE_FILE"
        return 1
    }
done

SYSTEM_LIB_DIR=""
for CANDIDATE in \
    "$WORK_DIR/system/system/lib64" \
    "$WORK_DIR/system/lib64"; do
    if [ -f "$CANDIDATE/android.hardware.graphics.composer3-V5-ndk.so" ] && \
       [ -f "$CANDIDATE/libbinder_ndk.so" ]; then
        SYSTEM_LIB_DIR="$CANDIDATE"
        break
    fi
done
[ -n "$SYSTEM_LIB_DIR" ] || {
    ABORT "Target system lacks the Composer3 AIDL V5 runtime"
    return 1
}

# The bridge imports buffers through this mapper privately.  Do not install a
# Composer3 service against a vendor that registered it globally through the
# allocator VINTF path: that makes Camera/ImageReader use the compatibility
# mapper and can abort while creating YUV planes.
SCOPED_MAPPER="$WORK_DIR/vendor/lib64/hw/mapper.exynos990_compat.so"
[ -f "$SCOPED_MAPPER" ] || {
    ABORT "Composer3 bridge requires the scoped mapper.exynos990_compat.so; apply graphics_allocator_bridge first"
    return 1
}

ADD_TO_WORK_DIR "$SRC_DIR/prebuilts/exynos990/composer3_hwc2_bridge" "vendor" "$BRIDGE_SERVICE" \
    0 2000 755 "u:object_r:hal_graphics_composer_default_exec:s0" || return 1
ADD_TO_WORK_DIR "$SRC_DIR/prebuilts/exynos990/composer3_hwc2_bridge" "vendor" "$BRIDGE_LIBRARY" \
    0 0 644 "u:object_r:vendor_file:s0" || return 1
for BRIDGE_RUNTIME_LIB in "${BRIDGE_RUNTIME_LIBS[@]}"; do
    [ -f "$BRIDGE_ROOT/$BRIDGE_RUNTIME_LIB" ] || {
        ABORT "Composer3 runtime dependency is missing: $BRIDGE_RUNTIME_LIB"
        return 1
    }
    ADD_TO_WORK_DIR "$SRC_DIR/prebuilts/exynos990/composer3_hwc2_bridge" "vendor" "$BRIDGE_RUNTIME_LIB" \
        0 0 644 "u:object_r:vendor_file:s0" || return 1
done
ADD_TO_WORK_DIR "$MODPATH" "vendor" \
    "etc/init/android.hardware.graphics.composer3-service.exynos990.rc" \
    0 0 644 "u:object_r:vendor_configs_file:s0" || return 1
ADD_TO_WORK_DIR "$MODPATH" "vendor" \
    "etc/init/android.hardware.graphics.composer@2.3-service.rc" \
    0 0 644 "u:object_r:vendor_configs_file:s0" || return 1
ADD_TO_WORK_DIR "$MODPATH" "vendor" \
    "etc/vintf/manifest/android.hardware.graphics.composer3-exynos990.xml" \
    0 0 644 "u:object_r:vendor_configs_file:s0" || return 1

VENDOR_FILE_CONTEXTS="$WORK_DIR/vendor/etc/selinux/vendor_file_contexts"
VENDOR_SERVICE_CONTEXTS="$WORK_DIR/vendor/etc/selinux/vendor_service_contexts"
grep -q -F 'composer3-service\.exynos990' "$VENDOR_FILE_CONTEXTS" || \
    echo '/(vendor|system/vendor)/bin/hw/android\.hardware\.graphics\.composer3-service\.exynos990 u:object_r:hal_graphics_composer_default_exec:s0' \
        >> "$VENDOR_FILE_CONTEXTS"
grep -q -F 'libexynos990_composer3_contract\.so' "$VENDOR_FILE_CONTEXTS" || \
    echo '/vendor/lib64/libexynos990_composer3_contract\.so u:object_r:vendor_file:s0' \
        >> "$VENDOR_FILE_CONTEXTS"

# Android 16/17 normally supplies this mapping in plat_service_contexts. Keep
# a vendor fallback for targets whose split policy omits the platform line.
PLAT_SERVICE_CONTEXTS="$WORK_DIR/system/system/etc/selinux/plat_service_contexts"
if ! grep -q -F 'android.hardware.graphics.composer3.IComposer/default' \
        "$PLAT_SERVICE_CONTEXTS" 2>/dev/null; then
    grep -q -F 'android.hardware.graphics.composer3.IComposer/default' \
        "$VENDOR_SERVICE_CONTEXTS" 2>/dev/null || \
        echo 'android.hardware.graphics.composer3.IComposer/default u:object_r:hal_graphics_composer_service:s0' \
            >> "$VENDOR_SERVICE_CONTEXTS"
fi


LOG "- Installed Composer3 AIDL V5 bridge over stock Exynos 990 HWC2"
unset BRIDGE_ROOT BRIDGE_SERVICE BRIDGE_LIBRARY BRIDGE_RUNTIME_LIBS BRIDGE_RUNTIME_LIB \
    BRIDGE_FILE SYSTEM_LIB_DIR SCOPED_MAPPER VENDOR_FILE_CONTEXTS VENDOR_SERVICE_CONTEXTS \
    PLAT_SERVICE_CONTEXTS CANDIDATE
