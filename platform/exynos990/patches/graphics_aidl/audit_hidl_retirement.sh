#!/usr/bin/env bash

# Static gate for removing the y2s graphics HIDL services.  It deliberately
# does not modify the work directory; it reports every ELF that would keep the
# old allocator/mapper ABI alive.
set -u
export LC_ALL=C

ROOT="${1:-out/target/y2s/work_dir}"
VENDOR="$ROOT/vendor"
SYSTEM="$ROOT/system/system"

if ! command -v readelf >/dev/null 2>&1; then
    echo "readelf is required" >&2
    exit 2
fi
if [ ! -d "$VENDOR" ] || [ ! -d "$SYSTEM" ]; then
    echo "work directory is incomplete: $ROOT" >&2
    exit 2
fi

echo "HIDL graphics retirement audit"
echo "root=$ROOT"
echo
echo "Declared HIDL graphics entries:"
grep -R -n -E 'android\.hardware\.graphics\.(allocator|mapper|composer)' \
    "$VENDOR/etc/vintf" "$VENDOR/etc/vintf/manifest.xml" 2>/dev/null || true
echo

hard_blockers=0
type_only=0
seen="|"
while IFS= read -r -d '' blob; do
    deps="$(readelf -d "$blob" 2>/dev/null | grep -E \
        'NEEDED.*android\.hardware\.graphics\.(allocator|mapper)@' || true)"
    [ -z "$deps" ] && continue

    # The interface libraries and the old implementation objects are the
    # removal targets themselves.  Report their consumers, not their own
    # internal ABI edges.
    case "$blob" in
        */bin/hw/android.hardware.graphics.allocator@*-service|\
        */android.hardware.graphics.allocator@*.so|\
        */android.hardware.graphics.mapper@*.so|\
        */hw/android.hardware.graphics.allocator@*-impl.so|\
        */hw/android.hardware.graphics.mapper@*-impl*.so)
            continue
            ;;
    esac

    key="|$blob|$deps|"
    case "$seen" in *"$key"*) continue ;; esac
    seen="${seen}${blob}|${deps}|"
    symbols="$(readelf -Ws "$blob" 2>/dev/null | awk '$7=="UND" {print $8}' | grep -E \
        'android8hardware8graphics(6mapper|9allocator).*getService|android\.hardware\.graphics\.(mapper|allocator).*getService' || true)"
    if [ -n "$symbols" ]; then
        hard_blockers=$((hard_blockers + 1))
        echo "BLOCKER (direct HIDL getService): ${blob#"$ROOT"/}"
    else
        type_only=$((type_only + 1))
        echo "ABI-ONLY (DT_NEEDED, sem getService HIDL): ${blob#"$ROOT"/}"
    fi
    echo "$deps" | sed 's/^/  /'
    [ -n "$symbols" ] && echo "$symbols" | sed 's/^/  symbol: /'
done < <(find "$VENDOR" "$SYSTEM" -type f \( -name '*.so' -o -perm -0100 \) -print0 2>/dev/null)

echo
echo "direct_getService_blockers=$hard_blockers abi_only_consumers=$type_only"
if [ "$hard_blockers" -ne 0 ]; then
    echo "RETIREMENT_BLOCKED: direct HIDL graphics clients remain."
    echo "Migrate those clients or provide an ABI adapter before deleting the HIDL service."
    exit 1
fi

echo "RETIREMENT_READY: no remaining graphics HIDL ELF consumers were found."
exit 0
