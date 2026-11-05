import SwiftUI
import AppKit

// MARK: - Editor de texto estilo Notion (Markdown com formatação ao vivo)
//
// O texto é guardado em Markdown — o mesmo formato que o Notion importa/exporta e entende ao colar.
// A formatação aparece enquanto se digita (títulos, negrito, listas, checklists clicáveis, citações,
// código, links); os marcadores ficam discretos. Menu "/" para inserir blocos e atalhos do Notion.

enum ComandoEditor: String, CaseIterable, Identifiable {
    case texto, h1, h2, h3, lista, numerada, checklist, citacao, codigo, divisor, negrito, italico, riscado, codigoInline, link, data, imagem
    var id: String { rawValue }
    var titulo: String {
        switch self {
        case .texto: "Texto"; case .h1: "Título 1"; case .h2: "Título 2"; case .h3: "Título 3"
        case .lista: "Lista com marcadores"; case .numerada: "Lista numerada"; case .checklist: "Lista de tarefas"
        case .citacao: "Citação"; case .codigo: "Bloco de código"; case .divisor: "Divisor"
        case .negrito: "Negrito"; case .italico: "Itálico"; case .riscado: "Riscado"; case .codigoInline: "Código"; case .link: "Link"
        case .data: "Data de hoje"
        case .imagem: "Imagem"
        }
    }
    var icone: String {
        switch self {
        case .texto: "text.alignleft"; case .h1: "textformat.size.larger"; case .h2: "textformat.size"; case .h3: "textformat.size.smaller"
        case .lista: "list.bullet"; case .numerada: "list.number"; case .checklist: "checklist"
        case .citacao: "text.quote"; case .codigo: "chevron.left.forwardslash.chevron.right"; case .divisor: "minus"
        case .negrito: "bold"; case .italico: "italic"; case .riscado: "strikethrough"; case .codigoInline: "curlybraces"; case .link: "link"
        case .data: "calendar"
        case .imagem: "photo"
        }
    }
    /// Prefixo de bloco (início da linha)
    var prefixo: String? {
        switch self {
        case .texto: ""; case .h1: "# "; case .h2: "## "; case .h3: "### "
        case .lista: "- "; case .numerada: "1. "; case .checklist: "- [ ] "; case .citacao: "> "
        default: nil
        }
    }
    static let blocos: [ComandoEditor] = [.texto, .h1, .h2, .h3, .lista, .numerada, .checklist, .citacao, .codigo, .divisor, .imagem, .data]
}

/// Imagens das notas: ficam em ~/Documents/BuildRemoto/Notas/imagens e entram no texto como ![](imagens/…)
enum ImagensNotas {
    static var raiz: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/BuildRemoto/Notas") }
    static var pasta: URL {
        let u = raiz.appendingPathComponent("imagens")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    /// Guarda a imagem e devolve o caminho usado no Markdown
    static func salvar(_ dados: Data, extensao: String) -> String {
        let nome = "\(UUID().uuidString.prefix(12).lowercased()).\(extensao)"
        try? dados.write(to: pasta.appendingPathComponent(nome))
        return "imagens/\(nome)"
    }
    static func salvar(_ img: NSImage) -> String? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return salvar(png, extensao: "png")
    }
    static func copiar(_ arquivo: URL) -> String? {
        guard let d = try? Data(contentsOf: arquivo) else { return nil }
        return salvar(d, extensao: arquivo.pathExtension.lowercased().isEmpty ? "png" : arquivo.pathExtension.lowercased())
    }
    static func url(_ caminho: String) -> URL? {
        if caminho.hasPrefix("/") { return URL(fileURLWithPath: caminho) }
        if caminho.hasPrefix("file://") { return URL(string: caminho) }
        if caminho.hasPrefix("http") { return nil }
        return raiz.appendingPathComponent(caminho.removingPercentEncoding ?? caminho)
    }
    static let extensoes: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]
}

/// Ponte para a barra de ferramentas mandar comandos ao editor
@MainActor
final class ControleEditor: ObservableObject {
    weak var texto: TextoMarkdownView?
    func executar(_ c: ComandoEditor) { texto?.aplicar(c); texto?.window?.makeFirstResponder(texto) }
}

struct EditorMarkdown: NSViewRepresentable {
    @Binding var texto: String
    var placeholder = "Escreva… use \"/\" para blocos (títulos, listas, tarefas, código)"
    var tamanhoFonte: CGFloat = 14
    var controle: ControleEditor?
    var rolavel = true

    func makeCoordinator() -> Coord { Coord(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = TextoMarkdownView()
        tv.tamanho = tamanhoFonte
        tv.placeholder = placeholder
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 4, height: 8)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        tv.delegate = context.coordinator
        tv.textStorage?.delegate = context.coordinator
        tv.string = texto
        tv.estilizar()
        controle?.texto = tv
        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = rolavel
        sv.drawsBackground = false
        sv.autohidesScrollers = true
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? TextoMarkdownView else { return }
        context.coordinator.pai = self
        controle?.texto = tv
        if tv.string != texto {
            let sel = tv.selectedRange()
            tv.string = texto
            tv.estilizar()
            tv.setSelectedRange(NSRange(location: min(sel.location, (texto as NSString).length), length: 0))
        }
    }

    @MainActor
    final class Coord: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var pai: EditorMarkdown
        init(_ p: EditorMarkdown) { pai = p }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            pai.texto = tv.string
        }

        nonisolated func textStorage(_ ts: NSTextStorage, didProcessEditing m: NSTextStorageEditActions, range: NSRange, changeInLength: Int) {
            guard m.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated {
                (ts.layoutManagers.first?.firstTextView as? TextoMarkdownView)?.estilizar(ts)
            }
        }

        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            guard let t = tv as? TextoMarkdownView else { return false }
            switch sel {
            case #selector(NSResponder.insertNewline(_:)): return t.novaLinha()
            case #selector(NSResponder.insertTab(_:)): return t.recuar(true)
            case #selector(NSResponder.insertBacktab(_:)): return t.recuar(false)
            case #selector(NSResponder.deleteBackward(_:)): return t.apagarParaTras()
            default: return false
            }
        }

        func textView(_ tv: NSTextView, shouldChangeTextIn r: NSRange, replacementString s: String?) -> Bool {
            guard let t = tv as? TextoMarkdownView, let s else { return true }
            if s == "/" { DispatchQueue.main.async { t.talvezMenuBarra() } }
            if s == " " { return !t.atalhoDeBloco(r) }
            return true
        }

        private var selecaoAnterior = NSRange(location: 0, length: 0)
        private var ajustando = false
        private var linhaAnterior = -1

        func textViewDidChangeSelection(_ n: Notification) {
            guard let t = n.object as? TextoMarkdownView, !ajustando else { return }
            ajustando = true
            t.ajustarCursor(anterior: selecaoAnterior)
            selecaoAnterior = t.selectedRange()
            // linhas que só aparecem com o cursor nelas (cercas de código, divisor)
            let s = t.string as NSString
            let linha = s.lineRange(for: NSRange(location: min(t.selectedRange().location, s.length), length: 0)).location
            if linha != linhaAnterior { linhaAnterior = linha; t.estilizar() }
            ajustando = false
        }

        func textView(_ tv: NSTextView, clickedOnLink link: Any, at i: Int) -> Bool {
            if let u = link as? URL ?? (link as? String).flatMap(URL.init(string:)) { NSWorkspace.shared.open(u) }
            return true
        }
    }
}

// MARK: - NSTextView com o comportamento do editor

final class TextoMarkdownView: NSTextView {
    var tamanho: CGFloat = 14
    var placeholder = ""

    private var base: NSFont { .systemFont(ofSize: tamanho) }
    private var mono: NSFont { .monospacedSystemFont(ofSize: tamanho - 1, weight: .regular) }

    // MARK: placeholder
    override func draw(_ r: NSRect) {
        super.draw(r)
        if let ind = indicador {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: ind, xRadius: 2, yRadius: 2).fill()
        }
        if string.isEmpty && !placeholder.isEmpty {
            (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height),
                                           withAttributes: [.font: base, .foregroundColor: NSColor.placeholderTextColor])
        }
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }

    // MARK: estilo (Markdown escondido, formatação de verdade)

    enum Deco { case marcador(Int), tarefa(Bool, Int), citacao, divisor, codigo, imagens([(String, CGSize)]) }
    private var cacheImagens: [String: NSImage] = [:]
    /// (área na tela, caminho, linha, posição na linha)
    private var areasImagem: [(NSRect, String, NSRange, Int)] = []
    private let espacoImagens: CGFloat = 10
    static let reImagem = #"!\[[^\]]*\]\([^)\s]+\)"#

    /// As imagens ("![](…)") de uma linha, em ordem
    static func imagensDaLinha(_ l: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: reImagem) else { return [] }
        let ns = l as NSString
        return re.matches(in: l, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
    static func caminho(_ token: String) -> String {
        guard let r = token.range(of: "](") else { return "" }
        return String(token[r.upperBound...].dropLast())
    }
    /// Linhas que são só uma imagem (o cursor pula por elas)
    private(set) var linhasImagem: [NSRange] = []

    private func carregarImagem(_ caminho: String) -> NSImage? {
        if let i = cacheImagens[caminho] { return i }
        guard let u = ImagensNotas.url(caminho), let i = NSImage(contentsOf: u) else { return nil }
        cacheImagens[caminho] = i
        return i
    }
    /// Decorações desenhadas por cima do texto: (tipo, faixa do parágrafo)
    private var decoracoes: [(Deco, NSRange)] = []
    /// Trechos de Markdown escondidos (o cursor não pode parar dentro deles)
    private(set) var ocultos: [NSRange] = []
    /// Marcadores de bloco no começo da linha ("- [ ] ", "# ", "> "…): Backspace no fim deles desfaz o bloco
    private(set) var blocos: [NSRange] = []
    private var caixas: [(NSRect, Int)] = []
    private let passo: CGFloat = 24

    /// Esconde caracteres sem mudar a altura da linha (cor transparente + kern negativo)
    private func esconder(_ ts: NSTextStorage, _ r: NSRange, fonte: NSFont? = nil) {
        guard r.length > 0, NSMaxRange(r) <= ts.length else { return }
        let s = ts.string as NSString
        for i in r.location..<NSMaxRange(r) {
            let c = s.substring(with: NSRange(location: i, length: 1))
            if c == "\n" { continue }
            let f = fonte ?? (ts.attribute(.font, at: i, effectiveRange: nil) as? NSFont) ?? base
            let w = (c as NSString).size(withAttributes: [.font: f]).width
            ts.addAttributes([.foregroundColor: NSColor.clear, .kern: -w, .font: f], range: NSRange(location: i, length: 1))
        }
        ocultos.append(r)
    }

    private func paragrafo(_ inicio: CGFloat, _ resto: CGFloat? = nil, antes: CGFloat = 0, depois: CGFloat = 3) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = inicio
        p.headIndent = resto ?? inicio
        p.paragraphSpacingBefore = antes
        p.paragraphSpacing = depois
        p.lineHeightMultiple = 1.12
        return p
    }

    func estilizar(_ ts0: NSTextStorage? = nil) {
        guard let ts = ts0 ?? textStorage else { return }
        let s = ts.string as NSString
        let tudo = NSRange(location: 0, length: s.length)
        decoracoes = []; ocultos = []; blocos = []; linhasImagem = []
        let cursor = s.lineRange(for: NSRange(location: min(selectedRange().location, s.length), length: 0))
        ts.beginEditing()
        ts.setAttributes([.font: base, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragrafo(0)], range: tudo)
        var codigoInicio: Int?
        s.enumerateSubstrings(in: tudo, options: [.byParagraphs, .substringNotRequired]) { _, r, _, _ in
            let linha = s.substring(with: r)
            let semRecuo = linha.drop { $0 == " " || $0 == "\t" }
            let recuo = linha.count - semRecuo.count
            let nivel = CGFloat(recuo / 4) + (recuo % 4 >= 2 ? 1 : 0)
            let noCursor = NSIntersectionRange(cursor, NSRange(location: r.location, length: max(r.length, 1))).length > 0 || cursor.location == r.location
            // blocos de código
            if semRecuo.hasPrefix("```") {
                ts.addAttributes([.font: self.mono, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: self.paragrafo(12)], range: r)
                if !noCursor {
                    let mini = NSFont.systemFont(ofSize: 2)
                    ts.addAttribute(.paragraphStyle, value: self.paragrafo(12, antes: codigoInicio == nil ? 8 : 0, depois: codigoInicio == nil ? 0 : 12), range: r)
                    self.esconder(ts, r, fonte: mini)
                }
                if let i = codigoInicio {
                    self.decoracoes.append((.codigo, NSRange(location: i, length: NSMaxRange(r) - i)))
                    codigoInicio = nil
                } else { codigoInicio = r.location }
                return
            }
            if codigoInicio != nil {
                ts.addAttributes([.font: self.mono, .foregroundColor: NSColor.labelColor, .paragraphStyle: self.paragrafo(12, depois: 0)], range: r)
                return
            }
            func faixa(_ n: Int) -> NSRange { NSRange(location: r.location, length: min(r.length, recuo + n)) }
            func resto(_ n: Int) -> NSRange { let p = min(r.length, recuo + n); return NSRange(location: r.location + p, length: r.length - p) }
            func bloco(_ n: Int, fonte: NSFont? = nil) { self.esconder(ts, faixa(n), fonte: fonte); self.blocos.append(faixa(n)) }

            if String(semRecuo).range(of: #"^(!\[[^\]]*\]\([^)\s]+\)\s*)+$"#, options: .regularExpression) != nil {
                let caminhos = Self.imagensDaLinha(String(semRecuo)).map(Self.caminho)
                let imgs = caminhos.map { self.carregarImagem($0) }
                if !imgs.contains(where: { $0 == nil || $0!.size.width == 0 }) {
                    let largura = max(160, min((self.textContainer?.containerSize.width ?? 600) - 24, 760))
                    let proporcoes = imgs.map { $0!.size.width / $0!.size.height }
                    // mesma altura para todas, ocupando a largura (uma imagem só não passa do tamanho real)
                    var h = (largura - self.espacoImagens * CGFloat(imgs.count - 1)) / proporcoes.reduce(0, +)
                    h = min(h, imgs.count == 1 ? min(460, imgs[0]!.size.height) : 380)
                    let tamanhos = proporcoes.map { CGSize(width: $0 * h, height: h) }
                    let p = NSMutableParagraphStyle()
                    p.minimumLineHeight = h + 14; p.maximumLineHeight = h + 14; p.paragraphSpacing = 6
                    ts.addAttribute(.paragraphStyle, value: p, range: r)
                    self.esconder(ts, r)
                    self.linhasImagem.append(r)
                    self.decoracoes.append((.imagens(Array(zip(caminhos, tamanhos))), r))
                } else {
                    ts.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: r)
                }
                return
            }
            for (marca, tam, peso) in [("# ", 1.75, NSFont.Weight.bold), ("## ", 1.42, .bold), ("### ", 1.18, .semibold)] where semRecuo.hasPrefix(marca) {
                let f = NSFont.systemFont(ofSize: self.tamanho * tam, weight: peso)
                ts.addAttributes([.font: f, .paragraphStyle: self.paragrafo(0, antes: self.tamanho * 0.7, depois: 4)], range: r)
                bloco(marca.count, fonte: f)
                self.inline(ts, resto(marca.count), s)
                return
            }
            if let m = semRecuo.range(of: #"^[-*+] \[( |x|X)\] "#, options: .regularExpression) {
                let n = semRecuo.distance(from: semRecuo.startIndex, to: m.upperBound)
                let feito = semRecuo.contains("[x] ") || semRecuo.contains("[X] ")
                ts.addAttribute(.paragraphStyle, value: self.paragrafo((nivel + 1) * self.passo), range: r)
                if feito { ts.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor], range: resto(n)) }
                bloco(n)
                self.decoracoes.append((.tarefa(feito, r.location + recuo + 3), r))
                self.inline(ts, resto(n), s)
                return
            }
            if let m = semRecuo.range(of: #"^[-*+] "#, options: .regularExpression) {
                let n = semRecuo.distance(from: semRecuo.startIndex, to: m.upperBound)
                ts.addAttribute(.paragraphStyle, value: self.paragrafo((nivel + 1) * self.passo), range: r)
                bloco(n)
                self.decoracoes.append((.marcador(Int(nivel)), r))
                self.inline(ts, resto(n), s)
                return
            }
            if let m = semRecuo.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                let n = semRecuo.distance(from: semRecuo.startIndex, to: m.upperBound)
                let w = (String(semRecuo[m]) as NSString).size(withAttributes: [.font: self.base]).width
                ts.addAttribute(.paragraphStyle, value: self.paragrafo(nivel * self.passo + 6, nivel * self.passo + 6 + w), range: r)
                if recuo > 0 { self.esconder(ts, NSRange(location: r.location, length: recuo)) }
                ts.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.monospacedDigitSystemFont(ofSize: self.tamanho, weight: .medium)],
                                 range: NSRange(location: r.location + recuo, length: n))
                self.inline(ts, resto(n), s)
                return
            }
            if semRecuo.hasPrefix("> ") || semRecuo == ">" {
                let n = min(2, semRecuo.count)
                ts.addAttributes([.paragraphStyle: self.paragrafo(16), .foregroundColor: NSColor.secondaryLabelColor], range: r)
                bloco(n)
                self.decoracoes.append((.citacao, r))
                self.inline(ts, resto(n), s)
                return
            }
            if semRecuo.range(of: #"^(-{3,}|\*{3,}|_{3,})\s*$"#, options: .regularExpression) != nil {
                if !noCursor { self.esconder(ts, r); self.decoracoes.append((.divisor, r)) }
                else { ts.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: r) }
                return
            }
            self.inline(ts, r, s)
        }
        if let i = codigoInicio { decoracoes.append((.codigo, NSRange(location: i, length: s.length - i))) }
        ts.endEditing()
        needsDisplay = true
    }

    /// Formatação dentro da linha — os símbolos ficam escondidos
    private func inline(_ ts: NSTextStorage, _ r: NSRange, _ s: NSString) {
        guard r.length > 1 else { return }
        func cada(_ padrao: String, _ f: (NSTextCheckingResult) -> Void) {
            guard let re = try? NSRegularExpression(pattern: padrao) else { return }
            re.enumerateMatches(in: s as String, range: r) { m, _, _ in if let m { f(m) } }
        }
        func traço(_ rg: NSRange, _ t: NSFontTraitMask) {
            ts.enumerateAttribute(.font, in: rg) { v, sub, _ in
                if let f = v as? NSFont { ts.addAttribute(.font, value: NSFontManager.shared.convert(f, toHaveTrait: t), range: sub) }
            }
        }
        var codigo: [NSRange] = []
        cada(#"`([^`\n]+)`"#) { m in
            codigo.append(m.range)
            ts.addAttributes([.font: self.mono, .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12),
                              .foregroundColor: NSColor.systemPink], range: m.range(at: 1))
            self.esconder(ts, NSRange(location: m.range.location, length: 1))
            self.esconder(ts, NSRange(location: NSMaxRange(m.range) - 1, length: 1))
        }
        let dentroDeCodigo = { (x: NSRange) in codigo.contains { NSIntersectionRange($0, x).length > 0 } }
        var marcas: [NSRange] = []
        cada(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#) { m in
            guard !dentroDeCodigo(m.range) else { return }
            traço(m.range(at: 2), .boldFontMask)
            marcas += [m.range(at: 1), NSRange(location: NSMaxRange(m.range) - 2, length: 2)]
        }
        cada(#"(?<![*\w])\*(?![*\s])(.+?)(?<![*\s])\*(?![*\w])|(?<![_\w])_(?![_\s])(.+?)(?<![_\s])_(?![_\w])"#) { m in
            guard !dentroDeCodigo(m.range) else { return }
            let i = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            traço(i, .italicFontMask)
            marcas += [NSRange(location: m.range.location, length: 1), NSRange(location: NSMaxRange(m.range) - 1, length: 1)]
        }
        cada(#"~~(?=\S)(.+?)(?<=\S)~~"#) { m in
            guard !dentroDeCodigo(m.range) else { return }
            ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
            marcas += [NSRange(location: m.range.location, length: 2), NSRange(location: NSMaxRange(m.range) - 2, length: 2)]
        }
        cada(#"\[([^\]\n]+)\]\(([^)\s]+)\)"#) { m in
            guard !dentroDeCodigo(m.range) else { return }
            let url = s.substring(with: m.range(at: 2))
            ts.addAttribute(.link, value: URL(string: url) ?? url, range: m.range(at: 1))
            marcas += [NSRange(location: m.range.location, length: 1),
                       NSRange(location: NSMaxRange(m.range(at: 1)), length: NSMaxRange(m.range) - NSMaxRange(m.range(at: 1)))]
        }
        cada(#"(?<![(\[])\bhttps?://[^\s)]+"#) { m in
            guard !dentroDeCodigo(m.range) else { return }
            let u = s.substring(with: m.range)
            if let url = URL(string: u) { ts.addAttribute(.link, value: url, range: m.range) }
        }
        // esconde por último (a fonte já tem negrito/itálico aplicado)
        for x in marcas { esconder(ts, x) }
    }

    // MARK: desenho dos marcadores, caixas de tarefa, citações, divisores e blocos de código

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager, let tc = textContainer else { return }
        let o = textContainerOrigin
        let largura = tc.containerSize.width - tc.lineFragmentPadding * 2
        caixas = []
        areasImagem = []
        let n = (string as NSString).length
        for (d, r) in decoracoes where r.location < n {
            let g = lm.glyphIndexForCharacter(at: r.location)
            var primeira = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            primeira = primeira.offsetBy(dx: o.x, dy: o.y)
            let gr = lm.glyphRange(forCharacterRange: NSRange(location: r.location, length: max(1, min(r.length, n - r.location))), actualCharacterRange: nil)
            var tudo = lm.boundingRect(forGlyphRange: gr, in: tc).offsetBy(dx: o.x, dy: o.y)
            tudo = tudo.union(primeira)
            let x0 = o.x + tc.lineFragmentPadding
            let meio = primeira.minY + min(primeira.height, tamanho * 1.45) / 2 + 1
            switch d {
            case .marcador(let nivel):
                let simbolo = ["•", "◦", "▪︎"][nivel % 3]
                let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: tamanho * 1.15, weight: .bold), .foregroundColor: NSColor.labelColor]
                let t = (simbolo as NSString).size(withAttributes: a)
                (simbolo as NSString).draw(at: NSPoint(x: x0 + CGFloat(nivel) * passo + (passo - t.width) / 2 - 2, y: meio - t.height / 2), withAttributes: a)
            case .tarefa(let feito, let indice):
                let lado = tamanho + 2
                let p = (paragraphStyle(em: r.location)?.firstLineHeadIndent ?? passo) - passo
                let caixa = NSRect(x: x0 + p + (passo - lado) / 2 - 2, y: meio - lado / 2, width: lado, height: lado)
                let img = NSImage(systemSymbolName: feito ? "checkmark.square.fill" : "square", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: lado, weight: .regular).applying(.init(paletteColors: feito ? [.white, .controlAccentColor] : [.secondaryLabelColor])))
                img?.draw(in: caixa)
                caixas.append((caixa.insetBy(dx: -4, dy: -4), indice))
            case .citacao:
                NSColor.tertiaryLabelColor.setFill()
                NSRect(x: x0 + 2, y: tudo.minY + 1, width: 3, height: tudo.height - 2).fill()
            case .divisor:
                NSColor.separatorColor.setFill()
                NSRect(x: x0, y: meio, width: largura, height: 1).fill()
            case .imagens(let lista):
                var x = x0
                for (i, (caminho, tam)) in lista.enumerated() {
                    guard let img = carregarImagem(caminho) else { continue }
                    let area = NSRect(x: x, y: primeira.minY + 6, width: tam.width, height: tam.height)
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(roundedRect: area, xRadius: 8, yRadius: 8).addClip()
                    img.draw(in: area, from: .zero, operation: .sourceOver, fraction: origemArrasto?.0 == r && origemArrasto?.1 == i && arrastoAtivo ? 0.35 : 1,
                             respectFlipped: true, hints: nil)
                    NSGraphicsContext.restoreGraphicsState()
                    NSColor.separatorColor.setStroke()
                    NSBezierPath(roundedRect: area, xRadius: 8, yRadius: 8).stroke()
                    areasImagem.append((area, caminho, r, i))
                    x += tam.width + espacoImagens
                }
            case .codigo:
                let caixa = NSRect(x: x0, y: tudo.minY - 6, width: largura, height: tudo.height + 12)
                NSColor.quaternaryLabelColor.withAlphaComponent(0.13).setFill()
                NSBezierPath(roundedRect: caixa, xRadius: 6, yRadius: 6).fill()
            }
        }
    }

    // MARK: arrastar imagens (lado a lado ou para outra linha)

    enum AlvoImagem { case naLinha(NSRange, Int), novaLinha(Int) }
    private var origemArrasto: (NSRange, Int, NSPoint)?
    private var arrastoAtivo = false
    private var alvoArrasto: AlvoImagem?
    private var indicador: NSRect?

    private func calcularAlvo(_ p: NSPoint) -> (AlvoImagem, NSRect)? {
        guard let lm = layoutManager, let tc = textContainer else { return nil }
        let x0 = textContainerOrigin.x + tc.lineFragmentPadding
        let largura = tc.containerSize.width - tc.lineFragmentPadding * 2
        // em cima de uma imagem: antes ou depois dela, na mesma linha
        if let (area, _, linha, i) = areasImagem.first(where: { $0.0.insetBy(dx: -espacoImagens / 2, dy: 0).contains(p) }) {
            let depois = p.x > area.midX
            let x = depois ? area.maxX + espacoImagens / 2 - 2 : area.minX - espacoImagens / 2 - 2
            return (.naLinha(linha, depois ? i + 1 : i), NSRect(x: x, y: area.minY, width: 4, height: area.height))
        }
        // na faixa de uma linha de imagens, depois da última: vai para o fim da linha
        let porLinha = Dictionary(grouping: areasImagem, by: { $0.2.location })
        for (_, itens) in porLinha {
            guard let ultima = itens.max(by: { $0.3 < $1.3 }), p.y >= ultima.0.minY, p.y <= ultima.0.maxY, p.x > ultima.0.maxX else { continue }
            return (.naLinha(ultima.2, ultima.3 + 1), NSRect(x: ultima.0.maxX + espacoImagens / 2 - 2, y: ultima.0.minY, width: 4, height: ultima.0.height))
        }
        // entre linhas de texto
        let s = string as NSString
        let i = min(characterIndexForInsertion(at: p), max(0, s.length - 1))
        guard s.length > 0 else { return (.novaLinha(0), NSRect(x: x0, y: textContainerOrigin.y, width: largura, height: 3)) }
        var frag = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: i), effectiveRange: nil)
        frag = frag.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let linha = (s.substring(to: i) as NSString).components(separatedBy: "\n").count - 1
        let antes = p.y < frag.midY
        return (.novaLinha(antes ? linha : linha + 1), NSRect(x: x0, y: (antes ? frag.minY : frag.maxY) - 1.5, width: largura, height: 3))
    }

    private func moverImagem(linha origemLinha: NSRange, indice: Int, para alvo: AlvoImagem) {
        let s = string as NSString
        func indiceDaLinha(_ loc: Int) -> Int { (s.substring(to: loc) as NSString).components(separatedBy: "\n").count - 1 }
        var linhas = string.components(separatedBy: "\n")
        let li = indiceDaLinha(origemLinha.location)
        guard li < linhas.count else { return }
        var tokens = Self.imagensDaLinha(linhas[li])
        guard indice < tokens.count else { return }
        let token = tokens.remove(at: indice)
        var destinoLinha = 0
        switch alvo {
        case .naLinha(let r, let pos):
            let lt = indiceDaLinha(r.location)
            if lt == li {
                tokens.insert(token, at: min(pos > indice ? pos - 1 : pos, tokens.count))
                linhas[li] = tokens.joined(separator: " ")
                destinoLinha = li
            } else {
                var t = Self.imagensDaLinha(linhas[lt])
                t.insert(token, at: min(pos, t.count))
                linhas[lt] = t.joined(separator: " ")
                destinoLinha = lt
                if tokens.isEmpty { linhas.remove(at: li); if lt > li { destinoLinha -= 1 } } else { linhas[li] = tokens.joined(separator: " ") }
            }
        case .novaLinha(let antesDe):
            var destino = antesDe
            if tokens.isEmpty {
                if antesDe == li || antesDe == li + 1 { return }   // soltou no mesmo lugar
                linhas.remove(at: li)
                if antesDe > li { destino -= 1 }
            } else {
                linhas[li] = tokens.joined(separator: " ")
            }
            destino = min(destino, linhas.count)
            linhas.insert(token, at: destino)
            destinoLinha = destino
        }
        let novo = linhas.joined(separator: "\n")
        guard novo != string else { return }
        let inicio = (linhas.prefix(destinoLinha).map { ($0 as NSString).length + 1 }).reduce(0, +)
        trocar(NSRange(location: 0, length: s.length), por: novo)
        let fimLinha = inicio + (linhas[destinoLinha] as NSString).length
        setSelectedRange(NSRange(location: min(fimLinha + 1, (novo as NSString).length), length: 0))
    }

    override func mouseDragged(with e: NSEvent) {
        guard let (_, _, inicio) = origemArrasto else { super.mouseDragged(with: e); return }
        let p = convert(e.locationInWindow, from: nil)
        if !arrastoAtivo && hypot(p.x - inicio.x, p.y - inicio.y) > 5 { arrastoAtivo = true; NSCursor.closedHand.push() }
        guard arrastoAtivo else { return }
        if let (alvo, ind) = calcularAlvo(p) { alvoArrasto = alvo; indicador = ind } else { alvoArrasto = nil; indicador = nil }
        autoscroll(with: e)
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        guard let (linha, i, _) = origemArrasto else { super.mouseUp(with: e); return }
        let estava = arrastoAtivo
        if estava { NSCursor.pop() }
        origemArrasto = nil; arrastoAtivo = false; indicador = nil
        if estava, let alvo = alvoArrasto { moverImagem(linha: linha, indice: i, para: alvo) }
        alvoArrasto = nil
        needsDisplay = true
    }

    private func paragraphStyle(em i: Int) -> NSParagraphStyle? {
        guard let ts = textStorage, i < ts.length else { return nil }
        return ts.attribute(.paragraphStyle, at: i, effectiveRange: nil) as? NSParagraphStyle
    }

    /// O cursor não para dentro de símbolos escondidos (nem antes de um marcador de bloco)
    func ajustarCursor(anterior: NSRange) {
        let sel = selectedRange()
        guard sel.length == 0 else { return }
        let i = sel.location
        let voltando = i < anterior.location
        let total = (string as NSString).length
        for l in linhasImagem where i >= l.location && i <= NSMaxRange(l) {
            if voltando { setSelectedRange(NSRange(location: max(0, l.location - 1), length: 0)) }
            else if NSMaxRange(l) + 1 <= total { setSelectedRange(NSRange(location: NSMaxRange(l) + 1, length: 0)) }
            else { insertText("\n", replacementRange: NSRange(location: total, length: 0)) }
            return
        }
        for b in blocos where i >= b.location && i < NSMaxRange(b) {
            if voltando && b.location > 0 { setSelectedRange(NSRange(location: b.location - 1, length: 0)) }
            else { setSelectedRange(NSRange(location: NSMaxRange(b), length: 0)) }
            return
        }
        for o in ocultos where i > o.location && i < NSMaxRange(o) {
            setSelectedRange(NSRange(location: voltando ? o.location : NSMaxRange(o), length: 0))
            return
        }
    }

    /// Backspace logo depois de um marcador escondido: desfaz o bloco (como no Notion)
    func apagarParaTras() -> Bool {
        let sel = selectedRange()
        guard sel.length == 0 else { return false }
        if let l = linhasImagem.first(where: { NSMaxRange($0) + 1 == sel.location }) {
            trocar(NSRange(location: l.location, length: l.length + 1), por: "", cursor: l.location)
            return true
        }
        guard let b = blocos.first(where: { NSMaxRange($0) == sel.location }) else { return false }
        let s = string as NSString
        let marca = s.substring(with: b)
        let recuo = marca.prefix { $0 == " " }.count
        if recuo >= 2 {   // item recuado: primeiro volta um nível
            trocar(NSRange(location: b.location, length: min(4, recuo)), por: "", cursor: sel.location - min(4, recuo))
        } else {
            trocar(b, por: "", cursor: b.location)
        }
        return true
    }

    // MARK: linha atual

    private var linhaAtual: (range: NSRange, texto: String) {
        let s = string as NSString
        let r = s.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        var t = s.substring(with: r)
        if t.hasSuffix("\n") { t.removeLast() }
        return (NSRange(location: r.location, length: (t as NSString).length), t)
    }

    private func trocar(_ r: NSRange, por t: String, cursor: Int? = nil) {
        guard shouldChangeText(in: r, replacementString: t) else { return }
        replaceCharacters(in: r, with: t)
        didChangeText()
        if let cursor { setSelectedRange(NSRange(location: cursor, length: 0)) }
    }

    /// Enter: continua lista/tarefa/citação; numa linha vazia de lista, sai da lista
    func novaLinha() -> Bool {
        let (r, t) = linhaAtual
        guard selectedRange().length == 0 else { return false }
        let recuo = String(t.prefix { $0 == " " || $0 == "\t" })
        let corpo = String(t.dropFirst(recuo.count))
        var proximo: String?
        if let m = corpo.range(of: #"^([-*+]) \[( |x|X)\] "#, options: .regularExpression) {
            proximo = corpo[m].count == corpo.count ? nil : "\(corpo.first!) [ ] "
            if corpo[m].count == corpo.count { trocar(r, por: "", cursor: r.location); return true }
        } else if let m = corpo.range(of: #"^[-*+] "#, options: .regularExpression) {
            if corpo[m].count == corpo.count { trocar(r, por: "", cursor: r.location); return true }
            proximo = String(corpo[m])
        } else if let m = corpo.range(of: #"^(\d+)([.)]) "#, options: .regularExpression) {
            if corpo[m].count == corpo.count { trocar(r, por: "", cursor: r.location); return true }
            let num = Int(corpo.prefix { $0.isNumber }) ?? 1
            let sep = corpo.dropFirst(String(num).count).first ?? "."
            proximo = "\(num + 1)\(sep) "
        } else if corpo.hasPrefix("> ") {
            if corpo == "> " { trocar(r, por: "", cursor: r.location); return true }
            proximo = "> "
        }
        guard let proximo else { return false }
        insertText("\n" + recuo + proximo, replacementRange: selectedRange())
        return true
    }

    /// Tab / Shift-Tab numa linha de lista: recua ou avança 4 espaços
    func recuar(_ dentro: Bool) -> Bool {
        let (r, t) = linhaAtual
        let corpo = t.drop { $0 == " " || $0 == "\t" }
        guard corpo.range(of: #"^([-*+]|\d+[.)]) "#, options: .regularExpression) != nil else { return !dentro ? false : false }
        let pos = selectedRange().location
        if dentro {
            trocar(NSRange(location: r.location, length: 0), por: "    ", cursor: pos + 4)
        } else {
            let tira = min(4, t.count - corpo.count)
            guard tira > 0 else { return true }
            trocar(NSRange(location: r.location, length: tira), por: "", cursor: max(r.location, pos - tira))
        }
        return true
    }

    /// "[] " no começo da linha vira tarefa, como no Notion
    func atalhoDeBloco(_ r: NSRange) -> Bool {
        let (lr, t) = linhaAtual
        guard r.location == NSMaxRange(lr), t.trimmingCharacters(in: .whitespaces) == "[]" else { return false }
        let recuo = t.prefix { $0 == " " }.count
        trocar(NSRange(location: lr.location + recuo, length: 2), por: "- [ ] ", cursor: lr.location + recuo + 6)
        return true
    }

    // MARK: checkbox clicável

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let (_, caminho, linha, i) = areasImagem.first(where: { $0.0.contains(p) }) {
            if e.clickCount == 2, let u = ImagensNotas.url(caminho) { NSWorkspace.shared.open(u); return }
            origemArrasto = (linha, i, p)   // pode virar um arrasto
            return
        }
        if let (_, i) = caixas.first(where: { $0.0.contains(p) }) {
            let s = string as NSString
            if i < s.length {
                let marca = NSRange(location: i, length: 1)
                trocar(marca, por: s.substring(with: marca) == " " ? "x" : " ")
                return
            }
        }
        super.mouseDown(with: e)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for (r, _) in caixas { addCursorRect(r, cursor: .pointingHand) }
    }

    // MARK: atalhos de teclado (como no Notion)

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: e) }
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let k = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if f == .command {
            switch k {
            case "b": aplicar(.negrito); return true
            case "i": aplicar(.italico); return true
            case "e": aplicar(.codigoInline); return true
            case "k": aplicar(.link); return true
            default: break
            }
        }
        if f == [.command, .shift], k == "x" { aplicar(.riscado); return true }
        if f == [.command, .option] {
            let mapa: [String: ComandoEditor] = ["0": .texto, "1": .h1, "2": .h2, "3": .h3, "4": .checklist, "5": .lista, "6": .numerada, "8": .codigo]
            if let c = mapa[k] { aplicar(c); return true }
        }
        return super.performKeyEquivalent(with: e)
    }

    func aplicar(_ c: ComandoEditor) {
        let sel = selectedRange()
        let s = string as NSString
        switch c {
        case .negrito: envolver("**")
        case .italico: envolver("*")
        case .riscado: envolver("~~")
        case .codigoInline: envolver("`")
        case .link:
            let t = sel.length > 0 ? s.substring(with: sel) : "texto"
            trocar(sel, por: "[\(t)](https://)")
            setSelectedRange(NSRange(location: sel.location + (t as NSString).length + 3, length: 8))
        case .divisor:
            let (r, t) = linhaAtual
            trocar(NSRange(location: NSMaxRange(r), length: 0), por: (t.isEmpty ? "" : "\n") + "---\n", cursor: NSMaxRange(r) + (t.isEmpty ? 4 : 5))
        case .codigo:
            let t = sel.length > 0 ? s.substring(with: sel) : ""
            trocar(sel, por: "```\n\(t)\n```", cursor: sel.location + 4 + (t as NSString).length)
        case .imagem:
            let painel = NSOpenPanel()
            painel.allowedContentTypes = [.image]
            painel.allowsMultipleSelection = true
            guard painel.runModal() == .OK else { return }
            inserirImagens(painel.urls.compactMap { ImagensNotas.copiar($0) })
        case .data:
            let df = DateFormatter(); df.dateFormat = "dd/MM/yyyy"
            insertText(df.string(from: Date()), replacementRange: sel)
        default:
            guard let novo = c.prefixo else { return }
            // troca o prefixo de bloco das linhas selecionadas
            let linhas = s.lineRange(for: sel)
            var resultado: [String] = []
            var n = 1
            s.substring(with: linhas).enumerateLines { l, _ in
                let recuo = String(l.prefix { $0 == " " })
                var corpo = String(l.dropFirst(recuo.count))
                if let m = corpo.range(of: #"^(#{1,3} |[-*+] \[( |x|X)\] |[-*+] |\d+[.)] |> )"#, options: .regularExpression) { corpo.removeSubrange(m) }
                let p = c == .numerada ? "\(n). " : novo
                n += 1
                resultado.append(recuo + p + corpo)
            }
            let fimNL = s.substring(with: linhas).hasSuffix("\n")
            let txt = resultado.joined(separator: "\n") + (fimNL ? "\n" : "")
            trocar(linhas, por: txt)
            setSelectedRange(NSRange(location: linhas.location + (txt as NSString).length - (fimNL ? 1 : 0), length: 0))
        }
    }

    private func envolver(_ m: String) {
        let sel = selectedRange()
        let s = string as NSString
        let t = s.substring(with: sel)
        let ml = (m as NSString).length
        // já está formatado? tira
        if sel.location >= ml, NSMaxRange(sel) + ml <= s.length,
           s.substring(with: NSRange(location: sel.location - ml, length: ml)) == m,
           s.substring(with: NSRange(location: NSMaxRange(sel), length: ml)) == m {
            trocar(NSRange(location: sel.location - ml, length: sel.length + 2 * ml), por: t)
            setSelectedRange(NSRange(location: sel.location - ml, length: sel.length))
            return
        }
        trocar(sel, por: m + t + m)
        setSelectedRange(NSRange(location: sel.location + ml, length: sel.length))
    }

    // MARK: menu "/"

    func talvezMenuBarra() {
        let (r, t) = linhaAtual
        guard t.trimmingCharacters(in: .whitespaces) == "/" else { return }
        let menu = NSMenu()
        for c in ComandoEditor.blocos {
            let item = NSMenuItem(title: c.titulo, action: #selector(escolheuBloco(_:)), keyEquivalent: "")
            item.representedObject = c.rawValue
            item.target = self
            item.image = NSImage(systemSymbolName: c.icone, accessibilityDescription: nil)
            menu.addItem(item)
        }
        barraEm = r
        if let lm = layoutManager, let tc = textContainer {
            let g = lm.glyphRange(forCharacterRange: NSRange(location: max(0, selectedRange().location - 1), length: 1), actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: g, in: tc)
            menu.popUp(positioning: nil, at: NSPoint(x: rect.minX + textContainerOrigin.x, y: rect.maxY + textContainerOrigin.y + 4), in: self)
        }
    }
    private var barraEm: NSRange?

    @objc private func escolheuBloco(_ i: NSMenuItem) {
        guard let raw = i.representedObject as? String, let c = ComandoEditor(rawValue: raw), let r = barraEm else { return }
        let s = string as NSString
        let lr = s.lineRange(for: NSRange(location: r.location, length: 0))
        var linha = s.substring(with: lr)
        let nl = linha.hasSuffix("\n")
        if nl { linha.removeLast() }
        let recuo = String(linha.prefix { $0 == " " })
        trocar(NSRange(location: lr.location, length: (linha as NSString).length), por: recuo, cursor: lr.location + recuo.count)
        aplicar(c)
    }

    /// Insere a imagem numa linha própria, na posição do cursor
    func inserirImagem(_ caminho: String) { inserirImagens([caminho]) }

    /// Várias imagens de uma vez ficam lado a lado (até 3 por linha)
    func inserirImagens(_ caminhos: [String]) {
        guard !caminhos.isEmpty else { return }
        let linhasTxt = stride(from: 0, to: caminhos.count, by: 3).map { caminhos[$0..<min($0 + 3, caminhos.count)].map { "![](\($0))" }.joined(separator: " ") }
        let s = string as NSString
        let sel = selectedRange()
        let lr = s.lineRange(for: NSRange(location: sel.location, length: 0))
        let antes = sel.location > lr.location && s.substring(with: NSRange(location: lr.location, length: sel.location - lr.location)).trimmingCharacters(in: .whitespaces) != ""
        insertText((antes ? "\n" : "") + linhasTxt.joined(separator: "\n") + "\n", replacementRange: sel)
    }


    /// Imagens arrastadas para a nota
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { ImagensNotas.extensoes.contains($0.pathExtension.lowercased()) }
        if !urls.isEmpty {
            let i = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
            setSelectedRange(NSRange(location: i, length: 0))
            inserirImagens(urls.compactMap { ImagensNotas.copiar($0) })
            return true
        }
        if let img = (pb.readObjects(forClasses: [NSImage.self]) as? [NSImage])?.first, pb.string(forType: .string) == nil,
           let c = ImagensNotas.salvar(img) {
            setSelectedRange(NSRange(location: characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil)), length: 0))
            inserirImagem(c)
            return true
        }
        return super.performDragOperation(sender)
    }

    // MARK: colar (do Notion e da web) e copiar

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        // imagem copiada (print, Preview, navegador) ou arquivos de imagem copiados no Finder
        let arquivos = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { ImagensNotas.extensoes.contains($0.pathExtension.lowercased()) }
        if !arquivos.isEmpty {
            inserirImagens(arquivos.compactMap { ImagensNotas.copiar($0) })
            return
        }
        if (pb.string(forType: .string) ?? "").isEmpty, let img = NSImage(pasteboard: pb), let c = ImagensNotas.salvar(img) {
            inserirImagem(c)
            return
        }
        let plano = pb.string(forType: .string)
        let html = pb.string(forType: .html)
        let pareceMarkdown = plano.map { p in
            p.range(of: #"(?m)^(#{1,6} |[-*+] |\d+\. |> |```|- \[[ xX]\] )|\*\*\S|\[[^\]]+\]\(http"#, options: .regularExpression) != nil
        } ?? false
        var texto = plano ?? ""
        if !pareceMarkdown, let html, let md = HTMLParaMarkdown.converter(html), !md.isEmpty { texto = md }
        guard !texto.isEmpty else { super.paste(sender); return }
        insertText(texto, replacementRange: selectedRange())
    }

    override func writeSelection(to pb: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        // copia sempre como texto (Markdown) — o Notion converte ao colar
        let t = (string as NSString).substring(with: selectedRange())
        return pb.setString(t, forType: .string)
    }
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
}

// MARK: - HTML (web, Google Docs, Slack…) → Markdown

enum HTMLParaMarkdown {
    @MainActor
    static func converter(_ html: String) -> String? {
        guard let d = html.data(using: .utf8),
              let a = try? NSAttributedString(data: d, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                  .characterEncoding: String.Encoding.utf8.rawValue],
                                              documentAttributes: nil) else { return nil }
        var linhas: [String] = []
        let s = a.string as NSString
        s.enumerateSubstrings(in: NSRange(location: 0, length: s.length), options: [.byParagraphs, .substringNotRequired]) { _, r, _, _ in
            guard r.length > 0 else { linhas.append(""); return }
            var prefixo = ""
            var maiorFonte: CGFloat = 0
            var tudoNegrito = true
            if let p = a.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle, !p.textLists.isEmpty {
                let nivel = String(repeating: "    ", count: p.textLists.count - 1)
                let ord = p.textLists.last!.markerFormat.rawValue.contains("decimal")
                prefixo = nivel + (ord ? "1. " : "- ")
            }
            var corpo = ""
            a.enumerateAttributes(in: r) { at, sub, _ in
                var t = s.substring(with: sub)
                // marcadores de lista que o HTML já põe no texto ("\t•\t")
                t = t.replacingOccurrences(of: #"^\t?[•◦▪︎\-\d.]+\t"#, with: "", options: .regularExpression)
                guard !t.isEmpty else { return }
                let f = at[.font] as? NSFont
                maiorFonte = max(maiorFonte, f?.pointSize ?? 0)
                let tr = f.map { NSFontManager.shared.traits(of: $0) } ?? []
                let negrito = tr.contains(.boldFontMask), italico = tr.contains(.italicFontMask)
                let mono = f?.isFixedPitch ?? false
                if !negrito && !t.trimmingCharacters(in: .whitespaces).isEmpty { tudoNegrito = false }
                let espacoIni = String(t.prefix { $0 == " " }), espacoFim = String(t.reversed().prefix { $0 == " " })
                var m = t.trimmingCharacters(in: .whitespaces)
                guard !m.isEmpty else { corpo += t; return }
                if mono { m = "`\(m)`" } else {
                    if italico { m = "*\(m)*" }
                    if negrito { m = "**\(m)**" }
                    if (at[.strikethroughStyle] as? Int ?? 0) != 0 { m = "~~\(m)~~" }
                }
                if let l = at[.link] { m = "[\(m)](\((l as? URL)?.absoluteString ?? "\(l)"))" }
                corpo += espacoIni + m + espacoFim
            }
            if prefixo.isEmpty {
                if maiorFonte >= 22 { prefixo = "# "; corpo = corpo.replacingOccurrences(of: "**", with: "") }
                else if maiorFonte >= 17.5 { prefixo = "## "; corpo = corpo.replacingOccurrences(of: "**", with: "") }
                else if maiorFonte >= 15 && tudoNegrito { prefixo = "### "; corpo = corpo.replacingOccurrences(of: "**", with: "") }
            }
            linhas.append(prefixo + corpo)
        }
        return linhas.joined(separator: "\n").replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Barra de formatação

struct BarraFormatacao: View {
    @ObservedObject var controle: ControleEditor

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(ComandoEditor.blocos) { c in
                    Button { controle.executar(c) } label: { Label(c.titulo, systemImage: c.icone) }
                }
            } label: { Label("Bloco", systemImage: "plus.square.on.square") }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Inserir bloco (ou digite / no começo da linha)")
            Divider().frame(height: 16).padding(.horizontal, 4)
            ForEach([ComandoEditor.h1, .h2, .h3], id: \.self) { botao($0, texto: $0 == .h1 ? "H1" : $0 == .h2 ? "H2" : "H3") }
            Divider().frame(height: 16).padding(.horizontal, 4)
            ForEach([ComandoEditor.negrito, .italico, .riscado, .codigoInline, .link], id: \.self) { botao($0) }
            Divider().frame(height: 16).padding(.horizontal, 4)
            ForEach([ComandoEditor.lista, .numerada, .checklist, .citacao, .codigo, .divisor, .imagem], id: \.self) { botao($0) }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private func botao(_ c: ComandoEditor, texto: String? = nil) -> some View {
        Button { controle.executar(c) } label: {
            if let texto { Text(texto).font(.system(size: 11, weight: .bold)).frame(width: 22) }
            else { Image(systemName: c.icone).frame(width: 22) }
        }
        .help(c.titulo + atalho(c))
    }

    private func atalho(_ c: ComandoEditor) -> String {
        switch c {
        case .negrito: " (⌘B)"; case .italico: " (⌘I)"; case .riscado: " (⌘⇧X)"; case .codigoInline: " (⌘E)"; case .link: " (⌘K)"
        case .h1: " (⌥⌘1)"; case .h2: " (⌥⌘2)"; case .h3: " (⌥⌘3)"; case .checklist: " (⌥⌘4)"; case .lista: " (⌥⌘5)"; case .numerada: " (⌥⌘6)"; case .codigo: " (⌥⌘8)"
        default: ""
        }
    }
}
