import Testing
@testable import KumoneCore
import Foundation
import AVFoundation

// Folia §3.3 task 1: the pure AutoMix logic that was extracted from the
// macOS-only gate so it compiles on iOS too — `TransitionPlanner` (plan
// choice / duration math), `LoudnessCompensation` (trim math) and
// `QueueOrderScorer` (queue scoring), plus the `TrackAnalyzer` sample path
// they all read from. These tests pin the extracted behaviour; the iOS
// build itself is proven by CI's xcodebuild, not by this macOS test run.

@Suite struct FoliaIOSPureLogicTests {

    // MARK: - Fixtures (same shape as TransitionPlannerTests / QueueOrderTests)

    private static let defaultProfile: [Float] = {
        let v = (0..<40).map { Float($0) }
        let mean = v.reduce(0, +) / Float(v.count)
        let centered = v.map { $0 - mean }
        let norm = centered.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return centered.map { $0 / norm }
    }()

    private func makeAnalysis(
        bpm: Double = 120,
        confidence: Double = 0.9,
        duration: TimeInterval = 200,
        downbeats: [TimeInterval]? = nil,
        phraseBoundaries: [TimeInterval] = [150, 90, 30],
        rmsEnvelope: [Float]? = nil,
        outroFadeStart: TimeInterval? = nil,
        introEnd: TimeInterval = 2,
        melProfile: [Float]? = nil,
        keyPitchClass: Int? = nil,
        keyIsMinor: Bool = false,
        keyConfidence: Double = 0,
        vocalActivity: [Float] = [],
        referenceLoudness: Double? = nil,
        peakDBFS: Double? = -6
    ) -> TrackAnalysis {
        let barLength = 4 * 60 / bpm
        let db = downbeats ?? stride(from: 0.4, to: duration, by: barLength).map { $0 }
        let beats = stride(from: 0.4, to: duration, by: 60 / bpm).map { $0 }
        return TrackAnalysis(
            version: TrackAnalysis.currentVersion,
            bpm: bpm,
            bpmConfidence: confidence,
            beats: beats,
            downbeats: db,
            phraseBoundaries: phraseBoundaries,
            rmsEnvelope: rmsEnvelope ?? [Float](repeating: 0.5, count: Int(duration)),
            outroFadeStart: outroFadeStart,
            introEnd: introEnd,
            duration: duration,
            melProfile: melProfile ?? Self.defaultProfile,
            keyPitchClass: keyPitchClass, keyIsMinor: keyIsMinor,
            keyConfidence: keyConfidence,
            vocalActivity: vocalActivity,
            referenceLoudness: referenceLoudness,
            peakDBFS: peakDBFS)
    }

    private func planned(_ tier: TransitionTier) -> PlannedTransition {
        switch tier {
        case .gapless:
            return .plain(.gapless)
        case .crossfade:
            return .plain(.crossfade(duration: 6, outPoint: 180, inPoint: 0))
        case .stagedCrossfade:
            return PlannedTransition(
                plan: .crossfade(duration: 6, outPoint: 180, inPoint: 0),
                style: TransitionStyle(outroEffect: .fade, stagedEQ: true))
        case .beatMatched, .rampedBeatMatched:
            var plan = BeatMatchedPlan(
                outPoint: 160, inPoint: 2, overlapBars: 8,
                outgoingRate: 1.01, incomingRate: 0.99,
                bassSwapOffset: 4, overlapDuration: 16)
            if tier == .rampedBeatMatched {
                plan.rampLeadSeconds = 13
                plan.rampReleaseSeconds = 3
            }
            return .plain(.beatMatched(plan))
        }
    }

    private func sine(_ hz: Double, dBFS: Double, seconds: Double,
                      sampleRate sr: Double) -> [Float] {
        let amplitude = pow(10.0, dBFS / 20.0)
        return (0..<Int(seconds * sr)).map {
            Float(amplitude * sin(2 * .pi * hz * Double($0) / sr))
        }
    }

    // MARK: - LoudnessCompensation: trim math

    @Test func loudMasterIsCutToTarget() {
        let analysis = makeAnalysis(referenceLoudness: -8, peakDBFS: -6)
        // Target −14 LUFS, master at −8: trim −6 dB, inside the −12 dB cut cap.
        #expect(LoudnessCompensation.trimDB(for: analysis) == -6)
    }

    @Test func quietMasterBoostIsCappedByPeakHeadroom() {
        let analysis = makeAnalysis(referenceLoudness: -20, peakDBFS: -6)
        // Wanted +6 dB, capped at +3 dB by maxBoostDB, then held to the peak
        // ceiling: −1 − (−6 + 3) = 2 dB of headroom.
        #expect(LoudnessCompensation.trimDB(for: analysis) == 2)
    }

    @Test func hotPeakBlocksAnyBoost() {
        let analysis = makeAnalysis(referenceLoudness: -20, peakDBFS: -0.5)
        // Peak + 3 dB allowance sits above the −1 dBFS ceiling already.
        #expect(LoudnessCompensation.trimDB(for: analysis) == 0)
    }

    @Test func trimIsZeroWithoutAnalysisOrWhenOff() {
        #expect(LoudnessCompensation.trimDB(for: nil) == 0)
        #expect(LoudnessCompensation.trimDB(for: makeAnalysis(referenceLoudness: -8),
                                            enabled: false) == 0)
        #expect(LoudnessCompensation.trimDB(
            for: makeAnalysis(referenceLoudness: .nan)) == 0)
    }

    @Test func albumModeTrimsAgainstTheGroupMean() {
        let a = makeAnalysis(referenceLoudness: -8, peakDBFS: -6)
        let b = makeAnalysis(referenceLoudness: -12, peakDBFS: -6)
        let mean = LoudnessCompensation.meanReferenceLoudness([a, b])
        #expect(mean == -10)
        // Against the album mean (−10) rather than its own (−8).
        #expect(LoudnessCompensation.trimDB(for: a, referenceLoudness: mean) == -4)
        #expect(LoudnessCompensation.meanReferenceLoudness([]) == nil)
        #expect(LoudnessCompensation.meanReferenceLoudness([nil, nil]) == nil)
        #expect(LoudnessCompensation.meanReferenceLoudness(
            [makeAnalysis(referenceLoudness: .nan),
             makeAnalysis(referenceLoudness: -10)]) == -10)
    }

    @Test func retargetedHouseLevelMovesTheTrim() {
        let analysis = makeAnalysis(referenceLoudness: -8, peakDBFS: -6)
        #expect(LoudnessCompensation.trimDB(
            for: analysis, config: .targeting(-11)) == -3)
    }

    @Test func gainConversionAndHeadroomHelpers() {
        #expect(abs(Double(LoudnessCompensation.gain(fromDB: -6)) - 0.5011872336) < 1e-6)
        #expect(LoudnessCompensation.gain(fromDB: 0) == 1)
        let analysis = makeAnalysis(referenceLoudness: -8, peakDBFS: -6)
        // After a −6 dB trim, 8 dB of boost headroom remains under the ceiling.
        #expect(LoudnessCompensation.boostHeadroomDB(for: analysis, afterTrimDB: -6) == 8)
        #expect(LoudnessCompensation.boostHeadroomDB(for: nil, afterTrimDB: 0) == 0)
        // Hot master at unity rate: the 5.5 dB time-pitch pad costs 6 dB.
        #expect(LoudnessCompensation.timePitchPadDB(forPeakDBFS: -0.5, afterTrimDB: 0) == -6)
        // A master limiter downstream retires the pad entirely.
        #expect(LoudnessCompensation.timePitchPadDB(
            forPeakDBFS: -0.5, afterTrimDB: 0, masterLimiterActive: true) == 0)
        #expect(LoudnessCompensation.timePitchPadDB(forPeakDBFS: nil, afterTrimDB: 0) == 0)
        // A cool master absorbs the overshoot on its own and pays nothing.
        #expect(LoudnessCompensation.timePitchPadDB(forPeakDBFS: -12, afterTrimDB: -6) == 0)
    }

    // MARK: - TransitionPlanner: config mapping

    @Test func handoverModeCrossfadeNeverBeatMatches() {
        let outgoing = makeAnalysis(bpm: 120)
        let incoming = makeAnalysis(bpm: 124, introEnd: 2)
        // The pair beat-matches under the shipped config…
        guard case .beatMatched = TransitionPlanner.plan(
            outgoing: outgoing, incoming: incoming).plan else {
            Issue.record("expected beatMatched under .automix")
            return
        }
        // …but the "淡入淡出" mode forces a plain crossfade for the same pair.
        var crossfadeConfig = TransitionPlanner.Config.standard
        crossfadeConfig.handoverMode = .crossfade
        guard case .crossfade = TransitionPlanner.plan(
            outgoing: outgoing, incoming: incoming,
            config: crossfadeConfig).plan else {
            Issue.record("expected crossfade under .crossfade")
            return
        }
        #expect(TransitionPlanner.Config.standard.handoverMode == .automix)
    }

    @Test func crossfadeMaxSecondsCapsTheFade() {
        let outgoing = makeAnalysis(bpm: 120)
        let incoming = makeAnalysis(bpm: 100, introEnd: 3)
        // Standard config: the far-BPM pair falls back to an 8 s crossfade.
        guard case .crossfade(let standardDuration, _, _) = TransitionPlanner.plan(
            outgoing: outgoing, incoming: incoming).plan else {
            Issue.record("expected crossfade")
            return
        }
        #expect(standardDuration == 8)
        // The user's longest fade (B5) arrives as maxOverlap: 6 s caps it.
        var capped = TransitionPlanner.Config.standard
        capped.maxOverlap = 6
        guard case .crossfade(let cappedDuration, _, _) = TransitionPlanner.plan(
            outgoing: outgoing, incoming: incoming, config: capped).plan else {
            Issue.record("expected crossfade")
            return
        }
        #expect(cappedDuration == 6)
    }

    @Test func missingAnalysisOrShortTrackIsGapless() {
        guard case .gapless = TransitionPlanner.plan(
            outgoing: nil, incoming: makeAnalysis()).plan else {
            Issue.record("expected gapless without an outgoing analysis")
            return
        }
        let short = makeAnalysis(duration: 30)
        guard case .gapless = TransitionPlanner.plan(
            outgoing: short, incoming: makeAnalysis()).plan else {
            Issue.record("expected gapless for a sub-45 s track")
            return
        }
    }

    // MARK: - QueueOrderScorer: scoring

    @Test func tierDominatesAndAgingIsUnbounded() {
        let a = makeAnalysis(melProfile: [], keyConfidence: 0)
        let b = makeAnalysis(melProfile: [], keyConfidence: 0)
        let matched = QueueOrderScorer.score(
            outgoing: a, incoming: b, planned: planned(.beatMatched))
        let faded = QueueOrderScorer.score(
            outgoing: a, incoming: b, planned: planned(.crossfade))
        #expect(matched.tier == .beatMatched)
        #expect(faded.tier == .crossfade)
        #expect(matched.total > faded.total)
        // Same pair, same plan: 40 lost rounds add exactly 40 × 0.35.
        let fresh = QueueOrderScorer.score(
            outgoing: a, incoming: b, planned: planned(.crossfade))
        let aged = QueueOrderScorer.score(
            outgoing: a, incoming: b, planned: planned(.crossfade), lostRounds: 40)
        #expect(abs((aged.total - fresh.total) - 14) < 1e-9)
        // …enough to outrank a whole tier, which is the no-starvation rule.
        #expect(aged.total > matched.total)
    }

    @Test func sameArtistCostsOneAndAHalfPoints() {
        let a = makeAnalysis(melProfile: [], keyConfidence: 0)
        let b = makeAnalysis(melProfile: [], keyConfidence: 0)
        let plain = QueueOrderScorer.score(
            outgoing: a, incoming: b, planned: planned(.crossfade))
        let penalized = QueueOrderScorer.score(
            outgoing: a, incoming: b, planned: planned(.crossfade),
            sharesArtist: true)
        #expect(abs((plain.total - penalized.total) - 1.5) < 1e-9)
    }

    @Test func affinityTermsReadThePair() {
        let a = makeAnalysis(bpm: 120, keyPitchClass: 0, keyConfidence: 0.9,
                             melProfile: [1, 0, 0, 0])
        let twin = makeAnalysis(bpm: 120, keyPitchClass: 0, keyConfidence: 0.9,
                                melProfile: [1, 0, 0, 0])
        #expect(QueueOrderScorer.tempoAffinity(a, twin) == 1)
        // Same key at 0.9 confidence: 0.5 + (1 − 0.5) × 0.9.
        #expect(abs(QueueOrderScorer.keyAffinity(a, twin) - 0.95) < 1e-9)
        #expect(QueueOrderScorer.styleAffinity(a, twin) == 1)
        // Flat envelopes on both sides: matched hand-over energy.
        #expect(QueueOrderScorer.energyContinuity(a, twin) == 1)
        // Tier read back off a plan: a ramped plan outranks a stepped one.
        #expect(TransitionTier(planned(.rampedBeatMatched)) == .rampedBeatMatched)
        #expect(TransitionTier(planned(.beatMatched)) == .beatMatched)
        #expect(TransitionTier(planned(.stagedCrossfade)) == .stagedCrossfade)
    }

    // MARK: - TrackAnalyzer: sample + file paths (ungated for iOS)

    @Test func analyzerReadsLoudnessAndPeakFromSamples() throws {
        let sr = TrackAnalyzer.analysisSampleRate
        let samples = sine(440, dBFS: -14, seconds: 10, sampleRate: sr)
        let analysis = try TrackAnalyzer.analyze(samples: samples, sampleRate: sr)
        #expect(abs(analysis.duration - 10) < 0.5)
        let loudness = try #require(analysis.referenceLoudness)
        #expect(abs(loudness - (-14)) < 1.5)
        let peak = try #require(analysis.peakDBFS)
        #expect(abs(peak - (-14)) < 1)
    }

    @Test func analyzerEarlyPathHasNoOpinionOnVeryShortInput() throws {
        let sr = TrackAnalyzer.analysisSampleRate
        let samples = sine(440, dBFS: -14, seconds: 0.1, sampleRate: sr)
        let analysis = try TrackAnalyzer.analyze(samples: samples, sampleRate: sr)
        #expect(analysis.bpm == 0)
        #expect(analysis.beats.isEmpty)
        #expect(analysis.referenceLoudness == nil)
    }

    @Test func analyzerDecodesAFile() throws {
        // The path iOS uses: a local audio file → AVAudioFile decode →
        // the same sample analysis. Writes a 5 s mono WAV, then analyzes it.
        let sr = TrackAnalyzer.analysisSampleRate
        let samples = sine(440, dBFS: -14, seconds: 5, sampleRate: sr)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("folia-ios-analyzer-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!,
                                               count: samples.count)
        }
        try file.write(from: buffer)
        let analysis = try TrackAnalyzer.analyze(fileAt: url)
        #expect(abs(analysis.duration - 5) < 0.5)
        let loudness = try #require(analysis.referenceLoudness)
        #expect(abs(loudness - (-14)) < 1.5)
    }
}
