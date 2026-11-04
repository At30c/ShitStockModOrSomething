# Mapa de implementação AIDL V4 → Camera3 do Exynos 990

Este mapa foi feito a partir da API AIDL V4 congelada do Android 17,
`hardware/camera3.h` Android 17 e dos binários reais do y2s. Ele orienta a
implementação e os testes; não há conversão baseada em suposição ou no blob do
S26+.

| Interface AIDL | Operação Camera3 de destino | Falha que deve ser impedida |
|---|---|---|
| `ICameraProvider.getCameraIdList` | `get_number_of_cameras` + `get_camera_info` | anunciar um ID inexistente ou externo como interno |
| `getCameraDeviceInterface` | tabela `camera_module_t` e `get_camera_info` | construir device sem metadata estática válida |
| estado/torch | `set_camera_device_state`, `set_torch_mode` | alterar torch em device aberto sem o retorno do módulo |
| `ICameraDevice.open` | `common.methods->open`, `camera3_device_ops.initialize` | abrir duas sessões ou iniciar sem callbacks Camera3 |
| características | `camera_info.static_camera_characteristics` | copiar metadata sem manter seu tamanho e ownership |
| templates | `construct_default_request_settings` | manter ponteiro do HAL depois de fechar a sessão |
| validar streams | `is_stream_combination_supported` quando existir; senão `configure_streams` somente na sessão | aceitar stream que o HAL recusaria |
| `configureStreams`/V2 | `camera3_device_ops.configure_streams` | entregar `camera3_stream_t` temporário depois do retorno |
| `processCaptureRequest` | `camera3_device_ops.process_capture_request` | fechar acquire fence duas vezes, perder `bufferId` ou reutilizar handle sem cache |
| `processCaptureResult` | `camera3_callback_ops.process_capture_result` | devolver buffer antes da release fence ou misturar frames |
| `requestStreamBuffers` | `camera3_callback_ops.request_stream_buffers` | entregar handle temporário ou exceder a reserva feita pelo HAL |
| `returnStreamBuffers` | `camera3_callback_ops.return_stream_buffers` | perder buffer gerenciado pelo HAL ou duplicar a release fence |
| `notify` | `camera3_callback_ops.notify` | inverter shutter/erro ou emitir callback depois de `close` |
| `flush` | `camera3_device_ops.flush` | fechar enquanto existem requests pendentes |
| `close` | `common.close` depois de `flush` | permitir callback do HAL após liberar a sessão |
| `switchToOffline` | `switch_to_offline` apenas se o ponteiro existir | anunciar offline em HAL que não o suporta |

## Invariantes que o teste deve provar

1. Cada `native_handle_t` recebido por request tem um proprietário e é liberado
   uma única vez após seu resultado final.
2. Uma acquire fence é transferida ao HAL uma única vez; uma release fence é
   transferida ao callback uma única vez.
3. `frame_number` cresce na entrada e todos os resultados desse frame são
   entregues antes de seu encerramento ou erro terminal.
4. A metadata AIDL é cópia exata do bloco `camera_metadata_t`; FMQ é usada
   apenas quando seu tamanho e consumo forem validados.
5. `close` bloqueia novos requests antes de fechar o `camera3_device_t`.

## Ordem de implementação

1. wrapper de módulo Camera3 e metadata estática;
2. `ICameraDevice` e abertura exclusiva;
3. `ICameraDeviceSession.configureStreams` e templates;
4. abertura de sessão, requests inline, resultado e cache de buffers sem FMQ; **concluído no código**;
5. reprocessamento e streams físicos; FMQ usa fallback inline nesta fase;
6. flush, close, offline e erros terminais;
7. ativação experimental e auditoria no aparelho.

## Implementação atual de requests

`Camera3Buffers` reconstrói o `native_handle_t` a partir do `NativeHandle`
AIDL com `dup()` para cada FD. O registro persiste por `(streamId, bufferId)`
e possui a flag `inFlight`. Assim, o `BufferCache` não remove um handle ainda
em posse do HAL e o resultado Camera3 reconduz o mesmo `bufferId` ao callback
AIDL. A acquire fence é duplicada antes da entrega ao HAL; a release fence
retornada pelo HAL é transferida uma única vez ao `ScopedFileDescriptor` do
resultado Binder.

Nesta etapa, a sessão aceita somente requests inline sem FMQ, sem
reprocessamento e sem configurações físicas. Esses casos retornam erro de
argumento em vez de seguir por um caminho incompleto. `notify` está
implementado, e as filas FMQ retornam um descritor vazio válido para que o
framework use metadata inline pelo Binder. O provider é opt-in por
`EXYNOS990_CAMERA_AIDL=1` até a validação em aparelho encerrar os contratos
pendentes.

Os callbacks `processCaptureResult` e `notify` já convertem resultados,
release fences, shutter e os quatro erros Camera3. `signalStreamFlush` também
traduz a lista AIDL de IDs para os endereços persistentes de `camera3_stream_t`.
O buffer manager Camera3 3.6 é ligado aos métodos AIDL
`requestStreamBuffers` e `returnStreamBuffers` somente quando o backend
anuncia essa versão, preservando o mesmo registro de `bufferId` e FDs. Em
Camera3 3.5 os ponteiros permanecem nulos, como a ABI exige. As filas FMQ retornam descritor vazio com sucesso, que é
o fallback AIDL para metadata inline e permite abrir a sessão sem truncá-la.
Reprocessamento, offline, câmeras físicas e a comprovação de encerramento com
requests pendentes continuam como bloqueios para promoção permanente.

## Parametrização `Stream` conforme Android 17

O bridge agora valida os campos da `Stream.aidl` congelada na versão 4 antes
de construir a estrutura privada consumida pelo Camera3 da Samsung. A fonte de
referência é `hardware/interfaces/camera/device/aidl/.../Stream.aidl` do AOSP
Android 17; a conversão equivalente no framework está em
`frameworks/av/services/camera/libcameraservice/device3/aidl/AidlCamera3Device.cpp`.

Os seguintes invariantes são aplicados: `id` não pode ser negativo nem repetido;
streams de entrada usam `usage=0` e não têm `physicalCameraId`; dimensões e
`bufferSize` são válidos; `groupId` mantém formato, dataspace, usage e
`concurrentGroup` iguais dentro do grupo; modos de pixel não se repetem e só
aceitam os valores públicos; e `useCase`/`dynamicRangeProfile` são validados
como enums AIDL de 64 bits, sem truncamento silencioso.

O Camera3 público continua sendo uma ABI C sem campos nomeados para
`groupId`, `sensorPixelModesUsed`, `dynamicRangeProfile`, `useCase` e
`colorSpace`. O adapter Samsung não tem como transportar faixa dinâmica não
padrão, então esse caso continua retornando `ILLEGAL_ARGUMENT`. Já os casos de
uso AIDL de vendor observados no framework (`0x10000`, `0x20000`, `0x2020000`
e `0x40000`) são aceitos e registrados. O bridge mantém o valor AIDL no
contrato público, mas deixa `reserved[0]` nulo no caminho AIDL direto. Esse
campo pertence à extensão privada `SehStream` do wrapper HIDL; preenchê-lo
antes do pré-processamento Samsung faz `libexynoscamera3.so` enumerar streams
extras novamente e abortar no limite físico de YUV. A transformação
`option = useCase >> 16` continua documentada e validada para auditoria, mas só
deve ser aplicada pelo wrapper HIDL que executa `sehPreProcessConfigurationLocked`.

O único campo privado preservado é o `mId` da implementação Samsung em
`+0x68`, confirmado no `convertFromHidl` do adaptador original. O campo não
altera o contrato AIDL. A configuração também registra todos os parâmetros
recebidos para que uma divergência entre framework, bridge e HAL possa ser
auditada sem depender de suposição.

Essa parametrização corrige a fronteira AIDL/Camera3, mas não reproduz ainda o
pré-processamento privado `sehPreProcessConfigurationLocked` do wrapper HIDL
Samsung. O teste atual confirma que o crash remanescente ocorre dentro de
`libexynoscamera3.so::m_enumExtraStreamInfo` ao criar streams extras; ele não é
um erro de serialização AIDL. A próxima etapa é portar esse pré-processamento
para o adapter AIDL ou delegar a configuração ao wrapper compatível, mantendo
as regras públicas acima.

### Validação do mapeamento de `useCase` (30/10/2026)

Com o provider arm64 executado em `hal_camera_default`, a Camera Samsung enviou
os casos `0x10000`, `0x20000`, `0x2020000` e `0x40000`. O log do HAL recebeu,
respectivamente, as opções `0x1`, `0x2`, `0x202` e `0x4` em
`m_setStreamInfo`, confirmando a transformação `option = useCase >> 16`.
Depois disso, o HAL avançou até `m_enumExtraStreamInfo` e abortou porque quatro
streams YUV excederam o limite físico três. O provider foi então ajustado para
manter `reserved[0] = nullptr` no caminho AIDL; a aplicação continua recebendo
e registrando `useCase`, enquanto o HAL deixa de interpretar a opção HIDL duas
vezes. O próximo teste deve confirmar se o objeto privado de 0x98 bytes e a
configuração direta eliminam o abort e o crash de `configureStreams`.

### Compatibilidade do objeto privado `Camera3Stream` (30/10/2026)

A auditoria do símbolo Samsung `convertFromHidl(SehStream, Camera3Stream*)`
mostrou que o wrapper HIDL não passa um bloco de apenas `sizeof(camera3_stream_t)`:
ele aloca e zera um objeto de `0x98` bytes, grava o ID em `+0x68`, a opção
privada em `reserved[0]` (`+0x38`) e mantém a cauda privada zerada para crop,
estado e campos de configuração. O adaptador AIDL usa agora a mesma extensão
zerada de `0x98` bytes. Os campos públicos continuam sendo preenchidos somente
com os valores definidos por `Stream.aidl`; a extensão serve apenas para
preservar a ABI que `libexynoscamera3.so` lê durante `configure_streams`.

### Correção (02/11/2026)

A desmontagem de `sehPreProcessConfigurationLocked` mostrou que o bloco de `0x98` bytes é o nó da
`std::map<int, Camera3Stream>` do wrapper (chave em `+0x20`, `Camera3Stream` em `+0x28`), e não um
dono privado de stream. O wrapper zera `priv` e entrega **todos** os streams ao HAL; não há
pré-processamento de streams extras. O abort de "quatro YUV" vinha da falta de
`HAL3_camera_device_set_parameters` (o HAL ignora a opção sem `samsungcamera=true`). Ver
`HIDL_SEH_CHAIN_STUDY_20261102.md`.
