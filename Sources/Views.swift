import SwiftUI

// MARK: - Janela principal

struct MainView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            if let p = app.selecionado {
                ProjetoView(projeto: p)
            } else {
                ContentUnavailableView("Escolha um app", systemImage: "square.grid.2x2")
            }
        }
        .alert("Atenção", isPresented: Binding(get: { app.erro != nil }, set: { if !$0 { app.erro = nil } })) {
            Button("OK") { app.erro = nil }
        } message: {
            Text(app.erro ?? "")
        }
        .onAppear {
            app.iniciar()
            NotaRapida.app = app
            NotaRapida.registrarAtalho()
        }
        .sheet(item: Binding(get: { app.gerarVersaoDe.map(ProjetoID.init) }, set: { app.gerarVersaoDe = $0?.id })) { p in
            GerarVersaoSheet(projeto: p.id).environmentObject(app)
        }
        .sheet(isPresented: $app.mostrarResumo) { ResumoDiaSheet() }
        .sheet(isPresented: $app.mostrarDiagnostico) { DiagnosticoSheet().environmentObject(app) }
        .sheet(isPresented: $app.mostrarPaleta) { PaletaComandos().environmentObject(app) }
        .sheet(isPresented: $app.mostrarBoasVindas) { BoasVindasSheet().environmentObject(app) }
        .sheet(isPresented: Binding(get: { app.infoMaquina != nil }, set: { if !$0 { app.infoMaquina = nil } })) {
            InfoMaquinaSheet(maquina: app.infoMaquina ?? .pc).environmentObject(app)
        }
        .sheet(isPresented: Binding(get: { app.capturaBug != nil }, set: { if !$0 { app.capturaBug = nil } })) {
            if let c = app.capturaBug { FormularioBug(captura: c).environmentObject(app) }
        }
    }
}

// MARK: - Barra lateral

struct Sidebar: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @AppStorage("sidebar.recolhidos") private var recolhidosTxt = ""
    @AppStorage("ferramentas.ocultas") private var ocultasTxt = ""
    @AppStorage("ferramentas.fixas") private var fixasTxt = ""
    @State private var verOcultas = false

    private var recolhidos: Set<String> { Set(recolhidosTxt.split(separator: ",").map(String.init)) }
    private var ocultas: Set<String> { Set(ocultasTxt.split(separator: ",").map(String.init)) }
    private var fixas: [String] { fixasTxt.split(separator: ",").map(String.init) }

    private func alternar(_ txt: inout String, _ v: String) {
        var l = txt.split(separator: ",").map(String.init)
        if let i = l.firstIndex(of: v) { l.remove(at: i) } else { l.append(v) }
        txt = l.joined(separator: ",")
    }

    /// Seleção da lista: "p|app" (o app), "t|app|ferramenta", "g|ação geral"
    private var selecao: Binding<String?> {
        Binding(get: {
            guard let p = app.selecionado else { return nil }
            return "t|\(p)|\(app.ferramenta(p).rawValue)"
        }, set: { v in
            guard let v else { return }
            let c = v.components(separatedBy: "|")
            switch c.first {
            case "p": app.selecionado = c[1]
            case "t":
                app.selecionado = c[1]
                if let f = Ferramenta(rawValue: c[2]) { app.abaFerramenta[c[1]] = f }
            case "g": abrirGeral(c[1])
            default: break
            }
        })
    }

    private func abrirGeral(_ g: String) {
        switch g {
        case "daily": app.mostrarResumo = true
        case "notas": openWindow(id: "todas-notas")
        case "diag": app.mostrarDiagnostico = true
        case "req": app.mostrarBoasVindas = true
        case "aws": if case .ok = AwsSSO.compartilhado.estado { Task { await AwsSSO.compartilhado.verificar() } } else { AwsSSO.compartilhado.tentarLogin() }
        case "versao": app.gerarVersaoDe = app.selecionado
        default: app.mostrarPaleta = true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SeletorApp().padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
            List(selection: selecao) {
                if let p = app.selecionado {
                    Section { ferramentas(p) }
                }
                Section("Geral") {
                    if AwsSSO.usaCodeCommit() { LinhaAws().tag("g|aws") }
                    linhaGeral("notas", "Todas as notas", "tray.full")
                    linhaGeral("daily", "Daily (resumo com IA)", "text.bubble")
                    linhaGeral("versao", "Gerar versão…", "shippingbox.and.arrow.backward")
                    linhaGeral("diag", "Diagnóstico", "stethoscope")
                    linhaGeral("req", "Requisitos e apps", "checklist")
                    linhaGeral("cmd", "Procurar comando  ⌘K", "command")
                }
            }
            .listStyle(.sidebar)
            Divider()
            StatusMaquinas().padding(10)
        }
    }

    private func linhaGeral(_ id: String, _ titulo: String, _ icone: String) -> some View {
        Label(titulo, systemImage: icone).font(.system(size: 12)).tag("g|\(id)")
    }

    @ViewBuilder private func ferramentas(_ p: String) -> some View {
        let fixadas = fixas.compactMap(Ferramenta.init(rawValue:)).filter { !ocultas.contains($0.rawValue) }
        if !fixadas.isEmpty {
            ForEach(fixadas) { f in linhaFerramenta(p, f, fixada: true) }
        }
        ForEach(GrupoFerramenta.allCases) { g in
            let itens = Ferramenta.allCases.filter { $0.grupo == g && !fixas.contains($0.rawValue) && (verOcultas || !ocultas.contains($0.rawValue)) }
            if !itens.isEmpty {
                let aberto = !recolhidos.contains(g.rawValue)
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { alternar(&recolhidosTxt, g.rawValue) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold))
                            .rotationEffect(.degrees(aberto ? 90 : 0))
                        Text(g.rawValue.uppercased()).font(.system(size: 10, weight: .semibold))
                        Spacer()
                        if !aberto, itens.contains(app.ferramenta(p)) {
                            Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 12)
                .selectionDisabled()
                if aberto { ForEach(itens) { f in linhaFerramenta(p, f, fixada: false) } }
            }
        }
        if !ocultas.isEmpty {
            Button(verOcultas ? "Esconder as ocultas" : "Mostrar ocultas (\(ocultas.count))") { verOcultas.toggle() }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.tertiary)
                .padding(.leading, 26)
                .selectionDisabled()
        }
    }

    private func linhaFerramenta(_ p: String, _ f: Ferramenta, fixada: Bool) -> some View {
        let oculta = ocultas.contains(f.rawValue)
        return HStack(spacing: 7) {
            Image(systemName: f.icone).frame(width: 16).foregroundStyle(.secondary)
            Text(f.rawValue).font(.system(size: 12.5))
            if fixada { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.tertiary) }
            Spacer()
            selo(p, f)
        }
        .padding(.leading, 14)
        .opacity(oculta ? 0.45 : 1)
        .tag("t|\(p)|\(f.rawValue)")
        .contextMenu {
            Button(fixas.contains(f.rawValue) ? "Desafixar" : "Fixar no topo") { alternar(&fixasTxt, f.rawValue) }
            Button(oculta ? "Mostrar de novo" : "Esconder") { alternar(&ocultasTxt, f.rawValue) }
        }
    }

    @ViewBuilder private func selo(_ p: String, _ f: Ferramenta) -> some View {
        let n: Int = {
            switch f {
            case .console: return app.sessoes(de: p).filter { app.estado($0) == .rodando || app.estado($0) == .local }.count
            case .notas: return NotasStore.de(p).abertas
            case .apks: return app.registrosApk[p]?.count ?? 0
            default: return 0
            }
        }()
        if n > 0 {
            Text("\(n)").font(.system(size: 9.5, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill((f == .console ? Color.green : .secondary).opacity(0.22)))
                .foregroundStyle(f == .console ? .green : .secondary)
        }
    }
}

/// Seletor do app: mostra o atual; ao clicar abre a lista para escolher outro
struct SeletorApp: View {
    @EnvironmentObject var app: AppState
    @State private var aberto = false

    var body: some View {
        Button { aberto.toggle() } label: {
            HStack(spacing: 10) {
                if let p = app.selecionado {
                    IconeApp(projeto: p, tamanho: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p).font(.system(size: 13.5, weight: .bold)).lineLimit(1)
                        Text(app.branches[p] ?? " ").font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    Text("Escolha um app").font(.system(size: 13, weight: .semibold))
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(aberto ? 0.9 : 0.5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Trocar de app")
        .popover(isPresented: $aberto, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Config.projetos, id: \.self) { p in
                    Button {
                        app.selecionado = p
                        aberto = false
                    } label: {
                        LinhaProjeto(projeto: p).frame(width: 250)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Mostrar no Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: Config.pasta(p))) }
                        Button("Alterar local…") { app.alterarLocal(p) }
                        Divider()
                        Button("Tirar da lista (não apaga nada)") { app.removerProjeto(p) }
                    }
                }
                Divider().padding(.vertical, 4)
                Button { aberto = false; app.adicionarProjeto() } label: { Label("Adicionar app…", systemImage: "plus") }
                    .buttonStyle(.borderless).padding(.horizontal, 6)
                Button { aberto = false; app.mostrarBoasVindas = true } label: { Label("Gerenciar apps…", systemImage: "gearshape") }
                    .buttonStyle(.borderless).padding(.horizontal, 6)
            }
            .padding(8)
        }
    }
}

/// Status compacto das máquinas no rodapé da barra lateral
struct StatusMaquinas: View {
    @EnvironmentObject var app: AppState
    @State private var mostrarRede = false

    var body: some View {
        VStack(spacing: 8) {
            if Config.temPC {
                Picker("", selection: $app.modoLocal) {
                    Text("PC").tag(false)
                    Text("Só o Mac").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .help("PC: build e Metro rodam no PC. Só o Mac: tudo roda localmente, sem o PC.")
            }
            HStack(spacing: 8) {
                if app.modoLocal {
                    Image(systemName: "laptopcomputer").foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Este Mac").font(.system(size: 11, weight: .semibold))
                        barra(app.mac.cpu, "CPU \(Int(app.mac.cpu * 100))%")
                        barra(app.mac.memTotalGB > 0 ? app.mac.memUsadaGB / app.mac.memTotalGB : 0,
                              String(format: "RAM %.1f/%.0f GB", app.mac.memUsadaGB, app.mac.memTotalGB))
                    }
                } else {
                    let pc = app.pc
                    Circle().fill(pc.online ? Color.green : pc.checado ? .red : .secondary).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(!pc.checado ? "PC: conectando…" : pc.online ? "PC online · \(pc.latenciaMs) ms" : "PC offline")
                            .font(.system(size: 11, weight: .semibold))
                        if pc.online {
                            barra(pc.cpu, "CPU \(Int(pc.cpu * 100))%")
                            barra(pc.memTotalGB > 0 ? pc.memUsadaGB / pc.memTotalGB : 0,
                                  String(format: "RAM %.1f/%.0f GB", pc.memUsadaGB, pc.memTotalGB))
                        }
                    }
                    Button { mostrarRede.toggle() } label: { Image(systemName: pc.viaTailscale ? "network.badge.shield.half.filled" : "wifi") }
                        .buttonStyle(.borderless).help("Rede do PC")
                        .popover(isPresented: $mostrarRede, arrowEdge: .trailing) { RedePopover() }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { app.infoMaquina = app.modoLocal ? .mac : .pc }
            .help("Clique para ver tudo sobre \(app.modoLocal ? "este Mac" : "o PC")")
            LinhaConsumoClaude()
        }
    }

    private func barra(_ v: Double, _ t: String) -> some View {
        HStack(spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(v > 0.85 ? Color.orange : .teal).frame(width: max(3, g.size.width * v))
                }
            }
            .frame(height: 4)
            Text(t).font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.secondary).fixedSize()
        }
    }
}

struct IconeApp: View {
    @EnvironmentObject var app: AppState
    let projeto: String
    var tamanho: CGFloat

    var body: some View {
        Group {
            if let img = app.icones[projeto] {
                Image(nsImage: img).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.fill").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: tamanho, height: tamanho)
        .clipShape(RoundedRectangle(cornerRadius: tamanho * 0.225, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: tamanho * 0.04, y: tamanho * 0.02)
    }
}

struct LinhaProjeto: View {
    @EnvironmentObject var app: AppState
    let projeto: String

    var body: some View {
        let rodando = app.sessoes(de: projeto).filter { app.estado($0) == .rodando || app.estado($0) == .local }.count
        let atual = app.selecionado == projeto
        HStack(spacing: 10) {
            IconeApp(projeto: projeto, tamanho: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(projeto).font(.system(size: 13, weight: atual ? .bold : .medium))
                    .foregroundStyle(atual ? Color.accentColor : .primary)
                if let b = app.branches[projeto] {
                    Text(b).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            NotasBadge(store: NotasStore.de(projeto))
            if rodando > 0 {
                Text("\(rodando)")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.green.opacity(0.25)))
                    .foregroundStyle(.green)
            }
            if atual { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.accentColor) }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(atual ? Color.accentColor.opacity(0.15) : .clear))
        .contentShape(Rectangle())
    }
}

// MARK: - Cartão do Mac (modo local)

struct MacCard: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer").font(.system(size: 15, weight: .semibold)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Este Mac").font(.system(size: 12, weight: .semibold))
                    Text(Config.temPC ? "Modo local — sem o PC" : "Tudo roda neste Mac").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { app.infoMaquina = .mac } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless).help("Informações e versões deste Mac")
            }
            Medidor(titulo: "CPU", valor: app.mac.cpu, texto: "\(Int(app.mac.cpu * 100))%")
            Medidor(titulo: "RAM", valor: app.mac.memTotalGB > 0 ? app.mac.memUsadaGB / app.mac.memTotalGB : 0,
                    texto: String(format: "%.1f / %.0f GB", app.mac.memUsadaGB, app.mac.memTotalGB))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
        .contentShape(Rectangle())
        .onTapGesture { app.infoMaquina = .mac }
        .help("Clique para ver tudo sobre este Mac")
    }
}

// MARK: - Cartão do PC

struct PCCard: View {
    @EnvironmentObject var app: AppState
    @State private var mostrarRede = false

    var body: some View {
        let pc = app.pc
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(pc.online ? .green : (pc.checado ? .red : .secondary))
                VStack(alignment: .leading, spacing: 0) {
                    Text("PC de build").font(.system(size: 12, weight: .semibold))
                    Text(!pc.checado ? "Conectando…" : pc.online ? "Online · \(pc.latenciaMs) ms" : "Offline")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { app.infoMaquina = .pc } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless).help("Informações e versões do PC")
                Button { mostrarRede.toggle() } label: {
                    Image(systemName: pc.viaTailscale ? "network.badge.shield.half.filled" : "wifi")
                }
                .buttonStyle(.borderless)
                .help("Rede do PC")
                .popover(isPresented: $mostrarRede, arrowEdge: .trailing) { RedePopover() }
            }
            if pc.online {
                Medidor(titulo: "CPU", valor: pc.cpu, texto: "\(Int(pc.cpu * 100))% · \(pc.nucleos) núcleos")
                Medidor(titulo: "RAM", valor: pc.memTotalGB > 0 ? pc.memUsadaGB / pc.memTotalGB : 0,
                        texto: String(format: "%.1f / %.0f GB", pc.memUsadaGB, pc.memTotalGB))
            }
            HStack(spacing: 4) {
                Image(systemName: pc.viaTailscale ? "lock.shield" : "house")
                Text(pc.viaTailscale ? "Tailscale" : "Rede local")
                Text("· \(pc.host)").foregroundStyle(.tertiary)
            }
            .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.5)))
        .contentShape(Rectangle())
        .onTapGesture { app.infoMaquina = .pc }
        .help("Clique para ver tudo sobre o PC")
    }
}

struct Medidor: View {
    let titulo: String
    let valor: Double
    let texto: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(titulo).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(texto).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(LinearGradient(colors: valor > 0.85 ? [.orange, .red] : [.teal, .blue],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, g.size.width * valor))
                        .animation(.easeOut(duration: 0.6), value: valor)
                }
            }
            .frame(height: 5)
        }
    }
}

struct RedePopover: View {
    @EnvironmentObject var app: AppState
    @State private var ip = ""
    @State private var saida = ""
    @State private var rodando = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rede do PC").font(.headline)
            Text("Endereço atual: \(app.pc.host)").font(.callout).foregroundStyle(.secondary)
            Button { rodar(["procurar"]) } label: {
                Label("Procurar o PC nesta rede", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { rodar(["tailscale"]) } label: {
                Label("Usar Tailscale (qualquer rede)", systemImage: "lock.shield")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                TextField("IP do PC (ex.: 192.168.1.50)", text: $ip)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !ip.isEmpty { rodar(["ip", ip]) } }
                Button("Usar") { rodar(["ip", ip]) }.disabled(ip.isEmpty)
            }
            if rodando { ProgressView().controlSize(.small) }
            if !saida.isEmpty {
                ScrollView {
                    Text(saida).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            }
        }
        .buttonStyle(.bordered)
        .padding(16)
        .frame(width: 360)
    }

    private func rodar(_ args: [String]) {
        rodando = true
        saida = ""
        Task {
            saida = await app.rede(args).trimmingCharacters(in: .whitespacesAndNewlines)
            rodando = false
        }
    }
}

// MARK: - Tela do projeto

struct ProjetoView: View {
    @EnvironmentObject var app: AppState
    let projeto: String

    var body: some View {
        VStack(spacing: 0) {
            Cabecalho(projeto: projeto)
                .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            Group {
                switch app.ferramenta(projeto) {
                case .console: AreaConsole(projeto: projeto)
                case .logcat: LogcatView(model: app.logcat, projeto: projeto)
                case .celular: CelularView(projeto: projeto)
                case .apks: ApksView(projeto: projeto)
                case .historico: HistoricoView(projeto: projeto)
                case .bugs: BugsView(projeto: projeto)
                case .notas: NotasView(store: NotasStore.de(projeto))
                case .entregas: EntregasView(store: EntregasStore.de(projeto)).id(projeto)
                case .atalhos: AtalhosView(store: AtalhosStore.de(projeto))
                case .versoes: VersoesView(projeto: projeto).id(projeto)
                case .git: GitView(git: app.git(projeto)).id(projeto)
                case .realm: RealmView(model: app.realm(projeto)).id(projeto)
                case .localizacao: LocalizacaoView(loc: app.localizacao)
                case .saude: SaudeView(model: app.saude(projeto)).id(projeto)
                case .docs: DocsView(model: DocsModel.de(projeto))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(projeto)
        .navigationSubtitle(app.ferramenta(projeto).rawValue)
        .inspector(isPresented: Binding(get: { app.mostrarTela || app.painelNotas },
                                        set: { if !$0 { app.mostrarTela = false; app.painelNotas = false } })) {
            Group {
                if app.painelNotas { PainelNotas(store: NotasStore.de(projeto)) }
                else { PainelTela(mirror: app.mirror) }
            }
            .inspectorColumnWidth(min: 280, ideal: 360, max: 600)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { app.gerarRelatorio(projeto) } label: {
                    if app.gerandoRelatorio { ProgressView().controlSize(.small) } else { Label("Relatório de bug", systemImage: "ladybug") }
                }
                .help("Cria na Mesa uma pasta com print, logs e contexto (e copia o texto)")
                .disabled(app.alvo == nil || app.gerandoRelatorio)
                Button { app.painelNotas.toggle() } label: {
                    Label("Notas", systemImage: app.painelNotas ? "note.text.badge.plus" : "note.text")
                }
                .help("Notas ao lado (⌘⇧N) · Nota rápida de qualquer app: ⌥⌘N")
                SeletorCelular()
                Button {
                    app.painelNotas = false
                    if app.mostrarTela { app.mostrarTela = false } else { app.abrirTela() }
                } label: {
                    Label("Tela do celular", systemImage: app.mostrarTela ? "iphone.gen3.circle.fill" : "iphone.gen3.circle")
                }
                .help("Mostrar a tela do celular dentro do app")
            }
        }
    }
}

struct Cabecalho: View {
    @EnvironmentObject var app: AppState
    let projeto: String
    @State private var apagarPasta: PastaApagavel?
    @State private var mostrarApks = false

    var body: some View {
        let sync = app.syncInfo(projeto).resumo
        HStack(alignment: .center, spacing: 10) {
            IconeApp(projeto: projeto, tamanho: 26)
            Text(projeto).font(.system(size: 15, weight: .bold, design: .rounded))
            if let b = app.branches[projeto] {
                Button { app.abaFerramenta[projeto] = .git } label: { Chip(icone: "arrow.triangle.branch", texto: b, cor: .purple) }
                    .buttonStyle(.plain).help("Abrir o Git")
            }
            if app.modoLocal {
                Chip(icone: "laptopcomputer", texto: "Mac", cor: .blue)
            } else {
                Button { app.sincronizarAgora(projeto) } label: { Chip(icone: sync.icone, texto: sync.texto, cor: sync.cor) }
                    .buttonStyle(.plain).help("Clique para sincronizar agora")
            }
            Spacer(minLength: 8)
            BotaoAcao(acao: .rodar, projeto: projeto, compacto: true)
            BotaoAcao(acao: .metro, projeto: projeto, compacto: true)
            Menu {
                Section("Ações") {
                    ForEach([Acao.logs, .tela, .debug, .release, .deps, .terminal]) { a in
                        Button { app.executar(a, projeto) } label: { Label(a.titulo, systemImage: a.icone) }
                    }
                }
                Divider()
                Button { app.gerarVersaoDe = projeto } label: { Label("Gerar versão…", systemImage: "shippingbox.and.arrow.backward") }
                Divider()
                Button { app.extra(projeto, "metro-limpo") } label: { Label("Metro limpando o cache", systemImage: "bolt.badge.clock") }
                Button { app.extra(projeto, "clean") } label: { Label("Gradle clean", systemImage: "sparkles") }
                Divider()
                Section("Apagar pastas") {
                    Button { apagarPasta = .nodeModules } label: { Label("Apagar node_modules…", systemImage: "shippingbox") }
                    ForEach([PastaApagavel.android, .ios], id: \.self) { pasta in
                        if FileManager.default.fileExists(atPath: "\(Config.pasta(projeto))/\(pasta.rawValue)") {
                            if app.pastaNoGit(projeto, pasta) {
                                Button { } label: { Label("Apagar pasta \(pasta.rawValue) (faz parte do código no Git)", systemImage: "lock") }
                                    .disabled(true)
                            } else {
                                Button { apagarPasta = pasta } label: { Label("Apagar pasta \(pasta.rawValue)…", systemImage: pasta.icone) }
                            }
                        }
                    }
                    if FileManager.default.fileExists(atPath: "\(Config.pasta(projeto))/android") {
                        Button { apagarPasta = .buildAndroid } label: { Label("Limpar build Android…", systemImage: "hammer") }
                    }
                }
                Divider()
                Button { abrirEditor() } label: { Label("Abrir no editor de código", systemImage: "chevron.left.forwardslash.chevron.right") }
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: "\(Config.pasta(projeto))")) } label: { Label("Abrir pasta no Finder", systemImage: "folder") }
                if !app.modoLocal {
                    Divider()
                    Button { app.espelhar(app.alvo) } label: { Label("Tela em janela separada (scrcpy)", systemImage: "macwindow") }
                }
            } label: {
                Label("Mais", systemImage: "ellipsis.circle")
            }
            .menuStyle(.button)
            .fixedSize()
            .sheet(item: $apagarPasta) { p in ApagarPastaSheet(projeto: projeto, pasta: p).environmentObject(app) }
        }
    }
}

extension Cabecalho {
    /// Abre a pasta do projeto no VS Code / Cursor (o que estiver instalado)
    func abrirEditor() {
        let pasta = URL(fileURLWithPath: "\(Config.pasta(projeto))")
        for id in ["com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode", "com.exafunction.windsurf"] {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.open([pasta], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        NSWorkspace.shared.open(pasta)
    }
}

struct Chip: View {
    let icone: String
    let texto: String
    let cor: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icone)
            Text(texto).lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(cor.opacity(0.15)))
        .foregroundStyle(cor)
    }
}

struct SeletorCelular: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Menu {
            if app.dispositivos.isEmpty {
                Text("Nenhum celular conectado")
            }
            ForEach(app.dispositivos) { d in
                Button {
                    app.alvoID = d.id
                } label: {
                    Label("\(d.nome) — no \(d.origem.rawValue)\(d.pronto ? "" : " (\(d.estado))")",
                          systemImage: d.id == app.alvo?.id ? "checkmark" : (d.origem == .pc ? "desktopcomputer" : "laptopcomputer"))
                }
                .disabled(!d.pronto)
            }
            let android = app.emuladores.filter { $0.plataforma == .android && (!app.modoLocal || $0.origem == .mac) }
            if !android.isEmpty {
                Section("Emuladores Android") {
                    ForEach(android) { e in
                        if e.ligado {
                            Button { app.desligarEmulador(e) } label: {
                                Label("Desligar \(e.titulo) (\(e.origem.rawValue))", systemImage: "power")
                            }
                        } else {
                            Button { app.ligarEmulador(e) } label: {
                                Label("Ligar \(e.titulo) — no \(e.origem.rawValue)\(app.ligandoEmulador.contains(e.id) ? " (ligando…)" : "")",
                                      systemImage: e.origem == .pc ? "desktopcomputer" : "laptopcomputer")
                            }
                            .disabled(app.ligandoEmulador.contains(e.id))
                        }
                    }
                }
            }
            let ios = app.emuladores.filter { $0.plataforma == .ios }
            if !ios.isEmpty, let p = app.selecionado {
                Section("Simuladores iOS (Mac)") {
                    ForEach(ios) { e in
                        Menu("\(e.ligado ? "● " : "")\(e.titulo) · \(e.versao)") {
                            if e.ligado {
                                Button { app.rodarIOS(p, e) } label: { Label("Rodar \(p) neste simulador", systemImage: "play.fill") }
                                Button { app.desligarEmulador(e) } label: { Label("Desligar", systemImage: "power") }
                            } else {
                                Button { app.ligarEmulador(e) { app.rodarIOS(p, e) } } label: {
                                    Label("Ligar e rodar \(p)", systemImage: "play.fill")
                                }
                                Button { app.ligarEmulador(e) } label: { Label("Só ligar", systemImage: "power") }
                            }
                        }
                    }
                }
            }
            if app.tunelMacAtivo {
                Divider()
                Button("Encerrar túnel do celular do Mac") { app.pararTunelMac() }
            }
        } label: {
            if let d = app.alvo {
                Label("\(d.nome) · \(d.origem.rawValue)", systemImage: "iphone.gen3")
            } else {
                Label("Sem celular", systemImage: "iphone.slash")
            }
        }
        .help("Celular usado em Rodar, Metro, Logs e Tela")
    }
}

struct BotaoAcao: View {
    @EnvironmentObject var app: AppState
    let acao: Acao
    let projeto: String
    var compacto = false
    @State private var hover = false

    private var sessao: String? {
        let alvoMac = app.alvo?.origem == .mac
        if app.modoLocal {
            switch acao {
            case .rodar: return "\(projeto)-run-local"
            case .metro: return "\(projeto)-metro-local"
            case .logs: return "\(projeto)-logs-mac"
            case .debug: return "\(projeto)-debug-local"
            case .release: return "\(projeto)-release-local"
            case .deps: return "\(projeto)-install-local"
            default: return nil
            }
        }
        switch acao {
        case .rodar: return "\(projeto)-\(alvoMac ? "android" : "run")"
        case .metro: return "\(projeto)-\(alvoMac ? "start" : "metro")"
        case .logs: return "\(projeto)-\(alvoMac ? "logs-mac" : "logs")"
        case .debug: return "\(projeto)-debug"
        case .release: return "\(projeto)-release"
        case .deps: return "\(projeto)-install"
        default: return nil
        }
    }

    var body: some View {
        let ativo = acao == .tela ? (app.mostrarTela && app.mirror.ativo)
            : sessao.map { app.estado($0) == .rodando || app.estado($0) == .local } ?? false
        let offline = !app.modoLocal && !app.pc.online && acao != .tela
        let carregando = sessao.map { app.iniciando.contains($0) } ?? false
        let semCelular = acao.usaCelular && app.alvo == nil && acao != .metro
        if compacto {
            Button {
                if ativo, let s = sessao { app.abaConsole[projeto] = s; app.abaFerramenta[projeto] = .console }
                else { app.executar(acao, projeto) }
            } label: {
                HStack(spacing: 6) {
                    if carregando { ProgressView().controlSize(.mini) }
                    else { Image(systemName: acao.icone).foregroundStyle(ativo ? .green : acao.cor) }
                    Text(acao.titulo)
                    if ativo { Circle().fill(.green).frame(width: 6, height: 6) }
                }
            }
            .controlSize(.regular)
            .disabled(offline || semCelular || carregando)
            .help(ativo ? "Rodando — clique para ver o console" : semCelular ? "Conecte um celular no PC ou no Mac" : acao.subtitulo)
        } else {
        Button {
            if ativo, let s = sessao { app.abaConsole[projeto] = s; app.abaFerramenta[projeto] = .console }
            else { app.executar(acao, projeto) }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(acao.cor.gradient)
                        .frame(width: 34, height: 34)
                    if carregando {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: acao.icone)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(acao.titulo).font(.system(size: 13, weight: .semibold))
                    Text(ativo ? "rodando — ver console" : acao.subtitulo)
                        .font(.system(size: 10.5))
                        .foregroundStyle(ativo ? .green : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if ativo {
                    Circle().fill(.green).frame(width: 7, height: 7)
                        .shadow(color: .green, radius: 3)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(hover ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quaternary.opacity(0.55)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(ativo ? acao.cor.opacity(0.6) : .clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(offline || semCelular || carregando)
        .opacity(offline || semCelular ? 0.45 : 1)
        .onHover { hover = $0 }
        .help(semCelular ? "Conecte um celular no PC ou no Mac" : acao.subtitulo)
        }
    }
}

// MARK: - Console com abas

struct AreaConsole: View {
    @EnvironmentObject var app: AppState
    let projeto: String

    var body: some View {
        let sessoes = app.sessoes(de: projeto)
        let aba = app.abaConsole[projeto].flatMap { sessoes.contains($0) || app.iniciando.contains($0) ? $0 : nil }
            ?? sessoes.first
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(Set(sessoes + (aba.map { [$0] } ?? []))).sorted(), id: \.self) { s in
                            AbaSessao(sessao: s, ativa: s == aba) { app.abaConsole[projeto] = s }
                        }
                    }
                }
                Spacer()
                if let aba { ControlesSessao(sessao: aba) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(nsColor: Paleta.fundo).opacity(0.92))
            Divider().opacity(0.3)
            if let aba {
                if let acao = AppState.partes(aba)?.1.replacingOccurrences(of: "-local", with: ""),
                   ["run", "android", "metro", "start", "metro-limpo"].contains(acao),
                   app.estado(aba) == .rodando || app.estado(aba) == .local {
                    TeclasExpo(sessao: aba)
                }
                ConsoleView(console: app.console(aba)) { app.digitar(aba, $0) }
                    .id(aba)
            } else {
                ZStack {
                    Color(nsColor: Paleta.fundo)
                    VStack(spacing: 8) {
                        Image(systemName: "apple.terminal").font(.system(size: 30))
                        Text("Nada rodando. Use os botões acima — a saída aparece aqui.")
                        Text("Dica: o atalho \"Ver terminal do Mac\" no Windows mostra a mesma sessão.")
                            .font(.caption)
                    }
                    .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .background(Color(nsColor: Paleta.fundo))
    }
}

/// Atalhos do Expo/Metro como botões (equivalem a apertar a tecla no terminal)
struct TeclasExpo: View {
    @EnvironmentObject var app: AppState
    let sessao: String
    private let teclas: [(String, String, String)] = [
        ("a", "Android", "Abrir/instalar no Android"),
        ("r", "Reload", "Recarregar o app"),
        ("m", "Menu dev", "Abrir o menu de desenvolvedor no celular"),
        ("s", "Dev build ⇄ Expo Go", "Alternar entre development build e Expo Go"),
        ("j", "Debugger", "Abrir o React Native DevTools"),
        ("c", "QR code", "Mostrar o QR code do projeto"),
        ("?", "Ajuda", "Listar todos os atalhos"),
    ]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard").foregroundStyle(.white.opacity(0.45)).font(.system(size: 11))
            ForEach(teclas, id: \.0) { t in
                Button { app.digitar(sessao, .texto(t.0)) } label: {
                    HStack(spacing: 4) {
                        Text(t.0).font(.system(size: 11, weight: .bold, design: .monospaced))
                            .frame(width: 16, height: 16)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.18)))
                        Text(t.1).font(.system(size: 11))
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06)))
                    .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help(t.2)
            }
            Spacer()
            Text("ou clique no console e digite").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color(nsColor: Paleta.fundo))
    }
}

struct AbaSessao: View {
    @EnvironmentObject var app: AppState
    let sessao: String
    let ativa: Bool
    let acao: () -> Void

    var body: some View {
        let bruto = AppState.partes(sessao)?.1 ?? sessao
        let local = bruto.hasSuffix("-local")
        let nome = bruto.replacingOccurrences(of: "-local", with: "")
        let est = app.estado(sessao)
        Button(action: acao) {
            HStack(spacing: 6) {
                Circle().fill(cor(est)).frame(width: 7, height: 7)
                Text(local ? rotulo(nome).replacingOccurrences(of: " (PC)", with: "") + " · Mac" : rotulo(nome))
                    .font(.system(size: 11.5, weight: ativa ? .semibold : .regular))
                if case let .terminou(c) = est {
                    Text(c == 0 ? "✓" : "✗ \(c)").font(.system(size: 10.5)).foregroundStyle(c == 0 ? .green : .red)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(ativa ? .white.opacity(0.12) : .clear))
            .foregroundStyle(.white.opacity(ativa ? 0.95 : 0.6))
        }
        .buttonStyle(.plain)
    }

    private func rotulo(_ a: String) -> String {
        if a.hasPrefix("cmd-") { return "⚡ " + a.dropFirst(4).replacingOccurrences(of: "-", with: " ") }
        return ["run": "Rodar (PC)", "android": "Rodar (Mac)", "metro": "Metro (PC)", "start": "Metro (Mac)",
         "logs": "Logs (PC)", "logs-mac": "Logs (Mac)", "debug": "APK Debug", "release": "APK Release",
         "install": "yarn install", "shell": "Terminal", "metro-limpo": "Metro (cache limpo)",
         "clean": "Gradle clean", "ios": "Rodar iOS"][a] ?? a
    }

    private func cor(_ e: EstadoSessao?) -> Color {
        switch e {
        case .rodando, .local: return .green
        case let .terminou(c): return c == 0 ? .blue : .red
        case nil: return app.iniciando.contains(sessao) ? .yellow : .gray
        }
    }
}

struct ControlesSessao: View {
    @EnvironmentObject var app: AppState
    let sessao: String

    var body: some View {
        let rodando = app.estado(sessao) == .rodando || app.estado(sessao) == .local
        let local = app.estadosLocais[sessao] != nil
        HStack(spacing: 2) {

            if rodando {
                BotaoIcone("stop.fill", "Parar (Ctrl+C)", cor: .red) { app.pararSessao(sessao) }
            }
            BotaoIcone("trash", "Limpar console") { app.console(sessao).limpar() }
            if !local {
                BotaoIcone("arrow.up.forward.app", "Abrir no Terminal") { app.abrirNoTerminal(sessao) }
            }
            BotaoIcone("xmark", "Fechar sessão") { app.fecharSessao(sessao) }
        }
    }
}

struct BotaoIcone: View {
    let icone: String
    let ajuda: String
    var cor: Color = .white
    let acao: () -> Void

    init(_ icone: String, _ ajuda: String, cor: Color = .white, acao: @escaping () -> Void) {
        self.icone = icone; self.ajuda = ajuda; self.cor = cor; self.acao = acao
    }

    var body: some View {
        Button(action: acao) {
            Image(systemName: icone)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(cor.opacity(0.85))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(ajuda)
    }
}

// MARK: - APKs

struct ApksPopover: View {
    @EnvironmentObject var app: AppState
    let projeto: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("APKs de \(projeto)").font(.headline)
                Spacer()
                Button("Abrir pasta") {
                    let u = URL(fileURLWithPath: "\(Config.apkDir)/\(projeto)")
                    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(u)
                }
            }
            let lista = app.apks[projeto] ?? []
            if lista.isEmpty {
                Text("Nenhum APK ainda. Use \"APK Debug\" ou \"APK Release\".")
                    .foregroundStyle(.secondary).font(.callout)
            }
            ForEach(lista.prefix(8)) { apk in
                HStack {
                    Image(systemName: "shippingbox.fill").foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text(apk.url.lastPathComponent).font(.system(size: 12, weight: .medium))
                        Text("\(apk.data.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: apk.tamanho, countStyle: .file))")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { NSWorkspace.shared.activateFileViewerSelecting([apk.url]) } label: {
                        Image(systemName: "magnifyingglass")
                    }.help("Mostrar no Finder")
                    if let d = app.alvo {
                        Button("Instalar") { app.instalarApk(apk, em: d) }
                            .help("Instalar em \(d.nome) (\(d.origem.rawValue))")
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}

// MARK: - Barra de menu

struct MenuBarView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let rodando = app.sessoesRemotas.filter { $0.value == .rodando }.keys.sorted()
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "desktopcomputer").foregroundStyle(app.pc.online ? .green : .red)
                Text(app.pc.online ? "PC online · \(app.pc.latenciaMs) ms" : "PC offline").font(.headline)
                Spacer()
            }
            if app.pc.online {
                Medidor(titulo: "CPU", valor: app.pc.cpu, texto: "\(Int(app.pc.cpu * 100))%")
                Medidor(titulo: "RAM", valor: app.pc.memTotalGB > 0 ? app.pc.memUsadaGB / app.pc.memTotalGB : 0,
                        texto: String(format: "%.1f / %.0f GB", app.pc.memUsadaGB, app.pc.memTotalGB))
            }
            Divider()
            if rodando.isEmpty {
                Text("Nada rodando").foregroundStyle(.secondary).font(.callout)
            }
            ForEach(rodando, id: \.self) { s in
                HStack {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text(s).font(.system(size: 12))
                    Spacer()
                    Button { app.pararSessao(s) } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(.borderless).help("Parar")
                }
            }
            Divider()
            NotasMenuBar()
            Divider()
            HStack {
                Button("Abrir Build Remoto") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Sair") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

struct NotasBadge: View {
    @ObservedObject var store: NotasStore
    var body: some View {
        if store.abertas > 0 {
            HStack(spacing: 2) {
                Image(systemName: "note.text").font(.system(size: 9))
                Text("\(store.abertas)").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .help("\(store.abertas) nota(s) em aberto")
        }
    }
}
