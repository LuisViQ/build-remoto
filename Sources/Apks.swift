import SwiftUI

// MARK: - Contexto de cada build de APK (salvo em JSON ao lado do .apk)

struct BuildContexto: Codable {
    var projeto: String
    var tipo: String               // debug | release
    var origem: String             // PC | Mac
    var inicio: Date
    var fim: Date?
    var branch: String
    var commit: String
    var commitMsg: String
    var autor: String
    var alteradosSemCommit: Int
    var versionName: String?
    var versionCode: String?
    var pacote: String?
    var tamanho: Int64?
    var notas: String = ""

    var duracao: String {
        guard let fim else { return "—" }
        let s = Int(fim.timeIntervalSince(inicio))
        return s >= 60 ? "\(s / 60)min \(s % 60)s" : "\(s)s"
    }

    /// Captura o estado do Git no início do build
    static func capturar(_ projeto: String, tipo: String, origem: String) async -> BuildContexto {
        let pasta = "\(Config.pasta(projeto))"
        let g = { (a: [String]) async -> String in
            await Shell.run("git", ["-C", pasta] + a).out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let log = await g(["log", "-1", "--pretty=format:%h\u{1F}%s\u{1F}%an"]).components(separatedBy: "\u{1F}")
        let alterados = await g(["status", "--porcelain"]).split(separator: "\n").count
        return BuildContexto(projeto: projeto, tipo: tipo, origem: origem, inicio: Date(),
                             branch: await g(["branch", "--show-current"]),
                             commit: log.first ?? "", commitMsg: log.count > 1 ? log[1] : "",
                             autor: log.count > 2 ? log[2] : "", alteradosSemCommit: alterados)
    }
}

struct ApkRegistro: Identifiable, Hashable {
    let url: URL
    var ctx: BuildContexto?
    let data: Date
    let tamanho: Int64
    var id: URL { url }
    var jsonURL: URL { url.deletingPathExtension().appendingPathExtension("json") }

    static func == (a: ApkRegistro, b: ApkRegistro) -> Bool { a.url == b.url }
    func hash(into h: inout Hasher) { h.combine(url) }
}

enum ApkArquivo {

    /// Lê pacote/versão de dentro do APK
    static func ler(_ url: URL) async -> (pacote: String?, nome: String?, codigo: String?) {
        guard let aapt = Config.aapt else { return (nil, nil, nil) }
        let r = await Shell.run(aapt, ["dump", "badging", url.path])
        guard let linha = r.out.split(separator: "\n").first(where: { $0.hasPrefix("package:") }) else { return (nil, nil, nil) }
        let campo = { (k: String) -> String? in
            guard let a = linha.range(of: "\(k)='") else { return nil }
            return String(linha[a.upperBound...].prefix { $0 != "'" })
        }
        return (campo("name"), campo("versionName"), campo("versionCode"))
    }

    /// Dá nome único ao APK recém-gerado (para não sobrescrever o anterior) e grava o contexto
    static func registrar(_ arquivo: URL, ctx inicial: BuildContexto) async -> URL {
        var ctx = inicial
        ctx.fim = Date()
        let info = await ler(arquivo)
        ctx.pacote = info.pacote
        ctx.versionName = info.nome
        ctx.versionCode = info.codigo
        ctx.tamanho = (try? arquivo.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd-HHmm"
        let branch = ctx.branch.replacingOccurrences(of: #"[^A-Za-z0-9._-]"#, with: "-", options: .regularExpression)
        let base = "\(ctx.projeto)_v\(info.nome ?? "?")(\(info.codigo ?? "?"))_\(ctx.tipo)_\(branch)_\(fmt.string(from: ctx.fim!))"
        let destino = arquivo.deletingLastPathComponent().appendingPathComponent(base + ".apk")
        try? FileManager.default.removeItem(at: destino)
        try? FileManager.default.moveItem(at: arquivo, to: destino)
        salvar(ctx, para: destino)
        return destino
    }

    static func salvar(_ ctx: BuildContexto, para apk: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(ctx).write(to: apk.deletingPathExtension().appendingPathExtension("json"))
    }

    static func listar(_ projeto: String) -> [ApkRegistro] {
        let dir = URL(fileURLWithPath: "\(Config.apkDir)/\(projeto)")
        let arqs = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return arqs.filter { $0.pathExtension == "apk" }.map { u in
            let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let ctx = (try? Data(contentsOf: u.deletingPathExtension().appendingPathExtension("json")))
                .flatMap { try? dec.decode(BuildContexto.self, from: $0) }
            return ApkRegistro(url: u, ctx: ctx, data: ctx?.fim ?? v?.contentModificationDate ?? .distantPast,
                               tamanho: Int64(v?.fileSize ?? 0))
        }.sorted { $0.data > $1.data }
    }
}

// MARK: - Aba APKs

struct ApksView: View {
    @EnvironmentObject var app: AppState
    let projeto: String
    @State private var selecionado: ApkRegistro?
    @State private var filtroTipo = "todos"
    @State private var notas = ""
    @State private var excluir: ApkRegistro?

    private var lista: [ApkRegistro] {
        (app.registrosApk[projeto] ?? []).filter { filtroTipo == "todos" || $0.ctx?.tipo == filtroTipo }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Picker("", selection: $filtroTipo) {
                        Text("Todos").tag("todos"); Text("Debug").tag("debug"); Text("Release").tag("release")
                    }
                    .pickerStyle(.segmented).frame(width: 220)
                    Spacer()
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: "\(Config.apkDir)/\(projeto)")) } label: {
                        Label("Pasta", systemImage: "folder")
                    }
                }
                .controlSize(.small).padding(8)
                Divider()
                if lista.isEmpty {
                    ContentUnavailableView("Nenhum APK ainda", systemImage: "shippingbox",
                                           description: Text("Use APK Debug ou APK Release — cada build fica guardado aqui com todo o contexto."))
                } else {
                    List(lista, selection: $selecionado) { a in
                        LinhaApk(apk: a).tag(a)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 340, idealWidth: 420, maxHeight: .infinity, alignment: .top)

            Group {
                if let a = selecionado, let atual = lista.first(where: { $0.url == a.url }) {
                    DetalheApk(apk: atual, notas: $notas, excluir: $excluir)
                        .id(atual.url)
                        .onAppear { notas = atual.ctx?.notas ?? "" }
                } else {
                    ContentUnavailableView("Escolha um APK", systemImage: "shippingbox")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { app.recarregarApks(projeto); if selecionado == nil { selecionado = lista.first } }
        .confirmationDialog("Excluir este APK?", isPresented: Binding(get: { excluir != nil }, set: { if !$0 { excluir = nil } })) {
            Button("Mover para o Lixo", role: .destructive) {
                if let a = excluir {
                    try? FileManager.default.trashItem(at: a.url, resultingItemURL: nil)
                    try? FileManager.default.trashItem(at: a.jsonURL, resultingItemURL: nil)
                    selecionado = nil
                    app.recarregarApks(projeto)
                }
            }
        }
    }
}

struct LinhaApk: View {
    let apk: ApkRegistro
    var body: some View {
        let c = apk.ctx
        HStack(spacing: 10) {
            Image(systemName: c?.tipo == "release" ? "shippingbox.fill" : "shippingbox")
                .font(.system(size: 18)).foregroundStyle(c?.tipo == "release" ? .indigo : .blue).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c?.versionName.map { "v\($0)" } ?? apk.url.deletingPathExtension().lastPathComponent)
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let code = c?.versionCode { Text("(\(code))").font(.system(size: 11)).foregroundStyle(.secondary) }
                    if let t = c?.tipo {
                        Text(t.uppercased()).font(.system(size: 9, weight: .heavy))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill((t == "release" ? Color.indigo : .blue).opacity(0.18)))
                    }
                }
                HStack(spacing: 6) {
                    if let b = c?.branch { Label(b, systemImage: "arrow.triangle.branch").lineLimit(1) }
                    if let o = c?.origem { Text("· \(o)") }
                }
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(apk.data.formatted(.relative(presentation: .named))).font(.system(size: 11))
                Text(ByteCountFormatter.string(fromByteCount: apk.tamanho, countStyle: .file))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct DetalheApk: View {
    @EnvironmentObject var app: AppState
    let apk: ApkRegistro
    @Binding var notas: String
    @Binding var excluir: ApkRegistro?

    var body: some View {
        let c = apk.ctx
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    IconeApp(projeto: c?.projeto ?? app.selecionado ?? "", tamanho: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(c?.versionName.map { "Versão \($0)" } ?? "APK").font(.title2.bold())
                        Text(apk.url.lastPathComponent).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
                    }
                }
                HStack {
                    if let d = app.alvo {
                        Button { app.instalarApk(Apk(url: apk.url, data: apk.data, tamanho: apk.tamanho), em: d) } label: {
                            Label("Instalar em \(d.nome)", systemImage: "arrow.down.app")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    ShareLink(item: apk.url) { Label("Compartilhar", systemImage: "square.and.arrow.up") }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([apk.url]) } label: { Image(systemName: "folder") }
                        .help("Mostrar no Finder")
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([apk.url as NSURL])
                    } label: { Image(systemName: "doc.on.doc") }
                        .help("Copiar arquivo (cole no WhatsApp, e-mail, Slack…)")
                    Spacer()
                    Button(role: .destructive) { excluir = apk } label: { Image(systemName: "trash") }
                }

                if let c {
                    Grupo(titulo: "Build", icone: "hammer") {
                        Info("Tipo", c.tipo.capitalized)
                        Info("Gerado no", c.origem == "PC" ? "PC (WSL)" : "Mac")
                        Info("Início", c.inicio.formatted(date: .abbreviated, time: .standard))
                        Info("Duração", c.duracao)
                        Info("Tamanho", ByteCountFormatter.string(fromByteCount: c.tamanho ?? apk.tamanho, countStyle: .file))
                    }
                    Grupo(titulo: "App", icone: "app.badge") {
                        Info("Pacote", c.pacote ?? "—")
                        Info("versionName", c.versionName ?? "—")
                        Info("versionCode", c.versionCode ?? "—")
                    }
                    Grupo(titulo: "Código", icone: "arrow.triangle.branch") {
                        Info("Branch", c.branch)
                        Info("Commit", "\(c.commit) — \(c.commitMsg)")
                        Info("Autor do commit", c.autor)
                        Info("Alterações sem commit", c.alteradosSemCommit == 0 ? "nenhuma ✓" : "\(c.alteradosSemCommit) arquivo(s) ⚠️")
                    }
                    Grupo(titulo: "Anotações", icone: "note.text", subtitulo: "ex.: enviado para o cliente, testado por…") {
                        TextEditor(text: $notas)
                            .font(.system(size: 12.5)).frame(minHeight: 70)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.background.opacity(0.6)))
                            .onChange(of: notas) { _, v in
                                var novo = c; novo.notas = v
                                ApkArquivo.salvar(novo, para: apk.url)
                            }
                    }
                } else {
                    Text("Este APK foi gerado antes do controle de contexto — só há data e tamanho.")
                        .foregroundStyle(.secondary).font(.callout)
                }
            }
            .padding(20)
        }
    }
}

struct Info: View {
    let k: String
    let v: String
    init(_ k: String, _ v: String) { self.k = k; self.v = v }
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(v).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5))
    }
}
