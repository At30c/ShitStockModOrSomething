# Auditoria HIDL/AIDL de allocator e mapper gráficos

Data: 24/10/2026  
Target analisado: y2s/m2s, bootloader `G985FXXSNHYB1`  
Doador usado somente para estudo: `out/fw/SM-S947B_EUX` (S26+)

Este relatório separa três coisas que não devem ser confundidas:

1. o serviço Binder/HAL que publica uma interface HIDL ou AIDL;
2. as bibliotecas de tipos e ABI que um cliente ainda pode carregar;
3. o backend físico Mali/Gralloc1 que aloca os DMA-BUFs do Exynos 990.

O objetivo da migração é retirar os serviços e clientes gráficos HIDL. Isso
não autoriza apagar `gralloc.exynos990.so`, `libion_exynos.so` ou o layout
proprietário dos handles: o allocator AIDL atual ainda usa esse backend.

## 1. Evidência de runtime no y2s

Após a `vendor` assinada com o allocator AIDL, os serviços encontrados foram:

```text
android.hardware.graphics.allocator.IAllocator/default       AIDL (encontrado)
android.hardware.graphics.composer3.IComposer/default        AIDL (encontrado)
android.hardware.graphics.allocator@2.0::IAllocator/default  HIDL (PID 7041)
android.hidl.allocator@1.0::IAllocator/ashmem                HIDL genérico (PID 7023)
android.hardware.graphics.mapper@2.1::IMapper/default        HIDL passthrough
```

`lshal` mostrou o mapper HIDL passthrough carregado pelos seguintes processos
durante a sessão: `surfaceflinger` (PID 7117),
`vendor.samsung.hardware.camera.provider@4.0-service_64` (7078),
`cameraserver` (7269), `mediaswcodec` (7310), `system_server` (7585),
SystemUI, Launcher, Settings, Camera e outros processos de interface.

Isso não significa que todos esses processos estejam usando a mesma operação
de alocação em cada frame; significa que o `IMapper@2.1` HIDL passthrough está
disponível/carregado no namespace deles. A remoção só é segura quando uma
auditoria posterior não mostrar mais nenhum cliente.

O `android.hidl.allocator@1.0::IAllocator/ashmem` é o allocator HIDL genérico
de ashmem. Ele não é o allocator de buffers gráficos e não deve ser removido
como parte desta migração.

## 2. y2s: allocator HIDL 2.0

Arquivos da imagem original extraída de `super`:

| Arquivo | Tamanho | SHA-256 | Papel |
|---|---:|---|---|
| `vendor/bin/hw/android.hardware.graphics.allocator@2.0-service` | 11.656 | `1478e8fac0d4b91c33fa896caf877589a1145e2c5e49a53eae647819c17cb3ed` | executável HIDL |
| `vendor/lib64/hw/android.hardware.graphics.allocator@2.0-impl.so` | 20.976 | `ecad7a19c30e2c3bbd9f888f867486a00de758af1149b8f92dec83e52bda8d32` | implementação passthrough |
| `vendor/lib64/hw/gralloc.exynos990.so` | 80.024 | `1dd0cd1c9d20b224f63f780bfc647f828203e3fb2b5654172aa6d86aed9b70e7` | backend Gralloc1/Mali |

O tamanho do executável é reportado pelo dump como ELF; a extração preserva o
arquivo original. O serviço tem `BuildID e7361472ac90bc8306423ea11f89d2d9`
e é marcado como Android 30.

### Dependências ELF

`android.hardware.graphics.allocator@2.0-service`:

```text
android.hardware.graphics.allocator@2.0.so
libhidlbase.so liblog.so libutils.so libc++.so libc.so libm.so libdl.so
```

`android.hardware.graphics.allocator@2.0-impl.so`:

```text
android.hardware.graphics.allocator@2.0.so
libbase.so libcutils.so libhardware.so libhidlbase.so liblog.so libutils.so
libc++.so libc.so libm.so libdl.so
```

O impl não possui `DT_NEEDED` direto para `gralloc.exynos990.so`; ele usa
`libhardware`/`hw_get_module` e procura dinamicamente um módulo `gralloc`.
Strings relevantes confirmam `HIDL_FETCH_IAllocator`, `AllocatorHal`,
`failed to open gralloc1 device` e `failed to get gralloc1 function`.

### Init e VINTF

`vendor/etc/init/android.hardware.graphics.allocator@2.0-service.rc` inicia:

```text
service vendor.gralloc-2-0 /vendor/bin/hw/android.hardware.graphics.allocator@2.0-service
    interface android.hardware.graphics.allocator@2.0::IAllocator default
    class hal animation
    user system
    group graphics drmrpc
    capabilities SYS_NICE SYS_RESOURCE
    onrestart restart surfaceflinger
```

`vendor/etc/vintf/manifest.xml` declara:

```xml
<hal format="hidl">
    <name>android.hardware.graphics.allocator</name>
    <transport>hwbinder</transport>
    <version>2.0</version>
    <fqname>@2.0::IAllocator/default</fqname>
</hal>
```

SELinux usa `hal_graphics_allocator_default_exec` para o executável e
`hal_graphics_allocator_service` para a instância AIDL nova; o serviço HIDL
usa as regras públicas do HAL gráfico.

## 3. y2s: mapper HIDL 2.0/2.1

| Arquivo | Tamanho | SHA-256 | Papel |
|---|---:|---|---|
| `vendor/lib64/hw/android.hardware.graphics.mapper@2.0-impl-2.1.so` | 34.864 | `b80b5e191750144137eb1e85b761dd7b4cc144c5f42b04a74810c254f6d4e022` | passthrough HIDL |
| `vendor/lib64/libGrallocMapperCamera.so` | 61.896 | `2d4fd0175db7be753a8802bea85e057fd4bb727f5ed255429d78ff860d6eb482` | ABI chamada pelo HAL da câmera |

Dependências de `android.hardware.graphics.mapper@2.0-impl-2.1.so`:

```text
android.hardware.graphics.mapper@2.0.so
android.hardware.graphics.mapper@2.1.so
libbase.so libcutils.so libhardware.so libhidlbase.so liblog.so libsync.so
libutils.so libc++.so libc.so libm.so libdl.so
```

Exports críticos:

```text
HIDL_FETCH_IMapper
android.hardware.graphics.mapper@2.1::IMapper
GrallocImportedBufferPool
Gralloc0Hal::lock
Gralloc0Hal::lockYCbCr
```

O mapper é uma implementação passthrough que abre o módulo Gralloc1, mantém
um pool de handles importados e fornece `lock`, `lockYCbCr`, `unlock`, metadata
e fences pela ABI HIDL. O VINTF y2s declara:

```xml
<hal format="hidl">
    <name>android.hardware.graphics.mapper</name>
    <transport arch="32+64">passthrough</transport>
    <version>2.1</version>
    <fqname>@2.1::IMapper/default</fqname>
</hal>
```

`libGrallocMapperCamera.so` depende diretamente de
`android.hardware.graphics.mapper@2.0.so`, `libnativewindow.so`,
`libion_exynos.so`, `libsync.so` e `libhardware.so`. O HAL
`libexynoscamera3.so` também possui `DT_NEEDED` para:

```text
android.hardware.graphics.allocator@2.0.so
android.hardware.graphics.mapper@2.0.so
libGrallocMapperCamera.so
libhidlbase.so
```

Além disso, o `camera.exynos990.so` depende diretamente de
`android.hardware.graphics.allocator@2.0.so`. Portanto, apagar o serviço HIDL
sem adaptar primeiro esses clientes não é uma desativação: é uma falha de
link ou uma falha de alocação no início da câmera.

## 4. O que já é AIDL no y2s

Os arquivos instalados na imagem de teste são:

```text
vendor/bin/hw/android.hardware.graphics.allocator-V2-service.exynos990
vendor/lib64/libexynos990_graphics_compat.so
vendor/lib64/hw/mapper.exynos990_compat.so
vendor/etc/init/android.hardware.graphics.allocator-V2-service.exynos990.rc
vendor/etc/vintf/manifest/android.hardware.graphics.allocator-exynos990.xml
```

O serviço publica `android.hardware.graphics.allocator.IAllocator/default`.
`getIMapperLibrarySuffix()` retorna `exynos990_compat`, e o framework carrega
`mapper.exynos990_compat.so` pelo contrato Stable-C. O bridge chama os
callbacks do `gralloc.exynos990.so`; ele não substitui o Gralloc1.

## 5. S26+: estudo do modelo AIDL

O dump S26+ contém:

| Arquivo | Tamanho | SHA-256 | Observação |
|---|---:|---|---|
| `vendor/bin/hw/android.hardware.graphics.allocator-aidl-service-sgr` | 151.384 | `f6ebbc7cf27e59335f4fce833bcc3a1300d9fda1a3f0581ea3aa7857241eeed3` | serviço AIDL |
| `vendor/lib64/hw/mapper.stableC-impl-sgr.so` | 200.824 | `e7e8acdcf18025b0939e6c4cb32189d6d1dd50a43d18c1fd5a0f6017d964eaea` | mapper Stable-C |
| `vendor/lib64/android.hardware.graphics.allocator-V2-ndk.so` | 69.080 | `24dbef00e6b9b3c15210acfa2a9c0505ea8dc3cb0447ccfc0c1ff680d1d09b40` | tipos AIDL allocator |

O serviço S26+ depende de:

```text
android.hardware.graphics.allocator-V2-ndk.so
mapper.stableC-impl-sgr.so
libbinder_ndk.so libgralloctypes.so libeis_utils.so libion_exynos.so
libhidlbase.so libhardware.so libbase.so libcutils.so liblog.so libutils.so
```

O mapper S26+ exporta `AIMapper_loadIMapper` e possui implementações
explícitas para:

```text
importBuffer/freeBuffer
lock/unlock
flush_locked_buffer/reread_locked_buffer
getMetadata/setMetadata/listSupportedMetadataTypes
CameraFormatManager
CpuFormatManager
HwcFormatManager
Sbwc/Dcc/LinearLayoutManager
ExynosIonMemoryManager
```

A diferença principal para o y2s não é somente a versão da interface. O S26+
tem `libgralloctypes.so`, gerenciadores de layout SBWC/DCC e um formato de
handle SGR próprio. Esses símbolos não podem ser copiados para o Exynos 990.

### Init e VINTF S26+

Init:

```text
service vendor.graphics.allocator-default /vendor/bin/hw/android.hardware.graphics.allocator-aidl-service-sgr
    class hal animation
    user system
    group graphics drmrpc
    capabilities SYS_NICE
    onrestart restart surfaceflinger
```

Manifest principal:

```xml
<hal format="aidl">
    <name>android.hardware.graphics.allocator</name>
    <version>2</version>
    <fqname>IAllocator/default</fqname>
</hal>
<hal format="native">
    <name>mapper</name>
    <fqname>@5.0/stableC-impl-sgr</fqname>
</hal>
```

O serviço Stable-C recebe o contexto:

```text
mapper/stableC-impl-sgr u:object_r:hal_graphics_mapper_service:s0
```

Não há serviço HIDL allocator gráfico no `vendor/bin/hw` do S26+ e não há
entrada HIDL de allocator/mapper no manifest principal. Porém, o dump ainda
fornece bibliotecas de tipos HIDL `allocator@2.0/@3.0/@4.0` e
`mapper@2.0/@2.1/@3.0/@4.0`.

Isso é intencional: `libexynosgraphicbuffer.so` ainda lista essas bibliotecas
HIDL como dependências, e `libgralloctypes.so` ainda lista
`android.hardware.graphics.mapper@4.0.so`/`libhidlbase.so`. O S26+ aposentou
os serviços HIDL, não apagou imediatamente toda a ABI de compatibilidade.

## 6. Comparação e decisão de implementação

| Item | y2s | S26+ | Decisão para o y2s |
|---|---|---|---|
| Serviço allocator | HIDL 2.0 + AIDL bridge | AIDL V2 nativo | AIDL global; HIDL temporário para câmera |
| Mapper principal | HIDL passthrough 2.1 | Stable-C SGR | Stable-C y2s baseado no handle Mali original |
| Backend físico | `gralloc.exynos990.so`/Mali | SGR/SBWC/DCC | preservar o Gralloc1 y2s |
| Tipo de handle | `private_handle_t` Exynos 990 | SGR | não misturar layouts |
| Câmera | HAL HIDL/Camera3 com ABI Gralloc1 | provider AIDL + buffer SGR | adaptar antes de remover HIDL |
| HIDL no VINTF | allocator, mapper, composer | ausentes para gráficos | retirar depois da auditoria de clientes |
| Bibliotecas HIDL | necessárias agora | ainda presentes como compatibilidade | remover somente após `DT_NEEDED` zero |

## 7. Ordem segura para desativar os HIDL

1. Manter AIDL allocator/Stable-C global — já testado e instalado.
2. Instrumentar `lshal`, `linker` e logs para separar clientes que ainda
   carregam `IMapper@2.1`.
3. Adaptar `libexynoscamera3.so`/`camera.exynos990.so` para o allocator AIDL
   e o mapper Stable-C, ou criar uma fachada transitória que encaminhe a ABI
   antiga para AIDL.
4. Validar preview, foto, vídeo, ZSL, RAW, ImageReader, fences e buffers
   protegidos.
5. Migrar `mediaswcodec` e demais consumidores de buffer que ainda aparecem no
   snapshot do `lshal`.
6. Remover do init/VINTF apenas o serviço allocator HIDL e verificar boot,
   câmera e SurfaceFlinger.
7. Remover a declaração passthrough HIDL do mapper somente quando nenhum
   cliente aparecer no `lshal`.
8. Depois de uma análise ELF sem `DT_NEEDED` HIDL gráfico, retirar as
   bibliotecas de compatibilidade. Até lá, mantê-las é necessário.

## 8. Componentes que não devem ser apagados nesta etapa

```text
vendor/lib64/hw/gralloc.exynos990.so
vendor/lib64/libion_exynos.so
vendor/lib64/libnativewindow.so
vendor/lib64/libhardware.so
vendor/lib64/libhidlbase.so
```

O `gralloc.exynos990.so` é o backend usado pelo allocator AIDL atual. O S26+
serve apenas como referência de arquitetura, contratos de metadata, ownership,
fences, layouts de câmera e organização VINTF/SELinux. Nenhum blob do S26+ foi
copiado ou tratado como compatível com o handle do y2s.

## 9. Gate de remoção definitiva (24/10/2026)

Foi criado `audit_hidl_retirement.sh` para impedir uma remoção baseada apenas
em `DT_NEEDED`. A ferramenta percorre os ELF do `work_dir`, lista as entradas
gráficas no VINTF e procura os símbolos não definidos de
`IAllocator/IMapper::getService()`.

Resultado reproduzível em `out/target/y2s/work_dir`:

```text
direct_getService_blockers=8 abi_only_consumers=22
RETIREMENT_BLOCKED: direct HIDL graphics clients remain.
```

Os oito bloqueadores são `system/system/lib64/libui.so`,
`system/system/lib/libui.so`, `system/system/lib/libgui.so`,
`vendor/lib64/camera.device@1.0-impl.so`,
`vendor/lib64/camera.device@3.2-impl.so`,
`vendor/lib64/camera.device@3.5-impl.so`,
`vendor/lib64/vendor.samsung.hardware.camera.device@5.0-impl.so` e
`vendor/lib64/android.hardware.graphics.composer@2.1-resources.so`.

Os 22 consumidores `ABI-ONLY` continuam listando uma ou mais das bibliotecas
`android.hardware.graphics.allocator@2.0.so`,
`android.hardware.graphics.mapper@2.0.so` e
`android.hardware.graphics.mapper@2.1.so` (ou as versões 3/4) sem um símbolo
direto de `getService()` detectado. Entre eles estão
`unihal_android.so`, `libexynosgraphicbuffer.so`, `libSecC2ComponentStore.so`,
`libGrallocMapperCamera.so`, `surfaceflinger` e `libgralloctypes.so`. Essa
classe ainda precisa de uma análise de link/execução, mas não é motivo seguro
para apagar a ABI.

O `customize.sh` passou a executar esse gate quando
`EXYNOS990_DISABLE_HIDL_ALLOCATOR=1` e aborta antes de remover o rc HIDL se
qualquer bloqueador existir. O AIDL allocator global continua sendo o caminho
do framework; a substituição definitiva agora tem um critério objetivo: adaptar
os clientes diretos (primeiro `libui/libgui` e o conjunto Camera3), reexecutar o
gate com zero `BLOCKER`, e só então retirar serviços, VINTF e bibliotecas de
compatibilidade em etapas separadas.

## 10. Pontos que selecionam o caminho HIDL (24/10/2026)

A inspeção do código desassemblado confirmou que o problema não é somente a
presença dos arquivos: existem construtores e inicializadores que escolhem o
serviço HIDL explicitamente.

No `system/system/lib64/libui.so`, os pontos são:

| Função | Chamada observada |
|---|---|
| `android::Gralloc2::Mapper::Mapper()` (`0x40f08`) | `mapper::V2_0::IMapper::getService()` |
| `android::Gralloc2::Allocator::Allocator(...)` (`0x41a70`) | `allocator::V2_0::IAllocator::getService()` |
| `android::Gralloc3::Mapper::Mapper()` (`0x42548`) | `mapper::V3_0::IMapper::getService()` |
| `android::Gralloc3::Allocator::Allocator(...)` (`0x42fd8`) | `allocator::V3_0::IAllocator::getService()` |
| `android::Gralloc4::Mapper::Mapper()` (`0x444fc`) | `mapper::V4_0::IMapper::getService()` |
| `android::Gralloc4::Allocator::Allocator(...)` (`0x47bec`) | `allocator::V4_0::IAllocator::getService()` |

O mesmo `libui.so` também contém chamadas AIDL (`AServiceManager_getService` e
`IAllocator::fromBinder`). Portanto, ele já possui os dois caminhos; o HIDL é
mantido como fallback/compatibilidade dentro dos construtores de versão.

Nos blobs da câmera, o padrão é mais direto: `HandleImporter::initializeLocked()`
em `camera.device@3.2-impl.so`, `camera.device@3.5-impl.so` e
`vendor.samsung.hardware.camera.device@5.0-impl.so` chama, em sequência,
`IMapper::getService()` V4, V3 e V2. O
`android.hardware.graphics.composer@2.1-resources.so` faz a mesma sequência em
`ComposerHandleImporter::init()`.

O `system/system/lib/libgui.so` é a variante 32-bit e mantém uma relocação
`R_ARM_JUMP_SLOT` para `mapper::V4_0::IMapper::getService()`; o blob está
desprovido do nome da função chamadora, mas a chamada pode ser localizada pelo
PLT/relocation. Isso confirma que a seleção HIDL ocorre também no processo
32-bit.

Esses pontos são candidatos a uma adaptação seletiva. No `libui` o caminho
AIDL já existe e a investigação deve identificar a condição que escolhe a
implementação HIDL. Na câmera e no Composer legado, a alternativa segura é
substituir o `HandleImporter` por uma fachada HIDL→Stable-C/AIDL que preserve
os mesmos retornos. Um `hex_patch` direto para trocar somente o alvo do `bl`
não é suficiente, porque cada versão retorna objetos HIDL com vtable e tipos
próprios.

## 11. Como o framework escolhe AIDL ou HIDL (24/10/2026)

O `libui.so` não começa pelo HIDL. A sequência real do construtor
`android::GraphicBufferMapper::GraphicBufferMapper()` (`0x32614`) é:

```text
1. new Gralloc5::Mapper
2. chama Gralloc5::Mapper::isLoaded()
3. se falhar: destrói e tenta Gralloc4::Mapper
4. depois Gralloc3::Mapper
5. por fim Gralloc2::Mapper
```

O campo de versão do mapper fica no objeto compartilhado. O construtor de
`android::GraphicBufferAllocator` (`0x324c8`) lê esse campo e escolhe o
allocator correspondente:

```text
versão > 4  -> Gralloc5::Allocator (AIDL)
versão == 4 -> Gralloc4::Allocator (HIDL)
versão == 3 -> Gralloc3::Allocator (HIDL)
versão == 2 -> Gralloc2::Allocator (HIDL)
```

O caminho `Gralloc5` consulta o serviço AIDL
`android.hardware.graphics.allocator.IAllocator/default` usando
`AServiceManager_isDeclared()`, `AServiceManager_waitForService()` e
`IAllocator::fromBinder()`. Para o mapper, ele chama
`AServiceManager_openDeclaredPassthroughHal()` com a string `mapper` e a
versão Stable-C. Portanto, a escolha AIDL depende da instância estar declarada
no VINTF e de o mapper Stable-C carregar corretamente; não depende de uma
propriedade simples que possa ser trocada cegamente.

Isso explica por que o aparelho já usa AIDL quando a vendor contém o fragmento
VINTF correto: o framework tenta `Gralloc5` primeiro. As chamadas HIDL que a
auditoria encontrou são os caminhos de fallback mantidos para quando o AIDL
não está declarado, não carrega ou retorna uma versão incompatível. Um
`hex_patch` útil, portanto, não deve trocar cada `getService()` isoladamente;
deve preservar o teste de `isLoaded()` e garantir que `Gralloc5` permaneça
carregado. Forçar o salto diretamente para `Gralloc4` faria o oposto e
reativaria o HIDL.

## 12. Falha prática e correção do seletor (24/10/2026)

No primeiro teste real, o allocator AIDL foi registrado e o SurfaceFlinger
chegou a carregar o arquivo `mapper.exynos990_compat.so`, mas o `Gralloc5`
falhou antes de chamar `AIMapper_loadIMapper`. O log decisivo foi:

```text
Failed to get isDeclared for mapper/exynos990_compat:
SELinux denied for service
avc: denied { find } ... name=mapper/exynos990_compat
tcontext=u:object_r:default_android_service:s0
Gralloc5: Failed to load mapper.exynos990_compat.so
```

O erro não era SONAME, `DT_NEEDED` ou incompatibilidade do handle. O nome
Stable-C estava sem entrada em `vendor_service_contexts`, então a regra
curinga o rotulava como `default_android_service`. A correção aplicada no
`customize.sh` adiciona a entrada específica:

```text
mapper/exynos990_compat u:object_r:hal_graphics_mapper_service:s0
```

Após instalar a mesma entrada no ambiente de teste e reiniciar o
`servicemanager`, o log passou a registrar `Found mapper/exynos990_compat in
device VINTF manifest`; o SurfaceFlinger manteve
`mapper.exynos990_compat.so` e `libexynos990_graphics_compat.so` mapeados, sem
novos erros `Gralloc5` ou AVC desse nome. Os avisos de sondagem
`Gralloc4/Gralloc3` restantes são as tentativas HIDL de compatibilidade, não
o caminho primário selecionado.

