// Sources/Kumone/Core/Storage/VisualizerBackgroundImageStore.swift
//
// Storage for the single user-uploaded background image shared by the
// monet + nomand backgrounds (Folia's `monet_background_image`, kept in
// IndexedDB there; a single global image, not per-song, not per-mode).
//
// The bytes live as one file under Application Support
// (`VisualizerBackgrounds/uploaded-background`); only the file name is
// stored in `SettingsManager.uploadedBackgroundImageName`. No
// photo-library entitlement is involved: the image arrives through the
// system photo picker (`PhotosPicker`), which hands the app the picked
// bytes out-of-process, so the app never needs photo-library access.

import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The uploaded background image: one file, shared by monet + nomand.
enum VisualizerBackgroundImageStore {
    /// The one stored file name. Fixed (not per-upload): a new upload
    /// overwrites the previous image, and clearing it deletes the file.
    static let fileName = "uploaded-background"

    private static let directoryName = "VisualizerBackgrounds"

    static func directory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func fileURL(named name: String) -> URL? {
        directory()?.appendingPathComponent(name, isDirectory: false)
    }

    /// Validates `data` as an image the platform can decode and stores
    /// it, returning the file name to record in settings. Returns nil
    /// when the data is not a decodable image — WebP and SVG are not
    /// decodable by `PlatformImage` on iOS 16, so those uploads are
    /// refused rather than stored as a file that can never render.
    @discardableResult
    static func save(data: Data) -> String? {
        guard PlatformImage(data: data) != nil,
              let directory = directory(),
              let url = fileURL(named: fileName)
        else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    /// The stored image, or nil when there is none (or it cannot load —
    /// a reinstall keeps the settings name but not the file, so callers
    /// must fall back to the cover).
    static func loadImage(named name: String?) -> PlatformImage? {
        guard let name, let url = fileURL(named: name),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return PlatformImage(data: data)
    }

    /// Deletes the stored file. Best-effort: a missing file is not an error.
    static func delete(named name: String?) {
        guard let name, let url = fileURL(named: name) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
