# Verificação cruzada da entrega de buffers da câmera

Data: 25/10/2026  
Alvo: y2s/m2s, Exynos 990, bootloader `G985FXXSNHYB1`  
Referência de estudo: S26+ (`out/fw/SM-S947B_EUX`)  
Fontes Android consultadas: `hardware/interfaces`, `frameworks/native` e
`hardware/libhardware` no Google Git.

Este documento registra somente fatos observados em binários, disassembly,
logs do aparelho e contratos oficiais do AOSP. Nenhum blob do S26+ foi usado
como driver do y2s.

## 1. Caminho HIDL real do y2s

Arquivos auditados:

```text
out/fw/SM-G986B_AUT/vendor/lib64/libGrallocMapperCamera.so
out/fw/SM-G986B_AUT/vendor/lib64/libexynoscamera3.so
out/fw/SM-G986B_AUT/vendor/lib64/hw/android.hardware.graphics.mapper@2.0-impl-2.1.so
out/fw/SM-G986B_AUT/vendor/lib64/hw/gralloc.exynos990.so
```

### 1.1 `lock(void**)`

No símbolo ARM64
`android::GrallocMapperCamera::Mapper::lock(..., void**)`, endereço `0x7a84`:

```text
0x7aa0  mov x0, xzr
0x7aac  bl mali_gralloc_lock_async(...)
```

O restante dos argumentos é montado assim:

```text
x1 = native_handle do buffer
x2 = usage legado recebido pelo Mapper
x3..x6 = left, top, width, height da Rect
x7 = ponteiro de saída
[sp] = acquire fence
```

Portanto, o `private_module_t` passado ao `mali_gralloc_lock_async()` é
explicitamente `nullptr`. O retorno de erro é convertido para o erro HIDL.

### 1.2 `lock(YCbCrLayout)`

No símbolo ARM64 equivalente, endereço `0x7aec`, o binário repete o mesmo
contrato:

```text
0x7b18  mov x2, stack_layout
0x7b1c  mov x0, xzr
0x7b38  bl mali_gralloc_get_num_flex_planes(nullptr, handle, &count)
...
0x7bac  mov x0, xzr
0x7bbc  bl mali_gralloc_lock_flex_async(nullptr, handle, usage,
                                         left, top, width, height,
                                         &layout, acquire_fence)
```

Depois do lock, o mapper valida a descrição flexível e copia para o
`YCbCrLayout` HIDL:

```text
y  = plane[0].top_left
cb = plane[1].top_left
cr = plane[2].top_left
yStride    = plane[0].v_increment
cStride    = plane[1].v_increment
chromaStep = plane[1].h_increment
```

Quando a descrição é inválida, ele chama
`mali_gralloc_unlock(nullptr, handle)` e retorna erro. A chamada a
`mali_gralloc_unlock` também usa `x0 = nullptr` no disassembly.

### 1.3 Quem chama esse Mapper

`libexynoscamera3.so` possui símbolos indefinidos exatamente para os dois
overloads HIDL de `android::GrallocMapperCamera::Mapper::lock` e declara como
dependências:

```text
android.hardware.graphics.allocator@2.0.so
android.hardware.graphics.mapper@2.0.so
libGrallocMapperCamera.so
libhidlbase.so
```

O `android.hardware.graphics.mapper@2.0-impl-2.1.so` é um passthrough HIDL que
exporta `HIDL_FETCH_IMapper`. Ele é uma rota de framework; a câmera também
possui a rota privada acima, ligada diretamente a `libGrallocMapperCamera.so`.

## 2. O contrato oficial HIDL/AOSP

O contrato AOSP de `IMapper@2.0` define que `lock()` e `lockYCbCr()` recebem:

```text
buffer importado
CPU usage
accessRegion
acquireFence
```

O mapper deve esperar a acquire fence antes de expor a memória e, no
`unlock()`, devolver uma release fence quando houver trabalho pendente. O
`lockYCbCr()` deve retornar os ponteiros e strides dos planos Y, Cb e Cr.

No framework, `GraphicBufferMapper::lockAsync()` converte os usages
Gralloc1 produtor/consumidor para o usage legado e encaminha a acquire fence;
`lockAsyncYCbCr()` faz o mesmo para o layout YCbCr. A câmera não recebe um
`byte[]` pelo Binder: recebe um `native_handle` de buffer e sincronização por
fences.

No Camera3, cada `camera3_stream_buffer_t` contém o handle nativo, status,
acquire fence e release fence. O HAL deve esperar a acquire fence antes de
escrever, retornar `acquire_fence = -1` e fornecer a release fence ao devolver
o buffer ao framework.

## 3. Caminho observado no S26+

Arquivos auditados:

```text
out/fw/SM-S947B_EUX/vendor/lib64/libsamsungcamerahwl_impl.so
out/fw/SM-S947B_EUX/vendor/lib64/hw/mapper.stableC-impl-sgr.so
out/fw/SM-S947B_EUX/vendor/bin/hw/android.hardware.graphics.allocator-aidl-service-sgr
```

No símbolo ARM64
`android::hardware::camera::common::helper::HandleImporter::importBufferInternal`
(`libsamsungcamerahwl_impl.so`, região `0x38e50`), o S26+ faz:

```text
GraphicBufferMapper::GraphicBufferMapper()
GraphicBufferMapper::importBufferNoValidate(rawHandle, &importedHandle)
```

No símbolo `HandleImporter::lockYCbCr` (`0x38f10`), ele faz:

```text
GraphicBufferMapper::preloadHal()
GraphicBufferMapper::lockYCbCr(importedHandle, usage, Rect, &android_ycbcr)
```

O `android_ycbcr` é zerado antes da chamada e o resultado é devolvido ao
pipeline da câmera. O binário da câmera não chama diretamente
`AIMapper_loadIMapper`, `mali_gralloc_lock_flex_async` ou
`libGrallocMapperCamera.so`.

Nesse aparelho, `GraphicBufferMapper` do `libui` resolve o mapper gráfico
Stable-C publicado pelo allocator AIDL. O `mapper.stableC-impl-sgr.so` exporta
`AIMapper_loadIMapper`, `CameraFormatManager` e getters de metadata/plane
layout SGR. O contrato SGR informa formato solicitado, formato FourCC,
modificador, número de planos, offsets, strides e subsampling.

## 4. Diferença comprovada

| Etapa | y2s/Exynos 990 | S26+ |
|---|---|---|
| Provider da câmera | HIDL Camera3/Samsung | AIDL Camera Provider v3 |
| Importação usada pela câmera | `Mapper::lock` privado + Gralloc1/Mali | `GraphicBufferMapper::importBufferNoValidate` |
| Lock YUV | `mali_gralloc_lock_flex_async(nullptr, ...)` | `GraphicBufferMapper::lockYCbCr(...)` → Stable-C |
| Handle | `private_handle_t` Exynos 990, formato privado `0x11d` observado no preview | handle SGR com metadata SGR |
| Metadata de planos | estrutura `android_flex_layout_t` do Mali | `PlaneLayout`/metadata Stable-C |
| Sincronização | acquire/release fence passada ao helper Mali | acquire/release fence do `GraphicBufferMapper`/Stable-C |

O fato decisivo é que o S26+ não “traduz” um handle Exynos 990: ele usa um
allocator e um layout SGR próprios. A semelhança do nome `lockYCbCr` não torna
os formatos intercambiáveis.

## 5. Consequência para o bug verde/preto

O disassembly invalida a hipótese de que o y2s original exigia um
`hw_module_t` não nulo. O código do bridge deve manter `nullptr` para os
helpers Mali até que um trace do próprio aparelho prove o contrário.

Nos logs atuais do Composer3, o handle de preview é `1440x1080`, formato
privado `0x11d`. O `LOCK_FLEX` retorna ponteiros, mas a amostragem observada
foi `Y/Cb/Cr = 0/0/0`; converter isso para RGBA inevitavelmente gera verde
uniforme. Entregar o handle `0x11d` diretamente ao HWC2 também é inválido se o
HWC2 não interpretar esse layout privado, podendo resultar em verde ou preto.

Assim, o próximo teste correto não é trocar o contexto HIDL por tentativa. É
capturar a acquire fence e o conteúdo real após o lock no mesmo processo,
comparar `android_flex_layout_t` com os offsets confirmados em
`gralloc.exynos990.so`, e só então decidir entre conversão YUV→RGBA ou uma
rota HWC2 que conheça `0x11d`.

## 6. Fontes oficiais consultadas

- AOSP HIDL Mapper 2.0: `graphics/mapper/2.0/IMapper.hal` — contrato de
  `lock`, `lockYCbCr`, acquire fence e release fence.
- AOSP HIDL Allocator 2.0: `graphics/allocator/2.0/IAllocator.hal` — retorno de
  stride e handles brutos.
- AOSP Stable-C Mapper: `graphics/mapper/stable-c/include/.../IMapper.h` —
  `AIMapper_loadIMapper`, import/free/lock e metadata.
- AOSP `frameworks/native/libs/ui/GraphicBufferMapper.cpp` — importação,
  conversão de usage, lock YCbCr e fences.
- AOSP `hardware/libhardware/include/hardware/camera3.h` — ownership do
  `native_handle` e regras de acquire/release fence do Camera3.
- AOSP Composer3 `LayerCommand.aidl` e `DisplayCommand.aidl` — buffer handle,
  composição e acquire fence enviados pelo SurfaceFlinger.

URLs:

```text
https://android.googlesource.com/platform/hardware/interfaces/+/master/graphics/mapper/2.0/IMapper.hal
https://android.googlesource.com/platform/hardware/interfaces/+/79d13ff0f5cd3c4242445baf5b2f01a52f0ed06f/graphics/allocator/2.0/IAllocator.hal
https://android.googlesource.com/platform/hardware/interfaces/+/refs/heads/main/graphics/mapper/stable-c/include/android/hardware/graphics/mapper/IMapper.h
https://android.googlesource.com/platform/frameworks/native/+/master/libs/ui/GraphicBufferMapper.cpp
https://android.googlesource.com/platform/hardware/libhardware/+/main/include_all/hardware/camera3.h
https://android.googlesource.com/platform/hardware/interfaces/+/d6262f55d828a9f34ff3f5750efc74888e00a346/graphics/composer/aidl/android/hardware/graphics/composer3/LayerCommand.aidl
```

## 7. Medição ao vivo: Foto no y2s com a ponte AIDL global (2026-10-29)

A medição foi feita no y2s iniciado, com a câmera frontal aberta no modo
Foto, BeautyPhotoMaker ativo e a configuração do usuário preservada
(front_photo_beauty_type=2, nível de suavização 2).

### 7.1 Caminho stock confirmado em execução

cameraserver mantém carregado
/vendor/lib64/libGrallocMapperCamera.so. Portanto, dentro do HAL, a rota
continua sendo:

    libexynoscamera3.so
      -> GrallocMapperCamera::Mapper::lock(YCbCrLayout)
      -> mali_gralloc_get_num_flex_planes(nullptr, private_handle_t, ...)
      -> mali_gralloc_lock_flex_async(nullptr, private_handle_t, usage, ..., acquireFence)
      -> planos Y/Cb/Cr para a câmera
      -> mali_gralloc_unlock(nullptr, private_handle_t)

O bridge AIDL não substitui esse mapper e não deve fazê-lo. Ele só recebe o
buffer de preview depois que o Camera3 o produziu para a SurfaceView.

### 7.2 O gargalo observado

A sessão Foto aberta pelo BeautyPhotoMaker configurou oito streams no HAL:

| Saída | Formato | Tamanho | Máximo de buffers |
|---|---|---:|---:|
| preview | privado/IMPL_DEF (0x11d) | 1440×1080 | 9 |
| callback de preview | YUV_420_888 | 1440×1080 | 9 |
| captura 1 | JPEG + YUV + RAW16 | 3648×2736 | 7/5/5 |
| captura 2 | JPEG + YUV | 2944×2208 | 7/5 |
| miniatura | YUV_420_888 | 512×384 | 7 |

Os logs do HAL registraram sehProcessCaptureRequest_5_0 entre 100 e 246 ms e
a telemetria da própria câmera alternou entre 10 e 20 fps em Foto. O modo
Vídeo não cria a mesma sessão fotográfica e por isso não apresenta a mesma
lentidão.

O SurfaceFlinger ainda identifica a SurfaceView como formato 0x11d e
composição DEVICE; o bridge usa uma alocação RGBA de compatibilidade apenas
para o HWC2, porque entregar o private_handle_t cru por Composer3 já foi
validado como verde/preto. Essa cópia deve continuar sendo otimizada, mas não
explica, sozinha, as pausas de 100+ ms que já ocorrem no Camera HAL.

### 7.3 Direção correta da correção

Não desativar Beauty, Night ou Foto. A correção deve fazer a câmera Android 17
montar, no y2s, uma configuração de streams que o HAL Exynos 990 consiga
sustentar: manter preview, callback YUV necessário à beleza e os buffers de
captura usados quando o obturador for acionado, sem anunciar para o app uma
topologia de RAW/múltiplas capturas incompatível com a sessão contínua.

Antes de alterar essa política, comparar cada capacidade de stream exposta pelo
HAL e a configuração equivalente da câmera stock G986B. A validação deve
cobrir preview, foto, troca frontal/traseira, vídeo e os modos que usam YUV ou
RAW.

## 8. Adaptação do mapper AIDL ao contrato stock da câmera (29/10/2026)

O `mapper.exynos990_compat.so` passou a usar, exclusivamente para o formato
privado `0x11d`, o mesmo contrato observado no
`/vendor/lib64/libGrallocMapperCamera.so` original do y2s:

- `mali_gralloc_get_num_flex_planes(nullptr, handle, &count)`;
- `mali_gralloc_lock_flex_async(nullptr, handle, usage_legado, rect, layout, acquire_fence)`;
- `mali_gralloc_unlock(nullptr, handle)`.

Antes desta alteração, a rota AIDL chamava o callback Gralloc1 genérico, separando `producerUsage` e `consumerUsage` e passando `bridge().device`.
Isso não corresponde ao caminho Camera3 proprietário: ele usa
`private_module_t == nullptr` e recebe uma única máscara de uso legada.

A adaptação preserva os planos DMA-BUF Y/Cb/Cr fornecidos pelo Mali. A cópia
para uma área linear existe apenas porque `IMapper::lock()` do Stable-C devolve
um único ponteiro, enquanto o formato proprietário tem planos separados. O
`libGrallocMapperCamera.so` stock continua no lugar e os clientes Camera3
continuam vinculados a ele; nenhum blob proprietário foi substituído.

A imagem de teste `vendor-graphics-camera-stock-contract-20261029-avb.img`
foi reconstruída a partir da vendor global já instalada, alterando somente
`/vendor/lib64/hw/mapper.exynos990_compat.so`. Ela preserva os contextos
`u:object_r:same_process_hal_file:s0` e possui footer AVB
`SHA256_RSA4096` com a chave de teste do projeto.

## 9. Medição do gargalo do preview global (29/10/2026)

Com a câmera aberta no aparelho, uma amostra de cinco segundos com
`simpleperf` no processo
`android.hardware.graphics.composer3-service.exynos990` registrou 9.017
amostras e 4.271.063.701 ciclos. **90,80%** delas ficaram nos offsets
`+0x32aac` a `+0x32ad0` de `libexynos990_composer3_contract.so`, que são o
laço NEON de conversão NV21 (`0x11d`) para RGBA. O processo atingiu 100% de
um núcleo durante a medição.

A vendor possui o caminho leve para esse trabalho: `hwcomposer.exynos990.so`
carrega `libacryl.so`, e este expõe os compositores MPP/G2D/M2M, inclusive
conversão CSC e fences. O Composer3 atual só chega a esse caminho depois de
entregar um buffer RGBA ao HWC2; por isso a conversão acontece antes, em CPU.

O próximo trabalho é adaptar a passagem de `private_handle_t` e fences ao
MPP/G2D proprietário, preservando o formato `0x11d`, para que a conversão
YUV→RGB seja feita pelo hardware. Reduzir ou desativar Beauty/Night não trata
esta causa e não deve ser usado como correção.

## 10. Contenção do custo de conversão por frame (29/10/2026)

Como a chamada direta ao handle `0x11d` reduziu o uso de CPU, mas deixou o
preview dependente de uma interpretação que o HWC2 atual não confirmou, o
caminho bruto continua desligado por padrão (`persist.vendor.exynos990.camera_mpp=0`).
O caminho compatível continua usando o `LOCK_FLEX` original e o scratch RGBA,
mas agora reutiliza o último buffer convertido durante o intervalo configurado.

O intervalo padrão é de 30 conversões por segundo. A propriedade
`persist.vendor.exynos990.camera_convert_fps` aceita valores de 5 a 60; o
limite é aplicado por camada e não descarta o buffer que o HWC2 ainda está
usando. Quando o primeiro frame ainda não existe, a conversão ocorre sem
espera adicional. Isso reduz o trabalho do laço NV21→RGBA e evita que o
Composer ocupe um núcleo inteiro quando a câmera entrega mais frames do que a
interface precisa.

O ajuste foi compilado no Composer3 AIDL e no módulo instalável. A imagem AVB
`/tmp/vendor-graphics-camera-rate-limit-20261029-avb.img` foi assinada com
`SHA256_RSA4096`, tem SHA-256
`6fded7d70273059e30da659d69204db8f75a0741442d42c37f5319833c81e893` e foi
gravada no recovery com `dd` em `/dev/block/bootdevice/by-name/vendor`.
Os primeiros 1 MiB escritos coincidiram com a imagem e o footer AVB de 2112
bytes permaneceu no final da partição. Após o boot, o Composer3 instalado foi
confirmado com SHA-256
`78c00483060afab982f09149588ce3640970170f1a8fe3050c520e133f8e01b5`.

O aparelho iniciou com `persist.vendor.exynos990.camera_mpp=0`; a câmera abriu
sem crash e o processo Composer3 ficou em aproximadamente 1% de CPU durante a
captura. O modo MPP bruto só deve ser reativado depois de corrigir a descrição
do handle privado no HWC2.
