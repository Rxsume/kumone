import Foundation
import os.log

/// QQ Music audio source, adapted from Beans' direct-to-QQ
/// implementation (`QQMusicAPI` / `QQMusicAuth` in this folder).
/// No backend is involved: search goes straight to QQ's public
/// endpoints and playback URLs come from QQ's vkey flow.
///
/// Two resolve paths:
/// 1. Direct. When the track already came from a QQ search
///    (`track.platformSource == .qqmusic`), `track.platformSongKey`
///    holds `songmid` or `songmid|mediaMid`; the vkey ladder is run
///    straight away with no search.
/// 2. Search. Otherwise the track is searched by title + artist and
///    the first candidate matching it (`AudioSourceTrackMatcher`:
///    title + artist + duration within 5 s, version-marker check)
///    goes down the same ladder.
///
/// Playback, highest tier first: F000 (FLAC) -> M800 (320k) ->
/// M500 (128k) -> C400. A tier answering with no playable URL means
/// the account cannot stream the song at that tier — that is "no
/// audio", not a transient error. Anonymous callers get free tracks
/// only; logged-in callers attach `authst` + cookies through
/// `QQMusicAPI`, so VIP tracks resolve when the account allows.
///
/// Returns nil (never throws) when nothing is found, so
/// `UnblockService` moves on to the next source. No preview request:
/// a short preview clip would be dropped downstream by the
/// short-clip probe anyway.
struct QQMusicAudioSourceProvider: AudioSourceProvider {
    let id: AudioSourceID = .qqmusic
    let displayName = AudioSourceID.qqmusic.displayName

    private static let log = Logger(subsystem: "sb.moe.kumone", category: "qq-music")

    /// vkey quality ladder, highest first.
    private static let qualityTiers = ["F000", "M800", "M500", "C400"]

    init() {}

    func resolve(track: Track) async throws -> ResolvedAudioSource? {
        // Direct path: the track already is a QQ song.
        if track.platformSource == .qqmusic,
           let key = track.platformSongKey, !key.isEmpty {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            let songmid = parts[0]
            guard !songmid.isEmpty else { return nil }
            let mediaMid = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
            return await playURL(songmid: songmid, mediaMid: mediaMid)
        }

        // Search path: find the QQ song matching this track, then play it.
        let keyword = AudioSourceTrackMatcher.keyword(for: track)
        guard !keyword.isEmpty else { return nil }
        guard let candidates = try? await QQMusicAPI.shared.searchSongs(keyword: keyword, limit: 20),
              let candidate = candidates.first(where: {
                  AudioSourceTrackMatcher.matches(
                      track: track, title: $0.title,
                      artist: $0.artistDisplayName, durationMS: $0.durationMS)
              }),
              !candidate.songmid.isEmpty
        else { return nil }
        return await playURL(songmid: candidate.songmid, mediaMid: candidate.mediaMid)
    }

    /// Requests the playback URL tier by tier; any tier returning a URL
    /// wins. Nil when no tier yields a playable URL.
    private func playURL(songmid: String, mediaMid: String?) async -> ResolvedAudioSource? {
        for br in Self.qualityTiers {
            if let urlString = try? await QQMusicAPI.shared.songURL(songmid: songmid, mediaMid: mediaMid, br: br),
               let url = URL(string: urlString),
               let scheme = url.scheme, scheme == "http" || scheme == "https",
               url.host != nil {
                return ResolvedAudioSource(id: id, displayName: displayName, url: url)
            }
            Self.log.debug("qq-music playback:no-play-link br=\(br, privacy: .public) songmid=\(songmid, privacy: .public)")
        }
        return nil
    }
}
