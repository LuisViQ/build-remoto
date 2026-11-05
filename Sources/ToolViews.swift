import SwiftUI
import WebKit
import UniformTypeIdentifiers

// MARK: - Painel da tela do celular (inspector à direita)

struct PainelTela: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var mirror: MirrorSession
    @State private var aviso: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "iphone.gen3").foregroundStyle(.secondary)
                Text(mirror.nomeAparelho.isEmpty ? (app.alvo?.nome ?? "Tela") : mirror.nomeAparelho)
                    .font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                if let d = mirror.dispositivo {
                    Text(d.origem == .pc ? "PC" : "Mac").font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                }
                Spacer()
                if mirror.ativo {
                    Button { mirror.parar() } label: { Image(systemName: "stop.circle") }
                        .buttonStyle(.borderless).help("Parar espelhamento")
                } else {
                    Button { app.abrirTela() } label: { Image(systemName: "play.circle") }
                        .buttonStyle(.borderless).help("Iniciar").disabled(app.alvo == nil)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            ZStack {
                Color.black
                MirrorRepresentable(sessao: mirror)
                    .aspectRatio(mirror.tamanho.width / max(1, mirror.tamanho.height), contentMode: .fit)
                switch mirror.estado {
                case .rodando: EmptyView()
                case let .conectando(msg):
                    VStack(spacing: 10) { ProgressView().tint(.white); Text(msg) }.foregroundStyle(.white.opacity(0.8))
                case let .erro(msg):
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").font(.title)
                        Text(msg).font(.caption).multilineTextAlignment(.center).textSelection(.enabled)
                        Button("Tentar de novo") { app.abrirTela() }
                    }
                    .foregroundStyle(.white.opacity(0.85)).padding()
                case .parado:
                    VStack(spacing: 10) {
                        Image(systemName: "iphone.slash").font(.largeTitle)
                        Text(app.alvo == nil ? "Conecte um celular" : "Espelhamento parado")
                        if app.alvo != nil { Button("Iniciar") { app.abrirTela() } }
                    }
                    .foregroundStyle(.white.opacity(0.6))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 10)

            // Botões do aparelho
            let botoes: [(String, String, () -> Void)] = [
                ("chevron.backward", "Voltar", { mirror.tecla(4) }),
                ("circle", "Início", { mirror.tecla(3) }),
                ("square.on.square", "Apps recentes", { mirror.tecla(187) }),
                ("speaker.minus", "Volume −", { mirror.tecla(25) }),
                ("speaker.plus", "Volume +", { mirror.tecla(24) }),
                ("rotate.right", "Girar", { mirror.girar() }),
                ("bell", "Notificações", { mirror.painelNotificacoes() }),
                ("power", "Botão liga/desliga", { mirror.tecla(26) }),
            ]
            HStack(spacing: 2) {
                ForEach(Array(botoes.enumerated()), id: \.offset) { _, b in
                    Button(action: b.2) {
                        Image(systemName: b.0).font(.system(size: 13, weight: .medium)).frame(width: 30, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless).help(b.1)
                }
            }
            .disabled(mirror.estado != .rodando)
            .padding(.top, 8)
            HStack(spacing: 8) {
                Button {
                    Task {
                        if let u = await mirror.capturarTela() {
                            if let png = try? Data(contentsOf: u), let msg = PrintNaNota.oferecer(app, png: png) {
                                aviso = msg + " (e salvo na Mesa)"
                            } else {
                                aviso = "Print salvo na Mesa e copiado"
                                NSWorkspace.shared.activateFileViewerSelecting([u])
                            }
                        } else { aviso = "Falha no print" }
                    }
                } label: { Label("Print", systemImage: "camera") }
                GravarBotao(gravacao: app.gravacao)
                Button { mirror.alternarTela() } label: {
                    Label(mirror.telaApagada ? "Acender tela" : "Apagar tela", systemImage: mirror.telaApagada ? "sun.max" : "moon")
                }
                .help("Apaga a tela do celular mantendo o espelhamento (economiza bateria)")
            }
            .controlSize(.small)
            .disabled(mirror.estado != .rodando)
            .padding(.vertical, 8)
            if let aviso {
                Text(aviso).font(.caption).foregroundStyle(.secondary).padding(.bottom, 6)
                    .task { try? await Task.sleep(for: .seconds(3)); self.aviso = nil }
            }
            Text("Clique = toque · arraste = deslizar · botão direito = voltar · digite para escrever · ⌘V cola")
                .font(.system(size: 10)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                .padding(.horizontal, 10).padding(.bottom, 10)
        }
    }
}

// MARK: - Logcat

struct LogcatView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: LogcatModel
    let projeto: String
    @State private var seguir = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $model.nivelMin) {
                    ForEach(["V", "D", "I", "W", "E"], id: \.self) { Text($0).tag(Character($0)) }
                }
                .pickerStyle(.segmented).frame(width: 170).help("Nível mínimo")
                TextField("Filtrar mensagem ou tag", text: $model.busca)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Toggle("Só o app", isOn: $model.soApp).toggleStyle(.checkbox)
                    .help(model.pacote.map { "Somente processos de \($0)" } ?? "")
                if model.soApp, let p = model.pacote {
                    Text(model.pidsApp.isEmpty ? "\(p) (não está rodando)" : p)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                VigiaToggle(vigia: app.vigia)
                Button { model.pausado.toggle(); if !model.pausado { model.refiltrar() } } label: {
                    Image(systemName: model.pausado ? "play.fill" : "pause.fill")
                }.help(model.pausado ? "Continuar" : "Pausar")
                Button { model.limpar() } label: { Image(systemName: "trash") }.help("Limpar")
                Button {
                    if let u = model.exportar() { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                } label: { Image(systemName: "square.and.arrow.up") }.help("Exportar para a Mesa")
                if model.rodando {
                    Button("Parar") { model.parar() }
                } else {
                    Button("Iniciar") { if let d = app.alvo { model.iniciar(d, projeto: projeto) } }
                        .disabled(app.alvo == nil).buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.small)
            .padding(8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.visiveis) { l in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(l.hora).foregroundStyle(.secondary)
                                Text(String(l.nivel))
                                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                                    .frame(width: 16, height: 15)
                                    .background(RoundedRectangle(cornerRadius: 3).fill(l.cor.opacity(0.22)))
                                    .foregroundStyle(l.cor)
                                Text(l.tag).foregroundStyle(l.cor.opacity(0.9)).frame(width: 150, alignment: .leading).lineLimit(1)
                                Text(l.msg).foregroundStyle(l.nivel == "E" || l.nivel == "F" ? .red : .primary)
                                    .textSelection(.enabled)
                            }
                            .font(.system(size: 11.5, design: .monospaced))
                            .padding(.horizontal, 10).padding(.vertical, 1.5)
                            .background(l.nivel == "E" || l.nivel == "F" ? Color.red.opacity(0.07) : .clear)
                            .id(l.id)
                        }
                    }
                }
                .onChange(of: model.visiveis.last?.id) { _, id in
                    if seguir, let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            .overlay {
                if !model.rodando && model.visiveis.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle").font(.largeTitle)
                        Text(app.alvo == nil ? "Conecte um celular" : "Clique em Iniciar para ver o logcat de \(app.alvo!.nome)")
                    }.foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            if !model.rodando, let d = app.alvo, model.dispositivo?.id != d.id || model.visiveis.isEmpty {
                model.iniciar(d, projeto: projeto)
            }
        }
    }
}

// MARK: - Ferramentas do celular

struct CelularView: View {
    @EnvironmentObject var app: AppState
    let projeto: String
    @State private var pacote: String?
    @State private var info: [(String, String)] = []
    @State private var deepLink = ""
    @State private var textoEnviar = ""
    @State private var mensagem = ""
    @State private var escuro = false
    @State private var animacoes = true
    @State private var toques = false
    @State private var fonte = 1.0
    @State private var confirmar: String?
    @State private var soltando = false
    @State private var storage: [ItemStorage]?

    private var historicoKey: String { "deeplinks:\(projeto)" }
    private var historico: [String] { UserDefaults.standard.stringArray(forKey: historicoKey) ?? [] }

    var body: some View {
        if let d = app.alvo {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Cabeçalho com informações
                    HStack(spacing: 14) {
                        Image(systemName: "iphone.gen3").font(.system(size: 30)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(d.nome).font(.title3.bold())
                            Text(info.map { "\($0.0) \($0.1)" }.joined(separator: "  ·  "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(d.origem == .pc ? "Ligado no PC" : "Ligado no Mac")
                            .font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(.quaternary))
                    }

                    Grupo(titulo: "App", icone: "app.badge", subtitulo: pacote ?? "procurando pacote…") {
                        HStack {
                            Botao("Abrir", "play.fill") { await sh(d, "monkey -p \(pacote ?? "") -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; echo ok", "App aberto") }
                            Botao("Reiniciar", "arrow.clockwise") {
                                await sh(d, "am force-stop \(pacote ?? ""); monkey -p \(pacote ?? "") -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; echo ok", "App reiniciado")
                            }
                            Botao("Forçar parada", "stop.fill") { await sh(d, "am force-stop \(pacote ?? "")", "App parado") }
                            Button { confirmar = "limpar" } label: { Label("Limpar dados", systemImage: "eraser") }
                            Button(role: .destructive) { confirmar = "desinstalar" } label: { Label("Desinstalar", systemImage: "trash") }
                        }
                        .disabled(pacote == nil)
                    }

                    Grupo(titulo: "Dados do app", icone: "cylinder.split.1x2", subtitulo: "Somente builds de debug") {
                        HStack {
                            Botao("Ver AsyncStorage", "tray.full") {
                                guard let p = pacote else { return }
                                switch await DadosApp.asyncStorage(d, pacote: p) {
                                case let .success(itens): storage = itens
                                case let .failure(m): mensagem = m.texto
                                }
                            }
                            Botao("Visualizar banco Realm", "cylinder.split.1x2") {
                                guard let p = pacote else { return }
                                switch await RealmModel.arquivosNoCelular(d, pacote: p) {
                                case let .success(arqs):
                                    let arquivo = arqs.first { $0 == "default.realm" } ?? arqs[0]
                                    app.abaFerramenta[projeto] = .realm
                                    await app.realm(projeto).abrirCelular(d, pacote: p, arquivo: arquivo)
                                case let .failure(m): mensagem = m.texto
                                }
                            }
                            Menu {
                                Button("Salvar uma cópia do banco na Mesa") {
                                    guard let p = pacote else { return }
                                    Task {
                                        switch await DadosApp.baixarRealm(d, pacote: p) {
                                        case let .success(u): mensagem = "Realm salvo em \(u.lastPathComponent)"; NSWorkspace.shared.activateFileViewerSelecting([u])
                                        case let .failure(m): mensagem = m.texto
                                        }
                                    }
                                }
                            } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton).fixedSize()
                        }
                        .disabled(pacote == nil)
                        Text("O banco abre na aba Realm (cópia de trabalho: navegar, filtrar e editar). Tokens e configurações ficam no AsyncStorage.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Grupo(titulo: "Deep link", icone: "link", subtitulo: "Abre uma URL/rota no app") {
                        HStack {
                            TextField("ex.: meuapp://tela/123 ou https://…", text: $deepLink)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { Task { await abrirLink(d) } }
                            Button("Abrir") { Task { await abrirLink(d) } }.disabled(deepLink.isEmpty)
                        }
                        if !historico.isEmpty {
                            FlowLinks(links: historico) { deepLink = $0; Task { await abrirLink(d) } }
                        }
                    }

                    Grupo(titulo: "Digitar no celular", icone: "keyboard", subtitulo: "Envia o texto para o campo focado (logins, CPFs…)") {
                        HStack {
                            TextField("Texto", text: $textoEnviar).textFieldStyle(.roundedBorder)
                                .onSubmit { Task { await enviarTexto(d) } }
                            Button("Enviar") { Task { await enviarTexto(d) } }.disabled(textoEnviar.isEmpty)
                        }
                    }

                    Grupo(titulo: "Ajustes de teste", icone: "slider.horizontal.3", subtitulo: "Valem para o aparelho todo") {
                        Toggle("Modo escuro", isOn: $escuro).onChange(of: escuro) { _, v in
                            Task { await sh(d, "cmd uimode night \(v ? "yes" : "no")", v ? "Modo escuro ligado" : "Modo claro") }
                        }
                        Toggle("Animações do sistema", isOn: $animacoes).onChange(of: animacoes) { _, v in
                            let x = v ? "1" : "0"
                            Task { await sh(d, "settings put global window_animation_scale \(x); settings put global transition_animation_scale \(x); settings put global animator_duration_scale \(x)", v ? "Animações ligadas" : "Animações desligadas") }
                        }
                        Toggle("Mostrar toques", isOn: $toques).onChange(of: toques) { _, v in
                            Task { await sh(d, "settings put system show_touches \(v ? 1 : 0)", "") }
                        }
                        HStack {
                            Text("Tamanho da fonte")
                            Picker("", selection: $fonte) {
                                Text("Pequena").tag(0.85); Text("Normal").tag(1.0); Text("Grande").tag(1.3); Text("Enorme").tag(1.6)
                            }
                            .pickerStyle(.segmented).frame(width: 300)
                            .onChange(of: fonte) { _, v in Task { await sh(d, "settings put system font_scale \(v)", "Fonte \(v)x") } }
                        }
                        Botao("Reconectar Metro (adb reverse 8081)", "arrow.left.arrow.right") {
                            let r = await Adb.run(d, ["reverse", "tcp:8081", "tcp:8081"])
                            mensagem = r.ok ? "adb reverse ok" : r.out
                        }
                    }

                    // Instalar APK arrastando
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                        .foregroundStyle(soltando ? Color.accentColor : .secondary.opacity(0.5))
                        .frame(height: 70)
                        .overlay(Label("Arraste um .apk aqui para instalar em \(d.nome)", systemImage: "arrow.down.app")
                            .foregroundStyle(.secondary))
                        .onDrop(of: [.fileURL], isTargeted: $soltando) { itens in
                            for i in itens {
                                _ = i.loadObject(ofClass: URL.self) { u, _ in
                                    guard let u, u.pathExtension == "apk" else { return }
                                    DispatchQueue.main.async {
                                        app.instalarApk(Apk(url: u, data: Date(), tamanho: 0), em: d)
                                    }
                                }
                            }
                            return true
                        }

                    if !mensagem.isEmpty {
                        Text(mensagem).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .padding(20)
            }
            .confirmationDialog(confirmar == "limpar" ? "Limpar todos os dados do app?" : "Desinstalar o app?",
                                isPresented: Binding(get: { confirmar != nil }, set: { if !$0 { confirmar = nil } })) {
                Button(confirmar == "limpar" ? "Limpar dados" : "Desinstalar", role: .destructive) {
                    let acao = confirmar
                    Task {
                        if acao == "limpar" { await sh(d, "pm clear \(pacote ?? "")", "Dados apagados") }
                        else { let r = await Adb.run(d, ["uninstall", pacote ?? ""]); mensagem = r.ok ? "Desinstalado" : r.out }
                    }
                }
            } message: { Text(pacote ?? "") }
            .task(id: d.id) { await carregar(d) }
            .sheet(isPresented: Binding(get: { storage != nil }, set: { if !$0 { storage = nil } })) {
                AsyncStorageSheet(itens: storage ?? [], pacote: pacote ?? "")
            }
        } else {
            ContentUnavailableView("Nenhum celular", systemImage: "iphone.slash",
                                   description: Text(app.modoLocal ? "Conecte um celular no Mac (USB ou Wi-Fi)." : "Conecte um celular no PC ou no Mac."))
        }
    }

    private func carregar(_ d: Dispositivo) async {
        pacote = await Adb.pacote(projeto, em: d)
        let r = await Adb.shell(d, "getprop ro.build.version.release; dumpsys battery | grep level; wm size; cmd uimode night; settings get global animator_duration_scale; settings get system show_touches; settings get system font_scale")
        let l = r.out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var i: [(String, String)] = []
        if l.count > 0 { i.append(("Android", l[0])) }
        if let b = l.first(where: { $0.hasPrefix("level") }) { i.append(("Bateria", b.replacingOccurrences(of: "level: ", with: "") + "%")) }
        if let w = l.first(where: { $0.hasPrefix("Physical size") }) { i.append(("Tela", w.replacingOccurrences(of: "Physical size: ", with: ""))) }
        info = i
        escuro = l.contains { $0.contains("Night mode: yes") }
        if let a = l.dropFirst(4).first, let v = Double(a) { animacoes = v != 0 }
        if let t = l.dropFirst(5).first { toques = t == "1" }
        if let f = l.dropFirst(6).first, let v = Double(f) { fonte = [0.85, 1.0, 1.3, 1.6].min { abs($0 - v) < abs($1 - v) } ?? 1 }
    }

    private func sh(_ d: Dispositivo, _ cmd: String, _ ok: String) async {
        let r = await Adb.shell(d, cmd)
        mensagem = r.ok ? ok : "✗ \(r.out)"
    }

    private func abrirLink(_ d: Dispositivo) async {
        let link = deepLink.trimmingCharacters(in: .whitespaces)
        guard !link.isEmpty else { return }
        var h = historico.filter { $0 != link }
        h.insert(link, at: 0)
        UserDefaults.standard.set(Array(h.prefix(8)), forKey: historicoKey)
        await sh(d, "am start -a android.intent.action.VIEW -d \(Adb.aspas(link))", "Link aberto: \(link)")
    }

    private func enviarTexto(_ d: Dispositivo) async {
        // "input text" não aceita espaço literal: usa %s
        let t = textoEnviar.replacingOccurrences(of: " ", with: "%s")
        await sh(d, "input text \(Adb.aspas(t))", "Texto enviado")
        textoEnviar = ""
    }
}

struct Grupo<C: View>: View {
    let titulo: String
    let icone: String
    var subtitulo = ""
    @ViewBuilder let conteudo: C

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icone).foregroundStyle(.secondary)
                Text(titulo).font(.headline)
                Text(subtitulo).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            conteudo
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.45)))
    }
}

struct Botao: View {
    let titulo: String
    let icone: String
    let acao: () async -> Void
    @State private var rodando = false

    init(_ titulo: String, _ icone: String, acao: @escaping () async -> Void) {
        self.titulo = titulo; self.icone = icone; self.acao = acao
    }

    var body: some View {
        Button {
            rodando = true
            Task { await acao(); rodando = false }
        } label: {
            if rodando { ProgressView().controlSize(.small) } else { Label(titulo, systemImage: icone) }
        }
    }
}

struct FlowLinks: View {
    let links: [String]
    let abrir: (String) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(links, id: \.self) { l in
                    Button { abrir(l) } label: {
                        Text(l).font(.caption).lineLimit(1).padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(.quaternary))
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Docs

struct DocsView: View {
    @ObservedObject var model: DocsModel
    @State private var editando = false
    @State private var rascunho = ""
    @State private var novoNome = ""
    @State private var criando = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Buscar nos docs (nome ou conteúdo)", text: $model.busca).textFieldStyle(.plain)
                    Button { criando = true } label: { Image(systemName: "square.and.pencil") }
                        .buttonStyle(.borderless).help("Novo documento em docs/")
                }
                .padding(8)
                Divider()
                let itens = model.filtrados
                List(selection: Binding(get: { model.selecionado }, set: { model.abrir($0); editando = false })) {
                    ForEach(Dictionary(grouping: itens, by: { $0.0.pasta }).sorted { ordem($0.key) < ordem($1.key) }, id: \.key) { pasta, docs in
                        Section(pasta) {
                            ForEach(docs, id: \.0) { d, trecho in
                                VStack(alignment: .leading, spacing: 2) {
                                    Label(d.nome, systemImage: icone(d)).font(.system(size: 12.5))
                                    if let trecho {
                                        Text(trecho).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                .tag(d)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                Text("\(itens.count) de \(model.docs.count) documentos").font(.caption2).foregroundStyle(.secondary).padding(6)
            }
            .frame(minWidth: 230, idealWidth: 270, maxWidth: 380, maxHeight: .infinity, alignment: .top)

            VStack(spacing: 0) {
                if let d = model.selecionado {
                    HStack {
                        Text(d.relativo).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        if editando {
                            Button("Cancelar") { editando = false }
                            Button("Salvar") { model.salvar(rascunho); editando = false }
                                .buttonStyle(.borderedProminent).keyboardShortcut("s")
                        } else {
                            Button { rascunho = model.conteudo; editando = true } label: { Label("Editar", systemImage: "pencil") }
                            Button { NSWorkspace.shared.open(d.url) } label: { Image(systemName: "arrow.up.forward.app") }
                                .help("Abrir no editor padrão")
                            Button { NSWorkspace.shared.activateFileViewerSelecting([d.url]) } label: { Image(systemName: "folder") }
                                .help("Mostrar no Finder")
                        }
                    }
                    .controlSize(.small)
                    .padding(8)
                    Divider()
                    if editando {
                        TextEditor(text: $rascunho)
                            .font(.system(size: 13, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(8)
                    } else {
                        MarkdownWeb(model: model, documento: d)
                    }
                } else {
                    ContentUnavailableView("Sem documentos", systemImage: "book.closed")
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Novo documento", isPresented: $criando) {
            TextField("nome-do-documento", text: $novoNome)
            Button("Criar") { if !novoNome.isEmpty { model.novo(nome: novoNome); novoNome = "" } }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("Será criado em docs/") }
    }

    private func ordem(_ pasta: String) -> String {
        pasta == "Raiz" ? "0" : pasta.hasPrefix("docs") ? "1" + pasta : pasta.hasPrefix(".claude") ? "2" + pasta : "3" + pasta
    }

    private func icone(_ d: Doc) -> String {
        let n = d.nome.lowercased()
        if n.contains("checklist") { return "checklist" }
        if n == "readme" { return "info.circle" }
        if n == "claude" { return "sparkles" }
        if d.pasta.contains("tasks") { return "square.and.pencil" }
        return "doc.text"
    }
}

struct MarkdownWeb: NSViewRepresentable {
    @ObservedObject var model: DocsModel
    let documento: Doc

    final class Coord: NSObject, WKScriptMessageHandler {
        var model: DocsModel?
        var versao = -1
        var url: URL?
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            switch m.name {
            case "check":
                guard let d = m.body as? [String: Any], let l = d["linha"] as? Int, let x = d["marcado"] as? Bool else { return }
                Task { @MainActor in self.model?.alternarCheck(linha: l, marcado: x) }
            case "link":
                guard let s = m.body as? String, let u = URL(string: s) else { return }
                Task { @MainActor in
                    if u.isFileURL, ["md", "markdown"].contains(u.pathExtension.lowercased()),
                       let m = self.model, let d = m.docs.first(where: { $0.url.standardizedFileURL == u.standardizedFileURL }) {
                        m.abrir(d)
                    } else {
                        NSWorkspace.shared.open(u)
                    }
                }
            case "scroll":
                if let y = m.body as? Double, let url { UserDefaults.standard.set(y, forKey: "scroll:" + url.path) }
            default: break
            }
        }
    }

    func makeCoordinator() -> Coord { Coord() }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        for n in ["check", "link", "scroll"] { cfg.userContentController.add(context.coordinator, name: n) }
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.setValue(false, forKey: "drawsBackground")
        return w
    }

    func updateNSView(_ w: WKWebView, context: Context) {
        let c = context.coordinator
        c.model = model
        guard c.versao != model.versao || c.url != documento.url else { return }
        c.versao = model.versao
        c.url = documento.url
        let html = Markdown.pagina(model.conteudo, arquivo: documento.url, busca: model.busca)
        w.loadHTMLString(html, baseURL: URL(fileURLWithPath: "\(Config.pasta(model.projeto))"))
    }
}

struct GravarBotao: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var gravacao: Gravacao

    var body: some View {
        if gravacao.gravando {
            Button {
                Task { if let u = await gravacao.parar() { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
            } label: {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let s = Int(Date().timeIntervalSince(gravacao.inicio ?? Date()))
                    Label(String(format: "Parar %d:%02d", s / 60, s % 60), systemImage: "stop.circle.fill")
                }
            }
            .tint(.red)
        } else {
            Button { if let d = app.alvo { gravacao.iniciar(d) } } label: { Label("Gravar", systemImage: "record.circle") }
                .help("Grava a tela do celular em MP4 (até 3 min). Entra no próximo relatório de bug.")
        }
    }
}

struct VigiaToggle: View {
    @ObservedObject var vigia: VigiaCrashes
    var body: some View {
        Toggle(isOn: $vigia.ativa) { Label("Vigiar crashes", systemImage: "shield.lefthalf.filled") }
            .toggleStyle(.checkbox)
            .help("Avisa com notificação quando o app crashar, travar (ANR) ou der erro de JavaScript")
    }
}
