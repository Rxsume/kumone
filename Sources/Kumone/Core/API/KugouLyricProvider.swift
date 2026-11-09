import CryptoKit
import Foundation

// Kugou lyrics provider for the multi-source lyric system.
//
// Direct, server-free port of Folia's dead-code
// `src/services/onlineMusic/kugou/kugouLyricProvider.ts`. The public lyrics
// endpoints answer without any login, cookie, or proxy server (verified
// 2026-11-08 against the live endpoints: song search, lyric search, and
// download all return HTTP 200 with usable payloads; the only credential is
// a request signature computed locally from a hardcoded salt — no account).
// Folia's live path instead goes through its KuGouMusicApi server
// (`search_lyric` + `lyric`, with server-side KRC decoding); this provider
// makes the same three calls directly and decrypts KRC on-device
// (see KugouKRCParser).
//
// Flow: song search (complexsearch, gives the Kugou file hash) -> score the
// hits with LyricMatch.evaluate -> lyric search for the best accepted hit ->
// download the first lyric candidate (fmt=krc) -> KRC decrypt + parse into
// LRC text and YRC word-timing text.
struct KugouLyricProvider: LyricProvider {
    var source: LyricSource { .kugou }

    func fetch(for track: Track) async -> LyricCandidate? {
        do {
            return try await fetchThrowing(for: track)
        } catch {
            return nil
        }
    }

    private func fetchThrowing(for track: Track) async throws -> LyricCandidate? {
        let title = track.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = track.artists.first?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty, !artist.isEmpty else { return nil }

        // 1. Song search: the lyric endpoints need a Kugou file hash, which
        //    only the song search provides.
        let songs = try await searchSongs(keyword: "\(title) \(artist)")
        try Task.checkCancellation()
        guard !songs.isEmpty else { return nil }

        // 2. Score the hits; the best accepted one wins, nothing otherwise.
        var best: (song: KugouSong, score: Double)?
        for song in songs {
            let result = LyricMatch.evaluate(
                title: song.songName,
                artist: song.artistNames,
                album: song.albumName.isEmpty ? nil : song.albumName,
                duration: song.duration > 0 ? TimeInterval(song.duration) : nil,
                track: track)
            guard result.accepted else { continue }
            if best == nil || result.score > best!.score {
                best = (song, result.score)
            }
        }
        guard let match = best else { return nil }
        let song = match.song

        // 3. Lyric search for the matched hash (Folia: keyword
        //    "artist - title", duration in ms, album_audio_id when the song
        //    search gave one). Folia takes the first candidate.
        let candidate = try await searchLyrics(for: song)
        try Task.checkCancellation()
        guard let candidate else { return nil }

        // 4. Download (fmt=krc) and decode.
        let downloaded = try await downloadLyrics(id: candidate.id, accessKey: candidate.accessKey)
        try Task.checkCancellation()
        guard let downloaded else { return nil }
        guard let parsed = KugouKRCParser.parseDownloadedLyric(
            bytes: downloaded.bytes, contentType: downloaded.contentType)
        else { return nil }

        let response = LyricResponse(
            lrc: LyricResponse.LyricBody(lyric: parsed.lrc),
            tlyric: nil,
            romalrc: nil,
            yrc: parsed.yrc.map { LyricResponse.LyricBody(lyric: $0) },
            ytlrc: nil,
            yromalrc: nil,
            lyricUser: nil,
            transUser: nil,
            nolyric: false,
            uncollected: false)
        return LyricCandidate(
            source: .kugou,
            response: response,
            isWordByWord: parsed.isWordByWord,
            isPureMusic: KugouKRCParser.isPureMusic(parsed.lrc))
    }

    // MARK: - Song search

    private func searchSongs(keyword: String) async throws -> [KugouSong] {
        let response: SongSearchResponse = try await get(
            url: "https://complexsearch.kugou.com/v2/search/song",
            module: "SearchSong",
            params: ["sorttype": "0", "keyword": keyword, "pagesize": "5", "page": "1"],
            headers: ["x-router": "complexsearch.kugou.com"])
        return response.data?.lists ?? []
    }

    // MARK: - Lyric search + download

    private func searchLyrics(for song: KugouSong) async throws -> KugouLyricCandidate? {
        var params: [String: String] = [
            "hash": song.fileHash.uppercased(),
            "duration": String(song.duration * 1000),
            "keyword": "\(song.artistNames) - \(song.songName)",
            "lrctxt": "1",
            "man": "no",
        ]
        if let albumAudioID = song.albumAudioID ?? song.mixSongID {
            params["album_audio_id"] = String(albumAudioID)
        }
        let response: LyricSearchResponse = try await get(
            url: "https://lyrics.kugou.com/v1/search",
            module: "Lyric",
            params: params)
        return response.candidates?.first
    }

    private func downloadLyrics(id: String, accessKey: String) async throws -> DownloadedLyric? {
        let response: DownloadResponse = try await get(
            url: "https://lyrics.kugou.com/download",
            module: "Lyric",
            params: [
                "accesskey": accessKey,
                "charset": "utf8",
                "client": "mobi",
                "fmt": "krc",
                "id": id,
                "ver": "1",
            ])
        guard let content = response.content,
              let bytes = Data(base64Encoded: content)
        else { return nil }
        return DownloadedLyric(bytes: bytes, contentType: response.contenttype)
    }

    // MARK: - Signed Kugou requests

    /// Performs a signed GET and decodes the JSON body. Mirrors Folia's
    /// `requestKugou` (same params, same signature, same headers); the
    /// signature is an MD5 over a hardcoded salt plus the sorted params —
    /// no account, token, or cookie is involved. An unsigned lyric search
    /// returns HTTP 200 with an empty body, so the signature is required.
    private func get<T: Decodable>(
        url: String,
        module: String,
        params: [String: String],
        headers: [String: String] = [:]
    ) async throws -> T {
        let clientTimeMs = Int(Date().timeIntervalSince1970 * 1000)
        let mid = md5Hex(String(clientTimeMs))
        var signed = params
        if module == "Lyric" {
            signed["appid"] = "3116"
            signed["clientver"] = "11070"
        } else {
            signed["userid"] = "0"
            signed["appid"] = "3116"
            signed["token"] = ""
            signed["clienttime"] = String(clientTimeMs / 1000)
            signed["iscorrection"] = "1"
            signed["uuid"] = "-"
            signed["mid"] = mid
            signed["dfid"] = "-"
            signed["clientver"] = "11070"
            signed["platform"] = "AndroidFilter"
        }
        signed["signature"] = kugouSignature(signed)

        var components = URLComponents(string: url)
        components?.queryItems = signed.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let requestURL = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 10
        request.setValue("Android14-1070-11070-201-0-\(module)-wifi", forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "KG-Rec")
        request.setValue("1", forHTTPHeaderField: "KG-RC")
        request.setValue(String(clientTimeMs), forHTTPHeaderField: "KG-CLIENTTIMEMS")
        request.setValue(mid, forHTTPHeaderField: "mid")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// `md5(salt + sorted "key=value" pairs + salt)`, exactly as Folia's
    /// `signParams` in `kugouLyricProvider.ts`.
    private func kugouSignature(_ params: [String: String]) -> String {
        let salt = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
        let body = params.keys.sorted()
            .map { "\($0)=\(params[$0] ?? "")" }.joined()
        return md5Hex(salt + body + salt)
    }
}

// MARK: - Response models

private struct SongSearchResponse: Decodable {
    let data: SongSearchData?
}

private struct SongSearchData: Decodable {
    let lists: [KugouSong]?
}

private struct KugouSong: Decodable {
    let songName: String
    let singers: [KugouSinger]
    let albumName: String
    /// Duration in seconds, as the song search reports it.
    let duration: Int
    let fileHash: String
    let albumAudioID: Int?
    let mixSongID: Int?

    var artistNames: String { singers.map(\.name).joined(separator: ", ") }

    private enum CodingKeys: String, CodingKey {
        case songName = "SongName"
        case singers = "Singers"
        case albumName = "AlbumName"
        case duration = "Duration"
        case fileHash = "FileHash"
        case albumAudioID = "album_audio_id"
        case mixSongID = "MixSongID"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        songName = (try? container.decode(String.self, forKey: .songName)) ?? ""
        singers = (try? container.decode([KugouSinger].self, forKey: .singers)) ?? []
        albumName = (try? container.decode(String.self, forKey: .albumName)) ?? ""
        duration = (try? container.decode(Int.self, forKey: .duration)) ?? 0
        fileHash = (try? container.decode(String.self, forKey: .fileHash)) ?? ""
        albumAudioID = Self.flexibleInt(container, .albumAudioID)
        mixSongID = Self.flexibleInt(container, .mixSongID)
    }

    private static func flexibleInt(
        _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) { return value }
        if let text = try? container.decode(String.self, forKey: key) { return Int(text) }
        return nil
    }
}

private struct KugouSinger: Decodable {
    let name: String

    private enum CodingKeys: String, CodingKey {
        case name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
    }
}

private struct LyricSearchResponse: Decodable {
    let candidates: [KugouLyricCandidate]?
}

private struct KugouLyricCandidate: Decodable {
    let id: String
    let accessKey: String
    /// Candidate duration in milliseconds, as the lyric search reports it.
    let duration: Int
    let song: String
    let singer: String

    private enum CodingKeys: String, CodingKey {
        case id, accesskey, duration, song, singer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(Int.self, forKey: .id) {
            id = String(value)
        } else {
            id = (try? container.decode(String.self, forKey: .id)) ?? ""
        }
        accessKey = (try? container.decode(String.self, forKey: .accesskey)) ?? ""
        duration = (try? container.decode(Int.self, forKey: .duration)) ?? 0
        song = (try? container.decode(String.self, forKey: .song)) ?? ""
        singer = (try? container.decode(String.self, forKey: .singer)) ?? ""
    }
}

private struct DownloadResponse: Decodable {
    let content: String?
    /// "0" for encrypted KRC, "2" for plain text (Folia compares the string).
    let contenttype: String?

    private enum CodingKeys: String, CodingKey {
        case content, contenttype
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try? container.decode(String.self, forKey: .content)
        if let value = try? container.decode(Int.self, forKey: .contenttype) {
            contenttype = String(value)
        } else {
            contenttype = try? container.decode(String.self, forKey: .contenttype)
        }
    }
}

private struct DownloadedLyric {
    let bytes: Data
    let contentType: String?
}
