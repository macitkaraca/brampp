import Foundation

/// Nginx ana yapılandırmasını yöneten yardımcı.
/// nginx.conf'u sıfırdan yazar — localhost bloğu ve sites-available include içinde.
enum NginxConfigManager {

    // MARK: - SSL Hazırlık Kontrolü

    /// localhost SSL çifti (cert **ve** key) diskte mevcut mu?
    ///
    /// Yalnızca `cert.pem`e bakmak yetmez: key eksikken üretilen `ssl_certificate_key`
    /// satırı var olmayan bir dosyayı gösterir ve nginx HİÇ başlamaz. HTTPS bloğu üreten
    /// tüm çağrı yerleri bu tek yardımcıyı kullanır.
    static var localhostSSLReady: Bool {
        FileHelper.exists("\(PathConfig.localhostSSLDir)/cert.pem")
            && FileHelper.exists("\(PathConfig.localhostSSLDir)/key.pem")
    }

    // MARK: - Durum Kontrolü

    /// nginx.conf içinde `sites-available` include varsa `true` döner.
    /// Dosyanın BRAMPP tarafından yeniden yazıldığını gösterir.
    static var isMainConfigRewritten: Bool {
        guard let content = FileHelper.readString(PathConfig.nginxConf) else { return false }
        return content.contains("sites-available")
    }

    /// nginx.conf içinde localhost HTTP bloğu var mı?
    ///
    /// Port SABİT ARANMAZ: kullanıcı 8080'i değiştirdiğinde (Servisler → Nginx Portları)
    /// blok yerinde durduğu hâlde "yapılandırılmamış" görünüyor ve sihirbaz config'i
    /// gereksizce yeniden yazıyordu. BRAMPP'ın ürettiği localhost bloğu her zaman
    /// `default_server` bayrağı taşır — yapısal imza budur.
    static var isLocalhostHTTPConfigured: Bool {
        hasListenDirective(ssl: false)
    }

    /// nginx.conf içinde localhost HTTPS bloğu (ssl + default_server) var mı?
    static var isLocalhostHTTPSConfigured: Bool {
        hasListenDirective(ssl: true)
    }

    /// nginx.conf'ta `listen <port> [ssl] default_server;` satırı arar (porttan bağımsız).
    private static func hasListenDirective(ssl: Bool) -> Bool {
        guard let content = FileHelper.readString(PathConfig.nginxConf) else { return false }
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), t.hasPrefix("listen") else { continue }
            // Satır içi yorumu at, direktifi ';'ye kadar al
            let noComment = t.components(separatedBy: "#").first ?? t
            let directive = noComment.components(separatedBy: ";").first ?? noComment
            let parts = directive.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2, parts.contains("default_server") else { continue }
            if parts.dropFirst().contains("ssl") == ssl { return true }
        }
        return false
    }

    /// nginx.conf içinde Adminer location bloğu var mı?
    static var isAdminerConfigured: Bool {
        guard let content = FileHelper.readString(PathConfig.nginxConf) else { return false }
        return content.contains("location /adminer")
    }

    // MARK: - Ana Config: Sıfırdan Yaz

    /// nginx.conf'u tamamen yeniden yazar.
    /// localhost HTTP + phpMyAdmin her zaman eklenir.
    /// localhost HTTPS yalnızca `sslAvailable` true ise eklenir.
    /// Virtual host'lar için `sites-available/*.conf` include eklenir.
    ///
    /// Portlar MEVCUT nginx.conf'tan okunur (varsayılan 8080/8443) — kullanıcının port
    /// ayarı bu yeniden yazımda kaybolmaz. Üzerine yazmadan önce zaman damgalı yedek alınır.
    ///
    /// - Parameter sslAvailable: localhost SSL çifti (cert **ve** key) mevcutsa `true`
    ///   — `localhostSSLReady` ile hesaplanmalıdır
    /// - Returns: Dosya yazma başarılıysa `true`
    @discardableResult
    static func rewriteMainConfig(sslAvailable: Bool, adminerAvailable: Bool? = nil) -> Bool {
        // nil → otomatik tespit: diğer çağrı yerleri (kurulum sihirbazı, SSL yenileme vb.)
        // parametreyi bilmese de kurulu araçların blokları KORUNUR (yeniden yazımda kaybolmaz)
        let hasAdminer  = adminerAvailable  ?? PathConfig.isAdminerInstalled

        // Portlar YAZIMDAN ÖNCE okunmalı — buildMainConfig mevcut nginx.conf'tan okur.
        let httpPort  = WebServerPorts.nginxHTTP()
        let httpsPort = WebServerPorts.nginxHTTPS()

        let config = buildMainConfig(sslAvailable: sslAvailable,
                                     adminerAvailable: hasAdminer,
                                     httpPort: httpPort,
                                     httpsPort: httpsPort)

        // Bu fonksiyon rutin işlemlerde de (Adminer kur-kaldır, varsayılan PHP
        // değişimi) çalışır ve dosyayı SIFIRDAN yazar. Kullanıcının elle eklediği her şey
        // uçar; o yüzden YEDEK ALINAMADIYSA YAZILMAZ. Eskiden yedeğin sonucu atılıyor ve
        // yazım yine de yapılıyordu — yani korumanın başarısız olduğu durumda tam olarak
        // korumak istediği şey kayboluyordu.
        let previous = FileHelper.readString(PathConfig.nginxConf)
        guard backupMainConfig() else { return false }

        guard FileHelper.write(config, to: PathConfig.nginxConf) else { return false }

        // YAZIM BAŞARILI ≠ NGINX KABUL ETTİ. Doğrulama yoktu: bozuk bir nginx.conf
        // yalnızca bu işlemi değil, sonraki her başlatmayı da düşürür ve kullanıcı
        // hangi satırın bozduğunu elle arar. Apache tarafında bu koruma zaten vardı.
        let test = Shell.bash("\(Shell.brewPrefix)/bin/nginx -t 2>&1")
        if Diagnostics.configVerdict(server: "Nginx", output: test.output,
                                     exitOK: test.isSuccess).level == .fail {
            // Geri dönülecek bir içerik varsa dön. Yoksa (dosya yeni yaratılıyordu)
            // bozuk hâli bırakmaktansa silmek daha az zarar verir: nginx eksik
            // dosyayla açık bir hata verir, bozuk dosyayla belirsiz bir hata.
            if let previous { _ = FileHelper.write(previous, to: PathConfig.nginxConf) }
            else { FileHelper.remove(PathConfig.nginxConf) }
            return false
        }
        return true
    }

    // MARK: - Yedekleme

    /// Üzerine yazmadan önce nginx.conf'un zaman damgalı kopyasını alır
    /// (`nginx.conf.brampp-bak-YYYYMMdd-HHmmss`). En yeni `keepBackups` kopya saklanır.
    private static let backupPrefix = "nginx.conf.brampp-bak-"
    private static let keepBackups  = 5

    @discardableResult
    private static func backupMainConfig() -> Bool {
        // Dosya henüz yoksa yedeklenecek bir şey de yok — bu bir BAŞARISIZLIK DEĞİL.
        guard FileHelper.exists(PathConfig.nginxConf) else { return true }

        let fmt = DateFormatter()
        fmt.locale     = Locale(identifier: "en_US_POSIX")
        fmt.timeZone   = TimeZone.current
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = fmt.string(from: Date())

        let target = "\(PathConfig.nginxBase)/\(backupPrefix)\(stamp)"
        // Aynı saniyede iki yazım olursa üzerine yazılmasın diye var olanı koru
        guard !FileHelper.exists(target) else { return true }
        guard FileHelper.copy(from: PathConfig.nginxConf, to: target) else { return false }

        pruneBackups()
        return true
    }

    /// Yedekler sınırsız birikmesin — ad zaman damgası içerdiğinden alfabetik sıralama
    /// kronolojik sıralamayla aynıdır.
    /// Hangi yedekler silinecek? Saf karar — dosya sistemine dokunmaz.
    ///
    /// **EN ESKİSİ ASLA SİLİNMEZ.** O yedek, kullanıcının BRAMPP'a hiç dokunmamış
    /// `nginx.conf`u: geri dönülmek istendiğinde asıl aranan dosya odur. Ad zaman
    /// damgası taşıdığından alfabetik sıralama kronolojiktir ve eski kod
    /// `dropLast(keep)` yapıyordu — yani en eskiden başlayarak siliyordu. Altı rutin
    /// işlemden (Adminer kur-kaldır, varsayılan PHP değişimi…) sonra o dosya gidiyordu.
    static func backupsToPrune(_ sortedNames: [String], keep: Int) -> [String] {
        guard sortedNames.count > keep else { return [] }
        // İlki korunur; kalanın en yenileri `keep` kadar tutulur.
        return Array(sortedNames.dropFirst().dropLast(keep))
    }

    private static func pruneBackups() {
        let all = FileHelper.contentsOfDirectory(PathConfig.nginxBase)
            .filter { $0.hasPrefix(backupPrefix) }
            .sorted()
        for name in backupsToPrune(all, keep: keepBackups) {
            FileHelper.remove("\(PathConfig.nginxBase)/\(name)")
        }
    }

    // MARK: - sites-available Dizini

    /// `sites-available/` dizinini oluşturur. Varsa sessizce geçer.
    @discardableResult
    static func createSitesAvailableDir() -> Bool {
        FileHelper.createDirectory(PathConfig.nginxSitesAvailableDir)
    }

    // MARK: - Config Builder

    /// - Parameters:
    ///   - httpPort/httpsPort: localhost bloklarının dinleyeceği portlar. Varsayılan `nil`
    ///     → mevcut nginx.conf'tan okunur; böylece rutin yeniden yazımlar kullanıcının
    ///     (ya da uygulamanın Nginx Portları ekranının) ayarını SIFIRLAMAZ.
    static func buildMainConfig(sslAvailable: Bool,
                                adminerAvailable: Bool = false,
                                httpPort: Int? = nil,
                                httpsPort: Int? = nil) -> String {
        let httpPort  = httpPort  ?? WebServerPorts.nginxHTTP()
        let httpsPort = httpsPort ?? WebServerPorts.nginxHTTPS()
        let root     = PathConfig.localhostDir
        // Varsayılan PHP sürümünün portu — sabit 8.3 yerine ayarlardan okunur
        let phpPort  = AppSettings.load().defaultPHPVersion.port
        let pmaDir   = PathConfig.phpmyadminDir
        let logs     = PathConfig.nginxLogs
        let certPath = "\(PathConfig.localhostSSLDir)/cert.pem"
        let keyPath  = "\(PathConfig.localhostSSLDir)/key.pem"

        let adminerBlock = adminerAvailable ? """

        # ─── Adminer (tek dosyalı DB yöneticisi — MySQL + PostgreSQL) ─────
        location /adminer {
            alias \(PathConfig.adminerDir);
            index index.php;
            location ~ \\.php$ {
                fastcgi_pass   127.0.0.1:\(phpPort);
                fastcgi_index  index.php;
                fastcgi_param  SCRIPT_FILENAME $request_filename;
                include        fastcgi_params;
            }
        }
""" : ""


        let httpsBlock = sslAvailable ? """

    # ─── localhost HTTPS (\(httpsPort)) ──────────────────────────────────────
    server {
        listen      \(httpsPort) ssl default_server;
        server_name localhost;
        root        "\(root)";

        ssl_certificate     "\(certPath)";
        ssl_certificate_key "\(keyPath)";

        index index.php index.html;

        location / {
            try_files $uri $uri/ /index.php?$query_string;
        }

        location ~ \\.php$ {
            fastcgi_pass   127.0.0.1:\(phpPort);
            fastcgi_index  index.php;
            fastcgi_param  SCRIPT_FILENAME $document_root$fastcgi_script_name;
            include        fastcgi_params;
        }

        location /phpmyadmin {
            alias \(pmaDir);
            index index.php;
            location ~ \\.php$ {
                fastcgi_pass   127.0.0.1:\(phpPort);
                fastcgi_index  index.php;
                fastcgi_param  SCRIPT_FILENAME $request_filename;
                include        fastcgi_params;
            }
        }
\(adminerBlock)
        access_log "\(logs)/localhost-ssl-access.log";
        error_log  "\(logs)/localhost-ssl-error.log";
    }
""" : ""

        return """
worker_processes  1;

events {
    worker_connections  1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;

    # ─── localhost HTTP (\(httpPort)) ───────────────────────────────────────
    # default_server: Host eşleşmeyen istekler domain bloklarına düşmesin
    server {
        listen      \(httpPort) default_server;
        server_name localhost;
        root        "\(root)";

        index index.php index.html;

        location / {
            try_files $uri $uri/ /index.php?$query_string;
        }

        location ~ \\.php$ {
            fastcgi_pass   127.0.0.1:\(phpPort);
            fastcgi_index  index.php;
            fastcgi_param  SCRIPT_FILENAME $document_root$fastcgi_script_name;
            include        fastcgi_params;
        }

        location /phpmyadmin {
            alias \(pmaDir);
            index index.php;
            location ~ \\.php$ {
                fastcgi_pass   127.0.0.1:\(phpPort);
                fastcgi_index  index.php;
                fastcgi_param  SCRIPT_FILENAME $request_filename;
                include        fastcgi_params;
            }
        }
\(adminerBlock)
        access_log "\(logs)/localhost-access.log";
        error_log  "\(logs)/localhost-error.log";
    }
\(httpsBlock)
    # ─── Virtual Hosts ───────────────────────────────────────────────────────
    include sites-available/*.conf;
}
"""
    }
}
