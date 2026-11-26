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
