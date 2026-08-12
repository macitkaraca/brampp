import Foundation

// MARK: - AppSettings

struct AppSettings: Codable {
    var defaultPHPVersion: PHPVersion
    var autoStartServices: Bool
    /// Açılışta otomatik başlatılacak KURULU servis id'leri (kullanıcı seçer).
    /// Boşsa hiçbir servis başlatılmaz. "Son çalışanlar" mantığının yerini aldı.
    var autoStartServiceIds: [String]
    var showConsoleOutput: Bool
    var autoRefreshInterval: Int
    var sitesPath: String
    var firstSetupCompleted: Bool
    var showMenuBarIcon: Bool
    var hideWindowOnClose: Bool
    /// Uygulama kapanırken tüm brew servislerini durdur
    var autoStopOnQuit: Bool
    /// Servis çöküşlerinde sistem bildirimi gönder
    var notificationsEnabled: Bool
    /// Konsolda çalıştırılan brew komutlarını göster
    var showCommandsInConsole: Bool
    /// Konsolda brew komut çıktısını (stdout/stderr) göster
    var showBrewOutputInConsole: Bool

    // MARK: - Cascade (Bağımlı Servis) Durdurma

    /// Web sunucusu (Apache/Nginx) durduğunda bağlı PHP-FPM servislerini durdur
    var stopPHPOnWebServerStop: Bool
    /// Web sunucusu (Apache/Nginx) durduğunda domain backend (Node/Python/.NET) proseslerini durdur
    var stopDomainsOnWebServerStop: Bool
    /// Web sunucusu (Apache/Nginx) başladığında domainlerin kullandığı PHP-FPM servislerini başlat
    var startPHPOnWebServerStart: Bool

    // MARK: - Kurulum Onay İstemi

    /// Kurulum sırasında brew "proceed? [y/N]" sorduğunda, kullanıcı yanıt vermezse
    /// zaman aşımı sonunda otomatik "y" gönder
    var installPromptAutoConfirm: Bool
    /// Otomatik "y" gönderilmeden önce beklenecek saniye (kullanıcı bu sürede yazabilir)
    var installPromptAutoConfirmSeconds: Int

    // MARK: - Debug / Verbose Logging

    /// Tüm shell komutlarını (yenileme dahil) konsola yaz — gelişmiş hata ayıklama için
    var verboseLogging: Bool

    /// Konsol satırları ~/Library/Application Support/BRAMPP/logs altına da yazılsın mı?
    /// Bellekteki tampon 300 satırda kesiliyor; kalıcı kopya olmadan biraz öncesine
    /// bakmak mümkün değil. 7 günden eski dosyalar açılışta silinir.
    var persistConsoleLog: Bool

    // MARK: - MCP Sunucusu

    /// Uygulama içi MCP sunucusu (yapay zekâ araçları için yerel uç nokta) açılışta başlatılsın mı?
    /// Varsayılan KAPALI: kullanıcı Ayarlar → Gelişmiş'ten bilinçli olarak açar.
    var mcpServerEnabled: Bool
    /// MCP sunucusunun dinlediği port — yalnızca 127.0.0.1'e bağlanır
    var mcpServerPort: Int

    /// MCP araçlarının alan bazlı erişim düzeyi. Yapay zekâ istemcisi yalnızca izin
    /// verilen araçları GÖRÜR (tools/list süzülür) ve çağırabilir (tools/call denetlenir).
    /// Varsayılan `.write`: mevcut davranış korunur; kısıtlama kullanıcının tercihidir.
    var mcpPermDomains:   String
    var mcpPermServices:  String
    var mcpPermDatabases: String
    var mcpPermLogs:      String
    /// Paylaşım (Cloudflare Quick Tunnel) alanı. Varsayılan ERİŞİM YOK: bu araçlar
    /// yerel siteyi herkese açık bir adrese çıkarır, diğer alanlarla aynı düzeyde
    /// varsayılamaz — kullanıcı bilerek açar.
    var mcpPermSharing:   String

    // MARK: - Uygulama Güncellemeleri
    //
    // Bu yedi alan YALNIZCA settings.json'da tutulur — @AppStorage aynası YOK.
    // Nedeni MCP alanlarındakiyle aynı (bkz. SettingsView.swift:38): UI dışında
    // okuyan tek yer AppState'in açılış akışıdır. Üstelik `updateSkippedVersion`
    // ve `updateSnoozeUntil` Ayarlar penceresinden DEĞİL, güncelleme bildiriminden
    // yazılır; bir ayna, aynı durumun üçüncü bir yazarı olurdu.
    //
    // Tarihler `Date` değil `Double` (timeIntervalSince1970): bu yapıdaki her alan
    // ilkel tip ve JSONEncoder zaten Date'i çıplak bir sayı olarak yazıyor —
    // sayıyı açıkça tutmak, settings.json'u elle düzenleyene ne gördüğünü söyler.

    /// Manifest kanalı ("stable" / "beta" / "nightly"). Yalnızca "stable" YAYINDA;
    /// diğerleri spec/update-manifest.md'de tanımlı ama dosyası henüz yok.
    var updateChannel: String
    /// Her açılışta güncelleme denetlensin mi?
    var updateAutoCheck: Bool
    /// Yeni sürüm bulununca dosya arka planda indirilsin mi? (Kurulum ASLA otomatik değil.)
    var updateAutoDownload: Bool
    /// İndirme sonrası davranış: "notify" | "download" | "downloadAndOpen"
    var updateMode: String
    /// Kullanıcının "bu sürümü atla" dediği TAM sürüm. Daha yenisi çıkarsa yeniden sorulur.
    var updateSkippedVersion: String
    /// "Sonra hatırlat" bitiş anı (timeIntervalSince1970). 0 = erteleme yok.
    var updateSnoozeUntil: Double
    /// Son BAŞARILI denetim anı (timeIntervalSince1970) — Ayarlar'da gösterilir. 0 = hiç.
    var updateLastCheck: Double

    // MARK: - Backward-compatible Decoder

    enum CodingKeys: String, CodingKey {
        case defaultPHPVersion, autoStartServices, showConsoleOutput
        case autoRefreshInterval, sitesPath, firstSetupCompleted
        case showMenuBarIcon, hideWindowOnClose, autoStopOnQuit
        case notificationsEnabled, showCommandsInConsole, showBrewOutputInConsole
        case stopPHPOnWebServerStop, stopDomainsOnWebServerStop, startPHPOnWebServerStart
        case installPromptAutoConfirm, installPromptAutoConfirmSeconds
        case verboseLogging, autoStartServiceIds, persistConsoleLog
        case mcpServerEnabled, mcpServerPort
        case mcpPermDomains, mcpPermServices, mcpPermDatabases, mcpPermLogs, mcpPermSharing
        case updateChannel, updateAutoCheck, updateAutoDownload, updateMode
        case updateSkippedVersion, updateSnoozeUntil, updateLastCheck
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultPHPVersion          = (try? c.decode(PHPVersion.self, forKey: .defaultPHPVersion)) ?? .v83
        autoStartServices          = (try? c.decode(Bool.self, forKey: .autoStartServices)) ?? false
        showConsoleOutput          = (try? c.decode(Bool.self, forKey: .showConsoleOutput)) ?? true
        autoRefreshInterval        = (try? c.decode(Int.self, forKey: .autoRefreshInterval)) ?? 30
        sitesPath                  = (try? c.decode(String.self, forKey: .sitesPath)) ?? PathConfig.sites
        firstSetupCompleted        = (try? c.decode(Bool.self, forKey: .firstSetupCompleted)) ?? false
        showMenuBarIcon            = (try? c.decode(Bool.self, forKey: .showMenuBarIcon)) ?? true
        hideWindowOnClose          = (try? c.decode(Bool.self, forKey: .hideWindowOnClose)) ?? true
        autoStopOnQuit             = (try? c.decode(Bool.self, forKey: .autoStopOnQuit)) ?? true
        notificationsEnabled       = (try? c.decode(Bool.self, forKey: .notificationsEnabled)) ?? true
        showCommandsInConsole      = (try? c.decode(Bool.self, forKey: .showCommandsInConsole)) ?? true
        showBrewOutputInConsole    = (try? c.decode(Bool.self, forKey: .showBrewOutputInConsole)) ?? false
        stopPHPOnWebServerStop     = (try? c.decode(Bool.self, forKey: .stopPHPOnWebServerStop)) ?? true
        stopDomainsOnWebServerStop = (try? c.decode(Bool.self, forKey: .stopDomainsOnWebServerStop)) ?? true
        startPHPOnWebServerStart   = (try? c.decode(Bool.self, forKey: .startPHPOnWebServerStart)) ?? true
        installPromptAutoConfirm   = (try? c.decode(Bool.self, forKey: .installPromptAutoConfirm)) ?? true
        installPromptAutoConfirmSeconds = (try? c.decode(Int.self, forKey: .installPromptAutoConfirmSeconds)) ?? 10
        verboseLogging             = (try? c.decode(Bool.self, forKey: .verboseLogging)) ?? false
        persistConsoleLog          = (try? c.decode(Bool.self, forKey: .persistConsoleLog)) ?? true
        autoStartServiceIds        = (try? c.decode([String].self, forKey: .autoStartServiceIds)) ?? []
        mcpServerEnabled           = (try? c.decode(Bool.self, forKey: .mcpServerEnabled)) ?? false
        mcpServerPort              = (try? c.decode(Int.self,  forKey: .mcpServerPort))    ?? 8765
        mcpPermDomains             = (try? c.decode(String.self, forKey: .mcpPermDomains))   ?? MCPPermission.write.rawValue
        mcpPermServices            = (try? c.decode(String.self, forKey: .mcpPermServices))  ?? MCPPermission.write.rawValue
        mcpPermDatabases           = (try? c.decode(String.self, forKey: .mcpPermDatabases)) ?? MCPPermission.write.rawValue
        mcpPermLogs                = (try? c.decode(String.self, forKey: .mcpPermLogs))      ?? MCPPermission.write.rawValue
        mcpPermSharing             = (try? c.decode(String.self, forKey: .mcpPermSharing))   ?? MCPPermission.none.rawValue
        // Güncelleme alanları: bu sürümden ÖNCE yazılmış bir settings.json'da hiçbiri
        // yoktur — `try?` + varsayılan sayesinde dosya yine sorunsuz çözülür.
        updateChannel              = (try? c.decode(String.self, forKey: .updateChannel))    ?? UpdateChannel.stable.rawValue
        updateAutoCheck            = (try? c.decode(Bool.self,   forKey: .updateAutoCheck))  ?? true
        updateAutoDownload         = (try? c.decode(Bool.self,   forKey: .updateAutoDownload)) ?? false
        updateMode                 = (try? c.decode(String.self, forKey: .updateMode))       ?? UpdateMode.download.rawValue
        updateSkippedVersion       = (try? c.decode(String.self, forKey: .updateSkippedVersion)) ?? ""
        updateSnoozeUntil          = (try? c.decode(Double.self, forKey: .updateSnoozeUntil)) ?? 0
        updateLastCheck            = (try? c.decode(Double.self, forKey: .updateLastCheck))   ?? 0
    }

    init() {
        self.defaultPHPVersion          = .v83
        self.autoStartServices          = false
        self.showConsoleOutput          = true
        self.autoRefreshInterval        = 30
        self.sitesPath                  = PathConfig.sites
        self.firstSetupCompleted        = false
        self.showMenuBarIcon            = true
        self.hideWindowOnClose          = true
        self.autoStopOnQuit             = true
        self.notificationsEnabled       = true
        self.showCommandsInConsole      = true
        self.showBrewOutputInConsole    = false
        self.stopPHPOnWebServerStop     = true
        self.stopDomainsOnWebServerStop = true
        self.startPHPOnWebServerStart   = true
        self.installPromptAutoConfirm   = true
        self.installPromptAutoConfirmSeconds = 10
        self.verboseLogging             = false
        self.persistConsoleLog          = true
        self.autoStartServiceIds        = []
        self.mcpServerEnabled           = false
        self.mcpServerPort              = 8765
        self.mcpPermDomains             = MCPPermission.write.rawValue
        self.mcpPermServices            = MCPPermission.write.rawValue
        self.mcpPermDatabases           = MCPPermission.write.rawValue
        self.mcpPermLogs                = MCPPermission.write.rawValue
        self.mcpPermSharing             = MCPPermission.none.rawValue
        self.updateChannel              = UpdateChannel.stable.rawValue
        self.updateAutoCheck            = true
        // İKİ AYAR, İKİ AYRI SORU — ve varsayılanları bilerek FARKLI yönde:
        //
        //   • `updateMode` = "bildirim penceresinin ana düğmesi NE YAPSIN". `.notify`
        //     iken düğme yalnızca sürüm sayfasını açar (UpdatePromptView.primaryAction),
        //     yani kutudan çıktığı hâliyle indirme/doğrulama boru hattına — sha256,
        //     codesign, Team ID, noter onayı — ULAŞILAMAZDI. Doğrulanmış indirmeyi
        //     yalnızca ayarları kurcalayan kullanıcıya sunmak, güvenli yolu gizli
        //     yol yapmaktı; `.download` bu yüzden varsayılan.
        //   • `updateAutoDownload` = "SORMADAN indirsin mi". Bu `false` KALIR: 60 MB,
        //     kullanıcının bilgisi dışında ve onun ağından inmez.
        //
        // Birlikte: pencere açılır, hiçbir şey inmez, düğme "İndir ve doğrula" der ve
        // indirme ancak kullanıcı tıklayınca başlar.
        self.updateAutoDownload         = false
        self.updateMode                 = UpdateMode.download.rawValue
        self.updateSkippedVersion       = ""
        self.updateSnoozeUntil          = 0
        self.updateLastCheck            = 0
    }

    // MARK: - Bellek İçi Önbellek (thread-safe)

    /// `load()` 28+ yerden çağrılıyor (bazıları arka plan thread'lerinden, ör. verbose log
    /// callback). Her çağrı diskten okumasın diye son yüklenen/kaydedilen değer önbelleklenir.
    /// Kilit ile korunur — arka plan + MainActor çağrıları güvenli.
    private static let cacheLock = NSLock()
    private static var cached: AppSettings?

    /// - Returns: diske GERÇEKTEN yazıldı mı? Eskiden dönüş yoktu ve `FileHelper.write`
    ///   yalnızca loglayıp `false` döndüğünden, başarısız bir yazım (izin sorunu, dolu disk,
    ///   eksik dizin) tamamen görünmezdi: önbellek yeni değeri tutar, disk eskisinde kalır ve
    ///   ayar bir sonraki açılışta sessizce geri dönerdi.
    @discardableResult
    func save() -> Bool {
        // Önbellek oturum tutarlılığı için güncellenir (UI anında doğru değeri görsün)
        AppSettings.cacheLock.lock()
        AppSettings.cached = self
        AppSettings.cacheLock.unlock()
        do {
            let data = try JSONEncoder().encode(self)
            // Üst dizin yoksa yazım sessizce başarısız olurdu
            FileHelper.createDirectory((PathConfig.settingsJson as NSString).deletingLastPathComponent)
            let ok = FileHelper.write(data, to: PathConfig.settingsJson)
            if !ok { print("❌ Ayarlar diske yazılamadı: \(PathConfig.settingsJson)") }
            return ok
        } catch {
            print("❌ Ayarlar kaydedilemedi: \(error.localizedDescription)")
            return false
        }
    }

    static func load() -> AppSettings {
        cacheLock.lock()
        if let c = cached { cacheLock.unlock(); return c }
        cacheLock.unlock()

        // Disk I/O kilit DIŞINDA — okuma/decode sırasında diğer çağrılar bloklanmaz
        let loaded: AppSettings
        if let data = FileHelper.readData(PathConfig.settingsJson) {
            if let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
                loaded = s
            } else {
                // Dosya VAR ama çözülemedi (elle düzenlemede bozulmuş, yarım yazılmış...).
                // Sessizce varsayılana dönmek VERİ KAYBIDIR: ilk save() bozuk ama
                // KURTARILABİLİR içeriği varsayılanlarla kalıcı olarak ezer.
                // Önce karantinaya al — mevcut yedeğin üzerine yazma (o, ilk bozulma anının
                // kopyası; şu anki dosya artık varsayılanlarla ezilmiş olabilir).
                let backup = PathConfig.settingsJson + ".corrupt.bak"
                if !FileHelper.exists(backup) {
                    FileHelper.copy(from: PathConfig.settingsJson, to: backup)
                    print("⚠️ settings.json çözülemedi — yedeklendi: \(backup)")
                }
                loaded = AppSettings()
            }
        } else {
            loaded = AppSettings()
        }

        cacheLock.lock()
        // Yarış: bu arada başka thread yüklediyse onunkini kullan (tutarlılık)
        if let c = cached { cacheLock.unlock(); return c }
        cached = loaded
        cacheLock.unlock()
        return loaded
    }

    /// SettingsView'in @AppStorage ile aynaladığı UserDefaults anahtarları.
    /// reset() bunları da temizlemeli; aksi halde JSON deposu (manager'ların okuduğu)
    /// sıfırlanırken UI (bu anahtarları okuyan) eski değerleri göstermeye devam eder ve
    /// iki depo kalıcı ayrışır. Bu anahtarların @AppStorage varsayılanları AppSettings()
    /// varsayılanlarıyla birebir eşleşir — silmek UI'yı da varsayılana döndürür.
    static let mirroredDefaultsKeys = [
        "defaultPHPVersion", "autoStartServices", "autoStopOnQuit",
        "notificationsEnabled", "autoRefreshInterval", "showConsoleOutput",
        "showCommandsInConsole", "showBrewOutputInConsole", "stopPHPOnWebServerStop",
        "stopDomainsOnWebServerStop", "startPHPOnWebServerStart",
        "installPromptAutoConfirm", "installPromptAutoConfirmSeconds", "verboseLogging",
        "showMenuBarIcon", "hideWindowOnClose", "persistConsoleLog"
    ]

    /// settings.json uygulama DIŞINDA değiştirildiğinde (yedek geri yükleme) önbelleği
    /// diskteki gerçek içerikle tazeler.
    ///
    /// `cached = nil` YAPILMAZ: reset()'te belgelenen yarışın aynısı oluşurdu — diskten
    /// geri yükleme ÖNCESİ baytları okumuş eşzamanlı bir load(), ikinci kontrolde
    /// `cached == nil` görüp o bayat değeri önbelleğe yazar; sonraki save() de onu diske
    /// geri yazarak geri yüklemeyi sessizce iptal ederdi. Bunun yerine taze değer
    /// kilit altında doğrudan yerine konur.
    static func reloadFromDisk() {
        // Disk I/O kilit DIŞINDA
        let fresh: AppSettings
        if let data = FileHelper.readData(PathConfig.settingsJson),
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            fresh = s
        } else {
            fresh = AppSettings()
        }
        cacheLock.lock()
        cached = fresh
        cacheLock.unlock()
    }

    /// UserDefaults'u (SettingsView'in @AppStorage ile okuduğu depo) settings.json'daki
    /// GERÇEK değerlerle eşitler. Açılışta çağrılır (yalnızca EKSİK anahtarları doldurur).
    ///
    /// Sorun: SettingsView toggle'ları @AppStorage (UserDefaults) okur, çıkış davranışı vb.
    /// AppSettings.load() (JSON) okur. Bir anahtar JSON'da var ama UserDefaults'ta yoksa
    /// (örn. varsayılanı sonradan değişen autoStopOnQuit, ya da eski sürümden gelen JSON),
    /// @AppStorage kod-varsayılanını gösterir → UI ile gerçek davranış çelişir.
    /// Bu eşitleme JSON'u tek doğruluk kaynağı yapıp UI'yı ona hizalar.
    static func hydrateUserDefaults() { writeUserDefaults(overwrite: false) }

    /// Yedek geri yükleme sonrası: JSON'daki değerleri UI deposuna ZORLA yazar.
    /// hydrate yalnızca eksikleri doldurduğundan, geri yüklemede mevcut (eski) değerler
    /// olduğu gibi kalır ve UI ile gerçek davranış ayrışırdı.
    static func overwriteUserDefaults() { writeUserDefaults(overwrite: true) }

    private static func writeUserDefaults(overwrite: Bool) {
        let s = load()
        let ud = UserDefaults.standard
        func put(_ key: String, _ value: Any) {
            if overwrite || ud.object(forKey: key) == nil { ud.set(value, forKey: key) }
        }
        put("defaultPHPVersion", s.defaultPHPVersion.rawValue)
        put("autoStartServices", s.autoStartServices)
        put("autoStopOnQuit", s.autoStopOnQuit)
        put("notificationsEnabled", s.notificationsEnabled)
        put("autoRefreshInterval", s.autoRefreshInterval)
        put("showConsoleOutput", s.showConsoleOutput)
        put("showCommandsInConsole", s.showCommandsInConsole)
        put("showBrewOutputInConsole", s.showBrewOutputInConsole)
        put("stopPHPOnWebServerStop", s.stopPHPOnWebServerStop)
        put("stopDomainsOnWebServerStop", s.stopDomainsOnWebServerStop)
        put("startPHPOnWebServerStart", s.startPHPOnWebServerStart)
        put("installPromptAutoConfirm", s.installPromptAutoConfirm)
        put("installPromptAutoConfirmSeconds", s.installPromptAutoConfirmSeconds)
        put("verboseLogging", s.verboseLogging)
        put("showMenuBarIcon", s.showMenuBarIcon)
        put("hideWindowOnClose", s.hideWindowOnClose)
        put("persistConsoleLog", s.persistConsoleLog)
    }

    static func reset() {
        // Önbellek nil DEĞİL, VARSAYILANLARA çevrilir. nil yapılsaydı: eşzamanlı bir load()
        // diskten az önce okuduğu bayat değeri ikinci kontrolde cached==nil görüp önbelleğe
        // yazar, sonraki save() o bayat değeri diske geri yazar — sıfırlama sessizce geri
        // alınırdı. cached=varsayılan ile yarıştaki load() da varsayılanları döndürür.
        cacheLock.lock()
        cached = AppSettings()
        cacheLock.unlock()
        FileHelper.remove(PathConfig.settingsJson)
        // UI deposunu (UserDefaults) da temizle — JSON ile ayrışmasın.
        for key in mirroredDefaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        print("✅ Ayarlar sıfırlandı")
    }
}
