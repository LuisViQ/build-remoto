import SwiftUI
import WebKit

// MARK: - Relatórios de bug
//
// Fluxo: o botão de bug captura print + logs + contexto na hora e abre um formulário.
// Ao salvar, cria ~/Documents/BuildRemoto/Bugs/<projeto>/<data> - <título>/ com README.md,
// print, logs, vídeo e bug.json (metadados/status), e mostra o relatório na aba Bugs.

/// O que é capturado no momento em que o botão é clicado
struct CapturaBug {
    let projeto: String
    let dispositivo: String
    let print: Data?
    let logApp: String
    let logCompleto: String
    let pacote: String
    let versao: String
    let android: String
    let tela: String
    let branch: String
    let commit: String
    let crashes: [(Date, String, String)]
    let video: URL?
    let quando = Date()

    static func capturar(projeto: String, d: Dispositivo, video: URL?, crashes: [(Date, String, String)]) async -> CapturaBug {
        let pkg = await Adb.pacote(projeto, em: d) ?? ""
        let argsPrint = await Adb.argsPrint(d)
        async let print = Adb.dados(d, argsPrint)
        async let logTudo = Adb.run(d, ["logcat", "-d", "-v", "threadtime", "-t", "1500"])
        async let pid = Adb.shell(d, "pidof \(pkg)")
        async let versao = Adb.shell(d, "dumpsys package \(pkg) | grep -m1 versionName; dumpsys package \(pkg) | grep -m1 versionCode")
        async let info = Adb.shell(d, "getprop ro.build.version.release; wm size | tail -1")
        let g = { (a: [String]) async -> String in
            await Shell.run("git", ["-C", "\(Config.pasta(projeto))"] + a).out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let log = await logTudo.out
        let pids = Set(await pid.out.split(whereSeparator: \.isWhitespace).map(String.init))
        let soApp = log.split(separator: "\n").filter { l in
            let c = l.split(separator: " ", omittingEmptySubsequences: true)
            return c.count > 3 && (pids.contains(String(c[2])) || l.contains("ReactNativeJS"))
        }.joined(separator: "\n")
        let i = await info.out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let v = await versao.out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let versionName = v.first { $0.hasPrefix("versionName=") }?.replacingOccurrences(of: "versionName=", with: "") ?? "?"
        let versionCode = v.first { $0.hasPrefix("versionCode=") }?.split(separator: " ").first?
            .replacingOccurrences(of: "versionCode=", with: "") ?? "?"
        return CapturaBug(projeto: projeto, dispositivo: d.nome, print: Adb.soPNG(await print), logApp: soApp, logCompleto: log,
                          pacote: pkg, versao: "\(versionName) (\(versionCode))", android: i.first ?? "?",
                          tela: (i.dropFirst().first ?? "").replacingOccurrences(of: "Physical size: ", with: ""),
                          branch: await g(["branch", "--show-current"]), commit: await g(["log", "-1", "--pretty=%h %s (%an, %cr)"]),
                          crashes: crashes.filter { Date().timeIntervalSince($0.0) < 1800 }, video: video)
    }
}

struct FormBug {
    var titulo = ""
    var gravidade = "Média"
    var aconteceu = ""
    var passos = "1. \n2. \n3. "
    var esperado = ""
    var incluirPrint = true
    var incluirVideo = true
}

struct BugMeta: Codable {
    var titulo: String
    var gravidade: String
    var projeto: String
    var data: Date
    var resolvido: Bool
    var branch: String
    var versao: String
}

struct BugRegistro: Identifiable, Hashable {
    let pasta: URL
    var meta: BugMeta
    var id: URL { pasta }
    var readme: URL { pasta.appendingPathComponent("README.md") }
    static func == (a: BugRegistro, b: BugRegistro) -> Bool { a.pasta == b.pasta && a.meta.resolvido == b.meta.resolvido }
    func hash(into h: inout Hasher) { h.combine(pasta) }
}

enum Bugs {
    static func pasta(_ projeto: String) -> URL {
        let u = URL(fileURLWithPath: "\(Config.home)/Documents/BuildRemoto/Bugs/\(projeto)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static let enc: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
    static let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    static func listar(_ projeto: String) -> [BugRegistro] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: pasta(projeto), includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { d in
            guard let data = try? Data(contentsOf: d.appendingPathComponent("bug.json")),
                  let m = try? dec.decode(BugMeta.self, from: data) else { return nil }
            return BugRegistro(pasta: d, meta: m)
        }.sorted { $0.meta.data > $1.meta.data }
    }

    static func salvarMeta(_ b: BugRegistro) {
        try? enc.encode(b.meta).write(to: b.pasta.appendingPathComponent("bug.json"))
    }

    static func markdown(_ f: FormBug, _ c: CapturaBug, temPrint: Bool, video: String?) -> String {
        let titulo = f.titulo.isEmpty ? "Bug em \(c.projeto)" : f.titulo
        let bloco = { (t: String) in t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "_(não informado)_" : t }
        return """
        # \(titulo)

        **Gravidade:** \(f.gravidade) · **App:** \(c.projeto) · **Data:** \(c.quando.formatted(date: .abbreviated, time: .shortened))

        ## O que aconteceu
        \(bloco(f.aconteceu))

        ## Passos para reproduzir
        \(bloco(f.passos))

        ## Esperado
        \(bloco(f.esperado))

        ## Contexto
        | | |
        |---|---|
        | App | `\(c.pacote)` — versão \(c.versao) |
        | Aparelho | \(c.dispositivo) · Android \(c.android) · \(c.tela) |
        | Branch | `\(c.branch)` |
        | Commit | \(c.commit) |
        \(c.crashes.isEmpty ? "" : "\n## Erros detectados nos últimos 30 min\n" + c.crashes.map { "- \($0.0.formatted(date: .omitted, time: .shortened)) — \($0.1): `\($0.2.prefix(160))`" }.joined(separator: "\n") + "\n")
        \(temPrint ? "## Print\n![print](print.png)\n" : "")
        ## Anexos
        \(temPrint ? "- `print.png` — tela no momento do relatório\n" : "")- `logcat-app.txt` — logs do app · `logcat-completo.txt` — logs do aparelho\(video.map { "\n- `\($0)` — gravação da tela" } ?? "")
        """
    }

    static func salvar(_ f: FormBug, _ c: CapturaBug) -> BugRegistro {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH.mm"
        let nome = (f.titulo.isEmpty ? "bug" : f.titulo).replacingOccurrences(of: #"[/:\\]"#, with: "-", options: .regularExpression).prefix(60)
        let dir = pasta(c.projeto).appendingPathComponent("\(fmt.string(from: c.quando)) - \(nome)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temPrint = f.incluirPrint && c.print != nil
        if temPrint { try? c.print?.write(to: dir.appendingPathComponent("print.png")) }
        try? c.logApp.write(to: dir.appendingPathComponent("logcat-app.txt"), atomically: true, encoding: .utf8)
        try? c.logCompleto.write(to: dir.appendingPathComponent("logcat-completo.txt"), atomically: true, encoding: .utf8)
        var nomeVideo: String?
        if f.incluirVideo, let v = c.video {
            try? FileManager.default.copyItem(at: v, to: dir.appendingPathComponent(v.lastPathComponent))
            nomeVideo = v.lastPathComponent
        }
        let md = markdown(f, c, temPrint: temPrint, video: nomeVideo)
        try? md.write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let b = BugRegistro(pasta: dir, meta: BugMeta(titulo: f.titulo.isEmpty ? "Bug em \(c.projeto)" : f.titulo,
                                                     gravidade: f.gravidade, projeto: c.projeto, data: c.quando,
                                                     resolvido: false, branch: c.branch, versao: c.versao))
        salvarMeta(b)
        return b
    }

    /// README sem a linha da imagem — para colar em chat/issue
    static func textoParaCopiar(_ b: BugRegistro) -> String {
        ((try? String(contentsOf: b.readme, encoding: .utf8)) ?? "")
            .replacingOccurrences(of: "## Print\n![print](print.png)\n", with: "")
    }
}

// MARK: - Formulário (abre ao clicar no botão de bug)

struct FormularioBug: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let captura: CapturaBug
    @State private var form = FormBug()
    @FocusState private var focoTitulo: Bool

    private let gravidades: [(String, Color)] = [("Baixa", .green), ("Média", .yellow), ("Alta", .orange), ("Crítica", .red)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "ladybug.fill").font(.title2).foregroundStyle(.red)
                VStack(alignment: .leading) {
                    Text("Novo relatório de bug").font(.title3.bold())
                    Text("\(captura.projeto) · capturado \(captura.quando.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            Divider()
            HStack(alignment: .top, spacing: 18) {
                // Formulário
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Campo("Título") {
                            TextField("ex.: App fecha ao finalizar abastecimento", text: $form.titulo)
                                .textFieldStyle(.roundedBorder).font(.system(size: 14))
                                .focused($focoTitulo)
                        }
                        Campo("Gravidade") {
                            HStack(spacing: 6) {
                                ForEach(gravidades, id: \.0) { g in
                                    Button { form.gravidade = g.0 } label: {
                                        Text(g.0).font(.system(size: 12, weight: .medium))
                                            .padding(.horizontal, 12).padding(.vertical, 5)
                                            .background(Capsule().fill(form.gravidade == g.0 ? g.1.opacity(0.3) : Color.secondary.opacity(0.1)))
                                            .overlay(Capsule().strokeBorder(form.gravidade == g.0 ? g.1 : .clear))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        Campo("O que aconteceu") { Editor(texto: $form.aconteceu, altura: 80) }
                        Campo("Passos para reproduzir") { Editor(texto: $form.passos, altura: 90) }
                        Campo("Resultado esperado") { Editor(texto: $form.esperado, altura: 55) }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minWidth: 420)

                // Print + contexto
                VStack(alignment: .leading, spacing: 10) {
                    if let p = captura.print, let img = NSImage(data: p) {
                        Image(nsImage: img).resizable().scaledToFit()
                            .frame(maxHeight: 300)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
                            .opacity(form.incluirPrint ? 1 : 0.3)
                        Toggle("Incluir print", isOn: $form.incluirPrint)
                    } else {
                        Label("Sem print (celular não respondeu)", systemImage: "photo.badge.exclamationmark")
                            .foregroundStyle(.secondary)
                    }
                    if let v = captura.video {
                        Toggle("Incluir gravação (\(v.lastPathComponent))", isOn: $form.incluirVideo)
                    }
                    Divider()
                    Group {
                        Info("App", "\(captura.pacote) \(captura.versao)")
                        Info("Aparelho", "\(captura.dispositivo) · Android \(captura.android)")
                        Info("Branch", captura.branch)
                        Info("Commit", captura.commit)
                        Info("Logs do app", "\(captura.logApp.split(separator: "\n").count) linhas")
                        if !captura.crashes.isEmpty {
                            Info("Erros recentes", "\(captura.crashes.count) (incluídos)")
                        }
                    }
                    .font(.system(size: 11.5))
                }
                .frame(width: 290)
            }
            .padding(16)
            Divider()
            HStack {
                Text("O texto é copiado ao salvar — é só colar no chat ou na tarefa.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Salvar relatório") {
                    let b = Bugs.salvar(form, captura)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Bugs.textoParaCopiar(b), forType: .string)
                    app.bugSalvo(b)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(14)
        }
        .frame(width: 820, height: 620)
        .onAppear { focoTitulo = true }
    }
}

struct Campo<C: View>: View {
    let titulo: String
    @ViewBuilder let conteudo: C
    init(_ titulo: String, @ViewBuilder conteudo: () -> C) { self.titulo = titulo; self.conteudo = conteudo() }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(titulo).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            conteudo
        }
    }
}

struct Editor: View {
    @Binding var texto: String
    let altura: CGFloat
    var body: some View {
        TextEditor(text: $texto)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: altura)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
    }
}

// MARK: - Aba Bugs

struct BugsView: View {
    @EnvironmentObject var app: AppState
    let projeto: String
    @State private var lista: [BugRegistro] = []
    @State private var filtro = "abertos"
    @State private var excluir: BugRegistro?
    @State private var aviso = ""

    var body: some View {
        let itens = lista.filter { filtro == "todos" || ($0.meta.resolvido == (filtro == "resolvidos")) }
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Picker("", selection: $filtro) {
                        Text("Abertos").tag("abertos"); Text("Resolvidos").tag("resolvidos"); Text("Todos").tag("todos")
                    }
                    .pickerStyle(.segmented).frame(width: 260)
                    Spacer()
                    Button { app.gerarRelatorio(projeto) } label: { Label("Novo", systemImage: "plus") }
                        .disabled(app.alvo == nil)
                }
                .controlSize(.small).padding(8)
                Divider()
                if itens.isEmpty {
                    ContentUnavailableView(filtro == "abertos" ? "Nenhum bug aberto" : "Nada aqui", systemImage: "ladybug",
                                           description: Text("Use o botão de joaninha (⌥⌘B) para registrar um bug com print, logs e contexto."))
                } else {
                    List(itens, selection: Binding(get: { app.bugSelecionado[projeto] }, set: { app.bugSelecionado[projeto] = $0 })) { b in
                        HStack(spacing: 10) {
                            Circle().fill(cor(b.meta.gravidade)).frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(b.meta.titulo).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                                    .strikethrough(b.meta.resolvido)
                                Text("\(b.meta.gravidade) · \(b.meta.branch) · v\(b.meta.versao)")
                                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(b.meta.data.formatted(.relative(presentation: .named))).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                        .tag(b.pasta)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 300, idealWidth: 360, maxHeight: .infinity, alignment: .top)

            VStack(spacing: 0) {
                if let sel = app.bugSelecionado[projeto], let b = lista.first(where: { $0.pasta == sel }) {
                    HStack(spacing: 8) {
                        Button {
                            var n = b; n.meta.resolvido.toggle(); Bugs.salvarMeta(n); carregar()
                        } label: {
                            Label(b.meta.resolvido ? "Reabrir" : "Marcar resolvido",
                                  systemImage: b.meta.resolvido ? "arrow.uturn.backward" : "checkmark.circle")
                        }
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Bugs.textoParaCopiar(b), forType: .string)
                            aviso = "Texto copiado"
                        } label: { Label("Copiar texto", systemImage: "doc.on.doc") }
                        Button {
                            let p = b.pasta.appendingPathComponent("print.png")
                            if let png = try? Data(contentsOf: p) { copiarImagem(png, arquivo: p); aviso = "Print copiado" }
                        } label: { Label("Copiar print", systemImage: "photo") }
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.writeObjects([b.pasta as NSURL])
                            aviso = "Pasta copiada"
                        } label: { Image(systemName: "paperclip") }.help("Copiar a pasta (cole no e-mail/Slack/WhatsApp)")
                        Spacer()
                        if !aviso.isEmpty {
                            Text(aviso).font(.caption).foregroundStyle(.green)
                                .task(id: aviso) { try? await Task.sleep(for: .seconds(2)); aviso = "" }
                        }
                        Button { NSWorkspace.shared.open(b.readme) } label: { Image(systemName: "pencil") }.help("Editar o README no editor")
                        Button { NSWorkspace.shared.open(b.pasta) } label: { Image(systemName: "folder") }.help("Abrir pasta")
                        Button(role: .destructive) { excluir = b } label: { Image(systemName: "trash") }
                    }
                    .controlSize(.small)
                    .padding(8)
                    Divider()
                    BugWeb(bug: b)
                } else {
                    ContentUnavailableView("Escolha um relatório", systemImage: "ladybug")
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { carregar() }
        .onChange(of: app.versaoBugs) { _, _ in carregar() }
        .confirmationDialog("Excluir este relatório?", isPresented: Binding(get: { excluir != nil }, set: { if !$0 { excluir = nil } })) {
            Button("Mover para o Lixo", role: .destructive) {
                if let b = excluir { try? FileManager.default.trashItem(at: b.pasta, resultingItemURL: nil); carregar() }
            }
        }
    }

    private func carregar() {
        lista = Bugs.listar(projeto)
        if app.bugSelecionado[projeto] == nil { app.bugSelecionado[projeto] = lista.first { !$0.meta.resolvido }?.pasta }
    }

    private func cor(_ g: String) -> Color {
        ["Baixa": .green, "Média": .yellow, "Alta": .orange, "Crítica": .red][g] ?? .gray
    }
}

/// Mostra o README do relatório formatado, com o print embutido
struct BugWeb: NSViewRepresentable {
    let bug: BugRegistro

    final class Coord { var chave = "" }
    func makeCoordinator() -> Coord { Coord() }

    func makeNSView(context: Context) -> WKWebView {
        let w = WKWebView()
        w.setValue(false, forKey: "drawsBackground")
        return w
    }

    func updateNSView(_ w: WKWebView, context: Context) {
        let data = (try? bug.readme.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
        let chave = bug.pasta.path + "\(data?.timeIntervalSince1970 ?? 0)"
        guard context.coordinator.chave != chave else { return }
        context.coordinator.chave = chave
        let md = (try? String(contentsOf: bug.readme, encoding: .utf8)) ?? ""
        var html = Markdown.pagina(md, arquivo: bug.readme, busca: "")
        if let png = try? Data(contentsOf: bug.pasta.appendingPathComponent("print.png")) {
            let estilo = "style=\"max-height:560px;border:1px solid var(--borda);border-radius:14px\""
            html = html.replacingOccurrences(of: "src=\"print.png\"", with: "\(estilo) src=\"data:image/png;base64,\(png.base64EncodedString())\"")
        }
        // Mensagens de checkbox/link não são necessárias aqui
        html = html.replacingOccurrences(of: "window.webkit.messageHandlers", with: "(window.webkit||{messageHandlers:{}}).messageHandlers")
        w.loadHTMLString(html, baseURL: bug.pasta)
    }
}
