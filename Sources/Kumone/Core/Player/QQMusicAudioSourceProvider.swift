import Foundation
import os.log

/// QQ Music audio source: searches QQ for the track, then resolves a
/// playback URL through the self-hosted `qq-music-api` backend
/// (`GET /getMusicPlay/:songmid`), downgrading quality tier by tier.
///
/// This is the first Golia source that searches another platform by
/// title/artist instead of resolving a NetEase ID directly, so it uses
/// the existing `AudioSourceTrackMatcher.matches` (title + artist +
/// duration within 5 s, version-marker check) rather than its own
/// normalization.
///
/// Flow (mirrors Folia's `qqProvider.ts` `getAudioSource` + `qqSearch.ts`):
/// 1. Search. With a session, the backend `/search` first; on failure,
///    or on an empty first page, fall back to the anonymous musicu
///    search (`u.y.qq.com`, no backend, no session). Without a session,
///    anonymous search directly. First candidate matching the track wins.
/// 2. Playback, highest tier first: `flac` -> `320` -> `128`
///    (Folia's lossless fallback chain). Any tier returning a URL wins.
///    The backend answers HTTP 200 with an empty `url` when the account
///    may not stream the song; that is "no audio", not a transient
///    error, and is not retried as one.
/// 3. Preview. Only with a session, and only when every tier came back
///    empty: one more `music_play` call with `preview=1`. Without a
///    session the backend gives no preview, so none is asked for.
///    NOTE: `ResolvedAudioSource` carries no preview flag, and
///    `UnblockService.isUsable` rejects audio far shorter than the
///    track, so a short preview returned here will currently be
///    dropped downstream as a trial clip. Carrying the preview flag
///    through to the player is a follow-up, not part of this file.
///
/// Requires a configured backend (`QQMusicSettings.baseURL`); with
/// none configured, `resolve` returns nil without a request, so an
/// unconfigured QQ source stays silent in the fallback chain.
struct QQMusicAudioSourceProvider: AudioSourceProvider {
    let id: AudioSourceID = .qqmusic
    let displayName = AudioSourceID.qqmusic.displayName

    private static let log = Logger(subsystem: "sb.moe.kumone", category: "qq-music")

    /// Quality tiers, highest first (Folia's lossless fallback chain:
    /// flac -> 320 -> 128).
    private static let qualityTiers = ["flac", "320", "128"]

    /// Folia's limit for a playback request: the backend chains up to
    /// four QQ calls (GetVkey, two 5 s CDN probes, GetCdnDispatch).
    private static let playTimeout: TimeInterval = 70

    private let session: QQMusicSession
    private let httpClient: QQMusicAPIClient

    init(session: QQMusicSession = .shared, httpClient: QQMusicAPIClient = .shared) {
        self.session = session
        self.httpClient = httpClient
    }

    func resolve(track: Track) async throws -> ResolvedAudioSource? {
        guard let baseURL = QQMusicSettings.baseURL else { return nil }
        guard let candidate = try await findCandidate(for: track) else { return nil }
        guard !candidate.songmid.isEmpty else { return nil }
        return try await playURL(for: candidate, baseURL: baseURL)
    }

    // MARK: - Search

    /// Searches for the track and returns the first candidate matching
    /// it, or nil when nothing matches.
    private func findCandidate(for track: Track) async throws -> QQMusicTrack? {
        let keyword = AudioSourceTrackMatcher.keyword(for: track)
        var candidates: [QQMusicTrack] = []
        if session.hasSession {
            do {
                candidates = try await session.searchSongs(keyword: keyword, limit: 20, page: 1)
            } catch {
                Self.log.warn("qq-music session search failed, falling back to anonymous search: \(error.localizedDescription, privacy: .public)")
                candidates = []
            }
            // A session search that answers empty on page 1 is retried
            // anonymously: the backend's session path sometimes returns
            // an empty list where the anonymous path answers normally.
            if candidates.isEmpty {
                candidates = try await httpClient.searchMusicu(keyword: keyword, page: 1, pageSize: 20)
            }
        } else {
            candidates = try await httpClient.searchMusicu(keyword: keyword, page: 1, pageSize: 20)
        }
        return candidates.first {
            AudioSourceTrackMatcher.matches(
                track: track, title: $0.title, artist: $0.artistDisplayName, durationMS: $0.durationMS)
        }
    }

    // MARK: - Playback

    /// Requests the playback URL tier by tier; any tier returning a URL
    /// wins. A tier that answers HTTP 200 with an empty `url` means the
    /// account cannot stream the song at that tier.
    private func playURL(for candidate: QQMusicTrack, baseURL: URL) async throws -> ResolvedAudioSource? {
        var sawEmptyPlayLink = false
        var standardTierEmpty = false
        var firstFailure: Error?
        var firstUnreachable: Error?
        let sentSession = session.sessionString

        for tier in Self.qualityTiers {
            do {
                let url = try await playURL(
                    songmid: candidate.songmid, mediaMid: candidate.mediaMid,
                    quality: tier, preview: false, baseURL: baseURL)
                if let url {
                    return ResolvedAudioSource(id: id, displayName: displayName, url: url)
                }
                sawEmptyPlayLink = true
                if tier == Self.qualityTiers.last { standardTierEmpty = true }
                Self.log.warn("qq-music playback:no-play-link quality=\(tier, privacy: .public)")
            } catch let error as QQMusicError {
                switch error {
                case .unauthorized:
                    // A 401 is only "this call was refused", not proof
                    // the login ended: let the session check decide
                    // whether the stored session goes, then surface it.
                    if let sentSession { session.checkSessionAfterRefusal(sent: sentSession) }
                    throw error
                case .rateLimited, .notConfigured:
                    throw error
                case .transport, .httpStatus:
                    // Unreachable (offline, or a 5xx with no refusal):
                    // record it and try the next tier.
                    if firstUnreachable == nil { firstUnreachable = error }
                    if firstFailure == nil { firstFailure = error }
                case .routeNotFound, .invalidResponse, .invalidURL,
                     .deviceLimit, .loginFailed, .notPlayable:
                    if firstFailure == nil { firstFailure = error }
                }
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }

        Self.log.warn("qq-music playback:no-source upstreamRefusedPlayLink=\(sawEmptyPlayLink, privacy: .public) standardTierEmpty=\(standardTierEmpty, privacy: .public)")
        // A tier was unreachable and the standard tier never answered
        // with an empty link: the account's playability is unknown, so
        // report the unreachable error (the caller retries) instead of
        // offering a preview that would mask a network blip as a
        // one-minute song.
        if firstUnreachable != nil, !standardTierEmpty { throw firstUnreachable! }
        if firstFailure != nil, !sawEmptyPlayLink { throw firstFailure! }

        // Every tier answered empty. With a session, ask once for the
        // trial clip; without one the backend gives no preview.
        if sawEmptyPlayLink, session.hasSession {
            if let previewURL = try await playURL(
                songmid: candidate.songmid, mediaMid: candidate.mediaMid,
                quality: nil, preview: true, baseURL: baseURL) {
                return ResolvedAudioSource(id: id, displayName: displayName, url: previewURL)
            }
        }
        throw QQMusicError.notPlayable
    }

    /// One `GET /getMusicPlay/:songmid` call. Returns the playback URL,
    /// or nil when the backend answered with an empty `url` for this
    /// tier. The `playUrl` map is keyed by songmid; the first value is
    /// accepted as a fallback, matching Folia.
    private func playURL(
        songmid: String, mediaMid: String?, quality: String?,
        preview: Bool, baseURL: URL
    ) async throws -> URL? {
        var params: [String: String] = [:]
        if let mediaMid, !mediaMid.isEmpty { params["mediaId"] = mediaMid }
        if let quality { params["quality"] = quality }
        if preview { params["preview"] = "1" }
        let body = try await httpClient.backend(
            "/getMusicPlay/\(songmid)", baseURL: baseURL, params: params,
            sessionString: session.sessionString, timeout: Self.playTimeout)
        let playURLMap = (body["data"] as? [String: Any])?["playUrl"] as? [String: Any] ?? [:]
        let entry = (playURLMap[songmid] as? [String: Any])
            ?? (playURLMap.values.first as? [String: Any])
        guard let urlString = entry?["url"] as? String,
              let url = URL(string: urlString),
              let scheme = url.scheme, scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }
        return url
    }
}
