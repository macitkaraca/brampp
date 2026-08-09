import Foundation

/// Proje klasöründen framework'ü tanır ve alan adı ayarlarını önerir.
///
/// Karar tamamen saftır: girdi dosya adları ve iki manifest metnidir, disk erişimi
/// çağırana aittir. Böylece kurallar gerçek projelerle test edilebilir.
///
/// ÖNEMLİ: `public/` klasörünün varlığı TEK BAŞINA belge kökünü değiştirmek için
/// yeterli değildir. Laravel ve Symfony'de belge kökü gerçekten `public/`; ama düz bir
/// PHP sitesinde `public/` yalnızca varlık klasörü olabilir ve kökü oraya taşımak siteyi
/// bozar. Bu yüzden kök önerisi yalnızca framework KESİN tanındığında verilir.
enum FrameworkDetector {

    /// Öneriye ne kadar güvenilebileceği — arayüz buna göre "uygula" mı "öner" mi karar verir.
    enum Confidence: String {
        /// Framework'e özgü bir imza dosyası bulundu (artisan, wp-config.php…)
        case certain
        /// Bağımlılık listesinden çıkarıldı
        case likely
        /// Yalnızca genel ipuçları var
        case guess
    }

    struct Detection: Equatable {
        let framework: String
        let platform: Platform
        /// Belge kökü için alt klasör — nil ise proje kökü kullanılır
        let documentRootSuffix: String?
        /// Önerilen servisler (Service.id)
        let suggestedServices: [String]
        /// Node/Python projelerinde çalıştırma komutu önerisi
        let runCommand: String?
        let confidence: Confidence

        static func == (a: Detection, b: Detection) -> Bool {
            a.framework == b.framework && a.platform == b.platform
                && a.documentRootSuffix == b.documentRootSuffix
                && a.suggestedServices == b.suggestedServices
                && a.confidence == b.confidence
        }
    }

    /// JSON'dan bağımlılık adlarını toplar (`require`, `require-dev`,
    /// `dependencies`, `devDependencies`).
    static func dependencies(in json: String?) -> Set<String> {
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        var out = Set<String>()
        for key in ["require", "require-dev", "dependencies", "devDependencies"] {
            (obj[key] as? [String: Any])?.keys.forEach { out.insert($0.lowercased()) }
        }
        return out
    }

    /// `files`: proje kökündeki dosya/klasör adları (yalnızca ilk seviye).
    static func detect(files: Set<String>,
                       composerJSON: String? = nil,
                       packageJSON: String? = nil) -> Detection? {
        let composerDeps = dependencies(in: composerJSON)
        let nodeDeps = dependencies(in: packageJSON)

        // ── PHP: imza dosyaları kesin sonuç verir ───────────────────────────
        if files.contains("artisan") {
            // Laravel'de belge kökü GERÇEKTEN public/ — kökü sunmak .env dosyasını
            // internete açardı.
            return Detection(framework: "Laravel", platform: .php,
                             documentRootSuffix: "public",
                             suggestedServices: ["mariadb", "redis"],
                             runCommand: nil, confidence: .certain)
        }
        if files.contains("wp-config.php") || files.contains("wp-load.php") {
            return Detection(framework: "WordPress", platform: .php,
                             documentRootSuffix: nil,
                             suggestedServices: ["mariadb"],
                             runCommand: nil, confidence: .certain)
        }
        if composerDeps.contains(where: { $0.hasPrefix("symfony/") }) {
            return Detection(framework: "Symfony", platform: .php,
                             documentRootSuffix: files.contains("public") ? "public" : nil,
                             suggestedServices: ["mariadb"],
                             runCommand: nil, confidence: .likely)
        }
        if files.contains("system") && files.contains("application") {
            return Detection(framework: "CodeIgniter", platform: .php,
                             documentRootSuffix: nil,
                             suggestedServices: ["mariadb"],
                             runCommand: nil, confidence: .likely)
        }

        // ── .NET ────────────────────────────────────────────────────────────
        if files.contains(where: { $0.hasSuffix(".csproj") || $0.hasSuffix(".sln") }) {
            return Detection(framework: "ASP.NET Core", platform: .dotnet,
                             documentRootSuffix: nil, suggestedServices: [],
                             runCommand: "dotnet run", confidence: .certain)
        }

        // ── Python ──────────────────────────────────────────────────────────
        if files.contains("manage.py") {
            return Detection(framework: "Django", platform: .python,
                             documentRootSuffix: nil,
                             suggestedServices: ["mariadb"],
                             runCommand: "python manage.py runserver", confidence: .certain)
        }
        if files.contains("requirements.txt") || files.contains("pyproject.toml") {
            return Detection(framework: "Python", platform: .python,
                             documentRootSuffix: nil, suggestedServices: [],
                             runCommand: nil, confidence: .guess)
        }

        // ── Node ────────────────────────────────────────────────────────────
        if !nodeDeps.isEmpty || files.contains("package.json") {
            if nodeDeps.contains("next") {
                return Detection(framework: "Next.js", platform: .nodejs,
                                 documentRootSuffix: nil, suggestedServices: [],
                                 runCommand: "npm run dev", confidence: .likely)
            }
            if nodeDeps.contains("nuxt") {
                return Detection(framework: "Nuxt", platform: .nodejs,
                                 documentRootSuffix: nil, suggestedServices: [],
                                 runCommand: "npm run dev", confidence: .likely)
            }
            if nodeDeps.contains("express") {
                return Detection(framework: "Express", platform: .nodejs,
                                 documentRootSuffix: nil, suggestedServices: [],
                                 runCommand: "npm start", confidence: .likely)
            }
            // Vite/SPA: derleme çıktısı statik olarak sunulur, süreç gerekmez.
            if nodeDeps.contains("vite") || nodeDeps.contains("react-scripts") {
                return Detection(framework: "SPA", platform: .static_,
                                 documentRootSuffix: files.contains("dist") ? "dist" : nil,
                                 suggestedServices: [],
                                 runCommand: nil, confidence: .likely)
            }
            return Detection(framework: "Node.js", platform: .nodejs,
                             documentRootSuffix: nil, suggestedServices: [],
                             runCommand: "npm start", confidence: .guess)
        }

        // ── Düz PHP ─────────────────────────────────────────────────────────
        if files.contains("index.php") || files.contains("composer.json") {
            // public/ VAR ama framework tanınmadı: kökü değiştirmek siteyi bozabilir,
            // bu yüzden önerilmez — yalnızca PHP olduğu söylenir.
            return Detection(framework: "PHP", platform: .php,
                             documentRootSuffix: nil,
                             suggestedServices: composerJSON != nil ? ["mariadb"] : [],
                             runCommand: nil, confidence: .guess)
        }
        if files.contains("index.html") {
            return Detection(framework: "Statik site", platform: .static_,
                             documentRootSuffix: nil, suggestedServices: [],
                             runCommand: nil, confidence: .guess)
        }
        return nil
    }
}
