import SwiftUI
import Combine

/// Merkezi konsol yönetimi — Tüm manager'lar buraya yazar.
/// ContentView'daki birleştirme + sıralama ihtiyacını ortadan kaldırır.
@MainActor
class ConsoleStore: ObservableObject {

    @Published private(set) var entries: [ConsoleEntry] = []

    private let maxEntries = 300
    private let trimTo = 200

    /// Konsola yeni satır yaz — ANAHTARSIZ (dinamik metin: brew çıktısı, shell stderr…).
    /// Çevrilebilir satırlar için `log(key:args:type:)` tercih edilmelidir.
    func log(_ message: String, type: ConsoleEntryType = .info) {
        append(ConsoleEntry(timestamp: Date(), type: type, message: message))
    }

    /// Konsola ÇEVRİLEBİLİR satır yaz — metin gösterim anında çözülür,
    /// böylece dil değişince GEÇMİŞ satırlar da yeni dile döner.
    /// Anahtar ve argüman kuralları: Core/L10nLog.swift.
    func log(key: String, args: [String] = [], type: ConsoleEntryType = .info) {
        // message: log anındaki çözülmüş metin. Yalnızca yedektir — anahtarı
        // okumayan tüketiciler (ör. MCP read_log) boş satır görmesin diye.
        let snapshot = L10n.renderLog(key: key, args: args)
        append(ConsoleEntry(timestamp: Date(), type: type, message: snapshot, key: key, args: args))
    }

    private func append(_ entry: ConsoleEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - trimTo)
        }
        persist(entry)
    }

    /// Satırı diskteki günlük dosyaya da yazar.
    ///
    /// Bellekteki tampon 300 satırda kesiliyor ve uygulama kapanınca siliniyor; kalıcı
    /// kopya olmadan ne kullanıcı ne de MCP'nin `read_log` aracı biraz öncesine
    /// bakabiliyordu. Yazma arka planda, `ConsoleLogFile` üzerinden.
    private func persist(_ entry: ConsoleEntry) {
        guard persistToFile, ConsoleLogFile.shouldPersist(entry.type) else { return }
        // `text` anahtarı ÇÖZER (dosya kendi başına okunabilir olmalı) ve @MainActor'dır —
        // bu yüzden çözme burada, ana iş parçacığında; yalnızca dosyaya yazma arka planda.
        ConsoleLogFile.append(date: entry.timestamp, level: entry.type.logLabel, text: entry.text)
    }

    /// Ayarlardan gelen anahtar. Her satırda `AppSettings.load()` çağırmamak için
    /// bir kez okunur; ayar değişince `SettingsView` bunu günceller.
    var persistToFile: Bool = AppSettings.load().persistConsoleLog

    /// İndirme çubuğu için son `.progress` satırını in-place günceller.
    /// Son satır `.progress` değilse yeni satır ekler.
    func logProgress(_ message: String) {
        if entries.last?.type == .progress {
            // Son satırı yerinde güncelle — brew ########## %100 animasyonu için
            entries[entries.count - 1] = ConsoleEntry(
                timestamp: entries[entries.count - 1].timestamp,
                type: .progress,
                message: message
            )
        } else {
            log(message, type: .progress)
        }
    }

    /// Konsolu temizle
    func clear() {
        entries.removeAll()
    }
}
