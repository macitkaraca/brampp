import SwiftUI

/// Servis kategorileri
enum ServiceCategory: String, Codable, CaseIterable, Identifiable {
    case webServer = "webServer"
    case web = "web"
    case php = "php"
    case nodejs = "nodejs"
    case python = "python"
    case dotnet = "dotnet"
    case database = "database"
    case cache = "cache"

    var id: String { rawValue }

    /// Çevrilebilir kategoriler için katalog anahtarı (özel adlar — PHP-FPM, Node.js — çevrilmez)
    var l10nKey: String? {
        switch self {
        case .webServer: return "cat.webServer"
        case .database:  return "cat.database"
        default:         return nil
        }
    }

    var displayName: String {
        switch self {
        case .webServer: return "Web Sunucusu"
        case .web: return "Web"
        case .php: return "PHP-FPM"
        case .nodejs: return "Node.js"
        case .python: return "Python"
        case .dotnet: return ".NET Core"
        case .database: return "Veritabanı"
        case .cache: return "Cache"
        }
    }

    var icon: String {
        switch self {
        case .webServer: return "🌐"
        case .web: return "🌐"
        case .php: return "🐘"
        case .nodejs: return "🟩"
        case .python: return "🐍"
        case .dotnet: return "🟣"
        case .database: return "🗄️"
        case .cache: return "📦"
        }
    }
}

/// Servis tipi
enum ServiceType: String, Codable {
    case brewService = "brew"      // brew services run/stop (launchctl load/remove)
    case runtime = "runtime"       // Sadece kurulu/değil kontrolü (Node.js, Python, .NET)
}

/// Servis durumu
enum ServiceStatus: String {
    case running      = "started"
    case stopped      = "stopped"
    /// Runtime (Node.js, Python) kurulu ama "servis" olarak çalışmıyor — mavi gösterilir.
    case installed    = "installed"
    case notInstalled = "notInstalled"
    case unknown      = "unknown"

    var color: Color {
        switch self {
        case .running:      return .green
        case .stopped:      return .red
        case .installed:    return .blue
        case .notInstalled: return .gray
        case .unknown:      return .gray
        }
    }

    var icon: String {
        switch self {
        case .running:      return "checkmark.circle.fill"
        case .stopped:      return "xmark.circle.fill"
        case .installed:    return "checkmark.circle.fill"
        case .notInstalled: return "circle.dashed"
        case .unknown:      return "questionmark.circle"
        }
    }

    var displayName: String {
        // Sabit Türkçe metin EN arayüze sızıyordu — çalışma zamanı diline uyulur
        switch self {
        case .running:      return Localizer.shared.t("svc.running")
        case .stopped:      return Localizer.shared.t("svc.stopped")
        case .installed:    return Localizer.shared.t("svc.installed")
        case .notInstalled: return Localizer.shared.t("svc.notInstalled")
        case .unknown:      return Localizer.shared.t("svc.unknown")
        }
    }
}

/// Servis modeli
struct Service: Identifiable {
    let id: String
    let name: String
    let category: ServiceCategory
    let type: ServiceType
    let port: Int?
    let brewName: String?
    let installCommand: String?
    var status: ServiceStatus
    var version: String?
    var isLoading: Bool
    /// true → servis başlatıldı, port yanıtı bekleniyor (turuncu spinner)
    var isStarting: Bool
    /// true → durdurma komutu verildi, brew yanıtı bekleniyor (kırmızı spinner)
    var isStopping: Bool

    /// Başlatma/durdurma işlemi devam ediyor mu?
    /// Meşgul mü? Kurulum/kaldırma (isLoading) da MEŞGULDÜR: aksi halde brew uninstall
    /// sırasında light-refresh sahte "çöktü" bildirimi gönderir ve durumu ezer.
    var isBusy: Bool { isStarting || isStopping || isLoading }

    init(
        id: String,
        name: String,
        category: ServiceCategory,
        type: ServiceType,
        port: Int? = nil,
        brewName: String? = nil,
        installCommand: String? = nil,
        status: ServiceStatus = .unknown,
        version: String? = nil,
        isLoading: Bool = false,
        isStarting: Bool = false,
        isStopping: Bool = false
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.type = type
        self.port = port
        self.brewName = brewName ?? id
        self.installCommand = installCommand ?? "brew install \(brewName ?? id)"
        self.status = status
        self.version = version
        self.isLoading = isLoading
        self.isStarting = isStarting
        self.isStopping = isStopping
    }

    /// Port gösterimi (binlik ayraç olmadan)
    var portDisplay: String {
        if let port = port {
            return ":\(port)"
        }
        return ""
    }

    /// Runtime ise sadece kurulu kontrolü yapılır
    var isRuntimeOnly: Bool {
        type == .runtime
    }

    /// Start/Stop yapılabilir mi?
    var canToggle: Bool {
        type == .brewService
    }
}

// MARK: - Default Services

extension Service {

    /// Varsayılan servis listesi
    static let defaultServices: [Service] = [
        // Web Server
        Service(id: "httpd",  name: "Apache", category: .webServer, type: .brewService, port: 80),
        Service(id: "nginx",  name: "Nginx",  category: .webServer, type: .brewService, port: 8080),

        // PHP-FPM — varsayılan portlar (updatePortsFromConfig www.conf'tan okur ve override eder)
        Service(id: "php@8.1", name: "PHP 8.1", category: .php, type: .brewService, port: 9081),
        Service(id: "php@8.2", name: "PHP 8.2", category: .php, type: .brewService, port: 9082),
        Service(id: "php@8.3", name: "PHP 8.3", category: .php, type: .brewService, port: 9083),
        Service(id: "php@8.4", name: "PHP 8.4", category: .php, type: .brewService, port: 9084),
        // php@8.5 şu an brew'da "php" formülünün alias'ı — brew install/services alias'ı çözer,
        // launchd etiketi "homebrew.mxcl.php" olur (refreshStatus port fallback ile yakalar)
        Service(id: "php@8.5", name: "PHP 8.5", category: .php, type: .brewService, port: 9085),

        // Node.js
        Service(id: "node@18", name: "Node.js 18", category: .nodejs, type: .runtime, brewName: "node@18"),
        Service(id: "node@20", name: "Node.js 20", category: .nodejs, type: .runtime, brewName: "node@20"),
        Service(id: "node@22", name: "Node.js 22", category: .nodejs, type: .runtime, brewName: "node@22"),
        // Python runtime
        Service(id: "python@3.10", name: "Python 3.10", category: .python, type: .runtime, brewName: "python@3.10"),
        Service(id: "python@3.11", name: "Python 3.11", category: .python, type: .runtime, brewName: "python@3.11"),
        Service(id: "python@3.12", name: "Python 3.12", category: .python, type: .runtime, brewName: "python@3.12"),
        Service(id: "python@3.13", name: "Python 3.13", category: .python, type: .runtime, brewName: "python@3.13"),
        Service(id: "python@3.14", name: "Python 3.14", category: .python, type: .runtime, brewName: "python@3.14"),
        // .NET Core
        Service(id: "dotnet@7",  name: ".NET 7.0",  category: .dotnet, type: .runtime, brewName: "dotnet@7"),
        Service(id: "dotnet@8",  name: ".NET 8.0",  category: .dotnet, type: .runtime, brewName: "dotnet@8"),
        Service(id: "dotnet@9",  name: ".NET 9.0",  category: .dotnet, type: .runtime, brewName: "dotnet@9"),
        Service(id: "dotnet@10", name: ".NET 10.0", category: .dotnet, type: .runtime, brewName: "dotnet@10"),

        // Database
        Service(id: "mariadb", name: "MariaDB", category: .database, type: .brewService, port: 3306),
        Service(id: "postgresql@18", name: "PostgreSQL 18", category: .database, type: .brewService, port: 5432),
        Service(id: "postgresql@17", name: "PostgreSQL 17", category: .database, type: .brewService, port: 5433),
        Service(id: "postgresql@16", name: "PostgreSQL 16", category: .database, type: .brewService, port: 5434),

        // Cache
        Service(id: "redis", name: "Redis", category: .cache, type: .brewService, port: 6379),
        Service(id: "memcached", name: "Memcached", category: .cache, type: .brewService, port: 11211),
    ]
}
