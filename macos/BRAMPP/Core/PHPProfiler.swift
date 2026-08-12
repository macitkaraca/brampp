import Foundation

/// PHP profilleyici — Xdebug'ın profil kipini yönetir ve üretilen dosyaları listeler.
///
/// Kendi profilleyicimizi yazmıyoruz: Xdebug zaten eklenti kataloğunda ve ürettiği
/// cachegrind biçimi qcachegrind/KCachegrind ile okunabiliyor. Buradaki iş, elle
/// `php.ini` düzenlemeden bu kipi açıp kapatabilmek ve çıktıları bir yerde toplamak.
///
/// TETİKLEYİCİ KİPİ VARSAYILAN. `xdebug.mode=profile` tek başına HER isteği profiller;
/// birkaç dakikada yüzlerce megabayt dosya üretir ve siteyi gözle görülür yavaşlatır.
/// `start_with_request=trigger` ile yalnızca `XDEBUG_TRIGGER` gönderilen istekler
/// profillenir — geliştirici istediği isteği ölçer, gerisi normal hızda çalışır.
enum PHPProfiler {

    /// Profil çıktılarının toplandığı klasör.
    static var outputDir: String { "\(PathConfig.appSupport)/profiles" }

    /// `php.ini` içine yazılan blok. Başı ve sonu işaretli — kaldırırken bu işaretler
    /// kullanılır, kullanıcının kendi Xdebug ayarlarına dokunulmaz.
    static let beginMark = "; ── BRAMPP profiler: başlangıç ──"
    static let endMark   = "; ── BRAMPP profiler: bitiş ──"

    /// Yazılacak yapılandırma.
    ///
    /// - Parameter alwaysOn: `true` ise her istek profillenir. Varsayılan `false`:
    ///   yalnızca `XDEBUG_TRIGGER` taşıyan istekler ölçülür.
    static func iniBlock(alwaysOn: Bool = false) -> String {
        """
        \(beginMark)
        xdebug.mode = profile
        xdebug.output_dir = \(outputDir)
        xdebug.profiler_output_name = cachegrind.out.%t.%p
        xdebug.start_with_request = \(alwaysOn ? "yes" : "trigger")
        \(endMark)
        """
    }

    /// Bloğu içeriğe ekler ya da varsa günceller.
    static func applying(to content: String, alwaysOn: Bool) -> String {
        let stripped = removing(from: content)
        let sep = stripped.hasSuffix("\n") ? "" : "\n"
        return stripped + sep + "\n" + iniBlock(alwaysOn: alwaysOn) + "\n"
    }

    /// Bloğu içerikten çıkarır. İşaretler yoksa içerik aynen döner.
    ///
    /// Satır satır yürünür: düzenli ifadeyle çok satırlı silme, kullanıcının araya
    /// yazdığı satırları da yutabiliyordu.
    static func removing(from content: String) -> String {
        var out: [String] = []
        var inside = false
        for line in content.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == beginMark { inside = true; continue }
            if t == endMark   { inside = false; continue }
            if !inside { out.append(line) }
        }
        // Blok silindikten sonra kalan üçlü boş satırları ikiye indir
        var text = out.joined(separator: "\n")
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return text
    }

    /// İçerikte BRAMPP bloğu var mı?
    static func isEnabled(in content: String) -> Bool {
        content.contains(beginMark)
    }

    /// Blok her isteği mi profilliyor?
    /// YALNIZCA BRAMPP bloğunun içine bakılır.
    ///
    /// Tüm dosya taranıyordu: kullanıcının dosyanın başka bir yerindeki kendi
    /// `xdebug.start_with_request` satırı — bloğun ÜSTÜNDE olduğu için önce görülüp —
    /// paneli kilitliyordu. Anahtar açık görünüp kapanmıyor, kapalı görünüp açılmıyordu,
    /// çünkü panel bizim yazdığımız değeri değil kullanıcınınkini okuyordu.
    static func isAlwaysOn(in content: String) -> Bool {
        guard isEnabled(in: content) else { return false }
        var inside = false
        for line in content.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == beginMark { inside = true; continue }
            if t == endMark   { break }
            guard inside, t.hasPrefix("xdebug.start_with_request") else { continue }
            // Değer `=`in SAĞINDAN okunur: satırın herhangi bir yerinde "yes" aramak,
            // `; …yes demeyin` gibi bir yorumu değer sanardı.
            guard let eq = t.firstIndex(of: "=") else { continue }
            return t[t.index(after: eq)...]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
                .hasPrefix("yes")
        }
        return false
    }

    // MARK: - Çıktı dosyaları

    struct ProfileFile: Identifiable, Equatable {
        let name: String
        let path: String
        let bytes: Int
        let modified: Date
        var id: String { path }

        var sizeText: String {
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
    }

    /// `cachegrind.out.*` dosyalarını yeniden eskiye sıralar.
    static func profiles(in dir: String = outputDir) -> [ProfileFile] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return names
            .filter { $0.hasPrefix("cachegrind.out.") }
            .compactMap { name in
                let path = "\(dir)/\(name)"
                guard let a = try? fm.attributesOfItem(atPath: path) else { return nil }
                return ProfileFile(name: name, path: path,
                                   bytes: (a[.size] as? NSNumber)?.intValue ?? 0,
                                   modified: (a[.modificationDate] as? Date) ?? .distantPast)
            }
            .sorted { $0.modified > $1.modified }
    }

    /// Cachegrind okuyucusu kurulu mu? Yoksa dosya Finder'da gösterilir.
    static var viewerPath: String? {
        for p in ["\(PathConfig.brewBin)/qcachegrind", "/Applications/qcachegrind.app"]
        where FileHelper.exists(p) { return p }
        return nil
    }
}
