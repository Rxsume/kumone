import Foundation
import os.log

// AMLL lyrics provider for the multi-source lyric system.
//
// Port of Folia's AMLL DB provider (`providers/amllDbProvider.ts` +
// `providers/amllApi.ts`): the AMLL TTML DB official API at
// https://api.amll.dev, no login, no proxy. The fetched TTML is parsed by
// `TTMLLyricParser` into the LRC / YRC text `LyricsParser` understands.
//
// Flow: get-by-NetEase-ID first, then one title+artist search whose hits
// are scored with `LyricMatch.evaluate` and only the best accepted hit is
// fetched. Request timeouts are 10s; the orchestrator enforces the 5s
// per-source budget, and `Task.isCancelled` is checked between steps.
//
// Endpoints (Folia `amllApi.ts`):
//   GET /v1/lyrics/get?ncmMusicId=<id>
//   GET /v1/lyrics/search?musicName=<title>&artistName=<artist>&pageSize=10
// Both answer `{ status: 200, data: … }`; anything else (404 unlisted,
// 429 rate-limited, non-200, bad JSON) is a miss, never retried.
// The search payload carries no lyrics and no duration, so candidates are
// scored with `duration: nil`.
//
// QQ probing does not apply here: Folia tries a QQ mid first and then the
// numeric QQ id because QQ songs are filed under either. Rumxs tracks
// carry a NetEase id only and no QQ mid, so the only ID path is
// `?ncmMusicId=<neteaseId>`; QQ ids are never consulted.
//
// Deviations from Folia's search ladder (`amllDbCandidates.ts`): Folia
// tries up to four queries (full title + artist, suffix-stripped title +
// artist, stripped title alone, then a `q` full-text query). This provider
// makes exactly one search — suffix-stripped title + first artist — to
// stay inside the rate limit and the 5s budget. Only the best accepted hit
// is fetched; if its TTML fetch comes back empty, the provider returns nil
// instead of fanning out to the next hit.
//
// `isPureMusic` is always false: the AMLL payload has no pure-music flag
// and TTML carries none, so a song with no usable lines is a miss (nil),
// not a pure-music verdict.
//
// NOTE on the type name: the task brief called this `AmllLyricProvider`,
// but the landed contract file (`LyricProviders.swift`) wires the factory
// to `AMLLLyricProvider()`, so the type is named to match it.
struct AMLLLyricProvider: LyricProvider {
    var source: LyricSource { .amll }

    func fetch(for track: Track) async -> LyricCandidate? {
        // 1. Get by NetEase id: the track's own platform id, one request.
        if track.id > 0, let ttml = await fetchLyrics(ncmMusicId: String(track.id)) {
            if let candidate = candidate(fromTTML: ttml) { return candidate }
        }
        guard !Task.isCancelled else { return nil }

        // 2. Search by title + first artist, score, fetch the best
        // accepted hit only.
        guard let match = await searchBestMatch(for: track) else { return nil }
        guard !Task.isCancelled else { return nil }
        guard let ncmId = match.ncmMusicIds?.first(where: { !$0.isEmpty }) else { return nil }
        guard let ttml = await fetchLyrics(ncmMusicId: ncmId) else { return nil }
        return candidate(fromTTML: ttml)
    }

    // MARK: - API

    private static let baseURL = "https://api.amll.dev"
    private static let userAgent = "Golia (Rxsume/kumone)"
    private static let log = Logger(subsystem: "sb.moe.kumone", category: "amll")

    /// `GET /v1/lyrics/get?ncmMusicId=<id>`; returns the TTML text, or nil
    /// on any miss (unlisted, rate-limited, non-200, bad JSON, not TTML).
    /// Folia only checks that the lyrics look like TTML (`<tt …>`); the
    /// `format` field is ignored the same way.
    private func fetchLyrics(ncmMusicId: String) async -> String? {
        var components = URLComponents(string: Self.baseURL + "/v1/lyrics/get")
        components?.queryItems = [URLQueryItem(name: "ncmMusicId", value: ncmMusicId)]
        guard let url = components?.url, let data = await getData(from: url) else { return nil }
        guard let envelope = try? JSONDecoder().decode(AmllEnvelope<AmllSong>.self, from: data),
              envelope.status == 200,
              let song = envelope.data,
              let lyrics = song.lyrics,
              !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.looksLikeTTML(lyrics) else { return nil }
        return lyrics
    }

    /// One `GET /v1/lyrics/search` with the suffix-stripped title and the
    /// first artist; returns the best accepted hit, or nil when none is
    /// accepted. Hits without a NetEase id cannot be fetched and are
    /// skipped — the search payload's QQ ids are unusable here (see the
    /// file header).
    private func searchBestMatch(for track: Track) async -> AmllSong? {
        let title = Self.stripTitleSuffix(track.name)
        let artist = track.artists.first?.name ?? ""
        guard !title.isEmpty else { return nil }
        var components = URLComponents(string: Self.baseURL + "/v1/lyrics/search")
        var items: [URLQueryItem] = [URLQueryItem(name: "musicName", value: title)]
        if !artist.isEmpty { items.append(URLQueryItem(name: "artistName", value: artist)) }
        items.append(URLQueryItem(name: "pageSize", value: "10"))
        components?.queryItems = items
        guard let url = components?.url, let data = await getData(from: url) else { return nil }
        guard let page = try? JSONDecoder().decode(AmllEnvelope<AmllSearchPage>.self, from: data),
              let songs = page.data?.items, !songs.isEmpty else { return nil }
        var best: (song: AmllSong, score: Double)?
        for song in songs {
            guard song.ncmMusicIds?.contains(where: { !$0.isEmpty }) == true else { continue }
            // The search payload carries no duration, so it scores unknown.
            let result = LyricMatch.evaluate(
                title: song.musicNames?.first ?? "",
                artist: (song.artistNames ?? []).joined(separator: " / "),
                album: song.albumNames?.first,
                duration: nil,
                track: track)
            guard result.accepted else { continue }
            if best == nil || result.score > best!.score {
                best = (song, result.score)
            }
        }
        return best?.song
    }

    /// Plain GET with a 10s timeout. Non-200 is a miss (404/429 included);
    /// 429 is logged, matching Folia's rate-limit warning. Network errors
    /// are misses too — no retries, no parallel fan-out.
    private func getData(from url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        // An identifiable UA, as Folia does for its Electron builds, so the
        // upstream can tell this client apart from a generic fetch.
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 429 {
                Self.log.warning("[AMLL] Rate limited by api.amll.dev")
                return nil
            }
            guard http.statusCode == 200 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    // MARK: - TTML -> candidate

    private func candidate(fromTTML ttml: String) -> LyricCandidate? {
        let parsed = TTMLLyricParser.parse(ttml)
        guard !parsed.lines.isEmpty else { return nil }
        let lrc = parsed.lrcText()
        guard !lrc.isEmpty else { return nil }
        // Translation / romanization are line-timed LRC, so they go in
        // `tlyric` / `romalrc`, not the word-timed `ytlrc` / `yromalrc`.
        let response = LyricResponse(
            lrc: LyricResponse.LyricBody(lyric: lrc),
            tlyric: parsed.translationLRCText().map { LyricResponse.LyricBody(lyric: $0) },
            romalrc: parsed.romanizationLRCText().map { LyricResponse.LyricBody(lyric: $0) },
            yrc: parsed.yrcText().map { LyricResponse.LyricBody(lyric: $0) },
            ytlrc: nil,
            yromalrc: nil,
            lyricUser: nil,
            transUser: nil,
            nolyric: false,
            uncollected: false)
        return LyricCandidate(
            source: .amll,
            response: response,
            isWordByWord: parsed.isWordByWord,
            isPureMusic: false)
    }

    // MARK: - Helpers

    /// Folia `amllDbProvider`: the lyrics must look like TTML,
    /// `/<tt(?:\s|>)/i`. A bare "<tt" inside other text does not count.
    private static func looksLikeTTML(_ lyrics: String) -> Bool {
        let lower = lyrics.lowercased()
        var searchFrom = lower.startIndex
        while let range = lower.range(of: "<tt", range: searchFrom..<lower.endIndex) {
            let next = range.upperBound
            if next == lower.endIndex { return false }
            let character = lower[next]
            if character == ">" || character.isWhitespace { return true }
            searchFrom = range.upperBound
        }
        return false
    }

    /// Folia `stripTitleSuffix`: drop trailing bracketed asides such as
    /// "Idol (TV Size)" -> "Idol", so the contains-match search still
    /// finds the un-suffixed entry. Unbalanced or empty results keep the
    /// original title.
    private static func stripTitleSuffix(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespaces)
        let pairs: [Character: Character] = [")": "(", "]": "[", "）": "（", "】": "【"]
        while let last = text.last, let opener = pairs[last] {
            // Walk back from the trailing closer to its matching opener,
            // counting nesting, so "A (x (y))" strips as one segment and
            // an unbalanced "A (B) C)" strips nothing at all.
            var depth = 0
            var match: String.Index?
            var index = text.index(before: text.endIndex)
            while true {
                let character = text[index]
                if character == last {
                    depth += 1
                } else if character == opener {
                    depth -= 1
                    if depth == 0 { match = index; break }
                }
                if index == text.startIndex { break }
                index = text.index(before: index)
            }
            guard let openIndex = match else { break }
            text = String(text[..<openIndex]).trimmingCharacters(in: .whitespaces)
        }
        return text.isEmpty ? title : text
    }
}

// MARK: - Response models (tolerant decodes: any unexpected field shape
// drops that field instead of failing the whole payload)

private struct AmllEnvelope<T: Decodable>: Decodable {
    let status: Int?
    let data: T?

    private enum CodingKeys: String, CodingKey {
        case status, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try? container.decode(Int.self, forKey: .status)
        data = try? container.decode(T.self, forKey: .data)
    }
}

/// One AMLL DB song entry. The search endpoint returns everything except
/// `lyrics`; the get endpoint adds `lyrics` (TTML text).
private struct AmllSong: Decodable {
    let musicNames: [String]?
    let artistNames: [String]?
    let albumNames: [String]?
    let ncmMusicIds: [String]?
    let lyrics: String?

    private enum CodingKeys: String, CodingKey {
        case musicNames, artistNames, albumNames, ncmMusicIds, lyrics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        musicNames = try? container.decode([String].self, forKey: .musicNames)
        artistNames = try? container.decode([String].self, forKey: .artistNames)
        albumNames = try? container.decode([String].self, forKey: .albumNames)
        ncmMusicIds = try? container.decode([String].self, forKey: .ncmMusicIds)
        lyrics = try? container.decode(String.self, forKey: .lyrics)
    }
}

private struct AmllSearchPage: Decodable {
    let items: [AmllSong]?

    private enum CodingKeys: String, CodingKey {
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try? container.decode([AmllSong].self, forKey: .items)
    }
}
