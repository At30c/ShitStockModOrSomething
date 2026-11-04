# Auditoria da rota AIDL da câmera no S26+ e no y2s

## Resultado

O S26+ usa dois contratos AIDL diferentes que participam da câmera:

1. `android.hardware.camera.provider` AIDL v3 para publicar o provider e as
   sessões de câmera;
2. `android.hardware.graphics.allocator` AIDL v2 mais
   `mapper.stableC-impl-sgr.so` para alocar, importar, bloquear e descrever os
   buffers de câmera.

O y2s não possui o primeiro contrato na vendor. Ele publica o provider HIDL
`android.hardware.camera.provider@2.6` e
`vendor.samsung.hardware.camera.provider@4.0`. O HAL interno ainda é uma
implementação Camera3 C (`camera.exynos990.so`) que chama o Gralloc1 Mali por
`libGrallocMapperCamera.so`.

Portanto, copiar o provider AIDL ou o mapper SGR do S26+ não é uma conversão
válida. O provider AIDL do S26+ é uma camada sobre um HAL de câmera, sensores,
formatos e handles SGR diferentes.

## Como o S26+ entrega a câmera

O serviço do dump é:

```
vendor/bin/hw/vendor.samsung.hardware.camera.provider-service_64
vendor/etc/init/vendor.samsung.hardware.camera.provider-service_64.rc
vendor/etc/vintf/manifest/vendor.samsung.hardware.camera.provider-service.xml
```

O manifest registra:

```
android.hardware.camera.provider/ICameraProvider/internal/0  (AIDL v3)
```

O executável importa as interfaces AIDL do provider e do device, incluindo
`android.hardware.camera.provider-V3-ndk.so`,
`android.hardware.camera.device-V3-ndk.so`,
`vendor.samsung.hardware.camera.provider-V1-ndk.so` e
`vendor.samsung.hardware.camera.device-V1-ndk.so`. Ele publica o serviço como
`cameraservice` e entrega sessões AIDL para o framework Android 17.

O provider não implementa a captura sozinho. Ele carrega o HAL de câmera
`camera.s5e9965.so` e as bibliotecas `libsamsungcamerahal.so` e
`libsamsungcamerahalutils.so`. O HAL continua expondo internamente a cadeia
Camera3 (`camera3_stream_configuration`, `camera3_device` e
`camera3_capture_request`). O AIDL é o transporte externo; o pipeline de
sensor/ISP continua proprietário.

## Como os buffers chegam à câmera no S26+

O allocator AIDL do S26+ é iniciado por:

```
vendor/bin/hw/android.hardware.graphics.allocator-aidl-service-sgr
vendor/etc/init/android.hardware.graphics.allocator-aidl-service-sgr.rc
```

O manifest principal registra `IAllocator/default` na versão 2. O serviço
retorna o sufixo Stable-C do mapper, e o framework carrega:

```
vendor/lib64/hw/mapper.stableC-impl-sgr.so
```

O contexto SELinux do mapper é:

```
mapper/stableC-impl-sgr u:object_r:hal_graphics_mapper_service:s0
```

O mapper SGR contém uma implementação específica para câmera
(`CameraFormatManager`) e trata `CAMERA_INPUT`, `CAMERA_OUTPUT`, formatos YUV,
plane layouts, alinhamento, metadata e handles SGR. Esse é o ponto que evita
que o provider AIDL receba um buffer com geometria diferente da esperada pelo
HAL.

O provider AIDL também mantém dependências de
`android.hardware.graphics.mapper@2.0.so`, `@3.0.so` e `@4.0.so`. Isso mostra
que a migração da câmera do S26+ não removeu toda a ABI antiga de uma vez;
algumas rotas de compatibilidade continuam disponíveis mesmo com allocator e
provider AIDL.

## Diferenças do y2s

O y2s publica:

```
android.hardware.camera.provider@2.6::ICameraProvider/legacy/0
vendor.samsung.hardware.camera.provider@4.0::ISehCameraProvider/legacy/0
```

O provider depende de:

```
android.hardware.camera.provider@2.4.so
vendor.samsung.hardware.camera.provider@4.0.so
vendor.samsung.hardware.camera.provider@4.0-legacy.so
android.hidl.allocator@1.0.so
android.hidl.memory@1.0.so
```

O HAL `camera.exynos990.so` depende de
`android.hardware.graphics.allocator@2.0.so`, `libhardware.so` e
`libexynoscamera3.so`. O caminho de imagem usa
`libGrallocMapperCamera.so`, que chama diretamente:

```
mali_gralloc_lock
mali_gralloc_lock_flex_async
mali_gralloc_lock_ycbcr
mali_gralloc_unlock
mali_gralloc_get_num_flex_planes
```

`libexynoscamera3.so` também calcula usos Gralloc1 específicos para câmera,
ZSL, vídeo e composição. Esses valores não podem ser substituídos pelo layout
SGR do S26+.

## Conclusão para a migração

A primeira etapa correta é criar um **provider AIDL adaptador** para o y2s que:

1. publique `android.hardware.camera.provider/ICameraProvider/internal/0`;
2. carregue o `camera.exynos990.so` existente pelo contrato Camera3;
3. converta `ICameraDeviceSession` AIDL para
   `camera3_stream_configuration`, requests, resultados e fences;
4. mantenha `libGrallocMapperCamera.so` para os handles Mali do Exynos 990;
5. use o allocator/mapper AIDL somente para os buffers que passam pelo
   framework, sem copiar `mapper.stableC-impl-sgr.so`.

O provider AIDL pode coexistir inicialmente com o mapper HIDL usado pelo HAL
legado. Depois de validar preview, captura, vídeo, ZSL, RAW e câmera frontal,
podemos remover o provider HIDL. Remover o mapper HIDL antes dessa validação
quebraria a rota `libGrallocMapperCamera.so`, porque ela ainda chama a ABI
Gralloc1/Mali diretamente.

### Evidências dos binários auditados

```
S26+ provider AIDL:
6a6002f0a30bf1a462a3bcdd67e88a179e020ae2727279254e257700b33850b9

S26+ camera.s5e9965.so:
b0cd5e5377cebf397fbd9f2084bd8da0f7cc0fa9290eed3bb2d72cfde8c5a7f8

y2s provider HIDL:
c040309023f81b1d86781644d846f2488f4e0549d6462ee791b7945c682d210b

y2s camera.exynos990.so:
357d209d3b40c664d7097edb21c29ed7d2d4c38154b2efc119a1f2b6df0c0844
```

## Ajuste baseado no driver original

O bridge não usa somente os nomes de API do S26+. O `gralloc.exynos990.so`
original do y2s foi desassemblado para confirmar o contrato que a câmera já
usa. `mali_gralloc_lock_ycbcr()` lê o formato de alocação em
`private_handle_t + 0x50`, o
stride Y em `+0x5c`, o offset/stride de croma em `+0x68/+0x6c` e o segundo
offset planar YV12 em `+0x78`. O mesmo código confirma a ordem Cb/Cr de NV12,
NV21 e YV12. Esses valores agora ficam em
`include/exynos990/graphics_contract.h` e são consumidos pelo allocator e pelo
mapper.

Também foi corrigida a conversão de usos: `CAMERA_OUTPUT` vai apenas para o
produtor Gralloc1, `CAMERA_INPUT` apenas para o consumidor, e o bit legado de
`GPU_DATA_BUFFER` não é confundido com `SENSOR_DIRECT_DATA`. O teste isolado
aloca YUV com `CAMERA_OUTPUT` e valida o metadata de uso no round-trip.

Para formatos flexíveis que não estejam entre NV12, NV21 e YV12, o mapper
consulta `mali_gralloc_lock_flex_async()` no próprio handle e serializa as
planes reais; se o driver não oferecer uma descrição válida, retorna
`UNSUPPORTED` com segurança.

Isso é uma etapa de aposentadoria das interfaces HIDL, não uma substituição
cega do backend Mali. O HAL `camera.exynos990.so` continua usando
`libGrallocMapperCamera.so` enquanto a implementação fonte ainda não cobre
AFBC, todos os formatos internos e as fences do driver original.

## Ajuste do formato privado 0x11d (22/10/2026)

A auditoria do `gralloc.exynos990.so` original confirmou que o buffer de
saída da câmera em formato `0x11d` possui Y e UV em DMA-BUFs separados. O
`libGrallocMapperCamera.so` original continua sendo a fonte da obtenção dos
ponteiros por `LOCK_FLEX`; nenhum layout do S26+ foi aplicado ao handle.

O `mapper.exynos990_compat.so` agora fornece um scratch YUV contíguo apenas
durante o lock de CPU desse formato. No unlock, ele copia as linhas para os
planos originais e libera o mapeamento. Locks aninhados são mantidos em pilha
por handle para acompanhar as duas chamadas que o `GraphicBufferMapper` do
Android 17 faz durante o pós-processamento. A imagem de teste foi instalada
com AVB pelo TWRP no aparelho `G985FXXSNHYB1`/`m2s`: ao abrir o preview, o
mapper não voltou a produzir `SIGSEGV`, `SIGBUS`, `BAD_BUFFER` ou
`Function not implemented`.

Na captura manual de 22/10, a rota still também chegou ao fim: o log registrou
`20261022_210331.jpg` (2.700.030 bytes) e `20261022_210341.jpg` (3.037.072
bytes), ambos gravados em `DCIM/Camera` e indexados pelo MediaProvider. Uma
falha posterior ocorreu somente no encerramento de outra sessão, quando o
`eden_runtime` recebeu `SIGSEGV` e a câmera descartou frames pendentes. Isso é
separado do bridge de lock e não invalida as fotos salvas. Os timeouts de 10 ms
do `AutoBeautyPhotoMaker` seguem como sinal de latência do pós-processamento;
o binário com a reutilização de locks aninhados foi compilado, mas ainda deve
ser validado isoladamente no aparelho.
