LOG_STEP_IN "- Fixing EDEN debug logging"

# Remove log.tag.EDEN=INFO from vendor/build.prop
VENDOR_BUILD_PROP="$WORK_DIR/vendor/build.prop"
if [ -f "$VENDOR_BUILD_PROP" ]; then
    LOG "- Removing \"log.tag.EDEN=INFO\" from vendor/build.prop"
    EVAL "sed -i '/^log\.tag\.EDEN=INFO$/d' \"$VENDOR_BUILD_PROP\""
fi

# Remove log.tag.EDEN=INFO from system/system/build.prop
SYSTEM_BUILD_PROP="$WORK_DIR/system/system/build.prop"
if [ -f "$SYSTEM_BUILD_PROP" ]; then
    LOG "- Removing \"log.tag.EDEN=INFO\" from system/system/build.prop"
    EVAL "sed -i '/^log\.tag\.EDEN=INFO$/d' \"$SYSTEM_BUILD_PROP\""
fi

LOG_STEP_OUT

if [[ "$SOURCE_PLATFORM_SDK_VERSION" -ge 37 ]]; then
    LOG_STEP_IN "- Restoring the target EDEN HIDL system bridge"

    # The S24+ source contributes the Android 17 AIDL EDEN stub, while the
    # Exynos 990 vendor service is still
    # vendor.samsung_slsi.hardware.eden_runtime@1.0 (HIDL).  Keeping the
    # source system bridge makes model cleanup call the AIDL interface against
    # a HIDL service and is what produces the eden_runtime SIGSEGV/restart
    # sequence seen in the boot capture.  Restore the three matched target
    # system-side libraries as a unit; do not mix one of them with the source
    # AIDL stub.
    EDEN_SYSTEM_BLOBS="
system/lib64/libeden_nn_on_system.so
system/lib64/libeden_rt_stub.edensdk.samsung.so
system/lib64/vendor.samsung_slsi.hardware.eden_runtime@1.0.so
"
    for blob in $EDEN_SYSTEM_BLOBS; do
        ADD_TO_WORK_DIR "$TARGET_FIRMWARE" "system" "$blob" 0 0 644 "u:object_r:system_lib_file:s0"
    done

    LOG_STEP_OUT
    unset EDEN_SYSTEM_BLOBS
fi

if [[ "$SOURCE_PLATFORM_SDK_VERSION" -ge 37 ]]; then
    LOG_STEP_IN "- Disabling the incompatible EDEN OpenCL backend"

    VENDOR_BUILD_PROP="$WORK_DIR/vendor/build.prop"
    if grep -q '^ro\.vendor\.eden\.devices=CPU1_GPU1_NPU2$' "$VENDOR_BUILD_PROP"; then
        EVAL "sed -i 's/^ro\\.vendor\\.eden\\.devices=CPU1_GPU1_NPU2$/ro.vendor.eden.devices=CPU1_GPU0_NPU2/' \"$VENDOR_BUILD_PROP\""
    elif ! grep -q '^ro\.vendor\.eden\.devices=CPU1_GPU0_NPU2$' "$VENDOR_BUILD_PROP"; then
        ABORT "Unexpected ro.vendor.eden.devices value for the Exynos 990 Android 17 target"
    fi

    # Object detection uses the NPU for its networks, but its legacy model also
    # creates an OpenCL custom operation. With the current Android 17 graphics
    # stack that operation executes correctly and then crashes in
    # GpuUserDriver::CloseModel()/UDModel::~UDModel during camera teardown.
    # Keep EDEN CPU/NPU available and prevent only the unsafe GPU backend from
    # being advertised to the runtime.
    LOG "- EDEN devices: CPU1_GPU0_NPU2"

    LOG_STEP_OUT
    unset VENDOR_BUILD_PROP
fi

# vplUnload() is kept intact.  The no-op patch (patch_libvpl_unload.py, from
# an Exynos 2100 port) left the camera provider's EDEN/NPU session open after
# the camera closed: npu_run_wlock stayed held (20+ min after one camera use),
# the NPU stayed powered and the device could not suspend.  The teardown crash
# it worked around came from the EDEN OpenCL backend, which is disabled above
# (CPU1_GPU0_NPU2); with the stock vplUnload() the NPU is released on every
# camera close (photo/video cycles validated on y2s, 03/11/2026).  Set
# EXYNOS990_PATCH_VPL_UNLOAD=true only to reproduce the old behaviour.
if [[ "${EXYNOS990_PATCH_VPL_UNLOAD:-false}" == "true" ]]; then
    LOG_STEP_IN "- Patching libvpl.so (64-bit only)"

    LIBVPL_64="$WORK_DIR/vendor/lib64/libvpl.so"
    PATCH_SCRIPT="$SRC_DIR/platform/exynos990/patches/eden/patch_libvpl_unload.py"

    if [ ! -f "$PATCH_SCRIPT" ]; then
        ABORT "patch_libvpl_unload.py not found: ${PATCH_SCRIPT//$SRC_DIR\//}"
    fi

    if [ ! -f "$LIBVPL_64" ]; then
        LOG "\033[0;33m! vendor/lib64/libvpl.so not found, skipping...\033[0m"
    else
        LOG "- Patching vendor/lib64/libvpl.so (vplUnload → immediate return)"
        EVAL "python3 \"$PATCH_SCRIPT\" \"$LIBVPL_64\""
    fi

    LOG_STEP_OUT
fi
