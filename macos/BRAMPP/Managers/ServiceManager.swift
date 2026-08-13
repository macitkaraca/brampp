import SwiftUI
import Combine
import UserNotifications
import AppKit

// MARK: - ServiceManagerEvent

/// ServiceManager'ın cross-manager orchestrasyon için yayımladığı olaylar.
/// AppState bu olaylara subscribe olur; ServiceManager DomainManager'ı doğrudan bilmez.
enum ServiceManagerEvent {
    /// Periyodik hafif durum kontrolü tamamlandı — domain durumları da güncellenmeli.
    case lightRefreshCompleted
    /// Tüm web sunucuları (httpd + nginx) durdu — domain backend prosesleri kapatılmalı.
    case allWebServersStopped
    /// Bir web sunucusu (httpd/nginx) başladı — bağımlı PHP-FPM servisleri başlatılabilir.
    case webServerStarted(serviceId: String)
}

// MARK: - Kaldırma planı

/// Kaldırmada silinecek bir yolun TÜRÜ.
///
/// Ayrım kozmetik değil: `configuration` yeniden kurulumda yeniden üretilir,
/// `data` kullanıcının kendi ürettiği ve GERİ GETİRİLEMEZ içeriktir — veritabanı
/// kümeleri, pip ile kurulmuş paketler. Onay diyaloğu ikisini ayrı başlıklar altında
/// gösterir; veri varsa yazarak onay ister.
enum UninstallPathKind {
    case configuration
    case data
}

/// Kaldırmada `rm -rf` edilecek tek bir yol ve türü.
struct UninstallPath: Equatable {
    let path: String
    let kind: UninstallPathKind

    static func config(_ p: String) -> UninstallPath { UninstallPath(path: p, kind: .configuration) }
    static func data(_ p: String)   -> UninstallPath { UninstallPath(path: p, kind: .data) }
}

/// Bir kaldırmanın neyi sileceği — betiğin ve onay diyaloğunun ORTAK kaynağı.
/// Üretimi: `ServiceManager.uninstallPlan(forServiceID:brewPrefix:)`.
struct UninstallPlan {
    let serviceID: String
    /// Silinecek yollar, betiğe verilen SIRAYLA.
    let paths: [UninstallPath]
    /// SİLİNMEYEN ama DÜZENLENEN dosyalar — betik bunlardan satır çıkarır (`sed -i ''`).
    ///
    /// httpd.conf böyle bir dosyadır: silinemez (bütün Apache yapılandırması orada),
    /// ama MariaDB kaldırılırken phpMyAdmin include satırı çıkarılır. Eskiden bu düzenleme
    /// planın DIŞINDAYDI; diyalog Apache yapılandırmasının değişeceğini hiç söylemiyordu.
    let editedPaths: [String]
    /// KASITLI olarak dokunulmayan kullanıcı verisi (vhost'lar) — diyalogda da söylenir.
    let preservedPaths: [String]

    var allPaths: [String]           { paths.map(\.path) }
    var configurationPaths: [String] { paths.filter { $0.kind == .configuration }.map(\.path) }
    var dataPaths: [String]          { paths.filter { $0.kind == .data }.map(\.path) }

    /// Kullanıcı verisi siliniyor mu? Diyalog buna göre yazarak onay ister.
    var destroysData: Bool { !dataPaths.isEmpty }

    /// Kaybedilecek şeyin SOMUT cümlesinin katalog anahtarı — "dosyalar silinecek" değil,
    /// "bütün veritabanlarınız silinecek". Veri silinmiyorsa nil.
    var dataWarningKey: String? {
        guard destroysData else { return nil }
        if serviceID == "mariadb" || serviceID.hasPrefix("postgresql@") {
            return "svc.uninstall.dataWarn.databases"
        }
        if serviceID.hasPrefix("python@") { return "svc.uninstall.dataWarn.packages" }
        return "svc.uninstall.dataWarn.generic"
    }

    /// Onay diyaloğunun gövdesi: önce VERİ, sonra yapılandırma, sonra korunanlar.
    /// Çeviri bir kapanışla verilir — metin kurgusu saf kalır ve testlerden çağrılabilir.
    func confirmationMessage(_ t: (String) -> String) -> String {
        func block(_ header: String, _ items: [String]) -> String {
            ([t(header)] + items.map { "• \($0)" }).joined(separator: "\n")
        }
        var parts: [String] = []
        if destroysData {
            var data = block("svc.uninstall.dataHeader", dataPaths)
            if let key = dataWarningKey { data += "\n" + t(key) }
            parts.append(data)
        }
        if !configurationPaths.isEmpty {
            parts.append(block("svc.uninstall.configHeader", configurationPaths))
        }
        if !editedPaths.isEmpty {
            parts.append(block("svc.uninstall.editedHeader", editedPaths))
        }
        if !preservedPaths.isEmpty {
            parts.append(block("svc.uninstall.preserved", preservedPaths))
        }
        parts.append(t("svc.uninstall.confirm"))
        return parts.joined(separator: "\n\n")
    }

    /// Yazılan metin onayı karşılıyor mu? Servis ADI beklenir (büyük/küçük harf ve
    /// baştaki/sondaki boşluk önemsiz — amaç zorluk çıkarmak değil, kasıt aramak).
    func typedConfirmationMatches(_ typed: String, serviceName: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == serviceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Servis yönetimi — BaseManager'dan türetilir.
///
/// Durum kontrolleri iki katmanda çalışır:
/// - **Hafif (periyodik/anlık):** `launchctl list` PID kontrolü + `nc -z 127.0.0.1 PORT` iki koşullu izleme (~2ms).
/// - **Tam (başlangıç/kurulum):** Runtime sürümleri, port bilgileri ve kurulum durumu dahil tüm kontrolleri yapar.
@MainActor
class ServiceManager: BaseManager {

    @Published var services: [Service] = Service.defaultServices

    /// Kurulum ilerlemesi — gerçek zamanlı log
    @Published var installationLog: String   = ""
    @Published var installationTitle: String = ""
    @Published var isInstalling: Bool        = false
    /// Son kurulum/kaldırma akışının sonucu. `nil` = henüz sonuçlanmadı.
    ///
    /// Başlık bunu okur. Eskiden `installationLog.contains("✅")` ile çıkarım
    /// yapılıyordu: gövdedeki ARA adım tiklerini bütünün başarısı sanıyor ve
    /// açıkça iptal edilmiş bir PostgreSQL yapılandırması yeşil tik alıyordu.
    @Published var lastRunSucceeded: Bool? = nil

    // MARK: - Kurulum Onay İstemi (interaktif y/n)

    /// Kurulum bir onay istemi bekliyor mu? (UI girdi alanını gösterir)
    @Published var isAwaitingInput: Bool = false
    /// Bekleyen istemin metni (örn. "Do you want to proceed with the installation? [y/N]")
    @Published var currentPrompt: String = ""
    /// Otomatik "y" gönderilene kadar kalan saniye (0 = otomatik onay kapalı)
    @Published var autoConfirmCountdown: Int = 0
    /// Çalışan kuruluma girdi göndermek için PTY kanalı
    private var ptyController: Shell.PTYController?
    /// Zaman aşımı geri sayım görevi
    private var autoConfirmTask: Task<Void, Never>?

    private var refreshTimer: Timer?
    private var backgroundObservers: [NSObjectProtocol] = []

    /// Uyku/uyanma gözlemcileri AYRI tutulur: `NSWorkspace.shared.notificationCenter`
    /// `NotificationCenter.default`'tan farklı bir merkezdir ve kaydı oradan silmek
    /// hiçbir şey yapmaz — gözlemci sessizce yaşamaya devam eder, her `startAutoRefresh`
    /// bir yenisini ekler ve uyanışta N kez tazeleme tetiklenirdi.
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Önceki durum — çöküş tespiti için
    private var previousStatuses: [String: ServiceStatus] = [:]
    /// \r-tabanlı progress satırının log'daki güncel içeriği — streamInstallLog tarafından yönetilir
    private var _installProgressLine: String = ""
    /// Tam durum kontrolü yapılıp yapılmadığını belirtir.
    /// MenuBar bu flag'i kontrol ederek "yükleniyor" durumunu gösterir.
    private(set) var hasRunFullCheck: Bool = false

    // MARK: - Lifecycle Events

    /// AppState bu publisher'a subscribe olarak cross-manager orchestrasyon yapar.
    let events = PassthroughSubject<ServiceManagerEvent, Never>()

    // MARK: - Bağımlılık Yönetimi

    /// Tüm PHP-FPM servis ID'leri — PHPVersion enum'undan türetilir (yeni sürüm eklenince otomatik güncellenir)
    private static let phpServiceIds: [String] = PHPVersion.allCases.map { "php@\($0.rawValue)" }

    /// Web sunucuları durduğunda otomatik kapanan bağımlı servisler.
    /// Key: durdurulan servis ID, Value: o servis durduğunda kontrol edilecek bağımlılar.
    private static let serviceDependents: [String: [String]] = [
        "httpd": phpServiceIds,
        "nginx": phpServiceIds,
    ]
    /// Web sunucularının ID listesi
    private static let webServerIds: Set<String> = ["httpd", "nginx"]

    /// Bir servis durdurulunca bağımlı PHP-FPM servislerini cascade durdur.
    /// Ayarlar → Bağımlı Servisler → "Web sunucusu durduğunda PHP-FPM'i durdur" kontrolü yapılır.
    private func stopDependentsIfNeeded(stoppedId: String) {
        guard AppSettings.load().stopPHPOnWebServerStop else { return }
        let dependents = Self.serviceDependents[stoppedId] ?? []
        guard !dependents.isEmpty else { return }

        let anyWebServerRunning = services.contains {
            Self.webServerIds.contains($0.id) && $0.status == .running
        }
        guard !anyWebServerRunning else { return }

        for depId in dependents {
            // isBusy elenir: başlatma/durdurma ortasındaki servise ikinci bir stop
            // göndermek brew'da yarışa ve tutarsız duruma yol açar.
            if let svc = services.first(where: { $0.id == depId && $0.status == .running && !$0.isBusy }) {
                log(key: "log.svc.cascadeStop", args: [svc.name], type: .info)
                stopService(svc)
            }
        }
    }

    /// Web sunucusu durduğunda domain backend (Node.js / Python / .NET) proseslerini durdur.
    /// Her iki web sunucusu da (httpd + nginx) durmuşsa tetiklenir.
    /// Ayarlar → Bağımlı Servisler → "Web sunucusu durduğunda domain servislerini durdur" kontrolü yapılır.
    private func stopDomainProcessesIfNeeded(stoppedId: String) {
        guard AppSettings.load().stopDomainsOnWebServerStop else { return }
        guard Self.webServerIds.contains(stoppedId) else { return }
        let anyWebServerRunning = services.contains {
            Self.webServerIds.contains($0.id) && $0.status == .running
        }
        guard !anyWebServerRunning else { return }
        log(key: "log.svc.allWebServersStopped", type: .info)
        events.send(.allWebServersStopped)
    }

    // MARK: - Status

    /// Tam durum kontrolü — Başlangıçta ve kurulum sonrası çağrılır.
    /// Runtime sürümleri, port bilgileri, kurulum durumu dahil her şeyi kontrol eder.
    /// Tüm servisler için port + sürüm kontrolleri **eş zamanlı** (TaskGroup) çalışır.
    func refreshStatus() {
        guard requireBrew(forKey: "log.op.statusCheck") else {
            for i in 0..<services.count { services[i].status = .notInstalled }
            return
        }

        log(key: "log.svc.statusChecking", type: .info)

        Task {
            await updatePortsFromConfig()
            let runningLabels = await parseLaunchctlList()

            // Value-type anlık görüntü — child task'lara güvenle aktarılır
            let snapshot = services.enumerated().map { ($0.offset, $0.element) }

            // FileHelper.exists → @MainActor'da çağrılmalı (Swift 6).
            // TaskGroup'a girmeden önce kurulum durumunu hesapla ve sakla.
            let brewOpt = PathConfig.brewBase + "/opt"
            let isInstalledMap: [Int: Bool] = Dictionary(uniqueKeysWithValues:
                snapshot.compactMap { (i, svc) -> (Int, Bool)? in
                    guard svc.type == .brewService else { return nil }
                    return (i, FileHelper.exists("\(brewOpt)/\(svc.brewName ?? svc.id)"))
                }
            )

            // Dönüş tipi: (index, status, version?) — runtime sürümü için taşınır
            var results: [(index: Int, status: ServiceStatus, version: String?)] = []

            await withTaskGroup(of: (Int, ServiceStatus, String?).self) { group in
                for (i, svc) in snapshot {
                    group.addTask {
                        switch svc.type {
                        case .brewService:
                            let label = "homebrew.mxcl.\(svc.brewName ?? svc.id)"
                            let hasPort  = (svc.port ?? 0) > 0
                            let portOpen = hasPort ? await Shell.isPortOpenFast(svc.port!) : false
                            if runningLabels.contains(label) {
                                // refreshStatusLight ile tutarlı: HTTP portu açıksa çalışıyor
                                return (i, (!hasPort || portOpen) ? .running : .stopped, nil)
                            }
                            // Label eşleşmedi ama port açık — alias formüller (php@8.5 → php)
                            // launchd'de gerçek formül adıyla (homebrew.mxcl.php) kayıtlıdır.
                            if portOpen {
                                return (i, .running, nil)
                            }
                            // @MainActor'da önceden hesaplanan kurulum durumunu kullan
                            let installed = isInstalledMap[i] ?? false
                            return (i, installed ? .stopped : .notInstalled, nil)
                        case .runtime:
                            let ver = await self.getInstalledVersion(for: svc)
                            return (i, ver != nil ? .installed : .notInstalled, ver)
                        }
                    }
                }
                for await r in group { results.append((r.0, r.1, r.2)) }
            }

            // Sonuçları @MainActor'da uygula + baseline güncelle
            //
            // BAYAT SONUÇ KORUMASI: tarama (port kontrolleri) saniyeler sürebilir ve bu sırada
            // kullanıcı bir servisi başlatmış/durdurmuş olabilir. `snapshot` taramanın BAŞINDAKİ
            // kopyadır; servisin durumu o andan beri değiştiyse elimizdeki sonuç BAYATTIR ve
            // yazılmamalıdır — aksi halde az önce başlatılan servis tekrar "durduruldu" görünür.
            // Ayrıca dizi bu arada değişmiş olabileceğinden (kurulum/kaldırma) index'in hâlâ
            // AYNI servisi gösterdiği id ile doğrulanır.
            for r in results {
                guard r.index < services.count, r.index < snapshot.count else { continue }
                let atStart = snapshot[r.index].1
                guard services[r.index].id == atStart.id,
                      services[r.index].status == atStart.status else { continue }

                services[r.index].status = r.status
                if let ver = r.version { services[r.index].version = ver }
                previousStatuses[services[r.index].id] = r.status
            }
            hasRunFullCheck = true
            log(key: "log.svc.statusUpdated", type: .success)
            persistRunningServices()
        }
    }

    // MARK: - Son Çalışan Servisler (açılışta geri yükleme)

    /// Çıkış sürüyor — persistRunningServices'in korunan listeyi ezmesini önler.
    private var isQuitting = false

    /// Çalışan brew servislerinin ID'lerini diske yazar.
    /// Açılışta "son çalışanları başlat" modu bu listeyi kullanır.
    private func persistRunningServices() {
        guard hasRunFullCheck, !isQuitting else { return }
        // Dosya MAKİNEYE ait (bkz. Core/ProcessRole.swift): test ana uygulaması ya da ikinci
        // bir kopya buraya yazarsa, bir sonraki GERÇEK açılışta "son çalışanları başlat"
        // yanlış listeyi geri getirir. Kapı bootstrap'ta bir kez değil, HER YAZIMDA
        // sorulur — kısıtlama geçiciyse (kapanmakta olan eski kopya) kendiliğinden geçer.
        guard ProcessRole.mayMutateSharedEnvironment else { return }
        let running = services.filter { $0.canToggle && $0.status == .running }.map(\.id)
        if let data = try? JSONEncoder().encode(running) {
            FileHelper.write(data, to: PathConfig.lastRunningJson)
        }
    }

    /// lastRunningJson'daki kayıtlı listeyi okur.
    /// Çıkış yolu (AppDelegate.realQuit) bunu kullanır: `brew services stop --all` yerine
    /// YALNIZCA bu uygulamanın çalıştırdığı servisleri durdurmak için.
    static func readLastRunningIds() -> [String] {
        guard let data = FileHelper.readData(PathConfig.lastRunningJson),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return ids
    }

    /// Kullanıcının açılışta başlatmayı seçtiği servisleri başlatır (yalnızca KURULU + DURMUŞ olanlar).
    func startSelectedServices(ids: [String]) {
        for id in ids {
            guard let svc = services.first(where: { $0.id == id }),
                  svc.status == .stopped, svc.canToggle else { continue }
            log(key: "log.svc.startupLaunching", args: [svc.name], type: .info)
            startService(svc)
        }
    }


    /// Hafif durum kontrolü — Periyodik timer ve uygulama ön plana gelince çağrılır.
    ///
    /// **Port-tabanlı izleme:**
    /// `nc -z 127.0.0.1 PORT` → Port dinleniyor mu? (~1ms)
    /// Port bilgisi olmayan servisler atlanır (tam yenileme günceller).
    ///
    /// Tüm kontroller **eş zamanlı** (TaskGroup) çalışır — sıralı bekleme yok.
    func refreshStatusLight() async {
        guard requireBrew(forKey: "log.op.statusCheck"), hasRunFullCheck else { return }

        log(key: "log.svc.statusCheckingLight", type: .info)

        // Sadece port'u olan brew servisleri — port kapıyı tutuyor mu? → servis cevabı
        let snapshot = services.enumerated()
            .filter { $0.element.type == .brewService && $0.element.status != .notInstalled }
            .compactMap { e -> (Int, Service, Int)? in
                guard let port = e.element.port, port > 0 else { return nil }
                return (e.offset, e.element, port)
            }

        // Tüm port kontrollerini eş zamanlı yürüt
        var results: [(Int, ServiceStatus)] = []
        await withTaskGroup(of: (Int, ServiceStatus).self) { group in
            for (i, _, port) in snapshot {
                group.addTask {
                    let portOpen = await Shell.isPortOpenFast(port)
                    return (i, portOpen ? .running : .stopped)
                }
            }
            for await r in group { results.append(r) }
        }

        // Sonuçları @MainActor'da uygula + çöküş tespiti
        for (i, newStatus) in results {
            let svc = services[i]
            // Kasıtlı durdurma/başlatma sürerken (isBusy) sahte "çöktü" bildirimi gönderme
            if let prev = previousStatuses[svc.id], prev == .running, newStatus == .stopped, !svc.isBusy {
                sendCrashNotification(for: svc)
                log(key: "log.svc.crashed", args: [svc.name], type: .warning)
            }
            // Başlatma/durdurma sürerken (isBusy) light-refresh sonucu BAYATTIR — yazma.
            guard !services[i].isBusy else { continue }
            services[i].status = newStatus
            previousStatuses[svc.id] = newStatus
        }
        log(key: "log.svc.statusUpdatedLight", type: .success)
        persistRunningServices()
        events.send(.lightRefreshCompleted)
    }

    // MARK: - Service Control (Birleşik)

    /// Eylem (start/stop/restart) → log anahtarı soneki.
    /// Üretilen anahtarlar: log.svc.{begin,done,failed}{Start,Stop,Restart} ve
    /// log.op.service{Start,Stop,Restart} (Core/L10nLog+service.swift ve +base.swift).
    private static func actionKeySuffix(_ action: String) -> String {
        switch action {
        case "start": return "Start"
        case "stop":  return "Stop"
        default:      return "Restart"
        }
    }

    private func controlService(_ service: Service, action: String, expectedStatus: ServiceStatus) {
        // Fiil çekimi TR/EN'de farklı kurulur — ARGÜMAN olarak geçirilemez.
        // Her eylemin KENDİ anahtarı vardır: begin/done/failed + Start|Stop|Restart.
        let sfx = Self.actionKeySuffix(action)
        guard requireBrew(forKey: "log.op.service\(sfx)", [service.name]) else { return }
        guard let i = services.firstIndex(where: { $0.id == service.id }) else { return }

        // Spinner — brew yanıt verene kadar döner (start/restart: turuncu, stop: kırmızı)
        if action == "stop" {
            services[i].isStopping = true
        } else {
            services[i].isStarting = true
        }
        log(key: "log.svc.begin\(sfx)", args: [service.name], type: .command)

        Task {
            // Fresh start'ta port çakışma kontrolü — ASENKRON (senkron `nc` ana thread'i
            // dondururdu). Task içinde yapılır ki UI donmasın; iptal olursa spinner temizlenir.
            if action == "start", let port = service.port, port > 0,
               await Shell.isPortInUseAsync(port) {
                log(key: "log.svc.portInUse", args: [service.name, "\(port)"], type: .warning)
                services[i].isStarting = false
                return
            }

            let brewName   = service.brewName ?? service.id
            // start → "run" (login'de auto-start yok, sadece şu oturum)
            let brewAction = (action == "start") ? "run" : action

            // Brew komutunu konsola yaz — verboseLogging zaten full path ile logluyor,
            // ikisi aynı anda açıksa çift log olmasın. restart aslında stop+run çalıştırır
            // (run semantiği — login'de auto-start yok), log da bunu doğru gösterir.
            let settings = AppSettings.load()
            if settings.showCommandsInConsole && !settings.verboseLogging {
                if brewAction == "restart" {
                    log("$ brew services stop \(brewName) && brew services run \(brewName)", type: .command)
                } else {
                    log("$ brew services \(brewAction) \(brewName)", type: .command)
                }
            }

            let r        = await Shell.brewServicesAsync(brewAction, service: brewName)
            let combined = (r.output + " " + r.error).trimmingCharacters(in: .whitespaces)

            // Brew çıktısını konsola yaz — SADECE başarılı olduğunda.
            // Başarısız durumda aşağıda "başarısız: <hata>" olarak zaten loglanır; burada
            // ayrıca warning yazmak aynı mesajın iki kez görünmesine yol açar.
            if settings.showBrewOutputInConsole, r.isSuccess, !combined.isEmpty {
                let brewOutput = combined
                    .components(separatedBy: "\n")
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty
                           && !$0.localizedCaseInsensitiveContains("Try re-running") }
                    .joined(separator: " | ")
                if !brewOutput.isEmpty {
                    log("↳ \(brewOutput)", type: .info)
                }
            }

            // "Zaten çalışıyor / durdurulmuş" tespiti
            //
            // "Bootstrap failed: 5" iki farklı anlam taşır:
            //   • TEK BAŞINA (EALREADY)  → servis zaten bootstrap'lı, sorunsuz çalışıyor ✓
            //   • + "Input/output error" → launchctl gerçek I/O hatası, servis BAŞLAMADI ✗
            //   • + "Failure while executing" → plist/binary sorunu, servis BAŞLAMADI ✗
            //
            // "exited with 5" de aynı hata mesajında geçebilir; güvenilmez — kontrol dışı bırakıldı.
            let isBootstrapFailed5  = combined.localizedCaseInsensitiveContains("Bootstrap failed: 5")
            let isRealBootstrapError = isBootstrapFailed5
                && (combined.localizedCaseInsensitiveContains("Input/output error")
                    || combined.localizedCaseInsensitiveContains("Failure while executing"))

            let alreadyRunning = combined.localizedCaseInsensitiveContains("already started")
                || combined.localizedCaseInsensitiveContains("already running")
                || combined.localizedCaseInsensitiveContains("already bootstrapped")
                || (isBootstrapFailed5 && !isRealBootstrapError)

            let alreadyStopped = action == "stop"
                && combined.localizedCaseInsensitiveContains("is not started")

            let brewSucceeded = r.isSuccess || alreadyRunning || alreadyStopped

            if brewSucceeded {
                if alreadyRunning {
                    log(key: "log.svc.alreadyRunning", args: [service.name], type: .warning)
                } else if alreadyStopped {
                    log(key: "log.svc.alreadyStopped", args: [service.name], type: .warning)
                }

                // Başlatma/restart: porta bakarak gerçek durumu doğrula
                // Durdurma: brew sonucuna güven (port 80 gibi privileged portlar root olmadan tam ölçülemez)
                // Apache/Nginx: HTTP veya HTTPS portlarından biri açıksa çalışıyor sayılır
                let confirmedPort = service.port.flatMap { $0 > 0 ? $0 : nil }
                if let port = confirmedPort, (action == "start" || action == "restart"), !alreadyRunning {
                    // Brew OK döndükten hemen sonra servis henüz porta bağlanmamış olabilir.
                    // 500ms aralıklarla 5 kez dene — max ~2.5 sn bekle.
                    var portOpen = false
                    for attempt in 1...5 {
                        try? await Task.sleep(nanoseconds: 500_000_000)   // 500ms
                        if await Shell.isPortInUseAsync(port) { portOpen = true; break }
                        if attempt == 5 { break }
                    }
                    if portOpen {
                        services[i].status = .running
                        previousStatuses[service.id] = .running
                        log(key: "log.svc.startedPortActive", args: [service.name, "\(port)"], type: .success)
                    } else {
                        // 2.5 sn sonra hâlâ port yok → brew başardı ama servis ayağa kalkmadı
                        services[i].status = .stopped
                        previousStatuses[service.id] = .stopped
                        log(key: "log.svc.startedPortSilent", args: [service.name], type: .warning)
                    }
                } else {
                    // Port bilgisi yok veya zaten çalışıyordu → brew sonucuna güven
                    services[i].status = expectedStatus
                    previousStatuses[service.id] = expectedStatus
                    if !alreadyRunning && !alreadyStopped {
                        log(key: "log.svc.done\(sfx)", args: [service.name], type: .success)
                    }
                }

                // Durdurma başarılıysa → bağımlı servisleri cascade durdur
                if action == "stop" {
                    stopDependentsIfNeeded(stoppedId: service.id)
                    stopDomainProcessesIfNeeded(stoppedId: service.id)
                }

                // Web sunucusu başladıysa → bağımlı PHP-FPM'leri başlat (AppState orkestre eder)
                if (action == "start" || action == "restart"),
                   Self.webServerIds.contains(service.id),
                   services[i].status == .running {
                    events.send(.webServerStarted(serviceId: service.id))
                }
            } else {
                // Hata mesajını temizle: "Try re-running..." satırlarını çıkar
                let errorMsg = combined
                    .components(separatedBy: "\n")
                    .filter { !$0.isEmpty && !$0.localizedCaseInsensitiveContains("Try re-running") }
                    .joined(separator: " | ")
                log(key: "log.svc.failed\(sfx)", args: [service.name, errorMsg], type: .error)
                // .error yerine .stopped: hata konsola yazıldı, UI'de butonlar görünür kalsın
                services[i].status = .stopped
                previousStatuses[service.id] = .stopped
            }

            services[i].isStarting = false
            services[i].isStopping = false
            persistRunningServices()
        }
    }

    func startService(_ service: Service)   { controlService(service, action: "start",   expectedStatus: .running) }
    func stopService(_ service: Service)    { controlService(service, action: "stop",    expectedStatus: .stopped) }
    func restartService(_ service: Service) { controlService(service, action: "restart", expectedStatus: .running) }

    func toggleService(_ service: Service) {
        service.status == .running ? stopService(service) : startService(service)
    }

    /// Bir web sunucusunu (httpd/nginx) çalışır durumda GARANTİ eder — async, sonucu bekler.
    /// DomainManager domain eklerken/başlatırken çağırır: bağlı sunucu durmuşsa `brew services run`
    /// ile başlatır, portu doğrular ve UI durumunu günceller. Zaten çalışıyorsa hemen true döner.
    /// (controlService fire-and-forget olduğundan domain akışının bekleyebileceği ayrı bir yol.)
    @discardableResult
    func ensureWebServerRunning(_ serviceId: String) async -> Bool {
        guard requireBrew(forKey: "log.op.webServerStart") else { return false }
        guard let i = services.firstIndex(where: { $0.id == serviceId }) else {
            log(key: "log.svc.depUnknown", args: [serviceId], type: .warning)
            return false
        }

        // ÖNCE KURULU MU? Kurulmamış bir servise `brew services run` demek anlamsız bir
        // brew hatası döndürür ve kullanıcı asıl sorunu (paket hiç kurulu değil) göremez.
        // Bağımlılık listesinde kurulu olmayan servis BULUNABİLİR: dependencyCandidates
        // kayıtlı seçimleri brew'dan kaldırılmış olsa bile listede tutuyor.
        guard services[i].status != .notInstalled else {
            log(key: "log.svc.depNotInstalled", args: [services[i].name], type: .warning)
            return false
        }

        // Zaten çalışıyor mu? (process adı ile hızlı kontrol)
        // Servis id'si HER ZAMAN daemon adı değildir: mariadb'nin süreci mariadbd,
        // redis'inki redis-server, postgresql@X'inki postgres, php@X'inki php-fpm.
        // Haritasız pgrep bu servisleri hep "çalışmıyor" sanıp gereksiz brew çağırırdı.
        let procName: String = {
            switch serviceId {
            case "mariadb":                              return "mariadbd"
            case "redis":                                return "redis-server"
            case let id where id.hasPrefix("postgresql@"): return "postgres"
            case let id where id.hasPrefix("php@"):        return "php-fpm"
            default:                                     return serviceId   // httpd/nginx/memcached
            }
        }()
        // php@X / postgresql@X süreç adları (php-fpm/postgres) TÜM sürümlerde ORTAK olduğundan
        // pgrep herhangi bir sürüm çalışıyorsa yanlışça "bu sürüm çalışıyor" der. Bu servisler
        // için pgrep atlanır; aşağıdaki sürüme-özgü PORT kontrolü tek güvenilir ölçüttür.
        let versioned = serviceId.hasPrefix("php@") || serviceId.hasPrefix("postgresql@")
        if !versioned, await Shell.isProcessAlive(procName) {
            services[i].status = .running
            previousStatuses[serviceId] = .running
            return true
        }
        if versioned, let port = services[i].port, port > 0, await Shell.isPortInUseAsync(port) {
            services[i].status = .running
            previousStatuses[serviceId] = .running
            return true
        }

        let svc      = services[i]
        let brewName = svc.brewName ?? svc.id
        services[i].isStarting = true
        // Spinner brew komutu dönene kadar değil, aşağıdaki PORT doğrulaması bitene kadar
        // sürmeli — erken kapatılınca servis birkaç saniye "durdurulmuş" görünüyordu.
        // Index defer anında yeniden aranır: await'ler sırasında dizi değişmiş olabilir.
        defer {
            if let k = services.firstIndex(where: { $0.id == serviceId }) {
                services[k].isStarting = false
            }
        }
        log(key: "log.svc.autoStartForDomain", args: [svc.name], type: .command)
        let r = await Shell.brewServicesAsync("run", service: brewName)

        let combined = (r.output + " " + r.error).lowercased()
        let already  = combined.contains("already")
        guard r.isSuccess || already else {
            log(key: "log.svc.autoStartFailed", args: [svc.name, r.error.isEmpty ? r.output : r.error], type: .error)
            return false
        }

        // Portu doğrula (max ~2.5sn) — brew OK dönse de servis henüz bağlanmamış olabilir
        if let port = svc.port, port > 0 {
            for _ in 1...5 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if await Shell.isPortInUseAsync(port) {
                    services[i].status = .running
                    previousStatuses[serviceId] = .running
                    log(key: "log.svc.startedPortActive", args: [svc.name, "\(port)"], type: .success)
                    // Olay yalnızca GERÇEK web sunucuları için: deps özelliğiyle MariaDB/Redis de
                    // buradan başlıyor; guard'sız gönderim PHP-FPM'leri gereksiz tetiklerdi.
                    if Self.webServerIds.contains(serviceId) {
                        events.send(.webServerStarted(serviceId: serviceId))
                    }
                    return true
                }
            }
        }
        // Port doğrulanamadı ama process ayakta olabilir (privileged port vb.) — pgrep ile son kontrol.
        // versioned (php@X/postgresql@X) hariç: süreç adı tüm sürümlerde ortak olduğundan
        // pgrep başka bir sürümü görüp yanlışça "çalışıyor" derdi — tek ölçüt PORT.
        if !versioned, await Shell.isProcessAlive(procName) {
            services[i].status = .running
            previousStatuses[serviceId] = .running
            if Self.webServerIds.contains(serviceId) {
                events.send(.webServerStarted(serviceId: serviceId))
            }
            log(key: "log.svc.started", args: [svc.name], type: .success)
            return true
        }
        log(key: "log.svc.startedNoResponse", args: [svc.name], type: .warning)
        return false
    }

    // MARK: - Bulk

    func startAll() {
        guard requireBrew(forKey: "log.op.startAll") else { return }
        log(key: "log.svc.startAll", type: .command)
        Task {
            // Güncel durumu al — eski cache'den çalışan servisi yeniden başlatmayı önle
            await refreshStatusLight()

            let running = services.filter { $0.canToggle && $0.status == .running }
            let toStart = services.filter { $0.canToggle && $0.status == .stopped }

            if !running.isEmpty {
                let names = running.map(\.name).joined(separator: ", ")
                log(key: "log.svc.skipRunning", args: [names], type: .info)
            }
            for svc in toStart { startService(svc) }
        }
    }

    func stopAll() {
        guard requireBrew(forKey: "log.op.stopAll") else { return }
        log(key: "log.svc.stopAll", type: .command)
        Task {
            // Güncel durumu al — bayat cache'e göre çalışan servisi atlamayı önle (startAll ile simetrik)
            await refreshStatusLight()
            for svc in services where svc.canToggle && svc.status == .running { stopService(svc) }
        }
        // Domain backend prosesleri stopDomainProcessesIfNeeded → event → AppState zinciriyle durdurulur.
        // Web sunucuları async olarak durduğunda her biri için olay zaten tetiklenir.
    }

    /// Çıkış için: çalışan servisleri ANİMASYONLU durdurur (menü bar/Servisler sekmesi
    /// satırları "Durduruluyor..." kırmızı spinner gösterir), sonra uygulamayı sonlandırır.
    /// Doğrudan `brew services stop --all` çağrısı isStopping bayraklarını set etmediğinden
    /// eskiden animasyon görünmüyor ve uygulama aniden kapanıyordu.
    /// Çıkış öncesi hazırlık — periyodik yenilemeyi durdurur ve persist'i kilitler.
    /// Böylece çıkış sırasında (brew stop penceresi) auto-refresh tetiklenip "son çalışan
    /// servisler" listesini boş/yarı-durmuş durumla EZEMEZ. Dock "Servisleri Durdur ve Kapat"
    /// yolu da (realQuit stopServices:true) bunu çağırmalı — aksi halde korumayı atlar.
    func prepareForQuit() {
        stopAutoRefresh()
        isQuitting = true
    }

    func stopAllAndQuit() {
        func terminate() {
            BRAMPPAppDelegate.shared?.realQuit(stopServices: false) ?? NSApp.terminate(nil)
        }
        // Çıkış sırasında periyodik hafif yenileme tetiklenip "son çalışanlar" listesini
        // boş/yarı-durmuş durumla ezmesin — timer'ı durdur, persist'i bayrakla kilitle.
        prepareForQuit()

        // Homebrew yoksa bile domain backend süreçleri (Node/Python/.NET) durdurulmalı:
        // bunlar brew'dan bağımsız, `nohup` ile başlatılır ve uygulama kapandıktan sonra
        // arka planda çalışmaya DEVAM eder. Bu yüzden `requireBrew` artık erken çıkmaz.
        let brewReady  = requireBrew(forKey: "log.op.stopOnQuit")
        let runningIdx = brewReady
            ? services.indices.filter { services[$0].canToggle && services[$0].status == .running }
            : []

        // Animasyonu hemen göster — kırmızı spinner + "Durduruluyor..."
        if !runningIdx.isEmpty {
            for i in runningIdx { services[i].isStopping = true }
            log(key: "log.svc.quitStopping", args: ["\(runningIdx.count)"], type: .command)
        }

        Task {
            // 0) Domain backend süreçleri — brew servislerinden ÖNCE durdurulur.
            //    Terminate'ten sonra kimse durduramaz: nohup'lu wrapper'lar öksüz kalıp
            //    portları tutmaya devam eder ve sonraki açılışta "port kullanımda" hatası verir.
            await stopDomainBackendsForQuit()

            // `--all` KULLANILMAZ: kullanıcının BRAMPP dışında başlattığı Homebrew
            // servislerini (postgres@13, mongodb, elasticsearch…) de durdururdu.
            // Yalnızca bu uygulamanın yönettiği ÇALIŞAN servisler durdurulur.
            let names = runningIdx.compactMap { services.indices.contains($0) ? (services[$0].brewName ?? services[$0].id) : nil }
            if !names.isEmpty {
                _ = await Shell.brewBashAsync("\(Shell.brewBin) services stop \(names.joined(separator: " ")) 2>/dev/null")
                // Animasyonun görünmesi + durdurmanın oturması için kısa bekle
                try? await Task.sleep(nanoseconds: 900_000_000)
            }
            // NOT: persistRunningServices() ÇAĞRILMAZ — "son çalışan servisler" listesi
            // çıkıştan önceki durumu korumalı ki açılışta o servisler geri başlatılabilsin.
            for i in runningIdx where services.indices.contains(i) {
                services[i].isStopping = false
                services[i].status = .stopped
                previousStatuses[services[i].id] = .stopped
            }
            // Kullanıcının son kareyi görmesi için küçük bir es, sonra çık
            if !runningIdx.isEmpty {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            terminate()
        }
    }

    /// Çıkışta domain backend (Node.js / Python / .NET) süreçlerini durdurur.
    ///
    /// `NativeProcessManager.start` süreçleri `nohup` ile arkaplanlaştırır: uygulama
    /// kapansa da yaşamaya devam ederler. DomainManager burada erişilebilir olmadığından
    /// domain listesi doğrudan `domains.json`'dan okunur (çıkış anında bu dosya günceldir).
    ///
    /// Ayarlar → Bağımlı Servisler → "Web sunucusu durduğunda domain servislerini durdur"
    /// kapalıysa kullanıcı süreçlerin bağımsız yaşamasını istiyordur — dokunulmaz.
    private func stopDomainBackendsForQuit() async {
        guard AppSettings.load().stopDomainsOnWebServerStop else { return }
        guard let data = FileHelper.readData(PathConfig.domainsJson),
              let list = try? JSONDecoder().decode(DomainList.self, from: data) else { return }

        let backends = list.domains.filter { [Platform.nodejs, .python, .dotnet].contains($0.platform) }
        guard !backends.isEmpty else { return }

        // Önce ÇALIŞANLARI belirle (isRunning port/PID kontrolü yapar), sonra durdur.
        var running: [Domain] = []
        for domain in backends {
            if await NativeProcessManager.isRunning(domain: domain) { running.append(domain) }
        }
        guard !running.isEmpty else { return }

        log(key: "log.svc.quitStoppingDomains", args: ["\(running.count)"], type: .command)
        for domain in running {
            await NativeProcessManager.stop(domain: domain)
        }
    }

    func restartApache() {
        if let apache = services.first(where: { $0.id == "httpd" }) { restartService(apache) }
    }

    func restartNginx() {
        if let nginx = services.first(where: { $0.id == "nginx" }) { restartService(nginx) }
    }

    // MARK: - Installation

    func installService(_ service: Service) {
        guard requireBrew(forKey: "log.op.serviceInstall", [service.name]) else { return }
        // Kurulum durumu (isInstalling / installationLog / ptyController) TEKİLDİR.
        // İkinci bir akış aynı alanları ezer ve ilkini istemine yanıtsız bırakır.
        guard !isInstalling else {
            log(key: "log.svc.installBusy", args: [installationTitle], type: .warning); return
        }
        guard let i = services.firstIndex(where: { $0.id == service.id }) else { return }

        // streamBashPTY kendi PTY'sini oluşturur; withPTY sarması gerekmez
        let cmd = service.installCommand ?? "brew install \(service.brewName ?? service.id)"

        // Kurulum log penceresini başlat
        services[i].isLoading  = true
        isInstalling            = true
        installationTitle       = "\(service.name) Kuruluyor"
        installationLog         = "🚀 \(service.name) kurulum başlatılıyor...\n\(cmd)\n\n"

        log(key: "log.svc.installing", args: [service.name], type: .command)

        Task {
            // Komutu gerçek zamanlı çalıştır — progress barları da canlı güncellenir
            let r = await streamInstallLog(cmd)

            services[i].isLoading = false
            isInstalling          = false

            if r.isSuccess {
                installationLog += "\n✅ Kurulum başarıyla tamamlandı!\n"
                log(key: "log.svc.installed", args: [service.name], type: .success)
            } else {
                installationLog += "\n❌ Kurulum başarısız (Hata kodu: \(r.exitCode))\n"
                if !r.error.isEmpty { installationLog += r.error + "\n" }
                log(key: "log.svc.installFailed", args: [service.name, r.error], type: .error)
            }

            // PHP kurulumu → FPM ayarlarını otomatik uygula
            if let phpVersion = PHPFPMConfigManager.phpVersion(from: service.id) {
                if PHPFPMConfigManager.normalize(for: phpVersion) {
                    log(key: "log.svc.phpFpmNormalized", args: [phpVersion], type: .success)
                }
            }

            // PostgreSQL kurulumu → postgresql.conf'a beklenen portu yaz (5432/5433/5434)
            if r.isSuccess && service.id.hasPrefix("postgresql@"), let expectedPort = service.port {
                let ver = service.id.replacingOccurrences(of: "postgresql@", with: "")
                let confPath = PathConfig.pgDataDir(version: ver) + "/postgresql.conf"
                if setPostgresPort(in: confPath, port: expectedPort) {
                    installationLog += "✅ postgresql.conf — port \(expectedPort) ayarlandı\n"
                    log(key: "log.svc.pgPortConfigured", args: [ver, "\(expectedPort)"], type: .info)
                }
            }

            // Nginx kurulumu → nginx.conf sıfırdan yaz + sites-available dizini oluştur
            // (yalnızca kurulum gerçekten başarılıysa — başarısız kurulumda mevcut config'e dokunma)
            if r.isSuccess, service.id == "nginx" {
                NginxConfigManager.createSitesAvailableDir()
                let sslAvailable = NginxConfigManager.localhostSSLReady
                if NginxConfigManager.rewriteMainConfig(sslAvailable: sslAvailable) {
                    // SSL notu ARGÜMAN olarak geçirilir; "@" ön eki katalogdan çevrilmesini sağlar
                    let sslNote = sslAvailable ? "@log.svc.nginxSslNoteBoth" : "@log.svc.nginxSslNoteHttpOnly"
                    log(key: "log.svc.nginxMainConfigCreated", args: [sslNote], type: .success)
                } else {
                    log(key: "log.svc.nginxMainConfigWriteFailed", type: .error)
                }
            }


            refreshStatus()
        }
    }

    // MARK: - phpMyAdmin Installation (InstallationProgressSheet)

    /// phpMyAdmin'i ServicesTab'daki İlerleme Penceresi'nde kurar; config sağ konsolda gösterilir.
    func installPhpMyAdmin() {
        guard requireBrew(forKey: "log.op.phpmyadminInstall") else { return }
        // Kurulum durumu (isInstalling / installationLog / ptyController) TEKİLDİR.
        // İkinci bir akış aynı alanları ezer ve ilkini istemine yanıtsız bırakır.
        guard !isInstalling else {
            log(key: "log.svc.installBusy", args: [installationTitle], type: .warning); return
        }
        isInstalling     = true
        installationTitle = "phpMyAdmin Kuruluyor"
        installationLog  = "🚀 phpMyAdmin kurulum başlatılıyor...\n\(Shell.brewBin) install phpmyadmin\n\n"
        log(key: "log.svc.pmaInstalling", type: .command)

        Task {
            let r = await streamInstallLog("\(Shell.brewBin) install phpmyadmin 2>&1")

            lastRunSucceeded = r.isSuccess
            isInstalling = false

            if r.isSuccess {
                installationLog += "\n✅ phpMyAdmin başarıyla kuruldu!\n"
                log(key: "log.svc.pmaInstalled", type: .success)
                // Yapılandırma — sağ konsolda gösterilir (sheet kapatıldıktan sonra görünür)
                setupPhpMyAdminApacheConfig()
                await configureMariaDBRoot()
                log(key: "log.svc.restartApacheHint", type: .info)
            } else {
                installationLog += "\n❌ Kurulum başarısız (Hata kodu: \(r.exitCode))\n"
                if !r.error.isEmpty { installationLog += r.error + "\n" }
                log(key: "log.svc.pmaInstallFailed", args: [r.error], type: .error)
            }
            refreshStatus()
        }
    }

    /// Varsayılan PHP sürümü değiştiğinde, PHP-FPM portunu SABİT gömmüş tüm paylaşılan
    /// web-sunucu config'lerini yeni portla yeniden üretir. Aksi halde localhost, phpMyAdmin
    /// ve Adminer eski FPM portuna proxy'lemeye devam eder → eski sürüm durdurulunca 502/503,
    /// çalışıyorsa kullanıcının seçtiği sürüm yerine sessizce eski sürüm çalışır.
    /// - Parameter domainManager: 000-localhost.conf'u force ile yeniden yazmak için gerekir.
    func applyDefaultPHPVersionChange(domainManager: DomainManager) {
        let newPort = AppSettings.load().defaultPHPVersion.port
        log(key: "log.svc.defaultPhpPortApplying", args: ["\(newPort)"], type: .command)

        // 1) Apache localhost varsayılan vhost'unu yeni portla ZORLA yeniden yaz
        domainManager.ensureApacheDefaultVHost(force: true)

        // 2) phpMyAdmin Apache config (kuruluysa)
        if PathConfig.isPhpMyAdminInstalled, FileHelper.exists(PathConfig.httpdConf) {
            _ = FileHelper.write(VHostTemplates.phpmyadminConfig(phpPort: newPort), to: PathConfig.phpmyadminConf)
        }
        // 3) Adminer Apache config (kuruluysa)
        if PathConfig.isAdminerInstalled, FileHelper.exists(PathConfig.httpdConf) {
            _ = FileHelper.write(VHostTemplates.adminerApacheConfig(phpPort: newPort), to: PathConfig.adminerConf)
        }

        // 4) Nginx ana config (localhost + phpMyAdmin + Adminer portları içinde)
        if FileHelper.exists(PathConfig.nginxConf) {
            let ssl = NginxConfigManager.localhostSSLReady
            _ = NginxConfigManager.rewriteMainConfig(sslAvailable: ssl)   // auto-detect: kurulu blokları korur
        }

        // 5) Web sunucularını yeniden yükle (çalışıyorlarsa)
        Task {
            if await Shell.isProcessAlive("httpd") {
                _ = await Shell.bashAsync("\(Shell.brewPrefix)/bin/apachectl graceful 2>&1")
            }
            if await Shell.isProcessAlive("nginx") {
                _ = await Shell.bashAsync("\(Shell.brewPrefix)/bin/nginx -s reload 2>&1")
            }
            log(key: "log.svc.defaultPhpPortApplied", type: .success)
        }
    }

    private func setupPhpMyAdminApacheConfig() {
        log(key: "log.svc.pmaApacheConfiguring", type: .info)
        FileHelper.createDirectory(PathConfig.httpdExtra)
        let confOK    = FileHelper.write(
            VHostTemplates.phpmyadminConfig(phpPort: AppSettings.load().defaultPHPVersion.port),
            to: PathConfig.phpmyadminConf
        )
        let includeOK = FileHelper.appendLineIfMissing(VHostTemplates.phpmyadminIncludeConfig(), to: PathConfig.httpdConf)
        let appOK     = patchOrWritePhpMyAdminConfig()
        log(key: confOK    ? "log.svc.pmaConfCreated"      : "log.svc.pmaConfWriteFailed",  type: confOK    ? .success : .error)
        log(key: includeOK ? "log.svc.pmaIncludeAdded"     : "log.svc.pmaIncludeFailed",    type: includeOK ? .success : .error)
        log(key: appOK     ? "log.svc.pmaAppConfigUpdated" : "log.svc.pmaAppConfigFailed",  type: appOK     ? .success : .error)
    }

    /// Mevcut config.inc.php varsa blowfish_secret/host/AllowNoPassword yamalar; yoksa sıfırdan yazar.
    /// Var olan dosya ÖZGÜN kodlamasıyla geri yazılır; okunamıyorsa hiç dokunulmaz
    /// (aksi halde kullanıcının Latin-1 config'i UTF-8'e çevrilip bozulur).
    @discardableResult
    private func patchOrWritePhpMyAdminConfig() -> Bool {
        let path = PathConfig.phpmyadminAppConfig

        let result = ConfigFileEditor.patch(path) { existing in
            let patched = existing.components(separatedBy: .newlines)
                .map { line -> String in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if t.contains("blowfish_secret") {
                        if let s = t.range(of: "= '")?.upperBound,
                           let e = t[s...].range(of: "'")?.lowerBound,
                           String(t[s..<e]).count < 32 {
                            let newSecret = VHostTemplates.generateBlowfishSecret()
                            return line.replacingOccurrences(of: "= '\(String(t[s..<e]))'", with: "= '\(newSecret)'")
                        }
                        return line
                    }
                    if t.contains("['host']") && t.contains("'localhost'") {
                        return line.replacingOccurrences(of: "'localhost'", with: "'127.0.0.1'")
                    }
                    if t.contains("AllowNoPassword") {
                        return line.replacingOccurrences(of: "= false;", with: "= true;")
                    }
                    return line
                }
                .joined(separator: "\n")
            // hide_db yoksa sona ekle
            let hideDB = "$cfg['Servers'][$i]['hide_db'] = '^(information_schema|mysql|performance_schema|sys)$';"
            return patched.contains("hide_db") ? patched : patched + "\n\n" + hideDB + "\n"
        }

        switch result {
        case .written:     return true
        case .writeFailed: return false
        case .unreadable:  return false   // dosya VAR ama çözülemedi → ÜZERİNE YAZMA
        case .missing:     return FileHelper.write(VHostTemplates.phpmyadminLocalConfig(), to: path)
        }
    }

    /// MariaDB root@localhost kullanıcısını mysql_native_password auth ile yapılandırır.
    /// Homebrew MariaDB unix_socket auth kullanır; TCP bağlantısı için (phpMyAdmin, VS Code vb.) bu adım gereklidir.
    func configureMariaDBRoot() async {
        log(key: "log.svc.mariadbRootConfiguring", type: .info)
        let currentUser = NSUserName()

        let ping = await Shell.brewBashAsync("mysqladmin -u \(currentUser) ping 2>/dev/null || mysqladmin ping 2>/dev/null")
        let wasRunning = ping.output.contains("alive") || ping.isSuccess

        if !wasRunning {
            log(key: "log.svc.mariadbTempStarting", type: .info)
            _ = await Shell.brewBashAsync("\(Shell.brewBin) services run mariadb 2>&1")
            var started = false
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let check = await Shell.brewBashAsync("mysqladmin -u \(currentUser) ping 2>/dev/null || mysqladmin ping 2>/dev/null")
                if check.output.contains("alive") || check.isSuccess { started = true; break }
            }
            guard started else { log(key: "log.svc.mariadbStartFailed", type: .error); return }
            log(key: "log.svc.mariadbStarted", type: .success)
        }

        let sql = "GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('') WITH GRANT OPTION; FLUSH PRIVILEGES;"
        let fix = await Shell.brewBashAsync("mysql -u \(currentUser) -e \"\(sql)\" 2>&1")
        if fix.isSuccess || fix.exitCode == 0 {
            log(key: "log.svc.mariadbRootConfiguredTCP", type: .success)
        } else {
            let fix2 = await Shell.brewBashAsync("mysql -e \"\(sql)\" 2>&1")
            if fix2.isSuccess || fix2.exitCode == 0 {
                log(key: "log.svc.mariadbRootConfigured", type: .success)
            } else {
                log(key: "log.svc.mariadbRootConfigureFailed", args: [fix.error.isEmpty ? fix.output : fix.error], type: .error)
            }
        }

        if !wasRunning {
            _ = await Shell.brewBashAsync("\(Shell.brewBin) services stop mariadb 2>&1")
            log(key: "log.svc.mariadbTempStopped", type: .info)
        }
    }


    // MARK: - Adminer (tek dosyalı web DB yöneticisi)

    /// Adminer'i indirir (tek PHP dosyası, ~500 KB) ve HEM Apache HEM Nginx için
    /// yapılandırır. MySQL/MariaDB + PostgreSQL'i aynı arayüzden yönetir.
    func installAdminer() {
        // Kurulum durumu (isInstalling / installationLog / ptyController) TEKİLDİR.
        // İkinci bir akış aynı alanları ezer ve ilkini istemine yanıtsız bırakır.
        guard !isInstalling else {
            log(key: "log.svc.installBusy", args: [installationTitle], type: .warning); return
        }
        // PHP şart — Adminer bir PHP uygulaması
        let php = AppSettings.load().defaultPHPVersion
        guard php.isInstalled || PHPVersion.allCases.contains(where: { $0.isInstalled }) else {
            log(key: "log.svc.adminerNeedsPhp", type: .error)
            return
        }
        isInstalling      = true
        installationTitle = "Adminer Kuruluyor"
        installationLog   = "🚀 Adminer indiriliyor (tek dosya, ~500 KB)...\n\n"
        log(key: "log.svc.adminerInstalling", type: .command)

        Task {
            FileHelper.createDirectory(PathConfig.adminerDir)
            // adminer.org/latest.php → her zaman güncel tam sürüme (tüm sürücüler +
            // Türkçe dahil tüm diller) yönlenir. -f: HTTP hatasında dosya yazma.
            let r = await streamInstallLog(
                "curl -fSL -o \(Shell.quote(PathConfig.adminerFile)) https://www.adminer.org/latest.php 2>&1 && " +
                "echo '✅ İndirildi:' $(ls -lh \(Shell.quote(PathConfig.adminerFile)) | awk '{print $5}')"
            )
            // curl -f başarısızsa yarım/boş dosya bırakmış olabilir → SİL, aksi halde
            // isAdminerInstalled yanlışlıkla true olur ve bozuk kurulum "kurulu" görünür.
            guard r.isSuccess, FileHelper.exists(PathConfig.adminerFile) else {
                FileHelper.remove(PathConfig.adminerFile)
                lastRunSucceeded = false  // İndirme başarısız — yarım dosya silindi.
                isInstalling = false
                installationLog += "\n❌ İndirme başarısız — internet bağlantınızı kontrol edin.\n"
                log(key: "log.svc.adminerDownloadFailed", type: .error)
                refreshStatus()
                return
            }

            installationLog += "\n🔧 Web sunucuları yapılandırılıyor...\n"
            let apacheOK = await configureAdminerForApache()
            let nginxOK  = PathConfig.isNginxInstalled ? await configureAdminerForNginx() : true

            lastRunSucceeded = apacheOK && nginxOK
            isInstalling = false
            if apacheOK || nginxOK {
                installationLog += "\n✅ Adminer kuruldu!\n"
                if apacheOK { installationLog += "   Apache: https://localhost/adminer\n" }
                if PathConfig.isNginxInstalled && nginxOK { installationLog += "   Nginx : http://localhost:8080/adminer\n" }
                log(key: "log.svc.adminerInstalled", type: .success)
            } else {
                installationLog += "\n⚠️ Adminer indirildi ama web sunucusu yapılandırılamadı.\n"
                log(key: "log.svc.adminerWebServerConfigFailed", type: .warning)
            }
            refreshStatus()
        }
    }

    /// Adminer/phpMyAdmin config'lerinin kullanacağı PHP-FPM portu.
    /// Varsayılan sürüm kurulu DEĞİLSE, kurulu ilk sürümün portuna düşer —
    /// aksi halde config kurulu olmayan bir FPM portuna proxy'ler ve araç çalışmaz.
    private func effectivePHPPort() -> Int {
        let def = AppSettings.load().defaultPHPVersion
        if def.isInstalled { return def.port }
        return PHPVersion.allCases.first(where: { $0.isInstalled })?.port ?? def.port
    }

    @discardableResult
    func configureAdminerForApache() async -> Bool {
        guard FileHelper.exists(PathConfig.httpdConf) else {
            log(key: "log.svc.httpdConfMissing", type: .warning); return false
        }
        let confOK = FileHelper.write(VHostTemplates.adminerApacheConfig(phpPort: effectivePHPPort()),
                                      to: PathConfig.adminerConf)
        let includeOK = FileHelper.appendLineIfMissing(VHostTemplates.adminerIncludeConfig(),
                                                       to: PathConfig.httpdConf)
        log(key: confOK    ? "log.svc.adminerConfCreated"   : "log.svc.adminerConfWriteFailed", type: confOK    ? .success : .error)
        log(key: includeOK ? "log.svc.adminerIncludeAdded" : "log.svc.adminerIncludeFailed",   type: includeOK ? .success : .error)
        if confOK && includeOK { log(key: "log.svc.restartApacheHint", type: .info) }
        return confOK && includeOK
    }

    @discardableResult
    func configureAdminerForNginx() async -> Bool {
        guard FileHelper.exists(PathConfig.nginxConf) else {
            log(key: "log.svc.nginxConfMissing", type: .warning); return false
        }
        let ssl = NginxConfigManager.localhostSSLReady
        if NginxConfigManager.rewriteMainConfig(sslAvailable: ssl, adminerAvailable: true) {
            log(key: "log.svc.adminerNginxBlockAdded", type: .success)
            log(key: "log.svc.restartNginxHint", type: .info)
            return true
        } else {
            log(key: "log.svc.nginxConfWriteFailed", type: .error)
            return false
        }
    }

    /// Adminer'i tamamen kaldırır: dosya + Apache conf/include + Nginx bloğu.
    func uninstallAdminer() {
        log(key: "log.svc.adminerUninstalling", type: .command)
        Task {
            FileHelper.remove(PathConfig.adminerDir)
            FileHelper.remove(PathConfig.adminerConf)
            _ = await Shell.bashAsync(
                "sed -i '' '/IncludeOptional.*adminer\\.conf/d' \(Shell.quote(PathConfig.httpdConf)) 2>/dev/null"
            )
            if FileHelper.exists(PathConfig.nginxConf) {
                let ssl = NginxConfigManager.localhostSSLReady
                _ = NginxConfigManager.rewriteMainConfig(sslAvailable: ssl, adminerAvailable: false)
            }
            log(key: "log.svc.adminerUninstalled", type: .success)
            log(key: "log.svc.restartWebServersHint", type: .info)
            refreshStatus()
        }
    }

    // MARK: - PostgreSQL İlk Yapılandırma

    /// `postgresql.conf` içindeki dinleme portunu ayarlar (yorumlu `#port = 5432` dahil).
    /// Dosyanın ÖZGÜN kodlaması korunur; okunamıyorsa (ikili/bozuk) ÜZERİNE YAZILMAZ.
    /// - Returns: dosya gerçekten yazıldıysa `true`
    @discardableResult
    private func setPostgresPort(in confPath: String, port: Int) -> Bool {
        ConfigFileEditor.patch(confPath) { conf in
            var out = conf
            if out.contains("#port = 5432") {
                out = out.replacingOccurrences(of: "#port = 5432", with: "port = \(port)")
            } else if out.contains("port = 5432") && port != 5432 {
                out = out.replacingOccurrences(of: "port = 5432", with: "port = \(port)")
            } else if !out.contains("port = \(port)") {
                out += "\nport = \(port)\n"
            }
            return out
        } == .written
    }

    /// PostgreSQL için ilk yapılandırma:
    /// 1. pg_hba.conf → trust auth (yerel şifresiz erişim)
    /// 2. postgres superuser oluştur (boş şifre)
    /// 3. test veritabanı oluştur
    func configurePGInitial(version: String) {
        guard requireBrew(forKey: "log.op.pgConfigure", [version]) else { return }
        let pgPort      = services.first(where: { $0.id == "postgresql@\(version)" })?.port ?? 5432
        let dataDir     = PathConfig.pgDataDir(version: version)
        let currentUser = NSUserName()

        // Versiyonlu binary tam yolları — birden fazla PG kuruluysa doğru binary kullanılır
        let pgBin       = "\(Shell.brewPrefix)/opt/postgresql@\(version)/bin"
        let pgIsReady   = "\(pgBin)/pg_isready"
        let pgCtlBin    = "\(pgBin)/pg_ctl"
        let initdbBin   = "\(pgBin)/initdb"
        let psqlBin     = "\(pgBin)/psql"

        isInstalling      = true
        installationTitle = "PostgreSQL \(version) Başlangıç Yapılandırması"
        installationLog   = "🔧 PostgreSQL \(version) yapılandırılıyor...\n\n"
        log(key: "log.svc.pgInitialConfigStarted", args: [version], type: .command)

        Task {
            // 1. Servis çalışıyor mu? — versiyona özgü pg_isready kullan
            installationLog += "▶️ Bağlantı kontrol ediliyor (port:\(pgPort))...\n"
            let ping = await Shell.brewBashAsync("\(pgIsReady) -h 127.0.0.1 -p \(pgPort) 2>/dev/null")
            if !ping.isSuccess {
                // 1a. Data dizini var mı? Yoksa versiyona özgü initdb ile oluştur
                let pgHba = "\(dataDir)/pg_hba.conf"
                if !FileHelper.exists(pgHba) {
                    installationLog += "ℹ️ Veri dizini boş — initdb çalıştırılıyor (PG\(version))...\n"
                    let initR = await Shell.brewBashAsync(
                        "\(initdbBin) --locale=C -E UTF-8 \(dataDir) 2>&1"
                    )
                    installationLog += initR.isSuccess
                        ? "✅ Veri dizini oluşturuldu\n"
                        : "⚠️ initdb: \(initR.output.prefix(120))\n"
                    // port'u postgresql.conf'a yaz
                    if setPostgresPort(in: "\(dataDir)/postgresql.conf", port: pgPort) {
                        installationLog += "✅ postgresql.conf — port \(pgPort) ayarlandı\n"
                    }
                }

                // 1b. brew services run dene (launchd, login'de auto-start olmaz)
                installationLog += "ℹ️ PostgreSQL \(version) başlatılıyor (brew services)...\n"
                let brewStart = await Shell.brewBashAsync("\(Shell.brewBin) services run postgresql@\(version) 2>&1")
                var ready = false
                for _ in 0..<6 {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    let c = await Shell.brewBashAsync("\(pgIsReady) -h 127.0.0.1 -p \(pgPort) 2>/dev/null")
                    if c.isSuccess { ready = true; break }
                }

                // 1c. brew services başaramadıysa pg_ctl ile doğrudan başlat
                if !ready {
                    installationLog += "⚠️ brew services başaramadı"
                    if !brewStart.output.isEmpty { installationLog += ": \(brewStart.output.prefix(80))" }
                    installationLog += "\nℹ️ pg_ctl ile doğrudan başlatılıyor...\n"
                    let logFile = "/tmp/postgresql@\(version).log"
                    let pgctlR = await Shell.brewBashAsync(
                        "\(pgCtlBin) -D \(dataDir) -l \(logFile) start 2>&1"
                    )
                    installationLog += pgctlR.output.isEmpty ? "" : "  \(pgctlR.output.prefix(120))\n"
                    for _ in 0..<6 {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        let c = await Shell.brewBashAsync("\(pgIsReady) -h 127.0.0.1 -p \(pgPort) 2>/dev/null")
                        if c.isSuccess { ready = true; break }
                    }
                }

                if !ready {
                    installationLog += "❌ PostgreSQL başlatılamadı — yapılandırma durduruluyor\n"
                    installationLog += "💡 İpucu: Terminalde çalıştırın:\n"
                    installationLog += "   brew services stop postgresql@\(version) 2>/dev/null; brew services run postgresql@\(version)\n"
                    lastRunSucceeded = false  // İPTAL edilen akış başarı değildir; başlık yeşil tik gösteriyordu.
                    isInstalling = false
                    log(key: "log.svc.pgStartFailed", args: [version], type: .error)
                    return
                }
                installationLog += "✅ PostgreSQL \(version) başlatıldı\n"
            } else {
                installationLog += "✅ PostgreSQL \(version) hazır\n"
            }

            // 2. pg_hba.conf — trust auth
            installationLog += "\n▶️ pg_hba.conf — trust auth yapılandırılıyor...\n"
            let hbaPath = "\(dataDir)/pg_hba.conf"
            var hbaAlreadyTrusted = false
            // Dosyanın ÖZGÜN kodlaması korunur; okunamıyorsa üzerine YAZILMAZ.
            let hbaResult = ConfigFileEditor.patch(hbaPath) { hba in
                guard !hba.contains("# BRAMPP local dev") else { hbaAlreadyTrusted = true; return hba }
                let trustBlock =
                    "# BRAMPP local dev — trust auth (şifresiz yerel erişim)\n" +
                    "local   all             all                                     trust\n" +
                    "host    all             all             127.0.0.1/32            trust\n" +
                    "host    all             all             ::1/128                 trust\n\n"
                let lines = hba.components(separatedBy: .newlines).map { line -> String in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    guard !t.hasPrefix("#"), !t.isEmpty, t.hasPrefix("local") || t.hasPrefix("host") else { return line }
                    return "# " + line
                }
                return trustBlock + lines.joined(separator: "\n")
            }

            if hbaAlreadyTrusted {
                installationLog += "ℹ️ pg_hba.conf zaten trust auth içeriyor\n"
            } else {
                switch hbaResult {
                case .written:
                    installationLog += "✅ pg_hba.conf güncellendi (trust auth aktif)\n"
                    // pg_reload_conf — versiyona özgü psql kullan
                    _ = await Shell.brewBashAsync("\(psqlBin) -U \(currentUser) -p \(pgPort) postgres -c 'SELECT pg_reload_conf();' 2>/dev/null")
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    installationLog += "✅ PostgreSQL yapılandırması yeniden yüklendi\n"
                case .writeFailed:
                    installationLog += "❌ pg_hba.conf yazılamadı\n"
                case .missing:
                    installationLog += "⚠️ pg_hba.conf bulunamadı: \(hbaPath)\n"
                case .unreadable:
                    installationLog += "⚠️ pg_hba.conf okunamadı (bozuk kodlama?) — dokunulmadı: \(hbaPath)\n"
                }
            }

            // 3. postgres superuser oluştur + boş şifre
            installationLog += "\n▶️ postgres süper kullanıcı oluşturuluyor...\n"
            let createSQL = """
            DO \\$\\$ BEGIN
              IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'postgres') THEN
                CREATE ROLE postgres SUPERUSER CREATEDB CREATEROLE LOGIN;
              ELSE
                ALTER ROLE postgres SUPERUSER CREATEDB CREATEROLE LOGIN;
              END IF;
            END \\$\\$;
            """
            let roleR = await Shell.brewBashAsync("\(psqlBin) -U \(currentUser) -p \(pgPort) postgres -c \"\(createSQL)\" 2>&1")
            installationLog += (roleR.isSuccess || roleR.output.contains("DO"))
                ? "✅ postgres rolü oluşturuldu/güncellendi\n"
                : "⚠️ Rol: \(roleR.output.prefix(120))\n"

            let passR = await Shell.brewBashAsync("\(psqlBin) -U \(currentUser) -p \(pgPort) postgres -c \"ALTER USER postgres PASSWORD '';\" 2>&1")
            installationLog += (passR.isSuccess || passR.output.contains("ALTER"))
                ? "✅ postgres şifresi boş olarak ayarlandı\n"
                : "⚠️ Şifre: \(passR.output.prefix(120))\n"

            // 4. test DB oluştur
            installationLog += "\n▶️ test veritabanı kontrol ediliyor...\n"
            let checkDB = await Shell.brewBashAsync("\(psqlBin) -U \(currentUser) -p \(pgPort) postgres -tc \"SELECT 1 FROM pg_database WHERE datname='test'\" 2>/dev/null")
            if checkDB.output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("1") {
                installationLog += "ℹ️ test veritabanı zaten mevcut\n"
            } else {
                let createDB = await Shell.brewBashAsync("\(psqlBin) -U \(currentUser) -p \(pgPort) postgres -c \"CREATE DATABASE test OWNER postgres;\" 2>&1")
                installationLog += (createDB.isSuccess || createDB.output.contains("CREATE"))
                    ? "✅ test veritabanı oluşturuldu (sahibi: postgres)\n"
                    : "⚠️ DB: \(createDB.output.prefix(120))\n"
            }

            // Özet
            installationLog += """

            ══════════════════════════════════════════
              🎉 PostgreSQL \(version) yapılandırması tamamlandı!
              Host      : 127.0.0.1
              Port      : \(pgPort)
              Kullanıcı : postgres
              Şifre     : (boş)
              Veritabanı: test
            ══════════════════════════════════════════
            """

            lastRunSucceeded = true
            isInstalling = false
            log(key: "log.svc.pgInitialConfigDone", args: [version], type: .success)
            refreshStatus()
        }
    }

    // MARK: - Install Log Streaming

    /// PTY komutunu çalıştırır; çıktıyı `installationLog`'a gerçek zamanlı yazar.
    ///
    /// **Progress satırı desteği:** brew/curl `\r` (carriage return) ile aynı satırı
    /// sürekli günceller (indirme yüzdesi, `########` barı).
    /// `onProgress` callback'i bu ara güncellemeleri alır ve son log satırını yerine
    /// değiştirerek "canlı progress" efekti sağlar.
    /// `onLine` callback'i ise progress dizisinin son halini (100%) ve diğer tüm
    /// normal satırları alarak bunları kalıcı log satırı olarak ekler.
    ///
    /// - Parameter command: Çalıştırılacak kabuk komutu (zaten PTY-sarmalı olmalı)
    /// - Returns: `Shell.Result`
    @discardableResult
    private func streamInstallLog(_ command: String) async -> Shell.Result {
        _installProgressLine = ""
        let controller = Shell.PTYController()
        ptyController = controller

        let r = await Shell.streamBashPTY(command, controller: controller) { [weak self] line in
            guard let self else { return }
            let clean = ServiceManager.stripANSI(line)
            if !self._installProgressLine.isEmpty {
                // Progress satırının SON hali geldi — log'daki geçici progress'i değiştir
                self.installationLog = String(
                    self.installationLog.dropLast(self._installProgressLine.count)
                ) + clean + "\n"
                self._installProgressLine = ""
            } else if !clean.isEmpty {
                self.installationLog += clean + "\n"
            }
            // Not: İstem durumu artık burada temizlenmiyor. sendInstallInput() ve otomatik
            // onay görevi zaten clearAwaitingInput() çağırır. Buradaki temizleme, istemi açan
            // aynı PTY parçasında gelen ÖNCEKİ satır tarafından yanlış tetiklenip kurulumu
            // asıyordu (istem çubuğu anında kapanıyor, 'y' hiç gönderilmiyordu).
        } onProgress: { [weak self] progress in
            guard let self else { return }
            // \r ile güncellenen ara progress parçası
            let clean = ServiceManager.stripANSI(progress)
            guard !clean.isEmpty else { return }
            if self._installProgressLine.isEmpty {
                // İlk progress chunk'ı — log'a ekle (henüz \n yok → satır "açık")
                self.installationLog += clean
            } else {
                // Log'un sonundaki eski progress metnini yenisiyle değiştir
                self.installationLog = String(
                    self.installationLog.dropLast(self._installProgressLine.count)
                ) + clean
            }
            self._installProgressLine = clean
        } onPrompt: { [weak self] prompt in
            self?.handleInstallPrompt(prompt)
        }

        // Komut bitişinde açık kalan progress satırını kapat + istem durumunu temizle
        if !_installProgressLine.isEmpty {
            installationLog += "\n"
            _installProgressLine = ""
        }
        clearAwaitingInput()
        ptyController = nil
        return r
    }

    // MARK: - Kurulum İstemi Yönetimi

    /// brew "proceed? [y/N]" sorduğunda çağrılır — UI girdi alanını açar, zaman aşımı sayacını başlatır.
    private func handleInstallPrompt(_ prompt: String) {
        guard !isAwaitingInput else { return }   // aynı istem için tek sefer
        isAwaitingInput = true
        currentPrompt = prompt

        let settings = AppSettings.load()
        guard settings.installPromptAutoConfirm else {
            autoConfirmCountdown = 0
            return
        }
        let secs = max(1, settings.installPromptAutoConfirmSeconds)
        autoConfirmCountdown = secs
        autoConfirmTask?.cancel()
        autoConfirmTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.isAwaitingInput else { return }
                self.autoConfirmCountdown -= 1
                if self.autoConfirmCountdown <= 0 { break }
            }
            guard let self, self.isAwaitingInput else { return }
            self.log(key: "log.svc.autoConfirmSent", args: ["\(secs)"], type: .info)
            self.sendInstallInput("y")
        }
    }

    /// Kullanıcı (veya zaman aşımı) tarafından kuruluma girdi gönderir.
    func sendInstallInput(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        ptyController?.send(trimmed.isEmpty ? "y" : trimmed)
        if !trimmed.isEmpty {
            installationLog += "> \(trimmed)\n"
        }
        clearAwaitingInput()
    }

    /// İstem durumunu temizler ve geri sayım görevini iptal eder.
    private func clearAwaitingInput() {
        autoConfirmTask?.cancel()
        autoConfirmTask = nil
        if isAwaitingInput { isAwaitingInput = false }
        currentPrompt = ""
        autoConfirmCountdown = 0
    }

    /// ANSI / terminal kontrol kodlarını temizler.
    /// PTY çıktısında ek sekanslar bulunur (cursor hide/show, erase-line vb.)
    nonisolated static func stripANSI(_ text: String) -> String {
        // CSI sekansları: ESC [ [0-9;?]* <harf>  (? → cursor hide/show gibi parametreler)
        // Character-set: ESC ( B
        // OSC sekansları: ESC ] ... BEL veya ESC \
        // Backspace silme zincirleri: \x08+
        // Carriage return: \r
        let pattern = #"\x1B(?:\[[0-9;?]*[A-Za-z@`]|\(B|\].*?(?:\x07|\x1B\\))|\x08+|\r"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
    }

    // MARK: - Uninstallation

    func uninstallService(_ service: Service) {
        guard requireBrew(forKey: "log.op.serviceUninstall", [service.name]) else { return }
        // Kurulum durumu (isInstalling / installationLog / ptyController) TEKİLDİR.
        // İkinci bir akış aynı alanları ezer ve ilkini istemine yanıtsız bırakır.
        guard !isInstalling else {
            log(key: "log.svc.installBusy", args: [installationTitle], type: .warning); return
        }
        guard let i = services.firstIndex(where: { $0.id == service.id }) else { return }

        let brewName = service.brewName ?? service.id
        let script = Self.uninstallScript(serviceID: service.id,
                                          serviceName: service.name,
                                          brewName: brewName,
                                          brewPrefix: Shell.brewPrefix,
                                          port: service.port)

        // Script'i geçici dosyaya yaz, PTY ile çalıştır → InstallationProgressSheet'te göster
        let tmpPath = NSTemporaryDirectory() + "brampp_uninstall_\(UUID().uuidString).sh"
        guard (try? script.write(toFile: tmpPath, atomically: true, encoding: .utf8)) != nil else {
            log(key: "log.svc.uninstallScriptFailed", args: [service.name], type: .error); return
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpPath)

        services[i].isLoading = true
        isInstalling           = true
        installationTitle      = "\(service.name) Kaldırılıyor"
        installationLog        = "🗑️ \(service.name) kaldırma başlatılıyor...\n\n"
        log(key: "log.svc.uninstalling", args: [service.name], type: .command)

        Task {
            let r = await streamInstallLog("/bin/bash '\(tmpPath)'")
            try? FileManager.default.removeItem(atPath: tmpPath)

            services[i].isLoading = false
            isInstalling          = false

            if r.isSuccess {
                // Not: Başarı mesajını script zaten sonda basıyor ve log akışıyla pencereye
                // düşüyor — burada tekrar eklersek "başarıyla kaldırıldı" İKİ kez görünür.
                log(key: "log.svc.uninstalled", args: [service.name], type: .success)
            } else {
                installationLog += "\n❌ Kaldırma başarısız (Hata kodu: \(r.exitCode))\n"
                if !r.error.isEmpty { installationLog += r.error + "\n" }
                log(key: "log.svc.uninstallFailed", args: [service.name, r.error], type: .error)
            }
            refreshStatus()
        }
    }

    /// Kaldırma betiği — SAF metin üretimi (dosya sistemine dokunmaz, testlerden çağrılır).
    ///
    /// Betiğin `rm -rf` ettiği HER yol `uninstallPlan(...).allPaths` içinden, `sed -i ''`
    /// ile düzenlediği her dosya `editedPaths` içinden gelir. Kaynak tek olduğu için
    /// betikle onay diyaloğu AYRIŞAMAZ; testler de bunu betiğin metni üzerinde doğrular
    /// (planı planla karşılaştıran eski test hiçbir sapmayı göremezdi).
    static func uninstallScript(serviceID: String, serviceName: String,
                                brewName: String, brewPrefix base: String,
                                port: Int? = nil) -> String {
        let plan = uninstallPlan(forServiceID: serviceID, brewPrefix: base)
        let cleanupPaths = uninstallCleanupPaths(forServiceID: serviceID, brewPrefix: base)

        let pathEchos = cleanupPaths.isEmpty
            ? "  echo \"  (temizlenecek config yok)\""
            : cleanupPaths.map { "  echo \"  \($0)\"" }.joined(separator: "\n")

        // Sonuç yola göre AYRI raporlanır ve başarısızlık bayraklanır.
        // Eskiden `rm -rf "yol" && echo "Silindi"` yazıyordu: `&&` yüzünden başarısız
        // silme sessizce geçiliyor, betik sonunda yine "başarıyla kaldırıldı" diyordu.
        // MariaDB'de bu, veri dizini DURUYORKEN kullanıcının silindiğini sanması demek.
        // `[ -e ]` denetimi de şart: onsuz var olmayan bir yol için "Silindi" yazılırdı.
        let rmCommands = cleanupPaths.isEmpty
            ? "echo \"  (temizlenecek config yok)\""
            : cleanupPaths.map { p in
                """
                if [ -e "\(p)" ]; then
                  if rm -rf "\(p)"; then echo "  ✅ Silindi: \(p)"
                  else echo "  ❌ SİLİNEMEDİ: \(p)"; CLEANUP_FAILED=1; fi
                else
                  echo "  ➖ Zaten yok: \(p)"
                fi
                """
            }.joined(separator: "\n")

        // Korunan kullanıcı verisi (vhost'lar) — silinmediği AÇIKÇA bildirilir
        let preservedPaths = plan.preservedPaths
        let preservedNote = preservedPaths.isEmpty ? "" : """

        echo "🛡  Yapılandırmalarınız korundu (silinmedi):"
        \(preservedPaths.map { "echo \"  \($0)\"" }.joined(separator: "\n"))
        echo "   Paketi tekrar kurduğunuzda alan adlarınız yerinde olacak."
        echo ""
        """

        // ── Durdurma ve kaldırma komutları ────────────────────────────────
        // Tüm servisler Homebrew — launchctl remove ile durdur, brew uninstall ile kaldır
        // Durdurmak YETMEZ, durduğunu DOĞRULAMAK gerekir. `brew services stop`
        // launchd'ye isteği bırakır ve hemen döner; MariaDB'nin düzgün kapanması
        // saniyeler sürebilir. Veri dizini sunucu hâlâ yazarken silinirse, silme
        // yarım kalır ve geriye tutarsız dosyalar kalır — üstelik o an alınmış bir
        // yedek de bozuk olur. Port hâlâ dinleniyorsa kaldırmaya HİÇ girilmez.
        let portGuard = port.map { p in """

        echo "   Servisin gerçekten durduğu doğrulanıyor (port \(p))..."
        STOPPED=0
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            if ! nc -z 127.0.0.1 \(p) >/dev/null 2>&1; then STOPPED=1; break; fi
            sleep 1
        done
        if [ "$STOPPED" != "1" ]; then
            echo ""
            echo "❌ \(serviceName) 10 saniyede durmadı — port \(p) hâlâ dinleniyor."
            echo "   Veri dizini SİLİNMEDİ: çalışan bir sunucunun altından dosya çekmek"
            echo "   geriye tutarsız bir veri dizini bırakır. Servisi durdurup tekrar deneyin."
            exit 1
        fi
        echo "   ✓ durdu"
""" } ?? ""
        let stopCmd = "brew services stop \(brewName) 2>/dev/null || true" + portGuard
        let uninstallCmd   = "brew uninstall --force \(brewName)"
        let packageLabel   = "Paket   : \(brewName)"
        let autoremoveBlock = """

        echo "🧹 Kullanılmayan bağımlılıklar temizleniyor..."
        brew autoremove
        echo ""
        """
        // ─────────────────────────────────────────────────────────────────

        // MariaDB kaldırılıyorsa phpMyAdmin da kaldır. Web kökünün (`share/phpmyadmin`)
        // `rm -rf`i artık burada DEĞİL, planın ortak temizlik listesinde — diyalog da
        // ancak orada olan yolları gösterebiliyor.
        let phpmyadminExtra: String
        if serviceID == "mariadb" {
            // Düzenlenen dosya plandan gelir; betiğe gömülü ikinci bir yol kalmasın.
            let httpdConf = plan.editedPaths.first ?? PathConfig.Brew.httpdConf(base)
            phpmyadminExtra = """

        if brew list phpmyadmin >/dev/null 2>&1; then
            echo "🗑️  phpMyAdmin da kaldırılıyor (MariaDB bağımlılığı)..."
            brew services stop phpmyadmin 2>/dev/null || true
            brew uninstall --force phpmyadmin
            echo "  ✅ phpMyAdmin kaldırıldı"
        fi

        echo "🧹 httpd.conf'tan phpMyAdmin include satırı kaldırılıyor..."
        sed -i '' '/IncludeOptional.*phpmyadmin\\.conf/d' "\(httpdConf)" 2>/dev/null && echo "  ✅ Include satırı kaldırıldı" || true
        """
        } else {
            phpmyadminExtra = ""
        }

        // Node.js: npm global cache; Python: pip cache
        let runtimeExtra: String
        if serviceID.hasPrefix("node@") {
            runtimeExtra = """

        echo "🧹 npm cache temizleniyor..."
        npm cache clean --force 2>/dev/null || true
        echo ""
        """
        } else if serviceID.hasPrefix("python@") {
            let ver = serviceID.replacingOccurrences(of: "python@", with: "")
            runtimeExtra = """

        echo "🧹 pip cache temizleniyor..."
        python\(ver) -m pip cache purge 2>/dev/null || true
        echo ""
        """
        } else {
            runtimeExtra = ""
        }

        return """
        #!/bin/bash
        export PATH="\(base)/bin:\(base)/sbin:$PATH"
        export HOMEBREW_NO_AUTO_UPDATE=1

        echo "══════════════════════════════════════════════════"
        echo "  🗑️  \(serviceName) Kaldırılıyor"
        echo "══════════════════════════════════════════════════"
        echo ""
        echo "  \(packageLabel)"
        \(pathEchos)
        echo ""

        echo "🛑 Servis durduruluyor..."
        \(stopCmd)
        echo ""
        \(runtimeExtra)
        echo "🗑️  Paket kaldırılıyor..."
        # `brew uninstall --force` paket ZATEN yokken de 0 döner: çıkış kodu tek
        # başına "kaldırıldı" demek değil. Muhafızın ölçtüğü şey, veri dosyalarına
        # dokunmadan önce paketin gerçekten gitmiş olması.
        if ! \(uninstallCmd); then
            echo ""
            echo "❌ brew uninstall başarısız — config ve veri dosyalarına DOKUNULMADI."
            echo "   Sorunu giderdikten sonra tekrar deneyin."
            exit 1
        fi
        if brew list --formula \(brewName) >/dev/null 2>&1; then
            echo ""
            echo "❌ \(brewName) hâlâ kurulu görünüyor — config ve veri dosyalarına DOKUNULMADI."
            exit 1
        fi
        echo ""

        echo "🗑️  Config & kütüphane dosyaları temizleniyor..."
        CLEANUP_FAILED=0
        \(rmCommands)
        echo ""
        \(preservedNote)
        \(phpmyadminExtra)
        \(autoremoveBlock)
        if [ "$CLEANUP_FAILED" = "1" ]; then
            echo "⚠️  \(serviceName) kaldırıldı ama YUKARIDA ❌ ile işaretli yollar silinemedi."
            echo "   O dosyalar diskte duruyor; elle silmeniz gerekebilir."
            exit 1
        fi
        echo "✅ \(serviceName) başarıyla kaldırıldı!"
        """
    }

    /// Betiğin `rm -rf` edeceği yollar — SIRA korunur (çıktıdaki liste bu sırayla basılır).
    /// Sınıflandırma `UninstallPlan`da; burada yalnızca düzleştirilir.
    ///
    /// `private` DEĞİL: "betik yalnızca planın yollarını siler" değişmezini testin
    /// gerçekten ölçebilmesi için görünür olmalı (eski test planı planla karşılaştırıyordu).
    static func uninstallCleanupPaths(forServiceID id: String, brewPrefix base: String) -> [String] {
        uninstallPlan(forServiceID: id, brewPrefix: base).allPaths
    }

    /// Bir servisi kaldırmanın neye mal olacağı — **TEK KAYNAK**.
    ///
    /// Onay diyaloğu (`ServicesTabView`) ve kaldırma betiği AYNI listeden üretilir.
    /// Ayrı iki liste tutulduğu sürece diyalog "paket ve yapılandırma dosyaları silinecek"
    /// derken betik `var/mysql` altındaki bütün veritabanlarını siliyordu; kullanıcı ne
    /// kaybettiğini ancak silindikten sonra, log akışında görüyordu.
    ///
    /// Saf: yalnızca servis kimliğine ve verilen Homebrew önekine bakar; dosya sistemine
    /// DOKUNMAZ ve `Shell.brewPrefix` okumaz. Yol formülleri `PathConfig.Brew` altındadır
    /// (tek tanım orada; `PathConfig` sabitleri de aynı formülleri kullanır) — böylece
    /// birim testler hayalî bir önekle çalışır, `brew --prefix` çağırmaz.
    /// Üretimdeki çağrı — Homebrew önekiyle. (Varsayılan parametre DEĞİL: varsayılan
    /// ifade yalıtımsız bağlamda çözülür ve `Shell.brewPrefix` erişimi uyarı üretir.)
    static func uninstallPlan(forServiceID id: String) -> UninstallPlan {
        uninstallPlan(forServiceID: id, brewPrefix: Shell.brewPrefix)
    }

    static func uninstallPlan(forServiceID id: String, brewPrefix base: String) -> UninstallPlan {
        func plan(_ paths: [UninstallPath], edited: [String] = [], preserved: [String] = []) -> UninstallPlan {
            UninstallPlan(serviceID: id, paths: paths, editedPaths: edited, preservedPaths: preserved)
        }

        switch id {
        case "httpd":
            // DİKKAT: `etc/httpd` dizininin TAMAMI silinemez — `VirtualHosts/` altında
            // kullanıcının TÜM alan adı yapılandırmaları durur. Yalnızca paketin/BRAMPP'ın
            // ürettiği dosyalar temizlenir; vhost'lar olduğu gibi kalır.
            return plan([
                .config(PathConfig.Brew.httpdConf(base)),      // etc/httpd/httpd.conf
                .config(PathConfig.Brew.httpdSSLConf(base)),   // etc/httpd/extra/httpd-ssl.conf
                .config(PathConfig.Brew.phpmyadminConf(base)), // etc/httpd/extra/phpmyadmin.conf
                .config(PathConfig.Brew.adminerConf(base))     // etc/httpd/extra/adminer.conf
            ], preserved: [PathConfig.Brew.vhostsDir(base)])
        case "nginx":
            // Aynı gerekçe: `sites-available/` kullanıcının domain bloklarını barındırır.
            return plan([.config(PathConfig.Brew.nginxConf(base))],   // etc/nginx/nginx.conf
                        preserved: [PathConfig.Brew.nginxSitesAvailableDir(base)])
        case "mariadb":
            // phpMyAdmin config dosyaları da temizle (brew package ayrı kaldırılır).
            // `share/phpmyadmin` ve httpd.conf düzenlemesi eskiden PLANIN DIŞINDA,
            // doğrudan betiğe gömülüydü — diyalog ikisini de hiç anmıyordu.
            return plan([
                .config("\(base)/etc/my.cnf"),
                // VERİ: kullanıcının TÜM veritabanları burada. Kaldırma bunu siler.
                .data("\(base)/var/mysql"),
                .config(PathConfig.Brew.phpmyadminConf(base)),
                .config(PathConfig.Brew.phpmyadminAppConfig(base)),
                // phpMyAdmin web kökü — paket MariaDB ile birlikte kaldırılır
                .config(PathConfig.Brew.phpmyadminDir(base))
            ], edited: [PathConfig.Brew.httpdConf(base)])   // phpMyAdmin include satırı çıkarılır
        case "redis":
            // Yalnızca config: `var/db/redis` altındaki dump.rdb'ye DOKUNULMAZ.
            return plan([.config("\(base)/etc/redis.conf")])
        case "memcached":
            return plan([])
        default:
            if id.hasPrefix("php@") {
                let ver = id.replacingOccurrences(of: "php@", with: "")
                return plan([.config("\(base)/etc/php/\(ver)")])
            }
            if id.hasPrefix("postgresql@") {
                let ver = id.replacingOccurrences(of: "postgresql@", with: "")
                return plan([
                    .config("\(base)/etc/postgresql@\(ver)"),
                    // VERİ: kümenin TAMAMI (initdb ile üretilen data directory).
                    .data("\(base)/var/postgresql@\(ver)")
                ])
            }
            if id.hasPrefix("node@") {
                let ver = id.replacingOccurrences(of: "node@", with: "")
                // DİKKAT: lib/node_modules ve include/node PAYLAŞILANDIR — ana `node` formülünün
                // npm'i ve kullanıcının tüm global paketleri (yarn, pm2 vb.) orada durur.
                // Yalnızca sürüme özgü opt dizini temizlenir.
                return plan([
                    .config("\(base)/opt/node@\(ver)"),          // brew opt dizini (sürüme özgü)
                ])
            }
            if id.hasPrefix("python@") {
                let ver = id.replacingOccurrences(of: "python@", with: "")
                let major = ver.components(separatedBy: ".").prefix(2).joined(separator: ".")
                return plan([
                    .config("\(base)/opt/python@\(ver)"),                      // brew opt dizini
                    // VERİ: site-packages — kullanıcının pip ile kurduğu HER ŞEY.
                    // `lib/pythonX.Y` Framework içindeki dizine bağdır; ikisi de aynı içeriği
                    // gösterir, ikisi de siliniyor.
                    .data("\(base)/lib/python\(major)"),                       // site-packages
                    .data("\(base)/Frameworks/Python.framework/Versions/\(major)"),
                ])
            }
            if id.hasPrefix("dotnet@") {
                return plan([
                    .config("\(base)/opt/\(id)"),          // brew opt: opt/dotnet@7
                    .config("\(base)/share/dotnet/\(id)"), // SDK paylaşımlı kaynaklar
                ])
            }
            return plan([])
        }
    }

    func services(for category: ServiceCategory) -> [Service] {
        services.filter { $0.category == category }
    }

    // MARK: - Private

    // MARK: - Apache Port Config

    func currentApacheHTTPPort() -> Int { Self.readApacheHTTPPort() ?? 80 }
    func currentApacheHTTPSPort() -> Int { readApacheHTTPSPort() ?? 443 }

    func updateApachePorts(http: Int, https: Int) {
        let oldHTTP  = Self.readApacheHTTPPort()  ?? 80
        let oldHTTPS = readApacheHTTPSPort() ?? 443

        Task {
            // Yazımdan ÖNCE config zaten geçerli miydi? Değilse bozulmayı bize atfetmez,
            // geri de almayız (DomainManager.createVHostConfigResult ile aynı desen).
            let wasValid = await apacheConfigValid()

            // Geri alma için dokunulan her dosyanın ÖZGÜN hâli (içerik + kodlama)
            var originals: [String: (text: String, enc: String.Encoding)] = [:]

            /// Dosyayı oku → dönüştür → AYNI kodlamayla yaz. Okunamıyorsa DOKUNMAZ.
            @MainActor
            func patch(_ path: String, _ transform: (String) -> String) -> ConfigFileEditor.Result {
                switch FileHelper.readStringDetailed(path) {
                case .missing:    return .missing
                case .unreadable: return .unreadable
                case .ok(let text, let enc):
                    let updated = transform(text)
                    guard updated != text else { return .written }   // değişiklik yok
                    originals[path] = (text, enc)
                    return FileHelper.write(updated, to: path, encoding: enc) ? .written : .writeFailed
                }
            }

            // 1) httpd.conf — HTTP Listen (satır bazlı: "Listen 80", "Listen 0.0.0.0:80"
            //    desteklenir; düz substring değişimi "Listen 8080" gibi satırları bozar)
            switch patch(PathConfig.httpdConf, { replaceApacheListenLines(in: $0, oldPort: oldHTTP, newPort: http) }) {
            case .written:      log(key: "log.svc.apacheHttpPortUpdated", args: ["\(http)"], type: .success)
            case .writeFailed:  log(key: "log.svc.httpdConfWriteFailed", type: .error)
            case .missing:      log(key: "log.svc.httpdConfMissing", type: .error)
            case .unreadable:   log(key: "log.svc.httpdConfReadFailed", type: .error)
            }

            // 2) httpd-ssl.conf — HTTPS Listen + <VirtualHost _default_:443>
            switch patch(PathConfig.httpdSSLConf, { text in
                var out = replaceApacheListenLines(in: text, oldPort: oldHTTPS, newPort: https)
                out = replaceApacheVHostPorts(in: out, oldHTTP: oldHTTP, oldHTTPS: oldHTTPS,
                                              newHTTP: http, newHTTPS: https)
                return out
            }) {
            case .written:      log(key: "log.svc.apacheHttpsPortUpdated", args: ["\(https)"], type: .success)
            case .writeFailed:  log(key: "log.svc.httpdSslConfWriteFailed", type: .error)
            case .missing, .unreadable: break   // SSL yapılandırılmamış olabilir — sessiz geç
            }

            // 3) VirtualHosts/*.conf — alan adı vhost'ları.
            //    Bu adım OLMADAN port değişince <VirtualHost *:eskiPort> eski portta kalır
            //    ve TÜM alan adları erişilemez olurdu (Nginx tarafında bu dönüşüm zaten vardı).
            var vhostCount = 0
            if oldHTTP != http || oldHTTPS != https {
                for file in FileHelper.contentsOfDirectory(PathConfig.vhostsDir) where file.hasSuffix(".conf") {
                    let path = "\(PathConfig.vhostsDir)/\(file)"
                    let r = patch(path) { replaceApacheVHostPorts(in: $0, oldHTTP: oldHTTP, oldHTTPS: oldHTTPS,
                                                                 newHTTP: http, newHTTPS: https) }
                    if r == .written, originals[path] != nil { vhostCount += 1 }
                }
            }
            if vhostCount > 0 {
                log(key: "log.svc.apacheVhostPortsUpdated", args: ["\(vhostCount)"], type: .success)
            }

            // 4) Doğrula — bozduysak HER ŞEYİ geri al (yarım yamalanmış config Apache'yi
            //    hiç başlatmaz; kullanıcı tüm sitelerini kaybederdi).
            if wasValid, !(await apacheConfigValid()) {
                for (path, orig) in originals {
                    _ = FileHelper.write(orig.text, to: path, encoding: orig.enc)
                }
                log(key: "log.svc.apachePortsRolledBack", type: .error)
                refreshStatus()
                return
            }

            restartApache()
            refreshStatus()
        }
    }

    /// `apachectl configtest` — config sözdizimi geçerli mi?
    private func apacheConfigValid() async -> Bool {
        let r = await Shell.bashAsync("\(Shell.brewPrefix)/bin/apachectl configtest 2>&1")
        return r.isSuccess || r.output.contains("Syntax OK")
    }

    /// `<VirtualHost *:80>` / `<VirtualHost _default_:443>` etiketlerini ve bunlara bağlı
    /// `ServerName host:port` + `Redirect … https://host:port/` satırlarını yeni portlara taşır.
    /// Tek geçiş: yeni HTTP portu eski HTTPS portuna eşit olsa bile ikinci bir dönüşüm olmaz.
    private func replaceApacheVHostPorts(in content: String, oldHTTP: Int, oldHTTPS: Int,
                                         newHTTP: Int, newHTTPS: Int) -> String {
        func mapped(_ port: Int) -> Int? {
            if port == oldHTTP  { return newHTTP }
            if port == oldHTTPS { return newHTTPS }
            return nil
        }

        return content.components(separatedBy: .newlines).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            let lower = t.lowercased()

            // <VirtualHost *:80>  ·  <VirtualHost _default_:443>  ·  <VirtualHost 127.0.0.1:80>
            if lower.hasPrefix("<virtualhost"), t.hasSuffix(">"),
               let colon = t.range(of: ":", options: .backwards),
               let port  = Int(t[colon.upperBound..<t.index(before: t.endIndex)]),
               let new   = mapped(port), new != port {
                return line.replacingOccurrences(of: ":\(port)>", with: ":\(new)>")
            }

            // ServerName localhost:443 → yalnızca port kısmı güncellenir
            if lower.hasPrefix("servername"),
               let colon = t.range(of: ":", options: .backwards),
               let port  = Int(t[colon.upperBound...]),
               let new   = mapped(port), new != port {
                return line.replacingOccurrences(of: ":\(port)", with: ":\(new)")
            }

            // Redirect permanent / https://domain:8443/ → yeni HTTPS portu (443'te port eki düşer)
            if lower.hasPrefix("redirect"), newHTTPS != oldHTTPS {
                return retargetHTTPSAuthority(line, oldHTTPS: oldHTTPS, newHTTPS: newHTTPS)
            }
            return line
        }.joined(separator: "\n")
    }

    /// Satırdaki ilk `https://host[:port]` yetkisini yeni HTTPS portuna göre yeniden yazar.
    /// Eski port standart 443 olduğu için hiç yazılmamışsa da (port eki yok) ele alınır.
    private func retargetHTTPSAuthority(_ line: String, oldHTTPS: Int, newHTTPS: Int) -> String {
        guard let scheme = line.range(of: "https://") else { return line }
        let rest   = line[scheme.upperBound...]
        let endIdx = rest.firstIndex(where: { $0 == "/" || $0 == " " || $0 == "\t" || $0 == "\"" }) ?? rest.endIndex
        let authority = String(rest[..<endIdx])

        var host = authority
        var port: Int?
        if let colon = authority.range(of: ":", options: .backwards),
           let p = Int(authority[colon.upperBound...]) {
            host = String(authority[..<colon.lowerBound])
            port = p
        }
        guard !host.isEmpty, port == oldHTTPS || (port == nil && oldHTTPS == 443) else { return line }

        let newAuthority = host + WebServerPorts.portSuffix(newHTTPS, https: true)
        return line.replacingCharacters(in: scheme.upperBound..<endIdx, with: newAuthority)
    }

    /// Apache `Listen` satırlarını satır bazlı günceller — yalnızca port değeri tam eşleşirse.
    /// "Listen 80", "Listen 0.0.0.0:80", "Listen 127.0.0.1:80" biçimlerini destekler.
    private func replaceApacheListenLines(in content: String, oldPort: Int, newPort: Int) -> String {
        content.components(separatedBy: .newlines).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), t.lowercased().hasPrefix("listen ") else { return line }
            var comps = t.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard comps.count >= 2 else { return line }
            let value = comps[1]
            if let colon = value.range(of: ":", options: .backwards) {
                let host = String(value[..<colon.lowerBound])
                if Int(value[colon.upperBound...]) == oldPort {
                    comps[1] = "\(host):\(newPort)"
                    return comps.joined(separator: " ")
                }
            } else if Int(value) == oldPort {
                comps[1] = "\(newPort)"
                return comps.joined(separator: " ")
            }
            return line
        }.joined(separator: "\n")
    }

    nonisolated private static func readApacheHTTPPort() -> Int? {
        guard let content = FileHelper.readString(PathConfig.httpdConf) else { return nil }

        var listenPorts: [Int] = []
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), trimmed.lowercased().hasPrefix("listen") else { continue }

            let value = trimmed.components(separatedBy: CharacterSet.whitespaces).dropFirst().first.map { String($0) } ?? ""
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)

            if normalized.contains(":") {
                if let portString = normalized.components(separatedBy: ":").last,
                   let port = Int(portString.trimmingCharacters(in: .whitespaces)) {
                    listenPorts.append(port)
                }
            } else if let port = Int(normalized) {
                listenPorts.append(port)
            }
        }

        if listenPorts.contains(80) {
            return 80
        }

        return listenPorts.first
    }

    private func readApacheHTTPSPort() -> Int? {
        guard let content = FileHelper.readString(PathConfig.httpdSSLConf) else { return nil }
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), t.lowercased().hasPrefix("listen") else { continue }
            let value = t.components(separatedBy: CharacterSet.whitespaces).dropFirst().first.map { String($0) } ?? ""
            if let port = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) { return port }
        }
        return nil
    }

    // MARK: - Nginx Port Config

    func currentNginxHTTPPort()  -> Int { Self.readNginxHTTPPort()  ?? 8080 }
    func currentNginxHTTPSPort() -> Int { readNginxHTTPSPort() ?? 8443 }

    /// nginx.conf içindeki localhost bloğunda ve sites-available/*.conf'larda HTTP/HTTPS portlarını günceller.
    func updateNginxPorts(http: Int, https: Int) {
        let oldHTTP  = Self.readNginxHTTPPort()  ?? 8080
        let oldHTTPS = readNginxHTTPSPort() ?? 8443
        var updatedCount = 0

        // Config dosyaları ÖZGÜN kodlamalarıyla geri yazılır (Latin-1 bir nginx.conf
        // UTF-8'e çevrilirse kullanıcının metni bozulur); okunamayana DOKUNULMAZ.
        let retarget: (String) -> String = {
            self.replaceNginxPorts(in: $0, oldHTTP: oldHTTP, oldHTTPS: oldHTTPS, newHTTP: http, newHTTPS: https)
        }

        // 1) nginx.conf — localhost bloğu
        switch ConfigFileEditor.patch(PathConfig.nginxConf, transform: retarget) {
        case .written:                  updatedCount += 1
        case .missing, .unreadable:     log(key: "log.svc.nginxConfReadFailed", type: .error)
        case .writeFailed:              log(key: "log.svc.nginxConfWriteFailed", type: .error)
        }

        // 2) sites-available/*.conf — domain sunucu blokları
        for file in FileHelper.contentsOfDirectory(PathConfig.nginxSitesAvailableDir) where file.hasSuffix(".conf") {
            let path = "\(PathConfig.nginxSitesAvailableDir)/\(file)"
            if ConfigFileEditor.patch(path, transform: retarget) == .written { updatedCount += 1 }
        }

        if updatedCount > 0 {
            log(key: "log.svc.nginxPortsUpdated", args: ["\(http)", "\(https)", "\(updatedCount)"], type: .success)
        } else {
            log(key: "log.svc.nginxPortsNoFiles", type: .warning)
        }

        restartNginx()
        refreshStatus()
    }

    /// Port değiştirme yardımcısı — listen satırlarını günceller.
    /// `default_server` bayraklı localhost blokları da desteklenir.
    private func replaceNginxPorts(in content: String, oldHTTP: Int, oldHTTPS: Int, newHTTP: Int, newHTTPS: Int) -> String {
        var result = content
        result = result.replacingOccurrences(of: "listen      \(oldHTTP) default_server;", with: "listen      \(newHTTP) default_server;")
        result = result.replacingOccurrences(of: "listen \(oldHTTP) default_server;",      with: "listen \(newHTTP) default_server;")
        result = result.replacingOccurrences(of: "listen      \(oldHTTP);", with: "listen      \(newHTTP);")
        result = result.replacingOccurrences(of: "listen \(oldHTTP);",      with: "listen \(newHTTP);")
        result = result.replacingOccurrences(of: "listen      \(oldHTTPS) ssl default_server;", with: "listen      \(newHTTPS) ssl default_server;")
        result = result.replacingOccurrences(of: "listen \(oldHTTPS) ssl default_server;",      with: "listen \(newHTTPS) ssl default_server;")
        result = result.replacingOccurrences(of: "listen      \(oldHTTPS) ssl;", with: "listen      \(newHTTPS) ssl;")
        result = result.replacingOccurrences(of: "listen \(oldHTTPS) ssl;",      with: "listen \(newHTTPS) ssl;")
        result = result.replacingOccurrences(of: ":\(oldHTTPS)$request_uri",     with: ":\(newHTTPS)$request_uri")
        return result
    }

    /// nginx.conf içinden HTTP portunu okur (ssl olmayan ilk listen)
    nonisolated private static func readNginxHTTPPort() -> Int? {
        guard let content = FileHelper.readString(PathConfig.nginxConf) else { return nil }
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), t.hasPrefix("listen"), !t.contains("ssl") else { continue }
            let parts = t.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }
            let portStr = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            if let port = Int(portStr) { return port }
        }
        return nil
    }

    /// nginx.conf içinden HTTPS portunu okur (ssl içeren ilk listen)
    private func readNginxHTTPSPort() -> Int? {
        guard let content = FileHelper.readString(PathConfig.nginxConf) else { return nil }
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), t.hasPrefix("listen"), t.contains("ssl") else { continue }
            let parts = t.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }
            let portStr = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            if let port = Int(portStr) { return port }
        }
        return nil
    }

    private func parseLaunchctlList() async -> Set<String> {
        let output = await Shell.bashAsync("launchctl list 2>/dev/null").output
        var running = Set<String>()
        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            let pid = parts[0].trimmingCharacters(in: .whitespaces)
            let label = String(parts[2])
            if Int(pid) != nil && label.hasPrefix("homebrew.mxcl.") {
                running.insert(label)
            }
        }
        return running
    }

    private func getInstalledVersion(for svc: Service) async -> String? {
        guard Shell.isBrewInstalled else { return nil }
        switch svc.category {
        case .nodejs:
            let path = PathConfig.nodeBin(version: svc.id.replacingOccurrences(of: "node@", with: ""))
            return await Shell.getVersionAsync(path)
        case .python:
            // Brew Python versiyonları — binary yoluyla tespit
            let path = PathConfig.pythonBin(version: svc.id.replacingOccurrences(of: "python@", with: ""))
            return await Shell.getVersionAsync(path)
        case .dotnet:
            // Her .NET sürümü kendi brew opt dizinine kurulur: opt/dotnet@7, opt/dotnet@8...
            let majorVer = (svc.brewName ?? svc.id).replacingOccurrences(of: "dotnet@", with: "")
            let versionedBin = PathConfig.dotnetBin(majorVersion: majorVer)

            // 1. Sürüme özgü binary varsa direkt versiyon al
            if FileHelper.exists(versionedBin) {
                return await Shell.getVersionAsync(versionedBin)
            }
            // 2. Fallback: list-runtimes çıktısında bu major sürümü ara
            let lr = await Shell.bashAsync("'\(PathConfig.dotnet)' --list-runtimes 2>/dev/null")
            if lr.isSuccess {
                for line in lr.output.components(separatedBy: "\n") {
                    if line.hasPrefix("Microsoft.NETCore.App \(majorVer).") {
                        let parts = line.components(separatedBy: " ")
                        if parts.count >= 2 { return parts[1] }
                    }
                }
            }
            return nil
        case .sharing:
            // brew opt yolu değil doğrudan bin: cloudflared tek bir ikili olarak kurulur
            // ve sürüm satırı "cloudflared version 2026.7.3 (…)" biçimindedir.
            let bin = "\(PathConfig.brewBin)/\(svc.brewName ?? svc.id)"
            return await Shell.getVersionAsync(bin)
        default: return nil
        }
    }

    /// Config dosyalarından servis portlarını okur ve uygular.
    /// Dosya I/O ANA THREAD DIŞINDA yapılır (readStatus 30sn'de bir + birçok tetikleyiciden
    /// çağrıldığından, senkron çalışsaydı UI donardı). Yalnızca hesaplanan [id: port]
    /// haritası MainActor'da uygulanır.
    private func updatePortsFromConfig() async {
        guard Shell.isBrewInstalled else { return }
        // MainActor'da güvenli anlık görüntü — detached task'a değer olarak taşınır
        let snapshot = services.map { (id: $0.id, category: $0.category) }

        let portMap: [String: Int] = await Task.detached { [snapshot] in
            var out: [String: Int] = [:]
            for s in snapshot {
                var port: Int? = nil
                if s.id == "httpd"  { port = Self.readApacheHTTPPort() }
                if s.id == "nginx"  { port = Self.readNginxHTTPPort()  }
                if s.category == .php, s.id.hasPrefix("php@") {
                    let ver = s.id.replacingOccurrences(of: "php@", with: "")
                    let confPath = PathConfig.phpFpmConf(version: ver)
                    if FileHelper.exists(confPath) { _ = PHPFPMConfigManager.normalize(for: ver) }
                    port = Self.readPort(from: confPath, pattern: "listen")
                }
                if s.id.hasPrefix("postgresql@") {
                    let ver = s.id.replacingOccurrences(of: "postgresql@", with: "")
                    let dataDirConf = PathConfig.pgDataDir(version: ver) + "/postgresql.conf"
                    port = Self.readPort(from: dataDirConf, pattern: "port")
                        ?? Self.readPort(from: PathConfig.pgConf(version: ver), pattern: "port")
                }
                if let p = port { out[s.id] = p }
            }
            return out
        }.value

        // Sonuçları MainActor'da uygula
        for i in 0..<services.count {
            guard let p = portMap[services[i].id] else { continue }
            let svc = services[i]
            services[i] = Service(id: svc.id, name: svc.name, category: svc.category, type: svc.type,
                                  port: p, brewName: svc.brewName, installCommand: svc.installCommand,
                                  status: svc.status, version: svc.version, isLoading: svc.isLoading,
                                  isStarting: svc.isStarting, isStopping: svc.isStopping)
        }
    }

    /// Config dosyasından port oku (Listen veya listen = pattern)
    nonisolated private static func readPort(from path: String, pattern: String) -> Int? {
        guard let content = FileHelper.readString(path) else { return nil }
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), !t.hasPrefix(";"), t.lowercased().hasPrefix(pattern.lowercased()) else { continue }

            // SATIR SONU YORUMUNU AT: PostgreSQL'in kendi varsayılanı
            // "port = 5433\t\t\t\t# (change requires restart)" biçimindedir. Yorum
            // ayıklanmazsa Int() nil döner ve port HİÇ okunamaz.
            var body = t
            if let hash = body.firstIndex(of: "#") { body = String(body[body.startIndex..<hash]) }
            if let semi = body.firstIndex(of: ";") { body = String(body[body.startIndex..<semi]) }
            body = body.trimmingCharacters(in: .whitespaces)

            let raw = body.contains("=")
                ? body.components(separatedBy: "=").last?.trimmingCharacters(in: CharacterSet.whitespaces) ?? ""
                : body.components(separatedBy: CharacterSet.whitespaces).dropFirst().first.map { String($0) } ?? ""
            let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: "'\" \t"))

            let parsed = value.contains(":")
                ? value.components(separatedBy: ":").last.flatMap { Int($0.trimmingCharacters(in: CharacterSet.whitespaces)) }
                : Int(value)

            // Ayrıştırılamadıysa DURMA — eşleşen bir sonraki satırı dene. Eskiden ilk
            // eşleşmede return edildiğinden, bozuk/yorumlu ilk satır tüm okumayı bitiriyordu.
            if let p = parsed { return p }
        }
        return nil
    }

    // MARK: - Auto Refresh

    func startAutoRefresh(interval: TimeInterval = 30) {
        stopAutoRefresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshStatusLight() }
        }
        setupBackgroundObservers(interval: interval)
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Background Observer (arka planda timer'ı durdur)

    private func setupBackgroundObservers(interval: TimeInterval) {
        // Önceki observer'ları temizle
        backgroundObservers.forEach { NotificationCenter.default.removeObserver($0) }
        backgroundObservers.removeAll()
        // Her biri KENDİ merkezinden silinir — bkz. `workspaceObservers` notu.
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()

        // Uygulama arka plana geçince timer'ı durdur — pil tasarrufu
        let resign = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshTimer?.invalidate()
                self?.refreshTimer = nil
            }
        }

        // Uygulama ön plana gelince (manuel tıklama VEYA bildirim tıklaması):
        // 1. Anlık durum güncellemesi — kullanıcı ekrana bakar bakmaz doğru durum görür
        // 2. Timer yeniden başlat
        let activate = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.hasRunFullCheck else { return }
                // Anlık hafif kontrol — launchctl + nc (~2ms)
                await self.refreshStatusLight()
                // Timer henüz çalışmıyorsa yeniden başlat
                if self.refreshTimer == nil {
                    self.refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                        Task { @MainActor [weak self] in await self?.refreshStatusLight() }
                    }
                }
            }
        }

        // Mac UYKUDAN UYANINCA — odak değişmeden.
        //
        // NEDEN AYRI BİR GÖZLEMCİ: yukarıdaki ikisi UYGULAMA odağına bakar, uykuya
        // değil. Mac uyurken `Timer` ateşlenmez ve uyanınca kendi takviminde devam
        // eder; üstelik uygulama o sırada arka plandaysa timer zaten iptal edilmiştir.
        // Sonuç: uyanan makinede durum, kullanıcı BRAMPP'e TIKLAYANA kadar bayat kalır.
        //
        // Bu en çok paylaşımlarda acıtır: uyku ağı düşürür, cloudflared ölür, tünel
        // adresi çöker — yani tünelin ölmesi en muhtemel an, kimsenin bakmadığı andır.
        // `NSWorkspace.didWakeNotification` uygulama arka planda olsa da gelir.
        let wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.hasRunFullCheck else { return }
                // Ağ arayüzleri uyanmayla ANINDA hazır olmuyor; hemen sorulan `nc`
                // probu yanlışlıkla "kapalı" der. Kısa bir soluk payı bırakılır.
                try? await Task.sleep(for: .seconds(2))
                await self.refreshStatusLight()
                // Uygulama arka plandaysa `didBecomeActive` gelmeyecek, yani timer'ı
                // burada geri kurmazsak bir daha hiç dönmez.
                if self.refreshTimer == nil {
                    self.refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                        Task { @MainActor [weak self] in await self?.refreshStatusLight() }
                    }
                }
            }
        }

        backgroundObservers = [resign, activate]
        workspaceObservers = [wake]
    }

    // MARK: - Bildirimler

    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendCrashNotification(for service: Service) {
        guard AppSettings.load().notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(service.name) Durdu"
        content.body  = "\(service.name) beklenmedik şekilde durdu. Yeniden başlatmak için BRAMPP'i açın."
        content.sound = .default
        let req = UNNotificationRequest(identifier: "crash-\(service.id)-\(Date().timeIntervalSince1970)",
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
