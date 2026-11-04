# Gate de conclusão do provider Camera3 AIDL V4 — Exynos 990

Este documento proíbe a ativação parcial do provider. O objetivo é impedir o
caso mais perigoso: o CameraService seleciona o AIDL porque ele enumera uma
câmera, mas o primeiro preview falha dentro do blob sem resultado ou log útil.

## Cadeia que precisa ficar completa

```text
CameraService
  AIDL provider V4
    AIDL device V4
      AIDL session V4 + callbacks
        adaptador Camera3
          camera.exynos990.so / libexynoscamera3.so
            mapper Stable-C + fachada ABI do mapper legado
              FIMC-IS / ION / kernel
```

O provider HIDL Samsung não pode ser chamado pelo adaptador. Ele permanece
instalado somente até esta cadeia ser validada e removido apenas quando o AIDL
substituir integralmente suas funções públicas.

## Contratos obrigatórios

| Camada | Implementação exigida | Critério de aceitação |
|---|---|---|
| Módulo | `hw_get_module(CAMERA_HARDWARE_MODULE_ID)`, callbacks, IDs, metadata, vendor tags, torch e estado do aparelho | IDs e características vêm do `camera.exynos990.so`, sem lista fixa criada pelo port |
| Device | características física/lógica, custo, templates, validação de streams e `open` exclusivo | toda chamada do AIDL V4 possui caminho Camera3 ou retorno documentado pela capacidade original |
| Session | `configureStreams`/V2, request settings, requests, caches, `flush`, fechamento e offline | stream preview, JPEG, vídeo, ZSL, RAW e ImageReader não perdem handle ou fence |
| Buffers | `native_handle_t`, import/release, acquire/release fences, `bufferId` e cache | um buffer é importado, devolvido e liberado exatamente uma vez |
| Callbacks | shutter, erro, metadata parcial/final e buffers de resultado | ordem de frame e quantidade de metadata coincidem com `camera3_callback_ops_t` |
| FMQ | filas de metadata de request e resultado, com fallback inline correto | nenhuma metadata é truncada nem lida duas vezes |
| Encerramento | `flush`, `close`, desconexão e morte do cliente | não resta request pendente, fd aberto ou callback após fechar |

## Regra de ativação

`EXYNOS990_CAMERA_AIDL=1` é o modo de validação isolada. Ele expõe
exclusivamente o provider AIDL no manifest da imagem construída e conserva o
provider HIDL nos arquivos de origem para rollback. O serviço só pode avançar
para ativação permanente após auditoria de fonte e testes no aparelho cobrirem
a tabela inteira. Não será publicado um provider que enumere IDs sem abrir
sessão Camera3.

Enquanto não forem medidos no aparelho, reprocessamento, câmeras físicas e
sessões offline devem responder `EX_UNSUPPORTED_OPERATION`. Esses recursos não
podem ser habilitados por strings presentes no blob: a decisão depende das
tags de metadata estática e dos ponteiros Camera3 que o HAL realmente anuncia.
