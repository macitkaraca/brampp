import SwiftUI
import Combine
import AppKit

/// Uyarı kutusunu taşıyan model — `Identifiable` sayesinde `.alert(item:)` ile kullanılır.
struct AppAlert: Identifiable {
    let id   = UUID()
    let title:   String
    let message: String
}

/// Domain yönetimi — BaseManager'dan türetilir.
@MainActor
class DomainManager: BaseManager {

    @Published var domains:     [Domain]   = []
    @Published var activeAlert: AppAlert?  = nil
    /// ⌘N başka sekmedeyken basıldığında ContentView bu bayrağı diker; DomainsTabView
    /// görünür olunca tüketip "Yeni Alan Adı" sheet'ini açar (bildirim o an ekranda
    /// olmayan view'a ulaşamazdı).
    @Published var pendingOpenAddSheet: Bool = false

    private var usedPorts: Set<Int> = []
    private let mkcertManager = MkcertManager()

    /// AppState kurar (iki yönlü sahiplik olmasın diye `weak`).
    ///
    /// Alan adının vhost'u kaybolduğunda AÇIK KALMIŞ bir tünel tehlikeye dönüşür: tünel
    /// `127.0.0.1`'e bağlanıp `Host` başlığını taşıdığı için, vhost gidince istek artık
    /// hiçbir server bloğuyla eşleşmez ve VARSAYILAN vhost'a düşer. Sonuç, rastgele bir
    /// `*.trycloudflare.com` adresinin kullanıcının localhost kökünü — /phpmyadmin ve
    /// /adminer dahil — internete açması olur; istek loopback'ten geldiği için Apache'nin
    /// `Require local` kısıtı da devreye girmez. Bu yüzden vhost'a dokunan her yol önce
    /// paylaşımı kapatır.
    weak var tunnelManager: TunnelManager?
    /// Her updateDomain çağrısında domain başına artar — arka plandaki doğrulama Task'ı,
    /// kendi neslinden daha yeni bir çağrı başladıysa (kullanıcı tekrar düzenlediyse)
    /// bayat anlık görüntüsünü uygulamadan görevi bırakır.
    private var updateGenerations: [UUID: Int] = [:]

    // MARK: - Dış Değişiklik İzleyici (MCP/CLI köprüsü)

    /// Application Support dizinini izleyen kaynak — domains.json BRAMPP dışından
    /// değiştirildiğinde arayüzün kendiliğinden tazelenmesini sağlar.
    private var dirWatcher: DispatchSourceFileSystemObject?
    /// domains.json'un KENDİSİNİ izleyen kaynak: yerinde yazımlar (truncate+write, touch)
    /// dizin olayı ÜRETMEZ — dizin izleyici yalnızca atomik değişimi (rename) görür.
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var watcherDebounce: Task<Void, Never>?
    /// Diskteki domains.json'un bizim bildiğimiz son hali (kendi yazımımız veya son
    /// yüklediğimiz). İzleyici bununla karşılaştırır: farklı mtime = dış değişiklik.
    /// Not: izleyici uygulama ömrü boyunca yaşar — deinit'te iptal gerekmez (BaseManager'ın
    /// @MainActor deinit'i alt sınıfta nonisolated deinit'e de izin vermez).
    private var knownDomainsMtime: Date?

    /// Bir web sunucusunu (httpd/nginx) çalışır duruma getiren kanca — AppState tarafından
    /// ServiceManager.ensureWebServerRunning'e bağlanır. Domain eklenirken/başlatılırken
    /// bağlı sunucu durmuşsa otomatik başlatılır (yalnızca reload yerine). ServiceID → başarı.
    var ensureServiceRunning: ((String) async -> Bool)?

    /// Alan adının bağımlılık servislerini (varsa) uygulama başlamadan ÖNCE ayağa kaldırır.
    /// Örn. Node.js uygulaması MariaDB + Redis'e bağlıysa, ikisi çalışmadan uygulamayı
    /// başlatmak anlamsızdır — bağlantı hatalarıyla crash-loop'a girer.
    /// Bir alan adının bağımlılık servislerini SIRALI ve TEKİL olarak üretir.
    /// Saf fonksiyon — yan etkisi yok, doğrudan test edilebilsin diye ayrıldı.
    /// Sıra önemlidir: web sunucusu ilk, kullanıcının seçtiği DB/önbellek servisleri sonra.
    static func dependencyOrder(for domain: Domain, apacheCompanionAvailable: Bool) -> [String] {
        var deps: [String] = [domain.webServer.brewServiceID]
        // Nginx domaini bare URL (80/443) için Apache companion vhost'una da bağlıdır.
        if domain.webServer == .nginx, apacheCompanionAvailable {
            deps.append(WebServer.apache.brewServiceID)
        }
        deps.append(contentsOf: domain.serviceDependencies ?? [])
        // Kullanıcı web sunucusunu bağımlılık olarak da seçmiş olabilir → tekilleştir,
        // aksi halde aynı servis iki kez başlatılmaya çalışılır ve log tekrarlanır.
        var seen = Set<String>()
        return deps.filter { seen.insert($0).inserted }
    }

    func ensureDependencies(for domain: Domain) async {
        // Bağlı web sunucusu da bir bağımlılıktır ve İLK sırada gelir: ASP.NET Core,
        // Node.js ve Python uygulamaları Kestrel/Express/WSGI portunda dinler, dışarıya
        // yalnızca nginx/apache ters vekili üzerinden açılır. Sunucu durmuşsa uygulama
        // "çalışıyor" görünür ama site erişilemez — bu sessiz durum daha önce ancak
        // uygulama BAŞARIYLA ayağa kalktıktan sonra (reloadWebServer) fark ediliyordu.
        let deps = Self.dependencyOrder(
            for: domain,
            apacheCompanionAvailable: FileHelper.exists(PathConfig.httpdConf)
        )
        for dep in deps {
            // ensureServiceRunning sırayı garanti eder: kurulu mu → durum → başlat.
            // Kurulu değilse brew hiç çağrılmaz, net bir uyarı yazılır.
            let ok = await ensureServiceRunning?(dep) ?? false
            if ok {
                log(key: "log.dom.depReady", args: [dep], type: .info)
            } else {
                log(key: "log.dom.depStartFailed", args: [dep], type: .warning)
            }
        }
    }

    // MARK: - Persistence

    func loadDomains() {
        guard let data = FileHelper.readData(PathConfig.domainsJson) else { domains = []; return }
        do {
            let list = try JSONDecoder().decode(DomainList.self, from: data)
            // Ad doğrulaması yalnızca ekleme/yeniden adlandırmada yapılıyordu; dosya elle
            // düzenlenmiş veya eski bir sürümden migrate edilmişse kabuk metakarakteri
            // içeren bir ad buradan sızabilir. Bu adlar root ile çalışan /etc/hosts
            // komutlarına tırnak içinde gömüldüğünden yüklemede de elenmeli.
            // customDocumentRoot da AYNI denetimden geçer: bu değer hem web sunucusu
            // direktiflerinin içine hem de kabuk komutlarına gidiyor. Ekleme/güncelleme
            // sınırında doğrulanıyor ama diskteki dosya elle düzenlenmiş ya da eski bir
            // sürümden gelmiş olabilir — tek denetimsiz yol burasıydı.
            let validDomains = list.domains.filter { d in
                guard Self.isValidDomainName(d.name) else { return false }
                if let dr = d.customDocumentRoot, !dr.isEmpty, !Self.isValidDocumentRoot(dr) {
                    log(key: "log.dom.invalidDocRoot", args: [dr], type: .error)
                    return false
                }
                return true
            }
            let invalidCount = list.domains.count - validDomains.count
            domains = validDomains
            // YEDEK ÖNCE alınmalı: migrateBakedPythonPorts() içindeki saveDomains(),
            // domains.json'u BUDANMIŞ (bozuk kayıtları düşülmüş) listeyle hemen ezebilir.
            // Yedek o ezmeden sonra alınırsa atlanan kayıtlar yedekte de bulunmaz —
            // yedek mekanizmasının önlemeye çalıştığı kayıp aynen gerçekleşirdi.
            if list.droppedCount > 0 || invalidCount > 0 {
                let backup = PathConfig.domainsJson + ".corrupt.bak"
                // Mevcut yedeğin ÜZERİNE yazma: o, İLK bozulma anının kopyasıdır.
                // Diskteki dosya bu noktada zaten budanmış olabilir; koşulsuz kopyalamak
                // orijinal (kurtarılabilir) içeriği kalıcı olarak kaybettirirdi.
                // Aynı desen: Core/AppSettings.swift (settings.json.corrupt.bak).
                if !FileHelper.exists(backup) {
                    FileHelper.copy(from: PathConfig.domainsJson, to: backup)
                }
                if list.droppedCount > 0 {
                    log(key: "log.dom.corruptRecordsSkipped", args: ["\(list.droppedCount)", backup], type: .warning)
                }
                if invalidCount > 0 {
                    log(key: "log.dom.invalidNamesSkipped", args: ["\(invalidCount)", backup], type: .warning)
                }
            }
            migrateBakedPythonPorts()   // eski gömülü port → {PORT} şablonu (502 önlemi)
            ensureApacheCompanions()    // mevcut Nginx domainleri için bare URL desteği (backfill)
            updateUsedPorts()
            // Diskle senkronuz — izleyici bu hali "dış değişiklik" sanmasın
            knownDomainsMtime = Self.mtime(of: PathConfig.domainsJson)
            log(key: "log.dom.loaded", args: ["\(domains.count)"], type: .info)
        } catch {
            // Dosya var ama tamamen çözülemedi — ÜZERİNE YAZMADAN önce yedekle,
            // aksi halde bir sonraki kaydetme tüm domainleri kalıcı olarak kaybettirir.
            let backup = PathConfig.domainsJson + ".corrupt.bak"
            // İlk bozulmanın kopyası korunur — üzerine yazma (yukarıdaki gerekçe)
            if !FileHelper.exists(backup) {
                FileHelper.copy(from: PathConfig.domainsJson, to: backup)
            }
            log(key: "log.dom.loadFailed", args: [error.localizedDescription], type: .error)
            log(key: "log.dom.corruptJsonBackedUp", args: [backup], type: .warning)
            domains = []
            // Bozuk dosyayla da diskle "senkron" sayılırız — aksi halde izleyici, dizine
            // yazan HER dosyada (ör. last-running-services.json) bozuk dosyayı yeniden
            // yükleyip sonsuz uyarı/yedek döngüsüne girerdi.
            knownDomainsMtime = Self.mtime(of: PathConfig.domainsJson)
        }
    }

    /// Eski Python domainlerinde gömülü kalan portu `{PORT}` şablonuna taşır.
    /// YALNIZCA komut, framework'ün gömülü-portlu varsayılanıyla TAM eşleşirse (kullanıcı
    /// özelleştirmemişse) değiştirilir — özel komutlara dokunulmaz. Böylece port sonradan
    /// değişince komut da güncel kalır (aksi halde reverse proxy 502 verirdi).
    private func migrateBakedPythonPorts() {
        var changed = false
        for i in domains.indices where domains[i].platform == .python {
            guard let cmd = domains[i].appCommand,
                  let port = domains[i].port,
                  let fw = domains[i].pythonFramework else { continue }
            let bakedDefault = fw.serverCommand.replacingOccurrences(of: "{PORT}", with: "\(port)")
            if cmd == bakedDefault {
                domains[i].appCommand = fw.serverCommand
                changed = true
            }
        }
        if changed {
            saveDomains()
            log(key: "log.dom.pythonPortsMigrated", type: .info)
        }
    }

    func saveDomains() {
        PathConfig.createRequiredDirectories()
        do {
            let data = try JSONEncoder().encode(DomainList(domains: domains))
            FileHelper.write(data, to: PathConfig.domainsJson)
            // Kendi yazımımızı dış değişiklik sanmamak için güncel mtime kaydedilir
            knownDomainsMtime = Self.mtime(of: PathConfig.domainsJson)
        } catch {
            log(key: "log.dom.saveFailed", args: [error.localizedDescription], type: .error)
        }
    }

    private static func mtime(of path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Application Support dizinini izlemeye başlar; domains.json dışarıdan (MCP aracı,
    /// CLI, elle düzenleme) değişirse listeyi diskten yeniden yükler. Kendi saveDomains
    /// yazımlarımız `knownDomainsMtime` karşılaştırmasıyla elenir.
    func startWatchingExternalChanges() {
        guard dirWatcher == nil else { return }
        PathConfig.createRequiredDirectories()
        let fd = open(PathConfig.appSupport, O_EVTONLY)
        guard fd >= 0 else {
            log(key: "log.dom.watcherStartFailed", args: [PathConfig.appSupport], type: .warning)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            // Handler ana kuyrukta çalışır ama derleyici bunu bilemez — MainActor'a atla
            Task { @MainActor [weak self] in
                self?.armFileWatcher()   // atomik değişimde eski vnode ölür — yenisine bağlan
                self?.scheduleExternalReloadCheck()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        dirWatcher = source
        armFileWatcher()
    }

    /// domains.json vnode izleyicisini (yeniden) kurar. Dosya atomik yazımla değiştiğinde
    /// eski dosya tanıtıcısı ölü vnode'u gösterir — .delete/.rename olayında ve her dizin
    /// olayında yeniden bağlanmak gerekir. Dosya henüz yoksa sessizce vazgeçilir; ilk
    /// oluşturulma dizin olayı üreteceğinden orada tekrar denenir.
    private func armFileWatcher() {
        fileWatcher?.cancel()
        fileWatcher = nil
        let fd = open(PathConfig.domainsJson, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            let flags = source.data
            Task { @MainActor [weak self] in
                if flags.contains(.delete) || flags.contains(.rename) {
                    self?.armFileWatcher()
                }
                self?.scheduleExternalReloadCheck()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileWatcher = source
    }

    /// Peş peşe gelen dosya olaylarını tek kontrole indirger (0.5 sn debounce).
    private func scheduleExternalReloadCheck() {
        watcherDebounce?.cancel()
        watcherDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.reloadIfExternallyChanged()
        }
    }

    private func reloadIfExternallyChanged() {
        guard let diskMtime = Self.mtime(of: PathConfig.domainsJson) else { return }
        if let known = knownDomainsMtime, abs(diskMtime.timeIntervalSince(known)) < 0.001 { return }
        loadDomains()   // sonunda knownDomainsMtime'ı da tazeler
        refreshStatus()
        log(key: "log.dom.externallyChanged", type: .info)
    }

    // MARK: - Port

    private func updateUsedPorts() { usedPorts = Set(domains.compactMap { $0.port }) }

    func nextAvailablePort(for platform: Platform) -> Int? {
        platform.portRange?.first { !usedPorts.contains($0) }
    }

    /// Bu portu BAŞKA bir domain kullanıyor mu? (`excluding`: düzenlenen domainin kendi id'si)
    /// Elle girilen portlar `nextAvailablePort`'tan geçmediğinden çakışma denetlenmezdi:
    /// iki domain aynı portu alırsa ikinci uygulama porta bağlanamaz ve site sessizce 502 verir.
    func isPortInUse(_ port: Int, excluding domainID: UUID? = nil) -> Bool {
        domains.contains { $0.port == port && $0.id != domainID }
    }

    // MARK: - CRUD

    /// Geçerli bir host adı mı? — harf/rakam/nokta/tire; boşluk/tırnak/slash yasak.
    /// Geçersiz ad vhost dosyalarını ve root ile çalışan /etc/hosts komutlarını bozar.
    /// Document root olarak KABUL EDİLEBİLİR bir yol mu?
    ///
    /// Bu değer Apache `DocumentRoot "..."` / `<Directory "...">` ve nginx `root "...";`
    /// direktiflerinin İÇİNE çift tırnak arasında gömülüyor. Kaçış yeterli bir çözüm değil:
    /// nginx `$` karakterini config'te değişken olarak yorumlar ve kaçışı yoktur, satır sonu
    /// ise doğrudan yeni direktif enjekte eder. Bu yüzden tehlikeli karakterler SINIRDA
    /// reddedilir (klasör seçici zaten normal yolları üretir).
    static func isValidDocumentRoot(_ path: String) -> Bool {
        let p = path.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, p.hasPrefix("/") else { return false }
        // " → direktifi kapatır, $ → nginx değişkeni, \ → kaçış, satır sonu → direktif enjeksiyonu,
        // ; ve { } → nginx blok sözdizimi
        //
        // Bu değer web sunucusu direktiflerinin YANI SIRA kabuk komutlarına da (start.sh,
        // kurulum script'leri) giriyor. Kabuk metakarakterleri de sınırda elenir:
        //   ` → komut ikamesi, | & ( ) → komut zincirleme ve alt kabuk, < > → yönlendirme.
        //
        // TEK TIRNAK BİLEREK SERBEST: gerçek macOS yollarında geçer (/Users/me/O'Brien/site)
        // ve kabuğa giden her yol Shell.quote'tan geçiyor — quote() tek tırnağı '\'' ile
        // doğru kaçırdığından yasaklamak meşru kullanımı kırmaktan başka işe yaramaz.
        let forbidden = CharacterSet(charactersIn: "\"$\\;{}\n\r\t`|&()<>")
        return p.rangeOfCharacter(from: forbidden) == nil
    }

    /// Verilen yolun bulunduğu birim büyük/küçük harfe DUYARLI mı?
    /// Case-only yeniden adlandırma kısayolu yalnızca DUYARSIZ birimlerde güvenlidir.
    static func volumeIsCaseSensitive(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return values?.volumeSupportsCaseSensitiveNames ?? false
    }

    /// BRAMPP'in ASLA yönetmemesi gereken host adları.
    ///
    /// `localhost` ve arkadaşları macOS'un stok /etc/hosts satırlarıdır ve SSL dizini
    /// (`ssl/localhost`) Apache + Nginx tarafından ORTAK kullanılır. Böyle bir domain
    /// eklenip sonra silinseydi: (a) removeFromHosts, root ile `sed` çalıştırıp sistemin
    /// `127.0.0.1 localhost` satırını silerdi, (b) removeDomain paylaşılan localhost SSL
    /// dizinini yok edip her iki sunucunun HTTPS'ini kırardı.
    static let reservedHostNames: Set<String> = [
        "localhost", "localhost.localdomain", "broadcasthost",
        "127.0.0.1", "0.0.0.0", "::1"
    ]

    /// Ad rezerve mi? (büyük/küçük harf duyarsız) — salt IP biçimleri de rezerve sayılır:
    /// bir IP'yi host adı gibi kaydetmek /etc/hosts satırlarını bozar.
    static func isReservedDomainName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        if reservedHostNames.contains(n) { return true }
        // Salt IPv4 (1.2.3.4) — isValidDomainName deseni bunu "geçerli ad" sayıyor
        if n.range(of: "^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", options: .regularExpression) != nil { return true }
        // Salt IPv6 / kısaltmaları — iki nokta üst üste içeren her şey
        if n.contains(":") { return true }
        return false
    }

    static func isValidDomainName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n.count <= 253, !n.hasPrefix("."), !n.hasSuffix(".") else { return false }
        // Etiketler: harf/rakam ile başlayıp biten, arada tire olabilen; nokta ile ayrılır
        let pattern = "^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)(\\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$"
        return n.range(of: pattern, options: .regularExpression) != nil
    }

    func addDomain(_ domain: Domain) async -> Bool {
        guard requireBrew(forKey: "log.op.domainCreate") else { return false }

        // Domain adı geçerli mi? — boşluk/tırnak/slash içeren ad tüm vhost'ları ve
        // root ile çalışan /etc/hosts komutlarını bozar
        guard Self.isValidDomainName(domain.name) else {
            log(key: "log.dom.invalidName", args: [domain.name], type: .error)
            activeAlert = AppAlert(title: Localizer.shared.t("dom.alert.invalidName.title"),
                                   message: String(format: Localizer.shared.t("dom.alert.invalidName.msg"), domain.name))
            return false
        }

        // Sistem adı mı? — 'localhost' gibi bir kayıt silindiğinde macOS'un stok /etc/hosts
        // satırı ve Apache+Nginx'in ORTAK kullandığı localhost SSL dizini yok edilirdi.
        guard !Self.isReservedDomainName(domain.name) else {
            log(key: "log.dom.invalidName", args: [domain.name], type: .error)
            activeAlert = AppAlert(title: Localizer.shared.t("dom.alert.reservedName.title"),
                                   message: String(format: Localizer.shared.t("dom.alert.reservedName.msg"), domain.name))
            return false
        }

        // Aynı adla domain zaten var mı? — çift kayıt vhost/hosts çakışmasına yol açar
        if domains.contains(where: { $0.name.lowercased() == domain.name.lowercased() }) {
            log(key: "log.dom.duplicateName", args: [domain.name], type: .error)
            activeAlert = AppAlert(title: Localizer.shared.t("dom.alert.duplicateName.title"),
                                   message: String(format: Localizer.shared.t("dom.alert.duplicateName.msg"), domain.name))
            return false
        }

        var domain = domain   // SSL başarısız olursa sslEnabled'ı düşürebilmek için mutable

        // Ayarlar'daki özel Sites klasörü: varsayılandan farklıysa, yol OLUŞTURMA ANINDA
        // domain'e sabitlenir (customDocumentRoot). Böylece ayar sonradan değişse bile
        // mevcut domainlerin klasörleri kaymaz — yalnızca YENİ domainler yeni konuma gider.
        if domain.customDocumentRoot == nil {
            let base = AppSettings.load().sitesPath
            if !base.isEmpty, base != PathConfig.sites {
                domain.customDocumentRoot = "\(base)/\(domain.name)"
            }
        }

        // Document root config direktiflerine gömüldüğünden sınırda doğrulanır
        if let dr = domain.customDocumentRoot, !Self.isValidDocumentRoot(dr) {
            log(key: "log.dom.invalidDocRoot", args: [dr], type: .error)
            isLoading = false
            return false
        }

        // Port çakışması yedek kontrolü: sheet'ler artık engelliyor ama içe aktarma gibi
        // yollar o doğrulamadan geçmez. İki domain aynı portu alırsa ikinci uygulama porta
        // bağlanamaz ve site sessizce 502 verir — sessiz çakışma yerine boş port ata.
        if let p = domain.port, isPortInUse(p, excluding: domain.id) {
            guard let free = nextAvailablePort(for: domain.platform) else {
                log(key: "log.dom.noFreePort", args: ["\(p)", domain.name], type: .error)
                isLoading = false
                return false
            }
            log(key: "log.dom.portReassigned", args: ["\(p)", domain.name, "\(free)"], type: .warning)
            domain.port = free
        }

        isLoading = true
        log(key: "log.dom.creating", args: [domain.name], type: .command)

        // **KAYIT ÖNCE YAZILIR.** Eskiden en sonda yazılıyordu ve arada makine, BRAMPP'ın
        // hiç bilmediği bir alan adını sunmaya hazır hâle geliyordu: site klasörü,
        // sertifika, vhost, hosts girişi hepsi vardı ama kayıt yoktu. `addToHosts`
        // yönetici parolası isteyip süresiz beklediğinden bu pencere dakikalar sürebilir;
        // orada çıkılırsa geriye hiçbir arayüzde görünmeyen, hiçbir şeyin toplamadığı
        // dosyalar kalıyordu.
        //
        // Sıra ayrıca `createVHostConfigLocked`in "kayıt hâlâ duruyor mu" denetimi için
        // ZORUNLU: o denetim silinen bir alan adının vhost'unun geri yazılmasını
        // engelliyor ve kaydı sonda yazmak, oluşturmanın kendi yazımını da engellerdi.
        domains.append(domain)
        updateUsedPorts()
        saveDomains()

        /// Oluşturma yarıda kalırsa kaydı geri al — yoksa dosyasız bir kayıt kalırdı.
        func abandon() {
            domains.removeAll { $0.id == domain.id }
            updateUsedPorts()
            saveDomains()
            isLoading = false
        }

        guard createSiteFolder(for: domain) else { abandon(); return false }

        if domain.sslEnabled {
            if !(await createSSLCertificate(for: domain)) {
                // Sertifika yoksa SSL bloğu Apache/Nginx'i çökertir — domaini SSL'siz yap
                log(key: "log.dom.sslFailedHttpOnly", type: .warning)
                domain.sslEnabled = false
                domain.redirectHTTPToHTTPS = false
            }
        }

        guard await createVHostConfig(for: domain) else { abandon(); return false }

        // .brampp.json yaz (backend platformlar için)
        writeConfigFiles(for: domain)

        // Bağımlılık servisleri (MariaDB/PostgreSQL/Redis…) — PHP siteleri de dahil:
        // site ilk açılışta DB'ye bağlanamayıp hata sayfası göstermesin.
        await ensureDependencies(for: domain)

        // /etc/hosts'a ekle — şifre iptal edilirse domain YİNE DE oluşturulur (dosyalar silinmez).
        // Yalnızca hosts girişi eksik kalır; kullanıcıya elle ekleme talimatı gösterilir.
        let hostsOK = await addToHosts(domain.name)
        // Bağlı web sunucusu durmuşsa otomatik başlat + reload (yeni domain hemen erişilebilsin)
        await reloadWebServer(for: domain, autoStart: true)

        // Kayıt ZATEN eklendi; burada yalnızca oluşturma sırasında DEĞİŞEN alanlar
        // işlenir — sertifika üretilemediyse `sslEnabled` yukarıda false'a çekiliyor ve
        // kayıt bunu yansıtmazsa arayüz HTTPS varmış gibi gösterirdi.
        if let i = domains.firstIndex(where: { $0.id == domain.id }) {
            domains[i] = domain
            updateUsedPorts()
            saveDomains()
        }

        if hostsOK {
            log(key: "log.dom.created", args: [domain.name], type: .success)
            log(key: "log.dom.url", args: [domain.url], type: .info)
        } else {
            // Domain oluşturuldu ama /etc/hosts'a yazılamadı — geri alma YOK, elle ekleme talimatı
            log(key: "log.dom.createdNoHosts", args: [domain.name], type: .warning)
            log(key: "log.dom.hostsManualHint", args: [domain.name], type: .info)
            activeAlert = AppAlert(
                title: "Domain Oluşturuldu — hosts Girişi Eksik",
                message: "'\(domain.name)' oluşturuldu fakat yönetici izni verilmediği için /etc/hosts'a eklenemedi. Dosyalar korundu.\n\nTarayıcıda açılması için şu satırı /etc/hosts'a ekleyin:\n127.0.0.1  \(domain.name)\n\nDomaini silip yeniden oluşturmanıza gerek yok; ayarlardan tekrar deneyebilirsiniz."
            )
        }
        isLoading = false
        return true
    }

    /// Alan adının açık paylaşımı varsa kapatır. Vhost DEĞİŞMEDEN ÖNCE çağrılmalı —
    /// aradaki her an, adresin varsayılan siteyi yayınladığı bir penceredir.
    ///
    /// Yeniden adlandırmada ESKİ adla çağrılır: tünel kaydı eski adla saklandığı için
    /// yeni adla arayan (arayüz rozeti dahil) onu bir daha bulamaz ve kullanıcı çalışan
    /// tüneli durduramaz hâle gelir.
    /// - Returns: paylaşım artık KAPALI ise `true`. Açık paylaşım yoksa da `true` —
    ///   çağıran için anlamlı olan "bu adres artık dışarıya açık değil" bilgisidir.
    @discardableResult
    private func stopShareBeforeVHostChange(_ name: String) async -> Bool {
        guard let tunnelManager, tunnelManager.tunnel(for: name) != nil else { return true }
        // SONUÇ YOK SAYILMAZDI ve başarı KOŞULSUZ loglanıyordu: tünel süreci ölmese bile
        // "paylaşım kapatıldı" yazıyordu. `stop` tam da bunu ayırt etmek için Bool döner.
        guard await tunnelManager.stop(domainName: name) else { return false }
        log(key: "log.dom.shareStoppedWithDomain", args: [name], type: .warning)
        return true
    }

    func removeDomain(_ domain: Domain) async {
        isLoading = true
        log(key: "log.dom.deleting", args: [domain.name], type: .command)

        // Uçuştaki `updateDomain` görevinin neslini GEÇERSİZ KIL. Aşağıda dört `await`
        // var — `removeFromHosts` yönetici parolası isteyebilir, yani pencere saniyeler
        // sürebilir — ve o süre boyunca eski görev uyanıp silinen alan adının vhost'unu
        // GERİ YAZARDI. `setDomainEnabled` ile `renameDomain` tam bu nedenle aynı
        // korumayı taşıyor; silme yolunda eksikti.
        // PAYLAŞIM ÖNCE KAPANIR, kayıt HENÜZ DÜŞMEDEN.
        //
        // Sıra eskiden tersti ve sonuç da yok sayılıyordu. Tünel kapanmazsa şu oluyordu:
        // kayıt siliniyor, vhost siliniyor, ama cloudflared hâlâ koşuyor — yani herkese
        // açık adres artık bu alan adını değil, VARSAYILAN SİTEYİ yayınlıyor. Üstelik
        // tünel kaydı alan adına bağlı olduğundan kullanıcı onu arayüzden bir daha
        // durduramıyor. Kapatılamayan bir paylaşımın üstüne silme yapılmaz.
        guard await stopShareBeforeVHostChange(domain.name) else {
            log(key: "log.dom.shareStopFailedAbort", args: [domain.name], type: .error)
            isLoading = false
            return
        }

        updateGenerations[domain.id, default: 0] += 1
        // Kayıt da şimdi düşer: `await`ler boyunca domain listede durmaya devam
        // etseydi, o sırada koşan başka bir akış onu hâlâ var sayardı.
        domains.removeAll { $0.id == domain.id }
        updateUsedPorts()
        saveDomains()

        // Çalışan uygulama sürecini durdur (hayalet process kalmasın)
        if [Platform.python, .nodejs, .dotnet].contains(domain.platform) {
            await NativeProcessManager.stop(domain: domain)
            // Application Support/processes/{name}/ — start.sh, app.pid, app.log, .brampp.json
            FileHelper.remove(PathConfig.processDir(domain: domain.name))
        }

        FileHelper.remove(domain.vhostConfigPath)
        // PAYLAŞILAN localhost SSL dizini silinmez: Apache + Nginx varsayılan vhost'ları
        // (ve phpMyAdmin/Adminer) aynı sertifikayı kullanır — silinirse ikisinin de HTTPS'i
        // kırılır. Rezerve adlar artık sınırda reddediliyor; bu, ESKİ kayıtlar için ağ.
        let sslDir = PathConfig.sslDirPath(for: domain.name)
        if !PathConfig.isSharedLocalhostSSLDir(sslDir) {
            FileHelper.remove(sslDir)
        }
        // Nginx domainleri için yazılmış Apache companion vhost'u da temizle
        if domain.webServer == .nginx {
            FileHelper.remove(apacheCompanionPath(for: domain.name))
        }

        // Web sunucusu logları. Vhost'lar bunları alan adı başına yazıyor ama silme
        // yolu hiç dokunmuyordu: her silinen alan adı arkasında iki-dört dosya
        // bırakıyordu ve adı bir daha kullanılmadıkça hiçbir şey onları toplamıyordu.
        // Dördü birden silinir — gerekçesi Domain.allLogPaths'te.
        for path in domain.allLogPaths { FileHelper.remove(path) }

        // Tünel izleri. `TunnelManager.stop` log dosyasını BİLEREK bırakır (paylaşım
        // bitince kullanıcı ne olduğuna bakabilsin diye) ve yalnızca .pid'i siler.
        // Ama alan adının kendisi gidiyorsa o kaydın bakılacağı bir bağlam kalmaz.
        FileHelper.remove(PathConfig.tunnelLog(domain: domain.name))
        FileHelper.remove(PathConfig.tunnelPid(domain: domain.name))

        // SONUÇ YOK SAYILMAZ: başarısızlıkta /etc/hosts'ta bu ada bir satır kalır ve
        // kayıt artık silindiği için hiçbir akış onu bir daha aramaz — sessizce
        // kalıcı olur. En azından kullanıcı bunu görmeli.
        if await removeFromHosts(domain.name) == false {
            log(key: "log.dom.hostsRemoveFailed", args: [domain.name], type: .error)
        }
        // autoStart:false — silmede durmuş sunucuyu ayağa kaldırmaya gerek yok.
        // (nginx dalı companion nedeniyle Apache'yi de yeniler; ayrı çağrı gerekmez.)
        await reloadWebServer(for: domain)

        // Nesil sayacı artık boşuna yer tutuyor. EN SONDA düşer: neslini okuyan her
        // `await` bitmiş olmalı, yoksa uçuştaki bir görev sayacı sıfırdan yeniden
        // yaratıp kendini geçerli sanardı.
        updateGenerations.removeValue(forKey: domain.id)

        log(key: "log.dom.deleted", args: [domain.name], type: .success)
        isLoading = false
    }

    func updateDomain(_ domain: Domain) {
        guard let i = domains.firstIndex(where: { $0.id == domain.id }) else { return }
        // Document root VHost direktiflerine tırnak arasında gömülür — addDomain ile aynı
        // sınır doğrulaması burada da yapılmalı (aksi halde config enjeksiyonu/bozulması).
        if let dr = domain.customDocumentRoot, !Self.isValidDocumentRoot(dr) {
            log(key: "log.dom.invalidDocRootUpdate", args: [dr], type: .error)
            return
        }
        // PHP sürümü DEĞİŞTİYSE yeni sürümün FPM servisi çalışmıyor olabilir —
        // vhost yeni porta (:908x) proxy'leyeceğinden site 502'ye düşerdi.
        // Yeni sürümün FPM'ini otomatik başlat (zaten çalışıyorsa hızla geçer).
        // Doğrulama başarısız olursa geri dönülecek anlık görüntü (vhost geri alınırsa
        // modelin de geri alınması gerekir — aksi halde domains.json yeni ayarları iddia
        // ederken sunucu ESKİ config'i servis eder).
        let previous = domains[i]
        let oldPHP = previous.phpVersion
        let generation = (updateGenerations[domain.id] ?? 0) + 1
        updateGenerations[domain.id] = generation
        domains[i] = domain
        if domain.platform == .php, let newPHP = domain.phpVersion, newPHP != oldPHP {
            Task { _ = await ensureServiceRunning?("php@\(newPHP.rawValue)") }
        }
        // Document root değiştirilmiş olabilir — web sunucusu var olmayan dizinde başlamaz
        FileHelper.createDirectory(domain.sitePath)
        // Config dosyalarını güncelle (start.sh + .brampp.json)
        writeConfigFiles(for: domain)
        // Port değişmiş olabilir — sonraki port önerisinin çakışmaması için güncelle
        updateUsedPorts()
        saveDomains()
        // NOT: "güncellendi" başarı logu buradan KALDIRILDI. VHost doğrulaması aşağıdaki
        // Task'ta yapılıyor; başarı önceden loglanırsa doğrulama config'i geri aldığında
        // kullanıcı "güncellendi" görür ama diskteki vhost ESKİ içerikte kalır.
        // VHost yeniden üretimi (doğrulamalı) + reload @MainActor'ı bloke etmesin — arka planda
        Task {
            // DEVRE DIŞI domainin vhost'u YENİDEN ÜRETİLMEZ. setDomainEnabled(false) onu
            // bilerek kaldırmıştı; burada yeniden yazmak domaini tekrar servis edilir hale
            // getirir ama isEnabled=false kaldığından UI "devre dışı" göstermeye devam eder
            // (üstelik /etc/hosts girişi de yok). Ayarlar yine de kaydedildi; tekrar
            // etkinleştirildiğinde setDomainEnabled(true) vhost'u güncel ayarlarla üretir.
            guard domain.isEnabled else {
                log(key: "log.dom.savedWhileDisabled", args: [domain.name], type: .info)
                return
            }

            // SSL yeni açıldıysa ve sertifika yoksa üret. Üretilemezse addDomain ile aynı
            // davranış: HTTP'ye düş — aksi halde vhost var olmayan sertifikaya işaret eder,
            // doğrulama TÜM güncellemeyi geri alır ve kullanıcının diğer değişiklikleri de
            // sessizce kaybolurdu.
            var current = domain
            if current.sslEnabled, await sslCertNeedsRenewal(current.sslCertPath) {
                if !(await createSSLCertificate(for: current)) {
                    current.sslEnabled = false
                    current.redirectHTTPToHTTPS = false
                    // Sertifika üretimi (mkcert) saniyeler sürebilir — bu sırada kullanıcı
                    // YENİ bir düzenleme kaydetmiş olabilir. Model ve disk yalnızca nesil
                    // hâlâ bizimken düşürülür; aksi halde yeni kaydın SSL tercihi ezilirdi.
                    if updateGenerations[current.id] == generation,
                       let j = domains.firstIndex(where: { $0.id == current.id }) {
                        domains[j].sslEnabled = false
                        domains[j].redirectHTTPToHTTPS = false
                        saveDomains()
                    }
                    log(key: "log.dom.sslFailedUpdateHttp", args: [current.name], type: .warning)
                }
            }

            // Kullanıcı Düzenle'den yeni bir DB/önbellek bağımlılığı eklemiş olabilir → başlat
            await ensureDependencies(for: current)

            // await'ler sırasında domain silinmiş, devre dışı bırakılmış veya YENİDEN
            // düzenlenmiş olabilir — bayat anlık görüntüyle vhost yazmak daha yeni ayarları
            // ezerdi. Nesil değiştiyse daha yeni updateDomain devrede: onun Task'ı uygular.
            guard domains.contains(where: { $0.id == current.id && $0.isEnabled }),
                  updateGenerations[current.id] == generation else { return }

            let vhostResult = await createVHostConfigResult(for: current)
            // configtest saniyeler sürer — bu sırada daha yeni bir kayıt geldiyse bu Task'ın
            // sonucu artık geçersizdir: ne geri alma ne "güncellendi" logu. Aksi halde geri
            // alma, kullanıcının az önce kaydettiği YENİ düzenlemeyi previous'a ezerdi.
            guard updateGenerations[current.id] == generation else { return }

            if vhostResult == .failed {
                // Doğrulama vhost'u ESKİ içeriğine geri aldı → modeli ve config dosyalarını
                // da geri al. Domain bu arada silinmiş olabilir; index yeniden aranır.
                if let j = domains.firstIndex(where: { $0.id == current.id }) {
                    domains[j] = previous
                    writeConfigFiles(for: previous)   // start.sh/.brampp.json eski değerlere dönsün
                    updateUsedPorts()
                    saveDomains()
                }
                log(key: "log.dom.updateRolledBack", args: [current.name], type: .error)
                activeAlert = AppAlert(
                    title:   "Güncelleme Geri Alındı",
                    message: "'\(current.name)' için yeni yapılandırma doğrulanamadı. Önceki ayarlar geri yüklendi; ayrıntılar konsol panelinde."
                )
                return
            }
            log(key: "log.dom.updated", args: [current.name], type: .success)
            await reloadWebServer(for: current, autoStart: true)

            // Backend uygulaması ÇALIŞIYORSA yeni ayarlarla (port/komut/env) yeniden başlat —
            // aksi halde değişiklikler ancak elle yeniden başlatınca etkili olurdu.
            if [Platform.nodejs, .python, .dotnet].contains(current.platform),
               await NativeProcessManager.isRunning(domain: current) {
                log(key: "log.dom.restartingAfterUpdate", args: [current.name], type: .command)
                if current.platform == .python {
                    await startPythonApp(domain: current)   // ensureEnvironment + start (önce stop)
                } else {
                    await startNativeApp(domain: current)   // .NET proje kontrolü + start (önce stop)
                }
            }
        }
    }

    // MARK: - Etkinleştir / Devre Dışı Bırak

    /// Domaini silmeden geçici olarak devre dışı bırakır veya tekrar etkinleştirir.
    /// Devre dışı: çalışan uygulama durdurulur, vhost (+ companion) ve /etc/hosts girişi
    /// KALDIRILIR — ama domains.json kaydı ve site klasörü/dosyaları KORUNUR.
    /// Etkin: vhost + hosts yeniden üretilir (sanki yeni ekleniyormuş gibi).
    func setDomainEnabled(_ domain: Domain, enabled: Bool) async {
        guard domains.contains(where: { $0.id == domain.id }) else { return }
        guard domain.isEnabled != enabled else { return }

        isLoading = true
        // Devam eden bir updateDomain doğrulaması varsa nesli ilerlet: onun geri alması
        // (previous anlık görüntüsü) buradaki isEnabled değişikliğini geri çevirirdi.
        updateGenerations[domain.id, default: 0] += 1
        var updated = domain
        updated.isEnabled = enabled

        if enabled {
            log(key: "log.dom.enabling", args: [domain.name], type: .command)

            // Sertifika dışarıdan silinmiş ya da mkcert CA sıfırlanmış olabilir. Var olmayan
            // sertifikaya işaret eden bir SSL bloğu Apache/Nginx'i komple başlatmaz — bu yüzden
            // addDomain ile AYNI davranış: önce yeniden üret, olmuyorsa HTTP'ye düş.
            if updated.sslEnabled, await sslCertNeedsRenewal(updated.sslCertPath) {
                if !(await createSSLCertificate(for: updated)) {
                    log(key: "log.dom.sslFailedEnableHttp", type: .warning)
                    updated.sslEnabled = false
                    updated.redirectHTTPToHTTPS = false
                }
            }

            // Vhost yazılamazsa etkinleştirme TAMAMLANMIŞ SAYILMAZ: aksi halde domains.json
            // isEnabled=true derken ortada vhost olmaz ve domain sessizce servis edilmez.
            guard await createVHostConfig(for: updated) else {
                log(key: "log.dom.enableFailed", args: [domain.name], type: .error)
                isLoading = false
                return
            }
            // İndeks await'lerden ÖNCE çözülemez — arada domain silinirse bayat pozisyonel
            // indeks YANLIŞ kaydı ezer. Yazımdan hemen önce id ile yeniden çözülür.
            guard let idx = domains.firstIndex(where: { $0.id == domain.id }) else {
                isLoading = false
                return
            }
            domains[idx] = updated
            saveDomains()
            _ = await addToHosts(updated.name)
            await ensureDependencies(for: updated)
            await reloadWebServer(for: updated, autoStart: true)
            log(key: "log.dom.enabled", args: [domain.name], type: .success)
        } else {
            log(key: "log.dom.disabling", args: [domain.name], type: .command)
            // Devre dışı bırakmak da vhost'u siliyor — silmeyle AYNI tehlike, o yüzden
            // AYNI koruma. Sonuç yok sayılıyordu: cloudflared SIGKILL'den sağ çıktığında
            // bile vhost siliniyor, herkese açık adres yayında kalıp varsayılan siteyi
            // (phpMyAdmin ve Adminer dâhil) sunmaya başlıyordu.
            guard await stopShareBeforeVHostChange(domain.name) else {
                log(key: "log.dom.shareStopFailedDisable", args: [domain.name], type: .error)
                isLoading = false
                return
            }
            // Çalışan backend'i durdur (arka planda ghost süreç kalmasın)
            if [Platform.nodejs, .python, .dotnet].contains(domain.platform) {
                await NativeProcessManager.stop(domain: domain)
            }
            FileHelper.remove(domain.vhostConfigPath)
            if domain.webServer == .nginx {
                FileHelper.remove(apacheCompanionPath(for: domain.name))
            }
            await removeFromHosts(domain.name)
            // Yazımdan hemen önce indeksi yeniden çöz (yukarıdaki gerekçe)
            guard let idx = domains.firstIndex(where: { $0.id == domain.id }) else {
                isLoading = false
                return
            }
            domains[idx] = updated
            saveDomains()
            // Kaldırılan vhost için web sunucusunu yenile (durmuş sunucuyu ayağa kaldırma)
            await reloadWebServer(for: domain)
            log(key: "log.dom.disabled", args: [domain.name], type: .success)
        }
        refreshStatus()
        isLoading = false
    }

    // MARK: - Rename

    /// Domaini yeniden adlandırır: bir domainin sahip olduğu TÜM artefaktları taşır/yeniden üretir.
    ///   1. vhost config (+ Nginx için Apache companion)
    ///   2. SSL sertifikası — mkcert host'a özeldir, YENİDEN ÜRETİLİR (taşınamaz)
    ///   3. /etc/hosts girişi (eski sil, yeni ekle)
    ///   4. process dizini (start.sh/app.log/.brampp.json) — taşınır, start.sh yeniden üretilir
    ///   5. site klasörü — yalnızca VARSAYILAN konumdaysa (özel document root değilse) taşınır
    ///   6. domains.json kaydı (aynı id, yeni ad)
    /// Çalışan backend uygulaması önce durdurulur, sonunda yeni adla yeniden başlatılır.

    /// Rename sonucu — UI (renameSheet) hata mesajını sheet İÇİNDE gösterebilsin diye
    /// mesaj döner (activeAlert modal sheet arkasında kaybolabiliyordu).
    enum RenameResult: Equatable { case success; case failure(String) }

    @discardableResult
    func renameDomain(_ domain: Domain, to rawNewName: String) async -> RenameResult {
        let newName = rawNewName.trimmingCharacters(in: .whitespaces).lowercased()
        let oldName = domain.name
        guard newName != oldName else { return .success }   // değişiklik yok

        guard Self.isValidDomainName(newName) else {
            return .failure("'\(newName)' geçerli bir alan adı değil. Yalnızca harf, rakam, nokta ve tire kullanın.")
        }
        // Sistem adına yeniden adlandırma da yasak — addDomain ile aynı gerekçe
        // (stok /etc/hosts satırları ve paylaşılan localhost SSL dizini).
        guard !Self.isReservedDomainName(newName) else {
            return .failure("'\(newName)' sistem tarafından ayrılmış bir addır (localhost, broadcasthost, IP adresleri…). Farklı bir ad seçin.")
        }
        guard !domains.contains(where: { $0.name.lowercased() == newName && $0.id != domain.id }) else {
            return .failure("'\(newName)' adında bir domain zaten kayıtlı.")
        }
        guard domains.contains(where: { $0.id == domain.id }) else {
            return .failure("Domain bulunamadı.")
        }

        // Doğrulamalar geçtikten SONRA, dosyalara dokunmadan ÖNCE: buradan sonrası
        // artık geri dönülmeyecek bir yeniden adlandırma. Tam bu yüzden paylaşımın
        // kapandığından EMİN olunmadan başlanmaz: yeniden adlandırma vhost'u ESKİ adla
        // siler, tünel ise eski ada bağlıdır — kapanmadıysa hem herkese açık adres
        // varsayılan siteye düşer hem de kullanıcı onu arayüzden bir daha bulamaz.
        guard await stopShareBeforeVHostChange(oldName) else {
            log(key: "log.dom.shareStopFailedRename", args: [oldName], type: .error)
            isLoading = false
            return .failure(Localizer.shared.t("dom.rename.shareStopFailed"))
        }

        // CASE-ONLY rename (Api.local → api.local): macOS varsayılan dosya sistemi
        // büyük/küçük harfe DUYARSIZ olduğundan tüm yollar AYNI dosyaya çözülür.
        // remove+move veya "eskiyi sil" bu durumda VERİ KAYBETTİRİR. Bu yüzden dosya
        // taşıma/silme YAPILMADAN yalnızca vhost/hosts/model güncellenir.
        // ÖNEMLİ: Bu kısayol "aynı dosyaya çözülür" varsayımına dayanır ve bu YALNIZCA
        // büyük/küçük harfe duyarsız birimlerde doğrudur. Duyarlı APFS (geliştiricilerde
        // yaygın) üzerinde 'Api.local.conf' ile 'api.local.conf' AYRI dosyalardır; dosya
        // taşımayı atlamak eskileri yetim bırakır ve yeni ad dosyasız kalırdı.
        let caseOnly = oldName.lowercased() == newName && !Self.volumeIsCaseSensitive(PathConfig.sites)

        isLoading = true
        defer { isLoading = false }
        log(key: "log.dom.renaming", args: [oldName, newName], type: .command)

        // Devam eden bir updateDomain doğrulaması varsa nesli ilerlet: o Task'ın elindeki
        // anlık görüntü ESKİ adı taşır; geri alması bu yeniden adlandırmayı ezerdi.
        updateGenerations[domain.id, default: 0] += 1

        let isBackend = [Platform.nodejs, .python, .dotnet].contains(domain.platform)
        var wasRunning = false
        if isBackend { wasRunning = await NativeProcessManager.isRunning(domain: domain) }
        if isBackend { await NativeProcessManager.stop(domain: domain) }

        var newDomain = domain
        newDomain.name = newName

        // Herhangi bir başarısızlıkta eski durumu kurtar (yarı-taşınmış kalmasın)
        func abort(_ msg: String) async -> RenameResult {
            log(key: "log.dom.renameAborted", args: [msg], type: .error)
            if wasRunning { await startBackend(domain) }   // eski adla geri başlat
            return .failure(msg)
        }

        let usingDefaultSite = (domain.customDocumentRoot ?? "").isEmpty
        let oldSite = "\(PathConfig.sites)/\(oldName)"
        let newSite = "\(PathConfig.sites)/\(newName)"

        // ── 1) Site klasörünü taşı (case-only DEĞİLSE ve varsayılan konumdaysa) ──
        if !caseOnly, usingDefaultSite, FileHelper.exists(oldSite) {
            // Hedef "boş mu": gizli dosyalar DAHİL hiçbir giriş olmamalı (.git/.env silinmesin)
            if FileHelper.exists(newSite), !FileHelper.contentsOfDirectory(newSite).isEmpty {
                return await abort("'\(newSite)' zaten var ve boş değil (gizli dosyalar dahil). Farklı bir ad seçin.")
            }
            FileHelper.remove(newSite)   // yalnızca tamamen boş dizin — güvenli
            guard FileHelper.move(from: oldSite, to: newSite) else {
                return await abort("Site klasörü taşınamadı: \(oldSite) → \(newSite)")
            }
            log(key: "log.dom.siteFolderMoved", args: [newSite], type: .info)
        }

        // ── 2) Process dizinini taşı (case-only DEĞİLSE) ──
        if isBackend, !caseOnly {
            let oldProc = PathConfig.processDir(domain: oldName)
            let newProc = PathConfig.processDir(domain: newName)
            if FileHelper.exists(oldProc) {
                if FileHelper.exists(newProc), !FileHelper.contentsOfDirectory(newProc).isEmpty {
                    // Beklenmedik dolu hedef — üzerine yazma, geri al (site zaten taşındıysa geri taşı)
                    if usingDefaultSite, FileHelper.exists(newSite) { _ = FileHelper.move(from: newSite, to: oldSite) }
                    return await abort("Process klasörü hedefi dolu: \(newProc)")
                }
                FileHelper.remove(newProc)
                guard FileHelper.move(from: oldProc, to: newProc) else {
                    if usingDefaultSite, FileHelper.exists(newSite) { _ = FileHelper.move(from: newSite, to: oldSite) }
                    return await abort("Process klasörü taşınamadı: \(oldProc) → \(newProc)")
                }
                FileHelper.remove(PathConfig.processPid(domain: newName))   // bayat PID
            }
        }
        if isBackend { writeConfigFiles(for: newDomain) }   // start.sh + .brampp.json yeni adla

        // ── 3) YENİ SSL sertifikası üret (ESKİ dizini SİLMEDEN — üretim başarısızsa geri dönülür) ──
        if domain.sslEnabled, !caseOnly {
            if !(await createSSLCertificate(for: newDomain)) {
                log(key: "log.dom.sslFailedRename", type: .warning)
                newDomain.sslEnabled = false
                newDomain.redirectHTTPToHTTPS = false
            }
        }

        // ── 4) YENİ vhost'u yaz + DOĞRULA (createVHostConfig configtest yapar, bozarsa geri alır) ──
        //     Başarısızsa ESKİ vhost/SSL'e DOKUNMADAN geri dön — domain erişilebilir kalır.
        //     Burada .unverified de KABUL EDİLMEZ: aşağıdaki adım eski vhost/SSL'i SİLİYOR.
        //     Config zaten bozuk olduğu için doğrulayamadıysak, silme yaparsak kullanıcı hem
        //     eski hem yeni yapılandırmayı kaybedebilir.
        guard await createVHostConfigResult(for: newDomain) == .verified else {
            // Yeni SSL üretildiyse temizle; taşınan klasörleri geri al
            if !caseOnly {
                FileHelper.remove(PathConfig.sslDirPath(for: newName))
                // Yeni ad için diske yazılmış (ama doğrulanamamış) vhost/companion yetim kalmasın
                FileHelper.remove(newDomain.vhostConfigPath)
                if newDomain.webServer == .nginx { FileHelper.remove(apacheCompanionPath(for: newName)) }
                if isBackend, FileHelper.exists(PathConfig.processDir(domain: newName)) {
                    _ = FileHelper.move(from: PathConfig.processDir(domain: newName),
                                        to: PathConfig.processDir(domain: oldName))
                    writeConfigFiles(for: domain)
                }
                if usingDefaultSite, FileHelper.exists(newSite) { _ = FileHelper.move(from: newSite, to: oldSite) }
            }
            return await abort("Yeni yapılandırma (\(newDomain.webServer.displayName)) doğrulanamadı — eski ad korundu.")
        }

        // ── 5) Yeni vhost DOĞRULANDI → artık ESKİ artefaktları güvenle sil ──
        if !caseOnly {
            FileHelper.remove(domain.vhostConfigPath)                    // eski vhost
            if domain.webServer == .nginx { FileHelper.remove(apacheCompanionPath(for: oldName)) }
            // Eski SSL EN SON — ama paylaşılan localhost dizini asla silinmez (eski adı
            // 'localhost' olan bir kayıt Apache+Nginx sertifikasını götürürdü)
            let oldSSLDir = PathConfig.sslDirPath(for: oldName)
            if domain.sslEnabled, !PathConfig.isSharedLocalhostSSLDir(oldSSLDir) {
                FileHelper.remove(oldSSLDir)
            }
        }

        // ── 6) /etc/hosts + model + reload ──
        await removeFromHosts(oldName)
        let hostsOK = await addToHosts(newName)
        // İndeks await'lerden ÖNCE çözülemez: bu arada başka bir domain silinmiş olabilir ve
        // bayat pozisyonel indeks YANLIŞ kaydı ezer (veya sınır dışına çıkar). Yazımdan hemen
        // önce id ile yeniden çözülür — kayıt yoksa (silinmiş) model yazımı atlanır.
        if let idx = domains.firstIndex(where: { $0.id == newDomain.id }) {
            domains[idx] = newDomain
        }
        updateUsedPorts()
        saveDomains()
        await reloadWebServer(for: newDomain, autoStart: true)
        if wasRunning { await startBackend(newDomain) }

        if hostsOK {
            log(key: "log.dom.renamed", args: [oldName, newName], type: .success)
            return .success
        } else {
            log(key: "log.dom.renamedNoHosts", args: [newName], type: .warning)
            return .failure("Domain yeniden adlandırıldı ancak /etc/hosts güncellenemedi (yönetici izni). Elle ekleyin: 127.0.0.1  \(newName)")
        }
    }

    /// Backend platform uygulamasını doğru başlatıcıyla çalıştırır (rename için yardımcı).
    private func startBackend(_ domain: Domain) async {
        if domain.platform == .python { await startPythonApp(domain: domain) }
        else { await startNativeApp(domain: domain) }
    }

    // MARK: - Site Folder

    private func createSiteFolder(for domain: Domain) -> Bool {
        log(key: "log.dom.siteFolderPreparing", type: .info)

        guard FileHelper.createDirectory(domain.sitePath) else {
            log(key: "log.dom.siteFolderCreateFailed", args: [domain.sitePath], type: .error); return false
        }

        // Dolu klasör (manuel document root veya yeniden eklenen domain) — kullanıcı dosyalarının üzerine yazma
        let existingItems = FileHelper.contentsOfDirectory(domain.sitePath).filter { !$0.hasPrefix(".") }
        if !existingItems.isEmpty {
            log(key: "log.dom.siteFolderNotEmpty", args: ["\(existingItems.count)", domain.sitePath], type: .info)
            return true
        }

        do {
            switch domain.platform {
            case .php:
                try VHostTemplates.samplePHP(domain: domain.name, phpVersion: domain.phpVersion?.rawValue ?? "8.3")
                    .write(toFile: "\(domain.sitePath)/index.php", atomically: true, encoding: .utf8)
            case .nodejs:
                try VHostTemplates.sampleNodeJS(domain: domain.name, port: domain.port ?? 3001)
                    .write(toFile: "\(domain.sitePath)/app.js", atomically: true, encoding: .utf8)
                try VHostTemplates.samplePackageJSON(domain: domain.name)
                    .write(toFile: "\(domain.sitePath)/package.json", atomically: true, encoding: .utf8)
            case .python:
                try VHostTemplates.samplePython(domain: domain.name, framework: domain.pythonFramework ?? .fastapi)
                    .write(toFile: "\(domain.sitePath)/main.py", atomically: true, encoding: .utf8)
                try VHostTemplates.sampleRequirements(framework: domain.pythonFramework ?? .fastapi)
                    .write(toFile: "\(domain.sitePath)/requirements.txt", atomically: true, encoding: .utf8)
            case .dotnet:
                log(key: "log.dom.dotnetNewHint", type: .info)
            case .static_:
                try VHostTemplates.sampleHTML(domain: domain.name)
                    .write(toFile: "\(domain.sitePath)/index.html", atomically: true, encoding: .utf8)
            }
            log(key: "log.dom.siteFolderCreated", args: [domain.sitePath], type: .success)
            return true
        } catch {
            log(key: "log.dom.sampleFileFailed", args: [error.localizedDescription], type: .error)
            return false
        }
    }

    // MARK: - Config Files

    /// Backend platformlar (Node.js, Python, .NET) için
    /// `start.sh` dosyasını oluşturur — tüm platformlar NativeProcessManager kullanır.
    func writeConfigFiles(for domain: Domain) {
        guard [Platform.nodejs, .python, .dotnet].contains(domain.platform) else { return }

        let stackDir   = NativeProcessManager.dir(for: domain)
        let scriptPath = NativeProcessManager.startScriptPath(for: domain)
        FileHelper.createDirectory(stackDir)
        let script = NativeProcessManager.buildStartScript(for: domain)
        if FileHelper.write(script, to: scriptPath) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            log(key: "log.dom.startScriptCreated", type: .info)
        }

        // .brampp.json — Application Support/processes/{name}/ altında tutulur (site dizini kirletilmez)
        let config = BRAMPPConfig.from(domain)
        if config.write(to: stackDir) {
            log(key: "log.dom.configJsonCreated", type: .info)
        }
    }

    // MARK: - SSL

    func installMkcertCA() async -> Bool {
        await mkcertManager.installCA { [weak self] msg, type in self?.log(msg, type: type) }
    }

    /// Sertifika yok mu, ya da yakında dolacak mı?
    ///
    /// Yenileme kapılarının hepsi yalnızca dosyanın VARLIĞINA bakıyordu. mkcert
    /// yaprakları 2 yıl 3 ay geçerli; süresi dolmuş bir `cert.pem` diskte durduğu için
    /// hiçbir kod yolu yeniden üretimi tetiklemiyor, tarayıcı da
    /// `NET::ERR_CERT_DATE_INVALID` veriyordu — üstelik uygulama sertifikayı "var"
    /// saydığı için kullanıcıya hiçbir şey söylemiyordu.
    ///
    /// BELİRLENEMİYORSA YENİLENMEZ. `openssl` bulunamaz ya da beklenmedik bir çıktı
    /// verirse `false` döner: kararsızlıkta yeniden üretmek, çalışan bir sertifikayı
    /// gereksiz yere değiştirip her düzenlemede Apache'yi yeniden yükletirdi.
    private func sslCertNeedsRenewal(_ path: String) async -> Bool {
        guard FileHelper.exists(path) else { return true }
        // `-checkend N`: sertifika N saniye içinde dolacaksa çıkış kodu 1.
        let r = await Shell.runAsync("/usr/bin/openssl",
                                     arguments: ["x509", "-in", path, "-noout",
                                                 "-checkend", "2592000"],   // 30 gün
                                     timeout: 20)
        // exitCode 0 → hâlâ geçerli · 1 → doluyor · başka her şey → belirlenemedi
        return r.exitCode == 1
    }

    private func createSSLCertificate(for domain: Domain) async -> Bool {
        guard requireBrew(forKey: "log.op.sslCreate") else { return false }

        await mkcertManager.checkStatus()
        if mkcertManager.needsSetup {
            log(key: "log.dom.mkcertCaInstalling", type: .warning)
            if !(await installMkcertCA()) { log(key: "log.dom.mkcertCaFailed", type: .warning) }
        }

        return await mkcertManager.generateCertificate(for: domain.name) { [weak self] msg, type in self?.log(msg, type: type) }
    }

    // MARK: - VHost

    /// Varsayılan localhost vhost'unu (000-localhost.conf) garanti eder.
    ///
    /// Apache, Host başlığı eşleşmeyen istekleri o porttaki İLK vhost'a düşürür.
    /// Bu dosya olmadan `localhost/phpmyadmin` gibi istekler alfabetik ilk domain
    /// vhost'una (ve onun HTTPS yönlendirmesine) gider. Yeni oluşturulduysa Apache
    /// sıcak yeniden yüklenir.
    func ensureApacheDefaultVHost(force: Bool = false) {
        guard Shell.isBrewInstalled, FileHelper.exists(PathConfig.httpdConf) else { return }
        let path = PathConfig.apacheDefaultVHost
        guard force || !FileHelper.exists(path) else { return }

        FileHelper.createDirectory(PathConfig.vhostsDir)
        let phpPort = AppSettings.load().defaultPHPVersion.port
        if FileHelper.write(VHostTemplates.apacheLocalhostDefault(phpPort: phpPort), to: path) {
            log(key: "log.dom.defaultVhostCreated", args: [path], type: .info)
            Task { await reloadApache() }
        } else {
            log(key: "log.dom.defaultVhostWriteFailed", args: [path], type: .warning)
        }
    }

    // MARK: - Config Yazım Serileştirme

    /// Config yaz/doğrula/geri-al akışı await noktaları içerdiğinden, eşzamanlı iki yazım
    /// (örn. updateDomain Task'ı + addDomain) birbirinin doğrulamasını kirletebilir ve
    /// geri-alma MASUM bir domainin dosyasını hedefleyebilirdi. MainActor üzerinde basit
    /// bir bayrak+bekleme ile yazımlar FIFO'ya yakın serileştirilir.
    private var configWriteInProgress = false

    private func withConfigWriteLock<T>(_ body: () async -> T) async -> T {
        while configWriteInProgress {
            try? await Task.sleep(nanoseconds: 50_000_000)   // 50ms — nadir yol
        }
        configWriteInProgress = true
        defer { configWriteInProgress = false }
        return await body()
    }

    /// VHost yazımının sonucu.
    /// Eskiden yalnızca `Bool` dönülüyordu ve yazım sonrası doğrulama SADECE config yazımdan
    /// önce geçerliyse yapılıyordu; başka bir vhost zaten bozukken bizim yazdığımız GEÇERSİZ
    /// config de "başarılı" sayılıyordu. Yeniden adlandırma bunu eski dosyaları silmeden önceki
    /// güvence olarak kullandığından, bu sessiz "başarılı" veri kaybına yol açabilirdi.
    enum VHostWriteResult {
        case verified     // yazıldı ve sunucu config'i doğrulandı
        case unverified   // yazıldı; config ZATEN bozuktu → bu yazım doğrulanamadı (bizim hatamız değil)
        case failed       // yazılamadı ya da bu yazım config'i bozdu (geri alındı)
    }

    @discardableResult
    private func createVHostConfig(for domain: Domain) async -> Bool {
        await createVHostConfigResult(for: domain) != .failed
    }

    private func createVHostConfigResult(for domain: Domain) async -> VHostWriteResult {
        await withConfigWriteLock { await self.createVHostConfigLocked(for: domain) }
    }

    private func createVHostConfigLocked(for domain: Domain) async -> VHostWriteResult {
        guard requireBrew(forKey: "log.op.vhostCreate") else { return .failed }

        // Apache: domain vhost'undan önce varsayılan localhost vhost'u mevcut olsun
        if domain.webServer == .apache { ensureApacheDefaultVHost() }

        // Not: vhostConfigPath nginx için sites-available kullanır — dizin de onunla tutarlı olmalı
        let configDir = domain.webServer == .nginx ? PathConfig.nginxSitesAvailableDir : PathConfig.vhostsDir
        log(key: "log.dom.vhostCreating", args: [domain.webServer.displayName], type: .info)
        FileHelper.createDirectory(configDir)

        // Yazımdan ÖNCE: mevcut (çalışan) config içeriğini sakla — geri-almada SİLMEK yerine
        // GERİ YÜKLENİR. updateDomain'de silme, çalışan domaini config'siz bırakırdı.
        let previousContent = FileHelper.readString(domain.vhostConfigPath)

        // Yazımdan ÖNCE config zaten geçerli miydi? (Değilse, bozulmayı bize atfetmeyiz.)
        let wasValid = await webServerConfigValid(domain.webServer)

        // **KAYIT HÂLÂ DURUYOR MU?** Bu denetim yazımın HEMEN ÖNÜNDE olmak zorunda.
        //
        // Çağıranlar nesli yazımın ETRAFINDA denetliyordu, içinde değil — ve yukarıdaki
        // `await` (apachectl configtest / nginx -t) saniyeler sürebiliyor. O pencerede
        // `removeDomain` baştan sona koşabilir: kaydı düşürür, vhost'u siler, SSL dizinini
        // de siler. Sonra bu yazım düşer ve artık var olmayan bir sertifikayı gösteren
        // ÖKSÜZ bir vhost yaratır. `configtest` kalıcı olarak düşer, Apache hiç başlamaz
        // ve makinedeki BÜTÜN siteler gider. Üstelik çağırandaki yazım-sonrası nesil
        // koruması hata logunu da bastırdığı için sessizce olur.
        guard domains.contains(where: { $0.id == domain.id }) else {
            log(key: "log.dom.vhostWriteAborted", args: [domain.name], type: .warning)
            return .failed
        }

        guard FileHelper.write(VHostTemplates.generate(for: domain), to: domain.vhostConfigPath) else {
            log(key: "log.dom.vhostWriteFailed", args: [domain.webServer.displayName], type: .error)
            return .failed
        }

        // Yazım sonrası doğrulama HER ZAMAN yapılır (wasValid'den bağımsız). Eskiden bu kontrol
        // yalnızca `wasValid` iken çalıştığından, ortamda zaten bozuk bir vhost varken bizim
        // yazdığımız geçersiz config hiç denetlenmeden "başarılı" dönüyordu.
        let nowValid = await webServerConfigValid(domain.webServer)

        if !nowValid {
            if wasValid {
                // Önceden geçerliydi → bozan BU yazım. Geri al.
                if let old = previousContent {
                    FileHelper.write(old, to: domain.vhostConfigPath)
                    log(key: "log.dom.vhostSyntaxBrokeRestored", args: [domain.name, domain.webServer.displayName], type: .error)
                } else {
                    FileHelper.remove(domain.vhostConfigPath)
                    log(key: "log.dom.vhostSyntaxBrokeRemoved", args: [domain.name, domain.webServer.displayName], type: .error)
                }
                return .failed
            }
            // Yazımdan ÖNCE de bozuktu: bozulmayı bize atfetmiyoruz, geri de almıyoruz —
            // ama DOĞRULANMIŞ sayamayız. Yeniden adlandırma gibi yıkıcı işlemler bu durumda
            // eski dosyaları SİLMEMELİ.
            log(key: "log.dom.vhostAlreadyInvalid", args: [domain.webServer.displayName], type: .warning)
            await writeApacheCompanionIfNeeded(for: domain)
            return .unverified
        }

        log(key: "log.dom.vhostCreated", args: [domain.webServer.displayName, domain.vhostConfigPath], type: .success)

        // Nginx domainleri için Apache "companion" vhost — bare URL (80/443) de app'e ulaşsın.
        // Aksi halde `https://domain/` Apache'ye (443) gider, orada vhost olmadığından
        // varsayılan localhost PHP sayfası servis edilir.
        await writeApacheCompanionIfNeeded(for: domain)
        return .verified
    }

    /// Apache "companion" vhost yolu (Nginx domainleri için standart port desteği).
    private func apacheCompanionPath(for domain: String) -> String {
        "\(PathConfig.vhostsDir)/\(domain).conf"
    }

    /// Mevcut Nginx domainleri için eksik Apache companion vhost'larını (bare URL desteği)
    /// tek seferlik oluşturur — bu özellikten önce eklenmiş domainler de bare URL'de çalışsın.
    /// Yazılan dosyalar configtest'i bozarsa GERİ ALINIR — bozuk companion diskte bırakılırsa
    /// sonraki TÜM Apache reload/start'ları kalıcı olarak zehirlerdi.
    private func ensureApacheCompanions() {
        guard Shell.isBrewInstalled, FileHelper.exists(PathConfig.httpdConf) else { return }
        // Eksik companion'ı olan domainleri tespit et (yazım kilit ALTINDA yapılacak)
        // Devre dışı domainler companion almaz (vhost'ları kasıtlı kaldırılmış durumda)
        let pending = domains.filter { $0.isEnabled && $0.webServer == .nginx && !FileHelper.exists(apacheCompanionPath(for: $0.name)) }
        guard !pending.isEmpty else { return }

        ensureApacheDefaultVHost()
        Task {
            // Yazım + doğrulama + geri-alma TEK kilit altında olmalı: aksi halde yazımlar
            // kilit dışında yapıldığından, eşzamanlı bir createVHostConfigLocked doğrulaması
            // yarım yazılmış companion setini görüp MASUM kendi domainini geri alabilirdi.
            await withConfigWriteLock {
                // Yazımdan ÖNCE Apache yapılandırması zaten geçerli miydi? Değilse
                // `configtest`in düşmesi companion'ların suçu DEĞİLDİR ve yazdıklarımızı
                // silmek, bozukluğu gidermeden çalışan tek şeyi de götürür.
                // `createVHostConfigLocked` ve `writeApacheCompanionIfNeeded` bu deseni
                // zaten uyguluyor; burada eksikti.
                let wasValid = await self.webServerConfigValid(.apache)
                var writtenPaths: [String] = []
                for d in pending {
                    let path = self.apacheCompanionPath(for: d.name)
                    var apacheCopy = d; apacheCopy.webServer = .apache
                    FileHelper.createDirectory(PathConfig.vhostsDir)
                    if FileHelper.write(VHostTemplates.generate(for: apacheCopy), to: path) {
                        writtenPaths.append(path)
                    }
                }
                guard !writtenPaths.isEmpty else { return }

                if await self.webServerConfigValid(.apache) {
                    self.log(key: "log.dom.companionsCreated", type: .info)
                    await self.reloadApache()
                } else if wasValid {
                    // Yalnızca ÖNCEDEN geçerliyken geri al: o zaman bozukluğu bu tur
                    // getirmiştir. Config baştan bozuksa yazdıklarımızı silmek onu
                    // düzeltmez, yalnızca companion'ları da kaybettirir.
                    for p in writtenPaths { FileHelper.remove(p) }
                    self.log(key: "log.dom.companionsRolledBack", args: ["\(writtenPaths.count)"], type: .warning)
                } else {
                    self.log(key: "log.dom.companionsKeptConfigWasBroken", type: .warning)
                }
            }
        }
    }

    /// Nginx domainleri için Apache reverse-proxy/PHP companion vhost'u yazar — böylece
    /// bare URL (Apache 80/443) domainin app'ine/kök dizinine ulaşır. Apache domaini de
    /// (Nginx'e ek olarak) servis eder; yerel geliştirmede zararsız, bare URL çalışır.
    private func writeApacheCompanionIfNeeded(for domain: Domain) async {
        guard domain.webServer == .nginx else { return }   // Apache domainleri zaten 443'te
        ensureApacheDefaultVHost()
        FileHelper.createDirectory(PathConfig.vhostsDir)

        var apacheCopy = domain
        apacheCopy.webServer = .apache
        let config = VHostTemplates.generate(for: apacheCopy)   // apacheProxy / apachePHP / apacheStatic
        let path   = apacheCompanionPath(for: domain.name)

        let previousContent = FileHelper.readString(path)   // güncelleme ise eskiyi sakla
        let wasValid = await webServerConfigValid(.apache)
        guard FileHelper.write(config, to: path) else {
            log(key: "log.dom.companionWriteFailed", args: [path], type: .warning); return
        }
        // Apache sözdizimini bozduysa geri al (Nginx domaini yine de çalışır) —
        // güncelleme ise ÖNCEKİ çalışan içeriği geri yükle, silme.
        if wasValid, !(await webServerConfigValid(.apache)) {
            if let old = previousContent {
                FileHelper.write(old, to: path)
                log(key: "log.dom.companionUpdateReverted", type: .warning)
            } else {
                FileHelper.remove(path)
                log(key: "log.dom.companionReverted", type: .warning)
            }
            return
        }
        log(key: "log.dom.companionCreated", args: [domain.name], type: .info)
        await reloadApache()
    }

    /// Web sunucusu config sözdizimi geçerli mi? (apachectl configtest / nginx -t)
    private func webServerConfigValid(_ ws: WebServer) async -> Bool {
        switch ws {
        case .apache:
            let r = await Shell.bashAsync("\(Shell.brewPrefix)/bin/apachectl configtest 2>&1")
            return r.isSuccess || r.output.contains("Syntax OK")
        case .nginx:
            let r = await Shell.bashAsync("\(Shell.brewPrefix)/bin/nginx -t 2>&1")
            return r.isSuccess || r.output.lowercased().contains("syntax is ok")
        }
    }

    // MARK: - Web Server Reload

    /// Servis çalışıyorsa config'i sıcak yükler (durdurma/başlatma yok).
    /// Apache: apachectl configtest && apachectl graceful
    /// Nginx:  nginx -s reload
    /// Servis durmuşsa dokunulmaz — zaten başlatılınca yeni config'i okuyacak.
    /// async: apachectl/nginx çağrıları @MainActor'ı bloke etmesin (UI donması önlenir).
    /// Domain'in bağlı web sunucusunu (nginx/apache) yeniden yükler.
    /// - Parameter autoStart: true ise sunucu DURMUŞSA önce otomatik başlatır (domain ekleme/
    ///   güncelleme/başlatma yolları için). Silme yolunda false — durmuş sunucuyu ayağa kaldırmak
    ///   gereksiz. Nginx domainleri Apache companion vhost'una da bağlı olduğundan, autoStart'ta
    ///   Apache da (kuruluysa) çalışır duruma getirilir ki bare URL (80/443) de erişilebilsin.
    private func reloadWebServer(for domain: Domain, autoStart: Bool = false) async {
        if autoStart {
            _ = await ensureServiceRunning?(domain.webServer.brewServiceID)
            // Nginx domaini: bare URL için Apache companion da çalışmalı (kuruluysa)
            if domain.webServer == .nginx, FileHelper.exists(PathConfig.httpdConf) {
                _ = await ensureServiceRunning?(WebServer.apache.brewServiceID)
            }
        }
        switch domain.webServer {
        case .apache: await reloadApache()
        case .nginx:
            await reloadNginx()
            // Nginx domaini için Apache companion'ı da yenile (bare URL 80/443)
            if FileHelper.exists(PathConfig.httpdConf) { await reloadApache() }
        }
    }

    private func reloadApache() async {
        let apachectl = "\(Shell.brewPrefix)/bin/apachectl"
        guard await Shell.isProcessAlive("httpd") else {
            log(key: "log.dom.apacheNotRunning", type: .info)
            return
        }
        log(key: "log.dom.apacheReloading", type: .command)
        let test = await Shell.bashAsync("\(apachectl) configtest 2>&1")
        guard test.isSuccess || test.output.contains("Syntax OK") else {
            log(key: "log.dom.apacheConfigError", args: [test.output], type: .error)
            return
        }
        let r = await Shell.bashAsync("\(apachectl) graceful 2>&1")
        if r.isSuccess {
            log(key: "log.dom.apacheReloaded", type: .success)
        } else {
            log(key: "log.dom.apacheReloadFailed", args: [r.output], type: .error)
        }
    }

    private func reloadNginx() async {
        let nginx = "\(Shell.brewPrefix)/bin/nginx"
        guard await Shell.isProcessAlive("nginx") else {
            log(key: "log.dom.nginxNotRunning", type: .info)
            return
        }
        log(key: "log.dom.nginxReloading", type: .command)
        let r = await Shell.bashAsync("\(nginx) -s reload 2>&1")
        if r.isSuccess {
            log(key: "log.dom.nginxReloaded", type: .success)
        } else {
            log(key: "log.dom.nginxReloadFailed", args: [r.output], type: .error)
        }
    }

    // MARK: - Hosts File

    /// "/etc/hosts'ta bu domain için ETKİN bir 127.0.0.1 eşlemesi var mı?" kontrolünü yapan
    /// shell komutu (çıkış kodu 0 = var). `missingHostsEntries()` ile AYNI ölçüt:
    ///   • yorum satırları atlanır,
    ///   • ilk alan tam olarak 127.0.0.1 olmalı,
    ///   • ad bir ALANIN TAMAMI olarak eşleşmeli.
    /// Eski `grep -qE` deseni domaini HERHANGİ bir satırda eşleştiriyordu; bu yüzden
    /// `192.168.64.10 foo.local` (başka IP) veya `# 127.0.0.1 foo.local` (yorum) varken
    /// gerçek giriş hiç eklenmez, domain localhost'a çözülmez ve onarım "başarılı" derdi.
    private func hostsHasEntryCmd(_ domain: String) -> String {
        "awk -v d=\(Shell.quote(domain)) '/^[[:space:]]*#/ {next} $1==\"127.0.0.1\" {for(i=2;i<=NF;i++) if($i==d){f=1;exit}} END{exit(f?0:1)}' /etc/hosts"
    }

    /// `/etc/hosts` newline ile bitmiyorsa bir newline ekler.
    ///
    /// `echo … >>` yalnızca SONA newline koyar, başa koymaz. Dosya newline'sız
    /// bitiyorsa yeni girdi mevcut son satırın kuyruğuna yapışır — ör.
    /// `255.255.255.255 broadcasthost127.0.0.1\tfoo.test`. Sonuç iki katlı: yeni ad
    /// çözülmez VE yapıştığı satır kalıcı olarak bozulur.
    ///
    /// `$(…)` sondaki newline'ları kırptığı için `tail -c 1` çıktısı BOŞSA son bayt
    /// zaten newline'dır.
    static let hostsEnsureTrailingNewline =
        "{ [ -s /etc/hosts ] && [ -n \"$(tail -c 1 /etc/hosts)\" ] && printf '\\n' >> /etc/hosts; } || true"

    /// Ekleme zincirini newline garantisiyle sarar — SAF, testten geçer.
    ///
    /// Sarmalayıcı ayrı bir işlev, çünkü ekleme yapan İKİ yol var (`addToHosts` ve
    /// `repairHosts`) ve garantiyi birinde unutmak sessizce eski hataya dönerdi.
    static func hostsCommand(appending chain: String) -> String {
        "\(hostsEnsureTrailingNewline); \(chain)"
    }

    @discardableResult
    private func addToHosts(_ domain: String) async -> Bool {
        log(key: "log.dom.hostsAdding", type: .info)
        // Tırnaklar elle yazılmaz: root ile çalışan komutta ad Shell.quote ile sarılır
        // (savunma katmanı — adlar yüklemede zaten doğrulanıyor).
        let entry = Shell.quote("127.0.0.1\t\(domain)")
        let cmd = Self.hostsCommand(
            appending: "\(hostsHasEntryCmd(domain)) || echo \(entry) >> /etc/hosts")
        return await hostsUpdate(cmd, successKey: "log.dom.hostsUpdated", failKey: "log.dom.hostsUpdateFailed")
    }

    // MARK: - Hosts Onarımı

    /// ETKİN domainlerden hangilerinin /etc/hosts girişi eksik, döner (senkron dosya okuma).
    /// Kullanıcı hosts'u elle düzenlediyse veya başka araç sildiyse tespit için.
    func missingHostsEntries() -> [String] {
        guard let hosts = FileHelper.readString("/etc/hosts") else { return [] }
        let lines = hosts.components(separatedBy: .newlines)
        return domains.filter { $0.isEnabled }.map(\.name).filter { name in
            // 127.0.0.1  name  satırı var mı? (yorum olmayan, tam kelime)
            !lines.contains { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("#") else { return false }
                let tokens = t.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                // hostsHasEntryCmd (awk) ile AYNI ölçüt: ilk alan tam 127.0.0.1 olmalı
                return tokens.first == "127.0.0.1" && tokens.dropFirst().contains(name)
            }
        }
    }

    /// Eksik hosts girişlerinin tümünü TEK sudo işleminde ekler (onarım).
    /// Her domain için ayrı ayrı şifre sormaz.
    @discardableResult
    func repairHosts() async -> Bool {
        let missing = missingHostsEntries()
        guard !missing.isEmpty else {
            log(key: "log.dom.hostsAllPresent", type: .info)
            return true
        }
        log(key: "log.dom.hostsRepairing", args: ["\(missing.count)", missing.joined(separator: ", ")], type: .command)
        // Tek komutta hepsini ekle — her biri için "zaten var mı" kontrolüyle (idempotent)
        let appends = missing.map { name -> String in
            let entry = Shell.quote("127.0.0.1\t\(name)")
            return "\(hostsHasEntryCmd(name)) || echo \(entry) >> /etc/hosts"
        }.joined(separator: "; ")
        // Zincirin İLK `echo`su da aynı tuzağa düşer: dosya newline'sız bitiyorsa ilk
        // girdi son satırın kuyruğuna yapışır ve o satırı da bozar.
        let cmd = Self.hostsCommand(appending: appends)
        return await hostsUpdate(cmd, successKey: "log.dom.hostsRepaired",
                                 successArgs: ["\(missing.count)"], failKey: "log.dom.hostsRepairFailed")
    }

    @discardableResult
    private func removeFromHosts(_ domain: String) async -> Bool {
        // SAVUNMA: sistem adları ASLA /etc/hosts'tan silinmez. Bu komut root ile `sed -i`
        // çalıştırır; 'localhost' gibi bir ad buraya sızarsa macOS'un stok
        // `127.0.0.1 localhost` satırı kalıcı olarak silinir ve sistem genelinde
        // localhost çözümlemesi bozulur. (Sınırda ekleme/yeniden adlandırma zaten
        // reddediliyor; bu, ESKİ kayıtlar ve gelecekteki çağrı yolları için ağ.)
        guard !Self.isReservedDomainName(domain) else { return true }
        log(key: "log.dom.hostsRemoving", type: .info)
        // Domain adındaki noktaları escape ederek regex injection'ı önle
        let escapedDomain = domain.replacingOccurrences(of: ".", with: "\\.")
        let script = Shell.quote("/^127\\.0\\.0\\.1[[:space:]]\\{1,\\}\(escapedDomain)$/d")
        let cmd = "sed -i '' \(script) /etc/hosts"
        return await hostsUpdate(cmd, successKey: "log.dom.hostsUpdated", failKey: "log.dom.hostsUpdateFailed")
    }

    /// /etc/hosts için yönetici onaylı sudo — iptal edilirse 2 kez yeniden dener (toplam 3 deneme).
    /// NOT: osascript'in yönetici istemi PAROLA sorar; Touch ID sunmaz.
    /// - Returns: İşlem başarılıysa `true`; izin iptal edildi veya hata olduysa `false`.
    ///   Çağıran taraf `false` durumunda GERİ ALMA YAPMAZ — yarım kalan işi silmek yerine korur.
    @discardableResult
    private func hostsUpdate(_ shellCmd: String, successKey: String, successArgs: [String] = [],
                             failKey: String) async -> Bool {
        for attempt in 1...3 {
            let r = await Shell.sudoAuthorized(shellCmd)
            if r.isUserCancelled {
                if attempt < 3 {
                    log(key: "log.dom.hostsRetry", args: ["\(attempt)"], type: .warning)
                } else {
                    log(key: "log.dom.hostsCancelled", type: .warning)
                }
                continue
            }
            if r.isSuccess {
                log(key: successKey, args: successArgs, type: .success)
            } else {
                log(key: failKey, type: .error)
                // Shell stderr'i ham geçer — çevrilebilir bir metin değildir
                if !r.error.isEmpty { log(r.error, type: .error) }
            }
            return r.isSuccess
        }
        return false
    }

    // MARK: - Actions

    /// Domaine ait URL'yi domain.webServer'a göre açar.
    func openInBrowser(_ domain: Domain) {
        if let url = URL(string: domain.url) { NSWorkspace.shared.open(url) }
    }

    /// Domain URL'sini panoya kopyalar.
    func copyURL(_ domain: Domain) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(domain.url, forType: .string)
        log(key: "log.dom.urlCopied", args: [domain.url], type: .info)
    }

    /// Domain'e gerçek bir HTTP isteği atarak uçtan uca sağlık testi yapar —
    /// "servis çalışıyor" göstergesinden farklı olarak sitenin GERÇEKTEN yanıt verdiğini doğrular.
    /// Sonuç konsola ve alert olarak raporlanır.
    func healthCheck(_ domain: Domain) {
        Task {
            let url = domain.url
            log(key: "log.dom.healthCheckStart", args: [domain.name, url], type: .command)
            // -k: yerel mkcert sertifikası; -m 6: 6sn zaman aşımı; -L: yönlendirmeleri izle
            let r = await Shell.bashAsync(
                "curl -skL -o /dev/null -m 6 -w '%{http_code}' \(Shell.quote(url)) 2>/dev/null"
            )
            let code = r.output.trimmingCharacters(in: .whitespacesAndNewlines)

            let title: String
            let message: String
            if let c = Int(code), (200..<400).contains(c) {
                log(key: "log.dom.healthOk", args: [domain.name, code], type: .success)
                title = String(format: Localizer.shared.t("dom.health.ok.title"), domain.name)
                message = String(format: Localizer.shared.t("dom.health.ok.msg"), code, url)
            } else if code == "000" || code.isEmpty {
                log(key: "log.dom.healthUnreachable", args: [domain.name], type: .error)
                title = String(format: Localizer.shared.t("dom.health.unreachable.title"), domain.name)
                message = String(format: Localizer.shared.t("dom.health.unreachable.msg"), domain.webServer.displayName)
            } else if code == "502" || code == "503" || code == "504" {
                log(key: "log.dom.healthBackendDown", args: [domain.name, code], type: .warning)
                title = String(format: Localizer.shared.t("dom.health.backendDown.title"), code)
                message = Localizer.shared.t("dom.health.backendDown.msg")
            } else {
                log(key: "log.dom.healthUnexpected", args: [domain.name, code], type: .warning)
                title = String(format: Localizer.shared.t("dom.health.unexpected.title"), domain.name, code)
                message = String(format: Localizer.shared.t("dom.health.unexpected.msg"), code, url)
            }
            activeAlert = AppAlert(title: title, message: message)
        }
    }

    /// Domaine ait URL'yi belirtilen web sunucusu üzerinden açar.
    func openInBrowser(_ domain: Domain, via server: WebServer, httpPort: Int? = nil, httpsPort: Int? = nil) {
        let scheme  = domain.sslEnabled ? "https" : "http"
        let port    = domain.sslEnabled ? (httpsPort ?? server.httpsPort) : (httpPort ?? server.httpPort)
        let isStd   = (domain.sslEnabled && port == 443) || (!domain.sslEnabled && port == 80)
        let portStr = isStd ? "" : ":\(port)"
        if let url = URL(string: "\(scheme)://\(domain.name)\(portStr)") {
            NSWorkspace.shared.open(url)
        }
    }

    func openInFinder(_ domain: Domain) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: domain.sitePath)
    }

    func openConfig(_ domain: Domain) {
        guard FileHelper.exists(domain.vhostConfigPath) else { log(key: "log.dom.configNotFound", type: .warning); return }
        NSWorkspace.shared.open(URL(fileURLWithPath: domain.vhostConfigPath))
    }

    func openStartScript(_ domain: Domain) {
        let path = NativeProcessManager.startScriptPath(for: domain)
        guard FileHelper.exists(path) else {
            log(key: "log.dom.startScriptNotFound", args: [path], type: .warning); return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Log dosyası oku — error ve access loglar için ortak metod
    private func readLog(path: String, label: String) -> String {
        guard FileHelper.exists(path) else {
            return "Henüz \(label) oluşmamış.\nYol: \(path)"
        }
        return FileHelper.readString(path) ?? "\(label) okunamadı.\nYol: \(path)"
    }

    func readErrorLog(for domain: Domain) -> String {
        readLog(path: domain.errorLogPath, label: "error log")
    }

    func readAccessLog(for domain: Domain) -> String {
        readLog(path: domain.accessLogPath, label: "access log")
    }

    func openErrorLog(_ domain: Domain) {
        guard FileHelper.exists(domain.errorLogPath) else { log(key: "log.dom.errorLogNotFound", type: .warning); return }
        NSWorkspace.shared.open(URL(fileURLWithPath: domain.errorLogPath))
    }

    func openAccessLog(_ domain: Domain) {
        guard FileHelper.exists(domain.accessLogPath) else { log(key: "log.dom.accessLogNotFound", type: .warning); return }
        NSWorkspace.shared.open(URL(fileURLWithPath: domain.accessLogPath))
    }

    /// Domain çalışma durumlarını günceller.
    ///
    /// - Parameters:
    ///   - apacheRunning: Apache durumu dışarıdan biliniyorsa geçilir (süreç kontrolü atlanır).
    ///     `nil` → kendi içinde `Shell.isProcessAlive("httpd")` ile kontrol eder.
    ///   - nginxRunning: Nginx durumu dışarıdan biliniyorsa geçilir (süreç kontrolü atlanır).
    ///     `nil` → kendi içinde `Shell.isProcessAlive("nginx")` ile kontrol eder.
    func refreshStatus(apacheRunning: Bool? = nil, nginxRunning: Bool? = nil) {
        guard Shell.isBrewInstalled else { return }
        Task {
            // Dışarıdan verilmişse pgrep çalıştırma — ServiceManager zaten nc ile kontrol etti
            let apache = if let a = apacheRunning { a } else {
                await Shell.isProcessAlive("httpd")
            }
            let nginx = if let n = nginxRunning { n } else {
                await Shell.isProcessAlive("nginx")
            }

            // Değer-tipi anlık görüntü üzerinde çalış — await sırasında kullanıcı domain
            // silerse pozisyonel index (domains[i]) sınır dışına çıkıp çökerdi. Durumlar
            // id ile hesaplanıp id ile geri yazılır; silinen domain sessizce atlanır.
            let snapshot = domains
            var statuses: [UUID: Bool] = [:]
            for d in snapshot {
                switch d.platform {
                case .python, .nodejs, .dotnet:
                    statuses[d.id] = await NativeProcessManager.isRunning(domain: d)
                default:
                    // Devre dışı bırakılmış domainin vhost'u ve /etc/hosts girişi
                    // SİLİNMİŞTİR — web sunucusu ayakta olsa da bu site servis
                    // edilmez. Sunucunun durumunu domainin durumu gibi göstermek
                    // satırda yeşil "çalışıyor" noktası çizip kullanıcıyı yanıltıyordu.
                    // App platformları bilerek dışarıda: orada `isRunning` gerçek bir
                    // süreç denetimidir ve Başlat/Durdur düğmesini sürer.
                    statuses[d.id] = d.isEnabled && (d.webServer == .nginx ? nginx : apache)
                }
            }
            for (id, running) in statuses {
                if let idx = domains.firstIndex(where: { $0.id == id }) {
                    domains[idx].isRunning = running
                }
            }
        }
    }

    // MARK: - Build / Run

    /// Build komutunu site klasöründe çalıştırır, çıktıyı akış halinde döndürür.
    func runBuildCommand(for domain: Domain, progress: @escaping (String) -> Void) async -> Bool {
        guard let cmd = domain.buildCommand, !cmd.isEmpty else {
            progress("⚠️ Build komutu tanımlı değil\n"); return false
        }
        log(key: "log.dom.buildStarting", args: [cmd], type: .command)
        progress("$ \(cmd)\n")

        // Komut KULLANICIDAN geliyor. `npm run dev` / `vite` gibi hiç bitmeyen bir komut
        // yazılırsa süresiz beklemek bu task'ı kalıcı olarak asardı (build paneli sonsuza
        // kadar "çalışıyor" kalır). 10 dakika gerçek bir derleme için fazlasıyla yeterli.
        let r = await Shell.streamBash(
            "cd \(Shell.quote(domain.sitePath)) && \(cmd) 2>&1",
            timeout: 600
        ) { line in
            progress(line + "\n")
        }

        if r.isSuccess {
            log(key: "log.dom.buildDone", args: [domain.name], type: .success)
            progress("\n✅ Tamamlandı\n")
        } else {
            log(key: "log.dom.buildFailed", args: [r.error], type: .error)
            progress("\n❌ Hata (kod \(r.exitCode)): \(r.error)\n")
        }
        return r.isSuccess
    }

    /// Node.js: package.json var ama node_modules yoksa bağımlılıkları otomatik kurar.
    /// Python'daki ensureEnvironment / .NET'teki ensureDotnetProject ile simetrik —
    /// ilk başlatmada "Cannot find module" çökmesini önler. node_modules varsa hızla geçer.
    private func ensureNodeModules(domain: Domain) async {
        let site = domain.sitePath
        guard FileHelper.exists("\(site)/package.json"),
              !FileHelper.exists("\(site)/node_modules") else { return }

        log(key: "log.dom.npmInstalling", type: .command)
        // Domain'in Node sürümünün bin dizini önde olsun (doğru npm kullanılsın)
        let nodeBin = domain.nodeVersion?.binDir ?? "\(PathConfig.brewBin)"
        let r = await Shell.bashAsync(
            "cd \(Shell.quote(site)) && PATH=\(Shell.quote(nodeBin)):\"$PATH\" npm install --no-audit --no-fund 2>&1"
        )
        if r.isSuccess {
            log(key: "log.dom.npmInstalled", type: .success)
        } else {
            // Başlatmayı engelleme — npm hatası app.log'da da görünecektir
            let tail = r.output.components(separatedBy: "\n").suffix(4).joined(separator: " | ")
            log(key: "log.dom.npmInstallFailed", args: [tail], type: .warning)
        }
    }

    // MARK: - Python Süreç Yönetimi

    /// Python uygulamasını başlatır.
    /// 1. `ensureEnvironment`: venv yoksa oluşturur, paketleri kurar, Django projesi başlatır.
    /// 2. `NativeProcessManager.start`: `start.sh` ile nohup başlatma.
    func startPythonApp(domain: Domain) async {
        log(key: "log.dom.appStarting", args: [domain.name], type: .command)
        await ensureDependencies(for: domain)

        if PythonProcessManager.detectVenvBin(at: domain.sitePath) == nil {
            log(key: "log.dom.venvMissing", type: .info)
        }

        let ready = await PythonProcessManager.ensureEnvironment(for: domain)
        guard ready else {
            log(key: "log.dom.appStartFailedEnv", args: [domain.name], type: .error)
            refreshStatus()
            return
        }

        let ok = await NativeProcessManager.start(domain: domain)
        if ok {
            log(key: "log.dom.appStarted", args: [domain.name], type: .success)
            // Uygulama ayakta — bağlı web sunucusu (proxy) durmuşsa otomatik başlat + reload
            await reloadWebServer(for: domain, autoStart: true)
        } else {
            log(key: "log.dom.appStartFailed", args: [domain.name], type: .error)
            activeAlert = await buildStartAlert(for: domain)
        }
        refreshStatus()
    }

    /// Çalışan Python uygulamasını durdurur.
    func stopPythonApp(domain: Domain) async {
        log(key: "log.dom.appStopping", args: [domain.name], type: .command)
        await NativeProcessManager.stop(domain: domain)
        log(key: "log.dom.appStopped", args: [domain.name], type: .info)
        refreshStatus()
    }

    // MARK: - .NET Proje Yönetimi

    /// Site dizininde .csproj yoksa `dotnet new webapi` ile yeni proje oluşturur.
    /// Mevcut .csproj yanlış framework hedefliyorsa `<TargetFramework>` satırını düzeltir.
    /// - Returns: `true` → başlatmaya hazır, `false` → oluşturma/düzeltme başarısız
    /// Kurulu .NET SDK'larına göre kullanılabilir (dotnetBin, frameworkMoniker) çözer.
    /// İstenen sürümün SDK'sı yoksa kurulu EN YÜKSEK sürüme düşer — `dotnet new` "net8.0 geçerli
    /// değer değil" hatasıyla patlamak yerine kurulu sürümle proje üretilir.
    /// - Returns: bin/moniker; `installed=false` → hiç SDK yok (kurulum gerekli).
    private func resolveDotnetTarget(for domain: Domain) async -> (bin: String, moniker: String, installed: Bool, fellBack: Bool) {
        let requestedMajor = Int(domain.dotnetVersion?.majorVersion ?? "9") ?? 9

        // 1) İstenen sürümün SDK'sı kurulu mu? (opt/dotnet@X)
        if let v = domain.dotnetVersion, FileHelper.exists(v.versionedBin) {
            return (v.versionedBin, v.frameworkMoniker, true, false)
        }

        // 2) Global/mevcut dotnet — hangi major SDK'lar kurulu?
        let bin = PathConfig.dotnet
        guard FileHelper.exists(bin) else {
            return (bin, "net\(requestedMajor).0", false, false)
        }
        let list = await Shell.bashAsync("\(Shell.quote(bin)) --list-sdks 2>/dev/null")
        let majors = Set(list.output.components(separatedBy: .newlines).compactMap { line -> Int? in
            Int(line.trimmingCharacters(in: .whitespaces).components(separatedBy: ".").first ?? "")
        })
        guard !majors.isEmpty else {
            return (bin, "net\(requestedMajor).0", false, false)
        }
        // İstenen major kuruluysa onu; değilse en yükseği kullan (fallback)
        if majors.contains(requestedMajor) {
            return (bin, "net\(requestedMajor).0", true, false)
        }
        let best = majors.max()!
        return (bin, "net\(best).0", true, true)
    }

    private func ensureDotnetProject(domain: Domain) async -> Bool {
        let sitePath = domain.sitePath

        // Kurulu SDK'ya göre gerçek framework ve binary'yi çöz (net8.0 istenip 9 kuruluysa 9'a düşer)
        let target = await resolveDotnetTarget(for: domain)
        guard target.installed else {
            log(key: "log.dom.dotnetSdkMissing", type: .error)
            activeAlert = AppAlert(title: Localizer.shared.t("dom.alert.dotnetMissing.title"),
                                   message: String(format: Localizer.shared.t("dom.alert.dotnetMissing.msg"), domain.name))
            return false
        }
        let frameworkMoniker = target.moniker
        let dotnetBin        = target.bin
        if target.fellBack {
            log(key: "log.dom.dotnetVersionFallback", args: [domain.dotnetVersion?.rawValue ?? "?", frameworkMoniker], type: .warning)
        }

        // ── .csproj mevcut mu? ────────────────────────────────────────────
        let csprojFind = await Shell.bashAsync(
            "ls \(Shell.quote(sitePath))/*.csproj 2>/dev/null | head -1"
        )
        if csprojFind.hasOutput {
            let csprojPath = csprojFind.output.trimmingCharacters(in: .whitespacesAndNewlines)

            // Doğru framework mi?
            let correct = await Shell.bashAsync(
                "grep -q '<TargetFramework>\(frameworkMoniker)</TargetFramework>' \(Shell.quote(csprojPath)) 2>/dev/null"
            ).isSuccess

            if correct {
                log(key: "log.dom.dotnetProjectExists", args: [frameworkMoniker], type: .info)
                // Mevcut projeye de eksikse kök info sayfası + UTF-8 + reverse-proxy yamalarını
                // uygula (idempotent — zaten varsa dokunmaz). Böylece eski projeler de düzelir.
                patchDotnetProgramCs(at: sitePath, moniker: frameworkMoniker, domain: domain)
                return true
            }

            // Yanlış framework — <TargetFramework> satırını güncelle (kullanıcı koduna dokunma)
            log(key: "log.dom.csprojWrongFramework", args: [frameworkMoniker], type: .warning)
            if var content = FileHelper.readString(csprojPath),
               let range = content.range(
                   of: #"<TargetFramework>net[^<]+</TargetFramework>"#,
                   options: .regularExpression) {
                content.replaceSubrange(
                    range,
                    with: "<TargetFramework>\(frameworkMoniker)</TargetFramework>"
                )
                if FileHelper.write(content, to: csprojPath) {
                    log(key: "log.dom.csprojUpdated", args: [frameworkMoniker], type: .success)
                    // Eski bin/obj artefaktları silinsin — yanlış framework ile derlenmişler
                    _ = await Shell.bashAsync(
                        "rm -rf \(Shell.quote(sitePath + "/bin")) \(Shell.quote(sitePath + "/obj")) 2>/dev/null"
                    )
                    patchDotnetProgramCs(at: sitePath, moniker: frameworkMoniker, domain: domain)
                    writeConfigFiles(for: domain)
                    // Framework değişti — bin/obj silindi; bir kez yeniden derle
                    await buildDotnetProject(sitePath: sitePath, dotnetBin: dotnetBin)
                    return true
                }
            }
            log(key: "log.dom.csprojUpdateFailed", type: .error)
            return false
        }

        // ── Proje yok — yeni oluştur ─────────────────────────────────────
        log(key: "log.dom.dotnetProjectCreating", args: [frameworkMoniker], type: .info)

        // Proje adı: domain adından geçerli bir C# identifier üret
        let projectName = domain.name
            .components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: "_")).inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
            .prefix(1).uppercased()
            + domain.name
                .components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: "_")).inverted)
                .filter { !$0.isEmpty }
                .joined(separator: "_")
                .dropFirst()

        let r = await Shell.bashAsync(
            "\(Shell.quote(dotnetBin)) new webapi --name \(Shell.quote(projectName)) --output \(Shell.quote(sitePath)) --framework \(Shell.quote(frameworkMoniker)) --force 2>&1"
        )

        if r.isSuccess {
            log(key: "log.dom.dotnetProjectCreated", args: [projectName, frameworkMoniker], type: .success)
            // Nginx reverse proxy uyumluluğu + kök info sayfası + UTF-8
            patchDotnetProgramCs(at: sitePath, moniker: frameworkMoniker, domain: domain)
            writeConfigFiles(for: domain)
            // İşlem sırası: kurulum → şablon → BİR KEZ DERLE → (çağıran) başlat
            await buildDotnetProject(sitePath: sitePath, dotnetBin: dotnetBin)
            return true
        } else {
            log(key: "log.dom.dotnetProjectCreateFailed", args: [r.error.isEmpty ? r.output : r.error], type: .error)
            return false
        }
    }

    /// .NET projesini bir kez derler (kurulum/şablon sonrası). `dotnet run` ilk çalıştırmada
    /// zaten derler; burada önden derlemek hataları erken yakalar ve ilk başlatmayı hızlandırır.
    /// Derleme başarısızsa uyarır ama akışı durdurmaz — `dotnet run` hatayı yine gösterecektir.
    private func buildDotnetProject(sitePath: String, dotnetBin: String) async {
        log(key: "log.dom.dotnetBuilding", type: .command)
        let r = await Shell.bashAsync(
            "cd \(Shell.quote(sitePath)) && \(Shell.quote(dotnetBin)) build -c Debug --nologo 2>&1"
        )
        if r.isSuccess {
            log(key: "log.dom.dotnetBuildOk", type: .success)
        } else {
            // Son birkaç anlamlı satırı göster (tüm MSBuild çıktısı konsolu boğmasın)
            let tail = r.output.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .suffix(6).joined(separator: "\n")
            log(key: "log.dom.dotnetBuildWarned", args: [tail], type: .warning)
        }
    }

    /// `dotnet new` çıktısını yapılandırır (idempotent — her adım zaten varsa atlanır):
    ///   • `using Microsoft.AspNetCore.HttpOverrides;` ekler
    ///   • `app.UseForwardedHeaders(...)` ekler (nginx/Apache X-Forwarded-* başlıkları)
    ///   • `app.UseHttpsRedirection();` kaldırır (HTTPS'i web sunucusu halleder)
    ///   • Statik dosya sunumu ekler → `wwwroot/index.html` kök `/` info sayfası olur
    ///   • Kısa `/info` JSON ucu ekler (çalışma zamanı sürümü)
    ///   • Konsol çıktısına UTF-8 kodlaması ayarlar
    /// Not: Büyük HTML C# ham-string girinti kuralları kırılgan olduğundan info sayfası
    /// ayrı statik dosyaya (wwwroot/index.html) yazılır — kaçış/girinti derdi olmaz.
    private func patchDotnetProgramCs(at sitePath: String, moniker: String, domain: Domain) {
        // İnfo sayfasını statik dosya olarak yaz (Türkçe + UTF-8, tam serbest HTML)
        writeDotnetInfoPage(at: sitePath, moniker: moniker, domain: domain)

        let programPath = "\(sitePath)/Program.cs"
        guard var src = FileHelper.readString(programPath) else { return }

        var changed = false

        // 1. using Microsoft.AspNetCore.HttpOverrides ekle (üste)
        if !src.contains("HttpOverrides") {
            src = "using Microsoft.AspNetCore.HttpOverrides;\n" + src
            changed = true
        }

        // 2. UseHttpsRedirection'ı kaldır (HTTPS yönlendirmesini web sunucusu halleder)
        if src.contains("app.UseHttpsRedirection();") {
            src = src.replacingOccurrences(
                of: "\napp.UseHttpsRedirection();\n",
                with: "\n// HTTPS yönlendirmesi web sunucusu (nginx/Apache) tarafından yapılıyor.\n"
            )
            changed = true
        }

        // 3. UseForwardedHeaders + UTF-8 — app.Build()'dan hemen sonra
        if !src.contains("UseForwardedHeaders") {
            let marker = "var app = builder.Build();"
            let block = """
            \(marker)

            // Türkçe karakterler için konsol çıktısı UTF-8
            System.Console.OutputEncoding = System.Text.Encoding.UTF8;

            // Reverse proxy (nginx/Apache): X-Forwarded-For / X-Forwarded-Proto
            app.UseForwardedHeaders(new ForwardedHeadersOptions
            {
                ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto
            });
            """
            src = src.replacingOccurrences(of: marker, with: block)
            changed = true
        }

        // 3b. Statik dosya sunumu — AYRI adım (eski projelerde UseForwardedHeaders zaten olabilir;
        //     o durumda 3. adım atlanır ama statik sunum yine eklenmeli). Idempotent.
        //     Build() satırından hemen sonra eklenir (deterministik anchor). Statik dosyaların
        //     forwarded-header'lardan önce sunulması işlevsel olarak sorunsuzdur.
        if !src.contains("UseStaticFiles") {
            let anchor = "var app = builder.Build();"
            let insertion = """
            \(anchor)

            // wwwroot/index.html kök "/" adresinde info sayfası olarak sunulur
            app.UseDefaultFiles();
            app.UseStaticFiles();
            """
            if let range = src.range(of: anchor) {
                src.replaceSubrange(range, with: insertion)
                changed = true
            }
        }

        // 4. Kısa /info JSON ucu — app.Run()'dan hemen önce (idempotent)
        if !src.contains("MapGet(\"/info\"") {
            let infoRoute = """
            // Sürüm bilgisi (JSON) — programatik erişim için
            app.MapGet("/info", () => Results.Json(new
            {
                domain = "\(domain.name)",
                runtime = System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription,
                targetFramework = "\(moniker)",
                environment = app.Environment.EnvironmentName
            }));

            app.Run();
            """
            if let range = src.range(of: "app.Run();") {
                src.replaceSubrange(range, with: infoRoute)
                changed = true
            }
        }

        if changed, FileHelper.write(src, to: programPath) {
            log(key: "log.dom.programCsPatched", type: .success)
        }
    }

    /// ASP.NET projesi için `wwwroot/index.html` info sayfasını yazar (idempotent — varsa dokunmaz).
    /// Tam serbest HTML: Türkçe karakterler + UTF-8 + hedef framework bilgisi. Kök `/` adresinde sunulur.
    private func writeDotnetInfoPage(at sitePath: String, moniker: String, domain: Domain) {
        let wwwroot   = "\(sitePath)/wwwroot"
        let indexPath = "\(wwwroot)/index.html"
        guard !FileHelper.exists(indexPath) else { return }   // kullanıcı sayfasını ezme
        FileHelper.createDirectory(wwwroot)
        let html = """
        <!doctype html>
        <html lang="tr">
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(domain.name) — ASP.NET Core</title>
        </head>
        <body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;max-width:680px;margin:8vh auto;padding:0 24px;color:#1d1d1f;line-height:1.6">
            <h1 style="font-size:2em;margin-bottom:4px">🟣 ASP.NET Core Çalışıyor</h1>
            <p style="color:#6e6e73;margin-top:0"><strong>\(domain.name)</strong> hizmeti aktif ve UTF-8 destekli.</p>
            <table style="border-collapse:collapse;margin-top:24px;font-size:15px">
                <tr><td style="padding:6px 16px 6px 0;color:#6e6e73">Hedef Framework</td><td style="padding:6px 0"><code>\(moniker)</code></td></tr>
                <tr><td style="padding:6px 16px 6px 0;color:#6e6e73">Sunucu</td><td style="padding:6px 0"><code>\(domain.webServer.displayName)</code> reverse proxy</td></tr>
                <tr><td style="padding:6px 16px 6px 0;color:#6e6e73">Türkçe Test</td><td style="padding:6px 0">ç ğ ı ö ş ü — İĞÜŞÖÇ ✓</td></tr>
            </table>
            <h2 style="font-size:1.15em;margin-top:32px">Örnek Uç Noktalar</h2>
            <ul>
                <li><a href="/weatherforecast">/weatherforecast</a> — örnek JSON verisi (hava durumu tahmini)</li>
                <li><a href="/info">/info</a> — çalışma zamanı sürüm bilgisi (JSON)</li>
            </ul>
            <p style="color:#a1a1a6;font-size:13px;margin-top:32px">Bu sayfa BRAMPP tarafından otomatik oluşturuldu. <code>wwwroot/index.html</code> dosyasından düzenleyebilirsiniz.</p>
        </body>
        </html>
        """
        if FileHelper.write(html, to: indexPath) {
            log(key: "log.dom.dotnetInfoPageCreated", type: .info)
        }
    }

    // MARK: - Native App (Node.js / .NET)

    /// Node.js / .NET uygulamasını NativeProcessManager ile başlatır (PM2 gerektirmez).
    /// .NET için önce proje varlığı kontrol edilir; yoksa veya yanlış framework ise otomatik düzeltilir.
    func startNativeApp(domain: Domain) async {
        log(key: "log.dom.appStarting", args: [domain.name], type: .command)
        await ensureDependencies(for: domain)

        // .NET: proje yoksa veya yanlış framework'sa düzelt
        if domain.platform == .dotnet {
            let ready = await ensureDotnetProject(domain: domain)
            guard ready else {
                log(key: "log.dom.appStartFailedProject", args: [domain.name], type: .error)
                refreshStatus()
                return
            }
        }

        // Node.js: node_modules yoksa bağımlılıkları OTOMATİK kur (Python venv /
        // .NET build ile simetrik). Aksi halde ilk başlatma MODULE_NOT_FOUND ile çöker
        // ve kullanıcı elle "Derle/Kur" çalıştırmak zorunda kalırdı.
        if domain.platform == .nodejs {
            await ensureNodeModules(domain: domain)
        }

        let ok = await NativeProcessManager.start(domain: domain)
        if ok {
            log(key: "log.dom.appStarted", args: [domain.name], type: .success)
            // Uygulama ayakta — bağlı web sunucusu (proxy) durmuşsa otomatik başlat + reload
            await reloadWebServer(for: domain, autoStart: true)
        } else {
            log(key: "log.dom.appStartFailed", args: [domain.name], type: .error)
            activeAlert = await buildStartAlert(for: domain)
        }
        refreshStatus()
    }

    /// Çalışan Node.js / .NET uygulamasını durdurur.
    func stopNativeApp(domain: Domain) async {
        log(key: "log.dom.appStopping", args: [domain.name], type: .command)
        await NativeProcessManager.stop(domain: domain)
        log(key: "log.dom.appStopped", args: [domain.name], type: .info)
        refreshStatus()
    }

    // MARK: - Başlatma Hatası Analizi

    /// Başlatma sonrası log'u okur; port çakışması veya genel hata için uyarı mesajı oluşturur.
    private func buildStartAlert(for domain: Domain) async -> AppAlert {
        let recent = await NativeProcessManager.readLogs(for: domain, lines: 30)
        let lines  = recent.components(separatedBy: "\n")

        // Port çakışması satırını ara: "Port :8001 zaten kullanımda — PID: 12345 (uvicorn)"
        if let conflict = lines.first(where: { $0.contains("zaten kullanımda") }) {
            // Port numarasını çıkar
            let port = domain.port.map { ":\($0)" } ?? ""
            // PID kısmını çıkar (varsa)
            var detail = conflict
            if let range = conflict.range(of: "❌ ") { detail = String(conflict[range.upperBound...]) }
            return AppAlert(
                title:   "Port\(port) Zaten Kullanımda",
                message: "\(detail)\n\nÖnce portu kullanan süreci durdurun veya domain ayarlarından farklı bir port seçin."
            )
        }

        // Genel başlatma hatası
        let hint = domain.platform == .dotnet
            ? "dotnet build çıktısını ve app.log dosyasını kontrol edin."
            : "app.log dosyasını inceleyerek hatanın kaynağını bulabilirsiniz."
        return AppAlert(
            title:   "\(domain.name) Başlatılamadı",
            message: hint
        )
    }
}
