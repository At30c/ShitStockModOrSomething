# Samsung Galaxy S20+ 5G (Exynos) sysinput prebuilt

- Device: Samsung Galaxy S20+ 5G (Exynos)
- Model: `SM-G986B`
- Codename: `y2s`
- Region/source: `AUT`
- Firmware source: `G986BXXSNHYB1/G986BOXMNHYB1/G986BXXSNHYB1`

This directory contains the HIDL 1.3 sysinput userspace chain consumed by the
M21s Android 17 compatibility module and the optional vibrator donor used by
the standalone M21s test installer:

- `vendor/bin/hw/vendor.samsung.hardware.sysinput@1.3-service`
- `vendor/etc/init/vendor.samsung.hardware.sysinput@1.3-service.rc`
- `vendor/etc/vintf/sysinput-hidl-1.3.xml`
- `vendor/lib64/vendor.samsung.hardware.sysinput@1.0.so` through `@1.3.so`


## Vibrator donor

The same pinned `SM-G986B`/`AUT` donor also supplies the optional M21s S20+
vibrator test module. The test consumes only the following service and HIDL
interface files; it does not replace the M21s proprietary
`vendor/lib64/hw/vibrator.default.so`:

- `vendor/bin/hw/vendor.samsung.hardware.vibrator@2.2-service`
- `vendor/etc/init/vendor.samsung.hardware.vibrator@2.2-service.rc`
- `system/system/lib64/android.hardware.vibrator@1.0.so` through `@1.3.so`
- `vendor/lib64/vendor.samsung.hardware.vibrator@2.0.so` through `@2.2.so`

The donor is pinned from `out/fw/SM-G986B_AUT`; hashes are recorded in
`vibrator_s20_test/build.sh` output when the test ZIP is generated.
