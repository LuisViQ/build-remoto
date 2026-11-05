import SwiftUI
import Charts

// MARK: - Saúde do projeto
//
// Dependências desatualizadas, vulnerabilidades, versão do Expo/React Native, pacotes sem uso,
// expo-doctor e do que é feito o APK. Tudo só leitura — nada é instalado ou alterado.

struct PacoteDesatualizado: Codable, Identifiable, Hashable {
    let nome: String
    let atual: String
    let desejada: String
    let ultima: String
    let tipo: String
    var id: String { nome }
    /// major = muda o primeiro número (pode quebrar)
    var nivel: String {
        let a = atual.split(separator: ".").first, u = ultima.split(separator: ".").first
        if a != u { return "major" }
        let a2 = atual.split(separator: ".").dropFirst().first, u2 = ultima.split(separator: ".").dropFirst().first
        return a2 != u2 ? "minor" : "patch"
    }
}

struct ParteApk: Codable, Identifiable, Hashable {
    let nome: String
    let bytes: Int64
    var id: String { nome }
}

struct RelatorioSaude: Codable {
    var data = Date()
    var expo: String?
    var expoUltima: String?
    var reactNative: String?
    var node: String?
    var desatualizados: [PacoteDesatualizado] = []
    var vulnerabilidades: [String: Int] = [:]
    var vulnerabilidadesDetalhe: [String] = []
    var semUso: [String] = []
    var faltando: [String] = []
    var doctor: String?
    var doctorOk: Bool?
    var apk: String?
    var apkTamanho: Int64?
    var apkPartes: [ParteApk] = []
    var nodeModules: Int64?
    var erros: [String] = []

    var nota: Int {
        var n = 100
        n -= min(30, desatualizados.filter { $0.nivel == "major" }.count * 3)
        n -= min(10, desatualizados.filter { $0.nivel != "major" }.count)
        n -= (vulnerabilidades["critical"] ?? 0) * 10 + (vulnerabilidades["high"] ?? 0) * 4 + (vulnerabilidades["moderate"] ?? 0)
        n -= min(10, semUso.count * 2)
        if doctorOk == false { n -= 10 }
        return max(0, min(100, n))
    }
}

@MainActor
final class SaudeModel: ObservableObject {
    let projeto: String
    @Published var relatorio: RelatorioSaude?
    @Published var rodando: String?
    @Published var incluirDoctor = true
    @Published var incluirDepcheck = true

    init(projeto: String) {
        self.projeto = projeto
        if let d = try? Data(contentsOf: arquivo) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            relatorio = try? dec.decode(RelatorioSaude.self, from: d)
        }
    }

    private var arquivo: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BuildRemoto/saude")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u.appendingPathComponent("\(projeto).json")
    }

    private var pasta: String { Config.pasta(projeto) }

    /// Roda no projeto com o Node certo (nvm/.nvmrc); devolve stdout+stderr
    private func sh(_ cmd: String) async -> ShellResult {
        await Shell.run("zsh", ["-lc", "cd \(Adb.aspas(pasta)) && \(Shell.prepararNode)\n\(cmd)"], env: ["CI": "1", "FORCE_COLOR": "0", "NO_COLOR": "1"])
    }

    func analisar() async {
        var r = RelatorioSaude()
        let pkg = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(pasta)/package.json")))) as? [String: Any] ?? [:]
        let deps = (pkg["dependencies"] as? [String: String] ?? [:]).merging(pkg["devDependencies"] as? [String: String] ?? [:]) { a, _ in a }
        let instalada = { (n: String) -> String? in
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(self.pasta)/node_modules/\(n)/package.json"))) as? [String: Any])?["version"] as? String
        }
        r.expo = deps["expo"] != nil ? (instalada("expo") ?? deps["expo"]) : nil
        r.reactNative = instalada("react-native") ?? deps["react-native"]
        r.node = (await sh("node -v")).out.split(separator: "\n").last.map(String.init)

        rodando = "Procurando dependências desatualizadas (yarn outdated)…"
        let out = await sh("yarn outdated --json 2>/dev/null")
        for l in out.out.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any], o["type"] as? String == "table",
                  let body = (o["data"] as? [String: Any])?["body"] as? [[String]] else { continue }
            r.desatualizados = body.compactMap { c in c.count >= 5 ? PacoteDesatualizado(nome: c[0], atual: c[1], desejada: c[2], ultima: c[3], tipo: c[4]) : nil }
        }
        if r.desatualizados.isEmpty && out.out.contains("error") { r.erros.append("yarn outdated: " + String(out.out.suffix(300))) }

        rodando = "Procurando vulnerabilidades (yarn audit)…"
        let au = await sh("yarn audit --json --groups dependencies 2>/dev/null")
        var vistos = Set<String>()
        for l in au.out.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any] else { continue }
            if o["type"] as? String == "auditSummary", let v = (o["data"] as? [String: Any])?["vulnerabilities"] as? [String: Int] {
                r.vulnerabilidades = v
            }
            if o["type"] as? String == "auditAdvisory", let a = (o["data"] as? [String: Any])?["advisory"] as? [String: Any] {
                let t = "[\(a["severity"] as? String ?? "?")] \(a["module_name"] as? String ?? "?"): \(a["title"] as? String ?? "")"
                if vistos.insert(t).inserted { r.vulnerabilidadesDetalhe.append(t) }
            }
        }

        if r.expo != nil {
            rodando = "Conferindo a versão mais nova do Expo…"
            r.expoUltima = (await sh("npm view expo version 2>/dev/null")).out.split(separator: "\n").last.map(String.init)
            if incluirDoctor {
                rodando = "Rodando o expo-doctor (pode baixar o pacote na primeira vez)…"
                let d = await sh("npx --yes expo-doctor 2>&1 | tail -n 60")
                r.doctor = d.out.trimmingCharacters(in: .whitespacesAndNewlines)
                r.doctorOk = !(r.doctor ?? "").lowercased().contains("failed") && !(r.doctor ?? "").contains("✖")
            }
        }

        if incluirDepcheck {
            rodando = "Procurando pacotes sem uso (depcheck)…"
            let dc = await sh("npx --yes depcheck --json 2>/dev/null")
            if let o = try? JSONSerialization.jsonObject(with: Data((dc.out.split(separator: "\n").last ?? "").utf8)) as? [String: Any] {
                // pacotes usados só por config/plugins costumam aparecer como falso positivo
                let ignorar: Set<String> = ["expo", "react-native", "react", "@babel/core", "typescript", "babel-preset-expo"]
                r.semUso = ((o["dependencies"] as? [String]) ?? []).filter { !ignorar.contains($0) }.sorted()
                r.faltando = ((o["missing"] as? [String: Any]) ?? [:]).keys.sorted()
            }
        }

        rodando = "Medindo o node_modules e o APK…"
        if let kb = Int64((await Shell.run("du", ["-sk", "\(pasta)/node_modules"])).out.split(separator: "\t").first ?? "") { r.nodeModules = kb * 1024 }
        if let apk = ApkArquivo.listar(projeto).first {
            r.apk = apk.url.lastPathComponent
            r.apkTamanho = apk.tamanho
            r.apkPartes = await Self.partes(apk.url)
        }

        r.data = Date()
        relatorio = r
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(r).write(to: arquivo)
        rodando = nil
    }

    /// Do que o APK é feito (tamanho comprimido por grupo)
    static func partes(_ apk: URL) async -> [ParteApk] {
        let r = await Shell.run("zipinfo", ["-l", apk.path])
        var grupos: [String: Int64] = [:]
        for l in r.out.split(separator: "\n") {
            let c = l.split(separator: " ", omittingEmptySubsequences: true)
            guard c.count >= 10, c[0].hasPrefix("-"), let comp = Int64(c[5]) else { continue }
            let nome = c[9...].joined(separator: " ")
            let g: String
            if nome.hasPrefix("lib/") { g = "Nativo (lib/" + (nome.split(separator: "/").dropFirst().first.map(String.init) ?? "?") + ")" }
            else if nome.hasSuffix(".dex") { g = "Código Java/Kotlin (dex)" }
            else if nome.contains("index.android.bundle") { g = "JavaScript (bundle)" }
            else if nome.hasPrefix("assets/") { g = "Assets (fontes, imagens do JS)" }
            else if nome.hasPrefix("res/") || nome == "resources.arsc" { g = "Recursos Android (res)" }
            else if nome.hasPrefix("META-INF/") { g = "Assinatura (META-INF)" }
            else { g = "Outros" }
            grupos[g, default: 0] += comp
        }
        return grupos.map { ParteApk(nome: $0.key, bytes: $0.value) }.sorted { $0.bytes > $1.bytes }
    }
}

struct SaudeView: View {
    @ObservedObject var model: SaudeModel
    @State private var filtroNivel = "todos"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let r = model.relatorio {
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 6)
                        Circle().trim(from: 0, to: CGFloat(r.nota) / 100).stroke(cor(r.nota), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(r.nota)").font(.system(size: 16, weight: .bold, design: .rounded))
                    }
                    .frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Saúde de \(model.projeto)").font(.headline)
                        Text("Analisado \(r.data.formatted(.relative(presentation: .named))) · Node \(r.node ?? "?")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Saúde de \(model.projeto)").font(.headline)
                }
                Spacer()
                if let s = model.rodando { ProgressView().controlSize(.small); Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Toggle("expo-doctor", isOn: $model.incluirDoctor).toggleStyle(.checkbox)
                Toggle("Pacotes sem uso", isOn: $model.incluirDepcheck).toggleStyle(.checkbox)
                Button { Task { await model.analisar() } } label: { Label(model.relatorio == nil ? "Analisar" : "Analisar de novo", systemImage: "stethoscope") }
                    .buttonStyle(.borderedProminent).disabled(model.rodando != nil)
            }
            .controlSize(.small)
            .padding(12)
            Divider()
            if let r = model.relatorio {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        resumo(r)
                        desatualizados(r)
                        seguranca(r)
                        if !r.semUso.isEmpty || !r.faltando.isEmpty { semUso(r) }
                        if let d = r.doctor { doctor(d, ok: r.doctorOk ?? true) }
                        apk(r)
                        if !r.erros.isEmpty {
                            ForEach(r.erros, id: \.self) { Text($0).font(.caption.monospaced()).foregroundStyle(.red) }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ContentUnavailableView("Analisar a saúde do projeto", systemImage: "stethoscope",
                                       description: Text("Dependências desatualizadas, vulnerabilidades, versão do Expo, pacotes sem uso, expo-doctor e do que o APK é feito. Só leitura — nada é instalado. Leva de 30 s a alguns minutos e precisa de internet."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func cor(_ n: Int) -> Color { n >= 80 ? .green : n >= 55 ? .orange : .red }

    private func cartao<C: View>(_ titulo: String, _ icone: String, @ViewBuilder _ c: () -> C) -> some View {
        GroupBox { c().frame(maxWidth: .infinity, alignment: .leading).padding(4) } label: { Label(titulo, systemImage: icone).font(.headline) }
    }

    private func resumo(_ r: RelatorioSaude) -> some View {
        HStack(spacing: 22) {
            if let e = r.expo {
                Metrica(valor: e.replacingOccurrences(of: "~", with: "").replacingOccurrences(of: "^", with: ""),
                        rotulo: "Expo" + (r.expoUltima.map { $0 != e ? " (mais nova: \($0))" : " (atual)" } ?? ""),
                        cor: r.expoUltima.map { $0.split(separator: ".").first != e.split(separator: ".").first ? .orange : .green } ?? .blue)
            }
            if let rn = r.reactNative { Metrica(valor: rn, rotulo: "React Native", cor: .blue) }
            Metrica(valor: "\(r.desatualizados.count)", rotulo: "desatualizados", cor: r.desatualizados.isEmpty ? .green : .orange)
            Metrica(valor: "\(r.vulnerabilidades.values.reduce(0, +))", rotulo: "vulnerabilidades",
                    cor: (r.vulnerabilidades["critical"] ?? 0) + (r.vulnerabilidades["high"] ?? 0) > 0 ? .red : .green)
            if let n = r.nodeModules { Metrica(valor: ByteCountFormatter.string(fromByteCount: n, countStyle: .file), rotulo: "node_modules", cor: .secondary) }
            if let t = r.apkTamanho { Metrica(valor: ByteCountFormatter.string(fromByteCount: t, countStyle: .file), rotulo: "último APK", cor: .purple) }
        }
    }

    private func desatualizados(_ r: RelatorioSaude) -> some View {
        cartao("Dependências desatualizadas (\(r.desatualizados.count))", "shippingbox") {
            if r.desatualizados.isEmpty { Text("Tudo em dia ✓").foregroundStyle(.green) } else {
                Picker("", selection: $filtroNivel) {
                    Text("Todas").tag("todos")
                    Text("Major (\(r.desatualizados.filter { $0.nivel == "major" }.count))").tag("major")
                    Text("Minor/patch (\(r.desatualizados.filter { $0.nivel != "major" }.count))").tag("menor")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        ForEach(["Pacote", "Instalada", "Compatível", "Mais nova", ""], id: \.self) { Text($0).font(.caption.bold()).foregroundStyle(.secondary) }
                    }
                    ForEach(r.desatualizados.filter { filtroNivel == "todos" || (filtroNivel == "major") == ($0.nivel == "major") }) { p in
                        GridRow {
                            Text(p.nome).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            Text(p.atual).font(.system(size: 12, design: .monospaced))
                            Text(p.desejada).font(.system(size: 12, design: .monospaced)).foregroundStyle(p.desejada != p.atual ? .blue : .secondary)
                            Text(p.ultima).font(.system(size: 12, design: .monospaced)).foregroundStyle(p.nivel == "major" ? .orange : .primary)
                            Text(p.nivel).font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                                .background((p.nivel == "major" ? Color.orange : .blue).opacity(0.15), in: Capsule())
                        }
                    }
                }
                Text("Em projetos Expo, prefira \"npx expo install --fix\" para as versões compatíveis com o SDK; major pode quebrar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func seguranca(_ r: RelatorioSaude) -> some View {
        cartao("Vulnerabilidades (yarn audit, só dependências de produção)", "lock.shield") {
            if r.vulnerabilidades.values.reduce(0, +) == 0 { Text("Nenhuma encontrada ✓").foregroundStyle(.green) } else {
                HStack(spacing: 14) {
                    ForEach(["critical", "high", "moderate", "low", "info"], id: \.self) { k in
                        if let n = r.vulnerabilidades[k], n > 0 {
                            Text("\(k): \(n)").font(.callout.bold())
                                .foregroundStyle(k == "critical" || k == "high" ? .red : k == "moderate" ? .orange : .secondary)
                        }
                    }
                }
                ForEach(r.vulnerabilidadesDetalhe.prefix(25), id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
            }
        }
    }

    private func semUso(_ r: RelatorioSaude) -> some View {
        cartao("Pacotes (depcheck)", "trash.slash") {
            if !r.semUso.isEmpty {
                Text("Parecem não ser usados no código (\(r.semUso.count)) — confira antes de remover, alguns são usados só por plugins/config:").font(.callout)
                Text(r.semUso.joined(separator: "  ·  ")).font(.caption.monospaced()).textSelection(.enabled)
            }
            if !r.faltando.isEmpty {
                Text("Usados no código mas fora do package.json (\(r.faltando.count)):").font(.callout).foregroundStyle(.orange)
                Text(r.faltando.joined(separator: "  ·  ")).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
    }

    private func doctor(_ d: String, ok: Bool) -> some View {
        cartao("expo-doctor — \(ok ? "sem problemas" : "encontrou problemas")", ok ? "checkmark.seal" : "exclamationmark.triangle") {
            Text(d).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
        }
    }

    private func apk(_ r: RelatorioSaude) -> some View {
        cartao("Do que o APK é feito" + (r.apk.map { " — \($0)" } ?? ""), "chart.bar.xaxis") {
            if r.apkPartes.isEmpty { Text("Gere um APK para ver a composição.").foregroundStyle(.secondary) } else {
                Chart(r.apkPartes) { p in
                    BarMark(x: .value("Tamanho (MB)", Double(p.bytes) / 1_048_576), y: .value("Parte", p.nome))
                        .annotation(position: .trailing) {
                            Text(ByteCountFormatter.string(fromByteCount: p.bytes, countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartXAxisLabel("MB (comprimido)")
                .frame(height: CGFloat(max(r.apkPartes.count, 3)) * 30)
                if r.apkPartes.contains(where: { $0.nome.contains("x86") }) {
                    Text("O APK leva bibliotecas x86/x86_64 (só emulador). Gerando por ABI (splits) ou AAB, o celular baixa só a dele.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}
