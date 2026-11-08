import Foundation
import os.log

/// KuGou audio source, adapted from Beans' direct-to-KuGou
/// implementation (no self-hosted backend).
///
/// Two resolve paths:
/// 1. Direct: the track already came from a KuGou search
///    (`platformSource == .kugou`), so `platformSongKey` carries
///    `hash` or `hash|albumAudioId|albumId` — go straight down the
///    `/v5/url` ladder, no search.
/// 2. Search: search KuGou by title + artist (anonymous signed
///    search, no login, no backend), match with the shared
///    `AudioSourceTrackMatcher`, then resolve the matched hash.
///
/// Nothing found returns `nil` (never throws) so `UnblockService`
/// moves on to the next source.
struct KugouAudioSourceProvider: AudioSourceProvider {
    let id: AudioSourceID = .kugou
    let displayName = AudioSourceID.kugou.displayName

    private static let log = Logger(subsystem: "sb.moe.kumone", category: "audio-source")

    init() {}

    func resolve(track: Track) async throws -> ResolvedAudioSource? {
        // Direct path: the key already identifies the KuGou song.
        if track.platformSource == .kugou,
           let key = track.platformSongKey, !key.isEmpty {
            let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let hash = parts[0]
            let albumAudioId = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
            let albumId = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
            guard !hash.isEmpty else { return nil }
            if let url = try? await KugouMusicAPI.shared.songURL(
                hash: hash, albumAudioId: albumAudioId, albumId: albumId
            ) {
                return ResolvedAudioSource(id: id, displayName: displayName, url: url)
            }
            return nil
        }

        // Search path: anonymous search, then match, then resolve.
        let keyword = AudioSourceTrackMatcher.keyword(for: track)
        guard !keyword.isEmpty else { return nil }
        let candidates: [KugouMusicSong]
        do {
            candidates = try await KugouMusicAPI.shared.searchSongs(keyword: keyword, limit: 10)
        } catch {
            Self.log.error(
                "source=kugou operation=search detail=search-failed error=\(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
        guard let match = candidates.first(where: {
            AudioSourceTrackMatcher.matches(
                track: track,
                title: $0.title,
                artist: $0.artistNames.joined(separator: " / "),
                durationMS: $0.durationMS
            )
        }) else { return nil }

        if let url = try? await KugouMusicAPI.shared.songURL(song: match) {
            return ResolvedAudioSource(id: id, displayName: displayName, url: url)
        }
        return nil
    }
}
