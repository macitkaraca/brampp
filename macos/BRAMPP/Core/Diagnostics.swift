import Foundation

/// Ortam teşhisi — "neden çalışmıyor" sorusunu tahmin ettirmeden yanıtlar.
///
/// BRAMPP zaten port sahipliğini, yapılandırma geçerliliğini ve güven deposunu ayrı ayrı
/// denetliyordu; bu tür bilgiler yalnızca bir işlem başarısız olduğunda, log satırı olarak
/// görünüyordu. Burada aynı denetimler önden ve topluca çalışır.
///
/// Yorumlama saf tutulur (`verdict`, `portConflict`): kabuk çağrılarından ayrı test edilir.
enum Diagnostics {

    enum Level: Int, Comparable {
        case pass, warn, fail
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        var icon: String {
            switch self {
            case .pass: return "checkmark.circle.fill"
            case .warn: return "exclamationmark.triangle.fill"
            case .fail: return "xmark.octagon.fill"
            }
        }
    }

    /// Tek bir bulgu.
    struct Finding: Identifiable, Equatable {
        let id: String
        let title: String
        let level: Level
        /// Ne bulunduğu — teknik ve somut, "bir sorun var" değil.
        let detail: String
        /// Kullanıcının atabileceği adım. Yoksa nil.
        let remedy: String?
    }

    // MARK: - Saf yorumlama

    /// Bir portu kimin dinlediğine bakarak karar verir.
    ///
    /// `expected` bizim beklediğimiz süreç adı (httpd, nginx…). Dinleyen başka bir şeyse
    /// bu, "servis başlamıyor" şikâyetlerinin en yaygın sebebi — ve tek başına
    /// "port kullanımda" demek yetmez, KİMİN kullandığı söylenmeli.
    static func portConflict(port: Int,
                             expectedProcess: String,
                             actualProcess: String?,
                             actualPID: Int?) -> Finding {
        let id = "port-\(port)"
        let title = "Port \(port)"
        guard let actual = actualProcess, !actual.isEmpty else {
            return Finding(id: id, title: title, level: .pass,
                           detail: "boşta — \(expectedProcess) başlatıldığında kullanacak",
                           remedy: nil)
        }
        // Süreç adı tam yol olabilir (/opt/homebrew/bin/nginx) — son bileşene bak.
        let name = (actual as NSString).lastPathComponent
        if name.contains(expectedProcess) || expectedProcess.contains(name) {
            return Finding(id: id, title: title, level: .pass,
                           detail: "\(name) dinliyor" + (actualPID.map { " (PID \($0))" } ?? ""),
                           remedy: nil)
        }
        return Finding(
            id: id, title: title, level: .fail,
            detail: "\(name)" + (actualPID.map { " (PID \($0))" } ?? "")
                  + " dinliyor — beklenen \(expectedProcess)",
            remedy: "\(expectedProcess) bu portu alamaz. Ya \(name) sürecini durdurun ya da "
                  + "\(expectedProcess) portunu Ayarlar'dan değiştirin.")
    }

    /// Yapılandırma testi çıktısını yorumlar.
    ///
    /// `apachectl configtest` ve `nginx -t` başarıyı FARKLI yazar ve ikisi de uyarıları
    /// stderr'e döker; çıkış kodu tek başına güvenilir değil.
    static func configVerdict(server: String, output: String, exitOK: Bool) -> Finding {
        let low = output.lowercased()
        let ok = exitOK || low.contains("syntax ok") || low.contains("syntax is ok")
        let id = "config-\(server.lowercased())"
        if ok {
            // Apache uyarıyı MODÜL ETİKETİYLE yazar — `[alias:warn]`, `[core:warn]` —
            // ve "warning" sözcüğü hiç geçmez. Yalnızca "warning" aramak, gerçek
            // uyarıları "sorun yok" diye raporlamamıza yol açıyordu. Nginx ise
            // `nginx: [warn]` biçimini kullanır.
            let warned = low.contains("warning") || low.contains(":warn]") || low.contains("[warn]")
            return Finding(id: id, title: "\(server) yapılandırması",
                           level: warned ? .warn : .pass,
                           detail: warned ? "geçerli, uyarı var" : "geçerli",
                           remedy: warned ? warningLine(in: output) : nil)
        }
        return Finding(id: id, title: "\(server) yapılandırması", level: .fail,
                       detail: firstLine(matching: "error", in: output)
                               ?? output.trimmingCharacters(in: .whitespacesAndNewlines)
                                        .components(separatedBy: "\n").first ?? "geçersiz",
                       remedy: "\(server) bu hâliyle başlamaz. Son eklenen alan adının vhost "
                             + "dosyasını gözden geçirin.")
    }

    /// `configtest` çıktısının tek satırlık ÖZETİ. `nil` → yapılandırma geçerli.
    ///
    /// Apache hatayı İKİ satıra böler ve sebep İKİNCİ satırdadır:
    ///
    ///     AH00526: Syntax error on line 144 of …/extra/httpd-ssl.conf:
    ///     SSLCertificateFile: file '…/server.crt' does not exist or is empty
    ///
    /// Yalnızca "error" geçen ilk satırı göstermek kullanıcıyı NEDEN'siz bırakır —
    /// hangi dosyanın eksik olduğu ikinci satırda yazar. Bu yüzden ikisi birlikte döner.
    static func configTestFailure(output: String, exitOK: Bool) -> String? {
        guard configVerdict(server: "Apache", output: output, exitOK: exitOK).level == .fail else {
            return nil
        }
        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Çıktısı olmayan bir başarısızlık da başarısızlıktır — nil dönmek "geçerli" demek olurdu.
        guard !lines.isEmpty else { return "apachectl configtest başarısız (çıktı yok)" }
        let start = lines.firstIndex { $0.lowercased().contains("error") } ?? 0
        return lines[start..<min(start + 2, lines.count)].joined(separator: " ")
    }

    /// Çıktıdaki ilk eşleşen satır — kullanıcıya tüm dökümü değil, ilgili satırı göster.
    static func firstLine(matching needle: String, in output: String) -> String? {
        output.components(separatedBy: .newlines)
            .first { $0.lowercased().contains(needle) }?
            .trimmingCharacters(in: .whitespaces)
    }

    /// İlk uyarı satırı — Apache'nin `[modül:warn]` ve Nginx'in `[warn]` biçimlerini
    /// birlikte tarar. Satırın başındaki zaman damgası ve PID atılır; kullanıcıya
    /// yararlı olan kısım mesajın kendisi.
    // MARK: - Alias sırası onarımı

    /// Bir companion yapılandırması ESKİ Alias sırasını mı taşıyor? SAF.
    ///
    /// Apache Alias'ları yazıldıkları sırada dener. Eğik çizgisiz olan (`/phpmyadmin`)
    /// eğik çizgilinin ÖNEKİDİR; önce yazılırsa ikincisi hiçbir zaman eşleşmez ve
    /// `configtest` AH00671 verir. Üretici 1.6'da düzeltildi ama DİSKTE duran dosyaya
    /// kimse dokunmadı: Mart'ta yazılmış bir dosya bugün de aynı uyarıyı üretiyor.
    /// Düzeltilen şey ile kullanıcının makinesindeki şey arasındaki fark tam olarak bu.
    ///
    /// Yalnızca gerçek yönerge satırları sayılır; yorumlar atlanır — şablonun kendi
    /// açıklaması `Alias` kelimesini geçiriyor ve sayılsaydı her dosya bozuk görünürdü.
    static func aliasOrderIsWrong(_ content: String, prefix: String) -> Bool {
        var bare = -1, slashed = -1
        for (i, raw) in content.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            if bare < 0,    line.hasPrefix("Alias \(prefix) ")  { bare = i }
            if slashed < 0, line.hasPrefix("Alias \(prefix)/ ") { slashed = i }
        }
        guard bare >= 0, slashed >= 0 else { return false }
        return bare < slashed
    }

    static func warningLine(in output: String) -> String? {
        guard let raw = output.components(separatedBy: .newlines).first(where: {
            let l = $0.lowercased()
            return l.contains("warning") || l.contains(":warn]") || l.contains("[warn]")
        }) else { return nil }
        // "[Mon Aug 10 …] [alias:warn] [pid 34128] AH00671: mesaj" → "AH00671: mesaj"
        if let last = raw.range(of: "] ", options: .backwards) {
            let tail = String(raw[last.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty { return tail }
        }
        return raw.trimmingCharacters(in: .whitespaces)
    }

    /// Bulguların genel özeti — en kötü seviye kazanır.
    static func summary(_ findings: [Finding]) -> Level {
        findings.map(\.level).max() ?? .pass
    }

    /// Gösterim sırası: önce sorunlar. Aynı seviyede özgün sıra korunur (kararlı sıralama).
    static func sorted(_ findings: [Finding]) -> [Finding] {
        findings.enumerated()
            .sorted { a, b in
                a.element.level == b.element.level ? a.offset < b.offset
                                                   : a.element.level > b.element.level
            }
            .map(\.element)
    }
}
