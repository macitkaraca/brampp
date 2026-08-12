import Foundation

/// Node.js, Python ve .NET uygulamaları için PM2'den bağımsız, sıfır bağımlılıklı süreç yöneticisi.
///
/// Her domain için `~/Library/Application Support/BRAMPP/processes/{domainName}/` kullanılır:
///   `start.sh`  — env + auto-restart sarmalayıcı script
///   `app.pid`   — script sürecinin PID'i (script kendisi yazar)
///   `app.log`   — birleşik stdout / stderr
///
/// Site dizini kirletilmez; git repoları etkilenmez; macOS Application Support standardı uygulanır.
///
/// **Süreç ömrü:**
/// `start` — `nohup` ile arkaplanlaştırır; uygulama kapansa bile süreç çalışmaya devam eder.
/// `stop`  — SIGTERM (süreç grubuna) → SIGKILL → port bazlı temizlik.
enum NativeProcessManager {

    // MARK: - Path Helpers

    /// `~/Library/Application Support/BRAMPP/processes/{domain.name}/`
    static func dir(for domain: Domain) -> String {
        PathConfig.processDir(domain: domain.name)
    }

    static func pidFile(for domain: Domain) -> String {
        PathConfig.processPid(domain: domain.name)
    }

    static func logFile(for domain: Domain) -> String {
        PathConfig.processLog(domain: domain.name)
    }

    static func startScriptPath(for domain: Domain) -> String {
        PathConfig.processScript(domain: domain.name)
    }

    // MARK: - Start

    /// Uygulamayı nohup ile arkaplanda başlatır.
    /// - Önce `start.sh` yeniden oluşturulur (domain ayarları güncel olsun).
    /// - PID dosyası, script'in kendi içinde yazılır (ilk satır: `echo $$ > pidFile`).
    @MainActor
    static func start(domain: Domain) async -> Bool {
        let script     = startScriptPath(for: domain)
        let log        = logFile(for: domain)
        let pid        = pidFile(for: domain)

        // Dizin hazırlığı (Application Support/processes/{name}/)
        PathConfig.createProcessDir(for: domain.name)

        // Çalışan wrapper + portu tam olarak durdur (stop: PID grubu → SIGKILL → port cleanup)
        // Bu olmazsa eski wrapper süreci restart loop'unda devam eder ve yeni başlatma port çakışmasına girer
        await stop(domain: domain)

        // Start script güncelle
        let content = buildStartScript(for: domain)
        guard FileHelper.write(content, to: script) else {
            return false
        }
        _ = await Shell.bashAsync("chmod +x \(Shell.quote(script))")

        // Önceki PID dosyasını temizle
        _ = await Shell.bashAsync("rm -f \(Shell.quote(pid))")

        // nohup ile arkaplanlaştır — subshell sayesinde shell'den bağımsız kalır
        let r = await Shell.bashAsync(
            "(nohup \(Shell.quote(script)) >>\(Shell.quote(log)) 2>&1 &)"
        )
        guard r.exitCode == 0 else { return false }

        // isRunning artık "port gerçekten açık mı" kontrol ettiğinden, yavaş başlayan
        // uygulamalara zaman tanımak için tek seferlik değil ~5.6sn boyunca poll edilir.
        // Port açılır açılmaz başarı döner; hiç açılmazsa (crash-loop/port çakışması) false.
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 700_000_000)   // 0.7s
            if await isRunning(domain: domain) { return true }
        }
        return false
    }

    // MARK: - Stop

    /// Çalışan süreci durdurur.
    ///
    /// **Neden süreç ağacı yürünüyor?** Wrapper script `(nohup script &)` ile başlatıldığında
    /// süreç grubu LİDERİ olmaz — bu yüzden `kill -- -PGID` gerçek uygulamayı (node/uvicorn/dotnet)
    /// bulamaz ve yalnızca wrapper ölür, uygulama öksüz kalırdı. Bunun yerine wrapper'ın alt süreç
    /// ağacı `pgrep -P` ile yürünür. Ayrıca wrapper ÖNCE öldürülür ki auto-restart döngüsü yeni
    /// child başlatmasın.
    @MainActor
    static func stop(domain: Domain) async {
        let pid = pidFile(for: domain)

        // PID dosyasındaki değer (yoksa boş bırakılır — port temizliği yine çalışır)
        var pidVal = ""
        if FileHelper.exists(pid),
           let raw = FileHelper.readString(pid),
           let v   = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            pidVal = String(v)
        }
        let portVal = domain.port.map(String.init) ?? ""

        // TEK script: sıra kritiktir. Port sahipliği HİÇBİR SİNYALDEN ÖNCE belirlenmeli —
        // wrapper öldürüldükten sonra çocukları launchd'ye reparent olur, soy zinciri kaybolur
        // ve porttaki sürecin bize ait olup olmadığı bir daha anlaşılamaz.
        _ = await Shell.bashAsync("""
        OURDIR=\(Shell.quote(dir(for: domain)))
        PIDVAL=\(Shell.quote(pidVal))
        PORT=\(Shell.quote(portVal))

        # lsof/ps FİZİKSEL yolu bildirir (ör. /tmp → /private/tmp). Sembolik link içeren
        # bir yol saklanmışsa karşılaştırma tutmaz ve kendi sürecimizi sahiplenemeyiz.
        OURDIR_P=$(cd "$OURDIR" 2>/dev/null && pwd -P)
        [ -z "$OURDIR_P" ] && OURDIR_P="$OURDIR"

        # ── PID kimlik doğrulaması ─────────────────────────────────────────────
        # PID dosyası bayat olabilir (port-çakışması çıkışından kalan) ve numara sistemce
        # YENİDEN tahsis edilmiş olabilir — komut satırı bizim dizinimizi içermiyorsa atla.
        if [ -n "$PIDVAL" ]; then
            ARGS=$(ps -p "$PIDVAL" -o args= 2>/dev/null)
            if [ -n "$ARGS" ]; then
                # Yol SINIRI zorunlu: OURDIR/ (sondaki /) — aksi halde "…/api.local" deseni
                # komşu "…/api.local2" domainini de eşleştirip yanlış süreci öldürürdü.
                case "$ARGS" in
                    *"$OURDIR/"*|*"$OURDIR_P/"*) : ;;   # bizim start.sh wrapper'ımız — devam
                    *) PIDVAL="" ;;                      # PID yeniden kullanılmış — kill atla
                esac
            fi
        fi

        # ── Port sahipliği (SİNYALDEN ÖNCE) ────────────────────────────────────
        # Porttaki süreç yalnızca ŞU durumlarda bizimdir: komut satırı dizinimizi içeriyor,
        # VEYA çalışma dizini dizinimizin altında, VEYA wrapper'ımızın soyundan geliyor.
        # Aksi halde DOKUNULMAZ: aynı portu tutan alakasız bir süreci (kullanıcının başka
        # projesi, Docker vb.) öldürmek veri kaybına yol açardı.
        OWNED=""
        if [ -n "$PORT" ]; then
            for p in $(lsof -ti TCP:"$PORT" -sTCP:LISTEN 2>/dev/null); do
                OK=""
                A=$(ps -p "$p" -o args= 2>/dev/null)
                case "$A" in *"$OURDIR/"*|*"$OURDIR_P/"*) OK=1 ;; esac   # yol sınırı (komşu domain karışmasın)
                if [ -z "$OK" ]; then
                    C=$(lsof -a -d cwd -Fn -p "$p" 2>/dev/null | sed -n 's/^n//p' | head -1)
                    case "$C" in
                        "$OURDIR"|"$OURDIR"/*|"$OURDIR_P"|"$OURDIR_P"/*) OK=1 ;;
                    esac
                fi
                if [ -z "$OK" ] && [ -n "$PIDVAL" ]; then
                    anc="$p"
                    while [ -n "$anc" ] && [ "$anc" != "1" ] && [ "$anc" != "0" ]; do
                        if [ "$anc" = "$PIDVAL" ]; then OK=1; break; fi
                        anc=$(ps -p "$anc" -o ppid= 2>/dev/null | tr -d ' ')
                    done
                fi
                [ -n "$OK" ] && OWNED="$OWNED $p"
            done
        fi

        # ── Wrapper ağacını durdur ─────────────────────────────────────────────
        # Alt süreç ağacı sinyalden ÖNCE toplanır; TERM ve KILL turu AYNI listeyi kullanır.
        # Aksi halde wrapper öldükten sonra `pgrep -P` boş döner ve SIGTERM'i yoksayan
        # süreçler SIGKILL'den kaçıp öksüz sızardı.
        if [ -n "$PIDVAL" ]; then
            collect() { for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; collect "$c"; done; }
            TARGETS="$PIDVAL $(collect "$PIDVAL")"
            for t in $TARGETS; do kill -TERM "$t" 2>/dev/null; done
            sleep 0.7
            for t in $TARGETS; do kill -9 "$t" 2>/dev/null; done
        fi

        # ── Yalnızca BİZE AİT port süreçlerini temizle ──────────────────────────
        if [ -n "$OWNED" ]; then
            for p in $OWNED; do kill -TERM "$p" 2>/dev/null; done
            sleep 1
            for p in $OWNED; do kill -9 "$p" 2>/dev/null; done
        fi
        true
        """)

        if FileHelper.exists(pid) {
            _ = await Shell.bashAsync("rm -f \(Shell.quote(pid))")
        }
    }

    // MARK: - isRunning

    /// Çalışma durumunu kontrol eder.
    ///
    /// Port'u olan uygulamalar (Node/Python/.NET) için: wrapper CANLI **ve** uygulama
    /// portu gerçekten DİNLİYORSA çalışıyor sayılır. Böylece:
    /// - crash-loop (wrapper canlı, sürekli yeniden deniyor ama port kapalı) → çalışmıyor,
    /// - port'u tutan YABANCI süreç (wrapper ölü/yok, pid dosyası kalmış) → çalışmıyor.
    ///
    /// PID dosyası hiç yoksa (uygulama bizim dışımızda başlatılmış olabilir) port fallback kullanılır.
    @MainActor
    static func isRunning(domain: Domain) async -> Bool {
        let pid = pidFile(for: domain)
        let pidExists = FileHelper.exists(pid)

        var wrapperAlive = false
        if pidExists,
           let raw = FileHelper.readString(pid),
           let pidVal = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            // Çıplak `kill -0` YALNIZCA "bu PID yaşıyor mu" der. Port çakışmasında wrapper
            // çıkarken app.pid bilerek KORUNUR; sistem o numarayı başka bir sürece yeniden
            // tahsis ederse alakasız süreç "bizim uygulamamız çalışıyor" sanılırdı.
            // stop() ile aynı ölçüt: sürecin komut satırı KENDİ start.sh yolumuzu içermeli.
            let ourScript = startScriptPath(for: domain)
            wrapperAlive = await Shell.bashAsync(
                "ps -p \(pidVal) -o args= 2>/dev/null | grep -qF \(Shell.quote(ourScript))"
            ).exitCode == 0
        }

        if let port = domain.port {
            let portOpen = await Shell.isPortOpenFast(port)
            if wrapperAlive {
                // Wrapper canlı — yalnızca uygulama portu GERÇEKTEN açtıysa çalışıyor
                return portOpen
            }
            // Wrapper ölü/yok. pid dosyası varsa (ölü wrapper) port'u tutan yabancı süreci
            // çalışıyor SAYMA. pid dosyası hiç yoksa port fallback'e izin ver.
            return pidExists ? false : portOpen
        }

        // Port tanımsız (nadir) — wrapper canlılığına güven
        return wrapperAlive
    }

    // MARK: - Süreç İzleme

    /// Çalışan uygulamanın izleme bilgisi.
    struct AppProcessInfo {
        let wrapperPID: Int?      // start.sh sarmalayıcı PID'i (yönettiğimiz süreç)
        let appPID: Int?          // portu GERÇEKTEN dinleyen süreç (asıl uygulama)
        let command: String?      // asıl sürecin komut adı (node/python/dotnet)
        let cpu: String?          // % CPU
        let memoryMB: String?     // MB cinsinden bellek (RSS)
    }

    /// Bu PID'e sahip bir süreç YAŞIYOR mu? `kill(pid, 0)` sinyal göndermez, yalnızca
    /// varlığı ve erişilebilirliği sınar. EPERM da "var ama bizim değil" demektir → yaşıyor.
    nonisolated static func isAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    /// Domain'in gerçek çalışma bilgisini toplar: wrapper PID + portu dinleyen asıl app PID
    /// + CPU/bellek. İzleme panelinde gösterilir. (Her satırda değil; talep üzerine çağrılır.)
    @MainActor
    /// `ps -o pid=,%cpu=,rss=,comm=` satırını ayrıştırır — SAF.
    ///
    /// İlk ÜÇ alan konumla alınır, KALAN HER ŞEY komuttur. Boşluğa göre bölmek,
    /// yürütücü yolu boşluk içerdiğinde ("/Users/x/My Tools/node") sütunları
    /// kaydırıyor ve kullanıcı komut adının parçasını CPU değeri olarak görüyordu.
    static func parseProcessLine(_ output: String) -> (pid: Int?, cpu: String?,
                                                       rssKB: Int?, command: String?) {
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return (nil, nil, nil, nil) }
        var fields: [String] = []
        var rest = Substring(line)
        for _ in 0..<3 {
            rest = rest.drop(while: { $0.isWhitespace })
            let f = rest.prefix(while: { !$0.isWhitespace })
            guard !f.isEmpty else { break }
            fields.append(String(f))
            rest = rest.dropFirst(f.count)
        }
        let command = rest.trimmingCharacters(in: .whitespaces)
        return (fields.count > 0 ? Int(fields[0]) : nil,
                fields.count > 1 ? fields[1] : nil,
                fields.count > 2 ? Int(fields[2]) : nil,
                command.isEmpty ? nil : (command as NSString).lastPathComponent)
    }

    static func processInfo(for domain: Domain) async -> AppProcessInfo {
        // PID dosyası, süreç öldükten sonra da diskte kalır. Doğrulamadan raporlamak
        // "wrapper hâlâ ayakta" izlenimi verir; isRunning=false olsa bile bu PID'i gören
        // biri onu öldürmeye çalışabilir — ya da o numara başka bir sürece yeniden
        // atanmışsa YANLIŞ süreci. Bu yüzden yaşadığı `kill(pid, 0)` ile doğrulanır.
        let wrapperPID = FileHelper.readString(pidFile(for: domain))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .flatMap { Self.isAlive($0) ? $0 : nil }

        guard let port = domain.port else {
            return AppProcessInfo(wrapperPID: wrapperPID, appPID: nil, command: nil, cpu: nil, memoryMB: nil)
        }

        // Portu dinleyen asıl süreç + ps ile CPU/bellek
        let r = await Shell.bashAsync("""
        PID=$(lsof -ti TCP:\(port) -sTCP:LISTEN 2>/dev/null | head -1)
        [ -z "$PID" ] && exit 1
        # comm SONA alınır: yürütücü yolu BOŞLUK içerebilir ("/Users/x/My Tools/node")
        # ve ortada dururken %cpu ile rss sütunlarını kaydırıyordu — kullanıcı komut
        # adının bir parçasını CPU değeri olarak görüyordu. Sayısal alanlar önde sabit.
        ps -p "$PID" -o pid=,%cpu=,rss=,comm= 2>/dev/null
        """)
        guard r.isSuccess, !r.output.isEmpty else {
            return AppProcessInfo(wrapperPID: wrapperPID, appPID: nil, command: nil, cpu: nil, memoryMB: nil)
        }
        // Çıktı: "12345 0.4 45678 /opt/homebrew/bin/node"  (rss KB cinsinden)
        // İlk ÜÇ alan konumla alınır, kalan HER ŞEY komuttur — boşluklu yol bölünmez.
        let parsed = Self.parseProcessLine(r.output)
        let appPID  = parsed.pid
        let command = parsed.command
        let cpu     = parsed.cpu
        let memMB   = parsed.rssKB.map { String(format: "%.0f", Double($0) / 1024.0) }

        return AppProcessInfo(wrapperPID: wrapperPID, appPID: appPID, command: command, cpu: cpu, memoryMB: memMB)
    }

    // MARK: - Logs

    /// Log dosyasının son `lines` satırını döndürür.
    @MainActor
    static func readLogs(for domain: Domain, lines: Int = 150) async -> String {
        let log = logFile(for: domain)
        guard FileHelper.exists(log) else {
            return """
            Henüz log yok.

            Uygulama ilk başlatıldığında '\(log)' dosyasına yazılmaya başlanacak.
            """
        }
        let r = await Shell.bashAsync("tail -n \(lines) '\(log)' 2>/dev/null")
        return r.output.isEmpty ? "Log dosyası boş." : r.output
    }

    /// Log dosyasını BOŞALTIR (temizle butonu için).
    ///
    /// Dosya SİLİNMEZ, boyutu sıfırlanır. Sarmalayıcının `>> app.log` yönlendirmesi süreç
    /// başlarken BİR KEZ kurulur; unlink edilirse fd yetim inode'u göstermeye devam eder,
    /// `app.log` ADIYLA yeni dosya bir daha oluşmaz ve o koşunun tüm çıktısı erişilemez olur.
    /// Log penceresi kalıcı olarak boş kalır, izleyici de yeniden bağlanamaz (silinen yolu
    /// açamaz) — tek çıkış uygulamayı yeniden başlatmaktır. Truncate aynı inode'u koruduğu
    /// için yazım kaldığı yerden sürer.
    static func clearLogs(for domain: Domain) {
        let log = logFile(for: domain)
        guard let handle = FileHandle(forWritingAtPath: log) else { return }
        defer { try? handle.close() }
        try? handle.truncate(atOffset: 0)
    }

    // MARK: - Script Builder (internal — DomainManager.writeConfigFiles de kullanır)

    /// `{sitePath}/start.sh` içeriğini oluşturur.
    /// Script ilk satırda kendi PID'ini `app.pid` dosyasına yazar.
    /// Süreç çöktüğünde en fazla `MAX_RESTARTS` kez yeniden başlatır.
    static func buildStartScript(for domain: Domain) -> String {
        // Varsayılan port PLATFORMA göre: node 3001, python 8001, dotnet 5001.
        // Sabit 3001, port'u nil olan eski bir Python domaininde start.sh'ı 3001'e,
        // resolvedServerCommand'i 8001'e yönlendiriyor ve uygulama hiç ayağa kalkmıyordu.
        let port    = domain.port ?? domain.platform.portRange?.lowerBound ?? 3001
        let wdir    = domain.sitePath
        let pid     = pidFile(for: domain)

        // {PORT} ve {PROJECT} yer tutucularını her zaman değiştir.
        // appCommand şablon olarak kaydedilmiş olabilir (örn. "gunicorn {PROJECT}.wsgi:application").
        let projectName = domain.name
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        let rawCmd  = domain.appCommand ?? defaultCommand(for: domain)
        let cmd     = rawCmd
            .replacingOccurrences(of: "{PORT}",    with: "\(port)")
            .replacingOccurrences(of: "{PROJECT}", with: projectName)

        // Ortam değişkenleri
        var envLines: [String] = [
            "export PORT='\(port)'",
            "export NODE_ENV='production'"
        ]

        switch domain.platform {
        case .nodejs:
            if let ver = domain.nodeVersion {
                let sysPath = "\(PathConfig.brewBin):/usr/bin:/bin:/usr/sbin:/sbin"
                envLines.append("export PATH='\(ver.binDir):\(sysPath)'")
            }
        case .dotnet:
            let dotnetBin = domain.dotnetVersion?.resolvedBin ?? PathConfig.dotnet
            let dotnetDir = (dotnetBin as NSString).deletingLastPathComponent
            let sysPath   = "\(PathConfig.brewBin):/usr/bin:/bin:/usr/sbin:/sbin"
            envLines.append("export PATH='\(dotnetDir):\(sysPath)'")
            envLines.append("export ASPNETCORE_URLS='http://127.0.0.1:\(port)'")
            envLines.append("export ASPNETCORE_ENVIRONMENT='Development'")
            envLines.append("export DOTNET_ENVIRONMENT='Development'")
        case .python:
            // Sunucu binary'sinin (uvicorn/gunicorn) bulunduğu dizini PATH'e ekle.
            // resolvedBinDir venv varsa venv/bin, yoksa brew Python bin'ini döner —
            // yalnızca venv'e bakmak, pythonUseVenv=false (global) modu tamamen
            // kırıyordu: uvicorn PATH'te bulunamayıp başlatma hep başarısızdı.
            let pyBin   = PythonProcessManager.resolvedBinDir(for: domain)
            let sysPath = "\(PathConfig.brewBin):/usr/bin:/bin:/usr/sbin:/sbin"
            envLines.append("export PATH='\(pyBin):\(sysPath)'")
        default:
            break
        }

        // Kullanıcı tanımlı env vars
        if let userEnv = domain.envVars {
            for (k, v) in userEnv.sorted(by: { $0.key < $1.key }) {
                // Anahtar geçerli bir shell tanımlayıcısı olmalı — aksi halde kaçışsız
                // "export KEY=..." satırı script'i bozar / komut enjeksiyonuna açılır.
                guard k.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
                    continue   // geçersiz anahtar sessizce atlanır (script bütünlüğü öncelikli)
                }
                let safeV = v.replacingOccurrences(of: "'", with: "'\"'\"'")
                envLines.append("export \(k)='\(safeV)'")
            }
        }

        let envBlock = envLines.joined(separator: "\n")
        // cmd, kullanıcının yazdığı tam bir komut satırıdır ve script'e ÇIPLAK gömülür
        // (tek tırnak içine alınmaz). Bu yüzden tek-tırnak "escape"i uygulanmamalı —
        // aksi halde apostrof içeren komutlar bozulur.
        let safeCmd  = cmd

        return """
        #!/bin/bash
        # BRAMPP — Otomatik oluşturuldu.
        # Bu dosyayı düzenlerseniz, domain ayarları kaydedilince sıfırlanır.

        # Kendi PID'imizi kaydet (stop için süreç grubu yönetimi)
        echo $$ > \(Shell.quote(pid))

        # ── Log rotasyonu: app.log 5 MB'ı aşarsa son 1 MB'ı koru ─────────────
        # (Rotasyon yoksa log süresiz büyür — restart döngüsündeki bir uygulama
        #  günde yüzlerce MB üretebilir.)
        APPLOG=\(Shell.quote(logFile(for: domain)))
        if [ -f "$APPLOG" ]; then
            LOGSIZE=$(stat -f%z "$APPLOG" 2>/dev/null || echo 0)
            if [ "$LOGSIZE" -gt 5242880 ]; then
                # INODE KORUNMALI. Sarmalayıcının fd'si (`>> app.log`) BU inode'a bağlı
                # ve yolu bir daha çözmez. `mv` rename(2) yapıp adı YENİ bir inode'a
                # bağlasaydı, bu koşunun tüm çıktısı adı silinmiş eski inode'a yazılır,
                # `app.log` 1 MB'ta donar ve log penceresi bir daha hiçbir şey göstermezdi.
                # `>` (O_TRUNC) aynı inode'u boşaltıp yeniden doldurur.
                if tail -c 1048576 "$APPLOG" > "$APPLOG.tmp" 2>/dev/null; then
                    cat "$APPLOG.tmp" > "$APPLOG" && rm -f "$APPLOG.tmp"
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ℹ️  Log döndürüldü (5 MB üzeri — son 1 MB korundu)"
                fi
            fi
        fi

        \(envBlock)

        cd \(Shell.quote(wdir))

        # ── Port ön-kontrol: başlamadan önce port müsait mi? ─────────────────
        if [ -n "$PORT" ]; then
            OWNER=$(lsof -ti TCP:"$PORT" -sTCP:LISTEN 2>/dev/null | head -1)
            if [ -n "$OWNER" ]; then
                OWNER_CMD=$(ps -p "$OWNER" -o comm= 2>/dev/null || echo "bilinmiyor")
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ Port :$PORT zaten kullanımda — PID: $OWNER ($OWNER_CMD)" >&2
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] ℹ️  Domain ayarlarından farklı bir port seçin veya süreci durdurun." >&2
                # PID dosyasını SİLME — ölü wrapper PID'i kalsın ki isRunning port'u tutan
                # YABANCI süreci "çalışıyor" saymasın (kill -0 ölü PID → false).
                exit 2
            fi
        fi

        MAX_RESTARTS=5
        RESTARTS=0

        while [ "$RESTARTS" -lt "$MAX_RESTARTS" ]; do
            \(safeCmd)
            EXIT=$?
            [ "$EXIT" -eq 0 ] && break

            # Port çakışması → yeniden denemek faydasız, hemen çık
            if [ -n "$PORT" ]; then
                OWNER=$(lsof -ti TCP:"$PORT" -sTCP:LISTEN 2>/dev/null | head -1)
                if [ -n "$OWNER" ]; then
                    OWNER_CMD=$(ps -p "$OWNER" -o comm= 2>/dev/null || echo "bilinmiyor")
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ Port :$PORT zaten kullanımda — PID: $OWNER ($OWNER_CMD)" >&2
                    break
                fi
            fi

            RESTARTS=$((RESTARTS + 1))
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️  Çıkış kodu: $EXIT — yeniden başlatılıyor ($RESTARTS/$MAX_RESTARTS)..." >&2
            sleep 3
        done

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⏹  Süreç sonlandı (yeniden başlatma: $RESTARTS/$MAX_RESTARTS)."
        rm -f \(Shell.quote(pid))
        """
    }

    // MARK: - Default Command

    /// `domain.appCommand` tanımlı değilse platform için varsayılan komut.
    static func defaultCommand(for domain: Domain) -> String {
        switch domain.platform {
        case .nodejs:
            return "npm start"
        case .dotnet:
            let bin = domain.dotnetVersion?.resolvedBin ?? PathConfig.dotnet
            return "'\(bin)' run --no-launch-profile"
        case .python:
            // Tam venv binary yolunu döndür — venv yoksa uygulama çalışamaz
            return PythonProcessManager.resolvedServerCommand(for: domain)
        default:
            return "echo 'komut tanımlı değil'"
        }
    }
}
