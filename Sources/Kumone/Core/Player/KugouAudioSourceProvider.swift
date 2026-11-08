import CryptoKit
import Foundation
import os.log

/// KuGou audio source, ported from Folia v0.7.27
/// (`src/services/onlineMusic/kugou/kugouProvider.ts` playback +
/// `kugouTransport.ts` anonymous search / legacy play info).
/// Unlike the other providers it cannot resolve from a NetEase id:
/// it searches KuGou by title + artist, matches with the shared
/// `AudioSourceTrackMatcher`, then asks `/song/url` for a playback URL.
///
/// Two search paths, in Folia's order:
/// 1. Logged in (token + userid + dfid, backend configured): the
///    backend `/search` route. An empty first page falls back to (2).
/// 2. Anonymous search: KuGou's public Android search endpoint with
///    the signed parameters Folia's rendering layer carries
///    (`appid` 3116, `clientver` 11070, MD5 signature). Needs no
///    backend and no login, so KuGou works as a fallback source even
///    before the user configures anything.
///
/// URL ladder per matched hash: `/song/url` at quality 320 then 128
/// (Folia's high → standard ladder; each tried with album ids first,
/// then hash-only), then the public mobile endpoint
/// `https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=…`
/// as a last resort. No match returns `nil` so `UnblockService`
/// moves on to the next source; a matched hash with no URL anywhere
/// throws, like the other providers.
///
/// NOTE: this file references `AudioSourceID.kugou`, which does not
/// exist yet — adding that one enum case (see
/// `INTEGRATION-kugou.md`) is the wiring step that makes it compile.
struct KugouAudioSourceProvider: AudioSourceProvider {
    let id: AudioSourceID = .kugou
    let displayName = AudioSourceID.kugou.displayName

    private static let log = Logger(subsystem: "sb.moe.kumone", category: "audio-source")

    /// Public values from Folia's anonymous Android search
    /// (`requestKugouAnonymousSearch`). They identify an old public
    /// Android client; they are not secrets.
    private static let anonymousAppID = "3116"
    private static let anonymousClientVersion = "11070"
    private static let anonymousSignatureSalt = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
    private static let anonymousSearchURL = "http://complexsearch.kugou.com/v2/search/song"

    /// `/song/url` quality ladder (Folia `qualityValue`: high 320,
    /// standard 128). No lossless tier: Golia does not pass a quality
    /// preference into `AudioSourceProvider.resolve`.
    private static let urlQualities = ["320", "128"]

    private let session: KugouSession
    private let httpClient: AudioSourceClient
    private let anonymousSession: URLSession

    init(
        session: KugouSession = .shared,
        httpClient: AudioSourceClient = .shared,
        anonymousSession: URLSession? = nil
    ) {
        self.session = session
        self.httpClient = httpClient
        if let anonymousSession {
            self.anonymousSession = anonymousSession
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        self.anonymousSession = URLSession(configuration: configuration)
    }

    func resolve(track: Track) async throws -> ResolvedAudioSource? {
        let keyword = AudioSourceTrackMatcher.keyword(for: track)
        guard !keyword.isEmpty else { return nil }

        let candidates = await searchCandidates(keyword: keyword)
        guard let match = candidates.first(where: {
            AudioSourceTrackMatcher.matches(
                track: track, title: $0.title, artist: $0.artist, durationMS: $0.durationMS
            )
        }) else { return nil }

        let hash = match.hash.uppercased()

        // Backend `/song/url`, 320 then 128. A rejected login is
        // thrown at once (the session is already cleared); anything
        // else just moves to the next rung / the legacy endpoint.
        if session.isBackendConfigured {
            for quality in Self.urlQualities {
                if let url = try await session.songURL(
                    hash: hash, quality: quality,
                    albumID: match.albumID, albumAudioID: match.albumAudioID
                ) {
                    return ResolvedAudioSource(id: id, displayName: displayName, url: url)
                }
            }
        }

        if let url = try? await legacyPlayInfoURL(hash: hash) {
            return ResolvedAudioSource(id: id, displayName: displayName, url: url)
        }
        throw AudioSourceProviderError.missingStreamURL
    }

    // MARK: - Search

    private func searchCandidates(keyword: String) async -> [KugouSong] {
        if session.hasAuthenticatedSession {
            do {
                let authed = try await session.searchSongs(keyword: keyword, page: 1, pageSize: 10)
                if !authed.isEmpty { return authed }
                // An expired login answers an empty list without an
                // error; fall through to anonymous search.
                Self.log.info("source=kugou operation=search detail=authenticated-empty-falling-back-to-anonymous")
            } catch KugouError.sessionExpired {
                Self.log.info("source=kugou operation=search detail=session-expired-falling-back-to-anonymous")
            } catch {
                Self.log.error("source=kugou operation=search detail=authenticated-search-failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
        do {
            return try await anonymousSearch(keyword: keyword, page: 1, pageSize: 10)
        } catch {
            Self.log.error("source=kugou operation=search detail=anonymous-search-failed error=\(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Anonymous Android search, ported from Folia's
    /// `requestKugouAnonymousSearch`: `signature = md5(salt +
    /// key-sorted "key=value" concatenation + salt)`,
    /// `mid = md5(current millisecond timestamp)`. Uses its own
    /// ephemeral session because the `KG-*` / `mid` / `x-router`
    /// headers cannot go through `AudioSourceClient`.
    private func anonymousSearch(keyword: String, page: Int, pageSize: Int) async throws -> [KugouSong] {
        let clientTimeMs = Int(Date().timeIntervalSince1970 * 1_000)
        let clientTimeSec = clientTimeMs / 1_000
        let mid = Self.md5Hex(String(clientTimeMs))
        var params: [String: String] = [
            "sorttype": "0",
            "keyword": keyword,
            "pagesize": String(pageSize),
            "page": String(page),
            "userid": "0",
            "appid": Self.anonymousAppID,
            "token": "",
            "clienttime": String(clientTimeSec),
            "iscorrection": "1",
            "uuid": "-",
            "mid": mid,
            "dfid": "-",
            "clientver": Self.anonymousClientVersion,
            "platform": "AndroidFilter",
        ]
        let signatureSource = params.keys.sorted().map { "\($0)=\(params[$0] ?? "")" }.joined()
        params["signature"] = Self.md5Hex("\(Self.anonymousSignatureSalt)\(signatureSource)\(Self.anonymousSignatureSalt)")

        var components = URLComponents(string: Self.anonymousSearchURL)
        components?.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw AudioSourceError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Android14-1070-11070-201-0-SearchSong-wifi", forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "KG-Rec")
        request.setValue("1", forHTTPHeaderField: "KG-RC")
        request.setValue(String(clientTimeMs), forHTTPHeaderField: "KG-CLIENTTIMEMS")
        request.setValue(mid, forHTTPHeaderField: "mid")
        request.setValue("complexsearch.kugou.com", forHTTPHeaderField: "x-router")

        let (data, response) = try await anonymousSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AudioSourceProviderError.invalidResponse }
        let errorCode = KugouJSON.errorCode(of: json) ?? 0
        guard errorCode == 0 || errorCode == 200 else {
            throw AudioSourceProviderError.invalidResponse
        }
        return KugouJSON.listOf(json).compactMap(KugouSong.from)
    }

    // MARK: - Legacy mobile fallback

    /// `https://m.kugou.com/app/i/getSongInfo.php?cmd=playInfo&hash=…`,
    /// Folia's `requestKugouLegacyPlayInfo`. Public, needs no backend
    /// and no login. `url`, else `backup_url`, top-level or under `data`.
    private func legacyPlayInfoURL(hash: String) async throws -> URL? {
        var components = URLComponents(string: "https://m.kugou.com/app/i/getSongInfo.php")
        components?.queryItems = [
            URLQueryItem(name: "cmd", value: "playInfo"),
            URLQueryItem(name: "hash", value: hash),
        ]
        guard let urlString = components?.url?.absoluteString else {
            throw AudioSourceError.invalidURL
        }
        let data = try await httpClient.data(
            from: urlString,
            source: id,
            operation: "legacy-play-info",
            userAgent: "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/124.0.0.0 Mobile Safari/537.36"
        )
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AudioSourceProviderError.invalidResponse
        }
        // Folia prefers `url` (top-level, then `data`) over
        // `backup_url` (top-level, then `data`).
        let candidates = [
            KugouJSON.string(json, "url"),
            KugouJSON.string(KugouJSON.dataOf(json), "url"),
            KugouJSON.string(json, "backup_url"),
            KugouJSON.string(KugouJSON.dataOf(json), "backup_url"),
        ].compactMap { $0 }
        for candidate in candidates {
            for part in candidate.split(separator: ",").map(String.init) {
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: trimmed),
                   let scheme = url.scheme, scheme == "http" || scheme == "https",
                   url.host != nil {
                    return url
                }
            }
        }
        return nil
    }

    private static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
