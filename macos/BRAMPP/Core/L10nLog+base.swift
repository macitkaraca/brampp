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
