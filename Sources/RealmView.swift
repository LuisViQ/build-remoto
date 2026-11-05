import SwiftUI
import UniformTypeIdentifiers

// MARK: - Aba Realm

struct RealmView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: RealmModel
    var emJanela = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let c = model.carregando, model.copia == nil {
                VStack(spacing: 10) { ProgressView(); Text(c).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.copia == nil && model.backup == nil {
                RealmInicio(model: model)
            } else if let b = model.backup {
                VStack(spacing: 0) {
                    BackupCabecalho(model: model, backup: b, aba: $abaBackup, emJanela: emJanela)
                    Divider()
                    switch abaBackup {
                    case .banco:
                        if model.copia != nil { banco } else {
                            ContentUnavailableView("Este backup não tem banco.realm", systemImage: "cylinder.split.1x2")
                        }
                    case .storage: BackupStorageView(model: model)
                    case .arquivos: BackupArquivosView(backup: b)
                    }
                }
            } else {
                banco
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if emJanela { entrarEmTelaCheia() } }
        .onDrop(of: [.fileURL], isTargeted: nil) { itens in
            _ = itens.first?.loadObject(ofClass: URL.self) { url, _ in
                guard let url, ["realm", "zip"].contains(url.pathExtension.lowercased()) else { return }
                Task { @MainActor in await model.abrirArquivo(url); RealmInicio.lembrar(url) }
            }
            return true
        }
        .alert("Realm", isPresented: Binding(get: { model.erro != nil }, set: { if !$0 { model.erro = nil } })) {
            Button("OK") {}
        } message: { Text(model.erro ?? "") }
    }

    @State private var abaBackup: AbaBackup = .banco

    private func abrirTelaCheia() {
        openWindow(id: "realm", value: model.projeto)
    }

    /// Coloca a janela do Realm em tela cheia logo que ela aparece
    private func entrarEmTelaCheia() {
        let titulo = "Realm — \(model.projeto)"
        Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(100))
                if let w = NSApp.windows.first(where: { $0.title == titulo }) {
                    if !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
                    return
                }
            }
        }
    }

    private var banco: some View {
                VStack(spacing: 0) {
                    RealmBarra(model: model, emJanela: emJanela)
                    Divider()
                    HSplitView {
                        RealmClasses(model: model)
                            .frame(minWidth: 190, idealWidth: 220, maxWidth: 320, maxHeight: .infinity)
                        RealmTabela(model: model)
                            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                        if let d = model.detalhe {
                            RealmEditor(model: model, detalhe: d).id("\(d.cls)#\(d.key)#\(model.alteracoes)")
                                .frame(minWidth: 320, idealWidth: 400, maxWidth: 620, maxHeight: .infinity)
                        }
                    }
                }
    }
}

// MARK: - Tela inicial (escolher o banco)

struct RealmInicio: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: RealmModel
    @State private var pacote: String?
    @State private var arquivos: [String] = []
    @State private var erroCelular: String?
    @State private var buscando = false
    @State private var recentes: [URL] = RealmInicio.lerRecentes()

    static func lerRecentes() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: "realm.recentes") ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    static func lembrar(_ u: URL) {
        var l = UserDefaults.standard.stringArray(forKey: "realm.recentes") ?? []
        l.removeAll { $0 == u.path }
        l.insert(u.path, at: 0)
        UserDefaults.standard.set(Array(l.prefix(12)), forKey: "realm.recentes")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Banco Realm").font(.title2.bold())
                    Text("Navegue, filtre (RQL), edite e exporte as tabelas do Realm. O app trabalha sempre numa cópia — o original só muda quando você mandar.")
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Do app aberto no celular", systemImage: "iphone.gen3").font(.headline)
                        if let d = app.alvo {
                            HStack {
                                Text("\(d.nome) · \(pacote ?? "procurando o pacote…")").foregroundStyle(.secondary)
                                Spacer()
                                Button { Task { await buscar() } } label: { Image(systemName: "arrow.clockwise") }.disabled(buscando)
                            }
                            if buscando { ProgressView().controlSize(.small) }
                            if let erroCelular { Label(erroCelular, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
                            ForEach(arquivos, id: \.self) { a in
                                Button {
                                    if let pacote { Task { await model.abrirCelular(d, pacote: pacote, arquivo: a) } }
                                } label: {
                                    Label("Abrir files/\(a)", systemImage: "cylinder.split.1x2").frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                            }
                            Text("Precisa ser um build de debug. O banco é baixado como um retrato do momento; dá para atualizar a qualquer hora ou deixar atualizando sozinho.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Conecte um celular (no Mac ou no PC) e escolha-o no seletor de dispositivos.").foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("De um backup (.zip do app) ou arquivo .realm", systemImage: "doc.zipper").font(.headline)
                        HStack {
                            Button { escolherArquivo() } label: { Label("Abrir backup .zip ou .realm…", systemImage: "folder") }
                            Text("ou arraste o arquivo para cá").foregroundStyle(.secondary)
                        }
                        if !recentes.isEmpty {
                            Text("Recentes").font(.caption.bold()).foregroundStyle(.secondary)
                            ForEach(recentes, id: \.self) { u in
                                Button {
                                    Task { await model.abrirArquivo(u); RealmInicio.lembrar(u) }
                                } label: {
                                    HStack {
                                        Image(systemName: "clock")
                                        Text(u.lastPathComponent)
                                        Text(u.deletingLastPathComponent().path.replacingOccurrences(of: Config.home, with: "~"))
                                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .padding(6)
                }

                if let c = model.carregando { HStack { ProgressView().controlSize(.small); Text(c) } }
                if let v = MotorRealm.projetoComRealm(model.projeto) {
                    Text("Motor: pacote realm de \(URL(fileURLWithPath: v).lastPathComponent)/node_modules — a mesma versão que o app usa.")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    Label("Nenhum projeto com o pacote realm instalado. Rode \"Dependências\" num app que usa Realm.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: app.alvo?.id) { await buscar() }
    }

    private func buscar() async {
        guard let d = app.alvo else { return }
        buscando = true
        defer { buscando = false }
        erroCelular = nil
        arquivos = []
        pacote = await pacoteDoProjeto(d)
        guard let pacote else { erroCelular = "Não achei o pacote (applicationId) do app."; return }
        switch await RealmModel.arquivosNoCelular(d, pacote: pacote) {
        case .success(let a): arquivos = a
        case .failure(let f): erroCelular = f.texto
        }
    }

    /// applicationId pelo build.gradle; nos apps Expo sem pasta android, pelo app.config/app.json
    private func pacoteDoProjeto(_ d: Dispositivo) async -> String? {
        if FileManager.default.fileExists(atPath: "\(Config.pasta(model.projeto))/android/app/build.gradle"),
           let p = await Adb.pacote(model.projeto, em: d) { return p }
        for arq in ["app.config.ts", "app.config.js", "app.json"] {
            let t = (try? String(contentsOfFile: "\(Config.pasta(model.projeto))/\(arq)", encoding: .utf8)) ?? ""
            if let r = t.range(of: #"["']?package["']?\s*:\s*["']([A-Za-z0-9_.]+)["']"#, options: .regularExpression) {
                let base = String(t[r]).components(separatedBy: CharacterSet(charactersIn: "\"'")).dropLast().last ?? ""
                let lista = await Adb.shell(d, "pm list packages \(base)").out
                    .split(separator: "\n").map { $0.replacingOccurrences(of: "package:", with: "").trimmingCharacters(in: .whitespaces) }
                    .filter { $0 == base || $0.hasPrefix(base + ".") }
                return lista.first { $0.hasSuffix(".debug") } ?? lista.first ?? base
            }
        }
        return nil
    }

    private func escolherArquivo() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "realm") ?? .data, .zip]
        p.allowsOtherFileTypes = true
        p.message = "Escolha o backup .zip do app ou um arquivo .realm"
        guard p.runModal() == .OK, let u = p.url else { return }
        RealmInicio.lembrar(u)
        Task { await model.abrirArquivo(u) }
    }
}

// MARK: - Barra superior

/// Abre o Realm numa janela própria em tela cheia (mesmo banco aberto)
struct BotaoTelaCheiaRealm: View {
    let projeto: String
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button { openWindow(id: "realm", value: projeto) } label: { Label("Tela cheia", systemImage: "arrow.up.left.and.arrow.down.right") }
            .help("Abre o Realm numa janela própria em tela cheia (o banco aberto continua o mesmo)")
    }
}

struct RealmBarra: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: RealmModel
    var emJanela = false
    @State private var confirmarEnvio = false
    @State private var reabrir = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if model.backup == nil { Image(systemName: model.doCelular ? "iphone.gen3" : "doc").foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.origem?.descricao ?? "").font(.callout.weight(.semibold)).lineLimit(1)
                    Text("schema v\(model.schemaVersion) · \(ByteCountFormatter.string(fromByteCount: model.tamanho, countStyle: .file)) · \(model.classes.filter { !$0.embutida }.count) classes · Realm \(model.motor.versao)"
                         + (model.atualizadoEm.map { " · lido às " + $0.formatted(date: .omitted, time: .standard) } ?? ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if model.alteracoes > 0 {
                    Label("\(model.alteracoes) alteração(ões) na cópia", systemImage: "pencil.circle.fill")
                        .font(.caption.bold()).foregroundStyle(.orange)
                        .help("As edições estão só na cópia de trabalho. Salve como arquivo ou envie ao celular.")
                }
                Spacer()
                if let c = model.carregando { ProgressView().controlSize(.small); Text(c).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if model.doCelular {
                    Button { Task { await model.recarregarDoCelular(app) } } label: { Label("Atualizar", systemImage: "arrow.clockwise") }
                        .disabled(model.alteracoes > 0 || model.carregando != nil)
                        .help(model.alteracoes > 0 ? "Salve ou envie as alterações antes de atualizar" : "Baixa o banco do celular de novo, mantendo a tabela, o filtro e o registro abertos")
                    Toggle("Auto (5s)", isOn: $model.autoAtualizar).toggleStyle(.checkbox)
                        .onChange(of: model.autoAtualizar) { model.alternarAuto(app) }
                        .help("Atualiza sozinho a cada 5 segundos enquanto não houver edições")
                    Button { confirmarEnvio = true } label: { Label("Enviar ao celular…", systemImage: "square.and.arrow.up.on.square") }
                        .disabled(model.alteracoes == 0 || model.carregando != nil)
                }
                if !emJanela { BotaoTelaCheiaRealm(projeto: model.projeto) }
                Menu {
                    Button("Salvar como arquivo .realm…") { salvarComo() }
                    Divider()
                    Button("Abrir outro banco…") { model.fecharBanco(app) }
                    Button("Mostrar a cópia de trabalho no Finder") { if let c = model.copia { NSWorkspace.shared.activateFileViewerSelecting([c]) } }
                    Button("Backups enviados ao celular") {
                        try? FileManager.default.createDirectory(at: RealmModel.pastaBackups, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(RealmModel.pastaBackups)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            .controlSize(.small)
            .padding(.horizontal, 12).padding(.vertical, 8)
            if let a = model.aviso {
                HStack(alignment: .top) {
                    Text(a).font(.caption).foregroundStyle(a.hasPrefix("✓") ? .green : .orange).textSelection(.enabled)
                    Spacer()
                    Button { model.aviso = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 12).padding(.bottom, 6)
            }
        }
        .sheet(isPresented: $confirmarEnvio) { envio }
    }

    private var envio: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Enviar o banco editado ao celular?", systemImage: "square.and.arrow.up.on.square").font(.title3.bold())
            if case .celular(_, let pacote, let arquivo) = model.origem {
                Text("\(model.alteracoes) alteração(ões) vão substituir files/\(arquivo) do app \(pacote). Passo a passo:")
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Fecha o app no celular (am force-stop)")
                    Text("2. Guarda o banco atual do celular em ~/Documents/BuildRemoto/Realm/\(pacote)/")
                    Text("3. Envia a cópia editada e confere o hash (SHA-1)")
                    Text("4. Se o hash não bater, devolve o banco original automaticamente")
                    if reabrir { Text("5. Abre o app de novo") }
                }
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                Label("Se o app estiver sincronizando com o servidor, dados alterados no celular depois do último \"Atualizar\" serão perdidos.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            Toggle("Reabrir o app depois", isOn: $reabrir).toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Cancelar") { confirmarEnvio = false }.keyboardShortcut(.cancelAction)
                Button("Enviar") {
                    confirmarEnvio = false
                    Task { await model.enviarAoCelular(app, reabrir: reabrir) }
                }
                .buttonStyle(.borderedProminent).tint(.orange)
            }
        }
        .padding(22).frame(width: 560)
    }

    private func salvarComo() {
        let p = NSSavePanel()
        p.nameFieldStringValue = (model.origem?.descricao.components(separatedBy: "/").last ?? "banco").replacingOccurrences(of: ".realm", with: "") + "-editado.realm"
        p.allowedContentTypes = [UTType(filenameExtension: "realm") ?? .data]
        guard p.runModal() == .OK, let u = p.url else { return }
        Task { await model.salvarComo(u) }
    }
}

// MARK: - Lista de classes

struct RealmClasses: View {
    @ObservedObject var model: RealmModel
    @State private var busca = ""
    @State private var verEmbutidas = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Classes", text: $busca).textFieldStyle(.plain)
            }
            .padding(8)
            Divider()
            List(selection: Binding(get: { model.classe }, set: { c in if let c { Task { await model.escolher(c) } } })) {
                ForEach(model.classes.filter { (!$0.embutida || verEmbutidas) && (busca.isEmpty || $0.nome.localizedCaseInsensitiveContains(busca)) }) { c in
                    HStack {
                        Image(systemName: c.embutida ? "square.on.square.dashed" : "tablecells").foregroundStyle(.secondary)
                        Text(c.nome).lineLimit(1)
                        Spacer()
                        if let n = model.contagens[c.nome] {
                            Text("\(n)").font(.caption.monospacedDigit()).foregroundStyle(n == 0 ? .tertiary : .secondary)
                        }
                    }
                    .tag(c.nome)
                    .help(c.embutida ? "Classe embutida: só existe dentro de outro registro" : "\(c.campos.count) campos" + (c.chave.map { " · chave: \($0)" } ?? " · sem chave primária"))
                }
            }
            .listStyle(.sidebar)
            Divider()
            Toggle("Mostrar classes embutidas", isOn: $verEmbutidas).toggleStyle(.checkbox).font(.caption).padding(8)
        }
    }
}

// MARK: - Tabela

struct RealmTabela: View {
    @ObservedObject var model: RealmModel
    @State private var larguras: [String: CGFloat] = [:]
    @State private var ajuda = false
    @State private var confirmarApagar = false
    @State private var confirmarApagarFiltro = false
    @State private var novo = false
    @State private var verSchema = false

    private var campos: [RCampo] { model.classeAtual?.campos ?? [] }
    private func largura(_ c: RCampo) -> CGFloat { larguras[c.nome] ?? (c.primario ? 210 : c.tipo == "bool" ? 80 : c.tipo == "int" ? 100 : 170) }

    var body: some View {
        VStack(spacing: 0) {
            barraFiltro
            if let e = model.erroFiltro {
                Text(e).font(.system(size: 11, design: .monospaced)).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.bottom, 6)
            }
            Divider()
            if verSchema { schema } else { grade }
            Divider()
            rodape
        }
        .confirmationDialog("Apagar \(model.selecao.count) registro(s) de \(model.classe ?? "")?", isPresented: $confirmarApagar) {
            Button("Apagar", role: .destructive) { Task { await model.apagar(model.classe ?? "", Array(model.selecao)) } }
        } message: { Text("Só na cópia de trabalho — o original não muda até você salvar ou enviar.") }
        .confirmationDialog("Apagar TODOS os \(model.total) registros \(model.filtro.isEmpty ? "de \(model.classe ?? "")" : "que batem com o filtro")?", isPresented: $confirmarApagarFiltro) {
            Button("Apagar \(model.total)", role: .destructive) { Task { await model.apagarFiltrados() } }
        } message: { Text(model.filtro.isEmpty ? "A tabela inteira fica vazia (na cópia de trabalho)." : "Filtro: \(model.filtro)") }
        .sheet(isPresented: $novo) {
            if let c = model.classeAtual { RealmNovo(model: model, classe: c) }
        }
    }

    private var barraFiltro: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
            TextField("Filtro RQL — ex.: status == \"pendente\" AND data > 2024-01-01@00:00:00", text: $model.filtro)
                .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                .onSubmit { model.pagina = 0; Task { await model.consultar() } }
            if !model.filtro.isEmpty {
                Button { model.filtro = ""; model.pagina = 0; Task { await model.consultar() } } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            Menu {
                if model.filtrosRecentes.isEmpty { Text("Nenhum filtro usado ainda") }
                ForEach(model.filtrosRecentes, id: \.self) { f in
                    Button(f) { model.filtro = f; model.pagina = 0; Task { await model.consultar() } }
                }
            } label: { Image(systemName: "clock.arrow.circlepath") }
                .menuStyle(.borderlessButton).fixedSize().help("Filtros recentes")
            Button { ajuda.toggle() } label: { Image(systemName: "questionmark.circle") }
                .buttonStyle(.borderless).popover(isPresented: $ajuda) { AjudaRQL(campos: campos) }
            Picker("", selection: $verSchema) {
                Image(systemName: "tablecells").tag(false)
                Image(systemName: "list.bullet.indent").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().help("Dados / Estrutura da classe")
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private var grade: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(campos) { c in cabecalho(c) }
                }
                .background(.bar)
                Divider()
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.linhas.enumerated()), id: \.element.key) { i, l in
                            linha(l, par: i % 2 == 0)
                        }
                    }
                }
            }
        }
        .overlay {
            if model.linhas.isEmpty && model.erroFiltro == nil {
                ContentUnavailableView(model.filtro.isEmpty ? "Tabela vazia" : "Nenhum registro com esse filtro", systemImage: "tray")
            }
        }
    }

    private func cabecalho(_ c: RCampo) -> some View {
        HStack(spacing: 3) {
            if c.primario { Image(systemName: "key.fill").font(.system(size: 9)).foregroundStyle(.yellow) }
            Text(c.nome).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
            Text(c.tipoTexto).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            if model.ordem == c.nome { Image(systemName: model.desc ? "chevron.down" : "chevron.up").font(.system(size: 9, weight: .bold)) }
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .frame(width: largura(c), alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { if !c.ehColecao && c.tipo != "object" || c.ehLink { Task { await model.ordenar(c.ehLink ? c.nome + "." + (model.classes.first { $0.nome == c.objectType }?.chave ?? "") : c.nome) } } }
        .help("\(c.nome): \(c.tipoTexto)" + (c.indexado ? " · indexado" : "") + " — clique para ordenar")
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1)
                .padding(.vertical, 4)
                .overlay(Color.clear.frame(width: 8).contentShape(Rectangle())
                    .gesture(DragGesture().onChanged { v in larguras[c.nome] = max(60, largura(c) + v.translation.width / 6) })
                    .onHover { dentro in if dentro { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } })
        }
    }

    private func linha(_ l: RLinha, par: Bool) -> some View {
        let sel = model.selecao.contains(l.key) || model.detalhe?.key == l.key && model.detalhe?.cls == model.classe
        return HStack(spacing: 0) {
            ForEach(campos) { c in
                let v = l.valores[c.nome]
                Text(RealmFmt.texto(v))
                    .font(.system(size: 11.5, design: c.tipo == "string" ? .default : .monospaced))
                    .foregroundStyle(RealmFmt.cor(v))
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .frame(width: largura(c), alignment: .leading)
            }
        }
        .background(sel ? Color.accentColor.opacity(0.25) : par ? Color.clear : Color.secondary.opacity(0.05))
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                if model.selecao.contains(l.key) { model.selecao.remove(l.key) } else { model.selecao.insert(l.key) }
            } else {
                model.selecao = [l.key]
                if let c = model.classe { Task { await model.abrirObjeto(c, l.key) } }
            }
        }
        .contextMenu {
            Button("Copiar como JSON") { copiar(RealmFmt.jsonEditavel(l.valores)) }
            if let c = model.classeAtual, let pk = c.chave { Button("Copiar \(pk)") { copiar(RealmFmt.texto(l.valores[pk])) } }
            Divider()
            Button("Apagar…", role: .destructive) {
                if !model.selecao.contains(l.key) { model.selecao = [l.key] }
                confirmarApagar = true
            }
        }
    }

    private var schema: some View {
        List {
            if let c = model.classeAtual {
                Section("\(c.nome) — \(c.chave.map { "chave primária: \($0)" } ?? "sem chave primária")\(c.embutida ? " · embutida" : "")") {
                    ForEach(c.campos) { f in
                        HStack {
                            Image(systemName: f.primario ? "key.fill" : f.ehLink || f.colecaoDeObjetos ? "link" : "textformat")
                                .foregroundStyle(f.primario ? .yellow : .secondary).frame(width: 18)
                            Text(f.nome).font(.system(size: 12.5, weight: .medium, design: .monospaced))
                            Spacer()
                            if f.indexado { Text("indexado").font(.caption2).foregroundStyle(.secondary) }
                            Text(f.tipoTexto).font(.system(size: 12, design: .monospaced)).foregroundStyle(.blue)
                        }
                    }
                }
                let apontam = model.classes.flatMap { o in o.campos.filter { $0.objectType == c.nome && $0.tipo != "linkingObjects" }.map { (o.nome, $0) } }
                if !apontam.isEmpty {
                    Section("Quem aponta para \(c.nome)") {
                        ForEach(apontam, id: \.1.id) { cls, f in
                            Text("\(cls).\(f.nome)  (\(f.tipoTexto))").font(.system(size: 12, design: .monospaced))
                        }
                    }
                }
            }
        }
    }

    private var rodape: some View {
        HStack(spacing: 10) {
            let ini = model.total == 0 ? 0 : model.pagina * model.limite + 1
            let fim = min(model.total, (model.pagina + 1) * model.limite)
            Button { model.pagina -= 1; Task { await model.consultar() } } label: { Image(systemName: "chevron.left") }
                .disabled(model.pagina == 0)
            Text("\(ini)–\(fim) de \(model.total)").font(.caption.monospacedDigit())
            Button { model.pagina += 1; Task { await model.consultar() } } label: { Image(systemName: "chevron.right") }
                .disabled(fim >= model.total)
            if !model.selecao.isEmpty {
                Text("\(model.selecao.count) selecionado(s)").font(.caption).foregroundStyle(.secondary)
                Button(role: .destructive) { confirmarApagar = true } label: { Label("Apagar", systemImage: "trash") }
            }
            Spacer()
            Button { novo = true } label: { Label("Novo registro", systemImage: "plus") }
                .disabled(model.classeAtual?.embutida != false)
            Menu {
                Button("Exportar como JSON…") { exportar("json") }
                Button("Exportar como CSV…") { exportar("csv") }
                Divider()
                Button("Apagar todos os \(model.total) \(model.filtro.isEmpty ? "registros" : "filtrados")…", role: .destructive) { confirmarApagarFiltro = true }
                    .disabled(model.total == 0)
            } label: { Label("Mais", systemImage: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func exportar(_ formato: String) {
        let p = NSSavePanel()
        p.nameFieldStringValue = "\(model.classe ?? "dados").\(formato)"
        guard p.runModal() == .OK, let u = p.url else { return }
        Task { await model.exportar(formato, para: u) }
    }
}

struct AjudaRQL: View {
    let campos: [RCampo]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Realm Query Language").font(.headline)
            Group {
                Text("nome == \"Maria\"   ·   nome CONTAINS[c] \"mar\"   ·   nome BEGINSWITH \"A\"")
                Text("idade > 18 AND ativo == true   ·   NOT (status IN {\"ok\", \"cancelado\"})")
                Text("criadoEm > 2024-05-01@00:00:00   ·   observacao == nil")
                Text("_id == oid(6643a1f0c2d4b8e9f1a2b3c4)   ·   dono.nome == \"Ana\"")
                Text("itens.@count > 0   ·   ANY itens.quantidade > 10   ·   valor.@sum > 100")
                Text("status == \"pendente\" SORT(data DESC) LIMIT(10)")
                Text("sincronizado == false   ·   apagado == true")
            }
            .font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
            if !campos.isEmpty {
                Divider()
                Text("Campos desta classe").font(.caption.bold())
                Text(campos.map { "\($0.nome): \($0.tipoTexto)" }.joined(separator: "   ")).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: 520, alignment: .leading)
            }
        }
        .padding(14)
        .frame(width: 560)
    }
}

// MARK: - Editor do registro

struct RealmEditor: View {
    @ObservedObject var model: RealmModel
    let detalhe: RDetalhe
    @State private var textos: [String: String] = [:]
    @State private var datas: [String: Date] = [:]
    @State private var bools: [String: Bool] = [:]
    @State private var nulos: Set<String> = []
    @State private var alterados: Set<String> = []
    @State private var erro: String?
    @State private var salvando = false
    @State private var confirmarApagar = false
    @State private var preparado = false

    private var classe: RClasse? { model.classes.first { $0.nome == detalhe.cls } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if model.podeVoltar {
                    Button { Task { await model.voltarObjeto() } } label: { Image(systemName: "chevron.left") }.help("Voltar ao registro anterior")
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(detalhe.cls).font(.caption).foregroundStyle(.secondary)
                    Text(detalhe.label).font(.headline).lineLimit(1).textSelection(.enabled)
                }
                Spacer()
                Menu {
                    Button("Copiar como JSON") { copiar(RealmFmt.jsonEditavel(detalhe.valores)) }
                    Button("Ver na tabela") { if let pk = classe?.chave, let l = literal(detalhe.valores[pk]) { Task { await model.aplicarFiltro(detalhe.cls, "\(pk) == \(l)") } } }
                        .disabled(classe?.chave == nil)
                    Divider()
                    Button("Apagar registro…", role: .destructive) { confirmarApagar = true }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                Button { model.detalhe = nil; model.selecao = [] } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                    .help("Fechar o painel (Esc)")
            }
            .padding(10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(classe?.campos ?? []) { c in campo(c) }
                    if !detalhe.apontam.isEmpty {
                        Divider()
                        Text("Quem aponta para este registro").font(.headline)
                        ForEach(detalhe.apontam) { a in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("\(a.cls).\(a.campo)").font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    Text("\(a.total)").font(.caption.bold()).foregroundStyle(.secondary)
                                    Spacer()
                                    if !a.filtro.isEmpty {
                                        Button("Ver todos na tabela") { Task { await model.aplicarFiltro(a.cls, a.filtro) } }.controlSize(.small)
                                    }
                                }
                                ForEach(a.itens, id: \.key) { i in
                                    Button { Task { await model.abrirObjeto(a.cls, i.key) } } label: {
                                        Label(i.label, systemImage: "arrow.right.circle").font(.system(size: 11.5)).lineLimit(1)
                                    }
                                    .buttonStyle(.borderless)
                                }
                                if a.total > a.itens.count { Text("+ \(a.total - a.itens.count)").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                .padding(12)
            }
            Divider()
            HStack {
                if let erro { Text(erro).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled) }
                Spacer()
                if !alterados.isEmpty {
                    Button("Descartar") { preparar() }
                    Button {
                        Task { await salvar() }
                    } label: { Label(salvando ? "Salvando…" : "Salvar \(alterados.count) campo(s)", systemImage: "checkmark") }
                        .buttonStyle(.borderedProminent).keyboardShortcut("s").disabled(salvando)
                }
            }
            .controlSize(.small)
            .padding(10)
        }
        .onAppear { preparar() }
        .confirmationDialog("Apagar este registro de \(detalhe.cls)?", isPresented: $confirmarApagar) {
            Button("Apagar", role: .destructive) { Task { await model.apagar(detalhe.cls, [detalhe.key]) } }
        } message: { Text("Só na cópia de trabalho.") }
    }

    private func literal(_ v: Any?) -> String? {
        guard let v else { return nil }
        if let s = v as? String { return "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\"" }
        if let n = v as? NSNumber { return n.stringValue }
        if let d = v as? [String: Any] {
            if let o = d["$oid"] as? String { return "oid(\(o))" }
            if let u = d["$uuid"] as? String { return "uuid(\(u))" }
        }
        return nil
    }

    // MARK: campos

    private func preparar() {
        textos = [:]; datas = [:]; bools = [:]; nulos = []; alterados = []; erro = nil
        for c in classe?.campos ?? [] {
            let v = detalhe.valores[c.nome]
            if v == nil || v is NSNull { nulos.insert(c.nome) }
            switch c.tipo {
            case "bool": bools[c.nome] = (v as? NSNumber)?.boolValue ?? false
            case "date": datas[c.nome] = ((v as? [String: Any])?["$date"] as? String).flatMap(RealmFmt.dataDe) ?? Date()
            case "list", "set", "dictionary", "mixed": textos[c.nome] = RealmFmt.jsonEditavel(v)
            case "object":
                if c.ehLink { textos[c.nome] = (v as? [String: Any])?["label"] as? String ?? "" }
                else { textos[c.nome] = RealmFmt.jsonEditavel((v as? [String: Any])?["valores"] ?? v) }
            default: textos[c.nome] = (v == nil || v is NSNull) ? "" : (v as? String ?? RealmFmt.texto(v))
            }
        }
        preparado = true
    }

    private func marcar(_ c: RCampo) { if preparado { alterados.insert(c.nome); erro = nil } }

    @ViewBuilder private func campo(_ c: RCampo) -> some View {
        let v = detalhe.valores[c.nome]
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if c.primario { Image(systemName: "key.fill").font(.system(size: 9)).foregroundStyle(.yellow) }
                Text(c.nome).font(.system(size: 12, weight: .semibold))
                Text(c.tipoTexto).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                if alterados.contains(c.nome) { Circle().fill(.orange).frame(width: 6, height: 6) }
                Spacer()
                if c.opcional && !c.ehColecao && !c.primario {
                    Toggle("nulo", isOn: Binding(get: { nulos.contains(c.nome) }, set: { if $0 { nulos.insert(c.nome) } else { nulos.remove(c.nome) }; marcar(c) }))
                        .toggleStyle(.checkbox).font(.caption).controlSize(.small)
                }
            }
            editor(c, v).disabled(nulos.contains(c.nome) && c.opcional && !c.ehColecao)
                .opacity(nulos.contains(c.nome) && c.opcional && !c.ehColecao ? 0.4 : 1)
        }
    }

    @ViewBuilder private func editor(_ c: RCampo, _ v: Any?) -> some View {
        switch c.tipo {
        case _ where c.primario:
            Text(RealmFmt.texto(v)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .help("A chave primária não pode ser alterada no Realm")
        case "bool":
            Picker("", selection: Binding(get: { bools[c.nome] ?? false }, set: { bools[c.nome] = $0; marcar(c) })) {
                Text("true").tag(true); Text("false").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        case "date":
            HStack {
                DatePicker("", selection: Binding(get: { datas[c.nome] ?? Date() }, set: { datas[c.nome] = $0; marcar(c) }),
                           displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                Text(datas[c.nome].map { RealmFmt.isoFracao.string(from: $0) } ?? "").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
        case "data":
            Text(RealmFmt.texto(v) + (((v as? [String: Any])?["preview"] as? String).map { "  " + $0 } ?? ""))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
        case "linkingObjects":
            colecaoDeObjetos(c, v)
        case "list", "set", "dictionary":
            VStack(alignment: .leading, spacing: 4) {
                if c.colecaoDeObjetos { colecaoDeObjetos(c, v) }
                jsonEditor(c, dica: c.colecaoDeObjetos ? "Lista de chaves primárias de \(c.objectType ?? ""), ex.: [1, 2]" : "JSON")
            }
        case "mixed":
            jsonEditor(c, dica: "Valor JSON: \"texto\", 12, true, null…")
        case "object":
            if c.ehLink {
                HStack {
                    TextField("chave primária de \(c.objectType ?? "")", text: Binding(get: { textos[c.nome] ?? "" }, set: { textos[c.nome] = $0; marcar(c) }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    if let d = v as? [String: Any], let k = d["key"] as? String, let cls = d["$link"] as? String {
                        Button { Task { await model.abrirObjeto(cls, k) } } label: { Label("Ir", systemImage: "arrow.right.circle.fill") }
                            .controlSize(.small)
                    }
                }
            } else {
                jsonEditor(c, dica: "Objeto embutido \(c.objectType ?? "") em JSON")
            }
        case "string":
            TextField("", text: Binding(get: { textos[c.nome] ?? "" }, set: { textos[c.nome] = $0; marcar(c) }), axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...8).font(.system(size: 12))
        default:
            TextField(c.tipo, text: Binding(get: { textos[c.nome] ?? "" }, set: { textos[c.nome] = $0; marcar(c) }))
                .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
        }
    }

    private func jsonEditor(_ c: RCampo, dica: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextEditor(text: Binding(get: { textos[c.nome] ?? "" }, set: { textos[c.nome] = $0; marcar(c) }))
                .font(.system(size: 11.5, design: .monospaced))
                .frame(minHeight: 44, maxHeight: 160)
                .padding(3)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            Text(dica).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func colecaoDeObjetos(_ c: RCampo, _ v: Any?) -> some View {
        let d = v as? [String: Any]
        let itens = (d?["itens"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(d?["$list"] as? Int ?? 0) item(ns)").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(itens.prefix(50).enumerated()), id: \.offset) { _, i in
                if let cls = i["$link"] as? String, let k = i["key"] as? String {
                    Button { Task { await model.abrirObjeto(cls, k) } } label: {
                        Label(i["label"] as? String ?? k, systemImage: "arrow.right.circle").font(.system(size: 11.5)).lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: salvar

    private func salvar() async {
        var valores: [String: Any] = [:]
        for nome in alterados {
            guard let c = classe?.campos.first(where: { $0.nome == nome }) else { continue }
            if nulos.contains(nome) && c.opcional && !c.ehColecao { valores[nome] = NSNull(); continue }
            switch c.tipo {
            case "bool": valores[nome] = bools[nome] ?? false
            case "date": valores[nome] = ["$date": RealmFmt.isoFracao.string(from: datas[nome] ?? Date())]
            case "list", "set", "dictionary", "mixed":
                let t = textos[nome] ?? ""
                if let j = try? JSONSerialization.jsonObject(with: Data(t.utf8), options: [.fragmentsAllowed]) { valores[nome] = j }
                else if c.tipo == "mixed" { valores[nome] = t }
                else { erro = "\(nome): JSON inválido"; return }
            case "object":
                let t = (textos[nome] ?? "").trimmingCharacters(in: .whitespaces)
                if c.ehLink { valores[nome] = t.isEmpty ? NSNull() : ["$pk": t] }
                else if let j = try? JSONSerialization.jsonObject(with: Data(t.utf8)) { valores[nome] = j }
                else { erro = "\(nome): JSON inválido"; return }
            default: valores[nome] = textos[nome] ?? ""
            }
        }
        salvando = true
        erro = await model.salvar(detalhe.cls, detalhe.key, valores)
        salvando = false
    }
}

// MARK: - Novo registro

struct RealmNovo: View {
    @ObservedObject var model: RealmModel
    let classe: RClasse
    @Environment(\.dismiss) private var dismiss
    @State private var textos: [String: String] = [:]
    @State private var erro: String?

    private var editaveis: [RCampo] { classe.campos.filter { $0.tipo != "linkingObjects" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Novo registro em \(classe.nome)").font(.title3.bold())
            Text("Deixe em branco o que não quiser preencher. Datas em ISO (2024-05-01T10:00:00Z), listas e objetos em JSON, links pela chave primária. Chaves ObjectId/UUID vazias são geradas sozinhas.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    ForEach(editaveis) { c in
                        GridRow {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(c.nome).font(.system(size: 12, weight: .semibold))
                                Text(c.tipoTexto).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            TextField(c.opcional ? "opcional" : "obrigatório", text: Binding(get: { textos[c.nome] ?? "" }, set: { textos[c.nome] = $0 }))
                                .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                        }
                    }
                }
            }
            .frame(maxHeight: 420)
            if let erro { Text(erro).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Criar") { Task { await criar() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func criar() async {
        var valores: [String: Any] = [:]
        for c in editaveis {
            let t = (textos[c.nome] ?? "").trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            switch c.tipo {
            case "list", "set", "dictionary", "mixed":
                valores[c.nome] = (try? JSONSerialization.jsonObject(with: Data(t.utf8), options: [.fragmentsAllowed])) ?? t
            case "object":
                valores[c.nome] = c.ehLink ? ["$pk": t] : ((try? JSONSerialization.jsonObject(with: Data(t.utf8))) ?? t)
            case "bool": valores[c.nome] = ["true", "1", "sim"].contains(t.lowercased())
            default: valores[c.nome] = t
            }
        }
        if let e = await model.criar(classe.nome, valores) { erro = e } else { dismiss() }
    }
}

// MARK: - Backup .zip

enum AbaBackup: String, CaseIterable, Identifiable {
    case banco = "Banco (Realm)", storage = "AsyncStorage", arquivos = "Fotos e áudios"
    var id: String { rawValue }
}

struct BackupCabecalho: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: RealmModel
    let backup: ConteudoBackup
    @Binding var aba: AbaBackup
    var emJanela = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.zipper").font(.title2).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(backup.zip.lastPathComponent).font(.callout.weight(.semibold)).lineLimit(1)
                Text([backup.dataBackup.map { "feito em " + RealmFmt.data.string(from: $0) },
                      backup.imei.map { "IMEI \($0)" },
                      "\(backup.storage.count) chaves",
                      "\(backup.arquivos.count) arquivos (\(ByteCountFormatter.string(fromByteCount: backup.tamanhoArquivos, countStyle: .file)))",
                      backup.extras.isEmpty ? nil : "outros: " + backup.extras.joined(separator: ", ")]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Picker("", selection: $aba) {
                ForEach(AbaBackup.allCases) { a in
                    Text(a == .storage ? "\(a.rawValue) (\(backup.storage.count))" : a == .arquivos ? "\(a.rawValue) (\(backup.arquivos.count))" : a.rawValue).tag(a)
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if model.alteracoes > 0 || backup.storageEditado {
                Text("editado").font(.caption.bold()).foregroundStyle(.orange)
            }
            Button { gerar() } label: { Label("Gerar novo .zip…", systemImage: "archivebox") }
                .help("Monta um backup novo, no mesmo formato do app, com o banco e o AsyncStorage como estão agora")
            if !emJanela { BotaoTelaCheiaRealm(projeto: model.projeto) }
            Button { model.fecharBanco(app) } label: { Image(systemName: "xmark.circle") }.help("Fechar o backup").buttonStyle(.borderless)
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func gerar() {
        let p = NSSavePanel()
        p.nameFieldStringValue = backup.zip.deletingPathExtension().lastPathComponent + "-editado.zip"
        p.allowedContentTypes = [.zip]
        guard p.runModal() == .OK, let u = p.url else { return }
        Task { await model.gerarZip(u) }
    }
}

struct BackupStorageView: View {
    @ObservedObject var model: RealmModel
    @State private var busca = ""
    @State private var selecionado: String?
    @State private var rascunho = ""
    @State private var editando = false
    @State private var nova = false
    @State private var novaChave = ""

    private var itens: [ItemStorage] {
        (model.backup?.storage ?? []).filter { busca.isEmpty || $0.chave.localizedCaseInsensitiveContains(busca) || $0.valor.localizedCaseInsensitiveContains(busca) }
    }
    private var atual: ItemStorage? { model.backup?.storage.first { $0.chave == selecionado } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Buscar na chave ou no valor", text: $busca).textFieldStyle(.plain)
                    Button { nova = true } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("Nova chave")
                }
                .padding(8)
                Divider()
                List(itens, selection: Binding(get: { selecionado }, set: { selecionado = $0; editando = false })) { i in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(i.chave).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1)
                        Text(i.valor.prefix(120)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(i.chave)
                }
                .listStyle(.inset)
                Text("\(itens.count) de \(model.backup?.storage.count ?? 0) chaves").font(.caption2).foregroundStyle(.secondary).padding(5)
            }
            .frame(minWidth: 260, idealWidth: 320, maxWidth: 460, maxHeight: .infinity)

            Group {
                if let i = atual {
                    VStack(spacing: 0) {
                        HStack {
                            Text(i.chave).font(.system(size: 12.5, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(i.valor.utf8.count), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if editando {
                                Button("Cancelar") { editando = false }
                                Button("Salvar") {
                                    model.editarStorage(i.chave, rascunho); editando = false
                                }
                                .buttonStyle(.borderedProminent).keyboardShortcut("s")
                                .disabled(ehJSON(i.valor) && !ehJSON(rascunho))
                            } else {
                                Button { copiar(i.formatado) } label: { Image(systemName: "doc.on.doc") }.help("Copiar")
                                Button { rascunho = i.formatado; editando = true } label: { Label("Editar", systemImage: "pencil") }
                                Button(role: .destructive) { model.editarStorage(i.chave, nil); selecionado = nil } label: { Image(systemName: "trash") }
                            }
                        }
                        .controlSize(.small).padding(10)
                        Divider()
                        if editando {
                            TextEditor(text: $rascunho).font(.system(size: 12, design: .monospaced)).padding(6)
                            if ehJSON(i.valor) && !ehJSON(rascunho) {
                                Text("JSON inválido").font(.caption).foregroundStyle(.red).padding(6)
                            }
                        } else {
                            ScrollView {
                                Text(i.formatado).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Escolha uma chave", systemImage: "key", description: Text("O valor aparece formatado quando é JSON. As edições entram no \"Gerar novo .zip\"."))
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $nova) {
            NomeSheet(titulo: "Nova chave no AsyncStorage", placeholder: "chave", botao: "Criar") { k in
                model.editarStorage(k, ""); selecionado = k
            }
        }
    }

    private func ehJSON(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{") || t.hasPrefix("[") else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(t.utf8))) != nil
    }
}

struct BackupArquivosView: View {
    let backup: ConteudoBackup
    @State private var busca = ""

    private var itens: [URL] { backup.arquivos.filter { busca.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(busca) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar pelo nome (ex.: o código da foto)", text: $busca).textFieldStyle(.plain)
                Button { NSWorkspace.shared.open(backup.pasta.appendingPathComponent("arquivos_usuario")) } label: { Label("Abrir pasta", systemImage: "folder") }
                    .controlSize(.small)
            }
            .padding(8)
            Divider()
            if itens.isEmpty {
                ContentUnavailableView("Nenhum arquivo", systemImage: "photo.on.rectangle",
                                       description: Text("O backup foi gerado sem fotos e áudios, ou eles foram enviados direto ao servidor."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(itens, id: \.self) { u in MiniaturaArquivo(url: u) }
                    }
                    .padding(12)
                }
            }
        }
    }
}

struct MiniaturaArquivo: View {
    let url: URL
    @State private var imagem: NSImage?
    private var ehImagem: Bool { ["jpg", "jpeg", "png", "webp", "heic"].contains(url.pathExtension.lowercased()) }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1))
                if let imagem { Image(nsImage: imagem).resizable().scaledToFill() }
                else { Image(systemName: ehImagem ? "photo" : "waveform").font(.largeTitle).foregroundStyle(.secondary) }
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
            Text(ByteCountFormatter.string(fromByteCount: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), countStyle: .file))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .contextMenu {
            Button("Abrir") { NSWorkspace.shared.open(url) }
            Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Copiar nome") { copiar(url.lastPathComponent) }
        }
        .help("Duplo clique para abrir")
        .task {
            guard ehImagem else { return }
            let u = url
            imagem = await Task.detached {
                guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                              kCGImageSourceThumbnailMaxPixelSize: 300,
                                                                              kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
                else { return nil as NSImage? }
                return NSImage(cgImage: cg, size: .zero)
            }.value
        }
    }
}
