import Foundation

/// Site klasöründe saklanan .brampp.json yapılandırma dosyası.
/// Domain ayarları (port, başlatma/derleme komutları, ortam değişkenleri) burada tutulur.
/// Domain oluşturulduğunda/güncellendiğinde otomatik yazılır;
/// "JSON Yükle" butonu veya NSOpenPanel ile herhangi bir konumdan da okunabilir.
struct BRAMPPConfig: Codable {

    var appCommand:   String?
    var buildCommand: String?
    var port:         Int?
    var envVars:      [String: String]?

    // MARK: - Constants

    static let fileName = ".brampp.json"

    // MARK: - Read

    /// Site klasöründeki .brampp.json'u okur. Yoksa nil döner.
    static func read(from directory: String) -> BRAMPPConfig? {
        read(at: "\(directory)/\(fileName)")
    }

    /// Config okuma hataları — "JSON Yükle" gibi kullanıcı eylemlerinde geri bildirim için.
    enum ConfigError: LocalizedError {
        case fileNotFound(String)
        case invalidJSON(String)
        var errorDescription: String? {
            switch self {
            case .fileNotFound(let p): return "Dosya okunamadı: \(p)"
            case .invalidJSON(let m):  return "Geçersiz JSON: \(m)"
            }
        }
    }

    /// Herhangi bir yoldaki JSON dosyasını okur (NSOpenPanel seçimi için). Hata fırlatır —
    /// kullanıcıya "neden yüklenemedi" bilgisini vermek için.
    static func readThrowing(at path: String) throws -> BRAMPPConfig {
        guard let data = FileHelper.readData(path) else { throw ConfigError.fileNotFound(path) }
        do {
            return try JSONDecoder().decode(BRAMPPConfig.self, from: data)
        } catch {
            throw ConfigError.invalidJSON(error.localizedDescription)
        }
    }

    /// Sessiz varyant (otomatik/best-effort okumalar için) — hatayı yutar.
    static func read(at path: String) -> BRAMPPConfig? {
        try? readThrowing(at: path)
    }

    // MARK: - Write

    /// Belirtilen dizine .brampp.json yazar.
    @discardableResult
    func write(to directory: String) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return false }
        return FileHelper.write(data, to: "\(directory)/\(Self.fileName)")
    }

    // MARK: - Factory

    /// Domain modelinden BRAMPPConfig oluşturur.
    static func from(_ domain: Domain) -> BRAMPPConfig {
        BRAMPPConfig(
            appCommand:   domain.appCommand,
            buildCommand: domain.buildCommand,
            port:         domain.port,
            envVars:      domain.envVars?.isEmpty == false ? domain.envVars : nil
        )
    }

    // MARK: - Apply

    /// Mevcut domain'e config değerlerini uygular (nil alanlar dokunulmaz).
    func apply(to domain: inout Domain) {
        if let cmd = appCommand,   !cmd.isEmpty   { domain.appCommand   = cmd }
        if let cmd = buildCommand, !cmd.isEmpty   { domain.buildCommand = cmd }
        if let p   = port,          p > 0         { domain.port         = p   }
        if let env = envVars,      !env.isEmpty   { domain.envVars      = env }
    }
}
