import Foundation

/// VHost / Server-block ve örnek dosya şablonları
struct VHostTemplates {

    // MARK: - Dispatcher

    static func generate(for domain: Domain) -> String {
        switch domain.webServer {
        case .apache: return generateApache(for: domain)
        case .nginx:  return generateNginx(for: domain)
        }
    }

    // MARK: - Apache Dispatcher

    private static func generateApache(for domain: Domain) -> String {
        switch domain.platform {
        case .php:
            return apachePHP(domain: domain)
        case .nodejs:
            return apacheProxy(domain: domain, port: domain.port ?? 3001)
        case .python:
            return apacheProxy(domain: domain, port: domain.port ?? 8001)
        case .dotnet:
            return apacheProxy(domain: domain, port: domain.port ?? 5001)
        case .static_:
            return apacheStatic(domain: domain)
        }
    }

    // MARK: - Nginx Dispatcher

    private static func generateNginx(for domain: Domain) -> String {
        switch domain.platform {
        case .php:
            return nginxPHP(domain: domain)
        case .nodejs:
            return nginxProxy(domain: domain, port: domain.port ?? 3001)
        case .python:
            return nginxProxy(domain: domain, port: domain.port ?? 8001)
        case .dotnet:
            return nginxProxy(domain: domain, port: domain.port ?? 5001)
        case .static_:
            return nginxStatic(domain: domain)
        }
    }

    // MARK: - Apache: PHP VHost

    private static func apachePHP(domain: Domain) -> String {
        let port     = domain.phpVersion?.port ?? 9083
        let certPath = sslCertPath(for: domain.name)
        let keyPath  = sslKeyPath(for: domain.name)
        let redirect = domain.redirectHTTPToHTTPS && domain.sslEnabled
        // Apache'nin GÜNCEL portları — kullanıcı portu değiştirdiyse vhost da uymalı
        let httpPort    = WebServerPorts.apacheHTTP()
        let httpsPort   = WebServerPorts.apacheHTTPS()
        let httpsSuffix = WebServerPorts.portSuffix(httpsPort, https: true)

        let httpBlock: String
        if redirect {
            httpBlock = """
            # HTTP → HTTPS Yönlendirme
            <VirtualHost *:\(httpPort)>
                ServerName \(domain.name)
                Redirect permanent / https://\(domain.name)\(httpsSuffix)/
            </VirtualHost>
            """
        } else {
            httpBlock = """
            # HTTP (\(httpPort)) — Yönlendirme yok, içerik servis edilir
            <VirtualHost *:\(httpPort)>
                ServerName \(domain.name)
                DocumentRoot "\(domain.documentRoot)"

                <FilesMatch \\.php$>
                    SetHandler "proxy:fcgi://127.0.0.1:\(port)"
                </FilesMatch>

                <Directory "\(domain.documentRoot)">
                    Options Indexes FollowSymLinks
                    AllowOverride All
                    Require all granted
                    DirectoryIndex index.php index.html
                </Directory>

                ErrorLog "\(PathConfig.httpdLogs)/\(domain.name)-error.log"
                CustomLog "\(PathConfig.httpdLogs)/\(domain.name)-access.log" combined
            </VirtualHost>
            """
        }

        // HTTPS bloğu YALNIZCA SSL açıksa üretilir — aksi halde var olmayan sertifika
        // yolu Apache configtest'i çökertir ve TÜM domainler erişilemez olur.
        let httpsBlock = domain.sslEnabled ? """


        # HTTPS
        <VirtualHost *:\(httpsPort)>
            ServerName \(domain.name)
            DocumentRoot "\(domain.documentRoot)"

            # SSL
            SSLEngine on
            SSLCertificateFile "\(certPath)"
            SSLCertificateKeyFile "\(keyPath)"

            # PHP-FPM (Port \(port))
            <FilesMatch \\.php$>
                SetHandler "proxy:fcgi://127.0.0.1:\(port)"
            </FilesMatch>

            # Directory
            <Directory "\(domain.documentRoot)">
                Options Indexes FollowSymLinks
                AllowOverride All
                Require all granted
                DirectoryIndex index.php index.html
            </Directory>

            # Logging
            ErrorLog "\(PathConfig.httpdLogs)/\(domain.name)-error.log"
            CustomLog "\(PathConfig.httpdLogs)/\(domain.name)-access.log" combined
        </VirtualHost>
        """ : ""

        return """
        # ═══════════════════════════════════════════════════════════════════
        # Domain: \(domain.name)
        # Platform: PHP \(domain.phpVersion?.rawValue ?? "8.3") · Apache
        # SSL: \(domain.sslEnabled ? "Açık" : "Kapalı")
        # Created: \(dateString())
        # ═══════════════════════════════════════════════════════════════════

        \(httpBlock)\(httpsBlock)
        """
    }

    // MARK: - Apache: Reverse Proxy VHost (Node.js, Python, .NET)

    private static func apacheProxy(domain: Domain, port: Int) -> String {
        let certPath     = sslCertPath(for: domain.name)
        let keyPath      = sslKeyPath(for: domain.name)
        let platformName = domain.platform.displayName
        let redirect     = domain.redirectHTTPToHTTPS && domain.sslEnabled
        let httpPort     = WebServerPorts.apacheHTTP()
        let httpsPort    = WebServerPorts.apacheHTTPS()
        let httpsSuffix  = WebServerPorts.portSuffix(httpsPort, https: true)

        // WebSocket RewriteRule (opsiyonel)
        let wsBlock = domain.websocketEnabled ? """

                # WebSocket Upgrade
                RewriteEngine On
                RewriteCond %{HTTP:Upgrade} websocket [NC]
                RewriteCond %{HTTP:Connection} upgrade [NC]
                RewriteRule ^/?(.*) ws://127.0.0.1:\(port)/$1 [P,L]
        """ : ""

        // SSE — Apache'de gzip'i kapat, X-Accel-Buffering header ekle
        let sseBlock = domain.sseEnabled ? """

                # SSE / Streaming
                SetEnv no-gzip 1
                Header set X-Accel-Buffering "no"
                Header set Cache-Control "no-cache"
        """ : ""

        // Maks. istek gövde boyutu — Apache bayt cinsinden alır (örn. 10m → 10485760)
        // Kullanıcıdan gelen format "10m" / "100m" / "1g" vb. — doğrudan LimitRequestBody geçersiz,
        // bu yüzden değeri olduğu gibi yazıyoruz (mod_rewrite ortam değişkeni ile hata mesajı çıkmaz)
        let bodyBlock: String
        if let mb = domain.maxBodySize, !mb.isEmpty {
            // LimitRequestBody bayt ister; "10m" → 10485760 dönüşümü
            let bytes = parseBodySize(mb)
            bodyBlock = "\n            LimitRequestBody \(bytes)"
        } else {
            bodyBlock = ""
        }

        // Uygulama (backend) kapalıyken Apache'nin çıplak 503'ü yerine kullanıcı dostu mesaj
        let errorDocBlock = "\n            ErrorDocument 503 \"\(appDownHTML(domain: domain.name))\""

        let httpBlock: String
        if redirect {
            httpBlock = """
            # HTTP → HTTPS Yönlendirme
            <VirtualHost *:\(httpPort)>
                ServerName \(domain.name)
                Redirect permanent / https://\(domain.name)\(httpsSuffix)/
            </VirtualHost>
            """
        } else {
            httpBlock = """
            # HTTP (\(httpPort)) — Yönlendirme yok, içerik servis edilir
            <VirtualHost *:\(httpPort)>
                ServerName \(domain.name)

                # Reverse Proxy (WebSocket RewriteRule ProxyPass'ten ÖNCE)
                ProxyPreserveHost On\(wsBlock)
                ProxyPass / http://127.0.0.1:\(port)/
                ProxyPassReverse / http://127.0.0.1:\(port)/\(sseBlock)\(bodyBlock)\(errorDocBlock)

                ErrorLog "\(PathConfig.httpdLogs)/\(domain.name)-error.log"
                CustomLog "\(PathConfig.httpdLogs)/\(domain.name)-access.log" combined
            </VirtualHost>
            """
        }

        // HTTPS bloğu yalnızca SSL açıksa — var olmayan sertifika Apache'yi çökertir
        let httpsBlock = domain.sslEnabled ? """


        # HTTPS
        <VirtualHost *:\(httpsPort)>
            ServerName \(domain.name)

            # SSL
            SSLEngine on
            SSLCertificateFile "\(certPath)"
            SSLCertificateKeyFile "\(keyPath)"

            # Reverse Proxy (WebSocket RewriteRule ProxyPass'ten ÖNCE — upgrade istekleri önce yakalanır)
            ProxyPreserveHost On\(wsBlock)
            ProxyPass / http://127.0.0.1:\(port)/
            ProxyPassReverse / http://127.0.0.1:\(port)/\(sseBlock)\(bodyBlock)\(errorDocBlock)

            # Headers
            RequestHeader set X-Forwarded-Proto "https"
            RequestHeader set X-Forwarded-Host "\(domain.name)"

            # Logging
            ErrorLog "\(PathConfig.httpdLogs)/\(domain.name)-error.log"
            CustomLog "\(PathConfig.httpdLogs)/\(domain.name)-access.log" combined
        </VirtualHost>
        """ : ""

        return """
        # ═══════════════════════════════════════════════════════════════════
        # Domain: \(domain.name)
        # Platform: \(platformName) · Apache
        # Port: \(port)
        # SSL: \(domain.sslEnabled ? "Açık" : "Kapalı")
        # Created: \(dateString())
        # ═══════════════════════════════════════════════════════════════════

        \(httpBlock)\(httpsBlock)
        """
    }

    /// Backend (Node/Python/.NET) kapalıyken gösterilen 503 sayfası.
    /// KISIT: tek tırnak (nginx `return 503 '...'`) VE çift tırnak (Apache `ErrorDocument "..."`)
    /// VE `$` (nginx değişkeni) İÇERMEMELİ. Türkçe karakterler (ş, ı, ğ, ü, ö, ç) güvenlidir —
    /// bunlar tırnak/$ değildir; config UTF-8 yazılır, `<meta charset=utf-8>` ile doğru görüntülenir.
    static func appDownHTML(domain: String) -> String {
        "<!doctype html><html lang=tr><head><meta charset=utf-8><title>Uygulama Kapalı</title></head>" +
        "<body style=font-family:-apple-system,sans-serif;text-align:center;padding-top:12vh;color:#333>" +
        "<h1 style=font-size:2.2em>&#9888;&#65039; Uygulama Şu Anda Kapalı</h1>" +
        "<p style=color:#666><b>\(domain)</b> uygulaması henüz başlatılmadı veya durduruldu.</p>" +
        "<p style=color:#999>BRAMPP &rarr; Alan Adları sekmesinden başlatabilirsiniz.</p>" +
        "</body></html>"
    }

    /// "10m" / "100m" / "1g" → bayt cinsinden Int.
    ///
    /// TAŞMA-GÜVENLİ: alan serbest metindir (doğrulanmıyor). "9000000000g" gibi bir girdide
    /// çarpım Int sınırını aşar; Swift'te taşan `*` çalışma anında trap atar ve uygulamayı
    /// ÇÖKERTİR. Sonuç ayrıca Apache LimitRequestBody tavanına (2 GiB−1) kırpılır — aksi halde
    /// negatif/absürt bir değer geçersiz direktif üretirdi.
    /// (test edilebilirlik için `internal` — taşma davranışı birim testle korunuyor)
    static func parseBodySize(_ s: String) -> Int {
        let maxBytes = 2_147_483_647   // Apache LimitRequestBody üst sınırı
        let lower = s.lowercased().trimmingCharacters(in: .whitespaces)

        func scaled(_ text: Substring, _ factor: Int) -> Int? {
            guard let n = Int(text), n >= 0 else { return nil }
            let (v, overflow) = n.multipliedReportingOverflow(by: factor)
            return overflow ? maxBytes : min(v, maxBytes)
        }
        if lower.hasSuffix("g"), let v = scaled(lower.dropLast(), 1_073_741_824) { return v }
        if lower.hasSuffix("m"), let v = scaled(lower.dropLast(), 1_048_576)     { return v }
        if lower.hasSuffix("k"), let v = scaled(lower.dropLast(), 1_024)         { return v }
        if let n = Int(lower), n >= 0 { return min(n, maxBytes) }
        return 10_485_760              // varsayılan: 10m
    }

    // MARK: - Apache: Static VHost

    private static func apacheStatic(domain: Domain) -> String {
        let certPath = sslCertPath(for: domain.name)
        let keyPath  = sslKeyPath(for: domain.name)
        let redirect = domain.redirectHTTPToHTTPS && domain.sslEnabled
        // SPA açıksa: dosyaya eşleşmeyen tüm yollar index.html'e düşer (mod_dir FallbackResource)
        let spaLine = domain.spaFallback ? "\n            FallbackResource /index.html" : ""
        let httpPort    = WebServerPorts.apacheHTTP()
        let httpsPort   = WebServerPorts.apacheHTTPS()
        let httpsSuffix = WebServerPorts.portSuffix(httpsPort, https: true)

        let httpBlock: String
        if redirect {
            httpBlock = """
            # HTTP → HTTPS Yönlendirme
            <VirtualHost *:\(httpPort)>
                ServerName \(domain.name)
                Redirect permanent / https://\(domain.name)\(httpsSuffix)/
            </VirtualHost>
            """
        } else {
            httpBlock = """
            # HTTP (\(httpPort)) — Yönlendirme yok, içerik servis edilir
            <VirtualHost *:\(httpPort)>
                ServerName \(domain.name)
                DocumentRoot "\(domain.documentRoot)"

                <Directory "\(domain.documentRoot)">
                    Options Indexes FollowSymLinks
                    AllowOverride All
                    Require all granted
                    DirectoryIndex index.html index.htm\(spaLine)
                </Directory>

                ErrorLog "\(PathConfig.httpdLogs)/\(domain.name)-error.log"
                CustomLog "\(PathConfig.httpdLogs)/\(domain.name)-access.log" combined
            </VirtualHost>
            """
        }

        let httpsBlock = domain.sslEnabled ? """


        # HTTPS
        <VirtualHost *:\(httpsPort)>
            ServerName \(domain.name)
            DocumentRoot "\(domain.documentRoot)"

            # SSL
            SSLEngine on
            SSLCertificateFile "\(certPath)"
            SSLCertificateKeyFile "\(keyPath)"

            # Directory
            <Directory "\(domain.documentRoot)">
                Options Indexes FollowSymLinks
                AllowOverride All
                Require all granted
                DirectoryIndex index.html index.htm\(spaLine)
            </Directory>

            # Logging
            ErrorLog "\(PathConfig.httpdLogs)/\(domain.name)-error.log"
            CustomLog "\(PathConfig.httpdLogs)/\(domain.name)-access.log" combined
        </VirtualHost>
        """ : ""

        return """
        # ═══════════════════════════════════════════════════════════════════
        # Domain: \(domain.name)
        # Platform: Static · Apache
        # SSL: \(domain.sslEnabled ? "Açık" : "Kapalı")
        # Created: \(dateString())
        # ═══════════════════════════════════════════════════════════════════

        \(httpBlock)\(httpsBlock)
        """
    }

    // MARK: - Nginx: PHP Server Block

    private static func nginxPHP(domain: Domain) -> String {
        let phpPort  = domain.phpVersion?.port ?? 9083
        let certPath = sslCertPath(for: domain.name)
        let keyPath  = sslKeyPath(for: domain.name)
        let redirect = domain.redirectHTTPToHTTPS && domain.sslEnabled
        // Nginx'in GÜNCEL portları — kullanıcı portu değiştirdiyse server blokları da uymalı
        let httpPort  = WebServerPorts.nginxHTTP()
        let httpsPort = WebServerPorts.nginxHTTPS()

        let httpBlock: String
        if redirect {
            httpBlock = """
            # HTTP → HTTPS Yönlendirme
            server {
                listen      \(httpPort);
                server_name \(domain.name);
                return 301  https://\(domain.name):\(httpsPort)$request_uri;
            }
            """
        } else {
            httpBlock = """
            # HTTP (\(httpPort)) — Yönlendirme yok, içerik servis edilir
            server {
                listen      \(httpPort);
                server_name \(domain.name);
                root        "\(domain.documentRoot)";

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

                access_log "\(PathConfig.nginxLogs)/\(domain.name)-access.log";
                error_log  "\(PathConfig.nginxLogs)/\(domain.name)-error.log";
            }
            """
        }

        // HTTPS bloğu yalnızca SSL açıksa — var olmayan sertifika `nginx -t`'yi çökertir
        let httpsBlock = domain.sslEnabled ? """


        # HTTPS
        server {
            listen      \(httpsPort) ssl;
            server_name \(domain.name);
            root        "\(domain.documentRoot)";

            ssl_certificate     "\(certPath)";
            ssl_certificate_key "\(keyPath)";

            index index.php index.html;

            location / {
                try_files $uri $uri/ /index.php?$query_string;
            }

            # PHP-FPM (Port \(phpPort))
            location ~ \\.php$ {
                fastcgi_pass   127.0.0.1:\(phpPort);
                fastcgi_index  index.php;
                fastcgi_param  SCRIPT_FILENAME $document_root$fastcgi_script_name;
                include        fastcgi_params;
            }

            access_log "\(PathConfig.nginxLogs)/\(domain.name)-access.log";
            error_log  "\(PathConfig.nginxLogs)/\(domain.name)-error.log";
        }
        """ : ""

        return """
        # ═══════════════════════════════════════════════════════════════════
        # Domain: \(domain.name)
        # Platform: PHP \(domain.phpVersion?.rawValue ?? "8.3") · Nginx
        # SSL: \(domain.sslEnabled ? "Açık" : "Kapalı")
        # Created: \(dateString())
        # ═══════════════════════════════════════════════════════════════════

        \(httpBlock)\(httpsBlock)
        """
    }

    // MARK: - Nginx: Reverse Proxy (Node.js, Python, .NET)

    private static func nginxProxy(domain: Domain, port: Int) -> String {
        let certPath     = sslCertPath(for: domain.name)
        let keyPath      = sslKeyPath(for: domain.name)
        let platformName = domain.platform.displayName
        let redirect     = domain.redirectHTTPToHTTPS && domain.sslEnabled
        let httpPort     = WebServerPorts.nginxHTTP()
        let httpsPort    = WebServerPorts.nginxHTTPS()

        // HTTP/2 — Nginx 1.25+ standalone directive
        // HTTP/2 — gRPC onu ZORUNLU kılar, bu yüzden TLS dinleyicide de açılmalı.
        // (Düz metin dinleyici bunu zaten `plainHttp2` ile yapıyor.) Aksi halde grpcEnabled
        // ama http2Enabled kapalı bir domainde ALPN h2'yi duyurmaz ve gRPC/TLS sessizce çalışmaz.
        let http2Directive = (domain.http2Enabled || domain.grpcEnabled) ? "\n    http2           on;" : ""

        // client_max_body_size — boş string değersiz direktif üretmesin.
        // DOĞRULAMA: alan serbest metindir. Ham yazılırsa ";" veya "}" içeren bir değer
        // server bloğunu bozar (config enjeksiyonu), geçersiz bir değer ise nginx'in hiç
        // başlamamasına yol açar. Yalnızca nginx'in kabul ettiği "sayı[k|m|g]" biçimi geçer;
        // aksi halde direktif hiç yazılmaz (sunucu varsayılanı kullanılır).
        let bodyLine: String = {
            guard let raw = domain.maxBodySize?.trimmingCharacters(in: .whitespaces),
                  !raw.isEmpty,
                  raw.range(of: "^[0-9]+[kKmMgG]?$", options: .regularExpression) != nil
            else { return "" }
            return "\n        client_max_body_size \(raw);"
        }()

        // location / içeriği: gRPC veya HTTP proxy
        let locationContent: String
        if domain.grpcEnabled {
            // gRPC — HTTP/2 üzerinden; local app TLS kullanmıyorsa grpc://, kullanıyorsa grpcs://
            locationContent = """
                    grpc_pass           grpc://127.0.0.1:\(port);
                    grpc_set_header     Host $host;
                    grpc_set_header     X-Real-IP $remote_addr;
                    grpc_set_header     X-Forwarded-For $proxy_add_x_forwarded_for;
                    grpc_set_header     X-Forwarded-Proto $scheme;\(bodyLine)
            """
        } else {
            // WebSocket upgrade headers
            let wsHeaders: String
            if domain.websocketEnabled {
                wsHeaders = """
                        proxy_set_header        Upgrade $http_upgrade;
                        proxy_set_header        Connection "upgrade";
                        proxy_cache_bypass      $http_upgrade;
                """
            } else {
                wsHeaders = """
                        proxy_set_header        Connection "";
                """
            }
            // SSE / Streaming — proxy buffering kapatılır
            let sseLines = domain.sseEnabled ? """

                        proxy_buffering         off;
                        proxy_cache             off;
                        add_header              X-Accel-Buffering no;
            """ : ""

            locationContent = """
                    proxy_pass              http://127.0.0.1:\(port);
                    proxy_http_version      1.1;
            \(wsHeaders)
                    proxy_set_header        Host $host;
                    proxy_set_header        X-Real-IP $remote_addr;
                    proxy_set_header        X-Forwarded-For $proxy_add_x_forwarded_for;
                    proxy_set_header        X-Forwarded-Proto $scheme;
                    proxy_set_header        X-Forwarded-Host \(domain.name);
                    proxy_read_timeout      86400;\(sseLines)\(bodyLine)
            """
        }

        // Backend kapalıyken (502/504) nginx'in çıplak hata sayfası yerine kullanıcı dostu mesaj.
        // gRPC modunda eklenmez — gRPC istemcileri HTML beklemez.
        let appDownBlock = domain.grpcEnabled ? "" : """


                # Uygulama kapalıyken kullanıcı dostu mesaj
                error_page 502 503 504 = @app_down;
                location @app_down {
                    default_type text/html;
                    return 503 '\(appDownHTML(domain: domain.name))';
                }
        """

        let locationBlock = """
                location / {
            \(locationContent)
                }\(appDownBlock)
        """

        let httpBlock: String
        if redirect {
            httpBlock = """
            # HTTP → HTTPS Yönlendirme
            server {
                listen      \(httpPort);
                server_name \(domain.name);
                return 301  https://\(domain.name):\(httpsPort)$request_uri;
            }
            """
        } else {
            // gRPC HTTP/2 gerektirir — düz-metin (h2c) dinleyicide de http2 açık olmalı,
            // aksi halde SSL kapalıyken gRPC istekleri sessizce başarısız olur.
            let plainHttp2 = domain.grpcEnabled ? "\n                http2       on;" : ""
            httpBlock = """
            # HTTP (\(httpPort)) — Yönlendirme yok, içerik servis edilir
            server {
                listen      \(httpPort);\(plainHttp2)
                server_name \(domain.name);

            \(locationBlock)

                access_log "\(PathConfig.nginxLogs)/\(domain.name)-access.log";
                error_log  "\(PathConfig.nginxLogs)/\(domain.name)-error.log";
            }
            """
        }

        // Etkin özellikleri header'a yaz
        var features: [String] = []
        if domain.grpcEnabled      { features.append("gRPC") }
        if domain.http2Enabled     { features.append("HTTP/2") }
        if domain.websocketEnabled && !domain.grpcEnabled { features.append("WebSocket") }
        if domain.sseEnabled       { features.append("SSE") }
        if let mb = domain.maxBodySize, !mb.trimmingCharacters(in: .whitespaces).isEmpty { features.append("MaxBody:\(mb)") }
        let featureLine = features.isEmpty ? "" : "\n# Özellikler: \(features.joined(separator: ", "))"

        let httpsBlock = domain.sslEnabled ? """


        # HTTPS
        server {
            listen      \(httpsPort) ssl;\(http2Directive)
            server_name \(domain.name);

            ssl_certificate     "\(certPath)";
            ssl_certificate_key "\(keyPath)";

        \(locationBlock)

            access_log "\(PathConfig.nginxLogs)/\(domain.name)-access.log";
            error_log  "\(PathConfig.nginxLogs)/\(domain.name)-error.log";
        }
        """ : ""

        return """
        # ═══════════════════════════════════════════════════════════════════
        # Domain: \(domain.name)
        # Platform: \(platformName) · Nginx
        # Uygulama Portu: \(port)\(featureLine)
        # SSL: \(domain.sslEnabled ? "Açık" : "Kapalı")
        # Created: \(dateString())
        # ═══════════════════════════════════════════════════════════════════

        \(httpBlock)\(httpsBlock)
        """
    }

    // MARK: - Nginx: Static Server Block

    private static func nginxStatic(domain: Domain) -> String {
        let certPath = sslCertPath(for: domain.name)
        let keyPath  = sslKeyPath(for: domain.name)
        // SPA açıksa bulunamayan yollar index.html'e düşer (istemci-taraflı router)
        let spaTry = domain.spaFallback ? "/index.html" : "=404"
        let redirect = domain.redirectHTTPToHTTPS && domain.sslEnabled
        let httpPort  = WebServerPorts.nginxHTTP()
        let httpsPort = WebServerPorts.nginxHTTPS()

        let httpBlock: String
        if redirect {
            httpBlock = """
            # HTTP → HTTPS Yönlendirme
            server {
                listen      \(httpPort);
                server_name \(domain.name);
                return 301  https://\(domain.name):\(httpsPort)$request_uri;
            }
            """
        } else {
            httpBlock = """
            # HTTP (\(httpPort)) — Yönlendirme yok, içerik servis edilir
            server {
                listen      \(httpPort);
                server_name \(domain.name);
                root        "\(domain.documentRoot)";

                index index.html index.htm;

                location / {
                    try_files $uri $uri/ \(spaTry);
                }

                access_log "\(PathConfig.nginxLogs)/\(domain.name)-access.log";
                error_log  "\(PathConfig.nginxLogs)/\(domain.name)-error.log";
            }
            """
        }

        let httpsBlock = domain.sslEnabled ? """


        # HTTPS
        server {
            listen      \(httpsPort) ssl;
            server_name \(domain.name);
            root        "\(domain.documentRoot)";

            ssl_certificate     "\(certPath)";
            ssl_certificate_key "\(keyPath)";

            index index.html index.htm;

            location / {
                try_files $uri $uri/ \(spaTry);
            }

            access_log "\(PathConfig.nginxLogs)/\(domain.name)-access.log";
            error_log  "\(PathConfig.nginxLogs)/\(domain.name)-error.log";
        }
        """ : ""

        return """
        # ═══════════════════════════════════════════════════════════════════
        # Domain: \(domain.name)
        # Platform: Static · Nginx
        # SSL: \(domain.sslEnabled ? "Açık" : "Kapalı")
        # Created: \(dateString())
        # ═══════════════════════════════════════════════════════════════════

        \(httpBlock)\(httpsBlock)
        """
    }

    // MARK: - Apache: Varsayılan localhost VHost

    /// Varsayılan localhost vhost'u (000-localhost.conf).
    ///
    /// Apache, Host başlığı hiçbir ServerName ile eşleşmeyen istekleri o porttaki
    /// İLK VirtualHost'a düşürür. Bu dosya olmadan `localhost` istekleri alfabetik
    /// ilk domain vhost'una gider — ör. localhost/phpmyadmin'in bir domaine
    /// yönlenmesi bu yüzden olur. 000- öneki dosyanın ilk yüklenmesini garantiler.
    static func apacheLocalhostDefault(phpPort: Int) -> String {
        let root = PathConfig.localhostDir
        let cert = "\(PathConfig.localhostSSLDir)/cert.pem"
        let key  = "\(PathConfig.localhostSSLDir)/key.pem"
        let sslAvailable = FileHelper.exists(cert) && FileHelper.exists(key)
        let httpPort  = WebServerPorts.apacheHTTP()
        let httpsPort = WebServerPorts.apacheHTTPS()

        let directoryBlock = """
            <Directory "\(root)">
                Options Indexes FollowSymLinks
                AllowOverride All
                Require all granted
                DirectoryIndex index.php index.html
            </Directory>
        """

        let httpsBlock = sslAvailable ? """


        # HTTPS (\(httpsPort)) — varsayılan sunucu
        <VirtualHost *:\(httpsPort)>
            ServerName localhost
            ServerAlias 127.0.0.1
            DocumentRoot "\(root)"

            SSLEngine on
            SSLCertificateFile "\(cert)"
            SSLCertificateKeyFile "\(key)"

            <FilesMatch \\.php$>
                SetHandler "proxy:fcgi://127.0.0.1:\(phpPort)"
            </FilesMatch>

        \(directoryBlock)
        </VirtualHost>
        """ : ""

        return """
        # ═══════════════════════════════════════════════════════════════════
        # Varsayılan localhost VirtualHost — BRAMPP tarafından yönetilir
        # Bu dosya alfabetik olarak İLK yüklenir (000- öneki).
        # Host başlığı eşleşmeyen istekler (localhost, 127.0.0.1 dahil) buraya
        # düşer — domain vhost'larına yönlenme/redirect sorununu önler.
        # ═══════════════════════════════════════════════════════════════════

        <VirtualHost *:\(httpPort)>
            ServerName localhost
            ServerAlias 127.0.0.1
            DocumentRoot "\(root)"

            <FilesMatch \\.php$>
                SetHandler "proxy:fcgi://127.0.0.1:\(phpPort)"
            </FilesMatch>

        \(directoryBlock)
        </VirtualHost>\(httpsBlock)
        """
    }

    // MARK: - Apache Include Snippets

    static func virtualHostsIncludeConfig() -> String {
        "IncludeOptional \(PathConfig.vhostsDir)/*.conf"
    }

    static func phpmyadminIncludeConfig() -> String {
        "IncludeOptional \(PathConfig.phpmyadminConf)"
    }

    static func pgadmin4IncludeConfig() -> String {
        "IncludeOptional \(PathConfig.pgadmin4Conf)"
    }

    // MARK: - pgAdmin4 Apache Config

    /// Apache httpd.conf'a IncludeOptional ile eklenen pgAdmin4 reverse proxy bloğu.
    /// pgAdmin4 web sunucusu 127.0.0.1:5050'de çalışır; X-Script-Name header ile subpath yönlendirmesi yapılır.
    static func pgadmin4ApacheConfig() -> String {
        """
        # ═══════════════════════════════════════════════════════════════════
        # pgAdmin4 Reverse Proxy
        # Erişim: https://localhost/pgadmin4
        # pgAdmin4 servisi: brew services run pgadmin4 (port 5050)
        # ═══════════════════════════════════════════════════════════════════

        <Location /pgadmin4>
            RequestHeader set X-Script-Name /pgadmin4
            ProxyPreserveHost Off
            ProxyPass        http://127.0.0.1:\(PathConfig.pgadmin4Port)/
            ProxyPassReverse http://127.0.0.1:\(PathConfig.pgadmin4Port)/
        </Location>
        """
    }

    /// Nginx sites-available/pgadmin4.conf dosyası (nginx.conf'a include edilir).
    static func pgadmin4NginxConfig() -> String {
        """
        # ═══════════════════════════════════════════════════════════════════
        # pgAdmin4 Reverse Proxy — Nginx
        # Erişim: http://localhost:8080/pgadmin4/
        # pgAdmin4 servisi: brew services run pgadmin4 (port 5050)
        # ═══════════════════════════════════════════════════════════════════

        # Bu blok nginx.conf içindeki localhost HTTP ve HTTPS server bloklarına eklenmelidir.
        # Aşağıdaki location bloğunu kopyalayın veya 'Nginx Yapılandır' butonu ile otomatik ekleyin.

        location /pgadmin4/ {
            proxy_pass              http://127.0.0.1:\(PathConfig.pgadmin4Port)/;
            proxy_http_version      1.1;
            proxy_set_header        Host $host;
            proxy_set_header        X-Real-IP $remote_addr;
            proxy_set_header        X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header        X-Forwarded-Proto $scheme;
            proxy_set_header        X-Script-Name /pgadmin4;
        }
        """
    }

    // MARK: - phpMyAdmin Global Config

    /// Adminer için httpd.conf'a eklenecek IncludeOptional satırı
    static func adminerIncludeConfig() -> String {
        "IncludeOptional \(PathConfig.adminerConf)"
    }

    /// Adminer Apache yapılandırması (extra/adminer.conf).
    /// phpMyAdmin ile aynı desen: Alias + Directory + PHP-FPM handler.
    /// Tek dosya (index.php) hem MySQL/MariaDB hem PostgreSQL'i yönetir.
    static func adminerApacheConfig(phpPort: Int = 9083) -> String {
        """
        # ═══════════════════════════════════════════════════════════════════
        # Adminer — tek dosyalı web veritabanı yöneticisi
        # Erişim: https://localhost/adminer  (MySQL/MariaDB + PostgreSQL)
        # ═══════════════════════════════════════════════════════════════════

        Alias /adminer \(PathConfig.adminerDir)
        Alias /adminer/ \(PathConfig.adminerDir)/

        <Directory \(PathConfig.adminerDir)/>
            Options FollowSymLinks
            AllowOverride None
            <IfModule mod_authz_core.c>
                Require local
            </IfModule>
            <IfModule !mod_authz_core.c>
                Order deny,allow
                Deny from all
                Allow from 127.0.0.1 ::1
            </IfModule>
            DirectoryIndex index.php
        </Directory>

        <LocationMatch "^/adminer/.*\\.php$">
            Require local
            SetHandler "proxy:fcgi://127.0.0.1:\(phpPort)"
        </LocationMatch>
        """
    }

    static func phpmyadminConfig(phpPort: Int = 9083) -> String {
        """
        # ═══════════════════════════════════════════════════════════════════
        # phpMyAdmin Global Alias
        # Erişim: https://localhost/phpmyadmin
        # ═══════════════════════════════════════════════════════════════════

        Alias /phpmyadmin \(PathConfig.phpmyadminDir)
        Alias /phpmyadmin/ \(PathConfig.phpmyadminDir)/

        <Directory \(PathConfig.phpmyadminDir)/>
            Options Indexes FollowSymLinks MultiViews
            AllowOverride All
            <IfModule mod_authz_core.c>
                Require all granted
            </IfModule>
            <IfModule !mod_authz_core.c>
                Order allow,deny
                Allow from all
            </IfModule>
            DirectoryIndex index.php index.html
        </Directory>

        <Location "/phpmyadmin/setup">
            Require all denied
        </Location>

        <LocationMatch "^/phpmyadmin/.*\\.php$">
            Require local
            SetHandler "proxy:fcgi://127.0.0.1:\(phpPort)"
        </LocationMatch>
        """
    }

    /// phpMyAdmin config.inc.php içeriği.
    /// `blowfish_secret` kurulum sırasında bir kez üretilir ve sabit olarak yazılır (geçici anahtar uyarısı çıkmaz).
    static func phpmyadminLocalConfig() -> String {
        let secret = generateBlowfishSecret()
        return """
        <?php
        declare(strict_types=1);

        $i = 1;

        /* Cookie şifrelemesi için 32-byte rastgele anahtar (BRAMPP tarafından üretildi) */
        $cfg['blowfish_secret'] = '\(secret)';

        /* Authentication type */
        $cfg['Servers'][$i]['auth_type'] = 'cookie';

        /* Server parameters */
        $cfg['Servers'][$i]['host'] = '127.0.0.1';
        $cfg['Servers'][$i]['compress'] = true;
        $cfg['Servers'][$i]['AllowNoPassword'] = true;

        $cfg['Servers'][$i]['hide_db'] = '^(information_schema|mysql|performance_schema|sys)$';
        """
    }

    /// Tam olarak 32 görünür ASCII karakterinden oluşan rastgele bir blowfish_secret üretir.
    /// phpMyAdmin, tam 32-byte anahtar olmadığında geçici anahtar üretip uyarı gösterir.
    static func generateBlowfishSecret() -> String {
        let pool = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#%^&*-_=+?")
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        return String(bytes.map { pool[Int($0) % pool.count] })
    }

    // MARK: - Sample Files

    static func samplePHP(domain: String, phpVersion: String) -> String {
        """
        <?php
        /**
         * \(domain)
         * PHP Version: \(phpVersion)
         * Created by BRAMPP
         */

        echo "<h1>🐘 \(domain)</h1>";
        echo "<p>PHP " . phpversion() . " çalışıyor!</p>";
        echo "<hr>";
        phpinfo();
        """
    }

    static func sampleNodeJS(domain: String, port: Int) -> String {
        """
        /**
         * \(domain)
         * Node.js Application
         * Created by BRAMPP
         *
         * Port, start.sh'ın export ettiği PORT ortam değişkeninden okunur —
         * domain ayarlarından port değiştirilirse uygulama otomatik uyum sağlar
         * (sabit port gömülü olsaydı değişiklik sonrası 502 alınırdı).
         */

        const http = require('http');
        const PORT = Number(process.env.PORT) || \(port);

        const server = http.createServer((req, res) => {
            res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
            res.end(`
                <h1>🟩 \(domain)</h1>
                <p>Node.js ${process.version} çalışıyor!</p>
                <p>Port: ${PORT}</p>
            `);
        });

        server.listen(PORT, '127.0.0.1', () => {
            console.log(`Server running at http://127.0.0.1:${PORT}/`);
        });
        """
    }

    static func samplePackageJSON(domain: String) -> String {
        """
        {
            "name": "\(domain.replacingOccurrences(of: ".", with: "-"))",
            "version": "1.0.0",
            "description": "Generated by BRAMPP",
            "main": "app.js",
            "scripts": {
                "start": "node app.js",
                "dev": "nodemon app.js"
            },
            "keywords": [],
            "author": "",
            "license": "ISC"
        }
        """
    }

    static func samplePython(domain: String, framework: PythonFramework) -> String {
        switch framework {
        case .fastapi:
            return """
            \"\"\"
            \(domain)
            FastAPI Application
            Created by BRAMPP
            \"\"\"

            from fastapi import FastAPI

            app = FastAPI(title="\(domain)")

            @app.get("/")
            def root():
                return {
                    "message": "🐍 \(domain) çalışıyor!",
                    "framework": "FastAPI"
                }

            @app.get("/health")
            def health():
                return {"status": "ok"}
            """

        case .django:
            return """
            # Django projesi için:
            # django-admin startproject \(domain.replacingOccurrences(of: ".", with: "_")) .
            """

        case .flask:
            return """
            \"\"\"
            \(domain)
            Flask Application
            Created by BRAMPP
            \"\"\"

            from flask import Flask

            app = Flask(__name__)

            @app.route('/')
            def index():
                return '<h1>🐍 \(domain)</h1><p>Flask çalışıyor!</p>'

            if __name__ == '__main__':
                app.run(debug=True)
            """
        }
    }

    static func sampleRequirements(framework: PythonFramework) -> String {
        framework.packages.joined(separator: "\n")
    }

    static func sampleHTML(domain: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="tr">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>\(domain)</title>
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    min-height: 100vh;
                    margin: 0;
                    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                    color: white;
                }
                .container { text-align: center; }
                h1 { font-size: 3em; margin-bottom: 0.5em; }
                p  { font-size: 1.2em; opacity: 0.9; }
            </style>
        </head>
        <body>
            <div class="container">
                <h1>📄 \(domain)</h1>
                <p>Static site çalışıyor!</p>
                <p>Created by BRAMPP</p>
            </div>
        </body>
        </html>
        """
    }

    // MARK: - PM2 Ecosystem Config

    // MARK: - (Eski PM2 bloğu NativeProcessManager.buildStartScript ile değiştirildi)

    // MARK: - Path Helpers

    private static func sslCertPath(for domain: String) -> String {
        "\(PathConfig.sslDir)/\(domain)/cert.pem"
    }

    private static func sslKeyPath(for domain: String) -> String {
        "\(PathConfig.sslDir)/\(domain)/key.pem"
    }

    private static func dateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}
