#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/../../../.." && pwd)"
GRAPHICS_ROOT="$ROOT/../graphics_allocator_bridge"
OUTPUT="${1:-$REPO/prebuilts/exynos990/composer3_hwc2_bridge/ksu-composer3_hwc2_bridge.zip}"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/composer3-ksu.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

for file in \
    "$ROOT/module.prop" \
    "$REPO/prebuilts/exynos990/composer3_hwc2_bridge/vendor/bin/hw/android.hardware.graphics.composer3-service.exynos990" \
    "$REPO/prebuilts/exynos990/composer3_hwc2_bridge/vendor/lib64/libexynos990_composer3_contract.so" \
    "$REPO/prebuilts/exynos990/graphics_allocator_bridge/vendor/lib64/hw/mapper.exynos990_compat.so" \
    "$ROOT/vendor/etc/init/android.hardware.graphics.composer3-service.exynos990.rc" \
    "$ROOT/vendor/etc/init/android.hardware.graphics.composer@2.3-service.rc" \
    "$ROOT/vendor/etc/vintf/manifest/android.hardware.graphics.composer3-exynos990.xml"; do
    [ -f "$file" ] || { echo "Missing Composer3 module file: $file" >&2; exit 1; }
done

mkdir -p "$STAGE/system/vendor"
cp -a "$REPO/prebuilts/exynos990/composer3_hwc2_bridge/vendor/." "$STAGE/system/vendor/"
mkdir -p "$STAGE/system/vendor/lib64/hw"
cp -a "$REPO/prebuilts/exynos990/graphics_allocator_bridge/vendor/lib64/hw/mapper.exynos990_compat.so" \
    "$STAGE/system/vendor/lib64/hw/mapper.exynos990_compat.so"
cp -a "$ROOT/vendor/." "$STAGE/system/vendor/"

# Hide the old global allocator registration.  The files are bind-mounted by
# Magic Mount before vendor services are started; the empty init fragment and
# manifest keep the stock AIDL allocator from being registered globally while
# the HIDL allocator/mapper remain available to Camera and ImageReader.
mkdir -p "$STAGE/system/vendor/etc/init" "$STAGE/system/vendor/etc/vintf/manifest"
cat > "$STAGE/system/vendor/etc/init/android.hardware.graphics.allocator-V2-service.exynos990.rc" <<'EOF'
# Disabled for the private Composer3 mapper test. Camera keeps HIDL allocator.
EOF
cat > "$STAGE/system/vendor/etc/vintf/manifest/android.hardware.graphics.allocator-exynos990.xml" <<'EOF'
<manifest version="1.0" type="device" />
EOF
cp -a "$ROOT/module.prop" "$STAGE/module.prop"

cat > "$STAGE/customize.sh" <<'EOF'
SKIPUNZIP=0
EOF

cat > "$STAGE/post-fs-data.sh" <<'EOF'
#!/system/bin/sh
# ZIP extraction cannot retain SELinux xattrs.  Meta Magic Mount subsequently
# bind-mounts this source at /vendor, so label the source before that mount.
SERVICE="${0%/*}/system/vendor/bin/hw/android.hardware.graphics.composer3-service.exynos990"
if [ -f "$SERVICE" ]; then
    chown 0:2000 "$SERVICE"
    chmod 0755 "$SERVICE"
    chcon u:object_r:hal_graphics_composer_default_exec:s0 "$SERVICE"
fi
# ZIP extraction does not preserve vendor SELinux labels.  The dynamic linker
# resolves the bridge from the vendor namespace, so label its shared objects
# before init starts the service.  The mapper is loaded with dlopen by the
# Composer3 process and uses the same-process HAL label on this vendor.
LIBDIR="${0%/*}/system/vendor/lib64"
if [ -d "$LIBDIR" ]; then
    for library in "$LIBDIR"/*.so; do
        [ -f "$library" ] || continue
        chcon u:object_r:vendor_file:s0 "$library"
    done
fi
MAPPER="$LIBDIR/hw/mapper.exynos990_compat.so"
if [ -f "$MAPPER" ]; then
    chcon u:object_r:same_process_hal_file:s0 "$MAPPER"
fi
# The base vendor image may have started the global allocator before the
# module namespace is visible. Stop it explicitly; Composer3 loads the mapper
# privately and the stock HIDL allocator remains the camera compatibility path.
stop vendor.graphics.allocator-exynos990
EOF
chmod 0755 "$STAGE/post-fs-data.sh"

mkdir -p "$(dirname "$OUTPUT")"
(cd "$STAGE" && zip -qr9 "$OUTPUT" .)
unzip -t "$OUTPUT" >/dev/null
echo "Built KernelSU Composer3 test module: $OUTPUT"
sha256sum "$OUTPUT"
