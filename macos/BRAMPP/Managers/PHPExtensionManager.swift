import SwiftUI
import Combine

/// PHP Extension yönetimi — BaseManager'dan türetilir.
@MainActor
class PHPExtensionManager: BaseManager {
    
    @Published var extensions: [PHPExtension] = []
    @Published var selectedPHPVersion: PHPVersion = .v83
    @Published var phpIniSettings: [PHPIniSetting] = PHPIniSetting.commonSettings
    
    // MARK: - Load
    
    func loadExtensions() {
        guard requireBrew(forKey: "log.op.phpExtLoad") else {
            extensions = PHPExtension.popularExtensions; return
        }

        prepareSelectedPHPFPMIfNeeded()

        log(key: "log.php.loading", args: [selectedPHPVersion.rawValue], type: .info)

        var exts = PHPExtension.popularExtensions
        let installed = getInstalledExtensions()
        let enabled = getEnabledExtensions()
        let disabled = getDisabledExtensions()

        for i in 0..<exts.count {
            // DEVRE DIŞI BIRAKILAN DA KURULUDUR. `php -m` yalnızca YÜKLÜ uzantıları
            // listeler; devre dışı bırakma ext-<ad>.ini'yi .disabled yapıp php.ini
            // satırını da sildiği için uzantı o listeden düşer. Yalnızca `php -m`'e
            // bakılırsa satır "kurulu değil"e döner: onay kutusu kaybolur, yerine "Kur"
            // gelir, ona basınca PEAR kaydı hâlâ durduğundan `pecl install` "already
            // installed" ile patlar — uzantıyı arayüzden geri açmanın YOLU KALMAZ.
            // .disabled dosyasının varlığı, uzantının diskte durduğunun kanıtıdır.
            exts[i].isInstalled = installed.contains(exts[i].name)
                || disabled.contains(exts[i].name)
                || exts[i].isBuiltIn
            exts[i].isEnabled = enabled.contains(exts[i].name) || exts[i].isBuiltIn
        }
        
        extensions = exts
        loadPHPIniSettings()
        refreshProfiler()
        log(key: "log.php.loaded", args: ["\(extensions.filter { $0.isEnabled }.count)"], type: .success)
    }
    
    private func getInstalledExtensions() -> Set<String> {
        let phpPath = PathConfig.phpBin(version: selectedPHPVersion.rawValue)
        guard FileHelper.exists(phpPath) else { return [] }
        let r = Shell.run(phpPath, arguments: ["-m"])
        guard r.isSuccess else { return [] }
        return Set(r.output.components(separatedBy: "\n")
            .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.starts(with: "[") })
    }
    
    /// `ext-<ad>.ini.disabled` bırakılmış uzantılar — kurulu ama kapalı.
    private func getDisabledExtensions() -> Set<String> {
        let confD = PathConfig.phpConfD(version: selectedPHPVersion.rawValue)
        return Self.disabledNames(inConfD: FileHelper.contentsOfDirectory(confD))
    }

    /// conf.d dosya adlarından devre dışı uzantı adlarını çıkarır — SAF, diskten bağımsız.
    ///
    /// `.ini` ile `.ini.disabled` ayrımı burada kritik: sonek denetimi gevşetilirse etkin
    /// uzantılar da "devre dışı" sayılır ve `isEnabled` ile çelişir.
    static func disabledNames(inConfD fileNames: [String]) -> Set<String> {
        Set(fileNames
            .filter { $0.hasPrefix("ext-") && $0.hasSuffix(".ini.disabled") }
            .map { String($0.dropFirst("ext-".count).dropLast(".ini.disabled".count)) }
            .filter { !$0.isEmpty })
    }

    private func getEnabledExtensions() -> Set<String> {
        let confD = PathConfig.phpConfD(version: selectedPHPVersion.rawValue)
        let fromConfD = Set(FileHelper.contentsOfDirectory(confD)
            .filter { $0.starts(with: "ext-") && $0.hasSuffix(".ini") && !$0.contains(".disabled") }
            .map { $0.replacingOccurrences(of: "ext-", with: "").replacingOccurrences(of: ".ini", with: "") })
        // ANA php.ini de sayılır. Yalnızca conf.d'ye bakılıyordu: elle (ya da başka bir
        // araçla) php.ini'ye `extension=redis` yazılmış bir uzantı panelde DEVRE DIŞI
        // görünüyor, kullanıcı açınca conf.d'ye İKİNCİ bir kayıt düşüyor ve PHP aynı
        // uzantıyı iki kez yükleyip "Module already loaded" uyarısı veriyordu.
        let ini = PathConfig.phpIni(version: selectedPHPVersion.rawValue)
        let fromIni = Self.mainIniExtensionNames(in: FileHelper.readString(ini) ?? "")
        return fromConfD.union(fromIni)
    }

    /// Ana `php.ini` içinde `extension=` / `zend_extension=` ile kayıtlı uzantı adları.
    /// SAF — mutlak yol biçimi de çözülür: `…/pecl/20230831/xdebug.so` → `xdebug`.
    static func mainIniExtensionNames(in content: String) -> Set<String> {
        var out: Set<String> = []
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix(";"), !t.hasPrefix("#"),
                  let eq = t.firstIndex(of: "=") else { continue }
            // Direktif adı TAM eşleşmeli. Önek denetimi `extension_dir`i de yakalıyor
            // ve onun değerinin son bileşenini (`pecl`) uzantı adı sanıyordu.
            let directive = t[t.startIndex..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            guard directive == "extension" || directive == "zend_extension" else { continue }
            let value = t[t.index(after: eq)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            let file = (value as NSString).lastPathComponent
            let base = file.hasSuffix(".so") ? String(file.dropLast(3)) : file
            if !base.isEmpty { out.insert(base.lowercased()) }
        }
        return out
    }
    
    // MARK: - Profilleyici (Xdebug profile kipi)

    /// Seçili sürümde profilleyici açık mı?
    @Published var profilerEnabled = false
    /// Her istek mi profilleniyor (aksi hâlde yalnızca XDEBUG_TRIGGER taşıyanlar)?
    @Published var profilerAlwaysOn = false
    /// Üretilmiş profil dosyaları.
    @Published var profiles: [PHPProfiler.ProfileFile] = []

    /// Xdebug bu sürümde kurulu mu? Profilleyici ona bağlı.
    var isXdebugReady: Bool {
        extensions.first(where: { $0.name == "xdebug" })?.isEnabled ?? false
    }

    func refreshProfiler() {
        let ini = PathConfig.phpIni(version: selectedPHPVersion.rawValue)
        let content = FileHelper.readString(ini) ?? ""
        profilerEnabled  = PHPProfiler.isEnabled(in: content)
        profilerAlwaysOn = PHPProfiler.isAlwaysOn(in: content)
        profiles = PHPProfiler.profiles()
    }

    /// Profilleyiciyi açar/kapatır. `php.ini` yazıldıktan sonra PHP-FPM'in yeniden
    /// başlatılması gerekir — aksi halde ayar yalnızca CLI'da geçerli olur.
    func setProfiler(enabled: Bool, alwaysOn: Bool) {
        guard requireBrew(forKey: "log.op.phpIniUpdate") else { return }
        let ini = PathConfig.phpIni(version: selectedPHPVersion.rawValue)
        guard let content = FileHelper.readString(ini) else {
            log(key: "log.php.iniNotFound", type: .error); return
        }
        // Yazmadan önce yedek: php.ini bozulursa o sürüm hiç çalışmaz.
        // YEDEK ALINAMIYORSA ASIL YAZIMA HİÇ GİRİLMEZ. Sonuç yok sayılıyordu: kullanıcı
        // "yedek alındı" varsayımıyla devam ediyor, oysa geri dönecek dosya yoktu.
        guard FileHelper.write(content, to: ini + ".brampp.bak") else {
            log(key: "log.php.iniBackupFailed", args: [ini], type: .error); return
        }

        _ = FileHelper.createDirectory(PHPProfiler.outputDir)
        let updated = enabled ? PHPProfiler.applying(to: content, alwaysOn: alwaysOn)
                              : PHPProfiler.removing(from: content)
        guard FileHelper.write(updated, to: ini) else {
            log(key: "log.php.iniWriteFailed", type: .error); return
        }
        log(key: enabled ? (alwaysOn ? "log.php.profilerAlways" : "log.php.profilerTrigger")
                         : "log.php.profilerOff",
            args: [selectedPHPVersion.rawValue], type: .success)
        // php.ini YALNIZCA süreç başlangıcında okunur. Yeniden başlatılmazsa çalışan
        // FPM havuzu `xdebug.mode=profile` ile ayakta kalmaya devam eder: kullanıcı
        // profilleyiciyi kapattığını sanır, cachegrind dosyaları üretilmeye ve disk
        // dolmaya devam eder. Uyarı da gösterilmiyordu, çünkü uyarı kutusu yalnızca
        // profilleyici AÇIKKEN çiziliyordu — kapatma anında hiç görünmüyordu.
        restartBrewService(selectedPHPVersion.brewService, displayName: "PHP-FPM")
        refreshProfiler()
    }

    func deleteProfile(_ file: PHPProfiler.ProfileFile) {
        _ = FileHelper.remove(file.path)
        refreshProfiler()
    }

    func clearProfiles() {
        for f in PHPProfiler.profiles() { _ = FileHelper.remove(f.path) }
        log(key: "log.php.profilesCleared", type: .info)
        refreshProfiler()
    }

    // MARK: - Enable / Disable
    
    func enableExtension(_ ext: PHPExtension) {
        guard requireBrew(forKey: "log.op.extEnable") else { return }
        guard let i = extensions.firstIndex(where: { $0.id == ext.id }) else { return }
        
        log(key: "log.php.enabling", args: [ext.name], type: .command)
        let confD = PathConfig.phpConfD(version: selectedPHPVersion.rawValue)
        let disabled = "\(confD)/ext-\(ext.name).ini.disabled"
        let enabled  = "\(confD)/ext-\(ext.name).ini"
        
        if FileHelper.exists(disabled) {
            guard FileHelper.move(from: disabled, to: enabled) else { log(key: "log.php.moveFailed", type: .error); return }
        } else if !FileHelper.exists(enabled) {
            guard FileHelper.write(generateConfig(for: ext), to: enabled) else { log(key: "log.php.configWriteFailed", type: .error); return }
        }
        
        extensions[i].isEnabled = true
        restartBrewService(selectedPHPVersion.brewService, displayName: "PHP-FPM")
        log(key: "log.php.enabled", args: [ext.name], type: .success)
    }
    
    func disableExtension(_ ext: PHPExtension) {
        guard requireBrew(forKey: "log.op.extDisable") else { return }
        guard let i = extensions.firstIndex(where: { $0.id == ext.id }) else { return }
        guard !ext.isBuiltIn else { log(key: "log.php.builtInNoDisable", type: .warning); return }

        log(key: "log.php.disabling", args: [ext.name], type: .command)
        let confD = PathConfig.phpConfD(version: selectedPHPVersion.rawValue)
        let enabled  = "\(confD)/ext-\(ext.name).ini"
        let disabled = "\(confD)/ext-\(ext.name).ini.disabled"
        
        guard FileHelper.exists(enabled), FileHelper.move(from: enabled, to: disabled) else {
            log(key: "log.php.disableFailed", type: .error); return
        }

        // conf.d dosyasını taşımak TEK BAŞINA yetmez: uzantı ana php.ini'de de kayıtlıysa
        // (pecl'in eklediği `extension="x.so"` satırı) PHP onu yüklemeye devam eder ve
        // "devre dışı bıraktım" denmesine rağmen uzantı açık kalırdı.
        stripFromMainPHPIni(extension: ext.name, version: selectedPHPVersion.rawValue)

        extensions[i].isEnabled = false
        restartBrewService(selectedPHPVersion.brewService, displayName: "PHP-FPM")
        log(key: "log.php.disabled", args: [ext.name], type: .success)
    }
    
    func toggleExtension(_ ext: PHPExtension) {
        ext.isEnabled ? disableExtension(ext) : enableExtension(ext)
    }
    
    // MARK: - Install

    /// Kurulumu SÜREN uzantılar. İkinci tıklama ikinci bir `pecl` derlemesi ve ikinci
    /// bir Terminal penceresi açıyordu; ikisi aynı dosyalara yazınca sonuç belirsiz.
    @Published private(set) var installingExtensions: Set<String> = []

    func installExtension(_ ext: PHPExtension) {
        guard requireBrew(forKey: "log.op.extInstall") else { return }
        // AYNI uzantıya ikinci kurulum başlatılmaz: iki `pecl` derlemesi aynı dosyalara
        // yazar ve hangisinin kazandığı belirsizdir. Kilit, imagick dalından ÖNCE
        // konur — o yol da Terminal penceresi açıyor.
        guard !installingExtensions.contains(ext.name) else {
            log(key: "log.php.installBusy", args: [ext.name], type: .warning); return
        }
        installingExtensions.insert(ext.name)

        // imagick için özel kurulum süreci
        if ext.name == "imagick" {
            // Terminal penceresinde sürüyor: bittiğini buradan göremeyiz, o yüzden
            // kilit hemen çözülür. Yine de değer var — arka arkaya iki tıklamada
            // ikinci pencere açılmaz.
            installImagick()
            installingExtensions.remove(ext.name)
            return
        }

        guard let i = extensions.firstIndex(where: { $0.id == ext.id }) else {
            installingExtensions.remove(ext.name); return
        }

        extensions[i].isInstalled = false; isLoading = true
        log(key: "log.php.installing", args: [ext.name], type: .command)

        // Sürüm Task'tan ÖNCE sabitlenir. `pecl install` dakikalar sürebilir; bu sırada
        // @MainActor serbest olduğundan kullanıcı sürüm seçicisini değiştirebilir. Sürüm
        // askıdan SONRA okunursa uzantı YANLIŞ PHP sürümüne kurulurdu.
        let version = selectedPHPVersion.rawValue
        let extID   = ext.id

        Task {
            if let dep = ext.dependency {
                log(key: "log.php.depInstalling", args: [dep], type: .info)
                let dr = await Shell.brewBashAsync("brew install \(dep)")
                if !dr.isSuccess { log(key: "log.php.depFailed", args: [dr.error], type: .error) }
            }

            let r = await Shell.runAsync(PathConfig.peclBin(version: version), arguments: ["install", ext.name])
            if r.isSuccess {
                log(key: "log.php.installed", args: [ext.name, version], type: .success)
                // pecl, uzantıyı ANA php.ini'ye de ekler; conf.d/ext-*.ini ile birlikte
                // çift yükleme uyarısı verir ve "devre dışı bırak" işlemi etkisiz kalır.
                stripFromMainPHPIni(extension: ext.name, version: version)

                // Kurulum sırasında sürüm değiştiyse otomatik etkinleştirme YAPILMAZ:
                // enableExtension GÜNCEL seçili sürümün conf.d'sine yazacağından uzantı
                // yanlış sürüme tanımlanırdı. Dizi de değişmiş olabilir → id ile bul.
                if selectedPHPVersion.rawValue == version,
                   let j = extensions.firstIndex(where: { $0.id == extID }) {
                    extensions[j].isInstalled = true
                    enableExtension(extensions[j])
                }
            } else {
                log(key: "log.php.installFailed", args: [ext.name, r.error], type: .error)
            }
            // Kilit BAŞARIDA DA BAŞARISIZLIKTA DA çözülür: yalnızca başarıda çözülseydi
            // bir kez patlayan uzantı, uygulama kapanana dek yeniden denenemezdi.
            installingExtensions.remove(ext.name)
            isLoading = false; loadExtensions()
        }
    }

    /// `pecl install` uzantıyı ANA php.ini'ye `extension="x.so"` olarak ekler. Uygulama ise
    /// uzantıları `conf.d/ext-*.ini` üzerinden yönetir — ikisi birlikte kalırsa PHP
    /// "module already loaded" uyarısı verir ve conf.d dosyasını silmek (devre dışı bırakmak)
    /// uzantıyı gerçekte kapatmaz. Bu yüzden ana php.ini'deki satır temizlenir.
    /// (imagick yolu bunu zaten yapıyordu; genel pecl yolu yapmıyordu.)
    private func stripFromMainPHPIni(extension name: String, version: String) {
        let iniPath = PathConfig.phpIni(version: version)
        guard let content = FileHelper.readString(iniPath) else { return }

        let kept = content.components(separatedBy: .newlines).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix(";") else { return true }          // yorumlanmışa dokunma
            guard let eq = t.firstIndex(of: "=") else { return true }

            // Direktif adı TAM eşleşmeli — "extension_dir" gibi benzer adlar silinmemeli
            let key = t[t.startIndex..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "extension" || key == "zend_extension" else { return true }

            // Üç biçim de yakalanır: `extension=redis`, `extension="redis.so"` ve
            // `zend_extension=/opt/homebrew/lib/php/pecl/20230831/xdebug.so`.
            // Sonuncusu önemli: Xdebug'ın RESMÎ yönergesi mutlak yol verir ve yol
            // karşılaştırıldığı için satır hiç temizlenmiyordu — uzantı devre dışı
            // bırakıldıktan sonra bile php.ini'den yükleniyordu.
            let value = t[t.index(after: eq)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            let file = (value as NSString).lastPathComponent
            let base = file.hasSuffix(".so") ? String(file.dropLast(3)) : file
            return base.lowercased() != name.lowercased()
        }.joined(separator: "\n")

        guard kept != content else { return }
        if FileHelper.write(kept, to: iniPath) {
            log(key: "log.php.iniDupCleaned", args: [name], type: .info)
        }
    }

    // MARK: - imagick Özel Kurulum (Intel & Apple Silicon)

    /// imagick kurulumu — sürümden bağımsız yapı:
    /// • Tüm yollar `opt/php@X.Y` symlink'i üzerinden çalışma anında `php-config`'den çözülür;
    ///   Cellar içindeki patch sürümü (8.3.30 → 8.3.31) değişse de script bozulmaz.
    /// • Cellar'daki `pecl` symlink'inin hedefi (`lib/php/pecl`) yoksa PECL'in kopyalama adımı
    ///   "failed to mkdir ... File exists" ile patlar — script hedefi önceden oluşturur.
    /// • Mevcut imagick.so gerçekten yüklenebiliyor mu diye test edilir; PHP/ImageMagick
    ///   yükseltmesi sonrası kırılan .so otomatik yeniden derlenir.
    /// • PECL'in kopyalaması yine de başarısız olursa derlenen .so PEAR temp dizininden kurtarılır.
    private func installImagick() {
        guard requireBrew(forKey: "log.op.imagickInstall") else { return }

        isLoading = true
        let version = selectedPHPVersion.rawValue
        let brewService = selectedPHPVersion.brewService
        let brewPrefix = Shell.brewPrefix
        let isAppleSilicon = brewPrefix == "/opt/homebrew"
        let confD = PathConfig.phpConfD(version: version)
        let markerPath = NSTemporaryDirectory() + "hy_imagick_status_\(UUID().uuidString)"

        log(key: "log.php.imagickStart", type: .command)
        log(key: "log.php.platform",
            args: [isAppleSilicon ? "Apple Silicon (arm64)" : "Intel (x86_64)"], type: .info)

        let installScript = """
        BREW_PREFIX="\(brewPrefix)"
        PHP_VERSION="\(version)"
        CONF_D="\(confD)"
        MARKER="\(markerPath)"

        # Sürüm yükseltmelerinde sabit kalan opt symlink'i üzerinden çalış
        PHP_PREFIX="$BREW_PREFIX/opt/php@$PHP_VERSION"
        PHP_BIN="$PHP_PREFIX/bin/php"
        PHP_CONFIG="$PHP_PREFIX/bin/php-config"
        PECL_BIN="$PHP_PREFIX/bin/pecl"
        PHP_INI="$BREW_PREFIX/etc/php/$PHP_VERSION/php.ini"

        main() {
            echo "══════════════════════════════════════════════════"
            echo "  imagick Kurulum — PHP $PHP_VERSION"
            echo "  Platform: \(isAppleSilicon ? "Apple Silicon (arm64)" : "Intel (x86_64)")"
            echo "  Adımlar: ImageMagick → pkg-config → ext dizini → imagick.so → ini → doğrulama"
            echo "══════════════════════════════════════════════════"
            echo ""

            if [ ! -x "$PHP_BIN" ]; then
                echo "❌ PHP $PHP_VERSION bulunamadı: $PHP_BIN"
                return 1
            fi

            # Adım 1: ImageMagick bağımlılığı
            echo "🔍 Adım 1: ImageMagick (bağımlılık) kontrol ediliyor..."
            if brew list imagemagick &>/dev/null; then
                echo "  ✅ ImageMagick kurulu: $(brew list --versions imagemagick)"
            else
                echo "  📦 ImageMagick bulunamadı, kuruluyor..."
                brew install imagemagick || { echo "  ❌ ImageMagick kurulamadı!"; return 1; }
                echo "  ✅ ImageMagick kuruldu"
            fi
            echo ""

            # Adım 2: pkg-config (imagick derlemesi için zorunlu)
            echo "🔍 Adım 2: pkg-config kontrol ediliyor..."
            if command -v pkg-config &>/dev/null; then
                echo "  ✅ pkg-config mevcut: $(pkg-config --version)"
            else
                echo "  📦 pkg-config bulunamadı, kuruluyor..."
                brew install pkg-config || { echo "  ❌ pkg-config kurulamadı!"; return 1; }
                echo "  ✅ pkg-config kuruldu"
            fi
            echo ""

            # Adım 3: Extension dizini — kırık pecl symlink'ini onar
            echo "🔍 Adım 3: PHP extension dizini hazırlanıyor..."
            EXT_DIR=$("$PHP_CONFIG" --extension-dir 2>/dev/null)
            if [ -z "$EXT_DIR" ]; then
                echo "  ❌ php-config çalıştırılamadı: $PHP_CONFIG"
                return 1
            fi
            echo "  ℹ️  Extension dizini: $EXT_DIR"

            PECL_DIR=$(dirname "$EXT_DIR")
            if [ -L "$PECL_DIR" ] && [ ! -e "$PECL_DIR" ]; then
                # Kırık symlink: Cellar/php@X.Y/*/pecl → lib/php/pecl var ama hedef dizin yok.
                # Bu durumda mkdir -p "File exists" hatası verir (PECL kurulumunun bilinen hatası).
                LINK_TARGET=$(readlink "$PECL_DIR")
                case "$LINK_TARGET" in
                    /*) : ;;
                    *) LINK_TARGET="$(dirname "$PECL_DIR")/$LINK_TARGET" ;;
                esac
                echo "  🔧 Kırık pecl symlink'i tespit edildi — hedef oluşturuluyor: $LINK_TARGET"
                mkdir -p "$LINK_TARGET" || { echo "  ❌ Symlink hedefi oluşturulamadı"; return 1; }
            fi
            mkdir -p "$EXT_DIR" 2>/dev/null
            if [ ! -d "$EXT_DIR" ]; then
                echo "  ❌ Extension dizini oluşturulamadı: $EXT_DIR"
                return 1
            fi
            echo "  ✅ Extension dizini hazır"
            echo ""

            # Adım 4: imagick.so — mevcutsa yüklenebilirliğini test et, gerekirse derle
            echo "🔍 Adım 4: imagick.so kontrol ediliyor..."
            NEEDS_BUILD=1
            if [ -f "$EXT_DIR/imagick.so" ]; then
                if "$PHP_BIN" -n -d extension="$EXT_DIR/imagick.so" -m 2>/dev/null | grep -qix imagick; then
                    echo "  ✅ imagick.so mevcut ve yüklenebiliyor"
                    NEEDS_BUILD=0
                else
                    echo "  ⚠️  imagick.so mevcut ama yüklenemiyor (PHP/ImageMagick sürümü değişmiş olabilir)"
                    echo "  🔄 Yeniden derlenecek..."
                fi
            else
                echo "  📦 imagick.so bulunamadı — derlenecek"
            fi

            if [ $NEEDS_BUILD -eq 1 ]; then
                "$PECL_BIN" channel-update pecl.php.net >/dev/null 2>&1
                # Eski PECL kaydını temizle (dosyalara dokunmadan) — "already installed" hatasını önler
                "$PECL_BIN" uninstall -r imagick >/dev/null 2>&1
                echo "  🛠  PECL ile derleniyor (birkaç dakika sürebilir)..."
                printf '\\n' | PKG_CONFIG_PATH="$BREW_PREFIX/opt/imagemagick/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" "$PECL_BIN" install -f imagick
                PECL_STATUS=$?

                if [ ! -f "$EXT_DIR/imagick.so" ]; then
                    # PECL'in son kopyalama adımı başarısız olduysa derlenen .so'yu temp'ten kurtar
                    echo "  🔎 imagick.so extension dizinine kopyalanmamış — PEAR temp derlemesi aranıyor..."
                    BUILT_SO=$(find "${TMPDIR:-/tmp}/pear" /private/tmp/pear /tmp/pear -type f -name imagick.so 2>/dev/null | head -1)
                    if [ -n "$BUILT_SO" ]; then
                        echo "  📋 Derlenen dosya bulundu: $BUILT_SO"
                        cp "$BUILT_SO" "$EXT_DIR/imagick.so" || { echo "  ❌ Kopyalama başarısız"; return 1; }
                        echo "  ✅ imagick.so extension dizinine kopyalandı"
                    elif [ $PECL_STATUS -ne 0 ]; then
                        echo "  ❌ imagick derlenemedi (pecl çıkış kodu: $PECL_STATUS)"
                        return 1
                    fi
                fi
                [ -f "$EXT_DIR/imagick.so" ] || { echo "  ❌ imagick.so bulunamadı"; return 1; }
            fi
            echo ""

            # Adım 5: PECL'in php.ini'ye eklediği satırı temizle (conf.d ile çift yükleme uyarısını önler)
            if [ -f "$PHP_INI" ] && grep -q '^ *extension *= *"\\{0,1\\}imagick\\.so"\\{0,1\\} *$' "$PHP_INI"; then
                sed -i '' '/^ *extension *= *"\\{0,1\\}imagick\\.so"\\{0,1\\} *$/d' "$PHP_INI"
                echo "🧹 php.ini'deki mükerrer imagick satırı temizlendi (conf.d kullanılıyor)"
                echo ""
            fi

            # Adım 6: conf.d ini dosyası
            echo "🔍 Adım 5: imagick.ini konfigürasyonu kontrol ediliyor..."
            INI_FILE="$CONF_D/ext-imagick.ini"
            DISABLED_FILE="$CONF_D/ext-imagick.ini.disabled"

            if [ -f "$INI_FILE" ]; then
                echo "  ✅ imagick.ini zaten aktif: $INI_FILE"
            elif [ -f "$DISABLED_FILE" ]; then
                echo "  🔧 imagick devre dışı, aktif ediliyor..."
                mv "$DISABLED_FILE" "$INI_FILE"
                echo "  ✅ imagick.ini aktif edildi"
            else
                echo "  📝 imagick.ini oluşturuluyor..."
                mkdir -p "$CONF_D"
                printf '[imagick]\\nextension="imagick.so"\\n' > "$INI_FILE"
                echo "  ✅ imagick.ini oluşturuldu: $INI_FILE"
            fi
            echo ""

            # Adım 7: Son doğrulama — PHP gerçekten yükleyebiliyor mu?
            echo "🔍 Adım 6: Kurulum doğrulanıyor..."
            if "$PHP_BIN" -m 2>/dev/null | grep -qix imagick; then
                IMAGICK_VER=$("$PHP_BIN" -r 'echo phpversion("imagick");' 2>/dev/null)
                echo "  ✅ imagick $IMAGICK_VER aktif"
            else
                echo "  ❌ imagick PHP tarafından yüklenemedi — Terminal çıktısını kontrol edin"
                return 1
            fi

            echo ""
            echo "✅ imagick kurulumu tamamlandı!"
            return 0
        }

        main
        STATUS=$?
        echo "$STATUS" > "$MARKER"
        (exit $STATUS)
        """

        TerminalHelper.runInNewWindowAndWait(installScript, title: "imagick Kurulumu — PHP \(version)")

        Task {
            await waitForImagickInstall(markerPath: markerPath,
                                        brewService: brewService,
                                        phpVersion: version)
        }
    }

    /// Terminal'deki kurulum bitene kadar marker dosyasını bekler; sonucu loglar ve PHP-FPM'i yeniden başlatır.
    private func waitForImagickInstall(markerPath: String, brewService: String, phpVersion: String) async {
        log(key: "log.php.imagickWaiting", type: .info)

        let deadline = Date().addingTimeInterval(20 * 60)
        var status: String?
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let s = FileHelper.readString(markerPath)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty {
                status = s
                break
            }
        }
        FileHelper.remove(markerPath)

        switch status {
        case "0":
            log(key: "log.php.imagickDone", args: [phpVersion], type: .success)
            restartBrewService(brewService, displayName: "PHP-FPM")
        case .some(let code):
            log(key: "log.php.imagickFailed", args: [code], type: .error)
        case nil:
            log(key: "log.php.imagickTimeout", type: .warning)
        }

        isLoading = false
        loadExtensions()
    }
    
    // MARK: - php.ini
    
    func loadPHPIniSettings() {
        guard Shell.isBrewInstalled else { return }
        // HER YÜKLEMEDE BAŞTAN KURULUR. Eskiden yalnızca regex EŞLEŞİRSE değer
        // yazılıyor, eşleşmezse öncekinin değeri olduğu gibi kalıyordu. İki sonucu
        // vardı: (a) dosyada hiç tanımlı olmayan bir direktif için panel varsayılanı
        // gerçek değermiş gibi gösteriyordu, (b) PHP sürümü değiştirilince ÖNCEKİ
        // sürümün değerleri yeni sürümün panelinde kalıyordu.
        var fresh = PHPIniSetting.commonSettings
        let iniPath = PathConfig.phpIni(version: selectedPHPVersion.rawValue)
        guard let content = FileHelper.readString(iniPath) else {
            phpIniSettings = fresh; return
        }

        for i in 0..<fresh.count {
            let escaped = NSRegularExpression.escapedPattern(for: fresh[i].name)
            if let regex = try? NSRegularExpression(pattern: "^\\s*\(escaped)\\s*=\\s*(.+)$", options: .anchorsMatchLines),
               let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
               let range = Range(match.range(at: 1), in: content) {
                let v = String(content[range]).trimmingCharacters(in: .whitespaces)
                if !v.isEmpty {
                    fresh[i].currentValue = v
                    fresh[i].isDefined = true
                }
            }
        }
        phpIniSettings = fresh
    }
    
    /// Tek direktif — toplu yola indirgenir ki iki ayrı yazma/restart mantığı olmasın.
    func updatePHPIniSetting(_ setting: PHPIniSetting, value: String) {
        updatePHPIniSettings([(setting, value)])
    }

    /// Birden çok direktifi TEK dosya yazımı ve TEK FPM yeniden başlatmasıyla uygular.
    ///
    /// Eskiden her direktif için ayrı çağrı yapılıyordu ve her biri kendi
    /// `restartBrewService`ini tetikliyordu: üç ayarı değiştirip bir kez "Kaydet"e
    /// basmak ÜÇ bağımsız `brew services stop` + `run` çifti demekti. Bunlar gerçekten
    /// eşzamanlı koşuyor, Homebrew'un servis kilidi çakışıyor ve kilidi kaçıran `run`
    /// sessizce düşerse PHP-FPM DURMUŞ kalıyordu.
    func updatePHPIniSettings(_ changes: [(setting: PHPIniSetting, value: String)]) {
        guard requireBrew(forKey: "log.op.phpIniUpdate"), !changes.isEmpty else { return }

        let iniPath = PathConfig.phpIni(version: selectedPHPVersion.rawValue)
        guard var content = FileHelper.readString(iniPath) else {
            log(key: "log.php.iniNotFound", type: .error); return
        }
        guard FileHelper.write(content, to: iniPath + ".brampp.bak") else {
            log(key: "log.php.iniBackupFailed", args: [iniPath], type: .error); return
        }

        for c in changes {
            let escaped = NSRegularExpression.escapedPattern(for: c.setting.name)
            if let regex = try? NSRegularExpression(pattern: "^\\s*;?\\s*\(escaped)\\s*=.*$",
                                                    options: .anchorsMatchLines),
               let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
               let range = Range(match.range, in: content) {
                content.replaceSubrange(range, with: "\(c.setting.name) = \(c.value)")
            } else {
                content += "\n\(c.setting.name) = \(c.value)"
            }
        }

        guard FileHelper.write(content, to: iniPath) else {
            log(key: "log.php.iniUpdateFailed", type: .error); return
        }
        for c in changes {
            if let idx = phpIniSettings.firstIndex(where: { $0.id == c.setting.id }) {
                phpIniSettings[idx].currentValue = c.value
            }
            log(key: "log.php.iniUpdated", args: [c.setting.name, c.value], type: .success)
        }
        restartBrewService(selectedPHPVersion.brewService, displayName: "PHP-FPM")
    }
    
    // MARK: - Helpers
    
    private func prepareSelectedPHPFPMIfNeeded() {
        let version = selectedPHPVersion.rawValue
        let wwwConfPath = PathConfig.phpFpmConf(version: version)
        guard FileHelper.exists(wwwConfPath) else { return }

        if PHPFPMConfigManager.normalize(for: version) {
            log(key: "log.php.fpmPrepared", args: [version], type: .info)
        }
    }

    private func generateConfig(for ext: PHPExtension) -> String {
        let dir = (ext.name == "xdebug" || ext.name == "opcache") ? "zend_extension" : "extension"
        return "[\(ext.name)]\n\(dir)=\"\(ext.name).so\""
    }
    
    func extensions(for category: ExtensionCategory) -> [PHPExtension] { extensions.filter { $0.category == category } }
    
    func changePHPVersion(to version: PHPVersion) {
        selectedPHPVersion = version
        prepareSelectedPHPFPMIfNeeded()
        loadExtensions()
    }
}
