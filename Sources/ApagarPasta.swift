import SwiftUI

// MARK: - Apagar node_modules / android / ios (com confirmação)

enum PastaApagavel: String, Identifiable {
    case nodeModules = "node_modules"
    case android = "android"
    case ios = "ios"
    case buildAndroid = "build Android"
    var id: String { rawValue }

    var caminhos: [String] {
        switch self {
        case .nodeModules: ["node_modules"]
        case .android: ["android"]
        case .ios: ["ios"]
        case .buildAndroid: ["android/app/build", "android/build", "android/.gradle", "android/app/.cxx"]
        }
    }

    var titulo: String {
        switch self {
        case .nodeModules: "Apagar node_modules"
        case .android: "Apagar pasta android"
        case .ios: "Apagar pasta ios"
        case .buildAndroid: "Limpar build Android"
        }
    }

    var icone: String {
        switch self {
        case .nodeModules: "shippingbox"
        case .android: "a.square"
        case .ios: "apple.logo"
        case .buildAndroid: "hammer"
        }
    }

    func depois(_ expo: Bool) -> String {
        switch self {
        case .nodeModules: "As dependências são reinstaladas automaticamente no próximo Rodar (yarn install)."
        case .android: expo ? "A pasta é gerada de novo pelo prebuild (o \"Rodar\" faz isso sozinho quando ela não existe)." : ""
        case .ios: expo ? "A pasta é gerada de novo pelo prebuild (expo run:ios / yarn prebuild)." : ""
        case .buildAndroid: "Só a saída do Gradle. O próximo build recompila tudo (fica mais lento uma vez)."
        }
    }
}

extension AppState {
    /// android/ios fazem parte do código (estão no Git)? Então não podem ser apagadas por aqui.
    /// Lê o cache (preenchido em background); na dúvida, trata como "no Git" para não deixar apagar.
    func pastaNoGit(_ p: String, _ pasta: PastaApagavel) -> Bool {
        guard pasta == .android || pasta == .ios else { return false }
        guard let noGit = pastasNoGit[p] else { return true }
        return noGit.contains(pasta.rawValue)
    }

    /// Atualiza em background quais pastas nativas estão no Git
    func atualizarPastasNoGit() async {
        for p in Config.projetos {
            let base = Config.pasta(p)
            let arquivos = await Task.detached { Versoes.rastreados(base) }.value
            pastasNoGit[p] = Set(["android", "ios"].filter { pasta in arquivos.contains { $0.hasPrefix(pasta + "/") } })
        }
    }

    func apagar(_ pasta: PastaApagavel, de p: String, tambemNoPC: Bool) async -> String {
        let base = Config.pasta(p)
        let local = await Shell.run("rm", ["-rf"] + pasta.caminhos.map { "\(base)/\($0)" })
        var msg = local.ok ? "✓ Apagado neste Mac" : "✗ Erro no Mac: \(local.out)"
        if tambemNoPC {
            let remoto = pasta.caminhos.map { "~/apps/\(p)/\($0)" }.joined(separator: " ")
            let r = await Shell.noPC("rm -rf \(remoto)")
            msg += r.ok ? " e no PC" : " · ✗ erro no PC: \(r.out)"
        }
        Shell.notificar(p, "\(pasta.rawValue) apagado", som: "Pop")
        return msg
    }
}

struct ApagarPastaSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let projeto: String
    let pasta: PastaApagavel
    @State private var tamanhoMac: String = "calculando…"
    @State private var tamanhoPC: String = "calculando…"
    @State private var tambemNoPC = true
    @State private var apagando = false
    @State private var resultado: String?

    private var expo: Bool {
        ((try? String(contentsOfFile: "\(Config.pasta(projeto))/package.json", encoding: .utf8)) ?? "").contains("\"expo\":")
    }
    private var rodando: [String] {
        app.sessoes(de: projeto).filter { app.estado($0) == .rodando || app.estado($0) == .local }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "trash.circle.fill").font(.system(size: 34)).foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(pasta.titulo)?").font(.title3.bold())
                    Text(projeto).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(pasta.caminhos, id: \.self) { c in
                    Text("\(Config.pasta(projeto).replacingOccurrences(of: Config.home, with: "~"))/\(c)")
                        .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
                }
                Text("Tamanho neste Mac: \(tamanhoMac)").font(.callout)
            }
            if !pasta.depois(expo).isEmpty {
                Label(pasta.depois(expo), systemImage: "arrow.triangle.2.circlepath").font(.callout)
            }
            if !app.modoLocal && app.pc.online {
                Toggle(isOn: $tambemNoPC) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Apagar também no PC")
                        Text("~/apps/\(projeto) · \(tamanhoPC) — é a cópia usada nos builds do PC").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            if !rodando.isEmpty {
                Label("Este app tem \(rodando.count) tarefa(s) rodando. Pare antes de apagar para não dar erro no meio.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let resultado {
                Text(resultado).font(.callout).foregroundStyle(resultado.contains("✗") ? .red : .green)
            }
            HStack {
                Spacer()
                Button(resultado == nil ? "Cancelar" : "Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
                if resultado == nil {
                    Button(role: .destructive) {
                        apagando = true
                        Task {
                            resultado = await app.apagar(pasta, de: projeto, tambemNoPC: tambemNoPC && !app.modoLocal && app.pc.online)
                            apagando = false
                        }
                    } label: {
                        if apagando { HStack { ProgressView().controlSize(.small); Text("Apagando…") } }
                        else { Text("Apagar") }
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(apagando)
                }
            }
        }
        .padding(22)
        .frame(width: 520)
        .task {
            let base = Config.pasta(projeto)
            let mac = await Shell.run("du", ["-sk"] + pasta.caminhos.map { "\(base)/\($0)" })
            let kb = mac.out.split(separator: "\n").compactMap { Int64($0.split(separator: "\t").first ?? "") }.reduce(0, +)
            tamanhoMac = kb > 0 ? ByteCountFormatter.string(fromByteCount: kb * 1024, countStyle: .file) : "pasta vazia ou inexistente"
            if !app.modoLocal && app.pc.online {
                let pc = await Shell.noPC("du -sck " + pasta.caminhos.map { "~/apps/\(projeto)/\($0)" }.joined(separator: " ") + " 2>/dev/null | tail -1")
                let kbPC = Int64(pc.out.split(separator: "\t").first ?? "") ?? 0
                tamanhoPC = kbPC > 0 ? ByteCountFormatter.string(fromByteCount: kbPC * 1024, countStyle: .file) : "vazio"
            }
        }
    }
}
