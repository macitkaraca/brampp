import Foundation

/// MCP araçlarının bir alana (domain / servis / veritabanı / log) erişim düzeyi.
///
/// Kural: yapay zekâ istemcisi izin verilmeyen aracı **hiç görmez** — `tools/list`
/// süzülür. Görmediği bir aracı yine de çağırırsa `tools/call` reddeder. İki katmanlı
/// olması bilinçli: liste süzme "yanlışlıkla denemeyi", çağrı denetimi "kasıtlı denemeyi" keser.
enum MCPPermission: String, Codable, CaseIterable, Identifiable {
    /// Alan tamamen kapalı — ne okuma ne yazma
    case none
    /// Yalnızca okuma (listeleme, durum sorgulama, log okuma)
    case read
    /// Okuma + değiştirme (oluşturma, silme, başlatma/durdurma)
    case write

    var id: String { rawValue }

    /// Ayarlar ekranında gösterilecek ad — çalışma zamanı diline uyar
    var displayName: String {
        switch self {
        case .none:  return Localizer.shared.t("set.mcp.perm.none")
        case .read:  return Localizer.shared.t("set.mcp.perm.read")
        case .write: return Localizer.shared.t("set.mcp.perm.write")
        }
    }

    /// Bu düzey okumaya izin veriyor mu?
    var allowsRead: Bool { self != .none }
    /// Bu düzey değiştirmeye izin veriyor mu?
    var allowsWrite: Bool { self == .write }

    /// Bilinmeyen/bozuk değerler en kısıtlayıcı düzeye düşer — ayar dosyası elle
    /// düzenlenip geçersiz bir değer yazılırsa erişim açılmamalı.
    static func parse(_ raw: String) -> MCPPermission {
        MCPPermission(rawValue: raw) ?? .none
    }
}

/// MCP araçlarının gruplandığı erişim alanları.
enum MCPScope: String, CaseIterable, Identifiable {
    case domains, services, databases, logs, sharing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .domains:   return Localizer.shared.t("set.mcp.scope.domains")
        case .services:  return Localizer.shared.t("set.mcp.scope.services")
        case .databases: return Localizer.shared.t("set.mcp.scope.databases")
        case .logs:      return Localizer.shared.t("set.mcp.scope.logs")
        case .sharing:   return Localizer.shared.t("set.mcp.scope.sharing")
        }
    }

    var icon: String {
        switch self {
        case .domains:   return "globe"
        case .services:  return "gearshape.2"
        case .databases: return "cylinder.split.1x2"
        case .logs:      return "doc.text"
        case .sharing:   return "antenna.radiowaves.left.and.right"
        }
    }

    /// Ayarlardaki geçerli düzey
    func permission(in settings: AppSettings) -> MCPPermission {
        switch self {
        case .domains:   return .parse(settings.mcpPermDomains)
        case .services:  return .parse(settings.mcpPermServices)
        case .databases: return .parse(settings.mcpPermDatabases)
        case .logs:      return .parse(settings.mcpPermLogs)
        case .sharing:   return .parse(settings.mcpPermSharing)
        }
    }

    /// Ayarlarda düzeyi günceller
    func apply(_ level: MCPPermission, to settings: inout AppSettings) {
        switch self {
        case .domains:   settings.mcpPermDomains   = level.rawValue
        case .services:  settings.mcpPermServices  = level.rawValue
        case .databases: settings.mcpPermDatabases = level.rawValue
        case .logs:      settings.mcpPermLogs      = level.rawValue
        case .sharing:   settings.mcpPermSharing   = level.rawValue
        }
    }
}
