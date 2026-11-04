# Composer3 AIDL → HWC2 para y2s/y2slte

Este módulo registra `android.hardware.graphics.composer3.IComposer/default`
com uma implementação AIDL V5 que encaminha as operações suportadas para o
`hwcomposer.exynos990.so` original. O serviço é limitado aos targets `y2s` e
`y2slte`, instala o fragmento VINTF, o `init.rc`, o executável ARM64 e a
biblioteca do bridge. Como o namespace de linker vendor do Android 17 não
exporta o runtime Composer3 AIDL V5 nem os contratos `common`/`drm` para
processos vendor, o módulo também instala essas quatro bibliotecas NDK no
mesmo diretório `vendor/lib64`.

Compile os artefatos sem executar a build completa da ROM:

```sh
platform/exynos990/patches/composer3_hwc2_bridge/build.sh
```

O módulo não troca nem remove o Composer HIDL existente. Isso permite rollback
simples: remover o módulo da imagem restaura o caminho HIDL original. Antes de
usar uma imagem em produção, validar boot, SurfaceFlinger, rotação, câmera,
vídeo, suspensão e jogo prolongado. Os métodos sem equivalente seguro no HWC2
retornam `EX_UNSUPPORTED` explicitamente.
