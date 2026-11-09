#!/usr/bin/env bash
# Exynos 990 AIDL graphics chain, applied in dependency order:
#   1. AIDL allocator v2 + Stable-C mapper over the native Gralloc1
#   2. Composer3 AIDL V5 bridge over the stock HWC2 (imports buffers through
#      the mapper installed in step 1)
#   3. graphics allocator lifecycle trace (installed disabled; diagnostic)
# Binaries live in prebuilts/exynos990/graphics_aidl; init fragments and VINTF
# declarations in this module's vendor/ tree.

SKIPUNZIP=1

if [[ "$TARGET_CODENAME" != "y2s" && "$TARGET_CODENAME" != "y2slte" ]]; then
    LOG "- Exynos 990 AIDL graphics chain is limited to y2s/y2slte; skipping target"
    return 0
fi

GRAPHICS_PREBUILT="$SRC_DIR/prebuilts/exynos990/graphics_aidl"
VENDOR_FILE_CONTEXTS="$WORK_DIR/vendor/etc/selinux/vendor_file_contexts"
VENDOR_SERVICE_CONTEXTS="$WORK_DIR/vendor/etc/selinux/vendor_service_contexts"
PLAT_SERVICE_CONTEXTS="$WORK_DIR/system/system/etc/selinux/plat_service_contexts"

INSTALL_ALLOCATOR_AND_MAPPER()
{
    local BRIDGE_COMPAT="lib64/libexynos990_graphics_compat.so"
    local BRIDGE_MAPPER="lib64/hw/mapper.exynos990_compat.so"
    local AIDL_ALLOCATOR_SERVICE="bin/hw/android.hardware.graphics.allocator-V2-service.exynos990"
    local AIDL_ALLOCATOR_RC="etc/init/android.hardware.graphics.allocator-V2-service.exynos990.rc"
    local AIDL_ALLOCATOR_VINTF="etc/vintf/manifest/android.hardware.graphics.allocator-exynos990.xml"
    local BRIDGE_FILE

    # The camera HAL has a private ABI to the stock Exynos 990 mapper.  The
    # compatibility implementation produced by build.sh is test-only and must
    # never replace this file in the vendor image.  Keep the original SONAME
    # and its exact HIDL/Mali lock contract in every production build.
    if [ ! -f "$WORK_DIR/vendor/lib64/libGrallocMapperCamera.so" ]; then
        ABORT "Original vendor/lib64/libGrallocMapperCamera.so is missing; refusing to build the camera path without the stock mapper"
        return 1
    fi
    LOG "- Keeping stock libGrallocMapperCamera.so for the camera HAL"

    # The global AIDL allocator/Stable-C mapper is the default. This migrates
    # framework GraphicBufferAllocator/GraphicBufferMapper clients away from
    # the HIDL path. The immutable Exynos camera HAL still gets the HIDL
    # service as a compatibility endpoint until its direct allocator ABI is
    # adapted; removing that endpoint here would make camera.exynos990.so fail
    # to link or allocate. EXYNOS990_AIDL_GRAPHICS=0 remains an explicit
    # rollback switch.
    local AIDL_GRAPHICS_MODE="${EXYNOS990_AIDL_GRAPHICS:-1}"
    case "$AIDL_GRAPHICS_MODE" in
        0|1) ;;
        *) ABORT "EXYNOS990_AIDL_GRAPHICS must be 0 or 1"; return 1 ;;
    esac

    # Keep the stock HIDL allocator as a narrow compatibility path for
    # immutable vendor HALs (currently camera). Framework clients resolve the
    # AIDL instance. Removing HIDL is a separate step after the camera adapter
    # is shipped.
    local DISABLE_HIDL_ALLOCATOR="${EXYNOS990_DISABLE_HIDL_ALLOCATOR:-0}"
    case "$DISABLE_HIDL_ALLOCATOR" in
        0|1) ;;
        *) ABORT "EXYNOS990_DISABLE_HIDL_ALLOCATOR must be 0 or 1"; return 1 ;;
    esac

    for BRIDGE_FILE in "$BRIDGE_COMPAT" "$BRIDGE_MAPPER"; do
        [ -f "$GRAPHICS_PREBUILT/vendor/$BRIDGE_FILE" ] || {
            ABORT "Graphics prebuilt is missing: prebuilts/exynos990/graphics_aidl/vendor/$BRIDGE_FILE"
            return 1
        }
    done
    ADD_TO_WORK_DIR "$GRAPHICS_PREBUILT" "vendor" "$BRIDGE_COMPAT" \
        0 0 644 "u:object_r:same_process_hal_file:s0" || return 1
    ADD_TO_WORK_DIR "$GRAPHICS_PREBUILT" "vendor" "$BRIDGE_MAPPER" \
        0 0 644 "u:object_r:same_process_hal_file:s0" || return 1

    if [ "$AIDL_GRAPHICS_MODE" = 1 ]; then
        [ -f "$GRAPHICS_PREBUILT/vendor/$AIDL_ALLOCATOR_SERVICE" ] || {
            ABORT "Graphics prebuilt is missing: prebuilts/exynos990/graphics_aidl/vendor/$AIDL_ALLOCATOR_SERVICE"
            return 1
        }
        for BRIDGE_FILE in "$AIDL_ALLOCATOR_RC" "$AIDL_ALLOCATOR_VINTF"; do
            [ -f "$MODPATH/vendor/$BRIDGE_FILE" ] || {
                ABORT "Graphics allocator metadata is missing: vendor/$BRIDGE_FILE"
                return 1
            }
        done
        # Register allocator v2 globally. GraphicBufferMapper then resolves
        # the Stable-C suffix returned by IAllocator instead of entering the
        # old HIDL allocator/mapper path. Keep the old service available for
        # legacy clients, but do not start a second allocator service for the
        # same instance.
        ADD_TO_WORK_DIR "$GRAPHICS_PREBUILT" "vendor" "$AIDL_ALLOCATOR_SERVICE" \
            0 2000 755 "u:object_r:hal_graphics_allocator_default_exec:s0" || return 1
        ADD_TO_WORK_DIR "$MODPATH" "vendor" "$AIDL_ALLOCATOR_RC" \
            0 0 644 "u:object_r:vendor_configs_file:s0" || return 1
        ADD_TO_WORK_DIR "$MODPATH" "vendor" "$AIDL_ALLOCATOR_VINTF" \
            0 0 644 "u:object_r:vendor_configs_file:s0" || return 1

        # The stock HIDL allocator remains available because the current
        # Android 17 framework still requests IAllocator@2.0. An exclusive
        # AIDL experiment may opt out explicitly.
        if [ "$DISABLE_HIDL_ALLOCATOR" = 1 ]; then
            # Never remove the compatibility service while a framework or
            # vendor client still calls the HIDL allocator/mapper directly.
            local HIDL_AUDIT="$MODPATH/audit_hidl_retirement.sh"
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
        # Reapply the proven camera isolation fix. These files may be present
        # in a donor vendor or in an incremental work directory from the old
        # global experiment; remove them before the vendor image is generated.
        DELETE_FROM_WORK_DIR "vendor" "$AIDL_ALLOCATOR_SERVICE" || return 1
        DELETE_FROM_WORK_DIR "vendor" "$AIDL_ALLOCATOR_RC" || return 1
        DELETE_FROM_WORK_DIR "vendor" "$AIDL_ALLOCATOR_VINTF" || return 1
    fi

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
        # context table.  Keeping this entry in plat_service_contexts is wrong
        # on this Android 17 target: it can be ignored by servicemanager's
        # vendor HAL lookup, leaving the name as default_android_service and
        # causing the surfaceflinger `find` denial seen in logcat.
        mkdir -p "$(dirname "$VENDOR_SERVICE_CONTEXTS")"
        touch "$VENDOR_SERVICE_CONTEXTS"
        grep -q -F 'mapper/exynos990_compat' "$VENDOR_SERVICE_CONTEXTS" || \
            echo 'mapper/exynos990_compat u:object_r:hal_graphics_mapper_service:s0' \
                >> "$VENDOR_SERVICE_CONTEXTS"

        # Remove the line emitted by an older incremental run. A duplicate
        # platform/vendor specification makes servicemanager warn and obscures
        # which table is providing the native HAL label.
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
        LOG "- Installed global AIDL allocator v2 + Stable-C mapper over native Exynos 990 Gralloc1"
    else
        LOG "- Installed only the private Stable-C mapper (EXYNOS990_AIDL_GRAPHICS=0 rollback mode)"
    fi
}

INSTALL_COMPOSER3()
{
    local BRIDGE_SERVICE="bin/hw/android.hardware.graphics.composer3-service.exynos990"
    local BRIDGE_LIBRARY="lib64/libexynos990_composer3_contract.so"
    local BRIDGE_RUNTIME_LIBS=(
        "lib64/android.hardware.graphics.composer3-V5-ndk.so"
        "lib64/android.hardware.graphics.common-V7-ndk.so"
        "lib64/android.hardware.common-V2-ndk.so"
        "lib64/android.hardware.drm.common-V1-ndk.so"
        "lib64/libcomposer3_cxxshim.so"
    )
    local BRIDGE_FILE CANDIDATE SYSTEM_LIB_DIR=""

    for BRIDGE_FILE in "$BRIDGE_SERVICE" "$BRIDGE_LIBRARY" "${BRIDGE_RUNTIME_LIBS[@]}"; do
        [ -f "$GRAPHICS_PREBUILT/vendor/$BRIDGE_FILE" ] || {
            ABORT "Composer3 prebuilt is missing: prebuilts/exynos990/graphics_aidl/vendor/$BRIDGE_FILE"
            return 1
        }
    done

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

    # The bridge imports buffers through this mapper privately.  Do not
    # install a Composer3 service against a vendor that registered it globally
    # through the allocator VINTF path: that makes Camera/ImageReader use the
    # compatibility mapper and can abort while creating YUV planes.
    [ -f "$WORK_DIR/vendor/lib64/hw/mapper.exynos990_compat.so" ] || {
        ABORT "Composer3 bridge requires the scoped mapper.exynos990_compat.so installed by the allocator step"
        return 1
    }

    ADD_TO_WORK_DIR "$GRAPHICS_PREBUILT" "vendor" "$BRIDGE_SERVICE" \
        0 2000 755 "u:object_r:hal_graphics_composer_default_exec:s0" || return 1
    ADD_TO_WORK_DIR "$GRAPHICS_PREBUILT" "vendor" "$BRIDGE_LIBRARY" \
        0 0 644 "u:object_r:vendor_file:s0" || return 1
    for BRIDGE_FILE in "${BRIDGE_RUNTIME_LIBS[@]}"; do
        ADD_TO_WORK_DIR "$GRAPHICS_PREBUILT" "vendor" "$BRIDGE_FILE" \
            0 0 644 "u:object_r:vendor_file:s0" || return 1
    done
    for BRIDGE_FILE in \
        "etc/init/android.hardware.graphics.composer3-service.exynos990.rc" \
        "etc/init/android.hardware.graphics.composer@2.3-service.rc" \
        "etc/vintf/manifest/android.hardware.graphics.composer3-exynos990.xml"; do
        ADD_TO_WORK_DIR "$MODPATH" "vendor" "$BRIDGE_FILE" \
            0 0 644 "u:object_r:vendor_configs_file:s0" || return 1
    done

    grep -q -F 'composer3-service\.exynos990' "$VENDOR_FILE_CONTEXTS" || \
        echo '/(vendor|system/vendor)/bin/hw/android\.hardware\.graphics\.composer3-service\.exynos990 u:object_r:hal_graphics_composer_default_exec:s0' \
            >> "$VENDOR_FILE_CONTEXTS"
    grep -q -F 'libexynos990_composer3_contract\.so' "$VENDOR_FILE_CONTEXTS" || \
        echo '/vendor/lib64/libexynos990_composer3_contract\.so u:object_r:vendor_file:s0' \
            >> "$VENDOR_FILE_CONTEXTS"

    # Android 16/17 normally supplies this mapping in plat_service_contexts.
    # Keep a vendor fallback for targets whose split policy omits the
    # platform line.
    if ! grep -q -F 'android.hardware.graphics.composer3.IComposer/default' \
            "$PLAT_SERVICE_CONTEXTS" 2>/dev/null; then
        grep -q -F 'android.hardware.graphics.composer3.IComposer/default' \
            "$VENDOR_SERVICE_CONTEXTS" 2>/dev/null || \
            echo 'android.hardware.graphics.composer3.IComposer/default u:object_r:hal_graphics_composer_service:s0' \
                >> "$VENDOR_SERVICE_CONTEXTS"
    fi

    # Hand the camera preview layers to the bridge's MPP path. Without it the
    # bridge converts every preview frame on the CPU (private 0x11d format ->
    # NV21 -> RGBA, capped by camera_convert_fps), which loads a core and
    # makes the preview stutter. Validated on y2s on 06/11/2026. The value is
    # read once when the Composer3 service starts; a persist override set on
    # the device still wins (setprop ... 0 and reboot to compare).
    SET_PROP "vendor" "persist.vendor.exynos990.camera_mpp" "1" || return 1

    LOG "- Installed Composer3 AIDL V5 bridge over stock Exynos 990 HWC2"
}

INSTALL_ALLOCATOR_TRACE()
{
    local STALE_CONTEXTS

    # A failed/older build may have left the two paths in the generated
    # context file without their SELinux type.  Remove only those stale
    # entries so ADD_TO_WORK_DIR can write the complete path/context pair.
    for STALE_CONTEXTS in \
        "$WORK_DIR/configs/file_context-vendor" \
        "$VENDOR_FILE_CONTEXTS"; do
        if [ -f "$STALE_CONTEXTS" ]; then
            sed -i -E \
                -e '\#^/vendor/bin/graphics_allocator_trace[[:space:]]*$#d' \
                -e '\#^/vendor/etc/init/graphics_allocator_trace\\.rc[[:space:]]*$#d' \
                -e '\#^/(vendor|system/vendor)/bin/graphics_allocator_trace[[:space:]]*$#d' \
                -e '\#^/(vendor|system/vendor)/etc/init/graphics_allocator_trace\\.rc[[:space:]]*$#d' \
                "$STALE_CONTEXTS"
        fi
    done

    # An incremental run may also retain generic 0644 fs_config entries from
    # when the whole vendor/ directory was copied automatically.  Remove only
    # these two records so the explicit modes below are authoritative.
    if [ -f "$WORK_DIR/configs/fs_config-vendor" ]; then
        sed -i -E \
            -e '\#^vendor/bin/graphics_allocator_trace[[:space:]].*$#d' \
            -e '\#^vendor/etc/init/graphics_allocator_trace\.rc[[:space:]].*$#d' \
            "$WORK_DIR/configs/fs_config-vendor"
    fi

    # The service is declared `disabled`: it only runs when started by hand.
    ADD_TO_WORK_DIR "$MODPATH" "vendor" "bin/graphics_allocator_trace" \
        0 0 755 "u:object_r:vendor_shell_exec:s0" || return 1
    ADD_TO_WORK_DIR "$MODPATH" "vendor" "etc/init/graphics_allocator_trace.rc" \
        0 0 644 "u:object_r:vendor_configs_file:s0" || return 1

    grep -q -F 'graphics_allocator_trace' "$VENDOR_FILE_CONTEXTS" || {
        cat >> "$VENDOR_FILE_CONTEXTS" <<'EOF'
/(vendor|system/vendor)/bin/graphics_allocator_trace u:object_r:vendor_shell_exec:s0
/(vendor|system/vendor)/etc/init/graphics_allocator_trace\.rc u:object_r:vendor_configs_file:s0
EOF
    }
}

INSTALL_ALLOCATOR_AND_MAPPER || return 1
INSTALL_COMPOSER3 || return 1
INSTALL_ALLOCATOR_TRACE || return 1

unset -f INSTALL_ALLOCATOR_AND_MAPPER INSTALL_COMPOSER3 INSTALL_ALLOCATOR_TRACE
unset GRAPHICS_PREBUILT VENDOR_FILE_CONTEXTS VENDOR_SERVICE_CONTEXTS PLAT_SERVICE_CONTEXTS
