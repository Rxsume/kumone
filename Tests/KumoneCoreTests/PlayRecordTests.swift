import Foundation
import Testing
@testable import KumoneCore

/// Fixture tests for the `/v1/play/record` ranking response (no network):
/// the week/all split, the tolerant record decoding, and the client-side
/// artist ranking derived from the song records.
@Suite("Play Record Tests")
struct PlayRecordTests {
    @Test func decodesWeekAndAllData() throws {
        let response = try JSONDecoder().decode(
            MusicAPI.PlayRecordResponse.self,
            from: Data(playRecordJSON.utf8)
        )

        #expect(response.weekData?.count == 2)
        #expect(response.allData?.count == 1)
        let first = try #require(response.weekData?.first)
        #expect(first.playCount == 42)
        #expect(first.score == 100)
        #expect(first.song.id == 186016)
        #expect(first.song.name == "晴天")
        #expect(first.song.artistNames == "周杰伦")
    }

    @Test func missingListDecodesAsNil() throws {
        let response = try JSONDecoder().decode(
            MusicAPI.PlayRecordResponse.self,
            from: Data("{\"allData\":[]}".utf8)
        )

        #expect(response.weekData == nil)
        #expect(response.allData?.isEmpty == true)
    }

    @Test func missingPlayCountDefaultsToZero() throws {
        let item = try JSONDecoder().decode(
            PlayRecordItem.self,
            from: Data("""
            {"score": 5, "song": {"id": 7, "name": "Song", "ar": [], "al": {"id": 1, "name": "Album"}, "dt": 1000}}
            """.utf8)
        )

        #expect(item.playCount == 0)
        #expect(item.score == 5)
    }

    @Test func artistRankingSumsAcrossRecords() throws {
        let response = try JSONDecoder().decode(
            MusicAPI.PlayRecordResponse.self,
            from: Data(playRecordJSON.utf8)
        )
        let ranking = RankingAggregation.artistRanking(from: response.weekData ?? [])

        #expect(ranking.count == 2)
        #expect(ranking[0].name == "周杰伦")
        #expect(ranking[0].playCount == 42 + 3)
        #expect(ranking[0].tracks.count == 2)
        #expect(ranking[1].name == "林俊杰")
        #expect(ranking[1].playCount == 3)
    }

    @Test func multiArtistTrackCreditsEachArtist() throws {
        let records = try JSONDecoder().decode(
            MusicAPI.PlayRecordResponse.self,
            from: Data("""
            {"weekData": [{"playCount": 10, "score": 1, "song": {"id": 9, "name": "Duet",
            "ar": [{"id": 1, "name": "A"}, {"id": 2, "name": "B"}],
            "al": {"id": 1, "name": "Album"}, "dt": 1000}}]}
            """.utf8)
        ).weekData ?? []
        let ranking = RankingAggregation.artistRanking(from: records)

        #expect(ranking.count == 2)
        #expect(ranking.map(\.playCount) == [10, 10])
    }

    /// Shape of a real `/v1/play/record` body: `type=1` fills `weekData`,
    /// `type=0` fills `allData`.
    private var playRecordJSON: String {
        """
        {"weekData": [
          {"playCount": 42, "score": 100, "song": {"id": 186016, "name": "晴天",
           "ar": [{"id": 6452, "name": "周杰伦"}], "al": {"id": 18878, "name": "叶惠美"}, "dt": 269000}},
          {"playCount": 3, "score": 12, "song": {"id": 123456, "name": "江南",
           "ar": [{"id": 6452, "name": "周杰伦"}, {"id": 3685, "name": "林俊杰"}],
           "al": {"id": 2, "name": "第二天堂"}, "dt": 240000}}
        ], "allData": [
          {"playCount": 500, "score": 900, "song": {"id": 186016, "name": "晴天",
           "ar": [{"id": 6452, "name": "周杰伦"}], "al": {"id": 18878, "name": "叶惠美"}, "dt": 269000}}
        ]}
        """
    }
}
