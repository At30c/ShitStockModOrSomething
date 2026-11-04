# Cadeia HIDL Samsung da câmera e adaptação ao AIDL — 02/11/2026

Estudo por desmontagem do wrapper HIDL do S20+ (`vendor.samsung.hardware.camera.device@5.0-impl.so`),
do HAL (`camera.exynos990.so`/`libexynoscamera3.so`), do `cameraserver` Android 17 e dos providers
AIDL do A26 e do S26+. Nenhum blob do A26/S26+ entra no y2s; as interfaces Samsung foram
reconstruídas a partir das bibliotecas NDK que já estão na system do y2s.

## 1. O que o wrapper HIDL realmente faz

| Função HIDL | Evidência | Consequência para o AIDL |
| --- | --- | --- |
| `convertFromHidl(SehStream, Camera3Stream*)` (`0x32ae8`) | copia tipo/tamanho/formato, `usage` 64 bits em `+16`, dataspace `+40`, rotação `+44`, **zera `priv` (`+32`) e `physical_camera_id`**, grava `SehStream.useCase` cru em `+56`, ID em `+104` | `priv` nunca é fabricado; a opção Samsung vai em `reserved[0]` |
| `sehPreProcessConfigurationLocked` (`0x26a94`) | é o `preProcessConfigurationLocked` AOSP 3.4; `mStreamMap` é `std::map<int, Camera3Stream>` em `session+112`; o nó tem `0x98` bytes (chave em `+0x20`, `Camera3Stream` em `+0x28`); acrescenta só opção, crop zerado (`WriteStreamCropInfo`, `+60..+72`) e `operation_mode` | não existe pré-processamento de "streams extras"; **todos** os streams vão ao HAL. O "objeto de 0x98 bytes" usado como `priv` sintético era o nó da `std::map` (removido) |
| `sehProcessOneCaptureRequest` (`0x2876c`) | chama `ops+32` e libera os arrays locais do request; só `mInflightBuffers` e os handles por `bufferId` persistem | requests concluídos podem ser liberados; o provider mantém só uma janela de 32 como margem |
| `sehImportRequestImpl` | importa todo handle antes do HAL | não entregar handle cru (`preserve_private_handle=1` derrubava o vídeo em `m_sendYuvStreamResult`) |
| `sehSetParameters(hidl_string)` (`0x26118`) | chama `device->ops->reserved[0](device, str)` (`ops+0x50`) = `HAL3_camera_device_set_parameters` | **elo que faltava no AIDL** (seção 2) |
| `SehCameraDevice` | `atoi(publicId)` em `getCameraInfo()` e `open()` | IDs públicos (20, 50…) vão ao HAL sem remapeamento (seção 3) |

## 2. Parâmetros Samsung (`samsungcamera=true;shootingmode=…;sw-vdis=…`)

O HAL só honra as opções de stream, os modos de captura e o SW VDIS depois de
`ExynosCamera::setParameters()`. Em `m_enumExtraStreamInfo` a opção (`stream+56`) só é lida se
`getSamsungCamera() || getSamsungSDK()`; sem isso o log mostrava `option(0)` e o limite de três YUV
abortava a sessão.

No Android 17, `AidlCamera3Device` (cameraserver) obtém a interface por
`AIBinder_getExtension(session) → ISehCameraDeviceSession::fromBinder()` e registrava
`setParameters: Samsung interface is null.`. O provider também é consultado por
`ISehCameraProvider` (log `SEH CameraProvider extension acquired.`). A26 e S26+ usam exatamente esse
contrato (`CameraDeviceSession::SetParameters`).

Interfaces reconstruídas (`aidl/vendor/samsung/hardware/camera/{device,provider}`):

* `ISehCameraDeviceSession` V1, hash `c1d37123fc01e3f288f0f11a72330f9a95de01e9`:
  `void setParameters(in String)` (transação 1);
* `ISehCameraProvider` V1, hash `1b4ed917ff8b23cc778ada14e0ade631029d8469`:
  `String[] getCameraIdListAll()` (transação 1).

A extension é anexada em `createBinder()`: `SharedRefBase::asBinder()` guarda o `AIBinder` só por
referência fraca, então um `AIBinder_setExtension(x->asBinder().get(), …)` avulso se perde quando o
binder é recriado na serialização.

## 3. Câmera lógica 20

`getCameraIdInfo(20)` descreve vários sensores e `isLogicalCam(20)` é verdadeiro. Com o ID público
nativo (`vendor.camera.aidl.native_logical_ids=1`) o HAL registra
`Multi cameara mode is enabled! m_scenario(3) m_isLogicalCam(1) serviceCameraId(20)`, a metadata
lógica vem do próprio HAL e o app passa a criar os dois RAW_SENSOR (`4032x3024` e `4864x3648`,
físico 52, opção `0x340002`), como na sessão HIDL de 29/10. O caminho anterior (20 → backend 0 com IDs
físicos sintéticos `0,2,50,52`) só é usado quando a propriedade está desligada.

## 4. Validação no aparelho (`G985FXXSNHYB1`)

| Caso | Resultado |
| --- | --- |
| `set_parameters` | chega ao HAL; `getSamsungCamera 1`; opções `0x1`/`0x101` nos streams extras |
| Foto | 8 streams nativos aceitos; JPEG `4032x3024` (3,4 MB) e 12 RAW para Super Night entregues pelo HAL |
| Super Night | o app cai em `libAIQSolution_MPI.camera.samsung.so not found` (system, ver seção 5) |
| Vídeo | `SWVDIS_MODE(1)`; MP4 de 12,4 MB/176 quadros sem queda com `preserve_private_handle=0` |
| 0.5× | HAL troca `masterCamId(0 => 2)` em `OperationMode 3` |
| Gravação dupla | abre as câmeras 1 e 0 ao mesmo tempo; exige uma sessão por câmera (seção 6) |

## 6. Várias sessões simultâneas

O `SehCameraDevice` HIDL abre um `camera3_device_t` por câmera e cada um recebe o próprio
`camera3_callback_ops_t`. O provider AIDL usava um `CameraSession::active_` global, que recusava a
segunda abertura (`Illegal argument to HAL module for camera "0"` na gravação dupla) e roteava todos
os callbacks para uma única sessão. Agora cada sessão entrega ao `initialize()` um wrapper cujo
primeiro membro é o `camera3_callback_ops_t`, e o dono é recuperado pelo ponteiro que o HAL devolve.
Um registro com mutex preserva o descarte de callbacks depois de `close`. Conflitos continuam com o
CameraService (`resource_cost`/`conflicting_devices`) e o HAL, que entra em
`setPIPMode`/`PIP_MODE (1, 1)`.

O Motion Photo, que também derrubava a foto frontal, era um defeito do mapper Stable-C
(`IMPLEMENTATION_DEFINED` alocado como `0x11d`), não do provider. Ver
`INSTRUCTIONS.md`, seção "Motion Photo, foto frontal, Super Night e gravação dupla".

## 5. Pendente fora da vendor

`libAIQSolution_MPI` e `libLocalTM_pcc` faltam na system: o S947B as traz na vendor (dependências
em `/vendor/lib64` e `/vendor/etc/aip/config`), a vendor do S20+ não as tem e a system S947B também
não. A versão do G986B carrega exatamente o fechamento `/system/lib64` que a ROM já possui
(`libMultiFrameProcessing30`, `libSwIsp_wrapper_v1`). `platform/exynos990/patches/camera/customize.sh`
agora as importa do firmware alvo; exige build da system. Validado com overlay temporário de
`/system/lib64`: `makeSuperNight X` com 12 RAW e JPEG 4032x3024, sem entrada em
`public.libraries-camera.samsung.txt`.
