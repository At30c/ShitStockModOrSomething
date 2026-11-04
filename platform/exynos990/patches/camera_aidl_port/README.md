# Port do provider Camera3 AIDL para Exynos 990

O objetivo é substituir o transporte HIDL da câmera por um provider AIDL V4
do Android 17, sem copiar blobs do S26+. O backend físico permanece sendo o
`camera.exynos990.so` e o `libexynoscamera3.so` originais do S20+; eles são os
únicos que conhecem FIMC-IS, sensores, ION, layouts Mali e as tags Samsung.

## Contrato escolhido

```text
CameraService
  -> android.hardware.camera.provider.ICameraProvider/internal/0 (AIDL V4)
  -> ICameraDevice / ICameraDeviceSession (AIDL V4)
  -> adaptador Camera3 nativo
  -> camera.exynos990.so + libexynoscamera3.so
  -> libGrallocMapperCamera.so + gralloc.exynos990.so
  -> FIMC-IS / DMA-BUF / kernel
```

O provider Samsung HIDL não participa desta cadeia quando o port estiver
pronto. As dependências HIDL internas que ainda fazem parte da ABI fechada de
`libexynoscamera3.so` serão isoladas atrás do adaptador; removê-las antes de
um substituto binário compatível quebraria a alocação de buffers da câmera.

## Estado de ativação

O modo padrão (`EXYNOS990_CAMERA_AIDL=0`) preserva o provider HIDL Samsung.
O modo explícito `EXYNOS990_CAMERA_AIDL=1` instala o provider AIDL V4 real,
remove somente o serviço/manifest HIDL da câmera e deve ser usado primeiro em
validação isolada. Não anuncia uma lista artificial: ele enumera o módulo
`camera.exynos990.so` e abre o `camera3_device_t` correspondente.

O caminho já implementado cobre enumeração, metadata e vendor tags, abertura
Camera3, streams persistentes, requests e resultados inline, cache de
`bufferId`, fences, buffer manager Camera3 3.5, flush, close, callbacks,
VINTF, init e contexto SELinux. A ativação permanente exige validar no
aparelho estas operações juntas:

1. enumeração, características, tags Samsung, torch e estado do aparelho;
2. abertura Camera3 e conversão de `StreamConfiguration` para
   `camera3_stream_configuration_t`;
3. conversão bidirecional de requests/resultados, inclusive metadata parcial;
4. ownership exato de `native_handle_t`, acquire/release fences e caches;
5. `flush` e encerramento sem buffer perdido;
6. preview, foto, vídeo, troca frontal/traseira, ZSL, RAW, ImageReader e
   buffers protegidos;
7. VINTF, init e SELinux para o serviço AIDL, seguido da remoção do provider
   HIDL somente depois da equivalência comprovada.

FMQ usa deliberadamente o fallback AIDL de metadata inline: a sessão devolve
um descritor vazio com sucesso e o CameraService envia metadata pelo Binder.
Os IDs físicos recebidos no request e nos resultados são encaminhados ao
Camera3 quando pertencem à metadata original do S20+. Reprocessamento e
sessões offline permanecem recusados de forma explícita, pois ainda dependem
de ownership adicional que precisa ser coletado do HAL em execução. Isso
impede que uma capacidade incompleta seja anunciada como funcional.

## Latência de abertura

O provider não registra mais cada aquisição, devolução e comparação de
buffer no caminho de preview. A Samsung Camera abre vários pools de buffers
e esse rastreio produzia centenas de linhas por segundo no `logcat`,
competindo com os primeiros requests Camera3 e deixando a interface lenta.
Falhas de importação, fences e handles que não estejam em voo continuam
registradas; os eventos normais da sessão ficam limitados às primeiras
amostras e a uma amostra periódica.

## ABI alvo

O sistema y2s fornece `camera.provider-V4-ndk`, `camera.device-V4-ndk`,
`camera.metadata-V3-ndk`, `camera.common-V1-ndk`, `common-V2-ndk`,
`common.fmq-V1-ndk` e `graphics.common-V7-ndk`. Portanto o código será
gerado contra AIDL V4. A referência do S26+ é usada apenas para estudar a
lógica do provider moderno; a interface V3 dele não será introduzida no y2s.

Execute `audit_camera_aidl_contract.sh <work_dir>` antes de cada avanço. Ele
verifica que o backend é o Camera3 nativo e que a ABI do sistema corresponde
ao contrato acima.

O mapeamento verificável de cada método AIDL V4 para a operação Camera3
nativa está em `AIDL_CAMERA3_CONTRACT_MAP.md`. Ele define ownership de
handles/fences, ordem de callbacks e as condições que bloqueiam ativação do
provider; use-o como checklist dos testes antes de habilitar o módulo.

`audit_camera_buffers.sh` verifica a posse dos handles/fences; ele deve passar
junto de `audit_camera_session.sh` antes de gerar o probe.
`audit_camera_streams.sh` também valida a geração de configuração e impede que
recursos AIDL sem equivalente no Camera3 original sejam reduzidos silenciosamente.

`src/camera3_module.{h,cpp}` abre o módulo físico `camera.exynos990.so` por
`camera_module_t`, sem chamar o provider Samsung HIDL, e expõe enumeração,
metadata estática, estado, torch, abertura e fechamento Camera3.
`audit_camera3_module.sh` impede regressões para o provider HIDL ou para uma
versão Camera3 inferior a 3.2.

`build_probe.sh` gera e liga o serviço contra as definições congeladas AIDL V4
do Android 17 e contra as bibliotecas extraídas da system y2s. Ao terminar,
copie o ELF produzido para `prebuilts/exynos990/camera_aidl_port/vendor/bin/hw/` para atualizar o artefato
que `customize.sh` instala durante a validação.

## Extensões Samsung (02/11/2026)

A sessão anexa `vendor.samsung.hardware.camera.device.ISehCameraDeviceSession` e o provider
`vendor.samsung.hardware.camera.provider.ISehCameraProvider` como extensions Binder; o cameraserver
Android 17 os resolve por `AIBinder_getExtension()`. `setParameters` chama `camera3_device_ops::reserved[0]`
(`HAL3_camera_device_set_parameters`), como o `sehSetParameters` do HIDL. Com
`vendor.camera.aidl.native_logical_ids=1` os IDs públicos (20, 50…) são usados em `get_camera_info()`
e `open()`. Detalhes em `HIDL_SEH_CHAIN_STUDY_20261102.md`.
