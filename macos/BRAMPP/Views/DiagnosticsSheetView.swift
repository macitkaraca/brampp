import SwiftUI

/// Ortam teşhisi penceresi.
struct DiagnosticsSheetView: View {
    @EnvironmentObject var loc: Localizer
    @EnvironmentObject var diagnostics: DiagnosticsManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
        .task { if diagnostics.findings.isEmpty { await diagnostics.run() } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "stethoscope")
                .font(.title2).foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(loc.t("diag.title")).font(.title3.bold())
                Text(loc.t("diag.sub")).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if !diagnostics.isRunning, !diagnostics.findings.isEmpty { verdictBadge }
        }
        .padding()
    }

    private var verdictBadge: some View {
        let level = diagnostics.summary
        let issues = diagnostics.findings.filter { $0.level != .pass }.count
        return Text(level == .pass ? loc.t("diag.clean")
                                   : String(format: loc.t("diag.count"), issues))
            .font(.caption.bold())
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(color(level).opacity(0.18))
            .foregroundColor(color(level))
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var content: some View {
        if diagnostics.isRunning && diagnostics.findings.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text(loc.t("diag.running")).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(diagnostics.findings) { f in
                        row(f)
                        Divider().padding(.leading, 44)
                    }
                }
            }
        }
    }

    private func row(_ f: Diagnostics.Finding) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: f.level.icon)
                .foregroundColor(color(f.level))
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(f.title).fontWeight(.medium)
                    Text(f.detail).foregroundColor(.secondary)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Çözüm önerisi yalnızca sorunlu satırlarda var; "her şey yolunda"
                // satırının altına metin koymak listeyi okunmaz hâle getiriyordu.
                if let r = f.remedy {
                    Text(r).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .textSelection(.enabled)
    }

    private var footer: some View {
        HStack {
            if let t = diagnostics.lastRun {
                Text(String(format: loc.t("diag.lastRun"),
                            t.formatted(date: .omitted, time: .standard)))
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            // Onarım YALNIZCA yapılacak bir şey varken görünür. Her zaman duran ama
            // çoğu zaman hiçbir şey yapmayan bir düğme, basıldığında sessiz kalır ve
            // kullanıcı özelliğin bozuk olduğunu düşünür.
            if diagnostics.canRepairAliasOrder {
                Button(loc.t("diag.repairAlias")) { Task { await diagnostics.repairAliasOrder() } }
                    .disabled(diagnostics.isRunning)
                    .help(loc.t("diag.repairAlias.help"))
            }
            Button(loc.t("diag.rerun")) { Task { await diagnostics.run() } }
                .disabled(diagnostics.isRunning)
            Button(loc.t("common.close")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private func color(_ l: Diagnostics.Level) -> Color {
        switch l {
        case .pass: return .green
        case .warn: return .orange
        case .fail: return .red
        }
    }
}
