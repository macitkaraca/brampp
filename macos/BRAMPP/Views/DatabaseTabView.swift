import SwiftUI
import UniformTypeIdentifiers

/// Veritabanı yönetim paneli — MariaDB ve PostgreSQL
struct DatabaseTabView: View {
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var serviceManager: ServiceManager
    @EnvironmentObject var consoleStore: ConsoleStore

    @State private var selectedDB: DatabaseType = .mariadb
    @State private var databases: [String] = []
    @State private var isLoadingDBs: Bool = false
    @State private var newDBName: String = ""
    @State private var showCreateSheet: Bool = false
    // Dump / Restore (yedek al – geri yükle)
    @State private var isBackupBusy: Bool = false
    @State private var showRestoreSheet: Bool = false
    @State private var restoreFileURL: URL? = nil
    @State private var restoreDBName: String = ""
    // pgAdmin / Adminer kaldırma onayları
    @State private var showPgAdminRemoveAlert: Bool = false
    @State private var showAdminerRemoveAlert: Bool = false
    // Kritik DB hataları — konsol kapalı olabileceğinden alert ile de gösterilir
    @State private var dbErrorMessage: String? = nil
    @State private var pgSettings: [PGSetting] = PGSetting.defaults
    @State private var myCnfSettings: [PGSetting] = PGSetting.mariadbDefaults
    @State private var redisSettings: [PGSetting] = PGSetting.redisDefaults
    // Redis canlı durumu — talep üzerine `redis-cli INFO` ile okunur.
    // Otomatik yenileme YOK: sekme açık dururken saniyede bir kabuk çağırmak
    // pil ve CPU açısından bedelli, üstelik veri o hızda değişmiyor.
    @State private var redisStats: RedisStats?
    @State private var redisLoading = false
    @State private var dbToDelete: String? = nil
    @State private var showDropAlert: Bool = false
    /// ServiceManager kurulumu başladığında InstallationProgressSheet'i açar
    @State private var showInstallLog: Bool = false
    /// Seçili PostgreSQL versiyonu (postgresql@17, postgresql@16, …)
    @State private var selectedPGVersion: String = ""
    /// loadDatabases yarış koruması — her çağrı bir token alır; yalnızca en güncel
    /// token'ın sonucu uygulanır (hızlı DB/sürüm değişiminde eski sonuç eziyordu).
    @State private var loadToken: Int = 0
    /// MariaDB root@localhost TCP erişimi yapılandırılmış mı?
    /// nil = henüz kontrol edilmedi / bilinmiyor (MariaDB çalışmıyor).
    @State private var rootTCPConfigured: Bool? = nil

    private var isPgAdminInstalled: Bool {
        PathConfig.isPgAdmin4Installed
    }

    private var isPgAdminApacheConfigured: Bool {
        FileHelper.exists(PathConfig.pgadmin4Conf)
    }

    private var isPgAdminNginxConfigured: Bool {
        NginxConfigManager.isPgAdmin4Configured
    }

    private var isPhpMyAdminInstalled: Bool {
        PathConfig.isPhpMyAdminInstalled
    }

    enum DatabaseType: String, CaseIterable {
        case mariadb = "MariaDB"
        case postgresql = "PostgreSQL"
        case redis = "Redis"
    }

    /// Kurulu/yüklü PostgreSQL versiyonları (notInstalled olmayanlar)
    private var availablePGVersions: [String] {
        serviceManager.services
            .filter { $0.id.hasPrefix("postgresql@") && $0.status != .notInstalled }
            .map { $0.id.replacingOccurrences(of: "postgresql@", with: "") }
            .sorted(by: >)          // 17, 16, 15... sırasıyla
    }

    private var dbService: Service? {
        switch selectedDB {
        case .postgresql:
            let ver = selectedPGVersion.isEmpty ? (availablePGVersions.first ?? "") : selectedPGVersion
            return serviceManager.services.first { $0.id == "postgresql@\(ver)" }
        case .mariadb:
            return serviceManager.services.first { $0.id == "mariadb" }
        case .redis:
            return serviceManager.services.first { $0.id == "redis" }
        }
    }

    private var isDBRunning: Bool {
        dbService?.status == .running
    }

    private var pgVersion: String {
        selectedPGVersion.isEmpty ? (availablePGVersions.first ?? "") : selectedPGVersion
    }

    var body: some View {
        VStack(spacing: 0) {
            // DB seçici + PG versiyon picker + durum
            HStack(spacing: 12) {
                Picker("", selection: $selectedDB) {
                    ForEach(DatabaseType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 250)

                // PostgreSQL versiyonu — birden fazla kuruluysa göster
                if selectedDB == .postgresql && availablePGVersions.count > 1 {
                    Divider().frame(height: 20)
                    Text(loc.t("db.version")).font(.caption).foregroundColor(.secondary)
                    Picker("", selection: $selectedPGVersion) {
                        ForEach(availablePGVersions, id: \.self) { v in
                            Text("PG \(v)").tag(v)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }

                Spacer()

                if let svc = dbService {
                    HStack(spacing: 6) {
                        Circle().fill(svc.status.color).frame(width: 8, height: 8)
                        Text(svc.status.displayName).font(.caption).foregroundColor(.secondary)
                        if let port = svc.port {
                            Text(verbatim: ":\(port)").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding()

            Divider()

            if dbService == nil || dbService?.status == .notInstalled {
                notInstalledView
            } else if !isDBRunning {
                stoppedView
            } else {
                switch selectedDB {
                case .postgresql:
                    postgresqlPanel
                case .mariadb:
                    mariadbPanel
                case .redis:
                    redisPanel
                        // Sekme açıldığında bir kez oku; sonrası yenile düğmesiyle.
                        .onAppear { if redisStats == nil { loadRedisStats() } }
                }
            }
        }
        .onChange(of: selectedDB) {
            // Versiyon seçimini sıfırla ve DB'leri yeniden yükle
            selectedPGVersion = availablePGVersions.first ?? ""
            loadDatabases()
        }
        .onChange(of: selectedPGVersion) {
            loadDatabases()
            // Sürüm değişince ayarları da yeniden yükle — aksi halde eski sürümün
            // değerleri yeni sürümün postgresql.conf'una yazılırdı.
            if !pgVersion.isEmpty { loadPGSettings(version: pgVersion) }
        }
        .onAppear {
            selectedPGVersion = availablePGVersions.first ?? ""
            loadDatabases()
        }
        // ServiceManager'daki kurulum (phpMyAdmin/pgAdmin) başladığında sheet'i aç
        .onChange(of: serviceManager.isInstalling) { _, installing in
            if installing { showInstallLog = true }
        }
        // Seçili DB servisi başlatılınca/durunca listeyi otomatik yenile
        .onChange(of: dbService?.status) { _, _ in
            loadDatabases()
            // Servis durumu değişince root@localhost TCP erişimi de yeniden ölçülmeli
            Task { await checkMariaDBRootTCP() }
        }
        .sheet(isPresented: $showInstallLog) {
            InstallationProgressSheet(serviceManager: serviceManager, isPresented: $showInstallLog)
        }
        .alert(loc.t("db.deleteTitle"), isPresented: $showDropAlert, presenting: dbToDelete) { db in
            Button(loc.t("common.cancel"), role: .cancel) { dbToDelete = nil }
            Button(loc.t("db.delete"), role: .destructive) { dropDatabase(db); dbToDelete = nil }
        } message: { db in
            Text(String(format: loc.t("db.deleteConfirm"), db))
        }
        .alert(loc.t("db.pgadmin.removeTitle"), isPresented: $showPgAdminRemoveAlert) {
            Button(loc.t("common.cancel"), role: .cancel) { }
            Button(loc.t("common.remove"), role: .destructive) { serviceManager.uninstallPgAdmin4() }
        } message: {
            Text(loc.t("db.pgadmin.removeMsg"))
        }
        .alert(loc.t("db.adminer.removeTitle"), isPresented: $showAdminerRemoveAlert) {
            Button(loc.t("common.cancel"), role: .cancel) { }
            Button(loc.t("common.remove"), role: .destructive) { serviceManager.uninstallAdminer() }
        } message: {
            Text(loc.t("db.adminer.removeMsg"))
        }
        .alert(loc.t("db.opError"), isPresented: Binding(
            get: { dbErrorMessage != nil },
            set: { if !$0 { dbErrorMessage = nil } }
        )) {
            Button(loc.t("common.ok"), role: .cancel) { dbErrorMessage = nil }
        } message: {
            Text(dbErrorMessage ?? "")
        }
    }

    /// Hem konsola yazar hem alert gösterir — kritik hatalar konsol kapalıyken de görünür.
    private func reportDBError(_ message: String) {
        consoleStore.log(message, type: .error)
        dbErrorMessage = message
    }

    // MARK: - Adminer Bölümü (her iki panelde ortak)

    private var isAdminerInstalled: Bool { PathConfig.isAdminerInstalled }
    private var isAdminerApacheConfigured: Bool { FileHelper.exists(PathConfig.adminerConf) }
    private var isAdminerNginxConfigured: Bool { NginxConfigManager.isAdminerConfigured }

    /// Adminer: tek dosyalık, hem MySQL/MariaDB hem PostgreSQL yöneten hafif web arayüzü.
    /// Her iki veritabanı panelinde de gösterilir (iki motoru da tek yerden yönetir).
    private var adminerSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Adminer")
                                .fontWeight(.medium)
                            Text("• \(loc.t("db.adminerTag"))")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        if isAdminerInstalled {
                            Text("localhost/adminer")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.accentColor)
                        } else {
                            Text(loc.t("db.adminerDesc"))
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    if isAdminerInstalled {
                        Button(action: openAdminer) {
                            Label(loc.t("db.adminerOpen"), systemImage: "safari")
                                .font(.callout)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.teal)
                        .help(loc.t("db.adminerOpenHelp"))
                        Button(role: .destructive) {
                            showAdminerRemoveAlert = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bordered)
                        .help(loc.t("db.adminerRemoveHelp"))
                    } else {
                        Button(action: { serviceManager.installAdminer() }) {
                            Label(loc.t("db.adminerInstall"), systemImage: "arrow.down.circle")
                                .font(.callout)
                        }
                        .buttonStyle(.bordered)
                        .disabled(serviceManager.isInstalling)
                        .help(loc.t("db.adminerInstallHelp"))
                    }
                }

                if isAdminerInstalled {
                    Divider()
                    // Adminer'de AYRI port alanı yoktur — port "Sunucu" alanına host:port
                    // olarak yazılır. Birden fazla PG sürümü farklı portlarda çalıştığından
                    // seçili sürümün doğru adresi burada hazır gösterilir (kopyalanabilir).
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.caption).foregroundColor(.secondary)
                        Text(adminerConnectionHint)
                            .font(.caption).foregroundColor(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        Text(loc.t("db.adminerWeb"))
                            .font(.caption).fontWeight(.medium).foregroundColor(.secondary)
                        // Apache durumu
                        HStack(spacing: 4) {
                            Image(systemName: isAdminerApacheConfigured ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(isAdminerApacheConfigured ? .green : .red)
                                .font(.caption)
                            Text("Apache").font(.caption)
                            if !isAdminerApacheConfigured {
                                Button("Ayarla") { Task { await serviceManager.configureAdminerForApache() } }
                                    .controlSize(.mini)
                            }
                        }
                        Divider().frame(height: 14)
                        // Nginx durumu
                        HStack(spacing: 4) {
                            Image(systemName: isAdminerNginxConfigured ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(isAdminerNginxConfigured ? .green : .red)
                                .font(.caption)
                            Text("Nginx").font(.caption)
                            if !isAdminerNginxConfigured && PathConfig.isNginxInstalled {
                                Button("Ayarla") { Task { await serviceManager.configureAdminerForNginx() } }
                                    .controlSize(.mini)
                            }
                        }
                        Spacer()
                    }
                }
            }
            .padding(4)
        }
    }

    /// Adminer giriş ekranı için seçili motora göre doğru bağlantı bilgisi.
    /// Port, "Sunucu" alanına host:port biçiminde yazılır (Adminer'de ayrı port alanı yok).
    private var adminerConnectionHint: String {
        switch selectedDB {
        case .mariadb:
            return loc.t("db.adminerHintMysql")
        case .postgresql:
            let port = dbService?.port ?? 5432
            let ver  = pgVersion.isEmpty ? "" : " (PG \(pgVersion))"
            return String(format: loc.t("db.adminerHintPg"), "127.0.0.1:\(port)\(ver)")
        case .redis:
            return ""   // Adminer Redis'i desteklemez; bu bölüm Redis panelinde gösterilmiyor
        }
    }

    private func openAdminer() {
        // Apache yapılandırıldıysa 80/443; değilse Nginx 8080
        let urlString: String
        if isAdminerApacheConfigured {
            urlString = "https://localhost/adminer/"
        } else {
            urlString = "http://localhost:8080/adminer/"
        }
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Not Installed View

    private var notInstalledView: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.xmark")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text(String(format: loc.t("db.notInstalled"), selectedDB.rawValue))
                .font(.title3)
            Text(loc.t("db.installFromServices"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Stopped View

    private var stoppedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "stop.circle")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            Text(String(format: loc.t("db.notRunning"), selectedDB.rawValue))
                .font(.title3)
            Button(loc.t("common.start")) {
                if let svc = dbService {
                    serviceManager.startService(svc)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - PostgreSQL Panel

    private var postgresqlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Bağlantı bilgileri
                GroupBox(String(format: loc.t("db.conn.pg"), pgVersion)) {
                    VStack(alignment: .leading, spacing: 8) {
                        infoRow("Host",     value: "127.0.0.1")
                        infoRow("Port",     value: "\(dbService?.port ?? 5432)")
                        infoRow(loc.t("db.user"), value: "postgres")
                        infoRow(loc.t("db.password"),   value: loc.t("db.empty"))
                        infoRow(loc.t("db.command"),    value: "psql -h 127.0.0.1 -U postgres")

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loc.t("db.pg.firstConfig"))
                                    .font(.caption).fontWeight(.medium)
                                Text(loc.t("db.pg.firstConfigDesc"))
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(action: {
                                if !pgVersion.isEmpty {
                                    serviceManager.configurePGInitial(version: pgVersion)
                                }
                            }) {
                                Label(loc.t("db.configure"), systemImage: "wrench.and.screwdriver")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered).controlSize(.small).tint(.orange)
                            .disabled(pgVersion.isEmpty)
                            .help(loc.t("db.pgConfigHelp"))
                        }
                    }
                    .padding(8)
                }

                // pgAdmin4 (web version)
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("pgAdmin 4")
                                    .font(.headline)
                                Text(loc.t("db.pgadmin.desc"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if isPgAdminInstalled {
                                    HStack(spacing: 6) {
                                        Text("localhost/pgadmin4")
                                            .font(.caption)
                                            .fontWeight(.medium)
                                            .foregroundColor(.accentColor)
                                        Text("• port \(PathConfig.pgadmin4Port)")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            if isPgAdminInstalled {
                                Button(action: openPgAdmin) {
                                    Label(loc.t("db.pgadmin.open"), systemImage: "safari")
                                        .font(.callout)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.blue)
                                .disabled(dbService?.status != .running)
                                .help(loc.t("db.pgadminOpenHelp"))
                                Button(role: .destructive) {
                                    showPgAdminRemoveAlert = true
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.bordered)
                                .disabled(serviceManager.isInstalling)
                                .help(loc.t("db.pgadminRemoveHelp"))
                            } else {
                                Button(action: { installPgAdmin() }) {
                                    Label(loc.t("db.pgadminInstall"), systemImage: "arrow.down.circle")
                                        .font(.callout)
                                }
                                .buttonStyle(.bordered)
                                .disabled(!Shell.isBrewInstalled || serviceManager.isInstalling)
                                .help("brew install pgadmin4")
                            }
                        }

                        if isPgAdminInstalled {
                            Divider()

                            // Web sunucusu yapılandırma durumu
                            VStack(alignment: .leading, spacing: 6) {
                                Text(loc.t("db.webConfig"))
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.secondary)

                                HStack(spacing: 8) {
                                    // Apache
                                    HStack(spacing: 4) {
                                        Image(systemName: isPgAdminApacheConfigured ? "checkmark.circle.fill" : "xmark.circle.fill")
                                            .foregroundColor(isPgAdminApacheConfigured ? .green : .red)
                                            .font(.caption)
                                        Text("Apache")
                                            .font(.caption)
                                        if !isPgAdminApacheConfigured {
                                            Button("Ayarla") {
                                                Task { await configurePgAdmin4ForApache() }
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.mini)
                                            .tint(.orange)
                                        }
                                    }

                                    Divider().frame(height: 16)

                                    // Nginx
                                    HStack(spacing: 4) {
                                        Image(systemName: isPgAdminNginxConfigured ? "checkmark.circle.fill" : "xmark.circle.fill")
                                            .foregroundColor(isPgAdminNginxConfigured ? .green : .red)
                                            .font(.caption)
                                        Text("Nginx")
                                            .font(.caption)
                                        if PathConfig.isNginxInstalled && !isPgAdminNginxConfigured {
                                            Button("Ayarla") {
                                                Task { await configurePgAdmin4ForNginx() }
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.mini)
                                            .tint(.orange)
                                        } else if !PathConfig.isNginxInstalled {
                                            Text(loc.t("db.notInstalledShort"))
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(8)
                }

                // Adminer — hafif web DB yöneticisi (PostgreSQL de destekler)
                adminerSection

                // Veritabanları
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(loc.t("db.databases"))
                                .font(.headline)
                            Spacer()
                            Button(action: loadDatabases) {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .disabled(isBackupBusy)
                            Button(loc.t("db.restore")) {
                                pickRestoreFile()
                            }
                            .controlSize(.small)
                            .disabled(isBackupBusy)
                            .help(loc.t("db.restore.help"))
                            Button(loc.t("db.newDB")) {
                                showCreateSheet = true
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(isBackupBusy)
                        }

                        if isLoadingDBs {
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding()
                        } else if databases.isEmpty {
                            Text(loc.t("db.noDatabases"))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding()
                        } else {
                            ForEach(databases, id: \.self) { db in
                                HStack {
                                    Image(systemName: "cylinder")
                                        .foregroundColor(.accentColor)
                                    Text(db)
                                        .font(.system(.body, design: .monospaced))
                                    Spacer()
                                    Button {
                                        dumpDatabase(db)
                                    } label: {
                                        Image(systemName: "square.and.arrow.down")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(isBackupBusy)
                                    .help(loc.t("db.dump.help"))
                                    if db != "postgres" && db != "template0" && db != "template1" {
                                        Button(role: .destructive) {
                                            // MariaDB ile tutarlı: doğrudan silme yerine onay diyaloğu
                                            dbToDelete = db
                                            showDropAlert = true
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.caption)
                                        }
                                        .buttonStyle(.borderless)
                                        .disabled(isBackupBusy)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .padding(8)
                }

                // PostgreSQL Ayarları
                if !pgVersion.isEmpty {
                    GroupBox("postgresql.conf") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach($pgSettings) { $setting in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(setting.name)
                                            .font(.system(.body, design: .monospaced))
                                        Text(loc.t(setting.description))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    TextField("", text: $setting.value)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 120)
                                }
                            }

                            Button(loc.t("db.saveSettings")) {
                                savePGSettings(version: pgVersion)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(8)
                    }
                    .onAppear { loadPGSettings(version: pgVersion) }
                }
            }
            .padding()
        }
        .sheet(isPresented: $showCreateSheet) {
            createDatabaseSheet
        }
        .sheet(isPresented: $showRestoreSheet) {
            restoreDatabaseSheet
        }
    }

    // MARK: - MariaDB Panel

    private var mariadbPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox(loc.t("db.conn.maria")) {
                    VStack(alignment: .leading, spacing: 8) {
                        infoRow("Host", value: "127.0.0.1")
                        infoRow("Port", value: "3306")
                        infoRow(loc.t("db.user"), value: "root")
                        infoRow(loc.t("db.password"), value: loc.t("db.empty"))
                        infoRow(loc.t("db.command"), value: "mysql -u root")

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loc.t("db.mariaTCP"))
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Text(loc.t("db.mariaTCPDesc"))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if rootTCPConfigured == true {
                                // Yapılandırma zaten yapılmış — butona gerek yok
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text(loc.t("db.mariaTCPOk"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            } else {
                                Button(action: {
                                    Task {
                                        await serviceManager.configureMariaDBRoot()
                                        // Yapılandırma bittiğinde satır anında yeşile dönsün
                                        await checkMariaDBRootTCP()
                                    }
                                }) {
                                    Label(loc.t("db.mariaTCPConfig"), systemImage: "wrench.and.screwdriver")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(.orange)
                            }
                        }
                    }
                    .padding(8)
                }
                // Bölüm görünür olduğunda mevcut durumu ölç
                .task { await checkMariaDBRootTCP() }

                // phpMyAdmin
                GroupBox {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("phpMyAdmin")
                                .font(.headline)
                            Text(loc.t("db.pma.desc"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if isPhpMyAdminInstalled {
                            Button(action: {
                                if let url = URL(string: "https://localhost/phpmyadmin") {
                                    NSWorkspace.shared.open(url)
                                }
                            }) {
                                Label(loc.t("db.pma.open"), systemImage: "safari")
                                    .font(.callout)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                            .disabled(dbService?.status != .running)
                        } else {
                            Button(action: { installPhpMyAdmin() }) {
                                Label(loc.t("db.phpMyAdminInstall"), systemImage: "arrow.down.circle")
                                    .font(.callout)
                            }
                            .buttonStyle(.bordered)
                            .disabled(!Shell.isBrewInstalled || serviceManager.isInstalling)
                        }
                    }
                    .padding(8)
                }

                // Adminer — hafif web DB yöneticisi (MariaDB + PostgreSQL tek arayüz)
                adminerSection

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(loc.t("db.databases"))
                                .font(.headline)
                            Spacer()
                            Button(action: loadDatabases) {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .disabled(isBackupBusy)
                            Button(loc.t("db.restore")) {
                                pickRestoreFile()
                            }
                            .controlSize(.small)
                            .disabled(isBackupBusy)
                            .help(loc.t("db.restore.help"))
                            Button(loc.t("db.newDB")) {
                                showCreateSheet = true
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(isBackupBusy)
                        }

                        if isLoadingDBs {
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding()
                        } else if databases.isEmpty {
                            Text(loc.t("db.noDatabases"))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding()
                        } else {
                            let systemDBs = ["information_schema", "performance_schema", "mysql", "sys"]
                            ForEach(databases, id: \.self) { db in
                                HStack {
                                    Image(systemName: "cylinder")
                                        .foregroundColor(.accentColor)
                                    Text(db)
                                        .font(.system(.body, design: .monospaced))
                                    Spacer()
                                    if !systemDBs.contains(db) {
                                        Button {
                                            dumpDatabase(db)
                                        } label: {
                                            Image(systemName: "square.and.arrow.down")
                                                .font(.caption)
                                        }
                                        .buttonStyle(.borderless)
                                        .disabled(isBackupBusy)
                                        .help(loc.t("db.dump.help"))
                                        Button(role: .destructive) {
                                            dbToDelete = db
                                            showDropAlert = true
                                        } label: {
                                            Image(systemName: "trash")
                                                .font(.caption)
                                        }
                                        .buttonStyle(.borderless)
                                        .disabled(isBackupBusy)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .padding(8)
                }
                .sheet(isPresented: $showCreateSheet) { createDatabaseSheet }
                .sheet(isPresented: $showRestoreSheet) { restoreDatabaseSheet }

                // my.cnf ayar paneli (PostgreSQL postgresql.conf paneliyle simetrik).
                // Homebrew my.cnf `!includedir my.cnf.d` kullandığından ayarlar KENDİ
                // dosyamıza (my.cnf.d/zz-brampp.cnf) yazılır — kullanıcının my.cnf'i korunur.
                GroupBox("my.cnf (MariaDB)") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach($myCnfSettings) { $setting in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(setting.name).font(.system(.body, design: .monospaced))
                                    Text(loc.t(setting.description)).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                TextField("", text: $setting.value)
                                    .textFieldStyle(.roundedBorder).frame(width: 120)
                            }
                        }
                        HStack {
                            Button(loc.t("db.saveSettings")) { saveMyCnfSettings() }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                            Text(loc.t("db.myCnfNote"))
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    .padding(8)
                }
                .onAppear { loadMyCnfSettings() }
            }
            .padding()
        }
    }

    /// root@localhost TCP erişiminin ZATEN yapılandırılmış olup olmadığını ölçer.
    ///
    /// SetupWizardView.checkMariaDBRootAuthAsync ile AYNI teknik: unix_socket auth TCP
    /// üzerinden çalışmadığından, TCP + boş parola ile bağlanabilmek hem "şifresiz"
    /// hem "native auth" demektir. Yalnızca MariaDB çalışırken anlamlıdır — servis
    /// durmuşken bağlantı zaten kurulamaz, bu yüzden sonuç "yapılandırılmamış" değil
    /// bilinmiyor (nil) bırakılır; aksi halde mevcut yapılandırma yok sanılırdı.
    private func checkMariaDBRootTCP() async {
        guard selectedDB == .mariadb, dbService?.status == .running else {
            rootTCPConfigured = nil
            return
        }
        let tcpTest = await Shell.bashAsync("mysql -u root -h 127.0.0.1 --connect-timeout=3 -e 'SELECT 1' 2>/dev/null")
        rootTCPConfigured = tcpTest.isSuccess
    }

    // MARK: - Redis Panel

    private var redisPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox(loc.t("db.conn.redis")) {
                    VStack(alignment: .leading, spacing: 8) {
                        infoRow("Host",       value: "127.0.0.1")
                        infoRow("Port",       value: "\(dbService?.port ?? 6379)")
                        infoRow("CLI",        value: "redis-cli")
                        infoRow(loc.t("db.database"), value: "0–15 (SELECT n)")
                    }
                    .padding(8)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(loc.t("db.redis.stats")).font(.headline)
                            Spacer()
                            Button {
                                loadRedisStats()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless).controlSize(.small)
                            .disabled(redisLoading)
                        }
                        if let s = redisStats {
                            infoRow(loc.t("db.redis.uptime"),
                                    value: s.uptimeSeconds.map(RedisStats.formatUptime) ?? "—")
                            infoRow(loc.t("db.redis.clients"), value: s.connectedClients.map(String.init) ?? "—")
                            infoRow(loc.t("db.redis.memory"),
                                    value: (s.usedMemory ?? "—") + (s.isMemoryUnlimited ? " / \(loc.t("db.redis.unlimited"))" : ""))
                            infoRow(loc.t("db.redis.peak"), value: s.peakMemory ?? "—")
                            infoRow(loc.t("db.redis.hitRate"),
                                    value: s.hitRate.map { String(format: "%%%.0f", $0 * 100) } ?? loc.t("db.redis.noData"))
                            infoRow(loc.t("db.redis.keys"),
                                    value: s.keyspace.isEmpty ? "0"
                                         : "\(s.totalKeys)  (" + s.keyspace.map { "db\($0.db): \($0.keys)" }.joined(separator: ", ") + ")")
                            infoRow(loc.t("db.redis.commands"), value: s.commandsProcessed.map(String.init) ?? "—")
                        } else {
                            Text(loc.t(redisLoading ? "common.loading" : "db.redis.stopped"))
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding(8)
                }

                GroupBox("redis.conf") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach($redisSettings) { $setting in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(setting.name).font(.system(.body, design: .monospaced))
                                    Text(loc.t(setting.description)).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                TextField("", text: $setting.value)
                                    .textFieldStyle(.roundedBorder).frame(width: 150)
                            }
                        }
                        HStack {
                            Button(loc.t("db.saveSettings")) { saveRedisSettings() }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                            Text(loc.t("db.redisNote"))
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    .padding(8)
                }

                GroupBox {
                    HStack {
                        Image(systemName: "info.circle").foregroundColor(.secondary)
                        Text(loc.t("db.redis.hint"))
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                    }.padding(8)
                }
            }
            .padding()
        }
        .onAppear { loadRedisSettings() }
    }

    // MARK: - Create DB Sheet

    private var createDatabaseSheet: some View {
        VStack(spacing: 16) {
            Text(loc.t("db.create.title"))
                .font(.headline)

            TextField(loc.t("db.create.name"), text: $newDBName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)

            HStack {
                Button(loc.t("common.cancel")) {
                    newDBName = ""
                    showCreateSheet = false
                }
                Button(loc.t("common.create")) {
                    createDatabase(newDBName)
                    newDBName = ""
                    showCreateSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newDBName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }

    // MARK: - Restore Sheet

    private var restoreDatabaseSheet: some View {
        VStack(spacing: 16) {
            Text(loc.t("db.restore.title"))
                .font(.headline)

            if let url = restoreFileURL {
                Label(url.lastPathComponent, systemImage: "doc.text")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(loc.t("db.restore.target")).font(.caption).foregroundColor(.secondary)
                TextField("veritabani_adi", text: $restoreDBName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }

            Text(loc.t("db.restore.warn"))
                .font(.caption)
                .foregroundColor(.orange)
                .frame(width: 280)
                .multilineTextAlignment(.center)

            HStack {
                Button(loc.t("common.cancel")) {
                    showRestoreSheet = false
                    restoreFileURL = nil
                }
                Button(loc.t("backup.restore")) {
                    showRestoreSheet = false
                    performRestore()
                }
                .buttonStyle(.borderedProminent)
                .disabled(restoreDBName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
    }

    // MARK: - Dump / Restore

    /// Tarih damgası — yedek dosya adları için (20260716-1430 gibi)
    /// Dosya adı damgası — en_US_POSIX + Gregoryen SABİT.
    /// Kullanıcının sistem takvimi Hicri/Budist ise yıl 2569 gibi çıkar, Farsça/Arapça
    /// rakam sisteminde ise ASCII olmayan rakamlar üretilir; dosya adı hem yanlış hem
    /// sıralanamaz olurdu.
    private static let backupStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale     = Locale(identifier: "en_US_POSIX")
        f.calendar   = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyyMMdd-HHmm"
        return f
    }()

    private var backupStamp: String { Self.backupStampFormatter.string(from: Date()) }

    /// Tek veritabanının .sql dökümünü alır (NSSavePanel ile konum seçtirir).
    private func dumpDatabase(_ name: String) {
        // Listeden gelse de savunmacı ol: tire ile başlayan ad mysql araçlarında
        // seçenek sanılabilir (pg tarafında `--` işareti var, mysql'de garanti değil)
        guard !name.hasPrefix("-") else {
            consoleStore.log(key: "log.db.unsupportedName", args: [name], type: .error); return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name)-\(backupStamp).sql"
        if let t = UTType(filenameExtension: "sql") { panel.allowedContentTypes = [t] }
        panel.message = String(format: loc.t("db.dumpSavePrompt"), name)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isBackupBusy = true
        consoleStore.log(key: "log.db.dumpStart", args: [name, url.lastPathComponent], type: .command)
        Task {
            let out = Shell.quote(url.path)
            let result: Shell.Result
            switch selectedDB {
            case .postgresql:
                let pgPort = dbService?.port ?? 5432
                let dbArg = shSingleQuote(name)
                result = await Shell.brewBashAsync(
                    "pg_dump -h 127.0.0.1 -p \(pgPort) -U postgres -f \(out) -- \(dbArg) 2>&1 || " +
                    "pg_dump -h 127.0.0.1 -p \(pgPort) -f \(out) -- \(dbArg) 2>&1"
                )
            case .mariadb:
                // --single-transaction: InnoDB'de tutarlı anlık görüntü (tabloları kilitlemez)
                // --routines --triggers: saklı yordamlar ve tetikleyiciler de dökülsün
                result = await Shell.brewBashAsync(
                    "mysqldump -u root --single-transaction --routines --triggers \(shSingleQuote(name)) > \(out)"
                )
            case .redis:
                isBackupBusy = false
                return   // Redis dökümü RDB/BGSAVE ile — SQL dökümü uygulanmaz
            }
            isBackupBusy = false
            if result.isSuccess {
                let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
                consoleStore.log(key: "log.db.dumpDone",
                                 args: [name, "\(bytes / 1024)", url.path], type: .success)
            } else {
                // Başarısız dökümde yarım dosyayı bırakma — bozuk yedek, yedek yok demekten kötü
                try? FileManager.default.removeItem(at: url)
                reportDBError(String(format: loc.t("db.backupFailed"), result.error.isEmpty ? result.output : result.error))
            }
        }
    }

    /// .sql dosyası seçtirip geri yükleme sheet'ini açar.
    private func pickRestoreFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let t = UTType(filenameExtension: "sql") { panel.allowedContentTypes = [t, .plainText] }
        panel.message = loc.t("db.restorePickPrompt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        restoreFileURL = url
        // Dosya adından hedef DB önerisi: "blog-20260716-1430.sql" → "blog"
        let base = url.deletingPathExtension().lastPathComponent
        let guess = base.components(separatedBy: CharacterSet(charactersIn: "-.")).first ?? base
        restoreDBName = isValidDBName(guess) ? guess : ""
        showRestoreSheet = true
    }

    /// Seçilen dökümü hedef veritabanına uygular (yoksa oluşturur).
    private func performRestore() {
        guard let url = restoreFileURL else { return }
        let target = restoreDBName.trimmingCharacters(in: .whitespaces)
        restoreFileURL = nil
        guard isValidDBName(target) else {
            consoleStore.log(key: "log.db.invalidTargetName", type: .error)
            return
        }

        isBackupBusy = true
        consoleStore.log(key: "log.db.restoreStart", args: [target, url.lastPathComponent], type: .command)
        Task {
            let inFile = Shell.quote(url.path)
            let result: Shell.Result
            switch selectedDB {
            case .postgresql:
                let pgPort = dbService?.port ?? 5432
                let dbArg = shSingleQuote(target)
                // KRİTİK: dökümü ASLA iki kez uygulama. Eski `psql || psql` kalıbı, dökümün
                // ORTASINDAKİ bir SQL hatasında (ON_ERROR_STOP) ilk psql'i non-zero bitirir ve
                // `||` tüm dosyayı BAŞTAN yeniden uygular → PK'siz tablolarda satır ikiye katlanır.
                // Çözüm: önce hangi kullanıcının bağlanabildiğini bir kez tespit et (SELECT 1),
                // sonra createdb + döküm o kullanıcıyla TEK KEZ çalışır. Böylece "bağlantı hatası"
                // ile "döküm-içi SQL hatası" ayrışır; ikincisi yeniden uygulamaya yol açmaz.
                result = await Shell.brewBashAsync("""
                if psql -h 127.0.0.1 -p \(pgPort) -U postgres -c 'SELECT 1' >/dev/null 2>&1; then
                    U="-U postgres"
                elif psql -h 127.0.0.1 -p \(pgPort) -c 'SELECT 1' >/dev/null 2>&1; then
                    U=""
                else
                    echo "PostgreSQL bağlantısı kurulamadı (port \(pgPort))" >&2; exit 1
                fi
                # Veritabanını BİZ mi oluşturduk? Hata durumunda YALNIZCA kendi oluşturduğumuzu
                # düşürürüz — kullanıcının mevcut veritabanını asla silmeyiz.
                CREATED=0
                if createdb -h 127.0.0.1 -p \(pgPort) $U -- \(dbArg) 2>/dev/null; then CREATED=1; fi

                # --single-transaction: döküm ORTASINDA bir SQL hatası olursa TÜM değişiklikler
                # geri alınır. Onsuz, hata öncesi tablolar commit'lenmiş, sonrakiler eksik kalır
                # ve kullanıcı yarım geri yüklenmiş bir veritabanıyla baş başa kalırdı.
                if psql -h 127.0.0.1 -p \(pgPort) $U -v ON_ERROR_STOP=1 --single-transaction --dbname=\(dbArg) -f \(inFile) 2>&1; then
                    exit 0
                fi
                rc=$?
                if [ "$CREATED" = "1" ]; then
                    dropdb -h 127.0.0.1 -p \(pgPort) $U -- \(dbArg) 2>/dev/null || true
                    echo "Geri yükleme başarısız — bu işlemde oluşturulan veritabanı kaldırıldı" >&2
                fi
                exit $rc
                """)
            case .mariadb:
                // MariaDB/MySQL'de DDL örtük commit yaptığından döküm gerçek anlamda
                // transaction'a alınamaz. Yapılabilecek en iyi şey: veritabanını BU işlemde
                // biz oluşturduysak ve geri yükleme başarısız olursa yarım kalan veritabanını
                // kaldırmak. Kullanıcının ÖNCEDEN var olan veritabanına asla dokunulmaz.
                let createSQL = "CREATE DATABASE IF NOT EXISTS \(mysqlIdent(target))"
                let dropSQL   = "DROP DATABASE IF EXISTS \(mysqlIdent(target))"
                let existsSQL = "SHOW DATABASES LIKE \(shSingleQuote(target))"
                result = await Shell.brewBashAsync("""
                CREATED=0
                if [ -z "$(mysql -N -u root -e \(shSingleQuote(existsSQL)) 2>/dev/null)" ]; then
                    mysql -u root -e \(shSingleQuote(createSQL)) || exit 1
                    CREATED=1
                fi
                if mysql -u root \(shSingleQuote(target)) < \(inFile); then
                    exit 0
                fi
                rc=$?
                if [ "$CREATED" = "1" ]; then
                    mysql -u root -e \(shSingleQuote(dropSQL)) 2>/dev/null || true
                    echo "Geri yükleme başarısız — bu işlemde oluşturulan veritabanı kaldırıldı" >&2
                fi
                exit $rc
                """)
            case .redis:
                isBackupBusy = false
                return
            }
            isBackupBusy = false
            if result.isSuccess {
                consoleStore.log(key: "log.db.restoreDone", args: [target], type: .success)
            } else {
                reportDBError(String(format: loc.t("db.restoreFailed"), result.error.isEmpty ? result.output : result.error))
            }
            loadDatabases()
        }
    }

    // MARK: - Helpers

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
        }
    }

    // MARK: - Database Operations

    private func loadDatabases() {
        guard isDBRunning else { databases = []; return }
        loadToken += 1
        let token = loadToken
        isLoadingDBs = true

        Task {
            let result: Shell.Result
            switch selectedDB {
            case .postgresql:
                // İlk yapılandırma sonrası postgres superuser kullan; yoksa mevcut kullanıcıyla dene
                let pgPort = dbService?.port ?? 5432
                result = await Shell.brewBashAsync(
                    "psql -h 127.0.0.1 -p \(pgPort) -U postgres -t -A -c \"SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname\" 2>/dev/null || " +
                    "psql -h 127.0.0.1 -p \(pgPort) -t -A -c \"SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname\" 2>/dev/null"
                )
            case .mariadb:
                result = await Shell.brewBashAsync("mysql -u root -N -e 'SHOW DATABASES' 2>/dev/null")
            case .redis:
                result = Shell.Result(output: "", error: "", exitCode: 0)   // Redis'te DB listesi kavramı farklı (0-15)
            }

            // Bu çağrı beklerken daha yeni bir loadDatabases başladıysa sonucu YOKSAY
            guard token == loadToken else { return }

            if result.isSuccess {
                databases = result.output
                    .components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            } else {
                databases = []
                consoleStore.log(key: "log.db.listFailed", args: [result.error], type: .warning)
            }
            isLoadingDBs = false
        }
    }

    // MARK: - Güvenli Kaçış Yardımcıları

    /// Bir string'i bash için tek-tırnak içine güvenle sarar (içteki ' → '\'' ).
    private func shSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// MySQL/MariaDB backtick tanımlayıcısı — içteki backtick'leri ikiler.
    private func mysqlIdent(_ name: String) -> String {
        "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
    }

    /// Yeni veritabanı adı doğrulaması — yalnızca harf, rakam, _ ve - (maks 64).
    private func isValidDBName(_ name: String) -> Bool {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return !name.isEmpty && name.count <= 64 && name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private func createDatabase(_ name: String) {
        let sanitized = name.trimmingCharacters(in: .whitespaces)
        guard !sanitized.isEmpty else { return }
        guard isValidDBName(sanitized) else {
            consoleStore.log(key: "log.db.invalidName", type: .error)
            return
        }

        Task {
            let result: Shell.Result
            switch selectedDB {
            case .postgresql:
                let pgPort = dbService?.port ?? 5432
                let dbArg = shSingleQuote(sanitized)
                // -- : ad tire ile başlasa bile seçenek olarak yorumlanmasın (uç-işaret)
                result = await Shell.brewBashAsync(
                    "createdb -h 127.0.0.1 -p \(pgPort) -U postgres -- \(dbArg) 2>&1 || " +
                    "createdb -h 127.0.0.1 -p \(pgPort) -- \(dbArg) 2>&1"
                )
            case .mariadb:
                let sql = "CREATE DATABASE \(mysqlIdent(sanitized))"
                result = await Shell.brewBashAsync("mysql -u root -e \(shSingleQuote(sql)) 2>&1")
            case .redis:
                return   // Redis'te kullanıcı DB'si oluşturma yok
            }

            if result.isSuccess {
                consoleStore.log(key: "log.db.created", args: [sanitized], type: .success)
            } else {
                reportDBError(String(format: loc.t("db.createFailed"), result.error))
            }
            loadDatabases()
        }
    }

    private func dropDatabase(_ name: String) {
        Task {
            let result: Shell.Result
            switch selectedDB {
            case .postgresql:
                let pgPort = dbService?.port ?? 5432
                let dbArg = shSingleQuote(name)   // ad listeden gelir — yine de güvenle kaçışla
                // -- : ad tire ile başlasa bile seçenek olarak yorumlanmasın (uç-işaret)
                result = await Shell.brewBashAsync(
                    "dropdb -h 127.0.0.1 -p \(pgPort) -U postgres -- \(dbArg) 2>&1 || " +
                    "dropdb -h 127.0.0.1 -p \(pgPort) -- \(dbArg) 2>&1"
                )
            case .mariadb:
                let sql = "DROP DATABASE \(mysqlIdent(name))"
                result = await Shell.brewBashAsync("mysql -u root -e \(shSingleQuote(sql)) 2>&1")
            case .redis:
                return
            }

            if result.isSuccess {
                consoleStore.log(key: "log.db.dropped", args: [name], type: .success)
            } else {
                reportDBError(String(format: loc.t("db.dropFailed"), result.error))
            }
            loadDatabases()
        }
    }

    // MARK: - pgAdmin4 Actions

    private func openPgAdmin() {
        // Apache: https://localhost/pgadmin4, Nginx: http://localhost:8080/pgadmin4/
        let urlString: String
        if isPgAdminApacheConfigured {
            urlString = "https://localhost/pgadmin4"
        } else if isPgAdminNginxConfigured {
            urlString = "http://localhost:8080/pgadmin4/"
        } else {
            urlString = "http://127.0.0.1:\(PathConfig.pgadmin4Port)"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// ServiceManager.installPgAdmin4() → InstallationProgressSheet otomatik açılır
    private func installPgAdmin() {
        serviceManager.installPgAdmin4()
    }

    /// Apache için pgAdmin4 reverse proxy include dosyasını oluşturur ve httpd.conf'a ekler.
    private func configurePgAdmin4ForApache() async {
        consoleStore.log(key: "log.db.pgadminApacheConfiguring", type: .info)

        // pgadmin4.conf dosyasını oluştur
        let conf = VHostTemplates.pgadmin4ApacheConfig()
        guard FileHelper.write(conf, to: PathConfig.pgadmin4Conf) else {
            consoleStore.log(key: "log.db.pgadminConfWriteFailed", args: [PathConfig.pgadmin4Conf], type: .error)
            return
        }
        consoleStore.log(key: "log.db.pgadminConfCreated", type: .success)

        // httpd.conf'a IncludeOptional ekle
        guard var httpdContent = FileHelper.readString(PathConfig.httpdConf) else {
            consoleStore.log(key: "log.db.httpdReadFailed", type: .error)
            return
        }

        let includeDirective = VHostTemplates.pgadmin4IncludeConfig()
        if !httpdContent.contains(includeDirective) {
            // phpmyadmin include'un hemen altına ekle
            let pmaInclude = VHostTemplates.phpmyadminIncludeConfig()
            if httpdContent.contains(pmaInclude) {
                httpdContent = httpdContent.replacingOccurrences(
                    of: pmaInclude,
                    with: "\(pmaInclude)\n\(includeDirective)"
                )
            } else {
                httpdContent += "\n\(includeDirective)\n"
            }

            if FileHelper.write(httpdContent, to: PathConfig.httpdConf) {
                consoleStore.log(key: "log.db.httpdUpdated", type: .success)
                consoleStore.log(key: "log.db.restartApacheHint", type: .info)
            } else {
                consoleStore.log(key: "log.db.httpdWriteFailed", type: .error)
            }
        } else {
            consoleStore.log(key: "log.db.httpdAlreadyIncludes", type: .info)
        }
    }

    /// Nginx için nginx.conf'u pgAdmin4 location bloğu ile yeniden yazar.
    private func configurePgAdmin4ForNginx() async {
        consoleStore.log(key: "log.db.pgadminNginxConfiguring", type: .info)

        guard FileManager.default.fileExists(atPath: PathConfig.nginxConf) else {
            consoleStore.log(key: "log.db.nginxConfNotFound", type: .error)
            return
        }

        let sslAvailable = FileManager.default.fileExists(atPath: "\(PathConfig.localhostSSLDir)/cert.pem")
        if NginxConfigManager.rewriteMainConfig(sslAvailable: sslAvailable, pgAdmin4Available: true) {
            consoleStore.log(key: "log.db.nginxUpdated", type: .success)
            consoleStore.log(key: "log.db.restartNginxHint", type: .info)
        } else {
            consoleStore.log(key: "log.db.nginxWriteFailed", type: .error)
        }
    }

    /// ServiceManager.installPhpMyAdmin() → InstallationProgressSheet otomatik açılır
    private func installPhpMyAdmin() {
        serviceManager.installPhpMyAdmin()
    }


    // MARK: - PG Settings

    private func loadPGSettings(version: String) {
        let confPath = PathConfig.pgConf(version: version)
        guard let content = FileHelper.readString(confPath) else { return }

        for i in 0..<pgSettings.count {
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"), trimmed.hasPrefix(pgSettings[i].name) else { continue }
                if let value = trimmed.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces) {
                    // Yorum kısmını kes
                    pgSettings[i].value = value.components(separatedBy: "#").first?.trimmingCharacters(in: .whitespaces) ?? value
                }
            }
        }
    }

    private func savePGSettings(version: String) {
        let confPath = PathConfig.pgConf(version: version)
        guard var content = FileHelper.readString(confPath) else {
            consoleStore.log(key: "log.db.pgConfReadFailed", type: .error)
            return
        }

        for setting in pgSettings {
            // Boş değeri ASLA yazma: "shared_buffers = " gibi eksik değerli bir satır
            // PostgreSQL için FATAL sözdizimi hatasıdır — aşağıdaki restart sunucuyu
            // durdurur ve bir daha başlatamaz. (my.cnf/redis kaydedicileri de böyle korur.)
            let v = setting.value.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { continue }

            let pattern = "^\\s*#?\\s*\(NSRegularExpression.escapedPattern(for: setting.name))\\s*=.*$"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines),
               let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
               let range = Range(match.range, in: content) {
                content.replaceSubrange(range, with: "\(setting.name) = \(v)")
            } else {
                // Parametre dosyada HİÇ yoksa (budanmış postgresql.conf) eskiden sessizce
                // atlanır ama yine de "kaydedildi" denirdi. Sona ekle — PostgreSQL bir
                // anahtarın SON geçtiği satırı kullanır, bu yüzden eklemek güvenlidir.
                if !content.hasSuffix("\n") { content += "\n" }
                content += "\(setting.name) = \(v)\n"
            }
        }

        if FileHelper.write(content, to: confPath) {
            consoleStore.log(key: "log.db.pgSettingsSaved", type: .success)
            // PostgreSQL yeniden başlat
            if let svc = dbService {
                serviceManager.restartService(svc)
            }
        } else {
            consoleStore.log(key: "log.db.pgConfWriteFailed", type: .error)
        }
    }

    // MARK: - my.cnf (MariaDB) Ayarları

    /// Ayarlar KENDİ dosyamızdan (my.cnf.d/zz-brampp.cnf) okunur; yoksa varsayılan kalır.
    private func loadMyCnfSettings() {
        guard let content = FileHelper.readString(PathConfig.mariadbOwnConf) else { return }
        for i in 0..<myCnfSettings.count {
            for line in content.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("#"), t.hasPrefix(myCnfSettings[i].name) else { continue }
                if let v = t.components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces) {
                    myCnfSettings[i].value = v
                }
            }
        }
    }

    /// Tüm ayarları [mariadbd] bölümüyle KENDİ dosyamıza yazar (kullanıcının my.cnf'i korunur).
    private func saveMyCnfSettings() {
        FileHelper.createDirectory(PathConfig.mariadbConfDir)
        var lines = ["# BRAMPP tarafından yönetilir — elle düzenlemeyin.", "[mariadbd]"]
        for s in myCnfSettings {
            let v = s.value.trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { lines.append("\(s.name) = \(v)") }
        }
        if FileHelper.write(lines.joined(separator: "\n") + "\n", to: PathConfig.mariadbOwnConf) {
            consoleStore.log(key: "log.db.myCnfSaved", type: .success)
            if let svc = dbService { serviceManager.restartService(svc) }
        } else {
            reportDBError(String(format: loc.t("db.myCnfWriteFailed"), PathConfig.mariadbOwnConf))
        }
    }

    // MARK: - redis.conf Ayarları

    private func loadRedisSettings() {
        guard let content = FileHelper.readString(PathConfig.redisConf) else { return }
        for i in 0..<redisSettings.count {
            for line in content.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                // redis.conf formatı: "directive value" (= yok)
                guard !t.hasPrefix("#"), t.hasPrefix(redisSettings[i].name + " ") else { continue }
                let v = String(t.dropFirst(redisSettings[i].name.count)).trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { redisSettings[i].value = v }
            }
        }
    }

    /// redis.conf'ta ilgili direktifi günceller (varsa değiştir, yoksa ekle). "directive value" formatı.
    /// `redis-cli INFO` çıktısını okuyup panele yansıtır.
    /// Redis kapalıysa komut hata döner; bu durumda istatistik gösterilmez ve
    /// kullanıcıya "çalışmıyor" denir — boş/sıfır değerler göstermek yanıltıcı olurdu.
    private func loadRedisStats() {
        redisLoading = true
        Task {
            let r = await Shell.brewBashAsync("redis-cli INFO 2>/dev/null")
            redisStats = (r.isSuccess && r.output.contains("redis_version"))
                ? RedisStats.parse(r.output)
                : nil
            redisLoading = false
        }
    }

    private func saveRedisSettings() {
        guard var content = FileHelper.readString(PathConfig.redisConf) else {
            reportDBError(String(format: loc.t("db.redisReadFailed"), PathConfig.redisConf))
            return
        }
        for s in redisSettings {
            let v = s.value.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { continue }
            let pattern = "^\\s*#?\\s*\(NSRegularExpression.escapedPattern(for: s.name))\\s+.*$"
            let replacement = "\(s.name) \(v)"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines),
               let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
               let range = Range(match.range, in: content) {
                content.replaceSubrange(range, with: replacement)
            } else {
                content += "\n\(replacement)\n"   // yönerge yoksa sona ekle
            }
        }
        if FileHelper.write(content, to: PathConfig.redisConf) {
            consoleStore.log(key: "log.db.redisSaved", type: .success)
            if let svc = dbService { serviceManager.restartService(svc) }
        } else {
            reportDBError(loc.t("db.redisWriteFailed"))
        }
    }
}

// MARK: - PGSetting

struct PGSetting: Identifiable {
    let id: String
    let name: String
    let description: String
    var value: String

    static let defaults: [PGSetting] = [
        PGSetting(id: "max_connections", name: "max_connections", description: "dbset.maxConn", value: "100"),
        PGSetting(id: "shared_buffers", name: "shared_buffers", description: "dbset.sharedBuffers", value: "128MB"),
        PGSetting(id: "work_mem", name: "work_mem", description: "dbset.workMem", value: "4MB"),
        PGSetting(id: "maintenance_work_mem", name: "maintenance_work_mem", description: "dbset.maintMem", value: "64MB"),
        PGSetting(id: "listen_addresses", name: "listen_addresses", description: "dbset.listenAddr", value: "'localhost'"),
    ]

    static let mariadbDefaults: [PGSetting] = [
        PGSetting(id: "max_connections", name: "max_connections", description: "dbset.maxConn", value: "151"),
        PGSetting(id: "innodb_buffer_pool_size", name: "innodb_buffer_pool_size", description: "dbset.innodbPool", value: "128M"),
        PGSetting(id: "max_allowed_packet", name: "max_allowed_packet", description: "dbset.maxPacket", value: "64M"),
        PGSetting(id: "innodb_log_file_size", name: "innodb_log_file_size", description: "dbset.innodbLog", value: "48M"),
        PGSetting(id: "character-set-server", name: "character-set-server", description: "dbset.charset", value: "utf8mb4"),
    ]

    static let redisDefaults: [PGSetting] = [
        PGSetting(id: "maxmemory", name: "maxmemory", description: "dbset.maxMem", value: "0"),
        PGSetting(id: "maxmemory-policy", name: "maxmemory-policy", description: "dbset.evictPolicy", value: "noeviction"),
        PGSetting(id: "appendonly", name: "appendonly", description: "dbset.aof", value: "no"),
        PGSetting(id: "timeout", name: "timeout", description: "dbset.idleTimeout", value: "0"),
        PGSetting(id: "databases", name: "databases", description: "dbset.dbCount", value: "16"),
    ]
}
