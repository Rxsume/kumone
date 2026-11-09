#if os(iOS)
import UIKit

/// Wallpaper file management, adapted from Beans 2.0.3 `ThemeStore`'s
/// wallpaper half (same storage layout — files under
/// Documents/Wallpapers, paths in UserDefaults — but Golia keys under
/// `settings.*`, and the state itself lives in `SettingsManager`,
/// like P3a/P3b; this enum is only the file I/O, so it stays
/// dependency-free and actor-free: callers assign the returned paths
/// to `SettingsManager` themselves).
///
/// Deliberate deviations from Beans:
/// - No base64 backup of wallpaper data in UserDefaults (Beans keeps
///   one so a reinstall can rebuild files). Golia stores files only;
///   an uninstall wipes them, an app update preserves them. The
///   settings backup (P5) can carry the files if wanted.
/// - One active wallpaper per appearance (light/dark), same as Beans.
enum WallpaperStore {
    static var wallpaperDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Save uploaded image data as a new library entry. Returns the
    /// file path, or nil when the data cannot be written.
    static func addWallpaper(data: Data) -> String? {
        let file = wallpaperDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            return nil
        }
        return file.path
    }

    /// Delete a library entry's file. Callers remove the path from
    /// `settings.wallpaperPaths` and clear it as the active wallpaper
    /// if it was active.
    static func deleteWallpaper(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Load a wallpaper image for display (library grid / background).
    /// Files are user photos; a missing file reads as nil.
    static func image(at path: String) -> UIImage? {
        guard !path.isEmpty else { return nil }
        return UIImage(contentsOfFile: path)
    }

    /// Drop library entries whose files are gone (e.g. deleted outside
    /// the app). Returns the pruned list; callers write it back.
    static func prunedPaths(_ paths: [String]) -> [String] {
        paths.filter { FileManager.default.fileExists(atPath: $0) }
    }
}
#endif
