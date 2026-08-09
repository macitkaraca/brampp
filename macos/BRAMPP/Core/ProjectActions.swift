import Foundation

/// Bir alan adının proje klasöründe yapılabilecek işler.
///
/// Kural: KURULU OLMAYAN ya da o projede ANLAMSIZ olan hiçbir şey gösterilmez.
/// `composer.json` yoksa "composer install" menüde durmamalı; tıklanınca hata veren
/// bir menü ögesi, hiç olmamasından kötüdür.
///
/// Karar verme saf tutuldu: dosya sistemi ve kabuk erişimi çağırana ait, buradaki
/// fonksiyonlar yalnızca "şu koşullarda hangi eylemler görünür" sorusunu yanıtlar.
enum ProjectActions {

    // MARK: - Editörler

    struct Editor: Identifiable, Equatable {
        /// Menüde görünen ad
        let name: String
        /// `/Applications/<bundleName>.app` — `open -a` bunu kullanır
        let bundleName: String
        var id: String { bundleName }
    }

    /// Aranan editörler. CLI (`code`, `cursor`) KURULU OLMAYABİLİR ama uygulama
    /// duruyor olabilir — bu makinede tam olarak öyle. Bu yüzden `.app` paketine
    /// bakılır, komuta değil.
    static let knownEditors: [Editor] = [
        Editor(name: "VS Code",      bundleName: "Visual Studio Code"),
        Editor(name: "Cursor",       bundleName: "Cursor"),
        Editor(name: "PhpStorm",     bundleName: "PhpStorm"),
        Editor(name: "WebStorm",     bundleName: "WebStorm"),
        Editor(name: "Sublime Text", bundleName: "Sublime Text"),
        Editor(name: "Zed",          bundleName: "Zed"),
    ]

    /// Kurulu editörler. `appExists` enjekte edilir ki test dosya sistemine bağlanmasın.
    static func installedEditors(appExists: (String) -> Bool) -> [Editor] {
        knownEditors.filter { appExists("/Applications/\($0.bundleName).app") }
    }

    // MARK: - Görevler

    enum Task: Equatable, Identifiable {
        case composerInstall
        case composerUpdate
        case npmInstall
        /// package.json'daki script adı — "dev", "build", "start"…
        case npmScript(String)

        var id: String {
            switch self {
            case .composerInstall: return "composer-install"
            case .composerUpdate:  return "composer-update"
            case .npmInstall:      return "npm-install"
            case .npmScript(let s): return "npm-run-\(s)"
            }
        }

        var label: String {
            switch self {
            case .composerInstall: return "composer install"
            case .composerUpdate:  return "composer update"
            case .npmInstall:      return "npm install"
            case .npmScript(let s): return "npm run \(s)"
            }
        }

        /// Çalıştırılacak komut.
        func command(npmBin: String, composerBin: String) -> String {
            switch self {
            case .composerInstall:  return "\(composerBin) install"
            case .composerUpdate:   return "\(composerBin) update"
            case .npmInstall:       return "\(npmBin) install"
            case .npmScript(let s): return "\(npmBin) run \(s)"
            }
        }
    }

    /// package.json içindeki `scripts` anahtarlarını çıkarır.
    ///
    /// Tam JSON ayrıştırması yapılır — düzenli ifadeyle "scripts" bloğunu kesmek,
    /// iç içe nesnelerde yanlış anahtarları yakalıyordu.
    static func npmScripts(inPackageJSON json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = obj["scripts"] as? [String: Any] else { return [] }
        // Yaygın olanlar üste, gerisi alfabetik — menüde "dev" aranırken en üstte olsun.
        let öncelik = ["dev", "start", "serve", "watch", "build", "test"]
        let all = Array(scripts.keys)
        let head = öncelik.filter { all.contains($0) }
        let tail = all.filter { !öncelik.contains($0) }.sorted()
        return head + tail
    }

    /// Bu projede gösterilecek görevler.
    ///
    /// - Parameters:
    ///   - hasComposerJSON: proje klasöründe `composer.json` var mı
    ///   - packageJSON: `package.json` içeriği (yoksa nil)
    ///   - composerInstalled / npmInstalled: araç makinede var mı
    ///   - maxScripts: menüyü şişirmemek için gösterilecek en fazla npm script sayısı
    static func availableTasks(hasComposerJSON: Bool,
                               packageJSON: String?,
                               composerInstalled: Bool,
                               npmInstalled: Bool,
                               maxScripts: Int = 4) -> [Task] {
        var out: [Task] = []
        if hasComposerJSON && composerInstalled {
            out.append(.composerInstall)
            out.append(.composerUpdate)
        }
        if let pkg = packageJSON, npmInstalled {
            out.append(.npmInstall)
            out += npmScripts(inPackageJSON: pkg).prefix(maxScripts).map { .npmScript($0) }
        }
        return out
    }
}
