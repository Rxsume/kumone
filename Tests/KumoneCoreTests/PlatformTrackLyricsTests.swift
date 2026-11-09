import Foundation
import Testing
@testable import KumoneCore

/// Regression tests for platform-track lyrics (QQ/Kugou songs had no
/// lyrics after the Folia rollback removed the QQ QRC/DES lyric
/// provider: `MusicAPI.lyric(for:)` returned nil for every platform
/// track). The fix resolves the platform track to the same song on
/// NetEase via the shared `matchedNetEaseTrack` helper — the same
/// match playback already trusts — and loads that track's lyrics.
///
/// `MusicAPI.lyric(for:)` itself is not tested end-to-end here: it
/// goes through the hardcoded `MusicClient.shared` eapi (encrypted
/// requests, no client injection point), so stubbing it would need
/// real network access or a reimplementation of the eapi crypto.
/// These tests pin the shared resolution the fix depends on: a
/// platform track with a confident NetEase match resolves to that
/// track (whose lyrics `lyric(for:)` then loads), and one with no
/// confident match resolves to nil (so `lyric(for:)` still returns
/// nil, exactly as before).
@Suite("Platform track lyrics (matched NetEase track)")
struct PlatformTrackLyricsTests {
    /// The user-reported case: QQ 《晴天》 playing via the ikun
    /// sponsored script (build 767) showed no lyrics.
    @Test func qqTrackWithConfidentMatchResolvesToNetEaseTrack() async {
        let qq = Track.platform(
            source: .qqmusic, songKey: "004Z8Ijz0wKx4A", name: "晴天",
            artistNames: ["周杰伦"], albumName: "叶惠美", albumPicURL: nil,
            durationMS: 269_000)
        let match = await UnblockService.matchedNetEaseTrack(
            for: qq, search: stubSearch(matching: qq, netEaseID: 186016))
        #expect(match?.id == 186016)
    }

    /// Kugou takes the identical code path: the matcher reads only
    /// title/artist/duration, never the platform, so a Kugou track
    /// must resolve exactly like a QQ track.
    @Test func kugouTrackWithConfidentMatchResolvesToNetEaseTrack() async {
        let kugou = Track.platform(
            source: .kugou, songKey: "A1B2C3D4E5F60718293A4B5C6D7E8F90",
            name: "晴天", artistNames: ["周杰伦"], albumName: "叶惠美",
            albumPicURL: nil, durationMS: 269_000)
        let match = await UnblockService.matchedNetEaseTrack(
            for: kugou, search: stubSearch(matching: kugou, netEaseID: 186016))
        #expect(match?.id == 186016)
    }

    /// No candidates at all: no match, so `lyric(for:)` returns nil.
    @Test func platformTrackWithNoCandidatesReturnsNil() async {
        let qq = Track.platform(
            source: .qqmusic, songKey: "004Z8Ijz0wKx4A", name: "晴天",
            artistNames: ["周杰伦"], albumName: "叶惠美", albumPicURL: nil,
            durationMS: 269_000)
        let match = await UnblockService.matchedNetEaseTrack(for: qq, search: { _ in
            MusicAPI.SearchResult(
                songs: [], albums: nil, artists: nil, playlists: nil,
                songCount: 0, albumCount: nil, artistCount: nil, playlistCount: nil)
        })
        #expect(match == nil)
    }

    /// A candidate 30s off is outside the 5s duration tolerance:
    /// it must not match, or the wrong song's lyrics would load.
    @Test func platformTrackWithWrongDurationReturnsNil() async {
        let kugou = Track.platform(
            source: .kugou, songKey: "A1B2C3D4E5F60718293A4B5C6D7E8F90",
            name: "晴天", artistNames: ["周杰伦"], albumName: "叶惠美",
            albumPicURL: nil, durationMS: 269_000)
        let match = await UnblockService.matchedNetEaseTrack(
            for: kugou,
            search: stubSearch(matching: kugou, netEaseID: 186016, candidateDurationMS: 299_000))
        #expect(match == nil)
    }

    /// Stub "search" returning a single NetEase candidate with the
    /// platform track's title/artist and a duration within tolerance
    /// (unless overridden), under the given NetEase id.
    private func stubSearch(
        matching track: Track, netEaseID: Int, candidateDurationMS: Int? = nil
    ) -> (String) async throws -> MusicAPI.SearchResult {
        { _ in
            let candidate = Track(
                id: netEaseID, name: track.name,
                artists: track.artists, album: track.album,
                durationMS: candidateDurationMS ?? track.durationMS,
                alias: [], transNames: [], fee: 0, mvID: 0, trackNo: 0,
                disc: nil, noCopyright: false, isCloud: false,
                embeddedPrivilege: nil)
            return MusicAPI.SearchResult(
                songs: [candidate], albums: nil, artists: nil, playlists: nil,
                songCount: 1, albumCount: nil, artistCount: nil, playlistCount: nil)
        }
    }
}
