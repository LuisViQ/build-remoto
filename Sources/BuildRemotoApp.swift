import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var estado: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { estado?.encerrar() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct BuildRemotoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppState()

    var body: some Scene {
        Window("Build Remoto", id: "main") {
            MainView()
                .environmentObject(app)
                .frame(minWidth: 900, minHeight: 620)
                .onAppear { delegate.estado = app }
        }
        .defaultSize(width: 1180, height: 800)
        .commands {
            CommandMenu("Ações") {
                Button("Paleta de comandos") { app.mostrarPaleta = true }.keyboardShortcut("k")
                Divider()
                Button("Rodar app") { if let p = app.selecionado { app.executar(.rodar, p) } }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Recarregar app (r)") { app.recarregarAtivo() }.keyboardShortcut("r")
                Button("Metro") { if let p = app.selecionado { app.executar(.metro, p) } }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("APK Debug") { if let p = app.selecionado { app.executar(.debug, p) } }.keyboardShortcut("b", modifiers: [.command, .shift])
                Divider()
                Button("Mostrar/ocultar tela do celular") {
                    if app.mostrarTela { app.mostrarTela = false } else { app.abrirTela() }
                }.keyboardShortcut("t")
                Button("Relatório de bug") { if let p = app.selecionado { app.gerarRelatorio(p) } }.keyboardShortcut("b", modifiers: [.command, .option])
                Button("Diagnóstico") { app.mostrarDiagnostico = true }.keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Painel de notas") { app.painelNotas.toggle() }.keyboardShortcut("n", modifiers: [.command, .shift])
                AbrirTodasNotas()
                Button("Nova nota rápida (⌥⌘N, de qualquer app)") { NotaRapida.mostrar() }
                Button("Resumo para a daily…") { app.mostrarResumo = true }.keyboardShortcut("d", modifiers: [.command, .option])
                Button("Gerar versão…") { app.gerarVersaoDe = app.selecionado }.keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(app.selecionado == nil)
                Button("Boas-vindas e requisitos…") { app.mostrarBoasVindas = true }
                Divider()
                ForEach(Array(Ferramenta.allCases.prefix(9).enumerated()), id: \.offset) { i, f in
                    Button(f.rawValue) { if let p = app.selecionado { app.abaFerramenta[p] = f } }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
                Divider()
                ForEach(Array(Config.projetos.enumerated()), id: \.offset) { i, p in
                    Button(p) { app.selecionado = p }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .control])
                }
            }
        }

        // Notas de todos os apps juntas
        Window("Todas as notas", id: "todas-notas") {
            TodasNotasView().environmentObject(app)
        }
        .defaultSize(width: 1200, height: 760)

        // Realm em janela própria (dá para colocar em tela cheia)
        WindowGroup("Realm", id: "realm", for: String.self) { $projeto in
            if let projeto {
                RealmView(model: app.realm(projeto), emJanela: true)
                    .environmentObject(app)
                    .navigationTitle("Realm — \(projeto)")
                    .frame(minWidth: 900, minHeight: 600)
            }
        }
        .defaultSize(width: 1400, height: 900)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(app)
                .onAppear { app.iniciar() }
        } label: {
            Image(systemName: app.sessoesRemotas.values.contains(.rodando) ? "hammer.circle.fill" : "hammer.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
