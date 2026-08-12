import Foundation

/// GitHub sürüm gövdesini (Markdown'ımsı metin) okunabilir bloklara ayırır.
///
/// NEDEN SATIR SATIR, tek bir `AttributedString(markdown:)` çağrısı yerine:
/// tam belge kipi satır sonlarını birleştirir ve madde imlerini düşürür — sürüm
/// notu tek bir kalabalık paragrafa dönüşür, ki bu HAM metinden bile kötü okunur.
/// Blok yapısı burada üretilir, satır İÇİ biçimlendirme (kalın, kod, bağlantı)
/// sistem çözümleyicisine bırakılır.
///
/// TAMAMEN SAF: ağ yok, dosya yok, `@MainActor` bağımlılığı yok — doğrudan test edilir.
enum UpdateNotes {

    enum Block: Equatable {
        case heading(String)
        case bullet(AttributedString)
        case paragraph(AttributedString)
        case rule
    }

    /// Varsayılan üst sınır. Notlar BİZİM yazdığımız metindir ama uygulamanın
    /// içine ağdan giren, sabit boyutlu bir pencerede çizilen metindir; sınırsız
    /// bırakmak için bir neden yok. Kesme SATIR SINIRINDA yapılır ki yarım kalmış
    /// bir Markdown satırı tuhaf biçimlenmesin.
    static let defaultLimit = 20_000

    /// - Returns: çizilecek bloklar ve metnin kısaltılıp kısaltılmadığı.
    static func render(_ raw: String, limit: Int = defaultLimit) -> (blocks: [Block], truncated: Bool) {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var text = normalized
        var truncated = false
        if text.count > limit {
            let cut = text.index(text.startIndex, offsetBy: limit)
            let head = String(text[..<cut])
            text = head.lastIndex(of: "\n").map { String(head[..<$0]) } ?? head
            truncated = true
        }

        var blocks: [Block] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Boş satırlar blok ÜRETMEZ — arka arkaya kaç tane olursa olsun
            // aralarındaki boşluk yığın aralığından gelir, boş paragraflardan değil.
            if line.isEmpty { continue }

            if isRule(line) { blocks.append(.rule); continue }

            if let heading = headingText(line) {
                blocks.append(.heading(heading))
                continue
            }

            if let item = bulletText(line) {
                blocks.append(.bullet(inline(item)))
                continue
            }

            blocks.append(.paragraph(inline(line)))
        }
        return (blocks, truncated)
    }

    // MARK: - Satır sınıflandırma (saf)

    /// `---`, `***`, `___` — üç ya da daha fazla, tek karakterden oluşan ayraç satırı.
    static func isRule(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        for ch in ["-", "*", "_"] where line.allSatisfy({ String($0) == ch }) { return true }
        return false
    }

    /// `#`–`######` + boşluk. Diyez sayısı görsel hiyerarşiye yansıtılMAZ:
    /// sürüm notlarında başlık düzeyleri tutarsızdır, hepsi aynı ağırlıkta çizilir.
    static func headingText(_ line: String) -> String? {
        let hashes = line.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        let title = rest.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    /// `- `, `* `, `+ ` ve `1. ` biçimleri. İşaretin kendisi düşürülür — madde
    /// imini görünümdeki `•` çizer, iki im üst üste binmesin.
    static func bulletText(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            let rest = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        // Numaralı madde: "12. metin"
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let afterDigits = line.dropFirst(digits.count)
        guard afterDigits.hasPrefix(". ") else { return nil }
        let rest = afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    // MARK: - Satır içi biçimlendirme

    /// `**kalın**`, `` `kod` ``, `[metin](adres)` — yalnızca satır İÇİ sözdizimi.
    /// Çözümleme hata verirse metin OLDUĞU GİBİ gösterilir; bir sürüm notu
    /// bozuk Markdown yüzünden kaybolmamalı.
    static func inline(_ line: String) -> AttributedString {
        var attributed: AttributedString
        if let parsed = try? AttributedString(
            markdown: line,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            attributed = parsed
        } else {
            attributed = AttributedString(line)
        }
        stripUnsafeLinks(&attributed)
        return attributed
    }

    /// `http`/`https` DIŞINDAKİ her bağlantıyı tıklanamaz hâle getirir.
    ///
    /// Bu metin uygulamanın DIŞINDA yazılmış ve ağdan gelmiştir. Bir `file://`
    /// ya da özel şemalı bağlantının kullanıcının tek tıklamasıyla açılabilmesi,
    /// sürüm notunu küçük bir eylem yüzeyine çevirirdi. Metin kalır, bağlantılığı gider.
    static func stripUnsafeLinks(_ attributed: inout AttributedString) {
        var unsafe: [Range<AttributedString.Index>] = []
        for run in attributed.runs {
            guard let link = run.link else { continue }
            let scheme = link.scheme?.lowercased() ?? ""
            if scheme != "http", scheme != "https" { unsafe.append(run.range) }
        }
        for range in unsafe { attributed[range].link = nil }
    }

    /// Bloklardaki düz metin — testler ve erişilebilirlik için.
    static func plainText(_ blocks: [Block]) -> String {
        blocks.map { block in
            switch block {
            case .heading(let t):   return t
            case .bullet(let a):    return String(a.characters)
            case .paragraph(let a): return String(a.characters)
            case .rule:             return "—"
            }
        }.joined(separator: "\n")
    }
}
