import Foundation

/// Domain modeli
struct Domain: Identifiable, Hashable {
    let id: UUID
    var name: String
    var platform: Platform
    var phpVersion: PHPVersion?
    var nodeVersion: NodeVersion?
    var pythonVersion: PythonVersion?
    var pythonFramework: PythonFramework?
    var dotnetVersion: DotNetVersion?
    var port: Int?
    var sslEnabled: Bool
    var isRunning: Bool
    var createdAt: Date
    /// Hangi web sunucusu kullanılıyor — eski kayıtlar için varsayılan: apache
    var webServer: WebServer
    /// HTTP trafiğini HTTPS'e yönlendir — eski kayıtlar için varsayılan: true
    var redirectHTTPToHTTPS: Bool
    /// Uygulama başlatma komutu — Node.js: "npm start", Python: "python main.py", .NET: "dotnet run"
    var appCommand: String?
    /// Derleme/kurulum komutu — Node.js: "npm install", Python: "pip install -r requirements.txt"
    var buildCommand: String?
    /// Ortam değişkenleri — PM2 ecosystem config'e yansıtılır
    var envVars: [String: String]?
    /// Başlatılmadan önce ÇALIŞIYOR olması gereken servis id'leri
    /// (örn. "mariadb", "postgresql@17", "redis"). nil/boş = bağımlılık yok.
    var serviceDependencies: [String]? = nil

    // MARK: - Python Ayarları

    /// Virtual environment kullan — venv/ veya .venv/ otomatik tespit edilir.
    /// true (varsayılan): proje dizinindeki venv önceliklidir.
    /// false: brew ile kurulan global python kullanılır.
    var pythonUseVenv: Bool

    // MARK: - Proxy Ayarları

    /// WebSocket upgrade desteği — proxy_set_header Upgrade / Connection
    var websocketEnabled: Bool
    /// HTTP/2 protokolü — Nginx: `http2 on;` (v1.25+)
    var http2Enabled: Bool
    /// Server-Sent Events / Streaming — proxy_buffering off
    var sseEnabled: Bool
    /// gRPC modu — Nginx: grpc_pass (HTTP/2 gerektirir, WebSocket ile çelişir)
    var grpcEnabled: Bool
    /// Maks. istek gövde boyutu — "10m", "100m" vb. (nil: sunucu varsayılanı)
    var maxBodySize: String?

    // MARK: - Document Root

    /// Manuel document root — nil/boş ise varsayılan `~/Sites/{name}` kullanılır.
    /// Mevcut bir proje klasörü seçildiğinde içerik korunur, örnek dosya yazılmaz.
    var customDocumentRoot: String?

    // MARK: - Etkinlik

    /// Domain etkin mi? Devre dışı bırakıldığında vhost + /etc/hosts girişi kaldırılır
    /// (kayıt/dosyalar korunur), tekrar etkinleştirilince yeniden üretilir.
    /// Eski kayıtlar için varsayılan: true.
    var isEnabled: Bool

    /// SPA history fallback — yalnızca STATIC platform için anlamlıdır.
    /// true: bulunamayan yollar index.html'e düşer (React Router / Vue Router vb.
    /// istemci-taraflı yönlendirme çalışır). false: klasik 404.
    /// Eski kayıtlar için varsayılan: false.
    var spaFallback: Bool

    // MARK: - Computed Properties

    /// Site klasörü path'i
    var sitePath: String {
        if let root = customDocumentRoot, !root.isEmpty { return root }
        return "\(PathConfig.sites)/\(name)"
    }

    /// Document root
    var documentRoot: String {
        sitePath
    }

    /// SSL sertifika path'i
    var sslCertPath: String {
        "\(PathConfig.ssl)/\(name)/cert.pem"
    }

    /// SSL key path'i
    var sslKeyPath: String {
        "\(PathConfig.ssl)/\(name)/key.pem"
    }

    /// VHost / server block config dosyası path'i
    var vhostConfigPath: String {
        switch webServer {
        case .apache: return "\(PathConfig.vhostsDir)/\(name).conf"
        case .nginx:  return "\(PathConfig.nginxSitesAvailableDir)/\(name).conf"
        }
    }

    /// Error log dosyası path'i
    var errorLogPath: String {
        switch webServer {
        case .apache: return "\(PathConfig.httpdLogs)/\(name)-error.log"
        case .nginx:  return "\(PathConfig.nginxLogs)/\(name)-error.log"
        }
    }

    /// Access log dosyası path'i
    var accessLogPath: String {
        switch webServer {
        case .apache: return "\(PathConfig.httpdLogs)/\(name)-access.log"
        case .nginx:  return "\(PathConfig.nginxLogs)/\(name)-access.log"
        }
    }

    /// PM2 ecosystem config dosyası path'i
    var ecosystemConfigPath: String { "\(sitePath)/ecosystem.config.js" }

    /// BRAMPP JSON config dosyası (.brampp.json) path'i
    /// Application Support/processes/{name}/.brampp.json — site dizini kirletilmez
    var bramppConfigPath: String { PathConfig.processConfig(domain: name) }

    /// URL — web sunucusunun GÜNCEL portlarını kullanır (kullanıcı portu değiştirmiş olabilir)
    var url: String {
        let scheme  = sslEnabled ? "https" : "http"
        let port    = sslEnabled ? WebServerPorts.httpsPort(for: webServer)
                                 : WebServerPorts.httpPort(for: webServer)
        let portStr = WebServerPorts.portSuffix(port, https: sslEnabled)
        return "\(scheme)://\(name)\(portStr)"
    }

    /// Versiyon gösterimi
    var versionDisplay: String {
        switch platform {
        case .php:
            return phpVersion?.displayName ?? ""
        case .nodejs:
            return nodeVersion?.displayName ?? ""
        case .python:
            let version   = pythonVersion?.displayName ?? ""
            let framework = pythonFramework?.displayName ?? ""
            return "\(version) - \(framework)"
        case .dotnet:
            return dotnetVersion?.displayName ?? ""
        case .static_:
            return "Static"
        }
    }

    /// Port gösterimi (backend uygulama portu)
    var portDisplay: String {
        switch platform {
        case .php:
            return ":\(phpVersion?.port ?? 9083)"
        case .nodejs, .python, .dotnet:
            if let port = port { return ":\(port)" }
            return ""
        case .static_:
            return ""
        }
    }

    // MARK: - Initializer

    init(
        id: UUID = UUID(),
        name: String,
        platform: Platform,
        phpVersion: PHPVersion? = nil,
        nodeVersion: NodeVersion? = nil,
        pythonVersion: PythonVersion? = nil,
        pythonFramework: PythonFramework? = nil,
        dotnetVersion: DotNetVersion? = nil,
        port: Int? = nil,
        sslEnabled: Bool = true,
        isRunning: Bool = false,
        createdAt: Date = Date(),
        webServer: WebServer = .apache,
        redirectHTTPToHTTPS: Bool = true,
        appCommand: String? = nil,
        buildCommand: String? = nil,
        envVars: [String: String]? = nil,
        customDocumentRoot: String? = nil,
        isEnabled: Bool = true,
        spaFallback: Bool = false,
        pythonUseVenv: Bool = true,
        websocketEnabled: Bool = true,
        http2Enabled: Bool = false,
        sseEnabled: Bool = false,
        grpcEnabled: Bool = false,
        maxBodySize: String? = nil
    ) {
        self.id                   = id
        self.name                 = name
        self.platform             = platform
        self.phpVersion           = phpVersion
        self.nodeVersion          = nodeVersion
        self.pythonVersion        = pythonVersion
        self.pythonFramework      = pythonFramework
        self.dotnetVersion        = dotnetVersion
        self.port                 = port
        self.sslEnabled           = sslEnabled
        self.isRunning            = isRunning
        self.createdAt            = createdAt
        self.webServer            = webServer
        self.redirectHTTPToHTTPS  = redirectHTTPToHTTPS
        self.appCommand           = appCommand
        self.buildCommand         = buildCommand
        self.envVars              = envVars
        self.customDocumentRoot   = customDocumentRoot
        self.isEnabled            = isEnabled
        self.spaFallback          = spaFallback
        self.pythonUseVenv        = pythonUseVenv
        self.websocketEnabled     = websocketEnabled
        self.http2Enabled         = http2Enabled
        self.sseEnabled           = sseEnabled
        self.grpcEnabled          = grpcEnabled
        self.maxBodySize          = maxBodySize
    }

    // MARK: - Factory Methods

    static func php(name: String, version: PHPVersion = .v83, ssl: Bool = true,
                    webServer: WebServer = .apache) -> Domain {
        Domain(name: name, platform: .php, phpVersion: version,
               sslEnabled: ssl, webServer: webServer)
    }

    static func nodejs(name: String, version: NodeVersion = .v20, port: Int,
                       ssl: Bool = true, webServer: WebServer = .nginx,
                       appCommand: String? = nil, buildCommand: String? = nil,
                       envVars: [String: String]? = nil) -> Domain {
        Domain(name: name, platform: .nodejs, nodeVersion: version,
               port: port, sslEnabled: ssl, webServer: webServer,
               appCommand:   appCommand   ?? "npm start",
               buildCommand: buildCommand ?? "npm install",
               envVars:      envVars)
    }

    static func python(name: String, version: PythonVersion = .v312,
                       framework: PythonFramework = .fastapi, port: Int,
                       ssl: Bool = true, webServer: WebServer = .nginx,
                       useVenv: Bool = true,
                       appCommand: String? = nil, buildCommand: String? = nil,
                       envVars: [String: String]? = nil) -> Domain {
        Domain(name: name, platform: .python, pythonVersion: version,
               pythonFramework: framework, port: port, sslEnabled: ssl, webServer: webServer,
               // {PORT} yer tutucusu OLDUĞU GİBİ saklanır — çalışma anında domain.port ile
               // değiştirilir. Böylece port sonradan değişince komut da güncel portu kullanır
               // (aksi halde eski port gömülü kalıp reverse proxy 502 verirdi).
               appCommand:   appCommand   ?? framework.serverCommand,
               buildCommand: buildCommand ?? "pip install -r requirements.txt",
               envVars:      envVars,
               pythonUseVenv: useVenv)
    }

    static func dotnet(name: String, version: DotNetVersion = .v8, port: Int,
                       ssl: Bool = true, webServer: WebServer = .nginx,
                       appCommand: String? = nil, buildCommand: String? = nil,
                       envVars: [String: String]? = nil) -> Domain {
        Domain(name: name, platform: .dotnet, dotnetVersion: version,
               port: port, sslEnabled: ssl, webServer: webServer,
               appCommand:   appCommand   ?? "dotnet run",
               buildCommand: buildCommand ?? "dotnet restore",
               envVars:      envVars)
    }

    static func staticSite(name: String, ssl: Bool = true,
                           webServer: WebServer = .apache) -> Domain {
        Domain(name: name, platform: .static_, sslEnabled: ssl, webServer: webServer)
    }
}

// MARK: - Codable (backward compat — eski JSON'da yeni alanlar yok → nil/varsayılan)

extension Domain: Codable {

    enum CodingKeys: String, CodingKey {
        case id, name, platform, phpVersion, nodeVersion, pythonVersion
        case pythonFramework, dotnetVersion, port, sslEnabled, isRunning, createdAt
        case webServer, redirectHTTPToHTTPS, appCommand, buildCommand, envVars
        case customDocumentRoot
        case isEnabled, spaFallback
        case pythonUseVenv
        case websocketEnabled, http2Enabled, sseEnabled, grpcEnabled, maxBodySize
        case serviceDependencies
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                   = try c.decode(UUID.self,     forKey: .id)
        name                 = try c.decode(String.self,   forKey: .name)
        platform             = try c.decode(Platform.self, forKey: .platform)
        // Sürüm alanları TOLERANSLI okunur (try? → bilinmeyen değer nil'e düşer).
        // Sert decodeIfPresent, tanınmayan bir raw value'da ("8.6" gibi — downgrade veya
        // kaldırılmış enum case) throw edip TÜM domain kaydını LossyDecodable üzerinden
        // düşürürdü. Alan nil kalırsa domain listede kalır; tüm tüketiciler nil sürümü
        // varsayılanlarla (9083, "8.3", "3.12" vb.) zaten ele alıyor.
        phpVersion           = try? c.decode(PHPVersion.self,      forKey: .phpVersion)
        nodeVersion          = try? c.decode(NodeVersion.self,     forKey: .nodeVersion)
        pythonVersion        = try? c.decode(PythonVersion.self,   forKey: .pythonVersion)
        pythonFramework      = try? c.decode(PythonFramework.self, forKey: .pythonFramework)
        dotnetVersion        = try? c.decode(DotNetVersion.self,   forKey: .dotnetVersion)
        port                 = try c.decodeIfPresent(Int.self,             forKey: .port)
        sslEnabled           = try c.decode(Bool.self,     forKey: .sslEnabled)
        isRunning            = false // geçici durum — JSON'dan okunmaz, refreshStatus() güncelleyecek
        createdAt            = try c.decode(Date.self,     forKey: .createdAt)
        // Eski kayıtlarda alan yok → varsayılan apache
        webServer            = (try? c.decode(WebServer.self, forKey: .webServer)) ?? .apache
        // Eski kayıtlarda alan yok → varsayılan true (redirect açık)
        redirectHTTPToHTTPS  = (try? c.decode(Bool.self, forKey: .redirectHTTPToHTTPS)) ?? true
        // Eski kayıtlarda alan yok → nil (platform varsayılanı kullanılır)
        appCommand           = try? c.decodeIfPresent(String.self, forKey: .appCommand)
        buildCommand         = try? c.decodeIfPresent(String.self, forKey: .buildCommand)
        // Eski kayıtlarda alan yok → nil
        envVars          = try? c.decodeIfPresent([String: String].self, forKey: .envVars)
        // Eski kayıtlarda alan yok → nil (varsayılan ~/Sites/{name})
        customDocumentRoot = try? c.decodeIfPresent(String.self, forKey: .customDocumentRoot)
        // Eski kayıtlarda alan yok → etkin (varsayılan true)
        isEnabled        = (try? c.decode(Bool.self, forKey: .isEnabled)) ?? true
        spaFallback      = (try? c.decode(Bool.self, forKey: .spaFallback)) ?? false
        // Python ayarları — eski kayıtlarda yok → venv açık (varsayılan)
        pythonUseVenv    = (try? c.decode(Bool.self, forKey: .pythonUseVenv))    ?? true
        // Proxy ayarları — eski kayıtlarda yok → güvenli varsayılanlar
        websocketEnabled = (try? c.decode(Bool.self, forKey: .websocketEnabled)) ?? true
        http2Enabled     = (try? c.decode(Bool.self, forKey: .http2Enabled))     ?? false
        sseEnabled       = (try? c.decode(Bool.self, forKey: .sseEnabled))       ?? false
        grpcEnabled      = (try? c.decode(Bool.self, forKey: .grpcEnabled))      ?? false
        maxBodySize      = try? c.decodeIfPresent(String.self, forKey: .maxBodySize)
        serviceDependencies = try? c.decodeIfPresent([String].self, forKey: .serviceDependencies)
    }
}

// MARK: - Lossy Decodable

/// Tek bir elemanın decode'u başarısız olsa bile listenin tamamını düşürmeyen sarmalayıcı.
/// Bozuk eleman `value == nil` olur; init asla throw etmez → dizi decode'u devam eder.
private struct LossyDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

// MARK: - Domain List

/// Domain listesi wrapper (JSON kaydetme için)
struct DomainList: Codable {
    var domains: [Domain]
    var lastUpdated: Date
    /// Decode sırasında çözülemeyip atlanan kayıt sayısı (JSON'a yazılmaz).
    /// >0 ise çağıran taraf domains.json'u yedeklemeli — aksi halde atlanan kayıtlar
    /// sonraki kaydetmede kalıcı olarak silinir.
    var droppedCount: Int = 0

    enum CodingKeys: String, CodingKey { case domains, lastUpdated }

    init(domains: [Domain] = []) {
        self.domains      = domains
        self.lastUpdated  = Date()
        self.droppedCount = 0
    }

    /// Kayıp-toleranslı decode: bozuk/eski formatlı TEK bir domain kaydı, geri kalan tüm
    /// kayıtların yüklenmesini engellemez. Aksi halde bir kötü kayıt domains'i boşaltır ve
    /// sonraki kaydetme domains.json'u boş listeyle ezerek TÜM domainleri kaybettirir.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // KONTEYNER seviyesindeki bozukluk ('domains' anahtarı yok/null/dizi-değil) THROW
        // etmeli — çağıran (loadDomains) catch'e düşüp .corrupt.bak yedeğini alır.
        // Burada try? kullanmak domains=[] + droppedCount=0 üretir: yedek alınmaz ve
        // sonraki kaydetme dosyayı boş listeyle kalıcı ezerdi (sessiz toplu veri kaybı).
        // LossyDecodable eleman bazında zaten throw etmez; tolerans eleman seviyesindedir.
        let lossy = try c.decode([LossyDecodable<Domain>].self, forKey: .domains)
        domains      = lossy.compactMap { $0.value }
        droppedCount = lossy.count - domains.count
        lastUpdated  = (try? c.decode(Date.self, forKey: .lastUpdated)) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(domains, forKey: .domains)
        try c.encode(lastUpdated, forKey: .lastUpdated)
    }
}
