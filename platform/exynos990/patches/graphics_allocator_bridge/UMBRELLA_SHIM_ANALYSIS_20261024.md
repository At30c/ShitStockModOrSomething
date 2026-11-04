# Umbrella shim para a pilha gráfica

## O que a ideia resolve

É possível criar uma biblioteca única, específica do Exynos 990, que reúna
o código do mapper Stable-C compatível, o cache de metadata e os adaptadores
para Gralloc1/HWC2. Essa biblioteca pode ser usada pelo nosso serviço AIDL e
pelo Composer3 privado, reduzindo duplicação entre os componentes do bridge.
Ela continuará chamando o gralloc.exynos990.so original por hw_get_module e
não substituirá o layout de native_handle_t do Mali.

Esse é o formato seguro do “amuleto”: uma camada de compatibilidade criada
para o y2s, com símbolos e contratos que controlamos no código-fonte.

## O que um único .so não resolve

O linker Android resolve cada entrada DT_NEEDED pelo nome/SONAME declarado.
Um arquivo chamado libexynos990_graphics_compat.so não satisfaz
automaticamente libeis_utils.so, libgralloctypes.so,
mapper.stableC-impl-sgr.so e as demais entradas do S26+. Symlinks também não
transformam a ABI: o SONAME interno e os símbolos ainda precisam existir no
namespace do processo.

Para forçar o donor S26+ a carregar uma única biblioteca seria necessário:

1. editar o DT_NEEDED de cada executável e biblioteca;
2. exportar todos os símbolos esperados pelos nomes C++ exatos;
3. reimplementar os contratos de SGR, metadata, formatos e layouts;
4. reproduzir a ABI de Composer do S26+, incluindo as classes ExynosDevice,
   ExynosDisplay e ExynosLayer;
5. garantir que o handle recebido pelo SGR seja o mesmo handle que o kernel
   Mali/Exynos 990 entende.

As varreduras encontraram 61 símbolos indefinidos no mapper S26+, 77 no
allocator e 172 no Composer3. O Composer3 contém 63 referências diretas a
classes privadas ExynosDevice/ExynosDisplay/ExynosLayer. Não há código-fonte
dessas implementações na árvore; um shim que apenas retorne zero ou
EX_UNSUPPORTED faria o SurfaceFlinger perder composição, fences e buffers.

Além disso, o mapper S26+ implementa SGR com Camera/CPU/Video/HWC/SBWC/DCC
FormatManager e MetadataManager próprios. O y2s usa private_handle_t Mali,
AFBC, ION e LOCK_FLEX. Fazer esses contratos parecerem iguais somente pelo
linker causaria buffers verdes, planos YUV nulos, tela preta ou corrupção.

## Forma recomendada

O bridge deve ser reorganizado em três peças:

* libexynos990_graphics_compat.so: implementação compartilhada do mapper,
  metadata e chamadas Gralloc1/HWC2;
* mapper.exynos990_compat.so: pequeno carregador Stable-C que exporta
  AIMapper_loadIMapper e encaminha para a biblioteca compartilhada;
* android.hardware.graphics.allocator-V2-service.exynos990: serviço Binder
  fino que usa a mesma biblioteca, mas continua sendo um executável separado
  porque o init precisa iniciar um processo de serviço.

O umbrella ainda terá dependências normais do Android, como libhardware,
libcutils, liblog, libdl e libbinder_ndk no processo do allocator. Essas
bibliotecas são APIs de sistema e não são “drivers donor”; tentar incorporá-las
em um blob privado quebraria namespaces, atualizações e SELinux.

Esse desenho preserva o caminho global HIDL da câmera enquanto o mapper
Stable-C continua privado do Composer3. Depois de testar câmera, ImageReader,
MediaCodec, buffers protegidos, fences, suspensão/retomada e jogos, o
allocator AIDL poderá ser ativado globalmente com uma única implementação
compartilhada do y2s. A flag padrão continua
EXYNOS990_AIDL_GRAPHICS=0.

## Dependências verificadas do bridge atual

O inventário ELF dos artefatos compilados confirma que o bridge não carrega
blobs do S26+ nem bibliotecas proprietárias adicionais. O mapper
`mapper.exynos990_compat.so` depende somente de `libhardware.so`,
`libcutils.so`, `liblog.so`, `libdl.so`, `libm.so` e `libc.so`. O serviço
allocator acrescenta apenas `libbinder_ndk.so`, porque é um processo Binder
iniciado pelo `init`.

Essas bibliotecas devem continuar sendo fornecidas pelo Android. Elas são a
ABI de plataforma usada para `hw_get_module`, logging, carregamento dinâmico,
memória e Binder; copiá-las para um `.so` privado criaria uma segunda libc ou
Binder no namespace da vendor e quebraria SELinux, atualização e estabilidade
de ABI.

O que pode ser consolidado no umbrella é o código que controlamos: validação
de `native_handle_t`, posse/import/release, cache e conversão de metadata,
layouts YUV, fences e os adaptadores para Gralloc1/HWC2. O umbrella continua
abrindo o `gralloc.exynos990.so` e o `hwcomposer.exynos990.so` originais em
tempo de execução. Assim, as dependências do driver original permanecem no
próprio vendor do y2s, enquanto nossas dependências compartilhadas deixam de
ser duplicadas entre mapper, allocator e Composer.

O front-end Stable-C ainda precisa existir com o símbolo
`AIMapper_loadIMapper`, e o allocator ainda precisa ser um executável separado
para o `init` iniciar o processo. Ambos podem ligar contra o mesmo
`libexynos990_graphics_compat.so`; um único `.so` não substitui esses dois
entrypoints nem transforma o backend HIDL em AIDL por renomeação.

O mesmo umbrella já possui um adaptador experimental para a câmera em
`prebuilts/exynos990/graphics_allocator_bridge/test/libGrallocMapperCamera.compat.so`. Ele preserva o SONAME
`libGrallocMapperCamera.so` e os três símbolos que `libexynoscamera3.so`
referencia, encaminhando lock/unlock e YCbCr para o Gralloc1 original. O
artefato fica separado do `prebuilts/exynos990/graphics_allocator_bridge/vendor` até a validação no aparelho.

## Conclusão

Sim, podemos criar um único .so como umbrella do bridge nativo do Exynos 990.
Não é seguro usar um único .so para fingir que os binários SGR do S26+ são
compatíveis. A refatoração controlada foi aplicada: o mapper Stable-C e o
allocator AIDL compartilham a tabela de callbacks Gralloc1 em
`libexynos990_graphics_compat.so`, enquanto seus entrypoints continuam
separados. A biblioteca foi compilada contra o system y2s e permanece atrás
do modo privado do bridge até os testes no aparelho.
