import Foundation

// MARK: - FileHelper

/// Güvenli dosya işlemleri.
/// FileManager.default çağrılarını try-catch ile sarar, çökmeyi önler.
struct FileHelper {

    private static let fm = FileManager.default

    // MARK: - Hata Yönlendirme

    /// Dosya işlem hatalarını uygulama konsoluna yönlendirir (AppState atar — Shell.verboseLogCallback deseni).
    /// nil ise hatalar yalnızca Xcode konsoluna `print` ile düşer ve kullanıcı hiç görmez.
    static var errorLogger: ((String) -> Void)?

    private static func reportError(_ msg: String) {
        print("⚠️ \(msg)")
        errorLogger?(msg)
    }

    // MARK: - Check
    
    /// Dosya/dizin var mı?
    static func exists(_ path: String) -> Bool {
        fm.fileExists(atPath: path)
    }
    
    // MARK: - Create
    
    /// Dizin oluştur (intermediate dahil). Varsa hiçbir şey yapmaz.
    /// - Returns: true = oluşturuldu veya zaten var, false = hata
    @discardableResult
    static func createDirectory(_ path: String) -> Bool {
        guard !fm.fileExists(atPath: path) else { return true }
        do {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            return true
        } catch {
            reportError("Dizin oluşturulamadı: \(path) — \(error.localizedDescription)")
            return false
        }
    }
    
    /// String içeriği dosyaya yaz
    /// - Returns: true = yazıldı, false = hata
    /// - Parameter encoding: Dosyanın ÖZGÜN kodlaması. Latin-1 bir config'i UTF-8 olarak
    ///   geri yazmak baytları değiştirir (Türkçe karakterler bozulur); düzenleme yollarında
    ///   `readStringDetailed`'in döndürdüğü kodlama buraya geçirilmelidir.
    @discardableResult
    static func write(_ content: String, to path: String, encoding: String.Encoding = .utf8) -> Bool {
        do {
            try content.write(toFile: path, atomically: true, encoding: encoding)
            return true
        } catch {
            reportError("Dosya yazılamadı: \(path) — \(error.localizedDescription)")
            return false
        }
    }
    
    /// Data'yı dosyaya atomik olarak yaz — kesinti anında dosya yarım/bozuk kalmaz
    /// (önce geçici dosyaya yazılır, sonra yer değiştirir). settings.json/domains.json için kritik.
    @discardableResult
    static func write(_ data: Data, to path: String) -> Bool {
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            reportError("Data yazılamadı: \(path) — \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - Read

    /// Okuma sonucu — "dosya yok" ile "dosya VAR ama okunamadı" ayrımı için.
    /// Config yamalayan fonksiyonlar bu ayrıma muhtaç: okunamayan dosyayı boş sayıp
    /// üzerine yazmak (örn. httpd.conf) tüm yapılandırmayı kalıcı olarak siler.
    enum ReadResult {
        /// Okunan metin + dosyanın GERÇEK kodlaması (geri yazarken korunmalı)
        case ok(String, encoding: String.Encoding)
        case missing
        case unreadable
    }

    /// Dosyayı ayrıntılı sonuçla oku. UTF-8 başarısızsa Latin-1 (eski Türkçe editör
    /// kodlaması) denenir — böylece tek bir legacy karakter dosyayı "okunamaz" yapmaz.
    ///
    /// ÖNEMLİ: Latin-1 256 bayt değerinin TAMAMINI eşler, yani içerik ne olursa olsun
    /// asla başarısız olmaz. Bu yüzden eskiden `.unreadable` dalı ÖLÜ kod durumundaydı:
    /// ikili (binary) ya da bozuk bir dosya bile "okundu" sayılıp UTF-8 olarak geri
    /// yazılıyor ve KALICI olarak bozuluyordu. Latin-1 denemesinden önce NUL baytına
    /// bakılarak ikili içerik elenir.
    static func readStringDetailed(_ path: String) -> ReadResult {
        guard fm.fileExists(atPath: path) else { return .missing }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return .unreadable }

        if let s = String(data: data, encoding: .utf8) { return .ok(s, encoding: .utf8) }
        if data.contains(0) { return .unreadable }   // NUL → metin dosyası değil
        if let s = String(data: data, encoding: .isoLatin1) { return .ok(s, encoding: .isoLatin1) }
        return .unreadable
    }

    /// Dosya içeriğini oku. Yoksa VEYA okunamıyorsa nil döner.
    /// Yıkıcı yazımdan önce ayrım gerekiyorsa `readStringDetailed` kullanın.
    static func readString(_ path: String) -> String? {
        if case .ok(let s, _) = readStringDetailed(path) { return s }
        return nil
    }
    
    /// Data olarak oku
    static func readData(_ path: String) -> Data? {
        guard fm.fileExists(atPath: path) else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }
    
    // MARK: - Delete
    
    /// Dosya/dizin sil. Yoksa sessizce geç.
    /// - Returns: true = silindi veya zaten yok, false = hata
    @discardableResult
    static func remove(_ path: String) -> Bool {
        guard fm.fileExists(atPath: path) else { return true }
        do {
            try fm.removeItem(atPath: path)
            return true
        } catch {
            reportError("Silinemedi: \(path) — \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - Copy

    /// Dosya kopyala (varsa üzerine yaz).
    /// Önce geçici ada kopyalanır, sonra `replaceItemAt` ile ATOMİK olarak yer değiştirilir —
    /// remove+move dizisinin aksine, değiştirme başarısız olsa bile mevcut hedef dosya kaybolmaz.
    @discardableResult
    static func copy(from: String, to: String) -> Bool {
        let tmp = to + ".tmp-\(UUID().uuidString.prefix(8))"
        do {
            try fm.copyItem(atPath: from, toPath: tmp)
            if fm.fileExists(atPath: to) {
                _ = try fm.replaceItemAt(URL(fileURLWithPath: to),
                                         withItemAt: URL(fileURLWithPath: tmp))
            } else {
                try fm.moveItem(atPath: tmp, toPath: to)
            }
            return true
        } catch {
            try? fm.removeItem(atPath: tmp)
            reportError("Kopyalanamadı: \(from) → \(to) — \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Move

    /// Dosya taşı
    @discardableResult
    static func move(from: String, to: String) -> Bool {
        do {
            try fm.moveItem(atPath: from, toPath: to)
            return true
        } catch {
            reportError("Taşınamadı: \(from) → \(to) — \(error.localizedDescription)")
            return false
        }
    }
    
    // MARK: - Directory List
    
    /// Dizin içindeki dosyaları listele. Hata varsa boş array döner.
    static func contentsOfDirectory(_ path: String) -> [String] {
        (try? fm.contentsOfDirectory(atPath: path)) ?? []
    }
    // MARK: - Text Patch Helpers
    
    /// İçerik belirtilen satırı içermiyorsa dosyanın sonuna ekler.
    /// - Satır bazlı TAM eşleşme kullanılır — alt-dize kontrolü "#IncludeOptional ..."
    ///   yorumunu "zaten var" sayıyor ve include hiç aktifleşmiyordu.
    /// - Yorumlanmış hâli varsa aktifleştirilir (başındaki # kaldırılır).
    /// - Dosya VAR ama okunamıyorsa ASLA üzerine yazılmaz (httpd.conf silinirdi) — false döner.
    @discardableResult
    static func appendLineIfMissing(_ line: String, to path: String) -> Bool {
        var content: String
        let enc: String.Encoding
        switch readStringDetailed(path) {
        case .ok(let s, let e): content = s; enc = e
        case .missing:          content = ""; enc = .utf8
        case .unreadable:
            reportError("Dosya okunamadı (bozuk kodlama?) — üzerine YAZILMADI: \(path)")
            return false
        }

        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        var lines = content.components(separatedBy: .newlines)

        // Aktif satır zaten var mı? (tam eşleşme)
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == trimmedLine }) {
            return true
        }

        // Yorumlanmış hâli varsa aktifleştir
        for i in lines.indices {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t == "#\(trimmedLine)" || t == "# \(trimmedLine)" {
                lines[i] = trimmedLine
                return write(lines.joined(separator: "\n"), to: path, encoding: enc)
            }
        }

        if !content.isEmpty, !content.hasSuffix("\n") {
            content += "\n"
        }
        content += line + "\n"
        return write(content, to: path, encoding: enc)
    }
    
    /// Yorum satırına alınmış veya eksik bir Apache LoadModule satırını aktif eder ya da ekler.
    /// Dosya VAR ama okunamıyorsa ASLA üzerine yazılmaz — httpd.conf'un yalnızca tek bir
    /// LoadModule satırıyla değiştirilip tüm yapılandırmanın silinmesini önler.
    @discardableResult
    static func ensureApacheModule(_ moduleName: String, loadPath: String, in configPath: String) -> Bool {
        var content: String
        let enc: String.Encoding
        switch readStringDetailed(configPath) {
        case .ok(let s, let e): content = s; enc = e
        case .missing:          content = ""; enc = .utf8
        case .unreadable:
            reportError("Config okunamadı (bozuk kodlama?) — üzerine YAZILMADI: \(configPath)")
            return false
        }
        let activeLine = "LoadModule \(moduleName) \(loadPath)"
        
        let lines = content.components(separatedBy: .newlines)
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == activeLine }) {
            return true
        }
        
        let linePrefixes = [
            "#LoadModule \(moduleName) ",
            "# LoadModule \(moduleName) ",
            "LoadModule \(moduleName) "
        ]
        
        var updatedLines: [String] = []
        var replaced = false
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if linePrefixes.contains(where: { trimmed.hasPrefix($0) }) {
                updatedLines.append(activeLine)
                replaced = true
            } else {
                updatedLines.append(line)
            }
        }
        
        if replaced {
            let updatedContent = updatedLines.joined(separator: "\n")
            return write(updatedContent, to: configPath, encoding: enc)
        }
        
        if !content.isEmpty, !content.hasSuffix("\n") {
            content += "\n"
        }
        content += activeLine + "\n"
        return write(content, to: configPath, encoding: enc)
    }
}
