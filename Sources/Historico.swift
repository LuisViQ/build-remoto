import SwiftUI

// MARK: - Histórico de execuções (log completo + resumo do erro)
//
// Cada execução que termina (build, yarn android, install, clean…) é guardada em
// ~/Library/Application Support/BuildRemoto/historico/<projeto>/, com o log bruto (.log)
// e os dados da execução (.json). Mantém as 150 mais recentes por projeto.

struct Execucao: Codable, Identifiable, Hashable {
    var projeto: String
    var acao: String
    var origem: String          // PC | Mac
    var inicio: Date?
    var fim: Date
    var codigo: Int
    var branch: String
    var commit: String
    var arquivo: String         // nome base (sem extensão)
    var id: String { arquivo }
    var ok: Bool { codigo == 0 }
    var interrompido: Bool { codigo == 130 }

    var duracao: String {
        guard let inicio else { return "—" }
        let s = Int(fim.timeIntervalSince(inicio))
        return s >= 60 ? "\(s / 60)min \(s % 60)s" : "\(s)s"
    }
}

enum Historico {
    static func pasta(_ projeto: String) -> URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BuildRemoto/historico/\(projeto)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func logURL(_ e: Execucao) -> URL { pasta(e.projeto).appendingPathComponent(e.arquivo + ".log") }

    static func registrar(projeto: String, acao: String, origem: String, inicio: Date?, codigo: Int, log: String) async {
        let g = { (a: [String]) async -> String in
            await Shell.run("git", ["-C", "\(Config.pasta(projeto))"] + a).out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd-HHmmss"
        let fim = Date()
        let base = "\(fmt.string(from: fim))_\(acao)_\(codigo == 0 ? "ok" : "falha")"
        let e = Execucao(projeto: projeto, acao: acao, origem: origem, inicio: inicio, fim: fim, codigo: codigo,
                         branch: await g(["branch", "--show-current"]), commit: await g(["log", "-1", "--pretty=%h %s"]),
                         arquivo: base)
        let dir = pasta(projeto)
        try? log.write(to: dir.appendingPathComponent(base + ".log"), atomically: true, encoding: .utf8)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .prettyPrinted
        try? enc.encode(e).write(to: dir.appendingPathComponent(base + ".json"))
        limpar(projeto)
    }

    static func listar(_ projeto: String) -> [Execucao] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let arqs = (try? FileManager.default.contentsOfDirectory(at: pasta(projeto), includingPropertiesForKeys: nil)) ?? []
        return arqs.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? dec.decode(Execucao.self, from: $0) } }
            .sorted { $0.fim > $1.fim }
    }

    private static func limpar(_ projeto: String) {
        for e in listar(projeto).dropFirst(150) {
            try? FileManager.default.removeItem(at: logURL(e))
            try? FileManager.default.removeItem(at: logURL(e).deletingPathExtension().appendingPathExtension("json"))
        }
    }

    static func semANSI(_ s: String) -> String {
        s.replacingOccurrences(of: #"\u001B\[[0-9;?]*[A-Za-z]|\u001B\][^\u0007]*\u0007"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
    }

    /// Junta os trechos que explicam a falha: blocos do Gradle ("What went wrong"),
    /// erros do Kotlin/Java/JS e falhas de tarefa. Ignora repetições.
    static func resumoErro(_ log: String) -> String {
        let linhas = semANSI(log).components(separatedBy: "\n")
        var saida: [String] = []
        var vistos = Set<String>()
        func add(_ l: String) {
            let t = l.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !vistos.contains(t) else { return }
            vistos.insert(t); saida.append(l)
        }
        var i = 0
        while i < linhas.count {
            let l = linhas[i]
            if l.contains("* What went wrong:") {
                var j = i + 1
                while j < linhas.count, j < i + 14, !linhas[j].hasPrefix("* Try:") {
                    add(linhas[j]); j += 1
                }
                i = j; continue
            }
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("e: ") || t.hasPrefix("error:") || t.hasPrefix("ERROR") || t.hasPrefix("Error:")
                || t.contains("error TS") || t.contains("SyntaxError") || t.contains("Execution failed for task")
                || t.contains("FAILURE:") || t.contains(": error:") || t.hasPrefix("[!]") || t.contains("Unable to resolve module")
                || (t.lowercased().hasPrefix("error") && t.count > 6) {
                add(l)
            }
            i += 1
            if saida.count > 40 { break }
        }
        return saida.joined(separator: "\n")
    }
}

// MARK: - Aba Histórico

struct HistoricoView: View {
    @EnvironmentObject var app: AppState
    let projeto: String
    @State private var lista: [Execucao] = []
    @State private var selecionado: Execucao?
    @State private var soFalhas = false
    @StateObject private var console = ConsoleModel(nome: "historico")
    @State private var resumo = ""
    @State private var copiado = ""

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Picker("", selection: $soFalhas) {
                        Text("Todas").tag(false); Text("Só falhas").tag(true)
                    }
                    .pickerStyle(.segmented).frame(width: 180)
                    Spacer()
                    Button { carregar() } label: { Image(systemName: "arrow.clockwise") }.help("Atualizar")
                    Button { NSWorkspace.shared.open(Historico.pasta(projeto)) } label: { Image(systemName: "folder") }
                        .help("Abrir pasta dos logs")
                }
                .controlSize(.small).padding(8)
                Divider()
                let itens = lista.filter { !soFalhas || !$0.ok }
                if itens.isEmpty {
                    ContentUnavailableView(soFalhas ? "Nenhuma falha 🎉" : "Sem histórico ainda", systemImage: "clock.arrow.circlepath",
                                           description: Text("Cada build/execução que terminar fica guardada aqui com o log completo."))
                } else {
                    List(itens, selection: $selecionado) { e in
                        HStack(spacing: 10) {
                            Image(systemName: e.ok ? "checkmark.circle.fill" : e.interrompido ? "stop.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(e.ok ? .green : e.interrompido ? .secondary : .red)
                                .font(.system(size: 16))
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Text(rotulo(e.acao)).font(.system(size: 12.5, weight: .semibold))
                                    Text(e.origem).font(.system(size: 9, weight: .heavy))
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(Capsule().fill(.quaternary))
                                }
                                Text("\(e.branch) · \(e.duracao)\(e.ok ? "" : " · código \(e.codigo)")")
                                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(e.fim.formatted(.relative(presentation: .named))).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .tag(e)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 300, idealWidth: 360, maxHeight: .infinity, alignment: .top)

            VStack(spacing: 0) {
                if let e = selecionado {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(rotulo(e.acao)) — \(e.ok ? "sucesso" : e.interrompido ? "interrompido" : "falhou (código \(e.codigo))")")
                                .font(.headline)
                            Text("\(e.fim.formatted(date: .abbreviated, time: .standard)) · \(e.origem) · \(e.commit)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if !copiado.isEmpty { Text(copiado).font(.caption).foregroundStyle(.green) }
                        Button { copiar(console.bruto.isEmpty ? "" : Historico.semANSI(console.bruto), "Log copiado") } label: {
                            Label("Copiar log", systemImage: "doc.on.doc")
                        }
                        Button { NSWorkspace.shared.open(Historico.logURL(e)) } label: { Image(systemName: "arrow.up.forward.app") }
                            .help("Abrir no editor")
                        Button { NSWorkspace.shared.activateFileViewerSelecting([Historico.logURL(e)]) } label: { Image(systemName: "folder") }
                            .help("Mostrar no Finder")
                    }
                    .controlSize(.small)
                    .padding(10)
                    if !resumo.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label("Resumo do erro", systemImage: "exclamationmark.triangle.fill").font(.subheadline.bold())
                                    .foregroundStyle(.red)
                                Spacer()
                                Button("Copiar resumo") {
                                    copiar("Falha em \(rotulo(e.acao)) — \(e.projeto) (\(e.branch), \(e.commit))\n\n\(resumo)", "Resumo copiado")
                                }
                                .controlSize(.small)
                            }
                            ScrollView {
                                Text(resumo).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 170)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(.red.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.red.opacity(0.3)))
                        .padding(.horizontal, 10).padding(.bottom, 8)
                    }
                    ConsoleView(console: console)
                } else {
                    ContentUnavailableView("Escolha uma execução", systemImage: "doc.text.magnifyingglass")
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            carregar()
            selecionado = selecionado ?? lista.first { !$0.ok && !$0.interrompido } ?? lista.first
        }
        .onChange(of: selecionado) { _, e in abrir(e) }
        .onChange(of: app.versaoHistorico) { _, _ in carregar() }
    }

    private func carregar() { lista = Historico.listar(projeto) }

    private func abrir(_ e: Execucao?) {
        console.limpar()
        resumo = ""
        guard let e else { return }
        let texto = (try? String(contentsOf: Historico.logURL(e), encoding: .utf8)) ?? "(log não encontrado)"
        console.receber(texto)
        if ["crash", "anr", "erro-js"].contains(e.acao) {
            resumo = Historico.semANSI(texto).components(separatedBy: "\n").prefix(30).joined(separator: "\n")
        } else if !e.ok {
            resumo = Historico.resumoErro(texto)
        }
    }

    private func copiar(_ t: String, _ aviso: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
        copiado = aviso
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiado = "" }
    }

    private func rotulo(_ a: String) -> String {
        ["run": "Rodar app", "android": "Rodar app (celular do Mac)", "metro": "Metro", "start": "Metro (celular do Mac)",
         "debug": "APK Debug", "release": "APK Release", "install": "yarn install", "clean": "Gradle clean",
         "metro-limpo": "Metro (cache limpo)", "crash": "💥 Crash do app", "anr": "🧊 App travou (ANR)",
         "erro-js": "⚠️ Erro de JavaScript"][a] ?? a
    }
}
