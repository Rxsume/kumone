// Sources/Kumone/Features/Player/LuminousLyricsView.swift
//
// Folia Stage "流光" (classic) visualizer, re-implemented in Swift.
//
// Folia renders the active lyric line as individually glowing words
// (`components/visualizer/classic/Visualizer.tsx` +
// `GlowWord.tsx`): each word has one of three states — waiting, active,
// passed — decided by the word's own start/end time plus a 0.15s
// lookahead, and each word sits at a deterministic random offset /
// rotation / scale seeded by the line's start time, so the layout is
// stable across re-renders. The line floats up and down (breathing),
// and the current line's translation plus the next two lines are shown
// as a subtitle overlay underneath (`VisualizerSubtitleOverlay.tsx`).
//
// Rendering note: the layout is a SwiftUI `Layout` (`LuminousWordFlowLayout`
// below), not a Canvas like `LatticeLyricsCard`. A Canvas `GraphicsContext`
// has no save/restore, so per-word rotation + scale + glow would have to
// be hand-computed; the Layout protocol (iOS 16+) measures each word with
// `context.resolve(Text).measure(in:)` the same way the Lattice card does,
// then places real `Text` views that keep their native `.rotationEffect`,
// `.scaleEffect` and `.shadow` glow for free.

import Foundation
import NaturalLanguage
import SwiftUI

// MARK: - Pure logic (unit-testable)

/// Folia classic (流光) visualizer logic: word states, deterministic
/// random layout, breathing motion, and CJK semantic layout units.
/// Pure — no SwiftUI, no settings — so it can be unit-tested directly.
enum LuminousLyrics {

    /// How far ahead of a word's start time it lights up.
    static let lookahead: TimeInterval = 0.15

    /// Active words are scaled by their placement scale times this.
    static let activeScale: CGFloat = 1.4

    /// Line height in em (Folia `glowWordOverlap.ts`).
    static let lineHeight: CGFloat = 1.22

    /// Passed words keep this much of their glow before fading out.
    static let passedOpacity: Double = 0.82

    // MARK: Word state

    enum WordState: Equatable {
        case waiting
        case active
        case passed
    }

    /// Which of the three states a word is in at `time`, from its own
    /// start/end plus the fixed lookahead.
    /// Boundaries: at exactly `start - lookahead` the word is already
    /// active; at exactly `end` it has already passed.
    static func state(of word: LyricWord, at time: TimeInterval) -> WordState {
        if time < word.start - lookahead { return .waiting }
        if time < word.end { return .active }
        return .passed
    }

    /// The moment a word stops glowing: its end time.
    /// (Folia `getGlowWordActiveEndTime`.)
    static func activeEndTime(of word: LyricWord) -> TimeInterval {
        word.end
    }

    /// How long a word's glow stays on screen: from its lookahead start
    /// until its end. (Folia `getGlowWordDisplayDuration`.)
    static func displayDuration(of word: LyricWord) -> TimeInterval {
        max(0, word.end - (word.start - lookahead))
    }

    /// The render profile of a line: when its glow starts, when it ends,
    /// and how long the glow lasts. (Folia `resolveGlowWordRenderProfile`.)
    static func renderProfile(for line: LyricLine) -> (lookahead: TimeInterval, activeEnd: TimeInterval, displayDuration: TimeInterval) {
        let end = line.words?.last?.end ?? line.end
        return (lookahead, end, max(0, end - (line.time - lookahead)))
    }

    // MARK: Deterministic random layout

    /// Folia's `random(offset)`: `frac(sin(seed + i + offset) * 10000)`,
    /// where the seed is the line's start time and `i` the word index.
    /// Same seed + index always gives the same value.
    static func random(seed: TimeInterval, index: Int, offset: Double) -> Double {
        let value = sin(seed + Double(index) + offset) * 10_000
        return value - floor(value)
    }

    /// One word's deterministic offset / rotation / scale, from its index
    /// in the line and the line's start time as seed.
    struct WordPlacement: Equatable {
        var x: CGFloat
        var y: CGFloat
        var rotate: Double
        var scale: CGFloat
        /// Extra rotation the word turns through once it has passed.
        var passedRotate: Double

        static let identity = WordPlacement(x: 0, y: 0, rotate: 0, scale: 1, passedRotate: 0)
    }

    /// Normal intensity: ±20pt offsets, ±5° rotation, 1.1–1.3× scale.
    /// Calm intensity: everything centred (no offsets, no rotation,
    /// scale 1). The passed-turn is ±22.5°.
    static func placement(seed: TimeInterval, index: Int, rotationEnabled: Bool, calm: Bool = false) -> WordPlacement {
        guard !calm else { return .identity }
        let x = (random(seed: seed, index: index, offset: 0) - 0.5) * 40
        let y = (random(seed: seed, index: index, offset: 1) - 0.5) * 40
        let rotate = rotationEnabled ? (random(seed: seed, index: index, offset: 2) - 0.5) * 10 : 0
        let scale = 1.1 + random(seed: seed, index: index, offset: 4) * 0.2
        let passedRotate = (random(seed: seed, index: index, offset: 8) - 0.5) * 45
        return WordPlacement(x: x, y: y, rotate: rotate, scale: scale, passedRotate: passedRotate)
    }

    /// Row justification of a line: Folia's `justifyContent`, one of
    /// five options rotating by seed — start / center / end / around /
    /// between (`classic/Visualizer.tsx`, `justifyOptions`). Calm lines
    /// are always centred. Note the seed here is the line's start time,
    /// so `floor(seed % 5)` picks the option.
    enum LineJustify: Equatable {
        case leading
        case center
        case trailing
        case spaceAround
        case spaceBetween
    }

    static func lineJustify(seed: TimeInterval, calm: Bool = false) -> LineJustify {
        guard !calm else { return .center }
        switch Int(floor(seed.truncatingRemainder(dividingBy: 5))) {
        case 0: return .leading
        case 1: return .center
        case 2: return .trailing
        case 3: return .spaceAround
        default: return .spaceBetween
        }
    }

    // MARK: Font sizes

    /// Main lyric font size: `clamp(36pt, 6% of width, 72pt)` times the
    /// user's font scale. (Folia `mainFontSize`.)
    static func fontSize(for width: CGFloat, scale: Double) -> CGFloat {
        min(max(36, 0.06 * width), 72) * scale
    }

    /// Translation subtitle size: `clamp(18pt, 2.6vw, 20pt)` × scale.
    /// (Folia `resolveSubtitleFontSizes`.)
    static func translationFontSize(for width: CGFloat, scale: Double) -> CGFloat {
        min(max(18, 0.026 * width), 20) * scale
    }

    /// Upcoming-line subtitle size: `clamp(14pt, 2vw, 16pt)` × scale.
    /// (Folia `resolveSubtitleFontSizes`.)
    static func upcomingFontSize(for width: CGFloat, scale: Double) -> CGFloat {
        min(max(14, 0.02 * width), 16) * scale
    }

    // MARK: Breathing float

    /// Whole-line breathing float: ±14pt over a 7s loop, eased through
    /// keyframes y = [0, −d, 0, 0.45d, 0], scaled by `multiplier`
    /// (0 = still). `time` is an absolute clock in seconds; the phase
    /// repeats every 7s.
    static func breathingOffset(at time: TimeInterval, multiplier: Double) -> CGFloat {
        guard multiplier > 0 else { return 0 }
        let distance = 14 * multiplier
        return keyframeValue(at: time, duration: 7, keys: [0, -distance, 0, 0.45 * distance, 0])
    }

    /// The breathing scale that rides with the float:
    /// [1, 1+0.01m, 1, 1−0.005m, 1] over the same 7s loop.
    static func breathingScale(at time: TimeInterval, multiplier: Double) -> CGFloat {
        guard multiplier > 0 else { return 1 }
        return keyframeValue(at: time, duration: 7, keys: [1, 1 + 0.01 * multiplier, 1, 1 - 0.005 * multiplier, 1])
    }

    /// Interpolates through equally spaced keyframes with an easeInOut
    /// between each pair.
    private static func keyframeValue(at time: TimeInterval, duration: TimeInterval, keys: [Double]) -> Double {
        guard keys.count > 1, duration > 0 else { return keys.first ?? 0 }
        let phase = (time.truncatingRemainder(dividingBy: duration) / duration)
        let segmentCount = Double(keys.count - 1)
        let position = phase * segmentCount
        let index = min(Int(floor(position)), keys.count - 2)
        let local = position - Double(index)
        let eased = local < 0.5 ? 2 * local * local : 1 - pow(-2 * local + 2, 2) / 2
        return keys[index] + (keys[index + 1] - keys[index]) * eased
    }

    // MARK: Overlap room (Folia `glowWordOverlap.ts`)

    /// How far a word can reach beyond its box, top and bottom, once it
    /// is scaled up (active) or turned (passed). The larger of the two
    /// poses wins, so the row reserves room for either.
    static func reach(width: CGFloat, fontSize: CGFloat, placement: WordPlacement) -> (top: CGFloat, bottom: CGFloat) {
        let glyph = fontSize
        let line = fontSize * lineHeight
        let active = reachFor(scale: placement.scale * activeScale, rotate: placement.rotate, width: width, glyph: glyph, line: line, offset: placement.y)
        let passed = reachFor(scale: placement.scale, rotate: placement.rotate + placement.passedRotate, width: width, glyph: glyph, line: line, offset: placement.y)
        return (top: max(active.top, passed.top), bottom: max(active.bottom, passed.bottom))
    }

    private static func reachFor(scale: CGFloat, rotate: Double, width: CGFloat, glyph: CGFloat, line: CGFloat, offset: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        let radians = abs(rotate) * Double.pi / 180
        let scaledWidth = width * scale
        let scaledHeight = glyph * scale
        let rotatedWidth = scaledWidth * cos(radians) + scaledHeight * sin(radians)
        let rotatedHeight = scaledWidth * sin(radians) + scaledHeight * cos(radians)
        let top = max(0, (rotatedHeight - line) / 2 - offset)
        let bottom = max(0, (rotatedHeight - line) / 2 + offset)
        _ = rotatedWidth
        return (top: top, bottom: bottom)
    }

    /// How much of the gap between two neighbouring words their scaled
    /// widths eat: half of each word's overhang.
    static func pairGap(width: CGFloat, nextWidth: CGFloat, fontSize: CGFloat, placement: WordPlacement, nextPlacement: WordPlacement) -> CGFloat {
        let active = pairGapFor(width: width, nextWidth: nextWidth, fontSize: fontSize, placement: placement, nextPlacement: nextPlacement, active: true)
        let passed = pairGapFor(width: width, nextWidth: nextWidth, fontSize: fontSize, placement: placement, nextPlacement: nextPlacement, active: false)
        return max(active, passed)
    }

    private static func pairGapFor(width: CGFloat, nextWidth: CGFloat, fontSize: CGFloat, placement: WordPlacement, nextPlacement: WordPlacement, active: Bool) -> CGFloat {
        let radians = abs(placement.rotate) * Double.pi / 180
        let nextRadians = abs(nextPlacement.rotate) * Double.pi / 180
        let s = placement.scale * (active ? activeScale : 1)
        let sNext = nextPlacement.scale * (active ? activeScale : 1)
        let rotatedWidth = width * s * cos(radians) + fontSize * s * sin(radians)
        let nextRotatedWidth = nextWidth * sNext * cos(nextRadians) + fontSize * sNext * sin(nextRadians)
        let halfOverflow = (rotatedWidth - width) / 2
        let nextHalfOverflow = (nextRotatedWidth - nextWidth) / 2
        let xOffsetDiff = placement.x - nextPlacement.x
        return halfOverflow + nextHalfOverflow + xOffsetDiff
    }

    /// How far a word overflows its own layout box, top and bottom, after
    /// scaling, rotation and its y offset. Used to reserve room above and
    /// below a row when overlap avoidance is on.
    static func overflow(width: CGFloat, fontSize: CGFloat, placement: WordPlacement) -> (top: CGFloat, bottom: CGFloat) {
        reach(width: width, fontSize: fontSize, placement: placement)
    }

    // MARK: CJK semantic layout units (Folia `buildPostLyricLayoutUnits`)

    /// One unbreakable layout unit: either a single word, or several words
    /// glued together by the tokenizer (a CJK word like "清楚" that the
    /// parser split per character) or by a sticky rule (punctuation,
    /// contractions, CJK particles like "的").
    struct LyricLayoutUnit: Hashable {
        var text: String
        var words: [LyricWord]
        var startTime: TimeInterval
        var endTime: TimeInterval
        /// Several words glued by the tokenizer into one semantic word.
        var isSemantic: Bool
        /// Glued by a sticky rule (punctuation / contraction / particle).
        var isSticky: Bool = false

        func withSticky(_ sticky: Bool) -> LyricLayoutUnit {
            var copy = self
            copy.isSticky = sticky
            return copy
        }
    }

    /// Split a line into layout units. With `semantic` on, CJK text is
    /// run through `NLTokenizer` so a multi-character word stays together;
    /// with `sticky` on, punctuation, contractions and CJK particles glue
    /// onto the previous unit. Any tokenizer failure falls back to
    /// one-word-per-unit (the sticky pass still runs).
    static func layoutUnits(for line: LyricLine, semantic: Bool = true, sticky: Bool = true) -> [LyricLayoutUnit] {
        guard let words = line.words, !words.isEmpty else {
            return [LyricLayoutUnit(text: line.text, words: [], startTime: line.time, endTime: line.end, isSemantic: false)]
        }
        let raw: [LyricLayoutUnit]
        if semantic, containsCJK(line.text) {
            raw = alignTokenizerSegments(line, words: words) ?? words.map { singleUnit($0) }
        } else {
            raw = words.map { singleUnit($0) }
        }
        return sticky ? applyStickyUnits(raw) : raw
    }

    /// The words the view actually renders, one per layout unit: a unit
    /// with several words renders as one word spanning its whole range,
    /// so its glow lights and fades as a whole.
    static func displayWords(from units: [LyricLayoutUnit]) -> [LyricWord] {
        units.map { unit in
            LyricWord(text: unit.text, start: unit.startTime, duration: max(0, unit.endTime - unit.startTime))
        }
    }

    private static func singleUnit(_ word: LyricWord) -> LyricLayoutUnit {
        LyricLayoutUnit(text: word.text, words: [word], startTime: word.start, endTime: word.end, isSemantic: false)
    }

    private static func appendUnit(_ target: LyricLayoutUnit, _ other: LyricLayoutUnit) -> LyricLayoutUnit {
        LyricLayoutUnit(
            text: target.text + other.text,
            words: target.words + other.words,
            startTime: target.startTime,
            endTime: other.endTime,
            isSemantic: target.isSemantic,
            isSticky: true
        )
    }

    /// Tokenize the line with `NLTokenizer` (.word) and align the tokens
    /// to the parser's words, ignoring whitespace. Returns `nil` on any
    /// mismatch — the caller then falls back to one-word-per-unit.
    private static func alignTokenizerSegments(_ line: LyricLine, words: [LyricWord]) -> [LyricLayoutUnit]? {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = line.text
        var segments: [String] = []
        tokenizer.enumerateTokens(in: line.text.startIndex..<line.text.endIndex) { range, _ in
            segments.append(String(line.text[range]))
            return true
        }
        func stripped(_ text: String) -> String { text.filter { !$0.isWhitespace } }
        var units: [LyricLayoutUnit] = []
        var wordIndex = 0
        // Absorb whitespace-only words into the previous unit.
        func absorbWhitespace() {
            guard !units.isEmpty else { return }
            while wordIndex < words.count, stripped(words[wordIndex].text).isEmpty {
                units[units.count - 1] = appendUnit(units[units.count - 1], singleUnit(words[wordIndex]))
                wordIndex += 1
            }
        }
        for segment in segments {
            let key = stripped(segment)
            guard !key.isEmpty else { continue }
            absorbWhitespace()
            let startWord = wordIndex
            var collected = ""
            while wordIndex < words.count, collected.count < key.count {
                collected += stripped(words[wordIndex].text)
                wordIndex += 1
                guard key.hasPrefix(collected) else { return nil }
            }
            guard collected == key else { return nil }
            let segmentWords = Array(words[startWord..<wordIndex])
            guard let first = segmentWords.first, let last = segmentWords.last else { return nil }
            let text = segmentWords.map(\.text).joined()
            let isSemantic = segmentWords.count > 1 && containsCJK(text)
            units.append(LyricLayoutUnit(text: text, words: segmentWords, startTime: first.start, endTime: last.end, isSemantic: isSemantic))
        }
        absorbWhitespace()
        guard wordIndex == words.count, !units.isEmpty else { return nil }
        return units
    }

    private static func applyStickyUnits(_ units: [LyricLayoutUnit]) -> [LyricLayoutUnit] {
        var merged: [LyricLayoutUnit] = []
        var index = 0
        while index < units.count {
            let current = units[index]
            guard let previous = merged.last else {
                merged.append(current)
                index += 1
                continue
            }
            let next = index + 1 < units.count ? units[index + 1] : nil
            // "It ' s": the apostrophe glues to the word before it and the
            // contraction suffix glues to the apostrophe.
            if isApostropheOnly(current), let next, endsWithWordChar(previous.text), isContractionSuffix(next) {
                merged[merged.count - 1] = appendUnit(appendUnit(previous, current), next)
                index += 2
                continue
            }
            // "don 't": the apostrophe+letter glues to the word before it.
            if isDirectContraction(current), endsWithWordChar(previous.text) {
                merged[merged.count - 1] = appendUnit(previous, current)
                index += 1
                continue
            }
            // "don' t": the suffix glues to the apostrophe before it.
            if isContractionSuffix(current), endsWithApostrophe(previous.text) {
                merged[merged.count - 1] = appendUnit(previous, current)
                index += 1
                continue
            }
            // Punctuation glues to the word before it ("世界。").
            if isStickyPunctuation(current), endsWithWordChar(previous.text) {
                merged[merged.count - 1] = appendUnit(previous, current)
                index += 1
                continue
            }
            // A lone CJK particle glues to the previous CJK unit ("清楚的").
            if isCJKParticle(current), containsCJK(previous.text) {
                merged[merged.count - 1] = appendUnit(previous, current)
                index += 1
                continue
            }
            merged.append(current)
            index += 1
        }
        return merged.map { unit in
            (hasAttachedTrailingPunctuation(unit) || hasInlineContraction(unit)) ? unit.withSticky(true) : unit
        }
    }

    // MARK: - Character classification

    static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        let value = scalar.value
        return (0x2E80...0x9FFF).contains(value)      // CJK radicals / ideographs
            || (0x3040...0x30FF).contains(value)      // hiragana / katakana
            || (0x31F0...0x31FF).contains(value)      // katakana extensions
            || (0xAC00...0xD7AF).contains(value)      // hangul syllables
            || (0xFF66...0xFF9D).contains(value)      // halfwidth katakana
    }

    static func containsCJK(_ text: String) -> Bool {
        text.contains { isCJK($0) }
    }

    private static let cjkParticles: Set<Character> = ["的", "了", "着", "过", "地", "得", "之", "吗", "呢", "吧", "啊", "哇", "哦", "呀", "呐", "啦", "嘛", "么"]

    private static func isCJKParticle(_ unit: LyricLayoutUnit) -> Bool {
        unit.words.count == 1 && unit.text.count == 1 && cjkParticles.contains(unit.text.first ?? " ")
    }

    private static func isStickyPunctuation(_ unit: LyricLayoutUnit) -> Bool {
        unit.words.count == 1 && unit.text.count == 1 && isStickyPunctuationChar(unit.text.first ?? " ")
    }

    private static func isStickyPunctuationChar(_ character: Character) -> Bool {
        switch character {
        case ",", ".", "!", "?", ";", ":", "。", "、", "，", "！", "？", "；", "：", "…", "—", "–", "）", "」", "』", "”", "’":
            return true
        default:
            return false
        }
    }

    private static func isApostropheOnly(_ unit: LyricLayoutUnit) -> Bool {
        unit.words.count == 1 && (unit.text == "'" || unit.text == "’")
    }

    private static let contractionSuffixes: Set<String> = ["s", "t", "m", "d", "ll", "re", "ve", "em"]

    private static func isContractionSuffix(_ unit: LyricLayoutUnit) -> Bool {
        unit.words.count == 1 && contractionSuffixes.contains(unit.text.lowercased())
    }

    private static func isDirectContraction(_ unit: LyricLayoutUnit) -> Bool {
        guard unit.words.count == 1, unit.text.count > 1 else { return false }
        let text = unit.text
        guard text.first == "'" || text.first == "’" else { return false }
        return contractionSuffixes.contains(String(text.dropFirst()).lowercased())
    }

    private static func endsWithWordChar(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return last.isLetter || last.isNumber
    }

    private static func endsWithApostrophe(_ text: String) -> Bool {
        text.last == "'" || text.last == "’"
    }

    private static func hasAttachedTrailingPunctuation(_ unit: LyricLayoutUnit) -> Bool {
        guard unit.words.count > 1, let last = unit.words.last else { return false }
        return last.text.count == 1 && isStickyPunctuationChar(last.text.first ?? " ")
    }

    private static func hasInlineContraction(_ unit: LyricLayoutUnit) -> Bool {
        guard unit.words.count > 1, !unit.isSemantic else { return false }
        let text = unit.text.lowercased()
        for (index, char) in text.enumerated() where char == "'" || char == "’" {
            guard index > 0, index + 1 < text.count else { continue }
            let after = String(text[text.index(text.startIndex, offsetBy: index + 1)...])
            if contractionSuffixes.contains(where: { after.hasPrefix($0) }) { return true }
        }
        return false
    }
}

// MARK: - Font helpers

extension Font.Weight {
    /// Folia font weight (100–900, from the style window's weight slider)
    /// to a SwiftUI weight. Values are bucketed to the nearest supported
    /// step, matching how the web renderer rounds them.
    static func fromFoliaValue(_ value: Double) -> Font.Weight {
        switch value {
        case ..<150: return .ultraLight
        case ..<250: return .thin
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        case ..<850: return .heavy
        default: return .black
        }
    }
}

// MARK: - Word-flow layout

/// Word-flow layout for one luminous line: measures each word, then wraps
/// into rows — the same measure-first-then-wrap as
/// `LatticeLyricsCard.layoutWords`, expressed as a SwiftUI `Layout` so
/// each word keeps native rotation / scale / shadow for its glow.
///
/// The gap between two words follows Folia's margin formula: each word's
/// overhang (how far it sticks out once scaled up) plus a 5% font-size
/// gap, times the word-spacing multiplier, with a 12% font-size floor.
/// When overlap avoidance is on, the gap also respects how far the words
/// actually reach (`LuminousLyrics.pairGap`), and the row reserves room
/// above and below for scaled / turned words (`LuminousLyrics.reach`).
struct LuminousWordFlowLayout: Layout {
    var fontSize: CGFloat
    var wordSpacing: Double
    var avoidOverlap: Bool
    var placements: [LuminousLyrics.WordPlacement]
    var justify: LuminousLyrics.LineJustify

    private struct Plan {
        var rows: [[Int]]
        var rowWidths: [CGFloat]
        var height: CGFloat
        var rowGap: CGFloat
        var reachTop: CGFloat
        var reachBottom: CGFloat
    }

    private func placement(at index: Int) -> LuminousLyrics.WordPlacement {
        guard placements.indices.contains(index) else { return .identity }
        return placements[index]
    }

    private func margin(after index: Int, sizes: [CGSize]) -> CGFloat {
        let width = sizes[index].width
        // NOTE: the local must not be named `placement` — it would shadow
        // the `placement(at:)` method below, so the calls at the next
        // word would resolve to the value instead of the method.
        let currentPlacement = placement(at: index)
        let scale = currentPlacement.scale * LuminousLyrics.activeScale
        var nextWidth: CGFloat = 0
        var nextScale: CGFloat = 1
        var nextX: CGFloat = 0
        if index + 1 < sizes.count {
            let next = placement(at: index + 1)
            nextScale = next.scale * LuminousLyrics.activeScale
            nextX = next.x
            nextWidth = sizes[index + 1].width
        }
        let gap = 0.05 * fontSize
        let halfOverflow = width * (scale - 1) / 2
        let nextHalfOverflow = nextWidth * (nextScale - 1) / 2
        let xOffsetDiff = currentPlacement.x - nextX
        let calculated = (halfOverflow + nextHalfOverflow + xOffsetDiff + gap) * wordSpacing
        let minMargin = 0.12 * fontSize * wordSpacing
        var final = max(minMargin, calculated)
        if avoidOverlap, index + 1 < sizes.count {
            let pairGap = LuminousLyrics.pairGap(
                width: width, nextWidth: nextWidth, fontSize: fontSize,
                placement: currentPlacement, nextPlacement: placement(at: index + 1)
            )
            final = max(final, pairGap + gap)
        }
        return final
    }

    private func plan(sizes: [CGSize], maxWidth: CGFloat) -> Plan {
        guard !sizes.isEmpty else {
            return Plan(rows: [], rowWidths: [], height: 0, rowGap: 0, reachTop: 0, reachBottom: 0)
        }
        let width = maxWidth > 0 ? maxWidth : sizes.reduce(0) { $0 + $1.width }
        let lineHeight = fontSize * LuminousLyrics.lineHeight
        let margins = sizes.indices.map { margin(after: $0, sizes: sizes) }
        var rows: [[Int]] = []
        var rowWidths: [CGFloat] = []
        var current: [Int] = []
        var currentWidth: CGFloat = 0
        for index in sizes.indices {
            let wordWidth = sizes[index].width
            if !current.isEmpty, currentWidth + wordWidth > width {
                rowWidths.append(currentWidth - margins[current.last ?? index])
                rows.append(current)
                current = []
                currentWidth = 0
            }
            current.append(index)
            currentWidth += wordWidth + margins[index]
        }
        if !current.isEmpty {
            rowWidths.append(currentWidth - margins[current.last ?? 0])
            rows.append(current)
        }
        var reachTop: CGFloat = 0
        var reachBottom: CGFloat = 0
        var rowGap: CGFloat = 0
        if avoidOverlap {
            for index in sizes.indices {
                let overflow = LuminousLyrics.overflow(width: sizes[index].width, fontSize: fontSize, placement: placement(at: index))
                reachTop = max(reachTop, overflow.top)
                reachBottom = max(reachBottom, overflow.bottom)
            }
            rowGap = ceil(reachTop + reachBottom)
            reachTop = ceil(reachTop)
            reachBottom = ceil(reachBottom)
        }
        let height = reachTop + CGFloat(rows.count) * lineHeight + CGFloat(max(rows.count - 1, 0)) * rowGap + reachBottom
        return Plan(rows: rows, rowWidths: rowWidths, height: height, rowGap: rowGap, reachTop: reachTop, reachBottom: reachBottom)
    }

    private func rowXOffset(rowWidth: CGFloat, maxWidth: CGFloat) -> CGFloat {
        switch justify {
        case .leading, .spaceBetween: return 0
        case .center: return max(0, (maxWidth - rowWidth) / 2)
        case .trailing: return max(0, maxWidth - rowWidth)
        case .spaceAround: return 0
        }
    }

    /// Extra gap handed out between words when the line spreads across
    /// the row (Folia's justify-between / justify-around). Returns the
    /// per-gap extra and the leading inset for the row.
    private func spread(rowWidth: CGFloat, maxWidth: CGFloat, wordCount: Int) -> (gap: CGFloat, leading: CGFloat) {
        let extra = max(0, maxWidth - rowWidth)
        switch justify {
        case .spaceBetween where wordCount > 1:
            return (extra / CGFloat(wordCount - 1), 0)
        case .spaceAround where wordCount > 0:
            // Half a gap at each edge, a full gap between words.
            let gap = extra / CGFloat(wordCount)
            return (gap, gap / 2)
        default:
            return (0, 0)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 0
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let plan = plan(sizes: sizes, maxWidth: maxWidth)
        return CGSize(width: maxWidth, height: plan.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let plan = plan(sizes: sizes, maxWidth: bounds.width)
        let lineHeight = fontSize * LuminousLyrics.lineHeight
        var y = bounds.minY + plan.reachTop
        for (rowIndex, row) in plan.rows.enumerated() {
            let (gapExtra, leadingInset) = spread(
                rowWidth: plan.rowWidths[rowIndex], maxWidth: bounds.width, wordCount: row.count
            )
            var x = bounds.minX + rowXOffset(rowWidth: plan.rowWidths[rowIndex], maxWidth: bounds.width) + leadingInset
            for (position, index) in row.enumerated() {
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(sizes[index])
                )
                x += sizes[index].width + margin(after: index, sizes: sizes)
                if position < row.count - 1 {
                    x += gapExtra
                } else if justify == .spaceAround {
                    // The trailing half-gap belongs after the last word;
                    // it is whitespace, so it needs no placement.
                    x += gapExtra / 2
                }
            }
            y += lineHeight + plan.rowGap
        }
    }
}

// MARK: - The view

/// Folia classic (流光) full-screen lyrics: one big line at a time, words
/// glowing in turn, with a subtitle overlay (translation + next two lines)
/// underneath.
///
/// `previewTime` drives the style window's live preview: when set, the
/// view renders the given sample line at that clock instead of the live
/// song, and never starts its own `TimelineView`. When `nil`, the view
/// follows `player.livePlaybackTime` while playing (and freezes on the
/// last frame while paused, in static mode, or with reduce motion on).
struct LuminousLyricsView: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    /// The playback clock, observed directly: `player.progress` is only a
    /// computed passthrough to `clock.progress`, so reading it through
    /// `player` never subscribes this view to its ticks — that is why the
    /// PR #13 progress heartbeat never fired and the lyrics froze. Same
    /// pattern as `NowPlayingScrubber`.
    @ObservedObject private var clock = PlayerService.shared.clock

    /// Per-line render cache (word splitting, placements, alignment):
    /// they depend only on the line and the layout settings, so they are
    /// computed once per line instead of once per 30fps tick — the split
    /// runs an NLTokenizer over the line every time. A reference-type box
    /// in `@State`: writing to the box publishes nothing, so the cache
    /// fills during rendering without re-triggering it.
    private final class LineRenderCacheBox {
        var lineID: Int?
        var lineTime: TimeInterval?
        var rotationEnabled: Bool?
        var calm: Bool?
        var words: [LyricWord] = []
        var placements: [LuminousLyrics.WordPlacement] = []
        var justify: LuminousLyrics.LineJustify = .center
    }
    @State private var lineCache = LineRenderCacheBox()

    /// Glow colour for the active word (the theme accent, passed in by
    /// the parent like `LatticeLyricsCard`'s `accent:`).
    var accent: Color = .white
    var previewLine: LyricLine?
    var previewTime: TimeInterval?
    /// In the preview, the sample lines after the current one, for the
    /// subtitle overlay's upcoming-line rows.
    var previewUpcoming: [LyricLine] = []

    private var isPreview: Bool { previewLine != nil }
    private var isStatic: Bool {
        settings.effectiveStaticMode || settings.effectiveReduceMotionMicroMotion
    }

    var body: some View {
        GeometryReader { geometry in
            content(size: geometry.size)
        }
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        if let previewLine, let previewTime {
            lyricsContent(line: previewLine, time: previewTime, clock: previewTime, size: size)
        } else if let lyrics = player.lyrics, !lyrics.lines.isEmpty {
            // The clock is observed directly (see `clock` above), so this
            // view re-renders on every clock publish (~0.5s) even if the
            // timeline stalls: the heartbeat that bounds lyric staleness.
            // `livePlaybackTime` is still preferred when it is finite — it
            // is the deck's live position, not the coarse published one.
            let fallback = clock.progress
            if player.isPlaying && !isStatic {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                    let time = currentTime(fallback: fallback)
                    lyricsContent(
                        line: activeLine(in: lyrics, at: time),
                        time: time,
                        clock: context.date.timeIntervalSinceReferenceDate,
                        size: size
                    )
                }
            } else {
                // Paused or static: no timeline, but the clock subscription
                // above still re-renders this branch on every tick, so the
                // line follows the playhead — static mode stills the
                // animation, it must not freeze the lyrics.
                let time = currentTime(fallback: fallback)
                lyricsContent(
                    line: activeLine(in: lyrics, at: time),
                    time: time,
                    clock: Date().timeIntervalSinceReferenceDate,
                    size: size
                )
            }
        } else {
            Text(player.currentTrack == nil ? "暂无歌曲" : "歌词加载中…")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func activeLine(in lyrics: ParsedLyrics, at time: TimeInterval) -> LyricLine {
        let index = lyrics.activeIndex(at: time) ?? 0
        return lyrics.lines[min(max(index, 0), lyrics.lines.count - 1)]
    }

    /// Live deck position; falls back to the coarse published progress
    /// when the deck reports nothing finite (no item loaded, mid-seek).
    /// The fallback is the clock's progress (read in `content(size:)`),
    /// which is also what subscribes this view to its heartbeat.
    private func currentTime(fallback: TimeInterval) -> TimeInterval {
        let live = player.livePlaybackTime
        return live.isFinite ? live : fallback
    }

    private func lyricsContent(line: LyricLine, time: TimeInterval, clock: TimeInterval, size: CGSize) -> some View {
        let scale = settings.effectiveLyricsFontScale
        let fontSize = LuminousLyrics.fontSize(for: size.width, scale: scale)
        let font = lyricFont(size: fontSize)
        let calm = isStatic
        let rotationEnabled = settings.effectiveClassicWordRotation
        // Words, placements and alignment come from the per-line cache:
        // the split runs an NLTokenizer over the line, and re-running it
        // on every 30fps tick was a large share of the frame cost.
        let box = lineCache
        let (words, placements, justify): ([LyricWord], [LuminousLyrics.WordPlacement], LuminousLyrics.LineJustify) = {
            if box.lineID == line.id, box.lineTime == line.time,
               box.rotationEnabled == rotationEnabled, box.calm == calm {
                return (box.words, box.placements, box.justify)
            }
            let units = LuminousLyrics.layoutUnits(for: line)
            let freshWords = LuminousLyrics.displayWords(from: units)
            let freshPlacements = freshWords.indices.map {
                LuminousLyrics.placement(seed: line.time, index: $0, rotationEnabled: rotationEnabled, calm: calm)
            }
            let freshJustify = LuminousLyrics.lineJustify(seed: line.time, calm: calm)
            box.lineID = line.id
            box.lineTime = line.time
            box.rotationEnabled = rotationEnabled
            box.calm = calm
            box.words = freshWords
            box.placements = freshPlacements
            box.justify = freshJustify
            return (freshWords, freshPlacements, freshJustify)
        }()
        let breathingOn = settings.effectiveClassicBreathingFloat > 0 && !isStatic
        let breathing = breathingOn
            ? LuminousLyrics.breathingOffset(at: clock, multiplier: settings.effectiveClassicBreathingFloat)
            : 0
        let breathingScale = breathingOn
            ? LuminousLyrics.breathingScale(at: clock, multiplier: settings.effectiveClassicBreathingFloat)
            : 1
        let entrance = min(max((time - line.time) / 0.3, 0), 1)

        return VStack(spacing: 24) {
            LuminousWordFlowLayout(
                fontSize: fontSize,
                wordSpacing: settings.effectiveClassicWordSpacing,
                avoidOverlap: settings.effectiveClassicAvoidOverlap,
                placements: placements,
                justify: justify
            ) {
                ForEach(words.indices, id: \.self) { index in
                    wordView(word: words[index], placement: placements[index], time: time, font: font, fontSize: fontSize, rotationEnabled: rotationEnabled)
                }
            }
            .scaleEffect(breathingScale)
            .scaleEffect(0.9 + 0.1 * entrance)
            .offset(y: breathing)
            .opacity(entrance)
            subtitleOverlay(line: line, time: time, size: size)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .opacity(settings.effectiveVisualizerOpacity)
        .padding(.horizontal, 24)
    }

    private func wordView(word: LyricWord, placement: LuminousLyrics.WordPlacement, time: TimeInterval, font: Font, fontSize: CGFloat, rotationEnabled: Bool) -> some View {
        let state = LuminousLyrics.state(of: word, at: time)
        // A shadow with radius 0 costs no offscreen blur pass, so only
        // the active word pays for the double glow: a line of ~10 words
        // used to cost ~20 large-radius shadow renders per frame.
        // Waiting words never glow; passed words keep one small shadow.
        //
        // Waiting (Folia `buildGlowWordLayoutVariants` + `glowWordBodyVariants`):
        // invisible, half size, flown in from (sin(y) * 100, cos(x) * 50)
        // with 20° extra turn and a 10px blur, springing to its place
        // over 0.4s when the lookahead hits. Passed words keep one small
        // shadow that fades with the glow over 0.9s.
        //
        // Glow radii (Folia `wordGlow.ts`, normal reveal mode: inner
        // 20px / outer 40px at a 72px font) scale with the font size, so
        // the halo keeps its proportion on a phone's 36pt lyrics.
        let (opacity, scale, rotate, offsetX, offsetY, blur, glowRadius, glowOpacity, secondRadius): (Double, CGFloat, Double, CGFloat, CGFloat, CGFloat, CGFloat, Double, CGFloat) = {
            switch state {
            case .waiting:
                return (
                    0, 0.5,
                    rotationEnabled ? placement.rotate + 20 : 0,
                    placement.x + CGFloat(sin(Double(placement.y))) * 100,
                    placement.y + CGFloat(cos(Double(placement.x))) * 50,
                    10, 0, 0, 0
                )
            case .active:
                return (1, placement.scale * LuminousLyrics.activeScale, placement.rotate, placement.x, placement.y, 0,
                        fontSize * 0.28, 0.8, fontSize * 0.56)
            case .passed:
                let turn = min(max((time - word.end) / 5, 0), 1)
                let fade = max(0, 1 - (time - word.end) / 0.8)
                return (LuminousLyrics.passedOpacity, placement.scale, placement.rotate + placement.passedRotate * turn,
                        placement.x, placement.y, 0, 6, 0.35 * fade, 0)
            }
        }()
        return Text(word.text)
            .font(font)
            .foregroundColor(.white.opacity(opacity))
            .shadow(color: accent.opacity(glowOpacity), radius: glowRadius, x: 0, y: 0)
            .shadow(color: .white.opacity(glowOpacity * 0.6), radius: secondRadius, x: 0, y: 0)
            .rotationEffect(.degrees(rotate))
            .scaleEffect(scale)
            .offset(x: offsetX, y: offsetY)
            .blur(radius: blur)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: state)
    }

    private func lyricFont(size: CGFloat) -> Font {
        let weight: Font.Weight = settings.effectiveLyricsFontWeight.map(Font.Weight.fromFoliaValue) ?? .bold
        if let custom = settings.effectiveLyricsCustomFont, !custom.isEmpty {
            return Font.custom(custom, size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: settings.effectiveLyricsFontStyle.design)
    }

    private func subtitleFont(size: CGFloat) -> Font {
        if settings.effectiveSubtitleFontFollowsLyrics {
            let style = settings.effectiveLyricsFontStyle
            if let custom = settings.effectiveLyricsCustomFont, !custom.isEmpty {
                return Font.custom(custom, size: size)
            }
            return .system(size: size, weight: .regular, design: style.design)
        }
        let weight: Font.Weight = settings.effectiveSubtitleFontWeight.map(Font.Weight.fromFoliaValue) ?? .regular
        if let custom = settings.effectiveSubtitleCustomFont, !custom.isEmpty {
            return Font.custom(custom, size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: settings.effectiveSubtitleFontStyle.design)
    }

    @ViewBuilder
    private func subtitleOverlay(line: LyricLine, time: TimeInterval, size: CGSize) -> some View {
        let mode = settings.subtitleContentMode
        let scale = settings.effectiveSubtitleFontScale
        let overlayOpacity = settings.effectiveSubtitleOverlayOpacity
        let hideTranslation = settings.effectiveHideTranslationSubtitle
        let translation = mode.showsTranslation && !hideTranslation ? line.translation : nil
        let romaji = mode.showsRomaji ? line.romaji : nil
        let upcoming: [LyricLine] = {
            if isPreview { return Array(previewUpcoming.prefix(settings.effectiveSubtitleUpcomingLineCount)) }
            guard let lyrics = player.lyrics else { return [] }
            let active = lyrics.activeIndex(at: time) ?? 0
            let window = LatticeLyrics.window(activeIndex: active, lineCount: lyrics.lines.count, before: 0, after: settings.effectiveSubtitleUpcomingLineCount)
            // `window` clamps its indices to the line range, so direct
            // indexing is safe.
            return window.map { lyrics.lines[$0] }.filter { $0.id != line.id }
        }()

        if translation != nil || romaji != nil || !upcoming.isEmpty {
            VStack(spacing: 8) {
                if let translation, !translation.isEmpty {
                    Text(translation)
                        .font(subtitleFont(size: LuminousLyrics.translationFontSize(for: size.width, scale: scale)))
                        .foregroundColor(.white.opacity(0.85 * overlayOpacity))
                        .multilineTextAlignment(.center)
                }
                if let romaji, !romaji.isEmpty {
                    Text(romaji)
                        .font(subtitleFont(size: LuminousLyrics.upcomingFontSize(for: size.width, scale: scale)))
                        .foregroundColor(.white.opacity(0.7 * overlayOpacity))
                        .multilineTextAlignment(.center)
                }
                ForEach(upcoming, id: \.id) { next in
                    Text(next.text)
                        .font(subtitleFont(size: LuminousLyrics.upcomingFontSize(for: size.width, scale: scale)))
                        .foregroundColor(.white.opacity(0.35 * overlayOpacity))
                        .blur(radius: settings.effectiveSubtitleUpcomingLyricsBlur ? 1 : 0)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, settings.effectiveSubtitleBackgroundEnabled ? 12 : 0)
            .padding(.vertical, settings.effectiveSubtitleBackgroundEnabled ? 8 : 0)
            .background {
                if settings.effectiveSubtitleBackgroundEnabled {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                }
            }
        }
    }
}

// MARK: - Subtitle content mode

extension SubtitleContentMode {
    var showsTranslation: Bool { self == .translation || self == .both }
    var showsRomaji: Bool { self == .romaji || self == .both }
}
