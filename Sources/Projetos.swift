import AppKit
import SwiftUI

// MARK: - Projetos configurados
//
// Na primeira vez, procura projetos React Native nas pastas comuns do usuário.
// Depois, a lista fica salva e pode ser editada (adicionar/remover) pelo app.

struct ProjetoCfg: Codable, Hashable {
    var nome: String
    var caminho: String
}

enum Projetos {
    nonisolated(unsafe) static var lista: [ProjetoCfg] = carregar()

    private static let chave = "projetos"

    /// Pastas escolhidas pelo usuário como "onde ficam os projetos" (também entram na busca automática)
    static var pastasRaiz: [String] {
        get { UserDefaults.standard.stringArray(forKey: "pastasProjetos") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "pastasProjetos") }
    }

    static func carregar() -> [ProjetoCfg] {
        if let d = UserDefaults.standard.data(forKey: chave), let l = try? JSONDecoder().decode([ProjetoCfg].self, from: d) {
            return l.filter { FileManager.default.fileExists(atPath: $0.caminho) }
        }
        let l = descobrir()
        salvar(l)
        return l
    }

    static func salvar(_ l: [ProjetoCfg]) {
        if let d = try? JSONEncoder().encode(l) { UserDefaults.standard.set(d, forKey: chave) }
    }

    static func ehReactNative(_ pasta: String) -> Bool {
        guard let d = FileManager.default.contents(atPath: "\(pasta)/package.json"),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }
        let deps = (j["dependencies"] as? [String: Any] ?? [:]).merging(j["devDependencies"] as? [String: Any] ?? [:]) { a, _ in a }
        return deps["react-native"] != nil || deps["expo"] != nil
    }

    /// Procura projetos React Native/Expo até 3 níveis abaixo das pastas comuns
    /// (ou só dentro de `somente`, quando o usuário escolhe uma pasta)
    static func descobrir(somente: [String]? = nil) -> [ProjetoCfg] {
        let home = Config.home
        let raizes = somente ?? (pastasRaiz + [home, "\(home)/Documents", "\(home)/Desktop", "\(home)/Projects", "\(home)/Projetos",
                      "\(home)/Developer", "\(home)/dev", "\(home)/code", "\(home)/workspace", "\(home)/www", "\(home)/git"])
        let ignorar: Set<String> = ["node_modules", "Library", "Applications", "Movies", "Music", "Pictures", "Public",
                                    ".Trash", "android", "ios", "Pods", ".git", "build", "BuildRemoto"]
        var achados: [ProjetoCfg] = []
        var vistos = Set<String>()
        func varrer(_ dir: String, _ nivel: Int) {
            guard nivel <= 3, let itens = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
            for i in itens where !i.hasPrefix(".") && !ignorar.contains(i) {
                let p = "\(dir)/\(i)"
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue,
                      !vistos.contains(p), !i.hasSuffix(".worktrees") else { continue }
                vistos.insert(p)
                if ehReactNative(p) {
                    var nome = i
                    var n = 2
                    while achados.contains(where: { $0.nome == nome }) { nome = "\(i)-\(n)"; n += 1 }
                    achados.append(ProjetoCfg(nome: nome, caminho: p))
                } else if nivel < 3 {
                    varrer(p, nivel + 1)
                }
            }
        }
        for r in raizes {
            // a própria pasta escolhida pode ser um projeto
            if somente != nil, ehReactNative(r), !vistos.contains(r) {
                vistos.insert(r)
                achados.append(ProjetoCfg(nome: (r as NSString).lastPathComponent, caminho: r))
                continue
            }
            varrer(r, r == home ? 1 : (somente != nil ? 0 : 2))
        }
        return achados.sorted { $0.nome.lowercased() < $1.nome.lowercased() }
    }
}

extension AppState {
    func adicionarProjeto() {
        let painel = NSOpenPanel()
        painel.canChooseDirectories = true
        painel.canChooseFiles = false
        painel.allowsMultipleSelection = true
        painel.prompt = "Adicionar"
        painel.message = "Escolha a pasta do app (onde fica o package.json)"
        guard painel.runModal() == .OK else { return }
        var l = Projetos.lista
        for u in painel.urls {
            guard FileManager.default.fileExists(atPath: u.appendingPathComponent("package.json").path) else {
                erro = "\(u.lastPathComponent) não tem package.json."
                continue
            }
            guard !l.contains(where: { $0.caminho == u.path }) else { continue }
            var nome = u.lastPathComponent
            var n = 2
            while l.contains(where: { $0.nome == nome }) { nome = "\(u.lastPathComponent)-\(n)"; n += 1 }
            l.append(ProjetoCfg(nome: nome, caminho: u.path))
        }
        definirProjetos(l)
    }

    /// Escolhe a pasta onde ficam os projetos, procura apps dentro dela e adiciona à lista
    func escolherPastaDeProjetos() {
        let painel = NSOpenPanel()
        painel.canChooseDirectories = true
        painel.canChooseFiles = false
        painel.prompt = "Usar esta pasta"
        painel.message = "Escolha a pasta onde ficam seus projetos (ex.: ~/Trabalho). Os apps dentro dela serão encontrados."
        guard painel.runModal() == .OK, let u = painel.url else { return }
        if !Projetos.pastasRaiz.contains(u.path) { Projetos.pastasRaiz.append(u.path) }
        let achados = Projetos.descobrir(somente: [u.path])
        if achados.isEmpty { erro = "Nenhum app React Native encontrado em \(u.lastPathComponent) (até 3 níveis de pastas)." }
        var l = Projetos.lista
        for a in achados where !l.contains(where: { $0.caminho == a.caminho }) {
            var x = a
            var n = 2
            while l.contains(where: { $0.nome == x.nome }) { x.nome = "\(a.nome)-\(n)"; n += 1 }
            l.append(x)
        }
        definirProjetos(l)
    }

    /// Aponta um app da lista para outra pasta (ex.: projeto movido)
    func alterarLocal(_ p: String) {
        let painel = NSOpenPanel()
        painel.canChooseDirectories = true
        painel.canChooseFiles = false
        painel.prompt = "Usar esta pasta"
        painel.message = "Nova pasta de \(p) (onde fica o package.json)"
        painel.directoryURL = URL(fileURLWithPath: Config.pasta(p)).deletingLastPathComponent()
        guard painel.runModal() == .OK, let u = painel.url else { return }
        guard FileManager.default.fileExists(atPath: u.appendingPathComponent("package.json").path) else {
            erro = "\(u.lastPathComponent) não tem package.json."; return
        }
        definirProjetos(Projetos.lista.map { $0.nome == p ? ProjetoCfg(nome: p, caminho: u.path) : $0 })
    }

    func removerProjeto(_ p: String) {
        definirProjetos(Projetos.lista.filter { $0.nome != p })
    }

    func definirProjetos(_ l: [ProjetoCfg]) {
        Projetos.lista = l
        Projetos.salvar(l)
        recarregarIcones()
        if selecionado == nil || !Config.projetos.contains(selecionado!) { selecionado = Config.projetos.first }
        objectWillChange.send()
    }
}

// MARK: - Boas-vindas (primeira abertura)

struct BoasVindasSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var procurando = false
    @StateObject private var req = Requisitos()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bem-vindo ao Build Remoto").font(.title.bold())
                    Text(Config.temPC
                         ? "Builds no PC ou no próprio Mac, com tela do celular, logs, APKs, bugs e notas por app."
                         : "Rode, depure e acompanhe seus apps React Native neste Mac — tela do celular, logs, APKs, bugs e notas por app.")
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            ListaRequisitos(req: req)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.35)))
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Onde ficam seus projetos").font(.headline)
                    Spacer()
                    Button { app.escolherPastaDeProjetos() } label: { Label("Escolher pasta…", systemImage: "folder.badge.plus") }
                }
                if Projetos.pastasRaiz.isEmpty {
                    Text("Opcional: escolha a pasta onde você guarda os projetos (ex.: ~/Trabalho) e os apps dentro dela são encontrados automaticamente.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Projetos.pastasRaiz, id: \.self) { r in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.blue)
                        Text(r.replacingOccurrences(of: Config.home, with: "~")).font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Button { Projetos.pastasRaiz.removeAll { $0 == r }; app.objectWillChange.send() } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless).help("Não procurar mais nesta pasta")
                    }
                }
            }
            HStack {
                Text("Seus apps").font(.headline)
                Text("\(Config.projetos.count) encontrado(s)").foregroundStyle(.secondary)
                Spacer()
                Button {
                    procurando = true
                    DispatchQueue.global().async {
                        let achados = Projetos.descobrir()
                        DispatchQueue.main.async {
                            var l = Projetos.lista
                            for a in achados where !l.contains(where: { $0.caminho == a.caminho }) { l.append(a) }
                            app.definirProjetos(l)
                            procurando = false
                        }
                    }
                } label: {
                    if procurando { ProgressView().controlSize(.small) } else { Label("Procurar de novo", systemImage: "magnifyingglass") }
                }
                Button { app.adicionarProjeto() } label: { Label("Adicionar um app…", systemImage: "plus") }
            }
            List {
                ForEach(Projetos.lista, id: \.self) { p in
                    HStack(spacing: 10) {
                        IconeApp(projeto: p.nome, tamanho: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.nome).font(.system(size: 13, weight: .medium))
                            Text(p.caminho.replacingOccurrences(of: Config.home, with: "~")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { app.alterarLocal(p.nome) } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless).help("Alterar o local deste app")
                        Button { app.removerProjeto(p.nome) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Tirar da lista (não apaga nada)")
                    }
                }
            }
            .frame(minHeight: 180, maxHeight: 260)
            .overlay {
                if Config.projetos.isEmpty {
                    ContentUnavailableView("Nenhum app encontrado", systemImage: "folder.badge.questionmark",
                                           description: Text("Use \"Adicionar pasta…\" e escolha a pasta do projeto."))
                }
            }
        }
        .padding(24)
        }
            Divider()
            HStack {
                if !req.faltandoEssenciais.isEmpty {
                    Text("Dá para começar mesmo assim; o que faltar aparece no Diagnóstico.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Começar") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(Config.projetos.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 760, height: 760)
        .onDisappear { UserDefaults.standard.set(true, forKey: "boasVindasVista") }
    }
}
