import Foundation

/// Settings backup / restore: export all user settings to a JSON file,
/// import one back.
///
/// Scope is SETTINGS ONLY — every `settings.*` UserDefaults key the app
/// knows (see `allowedKeys`), plus the updater's dismissal key.
/// Deliberately NOT included:
/// - Keychain logins, tokens and cookies (NetEase / QQ / Kugou sessions,
///   passwords) — never read, never written, never exported.
/// - User-supplied credentials: the FN / Spotify / Apple Music
///   credential keys were removed from the app entirely (PR #27),
///   so they can never appear in a backup; an old file that still
///   lists one is ignored as an unknown key on import.
/// - Anything that is not a setting: playlists, favorites, downloads,
///   cached audio, player volume/repeat state, calibration data.
/// - The uploaded background image FILE itself: only its file name
///   (`settings.uploadedBackgroundImageName`) is exported. Restoring
///   on a device without that file leaves a dangling name; the
///   background store treats a missing file as "no image". The same
///   holds for the Beans-port wallpaper FILES: only their stored
///   paths (`settings.backgroundImagePathLight/Dark`,
///   `settings.wallpaperPaths`) are exported, never the files.
///
/// Format (human-readable JSON):
/// ```
/// {
///   "format": "golia-settings-backup", "formatVersion": 1,
///   "app": "Golia", "appVersion": "0.3.29", "build": "693",
///   "exportedAt": "2026-11-08T14:00:00Z",
///   "settings": { "settings.audioQuality": "exhigh", ... },
///   "font": { "name": "MyFont", "data": "<base64>" }  // optional:
///     // the single user-installed font, if one is installed (P6:
///     // `FontManager.exportFontData`). Absent when no font is
///     // installed; old files without it still import fine.
/// }
/// ```
/// `Data` values (only `settings.urlBackgroundList`) are stored as
/// `{"__base64Data": "<base64>"}` so the file stays plain JSON.
///
/// Safety on import: a wrong-typed value can at worst make that one
/// setting fall back to its default — `SettingsManager` reads every key
/// with a typed accessor, so a stray string in a Bool key is ignored,
/// never a crash. Unknown keys are silently skipped.
enum SettingsBackup {
    static let formatIdentifier = "golia-settings-backup"
    static let formatVersion = 1

    /// The updater's dismissal key (`settings.dismissedUpdateRelease`,
    /// owned by `IOSUpdater`, same namespace as the rest).
    static let dismissedUpdateReleaseKey = "settings.dismissedUpdateRelease"

    /// Every settings key a backup may carry: the full `Keys` enum
    /// (generated from SettingsManager.swift) plus the updater's
    /// dismissal key and `PlatformPreferenceStore`'s three keys — minus
    /// the 7 keys the Folia rollback deleted (themePreset, customTheme,
    /// preferCustomTheme, songThemeAutoSwitch, preferredLyricSource,
    /// autoHidePlayerChrome, iosCrossfadeEnabled) and
    /// `neteaseScrobbleEnabled` (deleted by the Beans settings port),
    /// which must never be re-added here. The Beans settings port's
    /// own new keys (playback, accent, tab bar, wallpaper, font) are
    /// in the list; `settings.customAudioSources` is NOT — it is not a
    /// `SettingsManager` key and must never be backed up (the user's
    /// imported script, and its key, live only on their device).
    /// A restore silently ignores any key not in this set, so a foreign or hand-edited file cannot inject
    /// anything the app does not already know. The FN / Spotify /
    /// Apple Music credential keys no longer exist in the app, so they
    /// cannot appear here either.
    static let allowedKeys: Set<String> = [
        "settings.alwaysShowPlayerBackButton",
        "settings.alwaysShowTrackSwitchButtons",
        "settings.appearance",
        "settings.audioCacheAutomatic",
        "settings.audioCacheLimit",
        "settings.audioCacheSizeMB",
        "settings.audioQuality",
        "settings.autoCheckUpdates",
        "settings.autoHidePlayerChrome",
        "settings.autoResumeLastPlayback",
        "settings.autoSkipUnplayable",
        "settings.automixEnabled",
        "settings.automixOrder",
        "settings.automixStems",
        "settings.automixTransitions",
        "settings.backgroundHexDark",
        "settings.backgroundHexLight",
        "settings.backgroundImagePathDark",
        "settings.backgroundImagePathLight",
        "settings.backgroundSyncAll",
        "settings.classicAvoidOverlap",
        "settings.classicBreathingFloat",
        "settings.classicWordRotation",
        "settings.classicWordSpacing",
        "settings.commonDisableGeometric",
        "settings.commonDisableVignette",
        "settings.commonOpacity",
        "settings.commonUseCoverColorBg",
        "settings.crossfadeMaxSeconds",
        "settings.customAccentHex",
        "settings.customFontName",
        "settings.desktopLyricsCentered",
        "settings.dismissedUpdateRelease",
        "settings.enableAudioCache",
        "settings.enableUnblock",
        "settings.enabledHomePlatforms.v1",
        "settings.enabledUnblockSources",
        "settings.fmMode",
        "settings.foliaEnabled",
        "settings.globalLyricTimelineOffsetMs",
        "settings.hidePlayerProgressBar",
        "settings.hideTranslationSubtitle",
        "settings.homeDynamicBackground",
        "settings.homePlatform",
        "settings.homePlatformOrder.v1",
        "settings.homePlatformsSeen.v1",
        "settings.homeWallpaperBlur",
        "settings.landscapeNowPlayingStyle",
        "settings.latentColorSource",
        "settings.latentDisplayMode",
        "settings.latentDitheringAudioSpeed",
        "settings.latentDitheringOpacity",
        "settings.latentDitheringSize",
        "settings.latentDitheringSpeed",
        "settings.latentDynamicOnlyInPlayer",
        "settings.latentEnhancedBeatResponse",
        "settings.latentMeshAudioSpeed",
        "settings.latentMeshDistortion",
        "settings.latentMeshSpeed",
        "settings.latentMeshSwirl",
        "settings.latentOverlayEnabled",
        "settings.latentOverlayOpacity",
        "settings.legacyTabBarCornerRadius",
        "settings.legacyTabBarOffsetX",
        "settings.legacyTabBarOffsetY",
        "settings.legacyTabBarWidth",
        "settings.loudnessCompensation",
        "settings.lyricAnimationStyle",
        "settings.lyricsAnnotation",
        "settings.lyricsCustomFont",
        "settings.lyricsFontScale",
        "settings.lyricsFontStyle",
        "settings.lyricsFontWeight",
        "settings.mainWindowAmbientBackgroundIntensity",
        "settings.mixWithOtherAudio",
        "settings.monetBackgroundBlurPx",
        "settings.monetBackgroundDriftEnabled",
        "settings.monetBackgroundDriftStrength",
        "settings.monetBackgroundGrayscale",
        "settings.monetBackgroundHalfPaneOffsetX",
        "settings.monetBackgroundLayout",
        "settings.monetBackgroundOverlayOpacity",
        "settings.monetBackgroundSaturation",
        "settings.monetBackgroundSource",
        "settings.monetBackgroundStreaksEnabled",
        "settings.monetBackgroundWash",
        "settings.monetBackgroundWashColorMode",
        "settings.monetBackgroundWashCustomColor",
        "settings.nomandDitheringColorSteps",
        "settings.nomandDitheringInverted",
        "settings.nomandDitheringOriginalColors",
        "settings.nomandDitheringSize",
        "settings.nomandDitheringType",
        "settings.nomandEffect",
        "settings.nomandFlutedGlassBlur",
        "settings.nomandFlutedGlassDistortion",
        "settings.nomandFlutedGlassSize",
        "settings.nomandHalftoneContrast",
        "settings.nomandHalftoneDotsInverted",
        "settings.nomandHalftoneRadius",
        "settings.nomandHalftoneSize",
        "settings.nomandImageSource",
        "settings.nomandLensDistortionBulge",
        "settings.nomandLensDistortionDispersion",
        "settings.nomandLensDistortionSpread",
        "settings.nomandOriginalColors",
        "settings.nomandOverlayEnabled",
        "settings.nomandOverlayOpacity",
        "settings.nomandPaperTextureContrast",
        "settings.nomandPaperTextureFiber",
        "settings.nomandPaperTextureRoughness",
        "settings.nowPlayingMode",
        "settings.openAlbumOnArtworkClick",
        "settings.outputDeviceUID",
        "settings.playbackEntryView",
        "settings.playbackFadeEnabled",
        "settings.playerControlSlots",
        "settings.playerPageNativeBlur",
        "settings.playerPageTintIntensity",
        "settings.preventDisplaySleepDuringPlayback",
        "settings.queueAddBehavior",
        "settings.reduceMotionBackground",
        "settings.reduceMotionMicroMotion",
        "settings.reduceMotionTransitions",
        "settings.replayGainMode",
        "settings.showDesktopLyrics",
        "settings.showLyricsRomaji",
        "settings.showLyricsTranslation",
        "settings.showMainWindowAmbientBackground",
        "settings.showMenuBarPlayer",
        "settings.showThirdPartySourceNotice",
        "settings.soraBlank",
        "settings.stageTrackCardEnabled",
        "settings.staticMode",
        "settings.subtitleBackgroundEnabled",
        "settings.subtitleCustomFont",
        "settings.subtitleFontFollowsLyrics",
        "settings.subtitleFontScale",
        "settings.subtitleFontStyle",
        "settings.subtitleFontWeight",
        "settings.subtitleHarmonyBackgroundEnabled",
        "settings.subtitleHarmonyEnabled",
        "settings.subtitleOverlayOpacity",
        "settings.subtitleUpcomingLineCount",
        "settings.subtitleUpcomingLyricsBlur",
        "settings.tabLabelsVisible",
        "settings.transitionAnimationCard",
        "settings.transitionAnimationRing",
        "settings.transitionMode",
        "settings.uploadedBackgroundImageName",
        "settings.urlBackgroundList",
        "settings.urlBackgroundSelectedID",
        "settings.verbatimLyrics",
        "settings.visualizerBackgroundMode",
        "settings.visualizerOpacity",
        "settings.volume",
        "settings.wallpaperPaths",
    ]

    enum ImportError: LocalizedError, Equatable {
        case malformedJSON
        case wrongFormat
        case unsupportedVersion(Int)
        case missingSettings

        var errorDescription: String? {
            switch self {
            case .malformedJSON:
                return String(localized: "文件不是有效的 JSON，无法恢复")
            case .wrongFormat:
                return String(localized: "这不是 Golia 的设置备份文件")
            case .unsupportedVersion(let v):
                return String(localized: "备份文件版本 \(v) 太新，请先更新 Golia 再恢复")
            case .missingSettings:
                return String(localized: "备份文件里没有设置内容")
            }
        }
    }

    /// A backup file that passed validation, ready for the user to
    /// confirm before anything is written.
    struct ValidatedBackup {
        /// Key -> value, already filtered to known keys and type-checked.
        let values: [String: Any]
        /// Keys in the file that are not in `allowedKeys` (ignored).
        let unknownKeyCount: Int
        /// Keys in the file whose value had the wrong type (ignored).
        let typeMismatchCount: Int
        /// The installed font carried by the file, if any (name +
        /// file data). A malformed `font` entry is ignored, never a
        /// validation failure — the settings still restore.
        let font: (name: String, data: Data)?
        let appVersion: String?
        let build: String?
        let exportedAt: Date?
    }

    struct ImportResult {
        let appliedCount: Int
        let skippedUnknownCount: Int
        let skippedTypeMismatchCount: Int
        /// True when the file carried a font and it installed.
        let fontRestored: Bool
    }

    // MARK: - Export

    /// "Golia-Settings-Backup-20261108-220000.json" (local time, no
    /// characters a filesystem would reject).
    static func exportFileName(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "Golia-Settings-Backup-\(f.string(from: date)).json"
    }

    /// Build the backup file's bytes, or nil when nothing could be read.
    /// Only keys present in UserDefaults are exported (a fresh install
    /// exports almost nothing — that is correct, defaults need no backup).
    static func exportData() -> Data? {
        let defaults = UserDefaults.standard
        var settings: [String: Any] = [:]
        for (key, value) in defaults.dictionaryRepresentation() {
            guard allowedKeys.contains(key) else { continue }
            if let data = value as? Data {
                settings[key] = ["__base64Data": data.base64EncodedString()]
            } else if isJSONValue(value) {
                settings[key] = value
            }
            // Anything else (not JSON-representable) is skipped.
        }
        let info = Bundle.main.infoDictionary
        var doc: [String: Any] = [
            "format": formatIdentifier,
            "formatVersion": formatVersion,
            "app": "Golia",
            "appVersion": info?["CFBundleShortVersionString"] as? String ?? "dev",
            "build": info?["CFBundleVersion"] as? String ?? "",
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "settings": settings,
        ]
        // The single installed font, if any (P6). One font only, so
        // the file stays small; a CJK font can still be several MB
        // of base64 — accepted, it is the user's font.
        if let font = FontManager.exportFontData() {
            doc["font"] = [
                "name": font.name,
                "data": font.data.base64EncodedString(),
            ]
        }
        return try? JSONSerialization.data(
            withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Import

    /// Parse and validate without writing anything. The caller shows the
    /// counts to the user and calls `apply(_:)` only after confirmation.
    static func validate(_ data: Data) throws -> ValidatedBackup {
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ImportError.malformedJSON
        }
        guard let doc = obj as? [String: Any] else { throw ImportError.malformedJSON }
        guard doc["format"] as? String == formatIdentifier else { throw ImportError.wrongFormat }
        let version = doc["formatVersion"] as? Int ?? -1
        guard version == formatVersion else { throw ImportError.unsupportedVersion(version) }
        guard let rawSettings = doc["settings"] as? [String: Any] else {
            throw ImportError.missingSettings
        }

        let defaults = UserDefaults.standard
        var values: [String: Any] = [:]
        var unknown = 0
        var mismatched = 0
        for (key, value) in rawSettings {
            guard allowedKeys.contains(key) else { unknown += 1; continue }
            guard let checked = checkedValue(value, forKey: key, current: defaults.object(forKey: key)) else {
                mismatched += 1
                continue
            }
            values[key] = checked
        }
        let exportedAt = (doc["exportedAt"] as? String)
            .flatMap { ISO8601DateFormatter().date(from: $0) }
        // Optional installed font: malformed entries are ignored
        // (never a validation failure — the settings still restore).
        let font: (name: String, data: Data)? = {
            guard let dict = doc["font"] as? [String: Any],
                  dict.count == 2,
                  let name = dict["name"] as? String, !name.isEmpty,
                  let b64 = dict["data"] as? String,
                  let data = Data(base64Encoded: b64), !data.isEmpty
            else { return nil }
            return (name, data)
        }()
        return ValidatedBackup(
            values: values,
            unknownKeyCount: unknown,
            typeMismatchCount: mismatched,
            font: font,
            appVersion: doc["appVersion"] as? String,
            build: doc["build"] as? String,
            exportedAt: exportedAt
        )
    }

    /// Write a validated backup into UserDefaults and make the running
    /// app pick it up (no restart). Must be called on the main actor.
    @MainActor
    static func apply(_ backup: ValidatedBackup) -> ImportResult {
        let defaults = UserDefaults.standard
        for (key, value) in backup.values {
            defaults.set(value, forKey: key)
        }
        SettingsManager.shared.reloadFromUserDefaults()
        PlatformPreferenceStore.shared.reloadFromUserDefaults()
        // The installed font, if the file carried one.
        // `restoreFont` stages + registers before replacing, so bad
        // data can never wipe the font already installed.
        let fontRestored: Bool = {
            guard let font = backup.font else { return false }
            return FontManager.restoreFont(name: font.name, data: font.data)
        }()
        return ImportResult(
            appliedCount: backup.values.count,
            skippedUnknownCount: backup.unknownKeyCount,
            skippedTypeMismatchCount: backup.typeMismatchCount,
            fontRestored: fontRestored
        )
    }

    /// Validate + apply in one step (used by tests and by any caller
    /// that already confirmed with the user).
    @MainActor
    static func importData(_ data: Data) throws -> ImportResult {
        try apply(validate(data))
    }

    // MARK: - Value checks

    /// `Data` is the only non-JSON value a setting can hold
    /// (`settings.urlBackgroundList`, JSON-encoded). It travels as
    /// `{"__base64Data": ...}` and is only accepted for that one key.
    private static func checkedValue(
        _ value: Any, forKey key: String, current: Any?
    ) -> Any? {
        if let dict = value as? [String: Any] {
            guard dict.count == 1,
                  let b64 = dict["__base64Data"] as? String,
                  key == SettingsManager.Keys.urlBackgroundList,
                  let data = Data(base64Encoded: b64)
            else { return nil }
            return data
        }
        guard isJSONValue(value), !(value is NSNull) else { return nil }
        // A nested container is not a setting value.
        if value is [String: Any] { return nil }
        if let array = value as? [Any] {
            // The only array settings are string arrays
            // (`enabledAudioSourceIDs`, `playerControlSlots`).
            guard array.allSatisfy({ $0 is String }) else { return nil }
            if let currentArray = current as? [Any] {
                guard currentArray.allSatisfy({ $0 is String }) else { return nil }
            }
            return array
        }
        // Scalar: when the key already has a value, require the same
        // family (Bool / number / string). When it has none, accept
        // the JSON scalar as-is — a wrong family then just makes that
        // one setting read its default (typed accessors ignore it).
        if let current {
            guard jsonFamily(of: value) == jsonFamily(of: current) else { return nil }
        }
        return value
    }

    /// Bool must be checked before NSNumber: a JSON `true` bridges to
    /// both `Bool` and `NSNumber` (CFBoolean).
    private enum JSONFamily { case bool, number, string }

    private static func jsonFamily(of value: Any) -> JSONFamily? {
        if value is Bool { return .bool }
        if value is NSNumber { return .number }
        if value is String { return .string }
        return nil
    }

    private static func isJSONValue(_ value: Any) -> Bool {
        if value is NSNull { return false }
        if value is String || value is NSNumber || value is Data { return true }
        if let array = value as? [Any] { return array.allSatisfy(isJSONValue) }
        if let dict = value as? [String: Any] {
            return dict.values.allSatisfy(isJSONValue)
        }
        return false
    }
}
