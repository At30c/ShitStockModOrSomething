#!/usr/bin/env bash
# VaultKeeper AIDL front-end for the Exynos 990.
#
# The Android 17 (S947B) system talks to VaultKeeper through the AIDL
# interface vendor.samsung.hardware.security.vaultkeeper.ISehVaultKeeper
# (libvkmanager.so, libvkjni.so, /system/bin/scs, the Bluetooth APEX). The y2s
# vendor only serves the HIDL 2.0 interface, so those clients could not reach
# it (missing Activated ID / original CSC, Bluetooth link errors).
#
# Only the S26+ AIDL service binary and its NDK interface library are taken.
# The service forwards every call through libvkmanager_vendor.so to the stock
# vaultkeeperd, TEEgris TA and /efs/vk; those stay the y2s ones, because the
# S26+ TA is built for a different TEE and the vault data must not change
# format. Checked against the y2s vendor: every VaultKeeperManager symbol the
# service imports is exported by the y2s libvkmanager_vendor.so, the vendor
# and system V1-ndk libraries carry the same interface hash, libbinder_ndk is
# LLNDK, and the VNDK 30 libbase/libutils/libbinder/libhidlbase provide the
# rest. The HIDL 2.0 service keeps running beside it.

SKIPUNZIP=1

if [[ "$TARGET_CODENAME" != "y2s" && "$TARGET_CODENAME" != "y2slte" ]]; then
    LOG "- VaultKeeper AIDL front-end is limited to y2s/y2slte; skipping target"
    return 0
fi

VK_AIDL_SERVICE="bin/vendor.samsung.hardware.security.vaultkeeper-service"
VK_AIDL_NDK="lib64/vendor.samsung.hardware.security.vaultkeeper-V1-ndk.so"
VK_AIDL_RC="etc/init/vendor.samsung.hardware.security.vaultkeeper-service.rc"
VK_AIDL_VINTF="etc/vintf/manifest/vendor.samsung.hardware.security.vaultkeeper-manifest.xml"
VK_AIDL_INSTANCE="vendor.samsung.hardware.security.vaultkeeper.ISehVaultKeeper/default"

VK_DONOR=""
for CANDIDATE in \
        "$FW_DIR/$(cut -d "/" -f 1 -s <<< "$SOURCE_FIRMWARE")_$(cut -d "/" -f 2 -s <<< "$SOURCE_FIRMWARE")" \
        "$FW_DIR/SM-S947B_EUX"; do
    if [ -f "$CANDIDATE/vendor/$VK_AIDL_SERVICE" ] && [ -f "$CANDIDATE/vendor/$VK_AIDL_NDK" ]; then
        VK_DONOR="$CANDIDATE"
        break
    fi
done
if [ ! "$VK_DONOR" ]; then
    ABORT "No VaultKeeper AIDL donor (vendor/$VK_AIDL_SERVICE) was found"
    return 1
fi

# The front-end only works over the stock backend it was checked against.
for VK_FILE in \
        "bin/vaultkeeperd" \
        "bin/vendor.samsung.hardware.security.vaultkeeper@2.0-service" \
        "lib64/libvkmanager_vendor.so" \
        "etc/init/vaultkeeper_common.rc"; do
    if [ ! -f "$WORK_DIR/vendor/$VK_FILE" ]; then
        ABORT "Stock VaultKeeper backend file is missing: /vendor/$VK_FILE"
        return 1
    fi
done
VK_MISSING_SYMBOLS="$(LC_ALL=C comm -23 \
    <(nm -D --undefined-only "$VK_DONOR/vendor/$VK_AIDL_SERVICE" | awk '{print $2}' | grep VaultKeeperManager | LC_ALL=C sort -u) \
    <(nm -D --defined-only "$WORK_DIR/vendor/lib64/libvkmanager_vendor.so" | awk '{print $3}' | LC_ALL=C sort -u))"
if [ "$VK_MISSING_SYMBOLS" ]; then
    ABORT "y2s libvkmanager_vendor.so lacks symbols the AIDL service needs: $VK_MISSING_SYMBOLS"
    return 1
fi

LOG "- Adding the VaultKeeper AIDL front-end from ${VK_DONOR#$FW_DIR/}"
# Same exec label as the stock HIDL service: it runs in the vaultkeeperd
# domain, which already reaches /dev/socket/vaultkeeper and is binder-callable
# by system_server, scs, bluetooth, rild and ssud.
ADD_TO_WORK_DIR "$VK_DONOR" "vendor" "$VK_AIDL_SERVICE" \
    0 2000 755 "u:object_r:vaultkeeperd_exec:s0" || return 1
ADD_TO_WORK_DIR "$VK_DONOR" "vendor" "$VK_AIDL_NDK" \
    0 0 644 "u:object_r:vendor_file:s0" || return 1
# The S26+ NDK interface library references std::__1::__libcpp_verbose_abort,
# which the VNDK 30 libc++ in the y2s vendor namespace lacks, so it would fail
# to load. libcomposer3_cxxshim.so (graphics_aidl) exports exactly that symbol
# as a trap, the same terminal behavior libc++ has there.
if nm -D --undefined-only "$WORK_DIR/vendor/$VK_AIDL_NDK" | grep -q " _ZNSt3__122__libcpp_verbose_abortEPKcz$"; then
    if [ ! -f "$WORK_DIR/vendor/lib64/libcomposer3_cxxshim.so" ] || \
            ! nm -D --defined-only "$WORK_DIR/vendor/lib64/libcomposer3_cxxshim.so" \
            | grep -q " _ZNSt3__122__libcpp_verbose_abortEPKcz$"; then
        ABORT "vendor/lib64/libcomposer3_cxxshim.so (graphics_aidl) is required by the VaultKeeper AIDL library"
        return 1
    fi
    if ! patchelf --print-needed "$WORK_DIR/vendor/$VK_AIDL_NDK" | grep -qx "libcomposer3_cxxshim.so"; then
        patchelf --add-needed "libcomposer3_cxxshim.so" "$WORK_DIR/vendor/$VK_AIDL_NDK" || return 1
    fi
fi
ADD_TO_WORK_DIR "$MODPATH" "vendor" "$VK_AIDL_RC" \
    0 0 644 "u:object_r:vendor_configs_file:s0" || return 1
ADD_TO_WORK_DIR "$MODPATH" "vendor" "$VK_AIDL_VINTF" \
    0 0 644 "u:object_r:vendor_configs_file:s0" || return 1

# On-device contexts (restorecon and servicemanager lookups).
VENDOR_FILE_CONTEXTS="$WORK_DIR/vendor/etc/selinux/vendor_file_contexts"
VENDOR_SERVICE_CONTEXTS="$WORK_DIR/vendor/etc/selinux/vendor_service_contexts"
VENDOR_SEPOLICY="$WORK_DIR/vendor/etc/selinux/vendor_sepolicy.cil"

VK_FILE_CONTEXT='/vendor/bin/vendor\.samsung\.hardware\.security\.vaultkeeper-service      u:object_r:vaultkeeperd_exec:s0'
grep -qF 'vaultkeeper-service ' "$VENDOR_FILE_CONTEXTS" 2> /dev/null || \
    grep -qF 'vaultkeeper-service	' "$VENDOR_FILE_CONTEXTS" 2> /dev/null || \
    printf '%s\n' "$VK_FILE_CONTEXT" >> "$VENDOR_FILE_CONTEXTS"

touch "$VENDOR_SERVICE_CONTEXTS"
if ! grep -qF "$VK_AIDL_INSTANCE" "$VENDOR_SERVICE_CONTEXTS"; then
    printf '%s u:object_r:hal_vaultkeeper_service:s0\n' "$VK_AIDL_INSTANCE" >> "$VENDOR_SERVICE_CONTEXTS"
fi

# hal_vaultkeeper_service exists only in the S26+ vendor policy. Platform
# types are named with the vendor's 30.0 mapping suffix. The clients are the
# domains the y2s policy already lets call vaultkeeperd over hwbinder.
VK_SEPOLICY_RULES=(
    "(type hal_vaultkeeper_service)"
    "(roletype object_r hal_vaultkeeper_service)"
    "(typeattributeset service_manager_type (hal_vaultkeeper_service))"
    "(allow vaultkeeperd binder_device_30_0 (chr_file (ioctl read write getattr lock append map open watch watch_reads)))"
    "(allow vaultkeeperd servicemanager_30_0 (binder (call transfer)))"
    "(allow servicemanager_30_0 vaultkeeperd (binder (call transfer)))"
    "(allow servicemanager_30_0 vaultkeeperd (dir (search)))"
    "(allow servicemanager_30_0 vaultkeeperd (file (read open)))"
    "(allow servicemanager_30_0 vaultkeeperd (process (getattr)))"
    "(allow vaultkeeperd hal_vaultkeeper_service (service_manager (add find)))"
)
for VK_CLIENT in system_server_30_0 scs_30_0 bluetooth_30_0 rild ssud_30_0 emservice hal_drk_default; do
    if grep -qF "(allow $VK_CLIENT vaultkeeperd (binder (call" "$VENDOR_SEPOLICY"; then
        VK_SEPOLICY_RULES+=("(allow $VK_CLIENT hal_vaultkeeper_service (service_manager (find)))")
    fi
done
for VK_RULE in "${VK_SEPOLICY_RULES[@]}"; do
    grep -qxF "$VK_RULE" "$VENDOR_SEPOLICY" || printf '%s\n' "$VK_RULE" >> "$VENDOR_SEPOLICY"
done

unset VK_AIDL_SERVICE VK_AIDL_NDK VK_AIDL_RC VK_AIDL_VINTF VK_AIDL_INSTANCE VK_DONOR \
    CANDIDATE VK_FILE VK_MISSING_SYMBOLS VK_FILE_CONTEXT VK_SEPOLICY_RULES VK_CLIENT \
    VK_RULE VENDOR_FILE_CONTEXTS VENDOR_SERVICE_CONTEXTS VENDOR_SEPOLICY
