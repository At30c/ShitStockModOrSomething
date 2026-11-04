# Engenharia reversa do allocator e mapper gráficos

Análise realizada em 17/10/2026. O objetivo é identificar quais partes da
pilha gráfica Samsung podem orientar o bridge do Exynos 990 sem substituir o
backend proprietário de buffers do aparelho-alvo.

## Amostras analisadas

| Amostra | ABI gráfica | Binário relevante | SHA-256 |
| --- | --- | --- | --- |
| y2s / donor S20+ (`out/fw/SM-G986B_AUT`) | Gralloc1 + mapper HIDL 2.1, allocator 2.0, Composer 2.3 | `vendor/lib64/hw/gralloc.exynos990.so` | `1dd0cd1c9d20b224f63f780bfc647f828203e3fb2b5654172aa6d86aed9b70e7` |
| y2s / donor S20+ | Wrapper passthrough do mapper HIDL | `vendor/lib64/hw/android.hardware.graphics.mapper@2.0-impl-2.1.so` | `b80b5e191750144137eb1e85b761dd7b4cc144c5f42b04a74810c254f6d4e022` |
| Dump do R11s, Android 15 | Mapper Samsung SGR 4.0, allocator 4.0, Composer 2.4 | `vendor/lib64/hw/android.hardware.graphics.mapper@4.0-impl-sgr.so` | `5d41ddf2933ccf34b23320a71e8d64c1277d7b12e8ab5f85c52cb3cd3218c27f` |
| Dump do R11s, Android 15 | Backend SGR HWC2 | `vendor/lib64/hw/hwcomposer.s5e9925.so` | `a1e7eab46fadacb2c0f24f02863b1f0f752c4380ffcd7c48e64d4871db337b56` |
| Dump do S26+ (`out/fw/SM-S947B_EUX`) | Mapper Stable-C 5, allocator AIDL 2, Composer3 AIDL 4 | `vendor/lib64/hw/mapper.stableC-impl-sgr.so` | `e7e8acdcf18025b0939e6c4cb32189d6d1dd50a43d18c1fd5a0f6017d964eaea` |
| Dump do S26+ | Allocator AIDL 2 | `vendor/bin/hw/android.hardware.graphics.allocator-aidl-service-sgr` | `f6ebbc7cf27e59335f4fce833bcc3a1300d9fda1a3f0581ea3aa7857241eeed3` |

A amostra do R11s veio da [branch do dump Samsung](https://dumps.tadiphone.dev/dumps/samsung/r11s/-/tree/r11sxxx-user-15-AP3A.240905.015.A2-S711BXXSAEYI1-release-keys/vendor)
`r11sxxx-user-15-AP3A.240905.015.A2-S711BXXSAEYI1-release-keys`.

## O que a comparação confirmou

### R11s e S26+ pertencem à mesma família SGR

O Mapper 4.0 do R11s e o Mapper Stable-C 5 do S26+ compartilham 220 símbolos
dinâmicos após a remoção dos nomes C++. O conjunto comum inclui:

- métodos `Mapper` para descritores, importação, liberação, lock, unlock, map,
  unmap e validação;
- métodos de alocação, importação, mapeamento e sincronização de cache do
  `ExynosIonMemoryManager`;
- `FormatManager`, `LinearLayoutManager`, `CpuFormatManager`,
  `CameraFormatManager`, `VideoFormatManager`, `HwcFormatManager`,
  `SgpuFormatManager`, `SbwcLayoutManager` e `DccLayoutManager`;
- acessores de `MetadataManager` para dimensões, uso, ID do buffer, layouts de
  planos, dataspace, metadata HDR, compressão e modificadores de formato;
- funções de metadata padrão SGR exportadas como
  `sgr_intf_get_*` e `sgr_intf_set_*`.

Isso mostra que o dump do R11s é uma boa referência intermediária para entender
o contrato Stable-C do S26+. Isso não prova que nenhum dos dois binários possa
consumir um `native_handle_t` do Exynos 990.

### O backend do Exynos 990 usa outra ABI

O `gralloc.exynos990.so` do Exynos 990 exporta a família ARM/Mali Gralloc1:

- `mali_gralloc_allocate`, `mali_gralloc_ion_allocate` e
  `mali_gralloc_ion_sync_*`;
- `mali_gralloc_reference_retain/release`;
- `mali_gralloc_get_*_internal` e `mali_gralloc_set_*_internal`;
- seleção de formatos AFBC e tabelas de formato/suporte de IP;
- caminho de propriedade e posse baseado em `private_handle_t` e Exynos ION.

Ele não exporta `MetadataManager` nem funções `sgr_intf_*`. O Mapper 2.1 do
S20+ é apenas um wrapper passthrough do AOSP sobre esse módulo Gralloc1 e não
possui a implementação moderna de metadata SGR. Portanto, o mapper SGR não
pode ser copiado sobre o mapper do Exynos 990: ele espera outro layout de
handle, outras tabelas de formato, outra área de metadata e outro contrato de
alocação.

### As gerações das APIs também são diferentes

| Aparelho | Allocator | Mapper | Composer | Backend |
| --- | --- | --- | --- | --- |
| Alvo Exynos 990 | HIDL 2.0 | HIDL 2.1 passthrough | HIDL 2.3 | Mali/Samsung Gralloc1 |
| R11s | HIDL 4.0 | HIDL 4.0 `*-impl-sgr` | HIDL 2.4 | Samsung SGR |
| S26+ | AIDL 2 | Mapper Stable-C 5 | Composer3 AIDL 4 | Samsung SGR |

O allocator do S26+ depende diretamente de `mapper.stableC-impl-sgr.so`,
`libeis_utils.so`, `libgralloctypes.so` e `libion_exynos.so`. O serviço
Composer3 também exige o `libui`, `libexynosdisplay` e as extensões HWC do
S26+. Esses componentes não são intercambiáveis com a pilha do Exynos 990.

### GPU e backend de renderização

O vendor do y2s/S20+ analisado contém `libGLES_mali.so`, `vulkan.mali.so` e o
`gralloc.exynos990.so` baseado em Mali/AFBC. O vendor do S26+ não contém esse
par Mali; ele usa `vulkan.samsung.so`, o backend SGR e Composer3. Isso é
compatível com uma GPU Xclipse/SGPU em vez do caminho Mali do Exynos 990.

Mesmo que ambos usem ION/DMA-BUF em alguma camada, o driver da GPU define
formatos, modificadores, alinhamento, cache, fences e metadata privados. Por
isso, a semelhança das APIs AIDL não transforma o mapper do S26+ em um donor
compatível com o y2s.

## Consequências para o bridge

A estratégia atual do bridge está correta: expor APIs modernas de allocator e
mapper enquanto encaminha alocação, importação, lock/unlock e posse para o
Gralloc1 original do Exynos 990. As amostras SGR devem ser usadas somente como
referência de contrato e metadata.

O bridge agora implementa a superfície Stable-C exigida pelo framework sem
alterar o layout nativo do handle:

1. `listSupportedMetadataTypes()` descreve todos os getters padrão obrigatórios
   e os setters de dataspace, blend mode, SMPTE 2086 e CTA 861.3.
2. `setMetadata()` valida o fluxo serializado AOSP e mantém os campos mutáveis
   por backing store, de modo que imports diferentes do mesmo buffer enxerguem
   o mesmo valor.
3. `flushLockedBuffer()` e `rereadLockedBuffer()` verificam que o buffer está
   travado e fazem a barreira DMA-BUF padrão quando o kernel a oferece. O
   Gralloc1 continua responsável pelo lock/unlock e pelas fences.
4. Layout de planos, crop, formato FourCC, tamanho de alocação, proteção e
   stride são derivados apenas dos callbacks Gralloc1 já verificados.

O nome original do descriptor, o modificador DRM privado e HDR dinâmico 2094
não existem nos callbacks públicos do Exynos 990. O bridge usa nome/modificador
de fallback e marca HDR 2094 como não suportado; não injeta offsets privados do
SGR nem copia binários do S26+.

## Próximo limite de implementação

1. Manter `gralloc.exynos990.so`, o userspace Mali e o HWC2 Samsung do Exynos
   990 sem substituição.
2. Ampliar o adaptador de metadata padrão do bridge usando somente callbacks
   Gralloc1 verificados e um cache de metadata por processo quando o framework
   exigir um campo mutável.
3. Adicionar um modo de rastreamento que registre método Mapper 5, ID do
   buffer, uso, formato, resultados de lock/unlock e fences sem despejar o
   conteúdo dos buffers.
4. Executar o teste de alocação existente junto com câmera, vídeo, suspensão/
   retomada da tela e jogos prolongados antes de alterar a seleção VINTF.
5. Remover patches de compatibilidade somente depois que `service list`,
   `lshal`, `dumpsys SurfaceFlinger` e a contabilidade de DMA-BUF confirmarem
   que o bridge é o caminho ativo e permanece equilibrado.

Nenhum binário SGR do R11s ou S26+ deve ser instalado na vendor do y2s. O
resultado útil dessas vendors é o mapa recuperado de APIs e metadata, não um
donor binário.

## Contrato de câmera confirmado no binário do y2s (22/10/2026)

Além dos símbolos exportados, o `mali_gralloc_lock_ycbcr()` e o
`mali_gralloc_lock_flex_async()` foram desassemblados no
`gralloc.exynos990.so` original. A implementação Stable-C usa somente os
campos confirmados nesse caminho:

| Campo do handle | Offset | Uso observado no driver |
| --- | ---: | --- |
| formato de alocação usado pelo lock/flex | `0x50` | seleciona `0x200`, `0x201` e os formatos flexíveis suportados |
| stride Y | `0x5c` | stride da plane Y |
| offset de croma | `0x68` | base da croma intercalada ou uma plane YV12 |
| stride de croma | `0x6c` | stride comum de Cb/Cr |
| segundo offset YV12 | `0x78` | a outra plane de croma YV12 |

O disassembly confirma que `0x200` é NV12 (Cb em `offset`, Cr em
`offset + 1`), `0x201` é NV21 (Cr em `offset`, Cb em `offset + 1`) e YV12
mantém Cb em `+0x78` e Cr em `+0x68`. O mapper não assume os offsets de
`mapper.stableC-impl-sgr.so`; eles pertencem a outro handle e outra GPU.

Os mesmos símbolos mostram que o driver rejeita AFBC ao tentar produzir um
`android_flex_layout` e exige `LOCK_FLEX` para os formatos YUV compatíveis.
Por isso o bridge converte `lock()` para `GRALLOC1_FUNCTION_LOCK_FLEX` nesses
formatos e retorna erro explícito para um formato interno que o driver não
consegue descrever com segurança. Essa rejeição é preferível a fabricar
planes que fariam `ImageReader.nativeCreatePlanes()` receber ponteiros nulos.
