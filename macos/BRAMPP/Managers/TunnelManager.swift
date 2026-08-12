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
    /// Adres alındıktan sonra DNS'in yayılması için beklenecek süre.
    static let dnsTimeout: TimeInterval = 45

    var activeCount: Int { tunnels.values.filter(\.isLive).count }

    /// "Durdurulacak bir şey var mı?" — `activeCount` bu soruyu YANITLAMAZ.
    ///
    /// Adresi henüz gelmemiş bir paylaşım (`.starting`) 45 saniyeye kadar sürebiliyor ve
    /// o süre boyunca `isLive` false olduğu için "tümünü durdur" düğmesi görünmüyordu:
    /// kullanıcı, tam da beklemekten vazgeçtiği anda iptal edemiyordu. `.failed` kayıtlar
    /// ise sayılmaz — onlarda durdurulacak bir süreç zaten yok.
    var stoppableCount: Int {
        tunnels.values.filter { if case .failed = $0.state { return false }; return true }.count
    }

    func tunnel(for domainName: String) -> Tunnel? { tunnels[domainName] }

    // MARK: - Bu sürecin sahiplendiği PID'ler

    /// BU süreçte başlatılmış cloudflared PID'leri → tünelin dizin anahtarı.
    ///
    /// Neden var: `PathConfig.tunnels` yalnızca `$HOME`'a bağlıdır, yani aynı kullanıcının
    /// çalıştırdığı HER BRAMPP kopyası (kurulu uygulama, Xcode'un Debug derlemesi, XCTest
    /// ana uygulaması) aynı dizini paylaşır. Dizindeki PID'lere sahiplik sormadan sinyal
    /// göndermek — açılışta da ÇIKIŞTA da — canlı bir kopyanın tünelini öldürür.
    /// Bu kayıt, "bu süreç hangi tünelleri açtı" sorusunun TEK doğru yanıtıdır ve hem
    /// açılış toparlamasının atlama ölçütü hem de çıkış kapatmasının HEDEF listesidir.
    ///
    /// Anahtar da saklanır (yalnızca PID değil): çıkışta süreci öldürdükten sonra hangi
    /// `.pid`/`.log` dosyalarının bize ait olduğunu bilmenin başka yolu yok.
    ///
    /// `nonisolated`: kayıt `applicationShouldTerminate` içinden, ana aktörü
    /// bekleyemeyecek bir bağlamda da okunur. Erişim kilitle korunur.
    nonisolated(unsafe) private static var ownedPIDs: [Int: String] = [:]
    nonisolated private static let ownedLock = NSLock()

    nonisolated static func rememberOwned(_ pid: Int, key: String) {
        ownedLock.lock(); defer { ownedLock.unlock() }
        ownedPIDs[pid] = key
    }

    nonisolated static func forgetOwned(_ pid: Int) {
        ownedLock.lock(); defer { ownedLock.unlock() }
        ownedPIDs.removeValue(forKey: pid)
    }

    nonisolated static func isOwned(_ pid: Int) -> Bool {
        ownedLock.lock(); defer { ownedLock.unlock() }
        return ownedPIDs[pid] != nil
    }

    /// Kaydın o andaki kopyası — kilidi tutarak dolaşmamak için.
    nonisolated static var ownedSnapshot: [Int: String] {
        ownedLock.lock(); defer { ownedLock.unlock() }
        return ownedPIDs
    }

    /// Yalnızca testler için: süreç genelindeki kayıt testler arasında sızmasın.
    nonisolated static func resetOwnedForTesting() {
        ownedLock.lock(); defer { ownedLock.unlock() }
        ownedPIDs.removeAll()
    }

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

    /// Aynı ad için yeni bir başlatma isteği çakışıyor mu? — SAF karar.
    ///
    /// NEDEN: eski kod YALNIZCA `existing.isLive` durumunda kısa devre yapıyordu.
    /// `.starting` bir kayıt canlı SAYILMAZ, dolayısıyla art arda iki `start_share`
    /// çağrısı (MCP aracıyla bir saniye arayla mümkün) İKİ cloudflared süreci
    /// doğuruyordu. İkincisi tabloya yazıldığı an birincisi TAKİPSİZ kalıyor:
    /// arayüzde görünmeyen, `reconcile`in bilmediği, çıkış temizliğinin bulamadığı —
    /// ama internete açık — bir tünel. Bu fiyaskoyu bu düzeltmenin bütün değişmezleri
    /// tek başına bozardı, o yüzden burada kapatılıyor.
    enum StartConflict: Equatable {
        /// Zaten yayında — yapılacak bir şey yok
        case alreadyLive
        /// Başka bir başlatma akışı sürüyor — İKİNCİ süreç doğurulmaz
        case inProgress
        /// `.starting` kaydı adres + DNS beklemesinin TOPLAMINI aştı: o akış çoktan
        /// bitmiş, kayıt takılı kalmış. Yeniden denemeden önce eski süreç kapatılır.
        case stale
    }

    static func startConflict(existing: Tunnel?, now: Date) -> StartConflict? {
        guard let existing else { return nil }
        if existing.isLive { return .alreadyLive }
        // `.failed` kayıt yeniden denemeyi engellemez — zaten durdurulacak süreci yok.
        guard existing.state == .starting else { return nil }
        return now.timeIntervalSince(existing.startedAt) > urlTimeout + dnsTimeout
             ? .stale : .inProgress
    }

    @discardableResult
    func start(domain: Domain) async -> Bool {
        guard Self.isCloudflaredInstalled else {
            log(key: "log.tunnel.notInstalled", type: .error)
            return false
        }
        switch Self.startConflict(existing: tunnels[domain.name], now: Date()) {
        case .alreadyLive:
            log(key: "log.tunnel.already", args: [domain.name], type: .warning)
            return true
        case .inProgress:
            log(key: "log.tunnel.startInProgress", args: [domain.name], type: .warning)
            return false
        case .stale:
            // Takılı akışın süreci hâlâ yaşıyor olabilir; yenisini doğurmadan önce
            // kapat — yoksa geride sahipsiz, açık bir tünel kalır.
            await stop(domainName: domain.name)
        case .none:
            break
        }

        // Yer tutucu kayıt İLK `await`ten ÖNCE konur. `start` ana aktörde koşsa da her
        // askıya alma noktasında araya ikinci bir çağrı girebilir; kayıt önce yazılırsa
        // ikinci çağrı `.inProgress` görüp çıkar, sonra yazılırsa ikisi de önkoşul
        // denetimini geçip iki cloudflared başlatır.
        //
        // `startedAt` aynı zamanda bu kaydın KUŞAK JETONUDUR (bkz. `markDead`) —
        // aşağıda kayıt yeniden kurulmaz, alanları güncellenir.
        tunnels[domain.name] = Tunnel(domainName: domain.name,
                                      origin: Self.origin(for: domain),
                                      publicURL: nil, pid: nil,
                                      startedAt: Date(), state: .starting)

        // Çalışmayan siteyi paylaşmak ziyaretçiye boş bir adres verir; engelle.
        if let block = await Self.shareBlockReason(for: domain) {
            tunnels.removeValue(forKey: domain.name)
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
        // Sahiplik kaydı: açılış toparlaması bu PID'e DOKUNMAZ, çıkış kapatması ise
        // YALNIZCA bu kayıttakileri hedefler.
        Self.rememberOwned(pid, key: domain.name)

        guard let url = await waitForURL(domain: domain.name) else {
            // `.failed` DURUM ÖNCE yazılır: `stop` kaydı sözlükten siler, sonrasındaki
            // isteğe bağlı zincir hiçbir yere düşmezdi (ölü koduydu). Kaydı geri koymak
            // yerine durumu önden yazıp silinmesine izin veriyoruz — arayüzün gösterecek
            // bir şeyi yok, konsol satırı nedeni zaten söylüyor.
            tunnels[domain.name]?.state = .failed("adres alınamadı")
            await stop(domainName: domain.name)
            log(key: "log.tunnel.urlTimeout", args: [domain.name], type: .error)
            return false
        }

        // Adres logda belirdiği AN kullanılabilir değil: DNS kaydının yayılması
        // ölçümde ~6 saniye daha sürüyor. Kullanıcıya erken verirsek tarayıcı adı
        // henüz yokken sorgular ve macOS çözümleyicisi sonucu ÖNBELLEĞE ALIR —
        // kayıt sonradan gelse bile ERR_NAME_NOT_RESOLVED almaya devam eder.
        // Bu yüzden adres, çözülebilir olana kadar gösterilmez.
        await waitUntilResolvable(url: url)

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
        // Alan adı akışıyla AYNI çakışma kuralı — iki eşzamanlı çağrı iki süreç
        // doğurmamalı (bkz. `startConflict`).
        switch Self.startConflict(existing: tunnels[key], now: Date()) {
        case .alreadyLive:
            log(key: "log.tunnel.already", args: [key], type: .warning)
            return true
        case .inProgress:
            log(key: "log.tunnel.startInProgress", args: [key], type: .warning)
            return false
        case .stale:
            await stop(domainName: key)
        case .none:
            break
        }
        // Yer tutucu kayıt İLK `await`ten önce (bkz. `start`).
        tunnels[key] = Tunnel(domainName: key, origin: "http://127.0.0.1:\(port)",
                              publicURL: nil, pid: nil, startedAt: Date(), state: .starting)

        let listening = await Shell.isPortOpenFast(port)
        if let refusal = Self.portRefusal(port: port, isListening: listening) {
            tunnels.removeValue(forKey: key)
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

        let r = await Shell.bashAsync("nohup \(cmd) >/dev/null 2>&1 & echo $!")
        guard r.isSuccess,
              let pid = Int(r.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            tunnels[key]?.state = .failed("cloudflared başlatılamadı")
            log(key: "log.tunnel.startFailed", args: [key], type: .error)
            return false
        }
        _ = FileHelper.write("\(pid)", to: PathConfig.tunnelPid(domain: key))
        tunnels[key]?.pid = pid
        Self.rememberOwned(pid, key: key)

        guard let url = await waitForURL(domain: key) else {
            await stop(domainName: key)
            log(key: "log.tunnel.urlTimeout", args: [key], type: .error)
            return false
        }
        await waitUntilResolvable(url: url)
        tunnels[key]?.publicURL = url
        tunnels[key]?.state = .active
        log(key: "log.tunnel.live", args: [key, url], type: .success)
        return true
    }

    /// Adres TARAYICININ kullandığı çözümleyiciyle çözülene kadar bekler.
    ///
    /// `dig` ile denetlemek yetmiyordu: `dig` `/etc/resolv.conf`'taki sunucuya doğrudan
    /// sorar, tarayıcı ise sistem çözümleyicisini kullanır ve ikisi farklı sonuç
    /// verebilir. Ölçüm: taze bir tünel adını Google DNS 6 denemede 1 kez, Cloudflare'in
    /// kendi çözümleyicisi 6/6 yanıtladı — yani adres gerçekten vardır ama kullanıcının
    /// DNS'i onu henüz görmüyordur.
    ///
    /// Bu yüzden `getaddrinfo` kullanılır: tarayıcı neyi görüyorsa o. Süre dolarsa adres
    /// yine verilir ama nedeni ve çözümü konsola yazılır — kullanıcı çıplak bir
    /// ERR_NAME_NOT_RESOLVED yerine ne olduğunu bilir.
    private func waitUntilResolvable(url: String,
                                     timeout: TimeInterval = TunnelManager.dnsTimeout) async {
        let host = url.replacingOccurrences(of: "https://", with: "")
                      .replacingOccurrences(of: "http://", with: "")
        guard !host.isEmpty else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await Self.systemCanResolve(host) { return }
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
        log(key: "log.tunnel.dnsSlow", args: [host], type: .warning)
    }

    /// `getaddrinfo` — tarayıcı ve curl ile AYNI yol. Ana iş parçacığını bloklamamak
    /// için ayrı bir görevde koşar.
    nonisolated static func systemCanResolve(_ host: String) async -> Bool {
        await Task.detached(priority: .utility) {
            var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                                 ai_protocol: 0, ai_addrlen: 0,
                                 ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var result: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, nil, &hints, &result)
            if let result { freeaddrinfo(result) }
            return status == 0
        }.value
    }

    // MARK: - Süreç denetimi dikişi

    /// `stop` akışının işletim sistemine dokunan ÜÇ işlemi — testlerde sahtelenebilsin
    /// diye enjekte edilir. Yükseltme mantığının doğruluğu gerçek bir cloudflared
    /// süreci olmadan sınanabilmeli; aksi halde bu kod hiç test edilemezdi.
    struct ProcessControl {
        var isAlive: (Int) -> Bool
        var isCloudflared: (Int) async -> Bool
        var signal: (Int, Int32) -> Void
        /// Bekleme adımı. Testlerde anında dönen bir sahte ile gerçek süre harcanmaz.
        var tick: (TimeInterval) async -> Void

        static let live = ProcessControl(
            isAlive: { NativeProcessManager.isAlive($0) },
            isCloudflared: { pid in
                // PID geri dönüştürülmüş olabilir; doğrulamadan sinyal göndermek
                // BAŞKASININ sürecini öldürürdü.
                let r = await Shell.bashAsync("ps -o comm= -p \(pid) 2>/dev/null")
                return r.output.contains("cloudflared")
            },
            signal: { pid, sig in kill(pid_t(pid), sig) },
            tick: { seconds in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            }
        )
    }

    /// Bir cloudflared sürecini durdurma girişiminin SONUCU.
    enum StopOutcome: Equatable {
        /// Süreç zaten yoktu — ya da o PID artık bizim cloudflared'imiz değil
        case notRunning
        /// SIGTERM yetti
        case terminated
        /// SIGTERM yutuldu, SIGKILL gerekti
        case killed
        /// İkisi de yetmedi — süreç HÂLÂ ayakta ve adres HÂLÂ yayında
        case survived

        /// Süreç gerçekten gitti mi? PID dosyasının silinmesi, sahiplik kaydının
        /// düşürülmesi ve "durduruldu" satırı YALNIZCA bu doğruyken yapılır.
        var isGone: Bool { self != .survived }
    }

    /// SIGTERM → SIGKILL yükseltmesi.
    ///
    /// NEDEN: cloudflared'in varsayılan `--grace-period`'ü **30 saniyedir**; SIGTERM'i
    /// aldıktan sonra açık bağlantıları o kadar süre taşımaya devam edebilir. Eski kod
    /// 0,4 saniye bekliyor, sonucu SORMADAN kaydı tablodan siliyor ve "durduruldu"
    /// satırını yazıyordu. Sonuç: "tüm paylaşımları durdur" düğmesi her paylaşımın
    /// kapandığını bildirirken herkese açık adresler yayında kalıyor, üstelik kayıt
    /// silindiği için `reconcile` de bir daha bulamıyordu.
    ///
    /// Sınırlar KISA (2 sn + 1 sn): kullanıcı "durdur" dediğinde 30 saniye beklemek
    /// kabul edilebilir değil. SIGKILL güvenlidir — cloudflared'in yerelde durumu yok,
    /// yalnızca kendi kenar bağlantısı kopar.
    nonisolated static func terminate(pid: Int,
                                      control: ProcessControl = .live,
                                      graceSeconds: TimeInterval = 2.0,
                                      killSeconds: TimeInterval = 1.0,
                                      step: TimeInterval = 0.05) async -> StopOutcome {
        guard control.isAlive(pid) else { return .notRunning }
        guard await control.isCloudflared(pid) else { return .notRunning }

        control.signal(pid, SIGTERM)
        if await awaitGone(pid, within: graceSeconds, step: step, control: control) {
            return .terminated
        }
        control.signal(pid, SIGKILL)
        if await awaitGone(pid, within: killSeconds, step: step, control: control) {
            return .killed
        }
        return .survived
    }

    /// Sürecin ölmesini bloklamadan bekler — `stop` ana aktörde koşuyor.
    private nonisolated static func awaitGone(_ pid: Int, within: TimeInterval,
                                              step: TimeInterval,
                                              control: ProcessControl) async -> Bool {
        var waited: TimeInterval = 0
        while waited < within {
            if !control.isAlive(pid) { return true }
            await control.tick(step)
            waited += step
        }
        return !control.isAlive(pid)
    }

    /// - Returns: paylaşım GERÇEKTEN kapandıysa `true`. `false`, sürecin sinyalleri
    ///   atlattığı ve adresin hâlâ yayında olduğu anlamına gelir — çağıran, kaydın
    ///   yerine yenisini koymamalıdır (yoksa yayında olan sürecin tutamağı kaybolur).
    @discardableResult
    func stop(domainName: String) async -> Bool {
        let pidFile = PathConfig.tunnelPid(domain: domainName)
        var pid = tunnels[domainName]?.pid
        if pid == nil, let raw = FileHelper.readString(pidFile) {
            pid = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        if let pid {
            let outcome = await Self.terminate(pid: pid)
            guard outcome.isGone else {
                // Süreç SIGKILL'e rağmen ayakta. Kayıt SİLİNMEZ ve "durduruldu"
                // YAZILMAZ: kaydı silmek, yayında olan adresi arayüzden de
                // `reconcile`den de görünmez yapar — tutamağı kalmayan, internete
                // açık bir tünel. Başarısızlığı bildirmek, başarı uydurmaktan iyidir.
                // PID iki kez geçilir: kalıp hem tanıyı hem elle çözümü ("kill -9 <pid>")
                // içeriyor ve TR/EN metinlerinde yer tutucu sayısı aynı olmalı.
                log(key: "log.tunnel.stopStuck",
                    args: [domainName, "\(pid)", "\(pid)"], type: .error)
                return false
            }
            Self.forgetOwned(pid)
        }
        // PID dosyası ancak süreç GERÇEKTEN gittiğinde silinir. Yükseltme olmadan bu
        // koşul neredeyse hiç tutmuyordu: her normal durdurma arkasında bir `.pid`
        // dosyası bırakıyor, o dosya da `pruneStrandedLogs`a log'u "hâlâ bir tünele
        // ait" diye gösterip sonsuza dek biriktiriyordu.
        _ = FileHelper.remove(pidFile)
        tunnels.removeValue(forKey: domainName)
        log(key: "log.tunnel.stopped", args: [domainName], type: .info)
        return true
    }

    /// "Tümünü durdur" hangi kayıtlara dokunur? — SAF karar.
    ///
    /// `.failed` kayıtlarda durdurulacak bir süreç YOKTUR (`markDead` süreci yok diye
    /// işaretledi ya da başlatma hiç tutmadı). Onlar için `stop` çağırmak konsola,
    /// hiç olmamış bir iş için "%@ paylaşımı durduruldu" satırı yazdırıyordu; kullanıcı
    /// da gerçekten neyin kapandığını göremiyordu. Kayıtlar yine tablodan düşer —
    /// sessizce.
    static func stopTargets(in tunnels: [String: Tunnel]) -> (stop: [String], discard: [String]) {
        var stop: [String] = []
        var discard: [String] = []
        for (name, t) in tunnels {
            if case .failed = t.state { discard.append(name) } else { stop.append(name) }
        }
        return (stop.sorted(), discard.sorted())
    }

    /// Tüm tünelleri durdurur.
    func stopAll() async {
        let targets = Self.stopTargets(in: tunnels)
        for name in targets.discard { tunnels.removeValue(forKey: name) }
        for name in targets.stop { await stop(domainName: name) }
    }

    // MARK: - Gerçeklikle eşitleme

    /// Bellekteki tünel tablosunu işletim sisteminin gerçeğiyle karşılaştırır.
    ///
    /// NEDEN GEREKLİ: `tunnels` yalnızca `start`/`stop` ile değişir, yani `.active`
    /// durumundan çıkış yolu YOKTU. cloudflared başka bir yolla ölürse (çökme, elle
    /// `pkill`, ikinci bir BRAMPP kopyasının temizliği, Cloudflare'in Quick Tunnel'ı
    /// kapatması) arayüz ile MCP `list_shares` yeşil bir adres göstermeye devam ediyordu.
    /// Kullanıcı bağlantıyı paylaşıyor, karşı taraf Error 1033 görüyordu.
    ///
    /// MALİYET: yaşayan her kayıt için `kill(pid, 0)` — fork yok, çekirdek çağrısı,
    /// mikrosaniyeler. Ardından hayatta kalanlar için TEK bir `ps` (virgüllü PID listesi),
    /// yani tünel sayısından bağımsız olarak turda bir fork. Otuz saniyelik tazeleme
    /// döngüsüne bu yüzden takılabiliyor.
    ///
    /// LOG DOSYASI CANLILIK ÖLÇÜTÜ DEĞİLDİR — iki yönde de yanlış: cloudflared dosya
    /// tanıtıcısını silinme sonrası da açık tutar, ölen tünelin logunu ise kimse silmez.
    /// Hangi kayıtlar ölü GÖRÜNÜYOR? — SAF karar, kabuk çağırmaz, doğrudan test edilir.
    ///
    /// `isAlive` enjekte edilir (`kill(pid,0)`): karar mantığı gerçek süreçler olmadan
    /// sınanabilmeli.
    static func deadCandidates(in tunnels: [String: Tunnel], now: Date,
                               isAlive: (Int) -> Bool) -> Set<String> {
        var dead: Set<String> = []
        for (name, t) in tunnels {
            if case .failed = t.state { continue }   // zaten ölü işaretli
            guard let pid = t.pid else {
                // Henüz PID yazılmamış `.starting` kaydı: `start` akışı sürüyor olabilir.
                // Adres + DNS beklemesinin TOPLAMINI aşmışsa o akış çoktan bitmiştir ve
                // kayıt takılı kalmıştır — sonsuza kadar "başlatılıyor" göstermesin.
                if now.timeIntervalSince(t.startedAt) > urlTimeout + dnsTimeout {
                    dead.insert(name)
                }
                continue
            }
            if !isAlive(pid) { dead.insert(name) }   // `kill(pid,0)` başarısızlığı KESİN
        }
        return dead
    }

    /// `ps -o pid=,comm=` çıktısından cloudflared olduğu DOĞRULANAN PID'ler — SAF.
    nonisolated static func parseCloudflaredPIDs(from psOutput: String) -> Set<Int> {
        var confirmed = Set<Int>()
        for line in psOutput.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let head = parts.first, let pid = Int(head) else { continue }
            if parts.dropFirst().joined(separator: " ").contains("cloudflared") {
                confirmed.insert(pid)
            }
        }
        return confirmed
    }

    func reconcile() async {
        guard !tunnels.isEmpty else { return }

        // GÖZLEM ANININ kopyası. Aşağıdaki `await` sırasında tablo değişebilir;
        // `markDead` kararı bu kopyaya göre verildiği için uygularken de bu kopyayla
        // kimlik doğrulanır (bkz. `deadRecordStillApplies`).
        let observed = tunnels
        var dead = Self.deadCandidates(in: observed, now: Date(),
                                       isAlive: { NativeProcessManager.isAlive($0) })

        var alive: [Int: [String]] = [:]   // PID → o PID'i gösteren kayıt adları
        for (name, t) in observed where !dead.contains(name) {
            if case .failed = t.state { continue }
            if let pid = t.pid { alive[pid, default: []].append(name) }
        }

        // `kill(pid,0)` "yaşıyor" demesi yetmez: PID geri dönüştürülmüş olabilir ve o
        // numarada artık bambaşka bir süreç oturuyor olabilir. Kimlik doğrulaması
        // `stop`/açılış toparlaması ile aynı ölçüt — comm sütununda "cloudflared".
        if !alive.isEmpty {
            let list = alive.keys.sorted().map(String.init).joined(separator: ",")
            let r = await Shell.runAsync("/bin/ps", arguments: ["-o", "pid=,comm=", "-p", list])
            let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            // Boş çıktı, YAŞADIĞI bilinen PID'ler sorulmuşken imkânsızdır; olmuşsa `ps`
            // çağrısının kendisi başarısız olmuştur. Böyle bir durumda hepsini ölü ilan
            // etmek canlı tünelleri sahte biçimde kapatırdı — bu turu atla.
            if !out.isEmpty {
                let confirmed = Self.parseCloudflaredPIDs(from: out)
                for (pid, names) in alive where !confirmed.contains(pid) {
                    dead.formUnion(names)
                }
            }
        }

        for name in dead { markDead(name, observed: observed[name]) }
    }

    /// Ölü GÖRÜLEN kayıt hâlâ tablodaki kayıt mı? — SAF kimlik denetimi.
    ///
    /// NEDEN: `reconcile` ölü listesini `ps` beklemesinden ÖNCE hesaplar, uygular ise
    /// SONRA. O pencerede aynı alan adı yeniden paylaşıma açılırsa `markDead` YENİ
    /// kaydı bozuyordu: yeni PID'i unutuyor, YENİ pid dosyasını siliyor, pid'i nil
    /// yapıyordu. Ardından `start` tamamlanıp kaydı `.active` yapıyor — geriye bellekte
    /// pid'i, diskte dosyası olmayan ama internete AÇIK bir tünel kalıyordu: `stop`
    /// öldürecek bir şey bulamaz, uygulama kapandıktan sonra da yaşamayı sürdürür.
    ///
    /// Kuşak jetonu `startedAt`: her `start` çağrısı kaydı yeni bir `Date()` ile kurar,
    /// yani aynı ad için art arda iki paylaşım farklı damga taşır. PID de karşılaştırılır
    /// — kayıt yerinde güncellendiyse (pid yazıldıysa) gözlem eskimiş demektir.
    static func deadRecordStillApplies(observed: Tunnel?, current: Tunnel?) -> Bool {
        guard let observed, let current else { return false }
        return current.startedAt == observed.startedAt && current.pid == observed.pid
    }

    /// Kaydı "yayın bitti" durumuna alır: `isLive` ANINDA false olur, arayüz ile
    /// `list_shares` artık ölü bir adresi canlı göstermez.
    func markDead(_ name: String, observed: Tunnel?) {
        guard Self.deadRecordStillApplies(observed: observed, current: tunnels[name]),
              var t = tunnels[name] else { return }
        if let pid = t.pid { Self.forgetOwned(pid) }
        // PID dosyası artık kimseyi göstermiyor; bırakılırsa sonraki açılış temizliği
        // geri dönüştürülmüş bir numaraya sinyal göndermeye çalışırdı.
        _ = FileHelper.remove(PathConfig.tunnelPid(domain: name))
        // Log dosyası KASITLI olarak bırakılır: tünelin neden öldüğü yalnızca orada yazar.
        t.pid = nil
        t.publicURL = nil
        t.state = .failed("süreç yok")
        tunnels[name] = t
        log(key: "log.tunnel.died", args: [name], type: .warning)
    }


    // MARK: - Test kancası

    /// YALNIZCA testler için: tabloyu doğrudan kurar. `tunnels` üretimde `private(set)`
    /// olmalı (dışarıdan yazılan bir tünel tablosu, gerçeklikle bağı olmayan bir
    /// tablodur), ama `reconcile`/`markDead` kararlarını gerçek süreçler olmadan
    /// sınamanın başka yolu yok.
    func setTunnelsForTesting(_ table: [String: Tunnel]) { tunnels = table }

    // MARK: - Süpürme (açılış toparlaması / çıkış kapatması)

    /// AÇILIŞ toparlaması — yalnızca ARTAKALMIŞ tünelleri toplar.
    ///
    /// Amacı hep buydu: uygulama çökerse cloudflared yaşamaya devam eder ve site
    /// arkada açık kalır. Ama "açılıyorum" ile "bu tünel sahipsiz" aynı şey değil.
    /// `PathConfig.tunnels` `$HOME`'a bağlı olduğundan aynı dizini birden çok BRAMPP
    /// kopyası paylaşır (kurulu uygulama + Xcode Debug derlemesi + XCTest ana
    /// uygulaması). Ayrım bu yüzden "az önce mi başladım" değil, "bu PID benim mi"
    /// sorusuyla yapılır: `ownedPIDs` içindeki süreçlere DOKUNULMAZ.
    ///
    /// Kapı `ProcessRole.mayMutateSharedEnvironment` — açılıştaki BÜTÜN ortak-durum
    /// işleriyle (MCP dinleyicisi, otomatik servis başlatma, durum kalıcılaştırması)
    /// AYNI kapı. Tünellere özel ayrı bir ölçüt yok; tek kavram var.
    ///
    /// - Returns: toparlama gerçekten yapıldıysa `true`.
    @discardableResult
    nonisolated static func reapOrphansAtLaunch() -> Bool {
        guard ProcessRole.mayMutateSharedEnvironment else { return false }
        reapOrphanDirectoryEntries()
        pruneStrandedLogs()
        return true
    }

    /// Açılış toparlamasının SAF kararı: dizindeki her `.pid` kaydına ne yapılmalı?
    ///
    /// - Parameters:
    ///   - entries: dizin anahtarı → dosyadaki PID (okunamayan kayıt `nil`)
    ///   - isAlive: o PID'de yaşayan bir süreç var mı
    ///   - owned: BU sürecin sahiplendiği PID'ler — bunlara ASLA dokunulmaz
    /// - Returns: `kill` = kimliği doğrulandıktan sonra sinyal gönderilecek kayıtlar,
    ///   `discard` = süreci olmayan, yalnızca dosyaları silinecek kayıtlar.
    nonisolated static func reapDecision(entries: [String: Int?],
                             isAlive: (Int) -> Bool,
                             owned: Set<Int>) -> (kill: [String: Int], discard: [String]) {
        var kill: [String: Int] = [:]
        var discard: [String] = []
        for (key, maybePID) in entries {
            guard let pid = maybePID, isAlive(pid) else {
                // Okunamayan/ölü kayıt: temizlediğimiz tünel budur, logu da bizimdir.
                discard.append(key)
                continue
            }
            // Sahiplenilmiş PID canlı bir yayındır — ne öldürülür ne dosyası silinir.
            if owned.contains(pid) { continue }
            kill[key] = pid
        }
        return (kill, discard.sorted())
    }

    /// `reapDecision`ı gerçek dizine uygular.
    ///
    /// SÜRE SINIRI GLOBAL: eskiden PID BAŞINA bir `ps` fork'u ve PID başına 0,4 saniyelik
    /// `usleep` döngüsü vardı; açılışta ana iş parçacığı tünel sayısıyla çarpılan bir
    /// süre boyunca donuyordu. Artık tek `ps` çağrısı ve tek ortak bekleme penceresi var.
    private nonisolated static func reapOrphanDirectoryEntries(budget: TimeInterval = 0.5) {
        var entries: [String: Int?] = [:]
        for file in FileHelper.contentsOfDirectory(PathConfig.tunnels) where file.hasSuffix(".pid") {
            let key = String(file.dropLast(".pid".count))
            let raw = FileHelper.readString(PathConfig.tunnelPid(domain: key))
            entries[key] = Int((raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !entries.isEmpty else { return }

        let decision = reapDecision(entries: entries,
                                    isAlive: { NativeProcessManager.isAlive($0) },
                                    owned: Set(ownedSnapshot.keys))
        for key in decision.discard { discardFiles(for: key) }
        guard !decision.kill.isEmpty else { return }

        // Kimlik doğrulaması: PID geri dönüştürülmüş olabilir, dosya artık bambaşka
        // birinin sürecini gösteriyor olabilir. Doğrulanmayana SİNYAL GÖNDERİLMEZ.
        let confirmed = confirmedCloudflared(pids: Array(decision.kill.values))
        var targets: [Int: String] = [:]
        for (key, pid) in decision.kill {
            if confirmed.contains(pid) { targets[pid] = key } else { discardFiles(for: key) }
        }
        guard !targets.isEmpty else { return }

        for pid in targets.keys { kill(pid_t(pid), SIGTERM) }
        let survivors = waitAllGone(Set(targets.keys), budget: budget)
        // Artakalan tünel zaten sahipsiz: SIGTERM'i yutmasına izin vermek, siteyi
        // internette açık bırakmak demektir.
        for pid in survivors { kill(pid_t(pid), SIGKILL) }
        for (pid, key) in targets { forgetOwned(pid); discardFiles(for: key) }
    }

    /// Çıkış yolunda `await` edilemeyen bağlamlar için eşzamanlı kapatma.
    ///
    /// YALNIZCA BU SÜRECİN AÇTIĞI tüneller kapatılır. Eskiden dizindeki HER `.pid`
    /// dosyasına sinyal gidiyordu; niyet ("kendi tünelimi arkamda bırakmayayım") doğru
    /// olsa da sonuç, aynı `$HOME`'u paylaşan BAŞKA bir canlı kopyanın yayınını
    /// kesmekti — açılışta düzeltilen hatanın çıkış yoluna taşınmış hâli. Xcode'un
    /// Debug derlemesinde ⌘Q'ya basmak, kurulu uygulamanın canlı tünelini öldürüyordu.
    /// `ownedPIDs` kaydı tam bu soruyu yanıtlamak için var: sahiplik listesi hem
    /// hedeftir hem sınırdır.
    ///
    /// - Parameters:
    ///   - waitForExit: `false` ise SIGTERM ve bekleme ATLANIR, doğrudan SIGKILL
    ///     gönderilir. OTURUM KAPATMA / YENİDEN BAŞLATMA yolunda çıkışı geciktirmek
    ///     yasaktır: macOS "BRAMPP oturumu kapatmayı engelledi" deyip tüm işlemi iptal
    ///     eder. SIGKILL yutulamaz, bu yüzden beklemeden de kesin sonuç verir.
    ///   - budget: TOPLAM bekleme sınırı — tünel BAŞINA değil. Eski kod her PID için
    ///     ayrı 0,4 saniye harcıyor ve ana iş parçacığını `applicationShouldTerminate`
    ///     içinde tutuyordu.
    nonisolated static func killAllSynchronously(waitForExit: Bool = true,
                                                 budget: TimeInterval = 1.0) {
        let owned = ownedSnapshot
        guard !owned.isEmpty else { return }

        // Tek `ps` — PID başına fork atmak çıkış yolunu tünel sayısıyla çarpardı.
        let confirmed = confirmedCloudflared(pids: Array(owned.keys))

        for pid in confirmed { kill(pid_t(pid), waitForExit ? SIGTERM : SIGKILL) }
        if waitForExit {
            for pid in waitAllGone(confirmed, budget: budget) { kill(pid_t(pid), SIGKILL) }
        }

        // Sahiplenilmiş her kayıt bu süreçle birlikte gider: süreci öldürüldü (ya da
        // zaten ölüydü), dosyaları da bize aitti.
        for (pid, key) in owned {
            forgetOwned(pid)
            discardFiles(for: key)
        }
    }

    /// Verilen PID'lerin `comm` sütununda "cloudflared" olduğu DOĞRULANANLAR.
    /// Tek `ps` çağrısı — çağıran, listeyi kaç PID içerirse içersin tek fork öder.
    private nonisolated static func confirmedCloudflared(pids: [Int]) -> Set<Int> {
        guard !pids.isEmpty else { return [] }
        let list = pids.sorted().map(String.init).joined(separator: ",")
        let r = Shell.run("/bin/ps", arguments: ["-o", "pid=,comm=", "-p", list])
        return parseCloudflaredPIDs(from: r.output)
    }

    /// PID'lerin hepsinin ölmesini TEK bir süre bütçesiyle bekler; kalanları döner.
    ///
    /// Bloklayan sürüm YALNIZCA çıkış/açılış yollarındaki eşzamanlı süpürme içindir;
    /// oralarda `await` edilemiyor. Bütçe global olduğu için toplam duraklama tünel
    /// sayısından bağımsızdır.
    private nonisolated static func waitAllGone(_ pids: Set<Int>,
                                                budget: TimeInterval) -> Set<Int> {
        guard !pids.isEmpty, budget > 0 else { return pids }
        var remaining = pids
        let deadline = Date().addingTimeInterval(budget)
        while Date() < deadline {
            remaining = remaining.filter { NativeProcessManager.isAlive($0) }
            if remaining.isEmpty { return [] }
            usleep(25_000)
        }
        return remaining.filter { NativeProcessManager.isAlive($0) }
    }

    /// Bir tünelin PID ve log dosyalarını birlikte siler. YALNIZCA gerçekten
    /// temizlenmiş (ölü ya da öldürüldüğü doğrulanmış) tüneller için çağrılır —
    /// eskiden dizindeki TÜM `.log` dosyaları koşulsuz siliniyordu ve bu, ölen bir
    /// tünelin nedenini gösteren tek yerel kanıtı yok ediyordu.
    private nonisolated static func discardFiles(for key: String) {
        _ = FileHelper.remove(PathConfig.tunnelPid(domain: key))
        _ = FileHelper.remove(PathConfig.tunnelLog(domain: key))
    }

    /// PID dosyası olmayan, `retentionDays` günden eski log dosyalarını SEÇER — SAF.
    ///
    /// `stop` log dosyasını silmez (adres ve hata kaydı sorun ararken lazım olur), bu
    /// yüzden sahipsiz loglar birikir. Koşulsuz süpürme yerine yaş sınırı kullanılır —
    /// konsol dosyalarındaki ölçütün aynısı. Bugünkü kanıt durur, geçen haftaki gider.
    ///
    /// Dizin okuması ve mtime sorgusu ENJEKTE edilir: kararın kendisi gerçek dosya
    /// sistemine dokunmadan sınanabilmeli.
    nonisolated static func strandedLogTargets(names: [String], now: Date, retentionDays: Int,
                                   modified: (String) -> Date?) -> [String] {
        let pidKeys = Set(names.filter { $0.hasSuffix(".pid") }.map { String($0.dropLast(4)) })
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)

        var targets: [String] = []
        for file in names where file.hasSuffix(".log") {
            let key = String(file.dropLast(".log".count))
            guard !pidKeys.contains(key) else { continue }   // hâlâ bir tünele ait
            guard let date = modified(key) else { continue }
            if date < cutoff { targets.append(key) }
        }
        return targets.sorted()
    }

    /// `strandedLogTargets` kararını gerçek dizine uygular.
    private nonisolated static func pruneStrandedLogs(now: Date = Date(),
                                                      retentionDays: Int = 7) {
        let names = FileHelper.contentsOfDirectory(PathConfig.tunnels)
        let targets = strandedLogTargets(names: names, now: now, retentionDays: retentionDays) { key in
            let path = PathConfig.tunnelLog(domain: key)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
            return attrs[.modificationDate] as? Date
        }
        for key in targets { _ = FileHelper.remove(PathConfig.tunnelLog(domain: key)) }
    }
}
