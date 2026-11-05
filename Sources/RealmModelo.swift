import SwiftUI
import CryptoKit

// MARK: - Visualizador/editor de Realm
//
// O trabalho pesado fica num processo Node ("realm-motor.cjs") que usa o pacote "realm" do próprio
// projeto — a mesma versão do app, então o arquivo nunca muda de formato. O app sempre abre uma
// CÓPIA de trabalho: o backup original e o banco do celular só mudam quando o usuário manda.

struct RCampo: Identifiable, Hashable {
    let nome: String
    let tipo: String          // string, int, list, object, linkingObjects…
    let objectType: String?
    let opcional: Bool
    let indexado: Bool
    let primario: Bool
    var id: String { nome }

    static let primitivos: Set<String> = ["string", "int", "float", "double", "bool", "date", "objectId", "uuid", "decimal128", "data", "mixed"]

    var tipoTexto: String {
        let base: String
        switch tipo {
        case "list": base = "\(objectType ?? "?")[]"
        case "set": base = "\(objectType ?? "?")<>"
        case "dictionary": base = "\(objectType ?? "?"){}"
        case "object": base = objectType ?? "object"
        case "linkingObjects": base = "← \(objectType ?? "?")"
        default: base = tipo
        }
        return base + (opcional && tipo != "linkingObjects" ? "?" : "")
    }
    var ehLink: Bool { tipo == "object" && !(objectType.map { RCampo.primitivos.contains($0) } ?? true) }
    var ehColecao: Bool { ["list", "set", "dictionary", "linkingObjects"].contains(tipo) }
    var colecaoDeObjetos: Bool { ehColecao && !(objectType.map { RCampo.primitivos.contains($0) } ?? true) }
}

struct RClasse: Identifiable, Hashable {
    let nome: String
    let chave: String?
    let embutida: Bool
    let campos: [RCampo]
    var id: String { nome }
}

struct RLinha: Identifiable {
    let key: String
    let valores: [String: Any]
    var id: String { key }
}

struct RApontador: Identifiable {
    let cls: String
    let campo: String
    let total: Int
    let filtro: String
    let itens: [(key: String, label: String)]
    var id: String { "\(cls).\(campo)" }
}

struct RDetalhe {
    let cls: String
    let key: String
    let label: String
    let valores: [String: Any]
    let apontam: [RApontador]
}

enum OrigemRealm: Equatable {
    case arquivo(URL)
    case celular(serial: String, pacote: String, arquivo: String)
    case backup(URL)

    var descricao: String {
        switch self {
        case .arquivo(let u): return u.lastPathComponent
        case .backup(let u): return "\(u.lastPathComponent) · banco.realm"
        case .celular(_, let p, let a): return "\(p) · files/\(a)"
        }
    }
}

/// Conteúdo de um backup .zip gerado pelo app (banco.realm, async_storage.json, imei.json, arquivos_usuario/)
struct ConteudoBackup {
    let zip: URL
    let pasta: URL
    var storage: [ItemStorage]
    var storageEditado = false
    let imei: String?
    let dataBackup: Date?
    let arquivos: [URL]
    let banco: URL?
    let extras: [String]

    var tamanhoArquivos: Int64 {
        arquivos.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

// MARK: - Processo do motor

@MainActor
final class MotorRealm {
    private var proc: Process?
    private var entrada: FileHandle?
    private var buffer = Data()
    private var proximo = 1
    private var pendentes: [Int: CheckedContinuation<Result<Any, Falha>, Never>] = [:]
    private var pronto: CheckedContinuation<Result<Any, Falha>, Never>?
    private(set) var versao = ""
    private var stderr = ""

    var rodando: Bool { proc?.isRunning == true }

    static var script: String? {
        if let u = Bundle.main.url(forResource: "realm-motor", withExtension: "cjs") { return u.path }
        let dev = "\(Config.home)/BuildRemoto/Resources/realm-motor.cjs"
        return FileManager.default.fileExists(atPath: dev) ? dev : nil
    }

    /// Pasta de um projeto com o pacote realm instalado (de preferência o projeto atual)
    static func projetoComRealm(_ preferido: String) -> String? {
        let candidatos = [Config.pasta(preferido)] + Config.projetos.map { Config.pasta($0) }
        return candidatos.first { FileManager.default.fileExists(atPath: "\($0)/node_modules/realm/package.json") }
    }

    func iniciar(_ projeto: String) async -> Result<Void, Falha> {
        if rodando { return .success(()) }
        guard let script = Self.script else { return .failure(Falha("Motor do Realm não encontrado no app.")) }
        guard let pasta = Self.projetoComRealm(projeto) else {
            return .failure(Falha("Nenhum projeto com o pacote \"realm\" instalado. Rode \"Dependências\" (yarn install) num app que usa Realm."))
        }
        let p = Shell.processo("zsh", ["-lc", "cd \(Adb.aspas(pasta)) && \(Shell.prepararNode)\nexec node \(Adb.aspas(script)) \(Adb.aspas(pasta + "/node_modules/realm"))"])
        let ent = Pipe(), sai = Pipe(), err = Pipe()
        p.standardInput = ent
        p.standardOutput = sai
        p.standardError = err
        sai.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            Task { @MainActor in self?.receber(d) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let t = String(decoding: h.availableData, as: UTF8.self)
            Task { @MainActor in self?.stderr = String(((self?.stderr ?? "") + t).suffix(4000)) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.terminou() }
        }
        do { try p.run() } catch { return .failure(Falha("Não consegui iniciar o Node: \(error.localizedDescription)")) }
        proc = p
        entrada = ent.fileHandleForWriting
        let r = await withCheckedContinuation { c in pronto = c }
        switch r {
        case .success(let v):
            versao = ((v as? [String: Any])?["versao"] as? String) ?? ""
            return .success(())
        case .failure(let f): return .failure(f)
        }
    }

    private func terminou() {
        let msg = stderr.isEmpty ? "O motor do Realm parou." : "O motor do Realm parou:\n" + stderr.suffix(1500)
        pronto?.resume(returning: .failure(Falha(msg)))
        pronto = nil
        for (_, c) in pendentes { c.resume(returning: .failure(Falha(msg))) }
        pendentes = [:]
        proc = nil
        entrada = nil
    }

    private func receber(_ d: Data) {
        buffer.append(d)
        while let i = buffer.firstIndex(of: 0x0A) {
            let linha = buffer[buffer.startIndex..<i]
            buffer.removeSubrange(buffer.startIndex...i)
            guard let obj = try? JSONSerialization.jsonObject(with: linha, options: [.fragmentsAllowed]) as? [String: Any],
                  let id = obj["id"] as? Int else { continue }
            let res: Result<Any, Falha> = (obj["ok"] as? Bool) == true ? .success(obj["r"] ?? NSNull())
                : .failure(Falha((obj["erro"] as? String) ?? "erro desconhecido"))
            if id == 0 { pronto?.resume(returning: res); pronto = nil }
            else { pendentes.removeValue(forKey: id)?.resume(returning: res) }
        }
    }

    func enviar(_ cmd: String, _ args: [String: Any] = [:]) async -> Result<Any, Falha> {
        guard let entrada, rodando else { return .failure(Falha("O motor do Realm não está rodando.")) }
        let id = proximo
        proximo += 1
        var q = args
        q["id"] = id
        q["cmd"] = cmd
        guard var dados = try? JSONSerialization.data(withJSONObject: q) else { return .failure(Falha("Valor inválido")) }
        dados.append(0x0A)
        return await withCheckedContinuation { c in
            pendentes[id] = c
            entrada.write(dados)
        }
    }

    func parar() {
        proc?.terminate()
        proc = nil
    }
}

// MARK: - Modelo da tela

@MainActor
final class RealmModel: ObservableObject {
    let projeto: String
    let motor = MotorRealm()

    @Published var carregando: String?
    @Published var erro: String?
    @Published var origem: OrigemRealm?
    @Published var copia: URL?
    @Published var schemaVersion = 0
    @Published var tamanho: Int64 = 0
    @Published var classes: [RClasse] = []
    @Published var contagens: [String: Int] = [:]
    @Published var classe: String?
    @Published var filtro = ""
    @Published var erroFiltro: String?
    @Published var ordem: String?
    @Published var desc = false
    @Published var pagina = 0
    let limite = 200
    @Published var total = 0
    @Published var linhas: [RLinha] = []
    @Published var selecao: Set<String> = []
    @Published var detalhe: RDetalhe?
    @Published var alteracoes = 0
    @Published var atualizadoEm: Date?
    @Published var autoAtualizar = false
    @Published var filtrosRecentes: [String] = []
    @Published var aviso: String?
    @Published var backup: ConteudoBackup?
    private var voltar: [(String, String)] = []
    private var tarefaAuto: Task<Void, Never>?

    init(projeto: String) {
        self.projeto = projeto
        filtrosRecentes = UserDefaults.standard.stringArray(forKey: "realm.filtros.\(projeto)") ?? []
    }

    var classeAtual: RClasse? { classes.first { $0.nome == classe } }
    var podeVoltar: Bool { !voltar.isEmpty }
    var doCelular: Bool { if case .celular = origem { return true } else { return false } }

    private var pastaTrabalho: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BuildRemoto/realm/\(projeto)")
    }
    static var pastaBackups: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/BuildRemoto/Realm")
    }

    // MARK: abrir

    func abrirArquivo(_ url: URL) async {
        if url.pathExtension.lowercased() == "zip" { await abrirBackup(url); return }
        guard confirmarDescarte() else { return }
        backup = nil
        carregando = "Copiando o arquivo…"
        let destino = novaCopia(url.lastPathComponent)
        do { try FileManager.default.copyItem(at: url, to: destino) } catch {
            erro = "Não consegui copiar: \(error.localizedDescription)"; carregando = nil; return
        }
        await abrirCopia(destino, origem: .arquivo(url))
    }

    /// Extrai o .zip de backup do app e abre o banco e o AsyncStorage
    func abrirBackup(_ url: URL) async {
        guard confirmarDescarte() else { return }
        carregando = "Extraindo o backup…"
        let pasta = pastaTrabalho.appendingPathComponent("backup-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        let r = await Shell.run("/usr/bin/ditto", ["-x", "-k", url.path, pasta.path])
        guard r.ok else { erro = "Não consegui extrair o .zip: \(r.out)"; carregando = nil; return }
        let fm = FileManager.default
        var todos: [URL] = []
        if let e = fm.enumerator(at: pasta, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let u as URL in e.allObjects where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && !u.lastPathComponent.hasPrefix(".") && !u.path.contains("__MACOSX") { todos.append(u) }
        }
        let banco = todos.first { $0.lastPathComponent == "banco.realm" } ?? todos.first { $0.pathExtension == "realm" }
        let storageURL = todos.first { $0.lastPathComponent == "async_storage.json" }
        let imeiURL = todos.first { $0.lastPathComponent == "imei.json" }
        var storage: [ItemStorage] = []
        if let storageURL, let d = try? Data(contentsOf: storageURL),
           let pares = try? JSONSerialization.jsonObject(with: d) as? [[Any]] {
            storage = pares.compactMap { p in
                guard p.count >= 2, let k = p[0] as? String else { return nil }
                return ItemStorage(chave: k, valor: p[1] as? String ?? RealmFmt.json(p[1]))
            }.sorted { $0.chave < $1.chave }
        }
        var imei: String?, data: Date?
        if let imeiURL, let d = try? Data(contentsOf: imeiURL), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            imei = o["imei"].map { "\($0)" }
            data = (o["data"] as? String).flatMap(RealmFmt.dataDe)
        }
        let midia = todos.filter { $0.deletingLastPathComponent().lastPathComponent == "arquivos_usuario" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let conhecidos = Set([banco, storageURL, imeiURL].compactMap { $0 } + midia)
        let extras = todos.filter { !conhecidos.contains($0) }.map { String($0.path.dropFirst(pasta.path.count + 1)) }
        let anterior = backup?.pasta
        backup = ConteudoBackup(zip: url, pasta: pasta, storage: storage, imei: imei, dataBackup: data,
                                arquivos: midia, banco: banco, extras: extras)
        if let anterior { try? fm.removeItem(at: anterior) }
        if let banco {
            let copiaBanco = novaCopia("banco.realm")
            try? fm.copyItem(at: banco, to: copiaBanco)
            await abrirCopia(copiaBanco, origem: .backup(url))
        } else {
            origem = .backup(url)
            copia = nil
            classes = []; linhas = []; detalhe = nil
            carregando = nil
        }
    }

    func editarStorage(_ chave: String, _ valor: String?) {
        guard var b = backup else { return }
        if let valor {
            if let i = b.storage.firstIndex(where: { $0.chave == chave }) { b.storage[i] = ItemStorage(chave: chave, valor: valor) }
            else { b.storage.append(ItemStorage(chave: chave, valor: valor)); b.storage.sort { $0.chave < $1.chave } }
        } else {
            b.storage.removeAll { $0.chave == chave }
        }
        b.storageEditado = true
        backup = b
    }

    /// Monta um .zip novo no mesmo formato do app, com o banco e o AsyncStorage como estão agora
    func gerarZip(_ destino: URL) async {
        guard let b = backup else { return }
        carregando = "Gerando o .zip…"
        defer { carregando = nil }
        let fm = FileManager.default
        let pasta = pastaTrabalho.appendingPathComponent("novo-zip-\(UUID().uuidString.prefix(6))")
        defer { try? fm.removeItem(at: pasta) }
        do { try fm.copyItem(at: b.pasta, to: pasta) } catch { aviso = error.localizedDescription; return }
        if copia != nil, let banco = b.banco {
            let rel = String(banco.path.dropFirst(b.pasta.path.count + 1))
            let alvo = pasta.appendingPathComponent(rel)
            try? fm.removeItem(at: alvo)
            if case .failure(let f) = await motor.enviar("copiar", ["destino": alvo.path]) { aviso = f.texto; return }
        }
        if b.storageEditado || fm.fileExists(atPath: pasta.appendingPathComponent("async_storage.json").path) {
            let pares = b.storage.map { [$0.chave, $0.valor] }
            if let d = try? JSONSerialization.data(withJSONObject: pares, options: [.withoutEscapingSlashes]) {
                try? d.write(to: pasta.appendingPathComponent("async_storage.json"))
            }
        }
        try? fm.removeItem(at: destino)
        let r = await Shell.run("/bin/zsh", ["-c", "cd \(Adb.aspas(pasta.path)) && /usr/bin/zip -qr -X \(Adb.aspas(destino.path)) . -x '.*' -x '__MACOSX/*'"])
        if r.ok {
            aviso = "✓ Backup gerado: \(destino.lastPathComponent) — dá para restaurar no app pela importação de backup."
            NSWorkspace.shared.activateFileViewerSelecting([destino])
        } else {
            aviso = "✗ Falha ao gerar o .zip: \(r.out)"
        }
    }

    func abrirCelular(_ d: Dispositivo, pacote: String, arquivo: String, manterPosicao: Bool = false) async {
        carregando = "Baixando files/\(arquivo) do celular…"
        guard let dados = await Adb.dados(d, ["exec-out", "run-as", pacote, "cat", "files/\(arquivo)"]), dados.count > 100,
              !String(decoding: dados.prefix(80), as: UTF8.self).contains("run-as:") else {
            erro = "Não consegui ler files/\(arquivo). Só funciona com o app em build de debug (run-as)."
            carregando = nil
            return
        }
        let destino = novaCopia(arquivo)
        do { try dados.write(to: destino) } catch { erro = error.localizedDescription; carregando = nil; return }
        if !manterPosicao { backup = nil }
        await abrirCopia(destino, origem: .celular(serial: d.serial, pacote: pacote, arquivo: arquivo), manterPosicao: manterPosicao)
    }

    /// Arquivos .realm do app no celular
    static func arquivosNoCelular(_ d: Dispositivo, pacote: String) async -> Result<[String], Falha> {
        let r = await Adb.shell(d, "run-as \(pacote) ls files")
        if r.out.contains("run-as:") || r.out.contains("not debuggable") {
            return .failure(Falha("O celular não deixa ler os dados de \(pacote): só funciona com build de debug instalado."))
        }
        let arqs = r.out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasSuffix(".realm") }
        return arqs.isEmpty ? .failure(Falha("Nenhum arquivo .realm em files/ de \(pacote). O app já abriu o banco alguma vez?")) : .success(arqs)
    }

    private func novaCopia(_ nome: String) -> URL {
        let dir = pastaTrabalho.appendingPathComponent(UUID().uuidString.prefix(8).description)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(nome.hasSuffix(".realm") ? nome : nome + ".realm")
    }

    private func abrirCopia(_ url: URL, origem nova: OrigemRealm, manterPosicao: Bool = false) async {
        carregando = "Iniciando o motor do Realm…"
        erro = nil
        if case .failure(let f) = await motor.iniciar(projeto) { erro = f.texto; carregando = nil; return }
        carregando = "Abrindo o banco…"
        let r = await motor.enviar("abrir", ["path": url.path])
        carregando = nil
        guard case .success(let v) = r, let info = v as? [String: Any] else {
            if case .failure(let f) = r { erro = "Não consegui abrir o banco: \(f.texto)" }
            return
        }
        let anterior = copia
        origem = nova
        copia = url
        alteracoes = 0
        atualizadoEm = Date()
        lerInfo(info)
        if let anterior, anterior != url { try? FileManager.default.removeItem(at: anterior.deletingLastPathComponent()) }
        if !manterPosicao || classe == nil || !classes.contains(where: { $0.nome == classe }) {
            classe = classes.first { !$0.embutida && (contagens[$0.nome] ?? 0) > 0 }?.nome ?? classes.first { !$0.embutida }?.nome
            filtro = ""; ordem = nil; pagina = 0; detalhe = nil; voltar = []
        }
        await consultar()
        if manterPosicao, let d = detalhe { await abrirObjeto(d.cls, d.key, empilhar: false) }
    }

    private func lerInfo(_ info: [String: Any]) {
        schemaVersion = info["schemaVersion"] as? Int ?? 0
        tamanho = (info["tamanho"] as? NSNumber)?.int64Value ?? 0
        contagens = (info["contagens"] as? [String: Any] ?? [:]).compactMapValues { $0 as? Int }
        classes = (info["classes"] as? [[String: Any]] ?? []).map { c in
            let pk = c["primaryKey"] as? String
            return RClasse(nome: c["name"] as? String ?? "?", chave: pk, embutida: c["embedded"] as? Bool ?? false,
                           campos: (c["properties"] as? [[String: Any]] ?? []).map { p in
                               let nome = p["name"] as? String ?? "?"
                               return RCampo(nome: nome, tipo: p["type"] as? String ?? "?", objectType: p["objectType"] as? String,
                                             opcional: p["optional"] as? Bool ?? false, indexado: p["indexed"] as? Bool ?? false,
                                             primario: nome == pk)
                           }.sorted { a, b in a.primario != b.primario ? a.primario : false })
        }.sorted { $0.nome.localizedCaseInsensitiveCompare($1.nome) == .orderedAscending }
    }

    func atualizarInfo() async {
        if case .success(let v) = await motor.enviar("info"), let info = v as? [String: Any] { lerInfo(info) }
    }

    // MARK: consultar

    func escolher(_ c: String) async {
        guard c != classe else { return }
        classe = c
        filtro = ""; ordem = nil; desc = false; pagina = 0; selecao = []; erroFiltro = nil
        await consultar()
    }

    func consultar() async {
        guard let classe, classeAtual?.embutida == false else { linhas = []; total = 0; return }
        var args: [String: Any] = ["cls": classe, "filtro": filtro, "offset": pagina * limite, "limite": limite]
        if let ordem { args["ordem"] = ordem; args["desc"] = desc }
        switch await motor.enviar("consultar", args) {
        case .success(let v):
            let r = v as? [String: Any] ?? [:]
            total = r["total"] as? Int ?? 0
            linhas = (r["linhas"] as? [[String: Any]] ?? []).map { RLinha(key: $0["key"] as? String ?? "", valores: $0["valores"] as? [String: Any] ?? [:]) }
            erroFiltro = nil
            let f = filtro.trimmingCharacters(in: .whitespaces)
            if !f.isEmpty {
                filtrosRecentes.removeAll { $0 == f }
                filtrosRecentes.insert(f, at: 0)
                filtrosRecentes = Array(filtrosRecentes.prefix(20))
                UserDefaults.standard.set(filtrosRecentes, forKey: "realm.filtros.\(projeto)")
            }
            selecao = selecao.filter { k in linhas.contains { $0.key == k } }
        case .failure(let f):
            erroFiltro = f.texto
        }
    }

    func ordenar(_ campo: String) async {
        if ordem == campo { desc.toggle() } else { ordem = campo; desc = false }
        pagina = 0
        await consultar()
    }

    func aplicarFiltro(_ cls: String, _ f: String) async {
        classe = cls
        filtro = f
        ordem = nil; pagina = 0; selecao = []
        await consultar()
    }

    // MARK: objeto

    func abrirObjeto(_ cls: String, _ key: String, empilhar: Bool = true) async {
        switch await motor.enviar("objeto", ["cls": cls, "key": key]) {
        case .success(let v):
            let r = v as? [String: Any] ?? [:]
            if empilhar, let d = detalhe, d.cls != cls || d.key != key { voltar.append((d.cls, d.key)) }
            detalhe = RDetalhe(cls: cls, key: r["key"] as? String ?? key, label: r["label"] as? String ?? "",
                               valores: r["valores"] as? [String: Any] ?? [:],
                               apontam: (r["apontam"] as? [[String: Any]] ?? []).map { a in
                                   RApontador(cls: a["cls"] as? String ?? "", campo: a["campo"] as? String ?? "",
                                              total: a["total"] as? Int ?? 0, filtro: a["filtro"] as? String ?? "",
                                              itens: (a["itens"] as? [[String: Any]] ?? []).map { ($0["key"] as? String ?? "", $0["label"] as? String ?? "") })
                               })
        case .failure(let f):
            aviso = f.texto
            detalhe = nil
        }
    }

    func voltarObjeto() async {
        guard let (c, k) = voltar.popLast() else { return }
        await abrirObjeto(c, k, empilhar: false)
    }

    // MARK: editar (sempre na cópia de trabalho)

    func salvar(_ cls: String, _ key: String, _ valores: [String: Any]) async -> String? {
        switch await motor.enviar("atualizar", ["cls": cls, "key": key, "valores": valores]) {
        case .success:
            alteracoes += 1
            await abrirObjeto(cls, key, empilhar: false)
            await consultar()
            return nil
        case .failure(let f): return f.texto
        }
    }

    func criar(_ cls: String, _ valores: [String: Any]) async -> String? {
        switch await motor.enviar("criar", ["cls": cls, "valores": valores]) {
        case .success(let v):
            alteracoes += 1
            await atualizarInfo()
            await consultar()
            if let k = (v as? [String: Any])?["key"] as? String { await abrirObjeto(cls, k) }
            return nil
        case .failure(let f): return f.texto
        }
    }

    func apagar(_ cls: String, _ keys: [String]) async {
        switch await motor.enviar("apagar", ["cls": cls, "keys": keys]) {
        case .success:
            alteracoes += 1
            if let d = detalhe, keys.contains(d.key) { detalhe = nil }
            selecao = []
            await atualizarInfo()
            await consultar()
        case .failure(let f): aviso = f.texto
        }
    }

    func apagarFiltrados() async {
        guard let classe else { return }
        switch await motor.enviar("apagarFiltrados", ["cls": classe, "filtro": filtro]) {
        case .success:
            alteracoes += 1
            detalhe = nil; selecao = []; pagina = 0
            await atualizarInfo()
            await consultar()
        case .failure(let f): aviso = f.texto
        }
    }

    func exportar(_ formato: String, para url: URL) async {
        guard let classe else { return }
        switch await motor.enviar("exportar", ["cls": classe, "filtro": filtro, "ordem": ordem ?? "", "formato": formato, "destino": url.path]) {
        case .success(let v):
            aviso = "✓ \((v as? [String: Any])?["exportados"] as? Int ?? 0) registro(s) exportados para \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .failure(let f): aviso = f.texto
        }
    }

    func salvarComo(_ url: URL) async {
        switch await motor.enviar("copiar", ["destino": url.path]) {
        case .success: aviso = "✓ Banco salvo em \(url.path)"; NSWorkspace.shared.activateFileViewerSelecting([url])
        case .failure(let f): aviso = f.texto
        }
    }

    // MARK: celular

    func recarregarDoCelular(_ app: AppState) async {
        guard case .celular(let serial, let pacote, let arquivo) = origem,
              let d = app.dispositivos.first(where: { $0.serial == serial }) else {
            aviso = "O celular não está mais conectado."
            return
        }
        await abrirCelular(d, pacote: pacote, arquivo: arquivo, manterPosicao: true)
    }

    func alternarAuto(_ app: AppState) {
        tarefaAuto?.cancel()
        guard autoAtualizar else { return }
        tarefaAuto = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.autoAtualizar, self.alteracoes == 0, self.carregando == nil else { continue }
                await self.recarregarDoCelular(app)
            }
        }
    }

    /// Grava a cópia de trabalho de volta no celular: para o app, guarda o banco atual dele num
    /// backup, envia, confere o hash e reabre o app. Se o hash não bater, devolve o backup.
    func enviarAoCelular(_ app: AppState, reabrir: Bool) async {
        guard case .celular(let serial, let pacote, let arquivo) = origem,
              let d = app.dispositivos.first(where: { $0.serial == serial }) else {
            aviso = "O celular de origem não está conectado."
            return
        }
        carregando = "Preparando a cópia…"
        let temp = pastaTrabalho.appendingPathComponent("enviar-\(UUID().uuidString.prefix(6)).realm")
        if case .failure(let f) = await motor.enviar("copiar", ["destino": temp.path]) { aviso = f.texto; carregando = nil; return }
        defer { try? FileManager.default.removeItem(at: temp); carregando = nil }
        guard let novo = try? Data(contentsOf: temp) else { aviso = "Não consegui ler a cópia."; return }

        carregando = "Parando o app no celular…"
        _ = await Adb.shell(d, "am force-stop \(pacote)")

        carregando = "Guardando o banco atual do celular (backup)…"
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dirBackup = Self.pastaBackups.appendingPathComponent(pacote)
        try? FileManager.default.createDirectory(at: dirBackup, withIntermediateDirectories: true)
        let backup = dirBackup.appendingPathComponent("antes-de-enviar_\(fmt.string(from: Date()))_\(arquivo)")
        guard let atual = await Adb.dados(d, ["exec-out", "run-as", pacote, "cat", "files/\(arquivo)"]), atual.count > 100 else {
            aviso = "Não consegui fazer o backup do banco do celular — nada foi enviado."
            return
        }
        try? atual.write(to: backup)

        carregando = "Enviando o banco editado…"
        if let erro = await gravarNoCelular(d, pacote: pacote, arquivo: arquivo, dados: novo) {
            carregando = "Falhou — devolvendo o backup…"
            _ = await gravarNoCelular(d, pacote: pacote, arquivo: arquivo, dados: atual)
            aviso = "✗ \(erro)\nO banco original foi devolvido ao celular. Backup em \(backup.path)"
            return
        }
        if reabrir {
            _ = await Adb.shell(d, "monkey -p \(pacote) -c android.intent.category.LAUNCHER 1")
        }
        alteracoes = 0
        aviso = "✓ Banco enviado ao celular (\(ByteCountFormatter.string(fromByteCount: Int64(novo.count), countStyle: .file)))."
            + (reabrir ? " App reaberto." : "") + " Backup do anterior: \(backup.lastPathComponent)"
        await recarregarDoCelular(app)
    }

    /// Grava no celular com segurança: envia para um arquivo temporário, confere o hash DELE (o app
    /// não mexe nesse arquivo), e só então troca de forma atômica — apagando .lock/.management/.note
    /// do banco antigo, como faz a restauração de backup do próprio app.
    private func gravarNoCelular(_ d: Dispositivo, pacote: String, arquivo: String, dados: Data) async -> String? {
        let tmp = "files/\(arquivo).br-tmp"
        let comando = "run-as \(pacote) sh -c 'cat > \(tmp)'"
        let r: ShellResult
        if d.origem == .mac {
            r = await Shell.run("adb", ["-s", d.serial, "exec-in", comando], stdin: dados)
        } else {
            let cmd = Config.adbPC + " -s " + Adb.aspas(d.serial) + " exec-in " + Adb.aspas(comando)
            r = await Shell.run("ssh", Config.sshCliente + [Config.pcHost, cmd], stdin: dados)
        }
        guard r.ok else { return "Falha ao gravar: \(r.out)" }
        let hash = { (x: Data) in Insecure.SHA1.hash(data: x).map { String(format: "%02x", $0) }.joined() }
        let esperado = hash(dados)
        var confere = (await Adb.shell(d, "run-as \(pacote) sha1sum \(tmp)")).out.contains(esperado)
        if !confere, let volta = await Adb.dados(d, ["exec-out", "run-as", pacote, "cat", tmp]) {
            // sem sha1sum no aparelho: confere baixando de volta
            confere = hash(volta) == esperado
            if !confere {
                _ = await Adb.shell(d, "run-as \(pacote) rm -f \(tmp)")
                return "O arquivo chegou diferente no celular (enviados \(dados.count) bytes, chegaram \(volta.count)). Nada foi trocado."
            }
        }
        guard confere else {
            _ = await Adb.shell(d, "run-as \(pacote) rm -f \(tmp)")
            return "Não consegui conferir o arquivo enviado. Nada foi trocado."
        }
        // o app pode ter sido religado por tarefas em segundo plano: fecha de novo antes de trocar
        _ = await Adb.shell(d, "am force-stop \(pacote)")
        let f = "files/\(arquivo)"
        let troca = await Adb.shell(d, "run-as \(pacote) sh -c 'mv -f \(tmp) \(f) && rm -rf \(f).lock \(f).management \(f).note && echo TROCOU'")
        guard troca.out.contains("TROCOU") else { return "Falha ao trocar o arquivo: \(troca.out)" }
        let tam = (await Adb.shell(d, "run-as \(pacote) stat -c %s \(f)")).out.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Int(tam), n != dados.count { return "Depois da troca o arquivo tem \(n) bytes (esperado \(dados.count))." }
        return nil
    }

    // MARK: descarte

    func fecharBanco(_ app: AppState) {
        guard confirmarDescarte(backupEditado: backup?.storageEditado == true) else { return }
        autoAtualizar = false
        alternarAuto(app)
        _ = Task { await motor.enviar("fechar") }
        if let b = backup { try? FileManager.default.removeItem(at: b.pasta) }
        backup = nil; copia = nil; origem = nil; alteracoes = 0
        classes = []; linhas = []; detalhe = nil; classe = nil
    }

    /// Há edições não salvas: pergunta antes de trocar de banco
    func confirmarDescarte(backupEditado: Bool = false) -> Bool {
        guard alteracoes > 0 || backupEditado || backup?.storageEditado == true else { return true }
        let a = NSAlert()
        a.messageText = "Descartar as alterações?"
        a.informativeText = "As edições estão só na cópia de trabalho. Se abrir outro banco, elas se perdem. Use \"Salvar como…\", \"Gerar novo .zip…\" ou \"Enviar ao celular\" antes para guardá-las."
        a.addButton(withTitle: "Cancelar")
        a.addButton(withTitle: "Descartar")
        return a.runModal() == .alertSecondButtonReturn
    }

    func fechar() {
        tarefaAuto?.cancel()
        motor.parar()
    }
}

// MARK: - Formatação dos valores

enum RealmFmt {
    static let data: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd/MM/yyyy HH:mm:ss"; return f }()
    static let iso = ISO8601DateFormatter()
    static let isoFracao: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()

    static func dataDe(_ s: String) -> Date? { isoFracao.date(from: s) ?? iso.date(from: s) }

    static func ehBool(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    /// Texto curto para a tabela
    static func texto(_ v: Any?) -> String {
        guard let v, !(v is NSNull) else { return "null" }
        if let s = v as? String { return s.replacingOccurrences(of: "\n", with: " ⏎ ") }
        if ehBool(v) { return (v as! NSNumber).boolValue ? "true" : "false" }
        if let n = v as? NSNumber { return n.stringValue }
        if let d = v as? [String: Any] {
            if let x = d["$date"] { return (x as? String).flatMap(dataDe).map { data.string(from: $0) } ?? "data inválida" }
            if let x = d["$oid"] as? String { return x }
            if let x = d["$uuid"] as? String { return x }
            if let x = d["$decimal"] as? String { return x }
            if let x = d["$num"] as? String { return x }
            if let n = d["$bin"] as? Int { return "‹\(n) bytes›" }
            if d["$link"] != nil { return "→ \(d["label"] as? String ?? "?")" }
            if let n = d["$list"] as? Int {
                let itens = (d["itens"] as? [Any] ?? []).map { texto($0) }
                return "[\(n)] " + itens.joined(separator: ", ") + (n > itens.count ? "…" : "")
            }
            if let n = d["$dict"] as? Int { return "{\(n)} " + json((d["valores"] ?? [:])) }
            if let c = d["$embedded"] as? String { return "{\(c)}" }
            return json(d)
        }
        if let a = v as? [Any] { return json(a) }
        return "\(v)"
    }

    static func cor(_ v: Any?) -> Color {
        guard let v, !(v is NSNull) else { return .secondary.opacity(0.6) }
        if ehBool(v) { return .orange }
        if v is NSNumber { return .blue }
        if let d = v as? [String: Any] {
            if d["$link"] != nil { return .purple }
            if d["$date"] != nil { return .teal }
            if d["$list"] != nil || d["$dict"] != nil { return .indigo }
            return .brown
        }
        return .primary
    }

    static func json(_ v: Any) -> String {
        guard JSONSerialization.isValidJSONObject(v) || v is String || v is NSNumber,
              let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]) else { return "\(v)" }
        return String(decoding: d, as: UTF8.self)
    }

    /// Valor de uma coleção/mixed como JSON editável (links viram a chave primária)
    static func jsonEditavel(_ v: Any?) -> String {
        guard let v, !(v is NSNull) else { return "null" }
        func limpar(_ x: Any) -> Any {
            if let d = x as? [String: Any] {
                if d["$link"] != nil { return d["label"] as? String ?? "" }
                if let s = d["$date"] { return s }
                if let s = d["$oid"] ?? d["$uuid"] ?? d["$decimal"] { return s }
                if d["$list"] != nil { return (d["itens"] as? [Any] ?? []).map(limpar) }
                if d["$dict"] != nil { return (d["valores"] as? [String: Any] ?? [:]).mapValues(limpar) }
                return d.mapValues(limpar)
            }
            if let a = x as? [Any] { return a.map(limpar) }
            return x
        }
        let l = limpar(v)
        guard let d = try? JSONSerialization.data(withJSONObject: l, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "\(l)" }
        return String(decoding: d, as: UTF8.self)
    }
}
