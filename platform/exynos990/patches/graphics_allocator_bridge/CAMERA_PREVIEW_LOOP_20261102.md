# Diagnóstico do loop do preview no y2s — 02/11/2026

## Resultado

O loop visível no preview da Samsung Camera não nasce no sensor, no Camera3
proprietário nem no transporte de resultados do provider AIDL. Ele ocorre na
ponte Composer3 usada para apresentar o stream privado da câmera.

O caminho quebrado usa somente o stream `PRIVATE`/`IMPLEMENTATION_DEFINED`:

- stream AIDL `6` no registro de transição;
- formato público `0x22`, convertido pelo HAL Exynos para o formato privado
  `0x11d`;
- treze buffers registrados, com IDs `13` a `25`;
- aproximadamente 30 requests e 30 resultados de buffer por segundo.

Quando o preview volta a funcionar, a Samsung Camera troca
`mainPreview=1` por `mainPreviewCb=1`. Os requests deixam o stream privado `6`
e passam a usar o stream YUV `12`. O sensor e o backend continuam os mesmos;
somente a rota de apresentação muda.

## Por que a imagem forma um vídeo curto em loop

No contrato Composer3, um `Buffer` carrega o `native_handle` ao registrar ou
substituir um slot. Quando o mesmo slot é reutilizado em frames posteriores, o
framework pode enviar somente o número do slot e uma nova acquire fence.

A biblioteca instalada no aparelho é a revisão antiga:

```text
10ebbb83e93a29cdefac080393c48be6cd11b7637f21bef35b6432d3934d3a5a
/vendor/lib64/libexynos990_composer3_contract.so
```

Essa revisão converte o `0x11d` para RGBA quando recebe o handle, mas conserva
o RGBA anterior quando o frame seguinte reutiliza o slot sem reenviar o
handle. Como o BufferQueue da sessão observada alterna treze slots, o HWC
apresenta novamente as treze conversões antigas. O resultado visual é
exatamente um trecho curto repetido.

Uma notificação, o gesto de voltar ou o modo popup podem mascarar a falha
porque a Samsung Camera recria o `SurfaceView` ou muda para
`mainPreviewCb`, que usa YUV e não atravessa essa cache privada da mesma forma.

## Evidências que foram descartadas como causa principal

`Failed to get Internal Bayer Buffer` e `Invalid bayer buffer index` aparecem
a cada cinco frames também nos registros HIDL e no modo popup funcional.
Esses eventos fazem parte do agendamento interno do HAL Samsung e não explicam
sozinhos o loop.

O provider AIDL continua entregando buffers do stream privado em cadência
normal durante o sintoma. Portanto, limitar `pendingNativeFrames_`, reduzir
`maxBuffers` ou mudar o momento em que o provider libera um request pode
alterar estabilidade e latência, mas não atualiza o conteúdo RGBA que o
Composer3 antigo mantém por slot.

## Por que os últimos patches não chegaram ao teste

A imagem manual instalada em 02/11 alterou somente:

```text
vendor/bin/hw/android.hardware.camera.provider-V4-service.exynos990
```

O registro dessa instalação está em
`out/target/y2s/repack-camera-aidl-dd-20261101/INSTALL_RECORD.md`. A árvore
reempacotada preservou a biblioteca Composer3 de hash `10eb...a5a`.

O prebuilt mais novo já contém a atualização do slot sem handle:

```text
78c00483060afab982f09149588ce3640970170f1a8fe3050c520e133f8e01b5
prebuilts/exynos990/composer3_hwc2_bridge/vendor/lib64/
libexynos990_composer3_contract.so
```

Em `handleForBuffer()`, essa revisão procura o handle privado retido para o
slot e chama novamente `convertCameraSource()` com a acquire fence nova. Ela
também conserva o RGBA anterior somente enquanto a fence atual ainda não
sinalizou e controla a reutilização dos buffers de saída pelas release fences.

## Validação estática

A biblioteca antiga e a nova possuem:

- o mesmo `SONAME`, `libexynos990_composer3_contract.so`;
- a mesma lista de dependências ELF;
- os mesmos símbolos públicos exportados;
- ABI Composer3 V5 e backend `libexynos990_graphics_compat.so` iguais.

A auditoria do módulo reconheceu o novo ELF como ARM64 e confirmou a fábrica
Binder, os callbacks HWC2 e o transporte de acquire/present/release fences.

## Próxima validação

O teste seguinte deve substituir somente
`vendor/lib64/libexynos990_composer3_contract.so` pela revisão `78c...01b5`,
reempacotar a mesma vendor EROFS preservando `fs_config`, contextos SELinux,
UUID, geometria e footer AVB, e então confirmar:

1. preview `mainPreview` contínuo sem abrir popup;
2. reutilização dos treze slots sem repetição do conteúdo;
3. ausência de preview verde ou preto;
4. captura, vídeo, troca de câmera e mudança de resolução;
5. fences de release sem crescimento contínuo do pool RGBA.

Essa revisão ainda precisa de validação no aparelho. A análise demonstra por
que a imagem atual mantém o loop e qual artefato faltou instalar; ela não deve
ser declarada definitiva antes do teste de runtime.

## Medição aprofundada após a correção do loop (02/11)

A revisão `78c00483060afab982f09149588ce3640970170f1a8fe3050c520e133f8e01b5`
foi instalada e o loop de slots foi corrigido. O preview restante ficou lento,
portanto o diagnóstico passou a medir o processo real, não apenas inferir a
partir do código.

Com a Samsung Camera em primeiro plano e o aparelho acordado, `simpleperf`
coletou 10.180 amostras em seis segundos do processo Composer3. `88,82%` das
amostras ficaram nos offsets `0x32ecc`, `0x32ed0` e `0x32ef0` de
`libexynos990_composer3_contract.so`. A desmontagem identifica esses offsets
como o laço NEON que converte NV21 para RGBA. A carga medida foi de uma metade
de um núcleo (`3.000 ms` de `task-clock` em seis segundos); não é um bloqueio
do provider da câmera.

Foi criado o probe reproduzível
`src/libyuv_runtime_probe.cpp`. Ele é executado em
`/data/local/tests/vendor`, que usa o namespace de linker vendor, com um NV21
1440x1080 de VU/CrCb idêntico ao layout `0x11d` observado. Resultados no y2s:

| rota | tempo por frame | resultado |
| --- | ---: | --- |
| NEON atual | 1,694 ms | referência |
| NEON seguro proposto | 1,415 ms | mesmos bytes RGBA, 16,5% mais rápido |
| `libyuv::NV21ToABGR` | 2,344 ms | canais RGBA corretos, mais lento |

O probe também revelou que o laço atual chama `vld2_u8()` e lê 16 bytes de
croma para oito pixels, embora somente oito bytes (quatro pares VU) sejam
necessários. Na última linha da imagem isso avança oito bytes além do buffer;
sem uma cauda de guarda o teste termina em `SEGV_ACCERR`. A variante segura
usa `vld1_u8()` seguido de desentrelaçamento NEON, preserva exatamente o hash
RGBA da rota atual e elimina essa leitura fora dos limites.

`dlopen("/system/lib64/libyuv.so")` é corretamente bloqueado para um processo
vendor, enquanto `dlopen("libyuv.so")` funciona pelo namespace. Ainda assim,
o benchmark mostra que importar libyuv não é uma otimização para este SoC. A
próxima alteração de produção deve ser apenas a troca do carregamento NEON
inseguro pelo seguro e uma medição de preview real; ela não deve introduzir
libyuv como dependência.
