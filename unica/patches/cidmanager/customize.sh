# The source framework and the target firmware expose the same
# VaultKeeperService Java/JNI contract, but use different native transports.
# Keep the source AIDL manager for APEX clients (notably Bluetooth), and give
# VaultKeeperService a private copy of the target's matching HIDL 2.0 manager.
VK_CURRENT_MANAGER="$WORK_DIR/system/system/lib64/libvkmanager.so"
VK_STACK_MARKER="$WORK_DIR/configs/vaultkeeper_system_stack.path"

IS_VAULTKEEPER_HIDL_2_MANAGER()
{
    local VK_NEEDED

    [ -f "$1" ] || return 1
    while IFS= read -r VK_NEEDED; do
        if [ "$VK_NEEDED" = "vendor.samsung.hardware.security.vaultkeeper@2.0.so" ]; then
            return 0
        fi
    done < <(patchelf --print-needed "$1" 2> /dev/null)

    return 1
}

# /system/bin/scs (exec_start'ed by scs.rc during boot) reads the Activated
# ID from the VaultKeeper "AID" vault and sets ro.boot.activatedid, the
# original CSC shown last in Settings > Software information (ZTO/ZTO,ZTO/ZTO
# /ZTA). It links libvkmanager.so; the AIDL build cannot reach the y2s vendor,
# which only has VaultKeeper HIDL 2.0, so the field disappeared once
# libvkmanager.so went back to the source AIDL build for the Bluetooth APEX.
# Both builds export the same VaultKeeperManager API (scs only imports
# getInstance() and read(int, char*, int*)), so point it at the HIDL copy.
PATCH_SCS_VAULTKEEPER_MANAGER()
{
    local SCS="$WORK_DIR/system/system/bin/scs"

    [ -f "$SCS" ] || return 0
    patchelf --print-needed "$SCS" | grep -qx "libvkmanager.so" || return 0
    LOG "- Linking /system/bin/scs against libvkmanager-hidl.so"
    patchelf --replace-needed "libvkmanager.so" "libvkmanager-hidl.so" "$SCS" || \
        ABORT "Failed to patch /system/bin/scs"
}

if [ -s "$VK_STACK_MARKER" ]; then
    VK_STACK_PATH="$(head -n 1 "$VK_STACK_MARKER")"
    if [ ! -d "$VK_STACK_PATH/system" ]; then
        ABORT "VaultKeeper stack module not found: ${VK_STACK_PATH#$SRC_DIR/}"
    fi

    LOG "- Reapplying the authoritative VaultKeeper stack from ${VK_STACK_PATH#$SRC_DIR/}"
    ADD_TO_WORK_DIR "$VK_STACK_PATH" "system" "." \
        0 0 755 "u:object_r:system_file:s0"

    # The module no longer ships Bluetooth files: the APEX and libbt-iopdb
    # stay the Android 17 source ones (patched by unica/patches/bluetooth).
    for VK_RELATIVE_FILE in \
        "system/lib64/libvkmanager.so" \
        "system/lib64/libvkjni.so" \
        "system/lib64/vendor.samsung.hardware.security.vaultkeeper@2.0.so"; do
        if ! cmp -s \
                "$VK_STACK_PATH/system/$VK_RELATIVE_FILE" \
                "$WORK_DIR/system/$VK_RELATIVE_FILE"; then
            ABORT "VaultKeeper stack file was not installed correctly: /$VK_RELATIVE_FILE"
        fi
    done

    if ! IS_VAULTKEEPER_HIDL_2_MANAGER "$VK_CURRENT_MANAGER"; then
        ABORT "Selected VaultKeeper stack does not provide a HIDL 2.0 libvkmanager.so"
    fi

    # The Android 17 libbluetooth_jni.so links libvkmanager.so and the linker
    # resolves it from /system/lib64. The module's HIDL 2.0 build needs
    # vaultkeeper@2.0.so, which the com_android_bt namespace cannot see, so
    # com.android.bluetooth died with UnsatisfiedLinkError on every enable.
    # Give the module's libvkjni.so a private HIDL manager and put the source
    # AIDL manager back at the public name for the APEX (and /system/bin/scs).
    if ! command -v patchelf > /dev/null 2>&1; then
        ABORT "patchelf is required for VaultKeeper HIDL compatibility"
    fi
    LOG "- Isolating the HIDL 2.0 manager as libvkmanager-hidl.so"
    mv -f "$VK_CURRENT_MANAGER" "$WORK_DIR/system/system/lib64/libvkmanager-hidl.so"
    SET_METADATA "system" "system/lib64/libvkmanager-hidl.so" \
        0 0 644 "u:object_r:system_lib_file:s0"
    patchelf --set-soname "libvkmanager-hidl.so" \
        "$WORK_DIR/system/system/lib64/libvkmanager-hidl.so"
    patchelf --replace-needed "libvkmanager.so" "libvkmanager-hidl.so" \
        "$WORK_DIR/system/system/lib64/libvkjni.so"
    ADD_TO_WORK_DIR "$SOURCE_FIRMWARE" "system" "system/lib64/libvkmanager.so" \
        0 0 644 "u:object_r:system_lib_file:s0"
    PATCH_SCS_VAULTKEEPER_MANAGER

    if IS_VAULTKEEPER_HIDL_2_MANAGER "$VK_CURRENT_MANAGER"; then
        ABORT "libvkmanager.so is still the HIDL 2.0 build"
    fi
    for VK_CLIENT in "lib64/libvkjni.so" "bin/scs"; do
        [ -f "$WORK_DIR/system/system/$VK_CLIENT" ] || continue
        if ! patchelf --print-needed "$WORK_DIR/system/system/$VK_CLIENT" \
                | grep -qx "libvkmanager-hidl.so"; then
            ABORT "/system/$VK_CLIENT does not link libvkmanager-hidl.so"
        fi
    done
    unset VK_CLIENT

    unset VK_CURRENT_MANAGER VK_RELATIVE_FILE VK_STACK_MARKER VK_STACK_PATH
    unset -f IS_VAULTKEEPER_HIDL_2_MANAGER PATCH_SCS_VAULTKEEPER_MANAGER
    return 0
fi

unset VK_CURRENT_MANAGER VK_STACK_MARKER VK_STACK_PATH
unset -f IS_VAULTKEEPER_HIDL_2_MANAGER

VK_DONOR="$TARGET_FIRMWARE"
VK_DONOR_PATH="$(cut -d "/" -f 1 -s <<< "$VK_DONOR")_$(cut -d "/" -f 2 -s <<< "$VK_DONOR")"
VK_TARGET_INTERFACE="$WORK_DIR/vendor/lib64/vendor.samsung.hardware.security.vaultkeeper@2.0.so"
VK_TARGET_DAEMON="$WORK_DIR/vendor/bin/vaultkeeperd"
VK_HIDL_MANAGER="$WORK_DIR/system/system/lib64/libvkmanager-hidl.so"

if [ -f "$VK_TARGET_INTERFACE" ] && [ -f "$VK_TARGET_DAEMON" ]; then
    LOG "- Adding the isolated target VaultKeeper HIDL 2.0 system bridge"

    # Restore the source AIDL manager explicitly when a cached work directory
    # still contains an earlier downgrade experiment.
    ADD_TO_WORK_DIR "$SOURCE_FIRMWARE" "system" "system/lib64/libvkmanager.so" \
        0 0 644 "u:object_r:system_lib_file:s0"

    ADD_TO_WORK_DIR "$VK_DONOR" "system" "system/lib64/vendor.samsung.hardware.security.vaultkeeper@2.0.so" \
        0 0 644 "u:object_r:system_lib_file:s0"
    ADD_TO_WORK_DIR "$VK_DONOR" "system" "system/lib64/libvkjni.so" \
        0 0 644 "u:object_r:system_lib_file:s0"

    cp -a "$FW_DIR/$VK_DONOR_PATH/system/system/lib64/libvkmanager.so" \
        "$VK_HIDL_MANAGER"
    SET_METADATA "system" "system/lib64/libvkmanager-hidl.so" \
        0 0 644 "u:object_r:system_lib_file:s0"

    if ! command -v patchelf > /dev/null 2>&1; then
        LOGE "patchelf is required for VaultKeeper HIDL compatibility"
        return 1
    fi
    patchelf --set-soname 'libvkmanager-hidl.so' "$VK_HIDL_MANAGER"
    patchelf --replace-needed 'libvkmanager.so' 'libvkmanager-hidl.so' \
        "$WORK_DIR/system/system/lib64/libvkjni.so"
    PATCH_SCS_VAULTKEEPER_MANAGER

    # Clean artifacts from the superseded public-library experiment.
    sed -i '\|^vendor\.samsung\.hardware\.security\.vaultkeeper@2\.0\.so 64$|d' \
        "$WORK_DIR/system/system/etc/public.libraries.txt"
else
    LOGW "Legacy VaultKeeper HIDL 2.0 backend not found; keeping source system bridge"
fi

unset VK_DONOR VK_DONOR_PATH VK_TARGET_INTERFACE VK_TARGET_DAEMON VK_HIDL_MANAGER
unset -f PATCH_SCS_VAULTKEEPER_MANAGER
