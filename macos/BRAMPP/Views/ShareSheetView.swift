import SwiftUI
import CoreImage.CIFilterBuiltins
import AppKit

/// Bir alan adını Cloudflare Quick Tunnel ile internete açma sayfası.
///
/// Sayfanın ilk ekranı KASITLI olarak bir onay ekranıdır: paylaşım düğmesine basmadan
/// önce kullanıcı neyin herkese açık olacağını okur. Geliştirme siteleri çoğu zaman
/// kimlik doğrulaması olmadan çalışır; "paylaş" düğmesinin bedeli görünür olmalı.
struct ShareSheetView: View {
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var tunnelManager: TunnelManager
    @Environment(\.dismiss) private var dismiss

    let domain: Domain

    @State private var isWorking = false
    @State private var isInstalling = false

    private var tunnel: Tunnel? { tunnelManager.tunnel(for: domain.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title2).foregroundColor(.orange)
                Text(loc.t("dom.share.title")).font(.title3.bold())
                Spacer()
            }

            if !TunnelManager.isCloudflaredInstalled {
                notInstalled
            } else if let t = tunnel, let url = t.publicURL {
                live(url: url)
            } else if isWorking || tunnel?.state == .starting {
                starting
            } else {
                consent
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    // MARK: - Durumlar

    private var consent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loc.t("dom.share.warn"))
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

            LabeledContent(loc.t("dom.share.target")) {
                Text(TunnelManager.origin(for: domain)).font(.system(.footnote, design: .monospaced))
            }

            HStack {
                Button(loc.t("common.cancel")) { dismiss() }
                Spacer()
                Button(loc.t("dom.share.start")) {
                    Task {
                        isWorking = true
                        await tunnelManager.start(domain: domain)
                        isWorking = false
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var starting: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(loc.t("dom.share.starting")).foregroundColor(.secondary)
            Spacer()
            Button(loc.t("common.cancel")) {
                Task { await tunnelManager.stop(domainName: domain.name); dismiss() }
            }
        }
        .frame(height: 120)
    }

    private func live(url: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent(loc.t("dom.share.public")) {
                Text(url).font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled).foregroundColor(.orange)
            }
            LabeledContent(loc.t("dom.share.target")) {
                Text(TunnelManager.origin(for: domain)).font(.system(.footnote, design: .monospaced))
            }

            if let qr = Self.qrImage(for: url) {
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
                    Task { await tunnelManager.stop(domainName: domain.name); dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var notInstalled: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loc.t("dom.share.needsCf")).foregroundColor(.secondary)
            Text("brew install cloudflared").font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
            HStack {
                Button(loc.t("common.cancel")) { dismiss() }
                Spacer()
                Button(isInstalling ? loc.t("dom.share.starting") : loc.t("dom.share.install")) {
                    Task {
                        isInstalling = true
                        _ = await Shell.bashAsync("\(PathConfig.brew) install cloudflared")
                        isInstalling = false
                    }
                }
                .disabled(isInstalling)
            }
        }
    }

    // MARK: - QR

    /// Adresi QR koduna çevirir — telefondan denemek için. CoreImage sistemde var,
    /// ek bağımlılık getirmez.
    static func qrImage(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        guard let ci = filter.outputImage else { return nil }
        // Üretilen görüntü ~25×25 piksel; ekranda bulanmaması için ölçeklenir.
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
