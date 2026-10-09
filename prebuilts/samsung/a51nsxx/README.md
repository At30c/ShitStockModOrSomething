# Galaxy A51 vibrator HIDL donor

Fonte: [Samsung Dumps / A51](https://dumps.tadiphone.dev/dumps/samsung/a51),
branch `a51nsxx-user-13-TP1A.220624.014-A515FXXU8HWK1-release-keys`.
O conjunto foi separado do commit
`ff61a15b414bb8dfa7362325eeb8d94d9537e6ad` e fica disponível como prebuilt de
análise para o M21s; ele não é ativado por nenhum módulo da build.

Este donor contém somente o serviço HIDL 2.2, o `rc`, o fragmento VINTF e as
interfaces HIDL `android.hardware.vibrator@1.x` e
`vendor.samsung.hardware.vibrator@2.x`. Os hashes estão em `SHA256SUMS`.

A auditoria estática comparou o conjunto com os blobs originais do M21s:

- o conjunto `DT_NEEDED` do serviço é igual e todas as dependências existem na
  vendor do M21s;
- os símbolos definidos do serviço e das sete bibliotecas HIDL são iguais,
  incluindo as contagens de cada biblioteca;
- nenhum dos arquivos analisados contém `ldaprb`, `ldaddal`, `paciasp` ou
  `autiasp`, instruções que já causaram `SIGILL` nos donors AIDL modernos;
- o `vendor.samsung.hardware.vibrator@2.2-service.rc` é byte a byte igual ao
  `rc` do M21s, e o bloco VINTF `ISehVibrator@2.2/default` também é igual.

Não copie deste donor `vendor/lib64/hw/vibrator.default.so` nem
`vendor/lib64/libvibrator.so`: ambos são específicos do hardware e diferem dos
originais do M21s. O `vendor/etc/vintf/manifest.xml` completo do A51 também não
deve substituir o do M21s; use apenas o fragmento para conferir a declaração
do HAL.

O prebuilt é um ponto de partida para um teste HIDL controlado. Ainda não foi
instalado no aparelho nem ligado ao `customize.sh`.
