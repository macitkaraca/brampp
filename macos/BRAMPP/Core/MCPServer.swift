import Foundation
import Combine
import Network

// MARK: - HTTP Ayrıştırma Modelleri

/// Ayrıştırılmış minimal HTTP/1.1 isteği.
private struct HTTPRequest {
    let method: String
    /// Sorgu dizesi ayıklanmış yol (ör. "/mcp")
    let path: String
    /// Başlık adları KÜÇÜK HARFE indirgenmiş (HTTP başlıkları harf duyarsızdır)
    let headers: [String: String]
    let body: Data
}

/// Biriken tampondan istek çıkarma sonucu.
private enum HTTPParseResult {
    /// Başlıklar veya gövde henüz tamamlanmadı — okumaya devam
    case incomplete
    /// İstek satırı okunamadı — 400
    case invalid
    case request(HTTPRequest)
}

/// Bir aracın sonucu — JSON-RPC katmanı bunu uygun yanıta çevirir.
///
/// `Error` uyumu yalnızca `Result<Domain, ToolOutcome>` ile erken çıkış yapabilmek
/// içindir (`resolveDomain`); hiçbir yerde `throw` edilmez.
private enum ToolOutcome: Error {
    /// Başarılı sonuç metni (isError: false)
    case text(String)
    /// Araç çalıştı ama işlem başarısız (isError: true)
    case failure(String)
    /// Argüman eksik/geçersiz → JSON-RPC -32602
    case invalidParams(String)
}

/// Bir MCP aracının tam künyesi: JSON şeması + erişim alanı + ek açıklamalar.
///
/// Şema ve izin AYNI kayıtta tutulur — ayrı bir izin tablosu olsaydı yeni bir araç
/// eklenip tabloya yazılmayı unutulduğunda araç sessizce KORUMASIZ kalırdı.
private struct ToolSpec {
    let name: String
    /// `annotations.title` — insan-okur kısa ad
    let title: String
    let description: String
    let inputSchema: [String: Any]

    /// Aracın bağlı olduğu erişim alanı (Ayarlar → MCP → Erişim İzinleri)
    let scope: MCPScope
    /// true → çalıştırmak için alanda YAZMA izni gerekir; false → OKUMA yeter
    let needsWrite: Bool

    /// `annotations.readOnlyHint` — ortamda hiçbir değişiklik yapmaz.
    /// `needsWrite`ten AYRI tutulur: `db_query` okuma izniyle çalışır ama
    /// `allow_write=true` ile yazabildiğinden salt-okunur DEĞİLDİR.
    let readOnly: Bool
    /// `annotations.destructiveHint` — geri alınamaz veya kesinti yaratan etki
    let destructive: Bool
    /// `annotations.idempotentHint` — aynı argümanlarla tekrar çağırmak ek etki yaratmaz
    let idempotent: Bool

    init(_ name: String, title: String, description: String,
         schema: [String: Any], scope: MCPScope, needsWrite: Bool,
         readOnly: Bool? = nil, destructive: Bool = false, idempotent: Bool = true) {
        self.name        = name
        self.title       = title
        self.description = description
        self.inputSchema = schema
        self.scope       = scope
        self.needsWrite  = needsWrite
        self.readOnly    = readOnly ?? !needsWrite
        self.destructive = destructive
        self.idempotent  = idempotent
    }

    /// Verilen ayarlarla bu araç çağrılabilir mi?
    func isPermitted(in settings: AppSettings) -> Bool {
        let level = scope.permission(in: settings)
        return needsWrite ? level.allowsWrite : level.allowsRead
    }

    /// MCP `tools/list` girdisi
    var json: [String: Any] {
        let annotations: [String: Any] = [
            "title":           title,
            "readOnlyHint":    readOnly,
            "destructiveHint": destructive,
            "idempotentHint":  idempotent
        ]
        return [
            "name":        name,
            "description": description,
            "inputSchema": inputSchema,
            "annotations": annotations
        ]
    }
}

// MARK: - MCPServer

/// BRAMPP içi MCP (Model Context Protocol) sunucusu.
///
/// Claude gibi yapay zekâ araçları, BRAMPP'in CANLI manager'ları üzerinden alan adı,
/// servis ve veritabanı işlemleri yapabilsin diye 127.0.0.1'e bağlı minimal bir
/// HTTP/JSON-RPC uç noktası (`POST /mcp`) yayınlar. Tüm araçlar doğrudan
/// `DomainManager`/`ServiceManager` çağırdığından değişiklikler arayüze anında yansır.
///
/// Taşıma katmanı MCP "streamable-http" profilinin DURUMSUZ (stateless) biçimidir:
/// oturum üretilmez (`Mcp-Session-Id` yok), her istek tek yanıtla kapanır.
@MainActor
final class MCPServer: ObservableObject {

    // MARK: - Yayınlanan Durum

    @Published var isRunning = false
    /// Son başlatma hatası (port dolu, izin yok…) — Ayarlar ekranında gösterilir
    @Published var lastError: String? = nil

    private var listener: NWListener?

    /// Bir dinleyici nesnesi CANLI mı?
    ///
    /// Port meşgulken listener `.waiting` durumunda bekler: `isRunning` false'tur ama
    /// nesne yaşar ve port serbest kalınca kendi kendine `.ready` olur. Bu durumda
    /// yeniden başlatmak hiçbir şey kazandırmaz, yalnızca her tazeleme turunda bir
    /// "durduruldu" satırı üretir.
    var hasActiveListener: Bool { listener != nil }
    /// Gerçekten dinlenen port — Ayarlar bunu gösterir (istenen port geçersizse
    /// varsayılana düşülür ve arayüz gerçek adresi göstermelidir).
    @Published private(set) var port: Int = 8765

    /// Kabul edilmiş açık bağlantılar — stop() hepsini kapatır (listener.cancel()
    /// yalnızca yeni kabulü durdurur, teslim edilmiş bağlantıları değil).
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// Bağlantı başına OKUMA zaman aşımı sayaçları — istek tamamlanınca iptal edilir.
    private var readTimeouts: [ObjectIdentifier: Task<Void, Never>] = [:]

    // MARK: - Manager Bağları

    /// Manager'ların sahibi AppState'tir; MCPServer yalnızca ödünç kullanır → ZAYIF referans
    /// (aksi halde AppState ↔ MCPServer arasında güçlü döngü oluşurdu).
    private weak var serviceManager: ServiceManager?
    private weak var domainManager: DomainManager?
    private weak var consoleStore: ConsoleStore?
    private weak var tunnelManager: TunnelManager?

    // MARK: - Sabitler

    /// NWListener/NWConnection geri çağrılarının koştuğu kuyruk (MainActor DEĞİL).
    private static let queue = DispatchQueue(label: "com.brampp.mcp", qos: .userInitiated)

    /// Tek bir isteğin kabul edilebilir en büyük boyutu (başlık + gövde) — 1 MB.
    private static let maxRequestBytes = 1_048_576

    /// Aynı anda açık tutulabilecek en fazla bağlantı (boşta bekleyenler birikmesin).
    private static let maxConnections = 32

    /// Bağlantı başına İSTEK OKUMA süresi — bu süre içinde TAM istek gelmezse kapatılır.
    /// İstek ayrıştırıldıktan sonra sayaç iptal edilir (uzun süren araç çağrıları kesilmesin).
    private static let connectionTimeout = 30

    /// `update_domain` web sunucusu değişiminde silinen vhost'un geri-alma izleme süresi.
    /// Doğrulama zinciri (mkcert + bağımlılık başlatma + configtest) dakikayı bulabilir.
    private static let rollbackWatchSeconds: TimeInterval = 180

    /// Konuşulabilen MCP protokol sürümleri — istemcininki listedeyse AYNEN yankılanır.
    private static let knownProtocolVersions: Set<String> = ["2024-11-05", "2025-03-26", "2025-06-18"]
    private static let defaultProtocolVersion = "2025-06-18"

    /// Sunucu sürümü — bundle'dan okunur (MARKETING_VERSION ile otomatik senkron)
    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1"
    }

    // MARK: - Kurulum

    /// Canlı manager'ları enjekte eder. AppState.bootstrapManagers() içinde çağrılır.
    func configure(serviceManager: ServiceManager,
                   domainManager: DomainManager,
                   consoleStore: ConsoleStore,
                   tunnelManager: TunnelManager) {
        self.serviceManager = serviceManager
        self.domainManager  = domainManager
        self.consoleStore   = consoleStore
        self.tunnelManager  = tunnelManager
    }

    /// Konsola ÇEVRİLEBİLİR satır yaz — metin gösterim anında çözülür.
    /// Anahtar/argüman kuralları: Core/L10nLog.swift.
    private func log(key: String, args: [String] = [], type: ConsoleEntryType = .info) {
        consoleStore?.log(key: key, args: args, type: type)
    }

    // MARK: - Başlat / Durdur

    /// Sunucuyu verilen portta başlatır. Zaten çalışıyorsa önce durdurulur.
    func start(port requestedPort: Int) {
        stop()

        // Ayrıcalıklı portlar (<1024) root ister; geçersiz değerde varsayılana dön
        let resolved = (1024...65_535).contains(requestedPort) ? requestedPort : 8765
        port = resolved

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(resolved)) else {
            lastError = "Geçersiz port: \(requestedPort)"
            isRunning = false
            return
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // YALNIZCA loopback'e bağlan — sunucu ağdan erişilebilir OLMAMALI
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)

        do {
            let newListener = try NWListener(using: parameters)

            // Durum geri çağrısı ağ kuyruğunda koşar → MainActor'a atla.
            // `self.listener === l` kontrolü ŞART: durdurulup yeniden başlatılan bir
            // sunucuda ESKİ listener'ın gecikmeli `.cancelled` olayı, yeni listener
            // `.ready` olduktan SONRA gelip isRunning'i yanlışlıkla false yapardı.
            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                Task { @MainActor in
                    guard let self, let l = newListener, self.listener === l else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.lastError = nil
                        self.log(key: "log.mcp.listening", args: ["\(self.port)"], type: .success)
                    case .failed(let error):
                        self.isRunning = false
                        self.lastError = error.localizedDescription
                        self.log(key: "log.mcp.startFailed", args: [error.localizedDescription], type: .error)
                        l.cancel()
                        self.listener = nil
                    case .waiting(let error):
                        // Port meşgul olabilir — hata gösterilir, listener beklemeye devam eder
                        self.lastError = error.localizedDescription
                    case .cancelled:
                        self.isRunning = false
                    default:
                        break
                    }
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self else { connection.cancel(); return }
                    self.accept(connection)
                }
            }

            listener  = newListener
            lastError = nil
            newListener.start(queue: Self.queue)
        } catch {
            listener  = nil
            isRunning = false
            lastError = error.localizedDescription
            log(key: "log.mcp.startFailed", args: [error.localizedDescription], type: .error)
        }
    }

    /// Sunucuyu durdurur. Çalışmıyorsa sessizce döner (log kirletmez).
    func stop() {
        // Kabul edilmiş bağlantılar da kapatılmalı: NWListener.cancel() yalnızca YENİ
        // bağlantı kabulünü durdurur; teslim edilmiş bağlantılar bağımsız yaşar ve
        // "kapalı" görünen sunucu üzerinden araç çağrısı işlemeye devam ederdi.
        let open = connections.values
        connections.removeAll()
        for timeout in readTimeouts.values { timeout.cancel() }
        readTimeouts.removeAll()
        for c in open { c.cancel() }

        guard let current = listener else {
            isRunning = false
            return
        }
        listener = nil
        current.cancel()
        isRunning = false
        log(key: "log.mcp.stopped", type: .info)
    }

    // MARK: - Bağlantı Yaşam Döngüsü

    private func accept(_ connection: NWConnection) {
        // Eşzamanlı bağlantı tavanı: veri göndermeyen istemciler sınırsız birikmesin
        guard connections.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                connection.cancel()
                Task { @MainActor in self?.forget(connection) }
            default:
                break
            }
        }
        connection.start(queue: Self.queue)
        // Okuma zaman aşımı: hiç (ya da yarım) veri gönderen bağlantı süresiz askıda kalmasın.
        // YALNIZCA istek gövdesi tamamlanana kadar geçerlidir — bkz. disarmReadTimeout.
        let key = ObjectIdentifier(connection)
        readTimeouts[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.connectionTimeout))
            guard !Task.isCancelled, let self, self.connections[key] != nil else { return }
            connection.cancel()
            self.forget(connection)
        }
        receive(on: connection, buffer: Data())
    }

    /// İstek TAM olarak ayrıştırıldığında okuma zaman aşımını iptal eder.
    ///
    /// Sayaç eskiden KOŞULSUZ işliyordu: `create_domain` gibi mkcert + yönetici onayı +
    /// configtest zinciri çalıştıran bir araç 30 sn'yi aşınca bağlantı kapanıyor, istemci
    /// yanıtı ALAMIYOR ama işlem ZATEN yapılmış oluyordu (alan adı oluşmuş, ajan habersiz).
    /// Artık yalnızca "istek hâlâ okunuyor" evresini sınırlar; yanıt yazımı beklenir.
    private func disarmReadTimeout(for connection: NWConnection) {
        readTimeouts.removeValue(forKey: ObjectIdentifier(connection))?.cancel()
    }

    /// Bağlantıyı kayıttan düşürür (kapandığında veya zaman aşımında).
    private func forget(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        readTimeouts.removeValue(forKey: key)?.cancel()
        connections.removeValue(forKey: key)
    }

    /// Veriyi `\r\n\r\n` görünene ve Content-Length kadar gövde birikene dek toplar.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            var accumulated = buffer
            if let data, !data.isEmpty { accumulated.append(data) }
            if error != nil { connection.cancel(); return }

            let snapshot = accumulated
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                switch MCPServer.parse(snapshot) {
                case .request(let request):
                    // İstek eksiksiz okundu → okuma sayacı burada durur; araç çağrısı
                    // ne kadar sürerse sürsün yanıt istemciye ulaşabilsin.
                    self.disarmReadTimeout(for: connection)
                    await self.respond(to: request, on: connection)
                case .invalid:
                    self.disarmReadTimeout(for: connection)
                    MCPServer.send(400, body: nil, on: connection)
                case .incomplete:
                    // Karşı taraf yazmayı bitirdiyse istek eksik demektir
                    if isComplete { connection.cancel(); return }
                    guard snapshot.count <= MCPServer.maxRequestBytes else {
                        MCPServer.send(413, body: nil, on: connection)
                        return
                    }
                    self.receive(on: connection, buffer: snapshot)
                }
            }
        }
    }

    // MARK: - Yönlendirme

    private func respond(to request: HTTPRequest, on connection: NWConnection) async {
        // DNS rebinding önlemi: tarayıcıdan gelen isteklerde Origin bulunur; yerel
        // olmayan bir köken, kötü niyetli bir sayfanın localhost'a sızmaya çalıştığını
        // gösterir. Origin YOKSA (CLI/MCP istemcisi) istek kabul edilir.
        // Host TAM eşleşmeli — hasPrefix ile "http://localhost.saldirgan.com" filtreyi
        // aşıyordu (saldırgan böyle bir alan adını 127.0.0.1'e çözdürüp tüm araç setini
        // kurbanın tarayıcısından çağırabilirdi).
        if let origin = request.headers["origin"], !Self.isLoopbackOrigin(origin) {
            send403(on: connection)
            return
        }
        // Host başlığı da aynı ölçüte tabi: rebinding'de Host da saldırganın adını taşır.
        if let host = request.headers["host"], !Self.isLoopbackHost(host) {
            send403(on: connection)
            return
        }

        // Parçalı (chunked) gövde ÇÖZÜLMEZ: ayrıştırıcı yalnızca Content-Length'e bakar,
        // bu yüzden böyle bir istek BOŞ GÖVDELİ görünür ve istemci sebebini anlamadan
        // -32700 ("JSON ayrıştırılamadı") alırdı. Nedenini söyleyerek açıkça reddet.
        // ("identity" tek istisnadır: hiçbir kodlama uygulanmadığı anlamına gelir.)
        if let encoding = request.headers["transfer-encoding"],
           encoding.trimmingCharacters(in: .whitespaces).lowercased() != "identity" {
            Self.send(501, body: Self.textBody(
                "Transfer-Encoding desteklenmiyor (\(encoding)) — isteği Content-Length "
                + "başlığıyla, parçalanmamış tek gövde olarak gönderin."),
                      contentType: "text/plain; charset=utf-8", on: connection)
            return
        }

        // Tarayıcıdan GET ile açıldığında (Accept: text/html) kurulum sayfası gösterilir.
        // MCP istemcileri "application/json, text/event-stream" gönderdiğinden bu daldan
        // ETKİLENMEZ — onlar için aşağıdaki protokol davranışı (POST / 405) aynen sürer.
        let wantsHTML = (request.headers["accept"] ?? "").contains("text/html")
        let setupPaths: Set<String> = ["/mcp", "/mcp/", "/"]
        if request.method == "GET", wantsHTML, setupPaths.contains(request.path) {
            // Kurulum sayfası TÜM araçları gösterir: burası uygulamanın tanıtımıdır,
            // izin süzmesi yalnızca MCP protokolüne (tools/list + tools/call) uygulanır.
            let page = MCPSetupPage.html(port: port,
                                         toolNames: Self.allToolNames(),
                                         languageCode: Localizer.shared.language.effectiveCode)
            Self.send(200, body: Self.textBody(page),
                      contentType: "text/html; charset=utf-8", on: connection)
            return
        }

        guard request.path == "/mcp" else {
            Self.send(404, body: Self.textBody("Bulunamadı — MCP uç noktası: POST /mcp"),
                      contentType: "text/plain; charset=utf-8", on: connection)
            return
        }

        switch request.method {
        case "POST":
            let (status, payload) = await handleJSONRPC(body: request.body)
            Self.send(status, body: payload,
                      contentType: payload == nil ? nil : "application/json", on: connection)
        default:
            // GET dahil diğer metotlar: bu sunucu SSE akışı sunmaz (durumsuz profil)
            Self.send(405, body: Self.textBody("Yalnızca POST desteklenir"),
                      contentType: "text/plain; charset=utf-8", on: connection)
        }
    }

    private func send403(on connection: NWConnection) {
        Self.send(403, body: Self.textBody("Origin reddedildi — yalnızca yerel kökenler kabul edilir"),
                  contentType: "text/plain; charset=utf-8", on: connection)
    }

    // MARK: - JSON-RPC 2.0

    /// - Returns: (HTTP durum kodu, gövde) — bildirimlerde gövde `nil` (202).
    private func handleJSONRPC(body: Data) async -> (Int, Data?) {
        guard let object = try? JSONSerialization.jsonObject(with: body) else {
            return (200, Self.encode(Self.rpcError(id: NSNull(), code: -32700, message: "JSON ayrıştırılamadı")))
        }
        guard let message = object as? [String: Any] else {
            return (200, Self.encode(Self.rpcError(id: NSNull(), code: -32600,
                                                   message: "Toplu (batch) istek desteklenmiyor")))
        }

        let id = message["id"]
        // Bildirim (id yok / null) — notifications/initialized dahil: gövdesiz 202
        guard let id, !(id is NSNull) else { return (202, nil) }

        guard let method = message["method"] as? String else {
            return (200, Self.encode(Self.rpcError(id: id, code: -32600, message: "'method' alanı eksik")))
        }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            // İstemcinin sürümü tanıdıksa uzlaşma için kendi sürümümüzü öneririz
            var version = Self.defaultProtocolVersion
            if let clientVersion = params["protocolVersion"] as? String,
               Self.knownProtocolVersions.contains(clientVersion) {
                version = clientVersion
            }
            let result: [String: Any] = [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "BRAMPP", "version": Self.appVersion]
            ]
            return (200, Self.encode(Self.rpcResult(id: id, result: result)))

        case "ping":
            return (200, Self.encode(Self.rpcResult(id: id, result: [String: Any]())))

        case "tools/list":
            // İzin verilmeyen araçlar hiç GÖRÜNMEZ — yapay zekâ istemcisi yasak bir işlemi
            // denemeye kalkışmasın. (Yine de denerse tools/call ayrıca reddeder.)
            return (200, Self.encode(Self.rpcResult(id: id, result: ["tools": Self.permittedToolDefinitions()])))

        case "tools/call":
            guard let toolName = params["name"] as? String, !toolName.isEmpty else {
                return (200, Self.encode(Self.rpcError(id: id, code: -32602, message: "'name' alanı eksik")))
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            switch await callTool(name: toolName, arguments: arguments) {
            case .invalidParams(let message):
                return (200, Self.encode(Self.rpcError(id: id, code: -32602, message: message)))
            case .text(let text):
                return (200, Self.encode(Self.rpcResult(id: id, result: Self.toolContent(text, isError: false))))
            case .failure(let text):
                return (200, Self.encode(Self.rpcResult(id: id, result: Self.toolContent(text, isError: true))))
            }

        default:
            return (200, Self.encode(Self.rpcError(id: id, code: -32601, message: "Bilinmeyen metot: \(method)")))
        }
    }

    private static func rpcResult(id: Any, result: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func rpcError(id: Any, code: Int, message: String) -> [String: Any] {
        let payload: [String: Any] = ["code": code, "message": message]
        return ["jsonrpc": "2.0", "id": id, "error": payload]
    }

    private static func toolContent(_ text: String, isError: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    // MARK: - Araç Tanımları

    /// JSON Schema özelliği — `enum` verilirse izin verilen değerler kısıtlanır.
    private static func property(_ type: String, _ description: String,
                                 allowed: [String]? = nil) -> [String: Any] {
        var property: [String: Any] = ["type": type, "description": description]
        if let allowed { property["enum"] = allowed }
        return property
    }

    /// JSON Schema nesnesi (inputSchema) — argümansız araçlarda `properties` boştur.
    private static func schema(_ properties: [String: Any] = [:],
                               required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    /// Uygulama süreci yönetilen platformlar — PHP ve static'te başlatılacak bir süreç yoktur.
    private static let appPlatforms: Set<Platform> = [.nodejs, .python, .dotnet]

    /// Motor seçimi yapılan veritabanı araçlarında kabul edilen değerler.
    private static let dbEngines = ["mysql", "postgres"]

    private static func toolSpecs() -> [ToolSpec] {
        let nameOnly: [String: Any] = ["name": property("string", "Alan adı")]

        let createProperties: [String: Any] = [
            "name": property("string", "Alan adı, ör. myapp.test"),
            "platform": property("string", "Varsayılan: php",
                                 allowed: ["php", "nodejs", "python", "dotnet", "static"]),
            "web_server": property("string", "Varsayılan: apache", allowed: ["apache", "nginx"]),
            "port": property("integer", "Backend portu (nodejs/python/dotnet). Belirtilmezse boş bir port atanır."),
            "ssl": property("boolean", "HTTPS sertifikası üret — varsayılan: true")
        ]
        let updateProperties: [String: Any] = [
            "name": property("string", "Güncellenecek alan adı"),
            "php_version": property("string", "Yalnızca PHP domainlerinde",
                                    allowed: PHPVersion.allCases.map(\.rawValue)),
            "port": property("integer", "Backend portu — yalnızca nodejs/python/dotnet domainlerinde"),
            "ssl": property("boolean", "HTTPS aç/kapat. Kapatılırsa HTTP→HTTPS yönlendirmesi de kapanır."),
            "web_server": property("string", "Web sunucusunu değiştirir — eski sunucunun vhost'u kaldırılır",
                                   allowed: ["apache", "nginx"]),
            "document_root": property("string", "Site klasörünün mutlak yolu, ör. /Users/ben/Projeler/site"),
            "service_dependencies": [
                "type": "array",
                "description": "Başlatılmadan önce çalışıyor olması gereken servis id'leri, ör. [\"mariadb\",\"redis\"]. Boş dizi: bağımlılık yok.",
                "items": ["type": "string"]
            ]
        ]
        let enabledProperties: [String: Any] = [
            "name": property("string", "Alan adı"),
            "enabled": property("boolean", "true: etkinleştir, false: devre dışı bırak")
        ]
        let domainLogProperties: [String: Any] = [
            "name": property("string", "Alan adı"),
            "kind": property("string", "Hangi log — varsayılan: error. 'app' yalnızca nodejs/python/dotnet domainlerinde vardır.",
                             allowed: ["error", "access", "app"]),
            "lines": property("integer", "Kaç satır — varsayılan 100, en çok 1000")
        ]
        let serviceProperties: [String: Any] = [
            "id": property("string", "Servis id'si, ör. mariadb")
        ]
        let logProperties: [String: Any] = [
            "lines": property("integer", "Kaç satır — varsayılan 50, en çok 500"),
            "level": property("string", "Düzeye göre süz — varsayılan all",
                              allowed: ["all", "error", "warning"]),
            "search": property("string", "Yalnızca bu metni içeren satırlar (büyük/küçük harf duyarsız)"),
            "since_minutes": property("integer", "Yalnızca son N dakika"),
            "source": property("string", "memory = canlı tampon (son ~300 satır), file = diskteki günlük geçmiş",
                               allowed: ["memory", "file"])
        ]
        let installProperties: [String: Any] = [
            "name": property("string", "Servis kimliği — service_status çıktısındaki id "
                             + "(ör. cloudflared, mailpit, redis, php@8.4)")
        ]
        let shareProperties: [String: Any] = [
            "name": property("string", "Alan adı, ör. myapp.test")
        ]
        let startShareProperties: [String: Any] = [
            "name": property("string", "Paylaşılacak alan adı — 'port' verilmezse zorunlu"),
            "port": property("integer", "Alan adı yerine YEREL BİR HTTP PORTU paylaş "
                             + "(ör. 5173 — npm run dev). Veritabanı/önbellek portları reddedilir.")
        ]
        let dbListProperties: [String: Any] = [
            "engine": property("string", "Varsayılan: mysql", allowed: dbEngines)
        ]
        let dbCreateProperties: [String: Any] = [
            "name": property("string", "Veritabanı adı — yalnızca harf, rakam ve alt çizgi"),
            "engine": property("string", "Varsayılan: mysql", allowed: dbEngines)
        ]
        let dbExportProperties: [String: Any] = [
            "name": property("string", "Dökümü alınacak veritabanı adı"),
            "engine": property("string", "Varsayılan: mysql", allowed: dbEngines),
            "path": property("string", "Hedef .sql dosyasının MUTLAK yolu. Verilmezse ~/Library/Application Support/BRAMPP/backups altına zaman damgalı yazılır.")
        ]
        let dbImportProperties: [String: Any] = [
            "name": property("string", "Dökümün uygulanacağı hedef veritabanı adı"),
            "path": property("string", "Okunacak .sql dosyasının MUTLAK yolu"),
            "engine": property("string", "Varsayılan: mysql", allowed: dbEngines),
            "create_if_missing": property("boolean", "Hedef veritabanı yoksa oluştur — varsayılan: true")
        ]
        let dbQueryProperties: [String: Any] = [
            "sql": property("string", "Çalıştırılacak tek SQL ifadesi"),
            "engine": property("string", "Varsayılan: mysql", allowed: dbEngines),
            "database": property("string", "Bağlanılacak veritabanı — verilmezse mysql'de veritabanı seçilmez, postgres'te 'postgres' kullanılır"),
            "allow_write": property("boolean", "Veri değiştiren ifadelere izin ver — varsayılan: false. true için veritabanları alanında YAZMA izni gerekir."),
            "max_rows": property("integer", "En çok kaç satır döndürülsün — varsayılan 100, en çok 1000")
        ]

        return [
            // MARK: Alan adları
            ToolSpec("list_domains",
                     title: "Alan Adlarını Listele",
                     description: "BRAMPP'te kayıtlı tüm alan adlarını listeler (platform, web sunucusu, port, etkin/çalışıyor, SSL).",
                     schema: schema(), scope: .domains, needsWrite: false),
            ToolSpec("create_domain",
                     title: "Alan Adı Oluştur",
                     description: "Yeni bir alan adı oluşturur: site klasörü, vhost, SSL sertifikası ve /etc/hosts girişi.",
                     schema: schema(createProperties, required: ["name"]),
                     scope: .domains, needsWrite: true, idempotent: false),
            ToolSpec("update_domain",
                     title: "Alan Adını Güncelle",
                     description: "Var olan bir alan adının ayarlarını değiştirir (PHP sürümü, port, SSL, web sunucusu, site klasörü, servis bağımlılıkları). YALNIZCA verilen alanlar değişir; vhost yeniden üretilir.",
                     schema: schema(updateProperties, required: ["name"]),
                     // destructive: site klasörünü değiştirebilir ve web sunucusu
                     // değişiminde ESKİ vhost dosyasını kaldırır — geri alınamaz etki.
                     scope: .domains, needsWrite: true, destructive: true),
            ToolSpec("set_domain_enabled",
                     title: "Alan Adını Etkinleştir/Devre Dışı Bırak",
                     description: "Alan adını etkinleştirir veya devre dışı bırakır (kayıt ve dosyalar korunur; vhost + hosts girişi kaldırılır/yeniden üretilir).",
                     schema: schema(enabledProperties, required: ["name", "enabled"]),
                     scope: .domains, needsWrite: true, destructive: true),
            ToolSpec("health_check",
                     title: "Bağlantı Testi",
                     description: "Alan adına gerçek bir HTTP isteği atarak sitenin yanıt verip vermediğini doğrular (yalnızca 'servis çalışıyor' bilgisinden farklı, uçtan uca test).",
                     schema: schema(nameOnly, required: ["name"]),
                     scope: .domains, needsWrite: false),
            ToolSpec("start_app",
                     title: "Uygulamayı Başlat",
                     description: "Node.js / Python / .NET alan adının arka plan uygulamasını başlatır (bağımlılık kurulumu ve start.sh dahil). PHP ve static platformlarda geçerli değildir.",
                     schema: schema(nameOnly, required: ["name"]),
                     scope: .domains, needsWrite: true),
            ToolSpec("stop_app",
                     title: "Uygulamayı Durdur",
                     description: "Node.js / Python / .NET alan adının çalışan arka plan uygulamasını durdurur.",
                     schema: schema(nameOnly, required: ["name"]),
                     scope: .domains, needsWrite: true, destructive: true),
            ToolSpec("app_status",
                     title: "Uygulama Durumu",
                     description: "Node.js / Python / .NET uygulamasının çalışma bilgisini döndürür (çalışıyor mu, PID'ler, komut, CPU, bellek).",
                     schema: schema(nameOnly, required: ["name"]),
                     scope: .domains, needsWrite: false),

            // MARK: Servisler
            ToolSpec("service_status",
                     title: "Servis Durumları",
                     description: "Tüm servislerin durumunu döndürür (id, ad, durum, port, sürüm).",
                     schema: schema(), scope: .services, needsWrite: false),
            ToolSpec("start_service",
                     title: "Servisi Başlat",
                     description: "Bir brew servisini başlatır (ör. httpd, nginx, mariadb, php@8.3, redis).",
                     schema: schema(serviceProperties, required: ["id"]),
                     scope: .services, needsWrite: true),
            ToolSpec("stop_service",
                     title: "Servisi Durdur",
                     description: "Bir brew servisini durdurur (ör. httpd, nginx, mariadb, php@8.3, redis).",
                     schema: schema(serviceProperties, required: ["id"]),
                     scope: .services, needsWrite: true, destructive: true),
            ToolSpec("install_service",
                     title: "Servis Kur",
                     description: "Kurulu olmayan bir servisi Homebrew ile kurar (brew install). "
                         + "Dakikalar sürebilir; ilerleme BRAMPP penceresinde görünür. Yalnızca "
                         + "KATALOGDAKİ servisler kurulabilir — rastgele formül adı kabul edilmez.",
                     schema: schema(installProperties, required: ["name"]),
                     scope: .services, needsWrite: true, readOnly: false, destructive: false),
            ToolSpec("restart_service",
                     title: "Servisi Yeniden Başlat",
                     description: "Bir brew servisini yeniden başlatır — yapılandırma değişikliğini uygulamak için (kısa bir kesinti oluşur).",
                     schema: schema(serviceProperties, required: ["id"]),
                     scope: .services, needsWrite: true, destructive: true),

            // MARK: Veritabanları
            ToolSpec("db_list",
                     title: "Veritabanlarını Listele",
                     description: "MariaDB/MySQL veya PostgreSQL veritabanlarını listeler.",
                     schema: schema(dbListProperties), scope: .databases, needsWrite: false),
            ToolSpec("db_create",
                     title: "Veritabanı Oluştur",
                     description: "Yeni bir MariaDB/MySQL veya PostgreSQL veritabanı oluşturur (varsa dokunmaz).",
                     schema: schema(dbCreateProperties, required: ["name"]),
                     scope: .databases, needsWrite: true),
            ToolSpec("db_export",
                     title: "Veritabanını Dışa Aktar (dump)",
                     description: "Bir veritabanının .sql dökümünü alır. MariaDB/MySQL için `mysqldump --single-transaction --routines --triggers`, PostgreSQL için `pg_dump` kullanılır — biçim standarttır, başka araçlarla da geri yüklenebilir. 'path' verilmezse döküm ~/Library/Application Support/BRAMPP/backups altına zaman damgalı adla yazılır. Döküm başarısız olursa yarım dosya SİLİNİR.",
                     schema: schema(dbExportProperties, required: ["name"]),
                     scope: .databases, needsWrite: true),
            ToolSpec("db_import",
                     title: "Veritabanına İçe Aktar (restore)",
                     description: "Bir .sql dökümünü hedef veritabanına uygular. Hedef yoksa create_if_missing=true ile oluşturulur. DİKKAT: döküm DROP/CREATE TABLE içeriyorsa mevcut veriler değişir — önce db_export ile yedek alın.",
                     schema: schema(dbImportProperties, required: ["name", "path"]),
                     scope: .databases, needsWrite: true, destructive: true),
            ToolSpec("db_query",
                     title: "SQL Sorgusu Çalıştır",
                     description: "Tek bir SQL ifadesi çalıştırır. Varsayılan olarak YALNIZCA okuma (SELECT/SHOW/DESCRIBE/EXPLAIN/WITH) kabul edilir; gövdesinde veri değiştiren komut (INSERT/UPDATE/DELETE/DROP/… veya INTO OUTFILE) geçen sorgular — veri değiştiren CTE'ler dâhil — ve dosya sistemine erişen fonksiyonlar (LOAD_FILE, pg_read_file, lo_import/lo_export, pg_ls_*, DBMS_*) reddedilir. Veri değiştirmek için allow_write=true gerekir.",
                     schema: schema(dbQueryProperties, required: ["sql"]),
                     scope: .databases, needsWrite: false,
                     readOnly: false, destructive: true, idempotent: false),

            // MARK: Loglar
            ToolSpec("read_log",
                     title: "BRAMPP Konsolunu Oku",
                     description: "BRAMPP konsolundaki son kayıtları döndürür (hata ayıklama için).",
                     schema: schema(logProperties), scope: .logs, needsWrite: false),
            ToolSpec("read_domain_log",
                     title: "Alan Adı Logunu Oku",
                     description: "Bir alan adının web sunucusu error/access logunu veya (nodejs/python/dotnet için) uygulama logunu okur.",
                     schema: schema(domainLogProperties, required: ["name"]),
                     scope: .logs, needsWrite: false),

            // MARK: Paylaşım (Cloudflare Quick Tunnel)
            ToolSpec("list_shares",
                     title: "Paylaşımları Listele",
                     description: "Şu anda açık olan Cloudflare tünellerini ve herkese açık adreslerini döndürür.",
                     schema: schema(), scope: .sharing, needsWrite: false),
            ToolSpec("start_share",
                     title: "Paylaşımı Başlat",
                     description: "Bir alan adı (veya 'port' ile yerel bir HTTP portu) için Cloudflare "
                         + "Quick Tunnel açar ve HERKESE AÇIK bir https://<rastgele>.trycloudflare.com "
                         + "adresi döndürür. UYARI: bu adresi bilen herkes siteye erişebilir; sitede "
                         + "kimlik doğrulaması yoksa verileri de görür. Kullanıcı açıkça istemeden "
                         + "ÇAĞIRMA. Adres geçicidir, paylaşım durunca ölür.",
                     schema: schema(startShareProperties),
                     scope: .sharing, needsWrite: true, readOnly: false, destructive: false),
            ToolSpec("stop_share",
                     title: "Paylaşımı Durdur",
                     description: "Alan adının Cloudflare tünelini kapatır; herkese açık adres anında ölür.",
                     schema: schema(shareProperties, required: ["name"]),
                     scope: .sharing, needsWrite: true, readOnly: false, destructive: true)
        ]
    }

    /// MCP protokolüne verilecek araç listesi — izin verilmeyenler SÜZÜLÜR.
    ///
    /// Ayarlar HER çağrıda taze okunur: kullanıcı Ayarlar'dan izin değiştirdiğinde
    /// sunucuyu yeniden başlatması gerekmesin.
    private static func permittedToolDefinitions() -> [[String: Any]] {
        let settings = AppSettings.load()
        return toolSpecs()
            .filter { $0.isPermitted(in: settings) }
            .map(\.json)
    }

    /// TÜM araçlar (izin süzmesi YOK) — tarayıcıdaki kurulum sayfası uygulamanın tam
    /// yeteneğini göstermelidir; süzme yalnızca MCP protokolüne uygulanır.
    static func allToolDefinitions() -> [[String: Any]] {
        toolSpecs().map(\.json)
    }

    /// Kurulum sayfası ve Ayarlar için: tüm araçların adları.
    static func allToolNames() -> [String] { toolSpecs().map(\.name) }

    /// Şu anki izinlerle gerçekten çağrılabilen araçların adları (Ayarlar'daki sayaç için).
    static func permittedToolNames() -> [String] {
        let settings = AppSettings.load()
        return toolSpecs().filter { $0.isPermitted(in: settings) }.map(\.name)
    }

    // MARK: - Araç Yürütme

    /// Yazma yapan araçları SIRAYA sokan karşılıklı dışlama kilidi (FIFO).
    ///
    /// Araç gövdeleri `await` sırasında MainActor'ı bırakır; iki paralel `tools/call`
    /// birbirinin "kontrol et → yaz" adımlarının ARASINA girebilir. İki eşzamanlı
    /// `create_domain` böylece aynı boş portu bulup ikisine de atayabiliyordu (aynı
    /// yarış: alan adı çakışma denetimi, servis durumu, vhost yazımı).
    ///
    /// Okuma araçları bu kilide GİRMEZ — paralel çalışmaları sorun değildir.
    private actor WriteGate {
        private var busy = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func lock() async {
            guard busy else { busy = true; return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func unlock() {
            // Kilit doğrudan sıradakine DEVREDİLİR: `busy` false'a çekilseydi araya
            // yeni gelen bir çağrı sıradakinin önüne geçebilirdi.
            guard !waiting.isEmpty else { busy = false; return }
            waiting.removeFirst().resume()
        }
    }

    private static let writeGate = WriteGate()

    private func callTool(name: String, arguments: [String: Any]) async -> ToolOutcome {
        guard let spec = Self.toolSpecs().first(where: { $0.name == name }) else {
            return .invalidParams("Bilinmeyen araç: \(name)")
        }
        // Liste süzme TEK savunma DEĞİLDİR: istemci `tools/list`te görmediği bir aracı
        // yine de çağırabilir (adı sabit yazılmış olabilir, izin sonradan kısılmış
        // olabilir). Bu yüzden her çağrı burada tekrar denetlenir.
        if let denial = Self.permissionDenial(for: spec) { return .failure(denial) }

        // db_query künyesi okuma düzeyindedir ama allow_write=true ile YAZAR → o da sıraya girer
        let writes = spec.needsWrite || (name == "db_query" && arguments["allow_write"] as? Bool == true)
        guard writes else { return await dispatchTool(name: name, arguments: arguments) }

        await Self.writeGate.lock()
        let outcome = await dispatchTool(name: name, arguments: arguments)
        await Self.writeGate.unlock()
        return outcome
    }

    /// Araç gövdesini çalıştırır. Kilit/izin denetimi ÇAĞIRANIN işidir (bkz. callTool).
    private func dispatchTool(name: String, arguments: [String: Any]) async -> ToolOutcome {
        switch name {
        case "list_domains":       return toolListDomains()
        case "create_domain":      return await toolCreateDomain(arguments)
        case "update_domain":      return await toolUpdateDomain(arguments)
        case "set_domain_enabled": return await toolSetDomainEnabled(arguments)
        case "health_check":       return await toolHealthCheck(arguments)
        case "start_app":          return await toolControlApp(arguments, start: true)
        case "stop_app":           return await toolControlApp(arguments, start: false)
        case "app_status":         return await toolAppStatus(arguments)
        case "service_status":     return toolServiceStatus()
        case "start_service":      return toolControlService(arguments, action: .start)
        case "stop_service":       return toolControlService(arguments, action: .stop)
        case "restart_service":    return toolControlService(arguments, action: .restart)
        case "install_service":    return await toolInstallService(arguments)
        case "read_log":           return toolReadLog(arguments)
        case "read_domain_log":    return await toolReadDomainLog(arguments)
        case "list_shares":        return await toolListShares()
        case "start_share":        return await toolStartShare(arguments)
        case "stop_share":         return await toolStopShare(arguments)
        case "db_list":            return await toolDBList(arguments)
        case "db_create":          return await toolDBCreate(arguments)
        case "db_export":          return await toolDBExport(arguments)
        case "db_import":          return await toolDBImport(arguments)
        case "db_query":           return await toolDBQuery(arguments)
        default:                   return .invalidParams("Bilinmeyen araç: \(name)")
        }
    }

    // MARK: - İzin Denetimi

    /// İzin yoksa kullanıcıya gösterilecek Türkçe açıklama, izin varsa `nil`.
    ///
    /// - Parameter requiresWrite: Aracın künyesindeki düzeyi geçersiz kılar —
    ///   `db_query` normalde okumayla çalışır ama `allow_write=true` verildiğinde
    ///   YAZMA izni ister.
    private static func permissionDenial(for spec: ToolSpec, requiresWrite: Bool? = nil) -> String? {
        let level = spec.scope.permission(in: AppSettings.load())
        let needsWrite = requiresWrite ?? spec.needsWrite
        if needsWrite ? level.allowsWrite : level.allowsRead { return nil }
        let verb = needsWrite ? "yazma" : "okuma"
        return "'\(spec.name)' aracı \(spec.scope.displayName) alanında \(verb) izni gerektiriyor "
             + "(şu anki düzey: \(level.displayName)) — bu işlem için izin verilmemiş. "
             + "İzni değiştirmek için: BRAMPP → Ayarlar → MCP → Erişim İzinleri"
    }

    /// `db_query` gibi çalışma anında düzey yükselten araçlar için ek denetim.
    private static func writeDenial(forToolNamed name: String) -> String? {
        guard let spec = toolSpecs().first(where: { $0.name == name }) else { return nil }
        return permissionDenial(for: spec, requiresWrite: true)
    }

    private func toolListDomains() -> ToolOutcome {
        guard let manager = domainManager else { return .failure("DomainManager hazır değil") }
        let list: [[String: Any]] = manager.domains.map { domain in
            var entry: [String: Any] = [
                "name":       domain.name,
                "platform":   domain.platform.rawValue,
                "webServer":  domain.webServer.rawValue,
                "isEnabled":  domain.isEnabled,
                "isRunning":  domain.isRunning,
                "sslEnabled": domain.sslEnabled,
                "url":        domain.url
            ]
            if let port = domain.port { entry["port"] = port } else { entry["port"] = NSNull() }
            return entry
        }
        return .text(Self.jsonText(list))
    }

    private func toolCreateDomain(_ arguments: [String: Any]) async -> ToolOutcome {
        guard let manager = domainManager else { return .failure("DomainManager hazır değil") }

        guard let rawName = arguments["name"] as? String,
              !rawName.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .invalidParams("'name' argümanı zorunludur")
        }
        // Host adları harf duyarsızdır — UI'daki createDomain ile aynı normalleştirme
        let name = rawName.trimmingCharacters(in: .whitespaces).lowercased()

        guard DomainManager.isValidDomainName(name) else {
            return .failure("'\(name)' geçerli bir alan adı değil — yalnızca harf, rakam, nokta ve tire kullanın")
        }
        guard !manager.domains.contains(where: { $0.name.lowercased() == name }) else {
            return .failure("'\(name)' adında bir alan adı zaten kayıtlı")
        }

        let platformRaw = (arguments["platform"] as? String)?.lowercased() ?? "php"
        guard let platform = Platform(rawValue: platformRaw) else {
            return .invalidParams("'platform' geçersiz: \(platformRaw) — php|nodejs|python|dotnet|static")
        }
        let serverRaw = (arguments["web_server"] as? String)?.lowercased() ?? "apache"
        guard let webServer = WebServer(rawValue: serverRaw) else {
            return .invalidParams("'web_server' geçersiz: \(serverRaw) — apache|nginx")
        }
        let ssl = arguments["ssl"] as? Bool ?? true

        // Backend platformlarda port: verilmediyse uygulamanın kendi platform aralığının
        // (PathConfig.Ports) tabanından başlayıp BOŞ port aranır — arayüzden eklenen
        // domainlerle aynı aralıkta kalınır. (Yine de çakışırsa addDomain yedek atar.)
        var resolvedPort: Int? = nil
        if [Platform.nodejs, .python, .dotnet].contains(platform) {
            if let requested = arguments["port"] as? Int {
                // Arayüzdeki AddDomainSheet ile aynı üç denetim: aralık, çakışma,
                // web sunucusu portları. Doğrulanmadan yazılan port ya uygulamayı
                // hiç bağlanamaz hale getirir ya da Apache/Nginx'in portunu çalar.
                guard (1...65_535).contains(requested) else {
                    return .failure("Geçersiz port: \(requested) — 1-65535 aralığında olmalı")
                }
                guard !manager.isPortInUse(requested) else {
                    return .failure("Port \(requested) başka bir alan adı tarafından kullanılıyor")
                }
                if let svc = serviceManager {
                    let reserved: Set<Int> = [svc.currentApacheHTTPPort(), svc.currentApacheHTTPSPort(),
                                              svc.currentNginxHTTPPort(), svc.currentNginxHTTPSPort()]
                    guard !reserved.contains(requested) else {
                        return .failure("Port \(requested) bir web sunucusu tarafından kullanılıyor")
                    }
                }
                resolvedPort = requested
            } else {
                let range: ClosedRange<Int> = platform == .nodejs ? PathConfig.Ports.nodeRange
                    : (platform == .python ? PathConfig.Ports.pythonRange : PathConfig.Ports.dotnetRange)
                var candidate = range.lowerBound
                var attempts = 0
                while manager.isPortInUse(candidate), attempts < 50 {
                    candidate += 1
                    attempts += 1
                }
                resolvedPort = candidate
            }
        }

        // Sürüm varsayılanları — PHP'de kullanıcının Ayarlar'daki tercihi geçerlidir
        var domain: Domain
        switch platform {
        case .php:
            domain = .php(name: name, version: AppSettings.load().defaultPHPVersion,
                          ssl: ssl, webServer: webServer)
        case .nodejs:
            domain = .nodejs(name: name, version: .v20,
                             port: resolvedPort ?? PathConfig.Ports.nodeRange.lowerBound,
                             ssl: ssl, webServer: webServer)
        case .python:
            domain = .python(name: name, version: .v312, framework: .fastapi,
                             port: resolvedPort ?? PathConfig.Ports.pythonRange.lowerBound,
                             ssl: ssl, webServer: webServer)
        case .dotnet:
            domain = .dotnet(name: name, version: .v8,
                             port: resolvedPort ?? PathConfig.Ports.dotnetRange.lowerBound,
                             ssl: ssl, webServer: webServer)
        case .static_:
            domain = .staticSite(name: name, ssl: ssl, webServer: webServer)
        }
        domain.redirectHTTPToHTTPS = ssl

        log(key: "log.mcp.domainCreating",
            args: [name, platform.displayName, webServer.displayName], type: .command)
        guard await manager.addDomain(domain) else {
            return .failure("'\(name)' oluşturulamadı — ayrıntılar BRAMPP konsolunda (read_log)")
        }

        // SSL üretilemediyse addDomain HTTP'ye düşmüş olabilir — KAYDEDİLEN hali raporla
        let stored = manager.domains.first { $0.name.lowercased() == name } ?? domain
        var summary = "'\(stored.name)' oluşturuldu — \(stored.platform.displayName), "
            + "\(stored.webServer.displayName), SSL: \(stored.sslEnabled ? "açık" : "kapalı")"
        if let p = stored.port { summary += ", port \(p)" }
        summary += "\nURL: \(stored.url)"
        summary += "\nNot: /etc/hosts adımı uygulamada yönetici onayı isteyebilir."
        return .text(summary)
    }

    /// Argümanlardaki `name` ile kayıtlı domaini bulur (host adları harf duyarsızdır).
    private func resolveDomain(_ arguments: [String: Any]) -> Result<Domain, ToolOutcome> {
        guard let manager = domainManager else { return .failure(.failure("DomainManager hazır değil")) }
        guard let name = arguments["name"] as? String,
              !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure(.invalidParams("'name' argümanı zorunludur"))
        }
        let needle = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard let domain = manager.domains.first(where: { $0.name.lowercased() == needle }) else {
            return .failure(.failure("'\(name)' adında bir alan adı bulunamadı (list_domains ile listeleyin)"))
        }
        return .success(domain)
    }

    private func toolUpdateDomain(_ arguments: [String: Any]) async -> ToolOutcome {
        guard let manager = domainManager else { return .failure("DomainManager hazır değil") }
        let existing: Domain
        switch resolveDomain(arguments) {
        case .failure(let outcome): return outcome
        case .success(let d):       existing = d
        }

        var domain = existing
        var changes: [String] = []

        if let raw = arguments["php_version"] as? String {
            guard existing.platform == .php else {
                return .failure("'php_version' yalnızca PHP alan adlarında geçerli — "
                                + "'\(existing.name)' platformu: \(existing.platform.displayName)")
            }
            guard let version = PHPVersion(rawValue: raw) else {
                return .invalidParams("'php_version' geçersiz: \(raw) — "
                                      + PHPVersion.allCases.map(\.rawValue).joined(separator: "|"))
            }
            domain.phpVersion = version
            changes.append("PHP \(version.rawValue)")
        }

        if let requested = arguments["port"] as? Int {
            guard Self.appPlatforms.contains(existing.platform) else {
                return .failure("'port' yalnızca Node.js/Python/.NET alan adlarında geçerli — "
                                + "'\(existing.name)' platformu: \(existing.platform.displayName)")
            }
            // create_domain'deki ÜÇ denetimin aynısı: aralık, başka domainle çakışma,
            // web sunucusu portlarını çalma. (Kendi portu çakışma sayılmaz → excluding.)
            guard (1...65_535).contains(requested) else {
                return .failure("Geçersiz port: \(requested) — 1-65535 aralığında olmalı")
            }
            guard !manager.isPortInUse(requested, excluding: existing.id) else {
                return .failure("Port \(requested) başka bir alan adı tarafından kullanılıyor")
            }
            if let svc = serviceManager {
                let reserved: Set<Int> = [svc.currentApacheHTTPPort(), svc.currentApacheHTTPSPort(),
                                          svc.currentNginxHTTPPort(), svc.currentNginxHTTPSPort()]
                guard !reserved.contains(requested) else {
                    return .failure("Port \(requested) bir web sunucusu tarafından kullanılıyor")
                }
            }
            domain.port = requested
            changes.append("port \(requested)")
        }

        if let ssl = arguments["ssl"] as? Bool {
            domain.sslEnabled = ssl
            // SSL kapatıldıysa HTTPS yönlendirmesi anlamsız (ve zararlı: site erişilemez
            // hale gelirdi) — arayüzdeki Düzenle sayfasıyla aynı kural.
            if !ssl { domain.redirectHTTPToHTTPS = false }
            changes.append("SSL \(ssl ? "açık" : "kapalı")")
        }

        if let raw = arguments["web_server"] as? String {
            guard let webServer = WebServer(rawValue: raw.lowercased()) else {
                return .invalidParams("'web_server' geçersiz: \(raw) — apache|nginx")
            }
            domain.webServer = webServer
            if webServer != existing.webServer { changes.append(webServer.displayName) }
        }

        if let raw = arguments["document_root"] as? String {
            let path = raw.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else {
                return .invalidParams("'document_root' boş olamaz — site klasörünün mutlak yolunu verin")
            }
            // updateDomain aynı denetimi tekrar yapar ama orada başarısızlık yalnızca
            // konsola loglanır; burada reddedip çağırana AÇIK hata döndürüyoruz.
            guard DomainManager.isValidDocumentRoot(path) else {
                return .failure("Geçersiz site klasörü: '\(path)' — '/' ile başlamalı; "
                                + "tırnak, $, \\, ;, { } ve satır sonu içeremez")
            }
            domain.customDocumentRoot = path
            changes.append("klasör \(path)")
        }

        if let raw = arguments["service_dependencies"] {
            guard let ids = raw as? [String] else {
                return .invalidParams("'service_dependencies' bir dizi olmalı, ör. [\"mariadb\",\"redis\"]")
            }
            let cleaned = ids.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if let svc = serviceManager {
                let known = Set(svc.services.map(\.id))
                let unknown = cleaned.filter { !known.contains($0) }
                guard unknown.isEmpty else {
                    return .failure("Bilinmeyen servis id'si: \(unknown.joined(separator: ", ")) "
                                    + "(service_status ile listeleyin)")
                }
            }
            domain.serviceDependencies = cleaned.isEmpty ? nil : cleaned
            changes.append("bağımlılıklar: \(cleaned.isEmpty ? "yok" : cleaned.joined(separator: ", "))")
        }

        guard !changes.isEmpty else {
            return .invalidParams("Değiştirilecek alan verilmedi — php_version, port, ssl, "
                                  + "web_server, document_root veya service_dependencies")
        }

        // Web sunucusu DEĞİŞTİYSE eski sunucunun config dosyası geride kalır ve alan adını
        // servis etmeye devam ederdi (iki sunucu aynı adı sunar). updateDomain yalnızca YENİ
        // sunucunun config'ini yazdığından eskisi burada, YAZIMDAN ÖNCE kaldırılır —
        // setDomainEnabled(false) ile aynı davranış. Silmenin YAZIMDAN SONRAYA alınamamasının
        // nedeni: Apache→Nginx yönünde Nginx'in "companion" vhost'u tam da bu yola yazılır;
        // sonradan silmek taze companion'ı yok ederdi.
        var serverSwitchNote = ""
        if domain.webServer != existing.webServer {
            // Silme, updateDomain'in geri-alma korumasının DIŞINDA kalır: doğrulama
            // başarısız olup model ESKİ sunucuya döndürüldüğünde bu dosya geri yazılmaz
            // ve site 404 olurdu. İçeriği bellekte tutup geri dönüşü izliyoruz.
            let oldVHostPath = existing.vhostConfigPath
            let oldVHostContent = FileHelper.readString(oldVHostPath)
            FileHelper.remove(oldVHostPath)
            if let oldVHostContent {
                watchForServerSwitchRollback(domainID: existing.id,
                                             previousServer: existing.webServer,
                                             vhostPath: oldVHostPath,
                                             vhostContent: oldVHostContent)
            }
            serverSwitchNote = "\nNot: eski \(existing.webServer.displayName) yapılandırması kaldırıldı — "
                + "değişikliğin tamamlanması için restart_service ile "
                + "'\(existing.webServer.brewServiceID)' servisini yeniden başlatın."
        }

        log(key: "log.mcp.domainUpdating",
            args: [existing.name, changes.joined(separator: ", ")], type: .command)
        manager.updateDomain(domain)

        // updateDomain vhost doğrulamasını ARKA PLANDA yapar ve gerekirse geri alır;
        // bu yüzden "kaydedildi" denir, "uygulandı" değil.
        return .text("'\(existing.name)' güncellendi — \(changes.joined(separator: ", "))"
                     + "\nYapılandırma doğrulaması arka planda tamamlanır; sonucu read_log ile görebilirsiniz."
                     + serverSwitchNote)
    }

    /// Web sunucusu değişiminde silinen ESKİ vhost'un geri-alma sigortası.
    ///
    /// `DomainManager.updateDomain` doğrulamayı ARKA PLANDA yapar; başarısız olursa modeli
    /// `previous`a (yani eski web sunucusuna) döndürür — ama bizim sildiğimiz eski vhost
    /// dosyasından haberi YOKTUR. Model eski sunucuya dönerse dosyayı biz geri yazarız,
    /// aksi halde geri alınmış bir güncellemeden sonra site config'siz (404) kalırdı.
    ///
    /// Dosya bu arada YENİDEN OLUŞMUŞSA dokunulmaz: kullanıcı elle geri almış ya da
    /// Nginx domaini için Apache "companion" vhost'u aynı yola yazılmış olabilir —
    /// bayat içerik taze config'i ezmemelidir.
    private func watchForServerSwitchRollback(domainID: UUID,
                                              previousServer: WebServer,
                                              vhostPath: String,
                                              vhostContent: String) {
        Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(Self.rollbackWatchSeconds)
            while Date() < deadline {
                try? await Task.sleep(for: .milliseconds(500))
                guard let manager = self?.domainManager,
                      let current = manager.domains.first(where: { $0.id == domainID })
                else { return }   // domain silinmiş veya uygulama kapanıyor
                guard current.webServer == previousServer else { continue }
                // Model eski sunucuya döndü → güncelleme geri alınmış
                if !FileHelper.exists(vhostPath) { _ = FileHelper.write(vhostContent, to: vhostPath) }
                return
            }
        }
    }

    private func toolHealthCheck(_ arguments: [String: Any]) async -> ToolOutcome {
        let domain: Domain
        switch resolveDomain(arguments) {
        case .failure(let outcome): return outcome
        case .success(let d):       domain = d
        }

        // DomainManager.healthCheck() sonucu arayüzde MODAL uyarı olarak gösterir ve geriye
        // değer DÖNDÜRMEZ. MCP istemcisine metin döndürebilmek — ve kullanıcının önüne
        // kapatması gereken bir pencere atmamak — için aynı istek burada tekrarlanır.
        let url = domain.url
        // -k: yerel mkcert sertifikası; -m 6: 6sn zaman aşımı; -L: yönlendirmeleri izle
        let result = await Shell.bashAsync(
            "curl -skL -o /dev/null -m 6 -w '%{http_code}' \(Shell.quote(url)) 2>/dev/null")
        let code = result.output.trimmingCharacters(in: .whitespacesAndNewlines)

        if let status = Int(code), (200..<400).contains(status) {
            return .text("✅ \(domain.name) yanıt veriyor — HTTP \(status)\n\(url)")
        }
        if code == "000" || code.isEmpty {
            return .failure("❌ \(domain.name) erişilemiyor — \(url)\n"
                            + "Kontrol edin: \(domain.webServer.displayName) çalışıyor mu "
                            + "(service_status), /etc/hosts kaydı var mı, SSL sertifikası mevcut mu?")
        }
        if ["502", "503", "504"].contains(code) {
            return .failure("⚠️ \(domain.name) HTTP \(code) — web sunucusu ayakta ama arkadaki "
                            + "uygulama yanıt vermiyor. start_app ile başlatmayı deneyin.")
        }
        return .failure("⚠️ \(domain.name) beklenmeyen durum kodu döndürdü: HTTP \(code)\n\(url)")
    }

    private func toolControlApp(_ arguments: [String: Any], start: Bool) async -> ToolOutcome {
        guard let manager = domainManager else { return .failure("DomainManager hazır değil") }
        let domain: Domain
        switch resolveDomain(arguments) {
        case .failure(let outcome): return outcome
        case .success(let d):       domain = d
        }
        guard Self.appPlatforms.contains(domain.platform) else {
            return .failure("'\(domain.name)' \(domain.platform.displayName) platformunda — "
                            + "başlatılıp durdurulacak bir uygulama süreci yok. "
                            + "PHP ve static siteler doğrudan web sunucusu tarafından servis edilir "
                            + "(start_service ile httpd/nginx).")
        }

        // İki AYRI anahtar: eylem sözcüğü cümlenin içinde çekimlendiğinden argüman
        // olarak geçirilemez (TR "başlatılıyor" ↔ EN "starting the … app").
        log(key: start ? "log.mcp.appStarting" : "log.mcp.appStopping",
            args: [domain.name], type: .command)
        switch (start, domain.platform) {
        case (true,  .python): await manager.startPythonApp(domain: domain)
        case (true,  _):       await manager.startNativeApp(domain: domain)
        case (false, .python): await manager.stopPythonApp(domain: domain)
        case (false, _):       await manager.stopNativeApp(domain: domain)
        }

        // Manager başarısızlıkta yalnızca loglar/uyarı gösterir — GERÇEK durumu doğrula
        let running = await NativeProcessManager.isRunning(domain: domain)
        if running == start {
            return .text("'\(domain.name)' \(start ? "başlatıldı" : "durduruldu")"
                         + (start ? " — \(domain.url)" : ""))
        }
        return .failure("'\(domain.name)' \(start ? "başlatılamadı" : "durdurulamadı") — "
                        + "ayrıntılar için read_domain_log (kind: app) veya read_log")
    }

    private func toolAppStatus(_ arguments: [String: Any]) async -> ToolOutcome {
        let domain: Domain
        switch resolveDomain(arguments) {
        case .failure(let outcome): return outcome
        case .success(let d):       domain = d
        }
        guard Self.appPlatforms.contains(domain.platform) else {
            return .failure("'\(domain.name)' \(domain.platform.displayName) platformunda — "
                            + "izlenecek bir uygulama süreci yok (yalnızca Node.js, Python ve .NET).")
        }

        let running = await NativeProcessManager.isRunning(domain: domain)
        let info    = await NativeProcessManager.processInfo(for: domain)
        var entry: [String: Any] = [
            "name":      domain.name,
            "platform":  domain.platform.rawValue,
            "isRunning": running,
            "url":       domain.url
        ]
        entry["port"]       = domain.port      ?? NSNull()
        entry["wrapperPID"] = info.wrapperPID  ?? NSNull()
        entry["appPID"]     = info.appPID      ?? NSNull()
        entry["command"]    = info.command     ?? NSNull()
        entry["cpuPercent"] = info.cpu         ?? NSNull()
        entry["memoryMB"]   = info.memoryMB    ?? NSNull()
        return .text(Self.jsonText(entry))
    }

    private func toolSetDomainEnabled(_ arguments: [String: Any]) async -> ToolOutcome {
        guard let manager = domainManager else { return .failure("DomainManager hazır değil") }
        guard let name = arguments["name"] as? String, !name.isEmpty else {
            return .invalidParams("'name' argümanı zorunludur")
        }
        guard let enabled = arguments["enabled"] as? Bool else {
            return .invalidParams("'enabled' argümanı zorunludur (true/false)")
        }
        guard let domain = manager.domains.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            return .failure("'\(name)' adında bir alan adı bulunamadı")
        }
        guard domain.isEnabled != enabled else {
            return .text("'\(domain.name)' zaten \(enabled ? "etkin" : "devre dışı")")
        }

        await manager.setDomainEnabled(domain, enabled: enabled)

        // setDomainEnabled vhost yazılamazsa değişikliği UYGULAMAZ — gerçek durumu doğrula
        let current = manager.domains.first { $0.id == domain.id }?.isEnabled ?? domain.isEnabled
        guard current == enabled else {
            return .failure("'\(domain.name)' \(enabled ? "etkinleştirilemedi" : "devre dışı bırakılamadı") — ayrıntılar BRAMPP konsolunda (read_log)")
        }
        return .text("'\(domain.name)' \(enabled ? "etkinleştirildi" : "devre dışı bırakıldı")")
    }

    private func toolServiceStatus() -> ToolOutcome {
        guard let manager = serviceManager else { return .failure("ServiceManager hazır değil") }
        let list: [[String: Any]] = manager.services.map { service in
            var entry: [String: Any] = [
                "id":     service.id,
                "name":   service.name,
                "status": service.status.rawValue
            ]
            if let port = service.port { entry["port"] = port } else { entry["port"] = NSNull() }
            if let version = service.version { entry["version"] = version } else { entry["version"] = NSNull() }
            return entry
        }
        return .text(Self.jsonText(list))
    }

    /// Servis üzerinde uygulanacak işlem — üç aracın ortak gövdesi için.
    private enum ServiceAction: String {
        case start, stop, restart

        var verb: String {
            switch self {
            case .start:   return "başlatma"
            case .stop:    return "durdurma"
            case .restart: return "yeniden başlatma"
            }
        }
    }

    private func toolControlService(_ arguments: [String: Any], action: ServiceAction) -> ToolOutcome {
        guard let manager = serviceManager else { return .failure("ServiceManager hazır değil") }
        guard let id = arguments["id"] as? String, !id.isEmpty else {
            return .invalidParams("'id' argümanı zorunludur")
        }
        guard let service = manager.services.first(where: { $0.id == id }) else {
            return .failure("'\(id)' adında bir servis bulunamadı (service_status ile listeleyin)")
        }
        guard service.canToggle else {
            return .failure("'\(service.name)' başlatılıp durdurulamaz — yalnızca kurulu bir runtime")
        }

        switch action {
        case .start:   manager.startService(service)
        case .stop:    manager.stopService(service)
        case .restart: manager.restartService(service)
        }
        return .text("'\(service.name)' için \(action.verb) komutu verildi — "
                     + "durum birkaç saniye içinde güncellenir (service_status ile doğrulayın).")
    }

    /// Bir konsol satırının süzgeçlerden geçip geçmediği.
    ///
    /// Saf fonksiyon: `read_log` süzgeçleri kabuk çağırmadan test edilebilsin diye
    /// ayrı tutuldu. `warning` düzeyi uyarı VE hataları kapsar — kullanıcı "sorunları
    /// göster" derken hatayı dışarıda bırakmak istemez.
    static func logLineMatches(level: String, search: String?,
                               entryLabel: String, text: String) -> Bool {
        switch level {
        case "error":   if entryLabel != "ERROR" { return false }
        case "warning": if entryLabel != "WARN" && entryLabel != "ERROR" { return false }
        default:        break
        }
        if let search, !search.isEmpty,
           text.range(of: search, options: .caseInsensitive) == nil { return false }
        return true
    }

    /// Diskteki `YYYY-MM-DD HH:mm:ss [DÜZEY] metin` satırını parçalar.
    static func parseFileLogLine(_ line: String) -> (date: String, label: String, text: String)? {
        // 19 karakter tarih + boşluk + "[ETİKET]" + boşluk
        guard line.count > 22,
              let open = line.firstIndex(of: "["),
              let close = line[open...].firstIndex(of: "]") else { return nil }
        let stamp = String(line[line.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        guard stamp.count == 19 else { return nil }
        let label = String(line[line.index(after: open)..<close])
        let rest = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        return (stamp, label, rest)
    }

    private func toolReadLog(_ arguments: [String: Any]) -> ToolOutcome {
        let requested = arguments["lines"] as? Int ?? 50
        let count  = max(1, min(500, requested))
        let level  = (arguments["level"] as? String)?.lowercased() ?? "all"
        let search = arguments["search"] as? String
        let since  = (arguments["since_minutes"] as? Int).map { max(1, $0) }
        let source = (arguments["source"] as? String)?.lowercased() ?? "memory"

        guard ["all", "error", "warning"].contains(level) else {
            return .invalidParams("'level' geçersiz: \(level) — all|error|warning")
        }
        guard ["memory", "file"].contains(source) else {
            return .invalidParams("'source' geçersiz: \(source) — memory|file")
        }

        if source == "file" {
            // Diskteki geçmiş: bellekteki 300 satırlık tampon uzun işlemlerde
            // süpürüldüğü için "biraz önce ne oldu" ancak buradan yanıtlanır.
            // `since` verilmediyse pencere DARALTILMAZ: diskte tutulan tüm geçmiş
            // taranır. `?? 2` yüzünden "dört gün önce ne oldu" sorusu sessizce boş
            // dönüyordu — üstelik pencereyi GENİŞLETMENİN tek yolu, şemada DARALTICI
            // diye belgelenen `since_minutes`i vermekti.
            let days = since.map { max(1, Int(ceil(Double($0) / 1440.0)) + 1) }
                ?? ConsoleLogFile.retentionDays
            let raw = ConsoleLogFile.recentText(days: min(days, ConsoleLogFile.retentionDays))
            guard !raw.isEmpty else {
                return .text("Disk logu boş — Ayarlar'da 'Konsolu diske kaydet' kapalı olabilir.")
            }
            let cutoff = since.map { Date().addingTimeInterval(-Double($0) * 60) }
            let stampFmt = DateFormatter()
            stampFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
            stampFmt.locale = Locale(identifier: "en_US_POSIX")

            var kept: [String] = []
            for line in raw.components(separatedBy: .newlines) where !line.isEmpty {
                guard let p = Self.parseFileLogLine(line) else { continue }
                if let cutoff, let d = stampFmt.date(from: p.date), d < cutoff { continue }
                guard Self.logLineMatches(level: level, search: search,
                                          entryLabel: p.label, text: p.text) else { continue }
                kept.append(line)
            }
            guard !kept.isEmpty else { return .text("Süzgeçlere uyan satır yok") }
            return .text(kept.suffix(count).joined(separator: "\n"))
        }

        guard let store = consoleStore else { return .failure("Konsol hazır değil") }
        let cutoff = since.map { Date().addingTimeInterval(-Double($0) * 60) }
        // Gösterim DAİMA `text` üzerinden: `message` ham/İngilizce yedektir ve
        // doğrudan kullanılırsa log satırları uygulamanın diline uymaz (dili dondurur).
        let matched = store.entries.filter { entry in
            if let cutoff, entry.timestamp < cutoff { return false }
            return Self.logLineMatches(level: level, search: search,
                                       entryLabel: entry.type.logLabel, text: entry.text)
        }
        guard !matched.isEmpty else {
            return .text(store.entries.isEmpty ? "Konsol boş" : "Süzgeçlere uyan satır yok")
        }
        return .text(matched.suffix(count)
            .map { "\($0.formattedTime) \($0.type.icon) \($0.text)" }
            .joined(separator: "\n"))
    }

    private func toolInstallService(_ arguments: [String: Any]) async -> ToolOutcome {
        guard let manager = serviceManager else { return .failure("ServiceManager hazır değil") }
        guard let name = (arguments["name"] as? String)?
            .trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return .invalidParams("'name' zorunlu")
        }
        // Yalnızca KATALOGDAKİ servisler: rastgele formül adı kabul etmek, ajanın
        // makineye istediği paketi kurabilmesi demek olurdu.
        guard let svc = manager.services.first(where: { $0.id == name }) else {
            let ids = manager.services.map(\.id).sorted().joined(separator: ", ")
            return .invalidParams("'\(name)' katalogda yok. Kurulabilir servisler: \(ids)")
        }
        guard svc.status == .notInstalled else {
            return .text("'\(svc.name)' zaten kurulu.")
        }
        manager.installService(svc)
        return .text("'\(svc.name)' kurulumu başlatıldı — brew install \(svc.brewName ?? svc.id).\n\n"
                     + "Dakikalar sürebilir ve ilerleme BRAMPP penceresinde görünür. "
                     + "Bitip bitmediğini service_status ile kontrol edin.")
    }

    // MARK: - Paylaşım Araçları

    private func toolListShares() async -> ToolOutcome {
        guard let manager = tunnelManager else { return .failure("TunnelManager hazır değil") }
        // Bellekteki tablo, süreç dışarıdan öldüğünde kendiliğinden güncellenmez.
        // Sormadan önce gerçekle eşitle: bu araç ölü bir adresi ASLA açık paylaşım
        // diye bildirmemeli — karşı taraf Cloudflare'in 1033 hatasını görür.
        await manager.reconcile()
        // Ölü/başarısız kayıtlar listelenmez; adresi henüz gelmemiş olanlar öyle etiketlenir.
        let live = manager.tunnels.values
            .filter { $0.isLive || $0.state == .starting }
            .sorted { $0.domainName < $1.domainName }
        guard !live.isEmpty else { return .text("Açık paylaşım yok") }
        return .text(live.map { t in
            let url = t.publicURL ?? "(adres bekleniyor)"
            return "\(t.domainName) → \(url)  [yerel: \(t.origin)]"
        }.joined(separator: "\n"))
    }

    private func toolStartShare(_ arguments: [String: Any]) async -> ToolOutcome {
        guard let manager = tunnelManager else { return .failure("TunnelManager hazır değil") }

        // Alan adı yerine düz bir yerel port paylaşımı — BRAMPP'ta kayıtlı olmayan
        // bir geliştirme sunucusu (npm run dev gibi) için.
        if let port = arguments["port"] as? Int {
            guard await manager.startPort(port) else {
                switch manager.lastPortRefusal {
                case .outOfRange:
                    return .invalidParams("'\(port)' geçerli bir port değil (1–65535).")
                case .reservedService(let name):
                    return .failure("Port \(port) paylaşılamaz — \(name) servisi. Veritabanı ve "
                                    + "önbellek servisleri internete açılmaz; Quick Tunnel zaten "
                                    + "yalnızca HTTP taşır.")
                case .notListening:
                    return .failure("Port \(port) dinlenmiyor — paylaşılan adres boş dönerdi. "
                                    + "Önce sunucuyu başlatın.")
                case nil:
                    return .failure("Port \(port) için tünel açılamadı — ayrıntı için read_log.")
                }
            }
            let key = TunnelManager.portKey(port)
            guard let url = manager.tunnel(for: key)?.publicURL else {
                return .failure("Tünel açıldı ama adres alınamadı.")
            }
            return .text("127.0.0.1:\(port) ARTIK HERKESE AÇIK: \(url)\n\n"
                         + "Bu adresi bilen herkes erişebilir. Kapatmak için: "
                         + "stop_share name=\"\(key)\"")
        }

        let domain: Domain
        switch resolveDomain(arguments) {
        case .failure(let outcome): return outcome
        case .success(let d):       domain = d
        }
        guard TunnelManager.isCloudflaredInstalled else {
            return .failure("cloudflared kurulu değil. Kurulum: brew install cloudflared")
        }
        // Önkoşul denetimi TEK yerde: TunnelManager.start(). Burada ikinci bir kopya
        // tutmak, MCP yolundan gelen reddin konsola iz bırakmamasına yol açıyordu —
        // oysa paylaşım güvenlikle ilgili ve her denemesi görünür olmalı.
        guard await manager.start(domain: domain) else {
            switch manager.lastBlock {
            case .domainDisabled:
                return .failure("'\(domain.name)' devre dışı — vhost'u yok, paylaşılamaz. "
                                + "Önce set_domain_enabled ile etkinleştirin.")
            case .webServerDown(let name):
                return .failure("'\(domain.name)' paylaşılamaz: \(name) çalışmıyor, siteyi "
                                + "sunacak bir sunucu yok. start_service ile başlatın.")
            case .appDown:
                return .failure("'\(domain.name)' paylaşılamaz: arka plan uygulaması çalışmıyor, "
                                + "ziyaretçi 502 görürdü. start_app ile başlatıp tekrar deneyin.")
            case nil:
                return .failure("'\(domain.name)' için tünel açılamadı — ayrıntı için read_log.")
            }
        }
        guard let url = manager.tunnel(for: domain.name)?.publicURL else {
            return .failure("Tünel açıldı ama adres alınamadı.")
        }
        return .text("'\(domain.name)' ARTIK HERKESE AÇIK: \(url)\n\n"
                     + "Bu adresi bilen herkes siteye erişebilir. İşiniz bitince "
                     + "stop_share ile kapatın; uygulama kapanırken de otomatik kapanır.")
    }

    private func toolStopShare(_ arguments: [String: Any]) async -> ToolOutcome {
        guard let manager = tunnelManager else { return .failure("TunnelManager hazır değil") }
        guard let raw = (arguments["name"] as? String)?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return .invalidParams("'name' zorunlu")
        }
        // `start_share` ve `resolveDomain` adı küçüğe indiriyor, kayıt anahtarı da
        // öyle saklanıyor. Burada indirilmediği için "Foo.test" ile açılan bir
        // paylaşım "foo.test" ile kapatılamıyordu. Port anahtarı (":3000") harf
        // içermediğinden küçültmeden etkilenmez.
        let name = raw.lowercased()
        guard manager.tunnel(for: name) != nil else {
            return .failure("'\(raw)' için açık paylaşım yok")
        }
        // DÖNÜŞ DEĞERİ YUTULMAMALI. `false`, sürecin SIGTERM ve SIGKILL'i atlattığı
        // ve adresin HÂLÂ yayında olduğu anlamına gelir; kayıt da bilerek silinmez.
        // Koşulsuz "adres artık ölü" demek, ajanı üzerinden kullanıcıya kesin ve
        // yanlış bir güvence verir — site internete açık kalmaya devam eder.
        guard await manager.stop(domainName: name) else {
            return .failure("'\(name)' paylaşımı DURDURULAMADI — cloudflared süreci "
                          + "sinyalleri atlattı ve adres HÂLÂ yayında. Konsoldaki "
                          + "satır PID'i veriyor; süreci elle kapatmak gerekiyor.")
        }
        return .text("'\(name)' paylaşımı durduruldu — herkese açık adres artık ölü.")
    }

    private func toolReadDomainLog(_ arguments: [String: Any]) async -> ToolOutcome {
        guard let manager = domainManager else { return .failure("DomainManager hazır değil") }
        let domain: Domain
        switch resolveDomain(arguments) {
        case .failure(let outcome): return outcome
        case .success(let d):       domain = d
        }

        let requested = arguments["lines"] as? Int ?? 100
        let count = max(1, min(1000, requested))
        let kind  = (arguments["kind"] as? String)?.lowercased() ?? "error"

        let text: String
        switch kind {
        case "error":
            text = manager.readErrorLog(for: domain)
        case "access":
            text = manager.readAccessLog(for: domain)
        case "app":
            guard Self.appPlatforms.contains(domain.platform) else {
                return .failure("'app' logu yalnızca Node.js/Python/.NET alan adlarında bulunur — "
                                + "'\(domain.name)' platformu: \(domain.platform.displayName). "
                                + "kind: error veya access kullanın.")
            }
            text = await NativeProcessManager.readLogs(for: domain, lines: count)
        default:
            return .invalidParams("'kind' geçersiz: \(kind) — error|access|app")
        }

        let tail = Self.tail(text, lines: count)
        return .text(tail.isEmpty ? "Log boş" : tail)
    }

    // MARK: - Veritabanı Araçları

    /// Araç argümanındaki `engine` değerini çözer.
    private enum DBEngine: String {
        case mysql, postgres

        var displayName: String { self == .mysql ? "MariaDB/MySQL" : "PostgreSQL" }
    }

    private func resolveEngine(_ arguments: [String: Any]) -> Result<DBEngine, ToolOutcome> {
        let raw = (arguments["engine"] as? String)?.lowercased() ?? DBEngine.mysql.rawValue
        guard let engine = DBEngine(rawValue: raw) else {
            return .failure(.invalidParams("'engine' geçersiz: \(raw) — mysql|postgres"))
        }
        return .success(engine)
    }

    /// Çalışan PostgreSQL'in portu. Birden fazla sürüm kurulu olabilir — ÇALIŞAN ilki seçilir
    /// (arayüzdeki Veritabanı sekmesi de kullanıcının seçtiği sürümün portunu kullanır).
    private func runningPostgresPort() -> Result<Int, ToolOutcome> {
        guard let manager = serviceManager else {
            return .failure(.failure("ServiceManager hazır değil"))
        }
        guard let service = manager.services.first(where: {
            $0.id.hasPrefix("postgresql@") && $0.status == .running
        }) else {
            return .failure(.failure("Çalışan bir PostgreSQL bulunamadı — "
                                     + "service_status ile sürümü görüp start_service ile başlatın."))
        }
        return .success(service.port ?? 5432)
    }

    /// `psql`/`createdb` çağrısı: önce `postgres` superuser'ı, olmazsa oturum kullanıcısı
    /// (ilk yapılandırma yapılmamış kurulumlarda postgres rolü henüz yoktur).
    /// `{U}` yer tutucusu kullanıcı bayrağıyla değiştirilir.
    ///
    /// İlk denemenin hata çıktısı YUTULUR: `2>&1 || ...` kalıbında ikinci deneme başarılı
    /// olsa bile ilkinin hata metni sonucun başına karışır ve sorgu çıktısını kirletirdi.
    private static func psqlFallback(_ command: String) -> String {
        command.replacingOccurrences(of: "{U}", with: "-U postgres") + " 2>/dev/null || "
            + command.replacingOccurrences(of: "{U}", with: "") + " 2>&1"
    }

    private func toolDBList(_ arguments: [String: Any]) async -> ToolOutcome {
        let engine: DBEngine
        switch resolveEngine(arguments) {
        case .failure(let outcome): return outcome
        case .success(let e):       engine = e
        }

        switch engine {
        case .mysql:
            // Önce root + TCP (BRAMPP'in yapılandırdığı erişim), boş dönerse unix socket yedeği
            var result = await Shell.bashAsync(
                "mysql -N -u root -h 127.0.0.1 --connect-timeout=3 -e 'SHOW DATABASES' 2>/dev/null")
            var names = Self.nonEmptyLines(result.output)
            if names.isEmpty {
                result = await Shell.bashAsync(
                    "mysql -N -u \(Shell.quote(NSUserName())) --connect-timeout=3 -e 'SHOW DATABASES' 2>/dev/null")
                names = Self.nonEmptyLines(result.output)
            }
            guard !names.isEmpty else {
                return .failure("Veritabanı listesi alınamadı — MariaDB çalışıyor mu? (start_service id=mariadb)")
            }
            return .text(names.joined(separator: "\n"))

        case .postgres:
            let port: Int
            switch runningPostgresPort() {
            case .failure(let outcome): return outcome
            case .success(let p):       port = p
            }
            let sql = "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname"
            let result = await Shell.brewBashAsync(Self.psqlFallback(
                "psql -h 127.0.0.1 -p \(port) {U} -t -A -c \(Shell.quote(sql))"))
            let names = Self.nonEmptyLines(result.output)
            guard !names.isEmpty else {
                return .failure("PostgreSQL veritabanı listesi alınamadı — \(result.error.isEmpty ? result.output : result.error)")
            }
            return .text(names.joined(separator: "\n"))
        }
    }

    private func toolDBCreate(_ arguments: [String: Any]) async -> ToolOutcome {
        let engine: DBEngine
        switch resolveEngine(arguments) {
        case .failure(let outcome): return outcome
        case .success(let e):       engine = e
        }
        guard let name = arguments["name"] as? String, !name.isEmpty else {
            return .invalidParams("'name' argümanı zorunludur")
        }
        // Ad doğrudan SQL'e/komut satırına gömüldüğünden SINIRDA daraltılır (kaçış yerine reddetme)
        guard Self.isSafeIdentifier(name) else {
            return .failure("Geçersiz veritabanı adı: '\(name)' — yalnızca harf, rakam ve alt çizgi kullanın")
        }

        switch engine {
        case .mysql:
            let sql = "CREATE DATABASE IF NOT EXISTS \\`\(name)\\`;"
            let result = await Shell.bashAsync(
                "mysql -u root -h 127.0.0.1 --connect-timeout=3 -e \"\(sql)\" 2>/dev/null || " +
                "mysql -u \(Shell.quote(NSUserName())) --connect-timeout=3 -e \"\(sql)\" 2>/dev/null")
            guard result.isSuccess else {
                return .failure("'\(name)' oluşturulamadı — MariaDB çalışıyor mu? (start_service id=mariadb)")
            }

        case .postgres:
            let port: Int
            switch runningPostgresPort() {
            case .failure(let outcome): return outcome
            case .success(let p):       port = p
            }
            // createdb'de "IF NOT EXISTS" YOKTUR — MySQL'le aynı "varsa dokunma"
            // davranışını verebilmek için önce varlığı sorgulanır.
            let exists = await Shell.brewBashAsync(Self.psqlFallback(
                "psql -h 127.0.0.1 -p \(port) {U} -t -A -c "
                + Shell.quote("SELECT 1 FROM pg_database WHERE datname='\(name)'")))
            if Self.nonEmptyLines(exists.output).contains("1") {
                return .text("'\(name)' PostgreSQL veritabanı zaten var — dokunulmadı")
            }
            // -- : ad tire ile başlasa bile seçenek olarak yorumlanmasın (uç-işaret)
            let result = await Shell.brewBashAsync(Self.psqlFallback(
                "createdb -h 127.0.0.1 -p \(port) {U} -- \(Shell.quote(name))"))
            guard result.isSuccess else {
                return .failure("'\(name)' oluşturulamadı — \(result.error.isEmpty ? result.output : result.error)")
            }
        }

        log(key: "log.mcp.dbCreated", args: [name, engine.displayName], type: .success)
        return .text("'\(name)' veritabanı oluşturuldu — \(engine.displayName) (zaten varsa dokunulmadı)")
    }

    /// Salt-okunur kabul edilen SQL başlangıçları — `allow_write=false` iken sorgu
    /// bunlardan biriyle BAŞLAMALIDIR (izin verilenler listesi; yasaklılar listesi değil,
    /// çünkü bilinmeyen/yeni bir yazma komutu listeden kaçardı).
    private static let readOnlySQLPrefixes = ["SELECT", "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "WITH"]

    /// Salt-okunur modda sorgunun GÖVDESİNDE hiçbir yerde bulunamayacak komutlar.
    ///
    /// Yalnızca önek denetimi YETMEZ: "WITH" izinli bir başlangıç olduğundan
    /// `WITH d AS (DELETE FROM users RETURNING *) SELECT count(*) FROM d` gibi
    /// veri değiştiren CTE'ler (PostgreSQL tam destekler, MySQL 8 / MariaDB 10.6+
    /// WITH ... UPDATE|DELETE destekler) önek denetiminden geçip veri silerdi.
    private static let forbiddenSQLKeywords = [
        "INSERT", "UPDATE", "DELETE", "MERGE", "REPLACE", "CREATE", "DROP", "ALTER",
        "TRUNCATE", "RENAME", "GRANT", "REVOKE", "CALL", "DO", "HANDLER", "LOAD",
        "COPY", "VACUUM", "SET", "LOCK", "ATTACH"
    ]

    /// Salt-okunur modda yasak FONKSİYON/ÖNEK desenleri — dosya sistemine ve sunucu
    /// tarafı yordamlarına ulaşanlar.
    ///
    /// Kelime listesi bunları YAKALAYAMAZ: alt çizgi bir kelime karakteridir, bu yüzden
    /// `\bLOAD\b` deseni `LOAD_FILE` ile EŞLEŞMEZ. Sonuç olarak
    /// `SELECT LOAD_FILE('/etc/passwd')` salt-okunur süzgeçten geçip "yalnızca okuma"
    /// izniyle DİSKTEN DOSYA OKUYORDU (aynısı PostgreSQL'de pg_read_file/lo_import,
    /// Oracle uyumlu istemcilerde DBMS_* için geçerli).
    ///
    /// Desenler `\b...\b` yerine gerektiğinde açık sonlanma kullanır; eşleşen METNİN
    /// KENDİSİ reddetme mesajında gösterilir (hangi ifadenin engellediği belli olsun).
    private static let forbiddenSQLPatterns = [
        "\\bLOAD_FILE\\s*\\(",
        "\\bLO_IMPORT\\b",
        "\\bLO_EXPORT\\b",
        "\\bPG_READ_(FILE|BINARY_FILE)\\b",
        "\\bPG_LS_\\w+",
        "\\bPG_STAT_FILE\\b",
        "\\bDBMS_\\w+"
    ]

    /// Sorguyu TARAMA için sadeleştirir: yorumlar ve dizge/tanımlayıcı içerikleri
    /// boşluğa çevrilir. Böylece hem `SELECT 1 -- \n; DROP TABLE x` gibi yorumla
    /// gizlenmiş kaçışlar yakalanır, hem de `SELECT 'delete'` gibi zararsız sorgular
    /// yanlışlıkla engellenmez.
    ///
    /// ÖNEMLİ: MySQL'in "çalıştırılabilir yorumu" (`/*!... */`, `/*!50701 ... */`)
    /// GERÇEKTEN çalışır — içeriği yorum sayıp atlasaydık orada gizlenmiş bir DELETE
    /// taramadan kaçardı. Bu yüzden yalnızca sınırlayıcıları silinir, gövdesi kod olarak taranır.
    static func sqlScanBody(_ sql: String) -> String {
        var out = ""
        let chars = Array(sql)
        var i = 0
        while i < chars.count {
            let c = chars[i]

            // Satır yorumu: "--" (PostgreSQL) ve "#" (MySQL)
            if (c == "-" && i + 1 < chars.count && chars[i + 1] == "-") || c == "#" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                out.append(" ")
                continue
            }

            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                // /*! ... */ → çalıştırılabilir yorum: sınırlayıcı atılır, gövde kod olarak taranır
                if i + 2 < chars.count, chars[i + 2] == "!" {
                    i += 3
                    while i < chars.count, chars[i].isNumber { i += 1 }
                    out.append(" ")
                    continue
                }
                i += 2
                while i < chars.count {
                    if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" { i += 2; break }
                    i += 1
                }
                out.append(" ")
                continue
            }

            // Dizge ('…', "…") ve tırnaklı tanımlayıcı (`…`) içeriği taramaya girmez
            if c == "'" || c == "\"" || c == "`" {
                i += 1
                while i < chars.count {
                    if chars[i] == "\\" { i += 2; continue }              // MySQL ters bölü kaçışı
                    if chars[i] == c {
                        if i + 1 < chars.count, chars[i + 1] == c { i += 2; continue }  // '' ikilemesi
                        i += 1
                        break
                    }
                    i += 1
                }
                out.append(" ")
                continue
            }

            out.append(c)
            i += 1
        }
        return out
    }

    /// Sadeleştirilmiş gövdede yasaklı bir komut varsa adını döner (yoksa `nil`).
    /// Eşleşme kelime sınırıyla ve harf-duyarsız yapılır: `updated_at` UPDATE sayılmaz.
    static func readOnlySQLViolation(_ scanBody: String) -> String? {
        // MySQL'de "SELECT … INTO OUTFILE '/tmp/x'" SELECT önekiyle geçip DOSYA YAZAR
        if scanBody.range(of: "\\bINTO\\s+(OUT|DUMP)FILE\\b",
                          options: [.regularExpression, .caseInsensitive]) != nil {
            return "INTO OUTFILE"
        }
        // "SET" kara listede çünkü tek başına oturum durumunu değiştirir (SET autocommit=0).
        // Ancak MySQL'de KARAKTER KÜMESİ sorguları da bu kelimeyi taşır ve tamamen
        // okumadır: "SHOW CHARACTER SET", "SHOW CHARACTER SET LIKE 'utf8%'",
        // "SELECT ... COLLATE ... CHARACTER SET ...". Bunları engellemek yanlış pozitif
        // olurdu; yalnızca "CHARACTER SET" bağlamındaki SET'ler taramadan düşürülür —
        // gerçek "SET x = y" ifadesi hâlâ yakalanır.
        var body = scanBody.replacingOccurrences(
            of: "\\bCHARACTER\\s+SET\\b", with: " CHARSET_KW ",
            options: [.regularExpression, .caseInsensitive])
        // Aynı nötrleştirme "SHOW CREATE TABLE|VIEW|…" için de gerekir: SAF OKUMA olduğu
        // halde "CREATE" kara listede olduğundan reddediliyor ve ajana yanlış yol
        // gösteriliyordu ("allow_write: true kullanın" — oysa yazma izni gerektirmez).
        // Yalnızca SHOW'a BİTİŞİK CREATE düşürülür; gerçek "CREATE TABLE" hâlâ yakalanır.
        body = body.replacingOccurrences(
            of: "\\bSHOW\\s+CREATE\\b", with: " SHOWCREATE_KW ",
            options: [.regularExpression, .caseInsensitive])

        // Önce fonksiyon desenleri: eşleşen metnin kendisi döner (LOAD_FILE(, PG_LS_DIR…)
        for pattern in forbiddenSQLPatterns {
            if let range = body.range(of: pattern,
                                      options: [.regularExpression, .caseInsensitive]) {
                return body[range].trimmingCharacters(in: CharacterSet(charactersIn: " \t\n(")).uppercased()
            }
        }

        for keyword in forbiddenSQLKeywords
        where body.range(of: "\\b\(keyword)\\b",
                         options: [.regularExpression, .caseInsensitive]) != nil {
            return keyword
        }
        return nil
    }

    private func toolDBQuery(_ arguments: [String: Any]) async -> ToolOutcome {
        let engine: DBEngine
        switch resolveEngine(arguments) {
        case .failure(let outcome): return outcome
        case .success(let e):       engine = e
        }
        guard let rawSQL = arguments["sql"] as? String else {
            return .invalidParams("'sql' argümanı zorunludur")
        }
        let sql = rawSQL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return .invalidParams("'sql' boş olamaz") }

        let allowWrite = arguments["allow_write"] as? Bool ?? false
        if allowWrite {
            // Yazma yalnızca listelenmiş bir izin DEĞİL, ayrıca ALAN İZNİ ister:
            // db_query'nin künyesi okuma düzeyindedir, yazma düzeyi burada aranır.
            if let denial = Self.writeDenial(forToolNamed: "db_query") { return .failure(denial) }
        } else {
            // Denetim, yorumları ve dizge içeriklerini boşluğa çevrilmiş gövde üzerinde yapılır:
            // "SELECT 1 -- \n; DROP TABLE x" gibi yorumla gizlenmiş kaçışlar böylece görünür kalır.
            let scan = Self.sqlScanBody(sql)

            // Gövdesi ";" ile ayrılmış birden fazla komut içeren sorgular reddedilir —
            // "SELECT 1; DROP TABLE x" kalıbı salt-okunur önek denetimini aşardı.
            // (Sondaki noktalı virgül tek ifadenin parçasıdır, sayılmaz.)
            let body = scan.trimmingCharacters(in: CharacterSet(charactersIn: "; \t\n\r"))
            guard !body.contains(";") else {
                return .failure("Çoklu SQL ifadesi reddedildi — tek bir sorgu gönderin "
                                + "(veya veri değiştirmek için allow_write: true kullanın)")
            }
            let head = body.uppercased()
            guard Self.readOnlySQLPrefixes.contains(where: {
                head == $0 || head.hasPrefix("\($0) ") || head.hasPrefix("\($0)\n")
                    || head.hasPrefix("\($0)\t") || head.hasPrefix("\($0)(")
            }) else {
                return .failure("Yalnızca okuma sorgularına izin verilir "
                                + "(\(Self.readOnlySQLPrefixes.joined(separator: ", "))). "
                                + "Veri değiştirmek için allow_write: true gönderin.")
            }
            // İzin verilen önekten SONRA gövdede yazma komutu aranır (WITH … DELETE kaçışı)
            if let keyword = Self.readOnlySQLViolation(body) {
                return .failure("Salt-okunur sorgu '\(keyword)' ifadesi nedeniyle reddedildi — "
                                + "sorgu veri değiştirebilir veya dosya sistemine erişebilir. "
                                + "Bunu gerçekten yapmak istiyorsanız allow_write: true gönderin "
                                + "(veritabanları alanında YAZMA izni gerekir).")
            }
        }

        let requestedRows = arguments["max_rows"] as? Int ?? 100
        let maxRows = max(1, min(1000, requestedRows))

        var database: String? = nil
        if let raw = arguments["database"] as? String,
           !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            let name = raw.trimmingCharacters(in: .whitespaces)
            guard Self.isSafeIdentifier(name) else {
                return .failure("Geçersiz veritabanı adı: '\(name)' — yalnızca harf, rakam ve alt çizgi kullanın")
            }
            database = name
        }

        // SQL komut satırına ASLA düz interpolasyonla girmez — Shell.quote tek tırnağa alır.
        let quotedSQL = Shell.quote(sql)
        let result: Shell.Result
        switch engine {
        case .mysql:
            let dbFlag = database.map { " -D \(Shell.quote($0))" } ?? ""
            // Metin denetiminin ÜSTÜNE motor düzeyinde ikinci bariyer: oturum yalnızca okuma.
            // Buradaki ";" BİZİM ürettiğimiz komutta; kullanıcının sql'inde hâlâ yasak.
            let effectiveSQL = allowWrite
                ? quotedSQL
                : Shell.quote("SET SESSION TRANSACTION READ ONLY; \(sql)")
            // İlk denemenin hatası yutulur — ikinci deneme başarılıysa çıktıya karışmasın
            result = await Shell.bashAsync(
                "mysql -N -u root -h 127.0.0.1 --connect-timeout=3\(dbFlag) -e \(effectiveSQL) 2>/dev/null || "
                + "mysql -N -u \(Shell.quote(NSUserName())) --connect-timeout=3\(dbFlag) -e \(effectiveSQL) 2>&1")
        case .postgres:
            let port: Int
            switch runningPostgresPort() {
            case .failure(let outcome): return outcome
            case .success(let p):       port = p
            }
            let dbFlag = " -d \(Shell.quote(database ?? "postgres"))"
            // Motor düzeyinde ikinci bariyer: sunucu oturumu salt-okunur açılır,
            // metin denetiminden kaçan bir yazma girişimi burada da başarısız olur.
            let env = allowWrite ? "" : "PGOPTIONS='-c default_transaction_read_only=on' "
            result = await Shell.brewBashAsync(Self.psqlFallback(
                "\(env)psql -h 127.0.0.1 -p \(port) {U}\(dbFlag) -c \(quotedSQL)"))
        }

        guard result.isSuccess else {
            let detail = result.error.isEmpty ? result.output : result.error
            return .failure("Sorgu çalıştırılamadı (\(engine.displayName)):\n"
                            + (detail.isEmpty ? "Sunucu çalışıyor mu? (service_status)" : detail))
        }

        let body = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return .text("Sorgu çalıştı — çıktı yok.") }
        let lines = body.components(separatedBy: .newlines)
        var text = lines.prefix(maxRows).joined(separator: "\n")
        if lines.count > maxRows {
            text += "\n… (\(lines.count - maxRows) satır daha var — max_rows ile artırabilirsiniz)"
        }
        if allowWrite { log(key: "log.mcp.dbQueryWrite", args: [engine.displayName], type: .warning) }
        return .text(text)
    }

    // MARK: - Yardımcılar

    /// Metnin SON `lines` satırı — log dosyaları bütünüyle okunduğunda kırpmak için.
    private static func tail(_ text: String, lines: Int) -> String {
        let all = text.components(separatedBy: .newlines)
        // Dosya sonundaki boş satır "son satır" sayılmasın (aksi halde tail boş görünürdü)
        let trimmed = all.last?.isEmpty == true ? Array(all.dropLast()) : all
        return trimmed.suffix(lines).joined(separator: "\n")
    }

    /// Komut satırına/SQL'e gömülecek tanımlayıcı için sınır denetimi — kaçış yerine reddetme.
    private static func isSafeIdentifier(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil
    }

    /// MCP'den gelen .sql dosya yolunu doğrular.
    ///
    /// Yol kabuk komutuna gömüldüğünden sınırda KAÇIŞ yerine REDDETME uygulanır —
    /// DomainManager.isValidDocumentRoot ile aynı politika ve aynı yasak küme.
    /// Tek tırnak bilerek serbesttir: `Shell.quote` onu doğru kaçırır ve
    /// `/Users/me/O'Brien/yedek.sql` gibi meşru yollar reddedilmemelidir.
    /// Saf çekirdek — kabul edilebilirse `nil`, değilse ret gerekçesi döner.
    /// (Doğrudan test edilebilsin diye ToolOutcome'dan ayrıldı.)
    static func sqlPathRejection(_ raw: String) -> String? {
        let path = (raw as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            return "'path' mutlak bir yol olmalı, ör. /Users/ad/yedekler/blog.sql"
        }
        if !path.lowercased().hasSuffix(".sql") {
            return "'path' .sql uzantılı olmalı"
        }
        let forbidden = CharacterSet(charactersIn: "\"$\\;{}\n\r\t`|&()<>")
        if path.rangeOfCharacter(from: forbidden) != nil {
            return "'path' kabuk metakarakteri içeremez"
        }
        return nil
    }

    private static func validatedSQLPath(_ raw: String) -> Result<String, ToolOutcome> {
        if let reason = sqlPathRejection(raw) { return .failure(.invalidParams(reason)) }
        return .success((raw as NSString).expandingTildeInPath)
    }

    /// Yedek dosya adı için zaman damgası — arayüzdeki Veritabanı sekmesiyle AYNI biçim.
    private static func backupStamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        return f.string(from: Date())
    }

    /// Veritabanı dökümü alır (mysqldump / pg_dump).
    private func toolDBExport(_ arguments: [String: Any]) async -> ToolOutcome {
        let engine: DBEngine
        switch resolveEngine(arguments) {
        case .failure(let outcome): return outcome
        case .success(let e):       engine = e
        }
        guard let name = arguments["name"] as? String, !name.isEmpty else {
            return .invalidParams("'name' argümanı zorunludur")
        }
        guard Self.isSafeIdentifier(name) else {
            return .failure("Geçersiz veritabanı adı: '\(name)' — yalnızca harf, rakam ve alt çizgi kullanın")
        }

        let outPath: String
        if let raw = arguments["path"] as? String, !raw.isEmpty {
            switch Self.validatedSQLPath(raw) {
            case .failure(let outcome): return outcome
            case .success(let p):       outPath = p
            }
        } else {
            guard FileHelper.createDirectory(PathConfig.backups) else {
                return .failure("Yedek dizini oluşturulamadı: \(PathConfig.backups)")
            }
            outPath = "\(PathConfig.backups)/\(name)-\(Self.backupStamp()).sql"
        }
        // Var olan dosyanın ÜZERİNE yazma — mevcut bir yedeği sessizce yok etmek,
        // yedeğin var olma amacını ortadan kaldırır.
        guard !FileHelper.exists(outPath) else {
            return .failure("Dosya zaten var, üzerine yazılmadı: \(outPath)")
        }

        let out = Shell.quote(outPath)
        let result: Shell.Result
        switch engine {
        case .mysql:
            // --single-transaction: InnoDB'de tutarlı anlık görüntü (tabloları kilitlemez)
            // --routines --triggers: saklı yordamlar ve tetikleyiciler de dökülsün
            result = await Shell.brewBashAsync(
                "mysqldump -u root --single-transaction --routines --triggers \(Shell.quote(name)) > \(out) 2>/dev/null || "
                + "mysqldump -u \(Shell.quote(NSUserName())) --single-transaction --routines --triggers \(Shell.quote(name)) > \(out)")
        case .postgres:
            let port: Int
            switch runningPostgresPort() {
            case .failure(let outcome): return outcome
            case .success(let p):       port = p
            }
            // -- : ad tire ile başlasa bile seçenek sanılmasın (uç-işaret)
            result = await Shell.brewBashAsync(Self.psqlFallback(
                "pg_dump -h 127.0.0.1 -p \(port) {U} -f \(out) -- \(Shell.quote(name))"))
        }

        guard result.isSuccess else {
            // Yarım dosya bırakma: bozuk yedek, yedek yok demekten daha kötüdür
            // (kullanıcı yedeği olduğunu sanır). Arayüzdeki dumpDatabase ile aynı davranış.
            try? FileManager.default.removeItem(atPath: outPath)
            let err = result.error.isEmpty ? result.output : result.error
            return .failure("'\(name)' dökümü alınamadı — \(err.isEmpty ? "veritabanı çalışıyor mu?" : err)")
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: outPath))?[.size] as? Int ?? 0
        return .text("'\(name)' dökümü alındı — \(bytes / 1024) KB → \(outPath)")
    }

    /// .sql dökümünü hedef veritabanına uygular.
    private func toolDBImport(_ arguments: [String: Any]) async -> ToolOutcome {
        let engine: DBEngine
        switch resolveEngine(arguments) {
        case .failure(let outcome): return outcome
        case .success(let e):       engine = e
        }
        guard let name = arguments["name"] as? String, !name.isEmpty else {
            return .invalidParams("'name' argümanı zorunludur")
        }
        guard Self.isSafeIdentifier(name) else {
            return .failure("Geçersiz veritabanı adı: '\(name)' — yalnızca harf, rakam ve alt çizgi kullanın")
        }
        guard let rawPath = arguments["path"] as? String, !rawPath.isEmpty else {
            return .invalidParams("'path' argümanı zorunludur")
        }
        let inPath: String
        switch Self.validatedSQLPath(rawPath) {
        case .failure(let outcome): return outcome
        case .success(let p):       inPath = p
        }
        guard FileHelper.exists(inPath) else {
            return .failure("Dosya bulunamadı: \(inPath)")
        }

        let createIfMissing = arguments["create_if_missing"] as? Bool ?? true
        if createIfMissing {
            // Var olan veritabanına dokunmaz ("CREATE DATABASE IF NOT EXISTS" semantiği)
            switch await toolDBCreate(["name": name, "engine": engine.rawValue]) {
            case .text:                    break
            case .failure(let msg),
                 .invalidParams(let msg):  return .failure("Hedef veritabanı hazırlanamadı — \(msg)")
            }
        }

        let src = Shell.quote(inPath)
        let result: Shell.Result
        switch engine {
        case .mysql:
            // Kullanıcı ÖNCE yoklanır, döküm SONRA TEK KEZ uygulanır. `cmd1 || cmd2`
            // kalıbı burada güvenli değil: MySQL'de DDL örtük commit yapar, yani
            // yarıda kesilen ilk deneme geri ALINMAZ ve ikinci deneme o ana kadarki
            // INSERT'leri tekrar işleyip satırları ikiye katlar.
            let probe = await Shell.brewBashAsync(
                "mysql -u root -h 127.0.0.1 --connect-timeout=3 -e 'SELECT 1' 2>/dev/null")
            let user = probe.isSuccess ? "root" : NSUserName()
            result = await Shell.brewBashAsync(
                "mysql -u \(Shell.quote(user)) \(Shell.quote(name)) < \(src) 2>&1")
        case .postgres:
            let port: Int
            switch runningPostgresPort() {
            case .failure(let outcome): return outcome
            case .success(let p):       port = p
            }
            // ON_ERROR_STOP=1 ŞART: onsuz psql, dökümdeki HER ifade hata verse bile 0 ile
            // biter ve araç tamamen başarısız bir geri yüklemeyi "aktarıldı" diye raporlar.
            // --single-transaction ise psqlFallback'in `||` yedeğini güvenli kılar: ilk
            // deneme yarıda kalırsa tamamen geri alınır, ikinci deneme yarım uygulanmış
            // bir veritabanının üstüne yazmaz. Arayüzdeki aynı iş de böyle yapılıyor.
            result = await Shell.brewBashAsync(Self.psqlFallback(
                "psql -h 127.0.0.1 -p \(port) {U} -v ON_ERROR_STOP=1 --single-transaction "
                + "-d \(Shell.quote(name)) -f \(src)"))
        }

        guard result.isSuccess else {
            let err = result.error.isEmpty ? result.output : result.error
            return .failure("'\(name)' içine aktarım başarısız — \(err)")
        }
        return .text("'\(inPath)' → '\(name)' veritabanına aktarıldı")
    }

    private static func nonEmptyLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func jsonText(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object))
            ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Yanıt kodlanamadı"}}"#.utf8)
    }

    private static func textBody(_ text: String) -> Data { Data(text.utf8) }

    // MARK: - Köken Doğrulama

    /// Yalnızca gerçek loopback adları kabul edilir (TAM eşleşme, önek DEĞİL).
    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    /// `http://localhost:8765` gibi bir Origin'i ayrıştırıp host'u tam eşleştirir.
    static func isLoopbackOrigin(_ origin: String) -> Bool {
        guard let comps = URLComponents(string: origin),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = comps.host?.lowercased() else { return false }
        return loopbackHosts.contains(host)
    }

    /// `127.0.0.1:8765` biçimindeki Host başlığını doğrular (port isteğe bağlı).
    static func isLoopbackHost(_ header: String) -> Bool {
        let value = header.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty else { return false }
        // IPv6 köşeli parantezli biçim: [::1]:8765
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return false }
            return loopbackHosts.contains(String(value[value.startIndex...close]))
        }
        let host = value.components(separatedBy: ":").first ?? value
        return loopbackHosts.contains(host)
    }

    // MARK: - HTTP Ayrıştırma / Yazma

    private static func parse(_ buffer: Data) -> HTTPParseResult {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }

        let headerData = buffer.subdata(in: buffer.startIndex..<separator.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return .invalid }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .invalid }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key   = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        // Content-Length SINIRDA doğrulanır: negatif değer (ör. "-1") aşağıdaki
        // Range'i lowerBound > upperBound yapar ve yakalanamaz bir trap üretir —
        // ayrıştırma MainActor'da koştuğundan tek satırlık bir istek uygulamayı
        // komple çökertirdi. 1 MB üstü bildirim de gövde birikmesini beklemeden reddedilir.
        let contentLength: Int
        if let raw = headers["content-length"] {
            guard let n = Int(raw), (0...maxRequestBytes).contains(n) else { return .invalid }
            contentLength = n
        } else {
            contentLength = 0
        }
        let bodyStart = separator.upperBound
        guard buffer.endIndex - bodyStart >= contentLength else { return .incomplete }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))

        // Sorgu dizesi yoldan ayrılır (?foo=bar)
        let path = parts[1].components(separatedBy: "?").first ?? parts[1]
        return .request(HTTPRequest(method: parts[0].uppercased(), path: path,
                                    headers: headers, body: body))
    }

    /// Yanıtı yazar ve bağlantıyı kapatır (her istek tek yanıtla biter — Connection: close).
    private static func send(_ status: Int, body: Data?,
                             contentType: String? = nil, on connection: NWConnection) {
        var head = "HTTP/1.1 \(status) \(reason(for: status))\r\n"
        head += "Content-Length: \(body?.count ?? 0)\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        if let body { payload.append(body) }
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 501: return "Not Implemented"
        default:  return "Internal Server Error"
        }
    }
}
