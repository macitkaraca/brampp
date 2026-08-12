import Foundation

/// Güncelleme denetimi.
///
/// Tasarım kararları:
///   • **Sessiz başarısızlık.** Ağ yoksa, GitHub kotayı doldurmuşsa ya da yanıt
///     beklenmedikse kullanıcıya hata gösterilmez. Güncelleme denetimi yardımcı bir
///     özelliktir; başarısız olması uygulamanın kullanımını etkilememelidir.
///     (spec/update-manifest.md: "A missing manifest is not an error".)
///   • **İNDİRME VAR, KURULUM YOK.** Dosya indirilir ve dört kapıdan geçirilir —
///     beklenen yayın adresi + https, manifestteki sha256, `codesign --verify
///     --deep --strict`, `spctl --assess --type execute` ve çalışan uygulamanın
///     Team ID'si. Herhangi biri geçmezse indirilen dosya SİLİNİR. Doğrulanan disk
///     kalıbı açılır; uygulamayı Uygulamalar klasörüne KULLANICI sürükler.
///     BRAMPP çalışırken kendini DEĞİŞTİRMEZ — eski karardaki ("indirme yok")
///     asıl kaygı buydu ve o kaygı korunuyor: atlatılan bir zincir yok, aksine
///     zincir bir kez daha ve uygulamanın İÇİNDE denetleniyor.
///     (spec/update-manifest.md: "Never update silently".)
///   • **Karantina bayrağı bilerek kaldırılmaz.** İnen disk kalıbında
///     `com.apple.quarantine` durur; kullanıcı açtığında Gatekeeper kalıbı BİR KEZ
///     DAHA, bizden bağımsız denetler. Yazmadığımız ve yanlış yapamayacağımız bir kapı.
///   • **İKİ KAYNAK, DAHA YENİ OLAN KAZANIR.** Manifest güncellemenin ayrıntılarını
///     (sha256, zorunluluk, sorunlu sürümler, en düşük macOS) söyleyen tek kaynaktır;
///     ama "en son sürüm hangisi" sorusunda TEK SÖZ SAHİBİ DEĞİLDİR. Manifest elle
///     yayınlanan bir dosyadır ve GERİ KALABİLİR — bir kez kaldı da: 1.5 yayınlanmışken
///     `docs/updates/macos/stable.json` hâlâ "1.4" diyordu. Yalnızca manifeste bakan
///     bir denetim o gün HERKESE "güncelsiniz" derdi; üstelik eski API tabanlı
///     denetleyiciye göre bir GERİLEME olurdu. Bu yüzden sürüm karşılaştırması iki
///     kaynağın DAHA YENİSİ üzerinden yapılır.
///   • **Bayat manifest = sağlamasız yol.** Manifest geride kaldıysa oradaki sha256 /
///     mandatory / minimumOS API'nin gösterdiği sürümü ANLATMAZ; o değerleri başka bir
///     sürüme uygulamak, doğrulama vaadini sahteleştirmek olurdu. O durumda sonuç
///     API'ye düşer: uygulama içi indirme kapanır, kullanıcı sürüm sayfasına gider.
///     Tek istisna `blockedVersions`'tır — o liste manifestin KENDİ sürümünü değil,
///     BAŞKA (eski) sürümleri anlatır, dolayısıyla manifest bayatken de geçerlidir.
///   • **Ön sürümler atlanır.** `latest` uç noktası zaten taslak ve ön sürümleri
///     dışlar; yine de gelen veri denetlenir.
enum UpdateChecker {

    static let releasesURL = URL(string: "https://github.com/macitkaraca/brampp/releases/latest")!
    private static let apiURL = URL(string: "https://api.github.com/repos/macitkaraca/brampp/releases/latest")!

    // MARK: - Sonuç tipleri

    /// Bir yayın hakkında arayüzün ihtiyaç duyduğu her şey.
    ///
    /// Eskiden `Result` genişleyen bir demet taşıyordu (`current`, `latest`, `url`).
    /// Sürüm notları, sağlama, kanal ve "zorunlu" bilgisi eklenince demet okunmaz
    /// hâle gelirdi; adlandırılmış alanlar hem çağrı yerlerini hem testleri korur.
    struct ReleaseInfo: Equatable {
        /// Normalize edilmiş sürüm ("1.6")
        let version: String
        /// Ham etiket ("v1.6")
        let tag: String
        /// Sürüm sayfası
        let pageURL: URL
        /// GitHub sürüm gövdesi — boş OLABİLİR, arayüz buna hazır olmalı
        let notes: String
        /// İndirilecek disk kalıbı (mimariye uygun giriş yoksa nil)
        let assetURL: URL?
        /// YALNIZCA manifestten gelir. nil ⇒ uygulama içi indirme KAPALI.
        let sha256: String?
        let mandatory: Bool
        /// Kurulu sürüm manifestteki `blockedVersions` listesinde mi?
        let blockedCurrent: Bool
        /// Gerçekte YANIT VEREN kanal (istenen kanal 404 ise "stable")
        let channel: String
        let publishedAt: Date?
        /// Bilgi manifestten mi geldi? `false` ise GitHub API'ye düşüldü demektir —
        /// sağlama doğrulaması yapılamaz ve konsola bu durum yazılır.
        let manifestBacked: Bool
        /// Manifestteki `minimumOS`, AMA yalnızca BU MAKİNE onu KARŞILAMIYORSA dolu.
        ///
        /// Alan "yayının en düşük macOS'u" değil, "bu makine yetmiyor" bilgisidir:
        /// dolu olduğu her yerde indirme kapalıdır (`assetURL`/`sha256` nil) ve arayüz
        /// nedenini söyler. Sessizce "güncelsiniz" demek yanlış olurdu — sürüm GERÇEKTEN
        /// var; kullanıcı önce macOS'unu yükseltmeli.
        let requiredOS: String?
    }

    enum Result: Equatable {
        case upToDate(current: String)
        case updateAvailable(current: String, release: ReleaseInfo)
        /// **Daha yeni sürüm YOK, ama kurulu sürüm manifestin `blockedVersions`
        /// listesinde.** Ayrı bir durum olması şart: `.upToDate` demek, bozuk çıktığı
        /// bilinen bir yapıyı çalıştıran kullanıcıya "her şey yolunda" demektir.
        /// spec/update-manifest.md o listeyi tam olarak bu an için tanımlıyor:
        /// *"that list exists for the case where a release turned out to be harmful."*
        /// Düzeltme yayınlanana kadar geçen sürede uyarıyı taşıyan tek yol budur.
        case currentBlocked(current: String, release: ReleaseInfo)
        case failed
    }

    /// Uygulamanın kendi sürümü (Info.plist).
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: - Denetim

    /// - Parameter channel: `AppSettings.updateChannel`. Bilinmeyen değer kararlıya düşer.
    static func check(channel: String, timeout: TimeInterval = 10) async -> Result {
        let current = currentVersion
        let requested = UpdateChannel.from(channel)

        // 1) Manifest — asıl kaynak.
        var effective = requested
        var manifest = await fetchManifest(channel: requested, timeout: timeout)
        if requested != .stable, manifest == nil || manifest?.version == nil {
            // beta/nightly dosyası HENÜZ YOK (ya da o kanalda yayın yok). Kullanıcıyı
            // sessizce güncellemesiz bırakmak yerine kararlı kanala düş — arayüz de
            // bunu `set.upd.channel.reserved` ile söylüyor.
            manifest = await fetchManifest(channel: .stable, timeout: timeout)
            effective = .stable
        }

        // 2) API bacağı. Sürüm notlarının TEK kaynağı (manifest v1.0 şemasında not alanı
        //    yok; eklemek aynı metni iki yerde tutup ayrışmasına davetiye olurdu) ve
        //    manifest geride kaldığında sürümün İKİNCİ kaynağı.
        let api = await fetchLatestRelease(timeout: timeout)

        return resolve(current: current, manifest: manifest, api: api, channel: effective.rawValue)
    }

    // MARK: - Karar (SAF — ağ yok, doğrudan test edilir)

    /// İki kaynaktan tek sonucu üretir.
    ///
    /// Sıralama:
    ///   1. **Sürüm = iki kaynağın DAHA YENİSİ.** Manifest bayat kalırsa sessizlik değil,
    ///      API sonucu. (Bayat manifest bu projede yaşandı — bkz. tip başlığı.)
    ///   2. **Ayrıntılar yalnızca sürümü söyleyen kaynaktan.** Manifest kazandıysa
    ///      sha256/mandatory/minimumOS onun; API kazandıysa hiçbiri kullanılmaz ve
    ///      uygulama içi indirme kapanır.
    ///   3. **`blockedVersions` her hâlükârda okunur.** O liste manifestin kendi
    ///      sürümünü değil, KURULU sürümü ilgilendirir; manifest bayatken de,
    ///      daha yeni sürüm hiç yokken de geçerlidir (`.currentBlocked`).
    ///   4. **`minimumOS` karşılanmıyorsa indirme kapanır.** Dört kapıdan geçip kurulan
    ///      ama açılmayan bir uygulama, hiç indirilmemiş olandan kötüdür.
    ///
    /// - Parameter os: çalışan macOS. Parametre çünkü testler bunu değiştirebilmeli.
    static func resolve(current: String,
                        manifest: UpdateManifest?,
                        api: APIRelease?,
                        channel: String,
                        os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Result {

        let cur = normalize(current)

        /// Manifestin söylediği sürüm — "version": null ya da çözülemeyen değer ⇒ nil.
        let manifestVersion: String? = {
            guard let raw = manifest?.version else { return nil }
            let v = normalize(raw)
            return v.isEmpty ? nil : v
        }()
        let apiVersion: String? = {
            guard let v = api?.version, !v.isEmpty else { return nil }
            return v
        }()

        // Kurulu sürümün "sorunlu" işareti manifestin `version` alanından BAĞIMSIZDIR.
        let blocked = manifest?.isBlocked(current) ?? false

        // DAHA YENİ olan kazanır — D1'in kalbi.
        let latest: String? = {
            switch (manifestVersion, apiVersion) {
            case let (m?, a?): return isNewer(a, than: m) ? a : m
            case let (m?, nil): return m
            case let (nil, a?): return a
            case (nil, nil):   return nil
            }
        }()

        guard let latest, isNewer(latest, than: cur) else {
            // Daha yeni sürüm yok. Yine de kurulu sürüm sorunlu işaretliyse SUSULMAZ.
            if blocked {
                return .currentBlocked(current: current,
                                       release: blockedInfo(current: cur, manifest: manifest,
                                                            api: api, channel: channel))
            }
            // Hiçbir kaynağa ULAŞILAMADIYSA bu bir başarısızlıktır; manifest okunup
            // "bu kanalda yayın yok" dediyse HATA DEĞİLDİR (spec: "A missing manifest
            // is not an error").
            guard manifest != nil || api != nil else { return .failed }
            return .upToDate(current: current)
        }

        // Sürümü MANİFEST söylüyorsa ayrıntılar da ondan gelir.
        if let manifest, latest == manifestVersion {
            // minimumOS YALNIZCA manifestin kendi sürümünü anlatır — bayat manifestin
            // değeri API'nin gösterdiği sürüme uygulanamaz, bu yüzden denetim burada.
            let osOK = manifest.meetsMinimumOS(os)
            let download = osOK ? manifest.download() : nil
            let page = manifest.release.flatMap(URL.init(string:)) ?? api?.pageURL ?? releasesURL
            // Notlar YALNIZCA aynı sürüme aitse kullanılır. Manifest 1.6 derken API
            // 1.7'yi gösteriyorsa 1.7'nin notlarını 1.6 başlığının altına koymak
            // kullanıcıya yalan söylemek olurdu.
            let notes = (api?.version == latest) ? (api?.notes ?? "") : ""
            return .updateAvailable(current: current, release: ReleaseInfo(
                version: latest,
                tag: manifest.release.flatMap { URL(string: $0)?.lastPathComponent } ?? "v\(latest)",
                pageURL: page,
                notes: notes,
                assetURL: download?.assetURL,
                sha256: download?.sha256,
                mandatory: manifest.isMandatory,
                blockedCurrent: blocked,
                channel: channel,
                publishedAt: manifest.publishedDate,
                manifestBacked: true,
                requiredOS: osOK ? nil : manifest.minimumOS))
        }

        // Manifest yok ya da BAYAT → API sonucu.
        // `sha256` ve `assetURL` BİLEREK nil: bu yoldan inen bir dosyayı doğrulayacak
        // bağımsız bir özet yok, dolayısıyla uygulama içi indirme de yok (bkz.
        // UpdateInstaller). Kullanıcı sürüm sayfasına yönlendirilir.
        guard let api else { return .upToDate(current: current) }
        return .updateAvailable(current: current, release: ReleaseInfo(
            version: latest,
            tag: api.tag,
            pageURL: api.pageURL,
            notes: api.notes,
            assetURL: nil,
            sha256: nil,
            mandatory: false,
            blockedCurrent: blocked,
            channel: channel,
            publishedAt: api.publishedAt,
            manifestBacked: false,
            requiredOS: nil))
    }

    /// "Kurulu sürümünüz sorunlu" uyarısının taşıyıcısı. Kurulacak bir şey YOKTUR:
    /// `assetURL`/`sha256` nil, dolayısıyla arayüz yalnızca sürüm sayfasını önerir —
    /// kullanıcının zaten çalıştırdığı sürümü yeniden indirmenin anlamı olmazdı.
    private static func blockedInfo(current: String,
                                    manifest: UpdateManifest?,
                                    api: APIRelease?,
                                    channel: String) -> ReleaseInfo {
        ReleaseInfo(version: current,
                    tag: "v\(current)",
                    pageURL: manifest?.release.flatMap(URL.init(string:)) ?? api?.pageURL ?? releasesURL,
                    notes: "",
                    assetURL: nil,
                    sha256: nil,
                    mandatory: false,
                    blockedCurrent: true,
                    channel: channel,
                    publishedAt: nil,
                    manifestBacked: manifest != nil,
                    requiredOS: nil)
    }

    // MARK: - Ağ bacakları

    private static func fetchManifest(channel: UpdateChannel, timeout: TimeInterval) async -> UpdateManifest? {
        guard let url = UpdateManifest.url(channel: channel) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("BRAMPP/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        // Pages önbelleği yüzünden dünkü manifesti okumak, yayınlanmış bir düzeltmeyi
        // görmemek demek olurdu.
        req.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        return UpdateManifest.parse(data)
    }

    /// GitHub API'sinden okunan yayın — burada YALNIZCA `body` (sürüm notları) için var.
    struct APIRelease: Equatable {
        let version: String
        let tag: String
        let pageURL: URL
        let notes: String
        let publishedAt: Date?
    }

    private static func fetchLatestRelease(timeout: TimeInterval) async -> APIRelease? {
        var req = URLRequest(url: apiURL, timeoutInterval: timeout)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub kimliksiz istekleri User-Agent'a göre sınırlar; alan boş kalırsa 403 döner.
        req.setValue("BRAMPP/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return nil }

        // Taslak/ön sürüm güncelleme sayılmaz
        if (json["draft"] as? Bool) == true || (json["prerelease"] as? Bool) == true { return nil }

        let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesURL
        let published = (json["published_at"] as? String).flatMap(iso8601.date(from:))
        return APIRelease(version: normalize(tag),
                          tag: tag,
                          pageURL: page,
                          notes: (json["body"] as? String) ?? "",
                          publishedAt: published)
    }

    private static let iso8601: ISO8601DateFormatter = ISO8601DateFormatter()

    // MARK: - Açılışta bildirim kararı (saf — doğrudan test edilir)

    enum PromptDecision: Equatable {
        case show
        case upToDate
        case skippedVersion
        case snoozed
    }

    /// "Bu açılışta bildirimi GÖSTERELİM Mİ?"
    ///
    /// Sıralama tesadüf değil:
    ///   0. **Zorunlu ya da sorunlu sürüm her şeyi deler.** spec/update-manifest.md:
    ///      *"`blockedVersions` outranks `mandatory` … that list exists for the case
    ///      where a release turned out to be harmful."* Bozuk çıkmış bir sürüm
    ///      hakkındaki uyarı susturulamaz.
    ///   1. Yeni sürüm yoksa gösterilecek bir şey de yok.
    ///   2. **Atlama TAM SÜRÜM eşleşmesidir.** 1.6 atlandıysa 1.7 yine sorulur;
    ///      "bu sürümü atla" bir kereliktir, kalıcı bir sessizlik değil. İki taraf da
    ///      normalize edilir ki elle yazılmış "v1.6" da eşleşsin.
    ///   3. Erteleme SONRA bakılır: eski bir ertelemeyle yeni bir atlama çakışırsa
    ///      sonuç "atlandı" olur — daha açık, daha güçlü kullanıcı iradesi odur.
    ///
    /// **Erteleme, yeni bir sürüm çıktı diye BOZULMAZ.** "Bir hafta sonra hatırlat"
    /// bir hafta sessizlik demektir; araya giren her yayının bunu delmesi denetimi
    /// yalana çevirirdi. Yalnızca 0. kural deler.
    ///
    /// 0. KURAL `latest == current` İKEN DE ÇALIŞIR ve çalışması ŞARTTIR: sorunlu
    /// çıkmış bir sürümü kullanan kullanıcı için ortada "daha yeni sürüm" yoktur —
    /// uyarıyı taşıyan tek şey odur. Bu yol `check()` içinde `.currentBlocked` ile
    /// gelir ve `latest` olarak KURULU sürümü geçer; kural 1'in `guard`ından önce
    /// dönüldüğü için erken çıkış olmaz.
    static func decide(current: String, latest: String,
                       skippedVersion: String, snoozeUntil: Date,
                       mandatory: Bool, blockedCurrent: Bool,
                       now: Date) -> PromptDecision {
        if blockedCurrent || mandatory { return .show }
        guard isNewer(normalize(latest), than: normalize(current)) else { return .upToDate }
        if !skippedVersion.isEmpty, normalize(skippedVersion) == normalize(latest) {
            return .skippedVersion
        }
        if now < snoozeUntil { return .snoozed }
        return .show
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

    // MARK: - Gösterim yardımcıları

    /// Kullanıcıya gösterilecek kısa tarih — sistem yereline uyar.
    static func displayDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}
