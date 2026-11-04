# Auditoria dos binários do Composer do Exynos 990

Auditoria realizada em **22/10/2026** sobre os artefatos do
`out/target/y2s/work_dir`. O objetivo foi descobrir, pela interface ELF e
pelas strings dos binários, onde a resolução física é controlada e qual parte
do bridge pode ser aproveitada sem trocar o gralloc ou o mapper Mali.

## Amostras e integridade

| Arquivo | Função identificada | SHA-256 |
| --- | --- | --- |
| `vendor/bin/hw/android.hardware.graphics.composer3-service.exynos990` | Serviço AIDL Composer3 candidato | `eb0c45a88f31e3d295830077ed351c6be0c4de0418491cea10bd4674ed58c494` |
| `vendor/lib64/libexynos990_composer3_contract.so` | Contrato Composer3 e adaptador HWC2 | `397f9dac4bd396082d3e8ec050dabbb6f8ee22b9363b23948270a24e64660a7d` |
| `vendor/lib64/hw/hwcomposer.exynos990.so` | Composer HIDL/HWC2 proprietário | `a5e643d67fe17d183c8fc4b8e214d73dcbc06f05949b84a444933fd86612ee17` |
| `vendor/lib64/libexynosdisplay.so` | Objetos ExynosDisplay e interface do painel | `e5f9f143e20b66408a8df179df88346fab4f0c1692918ab6096e71e562600a2b` |
| `vendor/lib64/hw/gralloc.exynos990.so` | Gralloc1 Mali/ION | `1dd0cd1c9d20b224f63f780bfc647f828203e3fb2b5654172aa6d86aed9b70e7` |
| `vendor/lib64/hw/mapper.exynos990_compat.so` | Mapper Stable-C privado do bridge | `c321bab54e24fdbed9bd9f966ec729c12c6a977f3ab34b24eef21945576a99ab` |

O serviço Composer3 e o contrato usam ABI ARM64. O serviço depende de
`libexynos990_composer3_contract.so`; o contrato depende do runtime
`android.hardware.graphics.composer3-V5-ndk.so`, `libbinder_ndk.so`,
`libhardware.so`, `libcutils.so` e `libexynosdisplay.so`.

## O que o HWC2 proprietário já oferece

`hwcomposer.exynos990.so` exporta os callbacks necessários para a troca de
modo:

- `exynos_getDisplayConfigs`;
- `exynos_getDisplayAttribute`;
- `exynos_getActiveConfig`;
- `exynos_setActiveConfig`;
- `exynos_SetActiveConfigWithConstraints`;
- `exynos_getDisplayVsyncPeriod`;
- registro de hotplug, refresh e vsync;
- `validateDisplay`, `acceptDisplayChanges` e `presentDisplay`;
- fences de aquisição, apresentação e liberação.

`libexynosdisplay.so` confirma a mesma cadeia em símbolos C++:

- `ExynosDisplay::getDisplayConfigs()`;
- `ExynosDisplay::getDisplayAttribute()`;
- `ExynosDisplay::getActiveConfig()`;
- `ExynosDisplay::setActiveConfig()`;
- `ExynosDisplay::setActiveConfigWithConstraints()`;
- `ExynosDisplay::setDisplayVsyncPeriod()`;
- `ExynosPrimaryDisplayFbInterface::setScaledResolution()`;
- `ExynosDisplayFbInterface::setActiveConfig()`.

As strings também revelam os caminhos usados pelo driver:

- `EXYNOS_GET_DISPLAY_MODE` e `EXYNOS_GET_DISPLAY_MODE_NUM`;
- `HWC_CTL_DDI_RESOLUTION_CHANGE`;
- `HWC_CTL_DISPLAY_MODE`;
- `PANEL_IOC_SET_DISPLAY_MODE`;
- nós de `decon_f`, `decon_s`, `decon_t` e `vsync`.

Isso confirma que a troca física deve passar pelo HWC2/`ExynosDisplay` e
terminar no ioctl do painel. Gralloc, mapper e Vulkan não são responsáveis por
enumerar ou selecionar as resoluções do painel.

## O que o bridge atual já faz

O contrato compilado exporta a sessão HWC2 necessária, incluindo:

`get_display_configs`, `get_display_attribute`, `set_active_config`,
`set_active_config_with_constraints`, criação/destruição de layers,
`validate`, `present`, callbacks de hotplug/vsync e fences de release.

Ao selecionar uma configuração, o bridge chama o `setActiveConfig` do HWC2 e
depois tenta sincronizar o painel com `setScaledResolution` e
`ExynosDisplayFbInterface::setActiveConfig`. Essa é a direção correta para
eliminar a síntese de modos no `SecSettings`.

## Limitação crítica encontrada

O caminho atual de sincronização do bridge recupera objetos internos do
Composer por offsets privados:

- `ExynosDevice` a partir de `hwc2_device + 0x88`;
- `ExynosDisplay` por `getDisplay(0)`;
- `ExynosDisplayFbInterface` a partir de `ExynosDisplay + 0x3cd0`.

Esses offsets não fazem parte de uma ABI pública. Eles podem mudar com outra
versão de `hwcomposer.exynos990.so` e causar corrupção, tela preta ou bootloop.
A presença dos símbolos não prova que esses offsets continuem válidos em todos
os firmwares.

Por isso, esse bridge deve permanecer experimental. A implementação definitiva
deve preferir, nesta ordem:

1. usar somente os callbacks HWC2 públicos para obter e ativar configurações;
2. localizar uma API exportada de `ExynosPrimaryDisplayFbInterface` que aceite
   a troca física sem acessar offsets privados;
3. somente se não houver API pública, criar um shim específico para o hash
   exato do `hwcomposer.exynos990.so`, com verificação de versão e rollback.

## Estado da auditoria

`audit_graphics_stack.sh` terminou com **0 falhas e 2 avisos**. Os avisos são
esperados: o Composer3 AIDL ainda não está registrado no VINTF do sistema em
execução e faltam validação de lifecycle em lote e comandos avançados no
aparelho. A auditoria foi feita com o aparelho desconectado; portanto, ela
valida o contrato ELF e o fluxo de código, mas não substitui o teste de
SurfaceFlinger em execução.

O teste anterior do `SecSettings` já demonstrou que o painel aceita
`720x1600`, `1080x2400` e `1440x3200`. O próximo teste seguro é fazer o bridge
apenas consultar as configurações HWC2 e registrar os IDs, sem registrar uma
instância AIDL nem alterar o Composer ativo. Depois disso, podemos comparar o
ID HWC2 com o modo físico observado no kernel e remover gradualmente o fallback
do Settings.

## Comparação com o Composer do S26+

O S26+ foi usado como base de interface, mas os binários não são do mesmo
backend.

| Item | y2s / Exynos 990 | S26+ / base donor |
| --- | --- | --- |
| Serviço | bridge experimental de 5,9 KiB | `composer3-service.exynos` de 238 KiB |
| Interface | HWC2 proprietário, exposto pelo serviço HIDL 2.3 | Composer3 AIDL V4 nativo |
| VINTF | Composer HIDL ativo; AIDL ainda experimental | `android.hardware.graphics.composer3.IComposer/default`, versão 4 |
| Backend | `hwcomposer.exynos990.so` + `libexynosdisplay.so` | Composer3 Samsung integrado ao `libexynosdisplay.so` |
| Mapper | Gralloc1 Mali/ION e mapper compatível privado | `mapper.stableC-impl-sgr.so` / Mapper 4.0 SGR |
| Runtime Composer | V5 do sistema usado pelo bridge | V4 vendor + extensão Samsung Composer3 V5 |
| GPU/metadata | formatos Mali, AFBC e `private_handle_t` | SGR/Stable-C, metadata privada e backend de GPU diferente |

O serviço do S26+ depende, entre outros, de
`vendor.samsung_slsi.hardware.graphics.extension.composer3-V5-ndk.so`,
`libjsoncpp.so`, `libprocessgroup.so`, `libdrm.so`, `libdrmresource.so`,
`libdisplaycolor_default.so` e `libdisplaycolorwrapper.so`. Essas dependências
não existem no mesmo contrato do Exynos 990 e não devem ser copiadas para a
vendor do y2s.

### O que pode ser reutilizado do S26+

O que é útil como referência é o desenho do contrato:

- `getDisplayConfigurations` e `getDisplayAttribute` vêm do mesmo modelo
  Composer3;
- `setActiveConfig` e `setActiveConfigWithConstraints` são os pontos de
  entrada para o modo físico;
- `registerCallback`, hotplug, refresh e vsync seguem o ciclo Composer3;
- `validate`, `present` e release fences permanecem no Composer, enquanto o
  mapper só cuida dos buffers;
- `setBootDisplayConfig`, `setFrameIntervalNs` e callbacks de mudança de
  refresh mostram como uma implementação completa mantém o modo lógico e o
  modo físico sincronizados.

### O que não pode ser transplantado

O `composer3-service.exynos` do S26+ não deve substituir o serviço do y2s. Ele
usa `ExynosDevice`/`ExynosDisplay` próprios, `GraphicBufferMapper` SGR e
metadata que o Gralloc1 Mali do Exynos 990 não fornece. O mesmo vale para o
`mapper.stableC-impl-sgr.so`: a API Binder é parecida, mas o layout do handle,
modificadores, alinhamento, cache e fences são diferentes.

O bridge correto para o y2s deve copiar apenas o fluxo de controle do S26+ e
continuar encaminhando buffers ao `hwcomposer.exynos990.so`. A parte de
resolução deve ser implementada sobre os IDs retornados pelo HWC2 original,
com uma tabela de validação para `720x1600`, `1080x2400` e `1440x3200`, em vez
de importar tabelas de modos do S26+.

O bridge recebeu um ajuste compatível com esse modelo: quando o HWC2 não
fornece `HWC2_ATTRIBUTE_CONFIG_GROUP`, os modos passam a ser agrupados pela
mesma largura e altura. Assim, as variantes de 48/60/96/120 Hz de uma mesma
resolução compartilham o grupo, como no Composer3 do S26+, sem inventar IDs ou
copiar a tabela de modos de outro aparelho.

O contrato foi recompilado e propagado para o módulo instalável. O artefato
atual `composer3_hwc2_bridge/prebuilt/vendor/lib64/libexynos990_composer3_contract.so`
tem SHA-256
`ab027df0d035a9707daa5a5a50f6f982fb611d0fa477c6308789d216881cac45`.

### Conclusão da comparação

O S26+ confirma que a solução final deve estar no Composer, mas também mostra
por que não podemos portar o binário diretamente. A base segura é:

1. manter Gralloc1/Mali e `hwcomposer.exynos990.so` do y2s;
2. usar o S26+ somente para o desenho de chamadas Composer3 e callbacks;
3. substituir os offsets privados do bridge por uma API HWC2/exportada ou por
   um adaptador versionado para o hash exato do backend;
4. validar no aparelho a troca de modo, FOD, câmera, suspensão e fences antes
   de registrar o Composer3 no VINTF.

## Situação da câmera e migração completa para AIDL/HWC3

A correção atual da câmera não substituiu o caminho gráfico dela. O vendor
continua usando:

- Gralloc1 Mali original;
- allocator HIDL legado;
- mapper HIDL 2.1/passthrough;
- Composer HIDL/HWC2 original para o caminho em produção.

O mapper Stable-C compatível é carregado somente pelo bridge Composer3. Ele não
é registrado no VINTF global e não substitui o mapper que a câmera obtém pelo
`GraphicBufferMapper`. Essa separação foi necessária porque a câmera espera o
`private_handle_t`, layouts YUV e metadata do Gralloc1; o mapper SGR do S26+
produz outro layout e deixou os planos de `ImageReader` inválidos durante os
testes.

Portanto, o estado atual é uma ponte Composer3 sobre o backend HWC2, e não uma
migração completa para AIDL. Para remover definitivamente o HIDL e chegar ao
HWC3, a sequência precisa ser:

1. portar `getDisplayConfigurations`, atributos, grupos, modos ativos,
   callbacks de hotplug/refresh/vsync, `validate`, `present` e fences para
   Composer3;
2. implementar allocator AIDL e Mapper Stable-C que preservem os handles
   Mali/ION do Exynos 990, sem importar o mapper SGR do S26+;
3. manter compatíveis `lock`, `unlock`, `flush`, `reread`, layouts de planos
   YUV, stride, crop, proteção e metadata usados pela câmera;
4. registrar as interfaces AIDL no VINTF, init e SELinux somente depois que
   SurfaceFlinger, câmera, vídeo e FOD usarem o mesmo contrato sem fallback;
5. retirar o Composer HIDL e o mapper HIDL apenas após validar dois ciclos de
   boot, suspensão/retomada, troca de resolução e captura de fotos/vídeos.

O Composer3/HWC3 pode substituir o serviço HIDL antes da migração do mapper,
mas a câmera ainda dependerá do allocator/mapper legado nesse estágio. Remover
os três componentes ao mesmo tempo, usando os binários SGR do S26+, não é uma
conversão de interface: mudaria o layout dos buffers e reintroduziria o crash
da câmera. O objetivo final é AIDL completo, mas o bridge atual ainda não deve
desativar o HIDL até essa segunda parte estar implementada e testada.
