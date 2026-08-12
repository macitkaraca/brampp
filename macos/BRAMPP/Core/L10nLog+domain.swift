import Foundation

// ═══════════════════════════════════════════════════════════════════════════
//  KONSOL LOG KATALOGU — log.dom.* (Managers/DomainManager.swift)
// ═══════════════════════════════════════════════════════════════════════════
//  Kurallar: Core/L10nLog.swift dosyasının başındaki yorum bloğu.
//  Yer tutucu SADECE `%@`; TR ve EN metinlerinde yer tutucu SAYISI ve SIRASI
//  aynı olmalıdır (gerekirse İngilizce cümle yeniden kurulur).
//  Emoji/ok işaretleri (↳ ✅ ❌ ⚠️) iki dilde de METNİN İÇİNDE kalır.
// ═══════════════════════════════════════════════════════════════════════════

extension L10n {

    /// Domain işlemlerine ait konsol satırları — `L10n.logEntry(for:)` bunu da tarar.
    static let logCatalog_domain: [String: [String: String]] = [

        // ── Bağımlılık servisleri ───────────────────────────────────────────
        "log.dom.shareStoppedWithDomain":
            ["tr": "⚠️ %@ paylaşımı kapatıldı — alan adı değiştiği için herkese açık adres artık bu siteye gitmiyordu",
             "en": "⚠️ Sharing for %@ was stopped — with the domain gone, the public address no longer pointed at this site"],
        // %@ = yol
        "log.diag.repairBackupFailed":
            ["tr": "❌ Yedek alınamadı, dosyaya DOKUNULMADI: %@",
             "en": "❌ Could not write the backup, the file was left alone: %@"],
        "log.diag.repairWriteFailed":
            ["tr": "❌ Yapılandırma yazılamadı: %@", "en": "❌ Could not write the configuration: %@"],
        "log.diag.repairRolledBack":
            ["tr": "❌ Onarım sonrası configtest geçmedi — dosyalar YEDEKTEN geri alındı, Apache'ye dokunulmadı",
             "en": "❌ configtest failed after the repair — the files were restored from backup and Apache was left alone"],
        // %@ = onarılan dosya sayısı
        "log.diag.repaired":
            ["tr": "✅ %@ yapılandırma dosyasındaki Alias sırası düzeltildi, Apache yeniden başlatıldı (.brampp.bak yedeği duruyor)",
             "en": "✅ Alias order fixed in %@ configuration file(s) and Apache restarted (the .brampp.bak backup is kept)"],
        "log.dom.companionsKeptConfigWasBroken":
            ["tr": "⚠️ Apache yapılandırması bu yazımdan ÖNCE de geçersizdi — companion vhost'lar bırakıldı, silmek sorunu çözmezdi",
             "en": "⚠️ The Apache configuration was already invalid before this write — the companion vhosts were kept, removing them would not have fixed it"],
        "log.diag.clean":
            ["tr": "Teşhis tamamlandı — sorun bulunamadı",
             "en": "Diagnostics finished — nothing wrong found"],
        "log.diag.issues":
            ["tr": "Teşhis tamamlandı — %@ bulgu var",
             "en": "Diagnostics finished — %@ findings"],
        "log.tunnel.dnsSlow":
            ["tr": "⚠️ %@ adresi oluştu ama Mac'inizin DNS'i onu henüz görmüyor. Tarayıcı ERR_NAME_NOT_RESOLVED verebilir. Bazı sağlayıcılar (ör. 8.8.8.8) yeni trycloudflare adlarını geç alıyor; 1.1.1.1 kullanmak bunu çözer.",
             "en": "⚠️ %@ exists but your Mac's DNS has not picked it up yet. The browser may show ERR_NAME_NOT_RESOLVED. Some resolvers (8.8.8.8 among them) are slow with new trycloudflare names; 1.1.1.1 resolves them immediately."],
        "log.tunnel.portRange":
            ["tr": "❌ %@ geçerli bir port değil (1–65535)",
             "en": "❌ %@ is not a valid port (1–65535)"],
        "log.tunnel.portReserved":
            ["tr": "❌ Port %@ paylaşılamaz — %@ servisi. Veritabanı ve önbellek servisleri internete açılmaz",
             "en": "❌ port %@ cannot be shared — it is %@. Database and cache services are not put on the internet"],
        "log.tunnel.portClosed":
            ["tr": "❌ Port %@ dinlenmiyor — paylaşılan adres boş dönerdi",
             "en": "❌ nothing is listening on port %@ — the shared address would return nothing"],
        "log.tunnel.blockDisabled":
            ["tr": "❌ %@ paylaşılamaz — alan adı devre dışı, vhost'u yok",
             "en": "❌ cannot share %@ — the domain is disabled and has no vhost"],
        "log.tunnel.blockWebServer":
            ["tr": "❌ %@ paylaşılamaz — %@ çalışmıyor, siteyi sunacak bir sunucu yok",
             "en": "❌ cannot share %@ — %@ is not running, so nothing serves the site"],
        "log.tunnel.blockApp":
            ["tr": "❌ %@ paylaşılamaz — arka plan uygulaması çalışmıyor, ziyaretçi 502 görür",
             "en": "❌ cannot share %@ — its app is not running, so visitors would get a 502"],
        "log.tunnel.notInstalled":
            ["tr": "cloudflared kurulu değil — paylaşım için: brew install cloudflared",
             "en": "cloudflared is not installed — for sharing: brew install cloudflared"],
        "log.tunnel.starting":
            ["tr": "▶︎ %@ için Cloudflare tüneli açılıyor",
             "en": "▶︎ opening a Cloudflare tunnel for %@"],
        "log.tunnel.already":
            ["tr": "%@ zaten paylaşılıyor",
             "en": "%@ is already shared"],
        "log.tunnel.startFailed":
            ["tr": "❌ %@ için tünel başlatılamadı",
             "en": "❌ could not start the tunnel for %@"],
        "log.tunnel.urlTimeout":
            ["tr": "❌ %@ için herkese açık adres alınamadı — tünel kapatıldı",
             "en": "❌ no public address arrived for %@ — the tunnel was closed"],
        "log.tunnel.live":
            ["tr": "🌍 %@ ARTIK HERKESE AÇIK: %@",
             "en": "🌍 %@ IS NOW PUBLIC: %@"],
        "log.tunnel.stopped":
            ["tr": "%@ paylaşımı durduruldu",
             "en": "sharing stopped for %@"],
        // %@1 = alan adı / port anahtarı, %@2 = cloudflared PID'i
        "log.tunnel.stopStuck":
            ["tr": "❌ %@ paylaşımı DURDURULAMADI — cloudflared (pid %@) SIGTERM'i de SIGKILL'i de atlattı. Adres HÂLÂ herkese açık; süreci elle kapatın: kill -9 %@",
             "en": "❌ could NOT stop sharing for %@ — cloudflared (pid %@) survived both SIGTERM and SIGKILL. The address is STILL public; kill the process by hand: kill -9 %@"],
        "log.tunnel.startInProgress":
            ["tr": "%@ için bir paylaşım zaten başlatılıyor — ikinci tünel açılmadı",
             "en": "a share is already starting for %@ — a second tunnel was not opened"],
        "log.tunnel.died":
            ["tr": "⚠️ %@ paylaşımı beklenmedik şekilde sona erdi — cloudflared süreci yok. Adres artık çalışmıyor; paylaşmak için yeniden başlatın.",
             "en": "⚠️ sharing for %@ ended unexpectedly — the cloudflared process is gone. The address no longer works; start the share again to publish it."],
        "log.dom.depReady":
            ["tr": "↳ bağımlılık hazır: %@",
             "en": "↳ dependency ready: %@"],
        "log.dom.depStartFailed":
            ["tr": "⚠️ Bağımlılık başlatılamadı: %@ — uygulama yine de deneniyor",
             "en": "⚠️ Could not start dependency: %@ — starting the app anyway"],

        // ── Yükleme / kaydetme ──────────────────────────────────────────────
        // %@1 = kayıt sayısı, %@2 = yedek yolu
        "log.dom.corruptRecordsSkipped":
            ["tr": "%@ bozuk domain kaydı atlandı — yedek: %@",
             "en": "Skipped %@ corrupted domain record(s) — backup: %@"],
        // %@1 = ad sayısı, %@2 = yedek yolu
        "log.dom.invalidNamesSkipped":
            ["tr": "%@ geçersiz domain adı güvenlik nedeniyle atlandı — yedek: %@",
             "en": "Skipped %@ invalid domain name(s) for security reasons — backup: %@"],
        "log.dom.loaded":
            ["tr": "Domainler yüklendi (%@ adet)",
             "en": "Domains loaded (%@ total)"],
        "log.dom.loadFailed":
            ["tr": "Domainler yüklenemedi: %@",
             "en": "Could not load domains: %@"],
        "log.dom.corruptJsonBackedUp":
            ["tr": "Bozuk domains.json yedeklendi: %@ — düzeltip geri yükleyebilirsiniz",
             "en": "Corrupted domains.json backed up: %@ — you can fix it and put it back"],
        "log.dom.pythonPortsMigrated":
            ["tr": "Eski Python domainleri {PORT} şablonuna taşındı (port değişiminde 502 önlemi)",
             "en": "Legacy Python domains migrated to the {PORT} placeholder (prevents 502 after a port change)"],
        "log.dom.saveFailed":
            ["tr": "Domainler kaydedilemedi: %@",
             "en": "Could not save domains: %@"],

        // ── Dış değişiklik izleyici ─────────────────────────────────────────
        "log.dom.watcherStartFailed":
            ["tr": "Dizin izleyici başlatılamadı: %@",
             "en": "Could not start the directory watcher: %@"],
        "log.dom.externallyChanged":
            ["tr": "domains.json dışarıdan değişti — alan adları yeniden yüklendi",
             "en": "domains.json was changed outside BRAMPP — domains reloaded"],

        // ── Doğrulama ───────────────────────────────────────────────────────
        "log.dom.invalidName":
            ["tr": "Geçersiz domain adı: '%@' — yalnızca harf, rakam, nokta ve tire kullanın",
             "en": "Invalid domain name: '%@' — use only letters, digits, dots and hyphens"],
        "log.dom.duplicateName":
            ["tr": "'%@' zaten mevcut — aynı adla ikinci domain eklenemez",
             "en": "'%@' already exists — a second domain with the same name cannot be added"],
        "log.dom.invalidDocRoot":
            ["tr": "Geçersiz site klasörü: '%@' — tırnak, $, ;, { } ve satır sonu içeremez",
             "en": "Invalid site folder: '%@' — it cannot contain quotes, $, ;, { } or line breaks"],
        "log.dom.invalidDocRootUpdate":
            ["tr": "Geçersiz site klasörü: '%@' — güncelleme uygulanmadı",
             "en": "Invalid site folder: '%@' — the update was not applied"],

        // ── Port ────────────────────────────────────────────────────────────
        // %@1 = istenen port, %@2 = domain adı
        "log.dom.noFreePort":
            ["tr": "Port %@ kullanımda ve platform aralığında boş port yok — '%@' oluşturulmadı",
             "en": "Port %@ is in use and no free port is left in the platform range — '%@' was not created"],
        // %@1 = istenen port, %@2 = domain adı, %@3 = atanan port
        "log.dom.portReassigned":
            ["tr": "Port %@ başka bir domain tarafından kullanılıyor — '%@' için %@ atandı",
             "en": "Port %@ is used by another domain — '%@' was given port %@"],

        // ── Oluşturma ───────────────────────────────────────────────────────
        "log.dom.creating":
            ["tr": "'%@' oluşturuluyor...",
             "en": "Creating '%@'…"],
        "log.dom.sslFailedHttpOnly":
            ["tr": "SSL oluşturulamadı — domain SSL'siz (yalnızca HTTP) oluşturuluyor",
             "en": "Could not create SSL — the domain is being created without SSL (HTTP only)"],
        "log.dom.created":
            ["tr": "'%@' başarıyla oluşturuldu!",
             "en": "'%@' created successfully!"],
        "log.dom.url":
            ["tr": "URL: %@",
             "en": "URL: %@"],
        "log.dom.createdNoHosts":
            ["tr": "'%@' oluşturuldu ancak /etc/hosts'a eklenemedi (yönetici izni verilmedi)",
             "en": "'%@' was created but could not be added to /etc/hosts (administrator permission was denied)"],
        "log.dom.hostsManualHint":
            ["tr": "Elle eklemek için Terminal'de: echo '127.0.0.1  %@' | sudo tee -a /etc/hosts",
             "en": "To add it manually, run in Terminal: echo '127.0.0.1  %@' | sudo tee -a /etc/hosts"],

        // ── Silme ───────────────────────────────────────────────────────────
        "log.dom.deleting":
            ["tr": "'%@' siliniyor...",
             "en": "Deleting '%@'…"],
        "log.dom.deleted":
            ["tr": "'%@' silindi",
             "en": "'%@' deleted"],

        // ── Güncelleme ──────────────────────────────────────────────────────
        "log.dom.savedWhileDisabled":
            ["tr": "'%@' ayarları kaydedildi — domain devre dışı, etkinleştirildiğinde uygulanacak",
             "en": "Settings for '%@' were saved — the domain is disabled, they will apply once it is enabled"],
        "log.dom.sslFailedUpdateHttp":
            ["tr": "'%@' için SSL üretilemedi — HTTP olarak güncelleniyor",
             "en": "Could not generate SSL for '%@' — updating it as HTTP only"],
        "log.dom.updateRolledBack":
            ["tr": "'%@' güncellenemedi — yapılandırma doğrulanamadı, önceki ayarlar geri yüklendi",
             "en": "Could not update '%@' — the configuration failed validation, the previous settings were restored"],
        "log.dom.updated":
            ["tr": "'%@' güncellendi",
             "en": "'%@' updated"],
        "log.dom.restartingAfterUpdate":
            ["tr": "'%@' ayarları değişti — uygulama yeniden başlatılıyor...",
             "en": "Settings for '%@' changed — restarting the app…"],

        // ── Etkinleştir / devre dışı bırak ──────────────────────────────────
        "log.dom.enabling":
            ["tr": "'%@' etkinleştiriliyor...",
             "en": "Enabling '%@'…"],
        "log.dom.sslFailedEnableHttp":
            ["tr": "SSL sertifikası üretilemedi — domain yalnızca HTTP olarak etkinleştiriliyor",
             "en": "Could not generate the SSL certificate — enabling the domain as HTTP only"],
        "log.dom.enableFailed":
            ["tr": "'%@' etkinleştirilemedi — vhost yapılandırması yazılamadı",
             "en": "Could not enable '%@' — the vhost configuration could not be written"],
        "log.dom.enabled":
            ["tr": "'%@' etkinleştirildi",
             "en": "'%@' enabled"],
        "log.dom.disabling":
            ["tr": "'%@' devre dışı bırakılıyor...",
             "en": "Disabling '%@'…"],
        "log.dom.disabled":
            ["tr": "'%@' devre dışı — vhost ve hosts girişi kaldırıldı (kayıt korundu)",
             "en": "'%@' disabled — the vhost and the hosts entry were removed (the record is kept)"],

        // ── Yeniden adlandırma ──────────────────────────────────────────────
        // %@1 = eski ad, %@2 = yeni ad
        "log.dom.renaming":
            ["tr": "'%@' → '%@' olarak yeniden adlandırılıyor...",
             "en": "Renaming '%@' → '%@'…"],
        "log.dom.renameAborted":
            ["tr": "Yeniden adlandırma iptal: %@",
             "en": "Rename aborted: %@"],
        "log.dom.siteFolderMoved":
            ["tr": "Site klasörü taşındı → %@",
             "en": "Site folder moved → %@"],
        "log.dom.sslFailedRename":
            ["tr": "Yeni ad için SSL üretilemedi — domain SSL'siz devam ediyor",
             "en": "Could not generate SSL for the new name — the domain continues without SSL"],
        // %@1 = eski ad, %@2 = yeni ad
        "log.dom.renamed":
            ["tr": "'%@' → '%@' olarak yeniden adlandırıldı",
             "en": "Renamed '%@' → '%@'"],
        "log.dom.renamedNoHosts":
            ["tr": "Yeniden adlandırıldı ancak /etc/hosts güncellenemedi — elle ekleyin: 127.0.0.1  %@",
             "en": "Renamed, but /etc/hosts could not be updated — add it manually: 127.0.0.1  %@"],

        // ── Site klasörü ────────────────────────────────────────────────────
        "log.dom.siteFolderPreparing":
            ["tr": "Site klasörü hazırlanıyor...",
             "en": "Preparing the site folder…"],
        "log.dom.siteFolderCreateFailed":
            ["tr": "Site klasörü oluşturulamadı: %@",
             "en": "Could not create the site folder: %@"],
        // %@1 = öğe sayısı, %@2 = klasör yolu
        "log.dom.siteFolderNotEmpty":
            ["tr": "Mevcut klasör kullanılıyor (%@ öğe) — örnek dosya yazılmadı: %@",
             "en": "Using the existing folder (%@ item(s)) — no sample files were written: %@"],
        "log.dom.dotnetNewHint":
            ["tr": ".NET projesi için 'dotnet new webapi' çalıştırın",
             "en": "Run 'dotnet new webapi' for the .NET project"],
        "log.dom.siteFolderCreated":
            ["tr": "Site klasörü oluşturuldu: %@",
             "en": "Site folder created: %@"],
        "log.dom.sampleFileFailed":
            ["tr": "Site dosyası oluşturulamadı: %@",
             "en": "Could not create the site file: %@"],

        // ── Config dosyaları ────────────────────────────────────────────────
        "log.dom.startScriptCreated":
            ["tr": "start.sh oluşturuldu",
             "en": "start.sh created"],
        "log.dom.configJsonCreated":
            ["tr": ".brampp.json oluşturuldu",
             "en": ".brampp.json created"],

        // ── SSL / mkcert ────────────────────────────────────────────────────
        "log.dom.mkcertCaInstalling":
            ["tr": "mkcert CA kurulu değil, kuruluyor...",
             "en": "The mkcert CA is not installed, installing it…"],
        "log.dom.mkcertCaFailed":
            ["tr": "CA kurulamadı",
             "en": "Could not install the CA"],

        // ── VHost ───────────────────────────────────────────────────────────
        "log.dom.defaultVhostCreated":
            ["tr": "Varsayılan localhost vhost oluşturuldu: %@",
             "en": "Default localhost vhost created: %@"],
        "log.dom.defaultVhostWriteFailed":
            ["tr": "Varsayılan localhost vhost yazılamadı: %@",
             "en": "Could not write the default localhost vhost: %@"],
        "log.dom.vhostCreating":
            ["tr": "%@ config oluşturuluyor...",
             "en": "Creating the %@ config…"],
        "log.dom.vhostWriteFailed":
            ["tr": "%@ config yazılamadı",
             "en": "Could not write the %@ config"],
        // %@1 = domain adı, %@2 = web sunucusu adı
        "log.dom.vhostSyntaxBrokeRestored":
            ["tr": "%@ güncellemesi %@ sözdizimini bozdu — ÖNCEKİ config geri yüklendi",
             "en": "The update to %@ broke the %@ syntax — the PREVIOUS config was restored"],
        // %@1 = domain adı, %@2 = web sunucusu adı
        "log.dom.vhostSyntaxBrokeRemoved":
            ["tr": "%@ config'i %@ sözdizimini bozdu — geri alındı, domain oluşturulmadı",
             "en": "The config for %@ broke the %@ syntax — it was reverted and the domain was not created"],
        "log.dom.vhostAlreadyInvalid":
            ["tr": "%@ config'i bu yazımdan ÖNCE de geçersizdi — yeni config doğrulanamadı",
             "en": "The %@ config was already invalid BEFORE this write — the new config could not be verified"],
        // %@1 = web sunucusu adı, %@2 = config yolu
        "log.dom.vhostCreated":
            ["tr": "%@ config oluşturuldu: %@",
             "en": "%@ config created: %@"],

        // ── Apache companion vhost (Nginx domainleri için bare URL) ─────────
        "log.dom.companionsCreated":
            ["tr": "Mevcut Nginx domainleri için Apache companion vhost'ları oluşturuldu (bare URL)",
             "en": "Apache companion vhosts created for existing Nginx domains (bare URL support)"],
        "log.dom.companionsRolledBack":
            ["tr": "Companion vhost'lar configtest'i bozdu — %@ dosya geri alındı",
             "en": "The companion vhosts broke configtest — %@ file(s) reverted"],
        "log.dom.companionWriteFailed":
            ["tr": "Apache companion vhost yazılamadı: %@",
             "en": "Could not write the Apache companion vhost: %@"],
        "log.dom.companionUpdateReverted":
            ["tr": "Apache companion güncellemesi sözdizimi bozdu — önceki içerik geri yüklendi",
             "en": "The Apache companion update broke the syntax — the previous content was restored"],
        "log.dom.companionReverted":
            ["tr": "Apache companion vhost sözdizimi bozdu — geri alındı (bare URL için :8443 kullanın)",
             "en": "The Apache companion vhost broke the syntax — it was reverted (use :8443 for the bare URL)"],
        "log.dom.companionCreated":
            ["tr": "Apache companion vhost oluşturuldu — %@ bare URL (80/443) üzerinden de erişilebilir",
             "en": "Apache companion vhost created — %@ is now reachable over the bare URL (80/443) too"],

        // ── Web sunucusu yeniden yükleme ────────────────────────────────────
        "log.dom.apacheNotRunning":
            ["tr": "Apache çalışmıyor — config sonraki başlatmada uygulanacak",
             "en": "Apache is not running — the config will be applied on the next start"],
        "log.dom.apacheReloading":
            ["tr": "Apache config yeniden yükleniyor...",
             "en": "Reloading the Apache config…"],
        "log.dom.apacheConfigError":
            ["tr": "Apache config hatası: %@",
             "en": "Apache config error: %@"],
        "log.dom.apacheReloaded":
            ["tr": "Apache config yeniden yüklendi",
             "en": "Apache config reloaded"],
        "log.dom.apacheReloadFailed":
            ["tr": "Apache reload başarısız: %@",
             "en": "Apache reload failed: %@"],
        "log.dom.nginxNotRunning":
            ["tr": "Nginx çalışmıyor — config sonraki başlatmada uygulanacak",
             "en": "Nginx is not running — the config will be applied on the next start"],
        "log.dom.nginxReloading":
            ["tr": "Nginx config yeniden yükleniyor...",
             "en": "Reloading the Nginx config…"],
        "log.dom.nginxReloaded":
            ["tr": "Nginx config yeniden yüklendi",
             "en": "Nginx config reloaded"],
        "log.dom.nginxReloadFailed":
            ["tr": "Nginx reload başarısız: %@",
             "en": "Nginx reload failed: %@"],

        // ── /etc/hosts ──────────────────────────────────────────────────────
        "log.dom.hostsAdding":
            ["tr": "/etc/hosts'a ekleniyor...",
             "en": "Adding to /etc/hosts…"],
        "log.dom.hostsRemoving":
            ["tr": "/etc/hosts'tan kaldırılıyor...",
             "en": "Removing from /etc/hosts…"],
        "log.dom.hostsAllPresent":
            ["tr": "Tüm domainlerin /etc/hosts girişi mevcut — onarım gerekmiyor",
             "en": "Every domain already has an /etc/hosts entry — no repair needed"],
        // %@1 = eksik giriş sayısı, %@2 = domain listesi
        "log.dom.hostsRepairing":
            ["tr": "%@ eksik hosts girişi ekleniyor: %@",
             "en": "Adding %@ missing hosts entry(ies): %@"],
        "log.dom.hostsRetry":
            ["tr": "/etc/hosts: izin iptal edildi — yeniden deneniyor (%@/2)...",
             "en": "/etc/hosts: permission was cancelled — retrying (%@/2)…"],
        "log.dom.hostsCancelled":
            ["tr": "/etc/hosts güncellenmedi — yönetici izni 3 kez iptal edildi",
             "en": "/etc/hosts was not updated — administrator permission was cancelled 3 times"],
        "log.dom.hostsUpdated":
            ["tr": "/etc/hosts güncellendi",
             "en": "/etc/hosts updated"],
        "log.dom.hostsUpdateFailed":
            ["tr": "/etc/hosts güncellenemedi",
             "en": "Could not update /etc/hosts"],
        "log.dom.hostsRepaired":
            ["tr": "/etc/hosts onarıldı (%@ giriş eklendi)",
             "en": "/etc/hosts repaired (%@ entry(ies) added)"],
        "log.dom.hostsRepairFailed":
            ["tr": "/etc/hosts onarılamadı",
             "en": "Could not repair /etc/hosts"],

        // ── Eylemler / sağlık testi ─────────────────────────────────────────
        "log.dom.urlCopied":
            ["tr": "URL kopyalandı: %@",
             "en": "URL copied: %@"],
        // %@1 = domain adı, %@2 = url
        "log.dom.healthCheckStart":
            ["tr": "%@ bağlantı testi: %@",
             "en": "Connection test for %@: %@"],
        // %@1 = domain adı, %@2 = HTTP durum kodu
        "log.dom.healthOk":
            ["tr": "✅ %@ yanıt veriyor (HTTP %@)",
             "en": "✅ %@ is responding (HTTP %@)"],
        "log.dom.healthUnreachable":
            ["tr": "❌ %@ erişilemiyor — web sunucusu çalışıyor mu? /etc/hosts kaydı var mı?",
             "en": "❌ %@ is unreachable — is the web server running? is there an /etc/hosts entry?"],
        // %@1 = domain adı, %@2 = HTTP durum kodu
        "log.dom.healthBackendDown":
            ["tr": "⚠️ %@ HTTP %@ — backend uygulaması çalışmıyor",
             "en": "⚠️ %@ returned HTTP %@ — the backend app is not running"],
        // %@1 = domain adı, %@2 = HTTP durum kodu
        "log.dom.healthUnexpected":
            ["tr": "⚠️ %@ HTTP %@ döndürdü",
             "en": "⚠️ %@ returned HTTP %@"],
        "log.dom.configNotFound":
            ["tr": "Config bulunamadı",
             "en": "Config not found"],
        "log.dom.startScriptNotFound":
            ["tr": "start.sh bulunamadı: %@",
             "en": "start.sh not found: %@"],
        "log.dom.errorLogNotFound":
            ["tr": "Error log bulunamadı",
             "en": "Error log not found"],
        "log.dom.accessLogNotFound":
            ["tr": "Access log bulunamadı",
             "en": "Access log not found"],

        // ── Build ───────────────────────────────────────────────────────────
        "log.dom.buildStarting":
            ["tr": "Build başlatılıyor: %@",
             "en": "Starting build: %@"],
        "log.dom.buildDone":
            ["tr": "Build tamamlandı: %@",
             "en": "Build finished: %@"],
        "log.dom.buildFailed":
            ["tr": "Build başarısız: %@",
             "en": "Build failed: %@"],

        // ── Node.js bağımlılıkları ──────────────────────────────────────────
        "log.dom.npmInstalling":
            ["tr": "node_modules yok — bağımlılıklar kuruluyor (npm install)...",
             "en": "node_modules is missing — installing dependencies (npm install)…"],
        "log.dom.npmInstalled":
            ["tr": "Bağımlılıklar kuruldu (node_modules hazır)",
             "en": "Dependencies installed (node_modules is ready)"],
        "log.dom.npmInstallFailed":
            ["tr": "npm install başarısız (başlatma yine denenecek): %@",
             "en": "npm install failed (the app will still be started): %@"],

        // ── Uygulama süreç yönetimi (Node.js / Python / .NET) ───────────────
        "log.dom.appStarting":
            ["tr": "%@ başlatılıyor...",
             "en": "Starting %@…"],
        "log.dom.appStarted":
            ["tr": "%@ başlatıldı",
             "en": "%@ started"],
        "log.dom.appStartFailed":
            ["tr": "%@ başlatılamadı",
             "en": "Could not start %@"],
        "log.dom.appStartFailedEnv":
            ["tr": "%@ başlatılamadı — ortam hazırlanamadı",
             "en": "Could not start %@ — the environment could not be prepared"],
        "log.dom.appStartFailedProject":
            ["tr": "%@ başlatılamadı — proje hazırlanamadı",
             "en": "Could not start %@ — the project could not be prepared"],
        "log.dom.appStopping":
            ["tr": "%@ durduruluyor...",
             "en": "Stopping %@…"],
        "log.dom.appStopped":
            ["tr": "%@ durduruldu",
             "en": "%@ stopped"],
        "log.dom.venvMissing":
            ["tr": "venv bulunamadı — otomatik kurulum başlıyor (app.log takip edin)",
             "en": "No venv found — automatic setup is starting (follow app.log)"],

        // ── .NET projesi ────────────────────────────────────────────────────
        "log.dom.dotnetSdkMissing":
            ["tr": ".NET SDK kurulu değil — Servisler sekmesinden bir .NET sürümü kurun, sonra tekrar deneyin",
             "en": "The .NET SDK is not installed — install a .NET version from the Services tab, then try again"],
        // %@1 = istenen sürüm, %@2 = kullanılacak framework moniker
        "log.dom.dotnetVersionFallback":
            ["tr": "İstenen .NET %@ kurulu değil — kurulu %@ kullanılıyor",
             "en": "The requested .NET %@ is not installed — using the installed %@ instead"],
        "log.dom.dotnetProjectExists":
            ["tr": ".NET projesi mevcut (%@)",
             "en": ".NET project found (%@)"],
        "log.dom.csprojWrongFramework":
            ["tr": ".csproj %@ hedefli değil — güncelleniyor...",
             "en": "The .csproj does not target %@ — updating it…"],
        "log.dom.csprojUpdated":
            ["tr": ".csproj güncellendi → %@",
             "en": ".csproj updated → %@"],
        "log.dom.csprojUpdateFailed":
            ["tr": ".csproj güncellenemedi",
             "en": "Could not update the .csproj"],
        "log.dom.dotnetProjectCreating":
            ["tr": ".NET projesi bulunamadı — dotnet new webapi (%@) çalıştırılıyor...",
             "en": "No .NET project found — running dotnet new webapi (%@)…"],
        // %@1 = proje adı, %@2 = framework moniker
        "log.dom.dotnetProjectCreated":
            ["tr": ".NET projesi oluşturuldu: %@ [%@]",
             "en": ".NET project created: %@ [%@]"],
        "log.dom.dotnetProjectCreateFailed":
            ["tr": ".NET projesi oluşturulamadı: %@",
             "en": "Could not create the .NET project: %@"],
        "log.dom.dotnetBuilding":
            ["tr": ".NET projesi derleniyor (bir kez)...",
             "en": "Building the .NET project (one time)…"],
        "log.dom.dotnetBuildOk":
            ["tr": ".NET derleme başarılı",
             "en": ".NET build succeeded"],
        "log.dom.dotnetBuildWarned":
            ["tr": ".NET derleme uyarı/hata verdi (başlatma yine denenecek):\n%@",
             "en": ".NET build reported warnings/errors (the app will still be started):\n%@"],
        "log.dom.programCsPatched":
            ["tr": "Program.cs yapılandırıldı (statik info sayfası + UTF-8 + reverse-proxy)",
             "en": "Program.cs configured (static info page + UTF-8 + reverse proxy)"],
        "log.dom.dotnetInfoPageCreated":
            ["tr": "wwwroot/index.html info sayfası oluşturuldu (Türkçe, UTF-8)",
             "en": "wwwroot/index.html info page created (Turkish, UTF-8)"],
    ]
}
