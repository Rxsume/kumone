import Foundation
import CommonCrypto
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

    /// Decrypts one hex-encoded QRC payload: 3DES-ECB with the fixed key,
    /// then raw-deflate decompression. Nil on any failure.
    private static func qrcDecrypt(hex: String) -> String? {
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

    /// 3DES-EDE decryption in ECB mode with the fixed 24-byte QRC key.
    /// `qrcDecrypt.ts` hand-rolls DES, but its parameters are exactly
    /// standard 3DES — EDE, ECB, no IV — so CommonCrypto's `CCCrypt`
    /// (`kCCAlgorithm3DES`) does the same work: the TS key schedule drops
    /// the parity bits just like a standard DES schedule, and its DECRYPT
    /// setup (decrypt K3, encrypt K2, decrypt K1) is EDE decrypt. A
    /// trailing partial block is zero-padded before decrypting and the
    /// padding dropped afterwards, mirroring the TS loop.
    private static func tripleDESDecrypt(_ data: Data) -> Data? {
        let key = Data("!@#)(*$%123ZXC!@!@#)(NHL".utf8)
        let blockSize = kCCBlockSize3DES
        let paddedLength = ((data.count + blockSize - 1) / blockSize) * blockSize
        var padded = data
        if padded.count < paddedLength {
            padded.append(Data(repeating: 0, count: paddedLength - padded.count))
        }
        guard !padded.isEmpty else { return Data() }
        var out = Data(count: padded.count)
        var written = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            padded.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithm3DES),
                            CCOptions(kCCOptionECBMode),
                            keyPtr.baseAddress, key.count, nil,
                            dataPtr.baseAddress, padded.count,
                            outPtr.baseAddress, outPtr.count, &written)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(data.count)
    }

    /// Raw-deflate (RFC 1951, no zlib header) decompression, mirroring
    /// `qrcDecrypt.ts`'s `DecompressionStream('deflate')` step. The system
    /// zlib is used with `inflateInit2(..., -15)`; `zlib` is an SDK module
    /// on Apple platforms (the same mechanism `CommonCrypto` already
    /// relies on in this target), and the `canImport` guard keeps the file
    /// compiling anywhere it is absent — decryption then fails closed and
    /// the provider yields no lyrics.
    #if canImport(zlib)
    private static func inflateRawDeflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        return data.withUnsafeBytes { inputRaw -> Data? in
            guard let inputBase = inputRaw.baseAddress?.assumingMemoryBound(to: Bytef.self) else { return nil }
            var stream = z_stream()
            let initStatus = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
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
