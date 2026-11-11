import Testing
@testable import KumoneCore
import Foundation

/// Coverage for the Folia theme system (`ThemePreset` / `ResolvedTheme` /
/// `ThemeShareDocument`): preset lookup, custom-theme encode/decode and
/// the backup/import text forms.
///
/// Pure logic — no `SettingsManager.shared` mutation, so this suite needs
/// no serialisation and no snapshot/restore. Anything that resolves
/// against live settings lives in `FoliaMasterSwitchTests`
/// (`resolvedThemeFollowsMasterSwitch`), which owns the shared singleton.
struct ThemePresetTests {

    private var sampleCustomTheme: ThemePreset {
        ThemePreset(
            id: "custom",
            accent: ThemeColor(red: 1, green: 0, blue: 0),
            tint: ThemeColor(red: 0, green: 0, blue: 1),
            intensity: 1.2
        )
    }

    // MARK: - ThemeColor

    @Test func themeColorClampsComponents() {
        let clamped = ThemeColor(red: 2, green: -1, blue: 0.5, alpha: 3)
        #expect(clamped.red == 1)
        #expect(clamped.green == 0)
        #expect(clamped.blue == 0.5)
        #expect(clamped.alpha == 1)
    }

    // MARK: - Built-in presets

    @Test func allPresetIDsAreInPickerOrder() {
        #expect(ThemePreset.allPresetIDs == ["default", "dusk", "ocean", "forest", "rose", "custom"])
        #expect(ThemePreset.builtInPresets.map(\.id) == ["default", "dusk", "ocean", "forest", "rose"])
    }

    @Test func presetLookupFallsBackToDefault() {
        #expect(ThemePreset.preset(id: "ocean").id == "ocean")
        #expect(ThemePreset.preset(id: "rose").displayName == "玫瑰")
        #expect(ThemePreset.preset(id: "custom").id == "default")
        #expect(ThemePreset.preset(id: "no-such-preset").id == "default")
        #expect(ThemePreset.defaultPreset.displayName == "默认")
    }

    // MARK: - Custom theme encode / decode

    @Test func customThemeRoundTripsThroughJSON() {
        let theme = sampleCustomTheme
        let json = try! #require(theme.encodeToJSON())
        let decoded = try! #require(ThemePreset.decodeCustomTheme(from: json))
        #expect(decoded == theme)
        #expect(decoded.id == "custom")
    }

    @Test func decodeCustomThemeRejectsEmptyAndMalformed() {
        #expect(ThemePreset.decodeCustomTheme(from: "") == nil)
        #expect(ThemePreset.decodeCustomTheme(from: "not json") == nil)
        #expect(ThemePreset.decodeCustomTheme(from: "{\"id\":\"custom\"}") == nil)
    }

    @Test func decodeCustomThemeNormalizesIDAndClampsIntensity() {
        let json = "{\"id\":\"whatever\",\"accent\":{\"red\":1,\"green\":0,\"blue\":0,\"alpha\":1},\"tint\":{\"red\":0,\"green\":0,\"blue\":1,\"alpha\":1},\"intensity\":9}"
        let decoded = try! #require(ThemePreset.decodeCustomTheme(from: json))
        #expect(decoded.id == "custom")
        #expect(decoded.intensity == 1.5)
    }

    // MARK: - Share document: JSON form

    @Test func shareDocumentRoundTripsThroughJSON() {
        let theme = sampleCustomTheme
        let document = ThemeShareDocument.export(theme: theme, lyricAnimationStyle: .karaokeZoom)
        let json = try! #require(document.jsonText())
        let imported = try! #require(ThemeShareDocument.importDocument(from: json))
        #expect(imported == document)
        #expect(imported.theme == theme)
        #expect(imported.lyricAnimationStyle == "karaokeZoom")
    }

    @Test func shareDocumentWithoutThemeCarriesOnlyTheLyricStyle() {
        let document = ThemeShareDocument.export(theme: nil, lyricAnimationStyle: .lineHighlight)
        let json = try! #require(document.jsonText())
        let imported = try! #require(ThemeShareDocument.importDocument(from: json))
        #expect(imported.theme == nil)
        #expect(imported.lyricAnimationStyle == "lineHighlight")
    }

    // MARK: - Share document: folia-theme text form

    @Test func shareDocumentRoundTripsThroughFoliaThemeText() {
        let theme = sampleCustomTheme
        let document = ThemeShareDocument.export(theme: theme, lyricAnimationStyle: .fade)
        let text = try! #require(document.foliaThemeText())
        #expect(text.hasPrefix(ThemeShareDocument.foliaThemePrefix))
        let imported = try! #require(ThemeShareDocument.importDocument(from: text))
        #expect(imported == document)
    }

    @Test func shareDocumentImportAcceptsBareThemeJSON() {
        let theme = sampleCustomTheme
        let bare = try! #require(theme.encodeToJSON())
        let imported = try! #require(ThemeShareDocument.importDocument(from: bare))
        #expect(imported.theme == theme)
        #expect(imported.lyricAnimationStyle == nil)
    }

    @Test func shareDocumentImportRejectsGarbageAndWrongVersion() {
        #expect(ThemeShareDocument.importDocument(from: "") == nil)
        #expect(ThemeShareDocument.importDocument(from: "hello world") == nil)
        let theme = sampleCustomTheme
        let themeJSON = try! #require(theme.encodeToJSON())
        let wrongVersion = "{\"format\": \"golia-theme\", \"formatVersion\": 99, \"theme\": \(themeJSON), \"lyricAnimationStyle\": \"fade\"}"
        #expect(ThemeShareDocument.importDocument(from: wrongVersion) == nil)
    }
}
