import SwiftUI

/// Folia Lattice (P2) big-lyrics card: one static big-text style, modelled
/// on Folia's Lattice card — large current line with a per-word sweep,
/// dimmed surrounding lines, translation/romaji rows under the active line.
/// Rendered on SwiftUI Canvas (no WebGL/PixiJS: Folia's GPU texture
/// rasterizer is not portable); the sweep rides the existing
/// `LyricLine.words` timings through `LyricMainText.alphas`, the same
/// per-character wipe the karaoke line uses.
enum LatticeLyrics {
    /// Indices of the lines shown around the active line: `before` lines
    /// above it, the active line, `after` lines below it, clamped to the
    /// available lines. A nil active index shows the first lines.
    static func window(activeIndex: Int?, lineCount: Int, before: Int = 1, after: Int = 2) -> [Int] {
        guard lineCount > 0 else { return [] }
        let active = activeIndex.map { min(max($0, 0), lineCount - 1) } ?? 0
        let start = max(0, active - before)
        let end = min(lineCount - 1, active + after)
        return Array(start...end)
    }

    /// One (text, opacity) pair per word of the line: the sweep rides
    /// `LyricMainText.alphas` (one opacity per character), averaged over
    /// each word's characters. A line with no word timings comes back as a
    /// single full-brightness chunk.
    static func wordAlphas(line: LyricLine, at time: TimeInterval) -> [(text: String, alpha: Double)] {
        guard let words = line.words, !words.isEmpty else {
            return [(line.text, 1)]
        }
        let alphas = LyricMainText.alphas(for: line, words: words, at: time)
        var result: [(String, Double)] = []
        var offset = 0
        for word in words {
            let count = word.text.count
            let slice = alphas.dropFirst(offset).prefix(count)
            let alpha: Double
            if slice.isEmpty {
                alpha = alphas.last ?? 1
            } else {
                alpha = slice.reduce(0, +) / Double(slice.count)
            }
            result.append((word.text, alpha))
            offset += count
        }
        return result
    }
}

struct LatticeLyricsCard: View {
    let lyrics: ParsedLyrics?
    let activeIndex: Int?
    let accent: Color
    let tint: Color
    let showTranslation: Bool
    let showRomaji: Bool
    /// The wipe advances only while this is true (playing and not in
    /// static mode); otherwise the card draws once at the frozen time.
    let animate: Bool
    /// Lyric font-size scale (Folia's `lyricsFontScale`): the card's sizes
    /// follow it, so the Lattice card and the luminous mode agree.
    var fontScale: CGFloat = 1

    /// Lyric-style settings (D9): the card used to hardcode `.system`
    /// fonts and ignore these — they now match the luminous view, which
    /// reads the same effective values.
    var fontStyle: LyricsFontStyle = .sans
    var fontWeight: Font.Weight = .bold
    var customFontName: String? = nil
    var wordRotation: Bool = false
    var breathingFloat: Double = 0
    var wordSpacing: CGFloat = 0
    var avoidOverlap: Bool = false
    /// Overall lyric opacity (Folia's `visualizerOpacity`).
    var opacity: Double = 1

    @EnvironmentObject private var player: PlayerService

    /// One visual row inside the card: a run of chunks laid out left to
    /// right, wrapping only inside the active line's words.
    private struct WordChunk {
        var text: String
        var alpha: Double
        /// The word's deterministic ±5° tilt when word rotation is on,
        /// else 0. Static rows (translation, romaji, surrounding lines)
        /// always carry 0.
        var rotation: Double = 0
    }

    private struct VisualRow {
        var chunks: [WordChunk]
        var font: Font
        var fontSize: CGFloat
        /// Gap below this row before the next one.
        var gapAfter: CGFloat

        var height: CGFloat { fontSize * 1.35 }
    }

    /// The lyric font at `size`, mirroring `LuminousLyricsView.lyricFont`:
    /// the custom font when one is set, else the selected style's design,
    /// at the given weight.
    private func lyricFont(size: CGFloat, weight: Font.Weight) -> Font {
        if let custom = customFontName, !custom.isEmpty {
            return Font.custom(custom, size: size).weight(weight)
        }
        return .system(size: size, weight: weight, design: fontStyle.design)
    }

    /// Gap between two words on a row: the configured word spacing, plus
    /// a rotation clearance when word rotation is on and overlap is to be
    /// avoided — a ±5° tilt widens a word's footprint by ~sin(5°) of its
    /// height. With overlap allowed the tilt may kiss its neighbour,
    /// which is what the toggle means.
    private func interWordGap(for fontSize: CGFloat) -> CGFloat {
        wordSpacing + (wordRotation && avoidOverlap ? fontSize * 0.1 : 0)
    }

    /// Whole-card breathing float, mirroring the luminous line's: only
    /// while the card animates (playing, not static); still otherwise.
    /// `time` is the live deck position, as in `drawCard`.
    private var breathingYOffset: CGFloat {
        guard animate, breathingFloat > 0 else { return 0 }
        return LuminousLyrics.breathingOffset(at: player.livePlaybackTime, multiplier: breathingFloat)
    }

    private var breathingScaleFactor: CGFloat {
        guard animate, breathingFloat > 0 else { return 1 }
        return LuminousLyrics.breathingScale(at: player.livePlaybackTime, multiplier: breathingFloat)
    }

    private var activeFontSize: CGFloat { 34 * fontScale }
    private var surroundingFontSize: CGFloat { 20 * fontScale }
    private var secondaryFontSize: CGFloat { 15 * fontScale }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(tint.opacity(0.16))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(accent.opacity(0.35), lineWidth: 1)
                }
            canvasContent
                .padding(20)
                // D9: breathing float + overall opacity, as in the luminous
                // view (still while paused/static — see `breathingYOffset`).
                .offset(y: breathingYOffset)
                .scaleEffect(breathingScaleFactor)
        }
        .opacity(opacity)
    }

    private var canvasContent: some View {
        Group {
            if animate {
                TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
                    canvas
                }
            } else {
                canvas
            }
        }
    }

    private var canvas: some View {
        Canvas { context, size in
            drawCard(context: &context, size: size)
        }
        .accessibilityLabel("歌词")
    }

    private func drawCard(context: inout GraphicsContext, size: CGSize) {
        guard let lyrics, !lyrics.lines.isEmpty else {
            let placeholder = lyrics == nil ? "歌词加载中…" : "暂无歌词"
            let resolved = context.resolve(
                Text(placeholder)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
            )
            context.draw(resolved, at: CGPoint(x: 0, y: (size.height - resolved.measure(in: size).height) / 2), anchor: .topLeading)
            return
        }

        let time = player.livePlaybackTime
        let lines = lyrics.lines
        let active = activeIndex.map { min(max($0, 0), lines.count - 1) } ?? 0
        let indices = LatticeLyrics.window(activeIndex: activeIndex, lineCount: lines.count)

        // Pass 1: lay out every row (measuring through the context) so the
        // window can be centred vertically in the card.
        var rows: [VisualRow] = []
        for index in indices {
            let line = lines[index]
            if index == active {
                rows.append(contentsOf: layoutWords(
                    LatticeLyrics.wordAlphas(line: line, at: time),
                    line: line,
                    font: lyricFont(size: activeFontSize, weight: fontWeight),
                    fontSize: activeFontSize,
                    maxWidth: size.width,
                    in: &context
                ))
                if showTranslation, let translation = line.translation, !translation.isEmpty {
                    rows.append(VisualRow(
                        chunks: [WordChunk(text: translation, alpha: 0.6)],
                        font: lyricFont(size: secondaryFontSize, weight: .regular),
                        fontSize: secondaryFontSize,
                        gapAfter: 2
                    ))
                }
                if showRomaji, let romaji = line.romaji, !romaji.isEmpty {
                    rows.append(VisualRow(
                        chunks: [WordChunk(text: romaji, alpha: 0.55)],
                        font: lyricFont(size: secondaryFontSize, weight: .regular),
                        fontSize: secondaryFontSize,
                        gapAfter: 2
                    ))
                }
                // Gap between the active line block and the next line.
                if let last = rows.indices.last {
                    rows[last].gapAfter = 12
                }
            } else {
                rows.append(VisualRow(
                    chunks: [WordChunk(text: line.text, alpha: 0.4)],
                    font: lyricFont(size: surroundingFontSize, weight: .semibold),
                    fontSize: surroundingFontSize,
                    gapAfter: 12
                ))
            }
        }
        if let last = rows.indices.last {
            rows[last].gapAfter = 0
        }

        let totalHeight = rows.reduce(0) { $0 + $1.height + $1.gapAfter }
        var y = max(0, (size.height - totalHeight) / 2)

        // Pass 2: draw.
        for row in rows {
            var x: CGFloat = 0
            for (chunkIndex, chunk) in row.chunks.enumerated() {
                let resolved = context.resolve(
                    Text(chunk.text)
                        .font(row.font)
                        .foregroundColor(.white.opacity(chunk.alpha))
                )
                // Unconstrained measure: a width cap would wrap a single
                // chunk and report the cap, breaking the x accumulation.
                let width = resolved.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).width
                if chunk.rotation != 0 {
                    // Tilt about the word's centre so the rotation does not
                    // shift the word along the row.
                    let center = CGPoint(x: x + width / 2, y: y + row.height / 2)
                    let savedTransform = context.transform
                    context.translateBy(x: center.x, y: center.y)
                    context.rotate(by: .degrees(chunk.rotation))
                    context.translateBy(x: -center.x, y: -center.y)
                    context.draw(resolved, at: CGPoint(x: x, y: y), anchor: .topLeading)
                    context.transform = savedTransform
                } else {
                    context.draw(resolved, at: CGPoint(x: x, y: y), anchor: .topLeading)
                }
                x += width
                if chunkIndex < row.chunks.count - 1 {
                    x += interWordGap(for: row.fontSize)
                }
            }
            y += row.height + row.gapAfter
        }
    }

    /// Wraps the active line's words into visual rows at `maxWidth`. A word
    /// carries its trailing space (the parser rides blanks on the word
    /// before them), so no extra space width is added between chunks — the
    /// gap is the configured word spacing (plus rotation clearance).
    private func layoutWords(
        _ words: [(text: String, alpha: Double)],
        line: LyricLine,
        font: Font,
        fontSize: CGFloat,
        maxWidth: CGFloat,
        in context: inout GraphicsContext
    ) -> [VisualRow] {
        let gap = interWordGap(for: fontSize)
        var rows: [VisualRow] = []
        var current: [WordChunk] = []
        var currentWidth: CGFloat = 0
        for (index, word) in words.enumerated() {
            let width = context.resolve(
                Text(word.text).font(font)
            ).measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).width
            // The word's deterministic tilt, shared with the luminous view
            // (`LuminousLyrics.placement`, ±5°); x/y offsets and scale stay
            // with the luminous layout — the lattice rows are sequential.
            let rotation = wordRotation
                ? LuminousLyrics.placement(seed: line.time, index: index, rotationEnabled: true).rotate
                : 0
            let chunk = WordChunk(text: word.text, alpha: word.alpha, rotation: rotation)
            if !current.isEmpty, currentWidth + gap + width > maxWidth {
                rows.append(VisualRow(chunks: current, font: font, fontSize: fontSize, gapAfter: 2))
                current = []
                currentWidth = 0
            }
            if !current.isEmpty { currentWidth += gap }
            current.append(chunk)
            currentWidth += width
        }
        if !current.isEmpty {
            rows.append(VisualRow(chunks: current, font: font, fontSize: fontSize, gapAfter: 2))
        }
        return rows
    }
}
