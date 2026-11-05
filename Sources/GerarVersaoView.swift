import SwiftUI

struct GerarVersaoSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var g: GeradorVersao
    @State private var checagemAberta: UUID?

    init(projeto: String) { _g = StateObject(wrappedValue: GeradorVersao(projeto: projeto)) }

    var body: some View {
        VStack(spacing: 0) {
            cabecalho
            Divider()
            Group {
                switch g.fase {
                case .configurar: configurar
                case .analisando:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(g.progresso).foregroundStyle(.secondary)
                        Text("Só leitura — nada está sendo alterado.").font(.caption).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .relatorio: relatorio
                case .executando, .concluido: execucao
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            rodape
        }
        .frame(width: 900, height: 760)
        .task { await g.carregar() }
        .interactiveDismissDisabled(g.fase == .executando || g.fase == .analisando)
    }

    // MARK: cabeçalho e rodapé

    private var cabecalho: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSImage(contentsOfFile: Config.icone(g.projeto)) ?? NSImage())
                .resizable().frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("Gerar versão — \(g.projeto)").font(.title3.bold())
                Text("Atual: \(g.versaoAtual)" + (g.codigoAtual.isEmpty ? "" : " (build \(g.codigoAtual))") + " · branch \(g.branch)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ForEach(Array(["Configurar", "Relatório", "Execução"].enumerated()), id: \.offset) { i, nome in
                let atual = i == etapa
                Text("\(i + 1). \(nome)").font(.caption.weight(atual ? .bold : .regular))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(atual ? Color.accentColor.opacity(0.2) : .clear, in: Capsule())
                    .foregroundStyle(i <= etapa ? .primary : .secondary)
            }
        }
        .padding(14)
    }

    private var etapa: Int {
        switch g.fase { case .configurar, .analisando: 0; case .relatorio: 1; case .executando, .concluido: 2 }
    }

    private var rodape: some View {
        HStack {
            if let r = g.relatorio, g.fase != .configurar {
                Button { NSWorkspace.shared.activateFileViewerSelecting([r]) } label: { Label("Relatório salvo", systemImage: "doc.text") }
                    .help(r.path)
                Button { NSWorkspace.shared.open(r) } label: { Image(systemName: "arrow.up.forward.app") }.help("Abrir o relatório")
            }
            Spacer()
            switch g.fase {
            case .configurar:
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button { Task { await g.analisar(app) } } label: { Label("Gerar relatório", systemImage: "doc.text.magnifyingglass") }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(g.versaoNova.isEmpty)
            case .analisando:
                EmptyView()
            case .relatorio:
                Button("Voltar") { g.fase = .configurar }
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button { Task { await g.executar(app) } } label: {
                    Label("Aprovar e executar \(g.passos.filter(\.ativo).count) etapa(s)", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!g.podeExecutar || g.passos.allSatisfy { !$0.ativo })
            case .executando:
                ProgressView().controlSize(.small)
                Text("Executando… não feche esta janela").font(.caption).foregroundStyle(.secondary)
            case .concluido:
                if g.apkGerado != nil {
                    Button("Ver nos APKs") { app.abaFerramenta[g.projeto] = .apks; dismiss() }
                }
                Button("Fechar") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.regular)
        .padding(12)
    }

    // MARK: 1. configurar

    private var configurar: some View {
        Form {
            Section("Versão nova") {
                Picker("Tipo", selection: $g.parte) {
                    ForEach(GeradorVersao.Parte.allCases) { p in Text(p.titulo).tag(p) }
                }
                .pickerStyle(.segmented)
                HStack {
                    TextField("Versão", text: $g.versaoNova)
                        .disabled(g.parte != .personalizada)
                        .onChange(of: g.versaoNova) { if g.parte == .personalizada { g.recalcularCodigos() } }
                    if !g.codigoAtual.isEmpty { TextField("Build Android", text: $g.codigoNovo) }
                    if !g.codigoAtualIOS.isEmpty { TextField("Build iOS", text: $g.codigoNovoIOS) }
                }
                Text("\(g.versaoAtual) → \(g.versaoNova)" + (g.codigoAtual.isEmpty ? "" : "   ·   build \(g.codigoAtual) → \(g.codigoNovo)")
                     + " (o build segue o padrão que o projeto já usa)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Changelog") {
                Picker("Commits", selection: $g.origemChangelog) {
                    ForEach(GeradorVersao.OrigemChangelog.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(g.origemChangelog == .branch
                     ? "Todos os commits desde que a branch atual saiu da de origem (develop, main ou master — detectada sozinha)."
                     : "Só os commits desde a última tag ou o último commit \"build: version\".")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Checagens antes (só leitura)") {
                Toggle("TypeScript — tsc --noEmit", isOn: $g.rodarTsc).disabled(!g.temTsconfig)
                Toggle("ESLint — sem --fix, não altera arquivos", isOn: $g.rodarEslint)
                Text("O \"yarn lint\" dos projetos usa --fix/--write e alteraria arquivos, por isso o app chama o ESLint direto.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("O que fazer") {
                Toggle("Gerar o APK release (\(app.modoLocal ? "neste Mac" : "no PC"))", isOn: $g.gerarApk)
                Toggle("Criar a tag v\(g.versaoNova)", isOn: $g.criarTag)
                Toggle("Enviar commit e tag ao servidor (push)", isOn: $g.enviar)
                Text("Depois do relatório você ainda pode pular qualquer etapa.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Label("Nada é alterado agora. O próximo passo só lê o projeto e gera um relatório com tudo o que será feito — arquivos, comandos exatos e changelog. Você revisa e aprova antes.",
                      systemImage: "lock.shield").font(.callout)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: 2. relatório

    private var relatorio: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 24) {
                    Metrica(valor: g.versaoNova, rotulo: "versão (era \(g.versaoAtual))", cor: .accentColor)
                    if !g.codigoNovo.isEmpty { Metrica(valor: g.codigoNovo, rotulo: "build Android (era \(g.codigoAtual))", cor: .purple) }
                    Metrica(valor: "\(g.arquivosAlterados.count)", rotulo: "arquivos", cor: .blue)
                    Metrica(valor: "\(g.changelog.components(separatedBy: "\n- ").count - (g.changelog.hasPrefix("- ") ? 0 : 1))", rotulo: "itens no changelog", cor: .green)
                }

                secao("Verificações") {
                    ForEach(g.itens) { it in
                        Label {
                            Text(it.texto).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: icone(it.nivel)).foregroundStyle(cor(it.nivel))
                        }
                        .font(.callout)
                    }
                    if g.itens.contains(where: { $0.nivel == .bloqueio }) && !g.itens.contains(where: { $0.nivel == .impede }) {
                        Toggle("Entendi os itens ⛔ e quero continuar mesmo assim", isOn: $g.ignorarBloqueios)
                            .toggleStyle(.checkbox).font(.callout.weight(.semibold)).padding(.top, 4)
                    }
                }

                if !g.checagens.isEmpty {
                    secao("Checagens") {
                        ForEach(g.checagens) { c in
                            DisclosureGroup(isExpanded: Binding(get: { checagemAberta == c.id }, set: { checagemAberta = $0 ? c.id : nil })) {
                                Text(c.saida).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            } label: {
                                Label("\(c.nome) — \(c.ok ? "sem erros" : "com problemas") (\(c.segundos)s)",
                                      systemImage: c.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                    .foregroundStyle(c.ok ? .green : .red)
                            }
                        }
                    }
                }

                secao("Arquivos que serão alterados") {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                        GridRow {
                            ForEach(["Arquivo", "Campo", "Atual", "Novo"], id: \.self) { Text($0).font(.caption.bold()).foregroundStyle(.secondary) }
                        }
                        ForEach(g.mudancas) { m in
                            GridRow {
                                Text("\(m.fonte.arquivo):\(m.fonte.linha)").font(.system(size: 11.5, design: .monospaced))
                                Text(m.fonte.rotulo).font(.caption)
                                Text(m.fonte.valor).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.red)
                                Text(m.novo).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(.green)
                            }
                        }
                    }
                }

                secao("Changelog — \(g.totalCommitsChangelog) commit(s) desde \(g.baseChangelog) (pode editar; vai na tag e no APK)") {
                    TextEditor(text: $g.changelog)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 150)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .onChange(of: g.changelog) { g.atualizarRelatorio() }
                }

                secao("Plano de execução — marque o que fazer") {
                    ForEach(g.passos) { p in
                        HStack(alignment: .top, spacing: 10) {
                            Toggle("", isOn: Binding(get: { p.ativo }, set: { _ in g.alternar(p.tipo) }))
                                .toggleStyle(.checkbox).labelsHidden()
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(p.id). \(p.titulo)").font(.callout.weight(.semibold))
                                    .foregroundStyle(p.ativo ? .primary : .secondary)
                                    .strikethrough(!p.ativo)
                                ForEach(p.comandos, id: \.self) { c in
                                    Text(c).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                        .textSelection(.enabled).lineLimit(2)
                                }
                            }
                            Spacer()
                            if !p.ativo { Text("pular").font(.caption.bold()).foregroundStyle(.orange) }
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(p.ativo ? 0.06 : 0.02), in: RoundedRectangle(cornerRadius: 8))
                    }
                    ForEach(g.avisosDoPlano, id: \.self) { a in
                        Label(a, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                    }
                }
            }
            .padding(18)
        }
    }

    // MARK: 3. execução

    private var execucao: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(g.passos) { p in
                    HStack(alignment: .top, spacing: 10) {
                        Group {
                            switch p.estado {
                            case .pendente: Image(systemName: "circle").foregroundStyle(.secondary)
                            case .rodando: ProgressView().controlSize(.small)
                            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            case .falhou: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            case .pulado: Image(systemName: "forward.circle").foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(p.id). \(p.titulo)" + (p.estado == .pulado ? " — pulada" : ""))
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(p.estado == .pulado ? .secondary : .primary)
                            if !p.detalhe.isEmpty {
                                Text(p.detalhe).font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(p.estado == .falhou ? .red : .secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
                if g.fase == .concluido {
                    let falhou = g.passos.contains { $0.estado == .falhou }
                    Label(falhou ? "Parou na etapa com erro. O que já foi feito está no relatório; nada foi enviado ao servidor depois do erro."
                                 : "Versão \(g.versaoNova) concluída.",
                          systemImage: falhou ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                        .font(.headline).foregroundStyle(falhou ? .orange : .green)
                        .padding(.top, 6)
                }
            }
            .padding(18)
        }
    }

    // MARK: auxiliares

    private func secao<C: View>(_ titulo: String, @ViewBuilder _ conteudo: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(titulo).font(.headline)
            conteudo()
        }
    }

    private func icone(_ n: ItemVerificacao.Nivel) -> String {
        switch n {
        case .ok: "checkmark.circle.fill"
        case .aviso: "exclamationmark.triangle.fill"
        case .bloqueio: "minus.circle.fill"
        case .impede: "xmark.octagon.fill"
        }
    }

    private func cor(_ n: ItemVerificacao.Nivel) -> Color {
        switch n { case .ok: .green; case .aviso: .orange; case .bloqueio: .red; case .impede: .red }
    }
}

struct ProjetoID: Identifiable { let id: String }
