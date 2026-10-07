# Copyright (c) 2026 At30c
# SPDX-License-Identifier: GPL-3.0-or-later

# Platform configuration for Samsung Exynos 9611 targets.
# The S24+ ESSI source is still used for the system/framework side; the
# target firmware supplies the Exynos 9611 vendor and partition layout.
# The F415F/M21s stock vendor reports ro.vndk.version=31 and its bundled
# com.android.vndk.current.apex has the internal name com.android.vndk.v31.
# Keep the framework compatibility layer aligned with that vendor ABI.
TARGET_BOARD_API_LEVEL=31
TARGET_PRODUCT_SHIPPING_API_LEVEL=29

TARGET_USE_DYNAMIC_PARTITIONS=true
TARGET_SUPER_GROUP_NAME="group_basic"
# package_extract_file() writes to a path; recovery mount aliases such as
# /boot and /dtbo are not raw partitions.  Keep generated OTAs tied to the
# canonical block device directory used by F415F/M21s recovery.
TARGET_OS_BOOT_DEVICE_PATH="/dev/block/by-name"
TARGET_OS_SINGLE_SYSTEM_IMAGE="essi"
TARGET_OS_BUILD_SYSTEM_EXT_PARTITION=false
# The M21s test target uses ext4 for all logical OS partitions.  The kernel
# enables both ext4 and EROFS, but keeping the build type aligned with the
# first-stage fstab allows direct edits to the mounted test filesystems.
TARGET_OS_FILE_SYSTEM_TYPE="ext4"

# Universal9611 devices do not expose the Exynos 990-specific hardware
# feature set. These defaults are intentionally conservative and can be
# refined after extracting the F415F target floating_features.xml.
TARGET_BLUETOOTH_SUPPORT_A2DPSINK_PROFILE=true
TARGET_BLUETOOTH_SUPPORT_A2DP_SBM=false
TARGET_BLUETOOTH_SUPPORT_HEAD_SAR_BACKOFF=false
TARGET_BLUETOOTH_SUPPORT_XLNA_CONTROL=false
TARGET_WLAN_CONFIG_CONNECTION_PERSONALIZATION="0"
TARGET_WLAN_CONFIG_CPU_CSTATE_DISABLE_THRESHOLD="100"
TARGET_WLAN_CONFIG_DATA_ACTIVITY_AFFINITY_BOOSTER_THRESHOLD="0"
TARGET_WLAN_CONFIG_DYNAMIC_SWITCH="0"
TARGET_WLAN_CONFIG_L1SS_DISABLE_THRESHOLD="0"
TARGET_WLAN_SUPPORT_80211AX=false
TARGET_WLAN_SUPPORT_80211AX_6GHZ=false
TARGET_WLAN_SUPPORT_APE_SERVICE=false
TARGET_WLAN_SUPPORT_LOWLATENCY=true
TARGET_WLAN_SUPPORT_MBO=true
TARGET_WLAN_SUPPORT_MIMO=true
TARGET_WLAN_SUPPORT_MOBILEAP_11AX=false
TARGET_WLAN_SUPPORT_MOBILEAP_5G_BASEDON_COUNTRY=false
TARGET_WLAN_SUPPORT_MOBILEAP_6G=false
TARGET_WLAN_SUPPORT_MOBILEAP_DUALAP=false
TARGET_WLAN_SUPPORT_MOBILEAP_OWE=false
TARGET_WLAN_SUPPORT_MOBILEAP_POWER_SAVEMODE=true
TARGET_WLAN_SUPPORT_MOBILEAP_PRIORITIZE_TRAFFIC=true
TARGET_WLAN_SUPPORT_MOBILEAP_WIFI_CONCURRENCY=true
TARGET_WLAN_SUPPORT_MOBILEAP_WIFISHARING_LITE=false
TARGET_WLAN_SUPPORT_SWITCH_FOR_INDIVIDUAL_APPS=true
TARGET_WLAN_SUPPORT_TWT_CONTROL=false
TARGET_WLAN_SUPPORT_WIFI_TO_CELLULAR=true
