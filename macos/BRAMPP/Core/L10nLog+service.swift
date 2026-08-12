import Foundation

// ═══════════════════════════════════════════════════════════════════════════
//  log.svc.* — SERVİS KONSOL SATIRLARI (Managers/ServiceManager.swift)
// ═══════════════════════════════════════════════════════════════════════════
//  Kurallar ve çağrı biçimi: Core/L10nLog.swift dosyasının başındaki blok.
//  Bu sözlük `L10n.logEntry(for:)` tarafından ana log katalogundan ÖNCE taranır.
//
//  DİKKAT: Swift sözlük değişmezinde AYNI anahtar iki kez geçerse uygulama
//  ÇALIŞMA ZAMANINDA ÇÖKER. Yeni anahtar eklemeden önce grep ile denetleyin.
// ═══════════════════════════════════════════════════════════════════════════

extension L10n {

    /// ServiceManager'ın konsol satırları: anahtar → [dilKodu: metin].
    static let logCatalog_service: [String: [String: String]] = [

        // ── Durum kontrolü ──────────────────────────────────────────────────
        "log.svc.statusChecking":
            ["tr": "Servis durumları kontrol ediliyor...",
             "en": "Checking service statuses…"],
        "log.svc.statusUpdated":
            ["tr": "Servis durumları güncellendi",
             "en": "Service statuses updated"],
        "log.svc.statusCheckingLight":
            ["tr": "Servis durumları kontrol ediliyor... (Hafif)",
             "en": "Checking service statuses… (light)"],
        "log.svc.statusUpdatedLight":
            ["tr": "Servis durumları güncellendi (Hafif)",
             "en": "Service statuses updated (light)"],
        // %@ = servis adı
        "log.svc.crashed":
            ["tr": "%@ beklenmedik şekilde durdu!",
             "en": "%@ stopped unexpectedly!"],

        // ── Bağımlılık / açılış ─────────────────────────────────────────────
        // %@ = servis adı
        "log.svc.cascadeStop":
            ["tr": "↳ %@ durduruluyor (web sunucusu kalmadı)",
             "en": "↳ Stopping %@ (no web server left running)"],
        "log.svc.allWebServersStopped":
            ["tr": "↳ Tüm web sunucuları durdu — domain backend prosesleri durduruluyor...",
             "en": "↳ All web servers stopped — shutting down domain backend processes…"],
        // %@ = servis adı
        "log.svc.startupLaunching":
            ["tr": "↳ açılışta başlatılıyor: %@",
             "en": "↳ Starting at launch: %@"],

        // ── Başlat / durdur / yeniden başlat ────────────────────────────────
        // NOT: fiil çekimi TR ve EN'de farklı kurulduğundan ARGÜMAN olarak
        // geçirilemez — her eylemin KENDİ anahtarı vardır (begin/done/failed +
        // Start|Stop|Restart). Anahtar adı ServiceManager.actionKeySuffix ile üretilir.
        // %@ = servis adı
        "log.svc.beginStart":
            ["tr": "%@ başlatılıyor...",
             "en": "Starting %@…"],
        "log.svc.beginStop":
            ["tr": "%@ durduruluyor...",
             "en": "Stopping %@…"],
        "log.svc.beginRestart":
            ["tr": "%@ yeniden başlatılıyor...",
             "en": "Restarting %@…"],
        "log.svc.doneStart":
            ["tr": "%@ — başlatma tamam",
             "en": "%@ — started"],
        "log.svc.doneStop":
            ["tr": "%@ — durdurma tamam",
             "en": "%@ — stopped"],
        "log.svc.doneRestart":
            ["tr": "%@ — yeniden başlatma tamam",
             "en": "%@ — restarted"],
        // %@1 = servis adı, %@2 = hata açıklaması
        "log.svc.failedStart":
            ["tr": "%@ — başlatma başarısız: %@",
             "en": "%@ — could not start: %@"],
        "log.svc.failedStop":
            ["tr": "%@ — durdurma başarısız: %@",
             "en": "%@ — could not stop: %@"],
        "log.svc.failedRestart":
            ["tr": "%@ — yeniden başlatma başarısız: %@",
             "en": "%@ — could not restart: %@"],

        // %@1 = servis adı, %@2 = port
        "log.svc.portInUse":
            ["tr": "%@ — Port :%@ zaten kullanılıyor! Başlatma iptal edildi.",
             "en": "%@ — port :%@ is already in use! Start cancelled."],
        // %@ = servis adı
        "log.svc.alreadyRunning":
            ["tr": "%@ — zaten çalışıyor",
             "en": "%@ — already running"],
        "log.svc.alreadyStopped":
            ["tr": "%@ — zaten durdurulmuş",
             "en": "%@ — already stopped"],
        // %@1 = servis adı, %@2 = port
        "log.svc.startedPortActive":
            ["tr": "%@ — başlatıldı (:%@ aktif)",
             "en": "%@ — started (:%@ is listening)"],
        // %@ = servis adı
        "log.svc.startedPortSilent":
            ["tr": "%@ — brew başarılı ancak port yanıt vermiyor",
             "en": "%@ — brew succeeded but the port is not responding"],
        "log.svc.started":
            ["tr": "%@ başlatıldı",
             "en": "%@ started"],
        "log.svc.startedNoResponse":
            ["tr": "%@ başlatıldı ancak yanıt vermiyor",
             "en": "%@ started but is not responding"],
        "log.svc.autoStartForDomain":
            ["tr": "%@ durdurulmuş — domain için otomatik başlatılıyor...",
             "en": "%@ is stopped — starting it automatically for the domain…"],
        // %@1 = servis adı, %@2 = hata açıklaması
        "log.svc.autoStartFailed":
            ["tr": "%@ otomatik başlatılamadı: %@",
             "en": "Could not auto-start %@: %@"],
        // Bağımlılık kurulu değil — brew çağrılmadan önce elenir
        "log.svc.depNotInstalled":
            ["tr": "⚠️ %@ kurulu değil — başlatılamıyor (Servisler sekmesinden kurun)",
             "en": "⚠️ %@ is not installed — cannot start it (install it from the Services tab)"],
        "log.svc.depUnknown":
            ["tr": "⚠️ Bilinmeyen bağımlılık servisi: %@",
             "en": "⚠️ Unknown dependency service: %@"],

        // ── Toplu işlemler ──────────────────────────────────────────────────
        "log.svc.startAll":
            ["tr": "Tüm servisler başlatılıyor...",
             "en": "Starting all services…"],
        "log.svc.stopAll":
            ["tr": "Tüm servisler durduruluyor...",
             "en": "Stopping all services…"],
        // %@ = virgülle ayrılmış servis adları
        "log.svc.skipRunning":
            ["tr": "Zaten çalışıyor, atlanıyor: %@",
             "en": "Already running, skipping: %@"],
        // %@ = servis sayısı
        "log.svc.quitStopping":
            ["tr": "Çıkış: %@ servis durduruluyor...",
             "en": "Quitting: stopping %@ service(s)…"],
        // %@ = çalışan domain (PHP/Node yerel süreç) sayısı — brew servisi DEĞİL
        "log.svc.quitStoppingDomains":
            ["tr": "Çıkış: %@ domain süreci durduruluyor...",
             "en": "Quitting: stopping %@ domain process(es)…"],

        // ── Kurulum / kaldırma ──────────────────────────────────────────────
        // %@ = servis adı
        "log.svc.installing":
            ["tr": "%@ kuruluyor...",
             "en": "Installing %@…"],
        "log.svc.installed":
            ["tr": "%@ kuruldu",
             "en": "%@ installed"],
        // %@1 = servis adı, %@2 = hata açıklaması
        "log.svc.installFailed":
            ["tr": "%@ kurulamadı: %@",
             "en": "Could not install %@: %@"],
        // %@ = servis adı
        "log.svc.uninstalling":
            ["tr": "%@ kaldırılıyor...",
             "en": "Uninstalling %@…"],
        "log.svc.uninstalled":
            ["tr": "%@ kaldırıldı",
             "en": "%@ uninstalled"],
        // %@1 = servis adı, %@2 = hata açıklaması
        "log.svc.uninstallFailed":
            ["tr": "%@ kaldırılamadı: %@",
             "en": "Could not uninstall %@: %@"],
        // %@ = servis adı
        "log.svc.uninstallScriptFailed":
            ["tr": "%@ — kaldırma scripti oluşturulamadı",
             "en": "%@ — could not create the uninstall script"],
        // %@ = zaman aşımı (saniye)
        "log.svc.autoConfirmSent":
            ["tr": "Otomatik onay: 'y' gönderildi (%@sn zaman aşımı)",
             "en": "Auto-confirm: sent 'y' (%@s timeout)"],

        // ── PHP / varsayılan sürüm ──────────────────────────────────────────
        // %@ = PHP sürümü
        "log.svc.phpFpmNormalized":
            ["tr": "PHP %@ FPM ayarları uygulandı",
             "en": "PHP %@ FPM settings applied"],
        // %@ = port
        "log.svc.defaultPhpPortApplying":
            ["tr": "Varsayılan PHP portu (%@) tüm yapılandırmalara uygulanıyor...",
             "en": "Applying the default PHP port (%@) to all configurations…"],
        "log.svc.defaultPhpPortApplied":
            ["tr": "Varsayılan PHP portu güncellendi ve web sunucuları yeniden yüklendi",
             "en": "Default PHP port updated and web servers reloaded"],

        // ── Apache / Nginx yapılandırma dosyaları ───────────────────────────
        "log.svc.httpdConfMissing":
            ["tr": "httpd.conf bulunamadı — Apache kurulu mu?",
             "en": "httpd.conf not found — is Apache installed?"],
        "log.svc.httpdConfReadFailed":
            ["tr": "httpd.conf okunamadı",
             "en": "Could not read httpd.conf"],
        "log.svc.httpdConfWriteFailed":
            ["tr": "httpd.conf yazılamadı",
             "en": "Could not write httpd.conf"],
        "log.svc.httpdSslConfWriteFailed":
            ["tr": "httpd-ssl.conf yazılamadı",
             "en": "Could not write httpd-ssl.conf"],
        "log.svc.nginxConfMissing":
            ["tr": "nginx.conf bulunamadı",
             "en": "nginx.conf not found"],
        "log.svc.nginxConfReadFailed":
            ["tr": "nginx.conf okunamadı",
             "en": "Could not read nginx.conf"],
        "log.svc.nginxConfWriteFailed":
            ["tr": "nginx.conf yazılamadı",
             "en": "Could not write nginx.conf"],
        // %@ = SSL notu (@log.svc.nginxSslNote*)
        "log.svc.nginxMainConfigCreated":
            ["tr": "Nginx ana yapılandırması oluşturuldu%@",
             "en": "Nginx main configuration created%@"],
        "log.svc.nginxMainConfigWriteFailed":
            ["tr": "Nginx nginx.conf yazılamadı — yetersiz yetki?",
             "en": "Could not write nginx.conf — insufficient permissions?"],
        // ARGÜMAN olarak geçirilen SSL notları
        "log.svc.nginxSslNoteBoth":
            ["tr": " (HTTP :8080 + HTTPS :8443)",
             "en": " (HTTP :8080 + HTTPS :8443)"],
        "log.svc.nginxSslNoteHttpOnly":
            ["tr": " (HTTP :8080 — SSL henüz yok)",
             "en": " (HTTP :8080 — no SSL yet)"],
        // Yeniden başlatma ipuçları (birden çok yerde kullanılır)
        "log.svc.restartApacheHint":
            ["tr": "Apache'yi yeniden başlatın: Servisler → Apache → Yeniden Başlat",
             "en": "Restart Apache: Services → Apache → Restart"],
        "log.svc.restartNginxHint":
            ["tr": "Nginx'i yeniden başlatın: Servisler → Nginx → Yeniden Başlat",
             "en": "Restart Nginx: Services → Nginx → Restart"],
        "log.svc.restartWebServersHint":
            ["tr": "Web sunucularını yeniden başlatın (Apache/Nginx)",
             "en": "Restart the web servers (Apache/Nginx)"],

        // ── Port ayarları ───────────────────────────────────────────────────
        // %@ = port
        "log.svc.apacheHttpPortUpdated":
            ["tr": "HTTP portu güncellendi: :%@",
             "en": "HTTP port updated: :%@"],
        "log.svc.apacheHttpsPortUpdated":
            ["tr": "HTTPS portu güncellendi: :%@",
             "en": "HTTPS port updated: :%@"],
        // %@ = güncellenen vhost dosyası sayısı (yalnızca GERÇEKTEN yazılanlar sayılır)
        "log.svc.apacheVhostPortsUpdated":
            ["tr": "Apache vhost portları güncellendi (%@ dosya)",
             "en": "Apache vhost ports updated (%@ file(s))"],
        // Yamalanan config Apache'ye doğrulatılamadı: yarım yamalı bir yapılandırma
        // Apache'yi hiç başlatmaz, bu yüzden DOKUNULAN HER dosya eski hâline döner.
        "log.svc.apachePortsRolledBack":
            ["tr": "Apache yapılandırması geçersiz — port değişikliği geri alındı, dosyalar eski hâline döndürüldü",
             "en": "The Apache configuration did not validate — the port change was rolled back and every file was restored"],
        // %@1 = HTTP portu, %@2 = HTTPS portu, %@3 = güncellenen dosya sayısı
        "log.svc.nginxPortsUpdated":
            ["tr": "Nginx portları güncellendi — HTTP :%@, HTTPS :%@ (%@ dosya)",
             "en": "Nginx ports updated — HTTP :%@, HTTPS :%@ (%@ file(s))"],
        "log.svc.nginxPortsNoFiles":
            ["tr": "Nginx port güncellemesi: değiştirilecek dosya bulunamadı",
             "en": "Nginx port update: no files found to change"],

        // ── phpMyAdmin ──────────────────────────────────────────────────────
        "log.svc.pmaInstalling":
            ["tr": "phpMyAdmin kuruluyor...",
             "en": "Installing phpMyAdmin…"],
        "log.svc.pmaInstalled":
            ["tr": "phpMyAdmin kuruldu",
             "en": "phpMyAdmin installed"],
        // %@ = hata açıklaması
        "log.svc.pmaInstallFailed":
            ["tr": "phpMyAdmin kurulamadı: %@",
             "en": "Could not install phpMyAdmin: %@"],
        "log.svc.pmaApacheConfiguring":
            ["tr": "🔧 phpMyAdmin Apache yapılandırması oluşturuluyor...",
             "en": "🔧 Creating the phpMyAdmin Apache configuration…"],
        "log.svc.pmaConfCreated":
            ["tr": "✅ extra/phpmyadmin.conf oluşturuldu",
             "en": "✅ extra/phpmyadmin.conf created"],
        "log.svc.pmaConfWriteFailed":
            ["tr": "❌ extra/phpmyadmin.conf yazılamadı",
             "en": "❌ Could not write extra/phpmyadmin.conf"],
        "log.svc.pmaIncludeAdded":
            ["tr": "✅ httpd.conf — IncludeOptional eklendi",
             "en": "✅ httpd.conf — IncludeOptional added"],
        "log.svc.pmaIncludeFailed":
            ["tr": "❌ httpd.conf — include eklenemedi",
             "en": "❌ httpd.conf — could not add the include"],
        "log.svc.pmaAppConfigUpdated":
            ["tr": "✅ phpmyadmin.config.inc.php güncellendi",
             "en": "✅ phpmyadmin.config.inc.php updated"],
        "log.svc.pmaAppConfigFailed":
            ["tr": "❌ phpmyadmin.config.inc.php yazılamadı",
             "en": "❌ Could not write phpmyadmin.config.inc.php"],

        // ── MariaDB root yapılandırması ─────────────────────────────────────
        "log.svc.mariadbRootConfiguring":
            ["tr": "🔧 MariaDB root@localhost yapılandırılıyor...",
             "en": "🔧 Configuring MariaDB root@localhost…"],
        "log.svc.mariadbTempStarting":
            ["tr": "MariaDB çalışmıyor — geçici olarak başlatılıyor...",
             "en": "MariaDB is not running — starting it temporarily…"],
        "log.svc.mariadbStartFailed":
            ["tr": "MariaDB başlatılamadı",
             "en": "Could not start MariaDB"],
        "log.svc.mariadbStarted":
            ["tr": "MariaDB başlatıldı",
             "en": "MariaDB started"],
        "log.svc.mariadbRootConfiguredTCP":
            ["tr": "MariaDB root@localhost yapılandırıldı — root / boş şifre ile TCP bağlantısı açık",
             "en": "MariaDB root@localhost configured — TCP access open with user root and an empty password"],
        "log.svc.mariadbRootConfigured":
            ["tr": "MariaDB root@localhost yapılandırıldı",
             "en": "MariaDB root@localhost configured"],
        // %@ = hata açıklaması
        "log.svc.mariadbRootConfigureFailed":
            ["tr": "MariaDB root@localhost yapılandırılamadı: %@",
             "en": "Could not configure MariaDB root@localhost: %@"],
        "log.svc.mariadbTempStopped":
            ["tr": "MariaDB durduruldu (geçici başlatılmıştı)",
             "en": "MariaDB stopped (it had been started temporarily)"],

        // ── pgAdmin4 ────────────────────────────────────────────────────────
        "log.svc.pgadmin4Installing":
            ["tr": "pgAdmin4 kuruluyor...",
             "en": "Installing pgAdmin4…"],
        "log.svc.pgadmin4Installed":
            ["tr": "pgAdmin4 kuruldu",
             "en": "pgAdmin4 installed"],
        // %@ = hata açıklaması
        "log.svc.pgadmin4InstallFailed":
            ["tr": "pgAdmin4 kurulamadı: %@",
             "en": "Could not install pgAdmin4: %@"],
        "log.svc.pgadmin4ServiceStarting":
            ["tr": "pgAdmin4 servisi başlatılıyor...",
             "en": "Starting the pgAdmin4 service…"],
        // %@ = port
        "log.svc.pgadmin4ServiceStarted":
            ["tr": "✅ pgAdmin4 servisi başlatıldı (port %@)",
             "en": "✅ pgAdmin4 service started (port %@)"],
        // %@ = brew çıktısı
        "log.svc.pgadmin4ServiceStartFailed":
            ["tr": "⚠️ Servis başlatma: %@",
             "en": "⚠️ Service start: %@"],
        "log.svc.pgadmin4ApacheConfiguring":
            ["tr": "🔧 Apache için pgAdmin4 yapılandırılıyor...",
             "en": "🔧 Configuring pgAdmin4 for Apache…"],
        "log.svc.pgadmin4NginxConfiguring":
            ["tr": "🔧 Nginx için pgAdmin4 yapılandırılıyor...",
             "en": "🔧 Configuring pgAdmin4 for Nginx…"],
        "log.svc.pgadmin4ConfCreated":
            ["tr": "pgadmin4.conf oluşturuldu",
             "en": "pgadmin4.conf created"],
        // %@ = hedef yol
        "log.svc.pgadmin4ConfWriteFailed":
            ["tr": "pgadmin4.conf yazılamadı: %@",
             "en": "Could not write pgadmin4.conf: %@"],
        "log.svc.pgadmin4IncludeExists":
            ["tr": "httpd.conf zaten pgAdmin4 include içeriyor",
             "en": "httpd.conf already contains the pgAdmin4 include"],
        "log.svc.pgadmin4IncludeAdded":
            ["tr": "httpd.conf güncellendi — pgAdmin4 include eklendi",
             "en": "httpd.conf updated — pgAdmin4 include added"],
        "log.svc.pgadmin4NginxBlockAdded":
            ["tr": "nginx.conf güncellendi — pgAdmin4 location bloğu eklendi",
             "en": "nginx.conf updated — pgAdmin4 location block added"],
        "log.svc.pgadmin4Uninstalling":
            ["tr": "pgAdmin4 kaldırılıyor...",
             "en": "Uninstalling pgAdmin4…"],
        "log.svc.pgadmin4Uninstalled":
            ["tr": "pgAdmin4 kaldırıldı (config + veri temizlendi)",
             "en": "pgAdmin4 uninstalled (configuration and data cleaned up)"],
        // %@ = hata açıklaması
        "log.svc.pgadmin4UninstallIncomplete":
            ["tr": "pgAdmin4 kaldırma tamamlanamadı: %@",
             "en": "pgAdmin4 uninstall did not complete: %@"],

        // ── Adminer ─────────────────────────────────────────────────────────
        "log.svc.adminerNeedsPhp":
            ["tr": "Adminer için önce bir PHP sürümü kurun (Servisler sekmesi)",
             "en": "Install a PHP version first for Adminer (Services tab)"],
        "log.svc.adminerInstalling":
            ["tr": "Adminer kuruluyor...",
             "en": "Installing Adminer…"],
        "log.svc.adminerDownloadFailed":
            ["tr": "Adminer indirilemedi",
             "en": "Could not download Adminer"],
        "log.svc.adminerInstalled":
            ["tr": "Adminer kuruldu — localhost/adminer",
             "en": "Adminer installed — localhost/adminer"],
        "log.svc.adminerWebServerConfigFailed":
            ["tr": "Adminer dosyası hazır ama Apache/Nginx yapılandırılamadı — Ayarla düğmesini deneyin",
             "en": "The Adminer file is ready but Apache/Nginx could not be configured — try the Configure button"],
        "log.svc.adminerConfCreated":
            ["tr": "✅ extra/adminer.conf oluşturuldu",
             "en": "✅ extra/adminer.conf created"],
        "log.svc.adminerConfWriteFailed":
            ["tr": "❌ extra/adminer.conf yazılamadı",
             "en": "❌ Could not write extra/adminer.conf"],
        "log.svc.adminerIncludeAdded":
            ["tr": "✅ httpd.conf include eklendi",
             "en": "✅ httpd.conf include added"],
        "log.svc.adminerIncludeFailed":
            ["tr": "❌ httpd.conf güncellenemedi",
             "en": "❌ Could not update httpd.conf"],
        "log.svc.adminerNginxBlockAdded":
            ["tr": "✅ nginx.conf güncellendi — Adminer location bloğu eklendi",
             "en": "✅ nginx.conf updated — Adminer location block added"],
        "log.svc.adminerUninstalling":
            ["tr": "Adminer kaldırılıyor...",
             "en": "Uninstalling Adminer…"],
        "log.svc.adminerUninstalled":
            ["tr": "Adminer kaldırıldı (dosya + Apache + Nginx yapılandırmaları)",
             "en": "Adminer uninstalled (file plus Apache and Nginx configurations)"],

        // ── PostgreSQL ──────────────────────────────────────────────────────
        // %@1 = PG sürümü, %@2 = port
        "log.svc.pgPortConfigured":
            ["tr": "PostgreSQL %@ — port %@ olarak yapılandırıldı",
             "en": "PostgreSQL %@ — configured to use port %@"],
        // %@ = PG sürümü
        "log.svc.pgInitialConfigStarted":
            ["tr": "PostgreSQL %@ başlangıç yapılandırması başlatıldı",
             "en": "PostgreSQL %@ initial configuration started"],
        "log.svc.pgStartFailed":
            ["tr": "PostgreSQL %@ başlatılamadı",
             "en": "Could not start PostgreSQL %@"],
        "log.svc.pgInitialConfigDone":
            ["tr": "PostgreSQL %@ — postgres/boş şifre, test DB oluşturuldu",
             "en": "PostgreSQL %@ — user postgres with an empty password, test database created"],
    ]
}
