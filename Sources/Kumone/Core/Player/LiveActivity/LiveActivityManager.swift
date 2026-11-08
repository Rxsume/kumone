#if os(iOS)
import ActivityKit
import Combine
import Foundation
import RumxsLiveActivityShared
import UIKit

/// Owns the Rumxs Live Activity (Dynamic Island + lock screen) for the
/// currently playing track.
///
/// Driven from `NowPlayingManager.attach(to:)` — the one place playback
/// state is already observed — and kept in sync with the player's published
/// state. Updates are coalesced: track changes, play/pause, duration and
/// lyric-line changes push immediately, while playback progress refreshes
/// on a 5-second tick. Nothing here ever crashes: every ActivityKit and
/// file operation is failure-tolerant, and a missing shared container or
/// disabled Live Activities simply means no activity is shown.
///
/// Coexists with the system Now Playing surface (`MPNowPlayingSession` in
/// `NowPlayingManager`), which remains the Control Center / lock-screen
/// fallback. The Live Activity is the Dynamic Island mechanism: its
/// expanded view and lock-screen banner open `golia://player`, and its
/// controls open `golia://toggle-play` / `golia://next`, which the app
/// routes to the player page.
@MainActor
@available(iOS 16.1, *)
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private weak var player: PlayerService?
    private var cancellables: Set<AnyCancellable> = []
    private var activity: Activity<RumxsLiveActivityAttributes>?
    private var progressTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var replacementTask: Task<Void, Never>?
    private var activityStateTask: Task<Void, Never>?
    private var lastSentState: RumxsLiveActivityAttributes.ContentState?
    private var lastSentTrackID: Int?
    private var artworkTrackID: Int?
    private var artworkFileName: String?
    private var artworkPrimaryHex: String?
    private var artworkSecondaryHex: String?

    private init() {}

    /// Subscribes to the player's published state. Idempotent: calling it
    /// again for the same player is a no-op; for a different player it
    /// re-subscribes and drops the old activity.
    func attach(to player: PlayerService) {
        if self.player === player, !cancellables.isEmpty { return }
        detach()
        self.player = player
        // Activities survive app termination, so a previous run may have
        // left one behind that this run never adopted. Snapshot the orphans
        // synchronously — before the subscriptions below can deliver and
        // request a fresh activity — so the cleanup below can never catch
        // the fresh activity itself.
        let orphans = Activity<RumxsLiveActivityAttributes>.activities
        player.$currentTrack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.trackDidChange() }
            .store(in: &cancellables)
        player.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncIfNeeded() }
            .store(in: &cancellables)
        player.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncIfNeeded() }
            .store(in: &cancellables)
        player.lyricsCursor.$activeIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncIfNeeded() }
            .store(in: &cancellables)
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.syncProgressTick()
            }
        }
        // End the orphans, then run the first sync, so at most one Rumxs
        // activity exists and it is the fresh one for the current track.
        // The ends are awaited rather than fired-and-forgotten: requesting
        // while an old activity is still ending can throw.
        Task { [weak self] in
            for orphan in orphans {
                await orphan.end(dismissalPolicy: .immediate)
            }
            guard let self, !Task.isCancelled else { return }
            self.syncIfNeeded()
        }
    }

    private func detach() {
        cancellables.removeAll()
        progressTask?.cancel()
        progressTask = nil
        artworkTask?.cancel()
        artworkTask = nil
        replacementTask?.cancel()
        replacementTask = nil
        activityStateTask?.cancel()
        activityStateTask = nil
        player = nil
        endActivity()
    }

    // MARK: - Sync

    private func trackDidChange() {
        guard let player, let track = player.currentTrack else {
            endActivity()
            return
        }
        // A new track replaces the activity so attributes.trackID stays
        // accurate. The old one must finish ending before the new one is
        // requested: requesting while the old activity is still ending can
        // throw, which used to leave the island dead with nothing retrying
        // it. The replacement runs in one Task so the end and the request
        // stay serialized even when tracks change in quick succession, and
        // the new request is only made while this track is still current.
        // Artwork still loads in parallel below — the island never waits
        // on the thumbnail download.
        let previousActivity = activity
        activity = nil
        // The old activity's state observer dies with the old activity; the
        // replacement gets its own observer from requestActivity(for:).
        activityStateTask?.cancel()
        activityStateTask = nil
        replacementTask?.cancel()
        replacementTask = Task { [weak self] in
            if let previousActivity {
                await previousActivity.end(dismissalPolicy: .immediate)
            }
            guard let self, !Task.isCancelled,
                  self.player?.currentTrack?.id == track.id else { return }
            self.requestActivity(for: track)
        }
        lastSentState = nil
        lastSentTrackID = nil
        artworkFileName = (artworkTrackID == track.id) ? artworkFileName : nil
        artworkPrimaryHex = (artworkTrackID == track.id) ? artworkPrimaryHex : nil
        artworkSecondaryHex = (artworkTrackID == track.id) ? artworkSecondaryHex : nil
        artworkTask?.cancel()
        if artworkTrackID != track.id {
            artworkTask = Task { [weak self] in
                let artwork = await self?.prepareArtwork(for: track)
                guard let self, !Task.isCancelled,
                      self.player?.currentTrack?.id == track.id else { return }
                self.artworkFileName = artwork?.fileName
                self.artworkPrimaryHex = artwork?.primaryHex
                self.artworkSecondaryHex = artwork?.secondaryHex
                self.artworkTrackID = track.id
                self.syncIfNeeded()
            }
        }
    }

    private func syncIfNeeded() {
        guard let player, let track = player.currentTrack else {
            endActivity()
            return
        }
        if activity == nil {
            requestActivity(for: track)
            return
        }
        if lastSentTrackID != track.id {
            trackDidChange()
            return
        }
        let state = makeState(for: track, player: player)
        guard state != lastSentState else { return }
        pushUpdate(state)
    }

    private func syncProgressTick() async {
        guard let player, player.isPlaying, player.currentTrack != nil else { return }
        // No `activity != nil` guard here on purpose: syncIfNeeded()
        // requests when activity is nil, so this tick also retries a
        // request that threw during a track change instead of leaving the
        // island dead until some other state change happens.
        syncIfNeeded()
    }

    private func makeState(
        for track: Track,
        player: PlayerService
    ) -> RumxsLiveActivityAttributes.ContentState {
        let duration = player.duration > 0 ? player.duration : track.duration
        let (previous, current, next) = lyricLines(player: player)
        return RumxsLiveActivityAttributes.ContentState(
            title: track.name,
            artist: track.artistNames,
            album: track.album.name,
            artworkFileName: artworkFileName,
            isPlaying: player.isPlaying,
            progress: max(0, player.progress),
            duration: max(0, duration),
            previousLyric: previous,
            currentLyric: current,
            nextLyric: next,
            artworkPrimaryHex: artworkPrimaryHex,
            artworkSecondaryHex: artworkSecondaryHex
        )
    }

    private func lyricLines(player: PlayerService) -> (String?, String?, String?) {
        guard let lyrics = player.lyrics, !lyrics.lines.isEmpty,
              let index = player.lyricsCursor.activeIndex,
              lyrics.lines.indices.contains(index) else { return (nil, nil, nil) }
        let lines = lyrics.lines
        let previous = index > 0 ? lines[index - 1].text : nil
        let current = lines[index].text
        let next = index + 1 < lines.count ? lines[index + 1].text : nil
        return (previous, current, next)
    }

    // MARK: - ActivityKit

    private func requestActivity(for track: Track) {
        // Defensive no-op: a live activity is only ever replaced via
        // trackDidChange(), which clears `activity` first. This keeps a
        // second request from racing a pending replacement.
        guard activity == nil else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let player else { return }
        let state = makeState(for: track, player: player)
        let attributes = RumxsLiveActivityAttributes(trackID: track.id)
        do {
            let newActivity = try Activity.request(
                attributes: attributes,
                contentState: state,
                pushType: nil
            )
            activity = newActivity
            lastSentState = state
            lastSentTrackID = track.id
            observeActivityState(newActivity)
        } catch {
            activity = nil
        }
    }

    /// Watches the activity's own state so a dismissal is noticed. When the
    /// user swipes the lock-screen banner away, or iOS ends the activity,
    /// nothing else in this manager would ever learn: `syncIfNeeded()` sees
    /// a non-nil `activity` and keeps pushing updates into a dead activity,
    /// and the island falls back to the system Now Playing view, whose taps
    /// have no golia:// routing. On a terminal state for the *current*
    /// activity, drop the dead reference and re-request while playback
    /// continues. `.stale` is ignored — the regular updates keep
    /// `staleDate` fresh.
    private func observeActivityState(_ activity: Activity<RumxsLiveActivityAttributes>) {
        activityStateTask?.cancel()
        activityStateTask = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard let self, !Task.isCancelled else { return }
                // A stale observer must never kill a newer activity: only
                // the activity this task was started for may clear the
                // manager's reference.
                guard self.activity === activity else { return }
                let isTerminal: Bool
                if #available(iOS 16.2, *) {
                    isTerminal = (state == .ended || state == .dismissed)
                } else {
                    isTerminal = (state == .ended)
                }
                guard isTerminal else { continue }
                self.activity = nil
                self.lastSentState = nil
                self.lastSentTrackID = nil
                self.activityStateTask?.cancel()
                self.activityStateTask = nil
                // Re-request only while playback continues. A dismissal
                // while paused stays dead out of respect for the
                // dismissal; the next play press re-requests through the
                // $isPlaying sink, since syncIfNeeded() requests when
                // activity is nil. If the user answered "Don't allow" on
                // iOS's keep-allowing prompt, requestActivity's
                // areActivitiesEnabled gate refuses — nothing here
                // overrides that; the user must re-enable Live Activities
                // in Settings.
                guard let player = self.player, player.currentTrack != nil,
                      player.isPlaying else { return }
                self.syncIfNeeded()
                return
            }
        }
    }

    private func pushUpdate(_ state: RumxsLiveActivityAttributes.ContentState) {
        guard let activity else { return }
        lastSentState = state
        let stale = Date().addingTimeInterval(8 * 3600)
        Task {
            if #available(iOS 16.2, *) {
                await activity.update(ActivityContent(state: state, staleDate: stale))
            } else {
                await activity.update(using: state)
            }
        }
    }

    private func endActivity() {
        artworkTask?.cancel()
        artworkTask = nil
        activityStateTask?.cancel()
        activityStateTask = nil
        guard let activity else { return }
        self.activity = nil
        lastSentState = nil
        lastSentTrackID = nil
        Task { await activity.end(dismissalPolicy: .default) }
    }

    // MARK: - Artwork

    /// Fetches the cover through the existing image cache and writes a ~120px
    /// JPEG thumbnail into the shared container for the widget extension to
    /// read. Returns the file name plus the artwork palette as hex strings
    /// for the island tint, or nils when the container is unavailable
    /// (no App Group entitlement, e.g. an unsigned build) or the fetch fails
    /// — the widget then shows its placeholder on a plain black island.
    /// The palette is extracted from the same image, keyed by the raw
    /// artwork URL string exactly like `NowPlayingArtworkStore`, so the
    /// two surfaces share one palette cache entry per track.
    private func prepareArtwork(for track: Track) async -> (
        fileName: String?, primaryHex: String?, secondaryHex: String?
    ) {
        guard let picUrl = track.album.picUrl,
              let url = picUrl.resizedImageURL(120) else { return (nil, nil, nil) }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: RumxsLiveActivityConstants.appGroupIdentifier
        ) else { return (nil, nil, nil) }
        let directory = container.appendingPathComponent(
            RumxsLiveActivityConstants.artworkDirectoryName,
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileName = "artwork-\(track.id).jpg"
            let destination = directory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: destination.path) {
                // Thumbnail already cached: the palette still comes from the
                // in-memory image cache when available, so a repeated track
                // keeps its island tint; otherwise the hexes stay nil.
                let hexes = paletteHexes(for: url, cacheKey: picUrl)
                return (fileName, hexes?.primary, hexes?.secondary)
            }
            guard let image = await ImageCache.shared.image(for: url),
                  let data = image.jpegData(compressionQuality: 0.85) else { return (nil, nil, nil) }
            try data.write(to: destination, options: [.atomic])
            // Drop thumbnails from other tracks so the container never grows.
            if let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) {
                for file in files where file.lastPathComponent.hasPrefix("artwork-")
                    && file.lastPathComponent != fileName {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            let hexes = ArtworkPalette.extract(from: image, cacheKey: picUrl).hexPair
            return (fileName, hexes.primary, hexes.secondary)
        } catch {
            return (nil, nil, nil)
        }
    }

    /// Best-effort palette for an already-cached thumbnail: only the
    /// in-memory image cache can supply the pixels without a fetch.
    private func paletteHexes(
        for url: URL,
        cacheKey: String
    ) -> (primary: String, secondary: String)? {
        guard let image = ImageCache.shared.cachedImage(for: url) else { return nil }
        return ArtworkPalette.extract(from: image, cacheKey: cacheKey).hexPair
    }
}
#endif
