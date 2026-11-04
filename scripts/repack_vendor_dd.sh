#!/usr/bin/env bash
# Rebuilds an AVB-signed EROFS vendor image from a dd dump plus a change tree,
# for installation with scripts/dd_vendor_install.sh.
#
#   scripts/repack_vendor_dd.sh <base.img> <workdir> <changes-dir>
#
# <changes-dir> layout:
#   vendor/...        files copied over the extracted tree (new or replaced)
#   fs_config         optional extra fs_config lines   ("vendor/x 0 2000 0755 caps")
#   file_contexts     optional extra file_contexts lines ("/vendor/x u:object_r:...:s0")
#   remove            optional list of paths to delete ("vendor/x"), one per line
#
# The UUID, timestamp, compression, block size, partition size and AVB key of
# the base image are preserved.  The result is verified by extracting it again
# and comparing every path, mode, owner and SELinux label with the base, so the
# only differences reported are the intended ones.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$SRC_DIR/out/tools/bin:$PATH"
BASE="${1:?base image}"
WORK="${2:?workdir}"
CHANGES="${3:?changes dir}"
KEY="$SRC_DIR/security/avb/testkey_rsa4096.pem"

die() { echo "repack-vendor: $*" >&2; exit 1; }
for tool in extract.erofs mkfs.erofs avbtool fec; do
    command -v "$tool" >/dev/null || die "missing tool: $tool"
done
[[ -f "$BASE" ]] || die "base image missing: $BASE"
[[ -d "$CHANGES/vendor" ]] || die "changes dir needs a vendor/ tree: $CHANGES"
[[ -f "$KEY" ]] || die "AVB key missing: $KEY"

PARTITION_SIZE="$(stat -c '%s' "$BASE")"
UUID="$(dump.erofs "$BASE" 2>/dev/null | awk -F': *' '/Filesystem UUID/ {print $2}')"
[[ "$UUID" =~ ^[0-9a-f-]{36}$ ]] || die "cannot read EROFS UUID from base"
avbtool info_image --image "$BASE" | grep -q "Partition Name: *vendor" || die "base has no vendor AVB footer"

rm -rf "$WORK"
mkdir -p "$WORK"
# extracted tree + payload + verification tree: refuse to run on a full disk,
# where extract/mkfs leave truncated files behind without failing.
NEED_KB=$(( PARTITION_SIZE * 4 / 1024 ))
FREE_KB="$(df -Pk "$WORK" | awk 'NR == 2 {print $4}')"
(( FREE_KB > NEED_KB )) || die "not enough free space in $WORK: ${FREE_KB} KiB free, ${NEED_KB} KiB needed"
WORK="$(cd "$WORK" && pwd)"
BASE="$(realpath "$BASE")"
CHANGES="$(realpath "$CHANGES")"
echo "- extracting base"
# extract.erofs names the tree and config after the image file: use vendor.img.
ln -s "$BASE" "$WORK/vendor.img"
extract.erofs -i "$WORK/vendor.img" -x -s -T8 -o "$WORK/extracted" >/dev/null
TREE="$WORK/extracted/vendor"
CFG="$WORK/extracted/config"

echo "- applying changes"
if [[ -f "$CHANGES/remove" ]]; then
    while read -r path; do
        [[ -z "$path" || "$path" == \#* ]] && continue
        rm -rf "${WORK:?}/extracted/$path"
    done < "$CHANGES/remove"
fi
cp -a "$CHANGES/vendor/." "$TREE/"
if [[ -f "$CHANGES/fs_config" ]]; then
    grep -v '^\s*$' "$CHANGES/fs_config" >> "$CFG/vendor_fs_config"
fi
if [[ -f "$CHANGES/file_contexts" ]]; then
    grep -v '^\s*$' "$CHANGES/file_contexts" >> "$CFG/vendor_file_contexts"
fi

echo "- building EROFS"
# Same EROFS profile as scripts/build_fs_image.sh (lz4hc,9, 4 KiB blocks,
# Samsung fixed timestamp, mount point "vendor"), plus the base UUID.
mkfs.erofs -z lz4hc,9 -b 4096 -T 1640995200 -U "$UUID" --mount-point vendor \
    --fs-config-file="$CFG/vendor_fs_config" --file-contexts="$CFG/vendor_file_contexts" \
    "$WORK/vendor-payload.img" "$TREE" > "$WORK/mkfs.log" 2>&1 || {
        tail -20 "$WORK/mkfs.log" >&2; die "mkfs.erofs failed"; }

echo "- adding AVB hashtree footer"
avbtool add_hashtree_footer --image "$WORK/vendor-payload.img" \
    --partition_size "$PARTITION_SIZE" --partition_name vendor \
    --hash_algorithm sha256 --algorithm SHA256_RSA4096 --key "$KEY"
[[ "$(stat -c '%s' "$WORK/vendor-payload.img")" == "$PARTITION_SIZE" ]] || die "payload size mismatch"

echo "- verifying against base"
mkdir -p "$WORK/check" && ln -s "$WORK/vendor-payload.img" "$WORK/check/vendor.img"
extract.erofs -i "$WORK/check/vendor.img" -x -s -T8 -o "$WORK/check" >/dev/null
python3 - "$WORK/extracted/config" "$WORK/check/config" <<'EOF' || die "fs_config differs"
import sys
def load(d):
    fs = {}
    for l in open(f"{d}/vendor_fs_config"):
        p = l.split()
        if p: fs[p[0]] = " ".join(p[1:])
    fc = {}
    for l in open(f"{d}/vendor_file_contexts"):
        p = l.split()
        if len(p) >= 2: fc[p[0]] = p[-1]
    return fs, fc
want_fs, want_fc = load(sys.argv[1])
got_fs, got_fc = load(sys.argv[2])
bad = 0
for k, v in want_fs.items():
    if got_fs.get(k) != v:
        print(f"  fs_config mismatch {k}: want '{v}' got '{got_fs.get(k)}'"); bad += 1
for k in got_fs.keys() - want_fs.keys():
    print(f"  unexpected path {k}"); bad += 1
print(f"  {len(got_fs)} paths, {bad} mismatches")
sys.exit(1 if bad else 0)
EOF
diff -rq --no-dereference "$TREE" "$WORK/check/vendor" || die "content differs from the intended tree"
echo "  content identical to the intended tree"
python3 - "$WORK/extracted/config/vendor_file_contexts" "$WORK/check/config/vendor_file_contexts" "$CHANGES" <<'EOF2'
import sys
def load(p):
    m = {}
    for l in open(p):
        f = l.split()
        if len(f) >= 2: m[f[0]] = f[-1]
    return m
want, got = load(sys.argv[1]), load(sys.argv[2])
bad = [k for k in want if k in got and got[k] != want[k]]
for k in bad[:20]: print(f"  label mismatch {k}: want {want[k]} got {got[k]}")
missing = [k for k in want if k not in got and "(" not in k]
for k in missing[:20]: print(f"  label missing {k}")
print(f"  {len(got)} labels, {len(bad)} mismatches, {len(missing)} missing")
sys.exit(1 if bad or missing else 0)
EOF2
avbtool info_image --image "$WORK/vendor-payload.img" | grep -E "Image size|Root Digest"
sha256sum "$WORK/vendor-payload.img"
