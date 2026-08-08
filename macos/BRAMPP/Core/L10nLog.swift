import Foundation

// ═══════════════════════════════════════════════════════════════════════════
//  KONSOL LOG YERELLEŞTİRME — DİĞER AJANLAR/GELİŞTİRİCİLER İÇİN KURALLAR
// ═══════════════════════════════════════════════════════════════════════════
//
//  Konsol satırları METİN olarak DEĞİL, ANAHTAR + ARGÜMAN olarak saklanır ve
//  metin GÖSTERİM anında çözülür. Böylece kullanıcı dili değiştirdiğinde
//  KONSOLDAKİ ESKİ SATIRLAR DA yeni dile döner.
//
//  1) ÇAĞRI BİÇİMİ
//     Eski:  log("Yedek silindi: \(ad)", type: .info)
//     Yeni:  log(key: "log.backup.deleted", args: [ad], type: .info)
//     Anahtarsız kalması GEREKENLER (brew çıktısı, shell stderr, ham komut
//     çıktısı gibi dinamik metinler) eski `log(_:type:)` ile geçmeye devam eder.
//
//  2) ANAHTAR BİÇİMİ:  log.<alan>.<eylem>       (eylem camelCase)
//     Alan ön ekleri — SADECE bunlar kullanılır:
//       log.svc.*     servisler (Apache, Nginx, MariaDB, Redis… başlat/durdur)
//       log.dom.*     domain işlemleri (oluştur/sil/vhost/SSL)
//       log.db.*      veritabanı işlemleri
//       log.php.*     PHP sürümleri ve eklentileri
//       log.backup.*  yedekleme / geri yükleme / içe-dışa aktarma
//       log.wiz.*     kurulum sihirbazı
//       log.mcp.*     MCP sunucusu
//       log.app.*     genel uygulama yaşam döngüsü
//     Her ajan YALNIZCA kendi alanının bölümüne ekleme yapar.
//
//  3) ARGÜMANLAR
//     - Yer tutucu SADECE `%@`. Sayılar da String'e çevrilip `%@` ile geçirilir
//       (`args: ["\(sayı)"]`). `%d` KULLANMA.
//     - Argümanlar `args` dizisindeki SIRAYLA yerleşir. TR ve EN metinlerinde
//       yer tutucu SAYISI aynı olmalı; sıra dilden dile değişebilir DEĞİL —
//       gerekirse cümleyi yeniden kur.
//     - Bir argümanın KENDİSİ de çevrilecekse başına `@` koyup anahtarını yaz:
//       `args: ["3", "@log.backup.labelApacheVhost"]`. `@` ile başlamayan her
//       argüman ham metindir (yol, dosya adı, hata mesajı…) ve çevrilmez.
//     - İÇ İÇE ARGÜMAN: çevrilecek argümanın KENDİSİ de `%@` alıyorsa elle
//       birleştirme (o metin log ANINDA donar, dil değişince eski dilde kalır).
//       Bunun yerine `L10n.logArg(key:_:)` ile kodla:
//         args: [L10n.logArg(key: "log.op.serviceStart", [service.name])]
//       Kodlama tek String taşır (anahtar + argümanlar, ayırıcı U+001F) ve
//       GÖSTERİM anında çözülür; böylece satırın DIŞ kalıbı da İÇ metni de
//       aynı dile döner. TEK DÜZEY iç içelik desteklenir.
//     - HAM metin `@` ile başlıyorsa (npm hatası "@scope/paket: …" gibi) sorun
//       çıkmaz: karşılığı hiçbir katalogda bulunamayan `@…` argümanı ham kabul
//       edilip OLDUĞU GİBİ bırakılır. Gerçekten var olan bir anahtarla birebir
//       çakışan ham metin için kaçış: başına ikinci bir `@` koy (`@@log.x.y`
//       → düz `@log.x.y`).
//
//  4) KATALOG
//     - TR ve EN karşılığı ZORUNLU; ikisi de yazılmadan anahtar eklenmez.
//     - AYNI ANAHTARI İKİ KEZ EKLEME → Swift sözlük değişmezinde yinelenen
//       anahtar UYGULAMAYI ÇALIŞMA ZAMANINDA ÇÖKERTİR. Eklemeden önce
//       `grep '"log\.<alan>\.<eylem>"'` ile denetle.
//     - Ana katalogla (`L10n.catalog`) çakışma sorun değildir; log araması
//       ÖNCE bu katalogu tarar.
//
//  5) GÖSTERİM
//     Konsolu çizen kod `entry.text` kullanır (`entry.message` DEĞİL).
//     `message` yalnızca anahtarsız satırlar ve log anındaki yedek metindir.
//     Çeviri için `Localizer.tLog(_:)` çağrılır; view'lardaki `loc.t(_:)`
//     ana katalogu tarar, log anahtarlarını BULMAZ.
//
//  REFERANS DÖNÜŞÜM: Managers/BackupRestoreManager.swift — örnek olarak alın.
// ═══════════════════════════════════════════════════════════════════════════

extension L10n {

    /// Konsol log satırları için AYRI katalog: anahtar → [dilKodu: metin].
    /// Ana `L10n.catalog`tan ayrı tutulur; arayüz metinleriyle karışmaz.
    static let logCatalog: [String: [String: String]] = [

        // ── log.backup.* — Yedekleme / geri yükleme ─────────────────────────
        "log.backup.dirCreateFailed":
            ["tr": "Yedek klasörü oluşturulamadı: %@",
             "en": "Could not create backup folder: %@"],
        "log.backup.domainsSaveFailed":
            ["tr": "domains.json yedeklenemedi",
             "en": "Could not back up domains.json"],
        "log.backup.settingsSaveFailed":
            ["tr": "settings.json yedeklenemedi",
             "en": "Could not back up settings.json"],
        "log.backup.nothingToBackup":
            ["tr": "Yedeklenecek dosya bulunamadı — boş yedek oluşturulmadı",
             "en": "No files to back up — empty backup was not created"],
        // %@1 = dosya sayısı, %@2 = tarih damgası
        "log.backup.created":
            ["tr": "Yedek oluşturuldu (%@ dosya): %@",
             "en": "Backup created (%@ files): %@"],
        "log.backup.partial":
            ["tr": "Yedek EKSİK alındı: %@ — geri yükleme listesine alınmadı",
             "en": "Backup is INCOMPLETE: %@ — not added to the restore list"],
        // %@1 = dizin adı, %@2 = hata açıklaması
        "log.backup.dirFailed":
            ["tr": "%@ yedeklenemedi: %@",
             "en": "Could not back up %@: %@"],
        "log.backup.domainsRestoreFailed":
            ["tr": "domains.json geri yüklenemedi",
             "en": "Could not restore domains.json"],
        "log.backup.settingsRestoreFailed":
            ["tr": "settings.json geri yüklenemedi",
             "en": "Could not restore settings.json"],
        "log.backup.hostsManual":
            ["tr": "ℹ️ /etc/hosts otomatik geri yüklenmez (yönetici izni gerekir) — yedekteki hosts-snapshot.txt dosyasından elle kopyalayabilirsiniz.",
             "en": "ℹ️ /etc/hosts is not restored automatically (administrator permission required) — you can copy it manually from hosts-snapshot.txt in the backup."],
        "log.backup.restored":
            ["tr": "Yedek geri yüklendi: %@",
             "en": "Backup restored: %@"],
        "log.backup.restartHint":
            ["tr": "Değişikliklerin geçerli olması için uygulamayı yeniden başlatın.",
             "en": "Restart the app for the changes to take effect."],
        // %@1 = tür etiketi (@log.backup.label*), %@2 = kaynak yol
        "log.backup.dirReadFailed":
            ["tr": "%@ dizini okunamadı: %@",
             "en": "Could not read the %@ directory: %@"],
        // %@1 = dosya sayısı, %@2 = tür etiketi (@log.backup.label*)
        "log.backup.filesRestored":
            ["tr": "%@ %@ dosyası geri yüklendi",
             "en": "Restored %@ %@ file(s)"],
        "log.backup.filesRestoreFailed":
            ["tr": "%@ %@ dosyası geri yüklenemedi",
             "en": "Could not restore %@ %@ file(s)"],
        "log.backup.deleted":
            ["tr": "Yedek silindi: %@",
             "en": "Backup deleted: %@"],
        "log.backup.exportNoDomains":
            ["tr": "Dışa aktarılacak domain bulunamadı",
             "en": "No domains found to export"],
        "log.backup.exported":
            ["tr": "Domainler dışa aktarıldı: %@",
             "en": "Domains exported: %@"],
        "log.backup.exportFailed":
            ["tr": "Dışa aktarma başarısız: %@",
             "en": "Export failed: %@"],
        "log.backup.imported":
            ["tr": "Domainler içe aktarıldı: %@",
             "en": "Domains imported: %@"],
        "log.backup.importFailed":
            ["tr": "İçe aktarma başarısız — geçerli bir BRAMPP domain dosyası mı? %@",
             "en": "Import failed — is this a valid BRAMPP domain file? %@"],

        // ── log.backup.label* — ARGÜMAN olarak geçirilen tür etiketleri ──────
        // Kullanım: args: ["3", "@log.backup.labelApacheVhost"]
        "log.backup.labelApacheVhost":
            ["tr": "Apache vhost", "en": "Apache vhost"],
        "log.backup.labelNginxSite":
            ["tr": "Nginx site", "en": "Nginx site"],
        "log.backup.labelSslCert":
            ["tr": "SSL sertifikası", "en": "SSL certificate"],
    ]

    // MARK: - Arama

    /// Log anahtarı araması: ÖNCE log katalogu, sonra ana katalog.
    /// (Localization.swift'e dokunmadan iki katalogu birleştiren tek nokta.)
    static func logEntry(for key: String) -> [String: String]? {
        logCatalog_service[key] ??      // ← ServiceManager katalogu (L10nLog+service.swift)
        logCatalog[key] ?? logCatalog_kalan[key] ?? logCatalog_dbPHP[key] ?? logCatalog_domain[key] ??
        logCatalog_base[key] ?? catalog[key]   // ← BaseManager ortak yardımcıları (L10nLog+base.swift)
    }

    // MARK: - Çözümleme

    /// Anahtar + argümanları geçerli dilde tek satıra çözer.
    /// - Parameter fallback: anahtar hiçbir katalogda yoksa kullanılacak ham metin.
    @MainActor
    static func renderLog(key: String, args: [String], fallback: String = "") -> String {
        guard let entry = logEntry(for: key) else {
            if !fallback.isEmpty { return fallback }
            #if DEBUG
            return "⟨\(key)⟩"   // eksik anahtar geliştirmede görünür olsun
            #else
            return key
            #endif
        }
        let code = Localizer.shared.code
        let format = entry[code] ?? entry["en"] ?? entry["tr"] ?? key
        guard !args.isEmpty else { return format }
        return substitute(format, args.map(resolveLogArg))
    }

    /// İç içe argüman kodlamasının ayırıcısı — UNIT SEPARATOR (U+001F).
    /// Görünür metinlerde asla bulunmaz, bu yüzden ham argümanları bozmaz.
    private static let argSeparator = "\u{1F}"

    /// Çevrilecek argümanı KENDİ argümanlarıyla birlikte tek String'e kodlar.
    /// Argümansız anahtarlar için `"@\(key)"` ile aynı sonucu verir.
    /// Çözüm GÖSTERİM anında yapılır → dil değişince iç metin de yeni dile döner.
    static func logArg(key: String, _ args: [String] = []) -> String {
        args.isEmpty ? "@\(key)" : (["@\(key)"] + args).joined(separator: argSeparator)
    }

    /// `@` ile başlayan argümanı katalogdan çevirir; diğerlerini olduğu gibi döndürür.
    /// `logArg(key:_:)` ile kodlanmış iç içe argümanlar kendi argümanlarıyla çözülür.
    @MainActor
    static func resolveLogArg(_ arg: String) -> String {
        guard arg.hasPrefix("@") else { return arg }
        // Kaçış: "@@…" → düz "@…" (ham metin gerçek bir anahtarla çakışıyorsa)
        if arg.hasPrefix("@@") { return String(arg.dropFirst()) }

        let parts = arg.components(separatedBy: argSeparator)
        let key = String(parts[0].dropFirst())
        // Anahtar hiçbir katalogda yoksa bu bir anahtar DEĞİL, `@` ile başlayan
        // ham metindir (npm paket adı, e-posta…) → dokunmadan geri ver.
        guard logEntry(for: key) != nil else { return arg }
        return renderLog(key: key, args: Array(parts.dropFirst()))
    }

    /// `%@` yer tutucularını SIRAYLA doldurur.
    /// `String(format:)` yerine elle yerleştirme: yer tutucu/argüman sayısı
    /// uyuşmazsa çökmek yerine kalanı olduğu gibi bırakır ve `%` içeren
    /// argümanlar (dosya yolları, hata metinleri) yanlış yorumlanmaz.
    private static func substitute(_ format: String, _ args: [String]) -> String {
        var out = format
        var searchStart = out.startIndex
        for arg in args {
            guard let range = out.range(of: "%@", range: searchStart..<out.endIndex) else { break }
            out.replaceSubrange(range, with: arg)
            // Yerleştirilen argümanın İÇİNDEKİ "%@" bir sonraki turda yeniden
            // doldurulmasın diye arama noktası argümanın sonrasına taşınır.
            searchStart = out.index(range.lowerBound, offsetBy: arg.count)
        }
        return out
    }
}

// MARK: - Localizer

extension Localizer {
    /// Log anahtarını geçerli dile çevirir (log katalogu + ana katalog).
    /// View metinleri için `t(_:)` kullanılmaya devam edilir.
    func tLog(_ key: String, args: [String] = []) -> String {
        L10n.renderLog(key: key, args: args)
    }
}

// MARK: - ConsoleEntry

extension ConsoleEntry {
    /// Konsolda GÖSTERİLECEK metin — dil her değiştiğinde yeniden çözülür.
    /// Anahtarsız satırlarda ham `message` döner.
    @MainActor
    var text: String {
        guard let key, !key.isEmpty else { return message }
        return L10n.renderLog(key: key, args: args, fallback: message)
    }
}
