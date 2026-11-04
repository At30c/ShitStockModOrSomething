# Copyright (c) 2025 Salvo Giangreco
# SPDX-License-Identifier: GPL-3.0-or-later

# UN1CA configuration file for Exynos devices (essi)

# Galaxy S26+ (Exynos 2600) (One UI 9)
# Keep the tested S947B release pinned so framework/display behaviour is
# reproducible instead of silently moving with monthly FUS updates.
SOURCE_FIRMWARE="SM-S947B/EUX/350330051234562"
SOURCE_FIRMWARE_VERSION=""
SOURCE_EXTRA_FIRMWARES=()
SOURCE_PLATFORM_SDK_VERSION=37
# S947B uses Android 17 (platform SDK 37), ships with vendor API 36, and
# exposes the frozen board API level used by its build properties.
SOURCE_PRODUCT_SHIPPING_API_LEVEL=36
SOURCE_BOARD_API_LEVEL=202504
SOURCE_SUPER_GROUP_NAME="group_basic"
# S947B already ships the Android 17 display stack (dynamic resolution and
# native 24/10/30/48/60/80/120-Hz policy). Do not apply y2s resolution/HFR
# compatibility patches on top of it.
SOURCE_USE_NATIVE_DISPLAY_STACK=true
# Current Android 17 Settings/SystemUI use the generic fingerprint feature
# gates and already support optical UDFPS.  Only the legacy HIDL/framework
# sensor mapping still needs conversion when the target is optical.
SOURCE_USE_NATIVE_FINGERPRINT_UI=true
# The current services.jar gates the hardware mDNIe paths through A11yRune.
# Its classes were redesigned, so the old control-flow transplant must not be
# applied after the framework flags have already disabled those paths.
SOURCE_USE_MODERN_MDNIE_SERVICE=true

# SEC Product Feature
# S947B's SemMultiMicManager uses the 08030 record-alive framework contract.
# 08020 was the value from the previous S926B source and is not present in
# classes6.dex of the Android 17 donor.
SOURCE_AUDIO_CONFIG_RECORDALIVE_LIB_VERSION="08030"
SOURCE_AUDIO_SUPPORT_ACH_RINGTONE=true
SOURCE_AUDIO_SUPPORT_DUAL_SPEAKER=true
SOURCE_AUDIO_SUPPORT_VIRTUAL_VIBRATION_SOUND=true
SOURCE_BLUETOOTH_SUPPORT_A2DPSINK_PROFILE=true
SOURCE_BLUETOOTH_SUPPORT_A2DP_SBM=false
SOURCE_BLUETOOTH_SUPPORT_HEAD_SAR_BACKOFF=false
SOURCE_BLUETOOTH_SUPPORT_XLNA_CONTROL=false
SOURCE_CAMERA_SUPPORT_CAMERAX_EXTENSION=true
SOURCE_CAMERA_SUPPORT_CUTOUT_PROTECTION=false
SOURCE_CAMERA_SUPPORT_MASS_APP_FLAVOR=false
SOURCE_CAMERA_SUPPORT_SDK_SERVICE=true
SOURCE_COMMON_CONFIG_MDNIE_MODE="65303"
SOURCE_COMMON_SUPPORT_DYN_RESOLUTION_CONTROL=true
SOURCE_COMMON_SUPPORT_EMBEDDED_SIM=true
SOURCE_COMMON_SUPPORT_HDR_EFFECT=true
SOURCE_DVFSAPP_CONFIG_DVFS_POLICY_FILENAME="dvfs_policy_default"
# The S947B donor's ssrm.jar and floating_feature.xml use the M2S policy
# literal. Keep this in sync with the actual source framework so the DVFS
# patch can replace it with the target y2s policy.
SOURCE_DVFSAPP_CONFIG_SSRM_POLICY_FILENAME="siop_m2s_s5e9965"
SOURCE_FINGERPRINT_CONFIG_SENSOR="google_touch_display_ultrasonic"
SOURCE_LCD_CONFIG_COLOR_WEAKNESS_SOLUTION="3"
SOURCE_LCD_CONFIG_CONTROL_AUTO_BRIGHTNESS="5"
SOURCE_LCD_CONFIG_HFR_DEFAULT_REFRESH_RATE="120"
SOURCE_LCD_CONFIG_HFR_MODE="4"
SOURCE_LCD_CONFIG_HFR_SUPPORTED_REFRESH_RATE="1,60,120"
SOURCE_LCD_CONFIG_HFR_SUPPORTED_REFRESH_RATE_NS="none"
SOURCE_LCD_CONFIG_SEAMLESS_BRT="none"
SOURCE_LCD_CONFIG_SEAMLESS_LUX="none"
SOURCE_LCD_SUPPORT_MDNIE_HW=true
SOURCE_SECURITY_CONFIG_ESE_CHIP_VENDOR="GEMALTO"
# S947B's SecureElement and SemService use the UT8.3U COS identifier.
SOURCE_SECURITY_CONFIG_ESE_COS_NAME="UT8.3U"
# S947B's actual TelephonyFeatures value is entitlement_sa.  The generic
# ESSI template used satellite_carrier, which made the RIL compatibility patch
# search for a string that is not present in this Android 17 framework.
SOURCE_RIL_FEATURES="onebinary entitlement_sa"
SOURCE_RIL_SIM_CONFIG_MULTISIM_TRAYCOUNT="2"
SOURCE_RIL_SUPPORT_WATERPROOF_SIM_TRAY_MSG=true
# S947B's SemWifiInjector and BtmController use the value 3. The generic
# ESSI template used 2, which is absent from the Android 17 source smali.
SOURCE_WLAN_CONFIG_CONNECTION_PERSONALIZATION="3"
SOURCE_WLAN_CONFIG_CPU_CSTATE_DISABLE_THRESHOLD="100"
SOURCE_WLAN_CONFIG_CUSTOM_BACKOFF="none"
# Android 17's getBoosterThresholds() already carries the target-compatible
# 150/100/50 tuple (data/cstate/L1SS). Keep these source values aligned so the
# legacy placeholder patch is not selected for this newer layout.
SOURCE_WLAN_CONFIG_DATA_ACTIVITY_AFFINITY_BOOSTER_THRESHOLD="150"
SOURCE_WLAN_CONFIG_DYNAMIC_SWITCH="0"
SOURCE_WLAN_CONFIG_L1SS_DISABLE_THRESHOLD="50"
SOURCE_WLAN_SUPPORT_80211AX=true
SOURCE_WLAN_SUPPORT_80211AX_6GHZ=false
SOURCE_WLAN_SUPPORT_APE_SERVICE=true
SOURCE_WLAN_SUPPORT_LOWLATENCY=true
SOURCE_WLAN_SUPPORT_MBO=true
SOURCE_WLAN_SUPPORT_MIMO=true
SOURCE_WLAN_SUPPORT_MOBILEAP_11AX=true
SOURCE_WLAN_SUPPORT_MOBILEAP_5G_BASEDON_COUNTRY=true
SOURCE_WLAN_SUPPORT_MOBILEAP_6G=true
SOURCE_WLAN_SUPPORT_MOBILEAP_DUALAP=true
SOURCE_WLAN_SUPPORT_MOBILEAP_OWE=true
SOURCE_WLAN_SUPPORT_MOBILEAP_POWER_SAVEMODE=true
SOURCE_WLAN_SUPPORT_MOBILEAP_PRIORITIZE_TRAFFIC=true
SOURCE_WLAN_SUPPORT_MOBILEAP_WIFI_CONCURRENCY=true
SOURCE_WLAN_SUPPORT_MOBILEAP_WIFISHARING_LITE=false
SOURCE_WLAN_SUPPORT_SWITCH_FOR_INDIVIDUAL_APPS=true
# S947B's Android 17 WifiDriverFeatureProvider does not add feature ID 2
# (TWT) to its default feature map, so TWT is already unavailable in source.
SOURCE_WLAN_SUPPORT_TWT_CONTROL=false
SOURCE_WLAN_SUPPORT_WIFI_TO_CELLULAR=true
