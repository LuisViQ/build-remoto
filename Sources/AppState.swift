import AppKit
import SwiftUI

// MARK: - Modelos

enum Origem: String { case pc = "PC", mac = "Mac" }

struct Dispositivo: Identifiable, Hashable {
    let serial: String
    let modelo: String
    let estado: String      // device, offline, unauthorized
    let origem: Origem
    var id: String { "\(origem.rawValue):\(serial)" }
    var pronto: Bool { estado == "device" }
    /// serial do emulador -> nome do AVD (preenchido pelo AppState)
    nonisolated(unsafe) static var apelidos: [String: String] = [:]

    var nome: String {
        if serial.hasPrefix("emulator-") {
            return "Emulador " + (Self.apelidos[serial]?.replacingOccurrences(of: "_", with: " ") ?? serial)
        }
        let m = modelo.replacingOccurrences(of: "_", with: " ")
        let conhecidos: [String: String] = [:]
        return conhecidos[m] ?? (m.isEmpty ? serial : m)
    }
}

enum EstadoSessao: Equatable {
    case rodando
    case terminou(Int)
    case local        // processo rodando aqui no Mac (logcat do celular do Mac)
}

struct SyncInfo {
    var status = "—"
    var erro = false
    var resumo: (texto: String, cor: Color, icone: String) {
        if erro { return ("Erro na sincronização", .red, "exclamationmark.triangle.fill") }
        switch status {
        case "Watching for changes": return ("Sincronizado", .green, "checkmark.circle.fill")
        case let s where s.hasPrefix("Connecting") || s.hasPrefix("Waiting") || s.contains("Halted"):
            return ("Desconectado", .orange, "bolt.horizontal.circle")
        case "—": return ("—", .secondary, "circle.dashed")
        default: return ("Sincronizando…", .blue, "arrow.triangle.2.circlepath")
        }
    }
}

struct PCStatus {
    var online = false
    var checado = false
    var host = ""
    var latenciaMs = 0
    var cpu: Double = 0
    var nucleos = 0
    var memUsadaGB: Double = 0
    var memTotalGB: Double = 0
    var viaTailscale: Bool { host.hasPrefix("100.") }
}

struct MacStatus {
    var cpu: Double = 0
    var memUsadaGB: Double = 0
    var memTotalGB: Double = 0
}

enum GrupoFerramenta: String, CaseIterable, Identifiable {
    case rodar = "Rodar", codigo = "Código", dados = "Dados", anotacoes = "Anotações"
    var id: String { rawValue }
    var icone: String {
        switch self { case .rodar: "play.circle"; case .codigo: "chevron.left.forwardslash.chevron.right"; case .dados: "cylinder"; case .anotacoes: "note.text" }
    }
}

enum Ferramenta: String, CaseIterable, Identifiable {
    // na ordem dos grupos (⌘1…⌘9 seguem esta ordem)
    case console = "Console", logcat = "Logcat", celular = "Celular", localizacao = "Localização",
         git = "Git", versoes = "Versões", saude = "Saúde", docs = "Docs",
         realm = "Realm", apks = "APKs", historico = "Histórico",
         notas = "Notas", entregas = "Entregas", bugs = "Bugs", atalhos = "Atalhos"

    var grupo: GrupoFerramenta {
        switch self {
        case .console, .logcat, .celular, .localizacao: .rodar
        case .git, .versoes, .saude, .docs: .codigo
        case .realm, .apks, .historico: .dados
        case .notas, .entregas, .bugs, .atalhos: .anotacoes
        }
    }
    var id: String { rawValue }
    var icone: String {
        switch self {
        case .console: "apple.terminal"
        case .logcat: "list.bullet.rectangle"
        case .celular: "iphone.gen3"
        case .apks: "shippingbox"
        case .historico: "clock.arrow.circlepath"
        case .bugs: "ladybug"
        case .notas: "note.text"
        case .entregas: "checkmark.seal"
        case .atalhos: "bolt.circle"
        case .versoes: "number.circle"
        case .git: "arrow.triangle.branch"
        case .realm: "cylinder.split.1x2"
        case .localizacao: "location.fill.viewfinder"
        case .saude: "stethoscope"
        case .docs: "book.closed"
        }
    }
}

struct Apk: Identifiable {
    let url: URL
    let data: Date
    let tamanho: Int64
    var id: URL { url }
}

enum Acao: String, CaseIterable, Identifiable {
    case rodar, metro, logs, tela, debug, release, deps, terminal
    var id: String { rawValue }
    var titulo: String {
        switch self {
        case .rodar: "Rodar app"
        case .metro: "Metro"
        case .logs: "Logs"
        case .tela: "Ver tela"
        case .debug: "APK Debug"
        case .release: "APK Release"
        case .deps: "Dependências"
        case .terminal: "Terminal"
        }
    }
    var subtitulo: String {
        switch self {
        case .rodar: "yarn android"
        case .metro: "yarn start"
        case .logs: "console.log e crashes"
        case .tela: "espelhar no Mac"
        case .debug: "assembleDebug"
        case .release: "assembleRelease"
        case .deps: "yarn install"
        case .terminal: "shell no PC"
        }
    }
    var icone: String {
        switch self {
        case .rodar: "play.fill"
        case .metro: "bolt.fill"
        case .logs: "text.alignleft"
        case .tela: "iphone.gen3.radiowaves.left.and.right"
        case .debug: "shippingbox"
        case .release: "shippingbox.fill"
        case .deps: "arrow.down.circle"
        case .terminal: "terminal"
        }
    }
    var cor: Color {
        switch self {
        case .rodar: .green
        case .metro: .yellow
        case .logs: .cyan
        case .tela: .purple
        case .debug: .blue
        case .release: .indigo
        case .deps: .orange
        case .terminal: .gray
        }
    }
    /// Ações que dependem do celular escolhido
    var usaCelular: Bool { [.rodar, .metro, .logs, .tela].contains(self) }
}

// MARK: - Estado do app

@MainActor
final class AppState: ObservableObject {
    @Published var selecionado: String? = Config.projetos.first
    @Published var pc = PCStatus()
    @Published var dispositivos: [Dispositivo] = []
    @Published var alvoID: String?                       // celular escolhido
    @Published var sessoesRemotas: [String: EstadoSessao] = [:]
    var sessoesLocais: Set<String> { Set(estadosLocais.keys) }
    @Published var abaConsole: [String: String] = [:]   // projeto -> sessão aberta
    @Published var syncs: [String: SyncInfo] = [:]
    @Published var branches: [String: String] = [:]
    @Published var apks: [String: [Apk]] = [:]
    @Published var iniciando: Set<String> = []
    @Published var tunelMacAtivo = false
    @Published var erro: String?
    /// Modo "Só o Mac": tudo roda localmente, sem o PC
    @Published var modoLocal = UserDefaults.standard.bool(forKey: "modoLocal") {
        didSet {
            UserDefaults.standard.set(modoLocal, forKey: "modoLocal")
            alvoID = nil
            if modoLocal { pararTunelMac() }
            Task { await atualizar() }
        }
    }
    @Published var mostrarTela = false
    @Published var abaFerramenta: [String: Ferramenta] = [:]
    @Published var estadosLocais: [String: EstadoSessao] = [:]
    @Published var mac = MacStatus()

    @Published var registrosApk: [String: [ApkRegistro]] = [:]
    private var buildsPendentes: [String: BuildContexto] = [:]
    private var iniciosSessao: [String: Date] = [:]
    @Published var versaoHistorico = 0
    @Published var mostrarDiagnostico = false
    @Published var gerarVersaoDe: String?
    @Published var mostrarPaleta = false
    @Published var gerandoRelatorio = false
    @Published var capturaBug: CapturaBug?
    @Published var infoMaquina: Origem?
    @Published var pastasNoGit: [String: Set<String>] = [:]
    @Published var emuladores: [Emulador] = []
    @Published var ligandoEmulador: Set<String> = []
    @Published var bugSelecionado: [String: URL] = [:]
    @Published var versaoBugs = 0
    let vigia = VigiaCrashes()
    let gravacao = Gravacao()
    let mirror = MirrorSession()
    let logcat = LogcatModel()
    private var gits: [String: GitModel] = [:]

    @Published private(set) var icones: [String: NSImage] = [:]
    @Published var mostrarBoasVindas = !UserDefaults.standard.bool(forKey: "boasVindasVista")
    private var consoles: [String: ConsoleModel] = [:]
    private var mestre: Process?
    private var tunel: Process?
    private var cpuAnterior: (ocioso: Double, total: Double)?
    private var ciclo = 0
    private var iniciado = false
    private var dispositivosMudaram = false

    init() {
        // Sem PC configurado (ex.: Mac de outra pessoa), o app funciona só no modo local
        if !Config.temPC { modoLocal = true }
        recarregarIcones()
    }

    func recarregarIcones() {
        var i: [String: NSImage] = [:]
        for p in Config.projetos { i[p] = NSImage(contentsOfFile: Config.icone(p)) }
        icones = i
    }

    var alvo: Dispositivo? {
        dispositivos.first { $0.id == alvoID } ?? dispositivos.first { $0.pronto }
    }

    func iniciar() {
        guard !iniciado else { return }
        iniciado = true
        // ANDROID_HOME personalizado no terminal do usuário (SDK fora do lugar padrão)
        Task {
            let r = await Shell.run("zsh", ["-lic", "echo \"@@$ANDROID_HOME\"; echo \"@P$PATH\""])
            if let l = r.out.split(separator: "\n").last(where: { $0.hasPrefix("@P") }) {
                Config.pathUsuario = l.dropFirst(2).split(separator: ":").map(String.init)
                    .filter { !$0.hasPrefix("/var/run/com.apple") && !$0.hasPrefix("/System/Cryptexes") }
            }
            if let l = r.out.split(separator: "\n").last(where: { $0.hasPrefix("@@") }) {
                let sdk = String(l.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !sdk.isEmpty, FileManager.default.fileExists(atPath: "\(sdk)/platform-tools") { Config.androidSdk = sdk }
            }
        }
        // Túneis de espelhamento de uma execução anterior do app (encerrada à força) ficam órfãos
        Task { _ = await Shell.run("pkill", ["-f", "ssh -nN -o ControlMaster=no -o ControlPath=none -o ExitOnForwardFailure=yes -o ServerAliveInterval=15"]) }
        Task {
            while true {
                await atualizar()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func encerrar() {
        vigia.parar()
        mirror.parar()
        logcat.parar()
        tunel?.terminate()
        mestre?.terminate()
        consoles.values.forEach { $0.parar() }
    }

    // MARK: Conexão mestre SSH

    private func garantirMestre() {
        if let m = mestre, m.isRunning { return }
        let p = Shell.processo("ssh", [
            "-MNn", "-o", "ControlMaster=yes", "-o", "ControlPath=\(Config.controlPath)",
            "-o", "ControlPersist=no", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2",
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", Config.pcHost,
        ])
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try? p.run()
        mestre = p
    }

    func reconectar() {
        mestre?.terminate()
        mestre = nil
        Task { await atualizar() }
    }

    // MARK: Atualização periódica

    func atualizar() async {
        ciclo += 1
        let m = RecursosMac.memoria()
        mac = MacStatus(cpu: RecursosMac.cpu(), memUsadaGB: m.usada, memTotalGB: m.total)
        if modoLocal {
            async let adbMac = Shell.run("adb", ["devices", "-l"])
            async let sync = Shell.run("mutagen", ["sync", "list"])
            let (a, s) = await (adbMac, sync)
            lerSync(s.out)
            let devs = Self.lerAdb(a.out, origem: .mac)
            dispositivosMudaram = devs != dispositivos
            if devs != dispositivos { dispositivos = devs }
            if alvoID == nil || !dispositivos.contains(where: { $0.id == alvoID }) {
                alvoID = dispositivos.first { $0.pronto }?.id
            }
            if ciclo % 4 == 1 { await lerBranchesEApks() }
            acompanharCrashes()
            if ciclo % 7 == 1 || dispositivosMudaram { await atualizarEmuladores() }
            return
        }
        garantirMestre()
        let consultarAdbPC = !tunelMacAtivo
        let script = """
        D=$HOME/.build-remoto
        echo "##TMUX"; tmux ls -F '#{session_name}' 2>/dev/null
        echo "##STATUS"; for f in $D/*.status; do [ -f "$f" ] && echo "$(basename "$f" .status) $(cat "$f")"; done
        echo "##CPU"; head -1 /proc/stat
        echo "##MEM"; grep -E '^(MemTotal|MemAvailable):' /proc/meminfo
        echo "##NPROC"; nproc
        \(consultarAdbPC ? "echo '##ADB'; timeout 6 \(Config.adbWin) devices -l 2>/dev/null | tr -d '\\r' | tail -n +2" : "")
        echo "##FIM"
        """
        let t0 = Date()
        async let remoto = Shell.noPC(script)
        async let sync = Shell.run("mutagen", ["sync", "list"])
        async let adbMac = Shell.run("adb", ["devices", "-l"])
        async let host = Shell.run("pc-rede", ["atual"])
        let (r, s, a, h) = await (remoto, sync, adbMac, host)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)

        pc.host = h.out.trimmingCharacters(in: .whitespacesAndNewlines)
        pc.checado = true
        let secoes = Self.secoes(r.out)
        let online = r.ok && secoes["FIM"] != nil
        pc.online = online
        if online { pc.latenciaMs = ms; lerRecursos(secoes) }
        lerSessoes(secoes, online: online)
        lerSync(s.out)

        var devs = Self.lerAdb(a.out, origem: .mac)
        if online {
            if consultarAdbPC { devs += Self.lerAdb((secoes["ADB"] ?? []).joined(separator: "\n"), origem: .pc) }
            else { devs += dispositivos.filter { $0.origem == .pc } }
        }
        dispositivosMudaram = devs != dispositivos
        if devs != dispositivos { dispositivos = devs }
        if alvoID == nil || !dispositivos.contains(where: { $0.id == alvoID }) {
            alvoID = (dispositivos.first { $0.pronto && $0.origem == .pc } ?? dispositivos.first { $0.pronto })?.id
        }

        if ciclo % 4 == 1 { await lerBranchesEApks() }
        gravarDiagnostico(remoto: r)
        acompanharCrashes()
        if ciclo % 7 == 1 || dispositivosMudaram { await atualizarEmuladores() }
    }

    /// ~/Library/Caches/BuildRemoto/diagnostico.txt — estado da última consulta, para depurar
    private func gravarDiagnostico(remoto r: ShellResult) {
        let texto = """
        \(Date())
        online=\(pc.online) host=\(pc.host) latencia=\(pc.latenciaMs)ms cpu=\(Int(pc.cpu * 100))% ram=\(String(format: "%.1f/%.0f", pc.memUsadaGB, pc.memTotalGB))GB
        celulares=\(dispositivos.map { "\($0.nome)@\($0.origem.rawValue)[\($0.estado)]" })
        sessoes=\(sessoesRemotas.map { "\($0.key)=\($0.value)" }.sorted())
        syncs=\(syncs.map { "\($0.key)=\($0.value.status)" }.sorted())
        ssh_codigo=\(r.code)
        \(r.ok ? "" : r.out)
        """
        let dir = "\(Config.home)/Library/Caches/BuildRemoto"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? texto.write(toFile: "\(dir)/diagnostico.txt", atomically: true, encoding: .utf8)
    }

    private static func secoes(_ texto: String) -> [String: [String]] {
        var r: [String: [String]] = [:]
        var atual = ""
        for linha in texto.split(separator: "\n", omittingEmptySubsequences: true) {
            if linha.hasPrefix("##") { atual = String(linha.dropFirst(2)); r[atual] = []; continue }
            r[atual, default: []].append(String(linha))
        }
        return r
    }

    private func lerRecursos(_ s: [String: [String]]) {
        if let l = s["CPU"]?.first {
            let n = l.split(separator: " ").dropFirst().compactMap { Double($0) }
            if n.count >= 5 {
                let ocioso = n[3] + n[4]
                let total = n.reduce(0, +)
                if let ant = cpuAnterior, total > ant.total {
                    pc.cpu = max(0, min(1, 1 - (ocioso - ant.ocioso) / (total - ant.total)))
                }
                cpuAnterior = (ocioso, total)
            }
        }
        var mem: [String: Double] = [:]
        for l in s["MEM"] ?? [] {
            let p = l.split(separator: " ", omittingEmptySubsequences: true)
            if p.count >= 2 { mem[String(p[0])] = Double(p[1]) }
        }
        if let t = mem["MemTotal:"], let d = mem["MemAvailable:"] {
            pc.memTotalGB = t / 1_048_576
            pc.memUsadaGB = (t - d) / 1_048_576
        }
        pc.nucleos = Int(s["NPROC"]?.first ?? "") ?? 0
    }

    private func lerSessoes(_ s: [String: [String]], online: Bool) {
        guard online else { return }
        let vivas = Set(s["TMUX"] ?? [])
        var status: [String: Int] = [:]
        for l in s["STATUS"] ?? [] {
            let p = l.split(separator: " ")
            if p.count == 2, let c = Int(p[1]) { status[String(p[0])] = c }
        }
        var novo: [String: EstadoSessao] = [:]
        for nome in vivas where Config.projetos.contains(where: { nome.hasPrefix("\($0)-") }) {
            novo[nome] = status[nome].map { .terminou($0) } ?? .rodando
        }
        // Avisos quando algo termina
        for (nome, est) in novo {
            guard case let .terminou(code) = est, sessoesRemotas[nome] == .rodando else { continue }
            terminou(nome, code: code)
        }
        if novo != sessoesRemotas { sessoesRemotas = novo }
    }

    private func terminou(_ nome: String, code: Int) {
        guard let (p, acao) = Self.partes(nome) else { return }
        if !["logs", "logs-tudo", "shell"].contains(acao) {
            let inicio = iniciosSessao.removeValue(forKey: nome)
            Task {
                let log = await Shell.noPC("cat ~/.build-remoto/\(nome).log").out
                await Historico.registrar(projeto: p, acao: acao, origem: "PC", inicio: inicio, codigo: code, log: log)
                versaoHistorico += 1
            }
        }
        if code == 0, acao == "debug" || acao == "release" {
            Task {
                let r = await Shell.run("build-remoto", [p, "pegar-apk", acao])
                if r.ok {
                    await self.registrarNovos(p, sessao: nome, tipo: acao, origem: "PC")
                    Shell.notificar(p, "APK \(acao) pronto ✓")
                    await lerBranchesEApks()
                } else {
                    Shell.notificar(p, "Build ok, mas falhou ao copiar o APK", som: "Basso")
                }
            }
        } else if code == 0 {
            Shell.notificar(p, "\(acao) terminou ✓")
        } else if code != 130 {
            Shell.notificar(p, "\(acao) falhou (código \(code))", som: "Basso")
        }
    }

    static func partes(_ sessao: String) -> (String, String)? {
        guard let p = Config.projetos.first(where: { sessao.hasPrefix("\($0)-") }) else { return nil }
        return (p, String(sessao.dropFirst(p.count + 1)))
    }

    private func lerSync(_ texto: String) {
        var r: [String: SyncInfo] = [:]
        var nome = ""
        for linha in texto.split(separator: "\n") {
            let l = linha.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("Name: ") { nome = String(l.dropFirst(6)); r[nome] = SyncInfo() }
            else if l.hasPrefix("Status: ") { r[nome]?.status = String(l.dropFirst(8)) }
            else if l.lowercased().hasPrefix("last error") || l.hasPrefix("Conflicts") || l.contains("problems") {
                r[nome]?.erro = true
            }
        }
        syncs = r
    }

    private static func lerAdb(_ texto: String, origem: Origem) -> [Dispositivo] {
        texto.split(separator: "\n").compactMap { linha in
            let p = linha.split(separator: " ", omittingEmptySubsequences: true)
            guard p.count >= 2, !linha.hasPrefix("List of"), !linha.hasPrefix("*") else { return nil }
            let modelo = p.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)) } ?? ""
            return Dispositivo(serial: String(p[0]), modelo: modelo, estado: String(p[1]), origem: origem)
        }
    }

    private func lerBranchesEApks() async {
        await atualizarPastasNoGit()
        for p in Config.projetos {
            let r = await Shell.run("git", ["-C", "\(Config.pasta(p))", "branch", "--show-current"])
            branches[p] = r.ok ? r.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            let dir = URL(fileURLWithPath: "\(Config.apkDir)/\(p)")
            let arqs = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
            registrosApk[p] = ApkArquivo.listar(p)
            apks[p] = arqs.filter { $0.pathExtension == "apk" }.compactMap { u in
                let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return Apk(url: u, data: v?.contentModificationDate ?? .distantPast, tamanho: Int64(v?.fileSize ?? 0))
            }.sorted { $0.data > $1.data }
        }
    }

    // MARK: APKs com contexto

    /// APKs recém-copiados (app-*.apk) ganham nome único + JSON com o contexto do build
    private func registrarNovos(_ p: String, sessao: String, tipo: String, origem: String) async {
        let dir = URL(fileURLWithPath: "\(Config.apkDir)/\(p)")
        let novos = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "apk" && $0.lastPathComponent.hasPrefix("app-") }
        var ctx: BuildContexto
        if let c = buildsPendentes.removeValue(forKey: sessao) { ctx = c }
        else { ctx = await BuildContexto.capturar(p, tipo: tipo, origem: origem) }
        for u in novos { _ = await ApkArquivo.registrar(u, ctx: ctx) }
        recarregarApks(p)
        await lerBranchesEApks()
    }

    func recarregarApks(_ p: String) {
        registrosApk[p] = ApkArquivo.listar(p)
    }

    // MARK: Sync

    func syncInfo(_ p: String) -> SyncInfo {
        syncs[p.lowercased().replacingOccurrences(of: "_", with: "-")] ?? SyncInfo()
    }

    func sincronizarAgora(_ p: String) {
        Task {
            _ = await Shell.run("mutagen", ["sync", "flush", p.lowercased().replacingOccurrences(of: "_", with: "-")])
            await atualizar()
        }
    }

    // MARK: Sessões / consoles

    func sessoes(de p: String) -> [String] {
        let remotas = sessoesRemotas.keys.filter { $0.hasPrefix("\(p)-") }
        let locais = sessoesLocais.filter { $0.hasPrefix("\(p)-") }
        return (Set(remotas).union(locais)).sorted()
    }

    func estado(_ sessao: String) -> EstadoSessao? {
        estadosLocais[sessao] ?? sessoesRemotas[sessao]
    }

    let localizacao = LocalizacaoModel()
    @Published var mostrarResumo = false
    @Published var painelNotas = false
    /// Nota ou entrega aberta na tela (o botão de print oferece colocar o print nela)
    var alvoPrint: AlvoPrint?
    private var saudes: [String: SaudeModel] = [:]
    func saude(_ p: String) -> SaudeModel {
        if let s = saudes[p] { return s }
        let s = SaudeModel(projeto: p)
        saudes[p] = s
        return s
    }
    private var realms: [String: RealmModel] = [:]
    func realm(_ p: String) -> RealmModel {
        if let r = realms[p] { return r }
        let r = RealmModel(projeto: p)
        realms[p] = r
        return r
    }

    func git(_ p: String) -> GitModel {
        if let g = gits[p] { return g }
        let g = GitModel(projeto: p)
        gits[p] = g
        return g
    }

    func ferramenta(_ p: String) -> Ferramenta { abaFerramenta[p] ?? .console }

    func console(_ sessao: String) -> ConsoleModel {
        if let c = consoles[sessao] { return c }
        let c = ConsoleModel(nome: sessao)
        consoles[sessao] = c
        if !sessoesLocais.contains(sessao) { c.conectarRemoto() }
        return c
    }

    func executar(_ acao: Acao, _ p: String) {
        if acao != .tela && acao != .terminal { abaFerramenta[p] = .console }
        if modoLocal { executarLocal(acao, p); return }
        let alvo = self.alvo
        let noMac = alvo?.origem == .mac
        switch acao {
        case .rodar: iniciarSessao(p, noMac ? "android" : "run", tunelMac: noMac)
        case .metro: iniciarSessao(p, noMac ? "start" : "metro", tunelMac: noMac)
        case .logs:
            if noMac, let alvo { logsNoMac(p, alvo) } else { iniciarSessao(p, "logs", tunelMac: false) }
        case .tela: abrirTela()
        case .debug: iniciarSessao(p, "debug", tunelMac: nil)
        case .release: iniciarSessao(p, "release", tunelMac: nil)
        case .deps: iniciarSessao(p, "install", tunelMac: nil)
        case .terminal: Shell.abrirNoTerminal("build-remoto \(p) shell", titulo: "\(p) — terminal no PC")
        }
    }

    /// tunelMac: true = precisa do túnel (celular no Mac); false = precisa do adb do PC; nil = tanto faz
    private func iniciarSessao(_ p: String, _ acao: String, tunelMac: Bool?) {
        let nome = "\(p)-\(acao)"
        guard !iniciando.contains(nome) else { return }
        iniciando.insert(nome)
        abaConsole[p] = nome
        Task {
            defer { iniciando.remove(nome) }
            if tunelMac == true {
                guard await garantirTunelMac() else { return }
            } else if tunelMac == false {
                pararTunelMac()
            }
            iniciosSessao[nome] = Date()
            if acao == "debug" || acao == "release" {
                buildsPendentes[nome] = await BuildContexto.capturar(p, tipo: acao, origem: "PC")
            }
            let c = console(nome)
            c.parar()
            c.limpar()
            c.info("→ Sincronizando e iniciando \(acao) no PC…")
            let r = await Shell.run("build-remoto", [p, acao], env: ["BR_DETACH": "1"])
            if !r.ok {
                c.receber(r.out)
                c.info("✗ Não foi possível iniciar (código \(r.code))")
                return
            }
            sessoesRemotas[nome] = .rodando
            c.conectarRemoto()
            await atualizar()
        }
    }

    private func logsNoMac(_ p: String, _ d: Dispositivo) {
        let nome = "\(p)-logs-mac"
        estadosLocais[nome] = .local
        abaConsole[p] = nome
        let c = console(nome)
        c.conectarLocal("adb", ["-s", d.serial, "logcat", "-v", "color",
                                "ReactNativeJS:V", "ReactNative:V", "AndroidRuntime:E", "*:S"]) { [weak self] code in
            self?.estadosLocais[nome] = .terminou(Int(code))
        }
    }

    // MARK: Modo local (só o Mac)

    private func executarLocal(_ acao: Acao, _ p: String) {
        // yarn install só quando package.json/yarn.lock mudaram desde a última vez neste Mac
        let deps = #"h=$(cat package.json yarn.lock 2>/dev/null | shasum); [ "$(cat node_modules/.deps-hash-mac 2>/dev/null)" = "$h" ] || { echo "→ Dependências mudaram, rodando yarn install..."; yarn install --frozen-lockfile && echo "$h" > node_modules/.deps-hash-mac; }"#
        switch acao {
        case .rodar: sessaoLocal(p, "run", "\(deps) && yarn android")
        case .metro: sessaoLocal(p, "metro", "yarn start")
        case .logs:
            if let d = alvo { logsNoMac(p, d) } else { erro = "Conecte um celular no Mac." }
        case .tela: abrirTela()
        case .debug, .release:
            let tipo = acao == .debug ? "debug" : "release"
            let task = acao == .debug ? "assembleDebug" : "assembleRelease"
            let nome = "\(p)-\(tipo)-local"
            Task { buildsPendentes[nome] = await BuildContexto.capturar(p, tipo: tipo, origem: "Mac") }
            sessaoLocal(p, tipo, "\(deps) && cd android && ./gradlew --console=plain \(task)") { [weak self] code in
                guard code == 0 else { return }
                let origem = "\(Config.pasta(p))/android/app/build/outputs/apk/\(tipo)"
                let destino = "\(Config.apkDir)/\(p)"
                try? FileManager.default.createDirectory(atPath: destino, withIntermediateDirectories: true)
                for a in (try? FileManager.default.contentsOfDirectory(atPath: origem)) ?? [] where a.hasSuffix(".apk") {
                    try? FileManager.default.removeItem(atPath: "\(destino)/\(a)")
                    try? FileManager.default.copyItem(atPath: "\(origem)/\(a)", toPath: "\(destino)/\(a)")
                }
                Task {
                    await self?.registrarNovos(p, sessao: nome, tipo: tipo, origem: "Mac")
                    Shell.notificar(p, "APK \(tipo) pronto ✓ (Mac)")
                }
            }
        case .deps: sessaoLocal(p, "install", "rm -f node_modules/.deps-hash-mac; \(deps)")
        case .terminal:
            Shell.abrirNoTerminal("cd \(Adb.aspas("\(Config.pasta(p))")) && exec zsh -l", titulo: "\(p) — terminal")
        }
    }

    private func sessaoLocal(_ p: String, _ acao: String, _ comando: String, aoTerminar: ((Int32) -> Void)? = nil) {
        let nome = "\(p)-\(acao)-local"
        abaConsole[p] = nome
        if estadosLocais[nome] == .local, consoles[nome]?.rodandoLocal == true { return }
        estadosLocais[nome] = .local
        let c = console(nome)
        let inicio = Date()
        c.conectarTerminalLocal(comando, pasta: "\(Config.pasta(p))") { [weak self] code in
            self?.estadosLocais[nome] = .terminou(Int(code))
            let log = c.bruto
            Task {
                await Historico.registrar(projeto: p, acao: acao, origem: "Mac", inicio: inicio, codigo: Int(code), log: log)
                self?.versaoHistorico += 1
            }
            if code == 0 { Shell.notificar(p, "\(acao) terminou ✓ (Mac)") }
            else if code != 130 && code != 2 { Shell.notificar(p, "\(acao) falhou (código \(code))", som: "Basso") }
            aoTerminar?(code)
        }
    }

    /// Ações do menu "Mais": Metro limpando cache e Gradle clean
    func extra(_ p: String, _ acao: String) {
        abaFerramenta[p] = .console
        if modoLocal {
            let usaExpo = ((try? String(contentsOfFile: "\(Config.pasta(p))/package.json", encoding: .utf8)) ?? "").contains("\"expo\":")
            switch acao {
            case "metro-limpo": sessaoLocal(p, "metro", usaExpo ? "yarn start --clear" : "yarn start --reset-cache")
            default: sessaoLocal(p, "clean", "cd android && ./gradlew --console=plain clean")
            }
        } else {
            iniciarSessao(p, acao, tunelMac: acao == "clean" ? nil : false)
        }
    }

    // MARK: Vigia de crashes e relatório de bug

    private func acompanharCrashes() {
        vigia.projetoAtual = { [weak self] in self?.selecionado }
        // Com o túnel do celular do Mac ativo, o adb do PC fica indisponível
        let d = alvo
        if d?.origem == .pc && tunelMacAtivo { vigia.parar(); return }
        vigia.acompanhar(d)
    }

    /// Captura print/logs/contexto na hora e abre o formulário do relatório
    func gerarRelatorio(_ p: String) {
        guard let d = alvo else { erro = "Conecte um celular para gerar o relatório."; return }
        guard !gerandoRelatorio else { return }
        gerandoRelatorio = true
        Task {
            capturaBug = await CapturaBug.capturar(projeto: p, d: d, video: gravacao.ultimoVideo, crashes: vigia.ultimos)
            gerandoRelatorio = false
        }
    }

    func bugSalvo(_ b: BugRegistro) {
        gravacao.ultimoVideo = nil
        bugSelecionado[b.meta.projeto] = b.pasta
        abaFerramenta[b.meta.projeto] = .bugs
        versaoBugs += 1
    }

    // MARK: Comandos personalizados / scripts do package.json

    func rodarComando(_ p: String, nome: String, comando: String, noPC: Bool) {
        let slug = "cmd-" + nome.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        abaFerramenta[p] = .console
        guard noPC else { sessaoLocal(p, slug, comando); return }
        let nomeSessao = "\(p)-\(slug)"
        abaConsole[p] = nomeSessao
        iniciando.insert(nomeSessao)
        Task {
            defer { iniciando.remove(nomeSessao) }
            _ = await Shell.run("mutagen", ["sync", "flush", p.lowercased().replacingOccurrences(of: "_", with: "-")])
            let r = await Shell.run("ssh", Config.sshCliente + [Config.pcHost, "bash -lc 'br-iniciar \(nomeSessao)'"],
                                    stdin: Data("cd ~/apps/\(p) && \(comando)\n".utf8))
            guard r.ok || r.code == 3 else { erro = "Falha ao iniciar \(nome) no PC:\n\(r.out)"; return }
            iniciosSessao[nomeSessao] = Date()
            sessoesRemotas[nomeSessao] = .rodando
            console(nomeSessao).conectarRemoto()
        }
    }

    // MARK: Emuladores e simuladores

    func atualizarEmuladores() async {
        let (lista, nomes) = await Emuladores.listar(pcOnline: !modoLocal && pc.online, dispositivos: dispositivos)
        Dispositivo.apelidos = nomes
        emuladores = lista
        objectWillChange.send()   // nomes dos emuladores na lista de dispositivos
    }

    func ligarEmulador(_ e: Emulador, depois: (() -> Void)? = nil) {
        ligandoEmulador.insert(e.id)
        Task {
            let r = await Emuladores.ligar(e)
            if !r.ok && e.plataforma == .android { erro = "Não consegui ligar \(e.titulo):\n\(r.out)" }
            Shell.notificar(e.titulo, "Ligando \(e.plataforma == .ios ? "simulador" : "emulador")…", som: "Pop")
            // Android leva alguns segundos até aparecer no adb
            for _ in 0..<(e.plataforma == .android ? 20 : 1) {
                try? await Task.sleep(for: .seconds(3))
                await atualizar()
                await atualizarEmuladores()
                if emuladores.first(where: { $0.id == e.id })?.ligado == true { break }
            }
            ligandoEmulador.remove(e.id)
            if e.plataforma == .android, let d = dispositivos.first(where: { Dispositivo.apelidos[$0.serial] == e.nome && $0.origem == e.origem }) {
                alvoID = d.id
            }
            depois?()
        }
    }

    func desligarEmulador(_ e: Emulador) {
        let serial = dispositivos.first { Dispositivo.apelidos[$0.serial] == e.nome && $0.origem == e.origem }?.serial
        Task {
            await Emuladores.desligar(e, serial: serial)
            try? await Task.sleep(for: .seconds(2))
            await atualizar()
            await atualizarEmuladores()
        }
    }

    /// yarn ios / expo run:ios no simulador escolhido (sempre roda no Mac)
    func rodarIOS(_ p: String, _ e: Emulador) {
        guard let udid = e.udid else { return }
        let usaExpo = ((try? String(contentsOfFile: "\(Config.pasta(p))/package.json", encoding: .utf8)) ?? "").contains("\"expo\":")
        abaFerramenta[p] = .console
        sessaoLocal(p, "ios", usaExpo ? "npx expo run:ios --device \(udid)" : "npx react-native run-ios --udid \(udid)")
    }

    // MARK: Tela

    func abrirTela() {
        mostrarTela = true
        guard let d = alvo else { return }
        if !mirror.ativo || mirror.dispositivo?.id != d.id {
            if d.origem == .pc { pararTunelMac() }
            mirror.iniciar(d)
        }
    }

    func espelhar(_ d: Dispositivo?) {
        guard let d else { erro = "Nenhum celular conectado no PC ou no Mac."; return }
        let p: Process
        if d.origem == .mac {
            p = Shell.processo("scrcpy", ["-s", d.serial, "--stay-awake", "--window-title", d.nome])
        } else {
            pararTunelMac()
            p = Shell.processo("build-remoto", ["tela-pc", "-s", d.serial, "--window-title", "\(d.nome) (PC)"])
        }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try? p.run()
    }

    /// ⌘R: manda "r" para a sessão de app/Metro que estiver rodando no projeto atual
    func recarregarAtivo() {
        guard let p = selecionado else { return }
        let alvos = ["run", "android", "metro", "start", "metro-limpo"]
        if let s = sessoes(de: p).first(where: { s in
            let a = (Self.partes(s)?.1 ?? "").replacingOccurrences(of: "-local", with: "")
            return alvos.contains(a) && (estado(s) == .rodando || estado(s) == .local)
        }) {
            digitar(s, .texto("r"))
        }
    }

    func enviarTecla(_ sessao: String, _ tecla: String) {
        if let c = consoles[sessao], estadosLocais[sessao] != nil {
            c.enviar(tecla == "C-c" ? "\u{03}" : tecla)
            return
        }
        Task { _ = await Shell.noPC("tmux send-keys -t '=\(sessao):' \(tecla)") }
    }

    /// Teclado do console interativo -> sessão (stdin local ou tmux send-keys no PC)
    func digitar(_ sessao: String, _ t: TeclaTerminal) {
        if let c = consoles[sessao], estadosLocais[sessao] != nil {
            switch t {
            case let .texto(x): c.enviar(x)
            case let .especial(_, local): c.enviar(local)
            }
            return
        }
        let args: String
        switch t {
        case let .texto(x): args = "-l " + Adb.aspas(x)
        case let .especial(tmux, _): args = tmux
        }
        Task { _ = await Shell.noPC("tmux send-keys -t '=\(sessao):' \(args)") }
    }

    func pararSessao(_ sessao: String) {
        if estadosLocais[sessao] != nil {
            if sessao.hasSuffix("-local") {
                consoles[sessao]?.enviar("\u{03}")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.consoles[sessao]?.parar() }
            } else {
                consoles[sessao]?.parar()
            }
            return
        }
        enviarTecla(sessao, "C-c")
    }

    func fecharSessao(_ sessao: String) {
        consoles[sessao]?.parar()
        consoles[sessao] = nil
        if estadosLocais[sessao] != nil {
            estadosLocais[sessao] = nil
        } else {
            sessoesRemotas[sessao] = nil
            // encerra a sessão e todos os processos dela (senão o Metro fica órfão segurando a porta 8081)
            Task { _ = await Shell.noPC("~/.local/bin/br-encerrar '\(sessao)' 2>/dev/null || tmux kill-session -t '=\(sessao)' 2>/dev/null; rm -f ~/.build-remoto/\(sessao).status") }
        }
        if let (p, _) = Self.partes(sessao), abaConsole[p] == sessao {
            abaConsole[p] = sessoes(de: p).first
        }
    }

    func abrirNoTerminal(_ sessao: String) {
        Shell.abrirNoTerminal("ssh -t \(Config.pcHost) tmux attach -t '=\(sessao)'", titulo: sessao)
    }

    // MARK: Túnel para o celular ligado no Mac

    private func garantirTunelMac() async -> Bool {
        if let t = tunel, t.isRunning { return true }
        let p = Shell.processo("build-remoto", ["tunel-mac"])
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.tunelMacAtivo = false }
        }
        do { try p.run() } catch { erro = "Falha ao abrir o túnel: \(error.localizedDescription)"; return false }
        tunel = p
        try? await Task.sleep(for: .seconds(3))
        guard p.isRunning else {
            erro = "Não consegui abrir o túnel para o celular do Mac (porta 5037/8081 ocupada?)."
            return false
        }
        tunelMacAtivo = true
        return true
    }

    func pararTunelMac() {
        tunel?.terminate()
        tunel = nil
        tunelMacAtivo = false
    }

    // MARK: APKs

    func instalarApk(_ apk: Apk, em d: Dispositivo) {
        Task {
            Shell.notificar(d.nome, "Instalando \(apk.url.lastPathComponent)…", som: "Pop")
            let r: ShellResult
            if d.origem == .mac {
                r = await Shell.run("adb", ["-s", d.serial, "install", "-r", apk.url.path])
            } else {
                let dados = (try? Data(contentsOf: apk.url)) ?? Data()
                _ = await Shell.run("ssh", Config.sshCliente + [Config.pcHost, "cat > /tmp/br-install.apk"], stdin: dados)
                r = await Shell.noPC("\(Config.adbWin) start-server >/dev/null 2>&1; \(Config.adbPC) -s \(d.serial) install -r /tmp/br-install.apk")
            }
            Shell.notificar(d.nome, r.ok ? "APK instalado ✓" : "Falha ao instalar", som: r.ok ? "Glass" : "Basso")
            if !r.ok { erro = r.out }
        }
    }

    // MARK: Rede

    func rede(_ args: [String]) async -> String {
        let r = await Shell.run("pc-rede", args)
        reconectar()
        return r.out
    }
}
