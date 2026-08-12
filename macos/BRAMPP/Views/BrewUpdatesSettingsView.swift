import SwiftUI

/// Ayarlar → Homebrew. Kendi sekmesinde, çünkü iki ayrı kavram karışıyordu:
/// "Güncellemeler" sekmesi UYGULAMANIN sürümünü yönetiyor, burası MAKİNEDEKİ
/// paketleri. Aynı sekmede durduklarında hangi "güncelleme"nin kastedildiği
/// okunmadan anlaşılmıyordu.
struct BrewUpdatesSettingsView: View {
    @EnvironmentObject var loc: Localizer
    @ObservedObject var brew: BrewUpdatesManager
    @ObservedObject var serviceManager: ServiceManager

    /// İlgili ve diğer gruplar KAPALI başlar: kullanıcının aradığı şey neredeyse her
    /// zaman yönetilen paketlerdir, kalanı bağlam.
    @State private var showRelated = false
    @State private var showOther = false

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loc.t("set.brew.checkTitle")).font(.subheadline)
                        Text(loc.t("set.brew.checkDesc"))
                            .font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(brew.isChecking ? loc.t("set.updates.checking")
                                           : loc.t("set.updates.check.btn")) {
                        Task { await brew.check(services: serviceManager.services) }
                    }
                    .disabled(brew.isChecking || brew.isUpgrading || !Shell.isBrewInstalled)
                }
                if let t = brew.lastCheck {
                    Text(String(format: loc.t("diag.lastRun"),
                                t.formatted(date: .omitted, time: .standard)))
                        .font(.caption).foregroundColor(.secondary)
                }
            } header: {
                Label(loc.t("set.brewUpdates.header"), systemImage: "arrow.triangle.2.circlepath")
            }

            if brew.lastCheck != nil, !brew.hasAnything {
                Section {
                    Label(loc.t("set.updates.upToDate"), systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundColor(.green)
                }
            }

            if !brew.managed.isEmpty {
                group(loc.t("set.brew.group.managed"),
                      note: loc.t("set.brew.group.managed.note"),
                      packages: brew.managed)
            }
            if !brew.related.isEmpty {
                collapsible(loc.t("set.brew.group.related"),
                            note: loc.t("set.brew.group.related.note"),
                            packages: brew.related, open: $showRelated)
            }
            if !brew.other.isEmpty {
                collapsible(loc.t("set.brew.group.other"),
                            note: loc.t("set.brew.group.other.note"),
                            packages: brew.other, open: $showOther)
            }

            if brew.hasAnything {
                Section {
                    HStack {
                        Text(String(format: loc.t("set.brew.selected"), brew.selection.count))
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Button(loc.t("set.brew.selectManaged")) {
                            brew.selection = Set(brew.managed.map(\.name))
                        }
                        .disabled(brew.managed.isEmpty || brew.isUpgrading)
                        Button(brew.isUpgrading ? loc.t("set.brew.upgrading")
                                                : loc.t("set.brew.upgradeSelected")) {
                            Task {
                                await brew.upgradeSelected(services: serviceManager.services,
                                                           serviceManager: serviceManager)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(brew.selection.isEmpty || brew.isUpgrading)
                    }
                } footer: {
                    Text(loc.t("set.brew.restartNote"))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Parçalar

    @ViewBuilder
    private func group(_ title: String, note: String,
                       packages: [BrewUpdates.Package]) -> some View {
        Section {
            ForEach(packages) { p in row(p) }
        } header: {
            Text(title)
        } footer: {
            Text(note).font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func collapsible(_ title: String, note: String,
                             packages: [BrewUpdates.Package],
                             open: Binding<Bool>) -> some View {
        Section {
            DisclosureGroup(isExpanded: open) {
                ForEach(packages) { p in row(p) }
            } label: {
                HStack {
                    Text(title)
                    Text("\(packages.count)")
                        .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                }
            }
        } footer: {
            Text(note).font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ p: BrewUpdates.Package) -> some View {
        Toggle(isOn: Binding(
            get: { brew.selection.contains(p.name) },
            set: { on in
                if on { brew.selection.insert(p.name) } else { brew.selection.remove(p.name) }
            }
        )) {
            HStack(spacing: 8) {
                Text(p.name).font(.system(.body, design: .monospaced))
                Spacer()
                if !p.current.isEmpty {
                    // Sürümler tek tek okunur olmalı: "neyi neye yükseltiyorum"
                    // sorusunun cevabı, yükseltmeye karar verdiren şey.
                    Text("\(p.current) → \(p.latest)")
                        .font(.caption.monospaced()).foregroundColor(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(brew.isUpgrading)
    }
}
