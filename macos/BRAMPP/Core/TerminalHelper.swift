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
    
    /// Sudo komutu yeni bir Terminal penceresinde çalıştırır
    static func runSudoInNewWindow(
        _ command: String,
        title: String = "BRAMPP - Yönetici İzni Gerekli"
    ) {
        let fullCommand = """
        clear
        echo ""
        echo "╔════════════════════════════════════════════════════════════════╗"
        echo "║  🔒 \(title.padding(toLength: 56, withPad: " ", startingAt: 0))║"
        echo "╚════════════════════════════════════════════════════════════════╝"
        echo ""
        echo "ℹ️  Bu işlem için yönetici şifresi gerekiyor."
        echo ""
        sudo \(command)
        RESULT=$?
        echo ""
        if [ $RESULT -eq 0 ]; then
            echo "✅ İşlem başarıyla tamamlandı!"
            echo ""; echo "💡 3 saniye içinde kapanacak..."; sleep 3
        else
            echo "❌ İşlem başarısız (Hata kodu: $RESULT)"
            echo ""; echo "💡 5 saniye içinde kapanacak..."; sleep 5
        fi
        """
        runInNewWindow(fullCommand, title: title)
    }
    
    /// Terminal test fonksiyonu (debug için)
    static func testTerminal() {
        let testCommand = """
        echo "✅ Terminal başarıyla açıldı!"
        echo ""; echo "Sistem Bilgileri:"
        echo "  Tarih: $(date)"; echo "  Kullanıcı: $(whoami)"
        echo "  Shell: $SHELL"
        echo ""; echo "Homebrew Kontrolü:"
        which brew && brew --version || echo "❌ Homebrew bulunamadı"
        echo ""; echo "mkcert Kontrolü:"
        which mkcert && mkcert -version || echo "❌ mkcert bulunamadı"
        echo ""; read -p "Enter'a basarak kapatabilirsiniz... "
        """
        runInNewWindow(testCommand, title: "BRAMPP - Terminal Test")
    }
}
