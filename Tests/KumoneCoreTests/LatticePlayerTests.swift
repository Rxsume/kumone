import Foundation
import Testing

@testable import KumoneCore

/// Pure logic behind the Folia Lattice player (P2): the lyrics-card window
/// around the active line, the per-word sweep opacities, and the cover-wall
/// grid math. No UI, no player — just the functions the views call.
@Suite struct LatticePlayerTests {

    // MARK: - Lyrics window

    @Test func windowCentresOnTheActiveLine() {
        #expect(LatticeLyrics.window(activeIndex: 5, lineCount: 10) == [4, 5, 6, 7])
    }

    @Test func windowClampsAtTheStartAndEnd() {
        #expect(LatticeLyrics.window(activeIndex: 0, lineCount: 10) == [0, 1, 2])
        #expect(LatticeLyrics.window(activeIndex: 9, lineCount: 10) == [8, 9])
        #expect(LatticeLyrics.window(activeIndex: 1, lineCount: 10) == [0, 1, 2, 3])
    }

    @Test func windowWithNoActiveLineStartsAtTheTop() {
        #expect(LatticeLyrics.window(activeIndex: nil, lineCount: 10) == [0, 1, 2])
    }

    @Test func windowWithFewerLinesThanTheWindowShowsThemAll() {
        #expect(LatticeLyrics.window(activeIndex: 1, lineCount: 2) == [0, 1])
        #expect(LatticeLyrics.window(activeIndex: 0, lineCount: 1) == [0])
    }

    @Test func windowWithNoLinesIsEmpty() {
        #expect(LatticeLyrics.window(activeIndex: nil, lineCount: 0) == [])
        #expect(LatticeLyrics.window(activeIndex: 3, lineCount: 0) == [])
    }

    @Test func windowClampsAnOutOfRangeActiveIndex() {
        #expect(LatticeLyrics.window(activeIndex: 99, lineCount: 4) == [2, 3])
        #expect(LatticeLyrics.window(activeIndex: -2, lineCount: 4) == [0, 1, 2])
    }

    // MARK: - Per-word sweep

    private func line(words: [(String, TimeInterval, TimeInterval)]) -> LyricLine {
        let made = words.map { LyricWord(text: $0.0, start: $0.1, duration: $0.2) }
        return LyricLine(
            id: 0,
            time: made.first?.start ?? 0,
            end: made.last?.end ?? 0,
            text: made.map(\.text).joined(),
            words: made
        )
    }

    @Test func wordAlphasAreDimBeforeTheLineStarts() {
        let result = LatticeLyrics.wordAlphas(line: line(words: [("hello", 10, 2), ("world", 12, 2)]), at: 9)
        #expect(result.map { $0.text } == ["hello", "world"])
        for (_, alpha) in result {
            #expect(abs(alpha - 0.28) < 1e-6)
        }
    }

    @Test func wordAlphasAreFullAfterTheLineEnds() {
        let result = LatticeLyrics.wordAlphas(line: line(words: [("hello", 10, 2), ("world", 12, 2)]), at: 20)
        for (_, alpha) in result {
            #expect(abs(alpha - 1) < 1e-6)
        }
    }

    @Test func wordAlphasSweepWordByWord() {
        // Halfway through "hello" (10…12): its letters average ~0.64, and
        // "world" (12…14) has not started yet.
        let result = LatticeLyrics.wordAlphas(line: line(words: [("hello", 10, 2), ("world", 12, 2)]), at: 11)
        #expect(result.count == 2)
        #expect(result[0].alpha > 0.28 && result[0].alpha < 1)
        #expect(abs(result[1].alpha - 0.28) < 1e-6)
    }

    @Test func wordAlphasWithoutWordTimingsReturnOneFullChunk() {
        let plain = LyricLine(id: 0, time: 0, end: 6, text: "no timing here", words: nil)
        let result = LatticeLyrics.wordAlphas(line: plain, at: 3)
        #expect(result.count == 1)
        #expect(result[0].text == "no timing here")
        #expect(result[0].alpha == 1)
    }

    // MARK: - Wall grid math

    @Test func wallColumnsFitTheWidth() {
        // (390 + 8) / (76 + 8) = 4.73 -> 4 columns of ~91.5 pt.
        #expect(LatticeWallLayout.columns(for: 390) == 4)
        #expect(abs(LatticeWallLayout.tileSize(for: 390, columns: 4) - 91.5) < 1e-6)
    }

    @Test func wallColumnsNeverDropBelowOne() {
        #expect(LatticeWallLayout.columns(for: 0) == 1)
        #expect(LatticeWallLayout.columns(for: -10) == 1)
        #expect(LatticeWallLayout.columns(for: 50) == 1)
        #expect(LatticeWallLayout.tileSize(for: 50, columns: 1) == 50)
    }

    @Test func wallTileSizeAccountsForSpacing() {
        // 3 columns across 300 with 8 pt gaps: (300 - 16) / 3.
        #expect(abs(LatticeWallLayout.tileSize(for: 300, columns: 3) - 284.0 / 3) < 1e-6)
        #expect(LatticeWallLayout.tileSize(for: 300, columns: 0) == 0)
    }
}
