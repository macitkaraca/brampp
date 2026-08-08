import Foundation

// ═══════════════════════════════════════════════════════════════════════════
//  KONSOL LOG KATALOĞU — KALAN DOSYALAR
//  Kapsam: Core/MCPServer.swift, App/BRAMPPApp.swift, Views/DomainsTabView.swift
//  Kurallar ve anahtar biçimi: Core/L10nLog.swift dosyasının başındaki blok.
//  Bu sözlük `L10n.logEntry(for:)` içinden taranır.
// ═══════════════════════════════════════════════════════════════════════════

extension L10n {

    static let logCatalog_kalan: [String: [String: String]] = [

        // ── log.mcp.* — MCP sunucusu (Core/MCPServer.swift) ─────────────────
        // %@ = dinlenen port
        "log.mcp.listening":
            ["tr": "MCP sunucusu dinlemede: http://127.0.0.1:%@/mcp",
             "en": "MCP server is listening at http://127.0.0.1:%@/mcp"],
        // %@ = hata açıklaması
        "log.mcp.startFailed":
            ["tr": "MCP sunucusu başlatılamadı: %@",
             "en": "Could not start the MCP server: %@"],
        "log.mcp.stopped":
            ["tr": "MCP sunucusu durduruldu",
             "en": "MCP server stopped"],
        // %@1 = alan adı, %@2 = platform, %@3 = web sunucusu
        "log.mcp.domainCreating":
            ["tr": "MCP: '%@' oluşturuluyor (%@ / %@)",
             "en": "MCP: creating '%@' (%@ / %@)"],
        // %@1 = alan adı, %@2 = değişiklik listesi
        "log.mcp.domainUpdating":
            ["tr": "MCP: '%@' güncelleniyor — %@",
             "en": "MCP: updating '%@' — %@"],
        // %@ = alan adı
        "log.mcp.appStarting":
            ["tr": "MCP: '%@' uygulaması başlatılıyor",
             "en": "MCP: starting the '%@' app"],
        "log.mcp.appStopping":
            ["tr": "MCP: '%@' uygulaması durduruluyor",
             "en": "MCP: stopping the '%@' app"],
        // %@1 = veritabanı adı, %@2 = motor adı
        "log.mcp.dbCreated":
            ["tr": "MCP: '%@' veritabanı oluşturuldu (%@)",
             "en": "MCP: database '%@' created (%@)"],
        // %@ = motor adı
        "log.mcp.dbQueryWrite":
            ["tr": "MCP: db_query yazma modunda çalıştırıldı (%@)",
             "en": "MCP: db_query ran in write mode (%@)"],

        // ── log.app.* — Uygulama yaşam döngüsü (App/BRAMPPApp.swift) ────────
        "log.app.backendProcessesStopped":
            ["tr": "↳ Domain backend prosesleri durduruldu",
             "en": "↳ Domain backend processes stopped"],
        // %@ = servis adı
        "log.app.startingForWebServer":
            ["tr": "↳ %@ başlatılıyor (web sunucusu bağımlılığı)",
             "en": "↳ Starting %@ (web server dependency)"],
        "log.app.brewMissing":
            ["tr": "Homebrew kurulu değil",
             "en": "Homebrew is not installed"],

        // ── log.dom.* — Domain arayüzü (Views/DomainsTabView.swift) ─────────
        // %@ = hata açıklaması
        "log.dom.configLoadFailed":
            ["tr": "Config yüklenemedi: %@",
             "en": "Could not load the config: %@"],
        "log.dom.jsonLoadFailed":
            ["tr": "JSON yüklenemedi: %@",
             "en": "Could not load the JSON file: %@"],
    ]
}
