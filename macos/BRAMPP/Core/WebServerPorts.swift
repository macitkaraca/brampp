import Foundation

/// Web sunucularının GÜNCEL dinleme portlarını config dosyalarından okur.
///
/// Şablonlar (VHostTemplates) ve `Domain.url` sabit 80/443/8080/8443 yerine bunları
/// kullanır — böylece kullanıcı Apache/Nginx portunu değiştirdiğinde yeni domainler ve
/// URL'ler doğru portu kullanır. Okuma başarısızsa güvenli varsayılana düşer.
enum WebServerPorts {

    /// "8080", "8080;", "0.0.0.0:80", "127.0.0.1:8443", "[::]:8443;" gibi değerlerden
    /// port sayısını çıkarır — son ':' sonrasını alır (IPv6 ve adres:port formu dahil).
    private static func extractPort(_ token: String) -> Int? {
        var s = token.trimmingCharacters(in: CharacterSet(charactersIn: "; \t\n"))
        if let colon = s.range(of: ":", options: .backwards) {
            s = String(s[colon.upperBound...])
        }
        return Int(s)
    }

    // MARK: - Apache

    /// httpd.conf içindeki aktif HTTP Listen portu (80'i tercih eder).
    static func apacheHTTP() -> Int {
        guard let content = FileHelper.readString(PathConfig.httpdConf) else { return 80 }
        var ports: [Int] = []
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.hasPrefix("#") else { continue }
            // Apache direktif ile değer arasında TAB dahil her boşluğu kabul eder.
            // `hasPrefix("listen ")` hem "Listen\t8080"i kaçırıyor hem de ListenBackLog gibi
            // direktifleri yanlışlıkla yakalama riski taşıyordu — token'lara ayırıp TAM eşleştir.
            let parts = t.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            guard parts.first?.lowercased() == "listen" else { continue }
            let value = parts.dropFirst().first ?? ""
            if let p = extractPort(value) { ports.append(p) }
        }
        if ports.contains(80) { return 80 }
        return ports.first ?? 80
    }

    /// httpd-ssl.conf içindeki aktif HTTPS Listen portu.
    static func apacheHTTPS() -> Int {
        guard let content = FileHelper.readString(PathConfig.httpdSSLConf) else { return 443 }
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.hasPrefix("#") else { continue }
            // Apache direktif ile değer arasında TAB dahil her boşluğu kabul eder.
            // `hasPrefix("listen ")` hem "Listen\t8080"i kaçırıyor hem de ListenBackLog gibi
            // direktifleri yanlışlıkla yakalama riski taşıyordu — token'lara ayırıp TAM eşleştir.
            let parts = t.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            guard parts.first?.lowercased() == "listen" else { continue }
            let value = parts.dropFirst().first ?? ""
            if let p = extractPort(value) { return p }
        }
        return 443
    }

    // MARK: - Nginx

    /// nginx.conf içindeki ilk SSL-olmayan listen portu.
    static func nginxHTTP() -> Int {
        readNginxListen(ssl: false) ?? 8080
    }

    /// nginx.conf içindeki ilk SSL listen portu.
    static func nginxHTTPS() -> Int {
        readNginxListen(ssl: true) ?? 8443
    }

    private static func readNginxListen(ssl: Bool) -> Int? {
        guard let content = FileHelper.readString(PathConfig.nginxConf) else { return nil }
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), t.hasPrefix("listen") else { continue }
            // Satır içi yorumu at, direktifi ';'ye kadar al — böylece "listen 8080; # ssl yok"
            // gibi bir yorumdaki "ssl" kelimesi satırı yanlışlıkla SSL saymaz.
            let noComment = t.components(separatedBy: "#").first ?? t
            let directive = noComment.components(separatedBy: ";").first ?? noComment
            let parts = directive.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }
            // "ssl" bağımsız bir listen parametresi olmalı (örn. "listen 8443 ssl http2;")
            let isSSL = parts.dropFirst().contains("ssl")
            guard isSSL == ssl else { continue }
            // parts[1] "8080", "127.0.0.1:9090" veya "[::]:8443" olabilir
            if let p = extractPort(parts[1]) { return p }
        }
        return nil
    }

    // MARK: - Web Server'a Göre

    static func httpPort(for ws: WebServer)  -> Int { ws == .apache ? apacheHTTP()  : nginxHTTP() }
    static func httpsPort(for ws: WebServer) -> Int { ws == .apache ? apacheHTTPS() : nginxHTTPS() }

    /// URL için port eki — standart portta ("" ) boş, aksi halde ":port".
    static func portSuffix(_ port: Int, https: Bool) -> String {
        let isStd = (https && port == 443) || (!https && port == 80)
        return isStd ? "" : ":\(port)"
    }
}
