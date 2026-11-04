# Exynos 990 allocator/mapper bridge

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
platform/exynos990/patches/graphics_allocator_bridge/decode_graphics_contracts.sh --brief
```

This module keeps `gralloc.exynos990.so` and its native handle layout. It
builds an allocator AIDL v2 facade and an IMapper stable-C v5 facade for a
newer framework. The y2s target now enables the AIDL allocator globally by
default, so framework `GraphicBufferAllocator`/`GraphicBufferMapper` clients
leave the HIDL path. The stock HIDL allocator remains only as a compatibility
endpoint for immutable vendor HALs whose ABI is not yet AIDL-native (currently
the Exynos camera HAL). The Stable-C mapper translates the Exynos private YUV
handle layout to the `PLANE_LAYOUTS` metadata consumed by the framework;
Android's `GraphicBufferMapper` then constructs the `android_ycbcr` view.

The module remains controlled until the global VINTF/init path is tested. The
v5 mapper follows the Gralloc1 ownership contract: import clones and retains a
handle, and release drops the driver reference before closing the clone when
required. The AIDL allocator now probes the original gralloc in
`isSupported()` and rejects usage bits it cannot represent. A 100-cycle
allocator/mapper test completed without black screens, mapper crashes, or
ownership errors; the recovered driver contract is documented in
`DRIVER_RE.md`.

Build the two arm64 artifacts without building the ROM:

```sh
platform/exynos990/patches/graphics_allocator_bridge/build.sh
```

The script verifies the ELF machine, required exports, and unresolved runtime
dependencies. The result is placed under `prebuilt/vendor/` inside this
module. Remove `disable` only for a controlled boot test.

The global allocator image registers the allocator rc/VINTF and can be checked
with `monitor_test.sh [iterations]`. The test varies buffer dimensions and
exercises allocate/import/lock/unlock/free. Keep the HIDL allocator enabled
until the camera adapter removes its direct HIDL dependency; it is not used by
the framework allocator once the AIDL instance is visible.

The allocator service is registered in the target image. Android 17 framework
clients resolve `IAllocator/default` and the Stable-C suffix, while
`EXYNOS990_AIDL_GRAPHICS=0` remains the explicit rollback mode. Do not set
`EXYNOS990_DISABLE_HIDL_ALLOCATOR=1` until the camera adapter is installed;
`camera.exynos990.so` still links against the HIDL allocator/mapper ABI.
Registering AIDL together with the Stable-C mapper makes `GraphicBufferMapper`
select the compatibility mapper process-wide. The YUV
lock path obtains the base Y pointer from the native driver's `LOCK_FLEX`
result and returns it through the Stable-C `void**` contract. Plane offsets,
chroma stride and pixel stride are supplied separately through
`PLANE_LAYOUTS`; writing an `android_ycbcr` struct into `void**` would corrupt
the caller's stack. The Composer3 contract also opens
`mapper.exynos990_compat.so` directly.

Before attempting definitive HIDL removal, run
`audit_hidl_retirement.sh [work_dir]`. It distinguishes a real unresolved
HIDL `getService()` call from a type-only `DT_NEEDED` edge. The build refuses
`EXYNOS990_DISABLE_HIDL_ALLOCATOR=1` while a direct caller remains, so a
partial removal cannot leave the camera or framework without its provider.
The current y2s result is recorded in
`HIDL_AIDL_DRIVER_AUDIT_20261024.md` and in the dated audit log under
`out/target/y2s/`.

The mapper uses the platform `libc++.so`; the bridge does not replace or add a
vendor-wide C++ runtime.

The mapper and allocator share
`prebuilt/vendor/lib64/libexynos990_graphics_compat.so`. This umbrella owns
the Gralloc1 callback table and opens the original `gralloc.exynos990.so`
through `hw_get_module`; it does not contain S26+ blobs or replacement
implementations of `libc`, Binder or `libhardware`. The Stable-C mapper remains
a thin public entrypoint under `lib64/hw/`, and the allocator remains a
separate init service, both linked against the same umbrella. The umbrella
uses only the normal Android platform libraries; the allocator additionally
needs `libbinder_ndk.so` for its Binder process.

The build also produces
`prebuilt/test/libGrallocMapperCamera.compat.so`. It keeps the original
`libGrallocMapperCamera.so` SONAME and exports the three exact C++ symbols
requested by `libexynoscamera3.so` (`lock`, YCbCr `lock` and `unlock`). Its
methods delegate to the same Gralloc1 backend and translate flex planes to
the HIDL `YCbCrLayout`. It remains under `prebuilt/test/` until preview,
capture, video, RAW, fences and protected buffers are exercised on the phone;
the production module continues to install the vendor mapper unchanged.

The Stable-C surface is now complete for the metadata that can be represented
without changing the 2020 native handle. `flushLockedBuffer` and
`rereadLockedBuffer` validate the lock state and issue the standard DMA-BUF
cache barrier when the kernel exposes it. The standard metadata list includes
all required getters, including format, allocation size, protection, plane
layout, crop and stride. Dataspace, blend mode and the two static HDR metadata
types are settable and are propagated between imports that refer to the same
backing store.

The legacy backend contains a conservative y2s modifier decoder and reads
`private_handle_t + 0x48` only after validating version, the 65-field handle,
magic and size. A non-zero high word is accepted only for a low32 value proven
linear; the similarly named exported accessor reads `+0x30`
(`frameworkFormat`) and is used only for diagnostics. Only known low32 AFBC
bits are mapped; unknown/private combinations and non-linear high words return
`UNSUPPORTED` instead of being guessed. The vendor metadata class reads
`+0x50` as `alloc_format`. Dynamic HDR 2094-40/2094-10 payloads are retained
and returned byte-for-byte, but their semantic interpretation remains the
vendor camera/framework responsibility.
Before enabling the module in a production build, repeat the composition test
under longer gameplay and keep the IOVMM net mapping count below the kernel
warning threshold.

The camera SONAME shim was exercised in a clean 24/10/2026 session: preview,
still capture and a 4.4-second H.264/AAC video were saved successfully. It
continues to live under `prebuilt/test/`; RAW-effective capture, protected
buffers and private DRM modifiers are not yet enough to promote it or the
Stable-C mapper to the global vendor path.

## Auditoria em camadas

O estado de cada contrato pode ser conferido sem alterar a imagem:

```sh
platform/exynos990/patches/graphics_allocator_bridge/audit_graphics_stack.sh
```

O relatório fica em `STACK_AUDIT.md`. O mapper Stable-C 5 é agora o caminho
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
DRIVER_CONTRACT_AUDIT_20261024.md. Ela registra dependências ELF, símbolos de
posse e lock, formatos YUV/AFBC, metadata SGR, VINTF, init e SELinux. O S26+
é referência de contrato; seus binários não são compatíveis com o handle
Mali/Gralloc1 do y2s.

A separação específica da câmera está em
`CAMERA_DRIVER_SPLIT.md`. Para verificar que a fachada HIDL, o backend
Gralloc1 do S20+ e o adaptador AIDL continuam independentes, execute:

```sh
platform/exynos990/patches/graphics_allocator_bridge/audit_camera_driver_split.sh
```

Essa auditoria rejeita referências de runtime ao mapper SGR ou ao HAL de
câmera do S26+ dentro do código do y2s. O donor é consultado apenas como
referência de lógica para metadata, planes e fences.

A proposta de consolidar o bridge em uma biblioteca compartilhada nativa está
em UMBRELLA_SHIM_ANALYSIS_20261024.md. Ela pode reunir mapper, metadata e os
adaptadores Gralloc1/HWC2 do y2s. Não deve ser usada para mascarar os
SONAMEs ou os handles SGR do S26+.

Como etapa intermediária, a biblioteca HWC2 pode ser compilada sem build da
ROM:

```sh
platform/exynos990/patches/graphics_allocator_bridge/build_composer_backend.sh
```

O resultado fica em `prebuilt/test/`. `libexynos990_hwc2_backend.so` apenas
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
`prebuilt/test/libexynos990_composer3_contract.so` contra o runtime do y2s. A
implementação de teste consulta o display HWC2 original e encaminha
configuração, nome, resolução, DPI, vsync, orientação, modo de cor, power mode
e habilitação de vsync por uma sessão persistente. O C++ é estático no
artefato, evitando introduzir outra ABI de `libc++` na vendor.

O contrato ainda não é um HAL instalável. O serviço não está na VINTF e o
arquivo `disable` deve continuar presente. O probe e a biblioteca ficam em
`prebuilt/test/` até a conversão ser validada em composição real.
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
`audit_graphics_stack.sh` e continua mantendo o serviço fora da VINTF.

Quando a implementação for testada no aparelho, o módulo instalável separado
fica em `platform/exynos990/patches/composer3_hwc2_bridge`. Ele registra o
serviço AIDL, instala o fragmento VINTF e mantém o Composer HIDL original para
rollback. A compilação do módulo é feita por seu `build.sh`; a auditoria da
pilha também verifica o executável e a biblioteca instaláveis.

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
aparelho identificado por `G985FXXSNHYB1`/`m2s`, a imagem AVB de teste foi
instalada pelo TWRP e a câmera permaneceu aberta sem `SIGSEGV`, `SIGBUS`,
`Gralloc5 lock failed` ou `Function not implemented`. O teste de captura foi
executado com o formato `0x11d` e retornou `unlock` normal; os avisos de
latência do pós-processamento continuam sendo apenas timeout de 10 ms.
