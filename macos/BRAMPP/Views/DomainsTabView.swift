import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

// MARK: - Domains Tab

struct DomainsTabView: View {
    @EnvironmentObject var loc: Localizer

    @EnvironmentObject var domainManager: DomainManager
    @EnvironmentObject var serviceManager: ServiceManager
    @State private var showAddSheet: Bool = false
    @State private var showPortShare: Bool = false
    @State private var selectedEditDomain: Domain?
    @State private var selectedLogDomain: Domain?
    @State private var showDeleteAlert: Bool = false
    @State private var domainToDelete: Domain?
    @State private var searchText: String = ""
    @State private var missingHosts: [String] = []
    @State private var isRepairingHosts: Bool = false

    private var filteredDomains: [Domain] {
        guard !searchText.isEmpty else { return domainManager.domains }
        return domainManager.domains.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !missingHosts.isEmpty { hostsRepairBanner }
            searchBar
            Divider()
            domainList
        }
        .onAppear { missingHosts = domainManager.missingHostsEntries() }
        .onChange(of: domainManager.domains) { missingHosts = domainManager.missingHostsEntries() }
        .sheet(isPresented: $showPortShare) {
            SharePortSheetView()
        }
        .sheet(isPresented: $showAddSheet)           { AddDomainSheet() }
        .sheet(item: $selectedEditDomain)  { d in EditDomainSheet(domain: d) }
        .sheet(item: $selectedLogDomain)   { d in DomainLogSheet(domain: d) }
        .alert(loc.t("dom.deleteTitle"), isPresented: $showDeleteAlert, presenting: domainToDelete) { d in
            Button(loc.t("common.cancel"), role: .cancel) { }
            Button(loc.t("dom.delete"), role: .destructive) { Task { await domainManager.removeDomain(d) } }
        } message: { d in
            Text(String(format: loc.t("dom.deleteMsg"), d.name))
        }
        // Başlatma hatası / port çakışması uyarısı
        .alert(item: Binding(
            get: { domainManager.activeAlert },
            set: { domainManager.activeAlert = $0 }
        )) { alert in
            Alert(
                title:   Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text(loc.t("common.ok")))
            )
        }
        // ⌘N bayrağı: ContentView sekmeyi buraya çevirip bayrağı diker. Bildirimi doğrudan
        // dinlemek yetmezdi — başka sekmedeyken bu view mevcut olmadığından bildirimi kaçırırdı.
        .onAppear { consumePendingAddSheet() }
        .onChange(of: domainManager.pendingOpenAddSheet) { _, pending in
            if pending { consumePendingAddSheet() }
        }
    }

    /// ⌘N bayrağını tüketip "Yeni Alan Adı" sheet'ini açar.
    private func consumePendingAddSheet() {
        guard domainManager.pendingOpenAddSheet else { return }
        domainManager.pendingOpenAddSheet = false
        showAddSheet = true
    }

    /// /etc/hosts'ta eksik giriş tespit edilince görünen onarım şeridi
    private var hostsRepairBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: loc.t("dom.hostsMissing"), missingHosts.count))
                    .font(.caption).fontWeight(.medium)
                Text(missingHosts.joined(separator: ", "))
                    .font(.caption2).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button(isRepairingHosts ? loc.t("dom.repairing") : loc.t("dom.repair")) {
                isRepairingHosts = true
                Task {
                    await domainManager.repairHosts()
                    missingHosts = domainManager.missingHostsEntries()
                    isRepairingHosts = false
                }
            }
            .controlSize(.small)
            .disabled(isRepairingHosts)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.orange.opacity(0.1))
    }

    private var toolbar: some View {
        HStack {
            Text(loc.t("dom.title")).font(.headline)
            let count = searchText.isEmpty ? domainManager.domains.count : filteredDomains.count
            Text("(\(count))").foregroundColor(.secondary)
            Spacer()
            Button(action: { showPortShare = true }) {
                Label(loc.t("share.port.menu"), systemImage: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(.bordered)
            .disabled(!TunnelManager.isCloudflaredInstalled)
            .help(TunnelManager.isCloudflaredInstalled ? "" : loc.t("dom.share.needsInstall"))
            Button(action: { showAddSheet = true }) { Label(loc.t("dom.new"), systemImage: "plus") }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField(loc.t("dom.search"), text: $searchText).textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var domainList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if searchText.isEmpty { LocalhostRowView() }

                if filteredDomains.isEmpty && !searchText.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").font(.title2).foregroundColor(.secondary)
                        Text(String(format: loc.t("dom.noResult"), searchText)).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                } else if domainManager.domains.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "globe").font(.system(size: 36)).foregroundColor(.secondary)
                        Text(loc.t("dom.empty")).font(.headline)
                        Text(loc.t("dom.emptyHint")).foregroundColor(.secondary)
                        Button(action: { showAddSheet = true }) { Label(loc.t("dom.new"), systemImage: "plus") }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                } else {
                    ForEach(filteredDomains) { domain in
                        DomainRowView(
                            domain:       domain,
                            onOpenApache: { domainManager.openInBrowser(domain, via: .apache,
                                                                        httpPort:  serviceManager.currentApacheHTTPPort(),
                                                                        httpsPort: serviceManager.currentApacheHTTPSPort()) },
                            onOpenNginx:  { domainManager.openInBrowser(domain, via: .nginx,
                                                                        httpPort:  serviceManager.currentNginxHTTPPort(),
                                                                        httpsPort: serviceManager.currentNginxHTTPSPort()) },
                            onFinder:   { domainManager.openInFinder(domain) },
                            onConfig:   { domainManager.openConfig(domain) },
                            onEdit:     { selectedEditDomain = domain },
                            onErrorLog: { selectedLogDomain  = domain },
                            onDelete:   { domainToDelete = domain; showDeleteAlert = true }
                        )
                    }
                }
            }
            .padding()
        }
    }
}

// MARK: - Domain Row View

struct DomainRowView: View {
    @EnvironmentObject var loc: Localizer

    @EnvironmentObject var domainManager: DomainManager
    @EnvironmentObject var tunnelManager: TunnelManager

    let domain: Domain
    let onOpenApache: () -> Void
    let onOpenNginx:  () -> Void
    let onFinder:     () -> Void
    let onConfig:     () -> Void
    let onEdit:       () -> Void
    let onErrorLog:   () -> Void
    let onDelete:     () -> Void

    @State private var isTogglingApp: Bool  = false
    @State private var showAppLog:    Bool  = false
    @State private var showRename:    Bool  = false
    @State private var renameText:    String = ""
    @State private var isRenaming:    Bool  = false
    @State private var renameError:   String? = nil
    /// PID badge değeri — body'de her render'da senkron disk okumak yerine önbellek.
    @State private var cachedPID:     String? = nil
    @State private var showShare:     Bool   = false

    /// Bu alan adı şu anda yayında mı — satırdaki simgenin rengi buna bağlı.
    /// Proje klasöründe yapılabilecek işler — editörde aç, terminal, composer, npm.
    ///
    /// İçerik her açılışta yeniden hesaplanır: kullanıcı arada `composer.json` ekleyebilir
    /// ya da bir editör kurabilir. Menü boşsa hiç gösterilmez.
    @ViewBuilder
    private var projectActionsMenu: some View {
        let editors = ProjectActions.installedEditors { FileHelper.exists($0) }
        let site = domain.sitePath
        let pkgPath = "\(site)/package.json"
        let tasks = ProjectActions.availableTasks(
            hasComposerJSON: FileHelper.exists("\(site)/composer.json"),
            packageJSON: FileHelper.readString(pkgPath),
            composerInstalled: !PathConfig.composer.isEmpty,
            npmInstalled: !PathConfig.npm.isEmpty)

        Menu {
            ForEach(editors) { e in
                Button(String(format: loc.t("dom.act.openIn"), e.name)) {
                    NSWorkspace.shared.open(
                        [URL(fileURLWithPath: site)],
                        withApplicationAt: URL(fileURLWithPath: "/Applications/\(e.bundleName).app"),
                        configuration: NSWorkspace.OpenConfiguration())
                }
            }
            Button(loc.t("dom.act.terminal")) {
                TerminalHelper.runInNewWindow("cd \(Shell.quote(site)) && clear",
                                              title: domain.name)
            }
            Divider()
            // brampp.yml — projeyi başka bir Mac'te aynı kuran taşınabilir manifest
            Button(loc.t("dom.act.writeManifest")) { writeManifest(site: site) }
            if FileHelper.exists("\(site)/\(ProjectManifest.fileName)") {
                Button(loc.t("dom.act.applyManifest")) { applyManifest(site: site) }
            }
            if !tasks.isEmpty {
                Divider()
                ForEach(tasks) { task in
                    Button(task.label) {
                        // Terminalde çalıştırılır: composer/npm dakikalarca sürebilir ve
                        // çıktısı canlı görünmeli — sessiz bir arka plan işi olarak
                        // koşturmak kullanıcıyı neyin olduğundan habersiz bırakırdı.
                        TerminalHelper.runInNewWindow(
                            "cd \(Shell.quote(site)) && "
                            + task.command(npmBin: PathConfig.npm, composerBin: PathConfig.composer),
                            title: "\(domain.name) — \(task.label)")
                    }
                }
            }
        } label: {
            Image(systemName: "hammer")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22)
        .help(loc.t("dom.act.menu"))
    }

    /// Alan adı ayarlarını proje klasörüne `brampp.yml` olarak yazar.
    private func writeManifest(site: String) {
        // Framework algılaması yalnızca SERVİS önerisi için kullanılır; belge kökü
        // gibi alanlar alan adının GERÇEK ayarlarından gelir — tahmin değil.
        let files = Set(FileHelper.contentsOfDirectory(site))
        let detection = FrameworkDetector.detect(
            files: files,
            composerJSON: FileHelper.readString("\(site)/composer.json"),
            packageJSON: FileHelper.readString("\(site)/package.json"))
        let m = ProjectManifest.from(domain: domain, services: detection?.suggestedServices ?? [])
        let path = "\(site)/\(ProjectManifest.fileName)"
        if FileHelper.write(m.yaml(), to: path) {
            domainManager.log(key: "log.dom.manifestWritten", args: [domain.name], type: .success)
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: site)
        } else {
            domainManager.log(key: "log.dom.manifestFailed", args: [path], type: .error)
        }
    }

    /// Klasördeki `brampp.yml`'yi bu alan adına uygular.
    private func applyManifest(site: String) {
        let path = "\(site)/\(ProjectManifest.fileName)"
        guard let text = FileHelper.readString(path),
              let m = ProjectManifest.parse(text) else {
            domainManager.log(key: "log.dom.manifestInvalid", args: [path], type: .error)
            return
        }
        var updated = domain
        let changes = ProjectManifest.apply(m, to: &updated)
        guard !changes.isEmpty else {
            domainManager.log(key: "log.dom.manifestNoChange", args: [domain.name], type: .info)
            return
        }
        domainManager.updateDomain(updated)
        domainManager.log(key: "log.dom.manifestApplied",
                          args: [domain.name, changes.joined(separator: ", ")], type: .success)
    }

    private var isSharing: Bool {
        tunnelManager.tunnel(for: domain.name)?.isLive == true
    }

    /// Paylaşım hiç mümkün mü — cloudflared kurulu değilse düğme pasif olur.
    private var canShare: Bool { TunnelManager.isCloudflaredInstalled }

    private var isAppPlatform: Bool {
        [Platform.nodejs, .python, .dotnet].contains(domain.platform)
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(domain.platform.assetName)
                .resizable().interpolation(.high)
                .frame(width: 34, height: 34).frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                // Ad + durum satırı
                HStack(spacing: 6) {
                    Text(domain.name).font(.headline)
                        .foregroundColor(domain.isEnabled ? .primary : .secondary)
                    if !domain.isEnabled {
                        Text(loc.t("dom.disabled"))
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.gray.opacity(0.2))
                            .foregroundColor(.secondary)
                            .cornerRadius(4)
                    }
                    Circle()
                        .fill(domain.isRunning ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    if isAppPlatform && domain.isEnabled {
                        Text(domain.isRunning ? loc.t("dom.running") : loc.t("menu.stopped"))
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(domain.isRunning ? Color.green.opacity(0.15) : Color.red.opacity(0.12))
                            .foregroundColor(domain.isRunning ? .green : .red)
                            .cornerRadius(4)
                    }
                    if domain.sslEnabled {
                        Image(systemName: "lock.fill").font(.caption).foregroundColor(.green)
                    }
                }
                // Badge satırı
                HStack(spacing: 6) {
                    Text(domain.versionDisplay)
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(domain.platform.color.opacity(0.2))
                        .foregroundColor(domain.platform.color).cornerRadius(4)

                    Label(domain.webServer.displayName, systemImage: domain.webServer.sfSymbol)
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(domain.webServer.color.opacity(0.15))
                        .foregroundColor(domain.webServer.color).cornerRadius(4)

                    if let port = domain.port {
                        Text(verbatim: ":\(port)").font(.caption).foregroundColor(.secondary)
                    }
                    // Çalışan uygulama için PID badge'i (önbellekten — body'de disk okuma yok)
                    if isAppPlatform && domain.isRunning, let pidStr = cachedPID, !pidStr.isEmpty {
                        Text("PID \(pidStr)")
                            .font(.caption2).monospacedDigit()
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.blue.opacity(0.12))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                            .help(String(format: loc.t("dom.pidTip"), pidStr))
                    }
                    if FileHelper.exists(domain.bramppConfigPath) {
                        Image(systemName: "doc.badge.gearshape")
                            .font(.caption).foregroundColor(.secondary)
                            .help(loc.t("dom.configExists"))
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                // Başlat / Durdur + Log — sadece app platformlar
                if isAppPlatform {
                    Button(action: toggleApp) {
                        if isTogglingApp {
                            ProgressView().scaleEffect(0.65).frame(width: 16, height: 16)
                        } else if domain.isRunning {
                            Image(systemName: "stop.circle.fill")
                                .foregroundColor(.red).font(.system(size: 16))
                        } else {
                            Image(systemName: "play.circle.fill")
                                .foregroundColor(.green).font(.system(size: 16))
                        }
                    }
                    .disabled(isTogglingApp)
                    .help(domain.isRunning ? loc.t("dom.startStop.stop") : loc.t("dom.startStop.start"))

                    // Uygulama Log
                    Button(action: { showAppLog = true }) {
                        Image(systemName: "terminal.fill")
                            .foregroundColor(.secondary).font(.system(size: 14))
                    }
                    .help("Uygulama Log")

                    Divider().frame(height: 16)
                }

                // Tarayıcı butonu — sadece seçili web sunucu
                switch domain.webServer {
                case .apache:
                    Button(action: onOpenApache) {
                        Image(systemName: "safari").foregroundColor(.orange)
                    }.help(loc.t("dom.openApache"))
                case .nginx:
                    Button(action: onOpenNginx) {
                        Image(systemName: "safari.fill").foregroundColor(.green)
                    }.help(loc.t("dom.openNginx"))
                }

                Button(action: onFinder)   { Image(systemName: "folder") }
                    .help(loc.t("dom.finder"))
                projectActionsMenu
                Button(action: onConfig)   { Image(systemName: "doc.text") }
                    .help("VHost Config")
                Button(action: onEdit)     { Image(systemName: "slider.horizontal.3") }
                    .help(loc.t("dom.settings"))
                Button(action: onErrorLog) { Image(systemName: "exclamationmark.bubble") }
                    .help(loc.t("dom.logs"))
                Button(action: { showShare = true }) {
                    // Yayın durumu satıra bakınca anlaşılmalı: yeşil = yayında,
                    // kırmızı = kapalı. Kullanıcı sitesinin şu anda internete açık
                    // olup olmadığını pencere açmadan görebilmeli.
                    Image(systemName: isSharing ? "antenna.radiowaves.left.and.right"
                                                : "antenna.radiowaves.left.and.right.slash")
                        .foregroundColor(canShare ? (isSharing ? .green : .red) : .secondary)
                }
                // cloudflared yoksa düğme PASİF: tıklayıp kurulum ekranıyla
                // karşılaşmaktansa neden çalışmadığını ipucunda okumak daha dürüst.
                .disabled(!canShare)
                .help(!canShare ? loc.t("dom.share.needsInstall")
                      : (isSharing ? loc.t("dom.share.live") : loc.t("dom.share.off")))
                Button(action: onDelete)   { Image(systemName: "trash").foregroundColor(.red) }
                    .help(loc.t("dom.delete"))
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .task(id: "\(domain.name)|\(domain.isRunning)") {
            // PID dosyasını body dışında, durum değişince oku (senkron disk okuma body'den
            // çıktı). Ad da id'de: rename sonrası PID dosya yolu değişir — yalnız isRunning
            // izlenseydi eski adın PID'i bayat kalırdı.
            cachedPID = (isAppPlatform && domain.isRunning)
                ? FileHelper.readString(NativeProcessManager.pidFile(for: domain))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
        }
        .contextMenu {
            Button {
                domainManager.healthCheck(domain)
            } label: {
                Label(loc.t("dom.testConn"), systemImage: "stethoscope")
            }
            Button {
                domainManager.copyURL(domain)
            } label: {
                Label("URL'yi Kopyala", systemImage: "doc.on.doc")
            }
            Divider()
            Button(action: onFinder)   { Label(loc.t("dom.finder"), systemImage: "folder") }
            Button(action: onConfig)   { Label("VHost Config", systemImage: "doc.text") }
            Button(action: onEdit)     { Label(loc.t("dom.settings"), systemImage: "slider.horizontal.3") }
            Button {
                renameText  = domain.name
                renameError = nil        // önceki başarısız denemenin hatası yeniden görünmesin
                showRename  = true
            } label: { Label(loc.t("dom.rename"), systemImage: "pencil") }
            Button {
                Task { await domainManager.setDomainEnabled(domain, enabled: !domain.isEnabled) }
            } label: {
                Label(domain.isEnabled ? loc.t("dom.disable") : loc.t("dom.enable"),
                      systemImage: domain.isEnabled ? "pause.circle" : "play.circle")
            }
            Button(action: onErrorLog) { Label(loc.t("dom.logs"), systemImage: "exclamationmark.bubble") }
            if isAppPlatform {
                Button { showAppLog = true } label: { Label(loc.t("dom.appLog"), systemImage: "terminal") }
            }
            Divider()
            Button(role: .destructive, action: onDelete) { Label(loc.t("common.delete"), systemImage: "trash") }
        }
        .sheet(isPresented: $showShare) {
            ShareSheetView(domain: domain)
        }
        .sheet(isPresented: $showAppLog) {
            AppLogSheet(domain: domain)
        }
        .sheet(isPresented: $showRename) {
            renameSheet
        }
    }

    private var renameSheet: some View {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces).lowercased()
        let unchanged = trimmed == domain.name
        return VStack(alignment: .leading, spacing: 14) {
            Text(loc.t("dom.rename.title")).font(.headline)
            Text(String(format: loc.t("dom.rename.desc"), domain.name))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("yeni.domain.test", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .disabled(isRenaming)
                .onSubmit { if !unchanged && !trimmed.isEmpty { performRename() } }
            if domain.sslEnabled {
                Label(loc.t("dom.rename.ssl"), systemImage: "lock.shield")
                    .font(.caption2).foregroundColor(.secondary)
            }
            if let err = renameError {
                Text(err).font(.caption).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(loc.t("common.cancel")) { showRename = false }.disabled(isRenaming)
                Button(isRenaming ? loc.t("dom.rename.applying") : loc.t("dom.rename")) { performRename() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRenaming || unchanged || trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func performRename() {
        guard !isRenaming else { return }
        isRenaming = true
        renameError = nil
        let target = renameText
        Task {
            let result = await domainManager.renameDomain(domain, to: target)
            isRenaming = false
            switch result {
            case .success:            showRename = false
            case .failure(let msg):   renameError = msg   // hata sheet İÇİNDE görünür
            }
        }
    }

    private func toggleApp() {
        guard !isTogglingApp else { return }
        isTogglingApp = true
        Task {
            if domain.platform == .python {
                if domain.isRunning { await domainManager.stopPythonApp(domain: domain) }
                else                { await domainManager.startPythonApp(domain: domain) }
            } else {
                if domain.isRunning { await domainManager.stopNativeApp(domain: domain) }
                else                { await domainManager.startNativeApp(domain: domain) }
            }
            isTogglingApp = false
        }
    }
}

// MARK: - App Log Sheet (tüm uygulama platformları — PM2'siz)

struct AppLogSheet: View {
    @EnvironmentObject var loc: Localizer

    @EnvironmentObject var domainManager: DomainManager
    let domain: Domain
    @Environment(\.dismiss) var dismiss

    /// Log içeriği artık ÇEKİLMİYOR, akıtılıyor — dosya izleyici anında günceller.
    @StateObject private var tailer = LogTailer()
    @State private var isLoading:   Bool    = false
    /// Zamanlayıcı yalnızca CPU/bellek/PID çubuğu için: `ps` çıktısının izlenecek
    /// bir dosyası yok, o yüzden orada yoklama kaçınılmaz — ama artık seyrek.
    @State private var autoRefresh: Bool    = false
    @State private var timer:       Timer?  = nil
    @State private var procInfo:    NativeProcessManager.AppProcessInfo? = nil

    private var logTitle: String {
        "Uygulama Log — \(domain.name)"
    }

    /// Log dosyası yolu — Terminal'de `tail -f` için (tüm platformlar ortak)
    private var logFilePath: String {
        NativeProcessManager.logFile(for: domain)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill").foregroundColor(.green)
                Text(logTitle).font(.headline)
                Spacer()
                if isLoading { ProgressView().scaleEffect(0.7).frame(width: 20) }

                Toggle(loc.t("dom.autoRefresh"), isOn: $autoRefresh)
                    .toggleStyle(.switch).controlSize(.small)

                Button(action: refreshProcessInfo) {
                    Label(loc.t("common.refresh"), systemImage: "arrow.clockwise")
                }.buttonStyle(.borderless)
                .disabled(isLoading)

                // Temizle — tüm platformlar için
                Button(action: clearLogs) {
                    Label("Temizle", systemImage: "trash")
                }.buttonStyle(.bordered)

                Button(action: openInTerminal) {
                    Label("Terminal", systemImage: "terminal")
                }.buttonStyle(.bordered)

                Button(loc.t("common.close")) { dismiss() }.buttonStyle(.borderless)
            }
            .padding()

            Divider()

            // Süreç izleme çubuğu — gerçek app PID, CPU, bellek
            processInfoBar
                .padding(.horizontal).padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Log içerik
            ScrollViewReader { proxy in
                ScrollView {
                    Text(tailer.text)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                        .id("bottom")
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: tailer.text) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .frame(width: 740, height: 500)
        .onAppear {
            tailer.start(path: NativeProcessManager.logFile(for: domain),
                         placeholder: loc.t("dom.log.empty"))
            refreshProcessInfo()
        }
        .onDisappear {
            tailer.stop()
            timer?.invalidate(); timer = nil
        }
        .onChange(of: autoRefresh) { _, on in
            timer?.invalidate(); timer = nil
            if on {
                // 5 sn yerine 3 sn: artık tek işi süreç istatistikleri, log değil.
                timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                    Task { @MainActor in refreshProcessInfo() }
                }
            }
        }
    }

    // MARK: - Süreç İzleme Çubuğu

    @ViewBuilder
    private var processInfoBar: some View {
        HStack(spacing: 14) {
            let running = procInfo?.appPID != nil
            HStack(spacing: 5) {
                Circle().fill(running ? Color.green : Color.red).frame(width: 8, height: 8)
                Text(running ? loc.t("dom.running") : loc.t("dom.notRunning"))
                    .font(.caption).foregroundColor(running ? .green : .red)
            }
            if let port = domain.port {
                monitorChip(icon: "network", label: "Port", value: ":\(port)")
            }
            if let appPID = procInfo?.appPID {
                monitorChip(icon: "cpu", label: "App PID", value: "\(appPID)")
            }
            if let wp = procInfo?.wrapperPID {
                monitorChip(icon: "shippingbox", label: "Wrapper", value: "\(wp)")
            }
            if let cpu = procInfo?.cpu {
                monitorChip(icon: "gauge", label: "CPU", value: "%\(cpu)")
            }
            if let mem = procInfo?.memoryMB {
                monitorChip(icon: "memorychip", label: "Bellek", value: "\(mem) MB")
            }
            if let cmd = procInfo?.command {
                Text(cmd).font(.caption2.monospaced()).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
        }
    }

    private func monitorChip(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2).foregroundColor(.secondary)
            Text(label).font(.caption2).foregroundColor(.secondary)
            Text(verbatim: value).font(.caption2.monospaced().weight(.medium))
        }
    }

    /// Yalnızca CPU/bellek/PID çubuğunu tazeler — log kendi başına akıyor.
    private func refreshProcessInfo() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            procInfo = await NativeProcessManager.processInfo(for: domain)
            isLoading = false
        }
    }

    private func clearLogs() {
        NativeProcessManager.clearLogs(for: domain)
        tailer.reset()
        refreshProcessInfo()
    }

    private func openInTerminal() {
        TerminalHelper.runInNewWindowAndWait("tail -f '\(logFilePath)'")
    }
}

// MARK: - Env Vars Editor

/// Ortam değişkeni satırı — kararlı `id` sayesinde ForEach silmede çökmez.
struct EnvPair: Identifiable, Equatable {
    let id = UUID()
    var key: String
    var value: String

    /// Geçerli bir shell tanımlayıcısı deseni. start.sh'a `export KEY='...'` olarak
    /// yazıldığından anahtar bu desene UYMAK ZORUNDA.
    ///
    /// TEK KAYNAK: NativeProcessManager (start.sh üreticisi) aynı deseni uygular ama
    /// orada eşleşmeyen satır SESSİZCE atlanır. Kullanıcı "MY KEY" yazıp kaydedebiliyor,
    /// değişken script'e hiç girmiyor ve uygulama açıklanamayan biçimde yanlış
    /// davranıyordu. Denetim artık BURADA, kaydetmeden önce yapılır; oradaki atlama
    /// yalnızca son savunma hattıdır.
    static let keyPattern = "^[A-Za-z_][A-Za-z0-9_]*$"

    /// Tamamen boş satır (yeni eklenmiş, henüz doldurulmamış) geçerli sayılır —
    /// kaydederken zaten elenir. Değeri girilip anahtarı boş bırakılan satır ise
    /// aynı sessiz kaybı yaşatacağından GEÇERSİZDİR.
    var isKeyValid: Bool {
        if key.isEmpty { return value.isEmpty }
        return key.range(of: Self.keyPattern, options: .regularExpression) != nil
    }

    /// Listede kaydetmeyi engelleyen bir satır var mı?
    static func hasInvalid(_ pairs: [EnvPair]) -> Bool {
        pairs.contains { !$0.isKeyValid }
    }
}

struct EnvVarsEditorView: View {
    @EnvironmentObject var loc: Localizer

    @Binding var pairs: [EnvPair]

    var body: some View {
        VStack(spacing: 6) {
            if pairs.isEmpty {
                Text(loc.t("dom.env.empty"))
                    .font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            } else {
                // Kararlı id ile bağla — indeks yerine id kullanıldığından silme sırasında
                // "Index out of range" çökmesi oluşmaz.
                ForEach($pairs) { $pair in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            TextField("KEY", text: $pair.key)
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 90, maxWidth: 130)
                                .font(.system(.caption, design: .monospaced))
                                // Geçersiz anahtar start.sh'a HİÇ yazılmıyor — sorun
                                // kaydetmeden ÖNCE, girildiği yerde görünür olmalı
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(Color.red, lineWidth: pair.isKeyValid ? 0 : 1.5)
                                )
                            Text("=").foregroundColor(.secondary).font(.caption)
                            TextField("value", text: $pair.value)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                            Button(action: { pairs.removeAll { $0.id == pair.id } }) {
                                Image(systemName: "minus.circle.fill").foregroundColor(.red)
                            }.buttonStyle(.borderless).help(loc.t("dom.delete"))
                        }
                        if !pair.isKeyValid {
                            Text(loc.t("dom.env.keyInvalid"))
                                .font(.caption2).foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            HStack {
                Button(action: { pairs.append(EnvPair(key: "", value: "")) }) {
                    Label(loc.t("dom.env.add"), systemImage: "plus.circle").font(.caption)
                }.buttonStyle(.borderless)
                Spacer()
            }
        }
    }
}

// MARK: - Edit Domain Sheet

struct EditDomainSheet: View {
    @EnvironmentObject var loc: Localizer

    @EnvironmentObject var domainManager: DomainManager
    @EnvironmentObject var serviceManager: ServiceManager
    @Environment(\.dismiss) var dismiss

    let domain: Domain

    @State private var editedDomain: Domain
    @State private var selectedPHPVersion:    PHPVersion
    @State private var selectedPythonVersion: PythonVersion
    @State private var selectedPythonFramework: PythonFramework
    @State private var selectedNodeVersion:   NodeVersion
    @State private var selectedDotnetVersion: DotNetVersion
    @State private var redirectHTTPToHTTPS: Bool
    @State private var sslEnabled:    Bool
    @State private var spaFallback:   Bool
    @State private var portText:      String
    /// Başlatmadan önce çalışması gereken servisler (id seti)
    @State private var dependencySelection: Set<String>
    @State private var appCommand:    String
    @State private var buildCommand:  String
    @State private var envPairs:      [EnvPair]
    @State private var docRootText:   String
    @State private var isSaving:      Bool = false

    @State private var isBuilding:    Bool   = false
    @State private var buildLog:      String = ""
    @State private var showBuildLog:  Bool   = false

    @State private var showLoadAlert: Bool   = false
    @State private var loadedName:    String = ""

    // Python ayarları
    @State private var pythonUseVenv:    Bool   = true
    // Proxy ayarları
    @State private var websocketEnabled: Bool   = true
    @State private var http2Enabled:     Bool   = false
    @State private var sseEnabled:       Bool   = false
    @State private var grpcEnabled:      Bool   = false
    @State private var maxBodySizeText:  String = ""

    init(domain: Domain) {
        self.domain = domain
        _editedDomain              = State(initialValue: domain)
        _selectedPHPVersion        = State(initialValue: domain.phpVersion       ?? .v83)
        _selectedPythonVersion     = State(initialValue: domain.pythonVersion    ?? .v312)
        _selectedPythonFramework   = State(initialValue: domain.pythonFramework  ?? .fastapi)
        _selectedNodeVersion       = State(initialValue: domain.nodeVersion      ?? .v22)
        _selectedDotnetVersion     = State(initialValue: domain.dotnetVersion    ?? .v9)
        _redirectHTTPToHTTPS       = State(initialValue: domain.redirectHTTPToHTTPS)
        _sslEnabled                = State(initialValue: domain.sslEnabled)
        _spaFallback               = State(initialValue: domain.spaFallback)
        _portText                  = State(initialValue: domain.port.map { "\($0)" } ?? "")
        _dependencySelection       = State(initialValue: Set(domain.serviceDependencies ?? []))
        _appCommand                = State(initialValue: domain.appCommand ?? "")
        _buildCommand              = State(initialValue: domain.buildCommand ?? "")
        _envPairs                  = State(initialValue:
            domain.envVars?.map { EnvPair(key: $0.key, value: $0.value) }.sorted { $0.key < $1.key } ?? [])
        _docRootText               = State(initialValue: domain.customDocumentRoot ?? "")
        _pythonUseVenv       = State(initialValue: domain.pythonUseVenv)
        _websocketEnabled    = State(initialValue: domain.websocketEnabled)
        _http2Enabled        = State(initialValue: domain.http2Enabled)
        _sseEnabled          = State(initialValue: domain.sseEnabled)
        _grpcEnabled         = State(initialValue: domain.grpcEnabled)
        _maxBodySizeText     = State(initialValue: domain.maxBodySize ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(format: loc.t("dom.settingsTitle"), domain.name)).font(.headline)
                Spacer()
                Button(loc.t("common.close")) { dismiss() }.buttonStyle(.borderless)
            }
            .padding()

            Divider()

            Form {
                // MARK: Genel
                Section(loc.t("common.general")) {
                    LabeledContent(loc.t("dom.fieldName")) { Text(editedDomain.name).textSelection(.enabled) }
                    LabeledContent("Platform")    { HStack(spacing: 6) { Image(editedDomain.platform.assetName).resizable().frame(width: 18, height: 18); Text(editedDomain.platform.displayName) } }
                    LabeledContent(loc.t("dom.webServerLabel")) {
                        HStack(spacing: 6) {
                            Image(systemName: editedDomain.webServer.sfSymbol).foregroundColor(editedDomain.webServer.color)
                            Text(editedDomain.webServer.displayName).foregroundColor(editedDomain.webServer.color)
                            Text("HTTP :\(editedDomain.webServer.httpPort)  HTTPS :\(editedDomain.webServer.httpsPort)")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Toggle(isOn: $sslEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("SSL (HTTPS)")
                            Text(sslEnabled
                                 ? loc.t("dom.sslUsedHint")
                                 : loc.t("dom.ssl.enableHint"))
                            .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    if sslEnabled {
                        Toggle(isOn: $redirectHTTPToHTTPS) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loc.t("dom.httpsRedirect"))
                                Text(redirectHTTPToHTTPS
                                     ? loc.t("dom.redirectOn")
                                     : loc.t("dom.redirectOff"))
                                .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    if editedDomain.platform == .static_ {
                        Toggle(isOn: $spaFallback) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loc.t("dom.spa"))
                                Text(loc.t("dom.spaHint"))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }

                // MARK: PHP
                if editedDomain.platform == .php {
                    Section("PHP") {
                        // Kurulu sürümler ✓ ile işaretlenir (Python seçicisiyle simetrik)
                        Picker("PHP Versiyonu", selection: $selectedPHPVersion) {
                            ForEach(PHPVersion.allCases) { v in
                                HStack {
                                    Text(v.displayName)
                                    if v.isInstalled {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.blue)
                                            .font(.caption)
                                    }
                                }.tag(v)
                            }
                        }
                        Text(loc.t("dom.php.note"))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }

                // MARK: Uygulama Ayarları (Node.js / Python / .NET)
                if isAppPlatform {
                    Section(loc.t("dom.appSettings")) {

                        // Port
                        HStack(spacing: 10) {
                            Text("Port").frame(width: 56, alignment: .leading)
                            TextField("", text: $portText)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                            if let issue = portIssue {
                                Text(issue).font(.caption).foregroundColor(.red)
                            } else {
                                Text(String(format: loc.t("dom.portProxyHint"), editedDomain.webServer.displayName))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                        }

                        // Başlatma komutu
                        VStack(alignment: .leading, spacing: 4) {
                            Text(loc.t("dom.startCmd")).font(.subheadline)
                            TextField("", text: $appCommand)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                            Text(String(format: loc.t("dom.startCmdDefault"), defaultAppCmd))
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)

                        // Derleme / Kur
                        VStack(alignment: .leading, spacing: 4) {
                            Text(loc.t("dom.buildInstall")).font(.subheadline)
                            TextField("", text: $buildCommand)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                            Text(String(format: loc.t("dom.defaultVal"), defaultBuildCmd))
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)

                        // Build aksiyon
                        HStack(spacing: 8) {
                            Button(action: runBuild) {
                                if isBuilding { HStack(spacing: 6) { ProgressView().scaleEffect(0.7); Text(loc.t("dom.buildRun")) } }
                                else { Label(loc.t("dom.buildInstall"), systemImage: "hammer") }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isBuilding || buildCommand.trimmingCharacters(in: .whitespaces).isEmpty)

                            let startScriptPath = NativeProcessManager.startScriptPath(for: domain)
                            if FileHelper.exists(startScriptPath) {
                                Button(action: { domainManager.openStartScript(editedDomain) }) {
                                    Label("start.sh", systemImage: "doc.plaintext")
                                }
                                .buttonStyle(.borderless).font(.caption)
                            }

                            if showBuildLog {
                                Button(loc.t("dom.hideLog")) { showBuildLog = false }.buttonStyle(.borderless).font(.caption)
                            } else if !buildLog.isEmpty {
                                Button(loc.t("dom.showLog")) { showBuildLog = true }.buttonStyle(.borderless).font(.caption)
                            }
                        }

                        if showBuildLog && !buildLog.isEmpty {
                            ScrollView {
                                Text(buildLog)
                                    .font(.system(.caption2, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            .frame(height: 120)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(6)
                        }
                    }

                    // MARK: ENV
                    Section {
                        EnvVarsEditorView(pairs: $envPairs)
                        Text(loc.t("dom.env.note"))
                            .font(.caption2).foregroundColor(.secondary)
                    } header: {
                        HStack {
                            Text(loc.t("dom.env.title"))
                            Spacer()
                            Button(action: loadConfigFromFile) {
                                Label(loc.t("dom.jsonLoad"), systemImage: "square.and.arrow.down").font(.caption)
                            }.buttonStyle(.borderless)
                            .help(loc.t("dom.jsonLoadHelp"))

                            if FileHelper.exists(domain.bramppConfigPath) {
                                Button(action: loadLocalConfig) {
                                    Label(loc.t("dom.configLoad"), systemImage: "folder.badge.gearshape").font(.caption)
                                }.buttonStyle(.borderless)
                                .help(loc.t("dom.configLoadHelp"))
                            }
                        }
                    }

                    // MARK: Python Ayarları
                    // MARK: Node.js Sürümü — oluşturmadan sonra da değiştirilebilir
                    // (eskiden yalnızca Add ekranında vardı; yanlış sürüm seçen kullanıcı
                    // domaini silip yeniden oluşturmak zorunda kalıyordu)
                    if editedDomain.platform == .nodejs {
                        Section(loc.t("dom.node.settings")) {
                            Picker("Node.js Versiyonu", selection: $selectedNodeVersion) {
                                ForEach(NodeVersion.allCases) { v in
                                    HStack {
                                        Text(v.displayName)
                                        if v.isInstalled {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.blue)
                                                .font(.caption)
                                        }
                                    }.tag(v)
                                }
                            }
                            Text(loc.t("dom.node.note"))
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }

                    // MARK: .NET Sürümü — oluşturmadan sonra da değiştirilebilir
                    if editedDomain.platform == .dotnet {
                        Section(".NET") {
                            Picker(".NET Versiyonu", selection: $selectedDotnetVersion) {
                                ForEach(DotNetVersion.allCases) { v in
                                    HStack {
                                        Text(v.displayName)
                                        if v.isInstalled {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.blue)
                                                .font(.caption)
                                        }
                                    }.tag(v)
                                }
                            }
                            Text(loc.t("dom.dotnet.note"))
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }

                    if editedDomain.platform == .python {
                        Section(loc.t("dom.python.settings")) {
                            // Versiyon seçici
                            Picker("Python Versiyonu", selection: $selectedPythonVersion) {
                                ForEach(PythonVersion.allCases) { v in
                                    HStack {
                                        Text(v.displayName)
                                        if v.isInstalled {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.blue)
                                                .font(.caption)
                                        }
                                    }.tag(v)
                                }
                            }
                            .onChange(of: selectedPythonVersion) { _, v in
                                // Komut framework'ün varsayılan şablonundaysa (kullanıcı
                                // özelleştirmemişse) güncel framework şablonuna eşitle.
                                // {PORT} şablon olarak kalır — port değişse de komut doğru kalır.
                                if appCommand == (editedDomain.pythonFramework?.serverCommand ?? "") {
                                    appCommand = selectedPythonFramework.serverCommand
                                }
                            }

                            // Framework seçici
                            Picker("Framework", selection: $selectedPythonFramework) {
                                ForEach(PythonFramework.allCases) { f in
                                    Text(f.displayName).tag(f)
                                }
                            }
                            .onChange(of: selectedPythonFramework) { _, f in
                                // Yalnızca kullanıcı ÖZELLEŞTİRMEMİŞSE (komut eski frameworkün
                                // varsayılanıysa) yeni frameworkün varsayılanına geç. Aksi halde
                                // kullanıcının yazdığı komut korunur. (version onChange ile simetrik.)
                                if appCommand.isEmpty || appCommand == (editedDomain.pythonFramework?.serverCommand ?? "") {
                                    appCommand = f.serverCommand
                                }
                            }

                            Divider()

                            // venv toggle
                            let venvPath = PythonProcessManager.detectVenvBin(at: editedDomain.sitePath)
                            Toggle(isOn: $pythonUseVenv) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(loc.t("dom.python.useVenv"))
                                    if let v = venvPath {
                                        Text(String(format: loc.t("dom.python.detected"), v))
                                            .font(.caption).foregroundColor(.green)
                                    } else {
                                        Text(loc.t("dom.venvNotFound"))
                                            .font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                            .disabled(venvPath == nil)

                            // Çözümlenen bilgiler
                            let previewDomain = buildPreviewDomain()
                            let resolvedBin = PythonProcessManager.resolvedBinDir(for: previewDomain)
                            let resolvedCmd = PythonProcessManager.resolvedServerCommand(for: previewDomain)
                            LabeledContent(loc.t("dom.runCommand")) {
                                Text(resolvedCmd).font(.caption).foregroundColor(.secondary)
                                    .multilineTextAlignment(.trailing).textSelection(.enabled)
                            }
                            LabeledContent("Python Dizini") {
                                Text(resolvedBin).font(.caption).foregroundColor(.secondary)
                                    .multilineTextAlignment(.trailing).textSelection(.enabled)
                            }
                        }
                    }

                    // MARK: Proxy Ayarları
                    Section(loc.t("dom.proxy")) {
                        editProxySettingsSection
                    }
                }

                // MARK: Dosya Yolları
                dependenciesSection

                Section(loc.t("dom.filePaths")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Document Root").font(.subheadline)
                        HStack(spacing: 8) {
                            TextField(text: $docRootText, prompt: Text(loc.t("dom.docRootPh"))) {
                                Text("Document Root")
                            }
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            Button(loc.t("dom.select")) { chooseDocumentRoot() }
                            if !docRootText.isEmpty {
                                Button(action: { docRootText = "" }) {
                                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help(loc.t("dom.resetDefault"))
                            }
                        }
                        Text(String(format: loc.t("dom.docRootDefault"), "\(PathConfig.sites)/\(domain.name)"))
                            .font(.caption2).foregroundColor(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.vertical, 2)

                    LabeledContent(loc.t("dom.siteFolder")) {
                        Text(resolvedSitePath).font(.caption).foregroundColor(.secondary)
                            .textSelection(.enabled).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("VHost Config") {
                        Text(editedDomain.vhostConfigPath).font(.caption).foregroundColor(.secondary)
                            .textSelection(.enabled).multilineTextAlignment(.trailing)
                    }
                    if isAppPlatform {
                        LabeledContent("Start Script") {
                            Text(NativeProcessManager.startScriptPath(for: editedDomain))
                                .font(.caption).foregroundColor(.secondary)
                                .textSelection(.enabled).multilineTextAlignment(.trailing)
                        }
                        LabeledContent(loc.t("dom.logFile")) {
                            Text(NativeProcessManager.logFile(for: editedDomain))
                                .font(.caption).foregroundColor(.secondary)
                                .textSelection(.enabled).multilineTextAlignment(.trailing)
                        }
                        LabeledContent(loc.t("dom.hyConfig")) {
                            Text(editedDomain.bramppConfigPath).font(.caption).foregroundColor(.secondary)
                                .textSelection(.enabled).multilineTextAlignment(.trailing)
                        }
                    }
                    LabeledContent("Error Log") {
                        Text(editedDomain.errorLogPath).font(.caption).foregroundColor(.secondary)
                            .textSelection(.enabled).multilineTextAlignment(.trailing)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button(loc.t("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(loc.t("common.save")) { saveChanges() }
                    .buttonStyle(.borderedProminent)
                    // Geçersiz/çakışan port ve geçersiz ENV anahtarı sessizce YUTULMAZ —
                    // kaydetme engellenir (geçersiz anahtar start.sh'a hiç yazılmazdı)
                    .disabled(isSaving || !hasChanges || portIssue != nil || docRootIssue != nil
                              || EnvPair.hasInvalid(envPairs))
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 620, height: 660)
        .alert(loc.t("dom.configLoaded"), isPresented: $showLoadAlert) {
            Button(loc.t("common.ok"), role: .cancel) { }
        } message: {
            Text(String(format: loc.t("dom.loadedOk"), loadedName))
        }
    }

    // MARK: - Helpers

    private var isAppPlatform: Bool {
        [Platform.nodejs, .python, .dotnet].contains(editedDomain.platform)
    }

    /// Geçerli VE çakışmayan port (aksi halde nil → kaydetmede eski port korunur).
    private var parsedPort: Int? {
        guard let p = Int(portText.trimmingCharacters(in: .whitespaces)),
              (1...65535).contains(p),
              !domainManager.isPortInUse(p, excluding: domain.id)
        else { return nil }
        return p
    }

    /// Apache/Nginx'in kullandığı (HTTP+HTTPS) portlar — uygulama bunlara bağlanamaz.
    private var reservedWebServerPorts: Set<Int> {
        [serviceManager.currentApacheHTTPPort(), serviceManager.currentApacheHTTPSPort(),
         serviceManager.currentNginxHTTPPort(), serviceManager.currentNginxHTTPSPort()]
    }

    /// Port alanındaki sorun (nil = sorun yok). Boş alan sorun değildir (port değişmez).
    /// Aralık dışı bir port start.sh'a `export PORT='70000'` olarak yazılır ve uygulama
    /// hiç bağlanamaz; çakışan port ise ikinci uygulamayı sessizce 502'ye düşürür.
    private var portIssue: String? {
        let t = portText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        guard let p = Int(t), (1...65535).contains(p) else { return loc.t("dom.portRange") }
        if domainManager.isPortInUse(p, excluding: domain.id) { return loc.t("dom.portInUse") }
        if reservedWebServerPorts.contains(p) { return loc.t("dom.portReserved") }
        return nil
    }

    /// Kaydedilmemiş document root'a göre çözümlenen site klasörü. Boş alan, saveChanges'in
    /// kuralıyla aynı şekilde çözümlenir: nil olan eski domainde sabit ~/Sites; dolu yol
    /// temizlendiyse Ayarlar'daki Sites klasörü.
    private var resolvedSitePath: String {
        let trimmed = docRootText.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty else { return trimmed }
        guard domain.customDocumentRoot != nil else { return "\(PathConfig.sites)/\(domain.name)" }
        let base = AppSettings.load().sitesPath
        return "\(base.isEmpty ? PathConfig.sites : base)/\(domain.name)"
    }

    /// Alandaki değerin normalize edilmiş hali (boş → nil)
    private var parsedDocRoot: String? {
        let trimmed = docRootText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Site klasöründeki sorun (nil = sorun yok). Boş alan sorun değildir (varsayılan kullanılır).
    /// Bu yol web sunucusu direktiflerinin içine gömüldüğünden tehlikeli karakterler engellenir.
    private var docRootIssue: String? {
        guard let dr = parsedDocRoot else { return nil }
        return DomainManager.isValidDocumentRoot(dr) ? nil : loc.t("dom.docRootInvalid")
    }

    private var defaultAppCmd: String {
        switch editedDomain.platform {
        case .nodejs: return "npm start"
        // {PORT} şablon olarak bırakılır — port değişince komut da güncellenir (502 önlenir)
        case .python: return selectedPythonFramework.serverCommand
        case .dotnet: return "dotnet run --no-launch-profile"
        default:      return ""
        }
    }

    private var defaultBuildCmd: String {
        switch editedDomain.platform {
        case .nodejs: return "npm install"
        case .python: return "pip install -r requirements.txt"
        case .dotnet: return "dotnet restore"
        default:      return ""
        }
    }

    private var envVarsDict: [String: String]? {
        let f = envPairs.filter { !$0.key.isEmpty }
        return f.isEmpty ? nil : Dictionary(f.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
    }

    private var hasChanges: Bool {
        (editedDomain.platform == .php    && selectedPHPVersion    != (domain.phpVersion    ?? .v83))
        || (editedDomain.platform == .python && selectedPythonVersion != (domain.pythonVersion  ?? .v312))
        || (editedDomain.platform == .python && selectedPythonFramework != (domain.pythonFramework ?? .fastapi))
        || (editedDomain.platform == .nodejs && selectedNodeVersion   != (domain.nodeVersion   ?? .v22))
        || (editedDomain.platform == .dotnet && selectedDotnetVersion != (domain.dotnetVersion ?? .v9))
        || redirectHTTPToHTTPS != domain.redirectHTTPToHTTPS
        || sslEnabled != domain.sslEnabled
        || spaFallback != domain.spaFallback
        // Port farkı yalnızca GEÇERLİ bir değerde sayılır — boş/geçersiz giriş kaydetmede
        // sessizce yutulduğundan (eski port korunur), "değişiklik var" göstermek yanıltıcıydı
        || (parsedPort != nil && parsedPort != domain.port)
        || appCommand   != (domain.appCommand   ?? "")
        || buildCommand != (domain.buildCommand ?? "")
        || envVarsDict  != domain.envVars
        || parsedDocRoot != domain.customDocumentRoot
        || dependencySelection != Set(domain.serviceDependencies ?? [])
        || pythonUseVenv    != domain.pythonUseVenv
        || websocketEnabled != domain.websocketEnabled
        || http2Enabled     != domain.http2Enabled
        || sseEnabled       != domain.sseEnabled
        || grpcEnabled      != domain.grpcEnabled
        || (maxBodySizeText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : maxBodySizeText.trimmingCharacters(in: .whitespaces)) != domain.maxBodySize
    }

    /// Mevcut state'den Domain önizlemesi oluşturur (resolvedBinDir/resolvedCmd için)
    private func buildPreviewDomain() -> Domain {
        var d = editedDomain
        d.pythonVersion   = selectedPythonVersion
        d.pythonFramework = selectedPythonFramework
        d.pythonUseVenv   = pythonUseVenv
        d.appCommand      = appCommand.isEmpty ? nil : appCommand
        return d
    }

    // MARK: - Actions


    // MARK: Bağımlılıklar

    /// Seçilebilir bağımlılık adayları: kurulu veritabanı + önbellek servisleri.
    private var dependencyCandidates: [Service] {
        serviceManager.services.filter {
            // Kurulu DB/önbellek servisleri + KAYITLI seçimde geçenler (kaldırılmış olsa bile).
            // İkincisi olmasa, kullanıcı brew'dan kaldırdığı bir bağımlılığı listede
            // göremez ve seçimden ASLA çıkaramazdı.
            (($0.category == .database || $0.category == .cache) && $0.status != .notInstalled)
                || dependencySelection.contains($0.id)
        }
    }

    private var dependenciesSection: some View {
        Section(loc.t("dom.dependencies")) {
            if dependencyCandidates.isEmpty {
                Text(loc.t("dom.depsNone"))
                    .font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(dependencyCandidates, id: \.id) { svc in
                    Toggle(isOn: Binding(
                        get: { dependencySelection.contains(svc.id) },
                        set: { on in
                            if on { dependencySelection.insert(svc.id) }
                            else  { dependencySelection.remove(svc.id) }
                        }
                    )) {
                        HStack(spacing: 6) {
                            Text(svc.name)
                            Circle().fill(svc.status.color).frame(width: 7, height: 7)
                            Text(svc.status.displayName)
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                Text(loc.t("dom.dependenciesHint"))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func saveChanges() {
        guard !isSaving else { return }
        isSaving = true
        if editedDomain.platform == .php    { editedDomain.phpVersion    = selectedPHPVersion }
        if editedDomain.platform == .python {
            editedDomain.pythonVersion   = selectedPythonVersion
            editedDomain.pythonFramework = selectedPythonFramework
        }
        if editedDomain.platform == .nodejs { editedDomain.nodeVersion   = selectedNodeVersion }
        if editedDomain.platform == .dotnet { editedDomain.dotnetVersion = selectedDotnetVersion }
        editedDomain.sslEnabled = sslEnabled
        editedDomain.spaFallback = spaFallback
        // SSL kapatıldıysa yönlendirme de anlamsız — kapat
        editedDomain.redirectHTTPToHTTPS = sslEnabled ? redirectHTTPToHTTPS : false
        if let p = parsedPort { editedDomain.port = p }
        editedDomain.appCommand   = appCommand.isEmpty   ? nil : appCommand
        editedDomain.buildCommand = buildCommand.isEmpty ? nil : buildCommand
        editedDomain.envVars      = envVarsDict
        // Boş alan iki farklı anlama gelir ve ayrıştırılmalıdır:
        // 1) Alan DOLU açılıp kullanıcı bilerek temizlediyse → "varsayılan konuma dön":
        //    yeni oluşturma kuralı uygulanır (Ayarlar'daki Sites klasörüne sabitlenir) —
        //    aksi halde site sessizce ~/Sites tabanına kayardı.
        // 2) Alan zaten boş açılıp boş kaldıysa (customDocumentRoot=nil eski domain) →
        //    DOKUNULMAZ: nil sabit ~/Sites demektir; Ayarlar sonradan değişse bile mevcut
        //    domainlerin klasörleri kaymaz, yalnızca YENİ domainler yeni konuma gider.
        if let dr = parsedDocRoot {
            editedDomain.customDocumentRoot = dr
        } else if domain.customDocumentRoot != nil {
            let base = AppSettings.load().sitesPath
            editedDomain.customDocumentRoot =
                (!base.isEmpty && base != PathConfig.sites) ? "\(base)/\(editedDomain.name)" : nil
        }
        editedDomain.serviceDependencies = dependencySelection.isEmpty ? nil : dependencySelection.sorted()
        // Python ayarları
        editedDomain.pythonUseVenv = pythonUseVenv
        // Proxy ayarları
        editedDomain.websocketEnabled = websocketEnabled
        editedDomain.http2Enabled     = http2Enabled
        editedDomain.sseEnabled       = sseEnabled
        editedDomain.grpcEnabled      = grpcEnabled
        let bodyTrimmed = maxBodySizeText.trimmingCharacters(in: .whitespaces)
        editedDomain.maxBodySize = bodyTrimmed.isEmpty ? nil : bodyTrimmed
        domainManager.updateDomain(editedDomain)
        isSaving = false
        dismiss()
    }

    private func runBuild() {
        guard !isBuilding else { return }
        editedDomain.buildCommand = buildCommand.isEmpty ? nil : buildCommand
        isBuilding = true; buildLog = ""; showBuildLog = true
        Task {
            _ = await domainManager.runBuildCommand(for: editedDomain) { line in
                Task { @MainActor in buildLog += line }
            }
            isBuilding = false
        }
    }

    private func loadConfigFromFile() {
        let panel = NSOpenPanel()
        panel.title = loc.t("dom.selectJSONConfig")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyConfig(from: url.path, name: url.lastPathComponent)
    }

    private func chooseDocumentRoot() {
        let panel = NSOpenPanel()
        panel.title = loc.t("dom.selectDocRoot")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: resolvedSitePath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        docRootText = url.path
    }

    private func loadLocalConfig() {
        applyConfig(from: domain.bramppConfigPath, name: BRAMPPConfig.fileName)
    }

    private func applyConfig(from path: String, name: String) {
        let cfg: BRAMPPConfig
        do {
            cfg = try BRAMPPConfig.readThrowing(at: path)
        } catch {
            domainManager.log(key: "log.dom.configLoadFailed",
                              args: [error.localizedDescription], type: .error)
            loadedName = "❌ \(name) — \(error.localizedDescription)"
            showLoadAlert = true
            return
        }
        if let cmd = cfg.appCommand,   !cmd.isEmpty { appCommand   = cmd }
        if let cmd = cfg.buildCommand, !cmd.isEmpty { buildCommand = cmd }
        if let p   = cfg.port,          p > 0       { portText     = "\(p)" }
        if let env = cfg.envVars,      !env.isEmpty {
            var dict = Dictionary(envPairs.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
            env.forEach { dict[$0.key] = $0.value }
            envPairs = dict.map { EnvPair(key: $0.key, value: $0.value) }.sorted { $0.key < $1.key }
        }
        loadedName = name; showLoadAlert = true
    }

    // MARK: - Proxy Settings Section

    @ViewBuilder
    private var editProxySettingsSection: some View {
        let isNginx = editedDomain.webServer == .nginx

        // WebSocket
        Toggle(isOn: $websocketEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text(loc.t("dom.websocket"))
                Text("ws:// / wss:// upgrade isteklerini proxy'ye iletir")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .disabled(grpcEnabled)

        // SSE
        Toggle(isOn: $sseEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SSE / Streaming")
                Text(loc.t("dom.sse"))
                    .font(.caption).foregroundColor(.secondary)
            }
        }

        // HTTP/2 (Nginx only)
        Toggle(isOn: $http2Enabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("HTTP/2")
                Text(isNginx
                     ? loc.t("dom.http2On")
                     : loc.t("dom.http2Nginx"))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .disabled(!isNginx)

        // gRPC (Nginx only)
        Toggle(isOn: $grpcEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("gRPC Modu")
                Text(isNginx
                     ? loc.t("dom.grpcOn")
                     : loc.t("dom.grpcNginx"))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .disabled(!isNginx)
        .onChange(of: grpcEnabled) { _, enabled in
            if enabled { http2Enabled = true; websocketEnabled = false }
        }

        // Max body size
        HStack(spacing: 10) {
            Text(loc.t("dom.maxSize")).frame(width: 90, alignment: .leading)
            TextField("", text: $maxBodySizeText)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
            Text(loc.t("dom.bodySizePh"))
                .font(.caption).foregroundColor(.secondary)
            Spacer()
        }
        Text(isNginx
             ? loc.t("dom.bodyNginx")
             : loc.t("dom.bodyApache"))
            .font(.caption2).foregroundColor(.secondary)
    }
}

// MARK: - Domain Log Type / Sheet

enum DomainLogType: String, CaseIterable, Identifiable {
    case error, access
    var id: String { rawValue }
    var displayName: String { self == .error ? "Error Log" : "Access Log" }
}

struct DomainLogSheet: View {
    @EnvironmentObject var loc: Localizer

    @EnvironmentObject var domainManager: DomainManager
    let domain: Domain
    @Environment(\.dismiss) var dismiss

    @State private var selectedLogType: DomainLogType = .error
    @State private var logContent: String = ""

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(loc.t("dom.logs")).font(.headline)
                Spacer()
                Button(loc.t("common.close")) { dismiss() }.buttonStyle(.borderless)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(domain.name).font(.title3).fontWeight(.semibold)
                    Text(currentLogPath).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                }
                Spacer()
            }
            HStack {
                Picker(loc.t("dom.logType"), selection: $selectedLogType) {
                    ForEach(DomainLogType.allCases) { t in Text(t.displayName).tag(t) }
                }.pickerStyle(.segmented)
                Button(action: refreshLog) { Label(loc.t("common.refresh"), systemImage: "arrow.clockwise") }
                Button(action: openCurrentLog) { Label(loc.t("dom.openFile"), systemImage: "arrow.up.forward.app") }
            }
            ScrollView {
                Text(logContent.isEmpty ? loc.t("dom.logEmpty") : logContent)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled).padding(12)
            }
            .background(Color(NSColor.textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            .cornerRadius(8)
            Spacer()
        }
        .padding().frame(width: 760, height: 520)
        .onAppear { refreshLog() }
        .onChange(of: selectedLogType) { refreshLog() }
    }

    private var currentLogPath: String {
        selectedLogType == .error ? domain.errorLogPath : domain.accessLogPath
    }
    private func refreshLog() {
        logContent = selectedLogType == .error
            ? domainManager.readErrorLog(for: domain)
            : domainManager.readAccessLog(for: domain)
    }
    private func openCurrentLog() {
        if selectedLogType == .error { domainManager.openErrorLog(domain) }
        else                         { domainManager.openAccessLog(domain) }
    }
}

// MARK: - Add Domain Sheet

struct AddDomainSheet: View {
    @EnvironmentObject var loc: Localizer

    @EnvironmentObject var domainManager: DomainManager
    @EnvironmentObject var serviceManager: ServiceManager
    @Environment(\.dismiss) var dismiss

    @State private var domainName:               String = ""
    @State private var selectedPlatform:         Platform = .php
    @State private var selectedWebServer:        WebServer = .apache
    @State private var selectedPHPVersion:       PHPVersion = .v83
    @State private var selectedNodeVersion:      NodeVersion = .v20
    @State private var selectedPythonVersion:    PythonVersion = .v312
    @State private var selectedPythonFramework:  PythonFramework = .fastapi
    @State private var selectedDotNetVersion:    DotNetVersion = .v8
    @State private var sslEnabled:               Bool = true
    @State private var redirectHTTPToHTTPS:      Bool = true
    @State private var isCreating:               Bool = false
    @State private var isCAInstalled:            Bool = false

    @State private var customPort:    String = ""
    /// Başlatmadan önce çalışması gereken servisler (id seti)
    @State private var dependencySelection: Set<String> = []

    /// Alan adındaki sorun (nil = geçerli). Boş alan zaten Oluştur'u kapalı tutar; burada
    /// geçersiz karakter ve mükerrer ad, Oluştur'a basılmadan ÖNCE satır altında açıklanır —
    /// aksi halde hata yalnızca konsola düşer ve sheet sebepsiz açık kalmış görünürdü.
    private var nameIssue: String? {
        let t = domainName.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return nil }
        if !DomainManager.isValidDomainName(t) { return loc.t("dom.nameInvalid") }
        // addDomain ile aynı ölçüt: harf duyarsız — domains.json dışarıdan (izleyici yolu)
        // karışık harfli bir adla doldurulmuş olabilir.
        if domainManager.domains.contains(where: { $0.name.lowercased() == t }) { return loc.t("dom.nameTaken") }
        return nil
    }

    /// Apache/Nginx'in kullandığı portlar — uygulama bunlara bağlanamaz.
    private var reservedWebServerPorts: Set<Int> {
        [serviceManager.currentApacheHTTPPort(), serviceManager.currentApacheHTTPSPort(),
         serviceManager.currentNginxHTTPPort(), serviceManager.currentNginxHTTPSPort()]
    }

    /// Elle girilen porttaki sorun (nil = sorun yok). Boş alan sorun değildir: varsayılan
    /// port kullanılır. Aralık dışı port uygulamayı hiç bağlanamaz hale getirir; başka bir
    /// domainin portu ise ikinci uygulamayı sessizce 502'ye düşürür.
    private var customPortIssue: String? {
        let t = customPort.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        guard let p = Int(t), (1...65535).contains(p) else { return loc.t("dom.portRange") }
        if domainManager.isPortInUse(p) { return loc.t("dom.portInUse") }
        if reservedWebServerPorts.contains(p) { return loc.t("dom.portReserved") }
        return nil
    }

    /// Yalnızca GEÇERLİ ve boşta olan elle girilmiş port; aksi halde nil (varsayılan kullanılır).
    private var validCustomPort: Int? {
        guard customPortIssue == nil,
              let p = Int(customPort.trimmingCharacters(in: .whitespaces)),
              (1...65535).contains(p) else { return nil }
        return p
    }
    @State private var appCommand:    String = ""
    @State private var buildCommand:  String = ""
    @State private var envPairs:      [EnvPair] = []
    @State private var customDocRoot: String = ""

    /// Document root sorunu (nil = sorun yok). Boş = varsayılan kullanılır. Bu değer
    /// Apache/nginx direktiflerine gömüldüğünden Edit sheet'teki ile aynı doğrulama.
    private var docRootIssue: String? {
        let t = customDocRoot.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return DomainManager.isValidDocumentRoot(t) ? nil : loc.t("dom.docRootInvalid")
    }

    @State private var showLoadAlert: Bool   = false
    @State private var loadedName:    String = ""

    // Python ayarları
    @State private var pythonUseVenv:    Bool   = true
    // Proxy ayarları
    @State private var websocketEnabled: Bool   = true
    @State private var http2Enabled:     Bool   = false
    @State private var sseEnabled:       Bool   = false
    @State private var grpcEnabled:      Bool   = false
    @State private var maxBodySizeText:  String = ""

    private var isAppPlatform: Bool {
        [Platform.nodejs, .python, .dotnet].contains(selectedPlatform)
    }

    private func defaultPort(for p: Platform) -> Int {
        domainManager.nextAvailablePort(for: p) ?? (p == .nodejs ? 3001 : p == .python ? 8001 : 5001)
    }
    private func defaultAppCmd(for p: Platform) -> String {
        switch p {
        case .nodejs: return "npm start"
        // {PORT} şablon olarak bırakılır — çalışma anında güncel portla değiştirilir.
        // Port sonradan değiştirilse bile komut doğru porta gider (502 önlenir).
        case .python: return selectedPythonFramework.serverCommand
        case .dotnet: return "dotnet run --no-launch-profile"
        default:      return ""
        }
    }
    private func defaultBuildCmd(for p: Platform) -> String {
        switch p {
        case .nodejs: return "npm install"
        case .python: return "pip install -r requirements.txt"
        case .dotnet: return "dotnet restore"
        default:      return ""
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(loc.t("dom.newDomain")).font(.headline)
                Spacer()
                Button(loc.t("common.cancel")) { dismiss() }.buttonStyle(.borderless)
            }
            .padding()

            Divider()

            Form {
                // Domain
                Section(loc.t("dom.fieldName")) {
                    TextField("", text: $domainName).labelsHidden()
                    if let issue = nameIssue {
                        Text(issue).font(.caption).foregroundColor(.red)
                    } else {
                        Text(loc.t("dom.example")).font(.caption).foregroundColor(.secondary)
                    }
                }

                // Document Root
                Section("Document Root") {
                    HStack(spacing: 8) {
                        TextField(text: $customDocRoot, prompt: Text(loc.t("dom.docRootPh"))) {
                            Text("Document Root")
                        }
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        Button(loc.t("dom.select")) { chooseDocumentRoot() }
                        if !customDocRoot.isEmpty {
                            Button(action: { customDocRoot = "" }) {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(loc.t("dom.resetDefault"))
                        }
                    }
                    Text(customDocRoot.trimmingCharacters(in: .whitespaces).isEmpty
                         ? String(format: loc.t("dom.defaultVal"), "\(AppSettings.load().sitesPath)/\(domainName.trimmingCharacters(in: .whitespaces).isEmpty ? "<domain>" : domainName)")
                         : loc.t("dom.docRootHint"))
                        .font(.caption).foregroundColor(.secondary)
                        .lineLimit(2)
                }

                // Platform
                Section("Platform") {
                    Picker("Platform", selection: $selectedPlatform) {
                        ForEach(Platform.allCases) { p in Label(p.displayName, systemImage: platformIcon(p)).tag(p) }
                    }
                    .pickerStyle(.radioGroup)
                    .onChange(of: selectedPlatform) {
                        selectedWebServer = WebServer.recommended(for: selectedPlatform)
                        let port = defaultPort(for: selectedPlatform)
                        customPort   = isAppPlatform ? "\(port)" : ""
                        appCommand   = defaultAppCmd(for: selectedPlatform)
                        buildCommand = defaultBuildCmd(for: selectedPlatform)
                        envPairs     = []
                        // Proxy ayarlarını resetle
                        websocketEnabled = true
                        http2Enabled     = false
                        sseEnabled       = false
                        grpcEnabled      = false
                        maxBodySizeText  = ""
                        // Kurulu bir sürüme varsayılan (kurulu olmayan seçili kalmasın)
                        defaultToInstalledVersions()
                    }
                    versionPicker
                }

                // Uygulama Ayarları — backend platformlar
                if isAppPlatform {
                    Section(loc.t("dom.appSettings")) {
                        // Port
                        HStack(spacing: 10) {
                            Text("Port").frame(width: 40, alignment: .leading)
                            TextField("", text: $customPort)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                            if let issue = customPortIssue {
                                Text(issue).font(.caption).foregroundColor(.red)
                            } else {
                                Text(loc.t("dom.appPortHint"))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                        }

                        // Başlatma
                        VStack(alignment: .leading, spacing: 4) {
                            Text(loc.t("dom.startCmd")).font(.subheadline)
                            TextField("", text: $appCommand)
                                .labelsHidden().textFieldStyle(.roundedBorder)
                            Text(String(format: loc.t("dom.startCmdDefault"), defaultAppCmd(for: selectedPlatform)))
                                .font(.caption2).foregroundColor(.secondary)
                            if selectedPlatform == .python {
                                Text(loc.t("dom.portTemplate"))
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)

                        // Derleme
                        VStack(alignment: .leading, spacing: 4) {
                            Text(loc.t("dom.buildInstall")).font(.subheadline)
                            TextField("", text: $buildCommand)
                                .labelsHidden().textFieldStyle(.roundedBorder)
                            Text(String(format: loc.t("dom.buildRunHint"), defaultBuildCmd(for: selectedPlatform)))
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }

                    // ENV
                    Section {
                        EnvVarsEditorView(pairs: $envPairs)
                        Text("NODE_ENV ve PORT otomatik eklenir.")
                            .font(.caption2).foregroundColor(.secondary)
                    } header: {
                        HStack {
                            Text(loc.t("dom.env.title"))
                            Spacer()
                            Button(action: loadConfigFromFile) {
                                Label(loc.t("dom.jsonLoad"), systemImage: "square.and.arrow.down").font(.caption)
                            }.buttonStyle(.borderless)
                        }
                    }

                    // Python Ayarları
                    if selectedPlatform == .python {
                        Section(loc.t("dom.python.settings")) {
                            Toggle(isOn: $pythonUseVenv) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(loc.t("dom.python.useVenv"))
                                    Text(loc.t("dom.venvAutoDetect"))
                                        .font(.caption).foregroundColor(.secondary)
                                }
                            }
                            Text(loc.t("dom.python.venvHint"))
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }

                    // Proxy Ayarları
                    Section(loc.t("dom.proxy")) {
                        addProxySettingsSection
                    }
                }

                // Web Sunucusu
                dependenciesSection

                Section(loc.t("dom.webServerLabel")) {
                    Picker("Web Sunucusu", selection: $selectedWebServer) {
                        ForEach(WebServer.allCases) { ws in Label(ws.displayName, systemImage: ws.sfSymbol).tag(ws) }
                    }
                    .pickerStyle(.radioGroup)
                    HStack(spacing: 6) {
                        Image(systemName: selectedWebServer.sfSymbol).foregroundColor(selectedWebServer.color)
                        Text(selectedWebServer == .apache
                             ? "HTTP :80  ·  HTTPS :443"
                             : loc.t("dom.portsNginxHint"))
                        .font(.caption).foregroundColor(.secondary)
                    }
                }

                // SSL
                Section("SSL") {
                    Toggle(loc.t("dom.createSSLTitle"), isOn: $sslEnabled)
                    if sslEnabled {
                        Toggle(isOn: $redirectHTTPToHTTPS) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loc.t("dom.httpsRedirect"))
                                Text(redirectHTTPToHTTPS
                                     ? loc.t("dom.redirectOn2")
                                     : loc.t("dom.redirectOff"))
                                .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    if sslEnabled && !isCAInstalled {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(loc.t("dom.mkcertMissing")).font(.caption).fontWeight(.semibold).foregroundColor(.orange)
                                Text(loc.t("dom.sslWarn"))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .padding(8).background(Color.orange.opacity(0.1)).cornerRadius(6)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button(loc.t("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isCreating ? loc.t("dom.creating") : loc.t("common.create")) { createDomain() }
                    .buttonStyle(.borderedProminent)
                    // Geçersiz ENV anahtarı start.sh'a hiç yazılmaz — oluşturmayı engelle
                    .disabled(domainName.trimmingCharacters(in: .whitespaces).isEmpty || nameIssue != nil || isCreating || customPortIssue != nil || docRootIssue != nil
                              || EnvPair.hasInvalid(envPairs))
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 540, height: 780)
        .onAppear {
            checkCAStatus()
            // Başlangıç değerleri — PHP/Static için boş
            customPort   = ""
            appCommand   = ""
            buildCommand = ""
            // Açılışta kurulu bir sürüm seçili olsun
            defaultToInstalledVersions()
        }
        .onChange(of: sslEnabled) { _, on in redirectHTTPToHTTPS = on }
        .onChange(of: selectedPythonFramework) {
            if selectedPlatform == .python { appCommand = defaultAppCmd(for: .python) }
        }
        .alert(loc.t("dom.configLoaded"), isPresented: $showLoadAlert) {
            Button(loc.t("common.ok"), role: .cancel) { }
        } message: {
            Text(String(format: loc.t("dom.loadedOkPlain"), loadedName))
        }
    }

    // MARK: - CA Check
    private func checkCAStatus() {
        Task {
            let r = await Shell.runAsync(PathConfig.mkcert, arguments: ["-CAROOT"])
            if r.isSuccess {
                let path = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                isCAInstalled = FileManager.default.fileExists(atPath: "\(path)/rootCA.pem")
            } else {
                isCAInstalled = false
            }
        }
    }

    // MARK: - Version Picker
    /// Sürüm etiketi — kurulu değilse "— kurulu değil" ekler ki kullanıcı hangisinin
    /// kurulu olduğunu görüp seçebilsin.
    private func versionLabel(_ display: String, installed: Bool) -> String {
        installed ? "\(display)  ✓" : String(format: loc.t("dom.versionNotInstalled"), display)
    }

    @ViewBuilder
    private var versionPicker: some View {
        switch selectedPlatform {
        case .php:
            Picker("PHP Versiyonu", selection: $selectedPHPVersion) {
                ForEach(PHPVersion.allCases) { v in Text(versionLabel(v.displayName, installed: v.isInstalled)).tag(v) }
            }
        case .nodejs:
            Picker("Node.js Versiyonu", selection: $selectedNodeVersion) {
                ForEach(NodeVersion.allCases) { v in Text(versionLabel(v.displayName, installed: v.isInstalled)).tag(v) }
            }
        case .python:
            Picker("Python Versiyonu", selection: $selectedPythonVersion) {
                ForEach(PythonVersion.allCases) { v in Text(versionLabel(v.displayName, installed: v.isInstalled)).tag(v) }
            }
            Picker("Framework", selection: $selectedPythonFramework) {
                ForEach(PythonFramework.allCases) { f in Text(f.displayName).tag(f) }
            }
        case .dotnet:
            Picker(".NET Versiyonu", selection: $selectedDotNetVersion) {
                ForEach(DotNetVersion.allCases) { v in Text(versionLabel(v.displayName, installed: v.isInstalled)).tag(v) }
            }
        case .static_:
            Text(loc.t("dom.staticNoVer")).foregroundColor(.secondary)
        }
    }

    /// Seçili sürüm kurulu değilse, kurulu bir sürüme (en yüksek) varsayılan olarak geçer.
    private func defaultToInstalledVersions() {
        switch selectedPlatform {
        case .php:
            if !selectedPHPVersion.isInstalled,
               let v = PHPVersion.allCases.last(where: { $0.isInstalled }) { selectedPHPVersion = v }
        case .nodejs:
            if !selectedNodeVersion.isInstalled,
               let v = NodeVersion.allCases.last(where: { $0.isInstalled }) { selectedNodeVersion = v }
        case .python:
            if !selectedPythonVersion.isInstalled,
               let v = PythonVersion.allCases.last(where: { $0.isInstalled }) { selectedPythonVersion = v }
        case .dotnet:
            if !selectedDotNetVersion.isInstalled,
               let v = DotNetVersion.allCases.last(where: { $0.isInstalled }) { selectedDotNetVersion = v }
        case .static_:
            break
        }
    }

    // MARK: - Document Root Seçimi
    private func chooseDocumentRoot() {
        let panel = NSOpenPanel()
        panel.title = loc.t("dom.selectDocRoot")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if !customDocRoot.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: customDocRoot)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        customDocRoot = url.path
    }

    // MARK: - JSON Load
    private func loadConfigFromFile() {
        let panel = NSOpenPanel()
        panel.title = loc.t("dom.selectHYConfig")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let cfg: BRAMPPConfig
        do {
            cfg = try BRAMPPConfig.readThrowing(at: url.path)
        } catch {
            domainManager.log(key: "log.dom.jsonLoadFailed",
                              args: [error.localizedDescription], type: .error)
            loadedName = "❌ \(url.lastPathComponent) — \(error.localizedDescription)"
            showLoadAlert = true
            return
        }
        if let cmd = cfg.appCommand,   !cmd.isEmpty { appCommand   = cmd }
        if let cmd = cfg.buildCommand, !cmd.isEmpty { buildCommand = cmd }
        if let p   = cfg.port,          p > 0       { customPort   = "\(p)" }
        if let env = cfg.envVars,      !env.isEmpty {
            var dict = Dictionary(envPairs.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
            env.forEach { dict[$0.key] = $0.value }
            envPairs = dict.map { EnvPair(key: $0.key, value: $0.value) }.sorted { $0.key < $1.key }
        }
        loadedName = url.lastPathComponent; showLoadAlert = true
    }

    // MARK: - Create

    // MARK: Bağımlılıklar

    /// Seçilebilir bağımlılık adayları: kurulu veritabanı + önbellek servisleri.
    private var dependencyCandidates: [Service] {
        serviceManager.services.filter {
            // Kurulu DB/önbellek servisleri + KAYITLI seçimde geçenler (kaldırılmış olsa bile).
            // İkincisi olmasa, kullanıcı brew'dan kaldırdığı bir bağımlılığı listede
            // göremez ve seçimden ASLA çıkaramazdı.
            (($0.category == .database || $0.category == .cache) && $0.status != .notInstalled)
                || dependencySelection.contains($0.id)
        }
    }

    private var dependenciesSection: some View {
        Section(loc.t("dom.dependencies")) {
            if dependencyCandidates.isEmpty {
                Text(loc.t("dom.depsNone"))
                    .font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(dependencyCandidates, id: \.id) { svc in
                    Toggle(isOn: Binding(
                        get: { dependencySelection.contains(svc.id) },
                        set: { on in
                            if on { dependencySelection.insert(svc.id) }
                            else  { dependencySelection.remove(svc.id) }
                        }
                    )) {
                        HStack(spacing: 6) {
                            Text(svc.name)
                            Circle().fill(svc.status.color).frame(width: 7, height: 7)
                            Text(svc.status.displayName)
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                Text(loc.t("dom.dependenciesHint"))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func createDomain() {
        guard !isCreating else { return }
        isCreating = true
        // Host adları büyük/küçük harfe DUYARSIZDIR; karışık harfli ad üretmek yalnızca
        // sonradan "case-only rename" gibi kırılgan yollara kapı açar. Baştan normalize et.
        let trimmed = domainName.trimmingCharacters(in: .whitespaces).lowercased()
        let envDict: [String: String]? = {
            let f = envPairs.filter { !$0.key.isEmpty }
            return f.isEmpty ? nil : Dictionary(f.map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
        }()

        var domain: Domain
        switch selectedPlatform {
        case .php:
            domain = .php(name: trimmed, version: selectedPHPVersion, ssl: sslEnabled, webServer: selectedWebServer)
        case .nodejs:
            let port = validCustomPort ?? defaultPort(for: .nodejs)
            domain = .nodejs(name: trimmed, version: selectedNodeVersion,
                             port: port, ssl: sslEnabled, webServer: selectedWebServer,
                             appCommand:   appCommand.isEmpty   ? nil : appCommand,
                             buildCommand: buildCommand.isEmpty ? nil : buildCommand,
                             envVars: envDict)
        case .python:
            let port = validCustomPort ?? defaultPort(for: .python)
            domain = .python(name: trimmed, version: selectedPythonVersion,
                             framework: selectedPythonFramework, port: port,
                             ssl: sslEnabled, webServer: selectedWebServer,
                             useVenv: pythonUseVenv,
                             appCommand:   appCommand.isEmpty   ? nil : appCommand,
                             buildCommand: buildCommand.isEmpty ? nil : buildCommand,
                             envVars: envDict)
        case .dotnet:
            let port = validCustomPort ?? defaultPort(for: .dotnet)
            domain = .dotnet(name: trimmed, version: selectedDotNetVersion,
                             port: port, ssl: sslEnabled, webServer: selectedWebServer,
                             appCommand:   appCommand.isEmpty   ? nil : appCommand,
                             buildCommand: buildCommand.isEmpty ? nil : buildCommand,
                             envVars: envDict)
        case .static_:
            domain = .staticSite(name: trimmed, ssl: sslEnabled, webServer: selectedWebServer)
        }
        domain.redirectHTTPToHTTPS = sslEnabled ? redirectHTTPToHTTPS : false
        domain.serviceDependencies = dependencySelection.isEmpty ? nil : dependencySelection.sorted()
        // Manuel document root
        let rootTrimmed = customDocRoot.trimmingCharacters(in: .whitespaces)
        domain.customDocumentRoot = rootTrimmed.isEmpty ? nil : rootTrimmed
        // Python ayarları
        if selectedPlatform == .python { domain.pythonUseVenv = pythonUseVenv }
        // Proxy ayarları
        domain.websocketEnabled = websocketEnabled
        domain.http2Enabled     = http2Enabled
        domain.sseEnabled       = sseEnabled
        domain.grpcEnabled      = grpcEnabled
        let bodyTrimmed = maxBodySizeText.trimmingCharacters(in: .whitespaces)
        domain.maxBodySize = bodyTrimmed.isEmpty ? nil : bodyTrimmed
        Task {
            let ok = await domainManager.addDomain(domain)
            isCreating = false
            if ok { dismiss() }
        }
    }

    // MARK: - Proxy Settings Section

    @ViewBuilder
    private var addProxySettingsSection: some View {
        let isNginx = selectedWebServer == .nginx

        Toggle(isOn: $websocketEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text(loc.t("dom.websocket"))
                Text("ws:// / wss:// upgrade isteklerini proxy'ye iletir")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .disabled(grpcEnabled)

        Toggle(isOn: $sseEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SSE / Streaming")
                Text(loc.t("dom.sse"))
                    .font(.caption).foregroundColor(.secondary)
            }
        }

        Toggle(isOn: $http2Enabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("HTTP/2")
                Text(isNginx
                     ? loc.t("dom.http2On")
                     : loc.t("dom.http2Nginx"))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .disabled(!isNginx)

        Toggle(isOn: $grpcEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("gRPC Modu")
                Text(isNginx
                     ? loc.t("dom.grpcOn")
                     : loc.t("dom.grpcNginx"))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .disabled(!isNginx)
        .onChange(of: grpcEnabled) { _, enabled in
            if enabled { http2Enabled = true; websocketEnabled = false }
        }
        .onChange(of: selectedWebServer) { _, ws in
            if ws == .apache { http2Enabled = false; grpcEnabled = false }
        }

        HStack(spacing: 10) {
            Text(loc.t("dom.maxSize")).frame(width: 90, alignment: .leading)
            TextField("", text: $maxBodySizeText)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
            Text(loc.t("dom.bodySizePh"))
                .font(.caption).foregroundColor(.secondary)
            Spacer()
        }
        Text(isNginx ? "Nginx: client_max_body_size" : "Apache: LimitRequestBody")
            .font(.caption2).foregroundColor(.secondary)
    }

    private func platformIcon(_ p: Platform) -> String {
        switch p {
        case .php:    return "p.circle"
        case .nodejs: return "n.circle"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .dotnet: return "dot.circle"
        case .static_: return "doc.circle"
        }
    }
}

// MARK: - Localhost Row View

struct LocalhostRowView: View {
    @EnvironmentObject var loc: Localizer

    @EnvironmentObject var serviceManager: ServiceManager

    private var isNginxInstalled:      Bool { PathConfig.isNginxInstalled }
    private var isPhpMyAdminInstalled: Bool { FileHelper.exists(PathConfig.phpmyadminDir) }

    // Portlar her render'da 4 config dosyasını ~7 kez okumasın diye body başında BİR KEZ
    // hesaplanıp aşağıya taşınır (Ports struct). Öncesinde her erişim ayrı dosya okuyordu.
    private struct Ports { let apHTTP, apHTTPS, ngHTTP, ngHTTPS: Int }
    private func resolvePorts() -> Ports {
        Ports(apHTTP:  serviceManager.currentApacheHTTPPort(),
              apHTTPS: serviceManager.currentApacheHTTPSPort(),
              ngHTTP:  serviceManager.currentNginxHTTPPort(),
              ngHTTPS: serviceManager.currentNginxHTTPSPort())
    }

    private func apacheURL(_ port: Int, _ path: String = "") -> URL? {
        let portStr = port == 80 ? "" : ":\(port)"
        return URL(string: "http://localhost\(portStr)\(path)")
    }
    private func nginxURL(_ port: Int, _ path: String = "") -> URL? {
        URL(string: "http://localhost:\(port)\(path)")
    }

    var body: some View {
        let ports = resolvePorts()
        let apacheHTTPPort  = ports.apHTTP
        let apacheHTTPSPort = ports.apHTTPS
        let nginxHTTPPort   = ports.ngHTTP
        let nginxHTTPSPort  = ports.ngHTTPS
        return HStack(spacing: 16) {
            Text("🏠").font(.title).frame(width: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("localhost").font(.headline)
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Image(systemName: "lock.fill").font(.caption).foregroundColor(.green)
                    Text(loc.t("common.default")).font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15)).foregroundColor(.blue).cornerRadius(4)
                }
                HStack(spacing: 8) {
                    Label("Apache", systemImage: "server.rack").font(.caption).foregroundColor(.orange)
                    Text(verbatim: ":\(apacheHTTPPort)  :\(apacheHTTPSPort)").font(.caption).foregroundColor(.secondary)
                    if isNginxInstalled {
                        Divider().frame(height: 12)
                        Label("Nginx", systemImage: "network").font(.caption).foregroundColor(.green)
                        Text(verbatim: ":\(nginxHTTPPort)  :\(nginxHTTPSPort)").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Button(action: { if let u = apacheURL(apacheHTTPPort) { NSWorkspace.shared.open(u) } }) {
                    Image(systemName: "safari").foregroundColor(.orange)
                }.help(Text(verbatim: "Apache: http://localhost:\(apacheHTTPPort)"))

                if isNginxInstalled {
                    Button(action: { if let u = nginxURL(nginxHTTPPort) { NSWorkspace.shared.open(u) } }) {
                        Image(systemName: "safari.fill").foregroundColor(.green)
                    }.help(Text(verbatim: "Nginx: http://localhost:\(nginxHTTPPort)"))
                }

                if isPhpMyAdminInstalled {
                    Button(action: { if let u = apacheURL(apacheHTTPPort, "/phpmyadmin") { NSWorkspace.shared.open(u) } }) {
                        Image(systemName: "tablecells")
                    }.help(Text(verbatim: "phpMyAdmin: http://localhost:\(apacheHTTPPort)/phpmyadmin"))
                }

                Button(action: { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: PathConfig.localhostDir) }) {
                    Image(systemName: "folder")
                }.help(Text(verbatim: "Finder: \(PathConfig.localhostDir)"))
            }
            .buttonStyle(.borderless)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.25), lineWidth: 1))
    }
}

#Preview {
    let store = ConsoleStore()
    DomainsTabView()
        .environmentObject(DomainManager(consoleStore: store))
        .environmentObject(ServiceManager(consoleStore: store))
        .environmentObject(Localizer.shared)
}
