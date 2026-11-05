import SwiftUI

// MARK: - O que está ocupando espaço no Mac
//
// Mede as pastas que mais crescem em quem desenvolve app (Xcode, Gradle, simuladores,
// caches de yarn/npm/CocoaPods, node_modules…) e oferece limpeza segura onde dá.

struct ItemEspaco: Identifiable {
    enum Risco { case seguro, recriavel, manual }
    let id = UUID()
    let nome: String
    let caminho: String
    let explicacao: String
    let risco: Risco
    /// Comando de limpeza (zsh). nil = só mostrar no Finder
    let limpar: String?
    var bytes: Int64? = nil
    var medindo = false

    var tamanho: String { bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—" }
}

@MainActor
final class Armazenamento: ObservableObject {
    @Published var itens: [ItemEspaco] = []
    @Published var maiores: [(String, Int64)] = []
    @Published var analisandoHome = false
    @Published var livre: Int64 = 0
    @Published var total: Int64 = 0
    @Published var limpando: UUID?

    static func catalogo() -> [ItemEspaco] {
        let h = Config.home
        var l: [ItemEspaco] = [
            ItemEspaco(nome: "Xcode — DerivedData", caminho: "\(h)/Library/Developer/Xcode/DerivedData",
                       explicacao: "Builds intermediários do Xcode. O Xcode recria quando precisar.", risco: .seguro,
                       limpar: "rm -rf ~/Library/Developer/Xcode/DerivedData/*"),
            ItemEspaco(nome: "Xcode — suporte a iPhones", caminho: "\(h)/Library/Developer/Xcode/iOS DeviceSupport",
                       explicacao: "Símbolos de cada versão de iOS já conectada. Recriado ao conectar o iPhone.", risco: .seguro,
                       limpar: "rm -rf ~/Library/Developer/Xcode/'iOS DeviceSupport'/*"),
            ItemEspaco(nome: "Xcode — Archives", caminho: "\(h)/Library/Developer/Xcode/Archives",
                       explicacao: "Builds de publicação antigos (.xcarchive). Apague só os que não precisa mais.", risco: .manual, limpar: nil),
            ItemEspaco(nome: "Simuladores iOS", caminho: "\(h)/Library/Developer/CoreSimulator/Devices",
                       explicacao: "Dados dos simuladores. A limpeza remove só simuladores de iOS que não existem mais.", risco: .seguro,
                       limpar: "xcrun simctl delete unavailable"),
            ItemEspaco(nome: "Simuladores — caches", caminho: "\(h)/Library/Developer/CoreSimulator/Caches",
                       explicacao: "Caches dos simuladores. Recriados automaticamente.", risco: .seguro,
                       limpar: "rm -rf ~/Library/Developer/CoreSimulator/Caches/*"),
            ItemEspaco(nome: "Gradle — caches", caminho: "\(h)/.gradle/caches",
                       explicacao: "Dependências e builds do Android. O próximo build baixa de novo (fica mais lento uma vez).", risco: .recriavel,
                       limpar: "pkill -f GradleDaemon; rm -rf ~/.gradle/caches"),
            ItemEspaco(nome: "Gradle — versões baixadas", caminho: "\(h)/.gradle/wrapper/dists",
                       explicacao: "Cada versão do Gradle usada pelos projetos. Baixadas de novo quando preciso.", risco: .recriavel,
                       limpar: "rm -rf ~/.gradle/wrapper/dists"),
            ItemEspaco(nome: "Emuladores Android (AVDs)", caminho: "\(h)/.android/avd",
                       explicacao: "Discos dos emuladores. Remova pelo Android Studio (Device Manager) os que não usa.", risco: .manual, limpar: nil),
            ItemEspaco(nome: "Android SDK", caminho: "\(h)/Library/Android/sdk",
                       explicacao: "SDKs, imagens de sistema e NDKs. Remova versões antigas pelo SDK Manager do Android Studio.", risco: .manual, limpar: nil),
            ItemEspaco(nome: "Cache do Yarn", caminho: "\(h)/Library/Caches/Yarn",
                       explicacao: "Pacotes já baixados. O yarn baixa de novo quando precisar.", risco: .seguro, limpar: "yarn cache clean"),
            ItemEspaco(nome: "Cache do npm", caminho: "\(h)/.npm",
                       explicacao: "Pacotes já baixados pelo npm/npx.", risco: .seguro, limpar: "npm cache clean --force"),
            ItemEspaco(nome: "Cache do CocoaPods", caminho: "\(h)/Library/Caches/CocoaPods",
                       explicacao: "Pods já baixados (iOS).", risco: .seguro, limpar: "rm -rf ~/Library/Caches/CocoaPods"),
            ItemEspaco(nome: "Cache do Homebrew", caminho: "\(h)/Library/Caches/Homebrew",
                       explicacao: "Instaladores antigos do Homebrew.", risco: .seguro, limpar: "brew cleanup -s; rm -rf ~/Library/Caches/Homebrew/*"),
            ItemEspaco(nome: "Metro — temporários", caminho: NSTemporaryDirectory(),
                       explicacao: "Caches do Metro (metro-*, haste-map-*) na pasta temporária.", risco: .seguro,
                       limpar: "rm -rf \"$TMPDIR\"/metro-* \"$TMPDIR\"/haste-map-* \"$TMPDIR\"/react-*"),
            ItemEspaco(nome: "Lixeira", caminho: "\(h)/.Trash",
                       explicacao: "Arquivos já apagados que ainda ocupam espaço.", risco: .recriavel, limpar: "rm -rf ~/.Trash/* ~/.Trash/.[!.]*"),
            ItemEspaco(nome: "Downloads", caminho: "\(h)/Downloads",
                       explicacao: "Instaladores e arquivos baixados. Revise e apague o que não precisa.", risco: .manual, limpar: nil),
            ItemEspaco(nome: "APKs guardados (Build Remoto)", caminho: Config.apkDir,
                       explicacao: "Histórico de APKs gerados. Apague os antigos pela aba APKs.", risco: .manual, limpar: nil),
        ]
        for p in Config.projetos {
            l.append(ItemEspaco(nome: "node_modules — \(p)", caminho: "\(Config.pasta(p))/node_modules",
                                explicacao: "Dependências do app. Reinstaladas no próximo Rodar (yarn install).", risco: .recriavel,
                                limpar: "rm -rf \(Adb.aspas("\(Config.pasta(p))/node_modules"))"))
            l.append(ItemEspaco(nome: "Build Android — \(p)", caminho: "\(Config.pasta(p))/android/app/build",
                                explicacao: "Saída do Gradle deste app. Recriada no próximo build.", risco: .recriavel,
                                limpar: "rm -rf \(Adb.aspas("\(Config.pasta(p))/android/app/build")) \(Adb.aspas("\(Config.pasta(p))/android/build"))"))
        }
        return l
    }

    func medir() {
        if let v = try? URL(fileURLWithPath: Config.home).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            livre = v.volumeAvailableCapacityForImportantUsage ?? 0
            total = Int64(v.volumeTotalCapacity ?? 0)
        }
        itens = Self.catalogo().filter { FileManager.default.fileExists(atPath: $0.caminho) }
        for i in itens.indices { itens[i].medindo = true }
        for item in itens { Task { await medirItem(item.id) } }
    }

    private func medirItem(_ id: UUID) async {
        guard let item = itens.first(where: { $0.id == id }) else { return }
        let bytes: Int64
        if item.nome.hasPrefix("Metro") {
            let r = await Shell.run("zsh", ["-c", "du -skc \"$TMPDIR\"/metro-* \"$TMPDIR\"/haste-map-* \"$TMPDIR\"/react-* 2>/dev/null | tail -1"])
            bytes = (Int64(r.out.split(separator: "\t").first ?? "0") ?? 0) * 1024
        } else {
            let r = await Shell.run("du", ["-sk", item.caminho])
            bytes = (Int64(r.out.split(separator: "\t").first.map(String.init) ?? "0") ?? 0) * 1024
        }
        guard let i = itens.firstIndex(where: { $0.id == id }) else { return }
        itens[i].bytes = bytes
        itens[i].medindo = false
        if !itens.contains(where: \.medindo) { itens.sort { ($0.bytes ?? 0) > ($1.bytes ?? 0) } }
    }

    func limpar(_ item: ItemEspaco) async {
        guard let cmd = item.limpar else { return }
        limpando = item.id
        _ = await Shell.run("zsh", ["-lc", cmd])
        limpando = nil
        if let i = itens.firstIndex(where: { $0.id == item.id }) { itens[i].medindo = true }
        await medirItem(item.id)
        if let v = try? URL(fileURLWithPath: Config.home).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) {
            livre = v.volumeAvailableCapacityForImportantUsage ?? livre
        }
    }

    /// Maiores pastas da pasta pessoal e da Library (pode levar alguns minutos)
    func analisarHome() async {
        analisandoHome = true
        maiores = []
        let r = await Shell.run("zsh", ["-c", "du -sk ~/*(N/) ~/.[!.]*(N/) ~/Library/*(N/) ~/Library/Application\\ Support/*(N/) ~/Library/Containers/*(N/) 2>/dev/null"])
        var l: [(String, Int64)] = []
        for linha in r.out.split(separator: "\n") {
            let p = linha.split(separator: "\t", maxSplits: 1)
            guard p.count == 2, let kb = Int64(p[0]) else { continue }
            let caminho = String(p[1])
            if ["\(Config.home)/Library", "\(Config.home)/Library/Application Support", "\(Config.home)/Library/Containers"].contains(caminho) { continue }
            l.append((caminho, kb * 1024))
        }
        maiores = Array(l.sorted { $0.1 > $1.1 }.prefix(25))
        analisandoHome = false
    }
}

struct ArmazenamentoView: View {
    @StateObject private var a = Armazenamento()
    @State private var confirmar: ItemEspaco?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Disco
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Disco do Mac", systemImage: "internaldrive").font(.headline)
                        Spacer()
                        Text("\(ByteCountFormatter.string(fromByteCount: a.livre, countStyle: .file)) livres de \(ByteCountFormatter.string(fromByteCount: a.total, countStyle: .file))")
                            .foregroundStyle(.secondary)
                    }
                    let usado = a.total > 0 ? 1 - Double(a.livre) / Double(a.total) : 0
                    Medidor(titulo: "", valor: usado, texto: "\(Int(usado * 100))% usado")
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.45)))

                HStack {
                    Text("Coisas de desenvolvimento").font(.headline)
                    Spacer()
                    let somaSeguro = a.itens.filter { $0.risco == .seguro }.compactMap(\.bytes).reduce(0, +)
                    if somaSeguro > 0 {
                        Text("\(ByteCountFormatter.string(fromByteCount: somaSeguro, countStyle: .file)) podem ser liberados sem risco")
                            .font(.caption).foregroundStyle(.green)
                    }
                    Button { a.medir() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                }
                ForEach(a.itens) { item in
                    HStack(spacing: 12) {
                        Image(systemName: icone(item.risco)).foregroundStyle(cor(item.risco)).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.nome).font(.system(size: 12.5, weight: .semibold))
                            Text(item.explicacao).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if item.medindo { ProgressView().controlSize(.small) }
                        else {
                            Text(item.tamanho).font(.system(size: 13, weight: .bold).monospacedDigit())
                                .foregroundStyle((item.bytes ?? 0) > 5_000_000_000 ? .orange : .primary)
                        }
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: item.caminho)) } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless).help("Abrir no Finder")
                        if item.limpar != nil {
                            if a.limpando == item.id { ProgressView().controlSize(.small).frame(width: 60) }
                            else {
                                Button("Limpar") { confirmar = item }.controlSize(.small)
                                    .disabled(item.medindo || (item.bytes ?? 0) < 1_000_000)
                            }
                        } else {
                            Text("manual").font(.caption2).foregroundStyle(.tertiary).frame(width: 60)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.3)))
                }
                HStack(spacing: 16) {
                    Label("seguro", systemImage: icone(.seguro)).foregroundStyle(cor(.seguro))
                    Label("recriado depois (próximo build fica mais lento)", systemImage: icone(.recriavel)).foregroundStyle(cor(.recriavel))
                    Label("revisar à mão", systemImage: icone(.manual)).foregroundStyle(cor(.manual))
                }
                .font(.caption)

                Divider().padding(.vertical, 4)
                HStack {
                    Text("Maiores pastas da sua pasta pessoal").font(.headline)
                    Spacer()
                    Button {
                        Task { await a.analisarHome() }
                    } label: {
                        if a.analisandoHome { HStack { ProgressView().controlSize(.small); Text("Analisando… (pode levar 1–3 min)") } }
                        else { Label(a.maiores.isEmpty ? "Analisar" : "Analisar de novo", systemImage: "chart.bar.xaxis") }
                    }
                    .disabled(a.analisandoHome)
                }
                if let maior = a.maiores.first?.1 {
                    ForEach(a.maiores, id: \.0) { caminho, bytes in
                        HStack(spacing: 10) {
                            Text(caminho.replacingOccurrences(of: Config.home, with: "~")).font(.system(size: 11.5, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle).frame(width: 330, alignment: .leading)
                            GeometryReader { g in
                                Capsule().fill(LinearGradient(colors: [.teal, .blue], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(3, g.size.width * Double(bytes) / Double(maior)))
                            }
                            .frame(height: 8)
                            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.system(size: 11.5).monospacedDigit())
                                .frame(width: 70, alignment: .trailing)
                            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: caminho)]) } label: { Image(systemName: "folder") }
                                .buttonStyle(.borderless)
                        }
                    }
                } else if !a.analisandoHome {
                    Text("Mostra as pastas mais pesadas de ~ e de ~/Library (inclui apps e dados que não são de desenvolvimento).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(18)
        }
        .onAppear { if a.itens.isEmpty { a.medir() } }
        .confirmationDialog("Limpar \(confirmar?.nome ?? "")?", isPresented: Binding(get: { confirmar != nil }, set: { if !$0 { confirmar = nil } })) {
            Button("Limpar \(confirmar?.tamanho ?? "")", role: .destructive) {
                if let c = confirmar { Task { await a.limpar(c) } }
            }
        } message: {
            Text("\(confirmar?.explicacao ?? "")\n\nComando: \(confirmar?.limpar ?? "")")
        }
    }

    private func icone(_ r: ItemEspaco.Risco) -> String {
        switch r { case .seguro: "checkmark.shield.fill"; case .recriavel: "arrow.triangle.2.circlepath"; case .manual: "hand.raised.fill" }
    }
    private func cor(_ r: ItemEspaco.Risco) -> Color {
        switch r { case .seguro: .green; case .recriavel: .orange; case .manual: .secondary }
    }
}
