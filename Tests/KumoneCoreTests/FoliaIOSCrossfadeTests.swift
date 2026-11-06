import Testing
@testable import KumoneCore
import Foundation

// Folia §3.3 task 2: the iOS dual-deck crossfade engine's pure helpers —
// the equal-power ramp, the timed plan, and the settings → planner-config
// mapping. The deck surgery itself is proven by CI's xcodebuild (iOS) and
// by device testing, not by this macOS test run.

@Suite struct FoliaIOSCrossfadeTests {

    // MARK: - Equal-power gains

    @Test func equalPowerGainsEndpoints() {
        let start = CrossfadeTransition.equalPowerGains(at: 0)
        #expect(start.outGain == 1)
        #expect(start.inGain == 0)
        let end = CrossfadeTransition.equalPowerGains(at: 1)
        #expect(end.outGain == 0)
        #expect(end.inGain == 1)
    }

    @Test func equalPowerGainsMidpoint() {
        let mid = CrossfadeTransition.equalPowerGains(at: 0.5)
        #expect(abs(mid.outGain - 0.7071) < 0.001)
        #expect(abs(mid.inGain - 0.7071) < 0.001)
    }

    @Test func equalPowerGainsPreservePower() {
        for t in stride(from: 0.0, through: 1.0, by: 0.1) {
            let gains = CrossfadeTransition.equalPowerGains(at: t)
            let power = Double(gains.outGain * gains.outGain + gains.inGain * gains.inGain)
            #expect(abs(power - 1) < 0.001)
        }
    }

    @Test func equalPowerGainsClamp() {
        let before = CrossfadeTransition.equalPowerGains(at: -0.5)
        #expect(before.outGain == 1)
        #expect(before.inGain == 0)
        let after = CrossfadeTransition.equalPowerGains(at: 1.5)
        #expect(after.outGain == 0)
        #expect(after.inGain == 1)
    }

    // MARK: - Timed crossfade

    @Test func timedCrossfadeUsesUserMaximum() {
        let plan = CrossfadeTransition.timedCrossfade(outgoingDuration: 200, incomingDuration: 180, maxSeconds: 8)
        #expect(plan?.duration == 8)
        #expect(plan?.outPoint == 192)
        #expect(plan?.inPoint == 0)
    }

    @Test func timedCrossfadeCapsAtQuarterOfShorterTrack() {
        let plan = CrossfadeTransition.timedCrossfade(outgoingDuration: 100, incomingDuration: 100, maxSeconds: 30)
        #expect(plan?.duration == 25)
        #expect(plan?.outPoint == 75)
    }

    @Test func timedCrossfadeRespectsMaxSeconds() {
        let plan = CrossfadeTransition.timedCrossfade(outgoingDuration: 240, incomingDuration: 240, maxSeconds: 12)
        #expect(plan?.duration == 12)
    }

    @Test func timedCrossfadeRefusesShortTracks() {
        #expect(CrossfadeTransition.timedCrossfade(outgoingDuration: 5, incomingDuration: 5, maxSeconds: 8) == nil)
        #expect(CrossfadeTransition.timedCrossfade(outgoingDuration: 10, incomingDuration: 10, maxSeconds: 8) != nil)
    }

    // MARK: - Planner config mapping

    @Test func plannerConfigCrossfadeCapsOverlap() {
        let config = CrossfadeTransition.plannerConfig(mode: .crossfade, crossfadeMaxSeconds: 8)
        #expect(config.handoverMode == .crossfade)
        #expect(config.maxOverlap == 8)
    }

    @Test func plannerConfigAutomixLeavesStandard() {
        let config = CrossfadeTransition.plannerConfig(mode: .automix, crossfadeMaxSeconds: 8)
        #expect(config.handoverMode == .automix)
        #expect(config.maxOverlap == TransitionPlanner.Config.standard.maxOverlap)
    }
}
