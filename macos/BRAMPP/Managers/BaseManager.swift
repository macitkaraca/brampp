import SwiftUI
import Combine

// MARK: - BaseManager

/// Tüm manager'ların ortak base class'ı.
/// Console logging, Homebrew guard, brew service kontrolü merkezileştirir.
///
/// Alt sınıflar: ServiceManager, DomainManager, PHPExtensionManager
@MainActor
class BaseManager: ObservableObject {

    // MARK: - Published

    @Published var isLoading: Bool = false

    /// Merkezi konsol store — tüm manager'lar aynı store'a yazar.
    let consoleStore: ConsoleStore

    init(consoleStore: ConsoleStore) {
        self.consoleStore = consoleStore
    }

    // MARK: - Console Logging

    /// Konsola yaz — merkezi ConsoleStore'a delege eder.
    /// ANAHTARSIZ: yalnızca dinamik metinler (brew çıktısı, shell stderr…) için.
    func log(_ message: String, type: ConsoleEntryType = .info) {
        consoleStore.log(message, type: type)
    }

    /// Konsola ÇEVRİLEBİLİR satır yaz — metin gösterim anında çözülür.
    /// Anahtar/argüman kuralları: Core/L10nLog.swift.
    func log(key: String, args: [String] = [], type: ConsoleEntryType = .info) {
        consoleStore.log(key: key, args: args, type: type)
    }

    // MARK: - Brew Guard

    /// Homebrew kurulu değilse konsola uyarı yazar ve `false` döner.
    /// Tüm brew-bağımlı işlemlerden önce çağrılmalıdır.
    /// `operationKey` bir LOG ANAHTARIDIR (ör. "log.op.domainCreate"); işlem adı burada
    /// ÇÖZÜLMEZ — anahtar (ve varsa kendi argümanları) `L10n.logArg` ile kodlanıp
    /// "Homebrew kurulu değil — … yapılamıyor" kalıbına argüman olarak girer.
    /// Böylece dil değişince satırın DIŞ kalıbı da İÇ işlem adı da yeni dile döner.
    func requireBrew(forKey operationKey: String, _ args: [String] = []) -> Bool {
        guard Shell.isBrewInstalled else {
            log(key: "log.base.brewMissing",
                args: [L10n.logArg(key: operationKey, args)], type: .error)
            log(key: "log.app.brewInstallHint", type: .info)
            return false
        }
        return true
    }

    // MARK: - Result Logging

    /// Shell sonucunu logla — başarı/hata mesajını otomatik yazar.
    /// `failureKey` kalıbı SONDA fazladan bir `%@` taşımalıdır: shell hata detayı
    /// oraya ARGÜMAN olarak geçer (detay yoksa boş string). Metni elle birleştirmek
    /// satırı log anında dondurur; anahtar+argüman ile satır dil değişiminde çevrilir.
    @discardableResult
    func logResult(_ result: Shell.Result, successKey: String, failureKey: String,
                   args: [String] = []) -> Bool {
        if result.isSuccess {
            log(key: successKey, args: args, type: .success)
        } else {
            let detail = result.error.isEmpty ? "" : ": \(result.error)"
            log(key: failureKey, args: args + [detail], type: .error)
        }
        return result.isSuccess
    }

    // MARK: - Brew Service Control

    /// Brew servisini yeniden başlat (Apache, PHP-FPM vb. için ortak pattern).
    /// Senkron `brew services restart` saniyeler sürüp @MainActor'ı (UI'yi) dondurduğundan
    /// arka planda çalıştırılır.
    func restartBrewService(_ serviceName: String, displayName: String) {
        guard requireBrew(forKey: "log.op.serviceRestart", [displayName]) else { return }
        log(key: "log.base.restarting", args: [displayName], type: .command)
        Task {
            let r = await Shell.brewServicesAsync("restart", service: serviceName)
            logResult(r, successKey: "log.base.restartOk", failureKey: "log.base.restartFail",
                      args: [displayName])
        }
    }
}
