import Foundation
#if canImport(zlib)
import zlib
#endif

/// QQ Music lyrics provider: the Folia `qqLyricProvider.ts` +
/// `qrcDecrypt.ts` flow, ported to Swift.
///
/// Anonymous: no login, no account cookies — the only cookie sent is
/// `tmeLoginType=-1`, and both calls go to the public
/// `u.y.qq.com/cgi-bin/musicu.fcg` endpoint Folia uses.
struct QQLyricProvider: LyricProvider {
    var source: LyricSource { .qq }

    /// Searches QQ for the track, scores the candidates with
    /// `LyricMatch.evaluate`, and fetches + decrypts the best accepted
    /// song's lyrics. Nil when nothing matches or the song has no lyrics.
    func fetch(for track: Track) async -> LyricCandidate? {
        guard !Task.isCancelled else { return nil }
        let keyword = Self.searchKeyword(for: track)
        guard !keyword.isEmpty else { return nil }
        guard let candidates = await Self.searchSongs(keyword: keyword) else { return nil }
        if Task.isCancelled { return nil }

        var best: QQSong?
        var bestScore = -Double.infinity
        for candidate in candidates {
            if Task.isCancelled { return nil }
            let (score, accepted) = LyricMatch.evaluate(
                title: candidate.title,
                artist: candidate.artists.joined(separator: ", "),
                album: candidate.album,
                duration: candidate.duration,
                track: track)
            if accepted, score > bestScore {
                best = candidate
                bestScore = score
            }
        }
        guard let song = best else { return nil }
        if Task.isCancelled { return nil }
        return await Self.fetchLyrics(for: song)
    }

    // MARK: - Search

    /// One QQ search hit: what `LyricMatch.evaluate` scores and
    /// `GetPlayLyricInfo` needs.
    private struct QQSong {
        let id: Int
        let mid: String
        let title: String
        let artists: [String]
        let album: String?
        /// Length in seconds (`interval`).
        let duration: TimeInterval
    }

    /// Folia's lyric search query is `title - artist`; the query is capped
    /// at 60 characters.
    private static func searchKeyword(for track: Track) -> String {
        let name = track.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return "" }
        let artist = track.artists.first?.name.trimmingCharacters(in: .whitespaces) ?? ""
        let keyword = artist.isEmpty ? name : "\(name) - \(artist)"
        return String(keyword.prefix(60))
    }

    private static func searchSongs(keyword: String) async -> [QQSong]? {
        let searchID = String(
            Int64.random(in: 0..<100_000_000_000_000)
            + Int64(Date().timeIntervalSince1970 * 1000) % 86_400_000)
        let param: [String: Any] = [
            "search_id": searchID,
            "remoteplace": "search.android.keyboard",
            "query": keyword,
            // 7 = songs. 0 used to mean songs too, but QQ now answers 2001
            // with no items to every 0 search (Folia #695): do not change.
            "search_type": 7,
            "num_per_page": 20,
            "page_num": 1,
            "highlight": 0,
            "nqc_flag": 0,
            "page_id": 1,
            "grp": 1,
        ]
        guard let data = await Self.requestQQ(
            method: "DoSearchForQQMusicLite",
            module: "music.search.SearchCgiService",
            param: param),
            let body = data["body"] as? [String: Any],
            let items = body["item_song"] as? [[String: Any]]
        else { return nil }
        return items.compactMap(Self.song(from:))
    }

    private static func song(from info: [String: Any]) -> QQSong? {
        guard let id = info["id"] as? Int,
              let mid = info["mid"] as? String, !mid.isEmpty,
              let title = info["title"] as? String
        else { return nil }
        let singers = info["singer"] as? [[String: Any]] ?? []
        let artists = singers.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
        let album = (info["album"] as? [String: Any])?["name"] as? String
        let interval = (info["interval"] as? NSNumber)?.doubleValue ?? 0
        return QQSong(id: id, mid: mid, title: title, artists: artists,
                      album: album, duration: interval)
    }

    // MARK: - Lyrics

    private static func fetchLyrics(for song: QQSong) async -> LyricCandidate? {
        let artistsStr = song.artists.joined(separator: ", ")
        let param: [String: Any] = [
            "albumName": Self.base64(song.album ?? ""),
            "crypt": 1,
            "ct": 19,
            "cv": 2111,
            "interval": Int(song.duration),
            "lrc_t": 0,
            "qrc": 1,
            "qrc_t": 0,
            "roma": 1,
            "roma_t": 0,
            "singerName": Self.base64(artistsStr),
            "songID": song.id,
            "songName": Self.base64(song.title),
            "trans": 1,
            "trans_t": 0,
            "type": 0,
        ]
        guard let data = await Self.requestQQ(
            method: "GetPlayLyricInfo",
            module: "music.musichallSong.PlayLyricInfo",
            param: param),
            let lyricHex = data["lyric"] as? String,
            !lyricHex.isEmpty,
            let decrypted = Self.qrcDecrypt(hex: lyricHex)
        else { return nil }
        if Task.isCancelled { return nil }

        let text = Self.stripBOM(decrypted)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let translation = (data["trans"] as? String)
            .flatMap(Self.qrcDecrypt(hex:)).map(Self.stripBOM)
        let romanization = (data["roma"] as? String)
            .flatMap(Self.qrcDecrypt(hex:)).map(Self.stripBOM)

        let isWordByWord = Self.isQRC(text)
        let lrcText: String
        let yrcText: String?
        if isWordByWord {
            let lines = Self.parseQRC(text)
            guard !lines.isEmpty else { return nil }
            lrcText = lines.map { "[\(Self.lrcTimestamp(ms: $0.startMs))]\($0.text)" }
                .joined(separator: "\n")
            yrcText = lines.map { line in
                "[\(line.startMs),\(line.durationMs)]"
                    + line.words.map { "(\($0.startMs),\($0.durationMs),0)\($0.text)" }.joined()
            }.joined(separator: "\n")
        } else {
            // Not word-timed: Folia falls back to timed-format detection;
            // only plain LRC carries timestamps Golia can use.
            guard Self.looksLikeLRC(text) else { return nil }
            lrcText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            yrcText = nil
        }

        let response = LyricResponse(
            lrc: LyricResponse.LyricBody(lyric: lrcText),
            tlyric: translation.flatMap(Self.lrc(from:)).map { LyricResponse.LyricBody(lyric: $0) },
            romalrc: romanization.flatMap(Self.lrc(from:)).map { LyricResponse.LyricBody(lyric: $0) },
            yrc: yrcText.map { LyricResponse.LyricBody(lyric: $0) },
            ytlrc: nil,
            yromalrc: nil,
            lyricUser: nil,
            transUser: nil,
            nolyric: false,
            uncollected: false)
        // Folia hardcodes `isPureMusic: false` for QQ: `GetPlayLyricInfo`
        // carries no pure-music flag, and Golia's `LyricsParser` already
        // treats the "纯音乐，请欣赏" marker as instrumental at parse time.
        return LyricCandidate(source: .qq, response: response,
                              isWordByWord: isWordByWord, isPureMusic: false)
    }

    // MARK: - QRC parsing

    /// One decrypted QRC line: `[startMs,durationMs]` plus its timed words.
    private struct QRCLine {
        let startMs: Int
        let durationMs: Int
        let words: [QRCWord]
        var text: String { words.map(\.text).joined() }
    }

    private struct QRCWord {
        let startMs: Int
        let durationMs: Int
        let text: String
    }

    /// Folia's `detectIsQrc`: word tags plus a `[n,n]` line head.
    private static func isQRC(_ content: String) -> Bool {
        content.contains("(") && content.contains(")")
            && content.range(of: #"\[\d+,\d+\]"#, options: .regularExpression) != nil
    }

    private static func looksLikeLRC(_ content: String) -> Bool {
        content.range(of: #"\[\d+:\d+"#, options: .regularExpression) != nil
    }

    /// Parses decrypted QRC text the way Folia's `parseQRC` does: lines
    /// that don't start with `[startMs,durationMs]` are skipped, as are
    /// lines with no word tags. Word text follows its tag, matching
    /// `LyricsParser.parseYRC`'s `([^(]*)` capture, so the rebuilt YRC
    /// lines below parse back identically.
    private static func parseQRC(_ text: String) -> [QRCLine] {
        let lineTag = #/^\[(\d+),(\d+)\](.*)/#
        let wordTag = #/\((\d+),(\d+),\d+\)([^(]*)/#
        var lines: [QRCLine] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let head = line.firstMatch(of: lineTag) else { continue }
            let startMs = Int(head.output.1) ?? 0
            let durationMs = Int(head.output.2) ?? 0
            let rest = String(head.output.3)
            var words: [QRCWord] = []
            for match in rest.matches(of: wordTag) {
                let piece = String(match.output.3)
                guard !piece.isEmpty else { continue }
                words.append(QRCWord(
                    startMs: Int(match.output.1) ?? 0,
                    durationMs: Int(match.output.2) ?? 0,
                    text: piece))
            }
            guard !words.isEmpty else { continue }
            lines.append(QRCLine(startMs: startMs, durationMs: durationMs, words: words))
        }
        return lines
    }

    /// Converts a decrypted translation/romanization body to plain LRC
    /// lines: QRC bodies are parsed the same way as the main lyric, LRC
    /// bodies pass through. Golia merges translations with `parseLRC`, so
    /// they go in `tlyric`/`romalrc`, never `ytlrc`/`yromalrc`.
    private static func lrc(from text: String) -> String? {
        let clean = Self.stripBOM(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        if Self.isQRC(clean) {
            let lines = Self.parseQRC(clean)
            guard !lines.isEmpty else { return nil }
            return lines.map { "[\(Self.lrcTimestamp(ms: $0.startMs))]\($0.text)" }
                .joined(separator: "\n")
        }
        guard Self.looksLikeLRC(clean) else { return nil }
        return clean
    }

    /// `[mm:ss.cc]` for an LRC line, from a millisecond timestamp.
    private static func lrcTimestamp(ms: Int) -> String {
        String(format: "%02d:%02d.%02d", ms / 60000, (ms % 60000) / 1000, (ms % 1000) / 10)
    }

    private static func stripBOM(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    /// Folia's `toBase64`: standard base64 of the UTF-8 bytes.
    private static func base64(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
    }

    // MARK: - musicu.fcg transport

    private static let endpoint = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!
    private static let userAgent = "okhttp/3.14.9"

    /// Ephemeral session: anonymous requests, nothing persisted. The
    /// orchestrator enforces the 5 s per-source budget; 10 s here is the
    /// per-request ceiling.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    /// POSTs one `musicu.fcg` call the way Folia's `requestQQ` does and
    /// returns the `request.data` object. Nil on any transport or
    /// business-level failure (Folia's lyric search swallows these too).
    private static func requestQQ(method: String, module: String, param: [String: Any]) async -> [String: Any]? {
        let payload: [String: Any] = [
            "comm": [
                "ct": 11,
                "cv": "1003006",
                "v": "1003006",
                "os_ver": "15",
                "phonetype": "24122RKC7C",
                "rom": "Redmi/miro/miro:15/AE3A.240806.005/OS2.0.102.0.VOMCNXM:user/release-keys",
                "tmeAppID": "qqmusiclight",
                "nettype": "NETWORK_WIFI",
                "udid": "0",
                "uid": "0",
            ],
            "request": [
                "method": method,
                "module": module,
                "param": param,
            ],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("tmeLoginType=-1;", forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["code"] as? Int) == 0,
                  let requestObject = json["request"] as? [String: Any],
                  (requestObject["code"] as? Int) == 0,
                  let result = requestObject["data"] as? [String: Any]
            else { return nil }
            return result
        } catch {
            return nil
        }
    }

    // MARK: - QRC decryption (`qrcDecrypt.ts`)

    /// Decrypts one hex-encoded QRC payload with Folia's hand-rolled DES
    /// (see `qrcSBox` — not standard 3DES), then zlib/raw-deflate
    /// decompression. Internal for the `QQLyricDecryptTests` fixture.
    /// Nil on any failure.
    static func qrcDecrypt(hex: String) -> String? {
        guard let cipher = Self.data(fromHex: hex), !cipher.isEmpty,
              let decrypted = Self.tripleDESDecrypt(cipher),
              let inflated = Self.inflateRawDeflate(decrypted)
        else { return nil }
        return String(data: inflated, encoding: .utf8)
    }

    private static func data(fromHex hex: String) -> Data? {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count.isMultiple(of: 2) else { return nil }
        var bytes = Data(capacity: clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    // MARK: - QRC decryption (Folia `qrcDecrypt.ts`, ported)
    //
    // Folia hand-rolls DES in TypeScript. The previous Swift version
    // assumed that was standard 3DES and used CommonCrypto's `CCCrypt`
    // — it is not: live-probed 2026-11-09, Folia's decrypt of a real
    // `GetPlayLyricInfo` payload yields valid QRC text while a standard
    // 3DES-ECB decrypt of the same bytes does not inflate at all, so
    // every QQ lyric fetch failed at this step ("暂无歌词" for all QQ
    // songs). The DES below is a faithful port of Folia's bit-level
    // implementation (same S-boxes, permutations, key schedule and EDE
    // order); do not "simplify" it back to `CCCrypt`.

    private static let qrcSBox: [[Int]] = [
        [
            14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7,
            0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
            4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0,
            15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13,
        ],
        [
            15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10,
            3, 13, 4, 7, 15, 2, 8, 15, 12, 0, 1, 10, 6, 9, 11, 5,
            0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15,
            13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9,
        ],
        [
            10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8,
            13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
            13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7,
            1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12,
        ],
        [
            7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15,
            13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
            10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4,
            3, 15, 0, 6, 10, 10, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14,
        ],
        [
            2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9,
            14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
            4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14,
            11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3,
        ],
        [
            12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11,
            10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
            9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6,
            4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13,
        ],
        [
            4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1,
            13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
            1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2,
            6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12,
        ],
        [
            13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7,
            1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
            7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8,
            2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11,
        ],
    ]

    private static let qrcKeyPermC: [Int] = [
        56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1,
        58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35,
    ]

    private static let qrcKeyPermD: [Int] = [
        62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5,
        60, 52, 44, 36, 28, 20, 12, 4, 27, 19, 11, 3,
    ]

    private static let qrcKeyCompression: [Int] = [
        13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3,
        25, 7, 15, 6, 26, 19, 12, 1, 40, 51, 30, 36, 46, 54, 29, 39,
        50, 44, 32, 47, 43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31,
    ]

    private static let qrcKeyRoundShift: [Int] = [
        1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1,
    ]

    /// Extracts one bit from a byte array, DES bit numbering.
    private static func qrcBit(_ data: [UInt8], _ bit: Int, _ shift: Int) -> Int {
        let index = (bit / 32) * 4 + 3 - ((bit % 32) / 8)
        let bitShift = 7 - (bit % 8)
        return ((Int(data[index]) >> bitShift) & 1) << shift
    }

    private static func qrcBitInt(_ value: UInt32, _ bit: Int, _ shift: Int) -> Int {
        return Int((value >> (31 - bit)) & 1) << shift
    }

    private static func qrcBitIntL(_ value: UInt32, _ bit: Int, _ shift: Int) -> UInt32 {
        return ((value &<< bit) & 0x80000000) >> shift
    }

    private static func qrcSBoxBit(_ value: Int) -> Int {
        return (value & 32) | ((value & 31) >> 1) | ((value & 1) << 4)
    }

    private static func qrcInitialPermutation(_ input: [UInt8]) -> (UInt32, UInt32) {
        let s0 = UInt32(
            qrcBit(input, 57, 31) | qrcBit(input, 49, 30) | qrcBit(input, 41, 29) | qrcBit(input, 33, 28) |
            qrcBit(input, 25, 27) | qrcBit(input, 17, 26) | qrcBit(input, 9, 25) | qrcBit(input, 1, 24) |
            qrcBit(input, 59, 23) | qrcBit(input, 51, 22) | qrcBit(input, 43, 21) | qrcBit(input, 35, 20) |
            qrcBit(input, 27, 19) | qrcBit(input, 19, 18) | qrcBit(input, 11, 17) | qrcBit(input, 3, 16) |
            qrcBit(input, 61, 15) | qrcBit(input, 53, 14) | qrcBit(input, 45, 13) | qrcBit(input, 37, 12) |
            qrcBit(input, 29, 11) | qrcBit(input, 21, 10) | qrcBit(input, 13, 9) | qrcBit(input, 5, 8) |
            qrcBit(input, 63, 7) | qrcBit(input, 55, 6) | qrcBit(input, 47, 5) | qrcBit(input, 39, 4) |
            qrcBit(input, 31, 3) | qrcBit(input, 23, 2) | qrcBit(input, 15, 1) | qrcBit(input, 7, 0))
        let s1 = UInt32(
            qrcBit(input, 56, 31) | qrcBit(input, 48, 30) | qrcBit(input, 40, 29) | qrcBit(input, 32, 28) |
            qrcBit(input, 24, 27) | qrcBit(input, 16, 26) | qrcBit(input, 8, 25) | qrcBit(input, 0, 24) |
            qrcBit(input, 58, 23) | qrcBit(input, 50, 22) | qrcBit(input, 42, 21) | qrcBit(input, 34, 20) |
            qrcBit(input, 26, 19) | qrcBit(input, 18, 18) | qrcBit(input, 10, 17) | qrcBit(input, 2, 16) |
            qrcBit(input, 60, 15) | qrcBit(input, 52, 14) | qrcBit(input, 44, 13) | qrcBit(input, 36, 12) |
            qrcBit(input, 28, 11) | qrcBit(input, 20, 10) | qrcBit(input, 12, 9) | qrcBit(input, 4, 8) |
            qrcBit(input, 62, 7) | qrcBit(input, 54, 6) | qrcBit(input, 46, 5) | qrcBit(input, 38, 4) |
            qrcBit(input, 30, 3) | qrcBit(input, 22, 2) | qrcBit(input, 14, 1) | qrcBit(input, 6, 0))
        return (s0, s1)
    }

    private static func qrcInversePermutation(_ s0: UInt32, _ s1: UInt32) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 8)
        data[3] = UInt8(qrcBitInt(s1, 7, 7) | qrcBitInt(s0, 7, 6) | qrcBitInt(s1, 15, 5) |
                        qrcBitInt(s0, 15, 4) | qrcBitInt(s1, 23, 3) | qrcBitInt(s0, 23, 2) |
                        qrcBitInt(s1, 31, 1) | qrcBitInt(s0, 31, 0))
        data[2] = UInt8(qrcBitInt(s1, 6, 7) | qrcBitInt(s0, 6, 6) | qrcBitInt(s1, 14, 5) |
                        qrcBitInt(s0, 14, 4) | qrcBitInt(s1, 22, 3) | qrcBitInt(s0, 22, 2) |
                        qrcBitInt(s1, 30, 1) | qrcBitInt(s0, 30, 0))
        data[1] = UInt8(qrcBitInt(s1, 5, 7) | qrcBitInt(s0, 5, 6) | qrcBitInt(s1, 13, 5) |
                        qrcBitInt(s0, 13, 4) | qrcBitInt(s1, 21, 3) | qrcBitInt(s0, 21, 2) |
                        qrcBitInt(s1, 29, 1) | qrcBitInt(s0, 29, 0))
        data[0] = UInt8(qrcBitInt(s1, 4, 7) | qrcBitInt(s0, 4, 6) | qrcBitInt(s1, 12, 5) |
                        qrcBitInt(s0, 12, 4) | qrcBitInt(s1, 20, 3) | qrcBitInt(s0, 20, 2) |
                        qrcBitInt(s1, 28, 1) | qrcBitInt(s0, 28, 0))
        data[7] = UInt8(qrcBitInt(s1, 3, 7) | qrcBitInt(s0, 3, 6) | qrcBitInt(s1, 11, 5) |
                        qrcBitInt(s0, 11, 4) | qrcBitInt(s1, 19, 3) | qrcBitInt(s0, 19, 2) |
                        qrcBitInt(s1, 27, 1) | qrcBitInt(s0, 27, 0))
        data[6] = UInt8(qrcBitInt(s1, 2, 7) | qrcBitInt(s0, 2, 6) | qrcBitInt(s1, 10, 5) |
                        qrcBitInt(s0, 10, 4) | qrcBitInt(s1, 18, 3) | qrcBitInt(s0, 18, 2) |
                        qrcBitInt(s1, 26, 1) | qrcBitInt(s0, 26, 0))
        data[5] = UInt8(qrcBitInt(s1, 1, 7) | qrcBitInt(s0, 1, 6) | qrcBitInt(s1, 9, 5) |
                        qrcBitInt(s0, 9, 4) | qrcBitInt(s1, 17, 3) | qrcBitInt(s0, 17, 2) |
                        qrcBitInt(s1, 25, 1) | qrcBitInt(s0, 25, 0))
        data[4] = UInt8(qrcBitInt(s1, 0, 7) | qrcBitInt(s0, 0, 6) | qrcBitInt(s1, 8, 5) |
                        qrcBitInt(s0, 8, 4) | qrcBitInt(s1, 16, 3) | qrcBitInt(s0, 16, 2) |
                        qrcBitInt(s1, 24, 1) | qrcBitInt(s0, 24, 0))
        return data
    }

    /// DES round function f.
    private static func qrcF(_ state: UInt32, _ key: [UInt8]) -> UInt32 {
        let t1 = qrcBitIntL(state, 31, 0) |
            ((state & 0xf0000000) >> 1) |
            qrcBitIntL(state, 4, 5) |
            qrcBitIntL(state, 3, 6) |
            ((state & 0x0f000000) >> 3) |
            qrcBitIntL(state, 8, 11) |
            qrcBitIntL(state, 7, 12) |
            ((state & 0x00f00000) >> 5) |
            qrcBitIntL(state, 12, 17) |
            qrcBitIntL(state, 11, 18) |
            ((state & 0x000f0000) >> 7) |
            qrcBitIntL(state, 16, 23)
        let t2 = qrcBitIntL(state, 15, 0) |
            ((state & 0x0000f000) << 15) |
            qrcBitIntL(state, 20, 5) |
            qrcBitIntL(state, 19, 6) |
            ((state & 0x00000f00) << 13) |
            qrcBitIntL(state, 24, 11) |
            qrcBitIntL(state, 23, 12) |
            ((state & 0x000000f0) << 11) |
            qrcBitIntL(state, 28, 17) |
            qrcBitIntL(state, 27, 18) |
            ((state & 0x0000000f) << 9) |
            qrcBitIntL(state, 0, 23)
        let lrgstate = [
            Int((t1 >> 24) & 0xff),
            Int((t1 >> 16) & 0xff),
            Int((t1 >> 8) & 0xff),
            Int((t2 >> 24) & 0xff),
            Int((t2 >> 16) & 0xff),
            Int((t2 >> 8) & 0xff),
        ]
        let xorState = lrgstate.enumerated().map { $0.element ^ Int(key[$0.offset]) }
        let outputState = UInt32(
            (qrcSBox[0][qrcSBoxBit(xorState[0] >> 2)] << 28) |
            (qrcSBox[1][qrcSBoxBit(((xorState[0] & 0x03) << 4) | (xorState[1] >> 4))] << 24) |
            (qrcSBox[2][qrcSBoxBit(((xorState[1] & 0x0f) << 2) | (xorState[2] >> 6))] << 20) |
            (qrcSBox[3][qrcSBoxBit(xorState[2] & 0x3f)] << 16) |
            (qrcSBox[4][qrcSBoxBit(xorState[3] >> 2)] << 12) |
            (qrcSBox[5][qrcSBoxBit(((xorState[3] & 0x03) << 4) | (xorState[4] >> 4))] << 8) |
            (qrcSBox[6][qrcSBoxBit(((xorState[4] & 0x0f) << 2) | (xorState[5] >> 6))] << 4) |
            qrcSBox[7][qrcSBoxBit(xorState[5] & 0x3f)])
        return qrcBitIntL(outputState, 15, 0) | qrcBitIntL(outputState, 6, 1) | qrcBitIntL(outputState, 19, 2) |
            qrcBitIntL(outputState, 20, 3) | qrcBitIntL(outputState, 28, 4) | qrcBitIntL(outputState, 11, 5) |
            qrcBitIntL(outputState, 27, 6) | qrcBitIntL(outputState, 16, 7) | qrcBitIntL(outputState, 0, 8) |
            qrcBitIntL(outputState, 14, 9) | qrcBitIntL(outputState, 22, 10) | qrcBitIntL(outputState, 25, 11) |
            qrcBitIntL(outputState, 4, 12) | qrcBitIntL(outputState, 17, 13) | qrcBitIntL(outputState, 30, 14) |
            qrcBitIntL(outputState, 9, 15) | qrcBitIntL(outputState, 1, 16) | qrcBitIntL(outputState, 7, 17) |
            qrcBitIntL(outputState, 23, 18) | qrcBitIntL(outputState, 13, 19) | qrcBitIntL(outputState, 31, 20) |
            qrcBitIntL(outputState, 26, 21) | qrcBitIntL(outputState, 2, 22) | qrcBitIntL(outputState, 8, 23) |
            qrcBitIntL(outputState, 18, 24) | qrcBitIntL(outputState, 12, 25) | qrcBitIntL(outputState, 29, 26) |
            qrcBitIntL(outputState, 5, 27) | qrcBitIntL(outputState, 21, 28) | qrcBitIntL(outputState, 10, 29) |
            qrcBitIntL(outputState, 3, 30) | qrcBitIntL(outputState, 24, 31)
    }

    /// Standard single block DES crypt (enc/dec depending on key scheduling).
    private static func qrcCrypt(_ input: [UInt8], _ key: [[UInt8]]) -> [UInt8] {
        var (s0, s1) = qrcInitialPermutation(input)
        for idx in 0..<15 {
            let previousS1 = s1
            s1 = qrcF(s1, key[idx]) ^ s0
            s0 = previousS1
        }
        s0 = qrcF(s1, key[15]) ^ s0
        return qrcInversePermutation(s0, s1)
    }

    /// Standard DES key scheduling.
    private static func qrcKeySchedule(_ key: [UInt8], _ mode: Int) -> [[UInt8]] {
        var schedule = [[UInt8]](repeating: [UInt8](repeating: 0, count: 6), count: 16)
        var c: UInt32 = 0
        for i in 0..<28 {
            c |= UInt32(qrcBit(key, qrcKeyPermC[i], 31 - i))
        }
        var d: UInt32 = 0
        for i in 0..<28 {
            d |= UInt32(qrcBit(key, qrcKeyPermD[i], 31 - i))
        }
        for i in 0..<16 {
            let shift = qrcKeyRoundShift[i]
            c = ((c &<< shift) | (c >> (28 - shift))) & 0xfffffff0
            d = ((d &<< shift) | (d >> (28 - shift))) & 0xfffffff0
            let togen = mode == 0 ? 15 - i : i
            for j in 0..<24 {
                schedule[togen][j / 8] |= UInt8(qrcBitInt(c, qrcKeyCompression[j], 7 - (j % 8)))
            }
            for j in 24..<48 {
                schedule[togen][j / 8] |= UInt8(qrcBitInt(d, qrcKeyCompression[j] - 27, 7 - (j % 8)))
            }
        }
        return schedule
    }

    /// 3DES key setup. Builds 3 schedules from the 24-byte key.
    private static func qrcTripleDESKeySetup(_ key: [UInt8], _ mode: Int) -> [[[UInt8]]] {
        let key0 = Array(key[0..<8])
        let key8 = Array(key[8..<16])
        let key16 = Array(key[16..<24])
        if mode == 1 { // ENCRYPT
            return [qrcKeySchedule(key0, 1), qrcKeySchedule(key8, 0), qrcKeySchedule(key16, 1)]
        }
        // DECRYPT
        return [qrcKeySchedule(key16, 0), qrcKeySchedule(key8, 1), qrcKeySchedule(key0, 0)]
    }

    /// Encrypts/decrypts 8-byte blocks using 3DES.
    private static func qrcTripleDESCrypt(_ data: [UInt8], _ keySchedule: [[[UInt8]]]) -> [UInt8] {
        var temp = data
        for i in 0..<3 {
            temp = qrcCrypt(temp, keySchedule[i])
        }
        return temp
    }

    /// Decrypts one hex-encoded QRC payload: Folia's hand-rolled DES
    /// (see the note above `qrcSBox`) with the fixed 24-byte QRC key,
    /// then zlib/raw-deflate decompression. A trailing partial block is
    /// zero-padded before decrypting and the padding dropped
    /// afterwards, mirroring the TS loop. Nil on any failure.
    private static func tripleDESDecrypt(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        let key = [UInt8]("!@#)(*$%123ZXC!@!@#)(NHL".utf8)
        let schedule = qrcTripleDESKeySetup(key, 0) // 0 = DECRYPT
        var decrypted = Data()
        decrypted.reserveCapacity(data.count)
        var offset = 0
        while offset < data.count {
            let end = min(offset + 8, data.count)
            var block = [UInt8](data[offset..<end])
            let length = block.count
            if length < 8 {
                block += [UInt8](repeating: 0, count: 8 - length)
            }
            let out = qrcTripleDESCrypt(block, schedule)
            decrypted.append(contentsOf: out.prefix(length))
            offset = end
        }
        return decrypted
    }

    /// Decompression for QRC payloads. QQ's decrypted plaintext is a
    /// zlib-wrapped stream (RFC 1950 — it starts with the 0x78 0x9c
    /// header), NOT raw deflate (RFC 1951), even though Folia calls
    /// `DecompressionStream('deflate')`: browsers accept the wrapper
    /// there, but `inflateInit2(..., -15)` does not, so the previous
    /// raw-only version returned nil for every QQ lyric. Try the zlib
    /// wrapper first, then raw deflate as a fallback. `zlib` is an SDK
    /// module on Apple platforms, and the `canImport` guard keeps the
    /// file compiling anywhere it is absent — decryption then fails
    /// closed and the provider yields no lyrics.
    #if canImport(zlib)
    private static func inflateRawDeflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        if let inflated = Self.inflateWithWindowBits(data, windowBits: MAX_WBITS) { return inflated }
        return Self.inflateWithWindowBits(data, windowBits: -MAX_WBITS)
    }

    /// Named to avoid colliding with zlib's C `inflate` below.
    private static func inflateWithWindowBits(_ data: Data, windowBits: CInt) -> Data? {
        return data.withUnsafeBytes { inputRaw -> Data? in
            guard let inputBase = inputRaw.baseAddress?.assumingMemoryBound(to: Bytef.self) else { return nil }
            var stream = z_stream()
            let initStatus = inflateInit2_(&stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard initStatus == Z_OK else { return nil }
            defer { _ = inflateEnd(&stream) }
            stream.next_in = UnsafeMutablePointer(mutating: inputBase)
            stream.avail_in = uInt(data.count)

            var output = Data()
            let chunkSize = 16384
            let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
            defer { chunk.deallocate() }
            var status: CInt = Z_OK
            while status != Z_STREAM_END {
                stream.next_out = chunk
                stream.avail_out = uInt(chunkSize)
                status = inflate(&stream, Z_NO_FLUSH)
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 { output.append(chunk, count: produced) }
                switch status {
                case Z_OK, Z_STREAM_END:
                    break
                case Z_BUF_ERROR:
                    // No progress with no output: truncated or corrupt input.
                    if produced == 0 { return nil }
                default:
                    return nil
                }
                // `Z_OK` with no output and no input left means the stream
                // is stuck on a truncated payload.
                if status == Z_OK, produced == 0, stream.avail_in == 0 { return nil }
            }
            return output
        }
    }
    #else
    private static func inflateRawDeflate(_ data: Data) -> Data? { nil }
    #endif
}
