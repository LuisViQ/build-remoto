import SwiftUI

// MARK: - Tudo o que o Mac precisa para usar o Build Remoto (sem o PC)
//
// Verifica cada item e monta um script de instalação, aberto no Terminal (precisa da senha do
// Mac para o Homebrew e o Java). Os itens opcionais têm instalação separada.

struct Requisito: Identifiable {
    enum Grupo: String, CaseIterable { case essencial = "Essencial", codigo = "Acesso ao código (AWS CodeCommit)", android = "Android", ios = "iOS (opcional)", extra = "Extras (opcional)" }
    enum Estado { case ok, falta, aviso, verificando }

    let id: String
    let nome: String
    let paraQue: String
    let grupo: Grupo
    var estado: Estado = .verificando
    var detalhe = ""
    /// Passo do script de instalação (bash). nil = instalação manual (ver `comoInstalar`)
    var script: String?
    var comoInstalar = ""
    var opcional: Bool { grupo == .ios || grupo == .extra }
}

@MainActor
final class Requisitos: ObservableObject {
    @Published var itens: [Requisito] = Requisitos.catalogo()
    @Published var verificando = false

    var faltandoEssenciais: [Requisito] { itens.filter { !$0.opcional && $0.estado == .falta && visivel($0) } }

    /// O grupo da AWS só aparece se algum app usa CodeCommit (ou se nenhum app foi configurado ainda)
    func visivel(_ r: Requisito) -> Bool {
        r.grupo != .codigo || Config.projetos.isEmpty || AwsSSO.usaCodeCommit()
    }

    /// Script que roda "yarn install" em cada app sem node_modules
    var scriptDeps: String {
        let pastas = Config.projetos.map { Config.pasta($0) }.filter { !FileManager.default.fileExists(atPath: "\($0)/node_modules") }
        return pastas.map { "passo \"yarn install em \(($0 as NSString).lastPathComponent)\"; (cd \(Adb.aspas($0)) && yarn install --frozen-lockfile)" }.joined(separator: "\n")
    }

    static let sdk = "$HOME/Library/Android/sdk"
    /// Portal de login (SSO). Defina com: defaults write <bundle id> aws.ssoURL https://SEU-PORTAL.awsapps.com/start/
    static var ssoURL: String { UserDefaults.standard.string(forKey: "aws.ssoURL") ?? "https://SEU-PORTAL.awsapps.com/start/" }

    static func catalogo() -> [Requisito] {
        let sdk = Requisitos.sdk
        return [
            Requisito(id: "macos", nome: "macOS 14 ou mais novo", paraQue: "o próprio Build Remoto", grupo: .essencial,
                      comoInstalar: "Atualize em Ajustes do Sistema → Geral → Atualização de Software"),
            Requisito(id: "disco", nome: "Espaço livre (30 GB ou mais)", paraQue: "SDK do Android, dependências e builds", grupo: .essencial,
                      comoInstalar: "Libere espaço (Diagnóstico → Armazenamento do Mac)"),
            Requisito(id: "brew", nome: "Homebrew", paraQue: "instalar as outras ferramentas", grupo: .essencial,
                      script: #"""
                      if ! command -v brew >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/brew ]; then
                        passo "Homebrew (também instala as Ferramentas de Linha de Comando do Xcode)"
                        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
                      fi
                      eval "$(/opt/homebrew/bin/brew shellenv)"
                      grep -q 'brew shellenv' ~/.zprofile 2>/dev/null || echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
                      """#),
            Requisito(id: "clt", nome: "Ferramentas de Linha de Comando do Xcode", paraQue: "git e compiladores", grupo: .essencial,
                      script: #"""
                      if ! xcode-select -p >/dev/null 2>&1; then
                        passo "Ferramentas de Linha de Comando do Xcode"
                        xcode-select --install
                        echo "Conclua a instalação na janela que abriu…"
                        until xcode-select -p >/dev/null 2>&1; do sleep 5; done
                      fi
                      """#),
            Requisito(id: "git", nome: "Git", paraQue: "branches, commits, versões", grupo: .essencial,
                      script: "command -v git >/dev/null || brew install git"),
            Requisito(id: "gitnome", nome: "Git configurado (nome e e-mail)", paraQue: "criar commits pelo app", grupo: .essencial,
                      comoInstalar: "Preencha nome e e-mail abaixo"),
            Requisito(id: "node", nome: "Node.js 20 ou mais novo", paraQue: "rodar os apps React Native / Expo", grupo: .essencial,
                      script: #"""
                      v=$(node -v 2>/dev/null | tr -d v | cut -d. -f1)
                      if [ -z "$v" ] || [ "$v" -lt 20 ]; then passo "Node.js"; brew install node; fi
                      """#),
            Requisito(id: "yarn", nome: "Yarn 1 (classic)", paraQue: "instalar as dependências dos apps", grupo: .essencial,
                      script: #"command -v yarn >/dev/null || { passo "Yarn"; npm install -g yarn@1; }"#),
            Requisito(id: "watchman", nome: "Watchman", paraQue: "o Metro perceber as mudanças nos arquivos", grupo: .essencial,
                      script: #"command -v watchman >/dev/null || { passo "Watchman"; brew install watchman; }"#),
            Requisito(id: "awscli", nome: "AWS CLI", paraQue: "login (SSO) para o git", grupo: .codigo,
                      script: #"command -v aws >/dev/null || { passo "AWS CLI"; brew install awscli; }"#),
            Requisito(id: "grc", nome: "git-remote-codecommit", paraQue: "o git falar com o AWS CodeCommit (codecommit::…)", grupo: .codigo,
                      script: #"command -v git-remote-codecommit >/dev/null || { passo "git-remote-codecommit"; brew install git-remote-codecommit; }"#),
            Requisito(id: "awsperfil", nome: "Perfil AWS SSO configurado", paraQue: "qual conta e papel da AWS usar", grupo: .codigo,
                      script: """
                      if ! aws configure get sso_role_name >/dev/null 2>&1 && ! aws configure get sso_session >/dev/null 2>&1; then
                        passo "Configurar o login AWS (SSO) — responda as perguntas abaixo"
                        echo "  SSO session name ............ default"
                        echo "  SSO start URL ............... \(Requisitos.ssoURL)"
                        echo "  SSO region .................. us-east-1"
                        echo "  SSO registration scopes ..... (só Enter)"
                        echo "  → o navegador abre: faça login e autorize"
                        echo "  → escolha a conta e o papel (role) que te passaram"
                        echo "  Default client Region ....... sa-east-1"
                        echo "  CLI default output format ... json"
                        echo "  Profile name ................ default"
                        echo
                        aws configure sso
                      fi
                      """),
            Requisito(id: "awslogin", nome: "Login AWS ativo", paraQue: "fetch / pull / push funcionarem", grupo: .codigo,
                      comoInstalar: "Clique em \"Fazer login\" — o navegador abre para autorizar. Expira de tempos em tempos (normal)."),
            Requisito(id: "java", nome: "Java 17 ou mais novo (JDK)", paraQue: "compilar o Android (Gradle)", grupo: .android,
                      script: #"""
                      if ! /usr/libexec/java_home -v 17 >/dev/null 2>&1; then passo "Java 17"; brew install --cask zulu@17; fi
                      """#),
            Requisito(id: "sdk", nome: "Android SDK", paraQue: "adb, build-tools e plataforma Android", grupo: .android,
                      script: """
                      SDK="\(sdk)"
                      if [ ! -x "$SDK/cmdline-tools/latest/bin/sdkmanager" ]; then
                        passo "Android SDK (ferramentas de linha de comando)"
                        mkdir -p "$SDK/cmdline-tools" && cd /tmp
                        curl -fL -o cmdtools.zip https://dl.google.com/android/repository/commandlinetools-mac-11076708_latest.zip
                        unzip -q -o cmdtools.zip -d "$SDK/cmdline-tools"
                        rm -rf "$SDK/cmdline-tools/latest"; mv "$SDK/cmdline-tools/cmdline-tools" "$SDK/cmdline-tools/latest"
                        cd - >/dev/null
                      fi
                      export JAVA_HOME=$(/usr/libexec/java_home -v 17)
                      passo "Android SDK: licenças, platform-tools, plataforma 36 e build-tools"
                      yes | "$SDK/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null
                      "$SDK/cmdline-tools/latest/bin/sdkmanager" "platform-tools" "platforms;android-36" "build-tools;36.0.0"
                      """),
            Requisito(id: "env", nome: "Variáveis ANDROID_HOME e JAVA_HOME", paraQue: "o Gradle e o adb acharem o SDK e o Java", grupo: .android,
                      script: #"""
                      if ! grep -q '>>> Build Remoto >>>' ~/.zshrc 2>/dev/null; then
                        passo "Variáveis de ambiente no ~/.zshrc"
                        cat >> ~/.zshrc <<'ZSH'
                      # >>> Build Remoto >>>
                      export JAVA_HOME=$(/usr/libexec/java_home -v 17 2>/dev/null)
                      export ANDROID_HOME=$HOME/Library/Android/sdk
                      export PATH=$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH
                      # <<< Build Remoto <<<
                      ZSH
                      fi
                      """#),
            Requisito(id: "scrcpy", nome: "scrcpy", paraQue: "ver e controlar a tela do celular no app", grupo: .android,
                      script: #"command -v scrcpy >/dev/null || { passo "scrcpy"; brew install scrcpy; }"#),
            Requisito(id: "celular", nome: "Celular com depuração USB", paraQue: "rodar o app no celular", grupo: .android,
                      comoInstalar: "No celular: Configurações → Sobre o telefone → toque 7× em \"Número da versão\". Depois: Opções do desenvolvedor → Depuração USB. Conecte o cabo e aceite \"Permitir depuração USB\"."),
            Requisito(id: "deps", nome: "Dependências dos apps (node_modules)", paraQue: "rodar os apps e o visualizador do Realm", grupo: .android,
                      comoInstalar: "Clique em \"Instalar\" (roda yarn install em cada app) — ou elas são instaladas no primeiro Rodar."),
            Requisito(id: "emulador", nome: "Emulador Android", paraQue: "testar sem celular (ocupa ~6 GB)", grupo: .extra,
                      script: """
                      SDK="\(sdk)"; export JAVA_HOME=$(/usr/libexec/java_home -v 17)
                      passo "Emulador Android (imagem do Android 36)"
                      "$SDK/cmdline-tools/latest/bin/sdkmanager" "emulator" "system-images;android-36;google_apis;arm64-v8a"
                      echo no | "$SDK/cmdline-tools/latest/bin/avdmanager" create avd -n Android_36 -k "system-images;android-36;google_apis;arm64-v8a" -d pixel_7 --force
                      """),
            Requisito(id: "claude", nome: "Claude Code", paraQue: "resumo da daily com IA, sem chave de API", grupo: .extra,
                      script: #"command -v claude >/dev/null || [ -x "$HOME/.local/bin/claude" ] || { passo "Claude Code"; curl -fsSL https://claude.ai/install.sh | bash; echo "Depois rode: claude  (para fazer login uma vez)"; }"#),
            Requisito(id: "studio", nome: "Android Studio", paraQue: "editar código nativo e gerenciar SDK/emuladores", grupo: .extra,
                      script: #"[ -d "/Applications/Android Studio.app" ] || { passo "Android Studio"; brew install --cask android-studio; }"#),
            Requisito(id: "vscode", nome: "Editor de código (VS Code)", paraQue: "abrir os projetos pelo app", grupo: .extra,
                      script: #"[ -d "/Applications/Visual Studio Code.app" ] || { passo "VS Code"; brew install --cask visual-studio-code; }"#),
            Requisito(id: "xcode", nome: "Xcode", paraQue: "rodar no simulador iOS", grupo: .ios,
                      comoInstalar: "Instale pela App Store (é grande, ~15 GB) e abra uma vez para aceitar a licença."),
            Requisito(id: "pods", nome: "CocoaPods", paraQue: "dependências nativas do iOS", grupo: .ios,
                      script: #"command -v pod >/dev/null || { passo "CocoaPods"; brew install cocoapods; }"#),
        ]
    }

    func verificar() async {
        verificando = true
        let sdk = Requisitos.sdk
        let r = await Shell.run("zsh", ["-lic", #"""
        echo "@@macos=$(sw_vers -productVersion)"
        echo "@@brew=$(command -v brew || ls /opt/homebrew/bin/brew 2>/dev/null)"
        echo "@@clt=$(xcode-select -p 2>/dev/null)"
        echo "@@git=$(git --version 2>/dev/null)"
        echo "@@gitnome=$(git config --global user.name 2>/dev/null) <$(git config --global user.email 2>/dev/null)>"
        echo "@@node=$(node -v 2>/dev/null)"
        echo "@@yarn=$(yarn -v 2>/dev/null)"
        echo "@@watchman=$(watchman --version 2>/dev/null)"
        echo "@@java=$(/usr/libexec/java_home -v 17 2>/dev/null)"
        S="${ANDROID_HOME:-\#(sdk)}"
        echo "@@sdk=$( [ -x "$S/platform-tools/adb" ] && echo "$S · build-tools $(ls "$S/build-tools" 2>/dev/null | tail -1)" )"
        echo "@@licencas=$(ls "$S/licenses" 2>/dev/null | wc -l | tr -d ' ')"
        echo "@@env=ANDROID_HOME=$ANDROID_HOME|JAVA_HOME=$JAVA_HOME"
        echo "@@scrcpy=$(scrcpy --version 2>/dev/null | head -1)"
        echo "@@celular=$("$S/platform-tools/adb" devices 2>/dev/null | grep -c 'device$')"
        echo "@@emulador=$("$S/emulator/emulator" -list-avds 2>/dev/null | tr '\n' ' ')"
        echo "@@studio=$(ls -d '/Applications/Android Studio.app' 2>/dev/null)"
        echo "@@vscode=$(ls -d '/Applications/Visual Studio Code.app' '/Applications/Cursor.app' 2>/dev/null | head -1)"
        echo "@@xcode=$(xcodebuild -version 2>/dev/null | head -1)"
        echo "@@pods=$(pod --version 2>/dev/null)"
        echo "@@awscli=$(aws --version 2>/dev/null | cut -d' ' -f1)"
        echo "@@grc=$(command -v git-remote-codecommit)"
        echo "@@awsperfil=$(aws configure get sso_role_name 2>/dev/null) $(aws configure get sso_start_url 2>/dev/null || aws configure get sso_session 2>/dev/null)"
        echo "@@claude=$(command -v claude || ls $HOME/.local/bin/claude 2>/dev/null)"
        """#])
        var v: [String: String] = [:]
        for l in r.out.split(separator: "\n") where l.hasPrefix("@@") {
            let p = l.dropFirst(2).split(separator: "=", maxSplits: 1)
            v[String(p[0])] = p.count > 1 ? String(p[1]).trimmingCharacters(in: .whitespaces) : ""
        }
        let livre = (try? URL(fileURLWithPath: Config.home).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        for i in itens.indices {
            let id = itens[i].id
            let x = v[id] ?? ""
            var ok = !x.isEmpty
            var det = x
            switch id {
            case "macos": ok = (Int(x.split(separator: ".").first ?? "") ?? 0) >= 14; det = "macOS \(x)"
            case "disco":
                let gb = Double(livre) / 1_073_741_824
                det = String(format: "%.0f GB livres", gb)
                itens[i].estado = gb >= 30 ? .ok : gb >= 15 ? .aviso : .falta
                itens[i].detalhe = det
                continue
            case "gitnome": ok = !x.hasPrefix(" <") && !x.hasPrefix("<"); det = ok ? x : "nome/e-mail não configurados"
            case "node":
                let maior = Int(x.dropFirst().split(separator: ".").first ?? "") ?? 0
                ok = maior >= 20; det = x.isEmpty ? "não instalado" : (ok ? x : "\(x) (precisa 20+)")
            case "yarn": ok = x.hasPrefix("1."); det = x.isEmpty ? "não instalado" : (ok ? x : "\(x) (os apps usam Yarn 1)")
            case "java":
                det = ok ? x.replacingOccurrences(of: "/Library/Java/JavaVirtualMachines/", with: "").replacingOccurrences(of: "/Contents/Home", with: "")
                    : "não instalado (será instalado o Zulu 17)"
            case "sdk": det = ok ? x.replacingOccurrences(of: Config.home, with: "~") : "não instalado"
                if ok, (Int(v["licencas"] ?? "0") ?? 0) == 0 { itens[i].estado = .aviso; itens[i].detalhe = det + " · licenças não aceitas"; continue }
            case "env":
                ok = x.contains("ANDROID_HOME=/") && x.contains("JAVA_HOME=/")
                det = ok ? "configuradas" : "faltando no ~/.zshrc"
            case "celular":
                let n = Int(x) ?? 0
                itens[i].estado = n > 0 ? .ok : .aviso
                itens[i].detalhe = n > 0 ? "\(n) conectado(s)" : "nenhum conectado agora"
                continue
            case "emulador": ok = !x.trimmingCharacters(in: .whitespaces).isEmpty; det = ok ? x : "nenhum emulador criado"
            case "awsperfil":
                ok = !x.trimmingCharacters(in: .whitespaces).isEmpty
                det = ok ? "papel " + x.trimmingCharacters(in: .whitespaces) : "não configurado"
            case "awslogin":
                if v["awscli"]?.isEmpty ?? true { itens[i].estado = .falta; itens[i].detalhe = "precisa do AWS CLI"; continue }
                await AwsSSO.compartilhado.verificar()
                let e = AwsSSO.compartilhado.estado
                if case .ok = e { itens[i].estado = .ok } else { itens[i].estado = .aviso }
                itens[i].detalhe = AwsSSO.compartilhado.texto.replacingOccurrences(of: "AWS: ", with: "")
                continue
            case "deps":
                let sem = Config.projetos.filter { !FileManager.default.fileExists(atPath: "\(Config.pasta($0))/node_modules") }
                itens[i].estado = Config.projetos.isEmpty ? .aviso : sem.isEmpty ? .ok : .aviso
                itens[i].detalhe = Config.projetos.isEmpty ? "nenhum app configurado ainda" : sem.isEmpty ? "instaladas nos \(Config.projetos.count) apps" : "faltam em: " + sem.joined(separator: ", ")
                continue
            default: if !ok { det = "não instalado" }
            }
            itens[i].estado = ok ? .ok : .falta
            itens[i].detalhe = det
        }
        verificando = false
    }

    /// Script com os passos dos itens que faltam (na ordem do catálogo), para rodar no Terminal
    func scriptInstalacao(_ ids: [String]) -> String {
        var passos = itens.filter { ids.contains($0.id) }.compactMap(\.script)
        if ids.contains("deps") { passos.append("export NVM_DIR=\"$HOME/.nvm\"; [ -s \"$NVM_DIR/nvm.sh\" ] && . \"$NVM_DIR/nvm.sh\"\n" + scriptDeps) }
        return """
        #!/bin/bash
        # Instalação dos requisitos do Build Remoto
        passo() { echo; echo "▶ $1"; }
        clear
        echo "════════════════════════════════════════════════"
        echo "  Build Remoto — instalando o que falta"
        echo "════════════════════════════════════════════════"
        echo "Pode pedir a senha do Mac (a mesma de entrar no computador)."
        echo "Ao digitar a senha nada aparece na tela — é normal."
        echo "Leva de 10 a 40 minutos, dependendo da internet."
        echo
        sudo -v || exit 1
        # mantém a senha válida durante a instalação
        while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &
        [ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"
        \(passos.joined(separator: "\n"))
        echo
        echo "════════════════════════════════════════════════"
        echo "  ✓ Pronto! Pode fechar esta janela."
        echo "  Volte ao Build Remoto — ele verifica de novo sozinho."
        echo "════════════════════════════════════════════════"
        open -a "Build Remoto" 2>/dev/null
        """
    }

    func instalar(_ ids: [String]) {
        Shell.abrirNoTerminal("bash \(Adb.aspas(salvarScript(ids)))", titulo: "Build Remoto — instalação")
    }

    private func salvarScript(_ ids: [String]) -> String {
        let dir = "\(Config.home)/Library/Caches/BuildRemoto"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let caminho = "\(dir)/instalar-requisitos.sh"
        try? scriptInstalacao(ids).write(toFile: caminho, atomically: true, encoding: .utf8)
        return caminho
    }
}

// MARK: - Lista na tela de boas-vindas

struct ListaRequisitos: View {
    @ObservedObject var req: Requisitos
    @State private var nome = ""
    @State private var email = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("O que este Mac precisa").font(.headline)
                if req.verificando { ProgressView().controlSize(.small) }
                Spacer()
                Button { Task { await req.verificar() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Verificar de novo")
            }
            let faltam = req.faltandoEssenciais
            if !req.verificando {
                if faltam.isEmpty {
                    Label("Tudo o que é essencial está instalado ✓", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    HStack(spacing: 12) {
                        Label("Faltam \(faltam.count) item(ns) essencial(is)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Spacer()
                        Button {
                            req.instalar(faltam.filter { $0.script != nil }.map(\.id) + dependencias(faltam))
                        } label: {
                            Label("Instalar tudo o que falta", systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(faltam.allSatisfy { $0.script == nil })
                    }
                    Text("Abre o Terminal, pede a senha do Mac uma vez e instala na ordem certa. Ao voltar para o app, a lista é verificada de novo.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(Requisito.Grupo.allCases, id: \.self) { g in
                let itens = req.itens.filter { $0.grupo == g && req.visivel($0) }
                if !itens.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(g.rawValue.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).padding(.top, 6)
                    ForEach(itens) { r in linha(r) }
                }
                }
            }
        }
        .task { await req.verificar() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await req.verificar() }
        }
    }

    /// Itens que precisam vir antes (ex.: Homebrew antes de tudo, Java antes do SDK)
    private func dependencias(_ faltam: [Requisito]) -> [String] {
        let ids = Set(faltam.map(\.id))
        var extra: [String] = []
        if !ids.isDisjoint(with: ["node", "watchman", "java", "scrcpy", "git", "pods", "awscli", "grc"]) { extra.append("brew") }
        if ids.contains("awsperfil") { extra.append("awscli") }
        if ids.contains("sdk") { extra += ["java", "env"] }
        return extra
    }

    @ViewBuilder private func linha(_ r: Requisito) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icone(r.estado)).foregroundStyle(cor(r)).font(.system(size: 14)).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(r.nome).font(.system(size: 12.5, weight: .medium))
                    Text("— \(r.paraQue)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                if !r.detalhe.isEmpty {
                    Text(r.detalhe).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if r.estado != .ok && !r.comoInstalar.isEmpty && r.id != "gitnome" {
                    Text(r.comoInstalar).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if r.id == "gitnome" && r.estado == .falta {
                    HStack {
                        TextField("Seu nome", text: $nome).textFieldStyle(.roundedBorder).frame(width: 160)
                        TextField("seu@email.com", text: $email).textFieldStyle(.roundedBorder).frame(width: 190)
                        Button("Salvar") {
                            Task {
                                _ = await Shell.run("git", ["config", "--global", "user.name", nome])
                                _ = await Shell.run("git", ["config", "--global", "user.email", email])
                                await req.verificar()
                            }
                        }
                        .disabled(nome.isEmpty || email.isEmpty)
                    }
                    .controlSize(.small)
                }
            }
            Spacer()
            if r.estado != .ok {
                if r.id == "awslogin" {
                    Button { AwsSSO.compartilhado.tentarLogin() } label: {
                        Label("Fazer login", systemImage: AwsSSO.compartilhado.bloqueado ? "lock.fill" : "person.badge.key")
                    }
                    .controlSize(.small)
                } else if r.id == "deps" {
                    Button("Instalar") { req.instalar(["deps"]) }.controlSize(.small).disabled(Config.projetos.isEmpty)
                } else if r.id == "xcode" {
                    Button("App Store") { NSWorkspace.shared.open(URL(string: "macappstore://apps.apple.com/app/id497799835")!) }.controlSize(.small)
                } else if r.script != nil && r.opcional {
                    Button("Instalar") { req.instalar((r.id == "emulador" ? ["brew", "java", "sdk", "env"] : ["brew"]) + [r.id]) }.controlSize(.small)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func icone(_ e: Requisito.Estado) -> String {
        switch e { case .ok: "checkmark.circle.fill"; case .falta: "xmark.circle.fill"; case .aviso: "exclamationmark.circle.fill"; case .verificando: "circle.dotted" }
    }
    private func cor(_ r: Requisito) -> Color {
        switch r.estado {
        case .ok: .green
        case .falta: r.opcional ? .secondary : .red
        case .aviso: .orange
        case .verificando: .secondary
        }
    }
}
