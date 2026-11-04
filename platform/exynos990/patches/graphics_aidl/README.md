# Cadeia gráfica AIDL do Exynos 990 (`graphics_aidl`)

Módulo da cadeia gráfica AIDL do Galaxy S20+ (y2s) e S20 LTE (y2slte) no
Android 17. Ele coloca allocator, mapper e Composer AIDL sobre os drivers
originais do Exynos 990 (Gralloc1 e HWC2), sem substituir o driver Mali, o
handle nativo nem o HWC da Samsung. Em outros alvos, o módulo não faz nada.

Substitui os antigos `graphics_allocator_bridge`, `composer3_hwc2_bridge` e
`graphics_allocator_trace`.

## O que é instalado

O `customize.sh` aplica três etapas, nesta ordem (prioridade 40):

1. **Allocator AIDL v2 + mapper Stable-C**
   - `bin/hw/android.hardware.graphics.allocator-V2-service.exynos990`, com o
     `.rc` e o fragmento VINTF;
   - `lib64/hw/mapper.exynos990_compat.so` e a biblioteca compartilhada
     `lib64/libexynos990_graphics_compat.so`.

   O framework passa a usar o caminho AIDL. O allocator HIDL original continua
   disponível para a câmera, e o `libGrallocMapperCamera.so` do vendor não é
   trocado.
2. **Composer3 AIDL V5** sobre o HWC2 original
   - `bin/hw/android.hardware.graphics.composer3-service.exynos990`,
     `lib64/libexynos990_composer3_contract.so` e o runtime AIDL dele, com os
     `.rc` e o fragmento VINTF.

   Expõe os modos HD/FHD/QHD nativos e HDR (HDR10, HDR10+ e HLG). O Composer
   HIDL original continua instalado para rollback. Depende do mapper da etapa 1.
3. **Trace do allocator**: `vendor/bin/graphics_allocator_trace` com o serviço
   declarado `disabled`. É só diagnóstico e não roda sozinho.

Os contextos SELinux de arquivos e serviços são acrescentados pelo próprio
módulo.

## Opções de build

| Variável | Padrão | Efeito |
|---|---|---|
| `EXYNOS990_AIDL_GRAPHICS` | `1` | `0` instala só o mapper privado, sem o allocator AIDL global (rollback) |
| `EXYNOS990_DISABLE_HIDL_ALLOCATOR` | `0` | `1` remove o allocator HIDL. O build recusa se `audit_hidl_retirement.sh` ainda achar clientes HIDL diretos, como a câmera |

## Estrutura

| Caminho | Conteúdo |
|---|---|
| `customize.sh`, `module.prop` | instalação do módulo |
| `src/`, `include/` | código do allocator, mapper, gralloc da câmera, Composer3, backend HWC2 e probes |
| `aidl/`, `composer/aidl/` | AIDL do AOSP usados no build |
| `vendor/` | `.rc`, VINTF e o script do trace instalados pelo módulo |
| `docs/` | auditorias, engenharia reversa, detalhes técnicos e logs de teste |
| `prebuilts/exynos990/graphics_aidl/` (raiz do repositório) | binários instalados (`vendor/`), probes de teste (`test/`) e o zip de teste do KernelSU |

## Como compilar os binários

Os binários já vêm prontos em `prebuilts/exynos990/graphics_aidl/`. Só é
preciso recompilar ao mudar o código. Os scripts usam o NDK
(`ANDROID_NDK_ROOT`) e as bibliotecas do system em
`out/target/y2s/work_dir`:

| Script | Gera |
|---|---|
| `build.sh` | allocator, mapper, biblioteca compartilhada e probes |
| `build_composer_aidl.sh` | contrato Composer3 (`libexynos990_composer3_contract.so`) |
| `build_composer_backend.sh` | backend HWC2 de teste e o probe dele |
| `build_composer_service.sh` | serviço Composer3 instalável (chama `build_composer_aidl.sh`) |
| `build_composer_ksu_module.sh` | zip de teste do Composer3 para o KernelSU (id `composer3_hwc2_bridge`) |

## Verificação

| Script | Para quê |
|---|---|
| `audit_graphics_stack.sh` | confere contratos, binários e metadados do módulo sem alterar a imagem |
| `audit_hidl_retirement.sh [work_dir]` | lista os clientes HIDL diretos que ainda impedem remover o allocator HIDL |
| `audit_camera_driver_split.sh` | confere a separação entre o gralloc da câmera e o mapper AIDL |
| `decode_graphics_contracts.sh --brief` | leitura estática dos contratos gráficos da imagem |
| `monitor_test.sh [iterações]` | teste de alocação, import, lock e liberação no aparelho via adb |

## Limitações conhecidas

- A câmera ainda usa o allocator e o mapper HIDL. Por isso o allocator HIDL não
  pode ser removido.
- O gralloc de compatibilidade da câmera
  (`test/libGrallocMapperCamera.compat.so`) é só para teste e não é instalado.

## Documentação

- [`docs/DETALHES_TECNICOS.md`](docs/DETALHES_TECNICOS.md): funcionamento
  interno do allocator, do mapper e do Composer3.
- [`docs/COMPOSER3_BRIDGE.md`](docs/COMPOSER3_BRIDGE.md): ponte Composer3.
- As demais auditorias e a engenharia reversa dos drivers estão em `docs/`.

## Licença

Este repositório é um fork do [UN1CA](https://github.com/salvogiangri/UN1CA).

Os drivers gráficos deste módulo são criação de At30c e são distribuídos sob a
GNU GPL v3 ou posterior (`GPL-3.0-or-later`, ver `LICENSE` na raiz do
repositório):

- mapper Stable-C (`src/mapper.cpp`);
- gralloc/allocator AIDL (`src/allocator_service.cpp`);
- gralloc da câmera (`src/camera_mapper_compat.cpp`);
- o backend e os contratos que eles compartilham (`src/graphics_backend.cpp`,
  `src/metadata.h` e `include/exynos990/`).

Os arquivos copiados ou derivados do AOSP (`aidl/`, `composer/aidl/`,
`include/android/`, `include/cutils/`, `include/hardware/` e `include/system/`)
mantêm a licença Apache-2.0 original indicada em cada arquivo.
