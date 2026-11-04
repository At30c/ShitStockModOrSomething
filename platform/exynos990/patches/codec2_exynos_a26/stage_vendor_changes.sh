#!/usr/bin/env bash
# Stages the A26 Exynos Codec2 HAL as a change tree for
# scripts/repack_vendor_dd.sh.  Run build.sh first.
#
#   stage_vendor_changes.sh <changes-dir>
#
# Layout on the device:
#   /vendor/bin/hw/samsung.hardware.media.c2@1.2-service   instance "exynos0"
#   /vendor/lib64/                                         A26 chain + shim (renamed, see build.sh)
#   /vendor/etc/init/samsung.hardware.media.c2@1.2-service.rc
#   /vendor/etc/vintf/manifest/sec_c2_manifest_default.xml c2@1.2::IComponentStore/{default,exynos0}
#   /vendor/etc/media_codecs_c2.xml                        validated decoders only
#   /vendor/etc/seccomp_policy/codec2.vendor.{base,ext}.policy
#
# The A26 libraries whose names collide with the 990 copies used by the
# software store (samsung.software.media.c2, instance "default", c2.sec.*
# audio codecs) are renamed by build.sh, so both stores share /vendor/lib64.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?changes dir}"
PREBUILT="$ROOT/prebuilt/vendor"
[[ -f "$PREBUILT/bin/hw/samsung.hardware.media.c2@1.2-service" ]] || {
    echo "run build.sh first" >&2; exit 1; }

rm -rf "$OUT"
V="$OUT/vendor"
mkdir -p "$V/bin/hw" "$V/lib64" "$V/etc/init" "$V/etc/vintf/manifest" "$V/etc/seccomp_policy"

SERVICE="$V/bin/hw/samsung.hardware.media.c2@1.2-service"
cp "$PREBUILT/bin/hw/samsung.hardware.media.c2@1.2-service" "$SERVICE"
# Register as "exynos0" instead of "default": "default" stays with the 990
# software store.  The 7-character SSO string is built with two overlapping
# 32-bit stores ("defa" at +0, "ault" at +3); "exyn" + "nos0" gives "exynos0".
python3 - "$SERVICE" <<'PY'
import struct, sys
path = sys.argv[1]
data = bytearray(open(path, "rb").read())
def insn(*words):
    return b"".join(struct.pack("<I", w) for w in words)
# mov w9,#0x6564 ; mov w10,#0x7561 ; <x> ; movk w9,#0x6166,lsl16 ; movk w10,#0x746c,lsl16
old = [0x528CAC89, 0x528EAC2A, 0x72AC2CC9, 0x72AE8D8A]
new = [0x528F0CA9, 0x528DEDCA, 0x72ADCF29, 0x72A60E6A]
first = insn(old[0], old[1])
pos = data.find(first)
if pos < 0 or data.find(first, pos + 1) >= 0:
    sys.exit("instance-name pattern not found exactly once")
tail = data.find(insn(old[2], old[3]), pos, pos + 32)
if tail < 0:
    sys.exit("instance-name movk pair not found")
data[pos:pos + 8] = insn(new[0], new[1])
data[tail:tail + 8] = insn(new[2], new[3])
open(path, "wb").write(data)
PY
chmod 755 "$SERVICE"

for lib in "$PREBUILT"/lib64/*.so; do
    cp "$lib" "$V/lib64/"
done
chmod 644 "$V"/lib64/*.so
cp "$PREBUILT"/etc/seccomp_policy/codec2.vendor.*.policy "$V/etc/seccomp_policy/"
cp "$ROOT/vendor/etc/media_codecs_c2.xml" "$V/etc/media_codecs_c2.xml"
chmod 644 "$V"/etc/seccomp_policy/* "$V/etc/media_codecs_c2.xml"

cat > "$V/etc/init/samsung.hardware.media.c2@1.2-service.rc" <<'EOF'
service vendor.exynos-media-c2-hal-1-2 /vendor/bin/hw/samsung.hardware.media.c2@1.2-service
    class hal
    user mediacodec
    group camera mediadrm drmrpc
    ioprio rt 4
    task_profiles ProcessCapacityHigh
EOF

# Samsung's fragment declares android.hardware.media.c2 with override="true",
# which drops every other fragment's declaration of the same HAL, so the
# exynos0 instance has to live in this fragment.  The software store keeps
# registering "default" at 1.0, which a 1.2 declaration covers.
cat > "$V/etc/vintf/manifest/sec_c2_manifest_default.xml" <<'EOF'
<manifest version="1.0" type="device">
<!-- IComponentStore: default = samsung.software.media.c2 (1.0),
     exynos0 = A26 Exynos hardware store (1.2) -->
   <hal format="hidl" override="true">
        <name>android.hardware.media.c2</name>
        <transport>hwbinder</transport>
        <version>1.2</version>
        <interface>
            <name>IComponentStore</name>
            <instance>default</instance>
            <instance>exynos0</instance>
        </interface>
   </hal>
</manifest>
EOF
chmod 644 "$V/etc/init/samsung.hardware.media.c2@1.2-service.rc" \
    "$V/etc/vintf/manifest/sec_c2_manifest_default.xml"

{
    echo "vendor/bin/hw/samsung.hardware.media.c2@1.2-service 0 2000 0755"
    for f in "$V"/lib64/*.so; do echo "vendor/lib64/$(basename "$f") 0 0 0644"; done
    echo "vendor/etc/init/samsung.hardware.media.c2@1.2-service.rc 0 0 0644"
    echo "vendor/etc/vintf/manifest/sec_c2_manifest_default.xml 0 0 0644"
    echo "vendor/etc/media_codecs_c2.xml 0 0 0644"
    echo "vendor/etc/seccomp_policy/codec2.vendor.base.policy 0 0 0644"
    echo "vendor/etc/seccomp_policy/codec2.vendor.ext.policy 0 0 0644"
} > "$OUT/fs_config"

cat > "$OUT/file_contexts" <<'EOF'
/vendor/bin/hw/samsung\.hardware\.media\.c2@1\.2-service u:object_r:mediacodec_exec:s0
/vendor/etc/init/samsung\.hardware\.media\.c2@1\.2-service\.rc u:object_r:vendor_configs_file:s0
/vendor/etc/vintf/manifest/sec_c2_manifest_default\.xml u:object_r:vendor_configs_file:s0
/vendor/etc/media_codecs_c2\.xml u:object_r:vendor_configs_file:s0
/vendor/etc/seccomp_policy/codec2\.vendor\.base\.policy u:object_r:vendor_configs_file:s0
/vendor/etc/seccomp_policy/codec2\.vendor\.ext\.policy u:object_r:vendor_configs_file:s0
EOF
for f in "$V"/lib64/*.so; do
    echo "/vendor/lib64/$(basename "$f" | sed 's/\./\\./g') u:object_r:vendor_file:s0"
done >> "$OUT/file_contexts"
echo "Staged vendor changes in $OUT"
