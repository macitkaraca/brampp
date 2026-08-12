import SwiftUI
import AppKit

/// Ayarlar → **Güncelleme**. UYGULAMANIN kendi sürümüyle ilgilidir.
///
/// Homebrew paketlerinin güncelliği (`brew outdated`) BİLEREK burada değil,
/// Gelişmiş sekmesinde kaldı: o, yönetilen geliştirme ortamına ait bir konudur.
/// İkisini "Güncellemeler" adlı tek bir yere koymak tam da karıştırılmaması
/// gereken iki kavramı karıştırmak olurdu.
///
/// Durum `@AppStorage` ile AYNALANMAZ — yalnızca settings.json'da tutulur
/// (gerekçe: Core/AppSettings.swift, "Uygulama Güncellemeleri" bölümü).
struct UpdatesSettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var loc: Localizer

    @State private var channel: UpdateChannel = .stable
    @State private var autoCheck   = true
    @State private var autoDownload = false
    @State private var mode: UpdateMode = .notify
    @State private var skippedVersion = ""
    @State private var snoozeUntil: Double = 0
    @State private var lastCheck: Double = 0

    @State private var checking = false
    @State private var result: UpdateChecker.Result?

    private var installedVersion: String { UpdateChecker.currentVersion }

    /// Erteleme HÂLÂ sürüyor mu?
    ///
    /// `snoozeUntil > 0` DEĞİL: `updateSnoozeUntil` süresi dolduğunda temizlenmez
    /// (temizlemek için diskteki ayarı bir görünümün çiziminden yazmak gerekirdi ve
    /// o değer zaten zararsızdır — `decide()` geçmiş bir tarihi susturucu saymaz).
    /// Bu bölüm o değeri OLDUĞU GİBİ gösterdiği için, süresi dolmuş bir erteleme
    /// kullanıcıya GEÇMİŞ bir tarihle "…tarihine kadar ertelendi" diyordu — hem
    /// yanlış hem de gereksiz bir "Temizle" düğmesi.
    private var snoozeIsActive: Bool { snoozeUntil > Date().timeIntervalSince1970 }

    var body: some View {
        Form {
            versionSection
            channelSection
            autoSection
            downloadSection
            stateSection
            safetySection
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        // Bildirim penceresinden yapılan atlama/erteleme, AÇIK duran Ayarlar
        // penceresine de yansımalı — aksi halde kullanıcı temizleyemeyeceği bir
        // durumu görmüyor sanır.
        .onReceive(NotificationCenter.default.publisher(for: .updateStateChanged)) { _ in
            reload()
        }
    }

    // MARK: - Bu sürüm

    private var versionSection: some View {
        Section {
            LabeledContent(loc.t("set.upd.installed")) {
                Text(installedVersion).font(.caption).foregroundColor(.secondary)
            }
            CaptionText(lastCheck > 0
                        ? String(format: loc.t("set.upd.lastCheck"),
                                 UpdateChecker.displayDate(Date(timeIntervalSince1970: lastCheck)))
                        : loc.t("set.upd.lastCheckNever"))
            HStack(spacing: 8) {
                switch result {
                case .upToDate:
                    Label(loc.t("set.update.upToDate"), systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundColor(.green).labelStyle(.titleAndIcon)
                case .updateAvailable(let current, let release):
                    Label(String(format: loc.t("set.update.available"), release.version),
                          systemImage: "arrow.down.circle.fill")
                        .font(.caption).foregroundColor(.orange).labelStyle(.titleAndIcon)
                    // Açılış bildirimiyle AYNI pencere — tek sunum yolu.
                    Button(loc.t("set.upd.details")) {
                        UpdatePromptWindowController.shared.present(
                            current: current, release: release, console: appState.consoleStore)
                    }
                    .buttonStyle(.link).font(.caption)
                // Daha yeni sürüm YOK ama kurulu sürüm sorunlu işaretli. "En güncel
                // sürümdesiniz" yeşil onayı burada YANLIŞ olurdu.
                case .currentBlocked(let current, let release):
                    Label(loc.t("set.upd.blockedCurrent"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundColor(.red).labelStyle(.titleAndIcon)
                    Button(loc.t("set.upd.details")) {
                        UpdatePromptWindowController.shared.present(
                            current: current, release: release, console: appState.consoleStore)
                    }
                    .buttonStyle(.link).font(.caption)
                case .failed:
                    CaptionText(loc.t("set.update.failed"))
                case nil:
                    EmptyView()
                }
                Spacer()
                Button(checking ? loc.t("set.update.checking") : loc.t("set.upd.checkNow")) {
                    checkNow()
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(checking)
            }
        } header: {
            Label(loc.t("set.upd.version.header"), systemImage: "app.badge")
        }
    }

    // MARK: - Kanal

    private var channelSection: some View {
        Section {
            Picker(loc.t("set.upd.channel.label"), selection: $channel) {
                ForEach(UpdateChannel.allCases) { c in
                    Text(loc.t(c.labelKey)).tag(c)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: channel) { _, value in
                var s = AppSettings.load(); s.updateChannel = value.rawValue; s.save()
            }
            // GERÇEK ile AYRILMIŞ arasındaki fark kullanıcıdan saklanmaz.
            if !channel.isPublished {
                CaptionText(String(format: loc.t("set.upd.channel.reserved"),
                                   loc.t(channel.labelKey)), color: .orange)
            }
            CaptionText(loc.t("set.upd.channel.note"))
        } header: {
            Label(loc.t("set.upd.channel.header"), systemImage: "point.3.filled.connected.trianglepath.dotted")
        }
    }

    // MARK: - Otomatik denetim

    private var autoSection: some View {
        Section {
            Toggle(loc.t("set.upd.auto.toggle"), isOn: $autoCheck)
                .onChange(of: autoCheck) { _, value in
                    var s = AppSettings.load(); s.updateAutoCheck = value; s.save()
                }
            CaptionText(loc.t("set.upd.auto.note"))
        } header: {
            Label(loc.t("set.upd.auto.header"), systemImage: "clock.arrow.circlepath")
        }
    }

    // MARK: - İndirme

    private var downloadSection: some View {
        Section {
            Picker(loc.t("set.upd.dl.mode"), selection: $mode) {
                ForEach(UpdateMode.allCases) { m in
                    Text(loc.t(m.labelKey)).tag(m)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: mode) { _, value in
                var s = AppSettings.load()
                s.updateMode = value.rawValue
                // "Yalnızca haber ver" ile "arka planda indir" birlikte anlamsızdır;
                // iki denetimin çelişkili bir durum İFADE EDEBİLMESİ kusurdur.
                if value == .notify { s.updateAutoDownload = false; autoDownload = false }
                s.save()
            }
            Toggle(loc.t("set.upd.dl.auto"), isOn: $autoDownload)
                .disabled(mode == .notify)
                .onChange(of: autoDownload) { _, value in
                    var s = AppSettings.load(); s.updateAutoDownload = value; s.save()
                }
            CaptionText(loc.t("set.upd.dl.note"))
        } header: {
            Label(loc.t("set.upd.dl.header"), systemImage: "arrow.down.circle")
        }
    }

    // MARK: - Atlanan ve ertelenen

    /// Bu bölüm olmadan "bu sürümü atla" GERİ ALINAMAZ bir tuzaktır: kullanıcı
    /// kararını verdiği yerde geri alamaz, kararın izini de göremezdi.
    private var stateSection: some View {
        Section {
            if skippedVersion.isEmpty, !snoozeIsActive {
                CaptionText(loc.t("set.upd.state.none"))
            }
            if !skippedVersion.isEmpty {
                HStack {
                    CaptionText(String(format: loc.t("set.upd.state.skipped"), skippedVersion))
                    Spacer()
                    Button(loc.t("set.upd.state.clear")) {
                        var s = AppSettings.load(); s.updateSkippedVersion = ""; s.save()
                        skippedVersion = ""
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
            if snoozeIsActive {
                HStack {
                    CaptionText(String(format: loc.t("set.upd.state.snoozed"),
                                       UpdateChecker.displayDate(Date(timeIntervalSince1970: snoozeUntil))))
                    Spacer()
                    Button(loc.t("set.upd.state.clear")) {
                        var s = AppSettings.load(); s.updateSnoozeUntil = 0; s.save()
                        snoozeUntil = 0
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
        } header: {
            Label(loc.t("set.upd.state.header"), systemImage: "bell.slash")
        }
    }

    // MARK: - Güvenlik kapıları (salt okunur)

    private var safetySection: some View {
        Section {
            StatusRowView(icon: "lock.fill", color: .green, text: loc.t("set.upd.safety.https"))
                .font(.caption)
            StatusRowView(icon: "number", color: .green, text: loc.t("set.upd.safety.sha"))
                .font(.caption)
            StatusRowView(icon: "signature", color: .green, text: loc.t("set.upd.safety.codesign"))
                .font(.caption)
            StatusRowView(icon: "checkmark.seal.fill", color: .green, text: loc.t("set.upd.safety.gatekeeper"))
                .font(.caption)
            StatusRowView(icon: "person.badge.key.fill", color: .green, text: loc.t("set.upd.safety.team"))
                .font(.caption)
            CaptionText(loc.t("set.upd.safety.fail"), color: .orange)
        } header: {
            Label(loc.t("set.upd.safety.header"), systemImage: "shield.lefthalf.filled")
        }
    }

    // MARK: - Yardımcılar

    /// Alanlar diskteki GERÇEK değerden tazelenir — sıfırlama, yedek geri yükleme
    /// ya da bildirim penceresinden yapılan yazımdan sonra bayat kalmasın.
    private func reload() {
        let s = AppSettings.load()
        channel        = UpdateChannel.from(s.updateChannel)
        autoCheck      = s.updateAutoCheck
        autoDownload   = s.updateAutoDownload
        mode           = UpdateMode.from(s.updateMode)
        skippedVersion = s.updateSkippedVersion
        snoozeUntil    = s.updateSnoozeUntil
        lastCheck      = s.updateLastCheck
    }

    /// Elle denetim: atlama/erteleme DİNLENMEZ — insan sordu, yanıtı görmeli.
    private func checkNow() {
        checking = true
        Task {
            let r = await appState.performUpdateCheck(force: true)
            result = r
            checking = false
            reload()
        }
    }
}
