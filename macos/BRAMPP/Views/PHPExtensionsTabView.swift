import SwiftUI
import Combine

/// PHP Extension yönetimi görünümü
struct PHPExtensionsTabView: View {
    @EnvironmentObject var loc: Localizer
    
    @EnvironmentObject var phpExtensionManager: PHPExtensionManager
    @State private var showIniSettings: Bool = false
    @State private var draftIniSettings: [PHPIniSetting] = []
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            toolbar

            Divider()

            if installedPHPVersions.isEmpty {
                // Boş durum — hiç PHP kurulu değil
                VStack(spacing: 16) {
                    Image(systemName: "p.circle")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text(loc.t("ext.noPhp"))
                        .font(.headline)
                    Text(loc.t("ext.noPhpHint"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                HSplitView {
                    // Extensions List
                    extensionsList
                        .frame(minWidth: 400)

                    // php.ini Settings
                    if showIniSettings {
                        PHPProfilerView()
                        phpIniSettingsView
                            .frame(minWidth: 330, maxWidth: 360)
                    }
                }
            }
        }
        .onAppear {
            // Seçili sürüm kurulu değilse ilk kurulu sürüme geç
            if !installedPHPVersions.isEmpty,
               !installedPHPVersions.contains(where: { $0 == phpExtensionManager.selectedPHPVersion }) {
                let firstInstalled = installedPHPVersions[0]
                phpExtensionManager.changePHPVersion(to: firstInstalled)
            }
            draftIniSettings = phpExtensionManager.phpIniSettings
        }
        .onReceive(phpExtensionManager.$phpIniSettings) { settings in
            draftIniSettings = settings
        }
    }
    
    // MARK: - Toolbar

    /// Yalnızca Homebrew üzerinden kurulu PHP sürümleri
    private var installedPHPVersions: [PHPVersion] {
        PHPVersion.allCases.filter { $0.isInstalled }
    }

    private var toolbar: some View {
        HStack {
            Text(loc.t("ext.title"))
                .font(.headline)

            Spacer()

            // PHP Version Picker — yalnızca kurulu sürümler gösterilir
            if installedPHPVersions.isEmpty {
                Text(loc.t("ext.noPhpShort"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
            } else {
                Picker("PHP", selection: $phpExtensionManager.selectedPHPVersion) {
                    ForEach(installedPHPVersions) { version in
                        Text(version.displayName).tag(version)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)
                .onChange(of: phpExtensionManager.selectedPHPVersion) { _, version in
                    phpExtensionManager.changePHPVersion(to: version)
                    draftIniSettings = phpExtensionManager.phpIniSettings
                }
            }

            Button(action: { showIniSettings.toggle() }) {
                Image(systemName: showIniSettings ? "slider.horizontal.3" : "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .help(loc.t("ext.iniSettings"))

            Button(action: { phpExtensionManager.loadExtensions() }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
    
    // MARK: - Extensions List
    
    private var extensionsList: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForEach(ExtensionCategory.allCases) { category in
                    let extensions = phpExtensionManager.extensions(for: category)
                    if !extensions.isEmpty {
                        ExtensionGroupView(category: category, extensions: extensions)
                    }
                }
            }
            .padding()
        }
    }
    
    // MARK: - php.ini Settings
    
    private var phpIniSettingsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(loc.t("ext.iniSettings"))
                    .font(.headline)
                
                Spacer()
                
                Button(loc.t("ext.resetDefaults")) {
                    resetIniSettingsToDefaults()
                }
                .buttonStyle(.bordered)
                .disabled(!hasIniChanges)
                
                Button(loc.t("ext.save")) {
                    saveIniSettings()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasIniChanges)
            }
            .padding()
            
            Divider()
            
            ScrollView {
                VStack(spacing: 12) {
                    ForEach($draftIniSettings) { $setting in
                        PHPIniSettingRow(setting: $setting)
                    }
                }
                .padding()
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var hasIniChanges: Bool {
        guard draftIniSettings.count == phpExtensionManager.phpIniSettings.count else { return false }
        
        return zip(draftIniSettings, phpExtensionManager.phpIniSettings).contains {
            $0.currentValue != $1.currentValue
        }
    }
    
    private func saveIniSettings() {
        for draft in draftIniSettings {
            guard let original = phpExtensionManager.phpIniSettings.first(where: { $0.id == draft.id }) else { continue }
            guard original.currentValue != draft.currentValue else { continue }
            phpExtensionManager.updatePHPIniSetting(draft, value: draft.currentValue)
        }
    }
    
    private func resetIniSettingsToDefaults() {
        let defaultSettingsByID = Dictionary(uniqueKeysWithValues: PHPIniSetting.commonSettings.map { ($0.id, $0) })
        
        draftIniSettings = draftIniSettings.map { current in
            guard let defaultSetting = defaultSettingsByID[current.id] else { return current }
            var updated = current
            updated.currentValue = defaultSetting.currentValue
            return updated
        }
    }
}

// MARK: - Extension Group View

struct ExtensionGroupView: View {
    
    let category: ExtensionCategory
    let extensions: [PHPExtension]
    
    @State private var isExpanded: Bool = true
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack {
                    Text(category.icon)
                    Text(category.displayName)
                        .font(.headline)
                    
                    Spacer()
                    
                    Text("\(extensions.filter { $0.isEnabled }.count)/\(extensions.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
            }
            .buttonStyle(.plain)
            
            // Extensions
            if isExpanded {
                VStack(spacing: 1) {
                    ForEach(extensions, id: \.id) { ext in
                        ExtensionRowView(extension_: ext)
                    }
                }
            }
        }
        .background(Color(NSColor.separatorColor).opacity(0.3))
        .cornerRadius(10)
    }
}

// MARK: - Extension Row View

struct ExtensionRowView: View {
    
    @EnvironmentObject var phpExtensionManager: PHPExtensionManager
    @EnvironmentObject var loc: Localizer
    let extension_: PHPExtension
    
    var body: some View {
        HStack(spacing: 12) {
            // Toggle or Install
            if extension_.isInstalled {
                Toggle("", isOn: Binding(
                    get: { extension_.isEnabled },
                    set: { _ in phpExtensionManager.toggleExtension(extension_) }
                ))
                .toggleStyle(.checkbox)
                .disabled(extension_.isBuiltIn)
            } else {
                Button(loc.t("ext.install")) {
                    phpExtensionManager.installExtension(extension_)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            
            // Info
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(extension_.name)
                        .fontWeight(.medium)
                    
                    if extension_.isBuiltIn {
                        Text("built-in")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.2))
                            .foregroundColor(.blue)
                            .cornerRadius(3)
                    }
                    
                    if let version = extension_.version {
                        Text("v\(version)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Text(extension_.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Ayarlar: eklentinin kendi .ini dosyasını editörde açar
            // (xdebug, redis, imagick vb. yönergeleri buraya eklenir)
            if extension_.isInstalled && !extension_.isBuiltIn {
                Button(action: { openExtensionIni() }) {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)
                .help(String(format: loc.t("ext.gearHelp"), extension_.name, extension_.name))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    /// Eklentinin conf.d/ext-{name}.ini dosyasını varsayılan editörde açar.
    /// Dosya yoksa (etkin ama boş) yararlı bir başlık şablonuyla oluşturulur.
    private func openExtensionIni() {
        let ver   = phpExtensionManager.selectedPHPVersion.rawValue
        let confD = PathConfig.phpConfD(version: ver)
        // Etkin dosya "ext-name.ini", devre dışıysa ".ini.disabled"
        let enabled  = "\(confD)/ext-\(extension_.name).ini"
        let disabled = "\(enabled).disabled"
        let path = FileHelper.exists(enabled) ? enabled
                 : (FileHelper.exists(disabled) ? disabled : enabled)

        if !FileHelper.exists(path) {
            FileHelper.createDirectory(confD)
            let stub = """
            ; \(extension_.name) yapılandırması — PHP \(ver)
            ; Bu dosya BRAMPP tarafından yönetilir.
            ; Eklenti yönergelerini buraya ekleyin, ardından PHP-FPM'i yeniden başlatın.
            extension=\(extension_.name)

            ; Örnek yönergeler (gerekiyorsa yorumu kaldırın):
            ; \(extension_.name).some_setting = value
            """
            _ = FileHelper.write(stub, to: path)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

// MARK: - PHP INI Setting Row

struct PHPIniSettingRow: View {
    
    @Binding var setting: PHPIniSetting
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(setting.name)
                    .font(.caption)
                    .fontWeight(.semibold)
                
                Text(setting.description)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Picker("", selection: $setting.currentValue) {
                ForEach(setting.options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 120)
        }
        .padding(12)
        .background(Color(NSColor.textBackgroundColor))
        .cornerRadius(8)
    }
}

#Preview {
    PHPExtensionsTabView()
        .environmentObject(PHPExtensionManager(consoleStore: ConsoleStore()))
        .environmentObject(Localizer.shared)
}
