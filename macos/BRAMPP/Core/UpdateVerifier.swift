import Foundation
import CryptoKit
import Security

/// İndirilen bir sürümün kurulmadan ÖNCE geçmesi gereken kapılar.
///
/// Dört kapı var ve dördü de birbirinin yerine geçmez:
///   1. **Köken** — dosya https ile ve BEKLENEN yayın adresinden mi indi?
///   2. **Sağlama** — dosyanın sha256'sı manifestteki değerle aynı mı? (Özet AYRI
///      bir kökenden gelir; bkz. `UpdateManifest` başlığı.)
///   3. **İmza** — `codesign --verify --deep --strict` geçiyor mu, ve Team ID
///      ÇALIŞAN uygulamanınkiyle aynı mı? (Geçerli ama BAŞKA bir geliştiricinin
///      imzası da `codesign` denetiminden geçer — asıl soru "kimin imzası".)
///   4. **Noter onayı** — `spctl --assess --type execute` Apple'ın onayını görüyor mu?
///
/// Çıktı AYRIŞTIRICILARI SAF tutuldu: `codesign`/`spctl` çalıştırmadan, yakalanmış
/// metinlerle test edilebilirler. Kabuk çağıran ince sarmalayıcılar hemen altlarında.
enum UpdateVerifier {

    // MARK: - Başarısızlık nedenleri

    /// Her nedenin bir katalog anahtarı var: kullanıcı "doğrulanamadı" değil,
    /// HANGİ kapının kapandığını görür.
    enum Failure: Equatable {
        case untrustedURL
        case downloadFailed
        case checksumMismatch
        case mountFailed
        case appNotFound
        case codesignFailed
        case teamMismatch(expected: String, got: String?)
        case notNotarized
        case selfUnsigned
        /// Manifest bu mimari için bir varlık ya da sha256 YAYINLAMAMIŞ.
        ///
        /// Eskiden bu durum `.checksumMismatch` ile bildiriliyordu ve kullanıcı
        /// "indirilen dosya silindi" cümlesini HİÇBİR ŞEY İNMEDEN görüyordu —
        /// yanlış nöbetçi. Kendi nedeni var: burada eşleşmeyen bir sağlama değil,
        /// OLMAYAN bir sağlama söz konusudur.
        case noChecksum

        /// `upd.dl.failed` kalıbının içine yerleşen CÜMLE PARÇASI — tek başına
        /// cümle değildir, bu yüzden küçük harfle başlar.
        var messageKey: String {
            switch self {
            case .untrustedURL:     return "upd.fail.url"
            case .downloadFailed:   return "upd.fail.http"
            case .checksumMismatch: return "upd.fail.sha"
            case .mountFailed:      return "upd.fail.mount"
            case .appNotFound:      return "upd.fail.noApp"
            case .codesignFailed:   return "upd.fail.codesign"
            case .teamMismatch:     return "upd.fail.team"
            case .notNotarized:     return "upd.fail.gatekeeper"
            case .selfUnsigned:     return "upd.fail.selfUnsigned"
            case .noChecksum:       return "upd.fail.noHash"
            }
        }
    }

    // MARK: - SAF ayrıştırıcılar (kabuk çalıştırmadan test edilir)

    /// İndirme adresi BEKLENEN yayın adresi mi?
    ///
    /// SONEK EŞLEŞMESİ KULLANILMAZ. `host.hasSuffix("github.com")` yazılsaydı
    /// `evilgithub.com` denetimden geçerdi; ana bilgisayar adı TAM eşleşir.
    /// `github.com` için ayrıca yol da denetlenir — o alan altındaki herhangi bir
    /// deponun varlığı değil, YALNIZCA bu deponun yayın varlıkları kabul edilir.
    /// Yönlendirmelerin indiği CDN adları ayrıca listelenir; `URLSession` isteği
    /// oraya taşır ve doğrulanması gereken SON adrestir.
    ///
    /// **`..` İÇEREN YOL REDDEDİLİR.** `URL.path` yolu NORMALLEŞTİRMEZ: sunucu
    ///   `/macitkaraca/brampp/releases/download/../../../someoneelse/repo/x.dmg`
    /// adresini bambaşka bir depoya çözerken `hasPrefix` denetimi geçerdi. Tek
    /// başına sömürülebilir değil (sha256/codesign/Team ID/spctl kapıları duruyor)
    /// ama bu fonksiyon tam olarak "beklenen yayın varlığı mı" kapısıdır; kapının
    /// arkasındaki kapılara güvenerek gevşemesi, dört kapıyı üçe indirmek olurdu.
    /// Denetim `standardized` ÜZERİNDEN yapılır ve ayrıca ham bileşenlere de bakılır:
    /// `standardized` baştaki fazladan `..`'ları KIRPMAZ, yalnızca çözebildiklerini çözer.
    static func isTrustedReleaseURL(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else { return false }

        switch host {
        case "objects.githubusercontent.com", "release-assets.githubusercontent.com":
            return true
        case "github.com":
            let raw = url.path
            // Yol gezinmesi taşıyan hiçbir adres kabul edilmez — normalleştirilmiş
            // hâli tesadüfen doğru ön eke düşse bile niyeti belli bir adrestir.
            guard !raw.split(separator: "/").contains("..") else { return false }
            return url.standardized.path.hasPrefix("/macitkaraca/brampp/releases/download/")
                && raw.hasPrefix("/macitkaraca/brampp/releases/download/")
        default:
            return false
        }
    }

    /// `codesign -dv --verbose=4` çıktısındaki `TeamIdentifier=` satırı.
    ///
    /// `codesign`, imzasız/ad-hoc paketlerde harfi harfine `TeamIdentifier=not set`
    /// yazar. Bunu bir kimlik saymak, iki imzasız paketi "aynı geliştirici" ilan
    /// etmek olurdu — bu yüzden `nil` döner.
    static func teamIdentifier(inCodesignOutput out: String) -> String? {
        for line in out.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("TeamIdentifier=") else { continue }
            let value = String(trimmed.dropFirst("TeamIdentifier=".count))
                .trimmingCharacters(in: .whitespaces)
            if value.isEmpty || value == "not set" { return nil }
            return value
        }
        return nil
    }

    /// `Authority=` satırları — zincirin en altından köke doğru. Yalnızca
    /// teşhis/log için; karar Team ID ve `spctl` ile verilir.
    static func authorities(inCodesignOutput out: String) -> [String] {
        out.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Authority=") else { return nil }
            let value = String(trimmed.dropFirst("Authority=".count))
                .trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
    }

    /// `codesign --verify --deep --strict` sonucu.
    ///
    /// KARAR YALNIZCA ÇIKIŞ KODUNDAN verilir. `stderr` bilerek okunMAZ: `codesign`
    /// başarılı koşuda da bilgilendirme satırları yazar ve metne bakan bir denetim,
    /// Apple ileride o metni değiştirdiğinde sessizce gevşer ya da sıkışır.
    /// Parametre imzada duruyor çünkü çağıran hatayı LOGLAMAK için elinde tutar.
    static func isCodesignVerified(exitCode: Int32, stderr: String) -> Bool {
        _ = stderr
        return exitCode == 0
    }

    /// `spctl --assess --type execute --verbose` sonucu.
    ///
    /// ÇIKIŞ KODU TEK BAŞINA YETMEZ. Noter onayı OLMAYAN ama geçerli Developer ID
    /// ile imzalı bir paket, Gatekeeper politikasına göre 0 ile dönebilir ve çıktıda
    /// `source=Unnotarized Developer ID` yazar. Şartın tamamı budur: Apple'ın
    /// noter onayını GÖRMEDEN kabul yok. ("Unnotarized" dizgisi
    /// "source=Notarized" alt dizgisini içermez — ayrım tam da burada.)
    static func isNotarizedAccepted(exitCode: Int32, output: String) -> Bool {
        guard exitCode == 0 else { return false }
        return output.contains("source=Notarized Developer ID")
    }

    /// İki sha256 özeti aynı mı?
    ///
    /// Büyük/küçük harf ve kenar boşlukları önemsiz (`shasum` çıktısı, elle
    /// düzenlenmiş manifest); UZUNLUK önemli. Boş-boşa eşit SAYILMAZ: eksik bir
    /// alan yüzünden iki tarafın da boş kalması, doğrulamanın SESSİZCE geçmesi
    /// demek olurdu — bu fonksiyonun engellemek için var olduğu tek şey o.
    static func checksumsMatch(_ computed: String, _ expected: String) -> Bool {
        let a = computed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard a.count == 64, b.count == 64 else { return false }
        guard a.allSatisfy({ $0.isHexDigit }), b.allSatisfy({ $0.isHexDigit }) else { return false }
        return a == b
    }

    // MARK: - Çalışan kopyanın kendi kimliği

    /// ÇALIŞAN uygulamanın Team ID'si — Security.framework'ten, kabuk çağırmadan.
    ///
    /// `codesign` çağırmak yerine çerçeveyi kullanmanın nedeni: karşılaştırmanın
    /// bir ucu BİZİZ; kendi kimliğimizi bir alt sürecin metin çıktısından okumak,
    /// o çıktıyı etkileyebilen her şeye güvenmek olurdu.
    ///
    /// `nil` dönmesi bir hata değil, bir DURUMDUR: `scripts/make-dmg.sh`
    /// `SIGN_IDENTITY` boşken ad-hoc imzalar. Böyle bir geliştirme derlemesinin
    /// karşılaştıracak kimliği yoktur ve kendini güncellememelidir (`.selfUnsigned`).
    static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return nil }

        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard status == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty
        else { return nil }
        return team
    }

    // MARK: - Sağlama hesabı

    /// Dosyanın sha256'sı — CryptoKit ile SÜREÇ İÇİNDE.
    ///
    /// `shasum` çağrılMAZ: sistem çerçevesi zaten var, bağımlılık eklemez ve
    /// yola dosya adı gömen bir kabuk satırı yüzeyi bırakmaz. Dosya parça parça
    /// okunur — 60 MB'lık bir disk kalıbını belleğe almak için sebep yok.
    ///
    /// **İPTAL EDİLEBİLİR.** `Task.detached` üst görevin iptalini MİRAS ALMAZ
    /// (tanımı gereği: ayrık görev bağlam taşımaz). Bu yüzden bayrak dışarıdan,
    /// `withTaskCancellationHandler` ile kapatılır. Gerekçesi somut: kullanıcı
    /// "indirmeyi durdur"a bastığında hazırlık dizini siliniyor; hâlâ okuyan bir
    /// özetleyici o dosyanın altından çekilmesiyle karşılaşıp kullanıcının SEBEP
    /// OLMADIĞI kırmızı bir "doğrulama başarısız" satırı üretiyordu.
    static func sha256OfFile(at path: String) async -> String? {
        let flag = CancellationFlag()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                computeSHA256(path: path, isCancelled: { flag.isCancelled })
            }.value
        } onCancel: {
            flag.cancel()
        }
    }

    /// Görev sınırını aşan tek bitlik iptal bayrağı. `@unchecked Sendable`: tek
    /// alanı kilit altında; kilidin koruduğu değişmezlik gözle görülür kadar küçük.
    ///
    /// `nonisolated`: iki ucu da ana aktör DIŞINDAN çağrılır — okuyan taraf ayrık
    /// görev, yazan taraf `withTaskCancellationHandler`ın eşzamanlı iptal kancasıdır
    /// (proje `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` ile derlenir).
    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        nonisolated(unsafe) private var flag = false
        nonisolated var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        nonisolated func cancel() { lock.lock(); flag = true; lock.unlock() }
    }

    /// `nonisolated`: ayrık görevden (ana aktör dışından) çağrılır — 60 MB'lık bir
    /// dosyayı özetlemek ana iş parçacığında yapılacak iş değil.
    ///
    /// İptal HER PARÇADA sorulur (1 MB): dosyanın tamamını bitirip sonucu atmak,
    /// iptali "biraz sonra" yapmakla aynı şeydir.
    nonisolated private static func computeSHA256(path: String,
                                                  isCancelled: () -> Bool = { false }) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        // `try?` iç içe opsiyoneli düzler: `read(upToCount:)` `Data?` döndürüyor,
        // sonuç yine `Data?` olur — ikinci bir açma denemesi derlenmez.
        while let data = try? handle.read(upToCount: 1 << 20), !data.isEmpty {
            if isCancelled() { return nil }
            hasher.update(data: data)
        }
        // Son bir kez: tek parçalık küçük dosyada döngü içi denetim hiç çalışmaz.
        if isCancelled() { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
