import Testing
@testable import KumoneCore
import Foundation

/// Hot search parsing (NetEase `/search/hot/detail` + QQ
/// `gethotkey.fcg`) and the two-platform merge, all from fixtures —
/// no networking.
@Suite("Hot search")
struct HotSearchTests {

    /// Real `/search/hot/detail` shape (NeteaseCloudMusicApi):
    /// `data` is an array of items carrying `searchWord`.
    private static let netEaseFixture = """
        {"code":200,"data":[
          {"searchWord":"周杰伦","score":123456,"content":"周杰伦","source":1,"iconType":0,"iconUrl":null,"url":"","alg":"featured"},
          {"searchWord":"晴天","score":99999,"content":"晴天","source":1,"iconType":0,"iconUrl":null,"url":"","alg":"featured"},
          {"searchWord":"  ","score":1,"content":"","source":1,"iconType":0,"iconUrl":null,"url":"","alg":""},
          {"searchWord":"周杰伦","score":1,"content":"","source":1,"iconType":0,"iconUrl":null,"url":"","alg":""}
        ]}
        """

    @Test func parsesNetEaseHotSearchDetail() {
        let terms = MusicAPI.parseHotSearchTerms(from: Data(Self.netEaseFixture.utf8))
        #expect(terms == ["周杰伦", "晴天"])
    }

    @Test func capsNetEaseTermsAtLimit() {
        let terms = MusicAPI.parseHotSearchTerms(from: Data(Self.netEaseFixture.utf8), limit: 1)
        #expect(terms == ["周杰伦"])
    }

    @Test func malformedNetEasePayloadYieldsEmpty() {
        #expect(MusicAPI.parseHotSearchTerms(from: Data("not json".utf8)).isEmpty)
        #expect(MusicAPI.parseHotSearchTerms(from: Data("{\"code\":200}".utf8)).isEmpty)
        #expect(MusicAPI.parseHotSearchTerms(from: Data("{\"code\":200,\"data\":[]}".utf8)).isEmpty)
    }

    /// Real `gethotkey.fcg` shape, verified live 2026-11-10:
    /// `data.hotkey[].k` (with trailing spaces) and `n`.
    @Test func parsesQQHotKeys() {
        let json: [String: Any] = [
            "code": 0,
            "data": ["hotkey": [
                ["k": "我们的歌 ", "n": 765562],
                ["k": "张杰 ", "n": 323823],
                ["k": "张杰 ", "n": 1],
                ["k": "", "n": 0],
            ]],
        ]
        #expect(QQMusicAPI.parseHotKeys(json) == ["我们的歌", "张杰"])
    }

    @Test func capsQQHotKeysAtLimit() {
        let json: [String: Any] = [
            "code": 0,
            "data": ["hotkey": [
                ["k": "a", "n": 3],
                ["k": "b", "n": 2],
                ["k": "c", "n": 1],
            ]],
        ]
        #expect(QQMusicAPI.parseHotKeys(json, limit: 2) == ["a", "b"])
    }

    @Test func mergesBothPlatformsInterleavedAndDeduped() {
        let merged = SearchViewModel.mergedHotSearchTerms(
            netEase: ["周杰伦", "晴天", "稻香"],
            qq: ["张杰", "周杰伦", "我们的歌"],
            limit: 10)
        #expect(merged == ["周杰伦", "张杰", "晴天", "稻香", "我们的歌"])
    }

    @Test func mergeCapsAtLimit() {
        let merged = SearchViewModel.mergedHotSearchTerms(
            netEase: ["a", "b", "c"], qq: ["d", "e", "f"], limit: 4)
        #expect(merged == ["a", "d", "b", "e"])
    }

    @Test func mergeToleratesAnEmptySide() {
        #expect(SearchViewModel.mergedHotSearchTerms(netEase: [], qq: ["a"], limit: 10) == ["a"])
        #expect(SearchViewModel.mergedHotSearchTerms(netEase: ["a"], qq: [], limit: 10) == ["a"])
        #expect(SearchViewModel.mergedHotSearchTerms(netEase: [], qq: [], limit: 10).isEmpty)
    }
}
