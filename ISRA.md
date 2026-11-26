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

- **O quê:** a app fala o protocolo isra (`isra/PROTOCOL.md`, **revisão 2**). Em cada ligação, logo a seguir ao primeiro `APP_START` e antes de ir buscar mensagens, envia `HELLO` com o que sabe fazer (mensagens enviadas no aparelho; posição do telemóvel só se estiver ligada para esse rádio). Guarda o que o rádio responde (funções, revisão, estado do Phone pos e do GPS). Em Definições › Informações do dispositivo, secção Firmware, aparece a linha **Firmware isra** (`caps 0x3, revisão 2`, `não (firmware oficial)` ou `sem resposta`).
- **Porquê:** cada função nova só liga se o rádio disser que a tem. Com o firmware oficial o rádio responde «comando desconhecido» e a app comporta-se como a MeshCore One.
- **Como está feito:** código em `MeshCore/Sources/MeshCore/Isra/` (pacote: construir e ler as tramas, `HELLO` no mesmo passo do `APP_START`) e `MC1/Isra/IsraCenter.swift`. O pacote não vê a condição `ISRA`, por isso só envia `HELLO` (e só salta tramas desconhecidas ao esvaziar a fila, ver 3) depois de a app instalar o `IsraHooks` (só nas versões isra); numa versão sem isra o pacote comporta-se como o oficial.
- **Quando vai o `HELLO`:**
  - Por BLE o rádio guarda as funções até a ligação cair, por isso o `HELLO` vai uma vez por ligação. Noutras ligações (USB, TCP) o rádio apaga-as em cada `APP_START`, por isso aí o `HELLO` vai a seguir a **cada** `APP_START` (a app vê o tipo de ligação ao criar a sessão).
  - Quando se muda a opção da posição do telemóvel, vai outra vez. Se não conseguir sair ou não tiver resposta, fica marcado como pendente e vai com o próximo `APP_START` ou na próxima ligação. Até lá a app ignora os pedidos de posição do rádio.
  - Um rádio que não responde a dois `HELLO` seguidos (e nunca respondeu nessa ligação) passa a ser tratado como firmware sem as extensões até à ligação seguinte: a app deixa de tentar e não perde 3 s em cada `APP_START`. Aparece «sem resposta».
  - Firmware com a revisão 1 (as mensagens do aparelho em tramas 30/31/32 soltas): a app pede outra vez sem a função das mensagens, para o rádio continuar a mandá-las como recebidas com a etiqueta (espelho do isra2). A revisão 2 ou superior é a que liga essa função.
- **Como testar:** ligar ao rádio com o solo-isra e ver a linha Firmware isra; ligar a um rádio com firmware oficial e ver `não (firmware oficial)`, com tudo o resto igual à app oficial. Testes: `cd MeshCore && swift test --filter Isra`.

### 2. Posição do telemóvel para a telemetria

- **O quê:** em Definições › Localização, secção **Posição do telemóvel para a telemetria** (por rádio, desligada de origem). Com ela ligada, quando o rádio pede a posição (o GPS dele está a dormir com o GPS pwr), a app envia a posição do iPhone: logo se tiver uma com menos de 2 minutos, senão pede uma nova ao iOS (precisão de 100 m). Envia também uma vez depois do `HELLO` e, com a autorização «Sempre», quando o iPhone muda bastante de sítio (no máximo de 5 em 5 minutos). A secção mostra a autorização de localização (com botão para pedir «Sempre» ou abrir as Definições do iOS), se o firmware suporta, o estado do «Phone pos» e do GPS no rádio (com o caminho no menu do rádio se estiverem desligados), a hora da última posição enviada e o último erro.
- **Porquê:** a telemetria para os contactos de confiança sai com a posição do iPhone enquanto o GPS do rádio dorme, sem gastar bateria do rádio. A posição fica só na RAM do rádio: nunca em adverts nem na flash.
- **Privacidade:** as coordenadas nunca vão para o registo da app (só a idade e a precisão) nem são guardadas; só a hora do último envio.
- **Limites:** a app responde quando está ligada ao rádio, também em segundo plano (o pedido do rádio acorda a app pelo Bluetooth e ela pede uns segundos extra ao iOS para obter a posição). A mudança de sítio só é vigiada enquanto há ligação. Se o iOS terminar a app, ela **não** volta a ligar-se sozinha por causa da localização: seria preciso arrancar o gestor de ligação fora do ecrã, no arranque em segundo plano, o que mexe no arranque da app oficial (e no limite de tempo do iOS) sem poder ser testado aqui. Nesse caso a posição expira no rádio e o GPS dele volta a acordar, como previsto no protocolo. Abrir a app volta a ligar.
- **Posições que não servem:** uma posição do iOS com precisão pior que 1000 m ou com mais de 10 minutos não é enviada (o rádio recusava-a): aparece «A posição do iPhone era pouco precisa (mais de 1000 m) ou antiga: não foi enviada.».
- **Pausa depois de uma falha:** o rádio pede a posição de minuto a minuto. Depois de uma recusa, de faltar a autorização (ou só «Durante a utilização» com a app em segundo plano), de não haver posição ou de o rádio não responder, a app deixa de responder durante 2, 4, 8 e depois 15 minutos, em vez de tentar um envio condenado a cada pedido. A secção mostra «A app responde ao próximo pedido do rádio depois das HH:MM». A pausa acaba com um envio aceite, uma mudança de autorização, um `HELLO` novo (ligar, «Ler outra vez o estado do rádio») ou ao ligar a opção.
- **Erros:** «O rádio recusou: ligue Phone pos, o GPS e o GPS pwr» (o rádio disse BAD_STATE); «Posição recusada (precisão/idade)» (ILLEGAL_ARG: precisão pior que 1000 m ou mais de 10 minutos).
- **Como testar:** com o rádio em solo-isra, Phone pos, GPS e GPS pwr ligados no rádio: ligar a opção, dar «Sempre» à localização, ver «Última posição enviada» com a hora. Pedir a telemetria do meu rádio a partir do rádio do Rui (contacto de confiança com localização): deve vir a posição do iPhone. Desligar o Phone pos no rádio, tocar em «Ler outra vez o estado do rádio» e ver o aviso.

### 3. Mensagens escritas no aparelho

- **O quê:** as mensagens escritas no teclado do rádio (revisão 2: tramas `0xE1` com as sub-operações `0x20` SENT_DM, `0x21` SENT_CHANNEL e `0x22` SENT_STATUS, que chegam como resposta ao `SYNC_NEXT_MESSAGE`) aparecem na app como **enviadas por mim**, na conversa certa, sem notificação, sem contar como por ler e sem mexer no «ouvido há». Mensagens diretas: estado enviado, entregue (com o tempo de ida e volta), a repetir (tentativa) ou falhada; o ✓ de entrega chega em direto (a app calcula os códigos de confirmação das tentativas 0 a 3) ou mais tarde pela SENT_STATUS, se a entrega aconteceu com o telemóvel longe. Canais: o texto sem o «nome: », com as repetições ouvidas contadas como nas mensagens enviadas pela app. A mesma mensagem não aparece duas vezes (destinatário, hora e texto). A hora de ordenação é a do rádio, ou a de chegada se o relógio do rádio estiver errado.
- **Porquê:** substitui o espelho do isra2 («texto · enviada pelo Wio» do lado recebido). O rádio só manda estas tramas a uma app que as pediu no `HELLO`; para as outras continua a converter em mensagem recebida com a etiqueta. Na revisão 1 eram as tramas 30, 31 e 32 soltas, que são os próximos códigos livres da MeshCore oficial e podiam um dia chocar com eles; a revisão 2 pô-las debaixo do `0xE1`. A app já não lê as 30/31/32.
- **Só com a função combinada:** a app só guarda estas tramas se o `HELLO` dessa ligação tiver combinado a função das mensagens (revisão 2 ou superior). Com o firmware oficial, ou se o `HELLO` falhou, não guarda nada.
- **Robustez (só nas versões isra):** se, ao esvaziar a fila de mensagens, chegar uma destas tramas ou outra resposta com um código que a app não conhece, a app passa à seguinte em vez de esperar o tempo limite e parar (na MeshCore One oficial isso faz parar a receção das mensagens seguintes). Numa versão sem isra o pacote faz como o oficial.
- **Limites conhecidos:** o código de confirmação não leva o destinatário: uma mensagem direta escrita no rádio e outra enviada pela app com **o mesmo texto no mesmo segundo** têm o mesmo código, e a confirmação de uma pode marcar a outra como entregue (muito raro). Uma confirmação atrasada mostra a última tentativa e o seu tempo, não a que foi confirmada.
- **Como está feito:** `MC1Services/Sources/MC1Services/Isra/IsraSentMessageService.swift` (liga-se antes da primeira leitura de mensagens, só nas versões isra) e uma alteração pequena em `MeshCoreSession+Messaging.swift`.
- **Como testar:** escrever no rádio uma mensagem direta a um contacto de teste com a app ligada: aparece na conversa do contacto do meu lado, sem notificação, e passa a entregue quando o contacto confirma. Repetir com a app fechada e abri-la depois: a mensagem aparece e o estado é atualizado. Escrever no #ping a partir do rádio: aparece como minha e conta as repetições. Testes: `cd MC1Services && swift test --filter IsraSentMessage`; `cd MeshCore && swift test --filter Isra`.
### Definições e proteções do rádio

Regra geral: a app não reescreve definições do rádio pelas costas. As escritas do registo "other params" (adição manual, multi-acks, os três modos de telemetria, política de posição nos adverts) levam sempre os seis campos; a app relê o SELF_INFO antes de cada escrita, para os campos que não muda irem com o valor real do rádio e não com uma cópia antiga.

1. **Telemetria por categoria** (`MC1/Isra/Settings/IsraTelemetrySection.swift`, `IsraTelemetryAccessViews.swift`; serviço em `MC1Services/Sources/MC1Services/Isra/IsraTelemetryAccess.swift`).
   - O quê: em Definições avançadas › Telemetria há três escolhas, Bateria e estado / Localização / Sensores, cada uma Ninguém / Contactos autorizados / Todos (0/1/2). Cada escolha grava só o seu modo. A ligação «Contactos autorizados» está sempre visível e mostra, por contacto, o que pode pedir: Nada / Estado / Estado + localização / Estado + sensores / Tudo. A mesma escolha aparece na ficha de cada contacto (secção «Telemetria deste rádio»).
   - Porquê: na oficial, o interruptor «só contactos de confiança» reescrevia os três modos de uma vez, o da localização copiava o valor da bateria, a lista só aparecia com bateria = 1 e cada contacto recebia ou perdia as três autorizações juntas (0x0E). A minha configuração (bateria 2, localização 1, sensores 0) não se conseguia manter pela app.
   - Como: os modos vão por escrita de um só campo; nos contactos só mudam os bits 0x02/0x04/0x08, a partir do registo atual do rádio (o favorito 0x01 e a CLI remota 0x10 ficam como o rádio os tem).
   - Testar: com o rádio em 2/1/0, mudar Sensores para Ninguém e voltar a pôr Contactos autorizados; confirmar por USB com a meshcli que bateria (2) e localização (1) não mudaram. Num contacto favorito, escolher «Estado + localização» e confirmar pela meshcli que as flags ficam 7 (favorito mantido).
2. **A app nunca mexe no GPS do rádio nem grava a posição do telemóvel sozinha** (`IsraLocationSettingsSection.swift`, `IsraLocationPicker.swift`, `IsraRadioWrites.advertRefreshesLocation`, `set lat`/`set lon` na CLI).
   - O quê: guardar uma posição à mão (mapa ou CLI) já não desliga o GPS do rádio. Enviar um advert pela app (menu do Bluetooth, `advert` na CLI, Siri) **já não grava a posição do iPhone no rádio** (comando 14) **nem liga o GPS do rádio**: o advert leva o que o rádio já tem. Por isso saíram da secção Localização as linhas «Atualizar localização automaticamente» e «Fonte de GPS», que só serviam esse caminho. Só o interruptor «Ativar GPS do dispositivo» liga ou desliga o GPS. Os rodapés explicam.
   - Porquê: na oficial havia três sítios que desligavam o GPS sem o dizer, e com o GPS desligado a telemetria deixa de levar posição. E o firmware isra4 guarda a posição do comando 14 na flash, no SELF_INFO e em todos os adverts: com a posição nos adverts ligada no aparelho, cada advert enviado pela app publicava a posição do iPhone (ou ligava o GPS do rádio sem avisar).
   - Testar: com o GPS do rádio ligado, guardar uma posição no mapa; o interruptor continua ligado e o aparelho também mostra o GPS ligado. Com o GPS do rádio desligado e a posição do rádio a 0,0, enviar um advert pela app e confirmar por USB com a meshcli que a posição continua 0,0 e o GPS desligado.
3. **Posição nos adverts só de leitura** (`IsraLocationSettingsSection.swift`, ganchos em Nós, Mensagens diretas e CLI `set multi.acks`).
   - O quê: na secção Localização aparece «Posição nos adverts: Desligada / Ligada», lida do rádio (do último SELF_INFO: o aparelho não avisa a app quando a política muda, por isso o valor mostrado **pode estar desatualizado** até à próxima leitura, por exemplo ao voltar a ligar). Se estiver ligada aparece um aviso a dizer onde se desliga no aparelho (Settings › All settings › Privacy › Advert pos). O interruptor «Partilhar localização publicamente» desapareceu e nenhum caminho da app grava a política (nem o mapa, nem o interruptor do GPS).
   - Porquê: a decisão é adverts sem posição; a política só se muda no aparelho.
   - Testar: com a política 0, mudar multi-acks e a adição de contactos e confirmar por USB com a meshcli que a política continua 0. Mudar a política no aparelho, voltar à app e ver o aviso.
4. **Proteções do rádio** (`IsraDeviceActionsSection.swift`, `IsraBluetoothSection.swift`, `MC1Services/…/Isra/IsraCLIGuard.swift`).
   - Reiniciar: o botão «Reiniciar dispositivo» e o `reboot` na CLI do rádio local já não reiniciam; mostram «O Solo não deve ser reiniciado por software: desliga o interruptor 15 s.». O `reboot` numa sessão remota (repetidor) continua a funcionar. Desligar continua.
   - PIN: só «Aleatório (no ecrã)» (grava 0) ou «Personalizado» (6 dígitos, 123456 recusado). Um 123456 já gravado aparece como personalizado, com aviso. Mudar o PIN já não reinicia o rádio: o rádio grava-o e usa-o depois de desligar e voltar a ligar (interruptor 15 s); a app lê-o de volta e diz isso.
   - OTA: `start ota` e qualquer comando OTA/DFU são recusados na CLI, local e remota (Ferramentas › CLI e a CLI de repetidores, salas, sensores e rádios remotos), com o mesmo texto, e saíram das sugestões da CLI local. A app não tem outro caminho de OTA.
   - Porquê: o Solo pode ficar parado no arranque depois de um reinício por software; firmware só por USB; 123456 é conhecido de toda a gente.
   - Testar: tocar em Reiniciar e escrever `reboot` e `start ota` na CLI (nada sai para o rádio); mudar o PIN para aleatório e confirmar no ecrã do rádio depois de o desligar e ligar.
5. **CLI: chaves desconhecidas vão para o rádio**.
   - O quê: `get`/`set` de uma chave que a app não conhece (nem chave própria nem custom var listada pelo rádio) segue para a consola do rádio (comando 66) em vez de responder «Unknown var». As chaves que a app conhece continuam a ser tratadas por ela.
   - Porquê: as chaves da consola do Solo (ex. `telemetry.loc.phone`, `gps.interval`) passam a funcionar na CLI da app.
   - Testar: na CLI, `get telemetry.loc.phone` devolve o valor do rádio; `get name` continua a vir da app.

Testes automáticos: `swift test --package-path MC1Services --filter Isra` (bits 0x0E, modos, escrita do contacto a partir do registo do rádio, recusas da CLI); na app, `MC1Tests/Isra` (inclui a recusa de OTA na CLI remota).

### Privacidade nos registos

- As linhas de registo da oficial que escreviam coordenadas (localização do iPhone em `LocationService`, posição na importação de configuração e no `setLocationVerified`, incluindo a falha de verificação) passaram a ter um texto fixo, sem latitude nem longitude. O código isra já não registava coordenadas.

### Ferramentas

- **Registo de escritas no rádio** (Definições › Avançadas › Ferramentas isra). Cada comando que a app grava no rádio fica registado: hora, o quê, valor antigo → novo (quando o rádio já o tinha dito), quem o pediu ("pela app" ou "automático: acerto do relógio / fuso horário / reenvio de mensagem direta / recuperação do caminho") e a resposta do rádio (OK, recusado, não enviado, sem resposta atribuível). Cobre relógio, nome, parâmetros de rádio, potência, posição dos adverts, afinação (af), canais, contactos (adicionar, alterar autorizações, remover, repor caminho), PIN, outros parâmetros, variáveis, adição automática, hash dos caminhos, âmbito predefinido, chave privada, reposição de fábrica, reinício e `set …` na CLI. Últimas 500 entradas, guardadas só no telemóvel; partilhar como texto e limpar. Nunca regista posições, chaves nem os dígitos do PIN. *Porquê:* a app oficial grava sozinha (hora quando há desvio, `tz.offset`) e reenvia outros parâmetros sem avisar. *Como:* um ponto de observação no envio da sessão (`IsraFrameTap`), sem mudar o que é enviado. *Testar:* ligar ao rádio, mudar uma definição na app e abrir o registo; desligar e voltar a ligar com o relógio do rádio desacertado e ver "automático: acerto do relógio".
- **Tempo de emissão deste rádio** (Definições › O meu dispositivo › Sobre o dispositivo). Lê os contadores do próprio rádio uma vez por minuto (CMD_GET_STATS: segundos a emitir e tempo ligado desde o arranque; não emite nada no ar) e mostra a percentagem na última hora, nos últimos 10 minutos, desde que ligou e desde o arranque, comparada com o limite legal de 10 %. Resolução de 1 s (o firmware conta em segundos inteiros); o intervalo coberto aparece quando ainda não há uma hora de leituras. *Testar:* enviar um advert por inundação e "Ler agora": o TX sobe 1–2 s.
- **Importar configuração com diferenças**. Antes de aplicar, mostra campo a campo "rádio agora → ficheiro", com o "rádio agora" lido de novo do rádio (SELF_INFO) ao abrir a pré-visualização, não da cópia guardada na app. A chave privada, os modos de telemetria e a política de posição nos adverts ficam de fora por omissão (só entram se ligar o interruptor de cada um); com eles de fora, a app nem os envia ao rádio (o rádio mantém os seus). O formato do ficheiro não traz PIN. Logo antes de gravar os "outros parâmetros" (adição manual, multi-acks, telemetria, política) a app relê o SELF_INFO, para os campos que ficaram de fora irem com o valor real do rádio e nunca com uma cópia antiga (por exemplo uma política de posição mudada no aparelho depois da última leitura). Continua a ser preciso carregar em Aplicar e confirmar. (Se o ficheiro trouxer a chave privada e ela for aplicada, a releitura não é precisa: a ligação nova com a identidade importada acabou de ler o SELF_INFO.) *Testes da oficial:* os testes de importação da MeshCore One importam ficheiros com chave privada e telemetria e esperam que sejam gravados; passam porque o pacote de testes traz uma classe-marca (`MC1Tests/Isra/IsraUpstreamTestsMarker.swift`, lida por `MC1/Isra/IsraTestHost.swift`): com ela, o guarda partilhado começa com tudo incluído e a app não manda `HELLO` aos rádios simulados dos testes (nunca respondem e cada um custava 3 s). A app não tem essa classe, por isso uma importação a sério começa sempre com tudo de fora. Os ficheiros de teste da oficial não foram alterados. *Testar:* exportar a configuração, abrir o ficheiro em Importar e confirmar que a telemetria aparece riscada como "não aplicado".
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
