import SwiftUI
import Combine

/// Bir log dosyasını canlı izler — `tail -f` gibi.
///
/// Eskiden log pencereleri 5 saniyede bir `tail -n 150` çağırıyordu: her turda kabuk
/// süreci doğuyor, dosya baştan okunuyor ve güncelleme 5 saniyeye kadar gecikiyordu.
/// Bu sınıf dosyayı `DispatchSource` ile izler ve YALNIZCA eklenen baytları okur.
///
/// Üç tuzağı ele alır — üçü de gerçek koşullarda çıkar:
///   • **Rotasyon**: gözetmen uygulamayı yeniden başlattığında log dosyası silinip
///     yeniden yaratılabilir. Eski dosya tanıtıcısı ölü bir vnode'u gösterir; `.delete`
///     ve `.rename` olaylarında izleyici yeniden bağlanır.
///   • **Kesilme**: dosya `> log` ile boşaltılırsa boyut, tutulan konumdan küçülür.
///     Fark hesaplanmaya çalışılırsa negatife düşer; bu durumda baştan okunur.
///   • **Gürültü**: çöküp yeniden başlayan bir uygulama saniyede onlarca satır yazar.
///     Olaylar debounce ile birleştirilir, aksi halde arayüz her satırda yeniden çizilir.
@MainActor
final class LogTailer: ObservableObject {

    /// Pencerede gösterilen metin.
    @Published private(set) var text: String = ""

    /// Bellekte tutulacak en fazla satır — sonsuza kadar biriken log pencereyi şişirir.
    private let maxLines: Int
    /// Açılışta gösterilecek son satır sayısı.
    private let initialLines: Int

    private var path: String = ""
    private var offset: UInt64 = 0
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var dirWatcher: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?

    /// Dosya yokken gösterilecek metin (çağıran belirler — bağlama göre değişir).
    private var placeholder: String = ""

    init(maxLines: Int = 2000, initialLines: Int = 200) {
        self.maxLines = maxLines
        self.initialLines = initialLines
    }

    deinit {
        fileWatcher?.cancel()
        dirWatcher?.cancel()
        debounce?.cancel()
    }

    // MARK: - Saf yardımcılar (doğrudan test edilir)

    /// Dosya küçüldüyse okuma konumu geçersizdir — baştan okunmalı.
    ///
    /// `> dosya` ile boşaltma ya da rotasyon sonrası yeni ve küçük bir dosya bu duruma
    /// yol açar. Fark körlemesine hesaplansaydı `UInt64` taşması yaşanırdı.
    static func resolvedOffset(fileSize: UInt64, currentOffset: UInt64) -> UInt64 {
        fileSize < currentOffset ? 0 : currentOffset
    }

    /// Metni son `maxLines` satıra indirir.
    static func capped(_ text: String, maxLines: Int) -> String {
        guard maxLines > 0 else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return text }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    /// Dosyanın son `lines` satırı — açılışta bir kez kullanılır.
    static func lastLines(of text: String, lines: Int) -> String {
        capped(text, maxLines: lines)
    }

    // MARK: - Başlat / Durdur

    func start(path: String, placeholder: String = "") {
        stop()
        self.path = path
        self.placeholder = placeholder
        loadInitial()
        armDirectoryWatcher()
        armFileWatcher()
    }

    func stop() {
        fileWatcher?.cancel(); fileWatcher = nil
        dirWatcher?.cancel();  dirWatcher = nil
        debounce?.cancel();    debounce = nil
        offset = 0
    }

    /// Dosyayı sıfırlar (Temizle düğmesi) — izleyici çalışmaya devam eder.
    func reset() {
        text = placeholder
        offset = 0
        readAppended()
    }

    // MARK: - Okuma

    private func loadInitial() {
        guard let data = FileManager.default.contents(atPath: path) else {
            text = placeholder
            offset = 0
            return
        }
        offset = UInt64(data.count)
        let whole = String(data: data, encoding: .utf8) ?? ""
        text = whole.isEmpty ? placeholder : Self.lastLines(of: whole, lines: initialLines)
    }

    /// Konumdan sonrasını okuyup ekler.
    private func readAppended() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0

        let resolved = Self.resolvedOffset(fileSize: size, currentOffset: offset)
        if resolved == 0 && offset != 0 {
            // Kesilme ya da rotasyon — pencereyi baştan kur.
            offset = 0
            text = ""
        }
        guard size > offset else { return }

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        offset = size
        guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }

        if text == placeholder { text = "" }
        text = Self.capped(text + chunk, maxLines: maxLines)
    }

    // MARK: - İzleyiciler

    /// Dosyanın KENDİSİNİ izler. Silinme/yeniden adlandırmada yeniden bağlanır.
    private func armFileWatcher() {
        fileWatcher?.cancel()
        fileWatcher = nil
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }   // dosya henüz yok — dizin olayı bizi geri getirir
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: .main)
        source.setEventHandler { [weak self] in
            let flags = source.data
            Task { @MainActor [weak self] in
                guard let self else { return }
                if flags.contains(.delete) || flags.contains(.rename) {
                    // Yeni dosya yaratıldı; eski tanıtıcı ölü vnode'u gösteriyor.
                    self.offset = 0
                    self.armFileWatcher()
                }
                self.scheduleRead()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileWatcher = source
    }

    /// Dosyayı İÇEREN dizini izler — log henüz yaratılmamışsa ilk oluşumu böyle yakalanır.
    private func armDirectoryWatcher() {
        dirWatcher?.cancel()
        dirWatcher = nil
        let dir = (path as NSString).deletingLastPathComponent
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.fileWatcher == nil { self.armFileWatcher() }
                self.scheduleRead()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        dirWatcher = source
    }

    /// Peş peşe gelen yazma olaylarını tek okumaya indirger.
    private func scheduleRead() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in self?.readAppended() }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
