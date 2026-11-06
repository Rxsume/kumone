import SwiftUI

/// One sRGB colour, the `Codable` form of a `Color`.
///
/// `SwiftUI.Color` is not `Codable`, so themes persist as plain RGBA doubles
/// and convert back with ``ThemeColor/color``.
struct ThemeColor: Codable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.alpha = min(max(alpha, 0), 1)
    }

    /// Best-effort readback of a `Color`'s sRGB components. Colours that do
    /// not resolve to RGB (e.g. dynamic system colours) read as opaque black.
    init(_ color: Color) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        #if os(iOS)
        let resolved = UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        if resolved {
            self.init(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
        } else {
            self.init(red: 0, green: 0, blue: 0, alpha: 1)
        }
        #else
        // AppKit's getRed returns Void (no success flag); colours that do
        // not resolve to RGB leave the initial values untouched, which are
        // already opaque black — the documented fallback.
        NSColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(red: Double(red), green: Double(green), blue: Double(blue), alpha: Double(alpha))
        #endif
    }

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}

/// A colour theme preset: an accent colour plus a background tint colour.
///
/// Built-in presets are the five entries in ``ThemePreset/builtInPresets``;
/// a user-made theme is a `ThemePreset` with `id == "custom"`, persisted as
/// JSON in `SettingsManager.customThemeJSON` (see ``ThemePreset/decodeCustomTheme(from:)``).
/// This type only carries data and resolution rules; it never touches a view.
struct ThemePreset: Codable, Equatable, Hashable, Identifiable {
    var id: String
    var accent: ThemeColor
    var tint: ThemeColor
    /// Background tint strength, same 0.5...1.5 scale as
    /// `SettingsManager.mainWindowAmbientBackgroundIntensityRange`.
    var intensity: Double

    init(id: String, accent: ThemeColor, tint: ThemeColor, intensity: Double = 1) {
        self.id = id
        self.accent = accent
        self.tint = tint
        let range = SettingsManager.mainWindowAmbientBackgroundIntensityRange
        self.intensity = min(max(intensity, range.lowerBound), range.upperBound)
    }

    var displayName: String {
        switch id {
        case "default": return String(localized: "默认")
        case "dusk": return String(localized: "暮色")
        case "ocean": return String(localized: "海洋")
        case "forest": return String(localized: "林深")
        case "rose": return String(localized: "玫瑰")
        case "custom": return String(localized: "自定义")
        default: return id
        }
    }

    // MARK: - Built-in presets

    /// The default preset: the app's existing accent (`Theme.accent`, #EC4949)
    /// over the existing fallback artwork tint (`ArtworkColors.fallback`).
    static let defaultPreset = ThemePreset(
        id: "default",
        accent: ThemeColor(red: 0.925, green: 0.286, blue: 0.286),
        tint: ThemeColor(red: 0.16, green: 0.16, blue: 0.20)
    )

    /// 暮色: terracotta accent over a deep mauve tint.
    static let dusk = ThemePreset(
        id: "dusk",
        accent: ThemeColor(red: 0.878, green: 0.471, blue: 0.337),
        tint: ThemeColor(red: 0.18, green: 0.13, blue: 0.20)
    )

    /// 海洋: bright cyan-blue accent over a deep teal tint.
    static let ocean = ThemePreset(
        id: "ocean",
        accent: ThemeColor(red: 0.184, green: 0.659, blue: 0.788),
        tint: ThemeColor(red: 0.07, green: 0.18, blue: 0.24)
    )

    /// 林深: leaf-green accent over a deep forest tint.
    static let forest = ThemePreset(
        id: "forest",
        accent: ThemeColor(red: 0.373, green: 0.659, blue: 0.361),
        tint: ThemeColor(red: 0.09, green: 0.16, blue: 0.11)
    )

    /// 玫瑰: pink accent over a deep rose tint.
    static let rose = ThemePreset(
        id: "rose",
        accent: ThemeColor(red: 0.91, green: 0.365, blue: 0.541),
        tint: ThemeColor(red: 0.20, green: 0.10, blue: 0.14)
    )

    /// The five built-in presets, in picker order.
    static let builtInPresets: [ThemePreset] = [defaultPreset, dusk, ocean, forest, rose]

    /// Every selectable preset id, including `"custom"`.
    static let allPresetIDs: [String] = ["default", "dusk", "ocean", "forest", "rose", "custom"]

    /// The built-in preset for an id, or ``ThemePreset/defaultPreset`` for
    /// unknown ids (including `"custom"`, which lives in `customThemeJSON`).
    static func preset(id: String) -> ThemePreset {
        builtInPresets.first { $0.id == id } ?? defaultPreset
    }

    // MARK: - Custom theme persistence

    /// Decodes a custom theme from `SettingsManager.customThemeJSON`.
    /// Returns `nil` for an empty or malformed string. The decoded theme's
    /// id is always normalised to `"custom"`.
    static func decodeCustomTheme(from json: String) -> ThemePreset? {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        guard var theme = try? JSONDecoder().decode(ThemePreset.self, from: data) else { return nil }
        theme.id = "custom"
        return theme
    }

    /// The custom theme currently saved in settings, if any.
    @MainActor
    static func customTheme(from settings: SettingsManager) -> ThemePreset? {
        decodeCustomTheme(from: settings.customThemeJSON)
    }

    /// Encodes this theme as the JSON string stored in
    /// `SettingsManager.customThemeJSON`. Returns `nil` if encoding fails.
    func encodeToJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// The colours a view actually paints with, after presets, the custom theme
/// and the current song's artwork palette have been resolved.
struct ResolvedTheme: Equatable {
    enum Source: Equatable {
        /// A built-in preset (its id) or the default preset.
        case preset(String)
        /// The current song's artwork palette.
        case artwork
        /// The saved custom theme.
        case custom
    }

    /// Accent colour for controls and highlights.
    var accent: Color
    /// Background tint colour.
    var tint: Color
    /// Secondary background tint colour.
    var secondaryTint: Color
    /// Background tint strength, 0.5...1.5.
    var intensity: Double
    var source: Source
}

extension ThemePreset {
    /// Resolves the effective theme for the given settings and artwork
    /// palette (`nil` when no song/artwork is available). Priority:
    ///
    /// 1. Custom theme — when one is saved and either
    ///    `settings.preferCustomTheme` is on or the selected preset itself
    ///    is `"custom"`.
    /// 2. Song theme — when `settings.songThemeAutoSwitch` is on and a
    ///    palette is available; the artwork's primary colour becomes both
    ///    the accent and the tint, its secondary colour the secondary tint.
    /// 3. The selected preset (`settings.themePresetID`); an unknown id, or
    ///    `"custom"` with no saved theme, falls back to the default preset.
    ///
    /// The default preset resolves to the existing colours: `Theme.accent`
    /// with `ArtworkColors.fallback`.
    @MainActor
    static func resolvedTheme(settings: SettingsManager, palette: ArtworkColors?) -> ResolvedTheme {
        if let custom = customTheme(from: settings),
           settings.preferCustomTheme || settings.themePresetID == "custom" {
            return ResolvedTheme(
                accent: custom.accent.color,
                tint: custom.tint.color,
                secondaryTint: custom.tint.color.opacity(0.6),
                intensity: custom.intensity,
                source: .custom
            )
        }

        if settings.songThemeAutoSwitch, let palette {
            return ResolvedTheme(
                accent: palette.primary,
                tint: palette.primary,
                secondaryTint: palette.secondary,
                intensity: 1,
                source: .artwork
            )
        }

        let preset = preset(id: settings.themePresetID)
        if preset.id == "default" {
            return ResolvedTheme(
                accent: Theme.accent,
                tint: ArtworkColors.fallback.primary,
                secondaryTint: ArtworkColors.fallback.secondary,
                intensity: preset.intensity,
                source: .preset("default")
            )
        }
        return ResolvedTheme(
            accent: preset.accent.color,
            tint: preset.tint.color,
            secondaryTint: preset.tint.color.opacity(0.6),
            intensity: preset.intensity,
            source: .preset(preset.id)
        )
    }
}
