import Foundation
import AppKit

// MARK: - Terminal Helper

/// Terminal.app yardımcı fonksiyonları.
/// Brew kurulumu, mkcert CA kurulumu gibi işlemleri Terminal penceresinde çalıştırır.
struct TerminalHelper {
    
    /// Komutu yeni bir Terminal penceresinde çalıştırır
    static func runInNewWindow(_ command: String, title: String = "BRAMPP") {
        let tempDir = NSTemporaryDirectory()
        let scriptPath = tempDir + "brampp_\(UUID().uuidString).command"
        
        let fullScript = """
        #!/bin/bash
        
        echo "════════════════════════════════════════════════════════════"
        echo "  \(title)"
        echo "════════════════════════════════════════════════════════════"
        echo ""
        
        \(command)
        
        rm -f "\(scriptPath)"
        """
        
        do {
            try fullScript.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            
            let fileURL = URL(fileURLWithPath: scriptPath)
            let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([fileURL], withApplicationAt: terminalURL, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            print("❌ Script oluşturulamadı: \(error)")
        }
    }
    
    /// Komutu çalıştırır, sonucu gösterir, otomatik kapanır
    static func runInNewWindowAndWait(
        _ command: String,
        title: String = "BRAMPP"
    ) {
        let fullCommand = """
        echo "════════════════════════════════════════════════════════════"
        echo "  🚀 \(title)"
        echo "════════════════════════════════════════════════════════════"
        echo ""
        \(command)
        RESULT=$?
        echo ""
        echo "════════════════════════════════════════════════════════════"
        if [ $RESULT -eq 0 ]; then
            echo "✅ İşlem başarıyla tamamlandı!"
            echo ""; echo "💡 Bu pencere 3 saniye içinde kapanacak..."; sleep 3
        else
            echo "❌ İşlem başarısız oldu (Hata kodu: $RESULT)"
            echo ""; echo "💡 Bu pencere 5 saniye içinde kapanacak..."; sleep 5
        fi
        """
        runInNewWindow(fullCommand, title: title)
    }
    
    
}
