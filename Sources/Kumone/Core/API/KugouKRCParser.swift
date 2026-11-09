import Compression
import Foundation

// Kugou KRC lyric decoding and conversion.
//
// KRC (Folia `src/services/onlineMusic/kugou/krcDecrypt.ts` and
// `src/utils/lyrics/parserCore.ts` `parseKRC`):
// - Download payloads are base64; the bytes start with the `krc1` header,
//   then zlib-compressed data XORed with a static 16-byte key.
// - Decrypted text is line based. Metadata lines (`[ti:]`, `[ar:]`,
//   `[al:]`, `[language:]`, …) carry no timing. A timed line is
//   `[<lineStartMs>,<lineDurationMs>]` followed by word tags
//   `<offsetMs,durationMs[,?]>text`, where the offset is relative to the
//   line start. A timed line with no word tags holds plain text instead.
// - `parseKRC` returns `isWordByWord: true` unconditionally: every line
//   ends up with timed words, explicit tags or synthesized ones (Folia's
//   `buildTimedWords` spreads an untagged line across its characters).
//   This port mirrors that: any successfully parsed KRC yields YRC text
//   with `isWordByWord` true. Untagged lines get one synthesized word
//   spanning the line instead of Folia's per-character spread — real KRC
//   payloads tag every sung line (verified on the live endpoints), and the
//   untagged lines are credit/metadata lines where the spread adds nothing.
// - YRC word starts are absolute milliseconds, matching what Golia's
//   `LyricsParser.parseYRC` expects (`[lineStartMs,lineDurMs]` head,
//   `(wordStartMs,wordDurMs,0)word` pieces). One known round-trip loss,
//   shared with NetEase YRC through the same parser: a `(` inside word
//   text is dropped by `parseYRC`'s `\((\d+),(\d+),\d+\)([^(]*)` word
//   regex, so e.g. `(Jay Chou)` becomes `Jay Chou)` in the word-timed
//   line (the LRC text keeps the `(`). Only credit/header lines carry
//   parentheses in practice; the sung lines are unaffected.
enum KugouKRCParser {

    /// Decodes a lyric download payload into plain LRC text plus, when the
    /// source is word-timed, YRC text. Returns nil when nothing renderable
    /// comes out ( undecryptable bytes, or text with no timed lines).
    static func parseDownloadedLyric(
        bytes: Data, contentType: String?
    ) -> (lrc: String, yrc: String?, isWordByWord: Bool)? {
        let text: String
        if contentType == "2" || !isKRCBytes(bytes) {
            // Folia's plain-text branch: `contenttype == '2'` or no `krc1`
            // header means the bytes are already lyric text.
            guard let decoded = String(data: bytes, encoding: .utf8) else { return nil }
            text = decoded
        } else if let decrypted = decryptKRC(bytes) {
            text = decrypted
        } else {
            // Decrypt failed: fall back to the raw bytes as text when they
            // look like timed lyrics, as Folia does.
            guard let decoded = String(data: bytes, encoding: .utf8),
                  looksLikeTimedLyric(decoded)
            else { return nil }
            text = decoded
        }

        if let converted = parseKRC(text) { return converted }
        return parsePlainLRC(text)
    }

    /// Whether lyric text is an explicit pure-music notice, following
    /// Folia's `isPureMusicLyricText` (`src/utils/lyrics/pureMusic.ts`):
    /// at least one line is exactly a pure-music notice, and every other
    /// line is a staff credit, `field: value` metadata, a `title - artist`
    /// header, or punctuation-only filler. Any line that looks like real
    /// lyrics, or empty text, is not pure music.
    static func isPureMusic(_ lyricText: String) -> Bool {
        var hasNotice = false
        for line in cleanLyricLines(lyricText) {
            if isPureMusicNoticeLine(line) {
                hasNotice = true
                continue
            }
            if !isNoticeCompanionLine(line) { return false }
        }
        return hasNotice
    }

    // MARK: - KRC decrypt

    /// The static XOR key from Folia's `krcDecrypt.ts`.
    private static let krcKey: [UInt8] = [
        64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105
    ]

    private static func isKRCBytes(_ bytes: Data) -> Bool {
        bytes.count >= 4
            && bytes[0] == 0x6B && bytes[1] == 0x72
            && bytes[2] == 0x63 && bytes[3] == 0x31 // "krc1"
    }

    /// Skips the 4-byte `krc1` header, XORs with the static key, inflates.
    private static func decryptKRC(_ bytes: Data) -> String? {
        guard bytes.count > 4, isKRCBytes(bytes) else { return nil }
        var decrypted = Data()
        decrypted.reserveCapacity(bytes.count - 4)
        for (index, byte) in bytes.dropFirst(4).enumerated() {
            decrypted.append(byte ^ krcKey[index % krcKey.count])
        }
        guard let inflated = zlibInflate(decrypted) else { return nil }
        return String(data: inflated, encoding: .utf8)
    }

    /// zlib inflate via the Compression framework (iOS 13+ / macOS 10.15+).
    /// Grows the destination until the stream fits; lyrics are small, so
    /// the loop normally succeeds on the first try.
    private static func zlibInflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        var capacity = max(data.count * 4, 4096)
        for _ in 0..<6 {
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { destination in
                data.withUnsafeBytes { source in
                    compression_decode_buffer(
                        destination.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        capacity,
                        source.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        data.count,
                        nil,
                        COMPRESSION_ZLIB)
                }
            }
            if written > 0 { return output.prefix(written) }
            capacity *= 2
        }
        return nil
    }

    // MARK: - KRC -> LRC + YRC

    private struct KRCWord {
        /// Absolute start, in milliseconds.
        let startMs: Int
        let durationMs: Int
        let text: String
    }

    private struct KRCLine {
        let startMs: Int
        let durationMs: Int
        let words: [KRCWord]

        var text: String { words.map(\.text).joined() }
    }

    /// Parses KRC text into LRC lines plus YRC word timing. Returns nil
    /// when no timed line is found (metadata-only text, or not KRC at all).
    private static func parseKRC(
        _ text: String
    ) -> (lrc: String, yrc: String?, isWordByWord: Bool)? {
        let lineTag = #/^\[(\d+),(\d+)\](.*)$/#
        let wordTag = #/<(\d+),(\d+)(?:,\d+)?>([^<]*)/#
        var lines: [KRCLine] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let head = line.firstMatch(of: lineTag) else { continue }
            let lineStartMs = Int(head.output.1) ?? 0
            let lineDurationMs = Int(head.output.2) ?? 0
            let rest = String(head.output.3)

            var words: [KRCWord] = []
            for word in rest.matches(of: wordTag) {
                let offsetMs = Int(word.output.1) ?? 0
                let durationMs = Int(word.output.2) ?? 0
                // KRC word offsets are relative to the line start; YRC
                // wants absolute starts.
                words.append(KRCWord(
                    startMs: lineStartMs + offsetMs,
                    durationMs: durationMs,
                    text: String(word.output.3)))
            }
            if words.isEmpty {
                let plain = rest.trimmingCharacters(in: .whitespaces)
                guard !plain.isEmpty, !plain.hasPrefix("["), !plain.hasPrefix("<") else { continue }
                words.append(KRCWord(
                    startMs: lineStartMs, durationMs: lineDurationMs, text: plain))
            }
            guard !words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            lines.append(KRCLine(startMs: lineStartMs, durationMs: lineDurationMs, words: words))
        }
        guard !lines.isEmpty else { return nil }
        lines.sort { $0.startMs < $1.startMs }

        let lrc = lines.map { "\(lrcTimestamp($0.startMs))\($0.text)" }.joined(separator: "\n")
        let yrc = lines.map { line in
            let words = line.words.map { "(\($0.startMs),\($0.durationMs),0)\($0.text)" }.joined()
            return "[\(line.startMs),\(line.durationMs)]\(words)"
        }.joined(separator: "\n")
        return (lrc: lrc, yrc: yrc, isWordByWord: true)
    }

    /// Plain-LRC fallback for `contenttype == '2'` payloads that carry no
    /// KRC word tags: the text passes through as LRC, with no YRC.
    private static func parsePlainLRC(
        _ text: String
    ) -> (lrc: String, yrc: String?, isWordByWord: Bool)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.range(of: #"\[(\d+):(\d+)([.:]\d+)?\]"#, options: .regularExpression) != nil
        else { return nil }
        return (lrc: trimmed, yrc: nil, isWordByWord: false)
    }

    private static func lrcTimestamp(_ ms: Int) -> String {
        String(format: "[%02d:%02d.%02d]", ms / 60_000, (ms / 1_000) % 60, (ms % 1_000) / 10)
    }

    private static func looksLikeTimedLyric(_ text: String) -> Bool {
        text.range(of: #"\[(\d{1,2}):(\d{2})([.:]\d{1,3})?\]"#, options: .regularExpression) != nil
            || text.range(of: #"<(\d{1,2}):(\d{2})([.:]\d{1,3})?>"#, options: .regularExpression) != nil
            || text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT")
    }

    // MARK: - Pure-music detection

    private static let pureMusicNoticePattern =
        #"^(?:[此本](?:首)?(?:歌曲|曲目|作品|乐曲|曲)?[为是]?)?(?:(?:没有|无)(?:填词|歌词)的)?[纯純]音[乐樂]敬?[请請][您你]?欣[赏賞]$"#
    private static let noticeRegex = try? NSRegularExpression(pattern: pureMusicNoticePattern)

    /// Strips time tags from each line and drops empty and JSON lines.
    private static func cleanLyricLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .components(separatedBy: .newlines)
            .map { line in
                line.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"<[\d:.,\s]*>"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"\(\d+,\d+,\d+\)"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty && !($0.hasPrefix("{") && $0.hasSuffix("}")) }
    }

    private static func isPureMusicNoticeLine(_ line: String) -> Bool {
        // The notice match ignores whitespace and punctuation, so
        // "纯音乐，请欣赏" and "此歌曲为没有填词的纯音乐，请您欣赏" both match.
        let ignored = CharacterSet.punctuationCharacters
            .union(.symbols).union(.whitespacesAndNewlines)
        var stripped = ""
        stripped.unicodeScalars.reserveCapacity(line.unicodeScalars.count)
        for scalar in line.unicodeScalars where !ignored.contains(scalar) {
            stripped.unicodeScalars.append(scalar)
        }
        guard !stripped.isEmpty, let regex = noticeRegex else { return false }
        let range = NSRange(location: 0, length: stripped.utf16.count)
        return regex.firstMatch(in: stripped, range: range) != nil
    }

    /// Non-lyric lines allowed next to a pure-music notice: staff credits,
    /// `field: value` metadata, a `title - artist` header, or
    /// punctuation-only filler. (Folia checks the same shapes via its
    /// staff-credit helpers; this is a conservative local equivalent.)
    private static func isNoticeCompanionLine(_ line: String) -> Bool {
        if line.range(of: #"^(作词|作曲|编曲|演唱|制作|混音|母带|出品|发行|监制|和声|吉他|贝斯|鼓|键盘|弦乐|录音|词|曲)\s*[:：]"#, options: .regularExpression) != nil {
            return true
        }
        if let colon = line.firstIndex(where: { $0 == ":" || $0 == "：" }) {
            let before = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let after = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !before.isEmpty, !after.isEmpty { return true }
        }
        if line.contains(" - ") { return true }
        return line.rangeOfCharacter(from: .alphanumerics) == nil
    }
}
