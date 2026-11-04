# Auditoria do mapper Stable-C do Exynos 990

Esta auditoria foi feita antes de habilitar o allocator AIDL global. O
objetivo foi deixar o mapper privado do Composer3 mais seguro sem mudar o
caminho global usado pela câmera: o allocator e o mapper HIDL do vendor
continuam atendendo Gralloc1/Mali e `libGrallocMapperCamera.so`.

## Varreduras executadas

Foram revisados os contratos de importação, lock/unlock, locks aninhados,
fences, DMA-BUF, metadados, layouts YUV, handles nativos e os caminhos de erro
do formato privado `0x11d` da câmera. A compilação cruzada foi executada com:

```sh
platform/exynos990/patches/graphics_allocator_bridge/build.sh
```

O teste `bridge_test` agora também verifica que um native handle malformado é
rejeitado antes de chegar ao Gralloc1, que `setStandardMetadata()` rejeita
ponteiro nulo com payload, e que uma região AIDL zerada é normalizada para o
buffer inteiro. O teste YUV continua conferindo `PLANE_LAYOUTS`, conversão de
uso com `CAMERA_OUTPUT`, `LOCK_FLEX`, fences, flush/reread e liberação dupla.

### Allocator AIDL atualizado (24/10/2026)

O serviço `android.hardware.graphics.allocator-V2-service.exynos990` agora
consulta o gralloc original também em `isSupported()`: ele monta o descriptor,
faz uma alocação real de prova, consulta o stride e libera o buffer antes de
responder. Assim o framework não recebe `true` para um formato que o driver
proprietário rejeitaria. As flags AIDL sem equivalente no descriptor Gralloc1
(`GPU_CUBE_MAP`, `GPU_MIPMAP_COMPLETE`, `HW_IMAGE_ENCODER` e `FRONT_BUFFER`)
passam a ser recusadas explicitamente, em vez de descartadas silenciosamente.

O `bridge_test` foi ampliado para verificar descritor válido, largura zero e
`GPU_CUBE_MAP`. Com o serviço e o mapper recém-compilados carregados de
`/data/local/tmp`, o teste passou em 100 iterações, incluindo importação,
metadata, lock/unlock, fences, YUV/LOCK_FLEX e liberação dupla. A validação
foi feita contra o `gralloc.exynos990.so` original do y2s; nenhum blob do S26+
foi usado.

## Correções aplicadas

* Metadados agora ficam associados ao handle exato quando
  `GET_BACKING_STORE` retorna zero. Quando há um identificador válido, imports
  do mesmo allocation continuam compartilhando o metadata.
* `importBuffer()` valida versão, contagem e limites de fds/inteiros do
  `native_handle_t` e zera o resultado em todos os caminhos de erro.
* `lock()` aceita a região `{0,0,0,0}` como a região completa, valida limites e
  rejeita regiões invertidas ou fora da alocação.
* `lock()` rejeita bits que não pertencem ao domínio de uso da CPU, conforme o
  contrato AIDL, em vez de ignorá-los silenciosamente.

## Estado para a próxima etapa

O mapper Stable-C privado está compilável e auditado, mas ainda usa o
Gralloc1/Mali original para a execução física dos buffers. O allocator AIDL
global permanece desligado (`EXYNOS990_AIDL_GRAPHICS=0`) nesta etapa para que a
câmera continue no caminho HIDL já validado. A próxima etapa é um boot
controlado com VINTF/init do allocator global; antes de trocar o padrão, ainda
é necessário observar câmera, ImageReader, MediaCodec e composição prolongada
com o framework realmente selecionando a instância AIDL.
