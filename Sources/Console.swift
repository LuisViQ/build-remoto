import AppKit
import SwiftUI

// MARK: - Cores do console (tema escuro)

enum Paleta {
    static let fundo = NSColor(red: 0.075, green: 0.082, blue: 0.098, alpha: 1)
    static let texto = NSColor(red: 0.86, green: 0.87, blue: 0.89, alpha: 1)
    static let base: [NSColor] = [
        hex(0x3B4048), hex(0xEF596F), hex(0x89CA78), hex(0xE5C07B),
        hex(0x61AFEF), hex(0xD55FDE), hex(0x2BBAC5), hex(0xDCDFE4),
        hex(0x5C6370), hex(0xFF7A8A), hex(0xA5E075), hex(0xF0D58A),
        hex(0x7CC4FF), hex(0xE07FEF), hex(0x56D4DD), hex(0xFFFFFF),
    ]

    static func hex(_ v: Int) -> NSColor {
        NSColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static func cor256(_ n: Int) -> NSColor {
        switch n {
        case 0..<16: return base[n]
        case 16..<232:
            let i = n - 16
            let c = { (x: Int) in x == 0 ? 0 : CGFloat(55 + x * 40) / 255 }
            return NSColor(red: c(i / 36), green: c((i / 6) % 6), blue: c(i % 6), alpha: 1)
        default:
            let g = CGFloat(8 + (n - 232) * 10) / 255
            return NSColor(white: g, alpha: 1)
        }
    }
}

// MARK: - Interpretador ANSI incremental

/// Converte a saída de terminal (cores SGR, \r, apagar linha, subir cursor) em operações
/// simples sobre o texto. Guarda sequências incompletas entre um pedaço e outro.
struct AnsiParser {
    enum Op {
        case texto(String, [NSAttributedString.Key: Any])
        case novaLinha
        case retornoCarro
        case limparLinha(Int)     // 0: do cursor ao fim · 1: do início ao cursor · 2: a linha toda
        case subir(Int, inicio: Bool)
        case descer(Int, inicio: Bool)
        case coluna(Int)
        case limparAbaixo
    }

    private var pendente = ""
    private var fg: NSColor?
    private var bg: NSColor?
    private var negrito = false
    private var fraco = false

    static let fonte = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    static let fonteNegrito = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold)

    var atributos: [NSAttributedString.Key: Any] {
        var cor = fg ?? Paleta.texto
        if fraco { cor = cor.withAlphaComponent(0.6) }
        var a: [NSAttributedString.Key: Any] = [
            .foregroundColor: cor,
            .font: negrito ? Self.fonteNegrito : Self.fonte,
        ]
        if let bg { a[.backgroundColor] = bg }
        return a
    }

    mutating func processar(_ entrada: String) -> [Op] {
        let s = pendente + entrada
        pendente = ""
        var ops: [Op] = []
        var buf = ""
        func soltar() {
            if !buf.isEmpty { ops.append(.texto(buf, atributos)); buf = "" }
        }
        let u = Array(s.unicodeScalars)
        var i = 0
        while i < u.count {
            let c = u[i]
            switch c {
            case "\n":
                soltar(); ops.append(.novaLinha); i += 1
            case "\r":
                soltar(); ops.append(.retornoCarro); i += 1
            case "\u{1B}":
                guard i + 1 < u.count else { pendente = String(String.UnicodeScalarView(u[i...])); i = u.count; break }
                let n = u[i + 1]
                if n == "[" {
                    // CSI: ESC [ parâmetros letra
                    var j = i + 2
                    while j < u.count, !(0x40...0x7E).contains(u[j].value) { j += 1 }
                    guard j < u.count else { pendente = String(String.UnicodeScalarView(u[i...])); i = u.count; break }
                    let params = String(String.UnicodeScalarView(u[(i + 2)..<j]))
                    let fim = u[j]
                    soltar()
                    switch fim {
                    case "m": aplicarSGR(params)
                    case "K": ops.append(.limparLinha(Int(params) ?? 0))
                    case "A": ops.append(.subir(max(1, Int(params) ?? 1), inicio: false))
                    case "F": ops.append(.subir(max(1, Int(params) ?? 1), inicio: true))
                    case "B": ops.append(.descer(max(1, Int(params) ?? 1), inicio: false))
                    case "E": ops.append(.descer(max(1, Int(params) ?? 1), inicio: true))
                    case "G": ops.append(.coluna(max(1, Int(params) ?? 1)))
                    case "J": if (Int(params) ?? 0) == 0 { ops.append(.limparAbaixo) }   // 2J/3J (limpar a tela) é ignorado para não perder o log
                    default: break
                    }
                    i = j + 1
                } else if n == "]" {
                    // OSC (ex.: título da janela): até BEL ou ESC \
                    var j = i + 2
                    var achou = false
                    while j < u.count {
                        if u[j] == "\u{07}" { j += 1; achou = true; break }
                        if u[j] == "\u{1B}", j + 1 < u.count, u[j + 1] == "\\" { j += 2; achou = true; break }
                        j += 1
                    }
                    if !achou { pendente = String(String.UnicodeScalarView(u[i...])); i = u.count; break }
                    i = j
                } else {
                    i += 2
                }
            case "\u{07}", "\u{08}", "\u{0F}", "\u{0E}":
                i += 1
            default:
                buf.unicodeScalars.append(c); i += 1
            }
        }
        soltar()
        return ops
    }

    private mutating func aplicarSGR(_ params: String) {
        var p = params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        if p.isEmpty { p = [0] }
        var k = 0
        while k < p.count {
            let v = p[k]
            switch v {
            case 0: fg = nil; bg = nil; negrito = false; fraco = false
            case 1: negrito = true
            case 2: fraco = true
            case 22: negrito = false; fraco = false
            case 30...37: fg = Paleta.base[v - 30]
            case 90...97: fg = Paleta.base[v - 90 + 8]
            case 39: fg = nil
            case 40...47: bg = Paleta.base[v - 40].withAlphaComponent(0.35)
            case 100...107: bg = Paleta.base[v - 100 + 8].withAlphaComponent(0.35)
            case 49: bg = nil
            case 38, 48:
                var cor: NSColor?
                if k + 2 < p.count, p[k + 1] == 5 { cor = Paleta.cor256(p[k + 2]); k += 2 }
                else if k + 4 < p.count, p[k + 1] == 2 {
                    cor = NSColor(red: CGFloat(p[k + 2]) / 255, green: CGFloat(p[k + 3]) / 255,
                                  blue: CGFloat(p[k + 4]) / 255, alpha: 1)
                    k += 4
                }
                if v == 38 { fg = cor } else { bg = cor?.withAlphaComponent(0.35) }
            default: break
            }
            k += 1
        }
    }
}

// MARK: - Modelo de um console (uma sessão)

@MainActor
final class ConsoleModel: ObservableObject {
    let nome: String
    let storage = NSTextStorage()
    @Published var versao = 0
    @Published var conectado = false

    private var parser = AnsiParser()
    /// Posição do cursor no texto (como num terminal: o que vem depois é sobrescrito, não apagado)
    private var cursor = 0
    private var pulandoLinha = false
    private var proc: Process?
    private let limite = 1_500_000

    init(nome: String) { self.nome = nome }

    /// Acompanha o log da sessão no PC (tail -F), reexibindo o histórico recente.
    func conectarRemoto() {
        parar()
        limpar()
        let log = "~/.build-remoto/\(nome).log"
        proc = Shell.stream("ssh", Config.sshCliente + [Config.pcHost, "tail -n 4000 -F \(log) 2>/dev/null"],
                            onTexto: { [weak self] in self?.receber($0) },
                            onFim: { [weak self] _ in self?.conectado = false })
        conectado = proc != nil
    }

    /// Roda um processo local (ex.: adb logcat do celular ligado no Mac).
    func conectarLocal(_ exe: String, _ args: [String], env: [String: String] = [:],
                       onFim: ((Int32) -> Void)? = nil) {
        parar()
        limpar()
        proc = Shell.stream(exe, args, env: env,
                            onTexto: { [weak self] in self?.receber($0) },
                            onFim: { [weak self] code in
                                self?.conectado = false
                                self?.info("— terminou (código \(code))")
                                onFim?(code)
                            })
        conectado = proc != nil
    }

    /// Roda um comando de shell no Mac com terminal de verdade (cores, spinners e teclas
    /// como "r" do Metro). O "script" cria o pseudo-terminal; o stdin vai para ele.
    func conectarTerminalLocal(_ comando: String, pasta: String, onFim: @escaping (Int32) -> Void) {
        parar()
        limpar()
        let p = Shell.processo("script", ["-q", "/dev/null", "/bin/zsh", "-lc", "cd \(Adb.aspas(pasta)) && \(Shell.prepararNode)\n\(comando)"],
                               env: ["TERM": "xterm-256color", "FORCE_COLOR": "1", "COLUMNS": "200"])
        let saida = Pipe()
        let entrada = Pipe()
        p.standardOutput = saida
        p.standardError = saida
        p.standardInput = entrada
        saida.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            let t = String(decoding: d, as: UTF8.self)
            DispatchQueue.main.async { self?.receber(t) }
        }
        p.terminationHandler = { [weak self] pr in
            DispatchQueue.main.async {
                self?.conectado = false
                self?.info("— terminou (código \(pr.terminationStatus))")
                onFim(pr.terminationStatus)
            }
        }
        do { try p.run() } catch { info("✗ \(error.localizedDescription)"); return }
        proc = p
        stdin = entrada.fileHandleForWriting
        conectado = true
    }

    private var stdin: FileHandle?

    /// Envia teclas ao processo local ("r", "\u{03}" = Ctrl+C)
    func enviar(_ texto: String) {
        try? stdin?.write(contentsOf: Data(texto.utf8))
    }

    var rodandoLocal: Bool { proc?.isRunning ?? false }

    func parar() {
        if let p = proc, p.isRunning { p.terminate() }
        proc = nil
        stdin = nil
        conectado = false
    }

    func limpar() {
        bruto = ""
        storage.setAttributedString(NSAttributedString())
        parser = AnsiParser()
        cursor = 0
        versao += 1
    }

    func info(_ texto: String) {
        cursor = storage.length
        if storage.length > 0, !storage.string.hasSuffix("\n") { receber("\n") }
        receber("\u{1B}[2m\(texto)\u{1B}[0m\n")
    }

    /// Saída bruta (com cores) da execução atual, para guardar no histórico
    private(set) var bruto = ""

    func receber(_ texto: String) {
        bruto += texto
        if bruto.utf8.count > 8_000_000 { bruto = String(bruto.suffix(6_000_000)) }
        storage.beginEditing()
        for op in parser.processar(texto) { aplicar(op) }
        if storage.length > limite { aparar() }
        storage.endEditing()
        versao += 1
    }

    private var texto: NSString { storage.mutableString }

    private func inicio(_ pos: Int) -> Int {
        guard pos > 0 else { return 0 }
        let r = texto.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: pos))
        return r.location == NSNotFound ? 0 : r.location + 1
    }

    private func fim(_ pos: Int) -> Int {
        let r = texto.range(of: "\n", range: NSRange(location: pos, length: storage.length - pos))
        return r.location == NSNotFound ? storage.length : r.location
    }

    private func aplicar(_ op: AnsiParser.Op) {
        cursor = min(cursor, storage.length)
        switch op {
        case let .texto(t, attrs):
            // O "script" do PC grava cabeçalho/rodapé no log; não interessa no console
            if cursor == storage.length, cursor == inicio(cursor), t.hasPrefix("Script started on ") || t.hasPrefix("Script done on ") {
                pulandoLinha = true
            }
            if pulandoLinha { return }
            let tam = (t as NSString).length
            let sobra = fim(cursor) - cursor
            storage.replaceCharacters(in: NSRange(location: cursor, length: min(tam, sobra)),
                                      with: NSAttributedString(string: t, attributes: attrs))
            cursor += tam
        case .novaLinha:
            if pulandoLinha {
                pulandoLinha = false
                let i = inicio(cursor)
                storage.deleteCharacters(in: NSRange(location: i, length: fim(cursor) - i))
                cursor = i
                return
            }
            let f = fim(cursor)
            if f == storage.length {
                storage.append(NSAttributedString(string: "\n", attributes: parser.atributos))
                cursor = storage.length
            } else {
                cursor = f + 1
            }
        case .retornoCarro:
            cursor = inicio(cursor)
        case let .limparLinha(modo):
            let i = inicio(cursor), f = fim(cursor)
            switch modo {
            case 1:
                storage.replaceCharacters(in: NSRange(location: i, length: cursor - i),
                                          with: String(repeating: " ", count: cursor - i))
            case 2:
                storage.deleteCharacters(in: NSRange(location: i, length: f - i))
                cursor = i
            default:
                storage.deleteCharacters(in: NSRange(location: cursor, length: f - cursor))
            }
        case let .subir(n, paraInicio):
            var i = inicio(cursor)
            let col = cursor - i
            for _ in 0..<n where i > 0 { i = inicio(i - 1) }
            cursor = paraInicio ? i : i + min(col, fim(i) - i)
        case let .descer(n, paraInicio):
            let col = cursor - inicio(cursor)
            for _ in 0..<n {
                let f = fim(cursor)
                if f == storage.length { storage.append(NSAttributedString(string: "\n", attributes: parser.atributos)) }
                cursor = f + 1
            }
            cursor = paraInicio ? cursor : cursor + min(col, fim(cursor) - cursor)
        case let .coluna(c):
            let i = inicio(cursor)
            cursor = i + min(c - 1, fim(i) - i)
        case .limparAbaixo:
            storage.deleteCharacters(in: NSRange(location: cursor, length: storage.length - cursor))
        }
    }

    private func aparar() {
        let s = storage.string as NSString
        let r = s.range(of: "\n", range: NSRange(location: limite / 5, length: s.length - limite / 5))
        let corte = r.location == NSNotFound ? limite / 5 : r.location + 1
        storage.deleteCharacters(in: NSRange(location: 0, length: corte))
        cursor = max(0, cursor - corte)
    }
}

// MARK: - View do console (NSTextView compartilhando o NSTextStorage do modelo)

/// Tecla digitada no console: texto literal ou tecla especial (nome no tmux + sequência local)
enum TeclaTerminal {
    case texto(String)
    case especial(tmux: String, local: String)
}

/// NSTextView somente leitura que repassa o teclado para a sessão (terminal interativo)
final class TerminalTextView: NSTextView {
    var onTecla: ((TeclaTerminal) -> Void)?

    override func becomeFirstResponder() -> Bool {
        enclosingScrollView?.layer?.borderWidth = onTecla == nil ? 0 : 1.5
        return super.becomeFirstResponder()
    }
    override func resignFirstResponder() -> Bool {
        enclosingScrollView?.layer?.borderWidth = 0
        return super.resignFirstResponder()
    }

    override func keyDown(with e: NSEvent) {
        guard let onTecla else { super.keyDown(with: e); return }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) { super.keyDown(with: e); return }   // Cmd+C, Cmd+A…
        if mods.contains(.control), let c = e.charactersIgnoringModifiers?.lowercased(), c.count == 1,
           let v = c.unicodeScalars.first?.value, (97...122).contains(v) {
            onTecla(.especial(tmux: "C-\(c)", local: String(UnicodeScalar(v - 96)!)))
            return
        }
        let especiais: [UInt16: (String, String)] = [
            36: ("Enter", "\r"), 76: ("Enter", "\r"), 51: ("BSpace", "\u{7f}"), 53: ("Escape", "\u{1b}"),
            48: ("Tab", "\t"), 126: ("Up", "\u{1b}[A"), 125: ("Down", "\u{1b}[B"),
            124: ("Right", "\u{1b}[C"), 123: ("Left", "\u{1b}[D"),
        ]
        if let (t, l) = especiais[e.keyCode] { onTecla(.especial(tmux: t, local: l)); return }
        if let t = e.characters, !t.isEmpty { onTecla(.texto(t)) }
    }
}

struct ConsoleView: NSViewRepresentable {
    @ObservedObject var console: ConsoleModel
    var onTecla: ((TeclaTerminal) -> Void)? = nil

    final class Coordinator {
        var seguir = true
        weak var scroll: NSScrollView?
        var storage: NSTextStorage?

        @objc func rolou(_ n: Notification) {
            guard let sv = scroll, let doc = sv.documentView else { return }
            seguir = sv.contentView.bounds.maxY >= doc.frame.height - 40
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        let tv = TerminalTextView(frame: .zero)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        sv.documentView = tv
        sv.wantsLayer = true
        sv.layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.55).cgColor
        tv.onTecla = onTecla
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = true
        tv.backgroundColor = Paleta.fundo
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.isAutomaticLinkDetectionEnabled = false
        sv.drawsBackground = true
        sv.backgroundColor = Paleta.fundo
        sv.scrollerStyle = .overlay
        tv.layoutManager?.allowsNonContiguousLayout = true
        tv.layoutManager?.replaceTextStorage(console.storage)
        context.coordinator.storage = console.storage
        context.coordinator.scroll = sv
        sv.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.rolou(_:)),
                                               name: NSView.boundsDidChangeNotification, object: sv.contentView)
        DispatchQueue.main.async { tv.scrollToEndOfDocument(nil) }
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? TerminalTextView else { return }
        tv.onTecla = onTecla
        if context.coordinator.storage !== console.storage {
            tv.layoutManager?.replaceTextStorage(console.storage)
            context.coordinator.storage = console.storage
            context.coordinator.seguir = true
        }
        _ = console.versao
        if context.coordinator.seguir {
            DispatchQueue.main.async { tv.scrollToEndOfDocument(nil) }
        }
    }
}
