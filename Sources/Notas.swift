import SwiftUI
import Carbon.HIToolbox
import UniformTypeIdentifiers

// MARK: - Notas: páginas (estilo Notion) e quadro

/// O que está aberto agora e pode receber um print
struct AlvoPrint {
    enum Tipo { case nota, entrega }
    let tipo: Tipo
    let projeto: String
    let id: UUID
    let titulo: String
}

@MainActor
enum PrintNaNota {
    /// Pergunta se o print vai para a nota/entrega aberta; devolve uma mensagem se colocou
    static func oferecer(_ app: AppState, png: Data) -> String? {
        guard let alvo = app.alvoPrint else { return nil }
        let nome = alvo.titulo.isEmpty ? "Sem título" : alvo.titulo
        let a = NSAlert()
        a.messageText = alvo.tipo == .nota ? "Colocar o print na nota “\(nome)”?" : "Colocar o print na entrega “\(nome)”?"
        a.informativeText = alvo.tipo == .nota ? "Ele entra no fim da nota. O print também continua salvo na Mesa." : "Ele entra nos prints da entrega. O print também continua salvo na Mesa."
        a.addButton(withTitle: alvo.tipo == .nota ? "Colocar na nota" : "Colocar na entrega")
        a.addButton(withTitle: "Não")
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        switch alvo.tipo {
        case .nota:
            let caminho = ImagensNotas.salvar(png, extensao: "png")
            guard let b = NotasStore.dono(alvo.id, app: alvo.projeto).binding(alvo.id) else { return nil }
            let atual = b.wrappedValue.detalhes
            b.wrappedValue.detalhes = atual + (atual.isEmpty || atual.hasSuffix("\n") ? "" : "\n") + "![](\(caminho))\n"
            return "✓ Print colocado na nota “\(nome)”"
        case .entrega:
            guard let b = EntregasStore.de(alvo.projeto).binding(alvo.id) else { return nil }
            b.wrappedValue.prints.append(PrintEntrega(arquivo: EntregasStore.guardar(png)))
            return "✓ Print colocado na entrega “\(nome)”"
        }
    }
}

struct NotasView: View {
    @ObservedObject var store: NotasStore
    @AppStorage("notas.modo") private var modo = 0          // 0 páginas · 1 quadro
    @State private var selecionada: UUID?
    @State private var busca = ""
    @State private var tipo: Nota.Tipo?
    @State private var nova = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $modo) {
                    Label("Páginas", systemImage: "doc.text").tag(0)
                    Label("Quadro", systemImage: "rectangle.split.3x1").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                TextField("Anotar rápido e Enter (\"bug: …\", \"ideia: …\") — ⌥⌘N de qualquer lugar", text: $nova)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        store.adicionar(nova); nova = ""
                        if modo == 0 { selecionada = store.notas.first?.id }
                    }
                Picker("", selection: $tipo) {
                    Text("Todos").tag(Nota.Tipo?.none)
                    ForEach(Nota.Tipo.allCases, id: \.self) { t in Label(t.rawValue, systemImage: t.icone).tag(Nota.Tipo?.some(t)) }
                }
                .frame(width: 120)
                TextField("Buscar", text: $busca).textFieldStyle(.roundedBorder).frame(width: 150)
                Button { selecionada = store.novaPagina(); modo = 0 } label: { Label("Nova página", systemImage: "square.and.pencil") }
                Menu {
                    Button("Importar .md (exportação do Notion)…") { importar() }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            .controlSize(.small)
            .padding(10)
            .background(.quaternary.opacity(0.3))
            Divider()
            if modo == 0 {
                HSplitView {
                    ListaPaginas(store: store, selecionada: $selecionada, notas: filtradas, dono: dono)
                        .frame(minWidth: 220, idealWidth: 270, maxWidth: 380, maxHeight: .infinity)
                    Group {
                        if let id = selecionada, dono(id).binding(id) != nil {
                            PaginaNota(store: dono(id), projeto: store.projeto, id: id).id(id)
                        } else {
                            ContentUnavailableView("Escolha uma página", systemImage: "doc.text",
                                                   description: Text("Ou crie uma nova. O texto aceita Markdown e cola/copia do Notion já formatado."))
                        }
                    }
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                QuadroNotas(dono: dono, notas: filtradas) { id in selecionada = id; modo = 0 }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { abrirPedida() }
        .onChange(of: store.abrirID) { abrirPedida() }
    }

    @ObservedObject private var geral = NotasStore.geral

    private var todas: [Nota] { store.notas + NotasStore.compartilhadas(com: store.projeto) }
    private func dono(_ id: UUID) -> NotasStore { NotasStore.dono(id, app: store.projeto) }

    private var filtradas: [Nota] {
        todas.filter { n in
            (tipo == nil || n.tipo == tipo)
                && (busca.isEmpty || n.titulo.localizedCaseInsensitiveContains(busca) || n.detalhes.localizedCaseInsensitiveContains(busca))
        }
    }

    private func abrirPedida() {
        if let id = store.abrirID { selecionada = id; modo = 0; store.abrirID = nil }
    }

    private func importar() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        p.message = "Escolha arquivos .md (no Notion: ⋯ → Exportar → Markdown)"
        guard p.runModal() == .OK else { return }
        _ = store.importar(p.urls)
        selecionada = store.notas.first?.id
    }
}

// MARK: lista de páginas

struct ListaPaginas: View {
    @ObservedObject var store: NotasStore
    @Binding var selecionada: UUID?
    let notas: [Nota]
    let dono: (UUID) -> NotasStore

    private var ordenadas: [Nota] {
        notas.sorted { a, b in
            if (a.fixada ?? false) != (b.fixada ?? false) { return a.fixada ?? false }
            return a.atualizada > b.atualizada
        }
    }

    @AppStorage("notas.verFeitas") private var verFeitas = false

    var body: some View {
        let pendentes = ordenadas.filter { $0.status != .feito }
        let feitas = notas.filter { $0.status == .feito }.sorted { $0.atualizada > $1.atualizada }
        List(selection: $selecionada) {
            ForEach(pendentes) { n in linha(n) }
            if !feitas.isEmpty {
                Section(isExpanded: $verFeitas) {
                    ForEach(feitas) { n in linha(n) }
                } header: {
                    Text("Feitas (\(feitas.count))")
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder private func linha(_ n: Nota) -> some View {
                HStack(alignment: .top, spacing: 8) {
                    Text(n.emoji ?? "").frame(width: n.emoji == nil ? 0 : 18)
                    if n.emoji == nil { Image(systemName: n.tipo.icone).foregroundStyle(n.tipo.cor).frame(width: 16) }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(n.titulo.isEmpty ? "Sem título" : n.titulo).font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(n.titulo.isEmpty || n.status == .feito ? .secondary : .primary)
                                .strikethrough(n.status == .feito).lineLimit(1)
                            if n.fixada == true { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.orange) }
                            SeloApps(nota: n, compartilhada: dono(n.id).ehGeral)
                        }
                        if !n.previa.isEmpty { Text(n.previa).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1) }
                        HStack(spacing: 6) {
                            Circle().fill(cor(n.status)).frame(width: 6, height: 6)
                            Text(n.status.rawValue).font(.system(size: 9.5)).foregroundStyle(.secondary)
                            let (f, t) = n.tarefas
                            if t > 0 { Text("☑ \(f)/\(t)").font(.system(size: 9.5)).foregroundStyle(.secondary) }
                            Spacer()
                            Text(n.atualizada.formatted(.relative(presentation: .named))).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.vertical, 2)
                .tag(n.id)
                .contextMenu { MenuNota(store: dono(n.id), nota: n) }
    }
}

/// "Todos os apps" ou "3 apps" nas notas compartilhadas
struct SeloApps: View {
    let nota: Nota
    let compartilhada: Bool
    var body: some View {
        if compartilhada {
            Label(nota.apps.map { "\($0.count) apps" } ?? "Todos os apps", systemImage: "square.stack.3d.up")
                .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.purple)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Color.purple.opacity(0.12)))
                .help(nota.apps?.joined(separator: ", ") ?? "Vale para todos os apps")
        }
    }
}

func cor(_ s: Nota.Status) -> Color { s == .afazer ? .gray : s == .fazendo ? .blue : .green }

struct MenuNota: View {
    @ObservedObject var store: NotasStore
    let nota: Nota
    var body: some View {
        Button(nota.fixada == true ? "Desafixar" : "Fixar no topo") { var n = nota; n.fixada = !(nota.fixada ?? false); store.atualizar(n) }
        Menu("Mover para") {
            ForEach(Nota.Status.allCases.filter { $0 != nota.status }, id: \.self) { s in Button(s.rawValue) { store.mover(nota.id, para: s) } }
        }
        Button("Copiar para o Notion (Markdown)") { copiar(nota.markdown) }
        Button("Duplicar") { var n = nota; n.id = UUID(); n.titulo += " (cópia)"; n.criada = Date(); store.inserir(n) }
        Divider()
        Button("Excluir", role: .destructive) { store.remover(nota) }
    }
}

// MARK: página

struct PaginaNota: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var store: NotasStore
    var projeto: String? = nil
    let id: UUID
    @StateObject private var controle = ControleEditor()
    @State private var confirmarExcluir = false
    @State private var gerandoPDF = false
    private static let emojis = ["📝", "🐞", "💡", "❓", "✅", "🚀", "📌", "🔥", "⚠️", "📱", "🧪", "📦", "🔧", "📊", "🗓️", "💬"]

    var body: some View {
        if let b = store.binding(id) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    BarraFormatacao(controle: controle)
                    Spacer()
                    Button { copiar(b.wrappedValue.markdown) } label: { Label("Copiar p/ Notion", systemImage: "doc.on.doc") }
                        .help("Copia em Markdown — no Notion, cole numa página e os blocos são criados formatados")
                    Button { exportarPDF(b.wrappedValue) } label: { Label(gerandoPDF ? "Gerando…" : "PDF", systemImage: "doc.richtext") }
                        .disabled(gerandoPDF)
                        .help("Exporta a nota em PDF, com as imagens — bom para compartilhar rápido")
                    Menu {
                        Button("Exportar .md…") { exportar(b.wrappedValue) }
                        Button(b.wrappedValue.fixada == true ? "Desafixar" : "Fixar no topo") { b.wrappedValue.fixada = !(b.wrappedValue.fixada ?? false) }
                        Divider()
                        Button("Excluir página…", role: .destructive) { confirmarExcluir = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
                .controlSize(.small)
                .padding(.horizontal, 14).padding(.vertical, 6)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 8) {
                        Menu {
                            ForEach(Self.emojis, id: \.self) { e in Button(e) { b.wrappedValue.emoji = e } }
                            Divider()
                            Button("Sem ícone") { b.wrappedValue.emoji = nil }
                        } label: { Text(b.wrappedValue.emoji ?? "＋").font(.system(size: b.wrappedValue.emoji == nil ? 16 : 26)) }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .help("Ícone da página")
                        TextField("Sem título", text: b.titulo, axis: .vertical)
                            .textFieldStyle(.plain).font(.system(size: 26, weight: .bold))
                    }
                    propriedades(b)
                }
                .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 6)
                Divider().padding(.horizontal, 24)
                EditorMarkdown(texto: b.detalhes, controle: controle)
                    .padding(.horizontal, 18)
            }
            .onAppear { app.alvoPrint = AlvoPrint(tipo: .nota, projeto: projeto ?? store.projeto, id: id, titulo: b.wrappedValue.titulo) }
            .onChange(of: b.wrappedValue.titulo) { app.alvoPrint = AlvoPrint(tipo: .nota, projeto: projeto ?? store.projeto, id: id, titulo: b.wrappedValue.titulo) }
            .onDisappear { if app.alvoPrint?.id == id { app.alvoPrint = nil } }
            .confirmationDialog("Excluir \"\(b.wrappedValue.titulo)\"?", isPresented: $confirmarExcluir) {
                Button("Excluir", role: .destructive) { store.remover(b.wrappedValue) }
            }
        }
    }

    private func propriedades(_ b: Binding<Nota>) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            GridRow {
                rotulo("Status", "circle.dotted")
                Picker("", selection: b.status) { ForEach(Nota.Status.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().fixedSize()
                rotulo("Tipo", "tag")
                Picker("", selection: b.tipo) { ForEach(Nota.Tipo.allCases, id: \.self) { Label($0.rawValue, systemImage: $0.icone).tag($0) } }
                    .labelsHidden().fixedSize()
                rotulo("Prioridade", "flag")
                Picker("", selection: b.prioridade) { ForEach(Nota.Prioridade.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().fixedSize()
            }
            GridRow {
                rotulo("Apps", "square.stack.3d.up")
                MenuApps(nota: b.wrappedValue, projeto: projeto ?? store.projeto, compartilhada: store.ehGeral)
                    .gridCellColumns(5)
            }
            GridRow {
                rotulo("Branch", "arrow.triangle.branch")
                TextField("—", text: b.branch).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .gridCellColumns(3)
                rotulo("Editada", "clock")
                Text(b.wrappedValue.atualizada.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
    }

    private func rotulo(_ t: String, _ i: String) -> some View {
        Label(t, systemImage: i).font(.system(size: 11.5)).foregroundStyle(.secondary)
    }

    private func exportarPDF(_ n: Nota) {
        let p = NSSavePanel()
        p.nameFieldStringValue = (n.titulo.isEmpty ? "Nota" : n.titulo).replacingOccurrences(of: "/", with: "-") + ".pdf"
        p.allowedContentTypes = [.pdf]
        guard p.runModal() == .OK, let u = p.url else { return }
        gerandoPDF = true
        GeradorPDF.gerar(html: Self.html(n, projeto: projeto ?? store.projeto, compartilhada: store.ehGeral), para: u) { ok in
            gerandoPDF = false
            if ok { NSWorkspace.shared.activateFileViewerSelecting([u]) }
            else {
                let a = NSAlert(); a.messageText = "Não consegui gerar o PDF"; a.runModal()
            }
        }
    }

    static func html(_ n: Nota, projeto: String, compartilhada: Bool) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        let df = DateFormatter(); df.dateFormat = "dd/MM/yyyy HH:mm"
        let apps = compartilhada ? (n.apps?.joined(separator: ", ") ?? "Todos os apps") : projeto
        var props = [("Status", n.status.rawValue), ("Tipo", n.tipo.rawValue), ("Prioridade", n.prioridade.rawValue), ("Apps", apps)]
        if !n.branch.isEmpty { props.append(("Branch", n.branch)) }
        props.append(("Editada", df.string(from: n.atualizada)))
        return """
        <!doctype html><html><head><meta charset="utf-8"><base href="\(ImagensNotas.raiz.absoluteString)/"><style>
        body { font: 13px -apple-system, Helvetica, sans-serif; color: #1d2330; margin: 0; padding: 0 4px; }
        h1.titulo { font-size: 26px; margin: 0 0 10px; }
        .props { display: flex; flex-wrap: wrap; gap: 6px 18px; font-size: 11.5px; color: #6a7280; padding-bottom: 12px; border-bottom: 1px solid #e3e1da; margin-bottom: 16px; }
        .props b { color: #1d2330; font-weight: 600; }
        h1 { font-size: 22px; } h2 { font-size: 18px; } h3 { font-size: 15px; } h1, h2, h3 { page-break-after: avoid; }
        p, li { line-height: 1.55; }
        code { font: 11.5px Menlo, monospace; background: #f1eee7; padding: 1px 4px; border-radius: 4px; color: #b42359; }
        pre { background: #f1eee7; padding: 12px; border-radius: 8px; white-space: pre-wrap; } pre code { background: none; padding: 0; color: #1d2330; }
        blockquote { margin: 8px 0; padding-left: 12px; border-left: 3px solid #c9c4b8; color: #555d6c; }
        img { max-width: 70%; max-height: 900px; border-radius: 8px; border: 1px solid #ddd; display: block; margin: 10px 0; }
        p:has(img + img) { display: flex; gap: 10px; align-items: flex-start; }
        p:has(img + img) img { flex: 1; min-width: 0; max-width: none; height: auto; max-height: 700px; object-fit: contain; margin: 4px 0; }
        ul { padding-left: 22px; } li.task { list-style: none; margin-left: -18px; } li.task input { margin-right: 6px; }
        a { color: #2563C9; } hr { border: none; border-top: 1px solid #e3e1da; margin: 16px 0; }
        table { border-collapse: collapse; } th, td { border: 1px solid #e3e1da; padding: 4px 8px; }
        </style></head><body>
        <h1 class="titulo">\(n.emoji.map { esc($0) + " " } ?? "")\(esc(n.titulo.isEmpty ? "Sem título" : n.titulo))</h1>
        <div class="props">\(props.map { "<span>\($0.0): <b>\(esc($0.1))</b></span>" }.joined())</div>
        \(Markdown.html(n.detalhes, base: ImagensNotas.raiz))
        </body></html>
        """
    }

    private func exportar(_ n: Nota) {
        let p = NSSavePanel()
        p.nameFieldStringValue = (n.titulo.isEmpty ? "nota" : n.titulo).replacingOccurrences(of: "/", with: "-") + ".md"
        p.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard p.runModal() == .OK, let u = p.url else { return }
        try? n.markdown.write(to: u, atomically: true, encoding: .utf8)
        // leva junto as imagens usadas (pasta "imagens" ao lado do .md)
        let usadas = n.detalhes.components(separatedBy: "](imagens/").dropFirst().compactMap { $0.split(separator: ")").first.map(String.init) }
        if !usadas.isEmpty {
            let destino = u.deletingLastPathComponent().appendingPathComponent("imagens")
            try? FileManager.default.createDirectory(at: destino, withIntermediateDirectories: true)
            for nome in usadas {
                try? FileManager.default.copyItem(at: ImagensNotas.pasta.appendingPathComponent(nome), to: destino.appendingPathComponent(nome))
            }
        }
    }
}

/// Escolhe para quais apps a nota vale
struct MenuApps: View {
    let nota: Nota
    let projeto: String
    let compartilhada: Bool

    private var atuais: [String] {
        compartilhada ? (nota.apps ?? Config.projetos) : [projeto]
    }
    private var texto: String {
        if compartilhada && nota.apps == nil { return "Todos os apps" }
        return atuais.joined(separator: ", ")
    }

    var body: some View {
        Menu {
            Button("Só \(projeto)") { NotasStore.definirApps(nota.id, de: projeto, para: [projeto]) }
            Button("Todos os apps") { NotasStore.definirApps(nota.id, de: projeto, para: nil) }
            Divider()
            ForEach(Config.projetos, id: \.self) { p in
                let marcado = atuais.contains(p)
                Button {
                    var novo = atuais
                    if marcado { novo.removeAll { $0 == p } } else { novo.append(p) }
                    guard !novo.isEmpty else { return }
                    NotasStore.definirApps(nota.id, de: projeto, para: Set(novo) == Set(Config.projetos) ? nil : novo.sorted())
                } label: { Label(p, systemImage: marcado ? "checkmark.square.fill" : "square") }
            }
        } label: {
            Text(texto).font(.system(size: 12)).lineLimit(1)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Para quais apps esta nota vale")
    }
}

// MARK: quadro (kanban)

struct QuadroNotas: View {
    let dono: (UUID) -> NotasStore
    let notas: [Nota]
    let abrir: (UUID) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Nota.Status.allCases, id: \.self) { s in
                ColunaNotas(status: s, notas: ordenar(notas.filter { $0.status == s }, s), dono: dono, abrir: abrir)
            }
        }
        .padding(12)
    }

    private func ordenar(_ l: [Nota], _ s: Nota.Status) -> [Nota] {
        l.sorted { a, b in
            if s == .feito { return a.atualizada > b.atualizada }
            let pa = Nota.Prioridade.allCases.firstIndex(of: a.prioridade)!, pb = Nota.Prioridade.allCases.firstIndex(of: b.prioridade)!
            return pa != pb ? pa > pb : a.criada > b.criada
        }
    }
}

struct ColunaNotas: View {
    let status: Nota.Status
    let notas: [Nota]
    let dono: (UUID) -> NotasStore
    let abrir: (UUID) -> Void
    @State private var alvo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(cor(status)).frame(width: 8, height: 8)
                Text(status.rawValue).font(.system(size: 13, weight: .bold))
                Text("\(notas.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(notas) { n in
                        CartaoNota(nota: n, compartilhada: dono(n.id).ehGeral)
                            .onTapGesture { abrir(n.id) }
                            .draggable(n.id.uuidString)
                            .contextMenu { MenuNota(store: dono(n.id), nota: n) }
                    }
                }
                .padding(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(alvo ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.07)))
        .dropDestination(for: String.self) { ids, _ in
            for s in ids { if let id = UUID(uuidString: s) { dono(id).mover(id, para: status) } }
            return true
        } isTargeted: { alvo = $0 }
    }
}

struct CartaoNota: View {
    let nota: Nota
    var compartilhada = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                if let e = nota.emoji { Text(e) } else { Image(systemName: nota.tipo.icone).foregroundStyle(nota.tipo.cor).font(.system(size: 12)) }
                Text(nota.titulo.isEmpty ? "Sem título" : nota.titulo).font(.system(size: 12.5, weight: .medium))
                    .strikethrough(nota.status == .feito).foregroundStyle(nota.status == .feito ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if !nota.previa.isEmpty { Text(nota.previa).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3) }
            HStack(spacing: 6) {
                Text(nota.prioridade.rawValue).font(.system(size: 9.5, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(nota.prioridade.cor.opacity(0.2))).foregroundStyle(nota.prioridade.cor)
                let (f, t) = nota.tarefas
                if t > 0 { Text("☑ \(f)/\(t)").font(.system(size: 9.5)).foregroundStyle(.secondary) }
                if !nota.branch.isEmpty {
                    Label(nota.branch, systemImage: "arrow.triangle.branch").font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                SeloApps(nota: nota, compartilhada: compartilhada)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        .contentShape(Rectangle())
    }
}

// MARK: - Painel lateral (⌘⇧N): notas ao lado da ferramenta aberta

struct PainelNotas: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var store: NotasStore
    @ObservedObject private var geral = NotasStore.geral
    @State private var nova = ""
    @State private var aberta: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Notas · \(store.projeto)", systemImage: "note.text").font(.headline)
                Spacer()
                Button { app.painelNotas = false } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .padding(10)
            HStack {
                Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                TextField("Anotar e Enter", text: $nova).textFieldStyle(.plain)
                    .onSubmit { store.adicionar(nova); nova = "" }
            }
            .padding(.horizontal, 10).padding(.bottom, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let branch = store.branchAtual
                    secao("Desta branch", store.notas.filter { $0.branch == branch && !branch.isEmpty && $0.status != .feito })
                    secao("Fazendo", store.notas.filter { $0.status == .fazendo && $0.branch != branch })
                    secao("A fazer", store.notas.filter { $0.status == .afazer && $0.branch != branch })
                    secao("De todos os apps", NotasStore.compartilhadas(com: store.projeto).filter { $0.status != .feito })
                }
                .padding(10)
            }
            Divider()
            Button { app.abaFerramenta[store.projeto] = .notas } label: { Label("Abrir todas as notas", systemImage: "arrow.up.forward.square") }
                .buttonStyle(.borderless).padding(10)
        }
    }

    @ViewBuilder private func secao(_ t: String, _ l: [Nota]) -> some View {
        if !l.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(t.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                ForEach(l.prefix(15)) { n in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 6) {
                            Button { NotasStore.dono(n.id, app: store.projeto).mover(n.id, para: .feito) } label: { Image(systemName: "circle") }
                                .buttonStyle(.borderless).help("Marcar como feita")
                            Button {
                                aberta = aberta == n.id ? nil : n.id
                                app.alvoPrint = aberta.map { AlvoPrint(tipo: .nota, projeto: store.projeto, id: $0, titulo: n.titulo) }
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((n.emoji.map { $0 + " " } ?? "") + (n.titulo.isEmpty ? "Sem título" : n.titulo))
                                        .font(.system(size: 12)).multilineTextAlignment(.leading)
                                    if !n.previa.isEmpty && aberta != n.id { Text(n.previa).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button { store.abrirID = n.id; app.abaFerramenta[store.projeto] = .notas } label: { Image(systemName: "arrow.up.forward.square") }
                                .buttonStyle(.borderless).help("Abrir a página")
                        }
                        if aberta == n.id, let b = NotasStore.dono(n.id, app: store.projeto).binding(n.id) {
                            EditorMarkdown(texto: b.detalhes, tamanhoFonte: 12.5)
                                .frame(height: 180)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        }
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(aberta == n.id ? 0.1 : 0.04)))
                }
            }
        }
    }
}

// MARK: - Nota rápida (⌥⌘N global, de qualquer app)

final class PainelFlutuante: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

@MainActor
enum NotaRapida {
    private static var painel: PainelFlutuante?
    static weak var app: AppState?

    static func mostrar() {
        guard let app else { return }
        if painel == nil {
            let p = PainelFlutuante(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                                    styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .closable],
                                    backing: .buffered, defer: false)
            p.titlebarAppearsTransparent = true
            p.titleVisibility = .hidden
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isMovableByWindowBackground = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isReleasedWhenClosed = false
            painel = p
        }
        guard let p = painel else { return }
        p.contentView = NSHostingView(rootView: NotaRapidaView { p.orderOut(nil) }.environmentObject(app))
        if let tela = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: tela.midX - 280, y: tela.maxY - tela.height * 0.28 - 300))
        }
        p.makeKeyAndOrderFront(nil)
    }

    // atalho global com o Carbon (não precisa de permissão de acessibilidade)
    private static var registrado = false
    static func registrarAtalho() {
        guard !registrado else { return }
        registrado = true
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4252_4E54), id: 1)   // "BRNT"
        RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
        var tipo = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { NotaRapida.mostrar() }
            return noErr
        }, 1, &tipo, nil, nil)
    }
}

struct NotaRapidaView: View {
    @EnvironmentObject var app: AppState
    let fechar: () -> Void
    @State private var titulo = ""
    @State private var corpo = ""
    @State private var projeto = ""
    @State private var tipo: Nota.Tipo = .tarefa
    @State private var prioridade: Nota.Prioridade = .media
    @FocusState private var foco: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "square.and.pencil").foregroundStyle(Color.accentColor)
                Text("Nova nota").font(.headline)
                Spacer()
                Text("Enter salva · Esc fecha").font(.caption).foregroundStyle(.tertiary)
            }
            TextField("O que você quer anotar?", text: $titulo)
                .textFieldStyle(.plain).font(.system(size: 18, weight: .semibold))
                .focused($foco)
                .onSubmit { salvar(abrir: false) }
            EditorMarkdown(texto: $corpo, placeholder: "Detalhes (opcional) — Markdown, \"/\" para blocos", tamanhoFonte: 13)
                .frame(height: 110)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
            HStack {
                Picker("", selection: $projeto) {
                    ForEach(Config.projetos, id: \.self) { Text($0).tag($0) }
                    Divider()
                    Text("Todos os apps").tag(NotasStore.idGeral)
                }.labelsHidden().fixedSize()
                Picker("", selection: $tipo) { ForEach(Nota.Tipo.allCases, id: \.self) { Label($0.rawValue, systemImage: $0.icone).tag($0) } }.labelsHidden().fixedSize()
                Picker("", selection: $prioridade) { ForEach(Nota.Prioridade.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().fixedSize()
                if !projeto.isEmpty && projeto != NotasStore.idGeral {
                    let b = NotasStore.de(projeto).branchAtual
                    if !b.isEmpty { Label(b, systemImage: "arrow.triangle.branch").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                Button("Salvar e abrir") { salvar(abrir: true) }.keyboardShortcut(.return, modifiers: .command)
                Button("Salvar") { salvar(abrir: false) }.buttonStyle(.borderedProminent).disabled(titulo.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 560)
        .background(.regularMaterial)
        .onAppear {
            projeto = app.selecionado ?? Config.projetos.first ?? ""
            DispatchQueue.main.async { foco = true }
        }
    }

    private func salvar(abrir: Bool) {
        let t = titulo.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !projeto.isEmpty else { return }
        var n = Nota(titulo: t)
        n.detalhes = corpo
        n.tipo = tipo
        n.prioridade = prioridade
        let store = NotasStore.de(projeto)
        let id = store.inserir(n)
        fechar()
        if abrir {
            let alvo = projeto == NotasStore.idGeral ? (app.selecionado ?? Config.projetos.first ?? projeto) : projeto
            app.selecionado = alvo
            app.abaFerramenta[alvo] = .notas
            NotasStore.de(alvo).abrirID = id
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Notas na barra de menus

struct NotasMenuBar: View {
    @EnvironmentObject var app: AppState
    @State private var nova = ""

    var body: some View {
        let fazendo = Config.projetos.flatMap { p in NotasStore.de(p).notas.filter { $0.status == .fazendo }.map { (p, $0) } }
        let abertas = Config.projetos.reduce(0) { $0 + NotasStore.de($1).abertas }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Notas", systemImage: "note.text").font(.headline)
                Text("\(abertas) abertas").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Nova… ⌥⌘N") { NotaRapida.mostrar() }.buttonStyle(.borderless).font(.caption)
            }
            HStack {
                Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                TextField("Anotar em \(app.selecionado ?? "…") e Enter", text: $nova).textFieldStyle(.roundedBorder)
                    .onSubmit { if let p = app.selecionado { NotasStore.de(p).adicionar(nova) }; nova = "" }
            }
            ForEach(Array(fazendo.prefix(6)), id: \.1.id) { p, n in
                HStack(spacing: 6) {
                    Button { NotasStore.de(p).mover(n.id, para: .feito) } label: { Image(systemName: "circle") }.buttonStyle(.borderless).help("Concluir")
                    Text(n.titulo).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Text(p).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
