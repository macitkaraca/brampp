import SwiftUI

/// ELLE güncelleme denetiminin küçük durum penceresi.
///
/// Var olma nedeni: denetim bir ağ turudur ve saniyeler sürebilir. Sonuç ancak
/// bittiğinde beliriyordu, yani menüye basan kullanıcı için "hiçbir şey olmadı" —
/// menü öğesinin bozuk olduğunu düşündüren tam olarak o sessizlikti. Şimdi pencere
/// tıklamayla BİRLİKTE açılıyor ve ne olduğunu söylüyor.
///
/// Açılıştaki denetim bu pencereyi KULLANMAZ: orada kullanıcı bir şey istememiştir,
/// yalnızca güncelleme varsa bildirim gösterilir.
struct UpdateCheckStatusView: View {
    @EnvironmentObject var loc: Localizer

    enum State: Equatable {
        case checking
        /// Güncel — kurulu sürüm.
        case upToDate(String)
        case failed
    }

    let state: State
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.callout).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button(loc.t("common.close"), action: onClose)
                    .keyboardShortcut(.defaultAction)
                    // Denetim sürerken kapatmak işi yarıda bırakmaz, yalnızca pencereyi
                    // gizler; yine de düğmeyi gizlemiyoruz — kullanıcı vazgeçebilmeli.
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .checking:
            ProgressView().controlSize(.small).frame(width: 26, height: 26)
        case .upToDate:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24)).foregroundColor(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24)).foregroundColor(.orange)
        }
    }

    private var title: String {
        switch state {
        case .checking:   return loc.t("upd.check.title")
        case .upToDate:   return loc.t("upd.check.upToDate.title")
        case .failed:     return loc.t("upd.check.failed.title")
        }
    }

    private var detail: String {
        switch state {
        case .checking:          return loc.t("upd.check.detail")
        case .upToDate(let v):   return String(format: loc.t("upd.check.upToDate.detail"), v)
        case .failed:            return loc.t("upd.check.failed.detail")
        }
    }
}
