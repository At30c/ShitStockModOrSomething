# Auditoria ampliada dos contratos gráficos

Esta varredura compara os binários originais do Exynos 990/y2s com a vendor
do S26+ (SM-S947B_EUX). O objetivo é descobrir contratos que precisam ser
preservados antes de tornar o allocator AIDL global. Nenhum binário do S26+
foi instalado no y2s durante esta auditoria.

## Amostras verificadas

| Camada | Arquivo | SHA-256 |
| --- | --- | --- |
| Gralloc1/Mali antigo | out/target/y2s/work_dir/vendor/lib64/hw/gralloc.exynos990.so | 1dd0cd1c9d20b224f63f780bfc647f828203e3fb2b5654172aa6d86aed9b70e7 |
| Mapper HIDL antigo | out/target/y2s/work_dir/vendor/lib64/hw/android.hardware.graphics.mapper@2.0-impl-2.1.so | b80b5e191750144137eb1e85b761dd7b4cc144c5f42b04a74810c254f6d4e022 |
| Mapper usado pela câmera | out/target/y2s/work_dir/vendor/lib64/libGrallocMapperCamera.so | 2d4fd0175db7be753a8802bea85e057fd4bb727f5ed255429d78ff860d6eb482 |
| HWC2 antigo | out/target/y2s/work_dir/vendor/lib64/hw/hwcomposer.exynos990.so | a5e643d67fe17d183c8fc4b8e214d73dcbc06f05949b84a444933fd86612ee17 |
| Mapper Stable-C SGR | out/fw/SM-S947B_EUX/vendor/lib64/hw/mapper.stableC-impl-sgr.so | e7e8acdcf18025b0939e6c4cb32189d6d1dd50a43d18c1fd5a0f6017d964eaea |
| Allocator AIDL SGR | out/fw/SM-S947B_EUX/vendor/bin/hw/android.hardware.graphics.allocator-aidl-service-sgr | f6ebbc7cf27e59335f4fce833bcc3a1300d9fda1a3f0581ea3aa7857241eeed3 |
| Composer3 SGR | out/fw/SM-S947B_EUX/vendor/bin/hw/android.hardware.graphics.composer3-service.exynos | 18ee8f19d392d481ca5918fd9094f9023e35a33dae38bb38df1e91bbaeb54d1e |

Os arquivos antigos foram lidos da workdir do y2s; os três últimos foram
lidos diretamente da vendor extraída do S26+. As hashes servem para repetir
a comparação quando uma nova firmware for extraída.

## Contratos do driver antigo

O gralloc.exynos990.so é um ELF ARM64 construído para Android 30 e exporta a
família Gralloc1/Mali: mali_gralloc_allocate,
mali_gralloc_reference_retain/release, mali_gralloc_lock,
mali_gralloc_lock_ycbcr, mali_gralloc_lock_flex_async,
mali_gralloc_unlock e as rotinas de sincronização ION. O contrato de posse
é baseado em native_handle_clone e em uma contagem de referências por
processo; o último release libera ION e destrói o clone.

As strings e símbolos do driver confirmam estes limites:

* formatos YUV compatíveis precisam de LOCK_FLEX; lock_ycbcr é usado para os
  formatos YCbCr específicos;
* buffers AFBC não podem ser convertidos para android_flex_layout;
* região negativa, região maior que a alocação, overflow e handle inválido
  são rejeitados;
* o layout da câmera usa os offsets e strides do private_handle_t Mali, não
  os campos do handle SGR.

O android.hardware.graphics.mapper@2.0-impl-2.1.so antigo é um wrapper
passthrough HIDL que exporta HIDL_FETCH_IMapper e usa
GrallocImportedBufferPool. O libGrallocMapperCamera.so chama os mesmos
callbacks Mali/ION diretamente, além de depender de
android.hardware.graphics.mapper@2.0.so. Isso explica por que mudar o mapper
global altera o caminho de ImageReader da câmera.

O hwcomposer.exynos990.so é um backend HWC2 próprio. Ele exporta as operações
de display, layer, validate/present, client target, readback, configuração
ativa, callbacks, modos de cor, metadados HDR e release fences. Ele depende
de libexynosdisplay.so, libacryl.so, libExynosHWCService.so e libion.so,
portanto o Composer3 precisa chamar esse ABI HWC2; não pode chamar as classes
internas do S26+.

### Tabela de formatos e `internal_format` extraídos do y2s

A extração estática do `gralloc.exynos990.so` confirmou que o próprio y2s
fornece os pontos necessários para uma futura conversão de modifier, sem
copiar valores do S26+:

* `formats` está em `.rodata` no endereço `0x5d60`, com 1.652 bytes;
* `num_formats` está em `0x63d8` e contém `0x3b` (59 entradas);
* `formats_ip_support` começa em `0x63e0` e ocupa 944 bytes;
* `get_internal_format(unsigned int, bool)` percorre as 59 entradas e aplica
  a política de suporte do IP/uso;
* `get_format_ext(unsigned long, unsigned long)` preserva ou desloca os bits
  altos do formato conforme o bit de extensão do uso;
* `mali_gralloc_get_format_internal(native_handle_t*, int*)` é exportado e lê
  `private_handle_t + 0x30`. A auditoria de `libexynosgraphicbuffer.so`
  separou os campos: `+0x30` é `frameworkFormat`, `+0x48` é o
  `internal_format` da metadata Exynos e `+0x50` é `alloc_format` usado por
  `mali_gralloc_lock_flex_async()`. O nome do símbolo não deve ser usado para
  inferir o campo privado sem essa distinção.

Isso permite consultar a função exportada por buffer para diagnóstico, mas ela
retorna `frameworkFormat` nessa versão. O bridge lê o `internal_format` de
`+0x48` por uma rota validada antes de gerar `DRM_FORMAT_MOD_ARM_AFBC(...)`. A
correlação dos bits com o layout AFBC está isolada no decoder y2s e é coberta
por probe; a aceitação em runtime continua condicionada a o próprio gralloc
produzir um handle AFBC. O valor `0` é o único resultado confirmado para as
alocações lineares atuais. O formato privado de câmera `0x11d` não deve
receber um modifier DRM inventado.

### Validação do decoder de modifier no y2s (24/10/2026)

O decoder foi implementado em `include/exynos990/y2s_modifier.h` e é usado
somente depois de `mali_gralloc_get_format_internal()`. Ele aceita apenas os
bits AFBC observados na representação de 32 bits do y2s; combinações
desconhecidas retornam erro Stable-C em vez de serem anunciadas ao HWC.
Também foi adicionado `prebuilts/exynos990/graphics_allocator_bridge/test/y2s_modifier_probe`, que executou no
aparelho e passou nos casos linear, AFBC básico RGB/YUV, split+wide+tiled e
nas rejeições de bits inválidos.

O teste contra o gralloc original do aparelho (`internal_format_probe`) deu
valores para o accessor exportado (que lê `frameworkFormat` em `+0x30`), não
para o `internal_format` de `+0x48`:

* `mali_gralloc_select_format()` selecionou
  `0x0000000100000001` (AFBC básico em sua representação de 64 bits);
* o handle RGBA realmente alocado retornou `frameworkFormat=0x00000001`;
* o handle YUV da câmera retornou `frameworkFormat=0x00000023`;
* pedidos com os wrappers AFBC foram recusados pelo allocator (`error=5`).

Por fim, `mapper_modifier_probe` importou um handle RGBA real pelo mapper
Stable-C e obteve `DRM_FORMAT_MOD_LINEAR` (`0x0`), com `freeBuffer()` e o
release Gralloc1 concluindo sem erro. Isso valida a posse/importação e o
resultado linear daquele teste. O caminho atualizado lê e valida `+0x48`
diretamente (versão, `numFds + numInts == 65`, magic, tamanho e high-word); ainda assim, isso não
valida AFBC em runtime. O bridge não deve forçar AFBC nem substituir o mapper
global por causa desse probe.

Hashes dos artefatos compilados contra as bibliotecas do próprio y2s:

| Artefato | SHA-256 |
| --- | --- |
| `libexynos990_graphics_compat.so` | `5fa564c68d7fede2e81995132b9392aab6beb7b6d86e301c76109ff9c796dd12` |
| `mapper.exynos990_compat.so` | `b9c43c56875583b06043c26c46d8908f9e8f3000131075e70ce090a98d1f09fa` |
| `android.hardware.graphics.allocator-V2-service.exynos990` | `c2c53e24ab98331de7acd25ad9fa7fe380d6e249588adf79dcf3d692895c2b13` |
| `y2s_modifier_probe` | `ca721d73126101e4e448c917302e81db0331b6dadc1f982f4cd451d47137dacc` |
| `mapper_modifier_probe` | `b79b6160f4cb024557ea33c8319357232ff1fde750945bc625ff7e8515bd5d1a` |

## Contratos observados no S26+

O mapper.stableC-impl-sgr.so é um ELF ARM64 construído para Android 36. Ele
exporta AIMapper_loadIMapper e ANDROID_HAL_MAPPER_VERSION, mas o handle é
SGR. Os símbolos encontrados incluem:

* MetadataManager para dimensões, layer count, uso, formato solicitado,
  FourCC, modifier, tamanho, proteção, crop, dataspace, blend mode,
  PLANE_LAYOUTS, compressão, interlaced, chroma siting e HDR;
* CameraFormatManager, CpuFormatManager, VideoFormatManager,
  HwcFormatManager, LinearLayoutManager, SbwcLayoutManager e
  DccLayoutManager;
* ExynosIonMemoryManager para alloc/import/map/unmap e
  sync_start/sync_end/sync_partial;
* validate_buffer_size, validate_lock_input_parameters,
  flush_locked_buffer, reread_locked_buffer, lock/unlock e os acessores
  sgr_intf_get_* do handle privado.

O allocator AIDL SGR depende diretamente de mapper.stableC-impl-sgr.so,
libeis_utils.so, libgralloctypes.so,
android.hardware.graphics.allocator-V2-ndk.so e libbinder_ndk.so. O target
y2s não possui libeis_utils.so nem o mapper SGR. Portanto, copiar o executável
ou apenas renomear o mapper produziria falha de linker e, se o linker fosse
contornado, um handle incompatível.

O Composer3 SGR depende também de
vendor.samsung_slsi.hardware.graphics.extension.composer3-V5-ndk.so,
libbinder.so, libbinder_ndk.so, libjsoncpp.so, libprocessgroup.so,
libexynosdisplay.so e libExynosHWCService.so. Além das dependências, suas
referências indefinidas chamam ExynosDevice, ExynosDisplay, ExynosLayer e as
extensões de Composer do S26+. Essas classes não são a ABI do
hwcomposer.exynos990.so.

## VINTF, init e SELinux

O y2s continua declarando:

* allocator HIDL 2.0 em @2.0::IAllocator/default;
* Composer HIDL 2.3 em @2.3::IComposer/default;
* mapper HIDL 2.1 passthrough.

O donor S26+ declara allocator AIDL
android.hardware.graphics.allocator.IAllocator/default, mapper nativo
@5.0/stableC-impl-sgr e Composer3 AIDL IComposer/default. Seus serviços init
 têm domínios, grupos e task_profiles próprios. O S26+ também rotula o mapper
SGR como same_process_hal_file, o serviço do allocator como
hal_graphics_allocator_default_exec e publica mapper/stableC-impl-sgr como
hal_graphics_mapper_service.

No target, o rótulo estático de mapper.exynos990_compat.so aparece em
out/target/y2s/work_dir/configs/file_context-vendor e o
vendor_file_contexts runtime também contém a entrada após a aplicação
completa dos módulos. Embora o mapper seja um passthrough Stable-C carregado
como biblioteca, o framework consulta o nome declarado
`mapper/exynos990_compat` no servicemanager. Por isso ele também precisa de
`mapper/exynos990_compat u:object_r:hal_graphics_mapper_service:s0` em
`vendor_service_contexts`; sem essa linha o nome cai em
`default_android_service` e o SELinux nega o `find` do SurfaceFlinger. O
service_context AIDL do allocator só deve entrar quando o modo global for
explicitamente ativado.

## Conclusão de compatibilidade

O donor S26+ é útil como mapa de contrato Stable-C/AIDL, metadata, fences,
layouts e política VINTF/SELinux. Ele não é um donor binário para o y2s:

1. o layout de native_handle_t, os formatos e os offsets do y2s são
   Mali/Gralloc1;
2. SGR espera managers, metadata e modificadores SBWC/DCC que não existem no
   Gralloc1 do Exynos 990;
3. os serviços S26+ têm dependências e símbolos privados diferentes;
4. trocar o backend global antes de migrar câmera, MediaCodec, ImageReader,
   buffers protegidos e fences causaria exatamente os crashes de imagem verde,
   planos YUV nulos ou tela preta observados anteriormente.

O bridge atual deve continuar encaminhando execução para o Gralloc1/HWC2
original. A próxima etapa segura é preencher os testes de isSupported(),
formatos YUV/RAW, protected buffers, fences e metadata usando os contratos
observados, e só então fazer uma build experimental com
EXYNOS990_AIDL_GRAPHICS=1. O padrão permanece EXYNOS990_AIDL_GRAPHICS=0,
com o allocator HIDL global e o mapper Stable-C privado do Composer3.

## Repetição da varredura

As verificações ELF foram feitas com file, readelf -d,
readelf -Ws --dyn-syms, strings -a e sha256sum. A auditoria da pilha
instalada continua disponível em:

    platform/exynos990/patches/graphics_allocator_bridge/audit_graphics_stack.sh

Esta análise é somente leitura; ela não altera a workdir nem inicia uma nova
build.

## Possibilidade de substituir o mapper da câmera (24/10/2026)

O `libGrallocMapperCamera.so` original chama diretamente as rotinas Mali/ION
exportadas pelo `gralloc.exynos990.so`; portanto o shim precisa manter o
SONAME, a classe C++ e o `private_handle_t` original. A primeira tentativa,
que usava callbacks Gralloc1 separados, foi rejeitada no aparelho porque
alterava o `usage` combinado e gerava `REQUEST ERROR`.

O adaptador em `prebuilts/exynos990/graphics_allocator_bridge/test/libGrallocMapperCamera.compat.so` agora resolve
no módulo já carregado os símbolos `mali_gralloc_lock_async`,
`mali_gralloc_get_num_flex_planes`, `mali_gralloc_lock_flex_async` e
`mali_gralloc_unlock`, exatamente como o mapper stock. A auditoria ABI contra
`libexynoscamera3.so` confirma os três símbolos C++ requeridos. No aparelho,
preview e captura still funcionaram com o shim; o modo vídeo iniciou
`MediaWriter`/`VideoStabilizer` sem erro fatal, mas a persistência do MP4 ainda
precisa de uma sessão manual. `dumpsys media.camera` anuncia RAW e
`PRIVATE_REPROCESSING`; `NonBlockingImageReader` e fences `FenceTime` foram
observados sem crash. Buffers protegidos ainda não foram exercitados.

O shim permanece separado do prebuilt de produção e do allocator AIDL global.
`EXYNOS990_AIDL_GRAPHICS=0` continua sendo o padrão até terminar os testes de
vídeo persistente, RAW efetivo, ImageReader e protected buffers.

### Revalidação em sessão limpa (24/10/2026)

Depois de reiniciar o `m2s`/`G985FXXSNHYB1`, o módulo temporário foi montado
novamente pelo KernelSU e os artefatos ativos foram conferidos:

* `libGrallocMapperCamera.so`: SHA-256
  `4df052b12b426149caa7f1fff871706c789c19c4ee32a056eb055f81828fda43`;
* `libexynos990_graphics_compat.so`: SHA-256
  `6fbe0dfefc788ba31daf88ea8a540669917ac114260021a1eb3f874b6dbc54cf`.

O preview frontal exibiu imagem real, uma foto foi salva como
`20261024_192820.jpg` (1.230.267 bytes) e uma sessão de vídeo de
aproximadamente 4,4 s foi finalizada em `20261024_192927.mp4` (9.488.610
bytes). O log confirmou `MPEG4Writer` com trilhas H.264 e AAC, além do
`VideoStabilizer`, sem `CANNOT LINK`, `SIGSEGV` ou `SIGBUS`. Os dois
`RESULT ERROR` registrados logo após a abertura ocorreram na recuperação do
primeiro stream, antes da captura; não impediram a foto nem o vídeo seguintes.

Ainda não considero validados, portanto não promovo o shim a vendor global:
captura RAW efetiva (a capacidade apenas aparece no metadata), buffers
protegidos e o mapeamento de modificadores DRM privados. O allocator AIDL
global continua desligado.

Na metadata Stable-C, `NAME` deriva do `backingStore` e HDR dinâmico 2094-40/
2094-10 é armazenado e devolvido como bytes. O modificador DRM continua zero
quando o Gralloc1 não expõe um valor verificável; não se usa um valor SGR ou
AFBC do S26+ como substituto.
