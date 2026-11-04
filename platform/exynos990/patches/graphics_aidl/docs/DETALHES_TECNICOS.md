# Detalhes técnicos da cadeia gráfica AIDL

Conteúdo técnico que antes ficava no README do módulo. Os links são relativos a
`docs/`.

## Decodificação consolidada (25/10/2026)

O inventário mais recente e com níveis explícitos de evidência está em
[`DECODIFICACAO_CONTRATOS_GRAFICOS_20261025.md`](DECODIFICACAO_CONTRATOS_GRAFICOS_20261025.md).
Ele cobre Gralloc1/Mali, `private_handle_t`, formatos/modifiers, locks/fences,
mapper/allocator, clientes HIDL, HWC2/Composer, VINTF/SELinux e a comparação
estrutural com SGR do S26+. Quando um registro histórico divergir, não assuma
semântica para o formato privado `0x11d`: siga a evidência e as hashes daquele
documento.

Para repetir a leitura estática sem modificar uma imagem:

```sh
platform/exynos990/patches/graphics_aidl/decode_graphics_contracts.sh --brief
```

Este módulo mantém o `gralloc.exynos990.so` e o layout do handle nativo dele.
Sobre ele, monta uma fachada de allocator AIDL v2 e uma de IMapper Stable-C v5
para o framework novo. No y2s, o allocator AIDL é registrado globalmente por
padrão, então os clientes `GraphicBufferAllocator`/`GraphicBufferMapper` do
framework saem do caminho HIDL. O allocator HIDL original fica só como ponto de
compatibilidade para HALs proprietários do vendor cuja ABI ainda não é AIDL
(hoje, o HAL de câmera Exynos). O mapper Stable-C traduz o layout do handle YUV
privado da Exynos para o metadata `PLANE_LAYOUTS` lido pelo framework; o
`GraphicBufferMapper` do Android monta a partir dele a visão `android_ycbcr`.

O mapper v5 segue o contrato de posse do Gralloc1: o import clona e retém o
handle, e o release solta a referência do driver antes de fechar o clone,
quando necessário. O allocator AIDL consulta o gralloc original em
`isSupported()` e recusa bits de uso que ele não consegue representar. Um teste
de 100 ciclos de allocator/mapper terminou sem tela preta, crash do mapper ou
erro de posse; o contrato recuperado do driver está documentado em
[`docs/DRIVER_RE.md`](DRIVER_RE.md).

Para compilar os dois artefatos arm64 sem compilar a ROM:

```sh
platform/exynos990/patches/graphics_aidl/build.sh
```

O script confere a arquitetura do ELF, os exports obrigatórios e as
dependências de runtime não resolvidas. O resultado vai para
`prebuilts/exynos990/graphics_aidl/vendor/`, na raiz do repositório.

A imagem com o allocator global registra o `.rc` e a VINTF dele, e pode ser
testada com `monitor_test.sh [iterações]`. O teste varia as dimensões dos
buffers e exercita alocação, import, lock, unlock e liberação. Mantenha o
allocator HIDL ativo até o adaptador da câmera remover a dependência HIDL
direta; o allocator do framework deixa de usá-lo assim que a instância AIDL
fica visível.

O serviço do allocator é registrado na imagem do alvo. Os clientes do framework
do Android 17 resolvem `IAllocator/default` e o sufixo Stable-C, e
`EXYNOS990_AIDL_GRAPHICS=0` continua sendo o modo explícito de rollback. Não
use `EXYNOS990_DISABLE_HIDL_ALLOCATOR=1` antes de o adaptador da câmera estar
instalado: o `camera.exynos990.so` ainda é linkado contra a ABI HIDL de
allocator/mapper. Registrar o AIDL junto com o mapper Stable-C faz o
`GraphicBufferMapper` escolher o mapper de compatibilidade no processo inteiro.
O lock YUV obtém o ponteiro base do Y pelo resultado `LOCK_FLEX` do driver
nativo e o devolve pelo contrato `void**` do Stable-C. Offsets dos planos,
stride de croma e pixel stride vão separados em `PLANE_LAYOUTS`; escrever uma
struct `android_ycbcr` em `void**` corromperia a pilha de quem chamou. O
contrato Composer3 também abre o `mapper.exynos990_compat.so` diretamente.

Antes de tentar remover o HIDL de vez, rode
`audit_hidl_retirement.sh [work_dir]`. Ele distingue uma chamada HIDL
`getService()` real, ainda não resolvida, de uma dependência `DT_NEEDED` só de
tipo. O build recusa `EXYNOS990_DISABLE_HIDL_ALLOCATOR=1` enquanto houver um
chamador direto, para que uma remoção parcial não deixe a câmera ou o
framework sem provedor. O resultado atual do y2s está em
[`docs/HIDL_AIDL_DRIVER_AUDIT_20261024.md`](HIDL_AIDL_DRIVER_AUDIT_20261024.md)
e no log de auditoria datado em `out/target/y2s/`.

O mapper usa o `libc++.so` da plataforma; a ponte não substitui nem acrescenta
um runtime C++ para a vendor inteira.

O mapper e o allocator compartilham
`prebuilts/exynos990/graphics_aidl/vendor/lib64/libexynos990_graphics_compat.so`.
Essa biblioteca guarda-chuva é dona da tabela de callbacks do Gralloc1 e abre o
`gralloc.exynos990.so` original por `hw_get_module`; ela não contém blobs do
S26+ nem implementações substitutas de `libc`, Binder ou `libhardware`. O
mapper Stable-C continua sendo um ponto de entrada público fino em `lib64/hw/`,
e o allocator continua sendo um serviço init separado, os dois linkados contra
a mesma biblioteca. Ela usa só as bibliotecas normais da plataforma Android; o
allocator precisa também do `libbinder_ndk.so` para o processo Binder dele.

O build também gera
`prebuilts/exynos990/graphics_aidl/test/libGrallocMapperCamera.compat.so`. Ele
mantém o SONAME original `libGrallocMapperCamera.so` e exporta os três símbolos
C++ exatos pedidos pelo `libexynoscamera3.so` (`lock`, `lock` YCbCr e
`unlock`). Os métodos delegam ao mesmo backend Gralloc1 e traduzem os planos
flex para o `YCbCrLayout` HIDL. Ele fica em
`prebuilts/exynos990/graphics_aidl/test/` até preview, captura, vídeo, RAW,
fences e buffers protegidos serem exercitados no aparelho; o módulo de produção
continua instalando o mapper do vendor sem alteração.

A superfície Stable-C está completa para o metadata que pode ser representado
sem mudar o handle nativo de 2020. `flushLockedBuffer` e `rereadLockedBuffer`
validam o estado do lock e emitem a barreira de cache DMA-BUF padrão quando o
kernel a expõe. A lista de metadata padrão inclui todos os getters
obrigatórios, entre eles formato, tamanho de alocação, proteção, layout dos
planos, crop e stride. Dataspace, blend mode e os dois tipos de metadata HDR
estático podem ser definidos e são propagados entre imports que apontam para o
mesmo armazenamento.

O backend legado tem um decodificador conservador de modifiers do y2s e só lê
`private_handle_t + 0x48` depois de validar versão, o handle de 65 campos,
magic e tamanho. Uma palavra alta diferente de zero só é aceita para um valor
low32 comprovadamente linear; o accessor exportado de nome parecido lê `+0x30`
(`frameworkFormat`) e é usado apenas em diagnóstico. Só os bits AFBC low32
conhecidos são mapeados; combinações desconhecidas ou privadas e palavras altas
não lineares devolvem `UNSUPPORTED`, em vez de um palpite. A classe de metadata
do vendor lê `+0x50` como `alloc_format`. Os payloads de HDR dinâmico
2094-40/2094-10 são guardados e devolvidos byte a byte, mas interpretá-los
continua sendo responsabilidade da câmera e do framework do vendor.
Antes de considerar a composição estável, repita o teste em sessões de jogo
mais longas e mantenha a contagem de mapeamentos IOVMM abaixo do limite de
aviso do kernel.

O shim de SONAME da câmera foi testado numa sessão limpa em 24/10/2026:
preview, captura de foto e um vídeo H.264/AAC de 4,4 segundos foram salvos com
sucesso. Ele continua em `prebuilts/exynos990/graphics_aidl/test/`; captura RAW
efetiva, buffers protegidos e modifiers DRM privados ainda não bastam para
promovê-lo, nem o mapper Stable-C, ao caminho global da vendor.

## Auditoria em camadas

O estado de cada contrato pode ser conferido sem alterar a imagem:

```sh
platform/exynos990/patches/graphics_aidl/audit_graphics_stack.sh
```

O relatório fica em [`docs/STACK_AUDIT.md`](STACK_AUDIT.md). O mapper Stable-C 5 é agora o caminho
global selecionado pelo `Gralloc5`, mas continua sobre o Gralloc1 original e
seu handle Mali. O allocator e o mapper HIDL 2.0/2.1 permanecem como
compatibilidade para clientes proprietários, principalmente a câmera. O
Composer físico continua HIDL 2.3/HWC2 por baixo da ponte AIDL; ela só deve ser
promovida depois de cobrir comandos, fences, hotplug, modos e
`validate/present` em teste longo.

O nome Stable-C também precisa ser rotulado no
`vendor_service_contexts`:

```text
mapper/exynos990_compat u:object_r:hal_graphics_mapper_service:s0
```

Sem esse contexto, o servicemanager devolve `default_android_service`, nega o
`find` do SurfaceFlinger e faz o `Gralloc5` retornar ao caminho HIDL.

A comparação ampliada dos drivers antigos com o S26+ está em
[`docs/DRIVER_CONTRACT_AUDIT_20261024.md`](DRIVER_CONTRACT_AUDIT_20261024.md). Ela registra dependências ELF, símbolos de
posse e lock, formatos YUV/AFBC, metadata SGR, VINTF, init e SELinux. O S26+
é referência de contrato; seus binários não são compatíveis com o handle
Mali/Gralloc1 do y2s.

A separação específica da câmera está em
[`docs/CAMERA_DRIVER_SPLIT.md`](CAMERA_DRIVER_SPLIT.md). Para verificar que a fachada HIDL, o backend
Gralloc1 do S20+ e o adaptador AIDL continuam independentes, execute:

```sh
platform/exynos990/patches/graphics_aidl/audit_camera_driver_split.sh
```

Essa auditoria rejeita referências de runtime ao mapper SGR ou ao HAL de
câmera do S26+ dentro do código do y2s. O donor é consultado apenas como
referência de lógica para metadata, planes e fences.

A proposta de consolidar o bridge em uma biblioteca compartilhada nativa está
em [`docs/UMBRELLA_SHIM_ANALYSIS_20261024.md`](UMBRELLA_SHIM_ANALYSIS_20261024.md). Ela pode reunir mapper, metadata e os
adaptadores Gralloc1/HWC2 do y2s. Não deve ser usada para mascarar os
SONAMEs ou os handles SGR do S26+.

Como etapa intermediária, a biblioteca HWC2 pode ser compilada sem build da
ROM:

```sh
platform/exynos990/patches/graphics_aidl/build_composer_backend.sh
```

O resultado fica em `prebuilts/exynos990/graphics_aidl/test/`. `libexynos990_hwc2_backend.so` apenas
consulta o `hwcomposer.exynos990.so` original pelo contrato HWC2; o
`hwc2_backend_probe` permite validar display, configuração, resolução, vsync,
DPI e nome. Esses arquivos não são instalados na vendor e não registram um
serviço AIDL.

## Atualização do contrato y2s em 22/10/2026

O bridge agora usa um contrato comum em
`include/exynos990/graphics_contract.h`. A conversão entre `BufferUsage` AIDL
e Gralloc1 separa explicitamente produtor e consumidor. Isso preserva
`CAMERA_OUTPUT` no lado produtor, `CAMERA_INPUT` no lado consumidor e não
confunde `SENSOR_DIRECT_DATA` (bit 23 do produtor) com `GPU_DATA_BUFFER` (bit
23 do consumidor legado).

Os offsets de planos não foram escolhidos a partir do S26+. Eles foram
confirmados por disassembly do `gralloc.exynos990.so` do próprio y2s: o driver
lê o formato de alocação em `private_handle_t + 0x50`, `ystride` em `+0x5c`, croma em
`+0x68/+0x6c` e o segundo plano YV12 em `+0x78`. A ordem Cb/Cr foi conferida
em `mali_gralloc_lock_ycbcr()`. O mapper Stable-C apenas traduz esse contrato;
ele não introduz um handle SGR nem copia o mapper do S26+.

Para NV12/NV21/YV12, o mapper lê do handle nativo o formato, os strides e os
offsets de croma que o Exynos 990 já expõe. Isso evita derivar a geometria da
câmera do callback flexível legado, que neste vendor informa 2x2 para alguns
planos de luma. Para um formato flexível desconhecido, o mapper usa como
fallback o `mali_gralloc_lock_flex_async()` do próprio vendor, copia a
geometria retornada e faz `unlock()` imediatamente; nesse caminho, luma é
normalizada para a largura e altura completas do buffer. Se o driver não puder
descrever o buffer, o bridge devolve `UNSUPPORTED` em vez de fabricar offsets.

`build.sh` recompila os dois artefatos contra as bibliotecas do system do y2s
e o teste `bridge_test.cpp` inclui uma alocação YUV com `CAMERA_OUTPUT`, além
das verificações de importação, metadata, lock flexível, fences e liberação.
Esse teste precisa ser executado no aparelho com a imagem correspondente; a
compilação cruzada sozinha não comprova preview, captura ou câmera frontal.

O objetivo da etapa é aposentar primeiro as interfaces HIDL de allocator e
mapper usadas pelo framework. O backend Mali/Gralloc1 continua como camada de
execução até existir uma implementação fonte equivalente para formatos AFBC,
ION, fences e todos os formatos da câmera. Removê-lo antes dessa equivalência
deixaria o HAL `camera.exynos990.so` sem o contrato que ele chama diretamente.

## Contrato Composer3 AIDL e sessão HWC2

`build_composer_aidl.sh` gera os 90 AIDL do Composer3 V5 e compila
`prebuilts/exynos990/graphics_aidl/test/libexynos990_composer3_contract.so` contra o runtime do y2s. A
implementação de teste consulta o display HWC2 original e encaminha
configuração, nome, resolução, DPI, vsync, orientação, modo de cor, power mode
e habilitação de vsync por uma sessão persistente. O C++ é estático no
artefato, evitando introduzir outra ABI de `libc++` na vendor.

Na fase de validação, o contrato ainda não era um HAL instalável: o serviço
ficava fora da VINTF, e o probe e a biblioteca de teste ficam em
`prebuilts/exynos990/graphics_aidl/test/`.
O backend HWC2 também expõe, somente para a etapa de validação, primitives de
criação/destruição de layers, propriedades de buffer, client target,
`validate`, aceitação de mudanças e `present`. Esses callbacks mantêm os
descritores de fence e não são registrados como serviço; a ponte precisa de
validação no aparelho antes da instalação.

No contrato Binder, `createLayer`, `destroyLayer` e `setActiveConfig` já
encaminham para a sessão HWC2. `registerCallback` registra hotplug, refresh,
vsync, mudança de período e seamless no HWC2 e os entrega ao
`IComposerCallback` AIDL. `executeCommands` converte buffers por slot,
acquire fences, client target, atributos básicos, `validate`, mudanças de
composição, `acceptDisplayChanges`, `present`, o present fence e os release
fences por layer. O caminho
ainda retorna `EX_UNSUPPORTED` para lifecycle CREATE/DESTROY em lote e
atributos avançados que não têm equivalente seguro na interface HWC2
disponível.

A auditoria de contrato agora cobre explicitamente os **50/50 métodos de
`IComposerClient` V5**. Os 33 métodos que não tinham uma implementação HWC2
direta foram adicionados como métodos reais da classe: consultas sem capacidade
retornam lista vazia, identidade ou zero quando isso é permitido pelo contrato,
e operações sem equivalente retornam `EX_UNSUPPORTED` com uma mensagem clara.
Isso fecha a auditoria da interface sem declarar capacidades que o
`hwcomposer.exynos990.so` não oferece. O relatório pode ser reproduzido com
`audit_graphics_stack.sh`.

O serviço instalável está neste mesmo módulo (etapa 2 do `customize.sh`). Ele
registra o serviço AIDL, instala o fragmento VINTF e mantém o Composer HIDL
original para rollback. O serviço é compilado por `build_composer_service.sh`;
a auditoria da pilha também verifica o executável e a biblioteca instaláveis.

## Compatibilidade do formato privado da câmera y2s

O `gralloc.exynos990.so` e o `libGrallocMapperCamera.so` originais do y2s
foram usados como fonte do contrato. O formato privado `0x11d` que o HAL
entrega para o pós-processamento é semiplanar, mas seus planos ficam em
DMA-BUFs separados. O código Android 17 que chama `produceFrameWithYuv420`
escreve como se o retorno de `lock()` fosse um bloco Y seguido de UV contínuo;
devolver diretamente o primeiro DMA-BUF causa uma escrita além do fim do mapa.

O mapper reconhece somente esse valor confirmado no driver original, usa
`LOCK_FLEX` para obter Y/Cb/Cr, fornece um scratch linear temporário ao
chamador e copia as linhas de Y e UV de volta para os planos originais no
`unlock`. A lista de locks aceita chamadas aninhadas do framework e libera o
scratch correspondente em ordem inversa. O driver Mali, o handle nativo e o
`libGrallocMapperCamera.so` não são substituídos.

O S26+ foi consultado apenas para a superfície AIDL e o comportamento de
`mapper.stableC`; nenhum binário ou offset SGR é usado nessa adaptação. No
aparelho identificado por `G985FXXSNHYB1`/`y2s - y2slte`, a imagem AVB de teste foi
instalada pelo TWRP e a câmera permaneceu aberta sem `SIGSEGV`, `SIGBUS`,
`Gralloc5 lock failed` ou `Function not implemented`. O teste de captura foi
executado com o formato `0x11d` e retornou `unlock` normal; os avisos de
latência do pós-processamento continuam sendo apenas timeout de 10 ms.
