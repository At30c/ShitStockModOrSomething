# Auditoria desmembrada do HIDL da câmera

Data: 29/10/2026  
Alvo: `y2s`/Exynos 990  
Fonte principal: `out/target/y2s/work_dir`  
Referência de compatibilidade: `out/fw/SM-G986B_AUT`  
Logs de runtime: `/tmp/y2s-camera-shutter-key-20261029.log`,
`/tmp/y2s-camera-layout-20261029.log` e
`/tmp/y2s-camera-shutter-window-20261029.log`.

Este documento trata “HIDL da câmera” como o conjunto completo do caminho
Camera3 HIDL: provider Samsung, provider Android, interfaces de device,
sessão Camera3, adaptadores de buffer, `camera.exynos990.so`,
`libexynoscamera3.so`, fences e o backend Mali/ION. O Composer3/allocator AIDL
global é documentado apenas para separar os caminhos; ele não é considerado
parte do provider de câmera HIDL.

## 1. Topologia confirmada

O caminho observado é:

```text
CameraService/framework
  -> sec-camera-provider-4-0
  -> vendor.samsung.hardware.camera.provider@4.0-service_64
  -> vendor.samsung.hardware.camera.provider@4.0.so
  -> vendor.samsung.hardware.camera.provider@4.0-legacy.so
  -> camera.device@1.0/3.2/3.3/3.4/3.5-impl.so
  -> vendor.samsung.hardware.camera.device@5.0-impl.so
  -> camera.exynos990.so
  -> libexynoscamera3.so
  -> libGrallocMapperCamera.so
  -> gralloc.exynos990.so + libion_exynos.so + libsync.so
  -> V4L2/FIMC-IS e buffers DMA-BUF do kernel
```

O provider e a sessão são HIDL. O app não conversa diretamente com
`camera.exynos990.so`; ele recebe as respostas pelo CameraService, que
converte as estruturas Camera3 para os parcels HIDL.

## 2. Serviços e VINTF

### 2.1 Provider Android

`vendor/etc/vintf/manifest.xml` declara:

```xml
<hal format="hidl">
    <name>android.hardware.camera.provider</name>
    <transport>hwbinder</transport>
    <version>2.6</version>
    <interface>
        <name>ICameraProvider</name>
        <instance>legacy/0</instance>
    </interface>
    <fqname>@2.6::ICameraProvider/legacy/0</fqname>
</hal>
```

O `rc` publica também as versões anteriores que o framework pode consultar:

```text
android.hardware.camera.provider@2.4::ICameraProvider legacy/0
android.hardware.camera.provider@2.5::ICameraProvider legacy/0
android.hardware.camera.provider@2.6::ICameraProvider legacy/0
```

### 2.2 Extensão Samsung

`vendor/etc/vintf/manifest/deviceManifest.xml` declara:

```xml
<hal format="hidl">
    <name>vendor.samsung.hardware.camera.provider</name>
    <transport>hwbinder</transport>
    <version>4.0</version>
    <interface>
        <name>ISehCameraProvider</name>
        <instance>legacy/0</instance>
    </interface>
</hal>
```

O serviço é iniciado por
`vendor/etc/init/vendor.samsung.hardware.camera.provider@4.0-service_64.rc`:

```text
service sec-camera-provider-4-0 /vendor/bin/hw/vendor.samsung.hardware.camera.provider@4.0-service_64
    interface vendor.samsung.hardware.camera.provider@4.0::ISehCameraProvider legacy/0
    interface android.hardware.camera.provider@2.6::ICameraProvider legacy/0
```

Ele roda no usuário `cameraserver`, com grupos `camera`, `input`, `drmrpc`,
`media_rw`, `sdcard_rw` e `vendor_secdir`, capacidade `SYS_NICE` e perfis
`HighPerformance CameraServiceCapacity`.

### 2.3 Estado no aparelho

Após o último boot, o processo ativo foi:

```text
7101 vendor.samsung.hardware.camera.provider@4.0-service_64
7284 cameraserver
```

`init.svc.sec-camera-provider-4-0=running` e
`init.svc.cameraserver=running`. Não há provider de câmera AIDL ativo no
aparelho.

## 3. Contrato do `ICameraProvider`

O binário `vendor.samsung.hardware.camera.provider@4.0.so` exporta as
implementações HIDL `BpHw`/`BnHw` e os seguintes grupos de operações:

| Operação | Entrega | Evidência |
| --- | --- | --- |
| `getCameraIdList`/`sehGetCameraIdList` | IDs lógicos e físicos disponíveis | símbolos `BpHwSehCameraProvider` |
| `getCameraDeviceInterface_V1_x` | device HIDL 1.x para clientes antigos | símbolo exportado |
| `getCameraDeviceInterface_V3_x` | device HIDL 3.2 para Camera3 | símbolo exportado |
| `getVendorTags` | seções, nomes e tipos de tags Samsung | símbolo exportado |
| `setCallback` | callback de status/plug-in do provider | símbolo exportado |
| `notifyDeviceStateChange` | estado físico do dispositivo | símbolo exportado |
| `isSetTorchModeSupported` | suporte ao flash/torch | símbolo exportado |
| `getConcurrentStreamingCameraIds` | combinações de câmeras simultâneas | símbolo exportado |
| `isConcurrentStreamCombinationSupported` | validação de combinação concorrente | símbolo exportado |
| HIDL base | `interfaceChain`, `getHashChain`, `linkToDeath`, `ping`, `debug` | vtables HIDL presentes |

O provider não produz pixels. Ele localiza o device HIDL, abre uma sessão e
encaminha a configuração e as requisições para o HAL Camera3 nativo.

## 4. Contrato do device e da sessão Camera3

O executável provider importa as interfaces HIDL
`android.hardware.camera.device@1.0`, `@3.2`, `@3.3`, `@3.4`, `@3.5` e
`@3.6`. As implementações presentes na vendor são:

```text
vendor/lib64/camera.device@1.0-impl.so
vendor/lib64/camera.device@3.2-impl.so
vendor/lib64/camera.device@3.3-impl.so
vendor/lib64/camera.device@3.4-impl.so
vendor/lib64/camera.device@3.5-impl.so
vendor/lib64/vendor.samsung.hardware.camera.device@5.0-impl.so
```

O `vendor.samsung.hardware.camera.device@5.0-impl.so` é um adaptador HIDL
Samsung sobre as sessões Camera3. O contrato entregue ao HAL é equivalente a
estas operações Camera3:

| Fase | Entrega ao próximo estágio |
| --- | --- |
| abrir device | `camera3_device_t` e sua tabela `camera3_device_ops_t` |
| inicializar | callbacks para `notify()` e `process_capture_result()` |
| consultar características | `camera_metadata` estático e vendor tags |
| configurar streams | `camera3_stream_configuration_t`, usages, dataspace, rotação e `max_buffers` |
| enviar request | `camera3_capture_request_t`, settings, input buffer e output buffers |
| devolver resultado | `camera3_capture_result_t`, metadata parcial/final, status e release fences |
| flush | encerra requests pendentes e devolve buffers/fences |
| fechar | libera sessão, nodes V4L2 e pools de buffers |

No `camera.exynos990.so` foram confirmados os entrypoints de alto nível:

```text
HAL3_camera_device_configure_streams
HAL3_camera_device_process_capture_request
HAL_isStreamCombinationSupported
HAL_concStreamCombSupported
HAL_getConcurrentStreamingCameraIds
```

No mesmo HAL aparecem `configureStreams`, `initializeDevice`,
`processCaptureRequest` e `construct_default_request_settings` da classe
`ExynosCamera`.

## 5. Streams realmente entregues ao HAL

Na configuração capturada em 29/10, o adaptador HIDL entregou estes streams ao
HAL:

| ID | Formato | Tamanho | Opção | Tipo |
| ---: | --- | ---: | ---: | --- |
| 0 | `IMPLEMENTATION_DEFINED` (`0x22`) | 1440x1080 | `0x1` | OUTPUT preview |
| 1 | `YUV_420_888` (`0x23`) | 1440x1080 | `0x1` | OUTPUT preview |
| 2 | `YUV_420_888` (`0x23`) | 480x360 | `0x101` | OUTPUT auxiliar |
| 3 | `JPEG` (`0x21`) | 4032x3024 | `0x2` | OUTPUT foto |
| 4 | `YUV_420_888` (`0x23`) | 4032x3024 | `0x2` | OUTPUT pós-processamento |
| 5 | `RAW16` (`0x20`) | 4032x3024 | `0x2` | OUTPUT RAW |
| 6 | `RAW16` (`0x20`) | 4864x3648 | `0x340002` | OUTPUT RAW de alta resolução |
| 7 | `YUV_420_888` (`0x23`) | 512x384 | `0x4` | thumbnail |

O log interno do UniHal também registra streams `RAW_CAPTURE` nos tamanhos
4032x3024 e 4864x3648. Após a normalização de usage, esses streams aparecem
com `grallocUsage=0x20003` e `maxBuffers=5`.

O preview de 1440x1080 utiliza o formato privado Exynos `0x11d` no backend
Mali. Esse valor não é o mesmo que o formato público `YUV_420_888`; ele é um
handle privado cujo layout só pode ser obtido por `LOCK_FLEX`/`lock_ycbcr`.

## 6. Contrato de buffers HIDL

Cada `camera3_stream_buffer_t`/estrutura HIDL equivalente entrega:

```text
native_handle_t* buffer
status           (OK ou erro do HAL)
acquire_fence    (fd que o produtor deve esperar)
release_fence    (fd que o consumidor deve esperar)
```

Regras confirmadas pelo contrato Camera3 e pelos símbolos do HAL:

1. O HAL não pode escrever antes de consumir a `acquire_fence`.
2. O retorno da request deve marcar a acquire fence como consumida (`-1` ou
   equivalente no parcel HIDL).
3. Se o HAL ainda estiver usando o DMA-BUF, ele devolve uma release fence.
4. O `native_handle_t` continua pertencendo ao framework; o HAL apenas retém
   a referência durante a request e não fecha os FDs que não possui.
5. O `flush` precisa devolver todos os buffers pendentes, inclusive em erro.

O `libexynoscamera3.so` importa `libsync.so` e exporta a classe
`ExynosCameraFence`, com `getAcquireFence`, `getReleaseFence`, `wait`,
`isValid` e `waitFence`. Isso confirma que fences não são apenas metadados
ignorados: fazem parte do fluxo físico do HAL.

## 7. Contrato privado do mapper/allocator usado pela câmera

`libexynoscamera3.so` declara diretamente:

```text
android.hardware.graphics.allocator@2.0.so
android.hardware.graphics.mapper@2.0.so
libGrallocMapperCamera.so
```

`libGrallocMapperCamera.so` depende de:

```text
libhardware.so
liblog.so
libcutils.so
libGLESv1_CM.so
libion_exynos.so
libsync.so
libutils.so
android.hardware.graphics.mapper@2.0.so
libnativewindow.so
```

Os símbolos exportados que o HAL usa incluem:

```text
mali_gralloc_lock_async
mali_gralloc_lock_ycbcr
mali_gralloc_lock_ycbcr_async
mali_gralloc_lock_flex_async
mali_gralloc_get_num_flex_planes
mali_gralloc_unlock_async
mali_gralloc_unlock
mali_gralloc_ion_map / mali_gralloc_ion_unmap
mali_gralloc_ion_sync_start / mali_gralloc_ion_sync_end
android::GrallocMapperCamera::Mapper::lock(..., void**)
android::GrallocMapperCamera::Mapper::lock(..., YCbCrLayout*)
android::GrallocMapperCamera::Mapper::unlock(...)
```

O disassembly da implementação original confirmou que os helpers privados
Mali recebem `private_module_t* = nullptr`, o `native_handle_t`, usage, região
de acesso e acquire fence. Esse `nullptr` é parte do ABI observado; inserir um
`hw_module_t` diferente muda o contrato e não é uma correção segura.

### 7.1 `lock(void**)`

É usado para buffers que o HAL trata como memória linear. O mapper valida a
região, chama `mali_gralloc_lock_async` e retorna o ponteiro virtual. O
`unlock` chama o helper Mali correspondente e pode devolver uma fence.

### 7.2 `lock(YCbCrLayout*)`

Para YUV, o mapper consulta `mali_gralloc_get_num_flex_planes`, chama
`mali_gralloc_lock_flex_async` e converte `android_flex_layout_t` para o
`YCbCrLayout` HIDL:

```text
y          = plane[0].top_left
cb         = plane[1].top_left
cr         = plane[2].top_left
yStride    = plane[0].v_increment
cStride    = plane[1].v_increment
chromaStep = plane[1].h_increment
```

Se o layout não tiver os planos esperados, o mapper desbloqueia o handle e
retorna erro. AFBC e formatos não representáveis em flex layout não podem ser
tratados como YUV linear.

### 7.3 Handle privado `0x11d`

O trace do aparelho mostrou que o preview `0x11d` possui Y e UV em DMA-BUFs
separados. No layout observado, Y e UV não são uma única região contígua.
Como o limite de Y não é alinhado a página, não é correto fabricar um ponteiro
contíguo apenas com `mmap` dos dois FDs. O adaptador atual usa um scratch para
locks de CPU e copia de volta no `unlock`; o handle Mali original continua
preservado para o HAL/HWC.

## 8. Entregas internas do HAL Exynos

`libexynoscamera3.so` usa:

```text
libexynosv4l2.so       -> nodes V4L2/FIMC-IS
libion_exynos.so       -> alocação e mapeamento DMA-BUF
libsync.so             -> acquire/release fences
libhwjpeg.so           -> JPEG
libcsc.so              -> conversão de espaço/cor
libexynosutils.so      -> utilitários Exynos
libexynoscamera_plugin*.so -> pós-processamento proprietário
```

O fluxo físico é, portanto:

```text
camera3_capture_request
  -> ExynosCamera::processCaptureRequest
  -> ExynosCameraNode/Pipe/MCPipe
  -> V4L2/FIMC-IS
  -> DMA-BUF/ION
  -> ExynosCameraFence
  -> camera3_capture_result
```

Os símbolos do HAL confirmam nós e etapas para sensor, ISP, JPEG, GDC,
remosaic, ZSL, RAW e pós-processamento. O kernel específico de FIMC-IS e os
ioctls proprietários não podem ser reconstruídos integralmente a partir desses
blobs stripped; essa parte permanece marcada como **não decodificada**.

## 9. Metadados e vendor tags

O provider publica `getVendorTags` e o HAL usa `libcamera_metadata.so` para
settings e resultados. Os logs mostraram chamadas para tags Samsung como
`samsung.android.control.nightModeSuggestion` e
`samsung.android.control.nightIconState` que a camada atual não encontra.
Essas mensagens são ausência de tags de metadados, não uma falha do transporte
HIDL nem uma prova de que o buffer esteja corrompido.

## 10. Separação em relação ao AIDL gráfico global

O estado atual do aparelho é deliberadamente híbrido:

```text
Composer3 AIDL global       -> SurfaceFlinger/composição
Allocator AIDL global       -> GraphicBufferAllocator do framework
Mapper Stable-C bridge       -> clientes gráficos selecionados
Camera Provider HIDL 2.6/4.0 -> provider e sessões da câmera
Gralloc/Mapper Mali HIDL    -> ABI privada de camera.exynos990.so
```

O fato de `libui` usar AIDL global não remove as dependências HIDL diretas do
HAL da câmera. O `vendor.samsung.hardware.camera.provider@4.0-service_64`
continua carregando as bibliotecas HIDL de mapper 2.0/3.0/4.0, e
`libexynoscamera3.so` continua ligado a `allocator@2.0`, `mapper@2.0` e
`libGrallocMapperCamera.so`.

## 11. O que foi confirmado e o que falta

### Confirmado

- provider HIDL Android 2.6 e extensão Samsung 4.0;
- sessão Camera3 HIDL 3.2–3.6 e adaptador Samsung device 5.0;
- entrypoints Camera3 de configure/request/flush;
- oito streams reais de preview, foto, vídeo auxiliar, thumbnail e RAW;
- formato privado `0x11d` e layout Y/UV separado;
- contrato `LOCK_FLEX`, `YCbCrLayout`, acquire/release fence e `nullptr` no
  `private_module_t`;
- dependências ELF e cadeia V4L2/ION/sync;
- provider HIDL ativo no aparelho.

### Ainda não confirmado por instrumentação

- tabela completa de ioctls FIMC-IS e seus argumentos no kernel;
- todos os modificadores AFBC e formatos internos não lineares;
- cada FD físico do `private_handle_t` em todos os modos RAW/ZSL;
- timestamp exato de cada acquire/release fence em todas as requests;
- contrato de buffers protegidos sem realizar um teste DRM controlado.

## 12. Consequência para uma futura migração

Não é possível substituir o HIDL da câmera apagando apenas as bibliotecas
`camera.device@*` ou trocando `libGrallocMapperCamera.so`. A migração exigiria
um provider Camera AIDL, um adaptador AIDL de device/session, importação dos
handles Mali, equivalência de `YCbCrLayout`/`PlaneLayout`, ownership de fences,
vendor tags, streams RAW/ZSL e tratamento dos buffers protegidos.

Até esses contratos serem implementados e testados, a configuração correta é
manter o provider HIDL e modernizar somente o caminho gráfico que não altera o
ABI privado do HAL Exynos 990.

## 13. Comandos de reprodução da auditoria

```bash
readelf -d out/target/y2s/work_dir/vendor/bin/hw/vendor.samsung.hardware.camera.provider@4.0-service_64
readelf -d out/target/y2s/work_dir/vendor/lib64/libexynoscamera3.so
nm -D --defined-only out/target/y2s/work_dir/vendor/lib64/libGrallocMapperCamera.so
adb shell su -c 'ps -A -o PID,NAME,ARGS | grep -Ei "camera|cameraserver"'
adb shell su -c 'getprop | grep -Ei "init.svc.*camera|camera\.unihal"'
```
