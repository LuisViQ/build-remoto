import SwiftUI
import WebKit
import UniformTypeIdentifiers

// MARK: - Entregas: registro de fim de demanda
//
// Uma página por demanda concluída: resumo (escrito pela IA e revisado), como testar, prints de
// antes/depois e detalhes técnicos (commits escolhidos, versão, APK, aparelho). Fica guardada no app,
// vira PDF e copia em Markdown para Notion/Azure.

struct PrintEntrega: Codable, Identifiable, Hashable {
    var id = UUID()
    var arquivo: String          // nome em Entregas/imagens
    var legenda = ""
    var momento = "Depois"       // Antes · Depois · Outro
}

struct CommitEntrega: Codable, Identifiable, Hashable {
    var hash: String
    var titulo: String
    var autor: String
    var data: String
    var arquivos: [String]
    /// Commit de merge: o que importa é o que ele trouxe da outra branch
    var merge: Bool?
    var id: String { hash }
}

struct Entrega: Codable, Identifiable, Hashable {
    var id = UUID()
    var codigo = ""
    var titulo = ""
    var branch = ""
    var criada = Date()
    var atualizada = Date()
    var concluida: Date? = Date()
    var resumo = ""
    var comoTestar = ""
    var prints: [PrintEntrega] = []
    var commits: [CommitEntrega] = []
    var versao = ""
    var apk = ""
    var aparelho = ""

    var nomeExibicao: String {
        let t = titulo.isEmpty ? "Sem título" : titulo
        return codigo.isEmpty ? t : "#\(codigo) · \(t)"
    }
}

@MainActor
final class EntregasStore: ObservableObject {
    let projeto: String
    @Published var entregas: [Entrega] = [] { didSet { ArquivoJSON.salvar(entregas, "Entregas", projeto) } }

    private static var instancias: [String: EntregasStore] = [:]
    static func de(_ p: String) -> EntregasStore {
        if let s = instancias[p] { return s }
        let s = EntregasStore(projeto: p)
        instancias[p] = s
        return s
    }
    init(projeto: String) {
        self.projeto = projeto
        entregas = ArquivoJSON.ler([Entrega].self, "Entregas", projeto) ?? []
    }

    static var pastaImagens: URL {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/BuildRemoto/Entregas/imagens")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func nova() -> UUID {
        var e = Entrega()
        e.branch = ((try? String(contentsOfFile: "\(Config.pasta(projeto))/.git/HEAD", encoding: .utf8)) ?? "")
            .replacingOccurrences(of: "ref: refs/heads/", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        // número da demanda tirado da branch, se houver (ex.: fix/12345-…)
        if let r = e.branch.range(of: #"\d{4,}"#, options: .regularExpression) { e.codigo = String(e.branch[r]) }
        entregas.insert(e, at: 0)
        return e.id
    }

    func binding(_ id: UUID) -> Binding<Entrega>? {
        guard entregas.contains(where: { $0.id == id }) else { return nil }
        return Binding(get: { self.entregas.first { $0.id == id } ?? Entrega() },
                       set: { novo in
                           guard let i = self.entregas.firstIndex(where: { $0.id == id }) else { return }
                           var e = novo; e.atualizada = Date(); self.entregas[i] = e
                       })
    }

    func remover(_ id: UUID) {
        if let e = entregas.first(where: { $0.id == id }) {
            for p in e.prints { try? FileManager.default.removeItem(at: Self.pastaImagens.appendingPathComponent(p.arquivo)) }
        }
        entregas.removeAll { $0.id == id }
    }

    // MARK: imagens

    static func guardar(_ dados: Data, extensao: String = "png") -> String {
        let nome = "\(UUID().uuidString.prefix(12).lowercased()).\(extensao)"
        try? dados.write(to: pastaImagens.appendingPathComponent(nome))
        return nome
    }
    static func guardar(_ img: NSImage) -> String? {
        guard let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t), let png = r.representation(using: .png, properties: [:]) else { return nil }
        return guardar(png)
    }
    static func guardar(arquivo u: URL) -> String? {
        guard let d = try? Data(contentsOf: u) else { return nil }
        return guardar(d, extensao: u.pathExtension.lowercased().isEmpty ? "png" : u.pathExtension.lowercased())
    }

    // MARK: commits para escolher

    func commitsRecentes(_ busca: String, faixa: String? = nil) async -> [CommitEntrega] {
        let pasta = Config.pasta(projeto)
        var args = ["log", "--date=format:%d/%m/%Y %H:%M", "--format=@@C%x1f%H%x1f%s%x1f%an%x1f%ad%x1f%P%x1e", "--name-only"]
        if let faixa { args.append(faixa) } else { args += ["--all", "-n", "300"] }
        if !busca.isEmpty { args += ["-i", "--grep=\(busca)"] }
        let out = (await GitCLI.run(pasta, args)).out
        var lista: [CommitEntrega] = out.components(separatedBy: "@@C\u{1f}").dropFirst().compactMap { bloco in
            let partes = bloco.components(separatedBy: "\u{1e}")
            let c = partes[0].components(separatedBy: "\u{1f}")
            guard c.count >= 5 else { return nil }
            let arqs = (partes.count > 1 ? partes[1] : "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            let ehMerge = c[4].split(separator: " ").count > 1
            return CommitEntrega(hash: c[0], titulo: c[1], autor: c[2], data: c[3], arquivos: arqs, merge: ehMerge ? true : nil)
        }
        // merges: os arquivos são os que ele trouxe (diferença para o 1º pai)
        for i in lista.indices where lista[i].merge == true {
            lista[i].arquivos = (await GitCLI.run(pasta, ["diff", "--name-only", "\(lista[i].hash)^1", lista[i].hash])).out
                .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }
        return lista
    }

    /// Todos os commits da branch atual desde que ela saiu da develop/main/master (merges incluídos)
    func commitsDaBranch() async -> (lista: [CommitEntrega], origem: String)? {
        let pasta = Config.pasta(projeto)
        let atual = (await GitCLI.run(pasta, ["branch", "--show-current"])).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = (await GitCLI.run(pasta, ["rev-parse", "HEAD"])).out.trimmingCharacters(in: .whitespacesAndNewlines)
        var melhor: (String, String, Int)?
        for c in ["origin/develop", "develop", "origin/main", "main", "origin/master", "master"] {
            if c.replacingOccurrences(of: "origin/", with: "") == atual { continue }
            guard (await GitCLI.run(pasta, ["rev-parse", "-q", "--verify", c])).ok else { continue }
            let mb = (await GitCLI.run(pasta, ["merge-base", "HEAD", c])).out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !mb.isEmpty, mb != head else { continue }
            let d = Int((await GitCLI.run(pasta, ["log", "-1", "--format=%ct", mb])).out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            if melhor == nil || d > melhor!.2 { melhor = (c, mb, d) }
        }
        guard let (origem, mb, _) = melhor else { return nil }
        return (await commitsRecentes("", faixa: "\(mb)..HEAD"), origem)
    }

    // MARK: IA

    /// Trechos do código alterado — primeiro parâmetros, enums, modelos, APIs e configurações
    private func codigoAlterado(_ commits: [CommitEntrega]) async -> String {
        let pasta = Config.pasta(projeto)
        let fora = [":(exclude)yarn.lock", ":(exclude)package-lock.json", ":(exclude)**/*.snap", ":(exclude)android/**", ":(exclude)ios/**",
                    ":(exclude)**/*.png", ":(exclude)**/*.jpg", ":(exclude)**/*.svg", ":(exclude)**/*.ttf"]
        let importantes = [":(glob,icase)**/*param*", ":(glob)**/enums/**", ":(glob)**/models/**", ":(glob,icase)**/*schema*",
                           ":(glob)**/*storage-keys*", ":(glob)**/config/**", ":(glob)**/api/**", ":(glob)**/routers/**",
                           ":(glob)**/services/**", ":(glob)app.config.*", ":(glob)app.json", ":(glob)**/*permission*"]
        var prioridade = "", resto = ""
        for c in commits {
            let base: [String] = c.merge == true ? ["diff", "--no-color", "-U3", "\(c.hash)^1", c.hash] : ["show", "--format=", "--no-color", "-U3", c.hash]
            let imp = (await GitCLI.run(pasta, base + ["--"] + importantes + fora)).out
            if !imp.isEmpty && prioridade.count < 45_000 { prioridade += "\n# \(c.titulo)\n" + String(imp.prefix(12_000)) }
            let tudo = (await GitCLI.run(pasta, (c.merge == true ? ["diff", "--no-color", "-U2", "\(c.hash)^1", c.hash] : ["show", "--format=", "--no-color", "-U2", c.hash]) + ["--", "."] + fora)).out
            if resto.count < 45_000 { resto += "\n# \(c.titulo)\n" + String(tudo.prefix(6_000)) }
        }
        return (prioridade.isEmpty ? "" : "### Arquivos de parâmetros, enums, modelos, APIs e configuração\n" + String(prioridade.prefix(45_000)))
            + "\n### Demais mudanças\n" + String(resto.prefix(45_000))
    }

    /// Parâmetros do sistema criados ou usados nos commits/merges escolhidos (lidos dos enums de parâmetros do projeto)
    func parametrosDetectados(_ commits: [CommitEntrega]) async -> String {
        let pasta = Config.pasta(projeto)
        // definições atuais: NOME = 1001, // comentário   (arquivos de enums de parâmetros)
        let defs = (await GitCLI.run(pasta, ["grep", "-n", "-E", "^[[:space:]]*[A-Za-z_][A-Za-z0-9_]* = [0-9]{3,}", "HEAD", "--",
                                            ":(glob,icase)**/*param*"])).out
        var catalogo: [String: (numero: String, comentario: String, enumNome: String)] = [:]
        var enumAtual = ""
        for l in defs.split(separator: "\n") {
            let partes = l.split(separator: ":", maxSplits: 3).map(String.init)
            guard partes.count == 4 else { continue }
            let codigo = partes[3]
            guard let r = codigo.range(of: #"([A-Za-z_][A-Za-z0-9_]*) = (\d{3,})"#, options: .regularExpression) else { continue }
            let par = codigo[r].components(separatedBy: " = ")
            let comentario = codigo.components(separatedBy: "//").dropFirst().joined(separator: "//").trimmingCharacters(in: .whitespaces)
            enumAtual = partes[1]
            catalogo[par[0]] = (par[1], comentario, (enumAtual as NSString).lastPathComponent)
        }
        guard !catalogo.isEmpty else { return "" }
        var novos = Set<String>(), usados = Set<String>()
        for c in commits {
            let args = c.merge == true ? ["diff", "--no-color", "-U0", "\(c.hash)^1", c.hash] : ["show", "--format=", "--no-color", "-U0", c.hash]
            let d = (await GitCLI.run(pasta, args + ["--", ".", ":(exclude)android/**", ":(exclude)ios/**", ":(exclude)yarn.lock"])).out
            for l in d.split(separator: "\n") where l.hasPrefix("+") && !l.hasPrefix("+++") {
                for (nome, _) in catalogo where l.range(of: "\\b\(nome)\\b", options: .regularExpression) != nil {
                    if l.range(of: "\\b\(nome) = \\d", options: .regularExpression) != nil { novos.insert(nome) } else { usados.insert(nome) }
                }
            }
        }
        let todos = novos.union(usados)
        guard !todos.isEmpty else { return "" }
        return todos.sorted { (catalogo[$0]?.numero ?? "") < (catalogo[$1]?.numero ?? "") }.map { nome in
            let c = catalogo[nome]!
            return "- Parâmetro \(c.numero) (\(nome)) — \(c.comentario.isEmpty ? "sem descrição no código" : c.comentario) — "
                + (novos.contains(nome) ? "CRIADO nestes commits/merges" : "já existia; passou a ser usado nestes commits/merges")
        }.joined(separator: "\n")
    }

    func gerarResumo(_ e: Entrega, provedor: ProvedorIA, lerCodigo: Bool = true) async throws -> (resumo: String, comoTestar: String) {
        var dados = "Demanda: \(e.codigo.isEmpty ? "(sem número)" : "#" + e.codigo) — \(e.titulo)\nApp: \(projeto)\nBranch: \(e.branch)\n"
        if !e.commits.isEmpty {
            dados += "\nCommits:\n"
            for c in e.commits {
                let corpo = (await GitCLI.run(Config.pasta(projeto), ["show", "-s", "--format=%b", c.hash])).out.trimmingCharacters(in: .whitespacesAndNewlines)
                dados += "- \(c.merge == true ? "[MERGE] " : "")\(c.titulo)" + (corpo.isEmpty ? "" : "\n  Detalhes: \(corpo.prefix(500))")
                    + "\n  Arquivos: " + c.arquivos.prefix(25).joined(separator: ", ") + "\n"
                if c.merge == true {
                    // os commits que o merge trouxe da outra branch
                    let trazidos = (await GitCLI.run(Config.pasta(projeto), ["log", "--no-merges", "--format=    · %s%n%b", "-n", "40", "\(c.hash)^1..\(c.hash)"])).out
                        .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(80).joined(separator: "\n")
                    if !trazidos.isEmpty { dados += "  Esse merge trouxe:\n\(trazidos)\n" }
                }
            }
        }
        // tudo o que o app guarda sobre a branch / a demanda
        let ligada = { (texto: String, branch: String) -> Bool in
            (!e.branch.isEmpty && (branch == e.branch || texto.contains(e.branch))) || (!e.codigo.isEmpty && texto.contains(e.codigo))
        }
        let notas = (NotasStore.de(projeto).notas + NotasStore.compartilhadas(com: projeto)).filter { ligada($0.titulo + " " + $0.detalhes, $0.branch) }
        if !notas.isEmpty {
            dados += "\nNotas da demanda/branch:\n" + notas.map { n in
                let (f, t) = n.tarefas
                return "- \(n.titulo) [\(n.status.rawValue)\(t > 0 ? ", tarefas \(f)/\(t)" : "")]\n  " + String(n.detalhes.prefix(1500)).replacingOccurrences(of: "\n", with: "\n  ")
            }.joined(separator: "\n") + "\n"
        }
        let bugs = Bugs.listar(projeto).filter { ligada($0.meta.titulo, $0.meta.branch) }
        if !bugs.isEmpty {
            dados += "\nBugs registrados nesta branch:\n" + bugs.map { b -> String in
                let md = (try? String(contentsOf: b.readme, encoding: .utf8)) ?? ""
                func secao(_ t: String) -> String {
                    guard let r = md.range(of: "## \(t)\n") else { return "" }
                    let x = String(md[r.upperBound...].prefix { $0 != "#" }).trimmingCharacters(in: .whitespacesAndNewlines)
                    return x.contains("não informado") ? "" : x
                }
                return "- \(b.meta.titulo) [\(b.meta.gravidade)\(b.meta.resolvido ? ", resolvido" : "")]: " + secao("O que aconteceu").prefix(400)
                    + (secao("Passos para reproduzir").isEmpty ? "" : "\n  Passos: " + secao("Passos para reproduzir").prefix(400))
            }.joined(separator: "\n") + "\n"
        }
        if !e.branch.isEmpty {
            let apks = ApkArquivo.listar(projeto).filter { $0.ctx?.branch == e.branch }
            if !apks.isEmpty {
                let df = DateFormatter(); df.dateFormat = "dd/MM HH:mm"
                dados += "\nAPKs gerados nesta branch: " + apks.prefix(10).map { "\($0.ctx?.tipo ?? "?") v\($0.ctx?.versionName ?? "?") (\(df.string(from: $0.data)))" }.joined(separator: "; ") + "\n"
            }
            let builds = Historico.listar(projeto).filter { $0.branch == e.branch }
            if !builds.isEmpty {
                dados += "Execuções nesta branch: " + Dictionary(grouping: builds, by: \.acao).map { a, l in "\(a) \(l.count)x (\(l.filter(\.ok).count) ok)" }.sorted().joined(separator: "; ") + "\n"
            }
        }
        if let primeiro = e.commits.last?.data, let ultimo = e.commits.first?.data { dados += "Período dos commits: \(primeiro) a \(ultimo)\n" }
        if !e.commits.isEmpty {
            let params = await parametrosDetectados(e.commits)
            if !params.isEmpty { dados += "\nPARÂMETROS DETECTADOS NO CÓDIGO (lista exata, use todos):\n\(params)\n" }
        }
        if lerCodigo && !e.commits.isEmpty { dados += "\nCódigo alterado (diff):\n" + (await codigoAlterado(e.commits)) + "\n" }
        if !e.prints.isEmpty { dados += "\nPrints anexados: " + e.prints.map { "\($0.momento): \($0.legenda)" }.joined(separator: "; ") + "\n" }
        if !e.resumo.isEmpty { dados += "\nRascunho do desenvolvedor (aproveite):\n\(e.resumo)\n" }
        let instrucoes = """
        Você escreve o registro de FIM DE DEMANDA de um app mobile (React Native), em português do Brasil, para documentação.
        O registro deve ser COMPLETO: é a documentação oficial da entrega. Não resuma — descreva TODAS as mudanças encontradas nos dados.
        Responda em Markdown com exatamente duas partes, separadas pela linha "### Como testar":

        1) Primeiro, o que foi feito:
           - Um parágrafo de contexto (objetivo da demanda).
           - "#### Mudanças": uma lista com TODAS as mudanças, um item por mudança, agrupadas por funcionalidade/tela
             (use subtítulos em negrito por grupo). Para cada uma: o que mudou, onde aparece no app e o comportamento antes/depois quando houver.
             Linguagem que um gestor/QA entenda; sem nomes de arquivos nem código.
           - "#### Funcionalidades que vieram de outras branches (merges)": se houver commits [MERGE], descreva cada funcionalidade que eles
             trouxeram (ex.: consulta de saldo no servidor), com o mesmo nível de detalhe. Omita se não houver merges.
           - "#### Parâmetros e configurações": liste TODOS os itens de "PARÂMETROS DETECTADOS NO CÓDIGO", cada um com número, nome,
             para que serve, o que cada valor faz e se foi CRIADO ou se já existia e passou a ser usado. Acrescente campos/tabelas novas no banco local,
             endpoints/APIs, chaves de configuração/armazenamento e permissões que aparecerem no código. Omita a seção só se não houver nada.

        2) Depois da linha "### Como testar": passos numerados para validar cada mudança no aparelho, com o resultado esperado.
           Cubra cada parâmetro e cada valor relevante (ex.: "com o parâmetro 1001 em 1…", "com o 1002 ativo…") e os cenários online/offline quando fizer sentido.

        Não invente nada que não esteja nos dados. Se algo não puder ser confirmado, diga isso no item em vez de omitir.
        """
        let texto = try await IA.gerar(instrucoes: instrucoes, entrada: dados, provedor: provedor)
        let partes = texto.components(separatedBy: "### Como testar")
        return (partes[0].trimmingCharacters(in: .whitespacesAndNewlines),
                partes.count > 1 ? partes[1].trimmingCharacters(in: .whitespacesAndNewlines) : e.comoTestar)
    }

    // MARK: exportar

    func markdown(_ e: Entrega) -> String {
        let df = DateFormatter(); df.dateFormat = "dd/MM/yyyy"
        var md = "# \(e.codigo.isEmpty ? "" : "#\(e.codigo) — ")\(e.titulo)\n\n"
        md += "**App:** \(projeto)" + (e.concluida.map { " · **Concluída em:** \(df.string(from: $0))" } ?? "") + (e.branch.isEmpty ? "" : " · **Branch:** `\(e.branch)`") + "\n\n"
        md += "## O que foi feito\n\n\(e.resumo)\n\n"
        if !e.comoTestar.isEmpty { md += "## Como testar\n\n\(e.comoTestar)\n\n" }
        if !e.prints.isEmpty {
            md += "## Prints\n\n" + e.prints.map { "- \($0.momento)\($0.legenda.isEmpty ? "" : ": \($0.legenda)")" }.joined(separator: "\n") + "\n\n_(imagens anexadas no PDF)_\n\n"
        }
        md += "## Detalhes técnicos\n\n"
        if !e.versao.isEmpty { md += "- **Versão:** \(e.versao)\n" }
        if !e.apk.isEmpty { md += "- **APK testado:** \(e.apk)\n" }
        if !e.aparelho.isEmpty { md += "- **Aparelho:** \(e.aparelho)\n" }
        if !e.commits.isEmpty {
            md += "- **Commits:**\n" + e.commits.map { "    - `\($0.hash.prefix(8))` \($0.titulo) (\($0.data))" }.joined(separator: "\n") + "\n"
            let arquivos = Array(Set(e.commits.flatMap(\.arquivos))).sorted()
            if !arquivos.isEmpty { md += "- **Arquivos alterados (\(arquivos.count)):** " + arquivos.prefix(40).map { "`\($0)`" }.joined(separator: ", ") + "\n" }
        }
        return md
    }

    func html(_ e: Entrega) -> String {
        let df = DateFormatter(); df.dateFormat = "dd/MM/yyyy"
        let base = Self.pastaImagens
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        let prints = e.prints.map { p in
            "<figure><div class=\"tag \(p.momento.lowercased())\">\(esc(p.momento))</div><img src=\"\(base.appendingPathComponent(p.arquivo).absoluteString)\"><figcaption>\(esc(p.legenda))</figcaption></figure>"
        }.joined()
        let arquivos = Array(Set(e.commits.flatMap(\.arquivos))).sorted()
        var detalhes = ""
        for (k, v) in [("App", projeto), ("Branch", e.branch), ("Versão", e.versao), ("APK testado", e.apk), ("Aparelho", e.aparelho)] where !v.isEmpty {
            detalhes += "<tr><th>\(k)</th><td>\(esc(v))</td></tr>"
        }
        let commits = e.commits.map { "<li><code>\($0.hash.prefix(8))</code> \(esc($0.titulo)) <span class=\"mut\">· \(esc($0.autor)) · \($0.data)</span></li>" }.joined()
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { font: 13px -apple-system, Helvetica, sans-serif; color: #1d2330; margin: 0; padding: 0 4px; }
        header { border-bottom: 3px solid #F2A93B; padding-bottom: 12px; margin-bottom: 18px; }
        .eyebrow { font: 600 11px Menlo, monospace; letter-spacing: 2px; color: #9A5B00; text-transform: uppercase; }
        h1 { font-size: 24px; margin: 6px 0 6px; } .mut { color: #6a7280; }
        h2 { font-size: 16px; margin: 22px 0 8px; padding-bottom: 4px; border-bottom: 1px solid #e3e1da; page-break-after: avoid; }
        p, li { line-height: 1.5; } code { font: 11.5px Menlo, monospace; background: #f1eee7; padding: 1px 4px; border-radius: 4px; }
        pre { background: #f1eee7; padding: 10px; border-radius: 6px; white-space: pre-wrap; }
        .prints { display: flex; flex-wrap: wrap; gap: 14px; } figure { margin: 0; width: 220px; page-break-inside: avoid; }
        figure img { width: 220px; border: 1px solid #ddd; border-radius: 8px; } figcaption { font-size: 11.5px; color: #4a5263; margin-top: 4px; }
        .tag { display: inline-block; font: 600 10px -apple-system; padding: 2px 8px; border-radius: 99px; margin-bottom: 4px; background: #e8eef9; color: #2563C9; }
        .tag.antes { background: #fbeee0; color: #9A5B00; }
        table { border-collapse: collapse; } th { text-align: left; color: #6a7280; font-weight: 500; padding: 3px 16px 3px 0; } td { padding: 3px 0; }
        </style></head><body>
        <header><div class="eyebrow">Registro de entrega · \(esc(projeto))</div>
        <h1>\(e.codigo.isEmpty ? "" : "#\(esc(e.codigo)) — ")\(esc(e.titulo))</h1>
        <div class="mut">\(e.concluida.map { "Concluída em \(df.string(from: $0))" } ?? "Em andamento")</div></header>
        <h2>O que foi feito</h2>\(Markdown.html(e.resumo, base: ImagensNotas.raiz))
        \(e.comoTestar.isEmpty ? "" : "<h2>Como testar</h2>" + Markdown.html(e.comoTestar, base: ImagensNotas.raiz))
        \(prints.isEmpty ? "" : "<h2>Prints</h2><div class=\"prints\">\(prints)</div>")
        <h2>Detalhes técnicos</h2><table>\(detalhes)</table>
        \(commits.isEmpty ? "" : "<h3>Commits</h3><ul>\(commits)</ul>")
        \(arquivos.isEmpty ? "" : "<h3>Arquivos alterados (\(arquivos.count))</h3><p class=\"mut\">" + arquivos.prefix(60).map { "<code>\(esc($0))</code>" }.joined(separator: " ") + "</p>")
        </body></html>
        """
    }
}

// MARK: - IA compartilhada (Claude Code deste Mac ou API da Anthropic)

enum IA {
    static func gerar(instrucoes: String, entrada: String, provedor: ProvedorIA) async throws -> String {
        switch provedor {
        case .semIA:
            throw Falha("Escolha uma IA (Claude Code ou API) para gerar o texto.")
        case .claudeCode:
            let r = await Shell.run("claude", ["-p", instrucoes, "--output-format", "text"], stdin: Data(entrada.utf8))
            let txt = r.out.split(separator: "\n", omittingEmptySubsequences: false)
                .drop { $0.hasPrefix("Warning:") || $0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard r.ok, !txt.isEmpty else { throw Falha("O Claude Code não respondeu: \(txt.prefix(300))") }
            return txt
        case .api:
            guard let chave = Chaveiro.ler("anthropic-api-key") else { throw Falha("Guarde a chave da API na tela da Daily (Keychain).") }
            var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.httpMethod = "POST"
            req.timeoutInterval = 180
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.setValue(chave, forHTTPHeaderField: "x-api-key")
            req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            let corpo: [String: Any] = ["model": "claude-opus-5-5", "max_tokens": 16000, "fallbacks": "default",
                                        "output_config": ["effort": "low"], "system": instrucoes,
                                        "messages": [["role": "user", "content": entrada]]]
            req.httpBody = try JSONSerialization.data(withJSONObject: corpo)
            let (d, resp) = try await URLSession.shared.data(for: req)
            let json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                throw Falha(status == 401 ? "Chave da API inválida." : status == 429 ? "Limite da API atingido, tente de novo."
                            : "Erro \(status): \(((json["error"] as? [String: Any])?["message"] as? String) ?? "")")
            }
            if json["stop_reason"] as? String == "refusal" { throw Falha("O modelo recusou gerar o texto.") }
            let txt = (json["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            guard !txt.isEmpty else { throw Falha("A resposta veio vazia.") }
            return txt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static var provedorPadrao: ProvedorIA {
        UserDefaults.standard.string(forKey: "resumo.provedor").flatMap(ProvedorIA.init(rawValue:))
            ?? (FileManager.default.isExecutableFile(atPath: "\(Config.home)/.local/bin/claude") ? .claudeCode : .api)
    }
}

// MARK: - PDF (WebKit gera a página inteira; aqui ela é cortada em A4 entre os blocos)

@MainActor
final class GeradorPDF: NSObject, WKNavigationDelegate {
    private var web: WKWebView?
    private var janela: NSWindow?
    private var destino: URL!
    private var fim: ((Bool) -> Void)?
    private static var ativos: [GeradorPDF] = []
    private let largura: CGFloat = 794          // A4 a 96 dpi

    static func gerar(html: String, para url: URL, concluir: @escaping (Bool) -> Void) {
        let g = GeradorPDF()
        ativos.append(g)
        g.iniciar(html, url) { ok in concluir(ok); ativos.removeAll { $0 === g } }
    }

    private func iniciar(_ html: String, _ url: URL, _ fim: @escaping (Bool) -> Void) {
        destino = url
        self.fim = fim
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: largura, height: 12_000))
        w.navigationDelegate = self
        let j = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: largura, height: 12_000), styleMask: [.borderless], backing: .buffered, defer: false)
        j.contentView = w
        janela = j
        web = w
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("entrega-\(UUID().uuidString).html")
        try? html.write(to: tmp, atomically: true, encoding: .utf8)
        w.loadFileURL(tmp, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    private func terminar(_ ok: Bool) { janela?.orderOut(nil); fim?(ok); fim = nil }

    func webView(_ w: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { terminar(false) }

    func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
        // espera as imagens e mede onde cada bloco começa e termina
        let js = """
        new Promise(ok => { const imgs = [...document.images].filter(i => !i.complete);
          if (!imgs.length) return ok(); let n = imgs.length; imgs.forEach(i => { i.onload = i.onerror = () => { if (--n === 0) ok(); }; }); })
        .then(() => Promise.all([...document.images].map(i => { i.loading = 'eager'; return i.decode().catch(() => null); })))
        .then(() => new Promise(ok => setTimeout(ok, 150)))
        .then(() => JSON.stringify({ h: Math.ceil(Math.max(...[...document.body.children].map(e => e.getBoundingClientRect().bottom + scrollY), 100) + 24),
          b: [...document.querySelectorAll('h1,h2,h3,p,li,figure,pre,table,tr,header')].map(e => { const r = e.getBoundingClientRect(); return [r.top + scrollY, r.bottom + scrollY]; }) }))
        """
        w.callAsyncJavaScript("return await (\(js))", arguments: [:], in: nil, in: .page) { [self] r in
            guard case .success(let v) = r, let txt = v as? String, let d = txt.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let h = (o["h"] as? NSNumber).map({ CGFloat(truncating: $0) }) else { terminar(false); return }
            let blocos = (o["b"] as? [[NSNumber]] ?? []).map { (CGFloat(truncating: $0[0]), CGFloat(truncating: $0[1])) }
            if h > w.frame.height { w.frame.size.height = h; janela?.setContentSize(NSSize(width: largura, height: h)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                let cfg = WKPDFConfiguration()
                cfg.rect = CGRect(x: 0, y: 0, width: largura, height: h)
                w.createPDF(configuration: cfg) { [self] res in
                    guard case .success(let pdf) = res else { terminar(false); return }
                    terminar(paginar(pdf, altura: h, blocos: blocos))
                }
            }
        }
    }

    /// Corta a página única em A4, sempre entre blocos (nunca no meio de uma linha ou de um print)
    private func paginar(_ pdf: Data, altura h: CGFloat, blocos: [(CGFloat, CGFloat)]) -> Bool {
        guard let prov = CGDataProvider(data: pdf as CFData), let doc = CGPDFDocument(prov), let pagina = doc.page(at: 1) else { return false }
        let a4 = CGRect(x: 0, y: 0, width: 595, height: 842), margem: CGFloat = 36
        let escala = (a4.width - 2 * margem) / largura
        let alturaUtil = (a4.height - 2 * margem) / escala
        let origemH = pagina.getBoxRect(.mediaBox).height
        var cortes: [CGFloat] = [0]
        while let ultimo = cortes.last, ultimo < h - 1 {
            let limite = ultimo + alturaUtil
            if limite >= h { cortes.append(h); break }
            let valido = { (c: CGFloat) in !blocos.contains { $0.0 < c - 0.5 && $0.1 > c + 0.5 && ($0.1 - $0.0) < alturaUtil } }
            let candidatos = blocos.flatMap { [$0.0, $0.1] }.filter { $0 > ultimo + alturaUtil * 0.3 && $0 <= limite && valido($0) }
            cortes.append(candidatos.max() ?? limite)
        }
        var caixa = a4
        guard let consumidor = CGDataConsumer(url: destino as CFURL), let ctx = CGContext(consumer: consumidor, mediaBox: &caixa, nil) else { return false }
        for i in 0..<(cortes.count - 1) {
            let y0 = cortes[i], y1 = cortes[i + 1]
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: margem, y: a4.height - margem - (y1 - y0) * escala, width: a4.width - 2 * margem, height: (y1 - y0) * escala))
            ctx.translateBy(x: margem, y: a4.height - margem - (origemH - y0) * escala)
            ctx.scaleBy(x: escala, y: escala)
            ctx.drawPDFPage(pagina)
            ctx.restoreGState()
            // número da página
            let n = "\(i + 1) / \(cortes.count - 1)" as NSString
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            n.draw(at: NSPoint(x: a4.width - margem - 40, y: 16), withAttributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.gray])
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return true
    }
}

// MARK: - Tela

struct EntregasView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var store: EntregasStore
    @State private var selecionada: UUID?
    @State private var busca = ""

    private var filtradas: [Entrega] {
        store.entregas.filter { e in
            busca.isEmpty || e.titulo.localizedCaseInsensitiveContains(busca) || e.codigo.contains(busca)
                || e.branch.localizedCaseInsensitiveContains(busca) || e.resumo.localizedCaseInsensitiveContains(busca)
        }.sorted { ($0.concluida ?? $0.atualizada) > ($1.concluida ?? $1.atualizada) }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Nº da demanda, título ou texto", text: $busca).textFieldStyle(.plain)
                    Button { selecionada = store.nova() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("Nova entrega")
                }
                .padding(10)
                Divider()
                List(selection: $selecionada) {
                    ForEach(filtradas) { e in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                if !e.codigo.isEmpty {
                                    Text("#\(e.codigo)").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.purple)
                                }
                                Text(e.titulo.isEmpty ? "Sem título" : e.titulo).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            }
                            HStack(spacing: 8) {
                                Text(e.concluida.map { "Concluída " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "Em andamento")
                                    .font(.system(size: 10.5)).foregroundStyle(e.concluida == nil ? .orange : .secondary)
                                if !e.prints.isEmpty { Label("\(e.prints.count)", systemImage: "photo").font(.system(size: 10.5)).foregroundStyle(.secondary) }
                                if !e.commits.isEmpty { Label("\(e.commits.count)", systemImage: "point.3.connected.trianglepath.dotted").font(.system(size: 10.5)).foregroundStyle(.secondary) }
                            }
                        }
                        .padding(.vertical, 2)
                        .tag(e.id)
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if store.entregas.isEmpty {
                        VStack(spacing: 10) {
                            Text("Nenhuma entrega ainda").foregroundStyle(.secondary)
                            Button("Registrar a primeira") { selecionada = store.nova() }
                        }
                    }
                }
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 380, maxHeight: .infinity)

            Group {
                if let id = selecionada, store.binding(id) != nil {
                    PaginaEntrega(store: store, id: id, apagar: { store.remover(id); selecionada = nil }).id(id)
                } else {
                    ContentUnavailableView("Registro de fim de demanda", systemImage: "checkmark.seal",
                                           description: Text("Documente o que foi feito em cada demanda: resumo escrito pela IA, como testar, prints de antes e depois e os detalhes técnicos. Exporta em PDF e copia para o Notion/Azure."))
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct PaginaEntrega: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var store: EntregasStore
    let id: UUID
    let apagar: () -> Void
    @State private var gerando = false
    @State private var aviso: String?
    @State private var escolherCommits = false
    @State private var confirmarApagar = false
    @State private var tirandoPrint = false
    @State private var provedor: ProvedorIA = IA.provedorPadrao
    @AppStorage("entregas.lerCodigo") private var lerCodigo = true

    var body: some View {
        if let b = store.binding(id) {
            VStack(spacing: 0) {
                barra(b)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        cabecalho(b)
                        secao("O que foi feito", "text.alignleft") {
                            editor(b.resumo, "Resumo da entrega. Use \"Gerar com IA\" para escrever a partir dos commits e notas.", 220)
                        }
                        secao("Como testar", "checklist") {
                            editor(b.comoTestar, "1. Abra o app…\n2. …", 150)
                        }
                        secao("Prints", "photo.on.rectangle") { prints(b) }
                        secao("Detalhes técnicos", "wrench.and.screwdriver") { detalhes(b) }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .sheet(isPresented: $escolherCommits) { EscolherCommits(store: store, entrega: b) }
            .onAppear { app.alvoPrint = AlvoPrint(tipo: .entrega, projeto: store.projeto, id: id, titulo: b.wrappedValue.nomeExibicao) }
            .onChange(of: b.wrappedValue.titulo) { app.alvoPrint = AlvoPrint(tipo: .entrega, projeto: store.projeto, id: id, titulo: b.wrappedValue.nomeExibicao) }
            .onDisappear { if app.alvoPrint?.id == id { app.alvoPrint = nil } }
            .confirmationDialog("Apagar a entrega \(b.wrappedValue.nomeExibicao)?", isPresented: $confirmarApagar) {
                Button("Apagar", role: .destructive) { apagar() }
            } message: { Text("Os prints dela também são apagados.") }
        }
    }

    // MARK: barra de ações

    private func barra(_ b: Binding<Entrega>) -> some View {
        HStack(spacing: 10) {
            Picker("", selection: $provedor) {
                Text("Claude Code").tag(ProvedorIA.claudeCode)
                Text("API").tag(ProvedorIA.api)
            }
            .labelsHidden().fixedSize()
            Button {
                Task {
                    gerando = true; aviso = nil
                    do {
                        let r = try await store.gerarResumo(b.wrappedValue, provedor: provedor, lerCodigo: lerCodigo)
                        b.wrappedValue.resumo = r.resumo
                        if !r.comoTestar.isEmpty { b.wrappedValue.comoTestar = r.comoTestar }
                    } catch { aviso = (error as? Falha)?.texto ?? error.localizedDescription }
                    gerando = false
                }
            } label: { Label(gerando ? "Gerando…" : "Gerar com IA", systemImage: "sparkles") }
                .disabled(gerando)
                .help("Escreve o resumo e o \"Como testar\" a partir dos commits escolhidos, das notas da demanda e do seu rascunho")
            Toggle("Ler o código alterado", isOn: $lerCodigo).toggleStyle(.checkbox)
                .help("Manda o código dos commits escolhidos para a IA achar parâmetros, campos do banco, APIs e configurações. É código do projeto indo para a IA.")
            if gerando { ProgressView().controlSize(.small) }
            if let aviso { Text(aviso).font(.caption).foregroundStyle(aviso.hasPrefix("✓") ? .green : .orange).lineLimit(2) }
            Spacer()
            Button { copiar(store.markdown(b.wrappedValue)); aviso = "✓ Copiado em Markdown — cole no Notion ou no Azure" } label: {
                Label("Copiar", systemImage: "doc.on.doc")
            }
            .help("Copia em Markdown para colar no Notion ou na tarefa do Azure (os prints vão só no PDF)")
            Button { exportarPDF(b.wrappedValue) } label: { Label("PDF", systemImage: "doc.richtext") }
            Menu {
                Button("Apagar entrega…", role: .destructive) { confirmarApagar = true }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func cabecalho(_ b: Binding<Entrega>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Nº", text: b.codigo).textFieldStyle(.roundedBorder).font(.system(size: 14, design: .monospaced)).frame(width: 110)
                    .help("Número da demanda (ex.: 12345)")
                TextField("Título da demanda", text: b.titulo, axis: .vertical).textFieldStyle(.plain).font(.system(size: 24, weight: .bold))
            }
            HStack(spacing: 16) {
                Toggle("Concluída", isOn: Binding(get: { b.wrappedValue.concluida != nil }, set: { b.wrappedValue.concluida = $0 ? Date() : nil }))
                    .toggleStyle(.checkbox)
                if let d = b.wrappedValue.concluida {
                    DatePicker("", selection: Binding(get: { d }, set: { b.wrappedValue.concluida = $0 }), displayedComponents: .date)
                        .labelsHidden().fixedSize()
                }
                Text("App: \(store.projeto)").font(.caption).foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
    }

    private func secao<C: View>(_ t: String, _ i: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(t, systemImage: i).font(.headline)
            c()
        }
    }

    private func editor(_ texto: Binding<String>, _ dica: String, _ altura: CGFloat) -> some View {
        EditorMarkdown(texto: texto, placeholder: dica, tamanhoFonte: 13.5)
            .frame(minHeight: altura)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    // MARK: prints

    private func prints(_ b: Binding<Entrega>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let d = app.alvo {
                    Button {
                        Task {
                            tirandoPrint = true
                            let args = await Adb.argsPrint(d)
                            if let png = Adb.soPNG(await Adb.dados(d, args)) {
                                b.wrappedValue.prints.append(PrintEntrega(arquivo: EntregasStore.guardar(png)))
                                if b.wrappedValue.aparelho.isEmpty { b.wrappedValue.aparelho = d.nome }
                                copiarImagem(png)
                            } else { aviso = "Não consegui tirar o print do \(d.nome)." }
                            tirandoPrint = false
                        }
                    } label: { Label(tirandoPrint ? "Tirando…" : "Print do celular", systemImage: "camera") }
                        .disabled(tirandoPrint)
                }
                Button { adicionarArquivos(b) } label: { Label("Adicionar imagem…", systemImage: "photo.badge.plus") }
                Button {
                    if let img = NSImage(pasteboard: .general), let n = EntregasStore.guardar(img) {
                        b.wrappedValue.prints.append(PrintEntrega(arquivo: n))
                    } else { aviso = "Não há imagem copiada." }
                } label: { Label("Colar", systemImage: "doc.on.clipboard") }
                Text("ou arraste imagens para cá").font(.caption).foregroundStyle(.tertiary)
            }
            .controlSize(.small)
            if b.wrappedValue.prints.isEmpty {
                Text("Nenhum print ainda.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5])).foregroundStyle(.quaternary))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], alignment: .leading, spacing: 14) {
                    ForEach(b.prints) { $p in CartaoPrint(print: $p) { b.wrappedValue.prints.removeAll { $0.id == p.id } } }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            for u in urls where ImagensNotas.extensoes.contains(u.pathExtension.lowercased()) {
                if let n = EntregasStore.guardar(arquivo: u) { b.wrappedValue.prints.append(PrintEntrega(arquivo: n)) }
            }
            return true
        }
    }

    private func adicionarArquivos(_ b: Binding<Entrega>) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = true
        guard p.runModal() == .OK else { return }
        for u in p.urls { if let n = EntregasStore.guardar(arquivo: u) { b.wrappedValue.prints.append(PrintEntrega(arquivo: n)) } }
    }

    // MARK: detalhes técnicos

    private func detalhes(_ b: Binding<Entrega>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Branch").foregroundStyle(.secondary)
                    TextField("—", text: b.branch).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                }
                GridRow {
                    Text("Versão").foregroundStyle(.secondary)
                    TextField("ex.: 2.8.9 (2080903)", text: b.versao).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("APK testado").foregroundStyle(.secondary)
                    HStack {
                        TextField("—", text: b.apk).textFieldStyle(.roundedBorder)
                        Menu("Escolher") {
                            ForEach((app.registrosApk[store.projeto] ?? ApkArquivo.listar(store.projeto)).prefix(15), id: \.url) { a in
                                Button(a.url.lastPathComponent) {
                                    b.wrappedValue.apk = a.url.lastPathComponent
                                    if b.wrappedValue.versao.isEmpty, let v = a.ctx?.versionName { b.wrappedValue.versao = "\(v) (\(a.ctx?.versionCode ?? "?"))" }
                                }
                            }
                        }
                        .fixedSize()
                    }
                }
                GridRow {
                    Text("Aparelho").foregroundStyle(.secondary)
                    HStack {
                        TextField("—", text: b.aparelho).textFieldStyle(.roundedBorder)
                        if let d = app.alvo { Button("Usar \(d.nome)") { b.wrappedValue.aparelho = d.nome }.fixedSize() }
                    }
                }
            }
            .controlSize(.small)
            HStack {
                Text("Commits (\(b.wrappedValue.commits.count))").font(.callout.bold())
                Spacer()
                Button { escolherCommits = true } label: { Label("Escolher commits…", systemImage: "checklist") }.controlSize(.small)
            }
            if b.wrappedValue.commits.isEmpty {
                Text("Escolha os commits desta demanda — eles alimentam o resumo da IA e entram nos detalhes técnicos.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(b.wrappedValue.commits) { c in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(c.hash.prefix(8)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.titulo).font(.system(size: 12))
                        Text("\(c.autor) · \(c.data) · \(c.arquivos.count) arquivo(s)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { b.wrappedValue.commits.removeAll { $0.hash == c.hash } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
        }
    }

    private func exportarPDF(_ e: Entrega) {
        let p = NSSavePanel()
        p.nameFieldStringValue = "Entrega \(e.codigo.isEmpty ? "" : "#\(e.codigo) ")\(e.titulo)".trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-") + ".pdf"
        p.allowedContentTypes = [.pdf]
        guard p.runModal() == .OK, let u = p.url else { return }
        aviso = "Gerando o PDF…"
        GeradorPDF.gerar(html: store.html(e), para: u) { ok in
            aviso = ok ? "✓ PDF salvo" : "✗ Não consegui gerar o PDF"
            if ok { NSWorkspace.shared.activateFileViewerSelecting([u]) }
        }
    }
}

struct CartaoPrint: View {
    @Binding var print: PrintEntrega
    let remover: () -> Void
    @State private var imagem: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let imagem { Image(nsImage: imagem).resizable().scaledToFit() }
                    else { Rectangle().fill(.quaternary) }
                }
                .frame(height: 260)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture(count: 2) { NSWorkspace.shared.open(EntregasStore.pastaImagens.appendingPathComponent(print.arquivo)) }
                Button(action: remover) { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.borderless).foregroundStyle(.white, .black.opacity(0.5)).padding(6)
            }
            Picker("", selection: $print.momento) {
                Text("Antes").tag("Antes"); Text("Depois").tag("Depois"); Text("Outro").tag("Outro")
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)
            TextField("Legenda", text: $print.legenda, axis: .vertical).textFieldStyle(.roundedBorder).font(.caption).lineLimit(1...3)
        }
        .task(id: print.arquivo) { imagem = NSImage(contentsOf: EntregasStore.pastaImagens.appendingPathComponent(print.arquivo)) }
    }
}

struct EscolherCommits: View {
    @ObservedObject var store: EntregasStore
    @Binding var entrega: Entrega
    @Environment(\.dismiss) private var dismiss
    @State private var busca = ""
    @State private var lista: [CommitEntrega] = []
    @State private var marcados: Set<String> = []
    @State private var carregando = false
    @State private var origem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Commits da demanda").font(.headline)
            if let origem { Text(origem).font(.caption).foregroundStyle(.secondary) }
            HStack {
                TextField("Buscar na mensagem (ex.: o número da demanda)", text: $busca).textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await carregar() } }
                Button("Buscar") { Task { await carregar() } }
                Button("Todos da branch") {
                    Task {
                        carregando = true
                        if let r = await store.commitsDaBranch() {
                            lista = r.lista
                            marcados.formUnion(r.lista.map(\.hash))
                            origem = "Todos desde que a branch saiu de \(r.origem) (\(r.lista.count), merges incluídos)"
                        } else { origem = "Não achei a branch de origem (develop/main/master)." }
                        carregando = false
                    }
                }
                .help("Marca todos os commits da branch atual, incluindo merges que trouxeram funcionalidades de outras branches")
                if carregando { ProgressView().controlSize(.small) }
            }
            List(lista) { c in
                Toggle(isOn: Binding(get: { marcados.contains(c.hash) }, set: { if $0 { marcados.insert(c.hash) } else { marcados.remove(c.hash) } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            if c.merge == true {
                                Text("merge").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.purple)
                                    .padding(.horizontal, 5).background(Capsule().fill(Color.purple.opacity(0.12)))
                            }
                            Text(c.titulo).font(.system(size: 12))
                        }
                        Text("\(c.hash.prefix(8)) · \(c.autor) · \(c.data) · \(c.arquivos.count) arquivo(s)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .frame(height: 380)
            HStack {
                Text("\(marcados.count) selecionado(s)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Usar") {
                    let escolhidos = lista.filter { marcados.contains($0.hash) }
                    let antigos = entrega.commits.filter { marcados.contains($0.hash) && !escolhidos.contains($0) }
                    entrega.commits = antigos + escolhidos
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 640)
        .task {
            marcados = Set(entrega.commits.map(\.hash))
            busca = entrega.codigo
            await carregar()
            if lista.isEmpty && !busca.isEmpty { busca = ""; await carregar() }
        }
    }

    private func carregar() async {
        carregando = true
        lista = await store.commitsRecentes(busca)
        carregando = false
    }
}
