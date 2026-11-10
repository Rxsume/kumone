import Foundation

/// Beans-style direct lyric lookup by a platform track's own song key
/// (Beans `PlayerView` lyric loading: Kugou by file hash, QQ by
/// songmid). Unlike the Folia search-based providers, this asks the
/// platform for the lyrics of this exact song — no title/artist
/// search, no match-score gate, no DES/KRC song search. It is what
/// rescues the songs the search flow misses on-device (QQ 青花瓷,
/// 2026-11-10: the direct QQ endpoint returns timed LRC live while
/// the search flow finds nothing for the same song). Tried first in
/// `MusicAPI.lyric(for:)`; on any miss it falls through to the normal
/// multi/single-source paths, so NetEase tracks are unaffected.
/// Trade-off, stated plainly: a direct hit returns immediately, so
/// a song whose direct endpoint has LRC-only shows line-timed lyrics
/// instead of the QRC word-timing the search flow might have found.
/// That is Beans' own behaviour for this song (its direct QQ endpoint
/// returns no QRC for 青花瓷 either), and a lyric at all beats no lyric.
enum LyricDirectFetch {
    static func fetch(for track: Track) async -> LyricResponse? {
        guard let source = track.platformSource,
              let key = track.platformSongKey, !key.isEmpty else { return nil }
        let candidate: LyricCandidate?
        switch source {
        case .qqmusic:
            candidate = await QQLyricProvider.fetchDirect(platformKey: key)
        case .kugou:
            candidate = await KugouLyricProvider().fetchDirect(platformKey: key, track: track)
        default:
            return nil
        }
        guard let candidate else { return nil }
        let parsed = LyricsParser.parse(candidate.response)
        guard !parsed.isEmpty, !parsed.isInstrumental else { return nil }
        return candidate.response
    }
}
