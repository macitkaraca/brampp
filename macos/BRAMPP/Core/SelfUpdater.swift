import Foundation
import AppKit

// MARK: - Yerinde güncelleme

/// Doğrulanmış bir sürümü YERİNDE kurar: uygulama çıkar, paket takas edilir, yeniden açılır.
///
/// `UpdateInstaller` bilerek burada durur ve kalıbı kullanıcıya bırakır; oradaki gerekçe
/// hâlâ geçerli, bu tip bir alt sistem yanlış yapılırsa kullanıcıyı UYGULAMASIZ bırakır.
/// Bu yüzden tasarım o riski üç yerden kısıtlıyor:
///
///   1. **Kopyalama uygulama ÇALIŞIRKEN yapılır.** Çıkıştan sonra geriye yalnızca iki
///      `mv` kalır ve ikisi de HEDEFLE AYNI BİRİMDEDİR, yani rename — atomik. 60 MB'ı
///      çıkıştan sonra kopyalayan bir tasarımda takas penceresi saniyelerce açık kalır;
///      burada milisaniyedir.
///   2. **Eski paket silinmez, YANA ALINIR.** Yeni sürüm gerçekten açılana kadar diskte
///      durur; açılmazsa geri konur. Takas ortasında bir şey koparsa kullanıcı yine de
///      çalışan bir uygulamayla kalır.
///   3. **Sessiz değildir.** Kullanıcı düğmeye basar. Şartnamedeki *"Never update
///      silently"* kuralı korunur — yasak olan habersiz güncelleme, tek tıkla güncelleme
///      değil.
///
/// Yönetici parolası HİÇBİR KOŞULDA istenmez. Hedefe yazamıyorsak düğme hiç gösterilmez
/// ve kullanıcı eski yola (kalıbı aç, sürükle) düşer: "BRAMPP kendini güncellemek için
/// parolanı istiyor" alışkanlığı, bir saldırganın isteyeceği tam o alışkanlıktır.
enum SelfUpdater {

    /// Yerinde kurulumun neden YAPILAMAYACAĞI. Düğme gösterilmeden ÖNCE sorulur —
    /// kullanıcıyı uygulamadan ettikten sonra öğrenmek seçenek değil.
    enum Blocker: Equatable {
        /// Paketin bulunduğu dizine yazamıyoruz (başka bir yönetici kurmuş olabilir).
        case parentNotWritable
        /// Paketin kendisi salt okunur — takas için onu taşımamız gerekiyor.
        case bundleNotWritable
        /// Gatekeeper yer değiştirmesi: uygulama karantinalı bir kalıptan, salt okunur
        /// geçici bir kopyadan çalışıyor. Oraya kurmak hiçbir şey değiştirmez.
        case translocated
    }

    /// SAF karar — dosya sistemine dokunmaz, testten geçebilsin diye girdileri dışarıdan alır.
    static func blocker(bundlePath: String,
                        parentWritable: Bool,
                        bundleWritable: Bool) -> Blocker? {
        // Yer değiştirme ÖNCE denetlenir: böyle bir kopyada yazılabilirlik yanıltıcıdır,
        // geçici dizin yazılabilir olabilir ama oraya kurmak kullanıcının uygulamasını
        // değiştirmez.
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        if !parentWritable { return .parentNotWritable }
        if !bundleWritable { return .bundleNotWritable }
        return nil
    }

    /// Çalışan uygulama için kararı üretir.
    static func currentBlocker(bundle: Bundle = .main,
                               fileManager: FileManager = .default) -> Blocker? {
        let path   = bundle.bundleURL.path
        let parent = bundle.bundleURL.deletingLastPathComponent().path
        return blocker(bundlePath: path,
                       parentWritable: fileManager.isWritableFile(atPath: parent),
                       bundleWritable: fileManager.isWritableFile(atPath: path))
    }

    // MARK: - Takas betiği

    /// Paketin DIŞINDA çalışan takas betiği.
    ///
    /// Betik uygulamanın kendi paketinde DURAMAZ: takas ettiğimiz şey o pakettir, altından
    /// çekilen bir betiğin davranışı tanımsızdır. Bu yüzden Application Support altına
    /// yazılıp oradan çalıştırılır.
    ///
    /// SAF: yalnızca metin üretir, hiçbir şey çalıştırmaz.
    static func swapScript(parentPID: Int32,
                           stagedPath: String,
                           targetPath: String,
                           logPath: String,
                           binaryName: String) -> String {
        let staged = Shell.quote(stagedPath)
        let target = Shell.quote(targetPath)
        let log    = Shell.quote(logPath)
        let binary = Shell.quote("\(targetPath)/Contents/MacOS/\(binaryName)")
        return """
        #!/bin/bash
        # BRAMPP yerinde güncelleme — uygulamanın paketinin DIŞINDA çalışır.
        # `set -e` YOK: her hata noktasında geri alma yapmamız gerekiyor, kabuğun
        # sessizce çıkması tam da kaçındığımız "yarım takas" durumunu üretirdi.
        set -u
        exec >>\(log) 2>&1
        # Yol AYRI ve TIRNAKLI argüman olarak verilir. Çift tırnaklı metnin içine
        # gömülseydi `$` ya da `` ` `` taşıyan bir klasör adı kabuk tarafından
        # genişletilir, betik daha ilk satırında sözdizimi hatasıyla ölürdü.
        echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) takas başlıyor:" \(target)

        # 1) Ana süreç ölene kadar bekle. Sınırsız beklemek, çıkışı iptal eden bir
        #    kullanıcının ardında sonsuza dek yaşayan bir süreç bırakırdı.
        for _ in $(seq 1 120); do
            kill -0 \(parentPID) 2>/dev/null || break
            sleep 0.5
        done
        if kill -0 \(parentPID) 2>/dev/null; then
            echo "BRAMPP 60 saniyede çıkmadı — takas YAPILMADI, hazırlanan kopya siliniyor"
            rm -rf \(staged)
            exit 1
        fi

        OLD=\(target).brampp-old
        rm -rf "$OLD"

        # 2) İki rename. İkisi de AYNI birimde olduğu için atomik; arada uygulamanın
        #    hiç var olmadığı pencere milisaniyeler sürer.
        if ! mv \(target) "$OLD"; then
            echo "eski paket yana alınamadı — hiçbir şey değişmedi"
            rm -rf \(staged)
            exit 1
        fi
        if ! mv \(staged) \(target); then
            echo "yeni paket yerine konamadı — eski sürüm geri alınıyor"
            mv "$OLD" \(target)
            exit 1
        fi

        # 3) EMNİYET: uygulama ayırmayı yapamadan çıktıysa bağlı kalan kalıbı burada
        #    kurtarırız. Bağlı kalan bir birim her açılışta "volume is read only"
        #    hatası ürettiriyordu, çünkü temizlik onu silmeye çalışıyordu.
        for m in \(Shell.quote(PathConfig.updates))/mount-*; do
            [ -d "$m" ] || continue
            hdiutil detach "$m" -force >/dev/null 2>&1
            rmdir "$m" >/dev/null 2>&1
        done

        # 4) Yeni sürümü başlat.
        open \(target)

        # 5) GERÇEKTEN açıldı mı? `pgrep -f` deseni DÜZENLİ İFADE sayar; yolda `+`
        #    gibi bir metakarakter varsa eşleşme tutmaz ve BAŞARILI bir güncelleme
        #    geri alınırdı. `grep -F` deseni birebir metin alır.
        seen=0
        for _ in $(seq 1 40); do
            if ps -axo comm= | grep -qF -- \(binary); then seen=1; break; fi
            sleep 0.5
        done

        # 6) AÇIK KALDI mı? İlk görünme yetmez: açılışta çöken bir sürüm de bir an
        #    süreç olarak görünür. Görünmesiyle yetinip eski paketi silseydik, her
        #    açılışta düşen bir sürüm kullanıcıyı geri dönülemez biçimde uygulamasız
        #    bırakırdı — üstelik uygulama açılmadığı için uygulama içi güncelleme yolu
        #    da kapalı olurdu. Geri alma mekanizmasının VAROLUŞ sebebi bu senaryo.
        if [ "$seen" = "1" ]; then
            for _ in $(seq 1 20); do
                sleep 0.5
                ps -axo comm= | grep -qF -- \(binary) || { seen=0; break; }
            done
        fi

        if [ "$seen" = "1" ]; then
            echo "yeni sürüm açıldı ve ayakta kaldı — eski paket siliniyor"
            rm -rf "$OLD"
            exit 0
        fi

        echo "yeni sürüm açılmadı ya da açılır açılmaz düştü — ESKİ sürüme dönülüyor"
        # Hedef ÖNCE SİLİNMEZ. `rm -rf` + `mv` sırası, aralarında hiçbir uygulamanın
        # bulunmadığı bir pencere açar; betik o an ölürse (zorla yeniden başlatma,
        # oturum kapatma) kullanıcıda çalışan kopya kalmaz. Rename ile hedef her an
        # ya yeni ya eski paketi taşır.
        if ! mv \(target) \(target).brampp-failed; then
            echo "geri alma iptal — yeni sürüm yerinde bırakıldı"
            exit 1
        fi
        mv "$OLD" \(target)
        open \(target)
        rm -rf \(target).brampp-failed
        exit 1
        """
    }

    // MARK: - Hazırlık

    /// Takasa hazır durum: betik yazıldı, yeni paket hedefin YANINA kopyalandı.
    struct Prepared {
        let scriptPath: String
        let stagedPath: String
        let targetPath: String
        let logPath: String
    }

    enum PrepareError: Error, Equatable {
        case blocked(Blocker)
        case mountFailed
        case appNotFoundInImage
        case copyFailed(String)
        case signatureFailed
        /// İmza geçerli ama BAŞKASININ — kurulacak paket bizim ekibimize ait değil.
        case teamMismatch
        case notarizationFailed
        case scriptWriteFailed
    }

    /// Hata → kullanıcıya gösterilecek metnin anahtarı. Metin, kullanıcının ne
    /// yapabileceğini söyler; "işlem başarısız" demekle yetinmez.
    static func messageKey(for error: PrepareError) -> String {
        switch error {
        case .blocked:            return "upd.selfFail.blocked"
        case .mountFailed:        return "upd.selfFail.mount"
        case .appNotFoundInImage: return "upd.selfFail.missing"
        case .copyFailed:         return "upd.selfFail.copy"
        case .signatureFailed:    return "upd.selfFail.signature"
        case .teamMismatch:       return "upd.selfFail.team"
        case .notarizationFailed: return "upd.selfFail.notary"
        case .scriptWriteFailed:  return "upd.selfFail.script"
        }
    }

    /// Doğrulanmış kalıptan yeni paketi hedefin yanına kopyalar ve betiği yazar.
    ///
    /// `run` yalnızca ad çakışmasını önler; iki hazırlık aynı anda yaşayabilir.
    static func prepare(verifiedDMG: URL, run: Int,
                        bundle: Bundle = .main) async -> Result<Prepared, PrepareError> {
        if let b = currentBlocker(bundle: bundle) { return .failure(.blocked(b)) }

        let targetURL  = bundle.bundleURL
        let parentDir  = targetURL.deletingLastPathComponent().path
        let binaryName = targetURL.deletingPathExtension().lastPathComponent

        // Hazırlanan kopya HEDEFLE AYNI DİZİNE konur — takasın atomik olmasının koşulu
        // bu. `.app` uzantısı BİLEREK verilmez: uzantılı bir paketi Launch Services
        // dizine ekler ve kullanıcı Spotlight'ta ikinci bir BRAMPP görürdü.
        let stagedPath = "\(parentDir)/.BRAMPP-update-\(run)"
        let mountPoint = "\(PathConfig.updates)/mount-\(run)"

        // Yarım kalmış ESKİ hazırlıklar süpürülür. Bunlar `/Applications` altında
        // gizli durur ve `pruneOldStaging` yalnızca `updates/`e baktığı için hiçbir
        // kod onlara dokunmuyordu: her başarısız deneme 60 MB bırakırdı.
        for entry in FileHelper.contentsOfDirectory(parentDir)
        where entry.hasPrefix(".BRAMPP-update-") {
            _ = FileHelper.remove("\(parentDir)/\(entry)")
        }
        _ = FileHelper.createDirectory(PathConfig.updates)
        // Betik ve günlük `updates/` DIŞINDA durur: `pruneOldStaging` her açılışta o
        // dizindeki noktayla başlamayan her adı siliyor. Başarısız bir güncellemenin
        // tek kara kutusu, geri dönen eski sürüm açılır açılmaz silinirdi.
        _ = FileHelper.createDirectory(PathConfig.swapDir)

        let attach = await Shell.runAsync("/usr/bin/hdiutil", arguments: [
            "attach", verifiedDMG.path, "-nobrowse", "-readonly", "-noverify",
            "-mountpoint", mountPoint,
        ], timeout: 120)
        guard attach.isSuccess else { return .failure(.mountFailed) }

        /// Kalıbı ayırır. `defer` + `Task.detached` İŞE YARAMIYORDU: ayrılmış görevin
        /// çalışacağının garantisi yok ve `commitAndQuit` hemen ardından uygulamadan
        /// çıkıyor. Sonuç, güncellemeden sonra bağlı kalan bir birim — bir sonraki
        /// açılışta `pruneOldStaging` onu silmeye çalışıp
        /// "volume … is read only" hatası veriyordu, her açılışta.
        /// Bu yüzden ayırma SENKRON: her çıkış yolunda beklenerek yapılır.
        func detachImage() async {
            _ = await Shell.runAsync("/usr/bin/hdiutil",
                                     arguments: ["detach", mountPoint, "-force"], timeout: 60)
            _ = FileHelper.remove(mountPoint)
        }

        let sourceApp = "\(mountPoint)/\(targetURL.lastPathComponent)"
        guard FileHelper.exists(sourceApp) else { return .failure(.appNotFoundInImage) }

        // `ditto`, `cp -R` değil: imza, genişletilmiş öznitelikler ve sembolik bağlar
        // olduğu gibi taşınır. `cp -R` imzayı bozup Gatekeeper'ın yeni paketi reddetmesine
        // yol açabilirdi.
        let copy = await Shell.runAsync("/usr/bin/ditto",
                                        arguments: [sourceApp, stagedPath], timeout: 300)
        guard copy.isSuccess else {
            _ = FileHelper.remove(stagedPath)
            await detachImage()
            return .failure(.copyFailed(copy.error.isEmpty ? copy.output : copy.error))
        }

        // KAPILAR, hazırlanan paketin ÜZERİNDE yeniden kurulur.
        //
        // Kalıp indirilirken dört kapıdan geçti — ama doğrulanan şey KALIP, kurulan şey
        // bu KOPYA ve arada bir bağlama + `ditto` var. Tek başına `--verify` yetmez:
        // "imza bozulmamış" der, "KİM imzaladı" DEMEZ. Geçerli bir Developer ID'yle
        // imzalanmış bambaşka bir uygulama o kapıdan geçer ve kullanıcının BRAMPP'ının
        // yerine geçerdi. Bu yüzden kimlik (Team ID) ve noter onayı da tekrarlanır.
        let verify = await Shell.runAsync("/usr/bin/codesign",
                                          arguments: ["--verify", "--deep", "--strict", stagedPath],
                                          timeout: 180)
        guard UpdateVerifier.isCodesignVerified(exitCode: verify.exitCode,
                                                stderr: verify.error) else {
            _ = FileHelper.remove(stagedPath)
            await detachImage()
            return .failure(.signatureFailed)
        }

        // `codesign -dv` ayrıntıyı STDERR'e yazar; iki akış da taranır.
        let details = await Shell.runAsync("/usr/bin/codesign",
                                           arguments: ["-dv", "--verbose=4", stagedPath],
                                           timeout: 180)
        guard let ownTeam = UpdateVerifier.ownTeamIdentifier(),
              let team = UpdateVerifier.teamIdentifier(
                  inCodesignOutput: details.output + "\n" + details.error),
              team == ownTeam else {
            _ = FileHelper.remove(stagedPath)
            await detachImage()
            return .failure(.teamMismatch)
        }

        // Zaman aşımı KABUL DEĞİLDİR: `spctl` yanıt vermediyse noter onayını GÖRMEDİK.
        let assess = await Shell.runAsync("/usr/sbin/spctl",
                                          arguments: ["--assess", "--type", "execute", "-vv", stagedPath],
                                          timeout: 180)
        guard UpdateVerifier.isNotarizedAccepted(exitCode: assess.exitCode,
                                                 output: assess.output + "\n" + assess.error) else {
            _ = FileHelper.remove(stagedPath)
            await detachImage()
            return .failure(.notarizationFailed)
        }

        let logPath    = "\(PathConfig.swapDir)/swap-\(run).log"
        let scriptPath = "\(PathConfig.swapDir)/swap-\(run).sh"
        let script = swapScript(parentPID: ProcessInfo.processInfo.processIdentifier,
                                stagedPath: stagedPath,
                                targetPath: targetURL.path,
                                logPath: logPath,
                                binaryName: binaryName)
        guard FileHelper.write(script, to: scriptPath) else {
            _ = FileHelper.remove(stagedPath)
            await detachImage()
            return .failure(.scriptWriteFailed)
        }

        await detachImage()
        return .success(Prepared(scriptPath: scriptPath, stagedPath: stagedPath,
                                 targetPath: targetURL.path, logPath: logPath))
    }

    /// Takası başlatır ve uygulamadan çıkar.
    ///
    /// Betik `nohup` ile ayrılır: BRAMPP'in çocuğu olarak başlar ama ana süreç ölünce
    /// launchd'ye devredilir, öldürülmez. Ayrılmasaydı takası yapacak süreç, takasın
    /// beklediği çıkışla birlikte ölürdü.
    /// - Returns: takas GERÇEKTEN başladıysa `true`. `false` dönerse uygulama çıkmaz ve
    ///   çağıran arayüzü eski hâline döndürmek ZORUNDADIR — yoksa "Hazırlanıyor…"
    ///   düğmesi kalıcı olarak kilitli kalır, üstelik diğer düğmeler de ona bağlı
    ///   devre dışı olduğundan pencerede basılabilecek hiçbir şey kalmaz.
    @MainActor
    @discardableResult
    static func commitAndQuit(_ p: Prepared, console: ConsoleStore?) -> Bool {
        console?.log(key: "log.app.selfUpdateStarting", type: .command)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        task.arguments = ["/bin/bash", p.scriptPath]
        task.standardOutput = FileHandle.nullDevice
        task.standardError  = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            // Hazırlık GERİ ALINIR: 60 MB'lık kopya `/Applications` altında gizli
            // kalırsa onu temizleyen başka bir kod yok.
            _ = FileHelper.remove(p.stagedPath)
            _ = FileHelper.remove(p.scriptPath)
            console?.log(key: "log.app.selfUpdateLaunchFailed",
                         args: [error.localizedDescription], type: .error)
            return false
        }
        // Servisler DURDURULMAZ: kullanıcı uygulamayı güncelliyor, geliştirme ortamını
        // kapatmıyor. Tünelleri `applicationShouldTerminate` zaten koşulsuz kapatıyor.
        BRAMPPAppDelegate.shared?.realQuit(stopServices: false) ?? NSApp.terminate(nil)
        return true
    }
}
