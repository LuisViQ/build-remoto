import SwiftUI

// MARK: - Login AWS SSO (o git usa CodeCommit via git-remote-codecommit)

@MainActor
final class AwsSSO: ObservableObject {
    enum Estado: Equatable { case desconhecido, verificando, ok(Date?), expirado, semAws, naoConfigurado, entrando }

    static let compartilhado = AwsSSO()

    @Published var estado: Estado = .desconhecido
    @Published var codigo: String?       // código mostrado no navegador
    @Published var url: String?
    @Published var erro: String?
    /// O que falta para o login funcionar (id do requisito, nome)
    @Published var faltando: [(id: String, nome: String)] = []
    private var proc: Process?
    var bloqueado: Bool { !faltando.isEmpty }

    /// Os apps usam CodeCommit? (remote "codecommit::…")
    static func usaCodeCommit() -> Bool {
        Config.projetos.contains { p in
            let cfg = (try? String(contentsOfFile: "\(Config.pasta(p))/.git/config", encoding: .utf8)) ?? ""
            return cfg.contains("codecommit::") || cfg.contains("git-codecommit.")
        }
    }

    var texto: String {
        switch estado {
        case .desconhecido: "AWS: não verificado"
        case .verificando: "AWS: verificando…"
        case .ok(let d): d.map { "AWS: logado até \($0.formatted(date: .omitted, time: .shortened))" } ?? "AWS: logado"
        case .expirado: "AWS: login expirado"
        case .semAws: "AWS CLI não instalado"
        case .naoConfigurado: "AWS: falta configurar"
        case .entrando: "AWS: aguardando o navegador…"
        }
    }
    var cor: Color {
        switch estado { case .ok: .green; case .expirado, .semAws, .naoConfigurado: .orange; default: .secondary }
    }

    /// Validade do token SSO pelo cache (~/.aws/sso/cache), sem precisar de rede
    private func expiracaoDoCache() -> Date? {
        let dir = URL(fileURLWithPath: "\(Config.home)/.aws/sso/cache")
        let iso = ISO8601DateFormatter()
        let datas = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).compactMap { u -> Date? in
            guard let d = try? Data(contentsOf: u), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  o["accessToken"] != nil, let e = o["expiresAt"] as? String else { return nil }
            return iso.date(from: e.replacingOccurrences(of: "UTC", with: "Z"))
        }
        return datas.max()
    }

    func verificar() async {
        guard estado != .entrando else { return }
        let existe = { (n: String) in ["/opt/homebrew/bin/\(n)", "/usr/local/bin/\(n)"].contains { FileManager.default.isExecutableFile(atPath: $0) } }
        var f: [(String, String)] = []
        if !existe("aws") { f.append(("awscli", "AWS CLI")) }
        if !existe("git-remote-codecommit") { f.append(("grc", "git-remote-codecommit (o git falar com o CodeCommit)")) }
        if existe("aws") {
            let a = await Shell.run("aws", ["configure", "get", "sso_session"])
            let b = await Shell.run("aws", ["configure", "get", "sso_role_name"])
            if !a.ok && !b.ok { f.append(("awsperfil", "Perfil AWS SSO (conta e papel)")) }
        } else {
            f.append(("awsperfil", "Perfil AWS SSO (conta e papel)"))
        }
        faltando = f.map { (id: $0.0, nome: $0.1) }
        guard existe("aws"), !f.contains(where: { $0.0 == "awsperfil" }) else { estado = .naoConfigurado; return }
        estado = .verificando
        let r = await Shell.run("aws", ["sts", "get-caller-identity", "--output", "json"])
        estado = r.ok ? .ok(expiracaoDoCache()) : .expirado
    }

    /// "aws sso login": abre o navegador; quando o usuário autoriza, o comando termina
    func entrar() {
        guard estado != .entrando else { return }
        erro = nil; codigo = nil; url = nil
        estado = .entrando
        var saida = ""
        proc = Shell.stream("aws", ["sso", "login"], onTexto: { [weak self] t in
            saida += t
            // "Then enter the code: ABCD-EFGH" / URL de verificação
            if let r = saida.range(of: #"[A-Z0-9]{4}-[A-Z0-9]{4}"#, options: .regularExpression) { self?.codigo = String(saida[r]) }
            if let r = saida.range(of: #"https://\S+"#, options: .regularExpression) { self?.url = String(saida[r]) }
        }, onFim: { [weak self] code in
            guard let self else { return }
            self.proc = nil
            self.codigo = nil
            self.estado = .desconhecido
            if code != 0 { self.erro = "O login não terminou: " + String(saida.suffix(300)) }
            Task { await self.verificar() }
        })
        if proc == nil { estado = .desconhecido; erro = "Não consegui rodar o aws sso login." }
    }

    /// Login com o bloqueio: se falta configurar algo, avisa o que é e oferece configurar
    func tentarLogin() {
        guard bloqueado else { entrar(); return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Falta configurar o login da AWS"
        a.informativeText = "Para o login (e o git dos apps) funcionar, este Mac precisa de:\n\n"
            + faltando.map { "• \($0.nome)" }.joined(separator: "\n")
            + "\n\n\"Configurar agora\" abre o Terminal e instala/configura o que falta. No perfil SSO, ele pergunta a conta e o papel (role)."
        a.addButton(withTitle: "Configurar agora")
        a.addButton(withTitle: "Cancelar")
        a.addButton(withTitle: "Tentar mesmo assim")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            let ids = faltando.map(\.id)
            Requisitos().instalar((ids.contains("awscli") || ids.contains("grc") ? ["brew"] : []) + ids)
        case .alertThirdButtonReturn:
            if faltando.contains(where: { $0.id == "awscli" }) {
                erro = "Sem o AWS CLI não dá para fazer login."
            } else { entrar() }
        default: break
        }
    }

    func cancelar() {
        proc?.terminate()
        proc = nil
        estado = .desconhecido
        codigo = nil
    }

    /// O erro do git é de credencial da AWS?
    static func erroDeLogin(_ msg: String) -> Bool {
        let m = msg.lowercased()
        return m.contains("token has expired") || m.contains("sso session") || m.contains("expiredtoken")
            || m.contains("unable to locate credentials") || m.contains("error when retrieving token from sso")
            || (m.contains("codecommit") && (m.contains("403") || m.contains("credential")))
    }
}

/// Botão compacto com o status e o login
struct BotaoAwsLogin: View {
    @ObservedObject var aws = AwsSSO.compartilhado
    var compacto = false
    @State private var detalhes = false

    var body: some View {
        Button {
            if aws.bloqueado { aws.tentarLogin() }
            else if case .ok = aws.estado { detalhes.toggle() }
            else if aws.estado == .entrando { detalhes = true }
            else { aws.entrar(); detalhes = true }
        } label: {
            HStack(spacing: 5) {
                if aws.bloqueado { Image(systemName: "lock.fill").foregroundStyle(.orange) }
                else if aws.estado == .entrando || aws.estado == .verificando { ProgressView().controlSize(.mini) }
                else { Circle().fill(aws.cor).frame(width: 7, height: 7) }
                Text(compacto ? (aws.estado == .expirado || aws.bloqueado ? "Login AWS" : "AWS") : aws.texto)
            }
        }
        .help(aws.texto + " — o git (CodeCommit) usa esse login")
        .popover(isPresented: $detalhes, arrowEdge: .bottom) { painel }
        .task { if aws.estado == .desconhecido { await aws.verificar() } }
    }

    private var painel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Login AWS (SSO)", systemImage: "key.icloud").font(.headline)
            Text(aws.texto).foregroundStyle(aws.cor)
            if aws.estado == .entrando {
                Text("O navegador abriu na página da AWS. Confira se o código é o mesmo e autorize.").font(.callout)
                if let c = aws.codigo {
                    Text(c).font(.system(size: 22, weight: .bold, design: .monospaced)).textSelection(.enabled)
                }
                HStack {
                    if let u = aws.url, let url = URL(string: u) { Button("Abrir a página de novo") { NSWorkspace.shared.open(url) } }
                    Button("Cancelar") { aws.cancelar() }
                }
            } else {
                HStack {
                    Button { aws.tentarLogin() } label: { Label("Fazer login (aws sso login)", systemImage: aws.bloqueado ? "lock.fill" : "person.badge.key") }
                        .buttonStyle(.borderedProminent)
                    Button("Verificar") { Task { await aws.verificar() } }
                }
            }
            if let e = aws.erro { Text(e).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Text("O git dos apps usa o AWS CodeCommit; quando o login expira, fetch/pull/push falham até logar de novo.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 340)
    }
}

/// Linha na seção Geral da barra lateral
struct LinhaAws: View {
    @ObservedObject var aws = AwsSSO.compartilhado
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "key.icloud").frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text("Login AWS (git)").font(.system(size: 12))
                Text(aws.estado == .entrando ? "autorize no navegador\(aws.codigo.map { " · \($0)" } ?? "")" : aws.texto.replacingOccurrences(of: "AWS: ", with: ""))
                    .font(.system(size: 10)).foregroundStyle(aws.cor)
            }
            Spacer()
            if aws.bloqueado { Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.orange) }
            else if aws.estado == .entrando || aws.estado == .verificando { ProgressView().controlSize(.mini) }
            else { Circle().fill(aws.cor).frame(width: 7, height: 7) }
        }
        .help(aws.bloqueado ? "Falta configurar: " + aws.faltando.map(\.nome).joined(separator: ", ") : "Clique para fazer login (aws sso login). O git dos apps usa o AWS CodeCommit.")
        .task { if aws.estado == .desconhecido { await aws.verificar() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if aws.estado != .entrando { Task { await aws.verificar() } }
        }
    }
}
