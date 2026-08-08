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
    static func normalized(_ input: String, version: String) -> String {
        var content = input

        let listenValue = "listen = 127.0.0.1:\(PathConfig.Ports.phpPort(version: version))"
        let userValue = "user = _www"
        let groupValue = "group = _www"
        let ownerValue = "listen.owner = _www"
        let listenGroupValue = "listen.group = _www"

        let lines = content.components(separatedBy: .newlines)
        var updatedLines: [String] = []

        var hasListen = false
        var hasUser = false
        var hasGroup = false
        var hasOwner = false
        var hasListenGroup = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("listen =") || trimmed.hasPrefix(";listen =") {
                updatedLines.append(listenValue)
                hasListen = true
                continue
            }

            if trimmed.hasPrefix("user =") || trimmed.hasPrefix(";user =") {
                updatedLines.append(userValue)
                hasUser = true
                continue
            }

            if trimmed.hasPrefix("group =") || trimmed.hasPrefix(";group =") {
                updatedLines.append(groupValue)
                hasGroup = true
                continue
            }

            if trimmed.hasPrefix("listen.owner =") || trimmed.hasPrefix(";listen.owner =") {
                updatedLines.append(ownerValue)
                hasOwner = true
                continue
            }

            if trimmed.hasPrefix("listen.group =") || trimmed.hasPrefix(";listen.group =") {
                updatedLines.append(listenGroupValue)
                hasListenGroup = true
                continue
            }

            updatedLines.append(line)
        }

        if !hasListen { updatedLines.append(listenValue) }
        if !hasUser { updatedLines.append(userValue) }
        if !hasGroup { updatedLines.append(groupValue) }
        if !hasOwner { updatedLines.append(ownerValue) }
        if !hasListenGroup { updatedLines.append(listenGroupValue) }

        content = updatedLines.joined(separator: "\n")
        return content
    }
}
