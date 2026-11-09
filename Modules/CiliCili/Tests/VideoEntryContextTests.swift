import XCTest
@testable import CiliCiliKit

@MainActor
final class VideoEntryContextTests: XCTestCase {
    private func video(_ bvid: String, title: String? = nil) -> VideoItem {
        VideoItem(bvid: bvid, aid: nil, title: title ?? bvid, pic: nil, desc: nil,
                  duration: 60, pubdate: nil, owner: nil, stat: nil, cid: nil, pages: nil, dimension: nil)
    }

    func testSnapshotPreservesOrderAndEnrichesCurrentDetail() {
        let context = VideoEntryContext(title: "搜索结果", videos: [video("BVfirst"), video("BVmiddle"), video("BVlast")])
        let anchor = video("BVmiddle", title: "Resolved")
        var session = VideoListenQueueSession(seedVideo: anchor)
        session.installEntryContext(context, anchor: anchor)
        XCTAssertEqual(session.source, .entryList(title: "搜索结果"))
        XCTAssertEqual(session.videos.map(\.bvid), ["BVfirst", "BVmiddle", "BVlast"])
        XCTAssertEqual(session.videos[1].title, "Resolved")
        XCTAssertEqual(session.video(relativeTo: anchor, direction: .previous)?.bvid, "BVfirst")
        XCTAssertEqual(session.video(relativeTo: anchor, direction: .next)?.bvid, "BVlast")
        XCTAssertFalse(session.hasMore)
    }

    func testSnapshotsAreIndependentAndMissingAnchorIsInserted() {
        var videos = [video("BVother")]
        let context = VideoEntryContext(title: "投稿", videos: videos)
        videos.append(video("BVlater"))
        let anchor = video("BVcurrent")
        var session = VideoListenQueueSession(seedVideo: anchor)
        session.installEntryContext(context, anchor: anchor)
        XCTAssertEqual(session.videos.map(\.bvid), ["BVcurrent", "BVother"])
        XCTAssertEqual(context.videos.count, 1)
    }

    func testDuplicateVideoDoesNotDuplicateQueue() {
        let anchor = video("BVone")
        var session = VideoListenQueueSession(seedVideo: anchor)
        session.installEntryContext(VideoEntryContext(title: "合集", videos: [anchor, video("BVtwo"), anchor]), anchor: anchor)
        XCTAssertEqual(session.videos.map(\.bvid), ["BVone", "BVtwo"])
    }
}
