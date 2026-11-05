import Foundation

enum Config {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let pcHost = "pc-build"
    /// Projetos configurados (descobertos automaticamente ou adicionados pelo usuário)
    static var projetos: [String] { Projetos.lista.map(\.nome) }
    static func pasta(_ projeto: String) -> String {
        Projetos.lista.first { $0.nome == projeto }?.caminho ?? "\(home)/\(projeto)"
    }
    /// Há um PC de build configurado neste Mac? (sem ele, o app funciona só no modo local)
    static let temPC: Bool = {
        let ssh = (try? String(contentsOfFile: "\(home)/.ssh/config", encoding: .utf8)) ?? ""
        return ssh.contains("Host pc-build") && FileManager.default.isExecutableFile(atPath: "\(home)/.local/bin/build-remoto")
    }()
    /// aapt da versão mais nova de build-tools instalada
    static var aapt: String? {
        let bt = "\(androidSdk)/build-tools"
        let versoes = ((try? FileManager.default.contentsOfDirectory(atPath: bt)) ?? []).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        return versoes.map { "\(bt)/\($0)/aapt" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    /// Servidor do scrcpy (Homebrew em Apple Silicon ou Intel)
    static var scrcpyServer: String? {
        ["/opt/homebrew/share/scrcpy/scrcpy-server", "/usr/local/share/scrcpy/scrcpy-server"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }
    /// adb do WSL (cliente que fala com o adb server do Windows); ssh sem login não tem o SDK no PATH
    static let adbPC = "$HOME/Android/Sdk/platform-tools/adb"
    /// SDK do Android no Windows, visto do WSL. O "*" acha o usuário sozinho; com mais de um usuário com SDK,
    /// defina o nome com: defaults write <bundle id> pc.usuarioWindows NOME
    static var sdkWin: String {
        "/mnt/c/Users/\(UserDefaults.standard.string(forKey: "pc.usuarioWindows") ?? "*")/AppData/Local/Android/Sdk"
    }
    static var adbWin: String { "\(sdkWin)/platform-tools/adb.exe" }
    static let apkDir = "\(home)/apks-remotos"
    /// Android SDK: o padrão do Android Studio, ou o ANDROID_HOME do terminal do usuário (lido ao abrir o app)
    nonisolated(unsafe) static var androidSdk = "\(home)/Library/Android/sdk"
    /// PATH do terminal do usuário (lido do zsh interativo na abertura do app): pega nvm, asdf, volta, fnm etc.
    nonisolated(unsafe) static var pathUsuario: [String] = []

    static var path: String {
        var vistos = Set<String>()
        return (pathUsuario + [
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin",
            "\(androidSdk)/platform-tools", "\(androidSdk)/emulator", "\(androidSdk)/cmdline-tools/latest/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]).filter { !$0.isEmpty && vistos.insert($0).inserted }.joined(separator: ":")
    }

    // Conexão SSH mestre compartilhada: as consultas do app reaproveitam o mesmo canal
    static let controlPath = "\(home)/.ssh/cm-buildremoto-%C"
    static var sshCliente: [String] {
        ["-o", "ControlMaster=no", "-o", "ControlPath=\(controlPath)",
         "-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
    }

    /// Ícone do app: assets/icon.png (Expo), ícone de marketing do iOS ou ícone do Android
    static func icone(_ projeto: String) -> String {
        let base = pasta(projeto)
        let fm = FileManager.default
        var candidatos = ["\(base)/assets/icon.png", "\(base)/assets/images/icon.png"]
        if let ios = fm.enumerator(atPath: "\(base)/ios") {
            while let x = ios.nextObject() as? String {
                if x.contains("node_modules") || x.contains("Pods") { ios.skipDescendants(); continue }
                if x.hasSuffix("ios-marketing.png") || x.hasSuffix("1024.png") { candidatos.append("\(base)/ios/\(x)"); break }
            }
        }
        candidatos.append("\(base)/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png")
        return candidatos.first { fm.fileExists(atPath: $0) } ?? candidatos[0]
    }
}

struct ShellResult {
    let code: Int32
    let out: String
    var ok: Bool { code == 0 }
}

enum Shell {
    /// Antes de comandos de projeto no Mac: carrega o nvm (só vem no .zshrc, que o app não lê)
    /// e usa a versão do .nvmrc do projeto, se houver.
    static let prepararNode = #"""
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
      . "$NVM_DIR/nvm.sh" >/dev/null 2>&1
      if [ -f .nvmrc ]; then nvm use --silent >/dev/null 2>&1 || echo "⚠ Node $(cat .nvmrc) (do .nvmrc) não está instalado no nvm — usando $(node -v 2>/dev/null)"
      elif ! command -v node >/dev/null 2>&1; then nvm use --silent default >/dev/null 2>&1; fi
    fi
    [ -z "$(command -v fnm)" ] || eval "$(fnm env --use-on-cd 2>/dev/null)"
    if ! command -v yarn >/dev/null 2>&1; then
      if command -v corepack >/dev/null 2>&1; then corepack enable >/dev/null 2>&1; fi
      command -v yarn >/dev/null 2>&1 || echo "✗ yarn não encontrado. Abra Ações → Boas-vindas e requisitos e instale o que falta."
    fi
    """#

    static func ambiente(_ extra: [String: String] = [:]) -> [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = Config.path
        e.merge(extra) { _, novo in novo }
        return e
    }

    static func processo(_ exe: String, _ args: [String], env: [String: String] = [:]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [exe] + args
        p.environment = ambiente(env)
        return p
    }

    /// Roda um comando e devolve a saída (stdout + stderr) quando terminar.
    static func run(_ exe: String, _ args: [String], env: [String: String] = [:],
                    stdin: Data? = nil) async -> ShellResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = processo(exe, args, env: env)
                let saida = Pipe()
                p.standardOutput = saida
                p.standardError = saida
                let entrada = Pipe()
                p.standardInput = stdin == nil ? FileHandle.nullDevice : entrada
                do { try p.run() } catch {
                    cont.resume(returning: ShellResult(code: -1, out: "\(error.localizedDescription)"))
                    return
                }
                if let stdin {
                    entrada.fileHandleForWriting.write(stdin)
                    try? entrada.fileHandleForWriting.close()
                }
                let data = saida.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: ShellResult(code: p.terminationStatus,
                                                   out: String(decoding: data, as: UTF8.self)))
            }
        }
    }

    /// Roda um script bash no PC (WSL). O script vai como argumento (base64), não pelo stdin:
    /// comandos como o adb.exe leem o stdin e "comeriam" o resto do script.
    static func noPC(_ script: String) async -> ShellResult {
        let b64 = Data(script.utf8).base64EncodedString()
        return await run("ssh", Config.sshCliente + [Config.pcHost, "bash -c \"$(echo \(b64) | base64 -d)\" </dev/null"])
    }

    /// Roda um comando entregando a saída aos poucos (texto UTF-8 completo) na main thread.
    static func stream(_ exe: String, _ args: [String], env: [String: String] = [:],
                       onTexto: @escaping (String) -> Void,
                       onFim: @escaping (Int32) -> Void) -> Process? {
        let p = processo(exe, args, env: env)
        let saida = Pipe()
        p.standardOutput = saida
        p.standardError = saida
        p.standardInput = FileHandle.nullDevice
        var pendente = Data()
        saida.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }
            pendente.append(chunk)
            // Não corta um caractere UTF-8 no meio: guarda até 3 bytes incompletos
            var corte = pendente.count
            while corte > 0, corte > pendente.count - 4,
                  String(data: pendente.prefix(corte), encoding: .utf8) == nil {
                corte -= 1
            }
            if corte == 0 { corte = pendente.count }
            let texto = String(decoding: pendente.prefix(corte), as: UTF8.self)
            pendente.removeFirst(corte)
            DispatchQueue.main.async { onTexto(texto) }
        }
        p.terminationHandler = { proc in
            DispatchQueue.main.async { onFim(proc.terminationStatus) }
        }
        do { try p.run() } catch { return nil }
        return p
    }

    static func notificar(_ titulo: String, _ texto: String, som: String = "Glass") {
        let esc = { (s: String) in s.replacingOccurrences(of: "\"", with: "\\\"") }
        let script = "display notification \"\(esc(texto))\" with title \"Build Remoto\" subtitle \"\(esc(titulo))\" sound name \"\(som)\""
        Task { _ = await run("osascript", ["-e", script]) }
    }

    /// Abre o Terminal do macOS rodando um comando (via arquivo .command, sem pedir permissão)
    static func abrirNoTerminal(_ comando: String, titulo: String) {
        let dir = URL(fileURLWithPath: "\(Config.home)/Library/Caches/BuildRemoto")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let nome = titulo.replacingOccurrences(of: "/", with: "-")
        let arq = dir.appendingPathComponent("\(nome).command")
        let conteudo = """
        #!/bin/zsh
        export PATH="\(Config.path):$PATH"
        printf '\\e]0;%s\\a' "\(titulo)"
        clear
        \(comando)
        """
        try? conteudo.write(to: arq, atomically: true, encoding: .utf8)
        chmod(arq.path, 0o755)
        Task { _ = await run("open", ["-a", "Terminal", arq.path]) }
    }
}
