import SwiftUI

/// Yardım ve rehber — iki dilli (Localizer üzerinden TR/EN).
struct HelpView: View {
    @EnvironmentObject var loc: Localizer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(loc.t("help.title"), systemImage: "questionmark.circle")
                    .font(.headline)
                Spacer()
                Button(loc.t("common.close")) { dismiss() }
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(loc.t("help.intro"))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    section("help.services.title", "help.services.body", "gearshape.2")
                    section("help.domains.title",  "help.domains.body",  "globe")
                    section("help.database.title", "help.database.body", "cylinder")
                    section("help.hosts.title",    "help.hosts.body",    "wrench.and.screwdriver")
                    section("help.tips.title",     "help.tips.body",     "lightbulb")
                }
                .padding(20)
            }
        }
        .frame(width: 560, height: 560)
    }

    private func section(_ titleKey: String, _ bodyKey: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(loc.t(titleKey), systemImage: icon)
                .font(.subheadline).fontWeight(.semibold)
            Text(loc.t(bodyKey))
                .font(.callout).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
