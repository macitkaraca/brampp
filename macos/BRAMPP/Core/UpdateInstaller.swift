import Foundation
import Combine
import AppKit

// MARK: - İndirme sonrası davranış

/// Yeni sürüm bulunduğunda ne yapılacağı. Hiçbiri KURULUM yapmaz — en güçlüsü
/// doğrulanmış disk kalıbını açar, uygulamayı Uygulamalar klasörüne kullanıcı sürükler.
/// Seçenek adları bu sınırı olduğu gibi söyler (`set.upd.dl.mode.*`).
enum UpdateMode: String, CaseIterable, Identifiable {
    /// Yalnızca haber ver — indirme yok
    case notify
    /// İndir ve doğrula, dosyayı kullanıcıya bırak
    case download
    /// İndir, doğrula ve disk kalıbını aç
    case downloadAndOpen

    var id: String { rawValue }

    var labelKey: String {
        switch self {
        case .notify:         return "set.upd.dl.mode.notify"
        case .download:       return "set.upd.dl.mode.download"
        case .downloadAndOpen: return "set.upd.dl.mode.open"
        }
    }

    static func from(_ raw: String) -> UpdateMode { UpdateMode(rawValue: raw) ?? .notify }
}

// MARK: - İndirme + doğrulama boru hattı

/// Disk kalıbını indirir, DÖRT KAPIDAN geçirir ve doğrulanmışsa kullanıcıya bırakır.
///
/// **YERİNDE KENDİNİ DEĞİŞTİRME YOK — bu bir eksiklik değil, karardır.**
///   1. Ürün bir DMG. Kurmak `hdiutil attach` → `BRAMPP.app`'i dışarı kopyala →
///      `hdiutil detach` demek. ÇALIŞAN paketi kendi içinden atomik olarak
///      değiştirmek mümkün değildir; standart çözüm, ana süreç ölene kadar bekleyip
///      paketi takas eden ayrı bir "yeniden başlatıcı" süreçtir. Bu, takas ortasında
///      çökünce kullanıcıyı UYGULAMASIZ bırakan bir alt sistemdir — Sparkle'ın var
///      olma nedeni tam olarak budur ve bu projede üçüncü taraf bağımlılık yok.
///   2. `/Applications` her zaman yazılabilir değil. Başka bir yönetici kurduysa
///      takas ortasında parola sorulur. "BRAMPP kendini güncellemek için yönetici
///      parolanı istiyor" alışkanlığı, bir saldırganın isteyeceği tam o alışkanlıktır.
///   3. Projenin kendi şartnamesi yasaklıyor (spec/update-manifest.md: *"Never update
///      silently. BRAMPP tells the user and hands them the download."*).
///
/// Bu yüzden en güçlü kip: indir → dört kapıdan geçir → doğrulanmış kalıbı aç.
/// Sürükleme kullanıcıya ait. Karantina bayrağı da BİLEREK kaldırılmaz; kullanıcı
/// kalıbı açtığında Gatekeeper bizden bağımsız bir denetim daha yapar.
@MainActor
final class UpdateInstaller: ObservableObject {

    enum Phase: Equatable {
        case idle
        /// 0…1 arası oran
        case downloading(Double)
        case verifying
        /// Doğrulanmış disk kalıbının yolu
        case ready(URL)
        case failed(UpdateVerifier.Failure)
    }

    @Published private(set) var phase: Phase = .idle

    /// Konsola yazmak için — zayıf: kurucu, gösterildiği pencerenin ömrüne bağlı değil.
    weak var console: ConsoleStore?

    private var work: Task<Void, Never>?

    /// DİSKTE yaşayan hazırlık dizinlerinin adları, sahibi koşunun kimliğiyle.
    ///
    /// TEK BİR ALAN DEĞİL, çünkü aynı anda birden fazla dizin yaşayabilir: yeni koşu
    /// artık öncekinin bitmesini beklemez (bkz. `start()`), yani inmekte olan bir koşu
    /// ile ondan önce başlamış ama hâlâ sarılıp çözülmemiş bir koşu bir arada bulunur.
    /// Tek bir `stagingDir` alanı olsaydı, kapanan koşu "kendi" dizinini silerken
    /// alanın O ANDA gösterdiği — yani BAŞKASININ — dizinini silerdi.
    private var stagingNames: [Int: String] = [:]

    /// ŞU AN boru hattı koşturan kimlikler. Silme kuralı buna bakar: koşan iş kendi
    /// çöpünü kendi toplar, sahipsiz kalan (ör. doğrulanmış ama kurulmamış) dizinleri
    /// `cancel()` toplar.
    private var activeIDs: Set<Int> = []

    /// Her koşuya bir kimlik. İptal DE, yeni bir başlatma DA bu sayacı artırır; koşan
    /// boru hattı her aşama sınırında kendi kimliğini doğrular ve geçersizse SESSİZCE
    /// durup ardından kendi çöpünü toplar.
    ///
    /// NEDEN BAYRAK DEĞİL SAYAÇ: "iptal edildi mi" sorusunun yanıtı KİMİN sorduğuna
    /// bağlıdır. Bir koşu iptal edilip hemen yenisi başlarsa, tek bir bool ikisini
    /// ayırt edemez ve yeni koşu daha ilk sınırda kendini iptal edilmiş sanardı.
    private var generation = 0

    var isBusy: Bool {
        switch phase {
        case .downloading, .verifying: return true
        default: return false
        }
    }

    // MARK: - Dışa açık eylemler

    /// Yeni bir indirme başlatır.
    ///
    /// **YENİ KOŞU ÖNCEKİNİ BEKLEMEZ.** Bekliyordu ve bu, kurucuyu oturumun geri
    /// kalanında SESSİZCE kilitleyebiliyordu: zincir `_ = await previous?.value` idi;
    /// `Task<Void, Never>.value` ne fırlatır ne de bekleyenin iptalini dinler, yani
    /// önceki koşu (ör. EOF vermeyen bir pipe'ta asılı bir alt süreç yüzünden) hiç
    /// bitmezse yenisi HİÇ başlamaz ve `cancel()` de bu bekleyişi kesemez. Görünen
    /// yüzü: aşama `.verifying`de donar, "Durdur" işe yaramış gibi görünür ve o
    /// oturumdaki HER "İndir ve doğrula" tıklaması hiçbir şey yapmaz.
    ///
    /// Zincir yalnızca dizin çakışmasını önlemek için vardı; dizin artık SÜRÜMDEN değil
    /// KOŞUDAN türetildiği için (`PathConfig.updateStaging(version:run:)`) çakışma
    /// ifade edilemez. Önceki koşu yine de iptal edilir — ama beklenmez; kendi
    /// dizinini kendi toplayarak sessizce çekilir.
    func start(_ release: UpdateChecker.ReleaseInfo, openWhenReady: Bool) {
        generation &+= 1
        let id = generation
        work?.cancel()
        work = Task { [weak self] in
            await self?.run(release, openWhenReady: openWhenReady, id: id)
        }
    }

    /// Kullanıcı indirmeyi durdurdu (ya da pencere kapandı). Yarım dosya BIRAKILMAZ.
    ///
    /// **SİLME KOŞAN İŞE BIRAKILIR.** Eskiden `cancel()` dizini burada, YERİNDE
    /// siliyordu; Task iptali eş zamanlı değildir ve `Shell.run`/`sha256OfFile` o an
    /// dosyayı okumaya devam ediyordu. Sonuç kullanıcının sebep olmadığı kırmızı bir
    /// "Doğrulama başarısız" satırıydı — daha kötü zamanlamada ise SİLİNMİŞ bir dosya
    /// `.ready` işaretlenip `NSWorkspace.open` ile açılmaya çalışılıyordu.
    func cancel() {
        generation &+= 1                          // koşan iş bir sonraki sınırda düşer
        work?.cancel()
        phase = .idle                             // kullanıcıya ANINDA yanıt
        cleanupIdleStaging()                      // sahipsiz dizinleri biz toplarız
    }

    /// Doğrulanmış kalıbı aç — kurulum penceresi (sürükle-bırak) burada belirir.
    func revealVerified() {
        guard case .ready(let url) = phase else { return }
        NSWorkspace.shared.open(url)
    }

    /// Doğrulanmış ama kurulmamış dosyayı sil — kullanıcı vazgeçti.
    ///
    /// `cancel()`e yönlendirilir: aradaki tek fark hangi düğmeye basıldığıdır, silme
    /// kuralı (koşan iş varsa ONA bırak) İKİSİ İÇİN DE aynı olmak zorunda.
    func discard() { cancel() }

    // MARK: - Alt süreç zaman aşımları

    /// `hdiutil attach/detach` yerel diske iş yapar; yine de bozuk bir kalıpta
    /// takılabilir. Ölçü cömert, ama SONSUZ değil.
    private static let mountTimeout: TimeInterval = 120
    /// `codesign --verify --deep --strict` 60 MB'lık paketin her kaynağını özetler.
    private static let codesignTimeout: TimeInterval = 180
    /// `spctl --assess` Apple'a bir tur atar. Ağ olmadığında hızlı düşer; captive
    /// portal arkasında ise TCP zaman aşımını bekler — sınırı gereken yer burasıdır.
    private static let assessTimeout: TimeInterval = 90

    // MARK: - Boru hattı

    private func run(_ release: UpdateChecker.ReleaseInfo, openWhenReady: Bool, id: Int) async {
        // İLK sınır burası: `start()` ile bu satır arasında iptal gelmiş olabilir.
        // Denetimsiz kalsaydı, kullanıcının durdurduğu bir iş 60 MB'lık indirmeye
        // YENİ BAŞLARDI.
        guard !isStale(id) else { return }

        activeIDs.insert(id)
        defer { activeIDs.remove(id) }

        // ÖZET YOKSA İNDİRME YOK. Manifest okunamadığında sha256 elimizde olmaz ve
        // doğrulayamayacağımız bir dosyayı indirmek, doğrulama vaadini boşa çıkarır.
        // Arayüz bu durumda indirme düğmesini hiç göstermez (`upd.dl.noHash`);
        // buradaki koruma ikinci kapıdır.
        guard let expected = release.sha256, let asset = release.assetURL else {
            // `.checksumMismatch` DEĞİL: o neden "indirilen dosya silindi" der ve
            // burada indirilmiş bir dosya yoktur.
            fail(.noChecksum, run: id); return
        }
        guard UpdateVerifier.isTrustedReleaseURL(asset) else {
            fail(.untrustedURL, run: id); return
        }
        // Karşılaştıracak kendi kimliğimiz yoksa (ad-hoc imzalı geliştirme derlemesi)
        // güncelleme yapılmaz — "aynı geliştirici mi" sorusu yanıtsız kalır.
        guard let ownTeam = UpdateVerifier.ownTeamIdentifier() else {
            fail(.selfUnsigned, run: id); return
        }

        // Hazırlık dizini `~/Library/Application Support/BRAMPP/updates/<sürüm>-<koşu>`:
        //   • `/tmp` DEĞİL — herkese okunur, başka bir süreç dosyayı doğrulama ile
        //     açma arasında takas edebilir.
        //   • `~/Downloads` DEĞİL — kullanıcı biz doğrulamadan çift tıklayabilir.
        //   • Yalnızca `<sürüm>` DEĞİL — bkz. PathConfig.updateStagingName: koşu
        //     numarası iki koşunun aynı dizini paylaşmasını İMKÂNSIZ kılar.
        // Sürüm dizgisi `normalize()` çıktısıdır: yalnızca rakam ve tek noktalar
        // içerir, dolayısıyla yola ".." gibi bir bileşen sokamaz.
        let name = PathConfig.updateStagingName(version: release.version, run: id)
        let dir = PathConfig.updateStaging(name: name)
        stagingNames[id] = name
        // Bu süreç içinde aynı ad iki kez üretilemez; silinen, ÖNCEKİ OTURUMDAN kalmış
        // olabilecek aynı adlı dizindir (sayaç her açılışta 1'den başlar ve açılış
        // temizliği kısıtlı süreçlerde atlanır — bkz. BRAMPPApp.bootstrapManagers).
        _ = FileHelper.remove(dir)
        // Kalıntılar gider: doğrulanıp da kurulmamış her disk kalıbı ~60 MB ve
        // `updates/` dizini kullanıcının hiç bakmadığı bir yer. KORUNAN küme, BU
        // kurucunun diskte yaşayan TÜM dizinleridir — yalnızca kendi dizinimiz değil:
        // yanımızda sarılıp çözülen başka bir koşunun dosyasını silmek, tam olarak
        // koşu başına dizine geçerken ortadan kaldırdığımız hatanın kendisi olurdu.
        UpdateInstaller.pruneOldStaging(keeping: Set(stagingNames.values))
        guard FileHelper.createDirectory(dir) else { fail(.downloadFailed, run: id); return }

        let dmgPath = "\(dir)/BRAMPP-\(release.version).dmg"
        console?.log(key: "log.app.updateDownloadStarted", args: [release.version], type: .info)
        phase = .downloading(0)

        var req = URLRequest(url: asset)
        req.setValue("BRAMPP/\(UpdateChecker.currentVersion)", forHTTPHeaderField: "User-Agent")

        let progressDelegate = UpdateDownloadProgress { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .downloading = self.phase else { return }
                self.phase = .downloading(fraction)
            }
        }

        let temp: URL
        let response: URLResponse
        do {
            (temp, response) = try await URLSession.shared.download(for: req, delegate: progressDelegate)
        } catch {
            // İPTAL BİR HATA DEĞİLDİR: kullanıcı durdurduysa konsola hata satırı
            // düşmemeli, yalnızca yarım dosya temizlenmeli.
            if isStale(id) { abandon(run: id) } else { fail(.downloadFailed, run: id) }
            return
        }
        guard !isStale(id) else { abandon(run: id); return }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            fail(.downloadFailed, run: id); return
        }
        // YÖNLENDİRME SONRASI adres de denetlenir. `URLSession` isteği CDN'e taşır;
        // yalnızca İSTENEN adresi doğrulamak, gerçekte inen dosyayı doğrulamaz.
        guard UpdateVerifier.isTrustedReleaseURL(response.url) else {
            fail(.untrustedURL, run: id); return
        }
        // Geçici dosya bu noktadan sonra silinebilir — kendi dizinimize taşı.
        _ = FileHelper.remove(dmgPath)
        do {
            try FileManager.default.moveItem(at: temp, to: URL(fileURLWithPath: dmgPath))
        } catch {
            fail(.downloadFailed, run: id); return
        }

        guard !isStale(id) else { abandon(run: id); return }
        phase = .verifying

        // ── Kapı 2: sağlama ────────────────────────────────────────────────
        // `sha256OfFile` iptalde nil döner (bkz. UpdateVerifier). Bunu "sağlama
        // tutmadı" saymak, kullanıcının kendi durdurduğu işi hata gibi göstermek
        // olurdu — bu yüzden ÖNCE geçerlilik sorulur.
        let computed = await UpdateVerifier.sha256OfFile(at: dmgPath)
        guard !isStale(id) else { abandon(run: id); return }
        guard let computed, UpdateVerifier.checksumsMatch(computed, expected) else {
            fail(.checksumMismatch, run: id); return
        }

        // ── Kalıbı bağla ───────────────────────────────────────────────────
        // Bağlama noktası BİZİM seçtiğimiz özel yol: kalıbın içindeki birim adı
        // yayıncının (ve dolayısıyla saldırganın) etkisindedir; `/Volumes` altında
        // ad çakışması ve sürpriz bir yol üretebilirdi.
        // Argümanlar argv dizisiyle geçer (`Shell.run`), asla bash metnine gömülmez.
        //
        // Her alt sürecin SÜRESİ SINIRLI (`Shell.runAsync(_:arguments:timeout:)`).
        // `Process` görev iptalini dinlemez; sınır olmadan tek bir asılı `spctl`
        // hem doğrulamayı hem "durdur" düğmesini dakikalarca rehin alırdı.
        let mount = "\(dir)/mnt"
        _ = FileHelper.createDirectory(mount)
        let attach = await Shell.runAsync("/usr/bin/hdiutil", arguments: [
            "attach", dmgPath, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount
        ], timeout: UpdateInstaller.mountTimeout)
        guard !isStale(id) else { await abandon(run: id, unmounting: mount); return }
        guard attach.exitCode == 0 else { fail(.mountFailed, run: id); return }

        let appPath = "\(mount)/BRAMPP.app"
        guard FileHelper.exists(appPath) else {
            await detach(mount); fail(.appNotFound, run: id); return
        }

        // ── Kapı 3a: imza bütünlüğü ────────────────────────────────────────
        let verify = await Shell.runAsync("/usr/bin/codesign",
                                          arguments: ["--verify", "--deep", "--strict", appPath],
                                          timeout: UpdateInstaller.codesignTimeout)
        guard !isStale(id) else { await abandon(run: id, unmounting: mount); return }
        guard UpdateVerifier.isCodesignVerified(exitCode: verify.exitCode, stderr: verify.error) else {
            await detach(mount); fail(.codesignFailed, run: id); return
        }

        // ── Kapı 3b: Team ID ───────────────────────────────────────────────
        // `codesign -dv` ayrıntıyı STDERR'e yazar; iki akış da taranır ki
        // gelecekteki bir davranış değişikliği denetimi sessizce boşa düşürmesin.
        let details = await Shell.runAsync("/usr/bin/codesign",
                                           arguments: ["-dv", "--verbose=4", appPath],
                                           timeout: UpdateInstaller.codesignTimeout)
        guard !isStale(id) else { await abandon(run: id, unmounting: mount); return }
        let team = UpdateVerifier.teamIdentifier(inCodesignOutput: details.error + "\n" + details.output)
        guard let team, team == ownTeam else {
            await detach(mount)
            fail(.teamMismatch(expected: ownTeam, got: team), run: id)
            return
        }

        // ── Kapı 4: noter onayı ────────────────────────────────────────────
        let assess = await Shell.runAsync("/usr/sbin/spctl",
                                          arguments: ["--assess", "--type", "execute", "--verbose", appPath],
                                          timeout: UpdateInstaller.assessTimeout)
        guard !isStale(id) else { await abandon(run: id, unmounting: mount); return }
        // Zaman aşımı KABUL DEĞİLDİR: `spctl` yanıt vermediyse noter onayını GÖRMEDİK.
        // `isNotarizedAccepted` bunu zaten çıkış kodundan eler (-998 ≠ 0); ayrıca
        // yazmak, ileride sözleşme değişirse sessizce gevşememesi içindir.
        guard !assess.isTimeout,
              UpdateVerifier.isNotarizedAccepted(exitCode: assess.exitCode,
                                                 output: assess.error + "\n" + assess.output) else {
            await detach(mount); fail(.notNotarized, run: id); return
        }

        await detach(mount)
        _ = FileHelper.remove(mount)

        // SON sınır: buradan sonra dosya kullanıcıya "hazır" diye gösterilir ve
        // `openWhenReady` ile AÇILIR. İptal edilmiş bir koşunun silinmiş dosyayı
        // açmaya çalışması tam olarak bu denetimin engellediği şeydir.
        guard !isStale(id) else { abandon(run: id); return }

        console?.log(key: "log.app.updateVerifyOk", type: .success)
        phase = .ready(URL(fileURLWithPath: dmgPath))
        if openWhenReady { NSWorkspace.shared.open(URL(fileURLWithPath: dmgPath)) }
    }

    // MARK: - Koşu geçerliliği

    /// Bu koşu iptal edildi ya da yenisiyle değiştirildi mi?
    /// İki ölçüt de sorulur: `Task.isCancelled` üst iptali, `generation` ise
    /// "artık ben değilim" durumunu yakalar.
    private func isStale(_ id: Int) -> Bool { Task.isCancelled || id != generation }

    /// Geçersiz koşunun SESSİZ çıkışı. Konsola hata YAZILMAZ ve `phase` bozulmaz:
    /// kullanıcı zaten `.idle` görüyor, buraya kırmızı bir satır düşürmek onun
    /// yapmadığı bir şeyi yapmış gibi göstermek olurdu.
    ///
    /// Silinen KENDİ dizinidir — o an "güncel" olan değil. Yanımızda başka bir koşu
    /// iniyor olabilir ve onun dizinine dokunmak yasaktır.
    private func abandon(run id: Int) {
        cleanupStaging(of: id)
    }

    private func abandon(run id: Int, unmounting mount: String) async {
        await detach(mount)
        cleanupStaging(of: id)
    }

    // MARK: - Temizlik

    /// Herhangi bir kapı kapanınca: BU KOŞUNUN indirdiği her şey silinir ve neden
    /// konsola yazılır. Çalışan uygulamaya dokunulmaz; doğrulanmamış hiçbir şey açılmaz.
    ///
    /// **BAYAT KOŞU SESSİZ DÜŞER.** Kapıların çoğu bir `await`ten SONRA kapanır
    /// (`detach`, `sha256OfFile`, alt süreçler) ve `await` ana aktörü bırakır. O
    /// pencerede gelen bir `cancel()` `phase`i `.idle` yapar; üstüne `.failed` yazıp
    /// konsola kırmızı satır düşürmek, kullanıcıya YAPMADIĞI bir şeyi hata olarak
    /// göstermekti. Denetim tek yerde — her çağrı yerine ayrı ayrı serpiştirilmiş bir
    /// koşul, ileride eklenecek yeni bir kapıda unutulurdu.
    ///
    /// Dizin yine de silinir: bayat koşunun yarım dosyası her hâlde çöptür.
    private func fail(_ reason: UpdateVerifier.Failure, run id: Int) {
        cleanupStaging(of: id)
        guard !isStale(id) else { return }
        console?.log(key: "log.app.updateVerifyFailed",
                     args: ["@\(reason.messageKey)"], type: .error)
        phase = .failed(reason)
    }

    /// Tek bir koşunun dizinini siler. Kayıt da düşer ki sonraki `pruneOldStaging`
    /// çağrısı artık var olmayan bir adı korumaya çalışmasın.
    private func cleanupStaging(of id: Int) {
        guard let name = stagingNames.removeValue(forKey: id) else { return }
        _ = FileHelper.remove(PathConfig.updateStaging(name: name))
    }

    /// SAHİPSİZ hazırlık dizinlerini siler: koşusu bitmiş ama dosyası duran her şey —
    /// tipik olarak doğrulanmış ama kullanıcının kurmadığı disk kalıbı (`discard()`).
    ///
    /// KOŞANLARA DOKUNULMAZ. Silme, `Shell.run`/`sha256OfFile` o dosyayı okurken
    /// yapılırsa kullanıcının sebep olmadığı kırmızı bir "Doğrulama başarısız" satırı
    /// üretir; koşan iş kendi çöpünü bir sonraki sınırda kendi toplar.
    private func cleanupIdleStaging() {
        for (id, name) in stagingNames where !activeIDs.contains(id) {
            _ = FileHelper.remove(PathConfig.updateStaging(name: name))
            stagingNames[id] = nil
        }
    }

    private func detach(_ mount: String) async {
        _ = await Shell.runAsync("/usr/bin/hdiutil", arguments: ["detach", mount, "-quiet"],
                                 timeout: UpdateInstaller.mountTimeout)
    }

    // MARK: - Eski sürümlerin kalıntıları

    /// `~/Library/Application Support/BRAMPP/updates/` altında `keeping` KÜMESİNDE
    /// OLMAYAN her hazırlık dizinini siler.
    ///
    /// NEDEN GEREKLİ: doğrulanan bir disk kalıbı kullanıcı kurana kadar orada durur
    /// ve kullanıcı KURMAYABİLİR. Eskiden yalnızca AYNI sürümün dizini temizleniyordu;
    /// her yayın ~60 MB'ı, kullanıcının varlığından haberdar olmadığı bir dizinde
    /// sonsuza dek bırakıyordu.
    ///
    /// **NEDEN TEK AD DEĞİL KÜME:** dizin adı artık sürümü değil KOŞUYU adlandırır
    /// (`1.6-3`) ve aynı anda birden fazla koşunun dizini yaşayabilir. Tek bir ad
    /// korunsaydı, yeni koşu yanı başında sarılıp çözülen koşunun dosyasını silerdi —
    /// koşu başına dizine geçerken ortadan kaldırdığımız hatanın ta kendisi.
    /// Açılışta küme BOŞTUR: o an bekleyen hiçbir kurulum yoktur.
    ///
    /// Kalıp `ConsoleLogFile.pruneOldFiles()` ile aynı — silinecek girdi ADINDAN
    /// çözülür ve `names` verildiğinde diske DOKUNULMAZ (birim test bu yüzden mümkün).
    @discardableResult
    static func pruneOldStaging(keeping: Set<String>, names: [String]? = nil) -> [String] {
        let entries = names ?? FileHelper.contentsOfDirectory(PathConfig.updates)
        var removed: [String] = []
        for name in entries {
            // Gizli girdiler (.DS_Store) ve korunacak koşuların dizinleri atlanır.
            guard !name.hasPrefix("."), !keeping.contains(name) else { continue }
            removed.append(name)
            if names == nil { _ = FileHelper.remove(PathConfig.updateStaging(name: name)) }
        }
        return removed
    }
}

// MARK: - İndirme ilerlemesi köprüsü

/// `URLSession.download(for:delegate:)` yalnızca ilerleme için bir temsilci ister;
/// tamamlanmayı `await` zaten döndürür.
///
/// NEDEN DÜZ `download(for:)` DEĞİL: o çağrı bitene kadar hiçbir şey söylemez.
/// Onlarca megabaytlık bir kalıp inerken donmuş bir pencere göstermek, indirmeyi
/// iptal edilemez gibi hissettirir. NEDEN `bytes(for:)` DEĞİL: bayt bayt asenkron
/// döngü, on milyonlarca askıya alma noktasından geçmek demektir — aynı bilgi için
/// anlamsız bir maliyet.
///
/// Geri çağrılar URLSession'ın KENDİ kuyruğundan gelir, ana aktörden değil — bu
/// yüzden temsilci üyeleri `nonisolated`. Sınıf değiştirilebilir durum TUTMAZ;
/// tek alanı değişmez, Sendable bir kapanıştır, dolayısıyla kilide gerek yok.
private final class UpdateDownloadProgress: NSObject, URLSessionDownloadDelegate {

    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
        super.init()
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        // Sunucu uzunluk bildirmediyse oran hesaplanamaz — çubuk belirsiz kalır.
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    /// Protokolün ZORUNLU üyesi. Dosyayı taşımak bize düşmez: `download(for:delegate:)`
    /// kalıcı bir geçici yola kendisi taşıyıp döndürür.
    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) { }
}
