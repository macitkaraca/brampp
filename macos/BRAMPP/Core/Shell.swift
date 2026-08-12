import Foundation
import Darwin

// MARK: - Shell

/// Shell komutları — Apple Silicon & Intel uyumlu.
/// Homebrew yoksa güvenli fallback, uygulama çökmez.
final class Shell {
    
    // MARK: - Result
    
    struct Result {
        let output: String
        let error: String
        let exitCode: Int32

        var isSuccess: Bool { exitCode == 0 }
        var hasOutput: Bool { isSuccess && !output.isEmpty }
        /// osascript sudo dialogu kullanıcı tarafından iptal edildi
        var isUserCancelled: Bool {
            exitCode == -128 || error.localizedCaseInsensitiveContains("User canceled")
                              || error.localizedCaseInsensitiveContains("kullanıcı iptal")
        }

        var isTimeout: Bool { exitCode == -998 }

        static let brewNotInstalled = Result(
            output: "", error: "Homebrew kurulu değil.", exitCode: -99
        )
        static let userCancelled = Result(
            output: "", error: "İşlem kullanıcı tarafından iptal edildi.", exitCode: -128
        )
        static let timeout = Result(
            output: "", error: "Zaman aşımı", exitCode: -998
        )
    }
    
    // MARK: - Brew Detection
    
    static let brewPrefix: String = {
        if FileHelper.exists("/opt/homebrew/bin/brew") { return "/opt/homebrew" }
        if FileHelper.exists("/usr/local/bin/brew") { return "/usr/local" }
        
        // which brew dene
        do {
            let task = Process()
            let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            task.arguments = ["brew"]
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            try task.run()
            task.waitUntilExit()
            if let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                // Yol her zaman "<prefix>/bin/brew" biçimindedir → İKİ kez üst dizine çık.
                // Eski `replacingOccurrences(of: "/bin")` TÜM eşleşmeleri siliyordu; içinde
                // "/bin" geçen bir dizin adı (ör. /Users/binali/hb/bin/brew) prefix'i bozardı.
                let binDir = (path as NSString).deletingLastPathComponent          // <prefix>/bin
                let prefix = (binDir as NSString).deletingLastPathComponent        // <prefix>
                if !prefix.isEmpty, prefix != "/" { return prefix }
            }
        } catch {
            print("⚠️ 'which brew' başarısız: \(error.localizedDescription)")
        }

        #if arch(arm64)
        return "/opt/homebrew"
        #else
        return "/usr/local"
        #endif
    }()
    
    static let brewBin: String = "\(brewPrefix)/bin/brew"
    static var isBrewInstalled: Bool { FileHelper.exists(brewBin) }

    // MARK: - Verbose Log Hook
    /// Ayarlar → Konsol → "Tüm komutları kaydet" açıkken çağrılır.
    /// AppState tarafından set edilir; her bashAsync çağrısı öncesinde komutu iletir.
    static var verboseLogCallback: ((String) -> Void)?

    static let shellEnv: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "\(brewPrefix)/bin:\(brewPrefix)/sbin:\(existing)"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        return env
    }()
    
    // MARK: - Homebrew Installation
    
    /// Homebrew kuruluysa true döner; değilse kurulumu YENİ bir Terminal penceresinde BAŞLATIR.
    ///
    /// - Önemli: `do script` osascript'i, komut Terminal'e iletilir iletilmez döner — kurulum
    ///   BİTİMİNİ beklemez. Bu yüzden kurulum başlatıldıktan sonra dönüş `isBrewInstalled`
    ///   (yani "şu an kurulu mu") olur — kurulum daha yeni başladığından bu genelde `false`'tur.
    ///   Çağıran taraf, kullanıcı Terminal'deki kurulumu bitirdikten sonra tekrar kontrol etmelidir.
    @discardableResult
    static func ensureBrewInstalled() -> Bool {
        if isBrewInstalled { return true }
        let appleScript = """
        tell application "Terminal"
            activate
            do script "/bin/bash -c \\"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\\""
        end tell
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", appleScript]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do { try task.run(); task.waitUntilExit() }
        catch { return false }
        // osascript başarıyla Terminal'i tetikledi ≠ Homebrew kuruldu. Gerçek durumu döndür.
        return isBrewInstalled
    }
    
    @discardableResult
    static func ensureBrewInstalledAsync() async -> Bool {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: ensureBrewInstalled()) }
        }
    }
    
    // MARK: - Core: Senkron

    /// İki pipe'ın eş zamanlı boşaltılmasında kullanılan kutu — DispatchGroup ile senkronize.
    private final class PipeDataBox {
        var out = Data()
        var err = Data()
    }

    @discardableResult
    static func run(_ executable: String, arguments: [String] = [], environment: [String: String]? = nil) -> Result {
        guard FileHelper.exists(executable) else {
            return Result(output: "", error: "Dosya bulunamadı: \(executable)", exitCode: -1)
        }
        let task = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = outPipe
        task.standardError = errPipe
        task.environment = environment ?? shellEnv

        do {
            try task.run()
        } catch {
            return Result(output: "", error: error.localizedDescription, exitCode: -1)
        }

        // Deadlock önlemi: pipe'lar süreç bitmeden boşaltılmalı. Kernel pipe tamponu ~64KB;
        // komut daha fazla çıktı üretirse child write() üzerinde bloklanır ve
        // waitUntilExit() sonsuza dek bekler. Bu yüzden okuma eş zamanlı başlar.
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        let box = PipeDataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { box.out = outHandle.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { box.err = errHandle.readDataToEndOfFile(); group.leave() }

        task.waitUntilExit()
        group.wait()

        let output = String(data: box.out, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let error = String(data: box.err, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Result(output: output, error: error, exitCode: task.terminationStatus)
    }
    
    /// `run`, AMA SÜRESİ SINIRLI. Sözleşme `streamBash` ile birebir aynı: süre dolarsa
    /// SIGTERM, üç saniye sonra SIGKILL ve `exitCode == -998` (`Result.isTimeout`).
    ///
    /// NEDEN AYRI BİR İŞLEV: düz `run` `waitUntilExit()` çağırır ve bekleyeni SÜRESİZ
    /// tutar. Güncelleme doğrulamasında bu somut bir sorundu — `spctl --assess` Apple'a
    /// bir tur atar ve captive portal arkasında dakikalarca asılı kalabilir; `Process`
    /// görev iptalini dinlemediği için kullanıcının "durdur" düğmesi de çaresiz kalır.
    /// Sınır, iptali gerçekten uygulanabilir kılan şeydir.
    ///
    /// Etiketli parametre sayesinde eski `run(_:arguments:environment:)` çağrıları
    /// olduğu gibi kalır — hiçbir çağrı yeri sessizce davranış değiştirmez.
    @discardableResult
    static func run(_ executable: String, arguments: [String] = [], timeout: TimeInterval,
                    environment: [String: String]? = nil) -> Result {
        guard FileHelper.exists(executable) else {
            return Result(output: "", error: "Dosya bulunamadı: \(executable)", exitCode: -1)
        }
        let task = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = outPipe
        task.standardError = errPipe
        task.environment = environment ?? shellEnv

        do {
            try task.run()
        } catch {
            return Result(output: "", error: error.localizedDescription, exitCode: -1)
        }

        // Deadlock önlemi `run` ile aynı: pipe'lar süreç bitmeden boşaltılmalı.
        //
        // `timedOut` ve tamponlar YALNIZCA bu kilit altında okunur/yazılır. Kilit
        // zamanlayıcıyı `waitUntilExit` dönüşüyle uzlaştırmanın yanı sıra AŞAĞIDAKİ
        // sınırlı bekleyiş için de gerekli: bekleyiş süreye takılırsa okuyucular hâlâ
        // yazıyor olabilir ve tamponları kilitsiz okumak veri yarışı olurdu.
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        let box = PipeDataBox()
        let lock = NSLock()
        var timedOut = false
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = outHandle.readDataToEndOfFile()
            lock.lock(); box.out = data; lock.unlock()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = errHandle.readDataToEndOfFile()
            lock.lock(); box.err = data; lock.unlock()
            group.leave()
        }

        let item = DispatchWorkItem {
            lock.lock(); timedOut = true; lock.unlock()
            if task.isRunning { task.terminate() }                       // SIGTERM
            // Nazikçe ölmezse zorla — pipe'lar kapanır, okuyucular EOF alır.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: item)

        task.waitUntilExit()
        item.cancel()

        // **SINIR ÇOCUĞU DEĞİL, BEKLEYENİ BAĞLAR.** `timeout` yalnızca alt sürecin
        // ömrünü sınırlar; okuma tarafını sınırlamazsa söz tutulmaz. Alt süreç, yazma
        // ucunu MİRAS ALAN bir torun bırakırsa (ör. arka plana atılmış bir yardımcı)
        // pipe kapanmaz, `readDataToEndOfFile` EOF beklemeye devam eder ve SINIRSIZ bir
        // `group.wait()` çağıranı sonsuza kadar asardı — `runAsync(…timeout:)` hiç
        // dönmez, onu bekleyen güncelleme boru hattı da `.verifying`de donardı.
        // `streamBash` bunu zaten sınırlı bekliyor (bkz. aynı dosyadaki 5 sn'lik
        // bekleyiş); sözleşmenin "birebir aynı" olduğunu söyleyen doküman yorumu
        // ancak burada da sınırlıysa doğrudur.
        let drained = group.wait(timeout: .now() + 5) != .timedOut

        lock.lock()
        let didTimeout = timedOut
        let outData = box.out
        let errData = box.err
        lock.unlock()

        let output = String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let error = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Boşaltılamayan pipe da ZAMAN AŞIMIDIR: elimizdeki çıktı eksik olabilir, yani
        // "0 ile döndü, çıktısı buydu" demek YANLIŞ olur. Çağıran (ör. `spctl` kapısı)
        // `isTimeout`u zaten "görmedik" sayıyor — kabul tarafına düşmesi tehlikeliydi.
        if didTimeout || !drained {
            return Result(output: output,
                          error: (error + "\nKomut zaman aşımına uğradı")
                              .trimmingCharacters(in: .whitespacesAndNewlines),
                          exitCode: -998)                                 // Result.isTimeout
        }
        return Result(output: output, error: error, exitCode: task.terminationStatus)
    }

    // MARK: - Bash

    @discardableResult
    static func bash(_ command: String) -> Result {
        run("/bin/bash", arguments: ["-c", command])
    }

    /// Bir string'i bash için tek-tırnak içine güvenle sarar (içteki ' → '\'' ).
    /// Kullanıcı seçtiği document root gibi apostrof içerebilen yolları komutlara gömerken kullanılır.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    
    // MARK: - Brew (Güvenli)
    
    @discardableResult
    static func brew(_ arguments: String...) -> Result {
        guard isBrewInstalled else { return .brewNotInstalled }
        return run(brewBin, arguments: Array(arguments))
    }
    
    @discardableResult
    static func brewArgs(_ arguments: [String]) -> Result {
        guard isBrewInstalled else { return .brewNotInstalled }
        return run(brewBin, arguments: arguments)
    }
    
    @discardableResult
    static func brewServices(_ action: String, service: String) -> Result {
        guard isBrewInstalled else { return .brewNotInstalled }
        switch action {
        case "start", "run":
            // run semantiği: login'de auto-start OLMAZ (bkz. brewServicesAsync)
            return run(brewBin, arguments: ["services", "run", service])
        case "restart":
            // run semantiğini koru: brew restart yerine stop + run
            _ = run(brewBin, arguments: ["services", "stop", service])
            return run(brewBin, arguments: ["services", "run", service])
        default:
            return run(brewBin, arguments: ["services", action, service])
        }
    }
    
    static func getBrewServicesList() -> [String: String] {
        guard isBrewInstalled else { return [:] }
        let result = brew("services", "list")
        guard result.isSuccess else { return [:] }
        var dict: [String: String] = [:]
        for line in result.output.components(separatedBy: "\n").dropFirst() {
            let p = line.split(separator: " ", omittingEmptySubsequences: true)
            if p.count >= 2 { dict[String(p[0])] = String(p[1]) }
        }
        return dict
    }
    
    // MARK: - Sudo
    
    static func sudo(_ command: String, completion: @escaping (Result) -> Void) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
            task.standardOutput = outPipe; task.standardError = errPipe
            do {
                try task.run()
                // Deadlock önlemi: pipe'ları süreç bitmeden boşalt (run() ile aynı desen)
                let outHandle = outPipe.fileHandleForReading
                let errHandle = errPipe.fileHandleForReading
                let box = PipeDataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async { box.out = outHandle.readDataToEndOfFile(); group.leave() }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async { box.err = errHandle.readDataToEndOfFile(); group.leave() }
                task.waitUntilExit()
                group.wait()

                let out = String(data: box.out, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let err = String(data: box.err, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                // osascript iptali stderr'e "execution error: User canceled. (-128)" yazar,
                // exit kodu ise 1'dir — isUserCancelled'ın çalışması için -128'e çevir.
                let cancelled = err.contains("-128") || err.localizedCaseInsensitiveContains("User canceled")
                let code: Int32 = cancelled ? -128 : task.terminationStatus
                DispatchQueue.main.async { completion(Result(output: out, error: err, exitCode: code)) }
            } catch {
                DispatchQueue.main.async { completion(Result(output: "", error: error.localizedDescription, exitCode: -1)) }
            }
        }
    }
    
    // MARK: - Async

    static func runAsync(_ exe: String, arguments: [String] = []) async -> Result {
        await withCheckedContinuation { (c: CheckedContinuation<Result, Never>) in DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: run(exe, arguments: arguments)) } }
    }
    /// Süresi sınırlı `runAsync` — bkz. `run(_:arguments:timeout:environment:)`.
    static func runAsync(_ exe: String, arguments: [String] = [], timeout: TimeInterval) async -> Result {
        await withCheckedContinuation { (c: CheckedContinuation<Result, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                c.resume(returning: run(exe, arguments: arguments, timeout: timeout))
            }
        }
    }
    static func bashAsync(_ cmd: String) async -> Result {
        verboseLogCallback?(cmd)
        return await withCheckedContinuation { (c: CheckedContinuation<Result, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: bash(cmd)) }
        }
    }
    /// `sudo()` fonksiyonunun async versiyonu — osascript ile yönetici şifresi dialog'u gösterir.
    static func sudoAsync(_ cmd: String) async -> Result {
        await withCheckedContinuation { (c: CheckedContinuation<Result, Never>) in sudo(cmd) { c.resume(returning: $0) } }
    }

    // MARK: - osascript Sudo (yönetici parolası)

    /// osascript `do shell script ... with administrator privileges` ile komutu root çalıştırır.
    static func sudoAuthorized(_ command: String) async -> Result {
        return await sudoAsync(command)
    }
    /// Brew yoksa güvenli hata döner
    static func brewBashAsync(_ cmd: String) async -> Result {
        guard isBrewInstalled else { return .brewNotInstalled }
        return await bashAsync(cmd)
    }

    /// `brew services <action> <service>` komutunu çalıştırır, brew yanıtını bekler.
    ///
    /// - **Başarı:** exit 0 veya çıktı "already started/running" içeriyor.
    /// - **EALREADY (exit 5):** `launchctl bootstrap` zaten çalışan servise "exited with 5" döner;
    ///   `controlService` bunu "zaten çalışıyor" olarak ele alır.
    /// - Sudo kullanılmaz — brew her zaman net hata veya başarı mesajı döner.
    ///
    /// - Parameters:
    ///   - action: `"run"` | `"stop"` | `"restart"`
    ///   - service: Homebrew formula adı (örn. `"nginx"`, `"php@8.3"`)
    static func brewServicesAsync(_ action: String, service: String) async -> Result {
        guard isBrewInstalled else { return .brewNotInstalled }
        switch action {
        case "start", "run":
            // run semantiği: servisi SADECE bu oturum için başlatır — login/reboot'ta
            // auto-start OLMAZ (~/Library/LaunchAgents'a plist kopyalanmaz).
            return await bashAsync("\(brewBin) services run \(service) 2>&1")
        case "restart":
            // `brew services restart` servisi login'e KAYDEDER (start semantiği). run
            // semantiğini korumak için: önce stop, sonra run.
            _ = await bashAsync("\(brewBin) services stop \(service) 2>/dev/null")
            return await bashAsync("\(brewBin) services run \(service) 2>&1")
        default:   // stop vb.
            return await bashAsync("\(brewBin) services \(action) \(service) 2>&1")
        }
    }

    // MARK: - LaunchAgent Kontrolü (brew services bypass)


    /// Brew servislerini `brew services run` semantiği ile kontrol eder — login'de auto-start OLMAZ.
    ///
    /// **Neden doğrudan launchctl?**
    /// macOS Sonoma/Sequoia'da GUI uygulama alt sürecinden çalışan
    /// `launchctl bootstrap gui/UID plist` çağrısı EIO (exit code 5) ile başarısız olur.
    /// `launchctl load/unload` (eski API) bu kısıtlamadan etkilenmez.
    ///
    /// **run semantiği:**
    /// - Plist kaynağı: `brew_prefix/opt/{name}/homebrew.mxcl.{name}.plist` (Cellar symlink)
    ///   `~/Library/LaunchAgents/`'a KOPYALANMAZ → login/reboot'ta auto-start olmaz.
    /// - `launchctl list` yine de `homebrew.mxcl.{name}` label'ını görür — label plist içinden gelir, kaynak path'ten değil.
    ///
    /// **stop:** `launchctl remove` label ile durdurur (kaynak fark etmez).
    ///   Eski `brew services start` ile kurulmuş LaunchAgents plist'i varsa temizler.
    ///
    /// - Parameters:
    ///   - action: `"start"` (run semantiği), `"stop"` veya `"restart"`
    ///   - brewName: Homebrew formula adı (örn. `"nginx"`, `"php@8.3"`, `"mariadb"`)
    /// - Returns: Shell.Result
    static func launchAgentControl(action: String, brewName: String) async -> Result {
        guard isBrewInstalled else { return .brewNotInstalled }

        // opt/{name}/ → Cellar symlink — versiyon bilmek gerekmez
        let optPlist         = "\(brewPrefix)/opt/\(brewName)/homebrew.mxcl.\(brewName).plist"
        let label            = "homebrew.mxcl.\(brewName)"
        let home             = FileManager.default.homeDirectoryForCurrentUser.path
        let launchAgentPlist = "\(home)/Library/LaunchAgents/\(label).plist"

        switch action {
        case "start":
            // run semantiği: opt plist'i yükle, LaunchAgents'a kopyalama → auto-start yok
            // Eski `start` ile kurulmuş LaunchAgents plist'i varsa önce kaldır
            if FileManager.default.fileExists(atPath: launchAgentPlist) {
                _ = await bashAsync("/bin/launchctl unload -w '\(launchAgentPlist)' 2>/dev/null")
                try? FileManager.default.removeItem(atPath: launchAgentPlist)
            }
            let startR = await bashAsync("/bin/launchctl load '\(optPlist)' 2>&1")
            // exit 5 = EALREADY: servis zaten yüklü/çalışıyor → başarılı say, "already running" işareti koy
            return startR.exitCode == 5 ? Result(output: "already running", error: "", exitCode: 0) : startR

        case "stop":
            // Label ile durdur — kaynağı (opt veya LaunchAgents) fark etmez
            let stopR = await bashAsync("/bin/launchctl remove '\(label)' 2>&1")
            // Eski start'tan kalan LaunchAgents plist'ini temizle (varsa)
            if FileManager.default.fileExists(atPath: launchAgentPlist) {
                _ = await bashAsync("/bin/launchctl unload -w '\(launchAgentPlist)' 2>/dev/null")
                try? FileManager.default.removeItem(atPath: launchAgentPlist)
            }
            return stopR

        case "restart":
            _ = await bashAsync("/bin/launchctl remove '\(label)' 2>/dev/null")
            // Servisin tamamen kapanması için bekle
            try? await Task.sleep(nanoseconds: 600_000_000)
            let restartR = await bashAsync("/bin/launchctl load '\(optPlist)' 2>&1")
            return restartR.exitCode == 5 ? Result(output: "", error: "", exitCode: 0) : restartR

        default:
            return await brewBashAsync("brew services \(action) \(brewName)")
        }
    }

    
    // MARK: - UTF-8 Incremental Decode

    /// `data` içindeki tamamlanmış UTF-8 kod noktalarını String'e çevirir; sondaki EKSİK
    /// (chunk sınırında bölünmüş çok baytlı karakterin yarısı) baytları `data`'da bırakır.
    /// Böylece 🍺, kutu-çizim veya Türkçe karakterler kaç read'e bölünürse bölünsün
    /// (1 bayt/read dahi) sessizce atılmaz — kalan baytlar bir sonraki chunk'la birleşir.
    ///
    /// Gerçek artımlı çözücü: geçersiz baytlar U+FFFD ile değiştirilir ve 1 ilerlenir;
    /// yalnızca "sonda eksik ama geçerli başlangıçtaki" dizi geri tutulur.
    static func decodeUTF8Prefix(_ data: inout Data) -> String {
        guard !data.isEmpty else { return "" }
        let bytes = [UInt8](data)
        let n = bytes.count
        var result = ""
        var i = 0
        while i < n {
            let b = bytes[i]
            let len: Int
            if      b & 0x80 == 0x00 { len = 1 }   // 0xxxxxxx — ASCII
            else if b & 0xE0 == 0xC0 { len = 2 }   // 110xxxxx
            else if b & 0xF0 == 0xE0 { len = 3 }   // 1110xxxx
            else if b & 0xF8 == 0xF0 { len = 4 }   // 11110xxx
            else {
                // Geçersiz lead (continuation byte veya >4 bayt işareti) → replacement, 1 ilerle
                result.append("\u{FFFD}")
                i += 1
                continue
            }
            if i + len > n {
                // Sonda EKSİK dizi — geri kalanı sakla, bir sonraki chunk tamamlasın
                break
            }
            // Continuation baytlarını doğrula (10xxxxxx)
            var valid = true
            for j in 1..<len where bytes[i + j] & 0xC0 != 0x80 { valid = false; break }
            if valid, let s = String(bytes: bytes[i..<i + len], encoding: .utf8) {
                result.append(s)
                i += len
            } else {
                // Geçersiz dizi (aşırı-uzun/surrogate vb.) → replacement, 1 ilerle
                result.append("\u{FFFD}")
                i += 1
            }
        }
        data = i < n ? Data(bytes[i...]) : Data()
        return result
    }

    // MARK: - PTY Input Controller

    /// Çalışan bir PTY komutuna dışarıdan (UI'dan) girdi göndermeyi sağlar.
    /// Kurulum penceresindeki "y / n" alanı bu kanal üzerinden brew'e yanıt yazar.
    /// Thread-safe: write callback'i streamBashPTY tarafından bağlanır, süreç bitince koparılır.
    final class PTYController: @unchecked Sendable {
        private let lock = NSLock()
        private var writer: ((String) -> Void)?
        private(set) var isActive = false

        /// Komuta bir satır girdi gönderir (otomatik olarak `\n` eklenir).
        ///
        /// Yazma işlemi KİLİT ALTINDA yapılır: detach() aynı kilidi beklediğinden,
        /// süregiden bir write bitmeden fd kapatılamaz. (Closure'ı kilit dışında çağırmak,
        /// detach+close ile yarışta kapanmış/yeniden tahsis edilmiş fd'ye yazmaya yol açardı.)
        func send(_ text: String) {
            lock.lock()
            writer?(text)
            lock.unlock()
        }

        fileprivate func attach(_ w: @escaping (String) -> Void) {
            lock.lock(); writer = w; isActive = true; lock.unlock()
        }
        fileprivate func detach() {
            lock.lock(); writer = nil; isActive = false; lock.unlock()
        }
    }

    /// Bir metin parçasının brew/pip/apt gibi araçların onay istemi içerip içermediğini tespit eder.
    static func containsConfirmationPrompt(_ text: String) -> Bool {
        let l = text.lowercased()
        return l.contains("[y/n]") || l.contains("[y/n/")
            || l.contains("proceed with the installation")
            || l.contains("do you want to proceed")
            || l.contains("proceed? [y")
            || l.contains("? [y/n")
            || l.contains("(y/n)")
    }

    // MARK: - Native PTY Streaming

    /// POSIX `posix_openpt` ile gerçek PTY çifti oluşturur ve komutu çalıştırır.
    ///
    /// **Neden bu yöntemi kullanıyoruz?**
    /// - `script -q /dev/null` + Pipe yaklaşımında `script`'in stdout'u Pipe (TTY değil) olduğundan
    ///   stdio tamponlaması devreye girer — brew/curl progress çıktısı (yüzde, `########`) hepsi bir anda gelir.
    /// - Burada slave PTY doğrudan child'ın stdout/stderr/stdin'ine bağlanır; child brew'i gerçek
    ///   terminal zanneder ve indirme yüzdesini anında yazar. Master PTY'den `read()` döngüsüyle
    ///   veri tamponlanmadan okunur.
    ///
    /// - Parameter onProgress: `\r` ile güncellenen ara satır (aynı satırı yeniler). Main thread.
    /// - Parameter onLine:     Tamamlanan satır (`\n` sonrası). Main thread.
    /// - Parameter controller: Dışarıdan girdi göndermek için kanal (kurulum penceresi y/n yazar).
    /// - Parameter onPrompt: brew/pip/apt bir onay istediğinde (Do you want to proceed? [y/N])
    ///   tespit edilen istem metniyle çağrılır. Main thread. UI burada girdi alanını açar;
    ///   yanıt gelmezse çağıran taraf zaman aşımıyla otomatik "y" gönderebilir.
    @discardableResult
    static func streamBashPTY(
        _ command: String,
        controller: PTYController? = nil,
        onLine: @escaping (String) -> Void,
        onProgress: ((String) -> Void)? = nil,
        onPrompt: ((String) -> Void)? = nil
    ) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {

                // ── PTY çifti aç ──────────────────────────────────────────
                let masterFD = posix_openpt(O_RDWR | O_NOCTTY)
                guard masterFD >= 0,
                      grantpt(masterFD)  == 0,
                      unlockpt(masterFD) == 0,
                      let slaveName = String(validatingUTF8: ptsname(masterFD))
                else {
                    if masterFD >= 0 { close(masterFD) }
                    continuation.resume(returning: Result(output: "", error: "PTY oluşturulamadı", exitCode: -1))
                    return
                }
                let slaveFD = open(slaveName, O_RDWR | O_NOCTTY)
                guard slaveFD >= 0 else {
                    close(masterFD)
                    continuation.resume(returning: Result(output: "", error: "PTY slave açılamadı", exitCode: -1))
                    return
                }

                // ── Process ───────────────────────────────────────────────
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/bash")
                task.arguments     = ["-c", command]
                var env = shellEnv
                env["TERM"]                    = "xterm-256color"
                env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
                env["HOMEBREW_NO_ENV_HINTS"]   = "1"
                task.environment = env

                // Slave PTY → child'ın stdin/stdout/stderr
                let slaveFH = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
                task.standardOutput = slaveFH
                task.standardError  = slaveFH
                task.standardInput  = slaveFH

                do { try task.run() } catch {
                    close(masterFD); close(slaveFD)
                    continuation.resume(returning: Result(output: "", error: error.localizedDescription, exitCode: -1))
                    return
                }
                // Parent'ta slave'i kapat; child kapanınca master EIO → read döngüsü biter
                close(slaveFD)

                // UI'dan gelen girdiyi (y/n) master PTY'ye yaz — controller bu closure'ı çağırır
                controller?.attach { input in
                    let s = input.hasSuffix("\n") ? input : input + "\n"
                    s.withCString { ptr in _ = write(masterFD, ptr, strlen(ptr)) }
                }

                // ── Çıktı işleme ──────────────────────────────────────────
                var allOutput = ""
                var accumBuf  = ""   // işlenmemiş PTY verisi

                func flush() {
                    // 1. \n ile tamamlanan satırları işle
                    var lines = accumBuf.components(separatedBy: "\n")
                    accumBuf = lines.removeLast()
                    for line in lines {
                        let crParts = line.components(separatedBy: "\r")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        guard !crParts.isEmpty else { continue }
                        if crParts.count > 1 {
                            for part in crParts.dropLast() {
                                DispatchQueue.main.async { onProgress?(part) }
                            }
                        }
                        let last = crParts.last!
                        DispatchQueue.main.async { onLine(last) }
                    }
                    // 2. Kalan buffer içinde \r → ara progress (henüz \n yok)
                    if accumBuf.contains("\r") {
                        let crParts = accumBuf.components(separatedBy: "\r")
                        accumBuf = crParts.last ?? ""
                        for part in crParts.dropLast() {
                            let clean = part.trimmingCharacters(in: .whitespaces)
                            if !clean.isEmpty { DispatchQueue.main.async { onProgress?(clean) } }
                        }
                        // Güncel (henüz tamamlanmamış) progress parçasını da göster
                        let current = accumBuf.trimmingCharacters(in: .whitespaces)
                        if !current.isEmpty { DispatchQueue.main.async { onProgress?(current) } }
                    }
                }

                // ── Master PTY okuma döngüsü ──────────────────────────────
                // read() EIO (n <= 0) döndürdüğünde child kapanmış demek.
                // Ham baytlar `pending`'de biriktirilir; chunk sınırında bölünen
                // çok baytlı karakterler decodeUTF8Prefix ile korunur.
                var pending = Data()
                var buf = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(masterFD, &buf, 4096)
                    guard n > 0 else { break }
                    pending.append(contentsOf: buf.prefix(Int(n)))
                    let text = Shell.decodeUTF8Prefix(&pending)
                    if !text.isEmpty {
                        allOutput += text
                        accumBuf  += text
                        // İstem taraması flush()'TAN ÖNCE alınmalı. brew'in onay istemi
                        // `\n` ile değil `\r` ile biter:
                        //   \e[34m==>\e[0m \e[1m...proceed with the installation? [y/n]\e[0m\r
                        // flush() içindeki `\r` kırpması (progress barları için DOĞRU) sondaki
                        // \r yüzünden accumBuf'ı BOŞ bırakıyor ve istem metni yok oluyordu →
                        // onPrompt hiç tetiklenmiyor, otomatik 'y' gönderilmiyor, kurulum
                        // penceresi sonsuza kadar asılı kalıyordu.
                        let promptScan = accumBuf
                        // Önce tamamlanan satırları onLine'a gönder (flush), SONRA istem bildir —
                        // böylece istem satırı log'a girdikten sonra girdi çubuğu açılır.
                        flush()
                        // promptScan = önceki tamamlanmamış kuyruk + yeni chunk. İki read()
                        // arasında bölünen istem de bu pencerede tam hâliyle görünür. Bir sonraki
                        // turda kuyruk sıfırlandığı için eski istem yeniden tetiklenmez.
                        if let onPrompt, Shell.containsConfirmationPrompt(promptScan) {
                            let promptLine = promptScan
                                .components(separatedBy: CharacterSet(charactersIn: "\n\r"))
                                .last(where: { Shell.containsConfirmationPrompt($0) })?
                                .trimmingCharacters(in: .whitespaces) ?? promptScan.trimmingCharacters(in: .whitespaces)
                            DispatchQueue.main.async { onPrompt(promptLine) }
                        }
                    }
                }
                // Döngü bitince kalan eksik baytları da çöz (replacement ile)
                if !pending.isEmpty {
                    let text = String(decoding: pending, as: UTF8.self)
                    allOutput += text
                    accumBuf  += text
                    flush()
                }

                // Kalan tampon — son satırı bitir
                if !accumBuf.isEmpty {
                    let crParts = accumBuf.components(separatedBy: "\r")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    if let last = crParts.last { DispatchQueue.main.async { onLine(last) } }
                }

                // Önce controller'ı kopar (writer=nil, kilit altında) — böylece detach anında
                // send() geçersiz/kapanmış fd'ye yazamaz — SONRA fd'yi kapat.
                controller?.detach()
                close(masterFD)
                task.waitUntilExit()

                continuation.resume(returning: Result(
                    output:   allOutput.trimmingCharacters(in: .whitespacesAndNewlines),
                    error:    "",
                    exitCode: task.terminationStatus
                ))
            }
        }
    }

    // MARK: - PTY Wrapper (eski — artık streamBashPTY tercih edilir)

    /// `script(1)` ile sahte PTY — sadece geriye dönük uyumluluk için bırakıldı.
    static func withPTY(_ command: String) -> String {
        let escaped = command.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "script -q /dev/null /bin/bash -c '\(escaped)'"
    }

    // MARK: - Streaming

    /// Bash komutunu çalıştırır; stdout/stderr satır satır `onLine` callback'i ile bildirilir.
    /// `onLine` her zaman main thread'de çağrılır.
    /// `onProgress`: opsiyonel — brew gibi araçların `\r`-bazlı progress güncellemeleri için.
    ///               Bu callback son satırı değiştirmek (replace) amacıyla kullanılabilir.
    ///               Sağlanmazsa progress satırları da `onLine` ile gönderilir.
    @discardableResult
    /// - Parameter timeout: Komut bu süre içinde bitmezse SIGTERM (3 sn sonra SIGKILL) gönderilir.
    ///   `nil` → süresiz (eski davranış). Kullanıcıdan gelen komutları çalıştıran çağrılar
    ///   (ör. derleme komutu) MUTLAKA bir değer vermeli: `npm run dev` gibi hiç bitmeyen bir
    ///   komut aksi halde bekleyen task'ı kalıcı olarak asılı bırakır.
    static func streamBash(
        _ command: String,
        timeout: TimeInterval? = nil,
        onLine: @escaping (String) -> Void,
        onProgress: ((String) -> Void)? = nil
    ) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task    = Process()
                let outPipe = Pipe()
                let errPipe = Pipe()
                task.executableURL = URL(fileURLWithPath: "/bin/bash")
                task.arguments     = ["-c", command]
                task.standardOutput = outPipe
                task.standardError  = errPipe
                task.environment    = shellEnv

                // Tüm tampon erişimi bu seri kuyrukta yapılır — readabilityHandler yerine
                // bloke reader thread'ler kullanılır; böylece hem veri yarışı hem de
                // "waitUntilExit sonrası pipe'ta kalan okunmamış chunk kaybı" önlenir.
                let syncQueue = DispatchQueue(label: "com.brampp.streamBash.buffers")
                var allOutput = ""
                var allError  = ""
                var outBuffer = ""
                var errBuffer = ""
                /// Zaman aşımına uğradı mı / sonuç döndürüldü mü (ikisi de syncQueue korumalı).
                /// `finished` sonrası gelen geç çıktı UI'ya YAZILMAZ: aksi halde biz çoktan
                /// döndükten sonra hâlâ yaşayan bir alt süreç konsola satır basmaya devam eder.
                var timedOut = false
                var finished = false

                /// `\n` ile böler; satır içi `\r` segmentlerini progress olarak iletir.
                /// Son segment her zaman `onLine` ile gönderilir. (syncQueue üzerinde çağrılır)
                func flush(_ buffer: inout String) {
                    guard !finished else { buffer = ""; return }   // sonuç döndü — geç çıktıyı yut
                    var lines = buffer.components(separatedBy: "\n")
                    buffer = lines.removeLast()
                    for line in lines {
                        let crParts = line.components(separatedBy: "\r")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        guard !crParts.isEmpty else { continue }
                        // Ara \r segmentleri → progress (replace)
                        if crParts.count > 1, let prog = onProgress {
                            for part in crParts.dropLast() {
                                DispatchQueue.main.async { prog(part) }
                            }
                        }
                        // Son segment → yeni satır
                        let last = crParts.last!
                        DispatchQueue.main.async { onLine(last) }
                    }
                }

                /// Bir pipe'ı EOF'a kadar bloke okur; tüm tampon erişimi syncQueue'da.
                /// UTF-8 çok baytlı karakterler chunk sınırında bölünse bile korunur.
                func readLoop(_ handle: FileHandle, isOut: Bool) {
                    var pending = Data()
                    while true {
                        let data = handle.availableData
                        if data.isEmpty { break }   // EOF
                        syncQueue.sync {
                            pending.append(data)
                            let text = Shell.decodeUTF8Prefix(&pending)
                            guard !text.isEmpty else { return }
                            if isOut { allOutput += text; outBuffer += text; flush(&outBuffer) }
                            else     { allError  += text; errBuffer += text; flush(&errBuffer) }
                        }
                    }
                    // Kalan eksik baytlar (varsa) — replacement ile çöz
                    if !pending.isEmpty {
                        syncQueue.sync {
                            let text = String(decoding: pending, as: UTF8.self)
                            if isOut { allOutput += text; outBuffer += text; flush(&outBuffer) }
                            else     { allError  += text; errBuffer += text; flush(&errBuffer) }
                        }
                    }
                }

                do {
                    try task.run()
                } catch {
                    continuation.resume(returning: Result(output: "", error: error.localizedDescription, exitCode: -1))
                    return
                }

                // İki pipe'ı eş zamanlı, ayrı thread'lerde EOF'a kadar oku
                let group = DispatchGroup()
                let readers = DispatchQueue(label: "com.brampp.streamBash.readers", attributes: .concurrent)
                group.enter()
                readers.async { readLoop(outPipe.fileHandleForReading, isOut: true);  group.leave() }
                group.enter()
                readers.async { readLoop(errPipe.fileHandleForReading, isOut: false); group.leave() }

                // ── Zaman aşımı ────────────────────────────────────────────────────────
                var timeoutItem: DispatchWorkItem?
                if let timeout {
                    let item = DispatchWorkItem {
                        syncQueue.sync { timedOut = true }
                        if task.isRunning { task.terminate() }                 // SIGTERM
                        // Nazikçe ölmezse zorla — pipe'lar kapanır, readLoop EOF alır
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
                        }
                    }
                    timeoutItem = item
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: item)
                }

                task.waitUntilExit()
                timeoutItem?.cancel()

                // Okuyucular normalde milisaniyeler içinde EOF alır. Ancak bash çıksa bile
                // ARKA PLANDA kalan bir alt süreç (ör. `cmd &`) pipe'ı açık tutabilir; o
                // durumda EOF hiç gelmez. Sınırsız group.wait() burada çağıranı sonsuza
                // kadar asardı — sınırlı bekleyip elimizdekiyle dönüyoruz.
                if group.wait(timeout: .now() + 5) == .timedOut {
                    DispatchQueue.main.async {
                        onLine("⚠️ Çıktı akışı kapanmadı (arka planda süreç kalmış olabilir) — beklemeden devam ediliyor")
                    }
                }

                // Kalan tamponları sonlandır (syncQueue serisinde, tüm okumalardan sonra)
                syncQueue.sync {
                    if !outBuffer.isEmpty {
                        let crParts = outBuffer.components(separatedBy: "\r")
                            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        if let last = crParts.last {
                            DispatchQueue.main.async { onLine(last) }
                        }
                    }
                    let errRemaining = errBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !errRemaining.isEmpty {
                        DispatchQueue.main.async { onLine(errRemaining) }
                    }
                    finished = true   // bundan sonraki geç çıktı yutulur
                }

                // Zaman aşımı yolunda group.wait 5sn'de vazgeçebilir — okuyucular hâlâ
                // yazıyor olabilir. Tamponlar yalnızca syncQueue içinde okunursa yarış olmaz.
                let (didTimeout, finalOutput, finalError) =
                    syncQueue.sync { (timedOut, allOutput, allError) }
                if didTimeout {
                    DispatchQueue.main.async {
                        onLine("⏱️ Komut zaman aşımına uğradı ve durduruldu")
                    }
                }
                continuation.resume(returning: Result(
                    output:   finalOutput.trimmingCharacters(in: .whitespacesAndNewlines),
                    error:    didTimeout
                        ? (finalError + "\nKomut zaman aşımına uğradı").trimmingCharacters(in: .whitespacesAndNewlines)
                        : finalError.trimmingCharacters(in: .whitespacesAndNewlines),
                    exitCode: didTimeout ? -998 : task.terminationStatus   // Result.isTimeout ile uyumlu
                ))
            }
        }
    }

    // MARK: - ANSI

    /// Terminal ANSI kaçış kodlarını temizler (brew install çıktısında bulunur)
    static func stripANSI(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\x1B\[[0-9;]*[A-Za-z]|\x1B\(B|\r"#) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    // MARK: - Port Utility

    /// Belirtilen port dinleniyor mu? (`nc -z` ile kontrol, ~1ms)
    static func isPortInUse(_ port: Int) -> Bool {
        bash("nc -z 127.0.0.1 \(port) 2>/dev/null").isSuccess
    }

    /// Belirtilen port dinleniyor mu? (`nc -z` ile async kontrol, ~1ms)
    static func isPortInUseAsync(_ port: Int) async -> Bool {
        await bashAsync("nc -z 127.0.0.1 \(port) 2>/dev/null").isSuccess
    }

    /// `nc -z 127.0.0.1 PORT` ile port dinleniyor mu? (~1ms, pil verimliliği açısından optimize)
    static func isPortOpenFast(_ port: Int) async -> Bool {
        await bashAsync("nc -z 127.0.0.1 \(port) 2>/dev/null").isSuccess
    }

    /// Bir daemon süreci ayakta mı? Süreç ADINA bakar (komut satırına DEĞİL).
    ///
    /// nginx için `pgrep -x nginx` KULLANILAMAZ: nginx master süreci kendi başlığını
    /// `nginx: master process /opt/homebrew/.../nginx -g daemon off;` olarak yeniden
    /// yazar (setproctitle), bu yüzden ada TAM eşleşme arayan `-x` asla tutmaz. Sonuç:
    /// Homebrew nginx çalışırken bile "çalışmıyor" görünüyordu — vhost değişiklikleri
    /// reload edilmiyor, "config sonraki başlatmada uygulanacak" deniyordu.
    /// httpd'de sorun yok (süreç adı tam olarak `httpd`).
    ///
    /// `pgrep -f` bilinçli olarak KULLANILMADI: komut satırına baktığı için kendi kabuk
    /// komutumuzun argv'sini yakalayıp yanlış pozitif üretme riski taşır. `ps -eo comm=`
    /// yalnızca süreç adını listeler; bu riski yapısı gereği taşımaz.
    static func isProcessAlive(_ procName: String) async -> Bool {
        if procName == "nginx" {
            return await bashAsync("ps -eo comm= | grep -qE '^nginx(:| |$)'").isSuccess
        }
        return await bashAsync("pgrep -x \(procName) > /dev/null 2>&1").isSuccess
    }

    // MARK: - Utility

    static func getVersion(_ command: String, versionArg: String = "--version") -> String? {
        guard FileHelper.exists(command) else { return nil }
        let r = run(command, arguments: [versionArg])
        guard r.isSuccess else { return nil }
        let line = r.output.components(separatedBy: "\n").first ?? ""
        if let range = line.range(of: #"[\d]+\.[\d]+\.?[\d]*"#, options: .regularExpression) { return String(line[range]) }
        return line.isEmpty ? nil : line
    }

    static func getVersionAsync(_ command: String, versionArg: String = "--version") async -> String? {
        guard FileHelper.exists(command) else { return nil }
        let r = await runAsync(command, arguments: [versionArg])
        guard r.isSuccess else { return nil }
        let line = r.output.components(separatedBy: "\n").first ?? ""
        if let range = line.range(of: #"[\d]+\.[\d]+\.?[\d]*"#, options: .regularExpression) { return String(line[range]) }
        return line.isEmpty ? nil : line
    }
}
