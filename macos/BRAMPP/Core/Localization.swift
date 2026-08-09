import SwiftUI
import Combine

/// Uygulama dili. Türkçe ve İngilizce desteklenir; Türkçe DIŞINDAKİ tüm sistem
/// dilleri İngilizce'ye düşer (kullanıcının isteği: TR değilse fallback EN).
enum AppLanguage: String, CaseIterable, Identifiable {
    case system   // sistem diline göre otomatik (TR ise Türkçe, değilse İngilizce)
    case tr
    case en

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "Sistem / System"
        case .tr:     return "Türkçe"
        case .en:     return "English"
        }
    }

    /// Bu seçim için efektif dil kodu ("tr" veya "en").
    var effectiveCode: String {
        switch self {
        case .tr: return "tr"
        case .en: return "en"
        case .system:
            // Sistem tercih dilinin ilk kodu "tr" ise Türkçe, aksi halde İngilizce (fallback)
            let pref = Locale.preferredLanguages.first ?? "en"
            return pref.lowercased().hasPrefix("tr") ? "tr" : "en"
        }
    }
}

/// Çalışma zamanında dil değiştirilebilen basit yerelleştirici.
/// Kullanım:  @EnvironmentObject var loc: Localizer   →   loc.t("key")
/// ObservableObject olduğundan dil değişince tüm gözlemci view'lar yeniden çizilir.
@MainActor
final class Localizer: ObservableObject {
    static let shared = Localizer()

    @Published private(set) var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.key) }
    }

    private static let key = "appLanguage"

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? AppLanguage.system.rawValue
        self.language = AppLanguage(rawValue: raw) ?? .system
    }

    func setLanguage(_ lang: AppLanguage) { language = lang }

    /// Efektif dil kodu ("tr" / "en").
    var code: String { language.effectiveCode }

    /// Anahtarı geçerli dile çevirir. Anahtar/dil bulunamazsa: EN → TR → anahtarın kendisi.
    func t(_ key: String) -> String {
        guard let entry = L10n.catalog[key] else {
            #if DEBUG
            return "⟨\(key)⟩"   // eksik anahtar geliştirmede görünür olsun
            #else
            return key
            #endif
        }
        return entry[code] ?? entry["en"] ?? entry["tr"] ?? key
    }
}

/// String katalogu: anahtar → [dilKodu: metin].
/// Yeni metin eklemek için buraya bir satır ekleyip view'da `loc.t("anahtar")` çağır.
/// NOT: Uygulamanın tamamı henüz bu sisteme taşınMADI — sekme başlıkları, Yardım ve
/// dil ayarı çevrilidir; geri kalan yüzeyler kademeli olarak taşınacaktır.
enum L10n {
    static let catalog: [String: [String: String]] = [

        // ── İkinci çeviri turu: fonksiyon-argümanı / durum / uyarı metinleri ──
        "common.select":  ["tr": "Seç", "en": "Choose"],
        "common.edit":    ["tr": "Düzenle", "en": "Edit"],

        // DomainsTabView (dom.running / dom.notRunning / dom.bodyNginx zaten var — yeniden kullanılır)
        "dom.runCommand": ["tr": "Çalıştırma Komutu", "en": "Run Command"],
        "dom.portRange":  ["tr": "Port 1–65535 aralığında olmalı", "en": "Port must be between 1 and 65535"],
        "dom.portInUse":  ["tr": "Bu portu başka bir domain kullanıyor", "en": "This port is already used by another domain"],
        "dom.docRootInvalid": ["tr": "Klasör yolu tırnak, $, ;, { } veya satır sonu içeremez", "en": "Folder path cannot contain quotes, $, ;, { } or line breaks"],
        "dom.portProxyHint": ["tr": "%@ bu porta reverse proxy yapar", "en": "%@ reverse-proxies to this port"],
        "dom.grpcOn":     ["tr": "grpc_pass kullanılır — HTTP/2 otomatik etkinleştirilir, WebSocket devre dışı bırakılır", "en": "grpc_pass is used — HTTP/2 is auto-enabled, WebSocket is disabled"],
        "dom.portsNginxHint": ["tr": "HTTP :8080  ·  HTTPS :8443  —  Node.js ve .NET için önerilir", "en": "HTTP :8080  ·  HTTPS :8443  —  recommended for Node.js and .NET"],
        "dom.versionNotInstalled": ["tr": "%@  — kurulu değil", "en": "%@  — not installed"],
        "set.persistLog":     ["tr": "Konsolu diske kaydet", "en": "Save the console to disk"],
        "set.persistLogDesc": ["tr": "Satırlar günlük dosyalara yazılır, 7 gün sonra silinir — geçmişe dönük hata ayıklama ve MCP log okuması için", "en": "Lines are written to daily files and deleted after 7 days — for looking back and for MCP log reads"],
        "dom.share":          ["tr": "Paylaş", "en": "Share"],
        "dom.share.badgeLive":["tr": "YAYINDA", "en": "LIVE"],
        "dom.share.copied":   ["tr": "Kopyalandı", "en": "Copied"],
        "dom.share.live":     ["tr": "Yayında — karekodu görmek veya durdurmak için tıklayın", "en": "Live — click to see the QR code or stop it"],
        "dom.share.off":      ["tr": "Yayın kapalı — paylaşmak için tıklayın", "en": "Not shared — click to share"],
        "dom.share.stop":     ["tr": "Paylaşımı durdur", "en": "Stop sharing"],
        "dom.share.title":    ["tr": "Siteyi internete aç", "en": "Put the site on the internet"],
        "dom.share.warn":     ["tr": "Bu adres HERKESE AÇIKTIR. Adresi bilen herkes sitenize girebilir — sitede kimlik doğrulaması yoksa veriler de dâhil. Cloudflare hesabı gerekmez; adres geçicidir ve paylaşımı durdurunca ölür.", "en": "This address is PUBLIC. Anyone who has it can reach your site — including its data, if the site has no authentication. No Cloudflare account is needed; the address is temporary and dies when you stop sharing."],
        "dom.share.target":   ["tr": "Yerel hedef", "en": "Local target"],
        "dom.share.public":   ["tr": "Herkese açık adres", "en": "Public address"],
        "dom.share.starting": ["tr": "Tünel açılıyor…", "en": "Opening the tunnel…"],
        "dom.share.startingHint":["tr": "Cloudflare adres atıyor — genellikle 10 saniyeden kısa sürer.", "en": "Cloudflare is assigning an address — usually under 10 seconds."],
        "dom.share.start":    ["tr": "Paylaşımı başlat", "en": "Start sharing"],
        "dom.share.copy":     ["tr": "Adresi kopyala", "en": "Copy the address"],
        "dom.share.qr":       ["tr": "Telefonla açmak için kodu okutun", "en": "Scan the code to open it on a phone"],
        "cat.sharing":        ["tr": "Paylaşım", "en": "Sharing"],
        "svc.cf.desc":        ["tr": "Yerel siteyi geçici, herkese açık bir adrese çıkarır. Sürekli çalışmaz — yalnızca bir paylaşım açıkken yaşar.", "en": "Puts a local site on a temporary public address. It does not run continuously — it lives only while a share is open."],
        "svc.cf.activeOne":   ["tr": "1 yayın açık: %@", "en": "1 share open: %@"],
        "svc.cf.activeMany":  ["tr": "%d yayın açık: %@", "en": "%d shares open: %@"],
        "svc.cf.idle":        ["tr": "Açık yayın yok", "en": "No shares open"],
        "dom.share.needsInstall": ["tr": "cloudflared kurulu değil — Servisler sekmesinden kurun", "en": "cloudflared is not installed — install it from the Services tab"],
        "share.port.title":    ["tr": "Yerel bir portu paylaş", "en": "Share a local port"],
        "share.port.hint":     ["tr": "BRAMPP'ta alan adı olmayan bir geliştirme sunucusunu paylaşın — örneğin npm run dev ile 5173'te çalışan uygulamanızı.", "en": "Share a dev server that has no BRAMPP domain — for example the app npm run dev is serving on 5173."],
        "share.port.label":    ["tr": "Port", "en": "Port"],
        "share.port.range":    ["tr": "Geçerli bir port girin (1–65535).", "en": "Enter a valid port (1–65535)."],
        "share.port.reserved": ["tr": "Bu port %@ servisine ait. Veritabanı ve önbellek servisleri internete açılmaz — üstelik tünel yalnızca HTTP taşır, istemci zaten bağlanamaz.", "en": "That port belongs to %@. Database and cache services are not put on the internet — and the tunnel only carries HTTP, so a client could not connect anyway."],
        "share.port.closed":   ["tr": "Bu portu dinleyen bir şey yok. Paylaşılan adres boş dönerdi — önce sunucuyu başlatın.", "en": "Nothing is listening on that port. The shared address would return nothing — start the server first."],
        "share.port.menu":     ["tr": "Port paylaş", "en": "Share a port"],
        "dom.log.empty":     ["tr": "Henüz log yok — uygulama ilk başlatıldığında burada görünecek.", "en": "No log yet — it appears here once the app starts for the first time."],
        "dom.share.blocked":      ["tr": "Bu site şu anda paylaşılamaz", "en": "This site cannot be shared right now"],
        "dom.share.blockDisabled":["tr": "Alan adı devre dışı — önce Alan Adları sekmesinden etkinleştirin.", "en": "The domain is disabled — enable it on the Domains tab first."],
        "dom.share.blockServer":  ["tr": "%@ çalışmıyor. Siteyi sunacak bir sunucu olmadan paylaşılan adres boş döner — Servisler sekmesinden başlatın.", "en": "%@ is not running. With nothing serving the site the shared address returns nothing — start it on the Services tab."],
        "dom.share.blockApp":     ["tr": "Arka plan uygulaması çalışmıyor. Bu hâlde paylaşırsanız ziyaretçi 502 görür — domain satırındaki ▶︎ ile başlatın.", "en": "The app behind this domain is not running. Shared like this, visitors get a 502 — start it with the ▶︎ button on the domain row."],
        "dom.share.recheck":      ["tr": "Yeniden denetle", "en": "Check again"],
        "dom.share.needsCf":  ["tr": "Paylaşım için cloudflared gerekiyor", "en": "Sharing needs cloudflared"],
        "dom.share.install":  ["tr": "cloudflared kur", "en": "Install cloudflared"],
        "menu.stopAllShares": ["tr": "Tüm paylaşımları durdur", "en": "Stop all sharing"],

        // DomainManager uyarıları — bunlar Swift içinde SABİT TÜRKÇE yazılıydı, yani
        // İngilizce arayüzde de Türkçe görünüyordu. Birden çok argüman alan metinlerde
        // konumlu belirteç (%1$@) kullanılır: argüman sırası dile göre değişebilir.
        "dom.alert.invalidName.title": ["tr": "Geçersiz Domain Adı", "en": "Invalid Domain Name"],
        "dom.alert.invalidName.msg": [
            "tr": "'%@' geçerli bir alan adı değil. Örnek: projem.test, api.test\n\nBoşluk, tırnak veya slash kullanmayın.",
            "en": "'%@' is not a valid domain name. Example: myproject.test, api.test\n\nDo not use spaces, quotes or slashes."],
        "dom.alert.reservedName.title": ["tr": "Sistem Adı Kullanılamaz", "en": "Reserved System Name"],
        "dom.alert.reservedName.msg": [
            "tr": "'%@' sistem tarafından ayrılmış bir addır (localhost, broadcasthost, IP adresleri…). Bu adla domain oluşturmak macOS'un /etc/hosts dosyasını ve paylaşılan localhost SSL sertifikasını bozar.\n\nÖrnek geçerli ad: projem.test, api.test",
            "en": "'%@' is reserved by the system (localhost, broadcasthost, IP addresses…). Creating a domain with this name would break the macOS /etc/hosts file and the shared localhost SSL certificate.\n\nValid example: myproject.test, api.test"],
        "dom.alert.duplicateName.title": ["tr": "Domain Zaten Var", "en": "Domain Already Exists"],
        "dom.alert.duplicateName.msg": [
            "tr": "'%@' adında bir domain zaten kayıtlı. Farklı bir ad kullanın veya mevcut domaini düzenleyin.",
            "en": "A domain named '%@' is already registered. Use a different name, or edit the existing one."],
        "dom.alert.dotnetMissing.title": ["tr": ".NET SDK Bulunamadı", "en": ".NET SDK Not Found"],
        "dom.alert.dotnetMissing.msg": [
            "tr": "'%@' için .NET SDK kurulu değil.\n\nServisler sekmesinden bir .NET sürümü (örn. .NET 9) kurup domaini tekrar başlatın.",
            "en": "No .NET SDK is installed for '%@'.\n\nInstall a .NET version (e.g. .NET 9) from the Services tab, then start the domain again."],

        // Sağlık kontrolü sonucu — dört dalın da başlığı ve mesajı
        "dom.health.ok.title": ["tr": "✅ %@ Çalışıyor", "en": "✅ %@ is up"],
        "dom.health.ok.msg": [
            "tr": "Site yanıt veriyor — HTTP %1$@\n%2$@",
            "en": "The site is responding — HTTP %1$@\n%2$@"],
        "dom.health.unreachable.title": ["tr": "❌ %@ Erişilemiyor", "en": "❌ %@ is unreachable"],
        "dom.health.unreachable.msg": [
            "tr": "Bağlantı kurulamadı.\n\nKontrol edin:\n• %@ çalışıyor mu? (Servisler sekmesi)\n• /etc/hosts kaydı var mı?\n• SSL sertifikası mevcut mu?",
            "en": "Could not connect.\n\nCheck:\n• Is %@ running? (Services tab)\n• Is there an /etc/hosts entry?\n• Does the SSL certificate exist?"],
        "dom.health.backendDown.title": ["tr": "⚠️ Uygulama Çalışmıyor (HTTP %@)", "en": "⚠️ App Not Running (HTTP %@)"],
        "dom.health.backendDown.msg": [
            "tr": "Web sunucusu ayakta ama arkadaki uygulama yanıt vermiyor.\n\nDomain satırındaki ▶︎ butonuyla uygulamayı başlatın.",
            "en": "The web server is up, but the app behind it is not responding.\n\nStart it with the ▶︎ button on the domain row."],
        "dom.health.unexpected.title": ["tr": "⚠️ %1$@ — HTTP %2$@", "en": "⚠️ %1$@ — HTTP %2$@"],
        "dom.health.unexpected.msg": [
            "tr": "Site yanıt verdi ama beklenmeyen durum kodu döndü: HTTP %1$@\n%2$@",
            "en": "The site responded with an unexpected status code: HTTP %1$@\n%2$@"],

        // LogsTabView
        "logs.lineCount":         ["tr": "%d satır", "en": "%d lines"],
        "logs.lineCountFiltered": ["tr": "%d/%d satır", "en": "%d/%d lines"],

        // ServicesTabView
        "svc.pmaOpenHelp":     ["tr": "phpMyAdmin'i tarayıcıda aç", "en": "Open phpMyAdmin in browser"],
        "svc.mariadbNotRunning": ["tr": "MariaDB çalışmıyor", "en": "MariaDB is not running"],
        "svc.pgadminOpenHelp2": ["tr": "pgAdmin'i tarayıcıda aç (localhost/pgadmin4)", "en": "Open pgAdmin in browser (localhost/pgadmin4)"],
        "svc.pgNotRunning":    ["tr": "PostgreSQL çalışmıyor", "en": "PostgreSQL is not running"],
        "svc.rootTcpAccess":   ["tr": "root@localhost TCP Erişimi", "en": "root@localhost TCP Access"],

        // DatabaseTabView — Adminer bağlantı ipuçları
        "db.adminerHintMysql": ["tr": "Giriş — Sistem: MySQL · Sunucu: 127.0.0.1:3306 · Kullanıcı: root (parola boş)", "en": "Login — System: MySQL · Server: 127.0.0.1:3306 · User: root (empty password)"],
        "db.adminerHintPg":    ["tr": "Giriş — Sistem: PostgreSQL · Sunucu: %@ · Kullanıcı: postgres", "en": "Login — System: PostgreSQL · Server: %@ · User: postgres"],
        // DatabaseTabView — hata uyarıları (dbErrorMessage)
        "db.backupFailed":  ["tr": "Yedek alınamadı: %@", "en": "Backup failed: %@"],
        "db.restoreFailed": ["tr": "Geri yükleme başarısız: %@", "en": "Restore failed: %@"],
        "db.createFailed":  ["tr": "Veritabanı oluşturulamadı: %@", "en": "Could not create database: %@"],
        "db.dropFailed":    ["tr": "Veritabanı silinemedi: %@", "en": "Could not drop database: %@"],
        "db.myCnfWriteFailed": ["tr": "my.cnf yazılamadı: %@", "en": "Could not write my.cnf: %@"],
        "db.redisReadFailed":  ["tr": "redis.conf okunamadı: %@", "en": "Could not read redis.conf: %@"],
        "db.redisWriteFailed": ["tr": "redis.conf yazılamadı", "en": "Could not write redis.conf"],
        "db.dumpSavePrompt":   ["tr": "'%@' veritabanının dökümü nereye kaydedilsin?", "en": "Where should the dump of database '%@' be saved?"],
        "db.restorePickPrompt": ["tr": "Geri yüklenecek .sql dökümünü seçin", "en": "Choose the .sql dump to restore"],
        // DatabaseTabView — ayar açıklamaları
        "dbset.maxConn":      ["tr": "Maks bağlantı sayısı", "en": "Max connections"],
        "dbset.sharedBuffers": ["tr": "Paylaşımlı bellek", "en": "Shared memory"],
        "dbset.workMem":      ["tr": "Sorgu başına bellek", "en": "Memory per query"],
        "dbset.maintMem":     ["tr": "Bakım belleği", "en": "Maintenance memory"],
        "dbset.listenAddr":   ["tr": "Dinleme adresleri", "en": "Listen addresses"],
        "dbset.innodbPool":   ["tr": "InnoDB tampon havuzu", "en": "InnoDB buffer pool"],
        "dbset.maxPacket":    ["tr": "Maks paket boyutu", "en": "Max packet size"],
        "dbset.innodbLog":    ["tr": "InnoDB log dosya boyutu", "en": "InnoDB log file size"],
        "dbset.charset":      ["tr": "Sunucu karakter seti", "en": "Server character set"],
        "dbset.maxMem":       ["tr": "Maks bellek (0 = sınırsız)", "en": "Max memory (0 = unlimited)"],
        "dbset.evictPolicy":  ["tr": "Bellek dolunca politika", "en": "Eviction policy"],
        "dbset.aof":          ["tr": "AOF kalıcılığı (yes/no)", "en": "AOF persistence (yes/no)"],
        "dbset.idleTimeout":  ["tr": "Boşta bağlantı zaman aşımı (sn)", "en": "Idle connection timeout (s)"],
        "dbset.dbCount":      ["tr": "Veritabanı sayısı", "en": "Number of databases"],

        // SettingsView — yol/dizin etiketleri
        "set.pathSites":      ["tr": "Sites klasörü", "en": "Sites folder"],
        "set.pathNginxConf":  ["tr": "Nginx yapılandırma", "en": "Nginx configuration"],
        "set.pathApacheConf": ["tr": "Apache yapılandırma", "en": "Apache configuration"],
        "set.pathPhpIni":     ["tr": "PHP yapılandırması (%@)", "en": "PHP configuration (%@)"],
        "set.pathHosts":      ["tr": "hosts dosyası", "en": "hosts file"],
        "set.pathAppSupport": ["tr": "Uygulama desteği", "en": "Application support"],
        "set.pickSitesMsg":   ["tr": "Yeni domainlerin oluşturulacağı klasörü seçin", "en": "Choose the folder where new domains will be created"],
        // SettingsView — SSL paneli
        "set.ssl.brewMissing":    ["tr": "Homebrew kurulu değil", "en": "Homebrew not installed"],
        "set.ssl.brewMissingSub": ["tr": "SSL sertifikaları için Homebrew gereklidir.", "en": "Homebrew is required for SSL certificates."],
        "set.ssl.mkcertOk":       ["tr": "mkcert kurulu", "en": "mkcert installed"],
        "set.ssl.mkcertMissing":  ["tr": "mkcert kurulu değil", "en": "mkcert not installed"],
        "set.ssl.mkcertMissingSub": ["tr": "Yerel SSL sertifikaları için mkcert gereklidir.", "en": "mkcert is required for local SSL certificates."],
        "set.ssl.caOk":           ["tr": "Sertifika otoritesi oluşturulmuş", "en": "Certificate authority created"],
        "set.ssl.caMissing":      ["tr": "Sertifika otoritesi oluşturulmamış", "en": "Certificate authority not created"],
        "set.ssl.caMissingSub":   ["tr": "Sertifika otoritesi henüz oluşturulmamış.", "en": "The certificate authority has not been created yet."],
        "set.ssl.trusted":        ["tr": "Sistem tarafından güvenilir", "en": "Trusted by the system"],
        "set.ssl.untrusted":      ["tr": "Sistem tarafından güvenilir değil", "en": "Not trusted by the system"],
        "set.ssl.untrustedSub":   ["tr": "Sertifika otoritesi sisteme henüz eklenmemiş.", "en": "The certificate authority has not been added to the system yet."],
        "set.ssl.installMkcert":  ["tr": "mkcert'i Kur", "en": "Install mkcert"],
        "set.ssl.installMkcertSub": ["tr": "Homebrew üzerinden mkcert ve NSS kurulumu yapılır.", "en": "Installs mkcert and NSS via Homebrew."],
        "set.ssl.installCA":      ["tr": "Sertifika Otoritesini Kur", "en": "Install Certificate Authority"],
        "set.ssl.installCASub":   ["tr": "Yerel CA oluşturulur ve sisteme güvenilir olarak eklenir.", "en": "A local CA is created and added to the system as trusted."],
        "set.ssl.setup":          ["tr": "Kurulum", "en": "Setup"],
        "set.ssl.certDir":        ["tr": "Sertifika Dizini", "en": "Certificate Directory"],

        // ── Eksik kalan yüzeyler (toplu çeviri turu) ──
        // ContentView — yedek/konsol
        "cv.restoreConfirm":     ["tr": "'%@' yedeği geri yüklenecek. Mevcut ayarlar değişecek.", "en": "The '%@' backup will be restored. Current settings will change."],
        "cv.restoreConfirmFull": ["tr": "'%@' yedeği geri yüklenecek. Mevcut ayarlar değişecek. Uygulamayı yeniden başlatmanız önerilir.", "en": "The '%@' backup will be restored. Current settings will change. Restarting the app is recommended."],
        "cv.backupMenuHelp":     ["tr": "Dışa aktar / İçe aktar / Yedekle", "en": "Export / Import / Back up"],
        "cv.backupNow":          ["tr": "Şimdi Yedekle", "en": "Back Up Now"],
        "cv.export":             ["tr": "Dışa Aktar", "en": "Export"],
        "cv.import":             ["tr": "İçe Aktar", "en": "Import"],
        "cv.copyAllHelp":        ["tr": "Tüm konsol çıktısını kopyala", "en": "Copy all console output"],
        "cv.copyMessage":        ["tr": "Mesajı Kopyala", "en": "Copy Message"],
        "cv.copyWholeLine":      ["tr": "Satırın Tamamını Kopyala", "en": "Copy Entire Line"],

        // SettingsView
        "set.autoStartNote":  ["tr": "Başlatma: Apache/Nginx başlatıldığında domainlerin kullandığı PHP-FPM sürümleri de başlatılır. Durdurma: Apache veya Nginx tamamen durduğunda etkinleşir; diğer web sunucusu hâlâ çalışıyorsa durdurma yapılmaz.", "en": "Start: when Apache/Nginx starts, the PHP-FPM versions used by domains are started too. Stop: takes effect when Apache or Nginx fully stops; if the other web server is still running, no stop is performed."],
        "set.autoConfirmNote": ["tr": "brew kurulum sırasında \"Do you want to proceed? [y/N]\" sorduğunda, kurulum penceresinden elle y/n yazabilirsiniz. Otomatik onay açıksa, süre dolunca otomatik 'y' gönderilir. Kapalıysa yanıtı siz vermelisiniz.", "en": "When brew asks \"Do you want to proceed? [y/N]\" during installation, you can type y/n manually in the install window. If auto-confirm is on, a 'y' is sent automatically when the timer expires. If off, you must answer yourself."],
        "set.updates":        ["tr": "Güncellemeler", "en": "Updates"],
        "set.sslAllReady":    ["tr": "Her şey hazır", "en": "Everything is ready"],
        "set.sslManageHint":  ["tr": "SSL sertifikaları Alan Adları sekmesinden yönetilebilir.", "en": "SSL certificates can be managed from the Domains tab."],

        // ServicesTabView
        "svc.startAllHelp":   ["tr": "Kurulu ve durmuş tüm servisleri başlatır", "en": "Starts all installed, stopped services"],
        "svc.stopAllHelp":    ["tr": "Çalışan tüm servisleri durdurur", "en": "Stops all running services"],
        "svc.refreshHelp":    ["tr": "Servis durumlarını yenile", "en": "Refresh service statuses"],
        "svc.portSettingsHelp": ["tr": "HTTP / HTTPS port ayarları", "en": "HTTP / HTTPS port settings"],
        "svc.pgadminInstallHelp": ["tr": "brew install pgadmin4 — web tabanlı pgAdmin kurulur", "en": "brew install pgadmin4 — installs web-based pgAdmin"],
        "svc.uninstallHelp":  ["tr": "%@ ve kütüphane dosyalarını kaldır", "en": "Remove %@ and its library files"],
        "svc.apachePortNote": ["tr": "httpd.conf ve httpd-ssl.conf dosyaları güncellenir,\nApache otomatik olarak yeniden başlatılır.", "en": "httpd.conf and httpd-ssl.conf are updated,\nApache restarts automatically."],
        "svc.nginxPortNote":  ["tr": "servers/ dizinindeki tüm .conf dosyaları güncellenir,\nNginx otomatik olarak yeniden başlatılır.", "en": "All .conf files in the servers/ directory are updated,\nNginx restarts automatically."],
        "svc.defaultVal":     ["tr": "(varsayılan: %@)", "en": "(default: %@)"],
        "svc.awaitingResponse": ["tr": "Yanıt bekleniyor", "en": "Awaiting response"],
        "svc.autoConfirmIn":  ["tr": "· %d sn içinde otomatik 'y'", "en": "· auto 'y' in %ds"],
        "svc.send":           ["tr": "Gönder", "en": "Send"],
        "svc.no":             ["tr": "Hayır (n)", "en": "No (n)"],
        "svc.mariadbConfig":  ["tr": "MariaDB Yapılandırması", "en": "MariaDB Configuration"],
        "svc.mariadbConfigNote": ["tr": "Homebrew MariaDB varsayılan olarak unix_socket auth kullanır. phpMyAdmin ve VS Code gibi araçların TCP ile bağlanabilmesi için root kullanıcısına mysql_native_password yetkisi verilmesi gereklidir.", "en": "Homebrew MariaDB uses unix_socket auth by default. To let tools like phpMyAdmin and VS Code connect over TCP, the root user must be granted mysql_native_password auth."],
        "svc.userLabel":      ["tr": "Kullanıcı:", "en": "User:"],
        "svc.empty":          ["tr": "(boş)", "en": "(empty)"],
        "svc.configuring":    ["tr": "Yapılandırılıyor...", "en": "Configuring..."],
        "svc.configureRoot":  ["tr": "root@localhost Yapılandır", "en": "Configure root@localhost"],

        // DatabaseTabView
        "db.adminerDesc":     ["tr": "phpMyAdmin tarzı hafif arayüz — pgAdmin'e ~500 KB'lık alternatif", "en": "phpMyAdmin-style lightweight UI — a ~500 KB alternative to pgAdmin"],
        "db.adminerOpen":     ["tr": "Adminer Aç", "en": "Open Adminer"],
        "db.adminerOpenHelp": ["tr": "localhost/adminer adresini tarayıcıda açar", "en": "Opens localhost/adminer in the browser"],
        "db.adminerRemoveHelp": ["tr": "Adminer'i kaldır (dosya + Apache/Nginx yapılandırmaları)", "en": "Remove Adminer (file + Apache/Nginx configs)"],
        "db.adminerInstallHelp": ["tr": "Tek dosya indirilir; Apache + Nginx otomatik yapılandırılır", "en": "A single file is downloaded; Apache + Nginx are configured automatically"],
        "db.pgConfigHelp":    ["tr": "pg_hba.conf trust auth • postgres superuser • boş şifre • test DB", "en": "pg_hba.conf trust auth • postgres superuser • empty password • test DB"],
        "db.pgadminOpenHelp": ["tr": "https://localhost/pgadmin4 adresini tarayıcıda açar", "en": "Opens https://localhost/pgadmin4 in the browser"],
        "db.pgadminRemoveHelp": ["tr": "pgAdmin4'ü tamamen kaldır (paket + config + veri)", "en": "Completely remove pgAdmin4 (package + config + data)"],
        "db.myCnfNote":       ["tr": "[mariadbd] bölümüne yazılır; kaydedince MariaDB yeniden başlar.", "en": "Written to the [mariadbd] section; MariaDB restarts on save."],
        // ── Redis istatistik paneli ──
        "db.redis.stats":     ["tr": "Canlı Durum",        "en": "Live Status"],
        "db.redis.uptime":    ["tr": "Çalışma süresi",     "en": "Uptime"],
        "db.redis.clients":   ["tr": "Bağlı istemci",      "en": "Connected clients"],
        "db.redis.memory":    ["tr": "Bellek kullanımı",   "en": "Memory used"],
        "db.redis.peak":      ["tr": "Zirve bellek",       "en": "Peak memory"],
        "db.redis.hitRate":   ["tr": "İsabet oranı",       "en": "Hit rate"],
        "db.redis.keys":      ["tr": "Toplam anahtar",     "en": "Total keys"],
        "db.redis.commands":  ["tr": "İşlenen komut",      "en": "Commands processed"],
        "db.redis.noData":    ["tr": "henüz istek yok",    "en": "no requests yet"],
        "db.redis.unlimited": ["tr": "sınırsız",           "en": "unlimited"],
        "db.redis.stopped":   ["tr": "Redis çalışmıyor — durum okunamıyor",
                               "en": "Redis is not running — status unavailable"],
        "db.redisNote":       ["tr": "redis.conf'a yazılır; kaydedince Redis yeniden başlar.", "en": "Written to redis.conf; Redis restarts on save."],

        // DomainsTabView
        "dom.startCmdDefault": ["tr": "Varsayılan: %@  ·  start.sh üzerinden çalıştırılır", "en": "Default: %@  ·  Runs via start.sh"],
        "dom.defaultVal":     ["tr": "Varsayılan: %@", "en": "Default: %@"],
        "dom.mkcertMissing":  ["tr": "mkcert CA kurulu değil", "en": "mkcert CA not installed"],
        "dom.loadedOkPlain":  ["tr": "%@ başarıyla yüklendi.", "en": "%@ loaded successfully."],

        // PHPExtensionsTabView
        "ext.gearHelp":       ["tr": "%@ yapılandırma dosyasını (ext-%@.ini) editörde aç", "en": "Open the %@ configuration file (ext-%@.ini) in the editor"],
        // ── Sekmeler ──
        "tab.domains":       ["tr": "Alan Adları", "en": "Domains"],
        "tab.services":      ["tr": "Servisler",   "en": "Services"],
        "tab.database":      ["tr": "Veritabanı",  "en": "Database"],
        "tab.phpExt":        ["tr": "PHP Ext.",    "en": "PHP Ext."],
        "tab.logs":          ["tr": "Loglar",      "en": "Logs"],

        // ── Ortak ──
        "common.help":       ["tr": "Yardım",      "en": "Help"],
        "common.close":      ["tr": "Kapat",       "en": "Close"],
        "common.settings":   ["tr": "Ayarlar",     "en": "Settings"],
        "common.installing": ["tr": "Kuruluyor...", "en": "Installing..."],
        "common.loading":    ["tr": "Okunuyor...",  "en": "Loading..."],
        "common.done":       ["tr": "Tamamlandı",  "en": "Done"],
        "common.brewMissing.title": ["tr": "Homebrew Kurulu Değil", "en": "Homebrew Not Installed"],
        "common.brewMissing.msg":   ["tr": "Servisleri yönetmek için Homebrew gerekiyor. Kurulum sihirbazından kurabilirsiniz.", "en": "Homebrew is required to manage services. You can install it from the setup wizard."],
        "mkcert.installing.title": ["tr": "mkcert Kuruluyor", "en": "Installing mkcert"],
        "mkcert.ca.title":         ["tr": "mkcert CA Kurulumu", "en": "mkcert CA Installation"],

        // ── Dil ayarı ──
        "settings.language.header":  ["tr": "Dil",  "en": "Language"],
        "settings.language.label":   ["tr": "Uygulama dili:", "en": "App language:"],
        "settings.language.note":    ["tr": "Türkçe dışındaki sistem dilleri İngilizce olarak gösterilir.",
                                      "en": "System languages other than Turkish are shown in English."],

        // ── Yardım içeriği ──
        "help.title":        ["tr": "Yardım ve Rehber", "en": "Help & Guide"],
        "help.intro":        ["tr": "BRAMPP, Homebrew tabanlı yerel geliştirme ortamınızı yönetir: web sunucuları, veritabanları ve domainler.",
                              "en": "BRAMPP manages your Homebrew-based local development environment: web servers, databases and domains."],

        "help.services.title": ["tr": "Servisler", "en": "Services"],
        "help.services.body":  ["tr": "Servisler sekmesinden Apache, Nginx, PHP, MariaDB, PostgreSQL, Redis gibi servisleri kurabilir, başlatabilir ve durdurabilirsiniz. Servisler `brew services run` ile başlatılır (oturum boyunca; girişte otomatik başlamaz).",
                                "en": "From the Services tab you can install, start and stop services like Apache, Nginx, PHP, MariaDB, PostgreSQL, Redis. Services are started with `brew services run` (for the session only; they do not auto-start at login)."],

        "help.domains.title": ["tr": "Alan Adları", "en": "Domains"],
        "help.domains.body":  ["tr": "Yeni Domain ile PHP, Node.js, Python, .NET veya statik site ekleyin. mkcert ile otomatik HTTPS, /etc/hosts girişi ve vhost oluşturulur. Sağ tık menüsünden: Yeniden Adlandır, Devre Dışı Bırak, SSL aç/kapa, Bağlantıyı Test Et.",
                              "en": "Add PHP, Node.js, Python, .NET or static sites with New Domain. Automatic HTTPS (mkcert), /etc/hosts entry and vhost are created. Right-click menu: Rename, Disable, toggle SSL, Test Connection."],

        "help.database.title": ["tr": "Veritabanı", "en": "Database"],
        "help.database.body":  ["tr": "MariaDB, PostgreSQL ve Redis'i yönetin. Veritabanı oluştur/sil, .sql yedek al / geri yükle. Web arayüzü için phpMyAdmin, pgAdmin veya Adminer (tek dosya, hem MySQL hem PostgreSQL) kurabilirsiniz. redis.conf / my.cnf / postgresql.conf ayar panelleri mevcuttur.",
                              "en": "Manage MariaDB, PostgreSQL and Redis. Create/drop databases, back up/restore .sql dumps. For a web UI install phpMyAdmin, pgAdmin or Adminer (single file, both MySQL and PostgreSQL). Config panels for redis.conf / my.cnf / postgresql.conf are available."],

        "help.hosts.title": ["tr": "/etc/hosts Onarımı", "en": "/etc/hosts Repair"],
        "help.hosts.body":  ["tr": "Domain girişleri /etc/hosts'tan silinirse, Alan Adları sekmesinin üstünde turuncu bir onarım şeridi çıkar; \"Onar\" ile tümü tek seferde eklenir (yönetici şifresi gerekir).",
                             "en": "If domain entries are removed from /etc/hosts, an orange repair banner appears atop the Domains tab; \"Repair\" re-adds them all at once (requires admin password)."],

        "help.tips.title": ["tr": "İpuçları", "en": "Tips"],
        "help.tips.body":  ["tr": "• Menü çubuğu simgesinden servisleri hızlıca yönetin.\n• Ayarlar → Görüntülü: menü simgesini gizleyebilir, pencere kapatma davranışını seçebilirsiniz.\n• Ayarlar → Güncellemeler: yönetilen paketler için `brew outdated` denetimi.\n• Sorun mu var? Loglar sekmesine ve Ayarlar → Konsol seçeneklerine bakın.",
                            "en": "• Manage services quickly from the menu bar icon.\n• Settings → Appearance: hide the menu icon, choose the window-close behavior.\n• Settings → Updates: `brew outdated` check for managed packages.\n• Having issues? See the Logs tab."],

        // ── Ayarlar: sekmeler ──
        "set.tab.general":  ["tr": "Genel",     "en": "General"],
        "set.tab.services": ["tr": "Servisler", "en": "Services"],
        "set.tab.console":  ["tr": "Konsol",    "en": "Console"],
        "set.tab.ssl":      ["tr": "SSL",       "en": "SSL"],
        "set.tab.mcp":      ["tr": "MCP",       "en": "MCP"],
        "set.tab.advanced": ["tr": "Gelişmiş",  "en": "Advanced"],
        "set.mcp.openBrowser":     ["tr": "Tarayıcıda Aç", "en": "Open in Browser"],
        "set.mcp.openBrowserHelp": ["tr": "Kurulum yönergelerini tarayıcıda açar (Claude Code, Claude Desktop ve beceri dosyası)", "en": "Opens the setup instructions in your browser (Claude Code, Claude Desktop and the skill file)"],
        "set.mcp.intro":           ["tr": "BRAMPP'i Claude gibi yapay zekâ araçlarına bağlar. Araçlar canlı yöneticiler üzerinden çalışır — yapılan her değişiklik arayüze anında yansır.", "en": "Connects BRAMPP to AI tools like Claude. Tools run through the live managers — every change is reflected in the UI instantly."],
        "set.mcp.toolsTitle":      ["tr": "Kullanılabilir Araçlar", "en": "Available Tools"],
        "set.mcp.security":        ["tr": "Sunucu yalnızca 127.0.0.1 adresine bağlanır, ağdan erişilemez. Tarayıcı kaynaklı isteklerde Origin ve Host doğrulanır.", "en": "The server binds to 127.0.0.1 only and is not reachable from the network. Browser-originated requests are validated by Origin and Host."],
        "set.mcp.claudeSection":   ["tr": "Claude Entegrasyonu", "en": "Claude Integration"],
        "set.mcp.desktopTitle":    ["tr": "Claude Desktop", "en": "Claude Desktop"],
        "set.mcp.desktopAdd":      ["tr": "Yapılandırmaya Ekle", "en": "Add to Config"],
        "set.mcp.desktopRemove":   ["tr": "Yapılandırmadan Kaldır", "en": "Remove from Config"],
        "set.mcp.desktopOn":       ["tr": "Claude Desktop yapılandırmasında kayıtlı", "en": "Registered in the Claude Desktop config"],
        "set.mcp.desktopOff":      ["tr": "Claude Desktop yapılandırmasında kayıtlı değil", "en": "Not registered in the Claude Desktop config"],
        "set.mcp.desktopMissing":  ["tr": "Claude Desktop yapılandırma dosyası bulunamadı", "en": "Claude Desktop configuration file not found"],
        "set.mcp.desktopNote":     ["tr": "Claude Desktop yalnızca komut (stdio) tipi sunucu kabul ettiğinden mcp-remote köprüsü yazılır; Node.js gerekir.", "en": "Claude Desktop only accepts command (stdio) servers, so an mcp-remote bridge entry is written; requires Node.js."],
        "set.mcp.skillTitle":      ["tr": "Claude Becerisi (Skill)", "en": "Claude Skill"],
        "set.mcp.skillAdd":        ["tr": "Beceriyi Kur", "en": "Install Skill"],
        "set.mcp.skillRemove":     ["tr": "Beceriyi Kaldır", "en": "Remove Skill"],
        "set.mcp.skillOn":         ["tr": "~/.claude/skills içinde kurulu", "en": "Installed in ~/.claude/skills"],
        "set.mcp.skillOff":        ["tr": "Kurulu değil", "en": "Not installed"],
        "set.mcp.skillNote":       ["tr": "Beceri dosyası Claude'a araçları ne zaman ve nasıl kullanacağını anlatır — araç listesi, argümanlar ve örnekler.", "en": "The skill file tells Claude when and how to use the tools — tool list, arguments and examples."],
        "set.mcp.backupNote":      ["tr": "Değişiklikten önce mevcut yapılandırma zaman damgalı olarak yedeklenir.", "en": "The existing configuration is backed up with a timestamp before any change."],
        "set.mcp.backupDone":      ["tr": "Yedek alındı: %@", "en": "Backup created: %@"],
        "set.mcp.restartNote":     ["tr": "Değişiklik Claude Desktop yeniden başlatıldığında etkinleşir.", "en": "The change takes effect after restarting Claude Desktop."],
        "set.mcp.writeFailed":     ["tr": "İşlem başarısız: %@", "en": "Operation failed: %@"],
        "set.mcp.revealBackup":    ["tr": "Yedeği Göster", "en": "Reveal Backup"],
        "set.mcp.permissions":     ["tr": "Erişim İzinleri", "en": "Access Permissions"],
        "set.mcp.permNote":        ["tr": "Yapay zekâ istemcisi yalnızca izin verdiğiniz araçları görür ve çağırabilir. Kapalı alanların araçları listede hiç görünmez.", "en": "The AI client only sees and can call the tools you allow. Tools of disabled areas never appear in the list."],
        "set.mcp.perm.none":       ["tr": "İzin yok", "en": "No access"],
        "set.mcp.perm.read":       ["tr": "Okuma", "en": "Read"],
        "set.mcp.perm.write":      ["tr": "Okuma + Yazma", "en": "Read + Write"],
        "set.mcp.scope.domains":   ["tr": "Alan Adları", "en": "Domains"],
        "set.mcp.scope.services":  ["tr": "Servisler", "en": "Services"],
        "set.mcp.scope.databases": ["tr": "Veritabanları", "en": "Databases"],
        "set.mcp.scope.logs":      ["tr": "Loglar", "en": "Logs"],
        "set.mcp.scope.sharing":   ["tr": "Paylaşım", "en": "Sharing"],
        "set.mcp.scope.domainsDesc":   ["tr": "Listeleme, oluşturma, güncelleme, etkinleştirme, uygulama başlat/durdur", "en": "List, create, update, enable/disable, start/stop apps"],
        "set.mcp.scope.servicesDesc":  ["tr": "Durum sorgulama, başlatma, durdurma, yeniden başlatma", "en": "Status, start, stop, restart"],
        "set.mcp.scope.databasesDesc": ["tr": "Listeleme, oluşturma, sorgulama (yazma sorguları yalnızca Yazma izniyle)", "en": "List, create, query (write queries require Read + Write)"],
        "set.mcp.scope.logsDesc":      ["tr": "BRAMPP konsolu ve alan adı logları (hata/erişim/uygulama)", "en": "BRAMPP console and domain logs (error/access/app)"],
        "set.mcp.scope.sharingDesc":   ["tr": "Cloudflare tüneli açma/kapatma — siteyi HERKESE AÇIK bir adrese çıkarır", "en": "Open and close a Cloudflare tunnel — puts the site on a PUBLIC address"],
        "set.mcp.activeTools":     ["tr": "%d araç etkin", "en": "%d tools enabled"],
        "set.mcp.codexOn":         ["tr": "~/.codex/config.toml içinde kayıtlı", "en": "Registered in ~/.codex/config.toml"],
        "set.mcp.codexOff":        ["tr": "~/.codex/config.toml içinde kayıtlı değil", "en": "Not registered in ~/.codex/config.toml"],
        "set.mcp.codexMissing":    ["tr": "ChatGPT Codex yapılandırma klasörü (~/.codex) bulunamadı", "en": "The ChatGPT Codex configuration folder (~/.codex) was not found"],
        "set.mcp.codexNote":       ["tr": "Codex, Streamable HTTP'yi doğrudan destekler — köprü gerekmez, yalnızca uç nokta adresi yazılır.", "en": "Codex supports Streamable HTTP directly — no bridge needed, only the endpoint URL is written."],
        "set.mcp.portMismatch":    ["tr": "Yazılı port geçerli porttan farklı: %@ ≠ %@", "en": "The written port differs from the current one: %@ ≠ %@"],
        "set.mcp.portMismatchFix": ["tr": "Şu istemcilerin yapılandırması eski porta bakıyor: %@ — yeni adres: %@", "en": "These clients still point at the old port: %@ — new address: %@"],
        "set.mcp.portSynced":      ["tr": "Yapılandırma yeni portla güncellendi: %@ → %@", "en": "Configuration updated with the new port: %@ → %@"],

        // ── Ayarlar: sıfırlama ──
        "set.reset.title":   ["tr": "Ayarları Sıfırla",  "en": "Reset Settings"],
        "set.reset.confirm": ["tr": "Tüm ayarlar varsayılana döner ve kurulum sihirbazı yeniden gösterilir.",
                              "en": "All settings return to defaults and the setup wizard is shown again."],
        "set.reset.all":     ["tr": "Tüm ayarları sıfırla", "en": "Reset all settings"],
        "set.reset.button":  ["tr": "Sıfırla", "en": "Reset"],
        "common.cancel":     ["tr": "İptal",   "en": "Cancel"],
        "common.open":       ["tr": "Aç",      "en": "Open"],
        "common.apply":      ["tr": "Uygula",  "en": "Apply"],
        "common.default":    ["tr": "Varsayılan", "en": "Default"],
        "common.change":     ["tr": "Değiştir…", "en": "Change…"],
        "common.openFinder": ["tr": "Finder'da Aç", "en": "Reveal in Finder"],
        "common.seconds":    ["tr": "sn", "en": "s"],

        // ── Ayarlar: Genel ──
        "set.php.header":       ["tr": "PHP", "en": "PHP"],
        "set.php.default":      ["tr": "Varsayılan PHP sürümü:", "en": "Default PHP version:"],
        "set.refresh.header":   ["tr": "Otomatik Yenileme", "en": "Auto Refresh"],
        "set.refresh.interval": ["tr": "Durum yenileme aralığı:", "en": "Status refresh interval:"],
        "set.refresh.note":     ["tr": "En az 10, en fazla 300 saniye. Değişiklik anında uygulanır.",
                                 "en": "Between 10 and 300 seconds. Applied immediately."],
        "set.appearance.header":   ["tr": "Görünüm ve Davranış", "en": "Appearance & Behavior"],
        "set.menuIcon":            ["tr": "Menü çubuğu ikonunu göster", "en": "Show menu bar icon"],
        "set.hideOnClose":         ["tr": "Pencere kapatınca gizle (çıkma)", "en": "Hide on window close (don't quit)"],
        "set.appearance.note":     ["tr": "Gizleme kapalıyken kırmızı X uygulamadan tamamen çıkar; \"Kapanırken servisleri durdur\" ayarına uyulur.",
                                    "en": "When hiding is off, the red X fully quits the app; the \"Stop services on quit\" setting is honored."],
        "set.site.header":         ["tr": "Site Konumu", "en": "Site Location"],
        "set.site.newFolder":      ["tr": "Yeni domain klasörü:", "en": "New domain folder:"],
        "set.site.note":           ["tr": "Yalnızca YENİ oluşturulan domainler bu klasöre gider; mevcut domainlerin yolu değişmez.",
                                    "en": "Only NEWLY created domains go to this folder; existing domains keep their path."],
        "set.dirs.header":         ["tr": "Dizinler ve Dosyalar", "en": "Directories & Files"],
        "set.dirs.note":           ["tr": "Klasörler Finder'da, yapılandırma dosyaları varsayılan metin editöründe açılır.",
                                    "en": "Folders open in Finder, config files open in your default text editor."],

        // ── Ayarlar: Servisler ──
        "set.svcBehavior.header":  ["tr": "Servis Davranışı", "en": "Service Behavior"],
        "set.autoStart":           ["tr": "Uygulama açılışında servisleri başlat", "en": "Start services at app launch"],
        "set.autoStop":            ["tr": "Uygulama kapanırken servisleri durdur", "en": "Stop services on quit"],
        "set.notify":              ["tr": "Servis çöküşlerinde bildirim gönder", "en": "Notify on service crashes"],
        "set.svcBehavior.note":    ["tr": "\"Son çalışan servisleri başlat\": uygulama kapanırken çalışır durumda olan servisler bir sonraki açılışta otomatik başlatılır.",
                                    "en": "\"Start last running services\": services running at quit are auto-started on next launch."],
        "set.dep.header":          ["tr": "Bağımlı Servisler", "en": "Dependent Services"],
        "set.dep.startPHP":        ["tr": "Web sunucusu başladığında PHP-FPM'i başlat", "en": "Start PHP-FPM when web server starts"],
        "set.dep.stopPHP":         ["tr": "Web sunucusu durduğunda PHP-FPM'i durdur", "en": "Stop PHP-FPM when web server stops"],
        "set.dep.stopDomains":     ["tr": "Web sunucusu durduğunda domain servislerini durdur", "en": "Stop domain services when web server stops"],
        "set.dep.note":            ["tr": "Başlatma: Apache/Nginx başlatıldığında domainlerin kullandığı PHP-FPM sürümleri de başlatılır. Durdurma: Apache veya Nginx tamamen durduğunda etkinleşir; diğer web sunucusu hâlâ çalışıyorsa durdurma yapılmaz.",
                                    "en": "Start: when Apache/Nginx starts, the PHP-FPM versions used by domains also start. Stop: triggers only when Apache or Nginx fully stops; if the other web server is still running, nothing is stopped."],
        "set.confirm.header":      ["tr": "Kurulum Onayı", "en": "Install Confirmation"],
        "set.confirm.auto":        ["tr": "Kurulum onayına otomatik 'y' gönder", "en": "Auto-send 'y' to install prompts"],
        "set.confirm.wait":        ["tr": "Bekleme süresi:", "en": "Wait time:"],
        "set.confirm.note":        ["tr": "brew kurulum sırasında \"Do you want to proceed? [y/N]\" sorduğunda, kurulum penceresinden elle y/n yazabilirsiniz. Otomatik onay açıksa, süre dolunca otomatik 'y' gönderilir. Kapalıysa yanıtı siz vermelisiniz.",
                                    "en": "When brew asks \"Do you want to proceed? [y/N]\" during install, you can type y/n manually in the install window. If auto-confirm is on, 'y' is sent when the timer elapses. If off, you must answer."],

        // ── Ayarlar: Konsol ──
        "set.view.header":         ["tr": "Görünüm", "en": "View"],
        "set.showConsole":         ["tr": "Konsol panelini göster", "en": "Show console panel"],
        "set.showConsole.note":    ["tr": "Kapatıldığında konsol bölmesi gizlenir, kayıt devam eder.",
                                    "en": "When off, the console pane is hidden; logging continues."],
        "set.svcCmd.header":       ["tr": "Servis Komutları", "en": "Service Commands"],
        "set.showCmd":             ["tr": "Servis komutlarını göster", "en": "Show service commands"],
        "set.showBrewOut":         ["tr": "Brew yanıt çıktısını göster", "en": "Show brew response output"],
        "set.svcCmd.note1":        ["tr": "Komut: başlat/durdur/yeniden başlat sırasında çalıştırılan brew satırı",
                                    "en": "Command: the brew line run during start/stop/restart"],
        "set.svcCmd.note2":        ["tr": "Yanıt: brew'in döndürdüğü stdout/stderr çıktısı",
                                    "en": "Response: the stdout/stderr returned by brew"],
        "set.verbose.header":      ["tr": "Gelişmiş Kayıt", "en": "Verbose Logging"],
        "set.verbose.toggle":      ["tr": "Tüm komutları kaydet (verbose)", "en": "Log all commands (verbose)"],
        "set.verbose.note":        ["tr": "Açıkken yenileme, port kontrolü, launchctl sorguları dahil her shell komutu konsola yazılır. Hata ayıklama için kullanın — normal kullanımda kapalı bırakın.",
                                    "en": "When on, every shell command (refresh, port checks, launchctl queries) is logged. Use for debugging — keep off in normal use."],

        // ── Ayarlar: Gelişmiş ──
        "set.system.header":       ["tr": "Sistem", "en": "System"],
        "set.brew.location":       ["tr": "Homebrew konumu:", "en": "Homebrew location:"],
        "set.brew.status":         ["tr": "Homebrew durumu:", "en": "Homebrew status:"],
        "set.brew.installed":      ["tr": "Kurulu", "en": "Installed"],
        "set.brew.notInstalled":   ["tr": "Kurulu değil", "en": "Not installed"],
        "set.wizard.label":        ["tr": "Kurulum sihirbazı:", "en": "Setup wizard:"],
        "set.wizard.done":         ["tr": "Tamamlandı", "en": "Completed"],
        "set.wizard.notDone":      ["tr": "Tamamlanmadı", "en": "Not completed"],
        "set.about.header":        ["tr": "Hakkında", "en": "About"],
        "set.about.version":       ["tr": "Versiyon:", "en": "Version:"],
        // ── Güncelleme denetimi ──
        "set.update.check":     ["tr": "Güncellemeleri denetle", "en": "Check for updates"],
        "set.update.checking":  ["tr": "Denetleniyor…",          "en": "Checking…"],
        "set.update.upToDate":  ["tr": "En güncel sürümdesiniz", "en": "You're up to date"],
        // %@ = yeni sürüm numarası
        "set.update.available": ["tr": "Yeni sürüm var: %@",     "en": "Update available: %@"],
        "set.update.failed":    ["tr": "Denetlenemedi — bağlantıyı kontrol edin",
                                 "en": "Couldn't check — verify your connection"],
        "set.update.open":      ["tr": "Sürüm sayfasını aç",     "en": "Open release page"],
        "set.about.domains":       ["tr": "Kayıtlı alan adları:", "en": "Registered domains:"],
        "set.about.domainsCount":  ["tr": "%d adet", "en": "%d total"],
        "set.updates.header":      ["tr": "Güncellemeler", "en": "Updates"],
        "set.updates.check":       ["tr": "Güncellemeleri denetle", "en": "Check for updates"],
        "set.updates.desc":        ["tr": "Yönetilen Homebrew paketleri (PHP, servisler) için yeni sürüm var mı kontrol eder.",
                                    "en": "Checks whether managed Homebrew packages (PHP, services) have newer versions."],
        "set.updates.checking":    ["tr": "Denetleniyor…", "en": "Checking…"],
        "set.updates.check.btn":   ["tr": "Denetle", "en": "Check"],
        "set.updates.upToDate":    ["tr": "Tüm paketler güncel.", "en": "All packages up to date."],
        "set.updates.available":   ["tr": "%d paket güncellenebilir:", "en": "%d package(s) can be updated:"],
        "set.updates.howto":       ["tr": "Güncellemek için Terminal'de:  brew upgrade", "en": "To update, in Terminal:  brew upgrade"],

        // ── Menü çubuğu ──
        "menu.startAll":  ["tr": "Tümünü Başlat", "en": "Start All"],
        "menu.stopAll":   ["tr": "Tümünü Durdur", "en": "Stop All"],
        // ── Native menü çubuğu (uygulamaya özel öğeler) ──
        "menu.about":        ["tr": "BRAMPP Hakkında", "en": "About BRAMPP"],
        "menu.credits":      ["tr": "Karaca Teknoloji (Macit Karaca)\n© 2023 – 2026 · MIT lisansı\nkaracatechnology.com", "en": "Karaca Teknoloji (Macit Karaca)\n© 2023 – 2026 · MIT license\nkaracatechnology.com"],
        "menu.hide":         ["tr": "BRAMPP'i Gizle", "en": "Hide BRAMPP"],
        "menu.hideOthers":   ["tr": "Diğerlerini Gizle", "en": "Hide Others"],
        "menu.showAll":      ["tr": "Tümünü Göster", "en": "Show All"],
        "menu.quitApp":      ["tr": "BRAMPP'ten Çık", "en": "Quit BRAMPP"],
        "menu.quitNoStop":   ["tr": "Servisleri Durdurmadan Çık", "en": "Quit Without Stopping Services"],
        "menu.services":     ["tr": "Servisler", "en": "Services"],
        "menu.restartApache": ["tr": "Apache Yeniden Başlat", "en": "Restart Apache"],
        "menu.refreshLight": ["tr": "Hafif Yenile", "en": "Light Refresh"],
        "menu.domain":       ["tr": "Alan Adı", "en": "Domain"],
        "menu.newDomain":    ["tr": "Yeni Alan Adı Ekle…", "en": "Add New Domain…"],
        "menu.dockStopQuit": ["tr": "Servisleri Durdur ve Kapat", "en": "Stop Services and Quit"],
        "menu.helpItem":     ["tr": "BRAMPP Yardımı", "en": "BRAMPP Help"],
        "set.launchAtLogin": ["tr": "Girişte BRAMPP'i başlat", "en": "Launch BRAMPP at login"],
        "svc.inputHint":     ["tr": "Kuruluma girdi gönder — gerekirse y / n yazın", "en": "Send input to the installer — type y / n if needed"],
        "dom.dependencies":  ["tr": "Bağımlılıklar", "en": "Dependencies"],
        "dom.dependenciesHint": ["tr": "Bu alan adı başlatılmadan önce seçili servisler otomatik başlatılır.", "en": "Selected services are started automatically before this domain starts."],
        "dom.depsNone":      ["tr": "Kurulu veritabanı/önbellek servisi yok", "en": "No installed database/cache services"],
        "dom.fieldName":     ["tr": "Alan Adı", "en": "Domain"],
        "dom.webServerLabel": ["tr": "Web Sunucusu", "en": "Web Server"],
        "menu.openApp":   ["tr": "Uygulamayı Aç", "en": "Open App"],
        "menu.quit":      ["tr": "Çıkış", "en": "Quit"],
        "menu.running":   ["tr": "çalışıyor", "en": "running"],
        "menu.checking":  ["tr": "Kontrol ediliyor...", "en": "Checking..."],
        "menu.noServices": ["tr": "Yüklü servis bulunamadı", "en": "No installed services"],
        "menu.loadingStatus": ["tr": "Servis durumları alınıyor...", "en": "Loading service status..."],
        "menu.installHint": ["tr": "Ana pencereden servis kurabilirsiniz.", "en": "You can install services from the main window."],
        "menu.openMain":  ["tr": "Ana Pencereyi Aç", "en": "Open Main Window"],
        "menu.unavailable": ["tr": "Servis Yönetimi Kullanılamıyor", "en": "Service Management Unavailable"],
        "menu.stopped":   ["tr": "durdu", "en": "stopped"],
        "menu.noBrew":    ["tr": "Homebrew kurulu değil.", "en": "Homebrew is not installed."],
        "menu.setupIncomplete": ["tr": "Kurulum tamamlanmamış.", "en": "Setup is not complete."],
        "menu.disabled":  ["tr": "Devre dışı.", "en": "Disabled."],
        "svc.start":      ["tr": "Başlat", "en": "Start"],
        "svc.stop":       ["tr": "Durdur", "en": "Stop"],
        "svc.restart":    ["tr": "Yeniden Başlat", "en": "Restart"],

        // ── Loglar sekmesi ──
        "logs.title":      ["tr": "Loglar", "en": "Logs"],
        "logs.auto":       ["tr": "Otomatik", "en": "Auto"],
        "logs.search":     ["tr": "Logda ara...", "en": "Search logs..."],
        "logs.noResult":   ["tr": "'%@' için sonuç bulunamadı", "en": "No results for '%@'"],
        "logs.empty":      ["tr": "Log dosyası boş", "en": "Log file is empty"],
        "logs.needBrew":   ["tr": "Log dosyalarını görüntülemek için Homebrew gerekiyor.", "en": "Homebrew is required to view log files."],
        "logs.notFound":   ["tr": "Log bulunamadı: %@", "en": "Log not found: %@"],

        // ── PHP Eklentileri sekmesi ──
        "ext.title":       ["tr": "PHP Eklentileri", "en": "PHP Extensions"],
        "ext.iniSettings": ["tr": "php.ini Ayarları", "en": "php.ini Settings"],
        "ext.search":      ["tr": "Eklenti ara...", "en": "Search extensions..."],
        "ext.install":     ["tr": "Kur", "en": "Install"],
        "ext.installed":   ["tr": "built-in", "en": "built-in"],
        "ext.save":        ["tr": "Kaydet", "en": "Save"],
        "ext.needPhp":     ["tr": "PHP eklentilerini yönetmek için Homebrew ve PHP gerekiyor.", "en": "Homebrew and PHP are required to manage PHP extensions."],
        "ext.noPhp":       ["tr": "Kurulu PHP sürümü bulunamadı", "en": "No installed PHP version found"],
        "ext.noPhpHint":   ["tr": "Servisler sekmesinden bir PHP sürümü kurabilirsiniz.", "en": "You can install a PHP version from the Services tab."],
        "ext.noPhpShort":  ["tr": "Kurulu PHP yok", "en": "No PHP installed"],
        "ext.resetDefaults": ["tr": "Varsayılanlara Dön", "en": "Reset to Defaults"],

        // ── Servisler sekmesi ──
        "svc.title":       ["tr": "Servisler", "en": "Services"],
        "svc.searchPh":    ["tr": "Servis ara...", "en": "Search services..."],
        "svc.install":     ["tr": "Kur", "en": "Install"],
        "svc.uninstall":   ["tr": "Kaldır", "en": "Uninstall"],
        "svc.installing":  ["tr": "Kuruluyor...", "en": "Installing..."],
        "svc.running":     ["tr": "Çalışıyor", "en": "Running"],
        "svc.stopped":     ["tr": "Durduruldu", "en": "Stopped"],
        "svc.installed":   ["tr": "Kurulu", "en": "Installed"],
        "svc.unknown":     ["tr": "Bilinmiyor", "en": "Unknown"],
        "db.adminerTag":   ["tr": "tek dosya, MySQL + PostgreSQL", "en": "single file, MySQL + PostgreSQL"],
        "db.adminerWeb":   ["tr": "Web Sunucusu", "en": "Web Server"],
        "svc.stoppedShort": ["tr": "Durdu", "en": "Stopped"],
        "svc.notInstalled": ["tr": "Kurulu Değil", "en": "Not Installed"],
        "svc.installedState": ["tr": "Kurulu", "en": "Installed"],
        "svc.starting":    ["tr": "Başlatılıyor", "en": "Starting"],
        "svc.stopping":    ["tr": "Durduruluyor", "en": "Stopping"],
        "svc.needBrew":    ["tr": "Servisleri yönetmek için Homebrew gerekiyor.", "en": "Homebrew is required to manage services."],
        "svc.category.web":      ["tr": "Web Sunucuları", "en": "Web Servers"],
        "svc.category.php":      ["tr": "PHP Sürümleri", "en": "PHP Versions"],
        "svc.category.database": ["tr": "Veritabanları", "en": "Databases"],
        "svc.category.cache":    ["tr": "Önbellek", "en": "Cache"],
        "svc.category.runtime":  ["tr": "Çalışma Zamanları", "en": "Runtimes"],
        "svc.category.tools":    ["tr": "Araçlar", "en": "Tools"],
        "svc.sort":        ["tr": "Sırala", "en": "Sort"],
        "svc.sort.category": ["tr": "Kategori", "en": "Category"],
        "svc.sort.name":   ["tr": "İsim", "en": "Name"],
        "svc.sort.status": ["tr": "Durum", "en": "Status"],
        "svc.all":         ["tr": "Tümü (A-Z)", "en": "All (A-Z)"],
        "svc.other":       ["tr": "Diğer", "en": "Other"],
        "svc.uninstall.confirm": ["tr": "Bu işlem geri alınamaz. Paket ve yapılandırma dosyaları silinecek.",
                                  "en": "This cannot be undone. The package and its config files will be removed."],
        "svc.apachePorts": ["tr": "Apache Port Ayarları", "en": "Apache Port Settings"],
        "svc.nginxPorts":  ["tr": "Nginx Port Ayarları", "en": "Nginx Port Settings"],
        "svc.httpPort":    ["tr": "HTTP Port", "en": "HTTP Port"],
        "svc.httpsPort":   ["tr": "HTTPS Port", "en": "HTTPS Port"],
        "svc.portHint":    ["tr": "Geçerli port numaraları giriniz (1–65535, HTTP ≠ HTTPS)", "en": "Enter valid port numbers (1–65535, HTTP ≠ HTTPS)"],
        "svc.uninstall.title": ["tr": "%@ Kaldırılsın mı?", "en": "Remove %@?"],
        "svc.saveRestart": ["tr": "Kaydet ve Yeniden Başlat", "en": "Save & Restart"],
        "cat.webServer":   ["tr": "Web Sunucusu", "en": "Web Server"],
        "cat.database":    ["tr": "Veritabanı", "en": "Database"],

        // ── Yedekleme / Konsol (ContentView) ──
        "backup.title":    ["tr": "Yedekle / Geri Yükle", "en": "Backup / Restore"],
        "backup.settingsNote": ["tr": "Domainleri, ayarları, vhost'ları ve SSL sertifikalarını yedekleyin veya geri yükleyin.", "en": "Back up or restore domains, settings, vhosts and SSL certificates."],
        "svc.showInstallable": ["tr": "Kurulabilir servisleri göster", "en": "Show installable services"],
        "svc.hideInstallable": ["tr": "Kurulabilirleri gizle", "en": "Hide installable"],
        "set.autoStartPick":   ["tr": "Açılışta başlatılacak servisleri seçin:", "en": "Choose services to start at launch:"],
        "set.autoStartNoServices": ["tr": "Henüz kurulu servis yok", "en": "No installed services yet"],
        "dom.python.useVenv":  ["tr": "Virtual Environment Kullan", "en": "Use Virtual Environment"],
        "dom.python.detected": ["tr": "Tespit edildi: %@", "en": "Detected: %@"],
        "dom.portReserved":    ["tr": "Bu port bir web sunucusu tarafından kullanılıyor", "en": "This port is used by a web server"],
        "dom.nameInvalid":     ["tr": "Geçersiz alan adı — yalnızca harf, rakam, tire ve nokta kullanılabilir", "en": "Invalid domain name — only letters, digits, hyphens and dots are allowed"],
        "dom.nameTaken":       ["tr": "Bu alan adı zaten mevcut", "en": "This domain name already exists"],
        "db.mariaTCPOk":       ["tr": "root@localhost TCP erişimi yapılandırılmış — root / boş parola ile bağlanabilirsiniz", "en": "root@localhost TCP access is configured — connect with root / empty password"],
        "set.mcp.title":       ["tr": "MCP Sunucusu", "en": "MCP Server"],
        "set.mcp.enable":      ["tr": "MCP sunucusunu etkinleştir", "en": "Enable MCP server"],
        "set.mcp.port":        ["tr": "Port", "en": "Port"],
        "set.mcp.running":     ["tr": "Çalışıyor", "en": "Running"],
        "set.mcp.stopped":     ["tr": "Kapalı", "en": "Off"],
        "set.mcp.copyUrl":     ["tr": "URL'yi Kopyala", "en": "Copy URL"],
        "set.mcp.portHint":    ["tr": "Port değişikliği sunucuyu yeniden başlatır", "en": "Changing the port restarts the server"],
        "set.mcp.startError":  ["tr": "MCP sunucusu başlatılamadı: %@", "en": "MCP server failed to start: %@"],
        "backup.list":     ["tr": "Yedekler", "en": "Backups"],
        "backup.none":     ["tr": "Henüz yedek yok", "en": "No backups yet"],
        "backup.restore":  ["tr": "Geri Yükle", "en": "Restore"],
        "backup.actions":  ["tr": "İşlemler", "en": "Actions"],
        "backup.create":   ["tr": "Yedek Oluştur", "en": "Create Backup"],
        "backup.create.desc": ["tr": "Mevcut domain listesi ve ayarları yedekler.", "en": "Backs up the current domain list and settings."],
        "backup.exportImport": ["tr": "Dışa / İçe Aktar", "en": "Export / Import"],
        "backup.exportImport.desc": ["tr": "Domain listesini JSON dosyası olarak paylaşın.", "en": "Share the domain list as a JSON file."],
        "backup.confirmTitle": ["tr": "Geri Yükleme Onayı", "en": "Confirm Restore"],
        "backup.restoreTitle": ["tr": "Geri Yükleme", "en": "Restore"],

        // ── Yedek silme onayı ────────────────────────────────────────────────
        "backup.deleteConfirmTitle": ["tr": "Yedeği Sil", "en": "Delete Backup"],
        "backup.deleteConfirmMsg":   ["tr": "'%@' yedeği Çöp Kutusu'na taşınacak. Bu yedekten geri yükleme yapamazsınız.",
                                      "en": "The '%@' backup will be moved to the Trash. You will not be able to restore from it."],

        // ── İşlem sonucu uyarıları (başarısızlık artık yutulmuyor) ───────────
        "backup.resultOkTitle":   ["tr": "Tamamlandı", "en": "Done"],
        "backup.resultFailTitle": ["tr": "İşlem Başarısız", "en": "Operation Failed"],
        "backup.createFailMsg":   ["tr": "Yedek alınamadı. Ayrıntılar için konsol çıktısına bakın.",
                                   "en": "The backup could not be created. See the console output for details."],
        "backup.restoreOkMsg":    ["tr": "Yedek geri yüklendi. Değişikliklerin geçerli olması için uygulamayı yeniden başlatın.",
                                   "en": "Backup restored. Restart the app for the changes to take effect."],
        "backup.restoreFailMsg":  ["tr": "Geri yükleme tamamlanamadı; bazı dosyalar eski halinde kalmış olabilir. Ayrıntılar için konsol çıktısına bakın.",
                                   "en": "The restore did not complete; some files may be left unchanged. See the console output for details."],
        "backup.deleteFailMsg":   ["tr": "Yedek silinemedi. Ayrıntılar için konsol çıktısına bakın.",
                                   "en": "The backup could not be deleted. See the console output for details."],

        // ── İçe aktarma onayı ────────────────────────────────────────────────
        "backup.importPanelMsg":     ["tr": "Dışa aktarılmış domain JSON dosyasını seçin",
                                      "en": "Choose an exported domain JSON file"],
        "backup.importConfirmTitle": ["tr": "İçe Aktarmayı Onayla", "en": "Confirm Import"],
        // %@1 = dosya adı, %@2 = gelecek alan adı sayısı, %@3 = mevcut (silinecek) sayı
        "backup.importConfirmMsg":   ["tr": "'%@' dosyasındaki %@ alan adı içe aktarılacak. Mevcut listedeki %@ alan adı YERİNE geçecek (kaydı silinir; işlem öncesi otomatik yedek alınır).",
                                      "en": "'%@' contains %@ domain(s) to import. They REPLACE the %@ domain(s) in the current list (their records are removed; an automatic backup is taken first)."],
        "console.title":   ["tr": "Konsol", "en": "Console"],
        "cv.exportDomains": ["tr": "Alan Adlarını Dışa Aktar", "en": "Export Domains"],
        "cv.importDomains": ["tr": "Alan Adlarını İçe Aktar", "en": "Import Domains"],
        "cv.refresh":      ["tr": "Yenile", "en": "Refresh"],

        // ── Veritabanı sekmesi ──
        "db.deleteTitle":  ["tr": "Veritabanı Sil", "en": "Delete Database"],
        "db.delete":       ["tr": "Sil", "en": "Delete"],
        "db.deleteConfirm": ["tr": "'%@' veritabanı kalıcı olarak silinecek. Bu işlem geri alınamaz.", "en": "Database '%@' will be permanently deleted. This cannot be undone."],
        "db.pgadmin.removeTitle": ["tr": "pgAdmin4'ü Kaldır", "en": "Remove pgAdmin4"],
        "db.pgadmin.removeMsg": ["tr": "pgAdmin4 paketi, Apache/Nginx yapılandırmaları ve kayıtlı sunucu bağlantıları (~/.pgadmin) tamamen silinecek.", "en": "The pgAdmin4 package, Apache/Nginx configs and saved server connections (~/.pgadmin) will be fully removed."],
        "db.adminer.removeTitle": ["tr": "Adminer'i Kaldır", "en": "Remove Adminer"],
        "db.adminer.removeMsg": ["tr": "Adminer dosyası ve Apache/Nginx yapılandırmaları silinecek.", "en": "The Adminer file and Apache/Nginx configs will be removed."],
        "db.opError":      ["tr": "Veritabanı İşlem Hatası", "en": "Database Operation Error"],
        "common.ok":       ["tr": "Tamam", "en": "OK"],
        "common.save":     ["tr": "Kaydet", "en": "Save"],
        "common.delete":   ["tr": "Sil", "en": "Delete"],
        "common.refresh":  ["tr": "Yenile", "en": "Refresh"],
        "common.general":  ["tr": "Genel", "en": "General"],
        "common.status":   ["tr": "Durum", "en": "Status"],
        "db.installFromServices": ["tr": "Servisler sekmesinden kurabilirsiniz", "en": "You can install it from the Services tab"],
        "db.adminerInstall":  ["tr": "Adminer Kur", "en": "Install Adminer"],
        "db.pgadminInstall":  ["tr": "pgAdmin Kur", "en": "Install pgAdmin"],
        "db.phpMyAdminInstall": ["tr": "phpMyAdmin Kur", "en": "Install phpMyAdmin"],
        "dom.autoRefresh": ["tr": "Otomatik Yenile", "en": "Auto Refresh"],
        "dom.buildInstall": ["tr": "Derle / Kur", "en": "Build / Install"],
        "dom.hideLog":     ["tr": "Logu Gizle", "en": "Hide Log"],
        "dom.maxSize":     ["tr": "Maks. Boyut", "en": "Max Size"],
        "dom.newDomain":   ["tr": "Yeni Alan Adı", "en": "New Domain"],
        "svc.yes":         ["tr": "Evet (y)", "en": "Yes (y)"],
        "svc.passwordLabel": ["tr": "Parola:", "en": "Password:"],
        "common.remove":   ["tr": "Kaldır", "en": "Remove"],
        "common.start":    ["tr": "Başlat", "en": "Start"],
        "common.create":   ["tr": "Oluştur", "en": "Create"],
        "db.notInstalled": ["tr": "%@ kurulu değil", "en": "%@ is not installed"],
        "db.notRunning":   ["tr": "%@ çalışmıyor", "en": "%@ is not running"],
        "db.conn.pg":      ["tr": "Bağlantı Bilgileri — PostgreSQL %@", "en": "Connection Info — PostgreSQL %@"],
        "db.conn.maria":   ["tr": "Bağlantı Bilgileri", "en": "Connection Info"],
        "db.conn.redis":   ["tr": "Bağlantı Bilgileri — Redis", "en": "Connection Info — Redis"],
        "db.user":         ["tr": "Kullanıcı", "en": "User"],
        "db.password":     ["tr": "Parola", "en": "Password"],
        "db.empty":        ["tr": "(boş)", "en": "(empty)"],
        "db.command":      ["tr": "Komut", "en": "Command"],
        "db.database":     ["tr": "Veritabanı", "en": "Database"],
        "db.pg.firstConfig": ["tr": "İlk Yapılandırma", "en": "Initial Setup"],
        "db.pg.firstConfigDesc": ["tr": "trust auth, postgres superuser, boş şifre, test DB", "en": "trust auth, postgres superuser, empty password, test DB"],
        "db.configure":    ["tr": "Yapılandır", "en": "Configure"],
        "db.pgadmin.desc": ["tr": "Web tabanlı PostgreSQL yönetim arayüzü — Apache/Nginx üzerinden erişilir", "en": "Web-based PostgreSQL admin UI — accessed via Apache/Nginx"],
        "db.pgadmin.open": ["tr": "pgAdmin Aç", "en": "Open pgAdmin"],
        "db.webConfig":    ["tr": "Web Sunucusu Yapılandırması", "en": "Web Server Configuration"],
        "db.notInstalledShort": ["tr": "(kurulu değil)", "en": "(not installed)"],
        "db.databases":    ["tr": "Veritabanları", "en": "Databases"],
        "db.restore":      ["tr": "Geri Yükle…", "en": "Restore…"],
        "db.restore.help": ["tr": ".sql dökümünü bir veritabanına geri yükle", "en": "Restore a .sql dump into a database"],
        "db.newDB":        ["tr": "Yeni DB", "en": "New DB"],
        "db.noDatabases":  ["tr": "Veritabanı bulunamadı", "en": "No databases found"],
        "db.dump.help":    ["tr": "Yedek al (.sql dökümü)", "en": "Back up (.sql dump)"],
        "db.saveSettings": ["tr": "Ayarları Kaydet", "en": "Save Settings"],
        "db.mariaTCP":     ["tr": "root@localhost TCP erişimi", "en": "root@localhost TCP access"],
        "db.mariaTCPDesc": ["tr": "Homebrew MariaDB unix_socket auth kullanır. TCP bağlantısı (phpMyAdmin, VS Code vb.) için mysql_native_password yapılandırması gereklidir.", "en": "Homebrew MariaDB uses unix_socket auth. A TCP connection (phpMyAdmin, VS Code, etc.) requires mysql_native_password configuration."],
        "db.mariaTCPConfig": ["tr": "root@localhost Yapılandır", "en": "Configure root@localhost"],
        "db.pma.desc":     ["tr": "MariaDB web yönetim arayüzü", "en": "MariaDB web admin UI"],
        "db.pma.open":     ["tr": "phpMyAdmin Aç", "en": "Open phpMyAdmin"],
        "db.redis.hint":   ["tr": "Redis'i terminalden yönetmek için `redis-cli` kullanın. (Redis için standart bir web arayüzü gelmez.)", "en": "Use `redis-cli` to manage Redis from the terminal. (Redis has no standard web UI.)"],
        "db.create.title": ["tr": "Yeni Veritabanı Oluştur", "en": "Create New Database"],
        "db.create.name":  ["tr": "Veritabanı adı", "en": "Database name"],
        "db.restore.title": ["tr": "Veritabanını Geri Yükle", "en": "Restore Database"],
        "db.restore.target": ["tr": "Hedef veritabanı", "en": "Target database"],
        "db.version":       ["tr": "Versiyon", "en": "Version"],

        // ── Domainler sekmesi ──
        "dom.title":       ["tr": "Alan Adları", "en": "Domains"],
        "dom.new":         ["tr": "Yeni Alan Adı", "en": "New Domain"],
        "dom.search":      ["tr": "Alan adı ara…", "en": "Search domains…"],
        "dom.deleteTitle": ["tr": "Domain Sil", "en": "Delete Domain"],
        "dom.deleteMsg":   ["tr": "'%@' silinecek. Bu işlem geri alınamaz.", "en": "'%@' will be deleted. This cannot be undone."],
        "dom.hostsMissing": ["tr": "%d domainin /etc/hosts girişi eksik", "en": "%d domain(s) missing from /etc/hosts"],
        "dom.repair":      ["tr": "Onar", "en": "Repair"],
        "dom.repairing":   ["tr": "Onarılıyor…", "en": "Repairing…"],
        "dom.noResult":    ["tr": "'%@' için domain bulunamadı", "en": "No domains found for '%@'"],
        "dom.empty":       ["tr": "Henüz domain eklenmemiş", "en": "No domains added yet"],
        "dom.emptyHint":   ["tr": "Yeni bir domain ekleyerek başlayın", "en": "Get started by adding a domain"],
        "dom.disabled":    ["tr": "Devre dışı", "en": "Disabled"],
        "dom.running":     ["tr": "Çalışıyor", "en": "Running"],
        "dom.notRunning":  ["tr": "Çalışmıyor", "en": "Not running"],
        "dom.pidTip":      ["tr": "Çalışan süreç PID: %@", "en": "Running process PID: %@"],
        "dom.configExists": ["tr": "BRAMPP config mevcut", "en": "BRAMPP config present"],
        "dom.start":       ["tr": "Başlat", "en": "Start"],
        "dom.openApache":  ["tr": "Apache üzerinden aç (:80 / :443)", "en": "Open via Apache (:80 / :443)"],
        "dom.openNginx":   ["tr": "Nginx üzerinden aç (:8080 / :8443)", "en": "Open via Nginx (:8080 / :8443)"],
        "dom.finder":      ["tr": "Finder'da Aç", "en": "Reveal in Finder"],
        "dom.settings":    ["tr": "Domain Ayarları", "en": "Domain Settings"],
        "dom.logs":        ["tr": "Log Kayıtları", "en": "Logs"],
        "dom.testConn":    ["tr": "Bağlantıyı Test Et", "en": "Test Connection"],
        "dom.rename":      ["tr": "Yeniden Adlandır", "en": "Rename"],
        "dom.disable":     ["tr": "Devre Dışı Bırak", "en": "Disable"],
        "dom.enable":      ["tr": "Etkinleştir", "en": "Enable"],
        "dom.delete":      ["tr": "Sil", "en": "Delete"],
        "dom.appLog":      ["tr": "Uygulama Log", "en": "App Log"],
        "dom.rename.title": ["tr": "Domaini Yeniden Adlandır", "en": "Rename Domain"],
        "dom.rename.ssl":  ["tr": "SSL sertifikası yeni ad için yeniden üretilecek (mkcert).", "en": "The SSL certificate will be regenerated for the new name (mkcert)."],
        "dom.rename.applying": ["tr": "Uygulanıyor…", "en": "Applying…"],
        "dom.loading":     ["tr": "Yükleniyor...", "en": "Loading..."],
        "dom.env.empty":   ["tr": "Henüz değişken eklenmemiş", "en": "No variables added yet"],
        "dom.env.add":     ["tr": "Değişken Ekle", "en": "Add Variable"],
        // Geçersiz anahtar start.sh'a hiç yazılmaz — kaydetmeden önce uyarılır
        "dom.env.keyInvalid": ["tr": "Geçersiz anahtar: harf veya _ ile başlamalı, yalnızca harf, rakam ve _ içerebilir (boşluk yok).",
                               "en": "Invalid key: must start with a letter or _, and may contain only letters, digits and _ (no spaces)."],
        "dom.settingsTitle": ["tr": "Domain Ayarları — %@", "en": "Domain Settings — %@"],
        "dom.ssl.enableHint": ["tr": "Kaydedilince sertifika üretilip HTTPS etkinleştirilir", "en": "A certificate is generated and HTTPS is enabled on save"],
        "dom.httpsRedirect": ["tr": "HTTP → HTTPS Yönlendirme", "en": "HTTP → HTTPS Redirect"],
        "dom.redirectOn":  ["tr": "HTTP trafiği otomatik HTTPS'e yönlendirilir", "en": "HTTP traffic is auto-redirected to HTTPS"],
        "dom.redirectOff": ["tr": "HTTP ve HTTPS portları bağımsız aktif", "en": "HTTP and HTTPS ports are independently active"],
        "dom.spa":         ["tr": "SPA yönlendirme (history fallback)", "en": "SPA routing (history fallback)"],
        "dom.spaHint":     ["tr": "Bulunamayan yollar index.html'e düşer — React/Vue Router uygulamaları için.", "en": "Unmatched paths fall back to index.html — for React/Vue Router apps."],
        "dom.php.note":    ["tr": "Kaydedildiğinde Apache yapılandırması yeniden oluşturulur.", "en": "Apache config is regenerated on save."],
        "dom.appSettings": ["tr": "Uygulama Ayarları", "en": "Application Settings"],
        "dom.startCmd":    ["tr": "Başlatma Komutu", "en": "Start Command"],
        "dom.buildRun":    ["tr": "Çalışıyor...", "en": "Running..."],
        "dom.showLog":     ["tr": "Logu Göster", "en": "Show Log"],
        "dom.env.note":    ["tr": "NODE_ENV ve PORT otomatik eklenir. Buradakiler start.sh'a yansıtılır.", "en": "NODE_ENV and PORT are added automatically. These are reflected into start.sh."],
        "dom.env.title":   ["tr": "Ortam Değişkenleri (ENV)", "en": "Environment Variables (ENV)"],
        "dom.jsonLoad":    ["tr": "JSON Yükle", "en": "Load JSON"],
        "dom.configLoad":  ["tr": "Config Yükle", "en": "Load Config"],
        "dom.configLoadHelp": ["tr": "Application Support'taki .brampp.json'u yükle", "en": "Load .brampp.json from Application Support"],
        "dom.node.settings": ["tr": "Node.js Ayarları", "en": "Node.js Settings"],
        "dom.node.note":   ["tr": "Kaydedilince start.sh yeni sürümün PATH'i ile yeniden üretilir; çalışan uygulama yeniden başlatılır.", "en": "On save, start.sh is regenerated with the new version's PATH; a running app is restarted."],
        "dom.dotnet.note": ["tr": "Kaydedilince .csproj hedef framework'ü güncellenir ve proje yeniden derlenir.", "en": "On save, the .csproj target framework is updated and the project is rebuilt."],
        "dom.python.settings": ["tr": "Python Ayarları", "en": "Python Settings"],
        "dom.runCmd":      ["tr": "Çalıştırma Komutu", "en": "Run Command"],
        "dom.proxy":       ["tr": "Proxy Ayarları", "en": "Proxy Settings"],
        "dom.filePaths":   ["tr": "Dosya Yolları", "en": "File Paths"],
        "dom.docRootPh":   ["tr": "Özel yol — boş bırakılırsa varsayılan", "en": "Custom path — leave blank for default"],
        "dom.select":      ["tr": "Seç…", "en": "Choose…"],
        "dom.resetDefault": ["tr": "Varsayılana dön", "en": "Reset to default"],
        "dom.siteFolder":  ["tr": "Site Klasörü", "en": "Site Folder"],
        "dom.logFile":     ["tr": "Log Dosyası", "en": "Log File"],
        "dom.hyConfig":    ["tr": "BRAMPP Config", "en": "BRAMPP Config"],
        "dom.selectJSON":  ["tr": "JSON Config Dosyası Seç", "en": "Select JSON Config File"],
        "dom.selectDocRoot": ["tr": "Document Root Klasörü Seç", "en": "Select Document Root Folder"],
        "dom.selectHYConfig": ["tr": "BRAMPP Config Dosyası Seç", "en": "Select BRAMPP Config File"],
        "dom.websocket":   ["tr": "WebSocket Desteği", "en": "WebSocket Support"],
        "dom.sse":         ["tr": "Proxy önbelleklemeyi kapatır — Server-Sent Events ve uzun poll için", "en": "Disables proxy buffering — for Server-Sent Events and long polling"],
        "dom.http2On":     ["tr": "HTTPS bağlantısında HTTP/2 protokolü etkinleştirilir (http2 on)", "en": "Enables HTTP/2 on HTTPS connections (http2 on)"],
        "dom.http2Nginx":  ["tr": "HTTP/2 Nginx ile kullanılabilir", "en": "HTTP/2 is available with Nginx"],
        "dom.bodySizePh":  ["tr": "Örn: 10m, 100m, 1g", "en": "e.g. 10m, 100m, 1g"],
        "dom.bodyNginx":   ["tr": "Nginx: client_max_body_size  ·  Boş bırakırsanız sunucu varsayılanı kullanılır", "en": "Nginx: client_max_body_size  ·  Server default is used if left blank"],
        "dom.bodyApache":  ["tr": "Apache: LimitRequestBody  ·  Boş bırakırsanız sunucu varsayılanı kullanılır", "en": "Apache: LimitRequestBody  ·  Server default is used if left blank"],
        "dom.logType":     ["tr": "Log Türü", "en": "Log Type"],
        "dom.openFile":    ["tr": "Dosyayı Aç", "en": "Open File"],
        "dom.logEmpty":    ["tr": "Log içeriği bulunamadı.", "en": "No log content found."],
        "dom.example":     ["tr": "Örnek: projem.test, api.test", "en": "Example: myproject.test, api.test"],
        "dom.docRootHint": ["tr": "Seçilen klasör kullanılır — mevcut dosyalar korunur, klasör boşsa örnek proje dosyası eklenir.", "en": "The selected folder is used — existing files are preserved; if empty, a sample project file is added."],
        "dom.appPortHint": ["tr": "Nginx bu porta yönlendirme yapar", "en": "Nginx proxies to this port"],
        "dom.python.venvHint": ["tr": "Öneri: Projeyi oluşturduktan sonra proje dizininde 'python -m venv venv' çalıştırın.", "en": "Tip: After creating the project, run 'python -m venv venv' in the project directory."],
        "dom.nginxRec":    ["tr": "HTTP :8080  ·  HTTPS :8443  —  Node.js ve .NET için önerilir", "en": "HTTP :8080  ·  HTTPS :8443  —  recommended for Node.js and .NET"],
        "dom.createSSL":   ["tr": "SSL Sertifikası Oluştur", "en": "Create SSL Certificate"],
        "dom.redirectOn2": ["tr": "HTTP trafiği otomatik olarak HTTPS'e yönlendirilir", "en": "HTTP traffic is automatically redirected to HTTPS"],
        "dom.sslWarn":     ["tr": "Tarayıcınızda SSL uyarısı göreceksiniz. CA'yı 'Servisler' sekmesinden kurabilirsiniz.", "en": "You'll see an SSL warning in your browser. Install the CA from the 'Services' tab."],
        "dom.creating":    ["tr": "Oluşturuluyor...", "en": "Creating..."],
        "dom.staticNoVer": ["tr": "Static site için versiyon gerekmez", "en": "No version needed for static sites"],
        "dom.configLoaded": ["tr": "Config Yüklendi", "en": "Config Loaded"],
        "dom.startStop.start": ["tr": "Başlat", "en": "Start"],
        "dom.startStop.stop":  ["tr": "Durdur", "en": "Stop"],
        "dom.rename.desc": ["tr": "'%@' domaininin adını değiştirir. Vhost, SSL sertifikası, hosts girişi ve (varsayılan konumdaysa) site klasörü yeni ada taşınır. Çalışan uygulama yeni adla yeniden başlatılır.", "en": "Renames the domain '%@'. The vhost, SSL certificate, hosts entry and (if in the default location) the site folder are moved to the new name. A running app is restarted with the new name."],
        "dom.venvNotFound": ["tr": "venv/, .venv/ veya env/ bulunamadı — brew python kullanılacak", "en": "venv/, .venv/ or env/ not found — brew python will be used"],
        "dom.venvAutoDetect": ["tr": "venv/, .venv/ veya env/ dizini proje oluşturulunca otomatik tespit edilir", "en": "venv/, .venv/ or env/ is auto-detected once the project is created"],
        "dom.docRootDefaultEdit": ["tr": "Varsayılan: %@  ·  Kaydedilince VHost config yeniden oluşturulur.", "en": "Default: %@  ·  VHost config is regenerated on save."],
        "dom.grpcNginx":   ["tr": "gRPC Nginx ile kullanılabilir", "en": "gRPC is available with Nginx"],
        "dom.portTemplate": ["tr": "{PORT} otomatik olarak port numarasıyla değiştirilir — portu sonradan değiştirseniz bile komut güncel kalır.", "en": "{PORT} is automatically replaced with the port number — the command stays correct even if you change the port later."],
        "dom.createSSLTitle": ["tr": "SSL Sertifikası Oluştur", "en": "Create SSL Certificate"],
        "dom.sslUsedHint": ["tr": "mkcert sertifikası kullanılır; kapatılırsa yalnızca HTTP", "en": "mkcert certificate is used; if disabled, HTTP only"],
        "dom.jsonLoadHelp": ["tr": ".brampp.json veya başka bir JSON dosyasını yükle", "en": "Load .brampp.json or another JSON file"],
        "dom.docRootDefault": ["tr": "Varsayılan: %@  ·  Kaydedilince VHost config yeniden oluşturulur.", "en": "Default: %@  ·  VHost config is regenerated on save."],
        "dom.loadedOk":    ["tr": "%@ başarıyla yüklendi. Kaydetmek için 'Kaydet' butonuna basın.", "en": "%@ loaded successfully. Press 'Save' to apply."],
        "dom.selectJSONConfig": ["tr": "JSON Config Dosyası Seç", "en": "Select JSON Config File"],
        "dom.loadFailed":  ["tr": "Config yüklenemedi: %@", "en": "Failed to load config: %@"],
        "dom.jsonLoadFailed": ["tr": "JSON yüklenemedi: %@", "en": "Failed to load JSON: %@"],
        "dom.buildRunHint": ["tr": "Varsayılan: %@  ·  Domain oluşturulduktan sonra ayarlardan çalıştırın.", "en": "Default: %@  ·  Run from settings after creating the domain."],

        // ── Kurulum Sihirbazı ──
        "wiz.title":       ["tr": "Kurulum Sihirbazı", "en": "Setup Wizard"],
        "wiz.step1":       ["tr": "1/4 — Hoş Geldiniz", "en": "1/4 — Welcome"],
        "wiz.step2":       ["tr": "2/4 — Paket Kontrolü ve Kurulum", "en": "2/4 — Package Check & Install"],
        "wiz.step3":       ["tr": "3/4 — Yapılandırma", "en": "3/4 — Configuration"],
        "wiz.step4":       ["tr": "4/4 — Tamamlandı", "en": "4/4 — Done"],
        "wiz.welcome":     ["tr": "Hoş Geldiniz!", "en": "Welcome!"],
        "wiz.welcomeDesc": ["tr": "Bu sihirbaz local development ortamınızı kurmanıza yardımcı olacak.", "en": "This wizard will help you set up your local development environment."],
        "wiz.pkgTitle":    ["tr": "Paket Kontrolü ve Kurulum", "en": "Package Check & Install"],
        "wiz.pkgDesc":     ["tr": "Her paketin durumunu kontrol edip, eksik olanları kurabilirsiniz.", "en": "Check the status of each package and install any that are missing."],
        "wiz.notInstalled": ["tr": "Kurulu değil", "en": "Not installed"],
        "wiz.configTitle": ["tr": "Yapılandırma", "en": "Configuration"],
        "wiz.configDesc":  ["tr": "Aşağıdaki başlıkları açarak hangi adımların tamamlandığını ve hangi yapılandırmaların eksik olduğunu kontrol edin.", "en": "Expand the sections below to check which steps are complete and which configurations are missing."],
        "wiz.optional":    ["tr": "İsteğe bağlı", "en": "Optional"],
        "wiz.done":        ["tr": "Tamamlandı", "en": "Done"],
        "wiz.waitConsole": ["tr": "Konsol çıktısı bekleniyor...", "en": "Waiting for console output..."],
        "wiz.complete":    ["tr": "Kurulum Tamamlandı!", "en": "Setup Complete!"],
        "wiz.nextSteps":   ["tr": "Sonraki Adımlar:", "en": "Next Steps:"],
        "wiz.startDev":    ["tr": "Geliştirmeye başlayın!", "en": "Start developing!"],
        "wiz.hideCompleted": ["tr": "Tamamlananları gizle", "en": "Hide completed"],
        "wiz.showCompleted": ["tr": "Tamamlananları göster", "en": "Show completed"],
        "wiz.configure":   ["tr": "Yapılandır", "en": "Configure"],
        "wiz.back":        ["tr": "Geri", "en": "Back"],
        "wiz.next":        ["tr": "Devam", "en": "Continue"],
        "wiz.finish":      ["tr": "Bitir", "en": "Finish"],
        "wiz.console":     ["tr": "Konsol", "en": "Console"],
        "wiz.installing":  ["tr": "• Kuruluyor", "en": "• Installing"],
        "wiz.defaultPHP":  ["tr": "Varsayılan PHP sürümü", "en": "Default PHP version"],
        "wiz.dbOptional":  ["tr": "Veritabanı sunucusu (isteğe bağlı)", "en": "Database server (optional)"],
        "wiz.webDbOptional": ["tr": "Web veritabanı yönetim aracı (isteğe bağlı)", "en": "Web database management tool (optional)"],
        // Config grup başlıkları
        "wiz.g.apache":    ["tr": "Apache Yapılandırması", "en": "Apache Configuration"],
        "wiz.g.apache.sub": ["tr": "HTTP 80, include ve modül ayarları", "en": "HTTP 80, includes and module settings"],
        "wiz.g.php":       ["tr": "PHP 8.3 Yapılandırması", "en": "PHP 8.3 Configuration"],
        "wiz.g.php.sub":   ["tr": "PHP-FPM portu ve çalışma ayarları", "en": "PHP-FPM port and runtime settings"],
        "wiz.g.mkcert":    ["tr": "mkcert Durumu", "en": "mkcert Status"],
        "wiz.g.mkcert.sub": ["tr": "CA kurulumu ve güven kontrolleri", "en": "CA installation and trust checks"],
        "wiz.g.localhost": ["tr": "localhost Kurulumu", "en": "localhost Setup"],
        "wiz.g.localhost.sub": ["tr": "Yerel yayın, sertifika ve HTTPS tanımı", "en": "Local serving, certificate and HTTPS definition"],
        "wiz.g.mariadb":   ["tr": "MariaDB Yapılandırması", "en": "MariaDB Configuration"],
        "wiz.g.mariadb.sub": ["tr": "İlk çalıştırma + root@localhost TCP erişimi", "en": "First run + root@localhost TCP access"],
        "wiz.g.pma":       ["tr": "phpMyAdmin Yapılandırması", "en": "phpMyAdmin Configuration"],
        "wiz.g.pma.sub":   ["tr": "Apache include ve config.inc.php", "en": "Apache include and config.inc.php"],
        "wiz.g.nginx":     ["tr": "Nginx Yapılandırması", "en": "Nginx Configuration"],
        "wiz.g.nginx.sub": ["tr": "nginx.conf sıfırdan yaz — sites-available/ ve localhost :8080/:8443", "en": "Rewrite nginx.conf from scratch — sites-available/ and localhost :8080/:8443"],
        "wiz.g.nginx2":     ["tr": "Nginx localhost SSL", "en": "Nginx localhost SSL"],
        "wiz.g.nginx2.sub": ["tr": "nginx.conf'a HTTPS :8443 bloğu ekle — localhost SSL sertifikası gerekli", "en": "Add an HTTPS :8443 block to nginx.conf — localhost SSL certificate required"],

        // Karşılama özellik satırları
        "wiz.feat.langs":  ["tr": "PHP, Node.js, Python, .NET desteği", "en": "PHP, Node.js, Python, .NET support"],
        "wiz.feat.ssl":    ["tr": "Otomatik SSL sertifikaları (mkcert)", "en": "Automatic SSL certificates (mkcert)"],
        "wiz.feat.mgmt":   ["tr": "Apache, MariaDB, Redis yönetimi", "en": "Apache, MariaDB, Redis management"],

        // Paket açıklamaları
        "wiz.pkgd.homebrew": ["tr": "macOS paket yöneticisi", "en": "macOS package manager"],
        "wiz.pkgd.apache":   ["tr": "Web sunucusu", "en": "Web server"],
        "wiz.pkgd.mkcert":   ["tr": "Local SSL sertifika aracı", "en": "Local SSL certificate tool"],

        // Paket durumu / rozetler
        "wiz.checking":    ["tr": "Paketler kontrol ediliyor...", "en": "Checking packages..."],
        "wiz.recheck":     ["tr": "Yeniden Kontrol Et", "en": "Re-check"],
        "wiz.required":    ["tr": "Zorunlu", "en": "Required"],
        "wiz.install":     ["tr": "Kur", "en": "Install"],
        "wiz.st.checking": ["tr": "Kontrol...", "en": "Checking..."],
        "wiz.st.installed": ["tr": "Kurulu ✓", "en": "Installed ✓"],
        "wiz.st.notInstalled": ["tr": "Kurulu değil", "en": "Not installed"],
        "wiz.st.installing": ["tr": "Kuruluyor...", "en": "Installing..."],
        "wiz.st.error":    ["tr": "Hata", "en": "Error"],
        "wiz.checkingShort": ["tr": "Kontrol ediliyor...", "en": "Checking..."],
        "wiz.homebrewTitle": ["tr": "Homebrew Kurulumu", "en": "Homebrew Installation"],

        // Sonraki adımlar
        "wiz.next1":       ["tr": "localhost ve phpMyAdmin erişimini test edin", "en": "Test localhost and phpMyAdmin access"],
        "wiz.next2":       ["tr": "İlk domain'inizi ekleyin", "en": "Add your first domain"],

        // Yapılandırma kontrol maddeleri (başlıklar)
        "wiz.i.httpd-conf":     ["tr": "httpd.conf erişilebilir", "en": "httpd.conf accessible"],
        "wiz.i.listen-80":      ["tr": "Apache HTTP portu 80", "en": "Apache HTTP port 80"],
        "wiz.i.server-name":    ["tr": "ServerName localhost:80 olarak ayarlı", "en": "ServerName set to localhost:80"],
        "wiz.i.server-admin":   ["tr": "ServerAdmin admin@localhost olarak ayarlı", "en": "ServerAdmin set to admin@localhost"],
        "wiz.i.include-vhosts": ["tr": "VirtualHosts include eklendi", "en": "VirtualHosts include added"],
        "wiz.i.module-ssl":     ["tr": "SSL modülü aktif", "en": "SSL module enabled"],
        "wiz.i.module-http2":   ["tr": "HTTP/2 modülü aktif", "en": "HTTP/2 module enabled"],
        "wiz.i.module-proxy":   ["tr": "Proxy modülü aktif", "en": "Proxy module enabled"],
        "wiz.i.module-proxy-fcgi": ["tr": "PHP-FPM modülü aktif", "en": "PHP-FPM module enabled"],
        "wiz.i.module-rewrite": ["tr": "Rewrite modülü aktif", "en": "Rewrite module enabled"],
        "wiz.i.module-vhost-alias": ["tr": "VHost Alias modülü aktif", "en": "VHost Alias module enabled"],
        "wiz.i.module-proxy-http": ["tr": "HTTP proxy modülü aktif", "en": "HTTP proxy module enabled"],
        "wiz.i.module-proxy-wstunnel": ["tr": "WebSocket modülü aktif", "en": "WebSocket module enabled"],
        "wiz.i.module-headers": ["tr": "Headers modülü aktif", "en": "Headers module enabled"],
        "wiz.i.module-socache": ["tr": "SSL cache modülü aktif", "en": "SSL cache module enabled"],
        "wiz.i.php83-www-conf": ["tr": "PHP 8.3 www.conf erişilebilir", "en": "PHP 8.3 www.conf accessible"],
        "wiz.i.php83-listen":   ["tr": "PHP-FPM portu 9083 olarak ayarlı", "en": "PHP-FPM port set to 9083"],
        "wiz.i.php83-user":     ["tr": "PHP-FPM kullanıcı ayarı mevcut", "en": "PHP-FPM user settings present"],
        "wiz.i.localhost-files": ["tr": "localhost yayın klasörü hazır", "en": "localhost web root ready"],
        "wiz.i.localhost-main":  ["tr": "Ana DocumentRoot, Directory, DirectoryIndex ve PHP 8.3 eşlemesi hazır", "en": "Main DocumentRoot, Directory, DirectoryIndex and PHP 8.3 mapping ready"],
        "wiz.i.localhost-ssl":   ["tr": "mkcert ile localhost sertifikası üretildi", "en": "localhost certificate generated with mkcert"],
        "wiz.i.localhost-https": ["tr": "localhost için HTTPS tanımı hazır", "en": "HTTPS definition ready for localhost"],
        "wiz.i.mkcert-installed": ["tr": "mkcert kurulu", "en": "mkcert installed"],
        "wiz.i.mkcert-ca":       ["tr": "CA oluşturulmuş", "en": "CA created"],
        "wiz.i.mkcert-trusted":  ["tr": "CA güvenilir", "en": "CA trusted"],
        "wiz.i.mariadb-running": ["tr": "MariaDB çalıştırıldı", "en": "MariaDB started"],
        "wiz.i.mariadb-root-tcp": ["tr": "root TCP erişimi açık", "en": "root TCP access open"],
        "wiz.i.mariadb-root-nopass": ["tr": "root şifresi boş", "en": "root password empty"],
        "wiz.i.mariadb-root-native": ["tr": "mysql_native_password auth", "en": "mysql_native_password auth"],
        "wiz.i.mariadb-test-db": ["tr": "test veritabanı kaldırıldı", "en": "test database removed"],
        "wiz.i.pma-conf-file":   ["tr": "extra/phpmyadmin.conf oluşturuldu", "en": "extra/phpmyadmin.conf created"],
        "wiz.i.pma-httpd-include": ["tr": "httpd.conf IncludeOptional eklendi", "en": "httpd.conf IncludeOptional added"],
        "wiz.i.pma-config-file": ["tr": "config.inc.php yapılandırıldı", "en": "config.inc.php configured"],
        "wiz.i.nginx-conf":      ["tr": "nginx.conf erişilebilir", "en": "nginx.conf accessible"],
        "wiz.i.nginx-sites-dir": ["tr": "sites-available/ dizini mevcut", "en": "sites-available/ directory exists"],
        "wiz.i.nginx-rewritten": ["tr": "nginx.conf yeniden yazıldı", "en": "nginx.conf rewritten"],
        "wiz.i.nginx-localhost-http": ["tr": "localhost HTTP :8080 bloğu tanımlı", "en": "localhost HTTP :8080 block defined"],
        "wiz.i.nginx-localhost-cert": ["tr": "localhost SSL sertifikası mevcut", "en": "localhost SSL certificate exists"],
        "wiz.i.nginx-localhost-https": ["tr": "localhost HTTPS :8443 bloğu tanımlı", "en": "localhost HTTPS :8443 block defined"],
        "db.restore.warn": ["tr": "⚠️ Hedef veritabanı yoksa oluşturulur; varsa döküm MEVCUT verinin üzerine uygulanır.", "en": "⚠️ The target database is created if missing; if it exists, the dump is applied over EXISTING data."],

        // ═══════════════════════════════════════════════════════════════════
        //  KONSOL LOG ANAHTARLARI — log.backup.*
        //  Bunların ASIL yeri Core/L10nLog.swift'teki log.backup.* bölümüdür.
        //  `L10n.logEntry(for:)` arama zincirinin SONUNDA bu katalogu da taradığı
        //  için buradan da çözülürler; o dosya bu değişikliğe kapalı olduğundan
        //  geçici olarak burada duruyorlar. Taşınırken AYNI ANAHTARIN iki
        //  katalogda birden bulunmamasına dikkat: arama sırası yanlış metni seçer.
        // ═══════════════════════════════════════════════════════════════════

        // Geri yükleme öncesi güvenlik yedeği (%@ = yedeğin tarih damgası)
        "log.backup.preRestoreSaved":
            ["tr": "Geri yükleme öncesi mevcut durum yedeklendi — geri dönmek isterseniz: %@",
             "en": "Current state backed up before restoring — to come back, use: %@"],
        "log.backup.preRestoreFailed":
            ["tr": "⚠️ Geri yükleme öncesi güvenlik yedeği ALINAMADI — bu işlem geri alınamayabilir",
             "en": "⚠️ Could NOT create a safety backup before restoring — this operation may be irreversible"],

        // Yetim vhost/nginx yapılandırması temizliği
        "log.backup.orphanSkipped":
            ["tr": "Alan adı listesi okunamadı — yetim vhost temizliği atlandı",
             "en": "Could not read the domain list — orphaned vhost cleanup skipped"],
        // %@1 = tür etiketi (@log.backup.label*), %@2 = dosya adı
        "log.backup.orphanRemoved":
            ["tr": "Yetim %@ yapılandırması kaldırıldı: %@",
             "en": "Removed orphaned %@ config: %@"],
        "log.backup.orphanRemoveFailed":
            ["tr": "Yetim yapılandırma kaldırılamadı: %@",
             "en": "Could not remove orphaned config: %@"],
        "log.backup.orphanNone":
            ["tr": "Yetim vhost bulunamadı — yapılandırmalar alan adı listesiyle uyumlu",
             "en": "No orphaned vhosts found — configs match the domain list"],
        // %@ = kaldırılan dosya sayısı
        "log.backup.orphanReloadHint":
            ["tr": "%@ yetim yapılandırma kaldırıldı — değişikliğin geçerli olması için Apache/Nginx'i yeniden başlatın",
             "en": "Removed %@ orphaned config(s) — restart Apache/Nginx for this to take effect"],

        // Silme
        "log.backup.trashed":
            ["tr": "Yedek Çöp Kutusu'na taşındı: %@",
             "en": "Backup moved to the Trash: %@"],
        // %@1 = yedek adı, %@2 = hata açıklaması
        "log.backup.deleteFailed":
            ["tr": "Yedek silinemedi: %@ — %@",
             "en": "Could not delete backup: %@ — %@"],

        // İçe aktarma güvenliği
        // %@ = çözülemeyen kayıt sayısı
        "log.backup.importInvalidRecords":
            ["tr": "İçe aktarma iptal edildi: dosyadaki %@ kayıt çözülemedi — mevcut alan adları korundu",
             "en": "Import cancelled: %@ record(s) in the file could not be decoded — your existing domains were kept"],
        "log.backup.importEmpty":
            ["tr": "İçe aktarma iptal edildi: dosyada hiç alan adı yok — mevcut alan adları korundu",
             "en": "Import cancelled: the file contains no domains — your existing domains were kept"],
        "log.backup.importCancelled":
            ["tr": "İçe aktarma kullanıcı tarafından iptal edildi",
             "en": "Import cancelled by the user"],
        // %@ = güvenlik yedeğinin dosya adı
        "log.backup.importSafetyBackup":
            ["tr": "İçe aktarmadan önce mevcut liste yedeklendi: %@",
             "en": "Current list backed up before importing: %@"],
        "log.backup.importSafetyFailed":
            ["tr": "İçe aktarma iptal edildi: mevcut domains.json yedeklenemedi — üzerine yazılmadı",
             "en": "Import cancelled: could not back up the current domains.json — nothing was overwritten"],
        // %@ = hedef dosya yolu
        "log.backup.importWriteFailed":
            ["tr": "İçe aktarma başarısız: dosya yazılamadı — %@",
             "en": "Import failed: could not write the file — %@"],
    ]
}
