import SwiftUI
import Combine

/// Cloudflare Quick Tunnel yönetimi — yerel bir alan adını geçici, herkese açık bir
/// `*.trycloudflare.com` adresine bağlar.
///
/// GÜVENLİK NOTU: bu sınıfın açtığı her tünel, geliştirme sitesini internete çıkarır.
/// Geliştirme siteleri çoğu zaman kimlik doğrulaması olmadan, hata ayıklama açık ve
/// yanında phpMyAdmin ile durur. Bu yüzden:
///   • hiçbir tünel kalıcı değildir ve otomatik başlamaz,
///   • uygulama kapanırken hepsi KOŞULSUZ durdurulur (`stopAll`),
///   • başlatma her zaman kullanıcının ya da açıkça izin verilmiş bir MCP çağrısının
///     eylemidir — arka planda kendiliğinden açılmaz.
@MainActor
final class TunnelManager: BaseManager {

    /// Alan adı → tünel. Yalnızca bellekte; diske YAZILMAZ.
    @Published private(set) var tunnels: [String: Tunnel] = [:]

    /// Adresin log dosyasında belirmesi için beklenecek süre.
    static let urlTimeout: TimeInterval = 30

    var activeCount: Int { tunnels.values.filter(\.isLive).count }

    func tunnel(for domainName: String) -> Tunnel? { tunnels[domainName] }

    // MARK: - Komut kurma

    /// cloudflared'in yerelde hedefleyeceği adres.
    ///
    /// IP DEĞİL alan adının kendisi kullanılır: `/etc/hosts` zaten 127.0.0.1'e eşliyor ve
    /// adı kullanınca hem SNI hem `Host` başlığı vhost ile eşleşir. IP'ye bağlanınca
    /// isim tabanlı vhost tutmaz, ziyaretçi varsayılan siteyi görür.
    static func origin(for domain: Domain) -> String {
        let scheme = domain.sslEnabled ? "https" : "http"
        let port   = domain.sslEnabled ? WebServerPorts.httpsPort(for: domain.webServer)
                                       : WebServerPorts.httpPort(for: domain.webServer)
        let suffix = WebServerPorts.portSuffix(port, https: domain.sslEnabled)
        return "\(scheme)://\(domain.name)\(suffix)"
    }

    /// Çalıştırılacak komut.
    ///
    /// `--http-host-header` ŞART: `--url` ile origin tanımlandığında cloudflared'in
    /// `Host` başlığını doğru göndermesinin tek yolu bu bayrak.
    ///
    /// SSL açıkken HTTP hedeflenmez: BRAMPP SSL'li vhost'a HTTP→HTTPS yönlendirmesi
    /// koyar, HTTP hedeflenirse ziyaretçi `https://<ad>` adresine yönlendirilir ve o ad
    /// internette çözülmediği için sayfa açılmaz. HTTPS hedefte `--no-tls-verify`
    /// gerekir (mkcert sertifikası); atlanan doğrulama YALNIZCA loopback bacağındadır,
    /// Cloudflare kenarına giden bağlantı şifreli kalır.
    static func buildCommand(for domain: Domain,
                             cloudflaredPath: String = PathConfig.cloudflared) -> String {
        let origin = origin(for: domain)
        var parts = [
            Shell.quote(cloudflaredPath), "tunnel",
            "--url", Shell.quote(origin),
            "--http-host-header", Shell.quote(domain.name),
        ]
        if domain.sslEnabled { parts.append("--no-tls-verify") }
        parts += [
            "--logfile", Shell.quote(PathConfig.tunnelLog(domain: domain.name)),
            "--loglevel", "info",
            // Ölçüm sunucusu sabit portlara bağlanmaya çalışıyor; birden çok tünelde
            // çakışıyordu. 0 = işletim sistemi boş port versin.
            "--metrics", "127.0.0.1:0",
        ]
        return parts.joined(separator: " ")
    }

    // MARK: - Adres ayrıştırma

    private static let urlPattern = try! NSRegularExpression(
        pattern: "https://[a-z0-9][a-z0-9-]*\\.trycloudflare\\.com")

    /// cloudflared log çıktısından herkese açık adresi çeker.
    ///
    /// Adres bir kutu çiziminin içinde, satır ortasında geçer:
    ///   `... |  https://foo-bar-baz.trycloudflare.com   |`
    /// bu yüzden satır başı/sonu değil, desen araması yapılır. Birden çok eşleşmede
    /// İLKİ alınır — sonrakiler aynı adresin tekrarıdır.
    static func parsePublicURL(from log: String) -> String? {
        let range = NSRange(log.startIndex..., in: log)
        guard let m = urlPattern.firstMatch(in: log, range: range),
              let r = Range(m.range, in: log) else { return nil }
        return String(log[r])
    }

    // MARK: - Başlat / Durdur

    /// cloudflared kurulu mu?
    static var isCloudflaredInstalled: Bool { FileHelper.exists(PathConfig.cloudflared) }

    @discardableResult
    func start(domain: Domain) async -> Bool {
        guard Self.isCloudflaredInstalled else {
            log(key: "log.tunnel.notInstalled", type: .error)
            return false
        }
        if let existing = tunnels[domain.name], existing.isLive {
            log(key: "log.tunnel.already", args: [domain.name], type: .warning)
            return true
        }

        _ = FileHelper.createDirectory(PathConfig.tunnels)
        // Eski log SİLİNİR: bir önceki oturumun adresi dosyada duruyorsa yeni tünelin
        // adresi sanılır ve kullanıcıya ölü bir bağlantı gösterilirdi.
        _ = FileHelper.remove(PathConfig.tunnelLog(domain: domain.name))

        let pidFile = PathConfig.tunnelPid(domain: domain.name)
        let cmd = Self.buildCommand(for: domain)
        log(key: "log.tunnel.starting", args: [domain.name], type: .command)

        tunnels[domain.name] = Tunnel(domainName: domain.name,
                                      origin: Self.origin(for: domain),
                                      publicURL: nil, pid: nil,
                                      startedAt: Date(), state: .starting)

        // nohup + arka plan: cloudflared uzun ömürlüdür, kabuk çağrısını bloklamamalı.
        let launch = "nohup \(cmd) >/dev/null 2>&1 & echo $!"
        let r = await Shell.bashAsync(launch)
        guard r.isSuccess,
              let pid = Int(r.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            tunnels[domain.name]?.state = .failed("cloudflared başlatılamadı")
            log(key: "log.tunnel.startFailed", args: [domain.name], type: .error)
            return false
        }
        _ = FileHelper.write("\(pid)", to: pidFile)
        tunnels[domain.name]?.pid = pid

        guard let url = await waitForURL(domain: domain.name) else {
            await stop(domainName: domain.name)
            tunnels[domain.name]?.state = .failed("adres alınamadı")
            log(key: "log.tunnel.urlTimeout", args: [domain.name], type: .error)
            return false
        }

        tunnels[domain.name]?.publicURL = url
        tunnels[domain.name]?.state = .active
        // Bu satır KASITLI olarak belirgin: makinenin internete açıldığı, kullanıcı
        // ekrana bakmasa bile konsolda iz bırakmalı.
        log(key: "log.tunnel.live", args: [domain.name, url], type: .success)
        return true
    }

    /// Adres log dosyasında belirene kadar bekler.
    private func waitForURL(domain: String) async -> String? {
        let deadline = Date().addingTimeInterval(Self.urlTimeout)
        let path = PathConfig.tunnelLog(domain: domain)
        while Date() < deadline {
            if let text = FileHelper.readString(path),
               let url = Self.parsePublicURL(from: text) {
                return url
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return nil
    }

    func stop(domainName: String) async {
        let pidFile = PathConfig.tunnelPid(domain: domainName)
        var pid = tunnels[domainName]?.pid
        if pid == nil, let raw = FileHelper.readString(pidFile) {
            pid = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let pid, NativeProcessManager.isAlive(pid) {
            // Süreç GERÇEKTEN bizim cloudflared'imiz mi? PID geri dönüştürülmüş olabilir;
            // doğrulamadan sinyal göndermek başkasının sürecini öldürürdü.
            let check = await Shell.bashAsync("ps -o comm= -p \(pid) 2>/dev/null")
            if check.output.contains("cloudflared") {
                _ = await Shell.bashAsync("kill \(pid) 2>/dev/null")
            }
        }
        _ = FileHelper.remove(pidFile)
        tunnels.removeValue(forKey: domainName)
        log(key: "log.tunnel.stopped", args: [domainName], type: .info)
    }

    /// Tüm tünelleri durdurur. Uygulama çıkışında KOŞULSUZ çağrılır.
    func stopAll() async {
        for name in Array(tunnels.keys) {
            await stop(domainName: name)
        }
    }

    /// Çıkış yolunda `await` edilemeyen bağlamlar için eşzamanlı kapatma.
    ///
    /// `applicationShouldTerminate` içinde asenkron iş bitmeden uygulama sonlanabilir;
    /// arkada açık kalmış herkese açık bir tünel kabul edilemez. Bu yüzden PID
    /// dosyalarından doğrudan, bloklayarak öldürülür.
    nonisolated static func killAllSynchronously() {
        for name in FileHelper.contentsOfDirectory(PathConfig.tunnels)
        where name.hasSuffix(".pid") {
            let path = "\(PathConfig.tunnels)/\(name)"
            guard let raw = FileHelper.readString(path),
                  let pid = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                  NativeProcessManager.isAlive(pid) else {
                _ = FileHelper.remove(path); continue
            }
            let check = Shell.run("/bin/ps", arguments: ["-o", "comm=", "-p", "\(pid)"])
            if check.output.contains("cloudflared") {
                kill(pid_t(pid), SIGTERM)
            }
            _ = FileHelper.remove(path)
        }
    }
}
