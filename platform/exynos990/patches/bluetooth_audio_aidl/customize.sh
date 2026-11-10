#!/usr/bin/env bash

SKIPUNZIP=1

# The Android 17 Bluetooth apex first asks for the AIDL provider factory. The
# old y2s vendor only advertises Samsung's HIDL provider, so the apex falls
# back to the legacy audio.primary path and can leave SBC in a permanently
# suspended session. Take only the generic AIDL audio provider from the source
# S26+ vendor. Do not import its Qualcomm HCI service, firmware, or Bluetooth
# transport implementation: y2s keeps its Broadcom HIDL HCI.
SOURCE_CANDIDATES=()
if [ "$SOURCE_FIRMWARE" ]; then
    SOURCE_MODEL="$(cut -d "/" -f 1 <<< "$SOURCE_FIRMWARE")"
    SOURCE_CSC="$(cut -d "/" -f 2 <<< "$SOURCE_FIRMWARE")"
    if [ "$SOURCE_MODEL" ] && [ "$SOURCE_CSC" ]; then
        SOURCE_CANDIDATES+=("$FW_DIR/${SOURCE_MODEL}_${SOURCE_CSC}")
    fi
fi
SOURCE_CANDIDATES+=("$FW_DIR/SM-S947B_EUX")

DONOR=""
for CANDIDATE in "${SOURCE_CANDIDATES[@]}"; do
    [ -d "$CANDIDATE" ] || continue
    if [ -f "$CANDIDATE/vendor/lib64/android.hardware.bluetooth.audio-impl.so" ] && \
       [ -f "$CANDIDATE/vendor/lib64/android.hardware.bluetooth.audio-V5-ndk.so" ] && \
       [ -f "$CANDIDATE/vendor/lib64/libbluetooth_audio_session_aidl.so" ] && \
       [ -f "$CANDIDATE/vendor/etc/vintf/manifest/bluetooth_audio.xml" ]; then
        DONOR="$CANDIDATE"
        break
    fi
done

if [ ! "$DONOR" ]; then
    ABORT "No Android 17 Bluetooth Audio AIDL donor with a complete provider closure was found"
    return 1
fi

LOG "- Importing generic Bluetooth Audio AIDL provider from ${DONOR#$FW_DIR/}"

# These are the provider and its private ABI closure. The two existing
# Samsung HIDL audio interface libraries are retained because
# libbluetooth_audio_session_aidl.so bridges the AIDL session to them.
AIDL_AUDIO_LIBS=(
    "android.hardware.bluetooth.audio-impl.so"
    "android.hardware.bluetooth.audio-V5-ndk.so"
    "libbluetooth_audio_session_aidl.so"
    "android.hardware.audio.common-V4-ndk.so"
    "android.media.audio.common.types-V4-ndk.so"
    "android.hardware.common.fmq-V1-ndk.so"
    "libflatbuffers-cpp.so"
    "libaconfig_storage_read_api_cc.so"
    "server_configurable_flags.so"
)

for LIB in "${AIDL_AUDIO_LIBS[@]}"; do
    [ -f "$DONOR/vendor/lib64/$LIB" ] || {
        ABORT "Bluetooth Audio AIDL dependency is missing from donor: vendor/lib64/$LIB"
        return 1
    }
    ADD_TO_WORK_DIR "$DONOR" "vendor" "lib64/$LIB" \
        0 0 644 "u:object_r:vendor_file:s0" || return 1
done

# The session bridge links against these HIDL interface libraries. Keep the
# target copies when present; import them only for a target whose vendor did
# not already contain the exact SONAMEs.
for LIB in \
    "android.hardware.bluetooth.audio@2.0.so" \
    "android.hardware.bluetooth.audio@2.1.so"; do
    if [ ! -f "$WORK_DIR/vendor/lib64/$LIB" ]; then
        [ -f "$DONOR/vendor/lib64/$LIB" ] || {
            ABORT "Bluetooth Audio HIDL compatibility dependency is missing: vendor/lib64/$LIB"
            return 1
        }
        ADD_TO_WORK_DIR "$DONOR" "vendor" "lib64/$LIB" \
            0 0 644 "u:object_r:vendor_file:s0" || return 1
    fi
done

ADD_TO_WORK_DIR "$MODPATH" "vendor" \
    "etc/vintf/manifest/bluetooth_audio.xml" \
    0 0 644 "u:object_r:vendor_configs_file:s0" || return 1
ADD_TO_WORK_DIR "$MODPATH" "vendor" \
    "etc/bluetooth_audio_policy_configuration.xml" \
    0 0 644 "u:object_r:vendor_configs_file:s0" || return 1

# The software SBC path (persist.bluetooth.a2dp_offload.disabled) is set by
# the miscs module; the provider still exposes offload capabilities for a
# later per-codec test.

unset SOURCE_CANDIDATES SOURCE_MODEL SOURCE_CSC CANDIDATE DONOR LIB AIDL_AUDIO_LIBS
