import Foundation

/// Bir alan adı için açılmış Cloudflare Quick Tunnel.
///
/// KALICI DEĞİLDİR: diske yazılmaz, uygulama yeniden açıldığında hiçbir tünel geri
/// gelmez. Herkese açık bir adresin kullanıcının haberi olmadan yeniden canlanması
/// kabul edilebilir bir varsayılan değil.
struct Tunnel: Identifiable, Equatable {
    enum State: Equatable {
        /// cloudflared başlatıldı, adres henüz log dosyasında görünmedi
        case starting
        /// Adres alındı, tünel yayında
        case active
        /// Süreç öldü ya da adres zaman aşımına uğradı
        case failed(String)
    }

    /// Alan adı — aynı zamanda kimlik: bir alan adının tek tüneli olur
    let domainName: String
    /// cloudflared'in yerelde hedeflediği adres (`https://projem.test`)
    let origin: String
    /// `https://<rastgele>.trycloudflare.com` — henüz alınmadıysa nil
    var publicURL: String?
    var pid: Int?
    var startedAt: Date
    var state: State

    var id: String { domainName }

    var isLive: Bool {
        if case .active = state, publicURL != nil { return true }
        return false
    }
}
