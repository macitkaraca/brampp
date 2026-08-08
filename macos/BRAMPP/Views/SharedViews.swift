import SwiftUI

// MARK: - Status Row

/// Durum satırı — ikon + renk + metin.
/// ServicesTabView (SSL), SetupWizardView ve diğer yerlerde kullanılır.
///
/// ```swift
/// StatusRowView(icon: "checkmark.circle.fill", color: .green, text: "Kurulu")
/// ```
struct StatusRowView: View {
    let icon: String
    let color: Color
    let text: String
    var fontWeight: Font.Weight = .medium
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(text)
                .fontWeight(fontWeight)
        }
    }
}

// MARK: - Legend Item

/// Renk noktası + metin — durum açıklaması.
/// ServicesTabView alt kısmında kullanılır.
///
/// ```swift
/// LegendItemView(color: .green, text: "Çalışıyor")
/// ```
struct LegendItemView: View {
    let color: Color
    let text: String
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Mkcert Install Progress Sheet

/// mkcert / CA kurulum ilerlemesi — in-app streaming log sheet.
/// SettingsView ve SetupWizardView'dan sunulur.
struct MkcertInstallProgressSheet: View {
    @EnvironmentObject var loc: Localizer
    @ObservedObject var manager: MkcertManager
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                if manager.isInstalling {
                    ProgressView().controlSize(.small)
                    Text(manager.installTitle.isEmpty ? loc.t("common.installing") : manager.installTitle)
                        .font(.headline)
                    Spacer()
                    Text(loc.t("common.installing"))
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    let success = manager.installLog.contains("✅")
                    Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(success ? .green : .red)
                    Text(manager.installTitle.isEmpty ? loc.t("common.done") : manager.installTitle)
                        .font(.headline)
                    Spacer()
                    Text(loc.t("common.done")).font(.caption).foregroundColor(.secondary)
                }
                Button(loc.t("common.close")) { isPresented = false }
                    .buttonStyle(.bordered)
                    .disabled(manager.isInstalling)
            }
            .padding()

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(manager.installLog.isEmpty ? " " : manager.installLog)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                        .id("mkcert_log_bottom")
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: manager.installLog) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("mkcert_log_bottom", anchor: .bottom)
                    }
                }
            }
        }
        .frame(width: 640, height: 380)
        .interactiveDismissDisabled(manager.isInstalling)
    }
}

// MARK: - Brew Warning Banner

/// Homebrew kurulu değilken gösterilen turuncu uyarı banner'ı.
/// ServicesTabView ve LogsTabView'da kullanılır.
///
/// ```swift
/// if !Shell.isBrewInstalled { BrewWarningBanner() }
/// ```
struct BrewWarningBanner: View {
    @EnvironmentObject var loc: Localizer
    /// nil ise yerelleştirilmiş varsayılan mesaj kullanılır.
    var message: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(loc.t("common.brewMissing.title"))
                    .font(.headline)
                    .foregroundColor(.orange)
                Text(message ?? loc.t("common.brewMissing.msg"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(10)
    }
}

// MARK: - Empty State

/// Boş durum ekranı — ikon + başlık + alt metin.
/// DomainsTabView (domain yok) ve LogsTabView (log boş) için.
///
/// ```swift
/// EmptyStateView(icon: "globe", title: "Henüz domain yok", subtitle: "Eklemek için + butonuna basın")
/// ```
struct EmptyStateView: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var iconSize: CGFloat = 48
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: iconSize))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
            if let subtitle = subtitle {
                Text(subtitle)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Caption Label

/// Küçük açıklama metni — `.font(.caption).foregroundColor(.secondary)` tekrarını kaldırır.
///
/// ```swift
/// CaptionText("Bu bir açıklama")
/// CaptionText("Uyarı", color: .orange)
/// ```
struct CaptionText: View {
    let text: String
    var color: Color = .secondary
    
    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }
    
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundColor(color)
    }
}
