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
