import Testing
@testable import KumoneCore
import Foundation

// Folia macOS playback settings (B4/B5/B6): the transition-mode /
// longest-fade / ReplayGain-mode wiring. Planner-level behaviour plus the
// pure mappings in `PlayerService` and the album-group helpers in
// `LoudnessCompensation`. The player itself (deck loads, pre-renders) is not
// driven here.

@Suite struct FoliaMacPlaybackSettingsTests {

    // MARK: - Fixtures

    /// Shared default timbre fingerprint, copied from
    /// `TransitionPlannerTests`: a zero-sum, unit-norm 40-band spectral shape,
    /// so fixtures compare as identical unless a test overrides one side.
    private static let defaultProfile: [Float] = unit((0..<40).map { Float($0) })

    private static func unit(_ v: [Float]) -> [Float] {
        let mean = v.reduce(0, +) / Float(v.count)
        let centered = v.map { $0 - mean }
        let norm = centered.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return centered.map { $0 / norm }
    }

    private func makeAnalysis(
        bpm: Double = 120,
        confidence: Double = 0.9,
        duration: TimeInterval = 200,
        rmsEnvelope: [Float]? = nil,
        referenceLoudness: Double? = nil,
        peakDBFS: Double? = -6
    ) -> TrackAnalysis {
        let barLength = 4 * 60 / bpm
        let downbeats = stride(from: 0.4, to: duration, by: barLength).map { $0 }
        let beats = stride(from: 0.4, to: duration, by: 60 / bpm).map { $0 }
        return TrackAnalysis(
            version: TrackAnalysis.currentVersion,
            bpm: bpm,
            bpmConfidence: confidence,
            beats: beats,
            downbeats: downbeats,
            phraseBoundaries: [150, 90, 30],
            rmsEnvelope: rmsEnvelope ?? [Float](repeating: 0.5, count: Int(duration)),
            outroFadeStart: nil,
            introEnd: 2,
            duration: duration,
            melProfile: Self.defaultProfile,
            keyPitchClass: nil, keyIsMinor: false,
            keyConfidence: 0,
            vocalActivity: [],
            referenceLoudness: referenceLoudness,
            peakDBFS: peakDBFS)
    }

    /// A beat-matchable pair under the standard config: 120 → 124 BPM, steady
    /// energy, identical timbre. (Pinned by `TransitionPlannerTests`.)
    private func beatMatchablePair() -> (TrackAnalysis, TrackAnalysis) {
        (makeAnalysis(bpm: 120), makeAnalysis(bpm: 124))
    }

    // MARK: - B4: transition mode

    @Test func standardConfigDefaultsToAutomix() {
        #expect(TransitionPlanner.Config.standard.handoverMode == .automix)
    }

    @Test func automixModeKeepsBeatMatchOnBeatMatchablePair() {
        let (outgoing, incoming) = beatMatchablePair()
        var config = TransitionPlanner.Config.standard
        config.handoverMode = .automix
        let planned = TransitionPlanner.plan(
            outgoing: outgoing, incoming: incoming, config: config)
        guard case .beatMatched = planned.plan else {
            Issue.record("expected beatMatched in automix mode, got \(planned.plan)")
            return
        }
    }

    @Test func crossfadeModeForcesCrossfadeOnBeatMatchablePair() {
        let (outgoing, incoming) = beatMatchablePair()
        var config = TransitionPlanner.Config.standard
        config.handoverMode = .crossfade
        let planned = TransitionPlanner.plan(
            outgoing: outgoing, incoming: incoming, config: config)
        guard case .crossfade = planned.plan else {
            Issue.record("expected crossfade in crossfade mode, got \(planned.plan)")
            return
        }
    }

    // MARK: - B5: longest fade

    @Test func crossfadeModeCapsOverlapAtConfiguredMax() {
        let (outgoing, incoming) = beatMatchablePair()
        // Uncapped, this pair's crossfade is 8 s (intake capacity: flat
        // opening, 0 s climb + 8 s body). A 5 s cap must shrink it to 5 s.
        var capped = TransitionPlanner.Config.standard
        capped.handoverMode = .crossfade
        capped.maxOverlap = 5
        let planned = TransitionPlanner.plan(
            outgoing: outgoing, incoming: incoming, config: capped)
        guard case .crossfade(let duration, _, _) = planned.plan else {
            Issue.record("expected crossfade, got \(planned.plan)")
            return
        }
        #expect(duration == 5)

        var uncapped = TransitionPlanner.Config.standard
        uncapped.handoverMode = .crossfade
        let plain = TransitionPlanner.plan(
            outgoing: outgoing, incoming: incoming, config: uncapped)
        guard case .crossfade(let fullDuration, _, _) = plain.plan else {
            Issue.record("expected crossfade, got \(plain.plan)")
            return
        }
        #expect(fullDuration == 8)
    }

    @Test func transitionPlannerConfigMapsModeAndCap() {
        let automix = PlayerService.transitionPlannerConfig(
            mode: .automix, crossfadeMaxSeconds: 8)
        #expect(automix.handoverMode == .automix)
        #expect(automix.maxOverlap == 30)

        let crossfade = PlayerService.transitionPlannerConfig(
            mode: .crossfade, crossfadeMaxSeconds: 8)
        #expect(crossfade.handoverMode == .crossfade)
        #expect(crossfade.maxOverlap == 8)

        // Out-of-range user value never lifts the planner's own 30 s ceiling.
        let wide = PlayerService.transitionPlannerConfig(
            mode: .crossfade, crossfadeMaxSeconds: 20)
        #expect(wide.maxOverlap == 30)

        let narrow = PlayerService.transitionPlannerConfig(
            mode: .crossfade, crossfadeMaxSeconds: 2)
        #expect(narrow.maxOverlap == 2)
    }

    // MARK: - B6: ReplayGain mode

    @Test func effectiveLoudnessCompensationMatrix() {
        #expect(PlayerService.effectiveLoudnessCompensation(
            master: true, toggle: true, replayGainMode: .auto))
        #expect(PlayerService.effectiveLoudnessCompensation(
            master: true, toggle: true, replayGainMode: .track))
        #expect(PlayerService.effectiveLoudnessCompensation(
            master: true, toggle: true, replayGainMode: .album))
        #expect(!PlayerService.effectiveLoudnessCompensation(
            master: true, toggle: true, replayGainMode: .off))
        #expect(!PlayerService.effectiveLoudnessCompensation(
            master: false, toggle: true, replayGainMode: .auto))
        #expect(!PlayerService.effectiveLoudnessCompensation(
            master: true, toggle: false, replayGainMode: .auto))
    }

    @Test func meanReferenceLoudnessAveragesFiniteValues() {
        let loud = makeAnalysis(referenceLoudness: -9)
        let quiet = makeAnalysis(referenceLoudness: -11)
        let silent = makeAnalysis(referenceLoudness: nil)
        #expect(LoudnessCompensation.meanReferenceLoudness([loud, quiet]) == -10)
        #expect(LoudnessCompensation.meanReferenceLoudness([silent, loud]) == -9)
        #expect(LoudnessCompensation.meanReferenceLoudness([silent, nil]) == nil)
        #expect(LoudnessCompensation.meanReferenceLoudness([]) == nil)
    }

    @Test func trimDBUsesAlbumMeanWhenSupplied() {
        // House level −14 LUFS (standard config): own −9 LUFS trims −5 dB;
        // the album mean −12 LUFS trims the same track only −2 dB.
        let track = makeAnalysis(referenceLoudness: -9, peakDBFS: -6)
        #expect(LoudnessCompensation.trimDB(for: track) == -5)
        #expect(LoudnessCompensation.trimDB(for: track, referenceLoudness: -12) == -2)
        // No override is the shipped behaviour, byte for byte.
        #expect(LoudnessCompensation.trimDB(for: track, referenceLoudness: nil) == -5)
        // Off still means unity, override or not.
        #expect(LoudnessCompensation.trimDB(
            for: track, enabled: false, referenceLoudness: -12) == 0)
    }

    @Test func albumGroupReferenceLoudnessNeedsSameNonEmptyAlbum() {
        let loud = makeAnalysis(referenceLoudness: -9)
        let quiet = makeAnalysis(referenceLoudness: -11)
        #expect(PlayerService.albumGroupReferenceLoudness(
            outgoing: loud, outgoingAlbumID: 42,
            incoming: quiet, incomingAlbumID: 42) == -10)
        #expect(PlayerService.albumGroupReferenceLoudness(
            outgoing: loud, outgoingAlbumID: 42,
            incoming: quiet, incomingAlbumID: 43) == nil)
        #expect(PlayerService.albumGroupReferenceLoudness(
            outgoing: loud, outgoingAlbumID: 0,
            incoming: quiet, incomingAlbumID: 0) == nil)
        // A group of one degrades to that track's own value.
        #expect(PlayerService.albumGroupReferenceLoudness(
            outgoing: nil, outgoingAlbumID: 42,
            incoming: quiet, incomingAlbumID: 42) == -11)
    }
}
