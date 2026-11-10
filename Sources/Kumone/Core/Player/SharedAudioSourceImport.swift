import Foundation

/// Imports an audio-source script shared into the app via the system
/// "Open in Golia" path (share sheet / Files app).
///
/// No Share Extension, no App Groups: the app declares
/// `CFBundleDocumentTypes` for `.js` / `.txt` in
/// `ios/Config/Info.plist`, and the iOS root view (`IOSMainWindow`)
/// forwards opened URLs here via `.onOpenURL`.
///
/// Imported scripts live only on device (see
/// `CustomAudioSourceStore`); the store blob is permanently excluded
/// from SettingsBackup, so a shared script that contains a private
/// key never leaves the device through a backup. Nothing here logs
/// script content — only the source name reaches the toast.
///
/// `.py` files are deliberately NOT declared or imported: the app
/// has no Python runtime, so a Python source cannot run until it is
/// converted to JS.
enum SharedAudioSourceImport {
    /// Result of a share import, for the toast and for tests.
    enum Outcome: Equatable {
        /// Added to the store, enabled by default.
        case imported(name: String)
        /// A source with the same name or the same script text is
        /// already in the store (including the built-in ikun source).
        case duplicate(name: String)
        /// Not a readable LX script file.
        case invalid
    }

    /// Handles a URL delivered by `.onOpenURL`: reads the file under
    /// its security scope, imports it, and shows the toast. Call
    /// from the main actor (the `.onOpenURL` closure).
    @MainActor
    static func handleOpenedURL(_ url: URL) {
        switch importFile(at: url) {
        case .imported(let name):
            ToastCenter.shared.show("已导入自定义音源：\(name)")
        case .duplicate(let name):
            ToastCenter.shared.show("已存在相同音源：\(name)")
        case .invalid:
            ToastCenter.shared.show("不是有效的音源脚本")
        }
    }

    /// Reads + imports the script file at `url` under its security
    /// scope. Pure import logic (no toast), so tests can drive it
    /// through a test store.
    @MainActor
    static func importFile(at url: URL, store: CustomAudioSourceStore = .shared) -> Outcome {
        guard ["js", "txt"].contains(url.pathExtension.lowercased()) else { return .invalid }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
                  ?? String(data: data, encoding: .utf16)
                  ?? String(data: data, encoding: .unicode)
        else { return .invalid }
        return importScript(text: text, fileName: url.deletingPathExtension().lastPathComponent, store: store)
    }

    /// Parses `text` as custom audio source(s) and adds them to
    /// `store`. The name comes from the script's `@name` header,
    /// falling back to `fileName` (see
    /// `CustomAudioSourceImportParser`); garbage text is `.invalid`.
    @MainActor
    static func importScript(text: String, fileName: String, store: CustomAudioSourceStore = .shared) -> Outcome {
        guard let parsed = try? CustomAudioSourceImportParser.parse(text: text, fallbackName: fileName),
              !parsed.isEmpty
        else { return .invalid }
        var importedName: String?
        var duplicateName: String?
        for var source in parsed {
            source.id = UUID().uuidString
            let sameName = store.sources.contains { $0.name == source.name }
            let sameScript = source.script?.isEmpty == false
                && store.sources.contains { $0.script == source.script }
            if sameName || sameScript {
                duplicateName = source.name
                continue
            }
            store.addSources([source])
            if importedName == nil {
                importedName = source.name
            }
        }
        if let importedName {
            return .imported(name: importedName)
        }
        if let duplicateName {
            return .duplicate(name: duplicateName)
        }
        return .invalid
    }
}
