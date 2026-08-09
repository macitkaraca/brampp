import SwiftUI
import AppKit

/// PHP profilleyici paneli — Xdebug'ın profil kipini yönetir, çıktıları listeler.
struct PHPProfilerView: View {
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var phpExtensionManager: PHPExtensionManager

    @State private var showClearAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !phpExtensionManager.isXdebugReady {
                needsXdebug
            } else {
                controls
                if phpExtensionManager.profilerEnabled { activeNote }
                Divider()
                profileList
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear { phpExtensionManager.refreshProfiler() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.needle").foregroundColor(.orange)
            Text(loc.t("php.prof.title")).font(.headline)
            Spacer()
            if phpExtensionManager.profilerEnabled {
                Text(loc.t("php.prof.on"))
                    .font(.caption2.bold())
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.18))
                    .foregroundColor(.orange)
                    .clipShape(Capsule())
            }
        }
    }

    /// Profilleyici Xdebug'a bağlı — o etkin değilse ayar yazmanın anlamı yok.
    private var needsXdebug: some View {
        Label(loc.t("php.prof.needsXdebug"), systemImage: "info.circle")
            .font(.callout).foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(loc.t("php.prof.desc"))
                .font(.callout).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(loc.t("php.prof.enable"), isOn: Binding(
                get: { phpExtensionManager.profilerEnabled },
                set: { on in
                    phpExtensionManager.setProfiler(
                        enabled: on, alwaysOn: phpExtensionManager.profilerAlwaysOn)
                }))

            Toggle(loc.t("php.prof.always"), isOn: Binding(
                get: { phpExtensionManager.profilerAlwaysOn },
                set: { always in
                    phpExtensionManager.setProfiler(
                        enabled: phpExtensionManager.profilerEnabled, alwaysOn: always)
                }))
                .disabled(!phpExtensionManager.profilerEnabled)
            Text(loc.t("php.prof.alwaysNote"))
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Ayar `php.ini`'ye yazılıyor; PHP-FPM yeniden başlatılmadan web isteklerine
    /// yansımıyor. Bunu söylemezsek kullanıcı "açtım ama dosya üretmiyor" diyor.
    private var activeNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(loc.t("php.prof.restart"), systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if !phpExtensionManager.profilerAlwaysOn {
                Text(loc.t("php.prof.howTrigger"))
                    .font(.caption).foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var profileList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(loc.t("php.prof.files")).font(.subheadline.bold())
                Text("(\(phpExtensionManager.profiles.count))").foregroundColor(.secondary)
                Spacer()
                Button(loc.t("php.prof.folder")) {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: PHPProfiler.outputDir)
                }.buttonStyle(.borderless)
                if !phpExtensionManager.profiles.isEmpty {
                    Button(loc.t("php.prof.clear"), role: .destructive) { showClearAlert = true }
                        .buttonStyle(.borderless)
                }
            }

            if phpExtensionManager.profiles.isEmpty {
                Text(loc.t("php.prof.none")).font(.callout).foregroundColor(.secondary)
            } else {
                ForEach(phpExtensionManager.profiles.prefix(12)) { f in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text").foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.name).font(.system(size: 12, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                            Text("\(f.sizeText) · \(f.modified.formatted(date: .omitted, time: .standard))")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(loc.t("common.open")) { open(f) }.buttonStyle(.borderless)
                        Button(action: { phpExtensionManager.deleteProfile(f) }) {
                            Image(systemName: "trash").foregroundColor(.red)
                        }.buttonStyle(.borderless)
                    }
                    .padding(.vertical, 3)
                }
                if phpExtensionManager.profiles.count > 12 {
                    Text(String(format: loc.t("php.prof.more"),
                                phpExtensionManager.profiles.count - 12))
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .alert(loc.t("php.prof.clearTitle"), isPresented: $showClearAlert) {
            Button(loc.t("common.cancel"), role: .cancel) { }
            Button(loc.t("php.prof.clear"), role: .destructive) {
                phpExtensionManager.clearProfiles()
            }
        } message: {
            Text(loc.t("php.prof.clearMsg"))
        }
    }

    /// Cachegrind okuyucusu varsa onunla, yoksa Finder'da göster — ham dosyayı
    /// varsayılan uygulamada açmak metin editöründe anlamsız bir çıktı verirdi.
    private func open(_ f: PHPProfiler.ProfileFile) {
        if let viewer = PHPProfiler.viewerPath {
            let url = URL(fileURLWithPath: viewer)
            if viewer.hasSuffix(".app") {
                NSWorkspace.shared.open([URL(fileURLWithPath: f.path)],
                                        withApplicationAt: url,
                                        configuration: NSWorkspace.OpenConfiguration())
            } else {
                Task { _ = await Shell.bashAsync("\(Shell.quote(viewer)) \(Shell.quote(f.path)) &") }
            }
        } else {
            NSWorkspace.shared.selectFile(f.path, inFileViewerRootedAtPath: PHPProfiler.outputDir)
        }
    }
}
