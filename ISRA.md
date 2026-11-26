# isra: versão própria da MeshCore One

Esta é a app do meu iPhone: a [MeshCore One](https://github.com/Avi0n/MeshCoreOne) oficial (GPL-3.0) com algumas alterações por cima, para o meu rádio com o firmware [solo-isra](./isra/PROTOCOL.md) (MeshCore Solo + isra4). Uso pessoal; o código está público porque é um fork de um repositório público e a GPL assim o pede.

- Ramo **`isra`** (por omissão): a versão que vai para o iPhone. Um commit por alteração, por cima da versão oficial indicada em `.isra-base`.
- Ramos `main` / `dev`: cópias da MeshCore One, sem alterações.
- `.isra-version`: o nome desta versão.
- Instala-se como app separada, **MC1 isra** (`io.github.ghostemane.mc1isra`); a MeshCore One da App Store pode ficar instalada.

Versão atual: **v1.7.1-isra1**, sobre a MeshCore One **v1.7.1**.

## Como está montado (para as atualizações da app passarem sem conflitos)

- Os ficheiros do autor quase não mudam. O código novo fica em `MC1/Isra/`, os textos em `Isra.strings` (en, pt), a compilação em `isra.yml` + `isra/`.
- `isra.yml` inclui o `project.yml` do autor e muda só: o identificador da app, o Info.plist (cópia com as chaves extra, feita por `isra/make-plist.sh`), as condições `ISRA` e `SIDELOAD`, e tira a fase do SwiftGen (o `L10n.swift` vem pronto do autor).
- O protocolo com o firmware está em `isra/PROTOCOL.md` (igual ao do repositório do firmware). Cada função nova só liga se o rádio disser que a tem (`0xE1` HELLO); com outro firmware a app comporta-se como a oficial.

## As alterações

(Preenchido à medida que entram: o quê, porquê, como testar.)

### 1. Protocolo 0xE1 e HELLO

- **O quê:** a app fala o protocolo isra (`isra/PROTOCOL.md`, revisão 1). Em cada ligação, logo a seguir ao primeiro `APP_START` e antes de ir buscar mensagens, envia `HELLO` com o que sabe fazer (mensagens enviadas no aparelho; posição do telemóvel só se estiver ligada para esse rádio). Guarda o que o rádio responde (funções, revisão, estado do Phone pos e do GPS). Em Definições › Informações do dispositivo, secção Firmware, aparece a linha **Firmware isra** (`caps 0x3, revisão 1`, ou `não (firmware oficial)`).
- **Porquê:** cada função nova só liga se o rádio disser que a tem. Com o firmware oficial o rádio responde «comando desconhecido» e a app comporta-se como a MeshCore One.
- **Como está feito:** código em `MeshCore/Sources/MeshCore/Isra/` (pacote: construir e ler as tramas, `HELLO` no mesmo passo do `APP_START`) e `MC1/Isra/IsraCenter.swift`. O pacote não vê a condição `ISRA`, por isso só envia `HELLO` depois de a app instalar o `IsraHooks` (só nas versões isra). Por BLE o rádio guarda as funções até a ligação cair, por isso o `HELLO` vai uma vez por ligação (e outra vez quando se muda a opção da posição).
- **Como testar:** ligar ao rádio com o solo-isra e ver a linha Firmware isra; ligar a um rádio com firmware oficial e ver `não (firmware oficial)`, com tudo o resto igual à app oficial. Testes: `cd MeshCore && swift test --filter Isra`.

### 2. Posição do telemóvel para a telemetria

- **O quê:** em Definições › Localização, secção **Posição do telemóvel para a telemetria** (por rádio, desligada de origem). Com ela ligada, quando o rádio pede a posição (o GPS dele está a dormir com o GPS pwr), a app envia a posição do iPhone: logo se tiver uma com menos de 2 minutos, senão pede uma nova ao iOS (precisão de 100 m). Envia também uma vez depois do `HELLO` e, com a autorização «Sempre», quando o iPhone muda bastante de sítio (no máximo de 5 em 5 minutos). A secção mostra a autorização de localização (com botão para pedir «Sempre» ou abrir as Definições do iOS), se o firmware suporta, o estado do «Phone pos» e do GPS no rádio (com o caminho no menu do rádio se estiverem desligados), a hora da última posição enviada e o último erro.
- **Porquê:** a telemetria para os contactos de confiança sai com a posição do iPhone enquanto o GPS do rádio dorme, sem gastar bateria do rádio. A posição fica só na RAM do rádio: nunca em adverts nem na flash.
- **Privacidade:** as coordenadas nunca vão para o registo da app (só a idade e a precisão) nem são guardadas; só a hora do último envio.
- **Limites:** a app responde quando está ligada ao rádio, também em segundo plano (o pedido do rádio acorda a app pelo Bluetooth e ela pede uns segundos extra ao iOS para obter a posição). A mudança de sítio só é vigiada enquanto há ligação. Se o iOS terminar a app, ela **não** volta a ligar-se sozinha por causa da localização: seria preciso arrancar o gestor de ligação fora do ecrã, no arranque em segundo plano, o que mexe no arranque da app oficial (e no limite de tempo do iOS) sem poder ser testado aqui. Nesse caso a posição expira no rádio e o GPS dele volta a acordar, como previsto no protocolo. Abrir a app volta a ligar.
- **Erros:** «O rádio recusou: ligue Phone pos, o GPS e o GPS pwr» (o rádio disse BAD_STATE); «Posição recusada (precisão/idade)» (ILLEGAL_ARG: precisão pior que 1000 m ou mais de 10 minutos).
- **Como testar:** com o rádio em solo-isra, Phone pos, GPS e GPS pwr ligados no rádio: ligar a opção, dar «Sempre» à localização, ver «Última posição enviada» com a hora. Pedir a telemetria do meu rádio a partir do rádio do Rui (contacto de confiança com localização): deve vir a posição do iPhone. Desligar o Phone pos no rádio, tocar em «Ler outra vez o estado do rádio» e ver o aviso.

### 3. Mensagens escritas no aparelho

- **O quê:** as mensagens escritas no teclado do rádio (tramas 30, 31 e 32) aparecem na app como **enviadas por mim**, na conversa certa, sem notificação, sem contar como por ler e sem mexer no «ouvido há». Mensagens diretas: estado enviado, entregue (com o tempo de ida e volta), a repetir (tentativa) ou falhada; o ✓ de entrega chega em direto (a app calcula os códigos de confirmação das tentativas 0 a 3) ou mais tarde pela trama 32, se a entrega aconteceu com o telemóvel longe. Canais: o texto sem o «nome: », com as repetições ouvidas contadas como nas mensagens enviadas pela app. A mesma mensagem não aparece duas vezes (destinatário, hora e texto). A hora de ordenação é a do rádio, ou a de chegada se o relógio do rádio estiver errado.
- **Porquê:** substitui o espelho do isra2 («texto · enviada pelo Wio» do lado recebido). O rádio só manda estas tramas a uma app que as pediu no `HELLO`; para as outras continua a converter em mensagem recebida com a etiqueta.
- **Robustez (vale também para outros firmwares):** se, ao esvaziar a fila de mensagens, chegar uma trama que a app não conhece, a app passa à seguinte em vez de esperar o tempo limite e parar. Na MeshCore One oficial isso faz parar a receção das mensagens seguintes.
- **Como está feito:** `MC1Services/Sources/MC1Services/Isra/IsraSentMessageService.swift` (liga-se antes da primeira leitura de mensagens, só nas versões isra) e uma alteração pequena em `MeshCoreSession+Messaging.swift`.
- **Como testar:** escrever no rádio uma mensagem direta a um contacto de teste com a app ligada: aparece na conversa do contacto do meu lado, sem notificação, e passa a entregue quando o contacto confirma. Repetir com a app fechada e abri-la depois: a mensagem aparece e o estado é atualizado. Escrever no #ping a partir do rádio: aparece como minha e conta as repetições. Testes: `cd MC1Services && swift test --filter IsraSentMessage`; `cd MeshCore && swift test --filter Isra`.
### Definições e proteções do rádio

Regra geral: a app não reescreve definições do rádio pelas costas. As escritas do registo "other params" (adição manual, multi-acks, os três modos de telemetria, política de posição nos adverts) levam sempre os seis campos; a app relê o SELF_INFO antes de cada escrita, para os campos que não muda irem com o valor real do rádio e não com uma cópia antiga.

1. **Telemetria por categoria** (`MC1/Isra/Settings/IsraTelemetrySection.swift`, `IsraTelemetryAccessViews.swift`; serviço em `MC1Services/Sources/MC1Services/Isra/IsraTelemetryAccess.swift`).
   - O quê: em Definições avançadas › Telemetria há três escolhas, Bateria e estado / Localização / Sensores, cada uma Ninguém / Contactos autorizados / Todos (0/1/2). Cada escolha grava só o seu modo. A ligação «Contactos autorizados» está sempre visível e mostra, por contacto, o que pode pedir: Nada / Estado / Estado + localização / Estado + sensores / Tudo. A mesma escolha aparece na ficha de cada contacto (secção «Telemetria deste rádio»).
   - Porquê: na oficial, o interruptor «só contactos de confiança» reescrevia os três modos de uma vez, o da localização copiava o valor da bateria, a lista só aparecia com bateria = 1 e cada contacto recebia ou perdia as três autorizações juntas (0x0E). A minha configuração (bateria 2, localização 1, sensores 0) não se conseguia manter pela app.
   - Como: os modos vão por escrita de um só campo; nos contactos só mudam os bits 0x02/0x04/0x08, a partir do registo atual do rádio (o favorito 0x01 e a CLI remota 0x10 ficam como o rádio os tem).
   - Testar: com o rádio em 2/1/0, mudar Sensores para Ninguém e voltar a pôr Contactos autorizados; confirmar por USB com a meshcli que bateria (2) e localização (1) não mudaram. Num contacto favorito, escolher «Estado + localização» e confirmar pela meshcli que as flags ficam 7 (favorito mantido).
2. **A app nunca desliga o GPS do rádio** (`IsraLocationSettingsSection.swift`, `IsraLocationPicker.swift`, `set lat`/`set lon` na CLI).
   - O quê: escolher o GPS do telemóvel, desligar a atualização automática ou guardar uma posição à mão (mapa ou CLI) já não desligam o GPS do rádio. Só o interruptor «Ativar GPS do dispositivo» o liga ou desliga. O rodapé explica.
   - Porquê: na oficial havia três sítios que desligavam o GPS sem o dizer, e com o GPS desligado a telemetria deixa de levar posição.
   - Testar: com o GPS do rádio ligado, mudar a fonte para o telemóvel, desligar a atualização automática e guardar uma posição no mapa; o interruptor continua ligado e o aparelho também mostra o GPS ligado.
3. **Posição nos adverts só de leitura** (`IsraLocationSettingsSection.swift`, ganchos em Nós, Mensagens diretas e CLI `set multi.acks`).
   - O quê: na secção Localização aparece «Posição nos adverts: Desligada / Ligada», lida do rádio. Se estiver ligada aparece um aviso a dizer onde se desliga no aparelho (Settings › All settings › Privacy › Advert pos). O interruptor «Partilhar localização publicamente» desapareceu e nenhum caminho da app grava a política (nem o mapa, nem o interruptor do GPS).
   - Porquê: a decisão é adverts sem posição; a política só se muda no aparelho.
   - Testar: com a política 0, mudar multi-acks e a adição de contactos e confirmar por USB com a meshcli que a política continua 0. Mudar a política no aparelho, voltar à app e ver o aviso.
4. **Proteções do rádio** (`IsraDeviceActionsSection.swift`, `IsraBluetoothSection.swift`, `MC1Services/…/Isra/IsraCLIGuard.swift`).
   - Reiniciar: o botão «Reiniciar dispositivo» e o `reboot` na CLI do rádio local já não reiniciam; mostram «O Solo não deve ser reiniciado por software: desliga o interruptor 15 s.». O `reboot` numa sessão remota (repetidor) continua a funcionar. Desligar continua.
   - PIN: só «Aleatório (no ecrã)» (grava 0) ou «Personalizado» (6 dígitos, 123456 recusado). Um 123456 já gravado aparece como personalizado, com aviso. Mudar o PIN já não reinicia o rádio: o rádio grava-o e usa-o depois de desligar e voltar a ligar (interruptor 15 s); a app lê-o de volta e diz isso.
   - OTA: `start ota` e qualquer comando OTA/DFU são recusados na CLI, local e remota, e saíram das sugestões. A app não tem outro caminho de OTA.
   - Porquê: o Solo pode ficar parado no arranque depois de um reinício por software; firmware só por USB; 123456 é conhecido de toda a gente.
   - Testar: tocar em Reiniciar e escrever `reboot` e `start ota` na CLI (nada sai para o rádio); mudar o PIN para aleatório e confirmar no ecrã do rádio depois de o desligar e ligar.
5. **CLI: chaves desconhecidas vão para o rádio**.
   - O quê: `get`/`set` de uma chave que a app não conhece (nem chave própria nem custom var listada pelo rádio) segue para a consola do rádio (comando 66) em vez de responder «Unknown var». As chaves que a app conhece continuam a ser tratadas por ela.
   - Porquê: as chaves da consola do Solo (ex. `telemetry.loc.phone`, `gps.interval`) passam a funcionar na CLI da app.
   - Testar: na CLI, `get telemetry.loc.phone` devolve o valor do rádio; `get name` continua a vir da app.

Testes automáticos: `swift test --package-path MC1Services --filter Isra` (bits 0x0E, modos, escrita do contacto a partir do registo do rádio, recusas da CLI).
### Ferramentas

- **Registo de escritas no rádio** (Definições › Avançadas › Ferramentas isra). Cada comando que a app grava no rádio fica registado: hora, o quê, valor antigo → novo (quando o rádio já o tinha dito), quem o pediu ("pela app" ou "automático: acerto do relógio / fuso horário / reenvio de mensagem direta / recuperação do caminho") e a resposta do rádio (OK, recusado, não enviado, sem resposta atribuível). Cobre relógio, nome, parâmetros de rádio, potência, posição dos adverts, afinação (af), canais, contactos (adicionar, alterar autorizações, remover, repor caminho), PIN, outros parâmetros, variáveis, adição automática, hash dos caminhos, âmbito predefinido, chave privada, reposição de fábrica, reinício e `set …` na CLI. Últimas 500 entradas, guardadas só no telemóvel; partilhar como texto e limpar. Nunca regista posições, chaves nem os dígitos do PIN. *Porquê:* a app oficial grava sozinha (hora quando há desvio, `tz.offset`) e reenvia outros parâmetros sem avisar. *Como:* um ponto de observação no envio da sessão (`IsraFrameTap`), sem mudar o que é enviado. *Testar:* ligar ao rádio, mudar uma definição na app e abrir o registo; desligar e voltar a ligar com o relógio do rádio desacertado e ver "automático: acerto do relógio".
- **Tempo de emissão deste rádio** (Definições › O meu dispositivo › Sobre o dispositivo). Lê os contadores do próprio rádio uma vez por minuto (CMD_GET_STATS: segundos a emitir e tempo ligado desde o arranque; não emite nada no ar) e mostra a percentagem na última hora, nos últimos 10 minutos, desde que ligou e desde o arranque, comparada com o limite legal de 10 %. Resolução de 1 s (o firmware conta em segundos inteiros); o intervalo coberto aparece quando ainda não há uma hora de leituras. *Testar:* enviar um advert por inundação e "Ler agora": o TX sobe 1–2 s.
- **Importar configuração com diferenças**. Antes de aplicar, mostra campo a campo "rádio agora → ficheiro". A chave privada, os modos de telemetria e a política de posição nos adverts ficam de fora por omissão (só entram se ligar o interruptor de cada um); com eles de fora, a app nem os envia ao rádio (o rádio mantém os seus). O formato do ficheiro não traz PIN. Continua a ser preciso carregar em Aplicar e confirmar. *Testar:* exportar a configuração, abrir o ficheiro em Importar e confirmar que a telemetria aparece riscada como "não aplicado".
- **Reenvios de mensagens diretas**. A versão 1.7.1 já tem a definição (Avançadas › Mensagens diretas: tentativas diretas 1–4, voltar a inundação e tentativas por inundação). Por baixo aparece agora o pior caso por mensagem (de origem: 8 envios, 4 diretos + 4 por inundação). Não muda os valores de origem.
- **Âmbito efetivo ao escrever num canal**. Uma linha pequena por cima da caixa de texto diz que âmbito a mensagem vai levar: o da app (região do canal na app, que se sobrepõe ao do rádio, incluindo o âmbito por canal do Solo), nenhum forçado pela app, ou "decide o rádio" (o predefinido, ou no Solo o escolhido para o canal no aparelho, que a app não consegue ler). Tocar mostra a explicação.

## Compilar e instalar

Precisa do Xcode e do XcodeGen (`brew install xcodegen`). Não precisa de `make` nem do SwiftGen.

1. Xcode › Settings › Accounts: acrescentar o Apple ID. Anotar o ID da "Personal Team".
2. Criar `dev.yml` (não vai para o GitHub):
   ```
   settings:
     base:
       DEVELOPMENT_TEAM: ABCDE12345
   ```
3. iPhone: Definições › Privacidade e segurança › Modo de programador (reinicia). Ligar por cabo e confiar no Mac.
4. `isra/build.sh phone` compila e instala.
5. Na primeira vez: Definições › Geral › VPN e gestão de dispositivos › confiar no programador.
6. Conta gratuita: a instalação expira ao fim de 7 dias. Correr `isra/build.sh phone` outra vez antes disso (os dados ficam).

Só uma app pode estar ligada ao rádio de cada vez: fechar a MeshCore One da App Store (deslizar para cima) antes de abrir a MC1 isra. O histórico de mensagens não passa de uma para a outra; contactos e canais vêm do rádio.

Simulador (sem conta): `isra/build.sh sim`.

## Quando sai uma versão nova da MeshCore One

A Action **isra - nova versão da MeshCore One?** vê todos os dias se saiu versão nova. Se sim, tenta reaplicar a `isra` por cima, só dentro da Action, e abre uma issue a dizer se reaplica sem conflitos ou onde choca. Não envia nem instala nada.

À mão:

```
git clone https://github.com/GHOSTEMANE/meshcore-one-isra.git && cd meshcore-one-isra   # uma vez
git remote add avi0n https://github.com/Avi0n/MeshCoreOne.git                          # uma vez
git fetch avi0n --tags
git checkout isra
git rebase --onto vX.Y.Z "$(cat .isra-base)" isra
echo vX.Y.Z > .isra-base ; echo vX.Y.Z-isra1 > .isra-version
isra/build.sh sim      # compila?
```

Depois: testar, rever este ficheiro, `git push --force-with-lease origin isra`, e `isra/build.sh phone`.

As Actions do autor estão desligadas neste fork (`gh workflow disable`): correm num runner próprio dele e uma delas cria tags e releases.
