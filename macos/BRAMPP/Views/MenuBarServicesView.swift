import SwiftUI

// MARK: - MenuBarServicesView

struct MenuBarServicesView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var serviceManager: ServiceManager
    @EnvironmentObject var tunnelManager: TunnelManager
    @EnvironmentObject var loc: Localizer

    /// Ana pencere hiç kalmadığında WindowGroup sahnesini yeniden oluşturmak için.
    @Environment(\.openWindow) private var openWindow

    private var visibleServices: [Service] {
        serviceManager.services.filter {
            $0.canToggle &&
            ($0.status == .running || $0.status == .stopped)
        }
    }

    private var runningCount: Int { visibleServices.filter { $0.status == .running  }.count }
    private var stoppedCount: Int { visibleServices.filter { $0.status == .stopped }.count }
    private var isChecking: Bool  { !serviceManager.hasRunFullCheck }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            serviceListView
            Divider()
            footerView
        }
        .frame(width: 320)
        .onAppear {
            if appState.isSetupCompleted { serviceManager.refreshStatus() }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(alignment: .center) {
            Text("BRAMPP")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.primary)
            Spacer()
            headerStatusView
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var headerStatusView: some View {
        if !appState.canManageServices {
            EmptyView()   // liste zaten uyarıyı gösteriyor; başlıkta sonsuz spinner olmasın
        } else if isChecking {
            HStack(spacing: 5) {
                ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                Text(loc.t("menu.checking"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        } else if visibleServices.isEmpty {
            Text(loc.t("menu.noServices"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        } else {
            Text(statusSummaryText)
                .font(.system(size: 11, weight: .semibold))
        }
    }

    private var statusSummaryText: AttributedString {
        var result = AttributedString("")
        var running = AttributedString("\(runningCount) \(loc.t("menu.running"))")
        running.foregroundColor = .green
        result += running
        if stoppedCount > 0 {
            var sep = AttributedString("  ·  ")
            sep.foregroundColor = .init(.secondaryLabelColor)
            var stopped = AttributedString("\(stoppedCount) \(loc.t("menu.stopped"))")
            stopped.foregroundColor = .red
            result += sep + stopped
        }
        return result
    }

    // MARK: - Service List

    @ViewBuilder
    private var serviceListView: some View {
        // ÖNCE kullanılabilirlik: brew yok / kurulum bitmemişse hasRunFullCheck hiç true
        // olmaz ve "isChecking" sonsuza dek spinner gösterirdi — uyarı hiç görünmezdi.
        if !appState.canManageServices {
            unavailableView
        } else if isChecking {
            VStack(spacing: 10) {
                ProgressView()
                Text(loc.t("menu.loadingStatus"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else if visibleServices.isEmpty {
            emptyView
        } else {
            // Yükseklik: her satır 44px + 1px divider + bulk buttons (45px)
            // Maksimum ~9 satır göster, sonrası scroll
            let listHeight = min(CGFloat(visibleServices.count) * 45 + 45, 420)
            ScrollView {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Button(action: { serviceManager.startAll() }) {
                            Label(loc.t("menu.startAll"), systemImage: "play.fill")
                                .font(.system(size: 11, weight: .medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(stoppedCount == 0)

                        Button(action: { serviceManager.stopAll() }) {
                            Label(loc.t("menu.stopAll"), systemImage: "stop.fill")
                                .font(.system(size: 11, weight: .medium))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(runningCount == 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)

                    Divider()

                    ForEach(Array(visibleServices.enumerated()), id: \.element.id) { index, service in
                        MenuBarServiceRowView(service: service)
                        if index < visibleServices.count - 1 {
                            Divider().padding(.leading, 54)
                        }
                    }
                }
            }
            .frame(height: listHeight)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 26))
                .foregroundColor(.secondary.opacity(0.5))
            Text(loc.t("menu.noServices"))
                .font(.system(size: 12, weight: .medium))
            Text(loc.t("menu.installHint"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Button(loc.t("menu.openMain")) { openMainWindow() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var unavailableView: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(loc.t("menu.unavailable"))
                    .font(.system(size: 12, weight: .semibold))
                Text(!Shell.isBrewInstalled
                     ? loc.t("menu.noBrew")
                     : !appState.isSetupCompleted ? loc.t("menu.setupIncomplete") : loc.t("menu.disabled"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    // MARK: - Footer

    private var footerView: some View {
        VStack(spacing: 0) {
            SettingsLink {
                footerRowLabel(icon: "gearshape", label: loc.t("common.settings"), shortcut: "⌘,", tint: nil)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                NSApp.setActivationPolicy(.regular)
                // Popover buton eyleminden SONRA kapanır; aynı turdaki activate
                // yutulur ve Ayarlar penceresi arkada açılır.
                DispatchQueue.main.async {
                    if NSApp.isHidden { NSApp.unhide(nil) }
                    NSApp.activate(ignoringOtherApps: true)
                }
            })

            // Etkin tünel varsa menüde GÖRÜNÜR olmalı: kullanıcı ana pencereyi
            // açmadan da sitesinin internete açık olduğunu görebilmeli ve tek
            // tıkla kapatabilmeli.
            if tunnelManager.activeCount > 0 {
                Divider()
                footerRow(icon: "antenna.radiowaves.left.and.right",
                          label: loc.t("menu.stopAllShares"),
                          shortcut: "\(tunnelManager.activeCount)",
                          tint: .orange,
                          action: { Task { await tunnelManager.stopAll() } })
            }

            Divider()
            footerRow(icon: "macwindow", label: loc.t("menu.openMain"), shortcut: nil,  tint: nil,  action: openMainWindow)
            Divider()
            footerRow(icon: "power",      label: loc.t("menu.quit"),  shortcut: "⌘Q", tint: .red, action: quitApp)
        }
    }

    private func footerRowLabel(icon: String, label: String, shortcut: String?, tint: Color?) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(tint ?? .secondary)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(tint ?? .primary)
            Spacer()
            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func footerRow(icon: String, label: String, shortcut: String?, tint: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            footerRowLabel(icon: icon, label: label, shortcut: shortcut, tint: tint)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func openMainWindow() {
        // Tüm mantık AppDelegate'te tek yerde: popover'ın kapanmasını bekleyen
        // erteleme, unhide, aktivasyon ve pencere hiç yoksa yeniden oluşturma.
        BRAMPPAppDelegate.shared?.presentMainWindow {
            openWindow(id: BRAMPPApp.mainWindowID)
        }
    }

    private func quitApp() {
        // "Kapanırken servisleri durdur" AYARINA uyulur:
        //   açık  → animasyonlu durdurup çık (satırlar "Durduruluyor..." gösterir)
        //   kapalı → servislere dokunmadan çık
        if AppSettings.load().autoStopOnQuit {
            serviceManager.stopAllAndQuit()
        } else {
            BRAMPPAppDelegate.shared?.realQuit(stopServices: false) ?? NSApp.terminate(nil)
        }
    }
}

// MARK: - MenuBarServiceRowView

struct MenuBarServiceRowView: View {
    @EnvironmentObject var serviceManager: ServiceManager
    @EnvironmentObject var loc: Localizer
    let service: Service

    private var dotColor: Color {
        if service.isStarting { return .orange }
        if service.isStopping { return .red }
        switch service.status {
        case .running: return .green
        case .stopped: return .red
        default:       return .gray
        }
    }

    private var statusText: String {
        if service.isStarting { return loc.t("svc.starting") + "…" }
        if service.isStopping { return loc.t("svc.stopping") + "…" }
        switch service.status {
        case .running: return loc.t("svc.running") + (service.port != nil ? "  \(service.portDisplay)" : "")
        case .stopped: return loc.t("svc.stoppedShort")
        default:       return "–"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {

            // ── Durum noktası ──────────────────────────────────────────
            ZStack {
                Circle()
                    .fill(dotColor.opacity(0.15))
                    .frame(width: 30, height: 30)
                if service.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(service.isStopping ? .red : .orange)
                        .frame(width: 14, height: 14)
                } else {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 11, height: 11)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)

            // ── Servis adı ─────────────────────────────────────────────
            Text(service.name)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            // ── Durum + port (sağa dayalı) ─────────────────────────────
            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(dotColor)
                .lineLimit(1)

            // ── Aksiyon butonları ──────────────────────────────────────
            Group {
                if service.isLoading || service.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(service.isStopping ? .red : (service.isStarting ? .orange : nil))
                        .frame(width: 70, height: 44)
                } else if service.status == .running {
                    HStack(spacing: 4) {
                        rowBtn("stop.fill",       .red,         loc.t("svc.stop"))    { serviceManager.stopService(service) }
                        rowBtn("arrow.clockwise", .accentColor, loc.t("svc.restart")) { serviceManager.restartService(service) }
                    }
                    .padding(.leading, 8)
                } else if service.status == .stopped {
                    HStack(spacing: 4) {
                        rowBtn("play.fill", .green, loc.t("svc.start")) { serviceManager.startService(service) }
                        Color.clear.frame(width: 28, height: 28)
                    }
                    .padding(.leading, 8)
                } else {
                    Color.clear.frame(width: 70, height: 44)
                }
            }
            .padding(.trailing, 14)
        }
        .frame(height: 44)
        .contentShape(Rectangle())
    }

    private func rowBtn(_ icon: String, _ color: Color, _ tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(color.opacity(0.13))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(color)
            }
        }
        .buttonStyle(.plain)
        .help(tip)
    }
}

// MARK: - Preview

#Preview {
    let state = AppState()
    MenuBarServicesView()
        .environmentObject(state)
        .environmentObject(state.serviceManager)
        .environmentObject(Localizer.shared)
}
