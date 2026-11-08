import Testing
@testable import KumoneCore
import Foundation

/// Coverage for settings backup / restore (`SettingsBackup`):
/// export contents, round-trip restore, and rejection of foreign or
/// mistyped files.
///
/// The tests mutate the shared `SettingsManager` (and its UserDefaults
/// backing store), so the suite is serial and every test restores the
/// values it found on entry.
@Suite(.serialized)
@MainActor
struct SettingsBackupTests {

    // MARK: - Snapshot / restore

    /// The handful of settings these tests touch, as found on entry.
    private struct Snapshot {
        var audioQuality: AudioQuality
        var enableAudioCache: Bool
        var audioCacheSizeMB: Int
        var themePresetID: String
        var appleMusicDeveloperToken: String
        var spotifyClientID: String
        var fnmusicUsername: String

        static func take() -> Snapshot {
            let s = SettingsManager.shared
            return Snapshot(
                audioQuality: s.audioQuality,
                enableAudioCache: s.enableAudioCache,
                audioCacheSizeMB: s.audioCacheSizeMB,
                themePresetID: s.themePresetID,
                appleMusicDeveloperToken: s.appleMusicDeveloperToken,
                spotifyClientID: s.spotifyClientID,
                fnmusicUsername: s.fnmusicUsername
            )
        }

        func restore() {
            let s = SettingsManager.shared
            s.audioQuality = audioQuality
            s.enableAudioCache = enableAudioCache
            s.audioCacheSizeMB = audioCacheSizeMB
            s.themePresetID = themePresetID
            s.appleMusicDeveloperToken = appleMusicDeveloperToken
            s.spotifyClientID = spotifyClientID
            s.fnmusicUsername = fnmusicUsername
        }
    }

    private func backupDoc(settings: [String: Any]) -> Data {
        let doc: [String: Any] = [
            "format": SettingsBackup.formatIdentifier,
            "formatVersion": SettingsBackup.formatVersion,
            "app": "Golia",
            "appVersion": "0.3.29",
            "build": "693",
            "exportedAt": "2026-11-08T14:00:00Z",
            "settings": settings,
        ]
        return try! JSONSerialization.data(withJSONObject: doc)
    }

    // MARK: - Tests

    @Test("export contains changed settings and never credentials")
    func exportExcludesCredentials() {
        let snap = Snapshot.take()
        defer { snap.restore() }
        let s = SettingsManager.shared
        s.audioQuality = .lossless
        s.appleMusicDeveloperToken = "secret-jwt"
        s.spotifyClientID = "secret-client-id"
        s.fnmusicUsername = "someone"

        let data = try! #require(SettingsBackup.exportData())
        let doc = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(doc["format"] as? String == SettingsBackup.formatIdentifier)
        #expect(doc["formatVersion"] as? Int == SettingsBackup.formatVersion)
        let settings = doc["settings"] as! [String: Any]
        #expect(settings["settings.audioQuality"] as? String == "lossless")
        for key in SettingsBackup.excludedKeys {
            #expect(settings[key] == nil, "credential key \(key) leaked into export")
        }
    }

    @Test("export -> change -> import restores the exported values")
    func roundTrip() throws {
        let snap = Snapshot.take()
        defer { snap.restore() }
        let s = SettingsManager.shared
        s.audioQuality = .hires
        s.enableAudioCache = false
        s.themePresetID = "test-preset"

        let data = try #require(SettingsBackup.exportData())
        s.audioQuality = .standard
        s.enableAudioCache = true
        s.themePresetID = "other-preset"

        let result = try SettingsBackup.importData(data)
        #expect(result.appliedCount > 0)
        #expect(s.audioQuality == .hires)
        #expect(s.enableAudioCache == false)
        #expect(s.themePresetID == "test-preset")
    }

    @Test("foreign files are rejected, unknown keys are ignored")
    func foreignFiles() throws {
        let snap = Snapshot.take()
        defer { snap.restore() }

        // Not JSON at all.
        #expect(throws: SettingsBackup.ImportError.malformedJSON) {
            try SettingsBackup.validate(Data("not json".utf8))
        }
        // Valid JSON, wrong format.
        let wrong = try! JSONSerialization.data(withJSONObject: [
            "format": "something-else", "formatVersion": 1, "settings": [:],
        ])
        #expect(throws: SettingsBackup.ImportError.wrongFormat) {
            try SettingsBackup.validate(wrong)
        }
        // Right format, only unknown keys: validates, applies nothing.
        let unknown = backupDoc(settings: [
            "settings.notARealKey": true,
            "player.volume": 0.5,
        ])
        let validated = try SettingsBackup.validate(unknown)
        #expect(validated.values.isEmpty)
        #expect(validated.unknownKeyCount == 2)
    }

    @Test("wrong-typed values are skipped, good ones still apply")
    func typeMismatchSkipped() throws {
        let snap = Snapshot.take()
        defer { snap.restore() }
        let s = SettingsManager.shared
        s.audioQuality = .exhigh
        s.themePresetID = "before"

        // audioQuality as a number (current value is a string) is a
        // mismatch; themePresetID as a string is fine.
        let doc = backupDoc(settings: [
            "settings.audioQuality": 123,
            "settings.themePreset": "restored-preset",
        ])
        let result = try SettingsBackup.importData(doc)
        #expect(result.skippedTypeMismatchCount == 1)
        #expect(s.audioQuality == .exhigh)
        #expect(s.themePresetID == "restored-preset")
    }
}
