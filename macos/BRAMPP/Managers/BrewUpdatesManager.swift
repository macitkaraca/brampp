import SwiftUI
import Combine

/// `brew outdated` denetimini ve SEÇİLİ paketlerin yükseltilmesini yürütür.
/// Yorumlama `Core/BrewUpdates.swift` içinde ve saftır; burada yalnızca kabuk işi var.
@MainActor
final class BrewUpdatesManager: BaseManager {

    @Published private(set) var managed: [BrewUpdates.Package] = []
    @Published private(set) var related: [BrewUpdates.Package] = []
    @Published private(set) var other:   [BrewUpdates.Package] = []
    @Published private(set) var isChecking = false
    @Published private(set) var isUpgrading = false
    @Published private(set) var lastCheck: Date?
    /// Kullanıcının işaretledikleri. Denetim yenilenince temizlenir — bayat bir seçim,
    /// artık listede olmayan bir paketi yükseltmeye çalışırdı.
    @Published var selection: Set<String> = []

    var total: Int { managed.count + related.count + other.count }
    var hasAnything: Bool { total > 0 }

    func check(services: [Service]) async {
        guard !isChecking, Shell.isBrewInstalled else { return }
        isChecking = true
        defer { isChecking = false; lastCheck = Date() }
        selection = []

        // --verbose: sürümleri de verir ("httpd (2.4.62) < 2.4.63"). Yalnızca ad
        // göstermek, kullanıcıya yükseltmenin NE getirdiğini söylemiyordu.
        let out = await Shell.brewBashAsync("\(Shell.brewBin) outdated --formula --verbose 2>/dev/null")
        let packages = BrewUpdates.parseOutdated(out.output)

        let names = BrewUpdates.managedNames(services: services)
        // Bağımlılıklar TEK çağrıda alınır; formül başına ayrı `brew deps` çalıştırmak
        // onlarca süreç doğurur ve denetimi saniyelerden dakikalara çıkarırdı.
        //
        // Yalnızca KURULU yönetilen formüller sorulur: katalogda 27 ad var, tipik bir
        // makinede 8'i kurulu. Kurulu olmayanı sormak hem boşuna iş hem de brew'un
        // "bunlar gerçek çalışma zamanı bağımlılıkları değil" uyarısını tetikliyor.
        //
        // `--installed` BAYRAĞI VERİLMEZ — ölçüldü: o bayrakla dönen 47 adın hiçbiri
        // güncellenebilir paketlerle kesişmiyor, bayraksız dönen 65 adın 18'i kesişiyor
        // (`apr-util` dahil). Yani bayrak tam da gruplamak istediğimiz bağımlılıkları
        // eliyor ve hepsi "diğer" kutusuna düşüyordu.
        var deps: Set<String> = []
        let installedOut = await Shell.brewBashAsync("\(Shell.brewBin) list --formula -1 2>/dev/null")
        let askable = names.intersection(BrewUpdates.parseDeps(installedOut.output))
        if !askable.isEmpty {
            let list = askable.sorted().map { Shell.quote($0) }.joined(separator: " ")
            let d = await Shell.brewBashAsync(
                "\(Shell.brewBin) deps --union --formula \(list) 2>/dev/null")
            deps = BrewUpdates.parseDeps(d.output)
        }

        let split = BrewUpdates.split(packages, managed: names, dependencies: deps)
        managed = split.managed
        related = split.related
        other   = split.other

        log(key: "log.brew.checked",
            args: ["\(packages.count)", "\(managed.count)"],
            type: packages.isEmpty ? .success : .info)
    }

    /// Yalnızca SEÇİLİ paketleri yükseltir.
    ///
    /// `brew upgrade` argümansız çağrılsaydı makinedeki HER paketi yükseltirdi —
    /// kullanıcının seçmediği, BRAMPP'ın hiç ilgilenmediği paketler dahil. Bu yüzden
    /// seçim boşsa hiçbir şey yapılmaz; "hiçbiri" ile "hepsi" arasındaki farkı kabuğa
    /// bırakmak, bu komutta veri kaybına varan bir fark.
    func upgradeSelected(services: [Service], serviceManager: ServiceManager?) async {
        let picked = selection.sorted()
        guard !picked.isEmpty, !isUpgrading else { return }
        isUpgrading = true
        defer { isUpgrading = false }

        log(key: "log.brew.upgrading", args: [picked.joined(separator: ", ")], type: .command)
        let list = picked.map { Shell.quote($0) }.joined(separator: " ")
        let r = await Shell.brewBashAsync("\(Shell.brewBin) upgrade \(list) 2>&1")

        guard r.isSuccess else {
            log(key: "log.brew.upgradeFailed",
                args: [String(r.output.suffix(400))], type: .error)
            return
        }
        log(key: "log.brew.upgraded", args: ["\(picked.count)"], type: .success)

        // Yükseltme ikiliyi değiştirir, ÇALIŞAN süreç eskisini tutmaya devam eder.
        // Yeniden başlatılmazsa kullanıcı yeni sürümü çalıştırdığını sanır.
        if let serviceManager {
            let running = Set(serviceManager.services.filter { $0.status == .running }.map { $0.id })
            let ids = BrewUpdates.servicesNeedingRestart(after: picked,
                                                         runningServiceIDs: running,
                                                         services: services)
            for id in ids {
                guard let svc = serviceManager.services.first(where: { $0.id == id }) else { continue }
                log(key: "log.brew.restarting", args: [svc.name], type: .command)
                serviceManager.restartService(svc)
            }
        }
        await check(services: services)
    }
}
