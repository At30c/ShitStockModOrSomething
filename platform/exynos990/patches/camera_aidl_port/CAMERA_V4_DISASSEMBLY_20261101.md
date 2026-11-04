# Desmontagem estática das bibliotecas Camera AIDL V4

Data: 01/11/2026

Arquivos analisados:

```text
out/target/y2s/work_dir/system/system/lib64/android.hardware.camera.device-V4-ndk.so
out/target/y2s/work_dir/system/system/lib64/android.hardware.camera.provider-V4-ndk.so
```

A análise foi feita com `readelf`, `nm/c++filt`, `strings` e
`llvm-objdump` AArch64. Não há execução de código proprietário nesta etapa.
O comando reproduzível está em
`disassemble_camera_v4.sh`.

## Evidências da ABI

As duas bibliotecas são ELF AArch64, para Android 37, e estão stripped. Os
dois símbolos `Bn*::getInterfaceVersion(int*)` retornam literalmente `4`,
confirmando que o sufixo V4 corresponde à versão efetiva da interface, não a
um simples alias de compatibilidade.

Os hashes AIDL encontrados nas seções de strings são:

```text
android.hardware.camera.device: 6e6878817de92e03fd52d5f10937714862ab4922
android.hardware.camera.provider: 6d711578fd7d8ed6b5ab3a94743c4df77f6cdeaa
```

Esses valores devem ser mantidos separados ao gerar os stubs; não se deve
atribuir o hash do provider à interface device.

## Dependências reais

`android.hardware.camera.device-V4-ndk.so` importa:

```text
libbinder_ndk.so
android.hardware.graphics.common-V7-ndk.so
android.hardware.common-V2-ndk.so
android.hardware.common.fmq-V1-ndk.so
android.hardware.camera.common-V1-ndk.so
android.hardware.camera.metadata-V3-ndk.so
libc++.so, libc.so, libm.so, libdl.so
```

O provider V4 importa o device V4, camera common V1 e binder NDK. Isso é a
fronteira de transporte; não é uma lista de drivers de sensor ou GPU.

## Contratos úteis para o S20+

O device V4 contém serialização Binder (`readFromParcel`/`writeToParcel`) para:

```text
Stream, HalStream, StreamConfiguration, StreamBuffer
BufferCache, BufferRequest, StreamBufferRet, StreamBuffersVal
CaptureRequest, CaptureResult, PhysicalCameraSetting
PhysicalCameraMetadata, CameraMetadata, NotifyMsg, ShutterMsg
ConfigureStreamsRet, StreamGroupState
CameraOfflineSessionInfo, OfflineRequest, OfflineStream
```

As operações de sessão exportadas são:

```text
configureStreams / configureStreamsV2
processCaptureRequest
getCaptureRequestMetadataQueue / getCaptureResultMetadataQueue
signalStreamFlush(streamIds, streamConfigCounter)
repeatingRequestEnd
switchToOffline
flush / close
```

Os callbacks AIDL incluem `processCaptureResult`, `notify`,
`requestStreamBuffers` e `returnStreamBuffers`. Esse conjunto explica por que
o preview pode abrir enquanto foto, cache ou fences ainda falham: abrir a
sessão cobre somente a primeira camada; o caminho completo precisa preservar
cada `bufferId`, `NativeHandle`, acquire fence e release fence.

O provider exporta `getCameraIdList`, `getCameraDeviceInterface`,
`getVendorTags`, `getConcurrentCameraIds`,
`isConcurrentStreamCombinationSupported` e `notifyDeviceStateChange`. Ele
também publica o callback de estado físico de câmera, que é necessário para
que IDs lógicos e físicos permaneçam coerentes.

O device ainda expõe `getPhysicalCameraCharacteristics`,
`getSessionCharacteristics`, `isStreamCombinationWithSettingsSupported`,
`warmUp`, `getTorchStrengthLevel`, `turnOnTorchWithStrengthLevel` e
`openInjectionSession`. No S20+, os três últimos recursos devem ser ligados
somente quando houver backend Camera3 original correspondente; anunciar uma
capacidade sem implementação quebra a abertura ou o torch.

## Aplicação no port do S20+

O código em `src/` usa os contratos V4 para a fronteira pública, mas conserva:

1. IDs e características enumerados por `camera.exynos990.so`;
2. `private_handle_t` Mali original do S20+;
3. `GraphicBufferMapper`/HandleImporter para importar o handle antes do HAL;
4. opção Samsung e ID privado somente na estrutura Camera3 compatível do S20+;
5. metadata física somente quando ela veio do backend original.

O V4 não fornece um novo formato de buffer nem um driver de câmera. Ele fornece
parcelamento, ownership e regras de transporte. Copiar um `SGR handle` ou IDs
do S26+ continuaria incorreto.

## Limites identificados

O V4 possui offline, injection, grupos e multi-câmera. O Camera3 Exynos 990
original não possui equivalentes completos para todos eles. O adaptador deve
recusar explicitamente o recurso que não puder representar, em vez de
convertê-lo para preview comum. Preview, captura, vídeo, troca de câmera,
zoom, RAW, ImageReader, fences e buffers protegidos continuam sendo testes
obrigatórios no aparelho.

## Pesquisa pública em projetos Git — 2026-11-01

Foi feita uma busca por implementações e registros públicos do pipeline
ExynosCamera. Não foi encontrado código-fonte público da implementação
proprietária Samsung para `libexynoscamera3.so`, para o handle privado `0x11d`
ou para `m_previewFrameHandler`. Os resultados úteis são registros de execução
publicados no GitHub e o código aberto do Camera HAL3/AIDL do AOSP.

### Contrato público AOSP usado como referência

* A documentação [Camera HAL3 buffer management API](https://source.android.com/docs/core/camera/buffer-management-api)
  exige que `maxBuffers` represente a capacidade real do HAL. Quando o limite
  é atingido, o HAL deve aguardar a devolução de buffers; aceitar requisições
  além da capacidade produz starvation, frames repetidos e falhas de sessão.
* A implementação AIDL pública está em
  [`AidlCamera3Device.cpp`](https://android.googlesource.com/platform/frameworks/av/+/6953e3a76e0d3a4d303ae0e6475b57045ee041da/services/camera/libcameraservice/device3/aidl/AidlCamera3Device.cpp)
  e no tratamento de saídas em
  [`AidlCamera3OutputUtils.cpp`](https://android.googlesource.com/platform/frameworks/av/%2B/dedc9978841b3d03f579373b614508bcbb7407c2/services/camera/libcameraservice/device3/aidl/AidlCamera3OutputUtils.cpp).
  Esses arquivos são a referência para `processCaptureResult`,
  `requestStreamBuffers`, `returnStreamBuffers`, acquire fences, release fences
  e `flush`.
* A contraparte HIDL pública está em
  [`HidlCamera3Device.cpp`](https://android.1.googlesource.com/platform/frameworks/av/%2B/6a7795992745088692e3f5f8bc4812ecf4e0efa3/services/camera/libcameraservice/device3/hidl/HidlCamera3Device.cpp),
  útil para comparar a diferença de ownership e não para manter uma chamada
  HIDL escondida dentro do provider AIDL.

### Relação com o sintoma atual do y2s

Na captura local da revisão r8, o pool FLITE foi criado com oito buffers e o
HAL passou a registrar `Failed to get Internal Bayer Buffer: 12` e
`Invalid bayer buffer index: 12` a partir do nono frame. A ramificação de
preservação do handle privado não foi executada nessa requisição: o caminho
problemático é a devolução/contabilidade do buffer interno Bayer, e não uma
prova de que o handle `0x11d` deva ser convertido para um handle SGR.

As próximas alterações devem comparar o adaptador AIDL com a ordem observada
nos registros acima e com o contrato AOSP: limitar a fila ao número real de
buffers, devolver cada `bufferId` exatamente uma vez, propagar acquire e
release fences e liberar o pool interno no `flush`. O handle privado original
do Mali continua preservado até que esses invariantes sejam validados.
