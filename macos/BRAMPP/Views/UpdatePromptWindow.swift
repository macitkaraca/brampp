import SwiftUI
import AppKit

/// Güncelleme bildirimini taşıyan AppKit penceresi.
///
/// **NEDEN SHEET DEĞİL.** Sheet bir ÜST pencereye aittir ve bu uygulamada üst
/// pencereyi ortadan kaldıran iki normal davranış var:
///   • `hideWindowOnClose` → kırmızı X pencereyi `orderOut` edip uygulamayı
///     `.accessory` yapar (BRAMPPApp.swift, WindowHideInterceptor). Pencere yaşıyor
///     ama ekranda değil.
///   • Menü çubuğundan yaşayan kullanıcı ana pencereyi hiç açmaz.
/// RootView bu hatayı zaten belgeliyor: *"Pencere gizliyken sheet görünmez
/// kuyruklanır ve çok sonra beklenmedik anda belirirdi"*. Oradaki çözüm önce ana
/// pencereyi öne getirmek; HER AÇILIŞTA bunu yapmak, girişte menü çubuğuna açılan
/// bir uygulamanın penceresini kullanıcının suratına atmak olurdu.
///
/// **NEDEN SwiftUI `Window` SAHNESİ DEĞİL.** macOS 14'te `App` gövdesindeki bir
/// `Window` sahnesi açılışta kendiliğinden açılır; bunu bastıran
/// `.defaultLaunchBehavior(.suppressed)` macOS 15+. Dağıtım hedefi 14.0 olduğundan
/// her açılışta boş bir güncelleme penceresi belirirdi.
///
/// **`.accessory` KİPİNDE ÇALIŞIR.** Yardımcı uygulama da pencereyi key yapabilir.
/// `setActivationPolicy(.regular)` BİLEREK ÇAĞRILMAZ — kullanıcının bilerek
/// kaldırdığı Dock ikonunu geri getirirdi.
@MainActor
final class UpdatePromptWindowController: NSObject, NSWindowDelegate {

    static let shared = UpdatePromptWindowController()

    private var window: NSWindow?
    /// Şu an gösterilen sürüm — aynı sürüm için ikinci pencere açılmaz.
    private var shownVersion: String?

    /// **TEK kurucu.** Pencere her açılışında yenisi YARATILMAZ.
    ///
    /// Yaratılıyordu ve şu oluyordu: kurucular hazırlık dizinini sürümden türetiyordu,
    /// yani iki kurucu AYNI dizini paylaşırdı. İndirmeyi başlat, pencereyi kapat (eski
    /// kod indirmeyi durdurmuyordu), yeniden aç → yeni kurucu dizini siliyor, birincisi
    /// hata verip temizlenirken bu kez ikincinin dizinini siliyordu. İki kırmızı hata,
    /// sıfır indirme.
    ///
    /// Dizin ARTIK koşu başına türetiliyor (`PathConfig.updateStagingName(version:run:)`),
    /// yani o çakışma zaten ifade edilemez. Tek örnek yine de doğru: iki kurucu iki ayrı
    /// `phase` demektir ve kullanıcı aynı sürüm için iki ilerleme çubuğu, iki "Durdur"
    /// düğmesi görürdü. Sınır artık dosyaların değil, ARAYÜZÜN bütünlüğü.
    private let installer = UpdateInstaller()

    private override init() { super.init() }

    // MARK: - Sunum

    func present(current: String, release: UpdateChecker.ReleaseInfo, console: ConsoleStore?) {
        // Aynı sürüm zaten gösteriliyorsa yeni pencere değil, öne getirme.
        if let window, shownVersion == release.version {
            focus(window)
            return
        }
        // Başka bir sürüm gösteriliyorduysa onun indirmesi de biter: kullanıcının
        // artık göremediği bir ilerleme, ilerleme değildir.
        closeWindow()

        shownVersion = release.version
        installer.console = console

        let settings = AppSettings.load()
        let mode = UpdateMode.from(settings.updateMode)

        let root = UpdatePromptView(
            current: current,
            release: release,
            installer: installer,
            mode: mode,
            onSkip: { [weak self] in self?.skip(release, console: console) },
            onSnooze: { [weak self] until in self?.snooze(until: until, console: console) },
            onClose: { [weak self] in self?.closeWindow() }
        )
        .environmentObject(Localizer.shared)

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                           styleMask: [.titled, .closable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = Localizer.shared.t("upd.title")
        // SwiftUI barındıran pencere kapanınca serbest bırakılırsa, delegate
        // geri çağrısı serbest bırakılmış nesneye düşer.
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: root)
        win.delegate = self
        win.center()
        window = win

        // Ayarlar → "yeni sürüm bulununca arka planda indir": kullanıcı bunu
        // AÇIKÇA istediyse indirme pencereyle birlikte başlar. Kurulum yine yok.
        if settings.updateAutoDownload, mode != .notify, release.sha256 != nil {
            installer.start(release, openWhenReady: mode == .downloadAndOpen)
        }

        focus(win)
    }

    /// Elle denetimde yeni sürüm ÇIKMADIĞINDA kullanıcı yine de bir yanıt görmeli —
    /// menüden bir şey isteyip hiçbir şey olmaması, özelliğin bozuk olduğunu düşündürür.
    func showInfo(_ message: String) {
        let alert = NSAlert()
        alert.messageText = Localizer.shared.t("set.update.check")
        alert.informativeText = message
        alert.addButton(withTitle: Localizer.shared.t("common.close"))
        alert.runModal()
    }

    /// Sunum bir sonraki run-loop turuna ERTELENİR — `presentMainWindow`'daki iki
    /// nedenin aynısı: MenuBarExtra popover'ı tıklama anında key penceredir ve
    /// kapanışında key durumunu geri alır; `.accessory → .regular` geçişleri de
    /// WindowServer'a bir tur sonra işler.
    private func focus(_ win: NSWindow) {
        DispatchQueue.main.async {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// **Pencere kapanınca indirme de DURUR.**
    ///
    /// İki gerekçe:
    ///   • Kullanıcının göremediği bir indirme, iptal edilemeyen bir indirmedir —
    ///     ilerleme çubuğu da "durdur" düğmesi de o pencereyle birlikte gitti.
    ///   • Arkada koşmaya devam eden bir kurucu, bir sonraki açılışta aynı hazırlık
    ///     dizini için ikinci bir koşu demekti (bkz. `installer` yorumu).
    ///
    /// `cancel()` doğrulanmış ama KURULMAMIŞ dosyayı da siler. Bu bilinçli: kullanıcı
    /// "aç"a basmadan pencereyi kapattıysa ~60 MB'lık kalıbı, varlığından habersiz
    /// olduğu bir dizinde bırakmanın gerekçesi yok — bir sonraki denetimde yeniden
    /// inebilir.
    private func closeWindow() {
        installer.cancel()
        window?.delegate = nil
        window?.close()
        window = nil
        shownVersion = nil
    }

    // MARK: - Kullanıcı kararları

    /// "Bu sürümü atla" — ERTELEMEYİ DE TEMİZLER: daha açık ve daha güçlü karar
    /// budur, ikisinin bir arada durması ileride belirsizlik üretirdi.
    private func skip(_ release: UpdateChecker.ReleaseInfo, console: ConsoleStore?) {
        var s = AppSettings.load()
        s.updateSkippedVersion = release.version
        s.updateSnoozeUntil = 0
        s.save()
        console?.log(key: "log.app.updateSkipped", args: [release.version], type: .info)
        NotificationCenter.default.post(name: .updateStateChanged, object: nil)
        closeWindow()
    }

    /// "Sonra hatırlat" — atlamayı BOZMAZ; erteleme daha zayıf bir karardır.
    private func snooze(until date: Date, console: ConsoleStore?) {
        var s = AppSettings.load()
        s.updateSnoozeUntil = date.timeIntervalSince1970
        s.save()
        console?.log(key: "log.app.updateSnoozed",
                     args: [UpdateChecker.displayDate(date)], type: .info)
        NotificationCenter.default.post(name: .updateStateChanged, object: nil)
        closeWindow()
    }

    // MARK: - NSWindowDelegate

    /// Düz kapatma HİÇBİR ŞEY YAZMAZ: bir sonraki açılışta yeniden sorulur.
    /// "Kapat"ın "atla"dan farkı tam olarak budur.
    ///
    /// KIRMIZI X DE İNDİRMEYİ DURDURUR. Bu yol `closeWindow()`'dan geçmez (pencereyi
    /// AppKit kapatır), dolayısıyla iptal burada da ÇAĞRILMAK ZORUNDA — yoksa
    /// kullanıcının kapattığı pencerenin indirmesi arkada yaşamaya devam ederdi.
    func windowWillClose(_ notification: Notification) {
        installer.cancel()
        window = nil
        shownVersion = nil
    }
}
