import Testing
@testable import KumoneCore
import Foundation

/// Pure-logic coverage for the Folia playback settings wired into
/// `PlayerServiceIOS` (C1 fade ramp, C2 append-to-end, B7 auto-skip
/// decision, B8 entry view). The helpers under test live outside the
/// `#if os(iOS)` gate in `PlayerServiceIOS.swift` on purpose, so this file
/// runs in the macOS `swift test` job; the AVPlayer / UIKit behaviour they
/// feed is verified by CI build + device testing instead.
@Suite struct FoliaPlaybackSettingsTests {

    private func makeTracks(_ ids: [Int]) throws -> [Track] {
        try JSONDecoder().decode([Track].self, from: JSONSerialization.data(withJSONObject:
            ids.map { ["id": $0, "name": "Track \($0)"] }))
    }

    // MARK: - C1 fade ramp

    @Test func fadeInRampEndsAtTargetAndRisesMonotonically() {
        let ramp = PlaybackFade.volumes(from: 0, to: 0.8, steps: 20)
        #expect(ramp.count == 20)
        #expect(abs((ramp.last ?? -1) - 0.8) < 0.0001)
        #expect((ramp.first ?? -1) > 0)
        #expect(zip(ramp, ramp.dropFirst()).allSatisfy { $0 <= $1 + 0.0001 })
    }

    @Test func fadeOutRampEndsAtSilenceAndFallsMonotonically() {
        let ramp = PlaybackFade.volumes(from: 0.8, to: 0, steps: 20)
        #expect(ramp.count == 20)
        #expect(abs(ramp.last ?? -1) < 0.0001)
        #expect(zip(ramp, ramp.dropFirst()).allSatisfy { $0 >= $1 - 0.0001 })
    }

    @Test func fadeRampWithOneStepJumpsStraightToTarget() {
        let oneStep = PlaybackFade.volumes(from: 0.2, to: 0.9, steps: 1)
        #expect(oneStep.count == 1)
        #expect(abs((oneStep.first ?? 0) - 0.9) < 0.0001)
        // A degenerate step count still lands exactly on the target.
        let ramp = PlaybackFade.volumes(from: 0.2, to: 0.9, steps: 0)
        #expect(ramp.count == 1)
        #expect(abs((ramp.first ?? 0) - 0.9) < 0.0001)
    }

    @Test func fadeRampDurationIsInsideThePlannedWindow() {
        // 20 steps x 20 ms = 0.4 s, inside the 0.3–0.5 s window.
        let totalMS = PlaybackFade.defaultSteps * PlaybackFade.stepIntervalMilliseconds
        #expect(totalMS >= 300)
        #expect(totalMS <= 500)
    }

    // MARK: - C2 append to end

    @Test func appendAddsToQueueEndWhenShuffleIsOff() throws {
        let tracks = try makeTracks([1, 2, 3])
        let extra = try makeTracks([4])[0]
        let result = QueueAppend.appended(queue: tracks, shuffledQueue: [], shuffleEnabled: false, track: extra)
        #expect(result.queue.map(\.id) == [1, 2, 3, 4])
        #expect(result.shuffledQueue.isEmpty)
    }

    @Test func appendKeepsShuffleViewConsistentWhenShuffleIsOn() throws {
        let tracks = try makeTracks([1, 2, 3])
        let shuffled = try makeTracks([2, 3, 1])
        let extra = try makeTracks([4])[0]
        let result = QueueAppend.appended(queue: tracks, shuffledQueue: shuffled, shuffleEnabled: true, track: extra)
        #expect(result.queue.map(\.id) == [1, 2, 3, 4])
        #expect(result.shuffledQueue.map(\.id) == [2, 3, 1, 4])
        #expect(result.queue.count == result.shuffledQueue.count)
    }

    @Test func appendKeepsStaleShuffledOrderInStepWhenShuffleIsOff() throws {
        // Shuffle was on, then off: the stale shuffled order still exists
        // and must not lose the appended track when shuffle comes back.
        let tracks = try makeTracks([1, 2, 3])
        let shuffled = try makeTracks([3, 1, 2])
        let extra = try makeTracks([4])[0]
        let result = QueueAppend.appended(queue: tracks, shuffledQueue: shuffled, shuffleEnabled: false, track: extra)
        #expect(result.queue.map(\.id) == [1, 2, 3, 4])
        #expect(result.shuffledQueue.map(\.id) == [3, 1, 2, 4])
    }

    // MARK: - B7 auto-skip decision

    @Test func autoSkipOnlyForMetadataRuledOutTracks() {
        for playability in [TrackPlayability.vipOnly, .paidAlbum, .noCopyright, .delisted] as [TrackPlayability] {
            #expect(UnplayableSkip.shouldAutoSkip(playability: playability, autoSkipEnabled: true))
        }
        // Reads as playable but failed to resolve: transient (most often
        // the network) — never auto-skipped.
        #expect(!UnplayableSkip.shouldAutoSkip(playability: .playable, autoSkipEnabled: true))
    }

    @Test func autoSkipOffNeverSkips() {
        for playability in [TrackPlayability.playable, .vipOnly, .paidAlbum, .noCopyright, .delisted] as [TrackPlayability] {
            #expect(!UnplayableSkip.shouldAutoSkip(playability: playability, autoSkipEnabled: false))
        }
    }

    // MARK: - B8 entry view

    @Test func entryViewDecidesWhetherToOpenNowPlaying() {
        #expect(PlaybackEntry.shouldOpenNowPlaying(for: .nowPlaying))
        #expect(!PlaybackEntry.shouldOpenNowPlaying(for: .stay))
    }
}
