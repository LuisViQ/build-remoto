import AppKit
import SwiftUI

// MARK: - Logcat estruturado

struct LogLinha: Identifiable {
    let id: Int
    let hora: String
    let pid: String
    let nivel: Character
    let tag: String
    let msg: String

    var cor: Color {
        switch nivel {
        case "E", "F": .red
        case "W": .orange
        case "I": .green
        case "D": .blue
        default: .secondary
        }
    }
    static let ordem: [Character] = ["V", "D", "I", "W", "E", "F"]
}

@MainActor
final class LogcatModel: ObservableObject {
    @Published private(set) var visiveis: [LogLinha] = []
    @Published var nivelMin: Character = "V" { didSet { refiltrar() } }
    @Published var busca = "" { didSet { refiltrar() } }
    @Published var soApp = true { didSet { refiltrar() } }
    @Published var pausado = false
    @Published var rodando = false
    @Published var pidsApp: Set<String> = []
    @Published var pacote: String?
    @Published var dispositivo: Dispositivo?

    private var todas: [LogLinha] = []
    private var proc: Process?
    private var resto = ""
    private var proximoID = 0
    private var tarefaPid: Task<Void, Never>?
    private let limite = 15000
    private static let re = try! NSRegularExpression(
        pattern: #"^\d\d-\d\d (\d\d:\d\d:\d\d\.\d+)\s+(\d+)\s+\d+ ([VDIWEF]) (.*?)\s*: (.*)$"#)

    func iniciar(_ d: Dispositivo, projeto: String) {
        parar()
        dispositivo = d
        todas = []; visiveis = []; resto = ""
        rodando = true
        proc = Adb.stream(d, ["logcat", "-v", "threadtime", "-T", "500"],
                          onTexto: { [weak self] in self?.receber($0) },
                          onFim: { [weak self] _ in self?.rodando = false })
        tarefaPid = Task { [weak self] in
            let pkg = await Adb.pacote(projeto, em: d)
            self?.pacote = pkg
            while !Task.isCancelled, let pkg {
                let r = await Adb.shell(d, "pidof \(pkg)")
                let pids = Set(r.out.split(whereSeparator: \.isWhitespace).map(String.init).filter { Int($0) != nil })
                if pids != self?.pidsApp { self?.pidsApp = pids; self?.refiltrar() }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func parar() {
        proc?.terminate(); proc = nil
        tarefaPid?.cancel(); tarefaPid = nil
        rodando = false
    }

    func limpar() { todas = []; visiveis = [] }

    private func receber(_ texto: String) {
        let s = resto + texto
        var linhas = s.components(separatedBy: "\n")
        resto = linhas.removeLast()
        var novas: [LogLinha] = []
        for l in linhas {
            let l = l.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let ns = l as NSString
            // Linhas fora do formato (cabeçalhos "--------- beginning of") são ignoradas
            guard let m = Self.re.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)) else { continue }
            novas.append(LogLinha(id: proximoID, hora: ns.substring(with: m.range(at: 1)),
                                  pid: ns.substring(with: m.range(at: 2)),
                                  nivel: Character(ns.substring(with: m.range(at: 3))),
                                  tag: ns.substring(with: m.range(at: 4)), msg: ns.substring(with: m.range(at: 5))))
            proximoID += 1
        }
        guard !novas.isEmpty else { return }
        todas.append(contentsOf: novas)
        if todas.count > limite { todas.removeFirst(todas.count - limite) }
        if !pausado {
            visiveis.append(contentsOf: novas.filter(passa))
            if visiveis.count > 4000 { visiveis.removeFirst(visiveis.count - 4000) }
        }
    }

    func refiltrar() {
        visiveis = Array(todas.filter(passa).suffix(4000))
    }

    private func passa(_ l: LogLinha) -> Bool {
        let idx = LogLinha.ordem.firstIndex(of: l.nivel) ?? 0
        guard idx >= (LogLinha.ordem.firstIndex(of: nivelMin) ?? 0) else { return false }
        if soApp, !pidsApp.isEmpty, !pidsApp.contains(l.pid) { return false }
        if soApp, pidsApp.isEmpty, pacote != nil { return l.tag.hasPrefix("ReactNative") }
        if !busca.isEmpty {
            return l.msg.localizedCaseInsensitiveContains(busca) || l.tag.localizedCaseInsensitiveContains(busca)
        }
        return true
    }

    func exportar() -> URL? {
        let texto = todas.map { "\($0.hora) \($0.pid) \($0.nivel) \($0.tag): \($0.msg)" }.joined(separator: "\n")
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = URL(fileURLWithPath: "\(Config.home)/Desktop/logcat \(fmt.string(from: Date())).txt")
        try? texto.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

// MARK: - Docs

struct Doc: Identifiable, Hashable {
    let url: URL
    let relativo: String
    var id: URL { url }
    var nome: String { url.deletingPathExtension().lastPathComponent }
    var pasta: String {
        let p = (relativo as NSString).deletingLastPathComponent
        return p.isEmpty ? "Raiz" : p
    }
}

@MainActor
final class DocsModel: ObservableObject {
    let projeto: String
    @Published var docs: [Doc] = []
    @Published var busca = ""
    @Published var selecionado: Doc?
    @Published var conteudo = ""
    @Published var versao = 0
    private var cache: [URL: String] = [:]

    init(projeto: String) { self.projeto = projeto }

    nonisolated static let ignorar: Set<String> = ["node_modules", ".git", "android", "ios", ".expo", "build", "Pods",
                                       "dist", "web-build", ".gradle", "coverage", "vendor"]

    func carregar() {
        let raiz = URL(fileURLWithPath: "\(Config.pasta(projeto))")
        let projeto = self.projeto
        Task.detached(priority: .userInitiated) {
            var achados: [Doc] = []
            let fm = FileManager.default
            guard let e = fm.enumerator(at: raiz, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
            while let u = e.nextObject() as? URL {
                if DocsModel.ignorar.contains(u.lastPathComponent) { e.skipDescendants(); continue }
                if e.level > 6 { e.skipDescendants(); continue }
                if ["md", "mdx", "markdown"].contains(u.pathExtension.lowercased()) {
                    let rel = String(u.path.dropFirst(raiz.path.count + 1))
                    achados.append(Doc(url: u, relativo: rel))
                }
            }
            // README e docs/ primeiro, depois o resto em ordem alfabética
            let peso = { (d: Doc) -> Int in
                if d.pasta == "Raiz" { return 0 }
                if d.pasta.hasPrefix("docs") { return 1 }
                if d.pasta.hasPrefix(".claude") { return 2 }
                return 3
            }
            achados.sort { (peso($0), $0.relativo.lowercased()) < (peso($1), $1.relativo.lowercased()) }
            await MainActor.run { [achados] in
                guard let m = DocsModel.instancias[projeto] else { return }
                m.docs = achados
                if m.selecionado == nil {
                    m.abrir(achados.first { $0.nome.lowercased() == "readme" && $0.pasta == "Raiz" } ?? achados.first)
                }
            }
        }
    }

    static var instancias: [String: DocsModel] = [:]
    static func de(_ projeto: String) -> DocsModel {
        if let m = instancias[projeto] { return m }
        let m = DocsModel(projeto: projeto)
        instancias[projeto] = m
        m.carregar()
        return m
    }

    func texto(_ d: Doc) -> String {
        if let t = cache[d.url] { return t }
        let t = (try? String(contentsOf: d.url, encoding: .utf8)) ?? ""
        cache[d.url] = t
        return t
    }

    /// Docs filtrados: pelo nome ou pelo conteúdo (com trecho do resultado)
    var filtrados: [(Doc, String?)] {
        let q = busca.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return docs.map { ($0, nil) } }
        return docs.compactMap { d in
            if d.relativo.localizedCaseInsensitiveContains(q) { return (d, nil) }
            let t = texto(d)
            guard let r = t.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
            let ini = t.index(r.lowerBound, offsetBy: -40, limitedBy: t.startIndex) ?? t.startIndex
            let fim = t.index(r.upperBound, offsetBy: 60, limitedBy: t.endIndex) ?? t.endIndex
            return (d, "…" + t[ini..<fim].replacingOccurrences(of: "\n", with: " ") + "…")
        }
    }

    func abrir(_ d: Doc?) {
        selecionado = d
        guard let d else { conteudo = ""; return }
        cache[d.url] = nil
        conteudo = texto(d)
        versao += 1
    }

    func salvar(_ novo: String) {
        guard let d = selecionado else { return }
        try? novo.write(to: d.url, atomically: true, encoding: .utf8)
        cache[d.url] = novo
        conteudo = novo
        versao += 1
    }

    /// Marca/desmarca o item de checklist da linha indicada e salva o arquivo
    func alternarCheck(linha: Int, marcado: Bool) {
        var linhas = conteudo.components(separatedBy: "\n")
        guard linha < linhas.count else { return }
        let l = linhas[linha]
        if let r = l.range(of: #"\[( |x|X)\]"#, options: .regularExpression) {
            linhas[linha] = l.replacingCharacters(in: r, with: marcado ? "[x]" : "[ ]")
            salvar(linhas.joined(separator: "\n"))
        }
    }

    func novo(nome: String) {
        let pasta = URL(fileURLWithPath: "\(Config.pasta(projeto))/docs")
        try? FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        let arq = pasta.appendingPathComponent(nome.hasSuffix(".md") ? nome : nome + ".md")
        if !FileManager.default.fileExists(atPath: arq.path) {
            try? "# \(nome.replacingOccurrences(of: ".md", with: ""))\n\n".write(to: arq, atomically: true, encoding: .utf8)
        }
        let d = Doc(url: arq, relativo: "docs/" + arq.lastPathComponent)
        if !docs.contains(d) { docs.insert(d, at: 0) }
        abrir(d)
    }
}

// MARK: - Recursos do Mac (modo local)

enum RecursosMac {
    private static var anterior: (ocioso: UInt64, total: UInt64)?

    static func cpu() -> Double {
        var info = host_cpu_load_info()
        var n = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &n) }
        }
        guard r == KERN_SUCCESS else { return 0 }
        let t = info.cpu_ticks
        let ocioso = UInt64(t.3)
        let total = UInt64(t.0) + UInt64(t.1) + UInt64(t.2) + UInt64(t.3)
        defer { anterior = (ocioso, total) }
        guard let a = anterior, total > a.total else { return 0 }
        return 1 - Double(ocioso - a.ocioso) / Double(total - a.total)
    }

    static func memoria() -> (usada: Double, total: Double) {
        var s = vm_statistics64()
        var n = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &n) }
        }
        let total = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        guard r == KERN_SUCCESS else { return (0, total) }
        let pag = Double(vm_kernel_page_size)
        let usada = (Double(s.active_count) + Double(s.wire_count) + Double(s.compressor_page_count)) * pag / 1_073_741_824
        return (usada, total)
    }
}
