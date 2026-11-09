import CoreText
import Foundation

/// Global font management, adapted from Beans 2.0.3 `FontManager`
/// (same mechanism, Golia storage): user-uploaded ttf/otf files are
/// copied to Documents/Fonts and registered with CoreText, so they
/// stay usable after relaunch (re-registered at startup) and show up
/// in the existing lyric font picker (`UIFontPickerViewController`
/// lists registered fonts), which is the one place Golia picks a font
/// by name today.
///
/// Deliberate scope: Beans applies its font app-wide through
/// `BeansFont.appFont`, which every Beans view calls. Golia has no
/// central font reader — views use `.system` directly — so there is
/// no app-wide override in this sub-part; wiring one would mean
/// touching every `.font` call site, which belongs in its own work
/// item, not the settings port. The install / register / restore
/// machinery below is the prerequisite for it.
enum FontManager {
    static let storedFontNameKey = SettingsManager.Keys.customFontName

    private static var cachedInstalledFontName: String? =
        UserDefaults.standard.string(forKey: storedFontNameKey)

    static var installedFontName: String? {
        get { cachedInstalledFontName }
        set {
            cachedInstalledFontName = newValue
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: storedFontNameKey)
            } else {
                UserDefaults.standard.removeObject(forKey: storedFontNameKey)
            }
        }
    }

    private static var fontsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Fonts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Re-register installed fonts at launch (Documents survives app
    /// updates, so installed fonts keep working).
    static func reinstallIfNeeded() {
        guard installedFontName != nil else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: fontsDirectory, includingPropertiesForKeys: nil)
        else { return }
        for file in files where ["ttf", "otf", "ttc"].contains(file.pathExtension.lowercased()) {
            register(file)
        }
    }

    /// Install a user-picked font file (clears any previous font
    /// first, like Beans). Returns the registered PostScript name.
    @discardableResult
    static func install(from sourceURL: URL) -> String? {
        let file = fontsDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        if let files = try? FileManager.default.contentsOfDirectory(
            at: fontsDirectory, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
        if FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.removeItem(at: file)
        }
        guard (try? FileManager.default.copyItem(at: sourceURL, to: file)) != nil else { return nil }
        guard let name = register(file) else { return nil }
        installedFontName = name
        return name
    }

    /// Export the installed font (name + file data), for the settings
    /// backup to carry it (P5 takes the backup side; this is the
    /// prerequisite, mirroring Beans).
    static func exportFontData() -> (name: String, data: Data)? {
        guard installedFontName != nil else { return nil }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: fontsDirectory, includingPropertiesForKeys: nil)
        else { return nil }
        for file in files where ["ttf", "otf", "ttc"].contains(file.pathExtension.lowercased()) {
            if let data = try? Data(contentsOf: file) { return (installedFontName ?? "", data) }
        }
        return nil
    }

    /// Restore a font from backup data. Stages + registers the data
    /// BEFORE touching the installed font, so corrupt backup data can
    /// never wipe the font the user already has (P6: the backup
    /// carries the font file, and a hand-edited file may be bad).
    @discardableResult
    static func restoreFont(name: String, data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let staging = fontsDirectory.appendingPathComponent("golia-restored-font-staging.ttf")
        do { try data.write(to: staging, options: .atomic) } catch { return false }
        guard register(staging) != nil else {
            try? FileManager.default.removeItem(at: staging)
            return false
        }
        let file = fontsDirectory.appendingPathComponent("golia-restored-font.ttf")
        try? FileManager.default.removeItem(at: file)
        do { try FileManager.default.moveItem(at: staging, to: file) } catch { return false }
        // Already registered in-process from the staging file (same
        // bytes); launch re-registers from this path.
        if let files = try? FileManager.default.contentsOfDirectory(
            at: fontsDirectory, includingPropertiesForKeys: nil) {
            for f in files where f != file { try? FileManager.default.removeItem(at: f) }
        }
        installedFontName = name
        return true
    }

    static func clear() {
        installedFontName = nil
        if let files = try? FileManager.default.contentsOfDirectory(
            at: fontsDirectory, includingPropertiesForKeys: nil) {
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
    }

    @discardableResult
    private static func register(_ url: URL) -> String? {
        // Read via Data to avoid security-scope / CGDataProvider(url:)
        // issues on iOS (same reason as Beans).
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let provider = CGDataProvider(data: data as CFData),
              let font = CGFont(provider)
        else { return nil }
        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterGraphicsFont(font, &error) else { return nil }
        return font.postScriptName as String?
    }
}
