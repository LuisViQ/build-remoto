import SwiftUI
import Security

// MARK: - Resumo do dia (daily) com IA
//
// Junta o que aconteceu no período (commits seus, branches, builds, APKs, bugs e notas, em todos os apps)
// e pede ao Claude um resumo para a daily. Usa o Claude Code instalado neste Mac (sem chave) ou a API
// da Anthropic com uma chave guardada no Keychain. Sem IA, monta um resumo simples localmente.

enum Chaveiro {
    static let servico = "dev.buildremoto.app"

    static func ler(_ conta: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: servico,
                                kSecAttrAccount as String: conta, kSecReturnData as String: true]
        var r: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func gravar(_ conta: String, _ valor: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: servico,
                                   kSecAttrAccount as String: conta]
        SecItemDelete(base as CFDictionary)
        guard let valor, !valor.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(valor.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum ProvedorIA: String, CaseIterable, Identifiable {
    case claudeCode = "Claude Code (deste Mac)"
    case api = "API da Anthropic (chave)"
    case semIA = "Sem IA (resumo simples)"
    var id: String { rawValue }
}

@MainActor
final class ResumoDiaModel: ObservableObject {
    enum Periodo: String, CaseIterable, Identifiable {
        case desdeDaily = "Desde a última daily", ultimoDia = "Último dia útil", hoje = "Hoje", semana = "Últimos 7 dias"
        var id: String { rawValue }
    }

    @Published var periodo: Periodo = .desdeDaily
    /// Horário em que a daily começa (minutos desde a meia-noite) — o resumo corta aí
    @Published var horaDaily: Int = (UserDefaults.standard.object(forKey: "resumo.horaDaily") as? Int) ?? (9 * 60 + 30) {
        didSet { UserDefaults.standard.set(horaDaily, forKey: "resumo.horaDaily") }
    }
    @Published var provedor: ProvedorIA
    @Published var planos = ""
    @Published var impedimentos = ""
    @Published var estilo = 0   // 0 curto, 1 detalhado
    /// Manda também o código alterado (diff) — desligado por padrão: é código do projeto indo para a IA
    @Published var incluirDiff = UserDefaults.standard.bool(forKey: "resumo.diff")
    @Published var dados = ""
    @Published var resumo = ""
    @Published var gerando: String?
    @Published var erro: String?
    @Published var temChave = Chaveiro.ler("anthropic-api-key") != nil
    let temClaudeCode: Bool

    init() {
        let cc = ["\(Config.home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
        temClaudeCode = cc
        let salvo = UserDefaults.standard.string(forKey: "resumo.provedor").flatMap(ProvedorIA.init(rawValue:))
        provedor = salvo ?? (cc ? .claudeCode : (Chaveiro.ler("anthropic-api-key") != nil ? .api : .semIA))
        planos = UserDefaults.standard.string(forKey: "resumo.planos") ?? ""
    }

    var intervalo: (Date, Date) {
        let cal = Calendar.current
        let hoje = cal.startOfDay(for: Date())
        switch periodo {
        case .desdeDaily:
            // o horário da daily mais recente que já passou, pulando fim de semana
            var d = cal.date(byAdding: .minute, value: horaDaily, to: hoje)!
            while d > Date() || cal.isDateInWeekend(d) { d = cal.date(byAdding: .day, value: -1, to: d)! }
            return (d, Date())
        case .hoje: return (hoje, Date())
        case .semana: return (cal.date(byAdding: .day, value: -7, to: hoje)!, Date())
        case .ultimoDia:
            var d = cal.date(byAdding: .day, value: -1, to: hoje)!
            while cal.isDateInWeekend(d) { d = cal.date(byAdding: .day, value: -1, to: d)! }
            return (d, hoje)
        }
    }

    // MARK: coletar

    func coletar() async {
        gerando = "Juntando commits, builds, bugs e notas…"
        let (ini, fim) = intervalo
        let iso = ISO8601DateFormatter()
        let df = DateFormatter(); df.dateFormat = "dd/MM HH:mm"
        var t = "Período: \(df.string(from: ini)) até \(df.string(from: fim))\n"
        for p in Config.projetos {
            let pasta = Config.pasta(p)
            var bloco: [String] = []
            let email = (await GitCLI.run(pasta, ["config", "user.email"])).out.trimmingCharacters(in: .whitespacesAndNewlines)
            let nome = (await GitCLI.run(pasta, ["config", "user.name"])).out.trimmingCharacters(in: .whitespacesAndNewlines)
            var args = ["log", "--all", "--no-merges", "--since=\(iso.string(from: ini))", "--until=\(iso.string(from: fim))",
                        "--date=format:%d/%m %H:%M", "--format=@@C%x1f%h%x1f%ad%x1f%s%x1f%D%x1f%b%x1e", "--name-only"]
            if !email.isEmpty { args.append("--author=\(email)") } else if !nome.isEmpty { args.append("--author=\(nome)") }
            var commits: [String] = []
            var orcamentoDiff = 20_000
            for bloco in (await GitCLI.run(pasta, args)).out.components(separatedBy: "@@C\u{1f}").dropFirst() {
                let partes = bloco.components(separatedBy: "\u{1e}")
                let c = partes[0].components(separatedBy: "\u{1f}")
                guard c.count >= 5 else { continue }
                let (hash, data, titulo, refs) = (c[0], c[1], c[2], c[3])
                let corpo = c.count > 4 ? c[4].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                let arquivos = (partes.count > 1 ? partes[1] : "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                var t = "- \(data) · \(titulo)" + (refs.isEmpty ? "" : " (\(refs))")
                if !corpo.isEmpty { t += "\n  Detalhes: " + String(corpo.replacingOccurrences(of: "\n", with: " ").prefix(500)) }
                if !arquivos.isEmpty {
                    t += "\n  Arquivos (\(arquivos.count)): " + arquivos.prefix(15).joined(separator: ", ") + (arquivos.count > 15 ? "…" : "")
                }
                if incluirDiff && orcamentoDiff > 0 {
                    let d = (await GitCLI.run(pasta, ["show", "--format=", "--no-color", "-U2", hash, "--", ".",
                                                      ":(exclude)yarn.lock", ":(exclude)package-lock.json", ":(exclude)*.snap",
                                                      ":(exclude)android/**", ":(exclude)ios/**", ":(exclude)**/*.png", ":(exclude)**/*.jpg"])).out
                    let trecho = String(d.prefix(min(3_000, orcamentoDiff)))
                    orcamentoDiff -= trecho.count
                    if !trecho.isEmpty { t += "\n  Código alterado:\n" + trecho.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n") + (d.count > trecho.count ? "\n    …(cortado)" : "") }
                }
                commits.append(t)
            }
            if !commits.isEmpty { bloco.append("Commits:\n" + commits.joined(separator: "\n")) }
            // branches em que trabalhou (checkouts no reflog)
            let reflog = (await GitCLI.run(pasta, ["reflog", "--date=iso-strict", "--format=%gd|%gs"])).out
            var branches: [String] = []
            for l in reflog.split(separator: "\n") {
                let c = l.components(separatedBy: "|")
                guard c.count == 2, let r = c[0].range(of: #"\{(.+)\}"#, options: .regularExpression),
                      let d = iso.date(from: String(c[0][r].dropFirst().dropLast())), d >= ini, d <= fim,
                      let m = c[1].range(of: "moving from .* to ", options: .regularExpression) else { continue }
                let b = String(c[1][m.upperBound...])
                if !branches.contains(b) { branches.append(b) }
            }
            if !branches.isEmpty { bloco.append("Branches em que trabalhou: " + branches.joined(separator: ", ")) }
            let builds = Historico.listar(p).filter { $0.fim >= ini && $0.fim <= fim }
            if !builds.isEmpty {
                bloco.append("Builds/execuções: " + Dictionary(grouping: builds, by: \.acao).map { a, l in
                    "\(a) \(l.count)x (\(l.filter(\.ok).count) ok, \(l.filter { !$0.ok && !$0.interrompido }.count) falha)"
                }.sorted().joined(separator: "; "))
            }
            let apks = ApkArquivo.listar(p).filter { $0.data >= ini && $0.data <= fim }
            if !apks.isEmpty {
                bloco.append("APKs gerados: " + apks.map { "\($0.ctx?.tipo ?? "?") v\($0.ctx?.versionName ?? "?") (\($0.ctx?.branch ?? "?"))" }.joined(separator: "; "))
            }
            let bugs = Bugs.listar(p).filter { $0.meta.data >= ini && $0.meta.data <= fim }
            if !bugs.isEmpty {
                bloco.append("Bugs registrados:\n" + bugs.map { b -> String in
                    let md = (try? String(contentsOf: b.readme, encoding: .utf8)) ?? ""
                    var oque = ""
                    if let r = md.range(of: "## O que aconteceu\n") {
                        oque = String(md[r.upperBound...].prefix { $0 != "#" }).trimmingCharacters(in: .whitespacesAndNewlines)
                        if oque.contains("não informado") { oque = "" }
                    }
                    return "- \(b.meta.titulo) [\(b.meta.gravidade)]\(b.meta.resolvido ? " (resolvido)" : "")" + (oque.isEmpty ? "" : ": " + String(oque.replacingOccurrences(of: "\n", with: " ").prefix(300)))
                }.joined(separator: "\n"))
            }
            let notas = NotasStore.de(p).notas
            let mexidas = notas.filter { $0.atualizada >= ini && $0.atualizada <= fim }
            func descrever(_ n: Nota) -> String {
                let (f, total) = n.tarefas
                var t = "- \(n.titulo.isEmpty ? "Sem título" : n.titulo) → \(n.status.rawValue)" + (total > 0 ? " (tarefas \(f)/\(total))" : "")
                let corpo = n.detalhes.trimmingCharacters(in: .whitespacesAndNewlines)
                if !corpo.isEmpty { t += "\n  " + String(corpo.prefix(600)).replacingOccurrences(of: "\n", with: "\n  ") + (corpo.count > 600 ? "…" : "") }
                return t
            }
            if !mexidas.isEmpty { bloco.append("Notas/tarefas mexidas:\n" + mexidas.map(descrever).joined(separator: "\n")) }
            let abertas = notas.filter { $0.status == .fazendo && !mexidas.contains($0) }
            if !abertas.isEmpty { bloco.append("Em andamento:\n" + abertas.map(descrever).joined(separator: "\n")) }
            if !bloco.isEmpty { t += "\n## \(p)\n" + bloco.joined(separator: "\n") + "\n" }
        }
        // notas que valem para vários apps (entram uma vez só)
        let gerais = NotasStore.geral.notas.filter { ($0.atualizada >= ini && $0.atualizada <= fim) || $0.status == .fazendo }
        if !gerais.isEmpty {
            t += "\n## Geral (notas de vários apps)\n" + gerais.map { n -> String in
                let (f, total) = n.tarefas
                var x = "- \(n.titulo) → \(n.status.rawValue)" + (total > 0 ? " (tarefas \(f)/\(total))" : "")
                    + " [apps: \(n.apps?.joined(separator: ", ") ?? "todos")]"
                let corpo = n.detalhes.trimmingCharacters(in: .whitespacesAndNewlines)
                if !corpo.isEmpty { x += "\n  " + String(corpo.prefix(600)).replacingOccurrences(of: "\n", with: "\n  ") }
                return x
            }.joined(separator: "\n") + "\n"
        }
        if !t.contains("## ") { t += "\n(Nada registrado no período — sem commits, builds ou notas.)\n" }
        dados = t
        gerando = nil
    }

    // MARK: gerar

    private var instrucoes: String {
        """
        Você escreve o que um desenvolvedor vai FALAR na daily (reunião rápida da equipe), a partir dos dados abaixo.
        Escreva em português do Brasil, em primeira pessoa e linguagem simples, como alguém falando: "corrigi…", "ajustei…", "comecei…".

        Regras de leitura fácil:
        - Frases curtas, uma ideia por item. Diga o que mudou para quem usa o app (ex.: "corrigi o login que travava"), não como foi feito.
        - Nada de termos técnicos: não use commit, branch, build, merge, refactor, hash, versão, nomes de arquivos, código ou siglas internas.
        - Junte o que for do mesmo assunto num item só. Cite o nome do app no começo do item quando houver mais de um app.
        - Sem markdown: nada de negrito, títulos ou crases. Use só "-" para os itens.
        - Não invente nada. Se não houver planos informados, diga em uma frase o que vai continuar, com base no que está em andamento.

        Formato exato (\(estilo == 0 ? "no máximo 4 itens em cada parte" : "no máximo 7 itens em cada parte"):

        Desde a última daily:
        - …

        Hoje:
        - …

        Impedimentos: nenhum (ou o impedimento, em uma frase)
        """
    }

    /// Tira qualquer marcação que a IA ainda devolver (negrito, títulos, crases)
    static func simplificar(_ t: String) -> String {
        var x = t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "`", with: "")
        x = x.replacingOccurrences(of: #"(?m)^#{1,6}\s*"#, with: "", options: .regularExpression)
        x = x.replacingOccurrences(of: #"(?m)^\s*[*•]\s+"#, with: "- ", options: .regularExpression)
        x = x.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return x.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var entrada: String {
        var t = dados
        if !planos.trimmingCharacters(in: .whitespaces).isEmpty { t += "\nPlanos para hoje (informados pelo dev): \(planos)\n" }
        if !impedimentos.trimmingCharacters(in: .whitespaces).isEmpty { t += "Impedimentos (informados pelo dev): \(impedimentos)\n" }
        return t
    }

    func gerar() async {
        erro = nil
        UserDefaults.standard.set(provedor.rawValue, forKey: "resumo.provedor")
        UserDefaults.standard.set(planos, forKey: "resumo.planos")
        if dados.isEmpty { await coletar() }
        switch provedor {
        case .semIA: resumo = resumoSimples()
        case .claudeCode:
            gerando = "Pedindo o resumo ao Claude Code…"
            let r = await Shell.run("claude", ["-p", instrucoes, "--output-format", "text"], stdin: Data(entrada.utf8))
            // o Claude Code escreve avisos (ex.: login perto de expirar) junto da resposta
            let txt = r.out.split(separator: "\n", omittingEmptySubsequences: false)
                .drop { $0.hasPrefix("Warning:") || $0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if r.ok && !txt.isEmpty { resumo = Self.simplificar(txt) } else { erro = "O Claude Code não respondeu: \(txt.prefix(400))" }
        case .api:
            gerando = "Pedindo o resumo à API da Anthropic…"
            do { resumo = Self.simplificar(try await chamarAPI()) } catch { erro = (error as? Falha)?.texto ?? error.localizedDescription }
        }
        gerando = nil
        if !resumo.isEmpty { salvarHistorico() }
    }

    /// Messages API por HTTP (Swift não tem SDK oficial). Opus 5.5 com esforço baixo (tarefa simples)
    /// e fallback do servidor caso o modelo recuse.
    private func chamarAPI() async throws -> String {
        guard let chave = Chaveiro.ler("anthropic-api-key") else { throw Falha("Informe a chave da API (fica no Keychain do Mac).") }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(chave, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let corpo: [String: Any] = [
            "model": "claude-opus-5-5",
            "max_tokens": 16000,
            "fallbacks": "default",
            "output_config": ["effort": "low"],
            "system": instrucoes,
            "messages": [["role": "user", "content": entrada]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: corpo)
        let (dados, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: dados)) as? [String: Any] ?? [:]
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: dados.prefix(300), as: UTF8.self)
            switch status {
            case 401: throw Falha("Chave da API inválida (401).")
            case 429: throw Falha("Limite de uso da API atingido (429). Tente de novo em instantes.")
            case 500...: throw Falha("A API está com problema (\(status)). Tente de novo.")
            default: throw Falha("Erro \(status): \(msg)")
            }
        }
        if json["stop_reason"] as? String == "refusal" { throw Falha("O modelo recusou gerar o resumo.") }
        let texto = (json["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }.joined()
        guard !texto.isEmpty else { throw Falha("A resposta veio vazia.") }
        return texto.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resumoSimples() -> String {
        var linhas = ["\(periodo == .hoje ? "Hoje" : periodo == .desdeDaily ? "Desde a última daily" : "Ontem"):"]
        for bloco in dados.components(separatedBy: "\n## ").dropFirst() {
            let partes = bloco.split(separator: "\n", maxSplits: 1)
            guard let app = partes.first else { continue }
            let commits = bloco.split(separator: "\n").filter { $0.contains(" · ") }.map { l -> String in
                var s = String(l.split(separator: "·", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces)
                if let r = s.range(of: #"^\w+(\(.*?\))?!?:\s*"#, options: .regularExpression) { s.removeSubrange(r) }
                return s
            }
            if !commits.isEmpty { linhas.append("- \(app): " + commits.prefix(6).joined(separator: "; ")) }
            for l in bloco.split(separator: "\n") where l.hasPrefix("Builds") || l.hasPrefix("APKs") || l.hasPrefix("Bugs") {
                linhas.append("  - " + l)
            }
        }
        if linhas.count == 1 { linhas.append("- (sem registros no período)") }
        linhas.append("Hoje: " + (planos.isEmpty ? "—" : planos))
        linhas.append("Impedimentos: " + (impedimentos.isEmpty ? "Nenhum" : impedimentos))
        return linhas.joined(separator: "\n")
    }

    private func salvarHistorico() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/BuildRemoto/Dailies")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd_HH-mm"
        try? resumo.write(to: dir.appendingPathComponent("daily_\(df.string(from: Date())).txt"), atomically: true, encoding: .utf8)
    }
}

struct ResumoDiaSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var m = ResumoDiaModel()
    @State private var verDados = false
    @State private var chave = ""
    @State private var copiado = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Resumo para a daily", systemImage: "text.bubble").font(.title3.bold())
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Picker("Período", selection: $m.periodo) { ForEach(ResumoDiaModel.Periodo.allCases) { Text($0.rawValue).tag($0) } }
                    .frame(maxWidth: 260)
                    .onChange(of: m.periodo) { m.dados = ""; Task { await m.coletar() } }
                if m.periodo == .desdeDaily {
                    DatePicker("Daily às", selection: Binding(
                        get: { Calendar.current.date(bySettingHour: m.horaDaily / 60, minute: m.horaDaily % 60, second: 0, of: Date()) ?? Date() },
                        set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); m.horaDaily = (c.hour ?? 14) * 60 + (c.minute ?? 30); m.dados = ""; Task { await m.coletar() } }),
                               displayedComponents: .hourAndMinute)
                        .fixedSize()
                }
                Picker("Tamanho", selection: $m.estilo) { Text("Curto").tag(0); Text("Detalhado").tag(1) }
                    .pickerStyle(.segmented).frame(maxWidth: 200)
            }
            Picker("IA", selection: $m.provedor) {
                ForEach(ProvedorIA.allCases) { p in
                    Text(p.rawValue + (p == .claudeCode && !m.temClaudeCode ? " — não instalado" : "")).tag(p)
                }
            }
            .frame(maxWidth: 420)
            if m.provedor == .api && !m.temChave {
                HStack {
                    SecureField("Chave da API (sk-ant-…)", text: $chave).textFieldStyle(.roundedBorder)
                    Button("Guardar no Keychain") { Chaveiro.gravar("anthropic-api-key", chave.trimmingCharacters(in: .whitespaces)); m.temChave = true; chave = "" }
                        .disabled(!chave.hasPrefix("sk-"))
                }
            } else if m.provedor == .api {
                HStack {
                    Label("Chave guardada no Keychain · modelo Claude Opus 5.5", systemImage: "key.fill").font(.caption).foregroundStyle(.secondary)
                    Button("Trocar") { Chaveiro.gravar("anthropic-api-key", nil); m.temChave = false }.controlSize(.small)
                }
            }
            Toggle(isOn: $m.incluirDiff) {
                Text("Incluir o código alterado (diff) — mais preciso, mas envia código do projeto para a IA")
            }
            .toggleStyle(.checkbox).font(.caption)
            .onChange(of: m.incluirDiff) {
                UserDefaults.standard.set(m.incluirDiff, forKey: "resumo.diff")
                m.dados = ""; Task { await m.coletar() }
            }
            TextField("O que vai fazer hoje (opcional)", text: $m.planos, axis: .vertical).lineLimit(1...3).textFieldStyle(.roundedBorder)
            TextField("Impedimentos (opcional)", text: $m.impedimentos, axis: .vertical).lineLimit(1...2).textFieldStyle(.roundedBorder)

            Text({ let (a, b) = m.intervalo; let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.dateFormat = "EEE dd/MM HH:mm"
                   return "Período: de \(f.string(from: a)) até \(f.string(from: b))" }())
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Dados usados (\(m.dados.split(separator: "\n").count) linhas) — é só isso que vai para a IA", isExpanded: $verDados) {
                ScrollView { Text(m.dados).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 150)
            }
            .font(.caption)

            HStack {
                Button { Task { await m.gerar() } } label: { Label(m.resumo.isEmpty ? "Gerar resumo" : "Gerar de novo", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(m.gerando != nil || (m.provedor == .api && !m.temChave) || (m.provedor == .claudeCode && !m.temClaudeCode))
                if let g = m.gerando { ProgressView().controlSize(.small); Text(g).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if !m.resumo.isEmpty {
                    Button { copiar(m.resumo); copiado = true } label: { Label(copiado ? "Copiado ✓" : "Copiar", systemImage: "doc.on.doc") }
                }
            }
            if let e = m.erro { Text(e).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            TextEditor(text: $m.resumo)
                .font(.system(size: 13))
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .overlay { if m.resumo.isEmpty { Text("O resumo aparece aqui — dá para editar antes de copiar.").foregroundStyle(.tertiary) } }
                .frame(minHeight: 200)
                .onChange(of: m.resumo) { copiado = false }
        }
        .padding(20)
        .frame(width: 720, height: 720)
        .task { await m.coletar() }
    }
}
