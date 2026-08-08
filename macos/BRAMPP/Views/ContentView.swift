import SwiftUI
import Combine

struct ContentView: View {
    @EnvironmentObject var domainManager: DomainManager
    @EnvironmentObject var serviceManager: ServiceManager
    @EnvironmentObject var phpExtensionManager: PHPExtensionManager
    @EnvironmentObject var consoleStore: ConsoleStore
    @EnvironmentObject var loc: Localizer

    @State private var selectedTab: Tab = .domains
    // Ayarlar → "Konsol panelini göster" ile ortak — header butonu da bunu değiştirir
    @AppStorage("showConsoleOutput") private var showConsole: Bool = true

    enum Tab: String, CaseIterable {
        case domains, services, database, phpExtensions, logs

        /// Yerelleştirme anahtarı
        var l10nKey: String {
            switch self {
            case .domains:       return "tab.domains"
            case .services:      return "tab.services"
            case .database:      return "tab.database"
            case .phpExtensions: return "tab.phpExt"
            case .logs:          return "tab.logs"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            HSplitView {
                tabContent.frame(minWidth: 600)
                if showConsole { ConsoleView().environmentObject(consoleStore).frame(minWidth: 280, maxWidth: 350) }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        // ⌘N hangi sekmede olursa olsun çalışır: önce Alan Adları sekmesine geçilir,
        // sheet'i DomainsTabView bayrak üzerinden açar (o an ekranda değilse bildirimi
        // dinleyemeyeceğinden bayrak gerekli).
        .onReceive(NotificationCenter.default.publisher(for: .showAddDomainSheet)) { _ in
            selectedTab = .domains
            domainManager.pendingOpenAddSheet = true
        }
    }

    private var headerView: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                // Uygulama logosu (SF Symbol yerine) — marka tutarlılığı için başlıkta,
                // menü çubuğunda ve Dock'ta aynı görsel kullanılır.
                Image("AppLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 30, height: 30)
                    .accessibilityLabel("BRAMPP")
                Text("BRAMPP").font(.title2).fontWeight(.semibold)
            }
            Spacer()
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { Text(loc.t($0.l10nKey)).tag($0) }
            }
            .pickerStyle(.segmented).frame(width: 480)
            Spacer()
            HStack(spacing: 12) {
                Button(action: { showConsole.toggle() }) {
                    Image(systemName: showConsole ? "terminal.fill" : "terminal")
                }
                .help(loc.t("console.title"))
                Button(action: { serviceManager.refreshStatus(); domainManager.refreshStatus() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .help(loc.t("cv.refresh"))
                // Yardım sheet'i tek yerden (RootView) yönetilir — menüdeki Yardım ile aynı yol
                Button(action: { NotificationCenter.default.post(name: .showHelpSheet, object: nil) }) {
                    Image(systemName: "questionmark.circle")
                }
                .help(loc.t("common.help"))
            }
            .buttonStyle(.borderless).font(.title3)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .domains:       DomainsTabView()
        case .services:      ServicesTabView()
        case .database:      DatabaseTabView()
        case .phpExtensions: PHPExtensionsTabView()
        case .logs:          LogsTabView()
        }
    }
}

// MARK: - Backup / Restore Sheet

struct BackupRestoreSheet: View {
    @EnvironmentObject var loc: Localizer
    @ObservedObject var manager: BackupRestoreManager
    var onImport: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entryToRestore: BackupRestoreManager.BackupEntry? = nil
    @State private var showRestoreConfirm: Bool = false
    // Silme de geri yükleme kadar yıkıcı: aynı onay deseni uygulanır
    @State private var entryToDelete: BackupRestoreManager.BackupEntry? = nil
    @State private var showDeleteConfirm: Bool = false
    // İşlem sonucu — başarısızlık artık arayüzde YUTULMAZ
    @State private var resultMessage: ResultMessage? = nil

    /// Yedekleme/geri yükleme/silme sonucunu taşıyan uyarı içeriği.
    private struct ResultMessage: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "externaldrive").foregroundColor(.accentColor)
                Text(loc.t("backup.title")).font(.headline)
                Spacer()
                Button(loc.t("common.close")) { dismiss() }
            }
            .padding()

            Divider()

            HStack(spacing: 0) {
                // Yedekler listesi
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(loc.t("backup.list"))
                            .font(.subheadline).fontWeight(.semibold)
                        Spacer()
                        Button(action: { manager.loadBackups() }) {
                            Image(systemName: "arrow.clockwise").font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }

                    if manager.backups.isEmpty {
                        Text(loc.t("backup.none"))
                            .foregroundColor(.secondary)
                            .font(.caption)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    } else {
                        List(manager.backups) { entry in
                            HStack {
                                Image(systemName: "clock")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                                Text(entry.displayName)
                                    .font(.system(.body, design: .monospaced))
                                Spacer()
                                Button(loc.t("backup.restore")) {
                                    entryToRestore = entry
                                    showRestoreConfirm = true
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button(role: .destructive) {
                                    entryToDelete = entry
                                    showDeleteConfirm = true
                                } label: {
                                    Image(systemName: "trash").font(.caption)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .listStyle(.plain)
                    }
                }
                .frame(minWidth: 320)
                .padding()

                Divider()

                // Eylemler
                VStack(alignment: .leading, spacing: 16) {
                    Text(loc.t("backup.actions"))
                        .font(.subheadline).fontWeight(.semibold)

                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(loc.t("backup.create"))
                                .fontWeight(.medium)
                            Text(loc.t("backup.create.desc"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            // Dönüş değeri KULLANILIR: başarısız yedek eskiden sessizce
                            // "alınmış" görünüyordu (klasör listede yok ama uyarı da yok).
                            Button(action: { performBackup() }) {
                                Label(loc.t("cv.backupNow"), systemImage: "externaldrive.badge.plus")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(8)
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(loc.t("backup.exportImport"))
                                .fontWeight(.medium)
                            Text(loc.t("backup.exportImport.desc"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack {
                                Button(action: { manager.exportDomains() }) {
                                    Label(loc.t("cv.export"), systemImage: "square.and.arrow.up")
                                }
                                .buttonStyle(.bordered)
                                Button(action: {
                                    manager.importDomains { onImport() }
                                }) {
                                    Label(loc.t("cv.import"), systemImage: "square.and.arrow.down")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(8)
                    }

                    Spacer()
                }
                .frame(width: 240)
                .padding()
                // Sonuç uyarısı BİLEREK onay uyarılarından farklı bir view'a bağlandı:
                // aynı view'a yığılan birden çok .alert'te ikincisi yutulabiliyor.
                .alert(resultMessage?.title ?? "",
                       isPresented: Binding(get: { resultMessage != nil },
                                            set: { if !$0 { resultMessage = nil } })) {
                    Button(loc.t("common.ok"), role: .cancel) { resultMessage = nil }
                } message: {
                    Text(resultMessage?.text ?? "")
                }
            }
        }
        .frame(width: 620, height: 420)
        .onAppear { manager.loadBackups() }
        .alert(loc.t("backup.confirmTitle"), isPresented: $showRestoreConfirm, presenting: entryToRestore) { entry in
            Button(loc.t("common.cancel"), role: .cancel) { entryToRestore = nil }
            Button(loc.t("backup.restore"), role: .destructive) {
                performRestore(entry)
                entryToRestore = nil
            }
        } message: { entry in
            Text(String(format: loc.t("cv.restoreConfirmFull"), entry.displayName))
        }
        // Silme onayı — geri yüklemeyle AYNI desen. Eskiden tek tık kalıcı siliyordu.
        .alert(loc.t("backup.deleteConfirmTitle"), isPresented: $showDeleteConfirm, presenting: entryToDelete) { entry in
            Button(loc.t("common.cancel"), role: .cancel) { entryToDelete = nil }
            Button(loc.t("common.delete"), role: .destructive) {
                performDelete(entry)
                entryToDelete = nil
            }
        } message: { entry in
            Text(String(format: loc.t("backup.deleteConfirmMsg"), entry.displayName))
        }
    }

    // MARK: - Eylemler (sonuç arayüze YANSITILIR)

    /// Başarıda sessiz — yeni damga soldaki listede ANINDA belirir, bu yeterli geri
    /// bildirimdir. Başarısızlık ise hiçbir iz bırakmadığından mutlaka bildirilir:
    /// eskiden kısmi/başarısız yedek de "alınmış" gibi görünüyordu.
    private func performBackup() {
        guard !manager.createBackup() else { return }
        show(title: loc.t("backup.resultFailTitle"), text: loc.t("backup.createFailMsg"))
    }

    /// Yedeklemenin aksine BAŞARIDA da uyarı gösterilir: geri yüklenen ayarların
    /// tümü ancak yeniden başlatınca geçerli olur, bu bilgi kaçırılmamalı.
    private func performRestore(_ entry: BackupRestoreManager.BackupEntry) {
        let ok = manager.restoreBackup(entry)
        onImport()   // domain listesi her durumda tazelenir (kısmen geri yüklenmiş olabilir)
        if ok {
            show(title: loc.t("backup.resultOkTitle"), text: loc.t("backup.restoreOkMsg"))
        } else {
            show(title: loc.t("backup.resultFailTitle"), text: loc.t("backup.restoreFailMsg"))
        }
    }

    private func performDelete(_ entry: BackupRestoreManager.BackupEntry) {
        guard !manager.deleteBackup(entry) else { return }   // başarıda sessiz — liste zaten güncellenir
        show(title: loc.t("backup.resultFailTitle"), text: loc.t("backup.deleteFailMsg"))
    }

    /// Sonuç uyarısını gösterir. Onay uyarısı KAPANIRKEN ikinci bir uyarı açmak
    /// SwiftUI'da yutulduğundan sunum bir sonraki run loop turuna ertelenir.
    private func show(title: String, text: String) {
        DispatchQueue.main.async {
            resultMessage = ResultMessage(title: title, text: text)
        }
    }
}

// MARK: - ConsoleView

struct ConsoleView: View {
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var consoleStore: ConsoleStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Başlık çubuğu ──────────────────────────────────────────────
            HStack(spacing: 6) {
                Text(loc.t("console.title")).font(.headline)
                Spacer()
                // Tümünü kopyala
                Button {
                    let all = consoleStore.entries
                        .map { "\($0.formattedTime)  \($0.text)" }
                        .joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(all, forType: .string)
                } label: {
                    Image(systemName: "doc.on.clipboard").font(.caption)
                }
                .buttonStyle(.borderless)
                .help(loc.t("cv.copyAllHelp"))
                .disabled(consoleStore.entries.isEmpty)

                // Temizle
                Button(action: { consoleStore.clear() }) {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Konsolu temizle")
                .disabled(consoleStore.entries.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            Divider()

            // ── Log listesi ────────────────────────────────────────────────
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(consoleStore.entries) { entry in
                            HStack(alignment: .top, spacing: 6) {
                                // Saat — solda sabit genişlikte
                                Text(entry.formattedTime)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
                                    .frame(width: 52, alignment: .leading)
                                // Mesaj — türe göre renk. `text` anahtarı GÖSTERİM
                                // anında çözer; dil değişince geçmiş satırlar da döner.
                                Text(entry.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(entryColor(entry.type))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .id(entry.id)
                            .contextMenu {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(entry.text, forType: .string)
                                } label: {
                                    Label(loc.t("cv.copyMessage"), systemImage: "doc.on.clipboard")
                                }
                                Button {
                                    let full = "\(entry.formattedTime)  \(entry.text)"
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(full, forType: .string)
                                } label: {
                                    Label(loc.t("cv.copyWholeLine"), systemImage: "doc.on.doc")
                                }
                            }
                        }
                    }
                    .padding(10)
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: consoleStore.entries.count) {
                    if let last = consoleStore.entries.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func entryColor(_ type: ConsoleEntryType) -> Color {
        switch type {
        case .info:     return Color(NSColor.secondaryLabelColor)  // gri — bilgi
        case .success:  return .green                              // yeşil — başarı
        case .warning:  return .orange                             // turuncu — uyarı
        case .error:    return .red                                // kırmızı — hata
        case .command:  return Color(NSColor.systemBlue)           // mavi — komut girdi/çıktı
        case .progress: return Color(NSColor.systemBlue)           // mavi — brew progress
        }
    }
}
