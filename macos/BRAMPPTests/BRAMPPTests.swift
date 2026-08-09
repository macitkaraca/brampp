import XCTest
@testable import BRAMPP

/// Saf mantık fonksiyonları için birim testler.
/// Bu turlarda düzelttiğimiz regresyonların (UTF-8 bölünme, port ayrıştırma,
/// domain doğrulama, Codable geri uyumluluk) tekrar oluşmasını engeller.
@MainActor
final class BRAMPPTests: XCTestCase {

    // MARK: - Shell.decodeUTF8Prefix

    func testDecodeUTF8_ASCII() {
        var d = Data("Hello".utf8)
        XCTAssertEqual(Shell.decodeUTF8Prefix(&d), "Hello")
        XCTAssertTrue(d.isEmpty)
    }

    func testDecodeUTF8_MultibyteByteByByte() {
        // 🍺 (4 bayt) tek tek gelir — hiçbir bayt atılmamalı
        var pending = Data()
        var out = ""
        for byte in Array("🍺".utf8) {
            pending.append(byte)
            out += Shell.decodeUTF8Prefix(&pending)
        }
        XCTAssertEqual(out, "🍺")
        XCTAssertTrue(pending.isEmpty)
    }

    func testDecodeUTF8_MixedTurkishAndEmojiChunks() {
        let s = "Ağrı ─ İçişleri ✅ 🎉"
        let all = Array(s.utf8)
        var pending = Data()
        var out = ""
        var idx = 0
        for cs in [1, 3, 2, 5, 1, 4, 2, 7, 3, 1, 1, 1, 9, 2] {
            let end = min(idx + cs, all.count)
            if idx < end { pending.append(contentsOf: all[idx..<end]); out += Shell.decodeUTF8Prefix(&pending); idx = end }
        }
        if idx < all.count { pending.append(contentsOf: all[idx...]) }
        out += Shell.decodeUTF8Prefix(&pending)
        if !pending.isEmpty { out += String(decoding: pending, as: UTF8.self) }
        XCTAssertEqual(out, s)
    }

    func testDecodeUTF8_InvalidByte() {
        var d = Data([0x41, 0x42, 0xFF, 0x43])   // AB<invalid>C
        let out = Shell.decodeUTF8Prefix(&d)
        XCTAssertTrue(out.hasPrefix("AB"))
        XCTAssertTrue(out.hasSuffix("C"))
    }

    // MARK: - Shell.quote

    func testShellQuote_Apostrophe() {
        XCTAssertEqual(Shell.quote("O'Brien"), "'O'\\''Brien'")
        XCTAssertEqual(Shell.quote("/Users/x/site"), "'/Users/x/site'")
    }

    // MARK: - WebServerPorts.portSuffix

    func testPortSuffix_StandardPorts() {
        XCTAssertEqual(WebServerPorts.portSuffix(443, https: true), "")
        XCTAssertEqual(WebServerPorts.portSuffix(80, https: false), "")
    }

    func testPortSuffix_NonStandard() {
        XCTAssertEqual(WebServerPorts.portSuffix(8443, https: true), ":8443")
        XCTAssertEqual(WebServerPorts.portSuffix(8080, https: false), ":8080")
        XCTAssertEqual(WebServerPorts.portSuffix(443, https: false), ":443")   // http'de 443 standart değil
    }

    // MARK: - DomainManager.isValidDomainName

    func testDomainName_Valid() {
        for name in ["myproject.local", "api.test", "a.b.c.dev", "site-1.local", "x.io"] {
            XCTAssertTrue(DomainManager.isValidDomainName(name), "geçerli olmalı: \(name)")
        }
    }

    func testDomainName_Invalid() {
        for name in ["", " ", "boşluk lu.local", "tırnak'lı.local", "slash/lı.local",
                     ".baştaNokta", "sondaNokta.", "-.local", "a..b"] {
            XCTAssertFalse(DomainManager.isValidDomainName(name), "geçersiz olmalı: \(name)")
        }
    }

    // MARK: - DomainManager.isValidDocumentRoot

    /// Bu değer Apache/nginx direktiflerinin İÇİNE gömülüyor — config enjeksiyonuna
    /// açık karakterler sınırda reddedilmeli.
    func testDocumentRoot_Valid() {
        // Tek tırnak gerçek yollarda geçer ve Shell.quote onu doğru kaçırır → GEÇERLİ kalmalı
        for p in ["/Users/me/Sites/app", "/Volumes/Disk 1/proje", "/Users/me/O'Brien/site"] {
            XCTAssertTrue(DomainManager.isValidDocumentRoot(p), "geçerli olmalı: \(p)")
        }
    }

    func testDocumentRoot_RejectsConfigInjection() {
        for p in [
            "",                                   // boş
            "goreli/yol",                         // mutlak değil
            "/Users/me/\"quoted\"",               // direktifi kapatır
            "/Users/me/$HOME/site",               // nginx değişkeni ($ kaçışı yok)
            "/Users/me/site;root /etc",           // nginx direktif ayracı
            "/Users/me/site{}",                   // nginx blok sözdizimi
            "/Users/me/site\nDocumentRoot /etc",  // satır sonu → direktif enjeksiyonu
            // Kabuk metakarakterleri: bu değer start.sh ve kurulum script'lerine de giriyor
            "/Users/me/site`touch /tmp/x`",        // ters tırnak → komut ikamesi
            "/Users/me/site|whoami",               // boru
            "/Users/me/site&whoami",               // arka plan / zincirleme
            "/Users/me/site(sub)",                 // alt kabuk
            "/Users/me/site>out"                   // yönlendirme
        ] {
            XCTAssertFalse(DomainManager.isValidDocumentRoot(p), "reddedilmeli: \(p.debugDescription)")
        }
    }

    // MARK: - Domain Codable (lossy decode + round-trip)

    func testDomainList_RoundTrip() throws {
        let d = Domain.php(name: "test.local", version: .v83, ssl: true, webServer: .apache)
        let list = DomainList(domains: [d])
        let data = try JSONEncoder().encode(list)
        let decoded = try JSONDecoder().decode(DomainList.self, from: data)
        XCTAssertEqual(decoded.domains.count, 1)
        XCTAssertEqual(decoded.domains.first?.name, "test.local")
        XCTAssertEqual(decoded.droppedCount, 0)
    }

    func testDomain_isEnabled_BackwardCompatAndRoundTrip() throws {
        // Eski kayıtta isEnabled alanı YOK → true varsayılmalı (mevcut domainler
        // güncelleme sonrası pasifleşmiş görünmemeli)
        let legacy = """
        { "id": "\(UUID().uuidString)", "name": "eski.local", "platform": "php",
          "sslEnabled": false, "createdAt": 0 }
        """
        let d1 = try JSONDecoder().decode(Domain.self, from: Data(legacy.utf8))
        XCTAssertTrue(d1.isEnabled, "eski kayıt varsayılan etkin olmalı")

        // Round-trip: isEnabled=false korunmalı
        var d2 = Domain.php(name: "yeni.local", version: .v83, ssl: false, webServer: .nginx)
        d2.isEnabled = false
        let data = try JSONEncoder().encode(d2)
        let back = try JSONDecoder().decode(Domain.self, from: data)
        XCTAssertFalse(back.isEnabled, "isEnabled=false round-trip'te korunmalı")
    }

    func testDomainList_LossyDecode_SkipsCorruptRecord() throws {
        // İki kayıt: biri geçerli, biri bozuk (platform alanı geçersiz).
        // Bozuk olan atlanmalı, geçerli olan yüklenmeli — TÜM liste düşmemeli.
        let json = """
        {
          "lastUpdated": 0,
          "domains": [
            { "id": "\(UUID().uuidString)", "name": "iyi.local", "platform": "php",
              "sslEnabled": true, "createdAt": 0 },
            { "id": "\(UUID().uuidString)", "name": "bozuk.local", "platform": "GEÇERSİZ_PLATFORM",
              "sslEnabled": true, "createdAt": 0 }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(DomainList.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.domains.count, 1)
        XCTAssertEqual(decoded.domains.first?.name, "iyi.local")
        XCTAssertEqual(decoded.droppedCount, 1)   // bir bozuk kayıt atlandı
    }

    func testDomainList_ContainerCorruption_Throws() {
        // 'domains' null / eksik / dizi-değil → decode THROW etmeli ki çağıran
        // catch'e düşüp .corrupt.bak yedeği alsın. Sessizce [] dönerse sonraki
        // kaydetme dosyayı boş listeyle ezer (toplu veri kaybı).
        for bad in [
            #"{"lastUpdated": 0, "domains": null}"#,
            #"{"lastUpdated": 0}"#,
            #"{"lastUpdated": 0, "domains": {"a": 1}}"#
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(DomainList.self, from: Data(bad.utf8)),
                                 "konteyner bozukluğu throw etmeli: \(bad)")
        }
    }

    func testDomain_UnknownVersionValue_FieldNilsRecordSurvives() throws {
        // Tanınmayan sürüm değeri ("9.9") TÜM kaydı düşürmemeli — alan nil'e düşmeli
        let json = """
        { "id": "\(UUID().uuidString)", "name": "gelecek.local", "platform": "php",
          "phpVersion": "9.9", "sslEnabled": true, "createdAt": 0 }
        """
        let d = try JSONDecoder().decode(Domain.self, from: Data(json.utf8))
        XCTAssertEqual(d.name, "gelecek.local")
        XCTAssertNil(d.phpVersion, "bilinmeyen sürüm nil'e düşmeli, kaydı öldürmemeli")
    }

    func testDomain_BackwardCompat_MissingNewFields() throws {
        // Eski format: yeni alanlar (customDocumentRoot, http2Enabled vb.) yok → varsayılanlar
        let json = """
        { "id": "\(UUID().uuidString)", "name": "eski.local", "platform": "php",
          "sslEnabled": false, "createdAt": 0 }
        """
        let d = try JSONDecoder().decode(Domain.self, from: Data(json.utf8))
        XCTAssertEqual(d.name, "eski.local")
        XCTAssertEqual(d.webServer, .apache)            // varsayılan
        XCTAssertNil(d.customDocumentRoot)              // yeni alan → nil
        XCTAssertTrue(d.websocketEnabled)               // yeni alan → true varsayılan
    }

    // MARK: - Domain.sitePath (customDocumentRoot)

    func testDomain_SitePath_DefaultVsCustom() {
        let d1 = Domain.php(name: "a.local")
        XCTAssertTrue(d1.sitePath.hasSuffix("/Sites/a.local"))

        var d2 = Domain.php(name: "b.local")
        d2.customDocumentRoot = "/custom/root"
        XCTAssertEqual(d2.sitePath, "/custom/root")
    }

    // MARK: - AppSettings defaults + backward-compat

    func testAppSettings_Defaults() {
        let s = AppSettings()
        XCTAssertEqual(s.defaultPHPVersion, .v83)
        XCTAssertFalse(s.autoStartServices)
        XCTAssertTrue(s.autoStartServiceIds.isEmpty)   // "son çalışanlar" yerine seçili liste (varsayılan boş)
        XCTAssertTrue(s.installPromptAutoConfirm)
        XCTAssertEqual(s.installPromptAutoConfirmSeconds, 10)
        XCTAssertTrue(s.startPHPOnWebServerStart)
    }

    func testAppSettings_BackwardCompat_EmptyJSON() throws {
        // Boş JSON → tüm alanlar varsayılana düşmeli (eski ayar dosyaları)
        let s = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(s.defaultPHPVersion, .v83)
        XCTAssertEqual(s.autoRefreshInterval, 30)
        XCTAssertEqual(s.installPromptAutoConfirmSeconds, 10)
    }

    // MARK: - PHPVersion / Platform mappings

    func testPHPVersion_Ports() {
        XCTAssertEqual(PHPVersion.v81.port, 9081)
        XCTAssertEqual(PHPVersion.v83.port, 9083)
        XCTAssertEqual(PHPVersion.v84.port, 9084)
        XCTAssertEqual(PHPVersion.v85.port, 9085)
    }

    func testPHPVersion_BrewService() {
        XCTAssertEqual(PHPVersion.v85.brewService, "php@8.5")
    }

    func testWebServer_RecommendedByPlatform() {
        XCTAssertEqual(WebServer.recommended(for: .php), .apache)
        XCTAssertEqual(WebServer.recommended(for: .static_), .apache)
        XCTAssertEqual(WebServer.recommended(for: .nodejs), .nginx)
        XCTAssertEqual(WebServer.recommended(for: .python), .nginx)
        XCTAssertEqual(WebServer.recommended(for: .dotnet), .nginx)
    }

    // MARK: - VHostTemplates (SSL koşullu üretim)

    func testVHost_ApachePHP_SSLDisabled_NoHTTPSBlock() {
        let d = Domain.php(name: "nossl.local", ssl: false, webServer: .apache)
        let cfg = VHostTemplates.generate(for: d)
        XCTAssertFalse(cfg.contains("SSLEngine on"), "SSL kapalıyken SSL bloğu üretilmemeli")
        XCTAssertFalse(cfg.contains(":443>"), "SSL kapalıyken 443 vhost'u olmamalı")
    }

    func testVHost_ApachePHP_SSLEnabled_HasHTTPSBlock() {
        let d = Domain.php(name: "ssl.local", ssl: true, webServer: .apache)
        let cfg = VHostTemplates.generate(for: d)
        XCTAssertTrue(cfg.contains("SSLEngine on"), "SSL açıkken SSL bloğu üretilmeli")
    }

    func testVHost_NginxProxy_SSLDisabled_NoSSLListen() {
        let d = Domain.nodejs(name: "node.local", port: 3005, ssl: false, webServer: .nginx)
        let cfg = VHostTemplates.generate(for: d)
        XCTAssertFalse(cfg.contains("ssl_certificate"), "SSL kapalıyken ssl_certificate olmamalı")
    }

    // MARK: - Uygulama-kapalı 503 sayfası

    func testVHost_ProxyTemplates_HaveAppDownPage() {
        // Nginx proxy → error_page + @app_down
        let n = Domain.nodejs(name: "n.local", port: 3005, ssl: true, webServer: .nginx)
        let ncfg = VHostTemplates.generate(for: n)
        XCTAssertTrue(ncfg.contains("error_page 502 503 504"), "nginx proxy'de error_page olmalı")
        XCTAssertTrue(ncfg.contains("@app_down"), "nginx proxy'de @app_down location olmalı")

        // Apache proxy → ErrorDocument 503
        var a = n; a.webServer = .apache
        let acfg = VHostTemplates.generate(for: a)
        XCTAssertTrue(acfg.contains("ErrorDocument 503"), "apache proxy'de ErrorDocument 503 olmalı")
    }

    func testAppDownHTML_NoQuoteConflicts() {
        // Apache çift tırnak, nginx tek tırnak içine gömer — HTML ikisini de içermemeli
        let html = VHostTemplates.appDownHTML(domain: "x.local")
        XCTAssertFalse(html.contains("\""), "HTML çift tırnak içermemeli (Apache ErrorDocument kırılır)")
        XCTAssertFalse(html.contains("'"), "HTML tek tırnak içermemeli (nginx return kırılır)")
        XCTAssertFalse(html.contains("$"), "HTML $ içermemeli (nginx değişken olarak yorumlar)")
        XCTAssertTrue(html.contains("x.local"))
    }

    // MARK: - FileHelper güvenli config yamalama

    private func tempFile(_ name: String) -> String {
        NSTemporaryDirectory() + "hy-test-\(UUID().uuidString)-\(name)"
    }

    func testAppendLineIfMissing_CommentedLineReactivated() {
        let path = tempFile("conf")
        defer { FileHelper.remove(path) }
        FileHelper.write("Listen 80\n#IncludeOptional /etc/x.conf\nServerName localhost\n", to: path)

        XCTAssertTrue(FileHelper.appendLineIfMissing("IncludeOptional /etc/x.conf", to: path))
        let out = FileHelper.readString(path) ?? ""
        let lines = out.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(lines.contains("IncludeOptional /etc/x.conf"), "yorumlu satır aktifleştirilmeli")
        XCTAssertFalse(lines.contains("#IncludeOptional /etc/x.conf"), "yorumlu hâli kalmamalı")
        // Eskiden alt-dize eşleşmesi yüzünden HİÇ eklenmiyordu — dosyada tek aktif kopya olmalı
        XCTAssertEqual(lines.filter { $0 == "IncludeOptional /etc/x.conf" }.count, 1)
    }

    func testAppendLineIfMissing_ExactLineNotDuplicated() {
        let path = tempFile("conf")
        defer { FileHelper.remove(path) }
        FileHelper.write("IncludeOptional /etc/x.conf\n", to: path)
        XCTAssertTrue(FileHelper.appendLineIfMissing("IncludeOptional /etc/x.conf", to: path))
        let out = FileHelper.readString(path) ?? ""
        XCTAssertEqual(out.components(separatedBy: "IncludeOptional").count - 1, 1, "satır çoğaltılmamalı")
    }

    func testReadStringDetailed_MissingVsUnreadable() throws {
        // missing
        if case .missing = FileHelper.readStringDetailed(tempFile("yok")) {} else {
            XCTFail("olmayan dosya .missing dönmeli")
        }
        // Latin-1 fallback: UTF-8 olarak geçersiz ama METİN olan içerik okunabilmeli
        // ve kodlaması .isoLatin1 olarak RAPORLANMALI (geri yazarken korunması için).
        // NOT: NUL içeren ikili dosyalar artık .unreadable döner —
        // bkz. testReadStringDetailed_BinaryIsUnreadable.
        let path = tempFile("latin1")
        defer { FileHelper.remove(path) }
        try Data([0x4C, 0x69, 0x73, 0x74, 0x65, 0x6E, 0x20, 0xFE, 0x0A]).write(to: URL(fileURLWithPath: path))  // "Listen þ\n" Latin-1
        if case .ok(let s, let enc) = FileHelper.readStringDetailed(path) {
            XCTAssertTrue(s.hasPrefix("Listen"), "Latin-1 fallback içeriği okumalı")
            XCTAssertEqual(enc, .isoLatin1, "kodlama Latin-1 olarak raporlanmalı")
        } else {
            XCTFail("Latin-1 içerik .ok dönmeli (fallback)")
        }
    }

    func testEnsureApacheModule_CommentedModuleActivated() {
        let path = tempFile("httpd")
        defer { FileHelper.remove(path) }
        FileHelper.write("#LoadModule ssl_module lib/mod_ssl.so\nListen 80\n", to: path)
        XCTAssertTrue(FileHelper.ensureApacheModule("ssl_module", loadPath: "lib/mod_ssl.so", in: path))
        let out = FileHelper.readString(path) ?? ""
        XCTAssertTrue(out.contains("\nListen 80") || out.hasPrefix("LoadModule"), "mevcut içerik korunmalı")
        XCTAssertTrue(out.contains("LoadModule ssl_module lib/mod_ssl.so"))
        XCTAssertFalse(out.contains("#LoadModule ssl_module"))
    }

    func testFileHelperCopy_PreservesTargetOnOverwrite() throws {
        let src = tempFile("src"), dst = tempFile("dst")
        defer { FileHelper.remove(src); FileHelper.remove(dst) }
        FileHelper.write("yeni", to: src)
        FileHelper.write("eski", to: dst)
        XCTAssertTrue(FileHelper.copy(from: src, to: dst))
        XCTAssertEqual(FileHelper.readString(dst), "yeni")
    }

    // MARK: - FileHelper.move (domain rename'in bel kemiği: site/process dizini taşıma)

    func testFileHelperMove_DirectoryWithContents() {
        let base = NSTemporaryDirectory() + "hy-move-\(UUID().uuidString)"
        let oldDir = "\(base)/eski", newDir = "\(base)/yeni"
        defer { FileHelper.remove(base) }
        FileHelper.createDirectory(oldDir)
        FileHelper.write("PID 4242", to: "\(oldDir)/app.pid")
        FileHelper.write("log satırı", to: "\(oldDir)/app.log")
        FileHelper.createDirectory("\(oldDir)/sub")
        FileHelper.write("iç", to: "\(oldDir)/sub/nested.txt")

        XCTAssertTrue(FileHelper.move(from: oldDir, to: newDir), "dizin taşınmalı")
        XCTAssertFalse(FileHelper.exists(oldDir), "eski dizin kalmamalı")
        // İçerik (alt dizin dahil) korunmalı
        XCTAssertEqual(FileHelper.readString("\(newDir)/app.pid"), "PID 4242")
        XCTAssertEqual(FileHelper.readString("\(newDir)/sub/nested.txt"), "iç")
    }

    // MARK: - Yerelleştirme (i18n)

    func testAppLanguage_EffectiveCode() {
        XCTAssertEqual(AppLanguage.tr.effectiveCode, "tr")
        XCTAssertEqual(AppLanguage.en.effectiveCode, "en")
        // .system: sistem TR ise "tr", değilse "en" (fallback) — ikisinden biri olmalı
        XCTAssertTrue(["tr", "en"].contains(AppLanguage.system.effectiveCode))
    }

    func testL10n_CatalogHasBothLanguagesForKeys() {
        // Her katalog anahtarı hem tr hem en içermeli (yarım çeviri olmasın)
        for (key, entry) in L10n.catalog {
            XCTAssertNotNil(entry["tr"], "eksik TR: \(key)")
            XCTAssertNotNil(entry["en"], "eksik EN: \(key)")
        }
    }

    func testLocalizer_Translation() async {
        let loc = Localizer.shared
        loc.setLanguage(.tr)
        XCTAssertEqual(loc.t("tab.domains"), "Alan Adları")
        loc.setLanguage(.en)
        XCTAssertEqual(loc.t("tab.domains"), "Domains")
        // Bilinmeyen anahtar çökmemeli (DEBUG'da ⟨key⟩, aksi halde key döner)
        XCTAssertFalse(loc.t("bilinmeyen.anahtar.xyz").isEmpty)
        loc.setLanguage(.system)   // testten sonra varsayılana dön
    }

    func testFileHelperMove_FailsWhenTargetExists() {
        // rename akışı hedefi ÖNCE remove eder; move'un hedef varken sessizce
        // üzerine yazmaması beklenir (aksi halde veri kaybı gizlenir).
        let base = NSTemporaryDirectory() + "hy-move2-\(UUID().uuidString)"
        let a = "\(base)/a", b = "\(base)/b"
        // Test barındırıcısı BRAMPP.app'in KENDİSİ olduğundan FileHelper.errorLogger hâlâ
        // canlı konsola bağlıdır: bu testin BEKLENEN başarısızlığı, kullanıcının açık
        // uygulamasında gerçek bir hata gibi "Taşınamadı: …/hy-move2-…" satırı olarak
        // görünüyordu. Beklenen hata konsolu kirletmesin.
        let savedLogger = FileHelper.errorLogger
        FileHelper.errorLogger = nil
        defer { FileHelper.errorLogger = savedLogger; FileHelper.remove(base) }
        FileHelper.createDirectory(a); FileHelper.write("A", to: "\(a)/f")
        FileHelper.createDirectory(b); FileHelper.write("B", to: "\(b)/f")
        // Hedef zaten var → move başarısız olmalı, kaynak yerinde kalmalı
        XCTAssertFalse(FileHelper.move(from: a, to: b))
        XCTAssertTrue(FileHelper.exists(a), "başarısız move'da kaynak korunmalı")
        XCTAssertEqual(FileHelper.readString("\(b)/f"), "B", "hedef değişmemeli")
    }

    // MARK: - Shell.streamBash zaman aşımı / asılı kalmama

    /// Hiç bitmeyen bir komut (kullanıcı build komutuna `npm run dev` yazarsa) timeout ile
    /// durdurulmalı; eskiden waitUntilExit süresiz bloklayıp çağıran task'ı asardı.
    func testStreamBash_TimeoutTerminatesHangingCommand() async {
        let start = Date()
        let r = await Shell.streamBash("sleep 30", timeout: 2) { _ in }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 15, "timeout uygulanmadı — çağrı asılı kaldı")
        XCTAssertEqual(r.exitCode, -998, "zaman aşımı exit kodu bekleniyordu")
        XCTAssertTrue(r.isTimeout, "Result.isTimeout true olmalı")
        XCTAssertFalse(r.isSuccess)
    }

    /// bash ÇIKSA bile arka planda kalan bir alt süreç stdout'u açık tutabilir; o durumda
    /// pipe'lar EOF vermez. Sınırsız group.wait() burada sonsuza kadar beklerdi.
    func testStreamBash_BackgroundChildHoldingStdoutDoesNotHang() async {
        let start = Date()
        // Alt kabuk arka planda uyur ve stdout'u miras alır → bash bitse de EOF gelmez
        _ = await Shell.streamBash("(sleep 30 &) ; echo bitti", timeout: 20) { _ in }
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 15, "EOF gelmeyince sınırsız beklendi — çağrı asılı kaldı")
    }

    /// Normal (hızlı biten) komutlar timeout eklendikten sonra da aynen çalışmalı.
    func testStreamBash_NormalCommandStillWorks() async {
        var lines: [String] = []
        let r = await Shell.streamBash("echo merhaba", timeout: 30) { lines.append($0) }
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertTrue(r.output.contains("merhaba"), "çıktı: \(r.output)")
    }

    // MARK: - VHostTemplates.parseBodySize (taşma çökmesi)

    /// Serbest metin alan; büyük değer eskiden çarpımda taşıp uygulamayı ÇÖKERTİYORDU.
    func testParseBodySize_HugeValueDoesNotTrap() {
        let maxBytes = 2_147_483_647
        XCTAssertEqual(VHostTemplates.parseBodySize("9000000000g"), maxBytes)
        XCTAssertEqual(VHostTemplates.parseBodySize("99999999999999m"), maxBytes)
        XCTAssertEqual(VHostTemplates.parseBodySize("\(Int.max)k"), maxBytes)
    }

    func testParseBodySize_NormalUnits() {
        XCTAssertEqual(VHostTemplates.parseBodySize("10m"), 10 * 1_048_576)
        XCTAssertEqual(VHostTemplates.parseBodySize("1g"),  1_073_741_824)
        XCTAssertEqual(VHostTemplates.parseBodySize("512k"), 512 * 1_024)
        XCTAssertEqual(VHostTemplates.parseBodySize("2048"), 2048)
        XCTAssertEqual(VHostTemplates.parseBodySize("  10M  "), 10 * 1_048_576, "trim + büyük harf")
    }

    // MARK: - FileHelper kodlama koruması

    /// İkili dosya "okundu" sayılıp UTF-8 olarak geri yazılırsa KALICI bozulur.
    /// Latin-1 tüm baytları eşlediğinden bu koruma eskiden hiç çalışmıyordu.
    func testReadStringDetailed_BinaryIsUnreadable() {
        let path = NSTemporaryDirectory() + "hy_bin_\(UUID().uuidString)"
        let binary = Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0x00])
        XCTAssertTrue(FileHelper.write(binary, to: path))
        defer { FileHelper.remove(path) }

        if case .unreadable = FileHelper.readStringDetailed(path) {
            // beklenen
        } else {
            XCTFail("NUL içeren ikili dosya .unreadable dönmeliydi")
        }
        XCTAssertNil(FileHelper.readString(path))
    }

    /// Latin-1 bir config düzenlendiğinde UTF-8'e çevrilmemeli (baytlar değişir).
    func testAppendLineIfMissing_PreservesLatin1Encoding() {
        let path = NSTemporaryDirectory() + "hy_l1_\(UUID().uuidString)"
        // "Görünüm" Latin-1'de tek baytlı; UTF-8'de çok baytlı olurdu
        let original = "# Ayarlar: Görünüm\nListen 80\n"
        guard let l1 = original.data(using: .isoLatin1) else { return XCTFail("Latin-1 kodlanamadı") }
        XCTAssertTrue(FileHelper.write(l1, to: path))
        defer { FileHelper.remove(path) }

        // Latin-1 olarak algılanmalı
        guard case .ok(_, let enc) = FileHelper.readStringDetailed(path) else {
            return XCTFail("okunamadı")
        }
        XCTAssertEqual(enc, .isoLatin1)

        XCTAssertTrue(FileHelper.appendLineIfMissing("Listen 8080", to: path))

        // Dosya HÂLÂ Latin-1 olmalı (UTF-8 olarak çözülememeli) ve içerik korunmalı
        let after = FileHelper.readData(path)!
        XCTAssertNil(String(data: after, encoding: .utf8), "dosya UTF-8'e çevrilmiş — baytlar bozuldu")
        let text = String(data: after, encoding: .isoLatin1)!
        XCTAssertTrue(text.contains("Görünüm"), "özgün Türkçe karakterler korunmalı")
        XCTAssertTrue(text.contains("Listen 8080"), "yeni satır eklenmeli")
    }

    func testParseBodySize_InvalidFallsBackToDefault() {
        XCTAssertEqual(VHostTemplates.parseBodySize("abc"), 10_485_760)
        XCTAssertEqual(VHostTemplates.parseBodySize(""), 10_485_760)
        XCTAssertEqual(VHostTemplates.parseBodySize("-5m"), 10_485_760, "negatif kabul edilmemeli")
    }

    // MARK: - MCPToolsSkill

    /// Uygulamanın gömdüğü beceri metni ile depodaki SKILL.md ayrışmamalı: kurulan beceri
    /// (ve Codex AGENTS.md bölümü) bu sabitten yazılır, depodaki dosya ise geliştiricinin
    /// gördüğü kaynaktır. Biri güncellenip diğeri unutulursa bu test kırılır.
    func testMCPToolsSkill_MatchesRepositorySkillFile() throws {
        // #filePath: <depo>/macos/BRAMPPTests/BRAMPPTests.swift → iki üst klasör depo kökü
        let testDir  = (#filePath as NSString).deletingLastPathComponent      // …/BRAMPPTests
        let repoRoot = ((testDir as NSString).deletingLastPathComponent       // …/macos
                        as NSString).deletingLastPathComponent                // depo kökü
        let path = repoRoot + "/.claude/skills/\(MCPToolsSkill.name)/SKILL.md"

        // CI'da yalnızca derlenmiş ürün olabilir; kaynak ağacı yoksa testi atla.
        guard let fileText = FileHelper.readString(path) else {
            throw XCTSkip("Depodaki beceri dosyası okunamadı: \(path)")
        }
        // Karşılaştırma ŞABLON üzerinden yapılır: depo dosyası da `{{PORT}}` yer tutucusunu
        // taşıyorsa doğrudan; hâlâ somut varsayılan portu içeriyorsa ikame edilmiş metinle
        // (böylece iki dosya ancak yer tutucu dışında bir fark varsa kırılır).
        let expected = fileText.contains(MCPToolsSkill.portPlaceholder)
            ? MCPToolsSkill.markdown
            : MCPToolsSkill.rendered(port: MCPToolsSkill.defaultPort)
        XCTAssertEqual(expected, fileText,
                       "MCPToolsSkill.markdown ile \(path) ayrışmış")
    }

    /// Veritabanı becerisi için aynı senkron güvencesi — metin Swift'te, kopya depoda.
    func testMySQLSkill_MatchesRepositorySkillFile() throws {
        let testDir  = (#filePath as NSString).deletingLastPathComponent
        let repoRoot = ((testDir as NSString).deletingLastPathComponent
                        as NSString).deletingLastPathComponent
        let path = repoRoot + "/.claude/skills/\(BramppMySQLSkill.name)/SKILL.md"

        guard let fileText = FileHelper.readString(path) else {
            throw XCTSkip("Depodaki beceri dosyası okunamadı: \(path)")
        }
        let expected = fileText.contains(BramppMySQLSkill.portPlaceholder)
            ? BramppMySQLSkill.markdown
            : BramppMySQLSkill.rendered(port: BramppMySQLSkill.defaultPort)
        XCTAssertEqual(expected, fileText,
                       "BramppMySQLSkill.markdown ile \(path) ayrışmış")
    }

    /// Veritabanı becerisi de portu sabit yazmamalı.
    func testMySQLSkill_PortPlaceholderIsSubstituted() {
        XCTAssertTrue(BramppMySQLSkill.markdown.contains(BramppMySQLSkill.portPlaceholder),
                      "şablonda {{PORT}} yer tutucusu olmalı")
        let rendered = BramppMySQLSkill.rendered(port: 9123)
        XCTAssertFalse(rendered.contains(BramppMySQLSkill.portPlaceholder))
        XCTAssertTrue(rendered.contains("http://127.0.0.1:9123/mcp"))
    }

    /// İki beceri AYRI klasörlere kurulmalı — aynı yola yazılırsa biri diğerini ezer.
    /// Her katalog anahtarının iki dilinde de AYNI biçim belirteçleri olmalı.
    ///
    /// `String(format:)` fazla argümanı sessizce yutar, eksik argümanda çöp gösterir.
    /// TR metninde `%@` olup EN metninde olmaması bu yüzden hata vermez — yalnızca
    /// yanlış metin üretir ve fark edilmez. Belirteçler kümesi eşitlenerek yakalanır.
    func testCatalog_FormatSpecifiersMatchAcrossLanguages() {
        let pattern = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?[@dfs]")
        func specs(_ s: String) -> [String] {
            let r = NSRange(s.startIndex..., in: s)
            return pattern.matches(in: s, range: r)
                .compactMap { Range($0.range, in: s).map { String(s[$0]) } }
                .sorted()
        }
        for (key, langs) in L10n.catalog where langs.count > 1 {
            let byLang = langs.mapValues(specs)
            let reference = byLang.first!.value
            for (lang, found) in byLang {
                XCTAssertEqual(found, reference,
                               "\(key): \(lang) belirteçleri diğer dillerle uyuşmuyor — \(byLang)")
            }
        }
    }

    /// Uyarı metinleri Swift içinde SABİT yazılmamalı.
    ///
    /// DomainManager'daki sekiz uyarı sabit Türkçeydi; İngilizce arayüzde de Türkçe
    /// görünüyorlardı. Anahtarların varlığı ve iki dilde dolu olması burada güvenceye alınır.
    func testDomainAlerts_AreLocalizedInBothLanguages() {
        let keys = ["dom.alert.invalidName.title", "dom.alert.invalidName.msg",
                    "dom.alert.reservedName.title", "dom.alert.reservedName.msg",
                    "dom.alert.duplicateName.title", "dom.alert.duplicateName.msg",
                    "dom.alert.dotnetMissing.title", "dom.alert.dotnetMissing.msg",
                    "dom.health.ok.title", "dom.health.ok.msg",
                    "dom.health.unreachable.title", "dom.health.unreachable.msg",
                    "dom.health.backendDown.title", "dom.health.backendDown.msg",
                    "dom.health.unexpected.title", "dom.health.unexpected.msg"]
        for key in keys {
            guard let entry = L10n.catalog[key] else {
                XCTFail("\(key) katalogda yok"); continue
            }
            for lang in ["tr", "en"] {
                let text = entry[lang] ?? ""
                XCTAssertFalse(text.isEmpty, "\(key) için \(lang) çevirisi boş")
            }
            // "TR ile EN aynı olmamalı" diye bir kural YOK: "⚠️ %1$@ — HTTP %2$@" gibi
            // yalnızca yer tutucu ve protokol adı içeren başlıklar iki dilde de aynıdır.
            // Gerçek invariantlar burada anahtarın varlığı ve dolu olması; biçim
            // belirteçlerinin tutarlılığını testCatalog_FormatSpecifiers… güvenceye alır.
        }
    }

    /// Örneklerde `.test` önerilmeli, `.local` DEĞİL.
    ///
    /// `.local` mDNS'e ayrılmıştır (RFC 6762) ve macOS'ta çözümleme gecikmesi yaratır.
    /// Yerel HTTPS rehberimiz bunu zaten anlatıyordu, ama uygulama ve beceri metinleri
    /// hâlâ `.local` dağıtıyordu — kendi tavsiyemizle çelişen bu durum böyle yakalanır.
    /// Doğrulama TLD'den bağımsızdır; değişen yalnızca ÖNERİ, mevcut alan adları çalışır.
    func testExamples_RecommendTestTLD_NotLocal() {
        let example = L10n.catalog["dom.example"]
        XCTAssertNotNil(example, "dom.example anahtarı olmalı")
        for (lang, text) in example ?? [:] {
            XCTAssertTrue(text.contains(".test"), "\(lang): örnek .test önermeli — \(text)")
            XCTAssertFalse(text.contains(".local"), "\(lang): örnek .local önermemeli — \(text)")
        }

        for (name, markdown) in [("mcptools", MCPToolsSkill.markdown),
                                 ("brampp_mysql", BramppMySQLSkill.markdown)] {
            XCTAssertFalse(markdown.contains(".local"),
                           "\(name) becerisi örnek alan adı olarak .local vermemeli")
            XCTAssertTrue(markdown.contains(".test"), "\(name) becerisi .test örneği içermeli")
        }
    }


    // MARK: - Tünel (Cloudflare Quick Tunnel)

    /// cloudflared adresi bir kutu çiziminin İÇİNDE, satır ortasında yazar.
    /// Satır başı/sonu araması yapılsaydı adres hiç bulunmazdı.
    func testTunnel_ParsesURLFromRealLogOutput() {
        let log = """
        2026-08-09T10:00:00Z INF Thank you for trying Cloudflare Tunnel.
        2026-08-09T10:00:02Z INF +--------------------------------------------------------+
        2026-08-09T10:00:02Z INF |  Your quick Tunnel has been created! Visit it at:       |
        2026-08-09T10:00:02Z INF |  https://calm-river-fox-42.trycloudflare.com            |
        2026-08-09T10:00:02Z INF +--------------------------------------------------------+
        """
        XCTAssertEqual(TunnelManager.parsePublicURL(from: log),
                       "https://calm-river-fox-42.trycloudflare.com")
    }

    func testTunnel_NoURLYetReturnsNil() {
        let log = "2026-08-09T10:00:00Z INF Requesting new quick Tunnel on trycloudflare.com..."
        XCTAssertNil(TunnelManager.parsePublicURL(from: log),
                     "adres henüz yokken nil dönmeli — aksi halde ölü bağlantı gösterilir")
    }

    /// SSL AÇIK: HTTPS hedeflenmeli ve `--no-tls-verify` bulunmalı.
    ///
    /// HTTP hedeflenirse BRAMPP'ın koyduğu HTTP→HTTPS yönlendirmesi ziyaretçiyi
    /// internette çözülmeyen `https://<ad>` adresine atar ve sayfa hiç açılmaz.
    func testTunnel_CommandForSSLDomain() {
        let d = Domain(name: "shop.test", platform: .php, sslEnabled: true, webServer: .apache)
        let cmd = TunnelManager.buildCommand(for: d, cloudflaredPath: "/opt/homebrew/bin/cloudflared")

        XCTAssertTrue(cmd.contains("https://shop.test"), "SSL açıkken HTTPS hedeflenmeli: \(cmd)")
        XCTAssertTrue(cmd.contains("--no-tls-verify"), "mkcert sertifikası için gerekli")
        XCTAssertTrue(cmd.contains("--http-host-header"),
                      "isim tabanlı vhost'un eşleşmesi bu bayrağa bağlı")
        XCTAssertTrue(cmd.contains("shop.test"), "Host başlığı alan adı olmalı")
        XCTAssertFalse(cmd.contains("127.0.0.1:8"), "hedef IP değil alan adı olmalı")
    }

    /// SSL KAPALI: HTTP hedeflenir ve TLS doğrulaması atlanmaz — atlanacak TLS yok.
    func testTunnel_CommandForPlainDomain() {
        let d = Domain(name: "demo.test", platform: .php, sslEnabled: false, webServer: .apache)
        let cmd = TunnelManager.buildCommand(for: d, cloudflaredPath: "/opt/homebrew/bin/cloudflared")

        XCTAssertTrue(cmd.contains("http://demo.test"))
        XCTAssertFalse(cmd.contains("https://demo.test"))
        XCTAssertFalse(cmd.contains("--no-tls-verify"),
                       "TLS yokken doğrulama atlama bayrağı anlamsız")
        XCTAssertTrue(cmd.contains("--http-host-header"))
    }

    // MARK: - Konsol log dosyası

    /// `.progress` YAZILMAZ: brew'un ilerleme çubuğu saniyede onlarca satır üretir,
    /// bilgi taşımaz ve dosyayı kullanılamaz hâle getirir.
    func testConsoleLogFile_SkipsProgressLines() {
        XCTAssertFalse(ConsoleLogFile.shouldPersist(.progress))
        for type in [ConsoleEntryType.info, .success, .warning, .error, .command] {
            XCTAssertTrue(ConsoleLogFile.shouldPersist(type), "\(type) yazılmalı")
        }
    }

    /// Çok satırlı çıktıda HER fiziksel satır kendi zaman damgasını almalı;
    /// aksi halde tarihe göre süzme ilk satırdan sonrasını kaçırır.
    func testConsoleLogFile_StampsEveryPhysicalLine() {
        let out = ConsoleLogFile.format(date: Date(), level: "ERROR", text: "bir\niki\nüç")
        let lines = out.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        for line in lines {
            XCTAssertTrue(line.contains("[ERROR]"), "her satır düzey etiketi taşımalı: \(line)")
        }
        XCTAssertTrue(out.hasSuffix("\n"), "dosyaya eklemede satır sonu korunmalı")
    }

    /// Silinecek dosyalar ADINDAN çözülür, mtime'dan değil: yedekten dönen bir
    /// dosyanın değiştirilme tarihi bugünü gösterebilir.
    func testConsoleLogFile_PrunesByNameNotModificationTime() {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let now = Date()
        func name(_ daysAgo: Int) -> String {
            let d = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
            return "console-\(fmt.string(from: d)).log"
        }
        let files = [name(0), name(3), name(7), name(20), "not-a-log.txt", "console-bozuk.log"]
        let removed = ConsoleLogFile.pruneOldFiles(now: now, fileNames: files)

        XCTAssertTrue(removed.contains(name(20)), "20 günlük dosya silinmeli")
        XCTAssertFalse(removed.contains(name(0)), "bugünün dosyası durmalı")
        XCTAssertFalse(removed.contains(name(3)), "3 günlük dosya durmalı")
        XCTAssertFalse(removed.contains("not-a-log.txt"), "ilgisiz dosyaya dokunulmamalı")
        XCTAssertFalse(removed.contains("console-bozuk.log"), "tarihi çözülemeyen dosya silinmemeli")
    }

    // MARK: - read_log süzgeçleri

    func testReadLogFilter_LevelWarningIncludesErrors() {
        // "Sorunları göster" diyen kullanıcı hatayı dışarıda bırakmak istemez.
        XCTAssertTrue(MCPServer.logLineMatches(level: "warning", search: nil,
                                               entryLabel: "ERROR", text: "patladı"))
        XCTAssertTrue(MCPServer.logLineMatches(level: "warning", search: nil,
                                               entryLabel: "WARN", text: "dikkat"))
        XCTAssertFalse(MCPServer.logLineMatches(level: "warning", search: nil,
                                                entryLabel: "INFO", text: "olağan"))
    }

    func testReadLogFilter_ErrorIsStrictAndSearchIsCaseInsensitive() {
        XCTAssertFalse(MCPServer.logLineMatches(level: "error", search: nil,
                                                entryLabel: "WARN", text: "uyarı"))
        XCTAssertTrue(MCPServer.logLineMatches(level: "all", search: "NGINX",
                                               entryLabel: "INFO", text: "nginx başlatıldı"))
        XCTAssertFalse(MCPServer.logLineMatches(level: "all", search: "apache",
                                                entryLabel: "INFO", text: "nginx başlatıldı"))
    }

    func testReadLogFilter_ParsesFileLine() {
        let p = MCPServer.parseFileLogLine("2026-08-09 14:03:11 [ERROR] mariadb başlatılamadı")
        XCTAssertEqual(p?.date, "2026-08-09 14:03:11")
        XCTAssertEqual(p?.label, "ERROR")
        XCTAssertEqual(p?.text, "mariadb başlatılamadı")
        XCTAssertNil(MCPServer.parseFileLogLine("düz metin, biçime uymuyor"))
    }

    /// Paylaşım araçları YAZMA izni ister ve varsayılan Erişim yok'tur —
    /// ajanın makineyi kendiliğinden internete açamaması buna bağlı.
    func testSharingScope_DefaultsToNoAccess() {
        let fresh = AppSettings()
        XCTAssertEqual(MCPScope.sharing.permission(in: fresh), .none,
                       "paylaşım varsayılan olarak KAPALI olmalı")
        XCTAssertNotEqual(MCPScope.domains.permission(in: fresh), .none,
                          "diğer alanların varsayılanı değişmemeli")
    }

    func testSkills_HaveDistinctInstallPaths() {
        XCTAssertNotEqual(ClaudeIntegration.skillPath, ClaudeIntegration.mysqlSkillPath)
        XCTAssertNotEqual(ClaudeIntegration.skillDirectory, ClaudeIntegration.mysqlSkillDirectory)
        XCTAssertTrue(ClaudeIntegration.mysqlSkillPath.hasSuffix("/brampp_mysql/SKILL.md"))
    }

    /// Beceri metni portu SABİT yazarsa, portunu değiştiren kullanıcının ajanına yanlış
    /// uç nokta anlatılır. Şablonda yer tutucu olmalı, yazılan metinde kalmamalı.
    func testMCPToolsSkill_PortPlaceholderIsSubstituted() {
        XCTAssertTrue(MCPToolsSkill.markdown.contains(MCPToolsSkill.portPlaceholder),
                      "şablonda {{PORT}} yer tutucusu olmalı")

        let rendered = MCPToolsSkill.rendered(port: 9123)
        XCTAssertFalse(rendered.contains(MCPToolsSkill.portPlaceholder),
                       "yazılan metinde yer tutucu kalmamalı")
        XCTAssertTrue(rendered.contains("http://127.0.0.1:9123/mcp"),
                      "uç nokta gerçek portu göstermeli")
        XCTAssertFalse(rendered.contains("http://127.0.0.1:8765/mcp"),
                       "sabit port kalmamalı")
    }

    // MARK: - ClaudeIntegration: Codex TOML

    /// Yalnızca `[` önekine bakmak, çok satırlı bir TOML dizisinin ("[\"A\",\"1\"]," gibi)
    /// satırlarını tablo başlığı sanıyordu.
    func testIsTableHeader_RejectsArrayRows() {
        XCTAssertTrue(ClaudeIntegration.isTableHeader("[mcp_servers.brampp]"))
        XCTAssertTrue(ClaudeIntegration.isTableHeader("  [tool.x]   # yorum"))
        XCTAssertTrue(ClaudeIntegration.isTableHeader("[[array.of.tables]]"))

        XCTAssertFalse(ClaudeIntegration.isTableHeader("[\"A\",\"1\"],"), "dizi satırı başlık değil")
        XCTAssertFalse(ClaudeIntegration.isTableHeader("[1, 2, 3]"), "virgül içeren dizi başlık değil")
        XCTAssertFalse(ClaudeIntegration.isTableHeader("env_matrix = ["))
        XCTAssertFalse(ClaudeIntegration.isTableHeader("]"))
        XCTAssertFalse(ClaudeIntegration.isTableHeader("["))
        XCTAssertFalse(ClaudeIntegration.isTableHeader("[eksik.kapanis"))
    }

    /// Silme taraması dizi satırında erken durursa BRAMPP tablosunun kalıntısı dosyada
    /// kalır ve sonraki tabloların içine karışır.
    func testApplyCodexBlock_RemovalSkipsMultilineArray() {
        let toml = """
        [mcp_servers.brampp]
        url = "http://127.0.0.1:8765/mcp"
        env_matrix = [
        ["A","1"],
        ["B","2"],
        ]

        [mcp_servers.other]
        command = "x"

        """
        let out = ClaudeIntegration.applyCodexBlock(nil, to: toml)
        XCTAssertFalse(out.contains("mcp_servers.brampp"), "tablo silinmeli")
        XCTAssertFalse(out.contains("env_matrix"), "tabloya ait dizi de silinmeli")
        XCTAssertFalse(out.contains("[\"B\",\"2\"]"), "dizi satırları artık kalmamalı")
        XCTAssertTrue(out.contains("[mcp_servers.other]"), "başka sunucu korunmalı")
        XCTAssertTrue(out.contains("command = \"x\""))
    }

    /// BOM'lu dosyada başlık tanınmazsa ikinci bir `[mcp_servers.brampp]` eklenir ve
    /// TOML geçersiz olur.
    func testApplyCodexBlock_BOMDoesNotDuplicateTable() {
        XCTAssertTrue(ClaudeIntegration.isCodexTableHeader("\u{FEFF}[mcp_servers.brampp]"))
        XCTAssertTrue(ClaudeIntegration.isTableHeader("\u{FEFF}[tool.x]"))

        let toml = "\u{FEFF}[mcp_servers.brampp]\nurl = \"http://127.0.0.1:1111/mcp\"\n"
        let block = "[mcp_servers.brampp]\nurl = \"http://127.0.0.1:8765/mcp\"\n"
        let out = ClaudeIntegration.applyCodexBlock(block, to: toml)

        let count = out.components(separatedBy: "[mcp_servers.brampp]").count - 1
        XCTAssertEqual(count, 1, "tablo iki kez yazılmamalı")
        XCTAssertTrue(out.contains("8765"), "yeni port yazılmalı")
        XCTAssertFalse(out.contains("1111"), "eski tablo değiştirilmeli")
    }

    // MARK: - ClaudeIntegration: AGENTS.md işaretçileri

    /// START var END yok: kaldırma yapılırsa dosyanın geri kalanı (kullanıcının kendi
    /// talimatları) silinirdi. Bu durum "bozuk" sayılmalı ve metne DOKUNULMAMALI.
    func testAgentsBlockState_UnterminatedMarkerIsBroken() {
        let text = "# Kendi notlarım\n" + ClaudeIntegration.agentsStart + "\nyarım blok\n"
        guard case .broken = ClaudeIntegration.agentsBlockState(in: text) else {
            return XCTFail("eşleşmeyen işaretçi .broken olmalıydı")
        }
        XCTAssertEqual(ClaudeIntegration.applyAgentsBlock(nil, to: text, at: .broken), text,
                       "bozuk işaretçide metin değiştirilmemeli")
    }

    /// Gerçek senaryo: yarım blok üstüne kurulum yapılınca 2 START + 1 END oluşur.
    /// İlk START ile tek END arasındaki KULLANICI içeriği silinmemeli.
    func testAgentsBlockState_TwoStartsOneEndIsBroken() {
        let text = ClaudeIntegration.agentsStart + "\nESKI-BLOK\n"
            + "KULLANICI-ICERIGI\n"
            + ClaudeIntegration.agentsStart + "\nYENI-BLOK\n" + ClaudeIntegration.agentsEnd + "\n"

        let state = ClaudeIntegration.agentsBlockState(in: text)
        guard case .broken = state else {
            return XCTFail("2 START + 1 END .broken olmalıydı")
        }
        let out = ClaudeIntegration.applyAgentsBlock(nil, to: text, at: state)
        XCTAssertTrue(out.contains("KULLANICI-ICERIGI"), "kullanıcı içeriği silinmemeli")
        XCTAssertEqual(out, text)
    }

    /// Birden çok TAM çift varsa yalnızca İLKİ hedeflenir; aradaki içerik korunur.
    func testApplyAgentsBlock_OnlyFirstCompletePairIsReplaced() {
        let s = ClaudeIntegration.agentsStart
        let e = ClaudeIntegration.agentsEnd
        let text = s + "\nBLOK-BIR\n" + e + "\nARADAKI-NOT\n" + s + "\nBLOK-IKI\n" + e + "\n"

        let state = ClaudeIntegration.agentsBlockState(in: text)
        guard case .valid = state else { return XCTFail("dönüşümlü çiftler geçerli olmalı") }

        let out = ClaudeIntegration.applyAgentsBlock(nil, to: text, at: state)
        XCTAssertFalse(out.contains("BLOK-BIR"), "ilk blok kaldırılmalı")
        XCTAssertTrue(out.contains("ARADAKI-NOT"), "aradaki kullanıcı notu korunmalı")
        XCTAssertTrue(out.contains("BLOK-IKI"), "ikinci çifte dokunulmamalı")
    }

    /// İşaretçi yokken kurulum blok ekler; kullanıcının mevcut içeriği başta kalır.
    func testApplyAgentsBlock_AppendsWhenNoMarkers() {
        let text  = "# Kendi talimatlarım\n"
        let block = ClaudeIntegration.agentsStart + "\nyeni\n" + ClaudeIntegration.agentsEnd

        let state = ClaudeIntegration.agentsBlockState(in: text)
        guard case .none = state else { return XCTFail("işaretçi yok, .none beklenirdi") }

        let out = ClaudeIntegration.applyAgentsBlock(block, to: text, at: state)
        XCTAssertTrue(out.hasPrefix("# Kendi talimatlarım\n"))
        XCTAssertTrue(out.contains(block))
        // Kaldırma isteğinde ise yapacak bir şey yok
        XCTAssertEqual(ClaudeIntegration.applyAgentsBlock(nil, to: text, at: state), text)
    }

    // MARK: - db_query salt-okunur filtresi

    /// Kara listedeki tehlikeli kelimeler, gizlendikleri yerden de yakalanmalı.
    func testDBQuery_ReadOnlyFilter_RejectsWrites() {
        let cases = [
            "WITH d AS (DELETE FROM users RETURNING *) SELECT count(*) FROM d",
            "SELECT 1 INTO OUTFILE '/tmp/x'",
            "SELECT 1 INTO DUMPFILE '/tmp/x'",
            "SELECT 1 /*!50701 DELETE FROM users */",
            "   wItH d AS (dElEtE FROM x RETURNING *) SELECT 1",
            "SET autocommit = 0",
            "SELECT 1; DROP TABLE users",
        ]
        for sql in cases {
            let body = MCPServer.sqlScanBody(sql)
            XCTAssertNotNil(MCPServer.readOnlySQLViolation(body),
                            "reddedilmeliydi: \(sql)")
        }
    }

    /// Meşru okuma sorguları yanlış pozitif üretmemeli — özellikle tehlikeli
    /// kelimeyi DİZGE içinde ya da "CHARACTER SET" bağlamında taşıyanlar.
    func testDBQuery_ReadOnlyFilter_AllowsReads() {
        let cases = [
            "SELECT 1+1 AS toplam",
            "WITH t AS (SELECT 1 AS n) SELECT n FROM t",
            "SELECT 'delete me' AS note",
            "SELECT updated_at FROM t OFFSET 5",
            "SHOW CHARACTER SET",
            "SHOW CHARACTER SET LIKE 'utf8%'",
            "SELECT @@character_set_client",
            "SHOW DATABASES",
            "DESCRIBE users",
            "EXPLAIN SELECT 1",
        ]
        for sql in cases {
            let body = MCPServer.sqlScanBody(sql)
            XCTAssertNil(MCPServer.readOnlySQLViolation(body),
                         "geçmeliydi ama '\(MCPServer.readOnlySQLViolation(body) ?? "")' engelledi: \(sql)")
        }
    }

    // MARK: - Redis INFO ayrıştırma

    /// Gerçek `redis-cli INFO` çıktısından alınmış örnek (Redis 8.8).
    private var redisInfoSample: String {
        """
        # Server
        redis_version:8.8.0
        uptime_in_seconds:3725

        # Clients
        connected_clients:1

        # Memory
        used_memory_human:881.94K
        used_memory_peak_human:882.25K
        maxmemory_human:0B

        # Stats
        total_commands_processed:1420
        expired_keys:3
        evicted_keys:0
        keyspace_hits:75
        keyspace_misses:25

        # Keyspace
        db0:keys=2,expires=2,avg_ttl=0,subexpiry=0
        db3:keys=10,expires=0,avg_ttl=0
        """
    }

    func testRedisStats_ParsesRealInfoOutput() {
        let s = RedisStats.parse(redisInfoSample)
        XCTAssertEqual(s.version, "8.8.0")
        XCTAssertEqual(s.uptimeSeconds, 3725)
        XCTAssertEqual(s.connectedClients, 1)
        XCTAssertEqual(s.usedMemory, "881.94K")
        XCTAssertEqual(s.commandsProcessed, 1420)
        // Keyspace: db numarası, anahtar ve expires ayrı ayrı okunmalı
        XCTAssertEqual(s.keyspace.map(\.db), [0, 3])
        XCTAssertEqual(s.keyspace.map(\.keys), [2, 10])
        XCTAssertEqual(s.keyspace.map(\.expires), [2, 0])
        XCTAssertEqual(s.totalKeys, 12)
    }

    /// İsabet oranı hiç istek yokken "%0" değil, "veri yok" olmalı.
    func testRedisStats_HitRateIsNilWithoutTraffic() {
        let bos = RedisStats.parse("keyspace_hits:0\nkeyspace_misses:0")
        XCTAssertNil(bos.hitRate, "0/0 için oran hesaplanmamalı")

        let s = RedisStats.parse(redisInfoSample)
        XCTAssertEqual(s.hitRate ?? 0, 0.75, accuracy: 0.001)
    }

    /// Bölüm başlıkları, boş satırlar ve bilinmeyen alanlar ayrıştırmayı bozmamalı.
    func testRedisStats_IgnoresHeadersAndUnknownFields() {
        let s = RedisStats.parse("""
        # Server

        redis_version:7.0.0
        gelecekte_eklenen_alan:42
        bozuk_satir_iki_nokta_yok
        db1:keys=5,expires=1,avg_ttl=0
        """)
        XCTAssertEqual(s.version, "7.0.0")
        XCTAssertEqual(s.totalKeys, 5)
        XCTAssertNil(s.connectedClients)
    }

    /// maxmemory 0 → sınırsız. Geliştirme makinesinde olağan durum.
    func testRedisStats_UnlimitedMemory() {
        XCTAssertTrue(RedisStats.parse("maxmemory_human:0B").isMemoryUnlimited)
        XCTAssertFalse(RedisStats.parse("maxmemory_human:512.00M").isMemoryUnlimited)
    }

    func testRedisStats_FormatsUptime() {
        XCTAssertEqual(RedisStats.formatUptime(45), "45sn")
        XCTAssertEqual(RedisStats.formatUptime(600), "10dk")
        XCTAssertEqual(RedisStats.formatUptime(3725), "1s 2dk")
        XCTAssertEqual(RedisStats.formatUptime(90000), "1g 1s")
    }

    // MARK: - Sürüm karşılaştırma (UpdateChecker)

    /// Etiketten sürüm çıkarma: GitHub etiketleri "v1.1" biçiminde, release adı
    /// "BRAMPP 1.1" olabiliyor. İkisi de aynı sayıya inmeli.
    func testUpdateChecker_NormalizesTags() {
        XCTAssertEqual(UpdateChecker.normalize("v1.1"), "1.1")
        XCTAssertEqual(UpdateChecker.normalize("V2.0.3"), "2.0.3")
        XCTAssertEqual(UpdateChecker.normalize("BRAMPP 1.1"), "1.1")
        XCTAssertEqual(UpdateChecker.normalize("  v1.2  "), "1.2")
        XCTAssertEqual(UpdateChecker.normalize("release-3.4.5"), "3.4.5")
        XCTAssertEqual(UpdateChecker.normalize("sürüm yok"), "")
    }

    /// ASIL TUZAK: dizgi karşılaştırması "1.10" < "1.9" der. Sayısal olmalı.
    func testUpdateChecker_ComparesNumericallyNotLexically() {
        XCTAssertTrue(UpdateChecker.isNewer("1.10", than: "1.9"),
                      "1.10 > 1.9 olmalı — dizgi karşılaştırması burada yanılır")
        XCTAssertTrue(UpdateChecker.isNewer("2.0", than: "1.99"))
        XCTAssertTrue(UpdateChecker.isNewer("1.1.1", than: "1.1"))
        XCTAssertFalse(UpdateChecker.isNewer("1.9", than: "1.10"))
        XCTAssertFalse(UpdateChecker.isNewer("1.1", than: "1.1"))
        // Eksik bileşen 0 sayılır: "1.2" ile "1.2.0" eşit
        XCTAssertFalse(UpdateChecker.isNewer("1.2", than: "1.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.2.0", than: "1.2"))
    }

    /// Uçtan uca: yayındaki etiketle mevcut sürüm karşılaştırıldığında
    /// "güncelleme yok" çıkmalı (ikisi de aynı sürüm serisinden).
    func testUpdateChecker_SameVersionIsNotAnUpdate() {
        let tag = UpdateChecker.normalize("v1.1")
        XCTAssertFalse(UpdateChecker.isNewer(tag, than: UpdateChecker.normalize("1.1")))
        XCTAssertTrue(UpdateChecker.isNewer(UpdateChecker.normalize("v1.2"),
                                            than: UpdateChecker.normalize("1.1")))
    }

    // MARK: - Süreç canlılık denetimi

    /// PID dosyası süreç öldükten sonra da diskte kalır. `app_status` bunu doğrulamadan
    /// raporlayınca ölü bir wrapper PID'i "ayakta" gibi görünüyordu.
    func testProcessIsAlive_DistinguishesLiveAndDeadPIDs() {
        // Kendi sürecimiz kesinlikle yaşıyor
        XCTAssertTrue(NativeProcessManager.isAlive(Int(ProcessInfo.processInfo.processIdentifier)))
        // launchd (1) her zaman var — bize ait değil, EPERM yolunu da sınar
        XCTAssertTrue(NativeProcessManager.isAlive(1))
        // Geçersiz değerler
        XCTAssertFalse(NativeProcessManager.isAlive(0))
        XCTAssertFalse(NativeProcessManager.isAlive(-5))
        // Sistemdeki en büyük PID'in çok üstü — böyle bir süreç olamaz
        XCTAssertFalse(NativeProcessManager.isAlive(99_999_999))
    }

    // MARK: - db_export / db_import yol doğrulaması

    /// Yol kabuk komutuna gömüldüğünden sınırda REDDEDİLİR (kaçış değil).
    func testSQLPath_RejectsShellInjectionAndBadPaths() {
        let bad = [
            "yedek.sql",                              // göreli
            "/tmp/yedek.txt",                         // .sql değil
            "/tmp/`whoami`.sql",                      // komut ikamesi
            "/tmp/$(id).sql",                         // komut ikamesi
            "/tmp/a;rm -rf ~.sql",                    // komut ayracı
            "/tmp/a|tee /etc/passwd.sql",             // boru
            "/tmp/a&b.sql",                           // arka plan
            "/tmp/a>b.sql",                           // yönlendirme
            "/tmp/a\nb.sql",                          // satır sonu
            "/tmp/a\\b.sql",                          // ters bölü
        ]
        for p in bad {
            XCTAssertNotNil(MCPServer.sqlPathRejection(p), "reddedilmeliydi: \(p)")
        }
    }

    /// Meşru yollar geçmeli — tek tırnak DAHİL (Shell.quote onu doğru kaçırır).
    func testSQLPath_AcceptsLegitimatePaths() {
        let good = [
            "/Users/ad/yedekler/blog.sql",
            "/Users/ad/O'Brien/blog-20260729-0130.sql",   // apostrof meşru
            "/Users/ad/Library/Application Support/BRAMPP/backups/db.SQL",  // boşluk + büyük harf uzantı
            "~/yedek.sql",                                // tilde genişletilir
        ]
        for p in good {
            XCTAssertNil(MCPServer.sqlPathRejection(p),
                         "geçmeliydi ama '\(MCPServer.sqlPathRejection(p) ?? "")' reddetti: \(p)")
        }
    }

    // MARK: - Kurulum istemi tespiti

    /// brew'in onay istemi `\n` ile DEĞİL `\r` ile biter ve ANSI renk kodları taşır.
    /// Ölçülen ham çıktı:
    ///   `\e[34m==>\e[0m \e[1mDo you want to proceed with the installation? [y/n]\e[0m\r`
    /// flush() içindeki `\r` kırpması (progress barlar için doğru) accumBuf'ı boşaltıp
    /// istemi yok ediyordu → onPrompt tetiklenmiyor, 10 sn'lik otomatik 'y' hiç
    /// gönderilmiyor, kurulum penceresi sonsuza kadar asılı kalıyordu.
    func testPTYPrompt_DetectedWhenLineEndsWithCarriageReturn() async {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var v: String?
            func set(_ s: String) { lock.lock(); if v == nil { v = s }; lock.unlock() }
            var value: String? { lock.lock(); defer { lock.unlock() }; return v }
        }
        let box = Box()
        // Gerçek brew çıktısının birebir kopyası: önce normal satır, sonra \r ile biten istem
        let script = #"printf '\033[34m==>\033[0m \033[1mFetching dotnet@9\033[0m\n'; "#
                   + #"printf '\033[34m==>\033[0m \033[1mDo you want to proceed with the installation? [y/n]\033[0m\r'; sleep 1"#

        _ = await Shell.streamBashPTY(script, onLine: { _ in }, onProgress: nil,
                                      onPrompt: { box.set($0) })

        XCTAssertNotNil(box.value, "brew istemi tespit edilmedi — otomatik onay hiç çalışmaz")
        XCTAssertTrue(Shell.containsConfirmationPrompt(box.value ?? ""),
                      "tespit edilen metin istem değil: \(box.value ?? "-")")
    }

    /// Saf desen eşleştirici — ANSI kodlu ve `\r` ile biten gerçek metni tanımalı.
    func testConfirmationPromptPattern_RealBrewOutput() {
        let raw = "\u{1B}[34m==>\u{1B}[0m \u{1B}[1mDo you want to proceed with the installation? [y/n]\u{1B}[0m\r"
        XCTAssertTrue(Shell.containsConfirmationPrompt(raw))
        // Yanlış pozitif olmamalı
        XCTAssertFalse(Shell.containsConfirmationPrompt("==> Downloading https://ghcr.io/v2/homebrew/core"))
        XCTAssertFalse(Shell.containsConfirmationPrompt("Already downloaded: /Users/x/Library/Caches"))
    }

    // MARK: - Servis bağımlılık sırası

    /// ASP.NET Core uygulaması Kestrel portunda dinler ve dışarıya YALNIZCA ters vekil
    /// üzerinden açılır — bağlı web sunucusu bağımlılık listesinin İLK öğesi olmalı.
    func testDependencyOrder_DotnetIncludesBoundWebServer() {
        let apacheApp = Domain(name: "api.example.local", platform: .dotnet, webServer: .apache)
        XCTAssertEqual(DomainManager.dependencyOrder(for: apacheApp, apacheCompanionAvailable: true),
                       ["httpd"])

        let nginxApp = Domain(name: "api2.example.local", platform: .dotnet, webServer: .nginx)
        // Nginx domaini bare URL (80/443) için Apache companion vhost'una da bağlı
        XCTAssertEqual(DomainManager.dependencyOrder(for: nginxApp, apacheCompanionAvailable: true),
                       ["nginx", "httpd"])
        // Apache kurulu değilse companion eklenmemeli
        XCTAssertEqual(DomainManager.dependencyOrder(for: nginxApp, apacheCompanionAvailable: false),
                       ["nginx"])
    }

    /// Web sunucusu önce, kullanıcının seçtiği DB/önbellek servisleri sonra gelmeli.
    func testDependencyOrder_WebServerBeforeUserSelected() {
        var d = Domain(name: "shop.example.local", platform: .dotnet, webServer: .nginx)
        d.serviceDependencies = ["mariadb", "redis"]
        XCTAssertEqual(DomainManager.dependencyOrder(for: d, apacheCompanionAvailable: false),
                       ["nginx", "mariadb", "redis"])
    }

    /// Kullanıcı web sunucusunu bağımlılık olarak DA seçmişse iki kez başlatılmamalı.
    func testDependencyOrder_DeduplicatesWebServer() {
        var d = Domain(name: "dup.example.local", platform: .dotnet, webServer: .apache)
        d.serviceDependencies = ["httpd", "mariadb", "httpd"]
        XCTAssertEqual(DomainManager.dependencyOrder(for: d, apacheCompanionAvailable: true),
                       ["httpd", "mariadb"])
    }

    /// nginx master süreci başlığını yeniden yazdığından `pgrep -x nginx` asla eşleşmez;
    /// süreç kontrolü ada bakan yola düşmeli. httpd bu istisnaya girmemeli.
    func testProcessAliveCheck_NginxUsesNameScan() async {
        let nginxByExactName = await Shell.bashAsync("pgrep -x nginx > /dev/null 2>&1").isSuccess
        let nginxByHelper    = await Shell.isProcessAlive("nginx")
        // Gerçek ölçüt: port dinleniyorsa süreç ayaktadır
        if await Shell.isPortInUseAsync(8080) {
            XCTAssertTrue(nginxByHelper, "nginx :8080 dinliyor ama isProcessAlive bulamadı")
            XCTAssertFalse(nginxByExactName,
                           "pgrep -x nginx beklenmedik şekilde eşleşti — düzeltmenin gerekçesi değişmiş olabilir")
        }
        // httpd yolu değişmemeli
        let httpdByExactName = await Shell.bashAsync("pgrep -x httpd > /dev/null 2>&1").isSuccess
        let httpdByHelper    = await Shell.isProcessAlive("httpd")
        XCTAssertEqual(httpdByExactName, httpdByHelper, "httpd için davranış değişmemeliydi")
    }

    /// Bağımlılığı olmayan sade bir PHP domaini için bile web sunucusu denetlenmeli —
    /// eskiden serviceDependencies boşsa fonksiyon hemen dönüyor, hiçbir denetim yapmıyordu.
    func testDependencyOrder_EmptySelectionStillChecksWebServer() {
        let d = Domain(name: "plain.example.local", platform: .php, webServer: .apache)
        XCTAssertNil(d.serviceDependencies)
        XCTAssertEqual(DomainManager.dependencyOrder(for: d, apacheCompanionAvailable: true),
                       ["httpd"])
    }
}
