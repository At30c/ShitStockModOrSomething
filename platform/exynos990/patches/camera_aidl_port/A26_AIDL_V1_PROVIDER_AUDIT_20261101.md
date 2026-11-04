# Auditoria do provider AIDL V1 do Galaxy A26 5G

Data: 01/11/2026

Fonte analisada:

```text
out/a26_vendor_a266b_eux/vendor/bin/hw/vendor.samsung.hardware.camera.provider-service_64
out/a26_vendor_a266b_eux/vendor/etc/vintf/manifest/vendor.samsung.hardware.camera.provider-service.xml
out/a26_vendor_a266b_eux/vendor/etc/init/vendor.samsung.hardware.camera.provider-service_64.rc
```

Firmware: `SM-A266B/EUX`, `A266BXXUCDZJ5`, Android 17 / One UI 9.

## Método

Foi feita somente análise estática por `readelf`, `nm -D`, `c++filt` e
`strings`. O executável arm64 está stripped, portanto esta auditoria usa os
símbolos dinâmicos, as dependências ELF e as cadeias de texto exportadas pelo
binário; ela não executa nem descompila blobs do A26.

O procedimento é reproduzível com
`disassemble_a26_aidl_v1.sh [caminho/para/vendor]`.

## Cadeia encontrada

```text
CameraService
  -> ICameraProvider/internal/0 (AIDL V1)
  -> SCH_AidlCameraProvider
  -> samsung_camera_hal::CameraProvider
  -> SCH_AidlCameraDevice
  -> samsung_camera_hal::CameraDevice
  -> SCH_AidlCameraDeviceSession
  -> samsung_camera_hal::CameraDeviceSession
  -> sensor/ISP e buffers do A26
```

O manifesto declara `android.hardware.camera.provider` em AIDL V1, instância
`internal/0`. A RC registra exatamente a mesma instância em init e executa o
serviço como `cameraserver`, com os grupos `camera`, `media`, `drmrpc` e
`vendor_secdir`.

O provider depende das interfaces NDK públicas
`camera.provider-V1`, `camera.device-V1`, `camera.common-V1`, das extensões
Samsung `vendor.samsung.hardware.camera.{provider,device}-V1`, de
`libbinder_ndk`, `libcamera_metadata`, `libfmq`,
`libsamsungcamerahal` e `libsamsungcamerahalutils`.

## Contratos reconstruídos

Os símbolos dinâmicos demonstram que a implementação Samsung cria um backend
de provider, registra o callback e então dispara callbacks pendentes:

```text
CameraProvider::Create
CameraProvider::SetCallback
CameraProvider::TriggerDeferredCallbacks
CameraProvider::GetCameraIdList / GetCameraIdListAll
CameraProvider::CreateCameraDevice
CameraProvider::NotifyDeviceStateChange
```

Cada dispositivo fornece características, custo de recurso, torch, metadata
física e criação de sessão. A sessão delega `ConfigureStreams`,
`ProcessCaptureRequest`, `SignalStreamFlush`, `Flush`, reconfiguração e
parâmetros ao backend Samsung. Os símbolos e strings também comprovam:

- importação de buffers pelo mapper HIDL com seleção V4, V3 e V2;
- cache de `bufferId` e os callbacks `RequestStreamBuffers` e
  `ReturnStreamBuffers`;
- filas FMQ de metadata de resultado;
- conversão separada para buffers de entrada, saída, resultados, notify,
  vendor tags e extensões `Seh` da Samsung;
- suporte explícito a sessão offline no A26.

O A26 ainda usa Gralloc/Mapper e Composer HIDL. AIDL na câmera é a fronteira
Binder pública; não troca o formato privado de buffer, o ISP ou o driver Mali.

## Adaptação aplicada ao Exynos 990

O y2s usa AIDL V4 porque essa é a ABI disponibilizada pelo seu `/system`.
O backend físico continua exclusivamente o `camera.exynos990.so` e o
`libexynoscamera3.so` do S20+.

Foi adaptada a semântica verificável de `TriggerDeferredCallbacks`: depois de
`setCallback`, o provider Exynos 990 agora enumera cada mapeamento público
somente se `get_camera_info` do backend original devolver metadata estática
válida e publica `PRESENT` para o CameraService. A lista e os callbacks usam
a mesma rotina, evitando que um ID apareça na enumeração mas nunca seja
anunciado ao framework.

Não foram copiados do A26:

- blobs, bibliotecas, IDs físicos, metadata, formatos privados ou opções
  Samsung;
- ABI de stream, heap ION, handle gráfico ou qualquer código de sensor;
- extensões `ISeh*`, offline e FMQ como capacidades anunciadas sem equivalência
  completa no backend Camera3 do S20+.

## Próximos contratos que podem ser adaptados

1. Usar FMQ apenas após validar escrita/leitura integral de metadata e a ordem
   de consumo do CameraService; metadata inline continua válida em AIDL.
2. Manter a seleção de importador de buffers por compatibilidade, mas preservar
   o `private_handle_t` Mali do S20+ e sua liberação original.
3. Implementar offline somente se `camera3_device_ops::switch_to_offline`
   estiver realmente disponível no backend Exynos 990 e todos os buffers
   pendentes puderem mudar de proprietário sem duplicação.
