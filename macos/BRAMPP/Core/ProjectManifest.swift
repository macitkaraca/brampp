import Foundation

/// `brampp.yml` — bir alan adının yapılandırmasını proje klasöründe taşınabilir kılar.
///
/// Amaç: depoyu başka bir Mac'e klonlayınca ortamın elle kurulmaması. Dosya projeyle
/// birlikte sürümlenir, BRAMPP onu okuyup alan adını aynı ayarlarla oluşturur.
///
/// YAML KÜTÜPHANESİ KULLANILMIYOR. Uygulamanın hiç dış bağımlılığı yok ve bunu tek bir
/// yapılandırma dosyası için bozmak istemedim. Bu yüzden desteklenen dilbilgisi
/// KASITLI OLARAK dar: `anahtar: değer` satırları ve `- öge` listeleri. İç içe eşlemeler,
/// çok satırlı diziler ve çapa/alias yok. Ayrıştırıcı anlamadığı satırı SESSİZCE ATLAMAZ,
/// yok sayar ama bilinen anahtarların hiçbiri eksikse dosyayı geçersiz sayar.
struct ProjectManifest: Equatable {

    var name: String
    var platform: String            // php | nodejs | python | dotnet | static
    var webServer: String?          // apache | nginx
    var phpVersion: String?         // "8.4"
    var documentRoot: String?       // proje köküne göre alt klasör
    var port: Int?
    var ssl: Bool
    var services: [String]          // mariadb, redis…
    var runCommand: String?
    var buildCommand: String?

    static let fileName = "brampp.yml"

    // MARK: - Yazma

    func yaml() -> String {
        var l: [String] = [
            "# BRAMPP proje manifesti — https://macitkaraca.github.io/brampp/",
            "# Bu dosyayı depoya ekleyin: başka bir Mac'te BRAMPP ortamı aynı kurar.",
            "name: \(name)",
            "platform: \(platform)",
        ]
        if let w = webServer     { l.append("web_server: \(w)") }
        if let p = phpVersion    { l.append("php: \"\(p)\"") }
        if let d = documentRoot  { l.append("document_root: \(d)") }
        if let p = port          { l.append("port: \(p)") }
        l.append("ssl: \(ssl)")
        if let r = runCommand    { l.append("run: \(quoted(r))") }
        if let b = buildCommand  { l.append("build: \(quoted(b))") }
        if !services.isEmpty {
            l.append("services:")
            l += services.map { "  - \($0)" }
        }
        return l.joined(separator: "\n") + "\n"
    }

    /// Boşluk ya da `:` içeren değerler tırnaklanır; aksi halde yeniden okunamaz.
    private func quoted(_ s: String) -> String {
        s.contains(" ") || s.contains(":") ? "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
                                           : s
    }

    // MARK: - Okuma

    static func parse(_ text: String) -> ProjectManifest? {
        var scalars: [String: String] = [:]
        var services: [String] = []
        var inServices = false

        for raw in text.components(separatedBy: .newlines) {
            // Yorumlar ve boş satırlar
            let line = raw.hasPrefix("#") ? "" : raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Liste ögesi — yalnızca bir liste anahtarının ardından geçerli
            if trimmed.hasPrefix("- ") {
                if inServices {
                    services.append(unquote(String(trimmed.dropFirst(2))))
                }
                continue
            }

            // Girintili ama liste değil → desteklenmeyen iç içe yapı, yok say
            guard line == trimmed else { continue }

            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[trimmed.startIndex..<colon])
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = unquote(String(trimmed[trimmed.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces))

            if key == "services" {
                inServices = value.isEmpty
                if !value.isEmpty {
                    // "services: [a, b]" akış biçimi
                    services += value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                        .components(separatedBy: ",")
                        .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
                        .filter { !$0.isEmpty }
                }
                continue
            }
            inServices = false
            scalars[key] = value
        }

        // Ad ve platform olmadan manifest bir işe yaramaz.
        guard let name = scalars["name"], !name.isEmpty,
              let platform = scalars["platform"], !platform.isEmpty else { return nil }

        return ProjectManifest(
            name: name,
            platform: platform.lowercased(),
            webServer: scalars["web_server"]?.lowercased(),
            phpVersion: scalars["php"],
            documentRoot: scalars["document_root"],
            port: scalars["port"].flatMap { Int($0) },
            // Belirtilmemişse SSL AÇIK sayılır: BRAMPP alan adlarını böyle kuruyor ve
            // sessizce HTTP'ye düşmek beklenmedik olurdu.
            ssl: scalars["ssl"].map { ["true", "yes", "1", "on"].contains($0.lowercased()) } ?? true,
            services: services,
            runCommand: scalars["run"],
            buildCommand: scalars["build"])
    }

    // MARK: - Alan adı dönüşümü

    /// Bir alan adından manifest üretir.
    ///
    /// Belge kökü PROJE KÖKÜNE GÖRE yazılır: mutlak yol başka makinede anlamsız olurdu
    /// (kullanıcı adı ve Sites klasörü farklı olabilir).
    static func from(domain: Domain, services: [String] = []) -> ProjectManifest {
        var relRoot: String?
        if let custom = domain.customDocumentRoot, !custom.isEmpty {
            let base = "\(PathConfig.sites)/\(domain.name)"
            if custom.hasPrefix(base + "/") {
                relRoot = String(custom.dropFirst(base.count + 1))
            }
            // Sites dışındaki mutlak bir kök taşınabilir değil — yazılmaz.
        }
        return ProjectManifest(
            name: domain.name,
            platform: domain.platform.rawValue,
            webServer: domain.webServer.rawValue,
            phpVersion: domain.phpVersion?.rawValue,
            documentRoot: relRoot,
            port: domain.port,
            ssl: domain.sslEnabled,
            services: services,
            runCommand: domain.appCommand,
            buildCommand: domain.buildCommand)
    }

    /// Manifesti var olan bir alan adına uygular; DEĞİŞENLERİ döndürür.
    ///
    /// Ad değiştirilmez: alan adını yeniden adlandırmak vhost, hosts kaydı ve sertifika
    /// zincirini ilgilendirir ve manifest uygulamanın yan etkisi olmamalı.
    static func apply(_ m: ProjectManifest, to domain: inout Domain) -> [String] {
        var changed: [String] = []
        if let ws = m.webServer, let v = WebServer(rawValue: ws), v != domain.webServer {
            domain.webServer = v; changed.append("web sunucusu → \(v.displayName)")
        }
        if let php = m.phpVersion, let v = PHPVersion(rawValue: php), v != domain.phpVersion {
            domain.phpVersion = v; changed.append("PHP → \(php)")
        }
        if let p = m.port, p != domain.port {
            domain.port = p; changed.append("port → \(p)")
        }
        if m.ssl != domain.sslEnabled {
            domain.sslEnabled = m.ssl; changed.append("SSL → \(m.ssl ? "açık" : "kapalı")")
        }
        if let run = m.runCommand, run != domain.appCommand {
            domain.appCommand = run; changed.append("çalıştırma komutu")
        }
        if let build = m.buildCommand, build != domain.buildCommand {
            domain.buildCommand = build; changed.append("derleme komutu")
        }
        if let rel = m.documentRoot, !rel.isEmpty {
            let abs = "\(PathConfig.sites)/\(domain.name)/\(rel)"
            if abs != domain.customDocumentRoot {
                domain.customDocumentRoot = abs; changed.append("belge kökü → \(rel)")
            }
        }
        return changed
    }

    private static func unquote(_ s: String) -> String {
        var v = s
        // Satır sonu yorumu: `port: 3000  # geliştirme`
        if let hash = v.range(of: " #") { v = String(v[v.startIndex..<hash.lowerBound]) }
        v = v.trimmingCharacters(in: .whitespaces)
        if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        return v.replacingOccurrences(of: "\\\"", with: "\"")
    }
}
