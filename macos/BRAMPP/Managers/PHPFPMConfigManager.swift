//
//  PHPFPMConfigManager.swift
//  BRAMPP
//
//  Created by Macit Karaca on 7.03.2026.
//


//
//  PHPFPMConfigManager.swift
//  BRAMPP
//
//  Created by Macit Karaca on 7.03.2026.
//

import Foundation

// MARK: - ConfigFileEditor

/// Var olan bir config dosyasını OKU → DÖNÜŞTÜR → **aynı kodlamayla** geri yaz.
///
/// Neden gerekli: `readString` + `write` ikilisi dosyayı her zaman UTF-8 olarak geri yazar.
/// Latin-1 kodlanmış bir `php.ini` / `httpd.conf` (eski Türkçe editörlerin varsayılanı)
/// böyle yazılınca kullanıcının metni KALICI olarak bozulur. Ayrıca dosya VAR ama
/// okunamıyorsa (ikili/bozuk) üzerine ASLA yazılmaz — aksi halde tüm yapılandırma silinir.
enum ConfigFileEditor {

    enum Result: Equatable {
        /// Dönüştürülüp özgün kodlamayla yazıldı
        case written
        /// Dosya yok — çağıran karar verir (sıfırdan yazmak isteyebilir)
        case missing
        /// Dosya var ama metin olarak çözülemedi — DOKUNULMADI
        case unreadable
        /// Okundu ama yazılamadı (izin/disk)
        case writeFailed
    }

    /// - Parameter transform: mevcut içerikten yeni içeriği üretir
    @discardableResult
    static func patch(_ path: String, transform: (String) -> String) -> Result {
        switch FileHelper.readStringDetailed(path) {
        case .missing:
            return .missing
        case .unreadable:
            return .unreadable
        case .ok(let content, let encoding):
            return FileHelper.write(transform(content), to: path, encoding: encoding)
                ? .written : .writeFailed
        }
    }
}

enum PHPFPMConfigManager {
    static func phpVersion(from serviceID: String) -> String? {
        guard serviceID.hasPrefix("php@") else { return nil }
        return serviceID.replacingOccurrences(of: "php@", with: "")
    }

    @discardableResult
    static func normalize(for version: String) -> Bool {
        let wwwConfPath = PathConfig.phpFpmConf(version: version)

        // Dosyanın ÖZGÜN kodlaması korunur; okunamıyorsa üzerine YAZILMAZ
        // (Latin-1 bir www.conf UTF-8'e çevrilirse kullanıcının metni bozulurdu).
        return ConfigFileEditor.patch(wwwConfPath) { content in
            normalized(content, version: version)
        } == .written
    }

    /// `www.conf` içeriğini BRAMPP'ın beklediği listen/user/group değerlerine getirir.
    /// Saf metin dönüşümü — dosya sistemine dokunmaz (birim testten çağrılabilir).
    /// `www.conf` içeriğini BRAMPP'ın beklediği listen/user/group değerlerine getirir.
    /// Saf metin dönüşümü — dosya sistemine dokunmaz (birim testten çağrılabilir).
    ///
    /// YALNIZCA İLK HAVUZ BÖLÜMÜ yazılır. Eskiden dosyadaki HER `listen =` satırı aynı
    /// değere çevriliyordu: birden çok havuzu olan bir `www.conf`ta ([www] ve [site2])
    /// iki havuz aynı porta bağlanmaya çalışıyor ve php-fpm "Address already in use"
    /// ile HİÇ başlamıyordu. Eksik direktifler de dosyanın sonuna değil, o bölümün
    /// sonuna eklenir — sona eklenmiş bir `listen`, bir SONRAKİ havuza ait olurdu.
    static func normalized(_ input: String, version: String) -> String {
        let want: [(key: String, line: String)] = [
            ("listen",       "listen = 127.0.0.1:\(PathConfig.Ports.phpPort(version: version))"),
            ("user",         "user = _www"),
            ("group",        "group = _www"),
            ("listen.owner", "listen.owner = _www"),
            ("listen.group", "listen.group = _www"),
        ]

        var lines = input.components(separatedBy: .newlines)
        // İlk havuz başlığı `[www]` gibi bir satırdır; ondan önce global ayarlar olabilir.
        var start = 0
        var end = lines.count
        var seenHeader = false
        for (i, raw) in lines.enumerated() {
            let l = raw.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("["), l.hasSuffix("]") else { continue }
            if !seenHeader { seenHeader = true; start = i + 1 }
            else { end = i; break }          // İKİNCİ havuz başladı — dokunma
        }

        /// Satır bu direktifi mi tanımlıyor? `;` ve boşluk toleranslı, ad TAM eşleşmeli
        /// (`listen` ile `listen.owner` karışmasın).
        func defines(_ line: String, _ key: String) -> Bool {
            var s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix(";") { s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces) }
            guard let eq = s.firstIndex(of: "=") else { return false }
            return s[s.startIndex..<eq].trimmingCharacters(in: .whitespaces) == key
        }

        var found = Set<String>()
        for i in start..<end {
            for w in want where defines(lines[i], w.key) {
                lines[i] = w.line
                found.insert(w.key)
                break
            }
        }

        // Eksikler BÖLÜMÜN sonuna girer, dosyanın değil.
        let missing = want.filter { !found.contains($0.key) }.map(\.line)
        if !missing.isEmpty { lines.insert(contentsOf: missing, at: end) }

        return lines.joined(separator: "\n")
    }
}
