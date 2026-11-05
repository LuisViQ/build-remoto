# Build Remoto

App nativo de macOS (SwiftUI) que reúne o desenvolvimento de apps React Native/Expo num lugar só. O trabalho pesado pode rodar em outra máquina: o código fica no Mac, e o build acontece num PC com WSL. Também funciona só com o Mac.

## Funcionalidades

- **Rodar:** console, Metro, builds, APKs e histórico, no PC ou no Mac.
- **Celular:** espelhamento com controle, prints, gravação, logcat, relatório de bug, deep links e localização falsa com rotas.
- **Git:** linha do tempo com grafo, branches, merge revisado arquivo por arquivo e todo comando mostrado antes de rodar.
- **Versões:** relatório antes de agir, passos que podem ser pulados e changelog com os commits da branch.
- **Saúde:** dependências, auditoria e composição do APK.
- **Realm:** visualizador e editor do banco do celular, de backup `.zip` ou de arquivo `.realm`, com AsyncStorage.
- **Notas:** editor no estilo Notion, nota rápida global, PDF e tela com todas as notas em lista ou quadro.
- **Entregas e daily:** relatório de fim de demanda e resumo para a daily, gerados com IA a partir de commits, merges, código e notas.

## Requisitos

- Mac com Apple Silicon e macOS 14 ou mais novo
- Xcode Command Line Tools
- Opcional: PC com Windows e WSL para os builds remotos
- Opcional: um provedor de IA configurado no app, para os resumos

## Compilar

```sh
./make-app.sh   # instala em ~/Applications
./make-dmg.sh   # gera o instalador na Mesa
```

A tela de boas-vindas confere e instala o que falta. O app não é assinado; veja `LEIA-ME.txt`.

## Configurar o PC (opcional)

1. No WSL, ative o `sshd` na porta 2222 e copie `scripts/pc/*` para `~/.local/bin`.
2. No Mac, copie `scripts/mac/*` para `~/.local/bin` e crie o alias no `~/.ssh/config`:

   ```
   Host pc-build
     HostName <ip do PC>
     Port 2222
     User <usuário do WSL>
     HostKeyAlias pc-build
   ```

3. Liste os projetos em `~/.config/build-remoto/projetos`, um caminho por linha, e rode `build-remoto setup`.

## Ajustes opcionais

```sh
defaults write dev.buildremoto.app aws.ssoURL https://SEU-PORTAL.awsapps.com/start/   # login AWS SSO
defaults write dev.buildremoto.app pc.usuarioWindows NOME                             # vários usuários no Windows
export BR_TAILSCALE_IP=100.x.y.z                                                      # opção Tailscale do pc-rede
```

## Privacidade

Os recursos de IA enviam commits, notas e, se a opção estiver ligada, código ao provedor escolhido. Desligue "Ler o código alterado" se o seu projeto não permitir isso.
