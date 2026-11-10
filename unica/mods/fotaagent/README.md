# FotaAgent como atualizador da ROM

O `FotaAgent` (`com.wssyncmldm`) de fábrica continua na ROM. Este módulo
corta tudo que fala com a Samsung e faz o app buscar, baixar e instalar as
atualizações da própria ROM, com a interface normal de "Atualização de
software".

Este arquivo não entra na ROM: `scripts/internal/apply_modules.sh` só copia
as pastas de partição (`system/`, `vendor/`...), roda o `customize.sh` e
aplica `smali/`.

## Fluxo

1. **Verificação.** `io.unica.fota.UpdateChecker` (patch 0018) lê o manifesto
   JSON da URL em `ro.unica.ota.manifest` e compara com `ro.unica.timestamp`.
   A verificação roda em dois casos:
   - **sozinha**, pelo alarme de polling do próprio app: 5 a 10 minutos depois
     que o app se registra (primeiro boot, depois de uma atualização ou de
     limpar os dados) e depois uma vez por dia, com um espalhamento aleatório
     de até 2 h. O app cria o alarme com uma janela de 45 min, e o Android
     pode atrasá-lo dentro dela. Se já existe um job (baixando, pausado ou
     pronto para instalar), o polling não faz nada, como o agendador de
     fábrica: um segundo job gravaria no mesmo `update.zip`;
   - **pelo botão** "Procurar atualizações" em Configurações. Sem atualização
     aparece "Seu software está atualizado", e se não der para ler o manifesto
     aparece o diálogo de falha de conexão.
2. **Download.** O job FUMO usa o download descriptor (DD) indicado pelo
   manifesto. O DlAgent baixa o pacote, segue redirecionamentos HTTP e confere
   o MD5 do `installParam`. Vale a opção de download automático do app (o
   padrão é só pelo Wi-Fi); o job nunca é tratado como push urgente.
3. **Verificação da assinatura.** `RecoverySystem.verifyPackage()` só aceita
   pacotes assinados pela chave em `otacerts.zip`. O `customize.sh` troca as
   chaves da Samsung pelo certificado que assina os zips da ROM
   (`aosp_testkey`, ou `unica_ota` quando `ROM_IS_OFFICIAL=true`).
4. **Instalação.** O app grava `/cache/recovery/openrecoveryscript`
   (`install <pacote>` e `reboot`, patch 0014) e reinicia para o TWRP. O TWRP
   não lê o `--update_package` do RecoverySystem, porque lê os comandos antes
   de montar o /cache.
5. **Resultado.** Antes de reiniciar, o app grava `FOTA` em
   `/cache/fota/fota.status`. O updater-script troca esse valor por `FAIL` logo
   no começo e por `DONE` no fim (`PRINT_FOTA_STATUS` em
   `scripts/utils/build_utils.sh`). No boot, o app lê o resultado, mostra
   sucesso ou falha, apaga o pacote e fecha o job (patches 0015 a 0017).

Os zips incrementais sempre levam o `fota.status`. O zip completo e o
flashable só levam com `make_rom.sh -u` (`FOTA_STATUS_IN_FULL_ZIP`). Fora de
uma instalação feita pelo app, o arquivo não existe e a linha não faz nada.

## Patches

| Patch | O que faz |
|---|---|
| 0001 | Bloqueia a API REST de FOTA da Samsung (registro, push, `version.xml`, heartbeat, campanhas) |
| 0002 | Bloqueia as sessões OMA-DM com o servidor da Samsung |
| 0003 | Bloqueia os relatórios de resultado (UpdateReporter) |
| 0004 | Bloqueia o Samsung Analytics (envio, termos, política) |
| 0005 | Desliga o DiagMon |
| 0006 | Nunca registra push (FCM ou Samsung SPP) |
| 0007 | Mantém a URL do DD nos jobs criados pela ROM |
| 0008 | `io.unica.fota.UpdateReceiver`: inicia um job a partir de uma URL de DD (protegido por `DUMP`, só shell/sistema; usado para depuração) |
| 0009 | Mantém o auto-init do FCM desligado |
| 0010 | Job sem comando DM Exec é `DownloadAndUpdate` |
| 0011 | DD sem `installNotifyURI`: não envia relatório de download |
| 0012 | Informa o aparelho como registrado no agendador, senão ele reseta o app e perde o download |
| 0013 | Não recusa instalar por o binário não ser "oficial" |
| 0014 | Grava o `openrecoveryscript` para o TWRP |
| 0015 | `isRegistered()` verdadeiro, para o boot retomar o job e ler o resultado |
| 0016 | A retomada no boot mantém jobs sem DM Exec |
| 0017 | Fecha o job sem esperar a sessão DM de relatório que o 0002 bloqueia: apaga o pacote e roda o `IDMFumoTaskDmFinish`, o mesmo encerramento de quando o servidor responde `FINISH`. Ele tira a notificação "Conectando ao servidor" e manda `SCHEDULE_FINISH`. O `FINISH_AND_EXECUTE` (0x3f5), usado antes, esperava um próximo pacote e deixava o job aberto |
| 0018 | `io.unica.fota.UpdateChecker`: manifesto da ROM no lugar da Samsung, no polling e no botão. `io.unica.fota.PartProxy`: pacotes em partes servidos como um arquivo em 127.0.0.1 |
| 0019 | Falha de download fecha o job como no 0017, em vez da sessão DM que reporta a falha. O 0002 bloqueia essa sessão, que repetia para sempre com "Conectando ao servidor" na tela, e o job pendente fazia o UpdateChecker ignorar novas buscas |
| 0020 | O `HttpURLConnection` define o `Host`. O DlAgent fixava o `Host` da primeira URL também depois do redirecionamento, e o CDN dos arquivos de release do GitHub responde 500 a `Host: github.com` |

Nunca desative este módulo enquanto o FotaAgent estiver na ROM: o app sem
patch registra o aparelho na Samsung no primeiro boot.

## Manifesto

URL padrão, definida no `customize.sh` e substituível por
`ROM_OTA_MANIFEST_URL` (vazio desliga as verificações):

```
https://github.com/At30c/ShitStockModOrSomething/releases/latest/download/ota-<device>.json
```

O `latest/download` sempre aponta para a release mais nova, então basta anexar
um manifesto atualizado a cada release, sem commit no repositório.

```json
{
  "device": "y2s",
  "builds": [
    { "version": "2.0.2", "timestamp": 1794200000, "dd": "dd-2.0.2-full.xml" },
    { "version": "2.0.2", "timestamp": 1794200000,
      "base_timestamp": 1794036309, "dd": "dd-2.0.2-incremental.xml" }
  ]
}
```

- `timestamp` é o `ro.unica.timestamp` da build.
- Uma entrada com `base_timestamp` é incremental e só vale para o aparelho
  que está exatamente naquela build.
- `dd` pode ser absoluta ou relativa à URL do manifesto. É resolvida contra a
  URL original, não contra o destino de um redirecionamento.
- Escolha: a build mais nova vence. Na mesma build, o incremental vence o
  completo. Builds antigas ou incrementais de outra base são ignoradas.
- Se `device` não bater com `ro.unica.device`, o manifesto é ignorado.
- O manifesto é limitado a 1 MiB e lido com timeout de 30 s.

Mantenha a entrada completa da build mais nova, para quem está duas ou mais
builds atrás.

### Pacote em partes

Um pacote maior que o limite do host por arquivo (abaixo de 2 GiB nas
releases do GitHub) vai em partes, listadas em ordem com o tamanho exato de cada uma:

```json
{ "version": "2.0.2", "timestamp": 1794200000, "dd": "dd-2.0.2-full.xml",
  "parts": [ { "url": "UN1CA_2.0.2_y2s.zip.001", "size": 2097152000 },
             { "url": "UN1CA_2.0.2_y2s.zip.002", "size": 2097152000 },
             { "url": "UN1CA_2.0.2_y2s.zip.003", "size": 2097152000 },
             { "url": "UN1CA_2.0.2_y2s.zip.004", "size": 1186864189 } ] }
```

- O `scripts/fota_release.py` divide o zip em partes de 2000 MiB (veja
  "Publicar uma atualização"). O GitHub recusa arquivos de 2 GiB ou mais.
- O DD descreve o arquivo inteiro, já remontado (`size` total e `MD5=` do zip
  completo). O `objectURI` dele é ignorado. A soma das partes precisa bater
  com o `size`, senão a verificação falha.
- As URLs das partes podem ser relativas ao manifesto e podem redirecionar.
  O host precisa aceitar `Range` (as releases do GitHub aceitam).

`io.unica.fota.PartProxy` serve as partes como um arquivo só em
`http://127.0.0.1:47821`. O `UpdateChecker` entrega ao job o endereço
`/unica/dd.xml` do proxy, com o `objectURI` trocado para `/unica/package.bin`.
O DlAgent baixa normalmente: barra de progresso, retomada com `Range`, MD5 e
instalação continuam os de fábrica. Para cada trecho pedido, o proxy busca só
os bytes necessários da parte certa, e o arquivo já é gravado inteiro no
aparelho.

- O DD e a lista de partes ficam salvos nas preferências do app, e o proxy
  volta junto com o processo (`IDMApplication.onCreate`). Assim um download
  retomado depois de um reboot ainda encontra o proxy.
- Cada requisição do DlAgent fica presa à rede ativa naquele momento. Se a
  rede mudar (por exemplo, o Wi-Fi cai e entram os dados móveis), o proxy
  corta a transferência. Sem isso, a opção "só Wi-Fi" seria furada: a conexão
  do DlAgent é local e não percebe a troca. Com o corte, o DlAgent pausa e
  retoma do ponto em que parou quando a rede permitida volta.
- O proxy escuta só em `127.0.0.1`. Outros apps do aparelho poderiam se
  conectar, mas ele só repassa os arquivos públicos da release.

## Download descriptor (OMA DD 1.0)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<media xmlns="http://www.openmobilealliance.org/xmlns/dd">
  <DDVersion>1.0</DDVersion>
  <name>UN1CA 2.0.2</name>
  <vendor>UN1CA</vendor>
  <type>application/octet-stream</type>
  <size>TAMANHO_EM_BYTES</size>
  <objectURI>URL_DO_PACOTE</objectURI>
  <installParam>MD5=MD5_DO_PACOTE;mrType=MINOR</installParam>
  <description><![CDATA[<b>Novidades</b><br>• item]]></description>
  <summaryDescription>Resumo de uma linha</summaryDescription>
  <descriptionType>html</descriptionType>
</media>
```

- `type` precisa ser `application/octet-stream`, e o servidor precisa servir
  o pacote com esse mesmo Content-Type. Outro tipo faz o DlAgent abortar com
  erro 505.
- `size` precisa bater com o arquivo, e o `MD5=` é conferido depois do
  download.
- Não coloque `installNotifyURI`: nada é reportado de volta.
- `description` (HTML quando `descriptionType=html`) e `summaryDescription`
  são o changelog que o app mostra.
- O DlAgent acrescenta `px-nb` (tipo de rede, criptografado) e `px-rmtime`
  (hora UTC) à URL do pacote, com `&` quando ela já tem `?`. O host recebe
  esses dois parâmetros.

## Publicar uma atualização

`scripts/fota_release.py` gera tudo a partir dos zips do build e envia para
uma release do GitHub. Ele lê `device`, `version`, `timestamp` e
`incremental` do `build_info.txt` de cada zip.

```bash
# 0. Escreva o changelog em changelog.txt, na raiz do repositório
# 1. Gera os DDs, as partes e o manifesto em out/fota/<tag> (sem rede)
scripts/fota_release.py prepare
# 2. Envia para a release (cria como rascunho se ainda não existir)
scripts/fota_release.py upload
# 3. Publica: só então o manifesto em latest/download passa a valer
gh release edit <tag> -R At30c/ShitStockModOrSomething --draft=false --latest
```

Sem argumentos, o `prepare`:
- pega em `out/` a build mais nova (maior `timestamp` no `build_info.txt`),
  o zip completo e os incrementais que terminam nela;
- usa a tag `<versão>-<data da build em UTC>`, por exemplo
  `2.0.3-20261109-0453`;
- usa o `changelog.txt` da raiz do repositório, se existir.

O `upload` sem argumentos envia o último `prepare`. Tudo pode ser trocado:
`prepare <zips...> --tag <tag> --changelog <arquivo>`, `upload <pasta>`.

- **Changelog.** Arquivo `.html`, usado como está, ou texto simples: `# x`
  vira título em negrito, `- x` ou `* x` vira item, e uma linha vazia vira
  quebra de linha. O resumo de uma linha é o primeiro item que não é título;
  `--summary` troca esse texto.
- **URLs.** O `objectURI` e as URLs das partes apontam para
  `releases/download/<tag>/`, não para `latest`. Um download pausado continua
  funcionando depois que sai uma release mais nova. `--base-url` troca o host
  (por exemplo, um servidor próprio).
- **Partes.** Um zip maior que `--part-size` (padrão de 2000 MiB) é dividido
  em `<zip>.001`, `.002`... O DD continua descrevendo o zip inteiro, e o zip
  original não é enviado.
- **Manifesto.** O manifesto fica só com a build mais nova: o pacote completo
  e os incrementais. Builds anteriores são descartadas, porque o app sempre
  escolhe a mais nova. `--merge <ota-y2s.json>` aproveita as entradas de um
  manifesto existente, para gerar o completo e o incremental em execuções
  separadas. O script avisa quando falta o pacote completo da build nova.
- **Validações.** O script avisa quando um zip não tem a assinatura de
  arquivo inteiro (o app recusaria o pacote) e recusa zips de aparelhos
  diferentes. Também recusa nomes com caracteres que o GitHub trocaria no
  upload, porque as URLs deixariam de bater.
- **Content-Type.** O DlAgent só aceita o pacote se o Content-Type da
  resposta for exatamente o `<type>` do DD (`application/octet-stream`), e o
  GitHub serve cada arquivo com o tipo gravado no upload. O
  `gh release upload` escolhe o tipo pela extensão (`application/zip` para
  um zip), e com ele o download aborta com erro 505. Por isso o `upload` usa
  a API direto, com `application/octet-stream`. Um arquivo que já existe com
  outro tipo é recusado; `--clobber` substitui. O tipo do DD em si não é
  conferido.
- **Bases do incremental.** Ao publicar (`upload --publish`), o script fixa
  o target-files de cada build da release em
  `out/target/<device>/incremental/published/<timestamp>` (hardlinks, sem
  espaço extra enquanto a `base-target-files` for a mesma build) e guarda as
  3 mais novas; `fota_release.py pin [tag]` faz o mesmo à mão. O
  `make_rom.sh -i` gera um incremental a partir de cada uma das 2 publicadas
  mais novas (`ROM_INCREMENTAL_BASES` muda o número), e não mais da última
  build: a `base-target-files` acompanha toda build, inclusive as de teste
  nunca publicadas, e em 09/11 a base publicada chegou a ser apagada.
  Sem nenhuma publicada, volta à última build e avisa.

## Hospedagem

O manifesto e os DDs são pequenos e ficam nas releases do GitHub. O pacote
pode ficar em qualquer host, porque o DD aponta para ele por URL.

| Pacote | Host | Situação |
|---|---|---|
| Incremental | Release do GitHub | Cabe no limite por arquivo. O DlAgent segue o 302 do link de release (testado com redirecionamento local). Precisa ser enviado como `application/octet-stream` (`fota_release.py upload`) |
| ROM completa (~7,5 GB) | Release do GitHub, em partes | Testado localmente: 335 MB em 3 partes (uma por redirecionamento), com duas quedas de Wi-Fi e MD5 certo no fim |
| ROM completa | Google Drive | Alternativa, **não testada**. Riscos abaixo |

### Google Drive: riscos e como testar

1. **Aviso de vírus.** Em arquivos acima de uns 100 MB, o link
   `drive.google.com/uc?export=download&id=...` devolve uma página HTML de
   confirmação, não o arquivo. O DlAgent recusa (`text/html`, erro 505).
   Geradores de link direto como o gdocs2direct
   (sites.google.com/site/gdocs2direct) só convertem o link de
   compartilhamento para esse mesmo formato `uc?export=download`, então não
   resolvem. As receitas com `curl`/`wget` de dois passos (baixar o aviso,
   guardar o cookie, extrair o token `confirm` e repetir) também não servem:
   o DlAgent faz um único GET sem cookies. O candidato de um passo só é
   `https://drive.usercontent.google.com/download?id=<ID>&export=download&confirm=t`,
   que costuma servir o arquivo direto. O Google já mudou esse comportamento
   antes, então só o teste abaixo confirma.
2. **Retomada.** Em 7,5 GB a conexão cai em algum momento. O DlAgent retoma
   com `Range`; se o Drive não respeitar, o download recomeça do zero.
3. **Cota.** Muitos downloads do mesmo arquivo em pouco tempo fazem o Drive
   bloquear por cerca de 24 h e devolver HTML. O DlAgent falha e tenta mais
   tarde; o MD5 impede instalar um arquivo errado.
4. **Content-Length.** O DlAgent compara o tamanho do DD com o
   `Content-Length`. O Drive costuma enviar esse cabeçalho no link direto, mas
   isso precisa ser confirmado.

Teste antes de publicar, com um arquivo público de mais de 100 MB:

```bash
URL='https://drive.usercontent.google.com/download?id=<ID>&export=download&confirm=t'
# Content-Type, Content-Length e redirecionamentos, sem baixar o corpo
curl -sSIL "$URL"
# Range: deve responder 206 com Content-Range
curl -sS -o /dev/null -w '%{http_code} %{content_type}\n' -r 0-1023 "$URL"
```

Depois, no aparelho, aponte um DD para o link, deixe o DlAgent baixar alguns
MB, interrompa (desligue o Wi-Fi) e confirme que ele retoma de onde parou.

Se o Drive falhar, use um host que sirva o arquivo direto, sem página
intermediária (SourceForge, R2/B2, servidor próprio). O app não muda, só o
`objectURI`.

## Chave de assinatura

Fora do build oficial, o `otacerts.zip` usa a `aosp_testkey`, que é pública:
qualquer pessoa consegue assinar um pacote que o app aceita. Para distribuir
atualizações, use `unica_ota` (`ROM_IS_OFFICIAL=true`) ou uma chave própria.

## Recompilar o UpdateChecker e o PartProxy

O fonte fica em `src/io/unica/fota/` (`UpdateChecker.java` e
`PartProxy.java`). Os arquivos em `src/stubs/` só servem para compilar contra
as classes do FotaAgent e não vão para a ROM.

```bash
unica/mods/fotaagent/src/build.sh \
    ~/.android-sdk/platforms/android-36/android.jar \
    ~/.android-sdk/build-tools/36.1.0/d8 \
    out/tools/bin/apktool.jar \
    /caminho/de/saida
```

Copie `io/unica/fota/*.smali` da saída para `smali_classes2/io/unica/fota/`
do app decompilado com os patches 0001 a 0017, refaça as edições do 0018
(`DmSessionStarter`, `PollingStartState`, `PollingTimer`, `PollingInfo` e
`IDMApplication`) e gere o patch de novo com `git format-patch --zero-commit`.

## Testes no aparelho

```bash
# Inicia um job direto por uma URL de DD (patch 0008; o shell do ADB já tem DUMP)
adb shell am broadcast --include-stopped-packages -a io.unica.fota.START_UPDATE \
    -n com.wssyncmldm/io.unica.fota.UpdateReceiver --es dd_url <url-do-dd>

# Abre a tela de Atualização de software
adb shell su -c 'am start -a com.wssyncmldm.UserInitEntryActivity'

# Logs
adb logcat -s UnicaFota:* IDM_FOTA:*
```

Para servir arquivos locais ao aparelho: `adb reverse tcp:8765 tcp:8765` e um
servidor HTTP em `127.0.0.1:8765`. O `http.server` do Python não aceita
`Range`, então não serve para testar pacotes em partes nem retomada. O
`adb reverse` e um `adb logcat` em andamento caem quando o adbd reinicia
(logo depois do boot). Logo depois de um `pm clear`, um broadcast só chega com
`--include-stopped-packages`. O proxy pode ser consultado do PC com
`adb forward tcp:47821 tcp:47821`.

Já validado (2026-11-07, y2s): download pelo DD, verificação da assinatura,
instalação automática pelo TWRP (pacote no /cache e no /data), resultados
`DONE` e `FAIL`, limpeza do pacote, polling automático, botão com e sem
atualização, falha de conexão, redirecionamento 302, pacote em 3 partes com
duas quedas de Wi-Fi (o proxy corta, o DlAgent pausa e retoma com `Range`, MD5
certo) e nenhum tráfego para a Samsung com os dados do app limpos.

Em 2026-11-08, ponta a ponta pela release do GitHub: ROM completa de 7,9 GB
em 4 partes, baixada, verificada e instalada pelo app. Depois da instalação,
o job agora fecha (pacote apagado, `SCHEDULE_FINISH`, sem a notificação
"Conectando ao servidor" presa).

Em 2026-11-09, incremental de 163 MB pela release do GitHub. O DlAgent sem o
0020 recebia 500 no 302 do link da release (o `Host: github.com:443` ia junto
para o CDN) e a falha travava em "Conectando ao servidor" (corrigido pelo
0019). O `fota_release.py` agora lista o zip sem divisão como uma parte, então
o pacote passa pelo PartProxy, que segue o redirecionamento sozinho, também
nas builds sem o 0020. Baixado pelo app com o manifesto corrigido.

Falta validar: a hospedagem no Google Drive.
