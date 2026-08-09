import Foundation

// MARK: - Console Entry

/// Konsol satırı — Tüm manager'lar tarafından paylaşılır.
struct ConsoleEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let type: ConsoleEntryType
    /// Anahtarsız satırın ham metni (brew çıktısı, shell stderr…).
    /// `key` doluysa yalnızca log ANINDA çözülmüş yedek metindir — gösterimde
    /// `text` kullanılmalıdır (bkz. Core/L10nLog.swift).
    let message: String
    /// Çeviri anahtarı (`log.<alan>.<eylem>`); nil ise satır dinamiktir.
    let key: String?
    /// Anahtarın `%@` yer tutucularına SIRAYLA yerleşen argümanlar.
    let args: [String]

    init(timestamp: Date,
         type: ConsoleEntryType,
         message: String,
         key: String? = nil,
         args: [String] = []) {
        self.timestamp = timestamp
        self.type = type
        self.message = message
        self.key = key
        self.args = args
    }

    /// Statik DateFormatter — her çağrıda yeni instance oluşturmaz.
    private static let timeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt
    }()

    var formattedTime: String {
        Self.timeFormatter.string(from: timestamp)
    }
}

// MARK: - Console Entry Type

enum ConsoleEntryType {
    case info, success, warning, error, command
    /// Brew indirme çubuğu gibi in-place güncellenen satır
    case progress

    var icon: String {
        switch self {
        case .info:     return "ℹ️"
        case .success:  return "✅"
        case .warning:  return "⚠️"
        case .error:    return "❌"
        case .command:  return "▶️"
        case .progress: return "⬇️"
        }
    }

    /// Log dosyasındaki düzey etiketi. Emoji DEĞİL: dosya `grep` ile süzülüyor ve
    /// MCP `read_log` bu etikete göre filtreliyor.
    var logLabel: String {
        switch self {
        case .info:     return "INFO"
        case .success:  return "OK"
        case .warning:  return "WARN"
        case .error:    return "ERROR"
        case .command:  return "CMD"
        case .progress: return "PROGRESS"
        }
    }
}
