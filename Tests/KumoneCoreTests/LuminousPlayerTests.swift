import Foundation
import Testing

@testable import KumoneCore

/// Pure logic behind the Folia luminous (流光) player, the nomand (漫游)
/// halftone background and the lyric-style window: word states,
/// deterministic layout, CJK layout units, the preview clock loop, and
/// the new settings' defaults. No UI, no player — just the functions the
/// views call.
@Suite struct LuminousPlayerTests {

    // MARK: - Settings defaults

    @Test func classicTuningDefaultsMatchFolia() {
        #expect(SettingsManager.defaultClassicWordRotation == true)
        #expect(SettingsManager.defaultClassicBreathingFloat == 1)
        #expect(SettingsManager.defaultClassicWordSpacing == 0.7)
        #expect(SettingsManager.defaultClassicAvoidOverlap == false)
    }

    @Test func nomandDefaultsMatchFolia() {
        #expect(SettingsManager.defaultVisualizerBackgroundMode == .nomand)
        #expect(SettingsManager.defaultNomandEffect == .halftoneDots)
        #expect(SettingsManager.defaultNomandHalftoneSize == 0.5)
        #expect(SettingsManager.defaultNomandHalftoneRadius == 1.25)
        #expect(SettingsManager.defaultNomandHalftoneContrast == 0.4)
        #expect(SettingsManager.defaultNomandOriginalColors == false)
        #expect(SettingsManager.defaultNomandOverlayOpacity == 0.35)
    }

    @Test func lyricStyleDefaultsMatchFolia() {
        #expect(SettingsManager.defaultLyricsFontStyle == .sans)
        #expect(SettingsManager.defaultLyricsFontScale == 1)
        #expect(SettingsManager.defaultVisualizerOpacity == 1)
        #expect(SettingsManager.defaultSubtitleFontScale == 1)
        #expect(SettingsManager.defaultSubtitleOverlayOpacity == 0.6)
        #expect(SettingsManager.defaultSubtitleUpcomingLyricsBlur == true)
        #expect(SettingsManager.defaultHideTranslationSubtitle == false)
        #expect(SettingsManager.defaultSubtitleFontFollowsLyrics == true)
        #expect(SettingsManager.defaultSubtitleHarmonyEnabled == true)
    }

    @Test func clampedKeepsValuesInsideTheirRange() {
        #expect(SettingsManager.clamped(3, to: 0...2) == 2)
        #expect(SettingsManager.clamped(-1, to: 0...2) == 0)
        #expect(SettingsManager.clamped(1, to: 0...2) == 1)
        #expect(SettingsManager.clamped(0.5, to: SettingsManager.lyricsFontScaleRange) == 0.85)
        #expect(SettingsManager.clamped(2, to: SettingsManager.lyricsFontScaleRange) == 1.4)
    }

    // MARK: - Nomand tuning math

    @Test func halftoneDotSpacingFollowsSize() {
        // size 0.5 -> 16px; the ends of the range: 0.1 -> 25.6px, 1 -> 4px.
        #expect(NomandDitherer.dotSpacing(for: 0.5) == 16)
        #expect(abs(NomandDitherer.dotSpacing(for: 0.1) - 25.6) < 1e-9)
        #expect(NomandDitherer.dotSpacing(for: 1) == 4)
    }

    @Test func halftoneDotSharpnessFollowsRadius() {
        #expect(NomandDitherer.dotSharpness(for: 1.25) == 0.625)
        #expect(NomandDitherer.dotSharpness(for: 0.1) == 0.05)
        #expect(NomandDitherer.dotSharpness(for: 2) == 1)
    }

    @Test func halftoneContrastIsOnePlus() {
        #expect(abs(NomandDitherer.contrastValue(for: 0.4) - 1.4) < 1e-9)
        #expect(NomandDitherer.contrastValue(for: 0) == 1)
    }

    // MARK: - Word states

    private func word(_ text: String, start: TimeInterval, duration: TimeInterval) -> LyricWord {
        LyricWord(text: text, start: start, duration: duration)
    }

    private func line(words: [(String, TimeInterval, TimeInterval)]) -> LyricLine {
        let made = words.map { word($0.0, start: $0.1, duration: $0.2) }
        return LyricLine(
            id: 0,
            time: made.first?.start ?? 0,
            end: made.last?.end ?? 0,
            text: made.map(\.text).joined(),
            words: made
        )
    }

    @Test func wordStateBoundaries() {
        // Word "清楚" sings 10...12, with the 0.15s lookahead.
        let target = word("清楚", start: 10, duration: 2)
        #expect(LuminousLyrics.state(of: target, at: 9.84) == .waiting)
        #expect(LuminousLyrics.state(of: target, at: 9.85) == .active)
        #expect(LuminousLyrics.state(of: target, at: 11) == .active)
        #expect(LuminousLyrics.state(of: target, at: 11.99) == .active)
        #expect(LuminousLyrics.state(of: target, at: 12) == .passed)
    }

    @Test func wordStateLooksAheadOfTheWordStart() {
        let target = word("你", start: 5, duration: 1)
        #expect(LuminousLyrics.state(of: target, at: 4.84) == .waiting)
        #expect(LuminousLyrics.state(of: target, at: 4.85) == .active)
    }

    @Test func renderProfileSpansLookaheadToLastWordEnd() {
        let profile = LuminousLyrics.renderProfile(for: line(words: [("hello", 10, 2), ("world", 12, 2)]))
        #expect(profile.lookahead == 0.15)
        #expect(profile.activeEnd == 14)
        #expect(abs(profile.displayDuration - 4.15) < 1e-9)
    }

    @Test func displayDurationIncludesTheLookahead() {
        #expect(abs(LuminousLyrics.displayDuration(of: word("清楚", start: 10, duration: 2)) - 2.15) < 1e-9)
    }

    // MARK: - Deterministic layout

    @Test func sameSeedGivesTheSameLayoutTwice() {
        let first = (0..<8).map { LuminousLyrics.placement(seed: 0.7, index: $0, rotationEnabled: true) }
        let second = (0..<8).map { LuminousLyrics.placement(seed: 0.7, index: $0, rotationEnabled: true) }
        #expect(first == second)
    }

    @Test func differentSeedsGiveDifferentLayouts() {
        let a = (0..<8).map { LuminousLyrics.placement(seed: 0.7, index: $0, rotationEnabled: true) }
        let b = (0..<8).map { LuminousLyrics.placement(seed: 11.5, index: $0, rotationEnabled: true) }
        #expect(a != b)
    }

    @Test func placementStaysInsideTheFoliaRanges() {
        for index in 0..<20 {
            let placement = LuminousLyrics.placement(seed: 11.5, index: index, rotationEnabled: true)
            #expect(abs(placement.x) <= 20)
            #expect(abs(placement.y) <= 20)
            #expect(abs(placement.rotate) <= 5)
            #expect(placement.scale >= 1.1 && placement.scale <= 1.3)
            #expect(abs(placement.passedRotate) <= 22.5)
        }
    }

    @Test func rotationDisabledKeepsWordsUpright() {
        let placement = LuminousLyrics.placement(seed: 0.7, index: 3, rotationEnabled: false)
        #expect(placement.rotate == 0)
    }

    @Test func calmPlacementIsCentredAndStill() {
        let placement = LuminousLyrics.placement(seed: 0.7, index: 3, rotationEnabled: true, calm: true)
        #expect(placement == .identity)
        #expect(LuminousLyrics.lineAlignment(seed: 0.7, calm: true) == .center)
    }

    @Test func lineAlignmentRotatesWithTheSeed() {
        // The alignment is a pure function of the seed: the same seed
        // always picks the same side.
        let first = LuminousLyrics.lineAlignment(seed: 0.7)
        #expect(LuminousLyrics.lineAlignment(seed: 0.7) == first)
        let alignments = (0..<30).map { LuminousLyrics.lineAlignment(seed: Double($0) * 0.7) }
        #expect(alignments.contains(.leading))
        #expect(alignments.contains(.center))
        #expect(alignments.contains(.trailing))
    }

    // MARK: - Font sizes and breathing

    @Test func fontSizeClampsToTheFoliaFormula() {
        #expect(LuminousLyrics.fontSize(for: 390, scale: 1) == 36)
        #expect(abs(LuminousLyrics.fontSize(for: 800, scale: 1) - 48) < 1e-9)
        #expect(LuminousLyrics.fontSize(for: 2000, scale: 1) == 72)
        #expect(abs(LuminousLyrics.fontSize(for: 800, scale: 1.25) - 60) < 1e-9)
    }

    @Test func breathingFloatFollowsItsKeyframes() {
        // 7s loop, keyframes y = [0, -14, 0, 6.3, 0] at 0 / 1.75 / 3.5 / 5.25 / 7s.
        #expect(LuminousLyrics.breathingOffset(at: 0, multiplier: 1) == 0)
        #expect(LuminousLyrics.breathingOffset(at: 1.75, multiplier: 1) == -14)
        #expect(LuminousLyrics.breathingOffset(at: 3.5, multiplier: 1) == 0)
        #expect(abs(LuminousLyrics.breathingOffset(at: 5.25, multiplier: 1) - 6.3) < 1e-9)
        #expect(LuminousLyrics.breathingOffset(at: 7, multiplier: 1) == 0)
        #expect(LuminousLyrics.breathingOffset(at: 1.75, multiplier: 0) == 0)
        #expect(LuminousLyrics.breathingOffset(at: 1.75, multiplier: 2) == -28)
    }

    @Test func breathingScaleRidesWithTheFloat() {
        #expect(LuminousLyrics.breathingScale(at: 0, multiplier: 1) == 1)
        #expect(abs(LuminousLyrics.breathingScale(at: 1.75, multiplier: 1) - 1.01) < 1e-9)
        #expect(LuminousLyrics.breathingScale(at: 0, multiplier: 0) == 1)
    }

    // MARK: - Overlap room

    @Test func identityWordStillReservesActiveScaleRoom() {
        // Even an identity word is scaled 1.4x while it is the active
        // word (the view multiplies every current word's scale by
        // `activeScale`), so the row still reserves the active pose's
        // room: (36 x 1.4 - 36 x 1.22) / 2 = 3.24.
        let reach = LuminousLyrics.reach(width: 100, fontSize: 36, placement: .identity)
        #expect(abs(reach.top - 3.24) < 1e-9)
        #expect(abs(reach.bottom - 3.24) < 1e-9)
    }

    @Test func scaledWordNeedsRoomAboveAndBelow() {
        let placement = LuminousLyrics.WordPlacement(x: 0, y: 0, rotate: 0, scale: 1.3, passedRotate: 0)
        let reach = LuminousLyrics.reach(width: 100, fontSize: 36, placement: placement)
        // Active scale 1.3 x 1.4 = 1.82: (36 x 1.82 - 36 x 1.22) / 2 = 10.8.
        #expect(abs(reach.top - 10.8) < 1e-9)
        #expect(abs(reach.bottom - 10.8) < 1e-9)
    }

    // MARK: - CJK layout units

    private func cjkLine() -> LyricLine {
        // "但你能清楚的明白" split per character, like the LRC spread.
        let text = "但你能清楚的明白"
        let words = LyricStylePreviewSamples.characterWords(text, start: 0.7, end: 3.6)
        return LyricLine(id: 0, time: 0.7, end: 3.6, text: text, words: words)
    }

    @Test func layoutUnitsRejoinToTheLineText() {
        let line = cjkLine()
        let units = LuminousLyrics.layoutUnits(for: line)
        #expect(units.map(\.text).joined() == line.text)
        #expect(units.allSatisfy { !$0.text.isEmpty })
        let display = LuminousLyrics.displayWords(from: units)
        #expect(display.map(\.text).joined() == line.text)
    }

    @Test func cjkWordStaysTogetherAndTheParticleGluesOn() {
        // "清楚" is one semantic word and the particle "的" glues onto
        // it, so neither "清" nor "楚" nor a lone "的" stands alone.
        let units = LuminousLyrics.layoutUnits(for: cjkLine())
        #expect(units.contains { $0.text == "清楚的" })
        #expect(!units.contains { $0.text == "清" })
        #expect(!units.contains { $0.text == "的" })
    }

    @Test func stickyPunctuationGluesWithoutTheTokenizer() {
        // With the semantic pass off, "。" still glues to the word before
        // it, so the punctuation never wraps onto its own line.
        let words = LyricStylePreviewSamples.characterWords("世界。", start: 0, end: 3)
        let line = LyricLine(id: 0, time: 0, end: 3, text: "世界。", words: words)
        let units = LuminousLyrics.layoutUnits(for: line, semantic: false, sticky: true)
        #expect(units.map(\.text).joined() == "世界。")
        #expect(units.contains { $0.text.hasSuffix("。") && $0.text.count > 1 })
        #expect(!units.contains { $0.text == "。" })
    }

    @Test func contractionGluesAcrossTheApostrophe() {
        let words = [word("don", start: 0, duration: 1), word("'", start: 1, duration: 0.2), word("t", start: 1.2, duration: 0.3)]
        let line = LyricLine(id: 0, time: 0, end: 1.5, text: "don't", words: words)
        let units = LuminousLyrics.layoutUnits(for: line)
        #expect(units.map(\.text) == ["don't"])
    }

    // MARK: - Preview clock loop

    @Test func previewClockWrapsBackToTheFirstLine() {
        let sample = LyricStylePreviewSamples.default
        #expect(sample.loopDuration == 14.4)
        #expect(sample.loopTime(for: 14.4) == 0)
        #expect(abs(sample.loopTime(for: 15.1) - 0.7) < 1e-9)
        #expect(sample.activeLineIndex(at: sample.loopTime(for: 15.1)) == 0)
        #expect(sample.activeLineIndex(at: 0.7) == 0)
        #expect(sample.activeLineIndex(at: 14.4) == 3)
    }

    @Test func reservedPreviewClockWrapsAtThirteenPointSix() {
        let sample = LyricStylePreviewSamples.reserved
        #expect(sample.loopDuration == 13.6)
        #expect(sample.loopTime(for: 13.6) == 0)
        #expect(sample.activeLineIndex(at: sample.loopTime(for: 13.6 + 3.6)) == 1)
    }

    @Test func previewSamplesHaveFourLinesEach() {
        #expect(LyricStylePreviewSamples.default.lines.count == 4)
        #expect(LyricStylePreviewSamples.reserved.lines.count == 4)
        #expect(LyricStylePreviewSamples.all.map(\.title) == ["神文之诗", "野芝麻"])
    }

    // MARK: - Subtitle window

    @Test func subtitleWindowShowsTheNextTwoLines() {
        #expect(LatticeLyrics.window(activeIndex: 2, lineCount: 6, before: 0, after: 2) == [2, 3, 4])
        #expect(LatticeLyrics.window(activeIndex: 5, lineCount: 6, before: 0, after: 2) == [5])
        #expect(LatticeLyrics.window(activeIndex: 0, lineCount: 1, before: 0, after: 2) == [0])
    }
}
