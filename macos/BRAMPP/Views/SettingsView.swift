import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var mcpServer: MCPServer
    @Environment(\.dismiss) private var dismiss

    // Genel
    @AppStorage("defaultPHPVersion")    private var defaultPHPVersion: String = "8.3"
    @AppStorage("autoStartServices")    private var autoStartServices: Bool   = false
    @State private var autoStartServiceIds: Set<String> = Set(AppSettings.load().autoStartServiceIds)
    @AppStorage("autoStopOnQuit")       private var autoStopOnQuit: Bool      = true
    @AppStorage("notificationsEnabled") private var notificationsEnabled: Bool = true
    @AppStorage("autoRefreshInterval")  private var autoRefreshInterval: Int  = 30
    @State private var pendingRefreshInterval: Int = 30

    // Konsol
    @AppStorage("showConsoleOutput")       private var showConsoleOutput: Bool       = true
    @AppStorage("showCommandsInConsole")   private var showCommandsInConsole: Bool   = true
    @AppStorage("showBrewOutputInConsole") private var showBrewOutputInConsole: Bool = false

    // Bağımlı Servisler
    @AppStorage("stopPHPOnWebServerStop")     private var stopPHPOnWebServerStop: Bool     = true
    @AppStorage("stopDomainsOnWebServerStop") private var stopDomainsOnWebServerStop: Bool = true
    @AppStorage("startPHPOnWebServerStart")   private var startPHPOnWebServerStart: Bool   = true

    // Kurulum Onay İstemi
    @AppStorage("installPromptAutoConfirm")        private var installPromptAutoConfirm: Bool = true
    @AppStorage("installPromptAutoConfirmSeconds") private var installPromptAutoConfirmSeconds: Int = 10

    // Debug
    @AppStorage("verboseLogging") private var verboseLogging: Bool = false
    @AppStorage("persistConsoleLog") private var persistConsoleLog: Bool = true

    // MCP Sunucusu — @AppStorage DEĞİL: bu ayarlar yalnızca settings.json'da tutulur
    // (UI dışında okuyan tek yer AppState açılış akışıdır, ayna anahtara gerek yok).
    @State private var mcpEnabled: Bool = AppSettings.load().mcpServerEnabled
    @State private var mcpPort: Int     = AppSettings.load().mcpServerPort
    /// Alan bazlı erişim düzeyleri — MCPServer her istekte settings.json'dan okur,
    /// değişiklik için sunucuyu yeniden başlatmak GEREKMEZ.
    @State private var mcpPerms: [MCPScope: MCPPermission] = [:]

    // Claude entegrasyonu — dosya sistemi durumu (.onAppear ve her işlemden sonra tazelenir)
    @State private var desktopConfigPresent = false
    @State private var desktopConfigured    = false
    @State private var codexConfigPresent   = false
    @State private var codexConfigured      = false
    @State private var skillInstalled       = false
    @State private var claudeBackupPath: String? = nil
    @State private var claudeError: String?      = nil
    /// Yapılandırma dosyalarına YAZILMIŞ uç nokta portları (giriş yoksa/okunamadıysa nil).
    /// Geçerli porttan farklıysa istemci bağlanamaz — satırda uyarı gösterilir.
    @State private var desktopWrittenPort: Int? = nil
    @State private var codexWrittenPort: Int?   = nil
    /// "Yapılandırma yeni portla güncellendi" bilgisi (yedek satırının yanında yeşil).
    @State private var claudeSyncNote: String?  = nil

    // Görünüm & Davranış
    @AppStorage("showMenuBarIcon")   private var showMenuBarIcon: Bool   = true
    @AppStorage("hideWindowOnClose") private var hideWindowOnClose: Bool = true
    // Girişte başlat — tek doğruluk kaynağı sistem (SMAppService durumu)
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    // Güncelleme denetimi — yalnızca kullanıcı isteyince çalışır. Açılışta otomatik
    // sorgu YAPILMAZ: uygulama her açılışta GitHub'a bağlanmamalı.
    @State private var updateState: UpdateChecker.Result?
    @State private var updateChecking = false
    @State private var customSitesPath: String = AppSettings.load().sitesPath

    @State private var showResetAlert = false
    // Güncelleme denetimi (brew outdated — yönetilen paketler)
    @State private var isCheckingUpdates = false
    @State private var outdatedPackages: [String]? = nil   // nil: henüz denetlenmedi

    var body: some View {
        TabView {
            genelTab
                .tabItem { Label(loc.t("set.tab.general"), systemImage: "gear") }
            servislerTab
                .tabItem { Label(loc.t("set.tab.services"), systemImage: "gearshape.2") }
            konsolTab
                .tabItem { Label(loc.t("set.tab.console"), systemImage: "terminal") }
            sslTab
                .tabItem { Label(loc.t("set.tab.ssl"), systemImage: "lock.shield") }
            mcpTab
                .tabItem { Label(loc.t("set.tab.mcp"), systemImage: "sparkles") }
            gelismisTab
                .tabItem { Label(loc.t("set.tab.advanced"), systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 560, height: 540)
        .onAppear {
            pendingRefreshInterval = autoRefreshInterval
            // Sıfırlama sonrası ya da pencere yeniden açılınca bayat kalmasın
            customSitesPath = AppSettings.load().sitesPath
            launchAtLogin = SMAppService.mainApp.status == .enabled
            autoStartServiceIds = Set(AppSettings.load().autoStartServiceIds)
            mcpEnabled = AppSettings.load().mcpServerEnabled
            mcpPort    = AppSettings.load().mcpServerPort
            loadMCPPermissions()
            refreshClaudeStatus()
        }
        .sheet(isPresented: $showBackupSheet) {
            BackupRestoreSheet(manager: appState.backupRestoreManager,
                               onImport: { appState.domainManager.loadDomains() })
        }
        .alert(loc.t("set.reset.title"), isPresented: $showResetAlert) {
            Button(loc.t("common.cancel"), role: .cancel) { }
            Button(loc.t("set.reset.button"), role: .destructive) { resetSettings() }
        } message: {
            Text(loc.t("set.reset.confirm"))
        }
    }

    // MARK: - Genel Sekmesi

    private var genelTab: some View {
        Form {
            // PHP
            Section {
                Picker(loc.t("set.php.default"), selection: $defaultPHPVersion) {
                    ForEach(PHPVersion.allCases) { v in
                        Text(v.displayName).tag(v.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: defaultPHPVersion) { _, v in
                    var s = AppSettings.load()
                    s.defaultPHPVersion = PHPVersion(rawValue: v) ?? .v83
                    s.save()
                    // PHP-FPM portunu gömen tüm web-sunucu config'lerini (localhost,
                    // phpMyAdmin, Adminer, nginx) yeni portla yenile — aksi halde bu araçlar
                    // eski FPM portunda kalıp 502/503 verir veya eski sürümde çalışır.
                    appState.serviceManager.applyDefaultPHPVersionChange(domainManager: appState.domainManager)
                }
            } header: {
                Label(loc.t("set.php.header"), systemImage: "server.rack")
            }

            // Otomatik Yenileme
            Section {
                HStack(spacing: 8) {
                    Text(loc.t("set.refresh.interval"))
                    Spacer()
                    TextField("", value: $pendingRefreshInterval, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                    Text(loc.t("common.seconds"))
                        .foregroundColor(.secondary)
                    Button(loc.t("common.apply")) {
                        applyRefreshInterval()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(pendingRefreshInterval == autoRefreshInterval)
                }
            } header: {
                Label(loc.t("set.refresh.header"), systemImage: "clock.arrow.2.circlepath")
            } footer: {
                Text(loc.t("set.refresh.note"))
                    .font(.caption).foregroundColor(.secondary)
            }

            // Dil
            Section {
                Picker(loc.t("settings.language.label"), selection: Binding(
                    get: { loc.language },
                    set: { loc.setLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Label(loc.t("settings.language.header"), systemImage: "globe")
            } footer: {
                Text(loc.t("settings.language.note"))
                    .font(.caption).foregroundColor(.secondary)
            }

            // Görünüm & Davranış
            Section {
                Toggle(loc.t("set.launchAtLogin"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else  { try SMAppService.mainApp.unregister() }
                        } catch {
                            // Sistem reddetti — gerçek durumu geri yükle (toggle yalan söylemesin)
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle(loc.t("set.menuIcon"), isOn: $showMenuBarIcon)
                    .onChange(of: showMenuBarIcon) { _, v in
                        var s = AppSettings.load(); s.showMenuBarIcon = v; s.save()
                    }
                Toggle(loc.t("set.hideOnClose"), isOn: $hideWindowOnClose)
                    .onChange(of: hideWindowOnClose) { _, v in
                        var s = AppSettings.load(); s.hideWindowOnClose = v; s.save()
                    }
            } header: {
                Label(loc.t("set.appearance.header"), systemImage: "macwindow")
            } footer: {
                Text(loc.t("set.appearance.note"))
                    .font(.caption).foregroundColor(.secondary)
            }

            // Yeni domainler için Sites klasörü
            Section {
                HStack {
                    Text(loc.t("set.site.newFolder"))
                    Spacer()
                    Text(customSitesPath)
                        .font(.caption).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Button(loc.t("common.change")) { pickSitesFolder() }
                        .controlSize(.small)
                    if customSitesPath != PathConfig.sites {
                        Button(loc.t("common.default")) {
                            customSitesPath = PathConfig.sites
                            var s = AppSettings.load(); s.sitesPath = PathConfig.sites; s.save()
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                Label(loc.t("set.site.header"), systemImage: "folder.badge.plus")
            } footer: {
                Text(loc.t("set.site.note"))
                    .font(.caption).foregroundColor(.secondary)
            }

            // Dizinler & Yapılandırma Dosyaları
            Section {
                configRow(label: loc.t("set.pathSites"), path: PathConfig.sites, isDir: true)
                configRow(label: loc.t("set.pathNginxConf"), path: PathConfig.nginxConf, isDir: false)
                configRow(label: "Nginx sites", path: PathConfig.nginxSitesAvailableDir, isDir: true)
                configRow(label: loc.t("set.pathApacheConf"), path: PathConfig.httpdConf, isDir: false)
                configRow(label: "Apache VirtualHosts", path: PathConfig.vhostsDir, isDir: true)
                configRow(label: String(format: loc.t("set.pathPhpIni"), defaultPHPVersion), path: PathConfig.phpIni(version: defaultPHPVersion), isDir: false)
                configRow(label: loc.t("set.pathHosts"), path: "/etc/hosts", isDir: false)
                configRow(label: loc.t("set.pathAppSupport"), path: PathConfig.appSupport, isDir: true)
            } header: {
                Label(loc.t("set.dirs.header"), systemImage: "folder.badge.gearshape")
            } footer: {
                Text(loc.t("set.dirs.note"))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Servisler Sekmesi

    private var servislerTab: some View {
        Form {
            // Servis Davranışı
            Section {
                Toggle(loc.t("set.autoStart"), isOn: $autoStartServices)
                    .onChange(of: autoStartServices) { _, v in
                        var s = AppSettings.load(); s.autoStartServices = v; s.save()
                    }
                if autoStartServices {
                    // Açılışta başlatılacak KURULU servisleri kullanıcı seçer
                    // .unknown (ilk tam kontrol bitmeden) DIŞLANIR: aksi halde kurulu OLMAYAN
                    // servisler de kısa süre listede belirir. Kesin kurulu durumlar: running/stopped.
                    let installed = appState.serviceManager.services.filter {
                        ($0.status == .running || $0.status == .stopped) && $0.canToggle
                    }
                    if installed.isEmpty {
                        Text(loc.t("set.autoStartNoServices"))
                            .font(.caption).foregroundColor(.secondary)
                    } else {
                        Text(loc.t("set.autoStartPick"))
                            .font(.caption).foregroundColor(.secondary)
                        ForEach(installed, id: \.id) { svc in
                            Toggle(isOn: Binding(
                                get: { autoStartServiceIds.contains(svc.id) },
                                set: { on in
                                    if on { autoStartServiceIds.insert(svc.id) } else { autoStartServiceIds.remove(svc.id) }
                                    var s = AppSettings.load(); s.autoStartServiceIds = autoStartServiceIds.sorted(); s.save()
                                }
                            )) { Text(svc.name) }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                Toggle(loc.t("set.autoStop"),  isOn: $autoStopOnQuit)
                    .onChange(of: autoStopOnQuit) { _, v in
                        var s = AppSettings.load(); s.autoStopOnQuit = v; s.save()
                    }
                Toggle(loc.t("set.notify"),    isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { _, enabled in
                        var s = AppSettings.load(); s.notificationsEnabled = enabled; s.save()
                        if enabled { ServiceManager.requestNotificationPermission() }
                    }
            } header: {
                Label(loc.t("set.svcBehavior.header"), systemImage: "play.circle")
            } footer: {
                Text(loc.t("set.svcBehavior.note"))
                    .font(.caption).foregroundColor(.secondary)
            }

            // Bağımlı Servisler
            Section {
                Toggle(loc.t("set.dep.startPHP"), isOn: $startPHPOnWebServerStart)
                    .onChange(of: startPHPOnWebServerStart) { _, v in
                        var s = AppSettings.load(); s.startPHPOnWebServerStart = v; s.save()
                    }
                Toggle(loc.t("set.dep.stopPHP"), isOn: $stopPHPOnWebServerStop)
                    .onChange(of: stopPHPOnWebServerStop) { _, v in
                        var s = AppSettings.load(); s.stopPHPOnWebServerStop = v; s.save()
                    }
                Toggle(loc.t("set.dep.stopDomains"), isOn: $stopDomainsOnWebServerStop)
                    .onChange(of: stopDomainsOnWebServerStop) { _, v in
                        var s = AppSettings.load(); s.stopDomainsOnWebServerStop = v; s.save()
                    }
            } header: {
                Label(loc.t("set.dep.header"), systemImage: "arrow.triangle.branch")
            } footer: {
                Text(loc.t("set.autoStartNote"))
                    .font(.caption).foregroundColor(.secondary)
            }

            // Kurulum Onay İstemi
            Section {
                Toggle(loc.t("set.confirm.auto"), isOn: $installPromptAutoConfirm)
                    .onChange(of: installPromptAutoConfirm) { _, v in
                        var s = AppSettings.load(); s.installPromptAutoConfirm = v; s.save()
                    }
                if installPromptAutoConfirm {
                    HStack(spacing: 8) {
                        Text(loc.t("set.confirm.wait"))
                        Spacer()
                        Stepper(value: $installPromptAutoConfirmSeconds, in: 3...60, step: 1) {
                            Text("\(installPromptAutoConfirmSeconds) sn").monospacedDigit()
                        }
                        .onChange(of: installPromptAutoConfirmSeconds) { _, v in
                            var s = AppSettings.load(); s.installPromptAutoConfirmSeconds = v; s.save()
                        }
                    }
                }
            } header: {
                Label(loc.t("set.confirm.header"), systemImage: "keyboard")
            } footer: {
                Text(loc.t("set.autoConfirmNote"))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Konsol Sekmesi

    private var konsolTab: some View {
        Form {
            // Görünüm
            Section {
                Toggle(loc.t("set.showConsole"), isOn: $showConsoleOutput)
                    .onChange(of: showConsoleOutput) { _, v in
                        // Kardeş toggle'larla aynı desen: JSON deposu da senkron kalsın
                        // (reset() iki depoyu birlikte sıfırlar — tutarlılık şart)
                        var s = AppSettings.load(); s.showConsoleOutput = v; s.save()
                    }
            } header: {
                Label(loc.t("set.view.header"), systemImage: "sidebar.right")
            } footer: {
                Text(loc.t("set.showConsole.note"))
                    .font(.caption).foregroundColor(.secondary)
            }

            // Kayıt Detayı
            Section {
                Toggle(loc.t("set.showCmd"), isOn: $showCommandsInConsole)
                    .onChange(of: showCommandsInConsole) { _, v in saveConsoleSetting(\.showCommandsInConsole, v) }
                Toggle(loc.t("set.showBrewOut"), isOn: $showBrewOutputInConsole)
                    .onChange(of: showBrewOutputInConsole) { _, v in saveConsoleSetting(\.showBrewOutputInConsole, v) }
            } header: {
                Label(loc.t("set.svcCmd.header"), systemImage: "text.alignleft")
            } footer: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(loc.t("set.svcCmd.note1"))
                    Text(loc.t("set.svcCmd.note2"))
                }
                .font(.caption).foregroundColor(.secondary)
            }

            // Gelişmiş (Debug) Kayıt
            Section {
                Toggle(loc.t("set.verbose.toggle"), isOn: $verboseLogging)
                    .onChange(of: verboseLogging) { _, v in saveConsoleSetting(\.verboseLogging, v) }
                Toggle(loc.t("set.persistLog"), isOn: $persistConsoleLog)
                    .onChange(of: persistConsoleLog) { _, v in
                        saveConsoleSetting(\.persistConsoleLog, v)
                        // Canlı store da güncellenmeli: aksi halde ayar ancak
                        // uygulama yeniden açılınca etkili olurdu.
                        appState.consoleStore.persistToFile = v
                    }
                Text(loc.t("set.persistLogDesc"))
                    .font(.caption).foregroundColor(.secondary)
            } header: {
                Label(loc.t("set.verbose.header"), systemImage: "ant.circle")
            } footer: {
                Text(loc.t("set.verbose.note"))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - SSL Sekmesi

    private var sslTab: some View {
        SSLSettingsView()
    }

    // MARK: - MCP Sekmesi

    private var mcpTab: some View {
        Form {
            // MCP Sunucusu — yapay zekâ araçları için yerel uç nokta (yalnızca 127.0.0.1)
            Section {
                Toggle(loc.t("set.mcp.enable"), isOn: $mcpEnabled)
                    .onChange(of: mcpEnabled) { _, on in applyMCPEnabled(on) }

                HStack(spacing: 8) {
                    Text(loc.t("set.mcp.port"))
                    Spacer()
                    // grouping(.never): port "8.765" gibi binlik ayraçla gösterilmesin
                    TextField("", value: $mcpPort, format: .number.grouping(.never))
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { applyMCPPort() }
                }
                Text(loc.t("set.mcp.portHint"))
                    .font(.caption).foregroundColor(.secondary)

                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundColor(mcpServer.isRunning ? .green : .gray)
                    Text(mcpServer.isRunning ? loc.t("set.mcp.running") : loc.t("set.mcp.stopped"))
                        .font(.caption)
                        .foregroundColor(mcpServer.isRunning ? .green : .secondary)
                }

                HStack(spacing: 6) {
                    Text(mcpEndpoint)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(loc.t("set.mcp.copyUrl")) { copyMCPEndpoint() }
                        .controlSize(.small)
                    // Uç nokta tarayıcıda GET ile açıldığında kurulum yönergeleri sayfası döner
                    Button(loc.t("set.mcp.openBrowser")) { openMCPInBrowser() }
                        .controlSize(.small)
                        .help(loc.t("set.mcp.openBrowserHelp"))
                        .disabled(!mcpServer.isRunning)
                }

                if let error = mcpServer.lastError {
                    Text(String(format: loc.t("set.mcp.startError"), error))
                        .font(.caption).foregroundColor(.red)
                }
            } header: {
                Label(loc.t("set.mcp.title"), systemImage: "sparkles")
            } footer: {
                Text(loc.t("set.mcp.intro")).font(.caption).foregroundColor(.secondary)
            }

            // Erişim İzinleri — araç listesi bu düzeylere göre süzülür
            Section {
                ForEach(MCPScope.allCases) { scope in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(scope.displayName, systemImage: scope.icon)
                                .font(.subheadline)
                            Text(loc.t("set.mcp.scope.\(scope.rawValue)Desc"))
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { mcpPerms[scope] ?? .write },
                            set: { level in applyMCPPermission(level, to: scope) }
                        )) {
                            ForEach(MCPPermission.allCases) { level in
                                Text(level.displayName).tag(level)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 150)
                    }
                }
            } header: {
                Label(loc.t("set.mcp.permissions"), systemImage: "hand.raised")
            } footer: {
                Text(loc.t("set.mcp.permNote"))
                    .font(.caption).foregroundColor(.secondary)
            }

            // Etkin araçlar — izinler değişince canlı güncellenir, böylece kullanıcı
            // hangi yeteneği açıp kapattığını rakamla ve adla görür.
            Section {
                Text(String(format: loc.t("set.mcp.activeTools"), permittedToolCount))
                    .font(.subheadline).fontWeight(.medium)
                Text(permittedToolList)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Label(loc.t("set.mcp.toolsTitle"), systemImage: "wrench.and.screwdriver")
            } footer: {
                // Bu uyarı olmadan bölüm yanıltıyor: sayı izni değiştirir değiştirmez
                // artıyor ama bağlı istemcinin listesi bağlantı anında dondu. Sunucu
                // durumsuz HTTP olduğu için ona haber verecek bir kanal yok.
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc.t("set.mcp.reconnectNote"))
                    Text(loc.t("set.mcp.security"))
                }
                .font(.caption).foregroundColor(.secondary)
            }

            // Claude Entegrasyonu — yapılandırma dosyası ve beceri dosyası
            Section {
                claudeRow(
                    title: loc.t("set.mcp.desktopTitle"),
                    isOn: desktopConfigured,
                    isMismatched: desktopPortMismatch,
                    status: desktopConfigPresent
                        ? (desktopConfigured
                            ? (desktopPortMismatch ? portMismatchText(desktopWrittenPort) : loc.t("set.mcp.desktopOn"))
                            : loc.t("set.mcp.desktopOff"))
                        : loc.t("set.mcp.desktopMissing"),
                    buttonLabel: desktopConfigured ? loc.t("set.mcp.desktopRemove") : loc.t("set.mcp.desktopAdd"),
                    isDisabled: !desktopConfigPresent,
                    action: toggleClaudeDesktop
                )

                // ChatGPT Codex — Streamable HTTP'yi doğrudan desteklediğinden köprü yok.
                claudeRow(
                    title: "ChatGPT Codex",                     // marka adı — çevrilmez
                    isOn: codexConfigured,
                    isMismatched: codexPortMismatch,
                    status: codexConfigPresent
                        ? (codexConfigured
                            ? (codexPortMismatch
                                ? portMismatchText(codexWrittenPort)
                                : loc.t("set.mcp.codexOn"))
                            : loc.t("set.mcp.codexOff"))
                        : loc.t("set.mcp.codexMissing"),
                    buttonLabel: codexConfigured ? loc.t("set.mcp.desktopRemove") : loc.t("set.mcp.desktopAdd"),
                    isDisabled: false,
                    action: toggleCodex
                )

                claudeRow(
                    title: loc.t("set.mcp.skillTitle"),
                    isOn: skillInstalled,
                    isMismatched: false,
                    status: skillInstalled ? loc.t("set.mcp.skillOn") : loc.t("set.mcp.skillOff"),
                    buttonLabel: skillInstalled ? loc.t("set.mcp.skillRemove") : loc.t("set.mcp.skillAdd"),
                    isDisabled: false,
                    action: toggleClaudeSkill
                )

                // Port uyumsuzluğu: yazılmış yapılandırma başka bir portu gösteriyor —
                // istemci bağlanamaz. Tek dokunuşla geçerli portla yeniden yazılır.
                if !mismatchedClientNames.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundColor(.orange)
                        Text(String(format: loc.t("set.mcp.portMismatchFix"),
                                    mismatchedClientNames.joined(separator: ", "),
                                    endpointText(activeMCPPort)))
                            .font(.caption).foregroundColor(.orange)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(loc.t("common.apply")) { fixClaudeConfigPorts() }
                            .controlSize(.small)
                    }
                }

                Text(loc.t("set.mcp.skillNote"))
                    .font(.caption).foregroundColor(.secondary)

                if let note = claudeSyncNote {
                    Text(note)
                        .font(.caption).foregroundColor(.green)
                        .lineLimit(1).truncationMode(.middle)
                }
                if let backup = claudeBackupPath {
                    HStack(spacing: 6) {
                        Text(String(format: loc.t("set.mcp.backupDone"), (backup as NSString).lastPathComponent))
                            .font(.caption).foregroundColor(.green)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(loc.t("set.mcp.revealBackup")) {
                            NSWorkspace.shared.selectFile(backup, inFileViewerRootedAtPath: "")
                        }
                        .controlSize(.small)
                    }
                }
                if let error = claudeError {
                    Text(error).font(.caption).foregroundColor(.red)
                }
            } header: {
                Label(loc.t("set.mcp.claudeSection"), systemImage: "person.crop.square.badge.camera")
            } footer: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(loc.t("set.mcp.desktopNote"))
                    Text(loc.t("set.mcp.backupNote"))
                    Text(loc.t("set.mcp.restartNote"))
                }
                .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Claude Desktop / Beceri satırı — durum göstergesi + tek eylem butonu.
    /// `isMismatched`: giriş VAR ama başka bir portu gösteriyor → yeşil değil turuncu uyarı.
    private func claudeRow(title: String, isOn: Bool, isMismatched: Bool, status: String,
                           buttonLabel: String, isDisabled: Bool,
                           action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isMismatched ? "exclamationmark.triangle.fill"
                                           : (isOn ? "checkmark.circle.fill" : "circle"))
                .foregroundColor(isMismatched ? .orange : (isOn ? .green : .secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).fontWeight(.medium)
                Text(status).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button(buttonLabel, action: action)
                .controlSize(.small)
                .disabled(isDisabled)
        }
    }

    // MARK: - Gelişmiş Sekmesi

    @State private var showBackupSheet = false

    private var gelismisTab: some View {
        Form {
            // Yedekleme / Geri Yükleme / Dışa-İçe Aktarma (eskiden ana araç çubuğundaydı)
            Section {
                Button {
                    appState.backupRestoreManager.exportDomains()
                } label: { Label(loc.t("cv.exportDomains"), systemImage: "square.and.arrow.up") }
                Button {
                    appState.backupRestoreManager.importDomains { appState.domainManager.loadDomains() }
                } label: { Label(loc.t("cv.importDomains"), systemImage: "square.and.arrow.down") }
                Button {
                    showBackupSheet = true
                } label: { Label(loc.t("backup.title"), systemImage: "externaldrive") }
            } header: {
                Label(loc.t("backup.title"), systemImage: "externaldrive.badge.timemachine")
            } footer: {
                Text(loc.t("backup.settingsNote")).font(.caption).foregroundColor(.secondary)
            }

            // Sistem Bilgisi
            Section {
                LabeledContent(loc.t("set.brew.location")) {
                    Text(Shell.brewPrefix)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent(loc.t("set.brew.status")) {
                    HStack(spacing: 6) {
                        Image(systemName: Shell.isBrewInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(Shell.isBrewInstalled ? .green : .red)
                        Text(Shell.isBrewInstalled ? loc.t("set.brew.installed") : loc.t("set.brew.notInstalled"))
                    }
                    .font(.caption)
                    .foregroundColor(Shell.isBrewInstalled ? .green : .red)
                }
                LabeledContent(loc.t("set.wizard.label")) {
                    HStack(spacing: 6) {
                        Image(systemName: appState.isSetupCompleted ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(appState.isSetupCompleted ? .green : .red)
                        Text(appState.isSetupCompleted ? loc.t("set.wizard.done") : loc.t("set.wizard.notDone"))
                    }
                    .font(.caption)
                    .foregroundColor(appState.isSetupCompleted ? .green : .red)
                }
            } header: {
                Label(loc.t("set.system.header"), systemImage: "cpu")
            }

            // Uygulama Bilgisi
            Section {
                LabeledContent(loc.t("set.about.version")) {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1")
                        .font(.caption).foregroundColor(.secondary)
                }
                updateRow
                LabeledContent(loc.t("set.about.domains")) {
                    Text(String(format: loc.t("set.about.domainsCount"), appState.domainManager.domains.count))
                        .font(.caption).foregroundColor(.secondary)
                }
                LabeledContent("macOS:") {
                    Text(ProcessInfo.processInfo.operatingSystemVersionString)
                        .font(.caption).foregroundColor(.secondary)
                }
            } header: {
                Label(loc.t("set.about.header"), systemImage: "info.circle")
            }

            // Güncelleme Denetimi (brew outdated — yönetilen paketler)
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loc.t("set.updates.check")).font(.subheadline)
                        Text(loc.t("set.updates.desc"))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(isCheckingUpdates ? loc.t("set.updates.checking") : loc.t("set.updates.check.btn")) { checkUpdates() }
                        .disabled(isCheckingUpdates || !Shell.isBrewInstalled)
                }
                if let pkgs = outdatedPackages {
                    if pkgs.isEmpty {
                        Label(loc.t("set.updates.upToDate"), systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundColor(.green)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(String(format: loc.t("set.updates.available"), pkgs.count), systemImage: "arrow.up.circle")
                                .font(.caption).foregroundColor(.orange)
                            ForEach(pkgs, id: \.self) { pkg in
                                Text("• \(pkg)").font(.caption2.monospaced()).foregroundColor(.secondary)
                            }
                            Text(loc.t("set.updates.howto"))
                                .font(.caption2).foregroundColor(.secondary).textSelection(.enabled)
                        }
                    }
                }
            } header: {
                Label(loc.t("set.updates"), systemImage: "arrow.triangle.2.circlepath")
            }

            // Sıfırlama
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loc.t("set.reset.all"))
                            .font(.subheadline)
                        Text(loc.t("set.reset.confirm"))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(loc.t("set.reset.button")) { showResetAlert = true }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.small)
                }
            } header: {
                Label(loc.t("set.reset.title"), systemImage: "arrow.counterclockwise")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Yardımcılar

    /// Yeni domainler için özel Sites klasörü seç (NSOpenPanel)
    private func pickSitesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: customSitesPath)
        panel.prompt = loc.t("common.select")
        panel.message = loc.t("set.pickSitesMsg")
        if panel.runModal() == .OK, let url = panel.url {
            customSitesPath = url.path
            var s = AppSettings.load(); s.sitesPath = url.path; s.save()
        }
    }

    /// Yönetilen Homebrew paketlerinden hangileri güncellenebilir? (`brew outdated`)
    /// Uygulamanın kendi self-update kanalı olmadığından, dev-ortamı için asıl anlamlı
    /// güncelleme denetimi budur: PHP/servis paketlerinin güncelliği.
    private func checkUpdates() {
        isCheckingUpdates = true
        Task {
            // --formula: yalnızca formüller (cask'ları hariç tut); hızlı, ağ gerektirir
            let r = await Shell.brewBashAsync("\(Shell.brewBin) outdated --formula --quiet 2>/dev/null")
            let pkgs = r.output
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            outdatedPackages = pkgs
            isCheckingUpdates = false
        }
    }

    // MARK: - MCP Sunucusu

    /// Kopyalanabilir/paylaşılabilir uç nokta adresi. Sunucu ÇALIŞIYORSA gerçekte
    /// dinlenen port gösterilir — alanda kaydedilmemiş/geçersiz bir değer varken
    /// kopyalanan URL çalışmayan bir adres olurdu.
    private var mcpEndpoint: String { endpointText(activeMCPPort) }

    /// İstemci yapılandırmalarına yazılacak port: sunucu ÇALIŞIYORSA gerçekte dinlenen
    /// port, aksi halde alandaki/kaydedilmiş port.
    private var activeMCPPort: Int { mcpServer.isRunning ? mcpServer.port : mcpPort }

    private func endpointText(_ port: Int) -> String { "http://127.0.0.1:\(port)/mcp" }

    private func applyMCPEnabled(_ enabled: Bool) {
        // Port alanı Enter'a basılmadan bırakılmış olabilir → önce kırp ve kaydet,
        // sunucu her zaman kaydedilmiş ve geçerli portla başlasın.
        let clamped = max(1024, min(65535, mcpPort))
        mcpPort = clamped
        var s = AppSettings.load()
        s.mcpServerEnabled = enabled
        s.mcpServerPort    = clamped
        s.save()
        if enabled {
            mcpServer.start(port: clamped)
        } else {
            mcpServer.stop()
        }
        // Kırpma portu değiştirmiş olabilir; yazılmış yapılandırmalar bayat kalmasın.
        syncClaudeConfigs(port: clamped)
    }

    /// Port commit'te kaydedilir; sunucu çalışıyorsa yeni portla yeniden başlatılır.
    private func applyMCPPort() {
        let clamped = max(1024, min(65535, mcpPort))
        mcpPort = clamped
        var s = AppSettings.load()
        s.mcpServerPort = clamped
        s.save()
        // Kurulmuş istemci yapılandırmaları eski portu gösterirdi → yeni portla tazele.
        syncClaudeConfigs(port: clamped)
        guard mcpServer.isRunning else { return }
        mcpServer.stop()
        mcpServer.start(port: clamped)
    }

    private func copyMCPEndpoint() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(mcpEndpoint, forType: .string)
    }

    private func openMCPInBrowser() {
        guard let url = URL(string: mcpEndpoint) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - MCP Erişim İzinleri

    private func loadMCPPermissions() {
        let s = AppSettings.load()
        mcpPerms = Dictionary(uniqueKeysWithValues: MCPScope.allCases.map { ($0, $0.permission(in: s)) })
    }

    /// Sunucu ayarı her istekte okuduğundan yeniden başlatma gerekmez.
    private func applyMCPPermission(_ level: MCPPermission, to scope: MCPScope) {
        mcpPerms[scope] = level
        var s = AppSettings.load()
        scope.apply(level, to: &s)
        s.save()
    }

    /// Geçerli izinlerle yapay zekâ istemcisinin GÖRECEĞİ araçlar. `mcpPerms`
    /// okunduğu için izin değişince bu iki değer de yeniden hesaplanır.
    private var permittedToolNames: [String] {
        _ = mcpPerms   // izin değişiminde yeniden çizim için bağımlılık
        return MCPServer.permittedToolNames()
    }
    private var permittedToolCount: Int { permittedToolNames.count }
    private var permittedToolList: String {
        permittedToolNames.isEmpty ? "—" : permittedToolNames.joined(separator: ", ")
    }

    // MARK: - Claude Entegrasyonu

    private func refreshClaudeStatus() {
        desktopConfigPresent = ClaudeIntegration.desktopConfigExists()
        desktopConfigured    = ClaudeIntegration.isDesktopConfigured()
        codexConfigPresent   = ClaudeIntegration.codexConfigExists()
        codexConfigured      = ClaudeIntegration.isCodexConfigured()
        skillInstalled       = ClaudeIntegration.isSkillInstalled()
        desktopWrittenPort   = desktopConfigured ? writtenDesktopPort() : nil
        codexWrittenPort     = codexConfigured   ? writtenCodexPort()   : nil
    }

    // MARK: - Port eşitleme

    /// Giriş VAR ama yazılı port geçerli porttan farklı mı? Port okunamadıysa (nil)
    /// uyarı gösterilmez — yanlış alarm vermektense sessiz kalınır.
    private var desktopPortMismatch: Bool {
        guard desktopConfigured, let written = desktopWrittenPort else { return false }
        return written != activeMCPPort
    }
    private var codexPortMismatch: Bool {
        guard codexConfigured, let written = codexWrittenPort else { return false }
        return written != activeMCPPort
    }

    /// Uyumsuz istemcilerin adları (uyarı satırında listelenir)
    private var mismatchedClientNames: [String] {
        var names: [String] = []
        if desktopPortMismatch { names.append(loc.t("set.mcp.desktopTitle")) }
        if codexPortMismatch   { names.append("ChatGPT Codex") }
        return names
    }

    /// Yazılı adres ile geçerli adresin karşılaştırması ("… ≠ …").
    private func portMismatchText(_ written: Int?) -> String {
        guard let written else { return "" }
        return String(format: loc.t("set.mcp.portMismatch"),
                      endpointText(written), endpointText(activeMCPPort))
    }

    /// Port değiştiğinde KURULU istemci yapılandırmalarını yeni portla yeniden yazar.
    /// Yazılı portu zaten doğru olan istemciye dokunulmaz (gereksiz yedek üretilmesin).
    /// Kurulu olmayan istemci hiç eklenmez — kullanıcının kurmadığı entegrasyon açılmaz.
    private func syncClaudeConfigs(port: Int) {
        let fixDesktop = ClaudeIntegration.isDesktopConfigured() && writtenDesktopPort() != port
        let fixCodex   = ClaudeIntegration.isCodexConfigured()   && writtenCodexPort()   != port
        guard fixDesktop || fixCodex else { return }

        var updated:  [String] = []
        var backups:  [String] = []
        var failures: [String] = []

        if fixDesktop {
            switch ClaudeIntegration.addToDesktop(port: port) {
            case .success(let backup):
                updated.append(loc.t("set.mcp.desktopTitle"))
                if !backup.isEmpty { backups.append(backup) }
            case .failure(let error):
                failures.append(error.localizedDescription)
            }
        }
        if fixCodex {
            switch ClaudeIntegration.addToCodex(port: port) {
            case .success(let backup):
                updated.append("ChatGPT Codex")
                if !backup.isEmpty { backups.append(backup) }
            case .failure(let error):
                failures.append(error.localizedDescription)
            }
        }

        claudeSyncNote = updated.isEmpty ? nil
            : String(format: loc.t("set.mcp.portSynced"),
                     updated.joined(separator: ", "), endpointText(port))
        claudeBackupPath = backups.last
        claudeError      = failures.isEmpty
            ? nil
            : String(format: loc.t("set.mcp.writeFailed"), failures.joined(separator: " · "))
        refreshClaudeStatus()
    }

    /// Uyarı satırındaki "Uygula" — port alanı commit edilmemiş olabilir, önce kaydet.
    private func fixClaudeConfigPorts() {
        let clamped = max(1024, min(65535, mcpPort))
        mcpPort = clamped
        var s = AppSettings.load()
        if s.mcpServerPort != clamped { s.mcpServerPort = clamped; s.save() }
        // Sunucu çalışıyorsa yazılacak doğru adres GERÇEK dinlenen porttur.
        syncClaudeConfigs(port: mcpServer.isRunning ? mcpServer.port : clamped)
    }

    // GEÇİCİ: ClaudeIntegration yalnızca "giriş var mı" sorusunu yanıtlıyor; yazılı PORTU
    // döndüren bir API'si yok ve o dosya başka bir ajanın sorumluluğunda. Uyumsuzluğu
    // görebilmek için uç nokta portu burada okunuyor — ClaudeIntegration'a
    // desktopConfiguredPort()/codexConfiguredPort() eklenince bu üç yardımcı silinmeli.

    /// claude_desktop_config.json → mcpServers.brampp.args içindeki uç nokta portu
    private func writtenDesktopPort() -> Int? {
        guard let data = FileHelper.readData(ClaudeIntegration.desktopConfigPath),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any],
              let entry = servers["brampp"] as? [String: Any],
              let args = entry["args"] as? [String]
        else { return nil }
        return args.compactMap(endpointPort).first
    }

    /// ~/.codex/config.toml → [mcp_servers.brampp] tablosundaki url portu
    private func writtenCodexPort() -> Int? {
        guard let text = FileHelper.readString(ClaudeIntegration.codexConfigPath) else { return nil }
        var inTable = false
        for line in text.components(separatedBy: "\n") {
            let compact = line.filter { !$0.isWhitespace }
            if compact.hasPrefix("[") {
                inTable = compact == "[mcp_servers.brampp]"
                continue
            }
            if inTable, let port = endpointPort(line) { return port }
        }
        return nil
    }

    /// "…http://127.0.0.1:8765/mcp…" → 8765
    private func endpointPort(_ text: String) -> Int? {
        guard let range = text.range(of: "127.0.0.1:") else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    private func toggleCodex() {
        let port = activeMCPPort
        claudeSyncNote = nil
        let result = codexConfigured
            ? ClaudeIntegration.removeFromCodex()
            : ClaudeIntegration.addToCodex(port: port)
        switch result {
        case .success(let backupPath):
            // Codex kurulu değilken dosya sıfırdan oluşur; o durumda yedek yoktur.
            claudeBackupPath = backupPath.isEmpty ? nil : backupPath
            claudeError      = nil
        case .failure(let error):
            claudeBackupPath = nil
            claudeError      = String(format: loc.t("set.mcp.writeFailed"), error.localizedDescription)
        }
        refreshClaudeStatus()
    }

    private func toggleClaudeDesktop() {
        // Sunucu çalışıyorsa GERÇEK port yazılsın — alanda kaydedilmemiş bir değer
        // varken yapılandırmaya çalışmayan bir adres girmiş oluruz.
        let port = activeMCPPort
        claudeSyncNote = nil
        let result = desktopConfigured
            ? ClaudeIntegration.removeFromDesktop()
            : ClaudeIntegration.addToDesktop(port: port)
        switch result {
        case .success(let backupPath):
            claudeBackupPath = backupPath
            claudeError      = nil
        case .failure(let error):
            claudeBackupPath = nil
            claudeError      = String(format: loc.t("set.mcp.writeFailed"), error.localizedDescription)
        }
        refreshClaudeStatus()
    }

    private func toggleClaudeSkill() {
        // Beceri metnindeki uç nokta GERÇEK portu göstermeli — aksi halde ajan, port
        // değiştirilmişken bağlantı sorununda kullanıcıya yanlış portu söyler.
        let result = skillInstalled
            ? ClaudeIntegration.removeSkill()
            : ClaudeIntegration.installSkill(port: activeMCPPort)
        // Beceri dosyası yedeklenmez (uygulamadan üretilir) — önceki yedek mesajı da bayat kalmasın
        claudeBackupPath = nil
        claudeSyncNote   = nil
        switch result {
        case .success:
            claudeError = nil
        case .failure(let error):
            claudeError = String(format: loc.t("set.mcp.writeFailed"), error.localizedDescription)
        }
        refreshClaudeStatus()
    }

    private func applyRefreshInterval() {
        let clamped = max(10, min(300, pendingRefreshInterval))
        pendingRefreshInterval = clamped
        autoRefreshInterval    = clamped
        appState.serviceManager.startAutoRefresh(interval: TimeInterval(clamped))
        var s = AppSettings.load()
        s.autoRefreshInterval = clamped
        s.save()
    }

    private func saveConsoleSetting<T>(_ keyPath: WritableKeyPath<AppSettings, T>, _ value: T) {
        var s = AppSettings.load()
        s[keyPath: keyPath] = value
        s.save()
    }

    /// Dizin veya yapılandırma dosyası satırı — yol + aç butonu
    @ViewBuilder
    private func configRow(label: String, path: String, isDir: Bool) -> some View {
        let exists = FileManager.default.fileExists(atPath: path)
        LabeledContent(label + ":") {
            HStack(spacing: 6) {
                Text(path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(exists ? .secondary : .red)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button(action: { openPath(path, isDir: isDir) }) {
                    Image(systemName: isDir ? "folder" : "pencil")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help(isDir ? loc.t("common.openFinder") : loc.t("common.edit"))
                .disabled(!exists)
            }
        }
    }

    private func openPath(_ path: String, isDir: Bool) {
        if isDir {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    private func resetSettings() {
        AppSettings.reset()
        // Sıfırlama mcpServerEnabled'ı false yapar ama ÇALIŞAN dinleyiciyi kapatmaz —
        // arayüz "kapalı" gösterirken soket oturum boyunca açık kalırdı.
        appState.mcpServer.stop()
        mcpEnabled = false
        mcpPort    = AppSettings.load().mcpServerPort
        appState.isSetupCompleted = false
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.windows.first(where: {
                $0.title.contains("Ayarlar") || $0.identifier?.rawValue.contains("Settings") == true
            })?.close()
        }
    }
}

// MARK: - SSL Ayarları

struct SSLSettingsView: View {
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var appState: AppState
    @StateObject private var mkcertManager = MkcertManager()
    @State private var showInstallLog = false

    var body: some View {
        Form {
            Section {
                if !Shell.isBrewInstalled {
                    statusRow(icon: "exclamationmark.triangle.fill", color: .orange,
                              text: loc.t("set.ssl.brewMissing"),
                              subtitle: loc.t("set.ssl.brewMissingSub"))
                } else {
                    statusRow(
                        icon:  mkcertManager.isMkcertInstalled ? "checkmark.circle.fill" : "xmark.circle.fill",
                        color: mkcertManager.isMkcertInstalled ? .green : .red,
                        text:  mkcertManager.isChecking ? loc.t("wiz.checkingShort") :
                               (mkcertManager.isMkcertInstalled ? loc.t("set.ssl.mkcertOk") : loc.t("set.ssl.mkcertMissing")),
                        subtitle: mkcertManager.isMkcertInstalled ? nil : loc.t("set.ssl.mkcertMissingSub")
                    )

                    if mkcertManager.isMkcertInstalled {
                        statusRow(
                            icon:  mkcertManager.isCAInstalled ? "checkmark.circle.fill" : "xmark.circle.fill",
                            color: mkcertManager.isCAInstalled ? .green : .red,
                            text:  mkcertManager.isCAInstalled ? loc.t("set.ssl.caOk") : loc.t("set.ssl.caMissing"),
                            subtitle: mkcertManager.isCAInstalled ? nil : loc.t("set.ssl.caMissingSub")
                        )

                        if mkcertManager.isCAInstalled {
                            statusRow(
                                icon:  mkcertManager.isCATrusted ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                                color: mkcertManager.isCATrusted ? .green : .orange,
                                text:  mkcertManager.isCATrusted ? loc.t("set.ssl.trusted") : loc.t("set.ssl.untrusted"),
                                subtitle: mkcertManager.isCATrusted ? nil : loc.t("set.ssl.untrustedSub")
                            )
                        }
                    }
                }
            } header: {
                Label(loc.t("common.status"), systemImage: "shield.checkerboard")
            } footer: {
                if Shell.isBrewInstalled {
                    HStack {
                        Spacer()
                        Button(action: { Task { await mkcertManager.checkStatus() } }) {
                            Label(mkcertManager.isChecking ? loc.t("wiz.checkingShort") : loc.t("common.refresh"),
                                  systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(mkcertManager.isChecking)
                    }
                }
            }

            if Shell.isBrewInstalled {
                Section {
                    if !mkcertManager.isMkcertInstalled {
                        actionRow(
                            icon: "arrow.down.circle", title: loc.t("set.ssl.installMkcert"),
                            subtitle: loc.t("set.ssl.installMkcertSub"),
                            buttonLabel: loc.t("svc.install"), buttonColor: .blue,
                            isLoading: mkcertManager.isInstalling
                        ) {
                            Task { _ = await mkcertManager.installMkcert { m, t in appState.domainManager.log(m, type: t) } }
                        }
                    } else if !mkcertManager.isCAInstalled || !mkcertManager.isCATrusted {
                        actionRow(
                            icon: "lock.fill", title: loc.t("set.ssl.installCA"),
                            subtitle: loc.t("set.ssl.installCASub"),
                            buttonLabel: loc.t("svc.install"), buttonColor: .blue,
                            isLoading: mkcertManager.isInstalling
                        ) {
                            Task { _ = await mkcertManager.installCA { m, t in appState.domainManager.log(m, type: t) } }
                        }
                    } else {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.seal.fill").foregroundColor(.green).font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loc.t("set.sslAllReady")).font(.subheadline).fontWeight(.medium)
                                Text(loc.t("set.sslManageHint"))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }
                } header: {
                    Label(loc.t("set.ssl.setup"), systemImage: "wrench")
                }

                if !mkcertManager.caRootPath.isEmpty {
                    Section {
                        LabeledContent("CA Root:") {
                            Text(mkcertManager.caRootPath)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                        HStack {
                            Spacer()
                            Button(action: { mkcertManager.openCAFolder() }) {
                                Label(loc.t("common.openFinder"), systemImage: "folder")
                            }.controlSize(.small)
                        }
                    } header: {
                        Label(loc.t("set.ssl.certDir"), systemImage: "folder.badge.gearshape")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: mkcertManager.isInstalling) { _, installing in if installing { showInstallLog = true } }
        .sheet(isPresented: $showInstallLog) {
            MkcertInstallProgressSheet(manager: mkcertManager, isPresented: $showInstallLog)
        }
    }

    private func statusRow(icon: String, color: Color, text: String, subtitle: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundColor(color).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.subheadline).fontWeight(.medium)
                if let s = subtitle { Text(s).font(.caption).foregroundColor(.secondary) }
            }
            Spacer()
        }
    }

    private func actionRow(icon: String, title: String, subtitle: String,
                           buttonLabel: String, buttonColor: Color, isLoading: Bool,
                           action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundColor(buttonColor).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).fontWeight(.medium)
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if isLoading {
                ProgressView().scaleEffect(0.7)
            } else {
                Button(buttonLabel, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(buttonColor)
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Güncelleme satırı

extension SettingsView {
    /// "Güncellemeleri denetle" satırı. Sonuç aynı satırda gösterilir; yeni sürüm
    /// varsa sürüm sayfasına götüren bir düğme belirir. İndirme uygulamada YAPILMAZ —
    /// kendi kendini güncelleyen bir mekanizma imzalı/noter onaylı dağıtım zincirini
    /// atlatma riski taşır, indirme kullanıcının tarayıcısında kalır.
    @ViewBuilder
    var updateRow: some View {
        LabeledContent(loc.t("set.update.check")) {
            HStack(spacing: 8) {
                switch updateState {
                case .upToDate:
                    Label(loc.t("set.update.upToDate"), systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundColor(.green).labelStyle(.titleAndIcon)
                case .updateAvailable(_, let latest, let url):
                    Label(String(format: loc.t("set.update.available"), latest),
                          systemImage: "arrow.down.circle.fill")
                        .font(.caption).foregroundColor(.orange).labelStyle(.titleAndIcon)
                    Button(loc.t("set.update.open")) { NSWorkspace.shared.open(url) }
                        .buttonStyle(.link).font(.caption)
                case .failed:
                    Text(loc.t("set.update.failed"))
                        .font(.caption).foregroundColor(.secondary)
                case nil:
                    EmptyView()
                }

                Button(updateChecking ? loc.t("set.update.checking") : loc.t("set.update.check")) {
                    updateChecking = true
                    Task {
                        let r = await UpdateChecker.check()
                        updateState = r
                        updateChecking = false
                    }
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(updateChecking)
            }
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
        .environmentObject(Localizer.shared)
        .environmentObject(MCPServer())
}
