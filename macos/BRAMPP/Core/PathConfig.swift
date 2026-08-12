import Foundation

/// Tüm sabit path tanımları — Apple Silicon / Intel otomatik.
struct PathConfig {

    // MARK: - Homebrew önekine göre türetilen yollar (SAF)

    /// Homebrew öneki bir PARAMETRE olarak verildiğinde yolları üreten saf formüller.
    ///
    /// Aşağıdaki `static let` sabitleri bunları `brewBase` ile çağırır — tanım tektir,
    /// yalnızca öneki nereden aldığı değişir. Gerekçesi `ServiceManager.uninstallPlan`:
    /// plan "saf" olduğunu söylüyordu ama döndürdüğü her yol `Shell.brewPrefix` üzerinden
    /// GERÇEK makineye bağlıydı; birim testleri de `brew --prefix` çağırmak zorunda
    /// kalıyordu. Buradaki formüllerle plan gerçekten saf olur ve test hayalî bir
    /// önekle (`/brewtest`) çalışır.
    enum Brew {
        static func httpdBase(_ base: String) -> String  { "\(base)/etc/httpd" }
        static func httpdConf(_ base: String) -> String  { "\(httpdBase(base))/httpd.conf" }
        static func httpdExtra(_ base: String) -> String { "\(httpdBase(base))/extra" }
        static func vhostsDir(_ base: String) -> String  { "\(httpdBase(base))/VirtualHosts" }
        static func httpdSSLConf(_ base: String) -> String   { "\(httpdExtra(base))/httpd-ssl.conf" }
        static func phpmyadminConf(_ base: String) -> String { "\(httpdExtra(base))/phpmyadmin.conf" }
        static func adminerConf(_ base: String) -> String    { "\(httpdExtra(base))/adminer.conf" }
        static func pgadmin4Conf(_ base: String) -> String   { "\(httpdExtra(base))/pgadmin4.conf" }
        /// phpMyAdmin'in kendi PHP yapılandırması (kullanıcı düzenleyebilir)
        static func phpmyadminAppConfig(_ base: String) -> String { "\(base)/etc/phpmyadmin.config.inc.php" }
        /// brew paketinin web kökü
        static func phpmyadminDir(_ base: String) -> String { "\(base)/share/phpmyadmin" }
        static func nginxBase(_ base: String) -> String { "\(base)/etc/nginx" }
        static func nginxConf(_ base: String) -> String { "\(nginxBase(base))/nginx.conf" }
        static func nginxSitesAvailableDir(_ base: String) -> String { "\(nginxBase(base))/sites-available" }
    }

    // MARK: - Homebrew
    static let brewBase: String = Shell.brewPrefix
    static let brewBin: String  = "\(brewBase)/bin"
    static let brew: String     = "\(brewBin)/brew"
    static let mkcert: String   = "\(brewBin)/mkcert"
    static let node: String     = "\(brewBin)/node"
    static let dotnet: String   = "\(brewBin)/dotnet"
    static let cloudflared: String = "\(brewBin)/cloudflared"

    /// composer / npm — birden çok yerde bulunabilir; ilk var olan döner, yoksa boş.
    /// Node sürümleri Homebrew'da `node@22/bin` gibi ayrı öneklerde durabiliyor.
    static var composer: String { firstExisting(["\(brewBin)/composer", "/usr/local/bin/composer"]) }
    static var npm: String {
        firstExisting(["\(brewBin)/npm", "\(brewBase)/opt/node@22/bin/npm",
                       "\(brewBase)/opt/node@20/bin/npm", "\(brewBase)/opt/node/bin/npm",
                       "/usr/local/bin/npm"])
    }

    private static func firstExisting(_ paths: [String]) -> String {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
    }
    static let psql: String     = "\(brewBin)/psql"

    // MARK: - Kullanıcı
    static let home: String         = FileManager.default.homeDirectoryForCurrentUser.path
    static let sites: String        = "\(home)/Sites"
    static let sitesDir: String     = sites
    static let localhostDir: String = "\(sites)/localhost"
    static let appSupport: String   = "\(home)/Library/Application Support/BRAMPP"
    static let ssl: String          = "\(appSupport)/ssl"
    static let sslDir: String       = ssl
    static let localhostSSLDir: String = "\(ssl)/localhost"
    static let domainsJson: String  = "\(appSupport)/domains.json"
    static let settingsJson: String = "\(appSupport)/settings.json"
    /// Son çalışan brew servis ID'leri — açılışta "son çalışanları başlat" için
    static let lastRunningJson: String = "\(appSupport)/last-running-services.json"
    static let backups: String      = "\(appSupport)/backups"
    /// Konsolun diskteki günlük kopyaları — bkz. Core/ConsoleLogFile.swift
    static let logs: String         = "\(appSupport)/logs"
    /// Cloudflare Quick Tunnel süreçlerinin PID ve log dosyaları
    static let tunnels: String      = "\(appSupport)/tunnels"

    /// İndirilen güncelleme dosyalarının hazırlık alanı.
    /// `/tmp` DEĞİL (herkese okunur; doğrulama ile açma arasında dosya takas edilebilir),
    /// `~/Downloads` DEĞİL (kullanıcı biz doğrulamadan çift tıklayabilir).
    static let updates: String      = "\(appSupport)/updates"
    /// Yerinde güncellemenin takas betiği ve GÜNLÜĞÜ.
    ///
    /// `updates/` ALTINDA DEĞİL, çünkü `UpdateInstaller.pruneOldStaging` her açılışta o
    /// dizindeki noktayla başlamayan her adı siliyor. Başarısız bir güncellemenin tek
    /// kara kutusu, geri dönen eski sürüm açılır açılmaz yok olurdu.
    static let swapDir: String      = "\(appSupport)/swap"

    static func tunnelPid(domain: String) -> String { "\(tunnels)/\(domain).pid" }
    static func tunnelLog(domain: String) -> String { "\(tunnels)/\(domain).log" }

    /// Tek bir KOŞUNUN hazırlık dizininin ADI — sürümün değil.
    ///
    /// **NEDEN SÜRÜM YETMEZ:** dizin yalnızca sürümden türetildiğinde aynı sürümün iki
    /// koşusu AYNI dizini paylaşırdı; ikincisi `remove(dir)` ile birincinin inmekte olan
    /// dosyasını siler, birincisi hata verip temizlenirken bu kez ikincinin dizinini
    /// silerdi. Bunu önlemek için yeni koşu öncekinin BİTMESİNİ bekliyordu — ve o
    /// bekleyiş, önceki koşu hiç bitmezse kurucuyu oturum boyunca kilitliyordu.
    /// Koşu numarası çakışmayı İFADE EDİLEMEZ kılar; beklemeye gerek kalmaz.
    ///
    /// `version` `UpdateChecker.normalize()` çıktısıdır — yalnızca rakam ve tek noktalar
    /// içerir; `run` bir tamsayı. İkisi de yola ".." gibi bir bileşen sokamaz.
    static func updateStagingName(version: String, run: Int) -> String { "\(version)-\(run)" }

    /// Adı bilinen bir hazırlık dizininin tam yolu.
    static func updateStaging(name: String) -> String { "\(updates)/\(name)" }

    /// Tek bir koşunun hazırlık dizini.
    static func updateStaging(version: String, run: Int) -> String {
        updateStaging(name: updateStagingName(version: version, run: run))
    }

    // MARK: - SSL Helper'lar (tekrarlanan path'leri merkeze al)

    /// Domain için SSL dizini
    static func sslDirPath(for domain: String) -> String { "\(ssl)/\(domain)" }
    /// Domain için SSL sertifika yolu
    static func sslCertPath(for domain: String) -> String { "\(ssl)/\(domain)/cert.pem" }
    /// Domain için SSL anahtar yolu
    static func sslKeyPath(for domain: String) -> String { "\(ssl)/\(domain)/key.pem" }

    /// Verilen yol PAYLAŞILAN localhost SSL dizini mi?
    ///
    /// `ssl/localhost` sertifikasını Apache ve Nginx ORTAK kullanır (varsayılan vhost'lar,
    /// phpMyAdmin/Adminer…). Tek bir domain kaydı silinirken/yeniden adlandırılırken bu
    /// dizinin silinmesi her iki sunucunun HTTPS'ini birden kırar — silme yolları önce
    /// bunu sorar.
    static func isSharedLocalhostSSLDir(_ path: String) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.path
            == URL(fileURLWithPath: localhostSSLDir).standardizedFileURL.path
    }

    // MARK: - Nginx
    static let nginxBase: String               = Brew.nginxBase(brewBase)
    static let nginxConf: String               = Brew.nginxConf(brewBase)
    static let nginxServersDir: String         = "\(nginxBase)/servers"         // legacy
    static let nginxLocalhostConf: String      = "\(nginxBase)/servers/localhost.conf"  // legacy
    static let nginxSitesAvailableDir: String  = Brew.nginxSitesAvailableDir(brewBase)
    static let nginxLogs: String               = "\(brewBase)/var/log/nginx"

    // MARK: - Apache
    static let httpdBase: String         = Brew.httpdBase(brewBase)
    static let httpdConf: String         = Brew.httpdConf(brewBase)
    static let vhostsDir: String         = Brew.vhostsDir(brewBase)
    /// Varsayılan localhost vhost — 000- öneki sayesinde alfabetik İLK yüklenir;
    /// Host eşleşmeyen isteklerin domain vhost'larına düşmesini önler
    static let apacheDefaultVHost: String = "\(vhostsDir)/000-localhost.conf"
    static let httpdExtra: String        = Brew.httpdExtra(brewBase)
    static let httpdSSLConf: String      = Brew.httpdSSLConf(brewBase)
    static let phpmyadminConf: String    = Brew.phpmyadminConf(brewBase)
    static let phpmyadminAppConfig: String = Brew.phpmyadminAppConfig(brewBase)
    static let httpdLogs: String         = "\(brewBase)/var/log/httpd"
    static let httpdAccessLog: String    = "\(httpdLogs)/access_log"
    static let httpdErrorLog: String     = "\(httpdLogs)/error_log"

    // MARK: - PHP
    static let phpBase: String       = "\(brewBase)/etc/php"
    static let phpOpt: String        = "\(brewBase)/opt"
    static let phpmyadminDir: String = Brew.phpmyadminDir(brewBase)
    /// Gerçek brew paketi kurulu mu? (Apache config dosyasından bağımsız)
    static var isPhpMyAdminInstalled: Bool { Shell.isBrewInstalled && FileHelper.exists(phpmyadminDir) }

    static func phpIni(version: String) -> String     { "\(phpBase)/\(version)/php.ini" }
    static func phpConfD(version: String) -> String   { "\(phpBase)/\(version)/conf.d" }
    static func phpFpmConf(version: String) -> String { "\(phpBase)/\(version)/php-fpm.d/www.conf" }
    static func phpBin(version: String) -> String     { "\(phpOpt)/php@\(version)/bin/php" }
    static func peclBin(version: String) -> String    { "\(phpOpt)/php@\(version)/bin/pecl" }
    static func nodeBin(version: String) -> String    { "\(phpOpt)/node@\(version)/bin/node" }
    /// .NET sürüme özgü dotnet binary — her major sürüm kendi opt dizininde (opt/dotnet@7)
    static func dotnetBin(majorVersion: String) -> String { "\(phpOpt)/dotnet@\(majorVersion)/bin/dotnet" }

    /// Python yürütücü yolu.
    /// Brew, Python 3.12+ için gerçek binary'yi `libexec/bin/` altına koyar;
    /// `bin/python3` wrapper olabilir veya hiç olmayabilir.
    /// Kontrol sırası: libexec/bin → opt/bin → brewBase/bin/python3.X
    static func pythonBin(version: String) -> String {
        let libexec    = "\(phpOpt)/python@\(version)/libexec/bin/python3"
        let standard   = "\(phpOpt)/python@\(version)/bin/python3"
        let brewDirect = "\(brewBase)/bin/python\(version)"   // /opt/homebrew/bin/python3.12
        if FileHelper.exists(libexec)    { return libexec }
        if FileHelper.exists(standard)   { return standard }
        if FileHelper.exists(brewDirect) { return brewDirect }
        return standard  // fallback — shell script'te de ek kontrol var
    }

    // MARK: - PostgreSQL
    static let pgBase: String = "\(brewBase)/var/postgresql"

    /// PostgreSQL asıl config'i data dizinindedir — Homebrew `etc/postgresql@X/` OLUŞTURMAZ.
    /// initdb postgresql.conf'u `var/postgresql@X/` içine yazar; düzenlemeler burada yapılmalı.
    static func pgConf(version: String) -> String     { "\(pgDataDir(version: version))/postgresql.conf" }
    static func pgDataDir(version: String) -> String   { "\(brewBase)/var/postgresql@\(version)" }
    static func pgBin(version: String) -> String       { "\(phpOpt)/postgresql@\(version)/bin/psql" }

    // MARK: - pgAdmin4 (web version — brew install pgadmin4)
    static let pgadmin4Dir: String        = "\(brewBase)/opt/pgadmin4"
    static let pgadmin4Conf: String       = Brew.pgadmin4Conf(brewBase)          // Apache include
    static let pgadmin4NginxConf: String  = "\(nginxSitesAvailableDir)/pgadmin4.conf"  // Nginx site
    static let pgadmin4Port: Int          = 5050
    static var isPgAdmin4Installed: Bool  { Shell.isBrewInstalled && FileHelper.exists(pgadmin4Dir) }
    /// pgAdmin kullanıcı verisi (kayıtlı sunucu bağlantıları vb.) — kaldırmada temizlenir
    static let pgadmin4DataDir: String    = "\(NSHomeDirectory())/.pgadmin"

    // MARK: - MariaDB / Redis config
    /// Homebrew my.cnf `!includedir my.cnf.d` kullanır — kendi ayar dosyamızı buraya
    /// yazarız ki kullanıcının my.cnf'i regex ile bozulmasın.
    static let mariadbConfDir: String     = "\(brewBase)/etc/my.cnf.d"
    static let mariadbOwnConf: String     = "\(mariadbConfDir)/zz-brampp.cnf"
    static let redisConf: String          = "\(brewBase)/etc/redis.conf"

    // MARK: - Adminer (tek dosyalı web DB yöneticisi — MySQL + PostgreSQL + SQLite)
    /// brew'un standart web köküne kurulur (boşluksuz yol — Apache/Nginx config'leri sade kalır)
    static let adminerDir: String   = "\(brewBase)/var/www/adminer"
    static let adminerFile: String  = "\(adminerDir)/index.php"
    static let adminerConf: String  = Brew.adminerConf(brewBase)     // Apache include
    static var isAdminerInstalled: Bool { FileHelper.exists(adminerFile) }

    // MARK: - Süreç Yönetimi (NativeProcessManager)
    /// Tüm app platformları (Node.js, Python, .NET) için süreç dosyaları:
    /// `~/Library/Application Support/BRAMPP/processes/{domainName}/`
    static let processes: String = "\(appSupport)/processes"

    static func processDir(domain: String) -> String      { "\(processes)/\(domain)" }
    static func processPid(domain: String) -> String      { "\(processDir(domain: domain))/app.pid" }
    static func processLog(domain: String) -> String      { "\(processDir(domain: domain))/app.log" }
    static func processScript(domain: String) -> String   { "\(processDir(domain: domain))/start.sh" }
    static func processConfig(domain: String) -> String   { "\(processDir(domain: domain))/.brampp.json" }

    // Eski Python path'leri — geriye dönük uyumluluk
    static let pids: String       = "\(appSupport)/pids"
    static let pythonLogs: String = "\(appSupport)/python-logs"
    static func pythonPidFile(domain: String) -> String  { "\(pids)/\(domain).pid" }
    static func pythonLogFile(domain: String) -> String  { "\(pythonLogs)/\(domain).log" }

    /// Python bin dizini — venv yoksa PythonProcessManager tarafından PATH'e eklenir.
    /// libexec/bin varsa onu, yoksa bin'i döner.
    static func pythonOptBin(version: String) -> String {
        let libexec = "\(phpOpt)/python@\(version)/libexec/bin"
        return FileHelper.exists(libexec) ? libexec : "\(phpOpt)/python@\(version)/bin"
    }

    // MARK: - Sistem
    static let hosts: String = "/etc/hosts"

    // MARK: - Portlar
    struct Ports {
        static let php81 = 9081, php82 = 9082, php83 = 9083, php84 = 9084, php85 = 9085
        static let nodeRange: ClosedRange<Int>   = 3001...3099
        static let pythonRange: ClosedRange<Int> = 8001...8099
        static let dotnetRange: ClosedRange<Int> = 5001...5099
        static let mariadb = 3306, redis = 6379, memcached = 11211
        static let postgresql = 5432

        static func phpPort(version: String) -> Int {
            switch version {
            case "8.1": return php81; case "8.2": return php82
            case "8.3": return php83; case "8.4": return php84
            case "8.5": return php85
            default: return php83
            }
        }
    }

    // MARK: - Dizin Oluşturma

    static func createRequiredDirectories() {
        [sites, localhostDir, appSupport, ssl, localhostSSLDir, backups, processes].forEach { FileHelper.createDirectory($0) }
        if Shell.isBrewInstalled { FileHelper.createDirectory(vhostsDir) }
    }

    /// Domain'e ait process dizinini oluşturur (start.sh / app.pid / app.log için).
    static func createProcessDir(for domain: String) {
        FileHelper.createDirectory(processDir(domain: domain))
    }

    // MARK: - Kurulum Kontrolleri

    static var isHomebrewInstalled: Bool { Shell.isBrewInstalled }
    static var isMkcertInstalled: Bool   { Shell.isBrewInstalled && FileHelper.exists(mkcert) }
    static var isNginxInstalled: Bool    { Shell.isBrewInstalled && FileHelper.exists("\(brewBase)/opt/nginx") }

    static func isPHPInstalled(version: String) -> Bool    { Shell.isBrewInstalled && FileHelper.exists(phpBin(version: version)) }
    static func isNodeInstalled(version: String) -> Bool   { Shell.isBrewInstalled && FileHelper.exists(nodeBin(version: version)) }
    static func isPythonInstalled(version: String) -> Bool {
        guard Shell.isBrewInstalled else { return false }
        // libexec/bin veya bin altında python3 olabilir
        let libexec  = "\(phpOpt)/python@\(version)/libexec/bin/python3"
        let standard = "\(phpOpt)/python@\(version)/bin/python3"
        return FileHelper.exists(libexec) || FileHelper.exists(standard)
    }
    static var isDotNetInstalled: Bool                     { Shell.isBrewInstalled && FileHelper.exists(dotnet) }
    static func isPostgreSQLInstalled(version: String) -> Bool { Shell.isBrewInstalled && FileHelper.exists("\(phpOpt)/postgresql@\(version)") }
}
