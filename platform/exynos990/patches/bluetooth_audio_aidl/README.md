# Provider de áudio Bluetooth AIDL no Exynos 990

Este módulo é específico para `y2s`/`y2slte`. A auditoria do S26+ mostrou
que o Android 17 usa `IBluetoothAudioProviderFactory/default` em AIDL e troca
PCM por FMQ. O y2s original só anuncia
`vendor.samsung.hardware.bluetooth.audio@2.1`, deixando o Bluetooth APEX cair
no caminho HIDL ligado ao `audio.primary`/`libaudioproxy_9830`. Nesse caminho a
primeira sessão SBC pode permanecer em `BT A2DP Off/suspended`.

O módulo importa somente a implementação genérica do provider AIDL e a sua
cadeia de link (`android.hardware.bluetooth.audio-V5-ndk`, áudio comum V4,
tipos de áudio V4, FMQ, FlatBuffers e flags). O HCI Broadcom, o firmware
Bluetooth e o HAL de áudio principal do y2s continuam sendo os originais.

Durante o primeiro teste `persist.bluetooth.a2dp_offload.disabled=true` é
mantido para escolher a codificação SBC por software no provider AIDL. Depois
de validar Buds 3 Pro e a multimídia do carro, essa propriedade pode ser
testada por codec para reativar apenas o offload que funcionar.
