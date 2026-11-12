# Ponte ENN do Exynos 990

Esta ponte atenderá ao nome de ABI `libenn_user_lib.so` esperado por apps
Samsung recentes. Ela ainda é uma sonda, não uma implementação de inferência.

A primeira sonda chamou a API antiga `libenn_sys_user.samsung_slsi.so` e
confirmou que ela não pode ser o backend: o cliente aborta quando o serviço
HIDL `IEnnInterface` não existe. A implementação de produção deve traduzir
as chamadas ENN diretamente para a API C de `libeden_wrapper_sdk.so`, que é
nativa do y2s e alcança o NPU corretamente.

## Limite do driver do S26+

O binário ENN do S947B não é um donor. Em teste isolado no y2s, o carregador
chegou a `libenn_common_utils.so` e recebeu `SIGILL` na instrução `retaa`: o
arquivo exige PAC e BTI AArch64, indisponíveis no Cortex-A77. Além disso, a
pilha S26 abre `/dev/vertex10` e `/dev/vertex11` com VS4L v4/v5; esses nós e
esse contrato não existem no kernel Exynos 990. Use o S26+ somente para
estudar a semântica moderna, nunca como fonte de blobs para a vendor y2s.

## Sonda Eden direta

`build_probe.sh` também produz `eden_probe`. Ele carrega a
`libeden_wrapper_sdk.so` que já existe na vendor e chama `Initialize()` e
`Shutdown()`. No y2s, ambos retornaram zero e o log confirmou a inicialização
dos dois núcleos NPU do Exynos 990. A implementação futura deve adaptar as
requisições ENN para as operações C desse SDK, em vez de depender do serviço
HIDL ENN ausente.

## Conclusão: ponte inviável para o Language Core (11/11)

O APK `com.samsung.android.offline.languagemodel` 3.1.20.27 (3,1 GB) foi
analisado. Ele é o próprio modelo: um LLM local de ~3B parâmetros
(`embed_size` 3072, 34 subcamadas, vocabulário 150080, contexto 8704),
quantizado e dividido em `ip_256_*.nncz`/`stg_8704_*.nncz` + `weights_*.bin`
(~2,9 GB), com LoRAs por recurso (Bixby, resumo, resposta contextual etc.).

Todos os grafos são `NNC3` com seção `NPU_BINARY`, gerados por
`nncontainer-gen -c NPU --schema_version v3 --soc-type Solomon` com
`--multi_ncp`, conversão/quantização em hardware (`hw_cfu`/`hw_icfu`) e
configs `9955_*nncgraph_config.json`: binários do NPU do S5E9955. Os pesos
estão no layout desse NPU. O NPU do S5E9830 (Eden v1.6.23, NCP antigo) não
executa esse código, e não há grafo CPU/GPU/TFLite no pacote para fallback.

A cadeia de carga é `libssneural_vndk.so` -> `libenn_nncgraph.so` +
`libenn_api.so` -> `libenn_public_api_cpp_lib.so` -> `libenn_user_lib.so`
(~75 funções `Enn*`, incluindo pesos externos, sessões e batch). Uma ponte
só trocaria o erro de instalação por falha ao abrir o modelo. O módulo fica
como registro das sondas e não deve ser habilitado.

## ENN 2.2.29 do S24+ (11-12/11)

A ENN do SM-S926B (One UI 9, vendor `erd9945`) não tem `retaa`, LRCPC2, SVE
ou i8mm e carrega no A77 sem patch. Ferramentas usadas na prova:

- `tools/patch_enn_soc.py`: troca a chave `9840` por `990` nas 6 cópias da
  tabela de SoCs da `libenn_common_utils.so` (a ENN extrai os dígitos de
  `ro.hardware`); `EnnInitialize` passa e o driver de GPU sobe.
- `tools/gen_enn_user_shim.py` + `src/enn_user_shim.c`: geram a
  `libenn_user_lib.so` pública que exporta as 102 entradas C da ENN como
  desvios para a original renomeada `libenn_user_s24.so` e implementa
  `EnnExecuteModelWithSessionIdAndFlag` (ausente na 2.2.29). Necessário
  porque o app só resolve símbolos nos DT_NEEDED diretos.
- `tools/patch_pac.py`: troca `retaa`/`retab` por `ret` (usado só na análise
  da ENN 2.4.26 do S26+; dispensado com a do S24+).

No processo do app, a `libdmabufheap.so` precisa ser a do system do G986B
(A13): a do A17 exige `__libcpp_verbose_abort`, ausente na libc++ VNDK v30.

Resultado: o Language Core instala, mas `SSNeuralCore::checkChipset()`
recusa `ro.soc.model=Exynos 990` e todos os modelos Samsung são só
`NPU_BINARY` do chip de origem. Nenhum recurso é habilitado; os de nuvem
(por exemplo a borracha generativa da Galeria) funcionam sem a ENN, com
"Processar dados apenas no dispositivo" desligado. Detalhes em
`INSTRUCTIONS.md`.
