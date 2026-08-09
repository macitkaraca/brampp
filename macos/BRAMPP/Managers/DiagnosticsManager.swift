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

        // ── mkcert kök sertifikası ──────────────────────────────────────────
        let caDir = await Shell.bashAsync("\(PathConfig.mkcert) -CAROOT 2>/dev/null")
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        if FileHelper.exists(PathConfig.mkcert) {
            let root = "\(caDir)/rootCA.pem"
            if FileHelper.exists(root) {
                // Üretilmiş olması yetmez; sistem güven deposunda OLMASI gerekir,
                // yoksa tarayıcı yerel sertifikaları yine reddeder.
                let trusted = await Shell.bashAsync(
                    "security find-certificate -a -p /Library/Keychains/System.keychain "
                  + "2>/dev/null | grep -c 'BEGIN CERTIFICATE'")
                let n = Int(trusted.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                out.append(.init(id: "mkcert", title: "Yerel sertifika otoritesi",
                                 level: n > 0 ? .pass : .warn,
                                 detail: n > 0 ? "sistem güven deposunda"
                                               : "üretilmiş ama güven deposunda görünmüyor",
                                 remedy: n > 0 ? nil
                                       : "Kurulum sihirbazındaki mkcert adımını yeniden çalıştırın."))
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
