import SwiftUI

private let paleta: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .red, .yellow, .indigo, .mint, .brown, .cyan]
private func corTrilho(_ i: Int) -> Color { paleta[i % paleta.count] }

// MARK: - Tela principal do Git

struct GitView: View {
    @ObservedObject var git: GitModel

    var body: some View {
        VStack(spacing: 0) {
            if !git.repo {
                ContentUnavailableView("Esta pasta não é um repositório Git", systemImage: "arrow.triangle.branch",
                                       description: Text(git.pasta))
            } else {
                CabecalhoGit(git: git)
                Divider()
                if let op = git.operacao ?? (git.conflitos.isEmpty ? nil : .merge) {
                    FaixaOperacao(git: git, op: op)
                    Divider()
                }
                Group {
                    switch git.aba {
                    case .linha: LinhaDoTempoView(git: git)
                    case .alteracoes: AlteracoesView(git: git)
                    case .branches: BranchesView(git: git)
                    case .mesclar: MesclarView(git: git)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !git.saida.isEmpty {
                    Divider()
                    HStack(alignment: .top) {
                        Text(git.saida).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(git.falhou ? .red : .secondary)
                            .lineLimit(5).textSelection(.enabled)
                        Spacer()
                        if git.falhou && AwsSSO.erroDeLogin(git.saida) {
                            Button { AwsSSO.compartilhado.tentarLogin() } label: { Label("Login AWS expirado — fazer login", systemImage: "key.icloud") }
                                .buttonStyle(.borderedProminent).tint(.orange).controlSize(.small)
                        }
                        Button { git.saida = "" } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await git.carregar() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await git.carregarEstado() }
        }
        .sheet(item: Binding(get: { git.plano }, set: { if $0 == nil { git.responder(false) } })) { p in
            PreviaComandos(git: git, plano: p)
        }
    }
}

/// Mostra exatamente os comandos git que vão rodar antes de executar
struct PreviaComandos: View {
    @ObservedObject var git: GitModel
    let plano: PlanoGit
    @AppStorage("git.leveDireto") private var leveDireto = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: plano.destrutivo ? "exclamationmark.triangle.fill" : "terminal.fill")
                    .font(.system(size: 28)).foregroundStyle(plano.destrutivo ? .red : .accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plano.titulo).font(.title3.bold())
                    Text("\(git.projeto) · \(git.pasta.replacingOccurrences(of: Config.home, with: "~"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !plano.aviso.isEmpty {
                Text(plano.aviso).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(plano.comandos.count == 1 ? "Comando que será executado:" : "Comandos que serão executados, nesta ordem (para no primeiro erro):")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(plano.comandos.enumerated()), id: \.offset) { i, c in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(plano.comandos.count > 1 ? "\(i + 1)." : "$").foregroundStyle(.secondary)
                                Text(PlanoGit.texto(c)).foregroundStyle(plano.destrutivo ? .red : .primary)
                            }
                        }
                    }
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }
            if plano.leve {
                Toggle("Não perguntar mais para ações leves (incluir/tirar do commit e fetch)", isOn: $leveDireto)
                    .toggleStyle(.checkbox).font(.caption)
            }
            HStack {
                Button { copiar(plano.comandos.map(PlanoGit.texto).joined(separator: "\n")) } label: {
                    Label("Copiar", systemImage: "doc.on.doc")
                }
                Spacer()
                Button("Cancelar") { git.responder(false) }.keyboardShortcut(.cancelAction)
                Button(plano.destrutivo ? "Executar mesmo assim" : "Executar") { git.responder(true) }
                    .buttonStyle(.borderedProminent).tint(plano.destrutivo ? .red : .accentColor)
                    .keyboardShortcut(plano.destrutivo ? nil : .defaultAction)
            }
        }
        .padding(22)
        .frame(width: 600)
    }
}

/// Todos os comandos que o app executou que alteraram o repositório
struct RegistroComandos: View {
    @ObservedObject var git: GitModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Comandos executados nesta sessão").font(.headline)
            if git.registro.isEmpty {
                Text("Nenhum ainda.").foregroundStyle(.secondary).font(.callout)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(git.registro) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Image(systemName: c.codigo == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(c.codigo == 0 ? .green : .red)
                                Text(c.comando).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                                Spacer()
                                Text(c.quando.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                            }
                            if !c.saida.isEmpty {
                                Text(c.saida).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                                    .lineLimit(4).textSelection(.enabled).padding(.leading, 22)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 560, height: 380)
    }
}

struct CabecalhoGit: View {
    @ObservedObject var git: GitModel
    @State private var verRegistro = false

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: $git.aba) {
                ForEach(GitModel.Aba.allCases) { a in
                    Label(a == .alteracoes && !git.arquivos.isEmpty ? "\(a.rawValue) (\(git.arquivos.count))" : a.rawValue,
                          systemImage: a.icone).tag(a)
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Spacer()
            HStack(spacing: 6) {
                Label(git.branch, systemImage: "arrow.triangle.branch").font(.callout.weight(.semibold)).lineLimit(1)
                    .padding(.trailing, 2)
                Button {
                    Task { await git.acao(["pull", "--ff-only"], "Baixar \(git.atras) commit(s) de \(git.upstream)",
                                          aviso: "Traz os commits do servidor para \(git.branch). Se a branch tiver divergido, o git recusa (não faz merge sozinho) — aí use Revisar e mesclar.") }
                } label: {
                    Label(git.atras > 0 ? "Baixar \(git.atras)" : "Baixar", systemImage: "arrow.down")
                }
                .tint(git.atras > 0 ? .orange : nil)
                .buttonStyle(.bordered)
                .disabled(git.upstream.isEmpty)
                .help(git.upstream.isEmpty ? "Esta branch não está no servidor" : "Pull: traz os commits novos de \(git.upstream)")
                Button {
                    Task {
                        await git.acao(git.upstream.isEmpty ? ["push", "-u", "origin", git.branch] : ["push"],
                                       git.upstream.isEmpty ? "Publicar \(git.branch) no servidor" : "Subir \(git.frente) commit(s) para \(git.upstream)",
                                       aviso: git.upstream.isEmpty ? "A branch ainda não existe no servidor — será criada em origin/\(git.branch)."
                                           : "Seus commits locais vão para o servidor e ficam visíveis para a equipe.")
                    }
                } label: {
                    Label(git.upstream.isEmpty ? "Publicar" : git.frente > 0 ? "Subir \(git.frente)" : "Subir", systemImage: "arrow.up")
                }
                .tint(git.frente > 0 || git.upstream.isEmpty ? .blue : nil)
                .buttonStyle(.bordered)
                .help("Push: envia seus commits para o servidor")
                if AwsSSO.usaCodeCommit() { BotaoAwsLogin(compacto: true) }
                Button { Task { await git.acao(["fetch", "--all", "--prune"], "Fetch — conferir novidades no servidor", aviso: "Só busca as informações do servidor; não altera seus arquivos.") } } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .help("Fetch: confere se há novidades no servidor (atualiza os números ↓ e ↑)")
            }
            if git.ocupado { ProgressView().controlSize(.small) }
            Button { verRegistro = true } label: { Image(systemName: "list.bullet.rectangle") }
                .help("Comandos git executados pelo app")
                .popover(isPresented: $verRegistro) { RegistroComandos(git: git) }
            Button { Task { await git.carregar() } } label: { Image(systemName: "arrow.clockwise") }.help("Atualizar")
        }
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

struct FaixaOperacao: View {
    @ObservedObject var git: GitModel
    let op: OperacaoGit

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(op.nome) em andamento").font(.callout.weight(.semibold))
                Text(git.conflitos.isEmpty ? "Sem conflitos pendentes — pode concluir."
                     : "\(git.conflitos.count) arquivo(s) com conflito para resolver.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if git.aba != .alteracoes && !git.conflitos.isEmpty {
                Button("Resolver conflitos") { git.aba = .alteracoes }
            }
            Button("Abortar", role: .destructive) { Task { await git.abortarOperacao() } }
            Button("Concluir") { Task { await git.concluirOperacao() } }
                .buttonStyle(.borderedProminent).disabled(!git.conflitos.isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}

// MARK: - Linha do tempo

struct LinhaDoTempoView: View {
    @ObservedObject var git: GitModel
    @State private var selecionado: GCommit?
    @State private var busca = ""
    @State private var novaBranchEm: GCommit?
    @State private var sobMouse: (c: GCommit, ponto: CGPoint)?
    @State private var mostrarCartao = false
    @State private var esperaCartao: Task<Void, Never>?

    private var indices: [Int] {
        let b = busca.trimmingCharacters(in: .whitespaces)
        return git.commits.indices.filter { i in
            b.isEmpty || git.commits[i].titulo.localizedCaseInsensitiveContains(b) || git.commits[i].autor.localizedCaseInsensitiveContains(b)
                || git.commits[i].hash.hasPrefix(b.lowercased()) || git.commits[i].refs.contains { $0.localizedCaseInsensitiveContains(b) }
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Buscar por mensagem, autor, hash ou branch", text: $busca).textFieldStyle(.plain)
                    Toggle("Todas as branches", isOn: $git.todasBranches).toggleStyle(.checkbox)
                        .onChange(of: git.todasBranches) { Task { await git.carregarLinha() } }
                }
                .controlSize(.small).padding(8)
                Divider()
                let filtrando = !busca.trimmingCharacters(in: .whitespaces).isEmpty
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(indices, id: \.self) { i in
                            let c = git.commits[i]
                            LinhaCommit(c: c, linha: i < git.linhas.count ? git.linhas[i] : nil, colunas: git.colunas,
                                        grafo: !filtrando, selecionado: selecionado?.hash == c.hash, head: git.head == c.hash)
                                .contentShape(Rectangle())
                                .onTapGesture { selecionado = c }
                                .contextMenu { menu(c) }
                                .onContinuousHover(coordinateSpace: .named("listaCommits")) { fase in
                                    switch fase {
                                    case .active(let ponto): pairar(c, ponto)
                                    case .ended: if sobMouse?.c.hash == c.hash { pairar(nil, .zero) }
                                    }
                                }
                        }
                        if git.commits.count >= git.limite {
                            Button("Carregar mais commits") {
                                git.limite += 300
                                Task { await git.carregarLinha() }
                            }
                            .padding(10)
                        }
                    }
                }
                .coordinateSpace(name: "listaCommits")
                .overlay(alignment: .topLeading) {
                    GeometryReader { geo in
                        if mostrarCartao, let h = sobMouse {
                            let largura: CGFloat = 400
                            CartaoCommit(c: h.c)
                                .frame(width: largura)
                                .offset(x: max(8, min(h.ponto.x + 16, geo.size.width - largura - 8)),
                                        y: h.ponto.y + 150 > geo.size.height ? max(8, h.ponto.y - 160) : h.ponto.y + 20)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                }
                Divider()
                Text("\(indices.count) commits" + (git.todasBranches ? " · todas as branches" : " · só \(git.branch)"))
                    .font(.caption2).foregroundStyle(.secondary).padding(5)
            }
            .frame(minWidth: 420, maxHeight: .infinity, alignment: .top)

            if let c = selecionado {
                DetalheCommit(git: git, c: c, fechar: { selecionado = nil }).id(c.hash)
                    .frame(minWidth: 380, idealWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(item: $novaBranchEm) { c in
            NomeSheet(titulo: "Nova branch a partir de \(c.curto)", placeholder: "feature/nome", botao: "Criar e trocar") { nome in
                Task { await git.acao(["switch", "-c", nome, c.hash], "Branch \(nome) criada em \(c.curto)") }
            }
        }
    }

    /// Mostra o cartão depois de o mouse parar um instante sobre o commit
    private func pairar(_ c: GCommit?, _ ponto: CGPoint) {
        guard let c else {
            esperaCartao?.cancel(); sobMouse = nil; mostrarCartao = false
            return
        }
        let mudou = sobMouse?.c.hash != c.hash
        sobMouse = (c, ponto)
        guard mudou else { return }
        mostrarCartao = false
        esperaCartao?.cancel()
        esperaCartao = Task {
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.12)) { mostrarCartao = true } }
        }
    }

    @ViewBuilder private func menu(_ c: GCommit) -> some View {
        Button("Copiar hash") { copiar(c.hash) }
        Button("Copiar mensagem") { copiar(c.titulo) }
        Divider()
        Button("Criar branch a partir daqui…") { novaBranchEm = c }
        Button("Cherry-pick em \(git.branch)…") {
            Task { await git.acao(["cherry-pick", c.hash], "Cherry-pick de \(c.curto) em \(git.branch)",
                                  aviso: "Copia as mudanças de \"\(c.titulo)\" como um commit novo em \(git.branch). O código está no painel ao lado.") }
        }.disabled(c.merge)
        Button("Reverter este commit…") {
            Task { await git.acao(["revert", "--no-edit", c.hash], "Reverter \(c.curto)",
                                  aviso: "Cria um commit novo em \(git.branch) que desfaz \"\(c.titulo)\". O histórico não é apagado.") }
        }.disabled(c.merge)
    }
}

/// "Ana Maria Souza Lima" → "Ana Lima"
func nomeCurto(_ nome: String) -> String {
    let p = nome.split(separator: " ")
    return p.count > 2 ? "\(p.first!) \(p.last!)" : nome
}

func copiar(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

struct LinhaCommit: View {
    let c: GCommit
    let linha: LinhaGrafo?
    let colunas: Int
    let grafo: Bool
    let selecionado: Bool
    let head: Bool
    private let altura: CGFloat = 26
    private let largura: CGFloat = 14

    var body: some View {
        HStack(spacing: 6) {
            if grafo, let linha {
                Canvas { ctx, size in
                    func x(_ col: Int) -> CGFloat { CGFloat(col) * largura + largura / 2 + 4 }
                    for s in linha.segs where s.x1 < colunas && s.x2 < colunas {
                        let a = CGPoint(x: x(s.x1), y: s.y1 * size.height), b = CGPoint(x: x(s.x2), y: s.y2 * size.height)
                        var p = Path()
                        p.move(to: a)
                        if s.x1 == s.x2 { p.addLine(to: b) }
                        else {
                            let meio = (a.y + b.y) / 2
                            p.addCurve(to: b, control1: CGPoint(x: a.x, y: meio), control2: CGPoint(x: b.x, y: meio))
                        }
                        ctx.stroke(p, with: .color(corTrilho(s.cor)), lineWidth: 2)
                    }
                    let col = min(linha.no, colunas - 1)
                    let r: CGFloat = head ? 6 : 4.5
                    let ret = CGRect(x: x(col) - r, y: size.height / 2 - r, width: r * 2, height: r * 2)
                    if c.merge {
                        ctx.fill(Path(ellipseIn: ret), with: .color(Color(nsColor: .windowBackgroundColor)))
                        ctx.stroke(Path(ellipseIn: ret), with: .color(corTrilho(linha.cor)), lineWidth: 2)
                    } else {
                        ctx.fill(Path(ellipseIn: ret), with: .color(corTrilho(linha.cor)))
                    }
                    if head { ctx.stroke(Path(ellipseIn: ret.insetBy(dx: -2.5, dy: -2.5)), with: .color(.primary), lineWidth: 1.5) }
                }
                .frame(width: CGFloat(colunas) * largura + 8, height: altura)
            } else {
                Spacer().frame(width: 6)
            }
            ForEach(c.refs.prefix(3), id: \.self) { r in RefChip(ref: r) }
            Text(c.titulo).font(.system(size: 12, weight: head ? .semibold : .regular)).lineLimit(1)
                .layoutPriority(1).help(c.titulo)
            Spacer(minLength: 8)
            Text(nomeCurto(c.autor)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 110, alignment: .trailing)
            Text(c.quando).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(width: 92, alignment: .trailing)
            Text(c.curto).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.purple).frame(width: 62, alignment: .leading)
        }
        .frame(height: altura)
        .padding(.trailing, 6)
        .background(selecionado ? Color.accentColor.opacity(0.22) : .clear)
    }
}

struct RefChip: View {
    let ref: String
    var inteiro = false
    var body: some View {
        let (texto, cor, icone): (String, Color, String) = {
            if ref.hasPrefix("HEAD -> ") { return (String(ref.dropFirst(8)), .green, "checkmark.circle.fill") }
            if ref == "HEAD" { return ("HEAD", .red, "location.fill") }
            if ref.hasPrefix("tag: ") { return (String(ref.dropFirst(5)), .yellow, "tag.fill") }
            if ref.contains("/") { return (ref, .blue, "cloud") }
            return (ref, .green, "arrow.triangle.branch")
        }()
        Label(texto, systemImage: icone)
            .font(.system(size: 10, weight: .semibold)).lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(cor.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(cor == .yellow ? .orange : cor)
            .frame(maxWidth: inteiro ? nil : 230, alignment: .leading)
            .fixedSize(horizontal: inteiro, vertical: false)
    }
}

struct DetalheCommit: View {
    @ObservedObject var git: GitModel
    let c: GCommit
    var fechar: (() -> Void)?
    @State private var corpo = ""
    @State private var arquivos: [ArqMudado] = []
    @State private var arquivo: ArqMudado?
    @State private var carregando = true

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text(c.titulo).font(.title3.bold()).textSelection(.enabled)
                    Spacer()
                    if let fechar {
                        Button(action: fechar) { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                            .keyboardShortcut(.cancelAction).help("Fechar o detalhe (Esc)")
                    }
                }
                if !corpo.isEmpty {
                    Text(corpo).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(8)
                }
                HStack(spacing: 14) {
                    Label("\(c.autor) <\(c.email)>", systemImage: "person").lineLimit(1)
                    Label("\(c.data) · \(c.quando)", systemImage: "clock")
                }
                .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button { copiar(c.hash) } label: { Label(c.hash.prefix(12), systemImage: "doc.on.doc") }
                        .buttonStyle(.borderless).font(.caption.monospaced())
                    if c.merge { Label("Commit de merge (\(c.pais.count) pais) — mostrando a diferença para o 1º pai", systemImage: "arrow.triangle.merge").font(.caption).foregroundStyle(.secondary) }
                    ForEach(c.refs, id: \.self) { RefChip(ref: $0) }
                }
                Divider()
                ListaArquivosMudados(arquivos: arquivos, selecionado: $arquivo, carregando: carregando)
            }
            .padding(12)
            .frame(minHeight: 180, idealHeight: 280, maxHeight: .infinity, alignment: .top)

            Group {
                if let a = arquivo {
                    DiffCarregado(chave: c.hash + a.caminho, titulo: a.caminho) { await git.diffDoCommit(c, a.caminho) }
                } else {
                    ContentUnavailableView("Escolha um arquivo para ver o código", systemImage: "doc.text.magnifyingglass")
                }
            }
            .frame(minHeight: 200, maxHeight: .infinity)
        }
        .task {
            corpo = await git.corpo(c.hash)
            arquivos = await git.arquivosDoCommit(c)
            carregando = false
            arquivo = arquivos.first
        }
    }
}

struct ListaArquivosMudados: View {
    let arquivos: [ArqMudado]
    @Binding var selecionado: ArqMudado?
    var carregando = false
    var revisados: Binding<Set<String>>?
    var conflitos: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(arquivos.count) arquivo(s)").font(.caption.weight(.semibold))
                Text("+\(arquivos.compactMap(\.add).reduce(0, +))").font(.caption.monospaced()).foregroundStyle(.green)
                Text("−\(arquivos.compactMap(\.del).reduce(0, +))").font(.caption.monospaced()).foregroundStyle(.red)
                if carregando { ProgressView().controlSize(.mini) }
            }
            List(arquivos, selection: $selecionado) { a in
                HStack(spacing: 6) {
                    if let revisados {
                        Toggle("", isOn: Binding(get: { revisados.wrappedValue.contains(a.caminho) },
                                                 set: { if $0 { revisados.wrappedValue.insert(a.caminho) } else { revisados.wrappedValue.remove(a.caminho) } }))
                            .toggleStyle(.checkbox).labelsHidden().help("Marcar como revisado")
                    }
                    if conflitos.contains(a.caminho) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Vai dar conflito")
                    }
                    Image(systemName: icone(a.caminho)).foregroundStyle(.secondary).frame(width: 14)
                    VStack(alignment: .leading, spacing: 0) {
                        Text((a.caminho as NSString).lastPathComponent).font(.system(size: 12)).lineLimit(1)
                        let dir = (a.caminho as NSString).deletingLastPathComponent
                        if !dir.isEmpty { Text(dir).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
                    }
                    Spacer()
                    if a.binario { Text("bin").font(.caption2).foregroundStyle(.secondary) }
                    else {
                        Text("+\(a.add ?? 0)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.green)
                        Text("−\(a.del ?? 0)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.red)
                    }
                }
                .tag(a)
            }
            .listStyle(.inset)
        }
    }
}

func icone(_ caminho: String) -> String {
    switch (caminho as NSString).pathExtension.lowercased() {
    case "ts", "tsx", "js", "jsx", "mjs", "cjs": "curlybraces"
    case "json": "list.bullet.indent"
    case "md", "mdx": "doc.richtext"
    case "png", "jpg", "jpeg", "gif", "webp", "svg": "photo"
    case "kt", "java", "gradle", "kts", "swift", "m", "mm", "h": "chevron.left.forwardslash.chevron.right"
    case "lock", "yaml", "yml", "plist", "xml", "properties": "gearshape"
    default: "doc"
    }
}

/// Detalhes completos de um commit ao passar o mouse
struct CartaoCommit: View {
    let c: GCommit
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(c.titulo).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if !c.refs.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(c.refs, id: \.self) { r in
                        RefChip(ref: r, inteiro: true)
                    }
                }
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Image(systemName: "person").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(c.autor).font(.system(size: 12, weight: .medium))
                        Text(c.email).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                    Text("\(c.data) · \(c.quando)").font(.system(size: 12))
                }
                GridRow {
                    Image(systemName: "number").foregroundStyle(.secondary)
                    Text(c.hash).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.purple)
                }
                if c.merge {
                    GridRow {
                        Image(systemName: "arrow.triangle.merge").foregroundStyle(.secondary)
                        Text("Commit de merge (\(c.pais.count) pais)").font(.system(size: 12))
                    }
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}

// MARK: - Diff

struct DiffCarregado: View {
    let chave: String
    let titulo: String
    let carregar: () async -> String
    @State private var linhas: [LinhaDiff] = []
    @State private var carregando = true
    @State private var tudo = false
    private let limite = 3000

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(titulo).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer()
                let a = linhas.filter { $0.tipo == .add }.count, d = linhas.filter { $0.tipo == .del }.count
                Text("+\(a)").font(.caption.monospaced()).foregroundStyle(.green)
                Text("−\(d)").font(.caption.monospaced()).foregroundStyle(.red)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.bar)
            Divider()
            if carregando {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if linhas.isEmpty {
                ContentUnavailableView("Sem diferenças de texto", systemImage: "equal.circle")
            } else {
                ScrollView([.vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(tudo ? linhas : Array(linhas.prefix(limite))) { l in LinhaDiffView(l: l) }
                        if !tudo && linhas.count > limite {
                            Button("Mostrar o resto (\(linhas.count - limite) linhas)") { tudo = true }.padding(10)
                        }
                    }
                    .textSelection(.enabled)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .task(id: chave) {
            carregando = true
            tudo = false
            let txt = await carregar()
            linhas = await Task.detached { LinhaDiff.parse(txt) }.value
            carregando = false
        }
    }
}

struct LinhaDiffView: View {
    let l: LinhaDiff
    var body: some View {
        switch l.tipo {
        case .hunk:
            Text(l.texto).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.10))
        case .info:
            Text(l.texto).font(.system(size: 11).italic()).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
        default:
            let marcador = l.texto.hasPrefix("<<<<<<< ") || l.texto.hasPrefix(">>>>>>> ") || l.texto == "=======" || l.texto.hasPrefix("||||||| ")
            HStack(alignment: .top, spacing: 0) {
                Text(l.velho.map(String.init) ?? "").frame(width: 42, alignment: .trailing)
                Text(l.novo.map(String.init) ?? "").frame(width: 42, alignment: .trailing)
                Text(l.tipo == .add ? " + " : l.tipo == .del ? " − " : "   ")
                    .foregroundStyle(l.tipo == .add ? .green : l.tipo == .del ? .red : .secondary)
                Text(l.texto.isEmpty ? " " : l.texto)
                    .foregroundStyle(marcador ? .orange : .primary)
                    .fontWeight(marcador ? .bold : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.vertical, 0.5)
            .background(l.tipo == .add ? Color.green.opacity(0.14) : l.tipo == .del ? Color.red.opacity(0.14)
                        : marcador ? Color.orange.opacity(0.18) : .clear)
        }
    }
}

// MARK: - Alterações (stage, commit, descartar, stash, conflitos)

struct AlteracoesView: View {
    @ObservedObject var git: GitModel
    @State private var selecionado: ArqStatus?
    @State private var verPreparado = false
    @State private var mensagem = ""
    @State private var guardando = false

    private var preparados: [ArqStatus] { git.arquivos.filter(\.preparado) }
    private var modificados: [ArqStatus] { git.arquivos.filter { $0.modificado && !$0.conflito } }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List {
                    if !git.conflitos.isEmpty {
                        Section("Conflitos (\(git.conflitos.count))") {
                            ForEach(git.conflitos) { a in
                                LinhaStatus(a: a, selecionado: selecionado == a && !verPreparado)
                                    .onTapGesture { selecionado = a; verPreparado = false }
                                    .contextMenu { menuConflito(a) }
                            }
                        }
                    }
                    Section {
                        ForEach(preparados) { a in
                            LinhaStatus(a: a, selecionado: selecionado == a && verPreparado, botao: ("minus.circle", "Tirar do commit", {
                                Task { await git.acao(["restore", "--staged", "--", a.caminho], "Tirado do commit: \(a.caminho)") }
                            }))
                            .onTapGesture { selecionado = a; verPreparado = true }
                        }
                    } header: {
                        HStack {
                            Text("Vão no commit (\(preparados.count))")
                            Spacer()
                            if !preparados.isEmpty {
                                Button("Tirar todos") { Task { await git.acao(["restore", "--staged", "--", "."], "Tudo tirado do commit") } }
                                    .buttonStyle(.borderless).font(.caption)
                            }
                        }
                    }
                    Section {
                        ForEach(modificados) { a in
                            LinhaStatus(a: a, selecionado: selecionado == a && !verPreparado, botao: ("plus.circle", "Incluir no commit", {
                                Task { await git.acao(["add", "--", a.caminho], "Incluído: \(a.caminho)") }
                            }))
                            .onTapGesture { selecionado = a; verPreparado = false }
                            .contextMenu {
                                Button("Abrir no editor") { abrirArquivo(a.caminho) }
                                Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: "\(git.pasta)/\(a.caminho)")]) }
                                Divider()
                                Button("Descartar alterações…", role: .destructive) {
                                    Task {
                                        if a.naoRastreado {
                                            await git.acao(["clean", "-f", "--", a.caminho], "Apagar o arquivo novo \(a.caminho)",
                                                           aviso: "O arquivo é novo (nunca foi commitado) e será apagado. Não dá para desfazer.", destrutivo: true)
                                        } else {
                                            await git.acao(["restore", "--source=HEAD", "--staged", "--worktree", "--", a.caminho], "Descartar alterações de \(a.caminho)",
                                                           aviso: "O arquivo volta a ser como está no último commit. Não dá para desfazer.", destrutivo: true)
                                        }
                                    }
                                }
                            }
                        }
                    } header: {
                        HStack {
                            Text("Alterados (\(modificados.count))")
                            Spacer()
                            if !modificados.isEmpty {
                                Button("Incluir todos") { Task { await git.acao(["add", "-A"], "Tudo incluído no commit") } }
                                    .buttonStyle(.borderless).font(.caption)
                            }
                        }
                    }
                    if !git.stashes.isEmpty {
                        Section("Guardados (stash)") {
                            ForEach(git.stashes) { s in
                                HStack {
                                    Image(systemName: "tray.full").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(s.msg).font(.system(size: 12)).lineLimit(1)
                                        Text("\(s.ref) · \(s.quando)").font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Aplicar") { Task { await git.acao(["stash", "apply", s.ref], "Stash aplicado") } }
                                    Button("Recuperar") { Task { await git.acao(["stash", "pop", s.ref], "Stash recuperado e removido da lista") } }
                                        .help("Aplica e tira da lista")
                                    Button {
                                        Task { await git.acao(["stash", "drop", s.ref], "Apagar o stash \"\(s.msg)\"",
                                                              aviso: "As alterações guardadas nele são perdidas.", destrutivo: true) }
                                    } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                                }
                                .controlSize(.mini)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                if git.arquivos.isEmpty {
                    Text("Nada alterado — árvore limpa ✓").font(.callout).foregroundStyle(.secondary).padding()
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Mensagem do commit", text: $mensagem, axis: .vertical)
                        .lineLimit(2...5).textFieldStyle(.roundedBorder)
                    HStack {
                        Menu {
                            Button("Guardar tudo (stash)…") { guardando = true }.disabled(git.arquivos.isEmpty)
                            Divider()
                            Button("Descartar TODAS as alterações…", role: .destructive) {
                                Task {
                                    await git.acao([["reset", "--hard", "HEAD"], ["clean", "-fd"]], "Descartar TODAS as \(git.arquivos.count) alterações",
                                                   aviso: "Todos os arquivos voltam ao último commit e os arquivos novos são apagados (node_modules e o que está no .gitignore ficam). Não dá para desfazer — se tiver dúvida, cancele e use \"Guardar tudo (stash)\".",
                                                   destrutivo: true)
                                }
                            }.disabled(git.arquivos.isEmpty)
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).fixedSize()
                        Spacer()
                        if preparados.isEmpty && !modificados.isEmpty {
                            Button("Incluir tudo e commitar") { Task { await commitar(tudo: true) } }
                                .disabled(mensagem.trimmingCharacters(in: .whitespaces).isEmpty || !git.conflitos.isEmpty)
                        }
                        Button("Commitar \(preparados.count) arquivo(s)") { Task { await commitar(tudo: false) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(preparados.isEmpty || mensagem.trimmingCharacters(in: .whitespaces).isEmpty || !git.conflitos.isEmpty)
                            .keyboardShortcut(.return, modifiers: .command)
                    }
                    .controlSize(.small)
                }
                .padding(10)
            }
            .frame(minWidth: 330, idealWidth: 380, maxWidth: 520, maxHeight: .infinity, alignment: .top)

            Group {
                if let a = selecionado, git.arquivos.contains(a) {
                    VStack(spacing: 0) {
                        if a.conflito { AjudaConflito(git: git, a: a) }
                        DiffCarregado(chave: "\(a.caminho)\(verPreparado)\(a.x)\(a.y)\(git.arquivos.count)",
                                      titulo: a.caminho + (verPreparado ? " (no commit)" : "")) {
                            await git.diffLocal(a, preparado: verPreparado)
                        }
                    }
                } else {
                    ContentUnavailableView("Escolha um arquivo para ver o que mudou", systemImage: "doc.text.magnifyingglass")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $guardando) {
            NomeSheet(titulo: "Guardar alterações (stash)", placeholder: "Descrição (opcional)", botao: "Guardar", opcional: true) { nome in
                Task { await git.acao(["stash", "push", "-u"] + (nome.isEmpty ? [] : ["-m", nome]), "Alterações guardadas") }
            }
        }
    }

    private func commitar(tudo: Bool) async {
        let commit = ["commit", "-m", mensagem.trimmingCharacters(in: .whitespacesAndNewlines)]
        let qtd = tudo ? modificados.count : preparados.count
        if await git.acao(tudo ? [["add", "-A"], commit] : [commit], "Commitar \(qtd) arquivo(s) em \(git.branch)",
                          aviso: "O commit fica só no seu Mac até você clicar em Push.") {
            mensagem = ""
            selecionado = nil
        }
    }

    private func abrirArquivo(_ caminho: String) {
        let url = URL(fileURLWithPath: "\(git.pasta)/\(caminho)")
        for id in ["com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode", "com.exafunction.windsurf"] {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        NSWorkspace.shared.open(url)
    }

    @ViewBuilder private func menuConflito(_ a: ArqStatus) -> some View {
        Button("Abrir no editor") { abrirArquivo(a.caminho) }
        Divider()
        Button("Ficar com a versão da branch atual (ours)") {
            Task { await git.acao([["checkout", "--ours", "--", a.caminho], ["add", "--", a.caminho]], "Resolver \(a.caminho) com a versão da branch atual", aviso: "O arquivo inteiro fica com a versão da branch atual e é marcado como resolvido. As mudanças do outro lado neste arquivo são descartadas.", destrutivo: true) }
        }
        Button("Ficar com a versão que está chegando (theirs)") {
            Task { await git.acao([["checkout", "--theirs", "--", a.caminho], ["add", "--", a.caminho]], "Resolver \(a.caminho) com a versão que está chegando", aviso: "O arquivo inteiro fica com a versão que está chegando e é marcado como resolvido. As mudanças do outro lado neste arquivo são descartadas.", destrutivo: true) }
        }
    }
}

struct AjudaConflito: View {
    @ObservedObject var git: GitModel
    let a: ArqStatus
    @State private var aviso = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Conflito: as duas branches mudaram as mesmas linhas.").font(.callout.weight(.semibold))
            Text("Entre <<<<<<< e ======= está a versão da branch atual; entre ======= e >>>>>>> a que está chegando. Edite o arquivo deixando o código certo, apague os marcadores e marque como resolvido — ou escolha uma das versões inteiras.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Abrir no editor") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "\(git.pasta)/\(a.caminho)"))
                }
                Button("Usar a atual (ours)") {
                    Task { await git.acao([["checkout", "--ours", "--", a.caminho], ["add", "--", a.caminho]], "Resolver \(a.caminho) com a versão da branch atual", aviso: "O arquivo inteiro fica com a versão da branch atual e é marcado como resolvido. As mudanças do outro lado neste arquivo são descartadas.", destrutivo: true) }
                }
                Button("Usar a que chega (theirs)") {
                    Task { await git.acao([["checkout", "--theirs", "--", a.caminho], ["add", "--", a.caminho]], "Resolver \(a.caminho) com a versão que está chegando", aviso: "O arquivo inteiro fica com a versão que está chegando e é marcado como resolvido. As mudanças do outro lado neste arquivo são descartadas.", destrutivo: true) }
                }
                Spacer()
                Button("Marcar como resolvido") {
                    if git.aindaTemMarcadores(a.caminho) { aviso = true }
                    else { Task { await git.acao(["add", "--", a.caminho], "Marcar \(a.caminho) como resolvido") } }
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.10))
        .alert("O arquivo ainda tem marcadores de conflito", isPresented: $aviso) {
            Button("Marcar mesmo assim", role: .destructive) { Task { await git.acao(["add", "--", a.caminho], "Marcar \(a.caminho) como resolvido") } }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("Ainda existem linhas <<<<<<< / >>>>>>> no arquivo. Se for commitado assim, o app não compila.") }
    }
}

struct LinhaStatus: View {
    let a: ArqStatus
    let selecionado: Bool
    var botao: (String, String, () -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Text(a.rotulo).font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(a.conflito ? .orange : a.naoRastreado ? .blue : (a.x == "D" || a.y == "D") ? .red : .orange)
                .frame(width: 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text((a.caminho as NSString).lastPathComponent).font(.system(size: 12)).lineLimit(1)
                let dir = (a.caminho as NSString).deletingLastPathComponent
                if !dir.isEmpty { Text(dir).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
            }
            Spacer()
            if let (img, ajuda, acao) = botao {
                Button(action: acao) { Image(systemName: img) }.buttonStyle(.borderless).help(ajuda)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 1)
        .listRowBackground(selecionado ? Color.accentColor.opacity(0.2) : Color.clear)
    }
}

// MARK: - Branches

struct BranchesView: View {
    @ObservedObject var git: GitModel
    @State private var filtro = ""
    @State private var renomear: BranchLocal?
    @State private var criar = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filtrar branches", text: $filtro).textFieldStyle(.plain)
                Button { criar = true } label: { Label("Nova branch", systemImage: "plus") }
            }
            .controlSize(.small).padding(8)
            Divider()
            List {
                Section("Locais (\(git.locais.count))") {
                    ForEach(git.locais.filter { filtro.isEmpty || $0.nome.localizedCaseInsensitiveContains(filtro) }) { b in
                        linhaLocal(b)
                    }
                }
                Section("No servidor (\(git.remotas.count))") {
                    ForEach(git.remotas.filter { filtro.isEmpty || $0.nome.localizedCaseInsensitiveContains(filtro) }) { r in
                        HStack(spacing: 8) {
                            Image(systemName: "cloud").foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.nome).font(.system(size: 12.5))
                                Text("\(r.autor) · \(r.quando)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            let local = String(r.nome.split(separator: "/", maxSplits: 1).last ?? "")
                            if !git.locais.contains(where: { $0.nome == local }) {
                                Button("Baixar e trocar") { trocar(r.nome) }
                            }
                            Button("Revisar e mesclar…") { abrirMerge(r.nome) }
                        }
                        .controlSize(.small)
                    }
                }
            }
            .listStyle(.inset)
        }
        .sheet(isPresented: $criar) {
            NomeSheet(titulo: "Nova branch a partir de \(git.branch)", placeholder: "feature/nome", botao: "Criar e trocar") { nome in
                Task { await git.acao(["switch", "-c", nome], "Branch \(nome) criada") }
            }
        }
        .sheet(item: $renomear) { b in
            NomeSheet(titulo: "Renomear \(b.nome)", placeholder: b.nome, botao: "Renomear", inicial: b.nome) { nome in
                Task { await git.acao(["branch", "-m", b.nome, nome], "Renomeada para \(nome)") }
            }
        }
    }

    /// Pull da branch atual; para as outras, avança a branch local sem trocar (só fast-forward)
    private func baixar(_ b: BranchLocal) async {
        let partes = b.upstream.split(separator: "/", maxSplits: 1).map(String.init)
        guard partes.count == 2 else { return }
        if b.nome == git.branch {
            await git.acao(["pull", "--ff-only"], "Baixar \(b.atras) commit(s) de \(b.upstream)",
                           aviso: "Traz os commits do servidor para \(b.nome). Se a branch tiver divergido, o git recusa — aí use Revisar e mesclar.")
        } else {
            await git.acao(["fetch", partes[0], "\(partes[1]):\(b.nome)"], "Baixar \(b.atras) commit(s) em \(b.nome)",
                           aviso: "Atualiza \(b.nome) com o que está em \(b.upstream) sem trocar de branch e sem mexer nos seus arquivos. Se \(b.nome) tiver commits que não estão no servidor, o git recusa.")
        }
    }

    private func subir(_ b: BranchLocal) async {
        let publicar = b.upstream.isEmpty || b.sumiu
        await git.acao(publicar ? ["push", "-u", "origin", b.nome] : ["push", "origin", b.nome],
                       publicar ? "Publicar \(b.nome) no servidor" : "Subir \(b.frente) commit(s) de \(b.nome)",
                       aviso: publicar ? "A branch será criada no servidor em origin/\(b.nome)." : "Os commits vão para \(b.upstream) e ficam visíveis para a equipe.")
    }

    private func trocar(_ b: String) {
        let remota = git.remotas.contains { $0.nome == b }
        let aviso = git.arquivos.isEmpty
            ? "Os arquivos mudam para os da branch. A sincronização leva ao PC e as dependências são reinstaladas no próximo Rodar, se mudarem."
            : "Há \(git.arquivos.count) arquivos alterados. O git só troca se eles não conflitarem — se precisar, guarde-os antes (Alterações → ⋯ → stash)."
        Task { await git.acao(remota ? ["switch", "--track", b] : ["switch", b], "Trocar para \(b)", aviso: aviso) }
    }

    private func apagar(_ b: String) async {
        let ok = await git.acao(["branch", "-d", b], "Apagar a branch local \(b)",
                                aviso: "Só apaga aqui no seu Mac — a branch no servidor continua. O git recusa se ela tiver commits que não estão em nenhuma outra branch.",
                                destrutivo: true)
        if !ok && git.saida.contains("not fully merged") {
            await git.acao(["branch", "-D", b], "Apagar \(b) à força",
                           aviso: "\(b) tem commits que não foram mesclados em lugar nenhum. Se ela já estiver no servidor, os commits continuam lá; senão, eles se perdem.",
                           destrutivo: true)
        }
    }

    private func abrirMerge(_ origem: String) {
        git.mergeOrigem = origem
        if git.locais.contains(where: { $0.nome == git.branch }) { git.mergeDestino = git.branch }
        git.revisao = nil
        git.aba = .mesclar
        Task { await git.revisar() }
    }

    @ViewBuilder private func linhaLocal(_ b: BranchLocal) -> some View {
        let atual = b.nome == git.branch
        HStack(spacing: 8) {
            Image(systemName: atual ? "checkmark.circle.fill" : "arrow.triangle.branch")
                .foregroundStyle(atual ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(b.nome).font(.system(size: 12.5, weight: atual ? .semibold : .regular))
                    if b.sumiu { Text("apagada no servidor").font(.caption2).foregroundStyle(.orange) }
                    else if b.upstream.isEmpty { Text("só local").font(.caption2).foregroundStyle(.secondary) }
                    if !b.upstream.isEmpty && !b.sumiu {
                        Button { Task { await baixar(b) } } label: {
                            Label(b.atras > 0 ? "Baixar \(b.atras)" : "Baixar", systemImage: "arrow.down")
                        }
                        .buttonStyle(.bordered).controlSize(.mini)
                        .tint(b.atras > 0 ? .orange : nil)
                        .disabled(b.atras == 0)
                        .help(b.atras > 0 ? "Traz \(b.atras) commit(s) de \(b.upstream)" : "Nada novo em \(b.upstream) (use ⟳ para conferir)")
                    }
                    Button { Task { await subir(b) } } label: {
                        Label(b.upstream.isEmpty || b.sumiu ? "Publicar" : b.frente > 0 ? "Subir \(b.frente)" : "Subir", systemImage: "arrow.up")
                    }
                    .buttonStyle(.bordered).controlSize(.mini)
                    .tint(b.frente > 0 || b.upstream.isEmpty || b.sumiu ? .blue : nil)
                    .disabled(!(b.upstream.isEmpty || b.sumiu) && b.frente == 0)
                    .help(b.upstream.isEmpty || b.sumiu ? "Cria a branch no servidor" : b.frente > 0 ? "Envia \(b.frente) commit(s) para \(b.upstream)" : "Nada para enviar")
                }
                Text("\(b.titulo) · \(b.autor) · \(b.quando)").font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    .help("\(b.nome)\n\(b.titulo)\n\(b.autor) · \(b.quando)" + (b.upstream.isEmpty ? "" : "\nServidor: \(b.upstream)"))
            }
            Spacer()
            if !atual {
                Button("Trocar") { trocar(b.nome) }
                Button("Revisar e mesclar em \(git.branch)…") { abrirMerge(b.nome) }
            }
            Menu {
                Button("Renomear…") { renomear = b }
                Button("Copiar nome") { copiar(b.nome) }
                Divider()
                Button("Apagar…", role: .destructive) { Task { await apagar(b.nome) } }.disabled(atual)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .controlSize(.small)
    }
}

// MARK: - Revisar e mesclar

struct MesclarView: View {
    @ObservedObject var git: GitModel
    @State private var arquivo: ArqMudado?
    @State private var verCommits = false
    @State private var modo: ModoMerge = .automatico
    @State private var mensagem = ""

    private var todasAsBranches: [String] { git.locais.map(\.nome) + git.remotas.map(\.nome) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Trazer de", selection: $git.mergeOrigem) {
                    Text("Escolha…").tag("")
                    Section("Locais") { ForEach(git.locais) { Text($0.nome).tag($0.nome) } }
                    Section("Servidor") { ForEach(git.remotas) { Text($0.nome).tag($0.nome) } }
                }
                .frame(maxWidth: 300)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Picker("para dentro de", selection: $git.mergeDestino) {
                    ForEach(git.locais) { Text($0.nome).tag($0.nome) }
                }
                .frame(maxWidth: 300)
                Button { Task { await git.revisar() } } label: { Label("Analisar", systemImage: "magnifyingglass") }
                    .buttonStyle(.borderedProminent)
                    .disabled(git.mergeOrigem.isEmpty || git.mergeOrigem == git.mergeDestino || git.ocupado)
                Spacer()
            }
            .controlSize(.small).padding(10)
            Divider()

            if let d = git.desfazerMerge {
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Merge feito: \(d.texto). Ainda não foi enviado ao servidor.").font(.callout)
                    Spacer()
                    Button("Desfazer este merge…") { Task { await git.desfazerUltimoMerge() } }
                    Button("Fechar") { git.desfazerMerge = nil }
                }
                .controlSize(.small).padding(10).background(Color.green.opacity(0.10))
                Divider()
            }

            if let r = git.revisao, r.origem == git.mergeOrigem, r.destino == git.mergeDestino {
                resumo(r)
                Divider()
                if r.commits.isEmpty {
                    ContentUnavailableView("Nada para mesclar", systemImage: "checkmark.circle",
                                           description: Text("\(r.destino) já tem tudo o que existe em \(r.origem)."))
                } else {
                    HSplitView {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("", selection: $verCommits) {
                                Text("Arquivos (\(r.arquivos.count))").tag(false)
                                Text("Commits (\(r.commits.count))").tag(true)
                            }
                            .pickerStyle(.segmented).labelsHidden()
                            if verCommits {
                                List(r.commits) { c in
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack {
                                            Text(c.curto).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.purple)
                                            Text(c.titulo).font(.system(size: 12)).lineLimit(2)
                                        }
                                        Text("\(c.autor) · \(c.data)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                                    }
                                }
                                .listStyle(.inset)
                            } else {
                                ListaArquivosMudados(arquivos: r.arquivos, selecionado: $arquivo,
                                                     revisados: $git.revisados, conflitos: r.conflitosPrevistos ?? [])
                                HStack {
                                    Button("Marcar todos como revisados") { git.revisados = Set(r.arquivos.map(\.caminho)) }
                                    Button("Próximo não revisado") {
                                        arquivo = r.arquivos.first { !git.revisados.contains($0.caminho) }
                                    }
                                    .disabled(git.revisados.count == r.arquivos.count)
                                }
                                .controlSize(.small).buttonStyle(.borderless)
                            }
                        }
                        .padding(10)
                        .frame(minWidth: 300, idealWidth: 340, maxWidth: 480, maxHeight: .infinity, alignment: .top)

                        Group {
                            if let a = arquivo {
                                VStack(spacing: 0) {
                                    DiffCarregado(chave: r.origem + r.destino + a.caminho, titulo: a.caminho) { await git.diffDoMerge(r, a.caminho) }
                                    Divider()
                                    HStack {
                                        Spacer()
                                        Button(git.revisados.contains(a.caminho) ? "Revisado ✓" : "Marcar como revisado e ir para o próximo") {
                                            git.revisados.insert(a.caminho)
                                            arquivo = r.arquivos.first { !git.revisados.contains($0.caminho) } ?? a
                                        }
                                        .disabled(git.revisados.contains(a.caminho))
                                        .keyboardShortcut(.return, modifiers: [])
                                    }
                                    .controlSize(.small).padding(8)
                                }
                            } else {
                                ContentUnavailableView("Revise cada arquivo antes de mesclar", systemImage: "eye",
                                                       description: Text("Clique num arquivo para ver exatamente o que vai mudar em \(r.destino). Enter marca como revisado e vai para o próximo."))
                            }
                        }
                        .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Divider()
                    rodape(r)
                }
            } else if git.ocupado {
                ProgressView("Analisando…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Revisar antes de mesclar", systemImage: "arrow.triangle.merge",
                                       description: Text("Escolha a branch de origem e a de destino e clique em Analisar. O app mostra os commits, cada arquivo e o código que vai entrar, avisa se vai dar conflito — e só libera o merge depois que você revisar tudo."))
            }
        }
        .onChange(of: git.revisao?.origem) { arquivo = git.revisao?.arquivos.first; mensagem = "" }
    }

    private func textoConfirmacao(_ r: RevisaoMerge) -> String {
        var t = "\(r.commits.count) commit(s) e \(r.arquivos.count) arquivo(s) entram em \(r.destino). Modo: \(modo.titulo)."
        if git.branch != r.destino { t += "\n\nO app vai trocar para \(r.destino) antes." }
        if let c = r.conflitosPrevistos, !c.isEmpty { t += "\n\n⚠ \(c.count) arquivo(s) vão dar conflito — o merge vai parar para você resolver (ou abortar)." }
        t += "\n\nNada é enviado ao servidor; dá para desfazer logo depois."
        return t
    }

    @ViewBuilder private func resumo(_ r: RevisaoMerge) -> some View {
        HStack(spacing: 18) {
            Metrica(valor: "\(r.commits.count)", rotulo: "commits", cor: .purple)
            Metrica(valor: "\(r.arquivos.count)", rotulo: "arquivos", cor: .blue)
            Metrica(valor: "+\(r.adicoes)", rotulo: "linhas", cor: .green)
            Metrica(valor: "−\(r.remocoes)", rotulo: "linhas", cor: .red)
            Divider().frame(height: 30)
            Group {
                switch r.conflitosPrevistos {
                case .some(let c) where c.isEmpty:
                    Label("Sem conflitos", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .some(let c):
                    Label("\(c.count) arquivo(s) com conflito", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .help(c.joined(separator: "\n"))
                case .none:
                    Label("Não deu para prever conflitos", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                }
            }
            .font(.callout.weight(.semibold))
            if r.fastForward {
                Label("Fast-forward possível", systemImage: "forward.fill").font(.caption).foregroundStyle(.secondary)
                    .help("\(r.destino) não tem nada que \(r.origem) não tenha: o merge só avança o ponteiro, sem commit novo.")
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder private func rodape(_ r: RevisaoMerge) -> some View {
        let faltam = r.arquivos.filter { !git.revisados.contains($0.caminho) }.count
        HStack(spacing: 10) {
            ProgressView(value: Double(r.arquivos.count - faltam), total: Double(max(r.arquivos.count, 1))).frame(width: 120)
            Text(faltam == 0 ? "Tudo revisado ✓" : "Faltam \(faltam) de \(r.arquivos.count)").font(.caption)
                .foregroundStyle(faltam == 0 ? .green : .secondary)
            Picker("Modo", selection: $modo) {
                ForEach(ModoMerge.allCases) { m in Text(m.titulo).tag(m) }
            }
            .frame(maxWidth: 300)
            if modo.usaMensagem {
                TextField(modo == .squash ? "Mensagem do commit" : "Mensagem (opcional)", text: $mensagem).textFieldStyle(.roundedBorder)
            } else { Spacer() }
            Button {
                Task { await git.executarMerge(r, modo: modo, mensagem: mensagem, aviso: textoConfirmacao(r)) }
            } label: { Label("Executar merge", systemImage: "arrow.triangle.merge") }
                .buttonStyle(.borderedProminent)
                .disabled(faltam > 0 || git.ocupado || git.operacao != nil || (modo == .soFastForward && !r.fastForward))
                .help(faltam > 0 ? "Revise todos os arquivos primeiro" : "")
        }
        .controlSize(.small).padding(10)
    }
}

struct Metrica: View {
    let valor: String
    let rotulo: String
    let cor: Color
    var body: some View {
        VStack(spacing: 0) {
            Text(valor).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(cor)
            Text(rotulo).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Sheet de nome

struct NomeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let titulo: String
    let placeholder: String
    let botao: String
    var opcional = false
    var inicial = ""
    let ok: (String) -> Void
    @State private var nome = ""

    private var limpo: String {
        opcional ? nome.trimmingCharacters(in: .whitespaces) : nome.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(titulo).font(.headline)
            TextField(placeholder, text: $nome).textFieldStyle(.roundedBorder).frame(width: 360)
                .onSubmit { if opcional || !limpo.isEmpty { ok(limpo); dismiss() } }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(botao) { ok(limpo); dismiss() }.buttonStyle(.borderedProminent)
                    .disabled(!opcional && limpo.isEmpty).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { nome = inicial }
    }
}
