import Foundation
import Testing

@testable import KumoneCore

// Folia lyric filtering, ported: per-line rules and the leading
// staff-credits policy, both applied inside `LyricsParser.parse`
// (rules first, staff policy second). Pure tests, no network.
@Suite struct LyricFilterTests {

    private func response(lrc: String? = nil, yrc: String? = nil) -> LyricResponse {
        func body(_ text: String?) -> LyricResponse.LyricBody? {
            text.map { LyricResponse.LyricBody(lyric: $0) }
        }
        return LyricResponse(
            lrc: body(lrc), tlyric: nil, romalrc: nil, yrc: body(yrc), ytlrc: nil,
            yromalrc: nil, lyricUser: nil, transUser: nil, nolyric: nil, uncollected: nil)
    }

    /// A settings value with the built-in defaults, plus the given rules
    /// and staff policy.
    private func filter(
        rules: [LyricLineRule] = LyricLineRule.defaultRules,
        staffPolicy: LyricStaffPolicy = .keep,
        staffMinDwellSeconds: Double = LyricFilterSettings.defaultMinDwellSeconds,
        staffAbsorbMode: LyricStaffAbsorbMode = .off,
        staffPattern: String = "",
        title: String? = nil,
        artist: String? = nil
    ) -> LyricFilterSettings {
        LyricFilterSettings(
            rules: rules,
            staffPolicy: staffPolicy,
            staffMinDwellSeconds: staffMinDwellSeconds,
            staffAbsorbMode: staffAbsorbMode,
            staffPattern: staffPattern,
            title: title,
            artist: artist
        )
    }

    @Test func presetRuleRemovesMatchingLineAndKeepsTimingIntact() {
        let lrc = """
        [00:10.00]我爱你 hello world
        [00:14.00]版权所有 未经许可翻唱
        [00:30.00]最后
        """
        let rules = [LyricLineRule(shape: .preset, text: "copyright")]
        let parsed = LyricsParser.parse(response(lrc: lrc), filter: filter(rules: rules))
        #expect(parsed.lines.map(\.text) == ["我爱你 hello world", "最后"])
        // The kept lines' timings are untouched by the filter.
        #expect(parsed.lines[0].time == 10)
        #expect(parsed.lines[0].end == 14)
        #expect(parsed.lines[1].time == 30)
    }

    @Test func containsRuleRemovesMatchingLineOnly() {
        let lrc = "[00:10.00]第一行\n[00:14.00]这句有秘密\n[00:30.00]最后"
        let rules = [LyricLineRule(shape: .contains, text: "秘密")]
        let parsed = LyricsParser.parse(response(lrc: lrc), filter: filter(rules: rules))
        #expect(parsed.lines.map(\.text) == ["第一行", "最后"])
    }

    @Test func invalidRegexRuleIsSkippedWithoutCrashing() {
        let lrc = "[00:10.00]第一行\n[00:14.00]这句有秘密\n[00:30.00]最后"
        let rules = [
            LyricLineRule(shape: .written, text: "("),
            LyricLineRule(shape: .contains, text: "秘密"),
        ]
        let parsed = LyricsParser.parse(response(lrc: lrc), filter: filter(rules: rules))
        // The invalid rule is skipped; the valid one still applies.
        #expect(parsed.lines.map(\.text) == ["第一行", "最后"])
        #expect(LyricFilter.ruleError(rules[0]) != nil)
        #expect(LyricFilter.ruleError(rules[1]) == nil)
    }

    @Test func defaultRulesRemoveNoAuthorCreditButKeepRealCredits() {
        let lrc = """
        [00:00.00]作词：无
        [00:01.00]作曲：张三
        [00:03.00]第一句歌词
        """
        let parsed = LyricsParser.parse(response(lrc: lrc))
        #expect(parsed.lines.map(\.text) == ["作曲：张三", "第一句歌词"])
    }

    @Test func edgesOnlySparesMidSongLines() {
        let lrc = """
        [00:00.00]副歌副歌
        [00:05.00]第一句
        [00:10.00]副歌副歌
        [00:15.00]第二句
        [00:20.00]副歌副歌
        """
        let rules = [LyricLineRule(shape: .contains, text: "副歌", edgesOnly: true)]
        let parsed = LyricsParser.parse(response(lrc: lrc), filter: filter(rules: rules))
        // 5 lines: mid-song is index >= ceil(5/4)=2 and < 5-ceil(5/10)=4,
        // so only index 2 and 3 are mid-song; the matching line at index
        // 2 stays, the ones at 0 and 4 go.
        #expect(parsed.lines.map(\.text) == ["第一句", "副歌副歌", "第二句"])
    }

    // Three staff lines at 0/1/2 s, first lyric at 3 s: the intro window
    // is 3 s, the block needs 3 x 1.5 + 1 = 5.5 s.
    private var staffLrc: String {
        """
        [00:00.00]作词：张三
        [00:01.00]作曲：李四
        [00:02.00]编曲：王五
        [00:03.00]第一句歌词
        [00:06.00]第二句歌词
        """
    }

    @Test func staffHideRemovesLeadingBlock() {
        let parsed = LyricsParser.parse(response(lrc: staffLrc), filter: filter(staffPolicy: .hide))
        #expect(parsed.lines.map(\.text) == ["第一句歌词", "第二句歌词"])
    }

    @Test func staffKeepKeepsLeadingBlock() {
        let parsed = LyricsParser.parse(response(lrc: staffLrc), filter: filter(staffPolicy: .keep))
        #expect(parsed.lines.map(\.text) == ["作词：张三", "作曲：李四", "编曲：王五", "第一句歌词", "第二句歌词"])
    }

    @Test func staffSmartHidesWhenIntroIsTooShort() {
        // Smart rule: hide when the intro window cannot cover every
        // display line at min dwell plus the 1 s tail margin.
        let parsed = LyricsParser.parse(response(lrc: staffLrc), filter: filter(staffPolicy: .smart))
        #expect(parsed.lines.map(\.text) == ["第一句歌词", "第二句歌词"])
    }

    @Test func staffSmartKeepsWhenIntroFitsAndStampsAreWide() {
        // Staff at 0/2/4 s, first lyric at 10 s: the window (10 s) covers
        // 3 x 1.5 + 1 = 5.5 s, and the gaps (2, 2, 5 s) are all at least
        // min dwell, so the block stays exactly as written.
        let lrc = """
        [00:00.00]作词：张三
        [00:02.00]作曲：李四
        [00:04.00]编曲：王五
        [00:10.00]第一句歌词
        [00:14.00]第二句歌词
        """
        let parsed = LyricsParser.parse(response(lrc: lrc), filter: filter(staffPolicy: .smart))
        #expect(parsed.lines.map(\.text) == ["作词：张三", "作曲：李四", "编曲：王五", "第一句歌词", "第二句歌词"])
        #expect(parsed.lines[0].time == 0)
        #expect(parsed.lines[2].time == 4)
    }

    @Test func staffSmartRetimesWhenIntroFitsButStampsAreDense() {
        // Staff at 0/1/2 s, first lyric at 10 s: the window (10 s) covers
        // 5.5 s, but the 1 s gaps are under min dwell, so the block is
        // spread across the intro: slots of max((10-1-0)/3, 1.5) = 3 s.
        let lrc = """
        [00:00.00]作词：张三
        [00:01.00]作曲：李四
        [00:02.00]编曲：王五
        [00:10.00]第一句歌词
        [00:14.00]第二句歌词
        """
        let parsed = LyricsParser.parse(response(lrc: lrc), filter: filter(staffPolicy: .smart))
        #expect(parsed.lines.map(\.text) == ["作词：张三", "作曲：李四", "编曲：王五", "第一句歌词", "第二句歌词"])
        #expect(parsed.lines[0].time == 0)
        #expect(parsed.lines[0].end == 3)
        #expect(parsed.lines[1].time == 3)
        #expect(parsed.lines[1].end == 6)
        #expect(parsed.lines[2].time == 6)
        #expect(parsed.lines[2].end == 9)
        #expect(parsed.lines[3].time == 10)
        // The words' text still joins to the line's text after rescale.
        for line in parsed.lines {
            #expect(line.words?.map(\.text).joined() == line.text)
        }
    }

    @Test func staffAbsorbBeforePullsShortLineIntoHiddenBlock() {
        // A title line at 0 s (0.5 s long, under min dwell) sits before
        // the staff block; smart + a short intro hides the block, and
        // the absorbed title line goes with it.
        let lrc = """
        [00:00.00]歌名 - 歌手
        [00:00.50]作词：张三
        [00:01.00]作曲：李四
        [00:02.00]编曲：王五
        [00:03.00]第一句歌词
        [00:06.00]第二句歌词
        """
        let settings = filter(
            staffPolicy: .smart, staffAbsorbMode: .before, title: "歌名", artist: "歌手")
        let parsed = LyricsParser.parse(response(lrc: lrc), filter: settings)
        #expect(parsed.lines.map(\.text) == ["第一句歌词", "第二句歌词"])
    }

    @Test func customStaffPatternReplacesBuiltInList() {
        let lrc = """
        [00:00.00]FOO: Alpha
        [00:01.00]FOO: Beta
        [00:03.00]第一句歌词
        """
        let settings = filter(staffPolicy: .hide, staffPattern: #"^FOO:"#)
        let parsed = LyricsParser.parse(response(lrc: lrc), filter: settings)
        #expect(parsed.lines.map(\.text) == ["第一句歌词"])
    }

    @Test func invalidCustomStaffPatternFallsBackToBuiltInList() {
        let settings = filter(staffPolicy: .hide, staffPattern: "(")
        let parsed = LyricsParser.parse(response(lrc: staffLrc), filter: settings)
        #expect(parsed.lines.map(\.text) == ["第一句歌词", "第二句歌词"])
        #expect(LyricStaffCredits.patternError("(") != nil)
    }

    @Test func builtInStaffMatcherRecognizesCanonicalCredits() {
        // Regression: the built-in pattern must actually contain the
        // keyword group — a version that only asked for a colon at the
        // line start matched nothing and the whole staff detection
        // was dead.
        let matcher = LyricStaffCredits.staffMatcher(pattern: "")
        func line(_ text: String) -> LyricLine {
            LyricLine(id: 0, time: 0, end: 1, text: text,
                      translation: nil, romaji: nil, furigana: nil, words: nil)
        }
        #expect(matcher(line("作词：张三")))
        #expect(matcher(line("作曲：李四")))
        #expect(matcher(line("编曲：王五")))
        #expect(matcher(line("录音 Recording Studio：ABC")))
        #expect(matcher(line("混音/母带：X")))
        #expect(!matcher(line("鼓起勇气：向前走")))
        #expect(!matcher(line("他说：我爱你")))
        #expect(!matcher(line("第一句歌词")))
    }

    @Test func decodeRulesKeepsExplicitEmptyList() {
        // Missing or corrupt storage -> the defaults; an explicitly
        // empty array stays empty (the user deleted every rule).
        #expect(LyricFilterSettings.decodeRules(from: nil) == LyricLineRule.defaultRules)
        #expect(LyricFilterSettings.decodeRules(from: "not json") == LyricLineRule.defaultRules)
        #expect(LyricFilterSettings.decodeRules(from: "[]") == [])
        let encoded = LyricFilterSettings.encodeRules(LyricLineRule.defaultRules)
        #expect(LyricFilterSettings.decodeRules(from: encoded) == LyricLineRule.defaultRules)
    }

    @Test func singleStaffLineIsNeverTouched() {
        // One lone credit line is not a block: it stays, even under hide.
        let lrc = """
        [00:00.00]作词：张三
        [00:03.00]第一句歌词
        """
        let parsed = LyricsParser.parse(response(lrc: lrc), filter: filter(staffPolicy: .hide))
        #expect(parsed.lines.map(\.text) == ["作词：张三", "第一句歌词"])
    }
}
