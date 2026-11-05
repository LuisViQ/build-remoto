import SwiftUI

// MARK: - Informações completas de uma máquina (PC ou Mac)

struct SecaoInfo: Identifiable {
    let titulo: String
    let icone: String
    var itens: [(String, String)]
    var id: String { titulo }
}

enum InfoMaquina {
    /// Saída no formato "##Seção|ícone" seguido de linhas "chave=valor"
    static func parse(_ texto: String) -> [SecaoInfo] {
        var r: [SecaoInfo] = []
        for linha in texto.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n") {
            let l = String(linha)
            if l.hasPrefix("##") {
                let p = l.dropFirst(2).split(separator: "|", maxSplits: 1).map(String.init)
                r.append(SecaoInfo(titulo: p[0], icone: p.count > 1 ? p[1] : "info.circle", itens: []))
            } else if let i = l.firstIndex(of: "="), !r.isEmpty {
                let v = String(l[l.index(after: i)...]).trimmingCharacters(in: .whitespaces)
                r[r.count - 1].itens.append((String(l[..<i]), v.isEmpty ? "—" : v))
            }
        }
        return r.filter { !$0.itens.isEmpty }
    }

    static func mac() async -> [SecaoInfo] {
        let script = #"""
        sdk="$HOME/Library/Android/sdk"
        echo "##Sistema|laptopcomputer"
        echo "macOS=$(sw_vers -productVersion) ($(sw_vers -buildVersion))"
        echo "Modelo=$(sysctl -n hw.model)"
        echo "Nome=$(scutil --get ComputerName 2>/dev/null)"
        echo "Ligado há=$(uptime | sed 's/.*up \([^,]*\),.*/\1/')"
        echo "##Hardware|cpu"
        echo "Processador=$(sysctl -n machdep.cpu.brand_string)"
        echo "Núcleos=$(sysctl -n hw.physicalcpu) físicos · $(sysctl -n hw.logicalcpu) lógicos"
        echo "Memória=$(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
        echo "Disco=$(df -h ~ | awk 'NR==2{print $4" livres de "$2" ("$5" usado)"}')"
        echo "##Rede|network"
        echo "IP local=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1)"
        echo "Wi-Fi=$(networksetup -getairportnetwork en0 2>/dev/null | grep -v 'not associated' | sed 's/Current Wi-Fi Network: //')"
        echo "Tailscale=$(ifconfig | awk '/inet 100\./{print $2; exit}')"
        echo "##Ferramentas|hammer"
        echo "Node=$(node -v 2>/dev/null)"
        echo "yarn=$(yarn -v 2>/dev/null)"
        echo "npm=$(npm -v 2>/dev/null)"
        echo "Java=$(java -version 2>&1 | head -1)"
        echo "JAVA_HOME=${JAVA_HOME:-não definido}"
        echo "Git=$(git --version 2>/dev/null | awk '{print $3}')"
        echo "Ruby=$(ruby -v 2>/dev/null | awk '{print $2}')"
        echo "CocoaPods=$(pod --version 2>/dev/null)"
        echo "Xcode=$(xcodebuild -version 2>/dev/null | head -1)"
        echo "Swift=$(swift --version 2>&1 | head -1 | sed 's/.*Swift version \([^ ]*\).*/\1/')"
        echo "Watchman=$(watchman --version 2>/dev/null)"
        echo "Homebrew=$(brew --version 2>/dev/null | head -1 | awk '{print $2}')"
        echo "##Android|iphone.gen3"
        echo "ANDROID_HOME=${ANDROID_HOME:-$sdk}"
        echo "adb=$(adb version 2>/dev/null | sed -n 2p | awk '{print $2}')"
        echo "scrcpy=$(scrcpy --version 2>/dev/null | head -1 | awk '{print $2}')"
        echo "Build-tools=$(ls "$sdk/build-tools" 2>/dev/null | tr '\n' ' ')"
        echo "Plataformas=$(ls "$sdk/platforms" 2>/dev/null | tr '\n' ' ')"
        echo "NDK=$(ls "$sdk/ndk" 2>/dev/null | tr '\n' ' ')"
        echo "CMake=$(ls "$sdk/cmake" 2>/dev/null | tr '\n' ' ')"
        echo "Emuladores=$(emulator -list-avds 2>/dev/null | tr '\n' ' ')"
        echo "##Build Remoto|arrow.triangle.2.circlepath"
        echo "Mutagen=$(mutagen version 2>/dev/null)"
        echo "Sincronizações=$(mutagen sync list 2>/dev/null | grep -c '^Name:')"
        echo "PC configurado=$(awk '/^Host pc-build$/{f=1;next} /^Host /{f=0} f&&$1=="HostName"{print $2}' ~/.ssh/config)"
        """#
        let r = await Shell.run("zsh", ["-lic", script])
        return parse(r.out) + projetos()
    }

    static func pc() async -> [SecaoInfo] {
        let ps = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
        let script = #"""
        PS="\#(ps)"
        win=$($PS -NoProfile -Command '
          $o=Get-CimInstance Win32_OperatingSystem; $c=Get-CimInstance Win32_ComputerSystem; $p=Get-CimInstance Win32_Processor | Select -First 1
          "Windows=" + $o.Caption + " (" + $o.Version + ")"
          "Fabricante=" + $c.Manufacturer + " " + $c.Model
          "Nome=" + $env:COMPUTERNAME
          "Processador=" + $p.Name.Trim()
          "Nucleos=" + $p.NumberOfCores + " fisicos / " + $p.NumberOfLogicalProcessors + " logicos / base " + $p.MaxClockSpeed + " MHz"
          "MemoriaTotal=" + [math]::Round($c.TotalPhysicalMemory/1GB) + " GB"
          "GPU=" + ((Get-CimInstance Win32_VideoController | % Name) -join ", ")
          "PlanoEnergia=" + ((powercfg /getactivescheme) -replace ".*\((.*)\).*","`$1")
          $b=Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue; if ($b) { "Bateria=" + $b.EstimatedChargeRemaining + "% · " + $(if ($b.BatteryStatus -eq 2) {"na tomada"} else {"na bateria"}) }
          "Tailscale=" + ((Get-NetIPAddress -InterfaceAlias Tailscale -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress)
          "Wi-Fi=" + ((Get-NetConnectionProfile -InterfaceAlias Wi-Fi -ErrorAction SilentlyContinue).Name) + " (" + ((Get-NetConnectionProfile -InterfaceAlias Wi-Fi -ErrorAction SilentlyContinue).NetworkCategory) + ")"
        ' 2>/dev/null | tr -d '\r')
        get() { echo "$win" | grep "^$1=" | head -1 | cut -d= -f2-; }
        echo "##Windows|pc"
        echo "Sistema=$(get Windows)"
        echo "Máquina=$(get Fabricante)"
        echo "Nome=$(get Nome)"
        echo "Plano de energia=$(get PlanoEnergia)"
        b=$(get Bateria); [ -n "$b" ] && echo "Bateria=$b"
        echo "##Hardware|cpu"
        echo "Processador=$(get Processador)"
        echo "Núcleos=$(get Nucleos | sed 's/fisicos/físicos/; s/logicos/lógicos/; s| / | · |g')"
        echo "Memória do PC=$(get MemoriaTotal)"
        echo "GPU=$(get GPU)"
        echo "##WSL (Ubuntu)|terminal"
        echo "Distro=$(lsb_release -ds 2>/dev/null)"
        echo "Kernel=$(uname -r)"
        echo "Memória do WSL=$(free -h | awk '/Mem/{print $7" livres de "$2}')"
        echo "Núcleos no WSL=$(nproc)"
        echo "Disco=$(df -h ~ | awk 'NR==2{print $4" livres de "$2" ("$5" usado)"}')"
        echo "Ligado há=$(uptime -p | sed 's/up //')"
        echo "##Rede|network"
        echo "IP local=$(hostname -I | awk '{print $1}')"
        echo "Wi-Fi=$(get Wi-Fi)"
        echo "Tailscale=$(get Tailscale)"
        echo "SSH=porta 2222 · $(ssh -V 2>&1 | cut -d, -f1)"
        echo "##Ferramentas|hammer"
        source ~/.profile >/dev/null 2>&1
        echo "Node=$(node -v 2>/dev/null)"
        echo "yarn=$(yarn -v 2>/dev/null)"
        echo "npm=$(npm -v 2>/dev/null)"
        echo "Java=$(java -version 2>&1 | head -1)"
        echo "JAVA_HOME=${JAVA_HOME:-não definido}"
        echo "Git=$(git --version | awk '{print $3}')"
        echo "tmux=$(tmux -V | awk '{print $2}')"
        echo "Gradle (memória)=$(grep -o 'Xmx[0-9a-z]*' ~/.gradle/gradle.properties 2>/dev/null)"
        echo "Gradle daemons=$(pgrep -fc GradleDaemon)"
        echo "##Android|iphone.gen3"
        echo "ANDROID_HOME=$ANDROID_HOME"
        echo "adb (WSL)=$($HOME/Android/Sdk/platform-tools/adb version 2>/dev/null | sed -n 2p | awk '{print $2}')"
        echo "adb (Windows)=$(\#(Config.adbWin) version 2>/dev/null | tr -d '\r' | sed -n 2p | awk '{print $2}')"
        echo "Build-tools=$(ls $ANDROID_HOME/build-tools 2>/dev/null | tr '\n' ' ')"
        echo "Plataformas=$(ls $ANDROID_HOME/platforms 2>/dev/null | tr '\n' ' ')"
        echo "NDK=$(ls $ANDROID_HOME/ndk 2>/dev/null | tr '\n' ' ')"
        echo "CMake=$(ls $ANDROID_HOME/cmake 2>/dev/null | tr '\n' ' ')"
        echo "Celulares=$(timeout 5 \#(Config.adbWin) devices -l 2>/dev/null | tr -d '\r' | tail -n +2 | grep device | sed 's/.*model:\([^ ]*\).*/\1/' | tr '\n' ' ')"
        echo "##Projetos no PC|folder"
        for d in ~/apps/*/; do n=$(basename $d); echo "$n=node_modules $( [ -d $d/node_modules ] && echo "$(ls $d/node_modules | wc -l) pacotes" || echo 'não instalado')"; done
        """#
        let r = await Shell.noPC(script)
        guard r.ok || !r.out.isEmpty else { return [] }
        return parse(r.out)
    }

    /// Versões declaradas em cada projeto (lidas dos arquivos no Mac)
    static func projetos() -> [SecaoInfo] {
        Config.projetos.map { p in
            let base = "\(Config.pasta(p))"
            let pkg = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(base)/package.json")))) as? [String: Any]
            let deps = (pkg?["dependencies"] as? [String: String]) ?? [:]
            let ler = { (arq: String) in (try? String(contentsOfFile: "\(base)/\(arq)", encoding: .utf8)) ?? "" }
            let achar = { (texto: String, padrao: String) -> String in
                guard let r = texto.range(of: padrao, options: .regularExpression) else { return "—" }
                return String(texto[r]).components(separatedBy: CharacterSet(charactersIn: "=\" ")).last { !$0.isEmpty } ?? "—"
            }
            let gradle = achar(ler("android/gradle/wrapper/gradle-wrapper.properties"), #"gradle-[0-9.]+"#)
                .replacingOccurrences(of: "gradle-", with: "")
            let props = ler("android/gradle.properties") + ler("android/build.gradle")
            var itens: [(String, String)] = [
                ("Versão do app", (pkg?["version"] as? String) ?? "—"),
                ("React Native", deps["react-native"] ?? "—"),
            ]
            if let e = deps["expo"] { itens.append(("Expo SDK", e)) }
            itens += [
                ("React", deps["react"] ?? "—"),
                ("Gradle", gradle),
                ("compileSdk", achar(props, #"compileSdk(Version)?\s*=\s*\d+"#)),
                ("targetSdk", achar(props, #"targetSdk(Version)?\s*=\s*\d+"#)),
                ("Pacote", achar(ler("android/app/build.gradle"), #"applicationId\s*=?\s*["'][^"']+"#).replacingOccurrences(of: "'", with: "")),
                ("Branch", (try? String(contentsOfFile: "\(base)/.git/HEAD", encoding: .utf8))?
                    .replacingOccurrences(of: "ref: refs/heads/", with: "").trimmingCharacters(in: .whitespacesAndNewlines) ?? "—"),
            ]
            return SecaoInfo(titulo: p, icone: "app.badge", itens: itens)
        }
    }
}

struct InfoMaquinaSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State var maquina: Origem
    @State private var secoes: [SecaoInfo] = []
    @State private var carregando = false
    @State private var copiado = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: maquina == .pc ? "desktopcomputer" : "laptopcomputer")
                    .font(.system(size: 26)).foregroundStyle(maquina == .pc ? .green : .blue)
                VStack(alignment: .leading) {
                    Text(maquina == .pc ? "PC de build" : "Este Mac").font(.title2.bold())
                    Text("Sistema, hardware, ferramentas e versões").foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $maquina) {
                    Label("PC", systemImage: "desktopcomputer").tag(Origem.pc)
                    Label("Este Mac", systemImage: "laptopcomputer").tag(Origem.mac)
                }
                .pickerStyle(.segmented).frame(width: 220)
                Button {
                    let texto = secoes.map { s in "## \(s.titulo)\n" + s.itens.map { "\($0.0): \($0.1)" }.joined(separator: "\n") }
                        .joined(separator: "\n\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("# \(maquina == .pc ? "PC de build" : "Mac")\n\n" + texto, forType: .string)
                    copiado = true
                } label: { Label(copiado ? "Copiado" : "Copiar tudo", systemImage: copiado ? "checkmark" : "doc.on.doc") }
                .disabled(secoes.isEmpty)
                Button { Task { await carregar() } } label: { Image(systemName: "arrow.clockwise") }.disabled(carregando)
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(18)
            Divider()
            ZStack {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 14, alignment: .top)], spacing: 14) {
                        ForEach(secoes) { s in
                            VStack(alignment: .leading, spacing: 8) {
                                Label(s.titulo, systemImage: s.icone).font(.headline)
                                ForEach(Array(s.itens.enumerated()), id: \.offset) { _, kv in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(kv.0).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                                        Text(kv.1).textSelection(.enabled).lineLimit(3)
                                        Spacer(minLength: 0)
                                    }
                                    .font(.system(size: 12))
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.45)))
                        }
                    }
                    .padding(18)
                }
                if carregando && secoes.isEmpty {
                    VStack(spacing: 10) { ProgressView(); Text("Coletando informações…").foregroundStyle(.secondary) }
                } else if !carregando && secoes.isEmpty {
                    ContentUnavailableView("Sem resposta", systemImage: "wifi.exclamationmark",
                                           description: Text("O PC está offline. Abra o Ubuntu no Windows ou verifique a rede."))
                }
            }
        }
        .frame(width: 900, height: 680)
        .task(id: maquina) { await carregar() }
    }

    private func carregar() async {
        carregando = true
        copiado = false
        secoes = []
        secoes = maquina == .pc ? await InfoMaquina.pc() : await InfoMaquina.mac()
        carregando = false
    }
}
