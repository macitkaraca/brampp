import Foundation
import AppKit
import Combine

// MARK: - Types

enum MkcertStatus { case brewNotInstalled, notInstalled, caNotInstalled, caNotTrusted, ready }

// MARK: - MkcertManager

@MainActor
class MkcertManager: ObservableObject {
    
    @Published var isMkcertInstalled: Bool = false
    @Published var isCAInstalled: Bool = false
    @Published var isCATrusted: Bool = false
    @Published var caRootPath: String = ""
    @Published var isChecking: Bool = false
    @Published var isInstalling: Bool = false

    /// Gerçek zamanlı kurulum log çıktısı — in-app progress sheet için
    @Published var installLog: String = ""
    @Published var installTitle: String = ""
    
    var status: MkcertStatus {
        if !Shell.isBrewInstalled { return .brewNotInstalled }
        if !isMkcertInstalled    { return .notInstalled }
        if !isCAInstalled        { return .caNotInstalled }
        if !isCATrusted          { return .caNotTrusted }
        return .ready
    }
    
    var needsSetup: Bool { status != .ready }
    
    init() {
        guard Shell.isBrewInstalled else { return }
        Task { await checkStatus() }
    }
    
    // MARK: - Status Check
    
    func checkStatus() async {
        guard !isChecking else { return }
        
        isChecking = true
        defer { isChecking = false }
        
        guard Shell.isBrewInstalled else {
            isMkcertInstalled = false
            isCAInstalled = false
            isCATrusted = false
            caRootPath = ""
            return
        }
        
        let mkcertInstalled = FileHelper.exists(PathConfig.mkcert)
        guard mkcertInstalled else {
            isMkcertInstalled = false
            isCAInstalled = false
            isCATrusted = false
            caRootPath = ""
            return
        }
        
        let rootResult = await Shell.runAsync(PathConfig.mkcert, arguments: ["-CAROOT"])
        guard rootResult.isSuccess else {
            isMkcertInstalled = true
            isCAInstalled = false
            isCATrusted = false
            caRootPath = ""
            return
        }
        
        let resolvedCARootPath = rootResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let caInstalled = FileHelper.exists("\(resolvedCARootPath)/rootCA.pem") && FileHelper.exists("\(resolvedCARootPath)/rootCA-key.pem")
        let caTrusted = caInstalled ? await checkCATrust(certPath: "\(resolvedCARootPath)/rootCA.pem") : false
        
        isMkcertInstalled = true
        caRootPath = resolvedCARootPath
        isCAInstalled = caInstalled
        isCATrusted = caTrusted
    }
    
    // MARK: - Install
    
    func installMkcert(logger: ((String, ConsoleEntryType) -> Void)? = nil) async -> Bool {
        guard Shell.isBrewInstalled else { logger?("⚠️ Önce Homebrew kurun", .error); return false }
        guard !isInstalling else { return false }

        isInstalling = true
        installTitle = Localizer.shared.t("mkcert.installing.title")
        installLog   = "🚀 mkcert & nss kurulum başlatılıyor...\nbrew install mkcert nss\n\n"
        defer { isInstalling = false }

        logger?("mkcert kuruluyor...", .command)

        let r = await Shell.streamBash("brew install mkcert nss") { [weak self] line in
            self?.installLog += ServiceManager.stripANSI(line) + "\n"
        }

        await checkStatus()

        if isMkcertInstalled {
            installLog += "\n✅ mkcert kuruldu!\n"
            logger?("✅ mkcert kuruldu!", .success)
            return true
        } else {
            installLog += "\n❌ Kurulum başarısız (kod: \(r.exitCode))\n"
            if !r.error.isEmpty { installLog += r.error + "\n" }
            logger?("❌ mkcert kurulumu başarısız", .error)
            return false
        }
    }

    func installCA(logger: ((String, ConsoleEntryType) -> Void)? = nil) async -> Bool {
        guard Shell.isBrewInstalled else { logger?("⚠️ Önce Homebrew kurun", .error); return false }
        guard isMkcertInstalled else { logger?("❌ Önce mkcert kurun", .error); return false }
        guard !isInstalling else { return false }

        isInstalling = true
        installTitle = Localizer.shared.t("mkcert.ca.title")
        installLog   = "🔐 mkcert CA kurulum başlatılıyor...\n\n"
        installLog  += "ℹ️  Sistem anahtarlığına erişim için yönetici şifresi gerekecek.\n\n"
        defer { isInstalling = false }

        logger?("CA kurulumu başlatılıyor...", .info)

        // mkcert -install içinde `sudo security add-trusted-cert` çağırır.
        // osascript üzerinden çalışan alt süreçlerde SecTrustSettingsSetTrustSettings
        // interaktif yetki istediği için başarısız olur.
        // Çözüm: CA dosyasını mkcert ile oluştur, trust adımını doğrudan osascript ile yap.
        let mkcertPath = PathConfig.mkcert

        // CAROOT yolunu öğren
        let carootResult = await Shell.runAsync(mkcertPath, arguments: ["-CAROOT"])
        let caroot = carootResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let certPath    = "\(caroot)/rootCA.pem"
        let keyPath     = "\(caroot)/rootCA-key.pem"
        let certExists = FileHelper.exists(certPath)
        let keyExists  = FileHelper.exists(keyPath)

        // rootCA.pem VAR ama rootCA-key.pem YOK — kalıcı kilitlenme.
        //
        // mkcert bu durumda "keyless" moda düşer: mevcut sertifika durduğu için YENİ
        // bir CA üretmez, kaybolan anahtarı da geri getiremez (yeni anahtar mevcut
        // sertifikayla eşleşmezdi). Eskiden buradan sessizce geçiliyor, ardından
        // hiçbir yaprak sertifika imzalanamıyor ve düğme sonsuza dek anlamsız bir
        // "CA kurulumu başarısız (kod: 0)" veriyordu. Çıkış yolu CAROOT'u temizlemek,
        // ama bunu KULLANICI seçmeli: eski CA'yla imzalanmış sertifikaların hepsi
        // geçersizleşir ve her alan adının yeniden üretilmesi gerekir.
        if certExists && !keyExists {
            installLog += """

            ❌ Yerel CA bozuk: rootCA.pem var ama rootCA-key.pem yok.
               mkcert bu durumda yeni bir CA üretmez ve hiçbir sertifika imzalayamaz.
               Çözüm: \(caroot) dizinini silip mkcert adımını yeniden çalıştırın.
               UYARI: eski CA ile üretilmiş tüm site sertifikaları geçersiz olur ve
               yeniden üretilmeleri gerekir.

            """
            logger?("❌ Yerel CA bozuk — rootCA-key.pem eksik", .error)
            return false
        }

        let alreadyExists = certExists && keyExists

        // Adım 1: CA sertifika dosyaları yoksa oluştur (sudo gerekmez).
        // MKCERT_TRUST_STORES=none → güven kurma adımını atla, sadece dosyaları oluştur.
        if alreadyExists {
            installLog += "ℹ️  CA dosyaları zaten mevcut, oluşturma adımı atlanıyor.\n"
        } else {
            installLog += "▶️ CA dosyaları oluşturuluyor...\n"
            let genEnv = "MKCERT_TRUST_STORES=none"
            let gen = await Shell.bashAsync("\(genEnv) \(mkcertPath) -install 2>&1 || true")
            if !gen.output.isEmpty { installLog += gen.output + "\n" }

            guard FileHelper.exists(certPath) else {
                installLog += "\n❌ rootCA.pem oluşturulamadı: \(certPath)\n"
                logger?("❌ CA dosyası bulunamadı", .error)
                return false
            }
        }

        // Adım 2: Sertifikayı kullanıcı anahtarlığına ekle — sudo gerektirmez.
        // Sistem anahtarlığı (-d) macOS'un interaktif yetki mekanizması olmadan çalışmaz.
        // Kullanıcı anahtarlığına eklemek geliştirme ortamı için yeterlidir (Safari, Chrome, curl güvenir).
        let loginKeychain = "\(NSHomeDirectory())/Library/Keychains/login.keychain-db"
        installLog += "\n▶️ Kullanıcı anahtarlığına ekleniyor...\n"
        let trustCmd = "/usr/bin/security add-trusted-cert -r trustRoot -k '\(loginKeychain)' '\(certPath)'"
        let r = await Shell.bashAsync(trustCmd)
        if !r.output.isEmpty { installLog += r.output + "\n" }
        if !r.error.isEmpty  { installLog += r.error  + "\n" }

        await checkStatus()

        if isCATrusted {
            installLog += "\n✅ CA kuruldu ve güvenilir!\n"
            logger?("✅ CA kuruldu ve güvenilir!", .success)
            return true
        } else if isCAInstalled {
            installLog += "\n⚠️ CA oluşturuldu ama henüz güvenilir değil.\n"
            logger?("⚠️ CA oluşturuldu ama güvenilir değil", .warning)
            return false
        } else {
            installLog += "\n❌ CA kurulumu başarısız (kod: \(r.exitCode))\n"
            logger?("❌ CA kurulumu başarısız", .error)
            return false
        }
    }
    
    func generateCertificate(for domain: String, logger: ((String, ConsoleEntryType) -> Void)? = nil) async -> Bool {
        guard Shell.isBrewInstalled else { logger?("⚠️ Homebrew kurulu değil", .error); return false }
        guard status == .ready else { logger?("❌ mkcert hazır değil", .error); return false }
        
        let certDir = certificateDirectory(for: domain)
        guard FileHelper.createDirectory(certDir) else { logger?("❌ Dizin oluşturulamadı", .error); return false }
        
        logger?("🔐 \(domain) SSL sertifikası oluşturuluyor...", .command)
        let arguments = mkcertArguments(for: domain, certDir: certDir)
        let r = await Shell.runAsync(PathConfig.mkcert, arguments: arguments)
        
        if r.isSuccess { logger?("✅ SSL sertifikası oluşturuldu", .success) }
        else { logger?("❌ SSL oluşturulamadı: \(r.output)", .error) }
        return r.isSuccess
    }
    
    private func certificateDirectory(for domain: String) -> String {
        if domain == "localhost" {
            return PathConfig.localhostSSLDir
        }
        return "\(PathConfig.sslDir)/\(domain)"
    }
    
    private func mkcertArguments(for domain: String, certDir: String) -> [String] {
        let certFile = "\(certDir)/cert.pem"
        let keyFile = "\(certDir)/key.pem"
        
        if domain == "localhost" {
            return [
                "-cert-file", certFile,
                "-key-file", keyFile,
                "localhost",
                "127.0.0.1",
                "::1"
            ]
        }
        
        return [
            "-cert-file", certFile,
            "-key-file", keyFile,
            domain,
            "*.\(domain)"
        ]
    }
    
    func openCAFolder() {
        guard !caRootPath.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: caRootPath)
    }
    
    /// CA gerçekten GÜVENİLİR mi? Tek ölçüt `security verify-cert`: sertifika zincirini
    /// sistemin kendi güven politikasına göre değerlendirir ve `installCA`'nın kurduğu
    /// duruma (login.keychain + `-r trustRoot`) 0 döner.
    ///
    /// NOT: Eskiden verify-cert başarısız olunca `dump-trust-settings` çıktısında "mkcert"
    /// METNİ aranıp true dönülüyordu. Bu yanlıştı: dump-trust-settings bir sertifikayı
    /// HERHANGİ bir güven kaydı olduğunda listeler — açıkça "Asla Güvenme (Deny)" olarak
    /// işaretlenmiş olsa bile. Sonuç: uygulama "CA güvenilir" derken tarayıcılar
    /// sertifikayı reddediyordu ve kullanıcı sorunu göremiyordu.
    private func checkCATrust(certPath: String) async -> Bool {
        let verify = await Shell.runAsync("/usr/bin/security", arguments: ["verify-cert", "-c", certPath])
        return verify.isSuccess
    }
}
