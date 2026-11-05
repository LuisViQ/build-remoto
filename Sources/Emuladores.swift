import Foundation

// MARK: - Emuladores Android (Mac e PC) e simuladores iOS (Mac)
//
// Um emulador Android ligado vira um dispositivo adb normal ("emulator-5554") e passa a
// funcionar com todas as ferramentas. Os simuladores iOS só rodam no Mac (Xcode).

struct Emulador: Identifiable, Hashable {
    enum Plataforma: String { case android = "Android", ios = "iOS" }
    let nome: String
    let plataforma: Plataforma
    let origem: Origem
    let udid: String?          // iOS
    var ligado: Bool
    var versao: String = ""    // ex.: "iOS 27.0"
    var id: String { "\(origem.rawValue):\(plataforma.rawValue):\(udid ?? nome)" }
    var titulo: String { nome.replacingOccurrences(of: "_", with: " ") }
}

enum Emuladores {
    static var emulatorWin: String { "\(Config.sdkWin)/emulator/emulator.exe" }

    /// Lista tudo e marca quais estão ligados. Também devolve serial -> nome do AVD.
    static func listar(pcOnline: Bool, dispositivos: [Dispositivo]) async -> ([Emulador], [String: String]) {
        async let avdsMac = Shell.run("emulator", ["-list-avds"])
        async let sims = Shell.run("xcrun", ["simctl", "list", "devices", "available", "-j"])
        async let avdsPC: ShellResult = pcOnline
            ? Shell.noPC("[ -x \(emulatorWin) ] && \(emulatorWin) -list-avds 2>/dev/null | tr -d '\\r'")
            : ShellResult(code: 1, out: "")

        // Emuladores Android ligados: pergunta o nome do AVD a cada "emulator-XXXX"
        var nomes: [String: String] = [:]
        for d in dispositivos where d.serial.hasPrefix("emulator-") {
            let r = await Adb.run(d, ["emu", "avd", "name"])
            if let n = r.out.split(separator: "\n").first.map({ String($0).trimmingCharacters(in: .whitespaces) }), !n.isEmpty, n != "OK" {
                nomes[d.serial] = n
            }
        }
        let ligadosMac = Set(dispositivos.filter { $0.origem == .mac }.compactMap { nomes[$0.serial] })
        let ligadosPC = Set(dispositivos.filter { $0.origem == .pc }.compactMap { nomes[$0.serial] })

        var r: [Emulador] = []
        for n in await avdsMac.out.split(separator: "\n").map(String.init) where !n.isEmpty && !n.hasPrefix("INFO") {
            r.append(Emulador(nome: n, plataforma: .android, origem: .mac, udid: nil, ligado: ligadosMac.contains(n)))
        }
        for n in await avdsPC.out.split(separator: "\n").map(String.init) where !n.isEmpty && !n.hasPrefix("INFO") {
            r.append(Emulador(nome: n, plataforma: .android, origem: .pc, udid: nil, ligado: ligadosPC.contains(n)))
        }
        if let data = await sims.out.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let devs = json["devices"] as? [String: [[String: Any]]] {
            for (runtime, lista) in devs.sorted(by: { $0.key > $1.key }) {
                // "com.apple.CoreSimulator.SimRuntime.iOS-27-0" -> "iOS 27.0"
                let v = runtime.components(separatedBy: ".").last?.replacingOccurrences(of: "-", with: " ")
                    .replacingOccurrences(of: #"(\d+) (\d+)$"#, with: "$1.$2", options: .regularExpression) ?? ""
                guard v.hasPrefix("iOS") else { continue }
                for d in lista {
                    guard let nome = d["name"] as? String, let udid = d["udid"] as? String else { continue }
                    r.append(Emulador(nome: nome, plataforma: .ios, origem: .mac, udid: udid,
                                      ligado: (d["state"] as? String) == "Booted", versao: v))
                }
            }
        }
        return (r, nomes)
    }

    static func ligar(_ e: Emulador) async -> ShellResult {
        switch (e.plataforma, e.origem) {
        case (.ios, _):
            guard let u = e.udid else { return ShellResult(code: 1, out: "") }
            let r = await Shell.run("xcrun", ["simctl", "boot", u])
            _ = await Shell.run("open", ["-a", "Simulator"])
            return r
        case (.android, .mac):
            let p = Shell.processo("emulator", ["-avd", e.nome])
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return ShellResult(code: 1, out: error.localizedDescription) }
            return ShellResult(code: 0, out: "")
        case (.android, .pc):
            // Abre o emulador no Windows (aparece na tela do PC; o adb do Windows já o enxerga)
            return await Shell.noPC("cd /mnt/c && setsid nohup \(emulatorWin) -avd \(Adb.aspas(e.nome)) >/dev/null 2>&1 & sleep 1; echo ok")
        }
    }

    static func desligar(_ e: Emulador, serial: String?) async {
        switch e.plataforma {
        case .ios:
            if let u = e.udid { _ = await Shell.run("xcrun", ["simctl", "shutdown", u]) }
        case .android:
            guard let serial else { return }
            let d = Dispositivo(serial: serial, modelo: "", estado: "device", origem: e.origem)
            _ = await Adb.run(d, ["emu", "kill"])
        }
    }
}
