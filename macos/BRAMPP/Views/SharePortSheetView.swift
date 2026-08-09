import SwiftUI
import AppKit

/// BRAMPP'ta alan adı olarak kayıtlı OLMAYAN bir yerel HTTP portunu paylaşma sayfası.
///
/// Kullanım hâli: `npm run dev` 5173'te ayakta ama proje henüz bir alan adına
/// bağlanmamış ve müşteriye hemen gösterilmesi gerekiyor.
struct SharePortSheetView: View {
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var tunnelManager: TunnelManager
    @Environment(\.dismiss) private var dismiss

    @State private var portText = ""
    @State private var isWorking = false
    @State private var refusal: TunnelManager.PortRefusal?

    private var port: Int? { Int(portText.trimmingCharacters(in: .whitespaces)) }
    private var tunnel: Tunnel? {
        guard let p = port else { return nil }
        return tunnelManager.tunnel(for: TunnelManager.portKey(p))
    }

    private func refusalText(_ r: TunnelManager.PortRefusal) -> String {
        switch r {
        case .outOfRange:            return loc.t("share.port.range")
        case .reservedService(let n): return String(format: loc.t("share.port.reserved"), n)
        case .notListening:          return loc.t("share.port.closed")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title2).foregroundColor(.orange)
                Text(loc.t("share.port.title")).font(.title3.bold())
                Spacer()
            }

            if let t = tunnel, let url = t.publicURL {
                live(url: url)
            } else {
                form
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loc.t("share.port.hint"))
                .font(.callout).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(loc.t("share.port.label"))
                TextField("5173", text: $portText)
                    .frame(width: 90)
                    .onChange(of: portText) { refusal = nil }
            }

            if let r = refusal {
                Label(refusalText(r), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(loc.t("dom.share.warn"))
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(loc.t("common.cancel")) { dismiss() }
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button(loc.t("dom.share.start")) {
                    guard let p = port else { refusal = .outOfRange; return }
                    Task {
                        isWorking = true
                        let ok = await tunnelManager.startPort(p)
                        isWorking = false
                        if !ok { refusal = tunnelManager.lastPortRefusal ?? .notListening }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(port == nil || isWorking)
            }
        }
    }

    private func live(url: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent(loc.t("dom.share.public")) {
                Text(url).font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled).foregroundColor(.orange)
            }
            LabeledContent(loc.t("dom.share.target")) {
                Text("http://127.0.0.1:\(portText)").font(.system(.footnote, design: .monospaced))
            }
            if let qr = ShareSheetView.qrImage(for: url) {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(nsImage: qr).interpolation(.none)
                            .resizable().frame(width: 140, height: 140)
                        Text(loc.t("dom.share.qr")).font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
            HStack {
                Button(loc.t("dom.share.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
                Button(loc.t("common.open")) {
                    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                }
                Spacer()
                Button(loc.t("dom.share.stop"), role: .destructive) {
                    guard let p = port else { return }
                    Task {
                        await tunnelManager.stop(domainName: TunnelManager.portKey(p))
                        dismiss()
                    }
                }
                // Yayını sürdürerek pencereyi kapat.
                Button(loc.t("common.close")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
