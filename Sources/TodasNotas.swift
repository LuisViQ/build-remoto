import SwiftUI

// MARK: - Todas as notas: tudo o que está pendente, em andamento e pronto, de todos os apps

/// Uma nota com o lugar onde ela está guardada
@MainActor
struct NotaDeApp: Identifiable {
    let nota: Nota
    let store: NotasStore
    var id: UUID { nota.id }
    /// Nome mostrado: o app, ou "Todos os apps"/"N apps" para as compartilhadas
    var origem: String {
        store.ehGeral ? (nota.apps.map { $0.joined(separator: ", ") } ?? "Todos os apps") : store.projeto
    }
}

struct TodasNotasView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var geral = NotasStore.geral
    @State private var stores: [NotasStore] = []
    @State private var selecionada: UUID?
    @State private var busca = ""
    @State private var tipo: Nota.Tipo?
    @State private var filtroApp: String?          // nil = todos
    @AppStorage("todasNotas.agrupar") private var agruparPorApp = false
    @AppStorage("todasNotas.verFeitas") private var verFeitas = true
    @State private var versao = 0                   // força recalcular quando alguma store muda
    @AppStorage("todasNotas.modo") private var modo = 0   // 0 lista · 1 quadro
    @State private var abertaNoQuadro: UUID?
    @AppStorage("todasNotas.recolhidos") private var recolhidosTxt = ""

    var body: some View {
        VStack(spacing: 0) {
            barra
            Divider()
            if modo == 1 { quadro } else {
            HSplitView {
                lista.frame(minWidth: 300, idealWidth: 380, maxWidth: 520, maxHeight: .infinity)
                Group {
                    if let id = selecionada, let item = todas.first(where: { $0.id == id }) {
                        VStack(spacing: 0) {
                            HStack(spacing: 6) {
                                Image(systemName: item.store.ehGeral ? "square.stack.3d.up" : "app.fill")
                                    .foregroundStyle(item.store.ehGeral ? .purple : .accentColor)
                                Text(item.origem).font(.caption.bold())
                                if !item.nota.branch.isEmpty {
                                    Text("· \(item.nota.branch)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if !item.store.ehGeral {
                                    Button("Abrir no app") { abrirNoApp(item) }.controlSize(.small)
                                }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(.quaternary.opacity(0.25))
                            PaginaNota(store: item.store, projeto: item.store.ehGeral ? nil : item.store.projeto, id: id).id(id)
                        }
                    } else {
                        ContentUnavailableView("Escolha uma nota", systemImage: "tray.full",
                                               description: Text("Aqui ficam as notas de todos os apps juntas — pendentes, em andamento e feitas."))
                    }
                }
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .sheet(item: Binding(get: { abertaNoQuadro.map { IDNota(id: $0) } }, set: { abertaNoQuadro = $0?.id })) { x in
            if let item = todas.first(where: { $0.id == x.id }) {
                VStack(spacing: 0) {
                    HStack {
                        Text(item.origem).font(.caption.bold()).foregroundStyle(item.store.ehGeral ? .purple : .accentColor)
                        Spacer()
                        if !item.store.ehGeral { Button("Abrir no app") { abertaNoQuadro = nil; abrirNoApp(item) } }
                        Button("Fechar") { abertaNoQuadro = nil }.keyboardShortcut(.cancelAction)
                    }
                    .controlSize(.small).padding(10)
                    Divider()
                    PaginaNota(store: item.store, projeto: item.store.ehGeral ? nil : item.store.projeto, id: x.id)
                }
                .frame(width: 820, height: 640)
            }
        }
        .onAppear { stores = Config.projetos.map { NotasStore.de($0) } + [NotasStore.geral] }
        .onReceive(NotificationCenter.default.publisher(for: .notasMudaram)) { _ in versao += 1 }
    }

    // MARK: barra de filtros

    private var barra: some View {
        HStack(spacing: 10) {
            Picker("", selection: $modo) {
                Label("Lista", systemImage: "list.bullet").tag(0)
                Label("Quadro", systemImage: "rectangle.split.3x1").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            resumo
            Spacer()
            Picker("", selection: $filtroApp) {
                Text("Todos os apps").tag(String?.none)
                Divider()
                ForEach(Config.projetos, id: \.self) { p in Text(p).tag(String?.some(p)) }
                Text("Compartilhadas").tag(String?.some(NotasStore.idGeral))
            }
            .frame(width: 160)
            Picker("", selection: $tipo) {
                Text("Todos os tipos").tag(Nota.Tipo?.none)
                ForEach(Nota.Tipo.allCases, id: \.self) { t in Label(t.rawValue, systemImage: t.icone).tag(Nota.Tipo?.some(t)) }
            }
            .frame(width: 140)
            if modo == 0 { Toggle("Agrupar por app", isOn: $agruparPorApp).toggleStyle(.checkbox) }
            TextField("Buscar em todas", text: $busca).textFieldStyle(.roundedBorder).frame(width: 170)
        }
        .controlSize(.small)
        .padding(10)
        .background(.quaternary.opacity(0.3))
    }

    private var resumo: some View {
        let f = filtradas
        return HStack(spacing: 12) {
            contador("A fazer", f.filter { $0.nota.status == .afazer }.count, .gray)
            contador("Fazendo", f.filter { $0.nota.status == .fazendo }.count, .blue)
            contador("Feitas", f.filter { $0.nota.status == .feito }.count, .green)
        }
    }

    private func contador(_ t: String, _ n: Int, _ c: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 8, height: 8)
            Text("\(n)").font(.system(size: 13, weight: .bold).monospacedDigit())
            Text(t).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: lista

    private var lista: some View {
        let f = filtradas
        return List(selection: $selecionada) {
            if f.isEmpty {
                Text(busca.isEmpty ? "Nenhuma nota ainda." : "Nada encontrado.").foregroundStyle(.secondary)
            }
            if agruparPorApp {
                ForEach(grupos(f), id: \.0) { nome, itens in
                    Section("\(nome) (\(itens.filter { $0.nota.status != .feito }.count) abertas)") {
                        ForEach(ordenar(itens)) { linha($0, mostrarApp: false) }
                    }
                }
            } else {
                secao("Fazendo", f.filter { $0.nota.status == .fazendo })
                secao("A fazer", f.filter { $0.nota.status == .afazer })
                let feitas = f.filter { $0.nota.status == .feito }
                if !feitas.isEmpty {
                    Section(isExpanded: $verFeitas) {
                        ForEach(feitas.sorted { $0.nota.atualizada > $1.nota.atualizada }) { linha($0, mostrarApp: true) }
                    } header: { Text("Feitas (\(feitas.count))") }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder private func secao(_ t: String, _ itens: [NotaDeApp]) -> some View {
        if !itens.isEmpty {
            Section("\(t) (\(itens.count))") { ForEach(ordenar(itens)) { linha($0, mostrarApp: true) } }
        }
    }

    private func linha(_ i: NotaDeApp, mostrarApp: Bool) -> some View {
        let n = i.nota
        return HStack(alignment: .top, spacing: 8) {
            if let e = n.emoji { Text(e).frame(width: 18) } else { Image(systemName: n.tipo.icone).foregroundStyle(n.tipo.cor).frame(width: 18) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(n.titulo.isEmpty ? "Sem título" : n.titulo).font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(n.status == .feito ? .secondary : .primary)
                        .strikethrough(n.status == .feito).lineLimit(1)
                    if n.fixada == true { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.orange) }
                    if n.prioridade == .alta && n.status != .feito {
                        Image(systemName: "flag.fill").font(.system(size: 8)).foregroundStyle(.red).help("Prioridade alta")
                    }
                }
                if !n.previa.isEmpty { Text(n.previa).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1) }
                HStack(spacing: 6) {
                    if mostrarApp {
                        Text(i.origem).font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(i.store.ehGeral ? .purple : .accentColor)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill((i.store.ehGeral ? Color.purple : .accentColor).opacity(0.12)))
                            .lineLimit(1)
                    }
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
        .contextMenu {
            MenuNota(store: i.store, nota: n)
            if !i.store.ehGeral { Divider(); Button("Abrir no app \(i.store.projeto)") { abrirNoApp(i) } }
        }
    }

    // MARK: quadro — uma faixa por app, com as colunas A fazer / Fazendo / Feito

    private var quadro: some View {
        let g = grupos(filtradas)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if g.isEmpty {
                    Text(busca.isEmpty ? "Nenhuma nota ainda." : "Nada encontrado.").foregroundStyle(.secondary).padding()
                }
                ForEach(g, id: \.0) { nome, itens in faixa(nome, itens) }
            }
            .padding(12)
        }
    }

    private var recolhidos: Set<String> { Set(recolhidosTxt.split(separator: "|").map(String.init)) }

    private func faixa(_ nome: String, _ itens: [NotaDeApp]) -> some View {
        let aberto = !recolhidos.contains(nome)
        let maior = Nota.Status.allCases.map { s in itens.filter { $0.nota.status == s }.count }.max() ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                var r = recolhidos
                if aberto { r.insert(nome) } else { r.remove(nome) }
                recolhidosTxt = r.sorted().joined(separator: "|")
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(aberto ? 90 : 0)).foregroundStyle(.secondary)
                    Image(systemName: nome == "Compartilhadas" ? "square.stack.3d.up" : "app.fill")
                        .foregroundStyle(nome == "Compartilhadas" ? .purple : .accentColor)
                    Text(nome).font(.system(size: 14, weight: .bold))
                    ForEach(Nota.Status.allCases, id: \.self) { s in
                        let n = itens.filter { $0.nota.status == s }.count
                        HStack(spacing: 3) {
                            Circle().fill(cor(s)).frame(width: 6, height: 6)
                            Text("\(n)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if aberto {
                let notas = itens.map(\.nota)
                QuadroNotas(dono: dono, notas: notas) { abertaNoQuadro = $0 }
                    .padding(-12)
                    .frame(height: min(max(CGFloat(maior) * 96 + 60, 170), 520))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary))
    }

    private func dono(_ id: UUID) -> NotasStore {
        stores.first { $0.notas.contains { $0.id == id } } ?? NotasStore.geral
    }

    // MARK: dados

    private var todas: [NotaDeApp] {
        _ = versao
        return stores.flatMap { s in s.notas.map { NotaDeApp(nota: $0, store: s) } }
    }

    private var filtradas: [NotaDeApp] {
        todas.filter { i in
            let n = i.nota
            let okApp: Bool = {
                guard let a = filtroApp else { return true }
                if a == NotasStore.idGeral { return i.store.ehGeral }
                // notas do app + compartilhadas que valem para ele
                return i.store.projeto == a || (i.store.ehGeral && (n.apps == nil || n.apps!.contains(a)))
            }()
            return okApp && (tipo == nil || n.tipo == tipo)
                && (busca.isEmpty || n.titulo.localizedCaseInsensitiveContains(busca)
                    || n.detalhes.localizedCaseInsensitiveContains(busca) || n.branch.localizedCaseInsensitiveContains(busca))
        }
    }

    private func ordenar(_ l: [NotaDeApp]) -> [NotaDeApp] {
        let peso: [Nota.Prioridade: Int] = [.alta: 0, .media: 1, .baixa: 2]
        return l.sorted { a, b in
            if (a.nota.fixada ?? false) != (b.nota.fixada ?? false) { return a.nota.fixada ?? false }
            if a.nota.status != b.nota.status { return a.nota.status == .fazendo }
            if peso[a.nota.prioridade]! != peso[b.nota.prioridade]! { return peso[a.nota.prioridade]! < peso[b.nota.prioridade]! }
            return a.nota.atualizada > b.nota.atualizada
        }
    }

    private func grupos(_ l: [NotaDeApp]) -> [(String, [NotaDeApp])] {
        let por = Dictionary(grouping: l) { $0.store.ehGeral ? "Compartilhadas" : $0.store.projeto }
        return (Config.projetos + ["Compartilhadas"]).compactMap { k in por[k].map { (k, $0) } }
    }

    private func abrirNoApp(_ i: NotaDeApp) {
        app.selecionado = i.store.projeto
        app.abaFerramenta[i.store.projeto] = .notas
        i.store.abrirID = i.id
        NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true }?.makeKeyAndOrderFront(nil)
    }
}

extension Notification.Name {
    static let notasMudaram = Notification.Name("BuildRemoto.notasMudaram")
}

/// Item de menu (precisa do openWindow do ambiente)
struct AbrirTodasNotas: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Todas as notas (todos os apps)") { openWindow(id: "todas-notas") }.keyboardShortcut("a", modifiers: [.command, .option])
    }
}

struct IDNota: Identifiable { let id: UUID }
