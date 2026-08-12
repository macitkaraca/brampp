import Foundation

// BaseManager ortak yardımcılarının (requireBrew / logResult / restartBrewService)
// ürettiği loglar ve bunlara geçirilen "işlem adı" metinleri.
//
// `log.op.*` anahtarları TEK BAŞINA cümle değildir: "Homebrew kurulu değil — %@
// yapılamıyor" kalıbının içine yerleşirler. Bu yüzden Türkçede -me/-ma eki almış
// isim-fiil ("domain oluşturma"), İngilizcede ise "cannot %@" kalıbına oturan
// -ing biçimi ("create domains") kullanılır.
extension L10n {
    static let logCatalog_base: [String: [String: String]] = [
        // ── Brew guard ──────────────────────────────────────────────────────
        "log.base.brewMissing":     ["tr": "Homebrew kurulu değil — %@ yapılamıyor",
                                    "en": "Homebrew is not installed — cannot %@"],
        "log.app.brewInstallHint": ["tr": "Kurulum sihirbazından Homebrew'i kurabilirsiniz",
                                    "en": "You can install Homebrew from the setup wizard"],

        // ── Ortak ortam koruması (Core/ProcessRole.swift) ───────────────────
        // Bu süreç makinenin ortak durumuna (tünel dizini, Homebrew servisleri,
        // MCP portu, son-çalışan-servisler dosyası) YAZMAYACAK. Satır uyarı
        // düzeyindedir: uygulama normal görünür ama bu işleri yapmadığı bilinmeli.
        "log.app.sharedEnvTestHost":
            ["tr": "Test ana uygulaması olarak çalışılıyor — makinenin ortak durumuna dokunulmayacak (tünel toparlaması, MCP dinleyicisi, otomatik servis başlatma atlandı)",
             "en": "Running as a test host — the machine's shared state will not be touched (tunnel reaping, MCP listener and auto-start services were skipped)"],
        "log.app.sharedEnvOtherInstance":
            ["tr": "Bu makinede başka bir BRAMPP kopyası çalışıyor — makinenin ortak durumu ona bırakıldı (tünel toparlaması, MCP dinleyicisi, otomatik servis başlatma atlandı)",
             "en": "Another BRAMPP instance is running on this machine — its shared state was left alone (tunnel reaping, MCP listener and auto-start services were skipped)"],

        // ── Uygulama güncellemesi (Core/UpdateChecker.swift, UpdateInstaller.swift) ──
        // `log.app.*` alanı uygulama yaşam döngüsüne ait (L10nLog.swift kural 2);
        // güncelleme denetimi için AYRI bir ön ek uydurulmaz.
        // %@ = kanal adı
        "log.app.updateCheckStarted":
            ["tr": "Güncelleme denetimi başladı (%@ kanalı)",
             "en": "Update check started (%@ channel)"],
        // %@1 = yeni sürüm, %@2 = kurulu sürüm
        "log.app.updateAvailable":
            ["tr": "Yeni sürüm bulundu: %@ — kurulu sürüm %@",
             "en": "A newer version was found: %@ — the installed version is %@"],
        // %@ = kurulu sürüm
        "log.app.updateUpToDate":
            ["tr": "Uygulama güncel: %@",
             "en": "The app is up to date: %@"],
        // %@ = kurulu sürüm. Daha yenisi YOK; uyarının kaynağı manifestin
        // `blockedVersions` listesi (spec/update-manifest.md).
        "log.app.updateCurrentBlocked":
            ["tr": "Kullandığınız sürüm (%@) sorunlu olarak işaretlenmiş — düzeltilmiş bir sürüm henüz yayınlanmadı",
             "en": "The version you are running (%@) was flagged as faulty — no fixed release has been published yet"],
        "log.app.updateCheckFailed":
            ["tr": "Güncelleme denetlenemedi — sürüm bilgisi okunamadı",
             "en": "The update check failed — the version information could not be read"],
        // %@ = istenen kanal
        "log.app.updateManifestFallback":
            ["tr": "%@ kanalı okunamadı — GitHub sürüm bilgisine düşüldü, sağlama doğrulaması yapılamaz",
             "en": "The %@ channel could not be read — fell back to GitHub release information, checksum verification is unavailable"],
        "log.app.selfUpdateStarting":
            ["tr": "Yerinde güncelleme: yeni sürüm hazırlandı, BRAMPP kapanıp yeni sürümle açılacak — Homebrew servisleriniz çalışmaya devam eder",
             "en": "Updating in place: the new version is staged, BRAMPP will quit and reopen on it — your Homebrew services keep running"],
        // %@ = hata metni
        "log.app.selfUpdateLaunchFailed":
            ["tr": "❌ Güncelleme adımı başlatılamadı, kurulu sürüm olduğu gibi duruyor: %@",
             "en": "❌ The update step could not be started, your installed version is untouched: %@"],
        // %@ = atlanan sürüm
        "log.app.updateSkipped":
            ["tr": "%@ sürümü kullanıcı tarafından atlandı — bildirim gösterilmedi",
             "en": "Version %@ was skipped by the user — no notice was shown"],
        // %@ = erteleme bitiş tarihi
        "log.app.updateSnoozed":
            ["tr": "Güncelleme bildirimi %@ tarihine kadar ertelendi",
             "en": "The update notice is snoozed until %@"],
        // %@ = indirilen sürüm
        "log.app.updateDownloadStarted":
            ["tr": "Güncelleme indiriliyor: %@",
             "en": "Downloading the update: %@"],
        "log.app.updateVerifyOk":
            ["tr": "İndirilen sürüm doğrulandı — imza, noter onayı ve geliştirici kimliği geçti",
             "en": "The download verified — signature, notarization and Team ID all passed"],
        // %@ = başarısızlık nedeni (upd.fail.* anahtarı, `@` ile argüman olarak geçer)
        "log.app.updateVerifyFailed":
            ["tr": "Güncelleme doğrulanamadı (%@) — indirilen dosya silindi",
             "en": "The update did not verify (%@) — the download was deleted"],

        // ── Brew servis yeniden başlatma (BaseManager) ──────────────────────
        // logResult(failureKey:) kalıpları SONDA bir `%@` taşır: shell hata
        // detayı oraya yerleşir (detay yoksa boş string geçilir).
        "log.base.restarting":  ["tr": "%@ yeniden başlatılıyor...", "en": "Restarting %@…"],
        "log.base.restartOk":   ["tr": "%@ yeniden başlatıldı",      "en": "%@ restarted"],
        "log.base.restartFail": ["tr": "%@ yeniden başlatılamadı%@", "en": "Could not restart %@%@"],

        // ── İşlem adları (requireBrew(forKey:) ile geçirilir) ───────────────
        // Argüman ALAN kalıplar requireBrew'e `L10n.logArg(key:_:)` ile kodlanmış
        // biçimde ulaşır; iç metin de gösterim anında çözülür.
        "log.op.statusCheck":        ["tr": "servis durumu kontrolü",        "en": "check service status"],
        "log.op.startAll":           ["tr": "tüm servisleri başlatma",       "en": "start all services"],
        "log.op.stopAll":            ["tr": "tüm servisleri durdurma",       "en": "stop all services"],
        "log.op.stopOnQuit":         ["tr": "çıkışta servisleri durdurma",   "en": "stop services on quit"],
        "log.op.webServerStart":     ["tr": "web sunucusu başlatma",         "en": "start the web server"],
        "log.op.domainCreate":       ["tr": "domain oluşturma",              "en": "create domains"],
        "log.op.vhostCreate":        ["tr": "VHost oluşturma",               "en": "create vhosts"],
        "log.op.sslCreate":          ["tr": "SSL sertifika oluşturma",       "en": "create SSL certificates"],
        // Servis eylemleri: anahtar adı ServiceManager.actionKeySuffix ile üretilir
        // (log.op.service + Start|Stop|Restart).
        "log.op.serviceStart":       ["tr": "%@ başlatma",                   "en": "start %@"],
        "log.op.serviceStop":        ["tr": "%@ durdurma",                   "en": "stop %@"],
        "log.op.serviceRestart":     ["tr": "%@ yeniden başlatma",           "en": "restart %@"],
        "log.op.serviceInstall":     ["tr": "%@ kurma",                      "en": "install %@"],
        "log.op.serviceUninstall":   ["tr": "%@ kaldırma",                   "en": "uninstall %@"],
        "log.op.pgConfigure":        ["tr": "PostgreSQL %@ yapılandırması",  "en": "configure PostgreSQL %@"],
        "log.op.pgadminInstall":     ["tr": "pgAdmin4 kurma",                "en": "install pgAdmin4"],
        "log.op.pgadminUninstall":   ["tr": "pgAdmin4 kaldırma",             "en": "uninstall pgAdmin4"],
        "log.op.phpmyadminInstall":  ["tr": "phpMyAdmin kurma",              "en": "install phpMyAdmin"],
        "log.op.phpIniUpdate":       ["tr": "php.ini güncelleme",            "en": "update php.ini"],
        "log.op.phpExtLoad":         ["tr": "PHP extension yükleme",         "en": "load PHP extensions"],
        "log.op.extEnable":          ["tr": "extension aktif etme",          "en": "enable an extension"],
        "log.op.extDisable":         ["tr": "extension deaktif etme",        "en": "disable an extension"],
        "log.op.extInstall":         ["tr": "extension kurma",               "en": "install an extension"],
        "log.op.imagickInstall":     ["tr": "imagick kurma",                 "en": "install imagick"],
    ]
}
