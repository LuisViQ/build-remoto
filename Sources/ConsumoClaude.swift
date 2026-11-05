import SwiftUI

// MARK: - Consumo do Claude Code (lido dos registros locais em ~/.claude/projects)
//
// Cada resposta do Claude Code fica registrada com os tokens usados. Aqui somamos hoje, as últimas 5 h
// (a janela de uso do plano) e 7 dias, e estimamos quanto isso custaria pela API. O percentual do
// limite do plano não fica no Mac — esse só aparece na página de uso do Claude.

struct TotaisClaude: Equatable {
    var mensagens = 0
    var entrada = 0
    var saida = 0
    var cacheLeitura = 0
    var cacheEscrita = 0
    var custo: Double = 0
    var tokens: Int { entrada + saida + cacheLeitura + cacheEscrita }

    mutating func somar(_ u: [String: Any], modelo: String) {
        let e = u["input_tokens"] as? Int ?? 0, s = u["output_tokens"] as? Int ?? 0
        let cl = u["cache_read_input_tokens"] as? Int ?? 0, ce = u["cache_creation_input_tokens"] as? Int ?? 0
        mensagens += 1; entrada += e; saida += s; cacheLeitura += cl; cacheEscrita += ce
        // preço por milhão de tokens (entrada, saída); cache: leitura 5% da entrada, escrita 2x (cache de 1 h)
        let (pe, ps): (Double, Double) = modelo.contains("fable") || modelo.contains("mythos") ? (10, 50)
            : modelo.contains("opus-5-5") ? (4, 20) : modelo.contains("opus") ? (5, 25)
            : modelo.contains("sonnet") ? (2, 10) : modelo.contains("haiku-5") ? (0.1, 0.5) : modelo.contains("haiku") ? (1, 5) : (4, 20)
        custo += (Double(e) * pe + Double(s) * ps + Double(cl) * pe * 0.05 + Double(ce) * pe * 2) / 1_000_000
    }
}

@MainActor
final class ConsumoClaude: ObservableObject {
    static let compartilhado = ConsumoClaude()
    @Published var hoje = TotaisClaude()
    @Published var cincoHoras = TotaisClaude()
    @Published var semana = TotaisClaude()
    @Published var porModelo: [(String, TotaisClaude)] = []
    @Published var atualizado: Date?
    let disponivel = FileManager.default.fileExists(atPath: "\(Config.home)/.claude/projects")
    private var tarefa: Task<Void, Never>?

    func iniciar() {
        guard disponivel, tarefa == nil else { return }
        tarefa = Task { [weak self] in
            while !Task.isCancelled {
                let r = await Task.detached(priority: .utility) { ConsumoClaude.calcular() }.value
                guard let self else { return }
                self.hoje = r.0; self.cincoHoras = r.1; self.semana = r.2; self.porModelo = r.3; self.atualizado = Date()
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    nonisolated static func calcular() -> (TotaisClaude, TotaisClaude, TotaisClaude, [(String, TotaisClaude)]) {
        let fm = FileManager.default
        let raiz = URL(fileURLWithPath: "\(NSHomeDirectory())/.claude/projects")
        let agora = Date()
        let inicioHoje = Calendar.current.startOfDay(for: agora)
        let limite5h = agora.addingTimeInterval(-5 * 3600), limite7d = agora.addingTimeInterval(-7 * 86400)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var h = TotaisClaude(), c = TotaisClaude(), s = TotaisClaude()
        var modelos: [String: TotaisClaude] = [:]
        var vistos = Set<String>()
        let arquivos = (fm.enumerator(at: raiz, includingPropertiesForKeys: [.contentModificationDateKey])?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "jsonl" && ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > limite7d }
        for arq in arquivos {
            guard let dados = try? Data(contentsOf: arq, options: .mappedIfSafe) else { continue }
            for linha in dados.split(separator: 0x0A) {
                // só as linhas com consumo (evita decodificar o resto)
                guard linha.count > 50, linha.range(of: Data("\"usage\"".utf8)) != nil,
                      let o = try? JSONSerialization.jsonObject(with: linha) as? [String: Any],
                      let m = o["message"] as? [String: Any], let u = m["usage"] as? [String: Any],
                      let ts = (o["timestamp"] as? String).flatMap(iso.date(from:)), ts > limite7d else { continue }
                // a mesma resposta aparece em várias linhas: conta uma vez
                let chave = (m["id"] as? String ?? "") + (o["requestId"] as? String ?? "")
                guard !chave.isEmpty, vistos.insert(chave).inserted else { continue }
                let modelo = m["model"] as? String ?? "?"
                if modelo == "<synthetic>" { continue }
                s.somar(u, modelo: modelo)
                modelos[modelo, default: TotaisClaude()].somar(u, modelo: modelo)
                if ts >= inicioHoje { h.somar(u, modelo: modelo) }
                if ts >= limite5h { c.somar(u, modelo: modelo) }
            }
        }
        return (h, c, s, modelos.sorted { $0.value.custo > $1.value.custo })
    }

    static func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1f M", Double(n) / 1_000_000) : n >= 1000 ? String(format: "%.0f mil", Double(n) / 1000) : "\(n)"
    }
    static func dolar(_ v: Double) -> String { String(format: "US$ %.2f", v) }
}

/// Linha compacta no rodapé da barra lateral (abre os detalhes ao clicar)
struct LinhaConsumoClaude: View {
    @ObservedObject var c = ConsumoClaude.compartilhado
    @State private var detalhes = false

    var body: some View {
        if c.disponivel {
            Button { detalhes.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(.orange)
                    Text("Claude").font(.system(size: 11, weight: .semibold))
                    Text(c.atualizado == nil ? "calculando…" : "5h: \(ConsumoClaude.tokens(c.cincoHoras.tokens)) · hoje ~\(ConsumoClaude.dolar(c.hoje.custo))")
                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Consumo do Claude Code neste Mac — clique para ver os detalhes")
            .popover(isPresented: $detalhes, arrowEdge: .trailing) { painel }
            .onAppear { c.iniciar() }
        }
    }

    private var painel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Consumo do Claude Code", systemImage: "sparkles").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text("").frame(width: 1)
                    Text("Mensagens").font(.caption.bold()).foregroundStyle(.secondary)
                    Text("Tokens").font(.caption.bold()).foregroundStyle(.secondary)
                    Text("Custo estimado").font(.caption.bold()).foregroundStyle(.secondary)
                }
                linha("Últimas 5 h", c.cincoHoras)
                linha("Hoje", c.hoje)
                linha("7 dias", c.semana)
            }
            if !c.porModelo.isEmpty {
                Divider()
                Text("Por modelo (7 dias)").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(c.porModelo.prefix(5), id: \.0) { m, t in
                    HStack {
                        Text(m).font(.system(size: 11, design: .monospaced))
                        Spacer()
                        Text("\(ConsumoClaude.tokens(t.tokens)) · \(ConsumoClaude.dolar(t.custo))").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            Text("Tokens incluem leitura e escrita de cache. O custo é uma estimativa pelo preço da API — no plano de assinatura não há cobrança por token. O percentual do limite do plano fica só na página de uso do Claude.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Abrir página de uso") { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }
                Spacer()
                if let a = c.atualizado { Text("atualizado \(a.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.tertiary) }
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 420)
    }

    private func linha(_ t: String, _ x: TotaisClaude) -> some View {
        GridRow {
            Text(t).font(.callout)
            Text("\(x.mensagens)").font(.callout.monospacedDigit())
            Text(ConsumoClaude.tokens(x.tokens)).font(.callout.monospacedDigit())
            Text(ConsumoClaude.dolar(x.custo)).font(.callout.monospacedDigit())
        }
    }
}
