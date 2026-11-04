# Auditoria das pilhas gráficas do Exynos 990

Esta auditoria separa as interfaces por camada. O módulo permanece com o
arquivo `disable` enquanto a composição real não for validada em teste longo.
Nenhum binário do S26+, R11s ou de outro SoC é instalado como backend do Mali.

| Camada | Estado no y2s | Decisão |
| --- | --- | --- |
| Gralloc1 / Mali | funcional no vendor original | preservar `gralloc.exynos990.so` |
| Allocator HIDL 2.0 | funcional | manter para os clientes legados |
| Mapper HIDL 2.1 | funcional | manter como fallback |
| Allocator AIDL v2 | registrado quando `EXYNOS990_AIDL_GRAPHICS=1` | usar como caminho global; manter HIDL para clientes legados |
| Mapper Stable-C 5 | carregado pelo `Gralloc5` após o contexto SELinux correto | usar globalmente, preservando o handle Mali/Gralloc1 |
| Backend HWC2 de consulta | biblioteca ARM64 compilada, somente em `prebuilt/test` | usar para validar o backend antes do adaptador Binder |
| Composer HIDL 2.3 / HWC2 | caminho atual do aparelho | preservar até existir uma ponte completa |
| Composer3 AIDL | serviço carregado pelo SurfaceFlinger; backend físico ainda é HWC2 | manter a ponte sob teste até validar composição longa |

## Primeira pilha: allocator AIDL e mapper Stable-C global

Os artefatos são compilados por
`platform/exynos990/patches/graphics_allocator_bridge/build.sh` contra as
bibliotecas do `out/target/y2s/work_dir/system/system/lib64`. A checagem deve
confirmar:

- ELF ARM64 e tabela dinâmica válida;
- export `AIMapper_loadIMapper` e versão Stable-C;
- contexto SELinux do mapper privado;
- ciclo allocate/import/lock/unlock/flush/reread/free, inclusive double-free;
- fences válidas e contabilidade DMA-BUF/Mali sem crescimento contínuo.

Para executar a auditoria sem modificar a árvore:

```sh
platform/exynos990/patches/graphics_allocator_bridge/audit_graphics_stack.sh
```

O script exige o mapper ARM64 e seus exports, além do fragmento VINTF e do
contexto SELinux do allocator. Com o modo global ativo, o `libui` consulta
`IAllocator/default`, recebe o sufixo Stable-C e carrega
`mapper.exynos990_compat.so` no processo. O backend continua usando o
`gralloc.exynos990.so` e seu `private_handle_t` original; não há handle SGR do
S26+. A câmera ainda mantém seu cliente Gralloc1/HIDL próprio até o adaptador
de `libGrallocMapperCamera.so` ser promovido após a validação de RAW, fences e
buffers protegidos.

O nome do passthrough também precisa estar em
`vendor_service_contexts`:

```text
mapper/exynos990_compat u:object_r:hal_graphics_mapper_service:s0
```

Sem essa linha, o `servicemanager` aplica `default_android_service`, nega o
`find` do SurfaceFlinger e o framework cai para `Gralloc4/3/2`.

## Segunda pilha: Composer3 AIDL

O alvo possui as bibliotecas de tipos Composer3 AIDL V4/V5 no system, mas o
serviço ativo continua sendo
`android.hardware.graphics.composer@2.3-service`, ligado ao
`hwcomposer.exynos990.so`. A presença de `composer3-V*-ndk.so` não constitui
um HAL: são apenas tipos Binder e parcelables.

Uma ponte segura precisa implementar, no mínimo, criação do cliente, hotplug,
configurações e modos do painel, comandos de camada, fences de acquire/release,
validate/present, power mode e callbacks. Esses comandos precisam ser
convertidos para o HWC2 Samsung mantendo o layout Gralloc1 e a sincronização do
Mali. Registrar um serviço que apenas responda `UNSUPPORTED` faria o
SurfaceFlinger perder a composição; por isso essa camada não foi habilitada.

O patch `framework_compat` continua impedindo que o Watchdog monitore a sonda
AIDL Composer3 ausente no alvo até essa ponte existir. O SurfaceFlinger ainda
mantém seu fallback HIDL normal. O próximo passo é implementar e testar o adaptador
HWC2→Composer3 em um módulo separado, com uma propriedade de ativação e
rollback simples; só depois ele poderá entrar na matriz VINTF.

Como etapa intermediária, `build_composer_backend.sh` gera
`prebuilt/test/libexynos990_hwc2_backend.so` e o executável
`prebuilt/test/hwc2_backend_probe`. A biblioteca abre o módulo
`hwcomposer.exynos990.so` pelo contrato HWC2 e consulta o display/configuração
ativa, resolução, período de vsync, DPI, tipo e nome. Ela não é copiada para a
vendor nem registra serviço; serve para confirmar que a ponte futura conversa
com o backend proprietário sem passar pelo Composer HIDL.

## Auditoria conjunta antes de habilitar qualquer camada

1. Validar VINTF sem duplicar a instância `default` HIDL.
2. Conferir `service list`, `lshal` e o domínio SELinux do serviço.
3. Confirmar no mapa do SurfaceFlinger qual mapper foi carregado.
4. Exercitar câmera, vídeo, rotação, suspensão/retomada e jogo prolongado.
5. Comparar `mali*/gpu_memory`, DMA-BUF e `vmm num_map` antes e depois.
6. Recolher fences inválidas, `Gralloc`, `SurfaceFlinger` e `lmkd` no mesmo
   intervalo de teste.
7. Só remover `disable` após todos os itens permanecerem estáveis em mais de
   um ciclo de boot.
## Contrato Composer3 gerado e controles HWC2

`build_composer_aidl.sh` gera os 90 AIDL do contrato Composer3 V5 e monta o
artefato ARM64 `prebuilt/test/libexynos990_composer3_contract.so`. A biblioteca
usa o runtime V5 presente no system do y2s e mantém o C++ estático para não
misturar a ABI da `libc++` da base. A classe de teste já cobre as consultas de
configuração, nome, resolução, DPI, vsync, orientação, modo de cor e os
controles de power/vsync por uma sessão HWC2 persistente.

O binário não é um serviço instalado. O adaptador já converte callbacks de
hotplug, refresh, vsync, mudança de período e seamless, além de buffers por
slot, acquire fences, client target, `validate`, mudanças de composição,
`acceptDisplayChanges`, `present`, o present fence e os release fences por
layer. Isso é exercitado por
compilação e símbolos; registrar o serviço nessa fase substituiria o Composer
HIDL funcional antes da validação no aparelho.
O arquivo `disable` e a ausência de VINTF/SELinux do Composer3 devem ser
mantidos até esses itens serem implementados e testados em composição real.

O `V5-ndk.so` extraído do alvo também exporta símbolos de compatibilidade que
não aparecem no AIDL V5 público usado para gerar este módulo, incluindo
`getDisplayKnownVsyncSample`. Esse desvio precisa ser mapeado contra o
SurfaceFlinger da base antes de prometer compatibilidade binária; a ponte não
inventa esse método nem o registra como se fosse parte do contrato AOSP.
O backend HWC2 agora também exporta os primitives de transação usados pela
ponte: criação e destruição de layer, buffer e propriedades de layer, client
target, `validate`, leitura das mudanças de composição, aceitação de mudanças,
`present` e registro de callbacks. A ponte duplica os acquire fences antes de
entregá-los ao HWC2 e devolve o present fence e os release fences como
`ParcelFileDescriptor`.
Eles são exercitados por símbolo e compilação nesta etapa; ainda não são
expostos na vendor.

O contrato Binder já usa `createLayer`, `destroyLayer`, `setActiveConfig`,
`registerCallback` e `executeCommands` para chamar esses primitives quando a
classe é testada. Permanecem pendentes a prova de sincronização no aparelho,
lifecycle CREATE/DESTROY em lote, comandos de cor/metadados e
o mapeamento dos modos de display antes de habilitar VINTF.

### Cobertura da interface

`src/composer3_contract.cpp` agora declara explicitamente **50/50 métodos de
`IComposerClient` V5**. Os 33 métodos sem equivalente HWC2 seguro foram
implementados para a auditoria: retornam capacidade vazia/identidade/zero
quando o contrato permite ou `EX_UNSUPPORTED` quando a operação exigiria um
recurso ausente. Assim, nenhum método novo fica dependente do comportamento
default silencioso do AIDL. A auditoria ainda mantém o Composer3 fora da VINTF
até que lifecycle em lote, comandos avançados e validação no aparelho sejam
concluídos.
