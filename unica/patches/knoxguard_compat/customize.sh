#!/usr/bin/env bash

# The S947B Android 17 framework contains KnoxGuard 3.0 (AIDL).  The y2s and
# y2slte hardware stack is G985F/G986B and only supplies the target's legacy
# VaultKeeper HIDL 2.0 path; its kernel has no kg_drv interface.  Producing a
# mixed image makes Keyguard enter KNOXGUARD with kg.state=Error.  Stop the
# build instead of silently creating an image that can lock the device.

if [[ "$TARGET_PLATFORM" != "exynos990" ]]; then
    return 0
fi

case "$SOURCE_FIRMWARE" in
    SM-S947B/*)
        ;;
    *)
        return 0
        ;;
esac

KG30_FILES=(
    "$WORK_DIR/vendor/bin/hw/vendor.samsung.hardware.kg30-service"
    "$WORK_DIR/vendor/lib64/vendor.samsung.hardware.kg30-V1-ndk.so"
    "$WORK_DIR/vendor/etc/init/vendor.samsung.hardware.kg30-service.rc"
    "$WORK_DIR/vendor/etc/vintf/manifest/vendor.samsung.hardware.kg30-manifest.xml"
)

KG30_MISSING=()
for KG30_FILE in "${KG30_FILES[@]}"; do
    [ -f "$KG30_FILE" ] || KG30_MISSING+=("/${KG30_FILE#$WORK_DIR/}")
done

if [ "${#KG30_MISSING[@]}" -gt 0 ]; then
    ABORT "Refusing S947B KG30 framework on $TARGET_CODENAME: target vendor/kernel lacks the KG30 stack (${KG30_MISSING[*]}). Use a matching G985F/G986B system/vendor/kernel set; do not disable KnoxGuard to bypass this check."
    return 1
fi

# A KG30 service is not sufficient by itself.  The donor policy must expose
# its service type; otherwise system_server receives an SELinux denial and the
# same lock state is triggered.  Validate the final policy before packaging.
KG30_SERVICE_CONTEXTS="$WORK_DIR/vendor/etc/selinux/vendor_service_contexts"
if ! grep -q 'vendor\.samsung\.hardware\.kg30\.ISehKg30/default' \
        "$KG30_SERVICE_CONTEXTS" 2>/dev/null; then
    ABORT "Refusing incomplete KG30 stack: vendor service context for ISehKg30/default is missing"
    return 1
fi

LOG "- KG30 service and SELinux registration are present; keeping KnoxGuard security path coherent"
unset KG30_FILE KG30_FILES KG30_MISSING KG30_SERVICE_CONTEXTS
