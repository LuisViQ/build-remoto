import SQLite3
import SwiftUI

// MARK: - Vigia de crashes
//
// Logcat leve em segundo plano, só com erros. Ao detectar crash nativo, erro JS ou ANR,
// junta o trecho do erro, guarda no Histórico e mostra uma notificação.

@MainActor
final class VigiaCrashes: ObservableObject {
    @Published var ativa = UserDefaults.standard.object(forKey: "vigiaCrashes") as? Bool ?? true {
        didSet { UserDefaults.standard.set(ativa, forKey: "vigiaCrashes"); if !ativa { parar() } }
    }
    @Published var ultimos: [(Date, String, String)] = []   // (quando, tipo, primeira linha)
    private var proc: Process?
    private var dispositivoID: String?
    private var resto = ""
    private var coletando: (tipo: String, linhas: [String], inicio: Date)?
    var projetoAtual: () -> String? = { nil }

    func acompanhar(_ d: Dispositivo?) {
        guard ativa, let d, d.pronto else { parar(); return }
        if dispositivoID == d.id, proc?.isRunning == true { return }
        parar()
        dispositivoID = d.id
        proc = Adb.stream(d, ["logcat", "-v", "threadtime", "-T", "1",
                              "AndroidRuntime:E", "ReactNativeJS:E", "ReactNative:E", "ActivityManager:E", "*:S"],
                          onTexto: { [weak self] in self?.receber($0) },
                          onFim: { [weak self] _ in self?.dispositivoID = nil })
    }

    func parar() {
        proc?.terminate(); proc = nil; dispositivoID = nil
    }

    private func receber(_ t: String) {
        let s = resto + t
        var linhas = s.components(separatedBy: "\n")
        resto = linhas.removeLast()
        for l in linhas.map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }) {
            if var c = coletando {
                c.linhas.append(l); coletando = c
                continue
            }
            var tipo: String?
            if l.contains("FATAL EXCEPTION") || l.contains("Fatal signal") { tipo = "crash" }
            else if l.contains("ANR in ") { tipo = "anr" }
            else if l.contains("ReactNativeJS") || l.contains(" ReactNative:") {
                if l.range(of: #"Error|Unhandled|Exception|Invariant Violation"#, options: .regularExpression) != nil { tipo = "erro-js" }
            }
            guard let tipo else { continue }
            coletando = (tipo, [l], Date())
            // Junta as linhas seguintes (stack trace) por 1,5 s e então registra
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.fechar() }
        }
    }

    private func fechar() {
        guard let c = coletando, let p = projetoAtual() else { coletando = nil; return }
        coletando = nil
        let texto = c.linhas.joined(separator: "\n")
        let primeira = c.linhas.first.map { $0.components(separatedBy: ": ").dropFirst().joined(separator: ": ") } ?? ""
        let titulo = ["crash": "💥 Crash do app", "anr": "🧊 App travou (ANR)", "erro-js": "⚠️ Erro de JavaScript"][c.tipo] ?? c.tipo
        ultimos.insert((Date(), titulo, primeira), at: 0)
        if ultimos.count > 20 { ultimos.removeLast() }
        Shell.notificar(titulo, String(primeira.prefix(140)), som: "Sosumi")
        Task { await Historico.registrar(projeto: p, acao: c.tipo, origem: "Celular", inicio: c.inicio, codigo: 1, log: texto) }
    }
}

// MARK: - Gravação de tela e relatório de bug

@MainActor
final class Gravacao: ObservableObject {
    @Published var gravando = false
    @Published var inicio: Date?
    @Published var ultimoVideo: URL?
    private var proc: Process?
    private var dispositivo: Dispositivo?
    private let caminho = "/sdcard/build-remoto-gravacao.mp4"

    func iniciar(_ d: Dispositivo) {
        dispositivo = d
        // screenrecord para sozinho em 3 min (limite do Android)
        proc = Adb.stream(d, ["shell", "screenrecord", "--bit-rate", "6000000", caminho],
                          onTexto: { _ in }, onFim: { _ in })
        gravando = true
        inicio = Date()
    }

    func parar() async -> URL? {
        guard let d = dispositivo else { return nil }
        _ = await Adb.shell(d, "pkill -INT screenrecord")   // finaliza o MP4 corretamente
        try? await Task.sleep(for: .seconds(1.5))
        proc?.terminate(); proc = nil
        gravando = false
        guard let video = await Adb.dados(d, ["exec-out", "cat", caminho]), video.count > 1000 else { return nil }
        _ = await Adb.shell(d, "rm -f \(caminho)")
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd 'às' HH.mm.ss"
        let url = URL(fileURLWithPath: "\(Config.home)/Desktop/Gravação \(d.nome) \(fmt.string(from: Date())).mp4")
        try? video.write(to: url)
        ultimoVideo = url
        return url
    }
}

// MARK: - Dados do app (AsyncStorage e Realm)

struct Falha: Error {
    let texto: String
    init(_ t: String) { texto = t }
}

struct ItemStorage: Identifiable {
    let chave: String
    let valor: String
    var id: String { chave }
    var formatado: String {
        guard let d = valor.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]),
              JSONSerialization.isValidJSONObject(o) || o is [Any],
              let f = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) else { return valor }
        return String(decoding: f, as: UTF8.self)
    }
}

enum DadosApp {
    /// Baixa o banco do AsyncStorage (SQLite "RKStorage") via run-as e lê as chaves
    static func asyncStorage(_ d: Dispositivo, pacote: String) async -> Result<[ItemStorage], Falha> {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("br-storage-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var baixou = false
        for sufixo in ["", "-wal", "-shm"] {
            if let dados = await Adb.dados(d, ["exec-out", "run-as", pacote, "cat", "databases/RKStorage\(sufixo)"]),
               !dados.isEmpty, !String(decoding: dados.prefix(60), as: UTF8.self).contains("run-as:") {
                try? dados.write(to: dir.appendingPathComponent("RKStorage\(sufixo)"))
                if sufixo.isEmpty { baixou = true }
            }
        }
        guard baixou else {
            return .failure(Falha("Não consegui ler o AsyncStorage. Só funciona em builds de debug (run-as) e depois que o app salvou algo."))
        }
        var db: OpaquePointer?
        guard sqlite3_open(dir.appendingPathComponent("RKStorage").path, &db) == SQLITE_OK else { return .failure(Falha("Banco inválido")) }
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT key, value FROM catalystLocalStorage ORDER BY key", -1, &st, nil) == SQLITE_OK else {
            return .failure(Falha("Tabela catalystLocalStorage não encontrada"))
        }
        defer { sqlite3_finalize(st) }
        var itens: [ItemStorage] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let k = sqlite3_column_text(st, 0).map { String(cString: $0) } ?? ""
            let v = sqlite3_column_text(st, 1).map { String(cString: $0) } ?? ""
            itens.append(ItemStorage(chave: k, valor: v))
        }
        return .success(itens)
    }

    /// Copia os arquivos .realm do app para a Mesa
    static func baixarRealm(_ d: Dispositivo, pacote: String) async -> Result<URL, Falha> {
        let lista = await Adb.shell(d, "run-as \(pacote) ls files").out
        guard !lista.contains("run-as:") else { return .failure(Falha("run-as negado: precisa ser um build de debug")) }
        let arqs = lista.split(whereSeparator: \.isNewline).map(String.init).filter { $0.hasSuffix(".realm") }
        guard !arqs.isEmpty else { return .failure(Falha("Nenhum arquivo .realm em files/ (o app usa Realm?)")) }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH.mm"
        let pasta = URL(fileURLWithPath: "\(Config.home)/Desktop/Realm \(pacote) \(fmt.string(from: Date()))")
        try? FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        for a in arqs {
            if let dados = await Adb.dados(d, ["exec-out", "run-as", pacote, "cat", "files/\(a)"]) {
                try? dados.write(to: pasta.appendingPathComponent(a))
            }
        }
        return .success(pasta)
    }
}

struct AsyncStorageSheet: View {
    let itens: [ItemStorage]
    let pacote: String
    @Environment(\.dismiss) private var dismiss
    @State private var busca = ""
    @State private var selecionado: ItemStorage?

    var body: some View {
        let filtrados = itens.filter { busca.isEmpty || $0.chave.localizedCaseInsensitiveContains(busca) || $0.valor.localizedCaseInsensitiveContains(busca) }
        VStack(spacing: 0) {
            HStack {
                Text("AsyncStorage — \(pacote)").font(.headline)
                Spacer()
                TextField("Buscar", text: $busca).textFieldStyle(.roundedBorder).frame(width: 220)
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            HSplitView {
                List(filtrados, selection: $selecionado) { i in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(i.chave).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1)
                        Text(i.valor.prefix(90)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(i.id)
                    .tag(Optional(i))
                }
                .frame(minWidth: 260, idealWidth: 320)
                Group {
                    if let s = selecionado {
                        VStack(alignment: .leading) {
                            HStack {
                                Text(s.chave).font(.system(size: 12.5, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                                Spacer()
                                Button("Copiar valor") {
                                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.valor, forType: .string)
                                }
                            }
                            ScrollView {
                                Text(s.formatado).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(12)
                    } else {
                        ContentUnavailableView("\(itens.count) chaves", systemImage: "tray.full")
                    }
                }
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 860, height: 560)
    }
}

extension ItemStorage: Hashable {
    static func == (a: ItemStorage, b: ItemStorage) -> Bool { a.chave == b.chave }
    func hash(into h: inout Hasher) { h.combine(chave) }
}

// MARK: - Diagnóstico

struct Verificacao: Identifiable {
    enum Nivel { case ok, aviso, erro, rodando }
    let id = UUID()
    var titulo: String
    var detalhe = ""
    var nivel: Nivel = .rodando
    var corrigir: (String, () async -> Void)?
}

@MainActor
final class Diagnostico: ObservableObject {
    @Published var itens: [Verificacao] = []
    @Published var rodando = false

    func rodar(_ app: AppState) async {
        rodando = true
        itens = []
        func add(_ v: Verificacao) { itens.append(v) }

        if app.modoLocal {
            await checarMac(app)
            rodando = false
            return
        }
        // PC
        let t0 = Date()
        let pc = await Shell.noPC("""
        echo "node=$(bash -lc 'node -v' 2>/dev/null)"; echo "java=$(java -version 2>&1 | head -1)"
        echo "disco=$(df -h ~ | awk 'NR==2{print $4" livres de "$2" ("$5" usado)"}')"
        echo "discopct=$(df ~ | awk 'NR==2{print $5}' | tr -d %)"
        echo "gradle=$(pgrep -fc GradleDaemon)"
        echo "adbwin=$(timeout 5 \(Config.adbWin) devices 2>/dev/null | tr -d '\\r' | tail -n +2 | grep -c device)"
        echo "ram=$(free -g | awk '/Mem/{print $7" GB livres de "$2" GB"}')"
        """)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        guard pc.ok else {
            add(Verificacao(titulo: "PC de build", detalhe: "Sem conexão. Abra o Ubuntu no Windows ou use Rede → Procurar o PC.", nivel: .erro,
                            corrigir: ("Procurar o PC", { _ = await app.rede(["procurar"]) })))
            await checarMac(app)
            rodando = false
            return
        }
        var v: [String: String] = [:]
        for l in pc.out.split(separator: "\n") {
            let p = l.split(separator: "=", maxSplits: 1)
            if p.count == 2 { v[String(p[0])] = String(p[1]) }
        }
        add(Verificacao(titulo: "PC de build online", detalhe: "\(app.pc.host) · \(ms) ms\(app.pc.viaTailscale ? " · Tailscale" : "")",
                        nivel: ms > 1500 ? .aviso : .ok))
        let pct = Int(v["discopct"] ?? "0") ?? 0
        add(Verificacao(titulo: "Espaço em disco no WSL", detalhe: v["disco"] ?? "?", nivel: pct > 90 ? .erro : pct > 80 ? .aviso : .ok,
                        corrigir: pct > 80 ? ("Limpar caches do Gradle", {
                            _ = await Shell.noPC("cd ~/apps && for d in */android; do (cd $d && ./gradlew --stop >/dev/null 2>&1); done; rm -rf ~/.gradle/caches/build-cache-* ~/.gradle/caches/transforms-*")
                        }) : nil))
        add(Verificacao(titulo: "Memória livre no PC", detalhe: v["ram"] ?? "?", nivel: .ok))
        let nodeMac = await Shell.run("zsh", ["-lic", "node -v"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").last.map(String.init) ?? "?"
        let nodePC = v["node"] ?? "?"
        add(Verificacao(titulo: "Versão do Node", detalhe: "Mac \(nodeMac) · PC \(nodePC)",
                        nivel: nodeMac == nodePC ? .ok : .aviso))
        add(Verificacao(titulo: "Java no PC", detalhe: v["java"] ?? "não encontrado", nivel: (v["java"] ?? "").contains("17") ? .ok : .aviso))
        let daemons = Int(v["gradle"] ?? "0") ?? 0
        add(Verificacao(titulo: "Gradle daemons rodando", detalhe: "\(daemons) (cada um usa até 8 GB)", nivel: daemons > 2 ? .aviso : .ok,
                        corrigir: daemons > 0 ? ("Parar daemons", { _ = await Shell.noPC("pkill -f GradleDaemon; true") }) : nil))
        let adbWin = Int(v["adbwin"] ?? "0") ?? 0
        add(Verificacao(titulo: "Celular no PC (adb do Windows)", detalhe: adbWin > 0 ? "\(adbWin) conectado(s)" : "nenhum celular ou adb parado",
                        nivel: adbWin > 0 ? .ok : .aviso,
                        corrigir: ("Reiniciar adb do Windows", { _ = await Shell.noPC("\(Config.adbWin) kill-server; \(Config.adbWin) start-server") })))
        // Sincronização
        for p in Config.projetos {
            let s = app.syncInfo(p).resumo
            add(Verificacao(titulo: "Sincronização \(p)", detalhe: s.texto, nivel: s.texto == "Sincronizado" ? .ok : s.cor == .red ? .erro : .aviso,
                            corrigir: s.texto == "Sincronizado" ? nil : ("Reconectar", {
                                let n = p.lowercased().replacingOccurrences(of: "_", with: "-")
                                _ = await Shell.run("mutagen", ["sync", "reset", n])
                                _ = await Shell.run("mutagen", ["sync", "resume", n])
                            })))
        }
        await checarMac(app)
        rodando = false
    }

    private func checarMac(_ app: AppState) async {
        let disco = (try? URL(fileURLWithPath: Config.home).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let gb = Double(disco) / 1_073_741_824
        itens.append(Verificacao(titulo: "Espaço livre no Mac", detalhe: String(format: "%.0f GB", gb),
                                 nivel: gb < 10 ? .erro : gb < 25 ? .aviso : .ok))
        let ferr = await Shell.run("zsh", ["-lic", #"""
        echo "node=$(node -v 2>/dev/null)"; echo "yarn=$(yarn -v 2>/dev/null)"
        echo "java=$(java -version 2>&1 | head -1)"; echo "javahome=$JAVA_HOME"
        echo "sdk=${ANDROID_HOME:-$HOME/Library/Android/sdk}"; echo "bt=$(ls ${ANDROID_HOME:-$HOME/Library/Android/sdk}/build-tools 2>/dev/null | tail -1)"
        """#]).out
        var f: [String: String] = [:]
        for l in ferr.split(separator: "\n") {
            let p = l.split(separator: "=", maxSplits: 1)
            if p.count == 2 { f[String(p[0])] = String(p[1]) }
        }
        let local = app.modoLocal
        itens.append(Verificacao(titulo: "Node e yarn no Mac", detalhe: "Node \(f["node"] ?? "não encontrado") · yarn \(f["yarn"] ?? "não encontrado")",
                                 nivel: f["node"] == nil ? (local ? .erro : .aviso) : .ok))
        itens.append(Verificacao(titulo: "Java no Mac", detalhe: "\(f["java"] ?? "não encontrado")\(f["javahome"].map { " · JAVA_HOME=\($0)" } ?? " · JAVA_HOME não definido")",
                                 nivel: (f["java"] ?? "").contains("version") ? .ok : (local ? .erro : .aviso)))
        itens.append(Verificacao(titulo: "Android SDK no Mac", detalhe: f["bt"].map { "build-tools \($0) · \(f["sdk"] ?? "")" } ?? "não encontrado",
                                 nivel: f["bt"] != nil ? .ok : (local ? .erro : .aviso)))
        let adb = await Shell.run("adb", ["version"])
        itens.append(Verificacao(titulo: "adb no Mac", detalhe: adb.out.split(separator: "\n").dropFirst().first.map(String.init) ?? "não encontrado",
                                 nivel: adb.ok ? .ok : .erro))
        let celulares = app.dispositivos.filter { $0.pronto }
        let pendentes = app.dispositivos.filter { !$0.pronto }
        itens.append(Verificacao(titulo: "Celulares", detalhe: celulares.isEmpty ? "nenhum pronto" : celulares.map { "\($0.nome) (\($0.origem.rawValue))" }.joined(separator: ", "),
                                 nivel: celulares.isEmpty ? .aviso : .ok))
        for d in pendentes {
            itens.append(Verificacao(titulo: "\(d.nome): \(d.estado)",
                                     detalhe: d.estado == "unauthorized" ? "Aceite o aviso \"Permitir depuração USB\" no celular" : "Reconecte o cabo",
                                     nivel: .erro))
        }
    }
}

struct DiagnosticoSheet: View {
    @EnvironmentObject var app: AppState
    @StateObject private var diag = Diagnostico()
    @Environment(\.dismiss) private var dismiss
    @State private var aba = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "stethoscope").font(.title2).foregroundStyle(.teal)
                VStack(alignment: .leading) {
                    Text("Diagnóstico").font(.title2.bold())
                    Text(app.modoLocal ? "Modo Só o Mac" : "PC + Mac + celulares").foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $aba) {
                    Label("Verificações", systemImage: "checklist").tag(0)
                    Label("Armazenamento do Mac", systemImage: "internaldrive").tag(1)
                }
                .pickerStyle(.segmented).frame(width: 330)
                if aba == 0 {
                    Button { Task { await diag.rodar(app) } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(diag.rodando).help("Verificar de novo")
                }
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(18)
            Divider()
            if aba == 1 { ArmazenamentoView() } else {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(diag.itens) { v in
                        HStack(spacing: 12) {
                            Image(systemName: icone(v.nivel)).foregroundStyle(cor(v.nivel)).font(.system(size: 17))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(v.titulo).font(.system(size: 13, weight: .semibold))
                                Text(v.detalhe).font(.system(size: 11.5)).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            if let (rotulo, acao) = v.corrigir, v.nivel != .ok || rotulo.hasPrefix("Parar") {
                                Botao(rotulo, "wrench.and.screwdriver") { await acao(); await diag.rodar(app) }
                                    .controlSize(.small)
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(cor(v.nivel).opacity(0.07)))
                    }
                    if diag.rodando { ProgressView().padding() }
                }
                .padding(18)
            }
            }
        }
        .frame(width: 820, height: 680)
        .task { await diag.rodar(app) }
    }

    private func icone(_ n: Verificacao.Nivel) -> String {
        switch n { case .ok: "checkmark.circle.fill"; case .aviso: "exclamationmark.triangle.fill"; case .erro: "xmark.octagon.fill"; case .rodando: "circle.dotted" }
    }
    private func cor(_ n: Verificacao.Nivel) -> Color {
        switch n { case .ok: .green; case .aviso: .orange; case .erro: .red; case .rodando: .secondary }
    }
}

// MARK: - Paleta de comandos (⌘K)

struct Comando: Identifiable {
    let id = UUID()
    let titulo: String
    let subtitulo: String
    let icone: String
    let acao: () -> Void
}

struct PaletaComandos: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var busca = ""
    @State private var indice = 0
    @FocusState private var foco: Bool

    private var comandos: [Comando] {
        var c: [Comando] = []
        let atual = app.selecionado ?? Config.projetos[0]
        for p in [atual] + Config.projetos.filter({ $0 != atual }) {
            for a in Acao.allCases {
                c.append(Comando(titulo: "\(a.titulo) — \(p)", subtitulo: a.subtitulo, icone: a.icone) {
                    app.selecionado = p; app.executar(a, p)
                })
            }
            for f in Ferramenta.allCases {
                c.append(Comando(titulo: "Abrir \(f.rawValue) — \(p)", subtitulo: "aba", icone: f.icone) {
                    app.selecionado = p; app.abaFerramenta[p] = f
                })
            }
            c.append(Comando(titulo: "Relatório de bug — \(p)", subtitulo: "print, logs e contexto na Mesa", icone: "ladybug") {
                app.selecionado = p; app.gerarRelatorio(p)
            })
        }
        c.append(Comando(titulo: "Diagnóstico", subtitulo: "verificar PC, sync e celulares", icone: "stethoscope") { app.mostrarDiagnostico = true })
        c.append(Comando(titulo: app.modoLocal ? "Usar o PC (compartilhado)" : "Usar só o Mac", subtitulo: "trocar modo", icone: "arrow.left.arrow.right") {
            app.modoLocal.toggle()
        })
        c.append(Comando(titulo: "Mostrar/ocultar tela do celular", subtitulo: "⌘T", icone: "iphone.gen3") {
            if app.mostrarTela { app.mostrarTela = false } else { app.abrirTela() }
        })
        return c
    }

    private var filtrados: [Comando] {
        let q = busca.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        guard !q.isEmpty else { return Array(comandos.prefix(14)) }
        let termos = q.split(separator: " ")
        return comandos.filter { cmd in
            let t = (cmd.titulo + " " + cmd.subtitulo).lowercased().folding(options: .diacriticInsensitive, locale: nil)
            return termos.allSatisfy { t.contains($0) }
        }
    }

    var body: some View {
        let lista = filtrados
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "command").foregroundStyle(.secondary)
                TextField("O que você quer fazer? (ex.: rodar obras, apk release, docs)", text: $busca)
                    .textFieldStyle(.plain).font(.system(size: 16))
                    .focused($foco)
                    .onSubmit { executar(lista) }
                    .onKeyPress(.downArrow) { indice = min(indice + 1, max(0, lista.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { indice = max(indice - 1, 0); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(lista.enumerated()), id: \.element.id) { i, cmd in
                            HStack(spacing: 10) {
                                Image(systemName: cmd.icone).frame(width: 20).foregroundStyle(i == indice ? .white : .secondary)
                                Text(cmd.titulo).font(.system(size: 13))
                                Spacer()
                                Text(cmd.subtitulo).font(.system(size: 11)).foregroundStyle(i == indice ? .white.opacity(0.8) : .secondary)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 7).fill(i == indice ? Color.accentColor : .clear))
                            .foregroundStyle(i == indice ? .white : .primary)
                            .contentShape(Rectangle())
                            .onTapGesture { indice = i; executar(lista) }
                            .id(i)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: indice) { _, i in proxy.scrollTo(i) }
            }
        }
        .frame(width: 620, height: 420)
        .onAppear { foco = true }
        .onChange(of: busca) { _, _ in indice = 0 }
    }

    private func executar(_ lista: [Comando]) {
        guard lista.indices.contains(indice) else { return }
        let c = lista[indice]
        dismiss()
        DispatchQueue.main.async { c.acao() }
    }
}
