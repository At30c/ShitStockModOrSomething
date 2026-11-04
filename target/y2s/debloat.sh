# Copyright (c) 2026 Salvo Giangreco
# SPDX-License-Identifier: GPL-3.0-or-later

# AutoHotspotMDE is retained because MCF uses it for the Wi-Fi leg of Quick
# Share transfers. Removing it breaks both sending and receiving; the
# unrelated modem poller iNTC remains debloated below.

# iNTC is not shipped by the original G985F/G986B firmware. The S947B app
# polls IPC_MISC_CP_METRIC every three seconds, which the Exynos 990 RIL
# rejects with error 6. Its immediate retry wakes the modem PCIe link twice
# per poll while the device is idle.
SYSTEM_DEBLOAT+="
system/etc/permissions/privapp-permissions-com.sec.intc.xml
system/priv-app/iNTC
"

# MdxKitService (com.samsung.android.mdx.kit) não pode ser removido: a
# ShareLive só inicia a descoberta do Quick Share com esse pacote habilitado e,
# sem ele, lança ConnectionAppNotEnabledException (não envia nem recebe). A
# varredura BLE contínua que motivou a remoção antiga deve ser tratada sem
# apagar o pacote.

