import SwiftUI
import Combine
import AppKit

// MARK: - SetupStatus

/// Kurulum kontrol modeli
struct SetupStatus: Identifiable {
    let id: String
    let name: String
    let description: String
    let checkCommand: String
    let installCommand: String
    var status: ItemStatus
    var isRequired: Bool
    
    enum ItemStatus: Equatable {
        case checking
        case installed
        case notInstalled
        case installing
        case error(String)
        
        var icon: String {
            switch self {
            case .checking:     return "arrow.clockwise"
            case .installed:    return "checkmark.circle.fill"
            case .notInstalled: return "xmark.circle.fill"
            case .installing:   return "arrow.down.circle"
            case .error:        return "exclamationmark.triangle.fill"
            }
        }
        
        var color: Color {
            switch self {
            case .checking:     return .gray
            case .installed:    return .green
            case .notInstalled: return .red
            case .installing:   return .blue
            case .error:        return .orange
            }
        }
    }
}

struct SetupCheckGroup: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let items: [SetupCheckItem]
    let action: (() -> Void)?
    var isRequired: Bool = true

    var isComplete: Bool {
        items.allSatisfy(\.isComplete)
    }

    var hasWarnings: Bool {
        items.contains { !$0.isComplete }
    }
}

struct SetupCheckItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let isComplete: Bool
}

// MARK: - SetupWizardView

/// İlk kurulum sihirbazı.
/// Tamamlandığında `onComplete` closure'ını çağırır.
struct SetupWizardView: View {
    @EnvironmentObject var loc: Localizer

    var onComplete: () -> Void

    @State private var currentStep: Step = .welcome
    @State private var setupItems: [SetupStatus] = []
    @State private var isChecking: Bool = false
    @State private var consoleOutput: [String] = []
    @State private var configRefreshTrigger = false
    /// Açık gruplar — sadece eksik adımlar gösterilir
    @State private var expandedConfigGroups: Set<String> = []
    /// Tam genişletilmiş gruplar — tüm adımlar (tamamlananlar dahil) gösterilir
    @State private var fullyExpandedGroups: Set<String> = []
    @StateObject private var mkcertManager = MkcertManager()
    @State private var showMkcertLog = false
    /// MariaDB otomatik kontrol devam ediyor mu
    @State private var mariaDBChecking: Bool = false
    /// MariaDB çalışıyor mu (mysqladmin ping)
    @State private var mariaDBFirstRunOk: Bool = false
    /// MariaDB root TCP erişimi (mysql -u root -h 127.0.0.1)
    @State private var mariaDBRootAccessOk: Bool = false
    /// root şifresi boş mu
    @State private var mariaDBRootNoPassword: Bool = false
    /// root auth plugin mysql_native_password mı
    @State private var mariaDBRootNativeAuth: Bool = false
    /// MariaDB test veritabanı silindi mi
    @State private var mariaDBTestDbRemoved: Bool = false

    enum Step: Int, CaseIterable {
        case welcome = 0, packages, configure, complete
    }
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            
            ScrollView {
                HStack {
                    Spacer()
                    contentView
                        .frame(maxWidth: 700)
                    Spacer()
                }
                .padding(40)
            }
            
            Divider()
            footerView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            setupItems = createSetupItems()
        }
        .onChange(of: mkcertManager.isInstalling) { _, installing in
            if installing { showMkcertLog = true }
        }
        .sheet(isPresented: $showMkcertLog) {
            MkcertInstallProgressSheet(manager: mkcertManager, isPresented: $showMkcertLog)
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.title)
                .foregroundColor(.accentColor)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(loc.t("wiz.title"))
                    .font(.headline)
                    .fontWeight(.semibold)
                Text(stepTitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Adım göstergesi
            HStack(spacing: 6) {
                ForEach(0..<Step.allCases.count, id: \.self) { i in
                    Circle()
                        .fill(currentStep.rawValue >= i ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private var stepTitle: String {
        switch currentStep {
        case .welcome:   return loc.t("wiz.step1")
        case .packages:  return loc.t("wiz.step2")
        case .configure: return loc.t("wiz.step3")
        case .complete:  return loc.t("wiz.step4")
        }
    }
    
    // MARK: - Content Router
    
    @ViewBuilder
    private var contentView: some View {
        switch currentStep {
        case .welcome:   welcomeView
        case .packages:  packagesView
        case .configure: configureView
        case .complete:  completeView
        }
    }
    
    // MARK: - Step 1: Welcome
    
    private var welcomeView: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "hand.wave.fill")
                .font(.system(size: 64))
                .foregroundColor(.accentColor)
            
            Text(loc.t("wiz.welcome"))
                .font(.title)
                .fontWeight(.bold)

            Text(loc.t("wiz.welcomeDesc"))
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 12) {
                featureRow(icon: "globe", text: loc.t("wiz.feat.langs"))
                featureRow(icon: "lock.fill", text: loc.t("wiz.feat.ssl"))
                featureRow(icon: "gear", text: loc.t("wiz.feat.mgmt"))
            }
            .padding(20)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
            
            // Mimari bilgisi
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(.body)
                    .foregroundColor(.secondary)
                Text("Homebrew: \(Shell.brewPrefix)")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 8)
            
            Spacer()
        }
        .frame(maxWidth: 600)
    }
    
    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(.accentColor)
                .frame(width: 24)
            Text(text)
                .font(.body)
        }
    }
    
    // MARK: - Step 2: Packages (Birleşik Kontrol + Kurulum)
    
    private var packagesView: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
                .frame(height: 0)
            
            Text(loc.t("wiz.pkgTitle"))
                .font(.title3)
                .fontWeight(.semibold)

            Text(loc.t("wiz.pkgDesc"))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 4)
            
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12, alignment: .top),
                    GridItem(.flexible(), spacing: 12, alignment: .top)
                ],
                spacing: 12
            ) {
                ForEach(setupItems) { item in
                    packageCard(item)
                }
            }
            
            // İlk açılışta otomatik kontrol başlatma mesajı
            if isChecking {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(loc.t("wiz.checking"))
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 12)
            }

            // Manuel yeniden kontrol butonu
            if !isChecking {
                Button(action: checkRequirements) {
                    Label(loc.t("wiz.recheck"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 8)
            }
            
            Spacer()
        }
        .frame(maxWidth: 760)
        .onAppear {
            // İlk açılışta otomatik kontrol başlat
            if setupItems.allSatisfy({ $0.status == .checking }) {
                checkRequirements()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Uygulama aktif olduğunda otomatik kontrol (Homebrew terminal kurulumu sonrası)
            // In-app streaming çalışıyorsa tetikleme
            guard currentStep == .packages, !isChecking, !isPackageInstalling else { return }
            let hasNotInstalledItems = setupItems.contains { item in
                if case .notInstalled = item.status { return true }
                return false
            }
            if hasNotInstalledItems { checkRequirements() }
        }
    }
    
    @ViewBuilder
    private func statusIcon(_ status: SetupStatus.ItemStatus) -> some View {
        if case .checking = status {
            ProgressView()
                .controlSize(.small)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: status.icon)
                .font(.body)
                .foregroundColor(status.color)
                .frame(width: 20)
        }
    }

    private func packageCard(_ item: SetupStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                statusIcon(item.status)
                    .frame(width: 20)
                
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        if item.isRequired {
                            Text(loc.t("wiz.required"))
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.2))
                                .foregroundColor(.red)
                                .cornerRadius(4)
                        }
                    }
                    
                    Text(item.description)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Spacer(minLength: 0)
                
                VStack(alignment: .trailing, spacing: 2) {
                    Text(statusText(item.status))
                        .font(.caption)
                        .foregroundColor(item.status.color)
                    
                    if case .notInstalled = item.status {
                        Button(loc.t("wiz.install")) {
                            installItem(item)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .topLeading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private func statusText(_ status: SetupStatus.ItemStatus) -> String {
        switch status {
        case .checking:     return loc.t("wiz.st.checking")
        case .installed:    return loc.t("wiz.st.installed")
        case .notInstalled: return loc.t("wiz.st.notInstalled")
        case .installing:   return loc.t("wiz.st.installing")
        case .error:        return loc.t("wiz.st.error")
        }
    }
    
    // MARK: - Step 3: Install
    
    // MARK: - Step 3: Configure
    
    private var configureView: some View {
        let groups = configurationGroups

        return VStack(spacing: 16) {
            Text(loc.t("wiz.configTitle"))
                .font(.title2)
                .fontWeight(.semibold)

            Text(loc.t("wiz.configDesc"))
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                ForEach(groups) { group in
                    configurationGroupCard(group)
                }
            }
            .id(configRefreshTrigger)

            Spacer()
        }
        .frame(maxWidth: 680)
        .task {
            await mkcertManager.checkStatus()
            // MariaDB grubunu kontrol başlamadan açık göster
            let mariaDBInstalled = FileManager.default.fileExists(atPath: "\(Shell.brewPrefix)/opt/mariadb")
            if mariaDBInstalled {
                expandedConfigGroups.insert("mariadb-root")
                fullyExpandedGroups.insert("mariadb-root")
            }
            await autoCheckMariaDB()
            // Yapılandırılmamış grupları otomatik aç
            let incomplete = configurationGroups.filter { !$0.isComplete }.map(\.id)
            expandedConfigGroups.formUnion(incomplete)
        }
    }
    
    
    
    private var configurationGroups: [SetupCheckGroup] {
        var groups: [SetupCheckGroup] = [
            SetupCheckGroup(
                id: "apache",
                title: loc.t("wiz.g.apache"),
                subtitle: loc.t("wiz.g.apache.sub"),
                items: apacheCheckItems,
                action: apacheCheckItems.allSatisfy(\.isComplete) ? nil : { configureApacheEnvironment() }
            ),
            SetupCheckGroup(
                id: "php83",
                title: loc.t("wiz.g.php"),
                subtitle: loc.t("wiz.g.php.sub"),
                items: php83CheckItems,
                action: php83CheckItems.allSatisfy(\.isComplete) ? nil : { configurePHP83Environment() }
            ),
            SetupCheckGroup(
                id: "mkcert",
                title: loc.t("wiz.g.mkcert"),
                subtitle: loc.t("wiz.g.mkcert.sub"),
                items: mkcertCheckItems,
                action: mkcertCheckItems.allSatisfy(\.isComplete) ? nil : { installMkcertCA() },
                // İSTEĞE BAĞLI. HTTPS olmadan da yerel geliştirme yapılır; zorunlu
                // olduğu için mkcert kurulumu bir sebeple takılan kullanıcı (kayıp
                // rootCA-key.pem, anahtarlık reddi) sihirbazı hiç bitiremiyor ve
                // çalışan bir HTTP ortamına da geçemiyordu.
                isRequired: false
            ),
            SetupCheckGroup(
                id: "localhost",
                title: loc.t("wiz.g.localhost"),
                subtitle: loc.t("wiz.g.localhost.sub"),
                items: localhostCheckItems,
                action: localhostCheckItems.allSatisfy(\.isComplete) ? nil : { setupLocalhostEnvironment() },
                // Aynı gerekçe: localhost HTTPS mkcert'e bağlı, o atlanabiliyorsa bu da.
                isRequired: false
            )
        ]

        // MariaDB kuruluysa yapılandırma grubunu ekle
        if FileManager.default.fileExists(atPath: "\(Shell.brewPrefix)/opt/mariadb") {
            groups.append(SetupCheckGroup(
                id: "mariadb-root",
                title: loc.t("wiz.g.mariadb"),
                subtitle: loc.t("wiz.g.mariadb.sub"),
                items: mariaDBRootCheckItems,
                action: mariaDBRootCheckItems.allSatisfy(\.isComplete) ? nil : {
                    Task { await firstRunAndConfigureMariaDB() }
                },
                isRequired: false
            ))
        }

        // phpMyAdmin brew paketi kuruluysa Apache entegrasyonu grubunu ekle
        if PathConfig.isPhpMyAdminInstalled {
            groups.append(SetupCheckGroup(
                id: "phpmyadmin",
                title: loc.t("wiz.g.pma"),
                subtitle: loc.t("wiz.g.pma.sub"),
                items: phpmyadminCheckItems,
                action: phpmyadminCheckItems.allSatisfy(\.isComplete) ? nil : {
                    setupPhpMyAdminApacheConfig()
                },
                isRequired: false
            ))
        }

        // Nginx kuruluysa yapılandırma gruplarını da ekle.
        // isRequired: false — Nginx isteğe bağlıdır (kullanıcı yalnızca Apache kullanmak
        // isteyebilir; nginx bir bağımlılık olarak kurulmuş olabilir). Aksi halde kurulan
        // her nginx sihirbazı bloklar ve "Devam" hiçbir zaman aktifleşmez.
        if PathConfig.isNginxInstalled {
            groups.append(SetupCheckGroup(
                id: "nginx",
                title: loc.t("wiz.g.nginx"),
                subtitle: loc.t("wiz.g.nginx.sub"),
                items: nginxCheckItems,
                action: nginxCheckItems.allSatisfy(\.isComplete) ? nil : { configureNginxEnvironment() },
                isRequired: false
            ))
            groups.append(SetupCheckGroup(
                id: "nginx-localhost",
                title: loc.t("wiz.g.nginx2"),
                subtitle: loc.t("wiz.g.nginx2.sub"),
                items: nginxLocalhostCheckItems,
                action: nginxLocalhostCheckItems.allSatisfy(\.isComplete) ? nil : { setupNginxLocalhostEnvironment() },
                isRequired: false
            ))
        }

        return groups
    }
    
    
    private var apacheCheckItems: [SetupCheckItem] {
        [
            SetupCheckItem(id: "httpd-conf", title: loc.t("wiz.i.httpd-conf"), detail: PathConfig.httpdConf, isComplete: FileManager.default.fileExists(atPath: PathConfig.httpdConf)),
            SetupCheckItem(id: "listen-80", title: loc.t("wiz.i.listen-80"), detail: "Listen 80", isComplete: checkHttpdListen80()),
            SetupCheckItem(id: "server-name", title: loc.t("wiz.i.server-name"), detail: "ServerName localhost:80", isComplete: checkHttpdServerNameLocalhost()),
            SetupCheckItem(id: "server-admin", title: loc.t("wiz.i.server-admin"), detail: "ServerAdmin admin@localhost", isComplete: checkHttpdServerAdminLocalhost()),
            SetupCheckItem(id: "include-vhosts", title: loc.t("wiz.i.include-vhosts"), detail: VHostTemplates.virtualHostsIncludeConfig(), isComplete: checkHttpdIncludesVHosts()),
            SetupCheckItem(id: "module-ssl", title: loc.t("wiz.i.module-ssl"), detail: "LoadModule ssl_module", isComplete: checkHttpdModule("ssl_module")),
            SetupCheckItem(id: "module-http2", title: loc.t("wiz.i.module-http2"), detail: "LoadModule http2_module", isComplete: checkHttpdModule("http2_module")),
            SetupCheckItem(id: "module-proxy", title: loc.t("wiz.i.module-proxy"), detail: "LoadModule proxy_module", isComplete: checkHttpdModule("proxy_module")),
            SetupCheckItem(id: "module-proxy-fcgi", title: loc.t("wiz.i.module-proxy-fcgi"), detail: "LoadModule proxy_fcgi_module", isComplete: checkHttpdModule("proxy_fcgi_module")),
            SetupCheckItem(id: "module-rewrite", title: loc.t("wiz.i.module-rewrite"), detail: "LoadModule rewrite_module", isComplete: checkHttpdModule("rewrite_module")),
            SetupCheckItem(id: "module-vhost-alias", title: loc.t("wiz.i.module-vhost-alias"), detail: "LoadModule vhost_alias_module", isComplete: checkHttpdModule("vhost_alias_module")),
            SetupCheckItem(id: "module-proxy-http", title: loc.t("wiz.i.module-proxy-http"), detail: "LoadModule proxy_http_module", isComplete: checkHttpdModule("proxy_http_module")),
            SetupCheckItem(id: "module-proxy-wstunnel", title: loc.t("wiz.i.module-proxy-wstunnel"), detail: "LoadModule proxy_wstunnel_module", isComplete: checkHttpdModule("proxy_wstunnel_module")),
            SetupCheckItem(id: "module-headers", title: loc.t("wiz.i.module-headers"), detail: "LoadModule headers_module", isComplete: checkHttpdModule("headers_module")),
            SetupCheckItem(id: "module-socache", title: loc.t("wiz.i.module-socache"), detail: "LoadModule socache_shmcb_module", isComplete: checkHttpdModule("socache_shmcb_module"))
        ]
    }

    private var php83CheckItems: [SetupCheckItem] {
        [
            SetupCheckItem(id: "php83-www-conf", title: loc.t("wiz.i.php83-www-conf"), detail: php83FpmConfigPath, isComplete: FileManager.default.fileExists(atPath: php83FpmConfigPath)),
            SetupCheckItem(id: "php83-listen-9083", title: loc.t("wiz.i.php83-listen"), detail: "listen = 127.0.0.1:9083", isComplete: checkPHP83ListenPort()),
            SetupCheckItem(id: "php83-user", title: loc.t("wiz.i.php83-user"), detail: "user / group / listen.owner / listen.group", isComplete: checkPHP83UserSettings())
        ]
    }
    
    private var localhostCheckItems: [SetupCheckItem] {
        [
            SetupCheckItem(id: "localhost-files", title: loc.t("wiz.i.localhost-files"), detail: PathConfig.localhostDir, isComplete: checkLocalhostFilesReady()),
            SetupCheckItem(
                id: "localhost-main-mapping",
                title: loc.t("wiz.i.localhost-main"),
                detail: "DocumentRoot + <Directory> + DirectoryIndex + <FilesMatch> → \(PathConfig.localhostDir)",
                isComplete: checkHttpdDocumentRootLocalhost() && checkHttpdDirectoryLocalhost() && checkHttpdDirectoryIndexLocalhost() && checkHttpdPHP83HandlerLocalhost()
            ),
            SetupCheckItem(id: "localhost-ssl", title: loc.t("wiz.i.localhost-ssl"), detail: "cert.pem + key.pem", isComplete: checkLocalhostCertificateGenerated()),
            SetupCheckItem(id: "localhost-https", title: loc.t("wiz.i.localhost-https"), detail: PathConfig.httpdSSLConf, isComplete: checkHttpdIncludesSSLConf() && checkHttpdSSLContainsLocalhost())
        ]
    }
    
    private var mkcertCheckItems: [SetupCheckItem] {
        [
            SetupCheckItem(id: "mkcert-installed", title: loc.t("wiz.i.mkcert-installed"), detail: PathConfig.mkcert, isComplete: mkcertManager.isMkcertInstalled),
            SetupCheckItem(id: "mkcert-ca", title: loc.t("wiz.i.mkcert-ca"), detail: mkcertManager.caRootPath.isEmpty ? "CA yolu henüz bulunamadı" : mkcertManager.caRootPath, isComplete: mkcertManager.isCAInstalled),
            SetupCheckItem(id: "mkcert-trusted", title: loc.t("wiz.i.mkcert-trusted"), detail: mkcertManager.isCATrusted ? "Sistem tarafından güvenilir" : "Güvenilir değil", isComplete: mkcertManager.isCATrusted)
        ]
    }
    private var mariaDBRootCheckItems: [SetupCheckItem] {
        [
            SetupCheckItem(
                id: "mariadb-running",
                title: loc.t("wiz.i.mariadb-running"),
                detail: "mysqladmin ping ile doğrulandı",
                isComplete: mariaDBFirstRunOk
            ),
            SetupCheckItem(
                id: "mariadb-root-tcp",
                title: loc.t("wiz.i.mariadb-root-tcp"),
                detail: "mysql -u root -h 127.0.0.1 -e 'SELECT 1'",
                isComplete: mariaDBRootAccessOk
            ),
            SetupCheckItem(
                id: "mariadb-root-nopass",
                title: loc.t("wiz.i.mariadb-root-nopass"),
                detail: "authentication_string boş olmalı",
                isComplete: mariaDBRootNoPassword
            ),
            SetupCheckItem(
                id: "mariadb-root-native",
                title: loc.t("wiz.i.mariadb-root-native"),
                detail: "plugin = mysql_native_password",
                isComplete: mariaDBRootNativeAuth
            ),
            SetupCheckItem(
                id: "mariadb-test-db",
                title: loc.t("wiz.i.mariadb-test-db"),
                detail: "SHOW DATABASES LIKE 'test' — varsayılan test DB silinir (varsa)",
                isComplete: mariaDBTestDbRemoved
            )
        ]
    }

    private var phpmyadminCheckItems: [SetupCheckItem] {
        let configChecks = checkPhpMyAdminConfig()
        return [
            SetupCheckItem(
                id: "pma-conf-file",
                title: loc.t("wiz.i.pma-conf-file"),
                detail: PathConfig.phpmyadminConf,
                isComplete: FileHelper.exists(PathConfig.phpmyadminConf)
            ),
            SetupCheckItem(
                id: "pma-httpd-include",
                title: loc.t("wiz.i.pma-httpd-include"),
                detail: VHostTemplates.phpmyadminIncludeConfig(),
                isComplete: checkHttpdContainsPhpMyAdminAlias()
            ),
            SetupCheckItem(
                id: "pma-config-file",
                title: loc.t("wiz.i.pma-config-file"),
                detail: "blowfish_secret (32 chr), host 127.0.0.1, AllowNoPassword true",
                isComplete: configChecks.blowfish && configChecks.host && configChecks.allowNoPassword
            )
        ]
    }

    /// config.inc.php içindeki kritik ayarları kontrol eder.
    private func checkPhpMyAdminConfig() -> (blowfish: Bool, host: Bool, allowNoPassword: Bool) {
        guard let content = FileHelper.readString(PathConfig.phpmyadminAppConfig) else {
            return (false, false, false)
        }

        // blowfish_secret en az 32 karakter mi
        var blowfishOk = false
        if let range = content.range(of: "blowfish_secret'] = '"),
           let end = content[range.upperBound...].range(of: "'") {
            let secret = String(content[range.upperBound..<end.lowerBound])
            blowfishOk = secret.count >= 32
        }

        // host 127.0.0.1 mi (localhost yerine)
        let hostOk = content.contains("['host'] = '127.0.0.1'")

        // AllowNoPassword true mi
        let allowOk = content.contains("AllowNoPassword'] = true")

        return (blowfishOk, hostOk, allowOk)
    }

    /// MariaDB root TCP erişimini async olarak kontrol eder — view body'i bloklamaz.
    private func checkMariaDBRootTCPAccessAsync() async {
        let result = await Shell.bashAsync("mysql --no-defaults -u root --password= -h 127.0.0.1 --connect-timeout=3 -e 'SELECT 1' 2>/dev/null")
        mariaDBRootAccessOk = result.isSuccess
    }

    /// MariaDB 'test' veritabanının var olup olmadığını kontrol eder.
    private func checkMariaDBTestDbAsync() async {
        // -N: sütun başlığını atla — başlık "Database (test)" içinde 'test' geçtiğinden
        // substring kontrolü DB silinmiş olsa bile daima "silinmemiş" raporluyordu.
        // 'CONN_OK' işaret satırı: bağlantı gerçekten kurulduysa çıktıda görünür — böylece
        // "bağlanamadı" (mysql yok/başlamamış) durumu yanlışlıkla "test silinmiş" sayılmaz.
        // root TCP erişimi yoksa unix socket ile dene.
        let query = "SELECT 'CONN_OK'; SHOW DATABASES LIKE 'test';"
        let check = await Shell.bashAsync(
            "mysql -N -u root -h 127.0.0.1 --connect-timeout=3 -e \"\(query)\" 2>/dev/null || " +
            "mysql -N -u root --connect-timeout=3 -e \"\(query)\" 2>/dev/null"
        )
        let lines = check.output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let connected = lines.contains("CONN_OK")
        guard connected else {
            // Bağlantı kurulamadı → durum belirsiz; "silindi" DEME (yanlış pozitif önlenir)
            mariaDBTestDbRemoved = false
            return
        }
        let dbExists = lines.contains("test")
        mariaDBTestDbRemoved = !dbExists
    }

    /// Yapılandırma adımına girildiğinde MariaDB'yi otomatik başlatır ve tüm adımları sırayla kontrol eder.
    private func autoCheckMariaDB() async {
        // MariaDB kurulu değilse atla
        let installed = FileManager.default.fileExists(atPath: "\(Shell.brewPrefix)/opt/mariadb")
        guard installed else { return }

        mariaDBChecking = true
        defer { mariaDBChecking = false }

        let currentUser = NSUserName()

        // 1) MariaDB çalışıyor mu — çalışmıyorsa otomatik başlat
        let ping = await Shell.brewBashAsync("mysqladmin -u \(currentUser) ping 2>/dev/null || mysqladmin ping 2>/dev/null")
        if ping.output.contains("alive") || ping.isSuccess {
            mariaDBFirstRunOk = true
        } else {
            _ = await Shell.brewBashAsync("\(Shell.brewBin) services run mariadb 2>&1")
            var started = false
            for _ in 0..<8 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let check = await Shell.brewBashAsync("mysqladmin -u \(currentUser) ping 2>/dev/null || mysqladmin ping 2>/dev/null")
                if check.output.contains("alive") || check.isSuccess { started = true; break }
            }
            mariaDBFirstRunOk = started
        }
        configRefreshTrigger.toggle()

        guard mariaDBFirstRunOk else { return }

        // 2) root TCP erişimi — mysql -u root -h 127.0.0.1
        await checkMariaDBRootTCPAccessAsync()
        configRefreshTrigger.toggle()

        // 3) root şifresi ve auth plugin kontrolü — mysql.global_priv veya mysql.user tablosundan sorgula
        await checkMariaDBRootAuthAsync()
        configRefreshTrigger.toggle()

        // 4) test veritabanı varlığı — SHOW DATABASES
        await checkMariaDBTestDbAsync()
        configRefreshTrigger.toggle()
    }

    /// root kullanıcısının TCP + boş şifre ile erişilebilirliğini kontrol eder.
    ///
    /// Not: Eski `mysql.global_priv ... \G` sorgusu güvenilmezdi — `global_priv` tablosunda
    /// `plugin`/`authentication_string` sütunları yoktur (JSON `Priv` kolonu vardır) ve `-N`
    /// bayrağı `\G` etiketlerini sildiğinden ayrıştırma her zaman başarısızdı. Bunun yerine
    /// doğrudan TCP bağlantısı test edilir: unix_socket auth TCP üzerinden çalışmadığından,
    /// TCP + boş şifre ile bağlanabilmek hem "şifresiz" hem "native auth" anlamına gelir —
    /// phpMyAdmin/VS Code gibi araçların ihtiyacı tam olarak budur.
    private func checkMariaDBRootAuthAsync() async {
        let tcpTest = await Shell.bashAsync("mysql --no-defaults -u root --password= -h 127.0.0.1 --connect-timeout=3 -e 'SELECT 1' 2>/dev/null")
        mariaDBRootNoPassword = tcpTest.isSuccess
        mariaDBRootNativeAuth  = tcpTest.isSuccess
    }

    /// MariaDB 'test' veritabanını siler (varsa). root TCP erişimi yapılandırıldıktan sonra çağrılmalıdır.
    private func dropMariaDBTestDb() async {
        consoleOutput.append("🔍 'test' veritabanı kontrol ediliyor...")
        // CONN_OK işaret satırı + -N + unix-socket yedeği — checkMariaDBTestDbAsync ile AYNI ölçüt.
        // Eskiden yalnızca çıktıda "test" aranıyordu: bağlantı HİÇ kurulamadığında çıktı boş
        // geldiğinden "zaten yok" sanılıp adım YANLIŞLIKLA tamamlanmış işaretleniyordu.
        let query = "SELECT 'CONN_OK'; SHOW DATABASES LIKE 'test';"
        let check = await Shell.bashAsync(
            "mysql -N -u root -h 127.0.0.1 --connect-timeout=3 -e \"\(query)\" 2>/dev/null || " +
            "mysql -N -u root --connect-timeout=3 -e \"\(query)\" 2>/dev/null"
        )
        let lines = check.output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard lines.contains("CONN_OK") else {
            consoleOutput.append("❌ MariaDB'ye bağlanılamadı — 'test' veritabanı durumu doğrulanamadı")
            mariaDBTestDbRemoved = false
            return
        }
        guard lines.contains("test") else {
            consoleOutput.append("✅ 'test' veritabanı zaten yok")
            mariaDBTestDbRemoved = true
            return
        }
        consoleOutput.append("🗑️  'test' veritabanı siliniyor...")
        let dropResult = await Shell.bashAsync(
            "mysql -u root -h 127.0.0.1 --connect-timeout=3 -e \"DROP DATABASE IF EXISTS \\`test\\`;\" 2>/dev/null || " +
            "mysql -u root --connect-timeout=3 -e \"DROP DATABASE IF EXISTS \\`test\\`;\" 2>/dev/null"
        )
        if dropResult.isSuccess || dropResult.exitCode == 0 {
            consoleOutput.append("✅ 'test' veritabanı silindi")
            mariaDBTestDbRemoved = true
        } else {
            consoleOutput.append("❌ 'test' veritabanı silinemedi: \(dropResult.error.isEmpty ? dropResult.output : dropResult.error)")
            mariaDBTestDbRemoved = false
        }
    }

    private var php83FpmConfigPath: String {
        PathConfig.phpFpmConf(version: "8.3")
    }

    // MARK: - Nginx Check Items

    private var nginxCheckItems: [SetupCheckItem] {
        [
            SetupCheckItem(
                id: "nginx-conf",
                title: loc.t("wiz.i.nginx-conf"),
                detail: PathConfig.nginxConf,
                isComplete: FileManager.default.fileExists(atPath: PathConfig.nginxConf)
            ),
            SetupCheckItem(
                id: "nginx-sites-available-dir",
                title: loc.t("wiz.i.nginx-sites-dir"),
                detail: PathConfig.nginxSitesAvailableDir,
                isComplete: FileManager.default.fileExists(atPath: PathConfig.nginxSitesAvailableDir)
            ),
            SetupCheckItem(
                id: "nginx-main-config-rewritten",
                title: loc.t("wiz.i.nginx-rewritten"),
                detail: "localhost HTTP :\(WebServerPorts.nginxHTTP()) + phpMyAdmin + include sites-available/*.conf içeriyor",
                isComplete: NginxConfigManager.isMainConfigRewritten
            ),
            SetupCheckItem(
                id: "nginx-localhost-http",
                title: loc.t("wiz.i.nginx-localhost-http"),
                detail: "listen \(WebServerPorts.nginxHTTP()) default_server; server_name localhost; (nginx.conf içinde)",
                isComplete: NginxConfigManager.isLocalhostHTTPConfigured
            )
        ]
    }

    private var nginxLocalhostCheckItems: [SetupCheckItem] {
        [
            SetupCheckItem(
                id: "nginx-localhost-cert",
                title: loc.t("wiz.i.nginx-localhost-cert"),
                detail: "\(PathConfig.localhostSSLDir)/cert.pem",
                isComplete: checkLocalhostCertificateGenerated()
            ),
            SetupCheckItem(
                id: "nginx-localhost-https",
                title: loc.t("wiz.i.nginx-localhost-https"),
                detail: "listen \(WebServerPorts.nginxHTTPS()) ssl default_server; server_name localhost; (nginx.conf içinde)",
                isComplete: NginxConfigManager.isLocalhostHTTPSConfigured
            )
        ]
    }

    // MARK: - Nginx Check Helpers (legacy — artık nginx.conf'ta check yapılıyor)

    private func checkNginxLocalhostHTTP() -> Bool {
        NginxConfigManager.isLocalhostHTTPConfigured
    }

    private func checkNginxLocalhostHTTPS() -> Bool {
        NginxConfigManager.isLocalhostHTTPSConfigured
    }

    // MARK: - Nginx Configure Actions

    private func configureNginxEnvironment() {
        consoleOutput.append("▶️ Nginx yapılandırması hazırlanıyor...")

        guard FileManager.default.fileExists(atPath: PathConfig.nginxConf) else {
            consoleOutput.append("❌ nginx.conf bulunamadı: \(PathConfig.nginxConf)")
            consoleOutput.append("ℹ️  'brew install nginx' ile Nginx'i kurun")
            refreshConfigView()
            return
        }

        // sites-available/ dizinini oluştur
        NginxConfigManager.createSitesAvailableDir()
        consoleOutput.append("✅ sites-available/ dizini hazır: \(PathConfig.nginxSitesAvailableDir)")

        // nginx.conf'u sıfırdan yaz (SSL olmadan — localhost bloğu hâlâ eklenir).
        // Portlar mevcut nginx.conf'tan korunur; yazımdan önce zaman damgalı yedek alınır.
        let httpPort  = WebServerPorts.nginxHTTP()
        let httpsPort = WebServerPorts.nginxHTTPS()
        let sslAvailable = checkLocalhostCertificateGenerated()
        if NginxConfigManager.rewriteMainConfig(sslAvailable: sslAvailable) {
            consoleOutput.append("✅ nginx.conf yeniden yazıldı (önceki hâli yedeklendi)")
            consoleOutput.append("✅ localhost HTTP :\(httpPort) ve phpMyAdmin tanımlandı")
            consoleOutput.append("✅ sites-available/*.conf include eklendi")
            if sslAvailable {
                consoleOutput.append("✅ localhost HTTPS :\(httpsPort) bloğu da eklendi")
            }
        } else {
            consoleOutput.append("⚠️  nginx.conf yazılamadı — dosyaya yazma izni kontrol edin")
            consoleOutput.append("   Dosya: \(PathConfig.nginxConf)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            refreshConfigView()
        }
    }

    private func setupNginxLocalhostEnvironment() {
        consoleOutput.append("▶️ Nginx localhost SSL yapılandırması hazırlanıyor...")

        if !nginxCheckItems.allSatisfy(\.isComplete) {
            consoleOutput.append("⚠️  Önce Nginx Yapılandırmasını tamamlayın")
            refreshConfigView()
            return
        }

        if !checkLocalhostCertificateGenerated() {
            consoleOutput.append("⚠️  localhost SSL sertifikası yok — önce 'localhost Kurulumu' adımını tamamlayın")
            refreshConfigView()
            return
        }

        // nginx.conf'u SSL ile yeniden yaz (HTTPS bloğu eklenir)
        let httpPort  = WebServerPorts.nginxHTTP()
        let httpsPort = WebServerPorts.nginxHTTPS()
        if NginxConfigManager.rewriteMainConfig(sslAvailable: true) {
            consoleOutput.append("✅ nginx.conf yeniden yazıldı — HTTPS :\(httpsPort) bloğu eklendi")
            consoleOutput.append("✅ HTTP :\(httpPort) ve HTTPS :\(httpsPort) localhost blokları tanımlandı")
            consoleOutput.append("✅ phpMyAdmin hem HTTP hem HTTPS üzerinden erişilebilir")
            consoleOutput.append("ℹ️  Nginx'i Servisler sekmesinden yeniden başlatın (veya: brew services stop nginx && brew services run nginx)")
        } else {
            consoleOutput.append("❌ nginx.conf yazılamadı — dosyaya yazma izni kontrol edin")
            consoleOutput.append("   Dosya: \(PathConfig.nginxConf)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            refreshConfigView()
        }
    }

    private func checkHttpdIncludesSSLConf() -> Bool {
        guard let content = try? String(contentsOfFile: PathConfig.httpdConf, encoding: .utf8) else { return false }
        let lines = content.components(separatedBy: .newlines)
        // Dinamik brew yolu — Intel (/usr/local) ve Apple Silicon (/opt/homebrew) ikisi de çalışsın
        let sslConf = PathConfig.httpdSSLConf
        let validLines = [
            "Include \"\(sslConf)\"",
            "Include \(sslConf)"
        ]
        return lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("#") && validLines.contains(trimmed)
        }
    }
    
    private func checkHttpdSSLContainsLocalhost() -> Bool {
        guard let content = try? String(contentsOfFile: PathConfig.httpdSSLConf, encoding: .utf8) else { return false }
        return content.contains("ServerName localhost") && content.contains("DocumentRoot \"\(PathConfig.localhostDir)\"")
    }

    private func checkHttpdListen80() -> Bool {
        guard let content = try? String(contentsOfFile: PathConfig.httpdConf, encoding: .utf8) else { return false }
        let lines = content.components(separatedBy: .newlines)
        return lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("#") && (trimmed == "Listen 80" || trimmed == "Listen 0.0.0.0:80")
        }
    }

    private func checkHttpdServerNameLocalhost() -> Bool {
        guard let content = try? String(contentsOfFile: PathConfig.httpdConf, encoding: .utf8) else { return false }
        let lines = content.components(separatedBy: .newlines)
        return lines.contains { line in
            line.trimmingCharacters(in: .whitespaces) == "ServerName localhost:80"
        }
    }

    private func checkHttpdServerAdminLocalhost() -> Bool {
        guard let content = try? String(contentsOfFile: PathConfig.httpdConf, encoding: .utf8) else { return false }
        let lines = content.components(separatedBy: .newlines)
        return lines.contains { line in
            line.trimmingCharacters(in: .whitespaces) == "ServerAdmin admin@localhost"
        }
    }
    
    private func checkHttpdDocumentRootLocalhost() -> Bool {
        guard let content = try? String(contentsOfFile: PathConfig.httpdConf, encoding: .utf8) else { return false }
        let lines = content.components(separatedBy: .newlines)
        return lines.contains { line in
            line.trimmingCharacters(in: .whitespaces) == "DocumentRoot \"\(PathConfig.localhostDir)\""
        }
    }
    


    private func checkHttpdDirectoryLocalhost() -> Bool {
        guard let content = try? String(contentsOfFile: PathConfig.httpdConf, encoding: .utf8) else { return false }
        let lines = content.components(separatedBy: .newlines)
        return lines.contains { line in
            line.trimmingCharacters(in: .whitespaces) == "<Directory \"\(PathConfig.localhostDir)\">"
        }
    }

    private func checkHttpdDirectoryIndexLocalhost() -> Bool {
        guard let content = try? String(contentsOfFile: PathConfig.httpdConf, encoding: .utf8) else { return false }
        let lines = content.components(separatedBy: .newlines)
        return lines.contains { line in
            line.trimmingCharacters(in: .whitespaces) == "DirectoryIndex index.php index.html"
        }
    }

    /// localhost için kullanılacak PHP-FPM portu — TEK KAYNAK.
    /// Kontrol ile yazıcılar aynı değeri kullanmalı: aksi halde kullanıcı varsayılan PHP
    /// sürümünü değiştirdiğinde yazıcı 9081 yazar, kontrol 9083 arar ve "localhost Kurulumu"
    /// adımı asla tamamlanmış görünmez → sihirbaz "Devam"da kilitlenir.
    private var localhostFcgiPort: Int { AppSettings.load().defaultPHPVersion.port }

    private func checkHttpdPHP83HandlerLocalhost() -> Bool {
        guard let content = try? String(contentsOfFile: PathConfig.httpdConf, encoding: .utf8) else { return false }
        return content.contains("<FilesMatch \\.php$>")
            && content.contains("SetHandler \"proxy:fcgi://127.0.0.1:\(localhostFcgiPort)\"")
    }

    /// localhost SSL çifti hazır mı? Tek kaynak: `NginxConfigManager.localhostSSLReady`
    /// (cert.pem **ve** key.pem — key eksikken yazılan SSL bloğu sunucuyu hiç başlatmaz).
    private func checkLocalhostCertificateGenerated() -> Bool {
        NginxConfigManager.localhostSSLReady
    }

    private func checkLocalhostFilesReady() -> Bool {
        FileManager.default.fileExists(atPath: PathConfig.localhostDir) &&
        FileManager.default.fileExists(atPath: "\(PathConfig.localhostDir)/index.php")
    }

    private func checkPHP83ListenPort() -> Bool {
        guard let content = try? String(contentsOfFile: php83FpmConfigPath, encoding: .utf8) else { return false }
        let lines = content.components(separatedBy: .newlines)
        return lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix(";") && trimmed == "listen = 127.0.0.1:9083"
        }
    }
    
    private func checkPHP83UserSettings() -> Bool {
        guard let content = try? String(contentsOfFile: php83FpmConfigPath, encoding: .utf8) else { return false }
        let lines = content.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        
        let hasUser = lines.contains(where: { !$0.hasPrefix(";") && $0.hasPrefix("user =") })
        let hasGroup = lines.contains(where: { !$0.hasPrefix(";") && $0.hasPrefix("group =") })
        let hasOwner = lines.contains(where: { !$0.hasPrefix(";") && $0.hasPrefix("listen.owner =") })
        let hasListenGroup = lines.contains(where: { !$0.hasPrefix(";") && $0.hasPrefix("listen.group =") })
        
        return hasUser && hasGroup && hasOwner && hasListenGroup
    }

    private var currentMissingPackage: SetupStatus? {
        setupItems.first { $0.status != .installed }
    }

    /// Herhangi bir paket kurulumu devam ediyor mu?
    private var isPackageInstalling: Bool {
        setupItems.contains { if case .installing = $0.status { return true }; return false }
    }
    
    @ViewBuilder
    private func configurationGroupCard(_ group: SetupCheckGroup) -> some View {
        let isExpanded   = expandedConfigGroups.contains(group.id)
        let isFullyExp   = fullyExpandedGroups.contains(group.id)
        // Gösterilecek adımlar: tam genişletme varsa hepsi, değilse sadece eksikler
        let visibleItems = isFullyExp ? group.items : group.items.filter { !$0.isComplete }

        VStack(alignment: .leading, spacing: 0) {
            Button(action: { toggleConfigGroup(group.id) }) {
                HStack(spacing: 12) {
                    if group.id == "mariadb-root" && mariaDBChecking {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 20, height: 20)
                    } else {
                        Image(systemName: group.isComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(group.isComplete ? .green : .orange)
                            .frame(width: 20)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(group.title)
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundColor(group.isComplete && !isExpanded ? .secondary : .primary)

                            if !group.isRequired {
                                Text(loc.t("wiz.optional"))
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.15))
                                    .foregroundColor(.blue)
                                    .cornerRadius(4)
                            }

                            if group.id == "mariadb-root" && mariaDBChecking {
                                Text(loc.t("wiz.checkingShort"))
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            }
                        }
                        Text(group.subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Text("\(group.items.filter(\.isComplete).count)/\(group.items.count)")
                        .font(.caption)
                        .foregroundColor(group.isComplete ? .green : .secondary)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(visibleItems) { item in
                        HStack(alignment: .top, spacing: 10) {
                            if group.id == "mariadb-root" && mariaDBChecking && !item.isComplete {
                                ProgressView()
                                    .controlSize(.mini)
                                    .frame(width: 16, height: 16)
                                    .padding(.top, 2)
                            } else {
                                Image(systemName: item.isComplete ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(item.isComplete ? .green : .red)
                                    .frame(width: 16)
                                    .padding(.top, 2)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.callout)
                                Text(item.detail)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                            }

                            Spacer()
                        }
                    }

                    // Tamamlananları göster / gizle
                    if group.items.contains(where: \.isComplete) {
                        Divider()
                        Button(action: { toggleFullyExpanded(group.id) }) {
                            Label(
                                isFullyExp ? loc.t("wiz.hideCompleted") : loc.t("wiz.showCompleted"),
                                systemImage: isFullyExp ? "eye.slash" : "eye"
                            )
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }

                    if let action = group.action, !group.isComplete {
                        HStack {
                            Spacer()
                            Button(group.id == "packages" ? loc.t("wiz.recheck") : loc.t("wiz.configure")) {
                                consoleOutput.append("🔧 \(group.title) yapılandırılıyor...")
                                action()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(.top, 4)
                    } else if group.isComplete {
                        HStack {
                            Spacer()
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                Text(loc.t("wiz.done"))
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(14)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .opacity(group.isComplete && !isExpanded ? 0.6 : 1.0)
    }

    /// Kapalı ↔ açık (aç/kapat — tam genişleme alttaki butonla)
    private func toggleConfigGroup(_ id: String) {
        if expandedConfigGroups.contains(id) {
            expandedConfigGroups.remove(id)
            fullyExpandedGroups.remove(id)
        } else {
            expandedConfigGroups.insert(id)
        }
    }

    private func toggleFullyExpanded(_ id: String) {
        if fullyExpandedGroups.contains(id) {
            fullyExpandedGroups.remove(id)
        } else {
            fullyExpandedGroups.insert(id)
        }
    }
    // Reusable console box used in steps
    private func consoleBox(lineCount: Int, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "terminal")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(loc.t("wiz.console"))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                Spacer()
                if isChecking {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if consoleOutput.isEmpty {
                            Text(loc.t("wiz.waitConsole"))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .padding(12)
                        } else {
                            ForEach(Array(consoleOutput.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .textSelection(.enabled)
                                    .id(index)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .frame(height: height)
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: consoleOutput.count) {
                    if let lastIndex = consoleOutput.indices.last {
                        withAnimation {
                            proxy.scrollTo(lastIndex, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(NSColor.separatorColor).opacity(0.3), lineWidth: 1)
        )
    }
    
    // MARK: - Step 5: Complete
    
    private var completeView: some View {
        VStack(spacing: 28) {
            Spacer()
            
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)
            
            Text(loc.t("wiz.complete"))
                .font(.title)
                .fontWeight(.bold)

            VStack(alignment: .leading, spacing: 12) {
                Text(loc.t("wiz.nextSteps"))
                    .font(.headline)
                    .fontWeight(.semibold)
                stepRow(num: 1, text: loc.t("wiz.next1"))
                stepRow(num: 2, text: loc.t("wiz.next2"))
                stepRow(num: 3, text: loc.t("wiz.startDev"))
            }
            .padding(20)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
            
            Spacer()
        }
        .frame(maxWidth: 600)
    }
    
    private func stepRow(num: Int, text: String) -> some View {
        HStack(spacing: 10) {
            Text("\(num)")
                .font(.callout)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor)
                .clipShape(Circle())
            Text(text)
                .font(.body)
        }
    }
    
    // MARK: - Footer
    
    private var footerView: some View {
        VStack(spacing: 0) {
            // Konsol (her zaman göster - welcome hariç)
            if currentStep != .welcome {
                Divider()
                consoleFooterBox
            }
            
            Divider()
            
            // Butonlar
            HStack {
                if currentStep != .welcome && currentStep != .complete {
                    Button(loc.t("wiz.back")) { goBack() }
                        .controlSize(.large)
                }

                Spacer()

                if currentStep == .complete {
                    Button(loc.t("wiz.finish")) { completeSetup() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                } else {
                    Button(loc.t("wiz.next")) { goNext() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!canProceed)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }
    
    private var consoleFooterBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "terminal")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(loc.t("wiz.console"))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)

                if isPackageInstalling {
                    Text(loc.t("wiz.installing"))
                        .font(.caption2)
                        .foregroundColor(.blue)
                }

                Spacer()

                if isChecking || isPackageInstalling {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if consoleOutput.isEmpty {
                            Text(loc.t("wiz.waitConsole"))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .padding(12)
                        } else {
                            ForEach(Array(consoleOutput.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .textSelection(.enabled)
                                    .id(index)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .frame(height: 120)
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: consoleOutput.count) {
                    if let lastIndex = consoleOutput.indices.last {
                        withAnimation {
                            proxy.scrollTo(lastIndex, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
    
    private var canProceed: Bool {
        switch currentStep {
        case .welcome: return true
        case .packages:
            // Kurulum devam ediyorsa bekle
            guard !isPackageInstalling else { return false }
            // Tüm zorunlu paketler kurulu olmalı
            return setupItems
                .filter { $0.isRequired }
                .allSatisfy { $0.status == .installed }
        case .configure:
            // Yalnızca zorunlu yapılandırma grupları tamamlanmış olmalı
            return configurationGroups.filter(\.isRequired).allSatisfy(\.isComplete)
        case .complete:
            return true
        }
    }
    
    // MARK: - Navigation
    
    private func goNext() {
        withAnimation {
            switch currentStep {
            case .welcome:   currentStep = .packages
            case .packages:  currentStep = .configure
            case .configure: currentStep = .complete
            case .complete:  completeSetup()
            }
        }
    }
    
    private func goBack() {
        withAnimation {
            switch currentStep {
            case .packages:  currentStep = .welcome
            case .configure: currentStep = .packages
            default: break
            }
        }
    }
    
    // MARK: - Setup Items
    
    private func createSetupItems() -> [SetupStatus] {
        [
            SetupStatus(
                id: "homebrew",
                name: "Homebrew",
                description: "\(loc.t("wiz.pkgd.homebrew")) (\(Shell.brewPrefix))",
                checkCommand: "test -f \(Shell.brewBin) && echo 'ok' || echo 'fail'",
                installCommand: "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"",
                status: .checking,
                isRequired: true
            ),
            SetupStatus(
                id: "httpd",
                name: "Apache (httpd)",
                description: loc.t("wiz.pkgd.apache"),
                checkCommand: "test -d \(Shell.brewPrefix)/opt/httpd && echo 'ok' || echo 'fail'",
                installCommand: "\(Shell.brewBin) install httpd",
                status: .checking,
                isRequired: true
            ),
            SetupStatus(
                id: "mkcert",
                name: "mkcert",
                description: loc.t("wiz.pkgd.mkcert"),
                checkCommand: "(command -v mkcert >/dev/null 2>&1 || test -f \(PathConfig.mkcert)) && echo 'ok' || echo 'fail'",
                installCommand: "\(Shell.brewBin) install mkcert nss",
                status: .checking,
                isRequired: true
            ),
            SetupStatus(
                id: "php83",
                name: "PHP 8.3",
                description: loc.t("wiz.defaultPHP"),
                checkCommand: "test -d \(Shell.brewPrefix)/opt/php@8.3 && echo 'ok' || echo 'fail'",
                installCommand: "\(Shell.brewBin) install php@8.3",
                status: .checking,
                isRequired: true
            ),
            SetupStatus(
                id: "mariadb",
                name: "MariaDB",
                description: loc.t("wiz.dbOptional"),
                checkCommand: "test -d \(Shell.brewPrefix)/opt/mariadb && echo 'ok' || echo 'fail'",
                installCommand: "\(Shell.brewBin) install mariadb",
                status: .checking,
                isRequired: false
            ),
            SetupStatus(
                id: "phpmyadmin",
                name: "phpMyAdmin",
                description: loc.t("wiz.webDbOptional"),
                checkCommand: "test -d \(PathConfig.phpmyadminDir) && echo 'ok' || echo 'fail'",
                installCommand: "\(Shell.brewBin) install phpmyadmin",
                status: .checking,
                isRequired: false
            )
        ]
    }
    
    // MARK: - Actions
    
    private func checkRequirements() {
        isChecking = true

        Task {
            let items = setupItems
            var missing: [String] = []

            for i in 0..<items.count {
                let item = items[i]
                let result = await Shell.bashAsync(item.checkCommand)
                let ok = result.isSuccess
                    && result.output.lowercased().contains("ok")
                    && !result.output.lowercased().contains("fail")
                // Bu kontrol beklerken kullanıcı kuruluma başladıysa (.installing) durumu EZME
                if case .installing = setupItems[i].status {
                    if !ok { missing.append(item.name) }
                    continue
                }
                setupItems[i].status = ok ? .installed : .notInstalled
                if !ok { missing.append(item.name) }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            isChecking = false

            if missing.isEmpty {
                consoleOutput.append("✅ Tüm paketler kurulu")
            } else {
                consoleOutput.append("⚠️ Eksik: \(missing.joined(separator: ", "))")
            }

            checkAndAutoAdvance()
        }
    }
    
    /// MariaDB'yi başlatır, ardından root kullanıcısını ayarlar ve test DB'yi siler.
    private func firstRunAndConfigureMariaDB() async {
        let currentUser = NSUserName()

        if !mariaDBFirstRunOk {
            consoleOutput.append("🔧 MariaDB çalıştırılıyor...")
            _ = await Shell.brewBashAsync("\(Shell.brewBin) services run mariadb 2>&1")
            var started = false
            for _ in 0..<8 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let check = await Shell.brewBashAsync("mysqladmin -u \(currentUser) ping 2>/dev/null || mysqladmin ping 2>/dev/null")
                if check.output.contains("alive") || check.isSuccess { started = true; break }
            }
            if started {
                mariaDBFirstRunOk = true
                consoleOutput.append("✅ MariaDB çalıştırıldı")
            } else {
                consoleOutput.append("❌ MariaDB başlatılamadı")
                return
            }
        }

        await configureMariaDBRoot()
    }

    /// brew progress bar satırı mı? ("#####  50%" gibi)
    private func isProgressBar(_ line: String) -> Bool {
        line.contains("#") && line.contains("%")
    }

    /// MariaDB root@localhost'u mysql_native_password (boş şifre) ile yapılandırır.
    /// Homebrew MariaDB unix_socket auth kullanır; TCP bağlantısı için (phpMyAdmin, VS Code vb.) bu adım gereklidir.
    private func configureMariaDBRoot() async {
        let currentUser = NSUserName()
        consoleOutput.append("🔧 MariaDB root@localhost yapılandırılıyor...")

        let ping = await Shell.brewBashAsync("mysqladmin -u \(currentUser) ping 2>/dev/null || mysqladmin ping 2>/dev/null")
        let wasRunning = ping.output.contains("alive") || ping.isSuccess

        if !wasRunning {
            consoleOutput.append("ℹ️  MariaDB çalışmıyor — geçici olarak başlatılıyor...")
            _ = await Shell.brewBashAsync("\(Shell.brewBin) services run mariadb 2>&1")
            var started = false
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let check = await Shell.brewBashAsync("mysqladmin -u \(currentUser) ping 2>/dev/null || mysqladmin ping 2>/dev/null")
                if check.output.contains("alive") || check.isSuccess { started = true; break }
            }
            guard started else {
                consoleOutput.append("❌ MariaDB başlatılamadı — yapılandırma atlanıyor")
                return
            }
            consoleOutput.append("✅ MariaDB başlatıldı")
        }

        let sql = "GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('') WITH GRANT OPTION; FLUSH PRIVILEGES;"
        let fix = await Shell.brewBashAsync("mysql -u \(currentUser) -e \"\(sql)\" 2>&1")
        if fix.isSuccess || fix.exitCode == 0 {
            consoleOutput.append("✅ MariaDB root@localhost yapılandırıldı — root / boş şifre ile TCP bağlantısı açık")
        } else {
            let fix2 = await Shell.brewBashAsync("mysql -e \"\(sql)\" 2>&1")
            if fix2.isSuccess || fix2.exitCode == 0 {
                consoleOutput.append("✅ MariaDB root@localhost yapılandırıldı")
            } else {
                consoleOutput.append("❌ MariaDB root@localhost yapılandırılamadı: \(fix.error.isEmpty ? fix.output : fix.error)")
                consoleOutput.append("ℹ️  Terminalde: mysql -u \(currentUser) -e \"\(sql)\"")
            }
        }

        await checkMariaDBRootTCPAccessAsync()
        await checkMariaDBRootAuthAsync()
        await dropMariaDBTestDb()
        configRefreshTrigger.toggle()

        if !wasRunning {
            _ = await Shell.brewBashAsync("\(Shell.brewBin) services stop mariadb 2>&1")
            consoleOutput.append("ℹ️  MariaDB durduruldu (geçici başlatılmıştı)")
        }
    }

    /// phpMyAdmin yapılandırması: extra/phpmyadmin.conf oluştur, httpd.conf'a include ekle, config.inc.php yaz/yamala.
    private func setupPhpMyAdminApacheConfig() {
        FileHelper.createDirectory(PathConfig.httpdExtra)
        let confOK    = FileHelper.write(VHostTemplates.phpmyadminConfig(), to: PathConfig.phpmyadminConf)
        let includeOK = FileHelper.appendLineIfMissing(VHostTemplates.phpmyadminIncludeConfig(), to: PathConfig.httpdConf)
        let appOK     = patchOrWritePhpMyAdminConfig()
        consoleOutput.append(confOK    ? "✅ extra/phpmyadmin.conf oluşturuldu"     : "❌ extra/phpmyadmin.conf yazılamadı")
        consoleOutput.append(includeOK ? "✅ httpd.conf — IncludeOptional eklendi"  : "❌ httpd.conf — include eklenemedi")
        consoleOutput.append(appOK     ? "✅ phpmyadmin.config.inc.php güncellendi" : "❌ phpmyadmin.config.inc.php yazılamadı")
    }

    /// httpd.conf phpMyAdmin include'ını ETKİN olarak içeriyor mu?
    ///
    /// Düz alt dize araması YETMEZ: `# IncludeOptional …/phpmyadmin.conf` satırı da
    /// eşleşiyordu. Yorumlanmış bir include Apache tarafından yok sayılır, ama sihirbaz
    /// adımı "tamam" gösterip kullanıcıyı phpMyAdmin'in çalışmadığı bir yapılandırmayla
    /// baş başa bırakıyordu.
    static func httpdIncludesPhpMyAdmin(_ content: String, includeLine: String) -> Bool {
        let needle = includeLine.trimmingCharacters(in: .whitespaces)
        return content.components(separatedBy: .newlines).contains { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { return false }
            return line == needle || line.contains("phpmyadmin.conf")
        }
    }

    private func checkHttpdContainsPhpMyAdminAlias() -> Bool {
        guard let content = FileHelper.readString(PathConfig.httpdConf) else { return false }
        return Self.httpdIncludesPhpMyAdmin(content,
                                            includeLine: VHostTemplates.phpmyadminIncludeConfig())
    }

    /// config.inc.php: varsa ilgili satırları yamalar; yoksa sıfırdan yazar.
    /// • blowfish_secret boş/kısa ise 32 karakterlik rastgele anahtar üretir
    /// • host 'localhost' ise '127.0.0.1' yapar
    /// • AllowNoPassword false ise true yapar
    /// Var olan dosya ÖZGÜN kodlamasıyla geri yazılır; okunamıyorsa hiç dokunulmaz.
    @discardableResult
    private func patchOrWritePhpMyAdminConfig() -> Bool {
        let path = PathConfig.phpmyadminAppConfig

        let result = ConfigFileEditor.patch(path) { existing in
            let patched = existing.components(separatedBy: .newlines)
                .map { line -> String in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    // blowfish_secret boş veya kısa
                    if t.contains("blowfish_secret") {
                        if let s = t.range(of: "= '")?.upperBound,
                           let e = t[s...].range(of: "'")?.lowerBound {
                            let secret = String(t[s..<e])
                            if secret.count < 32 {
                                let newSecret = VHostTemplates.generateBlowfishSecret()
                                return line.replacingOccurrences(of: "= '\(secret)'", with: "= '\(newSecret)'")
                            }
                        }
                        return line
                    }
                    // host localhost → 127.0.0.1
                    if t.contains("['host']") && t.contains("'localhost'") {
                        return line.replacingOccurrences(of: "'localhost'", with: "'127.0.0.1'")
                    }
                    // AllowNoPassword false → true
                    if t.contains("AllowNoPassword") {
                        return line.replacingOccurrences(of: "= false;", with: "= true;")
                    }
                    return line
                }
                .joined(separator: "\n")
            // hide_db yoksa sona ekle
            let hideDB = "$cfg['Servers'][$i]['hide_db'] = '^(information_schema|mysql|performance_schema|sys|phpmyadmin)';"
            return patched.contains("hide_db") ? patched : patched + "\n\n" + hideDB + "\n"
        }

        switch result {
        case .written:     return true
        case .writeFailed: return false
        case .unreadable:  return false   // dosya VAR ama çözülemedi → ÜZERİNE YAZMA
        case .missing:     return FileHelper.write(VHostTemplates.phpmyadminLocalConfig(), to: path)
        }
    }

    /// Tüm zorunlu bileşenler kuruluysa bildirim ver
    private func checkAndAutoAdvance() {
        let allRequiredInstalled = setupItems
            .filter { $0.isRequired }
            .allSatisfy { $0.status == .installed }
        
        if allRequiredInstalled && currentStep == .packages {
            consoleOutput.append("✅ Tüm paketler hazır — Devam edebilirsiniz.")
        }
    }
    
    private func installItem(_ item: SetupStatus) {
        guard let i = setupItems.firstIndex(where: { $0.id == item.id }) else { return }
        // Zaten kuruluyorsa ikinci kez brew install tetikleme (çift kurulum koruması)
        if case .installing = setupItems[i].status { return }
        setupItems[i].status = .installing

        // Homebrew — interactive sudo gerektiriyor; external terminal zorunlu
        if item.id == "homebrew" {
            consoleOutput.append("🖥️  Homebrew terminal'de kuruluyor — bitince 'Yeniden Kontrol Et' butonuna basın")
            TerminalHelper.runInNewWindowAndWait(
                "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"",
                title: loc.t("wiz.homebrewTitle")
            )
            setupItems[i].status = .notInstalled
            return
        }

        // brew install paketleri — sudo gerektirmez; in-app streaming
        Task {
            consoleOutput.append("$ \(item.installCommand)")
            let r = await Shell.streamBash(
                item.installCommand,
                onLine: { line in
                    let clean = ServiceManager.stripANSI(line)
                    guard !clean.isEmpty else { return }
                    consoleOutput.append(clean)
                },
                onProgress: { line in
                    let clean = ServiceManager.stripANSI(line)
                    guard !clean.isEmpty else { return }
                    // Son satır bir progress bar ise yerinde güncelle, değilse ekle
                    if let last = consoleOutput.last, isProgressBar(last) {
                        consoleOutput[consoleOutput.count - 1] = clean
                    } else {
                        consoleOutput.append(clean)
                    }
                }
            )

            if r.isSuccess {
                setupItems[i].status = .installed
                consoleOutput.append("✅ \(item.name) kuruldu")

            } else {
                setupItems[i].status = .error(r.error.isEmpty ? "Çıkış kodu: \(r.exitCode)" : r.error)
                consoleOutput.append("❌ \(item.name) kurulamadı (kod: \(r.exitCode))")
                if !r.error.isEmpty { consoleOutput.append(r.error) }
            }

            checkAndAutoAdvance()
        }
    }
    
    private func createVirtualHostsFolder() {
        consoleOutput.append("▶️ VirtualHosts klasörü oluşturuluyor...")
        PathConfig.createRequiredDirectories()
        consoleOutput.append("✅ VirtualHosts klasörü oluşturuldu: \(PathConfig.vhostsDir)")
        
        // View'ı yenile için state güncellemesi tetikle
        refreshConfigView()
    }
    
    private func checkHttpdIncludesVHosts() -> Bool {
        guard let content = try? String(contentsOfFile: PathConfig.httpdConf, encoding: .utf8) else { return false }
        let lines = content.components(separatedBy: .newlines)
        return lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("#") && trimmed.contains("VirtualHosts/*.conf")
        }
    }
    
    private func checkHttpdIncludesPhpMyAdmin() -> Bool {
        guard let content = try? String(contentsOfFile: PathConfig.httpdConf, encoding: .utf8) else { return false }
        let lines = content.components(separatedBy: .newlines)
        return lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("#") && trimmed.contains("phpmyadmin.conf")
        }
    }
    
    private func checkHttpdModule(_ moduleName: String) -> Bool {
        guard let content = try? String(contentsOfFile: PathConfig.httpdConf, encoding: .utf8) else { return false }
        let lines = content.components(separatedBy: .newlines)
        return lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("LoadModule \(moduleName) ")
        }
    }
    
    private func showHttpdInstructions() {
        consoleOutput.append("📝 Apache yapılandırması için şu dosyayı kontrol edin:")
        consoleOutput.append("   \(PathConfig.httpdConf)")
        consoleOutput.append("ℹ️ Dosya Finder'da açılıyor...")
        NSWorkspace.shared.open(URL(fileURLWithPath: PathConfig.httpdConf))
    }

    private func configureApacheEnvironment() {
        consoleOutput.append("▶️ Apache yapılandırması hazırlanıyor...")

        guard FileManager.default.fileExists(atPath: PathConfig.httpdConf) else {
            consoleOutput.append("❌ httpd.conf bulunamadı: \(PathConfig.httpdConf)")
            refreshConfigView()
            return
        }

        // YEDEK → YAZ → configtest → GEÇMEZSE GERİ AL.
        //
        // Sihirbaz `httpd.conf`u — makinedeki PAYLAŞILAN Apache yapılandırmasını —
        // doğrudan düzenliyor: port, ServerName, include satırları, modüller. Bunlardan
        // biri Apache'yi başlatılamaz hâle getirirse geriye dönecek bir kopya yoktu ve
        // kullanıcı hangi satırın bozduğunu elle bulmak zorunda kalıyordu.
        let httpdBackup = PathConfig.httpdConf + ".brampp.bak"
        guard let httpdBefore = FileHelper.readString(PathConfig.httpdConf) else {
            consoleOutput.append("❌ httpd.conf okunamadı — dosyaya DOKUNULMADI")
            refreshConfigView(); return
        }
        guard FileHelper.write(httpdBefore, to: httpdBackup) else {
            consoleOutput.append("❌ httpd.conf yedeklenemedi — dosyaya DOKUNULMADI")
            refreshConfigView(); return
        }

        PathConfig.createRequiredDirectories()
        createPhpMyAdminConfig()
        let mainConfigResult = normalizeApacheMainConfig()

        var includeResults = [
            ensureApacheIncludeEnabled(VHostTemplates.virtualHostsIncludeConfig(), in: PathConfig.httpdConf),
            ensureApacheIncludeEnabled(VHostTemplates.phpmyadminIncludeConfig(), in: PathConfig.httpdConf)
        ]

        // SSL include SADECE httpd-ssl.conf gerçekten varsa eklenir — aksi halde Apache
        // "Could not open configuration file" ile başlatılamaz. Dinamik brew yolu (Intel/ARM).
        // Dosya yoksa localhost SSL adımı onu yazınca include o adımda eklenir.
        if FileManager.default.fileExists(atPath: PathConfig.httpdSSLConf) {
            includeResults.append(
                ensureApacheIncludeEnabled("Include \"\(PathConfig.httpdSSLConf)\"", in: PathConfig.httpdConf)
            )
        } else {
            consoleOutput.append("ℹ️ httpd-ssl.conf henüz yok — SSL include, localhost SSL adımında eklenecek")
        }

        let moduleResults = apacheModuleDefinitions.map {
            FileHelper.ensureApacheModule($0.name, loadPath: $0.path, in: PathConfig.httpdConf)
        }

        var hasFailures = !mainConfigResult || includeResults.contains(false) || moduleResults.contains(false)

        // Yazım "başarılı" olsa bile Apache'nin bu yapılandırmayı KABUL ETTİĞİ ayrı bir
        // sorudur. `configtest` geçmezse yazdıklarımız geri alınır: bozuk bir httpd.conf
        // yalnızca bu adımı değil, sonraki her başlatmayı da düşürür.
        if !hasFailures {
            // `brewBash`in eşzamanlı hâli yok; `bash` aynı kabuğu kullanıyor ve
            // `isBrewInstalled` bu adıma girilmeden önce zaten doğrulanmış oluyor.
            let test = Shell.bash("apachectl configtest 2>&1")
            if Diagnostics.configVerdict(server: "Apache", output: test.output,
                                         exitOK: test.isSuccess).level == .fail {
                if FileHelper.write(httpdBefore, to: PathConfig.httpdConf) {
                    consoleOutput.append("❌ configtest geçmedi — httpd.conf YEDEKTEN geri alındı")
                    consoleOutput.append(test.output.split(separator: "\n").prefix(3).joined(separator: "\n"))
                } else {
                    consoleOutput.append("❌ configtest geçmedi ve geri alma da başarısız — yedek: \(httpdBackup)")
                }
                hasFailures = true
            }
        }

        if hasFailures {
            consoleOutput.append("⚠️ Bazı Apache yapılandırmaları yazılamadı. Dosya izinlerini kontrol edin.")
            showHttpdInstructions()
        } else {
            consoleOutput.append("✅ Apache HTTP portu 80 olarak ayarlandı")
            consoleOutput.append("✅ ServerName ve ServerAdmin localhost için güncellendi")
            consoleOutput.append("✅ Apache include ve modül yapılandırmaları güncellendi")
            consoleOutput.append("ℹ️ Yapılandırma tamamlandı - durumu kontrol ediliyor...")
        }

        // Biraz bekle ve view'ı yenile
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            refreshConfigView()
        }
    }

    /// httpd.conf ÖZGÜN kodlamasıyla geri yazılır; okunamıyorsa DOKUNULMAZ
    /// (aksi halde tek bir Listen satırı için tüm Apache yapılandırması bozulur).
    @discardableResult
    private func normalizeApacheMainConfig() -> Bool {
        ConfigFileEditor.patch(PathConfig.httpdConf) { normalizedApacheMainConfig($0) } == .written
    }

    /// httpd.conf içeriğini BRAMPP'ın beklediği Listen/ServerName/ServerAdmin hâline getirir.
    /// Saf metin dönüşümü — dosya sistemine dokunmaz.
    private func normalizedApacheMainConfig(_ content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        var updatedLines: [String] = []
        var hasListen80 = false
        var hasServerName = false
        var hasServerAdmin = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Yorum satırlarına DOKUNMA — aksi halde yorumlu bir "#Listen 8080" aktifleştirilip
            // mevcut aktif "Listen 80" ile ÇAKIŞIR ve Apache "Address already in use" ile çöker.
            if trimmed.hasPrefix("#") {
                updatedLines.append(line)
                continue
            }

            // Aktif Listen 80/8080 satırlarını TEK bir "Listen 80"e indirge (dedup)
            if trimmed == "Listen 8080" || trimmed == "Listen 0.0.0.0:8080"
                || trimmed == "Listen 80" || trimmed == "Listen 0.0.0.0:80" {
                if !hasListen80 { updatedLines.append("Listen 80"); hasListen80 = true }
                continue   // fazlalık Listen satırlarını düş
            }

            if trimmed == "ServerName www.example.com:8080" ||
                trimmed == "ServerName www.example.com:80" ||
                trimmed == "ServerName localhost:8080" ||
                trimmed == "ServerName localhost:80" ||
                trimmed == "ServerName localhost" {
                if !hasServerName { updatedLines.append("ServerName localhost:80"); hasServerName = true }
                continue
            }

            if trimmed == "ServerAdmin you@example.com" ||
                trimmed == "ServerAdmin admin@example.com" {
                if !hasServerAdmin { updatedLines.append("ServerAdmin admin@localhost"); hasServerAdmin = true }
                continue
            }

            if trimmed.hasPrefix("ServerName ")  { hasServerName = true }
            if trimmed.hasPrefix("ServerAdmin ") { hasServerAdmin = true }

            updatedLines.append(line)
        }

        if !hasListen80 {
            updatedLines.insert("Listen 80", at: 0)
        }
        
        if !hasServerName {
            updatedLines.append("ServerName localhost:80")
        }
        
        if !hasServerAdmin {
            updatedLines.append("ServerAdmin admin@localhost")
        }

        return updatedLines.joined(separator: "\n")
    }

    /// httpd.conf ÖZGÜN kodlamasıyla geri yazılır; okunamıyorsa DOKUNULMAZ.
    @discardableResult
    private func normalizeLocalhostMainMapping() -> Bool {
        ConfigFileEditor.patch(PathConfig.httpdConf) { normalizedLocalhostMapping($0) } == .written
    }

    /// localhost DocumentRoot / Directory / PHP handler bloklarını yerine oturtur.
    /// Saf metin dönüşümü — dosya sistemine dokunmaz.
    private func normalizedLocalhostMapping(_ content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        var updatedLines: [String] = []
        var hasDocumentRoot = false
        var hasDirectory = false
        // "Eski FilesMatch'i gördüm" ile "yeni FilesMatch emit ettim" AYRI izlenir.
        // Aksi halde eski blok silinip yenisi eklenmediğinde PHP kaynak kodu düz servis edilir.
        var didEmitPHPHandler = false
        var isInsideLocalhostDirectoryBlock = false
        var skippedExistingFilesMatchBlock = false
        let fcgiPort = localhostFcgiPort

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "DocumentRoot \"/opt/homebrew/var/www\"" ||
                trimmed == "DocumentRoot \"/usr/local/var/www\"" ||
                trimmed == "DocumentRoot \"\(PathConfig.localhostDir)\"" {
                updatedLines.append("DocumentRoot \"\(PathConfig.localhostDir)\"")
                hasDocumentRoot = true
                continue
            }

            if trimmed == "<Directory \"/opt/homebrew/var/www\">" ||
                trimmed == "<Directory \"/usr/local/var/www\">" ||
                trimmed == "<Directory \"\(PathConfig.localhostDir)\">" {
                updatedLines.append("<Directory \"\(PathConfig.localhostDir)\">")
                hasDirectory = true
                isInsideLocalhostDirectoryBlock = true
                continue
            }

            // Eski FilesMatch bloğunu ATLA (yenisi aşağıda emit edilecek) — ama "handler var"
            // olarak İŞARETLEME; yalnızca gerçekten yeni blok yazınca didEmitPHPHandler=true.
            if trimmed == "<FilesMatch \\.php$>" {
                skippedExistingFilesMatchBlock = true
                continue
            }

            if skippedExistingFilesMatchBlock {
                if trimmed == "</FilesMatch>" {
                    skippedExistingFilesMatchBlock = false
                }
                continue
            }

            // Blok İÇİNDEKİ mevcut DirectoryIndex satırını ATLA — doğrusu aşağıda yeniden
            // yazılıyor. Korunursa her "Yapılandır" tıklamasında bir kopya daha eklenir ve
            // fonksiyon idempotent olmaz (httpd.conf zamanla aynı satırla şişer).
            if isInsideLocalhostDirectoryBlock && trimmed.hasPrefix("DirectoryIndex") {
                continue
            }

            if isInsideLocalhostDirectoryBlock && trimmed == "</Directory>" {
                updatedLines.append("    DirectoryIndex index.php index.html")
                updatedLines.append(line)
                updatedLines.append("")
                updatedLines.append("<FilesMatch \\.php$>")
                updatedLines.append("    SetHandler \"proxy:fcgi://127.0.0.1:\(fcgiPort)\"")
                updatedLines.append("</FilesMatch>")
                isInsideLocalhostDirectoryBlock = false
                didEmitPHPHandler = true
                continue
            }

            updatedLines.append(line)
        }

        if !hasDocumentRoot {
            updatedLines.append("DocumentRoot \"\(PathConfig.localhostDir)\"")
        }

        if !hasDirectory {
            updatedLines.append("<Directory \"\(PathConfig.localhostDir)\">")
            updatedLines.append("    Options Indexes FollowSymLinks")
            updatedLines.append("    AllowOverride All")
            updatedLines.append("    Require all granted")
            updatedLines.append("    DirectoryIndex index.php index.html")
            updatedLines.append("</Directory>")
        }

        // Yeni FilesMatch hiç yazılmadıysa MUTLAKA ekle — PHP handler eksikliği kaynak
        // kodun düz metin servis edilmesine (güvenlik açığı) yol açar.
        if !didEmitPHPHandler {
            updatedLines.append("")
            updatedLines.append("<FilesMatch \\.php$>")
            updatedLines.append("    SetHandler \"proxy:fcgi://127.0.0.1:\(fcgiPort)\"")
            updatedLines.append("</FilesMatch>")
        }

        return updatedLines.joined(separator: "\n")
    }

    @discardableResult
    private func ensureApacheIncludeEnabled(_ includeLine: String, in configPath: String) -> Bool {
        // Dosya VAR ama okunamıyorsa ASLA üzerine yazma — httpd.conf yalnızca include
        // satırıyla değiştirilip tüm Apache yapılandırması silinirdi.
        var content: String
        let enc: String.Encoding
        switch FileHelper.readStringDetailed(configPath) {
        case .ok(let s, let e): content = s; enc = e
        case .missing:          content = ""; enc = .utf8
        case .unreadable:
            consoleOutput.append("❌ \(configPath) okunamadı (bozuk kodlama?) — üzerine yazılmadı")
            return false
        }
        let trimmedInclude = includeLine.trimmingCharacters(in: .whitespaces)
        
        let normalizedTargets = Set([
            trimmedInclude,
            trimmedInclude.replacingOccurrences(of: "\"", with: "")
        ])
        
        let lines = content.components(separatedBy: .newlines)
        if lines.contains(where: { normalizedTargets.contains($0.trimmingCharacters(in: .whitespaces)) }) {
            return true
        }
        
        let commentedVariants = Set([
            "#\(trimmedInclude)",
            "# \(trimmedInclude)",
            "#\(trimmedInclude.replacingOccurrences(of: "\"", with: ""))",
            "# \(trimmedInclude.replacingOccurrences(of: "\"", with: ""))"
        ])
        
        var updatedLines: [String] = []
        var replaced = false
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if commentedVariants.contains(trimmed) {
                updatedLines.append(trimmedInclude)
                replaced = true
            } else {
                updatedLines.append(line)
            }
        }
        
        if replaced {
            let updatedContent = updatedLines.joined(separator: "\n")
            return FileHelper.write(updatedContent, to: configPath, encoding: enc)
        }
        
        if !content.isEmpty, !content.hasSuffix("\n") {
            content += "\n"
        }
        content += trimmedInclude + "\n"
        return FileHelper.write(content, to: configPath, encoding: enc)
    }
    
    private var apacheModuleDefinitions: [(name: String, path: String)] {
        [
            ("ssl_module", "lib/httpd/modules/mod_ssl.so"),
            ("http2_module", "lib/httpd/modules/mod_http2.so"),
            ("proxy_module", "lib/httpd/modules/mod_proxy.so"),
            ("proxy_fcgi_module", "lib/httpd/modules/mod_proxy_fcgi.so"),
            ("rewrite_module", "lib/httpd/modules/mod_rewrite.so"),
            ("vhost_alias_module", "lib/httpd/modules/mod_vhost_alias.so"),
            ("proxy_http_module", "lib/httpd/modules/mod_proxy_http.so"),
            ("proxy_wstunnel_module", "lib/httpd/modules/mod_proxy_wstunnel.so"),
            ("headers_module", "lib/httpd/modules/mod_headers.so"),
            ("socache_shmcb_module", "lib/httpd/modules/mod_socache_shmcb.so")
        ]
    }
    
    private func configurePHP83Environment() {
        consoleOutput.append("▶️ PHP 8.3 yapılandırması hazırlanıyor...")
        
        guard FileManager.default.fileExists(atPath: php83FpmConfigPath) else {
            consoleOutput.append("❌ PHP 8.3 www.conf bulunamadı: \(php83FpmConfigPath)")
            refreshConfigView()
            return
        }
        
        if PHPFPMConfigManager.normalize(for: "8.3") {
            consoleOutput.append("✅ PHP-FPM portu 9083 olarak ayarlandı")
            consoleOutput.append("✅ PHP 8.3 kullanıcı ve erişim ayarları güncellendi")
            consoleOutput.append("ℹ️ Yapılandırma tamamlandı - durumu kontrol ediliyor...")
        } else {
            consoleOutput.append("❌ PHP 8.3 yapılandırması yazılamadı")
        }
        
        // Biraz bekle ve view'ı yenile
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            refreshConfigView()
        }
    }

    private func createPhpMyAdminConfig() {
        consoleOutput.append("▶️ phpMyAdmin config oluşturuluyor...")
        // Apache include config'i her zaman güncellenebilir (bizim ürettiğimiz, kullanıcı düzenlemez).
        // config.inc.php ise kullanıcının düzenleyebileceği bir dosya — VARSA ÜZERİNE YAZMA
        // (aksi halde her "Yapılandır" tıklaması kullanıcı ayarlarını/blowfish_secret'ı siler).
        let apacheConfig = VHostTemplates.phpmyadminConfig(phpPort: AppSettings.load().defaultPHPVersion.port)

        try? FileManager.default.createDirectory(atPath: PathConfig.httpdExtra, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: "\(PathConfig.brewBase)/etc", withIntermediateDirectories: true)
        try? apacheConfig.write(toFile: PathConfig.phpmyadminConf, atomically: true, encoding: .utf8)
        consoleOutput.append("✅ phpMyAdmin Apache yapılandırması oluşturuldu")

        if FileManager.default.fileExists(atPath: PathConfig.phpmyadminAppConfig) {
            consoleOutput.append("ℹ️ config.inc.php zaten var — korunuyor (üzerine yazılmadı)")
        } else {
            let appConfig = VHostTemplates.phpmyadminLocalConfig()
            try? appConfig.write(toFile: PathConfig.phpmyadminAppConfig, atomically: true, encoding: .utf8)
            consoleOutput.append("✅ phpMyAdmin localhost yapılandırma dosyası oluşturuldu")
        }
    }

    private func setupLocalhostEnvironment() {
        consoleOutput.append("▶️ localhost ortamı hazırlanıyor...")

        if !apacheCheckItems.allSatisfy(\.isComplete) {
            consoleOutput.append("⚠️ Önce Apache yapılandırmasını tamamlayın")
            refreshConfigView()
            return
        }

        if !php83CheckItems.allSatisfy(\.isComplete) {
            consoleOutput.append("⚠️ Önce PHP 8.3 yapılandırmasını tamamlayın")
            refreshConfigView()
            return
        }

        if !mkcertCheckItems.allSatisfy(\.isComplete) {
            consoleOutput.append("⚠️ Önce mkcert yapılandırmasını tamamlayın")
            refreshConfigView()
            return
        }

        PathConfig.createRequiredDirectories()
        FileHelper.createDirectory(PathConfig.localhostDir)
        FileHelper.createDirectory(PathConfig.localhostSSLDir)
        _ = normalizeLocalhostMainMapping()

        let indexPath = "\(PathConfig.localhostDir)/index.php"
        if !FileManager.default.fileExists(atPath: indexPath) {
            let sample = VHostTemplates.samplePHP(domain: "localhost", phpVersion: "8.3")
            try? sample.write(toFile: indexPath, atomically: true, encoding: .utf8)
            consoleOutput.append("✅ localhost index dosyası oluşturuldu")
        }

        Task {
            // Sertifika üretim sonucunu kontrol et — başarısızsa ölü cert yollu SSL vhost
            // yazma (Apache SSL başlatılamaz) ve yanlış "başarılı" raporlama.
            let certOK = await mkcertManager.generateCertificate(for: "localhost") { message, _ in
                consoleOutput.append(message)
            }
            let certExists = FileHelper.exists("\(PathConfig.localhostSSLDir)/cert.pem")
                          && FileHelper.exists("\(PathConfig.localhostSSLDir)/key.pem")

            await MainActor.run {
                consoleOutput.append("✅ Ana DocumentRoot, DirectoryIndex ve PHP eşlemesi localhost için ayarlandı")
                if certOK && certExists {
                    consoleOutput.append("✅ mkcert ile localhost sertifikası oluşturuldu")
                    createLocalhostSSLConfig()   // SSL vhost + include yalnızca cert varsa
                    consoleOutput.append("✅ localhost için HTTPS yayını hazırlandı")
                } else {
                    consoleOutput.append("⚠️ localhost SSL sertifikası oluşturulamadı — HTTPS atlandı (yalnızca HTTP)")
                    consoleOutput.append("ℹ️ SSL sekmesinden mkcert CA'yı kurup tekrar deneyin")
                }
                consoleOutput.append("ℹ️ Yapılandırma tamamlandı - durumu kontrol ediliyor...")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    refreshConfigView()
                }
            }
        }
    }

    private func createLocalhostSSLConfig() {
        // Port SABİT 443 DEĞİL: kullanıcı Servisler → Apache Portları'ndan HTTPS portunu
        // değiştirmiş olabilir. `apacheHTTPS()` httpd-ssl.conf'taki mevcut `Listen`i okur
        // (yoksa 443'e düşer) — böylece bu dosyanın yeniden üretilmesi ayarı SIFIRLAMAZ.
        let httpsPort = WebServerPorts.apacheHTTPS()

        let config = """
        Listen \(httpsPort)

        <VirtualHost _default_:\(httpsPort)>
            ServerName localhost:\(httpsPort)
            ServerAlias localhost
            DocumentRoot "\(PathConfig.localhostDir)"

            SSLEngine on
            SSLCertificateFile "\(PathConfig.localhostSSLDir)/cert.pem"
            SSLCertificateKeyFile "\(PathConfig.localhostSSLDir)/key.pem"

            Protocols h2 http/1.1

            <FilesMatch \\.php$>
                SetHandler "proxy:fcgi://127.0.0.1:\(localhostFcgiPort)"
            </FilesMatch>

            <Directory "\(PathConfig.localhostDir)">
                Options Indexes FollowSymLinks
                AllowOverride All
                Require all granted
                DirectoryIndex index.php index.html
            </Directory>

            ErrorLog "\(PathConfig.httpdLogs)/localhost-ssl-error.log"
            CustomLog "\(PathConfig.httpdLogs)/localhost-ssl-access.log" combined
        </VirtualHost>
        """

        // Include yalnızca dosya GERÇEKTEN yazıldıysa eklenmeli: var olmayan dosyaya
        // işaret eden Include, Apache'nin hiç başlamamasına yol açar.
        // ÜZERİNE YAZMADAN ÖNCE YEDEK. Bu dosya bütünüyle yeniden yazılıyor: Homebrew'un
        // stok hâli `original/` kopyasından kurtarılabilir ama kullanıcının BU dosyaya
        // elle eklediği `<VirtualHost>` blokları kurtarılamaz. Yedek alınamıyorsa
        // yazıma hiç girilmez — geri dönüşü olmayan bir işlem için "belki almışızdır"
        // yeterli değil.
        if FileHelper.exists(PathConfig.httpdSSLConf) {
            let backup = PathConfig.httpdSSLConf + ".brampp.bak"
            guard let current = FileHelper.readString(PathConfig.httpdSSLConf),
                  FileHelper.write(current, to: backup) else {
                consoleOutput.append("❌ httpd-ssl.conf yedeklenemedi — dosyaya DOKUNULMADI")
                return
            }
            consoleOutput.append("ℹ️  Önceki httpd-ssl.conf yedeklendi: \(backup)")
        }

        if FileHelper.write(config, to: PathConfig.httpdSSLConf) {
            consoleOutput.append("✅ httpd-ssl.conf localhost için güncellendi (HTTPS :\(httpsPort))")
            if ensureApacheIncludeEnabled("Include \"\(PathConfig.httpdSSLConf)\"", in: PathConfig.httpdConf) {
                consoleOutput.append("✅ httpd.conf'a SSL include eklendi")
            }
        } else {
            consoleOutput.append("❌ httpd-ssl.conf yazılamadı — HTTPS atlandı (yalnızca HTTP)")
        }
    }
    
    /// Yapılandırma view'ını yenile (checkmark'ları güncelle)
    private func refreshConfigView() {
        // State toggle ile view'ı yenilemeye zorla
        configRefreshTrigger.toggle()
    }
    
    private func installMkcertCA() {
        consoleOutput.append("▶️ mkcert CA kurulumu başlatılıyor...")
        Task {
            _ = await mkcertManager.installCA { message, type in
                consoleOutput.append(message)
            }
            
            consoleOutput.append("ℹ️ Yapılandırma tamamlandı - durumu kontrol ediliyor...")
            
            // View'ı yenile
            await MainActor.run {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    refreshConfigView()
                }
            }
        }
    }
    
    // MARK: - Complete
    
    private func completeSetup() {
        var settings = AppSettings.load()
        settings.firstSetupCompleted = true
        settings.save()
        PathConfig.createRequiredDirectories()
        onComplete()
    }
}

#Preview {
    SetupWizardView(onComplete: {})
        .environmentObject(Localizer.shared)
}

