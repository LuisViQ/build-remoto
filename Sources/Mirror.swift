import AppKit
import AVFoundation
import CoreMedia
import SwiftUI

// MARK: - Sessão de espelhamento (cliente nativo do protocolo scrcpy 4.x)
//
// No celular roda o scrcpy-server (o mesmo do Homebrew). Ele abre dois sockets pelo
// "adb forward": vídeo (H.264) e controle (toques/teclas). O vídeo é decodificado pelo
// hardware via AVSampleBufferDisplayLayer, dentro do próprio app.

@MainActor
final class MirrorSession: ObservableObject {
    enum Estado: Equatable { case parado, conectando(String), rodando, erro(String) }

    @Published var estado: Estado = .parado
    @Published var tamanho = CGSize(width: 1080, height: 2340)   // resolução do vídeo
    @Published var nomeAparelho = ""
    @Published var telaApagada = false
    let camada = AVSampleBufferDisplayLayer()
    private(set) var dispositivo: Dispositivo?

    private var tunel: Process?
    private var servidor: Process?
    private var video: Socket?
    private var controle: Socket?
    private var porta: UInt16 = 0
    private var leitor: Thread?


    init() {
        camada.videoGravity = .resizeAspect
        camada.backgroundColor = NSColor.black.cgColor
    }

    var ativo: Bool {
        if case .parado = estado { return false }
        if case .erro = estado { return false }
        return true
    }

    // MARK: Iniciar / parar

    func iniciar(_ d: Dispositivo) {
        parar()
        dispositivo = d
        estado = .conectando("Preparando…")
        Task { await conectar(d) }
    }

    func parar() {
        video?.fechar(); controle?.fechar()
        video = nil; controle = nil
        servidor?.terminate(); servidor = nil
        if let d = dispositivo, porta != 0 {
            let p = porta
            Task { _ = await adb(d, ["forward", "--remove", "tcp:\(p)"]); self.tunel?.terminate(); self.tunel = nil }
        } else {
            tunel?.terminate(); tunel = nil
        }
        camada.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        estado = .parado
        telaApagada = false
    }

    /// adb do Mac (celular no Mac) ou adb do Mac apontado para o servidor do Windows pelo túnel (celular no PC)
    private func adb(_ d: Dispositivo, _ args: [String]) async -> ShellResult {
        let env = d.origem == .pc ? ["ADB_SERVER_SOCKET": "tcp:localhost:5038"] : [:]
        return await Shell.run("adb", ["-s", d.serial] + args, env: env)
    }

    private func versaoScrcpy() async -> String {
        let r = await Shell.run("scrcpy", ["--version"])
        return r.out.split(separator: " ").dropFirst().first.map(String.init) ?? "4.1"
    }

    private func conectar(_ d: Dispositivo) async {
        porta = UInt16.random(in: 27200...27299)
        let scid = String(format: "%08x", UInt32.random(in: 0..<0x7FFF_FFFF))

        if d.origem == .pc {
            estado = .conectando("Abrindo túnel com o PC…")
            _ = await Shell.noPC("\(Config.adbWin) start-server >/dev/null 2>&1")
            // Com o túnel caído, o adb do Mac sobe sozinho um servidor vazio na 5038 e toma o lugar do túnel
            _ = await Shell.run("/bin/sh", ["-c", "lsof -nP -iTCP:5038 -sTCP:LISTEN -Fpc | awk '/^p/{p=substr($0,2)} /^cadb/{print p}' | xargs -r kill"])
            try? await Task.sleep(for: .milliseconds(200))
            // Se outro espelhamento já abriu o túnel do adb (5038), só encaminha a porta do vídeo
            var encaminhar = ["-L", "\(porta):localhost:\(porta)"]
            if Socket(porta: 5038).map({ $0.fechar(); return false }) ?? true {
                encaminhar += ["-L", "5038:localhost:5037"]
            }
            let t = Shell.processo("ssh", ["-nN", "-o", "ControlMaster=no", "-o", "ControlPath=none",
                                           "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15"]
                                   + encaminhar + [Config.pcHost])
            t.standardOutput = FileHandle.nullDevice; t.standardError = FileHandle.nullDevice
            t.standardInput = FileHandle.nullDevice
            try? t.run()
            tunel = t
            try? await Task.sleep(for: .milliseconds(1500))
            guard t.isRunning else { estado = .erro("Não consegui abrir o túnel com o PC (porta 5038 em uso?)"); return }
        }

        guard let jar = Config.scrcpyServer else {
            estado = .erro("O scrcpy não está instalado.\nInstale com: brew install scrcpy")
            return
        }
        estado = .conectando("Enviando servidor ao celular…")
        let versao = await versaoScrcpy()
        let push = await adb(d, ["push", jar, "/data/local/tmp/scrcpy-server.jar"])
        guard push.ok else { estado = .erro("Falha no adb push:\n\(push.out)"); return }
        let fwd = await adb(d, ["forward", "tcp:\(porta)", "localabstract:scrcpy_\(scid)"])
        guard fwd.ok else { estado = .erro("Falha no adb forward:\n\(fwd.out)"); return }

        estado = .conectando("Iniciando vídeo…")
        let args = ["shell", "CLASSPATH=/data/local/tmp/scrcpy-server.jar", "app_process", "/",
                    "com.genymobile.scrcpy.Server", versao, "scid=\(scid)", "log_level=info",
                    "tunnel_forward=true", "audio=false", "control=true", "video_codec=h264",
                    "max_size=1800", "video_bit_rate=8000000", "max_fps=60", "stay_awake=true",
                    "clipboard_autosync=false", "power_off_on_close=false"]
        let env = d.origem == .pc ? ["ADB_SERVER_SOCKET": "tcp:localhost:5038"] : [:]
        let s = Shell.processo("adb", ["-s", d.serial] + args, env: env)
        let logServidor = Pipe()
        s.standardOutput = logServidor; s.standardError = logServidor
        s.standardInput = FileHandle.nullDevice
        do { try s.run() } catch { estado = .erro("Falha ao iniciar o servidor: \(error)"); return }
        servidor = s

        // Conecta o socket de vídeo: o servidor manda 1 byte assim que aceita a conexão
        let porta = self.porta
        let conectado: (Socket, Socket)? = await Task.detached {
            for _ in 0..<60 {
                if let v = Socket(porta: porta), v.lerExato(1) != nil {
                    if let c = Socket(porta: porta) { return (v, c) }
                    v.fechar()
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
            return nil
        }.value
        guard let (v, c) = conectado else {
            let saida = String(decoding: logServidor.fileHandleForReading.availableData, as: UTF8.self)
            estado = .erro("O celular não respondeu.\n\(saida)")
            servidor?.terminate()
            return
        }
        video = v
        controle = c
        estado = .rodando
        iniciarLeitura(v)
    }

    // MARK: Leitura do vídeo

    private func iniciarLeitura(_ v: Socket) {
        let camada = self.camada
        let t = Thread { [weak self] in
            var decoder = H264Montador()
            guard let nome = v.lerExato(64), v.lerExato(4) != nil else {   // nome do aparelho + codec id
                DispatchQueue.main.async { self?.falhou("Conexão de vídeo encerrada") }
                return
            }
            let n = String(decoding: nome.prefix { $0 != 0 }, as: UTF8.self)
            DispatchQueue.main.async { self?.nomeAparelho = n }
            while true {
                guard let h = v.lerExato(12) else { break }
                let b = [UInt8](h)
                if b[0] & 0x80 != 0 {
                    // Pacote de sessão (nova captura, ex.: rotação): largura/altura
                    let w = Int(b[4]) << 24 | Int(b[5]) << 16 | Int(b[6]) << 8 | Int(b[7])
                    let a = Int(b[8]) << 24 | Int(b[9]) << 16 | Int(b[10]) << 8 | Int(b[11])
                    DispatchQueue.main.async { self?.tamanho = CGSize(width: w, height: a) }
                    continue
                }
                let config = b[0] & 0x40 != 0
                let tam = Int(b[8]) << 24 | Int(b[9]) << 16 | Int(b[10]) << 8 | Int(b[11])
                guard let dados = v.lerExato(tam) else { break }
                if config {
                    decoder.configurar(dados)
                } else if let sb = decoder.amostra(dados) {
                    let r = camada.sampleBufferRenderer
                    if r.status == .failed { r.flush() }
                    r.enqueue(sb)
                }
            }
            DispatchQueue.main.async { self?.falhou("Conexão de vídeo encerrada") }
        }
        t.qualityOfService = .userInteractive
        t.start()
        leitor = t
    }

    private func falhou(_ msg: String) {
        guard estado == .rodando else { return }
        estado = .erro(msg)
        servidor?.terminate()
        tunel?.terminate()
    }

    // MARK: Controle (toque, teclas, texto)

    private func enviar(_ m: Data) {
        guard let c = controle else { return }
        DispatchQueue.global(qos: .userInteractive).async { c.escrever(m) }
    }

    enum AcaoToque: UInt8 { case down = 0, up = 1, move = 2 }

    func toque(_ acao: AcaoToque, _ p: CGPoint) {
        var m = Data([2, acao.rawValue])
        m.be(UInt64(bitPattern: -2))                      // POINTER_ID_GENERIC_FINGER
        posicao(&m, p)
        m.be(UInt16(acao == .up ? 0 : 0xFFFF))            // pressão
        m.be(UInt32(0)); m.be(UInt32(0))                 // actionButton, buttons
        enviar(m)
    }

    func rolar(_ p: CGPoint, dx: CGFloat, dy: CGFloat) {
        var m = Data([3])
        posicao(&m, p)
        let fp = { (v: CGFloat) -> UInt16 in
            UInt16(bitPattern: Int16(max(-32768, min(32767, (v / 16) * 32768))))
        }
        m.be(fp(dx)); m.be(fp(dy))
        m.be(UInt32(0))
        enviar(m)
    }

    func tecla(_ keycode: Int32) {
        for acao: UInt8 in [0, 1] {
            var m = Data([0, acao])
            m.be(UInt32(bitPattern: keycode)); m.be(UInt32(0)); m.be(UInt32(0))
            enviar(m)
        }
    }

    func texto(_ s: String) {
        let d = Data(s.utf8)
        var m = Data([1])
        m.be(UInt32(d.count)); m.append(d)
        enviar(m)
    }

    /// Cola no celular o que está na área de transferência do Mac
    func colar(_ s: String) {
        let d = Data(s.utf8)
        var m = Data([9])
        m.be(UInt64(0)); m.append(1)
        m.be(UInt32(d.count)); m.append(d)
        enviar(m)
    }

    func girar() { enviar(Data([11])) }
    func painelNotificacoes() { enviar(Data([5])) }
    func painelConfiguracoes() { enviar(Data([6])) }

    func alternarTela() {
        telaApagada.toggle()
        enviar(Data([10, telaApagada ? 0 : 1]))
    }

    private func posicao(_ m: inout Data, _ p: CGPoint) {
        m.be(UInt32(bitPattern: Int32(p.x))); m.be(UInt32(bitPattern: Int32(p.y)))
        m.be(UInt16(tamanho.width)); m.be(UInt16(tamanho.height))
    }

    /// Captura a tela em resolução cheia e salva na Mesa + área de transferência
    func capturarTela() async -> URL? {
        guard let d = dispositivo else { return nil }
        let args = await Adb.argsPrint(d)
        let r: Data?
        if d.origem == .mac {
            r = await Shell.runData("adb", ["-s", d.serial] + args)
        } else {
            r = await Shell.runData("adb", ["-s", d.serial] + args, env: ["ADB_SERVER_SOCKET": "tcp:localhost:5038"])
        }
        guard let png = Adb.soPNG(r), png.count > 1000 else { return nil }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd 'às' HH.mm.ss"
        let url = URL(fileURLWithPath: "\(Config.home)/Desktop/Celular \(fmt.string(from: Date())).png")
        try? png.write(to: url)
        await MainActor.run { copiarImagem(png, arquivo: url) }
        return url
    }
}

// MARK: - Montagem das amostras H.264 (Annex B -> AVCC)

struct H264Montador {
    private var formato: CMVideoFormatDescription?

    /// NALs separados pelos start codes 00 00 01 / 00 00 00 01
    static func nals(_ d: Data) -> [Data] {
        let b = [UInt8](d)
        var inicios: [(Int, Int)] = []   // (posição do start code, tamanho do start code)
        var i = 0
        while i + 3 <= b.count {
            if b[i] == 0, b[i + 1] == 0 {
                if b[i + 2] == 1 { inicios.append((i, 3)); i += 3; continue }
                if i + 4 <= b.count, b[i + 2] == 0, b[i + 3] == 1 { inicios.append((i, 4)); i += 4; continue }
            }
            i += 1
        }
        return inicios.enumerated().map { k, s in
            let ini = s.0 + s.1
            let fim = k + 1 < inicios.count ? inicios[k + 1].0 : b.count
            return Data(b[ini..<fim])
        }
    }

    mutating func configurar(_ d: Data) {
        let ns = Self.nals(d)
        guard let sps = ns.first(where: { ($0.first ?? 0) & 0x1F == 7 }),
              let pps = ns.first(where: { ($0.first ?? 0) & 0x1F == 8 }) else { return }
        var fd: CMVideoFormatDescription?
        sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let ptrs = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let tams = [sps.count, pps.count]
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: ptrs,
                    parameterSetSizes: tams, nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
            }
        }
        formato = fd
    }

    func amostra(_ d: Data) -> CMSampleBuffer? {
        guard let formato else { return nil }
        var avcc = Data()
        for n in Self.nals(d) where !n.isEmpty {
            let t = n.first! & 0x1F
            if t == 7 || t == 8 { continue }
            var tam = UInt32(n.count).bigEndian
            avcc.append(Data(bytes: &tam, count: 4))
            avcc.append(n)
        }
        guard !avcc.isEmpty else { return nil }
        var bloco: CMBlockBuffer?
        let len = avcc.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: len,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: len, flags: 0, blockBufferOut: &bloco) == noErr,
              let bloco else { return nil }
        avcc.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bloco,
                                                                 offsetIntoDestination: 0, dataLength: len) }
        var sb: CMSampleBuffer?
        var tamAmostra = len
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: bloco, formatDescription: formato,
                                  sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                  sampleSizeEntryCount: 1, sampleSizeArray: &tamAmostra, sampleBufferOut: &sb)
        if let sb, let anexos = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) {
            let dic = unsafeBitCast(CFArrayGetValueAtIndex(anexos, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dic, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }
}

// MARK: - Socket TCP simples (bloqueante) para localhost

final class Socket: @unchecked Sendable {
    private var fd: Int32

    init?(porta: UInt16) {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var um: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &um, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &um, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = porta.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if r != 0 { Darwin.close(fd); return nil }
    }

    func lerExato(_ n: Int) -> Data? {
        guard n > 0 else { return Data() }
        var d = Data(count: n)
        var lidos = 0
        let ok = d.withUnsafeMutableBytes { buf -> Bool in
            while lidos < n {
                let r = Darwin.recv(fd, buf.baseAddress! + lidos, n - lidos, 0)
                if r <= 0 { return false }
                lidos += r
            }
            return true
        }
        return ok ? d : nil
    }

    func escrever(_ d: Data) {
        d.withUnsafeBytes { b in
            var enviados = 0
            while enviados < d.count {
                let r = Darwin.send(fd, b.baseAddress! + enviados, d.count - enviados, 0)
                if r <= 0 { return }
                enviados += r
            }
        }
    }

    func fechar() {
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd); fd = -1 }
    }
}

extension Data {
    mutating func be<T: FixedWidthInteger>(_ v: T) {
        var x = v.bigEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
}

// MARK: - View do espelhamento (recebe mouse, rolagem e teclado)

final class MirrorNSView: NSView {
    weak var sessao: MirrorSession?
    private var arrastando = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func instalar(_ s: MirrorSession) {
        sessao = s
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        s.camada.frame = bounds
        layer?.addSublayer(s.camada)
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        sessao?.camada.frame = bounds
        CATransaction.commit()
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Converte o ponto da view para coordenadas do vídeo no celular
    private func noCelular(_ e: NSEvent) -> CGPoint? {
        guard let s = sessao else { return nil }
        let p = convert(e.locationInWindow, from: nil)
        let r = AVMakeRect(aspectRatio: s.tamanho, insideRect: bounds)
        guard r.width > 0 else { return nil }
        let x = (p.x - r.minX) / r.width * s.tamanho.width
        let y = (r.maxY - p.y) / r.height * s.tamanho.height
        return CGPoint(x: max(0, min(s.tamanho.width - 1, x)), y: max(0, min(s.tamanho.height - 1, y)))
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        guard let p = noCelular(e) else { return }
        arrastando = true
        sessao?.toque(.down, p)
    }

    override func mouseDragged(with e: NSEvent) {
        guard arrastando, let p = noCelular(e) else { return }
        sessao?.toque(.move, p)
    }

    override func mouseUp(with e: NSEvent) {
        guard arrastando, let p = noCelular(e) else { return }
        arrastando = false
        sessao?.toque(.up, p)
    }

    override func rightMouseDown(with e: NSEvent) { sessao?.tecla(4) }     // botão direito = voltar

    override func scrollWheel(with e: NSEvent) {
        guard let p = noCelular(e) else { return }
        let f: CGFloat = e.hasPreciseScrollingDeltas ? 0.05 : 1
        sessao?.rolar(p, dx: -e.scrollingDeltaX * f, dy: e.scrollingDeltaY * f)
    }

    override func keyDown(with e: NSEvent) {
        guard let s = sessao else { return }
        if e.modifierFlags.contains(.command) {
            if e.charactersIgnoringModifiers == "v", let t = NSPasteboard.general.string(forType: .string) { s.colar(t) }
            return
        }
        let mapa: [UInt16: Int32] = [36: 66, 76: 66, 51: 67, 117: 112, 123: 21, 124: 22, 126: 19, 125: 20,
                                     53: 4, 48: 61, 115: 3]
        if let k = mapa[e.keyCode] { s.tecla(k); return }
        if let t = e.characters, !t.isEmpty, t.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) {
            s.texto(t)
        }
    }
}

struct MirrorRepresentable: NSViewRepresentable {
    let sessao: MirrorSession
    func makeNSView(context: Context) -> MirrorNSView {
        let v = MirrorNSView()
        v.instalar(sessao)
        return v
    }
    func updateNSView(_ v: MirrorNSView, context: Context) {
        if v.sessao !== sessao { v.instalar(sessao) }
    }
}

extension Shell {
    static func runData(_ exe: String, _ args: [String], env: [String: String] = [:]) async -> Data? {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = processo(exe, args, env: env)
                let saida = Pipe()
                p.standardOutput = saida
                p.standardError = FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                guard (try? p.run()) != nil else { cont.resume(returning: nil); return }
                let d = saida.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: p.terminationStatus == 0 ? d : nil)
            }
        }
    }
}
