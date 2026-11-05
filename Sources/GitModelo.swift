import SwiftUI

// MARK: - Execução do git (stdout e stderr separados, sem prompts)

struct GitRes: Sendable {
    let code: Int32
    let out: String
    let err: String
    var ok: Bool { code == 0 }
    var msg: String { [out, err].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n") }
}

private final class Caixa: @unchecked Sendable { var dados = Data() }

enum GitCLI {
    static func run(_ pasta: String, _ args: [String]) async -> GitRes {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Shell.processo("git", ["-C", pasta, "-c", "color.ui=false", "-c", "core.quotepath=false"] + args,
                                       env: ["GIT_TERMINAL_PROMPT": "0", "GIT_EDITOR": "true", "GIT_MERGE_AUTOEDIT": "no",
                                             "GIT_SEQUENCE_EDITOR": "true"])
                let o = Pipe(), e = Pipe()
                p.standardOutput = o
                p.standardError = e
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(returning: GitRes(code: -1, out: "", err: error.localizedDescription))
                    return
                }
                let erro = Caixa()
                let grupo = DispatchGroup()
                grupo.enter()
                DispatchQueue.global().async { erro.dados = e.fileHandleForReading.readDataToEndOfFile(); grupo.leave() }
                let saida = o.fileHandleForReading.readDataToEndOfFile()
                grupo.wait()
                p.waitUntilExit()
                cont.resume(returning: GitRes(code: p.terminationStatus,
                                              out: String(decoding: saida, as: UTF8.self),
                                              err: String(decoding: erro.dados, as: UTF8.self)))
            }
        }
    }
}

// MARK: - Tipos

struct GCommit: Identifiable, Hashable, Sendable {
    let hash: String
    let pais: [String]
    let curto: String
    let titulo: String
    let autor: String
    let email: String
    let quando: String
    let data: String
    let refs: [String]
    var id: String { hash }
    var merge: Bool { pais.count > 1 }

    static let formato = "%H%x1f%P%x1f%h%x1f%s%x1f%an%x1f%ae%x1f%ar%x1f%ad%x1f%D%x1e"

    nonisolated static func parse(_ s: String) -> [GCommit] {
        s.components(separatedBy: "\u{1e}").compactMap { reg in
            let p = reg.trimmingCharacters(in: .newlines).components(separatedBy: "\u{1f}")
            guard p.count == 9 else { return nil }
            let refs = p[8].isEmpty ? [] : p[8].components(separatedBy: ", ")
            return GCommit(hash: p[0], pais: p[1].split(separator: " ").map(String.init), curto: p[2], titulo: p[3],
                           autor: p[4], email: p[5], quando: p[6], data: p[7], refs: refs)
        }
    }
}

struct SegGrafo: Sendable { let x1: Int; let y1: CGFloat; let x2: Int; let y2: CGFloat; let cor: Int }
struct LinhaGrafo: Sendable { let no: Int; let cor: Int; let segs: [SegGrafo] }

enum Grafo {
    /// Distribui os commits em "trilhos" (colunas) e gera os segmentos de cada linha.
    nonisolated static func montar(_ cs: [GCommit]) -> (linhas: [LinhaGrafo], colunas: Int) {
        var trilhos: [String?] = []
        var cores: [Int] = []
        var prox = 0
        var maxCol = 1
        var res: [LinhaGrafo] = []
        res.reserveCapacity(cs.count)
        for c in cs {
            let antes = trilhos, coresAntes = cores
            let idx: Int
            if let i = trilhos.firstIndex(of: c.hash) {
                idx = i
            } else if let f = trilhos.firstIndex(of: nil) {
                idx = f; cores[f] = prox; prox += 1
            } else {
                trilhos.append(nil); cores.append(prox); prox += 1; idx = trilhos.count - 1
            }
            let corNo = cores[idx]
            for k in trilhos.indices where k != idx && trilhos[k] == c.hash { trilhos[k] = nil }
            trilhos[idx] = c.pais.first
            for p in c.pais.dropFirst() where !trilhos.contains(p) {
                if let f = trilhos.firstIndex(of: nil) { trilhos[f] = p; cores[f] = prox }
                else { trilhos.append(p); cores.append(prox) }
                prox += 1
            }
            while let ultimo = trilhos.last, ultimo == nil { trilhos.removeLast(); cores.removeLast() }

            var segs: [SegGrafo] = []
            for (i, h) in antes.enumerated() {
                guard let h else { continue }
                if h == c.hash {
                    segs.append(SegGrafo(x1: i, y1: 0, x2: idx, y2: 0.5, cor: coresAntes[i]))
                } else if let j = (i < trilhos.count && trilhos[i] == h) ? i : trilhos.firstIndex(of: h) {
                    segs.append(SegGrafo(x1: i, y1: 0, x2: j, y2: 1, cor: coresAntes[i]))
                }
            }
            for p in c.pais {
                if let j = trilhos.firstIndex(of: p) { segs.append(SegGrafo(x1: idx, y1: 0.5, x2: j, y2: 1, cor: cores[j])) }
            }
            maxCol = max(maxCol, antes.count, trilhos.count, idx + 1)
            res.append(LinhaGrafo(no: idx, cor: corNo, segs: segs))
        }
        return (res, min(maxCol, 14))
    }
}

struct ArqMudado: Identifiable, Hashable, Sendable {
    let caminho: String
    let add: Int?
    let del: Int?
    var id: String { caminho }
    var binario: Bool { add == nil }

    /// Saída de `--numstat -z --no-renames`: "add\tdel\tcaminho\0"
    nonisolated static func parse(_ s: String) -> [ArqMudado] {
        s.components(separatedBy: "\0").compactMap { reg in
            let p = reg.trimmingCharacters(in: .newlines).split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard p.count == 3, !p[2].isEmpty else { return nil }
            return ArqMudado(caminho: String(p[2]), add: Int(p[0]), del: Int(p[1]))
        }
    }
}

struct ArqStatus: Identifiable, Hashable, Sendable {
    let caminho: String
    let x: Character
    let y: Character
    var id: String { caminho }
    var naoRastreado: Bool { x == "?" }
    var conflito: Bool { x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") }
    var preparado: Bool { !naoRastreado && !conflito && x != " " }
    var modificado: Bool { naoRastreado || conflito || y != " " }
    var rotulo: String { naoRastreado ? "novo" : conflito ? "conflito" : String([x, y]).replacingOccurrences(of: " ", with: "·") }

    nonisolated static func parse(_ s: String) -> [ArqStatus] {
        var res: [ArqStatus] = []
        let partes = s.components(separatedBy: "\0")
        var i = 0
        while i < partes.count {
            let r = partes[i]
            i += 1
            guard r.count > 3 else { continue }
            let cs = Array(r)
            res.append(ArqStatus(caminho: String(cs[3...]), x: cs[0], y: cs[1]))
            if cs[0] == "R" || cs[0] == "C" { i += 1 }   // o caminho antigo vem no próximo item
        }
        return res
    }
}

struct BranchLocal: Identifiable, Hashable, Sendable {
    let nome: String
    let upstream: String
    let frente: Int
    let atras: Int
    let sumiu: Bool
    let quando: String
    let autor: String
    let titulo: String
    var id: String { nome }
}

struct BranchRemota: Identifiable, Hashable, Sendable {
    let nome: String
    let quando: String
    let autor: String
    var id: String { nome }
}

struct StashItem: Identifiable, Hashable, Sendable {
    let ref: String
    let msg: String
    let quando: String
    var id: String { ref }
}

enum OperacaoGit: String, Sendable {
    case merge = "MERGE_HEAD", cherryPick = "CHERRY_PICK_HEAD", revert = "REVERT_HEAD"
    var nome: String {
        switch self { case .merge: "Merge"; case .cherryPick: "Cherry-pick"; case .revert: "Reversão" }
    }
}

enum ModoMerge: String, CaseIterable, Identifiable {
    case automatico, commitDeMerge, squash, soFastForward
    var id: String { rawValue }
    var titulo: String {
        switch self {
        case .automatico: "Padrão (fast-forward se der)"
        case .commitDeMerge: "Sempre criar commit de merge (--no-ff)"
        case .squash: "Squash (tudo em um commit só)"
        case .soFastForward: "Só fast-forward (--ff-only)"
        }
    }
    var usaMensagem: Bool { self == .commitDeMerge || self == .squash || self == .automatico }
}

struct RevisaoMerge: Sendable {
    let origem: String
    let destino: String
    let commits: [GCommit]
    let arquivos: [ArqMudado]
    /// nil = não foi possível prever; [] = sem conflitos
    let conflitosPrevistos: [String]?
    let fastForward: Bool
    var adicoes: Int { arquivos.compactMap(\.add).reduce(0, +) }
    var remocoes: Int { arquivos.compactMap(\.del).reduce(0, +) }
}

// MARK: - Prévia de comandos

struct PlanoGit: Identifiable {
    let id = UUID()
    let titulo: String
    let comandos: [[String]]
    let aviso: String
    let destrutivo: Bool

    /// Ações do dia a dia que só mexem no que vai no commit ou buscam do servidor
    var leve: Bool {
        comandos.allSatisfy { c in
            c.first == "add" || c.first == "fetch" || (c.first == "restore" && c.contains("--staged") && !c.contains("--worktree"))
        }
    }

    /// Como o comando ficaria digitado no terminal
    nonisolated static func texto(_ args: [String]) -> String {
        "git " + args.map { a in
            a.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@^~{}".contains($0) }) && !a.isEmpty
                ? a : "'" + a.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}

struct ComandoFeito: Identifiable {
    let id = UUID()
    let quando: Date
    let comando: String
    let codigo: Int32
    let saida: String
}

// MARK: - Diff

struct LinhaDiff: Identifiable, Sendable {
    enum Tipo: Sendable { case ctx, add, del, hunk, info }
    let id: Int
    let tipo: Tipo
    let velho: Int?
    let novo: Int?
    let texto: String

    nonisolated static func parse(_ s: String) -> [LinhaDiff] {
        var res: [LinhaDiff] = []
        var noBloco = false
        var v = 0, n = 0
        func add(_ t: Tipo, _ a: Int?, _ b: Int?, _ txt: String) { res.append(LinhaDiff(id: res.count, tipo: t, velho: a, novo: b, texto: txt)) }
        for sub in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(sub)
            if l.hasPrefix("diff --git") || l.hasPrefix("diff --cc") || l.hasPrefix("diff --combined") { noBloco = false; continue }
            if l.hasPrefix("@@") {
                noBloco = true
                // @@ -a,b +c,d @@ contexto
                let nums = l.split(separator: " ")
                if nums.count > 2 {
                    v = Int(nums[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    n = Int(nums[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                add(.hunk, nil, nil, l)
                continue
            }
            if !noBloco {
                if l.hasPrefix("Binary files") { add(.info, nil, nil, "Arquivo binário — sem visualização de texto") }
                else if l.hasPrefix("new file mode") { add(.info, nil, nil, "Arquivo novo") }
                else if l.hasPrefix("deleted file mode") { add(.info, nil, nil, "Arquivo apagado") }
                continue
            }
            if l.hasPrefix("+") { add(.add, nil, n, String(l.dropFirst())); n += 1 }
            else if l.hasPrefix("-") { add(.del, v, nil, String(l.dropFirst())); v += 1 }
            else if l.hasPrefix("\\") { add(.info, nil, nil, "Sem quebra de linha no fim do arquivo") }
            else if l.isEmpty { continue }
            else { add(.ctx, v, n, String(l.dropFirst())); v += 1; n += 1 }
        }
        return res
    }
}

// MARK: - Modelo

@MainActor
final class GitModel: ObservableObject {
    enum Aba: String, CaseIterable, Identifiable {
        case linha = "Linha do tempo", alteracoes = "Alterações", branches = "Branches", mesclar = "Revisar e mesclar"
        var id: String { rawValue }
        var icone: String {
            switch self {
            case .linha: "point.3.connected.trianglepath.dotted"
            case .alteracoes: "pencil.and.list.clipboard"
            case .branches: "arrow.triangle.branch"
            case .mesclar: "arrow.triangle.merge"
            }
        }
    }

    let projeto: String
    @Published var aba: Aba = .linha
    @Published var repo = true
    @Published var branch = ""
    @Published var upstream = ""
    @Published var frente = 0
    @Published var atras = 0
    @Published var locais: [BranchLocal] = []
    @Published var remotas: [BranchRemota] = []
    @Published var arquivos: [ArqStatus] = []
    @Published var stashes: [StashItem] = []
    @Published var operacao: OperacaoGit?
    @Published var commits: [GCommit] = []
    @Published var linhas: [LinhaGrafo] = []
    @Published var colunas = 1
    @Published var todasBranches = true
    @Published var limite = 300
    @Published var ocupado = false
    @Published var saida = ""
    @Published var falhou = false
    // Revisão de merge (compartilhado entre as abas)
    @Published var mergeOrigem = ""
    @Published var mergeDestino = ""
    @Published var revisao: RevisaoMerge?
    @Published var revisados: Set<String> = []
    @Published var desfazerMerge: (antes: String, depois: String, texto: String)?

    @Published var plano: PlanoGit?
    @Published var registro: [ComandoFeito] = []
    private var resposta: CheckedContinuation<Bool, Never>?

    init(projeto: String) { self.projeto = projeto }
    var pasta: String { Config.pasta(projeto) }
    var conflitos: [ArqStatus] { arquivos.filter(\.conflito) }
    var head: String? { commits.first { $0.refs.contains { $0.hasPrefix("HEAD") } }?.hash }

    func git(_ args: [String]) async -> GitRes { await GitCLI.run(pasta, args) }

    // MARK: carregar

    func carregar() async {
        let raiz = await git(["rev-parse", "--is-inside-work-tree"])
        repo = raiz.ok
        guard repo else { return }
        async let s = carregarEstado()
        async let l = carregarLinha()
        _ = await (s, l)
    }

    func carregarEstado() async {
        let b = await git(["branch", "--show-current"])
        branch = b.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if branch.isEmpty { branch = "(sem branch — HEAD solto)" }
        let up = await git(["rev-parse", "--abbrev-ref", "@{upstream}"])
        upstream = up.ok ? up.out.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let ab = (await git(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"])).out.split(whereSeparator: \.isWhitespace)
        frente = ab.count == 2 ? Int(ab[0]) ?? 0 : 0
        atras = ab.count == 2 ? Int(ab[1]) ?? 0 : 0

        let st = await git(["status", "--porcelain=v1", "-z", "-uall"])
        arquivos = ArqStatus.parse(st.out)

        let refs = await git(["for-each-ref", "refs/heads", "--sort=-committerdate",
                              "--format=%(refname:short)%1f%(upstream:short)%1f%(upstream:track,nobracket)%1f%(committerdate:relative)%1f%(authorname)%1f%(contents:subject)"])
        locais = refs.out.split(separator: "\n").compactMap { l in
            let p = l.components(separatedBy: "\u{1f}")
            guard p.count == 6 else { return nil }
            func num(_ chave: String) -> Int {
                guard let r = p[2].range(of: chave + " ") else { return 0 }
                return Int(p[2][r.upperBound...].prefix { $0.isNumber }) ?? 0
            }
            return BranchLocal(nome: p[0], upstream: p[1], frente: num("ahead"), atras: num("behind"),
                               sumiu: p[2] == "gone", quando: p[3], autor: p[4], titulo: p[5])
        }
        let rem = await git(["for-each-ref", "refs/remotes", "--sort=-committerdate",
                             "--format=%(refname:short)%1f%(committerdate:relative)%1f%(authorname)%1f%(symref)"])
        remotas = rem.out.split(separator: "\n").compactMap { l in
            let p = l.components(separatedBy: "\u{1f}")
            guard p.count == 4, p[3].isEmpty, p[0].contains("/") else { return nil }   // ignora origin/HEAD
            return BranchRemota(nome: p[0], quando: p[1], autor: p[2])
        }

        let sl = await git(["stash", "list", "--format=%gd%x1f%s%x1f%cr"])
        stashes = sl.out.split(separator: "\n").compactMap { l in
            let p = l.components(separatedBy: "\u{1f}")
            return p.count == 3 ? StashItem(ref: p[0], msg: p[1], quando: p[2]) : nil
        }

        operacao = nil
        for op in [OperacaoGit.merge, .cherryPick, .revert] {
            if (await git(["rev-parse", "-q", "--verify", op.rawValue])).ok { operacao = op; break }
        }
        if mergeDestino.isEmpty || !locais.contains(where: { $0.nome == mergeDestino }) {
            mergeDestino = locais.contains { $0.nome == branch } ? branch : (locais.first?.nome ?? "")
        }
    }

    func carregarLinha() async {
        var args = ["log", "--topo-order", "-n", "\(limite)", "--date=format:%d/%m/%Y %H:%M", "--format=\(GCommit.formato)"]
        if todasBranches { args += ["--exclude=refs/stash", "--all"] } else { args += ["HEAD"] }
        let r = await git(args)
        let cs = await Task.detached { GCommit.parse(r.out) }.value
        let g = await Task.detached { Grafo.montar(cs) }.value
        commits = cs
        linhas = g.linhas
        colunas = g.colunas
    }

    // MARK: ações (todo comando que altera algo passa pela prévia)

    /// Pede confirmação mostrando os comandos exatos. Suspende até o usuário responder.
    func confirmar(_ p: PlanoGit) async -> Bool {
        if p.leve && UserDefaults.standard.bool(forKey: "git.leveDireto") { return true }
        resposta?.resume(returning: false)
        return await withCheckedContinuation { c in
            resposta = c
            plano = p
        }
    }

    func responder(_ ok: Bool) {
        plano = nil
        resposta?.resume(returning: ok)
        resposta = nil
    }

    /// Roda os comandos em sequência (para no primeiro erro) e registra cada um.
    func rodar(_ cmds: [[String]]) async -> GitRes {
        var ultimo = GitRes(code: 0, out: "", err: "")
        var textos: [String] = []
        for cmd in cmds {
            let r = await git(cmd)
            registro.insert(ComandoFeito(quando: Date(), comando: PlanoGit.texto(cmd), codigo: r.code, saida: r.msg), at: 0)
            if registro.count > 300 { registro.removeLast() }
            if !r.msg.isEmpty { textos.append(r.msg) }
            ultimo = GitRes(code: r.code, out: textos.joined(separator: "\n"), err: "")
            if !r.ok { break }
        }
        return ultimo
    }

    @discardableResult
    func acao(_ args: [String], _ rotulo: String, aviso: String = "", destrutivo: Bool = false) async -> Bool {
        await acao([args], rotulo, aviso: aviso, destrutivo: destrutivo)
    }

    @discardableResult
    func acao(_ cmds: [[String]], _ rotulo: String, aviso: String = "", destrutivo: Bool = false) async -> Bool {
        guard await confirmar(PlanoGit(titulo: rotulo, comandos: cmds, aviso: aviso, destrutivo: destrutivo)) else { return false }
        ocupado = true
        let r = await rodar(cmds)
        falhou = !r.ok
        if !r.ok && AwsSSO.erroDeLogin(r.msg) {
            saida = "✗ \(rotulo) — o login da AWS expirou (o git usa o CodeCommit). Faça login e tente de novo.\n(token has expired)"
            Task { await AwsSSO.compartilhado.verificar() }
        } else {
            saida = r.ok ? "✓ \(rotulo)" + (r.msg.isEmpty ? "" : "\n" + r.msg) : "✗ \(rotulo) — falhou\n" + r.msg
        }
        await carregar()
        ocupado = false
        return r.ok
    }

    // MARK: detalhes

    func corpo(_ hash: String) async -> String {
        (await git(["show", "-s", "--format=%b", hash])).out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func arquivosDoCommit(_ c: GCommit) async -> [ArqMudado] {
        let r = c.pais.isEmpty
            ? await git(["show", "--format=", "--numstat", "-z", "--no-renames", c.hash])
            : await git(["diff", "--numstat", "-z", "--no-renames", c.pais[0], c.hash])
        return ArqMudado.parse(r.out)
    }

    func diffDoCommit(_ c: GCommit, _ caminho: String) async -> String {
        c.pais.isEmpty
            ? (await git(["show", "--format=", "--no-renames", c.hash, "--", caminho])).out
            : (await git(["diff", "--no-renames", c.pais[0], c.hash, "--", caminho])).out
    }

    func diffLocal(_ a: ArqStatus, preparado: Bool) async -> String {
        if a.naoRastreado {
            return (await git(["diff", "--no-index", "--", "/dev/null", a.caminho])).out
        }
        if a.conflito {
            let txt = (try? String(contentsOfFile: "\(pasta)/\(a.caminho)", encoding: .utf8)) ?? ""
            return "@@ -1 +1 @@\n" + txt.split(separator: "\n", omittingEmptySubsequences: false).map { " " + $0 }.joined(separator: "\n")
        }
        return (await git(preparado ? ["diff", "--cached", "--", a.caminho] : ["diff", "--", a.caminho])).out
    }

    // MARK: revisão de merge

    func revisar() async {
        let o = mergeOrigem, d = mergeDestino
        guard !o.isEmpty, !d.isEmpty, o != d else { return }
        ocupado = true
        revisao = nil
        revisados = []
        let cs = GCommit.parse((await git(["log", "--date=format:%d/%m/%Y %H:%M", "--format=\(GCommit.formato)", "\(d)..\(o)"])).out)
        let arqs = ArqMudado.parse((await git(["diff", "--numstat", "-z", "--no-renames", "\(d)...\(o)"])).out)
        let mt = await git(["merge-tree", "--write-tree", "--name-only", "--no-messages", d, o])
        let previstos: [String]?
        switch mt.code {
        case 0: previstos = []
        case 1: previstos = Array(mt.out.split(separator: "\n").dropFirst().map(String.init).filter { !$0.isEmpty })
        default: previstos = nil
        }
        let ff = (await git(["merge-base", "--is-ancestor", d, o])).ok
        revisao = RevisaoMerge(origem: o, destino: d, commits: cs, arquivos: arqs, conflitosPrevistos: previstos, fastForward: ff)
        ocupado = false
    }

    func diffDoMerge(_ r: RevisaoMerge, _ caminho: String) async -> String {
        (await git(["diff", "--no-renames", "\(r.destino)...\(r.origem)", "--", caminho])).out
    }

    func comandosMerge(_ r: RevisaoMerge, modo: ModoMerge, mensagem: String) -> [[String]] {
        let msg = mensagem.trimmingCharacters(in: .whitespacesAndNewlines)
        var cmds: [[String]] = branch == r.destino ? [] : [["switch", r.destino]]
        switch modo {
        case .automatico: cmds.append(["merge", "--no-edit"] + (msg.isEmpty ? [] : ["-m", msg]) + [r.origem])
        case .commitDeMerge: cmds.append(["merge", "--no-ff", "--no-edit"] + (msg.isEmpty ? [] : ["-m", msg]) + [r.origem])
        case .soFastForward: cmds.append(["merge", "--ff-only", r.origem])
        case .squash:
            cmds.append(["merge", "--squash", r.origem])
            cmds.append(["commit", "-m", msg.isEmpty ? "Squash de \(r.origem) em \(r.destino)" : msg])
        }
        return cmds
    }

    func executarMerge(_ r: RevisaoMerge, modo: ModoMerge, mensagem: String, aviso: String) async {
        let cmds = comandosMerge(r, modo: modo, mensagem: mensagem)
        guard await confirmar(PlanoGit(titulo: "Mesclar \(r.origem) em \(r.destino)", comandos: cmds, aviso: aviso, destrutivo: false)) else { return }
        ocupado = true
        defer { ocupado = false }
        let antes = (await git(["rev-parse", r.destino])).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let res = await rodar(cmds)
        await carregar()
        if res.ok {
            falhou = false
            let depois = (await git(["rev-parse", "HEAD"])).out.trimmingCharacters(in: .whitespacesAndNewlines)
            saida = "✓ \(r.origem) mesclada em \(r.destino)\n" + res.msg
            desfazerMerge = (antes, depois, "\(r.origem) → \(r.destino)")
            revisao = nil
            revisados = []
            Shell.notificar(projeto, "Merge concluído: \(r.origem) → \(r.destino)", som: "Glass")
        } else {
            falhou = true
            saida = conflitos.isEmpty ? "✗ O merge não foi feito\n" + res.msg
                : "⚠ Merge parou com \(conflitos.count) conflito(s). Resolva na aba Alterações ou aborte.\n" + res.msg
            desfazerMerge = nil
            if !conflitos.isEmpty { aba = .alteracoes }
        }
    }

    /// Volta ao estado de antes do merge feito pelo app (só se nada mudou desde então).
    func desfazerUltimoMerge() async {
        guard let d = desfazerMerge else { return }
        let atual = (await git(["rev-parse", "HEAD"])).out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard atual == d.depois else {
            falhou = true
            saida = "✗ Houve commits depois do merge — desfazer por aqui não é seguro."
            desfazerMerge = nil
            return
        }
        if await acao(["reset", "--keep", d.antes], "Desfazer o merge \(d.texto)",
                      aviso: "A branch volta exatamente para onde estava antes do merge. Alterações não commitadas são mantidas (o git recusa se conflitarem).",
                      destrutivo: true) { desfazerMerge = nil }
    }

    // MARK: operação em andamento

    func abortarOperacao() async {
        let aviso = "Os arquivos voltam ao estado de antes da operação. O que você já resolveu nos conflitos é descartado."
        switch operacao {
        case .merge: await acao(["merge", "--abort"], "Abortar o merge", aviso: aviso, destrutivo: true)
        case .cherryPick: await acao(["cherry-pick", "--abort"], "Abortar o cherry-pick", aviso: aviso, destrutivo: true)
        case .revert: await acao(["revert", "--abort"], "Abortar a reversão", aviso: aviso, destrutivo: true)
        case nil: await acao(["reset", "--merge"], "Desfazer o merge com conflito", aviso: aviso, destrutivo: true)   // squash não deixa MERGE_HEAD
        }
    }

    func concluirOperacao() async {
        switch operacao {
        case .merge, nil: await acao(["commit", "--no-edit"], "Concluir o merge", aviso: "Cria o commit de merge com os conflitos já resolvidos.")
        case .cherryPick: await acao(["cherry-pick", "--continue"], "Concluir o cherry-pick")
        case .revert: await acao(["revert", "--continue"], "Concluir a reversão")
        }
    }

    func aindaTemMarcadores(_ caminho: String) -> Bool {
        let txt = (try? String(contentsOfFile: "\(pasta)/\(caminho)", encoding: .utf8)) ?? ""
        return txt.contains("\n<<<<<<< ") || txt.hasPrefix("<<<<<<< ") || txt.contains("\n>>>>>>> ")
    }
}
