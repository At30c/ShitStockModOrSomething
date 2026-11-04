# Separação do driver de buffers da câmera

Este documento define a divisão da implementação para o y2s/Exynos 990. O
objetivo é modernizar a semântica de buffers com AIDL sem substituir os blobs
proprietários nem misturar o `private_handle_t` Mali com o handle SGR do S26+.

## Camadas que não devem ser misturadas

| Camada | Implementação do y2s | Responsabilidade | Fonte de comparação |
| --- | --- | --- | --- |
| Backend físico | `gralloc.exynos990.so` | ION/DMA-BUF, alocação, retain/release, lock e unlock | driver original do S20+ |
| Contrato de câmera | `libGrallocMapperCamera.so` e `camera.exynos990.so` | ABI HIDL/Camera3, `0x11d`, `LOCK_FLEX`, usages combinados | disassembly e runtime do S20+ |
| Adaptador moderno | `mapper.cpp` e `allocator_service.cpp` | AIDL Mapper/Allocator, metadata e conversão de usages | Stable-C do S26+ |
| Fachada de compatibilidade | `camera_mapper_compat.cpp` | Exportar apenas os símbolos que o HAL HIDL já chama | ABI do S20+ |
| Composição | `composer3_contract.cpp`/HWC2 backend | Composer3 sobre o HWC2 original | fluxo de callbacks do S26+ |

O backend físico continua sendo aberto por `hw_get_module()` e não é
recompilado. O S26+ só fornece a semântica de `importBuffer`, `lockYCbCr`,
`PlaneLayout`, metadata e fences.

## Contrato físico preservado do S20+

O adaptador deve manter:

* `private_handle_t` do Exynos 990/Mali;
* formato privado de câmera `0x11d` como handle opaco;
* callbacks `mali_gralloc_lock_async`, `mali_gralloc_get_num_flex_planes`,
  `mali_gralloc_lock_flex_async` e `mali_gralloc_unlock`;
* `hw_module_t = nullptr` nas chamadas privadas observadas no mapper original;
* usage combinado recebido pelo HAL, sem separar produtor/consumidor antes da
  chamada privada;
* offsets e strides confirmados no handle: `+0x50`, `+0x5c`, `+0x68`, `+0x6c`
  e `+0x78`;
* posse de acquire/release fences exatamente uma vez.

Não se deve publicar `PlaneLayout` transportável para `0x11d` enquanto o
driver não comprovar índices de FD e offsets físicos. Nesse caso o AIDL deve
retornar `UNSUPPORTED`, preservando a rota HIDL da câmera.

## Semântica moderna comparada com o S26+

| Operação | S26+ | Adaptação y2s |
| --- | --- | --- |
| Importação | `GraphicBufferMapper::importBufferNoValidate` | clone + retain do Gralloc1 |
| Lock YUV | `lockYCbCr` → `CameraFormatManager` | `LOCK_FLEX` Mali → `YCbCrLayout` |
| Planes | `PlaneLayout` SGR com offsets/FDs públicos | metadata somente para formatos comprovadamente lineares |
| Fence | Stable-C consome acquire e devolve release | helper Mali consome acquire e `unlock` devolve release |
| Handle | SGR | `private_handle_t` Mali |
| Protected | sem CPU map | `IMapper::lock` retorna `UNSUPPORTED` |
| Provider | Camera Provider AIDL v3 | Camera Provider HIDL permanece na primeira fase |

A equivalência que será auditada é de comportamento, não de layout binário.
Qualquer diferença de handle, FD, modifier ou ownership é esperada quando a
operação usa o backend do S20+ e deve ser tratada explicitamente.

## Fachada HIDL

`camera_mapper_compat.cpp` é a única camada que conhece os nomes C++ mangled
solicitados por `libexynoscamera3.so`. Ela deve apenas:

1. receber a chamada HIDL existente;
2. encaminhar ao adaptador de contrato do S20+;
3. converter o resultado para `YCbCrLayout` e o código de erro HIDL;
4. devolver a release fence sem alterar a posse.

Ela não deve registrar allocator AIDL global, interpretar handle SGR ou chamar
diretamente classes privadas do S26+.

## Ordem de promoção

1. Compilar e auditar cada camada separadamente.
2. Validar preview, still, vídeo, ZSL e ImageReader mantendo HIDL na câmera.
3. Validar RAW, protected buffers e fences sob carga.
4. Adaptar os clientes Camera3 para o mapper AIDL.
5. Só então remover dependências HIDL da câmera e considerar o provider AIDL.

Até a etapa 4, `EXYNOS990_DISABLE_HIDL_ALLOCATOR=1` deve continuar bloqueado
pela auditoria de clientes.
