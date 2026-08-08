import Foundation

/// `redis-cli INFO` çıktısının ayrıştırılmış hâli.
///
/// Ayrıştırma saf bir fonksiyondur (`parse`) — kabuk çağrısından ayrı tutuldu ki
/// doğrudan test edilebilsin. INFO çıktısı `#` ile başlayan bölüm başlıkları ve
/// `anahtar:değer` satırlarından oluşur; sürümler arası alan EKLENİR, çıkarılmaz,
/// bu yüzden bilinmeyen alanlar sessizce yok sayılır.
struct RedisStats: Equatable {
    var version: String?
    var uptimeSeconds: Int?
    var connectedClients: Int?
    var usedMemory: String?          // "881.94K" — Redis'in kendi biçimi
    var peakMemory: String?
    var maxMemory: String?           // "0B" → sınırsız
    var commandsProcessed: Int?
    var keyspaceHits: Int?
    var keyspaceMisses: Int?
    var expiredKeys: Int?
    var evictedKeys: Int?
    /// Veritabanı numarası → (anahtar sayısı, süresi dolacak anahtar sayısı)
    var keyspace: [(db: Int, keys: Int, expires: Int)] = []

    static func == (l: RedisStats, r: RedisStats) -> Bool {
        l.version == r.version && l.uptimeSeconds == r.uptimeSeconds
            && l.connectedClients == r.connectedClients && l.usedMemory == r.usedMemory
            && l.keyspace.map(\.db) == r.keyspace.map(\.db)
            && l.keyspace.map(\.keys) == r.keyspace.map(\.keys)
    }

    /// Toplam anahtar sayısı (tüm veritabanları).
    var totalKeys: Int { keyspace.reduce(0) { $0 + $1.keys } }

    /// İsabet oranı. Hiç istek gelmediyse `nil` — 0/0'ı "%0 isabet" diye göstermek
    /// yanıltıcı olur, "henüz veri yok" demek doğrudur.
    var hitRate: Double? {
        guard let h = keyspaceHits, let m = keyspaceMisses, h + m > 0 else { return nil }
        return Double(h) / Double(h + m)
    }

    /// `maxmemory` 0 ise Redis sınırsız çalışır — bu geliştirme makinesinde normaldir.
    var isMemoryUnlimited: Bool {
        guard let m = maxMemory else { return false }
        return m.hasPrefix("0")
    }

    static func parse(_ info: String) -> RedisStats {
        var s = RedisStats()
        for raw in info.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let sep = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<sep])
            let val = String(line[line.index(after: sep)...])

            switch key {
            case "redis_version":            s.version = val
            case "uptime_in_seconds":        s.uptimeSeconds = Int(val)
            case "connected_clients":        s.connectedClients = Int(val)
            case "used_memory_human":        s.usedMemory = val
            case "used_memory_peak_human":   s.peakMemory = val
            case "maxmemory_human":          s.maxMemory = val
            case "total_commands_processed": s.commandsProcessed = Int(val)
            case "keyspace_hits":            s.keyspaceHits = Int(val)
            case "keyspace_misses":          s.keyspaceMisses = Int(val)
            case "expired_keys":             s.expiredKeys = Int(val)
            case "evicted_keys":             s.evictedKeys = Int(val)
            default:
                // "db0:keys=2,expires=2,avg_ttl=0,subexpiry=0"
                guard key.hasPrefix("db"), let n = Int(key.dropFirst(2)) else { continue }
                var keys = 0, expires = 0
                for pair in val.split(separator: ",") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    guard kv.count == 2, let num = Int(kv[1]) else { continue }
                    if kv[0] == "keys" { keys = num }
                    if kv[0] == "expires" { expires = num }
                }
                s.keyspace.append((db: n, keys: keys, expires: expires))
            }
        }
        s.keyspace.sort { $0.db < $1.db }
        return s
    }

    /// Çalışma süresini insan okunur biçime çevirir.
    static func formatUptime(_ seconds: Int) -> String {
        let d = seconds / 86400, h = (seconds % 86400) / 3600, m = (seconds % 3600) / 60
        if d > 0 { return "\(d)g \(h)s" }
        if h > 0 { return "\(h)s \(m)dk" }
        if m > 0 { return "\(m)dk" }
        return "\(seconds)sn"
    }
}
