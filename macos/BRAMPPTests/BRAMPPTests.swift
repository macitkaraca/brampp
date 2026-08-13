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

    /// **KATALOGDA OLMAYAN LOG ANAHTARI HAM HÂLİYLE YAZILIR.**
    ///
    /// `L10n.logText` anahtarı bulamazsa anahtarın KENDİSİNİ döndürür; Debug'da bu göze
    /// çarpmaz çünkü konsola bakan biri olmayabilir, Release'de ise kullanıcı
    /// "log.svc.apachePortsRolledBack" satırını görür. Bu üçü tam olarak öyleydi:
    /// çağrılıyorlardı, hiçbir katalogda yoktular.
    func testLogCatalog_ServiceKeysReferencedByServiceManagerExist() {
        let keys = ["log.svc.quitStoppingDomains",
                    "log.svc.apacheVhostPortsUpdated",
                    "log.svc.apachePortsRolledBack"]
        for key in keys {
            guard let entry = L10n.logEntry(for: key) else {
                XCTFail("\(key) hiçbir log katalogunda yok — Release'de ham anahtar yazılır")
                continue
            }
            for lang in ["tr", "en"] {
                XCTAssertFalse((entry[lang] ?? "").isEmpty, "\(key) için \(lang) çevirisi boş")
            }
            // Anahtarın katalogda bulunması yetmez: çözüm gerçekten METİN döndürmeli.
            // (Release'de eksik anahtar `key`in kendisi, Debug'da `⟨key⟩` olarak döner.)
            let rendered = L10n.renderLog(key: key, args: ["3"])
            XCTAssertNotEqual(rendered, key)
            XCTAssertNotEqual(rendered, "⟨\(key)⟩")
        }
        // Argümanlı iki anahtar sayıyı gerçekten yerleştirmeli — `%@`si düşmüş bir
        // metin "Apache vhost portları güncellendi ( dosya)" üretirdi.
        for key in ["log.svc.quitStoppingDomains", "log.svc.apacheVhostPortsUpdated"] {
            for lang in ["tr", "en"] {
                XCTAssertTrue((L10n.logEntry(for: key)?[lang] ?? "").contains("%@"),
                              "\(key) (\(lang)) sayıyı yerleştirecek belirteci taşımalı")
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







    /// Yeni bir servis KATEGORİSİ eklendiğinde kurulu denetimi de eklenmezse servis
    /// hiçbir zaman "kurulu" görünemez. cloudflared tam olarak böyle kaybolmuştu:
    /// `.sharing` kategorisi `getInstalledVersion` içindeki `default: return nil`
    /// dalına düşüyordu. Bu test, kurulu denetimi olan kategorileri kayıt altına alır.
    func testServiceCatalog_RuntimeCategoriesHaveInstallDetection() {
        let runtimeCategories = Set(
            Service.defaultServices.filter { $0.type == .runtime }.map(\.category))
        // getInstalledVersion içinde açıkça ele alınan kategoriler
        let handled: Set<ServiceCategory> = [.nodejs, .python, .dotnet, .sharing]
        let missing = runtimeCategories.subtracting(handled)
        XCTAssertTrue(missing.isEmpty,
                      "bu kategorilerin kurulu denetimi yok, hep 'kurulu değil' görünürler: \(missing)")
    }

    /// Paylaşım servisi kataloğa gerçekten girmiş olmalı.
    func testServiceCatalog_ContainsCloudflaredAsRuntime() {
        guard let cf = Service.defaultServices.first(where: { $0.id == "cloudflared" }) else {
            return XCTFail("cloudflared katalogda yok")
        }
        XCTAssertEqual(cf.type, .runtime, "brew services onu yönetmez — daemon değil")
        XCTAssertEqual(cf.category, .sharing)
        XCTAssertEqual(cf.brewName, "cloudflared")
    }


    // MARK: - Proje eylemleri

    /// CLI kurulu OLMAYABİLİR ama editör duruyordur — bu makinede `code` komutu yok,
    /// Visual Studio Code.app var. Komuta bakan bir denetim editörü kaçırırdı.
    func testProjectActions_FindsEditorsByAppBundleNotCLI() {
        let kurulu = Set(["/Applications/Visual Studio Code.app", "/Applications/PhpStorm.app"])
        let found = ProjectActions.installedEditors { kurulu.contains($0) }
        XCTAssertEqual(found.map(\.name).sorted(), ["PhpStorm", "VS Code"])

        XCTAssertTrue(ProjectActions.installedEditors { _ in false }.isEmpty,
                      "hiçbiri kurulu değilse liste boş olmalı")
    }

    /// Tıklayınca hata veren menü ögesi, hiç olmamasından kötüdür.
    func testProjectActions_HidesTasksWithoutTheirFileOrTool() {
        // composer.json var ama composer kurulu değil
        XCTAssertTrue(ProjectActions.availableTasks(
            hasComposerJSON: true, packageJSON: nil,
            composerInstalled: false, npmInstalled: true).isEmpty)

        // composer kurulu ama projede composer.json yok
        XCTAssertTrue(ProjectActions.availableTasks(
            hasComposerJSON: false, packageJSON: nil,
            composerInstalled: true, npmInstalled: true).isEmpty)

        // ikisi de varsa görünür
        let t = ProjectActions.availableTasks(
            hasComposerJSON: true, packageJSON: nil,
            composerInstalled: true, npmInstalled: false)
        XCTAssertEqual(t, [.composerInstall, .composerUpdate])
    }

    /// `npm run dev` yalnızca package.json'da GERÇEKTEN dev script'i varsa gösterilmeli.
    func testProjectActions_OnlyOffersScriptsThatExist() {
        let pkg = """
        {"name":"x","scripts":{"build":"vite build","dev":"vite","lint":"eslint ."}}
        """
        let tasks = ProjectActions.availableTasks(
            hasComposerJSON: false, packageJSON: pkg,
            composerInstalled: false, npmInstalled: true)
        XCTAssertEqual(tasks.first, .npmInstall)
        XCTAssertTrue(tasks.contains(.npmScript("dev")))
        XCTAssertTrue(tasks.contains(.npmScript("build")))
        XCTAssertFalse(tasks.contains(.npmScript("serve")), "olmayan script önerilmemeli")

        // scripts bloğu olmayan package.json → yalnızca install
        let bare = ProjectActions.availableTasks(
            hasComposerJSON: false, packageJSON: "{\"name\":\"x\"}",
            composerInstalled: false, npmInstalled: true)
        XCTAssertEqual(bare, [.npmInstall])
    }

    /// Yaygın script'ler üste gelmeli — menüde "dev" aranırken dibe düşmesin.
    func testProjectActions_OrdersCommonScriptsFirst() {
        let pkg = """
        {"scripts":{"zebra":"x","build":"x","dev":"x","alpha":"x"}}
        """
        let s = ProjectActions.npmScripts(inPackageJSON: pkg)
        XCTAssertEqual(Array(s.prefix(2)), ["dev", "build"])
        XCTAssertEqual(Array(s.suffix(2)), ["alpha", "zebra"], "gerisi alfabetik")
    }

    /// Bozuk package.json çökertmemeli — kullanıcının dosyası her zaman geçerli değil.
    func testProjectActions_SurvivesMalformedPackageJSON() {
        XCTAssertTrue(ProjectActions.npmScripts(inPackageJSON: "{ bozuk").isEmpty)
        XCTAssertTrue(ProjectActions.npmScripts(inPackageJSON: "").isEmpty)
        XCTAssertTrue(ProjectActions.npmScripts(inPackageJSON: "[]").isEmpty)
    }

    // MARK: - Teşhis

    /// "Port kullanımda" demek yetmez — KİMİN kullandığı söylenmeli, çünkü kullanıcının
    /// atacağı adım buna bağlı (durdur / port değiştir).
    func testDiagnostics_NamesTheProcessHoldingThePort() {
        let f = Diagnostics.portConflict(port: 80, expectedProcess: "httpd",
                                         actualProcess: "nginx", actualPID: 4821)
        XCTAssertEqual(f.level, .fail)
        XCTAssertTrue(f.detail.contains("nginx"), "çakışan sürecin adı görünmeli")
        XCTAssertTrue(f.detail.contains("4821"), "PID görünmeli")
        XCTAssertNotNil(f.remedy, "sorunlu bulguda ne yapılacağı yazmalı")
    }

    /// `lsof` komut adını tam yolla verebilir; son bileşene bakılmazsa kendi
    /// sürecimizi yabancı sanardık.
    func testDiagnostics_MatchesOwnProcessByBasename() {
        let f = Diagnostics.portConflict(port: 8080, expectedProcess: "nginx",
                                         actualProcess: "/opt/homebrew/bin/nginx", actualPID: 12)
        XCTAssertEqual(f.level, .pass)
        XCTAssertNil(f.remedy)
    }

    func testDiagnostics_FreePortIsNotAProblem() {
        let f = Diagnostics.portConflict(port: 443, expectedProcess: "httpd",
                                         actualProcess: nil, actualPID: nil)
        XCTAssertEqual(f.level, .pass)
    }

    /// apachectl ve nginx başarıyı FARKLI yazar ve ikisi de uyarıyı stderr'e döker;
    /// yalnızca çıkış koduna bakmak yanıltıcı.
    func testDiagnostics_ReadsBothConfigSuccessPhrasings() {
        XCTAssertEqual(Diagnostics.configVerdict(server: "Apache",
                                                 output: "Syntax OK", exitOK: false).level, .pass)
        XCTAssertEqual(Diagnostics.configVerdict(server: "Nginx",
                                                 output: "configuration file ... syntax is ok",
                                                 exitOK: false).level, .pass)
    }

    /// Apache uyarıyı MODÜL ETİKETİYLE yazar ve "warning" sözcüğü hiç geçmez.
    /// Yalnızca "warning" arandığında gerçek uyarılar "sorun yok" diye raporlanıyordu —
    /// bu çıktı makinedeki gerçek `apachectl configtest` sonucundan alındı.
    func testDiagnostics_DetectsApacheModuleTaggedWarning() {
        let real = """
        [Mon Aug 10 01:24:16.530841 2026] [alias:warn] [pid 34128] AH00671: The Alias \
        directive in /opt/homebrew/etc/httpd/extra/phpmyadmin.conf at line 7 will \
        probably never match because it overlaps an earlier Alias.
        Syntax OK
        """
        let f = Diagnostics.configVerdict(server: "Apache", output: real, exitOK: true)
        XCTAssertEqual(f.level, .warn, "modül etiketli uyarı yakalanmalı")
        XCTAssertNotNil(f.remedy)
        XCTAssertTrue(f.remedy?.contains("AH00671") == true,
                      "zaman damgası ve PID atılıp mesaj gösterilmeli: \(f.remedy ?? "-")")
        XCTAssertFalse(f.remedy?.contains("pid 34128") == true, "PID gürültüsü atılmalı")
    }

    /// Nginx uyarıyı `nginx: [warn]` biçiminde yazar.
    func testDiagnostics_DetectsNginxBracketWarning() {
        let out = """
        nginx: [warn] conflicting server name "x.test" on 0.0.0.0:8080, ignored
        nginx: configuration file /opt/homebrew/etc/nginx/nginx.conf test is successful
        """
        XCTAssertEqual(Diagnostics.configVerdict(server: "Nginx", output: out, exitOK: true).level,
                       .warn)
    }

    /// Uyarı hata değildir: sunucu başlar ama kullanıcı bilmeli.
    func testDiagnostics_WarningIsNotFailure() {
        let warn = Diagnostics.configVerdict(
            server: "Apache",
            output: "Warning: DocumentRoot does not exist\nSyntax OK", exitOK: true)
        XCTAssertEqual(warn.level, .warn)
        XCTAssertNotNil(warn.remedy)

        let bad = Diagnostics.configVerdict(
            server: "Nginx",
            output: "nginx: [emerg] unknown directive \"servr\" in /x.conf:3", exitOK: false)
        XCTAssertEqual(bad.level, .fail)
    }

    /// Sorunlar üste gelmeli; aynı seviyedekiler özgün sırasını korumalı.
    func testDiagnostics_SortsProblemsFirstAndStably() {
        let input = [
            Diagnostics.Finding(id: "a", title: "A", level: .pass, detail: "", remedy: nil),
            Diagnostics.Finding(id: "b", title: "B", level: .fail, detail: "", remedy: nil),
            Diagnostics.Finding(id: "c", title: "C", level: .pass, detail: "", remedy: nil),
            Diagnostics.Finding(id: "d", title: "D", level: .warn, detail: "", remedy: nil),
        ]
        XCTAssertEqual(Diagnostics.sorted(input).map(\.id), ["b", "d", "a", "c"])
        XCTAssertEqual(Diagnostics.summary(input), .fail)
        XCTAssertEqual(Diagnostics.summary([input[0], input[2]]), .pass)
    }

    // MARK: - PHP Profilleyici

    /// Blok eklenip çıkarıldığında kullanıcının php.ini'si BOZULMAMALI.
    /// Bu dosya bozulursa o PHP sürümü hiç çalışmaz.
    func testProfiler_RoundTripLeavesUserContentIntact() {
        let original = """
        [PHP]
        memory_limit = 512M
        upload_max_filesize = 64M

        [xdebug]
        xdebug.client_host = localhost
        """
        let on = PHPProfiler.applying(to: original, alwaysOn: false)
        XCTAssertTrue(PHPProfiler.isEnabled(in: on))
        XCTAssertTrue(on.contains("memory_limit = 512M"), "kullanıcı ayarı korunmalı")
        XCTAssertTrue(on.contains("xdebug.client_host = localhost"),
                      "kullanıcının kendi xdebug ayarına dokunulmamalı")

        let off = PHPProfiler.removing(from: on)
        XCTAssertFalse(PHPProfiler.isEnabled(in: off))
        XCTAssertTrue(off.contains("memory_limit = 512M"))
        XCTAssertTrue(off.contains("xdebug.client_host = localhost"))
        XCTAssertFalse(off.contains("xdebug.output_dir"), "blok tamamen kalkmalı")
    }

    /// İki kez açmak bloğu ÇOĞALTMAMALI — yinelenen yönergeler php.ini'de
    /// öngörülemez davranışa yol açar.
    func testProfiler_EnablingTwiceDoesNotDuplicate() {
        let base = "[PHP]\nmemory_limit = 256M\n"
        let once = PHPProfiler.applying(to: base, alwaysOn: false)
        let twice = PHPProfiler.applying(to: once, alwaysOn: true)
        let marks = twice.components(separatedBy: PHPProfiler.beginMark).count - 1
        XCTAssertEqual(marks, 1, "blok bir kez bulunmalı")
        XCTAssertTrue(PHPProfiler.isAlwaysOn(in: twice), "ikinci çağrı kipi güncellemeli")
    }

    /// VARSAYILAN tetikleyici kipi olmalı: `start_with_request=yes` her isteği
    /// profiller, dakikalar içinde yüzlerce MB üretir ve siteyi yavaşlatır.
    func testProfiler_DefaultsToTriggerNotEveryRequest() {
        let block = PHPProfiler.iniBlock()
        XCTAssertTrue(block.contains("xdebug.start_with_request = trigger"))
        XCTAssertFalse(block.contains("start_with_request = yes"))
        XCTAssertTrue(block.contains("xdebug.mode = profile"))

        let always = PHPProfiler.iniBlock(alwaysOn: true)
        XCTAssertTrue(always.contains("xdebug.start_with_request = yes"))
    }

    /// İşaret yoksa içerik AYNEN dönmeli — profilleyici hiç açılmamış bir
    /// php.ini'yi "temizlemek" onu değiştirmemeli.
    func testProfiler_RemovingFromUntouchedFileChangesNothing() {
        let original = "[PHP]\nmemory_limit = 128M\n"
        XCTAssertEqual(PHPProfiler.removing(from: original), original)
        XCTAssertFalse(PHPProfiler.isEnabled(in: original))
        XCTAssertFalse(PHPProfiler.isAlwaysOn(in: original))
    }

    // MARK: - Log akışı (LogTailer)

    /// Dosya küçüldüyse tutulan okuma konumu geçersizdir.
    ///
    /// `> dosya` ile boşaltma ya da gözetmenin logu yeniden yaratması bu duruma yol açar.
    /// Fark körlemesine hesaplansaydı `UInt64` taşar ve devasa bir okuma denenirdi.
    func testLogTailer_DetectsTruncation() {
        XCTAssertEqual(LogTailer.resolvedOffset(fileSize: 50, currentOffset: 500), 0,
                       "dosya küçüldü — baştan okunmalı")
        XCTAssertEqual(LogTailer.resolvedOffset(fileSize: 500, currentOffset: 500), 500,
                       "değişmemişse konum korunur")
        XCTAssertEqual(LogTailer.resolvedOffset(fileSize: 900, currentOffset: 500), 500,
                       "büyümüşse konumdan devam edilir")
        XCTAssertEqual(LogTailer.resolvedOffset(fileSize: 0, currentOffset: 0), 0)
    }

    /// Sonsuza kadar biriken log pencereyi şişirir; son N satır tutulur.
    func testLogTailer_CapsLineCount() {
        let text = (1...100).map { "satır \($0)" }.joined(separator: "\n")
        let capped = LogTailer.capped(text, maxLines: 10)
        let lines = capped.split(separator: "\n")
        XCTAssertEqual(lines.count, 10)
        XCTAssertEqual(lines.first, "satır 91", "en ESKİ değil en YENİ satırlar kalmalı")
        XCTAssertEqual(lines.last, "satır 100")

        // Tavanın altındaki metin olduğu gibi kalır
        XCTAssertEqual(LogTailer.capped("a\nb", maxLines: 10), "a\nb")
        XCTAssertEqual(LogTailer.capped("a\nb", maxLines: 0), "")
    }

    /// Boş satırlar korunmalı: log çıktısındaki boşluklar okunabilirliğin parçası.
    func testLogTailer_PreservesBlankLines() {
        let text = "bir\n\niki\n\n\nüç"
        XCTAssertEqual(LogTailer.capped(text, maxLines: 100), text)
        XCTAssertEqual(LogTailer.capped(text, maxLines: 3).split(separator: "\n",
                                                                omittingEmptySubsequences: false).count, 3)
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

        // Hedef IP: alan adını çözmek `.local` uzantısında istek başına 5 sn mDNS
        // zaman aşımına yol açıyordu (ölçüldü: 5,01 sn → 0,012 sn).
        XCTAssertTrue(cmd.contains("https://127.0.0.1:"), "hedef doğrudan IP olmalı: \(cmd)")
        XCTAssertFalse(cmd.contains("https://shop.test"), "ad çözümlemesi yola girmemeli")
        // Ama vhost ve TLS eşleşmesi için ad İKİ yerde verilmeli.
        XCTAssertTrue(cmd.contains("--http-host-header"), "vhost Host başlığıyla seçilir")
        XCTAssertTrue(cmd.contains("--origin-server-name"),
                      "SNI verilmezse sunucu varsayılan sertifikayı sunar ve 421 döner")
        XCTAssertTrue(cmd.contains("--no-tls-verify"), "mkcert sertifikası için gerekli")
        // Sayıya dayalı iddia kırılgandı: alan adı log dosyası yolunda da geçiyor.
        // Bayrakların DEĞERİNE bakılır.
        let tokens = cmd.components(separatedBy: " ")
        for flag in ["--http-host-header", "--origin-server-name"] {
            guard let i = tokens.firstIndex(of: flag), i + 1 < tokens.count else {
                return XCTFail("\(flag) komutta yok: \(cmd)")
            }
            XCTAssertTrue(tokens[i + 1].contains("shop.test"),
                          "\(flag) değeri alan adı olmalı, bulunan: \(tokens[i + 1])")
        }
    }

    /// SSL KAPALI: HTTP hedeflenir ve TLS doğrulaması atlanmaz — atlanacak TLS yok.
    func testTunnel_CommandForPlainDomain() {
        let d = Domain(name: "demo.test", platform: .php, sslEnabled: false, webServer: .apache)
        let cmd = TunnelManager.buildCommand(for: d, cloudflaredPath: "/opt/homebrew/bin/cloudflared")

        XCTAssertTrue(cmd.contains("http://127.0.0.1:"))
        XCTAssertFalse(cmd.contains("https://"))
        XCTAssertFalse(cmd.contains("--no-tls-verify"),
                       "TLS yokken doğrulama atlama bayrağı anlamsız")
        XCTAssertFalse(cmd.contains("--origin-server-name"),
                       "TLS yoksa SNI de yok")
        XCTAssertTrue(cmd.contains("--http-host-header"), "vhost yine ada göre seçilir")
    }


    /// Çalışmayan siteyi paylaşmak ziyaretçiye 502/503 gönderir: adres canlı, içerik yok.
    /// Bu sessiz bir hatadır — paylaşan kişi ancak bağlantıyı gönderdikten sonra öğrenir.
    func testShareBlock_RefusesWhenNothingIsServing() {
        // Node.js alan adı, web sunucusu ayakta ama arka plan uygulaması kapalı
        XCTAssertEqual(
            TunnelManager.shareBlockReason(isEnabled: true, webServerRunning: true,
                                           webServerName: "Nginx",
                                           isAppPlatform: true, appRunning: false),
            .appDown)

        // Web sunucusu kapalı — platform ne olursa olsun engellenir
        XCTAssertEqual(
            TunnelManager.shareBlockReason(isEnabled: true, webServerRunning: false,
                                           webServerName: "Apache",
                                           isAppPlatform: false, appRunning: false),
            .webServerDown("Apache"))

        // Devre dışı alan adının vhost'u yok
        XCTAssertEqual(
            TunnelManager.shareBlockReason(isEnabled: false, webServerRunning: true,
                                           webServerName: "Apache",
                                           isAppPlatform: false, appRunning: false),
            .domainDisabled)
    }

    /// Her şey yerindeyse engel YOK — PHP/statik alan adları uygulama süreci istemez.
    func testShareBlock_AllowsWhenReady() {
        XCTAssertNil(TunnelManager.shareBlockReason(isEnabled: true, webServerRunning: true,
                                                    webServerName: "Apache",
                                                    isAppPlatform: false, appRunning: false),
                     "PHP/statik için uygulama süreci gerekmez")
        XCTAssertNil(TunnelManager.shareBlockReason(isEnabled: true, webServerRunning: true,
                                                    webServerName: "Nginx",
                                                    isAppPlatform: true, appRunning: true))
    }

    /// Sıra önemli: en temeldeki eksik önce bildirilmeli. Web sunucusu kapalıyken
    /// "uygulama çalışmıyor" demek kullanıcıyı yanlış yere bakmaya gönderir.
    func testShareBlock_ReportsMostFundamentalCauseFirst() {
        // Üçü de eksik → devre dışı olduğu bildirilmeli
        XCTAssertEqual(
            TunnelManager.shareBlockReason(isEnabled: false, webServerRunning: false,
                                           webServerName: "Nginx",
                                           isAppPlatform: true, appRunning: false),
            .domainDisabled)
        // Etkin ama sunucu ve uygulama kapalı → sunucu bildirilmeli, uygulama değil
        XCTAssertEqual(
            TunnelManager.shareBlockReason(isEnabled: true, webServerRunning: false,
                                           webServerName: "Nginx",
                                           isAppPlatform: true, appRunning: false),
            .webServerDown("Nginx"))
    }


    /// Veritabanı/önbellek portları paylaşıma KAPALI.
    ///
    /// Quick Tunnel yalnızca HTTP taşıdığı için bir MySQL istemcisi zaten bağlanamaz;
    /// asıl mesele bu servislerin geliştirme makinesinde çoğunlukla parolasız durması.
    /// Port elle girildiğinden yanlış yazım gerçek bir ihtimal.
    func testPortShare_RefusesDatabaseAndCachePorts() {
        for (port, name) in [(3306, "MariaDB/MySQL"), (5432, "PostgreSQL"),
                             (6379, "Redis"), (11211, "Memcached"), (27017, "MongoDB")] {
            XCTAssertEqual(TunnelManager.portRefusal(port: port, isListening: true),
                           .reservedService(name), "port \(port) reddedilmeli")
        }
    }

    func testPortShare_RefusesClosedAndInvalidPorts() {
        XCTAssertEqual(TunnelManager.portRefusal(port: 5173, isListening: false), .notListening,
                       "dinlenmeyen port boş adres verirdi")
        XCTAssertEqual(TunnelManager.portRefusal(port: 0, isListening: true), .outOfRange)
        XCTAssertEqual(TunnelManager.portRefusal(port: 70000, isListening: true), .outOfRange)
        // Sıra: aralık denetimi önce — 99999 aynı zamanda dinlenmiyor ama asıl sorun aralık
        XCTAssertEqual(TunnelManager.portRefusal(port: 99999, isListening: false), .outOfRange)
    }

    func testPortShare_AllowsOrdinaryDevPort() {
        XCTAssertNil(TunnelManager.portRefusal(port: 5173, isListening: true))
        XCTAssertNil(TunnelManager.portRefusal(port: 3000, isListening: true))
        XCTAssertEqual(TunnelManager.portKey(5173), ":5173",
                       "port paylaşımları alan adı olmadığı için sentetik anahtar kullanır")
    }

    /// Kullanıcıya teknik hedef değil sitenin kendi adresi gösterilmeli.
    func testTunnel_ShowsSiteAddressNotTheIPTarget() {
        let d = Domain(name: "shop.test", platform: .php, sslEnabled: true, webServer: .apache)
        XCTAssertTrue(TunnelManager.displayOrigin(for: d).contains("shop.test"))
        XCTAssertFalse(TunnelManager.displayOrigin(for: d).contains("127.0.0.1"))
        XCTAssertTrue(TunnelManager.origin(for: d).contains("127.0.0.1"))
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

    /// **2.0'dan sonra iki haneli merdiven: 2.01 … 2.09, 2.10, 2.11.**
    ///
    /// Sürüm 1.9'dan 2.0'a geçti ve sonrası iki haneli sayaç olarak sürüyor. Bu
    /// merdivenin sayısal karşılaştırmayla artan kaldığı burada sabitlenir —
    /// "2.09'dan sonra ne gelecek" sorusunun yanıtı 2.10'dur ve testi bu söyler.
    func testVersionLadder_TwoDigitMinorStaysMonotonic() {
        let ladder = ["2.0", "2.01", "2.02", "2.03", "2.04", "2.05",
                      "2.06", "2.07", "2.08", "2.09", "2.10", "2.11", "2.20", "3.0"]
        for (i, newer) in ladder.enumerated().dropFirst() {
            let older = ladder[i - 1]
            XCTAssertTrue(UpdateChecker.isNewer(newer, than: older),
                          "\(newer), \(older) sürümünden yeni sayılmalı")
            XCTAssertFalse(UpdateChecker.isNewer(older, than: newer),
                           "\(older), \(newer) sürümünden yeni SAYILMAMALI")
        }
    }

    /// **"2.1" YAYINLANAMAZ — 2.01 ile aynı sayıya çözülür.**
    ///
    /// Karşılaştırma bileşenleri sayıya çevirir, yani "01" ile "1" ayırt edilemez.
    /// İki haneli sayaca geçildikten sonra tek haneli bir ara sürüm yazmak sessiz
    /// ve tam bir teslimat kaybı olurdu: 2.02 ve sonrasındaki hiç kimseye
    /// "yeni sürüm var" denmez, hata da verilmez — güncelleme sadece hiç gelmez.
    /// Onuncu ara sürümün adı **2.10**'dur.
    ///
    /// Test davranışı DÜZELTMEZ, sınırı yazıya geçirir: burada `isNewer`ı "01" ile
    /// "1"i ayıracak şekilde değiştirmek, sayısal karşılaştırmanın kendisini
    /// (1.10 > 1.9) bozardı — asıl tuzak oydu.
    func testVersionLadder_SingleDigitMinorCollidesAndMustNotBePublished() {
        XCTAssertFalse(UpdateChecker.isNewer("2.1", than: "2.01"),
                       "2.1 ile 2.01 aynı sayıdır — 2.1 yayınlanırsa güncelleme hiç ulaşmaz")
        XCTAssertFalse(UpdateChecker.isNewer("2.01", than: "2.1"))
        // Ve asıl zarar: 2.09'daki kullanıcı için "2.1" GERİ adımdır.
        XCTAssertFalse(UpdateChecker.isNewer("2.1", than: "2.09"),
                       "2.09'dan sonra gelen sürümün adı 2.10 olmalı, 2.1 değil")
        XCTAssertTrue(UpdateChecker.isNewer("2.10", than: "2.09"))
    }

    /// Uçtan uca: yayındaki etiketle mevcut sürüm karşılaştırıldığında
    /// "güncelleme yok" çıkmalı (ikisi de aynı sürüm serisinden).
    func testUpdateChecker_SameVersionIsNotAnUpdate() {
        let tag = UpdateChecker.normalize("v1.1")
        XCTAssertFalse(UpdateChecker.isNewer(tag, than: UpdateChecker.normalize("1.1")))
        XCTAssertTrue(UpdateChecker.isNewer(UpdateChecker.normalize("v1.2"),
                                            than: UpdateChecker.normalize("1.1")))
    }

    // MARK: - Açılışta bildirim kararı (UpdateChecker.decide)

    /// Kısayol: testlerin okunur kalması için varsayılanlı sarmalayıcı.
    private func decide(current: String = "1.5", latest: String = "1.6",
                        skipped: String = "", snooze: Date = .distantPast,
                        mandatory: Bool = false, blocked: Bool = false,
                        now: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> UpdateChecker.PromptDecision {
        UpdateChecker.decide(current: current, latest: latest,
                             skippedVersion: skipped, snoozeUntil: snooze,
                             mandatory: mandatory, blockedCurrent: blocked, now: now)
    }

    func testUpdatePrompt_ShowsWhenNewerAndNothingSuppressesIt() {
        XCTAssertEqual(decide(), .show)
    }

    func testUpdatePrompt_NoNewerVersionIsNotShown() {
        XCTAssertEqual(decide(current: "1.6", latest: "1.6"), .upToDate)
        // 1.10 > 1.9 — saf dizgi karşılaştırması burada "upToDate" derdi
        XCTAssertEqual(decide(current: "1.9", latest: "1.10"), .show)
    }

    /// "Bu sürümü atla" TAM sürüme bağlıdır.
    func testUpdatePrompt_SkipMatchesExactVersionOnly() {
        XCTAssertEqual(decide(latest: "1.6", skipped: "1.6"), .skippedVersion)
        // Elle düzenlenmiş settings.json "v1.6" yazmış olabilir → yine eşleşmeli
        XCTAssertEqual(decide(latest: "1.6", skipped: "v1.6"), .skippedVersion)
    }

    /// ATLAMA İLERİ TAŞINMAZ: 1.6 atlandıysa 1.7 yine sorulur. Naif bir
    /// "atlanan varsa sus" mantığı bu testte kalır.
    func testUpdatePrompt_SkipDoesNotCarryToANewerVersion() {
        XCTAssertEqual(decide(current: "1.5", latest: "1.7", skipped: "1.6"), .show)
    }

    func testUpdatePrompt_ActiveSnoozeSuppresses_ExpiredDoesNot() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(decide(snooze: now.addingTimeInterval(3600), now: now), .snoozed)
        XCTAssertEqual(decide(snooze: now.addingTimeInterval(-1), now: now), .show)
        // Sınır anı: erteleme bitiş ANINDA artık susturmaz
        XCTAssertEqual(decide(snooze: now, now: now), .show)
    }

    /// ERTELEME, ARAYA YENİ BİR SÜRÜM GİRDİ DİYE BOZULMAZ. "Bir hafta sessizlik"
    /// sözünü her yayının delmesi denetimi yalana çevirirdi.
    func testUpdatePrompt_SnoozeSurvivesANewerRelease() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(decide(current: "1.5", latest: "9.9",
                              snooze: now.addingTimeInterval(86_400), now: now), .snoozed)
    }

    /// Zorunlu güncelleme atlamayı da ertelemeyi de deler.
    func testUpdatePrompt_MandatoryPiercesSkipAndSnooze() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(decide(latest: "1.6", skipped: "1.6", mandatory: true, now: now), .show)
        XCTAssertEqual(decide(snooze: now.addingTimeInterval(86_400),
                              mandatory: true, now: now), .show)
    }

    /// Kurulu sürüm SORUNLU işaretlenmişse uyarı susturulamaz
    /// (spec/update-manifest.md: "blockedVersions outranks mandatory").
    func testUpdatePrompt_BlockedCurrentPiercesEverything() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(decide(latest: "1.6", skipped: "1.6",
                              snooze: now.addingTimeInterval(86_400),
                              blocked: true, now: now), .show)
    }

    /// Bayat bir erteleme ile taze bir atlama çakışırsa sonuç DETERMİNİSTİK
    /// olarak "atlandı" olmalı — daha açık kullanıcı iradesi odur.
    func testUpdatePrompt_SkipBeatsStaleSnooze() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(decide(latest: "1.6", skipped: "1.6",
                              snooze: now.addingTimeInterval(86_400), now: now),
                       .skippedVersion)
    }

    // MARK: - UpdateVerifier: indirme adresi güveni

    func testUpdateVerifier_TrustsOnlyTheExpectedReleaseAddresses() {
        // docs/updates/macos/stable.json içindeki GERÇEK varlık adresi
        XCTAssertTrue(UpdateVerifier.isTrustedReleaseURL(
            URL(string: "https://github.com/macitkaraca/brampp/releases/download/v1.4/BRAMPP-1.4.dmg")))
        // Yönlendirmenin indiği CDN
        XCTAssertTrue(UpdateVerifier.isTrustedReleaseURL(
            URL(string: "https://objects.githubusercontent.com/github-production-release-asset/x")))
    }

    func testUpdateVerifier_RejectsLookalikeAndInsecureAddresses() {
        let bad = [
            // http — şifresiz
            "http://github.com/macitkaraca/brampp/releases/download/v1.4/BRAMPP-1.4.dmg",
            // sonek eşleşmesi kullanılsaydı GEÇERDİ
            "https://evilgithub.com/macitkaraca/brampp/releases/download/v1.4/BRAMPP-1.4.dmg",
            // alt alan adı hilesi
            "https://github.com.attacker.net/macitkaraca/brampp/releases/download/v1.4/x.dmg",
            // doğru alan, BAŞKA depo
            "https://github.com/someoneelse/repo/releases/download/v1/x.dmg",
            // doğru alan, yayın varlığı olmayan yol
            "https://github.com/macitkaraca/brampp/blob/main/x.dmg",
            // kullanıcı-bilgisi hilesi: gerçek ana bilgisayar evil.example
            "https://github.com@evil.example/macitkaraca/brampp/releases/download/v1/x.dmg"
        ]
        for s in bad {
            XCTAssertFalse(UpdateVerifier.isTrustedReleaseURL(URL(string: s)),
                           "güvenilmemeli: \(s)")
        }
        XCTAssertFalse(UpdateVerifier.isTrustedReleaseURL(nil))
    }

    /// **YOL GEZİNMESİ.** `URL.path` yolu NORMALLEŞTİRMEZ; `hasPrefix` denetimi
    /// `.../releases/download/../../../someoneelse/repo/x.dmg` adresini geçirirdi
    /// oysa sunucu onu bambaşka bir depoya çözer. Tek başına sömürülebilir değil
    /// (sha256/codesign/Team ID/spctl kapıları duruyor) ama bu fonksiyon tam olarak
    /// "beklenen yayın varlığı mı" kapısıdır — dört kapıyı üçe indiremez.
    func testUpdateVerifier_RejectsPathTraversalInReleaseURLs() {
        let traversal = [
            "https://github.com/macitkaraca/brampp/releases/download/../../../someoneelse/repo/x.dmg",
            "https://github.com/macitkaraca/brampp/releases/download/v1.4/../../../../x.dmg",
            "https://github.com/macitkaraca/brampp/releases/download/v1.4/..%2F..%2Fx.dmg"
        ]
        for s in traversal {
            XCTAssertFalse(UpdateVerifier.isTrustedReleaseURL(URL(string: s)),
                           "yol gezinmesi geçmemeli: \(s)")
        }
        // Normalleştirmenin DOĞRU adresi bozmadığı da doğrulanır
        XCTAssertTrue(UpdateVerifier.isTrustedReleaseURL(
            URL(string: "https://github.com/macitkaraca/brampp/releases/download/v1.5/BRAMPP-1.5.dmg")))
    }

    /// İNMEMİŞ bir dosya için "indirilen dosya silindi" denmez. `.checksumMismatch`
    /// bu durumun nöbetçisi olarak kullanılıyordu; kendi nedeni var.
    func testUpdateVerifier_MissingChecksumHasItsOwnReason() {
        XCTAssertEqual(UpdateVerifier.Failure.noChecksum.messageKey, "upd.fail.noHash")
        XCTAssertNotEqual(UpdateVerifier.Failure.noChecksum.messageKey,
                          UpdateVerifier.Failure.checksumMismatch.messageKey)
    }

    // MARK: - Hazırlık dizini KOŞU BAŞINA türetilir (PathConfig)

    /// **Dizin sürümden türetilirse aynı sürümün iki koşusu ÇAKIŞIR** — ve kurucu
    /// bunu ancak "yeni koşu öncekinin bitmesini beklesin" diyerek önleyebiliyordu.
    /// O bekleyiş `_ = await previous?.value` idi; `Task<Void, Never>.value` bekleyenin
    /// iptalini dinlemediği için bitmeyen bir koşu kurucuyu OTURUM BOYUNCA kilitliyordu:
    /// aşama `.verifying`de donuyor, "Durdur" işe yaramış görünüyor ve sonraki her
    /// "İndir ve doğrula" tıklaması hiçbir şey yapmıyordu.
    ///
    /// Bu testin koruduğu değişmez: AYNI sürüm, FARKLI koşu ⇒ FARKLI dizin.
    /// Sağlanıyorsa beklemeye gerek kalmaz.
    func testPathConfig_StagingDirectoryIsPerRunNotPerVersion() {
        let first  = PathConfig.updateStagingName(version: "1.6", run: 1)
        let second = PathConfig.updateStagingName(version: "1.6", run: 2)
        XCTAssertNotEqual(first, second, "aynı sürümün iki koşusu aynı dizini PAYLAŞAMAZ")

        // Sürüm adın içinde kalır: kullanıcı `updates/` içine baktığında ne olduğunu
        // görebilmeli ve prune adı ayrıştırmadan çalışabilmeli.
        XCTAssertTrue(first.hasPrefix("1.6"))
        XCTAssertEqual(first, "1.6-1")
        XCTAssertEqual(second, "1.6-2")

        // Tam yol `updates/` altında kalır — ve yola ".." sokulamaz.
        XCTAssertEqual(PathConfig.updateStaging(version: "1.6", run: 3),
                       "\(PathConfig.updates)/1.6-3")
        XCTAssertEqual(PathConfig.updateStaging(name: first), "\(PathConfig.updates)/1.6-1")
        XCTAssertFalse(PathConfig.updateStaging(version: "1.6", run: 3).contains(".."))
    }

    // MARK: - Hazırlık dizini temizliği (UpdateInstaller.pruneOldStaging)

    /// Doğrulanan disk kalıbı kullanıcı kurana kadar durur — ve kullanıcı
    /// KURMAYABİLİR. Yalnızca aynı sürümün dizinini temizlemek, her yayında ~60 MB'ı
    /// kullanıcının varlığından habersiz olduğu bir dizinde bırakıyordu.
    /// `names` verildiğinde diske DOKUNULMAZ — bu yüzden test edilebilir.
    func testUpdateInstaller_PrunesEveryStagingDirectoryButTheCurrentRun() {
        let onDisk = ["1.3-1", "1.4-1", "1.5-2", ".DS_Store"]
        XCTAssertEqual(Set(UpdateInstaller.pruneOldStaging(keeping: ["1.5-2"], names: onDisk)),
                       ["1.3-1", "1.4-1"])
        // Açılışta hiçbiri korunmaz: bekleyen bir kurulum yoktur, hepsi bayattır
        XCTAssertEqual(Set(UpdateInstaller.pruneOldStaging(keeping: [], names: onDisk)),
                       ["1.3-1", "1.4-1", "1.5-2"])
        // Gizli girdiler hiçbir hâlde silinmez
        XCTAssertFalse(UpdateInstaller.pruneOldStaging(keeping: [], names: onDisk).contains(".DS_Store"))
    }

    /// **KORUNAN, TEK BİR AD DEĞİL YAŞAYAN KOŞULARIN TAMAMIDIR.**
    ///
    /// Yeni koşu artık öncekinin bitmesini beklemiyor, yani bir koşu inerken ondan
    /// önce başlamış bir koşu hâlâ sarılıp çözülüyor olabilir. Prune yalnızca "şu anki"
    /// dizini korusaydı, yeni koşu yanı başındaki koşunun dosyasını silerdi — koşu
    /// başına dizine geçerken ortadan kaldırdığımız hatanın TIPATIP aynısı, iki kırmızı
    /// hata ve sıfır indirme.
    func testUpdateInstaller_PruneKeepsEveryLiveRunNotJustTheNewest() {
        // 1.6'nın 4. koşusu inerken 3. koşu hâlâ çözülüyor; 1.5'ten kalıntı var.
        let onDisk = ["1.5-1", "1.6-3", "1.6-4"]
        let live: Set<String> = ["1.6-3", "1.6-4"]

        let removed = Set(UpdateInstaller.pruneOldStaging(keeping: live, names: onDisk))
        XCTAssertEqual(removed, ["1.5-1"])
        XCTAssertFalse(removed.contains("1.6-3"), "yan yana koşan bir işin dizini SİLİNEMEZ")
        XCTAssertFalse(removed.contains("1.6-4"))

        // Aynı SÜRÜMÜN başka bir koşusu "aynı sürüm" diye korunmaz: kimlik dizin ADIDIR.
        XCTAssertEqual(Set(UpdateInstaller.pruneOldStaging(keeping: ["1.6-4"], names: onDisk)),
                       ["1.5-1", "1.6-3"])
    }

    // MARK: - "Sağlama yayınlanmamış" şeridi (UpdatePromptView)

    /// Testler için yayın bilgisi üretir; yalnızca ilgilenilen alanlar verilir.
    private func release(sha256: String?,
                         requiredOS: String? = nil,
                         blockedCurrent: Bool = false) -> UpdateChecker.ReleaseInfo {
        UpdateChecker.ReleaseInfo(
            version: "1.6",
            tag: "v1.6",
            pageURL: URL(string: "https://github.com/macitkaraca/brampp/releases/tag/v1.6")!,
            notes: "",
            assetURL: URL(string: "https://github.com/macitkaraca/brampp/releases/download/v1.6/BRAMPP-1.6.dmg"),
            sha256: sha256,
            mandatory: false,
            blockedCurrent: blockedCurrent,
            channel: "stable",
            publishedAt: nil,
            manifestBacked: true,
            requiredOS: requiredOS)
    }

    /// **"Doğrulanabilir sağlama yayınlanmamış" YALAN OLMAMALI.**
    ///
    /// Şerit yalnızca `sha256 == nil`e bakıyordu; oysa `sha256`, indirmeyi KAPATMANIN
    /// da yolu: `minimumOS` bu makineye yetmediğinde ve kurulu sürüm engellendiğinde de
    /// nil'lenir. macOS 14'teki kullanıcı, 15.0 isteyen PEKÂLÂ sağlaması yayınlanmış bir
    /// yayın için hem "macOS 15.0 gerekiyor" hem "sağlama yok" görüyordu — ikincisi
    /// yanlış ve gerçek nedeni gölgeliyor.
    func testUpdatePromptView_NoChecksumStripOnlyWhenTheChecksumIsTrulyAbsent() {
        // Manifest okunamadı / bu mimari için giriş yok → şerit DOĞRU
        XCTAssertTrue(UpdatePromptView.showsNoChecksumNotice(release(sha256: nil)))

        // macOS yetmiyor: sağlama YAYINLANMIŞTIR, yalnızca indirme kapalıdır
        XCTAssertFalse(UpdatePromptView.showsNoChecksumNotice(
            release(sha256: nil, requiredOS: "15.0")))

        // Kurulu sürüm `blockedVersions` listesinde: neden yine sağlamanın yokluğu değil
        XCTAssertFalse(UpdatePromptView.showsNoChecksumNotice(
            release(sha256: nil, blockedCurrent: true)))

        // Sağlama varsa şerit zaten hiç çıkmaz — hangi durumda olursa olsun
        XCTAssertFalse(UpdatePromptView.showsNoChecksumNotice(release(sha256: String(repeating: "a", count: 64))))
        XCTAssertFalse(UpdatePromptView.showsNoChecksumNotice(
            release(sha256: String(repeating: "a", count: 64), requiredOS: "15.0")))
    }

    // MARK: - UpdateVerifier: codesign / spctl çıktı ayrıştırma

    /// `codesign -dv --verbose=4` çıktısından yakalanmış gerçek biçim.
    private let codesignBlock = """
    Executable=/Volumes/BRAMPP/BRAMPP.app/Contents/MacOS/BRAMPP
    Identifier=com.karaca.BRAMPP
    Format=app bundle with Mach-O universal (arm64)
    CodeDirectory v=20500 size=1234 flags=0x10000(runtime) hashes=30+7
    Signature size=9000
    Authority=Developer ID Application: Macit Karaca (AB12CD34EF)
    Authority=Developer ID Certification Authority
    Authority=Apple Root CA
    TeamIdentifier=AB12CD34EF
    Sealed Resources version=2 rules=13 files=42
    """

    func testUpdateVerifier_ExtractsTeamIdentifier() {
        XCTAssertEqual(UpdateVerifier.teamIdentifier(inCodesignOutput: codesignBlock), "AB12CD34EF")
        XCTAssertEqual(UpdateVerifier.authorities(inCodesignOutput: codesignBlock).first,
                       "Developer ID Application: Macit Karaca (AB12CD34EF)")
        XCTAssertEqual(UpdateVerifier.authorities(inCodesignOutput: codesignBlock).count, 3)
    }

    /// İmzasız/ad-hoc paketlerde `codesign` harfi harfine "not set" yazar. Bunu bir
    /// kimlik saymak, iki imzasız paketi "aynı geliştirici" ilan etmek olurdu.
    func testUpdateVerifier_NotSetTeamIdentifierIsNil() {
        XCTAssertNil(UpdateVerifier.teamIdentifier(inCodesignOutput: "TeamIdentifier=not set"))
        XCTAssertNil(UpdateVerifier.teamIdentifier(inCodesignOutput: "TeamIdentifier="))
        XCTAssertNil(UpdateVerifier.teamIdentifier(inCodesignOutput: "Identifier=com.karaca.BRAMPP"))
    }

    func testUpdateVerifier_CodesignVerdictComesFromExitCodeOnly() {
        XCTAssertTrue(UpdateVerifier.isCodesignVerified(exitCode: 0, stderr: "x: valid on disk"))
        XCTAssertFalse(UpdateVerifier.isCodesignVerified(exitCode: 1, stderr: "x: valid on disk"))
        XCTAssertFalse(UpdateVerifier.isCodesignVerified(exitCode: -1, stderr: ""))
    }

    /// İŞİN KALBİ: `spctl` çıkış kodu 0 OLSA BİLE, noter onayı görülmeden kabul yok.
    /// Yalnızca çıkış koduna bakan naif bir denetim bu testte kalır.
    func testUpdateVerifier_UnnotarizedIsRejectedEvenWithExitCodeZero() {
        let notarized = "/Volumes/BRAMPP/BRAMPP.app: accepted\nsource=Notarized Developer ID\norigin=Developer ID Application: Macit Karaca (AB12CD34EF)"
        let unnotarized = "/Volumes/BRAMPP/BRAMPP.app: accepted\nsource=Unnotarized Developer ID\norigin=Developer ID Application: Macit Karaca (AB12CD34EF)"
        let plainDevID = "/Volumes/BRAMPP/BRAMPP.app: accepted\nsource=Developer ID"

        XCTAssertTrue(UpdateVerifier.isNotarizedAccepted(exitCode: 0, output: notarized))
        XCTAssertFalse(UpdateVerifier.isNotarizedAccepted(exitCode: 0, output: unnotarized))
        XCTAssertFalse(UpdateVerifier.isNotarizedAccepted(exitCode: 0, output: plainDevID))
        // Reddedilen paket
        XCTAssertFalse(UpdateVerifier.isNotarizedAccepted(exitCode: 3, output: notarized))
    }

    func testUpdateVerifier_ChecksumComparison() {
        let a = String(repeating: "a", count: 64)
        XCTAssertTrue(UpdateVerifier.checksumsMatch(a, a.uppercased()))
        XCTAssertTrue(UpdateVerifier.checksumsMatch("  \(a)\n", a))
        XCTAssertFalse(UpdateVerifier.checksumsMatch(a, String(repeating: "b", count: 64)))
        // Yanlış uzunluk (kırpılmış çıktı) kabul edilmez
        XCTAssertFalse(UpdateVerifier.checksumsMatch(String(a.dropLast()), String(a.dropLast())))
        // BOŞ–BOŞ EŞİT SAYILMAZ: eksik alan yüzünden doğrulamanın sessizce geçmesi,
        // bu fonksiyonun engellemek için var olduğu tek şeydir.
        XCTAssertFalse(UpdateVerifier.checksumsMatch("", ""))
        // Onaltılık olmayan karakter
        XCTAssertFalse(UpdateVerifier.checksumsMatch(String(repeating: "z", count: 64),
                                                     String(repeating: "z", count: 64)))
    }

    // MARK: - UpdateManifest çözümleme

    /// docs/updates/macos/stable.json ile birebir aynı şekil.
    private let macManifestJSON = """
    {
      "version": "1.4",
      "channel": "stable",
      "published": "2026-08-10",
      "release": "https://github.com/macitkaraca/brampp/releases/tag/v1.4",
      "minimumOS": "14.0",
      "mandatory": false,
      "blockedVersions": ["1.2"],
      "downloads": {
        "arm64": {
          "url": "https://github.com/macitkaraca/brampp/releases/download/v1.4/BRAMPP-1.4.dmg",
          "sha256": "6d9079fb353c8bc0fb202b2acce1d16c3c9a0a3e765ca46ee05c2ca9c77e03aa"
        }
      }
    }
    """

    func testUpdateManifest_ParsesTheRealMacOSShape() throws {
        let m = try XCTUnwrap(UpdateManifest.parse(Data(macManifestJSON.utf8)))
        XCTAssertEqual(m.version, "1.4")
        XCTAssertEqual(m.channel, "stable")
        XCTAssertFalse(m.isMandatory)
        let dl = try XCTUnwrap(m.download(forArch: "arm64"))
        XCTAssertEqual(dl.sha256?.count, 64)
        XCTAssertTrue(UpdateVerifier.isTrustedReleaseURL(dl.assetURL))
        // Intel'de giriş YOK → nil, çökme değil
        XCTAssertNil(m.download(forArch: "x86_64"))
        // blockedVersions normalize edilerek karşılaştırılır
        XCTAssertTrue(m.isBlocked("v1.2"))
        XCTAssertFalse(m.isBlocked("1.3"))
        XCTAssertNotNil(m.publishedDate)
    }

    /// windows/linux dosyaları GERÇEKTEN `"version": null` ve `minimumOS` YOK.
    /// Bu bir hata değil, "bu kanalda henüz yayın yok" demektir.
    func testUpdateManifest_ToleratesNullVersionAndMissingKeys() throws {
        let json = """
        {"version": null, "channel": "stable", "published": null, "release": null,
         "mandatory": false, "blockedVersions": [], "downloads": {},
         "note": "No windows build has been released yet."}
        """
        let m = try XCTUnwrap(UpdateManifest.parse(Data(json.utf8)))
        XCTAssertNil(m.version)
        XCTAssertNil(m.minimumOS)
        XCTAssertNil(m.download(forArch: "arm64"))
        XCTAssertFalse(m.isBlocked("1.5"))
        // minimumOS yoksa kısıtlama da yok
        XCTAssertTrue(m.meetsMinimumOS(OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)))
    }

    func testUpdateManifest_MinimumOSIsComparedNumerically() throws {
        let m = try XCTUnwrap(UpdateManifest.parse(Data(macManifestJSON.utf8)))
        XCTAssertTrue(m.meetsMinimumOS(OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)))
        XCTAssertTrue(m.meetsMinimumOS(OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 0)))
        XCTAssertFalse(m.meetsMinimumOS(OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 0)))
    }

    func testUpdateManifest_URLIsBuiltOnlyFromTheDocumentedPattern() {
        XCTAssertEqual(UpdateManifest.url(channel: .stable)?.absoluteString,
                       "https://macitkaraca.github.io/brampp/updates/macos/stable.json")
        XCTAssertEqual(UpdateManifest.url(channel: .nightly)?.absoluteString,
                       "https://macitkaraca.github.io/brampp/updates/macos/nightly.json")
        // Bilinmeyen kanal adı kararlıya düşer — olmayan bir dosya sonsuza dek sorulmaz
        XCTAssertEqual(UpdateChannel.from("kanalyok"), .stable)
        XCTAssertEqual(UpdateChannel.from("beta"), .beta)
        // Bugün GERÇEKTEN yayınlanan tek kanal
        XCTAssertTrue(UpdateChannel.stable.isPublished)
        XCTAssertFalse(UpdateChannel.beta.isPublished)
    }

    func testUpdateManifest_GarbageJSONIsNotAnError() {
        XCTAssertNil(UpdateManifest.parse(Data("bu json değil".utf8)))
        XCTAssertNil(UpdateManifest.parse(Data()))
    }

    // MARK: - Manifest ↔ API sürüm önceliği (UpdateChecker.resolve)

    /// Verilen alanlarla bir manifest kurar. JSON üzerinden gider ki testler
    /// çözümleyicinin kendisini de kullansın — üretimde okunan yol budur.
    private func manifest(version: String?,
                          minimumOS: String? = "14.0",
                          mandatory: Bool = false,
                          blocked: [String] = []) -> UpdateManifest {
        let v = version.map { "\"\($0)\"" } ?? "null"
        let os = minimumOS.map { "\"\($0)\"" } ?? "null"
        let blockedList = blocked.map { "\"\($0)\"" }.joined(separator: ", ")
        let json = """
        {
          "version": \(v),
          "channel": "stable",
          "published": "2026-08-10",
          "release": "https://github.com/macitkaraca/brampp/releases/tag/v\(version ?? "0")",
          "minimumOS": \(os),
          "mandatory": \(mandatory),
          "blockedVersions": [\(blockedList)],
          "downloads": {
            "arm64": {
              "url": "https://github.com/macitkaraca/brampp/releases/download/v\(version ?? "0")/BRAMPP-\(version ?? "0").dmg",
              "sha256": "\(String(repeating: "a", count: 64))"
            }
          }
        }
        """
        // swiftlint:disable:next force_unwrapping — sabit, testin kendi ürettiği JSON
        return UpdateManifest.parse(Data(json.utf8))!
    }

    private func apiRelease(_ version: String) -> UpdateChecker.APIRelease {
        UpdateChecker.APIRelease(
            version: version,
            tag: "v\(version)",
            pageURL: URL(string: "https://github.com/macitkaraca/brampp/releases/tag/v\(version)")!,
            notes: "notlar \(version)",
            publishedAt: nil)
    }

    private let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 4, patchVersion: 1)
    private let sequoia = OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 0)

    /// **YAŞANMIŞ HATA.** 1.5 yayınlanmıştı, `docs/updates/macos/stable.json` hâlâ
    /// "1.4" diyordu ve hiçbir betik o dosyayı yazmıyordu. Manifesti TEK kaynak sayan
    /// denetim HERKESE sonsuza dek "güncelsiniz" derdi — üstelik eski API tabanlı
    /// denetleyiciye göre bir GERİLEME. Bayat manifest SESSİZLİK ANLAMINA GELEMEZ.
    func testUpdateResolve_LaggingManifestStillYieldsTheAPIVersion() {
        let r = UpdateChecker.resolve(current: "1.5",
                                      manifest: manifest(version: "1.4"),
                                      api: apiRelease("1.6"),
                                      channel: "stable",
                                      os: sonoma)
        guard case .updateAvailable(let current, let release) = r else {
            return XCTFail("bayat manifest güncellemeyi yutmamalı, gelen: \(r)")
        }
        XCTAssertEqual(current, "1.5")
        XCTAssertEqual(release.version, "1.6")
        // Manifest 1.6'yı ANLATMIYOR: oradaki sha256 başka bir dosyanın özeti.
        // Doğrulanamayacak bir indirme sunulmaz — kullanıcı sürüm sayfasına gider.
        XCTAssertNil(release.sha256, "bayat manifestin sağlaması BAŞKA sürüme ait")
        XCTAssertNil(release.assetURL)
        XCTAssertFalse(release.manifestBacked)
        // Notlar API'den gelir ve o sürüme aittir
        XCTAssertEqual(release.notes, "notlar 1.6")
    }

    /// Manifest ÖNDEYSE ayrıntıların kaynağı odur: sha256 olmadan uygulama içi
    /// indirme hiç açılmaz, dolayısıyla bu yol özelliğin çalıştığı tek yoldur.
    func testUpdateResolve_ManifestWinsWhenItIsTheNewerSource() {
        let r = UpdateChecker.resolve(current: "1.5",
                                      manifest: manifest(version: "1.6", mandatory: true),
                                      api: apiRelease("1.5"),
                                      channel: "stable",
                                      os: sonoma)
        guard case .updateAvailable(_, let release) = r else { return XCTFail("gelen: \(r)") }
        XCTAssertEqual(release.version, "1.6")
        XCTAssertEqual(release.sha256?.count, 64)
        XCTAssertNotNil(release.assetURL)
        XCTAssertTrue(release.manifestBacked)
        XCTAssertTrue(release.mandatory)
        // API 1.5'i gösteriyor — 1.5'in notlarını 1.6 başlığının altına koymak yalan olurdu
        XCTAssertEqual(release.notes, "")
    }

    /// İki kaynak da AYNI sürümü söylüyorsa ayrıntılar manifestten gelir ve
    /// notlar da kullanılır — özelliğin normal günü budur.
    func testUpdateResolve_AgreementUsesManifestDetailsAndAPINotes() {
        let r = UpdateChecker.resolve(current: "1.5",
                                      manifest: manifest(version: "1.6"),
                                      api: apiRelease("1.6"),
                                      channel: "stable",
                                      os: sonoma)
        guard case .updateAvailable(_, let release) = r else { return XCTFail("gelen: \(r)") }
        XCTAssertEqual(release.sha256?.count, 64)
        XCTAssertEqual(release.notes, "notlar 1.6")
    }

    /// Manifest okunamadıysa (ağ yok, 404, bozuk JSON) API'ye düşülür — eski
    /// davranış korunur, ama sağlama yoktur.
    func testUpdateResolve_FallsBackToTheAPIWhenTheManifestIsUnreadable() {
        let r = UpdateChecker.resolve(current: "1.5", manifest: nil, api: apiRelease("1.6"),
                                      channel: "stable", os: sonoma)
        guard case .updateAvailable(_, let release) = r else { return XCTFail("gelen: \(r)") }
        XCTAssertEqual(release.version, "1.6")
        XCTAssertNil(release.sha256)
        XCTAssertFalse(release.manifestBacked)
    }

    /// Hiçbir kaynağa ULAŞILAMADIYSA başarısızlık; manifest okunup "bu kanalda
    /// yayın yok" dediyse HATA DEĞİL (spec: "A missing manifest is not an error").
    func testUpdateResolve_NoSourceIsFailure_NullVersionIsNot() {
        XCTAssertEqual(UpdateChecker.resolve(current: "1.5", manifest: nil, api: nil,
                                             channel: "stable", os: sonoma), .failed)
        XCTAssertEqual(UpdateChecker.resolve(current: "1.5",
                                             manifest: manifest(version: nil),
                                             api: nil, channel: "stable", os: sonoma),
                       .upToDate(current: "1.5"))
    }

    // MARK: - Sorunlu KURULU sürüm (blockedVersions)

    /// **ASIL SENARYO** (spec/update-manifest.md): 1.6 yayınlandı, zararlı çıktı,
    /// listeye eklendi. Manifestin `version`'ı HÂLÂ 1.6 — yani "daha yeni sürüm"
    /// yok. Yalnızca `isNewer`e bakan bir denetim tam da uyarılması gereken
    /// kullanıcıya "güncelsiniz" der ve `blockedVersions` hiç ateşlenemez.
    func testUpdateResolve_BlockedCurrentWarnsEvenWithNoNewerVersion() {
        let r = UpdateChecker.resolve(current: "1.6",
                                      manifest: manifest(version: "1.6", blocked: ["1.6"]),
                                      api: apiRelease("1.6"),
                                      channel: "stable",
                                      os: sonoma)
        guard case .currentBlocked(let current, let release) = r else {
            return XCTFail("sorunlu kurulu sürüm susturulamaz, gelen: \(r)")
        }
        XCTAssertEqual(current, "1.6")
        XCTAssertTrue(release.blockedCurrent)
        // Kurulacak bir şey YOK — kullanıcının zaten çalıştırdığı sürümü yeniden
        // indirtmek anlamsız olurdu; arayüz yalnızca sürüm sayfasını önerir.
        XCTAssertNil(release.assetURL)
        XCTAssertNil(release.sha256)
    }

    /// `blockedVersions` manifestin KENDİ sürümünü değil, KURULU sürümü anlatır —
    /// bu yüzden manifest bayatken de okunur ve API yolundaki sonuca taşınır.
    func testUpdateResolve_BlockedCurrentSurvivesALaggingManifest() {
        let r = UpdateChecker.resolve(current: "1.5",
                                      manifest: manifest(version: "1.4", blocked: ["v1.5"]),
                                      api: apiRelease("1.6"),
                                      channel: "stable",
                                      os: sonoma)
        guard case .updateAvailable(_, let release) = r else { return XCTFail("gelen: \(r)") }
        XCTAssertEqual(release.version, "1.6")
        XCTAssertTrue(release.blockedCurrent, "sorunlu işaret bayat manifestte de geçerlidir")
    }

    /// Kurulu sürüm sorunlu DEĞİLSE ve yenisi de yoksa sonuç sade "güncel"dir.
    func testUpdateResolve_UpToDateWhenNothingIsWrong() {
        XCTAssertEqual(UpdateChecker.resolve(current: "1.6",
                                             manifest: manifest(version: "1.6"),
                                             api: apiRelease("1.6"),
                                             channel: "stable", os: sonoma),
                       .upToDate(current: "1.6"))
    }

    /// `decide()` 0. kuralı `latest == current` iken de çalışmalı: sorunlu sürüm
    /// uyarısını taşıyan tek yol o. Kural 1'in `guard`ı önce dönseydi uyarı ölürdü.
    func testUpdatePrompt_BlockedCurrentShowsWithNoNewerVersion() {
        XCTAssertEqual(decide(current: "1.6", latest: "1.6", blocked: true), .show)
    }

    // MARK: - minimumOS kapısı

    /// Manifest macOS 15 istiyorsa macOS 14'teki kullanıcıya İNDİRME SUNULMAZ.
    /// Aksi halde ~60 MB iner, dört kapıdan da geçer, kurulur ve AÇILMAZ.
    func testUpdateResolve_MinimumOSClosesTheDownloadButDoesNotSilence() {
        let m = manifest(version: "1.6", minimumOS: "15.0")
        let blocked = UpdateChecker.resolve(current: "1.5", manifest: m, api: apiRelease("1.6"),
                                            channel: "stable", os: sonoma)
        guard case .updateAvailable(_, let release) = blocked else {
            return XCTFail("sürüm GERÇEKTEN var — susmak yalan olurdu, gelen: \(blocked)")
        }
        XCTAssertNil(release.assetURL, "macOS yetmiyorken indirme adresi verilmemeli")
        XCTAssertNil(release.sha256)
        XCTAssertEqual(release.requiredOS, "15.0", "arayüz nedeni söyleyebilmeli")

        // Aynı manifest, yeterli macOS → indirme açık
        let ok = UpdateChecker.resolve(current: "1.5", manifest: m, api: apiRelease("1.6"),
                                       channel: "stable", os: sequoia)
        guard case .updateAvailable(_, let okRelease) = ok else { return XCTFail("gelen: \(ok)") }
        XCTAssertNotNil(okRelease.assetURL)
        XCTAssertNil(okRelease.requiredOS)
    }

    /// `minimumOS` manifestin KENDİ sürümünü anlatır. Manifest bayatken API'nin
    /// gösterdiği sürüme uygulanması, ilgisiz bir kısıtı dayatmak olurdu.
    func testUpdateResolve_MinimumOSDoesNotLeakOntoTheAPIVersion() {
        let r = UpdateChecker.resolve(current: "1.5",
                                      manifest: manifest(version: "1.4", minimumOS: "15.0"),
                                      api: apiRelease("1.6"),
                                      channel: "stable",
                                      os: sonoma)
        guard case .updateAvailable(_, let release) = r else { return XCTFail("gelen: \(r)") }
        XCTAssertEqual(release.version, "1.6")
        XCTAssertNil(release.requiredOS, "bayat manifestin minimumOS'u 1.6'yı bağlamaz")
    }

    // MARK: - Sürüm notu çözümleme (UpdateNotes)

    func testUpdateNotes_SplitsHeadingsBulletsAndRules() {
        let raw = """
        ## Yenilikler\r
        - İlk madde
        * İkinci madde
        3. Üçüncü madde

        ---

        Düz bir paragraf.
        """
        let (blocks, truncated) = UpdateNotes.render(raw)
        XCTAssertFalse(truncated)
        guard blocks.count == 6 else {
            return XCTFail("6 blok bekleniyordu, \(blocks.count) geldi")
        }
        XCTAssertEqual(blocks[0], .heading("Yenilikler"))   // \r\n normalize edilmeli
        if case .bullet(let a) = blocks[1] { XCTAssertEqual(String(a.characters), "İlk madde") }
        else { XCTFail("madde bekleniyordu") }
        if case .bullet = blocks[2] {} else { XCTFail("* maddesi bekleniyordu") }
        if case .bullet = blocks[3] {} else { XCTFail("numaralı madde bekleniyordu") }
        XCTAssertEqual(blocks[4], .rule)
        if case .paragraph = blocks[5] {} else { XCTFail("paragraf bekleniyordu") }
    }

    /// Boş satırlar blok ÜRETMEZ — aksi halde notların yarısı boş paragraf olurdu.
    func testUpdateNotes_BlankLinesCollapseAndEmptyInputYieldsNothing() {
        let (blocks, _) = UpdateNotes.render("\n\n\n   \n\n")
        XCTAssertTrue(blocks.isEmpty)
        XCTAssertTrue(UpdateNotes.render("").blocks.isEmpty)
        // Tek satır, boş satırlarla çevrili → tek blok
        XCTAssertEqual(UpdateNotes.render("\n\nmerhaba\n\n\n").blocks.count, 1)
    }

    func testUpdateNotes_TruncatesAtALineBoundary() {
        let raw = (1...200).map { "satır \($0) ------------------------------" }.joined(separator: "\n")
        let (blocks, truncated) = UpdateNotes.render(raw, limit: 300)
        XCTAssertTrue(truncated)
        XCTAssertFalse(blocks.isEmpty)
        // Kesme satır sınırında: son blok yarım bir satır olmamalı
        let text = UpdateNotes.plainText(blocks)
        XCTAssertTrue(text.hasSuffix("------"), "satır ortasından kesilmiş: \(text.suffix(40))")
        XCTAssertLessThanOrEqual(text.count, 300)
        // Sınırın altındaki metin hiç kısaltılmaz
        XCTAssertFalse(UpdateNotes.render("kısa", limit: 300).truncated)
    }

    /// Sürüm notu UYGULAMANIN DIŞINDA yazılmış, ağdan gelen metindir. `file://`
    /// ya da özel şemalı bir bağlantı tıklanabilir kalmamalı.
    func testUpdateNotes_StripsNonHTTPLinks() {
        // Markdown çözümleyicisi file:// ve javascript: bağlantılarını GERÇEKTEN üretir —
        // süzgeç olmasa üçü de tıklanabilir kalırdı.
        let (blocks, _) = UpdateNotes.render(
            "[zararsız](https://example.com) [dosya](file:///etc/passwd) [betik](javascript:x)")
        guard case .paragraph(let attributed) = blocks.first else {
            return XCTFail("paragraf bekleniyordu")
        }
        let links = attributed.runs.compactMap { $0.link?.scheme }
        XCTAssertEqual(links, ["https"], "http(s) dışı şema tıklanabilir kaldı: \(links)")
        // Metin KAYBOLMAZ, yalnızca bağlantılığı gider
        XCTAssertTrue(String(attributed.characters).contains("dosya"))
        XCTAssertTrue(String(attributed.characters).contains("betik"))
    }

    /// Süzgeç doğrudan: elle kurulmuş bir `file://` bağlantısı da düşürülmeli.
    func testUpdateNotes_StripUnsafeLinksKeepsTextDropsScheme() {
        var safe = AttributedString("güvenli ")
        safe.link = URL(string: "https://x.example")
        var unsafe = AttributedString("tehlikeli")
        unsafe.link = URL(string: "file:///etc/passwd")
        var combined = safe + unsafe
        XCTAssertEqual(combined.runs.compactMap { $0.link }.count, 2)

        UpdateNotes.stripUnsafeLinks(&combined)
        XCTAssertEqual(combined.runs.compactMap { $0.link?.scheme }, ["https"])
        XCTAssertEqual(String(combined.characters), "güvenli tehlikeli")
    }

    func testUpdateNotes_LineClassifiersAreStrict() {
        XCTAssertTrue(UpdateNotes.isRule("---"))
        XCTAssertTrue(UpdateNotes.isRule("***"))
        XCTAssertFalse(UpdateNotes.isRule("--"))
        XCTAssertFalse(UpdateNotes.isRule("-*-"))
        XCTAssertEqual(UpdateNotes.headingText("### Başlık"), "Başlık")
        XCTAssertNil(UpdateNotes.headingText("#Boşluksuz"))         // Markdown değil
        XCTAssertNil(UpdateNotes.headingText("####### Yedi diyez"))  // en fazla 6
        XCTAssertEqual(UpdateNotes.bulletText("- madde"), "madde")
        XCTAssertEqual(UpdateNotes.bulletText("12. madde"), "madde")
        XCTAssertNil(UpdateNotes.bulletText("-tire, madde değil"))
        XCTAssertNil(UpdateNotes.bulletText("2026. yılında"))        // 4 hane → numaralı madde değil
    }

    // MARK: - AppSettings: güncelleme alanları

    /// **VARSAYILANLAR BORU HATTINI ULAŞILABİLİR BIRAKMALI.** `updateMode` `notify`
    /// iken bildirim penceresinin ana düğmesi yalnızca sürüm sayfasını açar
    /// (`UpdatePromptView.primaryAction`), yani kutudan çıktığı hâliyle indirme +
    /// sha256 + codesign + Team ID + noter onayı zincirini HİÇBİR kullanıcı görmezdi.
    /// İki alan iki ayrı soruyu yanıtlar ve varsayılanları bilerek farklı yönde:
    /// düğme indirmeyi SUNAR, ama tıklanmadan hiçbir şey İNMEZ.
    func testAppSettings_UpdateFieldDefaults() {
        let s = AppSettings()
        XCTAssertEqual(s.updateChannel, "stable")
        XCTAssertTrue(s.updateAutoCheck)
        XCTAssertFalse(s.updateAutoDownload)          // indirme kullanıcının bilinçli tercihi
        XCTAssertEqual(s.updateMode, "download")
        XCTAssertNotEqual(s.updateMode, UpdateMode.notify.rawValue,
                          "varsayılan `notify` olursa indirme/doğrulama boru hattı ULAŞILAMAZ")
        // Pencerenin ana düğmesinin indirmeyi sunması için gereken tam koşul
        XCTAssertNotEqual(UpdateMode.from(s.updateMode), .notify)
        XCTAssertEqual(s.updateSkippedVersion, "")
        XCTAssertEqual(s.updateSnoozeUntil, 0)
        XCTAssertEqual(s.updateLastCheck, 0)
    }

    /// GÜNCELLEME ALANLARINDAN ÖNCEKİ bir settings.json hâlâ çözülmeli.
    func testAppSettings_PreUpdateJSONStillDecodes() throws {
        let legacy = """
        {"defaultPHPVersion":"8.4","autoStartServices":true,"mcpServerPort":9000}
        """
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(s.defaultPHPVersion, .v84)
        XCTAssertTrue(s.autoStartServices)
        XCTAssertEqual(s.mcpServerPort, 9000)
        // Yeni alanlar varsayılana düşer, throw YOK
        XCTAssertEqual(s.updateChannel, "stable")
        XCTAssertTrue(s.updateAutoCheck)
        XCTAssertEqual(s.updateSnoozeUntil, 0)
        // Eski dosyadan gelen kullanıcı da boru hattını görebilmeli — çözme yolundaki
        // varsayılan `init()` ile AYNI olmalı, yoksa aynı ürünün iki farklı davranışı olur.
        XCTAssertEqual(s.updateMode, AppSettings().updateMode)
        XCTAssertNotEqual(UpdateMode.from(s.updateMode), .notify)
    }

    func testAppSettings_UpdateFieldsSurviveARoundTrip() throws {
        var s = AppSettings()
        s.updateChannel        = "beta"
        s.updateAutoCheck      = false
        s.updateAutoDownload   = true
        s.updateMode           = "downloadAndOpen"
        s.updateSkippedVersion = "1.6"
        s.updateSnoozeUntil    = 1_800_000_000
        s.updateLastCheck      = 1_700_000_000
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.updateChannel, "beta")
        XCTAssertFalse(back.updateAutoCheck)
        XCTAssertTrue(back.updateAutoDownload)
        XCTAssertEqual(back.updateMode, "downloadAndOpen")
        XCTAssertEqual(back.updateSkippedVersion, "1.6")
        XCTAssertEqual(back.updateSnoozeUntil, 1_800_000_000)
        XCTAssertEqual(back.updateLastCheck, 1_700_000_000)
        XCTAssertEqual(UpdateMode.from(back.updateMode), .downloadAndOpen)
        XCTAssertEqual(UpdateMode.from("uydurma"), .notify)
    }

    /// Açılışta kendiliğinden pencere açma kapısı — test ana uygulamasında KAPALI.
    func testProcessRole_TestHostMayNotPresentLaunchUI() {
        XCTAssertFalse(ProcessRole.mayPresentLaunchUI,
                       "test ana uygulaması açılışta pencere göstermemeli")
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

    // MARK: - Tünel sahiplik / eşitleme / durdurma
    //
    // Bu bölüm, aynı $HOME'u paylaşan iki BRAMPP kopyasının birbirinin canlı
    // tünelini öldürmesi olayının düzeltmelerini kilitler. Hepsi gerçek makineye
    // DOKUNMADAN koşar: süreç sorgusu, dizin listesi ve mtime enjekte edilir.

    /// Yardımcı — testlerde kayıt kurmak için.
    private func makeTunnel(_ name: String, pid: Int?, state: Tunnel.State,
                            startedAt: Date, url: String? = nil) -> Tunnel {
        Tunnel(domainName: name, origin: "http://127.0.0.1:8080",
               publicURL: url, pid: pid, startedAt: startedAt, state: state)
    }

    // MARK: reconcile — ölü tespiti

    /// `kill(pid,0)` başarısızlığı KESİN sonuçtur: süreç yoksa kayıt ölüdür.
    func testReconcile_DeadWhenProcessGone() {
        let now = Date()
        let table = [
            "live.test": makeTunnel("live.test", pid: 111, state: .active,
                                    startedAt: now, url: "https://a.trycloudflare.com"),
            "gone.test": makeTunnel("gone.test", pid: 222, state: .active,
                                    startedAt: now, url: "https://b.trycloudflare.com"),
        ]
        let dead = TunnelManager.deadCandidates(in: table, now: now, isAlive: { $0 == 111 })
        XCTAssertEqual(dead, ["gone.test"])
    }

    /// PID'i henüz yazılmamış `.starting` kaydı, adres + DNS beklemesinin TOPLAMI
    /// dolmadan ölü SAYILMAZ — `start` akışı hâlâ sürüyor olabilir.
    func testReconcile_FreshStartingRecordIsNotDead() {
        let now = Date()
        let table = ["boot.test": makeTunnel("boot.test", pid: nil, state: .starting,
                                             startedAt: now.addingTimeInterval(-5))]
        XCTAssertTrue(TunnelManager.deadCandidates(in: table, now: now, isAlive: { _ in true }).isEmpty)
    }

    /// Aynı kayıt beklemenin toplamını aşmışsa takılı kalmıştır — sonsuza kadar
    /// "başlatılıyor" göstermemeli.
    func testReconcile_StuckStartingRecordIsDead() {
        let now = Date()
        let stale = now.addingTimeInterval(-(TunnelManager.urlTimeout + TunnelManager.dnsTimeout + 1))
        let table = ["stuck.test": makeTunnel("stuck.test", pid: nil, state: .starting, startedAt: stale)]
        XCTAssertEqual(TunnelManager.deadCandidates(in: table, now: now, isAlive: { _ in true }),
                       ["stuck.test"])
    }

    /// Zaten `.failed` işaretli kayıt tekrar ölü ilan edilmez — yoksa her turda
    /// yeni bir "paylaşım sona erdi" satırı yazılırdı.
    func testReconcile_FailedRecordIsSkipped() {
        let now = Date()
        let table = ["dead.test": makeTunnel("dead.test", pid: 5, state: .failed("süreç yok"),
                                             startedAt: now.addingTimeInterval(-10_000))]
        XCTAssertTrue(TunnelManager.deadCandidates(in: table, now: now, isAlive: { _ in false }).isEmpty)
    }

    /// `ps -o pid=,comm=` çıktısında yalnızca comm'u cloudflared olan PID doğrulanır;
    /// geri dönüştürülmüş numarada oturan başka bir süreç canlı sayılmaz.
    func testReconcile_ConfirmsIdentityFromPsOutput() {
        let out = " 111 cloudflared\n 222 Google Chrome Helper\n 333 cloudflared\n"
        XCTAssertEqual(TunnelManager.parseCloudflaredPIDs(from: out), [111, 333])
    }

    // MARK: markDead — kuşak (generation) denetimi

    /// GERİLEME TESTİ: `reconcile` ölü listesini `ps` beklemesinden ÖNCE hesaplar,
    /// uygular ise SONRA. O pencerede aynı alan adı yeniden paylaşıma açılırsa eski
    /// karar YENİ kaydı bozmamalı — yoksa geriye pid'i unutulmuş, dosyası silinmiş,
    /// ama internete AÇIK bir tünel kalır.
    func testMarkDead_DoesNotTouchRestartedRecord() {
        let manager = TunnelManager(consoleStore: ConsoleStore())
        let observed = makeTunnel("race.invalid", pid: 111, state: .active,
                                  startedAt: Date(timeIntervalSince1970: 1_000),
                                  url: "https://old.trycloudflare.com")
        // `ps` beklemesi sırasında yeniden başlatılmış YENİ kayıt
        let restarted = makeTunnel("race.invalid", pid: 222, state: .starting,
                                   startedAt: Date(timeIntervalSince1970: 2_000))
        manager.setTunnelsForTesting(["race.invalid": restarted])

        manager.markDead("race.invalid", observed: observed)

        let current = manager.tunnel(for: "race.invalid")
        XCTAssertEqual(current?.pid, 222, "yeni kaydın PID'i unutulmamalıydı")
        XCTAssertEqual(current?.state, .starting, "yeni kayıt ölü işaretlenmemeliydi")
    }

    /// Kayıt DEĞİŞMEMİŞSE karar uygulanır — düzeltme, gerçek ölümleri kaçırmamalı.
    func testMarkDead_AppliesToUnchangedRecord() {
        let manager = TunnelManager(consoleStore: ConsoleStore())
        let record = makeTunnel("dead.invalid", pid: 111, state: .active,
                                startedAt: Date(timeIntervalSince1970: 1_000),
                                url: "https://x.trycloudflare.com")
        manager.setTunnelsForTesting(["dead.invalid": record])

        manager.markDead("dead.invalid", observed: record)

        let current = manager.tunnel(for: "dead.invalid")
        XCTAssertNil(current?.pid)
        XCTAssertNil(current?.publicURL)
        XCTAssertFalse(current?.isLive ?? true)
    }

    /// Kimlik ölçütü: `startedAt` kuşak jetonu + PID.
    func testMarkDead_IdentityPredicate() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = Date(timeIntervalSince1970: 2_000)
        let a = makeTunnel("x", pid: 111, state: .active, startedAt: t0)
        XCTAssertTrue(TunnelManager.deadRecordStillApplies(observed: a, current: a))
        // Aynı kuşak ama PID sonradan yazılmış (yer tutucu → gerçek süreç)
        XCTAssertFalse(TunnelManager.deadRecordStillApplies(
            observed: makeTunnel("x", pid: nil, state: .starting, startedAt: t0), current: a))
        // Yeni kuşak
        XCTAssertFalse(TunnelManager.deadRecordStillApplies(
            observed: a, current: makeTunnel("x", pid: 111, state: .active, startedAt: t1)))
        // Kayıt tamamen silinmiş
        XCTAssertFalse(TunnelManager.deadRecordStillApplies(observed: a, current: nil))
    }

    // MARK: Sahiplik — açılış toparlaması ve çıkış kapatması

    /// Açılış toparlaması BU sürecin tünellerine dokunmaz; sahipsiz olanları öldürür,
    /// süreci olmayan kayıtların yalnızca dosyalarını siler.
    func testReap_SparesOwnedPIDs() {
        let decision = TunnelManager.reapDecision(
            entries: ["mine.test": 111, "orphan.test": 222, "stale.test": 333, "junk.test": nil],
            isAlive: { $0 != 333 },
            owned: [111])
        XCTAssertEqual(decision.kill, ["orphan.test": 222], "yalnızca sahipsiz canlı süreç öldürülür")
        XCTAssertEqual(decision.discard, ["junk.test", "stale.test"])
        XCTAssertNil(decision.kill["mine.test"], "bu sürecin canlı tüneline DOKUNULMAZ")
    }

    /// Sahiplik kaydı PID → dizin anahtarı eşlemesini taşır: çıkışta hangi
    /// `.pid`/`.log` dosyalarının bize ait olduğu ancak böyle bilinir.
    func testOwnership_RegistryTracksKeys() {
        TunnelManager.resetOwnedForTesting()
        defer { TunnelManager.resetOwnedForTesting() }

        TunnelManager.rememberOwned(4242, key: "mine.test")
        XCTAssertTrue(TunnelManager.isOwned(4242))
        XCTAssertEqual(TunnelManager.ownedSnapshot[4242], "mine.test")
        XCTAssertFalse(TunnelManager.isOwned(4243), "başka sürecin PID'i sahiplenilmiş görünmemeli")

        TunnelManager.forgetOwned(4242)
        XCTAssertFalse(TunnelManager.isOwned(4242))
        XCTAssertTrue(TunnelManager.ownedSnapshot.isEmpty)
    }

    /// GERİLEME TESTİ (asıl hatanın çıkış yoluna taşınmış hâli): çıkış kapatması
    /// dizini SÜPÜRMEZ. Sahiplik kaydı boşken tünel dizinindeki yabancı bir kayıt
    /// olduğu gibi durmalı — eski kod onu siler, canlıysa SIGTERM gönderirdi.
    func testExitSweep_LeavesForeignTunnelRecordsAlone() {
        TunnelManager.resetOwnedForTesting()
        let key  = "brampp-unit-test-foreign.invalid"
        let path = PathConfig.tunnelPid(domain: key)
        defer { _ = FileHelper.remove(path) }

        _ = FileHelper.createDirectory(PathConfig.tunnels)
        // Ölü ama var olmayan bir numara: eski süpürme bunu "artık" sayıp dosyayı
        // silerdi. Sinyal gönderilmesi mümkün değil (böyle bir süreç yok).
        XCTAssertTrue(FileHelper.write("999999", to: path))

        TunnelManager.killAllSynchronously(waitForExit: false)

        XCTAssertTrue(FileHelper.exists(path),
                      "çıkış kapatması SAHİPLENİLMEMİŞ bir tünel kaydına dokunmamalı")
    }

    // MARK: stop — SIGTERM → SIGKILL yükseltmesi

    /// Sahte süreç denetimi: gerçek makineye sinyal göndermeden yükseltmeyi sınar.
    private final class FakeProcess {
        var alive = true
        var isCloudflared = true
        /// SIGTERM'i yutuyor mu? (cloudflared'in 30 sn'lik grace-period'ü bunu gerçek yapar)
        var ignoresTerm = false
        var immortal = false
        private(set) var signals: [Int32] = []

        func control() -> TunnelManager.ProcessControl {
            TunnelManager.ProcessControl(
                isAlive: { [self] _ in alive },
                isCloudflared: { [self] _ in isCloudflared },
                signal: { [self] _, sig in
                    signals.append(sig)
                    if immortal { return }
                    if sig == SIGKILL { alive = false }
                    if sig == SIGTERM && !ignoresTerm { alive = false }
                },
                tick: { _ in }
            )
        }
    }

    func testStop_SigtermIsEnough() async {
        let fake = FakeProcess()
        let outcome = await TunnelManager.terminate(pid: 1, control: fake.control(),
                                                    graceSeconds: 0.2, killSeconds: 0.2, step: 0.01)
        XCTAssertEqual(outcome, .terminated)
        XCTAssertEqual(fake.signals, [SIGTERM], "gereksiz yere SIGKILL gönderilmemeli")
        XCTAssertTrue(outcome.isGone)
    }

    /// GERİLEME TESTİ: SIGTERM'i yutan cloudflared SIGKILL ile alınır. Eski kodda
    /// yükseltme YOKTU; 0,4 sn bekleyip yine de "durduruldu" yazıyordu.
    func testStop_EscalatesToSigkill() async {
        let fake = FakeProcess()
        fake.ignoresTerm = true
        let outcome = await TunnelManager.terminate(pid: 1, control: fake.control(),
                                                    graceSeconds: 0.2, killSeconds: 0.2, step: 0.01)
        XCTAssertEqual(outcome, .killed)
        XCTAssertEqual(fake.signals, [SIGTERM, SIGKILL])
        XCTAssertTrue(outcome.isGone, "süreç gerçekten gitti → kayıt ve PID dosyası silinebilir")
    }

    /// GERİLEME TESTİ: hiçbir sinyal işe yaramadıysa BAŞARI BİLDİRİLMEZ. `isGone`
    /// false olduğu sürece `stop` kaydı silmez ve "durduruldu" satırını yazmaz —
    /// yayında olan bir adresin tutamağı kaybolmamalı.
    func testStop_ReportsFailureWhenProcessSurvives() async {
        let fake = FakeProcess()
        fake.immortal = true
        let outcome = await TunnelManager.terminate(pid: 1, control: fake.control(),
                                                    graceSeconds: 0.1, killSeconds: 0.1, step: 0.01)
        XCTAssertEqual(outcome, .survived)
        XCTAssertFalse(outcome.isGone)
        XCTAssertEqual(fake.signals, [SIGTERM, SIGKILL], "yükseltme yine de denenmiş olmalı")
    }

    /// PID geri dönüştürülmüşse HİÇBİR sinyal gönderilmez — başkasının süreci öldürülmez.
    func testStop_NeverSignalsARecycledPID() async {
        let fake = FakeProcess()
        fake.isCloudflared = false
        let outcome = await TunnelManager.terminate(pid: 1, control: fake.control(),
                                                    graceSeconds: 0.1, killSeconds: 0.1, step: 0.01)
        XCTAssertEqual(outcome, .notRunning)
        XCTAssertTrue(fake.signals.isEmpty, "cloudflared olmayan bir PID'e sinyal GÖNDERİLMEZ")
        XCTAssertTrue(outcome.isGone, "bize ait olmayan kayıt temizlenebilir")
    }

    // MARK: stopAll — ölü kayıtlara sahte "durduruldu" satırı yazılmaz

    func testStopAll_SkipsAlreadyFailedRecords() {
        let now = Date()
        let table = [
            "live.test":   makeTunnel("live.test", pid: 1, state: .active, startedAt: now,
                                      url: "https://a.trycloudflare.com"),
            "boot.test":   makeTunnel("boot.test", pid: nil, state: .starting, startedAt: now),
            "dead.test":   makeTunnel("dead.test", pid: nil, state: .failed("süreç yok"), startedAt: now),
        ]
        let targets = TunnelManager.stopTargets(in: table)
        XCTAssertEqual(targets.stop, ["boot.test", "live.test"],
                       "adres bekleyen paylaşım da durdurulabilmeli")
        XCTAssertEqual(targets.discard, ["dead.test"],
                       "ölü kayıt sessizce düşmeli — sahte 'durduruldu' satırı yazılmamalı")
    }

    // MARK: start — aynı ad için eşzamanlı ikinci süreç doğurulmaz

    /// GERİLEME TESTİ: eski kod yalnızca `isLive` durumunda kısa devre yapıyordu;
    /// `.starting` bir kayıt varken ikinci çağrı İKİNCİ bir cloudflared başlatıyor ve
    /// birincisi takipsiz kalıyordu.
    func testStart_SecondCallIsRefusedWhileFirstIsStarting() {
        let now = Date()
        let starting = makeTunnel("x.test", pid: 123, state: .starting,
                                  startedAt: now.addingTimeInterval(-3))
        XCTAssertEqual(TunnelManager.startConflict(existing: starting, now: now), .inProgress)
    }

    func testStart_LiveShareShortCircuits() {
        let now = Date()
        let live = makeTunnel("x.test", pid: 1, state: .active, startedAt: now,
                              url: "https://a.trycloudflare.com")
        XCTAssertEqual(TunnelManager.startConflict(existing: live, now: now), .alreadyLive)
    }

    /// Takılı kalmış `.starting` kaydı yeniden denemeyi SONSUZA KADAR engellememeli;
    /// önce eski süreç kapatılır (`.stale`).
    func testStart_StuckStartingAllowsRetryAfterCleanup() {
        let now = Date()
        let stale = makeTunnel("x.test", pid: 123, state: .starting,
                               startedAt: now.addingTimeInterval(-(TunnelManager.urlTimeout + TunnelManager.dnsTimeout + 1)))
        XCTAssertEqual(TunnelManager.startConflict(existing: stale, now: now), .stale)
    }

    func testStart_NoRecordOrFailedRecordDoesNotConflict() {
        let now = Date()
        XCTAssertNil(TunnelManager.startConflict(existing: nil, now: now))
        XCTAssertNil(TunnelManager.startConflict(
            existing: makeTunnel("x.test", pid: nil, state: .failed("süreç yok"), startedAt: now),
            now: now))
    }

    // MARK: Sahipsiz log temizliği

    /// PID dosyası olan log'a DOKUNULMAZ (tünel yaşıyor); sahipsiz olan yalnızca
    /// yaş sınırını aşarsa silinir — bugünkü kanıt durur, geçen haftaki gider.
    func testStrandedLogs_OnlyOldOwnerlessLogsAreRemoved() {
        let now = Date()
        let names = ["live.test.pid", "live.test.log", "old.test.log", "recent.test.log"]
        let ages: [String: Date] = [
            "live.test":   now.addingTimeInterval(-30 * 86_400),
            "old.test":    now.addingTimeInterval(-30 * 86_400),
            "recent.test": now.addingTimeInterval(-1 * 86_400),
        ]
        let targets = TunnelManager.strandedLogTargets(names: names, now: now, retentionDays: 7,
                                                       modified: { ages[$0] })
        XCTAssertEqual(targets, ["old.test"])
    }

    /// mtime okunamayan dosya silinmez — bilinmeyen yaş, silme gerekçesi değildir.
    func testStrandedLogs_UnknownAgeIsKept() {
        let targets = TunnelManager.strandedLogTargets(names: ["mystery.test.log"], now: Date(),
                                                       retentionDays: 7, modified: { _ in nil })
        XCTAssertTrue(targets.isEmpty)
    }

    // MARK: Paylaşılan konsol dosyasında süreç kimliği

    /// Dosya adı yalnızca TARİHE bağlı: kurulu uygulama, Xcode derlemesi, XCTest ana
    /// uygulaması ve önizlemeler aynı dosyaya yazar. Satır KİMİN yazdığını söylemeli —
    /// olayın teşhisini bu eksiklik günlerce geciktirdi.
    func testConsoleLogFile_LineIdentifiesTheWritingProcess() {
        let out = ConsoleLogFile.format(date: Date(), level: "INFO", text: "bir\niki",
                                        process: "app 1689")
        for line in out.split(separator: "\n") {
            XCTAssertTrue(line.contains("(app 1689)"), "her satır yazan süreci taşımalı: \(line)")
        }
        // Varsayılan imza da boş olmamalı ve PID içermeli.
        XCTAssertTrue(ProcessRole.signature.contains("\(ProcessInfo.processInfo.processIdentifier)"))
    }

    /// Testler ORTAK ortama yazmamalı — düzeltmenin kalbi bu. Test ana uygulamasında
    /// kapı kapalı olmalı (bu test zaten bir XCTest ana uygulamasında koşuyor).
    func testProcessRole_TestHostMayNotMutateSharedEnvironment() {
        XCTAssertTrue(ProcessRole.isTestHost, "bu süreç bir XCTest ana uygulaması")
        XCTAssertFalse(ProcessRole.mayMutateSharedEnvironment,
                       "test ana uygulaması makinenin ortak durumuna yazmamalı")
        XCTAssertFalse(TunnelManager.reapOrphansAtLaunch(),
                       "test ana uygulaması tünel dizinini toparlamamalı")
    }

    // MARK: - Kaldırma planı: yapılandırma mı, VERİ mi?

    /// Onay diyaloğu tek bir sabit cümleydi: "Paket ve yapılandırma dosyaları silinecek."
    /// Oysa betik `var/mysql`i `rm -rf` ediyordu — geliştiricinin kendi makinesinde
    /// 29 veritabanı. Plan artık veriyi AYRI sınıflandırır ve adıyla söyler.
    func testUninstall_MariaDBReportsTheDataDirectory() {
        let plan = ServiceManager.uninstallPlan(forServiceID: "mariadb", brewPrefix: "/brewtest")
        XCTAssertTrue(plan.destroysData, "mariadb kaldırma VERİ siler")
        XCTAssertEqual(plan.dataPaths, ["/brewtest/var/mysql"])
        XCTAssertTrue(plan.configurationPaths.contains("/brewtest/etc/my.cnf"))
        XCTAssertFalse(plan.configurationPaths.contains("/brewtest/var/mysql"),
                       "veri dizini yapılandırma diye gösterilmemeli")
        XCTAssertEqual(plan.dataWarningKey, "svc.uninstall.dataWarn.databases")
    }

    func testUninstall_PostgresClusterIsData() {
        let plan = ServiceManager.uninstallPlan(forServiceID: "postgresql@17", brewPrefix: "/brewtest")
        XCTAssertTrue(plan.destroysData)
        XCTAssertEqual(plan.dataPaths, ["/brewtest/var/postgresql@17"])
        XCTAssertEqual(plan.configurationPaths, ["/brewtest/etc/postgresql@17"])
        XCTAssertEqual(plan.dataWarningKey, "svc.uninstall.dataWarn.databases")
    }

    /// site-packages kullanıcının pip ile kurduğu HER ŞEYDİR; `opt/` ise brew'un
    /// paket dizini. İkisi aynı kefeye konmamalı.
    func testUninstall_PythonSitePackagesAreData() {
        let plan = ServiceManager.uninstallPlan(forServiceID: "python@3.12", brewPrefix: "/brewtest")
        XCTAssertTrue(plan.destroysData)
        XCTAssertEqual(plan.dataPaths, ["/brewtest/lib/python3.12",
                                        "/brewtest/Frameworks/Python.framework/Versions/3.12"])
        XCTAssertEqual(plan.configurationPaths, ["/brewtest/opt/python@3.12"])
        XCTAssertEqual(plan.dataWarningKey, "svc.uninstall.dataWarn.packages")
    }

    /// Veri silmeyen servislerde EK SÜRTÜNME OLMAMALI — yazarak onay yalnızca
    /// gerçekten kaybedilecek bir şey varken istenir.
    func testUninstall_SafeServicesDestroyNoData() {
        for id in ["httpd", "nginx", "redis", "memcached", "php@8.3", "node@22", "dotnet@8", "cloudflared"] {
            let plan = ServiceManager.uninstallPlan(forServiceID: id, brewPrefix: "/brewtest")
            XCTAssertFalse(plan.destroysData, "\(id) veri silmemeli")
            XCTAssertTrue(plan.dataPaths.isEmpty, "\(id)")
            XCTAssertNil(plan.dataWarningKey, "\(id)")
        }
    }

    /// Betiğe giden SIRA ve KÜME değişmemeli: sınıflandırma eklendi, silinen yollar aynı.
    func testUninstall_ScriptPathsAreUnchangedAndFullyClassified() {
        let plan = ServiceManager.uninstallPlan(forServiceID: "mariadb", brewPrefix: "/brewtest")
        XCTAssertEqual(Array(plan.allPaths.prefix(2)),
                       ["/brewtest/etc/my.cnf", "/brewtest/var/mysql"],
                       "betik sırası korunmalı")
        XCTAssertEqual(Set(plan.allPaths),
                       Set(plan.configurationPaths).union(plan.dataPaths),
                       "her yol tam olarak bir sınıfa düşmeli")
        XCTAssertEqual(plan.allPaths.count, plan.configurationPaths.count + plan.dataPaths.count)
    }

    /// Diyalog ile betik AYRIŞAMAZ: betiğin GERÇEKTEN sildiği/düzenlediği her yol onay
    /// metninde adıyla geçer — ve ölçüm betiğin METNİ üzerinde yapılır.
    ///
    /// Eski hâli totolojikti: aynı plan nesnesinden üretilen mesajı yine o planın
    /// yollarıyla karşılaştırıyordu. Betiğe elle gömülmüş `rm -rf "…/share/phpmyadmin"`
    /// ile `sed -i '' … httpd.conf` ikisi de plan dışındaydı ve test bunu göremiyordu.
    func testUninstall_ScriptTouchesNothingOutsideThePlan() {
        let base = "/brewtest"
        let cases: [(id: String, name: String, brew: String)] = [
            ("mariadb", "MariaDB", "mariadb"),
            ("httpd", "Apache", "httpd"),
            ("nginx", "Nginx", "nginx"),
            ("postgresql@16", "PostgreSQL 16", "postgresql@16"),
            ("python@3.13", "Python 3.13", "python@3.13"),
            ("node@22", "Node.js 22", "node@22"),
            ("redis", "Redis", "redis"),
            ("memcached", "Memcached", "memcached")
        ]
        for c in cases {
            let plan   = ServiceManager.uninstallPlan(forServiceID: c.id, brewPrefix: base)
            let script = ServiceManager.uninstallScript(serviceID: c.id, serviceName: c.name,
                                                        brewName: c.brew, brewPrefix: base)
            let message = plan.confirmationMessage { $0 }   // çeviri yerine anahtarın kendisi

            // 1) Temizlik listesi ile plan aynı kaynaktan gelmeli
            XCTAssertEqual(ServiceManager.uninstallCleanupPaths(forServiceID: c.id, brewPrefix: base),
                           plan.allPaths, "\(c.id): betiğe giden liste planla aynı olmalı")

            // 2) Betiğin sildiği yollar = planın yolları (iki yönlü)
            let removed = doubleQuotedTargets(after: "rm -rf ", in: script)
            XCTAssertEqual(Set(removed), Set(plan.allPaths),
                           "\(c.id): betiğin rm -rf hedefleri planla birebir aynı olmalı")

            // 3) Betiğin `sed -i ''` ile DÜZENLEDİĞİ dosyalar = planın editedPaths'i
            let edited = doubleQuotedTargets(after: "sed -i '' ", in: script)
            XCTAssertEqual(Set(edited), Set(plan.editedPaths),
                           "\(c.id): betiğin düzenlediği dosyalar planda bildirilmeli")

            // 4) Ve hepsi onay metninde adıyla geçmeli
            for path in plan.allPaths + plan.editedPaths {
                XCTAssertTrue(message.contains(path), "\(c.id): \(path) onay metninde yok")
            }
        }
    }

    /// `rm -rf "X"` / `sed -i '' … "X"` gibi satırlardan çift tırnaklı ilk hedefi çıkarır.
    private func doubleQuotedTargets(after marker: String, in script: String) -> [String] {
        script.components(separatedBy: .newlines).compactMap { line -> String? in
            guard let m = line.range(of: marker) else { return nil }
            let rest = line[m.upperBound...]
            guard let open = rest.firstIndex(of: "\"") else { return nil }
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "\"") else { return nil }
            return String(rest[afterOpen..<close])
        }
    }

    /// MariaDB kaldırması phpMyAdmin'in web kökünü siliyor ve httpd.conf'u düzenliyordu;
    /// diyalog ikisini de hiç anmıyordu. Artık ikisi de planda ve metinde.
    func testUninstall_MariaDBDeclaresPhpMyAdminDirAndHttpdConfEdit() {
        let plan = ServiceManager.uninstallPlan(forServiceID: "mariadb", brewPrefix: "/brewtest")
        XCTAssertTrue(plan.configurationPaths.contains("/brewtest/share/phpmyadmin"),
                      "phpMyAdmin web kökü yapılandırma olarak bildirilmeli")
        XCTAssertFalse(plan.dataPaths.contains("/brewtest/share/phpmyadmin"),
                       "paket dizini kullanıcı verisi DEĞİL")
        XCTAssertEqual(plan.editedPaths, ["/brewtest/etc/httpd/httpd.conf"])
        // httpd.conf SİLİNMEZ — sadece düzenlenir. Silme listesinde görünürse felaket olur.
        XCTAssertFalse(plan.allPaths.contains("/brewtest/etc/httpd/httpd.conf"),
                       "httpd.conf rm -rf listesine SIZMAMALI")

        let message = plan.confirmationMessage { $0 }
        XCTAssertTrue(message.contains("svc.uninstall.editedHeader"),
                      "düzenlenen dosyalar ayrı başlıkta gösterilmeli")
    }

    func testUninstall_ConfirmationMessageSeparatesDataFromConfiguration() {
        let maria = ServiceManager.uninstallPlan(forServiceID: "mariadb", brewPrefix: "/brewtest")
            .confirmationMessage { $0 }
        XCTAssertTrue(maria.contains("svc.uninstall.dataHeader"), "VERİ başlığı olmalı")
        XCTAssertTrue(maria.contains("svc.uninstall.dataWarn.databases"),
                      "ne kaybedileceği somut söylenmeli")
        XCTAssertTrue(maria.contains("svc.uninstall.configHeader"))

        let redis = ServiceManager.uninstallPlan(forServiceID: "redis", brewPrefix: "/brewtest")
            .confirmationMessage { $0 }
        XCTAssertFalse(redis.contains("svc.uninstall.dataHeader"),
                       "veri silinmiyorsa VERİ başlığı gösterilmemeli")
        XCTAssertTrue(redis.contains("svc.uninstall.configHeader"))
    }

    /// httpd/nginx kaldırmasında vhost'lar KORUNUR — diyalog bunu da söylemeli.
    /// Önek PARAMETRE: bu test `brew --prefix` çağırmaz, geliştiricinin makinesine bağlı değildir.
    func testUninstall_PreservedPathsAreShown() {
        let plan = ServiceManager.uninstallPlan(forServiceID: "httpd", brewPrefix: "/brewtest")
        XCTAssertEqual(plan.preservedPaths, ["/brewtest/etc/httpd/VirtualHosts"])
        XCTAssertTrue(plan.confirmationMessage { $0 }.contains("/brewtest/etc/httpd/VirtualHosts"))
    }

    /// Plan GERÇEKTEN saf mı? Doküman "dosya sistemine dokunmaz" diyordu ama döndürdüğü
    /// her `PathConfig` sabiti `Shell.brewPrefix` üzerinden gerçek makineye bağlıydı.
    /// Verilen önek dışında hiçbir yol üretilmemeli.
    func testUninstall_PlanIsPureWithRespectToTheGivenPrefix() {
        for id in ["httpd", "nginx", "mariadb", "redis", "php@8.3",
                   "postgresql@17", "node@22", "python@3.12", "dotnet@8"] {
            let plan = ServiceManager.uninstallPlan(forServiceID: id, brewPrefix: "/brewtest")
            for path in plan.allPaths + plan.editedPaths + plan.preservedPaths {
                XCTAssertTrue(path.hasPrefix("/brewtest/"),
                              "\(id): \(path) verilen önekten türemiyor (gerçek brew önekine kaçmış)")
            }
        }
        // Aynı kimlik, farklı önek → farklı yollar. (Sabitlere bağlı olsaydı değişmezdi.)
        let a = ServiceManager.uninstallPlan(forServiceID: "mariadb", brewPrefix: "/opt/a")
        let b = ServiceManager.uninstallPlan(forServiceID: "mariadb", brewPrefix: "/opt/b")
        XCTAssertNotEqual(a.allPaths, b.allPaths)
    }

    /// Veri silen kaldırmalarda onay YAZILARAK verilir (db.deleteConfirm ile aynı fikir).
    func testUninstall_TypedConfirmationRequiresTheServiceName() {
        let plan = ServiceManager.uninstallPlan(forServiceID: "mariadb", brewPrefix: "/brewtest")
        XCTAssertTrue(plan.typedConfirmationMatches("MariaDB", serviceName: "MariaDB"))
        XCTAssertTrue(plan.typedConfirmationMatches("  mariadb ", serviceName: "MariaDB"),
                      "boşluk ve büyük/küçük harf önemsiz")
        XCTAssertFalse(plan.typedConfirmationMatches("", serviceName: "MariaDB"))
        XCTAssertFalse(plan.typedConfirmationMatches("maria", serviceName: "MariaDB"))
        XCTAssertFalse(plan.typedConfirmationMatches("evet", serviceName: "MariaDB"))
    }

    /// Veri silen kaldırma ASLA `.alert`e düşmemeli.
    ///
    /// `.alert`in actions ViewBuilder'ının sunumdan sonra yeniden değerlendirileceği
    /// SwiftUI'da garanti değildir: yazarak onay ya sonsuza dek kapalı bir düğmeye
    /// (MariaDB bir daha kaldırılamaz) ya da sessizce hiçbir şey yapmayan bir tıklamaya
    /// dönüşür. Yazarak onay yalnızca canlı binding'li sheet'te güvenlidir.
    func testUninstall_DataDestroyingServicesUseTheTypedConfirmationSheet() {
        for id in ["mariadb", "postgresql@16", "postgresql@17", "python@3.12", "python@3.13"] {
            let plan = ServiceManager.uninstallPlan(forServiceID: id, brewPrefix: "/brewtest")
            XCTAssertEqual(ServiceRowView.confirmationStyle(for: plan), .typedConfirmationSheet,
                           "\(id): veri silen kaldırma yazarak onay sheet'i kullanmalı")
        }
        // Veri silmeyenlerde EK SÜRTÜNME OLMAMALI — basit uyarı yeterli.
        for id in ["httpd", "nginx", "redis", "memcached", "php@8.3", "node@22", "dotnet@8"] {
            let plan = ServiceManager.uninstallPlan(forServiceID: id, brewPrefix: "/brewtest")
            XCTAssertEqual(ServiceRowView.confirmationStyle(for: plan), .simpleAlert, "\(id)")
        }
    }

    func testUninstall_DialogKeysAreLocalizedInBothLanguages() {
        let keys = ["svc.uninstall.dataHeader", "svc.uninstall.configHeader",
                    "svc.uninstall.editedHeader",
                    "svc.uninstall.preserved", "svc.uninstall.dataWarn.databases",
                    "svc.uninstall.dataWarn.packages", "svc.uninstall.dataWarn.generic",
                    "svc.uninstall.typeToConfirm", "svc.uninstall.dataTitle",
                    "svc.uninstall.mismatch", "svc.uninstall.matched", "svc.uninstall.fieldLabel"]
        for key in keys {
            guard let entry = L10n.catalog[key] else { XCTFail("\(key) katalogda yok"); continue }
            for lang in ["tr", "en"] {
                XCTAssertFalse((entry[lang] ?? "").isEmpty, "\(key) için \(lang) çevirisi boş")
            }
        }
    }

    // MARK: - Apache configtest yorumlama (sihirbaz)

    /// Sihirbaz üç ✅ basıyordu ve 15 denetiminin tamamı geçiyordu; oysa httpd hiç
    /// başlamıyordu. configtest çıktısı SEBEBİYLE birlikte okunmalı — sebep İKİNCİ satırda.
    func testConfigTest_StockSSLConfFailureNamesTheMissingCertificate() {
        let real = """
        AH00526: Syntax error on line 144 of /opt/homebrew/etc/httpd/extra/httpd-ssl.conf:
        SSLCertificateFile: file '/opt/homebrew/etc/httpd/server.crt' does not exist or is empty
        """
        let failure = Diagnostics.configTestFailure(output: real, exitOK: false)
        XCTAssertNotNil(failure, "bu çıktı BAŞARISIZ sayılmalı")
        XCTAssertTrue(failure?.contains("httpd-ssl.conf") ?? false, "hangi dosya söylenmeli")
        XCTAssertTrue(failure?.contains("server.crt") ?? false, "eksik olan şey söylenmeli")
        XCTAssertTrue(failure?.contains("does not exist") ?? false)
    }

    func testConfigTest_SyntaxOKIsNotAFailure() {
        XCTAssertNil(Diagnostics.configTestFailure(output: "Syntax OK\n", exitOK: true))
        // apachectl bazen 0 dönerken uyarı basar; ifade tek başına da yeterli olmalı
        XCTAssertNil(Diagnostics.configTestFailure(output: "Syntax OK\n", exitOK: false))
    }

    /// Uyarı hata değildir — ServerName uyarısı yüzünden geri alma yapılmamalı.
    func testConfigTest_WarningIsNotAFailure() {
        let out = """
        [Mon Aug 10 12:00:00.000000 2026] [alias:warn] [pid 1] AH00671: The Alias directive overlaps
        Syntax OK
        """
        XCTAssertNil(Diagnostics.configTestFailure(output: out, exitOK: true))
    }

    /// Çıktısız bir başarısızlık da başarısızlıktır; nil dönmek "geçerli" demek olurdu.
    func testConfigTest_EmptyOutputFailureIsStillAFailure() {
        XCTAssertNotNil(Diagnostics.configTestFailure(output: "", exitOK: false))
    }

    // MARK: - 1.7 düzeltmeleri

    /// Devre dışı bırakılan uzantı `php -m`'den düşer. `.ini.disabled` dosyası onun
    /// hâlâ DİSKTE olduğunun kanıtıdır; bu ayrım kaybolursa satır "kurulu değil"e
    /// döner, onay kutusu yerine "Kur" gelir ve pecl "already installed" ile patlar —
    /// uzantıyı arayüzden geri açmanın yolu kalmaz.
    func testDisabledNames_TreatsDisabledFileAsProofOfInstall() {
        let names = PHPExtensionManager.disabledNames(inConfD: [
            "ext-redis.ini.disabled", "ext-xdebug.ini.disabled",
        ])
        XCTAssertEqual(names, ["redis", "xdebug"])
    }

    /// ETKİN uzantı devre dışı sayılmamalı: `.ini` ile `.ini.disabled` karışırsa
    /// isInstalled ile isEnabled birbiriyle çelişir.
    func testDisabledNames_IgnoresEnabledAndUnrelatedFiles() {
        let names = PHPExtensionManager.disabledNames(inConfD: [
            "ext-redis.ini",            // etkin
            "ext-soap.ini.disabled",    // devre dışı
            "php.ini", "ext-.ini.disabled", "50-extension.ini", "README",
        ])
        XCTAssertEqual(names, ["soap"], "yalnızca gerçek .ini.disabled sayılmalı")
    }

    /// Ad çıkarımı yalnızca UÇLARI kırpmalı: içinde "ext-" geçen bir ad bozulmamalı.
    func testDisabledNames_StripsOnlyTheAffixes() {
        XCTAssertEqual(PHPExtensionManager.disabledNames(inConfD: ["ext-my-ext-thing.ini.disabled"]),
                       ["my-ext-thing"])
    }

    // MARK: - Yerinde güncelleme

    /// YER DEĞİŞTİRME her şeyin önünde gelir. Karantinalı bir kalıptan açılan kopyanın
    /// geçici dizini yazılabilir olabilir; oraya kurmak kullanıcının uygulamasını
    /// değiştirmez, yalnızca çöp üretir.
    func testSelfUpdater_TranslocationOutranksWritability() {
        XCTAssertEqual(
            SelfUpdater.blocker(bundlePath: "/private/var/folders/x/AppTranslocation/ABC/d/BRAMPP.app",
                                parentWritable: true, bundleWritable: true),
            .translocated)
    }

    /// Yazılamayan bir hedefte düğme HİÇ gösterilmemeli — kullanıcıyı uygulamadan
    /// ettikten sonra "olmadı" demek, hiç dememekten kötüdür.
    func testSelfUpdater_ReportsUnwritableTarget() {
        XCTAssertEqual(SelfUpdater.blocker(bundlePath: "/Applications/BRAMPP.app",
                                           parentWritable: false, bundleWritable: true),
                       .parentNotWritable)
        XCTAssertEqual(SelfUpdater.blocker(bundlePath: "/Applications/BRAMPP.app",
                                           parentWritable: true, bundleWritable: false),
                       .bundleNotWritable)
        XCTAssertNil(SelfUpdater.blocker(bundlePath: "/Applications/BRAMPP.app",
                                         parentWritable: true, bundleWritable: true))
    }

    /// BOŞLUKLU YOL. Kullanıcı uygulamayı "/Users/x/My Apps" altında tutuyorsa,
    /// tırnaklanmamış bir `mv` yolu ikiye böler ve takas yarıda kalır — geri alınacak
    /// bir şey de bulunmaz.
    func testSelfUpdater_SwapScriptQuotesPathsWithSpaces() {
        let s = SelfUpdater.swapScript(parentPID: 4242,
                                       stagedPath: "/My Apps/.BRAMPP-update-1",
                                       targetPath: "/My Apps/BRAMPP.app",
                                       logPath: "/tmp/my logs/swap.log",
                                       binaryName: "BRAMPP")
        XCTAssertTrue(s.contains("'/My Apps/BRAMPP.app'"), "hedef tırnaklanmalı")
        XCTAssertTrue(s.contains("'/My Apps/.BRAMPP-update-1'"), "hazırlanan kopya tırnaklanmalı")
        XCTAssertTrue(s.contains("'/tmp/my logs/swap.log'"), "log yolu tırnaklanmalı")
    }

    /// Betiğin GERİ ALMA yolu bulunmak zorunda: yeni sürüm açılmazsa eski paket geri
    /// konmalı. Bu kaybolursa hata anında kullanıcı uygulamasız kalır.
    func testSelfUpdater_SwapScriptRollsBackWhenNewVersionDoesNotLaunch() {
        let s = SelfUpdater.swapScript(parentPID: 1, stagedPath: "/A/.new",
                                       targetPath: "/A/BRAMPP.app",
                                       logPath: "/A/log", binaryName: "BRAMPP")
        XCTAssertTrue(s.contains("mv \"$OLD\""), "eski paketi geri koyan bir yol olmalı")
        XCTAssertTrue(s.contains("grep -qF"), "yeni sürümün açıldığı DOĞRULANMALI")
        // Düz metin araması yetmez: betiğin açıklama satırı "set -e"nin NEDEN
        // kullanılmadığını anlatıyor ve o metni içeriyor. Aranan şey DİREKTİF.
        let directives = s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertFalse(directives.contains("set -e"),
                       "set -e, geri alma adımlarına varmadan kabuğu düşürürdü")
        XCTAssertTrue(s.contains("kill -0 1"), "ana sürecin çıkışı beklenmeli")
    }

    // MARK: - Tünel DNS beklemesi

    /// Sistem çözümleyicisi adı görüyorsa iş biter — kenarın ne dediğinin önemi yok.
    func testWaitVerdict_SystemResolutionEndsTheWait() {
        let now = Date()
        XCTAssertEqual(TunnelManager.waitVerdict(systemResolves: true, now: now,
                                                 deadline: now.addingTimeInterval(45),
                                                 edgeSeenAt: nil),
                       .ready)
    }

    /// Kenar adı GÖRDÜYSE gecikme artık Cloudflare'de değil, kullanıcının
    /// çözümleyicisinde. Kalan 40 saniyeyi beklemek hiç gelmeyecek cevabı beklemektir:
    /// kısa süre dolunca adres uyarıyla verilir.
    func testWaitVerdict_EdgeSightingShortensTheWait() {
        let now = Date()
        let deadline = now.addingTimeInterval(40)   // toplam süre HÂLÂ bol
        XCTAssertEqual(TunnelManager.waitVerdict(systemResolves: false, now: now,
                                                 deadline: deadline,
                                                 edgeSeenAt: now.addingTimeInterval(-7),
                                                 grace: 6),
                       .handOverWithWarning)
        // Süre henüz dolmadıysa beklemeye devam
        XCTAssertEqual(TunnelManager.waitVerdict(systemResolves: false, now: now,
                                                 deadline: deadline,
                                                 edgeSeenAt: now.addingTimeInterval(-2),
                                                 grace: 6),
                       .keepWaiting)
    }

    /// Kenar adı HİÇ görmediyse tam zaman aşımı korunur: bu, tünelin gerçekten
    /// hazır olmadığı durumdur ve erken pes etmek kullanıcıyı ölü bir adresle bırakır.
    func testWaitVerdict_WithoutEdgeSightingFullTimeoutStands() {
        let now = Date()
        XCTAssertEqual(TunnelManager.waitVerdict(systemResolves: false, now: now,
                                                 deadline: now.addingTimeInterval(30),
                                                 edgeSeenAt: nil),
                       .keepWaiting)
        XCTAssertEqual(TunnelManager.waitVerdict(systemResolves: false, now: now,
                                                 deadline: now.addingTimeInterval(-1),
                                                 edgeSeenAt: nil),
                       .handOverWithWarning)
    }

    /// dig'in kendi not satırları ADRES DEĞİLDİR; sayılsaydı bir zaman aşımı uyarısı
    /// "ad bulundu" diye okunur ve bekleme erken kesilirdi.
    func testDigFoundAddress_IgnoresCommentaryAndEmptyOutput() {
        XCTAssertTrue(TunnelManager.digFoundAddress(in: "104.16.231.132\n104.16.230.132\n"))
        XCTAssertFalse(TunnelManager.digFoundAddress(in: ""))
        XCTAssertFalse(TunnelManager.digFoundAddress(in: "\n  \n"))
        XCTAssertFalse(TunnelManager.digFoundAddress(in: ";; connection timed out\n"))
    }

    // MARK: - Alias sırası onarımı

    /// Kullanıcının makinesindeki GERÇEK dosya: eğik çizgisiz Alias önce geliyor,
    /// bu yüzden Apache AH00671 veriyor.
    func testAliasOrder_DetectsTheRealBrokenFile() {
        let broken = """
        # phpMyAdmin Global Alias
        Alias /phpmyadmin /opt/homebrew/share/phpmyadmin
        Alias /phpmyadmin/ /opt/homebrew/share/phpmyadmin/
        """
        XCTAssertTrue(Diagnostics.aliasOrderIsWrong(broken, prefix: "/phpmyadmin"))
    }

    /// Güncel şablon onarım İSTEMEMELİ; istese her açılışta gereksiz bir yeniden
    /// yazma ve Apache reload'u tetiklenirdi.
    func testAliasOrder_CurrentTemplateNeedsNoRepair() {
        XCTAssertFalse(Diagnostics.aliasOrderIsWrong(VHostTemplates.phpmyadminConfig(),
                                                     prefix: "/phpmyadmin"))
        XCTAssertFalse(Diagnostics.aliasOrderIsWrong(VHostTemplates.adminerApacheConfig(),
                                                     prefix: "/adminer"))
    }

    /// YORUM satırları sayılmamalı. Şablonun kendi açıklaması "Alias" kelimesini
    /// geçiriyor; sayılsaydı doğru sıralı her dosya bozuk görünürdü.
    func testAliasOrder_IgnoresComments() {
        let s = """
        # Alias /phpmyadmin burada yanlış sırada olurdu
        Alias /phpmyadmin/ /x/
        Alias /phpmyadmin /x
        """
        XCTAssertFalse(Diagnostics.aliasOrderIsWrong(s, prefix: "/phpmyadmin"))
    }

    /// Alias'lardan biri yoksa onarılacak bir sıra da yoktur — elle yazılmış bir
    /// dosyayı "bozuk" sayıp üzerine yazmak, kullanıcının yapılandırmasını silerdi.
    func testAliasOrder_IncompleteFileIsNotRepairable() {
        XCTAssertFalse(Diagnostics.aliasOrderIsWrong("Alias /phpmyadmin /x", prefix: "/phpmyadmin"))
        XCTAssertFalse(Diagnostics.aliasOrderIsWrong("", prefix: "/phpmyadmin"))
    }

    /// Süreç denetimi DÜZENLİ İFADE olmamalı. `pgrep -f` deseni ERE sayar; yolunda
    /// `+` gibi bir metakarakter olan bir kullanıcıda eşleşme tutmaz ve BAŞARILI bir
    /// güncelleme geri alınırdı.
    func testSelfUpdater_MatchesProcessLiterallyNotAsRegex() {
        let s = SelfUpdater.swapScript(parentPID: 1, stagedPath: "/A/.new",
                                       targetPath: "/A/C++ Tools/BRAMPP.app",
                                       logPath: "/A/log", binaryName: "BRAMPP")
        // Betiğin açıklaması `pgrep -f`in NEDEN kullanılmadığını anlatıyor ve o metni
        // içeriyor; aranan şey açıklama değil, ÇALIŞTIRILAN komut.
        let code = s.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
        XCTAssertFalse(code.contains("pgrep"), "regex tabanlı eşleşme kullanılmamalı")
        XCTAssertTrue(code.contains("grep -qF"), "düz metin eşleşmesi kullanılmalı")
    }

    /// Geri alma hedefi ÖNCE SİLMEMELİ. `rm -rf` + `mv` sırası, aralarında hiçbir
    /// uygulamanın bulunmadığı bir pencere açar; betik o an ölürse kullanıcıda
    /// çalışan kopya kalmaz.
    func testSelfUpdater_RollbackRenamesRatherThanDeletingTheTarget() {
        let s = SelfUpdater.swapScript(parentPID: 1, stagedPath: "/A/.new",
                                       targetPath: "/A/BRAMPP.app",
                                       logPath: "/A/log", binaryName: "BRAMPP")
        XCTAssertFalse(s.contains("rm -rf '/A/BRAMPP.app'\n"),
                       "hedef doğrudan silinmemeli")
        XCTAssertTrue(s.contains("'/A/BRAMPP.app'.brampp-failed"),
                      "geri alma, hedefi yana alarak yapılmalı")
    }

    /// Açılışın SÜREKLİLİĞİ denetlenmeli. İlk görünmeyle yetinilirse, açılışta çöken
    /// bir sürüm geri dönüş kopyasını yarım saniyede sildirir ve kullanıcı her
    /// açılışta düşen bir uygulamayla, geri dönecek hiçbir şey olmadan kalır.
    func testSelfUpdater_WaitsForTheNewVersionToStayAlive() {
        let s = SelfUpdater.swapScript(parentPID: 1, stagedPath: "/A/.new",
                                       targetPath: "/A/BRAMPP.app",
                                       logPath: "/A/log", binaryName: "BRAMPP")
        XCTAssertEqual(s.components(separatedBy: "grep -qF").count - 1, 2,
                       "biri ilk görünme, biri ayakta kalma denetimi olmak üzere iki tur")
        XCTAssertTrue(s.contains("seen=0"), "ayakta kalmayan sürüm başarısız sayılmalı")
    }

    /// Betiğe gömülen HİÇBİR yol tırnaksız kalmamalı: `$` taşıyan bir klasör adı
    /// kabuk tarafından genişletilir ve betik ilk satırında sözdizimi hatasıyla ölür.
    func testSelfUpdater_NeverEmbedsAnUnquotedPath() {
        let s = SelfUpdater.swapScript(parentPID: 1, stagedPath: "/A/.new",
                                       targetPath: "/Uyg $HOME/BRAMPP.app",
                                       logPath: "/A/log", binaryName: "BRAMPP")
        XCTAssertFalse(s.contains("takas başlıyor: /Uyg $HOME"),
                       "yol çift tırnaklı metnin İÇİNE gömülmemeli")
        XCTAssertTrue(s.contains("'/Uyg $HOME/BRAMPP.app'"), "yol tek tırnakla korunmalı")
    }

    // MARK: - Homebrew paket güncellemeleri

    /// `brew outdated --verbose` biçimi. Sürümler olmadan kullanıcı "neyi neye
    /// yükseltiyorum" sorusunu yanıtlayamaz; yalnızca ad göstermek bu yüzden yetmiyordu.
    func testBrewOutdated_ParsesNameAndVersions() {
        let out = """
        httpd (2.4.62) < 2.4.63
        php@8.3 (8.3.13, 8.3.14) < 8.3.15
        """
        let p = BrewUpdates.parseOutdated(out)
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(p[0], .init(name: "httpd", current: "2.4.62", latest: "2.4.63"))
        XCTAssertEqual(p[1].current, "8.3.13, 8.3.14", "birden çok kurulu sürüm korunmalı")
        XCTAssertEqual(p[1].latest, "8.3.15")
    }

    /// `!=` biçimi de güncellenebilir demektir (kurulu sürüm ileri gitmiş olabilir).
    /// Ayrıştırılamayan satır ATILMAZ: paketi hiç görmemek, sürümsüz görmekten kötü.
    func testBrewOutdated_HandlesNotEqualFormAndBareNames() {
        let p = BrewUpdates.parseOutdated("mariadb (11.4.2) != 11.4.3\nredis\n")
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(p[0].latest, "11.4.3")
        XCTAssertEqual(p[1], .init(name: "redis", current: "", latest: ""))
    }

    /// Asıl mesele: 49 paketlik bir listede `httpd` ile `jadx` aynı yerde duruyordu.
    /// Yönetilen / bağımlılık / diğer ayrımı bunu çözüyor.
    func testBrewSplit_SeparatesManagedFromNoise() {
        let pkgs = BrewUpdates.parseOutdated("""
        httpd (1) < 2
        apr-util (1) < 2
        jadx (1) < 2
        """)
        let s = BrewUpdates.split(pkgs, managed: ["httpd"], dependencies: ["apr-util"])
        XCTAssertEqual(s.managed.map(\.name), ["httpd"])
        XCTAssertEqual(s.related.map(\.name), ["apr-util"])
        XCTAssertEqual(s.other.map(\.name),   ["jadx"], "BRAMPP'ın dokunmadığı paket ayrı durmalı")
    }

    /// Yönetilen ad listesi KATALOGDAN türetilmeli; elle yazılan bir liste katalog
    /// büyüdüğünde sessizce eksik kalırdı.
    func testBrewManagedNames_ComeFromTheServiceCatalogue() {
        let names = BrewUpdates.managedNames(services: Service.defaultServices)
        XCTAssertTrue(names.contains("httpd"))
        XCTAssertTrue(names.contains("mariadb"))
        XCTAssertFalse(names.contains("jadx"))
    }

    /// Yalnızca ÇALIŞAN servisler yeniden başlatılmalı: durmuş bir servisi yükseltmek
    /// onu başlatmak için gerekçe değil, kullanıcı onu bilerek durdurmuş olabilir.
    func testBrewRestart_OnlyTouchesRunningServices() {
        let ids = BrewUpdates.servicesNeedingRestart(after: ["httpd", "mariadb"],
                                                     runningServiceIDs: ["httpd"],
                                                     services: Service.defaultServices)
        XCTAssertEqual(ids, ["httpd"])
    }

    // MARK: - /etc/hosts sonundaki newline

    /// `echo … >>` yalnızca SONA newline koyar. Dosya newline'sız bitiyorsa yeni girdi
    /// son satırın kuyruğuna yapışır: hem yeni ad çözülmez hem de yapıştığı satır
    /// kalıcı olarak bozulur. Garanti, ekleme zincirinden ÖNCE gelmeli.
    func testHostsCommand_PutsTheNewlineGuardBeforeTheAppend() {
        let cmd = DomainManager.hostsCommand(appending: "echo x >> /etc/hosts")
        XCTAssertTrue(cmd.hasPrefix(DomainManager.hostsEnsureTrailingNewline),
                      "garanti zincirin BAŞINDA olmalı")
        XCTAssertTrue(cmd.hasSuffix("echo x >> /etc/hosts"), "zincir korunmalı")
        XCTAssertTrue(DomainManager.hostsEnsureTrailingNewline.contains("tail -c 1"),
                      "son bayt denetlenmeli")
        // Boş dosyada newline EKLENMEMELİ: `-s` koruması bunun için var.
        XCTAssertTrue(DomainManager.hostsEnsureTrailingNewline.contains("-s /etc/hosts"))
    }

    // MARK: - ps çıktısı ayrıştırma

    /// BOŞLUKLU YOL. Yürütücü "/Users/x/My Tools/node" ise boşluğa göre bölmek
    /// sütunları kaydırır ve kullanıcı komut adının parçasını CPU değeri olarak görür.
    func testParseProcessLine_KeepsColumnsAlignedWithSpacedPath() {
        let p = NativeProcessManager.parseProcessLine("12345 0.4 45678 /Users/x/My Tools/node")
        XCTAssertEqual(p.pid, 12345)
        XCTAssertEqual(p.cpu, "0.4")
        XCTAssertEqual(p.rssKB, 45678)
        XCTAssertEqual(p.command, "node", "yolun son bileşeni alınmalı, sütun kaymamalı")
    }

    func testParseProcessLine_HandlesPlainPathAndEmptyOutput() {
        let p = NativeProcessManager.parseProcessLine("  999 12.5 1024 /opt/homebrew/bin/python3  ")
        XCTAssertEqual(p.pid, 999)
        XCTAssertEqual(p.command, "python3")
        let empty = NativeProcessManager.parseProcessLine("")
        XCTAssertNil(empty.pid); XCTAssertNil(empty.command)
    }

    /// Komut alanı hiç yoksa çökmemeli — ps beklenmedik biçimde kısa dönebilir.
    func testParseProcessLine_ToleratesMissingCommand() {
        let p = NativeProcessManager.parseProcessLine("42 0.0 100")
        XCTAssertEqual(p.pid, 42)
        XCTAssertEqual(p.rssKB, 100)
        XCTAssertNil(p.command)
    }

    // MARK: - PHP alt sistemi

    /// Xdebug'ın RESMÎ yönergesi mutlak yol verir. Yol karşılaştırıldığı için satır
    /// hiç temizlenmiyor, uzantı devre dışı bırakıldıktan sonra bile yükleniyordu.
    func testMainIniExtensions_ResolvesAbsolutePathsAndQuotes() {
        let names = PHPExtensionManager.mainIniExtensionNames(in: """
        extension=redis
        extension="soap.so"
        zend_extension=/opt/homebrew/lib/php/pecl/20230831/xdebug.so
        ; extension=disabled_one
        extension_dir = "/opt/homebrew/lib/php/pecl"
        """)
        XCTAssertEqual(names, ["redis", "soap", "xdebug"],
                       "yorumlanmış satır ve extension_dir sayılmamalı")
    }

    /// `isAlwaysOn` YALNIZCA BRAMPP bloğuna bakmalı: kullanıcının dosyanın başka
    /// yerindeki kendi satırı, bloğun üstünde olduğu için önce görülüp paneli
    /// kilitliyordu.
    func testProfilerAlwaysOn_ReadsOnlyInsideTheManagedBlock() {
        let ini = """
        xdebug.start_with_request = yes
        \(PHPProfiler.beginMark)
        xdebug.mode = profile
        xdebug.start_with_request = trigger
        \(PHPProfiler.endMark)
        """
        XCTAssertFalse(PHPProfiler.isAlwaysOn(in: ini),
                       "blok DIŞINDAKİ kullanıcı satırı okunmamalı")
    }

    func testProfilerAlwaysOn_TrueWhenTheManagedBlockSaysYes() {
        let ini = """
        \(PHPProfiler.beginMark)
        xdebug.mode = profile
        xdebug.start_with_request = yes
        \(PHPProfiler.endMark)
        """
        XCTAssertTrue(PHPProfiler.isAlwaysOn(in: ini))
    }

    // MARK: - Kaldırma betiği güvenliği

    /// Silme başarısızlığı YUTULMAMALI. Eski `rm -rf "yol" && echo "Silindi"` kalıbında
    /// `&&` yüzünden başarısız silme sessizce geçiliyor, betik yine "başarıyla
    /// kaldırıldı" diyordu — MariaDB'de bu, veri dizini DURURKEN kullanıcının
    /// silindiğini sanması demekti.
    func testUninstallScript_ReportsDeletionFailures() {
        let s = ServiceManager.uninstallScript(serviceID: "mariadb", serviceName: "MariaDB",
                                               brewName: "mariadb", brewPrefix: "/opt/homebrew",
                                               port: 3306)
        XCTAssertTrue(s.contains("CLEANUP_FAILED=1"), "başarısız silme bayraklanmalı")
        XCTAssertTrue(s.contains("SİLİNEMEDİ"), "başarısızlık kullanıcıya söylenmeli")
        XCTAssertFalse(s.contains("rm -rf \"/opt/homebrew/var/mysql\" && echo"),
                       "eski yutan kalıp kalmamalı")
    }

    /// Veri dizini, sunucunun durduğu DOĞRULANMADAN silinmemeli: çalışan bir sunucunun
    /// altından dosya çekmek geriye tutarsız bir veri dizini bırakır.
    func testUninstallScript_VerifiesTheServerStoppedBeforeDeleting() {
        let s = ServiceManager.uninstallScript(serviceID: "mariadb", serviceName: "MariaDB",
                                               brewName: "mariadb", brewPrefix: "/opt/homebrew",
                                               port: 3306)
        XCTAssertTrue(s.contains("nc -z 127.0.0.1 3306"), "port gerçekten yoklanmalı")
        let stopIdx = s.range(of: "nc -z 127.0.0.1 3306")?.lowerBound
        let rmIdx   = s.range(of: "CLEANUP_FAILED=0")?.lowerBound
        XCTAssertNotNil(stopIdx); XCTAssertNotNil(rmIdx)
        XCTAssertTrue(stopIdx! < rmIdx!, "doğrulama silmeden ÖNCE gelmeli")
    }

    /// Portu olmayan servis için doğrulama bloğu eklenmemeli — sonsuza dek bekleyen
    /// bir döngü, kaldırmayı hiç bitirmezdi.
    func testUninstallScript_SkipsThePortGuardWhenThereIsNoPort() {
        let s = ServiceManager.uninstallScript(serviceID: "mkcert", serviceName: "mkcert",
                                               brewName: "mkcert", brewPrefix: "/opt/homebrew")
        XCTAssertFalse(s.contains("nc -z 127.0.0.1"))
    }

    // MARK: - Sihirbaz denetimleri

    /// YORUMLANMIŞ include Apache tarafından yok sayılır. Düz alt dize araması onu da
    /// eşleştiriyor, sihirbaz adımı "tamam" gösteriyor ve kullanıcı phpMyAdmin'in
    /// çalışmadığı bir yapılandırmayla kalıyordu.
    func testPhpMyAdminInclude_IgnoresCommentedLines() {
        let line = "IncludeOptional /opt/homebrew/etc/httpd/extra/phpmyadmin.conf"
        XCTAssertFalse(SetupWizardView.httpdIncludesPhpMyAdmin("# \(line)\n", includeLine: line),
                       "yorumlanmış include etkin sayılmamalı")
        XCTAssertFalse(SetupWizardView.httpdIncludesPhpMyAdmin("   #\(line)\n", includeLine: line))
        XCTAssertTrue(SetupWizardView.httpdIncludesPhpMyAdmin("\(line)\n", includeLine: line))
        XCTAssertTrue(SetupWizardView.httpdIncludesPhpMyAdmin("  \(line)  \n", includeLine: line))
        XCTAssertFalse(SetupWizardView.httpdIncludesPhpMyAdmin("", includeLine: line))
    }

    // MARK: - PHP-FPM havuz normalleştirmesi

    /// ÇOK HAVUZLU www.conf. Her `listen` satırı aynı değere çevrilirse iki havuz aynı
    /// porta bağlanmaya çalışır ve php-fpm "Address already in use" ile HİÇ başlamaz.
    func testFPMNormalize_TouchesOnlyTheFirstPool() {
        let out = PHPFPMConfigManager.normalized("""
        [www]
        listen = /tmp/eski.sock
        user = nobody
        [site2]
        listen = 127.0.0.1:9999
        user = someone
        """, version: "8.3")
        XCTAssertTrue(out.contains("[site2]\nlisten = 127.0.0.1:9999"),
                      "ikinci havuz OLDUĞU GİBİ kalmalı")
        XCTAssertTrue(out.contains("user = someone"), "ikinci havuzun user'ı korunmalı")
        XCTAssertEqual(out.components(separatedBy: "listen = 127.0.0.1:9999").count - 1, 1)
    }

    /// Eksik direktifler BÖLÜMÜN sonuna girmeli; dosyanın sonuna eklenen bir `listen`
    /// bir SONRAKİ havuza ait olurdu.
    func testFPMNormalize_AddsMissingDirectivesInsideTheFirstPool() {
        let out = PHPFPMConfigManager.normalized("[www]\nphp_admin_value[x] = 1\n[other]\nlisten = /tmp/o.sock",
                                                 version: "8.3")
        let wwwIdx   = out.range(of: "[www]")!.lowerBound
        let otherIdx = out.range(of: "[other]")!.lowerBound
        let userIdx  = out.range(of: "user = _www")!.lowerBound
        XCTAssertTrue(wwwIdx < userIdx && userIdx < otherIdx,
                      "eksik direktif ilk havuzun İÇİNE girmeli")
    }

    /// `listen` ile `listen.owner` karışmamalı — önek eşleşmesi ikisini birbirine yazardı.
    func testFPMNormalize_DoesNotConfuseListenWithListenOwner() {
        let out = PHPFPMConfigManager.normalized("[www]\nlisten.owner = nobody\nlisten = /tmp/s.sock",
                                                 version: "8.3")
        XCTAssertTrue(out.contains("listen.owner = _www"))
        XCTAssertTrue(out.contains("listen = 127.0.0.1:"))
        XCTAssertFalse(out.contains("/tmp/s.sock"))
    }

    /// Bağlı kalan bir disk kalıbı, her açılışta "volume is read only" hatası
    /// ürettiriyordu: temizlik onu silmeye çalışıyor, silemiyor. Uygulama ayırmayı
    /// yapamadan çıkarsa betik kurtarmalı — o, çıkıştan SONRA çalışan tek şey.
    func testSelfUpdater_SwapScriptDetachesLeftoverImages() {
        let s = SelfUpdater.swapScript(parentPID: 1, stagedPath: "/A/.new",
                                       targetPath: "/A/BRAMPP.app",
                                       logPath: "/A/log", binaryName: "BRAMPP")
        XCTAssertTrue(s.contains("hdiutil detach"), "betik bağlı kalmış kalıbı ayırmalı")
        // Ayırma, uygulamayı AÇMADAN önce olmalı: yeni sürüm açılıp temizliği
        // çalıştırırsa aynı hatayı yine görürüz.
        let detachIdx = s.range(of: "hdiutil detach")?.lowerBound
        let openIdx   = s.range(of: "open '/A/BRAMPP.app'")?.lowerBound
        XCTAssertNotNil(detachIdx); XCTAssertNotNil(openIdx)
        XCTAssertTrue(detachIdx! < openIdx!, "ayırma açmadan ÖNCE gelmeli")
    }

    // MARK: - Apache/Nginx port çakışması

    /// Homebrew'un stok httpd-ssl.conf'u `Listen 8443` ile gelir ve BRAMPP'ın şemasında
    /// 8443 NGINX'indir. Olduğu gibi korunursa iki servis aynı porta bağlanmaya çalışır;
    /// ikinci başlayan düşer. Yazılacak port bu durumda 443 olmalı.
    func testApacheHTTPSForWrite_AvoidsNginxPort() {
        XCTAssertEqual(WebServerPorts.resolveApacheHTTPSForWrite(current: 8443, nginxHTTPS: 8443), 443,
                       "nginx'in portuyla çakışan değer 443'e dönmeli")
    }

    /// Kullanıcının BİLEREK seçtiği port korunmalı — çakışma yoksa dokunulmaz.
    func testApacheHTTPSForWrite_KeepsADeliberateChoice() {
        XCTAssertEqual(WebServerPorts.resolveApacheHTTPSForWrite(current: 9443, nginxHTTPS: 8443), 9443)
        XCTAssertEqual(WebServerPorts.resolveApacheHTTPSForWrite(current: 443,  nginxHTTPS: 8443), 443)
        // Nginx de taşınmış olabilir: çakışma nginx'in GERÇEK portuna göre ölçülür.
        XCTAssertEqual(WebServerPorts.resolveApacheHTTPSForWrite(current: 9443, nginxHTTPS: 9443), 443)
    }

    // MARK: - Alan adı silme temizliği

    /// **Silme, alan adının ÜRETEBİLECEĞİ her logu hedefler — seçili sunucununkini değil.**
    ///
    /// `errorLogPath`/`accessLogPath` `webServer`e bakıp TEK yol döndürür ve silme yolu
    /// uzun süre hiç log silmiyordu; her silinen alan adı arkasında dosya bırakıyordu.
    /// Sunucuya göre seçmek de yetmez, iki nedenle: nginx alan adlarına bir de Apache
    /// companion vhost'u yazılıyor (yani httpd altında da log doğabilir), ve kullanıcı
    /// sunucu tercihini sonradan değiştirmiş olabilir — eski sunucunun dosyaları kalır.
    func testDomainDelete_TargetsLogsOfBothWebServers() {
        for server in [WebServer.apache, .nginx] {
            let d = Domain(name: "shop.test", platform: .php, sslEnabled: true, webServer: server)
            let paths = d.allLogPaths

            XCTAssertEqual(Set(paths).count, 4, "\(server): dört ayrı yol beklenir — \(paths)")
            for dir in [PathConfig.httpdLogs, PathConfig.nginxLogs] {
                for kind in ["access", "error"] {
                    XCTAssertTrue(paths.contains("\(dir)/shop.test-\(kind).log"),
                                  "\(server) için \(dir)/shop.test-\(kind).log listede yok")
                }
            }
            // Seçili sunucunun kendi yolları da bu kümenin içinde olmalı; ikisi
            // ayrışırsa silme, arayüzün gösterdiği log dosyasını ıskalar.
            XCTAssertTrue(paths.contains(d.errorLogPath), "\(server): errorLogPath kapsam dışı")
            XCTAssertTrue(paths.contains(d.accessLogPath), "\(server): accessLogPath kapsam dışı")
        }
    }

    /// Silme onayı NE OLDUĞUNU söylemeli: site klasörü KALIR.
    ///
    /// `removeDomain` `sitePath`e bilerek hiç dokunmaz — içinde kullanıcının kendi kodu
    /// var. Ama uyarı yalnızca "silinecek, geri alınamaz" diyordu ve dosyalarının da
    /// gittiğini sandıran tam olarak bu sessizlikti.
    func testDeleteConfirmation_SaysTheSiteFolderSurvives() {
        for (lang, kept) in [("tr", "kalır"), ("en", "stays")] {
            let msg = L10n.catalog["dom.deleteMsg"]?[lang] ?? ""
            XCTAssertFalse(msg.isEmpty, "\(lang): dom.deleteMsg boş")
            XCTAssertTrue(msg.contains(kept),
                          "\(lang): uyarı site klasörünün KALDIĞINI söylemeli — \(msg)")
            XCTAssertEqual(msg.components(separatedBy: "%@").count - 1, 1,
                           "\(lang): tam bir %@ olmalı (alan adı)")
        }
    }

    // MARK: - Menü ve bildirim bağlantıları

    /// Uygulamanın Swift kaynakları — (yol, metin).
    ///
    /// Bu iki testin ölçtüğü şey ÇALIŞTIRILARAK ölçülemiyor: bozuk bir menü öğesi
    /// derlenir, çizilir ve hiçbir şey yapmaz. Kanıt ancak kaynakta.
    private func appSourceFiles() throws -> [(path: String, text: String)] {
        let testDir  = (#filePath as NSString).deletingLastPathComponent
        let repoRoot = ((testDir as NSString).deletingLastPathComponent
                        as NSString).deletingLastPathComponent
        let root = repoRoot + "/macos/BRAMPP"
        guard let walk = FileManager.default.enumerator(atPath: root) else {
            throw XCTSkip("Kaynak ağacı okunamadı: \(root)")
        }
        var out: [(String, String)] = []
        for case let rel as String in walk where rel.hasSuffix(".swift") {
            if let text = FileHelper.readString(root + "/" + rel) { out.append((rel, text)) }
        }
        guard !out.isEmpty else { throw XCTSkip("Kaynak ağacı boş: \(root)") }
        return out
    }

    /// **Aynı komut grubunu hem `replacing:` hem `after:`/`before:` ile hedeflemek YASAK.**
    ///
    /// Gerçek bir hatanın testi. "Güncellemeleri Denetle…" öğesi
    /// `CommandGroup(after: .appInfo)` içindeydi, ama `.appInfo` bir üstte
    /// `CommandGroup(replacing: .appInfo)` ile zaten devralınmıştı. Artık var olmayan
    /// bir gruba "sonra" eklemek SwiftUI'da tanımlı değil: öğe menüde çiziliyor ama
    /// EYLEMİ BAĞLANMIYOR. Tıklamak hiçbir şey yapmıyordu ve derleyici de, çalışma
    /// zamanı da tek bir uyarı vermiyordu.
    func testCommandGroups_DoNotAnchorToAGroupTheyAlsoReplace() throws {
        let pattern = try NSRegularExpression(
            pattern: #"CommandGroup\(\s*(replacing|after|before)\s*:\s*\.(\w+)"#)

        for (path, text) in try appSourceFiles() {
            var replaced = Set<String>(), anchored: [String: String] = [:]
            let ns = text as NSString
            for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let kind  = ns.substring(with: m.range(at: 1))
                let group = ns.substring(with: m.range(at: 2))
                if kind == "replacing" { replaced.insert(group) } else { anchored[group] = kind }
            }
            for (group, kind) in anchored where replaced.contains(group) {
                XCTFail("""
                        \(path): `.\(group)` hem `replacing:` hem `\(kind):` ile hedefleniyor. \
                        Değiştirilmiş bir gruba tutturulan öğe menüde görünür ama eylemi \
                        bağlanmaz — tıklamak sessizce hiçbir şey yapmaz. Öğeyi `replacing:` \
                        bloğunun İÇİNE taşıyın.
                        """)
            }
        }
    }

    /// **Katalogdaki her metnin bir isteyeni olmalı** — ters yön.
    ///
    /// Var olan denetim tek yönlüydü: kodun istediği anahtar katalogda var mı? Ters yön
    /// hiç bakılmıyordu ve 39 çeviri çifti, hiçbir kod yolunun isteyemeyeceği hâlde
    /// katalogda birikmişti. Ölü metnin bedeli yalnızca yer değil: her biri iki dilde
    /// bakım ister ve bir sonraki okuyucuya var olmayan bir ekranı anlatır.
    ///
    /// **ASIL TUZAK — anahtarlar çalışma zamanında BİRLEŞTİRİLEBİLİR.** Düz arama
    /// bunları ölü sanır. Aşağıdaki aileler bilerek muaf; muafiyeti genişletmeden önce
    /// anahtarı gerçekten üreten satırı bul.
    func testCatalog_EveryStringHasSomethingThatAsksForIt() throws {
        // Çalışma zamanında üretilen aileler — her birinin ürettiği yer yazılı.
        let assembled: [NSRegularExpression] = try [
            #"^v\d"#,                            // ServicesTabView:241, PHPExtensionsTabView:288 — t("v\(version)")
            #"^set\.mcp\.scope\..*Desc$"#,        // SettingsView:488 — scope.rawValue + "Desc"
            #"^set\.upd\.channel\."#,             // UpdateManifest:13 — "set.upd.channel.\(rawValue)"
        ].map { try NSRegularExpression(pattern: $0) }

        // BİLEREK bağlanmamış, silinmemiş. İkisi de kendi servisinin ne olduğunu
        // anlatan TEK kullanıcı metni; bağlamak mı düşürmek mi — ürün kararı.
        let deliberatelyUnwired: Set<String> = ["svc.mailpit.hint", "svc.cf.desc"]

        // Kaynak ağacı BİR KEZ taranır. Anahtar başına yeniden taramak, 1200 anahtar ×
        // 90 dosyada testi 30 saniyeye çıkarıyordu.
        //
        // Aranan şey dizgi sabitinin KENDİSİ değil, ANAHTAR ŞEKLİ: tırnak, küçük harfle
        // başlayan noktalı ad, tırnak. Tırnakları çiftleyerek ayrıştırmayı denemek
        // İÇ İÇE GEÇMİŞ dizgilerde çöküyordu — `Text("• \(loc.t("db.adminerTag"))")`
        // satırında dış dizginin açılışı iç anahtarın tırnağıyla eşleşiyor ve anahtar
        // hiç görülmüyordu; dört YAŞAYAN anahtar tam böyle kaybolmuştu. Şekil araması
        // iç içe girmeyi umursamaz. Baştaki `@`, argüman biçimi içindir
        // (`args: ["3", "@log.backup.labelApacheVhost"]`).
        let literal = try NSRegularExpression(pattern: #""@?([a-z][A-Za-z0-9_.-]*)""#)
        var referenced = Set<String>()

        for (_, text) in try appSourceFiles() {
            for line in text.components(separatedBy: .newlines) {
                let ns = line as NSString
                let matches = literal.matches(in: line, range: NSRange(location: 0, length: ns.length))
                // Katalog TANIM satırı (`"anahtar": [...]`) kendini "kullanılmış" saymaz.
                //
                // İki nokta ARAMAK TEK BAŞINA YETMEZ: üçlü operatör aynı görünür.
                // `loc.t(kosul ? "a" : "b")` içinde de ilk sabiti bir iki nokta izler ve
                // bu kural `a`yı ölü ilan ederdi — YAŞAYAN yedi anahtar tam böyle
                // kaybolmuştu. Ayırt eden şey KONUM: tanımda sabit satırın başındadır,
                // üçlüde önünde her zaman çağrının kendisi durur.
                var skipFirst = false
                if let first = matches.first {
                    let before = ns.substring(to: first.range.lowerBound)
                        .trimmingCharacters(in: .whitespaces)
                    let after = ns.substring(from: first.range.upperBound)
                        .trimmingCharacters(in: .whitespaces)
                    skipFirst = before.isEmpty && after.hasPrefix(":")
                }
                for (i, m) in matches.enumerated() where !(i == 0 && skipFirst) {
                    var s = ns.substring(with: m.range(at: 1))
                    // Argüman biçimi: `args: ["3", "@log.backup.labelApacheVhost"]`
                    if s.hasPrefix("@") { s.removeFirst() }
                    referenced.insert(s)
                }
            }
        }

        var orphans: [String] = []
        for key in L10n.catalog.keys.sorted() {
            if deliberatelyUnwired.contains(key) || referenced.contains(key) { continue }
            let range = NSRange(location: 0, length: (key as NSString).length)
            if assembled.contains(where: { $0.firstMatch(in: key, range: range) != nil }) { continue }
            orphans.append(key)
        }

        XCTAssertTrue(orphans.isEmpty, """
                      Katalogda hiçbir kodun isteyemeyeceği \(orphans.count) metin var: \
                      \(orphans.joined(separator: ", ")). Ya kullanın ya silin. \
                      Anahtar çalışma zamanında birleştiriliyorsa onu üreten satırı bulun \
                      ve bu testteki `assembled` listesine gerekçesiyle ekleyin.
                      """)
    }

    /// **Her bildirimin hem göndereni hem dinleyeni olmalı.**
    ///
    /// Yukarıdaki hatanın ALTINDA ikincisi vardı: menü öğesi düzeltildikten sonra bile
    /// hiçbir şey olmuyordu, çünkü gönderilen bildirimi hiçbir gözlemci duymuyordu.
    /// İz kaydı konsolda gönderim satırını iki kez, alım satırını sıfır kez gösterdi.
    /// Tek yönü kalmış bir bildirim derlenir ve sessizce hiçbir iş yapmaz; bu test
    /// o sessizliği derleme zamanına taşır.
    func testNotificationNames_HaveBothASenderAndAListener() throws {
        let files = try appSourceFiles()
        let declPattern = try NSRegularExpression(
            pattern: #"static let (\w+)\s*=\s*Notification\.Name\("#)

        var declared: [String: String] = [:]              // ad → bildirildiği dosya
        for (path, text) in files {
            let ns = text as NSString
            for m in declPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                declared[ns.substring(with: m.range(at: 1))] = path
            }
        }
        XCTAssertFalse(declared.isEmpty, "Hiç bildirim adı bulunamadı — test kendi kendini sınamıyor")

        for (name, declPath) in declared {
            // Bildirimin KENDİ tanım satırı sayılmasın; yalnızca kullanımlar aranır.
            var posts = false, listens = false
            for (_, text) in files {
                if text.contains("post(name: .\(name)") || text.contains("post(name: Notification.Name.\(name)") {
                    posts = true
                }
                if text.contains("publisher(for: .\(name)") || text.contains("forName: .\(name)") {
                    listens = true
                }
            }
            XCTAssertTrue(posts,
                          "\(declPath): `.\(name)` bildiriliyor ama hiçbir yerden GÖNDERİLMİYOR — ölü kod.")
            XCTAssertTrue(listens,
                          "\(declPath): `.\(name)` gönderiliyor ama hiçbir yerde DİNLENMİYOR — "
                        + "gönderen taraf sessizce hiçbir iş yapmaz.")
        }
    }
}
