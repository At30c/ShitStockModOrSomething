# FotaAgent (com.wssyncmldm) as the ROM updater.
#
# The stock app stays in the ROM (unica/debloat.sh no longer removes it). This
# module only patches it, removing every path that reaches Samsung:
#   0001 FOTA REST API (device registration, push registration, version.xml
#        polling, heartbeat, campaigns)
#   0002 OMA-DM sessions with the Samsung DM server
#   0003 update result reports (UpdateReporter)
#   0004 Samsung Analytics uploads, terms registration and policy fetch
#   0005 DiagMon crash/log reporting
#   0006 FCM and Samsung SPP push registration
#   0009 FCM auto-init (it would fetch a Firebase token from Google)
# and adds the ROM updater entry point:
#   0007 keep the download descriptor URL of jobs the ROM creates
#   0008 io.unica.fota.UpdateReceiver (DUMP-protected) starts a FUMO job from
#        a download descriptor URL; the descriptor carries the changelog.
#   0010 jobs without a DM Exec command are DownloadAndUpdate
#   0011 no installNotifyURI in the descriptor: skip the download report
#   0012 report the (never registered) device as registered, or the scheduler
#        resets the app state and drops a downloaded update
#   0013 do not refuse to install because the binary is not "official"
#   0014 write /cache/recovery/openrecoveryscript ("install <pkg>", "reboot"):
#        TWRP reads its startup commands before /cache is mounted and never
#        sees the --update_package that RecoverySystem writes
#   0015 report device registration as done, so boot resumes a pending
#        update job and reads the install result (/cache/fota/fota.status)
#   0016 boot resume keeps jobs without a DM Exec command instead of dropping
#        them, so the install result is processed
#   0017 after the install result, finish the job directly instead of
#        waiting for the DM report session that 0002 blocks: delete the update
#        package and run IDMFumoTaskDmFinish, which closes the job, stops the
#        "connecting to server" notification and sends SCHEDULE_FINISH
#        (FINISH_AND_EXECUTE would wait for a next package and keep the job)
#   0018 io.unica.fota.UpdateChecker (src/, rebuilt with src/build.sh) reads
#        the ROM update manifest instead of the Samsung servers, for the
#        periodic check (5-10 minutes after the app registers, then daily)
#        and for the Settings "check for updates" button.
#        io.unica.fota.PartProxy serves packages published in parts (over
#        the 2 GiB GitHub release asset limit) as one file on 127.0.0.1
#
# Update manifest (ro.unica.ota.manifest, JSON; see UpdateChecker.java):
#   { "device": "y2s", "builds": [
#       { "version": "2.0.2", "timestamp": <ro.unica.timestamp>, "dd": "<url>" },
#       { "version": "2.0.2", "timestamp": <ro.unica.timestamp>,
#         "base_timestamp": <source build timestamp>, "dd": "<url>" } ] }
#   Entries with base_timestamp are incremental packages. "dd" may be
#   relative to the manifest URL. The package URL inside the descriptor can
#   be on any host and may redirect. Packages over the GitHub release asset
#   limit (under 2 GiB) are published in parts (see PartProxy).
#   scripts/fota_release.py writes the descriptors, parts and manifest from
#   the build zips and uploads them to a release.
#
# Update server requirements (download descriptor, OMA DD 1.0):
#   - type application/octet-stream, and the package must be served with the
#     same Content-Type (DlAgent rejects other types: abort 505);
#   - installParam must carry MD5=<package md5> (checked after download);
#   - leave installNotifyURI out (nothing is reported back);
#   - description (HTML when descriptionType=html) and summaryDescription
#     are the changelog shown by the app.
#
# Never disable this module while FotaAgent ships: the unpatched app registers
# the device with Samsung on first boot.

if [ ! -f "$WORK_DIR/system/system/priv-app/FotaAgent/FotaAgent.apk" ]; then
    ABORT "FotaAgent.apk not found in the work dir"
fi

# FotaAgent checks the package with RecoverySystem.verifyPackage(), which only
# accepts keys listed in otacerts.zip. Replace Samsung's keys with the
# certificate that signs this ROM's flashable zips (build_full_ota_zip.sh), so
# ROM updates verify and Samsung OTA packages do not.
LOG_STEP_IN "- Replacing otacerts.zip with the ROM signing certificate"

OTA_CERT="$SRC_DIR/security/aosp_testkey.x509.pem"
$ROM_IS_OFFICIAL && OTA_CERT="$SRC_DIR/security/unica_ota.x509.pem"
[ -f "$OTA_CERT" ] || ABORT "File not found: ${OTA_CERT//$SRC_DIR\//}"

OTACERTS_TMP="$(mktemp -d)"
cp -a "$OTA_CERT" "$OTACERTS_TMP/rom_ota.x509.pem"
touch -d "2009-01-01 00:00:00" "$OTACERTS_TMP/rom_ota.x509.pem"
(cd "$OTACERTS_TMP" && zip -q -X -D "otacerts.zip" "rom_ota.x509.pem") || \
    ABORT "Failed to create otacerts.zip"
mkdir -p "$WORK_DIR/system/system/etc/security"
mv -f "$OTACERTS_TMP/otacerts.zip" "$WORK_DIR/system/system/etc/security/otacerts.zip"
rm -rf "$OTACERTS_TMP"
SET_METADATA "system" "system/etc/security/otacerts.zip" 0 0 644 "u:object_r:system_file:s0"

unset OTA_CERT OTACERTS_TMP

LOG_STEP_OUT

# Where UpdateChecker looks for ROM updates. Override with
# ROM_OTA_MANIFEST_URL; an empty value disables update checks.
ROM_OTA_MANIFEST_URL="${ROM_OTA_MANIFEST_URL-https://github.com/At30c/ShitStockModOrSomething/releases/latest/download/ota-$TARGET_CODENAME.json}"
LOG "- Update manifest: ${ROM_OTA_MANIFEST_URL:-(disabled)}"
SET_PROP "system" "ro.unica.ota.manifest" "$ROM_OTA_MANIFEST_URL"
if ! grep -q "^ro.unica.ota.manifest " "$WORK_DIR/system/system/etc/selinux/plat_property_contexts"; then
    echo "ro.unica.ota.manifest u:object_r:build_prop:s0 exact string" >> "$WORK_DIR/system/system/etc/selinux/plat_property_contexts"
fi
