#!/usr/bin/env bash
# Reinstala uma vendor EROFS assinada pelo AVB usando o TWRP e dd.
# Uso: scripts/dd_vendor_install.sh <vendor.img> [serial]
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${1:-}"
SERIAL="${2:-}"
ADB=(adb)
[[ "$SERIAL" ]] && ADB+=( -s "$SERIAL" )

die() { echo "dd-vendor-install: $*" >&2; exit 1; }
[[ -f "$IMAGE" ]] || die "imagem ausente: $IMAGE"
command -v adb >/dev/null || die "adb não encontrado"

AVBTOOL="$SRC_DIR/out/tools/bin/avbtool"
[[ -x "$AVBTOOL" ]] || AVBTOOL="$(command -v avbtool || true)"
[[ "$AVBTOOL" ]] || die "avbtool não encontrado"

IMAGE_SIZE="$(stat -c '%s' "$IMAGE")"
"$AVBTOOL" info_image --image "$IMAGE" >/dev/null || die "imagem sem footer AVB válido"

echo "Reiniciando para o recovery TWRP..."
"${ADB[@]}" reboot recovery
for _ in $(seq 1 120); do
    if "${ADB[@]}" get-state >/dev/null 2>&1; then break; fi
    sleep 2
done
"${ADB[@]}" get-state >/dev/null 2>&1 || die "TWRP não respondeu via adb"

TARGET="$(${ADB[@]} shell 'for p in /dev/block/by-name/vendor /dev/block/mapper/vendor; do [ -e "$p" ] && { case "$p" in /dev/block/dm-*) continue;; esac; echo "$p"; break; }; done' | tr -d '\r' | awk 'NF { print $1; exit }')"
[[ "$TARGET" == /dev/block/by-name/vendor || "$TARGET" == /dev/block/mapper/vendor ]] || \
    die "bloco vendor seguro não encontrado no TWRP"
PARTITION_SIZE="$(${ADB[@]} shell "blockdev --getsize64 $TARGET" | tr -d '\r' | awk 'NF { print $1; exit }')"
[[ "$PARTITION_SIZE" =~ ^[0-9]+$ ]] || die "não foi possível obter o tamanho da partição vendor no TWRP"
[[ "$IMAGE_SIZE" == "$PARTITION_SIZE" ]] || die "tamanho incompatível: imagem=$IMAGE_SIZE partição=$PARTITION_SIZE"

echo "Copiando imagem assinada para o TWRP..."
"${ADB[@]}" push "$IMAGE" /tmp/vendor-dd.img >/dev/null
"${ADB[@]}" shell 'umount /vendor 2>/dev/null || true'
"${ADB[@]}" shell "dd if=/tmp/vendor-dd.img of=$TARGET bs=4M conv=fsync"
"${ADB[@]}" shell sync

REMOTE_HASH="$("${ADB[@]}" shell "sha256sum $TARGET" | awk '{print $1}' | tr -d '\r')"
LOCAL_HASH="$(sha256sum "$IMAGE" | awk '{print $1}')"
[[ "$REMOTE_HASH" == "$LOCAL_HASH" ]] || die "verificação falhou: local=$LOCAL_HASH recovery=$REMOTE_HASH"
echo "vendor instalada e verificada: $TARGET ($LOCAL_HASH)"
