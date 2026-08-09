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

    /// Son başlatma denemesinin engellenme nedeni — arayüz bunu gösterir.
    @Published private(set) var lastBlock: ShareBlock?
    /// Son port paylaşımı denemesinin reddedilme nedeni.
    @Published private(set) var lastPortRefusal: PortRefusal?

    /// Adresin log dosyasında belirmesi için beklenecek süre.
    static let urlTimeout: TimeInterval = 30

    var activeCount: Int { tunnels.values.filter(\.isLive).count }

    func tunnel(for domainName: String) -> Tunnel? { tunnels[domainName] }

    // MARK: - Komut kurma

    /// cloudflared'in yerelde hedefleyeceği adres — DOĞRUDAN 127.0.0.1.
    ///
    /// Alan adını hedeflemek her isteğe ad çözümlemesi maliyeti bindiriyordu. `.local`
    /// uzantısı Multicast DNS'e gider; macOS'ta bu **istek başına 5 saniye** zaman
    /// aşımıyla sonuçlanıp ancak sonra `/etc/hosts`'a düşüyor. Aynı sitede ölçüm:
    /// alan adıyla 5,01 sn, doğrudan IP ile 0,012 sn.
    ///
    /// IP'ye bağlanmak tek başına yetmez — vhost eşleşmesi için `Host` başlığı ve
    /// TLS'te SNI de alan adı olmalı. İkisi `buildCommand` içinde ayrıca veriliyor;
    /// yalnızca `Host` verilip SNI atlanırsa sunucu 421 döner.
    static func origin(for domain: Domain) -> String {
        let scheme = domain.sslEnabled ? "https" : "http"
        let port   = domain.sslEnabled ? WebServerPorts.httpsPort(for: domain.webServer)
                                       : WebServerPorts.httpPort(for: domain.webServer)
        return "\(scheme)://127.0.0.1:\(port)"
    }

    /// Kullanıcıya gösterilecek yerel adres — teknik hedef değil, sitenin kendi adresi.
    /// Arayüzde `127.0.0.1:8443` yerine `https://projem.test` görmek daha anlamlı.
    static func displayOrigin(for domain: Domain) -> String {
        let scheme = domain.sslEnabled ? "https" : "http"
        let port   = domain.sslEnabled ? WebServerPorts.httpsPort(for: domain.webServer)
                                       : WebServerPorts.httpPort(for: domain.webServer)
        return "\(scheme)://\(domain.name)\(WebServerPorts.portSuffix(port, https: domain.sslEnabled))"
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
        if domain.sslEnabled {
            // SNI de alan adı olmalı. IP'ye bağlanırken SNI gönderilemez (IP adresi
            // geçerli bir SNI değildir), sunucu varsayılan sertifikayı sunar ve `Host`
            // ile uyuşmayınca 421 döner — ölçtüm. Bu bayrak TLS el sıkışmasındaki adı
            // düzeltir; `--no-tls-verify` ise mkcert sertifikası için.
            parts += ["--origin-server-name", Shell.quote(domain.name), "--no-tls-verify"]
        }
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

    // MARK: - Önkoşullar

    /// Paylaşımın engellenme nedeni.
    ///
    /// Çalışmayan bir siteyi paylaşmak ziyaretçiye 502/503 gönderir: adres canlıdır ama
    /// içerik yoktur. Bu, paylaşan için sessiz bir hatadır — bağlantıyı gönderdikten
    /// sonra öğrenir. Bu yüzden tünel açılmadan ÖNCE engellenir.
    enum ShareBlock: Equatable {
        /// Alan adı devre dışı — vhost'u yok, hiçbir şey sunulmuyor
        case domainDisabled
        /// Öndeki web sunucusu (Apache/Nginx) kapalı
        case webServerDown(String)
        /// Node.js/Python/.NET arka plan uygulaması çalışmıyor → ters vekil 502 döner
        case appDown

        var logKey: String {
            switch self {
            case .domainDisabled: return "log.tunnel.blockDisabled"
            case .webServerDown:  return "log.tunnel.blockWebServer"
            case .appDown:        return "log.tunnel.blockApp"
            }
        }

        var logArgs: [String] {
            if case .webServerDown(let name) = self { return [name] }
            return []
        }
    }

    /// Saf karar — kabuk çağrısı yapmaz, doğrudan test edilir.
    ///
    /// Sıra ÖNEMLİ: en temeldeki eksik önce bildirilir. Web sunucusu kapalıyken
    /// "uygulama çalışmıyor" demek kullanıcıyı yanlış yere bakmaya gönderir.
    static func shareBlockReason(isEnabled: Bool,
                                 webServerRunning: Bool,
                                 webServerName: String,
                                 isAppPlatform: Bool,
                                 appRunning: Bool) -> ShareBlock? {
        if !isEnabled { return .domainDisabled }
        if !webServerRunning { return .webServerDown(webServerName) }
        if isAppPlatform && !appRunning { return .appDown }
        return nil
    }

    /// Node.js/Python/.NET — önünde ters vekil olan, ayrı süreç isteyen platformlar.
    static let appPlatforms: Set<Platform> = [.nodejs, .python, .dotnet]

    /// Paylaşımı REDDEDİLEN portlar — veritabanı ve önbellek servisleri.
    ///
    /// Quick Tunnel yalnızca HTTP konuşur, bu yüzden bir MySQL istemcisi verilen adrese
    /// zaten bağlanamaz. Asıl mesele bu değil: bu servisler geliştirme makinesinde
    /// çoğunlukla parolasız durur (Homebrew Redis'te `requirepass` yok, MariaDB kökü
    /// boş olabilir). Yanlışlıkla açılmış bir tünel, parolasız veritabanını internete
    /// koyar. Teknik olarak işe yaramayacak bir şeyi ayrıca yasaklamak fazladan görünür
    /// — ama port numarası elle girildiği için "yanlış yazdım" hâli gerçek.
    static let refusedPorts: [Int: String] = [
        3306: "MariaDB/MySQL", 5432: "PostgreSQL", 6379: "Redis",
        11211: "Memcached", 27017: "MongoDB",
    ]

    /// Elle girilen bir portun paylaşılabilirliği.
    ///
    /// Saf fonksiyon — kabuk çağırmaz, doğrudan test edilir.
    enum PortRefusal: Equatable {
        case outOfRange
        case reservedService(String)
        case notListening
    }

    static func portRefusal(port: Int, isListening: Bool) -> PortRefusal? {
        guard (1...65535).contains(port) else { return .outOfRange }
        if let service = refusedPorts[port] { return .reservedService(service) }
        // Dinlenmeyen portu paylaşmak, alan adı durumunda olduğu gibi, boş adres verir.
        guard isListening else { return .notListening }
        return nil
    }

    /// Gerçek durumu toplayıp kararı verir.
    static func shareBlockReason(for domain: Domain) async -> ShareBlock? {
        let process = domain.webServer == .apache ? "httpd" : "nginx"
        let serverUp = await Shell.isProcessAlive(process)
        let isApp = appPlatforms.contains(domain.platform)
        // Web sunucusu kapalıysa uygulama durumunu sormaya gerek yok — hem gereksiz
        // kabuk çağrısı hem de zaten bildirilmeyecek bir bilgi.
        let appUp = (isApp && serverUp) ? await NativeProcessManager.isRunning(domain: domain) : false
        return shareBlockReason(isEnabled: domain.isEnabled,
                                webServerRunning: serverUp,
                                webServerName: domain.webServer.displayName,
                                isAppPlatform: isApp,
                                appRunning: appUp)
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
        // Çalışmayan siteyi paylaşmak ziyaretçiye boş bir adres verir; engelle.
        if let block = await Self.shareBlockReason(for: domain) {
            log(key: block.logKey, args: [domain.name] + block.logArgs, type: .error)
            lastBlock = block
            return false
        }
        lastBlock = nil

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

    // MARK: - Rastgele port paylaşımı

    /// Bir tünel kaydının anahtarı olarak kullanılan ad — port paylaşımları için
    /// alan adı yok, bu yüzden ":5173" biçiminde sentetik bir ad üretilir.
    static func portKey(_ port: Int) -> String { ":\(port)" }

    /// BRAMPP'ta alan adı olarak kayıtlı OLMAYAN bir yerel HTTP portunu paylaşır.
    ///
    /// Kullanım hâli: `npm run dev` 5173'te ayakta ama proje henüz bir alan adına
    /// bağlanmamış. Alan adı akışından farkı yalnızca hedefin `127.0.0.1:<port>`
    /// olması; `--http-host-header` verilmez çünkü eşleşecek bir vhost yoktur.
    @discardableResult
    func startPort(_ port: Int) async -> Bool {
        guard Self.isCloudflaredInstalled else {
            log(key: "log.tunnel.notInstalled", type: .error)
            return false
        }
        let key = Self.portKey(port)
        if let existing = tunnels[key], existing.isLive {
            log(key: "log.tunnel.already", args: [key], type: .warning)
            return true
        }

        let listening = await Shell.isPortOpenFast(port)
        if let refusal = Self.portRefusal(port: port, isListening: listening) {
            switch refusal {
            case .outOfRange:
                log(key: "log.tunnel.portRange", args: ["\(port)"], type: .error)
            case .reservedService(let name):
                log(key: "log.tunnel.portReserved", args: ["\(port)", name], type: .error)
            case .notListening:
                log(key: "log.tunnel.portClosed", args: ["\(port)"], type: .error)
            }
            lastPortRefusal = refusal
            return false
        }
        lastPortRefusal = nil

        _ = FileHelper.createDirectory(PathConfig.tunnels)
        let logPath = PathConfig.tunnelLog(domain: key)
        _ = FileHelper.remove(logPath)

        let origin = "http://127.0.0.1:\(port)"
        let cmd = [
            Shell.quote(PathConfig.cloudflared), "tunnel",
            "--url", Shell.quote(origin),
            "--logfile", Shell.quote(logPath),
            "--loglevel", "info", "--metrics", "127.0.0.1:0",
        ].joined(separator: " ")

        log(key: "log.tunnel.starting", args: [key], type: .command)
        tunnels[key] = Tunnel(domainName: key, origin: origin, publicURL: nil,
                              pid: nil, startedAt: Date(), state: .starting)

        let r = await Shell.bashAsync("nohup \(cmd) >/dev/null 2>&1 & echo $!")
        guard r.isSuccess,
              let pid = Int(r.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            tunnels[key]?.state = .failed("cloudflared başlatılamadı")
            log(key: "log.tunnel.startFailed", args: [key], type: .error)
            return false
        }
        _ = FileHelper.write("\(pid)", to: PathConfig.tunnelPid(domain: key))
        tunnels[key]?.pid = pid

        guard let url = await waitForURL(domain: key) else {
            await stop(domainName: key)
            log(key: "log.tunnel.urlTimeout", args: [key], type: .error)
            return false
        }
        tunnels[key]?.publicURL = url
        tunnels[key]?.state = .active
        log(key: "log.tunnel.live", args: [key, url], type: .success)
        return true
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
        // Ölü tünellerin logları da kalmasın: hiçbir tünel açık değilken bu dosyalar
        // yalnızca eski oturumlardan artakalır ve zamanla birikir.
        for name in FileHelper.contentsOfDirectory(PathConfig.tunnels) where name.hasSuffix(".log") {
            _ = FileHelper.remove("\(PathConfig.tunnels)/\(name)")
        }
    }
}
