# Current One UI 9 Port Handoff Instructions


## M21s camera `camera-feature.xml`: authoritative baseline and state (2026-10-05)

This is the current reference for the M21s camera XML. Everything below supersedes
any earlier ad-hoc edits to `target/m21s/camera/camera-feature.xml`.

### 1. Authoritative baseline

The stock M21s XML is the only trusted starting point:

```
source of truth : target/m21s/camera/reference/camera-feature.stock-m21s.xml
md5             : 8e03c7ca719ea6073e480fccb4d87e15
size            : 16850 bytes
<local> keys    : 173
```

Two immutable reference copies are kept in the repo so `/tmp` cleanup cannot
destroy the baseline:

```
reference/camera-feature.stock-m21s.xml          8e03c7ca719ea6073e480fccb4d87e15
reference/camera-feature.stock-m21s-zoom4000.xml b59c8c15c8a91600d2ca6d5dbea98cec
target/m21s/camera/camera-feature.xml             b59c8c15c8a91600d2ca6d5dbea98cec  (deployed)
```

`unica/patches/camera/customize.sh` copies only the exact filename
`camera-feature.xml`, so the `reference/` directory is inert for the build.

Its resolution values are the ones the M21s sensors were profiled with, and they
are large on purpose:

```
BACK_CAMERA_PICTURE_DEFAULT_RESOLUTION      9248x6936
BACK_CAMERA_RESOLUTION_4BY3_LARGE           9248x6936
BACK_CAMERA_RESOLUTION_4BY3_MEDIUM          9248x6936
BACK_CAMERA_RESOLUTION_SUPER_RESOLUTION     9248x6936
BACK_CAMERA_RESOLUTION_FULL_RATIO           4000x1844
BACK_CAMERA_RESOLUTION_16BY9_LARGE          4000x2252
BACK_CAMERA_RESOLUTION_1BY1_LARGE           3456x3456
FRONT_CAMERA_PICTURE_DEFAULT_RESOLUTION     4000x3000
FRONT_CAMERA_RESOLUTION_4BY3_LARGE          4000x3000
FRONT_CAMERA_RESOLUTION_SUPER_RESOLUTION    4000x3000
FRONT_CAMERA_RESOLUTION_16BY9_LARGE         4000x2252
FRONT_CAMERA_RESOLUTION_1BY1_LARGE          2992x2992
```

**Do not "correct" these numbers to match the HAL dump.** The stock values are
what the app expects; see the rejected experiments in section 4.

### 2. The one validated change

```
target/m21s/camera/camera-feature.xml:183
- <local name="DEFAULT_MAX_ZOOM_VALUE" value="1000" />
+ <local name="DEFAULT_MAX_ZOOM_VALUE" value="4000" />
```

Resulting file: `/tmp/opencode/cf.m21s_original_zoom4000.xml`,
md5 `b59c8c15c8a91600d2ca6d5dbea98cec`. This is the file that must be deployed,
and it is what `target/m21s/camera/camera-feature.xml` now contains.

4000 is the real digital ceiling (`availableMaxDigitalZoom = 4.0`; PhoneDB lists
SM-M215F as 1.0x optical / 4.0x digital). Never raise it past 4000.

### 3. Current runtime state

With the baseline XML plus the zoom fix, the app no longer soft-reboots and the
launch now fails on the zoom range check in `onCreate`:

```
java.lang.RuntimeException: Zoom is not supported. Check the zoom range.
  minZoomLevel=1000, maxZoomLevel=1000
    at com.samsung.android.camera.layer.keyscreen.zoom.ZoomView.m(...)
```

Note that the app still reads `maxZoomLevel=1000` even though the XML says
`4000`. The zoom ceiling is therefore **not** coming from
`DEFAULT_MAX_ZOOM_VALUE`; it is resolved later from the HAL zoom capability.
That is the next thing to investigate, and it is unresolved.

### 4. Rejected experiments

**S926B `camera-feature.xml` merge — causes a soft reboot. Do not retry.**
The ROM fingerprint is `samsung/e2sxxx/e2s:17/CP2A.260605.016/S926BXXUHZZI4`,
and the v17 app covers 155/504 of its own feature keys in the S926B XML versus
59/504 in the M21s XML, which made an S926B base look attractive. Replacing the
M21s XML with a 228-key S926B-based merge made the camera **soft-reboot the
device** on launch. Reverting to the M21s baseline immediately removed the
soft-reboot. The coverage heuristic is worthless here: the extra keys pull in
shooting modes and preview sizes that the F41 HAL cannot serve, and the failure
is native, not a catchable Java exception.

**Smali resolution patch — wrong layer.** Patching the `2592x1944` constant in
`e5/f.smali` to `2576x1932` does nothing useful. The runtime values come from
`cameradata/camera-feature.xml`; that smali constant is only a fallback.

**v17 APK rebuilt/signed — not needed, not installed.** `/tmp/opencode/v17_final.apk`
(md5 `52b4acea16adb7299990b383c3431355`) builds, aligns, signs and dexopts
cleanly, but the active APK is the stock signed
`/system/priv-app/SamsungCamera/SamsungCamera.apk` (md5
`9040bcad7e94a9ddcaa052061605e7d6`, version `17.0.00.43`). Reinstalling the
rebuilt APK only risks signature/permission divergence.

**v12 stock app — will not run on One UI 9.** `OneUiVersion.get(90000)` throws,
and patching that leads to `NoSuchMethodError:
semSetDisablePreviewScreenshots(Z)V`. Generation mismatch, not a HAL problem.

### 4.1 `LIVE_FOCUS_LITE` comes from a leaked donor XML, not from the app

The crash

```
java.lang.ExceptionInInitializerError
Caused by: java.lang.NullPointerException:
  There is no matched ShootingModeIdByName with : LIVE_FOCUS_LITE
```

is **not** an app-side problem. The string does not exist anywhere in the v17
APK (verified across all four `smali_classes*` trees). It only ever came from
donor XML files that carried the S24+ variant:

```
SM-S926B : <local name="SHOOTING_MODE_LIVE_FOCUS" back="LIVE_FOCUS" front="SELFIE_FOCUS" .../>
stock m21s: <local name="SHOOTING_MODE_LIVE_FOCUS" back="LIVE_FOCUS" enable="true" more="false" order="1" info="2"/>
```

The stock M21s XML has no `front` attribute on that entry and no
`LIVE_FOCUS_LITE` at all. `unica/patches/camera/customize.sh:60-73` already
defends against this: its m21s block runs
`s/front="LIVE_FOCUS_LITE" //` on the workdir copy and then `ABORT`s if
`LIVE_FOCUS_LITE` or any untranslated donor resolution string survives.

That block is a verified no-op against the restored stock file (checked: the
`sed` produces a byte-identical file and the `ABORT` guard does not fire), which
confirms the repo XML is now in the shape `customize.sh` expects. Keep it that
way — do not hand-patch `customize.sh` to chase this string.

### 5. Deployment procedure

Editing `/system` on the running device works but is SELinux-limited:

```bash
# Android 17 uses a single / mount (system-as-root); there is no separate /system
adb shell su 0 sh -c 'mount -o remount,rw /'
adb push /tmp/opencode/cf.m21s_original_zoom4000.xml /data/local/tmp/cf.final.xml
adb shell su 0 sh -c 'cp /data/local/tmp/cf.final.xml /system/cameradata/camera-feature.xml'
adb shell su 0 sh -c 'restorecon /system/cameradata/camera-feature.xml'
adb shell su 0 sh -c 'mount -o remount,ro /'
```

Constraints on that path: an **existing** file can be overwritten with `cp`, but
`chown`/`chmod`/`rm`/create-new are denied by SELinux even as root, so the
permissions and context of `camera-feature.xml` are inherited from the file
already in place. Overwriting a `/system` **APK** is not possible this way at
all; use TWRP for APKs (`/system_root/system/priv-app/...`, note the doubled
`system`).

### 6. Launch and verify

```bash
adb shell su 0 sh -c 'cmd package compile -m speed -f com.sec.android.app.camera'
adb shell am start --user 0 -n com.sec.android.app.camera/.Camera
adb logcat -d -b crash | grep -E 'FATAL|Caused by'
```

`--user 0` is mandatory. Without it `am start` reports
`Activity class ... does not exist`, which looks like a broken install but is
only a user-selection error. Always confirm the device survived with
`adb get-state` before reading the crash log: a native/HAL fault shows up as a
disconnect and a soft reboot, not as a `FATAL EXCEPTION`.

### 7. Known camera id roles (corrected)

`dumpsys media.camera` exposes ids `0, 1, 2, 3, 4, 20, 23, 50, 52`. Roles from
the static metadata, **not** from the earlier guess:

```
0   Back   4624x3468
1   Front  3264x2448     <- front-facing; DT app-visible
2   Back   3264x2448
3   Front  2640x1980
4   Front  3264x2448
20  Back   4624x3468
23  Back   4624x3468
50  Back   3264x2448
52  Back   2576x1932     <- reported Back, *not* front
```

DT declares `supported_cameraId=<0x0 0x1 0x17 0x32 0x34>` (0, 1, 23, 50, 52),
`max_supported_camera=<5>` / `max_camera_num=<4>`. An earlier note in this file
claiming device 52 is the front camera is wrong and must not be used for
resolution mapping.

## M21s media audio: force the primary PCM backend (2026-10-05)

The Android 17 framework marks Spotify and other normal media tracks with
`AUDIO_OUTPUT_FLAG_DEEP_BUFFER`.  When
`vendor/etc/audio_policy_configuration_sec.xml` advertised the stock M21s
combined `AUDIO_OUTPUT_FLAG_PRIMARY|AUDIO_OUTPUT_FLAG_DEEP_BUFFER` mix port,
the legacy `audio.primary.exynos9611` HAL opened that stream with flags `0xa`.
Its on-device dump then reported `output format: 4` (`PCM_8_24`) and
`backend_mode: 2`, even if the policy profile itself said PCM 16-bit.  This
was the direct cause of media being silent or producing loud radio-like noise;
the physical codec route and amplifier were working.

Do not split the route into a S20+-style standalone `deep_buffer` port.  That
also selects the M21s UHQ/deep backend and is incompatible with this port's
audio framework/effect chain.  Do not replace `audio.primary.exynos9611.so`,
`libaudioproxy.so`, mixer paths, or codec/amplifier drivers to address it.

`target/m21s/mods/vendor/customize.sh` must run
`force_m21s_primary_output.py` on the secondary policy after its Android 17
include and volume-table fixes.  The helper replaces the single combined flag
with `AUDIO_OUTPUT_FLAG_PRIMARY`, retaining the PCM 16-bit profile and speaker
route.  This forces media to `backend_mode: 0`, the same primary PCM path used
successfully by system sounds.  The change was installed through TWRP on the
connected M21s and media audio was confirmed working after reboot.

For each rebuilt image, verify the generated secondary policy contains only
`AUDIO_OUTPUT_FLAG_PRIMARY` on `primary-out`.  During active Spotify playback,
`dumpsys media.audio_flinger` must show an `AudioStreamOut` with primary flags,
PCM 16-bit, and `output backend_mode: 0`; a `PCM_8_24`/`backend_mode: 2`
stream means the UHQ/deep path was reintroduced.

The target SFF must retain the stock M21s SoundAlive declaration
`eq_custom,uhq_onoff,adapt,dvfs_700000` in `target/m21s/sff.sh`, matching the
target vendor.  This keeps the framework and target HAL feature contract
consistent, but it is separate from the primary-backend fix above.

## M21s rear fingerprint sensor mapping (2026-10-03)

The M21s/F41 target uses the original EGIS SPI fingerprint HAL, as confirmed
by the boot log's `FP_SET_SENSOR_TYPE :egis`; it is a rear capacitive reader,
not the S24+'s ultrasonic under-display reader. Its target feature values must
remain `google_touch_rear` and `capacitive_rear_phone`.

The generic product-feature layer already rewrites `framework.jar` and
`SecSettings.apk`, but it used to mutate the donor sensor variable while
selecting the rear-HAL branch. That made the later `BiometricSetting.apk`
rewrite a no-op, leaving `DisplayStateManager` with
`google_touch_display_ultrasonic`. Preserve the original donor value and use
it for that final rewrite. Do not import UDFPS/optical/side-fingerprint UI
patches for M21s: the target vendor HAL and rear-sensor UI must remain in
control.

`SystemUI` does not decide the sensor geometry from the floating feature. It
uses the `sensorType` supplied by the framework's HIDL-to-AIDL adapter. The
S24+ donor's `FingerprintManager.semGetSensorPosition()` hard-codes position
`2`; the adapter maps it to `sensorType=2`, an under-display path. The M21s
rear branch must replace that method with position `3`, which maps to
`sensorType=1`. `AuthController` explicitly classifies type `1` as
`REAR_FINGERPRINT`, preventing UDFPS/ultrasonic overlay rendering.

## M21s storage mount and codec-list deadlock (2026-10-03)

In this project, `SM-S926B/e2s` is the M21s target identity; do not infer a
different target from the Samsung model string alone. The M21s boot capture
`out/target/m21s/boot-diagnostics-2026-10-03_00:41:25-0300/logcat.txt` shows
that `/data` mounts successfully as F2FS and that `vold` can mount the
emulated volume/FUSE stack. A manual `sm mount 'emulated;0'` immediately
created `/storage/emulated`, proving that the userdata filesystem and the
FUSE/sdcardfs path are functional.

The automatic mount is not failing in fstab. `StorageManagerService` logs
`H_SYSTEM_READY` and then stops producing handler messages before
`H_VOLUME_MOUNT` or `H_COMPLETE_UNLOCK_USER`. In the same interval,
`servicemanager` repeatedly tries to start the lazy AIDL service
`media.codeclist.generator`, but `/system/bin/mediacodeclist_generator` is
absent. The remaining declaration
`/system/system/etc/init/media.codeclist.generator.rc` therefore causes
repeated `Cannot find ... mediacodeclist_generator` failures while the
framework queries `MediaCodecList`; `media.codec` is not published in the
service manager at that point. This is an independent framework/media
failure. It can interfere with the storage startup sequence, but the later
capture also shows a separate missing `H_COMPLETE_UNLOCK_USER` transition and
an SDP netlink mismatch, so it must not be presented as the sole proven cause
of the volume state.

The M21s `fm_framework_compat` module must preserve both source files;
deleting the binary while leaving the lazy AIDL declaration was the cause of
the repeated `Cannot find ... mediacodeclist_generator` failures. The matching
S24+ source firmware contains `/system/bin/mediacodeclist_generator` and
`system/etc/init/media.codeclist.generator.rc`, and the module no longer
removes either one. The current generated M21s work directory was restored
from those source files, including the `0755`/`media` fs-config entry.

After flashing a new image, verify that both paths exist and that the service
manager publishes `media.codeclist.generator`; only then evaluate whether any
remaining codec query blocks `StorageManagerService`. Do not paper over this
with an init-time `sm mount` workaround.

### Driver/dependency audit (2026-10-03)

The connected M21s was checked without changing or rebooting it. The kernel
exposes the legacy Exynos MFC video nodes (`/dev/video6` through `/dev/video11`)
under `12c30000.mfc0`, the SMFC node `/dev/video12`, and
`/dev/ion`; the corresponding `mediacodec`, OMX and Codec2 services are running
and registered with hwservicemanager. The target vendor tree also contains the
32-bit OMX service and its `vendor/lib` dependencies plus the 64-bit Samsung
Codec2 service and its `vendor/lib64` dependencies. Therefore there is no
evidence of a missing kernel codec driver or missing direct HAL library causing
the current failure. `/dev/dma_heap` is not expected here because this vendor
uses the legacy ION allocator.

The installed image is still the pre-fix image: `/system/etc/init/media.codeclist.generator.rc`
exists, but `/system/bin/mediacodeclist_generator` does not. The boot log
repeats `Cannot find '/system/bin/mediacodeclist_generator'`, while the rebuilt
work directory contains the matching source binary (SHA-256
`431cb79616f945a515594c5adf4c3939999a24f871585b55cc23d0398adc7c8e`), both
`libmedia_codeclist*.so` companions, matching fs-config and SELinux type/policy.
The next image must be flashed before judging the generator's runtime or the
automatic storage mount; testing the old installed image can only reproduce the
missing-file loop.

## M21s sysinput HIDL 1.3 import and M31 provenance (2026-10-03)

The M21s target now has an experimental complete sysinput import at
`target/m21s/patches/sysinput13_compat`. Its S20+ SM-G986B/y2s
donor is pinned under `prebuilts/samsung/y2sxxx` and replaces the target's
@1.2 service with the
`vendor.samsung.hardware.sysinput@1.3-service`, its @1.0--@1.3 `lib64`
interfaces, the matching init rc, and a dedicated sysinput-only VINTF
fragment. The donor service's callback interface is included. Existing M21s
SELinux file/hwservice contexts are validated before the module completes.
The M21s sensor HALs, sensorhub configuration, and kernel firmware are
deliberately not replaced by S20+ sensor files; sysinput and sensors are
separate chains.

The Android 17 source compatibility matrix may contain only the sysinput AIDL
entry, with no legacy HIDL block. In that layout the module must retain AIDL
and append one *optional* HIDL 1.3 declaration; it must not abort merely
because a HIDL 1.2 entry is absent.

The boot capture
`out/target/m21s/boot-diagnostics-2026-10-03_00:41:25-0300/logcat.txt` proves
that the generated kernel Image alone was not sufficient: it requests
`sensorhub/shub_ramen_m31.fw`, cannot load it, and leaves Android with no
sensorhub. `out/kernel_tmp-exynos9611/out/.config` has
`CONFIG_SENSORS_SSP_M21=y` and `CONFIG_SENSORS_SSP_M31` unset, and the built
Image contains `shub_ramen_m21.fw`; however the target retained the F415F
DTBO, whose contexthub overlay still specified the M31 filename. The F415F
DTBO must stay in place for its panel, battery and touchscreen wiring.

`kernel9611` now patches only the equal-length DTBO value
`sensorhub/shub_ramen_m31.fw` to `sensorhub/shub_ramen_m21.fw`, then stages
the exact firmware generated by the M21 kernel at
`/vendor/firmware/sensorhub/shub_ramen_m21.fw` with `vendor_fw_file` metadata.
It validates that no M31 sensorhub request remains in the generated DTBO.
This is deliberately not a full M21 DTBO replacement. A new build and flash
are required before expecting the boot log to report the M21 filename.

### `external_primary not found` is a volume-state symptom (2026-10-03)

The same capture contains the exact sequence behind the recurring
`DatabaseUtils: Volume external_primary not found` exception. At 00:29:36,
`StorageManagerService` receives `onUserUnlocking(0)`, initializes
`StorageSessionController`, and calls `vold.onUserStarted(0)`. It never logs
`H_COMPLETE_UNLOCK_USER` or `H_VOLUME_MOUNT` afterwards. Instead it repeatedly
logs `Reporting emulated;0 unmounted due to system locked`; `MediaStore` then
examines `emulated;0` as `external_primary` with state `unmounted`, and
`MediaProvider` has only the `internal` volume attached. Therefore this
exception is not a corrupt MediaProvider database and must not be silenced in
the provider.

The userdata F2FS mount and the FUSE path are functional when mounted
manually, so the missing framework volume transition is the failure to fix.
Two independent compatibility defects are present in the pre-fix image: the
lazy `media.codeclist.generator` declaration still points at a missing binary,
and the Android 17/S24+ `vold`/`libepm.so` starts an SDP filesystem-netlink
thread that the M21s 4.14.355 kernel does not implement (`Protocol not
supported`, `Kernel doesn't ... provide netlink socket for sdp`). The log also
contains a `vendor_init` denial while setting `ro.crypto.fuse_sdcard`.
These defects can prevent the unlock/mount callback chain from completing;
they must be tested separately after flashing the restored generator. Do not
replace `external_primary` with a fake MediaProvider volume or force a mount
from init, because that would hide the missing `H_COMPLETE_UNLOCK_USER`
transition and break FBE/CE lifecycle handling.

## M21s boot stall: TEEgris/Keystore chain (2026-09-30)

The latest normal-boot `console-ramoops-0` was saved under
`out/target/m21s/boot-diagnostics-20260930-190600`. The phone reached
second-stage init, mounted the ext4 logical partitions, started the service
managers, vold, the legacy Keymaster HAL, and `keystore2`; this rules out an
immediate super-size, filesystem, AVB, or linker crash for this boot.

Boot then stalled while vold repeatedly requested
`android.system.keystore2.IKeystoreService/default`. The `keystore2` process
and its threads existed but remained blocked and never published the Binder
service. The preceding persistent pmsg contains the explicit lower-layer
failure: `tzdaemon` could not create its IWD socket (`-13`, EACCES), failed to
probe `root_task`, and exited. Consequently `vendor.tzdaemon=Ready` was never
published and the TEEgris-dependent Keystore chain did not become usable.

The final `Hard Reset`/kernel BUG at roughly 361.5 seconds was caused by the
user's forced key reboot after the stall and is not the initiating failure.
The later `rt5665_i2c_probe` stack appears only in the multi-CPU panic dump and
is likewise not evidence that audio caused the boot stall. On-device hashes
confirmed that the installed `tzdaemon`, Keymaster service, `keystore2`, and
patched `teegris_v3.rc` match the current M21s work directory; the existing
chmod/restorecon init patch was applied but did not resolve the IWD EACCES.

## M21s TWRP dynamic-partition installation guard (2026-09-30)

The M21s flashable ZIP now explicitly unmounts `prism`, `optics`, `odm`,
`product`, `system_ext`, `vendor`, `system`, and `system_root` before applying its
dynamic-partition operation list. This is required because TWRP may leave a
logical partition mounted (confirmed with `vendor`), causing liblp to fail
with `DM_DEV_REMOVE ... Device or resource busy`, `Cannot unmap vendor`, and
installer error 25. Keep this target-specific guard before
`m21s-prepare-super-metadata.sh` and `update_dynamic_partitions`.

## M21s Prism/Optics physical image build (2026-10-06)

The M21s target keeps Prism and Optics as fixed ext4 partitions outside
`super`. Their source trees are the existing files under
`target/m21s/CSC/prism` and `target/m21s/CSC/optics`; do not replace them with
images from another model. `target/m21s/config.sh` enables
`TARGET_BUILD_PHYSICAL_PARTITIONS` and pins the PIT sizes to 1 GiB for Prism
and 33 MiB for Optics.

The builder function `BUILD_TARGET_PHYSICAL_PARTITION_IMAGES` in
`scripts/utils/build_utils.sh` creates raw (non-Android-sparse) ext4 images
with the normal AVB footer for both trees. The footer is required by the
F415F first-stage fstab, which marks both mounts `avb`; the images still fit
their fixed PIT sizes. Raw output is required because the recovery installer
uses `package_extract_file` directly on `/dev/block/by-name/prism` and
`/dev/block/by-name/optics`; a sparse payload would be written as invalid raw
partition data. The target-files and flashable ZIP builders call this function
after the logical images are built. Full and incremental OTAs preserve these
top-level image payloads for `target/m21s/installer/install-end.edify`.

SELinux labels are kept beside the source trees in
`target/m21s/CSC/file_context-prism` and `target/m21s/CSC/file_context-optics`,
matching the stock `system_ext_file_contexts`: Prism uses `system_file`, its
carrier subtree uses `vendor_configs_file`, Optics uses `vendor_file`, and
`optics/configs` uses `vendor_configs_file`. The generated fs_config gives the
image root and every source entry UID/GID 0 with the checked-out mode.

The target install-start script unmounts `/prism` and `/optics` before the
dynamic-partition update, and install-end writes the two raw images to their
physical block names. This path is target-specific and should remain disabled
for targets without these fixed partitions.

## Rejected S24+ Dolby/SoundAlive port (2026-09-28)

Do not import S24+ `dax-default.xml`, `libswdap.so`, or SoundAlive effects
into the legacy Exynos 990 audio stack. On-device validation showed that the
HIDL audio HAL loads `/system/lib64/libswdap_legacy.so`, not the copied vendor
effect. Passing it the S24+ DAX 3.10 profile table caused
`stack corruption detected (-fstack-protector)` in `vendor.audio-hal`, which
then made `audioserver` restart continuously. The failed experimental module
`unica/patches/zz_audio_tuning` was removed.

Keep the target S20 audio HAL, SoundAlive/Dolby effects, mixer paths,
amplifier/DSP calibration, volume curves and SoundBooster 1050. In particular,
do not replace them with S24+ SoundBooster 2000 or `SoundBoosterParam` blobs:
those tunings are hardware-specific and the existing `stock_blobs` module
keeps the known-good Exynos 990 stack. The work directory is recreated at the
start of each build, so removing the experimental module is sufficient to
restore the normal target files.

## Primary repository and Settings visual baseline (2026-09-27)

`/home/ats0c/Git/ShitStockModOrSomething` is the primary working repository.
Do not make new implementation changes in `UN1CA-y2slte`; it is retained only
until the user removes it.

The visual layer of `unica/mods/settings/SecSettings.apk` was restored from
`salvogiangri/UN1CA` branch `sixteen`: `res/` and `AndroidManifest.xml` match
that source exactly. This removes the ArtisanROM/ExtremeROM About screen,
logos, maintainers' avatars and related UI resources, restoring the original
UN1CA Settings presentation. The UN1CA smali code and smali patch sets remain
in place, except for the removed Device Image feature described below. Do not
replace the current One UI 9-aware `customize.sh` with the `sixteen` version,
since it lacks dynamic smali-path and incremental XML-overlay handling
required by this base.

## StockMod Settings restoration (2026-09-26)

`INSTRUCTIONS.md` was resynchronized with the current document in
`UN1CA-y2slte`. The uncommitted Settings rebrand was discarded because it
left the ArtisanROM banner paired with partially renamed UN1CA About-page
resources. The complete `unica/mods/settings` module is again the original,
consistent overlay: banner assets, `About ArtisanROM` activity, resource IDs,
controllers and `ro.artisanrom.*` properties match each other.

The independent flashable-ZIP, boot-sound and legacy-updater changes remain
pending in this worktree; this restoration intentionally affected only the
Settings module.

On 2026-09-27, `unica/mods/settings` was restored again from the current
`UN1CA-y2slte` module after StockMod had diverged. The two directories are
byte-for-byte identical after the restore, including Settings resources,
smali controllers, `customize.sh`, and the SecSettings patch set. This does
not alter any StockMod module outside `unica/mods/settings`.

## OMCAgent recommended-app fallback (2026-09-27)

The legacy target's OMC catalogue is read from the separate `/prism`
partition and can remain empty because StockMod does not rebuild that
partition. The Setup Wizard module now keeps its Recommended apps step and
installs a fallback JSON at `/system/etc/omcagent/unica_appres.json`.

`OMCAgent5` preserves the normal regional catalogue and appends the system
catalogue to it. The list is preselected and includes Clock, Samsung
Calendar, Galaxy Wearable, Samsung Health, Spotify, Samsung Notes, and
Samsung Voice Recorder. Package retrieval remains the responsibility of
OMCAgent and its configured provider, rather than StockMod embedding APKs.

The fallback hook belongs in `u7/c.smali` method `b(Context, boolean)`,
immediately after it consolidates the carrier/`/prism` catalogue. Do not move
it to method `c(Context, int, boolean)`: newer OMCAgent5 builds use that
method for a separate CB/carrier path, so the patch will not apply there. The
agent initializes its `appMap` from `appRow` inside `initApp()`, so the hook
must merge `getAppRow()`/`setAppRow()` rather than `getApp()`. The later
`setApp(List)` initialization keeps the first occurrence of each app ID, so a
regional `/prism` entry wins over a duplicate StockMod entry.

When a regional catalogue exists, the hook also sets its resulting version to
the StockMod fallback version. `ListChange` otherwise compares only the old
and regional version, considers the catalogue unchanged, and never replaces
its existing `app_res.db`; this was observed on ZTO, where the database kept
only Smart Tutor despite the merged list.

Because EROFS consumes explicit `fs_config` and `file_contexts`, the module
also registers `/system/etc/omcagent` (0755) and its JSON (0644) through
`SET_METADATA`. Creating those paths with `mkdir`/`cp` alone makes
`mkfs.erofs` reject the image as it cannot find canned metadata.

The previously staged removal of `unica/mods/updater` remains intentional:
it removes the obsolete `ArtisanUpdater` APK and its
`com.artisan.updater` permission/default-permission declarations. Do not
restore that module as part of the OMC change.

### OMC provider correction (2026-09-28)

The first fallback catalogue was visible in the Recommended apps screen, but
selecting an entry showed `We couldn't find any information about this app.`.
On-device `omcagent_session0.log` confirmed that every fallback row ended in
`state=NOT_FOUND` and `message=App not available`. The cause was the provider
field: `GA` is the OMC/carrier route, not the Galaxy Apps seller route used by
the source catalogue. The Spotify row used `GP`; the report endpoint rejected
that value with `Invalid Parameter ... downloadType ... GP`.

All seven fallback rows in `unica_appres.json` now use `downloadType: "GS"`,
matching the working Samsung Internet/Watch Manager entries in the original
catalogue. Direct `stubUpdateCheckEx.as` checks for Clock, Calendar, Galaxy
Wearable, Spotify, Samsung Notes and Voice Recorder returned `Update
Available` for the SM-S926B/ZTO/72402 profile, including Samsung Health
(`com.sec.android.app.shealth`). This fixes metadata lookup;
the actual APK download and installation remain OMCAgent's responsibility.
After flashing a build with this change, clear OMCAgent's app data or remove
its stale `app_res.db` so rows previously cached as `NOT_FOUND` are queried
again.

On-device validation completed on 2026-09-28: after clearing OMCAgent data and
allowing its catalog refresh to run, the fallback entries received their
metadata and the selected applications downloaded successfully. The recreated
database initially contained only the schema until the normal OMCAgent refresh
was triggered; this is expected and is not a database-creation failure.

## Device Image removal (2026-09-27)

The optional Device Image feature and its adapted `DeviceImageManager` patch
were removed from StockMod. The three `DeviceImagePreferenceController` smali
files and `0002-Make-device-image-product-code-configurable.patch` are no
longer part of the module. The `Utils.smali` dialog-return descriptor changes
remain because they are independently required by the Android 17 SecSettings
copy.

## x1s HDR10+ and y2s LOG camera gates (2026-09-25)

The target camera XML always overrides the target firmware's
`system/cameradata/camera-feature.xml`. Stock Android 13 camera XMLs from
the public Android Dumps collection were inspected as a hardware-capability
reference only; their framework generation is older than the One UI 9 source.

- Stock x1s (`G980FXXSJHXC1`) advertises `hdr10=true` for 13 rear recording
  profiles. The x1s target had changed all 30 profiles to `false` and added
  `SUPPORT_HDR10_PLUS_RECORDING=false`; the 13 stock-supported profiles were
  restored and the contradictory explicit disable was removed.
- The y2s dump (`G985FXXSFHWB1`) does not advertise LOG video, so
  `SUPPORT_LOG_VIDEO=true` in y2s is an explicit UN1CA parity experiment with
  x1s rather than a stock-derived claim. Do not add `SUPPORT_DEFAULT_HEVC` as
  part of this change; it changes the default recording codec independently.
- The same stock comparison found the all-disabled HDR10+ pattern in `c2s`,
  `r8s`, and `z3s`. `unica/patches/camera/customize.sh` restores only the
  stock-advertised rear profiles for those targets after their target XML is
  copied. r8s has two `1920x1440` entries, so only its final effective
  physical-camera entry is enabled. `c1s` remains unchanged because no
  matching dump was available.

Validation required after a build: x1s should expose HDR10+ only at the
stock-supported rear resolutions; y2s should expose LOG video and must be
tested for preview, recording, playback and saved-file validity.

## Experimental y2s Autoframe and Detail Enhancement import (2026-09-28)

The S24+ `SamsungCamera.apk` implementation already contains both the
Autoframe pipeline (`SUPPORT_VIDEO_AUTO_FRAMING`) and the Detail Enhancement
pipeline (`SUPPORT_DETAIL_ENHANCER`). The y2s APK therefore did not need a
smali port. Its missing pieces were feature gates and, for Autoframe, the
source-side tracker closure.

The y2s camera feature overlay advertises `SUPPORT_VIDEO_AUTO_FRAMING`, and
`target/y2s/sff.sh` sets `SEC_FLOATING_FEATURE_CAMERA_CONFIG_AUTOFRAMING` to
`uhd`. This is independent from Detail Enhancement.

For y2s only, `unica/patches/camera/customize.sh` imports the S24+ vendor
Autoframe closure: `libaivideocentral.arcsoft.so`, both `libzoomroi*` and
`libbodyid.arcsoft.so` helpers, the two Autoframe plugins,
`libautoframing_object_tracker.camera.samsung.so`,
`libautotracking_interface.so`, the AI mode/FISP wrappers
(`libAIMFISP.camera.samsung.so`, `libAIMFISP_core.camera.samsung.so` and
`libAImode_wrapper.camera.samsung.so`), and the detector `.info`/`.tflite` pair under
`vendor/etc/saiv/image_understanding/db/aic_autoframing_detector_tracker`.
ELF dependency inspection found no additional non-system libraries missing
from y2s. The import is guarded: if any source file is unavailable, it is
skipped rather than producing a partial stack.

### Detail Enhancement rollback after kernel panic (2026-09-28)

The first device test exposed a loader error for
`libAIHRWrapper.camera.samsung.so`. Making that S24+ wrapper visible in the
app linker namespace stopped the Java/native camera crash, but it was not a
valid port: taking a photo then caused a **kernel panic** and forced reboot.

The captured log provides the concrete compatibility boundary. SamsungCamera
entered `UNI_SHOOTING_MODE_GALAXY_AI_HIRES`, while the S20+ camera HAL logged
`No Scenario is found for shootingMode(UNI_SHOOTING_MODE_GALAXY_AI_HIRES)`.
It also rejected source-only vendor tags
`availableHighresYuvStreamConfigurations`, `availableHighresRawStreamConfigurations`,
and `adaptivePixelMode`; the camera node subsequently reported only a dummy
model. Persistent `dmesg-ramoops` confirms a kernel panic with the physical
camera pipeline active (`PDP0`, `3AA0`, `ISP0`, `MCS0`). The record itself is
truncated before the first panic line, so it must not be represented as proof
of a particular kernel function.

For safety, the experimental S24+ AIHR wrapper import and all y2s AI High
Resolution feature gates were removed. This hides/disables Detail Enhancement
again rather than allowing a source scenario to be sent to the legacy Exynos
990 HAL. The independent Autoframe import remains. Re-enable Detail
Enhancement only with a target-compatible HAL scenario, vendor-tag contract,
and processing implementation; copying more S24+ ENN/Tetra binaries cannot
provide those interfaces and risks another panic.

### Dependency and feature-gate audit (2026-09-28)

The Autoframe import was checked through its ELF closure. Its plugins and
tracker require `libaivideocentral.arcsoft.so`, `libzoomroi*.samsung.so`,
`libbodyid.arcsoft.so`, `libarcsoft_object_tracking.so`,
`libautoframing_object_tracker.camera.samsung.so`, `libOpenCv.camera.samsung.so`,
`libuniplugin.so`, `libmpbase.so`, plus the detector `.info`/`.tflite` pair.
The first five are imported by the y2s block; the remaining libraries are
already present in the target, so no additional Autoframe blob is missing.

The S24+ `AIHRWrapper` has late-loaded paths through
`libAIphoto_core.camera.samsung.so` and `libTetraMFP10.camera.samsung.so`.
Those require the S24+ ENN AIDL client/service
(`libenn_public_api_cpp.so`, `libenn_user.samsung_slsi.so`,
`vendor.samsung_slsi.hardware.enn_aidl-V1-ndk.so`) and matching camera models.
The legacy Exynos 990 NPU/ISP stack does not provide that contract. Do not
import that binary stack merely to satisfy filenames.

This document records the investigation and changes made after the request to inspect the latest `y2s` boot logs. It is intended as a handoff for other developers or AI assistants working on the same branch.

## Repository state

- Repository: `/home/ats0c/UN1CA-y2slte`
- Active branch during this investigation: `seventeen`
- An incremental ROM build for the cgroup A/B test completed the work-dir
  generation at 19:16. The flashable build was subsequently generated and
  installed on the connected SM-S926B for on-device A/B validation.
- The fixes described below were prepared on `seventeen`; check the branch history for their final commit identifiers.
- Do not discard unrelated local modifications. The working tree already contains other ongoing work.

## Atualização da branch

Em 2026-09-19, a branch local `seventeen` foi atualizada por fast-forward de
`3faf492f` para `c4607c8a` (`cgroup: revamp One UI 8.5 compatibility patch`),
incorporando os sete commits mais recentes de `origin/seventeen`. As alterações
locais rastreadas e os arquivos não rastreados foram preservados; o conflito
documental em `INSTRUCTIONS.md` foi combinado mantendo os registros locais e
as novas notas do upstream. Nenhum build ou flash foi executado.

## Persistent logcat capture

A dedicated, reconnect-safe logcat capture was added at:

```text
scripts/capture_logcat_tmux.sh
```

The detached `y2s-logcat` tmux session was started on 2026-09-16 at 16:49:21
(-0300). Its current output is:

```text
out/target/y2s/boot-diagnostics-20260916-164921/logcat.txt
```

The script remains in an infinite loop even when no device is connected. It
waits for ADB, confirms that `adb get-state` reports `device`, writes a
`DEVICE_CONNECTED_<date>_<time>` marker, captures all logcat buffers with
`threadtime`, writes `LOGCAT_DISCONNECTED_<date>_<time>` when the transport
goes away, and then waits for the next connection. ADB-server failures and
not-ready transports are retried instead of closing the tmux pane.

Useful commands:

```bash
tmux attach -t y2s-logcat
tmux capture-pane -pt y2s-logcat:0 -S -40
```

The earlier `y2s-logs` session remains active with its existing logcat,
dmesg, and snapshot panes so that the previous diagnostics are not
interrupted. The new session is the canonical persistent logcat capture for
future boots. Set `ADB_SERIAL` to target a specific device when more than one
ADB transport is present.

Validation performed after adding the script:

1. `bash -n scripts/capture_logcat_tmux.sh`
2. `git diff --check`
3. Confirmed that `y2s-logcat` remains attached while the device is connected
   and that its log contains `DEVICE_CONNECTED_2026-09-16_16:49:21-0300`.

The `y2s-logcat` session was reopened on 2026-09-23 at 17:50:14 (-0300)
using the same persistent script. It is currently waiting for ADB to report a
connected device; no capture directory is created until the next connection.

## Logs inspected

The latest active capture is:

```text
out/target/y2s/boot-diagnostics-20260916-124734/
```

Files used: `logcat.txt`, `dmesg.txt`, and `snapshot.txt`.

The `y2s-logs` tmux session was still active, and the device was visible through ADB as a normal Android device. The newest boot cycle begins near this marker in `logcat.txt`:

```text
==== DEVICE_CONNECTED_2026-09-16_13:38:18 ====
```

## Graphics result

The previous graphics fixes are working in this boot cycle:

- There is no new `ion_open failed with Permission denied` message.
- There is no new `output buffer not gpu writeable` abort.
- There is no new `gralloc-mapper is missing` abort.
- SurfaceFlinger, the Exynos graphics allocator 2.0 service, and composer 2.3 start successfully.
- The composer is killed only after `system_server` dies; it is not the origin of the current boot loop.

Do not revert the legacy mapper or ION SELinux fixes while investigating the current failure.

## Current fatal boot failure

### 2026-09-22 bootloop: invalid USB timeout patch

The boot diagnostics from `out/target/y2s/boot-diagnostics-2026-09-22_22:52:08-0300/logcat.txt`
showed `system_server` aborting repeatedly with:

```text
java.lang.VerifyError: Verifier rejected class
com.android.server.power.PowerManagerService:
updateIsPoweredLocked(int): register v2 has type PositiveByteConstant but expected Long
```

`bootchecker` then issued `reboot,rescueparty_by_bootchecker R5`. The cause was
`platform/exynos990/patches/framework_compat/smali/system/framework/services.jar/0002-avoid-resetting-screen-timeout-on-power-plug.patch`:
its injected USB check overwrote `v2`, the low half of the live `long v2/v3`
timestamp passed to `wakePowerGroupLocked()` and `userActivityNoUpdateLocked()`.
The patch was first corrected to use the dead integer temporaries `v4` and
`v6`, but adding a fifteenth local remapped `p1` to `v16` and caused another
smali failure. The final version keeps `.locals 14` and stores the old plug
type in the no-longer-used `p1` register after its flag check. No build or
flash has been run after this correction; rebuild `services.jar` before
testing.

The boot progresses into Android framework startup, but `system_server` dies with this verifier error:

```text
java.lang.VerifyError: Verifier rejected class
com.android.server.wm.WindowManagerService:
void WindowManagerService.changeDisplayScale(...) failed to verify:
return-object not expected
```

The invalid instruction came from:

```text
unica/mods/settings/smali/system/framework/services.jar/
0004-Allow-disable-screen-capture-detection.patch
```

The affected method has return type `V` (`void`):

```smali
.method public final changeDisplayScale(Landroid/view/MagnificationSpec;ZLandroid/view/IInputFilter;)V
```

The old injected sequence was therefore invalid:

```smali
invoke-static {}, Ljava/util/Collections;->emptyList()Ljava/util/List;
move-result-object p0
return-object p0
```

It also used `v3` despite the method declaring `.locals 3`. In this method, `v3` aliases parameter register `p0`, so writing to `v3` overwrote the `WindowManagerService` instance.

## Patch applied

The patch source was corrected to use an existing local register and the proper return opcode:

```smali
const/4 v2, 0x0

invoke-static {v0, v1, v2}, Landroid/provider/Settings$System;->getInt(Landroid/content/ContentResolver;Ljava/lang/String;I)I

move-result v0

if-eqz v0, :unica_ss_notify

return-void
```

The patch metadata was updated from 63 to 59 inserted lines, and the affected hunk count was updated accordingly.

The other injected early return in `registerScreenRecordingCallback(...)Z` remains:

```smali
return v1
```

That instruction is correct because that method returns a boolean (`Z`).

## Validation performed

The updated patch passed all of the following checks:

1. `git apply --stat`
2. `git apply --numstat`
3. `git diff --check`
4. The old patch was reverse-applied to copies of both affected decoded smali files.
5. The new patch passed `git apply --check` against those reconstructed clean files.
6. The new patch was applied successfully to those files.
7. The resulting `changeDisplayScale(...)V` method contains `return-void`, uses valid local registers, and no longer contains `return-object`.

## Non-fatal log item

`PlayIntegrityHooks.shouldBypassTaskPermission()` logs a caught `NullPointerException` because `PackageManager` is not ready during early `ActivityManagerService` construction. It is not the fatal exception responsible for this boot loop. Do not treat it as the current boot blocker unless a later log shows it escaping the hook.

## Required next step

Generate a fresh build so that `services.jar` is rebuilt from the corrected patch, install it, and capture a new boot log. The currently installed build still contains the invalid old bytecode and will continue restarting until replaced.

When reviewing the next log, first verify that all of these strings are absent:

```text
return-object not expected
ion_open failed with Permission denied
output buffer not gpu writeable
gralloc-mapper is missing
```

Then identify the first fatal exception in the newest boot cycle instead of acting on errors inherited from older cycles in the same appended log file.

## Selective repository upload

On 2026-09-16, the tracked local changes were selectively prepared for
upload on branch `seventeen`. The following tracked files were intentionally
left out and remain local for separate review:

```text
platform/exynos990/patches/extremekrnl/customize.sh
scripts/download_fw.sh
scripts/internal/build_incremental_ota_zip.sh
scripts/make_rom.sh
```

Untracked files were also intentionally left out:

```text
apply.out
last_kmsg
scripts/capture_logcat_tmux.sh
```

## PackageManagerService verifier correction

The boot cycle beginning at
`DEVICE_CONNECTED_2026-09-16_18:45:14-0300` exposed a second verifier
failure in `PackageManagerService.verifyReplacingVersionCode(...)`:

```text
register v3 has type Reference: java.lang.String but expected Integer
```

The fault was in
`unica/mods/settings/smali/system/framework/services.jar/0002-Allow-app-downgrade.patch`.
Its injected Settings lookup overwrote live registers `v3` and `v4`; `v3`
was the integer argument later passed to `isDowngradePermitted(IZ)Z`.

The first correction attempted to use local registers `v16` through `v18`,
but Apktool's non-range smali instructions reject registers above `v15` even
when the method has enough total locals. The patch now uses the method
parameter aliases `p0` through `p2`, whose original values were already
copied into locals and are no longer needed at this point. It uses
`move-object/from16`, `invoke-virtual/range`, `const-string`, `const/16`, and
`invoke-static/range`, preserving the original `v3` and `v4` types:

```smali
iget-object v0, v2, Lcom/android/server/pm/InstallPackageHelper;->mContext:Landroid/content/Context;
move-object/from16 p0, v0
invoke-virtual/range {p0 .. p0}, Landroid/content/Context;->getContentResolver()Landroid/content/ContentResolver;
move-result-object p0
const-string p1, "unica_allow_downgrade"
const/16 p2, 0x0
invoke-static/range {p0 .. p2}, Landroid/provider/Settings$System;->getInt(Landroid/content/ContentResolver;Ljava/lang/String;I)I
move-result v0
```

Validation performed:

1. Reversed the old patch against the generated `PackageManagerService.smali`.
2. Applied the corrected patch successfully to the reconstructed clean file.
3. Confirmed that `v3` remains the integer argument at the
   `isDowngradePermitted(IZ)Z` call and that the new invoke uses contiguous
   parameter aliases `p0..p2`.
4. Rebuilt the decoded `services.jar` directly with Apktool v3.0.3-11;
   smaling and APK assembly completed successfully.
5. No full ROM build or device installation has been performed yet.

The next required step is a fresh build and boot test so the corrected
`services.jar` replaces the currently installed bytecode.

## ExtremeKRNL cgroup v2 compatibility

The `y2s` boot log showed the Android userspace requesting the cgroup v2 mount
option `memory_recursiveprot`, which is not implemented by the ExtremeKRNL
4.19 cgroup parser. The kernel rejected that option and Android retried the
mount without it. This was non-fatal, but generated an avoidable init error
and exposed a userspace/kernel capability mismatch.

The ExtremeKRNL integration now applies:

```text
platform/exynos990/patches/extremekrnl/patches/0001-accept-memory-recursiveprot-on-legacy-cgroup2.patch
```

The patch makes the legacy parser accept `memory_recursiveprot` as a no-op.
This preserves the exact behavior of Android's existing retry path while
allowing the initial cgroup v2 mount to complete without the error. The
`customize.sh` integration is idempotent and includes the patched kernel
working tree in the existing cache key, so a stale kernel image is rebuilt.

Validation performed:

1. `git apply --check` succeeds against the current ExtremeKRNL source.
2. `bash -n platform/exynos990/patches/extremekrnl/customize.sh` succeeds.
3. `git diff --check` succeeds for the integration changes.
4. The patched `kernel/cgroup/cgroup.o` compiled successfully with the
   current ExtremeKRNL configuration.

No full kernel or ROM build was run in this step. Build and boot validation
remain required; the expected result is that `cgroup2: unknown option
"memory_recursiveprot"` and `Mounting memcg with memory_recursiveprot failed`
no longer appear in the new boot log.

## Verifier fixes for the downgrade and HMA patches

On 2026-09-16, the two verifier failures found in the boot diagnostics were
corrected in their patch sources:

- `unica/mods/settings/smali/system/framework/services.jar/0002-Allow-app-downgrade.patch`
  now restores parameter `p1` from the original `PackageInfoLite` saved in
  `v5` after the Settings lookup. The lookup still uses `p0..p2` as its
  temporary contiguous range, but the later `checkDowngrade(...)` call now
  receives the correct `PackageInfoLite` reference instead of the temporary
  setting-name `String`.
- `unica/mods/hma/smali/system/framework/services.jar/0001-Introduce-HideAppListUtils.patch`
  now uses `v0` for the temporary boolean/context values in
  `ActivityStarter.executeRequest(...)`. Register `v6`, which contains the
  live `resultWho` `String`, is no longer overwritten. The block is entered
  only while the original result code in `v0` is zero, so the false branches
  restore the same zero result and the archiver path overwrites `v0` as it did
  previously.

Validation completed:

1. Reversed the previous patch versions against the decoded Smali and applied
   the corrected versions successfully.
2. Rebuilt a temporary full decoded `services.jar` with Apktool v3.0.3-11;
   both `classes.dex` and `classes2.dex` smaled and the APK was assembled
   successfully.
3. Updated the patch metadata for the additional downgrade restoration
   instructions and ran `git diff --check`.

No full ROM build, installation, or post-fix device boot test has been run
yet. A real incremental build was started with
`./scripts/make_rom.sh -c --no-rom-zip`, but it was intentionally interrupted
by the user during work-directory creation so they can run the build
themselves. It did not reach APK/JAR assembly or produce an installable ROM.
The next step is to build and install a fresh ROM, then confirm that the
`PackageManagerService` `PackageInfoLite` verifier error and the
`ActivityStarter.executeRequest(...)` `String`/`Conflict` verifier error are
absent from a new boot cycle.

## Legacy BPF connectivity crash fix

The boot cycle beginning at
`DEVICE_CONNECTED_2026-09-16_21:06:55-0300` reached app optimization but then
restarted because `system_server` aborted inside
`LocalNetEventHandler::GetRingbuf()`. On the Exynos 990 Linux 4.19 kernel,
`netbpfload` correctly skips `local_net_note_op_ringbuf` (that map requires
kernel 5.10 or newer), while `netlog.bpf` also fails with `Invalid argument`.
The framework nevertheless tried to construct `LocalNetEventListener`, which
caused the native `SIGABRT`. `bootchecker` then issued
`reboot,rescueparty_by_bootchecker R2` after the repeated crashes.

The following source changes were made:

- `platform/exynos990/patches/tethering_legacy/patches/service-connectivity.jar/0001-disable-local-net-event-listener-on-legacy-bpf.patch`
  makes `ConnectivityService$Dependencies.getLocalNetEventListener(...)`
  return `null`. `ConnectivityService` already checks for a null listener
  before starting it, so networking remains available while only this
  optional local-net telemetry is disabled.
- `platform/exynos990/patches/tethering_legacy/customize.sh` now extracts
  `service-connectivity.jar` from the Tethering APEX payload, applies the
  smali patch, rebuilds the jar, and places it back before rebuilding and
  signing `apex_payload.img`. The generated Apktool cache is removed after
  the jar is returned to the payload.

Validation performed:

1. `bash -n platform/exynos990/patches/tethering_legacy/customize.sh`.
2. `git diff --check`.
3. Applied the patch to a decoded `service-connectivity.jar` with
   `git apply --check` and rebuilt it using the repository's `scripts/apktool.sh`.
4. Re-decoded the rebuilt jar and confirmed the method contains only
   `const/4 p0, 0x0` followed by `return-object p0`.

No full ROM build or device installation has been performed. Run a fresh build
and boot test next, then verify that `LocalNetEventHandler: BpfRingbuf init
failed`, `Fatal signal 6` in `system_server`, and the rescue-party reboot are
absent from the new connection cycle.

## Logcat tmux session reopened

The persistent `y2s-logcat` tmux session was recreated on 2026-09-16 at
21:44:45 (-0300) after the previous tmux server was no longer running. It is
using `scripts/capture_logcat_tmux.sh`, remains detached, waits indefinitely
for ADB/device availability, and records connection/disconnection markers.
The current capture file is:

```text
out/target/y2s/boot-diagnostics-20260916-214445/logcat.txt
```

At recreation time no ADB device was connected; the session is still alive and
will begin a new `DEVICE_CONNECTED_<date>_<time>` section when the phone is
available. Attach with:

```bash
tmux attach -t y2s-logcat
```

## Consolidated legacy BPF event-consumer handling

The next boot diagnostic cycle showed that the first `LocalNetEventHandler`
fix was effective: that abort no longer appeared. The same
`libservice-connectivity.so` still had a second fatal startup path,
`LoopbackEventHandler::Start()`, reached through
`BpfEventPoller.nativeInitLoopbackEventConsumer()`. Its missing map was
`/sys/fs/bpf/netd_shared/map_netd_loopback_access_ringbuf`.

The native inventory found exactly two fatal connectivity ring-buffer
consumers in this APEX:

- `LocalNetEventHandler`, using `map_netd_local_net_note_op_ringbuf`, disabled
  by patch `0001-disable-local-net-event-listener-on-legacy-bpf.patch`.
- `LoopbackEventHandler`, using `map_netd_loopback_access_ringbuf`, disabled
  by patch `0002-disable-loopback-event-consumer-on-legacy-bpf.patch`.

`customize.sh` now applies both patches to the decoded
`service-connectivity.jar` before rebuilding the Tethering APEX payload, so a
new missing ring buffer is handled in the same pass instead of requiring a
one-at-a-time boot/fix cycle. `libmemevents.so` has a separate
`MemBpfRingbuf` consumer for `map_bpfMemEvents_ams_rb`; the log only reports a
non-fatal initialization error for it, so it remains enabled to preserve the
available memory-event telemetry and is not part of the `system_server`
abort.

Validation completed on 2026-09-16:

1. Applied both patch files cleanly to a fresh `--no-debug-info` decode of the
   source `service-connectivity.jar`; the loopback patch was also
   reverse-applied and re-applied against the already patched decode.
2. Rebuilt and re-decoded the patched `service-connectivity.jar` from that
   fresh decode with Apktool v3.0.3-11 successfully.
3. Confirmed `getLocalNetEventListener(...)` returns `null` and the
   `systemReadyInternal` path contains no call to
   `nativeInitLoopbackEventConsumer()`.
4. Ran `bash -n platform/exynos990/patches/tethering_legacy/customize.sh` and
   `git diff --check`.

No full ROM build or device installation has been performed after the second
patch. Build and boot a fresh image, then check the next connection section
for any remaining `system_server` abort.

## Logcat tmux session restarted

The persistent `y2s-logcat` session was restarted on 2026-09-16 at
23:36:31 (-0300) after the previous capture file had been removed by a build
cleanup while the tmux process still held the deleted file open. The session
is detached, survives terminal and device disconnects, and is currently
capturing into:

```text
out/target/y2s/boot-diagnostics-20260916-233631/logcat.txt
```

The phone was already available through ADB when the session was started, so
the file contains a new `DEVICE_CONNECTED_2026-09-16_23:36:31-0300` marker.
Attach with:

```bash
tmux attach -t y2s-logcat
```

## A/B test do abort do zygote (2026-09-19)

O aparelho foi conectado por USB para um teste controlado. Ao abrir o Chrome,
o log mostrou a sequência: criação do cgroup do filho, aviso de que
`SystemMemoryProcess`/`JoinCgroup memory` seria ignorado e `SIGABRT` no
`zygote-child`; o spam `ZygoteProcess: Connection refused` começou logo
depois. Os controllers `memory` estavam ativos no root, `apps` e `system`.
O teste inicial levantou a hipótese de que o abort vinha exclusivamente do
perfil, mas o A/B instalado abaixo mostrou que essa hipótese é incompleta.

Para isolar essa causa, o perfil `SystemMemoryProcess` em
`prebuilts/samsung/e2sxxx/system/etc/task_profiles.json` foi temporariamente
mantido sem ações (`"Actions": []`). Isso é apenas um A/B diagnóstico: não é
a correção definitiva porque remove a movimentação desse processo para o
cgroup `system`. O JSON foi validado localmente. Um build incremental foi
iniciado com `source buildenv.sh y2s && ./scripts/make_rom.sh -c
--no-rom-zip` e concluiu a geração do `work_dir` às 19:16. A build flashável
foi então gerada pelo usuário e instalada no SM-S926B; a validação ocorreu no
fingerprint `samsung/e2sxxx/e2s:17/CP2A.260605.016/S926BXXUHZZHL`.

Resultado do A/B instalado: o perfil sem ações eliminou o aviso
`JoinCgroup ... memory ... will be ignored`, mas **não eliminou** o
`zygote-child SIGABRT`: ainda ocorreram aborts às 20:03:37 (PID 18836) e
20:04:43 (PID 19300). Nesses eventos o cgroup do filho foi criado
normalmente; logo, a causa não é somente o `JoinCgroup` do
`SystemMemoryProcess`. O `crash_dump64` também não conseguiu abrir `/proc` do
filho antes de ele desaparecer, portanto ainda falta um tombstone utilizável
para identificar a chamada que dispara o abort.

O spam `ZygoteProcess: Got error connecting to zygote, retrying. msg=
Connection refused` continua em ritmo alto (mais de 52 mil linhas entre
20:03 e 20:09), mesmo com `zygote`/`zygote_next` em execução e os sockets
correspondentes escutando. Ele é um problema separado, ainda não corrigido;
a propriedade `ro.vendor.redirect_socket_calls=true` e o caminho de conexão
do `system_server` precisam ser investigados.

O log também fechou a causa do soft-reboot: às 20:05:13 o `Watchdog` matou o
`system_server` porque ele ficou 71 s bloqueado em
`ActivityManager:procStart`, dentro de
`ZygoteProcess.waitForConnectionToZygote()` ->
`AppZygote.connectToZygoteIfNeededLocked()`. Em seguida o zygote registrou
`Zygote failed to write to system_server FD: Connection refused` e saiu; o
`init` reiniciou o zygote e o `system_server` (novo PID 19820 às 20:05:15).
Assim, o spam não é apenas cosmético: ele trava o start de processos e causa
o soft-reboot. O socket recusado é o AppZygote do Chrome (`uid 10248`), que
está abortando antes de ficar disponível.

Teste de controle após o reinício do `system_server`: `adb shell am start -W
-a android.settings.SETTINGS` abriu `SettingsHomepageActivity` em 864 ms,
com `system_server` (PID 19820) e zygote ativos e sem novo abort/refusal no
intervalo observado. Isso restringe a falha ao caminho de AppZygote usado pelo
Chrome/sandbox, e não a toda criação de processos normais.

Também permanece um crash independente do Chrome: `SIGTRAP` em
`libchrome.so`, com `Timed out waiting for GPU channel`, sem relação direta
com o abort do zygote. O perfil sem ações continua sendo apenas um A/B
diagnóstico e não deve ser tratado como correção final, pois remove a
colocação de `SystemMemoryProcess` no cgroup `system`.

## SDHMS RescueParty soft-reboot fix

The cycle beginning at `DEVICE_CONNECTED_2026-09-16_23:36:31-0300` was not a
kernel reboot or a zygote failure. `com.sec.android.sdhms` crashed repeatedly
in its `SDHMS Handler Thread` with:

```text
java.lang.IllegalArgumentException: No enum constant
com.sec.android.sdhms.thermal.overheatcontrol.overheatcomplex.OverheatComplexType.DEX
```

`RescueParty` detected the repeated SDHMS crashes and intentionally triggered
`WARM_REBOOT` at 23:37:29. The generated Samsung Device Health Manager APK
contained `<DEX formula="SKIN" temp="470" />` in `assets/ssrm_default.xml`,
but the target APK's `OverheatComplexType` enum has no `DEX` member. The
problem came from `unica/patches/dvfs/customize.sh`, which copied
`assets/siop_default.xml` into the `ssrm_default.xml` destination in both
asset-installation branches, even though the repository already provides the
separate compatible `assets/ssrm_default.xml` file.

The script now copies `$MODPATH/assets/ssrm_default.xml` for that destination
in both branches. This removes the accidental DEX entry from the SSRM fallback
policy; the separate SIOP fallback required the additional correction below.
No ROM build or device install was performed after this source correction; build and boot-test it next, then
verify that `No enum constant ...OverheatComplexType.DEX`, repeated
`com.sec.android.sdhms` crashes, and `reboot,rescueparty_warm_reboot_by_com.sec.android.sdhms`
are absent from the next capture.

## SDHMS fallback SIOP DEX enum fix

The next test still reported `OverheatComplexType.DEX` after the
`ssrm_default.xml` correction. The generated APK had the corrected SSRM asset,
but it also installed `assets/siop_default.xml` from this patch. SDHMS parses
that fallback policy during startup, and the target enum only defines
`LTB`, `LCD`, `GDM`, `GDMLTB`, `SS`, and `EMR`; it does not define `DEX`.

The unsupported `<DEX formula="SKIN" temp="470" />` entry was removed from
`unica/patches/dvfs/assets/siop_default.xml`. The target-specific
`siop_y2s_exynos990.xml` policy already contains compatible overheat types and
remains unchanged. No build, installation, or device test was performed after
this source correction; build a fresh image and confirm that the SDHMS handler
no longer throws `No enum constant ...OverheatComplexType.DEX`.

## Logcat capture reopened for app-launch failure

On 2026-09-17 at 01:57:15 (-0300), the persistent `y2s-logcat` tmux session
was recreated because the previous capture process was no longer running after
the build cleanup. The phone was in recovery at recreation time, so the script
is waiting for a normal ADB connection and will record a new
`DEVICE_CONNECTED_<date>_<time>` section when Android boots. The current output
file is:

```text
out/target/y2s/boot-diagnostics-20260917-015715/logcat.txt
```

The capture is detached and survives terminal/device disconnects. Attach with:

```bash
tmux attach -t y2s-logcat
```

## Logcat capture reopened after Chrome/WebView downgrade

On 2026-09-17 at 03:17:27 (-0300), the persistent `y2s-logcat` session was
recreated after the previous tmux server was unavailable. It is detached,
survives terminal and device disconnects, and is waiting for the next ADB
connection. The new output file is:

```text
out/target/y2s/boot-diagnostics-20260917-031727/logcat.txt
```

The phone's Chrome and WebView downgrade was reported to stop the AppZygote
soft-reboot loop; preserve the next boot capture to verify that result.

## Logcat capture reopened again

On 2026-09-17 at 03:23:40 (-0300), `y2s-logcat` was recreated because the
previous tmux server and capture process had exited. It is detached and
waiting for the next ADB connection. The new capture file is:

```text
out/target/y2s/boot-diagnostics-20260917-032340/logcat.txt
```

## Logcat capture reopened again

On 2026-09-17 at 12:19:59 (-0300), the `y2s-logcat` tmux session was
recreated after the previous tmux server and capture process exited. It is
detached and survives terminal and device disconnects. The phone connected at
12:20:06 (-0300), and the new capture file is:

```text
out/target/y2s/boot-diagnostics-20260917-121959/logcat.txt
```

## SystemUI crash: media library ABI mismatch

In the connection cycle captured in
`out/target/y2s/boot-diagnostics-20260917-121959/logcat.txt`, `com.android.systemui`
repeatedly crashes while creating the video wallpaper player:

```text
java.lang.UnsatisfiedLinkError: dlopen failed: cannot locate symbol
_ZN7android10MppWrapper28renderAndReleaseOutputBufferEillRKNS_2spINS_8AMessageEEE
referenced by /system/lib64/libmediasndk.so
```

The failure starts in `SemMediaPlayer`/`ImageWallpaper` and causes
`Process com.android.systemui has crashed too many times`, leaving the device
without SystemUI. The relevant log is around lines 390542-390650.

The source is an ABI mismatch introduced by the Paradigm Audio eraser block:
`unica/mods/paradigm/customize.sh` unconditionally imports the `pa2qxxx`
`libmediasndk.so` and `libmediasndk.mediacore.samsung.so` at lines 111-112.
The flashed `libmediasndk.so` hash is identical to that prebuilt. It requires
the old `MppWrapper::renderAndReleaseOutputBuffer(...AMessage)` symbol, while
the source S926B `libmppclient.so` in the image exports the newer signature
with an additional boolean argument. The matching S926B media libraries exist
under `out/fw/SM-S926B_EUX/system/system/lib64/`.

No source fix has been applied yet. The safe correction is to use a coherent
media-library set from the source firmware or disable this Audio eraser import;
do not mix `pa2qxxx` media libraries with the S926B `libmppclient.so`.

The failure was also confirmed live with the phone connected: the active
wallpaper is `com.samsung.android.wallpaper.res/Default_Video_Wallpaper_ZVLB.mp4`,
and `SystemUI` continues to crash/restart with the same linker error. The
latest repeated crash is recorded around lines 700125-700169 of the capture.

## Initial display density corrected for native resolution mapping

On 2026-09-17, the connected SM-S926B donor port was running the FHD mode at
1080x2400 with a logical density of 337 dpi. There was no persistent
`display_density_forced` override; the value came from the native Android 16
`DensityMapping` in `services.jar`. The generated vendor properties had
`ro.sf.lcd_density=450` and `ro.sf.init.lcd_density=450`, and the native path
scaled its static 450 dpi base by 1080/1440. The original G986B target's FHD
behavior is 450 dpi, so the donor mapping made the UI oversized.

The temporary `wm density` override used during diagnosis was reset. The
temporary `SMALI_PATCH` added to
`unica/patches/product_feature/customize.sh` to bypass the native density map
was reverted on request; no build or flash was performed after the change.

## Reversão do ajuste de DPI

Em 2026-09-17, removi o bloco `SMALI_PATCH` de
`unica/patches/product_feature/customize.sh`, conforme solicitado. Nenhum build
ou flash foi executado após a reversão.

## AppZygote SystemMemoryProcess crash: memory controller bake (2026-09-18)

The Android 16+ donor's sandboxed zygote specialization on Exynos990 aborts
its children (`F libc: Fatal signal 6, zygote-child`) when the
`SystemMemoryProcess` profile applies `JoinCgroup memory system`: the Exynos990
kernel exposes the cgroup v2 `memory` controller on the root
(`/sys/fs/cgroup/cgroup.controllers` = memory) but Samsung's init never enables
it, so the action is logged as "will be ignored" and the child aborts. Post-boot
the cgroupfs is unreachable even for root+permissive (KSU `su` uid 0, no `avc:`
denials; `+memory`/`mkdir` denied), so the controller can only be enabled at
boot.

The One UI 8.5 cgroup userspace swap (cgroups.json/task_profiles.json/
libcgrouprc.so, commit 0e9b59db) does NOT prevent the abort once baked
(verified on-device after flash; the earlier "module active => 20/20 clean" A/B
was a lifecycle artifact, not a config effect). `cgroups.json` already carries
`memory NeedsActivation:true`/`Optional:true` and it is never activated.

The baked fix adds `prebuilts/samsung/e2sxxx/system/etc/init/cgroupmem.rc`
(pushed into `/system/etc/init` by the cgroup_legacy module) which issues
idempotent `write +memory` to the `cgroup.subtree_control` chain (root, apps,
system) across the `early-init`, `init`, `post-fs-data`, `zygote-start` and
`boot` triggers, before the fs lock engages. Validate after flash that
`/sys/fs/cgroup/cgroup.subtree_control` reads `memory` and that cold-started
Chrome/WebView cycles no longer SIGABRT their app-zygote children.

Note: libchrome.so porting (commits e45eb9a8/aa7969ab) is unrelated to the
crash path and was not part of the fix.

Follow-up (same day, build flashed): the rc activation worked - the kernel
memory controller now reports active on the root, apps and system subtrees,
and fresh AppZygote spawns that previously aborted 100% of the time now mostly
survive (0-1 aborts per 8-14 cold cycles, system_server no longer restarts).
However `libprocessgroup` still logs "JoinCgroup ... memory ... will be
ignored" even with the kernel controller enabled: it treats controllers marked
`NeedsActivation` as inactive unless IT activated them during init, and Samsung
init never performs that activation. The remaining abort ties to that ignored
join. Fix: `cgroups.json`'s memory Cgroups2 entry no longer carries
`NeedsActivation`/`MaxActivationDepth`/`Optional`, so the runtime considers the
controller available and the profile join is applied instead of ignored. This
rides with `cgroupmem.rc` (kernel-side enable). Validate after flash that the
"will be ignored" line no longer appears and cold cycles are 0 aborts.

## Logcat capture prepared again

On 2026-09-19 at 18:51:56 (-0300), the detached persistent `y2s-logcat` tmux
session was recreated with `scripts/capture_logcat_tmux.sh`. The phone was not
connected at startup, so the capture is waiting for ADB and will create a new
`DEVICE_CONNECTED_<date>_<time>` marker automatically when the device becomes
available. The current output file is:

```text
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt
```

Attach with:

```bash
tmux attach -t y2s-logcat
```

## ART/APEX comparison and revised AppZygote diagnosis (2026-09-19)

The ART comparison was completed between the decompressed S926B source,
the original G986B target, and the r11s donor:

```text
S926B source:  com.google.android.art_compressed.apex, versionCode 371000140, SDK 37, lib64 only
r11s donor:    com.google.android.art_compressed.apex, versionCode 361154460, SDK 36, lib + lib64
G986B target:  com.google.android.art_compressed.apex, versionCode 331711080, SDK 33, lib + lib64
```

The inner APEX manifest identifies all three packages as `com.android.art`.
The r11s package is therefore an older Android 16 ART, while the S926B source
framework is Android 17. Replacing the complete S926B ART with r11s would mix
the Android 16 64-bit ART libraries and Java runtime with the Android 17
framework and is not a safe compatibility fix. The r11s package should not be
enabled wholesale merely to provide ARM32 files.

The repository contains a separate module,
`platform/exynos990/patches/runtime32_compat`, whose
`customize.sh` would copy the complete r11s ART APEX. That module is disabled
by its `disable` marker. The active
`platform/exynos990/patches/__desixtification/customize.sh` imports r11s
system libraries and merges Runtime/I18n content, but it does not replace the
ART APEX. The current work-dir ART APEX has the same SHA-256 as the S926B
source APEX, confirming that the observed 2026-09-19 boot was not running the
r11s ART.

This supersedes the earlier hypothesis that the current `zygote-child`
`SIGABRT` was caused solely by the `SystemMemoryProcess` memory join or by an
r11s ART replacement. The A/B test with the profile actions removed still
reproduced the abort. In the latest capture, the child successfully creates
`/sys/fs/cgroup/apps/uid_10248/pid_28075`, receives the cgroup-v2 memory join
warning, and aborts approximately 5 ms later:

```text
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:349717
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:349721
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:349723
```

The subsequent `ZygoteProcess: Connection refused` messages are the
system-server retry loop after the native AppZygote child/service failure;
they are not proof that the regular Java `zygote64` process was the original
fault. The native specialization path still needs to be isolated among
cpuset/task-profile application, seccomp/`NO_NEW_PRIVS`, SELinux context
transition, and capability setup. Audit queue overflow occurs at the same
time, so a native-AppZygote AVC may be missing from the captured log.

The confirmed independent configuration mismatch remains the imported
`SystemServiceCapacityHigh` profile requiring
`/dev/cpuset/foreground-boost`, while the target vendor init does not create
that group. Fix and test that mismatch separately, then compare the child
abort count, the `zygote_next` state, and the connection-refused rate. Do not
activate `runtime32_compat` as an ART fix without first designing an
ARM32-only merge that preserves the S926B ART 64-bit payload.

## Cadeia do Chrome Native AppZygote e causa provável do SIGABRT (2026-09-19)

Uma investigação adicional do APK, do `services.jar` e do logcat confirmou a
cadeia de inicialização usada pelo Chrome. O Chrome principal é iniciado pelo
zygote regular e funciona inicialmente (PID 28010):

```text
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:347603
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:347767
```

O manifesto do Chrome declara `NativeOnlySandboxedProcessService0` como
`nativeService=true`, `isolatedProcess=true` e `useAppZygote=true`. Por isso,
o serviço passa pela seguinte cadeia:

```text
Chrome
  -> services.jar / ProcessList
  -> AppZygote
  -> NativeZygoteProcess
  -> zygote_next
  -> zygote-child
```

As implementações desmontadas confirmam essa rota em
`ProcessList.smali`, `ActiveServices.smali` e `NativeZygoteProcess.smali`; não
foi encontrada uma seleção incorreta do zygote pelo `services.jar`:

```text
out/target/y2s/apktool/system/framework/services.jar/smali/com/android/server/am/ProcessList.smali:14487
out/target/y2s/apktool/system/framework/services.jar/smali/com/android/server/am/ActiveServices.smali:6449
out/target/y2s/apktool/system/framework/framework.jar/smali_classes3/android/os/NativeZygoteProcess.smali:312
```

No boot analisado, `zygote_next` inicia, cria o cgroup do processo nativo e o
filho aborta quase imediatamente:

```text
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:349686
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:349717
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:349723
```

O spam abaixo é consequência da morte do AppZygote: o `system_server` tenta
reconectar ao socket privado que deixou de existir e agenda nova tentativa do
`NativeOnlySandboxedProcessService0`. Não é evidência de que o `zygote64`
regular tenha morrido primeiro:

```text
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:7588824
```

Sem o processo nativo, o Chrome principal não recebe o canal GPU e aborta
depois com `Timed out waiting for GPU channel`. Esse crash é um efeito
posterior da falha do sandbox nativo, não uma prova de que o driver GPU seja a
causa inicial:

```text
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:390960
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:390966
```

O APK em `/product/app/Chrome64` também não é o binário efetivamente usado.
Ele é ignorado porque o Chrome atualizado em `/data/app` tem versão
`801004904`, superior à versão `782710233` da partição `product`:

```text
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:19238
```

O backtrace do crash aponta para `libchrome.so` dentro do APK atualizado em
`/data/app`. Portanto, alterar somente o APK Chrome da `product` não controla
o código nativo que falha durante esse boot.

O teste A/B também mostrou que remover as ações de `SystemMemoryProcess`
silencia o aviso de `JoinCgroup`, mas não elimina o `SIGABRT`: os PIDs 18836 e
19300 continuam abortando mesmo sem o aviso. A causa ainda precisa ser
isolada entre aplicação de task profile/cpuset, capability setup,
seccomp/`NO_NEW_PRIVS`, transição SELinux e bibliotecas nativas. O logcat não
contém o tombstone interno do `zygote-child`, e houve overflow da fila de
auditoria, portanto uma AVC específica pode ter sido perdida.

Os problemas de cgroup permanecem como incompatibilidades independentes:

```text
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:8324
out/target/y2s/boot-diagnostics-20260919-185156/logcat.txt:9256
```

O runtime ainda rejeita `memory_recursiveprot`, apesar de o patch existir no
código-fonte do kernel, e o perfil `SystemServiceCapacityHigh` requer o grupo
`/dev/cpuset/foreground-boost`, que não é criado pela inicialização do alvo.
É necessário validar o hash da imagem `boot.img` realmente flashada e capturar
o tombstone nativo para confirmar qual dessas incompatibilidades participa do
abort.

Próximos testes controlados:

1. Desabilitar/remover temporariamente o Chrome atualizado e testar a versão
   compatível da `product`, mantendo o restante da imagem inalterado.
2. Após um novo abort, preservar imediatamente o tombstone do
   `zygote-child`, além do logcat, para obter a mensagem de abort e o contexto
   nativo.
3. Comparar o hash do `boot.img` flashado com o artefato de kernel que contém
   o patch `memory_recursiveprot`.
4. Corrigir/testar separadamente o perfil `foreground-boost` e comparar a
   contagem de aborts, o estado de `zygote_next` e a frequência de
   `Connection refused`.

Não desviar permanentemente o serviço nativo para o zygote regular nem
desabilitar o sandbox do Chrome: isso reduziria a segurança. Nenhuma alteração
de código foi feita durante esta investigação; esta seção apenas documenta
os resultados e os testes recomendados.

## Adaptação das configurações vendor do zygote do S24+ (2026-09-19)

Foi feita uma comparação completa das referências a `zygote`, `app_zygote`,
`zygote_next`, serviços nativos, propriedades, `task_profiles` e SELinux entre
`out/fw/SM-S926B_EUX/vendor` e o vendor Exynos 990 usado pelo S20+.

O S24+ não possui `zygote_next` na partição `vendor`: não há arquivo `.rc`,
propriedade ou serviço vendor contendo `zygote_next`/`android-native-app`. O
serviço é iniciado exclusivamente pelo system em
`system/etc/init/zygote_next.rc`, através do binário
`/system/bin/zygote_next`. Portanto, nenhum serviço `zygote_next` foi copiado
para o vendor do S20+.

As configurações vendor relevantes encontradas no S24+ foram:

1. `ro.zygote=zygote64` e listas ABI somente arm64, que já eram aplicadas pelo
   módulo de desixtification e agora também ficam explícitas no novo módulo.
2. O seletor BoringSSL vendor que importa
   `boringssl_self_test.${ro.zygote}.rc`. O alvo possuía apenas os gatilhos
   genéricos no `boringssl_self_test.rc`; ele agora usa o mesmo seletor do
   S24+ e recebe `boringssl_self_test.zygote64.rc`, executando somente o
   self-test de 64 bits.
3. Os serviços `boringssl_self_test32_vendor` e
   `boringssl_self_test64_vendor` passaram a declarar explicitamente `user
   root`, como no donor. Os binários continuam sendo os do S20+/Exynos 990;
   nenhum executável do S24+ foi importado.

A adaptação foi isolada em:

```text
platform/exynos990/patches/zygote_vendor_compat/
```

O módulo também registra `file_context-vendor` e `fs_config-vendor` para que
os dois arquivos `.rc` recebam `vendor_configs_file` e permissões 0644. As
variantes vendor `zygote32`, `zygote64_32` e `no_zygote` do S24+ não foram
copiadas porque o alvo foi configurado como arm64-only (`ro.zygote=zygote64`;
`ro.vendor.product.cpu.abilist32` vazio).

A política SELinux do S24+ não foi substituída: as regras `app_zygote` e
`zygote` já existem no vendor alvo com os tipos API 30, e copiar os CIL do S24+
(API 34/SoC diferente) seria incompatível e inseguro. Da mesma forma, o
`task_profiles.json` vendor do S24+ contém perfis EMS específicos do hardware
S5E9945, portanto não foi importado como se fosse configuração de zygote.

Validação estática realizada:

- `ro.zygote` e a ABI final permanecem `zygote64`/arm64-only;
- o vendor não contém referência a `zygote_next` antes nem depois da
  adaptação;
- o novo import BoringSSL aponta para o arquivo `zygote64` correto;
- não foram copiados binários, bibliotecas ou políticas SELinux do S24+.

É necessário gerar e instalar uma nova build para validar no aparelho. O teste
deve verificar se o self-test vendor executa sem erro e, separadamente, se o
Chrome atualizado ainda causa o abort do AppZygote; esta alteração não desvia
o sandbox nativo para o zygote regular.

### Validação da build e do aparelho

A build `out/target/y2s/make_rom-20260919_230510.log` processou o módulo
`Zygote vendor compatibility` e terminou com sucesso em 31min27s. No
`work_dir`, os arquivos gerados são idênticos aos assets do módulo e os
metadados `vendor_configs_file`/0644 foram registrados.

No SM-S926B conectado, a validação em runtime confirmou:

```text
ro.zygote=zygote64
ro.product.cpu.abilist=arm64-v8a
ro.product.cpu.abilist32=[]
ro.vendor.product.cpu.abilist=arm64-v8a
init.svc.zygote=running
init.svc.zygote_next=running
```

O init importou o arquivo vendor selecionado por propriedade e executou
`boringssl_self_test64_vendor` com UID 0; o processo terminou com status 0.
Isso confirma que a adaptação do vendor foi aplicada corretamente.

O smoke test abriu o Chrome atualizado (`versionCode=801004904`,
`153.0.8010.49`) em 2,7s, mas o log ainda registrou `SIGABRT` no
`zygote-child` (PID 22929) e continuou exibindo `ZygoteProcess: Connection
refused`. Portanto, a alteração vendor/BoringSSL entrou e está funcional, mas
não resolve sozinha a falha do AppZygote nativo do Chrome. O downgrade para a
versão da `product` continua sendo o próximo A/B de compatibilidade mais
importante.

## Port do suporte `memory_recursiveprot` do cgroup2 (2026-09-20)

A solicitação para portar as funções cgroup2 do AOSP foi reduzida ao recurso
que realmente está ausente no kernel 4.19 do ExtremeKRNL: a extensão
`memory_recursiveprot`. O kernel já possui o subsistema cgroup2 e os
controladores necessários; substituir todo o cgroup por uma implementação de
um kernel AOSP mais novo teria alto risco de incompatibilidade com o vendor
Exynos 990.

O patch
`platform/exynos990/patches/extremekrnl/patches/0001-accept-memory-recursiveprot-on-legacy-cgroup2.patch`
foi ampliado para portar a implementação funcional, não apenas ignorar a
opção de montagem. Ele agora:

- adiciona `CGRP_ROOT_MEMORY_RECURSIVE_PROT` ao conjunto de flags do root;
- reconhece, aplica e exibe `memory_recursiveprot` nas operações de mount e
  remount do cgroup2;
- anuncia a feature em `/sys/kernel/cgroup/features`;
- porta o cálculo recursivo de proteção para `memory.min` e `memory.low` em
  `mm/memcontrol.c`, preservando o comportamento antigo quando a flag não é
  usada.

Validação realizada:

1. O patch foi aplicado e revertido em uma cópia limpa da árvore do
   ExtremeKRNL, confirmando que pode ser reaplicado pelo `customize.sh` sem
   depender de alterações locais.
2. `kernel/cgroup/cgroup.o` e `mm/memcontrol.o` foram compilados com a
   configuração arm64 do alvo e o Clang 14 usado pelo projeto, sem erros.
3. Nenhuma imagem de boot foi gerada ou flashada nesta etapa.

O próximo teste deve gerar uma nova imagem do kernel, confirmar no aparelho
que a montagem mostra `memory_recursiveprot` e repetir o teste do Chrome/AppZygote.
Esse port melhora a compatibilidade do contrato cgroup2, mas ainda não prova
que ele seja a única causa do `SIGABRT` no `zygote-child`.

## Correção dos perfis cgroup incompatíveis (2026-09-20)

O primeiro boot com `memory_recursiveprot` ativo confirmou o recurso no
kernel, mas revelou dois problemas de integração no userspace:

- `SystemServiceCapacityHigh` apontava para o grupo S24+
  `/dev/cpuset/foreground-boost`, inexistente no vendor do S20+;
- perfis de I/O eram aplicados antes de os grupos
  `/dev/blkio/top`, `high`, `normal` e `low` serem criados pelo `init.rc` em
  `early-fs`.

As correções foram feitas em `prebuilts/samsung/e2sxxx`:

1. `ForegroundBoostCapacityCPUs` e `SystemServiceCapacityHigh` agora usam o
   grupo existente `/dev/cpuset/foreground`, preservando uma política de CPU
   válida sem importar o grupo específico do S24+.
2. `SystemMemoryProcess` voltou a aplicar `JoinCgroup` no grupo v2
   `memory/system`, agora que o kernel instalado expõe `memory` e o boot
   confirmou `cgroup.subtree_control=memory`.
3. `cgroupmem.rc` cria os quatro grupos blkio no `early-init` e ajusta as
   permissões de `cgroup.procs`, eliminando a corrida com os primeiros perfis
   de processo. A criação posterior do vendor continua idempotente.

Validação local:

- `task_profiles.json` passou pelo parser JSON;
- `git diff --check` passou;
- o aparelho confirmou que `normal` já existe depois do boot, enquanto
  `foreground-boost` não existe, validando a escolha do fallback para
  `foreground`.

Ainda não foi gerada uma nova build após essa alteração. O próximo boot deve
ser verificado para confirmar a ausência de `foreground-boost/tasks` e a
redução dos avisos `blkio/normal/cgroup.procs`; o aviso do kernel
`mem_cgroup_update_lru_size(... lru_size -1)` deve ser acompanhado
separadamente, pois não é causado diretamente por esses perfis.

## Isolamento pós-fork do AppZygote (2026-09-20)

Foi repetido um teste controlado no SM-S926B após a criação dos grupos blkio.
Os perfis que o zygote nativo usa (`CPUSET_SP_DEFAULT`,
`SCHED_SP_DEFAULT`, `CPUSET_SP_FOREGROUND`, `SCHED_SP_FOREGROUND`,
`CPUSET_SP_TOP_APP`, `SCHED_SP_TOP_APP` e `SystemMemoryProcess`) foram
aplicados a processos temporários com `/system/bin/settaskprofile` e todos
retornaram `Profile ... is applied successfully`/`rc=0`. Os grupos relevantes
(`/dev/blkio/high`, `/dev/blkio/normal`, `/dev/cpuctl/foreground`,
`/dev/cpuset/foreground` e `/dev/cpuset/top-app`) existem no aparelho, e os
hashes de `task_profiles.json` e `cgroups.json` instalados coincidem com os
arquivos gerados em `work_dir`.

Ao iniciar o Chrome 153.0.8010.49, o filho ainda aborta sempre no mesmo ponto:

```text
libprocessgroup: Created cgroup /sys/fs/cgroup/apps/uid_10248/pid_<pid>
libprocessgroup: A JoinCgroup action in the SystemMemoryProcess profile is used for controller memory in the cgroup v2 hierarchy and will be ignored
libc: Fatal signal 6 (SIGABRT) ... (zygote-child)
```

O intervalo entre o aviso do perfil e o `SIGABRT` foi de aproximadamente 7 ms,
sem erro de cgroup, AVC ou GPU. O `crash_dump64` também não consegue gerar um
tombstone desse filho (`capset failed: Operation not permitted`), portanto a
ausência de backtrace não identifica a função que abortou. O kernel expõe
`CONFIG_SECCOMP=y`/`CONFIG_SECCOMP_FILTER=y`, `cap_last_cap=37` e o zygote
regular/nativo permanece vivo; não há evidência de que `clone3` seja exigido
(o zygote AOSP Android 17 usa `fork` nessa revisão).

A comparação dos manifestos mostra a diferença relevante entre a versão que
funcionava na partição `product` e a atualização que falha. Ambas usam
`NativeOnlySandboxedProcessService0/1` com `useAppZygote=true` e
`nativeService=true`, porém:

| versão | preload Java | biblioteca do NativeService |
| --- | --- | --- |
| 149.0.7827.102 (product) | `org.chromium.chrome.app.TrichromeZygotePreload` | `libmonochrome_64.so` |
| 153.0.8010.49 (atualizada) | `org.chromium.content_public.app.ZygotePreload` | `libchrome.so` |

Isso desloca a hipótese principal para a especialização/carregamento do
NativeService da biblioteca Chrome nova em conjunto com o zygote nativo, não
para a criação do cgroup2. O próximo A/B deve instalar somente o Chrome da
`product` (mantendo o restante da build) e repetir o mesmo smoke test; se o
`zygote-child` sobreviver, o kernel/cgroup fica descartado como causa primária
e a investigação deve comparar os requisitos nativos de `libchrome.so` com
`libmonochrome_64.so`.

## Validação da nova beta e escopo do spam do AppZygote (2026-09-20)

O log `logcat_android_20260920_212440.log` mostra que a nova beta melhorou o
início do sistema: `zygote64` (PID 7381) e `zygote_next` (PID 7505) são
iniciados normalmente e continuam presentes no relatório do watchdog. Não há
spam de `ZygoteProcess` durante o boot; o primeiro erro só aparece quando o
Chrome é aberto.

O problema, entretanto, não foi eliminado. O Chrome instalado é a versão
153.0.8010.49 (versionCode 801004904), que substitui a cópia antiga da
`product` (782710233). Ao criar o processo nativo isolado, ocorreram:

- `19.200` mensagens `Got error connecting to zygote` entre 21:24:56 e
  21:26:43;
- dois `Fatal signal 6 (SIGABRT)` em processos `zygote-child` (PIDs 20658 e
  21165), aproximadamente 7 ms depois do aviso de `SystemMemoryProcess`;
- falhas de `capset`/capacidades no `crash_dump64`, sem tombstone útil;
- timeout de canal GPU no processo principal do Chrome, consequência da morte
  do filho nativo;
- `WATCHDOG KILLING SYSTEM PROCESS` em `ActivityManager:procStart`, seguido de
  `PLATFORM WATCHDOG RESET`.

Portanto, a nova beta deslocou o sintoma para o caminho de inicialização do
Chrome/AppZygote, mas ainda não corrigiu a incompatibilidade. O aviso de
`JoinCgroup` em `SystemMemoryProcess` continua sendo apenas um aviso de ação
de memória ignorada na hierarquia cgroup v2; o abort ocorre logo depois e não
há evidência, neste log, de que o `zygote64` regular ou a criação básica dos
cgroups seja a causa primária. O próximo A/B deve manter o restante da build e
instalar somente o Chrome/Trichrome da `product`, comparando o caminho antigo
(`libmonochrome_64.so`) com o atual (`libchrome.so`).

Observação de reprodução: a árvore usada para esta análise contém o arquivo
vazio `platform/exynos990/patches/cgroup_legacy/disable`. O executor de módulos
ignora qualquer módulo que possua esse marcador; portanto, se ele estava
presente no momento da build, o `cgroup_legacy/customize.sh` não foi aplicado.

### Tombstone do processo principal do Chrome

O tombstone de 20/09 às 21:25:34 pertence ao processo principal do Chrome
(`pid 20607`, `ppid 7381`), não ao `zygote-child`. Ele registra `SIGTRAP` com a
mensagem fatal do Chromium:

```text
[FATAL:content/browser/gpu/browser_gpu_channel_host_factory.cc:49]
Timed out waiting for GPU channel.
```

Os frames nativos apontam para `libchrome.so` da versão 153.0.8010.49. Isso é
um abort intencional do Chromium após não receber o canal do processo GPU; o
`Data Abort` exibido no ESR não deve ser interpretado isoladamente como uma
falha de memória do kernel. A sequência causal permanece: o processo nativo
do AppZygote (`zygote-child`) aborta primeiro, o processo GPU não fica
disponível, o Chrome dispara o timeout e só então gera esse tombstone.

## Nova captura com Chrome/WebView da `product` (2026-09-20)

O arquivo `logcat_android_20260920_213635.log` contém três ciclos do mesmo
softreboot. A captura confirmou que trocar somente o Chrome atualizado não
resolve o problema:

- o Chrome 153 da partição `/data` falha com `libchrome.so`;
- depois, o Chrome 149 da `product` é realmente carregado de
  `/product/app/Chrome64/Chrome64.apk`, usando
  `/product/app/TrichromeLibrary64/TrichromeLibrary64.apk!libmonochrome_64.so`;
- mesmo com essa versão antiga, o processo `zygote-child` aborta e o Chrome
  termina com o mesmo `Timed out waiting for GPU channel`.

Isso descarta a versão específica de `libchrome.so` como causa suficiente. O
problema comum é o caminho `NativeOnlySandboxedProcessService`/AppZygote e a
especialização do processo no sistema/kernel atual.

Há também uma falha de configuração que precisa ser corrigida antes de novos
A/Bs. Na inicialização do zygote e após cada watchdog, o `init` registra:

```text
SetCgroup::ExecuteForTask: failed to open /dev/cpuset/foreground-boost/tasks
Failed to apply SystemServiceCapacityHigh task profile
init: failed to set task profiles
```

O grupo `foreground-boost` não existe no S20+. O arquivo vazio
`platform/exynos990/patches/cgroup_legacy/disable` faz o executor ignorar o
módulo que substitui esse perfil pelo grupo existente `foreground`; portanto,
essa build foi testada sem a correção de perfis. O próximo teste deve remover
esse marcador (ou habilitar o módulo corretamente), confirmar no log que não há
mais `foreground-boost`, e só então repetir o teste do Chrome antigo.

O WebView também não foi totalmente validado como `product`: o log mostra a
cópia `/product` (versionCode 777821504) sendo ignorada porque há uma versão
`/data` mais nova (155.0.8059.4, versionCode 805900413). O WebView 155 consegue
criar um sandbox regular, mas isso não testa o caminho NativeOnly/AppZygote do
Chrome.

## Auditoria do módulo `cgroup_legacy` (2026-09-20)

O módulo não foi aplicado na build usada no log. O arquivo vazio
`platform/exynos990/patches/cgroup_legacy/disable` faz
`scripts/internal/apply_modules.sh` retornar antes de executar o
`customize.sh`. Isso é confirmado pelos artefatos da build: o
`task_profiles.json` ainda aponta `ForegroundBoostCapacityCPUs` e
`SystemServiceCapacityHigh` para `foreground-boost`, o `cgroupmem.rc` não está
no `work_dir`, e o `cgroups.json` ainda marca o controlador `memory` como
`Optional`.

Quando habilitado, o módulo deve corrigir a parte de perfis legados: o arquivo
doador troca `SystemServiceCapacityHigh` para `cpuset/foreground` e
`NormalIoPriority` para `blkio/normal`, grupos que existem no S20+. O
`cgroupmem.rc` tenta ativar `memory` em `/sys/fs/cgroup`, `apps` e `system` em
vários estágios do boot. Isso pode eliminar as falhas de
`foreground-boost`/`NormalIoPriority`, mas não prova sozinho que o
`zygote-child` deixará de abortar: o Android continua emitindo o aviso de que
`SystemMemoryProcess` em `memory` na hierarquia v2 será ignorado, e o arquivo
não cria os nós `apps`/`system` caso eles não existam.

O módulo também copia `libchrome.so` para `/system/lib64` e `/vendor/lib64`,
mas isso não substitui as bibliotecas embarcadas nos APKs do Chrome/WebView
(`libmonochrome_64.so` no Chrome da `product` ou `libchrome.so` dentro do APK
atual). Portanto, essa cópia não é uma correção direta do crash do Chromium e
deve ser validada por ABI antes de ser mantida.

Conclusão: o módulo é uma correção plausível e específica para o erro de
perfis/cgroups observado, porém a captura atual não o testou. O A/B correto é
remover o marcador `disable`, reconstruir, verificar no log a ausência de
`foreground-boost`/`Failed to apply SystemServiceCapacityHigh`, e só então
avaliar novamente o `zygote-child`, o canal GPU e o softreboot.

## Incompatibilidade adicional da pilha gráfica (2026-09-20)

O timeout do Chromium não deve ser tratado apenas como mensagem secundária.
Pouco antes do primeiro `zygote-child` abortar, o Chrome pede
`android.hardware.graphics.allocator.IAllocator/default`, mas o
`servicemanager` informa que essa instância não existe no VINTF. O mesmo aviso
aparece durante o boot para `surfaceflinger`, `bootanim`, `mediaswcodec` e
outros clientes, portanto é uma incompatibilidade sistêmica, não exclusiva do
Chrome.

O vendor do S20+ declara somente a implementação HIDL antiga:
`android.hardware.graphics.allocator@2.0::IAllocator/default`,
`android.hardware.graphics.composer@2.3::IComposer/default` e
`android.hardware.graphics.mapper@2.1::IMapper/default` em
`vendor/etc/vintf/manifest.xml`. O serviço correspondente também é HIDL em
`android.hardware.graphics.allocator@2.0-service.rc`. Já a pilha de sistema
trazida do S24+ contém clientes AIDL (`IAllocator`/`IComposer`) e tenta
consultar essas instâncias AIDL.

O módulo `unica/mods/legacy_graphics_mapper` só remove a barreira de nível
de API para permitir o fallback interno Gralloc 3/2 do `libui`; ele não cria
um serviço AIDL nem corrige o VINTF. Na imagem atualmente analisada, os bytes
do gate ainda estão no estado original, então esse fallback também não foi
aplicado. O kernel Mali e o `vendor.gralloc-2-0` chegam a iniciar e há várias
alocações bem-sucedidas, mas isso não elimina a falha de descoberta da
interface gráfica.

Não é correto apenas adicionar `IAllocator/default` AIDL ao manifesto: isso
publicaria um serviço que o vendor não implementa. A correção precisa ser uma
destas duas opções, validada em A/B: fazer `libgui`/`libui` usar de fato o
fallback HIDL 2.0/2.1 compatível com o vendor, ou portar/fornecer uma ponte
AIDL real para allocator/composer/mapper. O erro `Timed out waiting for GPU
channel` deve ser reavaliado depois dessa compatibilidade e da ativação do
`cgroup_legacy`; ele pode ser consequência da falha de inicialização do
processo GPU, não uma falha física do Mali.

## Comparação com `MonsterROM/framework_compat` (2026-09-20)

O patch enviado por `devcore94/MonsterROM` confirma a mesma incompatibilidade
de geração. `0001-Avoid-unsupported-AIDL-HAL-probes.patch` remove de
`Watchdog.smali` as entradas AIDL
`android.hardware.graphics.allocator.IAllocator/` e
`android.hardware.graphics.composer3.IComposer/`, além de fazer o
`AudioService` usar diretamente o fallback HIDL quando o serviço AIDL de áudio
não existe.

O nosso `services.jar` contém exatamente essas sondagens em
`smali/com/android/server/Watchdog.smali` e o mesmo teste AIDL/HIDL em
`smali/com/android/server/audio/AudioService.smali`, portanto o patch é um
candidato plausível para ser portado como patch de `services.jar`, após
validar o contexto e os registradores da revisão atual.

Esse patch reduz sondagens e mensagens de VINTF do framework, mas não corrige
o crash do GPU por si só. No nosso log, a requisição que precede o abort vem do
próprio processo Chrome (`uid=10248`), não do `Watchdog`; o patch não toca
`libgui`, `libui`, `gralloc`, `mapper` nem fornece um servidor AIDL. Portanto,
ele deve ser tratado como uma correção complementar para o spam/framework,
enquanto a compatibilidade gráfica HIDL/AIDL continua sendo necessária para
resolver o canal GPU.

## Validação da beta `logcat_android_20260920_223614.log` (2026-09-20)

Nesta build o módulo `cgroup_legacy` entrou: o `init` processou
`/system/etc/init/cgroupmem.rc` (linha 8167) e não há mais falha de
`foreground-boost` nem de `SystemServiceCapacityHigh`. Restam somente a
condição de corrida inicial de `NormalIoPriority` (o nó
`/dev/blkio/normal/cgroup.procs` ainda não existe nas linhas 8457–9180) e o
aviso esperado de que `SystemMemoryProcess` não pode aplicar `memory` na
hierarquia cgroup v2.

O problema funcional, porém, continua. O Chrome (`pid=19194`) consegue criar
janela/superfície e há várias alocações `mali_gralloc_allocate` bem-sucedidas;
ele também percorre o fallback (`mapper 4.x` e `mapper 3.x` não suportados,
seguido de `Arm Module v1.0`). Logo, a ausência AIDL do allocator é um
problema de compatibilidade e gera spam, mas não impediu toda a renderização.

A sequência determinante é: `zygote-child` 19243 aborta com `SIGABRT` em
22:36:31.318, o framework repete `Connection refused`, o Chromium encerra
com `Timed out waiting for GPU channel` em 22:37:07.045 e, após nova tentativa
do child 19677, o `system_server` fica bloqueado em
`AppZygote.connectToZygoteIfNeededLocked` até o `PLATFORM WATCHDOG RESET` de
22:38:13.577. O tombstone do primeiro child não traz a causa porque o
`crash_dump64` não conseguiu abrir `/proc/19243`; portanto ainda não há prova
de que o kernel/Mali seja o responsável direto.

Também confirmei que o patch `framework_compat` do MonsterROM ainda não foi
aplicado nesta imagem: `services.jar` continua contendo as sondagens AIDL em
`Watchdog.smali`. Aplicá-lo pode eliminar as sondagens do framework, mas não
deve ser considerado correção do `zygote-child`/GPU, pois o Chrome faz a
requisição gráfica diretamente.

Conclusão da nova build: o ajuste de perfis cgroup resolveu aquele ramo de
erros, mas não resolveu o softreboot. O próximo teste deve separar as
variáveis: (1) corrigir a criação tardia de `/dev/blkio/normal`, (2) aplicar o
patch `framework_compat` isoladamente e (3) capturar o child com tombstone
válido para descobrir o motivo do `SIGABRT`, sem adicionar um serviço AIDL
falso ao VINTF.

## Rastreamento do timeout GPU até o kernel (2026-09-20)

O caminho mostrado pelo tombstone não é um arquivo do kernel. O binário que
dispara o abort é
`/product/app/TrichromeLibrary64/TrichromeLibrary64.apk!libmonochrome_64.so`,
com a string de origem `../../content/browser/gpu/browser_gpu_channel_host_factory.cc`
e a mensagem em `:49`. A cópia correspondente existe em
`out/target/y2s/work_dir/product/app/TrichromeLibrary64/TrichromeLibrary64.apk`;
ela está stripped, mas `strings` confirma tanto o caminho quanto a mensagem.

Essa linha é um watchdog do Chromium, não o watchdog do Mali: ele chama
`LOG(FATAL)` quando o canal IPC com o processo GPU não é estabelecido. No log,
o primeiro `zygote-child` morre às 22:36:31.318 e o Chromium aborta às
22:37:07.045, intervalo de aproximadamente 35,7 s. Isso coincide com o
temporizador de Android do Chromium (watchdog do GPU mais fator de reinício e
5 s), portanto o timeout é consequência de o processo sandbox/GPU não chegar
ao estado de canal pronto.

O kernel usado pela imagem foi localizado e confirmado no próprio artefato:
`out/target/y2s/work_dir/kernel/boot.img` contém um `Image` de 43.241.488
bytes, versão `4.19.325-cip119-st3-ExtremeKRNL-Nexus-v1+`, igual ao
`out/kernel_tmp-exynos990/build/out/y2s/Image`. O driver GPU correspondente é
`drivers/gpu/arm/bv_r38p1` (Mali DDK r38p1), e a inicialização registrada é
`mali 18500000.mali: GPU identified as 0x0 arch 9.0.8 r0p1`.

Há uma incompatibilidade real no lado do kernel/DT, mas ela não é a linha que
gera o timeout do Chromium: o driver imprime `No OPPs found in device tree!
Scaling timeouts using 100000 kHz` porque o DT y2s usa a tabela Samsung
`gpu_dvfs_table` e não fornece um `operating-points-v2` aceito pelo Mali. O
código que emite essa mensagem é
`drivers/gpu/arm/bv_r38p1/mali_kbase_core_linux.c:3319-3354`; ele apenas
escolhe a frequência de referência para calcular timeouts internos do driver.
Também estão desativados `CONFIG_MALI_DMA_FENCE` e
`CONFIG_MALI_DMA_BUF_MAP_ON_DEMAND`, mas o log mostra alocações
`mali_gralloc_allocate` bem-sucedidas e não mostra fault/reset/fence do Mali.

Conclusão: o arquivo do Chromium mostra exatamente por que ele responde com
`Timed out waiting for GPU channel`, mas não aponta para um arquivo-fonte do
kernel. A cadeia observada é `AppZygote/zygote-child` abortado → nenhum canal
GPU pronto → watchdog do Chromium → abort do Chrome → espera do
`system_server`. O próximo teste deve capturar a causa do `SIGABRT` do
`zygote-child`; alterar apenas a frequência/timeout do Mali ou a linha 49 do
Chromium esconderia o sintoma sem fazer o processo sandbox iniciar.

## Aplicação do patch `framework_compat` do MonsterROM (2026-09-20)

Foi adicionado o módulo
`platform/exynos990/patches/framework_compat/` com o patch revisado enviado
por `devcore94/MonsterROM`:
`smali/system/framework/services.jar/0001-Avoid-unsupported-AIDL-HAL-probes.patch`.
O conteúdo foi mantido, incluindo o cabeçalho Git e os créditos originais:
autor `ditternation <ditternation@localhost>`. `devcore94` é a origem do
patch no MonsterROM; At30c não é o autor dessa alteração.

O patch remove de `Watchdog.smali` somente as sondagens AIDL de áudio e
gráficos que o vendor Exynos 990 não implementa, e elimina de `AudioService`
o teste de `android.hardware.audio.core.IModule/default` antes do fallback
HIDL. Ele será aplicado automaticamente por `scripts/internal/apply_modules.sh`
antes dos módulos `unica`, seguindo a convenção `smali/.../*.jar/*.patch`.

Validação feita contra o `services.jar` atualmente decodificado:

```text
git diff --check
git apply --check --directory=out/target/y2s/apktool/system/framework/services.jar \
  --unsafe-paths platform/exynos990/patches/framework_compat/smali/system/framework/services.jar/0001-Avoid-unsupported-AIDL-HAL-probes.patch
```

Ambas passaram. A alteração ainda precisa de uma nova build para entrar no
`services.jar` flashável. O patch reduz as consultas VINTF ausentes do
framework e força o fallback HIDL de áudio; não cria um servidor AIDL e não
é, isoladamente, uma correção comprovada para o `zygote-child`/timeout GPU.

## Validação da build com `framework_compat` instalado (2026-09-20 23:48)

A build usada na captura `logcat_android_20260920_234820.log` realmente
contém o patch: `out/target/y2s/make_rom-20260920_225943.log` registra
`Processing "Framework compatibility" by @ditternation` e
`Applying "Avoid unsupported AIDL HAL probes"` ao `services.jar`.

O boot desta imagem chega a `sys.boot_completed=1` às 23:45:46. O kernel é o
ExtremeKRNL `4.19.325-cip119-st3-ExtremeKRNL-Nexus-v1+`, build `#9`. O módulo
`cgroup_legacy` continua ativo: não há mais `foreground-boost` nem falha de
`SystemServiceCapacityHigh`; resta apenas o aviso esperado de que
`SystemMemoryProcess` não consegue aplicar o controlador `memory` na
hierarquia cgroup v2.

O teste do Chrome reproduz o problema em duas tentativas:

```text
23:48:39.066  JoinCgroup(SystemMemoryProcess) ignorado
23:48:39.073  zygote-child 19780: SIGABRT
23:49:14.697  Chrome 19724: Timed out waiting for GPU channel
23:49:45.516  JoinCgroup(SystemMemoryProcess) ignorado
23:49:45.518  zygote-child 20226: SIGABRT
23:50:18.151  system_server bloqueado em ActivityManager:procStart por 71 s
23:50:18.193  PLATFORM WATCHDOG RESET
```

O `crash_dump64` falha novamente ao abrir `/proc/19780` e `/proc/20226`,
portanto ainda não há backtrace do processo que realmente aborta. O Chrome
principal, entretanto, gera tombstone válido e confirma o mesmo abort
intencional de Chromium em `browser_gpu_channel_host_factory.cc:49`, usando
`/product/app/TrichromeLibrary64/TrichromeLibrary64.apk!libmonochrome_64.so`.
O stack do watchdog agora fecha o elo restante: `system_server` fica preso em
`ZygoteProcess.waitForConnectionToNativeZygote` →
`AppZygote.connectToZygoteIfNeededLocked` enquanto o socket do AppZygote está
recusando conexões.

Conclusão desta A/B: o patch de compatibilidade foi aplicado corretamente e
reduz somente as sondagens do `Watchdog`/áudio do framework; ele não altera a
requisição AIDL gráfica feita diretamente pelo Chrome e não corrige o abort do
`NativeOnlySandboxedProcessService`. O processo Chrome chega a criar janela,
Surface e carregar Vulkan antes da morte do child; não há fault/reset do Mali
no intervalo. A causa primária continua sendo a inicialização do
`zygote-child`/AppZygote nativo, ainda sem tombstone útil, e o timeout GPU e o
softreboot permanecem consequências.

## Captura manual durante a inicialização do Chrome (2026-09-20 23:58)

Foi feita uma captura direcionada com o aparelho conectado e `su` disponível,
iniciando simultaneamente `logcat -b all`, `dmesg -w`, snapshots de processos,
lista de tombstones e, depois, executando:

```text
adb shell am force-stop com.android.chrome
adb shell am start -W -n com.android.chrome/com.google.android.apps.chrome.Main
```

A abertura retornou `Status: ok`, `LaunchState: COLD` e `TotalTime: 2347` ms.
Os artefatos estão em
`out/target/y2s/manual-chrome-capture-20260920-235817/` (`logcat.txt`,
`dmesg.txt`, `process-snapshots.txt`, `crash-buffer-final.txt`,
`tombstones.latest` e `launch.txt`).

A sequência reproduzida foi:

```text
23:58:21.618  zygote-child 3399 cria cgroup uid_10248/pid_3399
23:58:21.620  SystemMemoryProcess: controlador memory ignorado no cgroup v2
23:58:21.627  zygote-child 3399: SIGABRT
23:58:57.316  Chrome 3294: Timed out waiting for GPU channel
23:58:58.107  Chrome 3294: SIGTRAP; abort de browser_gpu_channel_host_factory.cc:49
23:59:27.932  zygote-child 5968 cria cgroup uid_10248/pid_5968
23:59:27.942  zygote-child 5968: SIGABRT
```

Durante o intervalo houve 12.860 mensagens `ZygoteProcess: Got error connecting
to zygote, retrying. msg= Connection refused`, seguidas de falha explícita no
socket `com.android.internal.os.AppZygoteInit/...` e nova tentativa de iniciar
`NativeOnlySandboxedProcessService0`. O Chrome principal chegou a criar janela,
Surface e carregar `libmonochrome_64.so`/Vulkan antes do timeout. O `dmesg` não
registrou fault, reset ou fence do Mali; os `capset failed` pertencem ao
`crash_dump64` depois que o child já havia desaparecido. O polling de processos
não capturou um snapshot do child porque ele termina em poucos milissegundos.

Conclusão: a captura manual confirma que o primeiro evento é o `SIGABRT` do
`zygote-child`/AppZygote; o erro de GPU do Chrome ocorre cerca de 36 s depois e
é consequência da ausência do processo sandbox/canal GPU. Ainda não há
tombstone/backtrace do child para apontar a instrução exata; a próxima coleta
deve observar o fork/abort com instrumentação mais próxima do processo.

## Auditoria completa de `crash_dump64` e capabilities (2026-09-21)

O spam de `capset failed` não é o primeiro erro. Na captura manual, o filho do
Chrome (UID 10248) aborta primeiro (`zygote-child` 3399 às 23:58:21.627 e
5968 às 23:59:27.942). Depois disso, o handler de sinal do Bionic cria o helper
3407/5970. Em `external/android-tools/vendor/core/debuggerd/handler/debuggerd_handler.cpp`,
`raise_caps()` copia `CapPrm` para `CapInh`, chama `capset()` e tenta elevar
cada bit para o conjunto ambient antes de executar `crash_dump64`. Por isso o
log mostra um `capset failed` seguido de dezenas de `failed to raise ambient
capability`.

O kernel retorna `-EPERM` quando o novo conjunto herdável contém bits fora do
bounding set (`out/kernel_tmp-exynos990/security/commoncap.c`) ou quando um
bit ambient não está simultaneamente em `CapPrm` e `CapInh`. O estado de
capabilities deixado pelo child/sandbox não é compatível com essa preparação,
mas isso é consequência do abort, não a evidência de que `crash_dump64` o
causou. Em seguida o helper tenta abrir `/proc/<pid>` e encontra `ENOENT`, pois
o child já saiu. O mesmo `crash_dump64` realiza vários dumps normais de outros
processos na mesma captura, portanto não há falha global do helper.

Há uma hipótese adicional para a causa primária: o sandbox Linux do Chromium
usa `capset()` para remover capabilities e valida o resultado. Isso torna o
`SIGABRT` do child compatível com uma falha na inicialização do sandbox, mas
ainda é necessário capturar `CapInh/CapPrm/CapEff/CapBnd/CapAmb`, `NoNewPrivs`
e `Seccomp` do child para confirmar. O Chrome foi criado pelo `zygote64`
(PID 20560), não diretamente pelo `zygote_next`; o `zygote_next` (PID 7476)
está ativo separadamente. Mesmo assim, o serviço `zygote_next` é `user root`
sem uma diretiva `capabilities`, portanto deve ser auditado antes de ser usado
para iniciar processos nativos.

Não foi aplicado patch de supressão de logs: alterar `debuggerd_handler.cpp`
sem reconstruir o `com.android.runtime.apex` apenas esconderia a evidência e
não corrigiria o abort do Chrome. O próximo teste deve coletar os conjuntos de
capabilities/seccomp durante o fork e fazer uma A/B com o caminho do sandbox.

## Linha de investigação do `SIGABRT` no native child (2026-09-21)

A cadeia nativa foi confrontada com o código do Android 17: Chrome inicia
`NativeOnlySandboxedProcessService` através de `AppZygote`; o serviço usa o
socket reservado `zygote_next`, que executa a espécie `android-native-app`. No
filho, o `re_initialize_prologue` da espécie cria o cgroup, instala o filtro
seccomp de app-zygote e só depois chama `PR_SET_NO_NEW_PRIVS`; a troca de UID e
a transição SELinux vêm ainda depois. Referências oficiais: [child_process.rs](https://android.googlesource.com/platform/system/zygote/+/refs/heads/android17-release/zygote/src/child_process.rs), [android_native.rs](https://android.googlesource.com/platform/system/zygote/+/refs/heads/android17-release/zygote/src/species/android_native.rs) e [server.rs](https://android.googlesource.com/platform/system/zygote/+/refs/heads/android17-release/zygote/src/server.rs).

Isso isolou uma hipótese testável e mais forte que o cgroup: o kernel entregue
tem `CONFIG_SECCOMP=y`, `CONFIG_SECCOMP_FILTER=y`, BPF e JIT habilitados
(`out/kernel_tmp-exynos990/out/.config:459,660-661`), mas o próprio
`kernel/seccomp.c:382-390` recusa instalar um filtro com `-EACCES` se o processo
não tiver `CAP_SYS_ADMIN` efetivo e ainda não tiver `NoNewPrivs`. A biblioteca
instalada contém `set_app_zygote_seccomp_filter` e a mensagem fatal
`Could not set seccomp filter of size`, confirmando que essa etapa está no
artefato usado pela ROM (`system/lib64/libseccomp_policy.so`). O caminho AOSP
de instalação está documentado em [seccomp_policy.cpp](https://android.googlesource.com/platform/bionic/+/master/libc/seccomp/seccomp_policy.cpp).

O `SIGABRT` imediato, sem `SIGSYS`, é compatível com esse `PLOG(FATAL)` caso o
`prctl(PR_SET_SECCOMP)` receba `EPERM/EACCES`, mas a captura não contém ainda a
mensagem fatal porque o child dura poucos milissegundos e a auditoria já estava
perdendo milhares de eventos. Portanto isto é uma causa provável, não uma
confirmação final. A política SELinux dá `sys_admin` a `zygote_next`
(`plat_sepolicy.cil:83292-83335`), e o serviço é `user root` sem diretiva
`capabilities` em `system/etc/init/zygote_next.rc:1-6`; falta verificar o estado
real herdado em `/proc` (`CapEff`, `CapBnd`, `NoNewPrivs` e `Seccomp`). Política
SELinux permissiva não prova que a capability esteja efetiva no processo.

Os erros de `SystemMemoryProcess`, `/dev/blkio` e `crash_dump64` continuam
secundários: o cgroup do child é criado antes do abort, o helper só roda depois
que o PID desaparece, e os perfis agregados ignoram falhas dos subperfis. Não
foi aplicado patch; o próximo teste precisa capturar o estado do `zygote_next`
e, se possível, o `logcat -b crash` imediatamente durante a abertura do Chrome.

Um detalhe adicional torna o teste de capability prioritário: o `raise_caps()`
do handler não enumera `CapEff`; ele copia `CapPrm` para `CapInh` e depois tenta
elevar o conjunto ambient. A lista observada (0–5 e 9–37) mostra que o child
carregava esses bits no conjunto permitido, mas o `capset` falhou porque pelo
menos um deles não cabia no bounding set. Isso não prova que
`CAP_SYS_ADMIN` (bit 21) estava efetivo no instante do `PR_SET_SECCOMP`; é
precisamente `CapEff` e `CapBnd` que precisam ser medidos no `zygote_next`/fork.

## Teste diferencial após o watchdog (2026-09-21)

O dumpstate do watchdog mostrou que o evento não era isolado: o mesmo ciclo se
repetia em horários diferentes — `zygote-child` aborta, o `AppZygote` perde a
conexão, `ActivityManager:procStart` fica bloqueado por 70 segundos e o
Watchdog reinicia o `system_server` (`PLATFORM WATCHDOG RESET`). Isso explica o
spam posterior de `ZygoteProcess: ... Connection refused`: ele é consequência
do zygote reiniciado, não a origem do primeiro aborto.

Foi feita uma verificação ao vivo depois do reset. Tanto `zygote_next` (PID
7476) quanto `zygote64` (PID 11067) estavam com `CapPrm`, `CapEff` e `CapBnd`
iguais a `0x3fffffffff`, `NoNewPrivs=0` e `Seccomp=0`. Portanto, a hipótese de
que o zygote pai simplesmente não possuía `CAP_SYS_ADMIN` foi descartada para
esse estado em execução. O `zygote_next` também tem regras SELinux explícitas
para `setpcap`, `sys_admin` e cgroup v2. O child ainda precisa ser observado no
instante do fork; o estado do pai não prova que a transição de capabilities e
seccomp do filho terminou corretamente.

O sandbox comum do WebView continua funcionando (`webview_zygote` com
`NoNewPrivs=1`, `Seccomp=2`, e processos isolados criados normalmente). Isso
estreita o problema para a especialização do caminho nativo/AppZygote usado pelo
Chrome, e não para todos os sandboxes do sistema.

Foram repetidos dois testes de abertura do Chrome, cada um com captura por mais
de um minuto. Um usou flags de renderização por software e o outro usou a
abertura normal. Ambos abriram `ChromeTabbedActivity`; o teste normal criou o
`com.android.chrome_zygote`, o processo principal, `sandboxed_process0` e
`privileged_process0`, sem novo `zygote-child`, `SIGABRT`, `crash_dump64`,
`capset`, timeout de GPU ou watchdog. Assim, a falha não foi reproduzida nessa
sessão; isso não demonstra que o patch do cgroup resolveu a causa, apenas que o
estado pós-reset está estável. O teste com flags não permite atribuir causalidade
à GPU porque a sintaxe de flags do Chrome ainda não foi confirmada.

Conclusão operacional atual: `crash_dump64` continua sendo um observador
secundário, e o erro de GPU só deve ser tratado como causa primária se voltar a
aparecer sem o `SIGABRT` anterior. A próxima coleta útil é reproduzir a falha a
frio com logcat limpo e instrumentar especificamente a instalação do filtro
seccomp/transição de capabilities do `android-native-app`; aplicar um patch de
silenciamento no handler ou no cgroup neste momento esconderia a evidência.

## Comparação entre navegadores Chromium (2026-09-21)

O aparelho não possui Firefox instalado neste momento, portanto não foi possível
fazer uma comparação direta com Gecko. Ele possui, porém, o Samsung Internet
(`com.sec.android.app.sbrowser`), que também usa Chromium. Após encerrá-lo e
abri-lo com captura limpa por 55 segundos, ele criou normalmente o processo
principal, `sandboxed_process0` e `privileged_process0` — inclusive um segundo
`sandboxed_process0` — sem `zygote-child`, `SIGABRT`, `crash_dump64`, `capset`,
timeout de GPU ou watchdog.

Os processos do Samsung Internet exibiram a mesma assinatura de sandbox esperada
do Chromium: `Seccomp=2`, capabilities zeradas; os processos isolados tinham
`NoNewPrivs=1`. O Chrome apresentou a mesma arquitetura no teste anterior. Há
uma ressalva importante: essa captura só mostrou `SandboxedProcessService`; ela
não mostrou `NativeOnlySandboxedProcessService`, que é justamente o caminho
AppZygote/nativo associado ao aborto observado anteriormente. Portanto o teste
prova que o sandbox Chromium comum funciona, mas ainda não valida o caminho
nativo que está sob suspeita; também não há evidência de que todo Chromium seja
inevitavelmente incompatível com o kernel.

A correlação com “Chromium falha, Firefox funciona” continua útil para priorizar
`AppZygote`/seccomp/capabilities e a inicialização dos processos nativos, mas não
isola ainda qual etapa quebra no boot problemático. O próximo A/B conclusivo deve
ser feito após reinicialização, com Chrome e Samsung Internet iniciados antes de
qualquer outro navegador, preservando o logcat desde o início.

## A/B após reinicialização com Firefox (2026-09-21)

Foi feito um reboot real e o Chrome foi aberto assim que `sys.boot_completed=1`.
No log permanente, ele iniciou às 03:02:27, criou o processo principal, o
`com.android.chrome_zygote`, `SandboxedProcessService0` e
`privileged_process0`; não houve `zygote-child`, `SIGABRT`, `crash_dump64`,
timeout de GPU ou watchdog nessa inicialização fria.

O Firefox (`org.mozilla.firefox`) foi localizado e aberto em seguida. Ele criou
o processo principal e vários processos Gecko (`tab_disable_art_image_*` e
`gpu_disable_art_image_`) diretamente a partir do `zygote64`, sem
`AppZygote`/`zygote_next`; a sessão permaneceu estável por 50 segundos. Isso
confirma a diferença arquitetural observada pelo usuário: Firefox não depende
do caminho Chromium/AppZygote. Ao mesmo tempo, o Chrome também passou nesse boot,
logo o defeito não é reproduzido deterministicamente apenas por iniciar o
navegador.

O próximo teste precisa provocar especificamente o serviço
`NativeOnlySandboxedProcessService` do Chrome (o serviço aparece nos logs antigos
antes do `zygote-child`), em vez de testar somente a abertura da atividade e o
`SandboxedProcessService` comum. Só então será possível capturar a transição de
capabilities/seccomp que diferencia o caso que falha do caso estável.

## Relatório `chrome://gpu` (2026-09-21)

O relatório fornecido pelo aparelho confirma que a GPU está ativa, e não
desabilitada por `--disable-gpu`: Canvas, composição, rasterização, vídeo,
WebGL e WebGPU aparecem como `Hardware accelerated`; OpenGL e Vulkan estão
`Enabled`; o dispositivo ativo é o Mali-G77 (`0x13b5/0x90800011`); e o backend
Skia é `GaneshVulkan`. A linha `Command Line` não contém `--disable-gpu`, e o
campo `GPU process crash count` está em `0`.

As entradas em `Driver Bug Workarounds` são compatibilidades normais do
Chromium para Mali/Android (MSAA 4x, virtualized contexts, limitações de
textura e extensões); não há, nesse relatório, indicação de GPU bloqueada,
context lost ou reset do driver. Portanto não foi a GPU que “foi desativada”
para fazer os navegadores abrirem. O timeout antigo do canal GPU pode ter sido
transitório ou consequência do `zygote-child`/processo nativo ausente; este
relatório isolado não prova que o driver seja a causa primária.

## Estado funcional atual e workaround confirmado (2026-09-21)

Durante a sessão que permaneceu estável, o aparelho não estava executando a beta
do Chrome. A instalação ativa foi confirmada ao vivo como:

```text
com.android.chrome          /product/app/Chrome64        149.0.7827.102
com.google.android.webview  /product/app/WebViewGoogle64  148.0.7778.215
```

Essas são as versões da `product`/base, depois do downgrade que já havia sido
observado como workaround. O Chrome ativo criou `com.android.chrome_zygote`,
`SandboxedProcessService0` e `PrivilegedProcessService0` normalmente; não houve
`NativeOnlySandboxedProcessService`, `zygote-child` ou watchdog nessa sessão.

Assim, o que tornou o aparelho utilizável foi a combinação do Chrome/WebView
compatíveis da `product` com a reinicialização dos processos após o reboot — não
`--disable-gpu` e não uma alteração no `debuggerd`. O módulo `cgroup_legacy`
deve permanecer habilitado (sem o marcador `disable`) para que os arquivos de
cgroup/tarefa compatíveis sejam instalados. Isso é um workaround operacional;
a beta 153 e seu caminho nativo ainda precisam de uma correção própria antes de
serem reativados.

## Reprodução com Microsoft Edge/Chromium (2026-09-21)

O Microsoft Edge instalado (`com.microsoft.emmx`, versão `153.0.4234.49`,
`target_sdk_version=36`, split `chrome`) reproduziu o mesmo defeito ao ser
aberto por `am start -W -n com.microsoft.emmx/com.microsoft.ruby.Main`. A captura
controlada está em `/tmp/edge-20260921-032428.log`.

O encadeamento observado foi explícito:

```text
03:24:32.558  ActivityManager: Start proc ... com.microsoft.emmx:privileged_process0
03:24:32.676  libc: Fatal signal 6 (SIGABRT) ... tid ... (zygote-child)
03:24:32.938  libc: capset failed: Operation not permitted
03:24:32.958  crash_dump64: failed to open /proc/...
03:24:32.959  libc: Crash due to signal: crash_dump helper failed ...
03:24:32.651+ ZygoteProcess: Got error connecting to zygote, retrying
```

Foram contadas 11.923 mensagens de `Connection refused` durante a captura.
Também apareceu o aviso de `SystemMemoryProcess`/cgroup v2, mas ele continua
sendo um aviso de ação ignorada, não a causa imediata do aborto. Portanto o
problema é reproduzível em dois aplicativos Chromium independentes (Chrome e
Edge) e está no caminho comum de inicialização nativa/AppZygote/zygote-child;
não é um defeito exclusivo do APK do Chrome. O `capset` e o `crash_dump64` são
consequências do processo filho já abortado.

Esse teste não demonstrou que a GPU seja a origem: o Edge chegou a iniciar a
atividade e o processo privilegiado antes do aborto, e a captura não contém um
timeout de GPU anterior ao `SIGABRT`. O workaround continua sendo manter
Chrome/WebView/Chromium em versões compatíveis da `product` ou usar Firefox
enquanto o caminho nativo da beta não for corrigido.

## A/B do Edge com as flags usadas no Chrome (2026-09-21)

Foi repetido no Edge o procedimento de abertura usado durante o teste do
Chrome, sem alteração permanente na ROM. Foram tentadas as duas sintaxes que
aparecem na captura histórica:

```text
adb shell am force-stop com.microsoft.emmx
adb shell am start -W -n com.microsoft.emmx/com.microsoft.ruby.Main \
  --esa command-line-flags --disable-gpu \
  --esa command-line-flags --disable-gpu-compositing

adb shell am force-stop com.microsoft.emmx
adb shell am start -W -n com.microsoft.emmx/com.microsoft.ruby.Main \
  --es args --disable-gpu
```

Ambas retornaram `Status: ok` e abriram a atividade do Edge, mas ambas
reproduziram o mesmo aborto do processo nativo:

```text
03:33:38.945  libc: Fatal signal 6 (SIGABRT) ... (zygote-child)
03:33:38.953  libc: capset failed: Operation not permitted

03:36:16.518  libc: Fatal signal 6 (SIGABRT) ... (zygote-child)
03:36:16.634  crash_dump64: failed to open /proc/...
```

As capturas foram salvas em `/tmp/edge-disable-gpu-20260921-033336.log` e
`/tmp/edge-disable-gpu-es-20260921-033610.log`. O segundo teste ainda registrou
7.795 recusas de conexão ao zygote. Portanto a flag `--disable-gpu` não é a
solução para esse caminho: o processo privilegiado/AppZygote morre antes de um
eventual problema gráfico. O Chrome que abriu anteriormente não provou que a
flag o corrigiu; ele estava usando a versão compatível da `product` e um estado
estável após o reset.

## Regressão reproduzida no Chrome após reboot (2026-09-21 03:44)

O log permanente `logcat_android_20260921_033344.log` mostra que o problema
voltou mesmo com o Chrome/WebView da `product` (Chrome `149.0.7827.102`). O
aparelho havia acabado de reiniciar (`uptime` de aproximadamente um minuto), e
o Chrome foi iniciado às 03:44:41:

```text
03:44:41.353  ActivityManager: Start proc ... com.android.chrome
03:44:41.559  libprocessgroup: cgroup uid_10248 criado
03:44:43.181  libprocessgroup: cgroup do pid 15127 criado
03:44:43.183  SystemMemoryProcess: ação de memory ignorada no cgroup v2
03:44:43.191  libc: Fatal signal 6 (SIGABRT) ... (zygote-child)
03:44:43.235  libc: capset failed: Operation not permitted
03:44:43.277  crash_dump64: failed to open /proc/15127
03:45:19.079  chromium: Timed out waiting for GPU channel
03:45:21.087  DEBUG: SIGTRAP; abort message = GPU channel timeout
```

Após o primeiro aborto foram contadas 6.713 mensagens de `Connection refused`.
O `dumpsys activity` ainda identifica o serviço
`NativeOnlySandboxedProcessService0` do Chrome, mas com `thread=null`, enquanto
o processo principal permanece vivo esperando o child nativo. Isso confirma a
ordem causal já observada: o `zygote-child` morre primeiro, o socket do
AppZygote deixa de responder e o timeout da GPU ocorre depois.

Conclusão atualizada: o downgrade para a `product` reduz a frequência, mas não
elimina o defeito. O problema continua reproduzível a frio no caminho comum
`NativeOnlySandboxedProcessService`/AppZygote/`zygote_next`; não deve ser
considerado resolvido por versão do Chrome, `--disable-gpu` ou pelo aviso de
`SystemMemoryProcess`.

## Auditoria profunda de zygote, AppZygote, seccomp, namespaces e init (2026-09-21)

Foi feita uma coleta direta no aparelho, sem alterar a ROM. O estado atual é:

```text
ro.zygote=zygote64
zygote64       PID 15928  domain=u:r:zygote:s0       Seccomp=0
zygote_next    PID  7128  domain=u:r:zygote_next:s0  Seccomp=0
webview_zygote PID 28336  domain=u:r:webview_zygote:s0 Seccomp=2 NoNewPrivs=1
Chrome         PID 29598  domain=u:r:untrusted_app_34:s0 Seccomp=2
```

O Chrome principal tem `PPid=zygote64`; portanto `zygote_next` está ativo, mas
não é o pai direto do Chrome nesta build. O `zygote_next` é iniciado pelo
gatilho `persist.zygote.zygote_next.start_on_boot=true` em
`system/etc/init/zygote_next.rc`. Os sockets `/dev/socket/zygote` e
`/dev/socket/zygote_next` existem e têm permissões `root:system 0660`.

O kernel expõe `CONFIG_SECCOMP=y` e `CONFIG_SECCOMP_FILTER=y`, mas não possui
`CONFIG_USER_NS` nem `CONFIG_IPC_NS`; também não possui `CONFIG_CGROUP_PIDS` e
`CONFIG_CGROUP_DEVICE`. Os namespaces `user` e `ipc` não aparecem em `/proc`.
Isso é uma diferença real em relação a kernels AOSP mais completos e pode ser
relevante para o sandbox nativo Chromium, embora o log não prove sozinho que
essa seja a chamada que aborta.

O caminho que falha foi isolado:

1. `com.android.chrome:privileged_process0` inicia normalmente e o processo
   `com.android.chrome_zygote` chega a existir.
2. O serviço comum `SandboxedProcessService0` chega a funcionar em sessões
   anteriores.
3. A falha ocorre ao iniciar
   `NativeOnlySandboxedProcessService0`. Nesse momento o AppZygote perde o
   socket `com.android.internal.os.AppZygoteInit/<uuid>` e passa a registrar
   `Connection refused`.
4. Logo depois o processo filho aborta como `zygote-child`.

No log de 03:45:49, a ordem é explícita:

```text
2043309  AppZygote: retry starting ... NativeOnlySandboxedProcessService0
2043312  libprocessgroup: Created cgroup ... pid_15623
2043314  JoinCgroup/SystemMemoryProcess ignorado no cgroup v2
2043321  libc: Fatal signal 6 (SIGABRT) ... zygote-child
2043324  crash_dump64: falha ao abrir /proc/15623
```

O aviso `SystemMemoryProcess` não é uma negação SELinux: o `libprocessgroup`
deliberadamente ignora essa ação quando o controlador `memory` está na
hierarquia cgroup v2. O controlador está ativo (`cgroup.controllers` e
`cgroup.subtree_control` contêm `memory`), mas a build também registra no boot
falhas ao abrir `/dev/blkio/normal/cgroup.procs` e montagens legacy `freezer`
com `Device or resource busy`. Isso indica que o módulo `cgroup_legacy` ainda
mistura perfis de cgroup do S24+ com a topologia legacy do kernel; a mistura
não deve ser considerada validada apenas porque o grupo v2 foi montado.

Não foram encontrados `avc: denied` envolvendo zygote/Chrome no instante do
aborto. Há perda de eventos (`kauditd hold queue overflow`), portanto a
ausência de AVC não elimina completamente uma negação, mas o sinal observável
continua sendo a especialização nativa/AppZygote, não a GPU nem o zygote64
principal.

## Veredito após reprodução limpa do Chrome (2026-09-21 11:27)

Foi feita uma reprodução sem flags, com o logcat limpo antes de abrir o Chrome.
A ordem observada foi:

```text
11:26:59.835  zygote64: Forked child process 7663
11:26:59.836  ActivityManager: Start proc 7663:com.android.chrome
11:27:00.383  libprocessgroup: Created cgroup .../apps/uid_10248/pid_7719
11:27:00.388  SystemMemoryProcess: JoinCgroup(memory) ignorado em cgroup v2
11:27:00.393  libc: Fatal signal 6 (SIGABRT) em zygote-child 7719
11:27:00.404  crash_dump64: failed to open /proc/7719
```

O processo principal do Chrome chega a criar a janela e continua vivo; quem
abortou foi o filho nativo criado para o sandbox. As recusas de conexão ao
zygote aparecem imediatamente depois do abort e não antes dele. Não houve
`GPU channel timeout` nessa janela de reprodução; os timeouts de GPU dos
tombstones anteriores são consequência de o processo auxiliar não existir.

Foi verificado ainda o código efetivamente usado pelo build em
`external/android-tools/vendor/core/libprocessgroup/task_profiles.cpp`: entre
as linhas 975–987, qualquer ação `JoinCgroup` cujo controlador esteja na
hierarquia cgroup v2 é deliberadamente descartada com o aviso
`will be ignored`. Portanto, o `cgroupmem.rc` do módulo
`platform/exynos990/patches/cgroup_legacy` não torna o perfil
`SystemMemoryProcess` aplicável ao filho; ele apenas habilita `memory` e
mantém uma configuração híbrida. O mesmo boot registra falhas em
`/dev/blkio/normal/cgroup.procs` e leituras de `cgroup.procs` do Freecess.

### Conclusão técnica

O problema primário está no caminho de especialização do filho nativo
Chromium/AppZygote (zygote-child), provocado por incompatibilidade entre o
userspace Android 17, os perfis/cgroups legados importados e as capacidades/
namespaces disponíveis no kernel 4.19. O `zygote64` principal não é a origem:
ele permanece executando e cria processos comuns. A GPU e `crash_dump64` são
efeitos posteriores. A hipótese mais acionável é remover ou adaptar o módulo
`cgroup_legacy`; a confirmação binária final exige uma build A/B sem esse
módulo, mantendo Chrome/APEX/kernel idênticos.

## Verificação e correção do módulo cgroup_legacy (2026-09-21)

O sistema da ROM vem de `SM-S926B_EUX` (S24+), enquanto o vendor vem de
`SM-G986B_AUT` (S20+). Portanto, os arquivos nativos do firmware alvo não
podem substituir os descritores do sistema: o S20+ usa `/acct` e não define
`SystemServiceCapacityHigh`, mas os `init.rc` do S24+ usam `/dev/acct` e esse
perfil. O módulo agora usa os descritores `e2sxxx` compatíveis, que mantêm
`/dev/acct`, remapeiam `foreground-boost` para `foreground` e removem o
perfil `cpu_mid` inexistente no kernel/ vendor do S20+.

O `libcgrouprc.so` e o `libchrome.so` do sistema permanecem os binários do
S24+; a comparação ELF mostrou somente dependências padrão (`libbase`,
`libc++`, `libc`, `libm`, `libdl`) e os símbolos `LIBCGROUPRC`/`LIBCGROUPRC_30`,
todos disponíveis no runtime. O `vendor/lib64/libchrome.so` do doador foi
removido por não ser uma dependência do cgroup.

O `cgroupmem.rc` é mantido porque o kernel 4.19 desta build expõe
`CONFIG_MEMCG=y`, `CONFIG_MEMCG_SWAP=y` e `memory_recursiveprot`; no aparelho,
`memory` está disponível em `/sys/fs/cgroup`, `apps` e `system`. A verificação
foi corrigida: o freezer v2 já está implementado no kernel e os grupos-filhos
expõem `cgroup.freeze`; ele não aparece em `cgroup.controllers` porque não é
um controlador separado. A única interface v2 ausente era `cgroup.kill`.

## Backport de cgroup.kill (2026-09-21)

Foi adicionado `platform/exynos990/patches/extremekrnl/patches/0002-cgroup2-add-cgroup-kill-interface.patch`.
O backport implementa a interface `cgroup.kill` no core cgroup2 do kernel 4.19:
aceita somente `1`, mata processos de usuário do grupo e de todos os
descendentes, ignora threads do kernel, rejeita cgroups threaded e fecha a
condição de corrida de fork marcando o grupo durante a iteração e terminando
filhos criados nesse intervalo. O freezer v2 existente não foi duplicado nem
alterado.

O `task_profiles.json` compatível `e2sxxx` agora também declara o atributo
`CgroupKill` (`cgroup2/cgroup.kill`), de modo que o userspace S24+ possa usar a
interface quando o kernel atualizado estiver instalado. O aplicador de patches
do ExtremeKRNL passou a percorrer todos os patches em ordem, mantendo
idempotência para builds incrementais. A compilação do objeto
`kernel/cgroup/cgroup.o`, a aplicação/reversão do patch, a sintaxe do script e
o JSON foram validados localmente.

O módulo foi atualizado para a versão 2.2/`versionCode=4`. Ainda é necessária
uma nova build/flash para verificar no aparelho `/sys/fs/cgroup/apps/cgroup.kill`
e testar a escrita controlada `echo 1 > .../cgroup.kill`; a função é uma
capacidade de gerenciamento de processos e não, por si só, uma correção
garantida para o crash do Chrome.

## Verificação no aparelho e créditos dos patches (2026-09-21)

Foi feita uma leitura somente no aparelho conectado `RX8NB005S3Z`, sem escrever
em nenhum cgroup. O kernel atualmente instalado confirma:

```text
/sys/fs/cgroup:        cgroup.freeze=no  cgroup.kill=no
/sys/fs/cgroup/apps:   cgroup.freeze=yes cgroup.kill=no
/sys/fs/cgroup/system: cgroup.freeze=yes cgroup.kill=no
features: nsdelegate, memory_recursiveprot
controllers: memory
```

Isso confirma que o freezer v2 já está ativo nos grupos-filhos e que o
`cgroup.kill` ainda não aparece porque a imagem com o patch 0002 ainda não foi
buildada/flashada. Depois do flash, a mesma leitura deve mostrar
`cgroup.kill=yes` em `apps` e `system`.

Também foram corrigidos 11 cabeçalhos de patches que usavam identidades
genéricas (`UN1CA maintainers`, `UN1CA y2slte`, `Codex`, `localhost` ou domínio
de exemplo). Eles agora usam o crédito solicitado:
`From: At30c`. Autores reais de terceiros não
foram alterados.

## Variante A/B para os APEX de runtime (2026-09-21)

Foi adicionada uma variante selecionável para testar a hipótese de que a
mescla ARM32 do runtime está relacionada ao crash de navegadores Chromium.
`EXYNOS990_RUNTIME32_APEX_MODE="source_apex"` agora é o padrão da plataforma:
preserva os APEX originais do S24+. O modo anterior continua disponível com
`EXYNOS990_RUNTIME32_APEX_MODE="merged"`; ele importa o payload ARM32 do r11s
para `com.android.runtime`/`com.android.i18n`, além dos binários de linker e
das bibliotecas soltas de compatibilidade.

Essa opção não troca nem remove `com.android.vndk.v30`: o VNDK 30 continua
sendo necessário para a interface do vendor do S20+. O teste altera somente
o caminho dos APEX de Runtime/I18n/ART e seus complementos ARM32.

O modo `source_apex` já está aplicado diretamente em
`platform/exynos990/config.sh`, portanto basta carregar o ambiente e iniciar a
build. Ele preserva integralmente os APEX originais do S24+
(`com.android.runtime`, `com.android.i18n` e ART) e não instala o linker,
nem mescla esses arquivos dentro dos APEX. Para que os serviços ARM32 do
vendor ainda possam iniciar, ela instala o linker e os quatro Bionic básicos
do donor como arquivos standalone em `/system/bin` e `/system/lib`; a única
exceção adicional é o `system/lib/libstagefright.so`, mantido porque o módulo
WFD aplica um patch direto nele. As dependências ARM32 não-Bionic são
resolvidas recursivamente. As propriedades de compatibilidade restantes
continuam sendo aplicadas. A variante é
intencionalmente diagnóstica: serviços legados 32-bit (por exemplo OMX) podem
deixar de iniciar, mas o resultado separa a causa APEX da causa Chromium/GPU.

Exemplo:

```bash
source buildenv.sh y2s
aether
```

Para testar novamente o comportamento anterior sem editar arquivos, use
`EXYNOS990_RUNTIME32_APEX_MODE=merged aether` depois de carregar o ambiente.

A sintaxe dos scripts foi validada com `bash -n`; a geração atual continua
produzindo `EXYNOS990_RUNTIME32_APEX_MODE="source_apex"` por padrão. Nenhuma
build ou instalação dessa variante foi executada ainda.

Durante o primeiro teste da variante, o módulo WFD falhou porque o
`libstagefright.so` isolado ainda dependia de `libcrypto.so`. O resolvedor do
WFD agora percorre automaticamente o `DT_NEEDED` não-Bionic do stagefright;
essa árvore contém 185 bibliotecas do r11s e não apresentou dependências
ausentes. O fechamento foi verificado com `readelf` sem instalar ou modificar
o aparelho.

O teste seguinte revelou uma dependência cruzada nos binários WFD do r9s:
`libhdcp2.so` precisava de `libion.so`, disponível apenas no prebuilt r11s.
O resolvedor agora pesquisa os dois doadores (r9s primeiro para os binários WFD
e r11s como fallback), incluindo o fechamento completo de todos os roots WFD.
O novo levantamento totalizou 214 bibliotecas resolvidas, sem ausências.

Na execução seguinte, a validação ainda encontrou `libstagefright.so` →
`lib_soundaliveresampler.so`. O resolvedor agora também é chamado no limite da
validação: se qualquer `DT_NEEDED` estiver faltando no `work_dir`, ele busca a
biblioteca nos dois doadores, instala o fechamento e só então valida o ELF.
Dependências previamente marcadas durante ciclos não podem mais mascarar um
arquivo que não foi instalado.

O primeiro flash do modo `source_apex` mostrou que o vendor ARM32 não iniciava
porque `/system/bin/linker` não existia. O diagnóstico no aparelho registrou
`init: cannot execv(...)` para os serviços DRM, áudio, GeoTrans e OMX. A
variante agora extrai o linker/Bionic ARM32 do Runtime donor sem modificar o
APEX do S24+, eliminando essa causa de bootloop.

Na confirmação seguinte no aparelho `RX8NB005S3Z`, `/system/bin/linker`,
`linker_asan`, `libc.so`, `libdl.so` e `libm.so` estavam ausentes; `bootanim`
continuava `running`, `sys.boot_completed` não era publicado e o uptime voltou
a reiniciar. Isso confirma que o bootloop observado era a ausência do runtime
ARM32 standalone, não uma morte do zygote 64-bit.

Após a instalação do runtime standalone, o erro seguinte ficou explícito:
`libprocessgroup.so` do VNDK 30 não encontrava `libcgrouprc.so` no namespace
32-bit. O módulo `cgroup_legacy` agora instala o `libcgrouprc.so` ARM32 e os
`libbase.so`/`libc++.so` correspondentes do mesmo donor r11s em `system/lib`;
as bibliotecas Bionic continuam vindo do runtime standalone.

## Captura confirmada do crash do Chrome e mitigação AppZygote (2026-09-21)

Na captura `logcat_android_20260921_160613.log`, o Chrome foi aberto sem
flags. O processo nativo do sandbox (`zygote-child`, PID 19316) abortou
primeiro:

```text
16:10:12.612  libprocessgroup: SystemMemoryProcess ... controller memory ... will be ignored
16:10:12.617  libc: Fatal signal 6 (SIGABRT) ... pid 19316 (zygote-child)
16:10:12.634  crash_dump64: failed to open /proc/19316: No such file or directory
```

O `crash_dump64` falhou nesse filho porque ele já havia desaparecido quando o
helper tentou abrir `/proc`. O processo principal do Chrome permaneceu vivo e
abortou depois, desta vez com captura completa. Foi criado no aparelho
`/data/tombstones/tombstone_15` às 16:10:48:

```text
Executable: /system/bin/app_process64
Cmdline: com.android.chrome
pid: 19270, ppid: 7021
signal 5 (SIGTRAP), code 1 (TRAP_BRKPT)
Abort message: '[FATAL:content/browser/gpu/browser_gpu_channel_host_factory.cc:49] Timed out waiting for GPU channel.'
```

O tombstone confirma que o timeout de GPU é consequência da morte do filho
native/AppZygote: o canal GPU nunca fica disponível. Ele não aponta para um
defeito independente no `crash_dump64` ou no driver GPU. Depois do timeout, o
framework entrou novamente em loop de `Connection refused`; às 16:12:00 o
`system_server` morreu e o zygote foi encerrado pelo init, produzindo o
soft-reboot observado.

Foi adicionada a variante experimental `unica/mods/appzygote_compat`. Ela
define `ro.unica.disable_app_zygote=true` e aplica
`services.jar/0001-Route-native-sandbox-away-from-AppZygote.patch`. O patch é
propriedade-gated e, quando ativo, força somente a ramificação de serviços
native que usaria `AppZygote` a seguir pelo zygote regular. O zygote comum e o
WebView zygote não são alterados. Isso é uma mitigação A/B reversível para
testar a causa primária; não é um patch no `libchrome.so` nem uma desativação
global da GPU.

Validações realizadas:

1. `bash -n unica/mods/appzygote_compat/customize.sh`.
2. `git diff --check`.
3. `git apply --check` do patch contra o `ProcessList.smali` Android 17
   atualmente decodificado.
4. Aplicação do patch em uma cópia temporária, confirmando `.locals 39`, uso
   de `invoke-static/range` válido e o desvio antes de
   `createAppZygoteForProcessIfNeeded()`.

O próximo teste deve gerar/instalar uma build com esse módulo, abrir o Chrome
sem flags e verificar se deixam de aparecer `zygote-child`/`crash_dump64` e o
timeout `browser_gpu_channel_host_factory.cc:49`. Se a ROM não iniciar ou
outros serviços nativos falharem, remova o módulo `appzygote_compat` e repita
o A/B; isso indicará que o fallback precisa ser limitado por pacote em vez de
ser aplicado a todos os serviços native.

O teste seguinte mostrou que misturar o `libc++.so` Android 33 do S20+ com o
`liblog.so`/`libbase.so` Android 37 do r11s causava o símbolo ausente
`_ZNSt3__122__libcpp_verbose_abortEPKcz`. O conjunto foi unificado no r11s
para manter o ABI C++ consistente.

A varredura recursiva dos 649 ELF32 presentes no `work_dir` também encontrou
clientes vendor que precisavam de `android.frameworks.sensorservice@1.0.so`,
`android.hardware.sensors@1.0.so`, `libGLESv3.so`, `libminijail.so` e
`libcap.so`. A variante `source_apex` agora instala os três primeiros do
firmware alvo e os dois últimos do donor r11s antes da validação WFD.

## Correção do patch AppZygote para o Apktool 3.0.3-16 (2026-09-21)

A primeira tentativa do `appzygote_compat` usava `v36`/`v37` e escrevia em
`v18`. Embora esses registradores fossem válidos pelo total de `.locals`, o
assembler desta versão do Apktool rejeita instruções não-range acima de `v15`.
Isso causou o erro `maximum allowed register ... v15` durante a build de
`services.jar`.

O patch foi corrigido para usar somente `v14`/`v15` na leitura da propriedade.
Quando `ro.unica.disable_app_zygote=true`, ele salta diretamente para
`:cond_1f`, o caminho do zygote normal, sem sobrescrever `v18`; com a
propriedade falsa, a decisão original de AppZygote permanece intacta.

Validação concluída:

1. `git apply --check` passou no `ProcessList.smali` decodificado.
2. `git diff --check` passou.
3. `java -Xmx2097m -jar out/tools/bin/apktool.jar b -j 1 .../services.jar`
   concluiu com exit code 0 e gerou `dist/services.jar`.

Ainda não houve flash nem validação no aparelho; a correção resolve o erro de
smali da build, mas sua eficácia contra o crash do Chrome só pode ser medida
após instalar uma ROM nova.

## Backport `cgroup.kill` registrado no repositório do kernel (2026-09-21)

O backport foi confirmado no kernel instalado e registrado no repositório
`At30c/SSM_990v2BYEXTREME`:

```text
Commit: f645ea00fb89 cgroup: add cgroup.kill to legacy cgroup2
Branch: main
Remote: origin/main
```

O commit contém somente:

```text
include/linux/cgroup-defs.h
kernel/cgroup/cgroup.c
```

O `cgroup.kill` foi deliberadamente marcado com `CFTYPE_NOT_ON_ROOT`, portanto
o arquivo não aparece em `/sys/fs/cgroup/cgroup.kill`; ele aparece nos cgroups
descendentes, por exemplo `/sys/fs/cgroup/apps/cgroup.kill`.

Validação no aparelho após o flash:

1. `/sys/fs/cgroup/apps/cgroup.kill` existe.
2. `/sys/fs/cgroup/apps/cgroup.freeze` continua disponível.
3. Um processo `sleep` foi movido para um cgroup temporário e terminou após
   `printf 1 > cgroup.kill`.
4. O cgroup temporário foi removido sem deixar resíduos.

Os diretórios de build não foram incluídos no commit; apenas os dois arquivos
do backport foram enviados ao repositório do kernel.

## Teste da nova build: framework estabiliza, mas o native Chromium child continua falhando (2026-09-21 17:15–17:22)

Na nova build instalada, o kernel confirmou novamente:

```text
4.19.325-cip119-st3-ExtremeKRNL-Nexus-v1+ #2
/sys/fs/cgroup/apps/cgroup.kill: presente
/sys/fs/cgroup/apps/cgroup.freeze: presente
```

O teste funcional de `cgroup.kill` continuou passando: um `sleep` temporário
foi movido para um cgroup descartável e morreu após `printf 1 > cgroup.kill`.

Chrome e Edge foram iniciados explicitamente com `am start`. Ambos mantiveram
o processo principal e criaram a Activity, mas o processo nativo
`NativeOnlySandboxedProcessService` falhou no mesmo ponto:

```text
zygote_next: zygote: Native Zygote: Exiting server
libc: Fatal signal 6 (SIGABRT) ... (zygote-child)
crash_dump64: failed to open /proc/<pid>: No such file or directory
ActivityManager: Process ... NativeOnlySandboxedProcessService0 failed to attach
```

O padrão se repetiu para o Chrome e para o Edge, confirmando que é uma falha
comum do caminho Chromium nativo, não de um APK específico. Não apareceu
`Timed out waiting for GPU channel` nesta execução, e `system_server`, zygote64
e zygote_next permaneceram vivos por mais de dez minutos; o patch do framework
evitou a escalada anterior para SIGTRAP/soft-reboot, mas não corrigiu o child.

Um A/B com SELinux permissivo não eliminou o `SIGABRT`; o teste foi restaurado
para `Enforcing`. Os pais `zygote64` e `zygote_next` continuam com
`CapEff=CapBnd=0x3fffffffff`, `NoNewPrivs=0` e `Seccomp=0`. Assim, o próximo
alvo é a transição do child nativo para seccomp/capabilities em
`zygote_next`; `cgroup.kill`, o aviso `SystemMemoryProcess` e a GPU ficam como
efeitos secundários nesta fase.

## Chrome abre após limpar dados, mas páginas não carregam (2026-09-21 17:25)

Foi aberta uma URL real (`https://example.com`) após limpar os dados do Chrome.
A conectividade do aparelho estava normal: Wi-Fi conectado, validado e com
rota/DNS disponíveis. A `ChromeTabbedActivity` permaneceu em primeiro plano,
mas o conteúdo não carregou.

O log mostrou o motivo: ao tentar criar os renderers, o Chrome entrou em loop
de `NativeOnlySandboxedProcessService0`. Cada tentativa gerou um novo UID
isolado, iniciou o `zygote_next` e morreu imediatamente:

```text
ActivityManager: Start proc ... NativeOnlySandboxedProcessService0
zygote_next: Native Zygote: Exiting server
libc: Fatal signal 6 (SIGABRT) ... (zygote-child)
crash_dump64: failed to open /proc/<pid>
ActivityManager: Process ... failed to attach
```

Não houve erro de DNS/rede nem timeout de GPU nessa tentativa. Portanto,
limpar os dados apenas permite que a Activity inicial seja criada; páginas
dependem do renderer nativo, que continua incompatível com a cadeia
`zygote_next`/seccomp/capabilities.

## Correção da segunda seleção de `zygote_next` no `framework.jar` (2026-09-21)

A investigação mostrou que o fallback anterior no `services.jar` não era
suficiente. Ele evita a criação do `AppZygote`, mas `Process.start()` faz uma
segunda decisão independente no `framework.jar`: quando
`Flags.nativeFrameworkPrototype()` é verdadeiro e o bit `0x8` está presente
em `runtimeFlags`, ele seleciona diretamente `NATIVE_ZYGOTE_PROCESS`. Na base
Android 17 atual, `RELEASE_NATIVE_FRAMEWORK_PROTOTYPE` está habilitado; por
isso os processos `NativeOnlySandboxedProcessService` ainda entravam em
`zygote_next` depois de contornar o AppZygote.

O módulo `unica/mods/appzygote_compat` foi atualizado para a versão 1.1. Ele
agora aplica também
`framework.jar/0001-Disable-native-zygote-on-legacy-vendor.patch` e define:

```properties
ro.unica.disable_app_zygote=true
ro.unica.disable_native_zygote=true
```

Com a segunda propriedade ativa, `Process.start()` salta para o
`ZYGOTE_PROCESS` Java regular antes de considerar o bit de processo nativo.
Quando a propriedade está ausente ou falsa, o fluxo original permanece
inalterado. O patch usa apenas `v1`/`v2`, que são sobrescritos pelo código
original depois da escolha do zygote, evitando o limite de registradores que
já causou falha no Apktool.

Validações realizadas:

1. `git apply --check` passou contra o `Process.smali` atualmente decodificado.
2. O patch foi aplicado a uma cópia limpa do `framework.jar` decodificado.
3. O Apktool `3.0.3-16-17254568-SNAPSHOT` recompilou todas as sete classes DEX
   e gerou `dist/framework.jar` com exit code 0.
4. `unzip -t` não encontrou erros no JAR remontado.
5. `bash -n` e `git diff --check` passaram nos arquivos do módulo.

O `services.jar` presente no `out` já continha o primeiro patch, o que também
confirma que ele entrou na build anterior. A nova correção do `framework.jar`
ainda não está no aparelho: é necessária uma nova build/instalação antes do
teste funcional. Depois do flash, a evidência esperada é a ausência de
`zygote_next: Native Zygote: Exiting server` ao abrir Chrome/Edge, seguida da
criação estável dos renderers e carregamento de páginas. Se o filho ainda
abortar, o log do novo caminho regular deve permitir separar a falha de
especialização de uma falha interna do Chromium.

## Módulo KernelSU para o teste AppZygote/zygote_next (2026-09-21)

Foi gerado o módulo de teste específico para a build instalada:

```text
out/target/y2s/appzygote-compat-ksu-v1.1.zip
SHA-256: b997c08c06a54730ef4a5315b51a1191ab4ba0dae5a7557a2ed345bbd702cceb
```

Antes de montar o módulo, os JARs locais e os do aparelho foram comparados. Os
dois pares eram idênticos:

```text
framework.jar  8361ab40e2f9f4d98a595753054d311cc4bd019c243b111f6a970407af1185c6
services.jar   373e210fc5d861d51c4ada3ddf8218034bea8dc4dbebc1716829bebc0ccc7e7b
```

O ZIP contém o `framework.jar` remontado com o novo patch, o `services.jar`
já presente na build e as duas propriedades de fallback. O instalador recusa
qualquer fingerprint ou hash diferente para impedir que um framework de outra
build seja montado. O arquivo passou em `unzip -t`, os scripts passaram em
`bash -n`, e a instalação pelo `ksud 3.3.0` confirmou os hashes-base.

O primeiro reboot foi concluído normalmente, mas não constituiu teste do
patch: `/system/framework/framework.jar` manteve o hash original e
`ro.unica.disable_native_zygote` não foi criada. A inspeção mostrou o módulo
em `modules_update`, com `update=true`, e nenhum link
`/data/adb/metamodule`. Essa versão do KernelSU Next delega a montagem de
arquivos de `/system` a um metamódulo; sem `meta-overlayfs`, Magic Mount ou
equivalente, o diretório `system/` de módulos regulares não é sobreposto. O
mesmo estado pendente também foi observado no ReZygisk já instalado.

O módulo v1.1 ficou preparado no aparelho, mas ainda não está ativo. Instalar
um metamódulo é uma mudança global: além deste teste, ativará outros módulos
pendentes, incluindo ReZygisk. Portanto isso não foi feito automaticamente.
Após escolher e instalar um backend de montagem compatível, reinicie e só
considere o patch ativo se:

```text
sha256sum /system/framework/framework.jar
0335d0adbb5e089d08eb0e695ec7dd34043fa99ecd094c497cd259ebf7d38538

getprop ro.unica.disable_native_zygote
true
```

## Resultado do A/B com o Zygote Java regular (2026-09-21 18:25)

O Meta-Overlayfsx 1.3.4 foi instalado. Como a integração do KernelSU deste
kernel não disparou `post-fs-data` automaticamente, o evento foi acionado uma
vez pelo `ksud`. O metamódulo montou a imagem ext4 e sobrepôs os dois JARs sem
conflitos. Antes do teste foram confirmados:

```text
/system/framework/framework.jar = 0335d0ad...d38538 (patch ativo)
ro.unica.disable_app_zygote=true
ro.unica.disable_native_zygote=true
Overlayfsx: Modules Mounted: 1, File Conflicts: False
```

Após um soft reboot, o Chrome foi aberto com `https://example.com`. O desvio
funcionou exatamente como implementado: os filhos apareceram com PPID do
`zygote64` Java regular, não houve a sequência anterior de `SIGABRT`,
`capset failed` ou falha do `crash_dump64`, e não houve tentativa funcional
de iniciar o renderer através de `zygote_next`.

Entretanto, o teste também provou que esse fallback não pode ser usado como
solução. `NativeOnlySandboxedProcessService0` não possui uma classe Java
carregável no APK base. Ao ser iniciado pelo Zygote Java, cada renderer morreu
com:

```text
java.lang.RuntimeException: Unable to create service
org.chromium.content.app.NativeOnlySandboxedProcessService0
Caused by: java.lang.ClassNotFoundException: Didn't find class
"org.chromium.content.app.NativeOnlySandboxedProcessService0"
```

Foram observadas 148 ocorrências desse `ClassNotFoundException` no teste. Isso
confirma duas coisas: o patch realmente retirou os filhos do `zygote_next`,
mas o Chromium atual depende obrigatoriamente do caminho Native Zygote para
esses serviços. A correção definitiva deve manter `NATIVE_ZYGOTE_PROCESS` e
corrigir sua especialização; redirecioná-lo para `ZYGOTE_PROCESS` apenas troca
o abort nativo por uma falha determinística de carregamento Java.

O módulo KernelSU `appzygote_compat_ksu` foi desabilitado e o aparelho foi
reiniciado. O framework voltou ao hash original
`8361ab40...1185c6`, a propriedade experimental deixou de existir e o boot
foi concluído. Também foi adicionado `unica/mods/appzygote_compat/disable`
para impedir que essa variante comprovadamente inválida entre em builds
futuras. A captura completa está em
`out/target/y2s/ksu-appzygote-test-20260921-1825/`.

## Diagnóstico TRACE do Native Zygote (2026-09-21)

Depois de confirmar que `NativeOnlySandboxedProcessService` não pode ser
redirecionado ao Zygote Java, foi preparada uma variante que mantém o caminho
nativo original e apenas aumenta a observabilidade. O novo módulo de
plataforma está em:

```text
platform/exynos990/patches/zzzzz_zygote_next_trace/
```

Ele substitui somente `system/etc/init/zygote_next.rc`. Socket, usuário,
grupo, prioridade, gatilho de inicialização e comportamento de restart foram
preservados. A linha do serviço passou a usar:

```text
--log-level TRACE --trace-level TRACE
```

Também foi acrescentado `stdio_to_kmsg`. A ROM é `ro.debuggable=1` e já usa
essa diretiva em outros serviços; assim, um panic Rust emitido em stderr pode
ser preservado no buffer do kernel mesmo quando o filho morre antes de o
`crash_dump64` anexar. O próprio binário `zygote_next --help` no aparelho
confirmou suporte aos dois argumentos de nível de log.

O código Android 17 confirma que, depois do último ponto atualmente visível
(`cgroup::create`), o filho executa `set_cpuset_policy`, `set_sched_policy`,
securebits/capabilities, seccomp, `setresuid` e a transição SELinux. O TRACE
deve identificar em qual dessas fronteiras ocorre o panic, evitando outro
patch comportamental por tentativa.

O ReZygisk foi deixado `enabled=false` e seu marcador de remoção foi revertido;
o módulo permanece instalado, mas não será executado no próximo boot. O módulo
KernelSU `appzygote_compat_ksu` também continua desabilitado. O Meta-Overlayfsx
permanece ativo apenas como backend de montagem.

Validações realizadas:

1. `zygote_next --help` confirmou `--log-level` e `--trace-level`.
2. `stdio_to_kmsg` já é aceito pelos arquivos init da mesma imagem.
3. A comparação com o RC original mostrou apenas comentários, níveis TRACE e
   redirecionamento de stderr como diferenças.
4. `git diff --check` passou.

O patch ainda requer nova build/flash. No teste seguinte, capture `logcat -b
all`, `dmesg` e eventos `zygote_next` desde antes de abrir o Chrome.

## Módulo KernelSU de TRACE do Native Zygote (2026-09-21 18:55)

Para testar a mesma instrumentação sem gerar outra ROM, foi criado e instalado
o módulo KernelSU `zygote_next_trace_ksu` 1.1. O ZIP final está em:

```text
out/target/y2s/zygote-next-trace-ksu-v1.1.zip
sha256 4319a9bb9a2ba06dee74983c42cebc0a6db75fdd8494044fe49d29d1228ea9ba
```

O módulo foi limitado ao binário `zygote_next` desta build. O instalador exige
o SHA-256 original
`b16225e7f4c41c5ebda007c2605ef831228bdbe8fff6a1392fae77e9dea47064`.
Ele monta um wrapper ELF AArch64 estático, sem libc e sem abrir descritores,
que preserva todos os argumentos do `init`, troca `INFO` por `TRACE`, acrescenta
`--trace-level TRACE` e executa a cópia intacta em
`/system/bin/zygote_next.real`. O código-fonte do wrapper e os arquivos de
empacotamento permanecem em:

```text
out/target/y2s/zygote-next-trace-ksu-src/
```

O Meta-Overlayfsx inicialmente atribuiu `system_file` aos dois executáveis. A
versão 1.1 corrige isso no `post-fs-data.sh`: o wrapper recebe novamente
`zygote_next_exec`, preservando a transição stock `init` -> `zygote_next`, e a
cópia real permanece `system_file`. A regra SELinux do módulo permite somente
o segundo `exec` sem transição e o relabel necessário pelo domínio privado do
KernelSU.

Nesta integração do KernelSU, `post-fs-data` ainda não é disparado
automaticamente. Depois do reboot o Android iniciou normalmente com o binário
stock; foi necessário executar uma vez:

```text
su -c /data/adb/ksu/bin/ksud post-fs-data
```

Após isso, o overlay apresentou os hashes esperados, o serviço foi reiniciado
isoladamente com `setprop ctl.restart zygote_next` e voltou saudável. A
validação ao vivo confirmou:

```text
contexto: u:r:zygote_next:s0
PID: 20818
zygote.zygote_next.server_ready=true
socket /dev/socket/zygote_next em LISTEN
NoNewPrivs=0
Seccomp=0
argv: /system/bin/zygote_next --name zygote_next --species android-native-app
      --log-level TRACE --arg-buf-padding ... --trace-level TRACE
```

Não houve falha de argumento, negação SELinux ou restart em loop. O módulo está
instalado e habilitado; `appzygote_compat_ksu` e ReZygisk continuam
desabilitados. O próximo passo é reproduzir a abertura do Chrome/Edge com
`logcat -b all` e `dmesg` já capturando, agora que o Native Zygote realmente
está emitindo TRACE.

## Causa explícita do SIGABRT do Native Zygote (2026-09-21 19:03)

Com o módulo TRACE ativo, o Chrome aberto reproduziu 18 aborts consecutivos de
`NativeOnlySandboxedProcessService`; uma segunda abertura controlada reproduziu
o mesmo padrão. Os artefatos completos estão em:

```text
out/target/y2s/native-zygote-trace-20260921-185847/
```

Além de `logcat -b all` e `dmesg`, foi feita uma captura ftrace dos eventos
`raw_syscalls`, `sched_process_*` e `signal_*`, filtrada pelo PID 20818 do
`zygote_next` e herdada pelos filhos. O tracing foi desligado e os filtros
foram removidos após quatro segundos. O Chrome foi encerrado sem limpar seus
dados para evitar que a repetição bloqueasse `system_server`; o aparelho
permaneceu com `sys.boot_completed=1`, `system_server` PID 7602 e
`zygote_next` PID 20818.

O ftrace identificou o primeiro erro fatal de forma determinística. Em nove
filhos conferidos, a especialização executou esta sequência:

```text
prctl(PR_CAPBSET_READ, 0..37) = 1
prctl(PR_CAPBSET_DROP, 0..37) = 0
prctl(PR_CAPBSET_READ, 38)    = -EINVAL
write(2, ..., 145)            = 145
rt_tgsigqueueinfo(..., SIGABRT, ...) = 0
```

Portanto, o abort não nasce no cgroup, na GPU, no `crash_dump64`, no seccomp
nem em uma negação SELinux. O cgroup termina antes do erro; o primeiro retorno
incompatível é a consulta da capability 38. O código Android 17 em
`system/zygote/zygote/src/child_process.rs` percorre o complemento de
`cap_bound` e usa `cap_within_bound(...).expect("Failed to check capability
bound")`; o `EINVAL` do kernel vira panic e `SIGABRT`.

O header do ExtremeKRNL confirma a incompatibilidade:

```text
include/uapi/linux/capability.h:
CAP_AUDIT_READ = 37
CAP_LAST_CAP   = CAP_AUDIT_READ
```

O userspace do Android 17 foi compilado com as capabilities modernas:

```text
CAP_PERFMON            = 38
CAP_BPF                = 39
CAP_CHECKPOINT_RESTORE = 40
CAP_LAST_CAP            = CAP_CHECKPOINT_RESTORE
```

O código AOSP usado para a comparação foi o branch oficial
`android17-release`, commit
`c24023080df0bdb5988c1e0c641d494574a97c40`. A árvore local também confirma
que o `init` moderno exige por `static_assert` que `CAP_LAST_CAP` seja
`CAP_CHECKPOINT_RESTORE`.

O spam do `crash_dump64` é consequência: o filho já iniciou o handler do
`SIGABRT` e desaparece antes de o helper abrir `/proc/<pid>`. O próximo patch
deve backportar ao kernel 4.19 a ABI das capabilities 38–40, incluindo os nomes
correspondentes em `COMMON_CAP2_PERMS` do SELinux. Apenas silenciar o panic ou
o helper esconderia a incompatibilidade sem corrigi-la.

## Backport da ABI de capabilities exigida pelo Android 17 (2026-09-21 21:31)

Foi criado o patch do ExtremeKRNL:

```text
platform/exynos990/patches/extremekrnl/patches/0003-capabilities-add-android17-bounding-set-abi.patch
```

O autor registrado no patch é `At30c`. O patch
adiciona ao kernel 4.19 os números de ABI de `CAP_PERFMON` (38), `CAP_BPF` (39)
e `CAP_CHECKPOINT_RESTORE` (40), eleva `CAP_LAST_CAP` para 40 e acrescenta os
três nomes em `COMMON_CAP2_PERMS` do SELinux. A numeração e os nomes seguem o
Linux upstream v5.9. Isto faz `PR_CAPBSET_READ` e `PR_CAPBSET_DROP` reconhecerem
os bits consultados pelo Native Zygote do Android 17; não afirma implementar as
funcionalidades modernas de perf, BPF ou checkpoint/restore associadas a essas
capabilities.

O `customize.sh` do ExtremeKRNL aplica automaticamente todos os arquivos
`patches/*.patch`, portanto o novo patch já entra no fluxo normal e também na
chave do cache do kernel. As validações realizadas foram:

```text
git apply --check: aprovado antes da aplicação
git apply --reverse --check: aprovado depois da aplicação
kernel/capability.o: compilado
security/commoncap.o: compilado
security/selinux/avc.o: compilado
kernel/sysctl.o: compilado
Image completo: compilado e linkado com sucesso
```

O gerador do SELinux produziu também os novos bits esperados:

```text
CAPABILITY2__PERFMON            0x00000040U
CAPABILITY2__BPF                0x00000080U
CAPABILITY2__CHECKPOINT_RESTORE 0x00000100U
```

O artefato usado para a validação local foi:

```text
out/kernel_tmp-exynos990/out/arch/arm64/boot/Image
tamanho: 43241488 bytes
sha256: c7d11a613258a3568b2e2c534ce2db3c0974d7f9d6f15232be19d2cdb6791b84
```

Esta etapa comprova aplicação, compilação e integração do patch, mas ainda não
comprova o comportamento em execução. É necessário gerar/instalar uma build
que contenha esse kernel e repetir a abertura do Chrome/Edge. O resultado
esperado no ftrace é que as consultas 38, 39 e 40 deixem de retornar `-EINVAL`;
o kernel deve publicar `CAP_LAST_CAP=40`, permitindo que o laço do zygote
termine normalmente sem `SIGABRT`. O número 41 é apenas o primeiro índice fora
da ABI e não precisa ser consultado pelo zygote.

### Validação no aparelho (2026-09-21)

A build contendo o backport foi instalada e o Chrome voltou a funcionar. Isso
confirma em execução que a causa do abort do `zygote-child` era a ABI incompleta
de capabilities do kernel 4.19: o Android 17 consultava `CAP_PERFMON` (38), mas
o kernel anterior encerrava em `CAP_AUDIT_READ` (37) e devolvia `-EINVAL`.
O patch `0003-capabilities-add-android17-bounding-set-abi.patch` deve permanecer na
configuração de produção. Os módulos `appzygote_compat` e
`zzzzz_zygote_next_trace` continuam sendo apenas tentativas/instrumentação de
diagnóstico e podem ser retirados depois de uma última validação sem TRACE.

## Captura para diagnóstico de vídeo Telegram/Discord (2026-09-21 22:54)

O aparelho estava desconectado e a sessão anterior do tmux não estava ativa.
O script persistente foi restaurado em:

```text
scripts/capture_logcat_tmux.sh
```

A sessão destacada foi iniciada novamente:

```text
tmux attach -t y2s-logcat
tmux capture-pane -pt y2s-logcat:0 -S -40
```

Ela permanece aguardando o ADB e cria um diretório
`out/target/y2s/boot-diagnostics-<data>` quando o aparelho voltar a aparecer.
Cada conexão recebe um marcador `DEVICE_CONNECTED_<data>` e todos os buffers
do logcat são capturados até a desconexão. O script passou em `bash -n` e não
limpa o buffer anterior, para preservar o primeiro erro ao reproduzir a falha
de reprodução de vídeo nos aplicativos Telegram e Discord.

Em 2026-09-21 23:00 o script foi corrigido para usar `tee`: o mesmo fluxo agora
aparece ao vivo no painel do tmux e continua sendo salvo em `logcat.txt`. A
sessão foi reiniciada e confirmou a exibição de eventos atuais do aparelho.

### Diagnóstico do vídeo Telegram/Discord: geração de buffers (2026-09-21)

O log persistente confirmou que o decoder Exynos inicia normalmente e que a
alocação Mali também é concluída. A falha só aparece quando o `ACodec` troca a
Surface: `BufferQueueProducer` rejeita o buffer reutilizado com `-22` porque a
geração do buffer antigo não coincide com a geração nova da fila:

```text
[OMX.Exynos.avc.dec] setting surface generation to 11550745
BufferQueueProducer: attachBuffer: generation number mismatch [buffer 0] [queue 11550745]
ACodec: failed to attach buffer ... Invalid argument (22)
MediaCodec.native_setSurface
ExoPlayerImplInternal: Playback error
```

A análise do `libgui.so` do S926B encontrou a causa no
`android::Surface::attachBuffer`: o binário importado só copia
`mGenerationNumber` para o `GraphicBuffer` quando `mSharedBufferMode` está
ativo. O vídeo usa buffers comuns, portanto o buffer chega à checagem de
`BufferQueueProducer::attachBuffer` com a geração antiga. A checagem da fila
não foi removida; ela deve continuar protegendo buffers de outra geração.

Foi preparado o módulo `unica/mods/surface_generation_compat`, que altera
somente duas sequências ARM64 do `libgui.so` do S926B: torna incondicional a
cópia em `Surface::attachBuffer()` e mantém a geração local atualizada em
`Surface::setGenerationNumber()`. As sequências originais e substitutas foram
validadas por desmontagem; em ambos os casos apenas o salto condicional vira
`nop`, sem remover a checagem de geração do `BufferQueueProducer`.

O primeiro A/B foi testado no aparelho por bind-mount temporário, com reinício do
zygote e reprodução controlada no Telegram via scrcpy. O `libgui.so` alterado
foi carregado, mas o log continuou mostrando `generation number mismatch`
seguido de `MediaCodec.native_setSurface`/`Playback error`; portanto o primeiro
bypass não é uma correção suficiente e não deve ser incorporado à build ainda.

Também foi testada uma segunda variante temporária, que tornava incondicional
a atualização em `Surface::setGenerationNumber` além da escrita em
`Surface::attachBuffer`. Mesmo com as duas alterações, o log de 23:41:42
continuou rejeitando o buffer pela geração da fila. Isso descarta a hipótese
de que apenas essas duas escritas condicionais sejam a causa. Uma terceira
variante, que neutralizava a checagem de geração dentro de
`BufferQueueProducer::attachBuffer`, foi usada inicialmente somente como
diagnóstico; o bind-mount foi removido com reboot completo e o hash de
`libgui.so` retornou ao original. Na captura de 2026-09-22, porém, o módulo de
duas escritas já estava efetivamente carregado e o mesmo erro continuou
ocorrendo. Isso confirmou que a rejeição acontece no produtor, depois de
`Surface::setOutputSurface`, e não apenas nas escritas locais de `Surface`.

Por solicitação, a variante do produtor foi incorporada ao módulo, com versão
1.1. Ela altera somente a sequência ARM64 de
`BufferQueueProducer::attachBuffer` que compara
`GraphicBuffer::mGenerationNumber` com a geração da fila:

```text
09c841b908e540b91f01096be1190054
 ->
09c841b908e540b91f01096b1f2003d5
```

A comparação permanece no binário para facilitar diagnóstico, mas o `b.ne`
que retornava `-EINVAL` (`generation number mismatch`) vira `nop`. As demais
validações de slot, fence, fila e conexão continuam intactas. Esta é uma
compatibilidade específica para o buffer de vídeo reutilizado que chega com
geração 0; ainda não é evidência de que o comportamento seja seguro para todos
os produtores.

Validações locais realizadas:

1. A sequência original aparece exatamente uma vez no `libgui.so` da build.
2. A substituição mantém o mesmo tamanho e o resultado continua sendo um ELF
   AArch64 válido.
3. `bash -n` e `git diff --check` passaram.

Ainda é necessário gerar/instalar uma build com o módulo 1.1 e repetir o vídeo
do Telegram/Discord. O sucesso esperado é o desaparecimento conjunto de
`generation number mismatch`, `attachBuffer ... (-22)` e
`MediaCodec.native_setSurface`; se surgir corrupção, soft-reboot ou erro de
fence, o patch deve ser revertido e a solução deve voltar para uma troca de
surface sem reutilização de `setOutputSurface`.

### Causa do retorno `-22` no caminho ACodec

O retorno não é um erro aleatório do driver. O fluxo AOSP é explícito:

1. `MediaCodec::connectToSurface()` escolhe uma geração nova, chama
   `surface->setGenerationNumber()` e desconecta/reconecta a surface para
   descartar buffers livres antigos.
2. O caminho legado `ACodec::handleSetSurface()` percorre os buffers de saída
   já registrados e chama `surface->attachBuffer()` para reanexá-los à nova
   surface.
3. `BufferQueueProducer::attachBuffer()` compara a geração do
   `GraphicBuffer` com a geração atual da fila e retorna `BAD_VALUE` (`-22`)
   quando elas diferem.

No log, a sequência observada é exatamente essa: o decoder define `15191042`,
mas o buffer reanexado ainda informa `0`. Portanto, a incompatibilidade está
na propagação da geração durante a migração de buffers entre surfaces no
`libgui`/`ACodec` importado, e não no codec AVC, no gralloc ou no cgroup. A
implementação de referência pode ser conferida em:

```text
frameworks/native/libs/gui/BufferQueueProducer.cpp::attachBuffer
frameworks/av/media/libstagefright/ACodec.cpp::handleSetSurface
```

O módulo 1.1 continua sendo uma hipótese de compatibilidade para confirmar o
diagnóstico. A correção definitiva deve sincronizar a geração do
`GraphicBuffer` no caminho `ACodec`/`Surface` antes do `attachBuffer`, mantendo
a validação do produtor, em vez de simplesmente ignorar a divergência.

O módulo consolidado contém agora as duas escritas condicionais e a
compatibilidade do produtor, mas ainda precisa ser validado em uma build/flash em que o `libgui.so` seja
carregado antes do zygote. Binds feitos depois do boot não são evidência
suficiente, porque `libgui.so` já fica mapeado no zygote.

O scrcpy foi usado para controlar o aparelho e confirmar a reprodução visual,
mas não altera a cadeia `MediaCodec`/`Surface`; o erro permanece nessa troca
de superfície, não na alocação inicial do Mali.

### Backport enviado ao repositório próprio do kernel

O repositório `SSM_990v2BYEXTREME` já continha os commits de
`memory_recursiveprot` e `cgroup.kill`. O único trecho faltante do diagnóstico
do zygote foi aplicado diretamente no kernel e enviado para `origin/main`:

```text
50782bcd1df5 capabilities: add Android 17 bounding-set ABI
```

Arquivos alterados no kernel:

```text
include/uapi/linux/capability.h
security/selinux/include/classmap.h
```

O patch `0003` continua no repositório da ROM como fallback para clones antigos
do kernel. Quando o build usar o kernel a partir de `50782bcd1df5`, o
`customize.sh` detectará que o patch já foi aplicado e não o duplicará. Os
diretórios gerados `build/out`, `out` e `toolchain/clang_14` não foram incluídos
no commit do kernel.

## Correções preparadas para publicação (2026-09-22)

Foram validadas e preparadas para envio as correções de compatibilidade que
estavam no working tree:

- `__desixtification`: seleção explícita entre os APEXes Runtime de origem e o
  payload ARM32 legado, com linker/Bionic standalone e dependências mínimas.
- `cgroup_legacy`: descritores cgroup/task profiles compatíveis com a base S24+,
  `CgroupKill`, `libcgrouprc`/dependências coerentes e remoção do
  `vendor/lib64/libchrome.so` doador.
- `wfd_compat`: resolução recursiva das dependências ARM32 entre os
  doadores r9s/r11s e validação ELF sem correções manuais biblioteca por
  biblioteca.
- `config.sh` e `gen_config_file.sh`: propagação de
  `EXYNOS990_RUNTIME32_APEX_MODE` para reproduzir a variante de runtime usada
  no teste do Chromium.
- Cabeçalhos `From:` dos patches corrigidos para `At30c`, conforme a autoria
  solicitada.
- O patch `platform/exynos990/patches/extremekrnl/patches/0002-cgroup2-add-cgroup-kill-interface.patch`
  foi incluído no conjunto de compatibilidade do kernel.

As validações locais foram `bash -n` nos scripts alterados e `git diff --check`.
Os módulos `unica/mods/appzygote_compat`, `zzzzz_zygote_next_trace` e
`scripts/capture_logcat_tmux.sh` permanecem fora deste envio por serem
diagnósticos/experimentais, não correções confirmadas.

## ICDFix adaptado para One UI 9.0 (2026-09-22)

O patch recebido em `/home/ats0c/Downloads/ICDFix_8.5/` foi comparado com o
`services.jar` decodificado da base Android 17/One UI 9. A versão 8.5 removia
os campos `mVerifiableIntegrity` de `AttestParameterSpec` e alterava a ABI das
classes. Essa remoção não é segura na base 9.0, que ainda compartilha essas
classes com `samsungkeystoreutils` no bootclasspath.

O patch original foi adaptado em:

```text
unica/mods/knoxpatch/services.jar/0001-Bypass-ICD-verification.patch
```

A implementação original é de Devcore94; esta árvore contém a adaptação
mantida por At30c para a ABI da One UI 9.0. A adaptação mantém os campos e a ABI da 9.0, remove os setters/reflexões que
apenas forçavam o valor `false` em `DevicePolicyManagerService`,
`DarManagerService`, `UserManagerService` e `SemSsdidManagerService`, e força
o `AttestationUtils` de `services.jar` a não acrescentar o parâmetro KeyMint
`0x700008fe` de verifiable integrity. O crédito original de Devcore94 foi
mantido no cabeçalho do patch.

Validações realizadas:

1. `git apply --check` passou contra uma cópia limpa do `services.jar` 9.0.
2. O `services.jar` reconstruído com Apktool 3.0.3-16 smaliou as duas dex e
   foi empacotado sem erro.
3. A remoção foi limitada aos callers identificados; os campos compartilhados
   continuam presentes para evitar incompatibilidade de ABI.

Este ajuste trata somente a construção da solicitação de atestação em
userspace. Ele não altera o estado comprometido retornado pelo Keymaster/TEE;
no log de 2026-09-22 o Secure Folder ainda recebeu `SECURE_HW_ACCESS_DENIED`
(-45) em `KnoxTestKey`, portanto a eficácia no hardware precisa ser validada
 com uma nova build instalada.

## Teste do caminho Secure Folder/KnoxTestKey (2026-09-22)

Foi adicionado `unica/mods/knoxpatch/services.jar/0002-Test-bypass-Knox-key-installability.patch`.
Ele faz `DarManagerService.isKnoxKeyInstallable()` retornar `true` antes da
tentativa de atestação de `KnoxTestKey`. O patch é somente diagnóstico: não
modifica VaultKeeper, Keymaster, TEE ou chaves protegidas por hardware. Se o
Secure Folder continuar falhando após essa etapa, a rejeição ocorre abaixo do
framework e o log deve continuar mostrando `SECURE_HW_ACCESS_DENIED (-45)`.
## VNDK v30 cgroup client repair (2026-09-22)

The boot log from a clean checkout showed that vendor audio, DRM, Widevine,
and OMX services could not link `libprocessgroup.so` because the isolated
`com.android.vndk.v30` namespace did not contain `libcgrouprc.so`. The earlier
cgroup modules only installed loose `/system/lib` and `/system/lib64` copies;
that does not satisfy an APEX linker namespace.

`unica/patches/vndk/customize.sh` now rebuilds the target VNDK v30 payload
for the Exynos 990/API-30 target when either cgroup client is missing. It imports the target firmware's
Android 33 libraries (both ARM32 and ARM64), validates that they export the
required `LIBCGROUPRC_30` ABI, preserves the payload metadata, rebuilds and
AVB-signs the APEX, and verifies that both libraries are present in the final
`apex_payload.img`. The target libraries were selected instead of the newer
Android 17 donor copies because `libprocessgroup.so` in this VNDK explicitly
requires the v30 symbol version.

The VNDK module still skips rebuilding when an incremental work directory
already contains both payload libraries. A fresh/incremental build must run
the VNDK module so the repaired APEX is included in the generated system_ext
image.

## USB power transition screen-timeout fix (2026-09-22)

The connected device reported `stay_on_while_plugged_in=0` and
`mStayOn=false`, but `PowerManagerService` still refreshed user activity after
every charger/USB transition. That path can keep an already interactive screen
on for another full timeout whenever the cable is connected. The device's power
history confirmed the related `plugged_in` wake event.

The framework compatibility patch
`platform/exynos990/patches/framework_compat/smali/system/framework/services.jar/0002-avoid-resetting-screen-timeout-on-power-plug.patch`
guards that `userActivityNoUpdateLocked()` call whenever the current or
previous plug type is USB (`2`). This also covers a disconnect/reconnect
oscillation; AC and wireless-only transitions retain their stock behavior. The normal
`wakePowerGroupLocked()` path remains intact, so a device that is actually asleep
can still wake for the charging UI; an already-awake display no longer receives
an artificial timeout reset from a USB connection or its matching disconnect.
This is an experimental fix
and must be validated with a build installed on hardware.

Validation performed: `git apply --check` passed against a clean decoded
`services.jar`; the assembled smali keeps `.locals 14` and stores the previous
plug type in `p1` (register `v15`), avoiding both the wide-register verifier
failure and the `v16` register limit failure. A controlled device test with a 5-second timeout showed that a
USB connection while awake still allowed the display to turn off after 5 s;
the simulated disconnect path was also exercised. `git diff --check` reported
no whitespace errors. After the first failed incremental build left a decoded
tree with the obsolete `.locals 15`/`v14` variant, that generated tree was
updated to the final patch as well, so the next incremental invocation can
recognize it as already applied. No build or flash was run after this fix.

## Charging UI waking a black display (2026-09-23)

The boot diagnostic from 2026-09-23 showed that the USB/power transition patch
was not the only wake path. `PowerUI.ChargingInfoExecutor` (SystemUI UID
10047) explicitly called `PowerManager.wakeUp()` while displaying the
incomplete-charger popup. Immediately afterward SurfaceFlinger powered the
display on, while the panel still had no visible frame. The same call also
exists for the slow-charger toast. This matches the symptom of a display that
is electrically on but completely black and does not point to a normal
screen-timeout reset.

The new patch
`platform/exynos990/patches/framework_compat/smali/system_ext/priv-app/SystemUI/SystemUI.apk/0001-prevent-charging-info-from-waking-black-display.patch`
replaces both charging-info `PowerManager.wakeUp()` calls with `nop`. The
charging popup/toast remains available; only the unsolicited display wake is
suppressed so the normal display pipeline can decide when to turn the panel
on. The framework patch remains separate because it handles a different
`PowerManagerService` user-activity path.

Validation performed: `git apply --check` passed against the clean decoded
SystemUI.apk, and `git diff --check` reported no whitespace errors. No ROM
build or flash was run after this change; hardware validation is still
required. The first placement under `smali/system/system_ext` was not
discovered by `apply_modules.sh`; the patch is now under the repository's
correct `smali/system_ext` path, matching the existing SystemUI modules.

## Make ROM log generation (2026-09-23)

`buildenv.sh` writes `make_rom-YYYYMMDD_HHMMSS.log` through the `run_cmd`
wrapper, exposed as `unica make_rom ...`. The `aether` alias intentionally
executes `./scripts/make_rom.sh` directly and therefore does not create that
log file; its output only appears in the terminal unless redirected manually.
The last wrapper-generated log in this checkout is from 2026-09-21. Builds
that updated `work_dir` on 2026-09-23 did not produce a newer `make_rom` log
for this reason.

To retain a build log, use:

```bash
source buildenv.sh y2s
unica make_rom -c --no-rom-zip
```

The SystemUI charging patch must be checked in that new log by searching for
`SystemUI: do not wake display for charging info overlays`.

## Black panel after USB connection: doze-charging cause (2026-09-23)

The installed SystemUI was verified by SHA-256 against `work_dir`, and its
decoded smali contains the two `nop` instructions from the charging-info
`wakeUp()` patch. The symptom therefore persisted with that patch genuinely
installed.

The reproduction at 03:47:33 identified the remaining path. With the display
already OFF, USB insertion caused `AodTriggerController` to request a doze
charging session. `DozeMachine` changed from `DOZE` to `DOZE_AOD`, the display
changed from OFF to DOZE, and the Exynos HWC received an unblank request while
`DisplayPowerController` reported brightness `0.0`/2 nits. This is the direct
explanation for a physically powered panel with no visible image.

`platform/exynos990/patches/framework_compat/smali/system_ext/priv-app/SystemUI/SystemUI.apk/0002-keep-charging-animation-in-legacy-doze.patch`
initially made `AodTriggerExecutor.isDozeChargingCondition()` return false.
Hardware testing confirmed that this stopped the black-panel symptom, but it
also disabled the charging animation while the screen was off.

The patch was refined after comparing the One UI 9 implementation with the
stock S20+ SystemUI. The stock implementation starts the PluginAOD charging
animation and holds its draw wakelock without forcibly promoting the panel out
of DOZE through the new override API. The refined patch therefore leaves
`isDozeChargingCondition()`, the doze session, animation and passive refresh
rate token unchanged, and replaces the One UI 9
`setDisplayStateOverride(..., Display.STATE_ON, 4500)` call with `nop`.

Hardware testing showed that the animation returned, but the panel still
remained active. The log then exposed the actual failed shutdown operation:
after `AnimTimeout` and `DozeChargingSession.close`, the call to
`PluginAODManager.chargingAnimStarted(false)` ran on `SystemUIBg-8`.
`DozeMachine.requestState()` rejected it with `IllegalStateException: should
be called from the main thread`, leaving the machine in `DOZE_AOD` after the
animation disappeared.

The final patch adds a small Runnable and posts `chargingAnimStarted(false)`
to `PluginAODManager.mHandler`, which is constructed with
`Looper.getMainLooper()`. This preserves the charging animation and allows
DozeMachine to perform its normal exit transition when the animation timeout
fires. The force-ON override remains disabled because the animation already
renders through the DOZE_AOD path.

`git apply --check` passed against the currently decoded SystemUI and
`git diff --check` reported no whitespace errors. No ROM build or flash was
run after this refined change. The existing decoded incremental tree was also
aligned with the final variant: the original doze eligibility logic was
restored, the force-ON call is `nop`, and the main-thread Runnable is present.
A clean apply check and a reverse apply check against that tree both passed,
so the build helper can recognize the final patch if it reuses the tree.

## Charging/display fix confirmed and published (2026-09-23)

The new build was tested on the S24+ target device and the USB charging
scenario is now resolved: the display no longer remains active with a black
panel, while the charging animation remains available and exits normally.
The fix is published as three patches:

1. `platform/exynos990/patches/framework_compat/smali/system/framework/services.jar/0002-avoid-resetting-screen-timeout-on-power-plug.patch`
   prevents the USB plug/disconnect transition from refreshing the interactive
   screen timeout.
2. `platform/exynos990/patches/framework_compat/smali/system_ext/priv-app/SystemUI/SystemUI.apk/0001-prevent-charging-info-from-waking-black-display.patch`
   removes the two unsolicited charging-info `PowerManager.wakeUp()` calls.
3. `platform/exynos990/patches/framework_compat/smali/system_ext/priv-app/SystemUI/SystemUI.apk/0002-keep-charging-animation-in-legacy-doze.patch`
   keeps the legacy DOZE charging animation, avoids the incompatible force-ON
   display override, and posts the animation-close callback to the main
   looper so `DozeMachine` can leave `DOZE_AOD` cleanly.

Only these patches and this documentation entry are being committed. No ROM
build or flash was executed while publishing them.

## Source-firmware MIDAS stack (2026-09-23)

The current Photo Remaster crash showed a mixed stack: the S24+ engine was
loading the S21 `p3sxxx` PhotoRemaster APK and MIDAS libraries. The MIDAS
module now unconditionally restores the source-firmware stack, preventing an
environment override from selecting the incompatible S21 donor. It restores
`vendor/etc/midas`, `vendor/etc/VslMesDetector`,
`PhotoRemasterService.apk`, `libmidas_core.camera.samsung.so`, and
`libmidas_DNNInterface.camera.samsung.so` from the configured S24+ source
firmware. The change has only passed shell syntax/read-only checks; no build
or flash was run.

The first test with the coherent S24+ stack reached `AI_UPSCALE_4X`, but the
S24+ `midas_config.json` selected its generic fallback because the device
reports `ro.soc.model=Exynos 990`. That fallback requested the absent
`SRIBMidas_aiUPSCALER_4X_LITE_V100_INT8.tflite`, after which the DNN cleanup
triggered a Scudo misaligned-pointer abort. The MIDAS module now adds the
existing Lite 2x/3x/4x model assets from the `p3sxxx` prebuilt and explicitly
associates the fallback entry with `Exynos 990`; the Photo Remaster APK and
MIDAS engine/core libraries remain from the S24+ source stack. This is a
static configuration change only; no build or flash has been run.

## HDR10+ recording failure and LOG-video compatibility (2026-09-23)

The capture from `out/target/y2s/boot-diagnostics-2026-09-23_20:17:44-0300`
reproduced the HDR10+ failure. The camera requests recording mode `10`,
`StagefrightRecorder` sets the HDR10+ color aspect, and the legacy
`OMX.Exynos.HEVC.Encoder` is created successfully. Android 17's source
`libstagefright.so` then logs `Do not enable feature for HDR10Plus recording`
and aborts `mediaserver` at
`frameworks/av/media/libstagefright/ACodec.cpp:4496` (`CHECK(false)`). This is
a framework/legacy-encoder compatibility abort, not a camera-app crash; the
`crash_dump64` tombstone was generated normally.

`platform/exynos990/patches/camera/customize.sh` now adds a source-SDK-37-only
hex patch that branches directly to the normal encoder continuation, skipping
both the `__android_log_assert` call and the following CFI slowpath. The first
test variant only NOPed the assert; the device then correctly changed the
failure from `SIGABRT` to a CFI `SIGTRAP`, proving that the post-assert CFI
sequence also had to be skipped. The exact surrounding instruction sequence
is matched, and an incremental rerun recognizes the first variant, so the
patch cannot silently apply to an unrelated `libstagefright.so`. HDR10+
metadata support still needs to be validated on-device after this revised
build.

The follow-up capture at
`out/target/y2s/boot-diagnostics-2026-09-23_21:19:22-0300` confirmed the
intermediate patch was active: the original `SIGABRT` was gone, but
`__cfi_slowpath` trapped at `setupVideoEncoder+3612` (`SIGTRAP`).

LOG video is a separate compatibility issue. The S24+ camera feature file and
floating features advertise `SUPPORT_LOG_VIDEO`, `SUPPORT_PREVIEW_LUT`,
`SEC_FLOATING_FEATURE_CAMERA_CONFIG_LOG_VIDEO=V1.0`, and the gallery LOG color
correction flag. The current S20+/Exynos 990 target feature files omit those
flags, and the target vendor camera HAL has no matching LOG-preview/LUT
symbols, while the S24+ HAL does. Therefore the LOG UI cannot be enabled safely
by copying only the S24+ XML; it requires a compatible Exynos 990 HAL path and
its LUT assets. No LOG flags or S24+ HAL blobs were forced in this change.

No ROM build or flash was run after the HDR10+ patch; only shell syntax,
pattern-match, disassembly, and whitespace checks were performed.

### Additional findings from the 21:19:22 capture

The USB cable is not implicated: the failure follows the camera's normal
`OMX.Exynos.HEVC.Encoder` setup and occurs inside `mediaserver`, without a USB
or projection error on that path.

There are three additional compatibility signals to keep separate from the
fatal HDR10+ guard:

* `OMXUtils` emits 199 warnings for vendor color formats
  `0x7f000011`, `0x10`, `0x7f00a000`, `0x7f000789` (and occasionally
  `0x7f000012`, `0x0f`, `0x7f42016b`). The target's S20+ OMX encoder reports
  these formats, while the active `libstagefright_omx_utils.so` is the S24+
  source binary. This is a strong framework/vendor color-format mismatch
  candidate; it must be resolved by mapping the formats or using a matching
  media stack, not by merely hiding the warning.
* The codec-list generator repeatedly reports that entries in
  `vendor/etc/media_codecs_performance.xml` do not correspond to a currently
  registered OMX codec. The base `media_codecs.xml`, performance XML, OMX
  libraries, and `somxreg.conf` are byte-identical to the S20+ target firmware,
  so this is a source Android 17 codec-list/legacy-OMX registration mismatch.
  It is secondary for now: the HEVC encoder is still instantiated afterwards.
* `Failed to query component store/interface for system resources: 6` appears
  both during this recording and for unrelated Codec2 clients. It indicates a
  missing optional resource query in the mixed media stack, but is not by
  itself proof of the HDR10+ crash.

Before the `SIGTRAP` at `21:19:36.178`, the camera HAL already reports
`VIDIOC_DQBUF`/`Invalid argument`, invalid buffer states, frame-count
mismatches, and dropped output frames around `21:19:35.216`. These errors can
be a preceding stream/format failure or cleanup triggered by the recording
request and need a camera-only comparison capture; they are not explained by
the later `__cfi_slowpath` trap alone.

After the media failure, the camera frame processor times out repeatedly
(`-110`) and `OMXNodeInstance` reports a dead observer; those are consequences
of `mediaserver` dying. Separately, at `21:20:21.703`, `eden_runtime` crashes
with `SIGSEGV` while freeing NPU models, followed by invalid-model/buffer
cleanup errors and a lazy-HAL restart. That is a real independent NPU/HAL
problem, not evidence that HDR10+ itself caused the crash.

No additional patch, build, or flash was performed for these findings.

### HDR10+ follow-up: guard bypass was insufficient (2026-09-23)

The next capture, `out/target/y2s/boot-diagnostics-2026-09-23_22:44:01-0300`,
proves that the first HDR10+ guard patch was present but incomplete. The
`Do not enable feature for HDR10Plus recording` message remained (it is the
diagnostic log emitted before the guard), and the original abort was replaced
by a SIGSEGV in the CFI runtime:

```text
Fatal signal 11 (SIGSEGV) in mediaserver/CodecLooper
#00 libdl.so (__cfi_slowpath+28)
#01 libstagefright.so (ACodec::setupVideoEncoder+3668)
```

The work-dir disassembly maps frame `+3668` to the Android 17 CFI alternate
path at `0xecb2c`. The legacy Exynos OMX object has a different vtable
identity, so the generated `b.ne` path passes an incompatible legacy vtable
pointer to `__cfi_slowpath`. This is why merely removing
`__android_log_assert()` did not produce a working recording.

That interpretation was superseded on 2026-09-24. The generated CFI branches
protect normal `ACodec` virtual calls and must not be disabled globally. The
camera script now restores all six branches if an incremental work directory
still contains the experimental NOPs.

The later Scudo tombstone made the narrower failure explicit:
`ACodec::setupVideoEncoder+2076` aborts while move-assigning the
`std::string` used only to cache a Base64-encoded process name for Samsung's
`reconfigEncoder4OtherApps()` helper. The invalid deallocation value decodes
to ASCII bytes, consistent with corrupted short-string state. This cache is
not part of OMX HEVC configuration or HDR10+ metadata delivery. The current
patch therefore skips only the process-name/cache block and resumes at the
existing encoder continuation; all CFI checks remain intact.

A temporary KernelSU module was prepared to test this binary without a ROM
build, but it never became active. `Meta-Overlayfsx` reports
`Function not implemented` while mounting `/system`, and a direct bind mount
is also unavailable in the granted root context. The live
`/system/lib64/libstagefright.so` hash remained unchanged, so neither reboot
is encoder-test evidence. The temporary module was marked for removal, and the
camera HDR preferences were not changed during this failed deployment. The
next valid test therefore requires the normal incremental ROM path.

Static validation of the superseded experiment had passed, but its six CFI
NOPs are no longer part of the intended result. No build or flash was run after
the process-cache replacement was prepared.

### HDR10+ runtime isolation and recording validation (2026-09-23)

The live device test isolated the remaining failure to the persisted HDR10+
setting rather than ordinary video recording. The camera preferences contained
`hdr10_recording=1` and `hdr10_recording_indicator=1`; opening recording then
selected `recordingmode: 10`, entered `OMX.Exynos.HEVC.Encoder`, and aborted
`mediaserver` in Scudo while assigning a `std::string` inside
`ACodec::setupVideoEncoder`.

For the controlled test, both values were saved and set to `0`. The camera
entered Video mode, recorded for approximately six seconds, and stopped cleanly
with `recordingmode: 0` using `OMX.Exynos.AVC.Encoder`. The log shows 178
encoded video frames, 278 audio frames, `Status:0`, and no `Scudo`, `Fatal
signal`, `MEDIA_ERROR_SERVER_DIED`, or `mediaserver` death. The capture is
`/tmp/camera-hdr-disabled-record.log`; the original preferences are backed up
on-device at `/data/local/tmp/camera_preferences.xml.before-hdr-test`.

An initial SamsungCamera workaround that forced `HDR10_RECORDING` to `0` was
prepared after this test, but it was explicitly rejected and removed on
2026-09-24. HDR10+ must remain exposed while the actual encoder/framework
compatibility failure is corrected. The runtime test is retained here only as
evidence that ordinary recording and the base Exynos OMX encoder are healthy.
No ROM build or flash was run for the removed workaround.

### Compatibility fixes prepared for the next build (2026-09-23)

Two functional changes were added after the capture analysis; the other two
items were audited and deliberately left untouched because there is no safe
ABI-preserving fix yet. No build or flash was run:

* `platform/exynos990/patches/eden/customize.sh` now restores the S20+ target
  system-side EDEN HIDL bridge as a unit (`libeden_nn_on_system.so`,
  `libeden_rt_stub.edensdk.samsung.so`, and
  `vendor.samsung_slsi.hardware.eden_runtime@1.0.so`) when the source SDK is
  37 or newer.  The source AIDL stub is not mixed into those three libraries.
  This is aimed at the independent `eden_runtime` SIGSEGV during model
  cleanup.
* `platform/exynos990/patches/miscs/customize.sh` removes
  `vendor/etc/media_codecs_performance.xml` for source SDK 37+.  The file is
  the S20+ legacy OMX performance overlay; Android 17 reports 180 entries as
  non-existing codecs.  `media_codecs.xml` and the C2 metadata are retained.
* The vendor color-format warnings were not force-mapped.  They originate in
  the Android 17 `libstagefright_omx_utils.so` parser, while the Exynos 990
  OMX driver advertises Samsung-private formats (`0x7f000011`,
  `0x7f000789`, `0x7f42016b`, etc.).  The available target parser is an older
  ABI and cannot safely replace the source parser.  A binary mapping without
  the exact plane layout would risk corrupting buffers, so this item remains
  intentionally unmodified pending a controlled codec-format test.
* The `Failed to query component store/interface for system resources: 6`
  message is emitted for unrelated apps as well as the camera.  It is an
  optional Codec2 resource-query failure, not an absent library proven by the
  capture; no unsafe S24+ Codec2 HAL was imported for it.

## GPU driver-family alignment for Chromium/social apps (2026-09-23)

Instagram/TikTok/Chromium workloads were heating the device quickly.  The
strongest static mismatch in the 2026-09-23 boot capture was the graphics
driver stack: source S24+ `EX2400` properties and APKs were left alongside the
S20+ `EX9830` target pair.  The log showed `ro.gfx.driver.0/1` being
overridden to `com.samsung.*.ex2400`, while the target packages were rejected
as not being in the allowed preload list.  The same capture also showed Mali
`No OPPs found in device tree!` and repeated `SF_GPU_MINLOCK [TIMEOUT / 2000]`
events, so the driver mismatch is being treated as the first reversible test,
not as proof that the kernel is the only cause.

`platform/exynos990/patches/stock_blobs/customize.sh` now performs the
following only when the target firmware contains both EX9830 APKs:

* removes the source `GameDriver-EX2400` and `DevGPUDriver-EX2400` trees;
* restores the target `GameDriver-EX9830` and `DevGPUDriver-EX9830` pair;
* restores their target `.apk.prof` files when present;
* sets `ro.gfx.driver.0/1` in both `product` and `vendor` to the actual EX9830
  package IDs;
* replaces EX2400 entries with EX9830 entries in
  `allowed-system-preload-apps.xml`, `apks_count_list.txt`, and
  `irremovable_list.txt` when those generated metadata files exist.

The script passed `bash -n` and `git diff --check`.  No ROM build or flash was
performed after this change.  The next test must be done with USB charging
disconnected and should compare `dumpsys thermalservice`, Mali/devfreq state,
and `logcat` before and after opening Instagram and TikTok.  If heat remains,
the next isolated A/B is disabling the forced Vulkan/hint-manager properties;
the kernel OPP/DVFS tables should not be changed blindly before that result.

## HDR10+ follow-up: patch was in the wrong execution path (2026-09-24)

The capture
`out/target/y2s/boot-diagnostics-2026-09-24_01:09:17-0300/logcat.txt`
shows that HDR10+ is still not functional. The camera enables
`hdr10_recording=1`, creates `OMX.Exynos.HEVC.Encoder`, and `mediaserver`
dies at:

```text
libdl.so (__cfi_slowpath+28)
libstagefright.so (ACodec::setupVideoEncoder+3696, PC 0xecb48)
```

The fault is `SEGV_ACCERR`, not the old HDR10+ `SIGABRT`; the crash is the
generated CFI alternate path reached by the legacy Exynos OMX vtable. The
crash dump was captured normally and `MEDIA_ERROR_SERVER_DIED` is a
consequence of `mediaserver` exiting.

The previous HDR10+ changes had been placed only in
`platform/exynos990/patches/camera/customize.sh`, while the build log proves
that the active patch script is `unica/patches/camera/customize.sh`. A clean
build could therefore omit the fix. The compatibility block is now present
in the active script (and mirrored in the platform-specific script):

* skip the Android 17 HDR10+ fatal-assert path;
* bypass only the six CFI conditional branches in
  `ACodec::setupVideoEncoder`, rather than disabling CFI globally; and
* skip only the incompatible optional Base64 process-name cache.

Each replacement is guarded by its complete byte pattern and aborts if the
expected source-SDK-37 blob is not present. This change has passed `bash -n`
and `git diff --check`; no build or flash has been run yet. The next test must
verify that `make_rom` prints the new
`Applying Exynos 990 HDR10+ ACodec compatibility` step and that the installed
`libstagefright.so` contains the six NOP replacements before reproducing HDR.

The subsequent test confirmed the six replacements were present in the
installed library, but the crash remained at the same `ecb48` address. The
remaining path was the two HDR metadata calls immediately after those six
branches (`setColorAspectsForVideoEncoder` and
`setHDRStaticInfoForVideoCodec`); their CFI branches were not included in the
first set. The active script now covers eight function-local branches in
total. No build or flash has been run after adding these two patterns.

### Persistent capture reopened (2026-09-24 09:17:06 -0300)

The detached `y2s-logcat` tmux session was reopened with
`scripts/capture_logcat_tmux.sh`. It remains alive while ADB is disconnected,
and will create a fresh timestamped `boot-diagnostics-*` directory and
`DEVICE_CONNECTED_<timestamp>` marker as soon as the device reconnects. At
the time of reopening, `adb get-state` reported no connected device; no ROM
or repository build was run.

### HDR10+ helper CFI follow-up (2026-09-24)

The latest capture moved the failure past the eight previously bypassed
`setupVideoEncoder()` branches. The camera now reaches
`ACodec::setColorAspectsForVideoEncoder()`, but `mediaserver` still exits with
`SIGSEGV` in `libdl::__cfi_slowpath` at `libstagefright.so+0xf1e8c`.
The tombstone identifies the same legacy Exynos OMX vtable/type-cookie mismatch
(`x0=0x5b6339fcfa1859d1`, `x1=0x65006365646f4341`), so this is not evidence of a
new sensor or HDR metadata failure yet.

The active and mirrored camera patch scripts now add six narrowly matched NOP
replacements for the CFI alternate branches: four in
`setColorAspectsForVideoEncoder` (`+0x280`, `+0x2e0`, `+0x2b0`, and `+0x2c8`)
and two in `setHDRStaticInfoForVideoCodec`. The latter are reached immediately
after the color-aspects helper. Together with the eight
existing `setupVideoEncoder()` replacements, the guarded compatibility block
covers fourteen HDR-path branches. Each replacement requires its exact
source-SDK-37 byte sequence and remains idempotent on incremental builds; CFI
is not disabled globally. This change has only passed shell syntax and diff
checks. No build or flash was run after it, so HDR10+ is not yet declared fixed.
### HDR10+ runtime after the fourteen CFI bypasses (2026-09-24)

The captures
`out/target/y2s/boot-diagnostics-2026-09-24_10:34:20-0300/logcat.txt` and
`out/target/y2s/boot-diagnostics-2026-09-24_10:34:26-0300/logcat.txt` were made
after the build that applied all fourteen byte patches. They confirm that the
patches are active: the previous fault at
`setColorAspectsForVideoEncoder+680` (`+0xf1e8c`, the CFI alternate stub) moved
to `setColorAspectsForVideoEncoder+148` (`+0xf1c78`).

The new PC is the first direct dereference after the CFI branch was bypassed:
`ldr x25, [x24]`. The tombstone has `x24=0x6d2f76612f736b72`, which is ASCII
data (`"rks/av/m"`) rather than a valid pointer, and `x19` points into the
`libstagefright.so` read-only string table at the literal `"ACodec"` instead of
an `ACodec` heap object. The same invalid object state is visible one level
earlier in `LoadedState::onConfigureComponent`, whose parent pointer field is
used to call `configureCodec`.

This proves that the remaining failure is an ACodec object/ABI or symbol-
interposition mismatch between the Android 17 framework media stack and the
legacy Exynos 990 OMX stack. It is no longer a missing CFI branch. Adding more
NOPs would only skip further checks and dereference more invalid fields; it
cannot restore the object layout. The log also still reports the known vendor
color formats (`0x7f000011`, `0x10`, `0x7f00a000`, `0x7f000789`) and then
`MEDIA_ERROR_SERVER_DIED`, but those warnings occur after the invalid ACodec
state has already entered configuration.

No additional CFI patch was added. The next valid fix must align the complete
`ACodec`/`libstagefright` ABI (or use a matching target media stack), followed
by a fresh HDR test; the fourteen-branch bypass remains only a diagnostic
experiment and does not make HDR10+ functional.

### HDR10+ root cause in the fatal-block bypass (2026-09-24)

Deeper disassembly superseded the ABI/interposition conclusion above. The
invalid pointer was produced deterministically by the experimental patch
itself. In `ACodec::setupVideoEncoder()`, the Android 17 fatal block starts at
`0xecaa0`; because `__android_log_assert()` is declared `noreturn`, the
compiler legitimately reuses callee-saved register `x19` for the static
`"ACodec"` log tag at `0xecaa8`. The previous patch escaped from the block only
at `0xecae0`, after that assignment, and returned to normal setup at `0xec3f8`.
Every later helper therefore received the read-only log-tag address as its
`ACodec *this`. This exactly explains both tombstone values: `x19` points to
the `"ACodec"` literal and the later `x24` load decodes adjacent
`frameworks/av` text as a pointer.

`platform/exynos990/patches/camera/customize.sh` now patches the first
x19-clobbering instruction at `0xecaa8` into `b 0xec1d0`. Both fatal-block
entries retain the real `ACodec` pointer and continue through the existing OMX
setup path. The original assert and every generated CFI check remain present;
the fatal block is simply unreachable for this guarded Exynos 990 case. For
incremental work directories, the script also restores the superseded assert
jump, all fourteen CFI NOPs, and the process-cache bypass before applying the
new branch. The duplicated device-specific block was removed from
`unica/patches/camera/customize.sh`; the implementation now has one owner in
the Exynos 990 platform module.

Static migration was tested on a copy of the currently patched work-dir
library. Its disassembly contains `ca fd ff 17` at `0xecaa8`, decoded as
`b 0xec1d0`; the branch at `0xf1c64` and the remaining CFI sites match the
unmodified S24+ source again. After migration, binary differences from the
source are limited to the existing model-name, fread-bound, encoder-input/SVC,
and new fatal-entry compatibility patches. Both camera scripts pass `bash -n`
and the repository passes `git diff --check`. No ROM build or flash was run,
so runtime HDR10+ recording still requires the next installed build test.

### HDR10+ encoder negotiation failure after the fatal-block fix (2026-09-24)

The build containing the corrected fatal-block branch no longer crashes
`mediaserver`, but entering HDR10+ video mode displays the generic camera error
that the recording could not be saved. The capture at
`out/target/y2s/boot-diagnostics-2026-09-24_11:52:10-0300/logcat.txt` proves
that this is not a filesystem failure: `StagefrightRecorder` selects recording
mode 10 and creates `OMX.Exynos.HEVC.Encoder`, then `ACodec` returns `-61`
(`ENODATA`) while configuring the codec. `MediaRecorder::prepare()` fails
before a frame is encoded, so the empty output file is subsequently truncated.

Static analysis identified the exact compatibility boundary. Android 17 asks
the HEVC component for profile `8192`
(`OMX_VIDEO_HEVCProfileMain10HDR10Plus`). The Exynos 990 Android 11 OMX
component's profile query at `Exynos_HEVCEnc_GetParameter+0x5f8` enumerates an
internal three-entry table containing only Main (`1`), Main10 (`2`) and
Main10HDR10 (`4096`). Exhausting that table returns `OMX_ErrorNoMore`, which
Stagefright surfaces unchanged as `-ENODATA` (`-61`). The advertised input
formats include `AndroidOpaque` (`0x7f000789`), so the earlier color-format
hypothesis is not the cause of this particular prepare failure.

`platform/exynos990/patches/camera/customize.sh` now adds a narrow Android 17
profile bridge in `libstagefright.so`. The otherwise unreachable HDR10+ fatal
block is reused as a six-instruction trampoline from
`ACodec::setupHEVCEncoderParameters()`: only requested profile `0x2000` is
translated to the legacy component's `0x1000` for profile verification and the
OMX HEVC parameter; every other HEVC profile remains unchanged. Both original
fatal-block entries now branch directly to the normal encoder path before x19
can be clobbered. The script recognizes both a clean source blob and an
incremental work directory carrying the previous fatal-entry patch.

The byte patches were applied to a temporary copy of the clean S24+
`libstagefright.so` and disassembled. The two fatal entries resolve to
`b 0xec1d0`, the HEVC profile load at `0xf10a8` resolves to the trampoline at
`0xecab0`, and the trampoline conditionally stores `0x1000` before returning to
`0xf10ac`. `bash -n` and `git diff --check` pass. No ROM build was executed.
The next installed-build test must first confirm that `ACodec configureCodec
returning error -61` and `MediaRecorder prepare failed: -61` are absent, then
verify that a saved HEVC file contains HDR10+ dynamic metadata rather than
assuming successful encoder creation alone proves full HDR10+ operation.

### HDR10+ confirmed functional on device (2026-09-24)

The ROM containing the HEVC profile bridge was built, installed and tested on
the device by the maintainer. HDR10+ recording is now functional. This runtime
result confirms that translating the Android 17 request from profile `0x2000`
to the Exynos 990 OMX profile `0x1000` removes the `-61` encoder-negotiation
failure while preserving the vendor HDR10+ recording path. Keep the guarded
fatal-block/profile trampoline in the Exynos 990 camera module; it is no longer
an unverified diagnostic experiment.

### HDR10+ profile bridge made layout independent (2026-09-25)

The device-confirmed bridge was hardcoded as byte patterns for one donor build.
That is correct but brittle: the patterns only exist if the source firmware
keeps the same instruction sequence, and the `== 36` source branch had no
bridge at all, so a build taken from the SDK 36 source kept the `-61`
negotiation failure silently. `libstagefright.so` is a source-firmware
library, not a target one, so the fix has to be resolved from whatever binary
the build copies in, not from a per-target list.

The branch is chosen by `SOURCE_PLATFORM_SDK_VERSION`, which describes the
*source* configuration and not the target device:

| source config | donor | `SOURCE_PLATFORM_SDK_VERSION` | shape |
| --- | --- | --- | --- |
| `unica/configs/essi.sh` | S24+ (Exynos 2400) | 37 | `frame` (`ldur`) |
| `unica/configs/qssi.sh` | S22 (Snapdragon) | 36 | `stack` (`ldr`) |

Both branches install the bridge, so every Exynos 990 target (`x1s`, `y2s`,
`y2slte`, `z3s`, `c1s`, `c2s`, `r8s`) is covered regardless of which source it
was built from, and each one gets the shape its own donor actually uses. Only
the `essi` path has been confirmed on a device; the `qssi` path is validated
statically.

`platform/exynos990/patches/camera/patch_hdr10plus_profile.py` replaces the
static patterns. It parses the ELF program headers, decodes the AArch64
instructions around both places and computes the absolute branches at patch
time:

* the profile copy in `ACodec::setupHEVCEncoderParameters()`, recognised by the
  requested-profile load followed by the `mov x0, x19 / mov w1, #1` OMX call
  setup, in either the One UI 9 callee-frame form (`ldur w2, [x29, #-0x20]`)
  or the One UI 8 stack form (`ldr w2, [sp, #8]`);
* the HDR10+ fatal block in `ACodec::setupVideoEncoder()`, recognised by the
  error-code store, the `ACodec` log-tag pair and the level-6 assert, whose
  assert-message setup becomes the six-instruction trampoline;
* the block entries, found as every branch target inside that block, and the
  normal continuation, taken as the fall-through of the guard that jumps to the
  last entry, so the reused assert is bypassed before x19 is clobbered.

Uniqueness is required, not assumed: an absent, ambiguous or unrecognised
layout aborts the build with a message naming the problem instead of silently
leaving HDR10+ broken, which is what the old `Skipping legacy HDR10+ blob on
Android 16` log did on the `qssi` path. A work directory that carries the
bridge on only some of the profile copies it contains is rejected for the same
reason, so a half-migrated directory cannot be reported as already done. The
trampoline is re-decoded after writing, a blob that already carries a valid
bridge everywhere is left untouched, and `--expect-shape` warns when the donor
does not match the slot the declared source generation is known to use. The
profile load and its matching store are carried over from the donor, so any
slot offset the source generation uses is handled without a hardcoded
immediate.

Verified on the `essi` donor in `out/fw` and on a `qssi` build's blob in
`out/target/x1s/work_dir`:

* the `essi` donor resolves the profile copy at `0xf10a8`, the trampoline at
  `0xecab0`, the resume at `0xf10ac` and both fatal entries to `0xec1d0`, and
  the result is byte-for-byte identical to the previous static patch;
* the `qssi` blob resolves the profile copy at `0xeab9c`, the trampoline at
  `0xe643c`, the resume at `0xeaba0` and both fatal entries to `0xe5a8c`, with
  the profile kept in the stack slot;
* rerunning the step on an already patched work directory changes no bytes and
  reports the existing bridge;
* a work directory carrying the superseded partial fatal-entry patch is
  normalised back to the stock block by the migration in `customize.sh` before
  the bridge runs, and converges to the same final blob;
* with the profile copy blanked out on purpose, the step reports the missing
  copy and returns non-zero, so `set -e` in `scripts/internal/apply_modules.sh`
  stops the build; the same holds for a non-ELF file, a partially overwritten
  block and a work directory with the bridge on only part of its copies.

The `< 36` branch keeps its own guard neutralisation: that older media stack
rejects HDR10+ with a plain check in front of the fatal block instead of the
profile copy, and it has no equivalent of the six-instruction block the bridge
reuses. That path was left as it is, and `python3 -m py_compile`, `bash -n`
and `git diff --check` pass. No ROM build or flash was run after the helper
replaced the static patterns; the `qssi` bridge in particular is validated
statically only and still needs an installed-build test that confirms a saved
HEVC file carries HDR10+ dynamic metadata.

### SecSettings crash while selecting apps to hide Developer options (2026-09-24)

The crash was reproduced when opening the app-selection screen used by the
custom Developer-options hiding feature. The first fatal exception in the
current log is:

```text
FATAL EXCEPTION: main
Process: com.android.settings
java.lang.NoSuchFieldError: No field mMainSwitch of type
Lcom/android/settings/widget/SettingsMainSwitchBar; in class
com.android.settings.SettingsActivity
at io.mesalabs.unica.settings.spoof.HideDeveloperStatusFragment.onCreateView(...)
```

This is a `SecSettings.apk` ABI mismatch, not a kernel crash or a full device
reboot. The target `SettingsActivity.smali` does not declare the `mMainSwitch`
field, while the custom fragment directly executes an `iget` against that
field during `onCreateView`, before the app list is displayed:

```text
out/target/y2s/apktool/system/priv-app/SecSettings/SecSettings.apk/
  smali_classes4/io/mesalabs/unica/settings/spoof/HideDeveloperStatusFragment.smali
```

The same incompatible access is present in
`io/mesalabs/unica/settings/hma/HideMyApplistFragment.smali` and should be
fixed together. The likely correction is to obtain the switch bar through the
target Settings implementation/resource instead of reading the absent private
field; simply deleting the access would avoid the crash but may leave the
switch UI disconnected. No patch, build, or flash was performed for this
issue yet. Before changing it, inspect the target `SettingsActivity` methods,
resources, and other fragments for the compatible switch-bar accessor.

### SecSettings switch-bar compatibility fix (2026-09-24)

The two affected UN1CA fragments were adapted to the target One UI 9
`SettingsActivity` ABI. Instead of reading the missing private
`SettingsActivity.mMainSwitch` field, both fragments now inflate the existing
target `styled_switch_bar` layout, insert it at the top of the preference
content container, resolve its `switch_bar` child, and keep using the existing
listener/state logic:

```text
unica/mods/settings/SecSettings.apk/smali_classes4/io/mesalabs/unica/settings/spoof/HideDeveloperStatusFragment.smali
unica/mods/settings/SecSettings.apk/smali_classes4/io/mesalabs/unica/settings/hma/HideMyApplistFragment.smali
```

This removes both `mMainSwitch` field references and keeps the switch UI
functional on the current base. `git diff --check` passed. No ROM build or
flash was executed; the maintainer must build/install `SecSettings.apk` and
open both app-picker screens to validate the runtime behavior.

### Codec2 resource pressure and social-app GPU path (2026-09-24)

The latest capture contains 21 occurrences of
`Failed to query component store for system resources: 6` across Instagram,
TikTok, Spotify, and `mediaserver`. A later source-level verification corrected
the original interpretation: Codec2 status `6` is `C2_BAD_INDEX` (`ENXIO`),
not `C2_NO_MEMORY` (`ENOMEM`, status 12). Android 17 is querying the proposed
`C2ResourcesCapacityTuning`, `C2ResourcesExcludedTuning`, and
`C2ResourcesNeededTuning` parameters, which the legacy Exynos 990 HIDL 1.0
component store does not implement. The separate LMKD/DMA-BUF pressure seen
in the same timeline remains relevant to heat, but this particular status is
not evidence of allocation pressure.

The S24+ source vendor properties were forcing
`ro.hwui.use_vulkan=true` and `debug.hwui.use_hint_manager=true`, while the
S20+ Exynos 990 target leaves the Vulkan selector empty and does not define
the hint-manager override. `platform/exynos990/patches/miscs/customize.sh`
now restores those target values: it clears `ro.hwui.use_vulkan` and removes
the hint-manager override. GPU acceleration is not disabled; only the
source-device GPU policy is no longer forced onto the Exynos 990.

This HWUI change is intentionally limited to an A/B thermal/DMA-BUF test. No
ROM build or flash was executed. The next build should compare, while
repeatedly opening Instagram and TikTok, `DmaBuf` totals, LMKD reclaim events,
skin temperature, and GPU timeout events. Do not use `system resources: 6` as
a memory-pressure counter.

### Suspend service compatibility and Codec2 `BAD_INDEX` (2026-09-24)

The 443 `power: ISystemSuspend::getService() failed` messages are an actual
transport mismatch. The S20+ target firmware contains the dual
`android.system.suspend@1.0-service` implementation, which registers both the
legacy HIDL endpoint used by `gpsd`/RIL/sensors and the Android 17 AIDL
endpoint. The source S24+ payload had replaced it with the AIDL-only daemon,
so legacy vendor clients could not find `ISystemSuspend/default`.

`platform/exynos990/patches/miscs/customize.sh` now restores the target's
dual-transport daemon while retaining the source service path and adds only
the target HIDL bridge library and `libSuspendProperties.so`. It also replaces
the AIDL-only suspend manifest with the target manifest that advertises both
transports. A later policy inspection established that both suspend binaries
read `/sys/class/wakeup`, labeled `sysfs_wakeup`, rather than debugfs. The
Android 17 base already contains the necessary `system_suspend` read/search
and HIDL-registration rules; `unica/patches/selinux/customize.sh` now verifies
those exact rules instead of adding unrelated debugfs permissions.

The six `CCodecConfig ... BAD_INDEX` lines occur while querying optional
AAC/Vorbis fields, after which Codec2 initializes, allocates, and releases the
component normally. `BAD_INDEX` is the defined Codec2 response for an
unsupported optional parameter; changing the vendor component to fabricate
support would be unsafe. The actionable Android 17 incompatibility was its
new availability accounting repeatedly querying resource parameters that the
legacy component store cannot expose.

`platform/exynos990/patches/miscs/customize.sh` patches the ARM64 copy, while
the later `platform/exynos990/patches/runtime32_compat/customize.sh`
patches the ARM32 r11s donor copy after it is imported. Both make only the
optional global and per-component availability-accounting routines inside
`libsfplugin_ccodec.so` return an empty resource set/success. This matches
CCodec's feature-disabled fallback, so the unsupported resource queries are
never issued. Patching the exported aconfig wrapper would not be sufficient
because this beta compiled the flag as a constant in the internal call sites;
the compatibility patch therefore targets the accounting routines that those
call sites actually execute.
Codec enumeration, hardware acceleration, buffer allocation, and real errors
remain enabled. The patch validates exact instruction signatures and accepts
an already-patched binary. No ROM build or flash was executed; after the next
build, confirm that `Failed to query component ... system resources: 6`
disappears and that codecs still reach `STARTED`. Occasional informational
`CCodecConfig ... BAD_INDEX` for other optional fields may remain and is not a
failure.

Validate the suspend fix in the same build by checking that
`ISystemSuspend::getService() failed` and `Error opening wakeup` disappear
while `dumpsys suspend_control_internal` still reports the service.

### AVC HDR-static discovery and decoder-buffer verdict (2026-09-24)

The 36 `ACodec: [OMX.Exynos.avc.dec] ... HDRStaticInfo failed even though
codec advertises support` messages have a concrete vendor-side cause. The
Android 11 Exynos AVC decoder returns a valid index for
`OMX.google.android.index.describeHDRStaticInfo` from
`Exynos_OMX_VideoDecodeGetExtensionIndex()`, but its GetConfig and SetConfig
paths reject that same index with `OMX_ErrorUnsupportedIndex`. Android 17
therefore repeats an operation that the AVC component never implemented.

`platform/exynos990/patches/miscs/customize.sh` now patches both ARM32 and
ARM64 `libOMX.Exynos.AVC.Decoder.so` instances so only the false-positive
HDR-static string match falls through to the generic unsupported-index result.
This prevents Stagefright from caching the unusable index and eliminates the
repeated get/set attempts. HEVC and the confirmed-working HDR10+ encoder path
are not changed. The clean target blobs contain each guarded pattern exactly
once; temporary patched copies disassemble to an ARM `mov r0, r0` and an
AArch64 `nop` at the two former equality branches.

The same log's two `[NALQ] no dst buffers` messages are not fatal allocation
failures. In the Exynos 990 kernel source,
`__mfc_nal_q_run_in_buf_dec()` emits that line when the destination queue is
temporarily empty and returns `-EAGAIN`; both occurrences coincide with
Spotify replacing or destroying video surfaces, after which decoding
continues. Likewise, `clearBuffersForDisconnectLocked` and
`Surface::cancelBuffer given a leaked buffer` occur during those explicit
surface disconnects. Do not patch the kernel or libgui merely to suppress
these lifecycle diagnostics unless a future capture shows a decoder timeout,
watchdog, or unrecovered playback failure immediately afterward.

The HWUI compatibility block was also hardened. A previous work directory
contained both an empty target `ro.hwui.use_vulkan=` and later source values
`ro.hwui.use_vulkan=true`/`debug.hwui.use_hint_manager=true`; Android property
ordering could therefore retain the incompatible source policy. The module
now deletes every occurrence directly from `vendor/build.prop`, appends one
canonical empty target selector, and removes the hint-manager override. This
keeps normal GPU acceleration while preventing duplicate properties from
undoing the Exynos 990 policy.

Static validation performed: `bash -n` on the modified module, exact clean-
blob pattern counts, disassembly of temporary patched ARM32/ARM64 decoder
copies, and `git diff --check`. No ROM build or device flash was performed.
After installing the next build, reproduce AVC playback in Spotify, Instagram
and TikTok and confirm that the `HDRStaticInfo failed` messages disappear;
also verify the final `vendor/build.prop` has only one empty
`ro.hwui.use_vulkan` and no `debug.hwui.use_hint_manager` entry.

### ExtremeKRNL verified-build pipeline (2026-09-24)

The ExtremeKRNL integration could associate a new cache key with an old
kernel artifact. `BUILD_KERNEL` returned a failure status, but its caller did
not check that status explicitly. Because `build/out/<model>/boot.img` from a
previous run was left in place, the later existence checks succeeded and the
old image was cached as if it had just been compiled. The evidence in the
working tree was explicit: `out/vmlinux` and `out/arch/arm64/boot/Image` were
generated on 2026-09-24, while the packaged `build/out/y2s/Image` and
`boot.img` were still from 2026-09-22 and had a different Image SHA-256.

`platform/exynos990/patches/extremekrnl/customize.sh` now treats kernel
production as a verified transaction:

- external kernel patches are optional: branches such as One UI 8.5, which do
  not have a `patches/` directory, build normally with a `none` patch-set
  digest; branches that provide patches still apply them idempotently before
  calculating the build state;
- its cache key includes a schema version, the integration script, every
  available kernel patch and its checksum, the complete kernel Git state,
  submodules and build arguments;
- a cache miss removes only the guarded Kbuild and model output directories,
  preventing old objects or packaged images from satisfying a new build;
- a failed `build.sh` now aborts immediately and can never create a cache
  manifest;
- `Image`, `boot.img`, `dtbo.img` and the LTE DTBO must be non-empty and newer
  than the build-start marker;
- the Image copied by `build.sh` must match the current Kbuild Image, and the
  kernel extracted from the Android boot header must match that Image;
- the cache is a versioned manifest containing SHA-256 values for every
  artifact, and copied work-directory images are checksum-verified again.

The artifact pipeline deliberately has no One UI 9-specific BPF, cgroup or
capability assumptions. This allows the same correction to be carried to the
One UI 8.5 `origin/sixteen` implementation, which contains the cache bug but
no external kernel patches. Patch correctness is guaranteed by `git apply`
or its reverse applicability check; the clean build and Image/boot checks then
guarantee that this exact resulting source state produced the delivered
artifact.

Static validation passed with `bash -n` and `git diff --check`. The boot-header
extractor confirmed that the existing old `boot.img` embeds its adjacent old
Image. Most importantly, the new compiled-artifact validator rejected the
current mixed state with `Packaged kernel Image does not match the Image from
the current build tree`, while a synthetic matched-artifact test passed. No
full kernel or ROM build was started; the next normal build will deliberately
invalidate the old cache and perform one clean kernel compilation.

### SecSettings app-hiding screen crash (2026-09-24)

The previous switch-bar adaptation still crashed when opening the UN1CA app
picker screens. The target `styled_switch_bar.xml` inflates a
`com.samsung.android.settings.widget.SecMainSwitchBar`, while the adapted
smali immediately cast that child to the derived
`com.android.settings.widget.SettingsMainSwitchBar`. That is an ABI-level
`ClassCastException`, before the app list can be shown.

Both fragments now inflate the target `sec_settings_main_switch_bar` layout.
Its root is already a `SettingsMainSwitchBar`, so the cast and subsequent
listener/state calls use the correct class without manually nesting or
searching the incompatible `styled_switch_bar` child:

```text
unica/mods/settings/SecSettings.apk/smali_classes4/io/mesalabs/unica/settings/spoof/HideDeveloperStatusFragment.smali
unica/mods/settings/SecSettings.apk/smali_classes4/io/mesalabs/unica/settings/hma/HideMyApplistFragment.smali
```

Static validation confirmed that the target layout root is
`SettingsMainSwitchBar`, both fragments reference
`sec_settings_main_switch_bar`, and the incompatible nested cast path was
removed. `git diff --check` passed. No APK/ROM build or flash was performed;
build `SecSettings.apk` and open both UN1CA screens to validate on-device.

### Suspend HIDL bridge and SELinux diagnosis (2026-09-24)

The installed build still ran the S24+ AIDL-only
`android.system.suspend-service`. Runtime evidence was explicit: the AIDL
service registered and remained running, but legacy Exynos 990 clients logged
`ISystemSuspend::getService() failed` because
`android.system.suspend@1.0::ISystemSuspend/default` was absent. The build log
also reported that no target dual service had been found.

The target S20+ dump does contain the required dual HIDL/AIDL daemon,
`android.system.suspend@1.0.so`, `libSuspendProperties.so`, and its dual
manifest. The module failed to find them because it converted the complete
`MODEL/CSC/SERIAL` firmware identifier to `MODEL_CSC_SERIAL`, while extracted
firmware directories use only `MODEL_CSC`. The suspend block in
`platform/exynos990/patches/miscs/customize.sh` now resolves the directory in
the same way as `make_rom.sh` and aborts instead of silently producing another
known-incompatible AIDL-only image when any required target component is
missing.

Directly loading the Android 13 target daemon against Android 17 is not ABI
safe. Symbol comparison found two concrete incompatibilities: `libbase.so`
changed the `WriteStringToFd`/`Trim` string ABI, and
`android.system.suspend.control-V1-cpp.so` changed its Binder object layout.
The module now imports only those two target libraries under private SONAMEs
(`libbase_suspend_compat.so` and
`android.system.suspend.control-V1-cpp-compat.so`) and rewrites only the
suspend daemon's `DT_NEEDED` entries with `patchelf`. Global Android 17
libraries remain untouched. The remaining daemon dependencies are present in
the source system and the target-only HIDL/property libraries are imported as
before.

The repeated `Error opening wakeup*/...: Permission denied` was previously
misattributed to `debugfs_wakeup_sources`. Both suspend binaries actually
enumerate `/sys/class/wakeup`, and the final Android 17 policy already labels
that tree `sysfs_wakeup` and grants `system_suspend` directory, file and link
read/search access. It also already permits `system_suspend_server` to add the
legacy HIDL hwservice. The custom debugfs allows were therefore removed;
`unica/patches/selinux/customize.sh` now verifies the required sysfs and HIDL
registration rules and aborts if a future source policy omits them.

Validation performed: both modified shell modules pass `bash -n`,
`git diff --check` passes, all four target suspend components resolve under
`out/fw/SM-G986B_AUT`, all direct library dependencies have providers, the
private-library transformation was reproduced on temporary copies, and the
rewritten daemon contains the expected private `DT_NEEDED` names and SONAMEs.
No ROM build, flash, or live service replacement was performed. After the
next installed build, verify the HIDL and AIDL registrations and confirm that
`ISystemSuspend::getService() failed` and the wakeup-entry EACCES messages are
absent.

### Android 17 suspend wakeup labels on Exynos 990 (2026-09-25)

The previous conclusion that every `/sys/class/wakeup` object was labelled
`sysfs_wakeup` was incomplete. Runtime label inspection on the S20+ showed
that those class links resolve to a mixture of `sysfs` (sensor and biometric
wakeups) and target-vendor `sysfs_battery` (USB, wireless and battery wakeups),
in addition to `sysfs_wakeup`. This explains why the AIDL service registered
correctly while it still emitted repeated `event_count` and kernel-wakelock
`EACCES` errors.

`unica/patches/selinux/customize.sh` now appends read-only `system_suspend`
rules for generic `sysfs`. When the target vendor declares the existing
`system_suspend_access_sysnode` compatibility attribute, it also adds the same
read-only rules through that narrow attribute; on the S20+ it covers
`sysfs_battery`, `sysfs_sec`, `sysfs_ss_writable` and `sysfs_uhid`. It neither
grants write access nor permits `debugfs_wakeup_sources`. Other targets are
left unchanged when they do not declare that attribute.

After installing a new build, reproduce a charge/wakeup event and verify:

```sh
adb logcat -d | grep -E 'system\.suspend-service.*(event_count|kernel wakelock stats).*Permission denied'
```

The command should produce no output. The AIDL registration and absence of
`ISystemSuspend::getService() failed` were already verified before this
follow-up policy correction.

### Android 17 RAM Plus / SLMK premature kills (2026-09-24)

DMA-BUF growth from roughly 634 MB to 723 MB was investigated because it
coincided with Chromium and social-app processes being killed. The allocation
was predominantly normal `ion_system_heap` display buffers shared by
SurfaceFlinger/SystemUI; camera and video heaps were not retaining a matching
amount. The direct kill trigger was instead SLMKD: it logged
`low watermark is breached and swap is low` with about 7.2 GB still free.

The target S20+ vendor policy provides `ro.slmk.base_swaptotal=2560` but no
explicit swap-free threshold. Android 17 RAM Plus expands the live zram device
to 8 GB (`persist.sys.zram.ram_expand_size=4096`), after which the Android 17
SLMKD calculated `SwapFreeLow: 55 -> 86`. That made it treat 86% free swap as
low and kill cached apps aggressively.

`platform/exynos990/patches/miscs/customize.sh` now preserves the S24+ source
policy values `ro.slmk.swap_free_low_percentage=10` and
`ro.slmk.2nd.swap_free_low_percentage=10` in the final target vendor
`build.prop`. On-device validation with `resetprop` followed by an `lmkd`
restart changed the daemon log from `SwapFreeLow: init 55 -> 86` to
`SwapFreeLow: init done 10 -> 10`; the temporary DeviceConfig override was
then removed and the result remained. This does not resize zram, change DMA-
BUF allocation, or change OOM scores—only the free-swap reclaim threshold.

After flashing a build, verify with:

```sh
adb shell getprop ro.slmk.swap_free_low_percentage
adb shell getprop ro.slmk.2nd.swap_free_low_percentage
adb logcat -d -s lmkd | grep SwapFreeLow
```

Both props must be `10`, and the log must show `10 -> 10`, not `55 -> 86`.

### Legacy Samsung Camera OCR / Scene Detection (2026-09-25)

The Samsung Camera source used by Android 17 reads the `Y0` text-detection
metadata key, which is not emitted by the legacy camera HAL used on pre-API 34
targets. The regular legacy preview path does provide the scene-detection `I0`
array (scene ID at index `1`); selected processing makers also expose a scene
node event. The compatibility mapping must only be driven by an actual
document/text result: ordinary scene IDs such as `18` (`HomeIndoor`) are not
text detection and must never be promoted to an OCR event.

`unica/patches/legacy/camera/SamsungCamera.apk/0002-Backport-legacy-Scene-detection-code.patch`
uses `I0` as its primary source and the node event only as a fallback,
translating the result to the text-detection callback state for the current
Android 17 SamsungCamera layout. It is enabled only for non-MASS pre-API 34
targets. This is an adaptation of HackMeGG's original Scene Detection backport, with the original
author and upstream commit `ec9e5c1abda401d32d72e962ae6d2fd0d5abf31a`
preserved in the patch header and `unica/patches/legacy/customize.sh`.

### y2s/y2slte legacy Document Scan runtime (2026-09-28)

The S24+ source includes enhanced document operations (AI dewarping, shadow
removal, deblur, object removal and color enhancement) that open an S5E9945
SNAP/NPU session. On the Exynos 990 target this fails at runtime with
`Snap wrapper openSnap error = 1`; it is not an OCR-model absence. The base
Smart Scan stack itself remains usable: `libSmartScan`, Stride models,
`OCRDataProvider` and `VexScanner` load correctly.

`platform/exynos990/mods/legacy_docscan` is intentionally applied after all source
modules for y2s/y2slte. It removes the incompatible enhanced capability,
replaces Smart Scan/Stride libraries, OCR models and the segmentation model
with the coherent S20+ target set, and removes the S24-only `libDoc*` SNAP
enhancement nodes. It preserves document detection, manual crop and text
extraction without advertising unavailable S24+ processing tasks.

### Original target wallpapers on One UI 9 (2026-09-28)

`unica/mods/wallpaper` now restores the stock wallpaper catalogue and assets
from each target firmware's `system/priv-app/wallpaper-res/wallpaper-res.apk`.
It deliberately **does not** replace the One UI 9 `wallpaper-res.apk`,
`SpriteWallpaper.apk`, or `AiWallpaper.apk`: those packages provide the newer
wallpaper capabilities missing from the One UI 5.1 application.

During a non-debug build the module decodes the base `wallpaper-res.apk` and
copies only assets explicitly referenced by the target's `phone` and `dex`
wallpaper lists. It merges only those two lists from the target's
`resources_info.json`. The source package's `types`, version, thumbnails,
frames, graphics, colors, and One UI 9 feature metadata remain intact. Target
videos and images are copied as-is—there is no resizing, WebP recompression,
MP4 re-encoding, Galaxy Store download, or S25/Paradigm motion-timing patch.

The module was re-enabled by removing its stale `disable` marker. A static
check using the G986B target and S926B base verified that both catalogues share
the required schema and that all 11 y2s catalogue entries resolve to extracted
target assets. No ROM build or flash was run for this change.

#### S20-series fullscreen AOD gate (2026-09-28)

`target/y2s/sff.sh` and `target/y2slte/sff.sh` set
`SEC_FLOATING_FEATURE_LCD_CONFIG_AOD_FULLSCREEN=1`. The generic fallback in
`unica/patches/__floating_feature` intentionally remains `0`, so this does not
enable the path on unrelated targets.

The dependency audit found no missing AOD runtime component for these two
targets: the generated base already contains the S24+ One UI 9
`AODService_v80.apk`, `aod.jar`, `/system/bin/aod`, feature declaration and
privileged-permission XML. The S20 and S24 `aod` launch scripts are byte-for-
byte identical, and the S20 hardware is AMOLED with stock AOD support. This
flag gates the full-screen path in the modern framework/SystemUI; it does not
require importing S24 display or vendor blobs. Build and device validation are
still required, especially for AOD battery behavior and panel wake/sleep.

### y2s animation-jank diagnosis: QHD/60 user preference (2026-09-28)

The connected y2s port was not running at its target high-refresh mode. Its
persisted user display mode was QHD (`1440x3200`) at `60 Hz`, and
`secure.refresh_rate_mode` was `0` (Samsung's standard-refresh policy). The
panel does support `1080x2400` at `120 Hz`; the target floating-feature table
already correctly advertises a 120 Hz default and the full `48/60/96/120`
profile set. This was a runtime user preference/migrated Settings state, not a
missing GPU overclock or a floating-feature defect.

The connected device was changed, without rebuilding the ROM, to the persisted
FHD/120 preference using `cmd display set-user-preferred-display-mode 1080
2400 120 0 true` and `settings put secure refresh_rate_mode 1`. A gesture test
then confirmed SurfaceFlinger mode `1080x2400 @ 120 Hz`. The adaptive policy
can intentionally report 60 Hz at rest, but switches to 120 Hz while handling
interaction.

At the time of testing the skin thermal state was level 3 at about 40.6 C,
while the AP was about 44.1 C with thermal status 0. SurfaceFlinger missed
frames were predominantly HWC-side rather than GPU-side. Do not add a GPU
overclock or alter kernel DVFS based on this observation. If lag remains while
an interaction is demonstrably at FHD/120, capture a fresh timed trace and
investigate HWC/display composition separately.

#### y2s GPU DVFS ceiling applied too early (2026-09-28)

Follow-up live testing found a separate, concrete contributor to progressively
laggy animations. At a G3D temperature of 45 C (well below the driver's first
thermal trip at 65 C), `/sys/kernel/gpu/gpu_max_clock` was capped at `377000`.
The kernel exposes that node as its effective DVFS maximum; clearing the
runtime constraint restored the hardware maximum to `800000`. A controlled
Home/recents gesture then reached `572000` MHz at 48–56% GPU utilization,
whereas the capped state could not exceed `377000`.

The source is the y2s target SIOP policy embedded into
`SamsungDeviceHealthManagerService.apk` by `unica/patches/dvfs/customize.sh`.
Its AP/LRP rule previously imposed 377 MHz from 35 C. The Brazil-oriented
target policy now uses `-1:572000:455000:455000:260000` at `38:44:48:50 C`:
it is **not** an overclock, does not raise the kernel's 800 MHz hardware
ceiling, and only applies the severe 260 MHz cap at 50 C. It avoids treating
ordinary warm UI use as a near-throttle condition while retaining the kernel's
independent 65 C GPU thermal trip.

After flashing, verify during normal warm use:

```sh
adb shell su -c 'cat /sys/kernel/gpu/gpu_max_clock; cat /sys/kernel/gpu/gpu_tmu'
```

At roughly 45 C the effective maximum should be `455000`, rather than
`377000`; at 50 C it should become `260000`. The kernel thermal trip remains
independent and must not be disabled.

#### y2s 120 Hz thermal limiter correction (2026-09-28)

A clean flash reset the user preference to standard refresh rate, but that was
not the remaining cause after Adaptive mode was selected again. Live
`dumpsys display` showed the `SamsungDeviceHealthManagerService` holding a
`LowRefreshRateToken:SiopLimiterHrr`, which overrides the 120 Hz user vote and
selects the 60 Hz panel mode. The active device reported `SKIN` around 45 C.

The effective target profile is `target/y2s/dvfs/siop_model.xml`, embedded as
`siop_y2s_exynos990.xml`. Its global `DISPLAY`/`LRP` `LimitHrr` threshold was
46 C. It has been raised to 50 C: this keeps the 60 Hz thermal safeguard for
genuinely elevated temperature while preventing an unintended cap in normal
warm-climate use. CPU/GPU derating and kernel thermal trips are unchanged.

After flashing, enable Adaptive motion smoothness and verify:

```sh
adb shell 'dumpsys display | grep -E "mActiveModeId=|SiopLimiterHrr"'
```

At normal temperature there must be no `SiopLimiterHrr` token; under touch the
FHD panel should select its 120 Hz mode. At/above the new LRP threshold,
60 Hz is intentional protection.

### y2s/y2slte LMK and ART memory policy (2026-09-28)

The Android 17 `services.jar` uses `ro.slmk.cached_max` for Samsung's
`BGSlotManager`; without the property it defaults to 512 cached applications.
On the connected 8 GiB y2s this produced `CUR_MAX_CACHED_PROCESSES=550`.
This retains far more background state than the legacy target policy needs and
postpones trimming until foreground workloads compete for memory.

For y2s and y2slte only, `platform/exynos990/patches/miscs/customize.sh` now
sets `ro.slmk.cached_max=256`. A live reversible DeviceConfig test at the
equivalent 288-process ActivityManager limit was accepted and recalculated
the cache/empty/trim limits correctly; the test configuration was removed
afterward. The existing `ro.slmk.*swap_free_low_percentage=10` fix remains
unchanged, so LMKD does not kill cached apps while most of zram is free.

The ART heap size and target utilization are deliberately unchanged: both the
S20 and S24+ use a 512 MiB process heap and changing it without a measured
allocation failure would trade jank for premature kills. The target's stock
`dalvik.vm.usejitprofiles=true` is restored instead, allowing profile-guided
JIT compilation after normal app use. USAP remains disabled because it also
is disabled by the source base.

After flashing and using the phone normally, verify:

```sh
adb shell 'getprop ro.slmk.cached_max; getprop dalvik.vm.usejitprofiles'
adb shell 'dumpsys activity settings | grep -E "CUR_MAX_CACHED_PROCESSES|CUR_TRIM_CACHED_PROCESSES"'
```

Expected values are `256`, `true`, and a cached-process limit substantially
below the former 550. Test multitasking, camera and Chromium playback before
publishing; this intentionally favors foreground stability over retaining an
unbounded number of old background processes.

### y2s/y2slte rounded-corner scaling at QHD+ (2026-09-28)

The disproportionate black/rounded screen edges at QHD+ were caused by the
target product framework overlay, not GPU composition. The active
`framework-res__y2sxxx__auto_generated_rro_product.apk` overrode the framework
corner radius with the S24+ value of `52dp`. At the QHD+ display density this
resolved to `195px`, despite the physical panel being the S20+ panel.

The S20+ framework uses `32dp`; `target/y2s/overlay/values/dimens.xml` and
`target/y2slte/overlay/values/dimens.xml` now restore that value for the top
and bottom display corner radii. These are `dp`, rather than a hardcoded pixel
size, so Android scales them automatically when the user switches between
FHD+ and QHD+. The unrelated clear-view cover radius remains unchanged.

After flashing, verify with:

```sh
adb shell 'cmd overlay lookup android android:dimen/rounded_corner_radius_top'
adb shell 'dumpsys window | grep -m1 initRoundedCorners'
```

The resource must resolve to `32.0dip`; at QHD+ / 600 dpi the rounded-corner
radius should be `120px`, not `195px`.

### KernelSU-Next module lifecycle on Android 17 (2026-09-29)

KernelSU root access alone does not prove that KernelSU modules are active.
Zygisk and Meta-Overlayfsx require the `ksud` lifecycle, principally
`post-fs-data`, to run during boot; otherwise module directories can remain in
`/data/adb/modules_update` and their `system/` overlays are never mounted.

The Exynos 990 kernel uses the KernelSU-Next **legacy/manual-hook** path. Its
previous submodule revision, `a54e4fa4`, predates the legacy fixes for modern
Bionic `execveat` handling and the accompanying hook hardening. The kernel
submodule is now advanced to `dd074bc6` from the upstream `legacy` branch:

- `legacy: non-GKI update — execveat (new bionic), hardening fixes, syscall table hooking scheme`;
- the related SELinux-hide and Kbuild hook fixes.

`CONFIG_OVERLAY_FS=y` is already present in the Exynos 990 kernel, so this
change targets the missing KernelSU boot lifecycle rather than adding a second
OverlayFS implementation. Rebuild and flash the kernel before judging it.

After the first reboot, validate both the lifecycle and the mount backend:

```sh
adb shell su -c 'dmesg | grep -iE "ksud|kernelsu|post-fs-data|module_mounted" | tail -n 120'
adb shell su -c 'find /data/adb/modules /data/adb/modules_update -maxdepth 2 -name module.prop -print'
adb shell su -c 'mount | grep -i overlay; cat /proc/filesystems | grep overlay'
```

The kernel log must contain a `post-fs-data` trigger and the enabled module
must reside under `/data/adb/modules`, not only `modules_update`. If
Meta-Overlayfsx is used, its own log must report that the module overlay was
mounted; a KernelSU module cannot mount `/system` by itself on a read-only
dynamic partition.

### Magic Mount do KernelSU-Next no y2s/y2slte (2026-10-23)

O KernelSU-Next 3.4.2/UAPI 5 não inclui mais um montador de módulos no kernel
ou no `ksud`. O kernel injeta `post-fs-data` e chama o `ksud`; a operação que
aplica uma árvore `system/`, `vendor/`, `product/` ou `system_ext/` é delegada
a um **metamódulo**. Sem ele, `ksud module list` pode mostrar `mount=true`,
mas nenhum overlay ou bind mount aparece no namespace global.

No aparelho y2s de teste, `ksud module metamodule` retornava `Unsupported` e
os módulos existiam em `/data/adb/modules` sem qualquer mount. Foi instalado
o Meta Magic Mount oficial `meta-mm` v1.0.1-sprout (SHA-256 do ZIP:
`4e2bfbccd80b0d787223cc8fe36315e8b269514a28f6d7ffb8e6e1f855e6e92b`).
Após `ksud post-fs-data`, o estado passou para `Installed` e o log
`/data/adb/magic_mount/mm.log` confirmou a varredura das árvores de módulos e
`Magic Mount Completed Successfully`.

Os módulos experimentais `fod_qhd_*`, `resolution_physical_test*` e
`resolution_native_modes_fix` foram marcados como `disable` antes de ativar o
metamódulo, para que JARs/APKs antigos não sejam reaplicados. O
`kernel_umount` permanece habilitado: ele só remove a visibilidade dos mounts
em processos filhos de zygote e não impede o metamódulo de montar arquivos
para serviços do sistema ou HALs da vendor.

Para um módulo de vendor, mantenha o layout `vendor/...` no ZIP. O
`metainstall.sh` do `meta-mm` converte esse layout em
`/data/adb/modules/<id>/vendor`, e o `metamount.sh` executado em
`post-fs-data` monta os arquivos antes de notificar `EVENT_MODULE_MOUNTED` ao
KernelSU. Não é necessário alterar `CONFIG_OVERLAY_FS` nem criar outro patch
no kernel para habilitar Magic Mount.

### Initial Galaxy M21s/F41 target (2026-09-29)

The StockMod tree now contains an initial `m21s` target for the Exynos 9611
Galaxy M21s/Galaxy F41 family. Samsung identifies the device as `SM-F415F`,
and the target uses the latest ZTO Android 12 release currently catalogued:
`F415FUBS3CWK2` / CSC `F415FOWO3CWK2` / CP `F415FDDS3CWK2` (security patch
2023-11-01). The firmware downloader still requires the third
`TARGET_FIRMWARE` component; `35209900` is only a fallback TAC. Set
`TARGET_FIRMWARE_DEVICE_ID` to the phone's own valid TAC/IMEI if Samsung FUS
rejects it.

The new target is `target/m21s`, its platform is `platform/exynos9611`, and
the partition geometry follows the extracted F415F ZTO PIT:
6,539,968,512-byte super partition with a 6,535,774,208-byte `group_basic`
group, 61,865,984-byte boot, 8 MiB DTBO, 71,106,560-byte recovery and
200 MiB cache. The target deliberately starts
with conservative 60 Hz, rear-fingerprint, non-eSIM and no HDR/dynamic-
resolution feature gates; camera/audio features must be filled from the
extracted F415F ZTO floating features before a release build.

The kernel integration is `target/m21s/patches/kernel9611`.
It pins the Exynos9611Development `SomethingNew-15-OUI-KSU-Old` revision
`933cc29fad7b2cfcfd0a529684c7377cbd6cd8cd`, invokes
`build_kernel.py --target=f41 --oneui --ksu`, keeps the target stock ramdisk,
DTB and command line, and replaces only the kernel payload inside
`work_dir/kernel/boot.img`. The repacked image is checked by unpacking it and
comparing its kernel byte-for-byte with the freshly built `Image`.

The first real build reached this module but stopped before compilation because
the pinned upstream checkout does not ship `toolchain/bin/clang`. The module
now stages the compiler inside the checkout automatically from a source-tree
AOSP prebuilt or a host LLVM installation, and supplies the
`aarch64-linux-gnu-*` LLVM utility names required by this 4.14 Makefile. No
manual export is required. `EXYNOS9611_TOOLCHAIN_DIR` remains an optional,
authoritative override for a pinned AOSP clang-r383902-compatible tree; the
host fallback is explicitly logged as non-reproducible. Static script
validation and a temporary boot repack simulation passed; no complete
corrected kernel build or flash was run here.

The extracted F415F ZTO firmware was then used to correct the target metadata:
the PIT reports a 61,865,984-byte boot, 8 MiB DTBO, 71,106,560-byte recovery,
209,715,200-byte cache, 6,539,968,512-byte super and
6,535,774,208-byte `group_basic` containing only system/vendor/product/odm.
The target now uses those values instead of the earlier guessed group name and
size. Its original floating features also confirm one speaker and no virtual
vibration-sound feature,
`lib_SamsungRec_07010.so`, mDNIe `61457`, auto-brightness mode `3`, and no
HFR list (`HFR_SUPPORTED_REFRESH_RATE=0`, NS `60`). The recovery map retains
the port's EROFS logical images but restores the stock ext4 Prism and Optics
mounts required by OMC.

The shared product-feature mapper now recognizes
`TARGET_FINGERPRINT_CONFIG_SENSOR=google_touch_rear` and skips optical/side
fingerprint UI transplants, leaving the rear sensor to the target vendor HAL.

Because the ESSI source (API 37) and F415F target (API 31) have different
SDK levels, the camera patch now falls back to the extracted target
`system/cameradata/camera-feature.xml` when no hand-authored target XML exists.
This avoids aborting the first target build or inventing S24+ camera modes;
future M21s camera changes should start from that extracted stock file.

References: [Exynos9611Development universal9611 kernel](https://github.com/Exynos9611Development/android_kernel_samsung_universal9611/tree/SomethingNew-15-OUI-KSU-Old), [Samsung F41 ZTO update history](https://doc.samsungmobile.com/SM-F415F/015389201104/roh.html), and [F415FUBS3CWK2 package metadata](https://samfw.com/firmware/SM-F415F/ZTO/F415FUBS3CWK2).

The first host-LLVM compilation failure was reproduced with Ubuntu clang
21.1.8 in `kernel/params.c` and `kernel/bpf/syscall.c`. Clang 20+ promotes
the old kernel's harmless type-check placeholder initialization diagnostics
(`-Wdefault-const-init-field-unsafe` and
`-Wdefault-const-init-var-unsafe`) to errors because this kernel enables
`-Werror`. The kernel module now detects clang major version 20 or newer and
appends only the corresponding `-Wno-*` compatibility flags through
`KCFLAGS`, preserving the remaining warnings-as-errors policy and any caller
flags. An incremental `make -j1 V=1` reached the cgroup and power objects
without reproducing the original `params.c` failure; the complete target
build still must be run by the maintainer before flashing.

The Exynos 9611 integration now follows the Exynos 990 mounted-kernel
lifecycle. `out/kernel_tmp-exynos9611` is reused when it is already a valid
git checkout at the pinned revision; the script does not delete a non-git
directory that may be a mounted filesystem, and aborts with a diagnostic
instead. A checksum manifest at `.unica-kernel-cache` records the source,
submodules, integration script, compiler and build mode. When the manifest and
`out/arch/arm64/boot/Image` still match, compilation is skipped and the image
is repacked into the current target boot image. Any source/integration/toolchain
change invalidates the manifest and triggers a fresh build.

## Bluetooth VaultKeeper HEX patch on M21s (2026-09-29)

The Bluetooth module no longer aborts when the extracted
`libbluetooth_jni.so` does not contain one of the four known VaultKeeper
branch encodings. The M21s build uses the Android 16 Bluetooth APEX, whose
native code still exports `VaultKeeperManager` but moved the initialization
flag to a different `ldrb` encoding. The module now recognizes the current
`8856523948050037` sequence (as well as the two older donor variants), applies
the HEX patch only after an exact match, and logs a warning otherwise. This
prevents accidentally rewriting an unrelated `tbnz` instruction while still
disabling the actual VaultKeeper initialization branch in the current APEX.

## M21s FM Radio JNI dependency (2026-09-29)

The F415F ZTO target firmware contains the hardware-specific
`system/lib64/libfmradio_jni.so` and 32-bit counterpart, but the initial work
directory did not copy them before the FM Radio module ran. Because the
target floating features do not define
`SEC_FLOATING_FEATURE_FMRADIO_SUPPORT_EXTERNAL_RADIO_CHIPSET`, the module
correctly detected the missing 64-bit JNI and aborted. It now imports the
target firmware's matching 64-bit library (and the 32-bit library when
available) before installing HybridRadio, while still aborting if the target
firmware genuinely lacks the required 64-bit implementation.

The FM Radio app download is also now resilient to Galaxy Store catalog
changes. If the source already contains `HybridRadio.apk`, it is preserved;
otherwise the module uses the target F415F firmware's original
`HybridRadio.apk` (and profile when present) before attempting Galaxy Store.
The build only aborts when neither a target/source app nor a valid download
URI exists.

## M21s compatibility stack required before release (2026-09-29)

The M21s platform now has target-specific wrappers for the compatibility stack:

- `platform/exynos9611/patches/__desixtification` reuses the audited ARM32
  runtime merge and preserves the F415F `abilist32` entries.
- `platform/exynos9611/patches/runtime32_compat` imports the multilib
  Runtime/I18n/ART APEX payload and the r11s ARM32 system dependency closure.
  Target-only GLES/audio libraries are now conditional, so a missing optional
  blob does not abort the M21s build.
- `platform/exynos9611/patches/zygote_vendor_compat` selects `zygote64`
  and the matching 64-bit BoringSSL trigger without clearing the vendor's
  32-bit ABI list. The target's `boringssl_self_test32/64` binaries are kept.
- `platform/exynos9611/patches/cgroup_legacy` installs the source-compatible
  descriptors and ARM32 cgroup client libraries, but does not advertise
  `CgroupKill`: the universal9611 4.14 kernel has no `cgroup.kill` interface.
- `target/m21s/patches/codec2_compat` applies only the audited
  Android 17 Codec2 seccomp allowances (`MREMAP_MAYMOVE`, `setsockopt`,
  `listen`, and `bind`). It does not import Exynos 990-specific HALs.
- `target/m21s/patches/kernel9611/patches/0001-capabilities-add-android17-bounding-set-abi.patch`
  is now applied by the mounted-kernel build script before compilation. It
  extends `CAP_LAST_CAP` through `CAP_CHECKPOINT_RESTORE` and adds the three
  SELinux capability2 names required by Android 17's native zygote. It is an
  ABI compatibility backport only; it does not enable the newer BPF, perf, or
  checkpoint/restore subsystems.

The generic `unica/patches/selinux` module remains the SELinux/suspend/ION
compatibility layer and will run after the FM Radio stage. The earlier failed
build stopped before reaching it. `platform/exynos990/patches/abi64_only/disable`
must remain disabled: forcing a 64-bit-only userspace would break the F415F's
32-bit OMX and audio services; the M21s port needs a coherent multilib runtime.
These changes are adaptation scaffolding only; a complete build and a clean
flash are still required before runtime validation on hardware.

### M21s linker normalization (2026-09-29)

If an interrupted diagnostic build had already materialized the ARM32
`system/bin/linker`, the runtime module previously aborted with
`Refusing to replace regular file`. The M21s desixtification wrapper now
forces the merged-APEX mode, and the shared runtime module only removes that
stale regular file when it is verified as an ELF32 linker and the target is
`exynos9611`; the Exynos 990 safety refusal remains unchanged. A fresh work
directory is still recommended after an interrupted build.

Validation performed before handing off the first adaptation: `bash -n` passed
for every new Exynos 9611 customization script and its shared desixtification,
runtime32, and cgroup implementations; `git diff --check` passed; the extracted
ZTO firmware contains both `boringssl_self_test32/64`, an ELF32 legacy OMX
service, the Codec2 seccomp policy, and the target 32-bit audio/GLES inputs;
the pinned `exynos9611-f41_defconfig` enables `CONFIG_MEMCG` and
`CONFIG_CGROUP_FREEZER`; the capability patch applies cleanly with
`git apply --check` to the current 4.14 universal9611 checkout. No full
ROM/kernel build or flash was run in this adaptation step.

### M21s Face HAL 2.0 selection (2026-09-29)

The legacy Face HIDL patch is written for an older `services.jar` and cannot be
applied to the Android 17/S24+ framework used as the M21s source. Its stale
contexts caused `git apply` failures in `AidlResponseHandler`,
`FaceAuthenticationClient`, the synthetic face lambdas and the HIDL adapters.
The M21s firmware exposes only
`vendor.samsung.hardware.biometrics.face@2.0-service`, while the modern
framework already ships both V2 and V3 adapters. `unica/patches/legacy/customize.sh`
therefore skips the old unified patch only for `m21s`/`exynos9611` and selects
the existing V2 path by forcing `SemBiometricFeature.FEATURE_JDM_HAL` in its
decoded static initializer. This keeps the V3 classes available for framework
verification, avoids mixed-interface deletions, and lets the HIDL 2.0 service
be selected without weakening the legacy behavior of other targets. The
generic legacy patch remains unchanged for non-M21s pre-API-34 targets.
After a failed attempt with the old patch, remove the decoded
`out/target/m21s/apktool/system/framework/services.jar` directory (or use the
normal target clean operation) before retrying, so successful hunks from the
aborted `git apply` are not reused.

The same source-version issue affects the legacy SehLights patch. The M21s
Android 17 framework already contains the VINTF `ISehLights` path and selects
legacy behavior from the vendor API level, while the old patch expects the
pre-Android-17 `LightImpl`/`BacklightAdapter` method layout. For
`m21s`/`exynos9611`, the lights patch is now skipped and the modern framework
implementation is retained; other pre-API-35 targets keep the original
backport path.

The M21s `netd` also uses a different Android 17 code generation pattern for
the legacy Sem Smart Hotspot checks. The old `cmp; b.eq` signature is absent;
the corresponding `MobileBBController::hotspotOn` decisions are emitted as
two `csel` instructions. The M21s branch now patches those exact instructions
to the non-4.14 path and patches the remaining `isMBBPathsPresent` compare.
The replacements are equal-length AArch64 instructions and were verified
against the extracted M21s `netd` before the build is retried.

For the sdFAT compatibility check, the extracted Android 17 `vold` has no
`time_offset` string at all, meaning the unsupported mount option has already
been removed upstream. The module now verifies that condition instead of
trying to apply an obsolete string replacement; if a future M21s `vold`
contains the option with an unknown encoding, the build aborts rather than
silently omitting the compatibility fix.

### M21s legacy camera patch layout (2026-09-29)

The M21s build was stopping in
`0001-Backport-CONTROL_AVAILABLE_FEATURE_SECOND_PICTURE_CO.patch` because all
seven donor files were expected under `smali_classes3`, including the old
`com/sec/android/app/camera/engine/core/CapabilityImpl` and
`PrepareMakerRequest` APIs. The Android 17 SamsungCamera used by this target
has neither those engine classes nor that field-backed capability model; its
`FeatureCapability` uses a `ConcurrentHashMap` and the core is under
`smali_classes2`. Repointing the old patch to `smali_classes2` would still
inject unresolved methods and is not a valid port.

`unica/patches/legacy/customize.sh` now inspects the decoded APK before any
camera patch is selected. It applies the donor SECOND_PICTURE patch only when
the complete legacy file set exists. For the known modern map-backed core it
keeps the native camera implementation and logs why the old API is not
applicable; an unrecognized layout aborts with an explicit compatibility
error instead of producing a later missing-smali failure. The same check
covers both the normal and mass-app patch variants.

The GPS metadata and OCR scene-detection patches receive equivalent semantic
preflight checks. Android 17's `CameraMetadataNative` is recognized when its
null-safe GPS array implementation is already present, and the modern
SamsungCamera callback path is recognized through `sceneDetectionEvent`, the
`SemCaptureResult.I0` lookup, and the callback lambda. These already-adapted
implementations are not patched a second time; older layouts still use the
original donor patches. This prevents partial/repeated hunks after an
interrupted build while preserving the legacy behavior where its API exists.

The checks use the actual decoded path (`apktool/system/priv-app/...`); they do
not prepend a second `system` component. The map-backed detector also locates
`FeatureCapability.smali` dynamically and checks for `ConcurrentHashMap`,
instead of depending on one obfuscation field name. This matters because a
wrong path or a renamed field would make a valid modern APK look unknown and
trigger the compatibility abort.
Validation for this change: the M21s decoded camera contains the map-backed
`FeatureCapability`, no `CapabilityImpl` engine class, the GPS implementation
and OCR callback markers are present, `bash -n unica/patches/legacy/customize.sh`
passes, and `git diff --check` is clean. A complete M21s build still needs to
be rerun from a clean `out/target/m21s/apktool` directory because the failed
attempt may have left partially patched decoded artifacts.

### M21s audio product-feature layout (2026-09-29)

The M21s Android 17 framework does not keep the exact field ordering used by
the donor audio patches. `Rune.smali` contains additional fields between
`SEC_AUDIO_SUPPORT_ACH_RINGTONE` and `SEC_AUDIO_SUPPORT_DUAL_SPEAKER`, so the
original dual-speaker hunk can fail even though the target still exposes the
same feature. The product-feature script now first tries the original patch,
then performs guarded semantic edits on the named Rune flag and the speaker
count (`2` to `1`) when the target has the known modern layout. The
`AudioService` patch is still applied and is checked independently.

The same preflight is used for ACH ringtone and virtual-vibration flags. When
the Android 17 field context differs, only the matching `Rune`/`VibRune`
boolean is changed; unrelated registers and fields are not rewritten. The
large legacy virtual-vibration services/settings patches are applied only when
their complete donor layout matches. On the modern M21s layout, the native
services and settings implementation is retained because its callers already
gate the feature through those flags; applying the old donor hunks would
otherwise create missing-smali or invalid-label failures.

Validation for this change: the extracted M21s `Rune.smali` has the extra
Auracast field and the `SEC_AUDIO_NUM_OF_SPEAKER` initializer, the semantic
fallback detects both, and the dual-speaker `AudioService` donor patch passes
`git apply --check` for the current layout. The legacy virtual-vibration
services donor is intentionally rejected by the same preflight because its
Android 17 broker context is different. `bash -n
unica/patches/product_feature/customize.sh` passes, and `git diff --check` is
clean. If a build was interrupted while
decoding, remove `out/target/m21s/apktool` (or use the normal target clean)
before retrying so partial hunks are not mistaken for a complete patch.

### M21s VINTF and 802.11ax compatibility (2026-09-29)

The M21s target now uses the original F415F ZTO device compatibility matrix at
`target/m21s/vintf/compatibility_matrix.device.xml`; this is the exact matrix
from `out/fw/SM-F415F_ZTO` (SHA-256
`e1ea04274eae3d99dc4885604e4eafef01406817a32e9e4a36d8534132865bc5`). This
keeps the VINTF input tied to the target's extracted firmware instead of
silently borrowing an unrelated device matrix.

Android 17's SecSettings and SystemUI no longer contain the legacy Wi-Fi slice,
AutoHotspot and Labs smali files used by the donor 802.11ax patches. The
product-feature script now validates every file named by each donor patch
before calling `git apply`; when the legacy layout is absent it uses the
modern semantic fallback (`WifiEntry` predicates, Wi-Fi repositories and
Smart-Tethering icon selectors). Unknown layouts abort explicitly; no
applicable patch is silently skipped. The path parser uses a non-ambiguous sed
delimiter so future builds do not emit the previous path-validation warning.

Validation: `bash -n unica/patches/product_feature/customize.sh` and
`git diff --check` pass. A clean M21s build should be run in a tmux session
named `m21s-build`; attach with `tmux attach -t m21s-build` when that session
is active.

### M21s Exynos9611 kernel target (2026-09-29)

The Exynos9611 kernel module is gated by the `m21s` target, but it had been
invoking `build_kernel.py --target=f41` and used `target=f41` in its cache key.
That could reuse/build the F41 profile even though the M21s kernel source has a
separate `exynos9611-m21_defconfig` with M21 camera and sensor selections. The
module now uses `KERNEL_TARGET=m21`, increments the cache-manifest version, and
passes that target to `build_kernel.py`. It also validates the M21 defconfig
before compiling and checks the generated `.config` for
`CONFIG_SENSORS_SSP_M21=y`, rejecting an accidental M31 profile.
The cache manifest records and validates the selected target explicitly, so an
older F41 image cannot satisfy the M21 cache check.

The target firmware remains the extracted SM-F415F ZTO package, so the boot
ramdisk, DTB and cmdline are still retained when the freshly built kernel
`Image` is repacked. This is intentional for the current target integration;
it does not claim that the F415F firmware and a different physical M21 model
are interchangeable. The kernel source's M21 defconfig and DTS currently
include `CONFIG_SAMSUNG_NFC`, `CONFIG_SEC_NFC` and `exynos9611-m21_nfc_00.dtsi`;
NFC was therefore not disabled based only on assumption. If the actual M21s
hardware lacks NFC, that must be confirmed from its board DT/firmware before
removing the driver, otherwise the M21 sensor/camera profile would be mixed
with an unverified hardware change.

Validation: `bash -n
target/m21s/patches/kernel9611/customize.sh` passes, the pinned
source contains `exynos9611-m21_defconfig`, and the existing generated
configuration was identified as the old F41 profile (`CONFIG_SENSORS_SSP_M31`);
the next M21s build must regenerate the kernel after this correction.

### M21s wallpaper resource rebuild (2026-09-29)

The first APK build after `make_rom -c` failed in `wallpaper-res` because the
One UI 9 decoded tree contains legacy uppercase resource filenames such as
`Default_Video_Wallpaper_ZVLB.mp4` and `Wallpaper_001.webp`. `aapt2` rejects
those names while creating `resources.zip`; the subsequent APK failures were
also amplified by multiple failed parallel workers leaving large temporary
`APKTOOL*.tmp` files in the tmpfs-backed `/tmp`.

`unica/mods/wallpaper/customize.sh` now normalizes only those twelve legacy
filenames to lowercase and updates their `public.xml` names without changing
their fixed resource IDs. The target catalogue and the One UI 9 wallpaper
feature resources remain otherwise unchanged. A clean rebuild (or a retry
after removing stale temporary APKTOOL files) is required; `-c` itself only
controls APK/JAR cache reuse and is not the source of the invalid names.

`scripts/apktool.sh` now passes a per-target build-volume Java temp directory
(`out/target/<target>/tmp/apktool-java`) to every Apktool decode/build. This
prevents concurrent aapt2 workers from exhausting the small host `/tmp`
tmpfs; old `APKTOOL*.tmp` files may still be removed manually before retrying.
The option uses the wrapper's required `-JD...` spelling; using `-J-D...`
would produce the invalid JVM option `--Djava.io.tmpdir`.

### M21s experimental repartitioner (2026-09-29, superseded layout)

The extracted F415F ZTO metadata allocates only 6,535,774,208 bytes to the
`group_basic` dynamic-partition group, while the current M21s build images
shown in the build log total 7,627.8 MiB. The A21s/Exynos 850
`repartitioner_A21s_Exinos850-v2024.05.zip` found in Downloads was therefore
used only as a code/packaging reference; its fixed `super=12288 MiB` and
Exynos 850 assumptions were not copied into the M21s target.

An explicitly temporary, standalone package is now under
`platform/exynos9611/installer/repartitioner_m21s/`. It is restricted at
runtime to `SM-F415F`/`f41`, resolves the physical disk from the `super`
by-name link, backs up the GPT, unmounts the logical/physical filesystems,
and aborts (restoring the backup) on a failed operation or invalid GPT. It
recreated `super` at **7828 MiB** for the earlier EROFS image set. That layout
is superseded by the ext4 11305-MiB layout documented below. It recreated
`prism` at 1024 MiB, `optics` at 33 MiB, `cache` at the target's
original 200 MiB, optional `omr` at 3 MiB, and `userdata` with the remaining
sectors. Optional `cp_debug`/`spu` entries are removed only when present; no
unknown partition is deleted implicitly.

`target/m21s/config.sh` is kept in sync with this temporary layout
(`TARGET_SUPER_PARTITION_SIZE=8208252928` and
`TARGET_GROUP_BASIC_SIZE=8204058624`). Without those build-side values,
`lpmake` would still reject the 7.6-GiB image set before the repartitioned
device could be tested.

This is not wired into the normal ROM installer. Build the recovery ZIP with
`platform/exynos9611/installer/repartitioner_m21s/build.sh`, flash it only on
the matching 64-GB F415F, reboot recovery, format data/cache, and keep the
complete stock ZTO firmware/PIT available. The package remains destructive
and experimental; the 200-MiB margin is not a final partition design.

Credits from the donor package are retained in both the script and README:
the original universal Exynos 7870 repartitioner was written by **@Astrako**
and later adapted for the A217F/A21s family. The donor recovery `update-
binary` and `sgdisk` are preserved as supplied; the M21s adaptation is
credited to At30c.

The first TWRP test showed why this cannot be diagnosed as a missing TWRP
script feature. TWRP supports `run_program`, but the original package only
looked for `/dev/block/by-name/super` and silently discarded every `sgdisk`
error. The script now also resolves the UFS link under
`/dev/block/platform/*/by-name/super`, checks `/sbin/sgdisk`,
`/system/bin/sgdisk`, and the bundled copy in that order, verifies that the
selected binary can actually execute, and writes all GPT errors plus rollback
messages to `/tmp/m21s-repartitioner.log`. If TWRP lacks the dynamic linker or
libraries required by the bundled `sgdisk`, the ZIP now aborts before changing
the GPT with an explicit error instead of appearing to do nothing. Rebuild the
ZIP after these script changes; an older copied ZIP still has the silent
failure behavior. The script writes `status=ok` to
`/tmp/m21s-repartitioner.status` only after the GPT verification succeeds, and
the updater script asserts that marker; a failed/rolled-back run can no longer
be presented as a successful installation. The first run with the corrected
bootloader guard exposed a 32-bit arithmetic overflow in the recovery shell:
`7828 * 1024 * 1024` wrapped before conversion to sectors, producing
`invalid size for super`; the GPT rollback then worked as designed. The size
calculation now reduces the MiB-to-sector factor before multiplication.
The next test then exposed a second layout conflict: stock GPT contains a
20-MiB `nad_fw` partition between `super` and `userdata`. The script now
records its original sector count, removes it while rebuilding the contiguous
range, and recreates it after `omr`; it no longer lets the enlarged `super`
overlap that firmware partition.

After the repartitioner succeeds, reboot recovery once so its by-name links
refresh before running the standalone
`platform/exynos9611/installer/format_m21s/` ZIP. That formatter uses the
recovery-provided `mke2fs` to create ext4 on `prism`, `optics`, `omr` and
`cache`, and `make_f2fs -g android` for `userdata`. It deliberately does not
format `super` (dynamic-partition container), `nad_fw` (raw firmware/NAD
partition), or `metadata`. Its status/log files are
`/tmp/m21s-format.status` and `/tmp/m21s-format.log`; the ZIP aborts unless
the status reaches `status=ok`. Formatting userdata is destructive. Build it
with `platform/exynos9611/installer/format_m21s/build.sh`.

The connected recovery test exposed a unified-TWRP property mismatch: recovery
reported `SM-M215F`/`m21`/`twrp_m21`, while the bootloader reported
`ro.boot.em.model=SM-F415F` and `ro.boot.hardware=exynos9611`. The guard now
uses the bootloader identity when it is present and requires the Exynos 9611
hardware, so a real M215F (with no F415F boot identity) is still refused. Do
not bypass this check or flash the F41 layout onto an M215F. Read-only
diagnostics confirmed that this TWRP exposes UFS as `/dev/block/sda`, both
`super` links resolve to `/dev/block/sda25`, and `/system/bin/sgdisk` executes
normally. The same read-only `sgdisk --print` reported an invalid backup GPT
header while the main header was valid. That warning must be investigated with
a stock PIT/firmware before making any partition change; the F41 package does
not repair it.

### M21s vendor/ODM 32-bit ABI advertisement (2026-09-29)

The M21s `zygote_vendor_compat` module was advertising
`ro.vendor.product.cpu.abilist`/`ro.odm.product.cpu.abilist` with ARM32 entries
while deleting both corresponding `abilist32` properties. That is internally
inconsistent and can make vendor/ODM 32-bit clients disappear from property-
based discovery even when the ARM32 linker, Bionic runtime and driver libraries
are present. It did not mean that the system should start a 32-bit app zygote:
`ro.zygote` remains `zygote64`.

The system/product side is left untouched because the Android 17 source is
already only-64. Vendor and ODM are explicitly normalized through the target
pattern: `abilist=arm64-v8a`, `abilist32=""`, and `abilist64=arm64-v8a`.
`SET_PROP` with an empty string is intentional here: the module's `.prop`
reader interprets an empty line as deletion, so
`zygote_vendor_compat/customize.sh` restores the keys with an empty value
after the property files are read. This keeps every vendor/ODM ABI-32 value
zero without modifying system. The ARM32 linker/runtime remains available
privately through `runtime32_compat`; these properties are not used to
decide whether a legacy driver can load.

### TWRP dynamic-partition installer sequencing (2026-09-29)

The first ROM-ZIP install after the experimental repartition failed inside
TWRP at `update_dynamic_partitions()` with `error: 25` and the misleading
message `Not enough free space to expand partition: vendor`. The generated
`dynamic_partitions_op_list` and `unsparse_super_empty.img` were internally
consistent: the four images occupy less than the 7824-MiB group limit and the
physical `super` is 7828 MiB. The recovery log then showed TWRP unmapping all
four logical partitions before liblp began resizing, so stale mounts were not
the root cause. A read-only dump of the physical `super` metadata found its
block-device table still advertising the original 6,539,968,512-byte size even
though the GPT entry had already grown to 8,208,252,928 bytes. liblp therefore
rejected the new `vendor` extent against the old internal capacity.

The first attempted workaround emitted explicit `unmount()` calls, but this
TWRP treats an absent `/system` volume as an installer error (`Failed to
unmount /system: No such volume`). That preamble was removed; the recovery
already logs that it unmaps the logical partitions internally. For the
temporary M21s layout, `target/m21s/installer/install-start.edify` extracts
`unsparse_super_empty.img` and runs `m21s-prepare-super-metadata.sh`. That
target-guarded script validates the F415F/Exynos 9611 identity and the 7828-MiB
`super`, then writes the new metadata payload to all four standard LP slots
and verifies a read-back before liblp runs. Rebuild the ROM ZIP after this
change; an already-created ZIP still contains the old updater script. The
change does not alter the GPT layout or image sizes.

### Work-dir reuse (2026-09-30)

`scripts/make_rom.sh` again reuses `out/target/<target>/work_dir` when its
`.completed` hash matches the current scripts, platform/target files, ROM
modules and extracted source/target firmware identities. This applies to a
normal invocation as well as `-c`; `-c` remains limited to the separate
per-file APK/JAR cache. When any tracked build input or firmware identity
changes, the stale work directory is removed immediately before rebuilding,
so old patched files cannot leak into the new tree. `-f` always forces that
clean rebuild. A packaging-only retry can therefore reuse the existing
completed work directory without re-extracting firmware or rebuilding APKs.

### M21s ext4 target (2026-09-30)

The M21s target now uses ext4 for every logical OS image. This matches the
F415F stock first-stage fstab and the kernel configuration (`CONFIG_EXT4_FS=y`)
and allows direct edits to the test filesystems without rebuilding EROFS
images. Source the target environment and run:

```sh
source buildenv.sh m21s
./scripts/build_m21s_ext4.sh
```

The helper reads the existing `out/target/m21s/work_dir`, estimates each ext4
image using the same first-pass reservation as `build_fs_image.sh`, adds a
configurable 256-MiB group margin plus 4 MiB for super metadata, writes the
calculated values to `out/target/m21s/m21s-ext4-layout.env`, and creates the
matching `m21s-repartitioner-ext4-experimental.zip`. It then exports the ext4
filesystem type and recalculated dynamic-group sizes for packaging.

`M21S_EXT4_SUPER_MARGIN_MIB=<MiB>` can override the temporary margin. The
repartitioner builder accepts an output path and super size in MiB. The
repartitioner remains experimental and destructive: flash it first, reboot
recovery, format the filesystems, then flash the generated ROM ZIP.

### M21s boot/fstab consistency guard (2026-09-30)

The target firmware initially supplies an ext4 `vendor/etc/fstab.exynos9611`
and the same ext4 file inside the stock boot ramdisk. The filesystem module
(`unica/patches/fs/customize.sh`) is the place that changes both copies to
the configured `TARGET_OS_FILE_SYSTEM_TYPE`; the source fstab is never copied
from the S24+ system side. It now validates the vendor copy and reopens the
repacked boot image to verify that `system`, `vendor`, `product` and `odm`
all use the selected type. The flashable ZIP also wraps boot extraction in
`assert(...)`, so recovery stops instead of silently leaving the stock boot
image in place. This prevents any logical image from booting with a mismatched
first-stage fstab; the M21s target currently selects ext4 for both.

### M21s ext4 super-size correction (2026-09-30)

The first all-ext4 packaging attempt failed in `lpmake`: `system.img` was
8,882,720,768 bytes by itself, while the old 7,824-MiB `group_basic` could
not contain it. The target now reserves 11,301 MiB for `group_basic` and
11,305 MiB for physical `super`, based on the observed system/vendor/product/
odm image total of approximately 11,045 MiB plus the configured 256-MiB
ext4 margin and metadata space. These values are synchronized across
`target/m21s/config.sh`, the repartitioner defaults, and
`m21s-prepare-super-metadata.sh`.

The new repartitioner layout is destructive and must be flashed before the
ROM when testing this variant. A stock F415F PIT does not provide the required
11,305-MiB `super`; keep the complete stock firmware available for recovery.

The regenerated package is
`out/target/m21s/m21s-repartitioner-ext4-11305MiB.zip`. Its embedded
`repartition.sh` was checked after packaging and contains `SUPERSIZE_MIB=11305`.
SHA-256: `e66430e717d68bc60ce188410a8aa6f06b65516b409ad29637196f4c45458add`.

### M21s ext4 boot failure: SELinux mapping aliases (2026-09-30)

The first 11,305-MiB ext4 build reached the kernel and first-stage init, so
the filesystem and repartitioner were not the cause of its reboot. The saved
`console-ramoops` showed `secilc` failing at
`system_ext/etc/selinux/mapping/31.0.cil:520` on
`expandtypeattribute (perf_prop_31_0)`, followed by `Unable to open SELinux
policy` and `InitFatalReboot`. The S24+ mapping supplied the `perf_prop` and
`qb_id_prop` API-31 aliases, but the F415F vendor policy does not publish
either attribute. `unica/patches/selinux/customize.sh` now removes both
through its existing compatibility-mapping cleanup; SELinux remains enforced
and no broad permissive bypass is added. A fresh build is required because the
failure occurs inside the generated system_ext mapping.

### M21s VNDK 31 alignment and recovery test (2026-09-30)

The extracted F415F ZTO vendor reports `ro.vndk.version=31`; its stock
`system/system/apex/com.android.vndk.current.apex` contains the internal
manifest name `com.android.vndk.v31`. The Exynos 9611 platform target was
therefore changed from `TARGET_BOARD_API_LEVEL=30` to `31`. The VNDK module
now stages this original F415F APEX at the framework's expected
`system_ext/apex/com.android.vndk.v31.apex` path for `m21s`, instead of using
the unrelated `b0qxxx` donor fallback. The v30-only cgroup runtime injection
remains restricted to VNDK 30 targets.

Because the test phone was already in root recovery, the installed firmware
was repaired without a full rebuild. `/system_root` was remounted read-write;
the original `com.android.vndk.v30.apex` was copied to
`/sdcard/m21s-recovery-backup-20260930/` and to the host directory
`out/target/m21s/recovery-backup-20260930/`, then replaced with the extracted
F415F stock APEX. The installed v31 file hash is
`00eb5662627f6182e75c5e61fe06612bbad151511fcc9e4f9291eafe50cb3360`.
The same recovery edit removed only the unresolved `perf_prop_31_0` and
`qb_id_prop_31_0` lines from `system_ext/etc/selinux/mapping/31.0.cil`; the
pre-edit mapping backup is also stored beside the APEX backup. The partition
had 94 MiB free after the replacement. This is a temporary, non-AVB test
modification; the next ROM build must include the source changes above.

The first direct boot test after replacing only the APEX reached
`linkerconfig`, which explicitly logged `Unable to access VNDK APEX at path
/apex/com.android.vndk.v30` and aborted on the missing
`SANITIZER_DEFAULT_VENDOR` variable. Inspection of the installed vendor
showed that this particular test image still had `ro.vndk.version=30`, unlike
the extracted stock F415F firmware. The vendor filesystem had no writable
`statfs`-available blocks, so its `build.prop` was repaired offline rather
than edited in place: a raw vendor dump was made, the original file was
recreated with `ro.vndk.version=31`, the temporary diagnostic binary
`bin/slsi_wlan_udi_log_decode` was restored from backup, and the repaired
image was written back to the vendor mapper. Verification after the write
reported 6305 bytes and `ro.vndk.version=31`. The next boot remained at the
splash screen and needs a fresh pstore capture from recovery; do not flash a
new build until that capture identifies whether the remaining failure is
linkerconfig/VNDK or an unrelated early-init issue.

The resulting recovery pstore (`out/target/m21s/recovery-vndk31-second-pstore.strings`)
contains no `linkerconfig` abort, no `secilc` compilation failure and no
kernel panic. Init reached the normal userspace path, but the vendor SBM/LPM
stack reported `sbm mode : poweroff` and deliberately ended with
`reboot: Restarting system with command 'lpm'`. Therefore that attempt did
not prove a VNDK boot failure; it was the low-power/charging boot path. When
testing from recovery, disconnect the USB power source before selecting
system reboot, or use the recovery UI's explicit “Reboot system” action, so
the device does not remain in `charging_mode`/LPM.

### X1S VNDK v31 donor (2026-09-30)

The Samsung Dumps `x1s` project (Galaxy S20, branch
`x1sxx-user-13-TP1A.220624.014-G980FXXSJHXC1-release-keys`) contains a
versioned `system/system/system_ext/apex/com.android.vndk.v31.apex`. The
prebuilt is stored at
`prebuilts/samsung/x1sxxx/system_ext/apex/com.android.vndk.v31.apex` and has
SHA-256
`dafab15626384623657dd1ed42accaa3a35eefb42456e93d3949ab7f57926477`.
Its 41,874,531-byte container is a valid ZIP and its payload manifest is
`com.android.vndk.v31`.

Before selecting it as a donor, its payload was compared with the extracted
F415F v31 APEX: both contain the same VNDK/LLNDK library-list files (identical
hashes), the same 268 shared-library filenames, and the same API-31 manifest
protobuf. The donor therefore supplies no missing VNDK library name; it is
still a cross-SoC binary donor (Exynos 990 to Exynos 9611), so it remains an
explicit M21s test variant rather than a guaranteed production replacement.
`unica/patches/vndk/customize.sh` now prefers this prebuilt for `m21s` VNDK
31 and falls back to the target's stock `com.android.vndk.current.apex` if
the prebuilt is absent. With the device manually mounted in recovery, the
installed `/system_root/system/system_ext/apex/com.android.vndk.v31.apex` was
backed up under `/sdcard/m21s-x1s-apex-backup-20260930/pre-x1s-v31.apex`, then
replaced by this donor and remounted read-only. The installed file was pulled
to `out/target/m21s/recovery-backup-20260930/installed-x1s-v31.apex` and
verified as a valid ZIP with manifest `com.android.vndk.v31`; its SHA-256 is
`dafab15626384623657dd1ed42accaa3a35eefb42456e93d3949ab7f57926477`, matching
the prebuilt. This is a recovery test only; the device has not yet been
rebooted with the donor, and the cross-SoC warning above still applies.

### M21s X1S-APEX boot attempt diagnostics (2026-09-30)

After installing the X1S donor directly from recovery, the boot attempt was
captured in `out/target/m21s/boot-diagnostics-20260930-apex-test/`. The APEX
did not produce the previous VNDK-30/linker fatal: there is no
`Unable to access VNDK APEX ... v30` message, and the device reached Android
`init`. Therefore this capture does not implicate the donor APEX as the direct
cause of the splash-loop.

The terminal failure is a kernel panic at approximately 455.818 seconds:
`Kernel BUG at hard_reset_hook_callback+0x114/0x160`, followed by a watchdog
panic/reboot. Before that, init reported failure to initialize platform
storage for vendor, linkerconfig could not find the generated linker
configuration, `watchdog1 did not stop`, and the vendor policy rejected
numerous property writes (`ro.debuggable`, `service.adb.root`,
`ro.crypto.fuse_sdcard`, and RMNET/WDA properties). The kernel also repeatedly
logged `sec_bat_get_battery_info: Fail to set psy ((null))`. These are evidence
of incomplete vendor/init/SELinux integration and a subsequent watchdog/hard
reset path, not proof of an APEX dependency failure. The donor remains
installed for controlled testing; do not treat this cross-SoC APEX as
production-safe until the vendor and watchdog issues are resolved.

The failed image was also built with a stale generated `out/config.sh` that
still contained `TARGET_BOARD_API_LEVEL="30"`, which caused the work tree to
retain `ro.vndk.version=30` even though the F415F stock vendor and the target
platform configuration are VNDK 31. The configuration was regenerated with
`source buildenv.sh m21s`; it now reports `TARGET_BOARD_API_LEVEL="31"`.
Future M21s builds must regenerate this file before reusing `work_dir`, or the
old VNDK-30 vendor/APEX combination can be silently reused.

### M21s vendor init/account compatibility (2026-09-30)

The X1S-APEX pstore also exposed three source/target integration mismatches
before the watchdog reset. The F415F `init.recovery.exynos9611.rc` is parsed
with the normal vendor rc files, so its `late-init` action attempted to set
`ro.debuggable`, `service.adb.root` and USB properties during a normal boot;
the M21s module now gates all of its events with
`property:ro.bootmode=recovery`, preserving recovery behavior without applying
those actions to Android. The same pstore showed Android 17 rejecting four
legacy `ril.clatd.v4-rmnet*` property triggers while parsing `init.baseband.rc`;
those optional RPS-tuning triggers are removed, while modem startup and the
remaining baseband actions are kept.

The Android 17 system side also contains DSMS/NGK init services whose
`vendor_dsms` and `vendor_ker` accounts are absent from the F415F vendor
passwd/group files. The platform-specific
`target/m21s/patches/fm_framework_compat` module adds the matching
Samsung IDs (5031 and 5554), removes obsolete `net.dns1`/`net.dns2` vendor
properties now owned by netd, and preserves vendor file metadata. Its two
unified patches were checked against the extracted F415F ZTO rc files with
`git apply --check`; no build was run. These changes target the explicit init
parse/property failures and publish the stock vendor API level (31) required
by Android 17's aconfig/platform-storage compatibility path. They do not
disable SELinux or the kernel watchdog.

### M21s stale VNDK tree correction (2026-09-30)

The charging/LPM animation still worked while normal Android stayed at the
splash. Inspection of the exact generated tree found the reason: despite
`platform/exynos9611/config.sh` and `out/config.sh` declaring board API/VNDK
31, `out/target/m21s/work_dir` still contained
`system/system/system_ext/apex/com.android.vndk.v30.apex`, a VNDK-30 payload,
and `vendor/build.prop`/the system_ext VINTF manifest still declared version
30. LPM does not mount the full Android system, so it could not expose this
normal-boot mismatch.

The root cause was also confirmed in Git: `platform/exynos9611/config.sh`
was present only as an untracked working-tree file. Without that file, the
target inherited the Exynos990 platform default (`TARGET_BOARD_API_LEVEL=30`),
and incremental reuse preserved the resulting VNDK-30 files. The M21s config
must be added to the repository before publishing the target; otherwise a
fresh checkout can silently recreate this API-30 mistake.

The stale v30 APEX was moved (recoverably) to
`out/target/m21s/recovery-backup-20260930/workdir-vndk30/`; the original F415F
`system/system/apex/com.android.vndk.current.apex` (embedded manifest
`com.android.vndk.v31`, SHA-256
`00eb5662627f6182e75c5e61fe06612bbad151511fcc9e4f9291eafe50cb3360`) is now
staged as `system_ext/apex/com.android.vndk.v31.apex`. The generated vendor
property and VINTF declaration were changed to 31, and
`ro.vendor.api_level=31` was added. This repairs the current generated tree;
the VNDK module must still be allowed to run on the next build so the fix is
recreated instead of relying on a hand-edited `work_dir`.

The connected M21s was then checked in TWRP. Its vendor already had
`ro.vndk.version=31` and `ro.vendor.api_level=31`, but
`system_ext/etc/vintf/manifest.xml` still declared VNDK 30 and the installed
APEX was the cross-SoC X1S donor (SHA-256
`dafab15626384623657dd1ed42accaa3a35eefb42456e93d3949ab7f57926477`). The
original F415F VNDK v31 APEX was copied to the device, the manifest was changed
to version 31, and the mount was returned read-only. Device verification
reported the target APEX SHA-256
`00eb5662627f6182e75c5e61fe06612bbad151511fcc9e4f9291eafe50cb3360` and
`com.android.vndk.v31` in its embedded manifest. The previous donor remains
backed up under `/sdcard/m21s-x1s-apex-backup-20260930/`.

After clearing the already-collected pstore and rebooting without touching the
hardware keys, the phone remained at the splash for more than four minutes and
did not return to recovery automatically. Thus the VNDK/API mismatch was real
and has been corrected, but it is not yet sufficient to explain the remaining
normal-boot hang; a forced recovery entry followed by a fresh pstore capture is
required for the next diagnosis.

The same compatibility set was applied directly to the connected M21s from
TWRP recovery on 2026-09-30. The original files were backed up under
`/sdcard/m21s-boot-compat-backup-20260930/` and on the host at
`out/target/m21s/recovery-backup-20260930/direct-boot-compat/`. Because the
mounted vendor filesystem had no writable COW space, individual copies would
truncate files; the final test image was rebuilt from the vendor backup,
checked with `e2fsck -fn`, and written to `/dev/block/mapper/vendor` from
recovery storage. The device-side SHA-256 checks matched the staged files:
`init.recovery.exynos9611.rc` 7deb56b6, `init.baseband.rc` 25d68e43,
`passwd` ba497b94, `group` f4d5b5b3 and `build.prop` 537d5cb7. The test image
contains `ro.vndk.version=31` and `ro.vendor.api_level=31`; the vendor mount
was returned to read-only. The phone was left in recovery and was not rebooted
automatically.

### M21s kernel hard-reset hook diagnosis (2026-09-30)

The first boot attempt after the vendor repair still returned to recovery. The
latest pstore capture is in
`out/target/m21s/boot-diagnostics-20260930-watchdog-stock/`; it shows
`Hard Reset` followed by `Kernel BUG at hard_reset_hook_callback+0x114/0x160`.
The callback belongs to `drivers/samsung/sec_hard_reset_hook.c`: the M21
kernel's Samsung key-notifier path incorrectly reaches the Power+VolumeDown
emergency-reset timer during normal boot, so the kernel deliberately calls
`BUG()` and reboots. This is not a Chrome, VNDK or filesystem failure.

The phone was also running kernel `4.14.345` while the generated M21 package
contained `4.14.355`; the generated package was installed directly from TWRP
after backing up `/dev/block/platform/13520000.ufs/by-name/boot` to
`/sdcard/m21s-boot-before-kernel-test.img`. Its AnyKernel Android-version
guard was widened from 13--15 to 13--17 only for this recovery test.

An experimental patch to default `hard_reset_hook_enable` to 0 was tested
briefly but is intentionally not kept: `hard_reset_hook_callback` is the
expected emergency handler when Power+VolumeDown are physically held. A pstore
line naming this callback therefore cannot distinguish a real key-forced reset
from a spontaneous one. It must not be disabled until a capture made without
touching those keys proves a phantom key event.

The same kernel patchset includes
`0003-clang21-allow-legacy-kernel-initializers.patch`, which adds the warning
flag needed by the bundled 4.14 build when using the host LLVM 21 toolchain;
without it, `kernel/params.c` fails with
`-Wdefault-const-init-field-unsafe` before producing `Image`.

### M21s recovery log capture (2026-09-30)

The recovery-side capture is stored in
`out/target/m21s/recovery-logs-20260930-101401/` (`dmesg.txt`, `pstore.txt`,
`recovery.log`, `getprop.txt` and `mount.txt`). It confirms that the device is
running TWRP/recovery kernel `4.14.113-Grass`, so this `dmesg` is not a normal
Android boot trace. Recovery mounted `/system_root`, `/vendor`, `/product` and
`/odm`; it does not contain a zygote crash or a normal-boot userspace trace.

The pstore in that capture contains the previous normal-boot failure: at about
191.6 seconds it records `Hard Reset` followed by `Kernel BUG at
hard_reset_hook_callback+0x114/0x160`. This is the same Power+VolumeDown
hard-reset path previously identified; because the reset was forced manually,
it cannot be used as evidence of a spontaneous Android crash.

The recovery kernel also reports non-fatal recovery/device-tree mismatches:
missing `calliope_sram.bin`, absent recovery health HAL, missing cpuset paths,
and `rt5665` invalid-GPIO warnings. These occur while TWRP probes hardware and
are not proof that the installed Android image fails for the same reason. The
pstore still contains older normal-boot SELinux/property and `TzDaemon`
`/dev/tzdev` permission-denied records; a clean boot without touching the
hardware keys is required to separate those from the manually forced reset.

### M21s 32-bit BoringSSL/runtime chain verification (2026-09-30)

The M21s work directory already carries the relevant chain used by the S20+
compatibility path. `system/system/lib/libcrypto.so` is the ARM32 r11s
library (SHA-256
`a05debb6190d31b40fc4dae67ae57334cae41bbd08db546038f99c3cfa8e81c6`), imported
by the merged desixtification `system/lib` tree. The vendor self-test binaries
remain the native F415F target files: `vendor/bin/boringssl_self_test32` and
`vendor/bin/boringssl_self_test64`. The 64-bit system self-test remains from
the Android 17 source, and `zygote_vendor_compat` supplies the vendor
trigger and SELinux/fs-config entries.

`system/bin/boringssl_self_test32` is now also copied explicitly from the
native F415F target by the M21s desixtification module. It is retained for
legacy/runtime tests, but remains inactive while the M21s contract advertises
an empty ABI-32 list and selects `ro.zygote=zygote64`; no 32-bit init trigger
is enabled. The 32-bit crypto library and vendor self-tests remain available
for legacy userspace consumers that actually require them.

The M21s vendor BoringSSL init file now follows the original F415F
`vendor/etc/init/boringssl_self_test.rc`: it directly schedules the 32/64-bit
vendor helpers based on the ABI properties, instead of depending on the
S24+-style imported dispatcher. With the ABI-32 property empty, only the
64-bit helper is started.

### M21s corrected recovery/pstore capture (2026-09-30)

The corrected capture is in
`out/target/m21s/recovery-logs-20260930-105803-fixed/`. The pstore files were
read individually with `adb exec-out` (the preceding attempt accidentally
passed `-T` as part of the command and captured a shell error instead of the
file contents). The real `console-ramoops-0` is 194755 bytes and
`pmsg-ramoops-0` is 2938 bytes.

The previous Android boot ended at approximately 105.9 seconds with `Hard
Reset` and `Kernel BUG at hard_reset_hook_callback+0x116/0x160`, followed by
the Samsung panic/watchdog path. The pstore also contains vendor-init SELinux
property denials and repeated `TzDaemon` `/dev/tzdev` permission failures.
The live `dmesg.txt` remains TWRP kernel `4.14.113-Grass`; it is not the
normal Android boot trace.

### M21s recovery/pstore capture after the timed reboot (2026-09-30)

The latest recovery capture is in
`out/target/m21s/recovery-logs-20260930-115410-current/`. It contains the
individual `console-ramoops-0`, `dmesg-ramoops-0` and `pmsg-ramoops-0` files,
plus the recovery `dmesg.txt`, `getprop.txt`, `mount.txt`, `recovery.log` and
`session-state.txt`.

Unlike the earlier manually forced reset, this pstore records a real kernel
software-watchdog expiry at `606.613795` seconds after boot (about 10 min
06.6 s): `softdog: Initiating panic` followed by `Kernel panic - not syncing:
Software Watchdog Timer expired 600s`. The kernel then arms the hardware
watchdog for another 30 seconds. It is therefore not a 10:25--10:30 minute
reset; the measured interval is approximately 10:06.6, with the final reset
expected roughly 30 seconds later.

The watchdog diagnostic selected `init` (PID 1), not `system_server`, and the
trace shows the init task sleeping in `epoll_wait`. Around the same point,
`tz_service` repeatedly exits because `/dev/tzdev` is denied, while the
hardware watchdog continues to be kicked normally. The log also contains a
burst of GPIO key events (codes 114/115/116) between 562 and 603 seconds;
those may be recovery-button interaction and are separate from the recorded
software-watchdog panic. No `Hard Reset`/`hard_reset_hook_callback` caused
this particular reboot.

### M21s timed reboot: TEEgris boot-unblock fallback (2026-09-30)

The automatic reboot was separated from the earlier key events. The pstore
records `softdog: Initiating panic` and `Software Watchdog Timer expired 600s`
after `init` remains blocked in the legacy `vendor/etc/init/teegris_v3.rc`
`wait_for_prop` actions. `tzdaemon` cannot open `/dev/tzdev` because the
custom universal9611 kernel keeps the TZDEV secure-world state unavailable;
this is an `-EPERM` returned by the driver, not an SELinux AVC. The stock F415F
kernel also contains `CONFIG_TZIC`/`CONFIG_TZIC_USE_TZDEV`, while the current
public universal9611 source has only stale defconfig entries and no TZIC
implementation, so the kernel-side compatibility fix remains a separate task.

The M21s platform now includes the diagnostic/boot-unblock module
`target/m21s/mods/vendor`. For `m21s` only, it
patches `teegris_v3.rc` so the boot action no longer waits synchronously for
`vendor.tzdaemon`/`vendor.tzts_daemon`; the dependent actions are triggered
only when the corresponding `Ready` property is actually published. The
failed `tz_service` and `tz_msg_recv` are marked `oneshot` to stop init's
five-second respawn loop while TZDEV is unavailable. This allows the Android
boot to proceed, but does not restore TEEgris functionality; it is intentionally
a fallback for testing and must not be presented as the final secure-world fix.
The patch applies cleanly to the current M21s vendor tree with
`git apply --check`; no full ROM build was run.

The apparent health-driver spam is from the recovery/vendor-compat capture,
not from the timed Android boot: `boot-diagnostics-20260930-vendor-compat`
shows recovery init repeatedly requesting
`android.hardware.health@2.0::IHealth/default`, while the F415F vendor tree
provides the Samsung `@2.1` HAL. The same capture reports healthd's unknown
`POWER_SHARING`/`OTG` supply types and missing optional cycle/capacity paths.
Those messages are compatibility noise in recovery and do not explain the
600-second software-watchdog panic; obtain a normal Android log before adding
a health HAL workaround.

### M21s direct TEEgris test application (2026-09-30)

The connected SM-M215F was in TWRP recovery (`adb get-state=recovery`). The
vendor partition was remounted RW and the original
`/vendor/etc/init/teegris_v3.rc` was backed up on-device as
`/data/stockmod-backups/teegris_v3.rc.stock-20260930-102053` (SHA-256
`b5995dafd91128e971edd0b6098d9145c35b2468eb46d81e1517183a6fa0ad64`). The
patched file was then written directly to `/vendor/etc/init/teegris_v3.rc`
and verified with SHA-256
`c45140d956ebd03f9d3801f7e29ca837b7f2a8f369e676bb2daa7eb252222ee6`, mode
0644, UID/GID 0:0 and `u:object_r:vendor_configs_file:s0`.

The vendor ext4 image had `f_bavail=0` even though `df` showed nominal free
blocks, so recovery returned `ENOSPC` for every data write. To make this
temporary direct test possible, the two optional Wi-Fi diagnostic trees
`/vendor/etc/wifi/mx140/debug` and `/vendor/etc/wifi/mx140_t/debug` were backed
up under `/data/stockmod-backups/vendor-wifi-debug/` and removed from vendor;
the diagnostic copies must be restored later or regenerated by a clean build.
`enable_test_mode.sh` was separately backed up, then restored with its original
SHA-256. No reboot was issued automatically.

### M21s TZDEV status capture from recovery (2026-09-30)

The connected device was still in TWRP recovery (`adb get-state=recovery`), so
this is not proof of a complete Android boot. The capture is stored in
`out/target/m21s/tzdev-check-20260930-123740/`.

In the live recovery kernel, `/dev/tzdev` and `/dev/tzic` exist and the dmesg
shows TZDEV deployment/startup completing (`tz_deploy_handler ...
Startuploader complete`) without `Permission denied` or `EPERM`. The pstore
from the previous charging/recovery session also contains no `tz_service` or
`TzDaemon` `/dev/tzdev` failure. A normal Android boot is still required to
confirm that the `teegris_v3.rc` fallback removed the original init blockage;
the recovery result alone cannot establish that.

### M21 kernel build diagnostics and incremental object reuse (2026-09-30)

The Exynos 9611 kernel integration now keeps the mounted checkout's `out/`
objects reusable when the source revision, target, toolchain, integration
script and kernel patch digest are unchanged. `platform/exynos9611/patches/
kernel9611/customize.sh` increments the cache schema to version 5 and
invokes `build_kernel.py --allow-dirty`; Kbuild remains responsible for
invalidating only objects whose command line or dependencies changed. The
final `Image` remains checksum-verified before it is accepted and repacked
into `work_dir/kernel/boot.img`.

Kernel compilation is permanently diagnostic for this target. The patch
`0004-stream-kernel-build-output-for-debugging.patch` enables
`KERNEL_BUILD_DEBUG=1`, streams compiler/linker output to the build terminal,
and saves it in `out/kernel_tmp-exynos9611/kernel-build.log`. A failed build
also includes its last 200 output lines in the Python exception, so the first
real clang or `ld.lld` error is no longer hidden behind `CommandError: exit
code 2`. This only changes build observability and object reuse; it does not
disable warnings-as-errors or skip a kernel patch.

The first debug build exposed the actual Clang 21 failure: legacy
`u64_to_user_ptr()` type-check temporaries in `kernel/bpf/syscall.c` and
`fs/verity/enable.c` triggered `-Werror,-Wdefault-const-init-var-unsafe`.
The existing compatibility flag only covered the corresponding `field`
diagnostic, so `0003-clang21-allow-legacy-kernel-initializers.patch` now passes
both `-Wno-default-const-init-field-unsafe` and
`-Wno-default-const-init-var-unsafe`. This is limited to the compiler warning
introduced by Clang 20+; it does not weaken runtime kernel checks or skip the
BPF/verity code.

The same incremental principle was restored for the Exynos 990/S20+ kernel
module: `platform/exynos990/patches/extremekrnl/customize.sh` no longer
deletes the shared `kernel_tmp-exynos990/out` Kbuild tree when packaged model
artifacts are refreshed. It still removes the model-specific `boot.img`,
`dtbo.img` and ZIP staging output, while the kernel build itself reuses valid
objects and recompiles only changed inputs.

### Desixtification shared-mount cleanup (2026-09-30)

The desixtification runtime/APEX merge previously called `umount` on only the
current path. Because `out/` is shared with the StockMod and legacy UN1CA
mount aliases, an APEX payload mount could propagate to all three paths and
leave the next build with `target is busy`. The shared
`platform/exynos990/patches/__desixtification/customize.sh` now uses
`DESIX_UNMOUNT`, which discovers only the matching `desixtification-*/mnt`
peers, detaches them safely (lazy fallback only for those paths), and clears
stale mounts before reusing a temporary tree. The existing stale M21 runtime
mounts were detached manually after validation; no unrelated mount was
changed.

### M21s latest normal-boot pstore capture (2026-09-30)

The latest boot diagnostics were copied while the SM-M215F was in TWRP
(`adb get-state=recovery`); the pstore files themselves are from the preceding
normal Android boot, not from recovery. They are stored in
`out/target/m21s/recovery-logs-20260930-191438-latest/` together with
`last_kmsg`, recovery dmesg, mounts, properties and uptime.

Unlike the earlier ~600-second software-watchdog report, this boot reached
userspace for about 318 seconds and then hit a direct kernel BUG in
`hard_reset_hook_callback+0x114/0x160`, called from the hrtimer interrupt path:
`drivers/samsung/sec_hard_reset_hook.c` intentionally calls `BUG()` after it
believes both `KEY_POWER` and `KEY_VOLUMEDOWN` are held for six seconds. The
pstore also shows the `gpio-keys` IRQs for those keys at the crash snapshot;
this makes the hard-reset hook/GPIO state the primary investigation target,
not the old `softdog` timeout. The same boot still logs `tzdaemon` failing to
open `/dev/tzdev` with `Permission denied` and repeated missing
`aidl/android.system.keystore2.IKeystoreService/default` interface requests;
those are recorded as separate integration issues and are not proven to be
the direct cause of this kernel BUG.

### M21s TEE/FBE boot-chain correction (2026-09-30)

The normal-boot records were reviewed again with the user-requested hard-reset
event excluded. The filesystem checks report no userdata corruption, ruling
out the repartitioner as the primary cause of the current splash-screen stall.
The latest trace reaches `late-fs`, where the late userdata/FBE mount is
coordinated, but has no evidence of advancing to `post-fs-data` or Zygote.
During that wait, vold repeatedly requests the absent
`android.system.keystore2.IKeystoreService/default` interface. The legacy
Keymaster 4.0 HAL is running, but `tzdaemon` cannot open `/dev/tzdev`,
`vendor.TEEGRIS.loaded` is never published, and VaultKeeper repeatedly exits
with status 255.

The F415F vendor already defines `/dev/tzdev` as `system:system` mode 0666 in
`vendor/ueventd.rc`, labels it `tz_user_device`, and grants the `tzdaemon`
domain access to that type. To make the legacy contract deterministic on the
Android 17 boot sequence, `m21s_vendor_compat` now applies a second,
M21s-only patch. Immediately before starting TEEgris it runs `restorecon`,
`chown system system`, and `chmod 0666` on `/dev/tzdev`. When
`vendor.tzdaemon=Ready` is received, it also starts Keystore2 again so vold can
complete the file-encryption handoff. The existing non-blocking property
triggers and oneshot fallback remain in place.

The 61.7-second sensorhub timeout in the captured boot requested
`sensorhub/shub_ramen_m31.fw`, proving that capture used an older F41/M31
kernel profile. The current generated and repacked kernel is configured with
`CONFIG_SENSORS_SSP_M21=y`, contains the built-in
`sensorhub/shub_ramen_m21.fw`, and contains no M31 firmware name. The kernel
integration now validates those facts even when reusing its incremental cache
and aborts instead of packaging a mismatched Image. The flashable builder does
include this repacked `boot.img`; the next device test must flash it together
with the updated vendor image.

Validation performed without a full ROM build: both customization scripts
pass `bash -n`; the two TEEgris patches apply in sequence to a pristine F415F
vendor rc; the second patch also applies to the current incremental work tree
and passes reverse-check; and the cached kernel Image/config pass the new M21
profile and firmware checks.

The live recovery inspection separated the installed state from the pending
fix. `/vendor/etc/init/teegris_v3.rc` on the device already contains the first
non-blocking/oneshot patch, but its SHA-256 differs from the current work tree
because it does not yet contain the second `/dev/tzdev` and Keystore2 patch.
The captured kernel also still requests `shub_ramen_m31.fw`. Therefore neither
new correction has been validated on-device yet: the next test must flash both
the rebuilt vendor image and the rebuilt M21 boot image before drawing a boot
result from it.

### M21s TEEgris IWD device-node correction (2026-09-30)

The TEEgris failure was narrowed beyond the generic `/dev/tzdev` diagnosis.
The stock `tzdaemon` loads the stock vendor `libteecl.so`; its failing
`iwd_socket()` probe uses `/dev/tziwsock`, while `/dev/tziwshmem` provides the
associated shared-memory transport. In recovery all three nodes appeared as
`0600 root:root`, and `tzdaemon` runs as `system`, which explains the exact
`EACCES (-13)` emitted before Keystore2 stalls. No SELinux denial is required
for this failure because Unix DAC rejects the open first.

The M21s-only `m21s_vendor_compat` module now applies
`0003-Prepare-TEEgris-IWD-device-nodes.patch` after its existing tzdev patch.
Before the TEEgris services start, it restores the labels and enforces the
original F415F vendor ownership/modes on the complete transport: `tzdev` and
`tziwsock` are `system:system 0666`, while `tziwshmem` is
`system:system 0660`. The existing vendor SELinux policy already labels the
three paths as `tz_user_device` and grants `tzdaemon` access, so no policy
relaxation was added. This correction is also safe for incremental work trees:
the new patch is independent from the already-applied `0002` patch and uses
the same forward/reverse validation before changing the rc file.

The same corrected rc was installed directly on the current test device from
TWRP, without waiting for another ROM build. During that write the ext4 vendor
filesystem exposed an Android kernel `reserved_clusters` corner case: all
remaining free clusters were reserved, so writes returned `ENOSPC` even to
root. The filesystem was checked, expanded only to the already allocated
logical-partition boundary, and its runtime cluster reserve was temporarily
cleared. The original rc was verified before the corrected 1212-byte file was
written; the installed SHA-256 is
`6749894eca904397b20cf39815a739c15822b72ea5c4d9d39fe0a8f2d8197900`, with
the expected `vendor_configs_file` label and mode 0644. Per user instruction,
no recovery-side backup was retained. This proves installation integrity, but
TEEgris/Keystore2 behavior still requires the next normal boot for validation.

The first boot with the complete IWD node correction proved that layer fixed:
the pstore in `out/target/m21s/recovery-logs-20260930-222340-after-iwd-fix/`
contains `Probe for D0 successful`, a successfully established secure-world
session and `Tzdaemon property is Ready`; the former `iwd_socket: -13` is
absent. The forced hard-reset happened around 220 seconds and is excluded as a
cause.

The boot still stalled because the already-running Keystore2 process never
published `IKeystoreService/default`. The previous Ready action used `start
keystore2`, which is a no-op for a running service. Patch `0004` now restarts
`vendor.keymaster-4-0` and then `keystore2` when TEEgris becomes Ready, forcing
both early-HAL processes to reconnect after the secure-world transport is
usable. The updated rc was also written directly from TWRP without retaining a
backup, as requested. Its installed size is 1247 bytes and SHA-256 is
`446963b5affa94eec1e53b24f8025def198f2afb5b36c7bbc01a767b354840e4`; `cmp`,
mode, owner and SELinux-label validation passed before vendor was remounted
read-only. This restart sequence still requires an on-device boot validation.

### M21s writable recovery mounts (2026-09-30)

The Exynos 9611 installer `recovery.fstab` now mounts the ext4 logical
`system`, `vendor`, `product`, and `odm` partitions as `rw`. This avoids TWRP
silently mounting a test partition read-only before direct compatibility
edits. The physical `prism` and `optics` partitions remain read-only.

Do not mirror this change into the Android first-stage
`vendor/etc/fstab.exynos9611`: its AVB/logical partitions intentionally remain
`ro`, and requesting writable mounts through the verified boot path can make
first-stage init reject or fail those mounts. The recovery-only change affects
future installer/recovery metadata; it cannot rewrite the fstab embedded in
an already installed third-party TWRP image.

### M21s TZTS/Keymaster ordering and persistent boot capture (2026-09-30)

The boot after patch `0004` confirmed that TEEgris itself is healthy, but
Keymaster still did not publish its HIDL interface and Keystore2 remained in a
futex wait. The legacy auxiliary daemon explicitly waits for the secure-world
ACSD endpoint and only then publishes `vendor.tzts_daemon=Ready`; therefore
`vendor.tzdaemon=Ready` alone is too early for opening the SKeymaster TA.
Patch `0005-Wait-for-TZTS-before-restarting-Keymaster.patch` leaves TZTS startup
on the base TEEgris Ready event and moves the Keymaster/Keystore2 restarts to
the `vendor.tzts_daemon=Ready` action. The patch passed forward/reverse checks,
was applied to the incremental work tree, and the resulting 1247-byte rc was
written directly to the test device with matching SHA-256
`6b108451ccc9deec5fc179f853a9fae4a21768702c8decadf456c7e0d8f86569`.

The following boot still stopped before Android exposed ADB. Its normal-boot
pstore is stored in
`out/target/m21s/recovery-logs-20260930-2042-after-tzts-wait/`. The record ends
with the user's forced hard reset at about 185 seconds, not an autonomous
watchdog reboot. It confirms that Keystore2 still failed to register. A manual
recovery test then proved that the stock `tzts_daemon` can publish `Ready` and
that launching the stock Keymaster afterward opens the stock Keymaster TA in
secure world; this narrows the remaining fault to the normal-boot service
environment or sequencing rather than missing TEE binaries, driver TAs, or
kernel IWD transport.

Because the 3 KiB pmsg does not retain the decisive Keymaster userspace error,
a temporary, device-only `vendor/etc/init/m21s_boot_debug.rc` was installed.
It temporarily switches SELinux to permissive at `post-fs` and streams all
logcat buffers to `/cache/m21s-debug/logcat.txt`. This is diagnostic only and
is intentionally not part of a build module; remove it after collecting the
next boot. Its purpose is both to preserve the complete early log without ADB
and to distinguish a policy denial from a Keymaster ABI/runtime failure.

The permissive diagnostic boot produced the same Keystore stall, so SELinux
was excluded as the primary blocker. The logcat file was not created, but the
larger pstore was saved as
`out/target/m21s/recovery-logs-20260930-2054-permissive-debug/`; it again shows
the base TEE daemon ready and no persistent TZTS process. The temporary debug
rc was then removed from the installed vendor partition, restoring normal
enforcing behavior for subsequent tests.

Patch `0006-Restore-ordered-TEEgris-startup.patch` now replaces the two
asynchronous readiness actions with Samsung's original synchronous `post-fs`
sequence. With the device nodes already corrected, init starts TEEgris, waits
for `vendor.tzdaemon=Ready`, starts TZTS, waits for
`vendor.tzts_daemon=Ready`, and only then restarts Keymaster and Keystore2.
This directly removes the observed startup race while preserving the original
vendor dependency contract. The patch passed application and shell syntax
checks and was installed directly from recovery; the installed 1257-byte rc
matches the work tree at SHA-256
`e8ebf6c26d99542ce87b2e7e6c09f1872d9c148a13b263764d8e54ab10538b33`.

### M21s Android 17 multidisabler and unencrypted data (2026-09-30)

The recovery return after the ordered TEEgris fix was not Android framework
Rescue Party. The normal-boot pstore showed Keymaster reaching secure world,
then `keystore2/km_compat generateKey : errorCode = -67`, followed by the
explicit init action `Service vold has 'reboot_on_failure' option and failed,
shutting down system.` Recovery inspection found the installed
`vendor/etc/fstab.exynos9611` truncated to zero bytes. This matches the old
Android 9-11 multidisabler failing with ENOSPC while using `sed -i` on a vendor
filesystem that was 99% full.

The generic old multidisabler must not be used on this Android 17 port. Besides
the unsafe in-place fstab edit, it disables VaultKeeper, PROCA, CASS and WSM,
which are dependencies of the M21s TEE/security startup chain. A target-only
replacement now lives in
`platform/exynos9611/installer/multidisabler_m21s`. It installs a complete,
validated F415F fstab, removes all userdata encryption fs_mgr flags, adds the
Android 17 `mkdir /data/data 0771 system system encryption=None` initialization
rule, and only disables stock-recovery restoration. It releases ext4 reserved
clusters during recovery installation and verifies the copied fstab with
`cmp`, preventing another silent zero-byte file. Build it with
`platform/exynos9611/installer/multidisabler_m21s/build.sh`; the current output
is `out/target/m21s/m21s-android17-multidisabler.zip`, SHA-256
`98f989ba27d6f4c6fda1df85237f9d9d64206a7ea4095518c154a8e74fd35e9d`.

Future ROM builds use the M21s-only
`target/m21s/patches/storage_compat` module. It keeps FBE enabled, converts
the legacy `fileencryption=ice` alias to the Android 17-compatible
`fileencryption=aes-256-xts:aes-256-cts:v1` policy, rejects an absent or empty
fstab, and removes the incompatible `mkdir /data/data ... encryption=None`
initialization rule. The filesystem module then propagates this validated
fstab into the boot ramdisk.

For the current test installation, the 2,144-byte unencrypted fstab was written
directly to vendor and verified with `cmp`; the init rule was written to the
installed system. The installed boot image was also extracted, its embedded
fstab changed to the same unencrypted userdata entry, repacked, reopened for
validation and flashed directly. The exact flashed 37,931,024-byte prefix
matches SHA-256
`bc8470a25c6d7da476249e0a575161e1ea6f95b61b420dd38fe638f8744ea0fd`.
The incremental work directory was synchronized with these three changes so a
subsequent ZIP-only package cannot restore the encrypted fstab accidentally.

The first direct boot test validates the storage part of the change. Its pstore
is saved under
`out/target/m21s/recovery-logs-20260930-2315-multidisabler/`: `/data`, its
`data_de`/`data_ce` mirrors and the profile mounts were created successfully,
and the earlier Keymaster `generateKey` error `-67` is absent. The primary
shutdown trigger moved to NetBpfLoad: loading
`/apex/com.android.tethering/etc/bpf/mainline/offload.o` returned libbpf error
1, followed by `Service bpfloader has 'reboot_on_failure'` and the explicit
reboot reason `bpfloader-failed`. The later vold failure occurs after shutdown
has already started and is secondary. Do not add a bpfloader bypass to the
multidisabler: the Exynos 9611 kernel/Tethering APEX compatibility must be
fixed separately so networking can initialize with valid BPF programs.

### M21s Android 17 BPF/Tethering compatibility (2026-09-30)

The follow-up normal boot is preserved in
`out/target/m21s/recovery-logs-20260930-233129-bpf-debug/pstore/`. It again
reaches NetBpfLoad, fails specifically while loading the Tethering APEX
`offload.o`, waits for the service timeout and reboots with
`bpfloader-failed`. The watchdog messages are shutdown noise, not the trigger.
A temporary attempt to capture logcat from vendor init was rejected because
this legacy init does not accept `setenforce` as an rc keyword. That diagnostic
block is not part of the repository or production configuration.

Inspection of the installed kernel config and the M21 defconfig found one
explicit Android 17 kernel-matrix mismatch: `CONFIG_NET_ACT_BPF` was disabled,
while `compatibility_matrix.202504.xml` requires it built in. BPF syscalls,
cgroup BPF, cls_bpf, the BPF JIT and xt_bpf were already enabled. Kernel patch
`0005-net-sched-enable-bpf-actions-for-android17.patch` enables only the
missing traffic-control BPF action for `exynos9611-m21_defconfig`. It passed a
clean `git apply --check`; regenerating the M21 config confirmed all six
relevant options as `=y`.

The M21s platform now also runs the same audited Android 17 Tethering
compatibility chain used by Exynos 990. It disables the obsolete 5.4/5.10
hard gates in `netbpfload`, disables the corresponding legacy-kernel gate in
`libnetd_updatable`, and removes the two optional service-connectivity BPF
event consumers that depend on maps unavailable on these old kernels. The
shared implementation is parameterized by the actual kernel version rather
than duplicated.

The netd program metadata is intentionally model-specific. Exynos 990 extends
the two Linux 4.19 programs to API 37. Exynos 9611 Linux 4.14 instead extends
only `ingress_stats_4_9_t` and `egress_stats_4_9_t`, whose kernel interval is
4.9 through 4.19; their maximum Android API changes from 3500 to 65536. The
original Android 17 `netd.o` hash is
`4418d9cca4dca5ca4ea8cfc2a61cee247946e6fa0d0ec111ed6b10954a9a2e5a`,
the expected M21s-patched hash is
`de859dc1efb34bfc53678b3844daeedb8b52fbc984ec13110775787d162c48e4`,
and exactly two metadata records matched. `offload.o` already contains native
4.14 program variants with an open-ended API range, so its program metadata is
not hex-patched.

During diagnostic cleanup, the 99%-full vendor filesystem again refused data
allocation despite reporting free blocks. Its ext4 `reserved_clusters` value
was 3725, reserving all practically writable space from recovery. Clearing
that runtime reserve allowed the temporary symlink to be removed and the
production 1,257-byte `teegris_v3.rc` to be restored as a regular vendor file.
The installed file has the expected `vendor_configs_file` label and SHA-256
`e8ebf6c26d99542ce87b2e7e6c09f1872d9c148a13b263764d8e54ab10538b33`;
all system-side diagnostic rc files and the former symlink target were also
removed.

The first kernel carrying `CONFIG_NET_ACT_BPF=y` compiled and flashed cleanly.
Its boot prefix SHA-256 was
`8da881a89104217fd338bd9256aaeaa50c8779c384af625acd02235e4606fca7`,
and the embedded config confirmed all required BPF switches. The boot in
`out/target/m21s/recovery-logs-20260930-234635-net-act-bpf/` nevertheless
failed on the same `offload.o` load and rebooted with `bpfloader-failed`.
Therefore the config correction is required by VINTF but is not sufficient;
the legacy kernel's BPF implementation still rejects part of the object ABI.

Two attempts to preserve logcat through an init service produced no output;
the production init configuration was restored after each attempt. To avoid
guessing at a large 4.19-to-4.14 BPF transplant, the current device-only test
kernel instruments only failing BPF syscalls made by `netbpfload`. It prints
`BPF_DIAG` with the command, errno, map definition and program definition into
the kernel log/pstore. The diagnostic boot image was validated after repack
and flashed with matching SHA-256
`0e92892f1adabb8bcc5984ea52d5332c59001b3abce43719d458985de6173a80`.
This instrumentation is intentionally absent from the platform patch set and
the work-dir boot image; after the next diagnostic boot identifies the exact
missing ABI, replace it with the narrow permanent backport.

The first syscall trace proved that every real `BPF_MAP_CREATE` from
`offload.o` is rejected with `EINVAL` before allocation. The Exynos 9611 UAPI
ends map creation at `map_name`, while Android 17 sends the 72-byte ABI that
continues with `map_ifindex`, `btf_fd`, `btf_key_type_id` and
`btf_value_type_id`. A second temporary diagnostic boot logs those four raw
words so the permanent backport can implement exactly the fields used rather
than silently discarding BTF metadata. Its validated 37,933,056-byte boot
prefix has SHA-256
`0023f48974de72ed8d9257d1a4fbac3c45f2127ffcd9008d57ce5c85ab1e3c04`;
the hash read back from the physical boot partition matched before reboot.

That second trace established that `map_ifindex` is zero, while every map
uses a valid BTF reference: `btf_fd=3` plus the exact key/value type IDs from
the successfully loaded object BTF. The correct fix therefore cannot discard
the new tail fields. The test kernel now backports the four map-create UAPI
fields, verifies key/value IDs and sizes through `btf_type_id_size()`, retains
the BTF object in `struct bpf_map`, and drops the reference on every success
and error teardown path. The full kernel rebuild succeeded, including all BPF
and UAPI consumers. The resulting 37,933,056-byte test boot has SHA-256
`7ced63afc7c825d00f77f1588b60bd6137833a485b7ccaf128b6cc00614439cf`;
the physical boot prefix matched after flashing. Temporary syscall telemetry
remains enabled for this one boot so any subsequent verifier incompatibility
is captured independently from the fixed map-creation path.

The map/BTF test boot confirmed that the backport works: all eight failing
`BPF_MAP_CREATE` calls disappeared. Loading then advanced to two 318-instruction
`BPF_PROG_TYPE_SCHED_CLS` programs, both rejected by the legacy verifier with
`-EACCES`. A third device-only diagnostic build prints only verifier error
messages generated by `netbpfload`; full per-instruction tracing remains off
to avoid overflowing pstore. Its validated boot prefix SHA-256 is
`cd294d353188949e00d4ee2bb038c9ef5188d9efb19c9238d9cb464007ccd2a7`,
and the physical readback matched before reboot. This verifier telemetry is
temporary and must not enter the permanent platform patch.

The first verifier capture preserved hundreds of empty `BPF_VERIFY:` records:
the legacy console split each prefix from the verifier text and pstore dropped
the continuations, so it did not expose the rejection reason. The replacement
device-only diagnostic keeps the last verifier message in a bounded 256-byte
buffer and emits one `BPF_VERIFY_RESULT` line, containing the return value,
instruction index and reason, only when a `netbpfload` verification fails. The
new kernel marker was confirmed inside the repacked image and its extracted
kernel is byte-identical to the compiled `Image`. The resulting 37,933,056-byte
boot prefix has SHA-256
`53b2a5c814bf20c397b9ff658b327b64c369b04f6315fdb294e6ddb2e0310036`;
the same hash was read back from the physical boot partition before reboot.
This single-result telemetry is also temporary and must be removed after the
specific verifier incompatibility is identified.

The single-result boot captured both missing verifier features explicitly. A
two-instruction feature probe was rejected as `invalid func unknown#160`;
helper ID 160 is `bpf_ktime_get_coarse_ns`. Both 318-instruction SCHED_CLS
programs then failed at instruction 223 with
`invalid bpf_context access off=164 size=4`; offset 164 in the contemporary
`__sk_buff` ABI is `gso_segs`. The service subsequently rebooted for
`bpfloader-failed`, so the watchdog output remains a shutdown consequence.
The complete capture is stored in
`out/target/m21s/recovery-logs-20261001-bpf-verifier-result-2/`.

The next device-only kernel test adds the helper-number ABI through ID 160,
implements only `bpf_ktime_get_coarse_ns` using the existing 4.14 monotonic
coarse clock, extends the `__sk_buff` layout through `gso_segs`, and translates
that read to the real `skb_shared_info.gso_segs`. Intermediate modern context
fields remain rejected because this kernel does not yet translate them. This
keeps the test narrower and safer than merely accepting every new offset.

The full kernel rebuild for that test completed successfully. The repacked
image was reopened and its embedded kernel matched the compiled `Image`
byte-for-byte (SHA-256
`85a47c25534da15465309f79ed1aed48c97ba503994efd29a87799d75c3ef991`).
The resulting 37,933,056-byte boot prefix has SHA-256
`f0173471b3133f9893e05d06dc3fa6485f833e03068c8884d1339b7a8794e817`;
the same hash was read back from the physical boot partition before reboot.
Verifier-result and failing-syscall telemetry remain enabled only for this
device test so any next missing ABI is captured instead of inferred.

That boot confirmed both fixes: helper 160 was accepted and context offset 164
advanced past verification. The two SCHED_CLS programs progressed from
instruction 223 to instruction 235, where both were rejected at context offset
176. In the same ABI, offset 176 is `__sk_buff.gso_size`. The follow-up test
therefore adds that field and translates its read to the existing
`skb_shared_info.gso_size`; writes remain forbidden. The supporting capture is
stored in `out/target/m21s/recovery-logs-20261001-bpf-gso-helper-test/`.

The `gso_size` test kernel compiled successfully. Its repacked kernel is
byte-identical to the compiled `Image`, SHA-256
`1882b6ed6cc663097cd4dd1c8eee81e3150216bd6f2ec03eb0ddef2b73fb367d`.
The resulting 37,933,056-byte boot prefix has SHA-256
`08126c0e05cf9df1ceae5d74244fe481c297f7e6cec8f535751741da1d9bd9c9`,
which matched the physical boot-partition readback before reboot. This is the
last build started by the assistant: for subsequent kernel builds, prepare the
changes, tell the user, and provide
`cd /home/ats0c/Git/ShitStockModOrSomething/out/kernel_tmp-exynos9611 &&
python3 build_kernel.py --target m21 --oneui --ksu --allow-dirty`; do not start
the build unless the user explicitly asks.

The `gso_size` boot then proved that the mandatory offload path is accepted:
`offload.o` loaded successfully after the map/BTF, helper 160, `gso_segs` and
`gso_size` compatibility work. NetBpfLoad advanced to
`dscpPolicy.o`, whose 551-instruction SCHED_CLS program was rejected with
`back-edge from insn 147 to 148`. The preserved evidence is
`out/target/m21s/recovery-logs-20261001-bpf-gso-size-test/pstore/console-ramoops-0`
(SHA-256
`e8541c97ab70c655de8601292a1cc33471585a16df08f703816bef21d9b0e35f`).
The failure is a bounded 16-entry policy scan, not another missing helper or
context field.

Do not permit arbitrary BPF back-edges in the 4.14 verifier. Upstream bounded
loop support arrived in Linux 5.3 with a new verifier parentage/branch-state
model; this vendor verifier predates that infrastructure, so bypassing its DAG
check would weaken verification rather than constitute a valid backport.
AOSP itself changed DSCP policy to require Linux 5.15 and explicitly states
that the feature is not required on older kernels. For the M21s Linux 4.14
path, `tethering_legacy/customize.sh` now changes only the
`dscpPolicy.o` program definition from `optional=false` to `optional=true`.
The loader may still create the IPv4/IPv6 policy maps, but rejection of the
5.15-only program can no longer abort NetBpfLoad or the system boot;
`DscpPolicyTracker` already treats an absent program as unusable. The original
object SHA-256 is
`418b9b09c96ed964bc408bff5df8f31e9fd5057d7f2bb56c3704c62c2ebdadec`
and the validated metadata-only result is
`3b9e62946d63e0e3a925080d68f96bc768cbdf22db14c0a14b3b2fde950f04b6`.
The change is gated by `LEGACY_KERNEL_VERSION=4.14`; Exynos 990 and newer
kernels are unaffected.

## M21s flashable ZIP: TWRP abort while unmounting logical partitions

The M21s recovery log from 2026-10-01 showed the flashable ZIP aborting before
dynamic-partition metadata was updated. The target installer emitted direct
edify `unmount()` calls for `/odm`, `/product`, `/system_ext`, `/vendor`,
`/system` and `/system_root`. This TWRP does not register every super child as
an edify volume, so an absent child returned `Failed to unmount /product: No
such volume` (and similarly for `/odm` and `/system_ext`), followed by
`Updater process ended with ERROR: 1`. The package's missing root
`compatibility.zip` and `file_contexts` messages were informational; the
failure occurred in the unmount preamble.

`target/m21s/installer/install-start.edify` now extracts and runs
`m21s-unmount-logical-partitions.sh`. The helper checks `/proc/mounts` and
`mountpoint` before attempting each path: a partition not mounted by recovery
is logged and skipped, while a real `umount` failure for an actually mounted
path still exits non-zero and aborts safely. This avoids treating a missing
TWRP volume as success for an unverified unmount and does not mask genuine
mount or storage errors. The installer root is copied automatically by all
flashable/full/incremental ZIP builders, so no builder-specific change is
needed.

After this source fix, generate a new M21s ZIP before flashing; an existing ZIP
still contains the old direct `unmount()` calls. Do not reboot the test device
from the build environment; wait for the user to report whether it booted or
returned to recovery.

## M21s post-install boot capture and ZIP version check (2026-10-01)

The device was found in TWRP recovery and its current pstore/recovery data was
captured under
`out/target/m21s/recovery-logs-20261001-192017-zip-install-followup/`.
`console-ramoops-0` and `last_kmsg` show that the preceding Android boot did
not reach the splash indefinitely: it shut down after about 94 seconds with
the explicit sequence:

```text
NetBpfLoad: Optional program cannot be loaded by libbpf
NetBpfLoad: Failed to load object: .../dscpPolicy.o, libbpf: 1
NetBpfLoad: === CRITICAL FAILURE LOADING BPF PROGRAMS ===
Service bpfloader has 'reboot_on_failure' option and failed
reboot: Restarting system with command 'bpfloader-failed'
```

This is the reason that installed test image did not boot. The earlier
`ro.crypto.fuse_sdcard` AVCs, linkerconfig warning, `watchdog1 did not stop`
messages and the later `vold` shutdown are secondary or non-fatal in this
capture. TEEgris reached `vendor.tzdaemon=Ready`, and Keystore2 was found in
the VINTF manifest, so this boot did not fail first in the VNDK/TEE chain.

The latest completed ROM log, `make_rom-20261001_175323.log`, confirms that
the Tethering module did run and logged
`Making the Linux 5.15-only DSCP program optional on Linux 4.14`. The decoded
work-dir APEX was independently inspected: its
`etc/bpf/mainline/dscpPolicy.o` hash is
`3b9e62946d63e0e3a925080d68f96bc768cbdf22db14c0a14b3b2fde950f04b6`, the
expected patched hash. Therefore the remaining failure is not a missing
HEX-patch application; Android 17's `netbpfload` still treats this failed
optional object as a critical load failure on the current legacy path. Do not
claim the optional-bit workaround is sufficient until the loader behavior is
changed or the unsupported `dscpPolicy.o` path is removed/handled explicitly.

The two 6.4-GiB ROM ZIPs were built before the installer guard was added. Their
`META-INF/com/google/android/updater-script` still contains direct edify
`unmount("/odm")`, `unmount("/product")` and `unmount("/system_ext")` calls,
and neither ZIP contains `m21s-unmount-logical-partitions.sh`. They will still
produce the old TWRP `No such volume` installation error. A new ZIP is
required after the installer source change; no reboot or direct device write
was performed during this capture.

The attempted removal of `dscpPolicy.o` and `dscpPolicy@funcs.o` was validated
and rejected by the next device boot: the pstore captured on 2026-10-01 at
20:54 shows `open(.../dscpPolicy.o) failed: No such file or directory`, then
the same `bpfloader` `reboot_on_failure` shutdown. The loader opens a fixed
DSCP object path before its optional-program handling, so deleting the object
does not disable the feature safely. The source has been restored to retain
both files and set the known object metadata to optional. The remaining fix
must be a narrow `netbpfload` change that ignores the DSCP load failure after
opening the object, not a global BPF verifier bypass. The new capture is
stored in `out/target/m21s/recovery-logs-20261001-205447-latest-boot/`.

## M21s Android 17: narrow DSCP loader bypass for Linux 4.14 (2026-10-01)

The Android 17 `netbpfload` 5.4 and 5.10 kernel-version gates had already
been replaced with normal-continuation branches; the decoded binary hash
`25f3b42b…` confirmed that fact. They must not be replaced by a fake global
kernel version, because the real version remains necessary to choose the
4.9–4.19-compatible netd BPF program variants.

The remaining hard failure was isolated by disassembling that patched binary.
After the normal BPF objects, the loader prepares the fixed
`dscpPolicy.o`/`dscpPolicy@funcs.o` pair. Those objects require the Linux
5.15-era verifier's bounded-loop support and cannot load on 4.14. In
`platform/exynos990/patches/tethering_legacy/customize.sh`, the M21s-only
(`TETHERING_LEGACY_KERNEL_VERSION=4.14`) path now replaces that preparation
instruction with a branch to the existing successful return. This skips only
the two DSCP objects; all earlier BPF objects are still opened, loaded and
validated normally. The exact resulting `netbpfload` SHA-256 is
`80ecac9684d6cd15f1e7b8636ced0bd3b761d96858a7a466b39173ad97d08d0a`, which
the script verifies before rebuilding the APEX. This must be calculated on
the full APEX binary, including `.gnu_debugdata`; the earlier analysis-only
copy had that section removed and consequently produced an invalid SHA.

The patch was statically validated by applying its unique byte sequence to
the real Android 17 binary and disassembling the result: address `0xf408`
now branches to `0xf48c`, the original success return. It has not yet been
put on the device; build a fresh M21s ZIP and inspect pstore after the next
user-initiated boot. Do not reboot the device from the host.

## M21s Android 17: netd BPF program-selection correction (2026-10-01)

The DSCP bypass reached a later, separate boot blocker. In the pstore capture
at `out/target/m21s/recovery-logs-20261001-222950-post-dscp-skip/`,
`NetBpfLoad` loaded `offload.o`, `test.o` and `clatd.o` successfully, but did
not load `netd.o`. It logged `kver:6060028` (Linux 6.6.40), whereas the same
boot's tombstone reports `4.14.355-openela-SN 1.3.0 Cross`. As no `netd.o`
program section supports Linux 6.6, no `/sys/fs/bpf/netd_shared` maps were
created. `libnetd_updatable.so` then aborted in `BpfHandler::init`, and init
rebooted because `netd1shot` is marked `reboot_on_failure`.

The installed `netd.o` does contain the required legacy implementations,
including `ingress/stats$4_9_t`, `egress/stats$4_9_t` and
`cgroupsock/inet_create$4_14_t`; the issue is their selection, not their
absence. `target/m21s/patches/tethering_legacy/customize.sh` now opts
in to `TETHERING_BPF_PROGRAM_KVER=4.14.355`. The common APEX module replaces
only the eight instructions that parse and cache the version used by
NetBpfLoad's object selector with `KVER(4,14,355)`. It does **not** alter the
global `uname` result or system properties. The expected complete-binary hash
after the DSCP and selector patches is
`e2d014d42e193533b190ce6417e9b6bacd2d0cfd4d199bb48a60891caae4b498`.

Static validation must confirm both: `netbpfload` disassembles the selector as
`mov w8, #0x163; movk w8, #0x40e, lsl #16`, and the next boot logs loading
`netd.o` before `NetBpfLoad: success`. Do not reboot the device from the host;
the user controls recovery/boot transitions.

For a recovery-only native APEX repair, set
`TETHERING_SKIP_SERVICE_PATCHES=true` while invoking the module. It preserves
the installed `service-connectivity.jar` rather than trying to reapply its
smali patches, then rebuilds/signs only the APEX payload. This is intentionally
opt-in: normal ROM builds must keep applying the JAR compatibility patches.
The common module also accepts the prior DSCP-only binary hash as an input
state, so this recovery path can apply the selector correction incrementally
instead of requiring an unmodified donor APEX.

On 2026-10-01 the correction was also produced as a standalone Tethering APEX
from the installed M21s image and written directly from TWRP recovery to
`/system/system/apex/com.google.android.tethering_compressed.apex`. The final
container SHA-256 on both host and device is
`6c25b17b15a0e9875d78455a2452bbf232786192dc3aafb040352847f278ee63`; its
embedded `bin/netbpfload` SHA-256 is the expected `e2d014d42…`. The write used
the existing inode, restored `root:root`/`0644`, verified the remote hash, and
remounted `/system_root` read-only. The device was deliberately left in
recovery for a user-controlled boot test.

That test confirmed the selector correction (`kver:40e0163`) but exposed an
earlier Android V gate: `Android V requires kernel 4.19.` It occurs before
`netd.o` loading. The M21s path therefore also converts only its conditional
branch at `0xa538` into an unconditional branch to the normal continuation
at `0xa55c`; it does not remove later program-range or verifier checks. The
new full `netbpfload` hash is
`58ba6358de058d267e504c95ec1227c074dfb801ab08b7046b6cc4795fabd941`.
The APEX repair chain accepts each of its three verified intermediate hashes
(DSCP-only, 4.14 selector, and selector plus Android-V gate), preserving those
states during subsequent recovery-only rebuilds rather than rejecting them as
unknown binaries.

The selector-plus-V-gate APEX was applied directly from recovery after host and
device temporary-file hash verification. Its installed container SHA-256 is
`1b3defa653f7f0c54b3823f8b1e166946189c533d57fec1e0dc242751e183ea1`;
ownership/mode were restored to `root:root`/`0644` and `/system_root` was
remounted read-only. The device remains in recovery pending a user-controlled
boot attempt.

## M21s Android 17: libnetd Android-V legacy-kernel gate (2026-10-02)

The post-gate boot was collected from TWRP into
`out/target/m21s/recovery-logs-20261001-230342-after-v-gate/`. It proves that
`NetBpfLoad` now reaches `success`; the remaining reboot is not caused by
`bpfloader`. `netd1shot` then aborts and init performs the intentional
`reboot,netd1shot-fail` because that service has `reboot_on_failure`.

The contemporaneous tombstone (`tombstones/tombstone_03`) identifies the
exact abort: `libnetd_updatable_init.cfi+564`, with the message `V+ platform
with kernel version < 4.19.0 is unsupported`. This is a **second** Android-V
version gate inside `lib64/libnetd_updatable.so`, independent of the already
patched NetBpfLoad gate. The M21s path changes only the `tbz w8, #0,
normal_continuation` at file/VA `0x91d0` to `b normal_continuation` (`88 08 00
36` to `44 00 00 14`). It reaches the original continuation at `0x92e0`, so
the subsequent BPF, map and verifier checks remain active. The verified
complete-library SHA-256 changes from
`ff780803b29a3fb993c841ca8da6166dcb32c8eb65f216cdab10b3066713ca32` to
`4a149ce65e7f9a052127bd1490edc2af7fe2d11cd8dce2e40d721257e561032e`.

The targeted APEX repair was rebuilt in tmux with
`TETHERING_SKIP_SERVICE_PATCHES=true`, so the installed
`service-connectivity.jar` was preserved byte-for-byte. It was written from
TWRP recovery to `/system_root/system/apex/com.google.android.tethering_compressed.apex`,
then verified on host and device as container SHA-256
`a7608fa70da2890ac152cfa01b153347fa57e3bd18056e82767a6c6db036da81`.
The inode ownership/mode was restored to `root:root`/`0644` and
`/system_root` was remounted read-only. The user must initiate the next boot;
the host must not reboot the phone.

## M21s Android 17: netd BPF program fallback (2026-10-02)

The first boot after the libnetd Android-V gate repair passed that gate. The
new tombstone (`recovery-logs-20261001-231847-post-libnetd-v-gate`, timestamp
`02:17:27 UTC`) instead reports `Failed to get program from
/sys/fs/bpf/netd_shared/prog_netd_skfilter_allowlist_xtbpf: No such file or
directory`. The APEX `netd.o` contains the legacy
`skfilter/allowlist_xtbpf$4_9` section, so this is a loader/kernel capability
failure rather than a missing file from the package.

The active kernel configuration also reports `# CONFIG_BPF_JIT is not set`,
while `out/kernel_tmp-exynos9611/out/.config` contains `CONFIG_BPF_JIT=y` and
`CONFIG_BPF_JIT_ALWAYS_ON=y`. This discrepancy must be fixed in the boot
kernel build before claiming complete Android 17 BPF support. The active
kernel does retain `CONFIG_BPF_SYSCALL`, `CONFIG_CGROUP_BPF`,
`CONFIG_NET_CLS_BPF`, `CONFIG_NETFILTER_XT_MATCH_BPF`, and
`CONFIG_NET_SCH_INGRESS`.

Until the kernel is corrected, the M21s-only Tethering APEX changes the
aggregate-error handoff immediately after `BpfHandler::init()` in
`libnetd_updatable.so` (`cbnz w8, fatal` to `nop`). The handler still attempts
to load every map and program; ordinary BPF operation errors remain visible.
It only prevents one unavailable legacy BPF program from aborting `netd1shot`
and forcing a reboot. The verified full-library SHA-256 after this fallback is
`ca94a16c778741cbd87fa2dbf4f2db4d8511b22e32e6380232ee7386bc61ecff`.
For this firmware revision the actual conditional at file/VA `0x136c0` is
`cbnz w8, fatal` (`c8 04 00 35`), immediately after the BpfHandler result
load at `0x136bc`; it is replaced with `nop` (`1f 20 03 d5`). Do not reuse a
different instruction signature without disassembling/validating the target
library first. The recovery-only rebuild was completed in tmux with
`TETHERING_SKIP_SERVICE_PATCHES=true`, preserving `service-connectivity.jar`.
The resulting container SHA-256 is
`992aeb2f31231a65eabf1995f51030d728463be56499bdb134d3ca8bb20464ea`; it was
verified in both `/tmp` and
`/system_root/system/apex/com.google.android.tethering_compressed.apex`, then
the partition was restored to read-only with owner/mode `root:root`/`0644`.
The device remains in recovery and must be booted manually by the user.

## M21s Android 17: restore the stock Mali userspace/kernel DDK pair (2026-10-02)

The actual M21s boot capture
`out/target/m21s/boot-diagnostics-2026-10-01_23:42:45-0300/logcat.txt` proves
that the NetBpfLoad fallback reaches `success`; it also identifies the next
fatal boot blocker as graphics.  `SurfaceFlinger` aborts after
`eglInitialize` returns `EGL_NOT_INITIALIZED`, while Mali reports `Failed
creating base context during opening of kernel driver`.  The generic message
that the kernel module may not be loaded is misleading: the kernel log proves
that Mali does probe successfully.

The relevant compatibility fault is explicit.  The retained stock F41/M21s
`vendor/lib64/egl/libGLES_mali.so` is Mali G72 **r32p1-01bet2**.  The pinned
universal9611 source instead contains commit `bec194d71b52` ("Use Mali
BiFrost R38P1 driver for all devices"), and the M21 defconfig consequently
builds **r38p1-01bet0**.  The two DDKs use different userspace/kernel ioctl
interfaces.  `target/m21s/patches/kernel9611/patches/0006-m21-restore-mali-r32p1-ddk.patch`
restores `CONFIG_MALI_BIFROST_R32P1=y` only for M21; it leaves all Android 17
BPF/capability patches and every other device defconfig untouched.  The
kernel integration now validates the resulting `.config` and refuses an
Image compiled with r38p1.  A kernel rebuild and user-controlled flash/boot
test are required before treating this as device-validated.

## M21s Android 17: stock audio HIDL 6.0 VINTF declaration (2026-10-02)

The later boot capture
`out/target/m21s/boot-diagnostics-2026-10-02_02:26:40-0300/logcat.txt`
proves that the rebuilt kernel runs the matching Mali DDK
`r32p1-01bet2`. It also exposes an independent, now-fatal audio problem:
`audioserver` starts, `FactoryHal` reports `Found no HAL version, main(Device)
null null` and `main(Effect) null null`, then `AudioFlinger::onFirstRef()`
segfaults. Four crashes before boot completion cause `bootchecker` to request
`reboot,rescueparty_by_bootchecker R2`.

The M21s audio service tries HIDL 7.1, 7.0, 6.0 and then succeeds at the
stock-declared 5.0 factory. Android 17's AudioFlinger cannot safely use that
5.0 fallback. Crucially, this is not a P3s dependency: the M21s firmware
itself contains `android.hardware.audio@6.0-impl.so` and
`android.hardware.audio.effect@6.0-impl.so` in both ABIs; their hashes in the
assembled target exactly match `out/fw/SM-F415F_ZTO`. Only its vendor VINTF
manifest declares 5.0, which rejects the service's attempted 6.0
registration.

`target/m21s/mods/vendor` therefore changes only
the two stock VINTF factory declarations from HIDL 5.0 to 6.0. It validates
that both target-native 64-bit implementation libraries exist and imports no
P3s audio HAL, configuration, or binary. The expected boot proof is service
registration at `android.hardware.audio@6.0` and
`android.hardware.audio.effect@6.0`, followed by a surviving `audioserver`.

### Recovery-only validation and vendor-space constraint

The M21s was left in TWRP recovery and the installed vendor manifest was
updated directly for a no-build test. The ext4 vendor filesystem reported
free blocks but zero *available* blocks (`f_bavail=0`), so `sed -i` could not
allocate its temporary file and truncated `vendor/etc/vintf/manifest.xml`.
Do **not** use in-place editors on this nearly-full partition.

The manifest was restored from the matching stock F41 firmware after changing
only its two audio factory declarations to HIDL 6.0. Because no new ext4
block could be allocated, the corrected 14,391-byte file was written into the
already allocated inode of the non-boot Wi-Fi diagnostic file
`vendor/etc/wifi/mx140_t/debug/wlan/univif.dbg`, then renamed atomically
inside the vendor filesystem to `vendor/etc/vintf/manifest.xml`. It was
verified to contain the closing XML tag plus both `@6.0` factory entries,
owned `root:root`, mode `0644`, and vendor was remounted read-only. This test
does not reboot the device; the user controls the next boot.

To cross the ext4 minimum-free threshold during recovery, these diagnostic
files were copied to
`out/target/m21s/recovery-temporary-backup-20261002/` and removed from the
installed vendor partition: `mx140/debug/common/log-strings.bin`,
`mx140/debug/wlan/unicli.dbg`, and the two
`*/debug/hardware/moredump/moredump.bin` files. They are not boot components;
the normal build source still retains them and the next full vendor image
restores them.

## M21s Android 17: legacy ION/G2D ueventd migration (2026-10-02)

The `2026-10-02_02:26:40` capture contains a separate graphics/media blocker:
allocator, HWC and OMX report `open /dev/ion failed: Permission denied`, and
`libacryl` cannot open `/dev/g2d`. This is an init-configuration issue, not a
missing driver: F415F stock keeps the full node-permission table at
`vendor/ueventd.rc`, while the Android 17 system imports only
`vendor/etc/ueventd.rc`. The stock file was consequently ignored and both
legacy nodes fell back to `root:root 0600`.

`target/m21s/patches/fm_framework_compat` now moves the unchanged
target stock table to `vendor/etc/ueventd.rc`, assigns it
`vendor_configs_file`, and removes the ignored root-level copy. The retained
entries set `/dev/ion` to `0666 system:system` and `/dev/g2d` to
`0660 system:graphics`; the legacy graphics allocator and composer services
already run in the `graphics` group. This remains M21s-specific and does not
weaken SELinux. The next user-controlled boot must verify node ownership/mode
and then determine whether the separate Gralloc/mapper compatibility warning
still remains.

### Device validation (boot capture 2026-10-02_03:58:10)

The next boot proves the ueventd migration took effect: there are zero
`open /dev/ion failed` and zero `Failed to open /dev/g2d` records, HWC starts,
and no Mali base-context failure occurs. The audio HIDL 6.0 factories also
register successfully. These fixes must be retained.

The new primary failure is distinct: Android 17 `SurfaceFlinger` and
`media.swcodec` both abort with `gralloc-mapper is missing`. The active
`libui.so` first seeks mapper 4.0, then 3.0; the target vendor declares only
the legacy HIDL mapper 2.1. It reaches `Gralloc4: mapper 4.x is not supported`
and aborts when `GraphicBuffer` is constructed. The software Codec2 crash is
the same problem (`libui.so -> AHardwareBuffer_isSupported ->
isHalPixelFormatSupported`), not a codec-specific failure.

Do not copy F415F's `libui.so` alone as a quick workaround. Android 17
SurfaceFlinger imports many symbols absent from that older library, so it
would fail dynamic linking before graphics initialization. Any future
compatibility solution must be an ABI-matched graphics bundle (SurfaceFlinger,
libgui and libui) or a narrow, validated change in the current libui mapper
selection; it cannot be a VINTF declaration that pretends mapper 4 exists.

### M21s graphics modules were previously skipped (2026-10-02)

The first M21s build only printed the module names `Legacy graphics mapper
fallback` and `Surface generation compatibility`; it did not print any
`HEX_PATCH` lines. This was caused by guards, not by a successful patch:
`legacy_graphics_mapper` skipped every target API above 30, while
`surface_generation_compat` was restricted to `exynos990`.

The M21s `work_dir` was checked before changing the guards and contained all
five expected legacy signatures: two in
`system/system/lib64/libui.so` and three in
`system/system/lib64/libgui.so`. The modules now allow the validated
`exynos9611` target while preserving the skip for other modern platforms. A
new M21s build must show two `libui.so` patches and three `libgui.so` patches;
the old build log cannot reflect this source change.

### M21s graphics patch boot validation (2026-10-02 10:37)

The recovery-applied `libui`/`libgui` patches were present during this boot.
The previous fatal `gralloc-mapper is missing` message is absent, there is no
`generation number mismatch`, and SurfaceFlinger reaches its main thread,
RenderEngine and Mali-G72 OpenGL initialization. The display/HWC path also
creates its G2D MPP workers. The remaining `mapper 4.x/3.x is not supported`
messages are expected capability fallbacks, not the former abort.

`media.swcodec` still logs failed 4x4 allocations for format `0x2b` with
`Unknown error -5`; it does not crash or trigger this reboot. This is a
separate format/allocation compatibility issue to investigate after boot is
stable.

The boot failure in this capture is now `netd`: it exits with status 2 five
times after `ip6tables-restore` reports `bpf: failed to get bpf object` and
`Failed to initialize BandwidthController (Operation not permitted)`. Init
then kills zygote, and `bootchecker` requests
`reboot,rescueparty_by_bootchecker R2`. The graphics patches are therefore
not the cause of this reboot; the next repair target is the netd bandwidth/BPF
object path and its kernel permissions.

### Recovery-only graphics patch validation (2026-10-02)

The M21s was connected in TWRP recovery and the current installed binaries
were confirmed to match the unpatched `work_dir` hashes. The two modules were
then applied directly to `/system_root/system/lib64` without rebuilding:

- `libui.so`: `466dffbd...` -> `1eaed0da...` (both legacy mapper gates);
- `libgui.so`: `aff919fe...` -> `29980aaf...` (all three surface-generation
  sequences).

The complete original files are preserved at
`out/target/m21s/recovery-graphics-backup-20261002/` as `*.orig`; patched
copies are stored there as `*.patched`. The system was remounted read-only
after writing, ownership/mode remained `root:root`/`0644`, and the device was
left in recovery for a user-controlled boot test. This direct modification is
temporary and will be replaced by the normal build output on the next flash.

## M21s netd loader and media.swcodec APV correction (2026-10-02)

### APV hard-disable and runtime validation (2026-10-03)

The APV probe persisted after removing the XML entries and APEX libraries because
Android 17 also carried APV loader names in `libcodec2_vndk.so`. The final
compatibility pass now clears both AConfig values (`apv_software_codec` and
`apv_software_codec_cq`), makes their exported flag queries return false, makes
`android_media_codec_apv_support` return false in the 32/64-bit system copies,
and rewrites the residual loader names to existing raw/AVC software codec
libraries. The APEX copy and the `/system/lib*` copies are all covered so the
media process cannot select an unpatched linker namespace.

The compressed artifact installed through TWRP is
`out/m21-capex-final4.cXCZfU/media-swcodec-fixed-final4.capex`, SHA-256
`96310c05b2f88dba2f516e5c7dac99e20ff0fd736c3b9739f2ba3e5f5b4451ce`. Its
inner AVB payload verifies with root digest
`b9f97c6cb22608ff64268d170f45b6758db7201a4a48d480f16cda0071b84b0d`. The
corresponding system libraries were written in recovery with SHA-256
`13557417038b0b8efd6beaa29aa22b01ef742000f1dbc4364eba41437de3ba61`
(64-bit) and
`acc7b03bc399db408c06000669aed939452d15b128088f60177aaf2d3732a4cd`
(32-bit).

After reboot, `sys.boot_completed=1`, `media.swcodec` remains running, and the
boot log contains no `C2Store` APV/dlopen error, `SIGABRT`, APV component name,
or SetupWizard ANR. Keep the source changes in
`target/m21s/patches/codec2_compat/customize.sh`; a future full
build will reproduce the APEX and system-library changes without carrying the
recovery-only artifact.

The `2026-10-02_10:37:11` boot log proves that the fatal netd failure is not
caused by a missing `netd.o`. The installed Tethering APEX contains `netd.o`
and that object contains all three programs requested by ip6tables/netd:
`denylist_xtbpf`, `allowlist_xtbpf` and `ingress_xtbpf`. NetBpfLoad logs only
`offload.o`, `test.o` and `clatd.o`, however, before declaring success.

Disassembly identified the regression in the first M21s DSCP workaround. Its
branch at `netbpfload` VA/file offset `0xf408` jumped to the successful return
at `0xf48c`; this skipped both unsupported `dscpPolicy.o` and the required
`netd.o`. The corrected branch goes only to `0xf41c`, the start of the
`netd.o` load. The parallel `@funcs` path at `0xf464` now similarly jumps to
`netd@funcs.o` at `0xf478`. The final binary SHA-256 after the DSCP, 4.14
selector and Android-V gate changes is
`02224cd3f3a4aae897056e46eb668d4a58df45c1964da95b90c28c15446e4b1b`.
The module recognizes and migrates all three hashes produced by the former
overly broad patch, so incremental work directories are repaired rather than
rejected. Runtime success still requires a new APEX/reboot validation showing
`netd.o` in NetBpfLoad and a persistent regular `netd` process.

The same log shows that `media.swcodec` itself does not exit: its PID remains
alive. Its recurring allocation errors are produced while Android 17 enables
and probes `c2.android.apv.decoder` and `c2.android.apv.encoder`. Both request
a 4x4 GraphicBuffer in format `0x2b`, which the legacy Mali-G72 gralloc rejects
with error `-5`. The M21s Codec2 compatibility module now rebuilds only the
media.swcodec APEX, removes the two APV catalogue entries and their two APV
component libraries, and preserves AVC, HEVC, VP8/9, AV1 and every audio
software codec. This is target-specific because APV is unsupported by the
M21s hardware/userspace graphics stack. Runtime validation must confirm zero
`C2SoftApv*` and zero `format 0x2b` allocation attempts while media.swcodec
and the remaining Codec2 components continue to register.

The media module must retain the compressed wrapper. Replacing the 16 MiB
CAPEX with a 36 MiB uncompressed APEX exhausts the nearly-full M21s system
filesystem. The implementation therefore signs the corrected inner APEX,
places it back into the source firmware's `original_apex` CAPEX wrapper,
updates the payload public key and signs the outer container. It also accepts
an already-patched uncompressed work-dir APEX and obtains a clean wrapper from
`out/fw/<source>/system/system/apex`, making incremental builds idempotent.

Both corrected artifacts were installed directly in TWRP without booting the
device. The installed Tethering container SHA-256 is
`edb74ffa6d6f65892eb18fcb8b4b0856c1c5544c8472ed35ee29c5b2e4d9989a`;
the compressed media.swcodec container SHA-256 is
`1fbc435e45a27927987d0278efe83888c891ba5ec43255a1ae965bf0ebdd2029`.
During the space-safe replacement, the SBrowser preload was temporarily
removed, then restored byte-for-byte with SHA-256
`7cb6a12122398801353e26ef94aed6fb6058bef307664f35e1010e3fea35e53c`.
The system partition is read-only again and retains roughly 24 MiB free. The
user controls the next system boot. A second targeted module pass over the
already-corrected CAPEX completed with `Unsupported APV software codecs are
already disabled` and `SWCODEC_IDEMPOTENCE_OK`, validating the incremental
`-c` path as well as a clean source-CAPEX path.

### M21s failed-boot verdict and corrected APEX artifacts (2026-10-02 09:11)

The first boot after the recovery-only APEX installation did not merely hang:
the current system pstore ends with `reboot: Restarting system with command
'bpfloader-failed'`. NetBpfLoad reached `netd.o`, but Linux 4.14 rejected both
selected `ingress_stats_4_9_t` and `egress_stats_4_9_t` programs at their exit
instruction with `should have been in (0x0; 0x1)`. Both programs had already
masked the return value with `& 1`, then performed a redundant 32-bit sign
extension. The old verifier lost the scalar range across that extension.

The Tethering module now replaces only those two redundant shift pairs with
`MOV r8,r8`. Runtime semantics remain identical for the only possible values,
zero and one, while the verifier retains the required range. The corrected
`netd.o` SHA-256 is
`012895118a9e32706f0cfab4e04a4ff883e81b8f775ce246c72678b1ca4f8917`.
The rebuilt and installed Tethering APEX SHA-256 is
`ce55c1bfd7073eb50f8db3e96c0ad83353ac6fba4ec1deeef9e00444af9e5679`.

The same pstore exposed an independent packaging error in the first
media.swcodec test: APEXd rejected it because the CAPEX manifest still
contained the source inner APEX root digest. The module now reads the AVB root
digest of the newly signed inner payload and updates CAPEX manifest field 12
before rebuilding/signing the wrapper. Static validation confirmed the outer
and inner digest are both
`1d992b9451b7cf65ad6a70b14f7d9559da2f6981317743ff3150f327531114b1`.
The corrected installed media.swcodec CAPEX SHA-256 is
`9ad2f66dafcc1334199544d5ca9673d76c7872308f5f35d78350e58982baa35b`.

Both corrected files were copied through recovery `/tmp`, verified against
their host hashes, assigned `root:root`, mode `0644` and
`u:object_r:system_file:s0`; `/system_root` was returned to read-only. The
device remains in recovery. The next user-controlled boot must verify that
APEXd activates media.swcodec and that NetBpfLoad loads `netd.o` without a
`bpfloader-failed` reboot.

### M21s second netd verifier correction (2026-10-02 11:25)

The next user-controlled boot confirmed that media.swcodec packaging is now
correct: the former APEXd CAPEX root-digest rejection is absent. Boot still
ended explicitly in `bpfloader-failed`, however, and Linux 4.14 reported the
same two `[0, 1]` return-range failures. Pulling the installed Tethering APEX
proved that the first MOV-only workaround was present, so this was not an APEX
cache or installation problem. The legacy verifier also fails to retain the
range through the preceding `AND 1` operation itself.

BTF line information in `netd.o` identifies the source semantics as
`match &= 1; return match;`. The module now preserves that exactly using
explicit control flow: test bit zero of `match`, return constant zero when it
is clear and constant one when it is set. Both exits consequently present a
literal verifier-known value without disabling either ingress or egress
accounting/filtering. The module migrates the first workaround hash as well as
fresh source input and is idempotent on the final state.

The final `netd.o` SHA-256 is
`38cba2f3cc728c3339c7fdce1dcc5065f25323705b9ede2fe4e386fe8f5c3365`.
The rebuilt Tethering APEX SHA-256 is
`501d59f357675f2fd2cb0f8eba5420781c986f21e13fd26e06b906079fd890a3`.
It was installed directly in recovery and verified byte-for-byte with
`root:root`, mode `0644`, context `u:object_r:system_file:s0`; system was
returned to read-only. The user still controls the next boot.

### M21s bounded-loop verifier backport and clean kernel rebuild (2026-10-02 14:20)

The `netd.o` range correction above removes the last *program-specific*
verifier blocker, but it cannot remove the next one. Decoding the `.android_progs`
sections of every object in the installed Tethering APEX
(`etc/bpf/mainline/{netd,offload,clatd,test,dscpPolicy}.o`, selector
`KVER(4,14,355)`, encoded as `major<<24 | minor<<16 | patch`) selects 23 programs:
8 from `netd.o`, 12 offload programs from `offload.o` and 3 from `clatd.o`.
`test.o` and `dscpPolicy.o` contribute none. Disassembling each selected program
with `llvm-objdump` shows **320 back-edges spread across 14 of those programs**:
9 programs are loop-free, `netd.o`'s `skfilter/egress_xtbpf$4_9` has a single
trivial back-edge (`insn 69 -> 67`, span 3) and the other 13 carry real loops
spanning 166..557 instructions. Of the 14, four offload programs are
`OPTIONAL`; the remaining ten are `REQUIRED` (nine real loops plus the trivial
one). NetBpfLoad loads them as required regardless, so `skfilter/egress_xtbpf`
fails on its own.

A first audit pass also reported eight-byte `PTR_TO_CTX` rejections. That was a
false positive: register `r6` in those programs holds a packet pointer, not the
context. With conservative ctx tracking the remaining classes are clean —
`unknown_helpers = 0` and `ctx_issues = 0` — and **bounded loops are the only
remote blocker still standing**. Linux 4.14 `check_cfg()` rejects every
back-edge unconditionally with `-EINVAL`, before `do_check()` ever runs, so no
userland change can work around it.

The fix is a backport of upstream `2589726d12a1b12eaaa93c7f1ea64287e383c7a5`
("bpf: introduce bounded loops", fetched to `/tmp/opencode/bpfaudit/bounded_loops.patch`).
It is adapted to this tree rather than applied verbatim:

- `bpf_verifier_state` keeps `parent` as the liveness chain and gains a separate
  `branch_parent`; the upstream patch assumes the 5.3 frame layout.
- `check_cfg()` marks which edges may close a loop and `push_insn()` accepts a
  back-edge only when that flag is set **and** `env->allow_ptr_leaks` is true.
  In 4.14 `allow_ptr_leaks` was assigned after `check_cfg()`, which would have
  made the new check dead code, so it is now assigned before it.
- `bpf_verifier_state` gains `branches`; `push_stack()` registers the extra
  outstanding path and `update_branch_counts()` walks the parentage chain from
  `bpf_exit` and from the prune path.
- `is_state_visited()` skips states whose branch count is still non-zero so
  loop iterations do not prune each other, and rejects a program whose state
  repeats exactly against a fully-explored state. `states_maybe_looping()` is
  the cheap `memcmp` pre-check for `states_equal()`, using
  `offsetof(struct bpf_reg_state, live)` because this tree has no BPF frames.
- `BPF_COMPLEXITY_LIMIT_INSNS` rises to 1000000 and `BPF_COMPLEXITY_LIMIT_STACK`
  to 8192 so a legitimate loop can finish while a truly infinite one is still
  rejected (`-EINVAL`, or `-E2BIG` once the budget is spent).
- `bpf_analyzer()` is deliberately left alone: it never sets `allow_ptr_leaks`,
  so that path still rejects loops, matching upstream.

The upstream `prune_point` aux-data flag was **not** ported: 4.14 already marks
prune points with `STATE_LIST_MARK` in `env->explored_states[]`, and
`clean_live_states()` does not exist here, so the flag would have been dead
weight.

The work is captured as three permanent patches in
`target/m21s/patches/kernel9611/patches/`, each verified to apply
with `git apply --check` on a pristine checkout of the pinned commit and to
reproduce the intended tree byte-for-byte:

- `0007-bpf-backport-map-btf-and-android17-helper-abi.patch`
  (SHA-256 `d6a512ee878ac5d2099955681394ec121b0b15d4becfabc31309088df45d3ac0`)
- `0008-bpf-sched-expose-android17-sk-ctx-fields.patch`
  (SHA-256 `b1cfc7ec4159ffd15d2bcae37090d3a1b5d58f0ebe5d473af0ae123747c4258f`)
- `0009-bpf-verifier-accept-bounded-loops.patch`
  (SHA-256 `90af3bdab04c90322bd9871c04c0005f6c1b5229dbf4c6ca189712d673b80b94`)

The temporary bring-up telemetry (`BPF_DIAG` in `__bpf_sys_bpf`, plus
`verifier_diag_last`, the `verbose()` tee and `BPF_VERIFY_RESULT` in the
verifier) is deliberately **excluded** from all three patches; it exists only in
the `out/kernel_tmp-exynos9611` worktree for the next boot test. The
telemetry-free `kernel/bpf/verifier.c` and `kernel/bpf/syscall.c` were compiled
separately to confirm the permanent patch content builds.

Building this kernel exposed a **pre-existing** defect in the incremental output
tree that had been masked: `out/built-in.o` defined **zero** `__crc_*` symbols
while every consumer held a weak undefined reference to them, so `ld.lld`
failed with `relocation R_AARCH64_ABS32 cannot be used against symbol
'__crc_bpf_prog_put'`. Mixing objects built on 2026-10-01 with a `.config`
regenerated on 2026-10-02 02:54 produced that state. The failure was proven
unrelated to the backport by restoring the stock verifier and reproducing the
identical link error. The 02:57 ROM build never exposed it because it found the
`.unica-kernel-cache` manifest valid and reused the cached `Image` from 02:20.
A clean rebuild (`make O=out mrproper` followed by
`build_kernel.py --target=m21 --oneui --ksu --allow-dirty`) completed with
`rc=0`, no errors, and now defines 9558 `__crc_*` symbols.

New artifacts: `Image` SHA-256
`e21524d21f1249e75d4a20e5c44f921758958f268c752c3632f2fa8aec6fa29a`
(replacing `1124e49030a1366b22bd08eea35c481ba87867ccaa07ef63a6ab4503e8b73e98`,
whose copy is kept at `/tmp/opencode/Image.baseline-0210`), kernel release
`4.14.355-openela-SN 1.3.0 Cross`, and
`SN_1.3.0_m21_OneUI_2026-10-02-KSU.zip` (1412 s of build time). `.unica-kernel-cache`
still records the superseded `image_sha256`, so the next ROM build will treat the
cache as outdated and recompile once; that is expected and safe.

No ROM build and no device boot were performed. `kernel/bpf/verifier.c` and
`kernel/bpf/syscall.c` in the worktree keep the telemetry so the next
user-controlled boot can confirm whether all 23 programs now load; the user
still controls that boot.

## M21s Tethering CAPEX: inert BPF map fallback and boot success (2026-10-02 18:51)

With the kernel rebuild in place the remaining blocker was no longer the BPF
*programs*: the installed Tethering CAPEX crashed `system_server` inside
`NetworkStatsServiceInitializer` the moment `BpfNetMaps` enumerated
`/sys/fs/bpf/netd_shared`. `SingleWriterBpfMap.getFirstKey()` calls
`bpfObjGetNextKey()`, which returns `-EINVAL`/`errno=25` on this kernel for the
maps the loader never created, and `BpfNetMaps` turns that into an
`IllegalStateException` during static init.

`platform/exynos990/patches/tethering_legacy/patches/service-connectivity.jar/0003-fallback-to-inert-bpf-maps-on-legacy-bpf.patch`
rewrites all **17** affected call sites — 11 `IBpfMap` getters plus 6
`BpfBoolean` accessors — to return an inert `LegacyNoopBpfMap` /
`LegacyNoopBpfMapBoolean` instead of the real map. Reads yield empty results,
`isEmpty()` returns `true`, writes are discarded, and the booleans report
`false`. The device therefore degrades: BPF-based per-UID traffic accounting
stops, connectivity keeps working. `customize.sh` picks the patch up through
`SERVICE_CONNECTIVITY_BPFFALLBACK_PATCH` when `LEGACY_KERNEL_VERSION=4.14`;
`TETHERING_SKIP_SERVICE_PATCHES=true` must stay off, since it ships the JAR
unpatched.

Building the CAPEX by hand needed four corrections that the ROM's own
`apex_builder` already does for you — worth writing down because each failure
looked like a different bug:

- **AVB algorithm.** Without `--algorithm SHA256_RSA4096`, `avbtool` emits an
  unsigned hashtree descriptor and `apexd` rejects it with `OK_NOT_SIGNED`. The
  footer must also carry `--partition_name ""` to match stock; passing
  `-p system` makes it disagree with the stock slot descriptor.
- **Salt.** Any salt is acceptable because the descriptor is signed. Reusing
  the stock salt `4776430b9f12333e5693d60074b5737df48bee498536a363398710b55ab6154b`
  just removes a variable while bisecting.
- **Payload alignment.** `apexd` reads `apex_payload.img` straight out of the
  zip under dm-verity, so the stored entry must start on a 4096-byte boundary.
  Otherwise the loop mount fails with `I/O error, dev loopNN, sector 0` and
  `EXT4-fs (loopNN): unable to read superblock` — which reads exactly like
  filesystem corruption but is not. Stock puts the payload at offset 8192.
- **Signature vs. alignment ordering.** `zipalign` after `signapk` re-writes
  the zip and detaches the APK Signing Block from the central directory, so
  `PackageManager` throws `No APK Signature Scheme v2 signature` /
  `SignatureNotFoundException: No APK Signing Block before ZIP Central
  Directory`. `signapk -a 4096` does both in one pass and is the only correct
  order; running `zipalign` afterwards silently reintroduces the failure.

The reproducible harness is `/tmp/opencode/build_apex_fixed.sh`, which ends in
an assertion that the payload is `STORED` and 4096-aligned and that the v2
block ends exactly at the central directory. It rebuilds
`/tmp/opencode/m21s-tethering/tethering_final.apex`
(SHA-256 `3798b6f7c41ac03a4a55c3c13a9ca15fd6444c5f5d4c314f916c7b9549376a55`,
30318900 bytes) from the patched JAR. The byte-identical predecessor that was
actually flashed was `tethering_v5.apex`
(`6b3cd1823fbc8914386602283686f0a08d35eeb4720b5f21242cf8bdcbd13da7`), installed
over `/system_root/system/apex/com.google.android.tethering_compressed.apex`
after clearing `/data/apex/{active,images,decompressed}`; the stock original is
backed up at `/data/local/tmp/tethering_backup_501d59f3.apex`
(`501d59f357675f2fd2cb0f8eba5420781c986f21e13fd26e06b906079fd890a3`).

Boot validation, `RX8NB07XAJE` (`boot-diagnostics-2026-10-02_18:51:01-0300`):
`apexd` mounts the module, `bpfloader` loads without complaint, no
`nativeGetNextMapKey failed` or `SingleWriterBpfMap` fatal appears,
`BootAnimation: service.bootanim.exit = 0` fires, and `system_server` dispatches
`android.intent.action.BOOT_COMPLETED`. **The generalised fallback works.**

Two follow-ups that are *not* caused by the patch:

- `vold` logs `getUsedF2fsFileNode -> Cannot Get Used FileNode Number (errno=25
  Inappropriate ioctl for device)` and eventually trips `reboot_on_failure`.
  `E vold` / `Open failed` lines appear in the pre-patch captures too, so this
  is a ROM/kernel f2fs mismatch that was previously masked by the earlier
  `system_server` crash.
- `com.samsung.android.server.wifi.ap.SemWifiApChipInfo.supportThisSoftApFeature(int)`
  fails `dex2oat64` verification (`Verifer rejected class ...`) even with the
  stock CAPEX, so it is pre-existing ROM breakage, not fallout from the patch.

**Read the device serial before trusting any boot result.** A second device
`RX8NB005S3Z` shares the ADB server and was reporting `sys.boot_completed=1`
and a green `vb` while the M21s was still looping. `adb -s RX8NB07XAJE` is
mandatory. Also note the user's own `adb reboot recovery` watchdog (visible as
`adbd service requested 'reboot:recovery'` from `/system/bin/reboot`) fires a
couple of seconds after ADB appears; that is what ended the successful boot
above, not a device fault.

## `semwifi-service.jar` 11AX switch: missing `const/4 v2, 0x0` (2026-10-02)

O port M21s entrava em bootloop com
`java.lang.VerifyError` em `SemWifiService.<init>`. A causa era a rotina
`getSupportedWifiFeature()` reescrita a partir do patch do upstream
`wifi/80211ax/semwifi-service.jar/0001-Disable-MOBILEAP_11AX-support.patch`:
o bloco do donor declara `const/4 v2, 0x0` para inicializar o registro de
retorno, mas a substituição no `customize.sh` do target **descartava esse
`const`**. O feature id `1` (11AX) saltava direto para o label de retorno e
devolvia o valor não inicializado de `v2`, o que o verificador do dex rejeita.

Bytecode quebrado (offsets confirmados via `dexdump`):

```
0000 const/4 v0, #1
0001 if-eq      v4, v0, 001a      <- feature 1 pula a inicializacao
...
0007 const/4 v2, #0               <- inalcancavel pelo feature 1
```

Bytecode correto após o patch:

```
0000 const/4 v2, #0
0001 const/4 v0, #1
0002 if-eq      v4, v0, 001b
0004 const/4 v1, #2
0005 if-eq      v4, v1, 001c
0007 const/4 v1, #3
0008 const/4 v2, #0
```

O patch ficou em `unica/patches/product_feature/customize.sh` (linhas
1488-1518): insere `const/4 v2, 0x0` antes de `const/4 v0, 0x1` e redireciona
**apenas** o feature id `1` de `:cond_2` para `:cond_1`, preservando os
features 2 e 3. Há uma guarda idempotente (`grep -qx 'const/4 v2, 0x0'`).

Validado com o bloco real contra a árvore pristine do donor e um rebuild via
apktool; executar o bloco uma segunda vez não altera o hash do smali.

Aplicado no aparelho sem build completo: o jar foi reconstruído pelo pipeline
do repo (`scripts/apktool.sh`), instalado via TWRP em
`/system_root/system/framework/semwifi-service.jar` e conferido com `sha256sum`
no host e no device. O jar original ficou em
`/sdcard/semwifi-backup-20261002/semwifi-service.jar.orig`. Boot completo em
~190 s, zero `VerifyError`, `SemWifiService` inicia normalmente e não há
`rescueparty_by_bootchecker`.

> `dexdump` 33.0.2 não lê o dex v041 do Android 16
> (`Unrecognized version number ... 0 4 1`). Use o apktool do repo para decodar
> e um `dexdump` compatível para validar offsets.

## M21s: `ro.sf.init.lcd_density` ausente no donor causa densidade 213

O M21s reportava `Physical density: 213` com `ro.sf.lcd_density=420` correto,
resultando em ícones minúsculos. `ro.sf.init.lcd_density` **não existia** e o
SurfaceFlinger logava a cada boot:

```
E SurfaceFlinger: ro.sf.init.lcd_density must be defined as a build property
```

Sem essa prop o SF deriva uma densidade de painel inválida, e o framework
passa a reportar `DisplayInfo.density = 213` (confirmação: `dumpsys display`
mostra `density 213 (403.411 x 404.326) dpi`, e `mDensityMapping= null`, ou
seja a densidade **não** vinha do `DensityMapping` nem do
`default_television.xml`).

A origem é o firmware do próprio aparelho: `TARGET_FIRMWARE="SM-F415F/ZTO/..."`
em `target/m21s/config.sh:15`. O build extrai `vendor/build.prop` desse
firmware, que traz **apenas** `ro.sf.lcd_density=420` (linha 147). Os doadores
S926B e G986B trazem as duas (`450`/`600` em ambos) — coerente com o registro
de 2026-09-17 nas linhas 919-931 deste arquivo.

> O M21s **é** o Galaxy F41: o número de modelo Samsung é `SM-F415F` e o
> codinome de comunidade é `f41`. `SM-F415F` não é um device diferente do
> M21s, e o `F415F` é o **target**, não um donor. O donor é o `SM-S926B`
> (S24+), de onde vem o framework Android 17. Não misturar os dois.

Correção em `BACKPORT_SF_PROPS()` (`unica/patches/legacy/customize.sh`):
espelha a densidade do próprio donor quando a prop falta, e não toca nos
doadores que já a definem.

```bash
PROP="ro.sf.init.lcd_density"
if [ ! "$(GET_PROP "vendor" "$PROP")" ]; then
    VALUE="$(GET_PROP "vendor" "ro.sf.lcd_density")"
    [ "$VALUE" ] && EVAL "sed -i \"/ro.sf.lcd_density=\$VALUE/a $PROP=\$VALUE\" \"$FILE\""
fi
```

Validado contra os três doadores de `out/fw/`: F415F recebe
`ro.sf.init.lcd_density=420` logo após a linha 147; S926B e G986B ficam
intactos (já possuem `600`). Idempotente nos três.

Verificado no aparelho: `Physical density: 420` sem nenhum override
`wm density`, o erro do SF não aparece mais e o `dumpsys display` reporta
`density 420`.

### `/vendor` cheio no M21s

`/vendor` está em 100% (716M usados, ~2.1M livres, inode 97%). Como
consequência, `cp` e `sed` falham com `ENOSPC` **e deixam o arquivo de destino
com 0 bytes**, sem erro visível para quem não checar o tamanho. Isso já
destruiu `/vendor/build.prop` uma vez durante o diagnóstico; o arquivo foi
recuperado de `/data/media/m21s-boot-compat-backup-20260930/vendor/build.prop`
(cópia preservada em `/tmp/opencode/recovery/vendor-build.prop.bak`, 6305 bytes
contra 6294 do arquivo danificado — pode haver divergência de 9 bytes em
relação ao original).

Ao escrever em `/vendor`, **sempre** verifique `wc -c` no destino e garanta
espaço: foi necessário mover temporariamente dois modelos de IA da Samsung
(`movinet_t0.tflite`, `SRIBMQA_aiNOISEDETECT_V100_FP32.tflite`) para
`/data/local/tmp` para liberar ~20MB. Ambos foram devolvidos. Um build não
passa por isso: a partição é gravada como imagem inteira, não arquivo a
arquivo.

## SetupWizard ANR: deadlock no `mediaserver` por `media.codeclist.generator`

O SetupWizard travava em `IntroLanguageSpinnerActivity` com
`Input dispatching timed out ... Waited 10000ms for FocusEvent(hasFocus=false)`,
matando e reiniciando o processo a cada 2-5 min. **A densidade não era a
causa** — `wm density 420` antes só fez o sintoma parecer resolvido; os ícones
pequenos e o ANR são problemas independentes.

A main thread fica presa num binder call síncrono:

```
MediaPlayer.release()
  -> BpMediaPlayer::disconnect()      <- binder TRANSACTION SINCRONA
    -> IPCThreadState::transact()      -> ioctl()
```

O `MediaPlayer$EventHandler` segura a main thread enquanto espera um
`mediaserver` que não responde. O deadlock está dentro do próprio
`mediaserver` (ANR trace de 1.9MB em `/data/anr/`, extraído via TWRP):

```
mediaserver tid 5418:
  ResourceManagerService::buildFrameRateInfoTable()
    -> BpMediaCodecListGenerator::generateCodecList()   <- espera o mediaserver
mediaserver tid 5359 (main):
  MediaCodecList::InstanceCache::getLocalInstance()
    -> mutex::lock()                                   <- segura o lock
```

O tid 5359 segura o mutex de `MediaCodecList::InstanceCache` e fica preso
**dentro dele**, sem conseguir atender a thread 5418, que segura o pedido por
trás. As 12 threads `binder:5359_*` empilham no mesmo mutex — o `mediaserver`
inteiro fica inutilizável, então **qualquer** app que use mídia trava.

Agravante: cada reinício do SetupWizard deixa o `AudioOutput` aberto
(4+ players órfãos visíveis em `dumpsys media.player`), o que derruba o
`load average` para ~17, provoca a cascata de `lmkd` (~30 processos mortos com
`cch+5`..`cch+85 CEM`) e faz o `system_server` chegar a 136% de CPU. O ANR e o
load são **consequência** do vazamento, não a causa.

Gatilho: `/system/bin/mediacodeclist_generator`, trazido pelo stack Android 17
do donor S24+. O serviço é `disabled` no
`/system/etc/init/media.codeclist.generator.rc`, mas em runtime aparecia como
`init.svc.media.codeclist.generator=running` e o processo ficava vivo por
10+ min sem terminar. **O que o habilita não foi identificado.**

O repositório não tem nenhum tratamento de `resourcemanager`, `codeclist` ou
`media_codecs` (nada em `unica/mods/`, `target/m21s/config.sh` ou nos scripts),
o que explica esse deadlock nunca ter aparecido antes. O contexto provável é o
Android 17 do donor esperando codecs que o vendor Android 12 do M21s não
entrega.

**Testado no aparelho**: renomear `/system/bin/mediacodeclist_generator` para
`.disabled` (via TWRP, depois remontando `ro`). Resultado: o processo não
sobe, **zero ANR** desde o boot, zero `AudioOutput` órfãos e o SetupWizard
avançou até `WifiSetupWizardActivity`. O load inicial de ~43 é o boot normal
do Android 17 num device de 3.6GB e cai sozinho.

O estado validado foi incorporado posteriormente ao módulo específico
`target/m21s/patches/fm_framework_compat`: somente o binário
`mediacodeclist_generator` é removido. O `mediaserver`, o Codec2, o arquivo
`.rc` e a lista regular de codecs são preservados. Consulte a seção
“M21s: correções do pós-boot de 2026-10-02” abaixo para a implementação e as
validações atuais.

### Sintoma residual: a tela apaga durante o wizard

`settings get system screen_off_timeout` retorna `30000` (30 s) e
`stay_on_while_plugged_in=0`, então a tela apaga no meio da animação de
entrada e só volta ao acorde. Como mitigação no aparelho, foi aplicado
`screen_off_timeout=1800000` e `stay_on_while_plugged_in=7` — **não é
persistente após reboot** e ainda não foi vertido no repositório. Também não
está isolado se o reinício do `IntroLanguageSpinnerActivity` observado depois
(2 inícios de processo, 0 ANR, sem `Killing`) tem a mesma raiz ou é
independente.

## M21s: estado do device e pendências ao encerrar a sessão

- Fix do wifi e da densidade **aplicados e verificados no aparelho**, ambos
  validados por harness contra os doadores reais e idempotentes.
- Nenhum ZIP final foi gerado: o build completo
  `./scripts/make_rom.sh -c` foi interrompido por timeout do shell durante
  `create_work_dir.sh`, deixando `out/target/m21s/apktool` removido e
  `out/target/m21s/work_dir` parcial. O build deve recriar o work_dir do zero.
- O ZIP `out/UN1CA_UNOFFICIAL_2.0.1_20261002_m21s-sign.zip` está **quebrado**;
  não usar.
- Alterações pendentes sem commit: o bloco do wifi em
  `unica/patches/product_feature/customize.sh`, a prop de densidade em
  `unica/patches/legacy/customize.sh` e este bloco do `INSTRUCTIONS.md`.
  `unica/patches/legacy/customize.sh` **já continha** adaptações Android 17
  para M21s (câmera, Face HIDL, SehLights, vold, netd) — foram preservadas.
- `ro.sf.init.lcd_density` foi escrito à mão no aparelho para validação; o
  repo garante o mesmo resultado no próximo build.

## M21s: correções do pós-boot de 2026-10-02

O log analisado é
`out/target/m21s/boot-diagnostics-2026-10-02_21:34:51-0300/logcat.txt`.
Ele permitiu separar quatro defeitos independentes que pareciam um único
soft-reboot do framework.

### Biometria traseira anunciada simultaneamente como sensor de tela

O cadastro chegava a 100%, mas `FingerprintEnrollActivity` travava por 10 s
ao perder foco e acabava em ANR. O próprio app registrou a contradição:

```
mIsRearSensor=true,mIsSideSensor=false,mIsDisplaySensor=true
```

O donor anunciava
`SEC_FLOATING_FEATURE_BIOAUTH_CONFIG_FINGERPRINT_FEATURES=ultrasonic_display_phone`,
enquanto o `SM-F415F` stock usa `capacitive_rear_phone`. O HAL e o sensor não
eram a causa: enrollment, `cancelEnrollment()` e `postEnroll()` chegavam ao
HAL. `target/m21s/sff.sh` agora força o valor stock do F415F.

O mesmo arquivo também restaura o perfil AOD real do aparelho:

- `FRAMEWORK_CONFIG_AOD_ITEM=aodversion=7`;
- `LCD_CONFIG_AOD_REFRESH_RATE=0`;
- remove `AOD_FULLSCREEN`, `AOD_BRIGHTNESS_ANIMATION` e a política de
  subdisplay herdadas do S24+.

O driver e o HAL de toque **aceitam** `aod_enable,1` e `aot_enable,1` com
`ret=0`, e expõem `support_feature=0x101`. Os erros `setTspEnable(...)
ret=-1` vêm da interface nova `/sys/class/sec/tsp/enabled`, ausente no driver
legado, mas não são o comando de duplo toque. O DTBO stock foi extraído e
confirma `melfas,support_lpm`, firmware `mss100_m31.fw` e os GPIOs esperados;
portanto, não foi aplicada uma alteração especulativa no kernel/DTB.

### Configurações/Visor: contrato JNI de FM incompleto

Ao indexar `FMSettingSearchProvider`, `libfmradio_jni.so` do F415F registrava
`FMPlayerNative.checkBaseFreq()Z`, ausente no framework Android 17. O ART
lançava `NoSuchMethodError` durante `RegisterNatives` e abortava o
`system_server`, produzindo o soft-reboot ao abrir Visor.

A comparação completa entre `FMPlayerNative` do donor e o framework stock
F415F mostrou que **essa é a única função do target ausente no donor**. O
patch específico fica em:

`target/m21s/patches/fm_framework_compat/patches/system/framework/framework.jar/0001-Restore-F415F-FM-checkBaseFreq-JNI-contract.patch`

Ele adiciona somente a declaração native e preserva a implementação da
biblioteca stock. O patch foi validado com `git apply --check` contra o smali
real decodificado.

Havia ainda um crash separado do processo Configurações: o índice UN1CA
registrava `AboutArtisanROMFragment`, embora
`@xml/artisanrom_about_settings` já tivesse sido removido. As duas
registrations obsoletas foram retiradas de
`UnicaSearchIndexableResources.smali`; os demais patches smali funcionais do
Settings foram mantidos.

### Conta e SetupWizard roteados para rede SATELLITE inexistente

Google e Samsung Account estavam instalados e seus authenticators eram
encontrados. A falha de login vinha da rede: o Android 17 detectava cinco
apps com metadata `SATELLITE_DATA_OPTIMIZED`, incluindo Samsung Account e
componentes do SetupWizard, e publicava para esses UIDs uma política de rede
satélite:

```
AppOptInDefaultNetworkController: Add SatelliteDataOptInUids ...
ConnectivityService: ... Transports: SATELLITE ... network{52}
NetworkAgentInfo ... IDLE ... LinkAddresses: [] DnsAddresses: []
```

O F415F não possui serviço satélite (`SatelliteModemInterface` também informa
que o pacote é indefinido). Assim, os apps eram retirados do Wi-Fi validado e
passavam a falhar com `UnknownHostException`; o SetupWizard registrava
`isNetworkConnectionValidated=false`.

O patch específico
`target/m21s/patches/tethering_legacy/patches/service-connectivity.jar/0004-disable-satellite-app-routing-on-F415F.patch`
impede apenas a publicação dessas políticas no M21s. Wi-Fi, dados móveis e o
restante do ConnectivityService permanecem intactos. O script compartilhado
do Tethering ganhou um hook opcional; outros devices não recebem o patch. O
smali modificado foi reconstruído com Apktool com sucesso.

### SetupWizard e `mediacodeclist_generator`

O resultado já validado no aparelho agora foi vertido no módulo específico
do M21s: `fm_framework_compat` remove
`/system/bin/mediacodeclist_generator`. Somente esse gerador lazy incompatível
é removido; `mediaserver`, Codec2 e a lista regular de codecs permanecem.
Isso reproduz o estado que eliminou o deadlock, os `AudioOutput` órfãos e os
ANRs do assistente.

O `.rc` ainda existe e pode registrar mensagens de tentativa de início do
serviço ausente. Isso é preferível ao deadlock comprovado e não deve ser
confundido com o antigo travamento. Um stub AIDL só deve substituir essa
solução depois de ser implementado e validado, nunca apenas para esconder o
log.

Validações feitas nesta etapa: sintaxe dos scripts com `bash -n`, patches com
`git apply --check`, `git diff --check`, reconstrução isolada do
`service-connectivity.jar`, montagem isolada dos smali modificados e comparação
do contrato FM com o jar stock. Uma ROM completa não foi iniciada; o próximo
teste exige build/flash do usuário.

### Wallpaper de vídeo nulo não era falha do codec

O mesmo log mostra que o vídeo da tela de bloqueio falhava antes de criar um
decoder. O catálogo mesclado continha a lista `phone` estática do F415F, mas
mantinha a tabela `types` do S24+, que anunciava o wallpaper de bloqueio
(`which=2`) como vídeo (`type=8`). O resultado em runtime era explícito:

```
WallpaperResourcesInfo: getDefaultWallpaperType: which = 6 , type = 8
SemWallpaperManagerService: ... videoFileName = null
ImageWallpaper[VideoResource]: ... com.samsung.android.wallpaper.res/null
Resources$NotFoundException: Resource ID #0x0
```

`unica/mods/wallpaper/customize.sh` agora importa também a tabela `types` do
target; quando o firmware antigo não a possui, grava uma lista vazia e deixa
os tipos estáticos declarados nas próprias entradas `phone`. Uma validação
com `jq` interrompe a build se algum tipo default explícito não possuir uma
entrada default equivalente e um `filename` real. Isso corrige a origem sem
alterar OMX, Codec2 ou o player do SystemUI.

### Correção estrutural dos patches do `service-connectivity.jar`

Durante a primeira build limpa, o patch compartilhado
`0003-fallback-to-inert-bpf-maps-on-legacy-bpf.patch` falhou antes da aplicação
com `patch fragment without header`. O arquivo tinha um cabeçalho `diff --git`
duplicado e não possuía os marcadores `---`/`+++` para `BpfNetMaps.smali` e
`BpfBoolean.smali`. Os cabeçalhos foram restaurados sem modificar a lógica do
fallback BPF.

O patch M21s `0004-disable-satellite-app-routing-on-F415F.patch` também foi
atualizado para aceitar o smali real da build, que não contém a diretiva de
debug `.line 269`. Os patches 0003 e 0004 foram aplicados em sequência ao JAR
decodificado que havia falhado; o `service-connectivity.jar` completo foi
reconstruído com Apktool e sua estrutura ZIP foi validada sem erros.

### Estado parcial do APV no `media.swcodec`

Uma tentativa incremental abortou em `Inconsistent media.swcodec APV state`.
O módulo exigia simultaneamente os dois registros XML e os dois arquivos
`libcodec2_soft_apv*.so`; uma tentativa interrompida podia remover somente uma
parte deles e cair nesse erro, apesar de o estado ser recuperável. O módulo
`codec2_compat` agora trata qualquer combinação parcial como APV ativo,
remove os registros e os arquivos existentes e só prossegue quando a
validação final confirma que nenhum deles restou. Isso torna a correção
idempotente entre builds incrementais e não altera os codecs de vídeo legados.
As verificações do XML usam `grep`, disponível no ambiente de build; não
dependem do utilitário opcional `rg`.

### Kernel M21s: patch de loops limitados do BPF (2026-10-02)

O patch
`target/m21s/patches/kernel9611/patches/0009-bpf-verifier-accept-bounded-loops.patch`
continua sendo obrigatório para os programas BPF do Android 17. Ele adiciona
o controle de ramificações do verifier, a detecção de loops infinitos, os
contadores de instruções/jumps e os limites de exploração necessários para
aceitar loops limitados.

Uma build incremental anterior já continha todos esses trechos no checkout
montado do kernel, mas também havia acrescentado o diagnóstico de
`netbpfload` dentro de `verbose()`. Por isso `git apply --reverse --check`
não conseguia reconhecer o 0009 como aplicado: o contexto do hunk de
logging havia mudado, embora a implementação estivesse completa.

`target/m21s/patches/kernel9611/customize.sh` agora faz uma
verificação semântica somente para o 0009 quando o reverse-check literal não
é possível. Ela exige simultaneamente os campos `branches` e
`branch_parent`, os quatro contadores no ambiente, os limites 1.000.000/8192,
`push_insn(..., bool loop_ok)`, `states_maybe_looping()`,
`update_branch_counts()`, a contagem de exits e a autorização do CFG por
`CAP_SYS_ADMIN`. Uma aplicação parcial ainda aborta; o patch nunca é
silenciado. Em um checkout limpo, o patch continua passando por
`git apply --check` normalmente.

### M21s: módulo de recorte de IA, eSIM, Music Share e vibração (2026-10-02)

Foi criado o módulo específico `unica/patches/zzzz_m21s_ai_minimal`. Ele só
é executado quando `TARGET_CODENAME=m21s`, depois do debloat e dos módulos de
SAIV, para que o estado final seja determinístico.

O módulo mantém Bixby, Bixby Interpreter, Now Brief (`Securitybrief`),
Assistente de transcrição (`LiveTranscribe`), Assistente de chamada e os
componentes de sugestões/notas já presentes no target. Como o debloat comum
removia Bixby, o módulo restaura `Bixby` e `BixbyWakeup` com suas permissões,
assinatura, preferred-apps e entradas sysconfig. Os APKs são importados sem
`oat`/`vdex` do S24+, evitando misturar artefatos ART de outra base.

Para reduzir o sistema, são removidos os add-ons e modelos de IA da Galeria:
`BixbyVisionFramework3.5`, `PhotoEditor_AIFull`, `AiWallpaper`, `MhsAiService`,
`AppSearchAiSealConfig` e os diretórios de lasso, inpainting,
style/object/reflection/shadow removal, image-tagger, pet e human-segmentation.
`SamsungGallery2018`, OCR/textrecognition, Smart Scan, MIDAS, `AICore` e
`SamsungAiCore` são preservados: os dois últimos são dependências reais do
Bixby/Interpreter, da transcrição e do Now Brief.

O recorte não pode apagar os gates de software do Now Brief. O arquivo
`target/m21s/sff.sh` e o módulo devem manter `COMMON_CONFIG_AI_VERSION=20263`,
`COMMON_SUPPORT_AI_AGENT=TRUE`,
`FRAMEWORK_SUPPORT_PERSONALIZED_DATA_CORE=TRUE` e
`FRAMEWORK_SUPPORT_SMART_SUGGESTIONS_WIDGET=TRUE`. O terceiro é o contrato do
Personal Data Intelligence, que o próprio texto de ajuda do target exige para
o Now Brief; os demais habilitam o agente e a entrada/widget. As flags de
Galeria/GenAI continuam removidas separadamente. O `KmxService` permanece
fora desta correção: ele fornece os dados de segurança do cartão Security
Brief e exige uma adaptação própria ao M21s, mas sua ausência não deve ocultar
o Now Brief inteiro.

O eSIM é removido completamente no M21s: `EsimClient`, `EuiccGoogle`,
`EsimKeyString`, `EuiccService`, permissões, defaults, autoinstalls e
sysconfig correspondentes, além das flags embedded-SIM do
`floating_feature.xml`.

Music Share/Continuity recebe `StorageShare.apk` do donor apenas quando
ausente e a permissão de armazenamento compartilhado correspondente. Os
demais APKs MCF/AllShare existentes não são substituídos. As flags finais são
`MCF_SUPPORT_CONTINUITY=15`, `MCF_SUPPORT_FRAMEWORK=TRUE` e
`ALLSHARE_CONFIG_VERSION=DMC_ONLY`.

Foi adicionada a flag de saúde da bateria
`BATTERY_SUPPORT_BSOH_GALAXYDIAGNOSTICS=TRUE`. Recursos físicos que o M21s
não possui (carregamento sem fio, Wireless TX e pass-through) permanecem
desativados, mesmo que o S24+ os anuncie.

O `services.jar` do target já contém `VibrationSession`, e a árvore já possui
`libhapticgenerator`/`audio_effects.xml`; o módulo preserva esse caminho e
adiciona `vendor/etc/audio_effects_haptic.xml` apenas se estiver ausente. Não
ativa a vibração virtual do S24+ nem substitui o HAL/vibrator do M21s.

Validações: `bash -n` do novo `customize.sh`, conferência dos APK/modelos e
das dependências no `work_dir` e comparação das listas de floating features.
A build/flash completo ainda precisa ser feito pelo usuário.

### M21s: display, câmera e diagnóstico do Spotify (2026-10-03)

O log
`out/target/m21s/boot-diagnostics-2026-10-03_00:41:25-0300/logcat.txt`
registrou a queda da câmera em `CamSettingBackgroundHandlerThread` com
`IllegalArgumentException: getResolution : argument is invalid - -1`. O valor
`SEC_FLOATING_FEATURE_CAMERA_CONFIG_HIGH_RESOLUTION_MAX_CAPTURE` do firmware
F415 era `-1`, mas a câmera importada do S24+ rejeita esse sentinela. O target
e o módulo final `target/m21s/mods/m21s_display_camera` agora publicam `0`, que
representa ausência de perfil extra sem invalidar a inicialização normal.

O mesmo módulo remove somente as linhas de UI de `screen_resolution`,
`extra_brightness` e `outdoor_mode` dos dois XMLs de display do SecSettings,
desativa a flag de resolução dinâmica, fixa o brilho automático em `3`,
mantém `SEC_FLOATING_FEATURE_SETTINGS_SUPPORT_AUTO_BRIGTNESS=TRUE`, restringe
o HFR a 60 Hz e remove a flag de brilho extra. O módulo `unica/mods/outdoor`
também é ignorado no M21s; a remoção é repetida no módulo final para proteger
builds incrementais com APK decodificado em cache.

As flags estáticas de hardware agora também ficam declaradas em
`target/m21s/sff.sh`: resolução dinâmica e brilho extra são removidos, o
brilho automático é `3`/`TRUE`, e o HFR permanece limitado a 60 Hz. O módulo
`m21s_display_camera` mantém as mesmas chamadas como camada final
idempotente, porque o donor ESSI e módulos comuns podem mesclar novamente o
`floating_feature.xml` depois do baseline do target em builds incrementais.
Assim, o `sff.sh` é a fonte do perfil do aparelho e o módulo só garante a
precedência do valor final; as alterações de UI/smali continuam exclusivamente
no módulo. O mesmo baseline agora declara as remoções estáticas de Gallery/
GenAI e eSIM, as flags de Music Share/Continuity e o diagnóstico de bateria.
`zzzz_m21s_ai_minimal` continua repetindo essas operações depois da limpeza de
APKs/modelos, pois a remoção de arquivos e a importação de `StorageShare` não
podem ser expressas no SFF.

O layout foi alinhado ao `target/y2s/sff.sh` do S20+ apenas nos contratos
comuns confirmados (`BIXBY_CONFIG_BARGEIN_FUNCTION` e
`FRAMEWORK_CONFIG_NAVIGATION_BAR_THEME`). Não foram copiados valores de
áudio, câmera, FCC, SIOP, bateria PD, punch-hole ou painel 120 Hz: eles são
específicos do Exynos 990/S20+ e poderiam reintroduzir incompatibilidades no
Exynos 9611/F415F.

O SFF do M21s agora contém seções completas para bateria, áudio, identidade do
device, câmera e UI geral, usando os valores extraídos do
`out/fw/SM-F415F_ZTO/system/system/etc/floating_feature.xml`. O S20+ foi usado
somente como modelo de organização e como fonte de nomes de chaves comuns.
Foram preservados o SoundAlive, topologia de sensores, bibliotecas de câmera,
FCC, tensão nominal, SIOP e perfil de 60 Hz do F415F. A opção de AI High
Resolution permanece desativada e o sentinel de captura continua `0`, pois o
APK de câmera One UI 9 rejeitava `-1` no M21s.

O Spotify não apresentou crash nesse log: o processo `28590` abriu
`com.spotify.music/.MainActivity`, desenhou o primeiro frame e permaneceu em
execução. Os erros de `/dev/null/Android/data/...` e
`Volume external_primary not found` coincidem com
`Reporting emulated;0 unmounted due to system locked`; são o comportamento do
armazenamento CE quando o aparelho está bloqueado, não uma falha do APK. Não
foi adicionado um patch que contorne a criptografia ou force um volume falso;
se o Spotify continuar sem conteúdo depois de desbloquear, deve ser capturado
um log específico nessa condição.

O mesmo boot revelou dois ajustes de compatibilidade adicionais. O módulo
`target/m21s/patches/fm_framework_compat` já removia o binário
incompatível `mediacodeclist_generator`, mas deixava
`system/etc/init/media.codeclist.generator.rc`; isso fazia o servicemanager
repetir `Cannot find /system/bin/mediacodeclist_generator`. O módulo agora
remove a declaração init junto com o binário.

Também houve um crash isolado de `com.samsung.android.rampart`:
`NoClassDefFoundError: LF1/a`. O reset de políticas do
`unica/patches/autoblocker_compat` só é injetado quando o helper `r1/a` existe
na variante decodificada. No Rampart do M21s ele não existe; nesse caso as
rotinas de desbloqueio/receivers continuam aplicadas, mas o reset opcional é
ignorado para não inserir referências smali inválidas.

Por fim, o framework estava aplicando `AutomaticBrightnessStrategy` e usando
o sensor, mas o controller do Settings informava `LastAvailableStatus false`.
O módulo M21s altera somente o fallback `unsupported` de
`SecAutoBrightnessPreferenceController`; restrições de administrador,
privacidade do sensor e display secundário continuam preservadas. Não cria
sensor nem altera o HAL: a opção pode ser exibida e o caminho nativo continua
responsável pelo ajuste real.

### M21s: correção de gravação de boot/DTBO no instalador (2026-10-03)

O ZIP do M21s continha o `dtbo.img` correto — a imagem gerada traz
`sensorhub/shub_ramen_m21.fw` — mas o `updater-script` escrevia as imagens em
`/dtbo` e `/boot`. Esses são aliases de montagem do recovery, não caminhos de
bloco garantidos para `package_extract_file()`. Na prática, o aparelho podia
continuar executando o DTBO antigo, que requisita
`sensorhub/shub_ramen_m31.fw`; o kernel então registrava `request_firmware`
com `-2` e o sensorhub ficava indisponível.

`platform/exynos9611/config.sh` agora define
`TARGET_OS_BOOT_DEVICE_PATH=/dev/block/by-name`, fazendo o ZIP gravar
diretamente `/dev/block/by-name/dtbo` e `/dev/block/by-name/boot`. A correção
exige gerar e instalar um novo ZIP; ela não consegue substituir uma partição
de boot de um aparelho já iniciado sem recovery/root.

Para isolar essa cadeia sem gerar uma ROM inteira, foi criado
`platform/exynos9611/installer/dtbo_sensorhub_m21s`. Seu `build.sh` gera
`out/target/m21s/m21s-dtbo-sensorhub-m21-test.zip`, contendo exclusivamente
o DTBO. O instalador recusa referências a `shub_ramen_m31.fw`, escreve no
bloco físico `/dev/block/by-name/dtbo` e compara SHA-256 do intervalo escrito.
Em 2026-10-03, ele foi instalado pelo TWRP 3.7.1_12-Galaxieo e a leitura
direta posterior confirmou o hash
`d866d11cc485cbc9438355ab464f02df6445e503c909d853ea9d31bccec4cefd`
e a referência exclusiva a `sensorhub/shub_ramen_m21.fw`.

O boot posterior mostrou que esse primeiro teste, embora gravado
corretamente, era somente o DTBO F41 com o nome da firmware alterado. O
context hub passou a registrar sensores parciais, mas falhou em `poweron`
com timeout `-110`; portanto, a troca de string não é uma solução válida. A
árvore do kernel já produz o overlay integral
`exynos9611-m21_swa_open_00.dtbo`, que contém as propriedades, calibração e
referência `shub_ramen_m21.fw` do M21. Porém ele **não é uma partição DTBO
Samsung completa**: começa com a assinatura FDT `d00dfeed`, tem 106800 bytes,
enquanto o DTBO stock tem a assinatura da tabela Samsung `d7b7ab1e` e 8 MiB.
Em 2026-10-03 ele foi gravado por engano e o bootloader entrou no Download
Mode com `dt table header check fail` / `DT LOAD Fail`. Não o instale
novamente. O gerador do ZIP agora recusa qualquer imagem sem a assinatura de
tabela Samsung. A recuperação preparada é
`out/target/m21s/odin_restore/M21s-F415F_stock-dtbo-restore.tar.md5`, que
contém somente o DTBO stock F415F, SHA-256
`dc8f44391c0defbd6dcae66f9e32cf8b13e759b88d573d9d60eb49e44ebd7fc8`.
Uma solução válida para sensores deve inserir/mesclar o overlay M21 na tabela
DTBO stock, preservando o cabeçalho e as entradas de painel, bateria e
touchscreen; não pode substituir a partição pelo `.dtbo` bruto do kernel.

O `mkdtimg` foi usado para criar uma tabela Samsung de uma única entrada com o
overlay `exynos9611-m21_swa_open_00.dtbo`: o cabeçalho, a entrada e o payload
foram validados por `mkdtimg dump`, o container foi preenchido até 8 MiB e a
única referência de firmware é `sensorhub/shub_ramen_m21.fw`. O artefato de
teste é `out/target/m21s/m21s-dtbo-m21-table-test.zip` (SHA-256 do DTBO:
`a3de2b18130f16cbfc62528aaebe3cd97575d955aa2bcf77499e47940b206fb2`).
Isso elimina especificamente o erro de cabeçalho do bootloader, mas ainda é
um teste de compatibilidade de hardware: só o boot e o registro dos sensores
confirmarão que o overlay M21 é adequado ao aparelho F41.

Uma segunda inspeção do DTBO stock revelou a diferença decisiva: a entrada
Samsung usa `custom[1]=0xff`, enquanto a primeira tabela criada manualmente
usou incorretamente `custom[0]=0xff`. O bootloader voltou a mostrar `DT LOAD
Fail`; portanto, esse ZIP de tabela M21 não deve ser reutilizado. Mais
importante, o overlay stock identifica a placa como `F41 SWA OPEN REV00` e
solicita legitimamente `sensorhub/shub_ramen_m31.fw`. A fonte do kernel possui
essa firmware (`ac7257c33b75551a29a037cb6b87d6907e47bcfe457a7d852cafdcefa2cf5093`),
mas o build M21 só entregava a M21 à vendor. A correção permanente mantém o
DTBO F41 sem alterações e entrega a firmware M31 em
`vendor/firmware/sensorhub/shub_ramen_m31.fw`; o kernel continua com o
defconfig M21. Para validar sem nova ROM, o ZIP TWRP
`out/target/m21s/m21s-sensorhub-m31-firmware-test.zip` modifica apenas esse
arquivo de firmware na vendor ext4 e confere seu SHA-256 após gravar.

### M21s: armazenamento interno exige FBE (2026-10-03)

O diagnóstico do aparelho mostrou a causa direta do volume interno ausente:
o usuário 0 alcançava `CE unlocked`, mas `System unlocked users` permanecia
vazio e o `StorageManagerService` repetia `emulated;0 unmounted due to system
locked`. A comparação com o firmware F415F revelou que
`storage_compat` e o multidisabler haviam removido
`fileencryption=ice` da entrada `/data`. O init também reportava
`FBE was not enabled`.

Android 17 não trata esse caso como um armazenamento sem criptografia válido
para o fluxo completo de usuário: o `vold` prepara os diretórios CE, mas o
framework não conclui `SYSTEM_USER_UNLOCK_MSG`, portanto publica a memória
primária como `/dev/null`. O módulo e o instalador M21s passam a preservar
`fileencryption=ice` e removem a regra incompatível `encryption=None`.
Uma migração a partir de uma instalação formatada pelo multidisabler antigo
exige formatar `/data` antes do primeiro boot para criar metadados FBE limpos.

### M21s: estado consolidado de DTBO/sensorhub e recuperação (2026-10-03)

O aparelho físico inicia com o DTBO stock F415F restaurado, mas os sensores
permanecem indisponíveis porque o kernel registra repetidamente:

```
Direct firmware load for sensorhub/shub_ramen_m31.fw failed with error -2
ueventd: firmware: could not find firmware for sensorhub/shub_ramen_m31.fw
SensorHubManager: sendSensorHubData failed, no sensorhub
```

Isto é uma dependência ausente de firmware, não uma falha do HAL de sensores
nem de `sysinput`. O DTBO stock deve continuar inalterado: além da definição
do sensorhub, ele descreve a placa F41, painel, bateria e touchscreen.

O teste que gravou o overlay bruto M21 falhou no bootloader por não possuir a
tabela Samsung. O segundo teste, encapsulado com `mkdtimg`, também não deve
ser reutilizado: embora tenha a magic DT-table correta, usou o campo de seleção
errado (`custom[0]` em vez de `custom[1]=0xff`) e novamente resultou em
`dt table header check fail` / `DT LOAD Fail`. Não gravar nenhum dos arquivos
`m21s-dtbo-*-test.zip` novamente.

O único artefato de recuperação para Download Mode é
`out/target/m21s/odin_restore/M21s-F415F_stock-dtbo-restore.tar.md5`, usado
no campo AP do Odin. Ele restaura somente o `dtbo.img` F415F de 8 MiB.

A correção persistente já foi aplicada em
`target/m21s/patches/kernel9611/customize.sh`: o kernel permanece
com o defconfig M21, porém o módulo deixa o DTBO intacto e copia a firmware
existente na source `firmware/sensorhub/shub_ramen_m31.fw` para
`vendor/firmware/sensorhub/shub_ramen_m31.fw`, com contexto `vendor_fw_file`.
O arquivo de origem foi validado com SHA-256
`ac7257c33b75551a29a037cb6b87d6907e47bcfe457a7d852cafdcefa2cf5093`.

Também foi criado o ZIP de diagnóstico
`out/target/m21s/m21s-sensorhub-m31-firmware-test.zip`, que altera somente
esse arquivo da vendor e valida seu hash. Ele exige TWRP com `/vendor`
ext4 gravável. No estado atual, o TWRP não inicia e o aparelho só pode ser
manuseado pelo Odin; logo esse ZIP **não foi aplicado** e não deve ser indicado
como solução imediata. Para testar sem TWRP será necessário gerar um AP Odin
válido que atualize a imagem `super`/vendor, ou gerar e instalar a ROM completa
com a correção persistente.
### M21s 4 GB memory and background-process policy (2026-10-05)

The M21s has about 3.66 GiB usable RAM.  Android 17 was keeping an excessive
cache for this target: `ro.slmk.cached_max=256` became
`CUR_MAX_CACHED_PROCESSES=286` at runtime after Samsung's `BGSlotManager`
added its empty-process allowance.  The consequence was that optional Samsung
and Google services remained resident long after they were useful, leaving
less headroom for the foreground application.

`target/m21s/patches/memory_4gb` now uses
`ro.slmk.cached_max=128`.  Its effective ActivityManager budget is about 158
processes, which is large enough for normal task switching and substantially
smaller than the prior 286.  The module retains the target ART policy
(`heapgrowthlimit=192m`, `heapsize=512m`, profile-guided JIT) and explicitly
keeps the USAP pool disabled.  It also preserves the `10%` RAM Plus/zram swap
watermarks, avoiding premature LMK kills while swap is mostly free.

Do not remove Samsung Smart Suggestions, Bixby or Google Play services merely
to obtain this result.  Smart Suggestions and Bixby are deliberately restored
by `unica/patches/zzzz_m21s_ai_minimal` for requested features.  A smaller
feature set should be an opt-in `lite` module, with its own package and
feature-contract audit, rather than an undocumented deletion from the default
build.

After a clean build and boot, verify:

```sh
adb shell 'getprop ro.slmk.cached_max; getprop dalvik.vm.usap_pool_enabled'
adb shell 'dumpsys activity settings | grep -E "CUR_MAX_CACHED_PROCESSES|CUR_MAX_EMPTY_PROCESSES"'
```

Expected values are `128`, `false`, and approximately `158` cached processes
(the exact total includes the framework's empty-process allowance).  Exercise
camera, a browser and normal app switching before publishing the policy.

### Root cause found and fixed: M21 defconfig selected the M21 camera profile (2026-10-05)

The kernel audit above is conclusive.  The target is an SM-F415F (Galaxy F41),
but `KERNEL_TARGET=m21` built `exynos9611-m21_defconfig`, whose FIMC-IS profile
is `CONFIG_CAMERA_MMS_V21`: rear GM2, front HI2021Q, actuator DW9808.  The stock
SM-F415F ZTO boot image that the ROM retains declares a different module list in
its DTBO, and those are the nodes FIMC-IS actually probes:

```text
gw1     position 0  id 0   rear   SENSOR_NAME_S5KGW1 = 62
imx616  position 1  id 1   front  SENSOR_NAME_IMX616 = 121
gc5035  position 2  id 2
4ha     position 4  id 3
```

Because `CONFIG_CAMERA_CIS_GW1_OBJ` and `CONFIG_CAMERA_CIS_IMX616_OBJ` were
unset, neither the CIS drivers nor the module wrappers were compiled, so
`fimc_is_search_sensor_module()` could never resolve ids 62/121 and both camtype
sysfs nodes stayed `UNKNOWN_UNKNOWN_FIMC_IS`.  The `-121` (`EREMOTEIO`) EEPROM
read failure is the same mismatch seen from the bus side: the module that drives
the sensor power/reset/MCLK sequence was never compiled.

Fixed by `0010-m21-f41-camera-sensors.patch`, which aligns only the camera
selection with the real F41 hardware and leaves every other m21 choice intact
(SSP_M21, MALI r32p1, panel/charging and the Android 17 backports):

```text
CIS       + GW1, IMX616      - GM2, HI2021Q   (GC5035 and 4HA already y)
actuator  + DW9817           - DW9808
profile   + CAMERA_FXT_V41   - CAMERA_MMS_V21
```

`CAMERA_FXT_V41` is what selects `fimc-is-vendor-sensor-pwr_fxt_v41.h` and
`fimc-is-vender-rom-config_fxt_v41.h`, carrying the F41 rails (`CAM_VLDO1..7`,
`gpio_cam_a2p8_en`) and the matching gw1/imx616/gc5035/4ha EEPROM maps.
Enabling the CIS objects without it would still power the wrong rails and read
the wrong EEPROM blocks, so both changes are required together.

Do not "fix" this by switching `KERNEL_TARGET` to `f41`: that also changes the
SSP sensors to M31 and Mali to r38p1, which patch `0006` and `VALIDATE_BUILT_KERNEL`
reject on purpose.  Overriding the whole f41 defconfig is also unnecessary; the
camera block above is now byte-identical to `exynos9611-f41_defconfig`.

`VALIDATE_BUILT_KERNEL` now asserts GW1/IMX616/GC5035/4HA and DW9817 are
selected, that GM2/HI2021Q and `CAMERA_MMS_V21` are not, that
`CAMERA_FXT_V41` is selected, and that the four CIS/module objects were built.
`KERNEL_CACHE_VERSION` was raised to `7` so the stale kernel is rebuilt.

Still unverified: the fix was validated by rebuilding the FIMC-IS subtree and
confirming the F41 profile is used (106 references to
`fimc-is-vendor-config_fxt_v41.h`, zero to `mms_v21`), but no full ROM build or
on-device boot has been run yet.  After flashing, confirm
`/sys/devices/virtual/camera/rear/rear_camtype` reports `SLSI_S5KGW1_FIMC_IS` and
`front_camtype` reports `SONY_IMX616_FIMC_IS`, and check that no `-121` EEPROM
error remains.  If `-121` persists after this change, the remaining cause is
downstream (pinctrl, regulator, reset, MCLK or I2C channel), not the config.

## Camera zoom: `DEFAULT_MAX_ZOOM_VALUE` (2026-10-05)

### Symptom

The camera crashed on launch with the zoom range collapsed:

```
java.lang.RuntimeException: Zoom is not supported. Check the zoom range.
  minZoomLevel=1000, maxZoomLevel=1000
    at com.samsung.android.camera.layer.keyscreen.zoom.ZoomView.m(...)
```

`min == max == 1000`, so the slider had zero width and the app aborted. The
`Zoom is not supported` string does not exist in the stock v12 app, so this is
not a v12 regression: the stock F415F camera and the One UI 9 v17 camera both
fail identically on this hardware.

### Cause

`DEFAULT_MAX_ZOOM_VALUE` in `cameradata/camera-feature.xml` was `1000`
(1.0x) while the minimum reported by the HAL was also 1.0x, leaving no range.

### Fix

```
target/m21s/camera/camera-feature.xml:183
- <local name="DEFAULT_MAX_ZOOM_VALUE" value="1000" />
+ <local name="DEFAULT_MAX_ZOOM_VALUE" value="4000" />
```

4000 = 4.0x, which is the real digital zoom ceiling of this device. PhoneDB
specs for SM-M215F list `1.0 x optical zoom` / `4.0 x digital zoom`, and the
M21S camera stack is 64MP f/1.8 26mm + 8MP ultrawide + 5MP depth with no
telephoto lens, so there is no optical zoom beyond 1.0x. The HAL dump agrees:
`availableMaxDigitalZoom = 4.0`.

Do not raise this value past 4000; the HAL will not honour a larger ratio and the
app will fail differently.

**Correction (later the same day): this change alone does not fix the zoom
crash.** With the stock M21s XML plus `value="4000"` applied, the app still
reports `minZoomLevel=1000, maxZoomLevel=1000` in `onCreate`. The value is
therefore not read from `DEFAULT_MAX_ZOOM_VALUE` at the point of the check, or
it is recomputed from the HAL zoom capability and clamped. The zoom ceiling
source is still unresolved — see section 3 at the top of this file.

## Camera resolution table: `FRONT_CAMERA_PICTURE_DEFAULT_RESOLUTION`

### Symptom

With the zoom fixed, the app got further and then died in a secondary thread:

```
FATAL EXCEPTION: CamSettingBackgroundHandlerThread
java.lang.RuntimeException: 108 is not exist
    at com.samsung.android.camera.core2.util.q.get(...)
    at java.util.Optional.orElseThrow(Optional.java:403)
```

### What `108` actually is

Not a camera id. `core2/util/q` is a `Supplier` for `Optional.orElseThrow`, and
its message prints the key it failed to find. The key is looked up in the
resolution enum `l9/a2`, which holds 166 `RESOLUTION_WxH` constants, resolved
through:

```
vc/n.get() -> e5/n.FRONT_CAMERA_PICTURE_DEFAULT_RESOLUTION
          -> e5/g.m()        (enum -> string)
          -> l9/a2.f(String) (string -> resolution enum)
          -> te/c0.J(I)      (HashMap<resolution, ...>, findFirst().orElseThrow)
```

### Root cause: `camera-feature.xml`, not the app

The resolution comes from **`cameradata/camera-feature.xml`**, which defines 173
`<local>` keys. The app holds the same key names in `e5/f` but the *values*
are supplied by the XML at runtime, so the smali fallback `2592x1944` is never
what is used. `target/m21s/camera/camera-feature.xml` declares:

```
<local name="FRONT_CAMERA_PICTURE_DEFAULT_RESOLUTION" value="4000x3000" />
```

`4000x3000` is not among the front-camera sizes the F41 HAL reports for device
1 (`3264x2448` active array). The stock XML asks for sizes from other sensors:

```
FRONT_CAMERA_RESOLUTION_SUPER_RESOLUTION      4000x3000
FRONT_CAMERA_RESOLUTION_4BY3_LARGE           4000x3000
FRONT_CAMERA_RESOLUTION_4BY3_MEDIUM          4000x3000
FRONT_CAMERA_RESOLUTION_16BY9_LARGE          4000x2252
FRONT_CAMERA_RESOLUTION_1BY1_LARGE           2992x2992
FRONT_CAMERA_PICTURE_DEFAULT_RESOLUTION      4000x3000
```

The lookup misses and the app aborts. Do **not** respond by shrinking these
values into the HAL/enum intersection: that is what produced the S926B merge
and the soft reboot documented at the top of this file. Keep the stock values
and fix the resolution source properly.

### Camera id inventory

`dumpsys media.camera` reports `Number of camera devices: 4` but exposes **9**
device ids, matching the F415F vendor HAL:

```
0, 1, 2, 3, 4, 20, 23, 50, 52
```

Device 52 is the rear camera reporting `2576x1932`. The front-facing devices are
1, 3 and 4; device 1 has a `3264x2448` active array. The DT declares
`supported_cameraId=<0x0 0x1 0x17 0x32 0x34>` (0,1,23,50,52) with
`max_supported_camera=<5>` / `max_camera_num=<4>`, so the app-visible ids are a
subset. `availableMaxDigitalZoomList` is the same fixed
`[10,10,1,10,10,10,10,1]` on all 9 ids and is built inside
`vendor/lib64/libexynoscamera3.so`; neither the DTBO nor the `FXT_V41` profile
carries any zoom property.

Note: the v17 app registers `samsung.android.scaler.availableMaxDigitalZoomList`
but has **no consumer** for it (the key obfuscates to `.q0`). Only
`availableMaxDigitalZoom` (`.p0`) is read, by `core2/CamCapability`. The v12
stock app does read the list, via `core2/capability/ScalerCapability`. This is
why the v17 camera is not affected by the list contents.

## General findings worth keeping

**The zoom curve tables are identical in v12 and v17.** They are hardcoded
strings, not code. `v12: layer/keyscreen/zoom/ZoomCurveDataHelper` and
`v17: core2/container/p` both carry the same four ranges byte for byte:

```
500_5000     50 steps   0.50x -> 5.00x
500_10000    45 steps   0.50x -> 10.00x
500_30000    61 steps   0.50x -> 30.00x
500_100000   61 steps   0.50x -> 100.00x
```

Entry format is `ratio,stepDurationMs,nextStepDurationMs`, e.g.
`0.50,0,32;0.60,32,32;...`. There is no zoom logic to port between the two
apps; v17 only refactored the class layout and dropped the vendor-list
consumer.

**Stock v12 will not run on One UI 9.** `OneUiVersion.get(90000)` throws
`IllegalArgumentException` because the enum stops at `V5_0` (50000). Patched
to return the highest known version instead, it gets past `onCreate` and dies in
`onStart` with
`NoSuchMethodError: semSetDisablePreviewScreenshots(Z)V in AppCompatActivity` -
that method is only in the AppCompat the ROM ships, and the v12 APK embeds an
older one. Both are the same class of problem: generation mismatch between the
app and the framework, not something the camera HAL causes.

**Packaging gotcha when patching a system APK.** `apktool` output must be run
through `zipalign -p 4` before signing. Without it the PM silently skips the
package at boot scan (no log line at all, `pm list packages` shows nothing) and
`pm install` reports the misleading
`INSTALL_FAILED_INVALID_APK: Failed to extract native libraries, res=-2` even
though the `.so` files are byte-identical to the originals. After aligning and
signing, the same APK is accepted. Signature verification with
`security/aosp_platform.pk8` was never the problem.

**After replacing a `/system` APK, dex may need recompiling.** The package
installs (`installed=true`) but activities fail to resolve with
`Activity class ... does not exist`. Fix with
`cmd package compile -m speed -f com.sec.android.app.camera`.

**Editing files on the running device.** Android 17 on this ROM has a single
root mount (`/dev/block/dm-0 on / type ext4`), so remount **`/`**, not
`/system` — `/system` is not in `/proc/mounts` and `mount -o remount,rw /system`
fails with `/system not in /proc/mounts`. Use `su 0 sh -c`; plain `su -c`
yields `CapEff: 0` here and is useless, and KernelSU's own `su` has no `-o` flag
(it must be inside `sh -c`). Once `/` is rw, an **existing** `/system` file can
be replaced with `cp`, which inherits the destination's owner/mode/context.
`chown`, `chmod`, `rm` and creating new files under `/system` are still denied
by SELinux even as root, so do not plan on restoring `camera-feature.xml.bak`
this way. Overwriting a `/system` **APK** is not possible at all (`dd` writes 0
bytes). For APKs use TWRP: it mounts at `/system_root`, remount rw, push, fix
owner/mode, then `twrp unmount system`. The camera apk lives at
`/system_root/system/priv-app/...`, note the doubled `system`.

## M21s SamsungCamera stale resolution migration (2026-10-05)

The `RuntimeException: 53 is not exist` was caused by a stale private
SamsungCamera preference, not an APK default or a camera-feature XML value:

```xml
<string name="back_camera_resolution">53</string>
```

It was found in
`/data/user/0/com.sec.android.app.camera/shared_prefs/com.sec.android.app.camera_preferences.xml`.
The stock M21s camera XML is parsed correctly: its valid default IDs are
`110` for rear `9248x6936` and `108` for front `4000x3000`.

`target/m21s/mods/m21s_display_camera/SamsungCamera.apk/0001-Migrate-stale-M21s-camera-resolution-preferences.patch`
patches `vc/f0.get()I` in the generated M21s SamsungCamera APK. When it reads
the old value `53`, it writes and returns `110` for
`back_camera_resolution`, or `108` for `front_camera_resolution`. Other
stored choices and XML-derived defaults are unchanged.

On the connected device, changing only the stale stored rear value to `110`
produced:

```text
BACK_CAMERA_RESOLUTION, value= 110
FRONT_CAMERA_RESOLUTION, value= 108
```

The `53 is not exist` crash is gone. The next camera launch stops later at
the independent unresolved zoom-capability failure
`minZoomLevel=1000, maxZoomLevel=1000`; do not alter the M21s XML baseline
to address it.

### APK test result

`out/target/m21s/SamsungCamera-m21s-resolution-migration-test.apk` was
installed through TWRP and tested on the connected device. The initial test
artifact failed before camera initialization because native libraries in a
system APK must be page-aligned. Re-align the rebuilt APK with
`zipalign -p 4` before signing; ordinary `zipalign 4` is insufficient and
causes `libnativeutils-jni.so not found`.

The installed page-aligned artifact has SHA-256
`95b783abf18a7fb02f87efb9690a42fed7ebf44d08f53b343e0d0d57f08b99d2`.
Forcing the stored rear preference to `53` then launching the camera changed
it back to `110`, and the log reported `BACK_CAMERA_RESOLUTION, value= 110`.
The app then reached sensor preview and only crashed at the existing zoom
capability check. This verifies the resolution migration itself.

### Fixed high-resolution zoom range (2026-10-05)

`DEFAULT_MAX_ZOOM_VALUE=4000` remains required in the M21s XML, but it is not
the source of the v17 `ZoomView` range. With the default `9248x6936` capture
profile, SamsungCamera selects its `HIGH_RESOLUTION` capability index (index
`2`). The F41 camera HAL exposes
`samsung.android.scaler.availableMaxDigitalZoomList` as
`[10, 10, 1, 10, 10, 10, 10, 1]`; the selected entry is consequently `1.0x`.
The matching minimum is also `1.0x`, so the app gets `1000..1000`.

This is a valid fixed-zoom high-resolution capability, not an indication that
the XML's 4x normal-mode ceiling was removed. The ported v17 code incorrectly
throws from `ZoomView.m()` for that valid fixed range. The M21s-only
`SamsungCamera.apk/0002-Do-not-crash-when-high-resolution-zoom-is-fixed.patch`
returns from zoom UI setup when the range is fixed, allowing the preview to
continue without advertising unsupported high-resolution zoom. The normal
camera capability still reports 8x through standard Camera2 metadata.

## M21s - Patch tethering_legacy (BPF) nativo + correção hash V-gate (2026-10-06)

- Problema: com `TETHERING_BPF_KEEP_DSCP=1`, estado fica nativo `PATCHED_9`, mas módulo validava contra hashes do caminho `skip+DSCP`. Blocos KVER/V-gate exigiam os hashes antigos → validação falhava.
- Correção em `platform/exynos990/patches/tethering_legacy/customize.sh`:
  - Adicionadas constantes `BPF_KVER_414355_NATIVE_PATCHED_9_SHA256` e `BPF_KVER_414355_NATIVE_V_GATE_PATCHED_9_SHA256`
  - Máquina de estados reconhece estados nativos
  - Bloco KVER separa fluxo nativo (PATCHED_9 → native+KVER) do fluxo skip
  - Bloco V-gate reconhece/gera estado nativo+V-gate
- Hash V-gate real corrigido para `e17af1482036b037572c8961029c873a49531be10e0a9b29ac0b90947078d010` (obtido do leftover `native+KVER` + V-gate reverso).
- CAPEX stock no work_dir → build parte de `EXPECTED_9` via fluxo nativo completo.

## M21s - KernelSU-Next (legacy) aplicado (2026-10-06)

- Removido KernelSU original + vestígios SUSFS do checkout `out/kernel_tmp-exynos9611` (submódulo, drivers/android/kernelsu, configs, hooks, AnyKernel3 refs).
- Aplicado KernelSU-Next legacy via `curl ... setup.sh | bash -s legacy` → cria `KernelSU-Next/`, symlink `drivers/kernelsu -> ../KernelSU-Next/kernel`, `CONFIG_KSU=y`, `CONFIG_KPROBES=y`, `CONFIG_KPROBE_EVENTS=y` no defconfig m21.
- Removidos hooks KSU/SUSFS manuais dos arquivos fs/mm/kernel quebrados pelo setup.
- Removido `kernel/bpf/ringbuf.c` da build (4.14 sem ringbuf nativo compatível) e `ringbuf.o` do Makefile.
- Limpeza SUSFS em `mm/shmem.c`, `kernel/sys.c`, `fs/internal.h`, `fs/open.c`, `fs/exec.c`, `fs/stat.c`, `fs/read_write.c`, `fs/readdir.c`, `fs/proc_namespace.c`, `fs/proc/base.c`, `fs/proc/task_mmu.c`, `fs/namespace.c`, `fs/namei.c`.
- Build kernel com LLVM: `export PATH=toolchain/bin:$PATH && make O=out ARCH=arm64 LLVM=1 -j4` (em andamento até gerar `out/arch/arm64/boot/Image`).

## M21s - Corrigido semantic-check de patches 0011/0012 (kernel9611) (2026-10-06)

- Adicionado `KERNEL_PATCH_ALREADY_PRESENT` para `0011-bpf-verifier-accept-pseudo-map-value.patch` e `0012-bpf-ringbuf-backport.patch` (árvore incremental já tem marcadores) evitando falha em `git apply --check/reverse-check`.

## M21s - KernelSU-Next: hooks manuais, shmem corrompido, ringbuf e fix do zip TWRP (2026-10-07)

Comando alvo: `python3 build_kernel.py --target m21 --allow-dirty --oneui` (checkout `out/kernel_tmp-exynos9611`, kernel `SomethingNew` 1.3.0, KernelSU-Next v3.4.0-legacy 33305).

### Pré-requisito de ambiente
- `build_kernel.py` não exporta `LD_LIBRARY_PATH`. O `toolchain/bin/llvm-objdump` é symlink para `out/kernel_tmp-exynos990/toolchain/clang_14/bin/llvm-objdump`, então é obrigatório:
  `export LD_LIBRARY_PATH=/home/ats0c/Git/ShitStockModOrSomething/out/kernel_tmp-exynos990/toolchain/clang_14/lib64`
  Sem isso o build morre com `llvm-objdump: not found`.

### Erro 1 - "No hooks were defined" (Kbuild KernelSU-Next:171)
- Causa: `CONFIG_KSU_MANUAL_HOOK=y` (ativado porque `CONFIG_KPROBES` está desabilitado no `exynos9611-m21_defconfig`) e o check do `drivers/kernelsu/Kbuild:164` (`grep ksu_handle_sys_reboot kernel/reboot.c`) falhou.
- Correção: adicionados os hooks manuais do KernelSU-Next (funções definidas na própria `KernelSU-Next`):
  - `kernel/reboot.c` - `ksu_handle_sys_reboot(magic1, magic2, cmd, (void __user **)&arg)` antes do check `CAP_SYS_BOOT`, sem short-circuit.
  - `fs/exec.c` - `ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags)` em `do_execveat_common`.
  - `fs/read_write.c` - `ksu_handle_vfs_read(&file, &buf, &count, &pos)` (dummy manual desta versão) em `vfs_read`.
  - `fs/stat.c` - `ksu_handle_stat(&dfd, &filename, &flags)` em `vfs_statx`.
  - `fs/open.c` - `ksu_handle_faccessat(&dfd, &filename, &mode, NULL)` em `sys_faccessat`.
  - Declarações `extern` colocadas em escopo de arquivo (não inline) por causa de `-Werror -Wdeclaration-after-statement`.

### Erro 2 - `mm/shmem.c` corrompido
- O arquivo estava byte-identico a `kernel/sys.c` (2776 linhas). Restaurado de `HEAD` (4445 linhas) e removidos os residuos SUSFS: `#include <linux/susfs.h>` + `#endif` orfao e o bloco `if (susfs_sus_memfd(name))` + `#endif` orfao.

### Erro 3 - `kernel/bpf/ringbuf.c` ausente (link: undefined `bpf_ringbuf_*_proto`)
- O backport (patch `0012-bpf-ringbuf-backport.patch`) tem referencias em `kernel/trace/bpf_trace.c` e `include/linux/bpf.h`, mas o arquivo novo `kernel/bpf/ringbuf.c` não existia e a linha `ringbuf.o` havia sido removida do `kernel/bpf/Makefile` (regressão da sessão anterior).
- Correção: recriado `kernel/bpf/ringbuf.c` via `git apply --include='kernel/bpf/ringbuf.c' 0012-bpf-ringbuf-backport.patch` (504 linhas) e re-adicionado `obj-$(CONFIG_BPF_SYSCALL) += ringbuf.o` no `kernel/bpf/Makefile`.
- Resultado: `OBJCOPY arch/arm64/boot/Image` (36 MB), `make` exit 0, e `build_kernel.py` gera `SN_1.3.0_m21_OneUI_2026-10-07.zip`.

### Erro 4 - TWRP "Updater process ended with ERROR: 1"
- Log real: `anykernel.sh: tools/ak3-core.sh: line 367: syntax error: unexpected "fi"`.
- Causa: edições locais não commitadas no submódulo `AnyKernel3` removeram os `ui_print` e deixaram um `else` vazio (`else` seguido de `fi`), o que é erro de sintaxe em `sh` e aborta o instalador inteiro antes de executar.
- Correção: removido o `else` vazio em `AnyKernel3/tools/ak3-core.sh` (branch KSU de `flash_boot`). Validado com `sh -n` em `ak3-core.sh`, `update-binary` e `anykernel.sh` (todos OK).
- Também ajustado `AnyKernel3/anykernel.sh`: `supported.versions=13 - 17` -> `12 - 17` (stock M21 = OneUI 4.1/Android 12; a checagem antiga abortava com "Unsupported Android version").
- `BLOCK=/dev/block/platform/13520000.ufs/by-name/boot` confirmado correto (dts `ufs@0x13520000`, `exynos9610.dts:2678`).
- Log do TWRP com `/data` criptografado: usar `adb pull /tmp/recovery.log` (tmpfs) ou `/cache/recovery/log` / `/cache/recovery/last_log`; o "Copy Log" padrão falha porque grava em `/sdcard`.
- Zip final: `out/kernel_tmp-exynos9611/SN_1.3.0_m21_OneUI_2026-10-07.zip`.
- **CONFIRMADO pelo usuário:** o `ERROR: 1` do TWRP foi resolvido pelo fix do `else` vazio no `ak3-core.sh`.

### Root do KernelSU-Next perdido após o flash (manager x driver) (2026-10-07)

- Estado do driver embutido no kernel: `KSU_VERSION=33305`, tag `v3.4.0-legacy`, commit `2d99a2da` (`v3.4.0-legacy-11-g2d99a2da`); `KERNEL_SU_UAPI_VERSION=5` (`uapi/supercall.h:13`).
- O KernelSU-Next **valida o APK do manager por assinatura**, não só por versão. O kernel compila com:
  - `EXPECTED_MANAGER_SIZE=0x3e6` e `EXPECTED_MANAGER_HASH=79e590113c4c4c0c222978e413a5faa801666957b1212a328e46c00c69821bf7` (`kernel/Kbuild:126-131`, usados em `kernel/manager/apk_sign.c:389`).
  - Um APK de manager compilado com chave de assinatura própria NÃO é reconhecido (sintoma: "signature not found", superuser/superfícies vazias, root inutilizável).
- Overrides suportados pelo `Kbuild` (lidos via `ifdef`/`ifndef`, então basta exportar no ambiente antes de rodar o `build_kernel.py`):
  - `KSU_VERSION_OVERRIDE` / `KSU_VERSION_TAG_OVERRIDE` (`Kbuild:105-107,119-123`)
  - `KSU_NEXT_MANAGER_SIZE` / `KSU_NEXT_MANAGER_HASH` (`Kbuild:126-131`)
  - `KSU_MANAGER_PACKAGE` (nome do pacote do manager)
- Extrair a assinatura do APK para casar com o kernel:
  ```sh
  unzip -o manager.apk 'META-INF/*.RSA' -d /tmp/apksig
  openssl pkcs7 -inform DER -in /tmp/apksig/META-INF/*.RSA -print_certs -out /tmp/apksig/cert.pem
  openssl x509 -in /tmp/apksig/cert.pem -outform DER -out /tmp/apksig/cert.der
  printf 'KSU_NEXT_MANAGER_SIZE=0x%x\nKSU_NEXT_MANAGER_HASH=%s\n' \
    "$(stat -c%s /tmp/apksig/cert.der)" "$(sha256sum /tmp/apksig/cert.der | cut -d' ' -f1)"
  ```
- Duas soluções possíveis:
  1. **Recomendado:** instalar o APK oficial do KernelSU-Next da mesma release (`v3.4.0`), que já bate com o hash/size embutidos.
  2. Se o APK for obrigatoriamente o compilado pelo grupo, rebuildar o kernel com `KSU_NEXT_MANAGER_SIZE`/`KSU_NEXT_MANAGER_HASH` extraídos desse APK (e ajustar `KSU_VERSION_OVERRIDE` se a versão do manager for mais baixa que `33305`).
- A compatibilidade real é pela UAPI (`KERNEL_SU_UAPI_VERSION=5`): managers `>= v3.0.0` falam UAPI 5; managers antigos (série 1.x) não enxergam o driver.

### RESOLVIDO - manager recompilado (UAPI 5) + kernel com assinatura própria (2026-10-07)
- O `KSU_VERSION_OVERRIDE=33294` anterior foi **revertido**: o kernel voltou a `33305`.
- Causa real (dupla):
  1. **UAPI:** o driver `legacy` HEAD reporta `KERNEL_SU_UAPI_VERSION=5`; o manager só é "full featured" quando `kernelUAPIVersion == managerUAPIVersion` (`Natives.kt`). Nenhuma release oficial tem UAPI 5 (`v3.3.0`=2, `v3.4.0`=4) -> só um manager da branch `dev` (UAPI 5) serve.
  2. **Assinatura:** `is_manager_apk()` (`kernel/manager/apk_sign.c`) confere a assinatura **v2** contra `EXPECTED_MANAGER_SIZE`/`EXPECTED_MANAGER_HASH` (default = chave oficial `0x3e6`/`79e590...`). APK próprio precisa do hash embutido no kernel.
- **Decisão (aprovada):** subir o manager e embutir a assinatura dele no kernel, mantendo `KSU_VERSION=33305`.
- **Manager:** compilado da branch `dev` (HEAD `3daa5787`, UAPI 5, `versionCode=33323`), assinado v2-only com keystore próprio.
  ```sh
  git -C out/kernel_tmp-exynos9611/KernelSU-Next worktree add --detach out/manager_build/src dev
  export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
  export ANDROID_HOME=/home/ats0c/.android-sdk          # platform 36, build-tools 36.1.0, ndk 29.0.14206865
  export ANDROID_NDK_HOME=/home/ats0c/.android-sdk/ndk/29.0.14206865
  cd out/manager_build/src/manager && ./gradlew clean assembleRelease
  # libksud.so (Rust) reutilizado do APK oficial v3.4.0 (mudança UAPI aditiva); re-assinar v2-only:
  apksigner sign --ks ksu-manager.jks --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled false ...
  ```
  Saída: `prebuilts/kernelsu-next/KernelSU_Next_33323_uapi5.apk`.
- **Kernel (33305, sem override):** rebuild embutindo a assinatura do manager:
  ```sh
  export KSU_NEXT_MANAGER_SIZE=0x308
  export KSU_NEXT_MANAGER_HASH=8b4967968e3418f3ec3bf00fa2e7c2fbfbfb9813d220a4d5a1a9f2b0b1b6edaf
  python3 build_kernel.py --target m21 --allow-dirty --oneui
  ```
  Verificado: `EXPECTED_MANAGER_SIZE=0x308` e `KSU_VERSION=33305` nos `.cmd` e o hash presente no `Image`. Zip: `out/kernel_tmp-exynos9611/SN_1.3.0_m21_OneUI_2026-10-07.zip`.
- **Integração:** `prebuilts/kernelsu-next/` (APK + `ksu-manager.jks` + `README.properties`); `unica/mods/preload/customize.sh` instala o APK local; `platform/exynos9611/.../customize.sh` exporta `KSU_NEXT_MANAGER_SIZE/HASH`.
- **Notas de armadilha:** o cert deve ter ≤1024 bytes (`CERT_MAX_LENGTH`) -> keystore RSA-2048 (cert atual = `0x308`). O `.apk` só pode ter **um** bloco v2 e nenhum v3 (o parser rejeita ids desconhecidos).

### SOLUÇÃO FINAL CONFIRMADA - KernelSU-Next (UAPI 5) no exynos9611/M21 (2026-10-07)

> Status: **testado no dispositivo e funcionando** ("alterações funcionaram").

#### Resumo do problema
O kernel universal9611 já vem com KernelSU-Next `legacy` HEAD (`KSU_VERSION=33305`, `KERNEL_SU_UAPI_VERSION=5`). O preload do ROM baixava o manager oficial `v3.3.0` (UAPI 2). Resultado: o manager não é "full featured" — `isFullFeatured()` exige `kernelUAPIVersion == managerUAPIVersion` (`manager/.../Natives.kt`) e a UI mostra `require_manager_version`. Não existe release oficial com UAPI 5 (`v3.3.0`=2, `v3.4.0`=4), e o kernel ainda confere a assinatura **v2** do manager (`kernel/manager/apk_sign.c` → `check_v2_signature`), cujo default é a chave oficial (`KSU_NEXT_MANAGER_SIZE=0x3e6`, `KSU_NEXT_MANAGER_HASH=79e590...`).

Decisão: **subir o manager** (compilar da branch `dev`, UAPI 5) e **embutir a assinatura dele no kernel**, mantendo `KSU_VERSION=33305`. O `KSU_VERSION_OVERRIDE=33294` anterior foi revertido.

#### 1) Toolchain (uma vez)
```sh
# Java 21 e Android SDK/NDK (o build do manager usa AGP 8.13.1, Kotlin 2.2.0, NDK 29)
sudo apt-get install -y openjdk-21-jdk        # se necessário
SDK=/home/ats0c/.android-sdk
SDKM=$SDK/cmdline-tools/latest/bin/sdkmanager
yes | "$SDKM" --sdk_root="$SDK" --licenses
"$SDKM" --sdk_root="$SDK" "platforms;android-36" "build-tools;36.1.0" "ndk;29.0.14206865" "platform-tools"
```

#### 2) Compilar o manager (branch `dev`, UAPI 5)
```sh
git -C out/kernel_tmp-exynos9611/KernelSU-Next worktree add --detach out/manager_build/src dev
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
export PATH="$JAVA_HOME/bin:$PATH"
export ANDROID_HOME=/home/ats0c/.android-sdk
export ANDROID_NDK_HOME=/home/ats0c/.android-sdk/ndk/29.0.14206865
cd out/manager_build/src/manager
printf 'sdk.dir=%s\nndk.dir=%s\n' "$ANDROID_HOME" "$ANDROID_NDK_HOME" > local.properties
# assinatura: KEYSTORE_FILE/KEYSTORE_PASSWORD/KEY_ALIAS/KEY_PASSWORD em gradle.properties
cp ../../ksu-manager.jks key.jks
./gradlew clean assembleRelease      # gera versionCode=33323 (commit count do dev)
```
Observação: `libksud.so` (Rust) foi **reutilizado do APK oficial v3.4.0** (a mudança UAPI 4→5 é aditiva: `EVENT_SERVICES`), copiando para `manager/app/src/main/jniLibs/arm64-v8a/libksud.so` antes do assemble.

#### 3) Assinar v2-only e extrair size/hash do cert v2
```sh
BT=/home/ats0c/.android-sdk/build-tools/36.1.0
"$BT/zipalign" -p -f 4 release.apk aligned.apk
"$BT/apksigner" sign --ks ksu-manager.jks --ks-key-alias ksunext \
  --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled false \
  --out KernelSU_Next_33323_uapi5.apk aligned.apk
```
> Só pode haver **um** bloco v2 e **nenhum v3** (o parser do kernel rejeita ids desconhecidos).
> O cert precisa ter ≤ `CERT_MAX_LENGTH` = **1024** bytes → usar keystore **RSA-2048** (o cert atual tem `0x308`).

O `check_block()` de `apk_sign.c` lê: `signers → signer → signed_data → digests → certificates → u32 cert_size → cert`, e compara `size == EXPECTED_MANAGER_SIZE` e `sha256(cert) == EXPECTED_MANAGER_HASH`. Script para extrair exatamente isso (validado contra o APK oficial, que dá `0x3e6`/`79e590...`):
```python
# /tmp/opencode/apk_cert.py  ->  python3 apk_cert.py <apk>
import sys, struct, hashlib
d = open(sys.argv[1], 'rb').read()
i = d.rfind(b'PK\x05\x06'); cd = struct.unpack('<I', d[i+16:i+20])[0]
assert d[cd-16:cd] == b'APK Sig Block 42'
sz = struct.unpack('<Q', d[cd-24:cd-16])[0]; pos = cd - sz - 8
u32 = lambda b,o: struct.unpack('<I', b[o:o+4])[0]
blk = None; p = pos + 8
while p < cd - 24:
    sp = struct.unpack('<Q', d[p:p+8])[0]; p += 8
    if u32(d, p) == 0x7109871a: blk = d[p+4:p+sp]; break
    p += sp
rl = lambda b,o: (o+4, o+4+struct.unpack('<I', b[o:o+4])[0])
o = 0
for _ in range(4): o,_ = rl(blk, o)      # signers, signer, signed_data, digests
o = _ ; o,ce = rl(blk, o)                # certificates
cs = struct.unpack('<I', blk[o:o+4])[0]; o += 4
cert = blk[o:o+cs]
print("EXPECTED_MANAGER_SIZE = 0x%x" % cs)
print("EXPECTED_MANAGER_HASH = %s" % hashlib.sha256(cert).hexdigest())
```

#### 4) Rebuildar o kernel 33305 embutindo a assinatura
```sh
export LD_LIBRARY_PATH=/home/ats0c/Git/ShitStockModOrSomething/out/kernel_tmp-exynos990/toolchain/clang_14/lib64
unset KSU_VERSION_OVERRIDE
export KSU_NEXT_MANAGER_SIZE=0x308
export KSU_NEXT_MANAGER_HASH=8b4967968e3418f3ec3bf00fa2e7c2fbfbfb9813d220a4d5a1a9f2b0b1b6edaf
cd out/kernel_tmp-exynos9611 && python3 build_kernel.py --target m21 --allow-dirty --oneui
```
Verificação:
```sh
grep -rhoE 'KSU_VERSION=[0-9]+' out/kernel_tmp-exynos9611/out/drivers/kernelsu | sort -u   # 33305
grep -oE 'DEXPECTED_MANAGER_SIZE=[^ ]+' out/kernel_tmp-exynos9611/out/drivers/kernelsu/manager/.apk_sign.o.cmd
strings -a out/kernel_tmp-exynos9611/out/arch/arm64/boot/Image | grep -c 8b4967968e34...edaf  # 1
```
Zip final: `out/kernel_tmp-exynos9611/SN_1.3.0_m21_OneUI_2026-10-07.zip`.

#### 5) Arquivos alterados / artefatos
- `prebuilts/kernelsu-next/KernelSU_Next_33323_uapi5.apk` (manager UAPI 5, v2-only).
- `prebuilts/kernelsu-next/ksu-manager.jks` + `README.properties` (credenciais do keystore).
- `unica/mods/preload/customize.sh` → instala o APK **local** em `system/preload/KernelSU-Next/com.rifsxd.ksunext-mesa==/base.apk`.
- `target/m21s/patches/kernel9611/customize.sh` → define/exporta `KSU_NEXT_MANAGER_SIZE`/`KSU_NEXT_MANAGER_HASH` (e inclui no `GET_KERNEL_CACHE_KEY`).
- `out/manager_build/src` = worktree destacado da branch `dev` do `KernelSU-Next`.

#### 6) Armadilhas conhecidas
- Caminho do kernel `legacy` HEAD usa `#define KERNEL_SU_UAPI_VERSION 5` (não é `static const`).
- UAPI 5 é **aditivo** (`EVENT_SERVICES`); por isso o `libksud.so` do v3.4.0 funciona — para 100% fidelidade ao `dev`, compilar o ksud (`rustup` + target `aarch64-linux-android` + linker do NDK); não foi necessário para o root.
- Manter `KSU_VERSION=33305` sem `KSU_VERSION_OVERRIDE`; o check do manager é por **UAPI**, não por versionCode.

### Wallpaper preso em carregamento no M21s (2026-10-07)

O catálogo de `wallpaper-res.apk` da build atual está correto: os defaults do
M21s são estáticos (`default_wallpaper.png` e
`keyguard_default_wallpaper.png`) e `types` está vazio. O travamento ocorre
depois de a imagem ser carregada, dentro do `DressRoom` 3.0.10.35 herdado do
S24+. O log mostra `ArcSoftObjectCaptureImpl: isObjectCaptureSupported = true`,
mas o detector retorna `predictions null score 0.0`; em seguida o editor registra
`saveObjectImageAndBounds: object result didn't yet set` e permanece em
`SAVING_WAITING_OBJECT`.

O M21s não possui o pipeline de captura de objetos compatível com esse
`DressRoom`. O módulo específico `target/m21s/mods/wallpaper` agora aplica
`target/m21s/mods/wallpaper/DressRoom.apk/0001-Disable-unsupported-object-capture-on-target.patch`
em `system/priv-app/DressRoom/DressRoom.apk`,
que faz `d7.k.b()` retornar `false`. Isso força o fluxo normal de recorte e
salvamento de imagem estática, sem remover o restante do stack moderno de
wallpaper. O patch foi aplicado e recompilado com Apktool 3.0.3; a build ROM
deve ser instalada para confirmar o salvamento no aparelho.

### y2slte: bootloop provocado pelo `bpfloader` no Android 17 (2026-10-07)

A captura do aparelho `SM-G985F`/`y2slte` está preservada em
`/tmp/last_kmsg-current-device.txt` (e a captura anterior em
`/tmp/last_kmsg-y2slte.txt`); o pstore complementar está em
`/tmp/pmsg-current-device.txt`. O kernel inicia normalmente:
`4.19.325-cip119-st3-ExtremeKRNL-Nexus-v1+`, com o modelo
`Samsung Y2SLTE EUR OPEN 21 based on EXYNOS990`. Não há `Kernel panic`, `Oops`
ou falha de carregamento do `boot.img`.

O Android chega ao serviço `NetBpfLoad`. Os objetos `offload.o`, `test.o` e
mapas/programas anteriores são aceitos, mas o programa obrigatório
`schedcls_ingress6_clat_ether_4_14` de `clatd.o` retorna `-7` (`E2BIG`, exibido
por libbpf como `Argument list too long`). Em seguida o init registra:
`Service bpfloader has 'reboot_on_failure' option and failed` e reinicia com
`reboot,bpfloader-failed`. As mensagens do watchdog aparecem durante o
desligamento e são consequência, não a causa.

O limite de exploração do verifier foi a primeira hipótese, mas o kernel de
teste `#14` a refutou: o `-E2BIG` apareceu sem executar o novo diagnóstico de
complexidade. A causa definitiva era a diferença de tamanho de `union
bpf_attr` entre o UAPI 4.19 e o libbpf do Android 17, corrigida pelo patch
`0009-bpf-accept-newer-prog-load-attributes.patch`. A seção "causa definitiva
do bootloop" abaixo registra a prova e o resultado no aparelho.

### M21s: captura e zoom da câmera (2026-10-07)

O preview da câmera abre, mas o M21s ainda pode encerrar o aplicativo ao pressionar o disparador ou ao tocar no zoom. Há duas causas independentes na montagem Android 17:

- O HAL F415F informa `minZoomLevel=maxZoomLevel=1000` no perfil de alta resolução. O primeiro patch removia apenas a exceção de `ZoomView.m()`, deixando eventos posteriores chegarem ao HAL com uma faixa inválida. O patch `target/m21s/mods/m21s_display_camera/SamsungCamera.apk/0002-Do-not-crash-when-high-resolution-zoom-is-fixed.patch` agora marca o presenter e a categoria da própria `ZoomView` como `Ll9/x2.NOT_SUPPORT` antes de retornar; assim tanto o caminho de toque quanto o clique direto são rejeitados quando o perfil é fixo.
- O logcat `out/target/m21s/boot-diagnostics-2026-10-09_00:23:14-0300/logcat.txt` mostrou que a versão instalada ainda encerrava com `VerifyError` antes da captura: `ZoomView.m(cd.b)` rejeitava `copy-reference v1<-v20 type=PositiveShortConstant`. O método reutiliza `p0` como inteiro em `const/16 p0, 0x3e8`, portanto o patch não podia recuperar o objeto por `p0` no final. O patch foi corrigido para obter a instância segura por `iget-object v1, v2, Lv9/i;->c:ZoomView`; a fonte limpa recebeu o patch e o Apktool remontou o APK sem erro em `/tmp/m21s-camera-verify.Mjnloe/SamsungCamera-fixed.apk`.
- A correção foi instalada no M21s pelo TWRP em 2026-10-09. O app permaneceu aberto, o estado chegou a `PREVIEWING` e o disparo concluiu o pós-processamento, salvando `20261009_004054.jpg`, sem novo `VerifyError`, `FATAL EXCEPTION` ou morte do processo. Os avisos restantes de `ExynosCameraMCPipe ... PIPE_3AA m_getBuffer fail ... ret(-1)` e o evento interno `Erro na câmera.(-10)` não interromperam esse teste; se voltarem a causar falha, devem ser tratados como diagnóstico separado do crash do verificador Java.
- O APK SamsungCamera do Android 17 usa `libnode-jni` e carrega em tempo de captura os processadores que o S24+ não possui no sistema F415F: `libMultiFrameProcessing10.camera.samsung.so`, `liblow_light_hdr.arcsoft.so` e `libhigh_dynamic_range.arcsoft.so`. O módulo M21s importa somente as versões 64-bit do firmware `SM-F415F/ZTO`, com contexto `u:object_r:system_lib_file:s0`, e publica os nomes no namespace de câmera. Sem essa closure o preview pode funcionar, mas o disparo falha no primeiro `dlopen`/símbolo do pós-processamento.
- O `logcat` de 2026-10-07 confirmou um bootloop diferente: o `zygote64` abortava em `linkerconfig` com `Cannot parse /system/etc/public.libraries-camera.samsung.txt` porque os nomes `liblow_light_hdr.arcsoft.so` e `libhigh_dynamic_range.arcsoft.so` não terminam em `.camera.samsung.so`. O módulo continua instalando essas bibliotecas em `system/lib64`, mas publica nessa lista somente `libMultiFrameProcessing10.camera.samsung.so`; os nomes ArcSoft originais não podem ser adicionados ao namespace público validado pelo Android 17.

Todas as alterações da partição vendor foram consolidadas em
`target/m21s/mods/vendor/customize.sh`, incluindo áudio HIDL/políticas de
volume, FBE/fstab, sysinput HIDL, TEEgris, contas e ueventd, propriedades de
memória, firmware do sensorhub e a política camera floating-feature. Os
módulos de câmera, wallpaper e framework permanecem responsáveis apenas por
`system`/APEX/APK. As alterações foram validadas estaticamente (`bash -n` e `git diff --check`). Ainda falta
confirmar no aparelho M21s com um logcat que contenha o crash do disparo; o
S20+ conectado não deve ser usado para esse teste.

### Organização dos módulos por plataforma e target (2026-10-07)

O prefixo `z` era usado apenas para vencer a ordenação alfabética do builder e
forçar módulos finais para o fim. O builder agora ordena cada conjunto pelo
campo numérico `priority=` de `module.prop`, usando `50` quando o campo não é
declarado. Assim os nomes dos diretórios podem descrever a função do módulo,
sem depender de `z`, `zz` ou `zzzz`.

Os módulos exclusivos do M21s ficam no target, separados por responsabilidade:

- `target/m21s/patches`: FBE, tethering, Codec2/APV, kernel, sysinput,
  framework FM e a política de memória de 4 GB;
- `target/m21s/mods/m21s_display_camera`: bibliotecas de pós-processamento,
  correção de zoom e ajustes do SamsungCamera/SecSettings;
- `target/m21s/mods/wallpaper`: somente o patch de DressRoom que desativa a
  captura de objetos incompatível;
- `target/m21s/mods/vendor`: todas as alterações da partição vendor, com os
  blobs, VINTF, propriedades, SELinux, init, fstab e firmware necessários.

`scripts/make_rom.sh` aplica `target/$TARGET_CODENAME/mods` depois dos módulos
comuns de `unica/mods`, para que uma correção exclusiva do aparelho permaneça
como a última camada. Os módulos exclusivamente M21s que antes estavam em
`platform/exynos9611/patches` (`storage_compat` e `tethering_legacy`) também
foram movidos para `target/m21s/patches` e receberam IDs próprios. Os oito
módulos migrados da camada de plataforma usam `priority=40`, antes dos
módulos de target existentes (`priority=50`), preservando a ordem de aplicação
que eles tinham com os antigos nomes iniciados por `z`.

O patch de document-scan específico de `y2s/y2slte` está em
`platform/exynos990/mods/legacy_docscan`, aplicado na etapa tardia de módulos
da plataforma e guardado para os dois targets da família. Os módulos que
continuam em `platform/exynos9611` ou `platform/exynos990` são
compatibilidades compartilhadas pela plataforma, mesmo quando contêm uma
condição interna para um codename; esse patch não é executado para outros
codenames.

O teste opcional do vibrator do M21s usa agora o donor fixado em
`prebuilts/samsung/y2sxxx`, copiado do `SM-G986B_AUT`. O instalador
`platform/exynos9611/installer/vibrator_s20_test` lê esse prebuilt em vez de
depender de `out/fw`; o `vibrator.default.so` incluído ali é apenas o payload
do ZIP de teste e não é instalado automaticamente na ROM M21s.

O módulo `target/m21s/mods/vendor` contém a migração experimental do vibrator
usada no y2s em `platform/exynos990/patches/vendor`: remove o serviço HIDL F415F
e instala o serviço AIDL, o `vendor.samsung.hardware.vibrator-default.rc`, a
declaração VINTF e `vendor.samsung.hardware.vibrator-V3-ndk_platform.so` do
`prebuilts/samsung/p3sxxx`. Ela permanece **desativada por padrão** mesmo com a
dependência V1 agora disponível; pode ser habilitada somente para teste com
`M21S_ENABLE_P3S_AIDL_VIBRATOR=1`. O
`vibrator.default.so` e `libvibrator.so` originais do M21s permanecem intactos.

### Teste P3S AIDL no M21s e rollback (2026-10-08)

O ELF P3S declara `android.hardware.vibrator-V1-ndk_platform.so` em `DT_NEEDED`.
O Android 17 do M21s só fornece a variante V2 no `com.android.vndk.v31.apex`
(além da V4 no sistema). Uma tentativa anterior renomeou a V2 para V1 pelo
TWRP; o serviço iniciou, mas caiu em `HwApi::hasAspEnable()` com `SIGSEGV`, e a
consulta `supportsHapticEngine()` também derrubou o
`system_server`. A causa foi incompatibilidade de ABI, não apenas o nome do
arquivo. O rollback por `dd` restaurou o serviço HIDL, as bibliotecas
`android.hardware.vibrator@1.x.so`, `vendor.samsung.hardware.vibrator@2.x.so` e
o `vendor/etc/vintf/manifest.xml` original. Após o reboot,
`sys.boot_completed=1`, sem crash do `system_server`; os hashes de
`vendor/lib64/hw/vibrator.default.so` e `vendor/lib64/libvibrator.so` ficaram
iguais aos blobs originais.

### Dependência V1 real para o serviço AIDL P3S (2026-10-09)

Foi adicionada a biblioteca arm64 oficial do [VNDK 30 do Android Open
Source](https://android.googlesource.com/platform/prebuilts/vndk/v30/+/8252d85f0f7d0ea3263ab36dda6200e1ad3900e8/arm64/arch-arm64-armv8-a/shared/vndk-core/android.hardware.vibrator-V1-ndk_platform.so)
em `prebuilts/samsung/p3sxxx/vendor/lib64`. Ela tem SONAME exatamente igual ao
`DT_NEEDED` do serviço P3S e SHA-256
`434f4ca8d7a4504ab1a4b9059e8c97f30b06754ebc08fadf15df902f9e136ab1`.

A auditoria encontrou os seis símbolos Android `BnVibrator`/`IVibrator` que o
serviço importa na V1; não foram usados aliases para V2/V4. O binário V1, o
serviço P3S e `vendor.samsung.hardware.vibrator-V3-ndk_platform.so` também não
contêm `ldaprb`, `ldaddal`, `paciasp` ou `autiasp`. O `customize.sh` do M21s
agora copia essa V1 junto com o serviço quando
`M21S_ENABLE_P3S_AIDL_VIBRATOR=1`; o caminho continua desativado por padrão.

### Teste direto do AIDL P3S no M21s (2026-10-09)

Para testar sem esperar uma compilação completa, o M21s foi confirmado pelo
bootloader `F415FUBS3CWK2` e pelo hardware `exynos9611`, reiniciado no TWRP e
teve a vendor original salva em
`out/manual/m21s-vendor-before-p3s-aidl-20261009_001619.img` (758083584
bytes; SHA-256
`293c8afca2a86754206599baf9b4b0fcde59d4c17324cfae5c50037917afec08`).

No `/vendor` montado em leitura e escrita, o teste moveu o serviço HIDL,
seu `rc`, as bibliotecas `vendor.samsung.hardware.vibrator@2.0` a `@2.2` e
as declarações HIDL para
`/vendor/.m21s-vibrator-hidl-before-p3s-20261009`, e instalou o conjunto AIDL
P3S:

- `vendor/bin/hw/vendor.samsung.hardware.vibrator-service`;
- `vendor/etc/init/vendor.samsung.hardware.vibrator-default.rc`;
- `vendor/etc/vintf/manifest/vendor.samsung.hardware.vibrator-default.xml`;
- `vendor/lib64/android.hardware.vibrator-V1-ndk_platform.so`;
- `vendor/lib64/vendor.samsung.hardware.vibrator-V3-ndk_platform.so`.

O `vendor/lib64/hw/vibrator.default.so` e o
`vendor/lib64/libvibrator.so` permaneceram os blobs originais do M21s. Os
contextos SELinux e permissões foram restaurados antes do reboot.

Após iniciar o Android, o serviço AIDL ficou registrado como
`android.hardware.vibrator.IVibrator/default`; o `VibratorManagerService`
passou a reportar `vibratorIds=[0]`, `vibratorInfoLoadSuccessful=true` e
`MOTOR_COIN_DC`. O comando
`adb shell cmd vibrator_manager synced -f oneshot 500 255` terminou com
`played: Step=500ms`, sem falha de linker, `SIGSEGV` ou `SIGILL`. Os artefatos
de reprodução estão em
`out/manual/m21s-p3s-aidl-test-20261009_001750/runtime/`, incluindo o
`dumpsys-vibrator-manager.txt`, a lista de serviços e o logcat. Os avisos sobre
`event_cmd`, `intensity` e outros nós opcionais ausentes são esperados no
driver do M21s e não impediram o registro nem o acionamento do HAL.

Este procedimento é somente um teste manual; a build continua usando o HIDL
original até que o AIDL seja habilitado explicitamente com
`M21S_ENABLE_P3S_AIDL_VIBRATOR=1`.

### Reversão do donor R11S no S20+ (2026-10-09)

O HAL AIDL do `r11sxxx` foi removido de `prebuilts/samsung/r11sxxx/vendor`.
Ele dependia de `android.hardware.vibrator-V2-ndk_platform.so`, que não estava
presente no conjunto baixado, e não chegou a produzir uma build funcional para
`y2s` ou `y2slte`. O donor `r11sxxx/system` continua disponível para os outros
módulos de compatibilidade que o utilizam.

`platform/exynos990/patches/vendor/customize.sh` voltou a usar o conjunto P3S
para o vibrator em todos os targets Exynos 990: serviço AIDL, `rc`, VINTF,
`android.hardware.vibrator-V1-ndk_platform.so` e
`vendor.samsung.hardware.vibrator-V3-ndk_platform.so`. O donor P3S é o mesmo
conjunto que foi carregado e registrado com sucesso no teste do M21s.

### Candidato AIDL completo encontrado no dump e2s (2026-10-08)

O dump identificado no repositório como `e2s` (`SM-S926B`, Galaxy S24+,
Exynos 2400) não é o firmware do S20+ (`SM-G986B`, Exynos 990). Ele contém
um conjunto AIDL diferente do P3S. O serviço
`vendor.samsung.hardware.vibrator-service` declara apenas dependências que vêm
junto do próprio conjunto:

- `android.hardware.vibrator-V2-ndk.so` — SHA-256
  `ea372345288f3222a906f6d50248cd511f72e7c2194710c4053d8c65da936f9f`;
- `vendor.samsung.hardware.vibrator-V5-ndk.so` — SHA-256
  `74a9f8007d455e060b7c281836cd493ae5d358cab80c08e40d386ae947221bb3`;
- serviço AIDL — SHA-256
  `fb30a93664c986f55f7250f0f1755fdd5cb12808cf54806159bcc26245eea2a0`.

O fragmento VINTF declara `IVibrator/default` e `IVibratorManager/default`,
ambos na versão 2. O `rc` usa os mesmos nós `timed_output` e `leds` presentes
no driver original do M21s, acrescentando apenas nós opcionais de FIFO,
`hybrid_haptic_engine` e `sec_vib_inputff`. O conjunto foi apenas baixado para
`out/manual/samsung-dump-e2s-candidate`; não foi instalado. A auditoria de CPU
abaixo bloqueia o uso direto via `dd` no M21s, mesmo mantendo
`vibrator.default.so` e `libvibrator.so` originais.

### Auditoria de compatibilidade Binder dos candidatos (2026-10-08)

O `libbinder_ndk.so` 64-bit da base M21s e o do dump `e2s` são byte a byte
idênticos:

```text
035395be52c63c9c6c0d00df93bbe009175b17d3a0f149cf9af6cf23821b5b6f
```

O Binder do S20+ tem um hash diferente, mas também exporta
`LIBBINDER_NDK`/`LIBBINDER_NDK30`. O serviço e as duas bibliotecas AIDL `e2s`
exigem apenas esses dois conjuntos de símbolos, que estão presentes nas três
bases. O serviço não tem `DT_NEEDED` para `vibrator.default.so` ou
`libvibrator.so`; esses blobs originais podem continuar intocados.

O candidato `r11s` também exige apenas `LIBBINDER_NDK`/`LIBBINDER_NDK30`, e o
`android.hardware.vibrator-V2-ndk_platform.so` do seu VNDK é byte a byte igual
ao VNDK v31 extraído do M21s. Porém, o conjunto r11s usa nomes `_platform` e
um `vendor.samsung.hardware.vibrator-V5-ndk_platform.so` específico da base;
por isso ele é ABI-compatível no Binder, mas menos autocontido que o conjunto
e2s. A compatibilidade de Binder não garante que os nós específicos do motor
vibratório existam no kernel do M21s; isso ainda requer teste funcional.

### Auditoria de instruções CPU do candidato e2s (2026-10-08)

A auditoria ELF foi ampliada para não confundir ABI do Binder com compatibilidade
do processador. Os três arquivos AArch64 do candidato e2s contêm instruções
reais no segmento `.text`:

| Arquivo | `ldaprb` | `ldaddal` |
| --- | ---: | ---: |
| `android.hardware.vibrator-V2-ndk.so` | 3 | 31 |
| `vendor.samsung.hardware.vibrator-V5-ndk.so` | 4 | 15 |
| `vendor.samsung.hardware.vibrator-service` | 4 | 22 |

`ldaprb` requer a extensão ARMv8.3-A FEAT_LRCPC (RCpc), e `ldaddal` pertence
às atomics LSE de ARMv8.1-A. O M21s usa Exynos 9611, com Cortex-A73/A53, e
esses núcleos não oferecem FEAT_LRCPC. Isso já foi confirmado em execução com
o candidato V2: o serviço abortou com `SIGILL` exatamente ao executar
`ldaprb`. Portanto, o conjunto e2s **não pode ser instalado sem recompilação
ou transformação para o M21s**, mesmo que o Binder seja compatível.

O S20+ y2s usa Exynos 990, com núcleos Cortex-A76/A55 e o cluster customizado
M5. A documentação dos A76/A55 confirma LDAPR/RCpc e LSE nos núcleos Arm,
mas não temos uma leitura de `ID_AA64ISAR1_EL1` de cada núcleo M5 do aparelho.
Além disso, os blobs HIDL originais do S20+ não contêm `ldaprb`; portanto o
donor e2s não pode ser marcado como CPU-compatível com o S20+ sem esse teste
por núcleo. Assim, a conclusão operacional é:

* Binder: compatível entre e2s, S20+ e M21s (os símbolos exigidos são
  `LIBBINDER_NDK`/`LIBBINDER_NDK30`; os arquivos do S20+ e do e2s não são
  byte a byte iguais);
* CPU: não comprovado para o S20+ y2s/Exynos 990 e incompatível com o M21s/
  Exynos 9611 no estado binário atual;
* não usar `dd` para colocar o conjunto e2s no M21s. A alternativa segura é
  recompilar os binários para uma ISA compatível ou manter o serviço original
  enquanto se faz um port específico.

### y2slte: causa definitiva do bootloop do `bpfloader` (2026-10-07)

O backport de bounded loops em
`platform/exynos990/patches/extremekrnl/patches/0007-bpf-verifier-allow-bounded-loops.patch`
continua necessário para aproximar o verifier 4.19 da ABI moderna, mas **não era
a causa do `-E2BIG` observado em `clatd.o`**. O kernel de teste `#14` usou os
limites restaurados (`1.000.000` instruções, stack `8192` e até `64` estados),
incluiu um log explícito no caminho de complexidade e falhou antes de emitir
esse log.

A falha real ocorria antes do verifier. O UAPI 4.19 conhece somente 72 bytes do
bloco `BPF_PROG_LOAD` de `union bpf_attr`, terminando em
`expected_attach_type`. O libbpf do Android 17 enviava 148 bytes, incluindo os
campos modernos de BTF e line info. `bpf_check_uarg_tail_zero()` rejeitava o
tamanho novo com `-E2BIG`; por isso o programa CLAT de apenas 381 instruções
nem chegava ao verifier.

O patch
`platform/exynos990/patches/extremekrnl/patches/0009-bpf-accept-newer-prog-load-attributes.patch`
mantém a validação estrita para chamadas sem privilégio e para todos os outros
comandos. Em `BPF_PROG_LOAD` privilegiado, aceita no máximo 256 bytes e copia
somente o prefixo que o kernel 4.19 conhece. O kernel `#15` registrou:

```text
BPF: accepting newer BPF_PROG_LOAD attribute tail (148 > 72 bytes)
NetBpfLoad: Loaded object: .../clatd.o, libbpf: 1
NetBpfLoad: success.
init: Service 'bpfloader' ... exited with status 0
```

O aparelho completou o boot. A captura que comprova a correção está em
`out/logs/runtime/logcat-kernel15.log`. Não selecionar manualmente os objetos
CLAT `_4_9` no APEX e não mascarar `reboot_on_failure`: a compatibilidade deve
permanecer no kernel.

### Exynos 990: SystemUI e apps abortando em `selinux_android_setcontext` (2026-10-07)

Depois do primeiro boot funcional, a ausência da SystemUI não era um crash do
APK. Todo filho comum do `zygote64` abortava com:

```text
selinux_android_setcontext(...): Invalid argument
JNI FatalError ... selinux_android_setcontext(...) failed
ksu_selinux_hide: blocked transaction_write from uid=...
```

A regressão veio do KernelSU-Next `v3.2.0-legacy-17-gdd074bc6`. A função
`selinux_hide` substituía a operação de escrita de `/sys/fs/selinux/context` e
devolvia `-EINVAL` para qualquer UID de app sob seccomp. O libselinux usa essa
interface no filho do Zygote, depois de trocar o UID, para validar o contexto
calculado por `seapp_contexts`. Assim a interceptação impedia a especialização
de SystemUI, teclado, Setup Wizard, Relógio e demais aplicativos.

O diagnóstico foi confirmado no aparelho sem alterar a política: executar
`ksud feature set selinux_hide 0` fez a SystemUI iniciar imediatamente em
`u:r:platform_app:s0:c512,c768`, com SELinux ainda `Enforcing`.

A correção permanente está em
`platform/exynos990/patches/extremekrnl/ksu-patches/0001-selinux-hide-allow-zygote-context-validation.patch`.
Ela preserva a página de status falsa do recurso, mas remove a interceptação de
`/sys/fs/selinux/context`. `extremekrnl/customize.sh` aplica separadamente os
patches do submódulo depois de `git submodule update` e inclui seus hashes na
chave do cache do kernel.

O kernel `#16` foi compilado e instalado no aparelho:

- `boot.img`: SHA-256
  `0eaffbf3b34aec0007780e15a7dc1b7c5df885275f6fdc0b3cb62206394cead1`;
- `Image`: SHA-256
  `0d9aeb9737d2a6eaa4e30fcd94cbc8c4228defa018125d7f500948e04e57a57f`;
- backup do kernel `#15`:
  `out/target/y2s/backups/boot-before-systemui16.img`.

Após reiniciar, `sys.boot_completed=1`, SELinux estava `Enforcing` e SystemUI
estava ativa. `selinux_hide` foi reativado (`Value: 1`) e o Relógio foi iniciado
como um novo filho do Zygote; ambos ficaram em
`u:r:platform_app:s0:c512,c768`, sem `Invalid argument`, `JNI FatalError` ou
`blocked transaction_write`. Os registros finais estão em
`out/logs/runtime/systemui16/logcat-kernel16-validation.txt` e
`out/logs/runtime/systemui16/dmesg-kernel16-validation.txt`.

### M21s: recuperação de patch incremental e teste do stack protector (2026-10-07)

O patch `target/m21s/patches/kernel9611/patches/0012-bpf-ringbuf-backport.patch`
aplica limpo na revisão fixada `933cc29fad7b2cfcfd0a529684c7377cbd6cd8cd`.
Uma tentativa interrompida de `git apply` pode deixar somente o novo
`kernel/bpf/ringbuf.c` na árvore incremental; nesse estado o próximo build acusa
`already exists` e aborta. `customize.sh` agora valida esse caso, move o arquivo
órfão temporariamente e reaplica o patch completo somente se todos os demais
hunks passarem no `git apply --check`.

O kernel usa `CONFIG_CC_STACKPROTECTOR_STRONG`. O clang Android 14 usado pelo
checkout recebe `-fuse-ld=lld` também nos probes de compilação sem link; com o
`-Werror` do kernel isso transforma o aviso de argumento não usado em falha.
O patch `0003-clang21-allow-legacy-kernel-initializers.patch` e o
`customize.sh` acrescentam `-Wno-unused-command-line-argument` apenas durante a
compilação, preservando o teste e a opção de stack protector. O mesmo conjunto
ignora somente opções de warning desconhecidas para que o clang 14 não trate as
flags destinadas ao clang 20 como erro. As flags
`-Wno-default-const-init-*` continuam condicionadas ao clang 20 ou mais novo.

Na revisão antiga do `verifier.c`, o backport também precisa preservar o rótulo
`err_release_maps:`. Ele é o destino dos caminhos de erro que liberam os mapas;
removê-lo deixa `goto err_release_maps` sem destino e interrompe a compilação em
`kernel/bpf/verifier.o`.

O método `ZoomView.m(Lcd/b;)V` declara `.locals 20` e reutiliza o registrador
físico de `p0` como constante durante o cálculo da faixa. Por isso o patch de
zoom não pode usar `p0` depois desse ponto: o verificador o vê como inteiro e
produz `VerifyError`. A instância correta da `ZoomView` permanece em
`v2.c`; o patch usa `iget-object v1, v2, Lv9/i;->c:ZoomView` antes do `iput-object`,
preservando a tipagem Smali e a montagem pelo Apktool.

### Donor HIDL do Galaxy A51 para o vibrator do M21s (2026-10-08)

O [dump público do Galaxy A51](https://dumps.tadiphone.dev/dumps/samsung/a51)
foi fixado na branch
`a51nsxx-user-13-TP1A.220624.014-A515FXXU8HWK1-release-keys` (Android 13,
One UI 5.1). O A51 é um dos donors mais próximos do M21s porque usa a mesma
família Exynos 9611; a página da Samsung descreve esse SoC com quatro Cortex-A73
e quatro Cortex-A53.

O conjunto HIDL foi usado somente para a auditoria e o teste manual abaixo;
ele não é mantido como prebuilt nem está ligado à build. Ele continha o
serviço `vendor.samsung.hardware.vibrator@2.2-service`, seu `rc`, o fragmento
VINTF e as bibliotecas `android.hardware.vibrator@1.0` até `@1.3` e
`vendor.samsung.hardware.vibrator@2.0` até `@2.2`. A auditoria contra os
blobs originais do M21s encontrou:

- o mesmo conjunto `DT_NEEDED` no serviço e todas as dependências resolvidas na
  vendor do M21s;
- os mesmos símbolos definidos, com a mesma contagem, no serviço e nas sete
  bibliotecas HIDL;
- ausência de `ldaprb`, `ldaddal`, `paciasp` e `autiasp` em todos os arquivos
  analisados;
- `vendor.samsung.hardware.vibrator@2.2-service.rc` byte a byte igual ao do
  M21s e o mesmo bloco VINTF `ISehVibrator@2.2/default`.

O A51 não deve fornecer `vendor/lib64/hw/vibrator.default.so` nem
`vendor/lib64/libvibrator.so`: eles diferem dos blobs específicos do M21s e
ficaram fora do prebuilt. Também não se deve substituir o `vendor/etc/vintf/manifest.xml`
inteiro; apenas a declaração do HAL é relevante. O donor está preparado para
um teste HIDL controlado, mas ainda não foi instalado no aparelho nem aplicado
ao `customize.sh`.

### Teste do donor A51 aplicado na vendor do M21s (2026-10-08)

O aparelho foi confirmado pelo bootloader `F415FUBS3CWK2` e pelo hardware
`exynos9611`, reiniciado no TWRP e teve a vendor extraída para
`out/manual/m21s-vendor-original-20261008_010246.img` (SHA-256
`70b27d3ddcfdb7950fce0015a0a37cca9551daa4ee6a3f2102767d0e9c8e09ee`). A
vendor foi montada em `rw` no TWRP e recebeu apenas o serviço HIDL A51, o `rc`
e as sete bibliotecas HIDL. O `vibrator.default.so`, o `libvibrator.so` e o
`manifest.xml` original permaneceram intactos; os contexts foram restaurados.

Após o reboot, o serviço A51 ficou ativo e registrou
`vendor.samsung.hardware.vibrator@2.2::ISehVibrator/default` sem crash. O
framework Android 17, porém, procura as instâncias AIDL
`android.hardware.vibrator.IVibrator/default` e
`IVibratorManager/default`; o `VibratorManagerService` terminou com
`vibratorIds=[]` e `MOTOR_NONE`. Portanto, o donor HIDL A51 é carregável no
M21s, mas não resolve a vibração nesta base Android 17 sem uma ponte AIDL ou
um serviço AIDL compatível. Os registros estão em
`out/manual/a51-vibrator-test-20261008_0107` e o rollback individual está em
`out/manual/m21s-vendor-before-a51-20261008_0105`.

### SAIV: doadores opcionais por firmware (2026-10-10)

`unica/patches/saiv/customize.sh` agora valida cada modelo ou diretório antes
de chamar `ADD_TO_WORK_DIR`. O S947B usado como donor declara
`SRIBMQA_aiIQA_V100_FP32.tflite` no `midas_config.json`, mas não entrega esse
arquivo em `vendor/etc/midas`; o G986B alvo também não o possui. A build agora
mantém o modelo do alvo quando existir e registra a ausência quando nenhum dos
firmwares tiver o recurso, em vez de abortar.

As mesmas proteções cobrem os bundles de moiré/aiFiQA, face cluster, AIG,
Photo Editor, pet search, Bixby Vision, document dewarp, Smart Cropping,
textrecognition e SmartScan. Os donors `gts11xx` e `a34xxx` só removem o
modelo atual depois que o conjunto substituto completo foi encontrado. O
script foi validado com `bash -n` e os caminhos presentes/ausentes foram
checados contra os diretórios extraídos em `out/fw` e `prebuilts/samsung`;
nenhuma build foi iniciada nesta auditoria.

### Exynos 990: atividade ociosa do modem e BLE (2026-10-11)

No y2s executando a base S947B, uma captura de 30 segundos com Wi-Fi,
Bluetooth visível e dados móveis desligados ainda registrou 14 ciclos completos
de `s5100_poweron_pcie`/`s5100_poweroff_pcie`. O Bluetooth permaneceu em
`BLE_ON`, com `BeaconManager` e `MCFServer` registrados. Em modo avião ambos
os grupos de eventos cessaram. Desativar apenas `ble_scan_always_enabled` não
interrompeu os ciclos do modem, portanto os dois comportamentos foram tratados
separadamente.

O framework Android 17 enviava cada elemento de
`setSignalStrengthReportingCriteria()` ao HAL HIDL 1.4/1.5 reutilizando o mesmo
serial. O RIL Samsung respondia a cada chamada, e todas as respostas depois da
primeira apareciam como `processResponse: Unexpected response!`. O módulo
`platform/exynos990/patches/framework_compat` agora encaminha somente o
primeiro critério nas rotas HIDL, seguindo o comportamento da ponte de
compatibilidade AIDL/HIDL do AOSP, e preserva a lista completa na rota AIDL. O
patch passou em `git apply --check` contra o `telephony-common.jar` decodificado
do y2s e o JAR modificado recompilou com Apktool 3.0.3.

Os perfis y2s e y2slte deixaram de declarar `satellite_carrier`, recurso que
não existe no framework original G986B. O teste da build instalada confirmou
que as respostas RIL duplicadas desapareceram, mas o `SatelliteController`
continua consultando a configuração NTN quando recebe atualizações da rede;
os próprios logs confirmam `satellite is disabled`. Essas consultas são uma
consequência das notificações do modem, não a origem das ativações PCIe.

Uma nova captura de 30 segundos com Wi-Fi, dados e Bluetooth desligados
registrou 15 ciclos PCIe e revelou o gatilho restante: o APK persistente
`com.sec.intc` da S947B solicita `IPC_MISC_CP_METRIC` a cada três segundos. O
RIL Exynos 990 devolve `error: 6`, o iNTC repete imediatamente e as duas
tentativas acordam o enlace do modem. Esse APK não existe nas firmwares
originais G985F/G986B disponíveis em `out/fw`. O debloat específico
`target/y2s/debloat.sh` remove o iNTC e seu XML de permissões, mas mantém
`AutoHotspotMDE` e seus três XMLs de configuração para preservar o Quick Share.
Os pacotes de hotspot comum
(`SmartTethering`, `TetheringAutomation` e `UnifiedTetheringProvision`)
permanecem presentes. Os logs dos testes estão em
`out/target/y2s/idle-patch-validation-2026-10-11_2052`.

### HMA: ComputerEngine da FW S947B (2026-10-10)

O patch `unica/mods/hma/smali/system/framework/services.jar/0001-Introduce-HideAppListUtils.patch`
falhava no `ComputerEngine.getApplicationInfoInternal()` porque a FW atual
usa `v1/v2` na chamada a `resolveInternalPackageName()` e mantém
`mPackages` em `v1`; o patch antigo esperava `v0/v1` e `mPackages` em `v0`.
O contexto do hunk foi atualizado para o layout Smali atual. Os demais hunks
de `services.jar`, incluindo `ActivityStarter`, e o patch correspondente de
`framework.jar` passam em `git apply --check` contra os APKs/JARs decodificados
do alvo y2s.

### Auditoria da sequência pós-HMA na FW S947B (2026-10-10)

O `make_rom-20260928_204924.log` foi usado como referência para a ordem dos
módulos depois do HMA: Keybox, KnoxPatch, Monotype, Multi-user, Outdoor,
Paradigm/PIF, Settings, Setup Wizard, Misc tweaks, wallpapers, fallback do
mapper gráfico e compatibilidade de geração de superfície. A sequência foi
reproduzida em cópias temporárias dos artefatos decodificados atuais, sem
iniciar uma nova build.

O hunk do Knox ICD em `UserManagerService.smali` foi atualizado para os
registradores `v8/v9/v13` usados pela S947B; o patch completo agora passa junto
com os dois patches seguintes do Knox. O patch ASKS também foi ajustado para o
bloco atual que mantém a constante `"true"` em `v0`; os três checks de
`persist.sys.unica.asks` passam na ordem correta.

Os patches estáticos de Keybox, Multi-user, PIF, Settings, MultiSound,
OMCAgent e os três patches do SystemUI passaram. O patch de compactação de
aplicativos não corresponde ao layout atual de `CachedAppOptimizer` e
`DynamicHiddenApp`, mas `unica/mods/tweaks/customize.sh` já o trata como
opcional com `|| true`, portanto ele não interrompe a build. Os patches
dinâmicos de Knox, Monotype, Outdoor, PIN, PIF, Settings e Setup Wizard tiveram
seus métodos e literais encontrados e aplicados na cópia de auditoria. O
fallback de `libui.so` ainda encontra as duas sequências originais; o patch de
`libgui.so` é corretamente ignorado no SDK 37 pela própria condição do módulo.

### Exynos 990: soft reboot por perda do RenderEngine Vulkan (2026-10-16)

Os soft reboots observados no y2s não reiniciavam o kernel: o uptime do kernel
continuava acima de 45 horas, enquanto `surfaceflinger`, `zygote64` e
`system_server` tinham sido recriados. Os registros Samsung preservados em
`/data/log/prev_dump.log` e `dumpstate_sys_native.zip` provaram dois eventos
iguais, em 15 de outubro às 06:31:26 e em 16 de outubro às 06:48:53. Em ambos,
o `surfaceflinger` abortou na thread `RenderEngine` com:

```text
VK_ERROR_DEVICE_LOST (non-protected): No details:
VK_EXT_device_fault not available/enabled.
```

O backtrace passa por `GrVkPrimaryCommandBuffer::finished`,
`GaneshVkRenderEngine::flushAndSubmit` e `SkiaRenderEngine::drawLayersInternal`.
No segundo evento, o dump mostra a composição da janela do Spotify, StatusBar
e NotificationShade com várias regiões de blur imediatamente antes da perda
do dispositivo Mali-G77. O `init` então executa o `onrestart` do
SurfaceFlinger, mata o zygote e recria todo o framework, produzindo a aparência
de soft reboot.

O crash do `com.samsung.android.kgclient` não foi o gatilho. Ele ocorre por
ausência de contexto SELinux para UID 5959, inclusive em horários sem
`SYSTEM_RESTART`; no evento de 16 de outubro ele reapareceu depois do reinício,
quando os aplicativos estavam sendo recriados. O modo deKnox para Android 16+
já desativa KnoxGuard em `services.jar` e agora também remove o APK órfão, os
dois XMLs de permissões e seu registro em `system/etc/sysconfig`, evitando os
tombstones sem ampliar a política SELinux. Na instalação existente, até
`pm disable-user` executado como root é recusado porque o Package Manager marca
o KnoxGuard como pacote protegido; a remoção deve entrar pela imagem `system`.

`ro.hwui.use_vulkan=` e `persist.sys.unica.vulkan=false` afetam o HWUI dos
aplicativos, não o RenderEngine do SurfaceFlinger. O `dumpsys SurfaceFlinger`
continuava mostrando `RE Vulkan (Ganesh)`. O patch Exynos 990 agora define
`debug.renderengine.backend=skiaglthreaded` antes da inicialização do
compositor. Isso mantém o RenderEngine moderno e encadeado, troca somente a
composição do sistema para Skia OpenGL ES e preserva Vulkan para aplicativos.

### Exynos 990: aquecimento causado pelo hotword do Google (2026-10-12)

Após instalar a build atualizada no y2s, o iNTC estava ausente como esperado.
O AutoHotspotMDE deve permanecer instalado para o Quick Share e não é o mesmo
componente que causava a atividade em repouso. A
temperatura não estava em faixa de throttling, mas o `AudioIn` permanecia com
wakelock contínuo. O responsável era o processo isolado
`GsaHotwordDetectionService` do Google: `dumpsys voiceinteraction` mostrava
`DetectorType=trusted_hotword_software`, nenhum `Enrolled KeyphraseSoundModel`
e `mPerformingSoftwareHotwordDetection=true`. O processo consumia entre 7% e
14% de CPU, enquanto `audioserver` e o serviço de áudio consumiam mais alguns
pontos percentuais.

O HAL SoundTrigger Samsung SLSI estava registrado, mas nenhum modelo havia sido
carregado nele. A tela `HOTWORD_DETECTION_SETTINGS` ainda aguardava a escolha
inicial entre `Não` e `Começar`; mesmo assim, o Google mantinha captura PCM a
16 kHz em `/dev/snd/pcmC0D18c`. Selecionar `Não` interrompeu imediatamente a
captura: `Wake Locks: size=0`, `mPerformingSoftwareHotwordDetection=false` e os
processos de Google e áudio ficaram em 0% nas três amostras seguintes. Pesquisa
e Assistente acionados manualmente continuam disponíveis.

O módulo `platform/exynos990/patches/stock_blobs` agora remove todas as pastas
`HotwordEnrollment*` herdadas da source antes de importar o par do firmware
alvo. A source S947B traz Ex6 Wideband para Android 17 e o G986B traz Ex3 para
Cortex-M4; anteriormente os Ex6 permaneciam na imagem e o Package Manager os
rejeitava como pacotes duplicados. Os modelos Ex6 não foram instalados no y2s,
pois foram produzidos para outra geração de DSP. Os registros da investigação
estão em `out/target/y2s/warm-diagnostics-2026-10-12`.
### Exynos 990: aquecimento e drenagem por reinício contínuo do `traced`

No port Android 17 para `y2s`/`y2slte`, o `traced` do Perfetto encerrava a
cada aproximadamente 15 segundos com
`Failed to create vsock://-1:2010 (errno: 97, Address family not supported by protocol)`.
O init reiniciava o processo e acionava `flags_health_check` como processo
atualizável em falha. O kernel instalado confirmou `# CONFIG_VSOCKETS is not set`.

O primeiro teste ativou somente `CONFIG_VSOCKETS=y`, mas a imagem instalada em
14/10/2026 demonstrou que isso apenas compilava o código comum: não havia uma
entrada VSOCK em `/proc/net/protocols` e o erro `EAFNOSUPPORT` permaneceu. Neste
kernel 4.19, `sock_register(AF_VSOCK)` só é chamado por
`vsock_core_init()` quando um transporte é inicializado. O patch
`platform/exynos990/patches/extremekrnl/patches/0010-enable-vsock-for-android-perfetto.patch`
agora ativa `CONFIG_VIRTUALIZATION=y`, `CONFIG_VSOCKETS=y` e
`CONFIG_VHOST_VSOCK=y`; `VIRTUALIZATION` torna o menu vhost visível e o último
seleciona o transporte comum que registra a família de sockets usada pelo
listener host do `traced`. A primeira compilação com apenas as duas opções
VSOCK demonstrou a dependência: o Kconfig descartou silenciosamente
`VHOST_VSOCK` enquanto `VIRTUALIZATION` estava desativado. `CONFIG_EVENTFD=y`,
outra dependência do vhost, já existe no `exynos9830_defconfig`. A alteração do
patchset invalida a chave do cache do kernel automaticamente.

Para validar uma instalação ainda sem esse kernel, pode-se interromper o loop
temporariamente com `adb shell setprop persist.traced.enable 0`. Após instalar
o kernel com VSOCKETS, restaurar com `adb shell setprop persist.traced.enable 1`
e confirmar que `getprop init.svc.traced` permanece `running`, sem novos eventos
`sys.init.updatable_crashing_process_name=traced`.

No mesmo diagnóstico, `com.samsung.cmh` disparava indexação de faces e o
`com.samsung.ipservice` chegava a consumir dezenas de por cento de CPU. A
varredura BLE de `com.samsung.android.mdx.kit` também permanecia ativa por
horas. Para o teste reversível foram usados `pm disable-user --user 0
com.samsung.cmh`, `pm disable-user --user 0 com.samsung.android.mdx.kit`,
`settings put system nearby_scanning_enabled 0` e
`settings put global ble_scan_always_enabled 0`. O cliente do Galaxy Fit,
`com.samsung.accessory`, não foi desativado. Em uma janela limpa de 45 segundos,
a varredura Bluetooth caiu para 0 ms e não houve nova execução do NPU/CMH.
Como o Link to Windows já é reduzido a stub nesta ROM, o debloat específico
`target/y2s/debloat.sh` também remove `MdxKitService` e seus XMLs; isso não
remove o cliente do relógio. Com o CMH suspenso, a Samsung Camera ainda abriu
normalmente e permaneceu ativa sem exceção fatal. A remoção definitiva do CMH
deve aguardar um teste mais longo das funções de busca e histórias da Galeria.

Na build instalada em 14/10/2026, a varredura contínua restante foi atribuída
pelas estatísticas do Bluetooth a `com.samsung.android.mcfds` (UID 10106) e ao
Google Play Services (UID 10298). O MCFDeviceSync manteve o scan pelo tempo
inteiro de atividade e ligou o serviço `com.samsung.android.mcfserver`; após
`pm disable-user --user 0 com.samsung.android.mcfds`, o cliente e o scan do
MCFServer desapareceram. Restou apenas `nearby_presence` do Google em modo
oportunista, com duty cycle de 0%. Em uma janela comparável de 45 segundos, o
AP caiu de 41,8 para 38,7 graus Celsius e a carga agregada caiu. O
`SamsungMultiConnectivity` e o cliente `com.samsung.accessory` permaneceram
instalados. Esse resultado identifica o gatilho, mas não justifica remover o
MCFDeviceSync: o pacote também fornece continuidade, handoff e Auto Switch. A
correção definitiva deve desativar somente a condição que solicita o scan
contínuo; `target/y2s/debloat.sh` mantém o pacote e seus XMLs enquanto essa
condição é investigada.

O APK MCFDeviceSync original do G986B (`1.2.10.24`, SDK 30) foi comparado com
o da source S947B (`4.6.12.12`, SDK 31), mas o Package Manager recusou o teste
como downgrade e o KernelSU da boot anterior não executou a sobreposição de
teste. A conclusão acima se baseia apenas na desativação reversível do cliente
moderno. O módulo temporário `mcfds_g986b_test_v2` foi deixado marcado com
`disable` no aparelho para nunca ser aplicado por engano.

Uma captura posterior, feita com os dados do `MCFDeviceSync` limpos e o pacote
habilitado por somente 25 segundos, localizou a condição exata. O app iniciou
dois scanners BLE de duty cycle baixo (5%): `Account`, necessário para a
continuidade da conta Samsung, e `Nearby`. A inicialização registrou
`nearbyscanning=false`, mas ainda criou o `NearbyHandler` porque
`SettingsHelper.isSupportTvSignin()` retornou `true`. Esse método lê o metadata
`com.samsung.android.mcfds.support_remote_signin=true` do
`/system/priv-app/SamsungAccount/SamsungAccount.apk`; em seguida o handler abre
uma requisição `NearbyScanRequest{appId=8, type=0}`. O mesmo metadata e a mesma
decisão existem nos APKs originais do G986B, portanto o recurso de login remoto
em TVs não foi inventado pelo port nem depende do `AmbientDetect` acrescentado
na versão moderna.

No aparelho, o scanner `Nearby` encontrou uma Samsung TV, publicou o contexto
de TV e iniciou tentativas BLE CoC/GATT para ela e para endereços rotativos. É
essa sequência que torna o MCF ativo mesmo quando sua máquina de estados aparece
como `IDLE`; o estado indica ausência de uma sessão de usuário, não ausência de
descoberta em segundo plano. A captura também descartou `AmbientDetect` como
gatilho desse caso. Desabilitar novamente `com.samsung.android.mcfds` encerrou
os dois scans, e o pacote foi deixado desabilitado após o teste. As evidências
estão em
`out/target/y2s/runtime-diagnostics-20261014/mcf-clean-enable-20261014`.

A política de descoberta não regrediu por causa da versão nova do APK: tanto o
MCFDeviceSync antigo quanto o moderno usam o modo Samsung customizado `100`,
intervalo `0xc30` e janela `0xa0` para a política `mode=0`, equivalente ao duty
cycle de aproximadamente 5% mostrado pelo Bluetooth Manager. Portar o scanner
antigo manteria a mesma busca persistente. O custo adicional observado aparece
quando os anúncios da TV geram tentativas de conexão, não por uma diferença no
intervalo básico do scan.

A correção seletiva foi implementada fora dos dois APKs atualizáveis em
`platform/exynos990/patches/framework_compat/smali/system/framework/framework.jar/0001-disable-tv-signin-mcf-scan.patch`.
No `ApplicationPackageManager`, toda consulta ao `ApplicationInfo` de
`com.osp.app.signin` clona o objeto e seu `Bundle` e substitui somente
`com.samsung.android.mcfds.support_remote_signin` por `false` quando
`ro.unica.device=y2s`. O target y2slte também publica esse codename. Como a
alteração está no framework da ROM, atualizações do Samsung Account e do
MCFDeviceSync não restauram a flag. O cache original do PackageManager não é
modificado.

Isso impede somente a criação do handler de appId 8 e preserva o scanner
`Account`, Auto Switch, handoff, clipboard e as demais funções de continuidade.
Remover todo o MCFDeviceSync continua inadequado. O patch passou em
`git apply --check`, e uma cópia do `framework.jar` com ele aplicado foi
recompilada com Apktool 3.0.3 sem erro. Nenhuma build completa foi iniciada.

A validação final do kernel recompilado confirmou na configuração em execução
`CONFIG_VIRTUALIZATION=y`, `CONFIG_VSOCKETS=y`, `CONFIG_VHOST_VSOCK=y`,
`CONFIG_VHOST=y` e `CONFIG_VIRTIO_VSOCKETS_COMMON=y`. `AF_VSOCK` passou a
aparecer em `/proc/net/protocols`. Depois de definir
`persist.traced.enable=1`, `traced` e `traced_probes` conservaram os mesmos PIDs
por 31 segundos; o log registrou o listener em
`/dev/socket/traced_producer` e `/dev/socket/traced_consumer`, sem
`EAFNOSUPPORT`, saída do serviço ou sinalização de processo atualizável em
crash. A boot validada tem SHA-256
`72c78e10d0b9b4a4d0418a457c5deb8c9153bd105ff9a03e214077d343883b66` e foi
copiada para `out/target/y2s/work_dir/kernel/boot.img`.

Durante esse teste, `statsd` abriu automaticamente a sessão Perfetto
`java_heap_profile_oom`, com buffers configurados para até 510128 KiB, enquanto
o usuário ainda estava bloqueado e os aplicativos processavam o pós-boot. Para
evitar prolongar essa carga térmica de diagnóstico, o teste terminou com
`persist.traced.enable=0`; isso é somente o estado runtime do aparelho e não
remove a correção do kernel. As evidências estão em
`out/target/y2s/runtime-diagnostics-20261014/traced-vhost-start.txt` e
`traced-vhost-after-30s.txt`.

A mesma instalação atualizou `system`, mas manteve `product` antigo: a
propriedade `persist.bluetooth.a2dp_offload.disabled=true` existe no
`work_dir/product/etc/build.prop`, porém `dumpsys bluetooth_manager` ainda
mostra `A2dpOffloadEnabled: true` no aparelho. O valor inserido por `resetprop`
ficou visível apenas na área lida pelo root e não alterou o serviço Bluetooth.
Portanto, o teste da central automotiva continua pendente até que a imagem
`product` da build seja realmente instalada; atualizar somente `system` e
`boot` não aplica essa correção.

### y2s: auditoria de consumo ocioso e consultas NTN (2026-10-16)

Uma nova captura do aparelho `SM-G985F`/`y2s`, preservada em
`out/target/y2s/runtime-diagnostics-20261016`, mostrou o sistema com mais de um
dia de uptime, sem throttling térmico e com CPU total próxima de 6% durante a
primeira amostra. A load average próxima de 15 não representava quinze CPUs
ocupadas: havia exatamente quinze threads permanentes do kernel em estado `D`
(`tz_worker_thread`, `ree_time`, `tz_iwlog_thread`, `tz_iwsock`,
`exynos_gmc_thread` e `ksu_selinux_pol`), que entram no cálculo de load mesmo
sem consumir CPU continuamente.

O `MCFDeviceSync` havia ficado desabilitado após o diagnóstico anterior. Nesse
estado, o `system_server` tentava abrir `McfDeviceSyncService` a cada três
segundos e produziu 6.181 falhas no buffer acumulado. O pacote foi reabilitado
no aparelho; as tentativas e os erros `bindMcf - failed with reason: 4`
cessaram. A build instalada ainda não contém o patch de metadata do framework,
portanto voltou a apresentar os dois scans de duty cycle 5% (`Account` e
`Nearby`) e o scan do `MCFServer`. A próxima build aplica
`0001-disable-tv-signin-mcf-scan.patch`, preserva o pacote habilitado e elimina
somente o handler `Nearby` acionado pelo login remoto de TVs.

Uma janela limpa de 25 segundos revelou a atividade restante mais repetitiva:
203 mensagens do `SatelliteController`, incluindo 46 tentativas de obter o
parser `satellite`, embora o RIL confirme que NTN está desabilitado. Foram
registradas somente duas notificações físicas do canal celular nessa janela;
as 13 chamadas `getAllCellInfo()` vieram da thread `SLocationService` e não
formaram o ciclo intenso sugerido pelo buffer histórico. O módulo
`platform/exynos990/patches/framework_compat` agora aplica
`0002-disable-unsupported-satellite-lookups.patch` ao `telephony-common.jar`.
Nos Exynos 990, que não possuem rádio satélite, o patch devolve os valores
terrestres antes das consultas de configuração NTN. A aplicação do patch e a
recompilação isolada do JAR com Apktool 3.0.3 foram validadas.

Também foram observadas rajadas de leitura do ADC pelo serviço térmico e erros
de I2C do controlador MFC de carregamento sem fio. Elas serão avaliadas em uma
janela desconectada do USB antes de qualquer alteração na vendor; a captura
atual foi feita a 100% e alimentada por USB, portanto não permite medir a
corrente real de repouso. Não houve `FATAL EXCEPTION` nem ANR novo.

