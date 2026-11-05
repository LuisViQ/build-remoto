import SwiftUI
import UniformTypeIdentifiers

// MARK: - Armazenamento simples em JSON (~/Documents/BuildRemoto/<pasta>/<projeto>.json)

enum ArquivoJSON {
    static func url(_ pasta: String, _ projeto: String) -> URL {
        let d = URL(fileURLWithPath: "\(Config.home)/Documents/BuildRemoto/\(pasta)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("\(projeto).json")
    }
    static func ler<T: Decodable>(_ t: T.Type, _ pasta: String, _ projeto: String) -> T? {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url(pasta, projeto))).flatMap { try? dec.decode(T.self, from: $0) }
    }
    static func salvar<T: Encodable>(_ v: T, _ pasta: String, _ projeto: String) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(v).write(to: url(pasta, projeto), options: .atomic)
    }
}

// MARK: - Notas (problemas, tarefas, ideias) por app

struct Nota: Codable, Identifiable, Hashable {
    enum Status: String, Codable, CaseIterable { case afazer = "A fazer", fazendo = "Fazendo", feito = "Feito" }
    enum Tipo: String, Codable, CaseIterable {
        case problema = "Problema", tarefa = "Tarefa", ideia = "Ideia", duvida = "Dúvida"
        var icone: String {
            switch self { case .problema: "exclamationmark.triangle.fill"; case .tarefa: "checkmark.square"; case .ideia: "lightbulb.fill"; case .duvida: "questionmark.circle.fill" }
        }
        var cor: Color {
            switch self { case .problema: .red; case .tarefa: .blue; case .ideia: .yellow; case .duvida: .purple }
        }
    }
    enum Prioridade: String, Codable, CaseIterable {
        case baixa = "Baixa", media = "Média", alta = "Alta"
        var cor: Color { switch self { case .baixa: .green; case .media: .orange; case .alta: .red } }
    }

    var id = UUID()
    var titulo: String
    var detalhes = ""
    var status: Status = .afazer
    var tipo: Tipo = .tarefa
    var prioridade: Prioridade = .media
    var branch = ""
    var criada = Date()
    var atualizada = Date()
    var emoji: String?
    var fixada: Bool?
    /// Só nas notas compartilhadas (arquivo "_todos"): para quais apps vale; nil = todos os apps
    var apps: [String]?

    /// Primeira linha "de verdade" do texto, sem marcação Markdown (prévia nos cartões)
    var previa: String {
        for l in detalhes.split(separator: "\n") {
            var t = l.trimmingCharacters(in: .whitespaces)
            t = t.replacingOccurrences(of: #"^(#{1,6} |[-*+] \[[ xX]\] |[-*+] |\d+[.)] |> )"#, with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: #"[*_`~]"#, with: "", options: .regularExpression)
            if t.hasPrefix("![") { continue }
            if !t.isEmpty && !t.hasPrefix("```") && t.range(of: #"^-{3,}$"#, options: .regularExpression) == nil { return t }
        }
        return ""
    }
    /// Tarefas do texto: (feitas, total)
    var tarefas: (Int, Int) {
        let linhas = detalhes.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let todas = linhas.filter { $0.range(of: #"^[-*+] \[[ xX]\] "#, options: .regularExpression) != nil }
        return (todas.filter { $0.contains("[x]") || $0.contains("[X]") }.count, todas.count)
    }
    /// Em Markdown, como o Notion importa (título + corpo)
    var markdown: String { "# \(emoji.map { $0 + " " } ?? "")\(titulo)\n\n\(detalhes)" }
}

@MainActor
final class NotasStore: ObservableObject {
    let projeto: String
    @Published var notas: [Nota] = [] {
        didSet {
            ArquivoJSON.salvar(notas, "Notas", projeto)
            NotificationCenter.default.post(name: .notasMudaram, object: nil)
        }
    }

    private static var instancias: [String: NotasStore] = [:]
    static func de(_ p: String) -> NotasStore {
        if let s = instancias[p] { return s }
        let s = NotasStore(projeto: p)
        instancias[p] = s
        return s
    }

    init(projeto: String) {
        self.projeto = projeto
        notas = ArquivoJSON.ler([Nota].self, "Notas", projeto) ?? []
    }

    var abertas: Int { notas.filter { $0.status != .feito }.count }

    func adicionar(_ titulo: String, tipo: Nota.Tipo = .tarefa) {
        let t = titulo.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var n = Nota(titulo: t, tipo: tipo)
        // tipo pela primeira palavra: "bug: …", "ideia: …", "?: …"
        let l = t.lowercased()
        if l.hasPrefix("bug") || l.hasPrefix("problema") { n.tipo = .problema }
        else if l.hasPrefix("ideia") { n.tipo = .ideia }
        else if l.hasSuffix("?") { n.tipo = .duvida }
        if let r = (try? String(contentsOfFile: "\(Config.pasta(projeto))/.git/HEAD", encoding: .utf8)) {
            n.branch = r.replacingOccurrences(of: "ref: refs/heads/", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        notas.insert(n, at: 0)
    }

    func atualizar(_ n: Nota) {
        guard let i = notas.firstIndex(where: { $0.id == n.id }) else { return }
        var x = n; x.atualizada = Date()
        notas[i] = x
    }

    func mover(_ id: UUID, para s: Nota.Status) {
        guard let i = notas.firstIndex(where: { $0.id == id }), notas[i].status != s else { return }
        notas[i].status = s
        notas[i].atualizada = Date()
    }

    func remover(_ n: Nota) { notas.removeAll { $0.id == n.id } }

    /// Nota pedida por outra tela (painel lateral, nota rápida) para abrir na aba Notas
    @Published var abrirID: UUID?

    // MARK: notas compartilhadas entre apps

    static let idGeral = "_todos"
    static var geral: NotasStore { de(idGeral) }
    var ehGeral: Bool { projeto == Self.idGeral }

    /// Notas compartilhadas que valem para o app
    static func compartilhadas(com p: String) -> [Nota] {
        geral.notas.filter { $0.apps == nil || $0.apps!.contains(p) }
    }

    /// Onde a nota está guardada (no app ou no arquivo compartilhado)
    static func dono(_ id: UUID, app p: String) -> NotasStore {
        de(p).notas.contains { $0.id == id } ? de(p) : geral
    }

    /// Muda para quais apps a nota vale, movendo-a entre o app e o arquivo compartilhado
    static func definirApps(_ id: UUID, de p: String, para escolhidos: [String]?) {
        let origem = dono(id, app: p)
        guard var n = origem.notas.first(where: { $0.id == id }) else { return }
        if let e = escolhidos, e.count == 1 {
            // só um app: a nota vai para o arquivo dele
            n.apps = nil
            origem.notas.removeAll { $0.id == id }
            let destino = de(e[0])
            destino.notas.removeAll { $0.id == id }
            destino.notas.insert(n, at: 0)
        } else {
            n.apps = escolhidos   // nil = todos
            n.atualizada = Date()
            if origem.ehGeral {
                if let i = origem.notas.firstIndex(where: { $0.id == id }) { origem.notas[i] = n }
            } else {
                origem.notas.removeAll { $0.id == id }
                geral.notas.insert(n, at: 0)
            }
        }
    }

    var branchAtual: String {
        ((try? String(contentsOfFile: "\(Config.pasta(projeto))/.git/HEAD", encoding: .utf8)) ?? "")
            .replacingOccurrences(of: "ref: refs/heads/", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    func inserir(_ n: Nota) -> UUID {
        var x = n
        if x.branch.isEmpty { x.branch = branchAtual }
        notas.insert(x, at: 0)
        return x.id
    }

    @discardableResult
    func novaPagina() -> UUID { inserir(Nota(titulo: "")) }

    func binding(_ id: UUID) -> Binding<Nota>? {
        guard notas.contains(where: { $0.id == id }) else { return nil }
        return Binding(get: { self.notas.first { $0.id == id } ?? Nota(titulo: "") },
                       set: { novo in
                           guard let i = self.notas.firstIndex(where: { $0.id == id }) else { return }
                           var n = novo; n.atualizada = Date()
                           self.notas[i] = n
                       })
    }

    /// Importa arquivos .md (ex.: exportação do Notion): o "# Título" vira o título
    func importar(_ urls: [URL]) -> Int {
        var n = 0
        for u in urls {
            guard let t = try? String(contentsOf: u, encoding: .utf8) else { continue }
            var linhas = t.components(separatedBy: "\n")
            var titulo = u.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: #"\s[0-9a-f]{32}$"#, with: "", options: .regularExpression)
            if let i = linhas.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), linhas[i].hasPrefix("# ") {
                titulo = String(linhas[i].dropFirst(2)); linhas.remove(at: i)
            }
            var nota = Nota(titulo: titulo)
            nota.detalhes = linhas.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            inserir(nota)
            n += 1
        }
        return n
    }
}

// MARK: - Atalhos: links, scripts do package.json e comandos personalizados

struct LinkUtil: Codable, Identifiable, Hashable {
    var id = UUID()
    var nome: String
    var url: String
}

struct ComandoPersonalizado: Codable, Identifiable, Hashable {
    var id = UUID()
    var nome: String
    var comando: String
    var noPC: Bool = true
}

struct Atalhos: Codable {
    var links: [LinkUtil] = []
    var comandos: [ComandoPersonalizado] = []
}

@MainActor
final class AtalhosStore: ObservableObject {
    let projeto: String
    @Published var dados: Atalhos { didSet { ArquivoJSON.salvar(dados, "Atalhos", projeto) } }

    private static var instancias: [String: AtalhosStore] = [:]
    static func de(_ p: String) -> AtalhosStore {
        if let s = instancias[p] { return s }
        let s = AtalhosStore(projeto: p)
        instancias[p] = s
        return s
    }

    init(projeto: String) {
        self.projeto = projeto
        dados = ArquivoJSON.ler(Atalhos.self, "Atalhos", projeto) ?? Atalhos()
    }

    /// Scripts declarados no package.json do projeto
    var scripts: [(String, String)] {
        let url = URL(fileURLWithPath: "\(Config.pasta(projeto))/package.json")
        guard let d = try? Data(contentsOf: url), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let s = j["scripts"] as? [String: String] else { return [] }
        return s.sorted { $0.key < $1.key }
    }
}

struct AtalhosView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var store: AtalhosStore
    @State private var novoLink: LinkUtil?
    @State private var novoComando: ComandoPersonalizado?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Links
                Grupo(titulo: "Links úteis", icone: "link", subtitulo: "Firebase, Play Console, API, Jira, Figma…") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], spacing: 8) {
                        ForEach(store.dados.links) { l in
                            Button { if let u = URL(string: l.url) { NSWorkspace.shared.open(u) } } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: icone(l.url)).foregroundStyle(.blue).frame(width: 18)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(l.nome).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                        Text(URL(string: l.url)?.host ?? l.url).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(9)
                                .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Editar") { novoLink = l }
                                Button("Copiar URL") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(l.url, forType: .string) }
                                Button("Remover", role: .destructive) { store.dados.links.removeAll { $0.id == l.id } }
                            }
                        }
                        Button { novoLink = LinkUtil(nome: "", url: "https://") } label: {
                            Label("Adicionar link", systemImage: "plus").frame(maxWidth: .infinity).padding(9)
                                .background(RoundedRectangle(cornerRadius: 9).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(.secondary))
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Scripts do package.json
                let scripts = store.scripts
                if !scripts.isEmpty {
                    Grupo(titulo: "Scripts do package.json", icone: "shippingbox", subtitulo: app.modoLocal ? "rodam no Mac" : "rodam no PC (yarn <script>)") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8)], spacing: 8) {
                            ForEach(scripts, id: \.0) { nome, cmd in
                                LinhaComando(nome: nome, comando: cmd, onde: app.modoLocal ? "Mac" : "PC") {
                                    app.rodarComando(store.projeto, nome: nome, comando: "yarn \(nome)", noPC: !app.modoLocal)
                                }
                            }
                        }
                    }
                }

                // Comandos personalizados
                Grupo(titulo: "Comandos personalizados", icone: "terminal", subtitulo: "rodam na pasta do projeto; saída no Console") {
                    if store.dados.comandos.isEmpty {
                        Text("Ex.: \"Limpar cache do Metro\" → rm -rf $TMPDIR/metro-* · \"Ver tamanho do APK\" → du -sh android/app/build/outputs/apk/*")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8)], spacing: 8) {
                        ForEach(store.dados.comandos) { c in
                            LinhaComando(nome: c.nome, comando: c.comando, onde: c.noPC && !app.modoLocal ? "PC" : "Mac") {
                                app.rodarComando(store.projeto, nome: c.nome, comando: c.comando, noPC: c.noPC && !app.modoLocal)
                            }
                            .contextMenu {
                                Button("Editar") { novoComando = c }
                                Button("Remover", role: .destructive) { store.dados.comandos.removeAll { $0.id == c.id } }
                            }
                        }
                    }
                    Button { novoComando = ComandoPersonalizado(nome: "", comando: "") } label: { Label("Novo comando", systemImage: "plus") }
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $novoLink) { l in
            EditorSimples(titulo: "Link", campos: [("Nome", l.nome), ("URL", l.url)]) { v in
                var n = l; n.nome = v[0]; n.url = v[1]
                if let i = store.dados.links.firstIndex(where: { $0.id == l.id }) { store.dados.links[i] = n } else { store.dados.links.append(n) }
            }
        }
        .sheet(item: $novoComando) { c in
            EditorComando(comando: c) { n in
                if let i = store.dados.comandos.firstIndex(where: { $0.id == c.id }) { store.dados.comandos[i] = n } else { store.dados.comandos.append(n) }
            }
        }
    }

    private func icone(_ u: String) -> String {
        let l = u.lowercased()
        if l.contains("firebase") { return "flame.fill" }
        if l.contains("play.google") { return "play.rectangle.fill" }
        if l.contains("expo.dev") { return "e.circle.fill" }
        if l.contains("github") || l.contains("gitlab") || l.contains("bitbucket") { return "chevron.left.forwardslash.chevron.right" }
        if l.contains("figma") { return "paintpalette.fill" }
        if l.contains("jira") || l.contains("atlassian") || l.contains("trello") { return "list.bullet.rectangle.fill" }
        if l.contains("api") { return "server.rack" }
        return "globe"
    }
}

struct LinhaComando: View {
    let nome: String
    let comando: String
    let onde: String
    let rodar: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: rodar) {
                Image(systemName: "play.fill").font(.system(size: 11)).foregroundStyle(.white)
                    .frame(width: 26, height: 26).background(Circle().fill(.green.gradient))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(nome).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(onde).font(.system(size: 8.5, weight: .heavy)).padding(.horizontal, 4)
                        .background(Capsule().fill(.quaternary))
                }
                Text(comando).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary))
        .help(comando)
    }
}

struct EditorSimples: View {
    let titulo: String
    @State var campos: [(String, String)]
    let salvar: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss

    init(titulo: String, campos: [(String, String)], salvar: @escaping ([String]) -> Void) {
        self.titulo = titulo; _campos = State(initialValue: campos); self.salvar = salvar
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(titulo).font(.headline)
            ForEach(campos.indices, id: \.self) { i in
                TextField(campos[i].0, text: $campos[i].1).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Salvar") { salvar(campos.map(\.1)); dismiss() }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(campos.contains { $0.1.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .padding(20).frame(width: 440)
    }
}

struct EditorComando: View {
    @State var comando: ComandoPersonalizado
    let salvar: (ComandoPersonalizado) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Comando personalizado").font(.headline)
            TextField("Nome (ex.: Typecheck)", text: $comando.nome).textFieldStyle(.roundedBorder)
            TextField("Comando (ex.: npx tsc --noEmit)", text: $comando.comando).textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
            Picker("Rodar no", selection: $comando.noPC) {
                Text("PC (no modo compartilhado)").tag(true)
                Text("Mac").tag(false)
            }
            .pickerStyle(.radioGroup)
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Salvar") { salvar(comando); dismiss() }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(comando.nome.isEmpty || comando.comando.isEmpty)
            }
        }
        .padding(20).frame(width: 480)
    }
}
