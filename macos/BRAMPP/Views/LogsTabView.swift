import SwiftUI
import Combine

struct LogsTabView: View {
    @EnvironmentObject var loc: Localizer
    @State private var selectedLogType: LogType = .apache
    @State private var logContent: String = ""
    @State private var isLoading: Bool = false
    @State private var autoRefresh: Bool = false
    @State private var refreshTimer: Timer?
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
        guard !searchText.isEmpty else { return logContent }
        let lines = logContent.components(separatedBy: "\n")
        let matched = lines.filter { $0.localizedCaseInsensitiveContains(searchText) }
        return matched.joined(separator: "\n")
    }

    private var filteredLineCount: Int {
        guard !filteredContent.isEmpty else { return 0 }
        return filteredContent.components(separatedBy: "\n").count
    }

    private var totalLineCount: Int {
        guard !logContent.isEmpty else { return 0 }
        return logContent.components(separatedBy: "\n").count
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
        .onDisappear { stopAutoRefresh() }
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

            Toggle(loc.t("logs.auto"), isOn: $autoRefresh).fixedSize()
                .toggleStyle(.switch)
                .onChange(of: autoRefresh) { _, on in on ? startAutoRefresh() : stopAutoRefresh() }
                .disabled(!brewOK)

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
            if !logContent.isEmpty {
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
                } else if logContent.isEmpty {
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
            .onChange(of: logContent) { withAnimation { proxy.scrollTo("logEnd", anchor: .bottom) } }
        }
    }

    private func loadLog() {
        guard Shell.isBrewInstalled else { return }
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let path = selectedLogType.path
            let content = FileHelper.exists(path) ? Shell.bash("tail -n 500 '\(path)'").output : "Log bulunamadı: \(path)"
            DispatchQueue.main.async { logContent = content; isLoading = false }
        }
    }

    private func clearLog() {
        Shell.sudo("echo '' > '\(selectedLogType.path)'") { r in
            if r.isUserCancelled { return }
            if r.isSuccess { loadLog() }
        }
    }

    private func openInFinder() {
        let path = selectedLogType.path
        if FileHelper.exists(path) { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
    }

    private func startAutoRefresh() {
        guard Shell.isBrewInstalled else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in loadLog() }
    }
    private func stopAutoRefresh() { refreshTimer?.invalidate(); refreshTimer = nil }
}

#Preview {
    LogsTabView()
        .environmentObject(Localizer.shared)
}
