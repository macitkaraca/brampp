import SwiftUI

/// Platform tipleri
enum Platform: String, Codable, CaseIterable, Identifiable {
    case php = "php"
    case nodejs = "nodejs"
    case python = "python"
    case dotnet = "dotnet"
    case static_ = "static"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .php: return "PHP"
        case .nodejs: return "Node.js"
        case .python: return "Python"
        case .dotnet: return ".NET Core"
        case .static_: return "Static"
        }
    }
    
    /// Asset kataloğundaki özgün platform ikonu (emoji yerine).
    var assetName: String {
        switch self {
        case .php: return "platform-php"
        case .nodejs: return "platform-nodejs"
        case .python: return "platform-python"
        case .dotnet: return "platform-dotnet"
        case .static_: return "platform-static"
        }
    }

    var icon: String {
        switch self {
        case .php: return "🐘"
        case .nodejs: return "🟩"
        case .python: return "🐍"
        case .dotnet: return "🟣"
        case .static_: return "📄"
        }
    }
    
    var color: Color {
        switch self {
        case .php: return .indigo
        case .nodejs: return .green
        case .python: return .yellow
        case .dotnet: return .purple
        case .static_: return .gray
        }
    }
    
    var portRange: ClosedRange<Int>? {
        switch self {
        case .nodejs: return PathConfig.Ports.nodeRange
        case .python: return PathConfig.Ports.pythonRange
        case .dotnet: return PathConfig.Ports.dotnetRange
        default: return nil
        }
    }
}

// MARK: - PHP Versions

enum PHPVersion: String, Codable, CaseIterable, Identifiable {
    case v81 = "8.1"
    case v82 = "8.2"
    case v83 = "8.3"
    case v84 = "8.4"
    case v85 = "8.5"

    var id: String { rawValue }

    var displayName: String { "PHP \(rawValue)" }

    var port: Int { PathConfig.Ports.phpPort(version: rawValue) }

    var brewService: String { "php@\(rawValue)" }

    var isInstalled: Bool { PathConfig.isPHPInstalled(version: rawValue) }
}

// MARK: - Node Versions

enum NodeVersion: String, Codable, CaseIterable, Identifiable {
    case v18 = "18"
    case v20 = "20"
    case v22 = "22"

    var id: String { rawValue }

    var displayName: String { "Node.js \(rawValue)" }

    var brewPackage: String { "node@\(rawValue)" }

    var isInstalled: Bool { PathConfig.isNodeInstalled(version: rawValue) }

    /// Brew'daki node bin dizini — başlatma betiğinin PATH'ine eklenir
    var binDir: String { "\(PathConfig.brewBase)/opt/node@\(rawValue)/bin" }
}

// MARK: - Python Versions

enum PythonVersion: String, Codable, CaseIterable, Identifiable {
    case v310 = "3.10"
    case v311 = "3.11"
    case v312 = "3.12"
    case v313 = "3.13"
    case v314 = "3.14"

    var id: String { rawValue }

    var displayName: String { "Python \(rawValue)" }

    var brewPackage: String { "python@\(rawValue)" }

    var isInstalled: Bool { PathConfig.isPythonInstalled(version: rawValue) }

    /// Python binary dizini — PythonProcessManager tarafından PATH'e eklenir.
    /// libexec/bin varsa onu, yoksa bin'i döner (Brew 3.12+ libexec kullanır).
    var binDir: String { PathConfig.pythonOptBin(version: rawValue) }
}

// MARK: - Python Framework

enum PythonFramework: String, Codable, CaseIterable, Identifiable {
    case fastapi = "fastapi"
    case django = "django"
    case flask = "flask"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .fastapi: return "FastAPI"
        case .django: return "Django"
        case .flask: return "Flask"
        }
    }
    
    var serverCommand: String {
        switch self {
        case .fastapi: return "uvicorn main:app --host 127.0.0.1 --port {PORT} --reload"
        case .django: return "gunicorn {PROJECT}.wsgi:application -b 127.0.0.1:{PORT} --reload"
        case .flask: return "gunicorn app:app -b 127.0.0.1:{PORT} --reload"
        }
    }
    
    var packages: [String] {
        switch self {
        case .fastapi: return ["fastapi", "uvicorn"]
        case .django: return ["django", "gunicorn"]
        case .flask: return ["flask", "gunicorn"]
        }
    }

    /// Sunucuyu fiilen ÇALIŞTIRAN binary — "kurulu mu" kontrolü bunun üzerinde yapılmalı.
    /// packages.first framework KÜTÜPHANESİNİ verir (django/flask — bunların bin/'de
    /// çalıştırılabilir dosyası ya yoktur ya da sunucu değildir); yanlış kontrol Django'da
    /// her başlatmada gereksiz pip install tetikliyor, offline'da başlatmayı kırıyordu.
    var serverBinary: String {
        switch self {
        case .fastapi:        return "uvicorn"
        case .django, .flask: return "gunicorn"
        }
    }
}

// MARK: - .NET Versions

enum DotNetVersion: String, Codable, CaseIterable, Identifiable {
    case v7  = "7.0"
    case v8  = "8.0"
    case v9  = "9.0"
    case v10 = "10.0"

    var id: String { rawValue }

    var displayName: String { ".NET \(rawValue)" }

    /// Major sürüm numarası — brew paketi adına karşılık gelir (ör. "8" → dotnet@8)
    var majorVersion: String { rawValue.components(separatedBy: ".").first ?? rawValue }

    /// Sürüme özgü dotnet binary yolu
    var versionedBin: String { PathConfig.dotnetBin(majorVersion: majorVersion) }

    /// Çalışan dotnet binary — sürüme özgü varsa onu kullan, yoksa global brew dotnet
    var resolvedBin: String {
        FileHelper.exists(versionedBin) ? versionedBin : PathConfig.dotnet
    }

    /// ASP.NET Core target framework moniker — `dotnet new` ve `.csproj` için
    /// Ör: .v8 → "net8.0", .v10 → "net10.0"
    var frameworkMoniker: String { "net\(majorVersion).0" }

    /// Bu SÜRÜME ait dotnet binary kurulu mu?
    /// Yalnızca sürüme özgü binary'ye bakılır — aksi halde global `dotnet` kurulu olduğunda
    /// TÜM sürümler yanlışlıkla "kurulu" görünürdü. (Global dotnet çalıştırmada resolvedBin
    /// ile fallback olarak yine kullanılır; bu yalnızca "bu sürüm kurulu mu" raporlamasıdır.)
    var isInstalled: Bool {
        Shell.isBrewInstalled && FileHelper.exists(versionedBin)
    }
}

// MARK: - Web Server

/// Domain'in hangi web sunucusu tarafından servis edileceği.
/// Apache: :80 / :443 — Nginx: :8080 / :8443
enum WebServer: String, Codable, CaseIterable, Identifiable {
    case apache = "apache"
    case nginx  = "nginx"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apache: return "Apache"
        case .nginx:  return "Nginx"
        }
    }

    var color: Color {
        switch self {
        case .apache: return .orange
        case .nginx:  return .green
        }
    }

    /// HTTP dinleme portu
    var httpPort: Int  { self == .apache ? 80   : 8080 }
    /// HTTPS dinleme portu
    var httpsPort: Int { self == .apache ? 443  : 8443 }

    /// Brew servis ID'si
    var brewServiceID: String { self == .apache ? "httpd" : "nginx" }

    /// SF Symbol adı — domain listesinde ikon olarak kullanılır
    var sfSymbol: String {
        switch self {
        case .apache: return "server.rack"
        case .nginx:  return "network"
        }
    }

    /// Platform'a göre önerilen varsayılan web sunucu
    /// Node.js, Python ve .NET için Nginx; PHP ve Static için Apache önerilir.
    static func recommended(for platform: Platform) -> WebServer {
        (platform == .dotnet || platform == .nodejs || platform == .python) ? .nginx : .apache
    }
}
