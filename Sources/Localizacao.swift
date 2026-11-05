import SwiftUI
import MapKit

// MARK: - Localização falsa no celular
//
// Emulador: "adb emu geo fix". Celular físico (Android 12+): provedores de teste do próprio Android
// ("cmd location providers"), com o shell autorizado como app de localização simulada — sem instalar nada.

struct LugarSalvo: Codable, Identifiable, Hashable {
    var id = UUID()
    var nome: String
    var lat: Double
    var lon: Double
    var coord: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
}

@MainActor
final class LocalizacaoModel: ObservableObject {
    @Published var ativa = false
    @Published var atual: CLLocationCoordinate2D?
    @Published var precisao: Double = 5
    @Published var status = ""
    @Published var erro: String?
    @Published var lugares: [LugarSalvo] = []
    // trajeto
    @Published var rota: [CLLocationCoordinate2D] = []
    @Published var distanciaRota: Double = 0
    @Published var velocidadeKmh: Double = 40
    @Published var progresso: Double = 0
    @Published var andando = false
    private var dispositivo: Dispositivo?
    private var tarefaManter: Task<Void, Never>?
    private var tarefaRota: Task<Void, Never>?
    private let provedores = ["gps", "network", "fused"]

    init() {
        if let d = UserDefaults.standard.data(forKey: "localizacao.lugares"),
           let l = try? JSONDecoder().decode([LugarSalvo].self, from: d) { lugares = l }
    }

    func salvarLugar(_ nome: String, _ c: CLLocationCoordinate2D) {
        lugares.append(LugarSalvo(nome: nome, lat: c.latitude, lon: c.longitude))
        persistir()
    }
    func removerLugar(_ l: LugarSalvo) { lugares.removeAll { $0.id == l.id }; persistir() }
    private func persistir() { UserDefaults.standard.set(try? JSONEncoder().encode(lugares), forKey: "localizacao.lugares") }

    private func emulador(_ d: Dispositivo) -> Bool { d.serial.hasPrefix("emulator-") }

    /// Liga os provedores de teste (só no celular físico)
    private func preparar(_ d: Dispositivo) async -> String? {
        if emulador(d) { return nil }
        let sdk = Int((await Adb.shell(d, "getprop ro.build.version.sdk")).out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard sdk >= 31 else { return "No celular físico isso precisa do Android 12 ou mais novo (este é API \(sdk)). Use um emulador." }
        let r = await Adb.shell(d, "appops set com.android.shell android:mock_location allow")
        if !r.ok { return "O celular recusou a localização simulada: \(r.out)" }
        var algum = false
        for p in provedores {
            _ = await Adb.shell(d, "cmd location providers add-test-provider \(p)")
            let e = await Adb.shell(d, "cmd location providers set-test-provider-enabled \(p) true")
            if e.ok && !e.out.lowercased().contains("exception") { algum = true }
        }
        return algum ? nil : "Não consegui criar os provedores de teste. Confira se a localização do celular está ligada."
    }

    private func enviar(_ d: Dispositivo, _ c: CLLocationCoordinate2D) async -> Bool {
        let lat = String(format: "%.7f", c.latitude), lon = String(format: "%.7f", c.longitude)
        if emulador(d) {
            let r = await Adb.run(d, ["emu", "geo", "fix", lon, lat])
            return r.ok && !r.out.lowercased().contains("ko")
        }
        var ok = false
        for p in provedores {
            let r = await Adb.shell(d, "cmd location providers set-test-provider-location \(p) --location \(lat),\(lon) --accuracy \(Int(precisao))")
            if r.ok && !r.out.lowercased().contains("exception") { ok = true }
        }
        return ok
    }

    func definir(_ c: CLLocationCoordinate2D, em d: Dispositivo) async {
        erro = nil
        if !ativa || dispositivo?.id != d.id {
            status = "Preparando o celular…"
            if let e = await preparar(d) { erro = e; status = ""; return }
            dispositivo = d
            ativa = true
        }
        if await enviar(d, c) {
            atual = c
            status = "Localização: \(String(format: "%.5f, %.5f", c.latitude, c.longitude))"
            manterViva()
        } else {
            erro = "O celular não aceitou a localização."
        }
    }

    /// Reenvia a posição a cada 2 s: alguns apps descartam localização "velha"
    private func manterViva() {
        tarefaManter?.cancel()
        tarefaManter = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.ativa, !self.andando, let d = self.dispositivo, let c = self.atual else { continue }
                _ = await self.enviar(d, c)
            }
        }
    }

    func parar() async {
        tarefaRota?.cancel(); andando = false
        tarefaManter?.cancel()
        guard let d = dispositivo else { ativa = false; return }
        status = "Voltando ao GPS real…"
        if !emulador(d) {
            for p in provedores { _ = await Adb.shell(d, "cmd location providers remove-test-provider \(p)") }
            _ = await Adb.shell(d, "appops set com.android.shell android:mock_location default")
        }
        ativa = false
        dispositivo = nil
        status = emulador(d) ? "Emulador: a última posição fica até você mudar (é o normal do emulador)." : "GPS real de volta ✓"
    }

    // MARK: trajeto

    func calcularRota(de a: CLLocationCoordinate2D, para b: CLLocationCoordinate2D, transporte: MKDirectionsTransportType) async {
        erro = nil
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: a))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: b))
        req.transportType = transporte
        do {
            let r = try await MKDirections(request: req).calculate()
            guard let rt = r.routes.first else { erro = "Nenhuma rota encontrada"; return }
            let n = rt.polyline.pointCount
            var pts = [CLLocationCoordinate2D](repeating: .init(), count: n)
            rt.polyline.getCoordinates(&pts, range: NSRange(location: 0, length: n))
            rota = pts
            distanciaRota = rt.distance
            progresso = 0
        } catch {
            // sem rota (ex.: sem internet): linha reta
            rota = [a, b]
            distanciaRota = CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
            progresso = 0
        }
    }

    func andar(em d: Dispositivo) {
        guard rota.count >= 2 else { return }
        tarefaRota?.cancel()
        andando = true
        tarefaRota = Task { [weak self] in
            guard let self else { return }
            if !self.ativa || self.dispositivo?.id != d.id {
                if let e = await self.preparar(d) { self.erro = e; self.andando = false; return }
                self.dispositivo = d; self.ativa = true
            }
            // distâncias acumuladas ao longo da rota
            var acum: [Double] = [0]
            for i in 1..<self.rota.count {
                let a = self.rota[i - 1], b = self.rota[i]
                acum.append(acum[i - 1] + CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)))
            }
            let total = max(acum.last ?? 1, 1)
            var percorrido = self.progresso * total
            while !Task.isCancelled && percorrido < total {
                let c = Self.ponto(self.rota, acum, percorrido)
                _ = await self.enviar(d, c)
                self.atual = c
                self.progresso = percorrido / total
                self.status = String(format: "Andando: %.1f de %.1f km a %.0f km/h", percorrido / 1000, total / 1000, self.velocidadeKmh)
                try? await Task.sleep(for: .seconds(1))
                percorrido += self.velocidadeKmh / 3.6
            }
            if !Task.isCancelled {
                if let fim = self.rota.last { _ = await self.enviar(d, fim); self.atual = fim }
                self.progresso = 1
                self.status = "Chegou ao destino ✓"
            }
            self.andando = false
            self.manterViva()
        }
    }

    func pausar() { tarefaRota?.cancel(); andando = false; manterViva() }

    private static func ponto(_ r: [CLLocationCoordinate2D], _ acum: [Double], _ d: Double) -> CLLocationCoordinate2D {
        guard let i = acum.firstIndex(where: { $0 >= d }), i > 0 else { return r.first! }
        let t = (d - acum[i - 1]) / max(acum[i] - acum[i - 1], 0.001)
        return .init(latitude: r[i - 1].latitude + (r[i].latitude - r[i - 1].latitude) * t,
                     longitude: r[i - 1].longitude + (r[i].longitude - r[i - 1].longitude) * t)
    }
}

// MARK: - Tela

struct LocalizacaoView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var loc: LocalizacaoModel
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(center: .init(latitude: -19.92, longitude: -43.94),
                                                                               span: .init(latitudeDelta: 0.08, longitudeDelta: 0.08)))
    @State private var marcado: CLLocationCoordinate2D?
    @State private var busca = ""
    @State private var resultados: [MKMapItem] = []
    @State private var coordTexto = ""
    @State private var modoRota = false
    @State private var origem: CLLocationCoordinate2D?
    @State private var destino: CLLocationCoordinate2D?
    @State private var transporte = 0
    @State private var nomeLugar = ""
    @State private var salvando = false

    var body: some View {
        HSplitView {
            painel
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 420, maxHeight: .infinity, alignment: .top)
            mapa
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $salvando) {
            NomeSheet(titulo: "Salvar este lugar", placeholder: "ex.: Obra Centro, Sede, Cliente X", botao: "Salvar", opcional: false) { n in
                if let c = marcado { loc.salvarLugar(n.replacingOccurrences(of: "-", with: " "), c) }
            }
        }
    }

    // MARK: painel

    private var painel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Circle().fill(loc.ativa ? Color.orange : .green).frame(width: 9, height: 9)
                    Text(loc.ativa ? "Localização FALSA ativa" : "GPS real").font(.headline)
                    Spacer()
                    if loc.ativa {
                        Button("Voltar ao GPS real") { Task { await loc.parar() } }.buttonStyle(.borderedProminent).tint(.orange)
                    }
                }
                if let d = app.alvo {
                    Label("\(d.nome) · \(d.serial.hasPrefix("emulator-") ? "emulador" : "celular físico")", systemImage: "iphone.gen3")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Conecte e escolha um celular ou emulador", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if !loc.status.isEmpty { Text(loc.status).font(.caption.monospaced()).foregroundStyle(.secondary) }
                if let e = loc.erro { Text(e).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }

                Picker("", selection: $modoRota) {
                    Text("Ponto fixo").tag(false)
                    Text("Trajeto").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden()

                GroupBox("Buscar endereço") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Rua, bairro, cidade ou lugar", text: $busca).textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await buscar() } }
                        ForEach(resultados, id: \.self) { r in
                            Button {
                                let c = r.placemark.coordinate
                                escolher(c)
                                resultados = []
                            } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(r.name ?? "").font(.callout)
                                    Text(r.placemark.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                        HStack {
                            TextField("ou cole: -19.9167, -43.9345", text: $coordTexto).textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .onSubmit { colarCoordenada() }
                            Button("Ir") { colarCoordenada() }
                        }
                    }
                    .padding(4)
                }

                if modoRota { painelRota } else { painelPonto }

                GroupBox("Lugares salvos") {
                    VStack(alignment: .leading, spacing: 4) {
                        if loc.lugares.isEmpty { Text("Marque um ponto no mapa e clique em Salvar.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(loc.lugares) { l in
                            HStack {
                                Button { escolher(l.coord) } label: { Label(l.nome, systemImage: "mappin.circle.fill") }.buttonStyle(.borderless)
                                Spacer()
                                if let d = app.alvo {
                                    Button("Usar") { escolher(l.coord); Task { await loc.definir(l.coord, em: d) } }.controlSize(.small)
                                }
                                Button { loc.removerLugar(l) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(4)
                }

                Text(app.alvo?.serial.hasPrefix("emulator-") == true
                     ? "No emulador a posição é enviada direto (adb emu geo fix)."
                     : "No celular físico (Android 12+) o app usa os provedores de teste do Android — não precisa instalar nada. \"Voltar ao GPS real\" desfaz tudo.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var painelPonto: some View {
        GroupBox("Ponto") {
            VStack(alignment: .leading, spacing: 8) {
                Text(marcado.map { String(format: "%.6f, %.6f", $0.latitude, $0.longitude) } ?? "Clique no mapa para marcar")
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Text("Precisão")
                    Slider(value: $loc.precisao, in: 1...100, step: 1)
                    Text("\(Int(loc.precisao)) m").font(.caption.monospacedDigit()).frame(width: 44)
                }
                .font(.caption)
                HStack {
                    Button {
                        if let c = marcado, let d = app.alvo { Task { await loc.definir(c, em: d) } }
                    } label: { Label("Colocar o celular aqui", systemImage: "location.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(marcado == nil || app.alvo == nil)
                    Button("Salvar") { salvando = true }.disabled(marcado == nil)
                }
            }
            .padding(4)
        }
    }

    private var painelRota: some View {
        GroupBox("Trajeto") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "a.circle.fill").foregroundStyle(.green)
                    Text(origem.map { String(format: "%.5f, %.5f", $0.latitude, $0.longitude) } ?? "clique no mapa").font(.caption.monospaced())
                    Spacer()
                    Button("Usar atual") { origem = loc.atual ?? marcado }.controlSize(.small).disabled(loc.atual == nil && marcado == nil)
                }
                HStack {
                    Image(systemName: "b.circle.fill").foregroundStyle(.red)
                    Text(destino.map { String(format: "%.5f, %.5f", $0.latitude, $0.longitude) } ?? "clique no mapa").font(.caption.monospaced())
                }
                Picker("Por", selection: $transporte) {
                    Text("Carro").tag(0); Text("A pé").tag(1); Text("Linha reta").tag(2)
                }
                .pickerStyle(.segmented)
                Button("Calcular trajeto") {
                    guard let o = origem, let dd = destino else { return }
                    Task {
                        if transporte == 2 { loc.rota = [o, dd]; loc.progresso = 0
                            loc.distanciaRota = CLLocation(latitude: o.latitude, longitude: o.longitude).distance(from: CLLocation(latitude: dd.latitude, longitude: dd.longitude))
                        } else { await loc.calcularRota(de: o, para: dd, transporte: transporte == 0 ? .automobile : .walking) }
                    }
                }
                .disabled(origem == nil || destino == nil)
                if loc.rota.count >= 2 {
                    Text(String(format: "%.1f km · %.0f min a %.0f km/h", loc.distanciaRota / 1000,
                                loc.distanciaRota / 1000 / max(loc.velocidadeKmh, 1) * 60, loc.velocidadeKmh)).font(.caption)
                    HStack {
                        Text("Velocidade").font(.caption)
                        Slider(value: $loc.velocidadeKmh, in: 3...150, step: 1)
                        Text("\(Int(loc.velocidadeKmh)) km/h").font(.caption.monospacedDigit()).frame(width: 60)
                    }
                    ProgressView(value: loc.progresso)
                    HStack {
                        if loc.andando {
                            Button { loc.pausar() } label: { Label("Pausar", systemImage: "pause.fill") }
                        } else {
                            Button { if let d = app.alvo { loc.andar(em: d) } } label: {
                                Label(loc.progresso > 0 && loc.progresso < 1 ? "Continuar" : "Começar a andar", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent).disabled(app.alvo == nil)
                        }
                        Button("Do início") { loc.pausar(); loc.progresso = 0 }.disabled(loc.progresso == 0)
                    }
                }
                Text("Clique no mapa: o 1º clique marca A, o 2º marca B.").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(4)
        }
    }

    // MARK: mapa

    private var mapa: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if let c = loc.atual {
                    Annotation("Celular", coordinate: c) {
                        ZStack {
                            Circle().fill(.orange.opacity(0.25)).frame(width: 34, height: 34)
                            Circle().fill(.orange).frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                }
                if !modoRota, let m = marcado { Marker("Aqui", coordinate: m).tint(.blue) }
                if modoRota {
                    if let o = origem { Marker("A", coordinate: o).tint(.green) }
                    if let d = destino { Marker("B", coordinate: d).tint(.red) }
                    if loc.rota.count >= 2 { MapPolyline(coordinates: loc.rota).stroke(.blue, lineWidth: 5) }
                }
                ForEach(loc.lugares) { l in
                    Annotation(l.nome, coordinate: l.coord) {
                        Image(systemName: "mappin.circle.fill").font(.title2).foregroundStyle(.purple).background(Circle().fill(.white))
                    }
                }
            }
            .mapControls { MapZoomStepper(); MapCompass(); MapScaleView() }
            .onTapGesture { p in
                guard let c = proxy.convert(p, from: .local) else { return }
                if modoRota {
                    if origem == nil || (origem != nil && destino != nil) { origem = c; destino = nil; loc.rota = [] }
                    else { destino = c }
                } else {
                    marcado = c
                }
            }
        }
        .overlay(alignment: .bottom) {
            if !modoRota, let m = marcado, let d = app.alvo {
                Button { Task { await loc.definir(m, em: d) } } label: {
                    Label("Colocar o celular aqui", systemImage: "location.fill").padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).shadow(radius: 4).padding(16)
            }
        }
    }

    private func escolher(_ c: CLLocationCoordinate2D) {
        if modoRota {
            if origem == nil { origem = c } else { destino = c }
        } else {
            marcado = c
        }
        camera = .region(MKCoordinateRegion(center: c, span: .init(latitudeDelta: 0.01, longitudeDelta: 0.01)))
    }

    private func buscar() async {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = busca
        resultados = Array(((try? await MKLocalSearch(request: req).start())?.mapItems ?? []).prefix(6))
        if resultados.isEmpty { loc.erro = "Nada encontrado para \"\(busca)\"" }
    }

    private func colarCoordenada() {
        let n = coordTexto.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).compactMap { Double($0) }
        guard n.count >= 2, abs(n[0]) <= 90, abs(n[1]) <= 180 else { loc.erro = "Formato: latitude, longitude"; return }
        escolher(.init(latitude: n[0], longitude: n[1]))
    }
}
