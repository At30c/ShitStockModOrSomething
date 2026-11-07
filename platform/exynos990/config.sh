# Copyright (c) 2026 Salvo Giangreco
# SPDX-License-Identifier: GPL-3.0-or-later

# Platform configuration file for Samsung Exynos 990 devices (exynos990)
# The S20 series launched on API 29, but its final vendor image uses VNDK 30.
TARGET_BOARD_API_LEVEL=30
TARGET_PRODUCT_SHIPPING_API_LEVEL=29

# Runtime APEX compatibility variant.  The platform defaults to "source_apex"
# so the S24+ Runtime/I18n/ART APEXes remain untouched.  Set this to "merged"
# only when the legacy r11s ARM32 payload is intentionally required.
EXYNOS990_RUNTIME32_APEX_MODE="${EXYNOS990_RUNTIME32_APEX_MODE:-source_apex}"

# Partitions
# Real size of /dev/block/by-name/boot (blockdev --getsize64 on y2s). avbtool
# pads the signed boot.img to this size, so a larger value makes the image
# overflow the partition and recovery fails with an I/O error.
TARGET_BOOT_PARTITION_SIZE=61865984
TARGET_DTBO_PARTITION_SIZE=8388608
TARGET_DTBO_LTE_PARTITION_SIZE=8388608
TARGET_VENDOR_BOOT_PARTITION_SIZE=67108864
TARGET_CACHE_PARTITION_SIZE=629145600
TARGET_RECOVERY_PARTITION_SIZE=69009408
TARGET_LK3RD_PARTITION_SIZE=2097152

# Dynamic partitions
TARGET_USE_DYNAMIC_PARTITIONS=true
TARGET_SUPER_GROUP_NAME="group_basic"

# OS
# package_extract_file() writes to a path; without this the full ZIP writes
# boot.img/dtbo.img to "/boot" and "/dtbo" in the recovery ramdisk instead of
# the partitions.
TARGET_OS_BOOT_DEVICE_PATH="/dev/block/by-name"
TARGET_OS_SINGLE_SYSTEM_IMAGE="essi"
TARGET_OS_BUILD_SYSTEM_EXT_PARTITION=false

# SEC Product Feature
TARGET_BLUETOOTH_SUPPORT_A2DPSINK_PROFILE=true
TARGET_BLUETOOTH_SUPPORT_A2DP_SBM=true
TARGET_BLUETOOTH_SUPPORT_HEAD_SAR_BACKOFF=false
TARGET_BLUETOOTH_SUPPORT_XLNA_CONTROL=false
TARGET_WLAN_CONFIG_CONNECTION_PERSONALIZATION="0"
TARGET_WLAN_CONFIG_CPU_CSTATE_DISABLE_THRESHOLD="100"
TARGET_WLAN_CONFIG_DATA_ACTIVITY_AFFINITY_BOOSTER_THRESHOLD="150"
TARGET_WLAN_CONFIG_DYNAMIC_SWITCH="0"
TARGET_WLAN_CONFIG_L1SS_DISABLE_THRESHOLD="50"
TARGET_WLAN_SUPPORT_80211AX=true
TARGET_WLAN_SUPPORT_80211AX_6GHZ=false
TARGET_WLAN_SUPPORT_APE_SERVICE=false
TARGET_WLAN_SUPPORT_LOWLATENCY=true
TARGET_WLAN_SUPPORT_MBO=true
TARGET_WLAN_SUPPORT_MIMO=true
TARGET_WLAN_SUPPORT_MOBILEAP_11AX=true
# One UI 9 Settings only list the 5 GHz hotspot band when
# SemWifiManager.supportWifiAp5GBasedOnCountry() is true; with this flag off
# product_feature stubs it to false and the hotspot is limited to 2.4 GHz.
# The BCM4375 does 5 GHz SoftAP, and the stock check (chip support settings
# plus the 2.4 GHz-only country list) handles the regions that cannot.
TARGET_WLAN_SUPPORT_MOBILEAP_5G_BASEDON_COUNTRY=true
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
