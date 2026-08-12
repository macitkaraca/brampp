import Foundation

/// Konsol satırlarının diskteki kalıcı kopyası.
///
/// `ConsoleStore` yalnızca son 300 satırı bellekte tutar; `brew install` gibi gürültülü
/// tek bir işlem tamponu süpürebiliyor ve uygulama kapanınca geçmiş tamamen kayboluyordu.
/// Bu yüzden satırlar ayrıca günlük dönen dosyalara yazılır — böylece "on dakika önce ne
/// oldu" sorusu hem kullanıcı hem de MCP'nin `read_log` aracı için yanıtlanabilir olur.
///
/// Yazma ANA İŞ PARÇACIĞINDA YAPILMAZ: her konsol satırında diske gitmek arayüzü
/// kilitlerdi. Satırlar seri bir kuyrukta tamponlanıp toplu yazılır.
enum ConsoleLogFile {

    /// Bu tarihten eski günlük dosyalar açılışta silinir.
    static let retentionDays = 7

    private static let queue = DispatchQueue(label: "com.karaca.brampp.consolelog", qos: .utility)

    /// Dosya adındaki tarih — `console-2026-08-09.log`
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    /// Satır başındaki zaman damgası — saniye çözünürlüğü yeterli, ayrıştırması kolay.
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    static func fileURL(for date: Date) -> URL {
        URL(fileURLWithPath: PathConfig.logs)
            .appendingPathComponent("console-\(dayFormatter.string(from: date)).log")
    }

    /// Bir satırın dosyaya yazılacak hâli.
    ///
    /// Metin ÇÖZÜLMÜŞ yazılır (anahtar değil): dosya kendi başına, uygulama olmadan da
    /// okunabilir olmalı. Çok satırlı çıktılarda (brew, shell stderr) her fiziksel satır
    /// kendi zaman damgasını alır — aksi halde tarihe göre süzme bozulurdu.
    ///
    /// SATIR YAZAN SÜRECİ SÖYLER (`(app 1689)`): dosya adı yalnızca TARİHE bağlı olduğu
    /// için kurulu uygulama, Xcode derlemesi, XCTest ana uygulaması ve önizlemeler aynı
    /// dosyaya karışık yazar. Kimin yazdığı belli olmadığında dosya, çakışan iki kopyayı
    /// teşhis etmek için işe yaramaz hâle geliyordu — yaşanan tünel olayında tam olarak
    /// bu oldu. Etiket `ProcessRole.signature`'tan gelir ve süreç ömrü boyunca sabittir.
    static func format(date: Date, level: String, text: String,
                       process: String = ProcessRole.signature) -> String {
        let stamp = stampFormatter.string(from: date)
        let lines = text.components(separatedBy: .newlines)
        return lines.map { "\(stamp) [\(level)] (\(process)) \($0)" }.joined(separator: "\n") + "\n"
    }

    /// `.progress` YAZILMAZ — brew'un `####### %42` çubuğu saniyede onlarca satır üretir,
    /// bilgi taşımaz ve dosyayı kullanılamaz hâle getirir.
    static func shouldPersist(_ type: ConsoleEntryType) -> Bool {
        type != .progress
    }

    /// Satırı kuyruğa alır. Çağıran beklemez.
    static func append(date: Date, level: String, text: String) {
        let line = format(date: date, level: level, text: text)
        let url = fileURL(for: date)
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                try? fm.createDirectory(atPath: PathConfig.logs,
                                        withIntermediateDirectories: true)
                fm.createFile(atPath: url.path, contents: nil)
            }
            // Handle her yazımda açılıp kapanır: uygulama günlerce açık kalabilir ve
            // gün dönünce hedef dosya değişir; açık tutulan handle eski dosyaya yazardı.
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    /// `retentionDays` gününden eski `console-*.log` dosyalarını siler.
    ///
    /// Silinecek dosyalar ADINDAN çözülür, değiştirilme tarihinden değil: yedekten geri
    /// yüklenen ya da kopyalanan bir dosyanın mtime'ı bugünü gösterebilir.
    @discardableResult
    static func pruneOldFiles(now: Date = Date(), fileNames: [String]? = nil) -> [String] {
        let names = fileNames ?? FileHelper.contentsOfDirectory(PathConfig.logs)
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now)
        else { return [] }

        var removed: [String] = []
        for name in names {
            guard name.hasPrefix("console-"), name.hasSuffix(".log") else { continue }
            let stamp = String(name.dropFirst("console-".count).dropLast(".log".count))
            guard let day = dayFormatter.date(from: stamp) else { continue }
            if day < Calendar.current.startOfDay(for: cutoff) {
                removed.append(name)
                if fileNames == nil {
                    _ = FileHelper.remove("\(PathConfig.logs)/\(name)")
                }
            }
        }
        return removed
    }

    /// Son `days` günün dosyalarını eskiden yeniye birleştirip döner.
    /// MCP `read_log` aracının `source: "file"` dalı bunu kullanır.
    static func recentText(days: Int = 2, now: Date = Date()) -> String {
        var parts: [String] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = Calendar.current.date(byAdding: .day, value: -offset, to: now),
                  let text = FileHelper.readString(fileURL(for: day).path),
                  !text.isEmpty else { continue }
            parts.append(text)
        }
        return parts.joined()
    }
}
