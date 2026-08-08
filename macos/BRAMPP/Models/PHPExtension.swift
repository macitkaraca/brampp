import SwiftUI

/// PHP Extension kategorileri
enum ExtensionCategory: String, CaseIterable, Identifiable {
    case image = "image"
    case database = "database"
    case debug = "debug"
    case cache = "cache"
    case crypto = "crypto"
    case format = "format"
    case network = "network"
    case utility = "utility"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .image: return "Görsel İşleme"
        case .database: return "Veritabanı"
        case .debug: return "Debug & Profiling"
        case .cache: return "Cache"
        case .crypto: return "Güvenlik & Crypto"
        case .format: return "Dosya Formatları"
        case .network: return "Network & API"
        case .utility: return "Utility"
        }
    }
    
    var icon: String {
        switch self {
        case .image: return "🖼️"
        case .database: return "🗄️"
        case .debug: return "🐛"
        case .cache: return "📦"
        case .crypto: return "🔐"
        case .format: return "📄"
        case .network: return "🌐"
        case .utility: return "🔧"
        }
    }
}

/// PHP Extension modeli
struct PHPExtension: Identifiable {
    let id: String
    let name: String
    let description: String
    let category: ExtensionCategory
    let isBuiltIn: Bool
    let dependency: String?
    var isInstalled: Bool
    var isEnabled: Bool
    var version: String?
    var configFile: String?
    
    init(
        name: String,
        description: String,
        category: ExtensionCategory,
        isBuiltIn: Bool = false,
        dependency: String? = nil,
        isInstalled: Bool = false,
        isEnabled: Bool = false,
        version: String? = nil
    ) {
        self.id = name
        self.name = name
        self.description = description
        self.category = category
        self.isBuiltIn = isBuiltIn
        self.dependency = dependency
        self.isInstalled = isInstalled
        self.isEnabled = isEnabled
        self.version = version
        self.configFile = isBuiltIn ? nil : "ext-\(name).ini"
    }
    
    /// Kurulum komutu
    var installCommand: String? {
        if isBuiltIn { return nil }
        return "pecl install \(name)"
    }
    
    /// Bağımlılık kurulum komutu
    var dependencyInstallCommand: String? {
        guard let dep = dependency else { return nil }
        return "brew install \(dep)"
    }
}

// MARK: - Default Extensions

extension PHPExtension {
    
    /// Popüler extension listesi
    static let popularExtensions: [PHPExtension] = [
        // Görsel İşleme
        PHPExtension(
            name: "imagick",
            description: "ImageMagick binding for PHP",
            category: .image,
            dependency: "imagemagick"
        ),
        PHPExtension(
            name: "gd",
            description: "GD Graphics Library",
            category: .image,
            isBuiltIn: true
        ),
        PHPExtension(
            name: "exif",
            description: "EXIF metadata okuma",
            category: .image,
            isBuiltIn: true
        ),
        
        // Veritabanı
        PHPExtension(
            name: "pdo_mysql",
            description: "MySQL PDO driver",
            category: .database,
            isBuiltIn: true
        ),
        PHPExtension(
            name: "mysqli",
            description: "MySQL Improved",
            category: .database,
            isBuiltIn: true
        ),
        PHPExtension(
            name: "pdo_pgsql",
            description: "PostgreSQL PDO driver",
            category: .database,
            isBuiltIn: true
        ),
        PHPExtension(
            name: "pgsql",
            description: "PostgreSQL native driver",
            category: .database,
            isBuiltIn: true
        ),
        PHPExtension(
            name: "redis",
            description: "PHP extension for Redis",
            category: .database
        ),
        PHPExtension(
            name: "mongodb",
            description: "MongoDB driver",
            category: .database
        ),
        
        // Debug
        PHPExtension(
            name: "xdebug",
            description: "Debugger and Profiler",
            category: .debug
        ),
        PHPExtension(
            name: "pcov",
            description: "Code coverage driver",
            category: .debug
        ),
        
        // Cache
        PHPExtension(
            name: "opcache",
            description: "Zend OPcache",
            category: .cache,
            isBuiltIn: true
        ),
        PHPExtension(
            name: "apcu",
            description: "APC User Cache",
            category: .cache
        ),
        PHPExtension(
            name: "memcached",
            description: "Memcached client",
            category: .cache,
            dependency: "libmemcached"
        ),
        
        // Crypto
        PHPExtension(
            name: "openssl",
            description: "OpenSSL functions",
            category: .crypto,
            isBuiltIn: true
        ),
        PHPExtension(
            name: "sodium",
            description: "Modern cryptography",
            category: .crypto,
            isBuiltIn: true
        ),
        
        // Format
        PHPExtension(
            name: "zip",
            description: "ZIP archive support",
            category: .format,
            isBuiltIn: true
        ),
        PHPExtension(
            name: "xml",
            description: "XML processing",
            category: .format,
            isBuiltIn: true
        ),
        PHPExtension(
            name: "json",
            description: "JSON support",
            category: .format,
            isBuiltIn: true
        ),
        PHPExtension(
            name: "yaml",
            description: "YAML parser",
            category: .format
        ),
        
        // Network
        PHPExtension(
            name: "curl",
            description: "cURL library",
            category: .network,
            isBuiltIn: true
        ),
        PHPExtension(
            name: "soap",
            description: "SOAP client/server",
            category: .network
        ),
        PHPExtension(
            name: "sockets",
            description: "Low-level sockets",
            category: .network,
            isBuiltIn: true
        ),
        
        // Utility
        PHPExtension(
            name: "intl",
            description: "Internationalization",
            category: .utility,
            isBuiltIn: true
        ),
        PHPExtension(
            name: "mbstring",
            description: "Multibyte String",
            category: .utility,
            isBuiltIn: true
        ),
        PHPExtension(
            name: "bcmath",
            description: "Arbitrary precision math",
            category: .utility,
            isBuiltIn: true
        ),
    ]
}

// MARK: - PHP INI Settings

struct PHPIniSetting: Identifiable {
    let id: String
    let name: String
    let description: String
    let options: [String]
    var currentValue: String
    
    init(name: String, description: String, options: [String], defaultValue: String) {
        self.id = name
        self.name = name
        self.description = description
        self.options = options
        self.currentValue = defaultValue
    }
}

extension PHPIniSetting {
    
    /// Yaygın php.ini ayarları
    static let commonSettings: [PHPIniSetting] = [
        PHPIniSetting(
            name: "memory_limit",
            description: "Maksimum bellek kullanımı",
            options: ["128M", "256M", "512M", "1G", "2G"],
            defaultValue: "256M"
        ),
        PHPIniSetting(
            name: "max_execution_time",
            description: "Maksimum çalışma süresi (saniye)",
            options: ["30", "60", "120", "300", "0"],
            defaultValue: "30"
        ),
        PHPIniSetting(
            name: "upload_max_filesize",
            description: "Maksimum dosya yükleme boyutu",
            options: ["2M", "32M", "64M", "128M", "512M"],
            defaultValue: "64M"
        ),
        PHPIniSetting(
            name: "post_max_size",
            description: "Maksimum POST boyutu",
            options: ["8M", "32M", "64M", "128M", "512M"],
            defaultValue: "64M"
        ),
        PHPIniSetting(
            name: "display_errors",
            description: "Hataları göster (Development)",
            options: ["On", "Off"],
            defaultValue: "On"
        ),
        PHPIniSetting(
            name: "error_reporting",
            description: "Hata raporlama seviyesi",
            options: ["E_ALL", "E_ALL & ~E_NOTICE", "E_ALL & ~E_NOTICE & ~E_DEPRECATED"],
            defaultValue: "E_ALL"
        ),
        PHPIniSetting(
            name: "date.timezone",
            description: "Varsayılan zaman dilimi",
            options: ["Europe/Istanbul", "UTC", "Europe/London", "America/New_York"],
            defaultValue: "Europe/Istanbul"
        ),
    ]
}
