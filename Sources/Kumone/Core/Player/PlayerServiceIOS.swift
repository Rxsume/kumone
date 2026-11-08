import Foundation
#if os(iOS)
import Combine
import AVFoundation
import UIKit

enum RepeatMode: String, CaseIterable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }
}

/// Where the current queue came from — used for scrobbling and UI affordances.
enum PlaySource: Codable, Equatable {
    case playlist(Int)
    case album(Int)
    case artist(Int)
    case daily
    case cloud
    case none

    var sourceID: Int {
        switch self {
        case .playlist(let id), .album(let id), .artist(let id): return id
        default: return 0
        }
    }
}

/// Where playback started from — listed under "Recently Played" in the Dock
/// menu, where picking one reloads it and starts playing again.
///
/// This is deliberately separate from `PlaySource`: heartbeat mode plays out
/// of the liked-songs playlist for scrobbling purposes, but as a *place* it is
/// its own thing, and the recents page has no source at all.
struct PlayContext: Codable, Hashable {
    enum Kind: String, Codable {
        /// Reloaded by id.
        case playlist, album, artist
        /// Fixed per-account entry points, each reloaded from its own API.
        case daily, cloud, recents, heartbeat, fm
    }

    let kind: Kind
    /// Zero for the fixed entry points, which have no id of their own.
    let id: Int
    let name: String

    static func playlist(id: Int, name: String) -> PlayContext {
        .init(kind: .playlist, id: id, name: name)
    }

    static func album(id: Int, name: String) -> PlayContext {
        .init(kind: .album, id: id, name: name)
    }

    static func artist(id: Int, name: String) -> PlayContext {
        .init(kind: .artist, id: id, name: name)
    }

    static var daily: PlayContext { .init(kind: .daily, id: 0, name: String(localized: "每日推荐")) }
    static var cloud: PlayContext { .init(kind: .cloud, id: 0, name: String(localized: "音乐云盘")) }
    static var recents: PlayContext { .init(kind: .recents, id: 0, name: String(localized: "最近播放")) }
    static var heartbeat: PlayContext { .init(kind: .heartbeat, id: 0, name: String(localized: "心动模式")) }
    static var fm: PlayContext { .init(kind: .fm, id: 0, name: String(localized: "私人漫游")) }

    /// Identity is the place, not its current title — a renamed playlist is
    /// still the same entry in the recents list.
    static func == (lhs: PlayContext, rhs: PlayContext) -> Bool {
        lhs.kind == rhs.kind && lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(id)
    }
}

enum RightPanel {
    case lyrics, queue
}

/// The playback engine: queue, shuffle/repeat, personal FM, URL resolution,
/// lyrics, scrobbling. Modeled on YesPlayMusic's Player class, backed by AVPlayer.
/// High-frequency playback position, isolated so per-tick updates only
/// re-render the scrubbers/lyrics that observe it — not every view holding
/// the PlayerService.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var progress: TimeInterval = 0
}

/// Which lyric line is current.
///
/// Every lyric view used to derive this itself, which meant observing the clock
/// and re-rendering on every tick just to discover the line hadn't changed —
/// and for the now-playing page, whose body is the whole immersive layout, that
/// was five full re-evaluations a second. Computing it once here and publishing
/// only on a change turns that into one re-render per lyric line.
@MainActor
final class LyricsCursor: ObservableObject {
    @Published var activeIndex: Int?
}

@MainActor
final class PlayerService: ObservableObject {
    static let shared = PlayerService()

    // MARK: - Observable state

    @Published private(set) var queue: [Track] = []
    @Published private(set) var shuffledQueue: [Track] = []
    @Published private(set) var playNextList: [Track] = []
    @Published private(set) var currentIndex = -1
    @Published private(set) var currentTrack: Track?
    private var playbackAccountID: Int?
    @Published private(set) var source: PlaySource = .none
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var servedQuality: String?
    @Published private(set) var unblockSource: String?
    @Published private(set) var isTrial = false
    let clock = PlaybackClock()
    let lyricsCursor = LyricsCursor()
    let sleepTimer = SleepTimer()
    /// Passthrough to the clock so existing `progress` reads/writes keep working.
    var progress: TimeInterval {
        get { clock.progress }
        set { clock.progress = newValue }
    }
    @Published var repeatMode: RepeatMode = .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "player.repeat") }
    }

    @Published private(set) var shuffleEnabled = false
    @Published var volume: Float = 1 {
        didSet {
            // While an overlap ramp runs, the ramp owns both decks' volumes;
            // a mid-ramp change lands at the next track instead of stomping the fade.
            if transitionTask == nil {
                engine.volume = effectiveVolume
            }
            UserDefaults.standard.set(volume, forKey: "player.volume")
        }
    }

    @Published private(set) var isFMMode = false
    @Published private(set) var fmUpcoming: [Track] = []
    /// Where playback was most recently started from, newest first —
    /// surfaced as "Recently Played" in the Dock menu.
    @Published private(set) var recentContexts: [PlayContext] = []
    @Published private(set) var lyrics: ParsedLyrics?
    @Published var activePanel: RightPanel?
    @Published var showNowPlaying = false

    /// The list the player is walking through (shuffled or ordered).
    var activeQueue: [Track] { shuffleEnabled ? shuffledQueue : queue }

    var upcomingTracks: [Track] {
        guard !activeQueue.isEmpty, currentIndex >= 0 else { return playNextList }
        let rest = activeQueue.suffix(from: min(currentIndex + 1, activeQueue.count))
        return playNextList + Array(rest.prefix(200))
    }

    var hasCurrentTrack: Bool { currentTrack != nil }

    // MARK: - Engine

    /// The two decks. `deckA` starts active; the standby deck preloads the
    /// next track and takes over at the overlap, so playback never stops for
    /// a hand-over. Everything else in this class keeps addressing the active
    /// deck through `engine`, exactly as before.
    private let deckA = AVPlayer()
    private let deckB = AVPlayer()
    private var activeDeckIsA = true
    /// The deck currently driving playback; all existing `engine.xxx` call sites keep working through this.
    private var engine: AVPlayer { activeDeckIsA ? deckA : deckB }
    /// The other deck: preloading the next track, or fading the old one out mid-overlap.
    private var standbyEngine: AVPlayer { activeDeckIsA ? deckB : deckA }

    /// Per-deck observations, installed once in `init` by `wireDeck(_:)`.
    private struct DeckWiring {
        var timeObserver: Any?
        var statusObservation: NSKeyValueObservation?
    }
    private var wiringA = DeckWiring()
    private var wiringB = DeckWiring()

    // iOS crossfade state (Folia P2/P3) — the implementation lives in the
    // section below, after `handleItemEnded`.

    /// The next track's prepared item, living on the standby deck until the overlap starts.
    private var preparedNext: PreparedNext?
    /// The standby item's status observation (ready/failed); separate from the active item's, so a failed preload never touches the playing track.
    private var preparedItemStatusObservation: NSKeyValueObservation?
    /// Prepare work in flight; cancelled whenever the queue or track changes.
    private var prepareTask: Task<Void, Never>?
    /// The queue candidate an in-flight preparation is resolving, so a
    /// manual advance onto exactly that track can wait for it instead of
    /// discarding it and re-resolving from scratch.
    private var preparingCandidate: PlaybackQueueCandidate?
    /// A manual advance that is waiting on an in-flight preparation: the
    /// track it is waiting for. Cleared when the wait resolves or a newer
    /// advance supersedes it, so a stale retry can never stomp a newer track.
    private var deferredAdvanceTrackID: Int?
    /// Bumped whenever a prepared item stops being valid (track change, user action), so stale async prepare work gives up instead of installing.
    private var prepareEpoch = 0
    /// The item the active deck is playing for `currentTrack`, set when it is installed and cleared when a new track starts resolving. The overlap may only start from it — never from a stale item left on the deck while the next track is still resolving.
    private weak var installedItem: AVPlayerItem?
    /// The overlap ramp in flight, if any.
    private var transitionTask: Task<Void, Never>?
    /// The post-overlap glide of the incoming deck back to unity rate (beat-matched plans only).
    private var rateRestoreTask: Task<Void, Never>?
    /// True from the overlap starting until the retiring deck is stopped.
    @Published private(set) var transitionInProgress = false
    /// Resources feeding the retiring deck during an overlap; released when the overlap ends.
    private var retiringResourceLoader: CachingAudioResourceLoader?
    private var retiringCacheLease: UUID?
    private var retiringOfflineLease: OfflinePlaybackLease?

    /// Everything the standby deck holds for the next track until the overlap starts.
    private final class PreparedNext {
        let track: Track
        let candidate: PlaybackQueueCandidate
        let item: AVPlayerItem
        let assetURL: URL
        let resourceLoader: CachingAudioResourceLoader?
        let cacheLease: UUID?
        let offlineLease: OfflinePlaybackLease?
        let durationMS: Int?
        let servedQuality: String?
        let unblockSourceID: AudioSourceID?
        let unblockSourceName: String?
        let isTrial: Bool
        /// Set by the standby item's status observation; the overlap only starts from a ready item.
        var isReady = false

        init(track: Track, candidate: PlaybackQueueCandidate, item: AVPlayerItem, assetURL: URL,
             resourceLoader: CachingAudioResourceLoader? = nil, cacheLease: UUID? = nil,
             offlineLease: OfflinePlaybackLease? = nil, durationMS: Int? = nil,
             servedQuality: String? = nil, unblockSourceID: AudioSourceID? = nil,
             unblockSourceName: String? = nil, isTrial: Bool = false) {
            self.track = track
            self.candidate = candidate
            self.item = item
            self.assetURL = assetURL
            self.resourceLoader = resourceLoader
            self.cacheLease = cacheLease
            self.offlineLease = offlineLease
            self.durationMS = durationMS
            self.servedQuality = servedQuality
            self.unblockSourceID = unblockSourceID
            self.unblockSourceName = unblockSourceName
            self.isTrial = isTrial
        }
    }

    /// One hand-over, decided by `planTransition`: how long the decks overlap, when it starts on the outgoing track, where the incoming deck enters, and what rates the decks run at.
    private struct ActiveTransition {
        let duration: TimeInterval
        let outPoint: TimeInterval
        let inPoint: TimeInterval
        let outgoingRate: Float
        let incomingRate: Float
        let rateReleaseSeconds: TimeInterval
        let isBeatMatched: Bool
    }

    private var lastPlaybackCheckpoint = ContinuousClock.now
    /// The fade ramp in flight, if any; a new play/pause cancels it so ramps
    /// never fight each other (C1).
    private var fadeTask: Task<Void, Never>?

    // MARK: - Loudness compensation (Folia P8, iOS)

    /// In-session analyses for loudness compensation: track ID →
    /// `TrackAnalysis`, filled by a background `TrackAnalyzer` run whenever
    /// a full local file is in hand (audio-cache hit or offline file).
    /// No disk persistence on iOS yet — `AnalysisStore` is still macOS-only
    /// — so this only covers tracks analyzed this session. Streamed tracks
    /// have no local file and are never analyzed.
    private var analysisByTrackID: [Int: TrackAnalysis] = [:]
    /// The trim, in dB, currently applied to `engine.volume` for the loaded
    /// track. 0 until an analysis lands, or while the mode is off.
    private var currentLoudnessTrimDB: Double = 0
    /// Background analysis in flight, if any; superseded when the track changes.
    private var analysisTask: Task<Void, Never>?

    /// The volume the engine actually plays at: the user's volume scaled by
    /// the current track's loudness trim, clamped to the 0...1 range
    /// `AVPlayer.volume` takes. Cuts (the common case for modern masters)
    /// pass through untouched; a boost can only lift the level up to full
    /// scale, never past it.
    private var effectiveVolume: Float {
        min(1, max(0, volume * LoudnessCompensation.gain(fromDB: currentLoudnessTrimDB)))
    }

    /// The loudness trim for `analysis` under the user's ReplayGain mode.
    /// `.off` → 0 (unity). `.auto` trims against the track's own analysis;
    /// `.track` does the same on iOS — there is no ReplayGain-tag reader
    /// here, so it falls back to the analysed value, as on macOS.
    /// `.album` trims against the album-group mean, which on iOS — where
    /// only the current track's analysis is in hand — is that track's own
    /// value, i.e. `.auto` behaviour. House level is `Config.standard`
    /// (−14 LUFS), the same target the macOS player ships with.
    private func loudnessTrimDB(for analysis: TrackAnalysis?) -> Double {
        let mode = SettingsManager.shared.effectiveReplayGainMode
        guard mode != .off else { return 0 }
        let reference = mode == .album
            ? LoudnessCompensation.meanReferenceLoudness([analysis])
            : nil
        return LoudnessCompensation.trimDB(for: analysis, enabled: true,
                                           referenceLoudness: reference)
    }

    /// Re-derive the trim for the loaded track from the in-session analysis
    /// and push it to the engine — unless a C1 fade or an overlap ramp is
    /// running, in which case the ramp owns `engine.volume` until it lands
    /// and the trim is picked up at the next play/pause.
    private func applyLoudnessTrim(for track: Track) {
        currentLoudnessTrimDB = loudnessTrimDB(for: analysisByTrackID[track.id])
        if fadeTask == nil, transitionTask == nil {
            engine.volume = effectiveVolume
        }
    }

    /// Kick off a background analysis of `fileURL` for `track` when the mode
    /// could use it (anything but `.off`) and no analysis is in hand yet.
    /// Only ever runs on a full local file — never on a stream.
    private func analyzeForLoudnessIfNeeded(fileURL: URL, for track: Track) {
        guard SettingsManager.shared.effectiveReplayGainMode != .off,
              analysisByTrackID[track.id] == nil else { return }
        analysisTask?.cancel()
        let trackID = track.id
        analysisTask = Task { @MainActor [weak self] in
            guard let analysis = try? await TrackAnalyzer.analyzeInBackground(fileAt: fileURL)
            else { return }
            guard let self else { return }
            if self.analysisByTrackID.count >= 32,
               let oldest = self.analysisByTrackID.keys.first {
                self.analysisByTrackID.removeValue(forKey: oldest)
            }
            self.analysisByTrackID[trackID] = analysis
            // Only retune the live gain if this is still the track playing.
            if self.currentTrack?.id == trackID {
                self.applyLoudnessTrim(for: track)
            }
        }
    }

    /// Live playback position straight from the player, for smooth per-frame
    /// karaoke highlighting (the published `progress` is intentionally coarse).
    var livePlaybackTime: TimeInterval {
        let t = engine.currentTime().seconds
        return t.isFinite ? t : progress
    }
    private var endObserver: NSObjectProtocol?
    private var audioResourceLoader: CachingAudioResourceLoader?
    private var pendingAudioResourceLoader: CachingAudioResourceLoader?
    private var audioCacheLease: UUID?
    private var itemStatusObservation: NSKeyValueObservation?
    private var resolveGeneration = 0
    private var consecutiveFailures = 0
    private var attemptedUnblockSources: Set<AudioSourceID> = []
    private var currentUnblockSourceID: AudioSourceID?
    /// The resolve generation that already spent its one reload after a
    /// failed item, so a reload that fails too gives up instead of looping.
    private var itemRetryGeneration: Int?
    /// Set when a failure skips to the next song, so that skip keeps counting
    /// toward the stop after five in a row instead of resetting it.
    private var advancingAfterFailure = false
    private var scrobbled = false
    private var startScrobbled = false

    // MARK: - Offline playback (downloads)

    /// The song that could not play because it is not on this device.
    @Published var offlineIssue: OfflinePlaybackIssue?
    /// Held while the player item reads a downloaded file, so the download
    /// cannot be deleted from under it.
    private var offlinePlaybackLease: OfflinePlaybackLease?
    private var offlineScan: Task<Void, Never>?
    private var offlineScanID = UUID()
    private var networkState = DownloadNetworkState.unknown
    private var networkObservation: AnyCancellable?
    private var offlineActivatedScope: String?
    /// Set by an automatic advance and consumed by `startPlaying`: a song that
    /// turns out to be missing offline is skipped rather than reported.
    private var pendingAutoAdvance = false
    private var currentWasAdvanced = false

    // MARK: - Queue prefetch (song cache)

    /// Fills the cache with the next few songs while the network is free.
    private let queuePrefetcher = QueuePrefetcher()
    private var prefetchObservations: Set<AnyCancellable> = []
    /// Subscriptions for the idle-timer hold (C3); separate from the prefetch
    /// set because they observe playback state, not prefetch inputs.
    private var idleTimerObservations: Set<AnyCancellable> = []
    private var prefetchUpdateScheduled = false

    private enum ResolvedURLLoadResult {
        case loaded
        case superseded
    }

    private init() {
        wiringA = wireDeck(deckA)
        wiringB = wireDeck(deckB)
        deckB.volume = 0
        sleepTimer.onDeadlineReached = { [weak self] in
            self?.pause()
        }
        volume = UserDefaults.standard.object(forKey: "player.volume") as? Float ?? 0.8
        engine.volume = effectiveVolume
        repeatMode = UserDefaults.standard.string(forKey: "player.repeat")
            .flatMap(RepeatMode.init) ?? .off

        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to activate audio session: \(error)")
        }

        // Resume after interruptions (phone calls, WeChat voice messages, …).
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleAudioInterruption(note)
            }
        }
        // Pause when the output route disappears (headphones unplugged).
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue),
                      reason == .oldDeviceUnavailable, self.isPlaying else { return }
                self.pause()
            }
        }
        #endif

        NowPlayingManager.shared.attach(to: self, players: [deckA, deckB])
        offlineActivatedScope = AccountStore.shared.offlineScope
        networkObservation = DownloadManager.shared.$network.removeDuplicates().sink { [weak self] network in
            self?.networkState = network
        }
        // C3 (Folia P13): hold the idle timer off while playing. The
        // $isPlaying sink covers every pause/stop path in one place; the
        // setting sink re-applies when the switch is flipped mid-playback.
        $isPlaying.sink { [weak self] _ in self?.updateIdleTimerDisabled() }.store(in: &idleTimerObservations)
        SettingsManager.shared.$preventDisplaySleepDuringPlayback.sink { [weak self] _ in
            self?.updateIdleTimerDisabled()
        }.store(in: &idleTimerObservations)
        // The idle timer only matters in the foreground: release the hold on
        // backgrounding and re-apply it when coming back.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            UIApplication.shared.isIdleTimerDisabled = false
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateIdleTimerDisabled()
            }
        }
        observePrefetchInputs()
        // The cache keeps its default limit until something writes to it, and
        // trims to that on every release; a cache-only session must not lose
        // songs on the way.
        if SettingsManager.shared.enableAudioCache {
            Task { try? await AudioCache.shared.enforce(maximumSizeMB: await SettingsManager.shared.effectiveAudioCacheSizeMB()) }
        }
        restoreState()
    }

    /// Set while the user drags the seek bar so the time observer doesn't fight the thumb.
    var isScrubbing = false

    #if os(iOS)
    private var wasPlayingBeforeInterruption = false

    private func handleAudioInterruption(_ note: Notification) {
        guard let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying {
                // The system already silenced us; sync our state and UI.
                isPlaying = false
                NowPlayingManager.shared.updateElapsed(progress, rate: 0)
                persistState()
            }
        case .ended:
            let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            guard wasPlayingBeforeInterruption, options.contains(.shouldResume) else { return }
            wasPlayingBeforeInterruption = false
            try? AVAudioSession.sharedInstance().setActive(true)
            engine.play()
            isPlaying = true
            NowPlayingManager.shared.updateElapsed(progress, rate: 1)
        @unknown default:
            break
        }
    }
    #endif

    // MARK: - Entry points

    /// - Parameter context: the place these tracks came from. Supplying it
    ///   lists that place in the Dock menu's recently played section; callers
    ///   playing an ad-hoc selection (search results, a single track) omit it.
    func play(tracks: [Track], source: PlaySource, startAt track: Track? = nil,
              context: PlayContext? = nil) {
        guard !tracks.isEmpty else { return }
        // B8: every caller of this entry point is a user-initiated play (list
        // taps, CarPlay, recents via play(context:)); automatic advances go
        // through startPlaying and never reach here.
        applyPlaybackEntryView()
        if let context { recordRecent(context) }
        isFMMode = false
        queue = tracks
        self.source = source
        playNextList.removeAll()
        let startTrack = track ?? tracks[0]
        if shuffleEnabled {
            reshuffle(keeping: startTrack)
            currentIndex = 0
        } else {
            currentIndex = tracks.firstIndex(where: { $0.id == startTrack.id }) ?? 0
        }
        startPlaying(activeQueue[currentIndex])
    }

    func playTrack(_ track: Track) {
        // B8: same user-initiated entry as play(tracks:) (no in-repo iOS
        // callers today, but the contract is identical).
        applyPlaybackEntryView()
        if let idx = activeQueue.firstIndex(where: { $0.id == track.id }) {
            currentIndex = idx
            startPlaying(track)
        } else {
            play(tracks: [track], source: .none)
        }
    }

    /// Insert a track right after the current one.
    func addToPlayNext(_ track: Track, playNow: Bool = false) {
        playNextList.append(track)
        if playNow || currentTrack == nil {
            advanceToNext(userInitiated: true)
        } else {
            ToastCenter.shared.show(String(localized: "已添加到下一首播放"))
        }
    }

    /// Append a track to the end of the queue (Folia P11 "append" behaviour).
    /// The shuffle view stays consistent: the track lands at the end of the
    /// underlying queue and, when a shuffled order is live, at the end of
    /// that too (see `QueueAppend`). In FM there is no queue to append to,
    /// so this falls back to play-next.
    func addToQueueEnd(_ track: Track, playNow: Bool = false) {
        if isFMMode {
            addToPlayNext(track, playNow: playNow)
            return
        }
        let result = QueueAppend.appended(queue: queue, shuffledQueue: shuffledQueue,
                                          shuffleEnabled: shuffleEnabled, track: track)
        queue = result.queue
        shuffledQueue = result.shuffledQueue
        if playNow || currentTrack == nil {
            currentIndex = activeQueue.count - 1
            startPlaying(track)
        } else {
            ToastCenter.shared.show(String(localized: "已添加到队尾"))
        }
    }

    /// The single entry point for a generic "add to queue" action: routes to
    /// play-next or append-to-end per `settings.effectiveQueueAddBehavior` (default
    /// `.next`, identical to the historical behaviour).
    func addTrack(_ track: Track, playNow: Bool = false) {
        switch SettingsManager.shared.effectiveQueueAddBehavior {
        case .append: addToQueueEnd(track, playNow: playNow)
        case .next: addToPlayNext(track, playNow: playNow)
        }
    }

    /// B8: opens the now-playing page for a user-initiated play, per
    /// `settings.effectivePlaybackEntryView`. Automatic advances (next/previous, FM,
    /// restore, resume) go through `startPlaying`, never here, so they can
    /// never drag the user into the now-playing page.
    private func applyPlaybackEntryView() {
        if PlaybackEntry.shouldOpenNowPlaying(for: SettingsManager.shared.effectivePlaybackEntryView) {
            showNowPlaying = true
        }
    }

    func togglePlayPause() {
        guard let track = currentTrack else { return }
        if isPlaying {
            pause()
            return
        } else if engine.currentItem == nil {
            // Restored session: re-resolve the source. No fade here — the
            // item is not loaded yet, so the ramp would run against silence.
            startPlaying(track, resumeAt: progress)
            return
        } else if SettingsManager.shared.effectivePlaybackFadeEnabled, volume > 0 {
            // C1: fade in from silence instead of cutting the volume in.
            cancelFade()
            engine.volume = 0
            engine.play()
            isPlaying = true
            scrobbleStartIfNeeded()
            fadeVolume(to: effectiveVolume)
        } else {
            engine.play()
            isPlaying = true
            scrobbleStartIfNeeded()
        }
        NowPlayingManager.shared.updateElapsed(progress, rate: isPlaying ? 1 : 0)
    }

    func pause() {
        settleDeckBeforeTakeover()
        cancelFade()
        // Fade out only when there is something loaded and audible;
        // otherwise pause at once, exactly as before.
        guard SettingsManager.shared.effectivePlaybackFadeEnabled, engine.currentItem != nil, volume > 0 else {
            pauseImmediately()
            return
        }
        isPlaying = false
        AudioSpectrum.shared.reset()
        NowPlayingManager.shared.updateElapsed(progress, rate: 0)
        persistState()
        let startVolume = engine.volume
        fadeTask = Task { @MainActor [weak self] in
            for level in PlaybackFade.volumes(from: startVolume, to: 0, steps: PlaybackFade.defaultSteps) {
                guard let self else { return }
                if Task.isCancelled { return }
                self.engine.volume = level
                try? await Task.sleep(for: .milliseconds(PlaybackFade.stepIntervalMilliseconds))
            }
            guard let self else { return }
            if Task.isCancelled { return }
            self.engine.pause()
            // A muted engine would stick at 0 for the next play if the
            // fade-in path were ever skipped, so restore the user volume
            // now; a faded resume re-ramps from 0 anyway.
            self.engine.volume = self.effectiveVolume
            self.fadeTask = nil
        }
    }

    /// The pre-fade pause body, kept as the single immediate-pause path.
    private func pauseImmediately() {
        engine.pause()
        isPlaying = false
        AudioSpectrum.shared.reset()
        NowPlayingManager.shared.updateElapsed(progress, rate: 0)
        persistState()
    }

    /// Cancels any fade in flight; the next play/pause starts a fresh ramp
    /// from whatever volume the engine is actually at.
    private func cancelFade() {
        fadeTask?.cancel()
        fadeTask = nil
    }

    /// Ramps `engine.volume` to `target` over ~0.4 s. Only ever touches
    /// `engine.volume` — the `volume` setting (and its UserDefaults write)
    /// is left alone, so a fade never persists a mid-ramp level.
    private func fadeVolume(to target: Float) {
        let startVolume = engine.volume
        fadeTask = Task { @MainActor [weak self] in
            for level in PlaybackFade.volumes(from: startVolume, to: target, steps: PlaybackFade.defaultSteps) {
                guard let self else { return }
                if Task.isCancelled { return }
                self.engine.volume = level
                try? await Task.sleep(for: .milliseconds(PlaybackFade.stepIntervalMilliseconds))
            }
            guard let self else { return }
            if Task.isCancelled { return }
            self.engine.volume = target
            self.fadeTask = nil
        }
    }

    /// C3 (Folia P13): hold the screen awake only while actually playing.
    private func updateIdleTimerDisabled() {
        UIApplication.shared.isIdleTimerDisabled =
            SettingsManager.shared.effectivePreventDisplaySleepDuringPlayback && isPlaying
    }

    func next() {
        advanceToNext(userInitiated: true)
    }

    func previous() {
        if isFMMode { return }
        if progress > 4 || activeQueue.isEmpty {
            seek(to: 0)
            return
        }
        var idx = currentIndex - 1
        if idx < 0 {
            guard repeatMode == .all else {
                seek(to: 0)
                return
            }
            idx = activeQueue.count - 1
        }
        currentIndex = idx
        startPlaying(activeQueue[idx])
    }

    /// Recomputes the current lyric line, publishing only on a change.
    /// The lead makes a line light up just before it is sung.
    private func updateLyricsCursor(at seconds: TimeInterval) {
        let index = lyrics?.activeIndex(at: seconds + 0.2)
        if index != lyricsCursor.activeIndex {
            lyricsCursor.activeIndex = index
        }
    }

    func seek(to seconds: TimeInterval, completion: (@MainActor () -> Void)? = nil) {
        settleDeckBeforeTakeover()
        progress = seconds
        updateLyricsCursor(at: seconds)
        engine.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            guard let completion else { return }
            Task { @MainActor in completion() }
        }
        NowPlayingManager.shared.updateElapsed(seconds, rate: isPlaying ? 1 : 0)
        persistState()
    }

    func toggleShuffle() {
        guard !isFMMode else { return }
        shuffleEnabled.toggle()
        guard let current = currentTrack else { return }
        if shuffleEnabled {
            reshuffle(keeping: current)
            currentIndex = 0
        } else {
            currentIndex = queue.firstIndex(where: { $0.id == current.id }) ?? 0
        }
    }

    func cycleRepeatMode() {
        guard !isFMMode else { return }
        repeatMode = repeatMode.next
    }

    /// Single-button mode cycle for the iOS minimal transport row:
    /// sequential → loop all → loop one → shuffle → sequential.
    func cyclePlaybackMode() {
        guard !isFMMode else { return }
        if shuffleEnabled {
            toggleShuffle()
            repeatMode = .off
        } else {
            switch repeatMode {
            case .off:
                repeatMode = .all
            case .all:
                repeatMode = .one
            case .one:
                repeatMode = .off
                toggleShuffle()
            }
        }
    }

    /// Jump to a track in the upcoming list (queue panel click).
    func jumpTo(_ track: Track) {
        if let nextIdx = playNextList.firstIndex(where: { $0.id == track.id }) {
            playNextList.removeSubrange(0...nextIdx)
            startPlaying(track)
            return
        }
        if let idx = activeQueue.firstIndex(where: { $0.id == track.id }) {
            currentIndex = idx
            startPlaying(track)
        }
    }

    func removeFromUpcoming(_ track: Track) {
        if let idx = playNextList.firstIndex(where: { $0.id == track.id }) {
            playNextList.remove(at: idx)
            return
        }
        if let idx = queue.firstIndex(where: { $0.id == track.id }), idx != currentIndex || shuffleEnabled {
            queue.remove(at: idx)
        }
        if let idx = shuffledQueue.firstIndex(where: { $0.id == track.id }) {
            shuffledQueue.remove(at: idx)
        }
    }

    /// Queue rows carry their occurrence, so a repeated song selects the row
    /// the listener clicked rather than its first occurrence.
    func jumpToUpcoming(at index: Int, matching trackID: Int) {
        guard let selected = upcomingCandidate(at: index, matching: trackID) else { return }
        switch selected.origin {
        case .inserted(let offset):
            playNextList.removeSubrange(0...offset)
        case .queue(let offset):
            if !playNextList.isEmpty { playNextList.removeAll() }
            currentIndex = offset
        case .fm: return
        }
        startPlaying(selected.track)
    }

    /// Removes the row itself: a repeated song leaves the occurrence the
    /// listener chose, not its first one, so the current index stays put.
    func removeUpcoming(at index: Int, matching trackID: Int) {
        guard let selected = upcomingCandidate(at: index, matching: trackID) else { return }
        switch selected.origin {
        case .inserted(let offset): playNextList.remove(at: offset)
        case .queue(let offset): removeQueueRow(at: offset, trackID: selected.track.id)
        case .fm: return
        }
    }

    /// The row sits after the current index in the active order; the other
    /// order drops one copy of the same song so both stay the same length.
    private func removeQueueRow(at offset: Int, trackID: Int) {
        if shuffleEnabled {
            shuffledQueue.remove(at: offset)
            if let idx = queue.firstIndex(where: { $0.id == trackID }) { queue.remove(at: idx) }
        } else {
            queue.remove(at: offset)
            if let idx = shuffledQueue.firstIndex(where: { $0.id == trackID }) { shuffledQueue.remove(at: idx) }
        }
    }

    /// The row at `index` of `upcomingTracks`, if it still shows `trackID`.
    private func upcomingCandidate(at index: Int, matching trackID: Int) -> PlaybackQueueCandidate? {
        let candidates = PlaybackQueuePlan.next(queue: activeQueue, currentIndex: currentIndex, inserted: playNextList,
                                                fm: [], isFM: false, repeatAll: false, limit: max(0, index + 1))
        guard candidates.indices.contains(index), candidates[index].track.id == trackID else { return nil }
        return candidates[index]
    }

    // MARK: - Personal FM

    func startFM() {
        guard !isFMMode || !isPlaying else { return }
        recordRecent(.fm)
        isFMMode = true
        shuffleEnabled = false
        repeatMode = .off
        queue = []
        shuffledQueue = []
        playNextList = []
        currentIndex = -1
        source = .none
        Task { await fmAdvance() }
    }

    func fmNext() {
        guard isFMMode else { return }
        Task { await fmAdvance() }
    }

    func fmTrash() {
        guard isFMMode, let track = currentTrack else { return }
        Task {
            await fmAdvance()
            try? await MusicAPI.fmTrash(id: track.id)
        }
    }

    private func fmAdvance() async {
        if usesOfflineQueue {
            advanceOffline()
            return
        }
        if fmUpcoming.isEmpty {
            for attempt in 0..<3 {
                if let tracks = try? await MusicAPI.personalFM(), !tracks.isEmpty {
                    fmUpcoming = tracks
                    break
                }
                if attempt == 2 {
                    ToastCenter.shared.show(String(localized: "获取私人漫游数据失败"))
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        guard !fmUpcoming.isEmpty else { return }
        let track = fmUpcoming.removeFirst()
        pendingAutoAdvance = true
        startPlaying(track)
        if fmUpcoming.count < 1 {
            if let more = try? await MusicAPI.personalFM() {
                fmUpcoming.append(contentsOf: more)
            }
        }
    }

    // MARK: - Advancing

    private func advanceToNext(userInitiated: Bool) {
        settleDeckBeforeTakeover()
        if usesOfflineQueue, !nextCandidates().isEmpty {
            pendingAutoAdvance = !userInitiated
            advanceOffline()
            return
        }
        if isFMMode {
            Task { await fmAdvance() }
            return
        }
        if !playNextList.isEmpty {
            let track = playNextList.removeFirst()
            pendingAutoAdvance = !userInitiated
            startPlaying(track)
            return
        }
        guard !activeQueue.isEmpty else { return }
        var idx = currentIndex + 1
        if idx >= activeQueue.count {
            guard repeatMode == .all else {
                if userInitiated {
                    ToastCenter.shared.show(String(localized: "已经是最后一首了"))
                } else {
                    isPlaying = false
                    NowPlayingManager.shared.updateElapsed(progress, rate: 0)
                }
                return
            }
            idx = 0
        }
        currentIndex = idx
        pendingAutoAdvance = !userInitiated
        startPlaying(activeQueue[idx])
    }

    private func handleItemEnded(for item: AVPlayerItem) {
        // A queued end notification for the outgoing track must not fire
        // after a crossfade swapped decks: the item on the deck is a
        // different one now.
        guard engine.currentItem === item else { return }
        settleDeckBeforeTakeover()
        scrobbleIfNeeded(completed: true)

        if sleepTimer.consumeEndOfCurrentTrack() {
            progress = duration
            updateLyricsCursor(at: duration)
            pause()
            engine.replaceCurrentItem(with: nil)
            releaseCurrentPlaybackResources()
            return
        }

        guard isPlaying else { return }

        if repeatMode == .one, !isFMMode {
            scrobbled = false
            seek(to: 0)
            engine.play()
            isPlaying = true
            return
        }
        advanceToNext(userInitiated: false)
    }

    // MARK: - iOS crossfade (Folia P2/P3): dual-deck overlap

    /// Installs the per-deck observations: a 0.2 s time observer driving the
    /// clock / lyrics / progress, and the buffering observation. Only the
    /// active deck drives anything — the retiring deck keeps ticking through
    /// its fade-out and must not publish — so the time observer is identified
    /// by the deck it was installed on, not by a capture. Runs once per deck
    /// in `init`.
    private func wireDeck(_ deck: AVPlayer) -> DeckWiring {
        deck.actionAtItemEnd = .pause
        var wiring = DeckWiring()
        let deckID = ObjectIdentifier(deck)
        wiring.timeObserver = deck.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, deckID == ObjectIdentifier(self.engine), !self.isScrubbing else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }

                // Lyrics need this cadence to stay in sync; the cursor itself
                // only publishes when the line actually changes.
                self.updateLyricsCursor(at: seconds)

                // The scrubber does not. Publishing the position every tick
                // re-renders it — and SwiftUI rebuilds the display list for the
                // whole tree each time — to move the thumb a fraction of a
                // pixel. Half a second is still smoother than the eye needs.
                if abs(seconds - self.progress) > 0.45 {
                    self.progress = seconds
                    NowPlayingManager.shared.updateElapsed(seconds, rate: self.isPlaying ? 1 : 0)
                }
                if self.isPlaying, self.lastPlaybackCheckpoint.duration(to: .now) >= .seconds(20) {
                    self.persistState()
                }
                if self.isPlaying {
                    self.maybeStartTransition(at: seconds)
                    self.maybePrepareNextTrack()
                }
            }
        }
        wiring.statusObservation = deck.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, player === self.engine else { return }
                self.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }
        return wiring
    }

    /// Status observation for the active item, factored out of
    /// `installResolvedAsset` so the overlap swap can install one for the
    /// incoming item under the new generation.
    private func makeItemStatusObservation(
        for item: AVPlayerItem, track: Track, generation: Int,
        sourceID: AudioSourceID?, remoteURL: URL?, durationMS: Int?
    ) -> NSKeyValueObservation {
        item.observe(\.status, options: [.new]) { [weak self] item, _ in
            switch item.status {
            case .readyToPlay:
                Task { @MainActor in
                    self?.itemBecameReady(generation: generation)
                }
            case .failed:
                let error = item.error
                Task { @MainActor in
                    if let sourceID {
                        self?.handleUnblockItemFailure(track: track, generation: generation, sourceID: sourceID)
                    } else {
                        self?.handleItemFailure(
                            track: track,
                            generation: generation,
                            remoteURL: remoteURL,
                            durationMS: durationMS,
                            error: error
                        )
                    }
                }
            default:
                break
            }
        }
    }

    /// End observer for the active item. The item check in
    /// `handleItemEnded(for:)` drops notifications queued before a swap.
    private func makeEndObserver(for item: AVPlayerItem) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleItemEnded(for: item)
            }
        }
    }

    /// Settles any overlap or post-overlap rate glide before a user action or
    /// failure path takes the deck over.
    private func settleDeckBeforeTakeover() {
        completeTransitionIfNeeded()
        cancelRateRestore()
    }

    /// Instantly finishes an in-flight overlap: the incoming deck takes over
    /// at full volume and unity rate, the retiring deck is silenced, stopped
    /// and released. No-op when no overlap is running. Every path that takes
    /// the deck over calls this first, so a retiring deck can never keep
    /// playing behind the new track.
    private func completeTransitionIfNeeded() {
        guard transitionInProgress else { return }
        transitionTask?.cancel()
        transitionTask = nil
        cancelRateRestore()
        transitionInProgress = false
        let retiring = standbyEngine
        retiring.pause()
        retiring.volume = 0
        retiring.replaceCurrentItem(with: nil)
        releaseRetiringResources()
        engine.volume = effectiveVolume
        engine.defaultRate = 1.0
        engine.rate = 1.0
        NowPlayingManager.shared.updateElapsed(progress, rate: isPlaying ? 1 : 0)
    }

    /// Cancels a post-overlap rate glide and puts the active deck back to
    /// unity rate. No-op when no glide is running.
    private func cancelRateRestore() {
        guard rateRestoreTask != nil else { return }
        rateRestoreTask?.cancel()
        rateRestoreTask = nil
        engine.defaultRate = 1.0
        engine.rate = 1.0
    }

    /// Releases the loader and leases that fed the retiring deck.
    private func releaseRetiringResources() {
        retiringResourceLoader?.cancel()
        retiringResourceLoader = nil
        if let lease = retiringCacheLease { releaseAudioCacheLease(lease) }
        retiringCacheLease = nil
        if let lease = retiringOfflineLease { Task { try? await OfflineStore.shared.release(lease) } }
        retiringOfflineLease = nil
    }

    /// Triggers a preload of the next track when the overlap engine is on and
    /// nothing is prepared yet. Called from the active deck's time observer,
    /// so it runs at most once per tick and only while playing. A prepared item
    /// whose queue position no longer holds is dropped first, so a stale
    /// preload never blocks a fresh one.
    private func maybePrepareNextTrack() {
        if let prepared = preparedNext, !stillHolds(prepared.candidate) {
            discardPrepared()
        }
        guard SettingsManager.shared.effectiveIosCrossfadeEnabled, isPlaying, !transitionInProgress,
              transitionTask == nil, preparedNext == nil, prepareTask == nil,
              !usesOfflineQueue, repeatMode != .one,
              let candidate = nextCandidates().first,
              candidate.track.id != currentTrack?.id else { return }
        prepareNextTrack(candidate)
    }

    /// Resolves the next track in the background and installs it on the
    /// standby deck, paused at volume 0. Mirrors `resolveAndLoad`'s resolution
    /// order (download → cache → network → unblock → fallback cache) but never
    /// toasts, never skips, and never touches the playing track: any failure
    /// just leaves `preparedNext` empty and the next cut is a hard cut,
    /// exactly as today.
    private func prepareNextTrack(_ candidate: PlaybackQueueCandidate) {
        let track = candidate.track
        let epoch = prepareEpoch
        preparingCandidate = candidate
        prepareTask = Task { [weak self] in
            guard let self else { return }
            defer { self.prepareTask = nil; self.preparingCandidate = nil }
            let quality = SettingsManager.shared.audioQuality.rawValue
            let allowsUnblock = SettingsManager.shared.canResolveUnblockedTracks
            let cacheEnabled = SettingsManager.shared.enableAudioCache

            // A downloaded copy beats the network, and is all there is without one.
            if let lease = await self.acquireOfflineLease(for: track, generation: self.resolveGeneration) {
                guard !Task.isCancelled, self.prepareEpoch == epoch else {
                    try? await OfflineStore.shared.release(lease)
                    return
                }
                await self.installPreparedAsset(
                    AVURLAsset(url: lease.url), for: track, candidate: candidate, epoch: epoch,
                    offlineLease: lease, durationMS: Int(lease.descriptor.duration * 1000))
                return
            }
            guard !Task.isCancelled, self.prepareEpoch == epoch else { return }

            if cacheEnabled,
               let cached = try? await AudioCache.shared.entry(
                   for: track.id, requestedQuality: quality, allowsUnblock: allowsUnblock) {
                guard !Task.isCancelled, self.prepareEpoch == epoch else { return }
                let lease = await AudioCache.shared.retain(cached)
                guard !Task.isCancelled, self.prepareEpoch == epoch else {
                    self.releaseAudioCacheLease(lease)
                    return
                }
                var unblockName: String?
                if case .unblock(let source) = cached.metadata.source {
                    unblockName = source
                }
                await self.installPreparedAsset(
                    AVURLAsset(url: cached.fileURL), for: track, candidate: candidate, epoch: epoch,
                    cacheLease: lease, servedQuality: cached.metadata.servedQuality,
                    unblockName: unblockName)
                return
            }
            guard !Task.isCancelled, self.prepareEpoch == epoch else { return }

            // Network URL (same two-step quality fallback as `resolveAndLoad`).
            var data: SongURLData?
            do {
                data = try await MusicAPI.songURL(ids: [track.id], level: quality).first
                if data?.url == nil, quality != AudioQuality.standard.rawValue {
                    data = try await MusicAPI.songURL(ids: [track.id], level: AudioQuality.standard.rawValue).first
                }
            } catch { data = nil }
            guard !Task.isCancelled, self.prepareEpoch == epoch else { return }

            var resolvedURL: URL?
            var servedQuality = data?.level
            var isTrial = false
            var unblockID: AudioSourceID?
            var unblockName: String?
            if let urlString = data?.url {
                resolvedURL = URL(string: urlString.replacingOccurrences(of: "http://", with: "https://"))
            }
            if resolvedURL == nil || data?.freeTrialInfo != nil, allowsUnblock {
                let resolution = await UnblockService.resolve(
                    track, enabledSources: SettingsManager.shared.enabledAudioSourceIDs, excluding: [])
                if let unblocked = resolution.source {
                    resolvedURL = unblocked.url
                    unblockID = unblocked.id
                    unblockName = unblocked.displayName
                    servedQuality = nil
                    isTrial = false
                }
            }
            guard !Task.isCancelled, self.prepareEpoch == epoch else { return }
            guard let url = resolvedURL else {
                // Last resort: any cached copy, like `loadFallbackCache`.
                if cacheEnabled,
                   let cached = try? await AudioCache.shared.fallbackEntry(
                       for: track.id, allowsUnblock: allowsUnblock) {
                    guard !Task.isCancelled, self.prepareEpoch == epoch else { return }
                    let lease = await AudioCache.shared.retain(cached)
                    guard !Task.isCancelled, self.prepareEpoch == epoch else {
                        self.releaseAudioCacheLease(lease)
                        return
                    }
                    await self.installPreparedAsset(
                        AVURLAsset(url: cached.fileURL), for: track, candidate: candidate, epoch: epoch,
                        cacheLease: lease, servedQuality: cached.metadata.servedQuality)
                }
                return
            }
            if data?.freeTrialInfo != nil, unblockID == nil {
                isTrial = true
            }
            await self.prepareLoadedURL(
                track: track, url: url, durationMS: data?.time, candidate: candidate, epoch: epoch,
                servedQuality: servedQuality, unblockID: unblockID, unblockName: unblockName, isTrial: isTrial)
        }
    }

    /// Builds the (possibly cache-wrapped) asset for a resolved network URL
    /// and installs it on the standby deck — the prepare-side twin of
    /// `loadResolvedURL`, minus the failure handling: a prepare that cannot
    /// load just gives up.
    private func prepareLoadedURL(
        track: Track, url: URL, durationMS: Int?, candidate: PlaybackQueueCandidate, epoch: Int,
        servedQuality: String?, unblockID: AudioSourceID?, unblockName: String?, isTrial: Bool
    ) async {
        let remote = CDNHost.preferred(for: url)
        var asset = AVURLAsset(url: remote)
        // Beans pattern: a QQ/Kugou stream needs the platform login
        // headers (UA/Referer + cookies) on the asset or the host 403s.
        // This only covers the direct asset: when the cache loader below
        // takes over, `asset` is replaced by the loader's cached asset
        // and the download goes through the loader's own session, which
        // does not get these headers (see the note on `loadResolvedURL`).
        if let headers = Self.playbackHeaders(for: unblockID) {
            // The AVURLAssetHTTPHeaderFieldsKey constant is not exposed
            // to Swift by the iOS SDK (CI run #85: "cannot find in
            // scope"), so the option key is spelled out as its literal
            // string — the same value, and the standard workaround.
            asset = AVURLAsset(url: remote, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        }
        var resourceLoader: CachingAudioResourceLoader?
        if SettingsManager.shared.enableAudioCache, !isTrial {
            let cacheLimitMB = await SettingsManager.shared.effectiveAudioCacheSizeMB()
            guard prepareEpoch == epoch else { return }
            let source: AudioCacheSource = unblockName.map(AudioCacheSource.unblock) ?? .origin
            do {
                let loader = try CachingAudioResourceLoader(
                    remoteURL: remote,
                    trackID: track.id,
                    requestedQuality: SettingsManager.shared.audioQuality.rawValue,
                    servedQuality: servedQuality,
                    source: source,
                    maximumCacheSizeMB: cacheLimitMB
                )
                guard prepareEpoch == epoch else {
                    loader.cancel()
                    return
                }
                let cachedAsset = AVURLAsset(url: loader.assetURL)
                loader.attach(to: cachedAsset)
                resourceLoader = loader
                asset = cachedAsset
            } catch {
                print("Audio source will play without caching: \(error)")
            }
        }
        await installPreparedAsset(
            asset, for: track, candidate: candidate, epoch: epoch, remoteURL: remote,
            resourceLoader: resourceLoader, durationMS: durationMS, servedQuality: servedQuality,
            unblockID: unblockID, unblockName: unblockName, isTrial: isTrial)
    }

    /// Installs a resolved asset on the standby deck, paused at volume 0, and
    /// records it as `preparedNext`. The spectrum tap is attached when the
    /// source allows it — a cached file plays untapped, exactly as on the
    /// active deck — but `markUntappable()` is deliberately NOT called here:
    /// that flips shared spectrum state the playing track still owns.
    private func installPreparedAsset(
        _ asset: AVURLAsset, for track: Track, candidate: PlaybackQueueCandidate, epoch: Int,
        remoteURL: URL? = nil, resourceLoader: CachingAudioResourceLoader? = nil,
        cacheLease: UUID? = nil, offlineLease: OfflinePlaybackLease? = nil,
        durationMS: Int? = nil, servedQuality: String? = nil,
        unblockID: AudioSourceID? = nil, unblockName: String? = nil, isTrial: Bool = false
    ) async {
        #if os(iOS)
        let assetTrack = asset.url.isFileURL ? nil : await loadAudioTrack(from: asset, timeout: 2)
        #else
        let assetTrack = await loadAudioTrack(from: asset, timeout: 2)
        #endif
        guard epoch == prepareEpoch, preparedNext == nil else {
            resourceLoader?.cancel()
            if let cacheLease { releaseAudioCacheLease(cacheLease) }
            if let offlineLease { Task { try? await OfflineStore.shared.release(offlineLease) } }
            return
        }
        let item = AVPlayerItem(asset: asset)
        if let assetTrack, let mix = AudioSpectrum.shared.makeAudioMix(for: assetTrack) {
            item.audioMix = mix
        }
        let prepared = PreparedNext(
            track: track, candidate: candidate, item: item, assetURL: asset.url,
            resourceLoader: resourceLoader, cacheLease: cacheLease, offlineLease: offlineLease,
            durationMS: durationMS, servedQuality: servedQuality,
            unblockSourceID: unblockID, unblockSourceName: unblockName, isTrial: isTrial)
        preparedItemStatusObservation?.invalidate()
        preparedItemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            switch item.status {
            case .readyToPlay:
                Task { @MainActor in
                    guard let self, self.preparedNext?.item === item else { return }
                    self.preparedNext?.isReady = true
                }
            case .failed:
                Task { @MainActor in
                    guard let self, self.preparedNext?.item === item else { return }
                    self.discardPrepared()
                }
            default:
                break
            }
        }
        standbyEngine.volume = 0
        standbyEngine.replaceCurrentItem(with: item)
        preparedNext = prepared
    }

    /// Drops the prepared next track: stops the standby deck, releases its
    /// loader and leases. No-op when nothing is prepared (in particular during
    /// an overlap, when `preparedNext` is already consumed).
    private func discardPrepared() {
        prepareTask?.cancel()
        guard let prepared = preparedNext else { return }
        preparedNext = nil
        preparedItemStatusObservation?.invalidate()
        preparedItemStatusObservation = nil
        standbyEngine.pause()
        standbyEngine.volume = 0
        standbyEngine.replaceCurrentItem(with: nil)
        prepared.resourceLoader?.cancel()
        if let cacheLease = prepared.cacheLease { releaseAudioCacheLease(cacheLease) }
        if let offlineLease = prepared.offlineLease { Task { try? await OfflineStore.shared.release(offlineLease) } }
    }

    /// Decides how the current track hands over to `incoming`. Crossfade mode
    /// always uses a timed plan (no analysis needed); Automix asks the planner
    /// when both sides were analyzed, and falls back to the same timed plan
    /// when a side has no analysis — iOS only analyzes local files, so
    /// without the fallback Automix would be gapless for almost every
    /// streamed pair.
    private func planTransition(outgoing: Track, incoming: Track) -> ActiveTransition? {
        let mode = SettingsManager.shared.effectiveTransitionMode
        let config = CrossfadeTransition.plannerConfig(
            mode: mode, crossfadeMaxSeconds: SettingsManager.shared.effectiveCrossfadeMaxSeconds)
        let outgoingDuration = duration
        guard outgoingDuration > 0, incoming.duration > 0 else { return nil }
        if mode == .crossfade {
            guard let timed = CrossfadeTransition.timedCrossfade(
                outgoingDuration: outgoingDuration, incomingDuration: incoming.duration,
                maxSeconds: SettingsManager.shared.effectiveCrossfadeMaxSeconds) else { return nil }
            return ActiveTransition(duration: timed.duration, outPoint: timed.outPoint, inPoint: 0,
                                    outgoingRate: 1, incomingRate: 1, rateReleaseSeconds: 0,
                                    isBeatMatched: false)
        }
        let outgoingAnalysis = analysisByTrackID[outgoing.id]
        let incomingAnalysis = analysisByTrackID[incoming.id]
        if outgoingAnalysis == nil || incomingAnalysis == nil {
            guard let timed = CrossfadeTransition.timedCrossfade(
                outgoingDuration: outgoingDuration, incomingDuration: incoming.duration,
                maxSeconds: SettingsManager.shared.effectiveCrossfadeMaxSeconds) else { return nil }
            return ActiveTransition(duration: timed.duration, outPoint: timed.outPoint, inPoint: 0,
                                    outgoingRate: 1, incomingRate: 1, rateReleaseSeconds: 0,
                                    isBeatMatched: false)
        }
        switch TransitionPlanner.plan(outgoing: outgoingAnalysis, incoming: incomingAnalysis,
                                      config: config).plan {
        case .gapless:
            return nil
        case .crossfade(let duration, let outPoint, let inPoint):
            return ActiveTransition(duration: duration, outPoint: outPoint, inPoint: inPoint,
                                    outgoingRate: 1, incomingRate: 1, rateReleaseSeconds: 0,
                                    isBeatMatched: false)
        case .beatMatched(let plan):
            return ActiveTransition(duration: plan.overlapDuration, outPoint: plan.outPoint,
                                    inPoint: plan.inPoint, outgoingRate: plan.outgoingRate,
                                    incomingRate: plan.incomingRate,
                                    rateReleaseSeconds: plan.rampReleaseSeconds > 0 ? plan.rampReleaseSeconds : 3,
                                    isBeatMatched: true)
        }
    }

    /// Starts the overlap when the playhead reaches the plan's out point.
    /// Called from the active deck's time observer, so at most once per 0.2 s
    /// tick and only while playing.
    private func maybeStartTransition(at seconds: TimeInterval) {
        if let prepared = preparedNext, !stillHolds(prepared.candidate) {
            discardPrepared()
        }
        guard SettingsManager.shared.effectiveIosCrossfadeEnabled, isPlaying, !transitionInProgress,
              transitionTask == nil, sleepTimer.state != .endOfCurrentTrack,
              let prepared = preparedNext, prepared.isReady,
              let outgoingTrack = currentTrack,
              let installed = installedItem, engine.currentItem === installed,
              duration > 0,
              let plan = planTransition(outgoing: outgoingTrack, incoming: prepared.track),
              seconds >= plan.outPoint else { return }
        // The observer ticks every 0.2 s, so the start is normally on time; a
        // late start shortens a plain crossfade, and skips a beat-matched plan
        // outright — its grids were aligned for the planned out point, not for now.
        let elapsed = seconds - plan.outPoint
        if plan.isBeatMatched, elapsed > 0.5 { return }
        let remaining = plan.duration - elapsed
        guard remaining >= 1 else { return }
        let active = ActiveTransition(duration: remaining, outPoint: seconds, inPoint: plan.inPoint,
                                      outgoingRate: plan.outgoingRate, incomingRate: plan.incomingRate,
                                      rateReleaseSeconds: plan.rateReleaseSeconds,
                                      isBeatMatched: plan.isBeatMatched)
        beginTransition(active, prepared: prepared)
    }

    /// Swaps the decks at the overlap: the standby deck (already holding the
    /// incoming track, paused at volume 0) starts playing while the outgoing
    /// deck fades out under an equal-power ramp. Logical state (track, queue
    /// pointers, metadata, scrobble) moves to the incoming track at the same
    /// moment, so the lock screen, Control Center and Live Activity never see
    /// a gap.
    private func beginTransition(_ plan: ActiveTransition, prepared: PreparedNext) {
        guard currentTrack != nil else { return }
        // Any advance waiting on a preparation is superseded by this
        // transition; its retry must not fire afterwards.
        deferredAdvanceTrackID = nil
        let outgoingDeck = engine
        let incomingDeck = standbyEngine
        let outgoingBaseVolume = outgoingDeck.volume
        // The outgoing track is finished for scrobbling purposes — the
        // listener heard it to the seam.
        scrobbleIfNeeded(completed: true)
        // Invalidate anything still resolving or preparing for the outgoing track.
        resolveGeneration += 1
        let generation = resolveGeneration
        prepareEpoch += 1
        // Resources: the incoming track's take the active slots; the outgoing
        // track's retire with its deck and are released when the overlap ends.
        retiringResourceLoader = audioResourceLoader
        retiringCacheLease = audioCacheLease
        retiringOfflineLease = offlinePlaybackLease
        audioResourceLoader = prepared.resourceLoader
        audioCacheLease = prepared.cacheLease
        offlinePlaybackLease = prepared.offlineLease
        // Logical swap.
        consumeCandidateIfHeld(prepared.candidate)
        preparedNext = nil
        preparedItemStatusObservation?.invalidate()
        preparedItemStatusObservation = nil
        currentTrack = prepared.track
        progress = plan.inPoint
        duration = prepared.durationMS.map { TimeInterval($0) / 1000 } ?? prepared.track.duration
        lyrics = nil
        lyricsCursor.activeIndex = nil
        scrobbled = false
        startScrobbled = false
        isTrial = prepared.isTrial
        servedQuality = prepared.servedQuality
        unblockSource = prepared.unblockSourceName
        currentUnblockSourceID = prepared.unblockSourceID
        consecutiveFailures = 0
        itemRetryGeneration = nil
        // Observations: the outgoing item's are retired with it; the incoming
        // item gets a fresh status observation and end observer under the new
        // generation.
        itemStatusObservation?.invalidate()
        itemStatusObservation = makeItemStatusObservation(
            for: prepared.item, track: prepared.track, generation: generation,
            sourceID: currentUnblockSourceID, remoteURL: nil, durationMS: prepared.durationMS)
        if let old = endObserver { NotificationCenter.default.removeObserver(old) }
        endObserver = makeEndObserver(for: prepared.item)
        installedItem = prepared.item
        // Loudness trim for the incoming track; the ramp below writes the
        // volumes, so no direct write here.
        currentLoudnessTrimDB = loudnessTrimDB(for: analysisByTrackID[prepared.track.id])
        if prepared.assetURL.isFileURL {
            analyzeForLoudnessIfNeeded(fileURL: prepared.assetURL, for: prepared.track)
        }
        // Deck swap.
        activeDeckIsA.toggle()
        if plan.incomingRate != 1.0 {
            prepared.item.audioTimePitchAlgorithm = .spectral
            incomingDeck.defaultRate = plan.incomingRate
        }
        if plan.outgoingRate != 1.0 {
            outgoingDeck.rate = plan.outgoingRate
        }
        if plan.inPoint > 0.01 {
            incomingDeck.seek(to: CMTime(seconds: plan.inPoint, preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                Task { @MainActor [weak self] in
                    guard let self, self.transitionInProgress else { return }
                    self.engine.play()
                }
            }
        } else {
            incomingDeck.play()
        }
        scrobbleStartIfNeeded()
        NowPlayingManager.shared.updateMetadata(for: prepared.track, duration: duration)
        NowPlayingManager.shared.updateElapsed(progress, rate: 1)
        persistState()
        Task { await loadLyrics(for: prepared.track, generation: generation) }
        transitionInProgress = true
        // Equal-power ramp: the outgoing deck falls as cos, the incoming rises
        // as sin, so the summed power stays flat across the seam. Targets are
        // captured once — a volume change mid-ramp lands at the next track instead.
        let incomingBaseVolume = effectiveVolume
        transitionTask = Task { @MainActor [weak self] in
            let steps = max(1, Int(plan.duration / 0.05))
            for step in 1...steps {
                guard let self else { return }
                if Task.isCancelled { return }
                let t = Double(step) / Double(steps)
                let gains = CrossfadeTransition.equalPowerGains(at: t)
                self.standbyEngine.volume = gains.outGain * outgoingBaseVolume
                self.engine.volume = gains.inGain * incomingBaseVolume
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let self else { return }
            if Task.isCancelled { return }
            self.finishTransition(incomingRate: plan.incomingRate,
                                  rateReleaseSeconds: plan.rateReleaseSeconds)
        }
    }

    /// Ends the overlap: the retiring deck is silenced, stopped and released,
    /// the incoming deck takes full volume, and a beat-matched deck glides
    /// back to unity rate.
    private func finishTransition(incomingRate: Float, rateReleaseSeconds: TimeInterval) {
        transitionTask = nil
        transitionInProgress = false
        let retiring = standbyEngine
        retiring.pause()
        retiring.volume = 0
        retiring.replaceCurrentItem(with: nil)
        releaseRetiringResources()
        engine.volume = effectiveVolume
        // The beat-matched seek plays on completion; if it is still pending
        // (pathological stall), start the deck here so the track is not left silent.
        if isPlaying, engine.timeControlStatus != .playing {
            engine.play()
        }
        if incomingRate != 1.0, rateReleaseSeconds > 0 {
            let startRate = incomingRate
            let release = max(0.5, rateReleaseSeconds)
            rateRestoreTask?.cancel()
            rateRestoreTask = Task { @MainActor [weak self] in
                let steps = max(1, Int(release / 0.05))
                for step in 1...steps {
                    guard let self else { return }
                    if Task.isCancelled { return }
                    let t = Float(step) / Float(steps)
                    self.engine.rate = startRate + (1.0 - startRate) * t
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard let self else { return }
                if Task.isCancelled { return }
                self.engine.rate = 1.0
                self.engine.defaultRate = 1.0
                self.rateRestoreTask = nil
            }
        } else {
            engine.defaultRate = 1.0
            engine.rate = 1.0
        }
        NowPlayingManager.shared.updateElapsed(progress, rate: isPlaying ? 1 : 0)
        persistState()
    }

    /// Advances the queue pointers for a prepared candidate — but only if it
    /// still holds. The callers of `startPlaying` (next / jump-to / FM
    /// advance) already consumed it on their way in, so consuming twice
    /// would eat the following track.
    private func consumeCandidateIfHeld(_ candidate: PlaybackQueueCandidate) {
        guard stillHolds(candidate) else { return }
        switch candidate.origin {
        case .inserted(let offset):
            playNextList.removeSubrange(0...offset)
        case .queue(let offset):
            if !playNextList.isEmpty { playNextList.removeAll() }
            currentIndex = offset
        case .fm(let index):
            fmUpcoming.removeSubrange(0...index)
        }
    }

    // MARK: - Source resolution

    private func startPlaying(_ track: Track,
                              localLease: OfflinePlaybackLease? = nil, resumeAt: TimeInterval = 0) {
        settleDeckBeforeTakeover()
        // iOS crossfade: a manual advance onto the prepared track crossfades
        // immediately instead of re-resolving it. The active deck must still
        // be playing the current track — after a natural end the deck has
        // stopped, so that case falls through to the hard cut below.
        if SettingsManager.shared.effectiveIosCrossfadeEnabled, isPlaying, !transitionInProgress,
           let prepared = preparedNext, prepared.track.id == track.id, prepared.isReady,
           sleepTimer.state != .endOfCurrentTrack, repeatMode != .one,
           engine.timeControlStatus == .playing,
           let installed = installedItem, engine.currentItem === installed,
           stillHolds(prepared.candidate),
           let plan = planTransition(outgoing: currentTrack ?? track, incoming: track) {
            let remaining = max(0, duration - livePlaybackTime)
            let overlap = min(plan.duration, remaining)
            if overlap >= 1 {
                currentWasAdvanced = pendingAutoAdvance
                pendingAutoAdvance = false
                beginTransition(
                    ActiveTransition(duration: overlap, outPoint: livePlaybackTime,
                                     inPoint: plan.inPoint, outgoingRate: plan.outgoingRate,
                                     incomingRate: plan.incomingRate,
                                     rateReleaseSeconds: plan.rateReleaseSeconds,
                                     isBeatMatched: plan.isBeatMatched),
                    prepared: prepared)
                return
            }
        }
        // One exception, checked before discarding anything: a preparation
        // for exactly this track is already in flight (the user tapped
        // next while the preload was still resolving). Discarding it and
        // re-resolving from scratch is what makes rapid skipping feel laggy,
        // so wait for it instead — the old track keeps playing meanwhile, so
        // the wait is silent, not a gap. After ~6s the wait gives up and the
        // normal hard cut runs, so a tap is never left unanswered.
        if let candidate = preparingCandidate,
           candidate.track.id == track.id,
           prepareTask != nil,
           stillHolds(candidate) {
            deferredAdvanceTrackID = track.id
            let wasPlaying = isPlaying
            Task { @MainActor [weak self] in
                guard let self else { return }
                let deadline = Date().addingTimeInterval(6)
                while Date() < deadline {
                    if self.prepareTask == nil,
                       self.preparedNext?.track.id != track.id || self.preparedNext?.isReady == true {
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                // Only retry when nothing changed meanwhile: a pause/resume
                // or a newer advance supersedes the wait.
                guard self.isPlaying == wasPlaying, self.deferredAdvanceTrackID == track.id else { return }
                self.deferredAdvanceTrackID = nil
                self.startPlaying(track, localLease: localLease, resumeAt: resumeAt)
            }
            return
        }
        deferredAdvanceTrackID = nil
        // The prepared item (if any) is for another track now, and the item
        // on the deck belongs to the previous track: both stop being valid here.
        discardPrepared()
        prepareEpoch += 1
        installedItem = nil
        offlineScan?.cancel()
        offlineScan = nil
        offlineScanID = UUID()
        offlineIssue = nil
        currentWasAdvanced = pendingAutoAdvance
        pendingAutoAdvance = false
        pendingAudioResourceLoader?.cancel()
        pendingAudioResourceLoader = nil
        scrobbleIfNeeded(completed: false)
        currentTrack = track
        playbackAccountID = AccountStore.shared.profile?.userId
        progress = resumeAt
        duration = track.duration
        servedQuality = nil
        unblockSource = nil
        currentUnblockSourceID = nil
        attemptedUnblockSources.removeAll()
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        isTrial = false
        lyrics = nil
        scrobbled = false
        startScrobbled = false
        isPlaying = true
        lyricsCursor.activeIndex = nil
        // Before the URL is even resolved: holds the bars still rather than
        // letting them fall back to the decorative animation for the moment it
        // takes to find out whether this source can be tapped.
        AudioSpectrum.shared.beginPreparing()
        resolveGeneration += 1
        let generation = resolveGeneration
        if advancingAfterFailure {
            advancingAfterFailure = false
        } else {
            consecutiveFailures = 0
        }

        NowPlayingManager.shared.updateMetadata(for: track, duration: track.duration)
        persistState()

        Task {
            await resolveAndLoad(track, generation: generation, localLease: localLease, resumeAt: resumeAt)
        }
        Task {
            await loadLyrics(for: track, generation: generation)
        }
    }

    /// - Parameter skipsLocalCopies: set when the downloaded or cached copy
    ///   just failed to play, so the reload fetches the song again instead
    ///   of the same file.
    private func resolveAndLoad(_ track: Track, generation: Int,
                                localLease: OfflinePlaybackLease? = nil,
                                skipsLocalCopies: Bool = false,
                                resumeAt: TimeInterval = 0) async {
        let quality = SettingsManager.shared.audioQuality.rawValue
        let allowsUnblock = SettingsManager.shared.canResolveUnblockedTracks
        let cacheEnabled = SettingsManager.shared.enableAudioCache && !skipsLocalCopies

        // A downloaded copy beats the network, and is all there is without one.
        if !skipsLocalCopies, let lease = await acquireOfflineLease(for: track, generation: generation, reusing: localLease) {
            await playOfflineFile(lease, for: track, generation: generation, resumeAt: resumeAt)
            return
        }
        guard generation == resolveGeneration else { return }

        if cacheEnabled {
            do {
                if let cached = try await AudioCache.shared.entry(
                    for: track.id,
                    requestedQuality: quality,
                    allowsUnblock: allowsUnblock
                ) {
                    guard generation == resolveGeneration else { return }
                    let lease = await AudioCache.shared.retain(cached)
                    guard generation == resolveGeneration else {
                        releaseAudioCacheLease(lease)
                        return
                    }
                    servedQuality = cached.metadata.servedQuality
                    if case .unblock(let source) = cached.metadata.source {
                        unblockSource = source
                    }
                    _ = await installResolvedAsset(
                        AVURLAsset(url: cached.fileURL),
                        for: track,
                        generation: generation,
                        durationMS: nil,
                        cacheLease: lease,
                        resumeAt: resumeAt
                    )
                    return
                }
            } catch {
                print("Audio cache lookup failed: \(error)")
            }
        }

        // Without a network, the cache is the last place to look.
        if usesOfflineQueue {
            if cacheEnabled, await loadFallbackCache(for: track, generation: generation, allowsUnblock: allowsUnblock, resumeAt: resumeAt) { return }
            guard generation == resolveGeneration else { return }
            unavailableOffline(track, generation: generation)
            return
        }

        var data: SongURLData?
        do {
            data = try await MusicAPI.songURL(ids: [track.id], level: quality).first
            if data?.url == nil, quality != AudioQuality.standard.rawValue {
                data = try await MusicAPI.songURL(ids: [track.id], level: AudioQuality.standard.rawValue).first
            }
        } catch {
            guard generation == resolveGeneration else { return }
            // A download covers a request that died on the network. Anything
            // else keeps upstream's path: third-party sources, then the cache.
            if ConnectivityFailure.matches(error) {
                if let lease = await acquireOfflineLease(for: track, generation: generation, anyQuality: true) {
                    await playOfflineFile(lease, for: track, generation: generation, resumeAt: resumeAt)
                    return
                }
                guard generation == resolveGeneration else { return }
                if usesOfflineQueue {
                    if cacheEnabled, await loadFallbackCache(for: track, generation: generation, allowsUnblock: allowsUnblock, resumeAt: resumeAt) { return }
                    guard generation == resolveGeneration else { return }
                    unavailableOffline(track, generation: generation)
                    return
                }
            }
        }
        guard generation == resolveGeneration else { return }

        var resolvedURL: URL?
        if let urlString = data?.url {
            resolvedURL = URL(string: urlString.replacingOccurrences(of: "http://", with: "https://"))
        }

        // The service refused — try third-party sources (unblock-style).
        if resolvedURL == nil || data?.freeTrialInfo != nil, allowsUnblock {
            if await resolveAndLoadUnblocked(track, generation: generation, resumeAt: resumeAt) { return }
        }
        guard generation == resolveGeneration else { return }

        guard let url = resolvedURL else {
            if cacheEnabled, await loadFallbackCache(
                for: track,
                generation: generation,
                allowsUnblock: allowsUnblock,
                resumeAt: resumeAt
            ) {
                return
            }
            handleUnplayable(track)
            return
        }

        servedQuality = data?.level
        if data?.freeTrialInfo != nil {
            isTrial = true
            ToastCenter.shared.show(String(localized: "VIP 歌曲，当前为试听片段"))
        }
        _ = await loadResolvedURL(track, url: url, durationMS: data?.time, generation: generation, resumeAt: resumeAt)
    }

    private func resolveAndLoadUnblocked(
        _ track: Track,
        generation: Int,
        requiresActivePlayback: Bool = false,
        resumeAt: TimeInterval = 0
    ) async -> Bool {
        let enabledSources = SettingsManager.shared.enabledAudioSourceIDs
        guard !enabledSources.isEmpty else { return false }

        guard generation == resolveGeneration,
              !requiresActivePlayback || isPlaying
        else { return false }

        let resolution = await UnblockService.resolve(
            track,
            enabledSources: enabledSources,
            excluding: attemptedUnblockSources
        )
        attemptedUnblockSources.formUnion(resolution.attemptedSources)
        guard let unblocked = resolution.source else { return false }
        guard generation == resolveGeneration,
              !requiresActivePlayback || isPlaying
        else { return false }

        currentUnblockSourceID = unblocked.id
        unblockSource = unblocked.displayName
        servedQuality = nil
        isTrial = false

        let loadResult = await loadResolvedURL(
            track,
            url: unblocked.url,
            durationMS: nil,
            generation: generation,
            resumeAt: resumeAt
        )
        guard case .loaded = loadResult else { return false }

        ToastCenter.shared.show(String(localized: "已使用第三方音源：\(unblocked.displayName)"))
        return true
    }

    private func handleUnplayable(_ track: Track) {
        settleDeckBeforeTakeover()
        consecutiveFailures += 1
        let playability = track.playability(privilege: nil,
                                            isLoggedIn: AccountStore.shared.isLoggedIn,
                                            vipType: AccountStore.shared.vipType)
        ToastCenter.shared.show(String(localized: "《\(track.name)》无法播放\(playability.reason.map { "：\($0)" } ?? "")"))
        guard isPlaying else {
            engine.replaceCurrentItem(with: nil)
            releaseCurrentPlaybackResources()
            return
        }
        // B7 (Folia P12): auto-skip is a setting, and only for tracks the
        // metadata itself rules out (VIP / paid album / no copyright /
        // delisted). A track that reads as playable but failed to resolve is
        // treated as transient — most often the network — and never skipped:
        // there is no network reason in `TrackPlayability`, so `.playable`
        // is the only signal that separates the two.
        guard UnplayableSkip.shouldAutoSkip(playability: playability,
                                            autoSkipEnabled: SettingsManager.shared.effectiveAutoSkipUnplayable),
              consecutiveFailures < 5 else {
            isPlaying = false
            NowPlayingManager.shared.updateElapsed(progress, rate: 0)
            return
        }
        advancingAfterFailure = true
        advanceToNext(userInitiated: false)
    }

    /// Playback headers for a resolved third-party URL (Beans
    /// `PlayerManager` pattern: QQ gets a Firefox UA + y.qq.com Referer
    /// + login Cookie; Kugou gets its Android UA + kugou.com Referer +
    /// login Cookie). Nil for NetEase and every other source, and nil
    /// when the platform reports no headers at all.
    private static func playbackHeaders(for source: AudioSourceID?) -> [String: String]? {
        switch source {
        case .qqmusic:
            let headers = QQMusicAuth.shared.playbackHeaders
            return headers.isEmpty ? nil : headers
        case .kugou:
            let headers = KugouMusicAuth.shared.playbackHeaders
            return headers.isEmpty ? nil : headers
        default:
            return nil
        }
    }

    private func loadResolvedURL(
        _ track: Track,
        url: URL,
        durationMS: Int?,
        generation: Int,
        resumeAt: TimeInterval = 0
    ) async -> ResolvedURLLoadResult {
        // Skip a CDN host that just failed to connect (see CDNHost).
        let remote = CDNHost.preferred(for: url)

        var asset = AVURLAsset(url: remote)
        // Beans pattern (see `prepareLoadedURL`): a QQ/Kugou stream
        // needs the platform login headers on the asset or the host
        // 403s. `loadResolvedURL` takes no source parameter; the caller
        // (`resolveAndLoadUnblocked`) records it in
        // `currentUnblockSourceID` before calling here. As in
        // `prepareLoadedURL`, this only covers the direct asset — when
        // the cache loader below takes over, the download goes through
        // the loader's own session without these headers, so a cached
        // QQ/Kugou playback that 403s needs the loader taught to carry
        // them (follow-up, not this change).
        if let headers = Self.playbackHeaders(for: currentUnblockSourceID) {
            // Same literal-string key as in prepareLoadedURL: the
            // AVURLAssetHTTPHeaderFieldsKey constant is not exposed to
            // Swift by the iOS SDK (CI run #85).
            asset = AVURLAsset(url: remote, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        }
        var resourceLoader: CachingAudioResourceLoader?
        if SettingsManager.shared.enableAudioCache, !isTrial {
            let cacheLimitMB = await SettingsManager.shared.effectiveAudioCacheSizeMB()
            guard generation == resolveGeneration else { return .superseded }
            let source: AudioCacheSource = unblockSource.map(AudioCacheSource.unblock) ?? .origin
            do {
                let loader = try CachingAudioResourceLoader(
                    remoteURL: remote,
                    trackID: track.id,
                    requestedQuality: SettingsManager.shared.audioQuality.rawValue,
                    servedQuality: servedQuality,
                    source: source,
                    maximumCacheSizeMB: cacheLimitMB
                )
                guard generation == resolveGeneration else {
                    loader.cancel()
                    return .superseded
                }
                let cachedAsset = AVURLAsset(url: loader.assetURL)
                loader.attach(to: cachedAsset)
                pendingAudioResourceLoader = loader
                resourceLoader = loader
                asset = cachedAsset
            } catch {
                print("Audio source will play without caching: \(error)")
            }
        }

        return await installResolvedAsset(
            asset,
            for: track,
            generation: generation,
            durationMS: durationMS,
            remoteURL: remote,
            resourceLoader: resourceLoader,
            resumeAt: resumeAt
        )
    }

    private func loadFallbackCache(
        for track: Track,
        generation: Int,
        allowsUnblock: Bool,
        resumeAt: TimeInterval = 0
    ) async -> Bool {
        do {
            guard let cached = try await AudioCache.shared.fallbackEntry(
                for: track.id,
                allowsUnblock: allowsUnblock
            ) else { return false }
            guard generation == resolveGeneration else { return true }
            let lease = await AudioCache.shared.retain(cached)
            guard generation == resolveGeneration else {
                releaseAudioCacheLease(lease)
                return true
            }
            servedQuality = cached.metadata.servedQuality
            if case .unblock(let source) = cached.metadata.source {
                unblockSource = source
            }
            _ = await installResolvedAsset(
                AVURLAsset(url: cached.fileURL),
                for: track,
                generation: generation,
                durationMS: nil,
                cacheLease: lease,
                resumeAt: resumeAt
            )
            return true
        } catch {
            print("Audio cache fallback lookup failed: \(error)")
            return false
        }
    }

    private func installResolvedAsset(
        _ asset: AVURLAsset,
        for track: Track,
        generation: Int,
        durationMS: Int?,
        remoteURL: URL? = nil,
        resourceLoader: CachingAudioResourceLoader? = nil,
        cacheLease: UUID? = nil,
        offlineLease: OfflinePlaybackLease? = nil,
        resumeAt: TimeInterval = 0
    ) async -> ResolvedURLLoadResult {
        // Resolve the asset's audio track before the item goes live: an audio mix
        // attached after playback starts is silently ignored, so the spectrum tap
        // has to be spliced in here or not at all. Unsupported sources and iOS
        // cache hits play untapped and use the decorative UI fallback.
        #if os(iOS)
        // Cached files already have a complete local media source. Keeping their
        // playback path free of a MediaToolbox processing tap avoids rebuilding
        // the custom render pipeline on every rapid cache-to-cache switch.
        let assetTrack = asset.url.isFileURL
            ? nil
            : await loadAudioTrack(from: asset, timeout: 2)
        #else
        let assetTrack = await loadAudioTrack(from: asset, timeout: 2)
        #endif
        guard generation == resolveGeneration,
              resourceLoader.map({ pendingAudioResourceLoader === $0 }) ?? true else {
            resourceLoader?.cancel()
            if let cacheLease {
                releaseAudioCacheLease(cacheLease)
            }
            if let offlineLease { Task { try? await OfflineStore.shared.release(offlineLease) } }
            return .superseded
        }

        let item = AVPlayerItem(asset: asset)
        if let assetTrack,
           let mix = AudioSpectrum.shared.makeAudioMix(for: assetTrack) {
            item.audioMix = mix
        } else {
            AudioSpectrum.shared.markUntappable()
        }

        itemStatusObservation?.invalidate()
        itemStatusObservation = makeItemStatusObservation(
            for: item, track: track, generation: generation,
            sourceID: currentUnblockSourceID, remoteURL: remoteURL, durationMS: durationMS)

        if let old = endObserver {
            NotificationCenter.default.removeObserver(old)
        }
        endObserver = makeEndObserver(for: item)
        let previousResourceLoader = audioResourceLoader
        let previousCacheLease = audioCacheLease
        let previousOfflineLease = offlinePlaybackLease
        if resourceLoader != nil {
            pendingAudioResourceLoader = nil
        }
        audioResourceLoader = resourceLoader
        audioCacheLease = cacheLease
        offlinePlaybackLease = offlineLease
        engine.replaceCurrentItem(with: item)
        installedItem = item
        // Loudness (Folia P8, iOS): retune the per-track volume trim from
        // any in-session analysis, and analyze this file in the background
        // when it is a full local copy — a streamed asset has no file to
        // analyze, so it keeps trim 0 until it is cached and replayed.
        applyLoudnessTrim(for: track)
        if asset.url.isFileURL {
            analyzeForLoudnessIfNeeded(fileURL: asset.url, for: track)
        }
        previousResourceLoader?.cancel()
        if let previousCacheLease {
            releaseAudioCacheLease(previousCacheLease)
        }
        if let previousOfflineLease { Task { try? await OfflineStore.shared.release(previousOfflineLease) } }
        if resumeAt > 0 {
            // The item's own length when known; the published duration may
            // still belong to the previous song or be unknown.
            let length = durationMS.map { TimeInterval($0) / 1000 } ?? duration
            let time = CMTime(seconds: length > 0.1 ? min(resumeAt, length - 0.1) : resumeAt, preferredTimescale: 600)
            _ = await engine.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            guard generation == resolveGeneration else { return .superseded }
        }
        if isPlaying {
            engine.play()
            scrobbleStartIfNeeded()
        }

        if let durationMS, durationMS > 0 {
            duration = TimeInterval(durationMS) / 1000
            NowPlayingManager.shared.updateMetadata(for: track, duration: duration)
        }
        return .loaded
    }

    private func handleUnblockItemFailure(
        track: Track,
        generation: Int,
        sourceID: AudioSourceID
    ) {
        settleDeckBeforeTakeover()
        guard generation == resolveGeneration,
              currentTrack?.id == track.id,
              currentUnblockSourceID == sourceID
        else { return }

        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        currentUnblockSourceID = nil
        unblockSource = nil
        engine.replaceCurrentItem(with: nil)
        releaseCurrentPlaybackResources()
        AudioSpectrum.shared.beginPreparing()

        guard isPlaying else {
            return
        }

        Task {
            let loaded = await resolveAndLoadUnblocked(
                track,
                generation: generation,
                requiresActivePlayback: true
            )
            guard isPlaying else { return }
            guard loaded else {
                guard generation == resolveGeneration else { return }
                handleUnplayable(track)
                return
            }
        }
    }

    /// The song is playing for real: the failure streak is over.
    private func itemBecameReady(generation: Int) {
        guard generation == resolveGeneration else { return }
        consecutiveFailures = 0
    }

    /// An upstream stream or a cached file failed. The song gets one reload,
    /// resuming where it stopped: on the CDN twin when the host could not be
    /// reached (the caching loader already swaps hosts itself, so this covers
    /// streams that bypass it), otherwise from a freshly resolved URL, since a
    /// signature may have expired, the network changed, or the local file
    /// was bad. With no network at all, or when the reload fails for lack of
    /// one, a downloaded copy takes over; any other second failure goes to the
    /// third-party sources, then skips.
    private func handleItemFailure(
        track: Track,
        generation: Int,
        remoteURL: URL?,
        durationMS: Int?,
        error: Error?
    ) {
        settleDeckBeforeTakeover()
        guard generation == resolveGeneration,
              currentTrack?.id == track.id,
              currentUnblockSourceID == nil
        else { return }

        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        engine.replaceCurrentItem(with: nil)
        releaseCurrentPlaybackResources()
        let connectivity = error.map(ConnectivityFailure.matches) ?? false

        guard itemRetryGeneration != generation else {
            if connectivity {
                handleConnectivityItemFailure(track: track, generation: generation)
                return
            }
            Task {
                guard SettingsManager.shared.canResolveUnblockedTracks,
                      await resolveAndLoadUnblocked(track, generation: generation) else {
                    guard generation == resolveGeneration else { return }
                    handleUnplayable(track)
                    return
                }
            }
            return
        }
        itemRetryGeneration = generation
        let twin = remoteURL.flatMap { url in
            error.flatMap { CDNHost.failover(from: url, after: $0) }
        }
        // No network at all: the downloaded copy is the only way on.
        if twin == nil, connectivity, usesOfflineQueue {
            handleConnectivityItemFailure(track: track, generation: generation)
            return
        }
        AudioSpectrum.shared.beginPreparing()
        let resumeAt = progress > 1 ? progress : 0
        Task {
            if let twin {
                _ = await loadResolvedURL(track, url: twin, durationMS: durationMS, generation: generation, resumeAt: resumeAt)
            } else {
                await resolveAndLoad(track, generation: generation, skipsLocalCopies: remoteURL == nil, resumeAt: resumeAt)
            }
        }
    }

    private func releaseAudioCacheLease(_ leaseID: UUID) {
        Task {
            do {
                try await AudioCache.shared.release(leaseID)
            } catch {
                print("Audio cache could not release its playback lease: \(error)")
            }
        }
    }

    private func releaseCurrentPlaybackResources() {
        let resourceLoader = audioResourceLoader
        let cacheLease = audioCacheLease
        audioResourceLoader = nil
        audioCacheLease = nil
        resourceLoader?.cancel()
        if let cacheLease {
            releaseAudioCacheLease(cacheLease)
        }
        releaseOfflineLease()
    }

    /// Resolves the asset's audio track, giving up after `timeout` so a slow or
    /// uncooperative source delays playback no longer than it would today.
    private func loadAudioTrack(from asset: AVURLAsset, timeout: TimeInterval) async -> AVAssetTrack? {
        await withTaskGroup(of: AVAssetTrack?.self) { group in
            group.addTask {
                try? await asset.loadTracks(withMediaType: .audio).first
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Global lyric timeline offset (Folia B12), seconds. 0 when the
    /// Folia master switch is off (see SettingsManager).
    private var lyricOffsetSeconds: TimeInterval {
        TimeInterval(SettingsManager.shared.effectiveGlobalLyricTimelineOffsetMs) / 1000
    }

    private func loadLyrics(for track: Track, generation: Int) async {
        let scope = offlineAccountScope
        if let scope, let saved = await OfflineMetadataStore.shared.lyrics(trackID: track.id, scope: scope) {
            guard generation == resolveGeneration else { return }
            lyrics = LyricsParser.parse(saved).applyingOffset(lyricOffsetSeconds)
            updateLyricsCursor(at: progress)
        }
        guard !usesOfflineQueue else { return }
        let response = await MusicAPI.lyric(for: track)
        guard generation == resolveGeneration, let response else { return }
        lyrics = LyricsParser.parse(response).applyingOffset(lyricOffsetSeconds)
        updateLyricsCursor(at: progress)
        if let scope, SettingsManager.shared.enableAudioCache || DownloadManager.shared.isDownloaded(trackID: track.id) {
            await OfflineMetadataStore.shared.keepPlaybackData(track: track, lyrics: response, scope: scope)
        }
    }

    // MARK: - Offline playback

    /// Downloads belong to one account; see `activateAccount`.
    private var offlineAccountScope: String? { AccountStore.shared.offlineScope }
    private var usesOfflineQueue: Bool { networkState.isKnown && !networkState.connected }

    private func nextCandidates() -> [PlaybackQueueCandidate] {
        PlaybackQueuePlan.next(queue: activeQueue, currentIndex: currentIndex, inserted: playNextList,
                               fm: fmUpcoming, isFM: isFMMode, repeatAll: repeatMode == .all)
    }

    /// Everything the prefetch window depends on. `@Published` fires before
    /// the value lands, so the update itself waits for the next turn.
    private func observePrefetchInputs() {
        let player: [AnyPublisher<Void, Never>] = [
            $queue.map { _ in }.eraseToAnyPublisher(), $shuffledQueue.map { _ in }.eraseToAnyPublisher(),
            $shuffleEnabled.map { _ in }.eraseToAnyPublisher(), $playNextList.map { _ in }.eraseToAnyPublisher(),
            $currentIndex.map { _ in }.eraseToAnyPublisher(), $currentTrack.map { _ in }.eraseToAnyPublisher(),
            $fmUpcoming.map { _ in }.eraseToAnyPublisher(), $isFMMode.map { _ in }.eraseToAnyPublisher(),
            $repeatMode.map { _ in }.eraseToAnyPublisher(), $isPlaying.map { _ in }.eraseToAnyPublisher(),
            $isBuffering.map { _ in }.eraseToAnyPublisher(),
        ]
        let environment: [AnyPublisher<Void, Never>] = [
            DownloadManager.shared.$network.map { _ in }.eraseToAnyPublisher(),
            DownloadManager.shared.$jobs.map { _ in }.eraseToAnyPublisher(),
            SettingsManager.shared.$enableAudioCache.map { _ in }.eraseToAnyPublisher(),
            SettingsManager.shared.$audioQuality.map { _ in }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange).map { _ in }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(player + environment)
            .sink { [weak self] _ in self?.scheduleUpdatePrefetch() }
            .store(in: &prefetchObservations)
    }

    private func scheduleUpdatePrefetch() {
        guard !prefetchUpdateScheduled else { return }
        prefetchUpdateScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.prefetchUpdateScheduled = false
            self.updatePrefetch()
        }
    }

    private func updatePrefetch() {
        guard isPlaying, !isBuffering, SettingsManager.shared.enableAudioCache, let current = currentTrack,
              QueuePrefetcher.permits(network: networkState, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        else { queuePrefetcher.update(nil); return }
        let upcoming = PrefetchLimits().window(nextCandidates().map(\.track))
        guard !upcoming.isEmpty else { queuePrefetcher.update(nil); return }
        let scope = offlineAccountScope
        let pending = Set(DownloadManager.shared.pendingJobs.filter { $0.accountScope == scope }.map(\.track.id))
        queuePrefetcher.update(.init(scope: scope, currentTrackID: current.id, tracks: upcoming,
                                     quality: SettingsManager.shared.audioQuality.rawValue,
                                     allowsUnblock: SettingsManager.shared.canResolveUnblockedTracks,
                                     pendingDownloadTrackIDs: pending))
    }

    /// A downloaded copy of the track. Online it must match the chosen quality
    /// or better; offline, any quality will do.
    private func acquireOfflineLease(for track: Track, generation: Int, reusing lease: OfflinePlaybackLease? = nil,
                                     anyQuality: Bool = false) async -> OfflinePlaybackLease? {
        let scope = offlineAccountScope
        var lease = lease
        if lease == nil, let scope {
            lease = try? await OfflineStore.shared.acquire(accountScope: scope, trackID: track.id,
                preferredQuality: SettingsManager.shared.audioQuality.rawValue,
                allowLowerQuality: anyQuality || !networkState.connected)
        }
        guard let lease else { return nil }
        guard generation == resolveGeneration, scope == offlineAccountScope,
              lease.descriptor.identity.accountScope == scope else {
            try? await OfflineStore.shared.release(lease)
            return nil
        }
        return lease
    }

    private func playOfflineFile(_ lease: OfflinePlaybackLease, for track: Track, generation: Int,
                                 resumeAt: TimeInterval = 0) async {
        servedQuality = lease.descriptor.identity.quality
        _ = await installResolvedAsset(AVURLAsset(url: lease.url), for: track, generation: generation,
                                       durationMS: Int(lease.descriptor.duration * 1000),
                                       offlineLease: lease, resumeAt: resumeAt)
    }

    /// The stream died for lack of network. A download of the same song picks
    /// up where it stopped; otherwise the song is reported or skipped.
    private func handleConnectivityItemFailure(track: Track, generation: Int) {
        settleDeckBeforeTakeover()
        guard generation == resolveGeneration, currentTrack?.id == track.id else { return }
        let position = max(progress, livePlaybackTime)
        resolveGeneration += 1
        let recovery = resolveGeneration
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        engine.replaceCurrentItem(with: nil)
        releaseCurrentPlaybackResources()
        Task {
            if let lease = await acquireOfflineLease(for: track, generation: recovery, anyQuality: true) {
                await playOfflineFile(lease, for: track, generation: recovery, resumeAt: position)
                return
            }
            guard recovery == resolveGeneration else { return }
            unavailableOffline(track, generation: recovery, autoAdvance: currentWasAdvanced && position < 0.5)
        }
    }

    private func releaseOfflineLease() {
        guard let lease = offlinePlaybackLease else { return }
        offlinePlaybackLease = nil
        Task { try? await OfflineStore.shared.release(lease) }
    }

    private func unavailableOffline(_ track: Track, generation: Int, autoAdvance: Bool? = nil) {
        settleDeckBeforeTakeover()
        guard generation == resolveGeneration else { return }
        if autoAdvance ?? currentWasAdvanced {
            advanceOffline(initialSkipped: 1, excludingFailedCurrent: true)
            return
        }
        engine.replaceCurrentItem(with: nil)
        releaseCurrentPlaybackResources()
        isPlaying = false
        isBuffering = false
        offlineIssue = .init(kind: .missingTrack, trackName: track.name)
        NowPlayingManager.shared.updateElapsed(progress, rate: 0)
    }

    func playNextAvailableOffline() {
        offlineIssue = nil
        advanceOffline()
    }

    /// Walks the upcoming list for the first song that is on this device.
    private func advanceOffline(initialSkipped: Int = 0, excludingFailedCurrent: Bool = false) {
        settleDeckBeforeTakeover()
        offlineScan?.cancel()
        let requestID = UUID()
        offlineScanID = requestID
        resolveGeneration += 1
        let generation = resolveGeneration
        let scope = offlineAccountScope
        var candidates = nextCandidates()
        if excludingFailedCurrent { candidates.removeAll { $0.origin == .queue(currentIndex) } }
        engine.replaceCurrentItem(with: nil)
        releaseCurrentPlaybackResources()
        isPlaying = false
        offlineScan = Task { [weak self] in
            guard let self, !Task.isCancelled, self.offlineScanID == requestID else { return }
            let selected = try? await OfflineQueueSelector.firstAvailable(candidates, scope: scope,
                quality: SettingsManager.shared.audioQuality.rawValue, store: .shared,
                isCached: { await self.isCachedForOffline($0) })
            guard !Task.isCancelled, self.offlineScanID == requestID, self.resolveGeneration == generation,
                  self.offlineAccountScope == scope else {
                if let lease = selected?.lease { try? await OfflineStore.shared.release(lease) }
                return
            }
            self.offlineScan = nil
            guard let selected else {
                self.pendingAutoAdvance = false
                self.offlineIssue = .init(kind: .emptyQueue, trackName: nil)
                self.isBuffering = false
                NowPlayingManager.shared.updateElapsed(self.progress, rate: 0)
                return
            }
            // The queue may have been edited while the scan ran.
            guard self.stillHolds(selected.candidate) else {
                if let lease = selected.lease { try? await OfflineStore.shared.release(lease) }
                self.advanceOffline(initialSkipped: initialSkipped, excludingFailedCurrent: excludingFailedCurrent)
                return
            }
            switch selected.candidate.origin {
            case .inserted(let index): self.playNextList.removeSubrange(0...index)
            case .queue(let index):
                if !self.playNextList.isEmpty { self.playNextList.removeAll() }
                self.currentIndex = index
            case .fm(let index): self.fmUpcoming.removeSubrange(0...index)
            }
            let skipped = initialSkipped + selected.skipped
            self.pendingAutoAdvance = true
            self.startPlaying(selected.candidate.track, localLease: selected.lease)
            if skipped > 0 { ToastCenter.shared.show(String(localized: "已跳过 \(skipped) 首未下载歌曲")) }
        }
    }

    /// Whether the song cache can play the track without the network.
    private func isCachedForOffline(_ trackID: Int) async -> Bool {
        guard SettingsManager.shared.enableAudioCache else { return false }
        let allowsUnblock = SettingsManager.shared.canResolveUnblockedTracks
        return (try? await AudioCache.shared.fallbackEntry(for: trackID, allowsUnblock: allowsUnblock)) != nil
    }

    private func stillHolds(_ candidate: PlaybackQueueCandidate) -> Bool {
        switch candidate.origin {
        case .inserted(let index): return playNextList.indices.contains(index) && playNextList[index].id == candidate.track.id
        case .queue(let index): return activeQueue.indices.contains(index) && activeQueue[index].id == candidate.track.id
        case .fm(let index): return fmUpcoming.indices.contains(index) && fmUpcoming[index].id == candidate.track.id
        }
    }

    /// Downloads belong to one account. Audio leased under the previous
    /// account stops, and the offline queue scan starts over.
    func activateAccount(scope: String?) {
        guard offlineActivatedScope != scope else { return }
        offlineActivatedScope = scope
        settleDeckBeforeTakeover()
        discardPrepared()
        offlineScan?.cancel()
        offlineScan = nil
        offlineScanID = UUID()
        offlineIssue = nil
        scheduleUpdatePrefetch()
        guard offlinePlaybackLease != nil else { return }
        resolveGeneration += 1
        engine.replaceCurrentItem(with: nil)
        releaseCurrentPlaybackResources()
        isPlaying = false
        NowPlayingManager.shared.updateElapsed(progress, rate: 0)
    }

    // MARK: - Scrobble

    private func scrobbleStartIfNeeded() {
        guard SettingsManager.shared.effectiveNetEaseScrobbleEnabled else { return }
        guard let track = currentTrack, !startScrobbled else { return }
        startScrobbled = true
        let trackID = track.id
        let sourceID = source.sourceID
        Task.detached {
            await MusicAPI.scrobbleStart(trackID: trackID, sourceID: sourceID)
        }
    }

    private func scrobbleIfNeeded(completed: Bool) {
        guard SettingsManager.shared.effectiveNetEaseScrobbleEnabled else { return }
        guard let track = currentTrack, !scrobbled, progress > 1 else { return }
        scrobbled = true
        let seconds = completed ? Int(duration) : Int(progress)
        let sourceID = source.sourceID
        Task.detached {
            await MusicAPI.scrobbleFinish(trackID: track.id, sourceID: sourceID, seconds: seconds)
        }
    }

    // MARK: - Shuffle helpers

    private func reshuffle(keeping first: Track) {
        var rest = queue
        if let index = rest.firstIndex(where: { $0.id == first.id }) { rest.remove(at: index) }
        rest.shuffle()
        shuffledQueue = [first] + rest
    }

    // MARK: - Persistence

    private static let recentContextsLimit = 6

    private func recordRecent(_ context: PlayContext) {
        recentContexts.removeAll { $0 == context }
        recentContexts.insert(context, at: 0)
        if recentContexts.count > Self.recentContextsLimit {
            recentContexts.removeLast(recentContexts.count - Self.recentContextsLimit)
        }
    }

    /// Reloads a place from the recents list and starts playing it again.
    func play(context: PlayContext) {
        // Personal FM is a stream, not a fixed list — restart it in place.
        guard context.kind != .fm else { return startFM() }
        Task {
            do {
                guard let resolved = try await resolve(context) else { return }
                play(tracks: resolved.tracks, source: resolved.source, context: context)
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    func resolve(_ context: PlayContext) async throws -> (tracks: [Track], source: PlaySource)? {
        try await OfflineContextResolver.resolve(context, offline: usesOfflineQueue) { try await resolveOnline(context) }
    }

    private func resolveOnline(_ context: PlayContext) async throws -> (tracks: [Track], source: PlaySource)? {
        switch context.kind {
        case .fm:
            return nil
        case .album:
            return (try await MusicAPI.album(id: context.id).songs, .album(context.id))
        case .artist:
            return (try await MusicAPI.artist(id: context.id).hotSongs, .artist(context.id))
        case .daily:
            return (try await MusicAPI.dailyRecommendSongs(), .daily)
        case .cloud:
            let songs = try await MusicAPI.cloudSongs().data?.compactMap(\.simpleSong) ?? []
            return (songs, .cloud)
        case .recents:
            guard let uid = AccountStore.shared.profile?.userId else { return nil }
            return (try await MusicAPI.playRecords(uid: uid, week: false).map(\.song), .none)
        case .heartbeat:
            // Regenerated from a fresh seed, the same way the Home card does it.
            guard let liked = AccountStore.shared.likedSongsPlaylist,
                  let seed = AccountStore.shared.likedTrackIDs.randomElement() else { return nil }
            let tracks = try await MusicAPI.intelligenceList(songID: seed, playlistID: liked.id)
            return (tracks, .playlist(liked.id))
        case .playlist:
            let response = try await MusicAPI.playlistDetail(id: context.id)
            var tracks = response.playlist.tracks
            // /v6/playlist/detail only carries the first page of tracks.
            let remaining = response.playlist.trackIds.map(\.id).dropFirst(tracks.count)
            for chunk in stride(from: 0, to: remaining.count, by: 500)
                .map({ Array(remaining.dropFirst($0).prefix(500)) }) {
                guard let more = try? await MusicAPI.songDetails(ids: chunk) else { break }
                tracks += more.songs
            }
            return (tracks, .playlist(context.id))
        }
    }

    var playbackSession: PlaybackSession? {
        guard let currentTrack else { return nil }
        return PlaybackSession(accountID: playbackAccountID, queue: queue, orderedQueue: activeQueue,
                               currentIndex: currentIndex, currentTrack: currentTrack, playNext: playNextList,
                               source: source, repeatMode: repeatMode.rawValue, shuffled: shuffleEnabled,
                               automaticOrder: false, isFM: isFMMode, progress: progress)
    }

    func resume(_ session: PlaybackSession) throws {
        let accountID = AccountStore.shared.authenticatedAccountID
        try session.validateAccess(accountID: accountID)
        scrobbleIfNeeded(completed: false)
        pause()
        applyPlaybackSession(session)
        startPlaying(session.currentTrack, resumeAt: session.progress)
    }

    private func applyPlaybackSession(_ session: PlaybackSession) {
        // Materialize a Mac AutoMix order on iOS, which has no AutoMix engine.
        queue = session.automaticOrder ? session.orderedQueue : session.queue
        shuffledQueue = session.shuffled ? session.orderedQueue : []
        shuffleEnabled = session.shuffled
        currentIndex = session.currentIndex
        currentTrack = session.currentTrack
        playbackAccountID = session.accountID
        playNextList = session.playNext
        source = session.source
        if let mode = RepeatMode(rawValue: session.repeatMode) { repeatMode = mode }
        isFMMode = session.isFM
        fmUpcoming = []
        progress = session.progress
        duration = session.currentTrack.duration
        scrobbled = true
    }

    func checkpointPlayback() { persistState() }

    func suspendForAccountChange() {
        settleDeckBeforeTakeover()
        discardPrepared()
        resolveGeneration += 1
        scrobbled = true
        pause()
        pendingAudioResourceLoader?.cancel()
        pendingAudioResourceLoader = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        engine.replaceCurrentItem(with: nil)
        releaseCurrentPlaybackResources()
    }

    private func persistState() {
        lastPlaybackCheckpoint = .now
        let state = PlaybackState(session: playbackSession, recentContexts: recentContexts)
        PlaybackStateStorage.save(state, to: Self.stateFileURL)
    }

    private func restoreState() {
        guard let data = try? Data(contentsOf: Self.stateFileURL),
              let state = try? JSONDecoder().decode(PlaybackState.self, from: data)
        else { return }
        // Recents outlive the queue: restore them before bailing out on an
        // empty queue, or the next played track persists an empty list over
        // them and the Dock menu loses its history for good.
        recentContexts = Array((state.recentContexts ?? []).prefix(Self.recentContextsLimit))
        if let session = state.session {
            do {
                try session.validate()
                applyPlaybackSession(session)
                NowPlayingManager.shared.updateMetadata(for: session.currentTrack, duration: duration)
            } catch { ToastCenter.shared.show(error.localizedDescription) }
            return
        }
        guard let legacy = state.legacy, !legacy.queue.isEmpty else { return }
        queue = legacy.queue
        shuffleEnabled = legacy.shuffle
        if shuffleEnabled {
            shuffledQueue = queue.shuffled()
        }
        if let id = legacy.currentID,
           let idx = activeQueue.firstIndex(where: { $0.id == id }) {
            currentIndex = idx
            currentTrack = activeQueue[idx]
            duration = activeQueue[idx].duration
            NowPlayingManager.shared.updateMetadata(for: activeQueue[idx], duration: duration)
            Task {
                await loadLyrics(for: activeQueue[idx], generation: resolveGeneration)
            }
        }
    }

    private static var stateFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kumone", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("player-state.json")
    }
}
#endif

// MARK: - Folia playback settings: pure helpers
//
// These live outside the `#if os(iOS)` gate above on purpose. The iOS
// player class cannot compile on macOS, so anything the macOS `swift test`
// run is meant to cover has to live here, in platform-independent code.

/// C1 (Folia P9): pause/resume volume ramp.
enum PlaybackFade {
    /// 20 steps x 20 ms = 0.4 s, inside the 0.3–0.5 s window the plan asks for.
    static let defaultSteps = 20
    static let stepIntervalMilliseconds = 20

    /// Linear ramp from `start` to `end`, excluding `start`, including `end`.
    /// `steps` is clamped to at least 1 so the result always ends at `end`.
    static func volumes(from start: Float, to end: Float, steps: Int) -> [Float] {
        let steps = max(1, steps)
        return (1...steps).map { start + (end - start) * Float($0) / Float(steps) }
    }
}

/// C2 (Folia P11): append-to-end queue arithmetic.
enum QueueAppend {
    /// Appends `track` to the end of the underlying queue, and to the
    /// shuffled queue too whenever one is live (shuffle on, or a stale
    /// shuffled order left over from an earlier shuffle), so both orders
    /// keep the same tracks and `activeQueue` stays consistent either way.
    static func appended(queue: [Track], shuffledQueue: [Track], shuffleEnabled: Bool, track: Track)
        -> (queue: [Track], shuffledQueue: [Track])
    {
        var queue = queue
        queue.append(track)
        var shuffledQueue = shuffledQueue
        if shuffleEnabled || !shuffledQueue.isEmpty {
            shuffledQueue.append(track)
        }
        return (queue, shuffledQueue)
    }
}

/// B7 (Folia P12): auto-skip decision for an unplayable track.
enum UnplayableSkip {
    /// Auto-skip only for tracks the metadata rules out. `.playable` means
    /// the failure was transient (no network reason exists in
    /// `TrackPlayability`), so it never auto-skips.
    static func shouldAutoSkip(playability: TrackPlayability, autoSkipEnabled: Bool) -> Bool {
        autoSkipEnabled && playability != .playable
    }
}

/// B8: entry-view decision for a user-initiated play.
enum PlaybackEntry {
    /// `.nowPlaying` opens the now-playing page; `.stay` leaves the current
    /// page alone.
    static func shouldOpenNowPlaying(for entryView: PlaybackEntryView) -> Bool {
        entryView == .nowPlaying
    }
}

/// iOS crossfade (Folia P2/P3): the pure math behind the dual-deck overlap —
/// the equal-power ramp, the timed plan used when no analysis exists, and the
/// user-settings → planner-config mapping (mirroring macOS
/// `PlayerService.transitionPlannerConfig`).
enum CrossfadeTransition {
    /// Equal-power crossfade gains at `t` (0 = outgoing only, 1 = incoming
    /// only): out falls as cos, in rises as sin, so out² + in² stays 1 and
    /// the summed power is flat across the seam. `t` is clamped to 0...1.
    static func equalPowerGains(at t: Double) -> (outGain: Float, inGain: Float) {
        let t = min(1, max(0, t))
        return (Float(cos(t * .pi / 2)), Float(sin(t * .pi / 2)))
    }

    /// A plain timed crossfade with no analysis: the overlap is the user's
    /// maximum, capped at a quarter of the shorter track, and the hand-over
    /// starts that far before the outgoing track ends. Returns nil when the
    /// overlap would be under the planner's 2 s minimum — the pair is too
    /// short to blend, so the cut stays a hard cut.
    static func timedCrossfade(outgoingDuration: TimeInterval, incomingDuration: TimeInterval,
                               maxSeconds: Double) -> (duration: TimeInterval, outPoint: TimeInterval, inPoint: TimeInterval)? {
        let overlap = min(maxSeconds, 0.25 * min(outgoingDuration, incomingDuration))
        guard overlap >= 2 else { return nil }
        return (duration: overlap, outPoint: outgoingDuration - overlap, inPoint: 0)
    }

    /// Maps the user's transition settings onto the planner config fields
    /// they own: the hand-over mode, and — in crossfade mode only — the
    /// overlap ceiling. `.automix` leaves the config exactly as `base` (the
    /// shipped planner).
    static func plannerConfig(mode: TransitionMode, crossfadeMaxSeconds: Double,
                              base: TransitionPlanner.Config = .standard) -> TransitionPlanner.Config {
        var config = base
        config.handoverMode = mode == .crossfade ? .crossfade : .automix
        if mode == .crossfade {
            config.maxOverlap = min(crossfadeMaxSeconds,
                                    TransitionPlanner.Config.standard.maxOverlap)
        }
        return config
    }
}
