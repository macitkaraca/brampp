import Foundation

// MARK: - ClaudeIntegration

/// Yapay zekâ istemcilerinin (Claude Desktop, ChatGPT Codex) yapılandırması ve
/// "mcptools" becerisi için dosya sistemi işlemleri.
///
/// Arayüz (SettingsView) yalnızca sonucu gösterir; okuma/yazma/yedekleme burada yapılır.
/// Kullanıcının mevcut yapılandırmasına dokunmak riskli olduğundan HER yazma işleminden
/// önce zaman damgalı yedek alınır ve yalnızca `brampp` girişi değiştirilir —
/// diğer anahtarlar (preferences, başka MCP sunucuları) aynen korunur.
@MainActor
enum ClaudeIntegration {

    // MARK: - Yollar

    /// ~/Library/Application Support/Claude/claude_desktop_config.json
    static var desktopConfigPath: String {
        NSHomeDirectory() + "/Library/Application Support/Claude/claude_desktop_config.json"
    }

    /// ~/.claude/skills/mcptools
    static var skillDirectory: String {
        NSHomeDirectory() + "/.claude/skills/" + MCPToolsSkill.name
    }

    /// ~/.claude/skills/mcptools/SKILL.md
    static var skillPath: String {
        skillDirectory + "/SKILL.md"
    }

    /// ~/.claude/skills/brampp_mysql — veritabanı araçlarının ayrı becerisi.
    /// Genel beceriyle birlikte kurulur/kaldırılır; ayrı tutulmasının sebebi veritabanı
    /// işinin kendi güvenlik kuralları (içe aktarmadan önce yedek, yıkıcı SQL onayı) olması.
    static var mysqlSkillDirectory: String {
        NSHomeDirectory() + "/.claude/skills/" + BramppMySQLSkill.name
    }

    /// ~/.claude/skills/brampp_mysql/SKILL.md
    static var mysqlSkillPath: String {
        mysqlSkillDirectory + "/SKILL.md"
    }

    /// Beceri eskiden "brampp-mcp" adıyla kuruluyordu. Kurulum/kaldırma sırasında bu
    /// klasör de silinir — yoksa kullanıcıda aynı becerinin iki kopyası kalır.
    static var legacySkillDirectory: String {
        NSHomeDirectory() + "/.claude/skills/brampp-mcp"
    }

    /// ~/.codex
    static var codexDirectory: String {
        NSHomeDirectory() + "/.codex"
    }

    /// ~/.codex/config.toml
    static var codexConfigPath: String {
        codexDirectory + "/config.toml"
    }

    /// ~/.codex/AGENTS.md — Codex'in talimat dosyası (Claude becerisinin karşılığı)
    static var codexAgentsPath: String {
        codexDirectory + "/AGENTS.md"
    }

    /// Yapılandırmadaki BRAMPP girişinin anahtarı
    private static let serverKey = "brampp"

    // MARK: - Durum

    /// Claude Desktop yapılandırma dosyası var mı? (Claude Desktop kurulu değilse yoktur)
    static func desktopConfigExists() -> Bool {
        FileHelper.exists(desktopConfigPath)
    }

    /// Yapılandırmada `mcpServers.brampp` girişi var mı? Dosya yoksa/bozuksa false.
    static func isDesktopConfigured() -> Bool {
        guard let json = readDesktopConfig() else { return false }
        let servers = json["mcpServers"] as? [String: Any]
        return servers?[serverKey] != nil
    }

    /// Beceri dosyası kurulu mu?
    static func isSkillInstalled() -> Bool {
        FileHelper.exists(skillPath)
    }

    /// Codex yapılandırma dosyası var mı? (Codex kurulu değilse yoktur — hata değil)
    static func codexConfigExists() -> Bool {
        FileHelper.exists(codexConfigPath)
    }

    /// Codex yapılandırmasında `[mcp_servers.brampp]` tablosu var mı?
    static func isCodexConfigured() -> Bool {
        guard let text = FileHelper.readString(codexConfigPath) else { return false }
        return text.components(separatedBy: "\n").contains(where: isCodexTableHeader)
    }

    // MARK: - Claude Desktop

    /// BRAMPP'i Claude Desktop yapılandırmasına ekler.
    /// - Returns: başarıysa alınan yedeğin tam yolu.
    static func addToDesktop(port: Int) -> Result<String, Error> {
        guard desktopConfigExists() else {
            return .failure(error("Claude Desktop yapılandırma dosyası bulunamadı: \(desktopConfigPath)"))
        }
        guard let backup = makeBackup(of: desktopConfigPath) else {
            return .failure(error("Yapılandırma yedeklenemedi: \(desktopConfigPath)"))
        }
        guard var json = readDesktopConfig() else {
            return .failure(error("Yapılandırma okunamadı veya JSON biçimi bozuk: \(desktopConfigPath)"))
        }

        var servers = json["mcpServers"] as? [String: Any] ?? [:]
        servers[serverKey] = desktopEntry(port: port)
        json["mcpServers"] = servers

        if let err = writeDesktopConfig(json) { return .failure(err) }
        return .success(backup)
    }

    /// BRAMPP girişini Claude Desktop yapılandırmasından siler.
    /// - Returns: başarıysa alınan yedeğin tam yolu.
    static func removeFromDesktop() -> Result<String, Error> {
        guard desktopConfigExists() else {
            return .failure(error("Claude Desktop yapılandırma dosyası bulunamadı: \(desktopConfigPath)"))
        }
        guard let backup = makeBackup(of: desktopConfigPath) else {
            return .failure(error("Yapılandırma yedeklenemedi: \(desktopConfigPath)"))
        }
        guard var json = readDesktopConfig() else {
            return .failure(error("Yapılandırma okunamadı veya JSON biçimi bozuk: \(desktopConfigPath)"))
        }

        if var servers = json["mcpServers"] as? [String: Any] {
            servers.removeValue(forKey: serverKey)
            json["mcpServers"] = servers
        }

        if let err = writeDesktopConfig(json) { return .failure(err) }
        return .success(backup)
    }

    /// Claude Desktop YALNIZCA komut (stdio) tipi sunucu kabul eder — HTTP uç noktası
    /// doğrudan yazılamaz. Bu yüzden `mcp-remote` köprüsü üzerinden bağlanılır.
    private static func desktopEntry(port: Int) -> [String: Any] {
        let npx = npxPath()
        return [
            "command": npx,
            "args": ["-y", "mcp-remote", "http://127.0.0.1:\(port)/mcp", "--allow-http"],
            "env": ["PATH": searchPath(npx: npx)]
        ]
    }

    /// Var olan ilk npx'i seç. Hiçbiri yoksa düz "npx" — PATH üzerinden çözülür.
    private static func npxPath() -> String {
        let candidates = [
            "\(Shell.brewPrefix)/opt/node@22/bin/npx",
            "\(Shell.brewPrefix)/bin/npx",
            "/usr/local/bin/npx"
        ]
        for path in candidates where FileHelper.exists(path) { return path }
        return "npx"
    }

    /// Claude Desktop alt süreci minimum ortamla başlatır; npx'in kendi dizini PATH'te
    /// olmazsa node ikilisini bulamaz ve köprü sessizce çöker.
    private static func searchPath(npx: String) -> String {
        var dirs: [String] = []
        let npxDir = (npx as NSString).deletingLastPathComponent
        if !npxDir.isEmpty { dirs.append(npxDir) }
        dirs.append("\(Shell.brewPrefix)/bin")
        dirs.append(contentsOf: ["/usr/local/bin", "/usr/bin", "/bin"])
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    // MARK: - ChatGPT Codex

    /// BRAMPP'i Codex yapılandırmasına ekler.
    /// - Returns: alınan yedeğin tam yolu; dosya YOKTU ve yeni oluşturulduysa boş metin.
    static func addToCodex(port: Int) -> Result<String, Error> {
        writeCodexConfig(block: codexEntry(port: port))
    }

    /// BRAMPP tablosunu Codex yapılandırmasından siler.
    /// - Returns: alınan yedeğin tam yolu; silinecek dosya yoksa boş metin.
    static func removeFromCodex() -> Result<String, Error> {
        writeCodexConfig(block: nil)
    }

    /// Codex, Streamable HTTP taşımasını DOĞRUDAN destekler — Claude Desktop'ın aksine
    /// `mcp-remote` köprüsü gerekmez. (stdio sunucular için `command`/`args` yazılır;
    /// `transport` diye bir anahtar YOKTUR.)
    private static func codexEntry(port: Int) -> String {
        """
        [mcp_servers.\(serverKey)]
        url = "http://127.0.0.1:\(port)/mcp"

        """
    }

    /// TOML'u JSON gibi ayrıştıramayız; düzenleme METİN tabanlı ve korumacıdır:
    /// yalnızca `[mcp_servers.brampp]` tablosu değiştirilir/silinir, geri kalan her satır
    /// (yorumlar, sıralama, diğer sunucular) aynen korunur.
    private static func writeCodexConfig(block: String?) -> Result<String, Error> {
        var backup = ""
        var text = ""
        var encoding = String.Encoding.utf8

        switch FileHelper.readStringDetailed(codexConfigPath) {
        case .ok(let content, let enc):
            guard let path = makeBackup(of: codexConfigPath) else {
                return .failure(error("Codex yapılandırması yedeklenemedi: \(codexConfigPath)"))
            }
            backup   = path
            text     = content
            encoding = enc
        case .unreadable:
            return .failure(error("Codex yapılandırması okunamadı: \(codexConfigPath)"))
        case .missing:
            // Codex kurulu olmayabilir; silme isteğinde yapacak bir şey yok.
            guard block != nil else { return .success("") }
            guard FileHelper.createDirectory(codexDirectory) else {
                return .failure(error("Klasör oluşturulamadı: \(codexDirectory)"))
            }
        }

        guard FileHelper.write(applyCodexBlock(block, to: text), to: codexConfigPath, encoding: encoding) else {
            return .failure(error("Codex yapılandırması yazılamadı: \(codexConfigPath)"))
        }
        return .success(backup)
    }

    /// `[mcp_servers.brampp]` tablosunu `block` ile değiştirir (nil ise siler).
    /// Tablo, bir sonraki tablo başlığına ya da dosya sonuna kadar sürer; tablo yoksa
    /// blok dosyanın SONUNA eklenir.
    static func applyCodexBlock(_ block: String?, to text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var found: Int?
        var i = 0
        while i < lines.count {
            guard isCodexTableHeader(lines[i]) else { i += 1; continue }
            var end = i + 1
            while end < lines.count, !isTableHeader(lines[end]) { end += 1 }
            if found == nil { found = i }
            lines.removeSubrange(i..<end)   // `i` yerinde kalır: kayan satır yeniden sınanır
        }

        guard let block else { return lines.joined(separator: "\n") }

        var blockLines = block.components(separatedBy: "\n")
        if blockLines.last == "" { blockLines.removeLast() }

        if let index = found {
            // Ardından başka bir tablo geliyorsa araya boş satır koy; blok dosyanın
            // sonundaysa boş satır dosyanın satır sonuyla bitmesini sağlar.
            if index >= lines.count || !lines[index].isEmpty { blockLines.append("") }
            lines.insert(contentsOf: blockLines, at: index)
            return lines.joined(separator: "\n")
        }

        var out = lines.joined(separator: "\n")
        if !out.isEmpty {
            if !out.hasSuffix("\n")   { out += "\n" }
            if !out.hasSuffix("\n\n") { out += "\n" }
        }
        return out + block
    }

    /// `[mcp_servers.brampp]` başlığı mı? Boşluklara toleranslıdır (`[ mcp_servers.brampp ]`).
    /// BOM (U+FEFF) dosyanın İLK satırına yapışır ve boşluk sayılmadığından karşılaştırmayı
    /// sessizce bozar: başlık tanınmaz, ikinci bir tablo eklenir ve TOML geçersiz olur.
    static func isCodexTableHeader(_ line: String) -> Bool {
        stripBOM(line).filter { !$0.isWhitespace } == "[mcp_servers.\(serverKey)]"
    }

    /// Gerçek bir TOML tablo başlığı mı? `[` ile başlayıp `]` ile BİTMELİ ve virgül
    /// içermemeli — yalnızca `[` önekine bakmak çok satırlı bir diziyi (`env = [` …
    /// `["A","1"],`) tablo başlığı sanıp silme taramasını erken durdurur ve dosyayı bozar.
    /// Başlıktan sonra yalnızca yorum gelebilir.
    static func isTableHeader(_ line: String) -> Bool {
        let trimmed = stripBOM(line).trimmingCharacters(in: .whitespaces)
        return trimmed.range(of: #"^\[\[?[^\]\n,]+\]\]?\s*(#.*)?$"#,
                             options: .regularExpression) != nil
    }

    /// Bayt sırası işaretini (U+FEFF) karşılaştırma öncesi kırpar. İçeriğe dokunmaz —
    /// yalnızca sınama amaçlı kullanılır, dosyaya yazılan metin olduğu gibi korunur.
    private static func stripBOM(_ line: String) -> String {
        line.replacingOccurrences(of: "\u{FEFF}", with: "")
    }

    // MARK: - Beceri (Skill)

    /// ~/.claude/skills/mcptools/SKILL.md dosyasını yazar (klasörü gerekirse oluşturur),
    /// eski "brampp-mcp" kurulumunu temizler.
    ///
    /// Codex talimat dosyası (~/.codex/AGENTS.md) yalnızca `~/.codex` klasörü ZATEN VARSA
    /// güncellenir: bu satır arayüzde "Claude becerisi" diye etiketlidir ve Codex
    /// kullanmayan kullanıcıda ~/.codex'i yoktan var etmemelidir (Codex için ayrı bir
    /// satır zaten var).
    /// - Parameter port: MCP sunucusunun gerçek portu; beceri metnindeki uç noktaya yazılır.
    static func installSkill(port: Int = MCPToolsSkill.defaultPort) -> Result<Void, Error> {
        guard FileHelper.createDirectory(skillDirectory) else {
            return .failure(error("Beceri klasörü oluşturulamadı: \(skillDirectory)"))
        }
        guard FileHelper.write(MCPToolsSkill.rendered(port: port), to: skillPath) else {
            return .failure(error("Beceri dosyası yazılamadı: \(skillPath)"))
        }
        // Veritabanı becerisi — genel beceriyle birlikte kurulur
        guard FileHelper.createDirectory(mysqlSkillDirectory) else {
            return .failure(error("Beceri klasörü oluşturulamadı: \(mysqlSkillDirectory)"))
        }
        guard FileHelper.write(BramppMySQLSkill.rendered(port: port), to: mysqlSkillPath) else {
            return .failure(error("Beceri dosyası yazılamadı: \(mysqlSkillPath)"))
        }
        FileHelper.remove(legacySkillDirectory)
        if let err = applyCodexAgents(block: agentsBlock(port: port)) { return .failure(err) }
        return .success(())
    }

    /// Beceri dosyasını siler (klasör boş kaldıysa klasörü de), eski kurulumu temizler ve
    /// —yalnızca ~/.codex varsa— AGENTS.md'deki BRAMPP bölümünü kaldırır.
    static func removeSkill() -> Result<Void, Error> {
        guard FileHelper.remove(skillPath) else {
            return .failure(error("Beceri dosyası silinemedi: \(skillPath)"))
        }
        if FileHelper.exists(skillDirectory), FileHelper.contentsOfDirectory(skillDirectory).isEmpty {
            FileHelper.remove(skillDirectory)
        }
        // Veritabanı becerisi de kaldırılır. Dosya yoksa (eski sürümden yükseltme) hata
        // sayılmaz — kaldırma işlemi bu yüzden başarısız olmamalı.
        FileHelper.remove(mysqlSkillPath)
        if FileHelper.exists(mysqlSkillDirectory), FileHelper.contentsOfDirectory(mysqlSkillDirectory).isEmpty {
            FileHelper.remove(mysqlSkillDirectory)
        }
        FileHelper.remove(legacySkillDirectory)
        if let err = applyCodexAgents(block: nil) { return .failure(err) }
        return .success(())
    }

    // MARK: - Codex talimat dosyası (AGENTS.md)

    static let agentsStart = "<!-- BRAMPP-MCP:START -->"
    static let agentsEnd   = "<!-- BRAMPP-MCP:END -->"

    /// AGENTS.md'deki işaretçilerin durumu.
    enum AgentsBlockState {
        /// Hiç işaretçi yok — kurulumda blok dosya sonuna eklenir.
        case none
        /// İlk TAM çift (işaretçiler dahil) — yalnızca bu aralık değiştirilir/silinir.
        case valid(Range<String.Index>)
        /// Eşleşmeyen ya da iç içe işaretçi (START var END yok, fazladan START…).
        /// Bu durumda SİLME yapılmaz: aradaki kullanıcı içeriği yok olabilir.
        case broken
    }

    /// Codex'in beceri metnini içeren AGENTS.md bloğu (işaretçiler dahil).
    private static func agentsBlock(port: Int) -> String {
        // Sondaki satır sonu markdown'ın kendisinden gelir; bitiş işaretçisi kendi satırında olur.
        agentsStart + "\n" + MCPToolsSkill.rendered(port: port) + agentsEnd
    }

    /// Codex'te beceri (skill) kavramı yok; talimatlar AGENTS.md'ye yazılır. Kullanıcının
    /// kendi içeriğine dokunmamak için yalnızca işaretçiler arası değiştirilir.
    /// - Parameter block: yazılacak blok; `nil` ise blok kaldırılır.
    /// - Returns: hata varsa NSError, başarıysa nil
    private static func applyCodexAgents(block: String?) -> Error? {
        // Codex kullanılmıyorsa (~/.codex yok) bu adım sessizce atlanır — klasörü BİZ
        // oluşturmayız; aksi hâlde Claude becerisi kurulumu Codex kurulumu gibi görünürdü.
        guard FileHelper.exists(codexDirectory) else { return nil }

        var text = ""
        var encoding = String.Encoding.utf8
        var fileExists = false

        switch FileHelper.readStringDetailed(codexAgentsPath) {
        case .ok(let content, let enc):
            text       = content
            encoding   = enc
            fileExists = true
        case .unreadable:
            return error("Codex talimat dosyası okunamadı: \(codexAgentsPath)")
        case .missing:
            guard block != nil else { return nil }   // temizlenecek dosya yok
        }

        let state = agentsBlockState(in: text)
        if case .broken = state {
            return error("AGENTS.md içindeki BRAMPP bloğu bozuk — elle düzeltin: \(codexAgentsPath)")
        }

        let updated = applyAgentsBlock(block, to: text, at: state)
        guard updated != text else { return nil }   // yapacak bir şey yok; boşuna yedek alma

        // Yazan/silen HER yolda önce yedek: kullanıcının kendi talimatları da bu dosyada.
        if fileExists, makeBackup(of: codexAgentsPath) == nil {
            return error("Codex talimat dosyası yedeklenemedi: \(codexAgentsPath)")
        }

        // Bölüm kaldırıldıktan sonra dosyada içerik kalmadıysa dosyayı da bırakma
        if block == nil, updated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return FileHelper.remove(codexAgentsPath)
                ? nil : error("Codex talimat dosyası silinemedi: \(codexAgentsPath)")
        }
        // Dosyanın ÖZGÜN kodlaması korunur: Latin-1 bir AGENTS.md'yi UTF-8 yazmak
        // kullanıcının Türkçe karakterlerini mojibake'e çevirirdi.
        guard FileHelper.write(updated, to: codexAgentsPath, encoding: encoding) else {
            return error("Codex talimat dosyası yazılamadı: \(codexAgentsPath)")
        }
        return nil
    }

    /// İlk tam işaretçi çiftini (işaretçiler dahil) `block` ile değiştirir (`nil` ise siler);
    /// işaretçi yoksa kurulumda sona ekler. Bozuk işaretçide metne DOKUNMAZ.
    /// - Important: `state`, AYNI `text`ten `agentsBlockState(in:)` ile hesaplanmış olmalıdır
    ///   (String.Index'ler ait oldukları metne bağlıdır).
    static func applyAgentsBlock(_ block: String?, to text: String, at state: AgentsBlockState) -> String {
        switch state {
        case .broken:
            return text
        case .valid(let range):
            var out = text
            out.replaceSubrange(range, with: block ?? "")
            return out
        case .none:
            guard let block else { return text }
            var out = text
            if !out.isEmpty {
                if !out.hasSuffix("\n")   { out += "\n" }
                if !out.hasSuffix("\n\n") { out += "\n" }
            }
            return out + block + "\n"
        }
    }

    /// İşaretçileri sırayla tarar. Geçerli sayılmak için kesin dönüşümlü olmalıdır:
    /// START, END, START, END… Fazladan/eksik ya da iç içe işaretçi `.broken` döner —
    /// aksi hâlde ilk START ile tek END arasındaki KULLANICI içeriği silinirdi.
    static func agentsBlockState(in text: String) -> AgentsBlockState {
        let starts = ranges(of: agentsStart, in: text)
        let ends   = ranges(of: agentsEnd,   in: text)

        if starts.isEmpty, ends.isEmpty { return .none }
        guard starts.count == ends.count else { return .broken }

        for (start, end) in zip(starts, ends) where start.upperBound > end.lowerBound {
            return .broken                      // END, kendi START'ından önce geliyor
        }
        for i in 1..<starts.count where ends[i - 1].upperBound > starts[i].lowerBound {
            return .broken                      // bir sonraki START, önceki bloğun içinde
        }
        return .valid(starts[0].lowerBound..<ends[0].upperBound)
    }

    /// `needle`'ın metindeki tüm konumları (soldan sağa, çakışmasız).
    private static func ranges(of needle: String, in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var from = text.startIndex
        while let r = text.range(of: needle, range: from..<text.endIndex) {
            found.append(r)
            from = r.upperBound
        }
        return found
    }

    // MARK: - Yardımcılar

    private static func readDesktopConfig() -> [String: Any]? {
        guard let data = FileHelper.readData(desktopConfigPath) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// - Returns: hata varsa NSError, başarıysa nil
    private static func writeDesktopConfig(_ json: [String: Any]) -> Error? {
        // .sortedKeys YOK: kullanıcının anahtar sırasını gereksizce karıştırmayalım.
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else {
            return error("Yapılandırma JSON'a çevrilemedi")
        }
        guard FileHelper.write(data, to: desktopConfigPath) else {
            return error("Yapılandırma yazılamadı: \(desktopConfigPath)")
        }
        return nil
    }

    /// …config.json.bak-YYYYMMDD-HHmmss / …config.toml.bak-YYYYMMDD-HHmmss
    /// - Returns: yedeğin tam yolu; alınamadıysa nil
    private static func makeBackup(of path: String) -> String? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let backup = path + ".bak-" + f.string(from: Date())
        return FileHelper.copy(from: path, to: backup) ? backup : nil
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "BRAMPP.ClaudeIntegration", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
