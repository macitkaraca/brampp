import SwiftUI
import AppKit

struct ServicesTabView: View {
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var serviceManager: ServiceManager

    enum SortOption: String, CaseIterable {
        case category = "Kategori"
        case name     = "İsim"
        case status   = "Durum"

        /// Segmented picker'da gösterilecek yerelleştirme anahtarı.
        var l10nKey: String {
            switch self {
            case .category: return "svc.sort.category"
            case .name:     return "svc.sort.name"
            case .status:   return "svc.sort.status"
            }
        }
    }

    @State private var sortOption: SortOption = .category
    /// Kurulum log panelini aç/kapat
    @State private var showInstallLog: Bool = false

    @State private var showDiagnostics = false
    /// Kurulu olmayan servisleri de göster (varsayılan: gizli — liste sade kalsın)
    @State private var showInstallable: Bool = false

    /// Gösterilecek servisler: showInstallable kapalıyken notInstalled olanlar gizlenir.
    private func visible(_ list: [Service]) -> [Service] {
        showInstallable ? list : list.filter { $0.status != .notInstalled }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    if !Shell.isBrewInstalled { BrewWarningBanner() }
                    switch sortOption {
                    case .category:
                        ForEach(ServiceCategory.allCases) { cat in
                            let svcs = visible(serviceManager.services(for: cat))
                            if !svcs.isEmpty { ServiceGroupView(category: cat, services: svcs) }
                        }
                    case .name:
                        let sorted = visible(serviceManager.services).sorted { $0.name < $1.name }
                        if !sorted.isEmpty {
                            ServiceGroupView(category: .webServer, services: sorted, customTitle: loc.t("svc.all"), customIcon: "📋")
                        }
                    case .status:
                        let running = serviceManager.services.filter { $0.status == .running }
                        let stopped = serviceManager.services.filter { $0.status == .stopped }
                        let others  = visible(serviceManager.services.filter { $0.status != .running && $0.status != .stopped })
                        if !running.isEmpty { ServiceGroupView(category: .webServer, services: running, customTitle: loc.t("svc.running"), customIcon: "🟢") }
                        if !stopped.isEmpty { ServiceGroupView(category: .database,  services: stopped, customTitle: loc.t("menu.stopped"), customIcon: "🔴") }
                        if !others.isEmpty  { ServiceGroupView(category: .cache,     services: others,  customTitle: loc.t("svc.other"), customIcon: "⚪️") }
                    }
                }.padding()
            }
            Divider()
            legendView
        }
        // Kurulum başladığında log sheet'ini otomatik aç
        .onChange(of: serviceManager.isInstalling) { _, installing in
            if installing { showInstallLog = true }
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsSheetView()
        }
        .sheet(isPresented: $showInstallLog) {
            InstallationProgressSheet(serviceManager: serviceManager, isPresented: $showInstallLog)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(loc.t("svc.title")).font(.headline)
            Spacer()
            Text(loc.t("svc.sort"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize()
            Picker("", selection: $sortOption) {
                ForEach(SortOption.allCases, id: \.self) { Text(loc.t($0.l10nKey)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
            Divider().frame(height: 20)
            Button(action: { showDiagnostics = true }) {
                Label(loc.t("diag.menu"), systemImage: "stethoscope")
            }
            .buttonStyle(.bordered)
            .help(loc.t("diag.sub"))
            Button(action: { serviceManager.startAll() }) {
                Label(loc.t("menu.startAll"), systemImage: "play.fill")
            }
            .buttonStyle(.bordered).tint(.green).disabled(!Shell.isBrewInstalled)
            .help(loc.t("svc.startAllHelp"))
            Button(action: { serviceManager.stopAll() }) {
                Label(loc.t("menu.stopAll"), systemImage: "stop.fill")
            }
            .buttonStyle(.bordered).tint(.red).disabled(!Shell.isBrewInstalled)
            .help(loc.t("svc.stopAllHelp"))
            Button(action: { serviceManager.refreshStatus() }) {
                Image(systemName: "arrow.clockwise")
            }.buttonStyle(.bordered).help(loc.t("svc.refreshHelp"))
            Button(action: { showInstallable.toggle() }) {
                Image(systemName: showInstallable ? "eye.slash" : "plus.circle")
            }
            .buttonStyle(.bordered)
            .help(loc.t(showInstallable ? "svc.hideInstallable" : "svc.showInstallable"))
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
    
    private var legendView: some View {
        HStack(spacing: 20) {
            LegendItemView(color: .green, text: loc.t("svc.running"))
            LegendItemView(color: .red, text: loc.t("menu.stopped"))
            LegendItemView(color: .blue, text: loc.t("svc.installedState"))
            LegendItemView(color: .gray, text: loc.t("svc.notInstalled"))
        }.font(.caption).padding()
    }
}

// MARK: - Service Group

struct ServiceGroupView: View {
    @EnvironmentObject var loc: Localizer
    let category: ServiceCategory
    let services: [Service]
    var customTitle: String? = nil
    /// Özel başlıklı gruplar için emoji ikon (nil → 📋). Kategori ikonları emoji olduğundan
    /// SF Symbol adı ("list.bullet") Text() içinde düz metin görünüyordu — bu yüzden emoji.
    var customIcon: String? = nil
    @State private var isExpanded: Bool = true

    private var title: String { customTitle ?? category.l10nKey.map { loc.t($0) } ?? category.displayName }
    private var icon: String  { customTitle != nil ? (customIcon ?? "📋") : category.icon }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack {
                    Text(icon); Text(title).font(.headline)
                    Spacer()
                    Text("\(services.count)").font(.caption).foregroundColor(.secondary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down").foregroundColor(.secondary)
                }.padding().background(Color(NSColor.controlBackgroundColor))
            }.buttonStyle(.plain)
            if isExpanded { VStack(spacing: 1) { ForEach(services, id: \.id) { ServiceRowView(service: $0) } } }
        }
        .background(Color(NSColor.separatorColor).opacity(0.3)).cornerRadius(10)
    }
}

// MARK: - Service Row

struct ServiceRowView: View {
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var serviceManager: ServiceManager
    @EnvironmentObject var tunnelManager: TunnelManager
    let service: Service

    @State private var showApacheConfig    = false
    @State private var showNginxConfig     = false
    @State private var showUninstallAlert  = false

    /// cloudflared satırının alt yazısı — açık yayınları adlarıyla listeler.
    @ViewBuilder
    private var cloudflaredStatus: some View {
        let live = tunnelManager.tunnels.values.filter(\.isLive)
            .map(\.domainName).sorted()
        if live.isEmpty {
            CaptionText(loc.t("svc.cf.idle"))
        } else {
            Text(live.count == 1
                 ? String(format: loc.t("svc.cf.activeOne"), live[0])
                 : String(format: loc.t("svc.cf.activeMany"), live.count, live.joined(separator: ", ")))
                .font(.caption).foregroundColor(.green)
        }
    }

    private var isPhpMyAdminInstalled: Bool {
        PathConfig.isPhpMyAdminInstalled
    }

    private var isPgAdminInstalled: Bool {
        PathConfig.isPgAdmin4Installed
    }

    private var isAdminerInstalled: Bool {
        PathConfig.isAdminerInstalled
    }

    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            if service.isLoading {
                ProgressView().scaleEffect(0.7).frame(width: 20, height: 20)
            } else if service.isStarting {
                ProgressView().tint(.orange).scaleEffect(0.7).frame(width: 20, height: 20)
            } else if service.isStopping {
                ProgressView().tint(.red).scaleEffect(0.7).frame(width: 20, height: 20)
            } else {
                Image(systemName: service.status.icon).foregroundColor(service.status.color).frame(width: 20)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(service.name).fontWeight(.medium)
                if service.id == "cloudflared" {
                    // Bu satır "kurulu mu"dan fazlasını söylemeli: cloudflared sürekli
                    // çalışmaz, bir paylaşım açıkken yaşar. Kullanıcının görmek
                    // istediği HANGİ sitelerin şu anda internete açık olduğu.
                    cloudflaredStatus
                } else if let v = service.version {
                    CaptionText("v\(v)")
                }
            }
            Spacer()
            actionButtons
            // MariaDB satırında phpMyAdmin + Adminer butonları
            if service.id == "mariadb" {
                phpMyAdminButton
                adminerButton
            }
            // Mailpit satırında web arayüzü — SMTP portu 1025, arayüz 8025
            if service.id == "mailpit", service.status == .running {
                Button(action: {
                    if let u = URL(string: "http://127.0.0.1:8025") { NSWorkspace.shared.open(u) }
                }) {
                    Image(systemName: "envelope.open")
                }
                .help(loc.t("svc.mailpit.open"))
            }
            // PostgreSQL satırlarında pgAdmin + Adminer butonları
            if service.id.hasPrefix("postgresql@") {
                pgAdminButton
                adminerButton
            }
            // Apache ayar butonu
            if service.id == "httpd" {
                Button(action: { showApacheConfig = true }) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(loc.t("svc.portSettingsHelp"))
            }
            // Nginx ayar butonu
            if service.id == "nginx" {
                Button(action: { showNginxConfig = true }) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(loc.t("svc.portSettingsHelp"))
            }
            // Port — en sağda
            if let portText = portDisplayText {
                Text(portText)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal).padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .sheet(isPresented: $showApacheConfig) {
            ApachePortConfigView(isPresented: $showApacheConfig)
                .environmentObject(serviceManager)
        }
        .sheet(isPresented: $showNginxConfig) {
            NginxPortConfigView(isPresented: $showNginxConfig)
                .environmentObject(serviceManager)
        }
        .alert(String(format: loc.t("svc.uninstall.title"), service.name), isPresented: $showUninstallAlert) {
            Button(loc.t("svc.uninstall"), role: .destructive) { serviceManager.uninstallService(service) }
            Button(loc.t("common.cancel"), role: .cancel) { }
        } message: {
            Text(loc.t("svc.uninstall.confirm"))
        }
    }

    private var portDisplayText: String? {
        if service.id == "httpd" {
            let http = service.port ?? 80
            return ":\(http)  :443"
        }
        if service.id == "nginx" {
            let http = service.port ?? 8080
            return ":\(http)  :8443"
        }
        guard let port = service.port else { return nil }
        return ":\(String(port))"
    }

    // MARK: - phpMyAdmin Button

    @ViewBuilder
    private var phpMyAdminButton: some View {
        if isPhpMyAdminInstalled {
            Button(action: {
                if let url = URL(string: "https://localhost/phpmyadmin") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                Label("phpMyAdmin", systemImage: "safari")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.blue)
            .disabled(service.status != .running)
            .help(service.status == .running ? loc.t("svc.pmaOpenHelp") : loc.t("svc.mariadbNotRunning"))
        } else {
            Button(action: {
                installPhpMyAdmin()
            }) {
                Label(loc.t("db.phpMyAdminInstall"), systemImage: "arrow.down.circle")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!Shell.isBrewInstalled)
            .help("phpMyAdmin'i Homebrew ile kur")
        }
    }

    /// ServiceManager.installPhpMyAdmin() → InstallationProgressSheet otomatik açılır
    private func installPhpMyAdmin() {
        serviceManager.installPhpMyAdmin()
    }

    // MARK: - pgAdmin Button

    @ViewBuilder
    private var pgAdminButton: some View {
        if isPgAdminInstalled {
            Button(action: openPgAdmin) {
                Label("pgAdmin", systemImage: "safari")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.blue)
            .disabled(service.status != .running)
            .help(service.status == .running ? loc.t("svc.pgadminOpenHelp2") : loc.t("svc.pgNotRunning"))
        } else {
            Button(action: { installPgAdmin() }) {
                Label(loc.t("db.pgadminInstall"), systemImage: "arrow.down.circle")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!Shell.isBrewInstalled)
            .help(loc.t("svc.pgadminInstallHelp"))
        }
    }

    private func openPgAdmin() {
        let apacheConfigured = FileHelper.exists(PathConfig.pgadmin4Conf)
        let nginxConfigured  = NginxConfigManager.isPgAdmin4Configured
        let urlString: String
        if apacheConfigured {
            urlString = "https://localhost/pgadmin4"
        } else if nginxConfigured {
            urlString = "http://localhost:8080/pgadmin4/"
        } else {
            urlString = "http://127.0.0.1:\(PathConfig.pgadmin4Port)"
        }
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Adminer Button

    /// Adminer tek dosyayla hem MySQL/MariaDB hem PostgreSQL yönettiğinden
    /// her iki veritabanı satırında da gösterilir.
    @ViewBuilder
    private var adminerButton: some View {
        if isAdminerInstalled {
            Button(action: openAdminer) {
                Label("Adminer", systemImage: "safari")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.teal)
            .disabled(service.status != .running)
            .help(service.status == .running
                  ? loc.t("db.adminerOpenHelp")
                  : (service.id == "mariadb" ? loc.t("svc.mariadbNotRunning") : loc.t("svc.pgNotRunning")))
        } else {
            Button(action: { serviceManager.installAdminer() }) {
                Label(loc.t("db.adminerInstall"), systemImage: "arrow.down.circle")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!Shell.isBrewInstalled || serviceManager.isInstalling)
            .help(loc.t("db.adminerInstallHelp"))
        }
    }

    private func openAdminer() {
        // Apache yapılandırıldıysa 80/443; değilse Nginx 8080 (DatabaseTabView ile aynı kural)
        let urlString = FileHelper.exists(PathConfig.adminerConf)
            ? "https://localhost/adminer/"
            : "http://localhost:8080/adminer/"
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    /// ServiceManager.installPgAdmin4() → InstallationProgressSheet otomatik açılır
    private func installPgAdmin() {
        serviceManager.installPgAdmin4()
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch service.status {
        case .notInstalled:
            Button(loc.t("svc.install")) { serviceManager.installService(service) }
                .buttonStyle(.bordered).controlSize(.small).disabled(!Shell.isBrewInstalled)
        case .installed:
            // Runtime servis (Node.js / Python): çalışmıyor ama kurulu — mavi Kaldır butonu
            Button(action: { showUninstallAlert = true }) {
                Label(loc.t("svc.uninstall"), systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
            .help(String(format: loc.t("svc.uninstallHelp"), service.name))
        case .running:
            if service.canToggle {
                HStack(spacing: 4) {
                    Button(action: { serviceManager.stopService(service) }) { Image(systemName: "stop.fill") }.tint(.red)
                    Button(action: { serviceManager.restartService(service) }) { Image(systemName: "arrow.clockwise") }.tint(.blue)
                }.buttonStyle(.bordered).controlSize(.small)
            } else { CaptionText(loc.t("svc.installedState")) }
        case .stopped:
            if service.canToggle {
                // Brew servisleri: Başlat + Kaldır
                HStack(spacing: 4) {
                    Button(action: { serviceManager.startService(service) }) { Image(systemName: "play.fill") }
                        .tint(.green)
                    Button(action: { showUninstallAlert = true }) { Image(systemName: "trash") }
                        .tint(.red)
                }.buttonStyle(.bordered).controlSize(.small)
            }
        case .unknown: EmptyView()
        }
    }
}

// MARK: - Apache Port Config Sheet

struct ApachePortConfigView: View {
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var serviceManager: ServiceManager
    @Binding var isPresented: Bool

    @State private var httpPort: String = "80"
    @State private var httpsPort: String = "443"

    private var isValid: Bool {
        guard let h = Int(httpPort), let s = Int(httpsPort) else { return false }
        return h > 0 && h < 65536 && s > 0 && s < 65536 && h != s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "gearshape.fill").foregroundColor(.blue)
                Text(loc.t("svc.apachePorts")).font(.headline)
            }

            Text(loc.t("svc.apachePortNote"))
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            VStack(spacing: 12) {
                HStack {
                    Text(loc.t("svc.httpPort"))
                        .frame(width: 110, alignment: .trailing)
                    TextField("80", text: $httpPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Text(String(format: loc.t("svc.defaultVal"), "80")).font(.caption).foregroundColor(.secondary)
                }
                HStack {
                    Text(loc.t("svc.httpsPort"))
                        .frame(width: 110, alignment: .trailing)
                    TextField("443", text: $httpsPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Text(String(format: loc.t("svc.defaultVal"), "443")).font(.caption).foregroundColor(.secondary)
                }
            }

            if !isValid && !httpPort.isEmpty && !httpsPort.isEmpty {
                Text(loc.t("svc.portHint"))
                    .font(.caption).foregroundColor(.red)
            }

            Divider()

            HStack {
                Spacer()
                Button(loc.t("common.cancel")) { isPresented = false }
                Button(loc.t("svc.saveRestart")) {
                    serviceManager.updateApachePorts(http: Int(httpPort)!, https: Int(httpsPort)!)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            httpPort  = String(serviceManager.currentApacheHTTPPort())
            httpsPort = String(serviceManager.currentApacheHTTPSPort())
        }
    }
}

// MARK: - Nginx Port Config Sheet

struct NginxPortConfigView: View {
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var serviceManager: ServiceManager
    @Binding var isPresented: Bool

    @State private var httpPort: String  = "8080"
    @State private var httpsPort: String = "8443"

    private var isValid: Bool {
        guard let h = Int(httpPort), let s = Int(httpsPort) else { return false }
        return h > 0 && h < 65536 && s > 0 && s < 65536 && h != s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "gearshape.fill").foregroundColor(.green)
                Text(loc.t("svc.nginxPorts")).font(.headline)
            }

            Text(loc.t("svc.nginxPortNote"))
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            VStack(spacing: 12) {
                HStack {
                    Text(loc.t("svc.httpPort"))
                        .frame(width: 110, alignment: .trailing)
                    TextField("8080", text: $httpPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Text(String(format: loc.t("svc.defaultVal"), "8080")).font(.caption).foregroundColor(.secondary)
                }
                HStack {
                    Text(loc.t("svc.httpsPort"))
                        .frame(width: 110, alignment: .trailing)
                    TextField("8443", text: $httpsPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                    Text(String(format: loc.t("svc.defaultVal"), "8443")).font(.caption).foregroundColor(.secondary)
                }
            }

            if !isValid && !httpPort.isEmpty && !httpsPort.isEmpty {
                Text(loc.t("svc.portHint"))
                    .font(.caption).foregroundColor(.red)
            }

            Divider()

            HStack {
                Spacer()
                Button(loc.t("common.cancel")) { isPresented = false }
                Button(loc.t("svc.saveRestart")) {
                    serviceManager.updateNginxPorts(http: Int(httpPort)!, https: Int(httpsPort)!)
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            httpPort  = String(serviceManager.currentNginxHTTPPort())
            httpsPort = String(serviceManager.currentNginxHTTPSPort())
        }
    }
}

// MARK: - Installation Progress Sheet

/// Brew kurulum çıktısını gerçek zamanlı gösteren sheet.
struct InstallationProgressSheet: View {
    @EnvironmentObject var loc: Localizer
    @ObservedObject var serviceManager: ServiceManager
    @Binding var isPresented: Bool
    @State private var inputText: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                if serviceManager.isInstalling {
                    ProgressView().controlSize(.small)
                    Text(serviceManager.installationTitle)
                        .font(.headline)
                    Spacer()
                    Text(serviceManager.installationTitle.contains("Kaldır") ? "Kaldırılıyor..." : "Kuruluyor...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Image(systemName: serviceManager.installationLog.contains("✅") ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(serviceManager.installationLog.contains("✅") ? .green : .red)
                    Text(serviceManager.installationTitle)
                        .font(.headline)
                    Spacer()
                    Text(loc.t("common.done"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Button(loc.t("common.close")) { isPresented = false }
                    .buttonStyle(.bordered)
                    .disabled(serviceManager.isInstalling)
            }
            .padding()

            Divider()

            // Log çıktısı — otomatik kaydırmalı
            ScrollViewReader { proxy in
                ScrollView {
                    Text(serviceManager.installationLog.isEmpty ? " " : serviceManager.installationLog)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                        .id("install_log_bottom")
                }
                .background(Color(NSColor.textBackgroundColor))
                // Yeni satır geldiğinde otomatik aşağı kaydır
                .onChange(of: serviceManager.installationLog) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("install_log_bottom", anchor: .bottom)
                    }
                }
            }

            // Girdi çubuğu YALNIZCA gerçek bir istem beklenirken görünür. Eskiden kurulum
            // boyunca açıktı; bu, istem algılama bozukken (brew istemi `\r` ile bittiği için
            // hiç tetiklenmiyordu) elle yanıt verebilmek için konulmuş bir emniyet supabıydı.
            // Algılama artık uçtan uca testli olduğundan çubuk sadece gerektiğinde açılır ve
            // 10 sn'lik otomatik onay sayacı da onunla birlikte görünür.
            if serviceManager.isAwaitingInput {
                Divider()
                promptInputBar
            }
        }
        .frame(width: 720, height: 560)
        // Esc ile kapanırsa y/n istemi ERİŞİLMEZ olur ve sheet ancak bir SONRAKİ kurulumda
        // açılır (isInstalling false→true geçişi). Kurulum/istem boyunca kapatma kilitli.
        .interactiveDismissDisabled(serviceManager.isInstalling || serviceManager.isAwaitingInput)
    }

    // MARK: - Onay Girdi Çubuğu

    private var promptInputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard.fill")
                    .foregroundColor(serviceManager.isAwaitingInput ? .orange : .secondary)
                Text(loc.t(serviceManager.isAwaitingInput ? "svc.awaitingResponse" : "svc.inputHint"))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(serviceManager.isAwaitingInput ? .primary : .secondary)
                if serviceManager.autoConfirmCountdown > 0 {
                    Text(String(format: loc.t("svc.autoConfirmIn"), serviceManager.autoConfirmCountdown))
                        .font(.caption).foregroundColor(.orange)
                }
                Spacer()
            }
            if !serviceManager.currentPrompt.isEmpty {
                Text(serviceManager.currentPrompt)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                TextField("y / n", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .focused($inputFocused)
                    .onSubmit { submit() }
                Button(loc.t("svc.send")) { submit() }
                    .buttonStyle(.bordered)
                Divider().frame(height: 18)
                Button(loc.t("svc.yes")) { serviceManager.sendInstallInput("y"); inputText = "" }
                    .buttonStyle(.borderedProminent).tint(.green)
                Button(loc.t("svc.no")) { serviceManager.sendInstallInput("n"); inputText = "" }
                    .buttonStyle(.bordered).tint(.red)
                Spacer()
            }
        }
        .padding()
        .background(Color.orange.opacity(0.08))
        .onAppear { inputFocused = true }
    }

    private func submit() {
        let t = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        serviceManager.sendInstallInput(t.isEmpty ? "y" : t)
        inputText = ""
    }
}

// MARK: - MariaDB Config Sheet

struct MariaDBConfigView: View {
    @EnvironmentObject var loc: Localizer
    @Binding var isPresented: Bool
    @EnvironmentObject var serviceManager: ServiceManager
    @State private var isConfiguring = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(loc.t("svc.mariadbConfig"))
                    .font(.headline)
                Spacer()
                Button(loc.t("common.close")) { isPresented = false }
            }

            GroupBox(loc.t("svc.rootTcpAccess")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(loc.t("svc.mariadbConfigNote"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    HStack(spacing: 4) {
                        Text("Host:").font(.caption).foregroundColor(.secondary)
                        Text("127.0.0.1").font(.caption.monospaced())
                        Text("·").foregroundColor(.secondary)
                        Text(loc.t("svc.userLabel")).font(.caption).foregroundColor(.secondary)
                        Text("root").font(.caption.monospaced())
                        Text("·").foregroundColor(.secondary)
                        Text(loc.t("svc.passwordLabel")).font(.caption).foregroundColor(.secondary)
                        Text(loc.t("svc.empty")).font(.caption.monospaced())
                    }

                    Button(action: {
                        isConfiguring = true
                        Task {
                            await serviceManager.configureMariaDBRoot()
                            isConfiguring = false
                        }
                    }) {
                        if isConfiguring {
                            Label(loc.t("svc.configuring"), systemImage: "arrow.triangle.2.circlepath")
                        } else {
                            Label(loc.t("svc.configureRoot"), systemImage: "wrench.and.screwdriver")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(isConfiguring)
                }
                .padding(8)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

#Preview {
    ServicesTabView()
        .environmentObject(ServiceManager(consoleStore: ConsoleStore()))
        .environmentObject(TunnelManager(consoleStore: ConsoleStore()))
        .environmentObject(Localizer.shared)
}
