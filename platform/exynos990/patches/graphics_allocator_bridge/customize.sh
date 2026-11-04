#!/usr/bin/env bash

SKIPUNZIP=1

BRIDGE_ROOT="$MODPATH/prebuilt/vendor"
BRIDGE_COMPAT="lib64/libexynos990_graphics_compat.so"
BRIDGE_MAPPER="lib64/hw/mapper.exynos990_compat.so"
AIDL_ALLOCATOR_SERVICE="bin/hw/android.hardware.graphics.allocator-V2-service.exynos990"
AIDL_ALLOCATOR_RC="etc/init/android.hardware.graphics.allocator-V2-service.exynos990.rc"
AIDL_ALLOCATOR_VINTF="etc/vintf/manifest/android.hardware.graphics.allocator-exynos990.xml"

if [[ "$TARGET_CODENAME" != "y2s" && "$TARGET_CODENAME" != "y2slte" ]]; then
    LOG "- Exynos 990 AIDL graphics bridge is limited to y2s/y2slte; skipping target"
    return 0
fi

# The camera HAL has a private ABI to the stock Exynos 990 mapper.  The
# compatibility implementation produced by build.sh is test-only and must
# never replace this file in the vendor image.  Keep the original SONAME and
# its exact HIDL/Mali lock contract in every production build.
CAMERA_MAPPER="$WORK_DIR/vendor/lib64/libGrallocMapperCamera.so"
if [ ! -f "$CAMERA_MAPPER" ]; then
    ABORT "Original vendor/lib64/libGrallocMapperCamera.so is missing; refusing to build the camera path without the stock mapper"
    return 1
fi
LOG "Keeping stock libGrallocMapperCamera.so for the camera HAL"

# The global AIDL allocator/Stable-C mapper is now the default. This migrates
# framework GraphicBufferAllocator/GraphicBufferMapper clients away from the
# HIDL path. The immutable Exynos camera HAL still gets the HIDL service as a
# compatibility endpoint until its direct allocator ABI is adapted; removing
# that endpoint here would make camera.exynos990.so fail to link or allocate.
# EXYNOS990_AIDL_GRAPHICS=0 remains an explicit rollback switch.
AIDL_GRAPHICS_MODE="${EXYNOS990_AIDL_GRAPHICS:-1}"
case "$AIDL_GRAPHICS_MODE" in
    0|1) ;;
    *) ABORT "EXYNOS990_AIDL_GRAPHICS must be 0 or 1"; return 1 ;;
esac

# Keep the stock HIDL allocator as a narrow compatibility path for immutable
# vendor HALs (currently camera). Framework clients resolve the AIDL instance
# above. Removing HIDL is a separate step after the camera adapter is shipped.
DISABLE_HIDL_ALLOCATOR="${EXYNOS990_DISABLE_HIDL_ALLOCATOR:-0}"
case "$DISABLE_HIDL_ALLOCATOR" in
    0|1) ;;
    *) ABORT "EXYNOS990_DISABLE_HIDL_ALLOCATOR must be 0 or 1"; return 1 ;;
esac

for BRIDGE_FILE in "$BRIDGE_COMPAT" "$BRIDGE_MAPPER"; do
    [ -f "$BRIDGE_ROOT/$BRIDGE_FILE" ] || {
        ABORT "Graphics allocator bridge prebuilt is missing: prebuilt/vendor/$BRIDGE_FILE"
        return 1
    }
done

# The init fragment and VINTF declaration live at the module root because
# ADD_TO_WORK_DIR must read them from the module's vendor/ tree.  Keep this
# check separate from the binary prebuilts above; treating both as if they
# were under prebuilt/vendor made a clean vendor application abort before
# copying anything.
ADD_TO_WORK_DIR "$MODPATH/prebuilt" "vendor" "$BRIDGE_COMPAT" \
    0 0 644 "u:object_r:same_process_hal_file:s0" || return 1
ADD_TO_WORK_DIR "$MODPATH/prebuilt" "vendor" "$BRIDGE_MAPPER" \
    0 0 644 "u:object_r:same_process_hal_file:s0" || return 1

if [ "$AIDL_GRAPHICS_MODE" = 1 ]; then
    for BRIDGE_FILE in "$AIDL_ALLOCATOR_SERVICE"; do
        [ -f "$BRIDGE_ROOT/$BRIDGE_FILE" ] || {
            ABORT "Graphics allocator bridge prebuilt is missing: prebuilt/vendor/$BRIDGE_FILE"
            return 1
        }
    done
    for BRIDGE_FILE in "$AIDL_ALLOCATOR_RC" "$AIDL_ALLOCATOR_VINTF"; do
        [ -f "$MODPATH/vendor/$BRIDGE_FILE" ] || {
            ABORT "Graphics allocator bridge metadata is missing: vendor/$BRIDGE_FILE"
            return 1
        }
    done
    # Register allocator v2 globally. GraphicBufferMapper then resolves the
    # Stable-C suffix returned by IAllocator instead of entering the old HIDL
    # allocator/mapper path. Keep the old service available for legacy clients,
    # but do not start a second allocator service for the same instance.
    ADD_TO_WORK_DIR "$MODPATH/prebuilt" "vendor" "$AIDL_ALLOCATOR_SERVICE" \
        0 2000 755 "u:object_r:hal_graphics_allocator_default_exec:s0" || return 1
    ADD_TO_WORK_DIR "$MODPATH" "vendor" "$AIDL_ALLOCATOR_RC" \
        0 0 644 "u:object_r:vendor_configs_file:s0" || return 1
    ADD_TO_WORK_DIR "$MODPATH" "vendor" "$AIDL_ALLOCATOR_VINTF" \
        0 0 644 "u:object_r:vendor_configs_file:s0" || return 1

    # The stock HIDL allocator remains available because the current Android
    # 17 framework still requests IAllocator@2.0. Its binary and rc are kept
    # as the compatibility path while clients are migrated to AIDL. An
    # exclusive AIDL experiment may opt out explicitly.
    if [ "$DISABLE_HIDL_ALLOCATOR" = 1 ]; then
        # Never remove the compatibility service while a framework or vendor
        # client still calls the HIDL allocator/mapper directly.  This gate
        # turns green only after those clients are migrated or wrapped by a
        # tested ABI adapter.
        HIDL_AUDIT="$MODPATH/audit_hidl_retirement.sh"
        if [ ! -x "$HIDL_AUDIT" ]; then
            ABORT "HIDL retirement audit is missing: $HIDL_AUDIT"
            return 1
        fi
        if ! bash "$HIDL_AUDIT" "$WORK_DIR"; then
            ABORT "Refusing to remove graphics HIDL: direct clients still call allocator/mapper getService()"
            return 1
        fi
        DELETE_FROM_WORK_DIR "vendor" \
            "etc/init/android.hardware.graphics.allocator@2.0-service.rc" || return 1
    fi
else
    # Reapply the proven camera isolation fix. These files may be present in a
    # donor vendor or in an incremental work directory from the old global
    # experiment; remove them before the vendor image is generated.
    DELETE_FROM_WORK_DIR "vendor" "$AIDL_ALLOCATOR_SERVICE" || return 1
    DELETE_FROM_WORK_DIR "vendor" "$AIDL_ALLOCATOR_RC" || return 1
    DELETE_FROM_WORK_DIR "vendor" "$AIDL_ALLOCATOR_VINTF" || return 1
fi

VENDOR_FILE_CONTEXTS="$WORK_DIR/vendor/etc/selinux/vendor_file_contexts"
grep -q -F 'libexynos990_graphics_compat\.so' "$VENDOR_FILE_CONTEXTS" || \
    echo '/vendor/lib(64)?/libexynos990_graphics_compat\.so u:object_r:same_process_hal_file:s0' \
        >> "$VENDOR_FILE_CONTEXTS"
grep -q -F 'mapper\.exynos990_compat\.so' "$VENDOR_FILE_CONTEXTS" || \
    echo '/vendor/lib(64)?/hw/mapper\.exynos990_compat\.so u:object_r:same_process_hal_file:s0' \
        >> "$VENDOR_FILE_CONTEXTS"

if [ "$AIDL_GRAPHICS_MODE" = 1 ]; then
    grep -q -F 'allocator-V2-service\.exynos990' "$VENDOR_FILE_CONTEXTS" || \
        echo '/(vendor|system/vendor)/bin/hw/android\.hardware\.graphics\.allocator-V2-service\.exynos990 u:object_r:hal_graphics_allocator_default_exec:s0' \
            >> "$VENDOR_FILE_CONTEXTS"

    # Native Stable-C passthrough names are resolved by the vendor service
    # context table.  Keeping this entry in plat_service_contexts is wrong on
    # this Android 17 target: it can be ignored by servicemanager's vendor HAL
    # lookup, leaving the name as default_android_service and causing the
    # surfaceflinger `find` denial seen in logcat.
    VENDOR_SERVICE_CONTEXTS="$WORK_DIR/vendor/etc/selinux/vendor_service_contexts"
    mkdir -p "$(dirname "$VENDOR_SERVICE_CONTEXTS")"
    touch "$VENDOR_SERVICE_CONTEXTS"
    grep -q -F 'mapper/exynos990_compat' "$VENDOR_SERVICE_CONTEXTS" || \
        echo 'mapper/exynos990_compat u:object_r:hal_graphics_mapper_service:s0' \
            >> "$VENDOR_SERVICE_CONTEXTS"

    PLAT_SERVICE_CONTEXTS="$WORK_DIR/system/system/etc/selinux/plat_service_contexts"
    # Remove the line emitted by an older incremental run of this module. A
    # duplicate platform/vendor specification makes servicemanager warn and
    # obscures which table is providing the native HAL label.
    if [ -f "$PLAT_SERVICE_CONTEXTS" ]; then
        sed -i '/^[[:space:]]*mapper\/exynos990_compat[[:space:]]/d' \
            "$PLAT_SERVICE_CONTEXTS"
    fi
    if ! grep -q -F 'android.hardware.graphics.allocator.IAllocator/default' \
            "$PLAT_SERVICE_CONTEXTS" 2>/dev/null; then
        grep -q -F 'android.hardware.graphics.allocator.IAllocator/default' \
            "$VENDOR_SERVICE_CONTEXTS" 2>/dev/null || \
            echo 'android.hardware.graphics.allocator.IAllocator/default u:object_r:hal_graphics_allocator_service:s0' \
                >> "$VENDOR_SERVICE_CONTEXTS"
    fi
fi

if [ "$AIDL_GRAPHICS_MODE" = 1 ]; then
    LOG "Installed global AIDL allocator v2 + Stable-C mapper over native Exynos 990 Gralloc1"
else
    LOG "Installed only the private Stable-C mapper (EXYNOS990_AIDL_GRAPHICS=0 rollback mode)"
fi
unset BRIDGE_ROOT BRIDGE_COMPAT BRIDGE_MAPPER BRIDGE_FILE CAMERA_MAPPER AIDL_ALLOCATOR_SERVICE AIDL_ALLOCATOR_RC \
    AIDL_ALLOCATOR_VINTF AIDL_GRAPHICS_MODE DISABLE_HIDL_ALLOCATOR VENDOR_FILE_CONTEXTS \
    VENDOR_SERVICE_CONTEXTS PLAT_SERVICE_CONTEXTS

