import AppKit
import Foundation

/// Executa comandos adb no celular escolhido, esteja ele ligado no Mac (adb local)
/// ou no PC (adb do WSL falando com o adb server do Windows).
enum Adb {
    static func aspas(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func run(_ d: Dispositivo, _ args: [String]) async -> ShellResult {
        let r: ShellResult
        if d.origem == .mac {
            r = await Shell.run("adb", ["-s", d.serial] + args)
        } else {
            let cmd = Config.adbPC + " " + (["-s", d.serial] + args).map(aspas).joined(separator: " ")
            r = await Shell.noPC(cmd)
        }
        // O adb pode devolver \r\n; no Swift "\r\n" é um caractere só e quebraria os split("\n")
        return ShellResult(code: r.code, out: r.out.replacingOccurrences(of: "\r\n", with: "\n"))
    }

    static func shell(_ d: Dispositivo, _ comando: String) async -> ShellResult {
        await run(d, ["shell", comando])
    }

    /// Argumentos do print da tela que está LIGADA (aparelhos dobráveis têm duas telas físicas)
    static func argsPrint(_ d: Dispositivo) async -> [String] {
        var id: String?
        for l in (await shell(d, "dumpsys display")).out.split(separator: "\n") {
            if let r = l.range(of: #"uniqueId="local:(\d+)""#, options: .regularExpression) {
                id = String(l[r]).components(separatedBy: ":").last?.replacingOccurrences(of: "\"", with: "")
            } else if let atual = id, l.contains("mState=") {
                if l.contains("mState=ON") { return ["exec-out", "screencap", "-p", "-d", atual] }
                id = nil
            }
        }
        return ["exec-out", "screencap", "-p"]
    }

    /// Remove o que vier antes da imagem: em aparelhos com duas telas (ex.: Galaxy Z Fold) o screencap
    /// escreve um aviso em texto ("Multiple displays were found…") no começo da saída
    static func soPNG(_ d: Data?) -> Data? {
        guard let d else { return nil }
        let assinatura = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        guard let r = d.range(of: assinatura) else { return nil }
        return d.subdata(in: r.lowerBound..<d.endIndex)
    }

    /// Saída binária (arquivos do celular: print, vídeo, banco de dados)
    static func dados(_ d: Dispositivo, _ args: [String]) async -> Data? {
        if d.origem == .mac {
            return await Shell.runData("adb", ["-s", d.serial] + args)
        }
        let cmd = Config.adbPC + " " + (["-s", d.serial] + args).map(aspas).joined(separator: " ")
        return await Shell.runData("ssh", Config.sshCliente + [Config.pcHost, cmd + " </dev/null"])
    }

    /// Processo de longa duração (ex.: logcat) com a saída chegando aos poucos
    static func stream(_ d: Dispositivo, _ args: [String], onTexto: @escaping (String) -> Void,
                       onFim: @escaping (Int32) -> Void) -> Process? {
        if d.origem == .mac {
            return Shell.stream("adb", ["-s", d.serial] + args, onTexto: onTexto, onFim: onFim)
        }
        let cmd = Config.adbPC + " " + (["-s", d.serial] + args).map(aspas).joined(separator: " ")
        return Shell.stream("ssh", Config.sshCliente + [Config.pcHost, cmd + " </dev/null"],
                            onTexto: onTexto, onFim: onFim)
    }

    /// Pacote instalado do projeto: lê o applicationId do build.gradle e confere no celular
    /// qual variante existe (ex.: com.app e com.app.debug).
    static func pacote(_ projeto: String, em d: Dispositivo) async -> String? {
        let gradle = (try? String(contentsOfFile: "\(Config.pasta(projeto))/android/app/build.gradle", encoding: .utf8)) ?? ""
        guard let r = gradle.range(of: #"applicationId\s*=?\s*["']([^"']+)["']"#, options: .regularExpression) else { return nil }
        let base = String(gradle[r]).components(separatedBy: CharacterSet(charactersIn: "\"'"))[1]
        let lista = await shell(d, "pm list packages \(base)").out
            .split(separator: "\n").map { $0.replacingOccurrences(of: "package:", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { $0 == base || $0.hasPrefix(base + ".") }
        return lista.first { $0.hasSuffix(".debug") } ?? lista.first ?? base
    }
}

/// Coloca a imagem na área de transferência em PNG (navegadores, Teams, Azure, WhatsApp),
/// TIFF (apps nativos) e, se houver, como arquivo (Finder, anexos)
@MainActor
func copiarImagem(_ png: Data, arquivo: URL? = nil) {
    let pb = NSPasteboard.general
    pb.clearContents()
    let item = NSPasteboardItem()
    item.setData(png, forType: .png)
    if let tiff = NSImage(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
    if let arquivo { item.setString(arquivo.absoluteString, forType: .fileURL) }
    pb.writeObjects([item])
}
