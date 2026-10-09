LOG_STEP_IN "- Updating Vibrator/RIL/Face/WPA HALs"

# The S20+ targets use the r11s AIDL vibrator payload.  Other Exynos 990
# targets keep the older p3sxxx payload.  The r11s dump is incomplete until
# its V2 platform interface library is supplied; fail before installing a
# service that cannot be loaded by the vendor linker.
VIBRATOR_DONOR="p3sxxx"
VIBRATOR_IMPL="lib64/vendor.samsung.hardware.vibrator-V3-ndk_platform.so"
VIBRATOR_CORE=""
USE_R11S_VIBRATOR=false
if [[ "$TARGET_CODENAME" == "y2s" || "$TARGET_CODENAME" == "y2slte" || "$TARGET_CODENAME" == "r11s" ]]; then
    USE_R11S_VIBRATOR=true
    VIBRATOR_DONOR="r11sxxx"
    VIBRATOR_IMPL="lib64/vendor.samsung.hardware.vibrator-V5-ndk_platform.so"
    VIBRATOR_CORE="lib64/android.hardware.vibrator-V2-ndk_platform.so"
    if [[ ! -f "$SRC_DIR/prebuilts/samsung/$VIBRATOR_DONOR/vendor/$VIBRATOR_CORE" ]]; then
        ABORT "r11s vibrator donor is incomplete: missing vendor/$VIBRATOR_CORE"
    fi
fi

# Delete hermes to get rid of weaver encryption blobs
BLOBS_LIST="
bin/hw/vendor.samsung.hardware.vibrator@2.2-service
etc/init/vendor.samsung.hardware.vibrator@2.2-service.rc
lib64/vendor.samsung.hardware.vibrator@2.0.so
lib64/vendor.samsung.hardware.vibrator@2.1.so
lib64/vendor.samsung.hardware.vibrator@2.2.so
bin/hw/vendor.samsung.hardware.vibrator-service
etc/init/vendor.samsung.hardware.vibrator-default.rc
etc/vintf/manifest/vendor.samsung.hardware.vibrator-default.xml
lib64/android.hardware.vibrator-V1-ndk_platform.so
lib64/android.hardware.vibrator-V2-ndk_platform.so
lib64/vendor.samsung.hardware.vibrator-V3-ndk_platform.so
lib64/vendor.samsung.hardware.vibrator-V5-ndk_platform.so
bin/hw/vendor.samsung.hardware.biometrics.face@2.0-service
etc/init/vendor.samsung.hardware.biometrics.face@2.0-service.rc
bin/hermesd
etc/init/hermesd.rc
lib/liboemcrypto.so
"
for blob in $BLOBS_LIST
do
    DELETE_FROM_WORK_DIR "vendor" "$blob"
done

ADD_TO_WORK_DIR "p3sxxx" "vendor" "bin/hw/vendor.samsung.hardware.biometrics.face@3.0-service"
ADD_TO_WORK_DIR "$VIBRATOR_DONOR" "vendor" \
    "bin/hw/vendor.samsung.hardware.vibrator-service" \
    0 2000 755 "u:object_r:hal_vibrator_default_exec:s0"
# Keep the existing non-audio p3s HAL support explicit.  Do not copy the
# whole directory: p3sxxx also contains the experimental audio @6.0 blobs,
# which are handled later by platform/exynos990/patches/p3s_audio_hal.
P3S_VENDOR_LIBS="
lib64/android.hardware.light-V1-ndk_platform.so
lib64/vendor.samsung.hardware.light-V1-ndk_platform.so
lib64/vendor.samsung.hardware.biometrics.face@2.0.so
lib64/vendor.samsung.hardware.biometrics.face@3.0.so
lib64/uwb_uci.hal.so
"
for blob in $P3S_VENDOR_LIBS; do
    ADD_TO_WORK_DIR "p3sxxx" "vendor" "$blob" \
        0 0 644 "u:object_r:vendor_file:s0"
done
if $USE_R11S_VIBRATOR; then
    ADD_TO_WORK_DIR "$VIBRATOR_DONOR" "vendor" \
        "etc/init/vendor.samsung.hardware.vibrator-default.rc" \
        0 0 644 "u:object_r:vendor_configs_file:s0"
else
    ADD_TO_WORK_DIR "p3sxxx" "vendor" "etc/init"
fi
ADD_TO_WORK_DIR "$VIBRATOR_DONOR" "vendor" \
    "etc/vintf/manifest/vendor.samsung.hardware.vibrator-default.xml" \
    0 0 644 "u:object_r:vendor_configs_file:s0"

if [[ "$VIBRATOR_CORE" ]]; then
    ADD_TO_WORK_DIR "$VIBRATOR_DONOR" "vendor" "$VIBRATOR_CORE" \
        0 0 644 "u:object_r:vendor_file:s0"
fi
ADD_TO_WORK_DIR "$VIBRATOR_DONOR" "vendor" "$VIBRATOR_IMPL" \
    0 0 644 "u:object_r:vendor_file:s0"

# WPA Supplicant HAL
if [[ "$TARGET_CODENAME" != "r8s" ]]; then
    ADD_TO_WORK_DIR "p3sxxx" "vendor" "bin/hw/wpa_supplicant"
fi

# Light HAL
if [[ "$TARGET_CODENAME" != "r8s" ]]; then
    ADD_TO_WORK_DIR "p3sxxx" "vendor" "bin/hw/vendor.samsung.hardware.light-service"
    ADD_TO_WORK_DIR "p3sxxx" "vendor" "lib64/android.hardware.light-V1-ndk_platform.so"
    ADD_TO_WORK_DIR "p3sxxx" "vendor" "lib64/vendor.samsung.hardware.light-V1-ndk_platform.so"
else
    ADD_TO_WORK_DIR "a73xqxx" "vendor" "bin/hw/vendor.samsung.hardware.light-service"
    ADD_TO_WORK_DIR "a73xqxx" "vendor" "lib64/android.hardware.light-V1-ndk_platform.so"
    ADD_TO_WORK_DIR "a73xqxx" "vendor" "lib64/vendor.samsung.hardware.light-V1-ndk_platform.so"
fi
LOG_STEP_OUT
unset BLOBS_LIST P3S_VENDOR_LIBS VIBRATOR_DONOR VIBRATOR_IMPL VIBRATOR_CORE USE_R11S_VIBRATOR blob
