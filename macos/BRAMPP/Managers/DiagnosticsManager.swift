import SwiftUI
import Combine

/// Teşhis denetimlerini koşturur. Yorumlama `Core/Diagnostics.swift` içinde ve saftır;
/// burada yalnızca gerçek durumu toplama işi var.
@MainActor
final class DiagnosticsManager: BaseManager {

    @Published private(set) var findings: [Diagnostics.Finding] = []
    @Published private(set) var isRunning = false
    @Published private(set) var lastRun: Date?

    var summary: Diagnostics.Level { Diagnostics.summary(findings) }

    /// Bir portu dinleyen sürecin adı ve PID'i.
    ///
    /// `lsof` PID ve komut adını birlikte verir; iki ayrı çağrı yapmak yerine tek
    /// çağrıdan ikisi de okunur — arada süreç değişirse tutarsız rapor çıkardı.
    private func portOwner(_ port: Int) async -> (name: String?, pid: Int?) {
        let r = await Shell.bashAsync(
            "lsof -nP -iTCP:\(port) -sTCP:LISTEN -Fcp 2>/dev/null | head -4")
        var name: String?, pid: Int?
        for line in r.output.components(separatedBy: .newlines) {
            if line.hasPrefix("p") { pid = Int(line.dropFirst()) }
            if line.hasPrefix("c") { name = String(line.dropFirst()) }
        }
        return (name, pid)
    }

    // MARK: - Alias sırası onarımı

    /// Onarılabilecek companion yapılandırmaları — (yol, Alias öneki, güncel içerik).
    private var repairableConfigs: [(path: String, prefix: String, content: String)] {
        [(PathConfig.phpmyadminConf, "/phpmyadmin", VHostTemplates.phpmyadminConfig()),
         (PathConfig.adminerConf,    "/adminer",    VHostTemplates.adminerApacheConfig())]
    }

    /// Eski Alias sırasını taşıyan, BRAMPP'ın kendi yazdığı bir dosya var mı?
    var canRepairAliasOrder: Bool {
        repairableConfigs.contains { c in
            guard let text = FileHelper.readString(c.path) else { return false }
            return Diagnostics.aliasOrderIsWrong(text, prefix: c.prefix)
        }
    }

    /// Bozuk sıralı dosyaları güncel şablonla yeniden yazar.
    ///
    /// PAYLAŞILAN Apache yapılandırmasına dokunuyoruz, o yüzden üç koruma birlikte:
    /// önce `.brampp.bak` yedeği, sonra `configtest`, geçmezse YEDEKTEN GERİ DÖNÜŞ.
    /// Denetimin "sihirbaz configtest'siz, yedeksiz, geri alınamaz yazıyor" bulgusu
    /// tam da bunun yokluğuydu; yeni bir yazıcı eklerken aynı hatayı tekrarlamıyoruz.
    func repairAliasOrder() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        var restored: [(String, String)] = []      // (yol, eski içerik)
        var rewritten = 0

        for c in repairableConfigs {
            guard let old = FileHelper.readString(c.path),
                  Diagnostics.aliasOrderIsWrong(old, prefix: c.prefix) else { continue }
            guard FileHelper.write(old, to: c.path + ".brampp.bak") else {
                log(key: "log.diag.repairBackupFailed", args: [c.path], type: .error)
                continue
            }
            guard FileHelper.write(c.content, to: c.path) else {
                log(key: "log.diag.repairWriteFailed", args: [c.path], type: .error)
                continue
            }
            restored.append((c.path, old))
            rewritten += 1
        }

        guard rewritten > 0 else { return }

        let test = await Shell.brewBashAsync("apachectl configtest 2>&1")
        if Diagnostics.configVerdict(server: "Apache", output: test.output,
                                     exitOK: test.isSuccess).level == .fail {
            for (path, old) in restored { _ = FileHelper.write(old, to: path) }
            log(key: "log.diag.repairRolledBack", type: .error)
            await run()
            return
        }

        _ = await Shell.brewBashAsync("\(PathConfig.brew) services restart httpd 2>&1")
        log(key: "log.diag.repaired", args: ["\(rewritten)"], type: .success)
        await run()
    }

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false; lastRun = Date() }

        var out: [Diagnostics.Finding] = []

        // ── Homebrew ────────────────────────────────────────────────────────
        if Shell.isBrewInstalled {
            out.append(.init(id: "brew", title: "Homebrew", level: .pass,
                             detail: Shell.brewPrefix, remedy: nil))
        } else {
            out.append(.init(id: "brew", title: "Homebrew", level: .fail,
                             detail: "bulunamadı",
                             remedy: "BRAMPP Homebrew servislerini yönetir; onsuz hiçbir "
                                   + "servis başlatılamaz. brew.sh üzerinden kurun."))
        }

        // ── Portlar ─────────────────────────────────────────────────────────
        // Beklenen sahibi olan portlar denetlenir. Kurulu olmayan servisin portuna
        // bakmak anlamsız — "boşta" demek kullanıcıyı yanıltırdı.
        var ports: [(Int, String)] = []
        if FileHelper.exists(PathConfig.httpdConf) {
            ports.append((WebServerPorts.apacheHTTP(), "httpd"))
            ports.append((WebServerPorts.apacheHTTPS(), "httpd"))
        }
        if FileHelper.exists(PathConfig.nginxConf) {
            ports.append((WebServerPorts.nginxHTTP(), "nginx"))
            ports.append((WebServerPorts.nginxHTTPS(), "nginx"))
        }
        for (port, expected) in ports {
            let owner = await portOwner(port)
            out.append(Diagnostics.portConflict(port: port, expectedProcess: expected,
                                                actualProcess: owner.name, actualPID: owner.pid))
        }

        // ── Yapılandırma sözdizimi ──────────────────────────────────────────
        if FileHelper.exists(PathConfig.httpdConf) {
            let r = await Shell.bashAsync("\(Shell.brewPrefix)/bin/apachectl configtest 2>&1")
            out.append(Diagnostics.configVerdict(server: "Apache", output: r.output,
                                                 exitOK: r.isSuccess))
        }
        if FileHelper.exists(PathConfig.nginxConf) {
            let r = await Shell.bashAsync("\(Shell.brewPrefix)/bin/nginx -t 2>&1")
            out.append(Diagnostics.configVerdict(server: "Nginx", output: r.output,
                                                 exitOK: r.isSuccess))
        }

        // ── Apache/Nginx port çakışması ─────────────────────────────────────
        // BRAMPP'ın şeması: Apache 80/443, Nginx 8080/8443. İkisinin aynı anda
        // çalışabilmesi bu ayrıma dayanıyor. Homebrew'un stok httpd-ssl.conf'u
        // `Listen 8443` ile geldiğinden Apache nginx'in portuna oturabiliyor ve
        // ikinci başlayan servis "Address already in use" ile düşüyor — kullanıcıya
        // görünen tek şey "nginx başlamıyor" oluyor, sebebi Apache'de olduğu hâlde.
        let aHTTPS = WebServerPorts.apacheHTTPS()
        let nHTTPS = WebServerPorts.nginxHTTPS()
        let aHTTP  = WebServerPorts.apacheHTTP()
        let nHTTP  = WebServerPorts.nginxHTTP()
        for (label, a, n) in [("HTTPS", aHTTPS, nHTTPS), ("HTTP", aHTTP, nHTTP)] where a == n {
            out.append(.init(id: "portclash-\(label)", title: "Apache ve Nginx aynı portta",
                             level: .fail,
                             detail: "ikisi de \(label) için \(a) numaralı portu kullanıyor",
                             remedy: "Aynı anda yalnızca biri çalışabilir; ikinci başlayan "
                                   + "\"Address already in use\" ile düşer. BRAMPP'ın şeması "
                                   + "Apache 80/443, Nginx 8080/8443'tür — Servisler → Apache "
                                   + "Portları'ndan düzeltin."))
        }

        // ── PHP-FPM portu: dosya ile BRAMPP'ın beklentisi ayrışmış mı ───────
        // Çok sürümlü PHP ayrı portlara dayanıyor: vhost'lar `PHPVersion.port` SABİTİNİ
        // yazıyor, `www.conf` da ona uydurulmalı. Ama dosya kullanıcının; Homebrew stok
        // hâlde 9000 veriyor ve BRAMPP artık onu sessizce düzeltmiyor (düzeltmek bir
        // DURUM OKUMASINDAN yapılıyordu ve çalışan daemon'un altından dosyayı değiştirip
        // hiçbir şeyi yeniden başlatmıyordu — sonuç 502'ydi). Ayrışma artık burada,
        // sonucuyla birlikte söyleniyor. Bu bir EMNİYET AĞI: açılışta
        // `reconcilePHPFPMPorts` düzeltmeyi yeniden başlatmayla BİRLİKTE yapıyor, yani
        // bu bulgu ancak o düzeltme koşamadığında ya da başarısız olduğunda görünür.
        for v in PHPVersion.allCases where PathConfig.isPHPInstalled(version: v.rawValue) {
            guard let actual = PHPFPMConfigManager.currentListenPort(for: v.rawValue) else { continue }
            let expected = v.port
            guard actual != expected else { continue }
            out.append(.init(id: "phpport-\(v.rawValue)",
                             title: "PHP \(v.rawValue) portu ayrışmış",
                             level: .fail,
                             detail: "www.conf \(actual) diyor, BRAMPP \(expected) bekliyor",
                             remedy: "VHost'lar \(expected) numaralı porta yönlendiriyor; PHP-FPM ise "
                                   + "\(actual) portunda dinliyor, yani bu sürümü kullanan siteler "
                                   + "502 döner. BRAMPP bunu açılışta kendiliğinden düzeltir — burada "
                                   + "görünüyorsa düzeltme yapılamamış demektir (www.conf yazılamadı, "
                                   + "servis yeniden başlatılamadı ya da bu kopya makinenin ortak "
                                   + "durumuna dokunmuyor). Konsolda sebebi yazar."))
        }

        // ── mkcert kök sertifikası ──────────────────────────────────────────
        let caDir = await Shell.bashAsync("\(PathConfig.mkcert) -CAROOT 2>/dev/null")
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        if FileHelper.exists(PathConfig.mkcert) {
            let root = "\(caDir)/rootCA.pem"
            if FileHelper.exists(root) {
                // Üretilmiş olması yetmez; sistemin güven POLİTİKASINA göre gerçekten
                // güvenilmesi gerekir.
                //
                // Eski denetim `find-certificate -a … | grep -c 'BEGIN CERTIFICATE'`
                // idi: System anahtarlığındaki HER sertifikayı sayıyordu. Apple'ın kök
                // sertifikaları orada durduğundan sayı hiçbir zaman sıfır olmuyor ve
                // denetim mkcert'in kökünü hiç ARAMADAN her koşulda "geçti" diyordu.
                // `verify-cert` zinciri değerlendirir: login ve system anahtarlıklarını
                // birlikte görür ve "Asla Güvenme" işaretli bir sertifikada düşer.
                let verify = await Shell.runAsync("/usr/bin/security",
                                                  arguments: ["verify-cert", "-c", root])
                let trusted = verify.isSuccess
                out.append(.init(id: "mkcert", title: "Yerel sertifika otoritesi",
                                 level: trusted ? .pass : .warn,
                                 detail: trusted ? "sistem güven deposunda"
                                                 : "üretilmiş ama güvenilmiyor",
                                 remedy: trusted ? nil
                                       : "Tarayıcı yerel sertifikaları reddeder. Kurulum "
                                       + "sihirbazındaki mkcert adımını yeniden çalıştırın."))
            } else {
                out.append(.init(id: "mkcert", title: "Yerel sertifika otoritesi", level: .warn,
                                 detail: "henüz üretilmemiş",
                                 remedy: "HTTPS'li alan adları için gerekli. Kurulum sihirbazından üretin."))
            }
        }

        // ── /etc/hosts ──────────────────────────────────────────────────────
        if let hosts = FileHelper.readString("/etc/hosts") {
            out.append(.init(id: "hosts", title: "/etc/hosts", level: .pass,
                             detail: "\(hosts.components(separatedBy: .newlines).count) satır, okunabilir",
                             remedy: nil))
        } else {
            out.append(.init(id: "hosts", title: "/etc/hosts", level: .fail,
                             detail: "okunamadı",
                             remedy: "Alan adları bu dosyaya yazılır; okunamıyorsa hiçbiri çözülmez."))
        }

        findings = Diagnostics.sorted(out)
        log(key: summary == .pass ? "log.diag.clean" : "log.diag.issues",
            args: ["\(findings.filter { $0.level != .pass }.count)"],
            type: summary == .fail ? .error : (summary == .warn ? .warning : .success))
    }
}
