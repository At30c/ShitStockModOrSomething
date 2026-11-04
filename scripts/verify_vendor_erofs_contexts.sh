#!/usr/bin/env bash
# Verifica os metadados mínimos que uma vendor EROFS precisa preservar.
# Uso: scripts/verify_vendor_erofs_contexts.sh <file_contexts> <fs_config> [vendor.img]
set -euo pipefail

FILE_CONTEXTS="${1:?uso: $0 <file_contexts> <fs_config> [vendor.img]}"
FS_CONFIG="${2:?uso: $0 <file_contexts> <fs_config> [vendor.img]}"
IMAGE="${3:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DUMP_EROFS="$ROOT/out/tools/bin/dump.erofs"

fail() { echo "verify-vendor-erofs-contexts: $*" >&2; exit 1; }
[[ -s "$FILE_CONTEXTS" ]] || fail "file_contexts ausente ou vazio: $FILE_CONTEXTS"
[[ -s "$FS_CONFIG" ]] || fail "fs_config ausente ou vazio: $FS_CONFIG"

# Uma tabela curta aplica o contexto padrão a toda a partição. Isto é
# suficiente para uma imagem ser assinada, mas impede init/apexd de iniciar.
[[ "$(wc -l < "$FILE_CONTEXTS")" -ge 1000 ]] || \
    fail "file_contexts incompleto ($(wc -l < "$FILE_CONTEXTS") regras)"

require_context() {
    local pattern="$1"
    grep -Eq "$pattern" "$FILE_CONTEXTS" || fail "contexto SELinux ausente: $pattern"
}
require_fs() {
    local pattern="$1"
    grep -Eq "$pattern" "$FS_CONFIG" || fail "entrada fs_config ausente: $pattern"
}

require_context '^/vendor/apex[[:space:]]+u:object_r:vendor_apex_file:s0$'
require_context '^/vendor/etc/ueventd\\.rc[[:space:]]+'
require_context '^/vendor/bin/hw/android\\.hardware\\.camera\\.provider-V4-service\\.exynos990[[:space:]]+u:object_r:hal_camera_default_exec:s0$'
require_context '^/vendor/etc/init/android\\.hardware\\.camera\\.provider-V4-service\\.exynos990\\.rc[[:space:]]+u:object_r:vendor_configs_file:s0$'
require_context '^/vendor/etc/vintf/manifest/android\\.hardware\\.camera\\.provider-exynos990\\.xml[[:space:]]+u:object_r:vendor_configs_file:s0$'
require_context '^/vendor/lib64/android\\.hardware\\.thermal@1\\.0\\.so[[:space:]]+u:object_r:same_process_hal_file:s0$'
require_context '^/vendor/lib64/android\\.hardware\\.thermal@2\\.0\\.so[[:space:]]+u:object_r:same_process_hal_file:s0$'
require_fs '^vendor/bin/hw/android\.hardware\.camera\.provider-V4-service\.exynos990[[:space:]]+0[[:space:]]+1047[[:space:]]+0?755$'

if [[ -n "$IMAGE" ]]; then
    [[ -x "$DUMP_EROFS" ]] || fail "dump.erofs ausente: $DUMP_EROFS"
    for path in / /apex /etc/ueventd.rc /bin/hw/android.hardware.camera.provider-V4-service.exynos990; do
        output="$($DUMP_EROFS --path="$path" "$IMAGE")"
        grep -Eq 'Xattr size: [1-9][0-9]*' <<<"$output" || \
            fail "imagem sem xattr SELinux em $path"
    done
fi

echo 'verify-vendor-erofs-contexts: contextos e xattrs validados'
