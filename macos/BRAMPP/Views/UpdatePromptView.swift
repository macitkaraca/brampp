import SwiftUI
import AppKit

/// Güncelleme bildiriminin gövdesi: sürüm başlığı, KAYDIRILABİLİR sürüm notları,
/// indirme/doğrulama şeridi ve eylem satırı.
///
/// Bu görünüm hem açılış bildiriminde hem Ayarlar → Güncelleme → "Ayrıntıları
/// göster"de kullanılır. TEK sunum yolu bilinçli: iki ayrı arayüz zamanla ayrışır.
struct UpdatePromptView: View {
    @EnvironmentObject var loc: Localizer
    @ObservedObject var installer: UpdateInstaller

    let current: String
    let release: UpdateChecker.ReleaseInfo
    let mode: UpdateMode
    let onSkip: () -> Void
    let onSnooze: (Date) -> Void
    let onClose: () -> Void

    /// Notlar bir KEZ çözümlenir. Her yeniden çizimde Markdown ayrıştırmak,
    /// kaydırma sırasında görünür bir takılma üretirdi.
    private let blocks: [UpdateNotes.Block]
    private let notesTruncated: Bool

    init(current: String,
         release: UpdateChecker.ReleaseInfo,
         installer: UpdateInstaller,
         mode: UpdateMode,
         onSkip: @escaping () -> Void,
         onSnooze: @escaping (Date) -> Void,
         onClose: @escaping () -> Void) {
        self.current = current
        self.release = release
        self._installer = ObservedObject(wrappedValue: installer)
        self.mode = mode
        self.onSkip = onSkip
        self.onSnooze = onSnooze
        self.onClose = onClose
        let rendered = UpdateNotes.render(release.notes)
        self.blocks = rendered.blocks
        self.notesTruncated = rendered.truncated
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            notesSection
            Divider()
            statusStrip
            actionRow
        }
        .frame(minWidth: 460, minHeight: 440)
    }

    // MARK: - Başlık

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc.t("upd.title")).font(.headline)
                    Text(String(format: loc.t("upd.subtitle"), current, release.version))
                        .font(.subheadline).foregroundColor(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Text(String(format: loc.t("upd.channelBadge"), release.channel))
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(4)
                if let published = release.publishedAt {
                    CaptionText(String(format: loc.t("upd.published"),
                                       UpdateChecker.displayDate(published)))
                }
                Spacer()
            }

            // Sorunlu sürüm uyarısı, zorunluluk uyarısından ÖNCE gelir: kullanıcının
            // ŞU AN çalıştırdığı şeyle ilgili olan odur (spec/update-manifest.md).
            if release.blockedCurrent {
                warning(loc.t("upd.blocked"), color: .red)
            } else if release.mandatory {
                warning(loc.t("upd.mandatory"), color: .orange)
            }

            // Sürüm var ama bu makinenin macOS'u yetmiyor. SÖYLENİR: "güncelsiniz"
            // demek yalan, indirme sunmak ise açılmayacak bir uygulamayı 60 MB
            // indirtmek olurdu (indirme bu durumda zaten kapalı — sha256 nil gelir).
            if let requiredOS = release.requiredOS {
                warning(String(format: loc.t("upd.needsNewerOS"), requiredOS), color: .orange)
            }
        }
        .padding(16)
    }

    private func warning(_ text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption).foregroundColor(color)
            Text(text).font(.caption).foregroundColor(color)
            Spacer()
        }
    }

    // MARK: - Sürüm notları

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(loc.t("upd.notes.header"))
                    .font(.caption).bold().foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)

            if blocks.isEmpty {
                // BOŞ KUTU GÖSTERİLMEZ: not yoksa bunu söyleyip kullanıcıyı
                // notların gerçekten bulunduğu yere yönlendiririz.
                VStack(spacing: 10) {
                    CaptionText(loc.t("upd.notes.none"))
                    Button(loc.t("upd.action.openPage")) {
                        NSWorkspace.shared.open(release.pageURL)
                    }
                    .buttonStyle(.link).font(.caption)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            blockView(block)
                        }
                        if notesTruncated {
                            CaptionText(loc.t("upd.notes.truncated"), color: .orange)
                                .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .frame(minHeight: 160)
                .textSelection(.enabled)
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func blockView(_ block: UpdateNotes.Block) -> some View {
        switch block {
        case .heading(let text):
            Text(text).font(.subheadline).bold().padding(.top, 4)
        case .bullet(let text):
            HStack(alignment: .top, spacing: 6) {
                Text("•").font(.callout).foregroundColor(.secondary)
                Text(text).font(.callout)
            }
        case .paragraph(let text):
            Text(text).font(.callout)
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    // MARK: - İndirme / doğrulama şeridi

    /// "Doğrulanabilir bir sağlama YAYINLANMAMIŞ" şeridi gösterilsin mi?
    ///
    /// **`sha256 == nil` TEK BAŞINA YETMEZ** — ve bunu yalnızca sağlamanın yokluğu
    /// sanmak somut bir yalan üretiyordu. `sha256`, indirmeyi KAPATMANIN da yoludur:
    ///   • `minimumOS` bu makineye yetmiyorsa (`requiredOS` dolu) nil'lenir,
    ///   • kurulu sürüm `blockedVersions` listesindeyse (`blockedCurrent`) nil'lenir.
    /// Bu iki durumda sağlama pekâlâ yayınlanmıştır. macOS 14'teki bir kullanıcı,
    /// 15.0 isteyen bir yayın için hem "macOS 15.0 gerekiyor" hem "doğrulanabilir
    /// sağlama yok" görüyordu; ikincisi yanlış, üstelik başlıktaki GERÇEK nedeni
    /// gölgeliyordu. İndirme yine kapalıdır — ama nedenini zaten uyarı satırı söyler.
    ///
    /// Görünümün DIŞINDA: koşulun kendisi birim testlenebilsin diye.
    static func showsNoChecksumNotice(_ release: UpdateChecker.ReleaseInfo) -> Bool {
        release.sha256 == nil && release.requiredOS == nil && !release.blockedCurrent
    }

    @ViewBuilder
    private var statusStrip: some View {
        switch installer.phase {
        case .idle:
            if UpdatePromptView.showsNoChecksumNotice(release) {
                // Manifest okunamadı ya da bu mimari için giriş yok → doğrulanabilir
                // bir sağlama yok → uygulama içinde indirme YOK.
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").font(.caption).foregroundColor(.orange)
                    CaptionText(loc.t("upd.dl.noHash"), color: .orange)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 10)
            }
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 4) {
                CaptionText(String(format: loc.t("upd.dl.downloading"),
                                   "\(Int((fraction * 100).rounded()))%"))
                ProgressView(value: fraction)
            }
            .padding(.horizontal, 16).padding(.top, 10)
        case .verifying:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                CaptionText(loc.t("upd.dl.verifying"))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 10)
        case .ready:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.seal.fill").font(.caption).foregroundColor(.green)
                CaptionText(loc.t("upd.dl.ready"), color: .green)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 10)
        case .failed(let reason):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "xmark.octagon.fill").font(.caption).foregroundColor(.red)
                CaptionText(String(format: loc.t("upd.dl.failed"), loc.t(reason.messageKey)),
                            color: .red)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 10)
        }
    }

    // MARK: - Eylemler

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button(loc.t("upd.action.skip"), action: onSkip)
                .buttonStyle(.bordered).controlSize(.small)

            Menu(loc.t("upd.action.later")) {
                Button(loc.t("upd.later.1day"))  { onSnooze(snoozeDate(days: 1)) }
                Button(loc.t("upd.later.3days")) { onSnooze(snoozeDate(days: 3)) }
                Button(loc.t("upd.later.1week")) { onSnooze(snoozeDate(days: 7)) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            Button(loc.t("common.close"), action: onClose)
                .buttonStyle(.bordered).controlSize(.small)

            primaryAction
        }
        .padding(16)
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch installer.phase {
        case .downloading, .verifying:
            Button(loc.t("upd.dl.cancel")) { installer.cancel() }
                .buttonStyle(.bordered).controlSize(.small)
        case .ready:
            Button(loc.t("upd.dl.discard")) { installer.discard() }
                .buttonStyle(.bordered).controlSize(.small)
            Button(loc.t("upd.dl.reveal")) { installer.revealVerified() }
                .buttonStyle(.borderedProminent).controlSize(.small)
        case .idle, .failed:
            // AYARLA ÇELİŞMEZ. "Yalnızca haber ver" seçiliyken pencerenin "İndir ve
            // doğrula" düğmesi göstermesi, iki denetimin çelişkili bir durum İFADE
            // EDEBİLMESİ demekti — Ayarlar'da `notify` + `autoDownload` bileşimini
            // yasaklarken kullandığımız gerekçenin aynısı, aynı özellik için.
            if mode != .notify, release.sha256 != nil, release.assetURL != nil {
                Button(loc.t("upd.action.install")) {
                    installer.start(release, openWhenReady: mode == .downloadAndOpen)
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
            } else {
                Button(loc.t("upd.action.openPage")) {
                    NSWorkspace.shared.open(release.pageURL)
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
    }

    /// Erteleme tarihi TAKVİMLE hesaplanır, `now + 86_400` ile değil: yaz saati
    /// geçişi olan bir haftada sabit saniye toplamı hatırlatmayı bir saat kaydırır.
    private func snoozeDate(days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: Date())
            ?? Date().addingTimeInterval(Double(days) * 86_400)
    }
}
