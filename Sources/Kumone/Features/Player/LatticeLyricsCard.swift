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

    @EnvironmentObject private var player: PlayerService

    /// One visual row inside the card: a run of chunks laid out left to
    /// right, wrapping only inside the active line's words.
    private struct VisualRow {
        var chunks: [(text: String, alpha: Double)]
        var font: Font
        var fontSize: CGFloat
        /// Gap below this row before the next one.
        var gapAfter: CGFloat

        var height: CGFloat { fontSize * 1.35 }
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
        }
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
                    font: .system(size: activeFontSize, weight: .bold),
                    fontSize: activeFontSize,
                    maxWidth: size.width,
                    in: &context
                ))
                if showTranslation, let translation = line.translation, !translation.isEmpty {
                    rows.append(VisualRow(
                        chunks: [(translation, 0.6)],
                        font: .system(size: secondaryFontSize),
                        fontSize: secondaryFontSize,
                        gapAfter: 2
                    ))
                }
                if showRomaji, let romaji = line.romaji, !romaji.isEmpty {
                    rows.append(VisualRow(
                        chunks: [(romaji, 0.55)],
                        font: .system(size: secondaryFontSize),
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
                    chunks: [(line.text, 0.4)],
                    font: .system(size: surroundingFontSize, weight: .semibold),
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
            for chunk in row.chunks {
                let resolved = context.resolve(
                    Text(chunk.text)
                        .font(row.font)
                        .foregroundColor(.white.opacity(chunk.alpha))
                )
                // Unconstrained measure: a width cap would wrap a single
                // chunk and report the cap, breaking the x accumulation.
                let width = resolved.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).width
                context.draw(resolved, at: CGPoint(x: x, y: y), anchor: .topLeading)
                x += width
            }
            y += row.height + row.gapAfter
        }
    }

    /// Wraps the active line's words into visual rows at `maxWidth`. A word
    /// carries its trailing space (the parser rides blanks on the word
    /// before them), so no extra space width is added between chunks.
    private func layoutWords(
        _ words: [(text: String, alpha: Double)],
        font: Font,
        fontSize: CGFloat,
        maxWidth: CGFloat,
        in context: inout GraphicsContext
    ) -> [VisualRow] {
        var rows: [VisualRow] = []
        var current: [(text: String, alpha: Double)] = []
        var currentWidth: CGFloat = 0
        for word in words {
            let width = context.resolve(
                Text(word.text).font(font)
            ).measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).width
            if !current.isEmpty, currentWidth + width > maxWidth {
                rows.append(VisualRow(chunks: current, font: font, fontSize: fontSize, gapAfter: 2))
                current = []
                currentWidth = 0
            }
            current.append(word)
            currentWidth += width
        }
        if !current.isEmpty {
            rows.append(VisualRow(chunks: current, font: font, fontSize: fontSize, gapAfter: 2))
        }
        return rows
    }
}
