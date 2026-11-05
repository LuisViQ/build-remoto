import SwiftUI

// MARK: - Gerar versão
//
// Fluxo completo de uma versão nova: confere o repositório, roda as checagens, sobe a versão em todos os
// lugares, monta o changelog, cria commit e tag, gera o APK release e confere a versão dentro do APK.
// Nada é alterado antes de o relatório ser gerado, salvo e aprovado.

struct ItemVerificacao: Identifiable {
    enum Nivel { case ok, aviso, bloqueio, impede }   // bloqueio: dá para ignorar conscientemente · impede: não dá
    let id = UUID()
    let nivel: Nivel
    let texto: String
}

struct Checagem: Identifiable {
    let id = UUID()
    let nome: String
    let comando: String
    let ok: Bool
    let saida: String
    let segundos: Int
}

struct MudancaVersao: Identifiable {
    let fonte: FonteVersao
    let novo: String
    var id: String { fonte.id }
}

enum TipoPasso: String, CaseIterable {
    case versao, commit, tag, prebuild, build, conferir, push
}

struct PassoRelease: Identifiable {
    enum Estado { case pendente, rodando, ok, falhou, pulado }
    let id: Int
    let tipo: TipoPasso
    let ativo: Bool
    let titulo: String
    let comandos: [String]
    var estado: Estado = .pendente
    var detalhe = ""
}

@MainActor
final class GeradorVersao: ObservableObject {
    enum Fase { case configurar, analisando, relatorio, executando, concluido }
    enum Parte: Int, CaseIterable, Identifiable {
        case patch = 2, minor = 1, major = 0, personalizada = -1
        var id: Int { rawValue }
        var titulo: String {
            switch self { case .patch: "Correção (patch)"; case .minor: "Novidades (minor)"; case .major: "Grande (major)"; case .personalizada: "Personalizada" }
        }
    }

    let projeto: String
    @Published var fase: Fase = .configurar
    @Published var progresso = ""

    // Configuração
    @Published var parte: Parte = .patch { didSet { recalcular() } }
    @Published var versaoNova = ""
    @Published var codigoNovo = ""
    @Published var codigoNovoIOS = ""
    @Published var rodarTsc = true
    @Published var rodarEslint = false
    @Published var gerarApk = true
    @Published var criarTag = true
    @Published var enviar = false
    enum OrigemChangelog: String, CaseIterable, Identifiable {
        case branch = "Todos os commits da branch", ultimaVersao = "Desde a última versão"
        var id: String { rawValue }
    }
    @Published var origemChangelog: OrigemChangelog = OrigemChangelog(rawValue: UserDefaults.standard.string(forKey: "versao.changelog") ?? "") ?? .branch {
        didSet { UserDefaults.standard.set(origemChangelog.rawValue, forKey: "versao.changelog") }
    }
    @Published var totalCommitsChangelog = 0
    @Published var ignorarBloqueios = false
    /// Etapas que o usuário escolheu pular
    @Published var pulados: Set<TipoPasso> = []

    // Resultado da análise
    @Published var fontes: [FonteVersao] = []
    @Published var versaoAtual = ""
    @Published var codigoAtual = ""
    @Published var codigoAtualIOS = ""
    @Published var cng = false
    @Published var temTsconfig = false
    @Published var branch = ""
    @Published var commitAtual = ""
    @Published var mudancas: [MudancaVersao] = []
    @Published var itens: [ItemVerificacao] = []
    @Published var checagens: [Checagem] = []
    @Published var baseChangelog = ""
    @Published var changelog = ""
    @Published var passos: [PassoRelease] = []
    @Published var relatorio: URL?
    @Published var apkGerado: URL?
    private var modoLocal = true
    private var analisadoEm = Date()

    init(projeto: String) { self.projeto = projeto }

    var pasta: String { Config.pasta(projeto) }
    var tag: String { "v\(versaoNova)" }
    var mensagemCommit: String { "build: version \(versaoNova)" }
    var podeExecutar: Bool {
        !itens.contains { $0.nivel == .impede } && (ignorarBloqueios || !itens.contains { $0.nivel == .bloqueio })
    }
    var arquivosAlterados: [String] { Array(Set(mudancas.map(\.fonte.arquivo))).sorted() }

    private func git(_ args: [String]) async -> GitRes { await GitCLI.run(pasta, args) }
    private func linha(_ r: GitRes) -> String { r.out.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: leitura inicial (só leitura)

    func carregar() async {
        let p = projeto
        let (f, g) = await Task.detached { (Versoes.ler(p), Versoes.nativoGerado(p)) }.value
        fontes = f
        cng = g
        temTsconfig = FileManager.default.fileExists(atPath: "\(pasta)/tsconfig.json")
        rodarTsc = temTsconfig
        versaoAtual = principal(f.filter { $0.tipo == .nome }) ?? "0.0.0"
        codigoAtual = principal(f.filter { $0.grupo == "Build Android" }) ?? ""
        codigoAtualIOS = principal(f.filter { $0.grupo == "Build iOS" }) ?? ""
        branch = linha(await git(["branch", "--show-current"]))
        recalcular()
    }

    private func principal(_ fs: [FonteVersao]) -> String? {
        let v = fs.filter { $0.observacao.isEmpty }.map(\.valor)
        return Dictionary(grouping: v, by: { $0 }).max { a, b in
            a.value.count < b.value.count || (a.value.count == b.value.count && (Int(a.key) ?? 0) < (Int(b.key) ?? 0))
        }?.key
    }

    func recalcular() {
        guard !versaoAtual.isEmpty else { return }
        if parte != .personalizada { versaoNova = Versoes.incrementar(versaoAtual, parte.rawValue) }
        recalcularCodigos()
    }

    func recalcularCodigos() {
        if let c = Int(codigoAtual) { codigoNovo = String(Versoes.sugerirCodigo(versaoAtual: versaoAtual, codigoAtual: c, novaVersao: versaoNova)) }
        if let c = Int(codigoAtualIOS) { codigoNovoIOS = String(Versoes.sugerirCodigo(versaoAtual: versaoAtual, codigoAtual: c, novaVersao: versaoNova)) }
    }

    // MARK: análise → relatório

    func analisar(_ app: AppState) async {
        fase = .analisando
        analisadoEm = Date()
        modoLocal = app.modoLocal
        var it: [ItemVerificacao] = []
        func add(_ n: ItemVerificacao.Nivel, _ t: String) { it.append(ItemVerificacao(nivel: n, texto: t)) }

        progresso = "Lendo as versões…"
        await carregarFontesDeNovo()
        let v = versaoNova.trimmingCharacters(in: .whitespaces)
        if v.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) == nil { add(.impede, "Versão \"\(v)\" inválida — use o formato 1.2.3.") }
        if compararVersoes(v, versaoAtual) <= 0 { add(.bloqueio, "A versão nova (\(v)) não é maior que a atual (\(versaoAtual)).") }
        if let a = Int(codigoAtual), let n = Int(codigoNovo), n <= a { add(.impede, "O build Android novo (\(n)) precisa ser maior que o atual (\(a)) — a Play Store e o Android recusam código menor ou igual.") }
        mudancas = planejarMudancas()
        if mudancas.isEmpty { add(.impede, "Nenhum arquivo de versão para alterar.") }
        let divergentes = Set(fontes.filter { $0.tipo == .nome && $0.observacao.isEmpty }.map(\.valor))
        if divergentes.count > 1 { add(.aviso, "As versões estavam divergentes entre os arquivos (\(divergentes.sorted().joined(separator: ", "))) — todas ficarão \(v).") }

        progresso = "Conferindo o Git…"
        branch = linha(await git(["branch", "--show-current"]))
        commitAtual = linha(await git(["rev-parse", "--short", "HEAD"]))
        if branch.isEmpty { add(.impede, "O repositório está sem branch (HEAD solto). Troque para uma branch antes.") }
        else { add(.ok, "Branch \(branch) (commit \(commitAtual)).") }
        let status = ArqStatus.parse((await git(["status", "--porcelain=v1", "-z", "-uall"])).out)
        if status.isEmpty { add(.ok, "Nenhuma alteração sem commit.") }
        else {
            add(.bloqueio, "\(status.count) arquivo(s) alterados sem commit — eles entrariam no APK, mas não no commit da versão: "
                + status.prefix(6).map(\.caminho).joined(separator: ", ") + (status.count > 6 ? "…" : "")
                + ". Commite ou guarde (stash) antes.")
        }
        for op in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD"] where (await git(["rev-parse", "-q", "--verify", op])).ok {
            add(.impede, "Há um merge/cherry-pick em andamento. Conclua ou aborte na aba Git.")
        }
        let up = await git(["rev-parse", "--abbrev-ref", "@{upstream}"])
        if up.ok {
            let ab = linha(await git(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"])).split(whereSeparator: \.isWhitespace)
            let atras = ab.count == 2 ? Int(ab[1]) ?? 0 : 0
            let frente = ab.count == 2 ? Int(ab[0]) ?? 0 : 0
            if atras > 0 { add(.bloqueio, "\(linha(up)) tem \(atras) commit(s) que você não tem. Baixe antes para a versão incluir tudo.") }
            else { add(.ok, "Em dia com \(linha(up)) (pela última consulta ao servidor)." + (frente > 0 ? " Você tem \(frente) commit(s) ainda não enviados." : "")) }
        } else {
            add(.aviso, "A branch \(branch) não está no servidor." + (enviar ? " O push vai criá-la." : ""))
        }
        if criarTag, ativo(.tag), (await git(["rev-parse", "-q", "--verify", "refs/tags/\(tag)"])).ok {
            add(.impede, "A tag \(tag) já existe. Escolha outra versão ou desmarque \"Criar tag\".")
        }

        progresso = "Montando o changelog…"
        await montarChangelog()

        progresso = "Conferindo o ambiente de build…"
        if gerarApk {
            let sessao = modoLocal ? "\(projeto)-release-local" : "\(projeto)-release"
            if let e = app.estado(sessao), e == .rodando || e == .local { add(.impede, "Já existe um build release rodando para este app.") }
            if modoLocal {
                if !cng && !FileManager.default.fileExists(atPath: "\(pasta)/android") { add(.impede, "Pasta android não encontrada neste Mac.") }
                else { add(.ok, "Build no Mac (modo só o Mac).") }
            } else {
                if app.pc.online { add(.ok, "Build no PC (online).") }
                else { add(.impede, "O PC está offline — mude para \"Só o Mac\" ou conecte o PC.") }
            }
            if cng { add(.ok, "Projeto Expo com pasta android gerada: o plano roda o prebuild para a versão nova chegar aos arquivos nativos.") }
            let gradle = (try? String(contentsOfFile: "\(pasta)/android/app/build.gradle", encoding: .utf8)) ?? ""
            if let r = gradle.range(of: "release {"), gradle[r.upperBound...].prefix(400).contains("signingConfig signingConfigs.debug") {
                add(.aviso, "O build release está configurado para assinar com a chave de DEBUG (android/app/build.gradle). Serve para teste, mas não para a Play Store.")
            }
        }

        checagens = []
        if rodarTsc && temTsconfig {
            progresso = "Rodando TypeScript (tsc --noEmit)… pode levar um minuto"
            checagens.append(await checar("TypeScript", "npx tsc --noEmit"))
        }
        if rodarEslint {
            progresso = "Rodando ESLint (sem --fix)…"
            checagens.append(await checar("ESLint", "npx eslint . --no-fix"))
        }
        for c in checagens {
            if c.ok { add(.ok, "\(c.nome) sem erros (\(c.segundos)s).") }
            else { add(.bloqueio, "\(c.nome) encontrou problemas — veja a saída na seção Checagens.") }
        }

        itens = it
        passos = montarPlano()
        ignorarBloqueios = false
        relatorio = salvarRelatorio()
        progresso = ""
        fase = .relatorio
    }

    private func carregarFontesDeNovo() async {
        let p = projeto
        let (f, g) = await Task.detached { (Versoes.ler(p), Versoes.nativoGerado(p)) }.value
        fontes = f
        cng = g
    }

    private func compararVersoes(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? -1 : 1 }
        }
        return 0
    }

    private func planejarMudancas() -> [MudancaVersao] {
        fontes.compactMap { f in
            guard f.observacao.isEmpty else { return nil }
            let novo: String?
            switch f.tipo {
            case .nome: novo = versaoNova
            case .codigo: novo = f.plataforma == .ios ? (codigoNovoIOS.isEmpty ? nil : codigoNovoIOS) : (codigoNovo.isEmpty ? nil : codigoNovo)
            case .schema, .runtime: novo = nil
            }
            guard let novo, novo != f.valor else { return nil }
            return MudancaVersao(fonte: f, novo: novo)
        }
    }

    /// Commits desde a última versão (a tag ou o commit "build: version" mais recente)
    /// Branch de onde a atual saiu (develop/main/master) e o commit em que se separaram
    private func baseDaBranch() async -> (nome: String, commit: String)? {
        let head = linha(await git(["rev-parse", "HEAD"]))
        var melhor: (String, String, Int)?
        for c in ["origin/develop", "develop", "origin/main", "main", "origin/master", "master"] {
            if c.replacingOccurrences(of: "origin/", with: "") == branch { continue }
            guard (await git(["rev-parse", "-q", "--verify", c])).ok else { continue }
            let mb = linha(await git(["merge-base", "HEAD", c]))
            guard !mb.isEmpty, mb != head else { continue }
            let d = Int(linha(await git(["log", "-1", "--format=%ct", mb]))) ?? 0
            if melhor == nil || d > melhor!.2 { melhor = (c, mb, d) }
        }
        return melhor.map { ($0.0, $0.1) }
    }

    private func montarChangelog() async {
        var base: (hash: String, desc: String, data: Int)?
        if origemChangelog == .branch, let b = await baseDaBranch() {
            base = (b.commit, "a saída de \(branch) de \(b.nome) (\(b.commit.prefix(8)))", 0)
        } else {
        let t = await git(["describe", "--tags", "--abbrev=0"])
        if t.ok {
            let nome = linha(t)
            let d = Int(linha(await git(["log", "-1", "--format=%ct", nome]))) ?? 0
            base = (nome, "tag \(nome)", d)
        }
        let vc = linha(await git(["log", "-1", "--format=%H%x1f%ct%x1f%s", "-E",
                                  "--grep=^(build|chore)(\\(.+\\))?: *(version|new build number|release)", "-i"]))
        let p = vc.components(separatedBy: "\u{1f}")
        if p.count == 3, let d = Int(p[1]), d > (base?.data ?? 0) { base = (p[0], "commit \"\(p[2])\" (\(p[0].prefix(8)))", d) }
        }
        let faixa = base.map { "\($0.hash)..HEAD" } ?? "HEAD"
        baseChangelog = base?.desc ?? "início do repositório (últimos 40 commits)"
        var args = ["log", "--no-merges", "--format=%s%x1f%an%x1f%h"]
        if base == nil { args += ["-n", "40"] }
        let r = await git(args + [faixa])
        totalCommitsChangelog = r.out.split(separator: "\n").count
        var grupos: [String: [String]] = [:]
        let titulos = ["feat": "Novidades", "fix": "Correções", "perf": "Melhorias de desempenho", "refactor": "Melhorias internas"]
        for l in r.out.split(separator: "\n") {
            let c = l.components(separatedBy: "\u{1f}")
            guard c.count == 3 else { continue }
            var msg = c[0], tipo = "outros"
            if let m = msg.range(of: #"^(\w+)(\([^)]*\))?!?:\s*"#, options: .regularExpression) {
                tipo = String(msg[m].prefix { $0.isLetter }).lowercased()
                msg = String(msg[m.upperBound...])
            }
            if tipo == "build" && msg.lowercased().hasPrefix("version") { continue }
            msg = msg.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            guard !msg.isEmpty else { continue }
            grupos[titulos[tipo] ?? "Outros", default: []].append("- \(msg.prefix(1).uppercased() + msg.dropFirst()) (\(c[2]))")
        }
        let ordem = ["Novidades", "Correções", "Melhorias de desempenho", "Melhorias internas", "Outros"]
        changelog = ordem.compactMap { g in grupos[g].map { "### \(g)\n" + $0.joined(separator: "\n") } }.joined(separator: "\n\n")
        if changelog.isEmpty { changelog = "- Sem commits novos desde \(baseChangelog)." }
    }

    /// Checagem só de leitura (nada de --fix/--write)
    private func checar(_ nome: String, _ cmd: String) async -> Checagem {
        let inicio = Date()
        let r = await Shell.run("zsh", ["-lc", "cd \(Adb.aspas(pasta)) && \(Shell.prepararNode)\n\(cmd) 2>&1 | tail -n 80"],
                                env: ["CI": "1", "FORCE_COLOR": "0"])
        // o tail esconde o código de saída; o tsc e o eslint imprimem erros no formato "error"
        let saida = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        let falhou = saida.range(of: #"error TS\d+|\d+ errors?\b|✖ \d+ problems? \(\d+ error"#, options: .regularExpression) != nil
            || saida.contains("command not found")
        return Checagem(nome: nome, comando: cmd, ok: !falhou, saida: saida.isEmpty ? "(sem saída)" : saida,
                        segundos: Int(Date().timeIntervalSince(inicio)))
    }

    // MARK: plano

    private var depsMac: String {
        #"h=$(cat package.json yarn.lock 2>/dev/null | shasum); [ "$(cat node_modules/.deps-hash-mac 2>/dev/null)" = "$h" ] || { echo "→ Dependências mudaram, rodando yarn install..."; yarn install --frozen-lockfile && echo "$h" > node_modules/.deps-hash-mac; }"#
    }
    private var depsPC: String {
        #"h=$(cat package.json yarn.lock | sha1sum); [ "$(cat node_modules/.deps-hash 2>/dev/null)" = "$h" ] || { echo "→ Dependências mudaram, rodando yarn install..."; yarn install --frozen-lockfile && echo "$h" > node_modules/.deps-hash; }"#
    }
    private let prebuild = "CI=1 npx expo prebuild --platform android --no-install"

    private var tagMensagem: String { "Versão \(versaoNova) (build \(codigoNovo))\n\n\(changelog)" }

    func ativo(_ t: TipoPasso) -> Bool { !pulados.contains(t) }

    func alternar(_ t: TipoPasso) {
        if pulados.contains(t) { pulados.remove(t) } else { pulados.insert(t) }
        // dependências: sem build não há o que conferir; sem arquivos alterados não há commit
        if t == .build && pulados.contains(.build) { pulados.insert(.conferir) }
        if t == .versao && pulados.contains(.versao) { pulados.insert(.commit) }
        if t == .conferir && !pulados.contains(.conferir) { pulados.remove(.build) }
        if t == .commit && !pulados.contains(.commit) { pulados.remove(.versao) }
        passos = montarPlano()
        atualizarRelatorio()
    }

    func montarPlano() -> [PassoRelease] {
        var ps: [PassoRelease] = []
        func add(_ t: TipoPasso, _ titulo: String, _ c: [String]) {
            ps.append(PassoRelease(id: ps.count + 1, tipo: t, ativo: ativo(t), titulo: titulo, comandos: c))
        }
        add(.versao, "Atualizar a versão em \(arquivosAlterados.count) arquivo(s)",
            mudancas.map { "\($0.fonte.arquivo):\($0.fonte.linha)  \($0.fonte.rotulo)  \($0.fonte.valor) → \($0.novo)" })
        add(.commit, "Commit da versão", [PlanoGit.texto(["add", "--"] + arquivosAlterados), PlanoGit.texto(["commit", "-m", mensagemCommit])])
        if criarTag {
            add(.tag, "Criar a tag \(tag)" + (ativo(.commit) ? " no commit da versão" : " no commit atual"),
                [PlanoGit.texto(["tag", "-a", tag, "-m", "Versão \(versaoNova) (build \(codigoNovo)) + changelog"])])
        }
        if gerarApk {
            if cng {
                add(.prebuild, "Atualizar a pasta android gerada (prebuild) — \(modoLocal ? "no Mac" : "no PC")",
                    modoLocal ? ["yarn install (se as dependências mudaram)", prebuild]
                              : ["mutagen sync flush", "ssh pc-build: cd ~/apps/\(projeto) && yarn install (se mudou) && \(prebuild)"])
            }
            add(.build, "Gerar o APK release — \(modoLocal ? "no Mac" : "no PC")",
                modoLocal ? ["cd android && ./gradlew --console=plain assembleRelease"] : ["build-remoto \(projeto) release"])
            add(.conferir, "Conferir a versão dentro do APK e guardar o changelog junto dele",
                ["aapt dump badging <apk>  → esperado versionName \(versaoNova), versionCode \(codigoNovo)"])
        }
        if enviar {
            var c = [PlanoGit.texto(["push"])]
            if criarTag { c.append(PlanoGit.texto(["push", "origin", tag])) }
            add(.push, "Enviar ao servidor", c)
        }
        return ps
    }

    /// Avisos que dependem das etapas escolhidas
    var avisosDoPlano: [String] {
        var a: [String] = []
        if gerarApk && ativo(.build) && !ativo(.versao) { a.append("A versão nos arquivos não será alterada: o APK sai com a versão atual (\(versaoAtual)).") }
        if ativo(.versao) && !ativo(.commit) { a.append("Os arquivos de versão ficam alterados sem commit — commite depois pela aba Git.") }
        if cng && ativo(.build) && pulados.contains(.prebuild) { a.append("Sem o prebuild, a pasta android gerada pode continuar com a versão antiga.") }
        if criarTag && ativo(.tag) && !ativo(.commit) { a.append("A tag \(tag) vai marcar o commit atual (\(commitAtual)), sem o commit da versão.") }
        if passos.allSatisfy({ !$0.ativo }) { a.append("Todas as etapas estão puladas — nada será feito.") }
        return a
    }

    // MARK: execução

    func executar(_ app: AppState) async {
        fase = .executando
        let gitModel = app.git(projeto)
        var inicioBuild = Date()
        defer { fase = .concluido; atualizarRelatorio() }

        for i in passos.indices {
            guard passos[i].ativo else { passos[i].estado = .pulado; continue }
            passos[i].estado = .rodando
            let erro = await rodarPasso(passos[i].tipo, app: app, git: gitModel, inicioBuild: &inicioBuild) { [weak self] d in
                self?.passos[i].detalhe = d
            }
            if let erro {
                passos[i].estado = .falhou
                passos[i].detalhe = erro
                for k in (i + 1)..<passos.count { passos[k].estado = .pulado }
                Shell.notificar(projeto, "Gerar versão \(versaoNova) falhou", som: "Basso")
                return
            }
            passos[i].estado = .ok
        }
        Shell.notificar(projeto, "Versão \(versaoNova) pronta ✓", som: "Glass")
    }

    /// Roda uma etapa; devolve a mensagem de erro (nil = deu certo)
    private func rodarPasso(_ tipo: TipoPasso, app: AppState, git gitModel: GitModel, inicioBuild: inout Date,
                            detalhe: (String) -> Void) async -> String? {
        switch tipo {
        case .versao:
            let p = projeto, ms = mudancas.map { ($0.fonte, $0.novo) }
            let alterados = await Task.detached { Versoes.aplicar(p, ms) }.value
            await carregarFontesDeNovo()
            let errados = mudancas.filter { m in !fontes.contains { $0.arquivo == m.fonte.arquivo && $0.linha == m.fonte.linha && $0.valor == m.novo } }
            if !errados.isEmpty {
                return "Não consegui conferir: " + errados.map { "\($0.fonte.arquivo):\($0.fonte.linha)" }.joined(separator: ", ") + ". Confira na aba Versões / Git."
            }
            detalhe("Alterados: " + alterados.joined(separator: ", "))

        case .commit:
            let r = await gitModel.rodar([["add", "--"] + arquivosAlterados, ["commit", "-m", mensagemCommit]])
            await gitModel.carregar()
            guard r.ok else { return r.msg }
            commitAtual = linha(await git(["rev-parse", "--short", "HEAD"]))
            detalhe("Commit \(commitAtual)")

        case .tag:
            let r = await gitModel.rodar([["tag", "-a", tag, "-m", tagMensagem]])
            await gitModel.carregar()
            guard r.ok else { return r.msg }
            detalhe("Tag \(tag) em \(linha(await git(["rev-parse", "--short", "HEAD"])))")

        case .prebuild:
            detalhe("Rodando o prebuild…")
            let r: ShellResult
            if modoLocal {
                r = await Shell.run("zsh", ["-lc", "cd \(Adb.aspas(pasta)) && \(Shell.prepararNode)\n\(depsMac) && \(prebuild)"])
            } else {
                _ = await Shell.run("mutagen", ["sync", "flush", projeto.lowercased().replacingOccurrences(of: "_", with: "-")])
                r = await Shell.noPC("bash -l <<'FIM'\ncd ~/apps/\(projeto) && \(depsPC) && \(prebuild)\nFIM")
            }
            let fim = r.out.split(separator: "\n").suffix(6).joined(separator: "\n")
            guard r.ok else { return "O prebuild falhou:\n" + fim }
            detalhe(fim)

        case .build:
            detalhe("Acompanhe no Console. Isso leva alguns minutos.")
            inicioBuild = Date()
            let sessao = modoLocal ? "\(projeto)-release-local" : "\(projeto)-release"
            let antes = app.estado(sessao)
            app.executar(.release, projeto)
            app.abaFerramenta[projeto] = .console
            guard let codigo = await esperarBuild(app, sessao, antes: antes) else { return "Não consegui acompanhar o build (sessão \(sessao))." }
            guard codigo == 0 else { return "O build terminou com erro (código \(codigo)). O log fica no Histórico." }
            let s = Int(Date().timeIntervalSince(inicioBuild))
            detalhe("Build concluído em \(s / 60)min \(s % 60)s")

        case .conferir:
            detalhe("Esperando o APK…")
            var apk: ApkRegistro?
            for _ in 0..<90 {
                apk = ApkArquivo.listar(projeto).first { ($0.ctx?.inicio ?? .distantPast) >= inicioBuild.addingTimeInterval(-5) && $0.ctx?.tipo == "release" }
                if apk != nil { break }
                try? await Task.sleep(for: .seconds(2))
            }
            guard let apk, var ctx = apk.ctx else { return "O build terminou, mas o APK não apareceu na lista de APKs." }
            apkGerado = apk.url
            ctx.notas = "Versão \(versaoNova) (build \(codigoNovo))\n\n\(changelog)"
            ApkArquivo.salvar(ctx, para: apk.url)
            app.recarregarApks(projeto)
            let esperadoNome = ativo(.versao) ? versaoNova : versaoAtual
            let esperadoCodigo = ativo(.versao) ? codigoNovo : codigoAtual
            if ctx.versionName != esperadoNome || ctx.versionCode != esperadoCodigo {
                return "O APK saiu com versionName \(ctx.versionName ?? "?") e versionCode \(ctx.versionCode ?? "?"), mas o esperado era \(esperadoNome) / \(esperadoCodigo). "
                    + (cng ? "O prebuild pode não ter atualizado a pasta android — rode o prebuild com --clean e gere de novo." : "Confira o android/app/build.gradle.")
            }
            detalhe("\(apk.url.lastPathComponent) · versionName \(esperadoNome) · versionCode \(esperadoCodigo) ✓")

        case .push:
            let semUpstream = linha(await git(["rev-parse", "--abbrev-ref", "@{upstream}"])).isEmpty
            var c: [[String]] = [["push"] + (semUpstream ? ["-u", "origin", branch] : [])]
            if criarTag && ativo(.tag) { c.append(["push", "origin", tag]) }
            let r = await gitModel.rodar(c)
            await gitModel.carregar()
            guard r.ok else { return r.msg }
            detalhe("Enviado")
        }
        return nil
    }

    /// Espera a sessão começar (até 2 min) e terminar (até 2 h); devolve o código de saída
    private func esperarBuild(_ app: AppState, _ sessao: String, antes: EstadoSessao?) async -> Int? {
        let inicio = Date()
        var comecou = false
        while Date().timeIntervalSince(inicio) < 2 * 3600 {
            let e = app.estado(sessao)
            if e == .rodando || e == .local { comecou = true }
            else if case .terminou(let c) = e, comecou || e != antes { return c }
            if !comecou && Date().timeIntervalSince(inicio) > 120 { return nil }
            try? await Task.sleep(for: .seconds(2))
        }
        return nil
    }

    // MARK: relatório em Markdown

    private var pastaRelatorios: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/BuildRemoto/Versoes/\(projeto)")
    }

    func textoRelatorio() -> String {
        let df = DateFormatter(); df.dateFormat = "dd/MM/yyyy HH:mm"
        let icone = { (n: ItemVerificacao.Nivel) -> String in
            switch n { case .ok: "✅"; case .aviso: "⚠️"; case .bloqueio: "⛔"; case .impede: "🚫" }
        }
        var md = """
        # \(projeto) — versão \(versaoNova)

        | | |
        |---|---|
        | Gerado em | \(df.string(from: analisadoEm)) |
        | Versão | \(versaoAtual) → **\(versaoNova)** |
        | Build Android | \(codigoAtual.isEmpty ? "—" : codigoAtual) → **\(codigoNovo.isEmpty ? "—" : codigoNovo)** |
        | Branch | \(branch) (commit \(commitAtual)) |
        | Onde o APK é gerado | \(gerarApk ? (modoLocal ? "Mac" : "PC") : "não gerar") |
        | Tag | \(criarTag ? tag : "não criar") |
        | Enviar ao servidor | \(enviar ? "sim" : "não") |

        ## Verificações
        \(itens.map { "- \(icone($0.nivel)) \($0.texto)" }.joined(separator: "\n"))

        """
        if !checagens.isEmpty {
            md += "\n## Checagens\n"
            for c in checagens {
                md += "\n### \(c.ok ? "✅" : "⛔") \(c.nome) — `\(c.comando)` (\(c.segundos)s)\n\n```\n\(c.saida.suffix(4000))\n```\n"
            }
        }
        md += "\n## Arquivos que serão alterados\n\n| Arquivo | Linha | Campo | Atual | Novo |\n|---|---|---|---|---|\n"
        md += mudancas.map { "| \($0.fonte.arquivo) | \($0.fonte.linha) | \($0.fonte.rotulo) | \($0.fonte.valor) | **\($0.novo)** |" }.joined(separator: "\n")
        if !avisosDoPlano.isEmpty { md += "\n\n## Atenção às etapas escolhidas\n" + avisosDoPlano.map { "- ⚠️ \($0)" }.joined(separator: "\n") }
        md += "\n\n## Changelog (desde \(baseChangelog))\n\n\(changelog)\n\n## Plano de execução\n"
        for p in passos {
            let st: String
            switch p.estado { case .pendente: st = p.ativo ? "" : " — **vai ser pulada**"; case .rodando: st = " — ⏳"; case .ok: st = " — ✅"; case .falhou: st = " — ❌"; case .pulado: st = " — pulado" }
            md += "\n\(p.id). **\(p.titulo)**\(st)\n" + p.comandos.map { "    - `\($0)`" }.joined(separator: "\n") + "\n"
            if !p.detalhe.isEmpty { md += "\n    > " + p.detalhe.replacingOccurrences(of: "\n", with: "\n    > ") + "\n" }
        }
        if let apkGerado { md += "\n## APK\n\n`\(apkGerado.path)`\n" }
        return md
    }

    func salvarRelatorio() -> URL? {
        try? FileManager.default.createDirectory(at: pastaRelatorios, withIntermediateDirectories: true)
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmm"
        let u = relatorio ?? pastaRelatorios.appendingPathComponent("v\(versaoNova)_\(df.string(from: analisadoEm)).md")
        return (try? textoRelatorio().write(to: u, atomically: true, encoding: .utf8)) != nil ? u : nil
    }

    func atualizarRelatorio() { relatorio = salvarRelatorio() }
}
