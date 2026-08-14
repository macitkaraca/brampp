import SwiftUI

// MARK: - RootView

struct RootView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var loc: Localizer
    /// Yardım hem ana arayüzde hem KURULUM SİHİRBAZINDA çalışmalı — gözlemci bu yüzden
    /// ContentView'da değil burada (RootView her iki dalı da sarar).
    @State private var showHelp = false
    var body: some View {
        Group {
            if appState.isSetupCompleted {
                ContentView()
                    .environmentObject(appState.domainManager)
                    .environmentObject(appState.serviceManager)
                    .environmentObject(appState.phpExtensionManager)
                    .environmentObject(appState.consoleStore)
                    .environmentObject(appState.tunnelManager)
                    .environmentObject(appState.diagnosticsManager)
            } else {
                // ServiceManager sihirbaza da GEREKLİ: paket kurulumları oradan geçiyor
                // (PTY, canlı ilerleme, istem çubuğu). Sihirbaz kendi düz `streamBash`
                // çağrısıyla kurduğunda brew'un sorduğu soru hiç görünmüyordu.
                SetupWizardView { appState.onSetupCompleted() }
                    .environmentObject(appState.serviceManager)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showHelpSheet)) { _ in
            // Pencere gizliyken (hideWindowOnClose) sheet görünmez kuyruklanır ve çok
            // sonra beklenmedik anda belirirdi — önce pencereyi öne getir.
            BRAMPPAppDelegate.shared?.presentMainWindow()
            showHelp = true
        }
        // NOT: ELLE güncelleme denetimi BURADAN GEÇMEZ ve bir bildirimle de taşınmaz.
        // Tek giriş Ayarlar → Güncellemeler'deki düğme; o da `AppState`in üzerindeki
        // `runManualUpdateCheck()`i doğrudan çağırır. Gerekçesi orada yazılı.
        .sheet(isPresented: $showHelp) { HelpView() }
    }
}
