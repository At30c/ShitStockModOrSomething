# Teste do provider AIDL V4 por bind mount

O teste foi feito sem reconstruir nem gravar a imagem EROFS da vendor. O
provider original foi salvo antes da troca e o arquivo experimental foi
montado em `/vendor/bin/hw/android.hardware.camera.provider-V4-service.exynos990`
a partir de um `tmpfs` com `exec`, preservando o contexto
`u:object_r:hal_camera_default_exec:s0`.

- Provider original: `c022ec3ce6927a1fae9faff91d4d773187d418669d0b2b4d93873a711c616f8b`.
- Provider testado: `ddcf0ec12c8cd72fe4de41ee28f4225ee04e44f28c5cbefe45f0c26fda23be8e`.
- Serviço: `exynos990-camera-provider-aidl`, iniciado sem bootloop.
- Preview: a interface abriu, com zoom `.5/1/2/3`, sem crash durante a janela
  de observação.
- HAL nativo: a captura chegou ao backend e registrou JPEG concluído com
  `jpeg size(11922700)`.
- Falha restante: o callback AIDL de resultado do buffer JPEG não foi entregue
  ao `CameraService` dentro do prazo; a Samsung Camera exibiu `Erro na câmera`.
  O backend também continua registrando a limitação física `FLITE_BUF` de oito
  buffers Bayer.

Depois do teste, o bind foi desmontado, o arquivo temporário foi removido e o
provider original voltou a ser usado. A vendor nunca foi reempacotada ou
gravada com `dd`.
