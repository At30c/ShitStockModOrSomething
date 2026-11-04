# Decodificação consolidada dos contratos gráficos — y2s/Exynos 990

Data da auditoria: 25/10/2026  
Escopo: `y2s`/`y2slte` com vendor do S20+ Exynos 990 e a vendor
`SM-S947B_EUX` usada somente como referência de arquitetura Android 17.

Este é o documento de referência para a modernização gráfica. Ele consolida a
desmontagem dos binários, os testes no aparelho e a auditoria de integração.
Não instala, copia ou usa blob do S26+ no y2s.

> **Leitura obrigatória:** uma dependência ELF, um offset lido por um blob e
> uma observação de log são evidências diferentes. O documento marca esse
> limite em cada conclusão. Se houver conflito com uma anotação histórica,
> prevalece a evidência classificada abaixo e a hash do binário analisado.

## 1. Resultado em uma página

1. O backend físico ainda é o conjunto original do y2s:
   `gralloc.exynos990.so` para alocação/mapeamento e
   `hwcomposer.exynos990.so` para composição. A camada AIDL nova é uma
   fachada que chama esse backend; ela não é um driver Mali/SGR novo.
2. O y2s pode expor um allocator AIDL v2 e um mapper Stable-C v5, mas isto
   **não** torna o ABI HIDL removível. Há oito clientes com chamada HIDL
   `getService()` e ainda não há mapper Stable-C de 32 bits.
3. O S26+ usa SGR: handle, metadata, serviços, VINTF e Composer são outra
   pilha. Ele serve para estudar o contrato público AIDL, nunca como donor
   binário ou de offsets.
4. O formato privado de preview `0x11d` continua opaco. O caminho CPU novo
   obtém planos zerados em uma sessão atual; o verde é a conversão de
   `Y=Cb=Cr=0`, não uma evidência de sensor defeituoso. Isso não autoriza
   classificar o buffer como AFBC, SBWC, linear ou multi-FD.
5. A ordem segura é: documentar/validar cada contrato do y2s, preservar o
   caminho proprietário quando não houver tradução comprovada, e retornar
   `UNSUPPORTED` para metadata que o handle Mali não descreve.

## 2. Como a evidência foi classificada

| Marca | Significado |
| --- | --- |
| **[ELF]** | Cabeçalho ELF, `DT_NEEDED`, símbolo dinâmico, VINTF, init ou SELinux lido diretamente. |
| **[ASM]** | Instrução ARM64 ou fluxo de controle desmontado do binário cuja hash está nesta página. |
| **[RT]** | Comportamento visto no aparelho ou em um teste executado. |
| **[INF]** | Inferência técnica plausível, ainda não demonstrada. Não pode virar código definitivo sem teste. |

Os comandos de reprodução estão em
[`decode_graphics_contracts.sh`](../decode_graphics_contracts.sh). O script é
somente leitura: escreve o relatório na saída padrão, não monta imagem e não
inicia uma build.

## 3. Amostras e identidade dos binários

Os offsets e conclusões abaixo pertencem às amostras exatas desta tabela.
Antes de repetir uma alteração, confira a hash: uma firmware diferente pode
manter o SONAME e mudar a estrutura privada.

| Papel | Arquivo analisado | SHA-256 |
| --- | --- | --- |
| Backend Gralloc1/Mali y2s | `out/target/y2s/vendor-gralloc5-20261025/lib64/hw/gralloc.exynos990.so` | `1dd0cd1c9d20b224f63f780bfc647f828203e3fb2b5654172aa6d86aed9b70e7` |
| Mapper HIDL 2.1 y2s | `out/target/y2s/work_dir/vendor/lib64/hw/android.hardware.graphics.mapper@2.0-impl-2.1.so` | `b80b5e191750144137eb1e85b761dd7b4cc144c5f42b04a74810c254f6d4e022` |
| Mapper privado da câmera y2s | `out/target/y2s/vendor-gralloc5-20261025/lib64/libGrallocMapperCamera.so` | `2d4fd0175db7be753a8802bea85e057fd4bb727f5ed255429d78ff860d6eb482` |
| HWC2 y2s | `out/target/y2s/work_dir/vendor/lib64/hw/hwcomposer.exynos990.so` | `a5e643d67fe17d183c8fc4b8e214d73dcbc06f05949b84a444933fd86612ee17` |
| Mapper Stable-C SGR | `out/fw/SM-S947B_EUX/vendor/lib64/hw/mapper.stableC-impl-sgr.so` | `e7e8acdcf18025b0939e6c4cb32189d6d1dd50a43d18c1fd5a0f6017d964eaea` |
| Allocator AIDL SGR | `out/fw/SM-S947B_EUX/vendor/bin/hw/android.hardware.graphics.allocator-aidl-service-sgr` | `f6ebbc7cf27e59335f4fce833bcc3a1300d9fda1a3f0581ea3aa7857241eeed3` |
| Composer3 SGR | `out/fw/SM-S947B_EUX/vendor/bin/hw/android.hardware.graphics.composer3-service.exynos` | `18ee8f19d392d481ca5918fd9094f9023e35a33dae38bb38df1e91bbaeb54d1e` |

As três bibliotecas y2s são ARM64, Android 30 e stripped. As três amostras
S26+ são ARM64, Android 36 e stripped. `stripped` não impede auditoria de
símbolos dinâmicos, strings, relocations e código, mas impede atribuir nomes
de campos privados sem uma evidência adicional.

## 4. Mapa da pilha real

```text
                           Framework Android 17
                                      |
                        Gralloc5/AIDL quando declarado
                                      |
       +------------------------------+-----------------------------+
       |                                                            |
mapper.exynos990_compat.so                                  allocator AIDL v2
       |                                                            |
       +-------------- libexynos990_graphics_compat.so ------------+
                                      |
                         gralloc.exynos990.so (Gralloc1/Mali)
                                      |
                                ION / DMA-BUF

Camera HAL ─ libGrallocMapperCamera.so ─ callbacks Mali/Gralloc1
SurfaceFlinger ─ Composer3 AIDL bridge ─ HWC2 ─ hwcomposer.exynos990.so
```

O desenho não diz que todos os processos usam sempre AIDL. A seleção depende
do VINTF, do serviço publicado, do contexto SELinux e da arquitetura do
processo. A câmera proprietária continua tendo uma rota direta para o mapper
HIDL/Gralloc1. O Composer3 novo converte a interface do framework para HWC2;
ele não converte o HWC2 em um driver SGR.

## 5. Backend Gralloc1/Mali do y2s

### 5.1 Dependências e superfície exportada

`gralloc.exynos990.so` depende de `libhardware`, `liblog`, `libcutils`,
`libGLESv1_CM`, `libion_exynos`, `libsync`, `libutils`, `libnativewindow`,
`libc++`, `libc`, `libm` e `libdl` **[ELF]**. As rotinas dinâmicas encontradas
se agrupam assim:

| Grupo | Entrypoints relevantes recuperados |
| --- | --- |
| Alocação/formato | `mali_gralloc_allocate`, `mali_gralloc_select_format`, `mali_gralloc_get_format_internal`, `mali_gralloc_derive_format_and_size` |
| Posse/importação | `mali_gralloc_reference_retain`, `mali_gralloc_reference_release`, `mali_gralloc_get_backing_store_internal` |
| ION | `mali_gralloc_ion_map`, `mali_gralloc_ion_unmap`, `mali_gralloc_ion_sync_start`, `mali_gralloc_ion_sync_end` |
| CPU lock | `mali_gralloc_lock`, `mali_gralloc_lock_ycbcr`, `mali_gralloc_lock_flex_async`, `mali_gralloc_unlock` |
| Descritor/metadata legada | getters/setters de dimensão, layer count, uso produtor/consumidor e descritor interno |

Isto confirma que a execução material do buffer permanece neste blob. O
allocator AIDL deve preservar import/release e lock/unlock deste backend em
vez de fabricar um segundo controlador de ION.

### 5.2 Posse, importação e sincronização

O caminho Gralloc1 clona o `native_handle` em importação e mantém referências
por processo; a liberação final desmonta/libera o estado ION antes de descartar
o clone **[ASM]**. Portanto:

* `importBuffer()` e `freeBuffer()` precisam ser pareados uma única vez por
  clone, mesmo que dois processos apontem para o mesmo backing store;
* nenhum adaptador pode fechar os FDs do handle emprestado;
* lock CPU precisa ser sucedido por unlock no mesmo backend que fez o lock;
* o identificador de backing store é útil para agrupar metadata, mas não
  substitui a contagem de referências do driver.

`mali_gralloc_lock_flex_async()` consome um acquire-fence válido: primeiro
chama `sync_wait(fence, -1)` e depois `close(fence)` **[ASM]**. Quem encaminha
o fence deve transferir sua posse uma única vez; esperar ou fechar de novo no
bridge cria deadlock, `EBADF` ou uso prematuro do buffer.

### 5.3 Validação mínima do `private_handle_t`

O lock analisado só aceita a variante desta firmware quando o cabeçalho passa
suas verificações: `native_handle.version == 12`,
`numFds + numInts == 65` e magic `0x03141592` em `+0x20` **[ASM]**. Esses são
invariantes de validação, não uma especificação Android universal.

| Offset do início do handle | Papel lido pelo blob y2s | Evidência e limite |
| --- | --- | --- |
| `+0x00`, `+0x04`, `+0x08` | versão, número de FDs, número de inteiros | Cabeçalho `native_handle_t`; só é válido antes de qualquer cast privado. |
| `+0x20` | magic da estrutura y2s | Validado pelo lock. Nunca usar como magic SGR. |
| `+0x24` | flags privadas | Consultado em ramificações de lock; sem semântica completa publicada. |
| `+0x28`, `+0x2c` | largura e altura | Recuperados na validação/descrição do handle. |
| `+0x30` | `frameworkFormat` | É o campo lido pelo símbolo exportado `mali_gralloc_get_format_internal()` no blob auditado. O nome do símbolo é enganoso; ele não prova o `internal_format` da classe `ExynosGraphicBufferMeta`. |
| `+0x38`, `+0x40` | usos de produtor e consumidor | São domínios Gralloc1 distintos; não devem ser somados/mascarados como uma flag AIDL única. |
| `+0x48` | `internal_format` da metadata Exynos | `libexynosgraphicbuffer.so` lê este `u64` em `get_format()`/`get_internal_format()`; o bridge agora o acessa diretamente após validar o handle. |
| `+0x50` | `alloc_format` usado por rotas de lock/flex | O `mali_gralloc_lock_*` lê o low32 deste campo; a tabela de formatos e o caso privado `0x11d` pertencem a esta seleção de alocação. |
| `+0x5c` | stride Y | Usado nas rotas y2s NV12/NV21/YV12 conhecidas. |
| `+0x64` | vstride observado pela metadata Exynos | Lido por `ExynosGraphicBufferMeta::get_vstride()`; não é automaticamente igual ao stride de bytes em `+0x5c`. |
| `+0x68`, `+0x6c` | offset e stride de croma | Usados nas rotas conhecidas, não em todo formato privado. |
| `+0x78` | segundo offset de croma | Caminho YV12 conhecido. |
| `+0x94` | stride retornado por `ExynosGraphicBufferMeta::get_stride()` | É uma leitura distinta observada no blob de metadata; correlacionar com `+0x5c` exige um handle real e não deve ser presumido. |
| `+0x108` | flag consultada por `ExynosGraphicBufferMeta::is_afbc()` | Indica apenas o que essa metadata considera AFBC; não é prova de modifier DRM sem validação do layout. |
| `+0xa0` e adjacências | mapeamento virtual por processo | Endereço transitório depois de import/map; nunca serializar ou copiar entre processos. |

Os offsets de planos só estão comprovados para os formatos publicamente
identificados no próprio y2s (`0x200` NV12, `0x201` NV21 e YV12). Eles não
descrevem automaticamente todo formato que o aplicativo observa, sobretudo
`0x11d`.

### 5.3.1 Distinção comprovada entre os três formatos

Uma segunda amostra, `libexynosgraphicbuffer.so` (SHA-256
`0da060a9fe7ee620143322f96a4d4837f00fef01d2dd403141dd691d60086caf`), permite
separar os campos que o blob Gralloc1 expõe com nomes ambíguos **[ASM]**:

| API/rotina | Leitura observada | Interpretação segura |
| --- | --- | --- |
| `mali_gralloc_get_format_internal(native_handle_t*, int*)` | `w` em `handle + 0x30` | `frameworkFormat` desta versão, apesar do nome exportado. |
| `ExynosGraphicBufferMeta::get_format()` | `w` em `handle + 0x48` | low32 de `internal_format`. |
| `ExynosGraphicBufferMeta::get_internal_format()` | `x` em `handle + 0x48` | `internal_format` completo, 64 bits. |
| `ExynosGraphicBufferMeta::get_frameworkFormat()` | `w` assinado em `handle + 0x30` | formato solicitado pelo framework. |
| `mali_gralloc_lock_flex_async()` | low32 em `handle + 0x50` | `alloc_format` usado para escolher a entrada de planos. |

O mesmo `private_handle_t` pode, portanto, conter valores diferentes em
`+0x30`, `+0x48` e `+0x50`. O bridge não usa mais o símbolo ambíguo no caminho
de modifier: a rota Stable-C lê `+0x48` diretamente somente depois de validar
versão, `numFds + numInts == 65`, magic e tamanho do handle. Um high-word
observado em buffers GPU lineares é aceito somente quando o low32 não possui
bits de modifier; para combinações não lineares desconhecidas, o decoder
rejeita o high-word ou qualquer bit privado. Isso é uma proteção, não uma
prova de que o firmware produz AFBC.

### 5.4 Formatos, AFBC e modifiers

O blob contém 59 entradas na tabela de formatos e exporta
`mali_gralloc_get_format_internal()` **[ELF/ASM]**. As strings e ramificações
confirmam que:

* formatos YUV compatíveis devem usar `LOCK_FLEX`;
* `LOCK_FLEX` pode recusar buffers AFBC porque um layout flexível não os
  representa;
* buffers AFBC não podem ser mapeados como um buffer CPU linear comum;
* a combinação formato/uso é validada antes do map;
* formatos desconhecidos devem falhar, e não receber um modifier inventado.

Nos probes do próprio y2s, o símbolo exportado retornou `0x1` para um RGBA
real e `0x23` para a alocação YUV de teste. Esses valores são os
`frameworkFormat` lidos em `+0x30`, e não uma medição do `internal_format`
de `+0x48`. O mapper publicou `DRM_FORMAT_MOD_LINEAR` para o RGBA real
**[RT]**. O código de decoder AFBC existe e agora recebe o campo validado em
`+0x48`, mas o allocator não produziu um handle AFBC real no teste. Assim,
somente o caminho linear está validado em runtime.

No teste direto desta sessão, os valores do handle foram capturados antes do
release **[RT]**:

| Pedido | `+0x30` framework | `+0x48` internal (64 bits) | `+0x50` alloc |
| --- | ---: | ---: | ---: |
| RGBA GPU | `0x00000001` | `0x0000000100000001` | `0x00000001` |
| RGBA CPU linear | `0x00000001` | `0x0000000000000001` | `0x00000001` |
| YUV 420 de teste | `0x00000023` | `0x0000000000000011` | `0x00000011` |

O high-word `1` do RGBA GPU é uma extensão observada no próprio allocator e
não pode ser descartada como erro. O bridge o aceita somente quando o low32 é
linear; high-words em combinações com bits de modifier continuam rejeitados.

**Não inferir:** `0x11d` não foi demonstrado como AFBC, SBWC, DCC, linear ou
um modifier DRM específico. Também não se deve reutilizar bits, modifiers ou
layouts do SGR do S26+.

## 6. Mapper HIDL, câmera e o formato privado `0x11d`

### 6.1 Caminho original da câmera

`libGrallocMapperCamera.so` preserva a ABI HIDL de `GrallocMapperCamera` e
depende de `android.hardware.graphics.mapper@2.0.so` **[ELF]**. O disassembly
da sobrecarga `Mapper::lock(..., YCbCrLayout*)` confirma a sequência abaixo
**[ASM]**:

1. chama `mali_gralloc_get_num_flex_planes(nullptr, handle, ...)`;
2. chama `mali_gralloc_lock_flex_async(nullptr, handle, usage, rect, layout,
   fence)`;
3. converte os flex planes em `YCbCrLayout`;
4. no unlock chama `mali_gralloc_unlock(nullptr, handle)`.

O primeiro argumento é nulo nessas chamadas, exatamente como no mapper stock.
O `ExynosCameraStreamAllocator::lock` de `libexynoscamera3.so` passa
`fence=-1` nessa rota **[ASM]**. Um substituto compatível precisa manter
SONAME, símbolos C++ e essa semântica; trocar para um módulo Gralloc1
independente ou alterar arbitrariamente o uso combinado já provocou erros de
request no passado.

### 6.2 O que foi realmente observado no preview

Na captura histórica que produzia foto/vídeo, o bridge registrou para o
preview `0x11d`: tamanho `2.332.800`, geometria `1440x1080`, stride
`1440/1440`, e ponteiros virtuais Y e croma distintos **[RT]**. Isso prova que
aquele caminho recebeu dois intervalos virtuais diferentes. Não prova, por si
só, que existam dois FDs, qual é o modifier, se há compressão ou qual o layout
físico por trás do ION.

Na sessão mais recente do conversor CPU no Composer, o mesmo tipo de fluxo
chegou com uso de produtor `0x60`, consumidor `0x900` e uso legado calculado
`0x933`. `LOCK_FLEX` devolveu geometria de planes válida, mas amostras Y/Cb/Cr
foram `0/0/0`; uma leitura RGBA resultou em `0/135/0` **[RT]**. A conversão
YUV→RGB faz isso para amostras nulas, explicando o preview verde.

Conclusão delimitada: o mapeamento CPU usado nesse caminho não vê conteúdo
útil naquele instante. As hipóteses ainda abertas são domínio de cache/fence,
mapa ION por processo, uso/semântica privada de plano ou um producer/consumer
opaco que não é legível por CPU. Não há prova suficiente para culpar EDEN, o
sensor, AFBC ou a câmera inteira.

### 6.3 Estrutura da tabela e o caso `0x11d`

Na amostra Gralloc1, a tabela `formats` começa em `0x5d60`, tem 59 entradas
de 28 bytes e a entrada associada ao fluxo `0x11d` está em torno de `0x60c4`
**[ASM]**. Nessa entrada, o byte `+0x05` indica três planos flexíveis e o
byte `+0x1a` indica a variante de layout observada. O switch de
`lock_ycbcr()` não aceita `0x11d`; o caminho correto é `lock_flex_async()`, que
possui despacho próprio para essa seleção. Isso explica por que converter o
buffer privado por `YCbCrLayout` genérico produz resultado verde ou zero sem
que o sensor esteja necessariamente falhando.

### 6.4 Ação correta para `0x11d`

Enquanto não existir uma descrição recuperada do driver para `0x11d`, o
adaptador deve:

* manter o handle privado original no caminho HWC/Mali;
* registrar apenas metadata que venha do próprio driver;
* não derivar offset, modifier, subsampling ou número de FDs por palpite;
* preferir um erro explícito a converter para um RGB/YUV sintético;
* instrumentar a estrutura e os resultados de lock sem registrar conteúdo de
  imagem, antes de mudar a semântica de um buffer real.

## 7. Mapper Stable-C e allocator AIDL do y2s

O adaptador local contém três responsabilidades diferentes:

| Componente | Responsabilidade | Não faz |
| --- | --- | --- |
| `mapper.exynos990_compat.so` | Entry point Stable-C no processo cliente; traduz metadata que o Gralloc1 comprova | Não vira um mapper SGR nem altera o handle Mali. |
| `android.hardware.graphics.allocator-V2-service.exynos990` | Serviço Binder AIDL de alocação | Não substitui ION/Mali; encaminha ao Gralloc1 original. |
| `libexynos990_graphics_compat.so` | Tabela compartilhada de callbacks/ponte Gralloc1 | Não é uma biblioteca genérica capaz de satisfazer SONAMEs SGR. |

O mapper Stable-C deve ser considerado uma biblioteca *in-process*. Por isso
um binário apenas em `vendor/lib64/hw/` não cobre processos 32 bits. O
allocator Binder pode atender clientes de outra arquitetura pelo Binder, mas o
mapper é carregado dentro do cliente que usa `GraphicBufferMapper`.

### 7.1 Fence do preview no Composer3

Na primeira implementação do `CameraRgbConverter`, o acquire fence recebido
do Composer3 era duplicado apenas para manter a posse local e, em seguida,
fechado antes de chamar `mali_gralloc_lock_flex_async(..., fence)`. Isso era
incorreto para o caminho de composição: o produtor da câmera ainda podia estar
preenchendo o DMA-BUF quando o conversor lia os planes. O callback original do
y2s espera e fecha um fence não-negativo por conta própria, como confirmado no
disassembly da função.

O conversor agora entrega essa duplicata diretamente ao callback. Dessa forma,
o gralloc faz a espera e a invalidação/cache maintenance no momento correto,
antes da leitura Y/Cb/Cr. Esta é uma correção de sincronização baseada no
contrato do próprio y2s; não altera o `private_handle_t`, não importa offsets do
SGR do S26+ e não transforma `0x11d` em um formato público arbitrário.

O sintoma que motivou a mudança foi `LOCK_FLEX` retornar uma geometria válida,
mas amostras `0/0/0`, que a conversão YUV→RGBA mostrava como verde. A validação
final exige uma nova sessão de câmera com o bridge carregado; se os samples
continuarem nulos mesmo após o fence, o problema passa a ser o mapeamento/cache
privado do driver, e não a ordem de composição.

O serviço AIDL exige VINTF, rc, contexto de arquivo, contexto de serviço e
permissões coerentes antes de ser selecionado. Em particular, o nome Stable-C
precisa de:

```text
mapper/exynos990_compat u:object_r:hal_graphics_mapper_service:s0
```

Sem esse label o servicemanager pode tratar o nome como
`default_android_service`, negar o `find` do SurfaceFlinger e fazê-lo retornar
ao fallback HIDL **[RT]**.

## 8. Como o framework escolhe AIDL ou HIDL

O `libui` do sistema tem as duas famílias de ABI em `DT_NEEDED`. Isso, sozinho,
não significa que o caminho HIDL está ativo. A lógica recuperada tenta o
mapper Gralloc5/Stable-C primeiro; depois tenta Gralloc4, Gralloc3 e Gralloc2
**[ASM/ELF]**. AIDL só se torna a rota prática quando o mapper é carregável,
declarado no VINTF e autorizado pelo servicemanager/SELinux.

O relatório de aposentadoria HIDL encontrou neste conjunto de arquivos:

| Classe | Clientes encontrados | Consequência |
| --- | --- | --- |
| `BLOCKER` — chamada direta a `getService()` | `system/lib64/libui.so`, `system/lib/libui.so`, `system/lib/libgui.so`, `vendor/lib64/camera.device@1.0-impl.so`, `camera.device@3.2-impl.so`, `camera.device@3.5-impl.so`, `vendor.samsung.hardware.camera.device@5.0-impl.so`, `android.hardware.graphics.composer@2.1-resources.so` | Não apagar allocator/mapper HIDL. É preciso migrar o cliente ou fornecer uma ABI HIDL compatível. |
| `ABI-ONLY` — `DT_NEEDED`, sem chamada direta encontrada | `libGrallocMapperCamera`, `unihal_android`, `libexynosgraphicbuffer`, `libSecC2ComponentStore` e outros | Ainda precisa de auditoria de execução; não é licença para apagar a biblioteca. |

Os HALs de câmera sondam mapper V4→V3→V2. `libui` conserva fallbacks para
versões HIDL. Além disso, `system/lib/libui.so` e `system/lib/libgui.so` são
clientes 32 bits, enquanto os prebuilts atuais do mapper novo são somente
ARM64 **[ELF]**. Esse é um bloqueio independente da câmera para uma remoção
definitiva do HIDL.

## 9. Composer, HWC2, resolução e fences

`hwcomposer.exynos990.so` é um backend HWC2 do y2s, ligado a
`libexynosdisplay.so`, `libacryl.so`, `libExynosHWCService.so`, `libion.so` e
`libui.so` **[ELF]**. A desmontagem/exportações recuperam operações para:

* displays e configs: enumerate, nome, tamanho, DPI, vsync, modo ativo,
  grupos e constraints;
* lifecycle de layer: criar/destruir, buffer, crop, frame, transformação,
  blend, alfa, z-order, dataspace e damage;
* composição: client target, validate, changed composition, accept, present,
  release fences e readback;
* callbacks: hotplug, refresh, vsync e mudança de período;
* HDR, color mode/render intent, metadata por frame, virtual display e power.

O Composer3 local deve traduzir comandos AIDL para essa ABI HWC2. Não pode
chamar `ExynosDevice`, `ExynosDisplay` ou `ExynosLayer` do S26+, pois essas
classes não pertencem ao HWC2 y2s. A ordem prática que o HWC Samsung exige
continua sendo:

```text
validate -> clientTarget -> acceptDisplayChanges -> present
```

As fences devem seguir a mesma regra de posse dos locks: acquire é consumida
uma vez pelo lado que a recebe; present/release são duplicadas apenas quando a
interface destino exige uma cópia. O Composer3 não elimina o HWC2 físico — ele
o encapsula.

O RC HIDL do Composer só pode ficar `disabled` quando o Composer3 AIDL do y2s
for instalado e publicado; manter as duas sessões abertas para o mesmo HWC2
causou troca lógica de resolução sem confirmação física. Isto não autoriza
remover binários HIDL, VINTF ou bibliotecas de recursos que ainda são
consumidas.

## 10. Contrato SGR/AIDL do S26+: referência, não donor

O S26+ declara allocator AIDL v2, mapper `@5.0/stableC-impl-sgr` e Composer3
AIDL v4 no VINTF **[ELF]**. Seu allocator depende diretamente do mapper SGR;
eles são uma única pilha de contrato. As dependências relevantes incluem:

| Parte | Dependências específicas observadas |
| --- | --- |
| Mapper/allocator SGR | `libgralloctypes.so`, `libeis_utils.so`, `libion_exynos.so`, `libbinder_ndk.so`, `android.hardware.graphics.allocator-V2-ndk.so` |
| Composer3 SGR | `composer3-V4-ndk.so`, `vendor.samsung_slsi.hardware.graphics.extension.composer3-V5-ndk.so`, `libexynosdisplay.so`, `libExynosHWCService.so`, `libui.so` |

O handle SGR possui outro ABI. A desmontagem mostra, entre outros campos,
magic em `+0x38`, handles/FDs em `+0x48`, bases em `+0x78`, metadata em
`+0xc8`, PID em `+0xd0`, uso/lock CPU em `+0xd8`, dimensões/formato em
`+0xe4..+0xec`, uso em `+0xf0`, formato/layout alocado em `+0x100..+0x104`,
planos em `+0x110` e versões perto de `+0x2c4/+0x2c8` **[ASM]**. Isso é
estruturalmente incompatível com o handle y2s validado na seção 5.

O que pode ser reaproveitado do S26+ é o **modelo**: metadata explícita,
validação por produtor/consumidor, separação câmera/CPU/vídeo/HWC, gestão de
fences, VINTF e SELinux coerentes. O que não pode ser copiado é o blob,
SONAME, handle, offsets, modifier SGR/SBWC/DCC, serviço, label ou extensão
Samsung de Composer3.

## 11. Estado funcional por área

| Área | Estado com evidência | Pendência para promoção definitiva |
| --- | --- | --- |
| Backend de alocação | Gralloc1/Mali original opera e é usado pelo adaptador AIDL **[RT]** | Não substituir o blob enquanto não houver implementação equivalente de todos os formatos e ION. |
| RGB/metadata básica | Import, release e modifier linear foram exercitados **[RT]** | Cobrir todos os tipos de metadata e os formatos que o framework realmente pede. |
| AFBC/modifiers privados | Decoder conservador existe | Falta um handle AFBC real para validar. Valores desconhecidos devem falhar. |
| Câmera no caminho legado | Há sessões históricas com preview, foto e vídeo **[RT]** | RAW efetivo, protected buffers e estabilidade prolongada. |
| Preview privado no caminho CPU novo | Conteúdo zerado/verde observado **[RT]** | Decodificar contrato `0x11d` ou preservar o trajeto opaco original. |
| Composer3 sobre HWC2 | Configs, layers e fences têm base de adaptação **[ELF/RT]** | Teste prolongado de composição, hotplug, readback e comandos avançados. |
| AIDL global | Seleção pode funcionar se integração VINTF/SELinux estiver correta **[RT]** | Cobrir processo 32-bit e todos os clientes legados. |
| Remoção HIDL | Bloqueada | Migrar/recompilar clientes, fornecer compatibilidade ABI e mapper Stable-C 32-bit. |

## 12. Próxima sequência segura

1. **Captura estrutural do `0x11d`:** logar versão, contagem de FDs/inteiros,
   magic, usos, formato interno/solicitado, flags e resultado de cada lock no
   mesmo processo. Não logar pixels nem copiar dados de câmera.
2. **Comparação controlada de lock:** na mesma sessão/processo, comparar a
   rota do `libGrallocMapperCamera` original com a rota do bridge, incluindo
   fence e uso. Uma diferença de ponteiro ou cache tem valor diagnóstico; uma
   conversão RGB não tem.
3. **Preservar buffers opacos:** até a etapa anterior concluir, enviar o
   handle privado original ao HWC/Mali em vez de tentar interpretar `0x11d`.
4. **Cobrir 32 bits e bloqueadores HIDL:** produzir entrypoint Stable-C ARM32
   compatível ou manter HIDL para esses processos; só depois cogitar apagar
   serviços/bibliotecas HIDL.
5. **Validar formatos difíceis:** AFBC real, protected, RAW, ImageReader,
   MediaCodec e fences sob carga. Cada formato/uso precisa de resultado
   separado.
6. **Só então** tornar o allocator/mapper novo a rota de produção e iniciar a
   migração do Composer físico para uma implementação AIDL completa.

## 13. Ações proibidas pela evidência atual

* Não copiar mapper, allocator, Composer, bibliotecas auxiliares ou handles
  do S26+ para o y2s.
* Não usar symlink, hex patch ou um `.so` "amuleto" para satisfazer uma ABI de
  handle/metadata que não existe.
* Não escrever campos privados de `private_handle_t` em um handle que não
  passou pela validação do driver.
* Não anunciar modifier DRM, formato de plano, AFBC/SBWC/DCC ou número de FDs
  para `0x11d` sem uma observação do driver.
* Não apagar HIDL por haver AIDL registrado; os dois podem coexistir enquanto
  os clientes imutáveis ainda pedem HIDL.
* Não confundir o preview verde com prova de falha do sensor ou do EDEN. Os
  dados atuais apontam primeiro para a visão CPU do buffer privado.

## 14. Implementação baseada no contrato AIDL do S26+ (27/10/2026)

O código do bridge foi ajustado usando o S26+ apenas como referência do
contrato Stable-C/AIDL. A implementação continua usando o `gralloc.exynos990.so`
original como backend físico e não importa o handle SGR, os offsets SGR ou
qualquer blob do S26+.

### 14.1 `PLANE_LAYOUTS` não inventa mais um layout para `0x11d`

O caminho genérico de `getStandardMetadata(PLANE_LAYOUTS)` agora consulta o
formato real antes de serializar a metadata. Para o formato privado de câmera
`0x11d`, ele retorna `AIMAPPER_ERROR_UNSUPPORTED` e registra o motivo. Essa é
a mesma decisão que o contrato AIDL permite para um layout que o mapper não
consegue descrever com segurança.

O retorno explícito é necessário porque `PlaneLayout` descreve offsets
relativos a uma alocação transportável entre processos. O `LOCK_FLEX` do y2s
expõe Y e UV por mapeamentos virtuais distintos e a amostra não provou o
índice de FD nem a relação física entre essas regiões. Serializar um plano
linear fictício faria o `GraphicBufferMapper` ler o handle privado como se
fosse uma imagem contínua, reproduzindo o preview verde/preto.

O caminho proprietário da câmera permanece intacto: o mapper HIDL original
continua chamando `mali_gralloc_lock_flex_async(nullptr, ...)`, enquanto o
Composer3 só usa a rota de conversão já validada quando consegue obter uma
visão CPU não nula. A recusa da metadata impede que um cliente AIDL consuma
um layout falso; ela não altera o handle que o HWC2 recebe.

### 14.2 Modifier agora usa o formato efetivo do handle

O caso `PIXEL_FORMAT_MODIFIER` passou a buscar `getFormat()` antes de chamar o
decoder de modifier. Antes, a variável permanecia no valor inicial quando a
metadata era consultada, o que podia classificar incorretamente uma alocação
RGB/YUV. O decoder continua conservador: só publica `DRM_FORMAT_MOD_LINEAR`
ou um AFBC comprovado pelo `internal_format` validado do handle y2s; formatos
privados ou high-word desconhecido continuam retornando `UNSUPPORTED`.

### 14.3 Protected buffers e fences

O mapper também separa alocação protegida de acesso CPU. Um descriptor com
`PROTECTED` ainda pode ser sondado pelo allocator, mas `IMapper::lock()` passa
a retornar `AIMAPPER_ERROR_UNSUPPORTED` antes de chamar `LOCK_FLEX` ou criar o
scratch do `0x11d`; a acquire fence recebida é consumida nesse caminho. Isso
evita expor conteúdo protegido e segue a mesma fronteira observada no mapper
Stable-C do S26+.

### 14.4 Limite de responsabilidade

Esse ajuste implementa a parte segura do modelo S26+: importação, fences,
metadata explícita e rejeição de layouts não representáveis. Ele não afirma
que o `0x11d` já é um buffer AIDL público e não substitui o `libGrallocMapperCamera.so`.
Para aposentar o HIDL da câmera ainda faltam uma descrição recuperada do
layout multi-FD, validação de RAW/protected/ImageReader e uma sessão real de
preview, captura e vídeo com o mapper Stable-C carregado.

### 14.5 Validação local

`build.sh` foi executado contra as bibliotecas do y2s em
`out/target/y2s/work_dir/system/system/lib64`. A compilação ARM64, o
`AIMapper_loadIMapper`, o SONAME da shim de câmera e os probes de modifier
terminaram sem erro.

Em 27/10/2026 a imagem EROFS foi reconstruída com o tamanho real retornado
por `/dev/block/dm-1` (`987979776` bytes), assinada com
`security/avb/testkey_rsa4096.pem` e gravada no recovery com `dd`. O SHA-256
da imagem local e do `dm-1` depois da gravação foi
`af66201e5521666bcd69b8c425eabb88e6c872e58fb4ee4dd04c9bd249337306`.
O backup bruto anterior permanece em
`out/target/y2s/vendor-before-dd-20261027.img`.

Após o boot, o aparelho confirmou `ro.boot.hardware=exynos990`,
`ro.boot.bootloader=G985FXXSNHYB1`, serviço
`android.hardware.graphics.allocator.IAllocator/default` registrado e os
três hashes esperados visíveis em `/vendor`. A câmera abriu sem crash na
sessão curta; os logs mostraram apenas a recusa explícita de `PLANE_LAYOUTS`
para `0x11d` e erros de estado de buffer do HAL legado, sem `SIGSEGV` ou
`SIGBUS`.

## 14. Reprodução da auditoria

```sh
platform/exynos990/patches/graphics_aidl/decode_graphics_contracts.sh \
  > /tmp/y2s-graphics-contracts-$(date +%F).txt

platform/exynos990/patches/graphics_aidl/audit_hidl_retirement.sh \
  out/target/y2s/work_dir
```

O primeiro comando lista hashes, ELF, dependências, símbolos, VINTF, init,
SELinux e trechos de disassembly conhecidos. O segundo deve continuar falhando
enquanto houver `BLOCKER`; essa falha é a proteção correta contra uma remoção
incompleta do HIDL.

## 15. Teste de `PLANE_LAYOUTS` no formato privado `0x11d` (27/10/2026)

Foi testada uma variante que chamava `LOCK_FLEX` do gralloc original para
publicar `PlaneLayout` do formato privado `0x11d`. Embora algumas chamadas
retornassem uma geometria aparentemente válida, os ponteiros expostos pelo
callback eram mapeamentos virtuais privados do processo. Eles não eram
offsets transportáveis do dma-buf exigidos pelo Stable-C.

Durante o preview da câmera, essa variante produziu erros de buffer e terminou
com `SIGBUS (BUS_ADRALN)` no `IReader-MAIN_PR` do Samsung Camera. A variante
foi removida do código e a imagem AVB foi revertida para o hash anterior
`af66201e5521666bcd69b8c425eabb88e6c872e58fb4ee4dd04c9bd249337306`.

O mapper de produção voltou a retornar `AIMAPPER_ERROR_UNSUPPORTED` para
`PLANE_LAYOUTS` de `0x11d`, preservando o trajeto opaco HIDL/Mali da câmera.
O prebuilt recompilado voltou ao SHA-256
`78be789273cde11cd2ccd301e68fb5161be5a8379806d3f94a68bb9e1f80572c`.
Esse resultado confirma que não é seguro converter os ponteiros de
`LOCK_FLEX` em `PlaneLayout` sem recuperar o contrato físico de FD e offset do
handle privado.

## 16. Medição do loop de preview (27/10/2026)

Para separar o bridge AIDL do HAL da câmera, o mapper recebeu uma
instrumentação temporária que mede `LOCK_FLEX`, a cópia para o scratch linear
e `unlock`. A imagem AVB foi instalada no `dm-1` pelo recovery com `dd`; o
SHA-256 da imagem e do bloco foi
`ba3435312662a2db6fa56d82716e4f2615f915aa3e3ceea829f439a9fd406517`.
O mapper usado nessa sessão foi o prebuilt
`2c38deedd5b3ad80040a57d6f64430d923948905c8080cef11b50494472a778d`.

O pedido real da câmera frontal ficou assim:

- stream privado de preview `0x11d`/`0x22`, `1440x1080`, uso `0x900`;
- stream de callback `YUV_420_888`, `1440x1080`, uso `0x20933`, com nove
  buffers;
- captura principal `3648x2736`, além de YUV, RAW e thumbnail.

Os quatro primeiros locks do mapper terminaram em 0--2 ms. A maior cópia
observada foi 51 ms; não houve `SIGBUS`, `SIGSEGV` nem retorno de erro do
mapper. Isso elimina a cópia AIDL como causa dos atrasos de 300--1500 ms.

O atraso começa antes ou fora do mapper: `processBatchCaptureRequests` chegou a
1,956 s, `Camera3-OutputStream` esperou até 950 ms por um buffer, e o kernel/HAL
registrou `shot mismatch`, `FIMC_IS_SYNC 1` e
`ExynosCameraFrameManager wait and pop fail, ret(-110)`. A própria
`BeautyPhotoMaker::produceFrameWithYuv420` passou de 323, 946, 845, 983 e
772 ms, enquanto o mapper continuava com locks curtos. O primeiro
`RESULT ERROR` ocorreu antes do primeiro log de `PlaneLayouts`.

A tela capturada nessa sessão permaneceu preta com a barra roxa, embora a UI da
câmera e a miniatura de preview continuassem ativas. Portanto, o loop não é
resolvido retornando `AIMAPPER_ERROR_UNSUPPORTED`: essa variante foi testada e
deixou o processo global sem fallback seguro para HIDL. O caminho correto agora
é investigar a sincronização do HAL/kernel (`FIMC_IS_SYNC`, `shot mismatch`,
`-110`) e a fila de buffers da stream 1. O bridge AIDL deve continuar com o
scratch validado enquanto essa investigação prossegue; não é seguro publicar
`PlaneLayouts` fictícios nem remover o mapper HIDL da câmera.


## 17. Controle sem o mapper AIDL (27/10/2026)

A vendor original e a vendor usada no teste foram comparadas por SHA-256. Os
blobs de captura permaneceram idênticos, incluindo `camera.exynos990.so`,
`camera.unihal.default.so`, `camera.device@3.5-impl.so`,
`vendor.samsung.hardware.camera.device@5.0-impl.so`,
`libGrallocMapperCamera.so` e `libexynoscamera3.so`. A única alteração do
caminho gráfico foi o mapper AIDL compatível instalado para o teste.

Também foi revisado o log de controle `runtime-hidl-noaidl-20261025.log`. Antes
de o mapper AIDL global ser usado, a câmera já registrava `RESULT ERROR`,
`shot mismatch`, `FIMC_IS_SYNC`, `processBatchCaptureRequests` lento e
`wait and pop fail, ret(-110)`. Portanto, esses erros não foram introduzidos
pelo bridge AIDL nem pela conversão do `0x11d`.

O controle elimina a hipótese de substituir cegamente os blobs de gralloc ou
HIDL. A investigação deve seguir pela compatibilidade do HAL UniHAL original
com o kernel e com a sequência de requisições da câmera Android 17, incluindo
módulo do sensor, firmware FIMC-IS, contagem de frames e fila da stream 1.
