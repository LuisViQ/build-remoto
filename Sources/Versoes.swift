import SwiftUI

// MARK: - Versões do app reunidas num só lugar
//
// Procura a versão em todos os lugares onde ela costuma ficar (package.json, app.config/app.json,
// build.gradle, Info.plist, project.pbxproj, constantes do código e versão do banco local),
// mostra as divergências e atualiza tudo de uma vez.

struct FonteVersao: Identifiable, Hashable {
    enum Tipo: String { case nome = "Versão", codigo = "Build", schema = "Banco local", runtime = "Runtime (OTA)" }
    enum Plataforma: String { case geral = "Geral", android = "Android", ios = "iOS" }

    let arquivo: String          // relativo ao projeto
    let rotulo: String
    let tipo: Tipo
    let plataforma: Plataforma
    let valor: String
    let linha: Int
    let intervalo: NSRange       // posição do valor no arquivo
    var observacao = ""
    var id: String { "\(arquivo):\(intervalo.location)" }
    var grupo: String { tipo == .codigo ? "\(tipo.rawValue) \(plataforma.rawValue)" : tipo.rawValue }
}

enum Versoes {
    private struct Regra {
        let arquivos: (String) -> [String]     // projeto -> arquivos relativos
        let padrao: String                     // grupo 1 = valor
        let rotulo: String
        let tipo: FonteVersao.Tipo
        let plataforma: FonteVersao.Plataforma
    }

    private static func existentes(_ base: String, _ nomes: [String]) -> [String] {
        nomes.filter { FileManager.default.fileExists(atPath: "\(base)/\($0)") }
    }

    /// Arquivos do código (src/app) que mencionam algo — para constantes e versão do banco
    private static func codigo(_ base: String, contendo termo: String) -> [String] {
        var r: [String] = []
        for raiz in ["src", "app"] {
            guard let e = FileManager.default.enumerator(atPath: "\(base)/\(raiz)") else { continue }
            while let f = e.nextObject() as? String {
                if f.contains("node_modules") || f.contains("__tests__") { continue }
                guard [".ts", ".tsx", ".js", ".jsx"].contains(where: f.hasSuffix) else { continue }
                if let t = try? String(contentsOfFile: "\(base)/\(raiz)/\(f)", encoding: .utf8), t.contains(termo) {
                    r.append("\(raiz)/\(f)")
                }
            }
        }
        return r
    }

    private static func iosArquivos(_ base: String, _ sufixo: String) -> [String] {
        guard let itens = try? FileManager.default.contentsOfDirectory(atPath: "\(base)/ios") else { return [] }
        if sufixo == "pbxproj" {
            return itens.filter { $0.hasSuffix(".xcodeproj") }.map { "ios/\($0)/project.pbxproj" }
                .filter { FileManager.default.fileExists(atPath: "\(base)/\($0)") }
        }
        return itens.map { "ios/\($0)/Info.plist" }.filter { FileManager.default.fileExists(atPath: "\(base)/\($0)") }
    }

    private static let regras: [Regra] = {
        let cfg = { (b: String) in existentes(b, ["app.json", "app.config.js", "app.config.ts"]) }
        let q = #"["']?"#
        return [
            Regra(arquivos: { existentes($0, ["package.json"]) }, padrao: #""version"\s*:\s*"([^"]+)""#,
                  rotulo: "package.json version", tipo: .nome, plataforma: .geral),
            Regra(arquivos: cfg, padrao: q + #"version"# + q + #"\s*:\s*["']([0-9][^"']*)["']"#,
                  rotulo: "version", tipo: .nome, plataforma: .geral),
            Regra(arquivos: cfg, padrao: q + #"versionCode"# + q + #"\s*:\s*(\d+)"#,
                  rotulo: "android.versionCode", tipo: .codigo, plataforma: .android),
            Regra(arquivos: cfg, padrao: q + #"buildNumber"# + q + #"\s*:\s*["'](\d+)["']"#,
                  rotulo: "ios.buildNumber", tipo: .codigo, plataforma: .ios),
            Regra(arquivos: cfg, padrao: q + #"runtimeVersion"# + q + #"\s*:\s*["']([^"']+)["']"#,
                  rotulo: "runtimeVersion", tipo: .runtime, plataforma: .geral),
            Regra(arquivos: { existentes($0, ["android/app/build.gradle", "android/app/build.gradle.kts"]) },
                  padrao: #"versionCode\s*=?\s*(\d+)"#, rotulo: "versionCode", tipo: .codigo, plataforma: .android),
            Regra(arquivos: { existentes($0, ["android/app/build.gradle", "android/app/build.gradle.kts"]) },
                  padrao: #"versionName\s*=?\s*["']([^"']+)["']"#, rotulo: "versionName", tipo: .nome, plataforma: .android),
            Regra(arquivos: { iosArquivos($0, "plist") },
                  padrao: #"<key>CFBundleShortVersionString</key>\s*<string>([^<$]+)</string>"#,
                  rotulo: "CFBundleShortVersionString", tipo: .nome, plataforma: .ios),
            Regra(arquivos: { iosArquivos($0, "plist") }, padrao: #"<key>CFBundleVersion</key>\s*<string>([^<$]+)</string>"#,
                  rotulo: "CFBundleVersion", tipo: .codigo, plataforma: .ios),
            Regra(arquivos: { iosArquivos($0, "pbxproj") }, padrao: #"MARKETING_VERSION = ([^;]+);"#,
                  rotulo: "MARKETING_VERSION", tipo: .nome, plataforma: .ios),
            Regra(arquivos: { iosArquivos($0, "pbxproj") }, padrao: #"CURRENT_PROJECT_VERSION = ([^;]+);"#,
                  rotulo: "CURRENT_PROJECT_VERSION", tipo: .codigo, plataforma: .ios),
            Regra(arquivos: { codigo($0, contendo: "nativeApplicationVersion") },
                  padrao: #"nativeApplicationVersion\s*\|\|\s*["']([^"']+)["']"#, rotulo: "fallback de VERSION", tipo: .nome, plataforma: .geral),
            Regra(arquivos: { codigo($0, contendo: "schemaVersion:") }, padrao: #"schemaVersion\s*:\s*(\d+)"#,
                  rotulo: "Realm schemaVersion", tipo: .schema, plataforma: .geral),
            Regra(arquivos: { codigo($0, contendo: "appSchema(") }, padrao: #"appSchema\(\{\s*version\s*:\s*(\d+)"#,
                  rotulo: "WatermelonDB schema version", tipo: .schema, plataforma: .geral),
        ]
    }()

    /// Arquivos versionados no Git (para saber se android/ e ios/ são do projeto ou gerados).
    /// Síncrono: nunca chamar a partir de um body de view (use o cache do AppState ou rode em background).
    static func rastreados(_ base: String) -> Set<String> {
        let p = Shell.processo("git", ["-C", base, "ls-files", "android", "ios"])
        let saida = Pipe()
        p.standardOutput = saida
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        // Só lê até o fim (EOF = git terminou). waitUntilExit() gira o run loop e pode reentrar no SwiftUI.
        let d = saida.fileHandleForReading.readDataToEndOfFile()
        return Set(String(decoding: d, as: UTF8.self).split(separator: "\n").map(String.init))
    }

    /// android/ e ios/ existem mas não estão no Git: são gerados pelo Expo (prebuild)
    static func nativoGerado(_ projeto: String) -> Bool {
        let base = Config.pasta(projeto)
        let temNativo = ["android", "ios"].contains { FileManager.default.fileExists(atPath: "\(base)/\($0)") }
        return temNativo && rastreados(base).isEmpty
    }

    static func ler(_ projeto: String) -> [FonteVersao] {
        let base = Config.pasta(projeto)
        var r: [FonteVersao] = []
        var vistos = Set<String>()
        // Arquivos nativos só contam quando estão no Git; senão são gerados (Expo) a partir do app.config
        let noGit = rastreados(base)
        for regra in regras {
            for arq in regra.arquivos(base) {
                if (arq.hasPrefix("android/") || arq.hasPrefix("ios/")) && !noGit.contains(arq) { continue }
                guard let texto = try? String(contentsOfFile: "\(base)/\(arq)", encoding: .utf8),
                      let re = try? NSRegularExpression(pattern: regra.padrao, options: [.anchorsMatchLines]) else { continue }
                let ns = texto as NSString
                for m in re.matches(in: texto, range: NSRange(location: 0, length: ns.length)) {
                    let rg = m.range(at: 1)
                    let chave = "\(arq):\(rg.location)"
                    guard !vistos.contains(chave) else { continue }
                    vistos.insert(chave)
                    let linha = ns.substring(to: rg.location).filter { $0 == "\n" }.count + 1
                    var rotulo = regra.rotulo
                    var plataforma = regra.plataforma
                    if rotulo == "version" {
                        // version dentro do bloco ios/android do app.config
                        let ctx = contexto(ns, antes: rg.location)
                        if ctx == "ios" { rotulo = "ios.version"; plataforma = .ios }
                        else if ctx == "android" { rotulo = "android.version"; plataforma = .android }
                        else { rotulo = "expo.version" }
                    }
                    var f = FonteVersao(arquivo: arq, rotulo: rotulo, tipo: regra.tipo, plataforma: plataforma,
                                        valor: ns.substring(with: rg).trimmingCharacters(in: CharacterSet(charactersIn: "\" ")),
                                        linha: linha, intervalo: rg)
                    if arq.hasSuffix("project.pbxproj") && iosArquivos(base, "plist").contains(where: { p in
                        ((try? String(contentsOfFile: "\(base)/\(p)", encoding: .utf8)) ?? "").contains(regra.tipo == .nome ? "<string>$(MARKETING_VERSION)" : "<string>$(CURRENT_PROJECT_VERSION)") == false
                    }) {
                        f.observacao = "o Info.plist tem valor fixo, então este campo não é usado"
                    }
                    if regra.tipo == .schema { f.observacao = "só aumente quando mudar os modelos do banco; nunca diminua" }
                    if regra.tipo == .runtime { f.observacao = "mude quando houver mudança nativa (atualizações OTA)" }
                    r.append(f)
                }
            }
        }
        return r
    }

    /// Bloco ios/android mais próximo acima da posição (pela indentação)
    private static func contexto(_ ns: NSString, antes pos: Int) -> String? {
        let anterior = ns.substring(to: pos).components(separatedBy: "\n")
        guard let atual = anterior.last else { return nil }
        let recuo = atual.prefix { $0 == " " }.count
        for l in anterior.dropLast().reversed() {
            let r = l.prefix { $0 == " " }.count
            let t = l.trimmingCharacters(in: .whitespaces)
            if r < recuo && t.hasSuffix("{") {
                if t.range(of: #"^["']?ios["']?\s*:"#, options: .regularExpression) != nil { return "ios" }
                if t.range(of: #"^["']?android["']?\s*:"#, options: .regularExpression) != nil { return "android" }
                return nil
            }
        }
        return nil
    }

    /// Grava os novos valores (por arquivo, de trás para frente para manter as posições)
    static func aplicar(_ projeto: String, _ mudancas: [(FonteVersao, String)]) -> [String] {
        let base = Config.pasta(projeto)
        var alterados: [String] = []
        for (arq, itens) in Dictionary(grouping: mudancas, by: { $0.0.arquivo }) {
            guard var texto = try? String(contentsOfFile: "\(base)/\(arq)", encoding: .utf8) else { continue }
            let ns = NSMutableString(string: texto)
            for (f, novo) in itens.sorted(by: { $0.0.intervalo.location > $1.0.intervalo.location }) {
                ns.replaceCharacters(in: f.intervalo, with: novo)
            }
            texto = ns as String
            try? texto.write(toFile: "\(base)/\(arq)", atomically: true, encoding: .utf8)
            alterados.append(arq)
        }
        return alterados.sorted()
    }

    /// Calcula o próximo código de build seguindo o padrão que o projeto já usa
    /// (ex.: 2.8.9 → 2080903 = 2·10⁶ + 8·10⁴ + 9·100 + 3)
    static func sugerirCodigo(versaoAtual: String, codigoAtual: Int, novaVersao: String) -> Int {
        let p = { (v: String) -> [Int] in
            let n = v.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
            return (n + [0, 0, 0]).prefix(3).map { $0 }
        }
        let a = p(versaoAtual), b = p(novaVersao)
        let padroes: [(Int, Int, Int)] = [(1_000_000, 10_000, 100), (1_000_000, 10_000, 10), (10_000, 100, 1), (100_000, 1_000, 10)]
        for (x, y, z) in padroes {
            let base = a[0] * x + a[1] * y + a[2] * z
            let resto = codigoAtual - base
            if resto >= 0 && resto < z || (z == 1 && resto == 0) {
                if a == b { return codigoAtual + 1 }
                return b[0] * x + b[1] * y + b[2] * z
            }
        }
        return codigoAtual + 1
    }

    static func incrementar(_ v: String, _ parte: Int) -> String {
        var n = v.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        while n.count < 3 { n.append(0) }
        n[parte] += 1
        for i in (parte + 1)..<3 { n[i] = 0 }
        return n.prefix(3).map(String.init).joined(separator: ".")
    }
}

// MARK: - Aba Versões

struct VersoesView: View {
    @EnvironmentObject var app: AppState
    let projeto: String
    @State private var gerado = false
    @State private var fontes: [FonteVersao] = []
    @State private var novaVersao = ""
    @State private var novoCodigoAndroid = ""
    @State private var novoCodigoIOS = ""
    @State private var novoSchema = ""
    @State private var marcadas: Set<String> = []
    @State private var resultado: (arquivos: [String], diff: String)?
    @State private var commitFeito = ""

    private var versaoPrincipal: String {
        let nomes = fontes.filter { $0.tipo == .nome && $0.observacao.isEmpty && $0.rotulo != "fallback de VERSION" }.map(\.valor)
        return Dictionary(grouping: nomes, by: { $0 }).max { $0.value.count < $1.value.count }?.key ?? "0.0.0"
    }
    private func principal(_ grupo: String) -> String? {
        let v = fontes.filter { $0.grupo == grupo && $0.observacao.isEmpty }.map(\.valor)
        return Dictionary(grouping: v, by: { $0 }).max { a, b in a.value.count < b.value.count || (a.value.count == b.value.count && (Int(a.key) ?? 0) < (Int(b.key) ?? 0)) }?.key
    }

    var body: some View {
        HSplitView {
            // Lista de fontes
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Onde a versão aparece").font(.headline)
                    Spacer()
                    Button { app.gerarVersaoDe = projeto } label: { Label("Gerar versão…", systemImage: "shippingbox.and.arrow.backward") }
                        .controlSize(.small).buttonStyle(.borderedProminent)
                        .help("Fluxo completo: relatório → versão → commit/tag → APK release → conferência")
                    let div = divergencias
                    if div > 0 {
                        Label("\(div) divergente(s)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption.bold())
                    } else if !fontes.isEmpty {
                        Label("tudo igual", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.caption.bold())
                    }
                    Button { carregar() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                }
                .padding(12)
                if gerado {
                    Label("android/ e ios/ são gerados pelo Expo (estão no .gitignore), então a versão vem só do app.config. "
                          + "Depois de mudar, rode o prebuild para os arquivos nativos receberem a versão nova.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.bottom, 8)
                }
                Divider()
                List {
                    ForEach(["Versão", "Build Android", "Build iOS", "Runtime (OTA)", "Banco local"], id: \.self) { g in
                        let itens = fontes.filter { $0.grupo == g }
                        if !itens.isEmpty {
                            Section(g) {
                                ForEach(itens) { f in LinhaFonte(projeto: projeto, f: f, esperado: esperado(f), marcada: binding(f)) }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            .frame(minWidth: 460, maxHeight: .infinity, alignment: .top)

            // Painel de atualização
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Nova versão").font(.title3.bold())
                    Grupo(titulo: "Versão do app", icone: "number", subtitulo: "atual: \(versaoPrincipal)") {
                        HStack {
                            TextField("ex.: 2.9.0", text: $novaVersao).textFieldStyle(.roundedBorder).font(.system(size: 15, weight: .semibold, design: .monospaced))
                                .frame(width: 130)
                                .onChange(of: novaVersao) { _, _ in recalcularCodigos() }
                            Button("+ patch") { novaVersao = Versoes.incrementar(versaoPrincipal, 2) }
                            Button("+ minor") { novaVersao = Versoes.incrementar(versaoPrincipal, 1) }
                            Button("+ major") { novaVersao = Versoes.incrementar(versaoPrincipal, 0) }
                        }
                    }
                    Grupo(titulo: "Código de build", icone: "barcode", subtitulo: "calculado pelo padrão do projeto; pode editar") {
                        if principal("Build Android") != nil {
                            HStack {
                                Text("Android versionCode").frame(width: 150, alignment: .leading)
                                TextField("", text: $novoCodigoAndroid).textFieldStyle(.roundedBorder).frame(width: 120)
                                Text("atual \(principal("Build Android") ?? "—")").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if principal("Build iOS") != nil {
                            HStack {
                                Text("iOS build").frame(width: 150, alignment: .leading)
                                TextField("", text: $novoCodigoIOS).textFieldStyle(.roundedBorder).frame(width: 120)
                                Text("atual \(principal("Build iOS") ?? "—")").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let s = fontes.first(where: { $0.tipo == .schema }) {
                        Grupo(titulo: "Versão do banco local", icone: "cylinder", subtitulo: s.rotulo) {
                            HStack {
                                TextField("manter \(s.valor)", text: $novoSchema).textFieldStyle(.roundedBorder).frame(width: 130)
                                Button("+1") { novoSchema = String((Int(s.valor) ?? 0) + 1) }
                                Text("atual \(s.valor)").font(.caption).foregroundStyle(.secondary)
                            }
                            Label("Só aumente quando mudar os modelos/tabelas do banco. Nunca diminua: quem já tem o app instalado perderia os dados ao abrir.",
                                  systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    let mudancas = planejar()
                    Grupo(titulo: "O que vai mudar", icone: "list.bullet", subtitulo: "\(mudancas.count) alteração(ões) em \(Set(mudancas.map(\.0.arquivo)).count) arquivo(s)") {
                        if mudancas.isEmpty {
                            Text("Defina a nova versão (ou ajuste os campos) para ver as alterações.").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(mudancas, id: \.0.id) { f, novo in
                            HStack(spacing: 6) {
                                Text(f.arquivo).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                Text(f.rotulo).font(.system(size: 11))
                                Spacer()
                                Text(f.valor).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.red).strikethrough()
                                Image(systemName: "arrow.right").font(.caption2)
                                Text(novo).font(.system(size: 11.5, weight: .bold, design: .monospaced)).foregroundStyle(.green)
                            }
                        }
                        Button {
                            let arquivos = Versoes.aplicar(projeto, mudancas)
                            Task {
                                let d = await Shell.run("git", ["-C", Config.pasta(projeto), "diff", "--stat", "--"] + arquivos).out
                                resultado = (arquivos, d)
                                carregar()
                            }
                        } label: {
                            Label("Aplicar em todos os arquivos", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(mudancas.isEmpty)
                    }
                    if let r = resultado {
                        Grupo(titulo: "Atualizado", icone: "checkmark.seal.fill", subtitulo: "\(r.arquivos.count) arquivo(s)") {
                            Text(r.diff.isEmpty ? r.arquivos.joined(separator: "\n") : r.diff)
                                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            HStack {
                                Button("Criar commit") {
                                    let v = novaVersao.isEmpty ? versaoPrincipal : novaVersao
                                    let codigo = novoCodigoAndroid.isEmpty ? "" : " (\(novoCodigoAndroid))"
                                    Task {
                                        let pasta = Config.pasta(projeto)
                                        _ = await Shell.run("git", ["-C", pasta, "add", "--"] + r.arquivos)
                                        let c = await Shell.run("git", ["-C", pasta, "commit", "-m", "chore: versão \(v)\(codigo)", "--"] + r.arquivos)
                                        commitFeito = c.ok ? "✓ commit criado: chore: versão \(v)\(codigo)" : "✗ \(c.out)"
                                    }
                                }
                                if gerado {
                                    let temScript = AtalhosStore.de(projeto).scripts.contains { $0.0 == "prebuild" }
                                    Button(temScript ? "Rodar yarn prebuild" : "Rodar expo prebuild") {
                                        app.rodarComando(projeto, nome: "Prebuild", comando: temScript ? "yarn prebuild" : "npx expo prebuild --no-install",
                                                         noPC: !app.modoLocal)
                                    }
                                    .help("Regenera android/ e ios/ a partir do app.config, levando a versão nova para o build")
                                }
                                Button("Desfazer") {
                                    Task {
                                        _ = await Shell.run("git", ["-C", Config.pasta(projeto), "checkout", "--"] + r.arquivos)
                                        resultado = nil
                                        carregar()
                                    }
                                }
                                .help("Volta os arquivos ao que estava no último commit")
                            }
                            if !commitFeito.isEmpty { Text(commitFeito).font(.caption).foregroundStyle(commitFeito.hasPrefix("✓") ? .green : .red) }
                        }
                    }
                }
                .padding(18)
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { carregar() }
    }

    private var divergencias: Int { fontes.filter { esperado($0) != nil }.count }

    /// Valor que esta fonte deveria ter (nil = está igual às demais)
    private func esperado(_ f: FonteVersao) -> String? {
        guard f.tipo == .nome || f.tipo == .codigo, f.observacao.isEmpty else { return nil }
        let alvo = f.tipo == .nome ? versaoPrincipal : principal(f.grupo)
        guard let alvo, f.valor != alvo else { return nil }
        // "1.3" como fallback é aceitável se for prefixo de 1.3.0? Melhor alinhar mesmo assim.
        return alvo
    }

    private func binding(_ f: FonteVersao) -> Binding<Bool> {
        Binding(get: { marcadas.contains(f.id) }, set: { if $0 { marcadas.insert(f.id) } else { marcadas.remove(f.id) } })
    }

    private func carregar() {
        let p = projeto
        Task {
            // leitura de arquivos e git fora da thread principal
            let (g, f) = await Task.detached { (Versoes.nativoGerado(p), Versoes.ler(p)) }.value
            gerado = g
            fontes = f
            // por padrão, atualiza tudo menos banco local e campos não usados
            marcadas = Set(fontes.filter { $0.tipo != .schema && $0.tipo != .runtime && $0.observacao.isEmpty }.map(\.id))
            if novaVersao.isEmpty { recalcularCodigos() }
        }
    }

    private func recalcularCodigos() {
        let v = novaVersao.isEmpty ? versaoPrincipal : novaVersao
        for (g, destino) in [("Build Android", 0), ("Build iOS", 1)] {
            guard let atual = principal(g).flatMap(Int.init) else { continue }
            let sugerido = novaVersao.isEmpty ? atual : Versoes.sugerirCodigo(versaoAtual: versaoPrincipal, codigoAtual: atual, novaVersao: v)
            if destino == 0 { novoCodigoAndroid = String(sugerido) } else { novoCodigoIOS = String(sugerido) }
        }
    }

    /// Alterações a fazer: fontes marcadas com valor diferente do novo
    private func planejar() -> [(FonteVersao, String)] {
        let v = novaVersao.isEmpty ? versaoPrincipal : novaVersao
        return fontes.compactMap { f in
            let novo: String?
            switch f.tipo {
            case .nome: novo = marcadas.contains(f.id) ? v : nil
            case .codigo:
                let c = f.plataforma == .ios ? novoCodigoIOS : novoCodigoAndroid
                novo = marcadas.contains(f.id) && !c.isEmpty ? c : nil
            case .schema: novo = novoSchema.isEmpty ? nil : novoSchema
            case .runtime: novo = nil
            }
            guard let novo, novo != f.valor else { return nil }
            return (f, novo)
        }
    }
}

struct LinhaFonte: View {
    let projeto: String
    let f: FonteVersao
    let esperado: String?
    @Binding var marcada: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if f.tipo == .nome || f.tipo == .codigo {
                Toggle("", isOn: $marcada).labelsHidden().toggleStyle(.checkbox).help("Atualizar este campo")
            } else {
                Image(systemName: f.tipo == .schema ? "cylinder" : "bolt.horizontal").foregroundStyle(.secondary).frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(f.rotulo).font(.system(size: 12.5, weight: .medium))
                    if f.plataforma != .geral {
                        Text(f.plataforma.rawValue).font(.system(size: 9, weight: .heavy)).padding(.horizontal, 4)
                            .background(Capsule().fill(.quaternary))
                    }
                }
                Text("\(f.arquivo):\(f.linha)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                if !f.observacao.isEmpty { Text(f.observacao).font(.system(size: 10.5)).foregroundStyle(.tertiary) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(f.valor).font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(esperado == nil ? Color.primary : .orange)
                if let e = esperado {
                    Text("outros: \(e)").font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            Button { abrir() } label: { Image(systemName: "arrow.up.forward.app") }.buttonStyle(.borderless).help("Abrir o arquivo")
        }
        .padding(.vertical, 2)
    }

    private func abrir() {
        let url = URL(fileURLWithPath: "\(Config.pasta(projeto))/\(f.arquivo)")
        NSWorkspace.shared.open(url)
    }
}
