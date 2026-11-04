# Contrato AIDL da câmera: S26+ como referência e S20+ como backend

Data: 01/11/2026

Este documento separa o que foi observado no provider AIDL do S26+ do que pode
ser usado com segurança no S20+ (`y2s`). A referência serve para definir a
fronteira Android; nenhum blob, handle privado SGR, ID de câmera ou calibração
do S26+ é levado para o S20+.

## Referência observada no S26+

O serviço `vendor.samsung.hardware.camera.provider-service_64` é registrado no
VINTF como `ICameraProvider/internal/0` e abre sessões AIDL. O binário contém
os conversores `ConvertToHalStream`, `ConvertToHalStreamBuffer`,
`ConvertToHalCaptureRequest` e os equivalentes de resultado. O fluxo público é:

```text
CameraService -> AIDL Stream/StreamBuffer/Request
              -> conversor do provider
              -> HAL de câmera Samsung
              -> mapper gráfico para importar o native_handle
```

O provider também importa compatibilidade de mapper HIDL. Isso confirma que
AIDL no limite público não exige trocar o formato privado do buffer que o HAL
antigo já entende.

## Mapeamento adotado para o S20+

| Dado AIDL | Conversão no provider do S20+ | Regra de compatibilidade |
| --- | --- | --- |
| ID público da câmera | enumeração do `camera.exynos990.so` | não copia IDs do S26+ |
| ID físico do stream | string vazia para stream lógico; string original para físico | ponteiro C permanece válido até o próximo configure |
| ID do stream | copiado para a cauda Samsung em `+0x68` | layout obtido do wrapper HIDL original do S20+ |
| `useCase` Samsung | opção privada de 32 bits em `reserved[0]` | inversa do adaptador HIDL Samsung, sem truncar valores inválidos |
| `NativeHandle` | duplica FDs, importa primeiro pelo `HandleImporter`/`GraphicBufferMapper` | preserva `private_handle_t` Mali original |
| fallback de importação | ponte Stable-C, depois ION original | não usa o handle SGR do S26+ |
| acquire/release fence | duplica na entrada e transfere/fecha uma única vez | não reutiliza FD já entregue |
| cache de buffer | chave `(streamId, bufferId)` | não reimporta handle quando o framework envia cache |

## Recursos AIDL que não podem ser simulados

O Camera3 do S20+ não possui campos para `sensorPixelModesUsed` em máxima
resolução nem para `multiResolutionInputImage`. A lista vazia e o modo
`DEFAULT` continuam aceitos, pois possuem a mesma semântica pública. Máxima
resolução e entrada multi-resolução retornam erro explícito até existir uma
ponte para o contrato de sensor do S20+. Isso evita configurar o sensor errado
sem aviso.

`streamConfigCounter` é salvo somente depois de `configure_streams()` concluir
com sucesso. Um `signalStreamFlush()` de uma geração anterior é ignorado antes
de chegar ao backend Camera3, como no contrato AIDL.

## Validação local

Execute:

```bash
platform/exynos990/patches/camera_aidl_port/audit_camera_buffers.sh
platform/exynos990/patches/camera_aidl_port/audit_camera_streams.sh
platform/exynos990/patches/camera_aidl_port/build_probe.sh
```

O probe compila a ABI AIDL V4 do Android 17. A validação física ainda exige
uma imagem vendor assinada e testes de preview, foto, vídeo, frontal/traseira,
zoom, ImageReader, RAW e buffers protegidos no aparelho.
