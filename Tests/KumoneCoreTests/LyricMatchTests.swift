import Foundation
import Testing
@testable import KumoneCore

/// Unit tests for the restored multi-source lyric match scoring
/// (Folia `matchScore.ts`, ported in PR #23 and restored here).
/// `LyricMatch.evaluate` is pure — no network — so these pin the
/// accept/reject boundary the providers depend on: an accepted hit
/// is fetched, a rejected one is never shown.
@Suite("Lyric match scoring (multi-source lyrics)")
struct LyricMatchTests {
    private func track(
        name: String = "晴天",
        artist: String = "周杰伦",
        album: String = "叶惠美",
        durationMS: Int = 269_000
    ) -> Track {
        Track.platform(
            source: .qqmusic, songKey: "004Z8Ijz0wKx4A", name: name,
            artistNames: [artist], albumName: album, albumPicURL: nil,
            durationMS: durationMS)
    }

    /// Identical title/artist/album and a 1s duration gap: full marks.
    @Test func exactMatchIsAcceptedWithFullScore() {
        let (score, accepted) = LyricMatch.evaluate(
            title: "晴天", artist: "周杰伦", album: "叶惠美",
            duration: 269, track: track())
        #expect(accepted)
        #expect(score == 100)
    }

    /// A different title can never be accepted, however good the rest is.
    @Test func wrongTitleIsRejected() {
        let (_, accepted) = LyricMatch.evaluate(
            title: "月亮", artist: "周杰伦", album: "叶惠美",
            duration: 269, track: track())
        #expect(!accepted)
    }

    /// 30s off kills the score through the duration multiplier (0.1):
    /// the wrong song's lyrics must never load.
    @Test func farOffDurationIsRejected() {
        let (score, accepted) = LyricMatch.evaluate(
            title: "晴天", artist: "周杰伦", album: "叶惠美",
            duration: 299, track: track())
        #expect(!accepted)
        #expect(score < 75)
    }

    /// No album on either side still accepts on title + artist alone.
    @Test func matchWithoutAlbumIsAccepted() {
        let (_, accepted) = LyricMatch.evaluate(
            title: "晴天", artist: "周杰伦", album: nil,
            duration: 269, track: track(album: ""))
        #expect(accepted)
    }
}
