import SwiftUI
import Combine
import AppKit
import Foundation

@main
struct BRAMPPApp: App {
    // NSApp'i güvenli şekilde yapılandırmak için AppDelegate kullanılır.
    // init() içinde NSApp henüz nil olabileceğinden doğrudan çağrı crash'e yol açar.
    @NSApplicationDelegateAdaptor(BRAMPPAppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    // Menü çubuğu ikonunu göster/gizle — MenuBarExtra(isInserted:) bu bağa bağlı.
    // @AppStorage: Ayarlar'daki toggle ile canlı senkron (yeniden başlatma gerekmez).
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    @StateObject private var localizer = Localizer.shared

    /// Ana pencere sahnesinin kimliği — pencere hiç kalmadığında `openWindow(id:)`
    /// ile yeniden oluşturabilmek için gerekir (AppKit'ten WindowGroup penceresi yaratılamaz).
    static let mainWindowID = "main"

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            RootView()
                .environmentObject(appState)
                .environmentObject(localizer)
                .environmentObject(appState.mcpServer)
                .frame(minWidth: 900, minHeight: 650)
                .background(WindowHideInterceptor(delegate: appDelegate))
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }

            // ── Uygulama menüsü — Türkçe ──────────────────────────────────────
            CommandGroup(replacing: .appInfo) {
                Button {
                    var opts: [NSApplication.AboutPanelOptionKey: Any] = [:]
                    opts[.applicationName]    = "BRAMPP"
                    // Sürüm bundle'dan okunur — MARKETING_VERSION ile otomatik senkron
                    opts[.applicationVersion] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1"
                    opts[.credits]            = NSAttributedString(
                        string: localizer.t("menu.credits"),
                        attributes: [
                            .font:            NSFont.systemFont(ofSize: 11),
                            .foregroundColor: NSColor.secondaryLabelColor
                        ]
                    )
                    NSApp.orderFrontStandardAboutPanel(options: opts)
                } label: {
                    Label(localizer.t("menu.about"), systemImage: "info.circle")
                }
            }

            CommandGroup(replacing: .appVisibility) {
                Button {
                    NSApp.hide(nil)
                } label: {
                    Label(localizer.t("menu.hide"), systemImage: "eye.slash")
                }
                .keyboardShortcut("h")

                Button {
                    NSApp.hideOtherApplications(nil)
                } label: {
                    Label(localizer.t("menu.hideOthers"), systemImage: "rectangle.stack")
                }
                .keyboardShortcut("h", modifiers: [.command, .option])

                Button {
                    NSApp.unhideAllApplications(nil)
                } label: {
                    Label(localizer.t("menu.showAll"), systemImage: "eye")
                }
                Divider()
            }

            // macOS sistem "Services" alt menüsünü kaldır (tercüme edilemez)
            CommandGroup(replacing: .systemServices) { }

            // NOT: Edit menüsü (Geri Al / Kes / Kopyala / Yapıştır / Tümünü Seç)
            // BIRAKILDI — uygulamada birçok metin alanı var (domain adı, port, ENV,
            // veritabanı adı, ayarlar). Kaldırılırsa ⌘C/⌘V/⌘Z kısayolları çalışmaz.
            // Menü başlıkları localizeMenus() ile Türkçeleştirilir.

            CommandGroup(replacing: .appTermination) {
                Button {
                    // "Kapanırken servisleri durdur" AYARINA uyulur:
                    //   açık  → animasyonlu durdurup çık (stopAllAndQuit)
                    //   kapalı → servislere dokunmadan çık
                    if AppSettings.load().autoStopOnQuit {
                        appState.serviceManager.stopAllAndQuit()
                    } else {
                        appDelegate.realQuit(stopServices: false)
                    }
                } label: {
                    Label(localizer.t("menu.quitApp"), systemImage: "power")
                }
                .keyboardShortcut("q")

                // Servisleri durdurmadan çıkmak isteyenler için ayrı seçenek
                Button {
                    appDelegate.realQuit(stopServices: false)
                } label: {
                    Label(localizer.t("menu.quitNoStop"), systemImage: "power.dotted")
                }
                .keyboardShortcut("q", modifiers: [.command, .option])
            }
            // Sistem Yardım menüsü: var olmayan Help Book'u açmaya çalışmak yerine
            // ("Help isn't available for BRAMPP" hatası) uygulama içi Yardım'ı açar.
            CommandGroup(replacing: .help) {
                Button(localizer.t("menu.helpItem")) {
                    NotificationCenter.default.post(name: .showHelpSheet, object: nil)
                }
                .keyboardShortcut("?", modifiers: [.command, .shift])
            }
            // ─────────────────────────────────────────────────────────────────

            CommandMenu(localizer.t("menu.services")) {
                Button(localizer.t("menu.startAll")) { appState.serviceManager.startAll() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!appState.canManageServices)
                Button(localizer.t("menu.stopAll")) { appState.serviceManager.stopAll() }
                    .keyboardShortcut("x", modifiers: [.command, .shift])
                    .disabled(!appState.canManageServices)
                Divider()
                Button(localizer.t("menu.restartApache")) { appState.serviceManager.restartApache() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(!appState.canManageServices)
                Divider()
                Button(localizer.t("common.refresh")) {
                    appState.serviceManager.refreshStatus()
                    appState.domainManager.refreshStatus()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!appState.isSetupCompleted)
                Button(localizer.t("menu.refreshLight")) {
                    Task { await appState.serviceManager.refreshStatusLight() }
                }
                .keyboardShortcut("r", modifiers: [.command, .option, .shift])
                .disabled(!appState.isSetupCompleted)
            }

            CommandMenu(localizer.t("menu.domain")) {
                Button(localizer.t("menu.newDomain")) {
                    NotificationCenter.default.post(name: .showAddDomainSheet, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(!appState.canManageServices)
            }
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarServicesView()
                .environmentObject(appState)
                .environmentObject(appState.serviceManager)
                // Etkin tünel sayısı menüde gösteriliyor; @Published değişimini
                // görebilmek için manager'ın kendisi gözlenmeli.
                .environmentObject(appState.tunnelManager)
                .environmentObject(localizer)
        } label: {
            MenuBarLabelView(appState: appState)
        }
        // .window stili: SwiftUI HStack/VStack vs. doğru çalışır.
        // .menu (varsayılan) stili native menu item olarak render eder → HStack bozulur.
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(localizer)
                .environmentObject(appState.mcpServer)
        }
    }
}

// MARK: - AppState

@MainActor
class AppState: ObservableObject {
    @Published var isSetupCompleted: Bool = false

    let consoleStore: ConsoleStore
    let serviceManager: ServiceManager
    let domainManager: DomainManager
    let phpExtensionManager: PHPExtensionManager
    let backupRestoreManager: BackupRestoreManager
    /// Cloudflare Quick Tunnel yönetimi — hiçbir tünel kalıcı değildir
    let tunnelManager: TunnelManager
    /// Uygulama içi MCP sunucusu — manager'lar bootstrapManagers()'ta enjekte edilir
    let mcpServer = MCPServer()

    private var cancellables = Set<AnyCancellable>()

    var canManageServices: Bool { isSetupCompleted && Shell.isBrewInstalled }

    var runningServiceCount: Int {
        serviceManager.services.filter { $0.status == .running }.count
    }

    var stoppedServiceCount: Int {
        serviceManager.services.filter { $0.canToggle && $0.status == .stopped }.count
    }

    var menuBarSymbolName: String {
        if !isSetupCompleted || !Shell.isBrewInstalled {
            return "exclamationmark.triangle.fill"
        }
        // Çalışan servis varsa dolu katman, yoksa çerçeve
        return runningServiceCount > 0 ? "square.stack.3d.up.fill" : "square.stack.3d.up"
    }

    init() {
        // UserDefaults'u (SettingsView'in okuduğu) settings.json'la eşitle — @AppStorage
        // toggle'ları gerçek davranışla (AppSettings.load) tutarlı görünsün.
        AppSettings.hydrateUserDefaults()

        let store = ConsoleStore()
        self.consoleStore = store
        self.serviceManager = ServiceManager(consoleStore: store)
        self.domainManager = DomainManager(consoleStore: store)
        self.phpExtensionManager = PHPExtensionManager(consoleStore: store)
        self.backupRestoreManager = BackupRestoreManager(consoleStore: store)
        self.tunnelManager = TunnelManager(consoleStore: store)

        serviceManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Verbose logging: her bashAsync çağrısı öncesinde komutu konsola yaz
        // Ayarlar → Konsol → "Tüm komutları kaydet" ile kontrol edilir
        Shell.verboseLogCallback = { [weak store] cmd in
            guard AppSettings.load().verboseLogging else { return }
            DispatchQueue.main.async {
                store?.log("$ \(cmd)", type: .command)
            }
        }

        // Dosya işlem hataları (yazılamadı/silinemedi/kopyalanamadı) konsola düşsün —
        // aksi halde yalnızca Xcode konsoluna print edilir ve kullanıcı hiç görmez.
        FileHelper.errorLogger = { [weak store] msg in
            DispatchQueue.main.async {
                store?.log(msg, type: .error)
            }
        }

        // ServiceManager olaylarını dinle — cross-manager orchestrasyon burada yapılır
        serviceManager.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .lightRefreshCompleted:
                    // ServiceManager nc-tabanlı port kontrolünü zaten yaptı.
                    // Apache (port 80) ve Nginx (port 8080) statüsünü doğrudan oku
                    // → DomainManager'da tekrar pgrep çalışmasın.
                    let apache = self.serviceManager.services.first { $0.id == "httpd" }?.status == .running
                    let nginx  = self.serviceManager.services.first { $0.id == "nginx"  }?.status == .running
                    self.domainManager.refreshStatus(apacheRunning: apache, nginxRunning: nginx)

                case .allWebServersStopped:
                    let backendDomains = self.domainManager.domains.filter {
                        [Platform.nodejs, .python, .dotnet].contains($0.platform)
                    }
                    guard !backendDomains.isEmpty else { return }
                    Task {
                        for domain in backendDomains {
                            await NativeProcessManager.stop(domain: domain)
                        }
                        self.serviceManager.log(key: "log.app.backendProcessesStopped", type: .info)
                        self.domainManager.refreshStatus()
                    }

                case .webServerStarted:
                    // Web sunucusu başladı — domainlerin kullandığı PHP-FPM'leri başlat (ayara bağlı)
                    let settings = AppSettings.load()
                    guard settings.startPHPOnWebServerStart else { return }
                    var versions = Set(self.domainManager.domains.compactMap { d -> PHPVersion? in
                        d.platform == .php ? (d.phpVersion ?? settings.defaultPHPVersion) : nil
                    })
                    if versions.isEmpty { versions = [settings.defaultPHPVersion] }
                    for v in versions {
                        if let svc = self.serviceManager.services.first(where: { $0.id == "php@\(v.rawValue)" }),
                           svc.status == .stopped, !svc.isBusy {
                            self.serviceManager.log(key: "log.app.startingForWebServer",
                                                    args: [svc.name], type: .info)
                            self.serviceManager.startService(svc)
                        }
                    }
                }
            }
            .store(in: &cancellables)

        guard Shell.isBrewInstalled else {
            isSetupCompleted = false
            print("⚠️ Homebrew kurulu değil — Kurulum sihirbazı gösterilecek")
            return
        }

        isSetupCompleted = AppSettings.load().firstSetupCompleted

        if isSetupCompleted {
            bootstrapManagers()
        }
    }

    func onSetupCompleted() {
        isSetupCompleted = true
        guard Shell.isBrewInstalled else {
            consoleStore.log(key: "log.app.brewMissing", type: .error)
            return
        }
        bootstrapManagers()
    }

    /// Kurulum tamamlandığında / uygulama açılışında ortak başlangıç akışı.
    private func bootstrapManagers() {
        // "Son çalışan servisler" listesi refreshStatus BAŞLAMADAN önce okunmalı:
        // açılışta tüm servisler kapalı olduğundan ilk tam kontrol listeye BOŞ yazar —
        // liste sonradan okunursa .lastRunning modu hiçbir zaman servis başlatamazdı.

        // 7 günden eski konsol dosyalarını temizle (Core/ConsoleLogFile.swift)
        ConsoleLogFile.pruneOldFiles()
        // Önceki oturumdan kalmış tünel süreci varsa öldür: uygulama çökerse
        // cloudflared yaşamaya devam eder ve site açık kalırdı.
        TunnelManager.killAllSynchronously()

        domainManager.loadDomains()
        // domains.json'a BRAMPP dışından yazılırsa (MCP aracı, CLI, elle düzenleme)
        // arayüz kendiliğinden tazelensin — dosya izleyicisi dış yazımı algılar.
        domainManager.startWatchingExternalChanges()
        // Varsayılan localhost vhost'u garanti et — Host eşleşmeyen isteklerin
        // (localhost/phpmyadmin gibi) domain vhost'larına düşmesini önler
        domainManager.ensureApacheDefaultVHost()
        serviceManager.refreshStatus()
        domainManager.refreshStatus()
        phpExtensionManager.loadExtensions()

        // Dock "Servisleri Durdur ve Kapat" yolunun da çıkış korumasını uygulaması için
        // hazırlık kancasını bağla (auto-refresh durdur + persist kilitle).
        BRAMPPAppDelegate.shared?.quitPreparation = { [weak serviceManager] in
            serviceManager?.prepareForQuit()
        }
        // Pencere kapatma davranışı (hideWindowOnClose=false) servisleri durdurarak
        // çıkabilsin diye AppState referansını bağla.
        BRAMPPAppDelegate.shared?.appStateRef = self

        // Domain eklen/başlatılırken bağlı web sunucusu durmuşsa otomatik başlatılsın diye
        // DomainManager'ı ServiceManager'a bağla (tek kaynak: servis başlatma ServiceManager'da).
        domainManager.ensureServiceRunning = { [weak serviceManager] id in
            await serviceManager?.ensureWebServerRunning(id) ?? false
        }

        let settings = AppSettings.load()
        let interval = TimeInterval(settings.autoRefreshInterval)
        serviceManager.startAutoRefresh(interval: interval)

        // MCP sunucusu: canlı manager'ları bağla; ayar açıksa yerel uç noktayı yayınla.
        // (Araçlar doğrudan bu manager'ları çağırdığından değişiklikler arayüze anında yansır.)
        mcpServer.configure(serviceManager: serviceManager,
                            domainManager:  domainManager,
                            consoleStore:   consoleStore,
                            tunnelManager:  tunnelManager)
        if settings.mcpServerEnabled {
            mcpServer.start(port: settings.mcpServerPort)
        }

        if settings.notificationsEnabled {
            ServiceManager.requestNotificationPermission()
        }

        if settings.autoStartServices, !settings.autoStartServiceIds.isEmpty {
            Task { [serviceManager] in
                // Sabit gecikme yerine ilk TAM durum kontrolünü bekle: aksi halde tüm
                // servisler hâlâ .unknown iken startSelectedServices (yalnızca .stopped
                // başlatır) hiçbir şey yapmaz. En fazla ~8sn poll, sonra yine de dene.
                for _ in 0..<40 where !serviceManager.hasRunFullCheck {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                serviceManager.startSelectedServices(ids: settings.autoStartServiceIds)
            }
        }
    }
}

extension Notification.Name {
    static let showAddDomainSheet = Notification.Name("showAddDomainSheet")
    static let showHelpSheet      = Notification.Name("showHelpSheet")
}

// MARK: - MenuBarLabelView

/// Menü çubuğu ikonu. Ayrı bir View tipi olmasının İKİ nedeni var:
///   1. `App` bir View değildir — `@Environment(\.openWindow)` yalnızca View içinde okunur.
///   2. Bu etiket uygulama AÇILIŞINDA render edilir; popover'ın açılmasını beklemez.
///
/// `openWindow` köprüsü buradan kurulur. Yalnızca MenuBarServicesView'de kurulsaydı
/// (popover ilk açıldığında), hiç pencere kalmamış bir durumda Dock'tan yeniden açma
/// pencereyi geri getiremezdi: AppKit'ten WindowGroup penceresi yaratılamıyor ve köprü
/// henüz kurulmamış oluyordu. Menü çubuğu ÖĞESİ bu açığa girmez — kendi `openWindow`
/// eylemini `presentMainWindow(createIfMissing:)`'e doğrudan geçirir.
struct MenuBarLabelView: View {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            if appState.isSetupCompleted && Shell.isBrewInstalled {
                // Uygulama logosu (rack) — şablon olarak, menü çubuğu rengine uyar
                Image("MenuBarIcon")
                    .renderingMode(.template)
            } else {
                Image(systemName: appState.menuBarSymbolName)
                    .renderingMode(.template)
                    .imageScale(.medium)
            }

            if appState.isSetupCompleted && appState.runningServiceCount > 0 {
                Text("\(appState.runningServiceCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
        }
        .onAppear {
            BRAMPPAppDelegate.shared?.createMainWindowAction = {
                openWindow(id: BRAMPPApp.mainWindowID)
            }
        }
    }
}

// MARK: - WindowHideInterceptor

/// Ana pencere kapatıldığında gizler (quit değil).
/// AppDelegate referansı üzerinden mainWindow'u kaydeder.
struct WindowHideInterceptor: NSViewRepresentable {
    let delegate: BRAMPPAppDelegate

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let win = view.window else { return }
            win.delegate = context.coordinator
            delegate.mainWindow = win          // ana pencereyi AppDelegate'e kaydet
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if nsView.window?.delegate == nil {
            DispatchQueue.main.async {
                guard let win = nsView.window else { return }
                win.delegate = context.coordinator
                delegate.mainWindow = win
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, NSWindowDelegate {
        /// Kırmızı X davranışı AYARA bağlıdır (Ayarlar → Genel → "Pencere kapatınca gizle"):
        ///   • true (varsayılan) → kapatma değil gizleme; dock ikonu da gizlenir,
        ///     uygulama menü çubuğundan yaşamaya devam eder
        ///   • false → gerçek çıkış; "Çıkışta servisleri durdur" ayarına da uyulur
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            let settings = AppSettings.load()
            guard settings.hideWindowOnClose else {
                if settings.autoStopOnQuit, let appState = BRAMPPAppDelegate.shared?.appStateRef {
                    appState.serviceManager.stopAllAndQuit()
                } else {
                    BRAMPPAppDelegate.shared?.realQuit(stopServices: false) ?? NSApp.terminate(nil)
                }
                return false   // çıkışı yukarıdaki akış yönetir
            }
            sender.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
            return false
        }
    }
}

// MARK: - AppDelegate

class BRAMPPAppDelegate: NSObject, NSApplicationDelegate {
    /// Menü bar gibi adaptör dışı bağlamlardan erişim için paylaşılan referans.
    /// `NSApp.delegate as? BRAMPPAppDelegate` ÇALIŞMAZ — SwiftUI adaptörü kendi
    /// iç delegate'ini atar; cast sessizce nil döner ve Çıkış butonu işlevsiz kalır.
    static private(set) var shared: BRAMPPAppDelegate?

    /// Ana içerik penceresi — WindowHideInterceptor tarafından atanır
    weak var mainWindow: NSWindow?

    /// SwiftUI `openWindow(id:)` köprüsü — MenuBarServicesView tarafından kurulur.
    /// AppKit'ten WindowGroup penceresi yaratılamadığı için son çare olarak kullanılır.
    var createMainWindowAction: (() -> Void)?

    /// Ana pencereyi kesin biçimde öne getirir. Menü çubuğu ve Dock/reopen yollarının
    /// ORTAK tek doğru yolu — ikisi ayrı ayrı yazılınca biri sessizce bozuluyordu.
    ///
    /// Sunumun bir sonraki run-loop turuna ERTELENMESİ zorunludur:
    ///   • MenuBarExtra(.window) popover'ı tıklama anında KEY penceredir ve buton
    ///     eylemi döndükten SONRA kapanır; aynı turda makeKeyAndOrderFront çağrılırsa
    ///     popover'ın kapanışı key durumunu geri alır, pencere arkada kalır.
    ///   • .accessory → .regular geçişi WindowServer'a ancak bir tur sonra işler;
    ///     aynı turdaki activate isteği yutulur.
    func presentMainWindow(createIfMissing: (() -> Void)? = nil) {
        NSApp.setActivationPolicy(.regular)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // ⌘H ile gizlenmişse orderFront tek başına pencereyi göstermez.
            if NSApp.isHidden { NSApp.unhide(nil) }
            NSApp.activate(ignoringOtherApps: true)

            if let win = self.mainWindow {
                win.setIsVisible(true)
                win.makeKeyAndOrderFront(nil)
                return
            }

            // Yedek: içerik penceresini ara. NSPanel'ler (MenuBarExtra popover'ı,
            // Ayarlar paneli) ve sheet'ler dışlanır — yoksa yanlış pencere öne gelir.
            if let win = NSApp.windows.first(where: {
                !($0 is NSPanel) && !$0.isSheet && $0.canBecomeMain &&
                !($0.identifier?.rawValue ?? "").contains("Settings")
            }) {
                self.mainWindow = win
                win.setIsVisible(true)
                win.makeKeyAndOrderFront(nil)
                return
            }

            // Hiç içerik penceresi yok → WindowGroup sahnesini yeniden oluştur.
            (createIfMissing ?? self.createMainWindowAction)?()
        }
    }

    /// true olduğunda applicationShouldTerminate gerçek çıkışa izin verir.
    /// Dock / Cmd+Q gibi sistem kapatma isteklerinde false kalır → sadece gizler.
    private var realQuitRequested = false

    /// Çıkış öncesi hazırlık kancası — App bootstrap'ta ServiceManager.prepareForQuit'e
    /// bağlanır. Servisleri durduran çıkış yolları (özellikle Dock menüsü) bunu çağırmalı
    /// ki auto-refresh timer'ı "son çalışan servisler" listesini ezmesin.
    var quitPreparation: (() -> Void)?

    /// AppState'e zayıf referans — pencere kapatma davranışı (hideWindowOnClose=false +
    /// autoStopOnQuit) servisleri durdurarak çıkabilmek için ServiceManager'a erişir.
    weak var appStateRef: AppState?

    /// Dil değişimini dinleyen abonelik(ler) — menü çubuğunu canlı yeniden çevirmek için.
    private var menuCancellables = Set<AnyCancellable>()

    /// Sistem kapanışı (Oturumu Kapat / Yeniden Başlat / Bilgisayarı Kapat) sürüyor mu?
    /// applicationShouldTerminate bu durumda çıkışı ASLA iptal etmemeli.
    private var systemIsPoweringOff = false

    override init() {
        super.init()
        BRAMPPAppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // SwiftUI menüleri gecikmeli oluşturur — kısa gecikme + yeniden deneme ile mevcut dile çevir.
        applyMenuLanguage(code: Localizer.shared.code)
        for delay in [0.3, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.applyMenuLanguage(code: Localizer.shared.code)
            }
        }
        // Dil değişince menü çubuğunu anında yeniden çevir (TR ↔ EN çift yönlü).
        // $language ilk abonelikte mevcut değeri de yayınlar → menü hemen senkron olur.
        Localizer.shared.$language
            .receive(on: DispatchQueue.main)
            .sink { [weak self] lang in
                self?.applyMenuLanguage(code: lang.effectiveCode)
            }
            .store(in: &menuCancellables)

        // Bir menü açılmadan hemen önce yeniden uygula: AppKit'in kendisi bazı öğeleri
        // (ör. tam ekrana geçince View menüsündeki "Tam Ekrandan Çık") sistem dilinde
        // yeniden yazabiliyor. Menü açılışında tekrar çevirerek bunların dile sadık
        // kalmasını garanti ederiz. İşlem ucuz ve idempotenttir.
        NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyMenuLanguage(code: Localizer.shared.code)
            }
            .store(in: &menuCancellables)

        // Sistem kapanışı başladığında işaretle — applicationShouldTerminate çıkışı
        // iptal etmemeli (aksi halde oturum kapatma/yeniden başlatma bloklanır).
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.willPowerOffNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.systemIsPoweringOff = true }
            .store(in: &menuCancellables)
    }

    /// macOS menü çubuğunu verilen dile ("tr"/"en") çevirir.
    ///
    /// ÇİFT YÖNLÜDÜR: bir öğenin başlığı hangi dilde olursa olsun (TR ya da EN) hedef
    /// dile getirir. Böylece çalışma anında TR ↔ EN geçişi her iki yönde de çalışır —
    /// eski tek-yönlü `localizeMenus()` yalnızca EN→TR yapıyordu ve EN'e dönüşü bozuyordu.
    ///
    /// Sistem öğeleri (Pencere, Düzenle, Kes/Kopyala…) satır içi çiftlerde; uygulamaya
    /// özel öğeler (Hakkında, Servisler menüsü…) katalogdan okunur (tek kaynak → `.commands`
    /// ile aynı metinler). Uygulamaya özel öğeleri SwiftUI de `loc.t` ile üretir; buradaki
    /// yeniden yazım idempotenttir (aynı hedef dil → aynı sonuç) ve dil değişiminde SwiftUI
    /// menüyü yeniden kurmasa bile başlıkların güncellenmesini garanti eder.
    private func applyMenuLanguage(code: String) {
        guard let mainMenu = NSApp.mainMenu else { return }
        let wantTR = (code == "tr")

        // (İngilizce, Türkçe) kavram çiftleri — sistem menüsü öğeleri
        var pairs: [(en: String, tr: String)] = [
            // Üst düzey menü başlıkları
            ("Window", "Pencere"), ("Help", "Yardım"), ("View", "Görünüm"),
            ("Edit", "Düzenle"), ("File", "Dosya"),
            // Uygulama menüsü (sistem) öğeleri
            ("Settings…", "Ayarlar…"),
            ("Minimize", "Küçült"), ("Zoom", "Yakınlaştır"),
            ("Bring All to Front", "Tümünü Öne Getir"),
            ("Enter Full Screen", "Tam Ekrana Geç"),
            ("Exit Full Screen", "Tam Ekrandan Çık"),
            ("Close", "Kapat"),
            // Düzenle menüsü
            ("Undo", "Geri Al"), ("Redo", "Yinele"), ("Cut", "Kes"),
            ("Copy", "Kopyala"), ("Paste", "Yapıştır"),
            ("Paste and Match Style", "Yapıştır ve Stili Eşle"),
            ("Delete", "Sil"), ("Select All", "Tümünü Seç"),
            ("Start Dictation…", "Dikteyi Başlat…"),
            ("Emoji & Symbols", "Emoji ve Semboller"),
            // Pencere döşeme
            ("Move Window to Left Side of Screen", "Pencereyi Ekranın Soluna Taşı"),
            ("Move Window to Right Side of Screen", "Pencereyi Ekranın Sağına Taşı"),
            ("Replace Tiled Window", "Döşeli Pencereyi Değiştir"),
            ("Remove Window from Set", "Pencereyi Kümeden Çıkar"),
            ("Fill", "Doldur"), ("Center", "Ortala"),
            ("Tile Window to Left of Screen", "Pencereyi Ekranın Soluna Döşe"),
            ("Tile Window to Right of Screen", "Pencereyi Ekranın Sağına Döşe")
        ]
        // Uygulamaya özel öğeler — katalogdan (tek kaynak) her iki dil de okunur
        let appKeys = ["menu.about", "menu.hide", "menu.hideOthers", "menu.showAll",
                       "menu.quitApp", "menu.quitNoStop", "menu.services", "menu.startAll",
                       "menu.stopAll", "menu.restartApache", "common.refresh",
                       "menu.refreshLight", "menu.domain", "menu.newDomain"]
        for key in appKeys {
            if let en = L10n.catalog[key]?["en"], let tr = L10n.catalog[key]?["tr"] {
                pairs.append((en, tr))
            }
        }

        // Her iki dil varyantından da hedef dile eşleme kur (çift yönlü + idempotent)
        var map: [String: String] = [:]
        for pair in pairs {
            let target = wantTR ? pair.tr : pair.en
            map[pair.en] = target
            map[pair.tr] = target
        }
        // "Settings..." (üç ayrı nokta) — bazı sürümlerde ellipsis yerine kullanılır
        map["Settings..."] = wantTR ? "Ayarlar…" : "Settings…"

        func apply(_ menu: NSMenu) {
            if let t = map[menu.title] { menu.title = t }
            for item in menu.items {
                if let t = map[item.title] { item.title = t }
                if let sub = item.submenu { apply(sub) }
            }
        }
        for item in mainMenu.items {
            if let t = map[item.title] { item.title = t }
            if let sub = item.submenu { apply(sub) }
        }
    }

    // MARK: Gerçek çıkış (menubar, ⌘Q, dock özel menüsü)

    func realQuit(stopServices: Bool = false) {
        realQuitRequested = true
        guard stopServices else {
            NSApp.terminate(nil)
            return
        }
        // Çıkış öncesi hazırlık: auto-refresh timer'ını durdur + persist'i kilitle.
        // Bu yol (Dock "Servisleri Durdur ve Kapat") stopAllAndQuit'i atladığından,
        // koruma burada açıkça uygulanmalı — aksi halde brew-stop penceresinde tetiklenen
        // bir yenileme "son çalışan servisler" listesini boş durumla ezerdi.
        quitPreparation?()
        // Servisleri durdurmak uzun sürebilir (MariaDB shutdown vb.) —
        // ana thread'i kilitlemeden arka planda durdur, sonra çık.
        DispatchQueue.global(qos: .userInitiated).async {
            // `--all` DEĞİL: yalnızca BRAMPP'in yönettiği çalışan servisler durdurulur —
            // kullanıcının kendi başlattığı diğer brew servisleri etkilenmemeli.
            let ids = ServiceManager.readLastRunningIds()
            if !ids.isEmpty {
                _ = Shell.bash("\(PathConfig.brew) services stop \(ids.joined(separator: " ")) 2>/dev/null")
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: Dock sağ tıklama menüsü

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        let stopQuit = NSMenuItem(
            title: Localizer.shared.t("menu.dockStopQuit"),
            action: #selector(dockStopAndQuit),
            keyEquivalent: ""
        )
        stopQuit.target = self
        menu.addItem(stopQuit)

        return menu
    }

    @objc private func dockStopAndQuit() {
        realQuit(stopServices: true)
    }

    // MARK: Quit intercept — sistem "Kapat" → gizle

    /// Çıkış isteği, oturum kapatma / yeniden başlatma / bilgisayarı kapatma kaynaklı mı?
    /// macOS bu durumda 'quit' AppleEvent'ine bir "neden" (`kAEQuitReason`) parametresi ekler.
    private var isSystemQuitEvent: Bool {
        guard let ev = NSAppleEventManager.shared().currentAppleEvent,
              ev.eventClass == AEEventClass(kCoreEventClass),
              ev.eventID    == AEEventID(kAEQuitApplication) else { return false }
        return ev.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Sistem kapanışı ASLA engellenmez. Aksi halde kullanıcı Oturumu Kapat / Yeniden
        // Başlat / Kapat dediğinde macOS "BRAMPP oturumu kapatmayı engelledi"
        // diyerek tüm işlemi iptal eder ve oturum kilitlenir.
        // İki bağımsız sinyal birlikte kullanılır: willPowerOff bildirimi ile quit
        // AppleEvent'inin sırası macOS sürümleri arasında garanti değildir.
        if systemIsPoweringOff || isSystemQuitEvent {
            TunnelManager.killAllSynchronously()
            return .terminateNow
        }
        guard realQuitRequested else {
            // Dock sağ tık "Kapat" vb. istekler → pencereyi gizle, dock ikonunu kaldır
            // (uygulama YAŞAMAYA DEVAM ediyor; tüneller de açık kalır)
            mainWindow?.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
            return .terminateCancel
        }
        // Açık her tünel yerel siteyi internete çıkarıyor. Uygulama kapanırken
        // KOŞULSUZ kapatılır — `autoStopOnQuit` ayarına bağlanmaz, o ayar servisler
        // içindir. Arkada unutulmuş herkese açık bir adres kabul edilebilir değil.
        // Eşzamanlı sürüm kullanılır: burada başlatılan asenkron iş, süreç sonlanmadan
        // bitmeyebilirdi.
        TunnelManager.killAllSynchronously()
        return .terminateNow
    }

    // MARK: Reopen / yeniden açılma

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Pencere gizlenerek kapatıldığında (hideWindowOnClose) aktivasyon politikası
        // .accessory yapılır ve Dock ikonu kalkar. Yeniden açılışta .regular'a DÖNÜLMEZSE
        // uygulama pencereyi gösterir ama Dock'ta/⌘-Tab'da görünmez halde kalır.
        presentMainWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
