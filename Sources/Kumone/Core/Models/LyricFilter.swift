// Sources/Kumone/Core/Models/LyricFilter.swift
//
// Folia lyric filtering, ported to Swift (Folia `lyricLineRules.ts` +
// `filtering.ts` + `useLyricSettingsStore.ts`).
//
// Two independent mechanisms live here and in `LyricStaffCredits.swift`:
// per-line regex rules (this file) and the leading staff-credits policy
// (`LyricStaffCredits.swift`). Both run inside `LyricsParser.parse`,
// filter rules first, staff policy second, so they compose and so cached
// and freshly-fetched lyrics behave identically.
//
// One deliberate deviation from Folia: Folia applies the line rules
// "where lyrics are shown, never where they are parsed or cached", so a
// rule change needs no new fetch. Golia stores the parsed lyrics in the
// offline cache, so the rules run at parse time instead — otherwise a
// cached song and a fresh song would show different lines.

import Foundation

/// One user-configurable per-line filter rule (Folia `LyricLineRule`).
/// A line is removed when any enabled rule matches its full text.
struct LyricLineRule: Codable, Hashable, Identifiable {
    enum Shape: String, Codable, CaseIterable {
        case starts, contains, whole, ends, preset, written

        var displayName: String {
            switch self {
            case .starts: return "开头是"
            case .contains: return "包含"
            case .whole: return "整行是"
            case .ends: return "结尾是"
            case .preset: return "预设"
            case .written: return "正则表达式"
            }
        }
    }

    var id: String
    var isOn: Bool
    var shape: Shape
    /// The words, one to a line (a preset's id for `preset`, the
    /// expression for `written`).
    var text: String
    /// `starts` only: the words are followed by a colon.
    var colon: Bool
    /// Lines in the middle of a song stay.
    var edgesOnly: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case isOn = "on"
        case shape, text, colon, edgesOnly
    }

    init(
        id: String = "rule-\(UUID().uuidString.prefix(8))",
        isOn: Bool = true,
        shape: Shape,
        text: String,
        colon: Bool = false,
        edgesOnly: Bool = false
    ) {
        self.id = id
        self.isOn = isOn
        self.shape = shape
        self.text = text
        self.colon = colon
        self.edgesOnly = edgesOnly
    }

    /// Ready-made rules (Folia `LYRIC_LINE_PRESETS`): a line holding any
    /// of the words goes.
    static let presets: [(id: String, words: [String])] = [
        ("copyright", ["版权所有", "未经许可", "未经授权", "不得翻唱", "禁止翻唱", "侵权必究", "all rights reserved", "copyright", "©", "℗"]),
        ("lyricSource", ["歌词贡献者", "翻译贡献者", "歌词来源", "歌词来自", "歌词提供", "歌词制作", "歌词校对", "lrc by"]),
    ]

    static func presetDisplayName(_ id: String) -> String {
        switch id {
        case "copyright": return "版权声明"
        case "lyricSource": return "歌词来源"
        default: return id
        }
    }

    static func presetWords(_ id: String) -> [String]? {
        presets.first { $0.id == id }?.words
    }

    /// The built-in strips `LyricsParser.parse` used to apply on its own
    /// (Folia has no default rules; Golia's defaults reproduce the strips
    /// that were in the parser before this port, so nothing changes for
    /// anyone who never opens the filter page): a credit line with no
    /// credited author, `作词：无` / `作曲：无`.
    static let defaultRules: [LyricLineRule] = [
        LyricLineRule(
            id: "builtin-no-author", isOn: true, shape: .written,
            text: #"^作(词|曲)\s*[:：]\s*无$"#)
    ]
}

/// The filter settings a parse runs with: the user's rules, the staff
/// policy, and the track's title/artist (only used to tolerate a title
/// line ahead of a staff block).
struct LyricFilterSettings: Hashable {
    /// A pathological user regex must never hang lyric loading: the rule
    /// count is capped, and every rule's regex is compiled once per parse.
    /// Lyric lines are short (< 200 chars) and each rule tests a line
    /// once, so the per-line work stays bounded.
    static let maxRules = 50
    static let defaultMinDwellSeconds = 1.5
    static let minDwellRange = 0.6...4.0

    var rules: [LyricLineRule] = LyricLineRule.defaultRules
    var staffPolicy: LyricStaffPolicy = .keep
    var staffMinDwellSeconds: Double = defaultMinDwellSeconds
    var staffAbsorbMode: LyricStaffAbsorbMode = .off
    var staffPattern: String = ""
    var title: String?
    var artist: String?

    /// Today's behaviour: the built-in strips only, staff kept as-is.
    /// `LyricsParser.parse` uses this when no settings are passed, so
    /// existing callers and tests keep today's output.
    static var `default`: LyricFilterSettings { LyricFilterSettings() }

    /// The user's effective settings for a track (Folia master switch
    /// gates the user rules/policy back to today's behaviour when off).
    @MainActor static func effective(for track: Track?) -> LyricFilterSettings {
        let settings = SettingsManager.shared
        return LyricFilterSettings(
            rules: settings.effectiveLyricLineRules,
            staffPolicy: settings.effectiveLyricStaffPolicy,
            staffMinDwellSeconds: settings.effectiveLyricStaffMinDwellSeconds,
            staffAbsorbMode: settings.effectiveLyricStaffAbsorbMode,
            staffPattern: settings.effectiveLyricStaffPattern,
            title: track?.name,
            artist: track?.artists.first?.name
        )
    }

    static func clampedDwell(_ value: Double) -> Double {
        guard value.isFinite else { return defaultMinDwellSeconds }
        return min(max(value, minDwellRange.lowerBound), minDwellRange.upperBound)
    }

    /// Decodes the stored rules (a JSON array, Folia `readLyricLineRules`
    /// shape): unknown entries are dropped, the count is capped, and a
    /// missing/empty store yields the default rules. An explicitly empty
    /// array stays empty — the user deleted every rule on purpose and
    /// the defaults must not come back on the next launch.
    static func decodeRules(from json: String?) -> [LyricLineRule] {
        guard let json, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([LyricLineRule].self, from: data)
        else { return LyricLineRule.defaultRules }
        let valid = decoded.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return Array(valid.prefix(maxRules))
    }

    static func encodeRules(_ rules: [LyricLineRule]) -> String {
        (try? JSONEncoder().encode(Array(rules.prefix(maxRules))))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// The rules that are on and remove something, each with its regex
    /// compiled once (Folia `compileLyricLineRules`). Invalid regexes
    /// compile to nil and are skipped — never a crash.
    var compiledRules: [CompiledLyricLineRule] {
        rules.compactMap { rule in
            guard rule.isOn, let regex = LyricFilter.compile(rule: rule) else { return nil }
            return CompiledLyricLineRule(rule: rule, regex: regex)
        }
    }
}

struct CompiledLyricLineRule {
    let rule: LyricLineRule
    let regex: NSRegularExpression
}

enum LyricFilter {
    /// Full-width ASCII (ＯＰ：) as ASCII; one character for one, so a
    /// match's position is the same in the line as shown (Folia
    /// `foldWidth`).
    static func foldWidth(_ text: String) -> String {
        String(text.unicodeScalars.map { scalar in
            (0xFF01...0xFF5E).contains(scalar.value)
                ? Character(UnicodeScalar(scalar.value - 0xFEE0)!)
                : Character(scalar)
        })
    }

    /// The words of a rule (starts, contains, whole, ends), one to a line
    /// of its text: a line matches any of them (Folia `lyricLineRuleWords`).
    static func ruleWords(_ text: String) -> [String] {
        Array(Set(text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }))
    }

    /// A line as a rule tests it: a written rule as it is, the others with
    /// full width folded (Folia `lyricLineAsRuleSees`).
    static func textAsRuleSees(_ rule: LyricLineRule, _ text: String) -> String {
        rule.shape == .written ? text : foldWidth(text)
    }

    /// The expression a rule tests each line with, or nil when it removes
    /// nothing (no words, an unknown preset, an expression that is not
    /// valid). Words match ignoring case and full width; a written rule is
    /// compiled exactly as written (Folia `compileLyricLineRule`).
    static func compile(rule: LyricLineRule) -> NSRegularExpression? {
        switch rule.shape {
        case .written:
            return try? NSRegularExpression(pattern: rule.text)
        case .preset:
            guard let words = LyricLineRule.presetWords(rule.text) else { return nil }
            let body = words.map { NSRegularExpression.escapedPattern(for: foldWidth($0)) }.joined(separator: "|")
            return try? NSRegularExpression(pattern: body, options: .caseInsensitive)
        default:
            let words = ruleWords(foldWidth(rule.text))
            guard !words.isEmpty else { return nil }
            // Longest first: of two words at one place, the match covers
            // the whole of the longer.
            let body = "(?:\(words.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")))"
            let pattern: String
            switch rule.shape {
            case .starts:
                pattern = "^\\s*\(body)\(rule.colon ? "\\s*[:：]" : "")"
            case .whole:
                pattern = "^\\s*\(body)\\s*$"
            case .ends:
                pattern = "\(body)\\s*$"
            case .contains:
                pattern = body
            case .written, .preset:
                return nil
            }
            return try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        }
    }

    /// Why a written rule removes nothing, or nil (Folia
    /// `getLyricLineRuleError`).
    static func ruleError(_ rule: LyricLineRule) -> String? {
        guard rule.shape == .written else { return nil }
        let text = rule.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        do {
            _ = try NSRegularExpression(pattern: text)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// A line after the first quarter and before the last tenth of a
    /// song's lines. Rough: it only warns, or spares with edgesOnly
    /// (Folia `isMidSongLine`).
    static func isMidSongLine(_ index: Int, total: Int) -> Bool {
        guard total > 0 else { return false }
        let firstQuarterEnd = (total + 3) / 4
        let lastTenthStart = total - (total + 9) / 10
        return index >= firstQuarterEnd && index < lastTenthStart
    }

    /// Whether one rule removes the line at `index` of `total`.
    static func ruleHits(_ compiled: CompiledLyricLineRule, text: String, index: Int, total: Int) -> Bool {
        guard !(compiled.rule.edgesOnly && isMidSongLine(index, total: total)) else { return false }
        let seen = textAsRuleSees(compiled.rule, text)
        let range = NSRange(seen.startIndex..., in: seen)
        return compiled.regex.firstMatch(in: seen, options: [], range: range) != nil
    }

    /// The lines without the ones the rules remove. Filtering drops whole
    /// timed lines (their text, translation, romaji and word timings go
    /// together), so a kept line's timing is untouched (Folia
    /// `applyLyricLineRules`, minus its interlude handling — Golia has no
    /// interlude lines).
    static func applyRules(_ lines: [LyricLine], settings: LyricFilterSettings) -> [LyricLine] {
        let compiled = settings.compiledRules
        guard !compiled.isEmpty, !lines.isEmpty else { return lines }
        let total = lines.count
        return lines.enumerated().filter { index, line in
            !compiled.contains { ruleHits($0, text: line.text, index: index, total: total) }
        }.map(\.element)
    }
}
