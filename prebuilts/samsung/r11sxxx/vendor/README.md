# r11s vibrator service dump

Fonte: Android Dumps / Samsung r11s
Ref: `r11sxxx-user-15-AP3A.240905.015.A2-S711BXXSAEYI1-release-keys`

Este diretório é apenas um prebuilt de análise. Nenhum arquivo foi instalado no aparelho.

Serviço analisado: `vendor/bin/hw/vendor.samsung.hardware.vibrator-service`

Dependência ELF declarada, mas ausente no dump:

- `android.hardware.vibrator-V2-ndk_platform.so`

O dump também expõe `android.hardware.vibrator-V4-ndk.so` e
`vendor.samsung.hardware.vibrator-V5-ndk.so` em `system/lib`, mas esses
arquivos são **32-bit** e têm SONAME diferente; não satisfazem o serviço
64-bit, que pede a variante `V2-ndk_platform`.

O `platform/exynos990/patches/vendor/customize.sh` foi protegido para abortar a
build de `y2s`/`y2slte` enquanto essa dependência não for fornecida. Não é
seguro substituir essa biblioteca pelo `android.hardware.vibrator-V4-ndk.so`
do target: são interfaces AIDL diferentes.

Arquivos mantidos:

- `vendor/bin/hw/vendor.samsung.hardware.vibrator-service`
- `vendor/lib64/vendor.samsung.hardware.vibrator-V5-ndk_platform.so`
- `vendor/etc/init/vendor.samsung.hardware.vibrator-default.rc`
- `vendor/etc/vintf/manifest/vendor.samsung.hardware.vibrator-default.xml`

As bibliotecas base do sistema e `vibrator.default.so` foram removidas porque já existem no target ou são drivers fora do conjunto AIDL analisado. Os hashes dos arquivos mantidos estão em `SHA256SUMS`.

Além da dependência ELF ausente, o target atual ainda declara o HAL HIDL
`vendor.samsung.hardware.vibrator@2.2`; o fragmento deste prebuilt declara o
HAL AIDL `android.hardware.vibrator/IVibrator/default`. A migração só deve ser
ativada quando houver um conjunto AIDL completo e a declaração antiga for
tratada de forma consistente.

## Candidato encontrado na base e2s

A base local `out/fw/SM-S926B_EUX` contém
`vendor/lib64/android.hardware.vibrator-V2-ndk.so`. A biblioteca exporta todos
os símbolos AIDL V2 que o serviço `r11s` e o `V5-ndk_platform` importam, mas o
SONAME/NEEDED é `android.hardware.vibrator-V2-ndk.so`, sem o sufixo
`_platform`. Ela é, portanto, uma candidata para um teste controlado; ainda
não foi copiada nem renomeada no módulo.
