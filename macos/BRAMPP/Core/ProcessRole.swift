import Foundation
import AppKit

/// "Bu SÜREÇ makinenin ortak geliştirme durumunu değiştirmeye yetkili mi?"
///
/// NEDEN VAR: BRAMPP'in tuttuğu her şey — `$HOME/…/BRAMPP` altındaki tünel dizini,
/// `last-running-services.json`, Homebrew servisleri, 8765'teki MCP dinleyicisi —
/// MAKİNEYE aittir, sürece değil. Aynı kullanıcının çalıştırdığı her kopya aynı
/// duruma bakar. Bu kopyalar bir tane değil:
///
///   • `/Applications/BRAMPP.app` — kullanıcının gerçekten kullandığı, yayında olan kopya
///   • Xcode'un Debug derlemesi — geliştirirken açılıp kapanır
///   • **XCTest ana uygulaması** — birim testler `TEST_HOST` ile UYGULAMANIN TAMAMINI
///     başlatır (`@main` dahil), üstelik her `xcodebuild test` koşusunda iki kez
///   • SwiftUI önizlemeleri
///
/// Yaşanan olay tam olarak buydu: ⌘U'ya basmak, kurulu kopyanın canlı Cloudflare
/// tünelini öldürdü, PID/log dosyalarını sildi ve 8765'te "Address already in use"
/// üretti. Kurulu kopyanın belleğindeki durum `.live` kaldığı için arayüz ile MCP
/// `list_shares` çalışan bir adres bildirmeye devam etti; Cloudflare ise Error 1033
/// döndürüyordu.
///
/// Bu yüzden "ortak duruma dokunan açılış işleri" TEK BİR kapıdan geçer:
/// `mayMutateSharedEnvironment`. Tünel toparlaması, MCP sunucusunun bağlanması,
/// otomatik servis başlatma ve durum kalıcılaştırması bu kapıya bakar — her biri
/// kendi ayrı kontrolünü uydurmaz.
///
/// KISITLAMANIN BEDELİ küçüktür: ikincil süreç yine tam olarak çalışır, yalnızca
/// makinenin ortak durumuna yazmaz. Alternatifin bedeli canlı bir yayının habersiz
/// kesilmesiydi.
///
/// `nonisolated`: bu sorular çıkış yolundan ve ana aktörü bekleyemeyen bağlamlardan
/// da sorulur.
enum ProcessRole {

    /// Süreç bir XCTest ana uygulaması mı?
    ///
    /// Üç ölçüt birlikte kullanılır çünkü hiçbiri tek başına her koşumda yok:
    /// `xcodebuild test` ile ⌘U farklı değişkenler geçirir, sınıf araması ise test
    /// paketi yüklendikten sonra kesin sonuç verir.
    nonisolated static var isTestHost: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestBundlePath"] != nil { return true }
        if env["XCTestSessionIdentifier"] != nil { return true }
        return NSClassFromString("XCTestCase") != nil
    }

    /// SwiftUI önizleme süreci mi? Önizlemeler de `@main`'i koşturur.
    nonisolated static var isPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    /// Aynı paket kimliğiyle YAŞAYAN başka bir kopya var mı?
    ///
    /// Xcode'un Debug derlemesi ile /Applications'taki kopya aynı `bundleIdentifier`'ı
    /// taşır; `NSRunningApplication` ikisini de görür. Böyle bir durumda ortak durumun
    /// sahibi belirsizdir — sahiplik kanıtlanamıyorsa yazılmaz.
    nonisolated static var hasOtherLiveInstance: Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != mine && !$0.isTerminated }
    }

    /// Yazmanın neden yasak olduğu — konsola tam nedeni yazabilmek için.
    enum Restriction {
        case testHost
        case preview
        case otherInstance

        /// Konsola yazılacak log anahtarı (TR/EN karşılıkları L10nLog+base.swift'te).
        var logKey: String {
            switch self {
            case .testHost, .preview: return "log.app.sharedEnvTestHost"
            case .otherInstance:      return "log.app.sharedEnvOtherInstance"
            }
        }
    }

    /// Kısıtlama varsa nedeni, yoksa `nil`.
    nonisolated static var restriction: Restriction? {
        if isTestHost { return .testHost }
        if isPreview { return .preview }
        if hasOtherLiveInstance { return .otherInstance }
        return nil
    }

    /// Ortak geliştirme ortamına yazma izni. TEK KAVRAM — tünel toparlaması,
    /// MCP dinleyicisi, otomatik servis başlatma ve durum kalıcılaştırması hep buna bakar.
    nonisolated static var mayMutateSharedEnvironment: Bool { restriction == nil }

    /// Bu süreç AÇILIŞTA kullanıcıya kendiliğinden bir pencere gösterebilir mi?
    ///
    /// `mayMutateSharedEnvironment` DEĞİL — bilerek daha dar. Ölçüt "makinenin ortak
    /// durumunu yazabilir miyim" değil, "ekranın önüne bir pencere koymam anlamlı mı":
    ///   • test ana uygulaması → `xcodebuild test` sırasında açılan pencere koşuyu bekletir
    ///   • önizleme            → Xcode kanvasına ağdan beslenen gerçek bir pencere düşerdi
    ///
    /// **`hasOtherLiveInstance` BU KAPIDA BİLEREK YOKTUR** — sapma kasıtlıdır ve
    /// `mayMutateSharedEnvironment`den bu tek maddeyle ayrılır. Gerekçesi, oradaki
    /// kaygının burada GEÇERSİZ olması:
    ///   • O kapı "makinenin ortak durumunu kim yazacak" sorusudur; sahiplik
    ///     kanıtlanamadığında yazmamak doğru yanıttır (canlı bir tünelin habersiz
    ///     kesilmesi).
    ///   • Bu kapı ise salt-okunur bir ağ denetimi ve bir bildirim penceresidir.
    ///     Yazdığı tek şey atlama/erteleme; ikisi de TEK alana son-yazan-kazanır
    ///     biçiminde iner, iki kopya arasında bozulacak bir değişmezlik yoktur.
    ///
    /// Kısıtlasaydık bedeli somut olurdu: kapanmakta olan (ama hâlâ `isTerminated`
    /// olmayan) bir önceki kopya yüzünden TAMAMEN NORMAL bir açılış hiç güncelleme
    /// haberi almazdı — üstelik sessizce. `startAutoRefresh` için zaten ödenmiş ve
    /// öğrenilmiş dersin aynısı (bkz. BRAMPPApp.swift, otomatik tazeleme yorumu).
    nonisolated static var mayPresentLaunchUI: Bool { !isTestHost && !isPreview }

    // MARK: - Log dosyasındaki süreç kimliği

    /// Paylaşılan konsol dosyasındaki satırın KİME ait olduğunu söyleyen kısa etiket.
    ///
    /// `ConsoleLogFile` dosyayı yalnızca TARİHE göre adlandırır, yani kurulu uygulama,
    /// Xcode derlemesi, test ana uygulaması ve önizlemeler AYNI dosyaya yazar. Olayı
    /// teşhis etmeyi bu kadar zorlaştıran şey buydu: 01:03'teki "bootstrap" satırlarının
    /// kimden geldiği dosyadan okunamıyordu. Etiket bir kez hesaplanır — süreç ömrü
    /// boyunca değişmez.
    nonisolated static let signature: String = {
        let pid = ProcessInfo.processInfo.processIdentifier
        return "\(kindTag) \(pid)"
    }()

    /// `signature`'ın metin kısmı. Kaynak, paketin diskteki yeri: DerivedData altından
    /// koşan bir kopya kullanıcının kurduğu kopya DEĞİLDİR.
    nonisolated static var kindTag: String {
        if isTestHost { return "test" }
        if isPreview { return "preview" }
        let path = Bundle.main.bundlePath
        if path.contains("/DerivedData/") || path.contains("/Build/Products/") { return "dev" }
        return "app"
    }
}
