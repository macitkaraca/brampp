import Foundation

// MARK: - Homebrew paket güncellemeleri

/// `brew outdated` çıktısının yorumlanması ve paketlerin BRAMPP'la İLGİSİNE göre
/// ayrılması. Tamamı SAF: kabuk çalıştırmaz, testten geçer.
///
/// Ayırmanın gerekçesi: `brew outdated` makinedeki HER formülü sayar. Bir geliştiricide
/// bu kolayca 49 pakete çıkar ve arasında `cocoapods`, `jadx`, `imagemagick` gibi
/// BRAMPP'ın hiç dokunmadığı şeyler bulunur. Hepsini tek listede göstermek, kullanıcıyı
/// kendi geliştirme ortamıyla ilgisi olmayan bir işe davet eder; asıl önemli olan
/// `httpd`, `php@8.3`, `mariadb` satırları da o gürültünün içinde kaybolur.
enum BrewUpdates {

    struct Package: Identifiable, Equatable {
        var id: String { name }
        let name: String
        /// Kurulu sürüm(ler). `brew` birden fazla kurulu sürüm bildirebilir.
        let current: String
        let latest: String
    }

    /// `brew outdated --formula --verbose` çıktısını ayrıştırır.
    ///
    /// Biçim: `httpd (2.4.62) < 2.4.63` — ya da birden çok kurulu sürümde
    /// `php@8.3 (8.3.13, 8.3.14) < 8.3.15`. `<` yerine `!=` de görülebilir (sürüm
    /// geriye gitmiş kurulumlar); ikisi de "güncellenebilir" demektir.
    ///
    /// AYRIŞTIRILAMAYAN SATIR ATLANIR ama sessizce yutulmaz: adı alınabiliyorsa paket
    /// yine listelenir, sürümler boş kalır. Kullanıcının bir paketi GÖRMEMESİ, onu
    /// eksik sürüm bilgisiyle görmesinden kötüdür.
    static func parseOutdated(_ output: String) -> [Package] {
        output.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            let name = String(line.prefix(while: { !$0.isWhitespace }))
            guard !name.isEmpty else { return nil }

            guard let open = line.firstIndex(of: "("),
                  let close = line[open...].firstIndex(of: ")") else {
                return Package(name: name, current: "", latest: "")
            }
            let current = String(line[line.index(after: open)..<close])
            let rest = line[line.index(after: close)...]
                .trimmingCharacters(in: .whitespaces)
            // `< 2.4.63` ya da `!= 2.4.63`
            let latest = rest.drop(while: { $0 == "<" || $0 == "!" || $0 == "=" })
                .trimmingCharacters(in: .whitespaces)
            return Package(name: name, current: current, latest: latest)
        }
    }

    /// BRAMPP'ın YÖNETTİĞİ formül adları — servis kataloğundan türetilir, elle
    /// yazılmaz: katalog büyüdüğünde bu liste kendiliğinden büyür.
    static func managedNames(services: [Service]) -> Set<String> {
        Set(services.compactMap { $0.brewName ?? $0.id })
    }

    /// Paketleri ikiye ayırır.
    ///
    /// `dependencies`, yönetilen formüllerin bağımlılıklarıdır (`brew deps --union`).
    /// Bunlar da "ilgili" sayılır: `apr-util` ya da `harfbuzz` kullanıcıya rastgele
    /// görünür, oysa `httpd`/`php` yükseltilirken zaten onlarla birlikte gelirler.
    /// Ayrı bir grupta göstermek, yükseltmenin neden başka paketlere dokunduğunu
    /// açıklar — gizlemek ise sürprize dönüşürdü.
    static func split(_ packages: [Package],
                      managed: Set<String>,
                      dependencies: Set<String>) -> (managed: [Package],
                                                     related: [Package],
                                                     other: [Package]) {
        var m: [Package] = [], r: [Package] = [], o: [Package] = []
        for p in packages {
            if managed.contains(p.name) { m.append(p) }
            else if dependencies.contains(p.name) { r.append(p) }
            else { o.append(p) }
        }
        return (m, r, o)
    }

    /// `brew deps --union` çıktısı — satır başına bir ad.
    static func parseDeps(_ output: String) -> Set<String> {
        Set(output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    /// Yükseltilecek paketlerden hangileri ÇALIŞAN bir servise ait?
    ///
    /// Yükseltme ikiliyi değiştirir ama çalışan süreç eskisini tutmaya devam eder:
    /// `httpd` yükseltildikten sonra yeniden başlatılmazsa kullanıcı yeni sürümü
    /// çalıştırdığını sanır, oysa bellekteki hâlâ eskisidir — ve bir sonraki yeniden
    /// başlatmada beklenmedik bir davranış değişikliğiyle karşılaşır.
    static func servicesNeedingRestart(after upgraded: [String],
                                       runningServiceIDs: Set<String>,
                                       services: [Service]) -> [String] {
        let byBrewName = Dictionary(services.map { ($0.brewName ?? $0.id, $0.id) },
                                    uniquingKeysWith: { a, _ in a })
        return upgraded.compactMap { byBrewName[$0] }
            .filter { runningServiceIDs.contains($0) }
    }
}
