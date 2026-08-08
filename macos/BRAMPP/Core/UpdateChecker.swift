import Foundation

/// GitHub Releases üzerinden güncelleme denetimi.
///
/// Tasarım kararları:
///   • **Sessiz başarısızlık.** Ağ yoksa, GitHub kotayı doldurmuşsa ya da yanıt
///     beklenmedikse kullanıcıya hata gösterilmez. Güncelleme denetimi yardımcı bir
///     özelliktir; başarısız olması uygulamanın kullanımını etkilememelidir.
///   • **İndirme YOK.** Yalnızca "yeni sürüm var" bilgisi verilir, indirme kullanıcının
///     tarayıcısında yapılır. Kendi kendini güncelleyen bir mekanizma, imzalı ve noter
///     onaylı dağıtım zincirini atlatma riski taşır.
///   • **Ön sürümler atlanır.** `latest` uç noktası zaten taslak ve ön sürümleri
///     dışlar; yine de gelen veri denetlenir.
enum UpdateChecker {

    static let releasesURL = URL(string: "https://github.com/macitkaraca/brampp/releases/latest")!
    private static let apiURL = URL(string: "https://api.github.com/repos/macitkaraca/brampp/releases/latest")!

    enum Result: Equatable {
        case upToDate(current: String)
        case updateAvailable(current: String, latest: String, url: URL)
        case failed
    }

    /// Uygulamanın kendi sürümü (Info.plist).
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// GitHub'a sorar ve sonucu döndürür. Hata durumunda `.failed`.
    static func check(timeout: TimeInterval = 10) async -> Result {
        let current = currentVersion
        var req = URLRequest(url: apiURL, timeoutInterval: timeout)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub kimliksiz istekleri User-Agent'a göre sınırlar; alan boş kalırsa 403 döner.
        req.setValue("BRAMPP/\(current)", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return .failed }

        // Taslak/ön sürüm gelirse güncelleme sayma
        if (json["draft"] as? Bool) == true || (json["prerelease"] as? Bool) == true {
            return .upToDate(current: current)
        }

        let latest = normalize(tag)
        guard !latest.isEmpty else { return .failed }

        let url = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesURL
        return isNewer(latest, than: normalize(current))
            ? .updateAvailable(current: current, latest: latest, url: url)
            : .upToDate(current: current)
    }

    // MARK: - Sürüm karşılaştırma (saf — doğrudan test edilir)

    /// Etiketten sürüm çıkarır: "v1.2" → "1.2", "BRAMPP 1.2" → "1.2".
    /// Rakam ve nokta dışındaki her şey atılır.
    static func normalize(_ tag: String) -> String {
        let allowed = Set("0123456789.")
        let s = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { !$0.isNumber })            // baştaki "v", "BRAMPP " vb.
        return String(s.filter { allowed.contains($0) })
            .split(separator: ".", omittingEmptySubsequences: true)
            .joined(separator: ".")
    }

    /// Noktalı sürümleri SAYISAL olarak karşılaştırır.
    /// Dizgi karşılaştırması "1.10" < "1.9" derdi — bu yüzden bileşen bileşen bakılır.
    /// Farklı uzunluklar eksik bileşenleri 0 sayarak karşılaştırılır ("1.2" == "1.2.0").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
