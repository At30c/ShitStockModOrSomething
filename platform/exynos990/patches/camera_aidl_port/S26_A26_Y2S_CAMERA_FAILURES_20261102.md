# Auditoria de Motion Photo, filtros e 64 MP — S26+, A26 e y2s

Data: 02/11/2026

## Método

Foram examinados, sem usar blobs deles em runtime:

* S26+: `vendor.samsung.hardware.camera.provider-service_64` e
  `mapper.stableC-impl-sgr.so`;
* A26: `vendor.samsung.hardware.camera.provider-service_64`;
* y2s: provider HIDL original, provider AIDL em desenvolvimento, mapper
  Exynos 990 e os logs capturados no aparelho.

## Resultado para Motion Photo e filtros

O log do y2s reproduz a sequência completa:

```text
GraphicBuffer 1440x1080 NV21, hal_format=0x11e
mali_gralloc_lock: buffers YUV devem usar GRALLOC1_FUNCTION_LOCK_FLEX
SIGSEGV em libsume_mediabuffer_jni
```

O mapper AIDL tratava somente `0x11d` como formato privado de câmera. O
`0x11e`, embora também seja um buffer YUV privado do Mali, caía no `lock()`
linear. Esse é o motivo verificável dos planos inválidos recebidos pela JNI;
não é um defeito do APK Samsung Camera.

O S26+ confirma a semântica moderna que deve ser atendida: o mapper possui
`CameraFormatManager` e publica formato solicitado, fourcc, modificador,
dataspace, chroma siting, tamanho de alocação e layouts por plano. O handle
SGR do S26+ não é compatível com o Mali e não é usado no y2s. No y2s, a fonte
de verdade dos planos continua sendo `LOCK_FLEX` do próprio gralloc original.

Correção aplicada ao bridge:

* `0x11d` e `0x11e` usam o mesmo caminho `LOCK_FLEX` proprietário;
* a cópia para CPU continua em um buffer linear temporário, preservando os
  ponteiros/strides devolvidos pelo Mali;
* `PLANE_LAYOUTS` para ambos retorna `UNSUPPORTED` até existir uma descrição
  transportável comprovada do handle. Isso evita publicar offsets inventados.

## Resultado para 64 MP

O modo de 64 MP pede a câmera pública `50` e uma saída `9248x6936`. O provider
AIDL atual associa esse alias ao índice físico `2` e usa a metadata desse
índice. A metadata publicada no `dumpsys media.camera` para
`device@1.0/internal/50` ainda termina em `4032x3024`; por isso o app recusa
`9248x6936` antes de configurar a sessão.

O provider HIDL Samsung original não limita a validação ao número físico de
câmeras: o disassembly de `getCameraDeviceInterface_V3_x` aceita uma lista de
IDs especiais antes de construir `SehCameraDevice`. Portanto, reduzir o alias
`50` a `2` na borda AIDL perde uma etapa específica do provider Samsung.

O S26+ contém `FixSensorPixelModesInStreamConfig` junto de
`configureStreams`; o A26 confirma o restante do ciclo AIDL
(`ConvertToHalStreamBuffer`, cache de `bufferId`, `RequestStreamBuffers` e
`ReturnStreamBuffers`). Isso estabelece a ordem correta:

1. preservar o alias público Samsung até a abertura/configuração do backend;
2. obter a metadata real que o backend associa ao alias;
3. anunciar `ANDROID_SENSOR_AVAILABLE_PIXEL_MODES` e as configurações de
   máxima resolução somente se a metadata do backend realmente as fornecer;
4. normalizar `sensorPixelModesUsed` antes de `configure_streams`, como o
   provider do S26+, sem rebaixar silenciosamente máxima resolução para o modo
   padrão.

Ainda não se anuncia `9248x6936`, pois isso sem a etapa 2 faria o HAL abrir o
sensor/modo incorreto e apenas mudaria o erro de lugar.

### Implementação inicial da separação de IDs

O provider AIDL passou a manter três dados distintos para a função 64 MP:

| Dado | Valor inicial | Uso |
| --- | --- | --- |
| ID público | `50` | nome AIDL visto pela Samsung Camera |
| ID de metadata | `50`, com recuo para `2` | `get_camera_info()` |
| ID de abertura | `"50"` | `camera_module_t::open()` |

O disassembly de `SehCameraDevice::getCameraCharacteristics()` confirmou a
rota completa: o construtor converte a string pública com `atoi()` e guarda o
resultado; depois `getCameraCharacteristics()` entrega esse valor diretamente
para `CameraModule::getCameraInfo()`. Portanto, para o alias `50`, o driver
HIDL consulta `get_camera_info(50)`. O provider AIDL reproduz esse contrato e
só recua para `2` se o backend não aceitar o ID especial. A metadata de máxima
resolução só será anunciada se essa consulta retornar capacidades reais.

## FLITE

O limite temporário de quatro requests foi respeitado pelo provider, mas o HAL
ainda esgotou os oito buffers internos `FLITE_BUF`. Logo, o limitador de
requests AIDL não é a causa. A investigação deve seguir a posse e devolução
dos buffers internos após `process_capture_request`, especialmente no fluxo de
captura em máxima resolução.
