import Foundation

// ═══════════════════════════════════════════════════════════════════════════
//  EK LOG KATALOGU — log.db.* (veritabanı) ve log.php.* (PHP sürüm/eklenti)
// ═══════════════════════════════════════════════════════════════════════════
//
//  Kaynak dosyalar: Views/DatabaseTabView.swift, Managers/PHPExtensionManager.swift
//  Kurallar ve anahtar biçimi: Core/L10nLog.swift dosyasının başındaki blok.
//  Bu sözlük `L10n.extraLogCatalogs` üzerinden aramaya katılır.
//
//  UYARI: Swift sözlük değişmezinde AYNI ANAHTAR İKİ KEZ geçerse uygulama
//  ÇALIŞMA ZAMANINDA ÇÖKER — yeni anahtar eklemeden önce grep ile denetleyin.
// ═══════════════════════════════════════════════════════════════════════════

extension L10n {

    static let logCatalog_dbPHP: [String: [String: String]] = [

        // ── log.db.* — Veritabanı işlemleri ─────────────────────────────────
        "log.db.unsupportedName":
            ["tr": "Bu veritabanı adı desteklenmiyor: %@",
             "en": "This database name is not supported: %@"],
        // %@1 = veritabanı adı, %@2 = hedef dosya adı
        "log.db.dumpStart":
            ["tr": "'%@' yedeği alınıyor → %@",
             "en": "Backing up '%@' → %@"],
        // %@1 = veritabanı adı, %@2 = boyut (KB), %@3 = dosya yolu
        "log.db.dumpDone":
            ["tr": "'%@' yedeği alındı (%@ KB): %@",
             "en": "Backed up '%@' (%@ KB): %@"],
        "log.db.invalidTargetName":
            ["tr": "Geçersiz hedef veritabanı adı — yalnızca harf, rakam, _ ve - kullanın",
             "en": "Invalid target database name — use only letters, digits, _ and -"],
        // %@1 = hedef veritabanı, %@2 = kaynak dosya adı
        "log.db.restoreStart":
            ["tr": "'%@' veritabanına geri yükleniyor ← %@",
             "en": "Restoring into '%@' ← %@"],
        "log.db.restoreDone":
            ["tr": "'%@' geri yüklendi",
             "en": "'%@' restored"],
        "log.db.listFailed":
            ["tr": "Veritabanları listelenemedi: %@",
             "en": "Could not list databases: %@"],
        "log.db.invalidName":
            ["tr": "Geçersiz veritabanı adı — yalnızca harf, rakam, _ ve - kullanın (maks 64 karakter)",
             "en": "Invalid database name — use only letters, digits, _ and - (max 64 characters)"],
        "log.db.created":
            ["tr": "'%@' veritabanı oluşturuldu",
             "en": "Database '%@' created"],
        "log.db.dropped":
            ["tr": "'%@' veritabanı silindi",
             "en": "Database '%@' deleted"],

        // ── log.db.* — pgAdmin4 / web sunucusu yapılandırması ────────────────
        "log.db.pgadminApacheConfiguring":
            ["tr": "🔧 Apache için pgAdmin4 yapılandırılıyor...",
             "en": "🔧 Configuring pgAdmin4 for Apache…"],
        "log.db.pgadminConfWriteFailed":
            ["tr": "pgadmin4.conf yazılamadı: %@",
             "en": "Could not write pgadmin4.conf: %@"],
        "log.db.pgadminConfCreated":
            ["tr": "pgadmin4.conf oluşturuldu",
             "en": "pgadmin4.conf created"],
        "log.db.httpdReadFailed":
            ["tr": "httpd.conf okunamadı",
             "en": "Could not read httpd.conf"],
        "log.db.httpdUpdated":
            ["tr": "httpd.conf güncellendi — pgAdmin4 include eklendi",
             "en": "httpd.conf updated — pgAdmin4 include added"],
        "log.db.restartApacheHint":
            ["tr": " Apache'yi yeniden başlatın: Servisler → Apache → Yeniden Başlat",
             "en": " Restart Apache: Services → Apache → Restart"],
        "log.db.httpdWriteFailed":
            ["tr": "httpd.conf yazılamadı — sudo izni gerekebilir",
             "en": "Could not write httpd.conf — sudo permission may be required"],
        "log.db.httpdAlreadyIncludes":
            ["tr": " httpd.conf zaten pgAdmin4 include içeriyor",
             "en": " httpd.conf already contains the pgAdmin4 include"],
        "log.db.pgadminNginxConfiguring":
            ["tr": "🔧 Nginx için pgAdmin4 yapılandırılıyor...",
             "en": "🔧 Configuring pgAdmin4 for Nginx…"],
        "log.db.nginxConfNotFound":
            ["tr": "nginx.conf bulunamadı",
             "en": "nginx.conf not found"],
        "log.db.nginxUpdated":
            ["tr": "nginx.conf güncellendi — pgAdmin4 location bloğu eklendi",
             "en": "nginx.conf updated — pgAdmin4 location block added"],
        "log.db.restartNginxHint":
            ["tr": " Nginx'i yeniden başlatın: Servisler → Nginx → Yeniden Başlat",
             "en": " Restart Nginx: Services → Nginx → Restart"],
        "log.db.nginxWriteFailed":
            ["tr": "nginx.conf yazılamadı",
             "en": "Could not write nginx.conf"],

        // ── log.db.* — Ayar dosyaları (postgresql.conf / my.cnf / redis.conf) ─
        "log.db.pgConfReadFailed":
            ["tr": "postgresql.conf okunamadı",
             "en": "Could not read postgresql.conf"],
        "log.db.pgSettingsSaved":
            ["tr": "PostgreSQL ayarları kaydedildi",
             "en": "PostgreSQL settings saved"],
        "log.db.pgConfWriteFailed":
            ["tr": "postgresql.conf yazılamadı",
             "en": "Could not write postgresql.conf"],
        "log.db.myCnfSaved":
            ["tr": "my.cnf ayarları kaydedildi (my.cnf.d/zz-brampp.cnf)",
             "en": "my.cnf settings saved (my.cnf.d/zz-brampp.cnf)"],
        "log.db.redisSaved":
            ["tr": "redis.conf ayarları kaydedildi",
             "en": "redis.conf settings saved"],

        // ── log.php.* — Eklenti listesi ──────────────────────────────────────
        "log.php.profilerTrigger":
            ["tr": "Profilleyici açık (PHP %@) — yalnızca XDEBUG_TRIGGER taşıyan istekler ölçülür",
             "en": "Profiler on (PHP %@) — only requests carrying XDEBUG_TRIGGER are measured"],
        "log.php.profilerAlways":
            ["tr": "⚠️ Profilleyici HER istekte açık (PHP %@) — site yavaşlar ve disk hızla dolar",
             "en": "⚠️ Profiler on for EVERY request (PHP %@) — the site slows down and the disk fills fast"],
        "log.php.profilerOff":
            ["tr": "Profilleyici kapatıldı (PHP %@)",
             "en": "Profiler turned off (PHP %@)"],
        "log.php.profilesCleared":
            ["tr": "Profil dosyaları silindi",
             "en": "Profile files deleted"],
        "log.php.iniWriteFailed":
            ["tr": "php.ini yazılamadı — yedek .brampp.bak olarak duruyor",
             "en": "could not write php.ini — the backup is at .brampp.bak"],
        "log.php.loading":
            ["tr": "PHP %@ eklentileri yükleniyor...",
             "en": "Loading PHP %@ extensions…"],
        "log.php.loaded":
            ["tr": "Eklentiler yüklendi (%@ aktif)",
             "en": "Extensions loaded (%@ enabled)"],

        // ── log.php.* — Etkinleştir / devre dışı bırak ───────────────────────
        "log.php.enabling":
            ["tr": "%@ aktif ediliyor...",
             "en": "Enabling %@…"],
        "log.php.moveFailed":
            ["tr": "Taşıma hatası",
             "en": "Move failed"],
        "log.php.configWriteFailed":
            ["tr": "Config yazılamadı",
             "en": "Could not write the config file"],
        "log.php.enabled":
            ["tr": "%@ aktif edildi",
             "en": "%@ enabled"],
        "log.php.builtInNoDisable":
            ["tr": "Yerleşik (built-in) eklenti deaktif edilemez",
             "en": "A built-in extension cannot be disabled"],
        "log.php.disabling":
            ["tr": "%@ deaktif ediliyor...",
             "en": "Disabling %@…"],
        "log.php.disableFailed":
            ["tr": "Deaktif etme hatası",
             "en": "Could not disable the extension"],
        "log.php.disabled":
            ["tr": "%@ deaktif edildi",
             "en": "%@ disabled"],

        // ── log.php.* — Kurulum ──────────────────────────────────────────────
        "log.php.installing":
            ["tr": "%@ kuruluyor...",
             "en": "Installing %@…"],
        "log.php.depInstalling":
            ["tr": "Bağımlılık kuruluyor: %@",
             "en": "Installing dependency: %@"],
        "log.php.depFailed":
            ["tr": "Bağımlılık hatası: %@",
             "en": "Dependency error: %@"],
        // %@1 = eklenti adı, %@2 = PHP sürümü
        "log.php.installed":
            ["tr": "%@ kuruldu (PHP %@)",
             "en": "%@ installed (PHP %@)"],
        // %@1 = eklenti adı, %@2 = hata çıktısı
        "log.php.installFailed":
            ["tr": "%@ kurulamadı: %@",
             "en": "Could not install %@: %@"],
        "log.php.iniDupCleaned":
            ["tr": "%@: ana php.ini'deki çift kayıt temizlendi",
             "en": "%@: removed the duplicate entry from the main php.ini"],

        // ── log.php.* — imagick özel kurulumu ────────────────────────────────
        "log.php.imagickStart":
            ["tr": "imagick kurulum süreci başlatılıyor...",
             "en": "Starting the imagick installation process…"],
        "log.php.platform":
            ["tr": "Platform: %@",
             "en": "Platform: %@"],
        "log.php.imagickWaiting":
            ["tr": "Kurulum Terminal penceresinde sürüyor — tamamlanması bekleniyor...",
             "en": "Installation is running in the Terminal window — waiting for it to finish…"],
        "log.php.imagickDone":
            ["tr": "imagick kurulumu tamamlandı (PHP %@)",
             "en": "imagick installation finished (PHP %@)"],
        "log.php.imagickFailed":
            ["tr": "imagick kurulumu başarısız (kod %@) — Terminal çıktısını kontrol edin",
             "en": "imagick installation failed (code %@) — check the Terminal output"],
        "log.php.imagickTimeout":
            ["tr": "imagick kurulumu 20 dakika içinde tamamlanmadı — Terminal penceresini kontrol edin",
             "en": "imagick installation did not finish within 20 minutes — check the Terminal window"],

        // ── log.php.* — php.ini ve PHP-FPM ───────────────────────────────────
        "log.php.iniNotFound":
            ["tr": "php.ini bulunamadı",
             "en": "php.ini not found"],
        // %@1 = ayar adı, %@2 = yeni değer
        "log.php.iniUpdated":
            ["tr": "php.ini güncellendi: %@ = %@",
             "en": "php.ini updated: %@ = %@"],
        "log.php.iniUpdateFailed":
            ["tr": "php.ini güncellenemedi",
             "en": "Could not update php.ini"],
        "log.php.fpmPrepared":
            ["tr": "PHP %@ FPM ayarları hazırlandı",
             "en": "PHP %@ FPM settings prepared"],
    ]
}
