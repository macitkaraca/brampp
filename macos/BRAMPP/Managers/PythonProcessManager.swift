import Foundation

// MARK: - PythonProcessManager

/// Python uygulamaları için native süreç yönetimi.
///
/// PM2 gerektirmez. Uvicorn / Gunicorn süreçleri doğrudan başlatılır:
/// - Virtual environment otomatik tespit edilir (venv/, .venv/, env/)
/// - PID dosyası ile takip: ~/Library/Application Support/BRAMPP/pids/
/// - Log dosyası: ~/Library/Application Support/BRAMPP/python-logs/
enum PythonProcessManager {

    // MARK: - venv Tespiti

    /// Proje dizininde sanal ortam tespit eder.
    /// Kontrol sırası: venv/ → .venv/ → env/
    /// - Returns: Bulunan venv'in `bin/` dizini, bulunamazsa `nil`
    static func detectVenvBin(at sitePath: String) -> String? {
        let candidates = ["venv", ".venv", "env"]
        for name in candidates {
            let binDir = "\(sitePath)/\(name)/bin"
            if FileHelper.exists(binDir) { return binDir }
        }
        return nil
    }

    /// venv varsa orada, yoksa PythonVersion.binDir (libexec/bin aware) döner.
    static func resolvedBinDir(for domain: Domain) -> String {
        if domain.pythonUseVenv, let venv = detectVenvBin(at: domain.sitePath) {
            return venv
        }
        // PythonVersion.binDir: libexec/bin varsa onu, yoksa bin döner
        return domain.pythonVersion?.binDir
            ?? PathConfig.pythonOptBin(version: "3.12")
    }

    // MARK: - Başlatma Komutu

    /// Domain için nihai başlatma komutunu döner.
    /// {PORT} ve {PROJECT} yer tutucuları değiştirilmiş olarak döner.
    static func resolvedServerCommand(for domain: Domain) -> String {
        let port = domain.port ?? 8001

        if let cmd = domain.appCommand, !cmd.isEmpty {
            return cmd
                .replacingOccurrences(of: "{PORT}", with: "\(port)")
                .replacingOccurrences(of: "{PROJECT}", with: djangoProject(for: domain))
        }

        let framework = domain.pythonFramework ?? .fastapi
        return framework.serverCommand
            .replacingOccurrences(of: "{PORT}", with: "\(port)")
            .replacingOccurrences(of: "{PROJECT}", with: djangoProject(for: domain))
    }

    /// Django WSGI modül adı — domain adındaki nokta ve tire → alt çizgi
    private static func djangoProject(for domain: Domain) -> String {
        domain.name
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    // MARK: - Log Yardımcısı

    /// Kurulum script'inin `log()` fonksiyonuyla AYNI biçim: `HH:mm:ss mesaj`.
    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Log dosyasının SONUNA bir satır ekler — kabuk kullanmadan.
    ///
    /// Kabuk üzerinden (`echo ... >> log`) yazmak, metin içinde geçen kabuk
    /// metakarakterlerini (özellikle ters tırnak) çalıştırma riski taşır; yol/mesaj
    /// kullanıcı verisinden geldiğinden bu yol tamamen terk edildi.
    private static func appendLogLine(_ message: String, to logFile: String) {
        let line = "\(logTimeFormatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: logFile) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // Dosya yoksa (ensureEnvironment onu oluşturur, yine de savunma) sıfırdan yaz
            _ = FileHelper.write(line, to: logFile)
        }
    }

    // MARK: - Ortam Hazırlığı

    /// venv ve framework paketlerini otomatik hazırlar.
    ///
    /// - `pythonUseVenv = true`  → venv yoksa oluşturur, uvicorn/gunicorn eksikse pip ile kurar
    /// - `pythonUseVenv = false` → brew Python global ortamında araç eksikse pip ile kurar
    ///
    /// Tüm kurulum çıktıları logFile'a yazılır — kullanıcı Log sekmesinden takip edebilir.
    /// - Returns: `true` → sunucu başlatmaya hazır, `false` → kurulum başarısız
    static func ensureEnvironment(for domain: Domain) async -> Bool {
        let sitePath   = domain.sitePath
        // Log: NativeProcessManager ile birleşik — Application Support/processes/{name}/app.log
        let logFile    = NativeProcessManager.logFile(for: domain)
        let framework  = domain.pythonFramework ?? .fastapi
        let packages   = framework.packages           // ["uvicorn","fastapi"] / ["gunicorn","django"] vb.
        // Varlık kontrolü SUNUCU binary'si üzerinde yapılmalı (uvicorn/gunicorn).
        // packages.first framework kütüphanesini (django/flask) veriyordu — bin/'de
        // bulunmadığından her başlatmada gereksiz pip install tetikleniyordu.
        let serverTool = framework.serverBinary

        // Application Support/processes/{name}/ dizini ve log dosyasını hazırla
        PathConfig.createProcessDir(for: domain.name)
        if !FileHelper.exists(logFile) {
            try? "".write(toFile: logFile, atomically: true, encoding: .utf8)
        }

        if domain.pythonUseVenv {
            let pythonExec  = PathConfig.pythonBin(version: domain.pythonVersion?.rawValue ?? "3.12")
            let venvDir     = "\(sitePath)/venv"
            let versionStr  = domain.pythonVersion?.rawValue ?? "3.12"
            let projectName = djangoProject(for: domain)
            let versionLabel = domain.pythonVersion?.displayName ?? "Python 3.12"

            // Framework'e özgü hazırlık bloğu (script içine eklenir)
            let frameworkBlock: String
            switch domain.pythonFramework ?? .fastapi {

            case .django:
                // Django: proje yoksa oluştur + ALLOWED_HOSTS'u otomatik patch et
                frameworkBlock = """

                # Django proje yapısı yok → django-admin startproject çalıştır
                if [ ! -f "$SITE/\(projectName)/wsgi.py" ]; then
                    log "⚙️  Django projesi oluşturuluyor: \(projectName)..."
                    cd "$SITE" && "$VENV/bin/django-admin" startproject '\(projectName)' . >> "$LOG" 2>&1
                    if [ $? -ne 0 ]; then
                        log "❌ Django projesi oluşturulamadı (dizin boş olmalı: $SITE)"
                        exit 1
                    fi
                    log "✅ Django projesi oluşturuldu: \(projectName)/"
                fi

                # ALLOWED_HOSTS: boş liste nginx/tarayıcı isteklerini reddeder — geliştirme için '*' ekle
                SETTINGS="$SITE/\(projectName)/settings.py"
                if [ -f "$SETTINGS" ] && grep -q "ALLOWED_HOSTS = \\[\\]" "$SETTINGS" 2>/dev/null; then
                    sed -i '' "s/ALLOWED_HOSTS = \\[\\]/ALLOWED_HOSTS = ['*', 'localhost', '127.0.0.1', '\(domain.name)']/" "$SETTINGS" 2>/dev/null
                    log "✅ ALLOWED_HOSTS güncellendi: \\['*', 'localhost', '127.0.0.1', '\(domain.name)'\\]"
                fi
                """

            case .flask:
                // Flask app.py yoksa Swift tarafında oluşturulur (ensureEnvironment sonunda)
                // Shell bloğu burada boş bırakılır
                frameworkBlock = ""

            default:
                frameworkBlock = ""
            }

            let setupScript = """
            #!/bin/bash
            LOG=\(Shell.quote(logFile))
            VENV=\(Shell.quote(venvDir))
            SITE=\(Shell.quote(sitePath))
            PYTHON=\(Shell.quote(pythonExec))
            VERSION=\(Shell.quote(versionStr))
            TOOL=\(Shell.quote(serverTool))
            PACKAGES=\(Shell.quote(packages.joined(separator: " ")))

            ts() { date '+%H:%M:%S'; }
            log() { echo "$(ts) $1" >> "$LOG"; }

            # Python binary çözümü — birden fazla path dene
            if [ ! -x "$PYTHON" ]; then
                BREW_PY="\(PathConfig.brewBase)/bin/python${VERSION}"
                if [ -x "$BREW_PY" ]; then
                    log "ℹ️  Python fallback: $BREW_PY"
                    PYTHON="$BREW_PY"
                else
                    SYS_PY="$(command -v python3 2>/dev/null)"
                    if [ -n "$SYS_PY" ]; then
                        log "ℹ️  Python fallback: $SYS_PY"
                        PYTHON="$SYS_PY"
                    else
                        log "❌ Python bulunamadı. Brew ile kurun: brew install python@${VERSION}"
                        exit 1
                    fi
                fi
            fi

            # venv yok → oluştur
            if [ ! -f "$VENV/bin/activate" ]; then
                log "⚙️  venv oluşturuluyor (\(versionLabel))..."
                "$PYTHON" -m venv "$VENV" >> "$LOG" 2>&1
                if [ $? -ne 0 ]; then
                    log "❌ venv oluşturulamadı — Python kurulu mu? ($PYTHON)"
                    exit 1
                fi
                log "✅ venv oluşturuldu: $VENV"
            fi

            # server aracı eksik → pip ile kur
            if ! "$VENV/bin/$TOOL" --version >/dev/null 2>&1; then
                log "⚙️  Paketler kuruluyor: $PACKAGES"
                "$VENV/bin/pip" install --upgrade pip -q >> "$LOG" 2>&1
                "$VENV/bin/pip" install $PACKAGES >> "$LOG" 2>&1
                if [ $? -ne 0 ]; then
                    log "❌ Paket kurulumu başarısız"
                    exit 1
                fi
                log "✅ Paketler kuruldu"
            fi

            # requirements.txt varsa PROJE bağımlılıklarını da kur — yalnızca dosya
            # değiştiyse (hash izi) tekrar çalışır; her başlatmada pip'i boşuna bekletmez.
            REQ="$SITE/requirements.txt"
            if [ -f "$REQ" ]; then
                REQ_HASH=$(shasum "$REQ" 2>/dev/null | awk '{print $1}')
                STAMP="$VENV/.req-installed"
                if [ ! -f "$STAMP" ] || [ "$(cat "$STAMP" 2>/dev/null)" != "$REQ_HASH" ]; then
                    log "⚙️  requirements.txt bağımlılıkları kuruluyor..."
                    "$VENV/bin/pip" install -r "$REQ" >> "$LOG" 2>&1
                    if [ $? -eq 0 ]; then
                        echo "$REQ_HASH" > "$STAMP"
                        log "✅ requirements.txt kuruldu"
                    else
                        log "⚠️  requirements.txt kurulumu hata verdi — başlatma yine denenecek"
                    fi
                fi
            fi
            \(frameworkBlock)
            exit 0
            """

            let r = await Shell.bashAsync(setupScript)
            guard r.exitCode == 0 else { return false }

            // Flask: app.py yoksa minimal başlangıç dosyası oluştur (Swift tarafında — shell heredoc sorunu yok)
            if (domain.pythonFramework ?? .fastapi) == .flask {
                let appPy = "\(sitePath)/app.py"
                if !FileHelper.exists(appPy) {
                    let starter = """
                    from flask import Flask

                    app = Flask(__name__)

                    @app.route('/')
                    def index():
                        return '<h1>Flask Çalışıyor!</h1>'

                    if __name__ == '__main__':
                        app.run()
                    """
                    _ = FileHelper.write(starter, to: appPy)
                    // Log satırı SWIFT tarafında eklenir. Eskiden bu satır `bash -c "echo ..."`
                    // ile yazılıyordu ve yol ÇİFT TIRNAK içindeydi: bash çift tırnak içinde
                    // ters tırnağı komut ikamesi olarak ÇALIŞTIRDIĞINDAN, ters tırnak içeren
                    // bir document root (ör. /Users/me/Sites/`komut`) keyfi komut çalıştırırdı.
                    // Kabuğa hiç ihtiyaç yok — dosyaya doğrudan eklemek hem güvenli hem hızlı.
                    appendLogLine("✅ Başlangıç app.py oluşturuldu: \(appPy)", to: logFile)
                }
            }

            return true

        } else {
            // venv yok — brew Python global ortamı.
            // Global pip (--break-system-packages, --user'sız) konsol script'lerini
            // brew prefix bin'ine (/opt/homebrew/bin) koyar; python interpreter'ı ise
            // libexec/bin'dedir. Bu yüzden varlık kontrolü HER İKİ dizini de tarar —
            // yalnızca libexec/bin'e bakmak aracı asla bulamayıp her başlatmada yeniden
            // kurulum tetikliyordu. start.sh PATH'i de ikisini birden içerir.
            let binDir = resolvedBinDir(for: domain)
            let brewBin = PathConfig.brewBin
            if FileHelper.exists("\(binDir)/\(serverTool)")
                || FileHelper.exists("\(brewBin)/\(serverTool)") { return true }

            // araç eksik → global pip ile kur
            let pythonExec = "\(binDir)/python3"
            let globalScript = """
            #!/bin/bash
            LOG=\(Shell.quote(logFile))
            ts() { date '+%H:%M:%S'; }
            log() { echo "$(ts) $1" >> "$LOG"; }

            log "⚙️  Global pip ile paketler kuruluyor: \(packages.joined(separator: " "))"
            # Homebrew Python PEP 668 gereği "externally-managed-environment" hatası verir.
            # Önce normal dene; bu hatayı alırsak --break-system-packages ile tekrar dene
            # (kullanıcı venv kullanmamayı seçmiş; global kurulum bilinçli tercihtir).
            PIP_OUT=$(\(Shell.quote(pythonExec)) -m pip install \(packages.joined(separator: " ")) 2>&1)
            PIP_RC=$?
            echo "$PIP_OUT" >> "$LOG"
            if [ $PIP_RC -ne 0 ] && echo "$PIP_OUT" | grep -qi "externally-managed"; then
                log "ℹ️  externally-managed ortam — --break-system-packages ile tekrar deneniyor"
                # --user KULLANMA: konsol script'lerini ~/Library/Python/X.Y/bin'e koyar;
                # o dizin start.sh'ın PATH'inde ve varlık kontrolünde YOK — uvicorn/gunicorn
                # "command not found" olurdu. --user'sız kurulum script'leri brew prefix
                # bin'ine (/opt/homebrew/bin) koyar; bu dizin hem start.sh PATH'inde hem de
                # varlık kontrolünde (brewBin dalı) mevcuttur.
                \(Shell.quote(pythonExec)) -m pip install --break-system-packages \(packages.joined(separator: " ")) >> "$LOG" 2>&1
                PIP_RC=$?
            fi
            if [ $PIP_RC -ne 0 ]; then
                log "❌ Paket kurulumu başarısız — venv kullanmanız önerilir (python -m venv venv)"
                exit 1
            fi
            log "✅ Paketler kuruldu (global)"
            exit 0
            """
            let r = await Shell.bashAsync(globalScript)
            return r.exitCode == 0
        }
    }

}
// Not: start / stop / isRunning / readLogs / clearLogs → NativeProcessManager'a taşındı.
// PythonProcessManager yalnızca venv/pip/framework kurulum mantığını (ensureEnvironment)
// ve komut çözümleme yardımcılarını (resolvedServerCommand, detectVenvBin, vb.) içerir.
