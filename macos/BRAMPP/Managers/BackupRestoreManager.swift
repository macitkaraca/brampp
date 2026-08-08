import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers

/// Yedekleme ve geri yükleme işlemleri.
/// domains.json + settings.json → backups/ dizinine tarih damgalı klasör olarak kaydeder.
@MainActor
class BackupRestoreManager: BaseManager {

    @Published var backups: [BackupEntry] = []

    struct BackupEntry: Identifiable {
        let id: String          // klasör adı (tarih damgası)
        let date: Date
        let path: String
        var displayName: String { dateFormatter.string(from: date) }

        private let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "dd.MM.yyyy HH:mm"
            return f
        }()
    }

    // MARK: - Backup

    /// Mevcut domains.json ve settings.json'u yedekler.
    /// Döndürülen değer: başarı mı?
    @discardableResult
    func createBackup() -> Bool {
        createBackupReturningStamp() != nil
    }

    /// `createBackup()`ın gövdesi — TAM başarılıysa yedeğin tarih damgasını döndürür.
    /// Kısmi/başarısız yedekte `nil`: çağıran "geri dönebileceğim bir yedek var" sanmasın
    /// (restoreBackup bu damgayı kullanıcıya geri dönüş adresi olarak loglar).
    @discardableResult
    private func createBackupReturningStamp() -> String? {
        // Damga saniye çözünürlüğünde — aynı saniyede ikinci yedek aynı klasöre düşerse
        // backupDirectory'nin copyItem'ı "hedef zaten var" ile fırlardı. Benzersiz kıl.
        var timestamp = backupTimestamp()
        var backupDir = "\(PathConfig.backups)/\(timestamp)"
        var suffix = 2
        while FileManager.default.fileExists(atPath: backupDir) {
            timestamp = "\(backupTimestamp())-\(suffix)"
            backupDir = "\(PathConfig.backups)/\(timestamp)"
            suffix += 1
        }

        guard FileHelper.createDirectory(backupDir) else {
            log(key: "log.backup.dirCreateFailed", args: [backupDir], type: .error)
            return nil
        }

        var success = true
        var filesBackedUp = 0

        if FileHelper.exists(PathConfig.domainsJson) {
            let dest = "\(backupDir)/domains.json"
            if FileHelper.copy(from: PathConfig.domainsJson, to: dest) {
                filesBackedUp += 1
            } else {
                log(key: "log.backup.domainsSaveFailed", type: .error)
                success = false
            }
        }

        if FileHelper.exists(PathConfig.settingsJson) {
            let dest = "\(backupDir)/settings.json"
            if FileHelper.copy(from: PathConfig.settingsJson, to: dest) {
                filesBackedUp += 1
            } else {
                log(key: "log.backup.settingsSaveFailed", type: .error)
                success = false
            }
        }

        // Son çalışan servis listesi (küçük ama açılış davranışını belirliyor)
        if FileHelper.exists(PathConfig.lastRunningJson),
           FileHelper.copy(from: PathConfig.lastRunningJson, to: "\(backupDir)/last-running-services.json") {
            filesBackedUp += 1
        }

        // ── Yapılandırma dizinleri: vhost'lar, nginx siteleri, SSL sertifikaları ──
        // (Eskiden yalnızca 2 JSON yedekleniyordu — geri yüklemede domainler listede
        //  görünür ama vhost/SSL olmadığından hiçbiri ÇALIŞMAZDI.)
        filesBackedUp += backupDirectory(PathConfig.vhostsDir,              to: "\(backupDir)/vhosts-apache")
        filesBackedUp += backupDirectory(PathConfig.nginxSitesAvailableDir, to: "\(backupDir)/nginx-sites")
        filesBackedUp += backupDirectory(PathConfig.ssl,                    to: "\(backupDir)/ssl")

        // /etc/hosts anlık görüntüsü — geri yükleme sudo gerektirdiğinden yalnızca
        // BAŞVURU amaçlı saklanır (kullanıcı girişleri elle kopyalayabilir)
        // NOT: filesBackedUp'a EKLENMEZ. /etc/hosts her macOS'ta okunabilir olduğundan
        // bu kopya her zaman başarılı olur ve sayacı 1 yapardı; sonuçta "hiç anlamlı veri
        // yedeklenmedi" koruması (aşağıdaki guard) hiçbir zaman devreye giremezdi.
        // Bu dosya yalnızca BAŞVURU amaçlıdır (geri yükleme sudo ister).
        _ = FileHelper.readString("/etc/hosts").map {
            FileHelper.write($0, to: "\(backupDir)/hosts-snapshot.txt")
        }

        // Kurulu PHP sürümlerinin php.ini özelleştirmeleri
        for v in PHPVersion.allCases where v.isInstalled {
            let ini = PathConfig.phpIni(version: v.rawValue)
            if FileHelper.exists(ini) {
                FileHelper.createDirectory("\(backupDir)/php-ini")
                if FileHelper.copy(from: ini, to: "\(backupDir)/php-ini/php-\(v.rawValue).ini") {
                    filesBackedUp += 1
                }
            }
        }

        // Hiç dosya yedeklenmediyse "başarılı" deme — boş klasörü temizle ve başarısızlık raporla
        guard filesBackedUp > 0 else {
            log(key: "log.backup.nothingToBackup", type: .warning)
            FileHelper.remove(backupDir)
            return nil
        }

        if success {
            log(key: "log.backup.created", args: ["\(filesBackedUp)", timestamp], type: .success)
        } else {
            // KISMİ yedek: kritik bir dosya kopyalanamadı. Klasör SİLİNMEZ (kopyalanabilenler
            // hâlâ değerli olabilir) ama işaretlenir; aksi halde geri yükleme listesinde
            // eksiksiz bir yedek gibi görünür ve kullanıcı ondan geri yükleyip fark etmezdi.
            FileHelper.write("", to: "\(backupDir)/\(Self.partialMarker)")
            log(key: "log.backup.partial", args: [timestamp], type: .error)
        }
        loadBackups()   // liste her durumda tazelenir (kısmi olan filtrelenir)
        return success ? timestamp : nil
    }

    /// Kısmi (eksik) yedeği işaretleyen dosya adı — loadBackups bunu içeren klasörleri atlar.
    /// Ad ekiyle işaretlemek işe yaramaz: parseTimestamp yalnızca ilk 19 karaktere baktığından
    /// "…-00.partial" gibi bir ad yine geçerli sayılırdı.
    private static let partialMarker = ".partial"

    /// Bir dizindeki TÜM dosyaları (alt dizinler dahil) yedek klasörüne kopyalar.
    /// Dönen değer: kopyalanan dosya sayısı. Dizin yoksa 0 (hata değil).
    private func backupDirectory(_ source: String, to dest: String) -> Int {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isDir), isDir.boolValue else { return 0 }
        do {
            // Defansif: hedef zaten varsa copyItem fırlatır — temiz kopya için önce sil
            if FileManager.default.fileExists(atPath: dest) {
                try? FileManager.default.removeItem(atPath: dest)
            }
            // copyItem tüm ağacı kopyalar (SSL'de domain başına alt dizin var)
            try FileManager.default.copyItem(atPath: source, toPath: dest)
            let count = (FileManager.default.enumerator(atPath: dest)?.allObjects.count) ?? 0
            return max(count, 1)
        } catch {
            log(key: "log.backup.dirFailed",
                args: [(source as NSString).lastPathComponent, error.localizedDescription],
                type: .warning)
            return 0
        }
    }

    // MARK: - Restore

    @discardableResult
    func restoreBackup(_ entry: BackupEntry) -> Bool {
        // ── 0) GERİ DÖNÜŞ YOLU ───────────────────────────────────────────────
        // Geri yükleme mevcut domains.json/settings.json/vhost'ların ÜZERİNE yazar.
        // Yanlış yedek seçilirse tek kurtuluş, o andaki durumun kendi yedeğidir;
        // bu adım atlanırsa kullanıcı seçimini geri alamaz. Damga loglanır ki
        // kullanıcı hangi yedeğe döneceğini bilsin.
        if let safetyStamp = createBackupReturningStamp() {
            log(key: "log.backup.preRestoreSaved", args: [safetyStamp], type: .info)
        } else {
            // Yedek alınamadı ama kullanıcı geri yüklemeyi AÇIKÇA istedi — işlemi
            // durdurmak yerine risk açıkça bildirilir.
            log(key: "log.backup.preRestoreFailed", type: .warning)
        }

        let domainsBackup  = "\(entry.path)/domains.json"
        let settingsBackup = "\(entry.path)/settings.json"

        var success = true
        // Yetim vhost temizliği YALNIZCA domains.json gerçekten geri yüklendiyse
        // yapılabilir — referans liste yoksa her .conf "yetim" sayılıp silinirdi.
        var domainsRestored = false

        if FileHelper.exists(domainsBackup) {
            if FileHelper.copy(from: domainsBackup, to: PathConfig.domainsJson) {
                domainsRestored = true
            } else {
                log(key: "log.backup.domainsRestoreFailed", type: .error)
                success = false
            }
        }

        if FileHelper.exists(settingsBackup) {
            if !FileHelper.copy(from: settingsBackup, to: PathConfig.settingsJson) {
                log(key: "log.backup.settingsRestoreFailed", type: .error)
                success = false
            } else {
                // settings.json uygulama DIŞINDA değişti: bellek içi önbellek hâlâ eski
                // değeri tutuyor. Tazelenmezse uygulama eski ayarlarla çalışmaya devam
                // eder ve ilk save() eski değerleri diske geri yazarak geri yüklemeyi
                // sessizce iptal ederdi. UI deposu (UserDefaults) da hizalanmalı.
                AppSettings.reloadFromDisk()
                AppSettings.overwriteUserDefaults()
            }
        }

        if FileHelper.exists("\(entry.path)/last-running-services.json") {
            _ = FileHelper.copy(from: "\(entry.path)/last-running-services.json", to: PathConfig.lastRunningJson)
        }

        // ── Yapılandırma dizinleri: dosya dosya geri kopyala (mevcutların üstüne) ──
        // Dizini komple değiştirmek yerine tek tek kopyalanır: yedekten SONRA eklenmiş
        // domainlerin config'leri silinmez, yalnızca yedekte olanlar geri gelir.
        // Başarısızlıklar genel sonuca KATILIR — aksi halde vhost/sertifika geri yüklenememişken
        // kullanıcıya "geri yüklendi" denir ve eksik yapılandırmayla çalışıldığı anlaşılmaz.
        var configFailures = 0
        configFailures += restoreDirectory("\(entry.path)/vhosts-apache", to: PathConfig.vhostsDir,              label: "@log.backup.labelApacheVhost")
        configFailures += restoreDirectory("\(entry.path)/nginx-sites",   to: PathConfig.nginxSitesAvailableDir, label: "@log.backup.labelNginxSite")
        configFailures += restoreDirectory("\(entry.path)/ssl",           to: PathConfig.ssl,                    label: "@log.backup.labelSslCert")
        if configFailures > 0 { success = false }

        // php.ini geri yükleme — yalnızca KURULU sürümler için (kurulu olmayan sürümün
        // ini yolu yazılırsa sonraki kurulumda beklenmedik config kalıntısı olurdu)
        let iniBackupDir = "\(entry.path)/php-ini"
        for v in PHPVersion.allCases where v.isInstalled {
            let src = "\(iniBackupDir)/php-\(v.rawValue).ini"
            if FileHelper.exists(src) {
                _ = FileHelper.copy(from: src, to: PathConfig.phpIni(version: v.rawValue))
            }
        }

        if FileHelper.exists("\(entry.path)/hosts-snapshot.txt") {
            log(key: "log.backup.hostsManual", type: .info)
        }

        // ── Uzlaştırma: yedekten SONRA eklenmiş domainlerin yetim config'leri ──
        // Geri yükleme domains.json'u eski haline döndürür ama vhost/nginx dosyaları
        // diskte kalır. Apache/Nginx `*.conf`u koşulsuz include ettiğinden, listede
        // artık GÖRÜNMEYEN bu siteler servis edilmeye devam eder (port çakışması,
        // "sildim ama hâlâ açılıyor"). Karşılığı olmayan .conf'lar kaldırılır.
        if domainsRestored {
            reconcileOrphanConfigs()
        } else {
            log(key: "log.backup.orphanSkipped", type: .info)
        }

        if success {
            log(key: "log.backup.restored", args: [entry.displayName], type: .success)
            log(key: "log.backup.restartHint", type: .info)
        }
        return success
    }

    /// Yedekteki bir dizinin dosyalarını (alt dizinler dahil) canlı dizine kopyalar.
    /// - Parameter label: log satırında geçen tür etiketi. Çevrilebilir olması için
    ///   ham metin değil `@` önekli katalog anahtarı verilir (bkz. Core/L10nLog.swift).
    /// - Returns: kopyalanaMAyan dosya sayısı (0 = tamam).
    ///   Çağıran bunu genel başarıya katmalıdır: aksi halde vhost/sertifika geri yüklemesi
    ///   sessizce başarısız olurken kullanıcıya "geri yüklendi" denir ve eksik yapılandırmayla
    ///   çalışıldığı fark edilmez.
    @discardableResult
    private func restoreDirectory(_ source: String, to dest: String, label: String) -> Int {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source, isDirectory: &isDir), isDir.boolValue else { return 0 }
        FileHelper.createDirectory(dest)
        guard let en = FileManager.default.enumerator(atPath: source) else {
            log(key: "log.backup.dirReadFailed", args: [label, source], type: .error)
            return 1
        }
        var restored = 0
        var failed   = 0
        for case let rel as String in en {
            let src = "\(source)/\(rel)", dst = "\(dest)/\(rel)"
            var srcIsDir: ObjCBool = false
            FileManager.default.fileExists(atPath: src, isDirectory: &srcIsDir)
            if srcIsDir.boolValue {
                FileHelper.createDirectory(dst)
            } else if FileHelper.copy(from: src, to: dst) {
                restored += 1
            } else {
                failed += 1
            }
        }
        if restored > 0 { log(key: "log.backup.filesRestored",      args: ["\(restored)", label], type: .info) }
        if failed   > 0 { log(key: "log.backup.filesRestoreFailed", args: ["\(failed)", label],   type: .error) }
        return failed
    }

    // MARK: - Orphan Config Reconciliation

    /// Domain'e AİT OLMAYAN, sistem/servis yapılandırması olan .conf adları.
    /// Bunlar domain listesiyle eşleşmez ama silinirse phpMyAdmin/Adminer/pgAdmin ve
    /// localhost tamamen erişilemez hale gelir — uzlaştırma bunlara ASLA dokunmaz.
    private static func isSystemConf(_ stem: String) -> Bool {
        let s = stem.lowercased()
        // Sıra öneki taşıyan sistem dosyaları (000-localhost.conf gibi)
        if s.hasPrefix("000-") { return true }
        return s.contains("phpmyadmin") || s.contains("adminer") || s.contains("pgadmin")
    }

    /// Geri yüklenen domains.json ile diskteki vhost/nginx yapılandırmalarını uzlaştırır:
    /// listede KARŞILIĞI OLMAYAN `<ad>.conf` dosyalarını kaldırır.
    ///
    /// Bir domain hem Apache hem Nginx dizininde dosya taşıyabildiğinden (Nginx
    /// domainlerine bare-URL için Apache eşlikçisi yazılıyor) eşleştirme DİZİNDEN
    /// bağımsız yapılır: ad listede varsa iki dizindeki dosyası da korunur.
    ///
    /// GÜVENLİK: yalnızca `restoreBackup` içinden, o fonksiyonun ilk adımda aldığı
    /// güvenlik yedeğinden SONRA çağrılır. Kaldırılan her .conf o yedeğin
    /// `vhosts-apache`/`nginx-sites` klasörlerinde durur; bu sıra bozulursa
    /// silinen yapılandırmaların geri dönüşü kalmaz.
    private func reconcileOrphanConfigs() {
        // Referans liste okunamıyorsa hiçbir şey silinmez — okunamayan bir dosyayı
        // "boş liste" sayıp tüm siteleri kaldırmak, düzeltmeye çalıştığımız veri
        // kaybının daha büyüğü olurdu.
        guard let data = FileHelper.readData(PathConfig.domainsJson),
              let list = try? JSONDecoder().decode(DomainList.self, from: data) else {
            log(key: "log.backup.orphanSkipped", type: .warning)
            return
        }
        // Host adları büyük/küçük harfe DUYARSIZ — karşılaştırma da öyle olmalı
        let known = Set(list.domains.map { $0.name.lowercased() })

        let targets: [(dir: String, label: String)] = [
            (PathConfig.vhostsDir,              "@log.backup.labelApacheVhost"),
            (PathConfig.nginxSitesAvailableDir, "@log.backup.labelNginxSite")
        ]

        var removed = 0
        for target in targets {
            for file in FileHelper.contentsOfDirectory(target.dir) where file.hasSuffix(".conf") {
                let stem = String(file.dropLast(".conf".count))
                guard !Self.isSystemConf(stem), !known.contains(stem.lowercased()) else { continue }
                let path = "\(target.dir)/\(file)"
                if FileHelper.remove(path) {
                    removed += 1
                    log(key: "log.backup.orphanRemoved", args: [target.label, file], type: .warning)
                } else {
                    log(key: "log.backup.orphanRemoveFailed", args: [path], type: .error)
                }
            }
        }
        if removed == 0 {
            log(key: "log.backup.orphanNone", type: .info)
        } else {
            // Web sunucusu hâlâ eski yapılandırmayı bellekte tutuyor
            log(key: "log.backup.orphanReloadHint", args: ["\(removed)"], type: .info)
        }
    }

    // MARK: - Delete

    /// Yedeği kaldırır. Kalıcı silme yerine ÇÖP KUTUSU kullanılır — yanlış yedek
    /// silinirse Finder'dan geri alınabilir.
    /// - Returns: kaldırıldı mı? (arayüz başarısızlıkta uyarı gösterebilsin)
    @discardableResult
    func deleteBackup(_ entry: BackupEntry) -> Bool {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path),
                                              resultingItemURL: nil)
            log(key: "log.backup.trashed", args: [entry.displayName], type: .info)
            loadBackups()
            return true
        } catch {
            // Çöp Kutusu her birimde kullanılamaz (ör. ağ/harici disk) — kalıcı silmeye düş
            guard FileHelper.remove(entry.path) else {
                log(key: "log.backup.deleteFailed",
                    args: [entry.displayName, error.localizedDescription], type: .error)
                return false
            }
            log(key: "log.backup.deleted", args: [entry.displayName], type: .info)
            loadBackups()
            return true
        }
    }

    // MARK: - Load

    func loadBackups() {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: PathConfig.backups) else {
            backups = []
            return
        }
        let parsed: [BackupEntry] = items.compactMap { name in
            let path = "\(PathConfig.backups)/\(name)"
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
            // Kısmi/eksik yedek geri yükleme listesine ALINMAZ
            guard !FileHelper.exists("\(path)/\(Self.partialMarker)") else { return nil }
            guard let date = parseTimestamp(name) else { return nil }
            return BackupEntry(id: name, date: date, path: path)
        }
        backups = parsed.sorted { $0.date > $1.date }
    }

    // MARK: - Export / Import (NSOpenPanel / NSSavePanel)

    func exportDomains() {
        guard FileHelper.exists(PathConfig.domainsJson) else {
            log(key: "log.backup.exportNoDomains", type: .warning)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "brampp-domains-\(backupTimestamp()).json"
        panel.allowedContentTypes = [.json]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: PathConfig.domainsJson))
                try data.write(to: url)
                self.log(key: "log.backup.exported", args: [url.lastPathComponent], type: .success)
            } catch {
                self.log(key: "log.backup.exportFailed", args: [error.localizedDescription], type: .error)
            }
        }
    }

    func importDomains(completion: @escaping () -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = Localizer.shared.t("backup.importPanelMsg")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            self.performImport(from: url, completion: completion)
        }
    }

    /// İçe aktarmanın gövdesi — dosya seçildikten sonra çalışır.
    ///
    /// KRİTİK: `JSONDecoder().decode(DomainList.self, …)` başarılı olması dosyanın
    /// GEÇERLİ olduğu anlamına GELMEZ. DomainList kayıp-toleranslı çözer: alakasız
    /// bir JSON (`{"domains":[1,2,3]}`) bile 0 domain + droppedCount>0 ile "çözülür".
    /// Eskiden bu "doğrulandı" sayılıp domains.json TAMAMEN eziliyordu; kullanıcının
    /// TÜM alan adları tek tıkla silinebiliyordu. Artık içe aktarma ANLAMLI içeriğe
    /// bağlı ve üzerine yazmadan önce zaman damgalı bir güvenlik yedeği alınıyor.
    private func performImport(from url: URL, completion: @escaping () -> Void) {
        let data: Data
        let incoming: DomainList
        do {
            data     = try Data(contentsOf: url)
            incoming = try JSONDecoder().decode(DomainList.self, from: data)
        } catch {
            log(key: "log.backup.importFailed", args: [error.localizedDescription], type: .error)
            return
        }

        // Tek bir kayıt bile çözülemediyse dosya bu uygulamanın ürettiği bir dışa
        // aktarım değildir (ya da bozulmuştur) — kısmi veriyle üzerine YAZMA.
        guard incoming.droppedCount == 0 else {
            log(key: "log.backup.importInvalidRecords", args: ["\(incoming.droppedCount)"], type: .error)
            return
        }
        guard !incoming.domains.isEmpty else {
            log(key: "log.backup.importEmpty", type: .error)
            return
        }

        // ── Onay: kaç alan adı gelecek, kaç alan adı gidecek ─────────────────
        let currentCount = currentDomainCount()
        let alert = NSAlert()
        alert.alertStyle      = .warning
        alert.messageText     = Localizer.shared.t("backup.importConfirmTitle")
        alert.informativeText = String(format: Localizer.shared.t("backup.importConfirmMsg"),
                                       url.lastPathComponent,
                                       "\(incoming.domains.count)",
                                       "\(currentCount)")
        alert.addButton(withTitle: Localizer.shared.t("cv.import"))     // .alertFirstButtonReturn
        alert.addButton(withTitle: Localizer.shared.t("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else {
            log(key: "log.backup.importCancelled", type: .info)
            return
        }

        // ── ÜZERİNE YAZMADAN ÖNCE güvenlik yedeği ───────────────────────────
        // Yedek alınamıyorsa içe aktarma da yapılmaz: geri dönüşü olmayan bir
        // üzerine yazma, kullanıcının onayladığından daha ağır bir risktir.
        if FileHelper.exists(PathConfig.domainsJson) {
            let safety = "\(PathConfig.domainsJson).\(backupTimestamp()).bak"
            guard FileHelper.copy(from: PathConfig.domainsJson, to: safety) else {
                log(key: "log.backup.importSafetyFailed", type: .error)
                return
            }
            log(key: "log.backup.importSafetyBackup",
                args: [(safety as NSString).lastPathComponent], type: .info)
        }

        // ATOMİK yazım: süreç ölür/disk dolarsa mevcut GEÇERLİ domains.json
        // yarım kalmaz (FileHelper.write(Data:) options: .atomic kullanır).
        guard FileHelper.write(data, to: PathConfig.domainsJson) else {
            log(key: "log.backup.importWriteFailed", args: [PathConfig.domainsJson], type: .error)
            return
        }
        log(key: "log.backup.imported", args: [url.lastPathComponent], type: .success)
        completion()
    }

    /// Diskteki domains.json'da kaç alan adı olduğu — onay metnindeki "gidecek" sayısı.
    /// Okunamıyorsa 0 (yalnızca bilgilendirme amaçlı; karar bu sayıya bağlı değil).
    private func currentDomainCount() -> Int {
        guard let data = FileHelper.readData(PathConfig.domainsJson),
              let list = try? JSONDecoder().decode(DomainList.self, from: data) else { return 0 }
        return list.domains.count
    }

    // MARK: - Helpers

    /// Sabit biçimli damga üretir/ayrıştırır.
    /// en_US_POSIX + Gregoryen ZORUNLU: kullanıcının takvimi (ör. Hicri) veya rakam sistemi
    /// farklıysa üretilen ad geri ayrıştırılamaz ve yedek listede görünmez olurdu.
    private static func stampFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale     = Locale(identifier: "en_US_POSIX")
        f.calendar   = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }

    private func backupTimestamp() -> String {
        Self.stampFormatter().string(from: Date())
    }

    private func parseTimestamp(_ name: String) -> Date? {
        // Ad "2025-07-23_10-00-00" olabileceği gibi, aynı saniyedeki ikinci yedek için
        // "2025-07-23_10-00-00-2" de olabilir. DateFormatter sondaki eki KABUL ETMEZ (nil döner);
        // tüm adı vermek o yedeği listede görünmez/yetim bırakırdı. Yalnızca damga kısmı ayrıştırılır.
        let stamp = String(name.prefix(19))
        return Self.stampFormatter().date(from: stamp)
    }
}
