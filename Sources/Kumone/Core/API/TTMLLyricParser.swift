import Foundation

// TTML lyric parser for the AMLL provider: converts the AMLL TTML DB's
// word-timed TTML into the plain LRC / YRC text the app's LyricsParser
// already understands.
//
// Faithful port of Folia's TTML path (`parseTTML` in parserCore.ts), which
// is `TTMLParser.parse` from `@applemusic-like-lyrics/ttml` 1.0.1 plus
// `buildLyricDataFromTTMLResult` in ttmlConversion.ts. The reference
// parser's rules are reproduced below; deliberate deviations are marked
// DEVIATION with the reason.
//
// A TTML line is one `<p>` inside `<body>` / `<div>`:
//   <p begin="00:01.500" end="00:04.000" itunes:key="L1">
//     <span begin="00:01.500" end="00:01.900">Hello</span> <span begin="00:01.900" end="00:04.000">world</span>
//     <span ttm:role="x-translation">你好世界</span>
//     <span ttm:role="x-roman">konnichiwa sekai</span>
//   </p>
//
// Parsing rules (reference `TTMLParser`):
// - Time: a trailing "s" means an offset in seconds ("12.5s" -> 12500 ms;
//   "12500ms" does not parse and yields 0); otherwise a clock time
//   `[HH:]MM:SS[.fff]` or plain seconds. `dur` is never read.
// - A `<span>` with both `begin` and `end` is a timed word; its text is
//   whitespace-collapsed then trimmed. A leading space marks the previous
//   word as ending with a space; a trailing space marks the word itself.
//   A span without both attributes still contributes its text to the line
//   but produces no word.
// - Whitespace-only text nodes that contain a newline are formatting and
//   are skipped; other whitespace-only runs mark the previous word as
//   ending with a space. All other text is whitespace-collapsed and joins
//   the line text.
// - `ttm:role="x-translation"` / `"x-roman"` spans are the line's
//   translation / romanization (text only; their own timings are ignored).
//   `ttm:role="x-bg"` is a background vocal: its words count for the
//   word-by-word determination and its time range widens the line, but its
//   text is not part of the main line.
// - A `tts:ruby="container"` span contributes its `tts:ruby="base"` text
//   as one word, timed from the earliest to the latest `tts:ruby="text"`
//   reading; the readings themselves are dropped.
// - Line time: the `<p>` begin/end, widened to cover any timed word or
//   background vocal that sticks out; a missing bound is taken from the
//   children. A line with text but no timed words gets one fallback word
//   spanning the line, so word-by-word output keeps the line.
// - Translations / romanizations also come from the `<iTunesMetadata>`
//   sidecar (`<text for="L1">`), keyed by the line's `itunes:key`; inline
//   spans win because the sidecar entries are appended after them.
// - Word-by-word: the root `itunes:timing` attribute when it is "Word" or
//   "Line"; otherwise any line with more than one timed word (main or
//   background vocal) makes the file word-timed.
// - Empty lines (no text) are dropped.
//
// DEVIATION — key-less lines are kept: the reference parser drops a `<p>`
// without `itunes:key` entirely. AMLL DB files from the official tool
// always carry keys, so this only matters for looser producers, where
// dropping the line would lose the whole song for no benefit.
// DEVIATION — no agent-overlap folding: Folia folds a later `<p>` with a
// different `ttm:agent` that overlaps an earlier line into that line's
// background vocal. Golia's LyricLine has no background-vocal slot, so
// both voices stay as separate lines; the later one wins the active-line
// lookup while they overlap, which is the closest rendering available.
// DEVIATION — background-vocal text is dropped outright (same reason:
// no slot for it), rather than kept as a background vocal.

/// One timed word (syllable) inside a TTML line. Times are absolute
/// milliseconds from the start of the track, as the reference parser
/// reports them.
struct TTMLWord {
    var text: String
    let startMs: Int
    let endMs: Int
    /// A space follows this word (inter-word whitespace in the TTML).
    var endsWithSpace: Bool
}

/// One TTML `<p>` line, with absolute millisecond times.
struct TTMLLine {
    let startMs: Int
    let endMs: Int
    let text: String
    let words: [TTMLWord]
    let translation: String?
    let romanization: String?
    /// Timed words in the line's background vocal (`x-bg` span), if any.
    /// Only used for the word-by-word determination; background vocals are
    /// not emitted into LRC/YRC (LyricLine has no background-vocal slot).
    let backgroundWordCount: Int
}

/// The parsed TTML document, plus the LRC / YRC renderings the provider
/// puts into a `LyricResponse`.
struct TTMLParseResult {
    let lines: [TTMLLine]
    let isWordByWord: Bool

    /// `[mm:ss.cc]text` per line — the shape `LyricsParser.parseLRC` reads.
    func lrcText() -> String {
        lines.map { "\(Self.lrcTimestamp(ms: $0.startMs))\($0.text)" }.joined(separator: "\n")
    }

    /// `[startMs,durationMs](wordStartMs,wordDurationMs,0)word…` per line —
    /// the shape `LyricsParser.parseYRC` reads. Word starts are absolute,
    /// as in YRC. Nil when the file is not word-timed. A wordless line in a
    /// word-timed file is emitted as a single word spanning the line, the
    /// way Folia falls back to spread words for such a line.
    /// Note: a word containing "(" would be cut short by parseYRC's word
    /// regex; nothing is escaped, so the LRC body stays the full text.
    func yrcText() -> String? {
        guard isWordByWord else { return nil }
        var out: [String] = []
        for line in lines {
            let durationMs = max(0, line.endMs - line.startMs)
            var text = "[\(line.startMs),\(durationMs)]"
            if line.words.isEmpty {
                text += "(\(line.startMs),\(durationMs),0)\(line.text)"
            } else {
                for word in line.words {
                    let wordDurationMs = max(0, word.endMs - word.startMs)
                    text += "(\(word.startMs),\(wordDurationMs),0)\(word.text)\(word.endsWithSpace ? " " : "")"
                }
            }
            out.append(text)
        }
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }

    /// `[mm:ss.cc]translation` per translated line, or nil when there is none.
    func translationLRCText() -> String? { lrcText(for: \.translation) }

    /// `[mm:ss.cc]romanization` per romanized line, or nil when there is none.
    func romanizationLRCText() -> String? { lrcText(for: \.romanization) }

    private func lrcText(for keyPath: KeyPath<TTMLLine, String?>) -> String? {
        let parts = lines.compactMap { line -> String? in
            guard let value = line[keyPath: keyPath], !value.isEmpty else { return nil }
            return "\(Self.lrcTimestamp(ms: line.startMs))\(value)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// `[mm:ss.cc]`, centisecond precision.
    private static func lrcTimestamp(ms: Int) -> String {
        let totalCs = max(0, (ms + 5) / 10)
        return String(format: "[%02d:%02d.%02d]", totalCs / 6000, (totalCs % 6000) / 100, totalCs % 100)
    }
}

enum TTMLLyricParser {
    static func parse(_ ttml: String) -> TTMLParseResult {
        let stripped = ttml.hasPrefix("\u{FEFF}") ? String(ttml.dropFirst()) : ttml
        guard let data = stripped.data(using: .utf8),
              let root = TTMLTreeBuilder.parse(data) else {
            return TTMLParseResult(lines: [], isWordByWord: false)
        }
        let sidecar = parseSidecar(root)
        let body = root.name == "body" ? root : root.children(named: "body").first
        var lines: [TTMLLine] = []
        if let body {
            for item in body.content {
                guard case .element(let child) = item else { continue }
                if child.name == "div" {
                    for p in child.descendants(named: "p") {
                        if let line = parseLine(p, sidecar: sidecar) { lines.append(line) }
                    }
                } else if child.name == "p" {
                    if let line = parseLine(child, sidecar: sidecar) { lines.append(line) }
                }
            }
        }
        lines.sort { $0.startMs < $1.startMs }
        let explicitTiming = root.attribute(localName: "timing")
        let isWordByWord: Bool
        if explicitTiming == "Word" {
            isWordByWord = true
        } else if explicitTiming == "Line" {
            isWordByWord = false
        } else {
            // Reference inferTimingMode: any line with more than one timed
            // word (main or background vocal) makes the file word-timed.
            isWordByWord = lines.contains { $0.words.count > 1 || $0.backgroundWordCount > 1 }
        }
        return TTMLParseResult(lines: lines, isWordByWord: isWordByWord)
    }

    // MARK: - Lines

    private static func parseLine(_ p: TTMLNode, sidecar: [String: SidecarEntry]) -> TTMLLine? {
        var draft = parseContent(p)
        if let id = p.attribute(localName: "key"), let entry = sidecar[id] {
            draft.translations += entry.translations
            draft.romanizations += entry.romanizations
        }
        guard !draft.text.isEmpty else { return nil }
        return TTMLLine(
            startMs: draft.startMs,
            endMs: draft.endMs,
            text: draft.text,
            words: draft.words,
            translation: draft.translations.first,
            romanization: draft.romanizations.first,
            backgroundWordCount: draft.backgroundWordCount)
    }

    /// Mirrors the reference parser's `parseCommonContent`: reads one
    /// element's begin/end, walks its children, then finalizes times and
    /// the fallback word.
    private static func parseContent(_ element: TTMLNode) -> LineDraft {
        var draft = LineDraft()
        draft.rawBeginMs = parseTime(element.attribute(localName: "begin"))
        draft.rawEndMs = parseTime(element.attribute(localName: "end"))
        draft.hasTimeAttributes = element.attribute(localName: "begin") != nil
            || element.attribute(localName: "end") != nil
        for item in element.content {
            switch item {
            case .text(let raw):
                processText(raw, into: &draft)
            case .element(let child):
                processElement(child, into: &draft)
            }
        }
        finalize(&draft)
        return draft
    }

    private static func processText(_ raw: String, into draft: inout LineDraft) {
        let isFormatting = raw.contains("\n")
        let normalized = normalize(raw, trim: false)
        if isFormatting && normalized.trimmingCharacters(in: .whitespaces).isEmpty { return }
        draft.fullText += normalized
        if !isFormatting && !normalized.isEmpty
            && normalized.trimmingCharacters(in: .whitespaces).isEmpty,
           !draft.words.isEmpty {
            draft.words[draft.words.count - 1].endsWithSpace = true
        }
    }

    private static func processElement(_ element: TTMLNode, into draft: inout LineDraft) {
        if element.attribute(localName: "ruby") == "container" {
            processRuby(element, into: &draft)
            return
        }
        switch element.attribute(localName: "role") {
        case "x-bg":
            // Background vocal: its words count for the word-by-word
            // determination and its time range widens the line; its text
            // is not part of the main line.
            let bg = parseContent(element)
            draft.backgroundWordCount = bg.words.count
            draft.backgroundStartMs = bg.startMs
            draft.backgroundEndMs = bg.endMs
            draft.hasBackground = true
        case "x-translation":
            let text = parseContent(element).text
            if !text.isEmpty { draft.translations.append(text) }
        case "x-roman", "x-romanization":
            // The reference role is "x-roman"; "x-romanization" is accepted
            // too in case a producer writes the long form.
            let text = parseContent(element).text
            if !text.isEmpty { draft.romanizations.append(text) }
        default:
            processWordElement(element, into: &draft)
        }
    }

    private static func processWordElement(_ element: TTMLNode, into draft: inout LineDraft) {
        let rawText = element.textContent
        let normalized = normalize(rawText, trim: false)
        draft.fullText += normalized
        guard let beginRaw = element.attribute(localName: "begin"),
              let endRaw = element.attribute(localName: "end"),
              !beginRaw.isEmpty, !endRaw.isEmpty else { return }
        let isFormatting = rawText.contains("\n")
        let startsWithSpace = !isFormatting && (normalized.first?.isWhitespace ?? false)
        let endsWithSpace = !isFormatting && (normalized.last?.isWhitespace ?? false)
        let clean = normalized.trimmingCharacters(in: .whitespaces)
        if startsWithSpace, !draft.words.isEmpty {
            draft.words[draft.words.count - 1].endsWithSpace = true
        }
        guard !clean.isEmpty else { return }
        draft.words.append(TTMLWord(
            text: clean,
            startMs: parseTime(beginRaw),
            endMs: parseTime(endRaw),
            endsWithSpace: endsWithSpace))
    }

    private static func processRuby(_ element: TTMLNode, into draft: inout LineDraft) {
        // tts:ruby="container": the sung text is the tts:ruby="base"
        // child; the readings (tts:ruby="text" children) only supply the
        // timing, from the earliest reading start to the latest reading end.
        guard let base = element.firstDescendant(where: { $0.attribute(localName: "ruby") == "base" }) else { return }
        let rawBase = base.textContent
        let normalized = normalize(rawBase, trim: false)
        draft.fullText += normalized
        let clean = normalized.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        var rubyStart: Int?
        var rubyEnd: Int?
        for node in element.allDescendants(where: { $0.attribute(localName: "ruby") == "text" }) {
            guard let beginRaw = node.attribute(localName: "begin"),
                  let endRaw = node.attribute(localName: "end") else { continue }
            let start = parseTime(beginRaw)
            let end = parseTime(endRaw)
            rubyStart = rubyStart.map { min($0, start) } ?? start
            rubyEnd = rubyEnd.map { max($0, end) } ?? end
        }
        let isFormatting = rawBase.contains("\n")
        let startsWithSpace = !isFormatting && (normalized.first?.isWhitespace ?? false)
        let endsWithSpace = !isFormatting && (normalized.last?.isWhitespace ?? false)
        if startsWithSpace, !draft.words.isEmpty {
            draft.words[draft.words.count - 1].endsWithSpace = true
        }
        draft.words.append(TTMLWord(
            text: clean,
            startMs: rubyStart ?? 0,
            endMs: rubyEnd ?? 0,
            endsWithSpace: endsWithSpace))
    }

    private static func finalize(_ draft: inout LineDraft) {
        // finalizeWords: the last word never carries a trailing space.
        if !draft.words.isEmpty {
            draft.words[draft.words.count - 1].endsWithSpace = false
        }
        // calculateTimeRange: the line spans its own begin/end, widened to
        // cover any timed word (or background vocal) that sticks out; a
        // missing bound is taken from the children.
        var startMs = draft.rawBeginMs
        var endMs = draft.rawEndMs
        var timed: [(start: Int, end: Int)] = draft.words.map { (start: $0.startMs, end: $0.endMs) }
        if draft.hasBackground {
            timed.append((start: draft.backgroundStartMs, end: draft.backgroundEndMs))
        }
        if !timed.isEmpty {
            let minStart = timed.map { $0.start }.min() ?? 0
            let maxEnd = timed.map { $0.end }.max() ?? 0
            if startMs == 0 || (minStart > 0 && minStart < startMs) { startMs = minStart }
            if endMs == 0 || maxEnd > endMs { endMs = maxEnd }
        }
        draft.startMs = startMs
        draft.endMs = endMs
        // applyFallbackWord: a line with text but no timed words still gets
        // one word spanning the line, so word-by-word output keeps it.
        let cleanText = normalize(draft.fullText, trim: true)
        draft.text = cleanText
        if draft.words.isEmpty && !cleanText.isEmpty && draft.hasTimeAttributes {
            let start = draft.rawBeginMs > 0 ? draft.rawBeginMs : startMs
            let end = draft.rawEndMs > 0 ? draft.rawEndMs : endMs
            draft.words.append(TTMLWord(text: cleanText, startMs: start, endMs: end, endsWithSpace: false))
        }
    }

    // MARK: - iTunesMetadata sidecar

    private struct SidecarEntry {
        var translations: [String] = []
        var romanizations: [String] = []
    }

    /// Apple Music-style `<iTunesMetadata>` sidecar: translations and
    /// romanizations keyed by line id (`<text for="L1">`), appended after
    /// a line's inline spans so inline wins (Folia takes the first entry).
    private static func parseSidecar(_ root: TTMLNode) -> [String: SidecarEntry] {
        var result: [String: SidecarEntry] = [:]
        guard let head = root.children(named: "head").first else { return result }
        for metadata in head.descendants(named: "itunesmetadata") {
            for container in metadata.descendants(named: "translations") {
                for item in container.children(named: "translation") {
                    for textElement in item.descendants(named: "text") {
                        guard let id = textElement.attribute(localName: "for"), !id.isEmpty else { continue }
                        let text = parseContent(textElement).text
                        guard !text.isEmpty else { continue }
                        result[id, default: SidecarEntry()].translations.append(text)
                    }
                }
            }
            for container in metadata.descendants(named: "transliterations") {
                for item in container.children(named: "transliteration") {
                    for textElement in item.descendants(named: "text") {
                        guard let id = textElement.attribute(localName: "for"), !id.isEmpty else { continue }
                        let text = parseContent(textElement).text
                        guard !text.isEmpty else { continue }
                        result[id, default: SidecarEntry()].romanizations.append(text)
                    }
                }
            }
        }
        return result
    }

    // MARK: - Text and time helpers

    /// Reference `normalizeText`: collapse every whitespace run to one
    /// space, and trim when asked.
    private static func normalize(_ text: String, trim: Bool) -> String {
        var collapsed = ""
        collapsed.reserveCapacity(text.count)
        var lastWasSpace = false
        for character in text {
            if character.isWhitespace {
                if !lastWasSpace { collapsed.append(" ") }
                lastWasSpace = true
            } else {
                collapsed.append(character)
                lastWasSpace = false
            }
        }
        return trim ? collapsed.trimmingCharacters(in: .whitespaces) : collapsed
    }

    /// Reference `TTMLParser.parseTime`: a trailing "s" means an offset in
    /// seconds ("12.5s" -> 12500 ms; "12500ms" does not parse and yields
    /// 0); otherwise a clock time `[HH:]MM:SS[.fff]` or plain seconds.
    /// Returns milliseconds, rounded like the reference.
    private static func parseTime(_ raw: String?) -> Int {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return 0 }
        if raw.hasSuffix("s") {
            guard let seconds = Double(String(raw.dropLast())) else { return 0 }
            return Int((seconds * 1000).rounded())
        }
        let fields = raw.split(separator: ":", omittingEmptySubsequences: false)
        let secondsText: String
        var minutes = 0
        var hours = 0
        switch fields.count {
        case 1:
            secondsText = String(fields[0])
        case 2:
            guard let minutesValue = Int(fields[0]) else { return 0 }
            minutes = minutesValue
            secondsText = String(fields[1])
        case 3:
            guard let hoursValue = Int(fields[0]), let minutesValue = Int(fields[1]) else { return 0 }
            hours = hoursValue
            minutes = minutesValue
            secondsText = String(fields[2])
        default:
            return 0
        }
        guard let seconds = Double(secondsText), hours >= 0, minutes >= 0, seconds >= 0 else { return 0 }
        return Int(((Double(hours) * 3600 + Double(minutes) * 60 + seconds) * 1000).rounded())
    }
}

// MARK: - Line draft (mutable parse state for one element)

private struct LineDraft {
    var rawBeginMs = 0
    var rawEndMs = 0
    var hasTimeAttributes = false
    var startMs = 0
    var endMs = 0
    var fullText = ""
    var text = ""
    var words: [TTMLWord] = []
    var translations: [String] = []
    var romanizations: [String] = []
    var backgroundWordCount = 0
    var backgroundStartMs = 0
    var backgroundEndMs = 0
    var hasBackground = false
}

// MARK: - Minimal XML tree (XMLParser is event-based; the walk above
// mirrors the reference parser's DOM walk, and needs ordered mixed
// content: direct text and child elements interleaved in document order)

private enum TTMLContent {
    case text(String)
    case element(TTMLNode)
}

private final class TTMLNode {
    /// Local element name, lowercased ("ttm:agent" -> "agent").
    let name: String
    /// Attributes as written (qualified names -> values).
    let attributes: [String: String]
    var content: [TTMLContent] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// All descendant text, in document order.
    var textContent: String {
        var out = ""
        for item in content {
            switch item {
            case .text(let text): out += text
            case .element(let node): out += node.textContent
            }
        }
        return out
    }

    /// Attribute by local name, as the reference parser's `getAttr` does:
    /// exact match first, then any qualified name with that local part.
    func attribute(localName: String) -> String? {
        if let value = attributes[localName] { return value }
        for (key, value) in attributes where Self.localName(key) == localName {
            return value
        }
        return nil
    }

    func children(named name: String) -> [TTMLNode] {
        content.compactMap { item in
            guard case .element(let node) = item, node.name == name else { return nil }
            return node
        }
    }

    func descendants(named name: String) -> [TTMLNode] {
        var out: [TTMLNode] = []
        collectDescendants(named: name, into: &out)
        return out
    }

    func firstDescendant(where predicate: (TTMLNode) -> Bool) -> TTMLNode? {
        for item in content {
            guard case .element(let node) = item else { continue }
            if predicate(node) { return node }
            if let found = node.firstDescendant(where: predicate) { return found }
        }
        return nil
    }

    func allDescendants(where predicate: (TTMLNode) -> Bool) -> [TTMLNode] {
        var out: [TTMLNode] = []
        collectDescendants(where: predicate, into: &out)
        return out
    }

    private func collectDescendants(named name: String, into out: inout [TTMLNode]) {
        for item in content {
            guard case .element(let node) = item else { continue }
            if node.name == name { out.append(node) }
            node.collectDescendants(named: name, into: &out)
        }
    }

    private func collectDescendants(where predicate: (TTMLNode) -> Bool, into out: inout [TTMLNode]) {
        for item in content {
            guard case .element(let node) = item else { continue }
            if predicate(node) { out.append(node) }
            node.collectDescendants(where: predicate, into: &out)
        }
    }

    static func localName(_ qualifiedName: String) -> String {
        qualifiedName.split(separator: ":").last.map(String.init)?.lowercased() ?? qualifiedName.lowercased()
    }

    func appendText(_ text: String) {
        guard !text.isEmpty else { return }
        if case .text(let existing) = content.last {
            content[content.count - 1] = .text(existing + text)
        } else {
            content.append(.text(text))
        }
    }
}

private final class TTMLTreeBuilder: NSObject, XMLParserDelegate {
    private var stack: [TTMLNode] = []
    private(set) var root: TTMLNode?
    private(set) var failed = false

    static func parse(_ data: Data) -> TTMLNode? {
        let builder = TTMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse(), !builder.failed, let root = builder.root else { return nil }
        return root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let node = TTMLNode(name: TTMLNode.localName(elementName), attributes: attributeDict)
        if let parent = stack.last {
            parent.content.append(.element(node))
        } else if root == nil {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.appendText(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8) {
            stack.last?.appendText(text)
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        failed = true
    }
}
