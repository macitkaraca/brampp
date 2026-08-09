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
    /// Önkoşul denetimi: sayfa açılır açılmaz koşar, düğme buna göre kilitlenir.
    @State private var block: TunnelManager.ShareBlock?
    @State private var isChecking = true
    @State private var copied = false

    private var tunnel: Tunnel? { tunnelManager.tunnel(for: domain.name) }

    /// Engel nedeninin okunur karşılığı.
    private func blockText(_ b: TunnelManager.ShareBlock) -> String {
        switch b {
        case .domainDisabled:        return loc.t("dom.share.blockDisabled")
        case .webServerDown(let n):  return String(format: loc.t("dom.share.blockServer"), n)
        case .appDown:               return loc.t("dom.share.blockApp")
        }
    }

    private func recheck() async {
        isChecking = true
        block = await TunnelManager.shareBlockReason(for: domain)
        isChecking = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

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

    /// Başlık — yayın durumunu rozetle gösterir, gövdeyi okumadan anlaşılsın.
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: isLive ? "antenna.radiowaves.left.and.right"
                                     : "antenna.radiowaves.left.and.right.slash")
                .font(.title2)
                .foregroundColor(isLive ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(loc.t("dom.share.title")).font(.title3.bold())
                Text(domain.name).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if isLive {
                Text(loc.t("dom.share.badgeLive"))
                    .font(.caption2.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.green.opacity(0.18))
                    .foregroundColor(.green)
                    .clipShape(Capsule())
            }
        }
    }

    private var isLive: Bool { tunnel?.publicURL != nil }

    // MARK: - Durumlar

    private var consent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let b = block {
                // Çalışmayan siteyi paylaşmak ziyaretçiye boş bir adres verir; bu,
                // bağlantıyı gönderdikten sonra fark edilen sessiz bir hatadır.
                VStack(alignment: .leading, spacing: 8) {
                    Label(loc.t("dom.share.blocked"), systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.bold()).foregroundColor(.orange)
                    Text(blockText(b)).font(.callout).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(Color.orange.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Text(loc.t("dom.share.warn"))
                    .font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Text(loc.t("dom.share.target")).font(.caption).foregroundColor(.secondary)
                Text(TunnelManager.displayOrigin(for: domain))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            Divider()

            HStack {
                Button(loc.t("common.cancel")) { dismiss() }
                if block != nil {
                    Button(loc.t("dom.share.recheck")) { Task { await recheck() } }
                        .disabled(isChecking)
                }
                Spacer()
                Button(loc.t("dom.share.start")) {
                    Task {
                        isWorking = true
                        await tunnelManager.start(domain: domain)
                        isWorking = false
                        // Başlatma yine de engellenirse (durum arada değişmiş olabilir)
                        // nedeni göster — sayfa sessizce kapanmasın.
                        if tunnelManager.tunnel(for: domain.name)?.publicURL == nil {
                            await recheck()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(block != nil || isChecking)
            }
        }
        .task { await recheck() }
    }

    private var starting: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc.t("dom.share.starting")).foregroundColor(.primary)
                    // Bekleme boyunca ne olduğunu söyle: boş bir çubuk, tünelin
                    // kilitlendiği izlenimi veriyordu. Gerçekte 7–10 sn sürüyor.
                    Text(loc.t("dom.share.startingHint"))
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 6) {
                Text(loc.t("dom.share.target")).font(.caption).foregroundColor(.secondary)
                Text(TunnelManager.displayOrigin(for: domain))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Divider()
            HStack {
                Spacer()
                Button(loc.t("common.cancel")) {
                    Task { await tunnelManager.stop(domainName: domain.name); dismiss() }
                }
            }
        }
    }

    private func live(url: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Adres SEÇİLEBİLİR ve tam genişlikte: sözcük ortasından kırılan bir URL
            // elle kopyalanamaz, ekran görüntüsünden okunamaz.
            VStack(alignment: .leading, spacing: 5) {
                Text(loc.t("dom.share.public"))
                    .font(.caption).foregroundColor(.secondary)
                Text(url)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundColor(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(Color.orange.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 6) {
                Text(loc.t("dom.share.target")).font(.caption).foregroundColor(.secondary)
                Text(TunnelManager.displayOrigin(for: domain))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            // Karekod beyaz zemin ister; koyu arayüzde kendi kartında durur.
            if let qr = Self.qrImage(for: url) {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(nsImage: qr).interpolation(.none)
                            .resizable().frame(width: 124, height: 124)
                            .padding(10)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(loc.t("dom.share.qr"))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button(loc.t("dom.share.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                    copied = true
                }
                Button(loc.t("common.open")) {
                    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                }
                if copied {
                    Label(loc.t("dom.share.copied"), systemImage: "checkmark")
                        .font(.caption).foregroundColor(.green)
                        .transition(.opacity)
                }
                Spacer()
                Button(loc.t("dom.share.stop"), role: .destructive) {
                    Task { await tunnelManager.stop(domainName: domain.name); dismiss() }
                }
                // Kapat, yayını SÜRDÜREREK pencereyi kapatır. Bu düğme olmadan
                // pencereden çıkmanın tek yolu paylaşımı durdurmaktı — oysa çoğu zaman
                // istenen, adres yayında kalırken pencereyi kapatmak.
                Button(loc.t("common.close")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .animation(.easeOut(duration: 0.15), value: copied)
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
