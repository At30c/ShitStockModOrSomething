# M21s S20+ vibrator test

`build.sh` creates `out/target/m21s/m21s-vibrator-s20-test.zip` from the pinned
`out/fw/SM-G986B_AUT` firmware. The TWRP installer mounts `/vendor`, remounts
it read-write, backs up every replaced file under `/sdcard`, installs the S20+
vendor vibrator service and 64-bit HIDL dependencies, restores labels, and
verifies the written files.

This is a reversible hardware/HIDL test. It does not replace Android's system
`libvibrator`/`libvibratorservice` or add the Android 17 AIDL vibrator HAL.
