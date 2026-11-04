#!/usr/bin/env bash
set -euo pipefail

# Auditoria somente leitura da pilha gráfica do y2s. O script não monta
# partições, altera imagens nem habilita o módulo experimental.

ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
WORK_DIR="${1:-$ROOT/out/target/y2s/work_dir}"
MODULE_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSER3_MODULE_DIR="$ROOT/platform/exynos990/patches/composer3_hwc2_bridge"
VENDOR="$WORK_DIR/vendor"
SYSTEM="$WORK_DIR/system/system"
MANIFEST="$VENDOR/etc/vintf/manifest.xml"
MODULE_MAPPER="$MODULE_DIR/prebuilt/vendor/lib64/hw/mapper.exynos990_compat.so"
MODULE_COMPAT="$MODULE_DIR/prebuilt/vendor/lib64/libexynos990_graphics_compat.so"
MODULE_CAMERA_SHIM="$MODULE_DIR/prebuilt/test/libGrallocMapperCamera.compat.so"
MODULE_ALLOCATOR="$MODULE_DIR/prebuilt/vendor/bin/hw/android.hardware.graphics.allocator-V2-service.exynos990"

errors=0
warnings=0

pass() { printf 'OK   %s\n' "$*"; }
warn() { warnings=$((warnings + 1)); printf 'WARN %s\n' "$*"; }
fail() { errors=$((errors + 1)); printf 'FAIL %s\n' "$*"; }

require_file() {
    local path="$1" label="$2"
    if [ -f "$path" ]; then pass "$label: $path"; else fail "$label ausente: $path"; fi
}

require_text() {
    local needle="$1" path="$2" label="$3"
    if [ -f "$path" ] && grep -q -F "$needle" "$path"; then
        pass "$label"
    else
        fail "$label (padrão ausente: $needle)"
    fi
}

printf '%s\n' "Auditoria gráfica Exynos 990" "work_dir: $WORK_DIR"

printf '%s\n' '' '[1/7] Backend proprietário e Composer HIDL'
for spec in \
    "bin/hw/android.hardware.graphics.allocator@2.0-service:allocator HIDL 2.0" \
    "bin/hw/android.hardware.graphics.composer@2.3-service:Composer HIDL 2.3" \
    "lib64/hw/android.hardware.graphics.allocator@2.0-impl.so:allocator HIDL impl" \
    "lib64/hw/android.hardware.graphics.mapper@2.0-impl-2.1.so:mapper HIDL 2.1" \
    "lib64/hw/gralloc.exynos990.so:gralloc1 Exynos 990" \
    "lib64/hw/hwcomposer.exynos990.so:HWC2 Exynos 990"; do
    path="${spec%%:*}"; label="${spec#*:}"
    require_file "$VENDOR/$path" "$label"
done

printf '%s\n' '' '[2/7] Runtime AIDL presente no sistema'
for lib in \
    android.hardware.graphics.allocator-V2-ndk.so \
    android.hardware.graphics.composer3-V4-ndk.so \
    android.hardware.graphics.composer3-V5-ndk.so \
    libbinder_ndk.so; do
    require_file "$SYSTEM/lib64/$lib" "$lib"
done

printf '%s\n' '' '[3/7] Artefato Stable-C privado do Composer3'
require_file "$MODULE_COMPAT" 'umbrella nativo do bridge'
if [ -f "$MODULE_COMPAT" ]; then
    file "$MODULE_COMPAT" | grep -q 'ARM aarch64' && pass 'umbrella nativo é ARM64' || fail 'umbrella nativo não é ARM64'
    nm -D "$MODULE_COMPAT" | grep ' exynos990_gralloc_backend$' >/dev/null && pass 'umbrella exporta o backend Gralloc1' || fail 'umbrella não exporta o backend Gralloc1'
    for dep in libhardware.so libcutils.so liblog.so libdl.so libm.so libc.so; do
        readelf -d "$MODULE_COMPAT" | grep -q "Shared library: \[$dep\]" && pass "umbrella depende de $dep" || fail "umbrella não declara $dep"
    done
fi
require_file "$MODULE_MAPPER" 'mapper Stable-C do módulo'
if [ -f "$MODULE_MAPPER" ]; then
    file "$MODULE_MAPPER" | grep -q 'ARM aarch64' && pass 'mapper Stable-C é ARM64' || fail 'mapper Stable-C não é ARM64'
    nm -D "$MODULE_MAPPER" | grep ' AIMapper_loadIMapper$' >/dev/null && pass 'mapper exporta AIMapper_loadIMapper' || fail 'mapper não exporta AIMapper_loadIMapper'
    nm -D "$MODULE_MAPPER" | grep ' ANDROID_HAL_STABLEC_VERSION$' >/dev/null && pass 'mapper exporta ANDROID_HAL_STABLEC_VERSION' || fail 'mapper não exporta ANDROID_HAL_STABLEC_VERSION'
    readelf -d "$MODULE_MAPPER" | grep -q 'libexynos990_graphics_compat.so' && pass 'mapper usa o umbrella compartilhado' || fail 'mapper não usa o umbrella compartilhado'
fi
require_file "$MODULE_CAMERA_SHIM" 'adaptador de teste do mapper da câmera'
CAMERA_HAL="$VENDOR/lib64/libexynoscamera3.so"
require_file "$CAMERA_HAL" 'HAL Exynos 990 da câmera'
if [ -f "$MODULE_CAMERA_SHIM" ] && [ -f "$CAMERA_HAL" ]; then
    readelf -d "$CAMERA_HAL" | grep -q 'libGrallocMapperCamera.so' && pass 'HAL da câmera carrega o SONAME do mapper privado' || fail 'HAL da câmera não declara o mapper privado'
    readelf -d "$MODULE_CAMERA_SHIM" | grep -q 'Library soname: \[libGrallocMapperCamera.so\]' && pass 'adaptador preserva o SONAME original' || fail 'adaptador mudou o SONAME original'
    while read -r symbol; do
        [ -z "$symbol" ] && continue
        nm -D --defined-only "$MODULE_CAMERA_SHIM" | awk '{print $3}' | grep -Fqx "$symbol" && \
            pass "adaptador exporta ABI da câmera: $symbol" || fail "adaptador não exporta ABI da câmera: $symbol"
    done < <(nm -D --undefined-only "$CAMERA_HAL" | awk '/GrallocMapperCamera/{print $2}')
fi
if [ -f "$VENDOR/bin/hw/android.hardware.graphics.allocator-V2-service.exynos990" ]; then
    pass 'allocator AIDL v2 está presente na imagem auditada'
    if readelf -d "$MODULE_ALLOCATOR" | grep -q 'libexynos990_graphics_compat.so'; then
        pass 'allocator AIDL usa o umbrella compartilhado'
    else
        fail 'allocator AIDL não usa o umbrella compartilhado'
    fi
    require_file "$VENDOR/etc/init/android.hardware.graphics.allocator-V2-service.exynos990.rc" \
        'init do allocator AIDL v2'
    require_file "$VENDOR/etc/vintf/manifest/android.hardware.graphics.allocator-exynos990.xml" \
        'fragmento VINTF do allocator AIDL v2'
    require_text 'mapper/exynos990_compat u:object_r:hal_graphics_mapper_service:s0' \
        "$VENDOR/etc/selinux/vendor_service_contexts" \
        'contexto SELinux do mapper Stable-C no servicemanager vendor'
    ALLOCATOR_MANIFEST="$VENDOR/etc/vintf/manifest/android.hardware.graphics.allocator-exynos990.xml"
    # AIDL VINTF fragments represent the instance as <name> + <fqname>:
    # <name>android.hardware.graphics.allocator</name> together with
    # <fqname>IAllocator/default</fqname>.  Some generated manifests instead
    # emit the fully-qualified string in one field, so accept both forms.
    if {
        grep -q -F '<name>android.hardware.graphics.allocator</name>' "$ALLOCATOR_MANIFEST" &&
        grep -q -F '<fqname>IAllocator/default</fqname>' "$ALLOCATOR_MANIFEST";
    } || grep -q -F 'android.hardware.graphics.allocator.IAllocator/default' "$ALLOCATOR_MANIFEST"; then
        pass 'VINTF registra android.hardware.graphics.allocator/IAllocator default'
    else
        fail 'VINTF não registra a instância AIDL IAllocator/default'
    fi
else
    warn 'allocator AIDL v2 não está na work_dir; esta imagem usa somente o fallback HIDL'
    pass 'mapper Stable-C pode continuar privado do Composer3 durante o rollback'
fi

printf '%s\n' '' '[4/7] Backend HWC2 para a futura ponte Composer3'
MODULE_HWC2="$MODULE_DIR/prebuilt/test/libexynos990_hwc2_backend.so"
MODULE_HWC2_PROBE="$MODULE_DIR/prebuilt/test/hwc2_backend_probe"
require_file "$MODULE_HWC2" 'biblioteca de consulta HWC2'
require_file "$MODULE_HWC2_PROBE" 'probe HWC2'
if [ -f "$MODULE_HWC2" ]; then
    file "$MODULE_HWC2" | grep -q 'ARM aarch64' && pass 'backend HWC2 é ARM64' || fail 'backend HWC2 não é ARM64'
    nm -D "$MODULE_HWC2" | grep ' exynos990_hwc2_query_display$' >/dev/null && pass 'backend HWC2 exporta consulta de display' || fail 'backend HWC2 não exporta consulta de display'
fi
if [ -f "$MODULE_HWC2_PROBE" ]; then
    file "$MODULE_HWC2_PROBE" | grep -q 'ARM aarch64' && pass 'probe HWC2 é ARM64' || fail 'probe HWC2 não é ARM64'
fi

printf '%s\n' '' '[5/7] Contrato Composer3 AIDL e adaptador HWC2'
MODULE_COMPOSER="$MODULE_DIR/prebuilt/test/libexynos990_composer3_contract.so"
MODULE_COMPOSER_PROBE="$MODULE_DIR/prebuilt/test/composer3_contract_probe"
COMPOSER_AIDL_COUNT="$(find "$MODULE_DIR/composer/aidl" -name '*.aidl' -type f | wc -l)"
if [ "$COMPOSER_AIDL_COUNT" -eq 90 ]; then
    pass 'fonte do contrato Composer3 contém os 90 AIDL esperados'
else
    fail "fonte do contrato Composer3 incompleta: $COMPOSER_AIDL_COUNT/90 AIDL"
fi
require_file "$MODULE_COMPOSER" 'biblioteca do contrato Composer3 AIDL'
require_file "$MODULE_COMPOSER_PROBE" 'probe do contrato Composer3 AIDL'
if [ -f "$MODULE_COMPOSER" ]; then
    file "$MODULE_COMPOSER" | grep -q 'ARM aarch64' && pass 'contrato Composer3 é ARM64' || fail 'contrato Composer3 não é ARM64'
    nm -D "$MODULE_COMPOSER" | grep ' exynos990_composer3_contract_probe$' >/dev/null && pass 'contrato Composer3 exporta probe' || fail 'contrato Composer3 não exporta probe'
    readelf -d "$MODULE_COMPOSER" | grep -q 'android.hardware.graphics.composer3-V5-ndk.so' && pass 'contrato Composer3 usa o runtime V5 do alvo' || fail 'contrato Composer3 não referencia o runtime V5'
    if readelf -d "$MODULE_COMPOSER" | grep 'libc++' >/dev/null; then
        fail 'contrato Composer3 depende de libc++ externa'
    else
        pass 'contrato Composer3 não adiciona libc++ externa'
    fi
fi
if [ -f "$MODULE_COMPOSER_PROBE" ]; then
    file "$MODULE_COMPOSER_PROBE" | grep -q 'ARM aarch64' && pass 'probe Composer3 é ARM64' || fail 'probe Composer3 não é ARM64'
fi
if [ -f "$MODULE_HWC2" ]; then
    nm -D "$MODULE_HWC2" | grep ' exynos990_hwc2_session_open$' >/dev/null && pass 'backend HWC2 exporta sessão persistente' || fail 'backend HWC2 não exporta sessão persistente'
    for symbol in exynos990_hwc2_session_create_layer \
                  exynos990_hwc2_session_set_layer_buffer \
                  exynos990_hwc2_session_validate \
                  exynos990_hwc2_session_present \
                  exynos990_hwc2_session_register_callbacks \
                  exynos990_hwc2_session_get_changed_composition_types \
                  exynos990_hwc2_session_get_release_fences; do
        if nm -D "$MODULE_HWC2" | grep " $symbol$" >/dev/null; then
            pass "backend HWC2 exporta $symbol"
        else
            fail "backend HWC2 não exporta $symbol"
        fi
    done
fi
if grep -q 'onHotplugEvent' "$MODULE_DIR/src/composer3_contract.cpp" &&
   grep -q 'onVsync' "$MODULE_DIR/src/composer3_contract.cpp"; then
    pass 'adaptador Composer3 implementa callbacks HWC2 de hotplug/vsync/refresh'
else
    fail 'adaptador Composer3 não contém a ponte de callbacks HWC2'
fi
if grep -q 'duplicateFence' "$MODULE_DIR/src/composer3_contract.cpp" &&
   grep -q 'presentFence' "$MODULE_DIR/src/composer3_contract.cpp" &&
   grep -q 'releaseFences' "$MODULE_DIR/src/composer3_contract.cpp"; then
    pass 'executeCommands transporta acquire/present/release fences com NativeHandle por slot'
else
    fail 'executeCommands não contém a conversão de fences'
fi

# A implementação deve declarar cada método do IComposerClient explicitamente.
# Isto evita que um método novo da interface seja atendido silenciosamente pelo
# default do AIDL. Os métodos sem equivalente seguro retornam EX_UNSUPPORTED
# de forma explícita no código C++.
CLIENT_METHODS=(
    createLayer destroyLayer registerCallback executeCommands
    getActiveConfig getDisplayConfigs getDisplayAttribute
    getDisplayConnectionType getDisplayName getDisplayVsyncPeriod
    getDisplayConfigurations setActiveConfig getDisplayPhysicalOrientation
    getColorModes getMaxVirtualDisplayCount createVirtualDisplay
    destroyVirtualDisplay getDataspaceSaturationMatrix getDisplayCapabilities
    getDisplayIdentificationData getDisplayedContentSample
    getDisplayedContentSamplingAttributes getHdrCapabilities
    getPerFrameMetadataKeys getReadbackBufferAttributes getReadbackBufferFence
    getRenderIntents getSupportedContentTypes getDisplayDecorationSupport
    setActiveConfigWithConstraints setBootDisplayConfig clearBootDisplayConfig
    getPreferredBootDisplayConfig setAutoLowLatencyMode
    setClientTargetSlotCount setColorMode setContentType
    setDisplayedContentSamplingEnabled setReadbackBuffer setIdleTimerEnabled
    getOverlaySupport getHdrConversionCapabilities setHdrConversionStrategy
    setRefreshRateChangedCallbackDebugEnabled notifyExpectedPresent
    getMaxLayerPictureProfiles startHdcpNegotiation getLuts setPowerMode
    setVsyncEnabled
)
missing_client_methods=()
for method in "${CLIENT_METHODS[@]}"; do
    if ! grep -Eq "^[[:space:]]*ndk::ScopedAStatus[[:space:]]+${method}\\(" \
        "$MODULE_DIR/src/composer3_contract.cpp"; then
        missing_client_methods+=("$method")
    fi
done
if [ "${#missing_client_methods[@]}" -eq 0 ]; then
    pass 'IComposerClient V5 possui 50/50 métodos com override explícito'
else
    fail "IComposerClient V5 possui métodos sem override: ${missing_client_methods[*]}"
fi

printf '%s\n' '' '[6/7] VINTF e SELinux do alvo'
require_text '<name>android.hardware.graphics.allocator</name>' "$MANIFEST" 'manifest declara allocator HIDL legado'
require_text '<name>android.hardware.graphics.composer</name>' "$MANIFEST" 'manifest declara Composer HIDL legado'
require_text '<name>android.hardware.graphics.mapper</name>' "$MANIFEST" 'manifest declara mapper HIDL legado'
if [ -f "$VENDOR/etc/selinux/vendor_file_contexts" ]; then
    if [ -f "$VENDOR/lib64/hw/mapper.exynos990_compat.so" ]; then
        require_text 'mapper\.exynos990_compat' "$VENDOR/etc/selinux/vendor_file_contexts" 'contexto do mapper privado no alvo'
    else
        warn 'mapper privado ainda não foi aplicado; a checagem ocorrerá na imagem empacotada'
    fi
else
    warn 'vendor_file_contexts não existe no work_dir; a checagem ocorrerá na imagem empacotada'
fi

printf '%s\n' '' '[7/7] Composer AIDL'
if grep -q 'android.hardware.graphics.composer3' "$MANIFEST" 2>/dev/null; then
    pass 'manifest já declara Composer3 AIDL'
else
    warn 'Composer3 AIDL ainda não está registrado; o alvo continua usando Composer HIDL 2.3'
fi
if [ -f "$SYSTEM/lib64/android.hardware.graphics.composer3-V4-ndk.so" ] ||
   [ -f "$SYSTEM/lib64/android.hardware.graphics.composer3-V5-ndk.so" ]; then
    pass 'framework possui runtime Composer3 AIDL'
else
    fail 'framework não possui runtime Composer3 AIDL'
fi
warn 'AIDL Composer continua desabilitado: faltam validação no aparelho, lifecycle CREATE/DESTROY em lote e os comandos avançados antes do registro VINTF'

printf '%s\n' '' '[8/8] Módulo instalável Composer3 HWC2'
COMPOSER3_SERVICE="$COMPOSER3_MODULE_DIR/prebuilt/vendor/bin/hw/android.hardware.graphics.composer3-service.exynos990"
COMPOSER3_LIBRARY="$COMPOSER3_MODULE_DIR/prebuilt/vendor/lib64/libexynos990_composer3_contract.so"
require_file "$COMPOSER3_MODULE_DIR/module.prop" 'module.prop do Composer3'
require_file "$COMPOSER3_MODULE_DIR/customize.sh" 'customize do Composer3'
require_file "$COMPOSER3_SERVICE" 'serviço Composer3 instalável'
require_file "$COMPOSER3_LIBRARY" 'biblioteca Composer3 instalável'
require_file "$COMPOSER3_MODULE_DIR/vendor/etc/init/android.hardware.graphics.composer3-service.exynos990.rc" \
    'init rc do Composer3'
require_file "$COMPOSER3_MODULE_DIR/vendor/etc/vintf/manifest/android.hardware.graphics.composer3-exynos990.xml" \
    'fragmento VINTF do Composer3'
if [ -f "$COMPOSER3_SERVICE" ]; then
    file "$COMPOSER3_SERVICE" | grep -q 'ARM aarch64' && pass 'serviço Composer3 é ARM64' || fail 'serviço Composer3 não é ARM64'
    readelf -d "$COMPOSER3_SERVICE" | grep -q 'libexynos990_composer3_contract.so' && \
        pass 'serviço Composer3 referencia a biblioteca do bridge' || \
        fail 'serviço Composer3 não referencia a biblioteca do bridge'
fi
if [ -f "$COMPOSER3_LIBRARY" ]; then
    file "$COMPOSER3_LIBRARY" | grep -q 'ARM aarch64' && pass 'biblioteca Composer3 instalável é ARM64' || fail 'biblioteca Composer3 instalável não é ARM64'
    nm -D "$COMPOSER3_LIBRARY" | grep ' exynos990_composer3_service_binder$' >/dev/null && \
        pass 'biblioteca Composer3 exporta a fábrica Binder do serviço' || \
        fail 'biblioteca Composer3 não exporta a fábrica Binder do serviço'
fi
require_text 'android.hardware.graphics.composer3.IComposer/default' \
    "$COMPOSER3_MODULE_DIR/vendor/etc/init/android.hardware.graphics.composer3-service.exynos990.rc" \
    'init registra a instância AIDL Composer3'
require_text '<version>5</version>' \
    "$COMPOSER3_MODULE_DIR/vendor/etc/vintf/manifest/android.hardware.graphics.composer3-exynos990.xml" \
    'VINTF declara Composer3 V5'
require_text 'TARGET_CODENAME' "$COMPOSER3_MODULE_DIR/customize.sh" \
    'módulo limita instalação a y2s/y2slte'

printf '%s\n' '' '[9/9] Fechamento das dependências HIDL de allocator/mapper'
HIDL_RETIREMENT_AUDIT="$MODULE_DIR/audit_hidl_retirement.sh"
if [ -x "$HIDL_RETIREMENT_AUDIT" ]; then
    HIDL_AUDIT_OUTPUT="$(bash "$HIDL_RETIREMENT_AUDIT" "$WORK_DIR" 2>&1)" || true
    HIDL_BLOCKERS="$(printf '%s\n' "$HIDL_AUDIT_OUTPUT" | awk -F= '/^direct_getService_blockers=/{split($2, a, " "); print a[1]; exit}')"
    HIDL_ABI_ONLY="$(printf '%s\n' "$HIDL_AUDIT_OUTPUT" | awk -F= '/^direct_getService_blockers=/{split($3, a, " "); print a[1]; exit}')"
    if printf '%s\n' "$HIDL_AUDIT_OUTPUT" | grep -q '^RETIREMENT_READY:'; then
        pass 'nenhum consumidor ELF chama diretamente o serviço HIDL gráfico'
    else
        warn "aposentadoria HIDL ainda bloqueada: ${HIDL_BLOCKERS:-?} chamadas diretas; ${HIDL_ABI_ONLY:-?} dependências ABI-only"
        printf '%s\n' "$HIDL_AUDIT_OUTPUT" | sed -n '/^BLOCKER /p' | sed 's/^/      /'
    fi
else
    warn 'audit_hidl_retirement.sh ausente; fechamento HIDL não foi verificado'
fi

printf '\nResultado: %d falha(s), %d aviso(s)\n' "$errors" "$warnings"
if [ "$errors" -ne 0 ]; then exit 1; fi
