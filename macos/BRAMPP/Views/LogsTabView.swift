import SwiftUI
import Combine

struct LogsTabView: View {
    @EnvironmentObject var loc: Localizer
    @State private var selectedLogType: LogType = .apache
    /// Log artık çekilmiyor, akıtılıyor — 5 saniyede bir `tail -n 500` yerine
    /// dosya izleyici yalnızca eklenen baytları okur (Core/LogTailer.swift).
    @StateObject private var tailer = LogTailer(maxLines: 3000, initialLines: 500)
    @State private var isLoading: Bool = false
    @State private var searchText: String = ""

    enum LogType: String, CaseIterable {
        case apache = "Apache", apacheError = "Apache Error", phpFpm = "PHP-FPM"
        var path: String {
            switch self {
            case .apache:      return PathConfig.httpdAccessLog
            case .apacheError: return PathConfig.httpdErrorLog
            case .phpFpm:      return "\(PathConfig.brewBase)/var/log/php-fpm.log"
            }
        }
    }

    /// Arama filtresi uygulanmış log içeriği
    private var filteredContent: String {
        guard !searchText.isEmpty else { return tailer.text }
        let lines = tailer.text.components(separatedBy: "\n")
        let matched = lines.filter { $0.localizedCaseInsensitiveContains(searchText) }
        return matched.joined(separator: "\n")
    }

    private var filteredLineCount: Int {
        guard !filteredContent.isEmpty else { return 0 }
        return filteredContent.components(separatedBy: "\n").count
    }

    private var totalLineCount: Int {
        guard !tailer.text.isEmpty else { return 0 }
        return tailer.text.components(separatedBy: "\n").count
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            searchBar
            Divider()
            if !Shell.isBrewInstalled {
                BrewWarningBanner(message: loc.t("logs.needBrew"))
                    .padding()
                Spacer()
            } else {
                logContentView
            }
        }
        .onAppear { if Shell.isBrewInstalled { loadLog() } }
        .onDisappear { tailer.stop() }
    }

    private var toolbar: some View {
        let brewOK = Shell.isBrewInstalled
        return HStack {
            Text(loc.t("logs.title")).font(.headline)
            Spacer()
            Picker("Log", selection: $selectedLogType) {
                ForEach(LogType.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).frame(width: 300)
            .onChange(of: selectedLogType) { loadLog() }
            .disabled(!brewOK)

            // "Otomatik Yenile" anahtarı KALDIRILDI: log artık dosya izleyiciyle
            // canlı akıyor, yenilenecek bir şey yok. Yenile düğmesi izleyiciyi
            // baştan kurar — dosya dışarıdan taşınmışsa işe yarar.
            Button(action: loadLog) { Image(systemName: "arrow.clockwise") }.buttonStyle(.bordered).disabled(!brewOK)
            Button(action: openInFinder) { Image(systemName: "folder") }.buttonStyle(.bordered).disabled(!brewOK)
            Button(action: clearLog) { Image(systemName: "trash") }.buttonStyle(.bordered).disabled(!brewOK)
        }.padding()
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField(loc.t("logs.search"), text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if !tailer.text.isEmpty {
                let countText = searchText.isEmpty
                    ? String(format: loc.t("logs.lineCount"), totalLineCount)
                    : String(format: loc.t("logs.lineCountFiltered"), filteredLineCount, totalLineCount)
                Text(countText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var logContentView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredContent.isEmpty && !searchText.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.title2).foregroundColor(.secondary)
                        Text(String(format: loc.t("logs.noResult"), searchText))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else if tailer.text.isEmpty {
                    EmptyStateView(icon: "doc.text", title: loc.t("logs.empty"))
                } else {
                    Text(filteredContent)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                        .id("logEnd")
                }
            }
            .background(Color(NSColor.textBackgroundColor))
            .onChange(of: tailer.text) { withAnimation { proxy.scrollTo("logEnd", anchor: .bottom) } }
        }
    }

    /// Seçili log dosyasını izlemeye başlar (tür değişince yeniden çağrılır).
    private func loadLog() {
        guard Shell.isBrewInstalled else { return }
        let path = selectedLogType.path
        tailer.start(path: path, placeholder: "Log bulunamadı: \(path)")
    }

    private func clearLog() {
        Shell.sudo("echo '' > '\(selectedLogType.path)'") { r in
            if r.isUserCancelled { return }
            if r.isSuccess { tailer.reset() }
        }
    }

    private func openInFinder() {
        let path = selectedLogType.path
        if FileHelper.exists(path) { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
    }
}

#Preview {
    LogsTabView()
        .environmentObject(Localizer.shared)
}
