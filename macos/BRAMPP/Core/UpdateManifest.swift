import Foundation

// MARK: - Kanal

/// Güncelleme kanalı. `spec/update-manifest.md` üçünü de tanımlar; bugün
/// `docs/updates/macos/` altında GERÇEKTEN yayınlanmış olan tek dosya
/// `stable.json`'dır. `beta`/`nightly` seçilebilir ama karşılığı yoktur —
/// bu ayrım kullanıcıdan SAKLANMAZ, arayüz `set.upd.channel.reserved` ile söyler.
enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable, beta, nightly

    var id: String { rawValue }
    var labelKey: String { "set.upd.channel.\(rawValue)" }

    /// Bu kanalın manifest dosyası bugün yayınlanıyor mu?
    /// Uydurulmuş bir uç nokta YOK: adres yalnızca belgelenmiş kalıptan kurulur,
    /// yanıt 404 ise kararlı kanala düşülür.
    var isPublished: Bool { self == .stable }

    /// Elle düzenlenmiş ya da eski bir settings.json'dan gelen değer kararlıya düşer.
    /// Bilinmeyen bir kanal adıyla adres kurmak, olmayan bir dosyayı sonsuza dek
    /// sormak demekti.
    static func from(_ raw: String) -> UpdateChannel { UpdateChannel(rawValue: raw) ?? .stable }
}

// MARK: - Manifest

/// GitHub Pages'te duran statik güncelleme bildirimi (`spec/update-manifest.md`, sürüm 1.0).
///
/// NEDEN GitHub API'si TEK BAŞINA YETMİYOR: API "en son yayın hangisi" sorusunu
/// yanıtlar, bir güncelleyicinin sorduklarını değil. Bir sürümün ZORUNLU olduğunu,
/// bir başkasının SORUNLU çıktığını, kullanıcının bir KANALDA olduğunu ve dosyanın
/// sha256'sını yalnızca bu dosya söyleyebilir. API ayrıca kimliksiz istekleri adres
/// başına saatte 60 ile sınırlar — tek bir NAT arkasındaki ofis bunu görür.
///
/// SHA256'NIN AYRI KÖKENDEN GELMESİ tasarımın kendisidir: disk kalıbı
/// `objects.githubusercontent.com` CDN'inden, ona kefil olan özet ise
/// `macitkaraca.github.io` Pages'ten iner. Tek bir sunucunun ele geçirilmesi hem
/// dosyayı hem de onu doğrulayan özeti sağlamaya yetmez
/// (spec/update-manifest.md, "Verify before installing").
///
/// TÜM ALANLAR OPSİYONEL. `docs/updates/windows/stable.json` gerçekten
/// `"version": null` taşıyor ve `minimumOS` alanı hiç yok — "bu kanalda henüz yayın
/// yok" bir HATA DEĞİLDİR ve çözümleyicinin bunu bir hata gibi ele alması, ileride
/// eklenecek her yeni alanın eski uygulamaları kırması demekti.
struct UpdateManifest: Decodable {

    struct Download: Decodable {
        let url: String?
        let sha256: String?

        /// Adres yalnızca ayrıştırılabiliyorsa döner; doğrulaması
        /// `UpdateVerifier.isTrustedReleaseURL` işidir.
        var assetURL: URL? { url.flatMap(URL.init(string:)) }
    }

    let version: String?
    let channel: String?
    let published: String?
    let release: String?
    let minimumOS: String?
    let mandatory: Bool?
    let blockedVersions: [String]?
    let downloads: [String: Download]?

    // MARK: - Adres

    /// Belgelenmiş kalıp — `spec/update-manifest.md:8`. Başka hiçbir yerden adres kurulmaz.
    static let baseURL = "https://macitkaraca.github.io/brampp/updates"

    static func url(platform: String = "macos", channel: UpdateChannel) -> URL? {
        URL(string: "\(baseURL)/\(platform)/\(channel.rawValue).json")
    }

    // MARK: - Çözümleme (saf — ağ yok, doğrudan test edilir)

    static func parse(_ data: Data) -> UpdateManifest? {
        try? JSONDecoder().decode(UpdateManifest.self, from: data)
    }

    /// Bu makinenin mimarisi. Manifest bugün yalnızca `arm64` taşıyor; Intel'de
    /// giriş bulunamaz ve arayüz "sürüm sayfasını aç"a düşer — sessizce hata vermez.
    static var currentArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    func download(forArch arch: String = UpdateManifest.currentArch) -> Download? {
        guard let d = downloads?[arch], d.assetURL != nil else { return nil }
        return d
    }

    /// Kurulu sürüm "sorunlu" listesinde mi?
    /// Karşılaştırma İKİ TARAFTA da normalize edilir: elle düzenlenmiş bir manifest
    /// "v1.5" yazabilir, uygulamanın kendi sürümü "1.5"tir.
    func isBlocked(_ current: String) -> Bool {
        let c = UpdateChecker.normalize(current)
        guard !c.isEmpty else { return false }
        return (blockedVersions ?? []).contains { UpdateChecker.normalize($0) == c }
    }

    /// Bu sürüm bu macOS'ta çalışır mı? Alan yoksa kısıtlama da yoktur.
    /// SAYISAL karşılaştırma: "14.10" > "14.9" (spec/update-manifest.md, "Compare numerically").
    func meetsMinimumOS(_ os: OperatingSystemVersion) -> Bool {
        guard let minimum = minimumOS, !minimum.isEmpty else { return true }
        let current = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return !UpdateChecker.isNewer(UpdateChecker.normalize(minimum), than: current)
    }

    var isMandatory: Bool { mandatory ?? false }

    /// `published` alanı ISO tarih (YYYY-MM-DD). Çözülemezse nil — gösterim satırı düşer.
    var publishedDate: Date? {
        guard let published else { return nil }
        return UpdateManifest.dayParser.date(from: published)
    }

    /// Sabit biçimli tarih için POSIX yerel — kullanıcının takvimi/dili biçimi bozmasın.
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
