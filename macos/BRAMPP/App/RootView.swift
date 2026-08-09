import SwiftUI

// MARK: - RootView

struct RootView: View {
    @EnvironmentObject var appState: AppState
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
                SetupWizardView { appState.onSetupCompleted() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showHelpSheet)) { _ in
            // Pencere gizliyken (hideWindowOnClose) sheet görünmez kuyruklanır ve çok
            // sonra beklenmedik anda belirirdi — önce pencereyi öne getir.
            BRAMPPAppDelegate.shared?.presentMainWindow()
            showHelp = true
        }
        .sheet(isPresented: $showHelp) { HelpView() }
    }
}
