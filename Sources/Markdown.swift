import Foundation

/// Conversor Markdown -> HTML (suficiente para a documentação dos projetos): títulos, listas,
/// checklists (clicáveis), blocos de código, tabelas, citações, links, negrito/itálico e imagens.
enum Markdown {
    static func html(_ md: String, base: URL) -> String {
        var out = ""
        let linhas = md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        var listas: [String] = []          // pilha de "ul"/"ol"
        var paragrafo: [String] = []

        func fecharParagrafo() {
            if !paragrafo.isEmpty { out += "<p>\(inline(paragrafo.joined(separator: " "), base))</p>\n"; paragrafo = [] }
        }
        func fecharListas(ate n: Int = 0) {
            while listas.count > n { out += "</\(listas.removeLast())>\n" }
        }

        while i < linhas.count {
            let l = linhas[i]
            let t = l.trimmingCharacters(in: .whitespaces)

            // Bloco de código
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                fecharParagrafo(); fecharListas()
                let lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codigo: [String] = []
                i += 1
                while i < linhas.count, !linhas[i].trimmingCharacters(in: .whitespaces).hasPrefix(String(t.prefix(3))) {
                    codigo.append(linhas[i]); i += 1
                }
                out += "<pre><code class=\"\(esc(lang))\">\(esc(codigo.joined(separator: "\n")))</code></pre>\n"
                i += 1; continue
            }
            if t.isEmpty { fecharParagrafo(); fecharListas(); i += 1; continue }

            // Títulos
            if let m = t.range(of: #"^#{1,6} "#, options: .regularExpression) {
                fecharParagrafo(); fecharListas()
                let n = t.distance(from: m.lowerBound, to: m.upperBound) - 1
                let texto = String(t[m.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                out += "<h\(n) id=\"\(ancora(texto))\">\(inline(texto, base))</h\(n)>\n"
                i += 1; continue
            }
            // Linha horizontal
            if t.range(of: #"^([-*_])( *\1){2,}$"#, options: .regularExpression) != nil {
                fecharParagrafo(); fecharListas(); out += "<hr>\n"; i += 1; continue
            }
            // Tabela
            if t.hasPrefix("|"), i + 1 < linhas.count,
               linhas[i + 1].trimmingCharacters(in: .whitespaces).range(of: #"^\|?[\s:|-]+\|?$"#, options: .regularExpression) != nil {
                fecharParagrafo(); fecharListas()
                let cel = { (s: String) -> [String] in
                    var x = s.trimmingCharacters(in: .whitespaces)
                    if x.hasPrefix("|") { x.removeFirst() }
                    if x.hasSuffix("|") { x.removeLast() }
                    return x.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                }
                out += "<table><thead><tr>" + cel(t).map { "<th>\(inline($0, base))</th>" }.joined() + "</tr></thead><tbody>"
                i += 2
                while i < linhas.count, linhas[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    out += "<tr>" + cel(linhas[i]).map { "<td>\(inline($0, base))</td>" }.joined() + "</tr>"
                    i += 1
                }
                out += "</tbody></table>\n"
                continue
            }
            // Citação
            if t.hasPrefix(">") {
                fecharParagrafo(); fecharListas()
                var bloco: [String] = []
                while i < linhas.count, linhas[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    bloco.append(String(linhas[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                out += "<blockquote>\(html(bloco.joined(separator: "\n"), base: base))</blockquote>\n"
                continue
            }
            // Itens de lista (com checklists)
            if let m = l.range(of: #"^(\s*)([-*+]|\d+[.)])\s+"#, options: .regularExpression) {
                fecharParagrafo()
                let recuo = l.prefix { $0 == " " || $0 == "\t" }.count / 2
                let ordenada = l[m].contains(where: \.isNumber)
                let tipo = ordenada ? "ol" : "ul"
                if listas.count < recuo + 1 {
                    while listas.count < recuo + 1 { listas.append(tipo); out += "<\(tipo)>\n" }
                } else {
                    fecharListas(ate: recuo + 1)
                }
                var item = String(l[m.upperBound...])
                if let c = item.range(of: #"^\[( |x|X)\]\s*"#, options: .regularExpression) {
                    let marcado = item[c].lowercased().contains("x")
                    item = String(item[c.upperBound...])
                    out += "<li class=\"task\"><input type=\"checkbox\" data-linha=\"\(i)\"\(marcado ? " checked" : "")> <span>\(inline(item, base))</span></li>\n"
                } else {
                    out += "<li>\(inline(item, base))</li>\n"
                }
                i += 1; continue
            }
            if !listas.isEmpty, l.hasPrefix("  ") {
                out += "<div class=\"cont\">\(inline(t, base))</div>"; i += 1; continue
            }
            fecharListas()
            paragrafo.append(t)
            i += 1
        }
        fecharParagrafo(); fecharListas()
        return out
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func ancora(_ s: String) -> String {
        s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: #"[^a-z0-9 -]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: " ", with: "-")
    }

    /// Formatação dentro da linha. O código inline é protegido antes das outras regras.
    static func inline(_ s: String, _ base: URL) -> String {
        var codigos: [String] = []
        var t = s.replacingOccurrences(of: #"`([^`]+)`"#, with: "\u{1}$1\u{2}", options: .regularExpression)
        // separa os trechos de código
        var r = ""
        var dentro = false
        var atual = ""
        for c in t {
            if c == "\u{1}" { r += esc(atual); atual = ""; dentro = true }
            else if c == "\u{2}" { codigos.append(atual); r += "\u{3}\(codigos.count - 1)\u{3}"; atual = ""; dentro = false }
            else { atual.append(c) }
        }
        r += dentro ? esc("`" + atual) : esc(atual)
        t = r
        let regras: [(String, String)] = [
            (#"!\[([^\]]*)\]\(([^)\s]+)[^)]*\)"#, "<img alt=\"$1\" src=\"$2\">"),
            (#"\[([^\]]+)\]\(([^)\s]+)[^)]*\)"#, "<a href=\"$2\">$1</a>"),
            (#"\*\*([^*]+)\*\*"#, "<strong>$1</strong>"),
            (#"__([^_]+)__"#, "<strong>$1</strong>"),
            (#"(?<![\w*])\*([^*\s][^*]*)\*(?![\w*])"#, "<em>$1</em>"),
            (#"(?<!\w)_([^_\s][^_]*)_(?!\w)"#, "<em>$1</em>"),
            (#"~~([^~]+)~~"#, "<del>$1</del>"),
            (#"(?<!["=>])(https?://[^\s<]+)"#, "<a href=\"$1\">$1</a>"),
        ]
        for (p, sub) in regras { t = t.replacingOccurrences(of: p, with: sub, options: .regularExpression) }
        for (k, c) in codigos.enumerated() {
            t = t.replacingOccurrences(of: "\u{3}\(k)\u{3}", with: "<code>\(esc(c))</code>")
        }
        return t
    }

    static let css = """
    :root { color-scheme: light dark; --fg:#1d1d1f; --mut:#6e6e73; --bg:#ffffff; --code:#f4f4f6; --borda:#e3e3e8; --link:#0a66d8; --acc:#c0392b; }
    @media (prefers-color-scheme: dark) { :root { --fg:#e8e8ed; --mut:#98989f; --bg:#1e1e20; --code:#2a2a2e; --borda:#3a3a3f; --link:#5aa7ff; --acc:#ff6b5e; } }
    html { background: var(--bg); }
    body { font: 14.5px/1.65 -apple-system, BlinkMacSystemFont, sans-serif; color: var(--fg); max-width: 860px; margin: 0 auto; padding: 28px 36px 80px; }
    h1,h2,h3,h4 { line-height: 1.25; margin: 1.6em 0 .55em; font-weight: 700; }
    h1 { font-size: 2em; margin-top: .2em; letter-spacing: -.02em; }
    h2 { font-size: 1.45em; padding-bottom: .3em; border-bottom: 1px solid var(--borda); }
    h3 { font-size: 1.18em; } h4 { font-size: 1em; color: var(--mut); text-transform: uppercase; letter-spacing: .04em; }
    a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
    code { font: 12.5px ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--code); padding: .15em .4em; border-radius: 5px; }
    pre { background: var(--code); padding: 14px 16px; border-radius: 10px; overflow-x: auto; border: 1px solid var(--borda); }
    pre code { background: none; padding: 0; font-size: 12.5px; line-height: 1.55; }
    blockquote { margin: 1em 0; padding: .4em 1em; border-left: 4px solid var(--acc); background: var(--code); border-radius: 0 8px 8px 0; color: var(--mut); }
    table { border-collapse: collapse; margin: 1em 0; width: 100%; font-size: 13.5px; display: block; overflow-x: auto; }
    th, td { border: 1px solid var(--borda); padding: 7px 11px; text-align: left; vertical-align: top; }
    th { background: var(--code); font-weight: 600; }
    tr:nth-child(even) td { background: color-mix(in srgb, var(--code) 45%, transparent); }
    ul, ol { padding-left: 1.6em; } li { margin: .25em 0; }
    li.task { list-style: none; margin-left: -1.3em; }
    li.task input { width: 15px; height: 15px; vertical-align: -2px; margin-right: 6px; accent-color: var(--acc); cursor: pointer; }
    li.task input:checked + span { color: var(--mut); text-decoration: line-through; }
    hr { border: 0; border-top: 1px solid var(--borda); margin: 2em 0; }
    img { max-width: 100%; border-radius: 8px; }
    mark { background: #ffe066; color: #000; border-radius: 3px; padding: 0 2px; }
    .progresso { position: sticky; top: 0; background: var(--bg); padding: 8px 0 10px; margin-bottom: 8px; border-bottom: 1px solid var(--borda); font-size: 12.5px; color: var(--mut); z-index: 2; }
    .barra { height: 6px; background: var(--code); border-radius: 3px; overflow: hidden; margin-top: 5px; }
    .barra div { height: 100%; background: linear-gradient(90deg, #2ecc71, #27ae60); border-radius: 3px; }
    """

    static func pagina(_ md: String, arquivo: URL, busca: String) -> String {
        let corpo = html(md, base: arquivo.deletingLastPathComponent())
        let total = md.components(separatedBy: "\n").filter { $0.range(of: #"^\s*([-*+]|\d+[.)])\s+\[( |x|X)\]"#, options: .regularExpression) != nil }.count
        let feitos = md.components(separatedBy: "\n").filter { $0.range(of: #"^\s*([-*+]|\d+[.)])\s+\[(x|X)\]"#, options: .regularExpression) != nil }.count
        let progresso = total > 0 ? """
        <div class="progresso">Checklist: <b>\(feitos)</b> de <b>\(total)</b> concluídos (\(feitos * 100 / total)%)
        <div class="barra"><div style="width:\(feitos * 100 / total)%"></div></div></div>
        """ : ""
        let buscaJS = busca.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return """
        <!doctype html><html><head><meta charset="utf-8"><base href="\(arquivo.deletingLastPathComponent().absoluteString)">
        <style>\(css)</style></head><body>\(progresso)\(corpo)
        <script>
        document.querySelectorAll('li.task input').forEach(c => c.addEventListener('change', e => {
          window.webkit.messageHandlers.check.postMessage({linha: +c.dataset.linha, marcado: c.checked});
        }));
        document.querySelectorAll('a').forEach(a => a.addEventListener('click', e => {
          const h = a.getAttribute('href') || '';
          if (h.startsWith('#')) return;
          e.preventDefault(); window.webkit.messageHandlers.link.postMessage(a.href);
        }));
        const q = '\(buscaJS)';
        if (q.length > 1) {
          const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          const nos = []; while (w.nextNode()) nos.push(w.currentNode);
          const re = new RegExp(q.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&'), 'gi');
          let primeiro = null;
          nos.forEach(n => { if (!n.parentElement.closest('script,style') && re.test(n.nodeValue)) {
            const s = document.createElement('span'); s.innerHTML = n.nodeValue.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(re, m => '<mark>'+m+'</mark>');
            n.replaceWith(s); primeiro = primeiro || s; } re.lastIndex = 0; });
          if (primeiro) primeiro.scrollIntoView({block: 'center'});
        }
        window.scrollTo(0, \(UserDefaults.standard.double(forKey: "scroll:" + arquivo.path)));
        window.addEventListener('scroll', () => window.webkit.messageHandlers.scroll.postMessage(window.scrollY));
        </script></body></html>
        """
    }
}
