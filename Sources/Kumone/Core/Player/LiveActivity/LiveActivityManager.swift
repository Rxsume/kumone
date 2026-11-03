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
/// expanded view and lock-screen banner open `rumxs://now-playing`, and its
/// controls open `rumxs://toggle-play` / `rumxs://next`, which the app
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
    private var lastSentState: RumxsLiveActivityAttributes.ContentState?
    private var lastSentTrackID: Int?
    private var artworkTrackID: Int?
    private var artworkFileName: String?

    private init() {}

    /// Subscribes to the player's published state. Idempotent: calling it
    /// again for the same player is a no-op; for a different player it
    /// re-subscribes and drops the old activity.
    func attach(to player: PlayerService) {
        if self.player === player, !cancellables.isEmpty { return }
        detach()
        self.player = player
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
        syncIfNeeded()
    }

    private func detach() {
        cancellables.removeAll()
        progressTask?.cancel()
        progressTask = nil
        artworkTask?.cancel()
        artworkTask = nil
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
        // accurate. The old one is dismissed immediately; the new one is
        // requested right away (with no artwork yet) so the island never
        // waits on the thumbnail download.
        if let previous = activity {
            activity = nil
            Task { await previous.end(dismissalPolicy: .immediate) }
        }
        lastSentState = nil
        lastSentTrackID = nil
        artworkFileName = (artworkTrackID == track.id) ? artworkFileName : nil
        requestActivity(for: track)
        artworkTask?.cancel()
        if artworkTrackID != track.id {
            artworkTask = Task { [weak self] in
                let fileName = await self?.prepareArtwork(for: track)
                guard let self, !Task.isCancelled,
                      self.player?.currentTrack?.id == track.id else { return }
                self.artworkFileName = fileName
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
        guard let player, player.isPlaying, player.currentTrack != nil, activity != nil else { return }
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
            nextLyric: next
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
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let player else { return }
        let state = makeState(for: track, player: player)
        let attributes = RumxsLiveActivityAttributes(trackID: track.id)
        do {
            activity = try Activity.request(
                attributes: attributes,
                contentState: state,
                pushType: nil
            )
            lastSentState = state
            lastSentTrackID = track.id
        } catch {
            activity = nil
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
        guard let activity else { return }
        self.activity = nil
        lastSentState = nil
        lastSentTrackID = nil
        Task { await activity.end(dismissalPolicy: .default) }
    }

    // MARK: - Artwork

    /// Fetches the cover through the existing image cache and writes a ~120px
    /// JPEG thumbnail into the shared container for the widget extension to
    /// read. Returns the file name, or nil when the container is unavailable
    /// (no App Group entitlement, e.g. an unsigned build) or the fetch fails
    /// — the widget then shows its placeholder.
    private func prepareArtwork(for track: Track) async -> String? {
        guard let url = track.album.picUrl?.resizedImageURL(120) else { return nil }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: RumxsLiveActivityConstants.appGroupIdentifier
        ) else { return nil }
        let directory = container.appendingPathComponent(
            RumxsLiveActivityConstants.artworkDirectoryName,
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileName = "artwork-\(track.id).jpg"
            let destination = directory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: destination.path) { return fileName }
            guard let image = await ImageCache.shared.image(for: url),
                  let data = image.jpegData(compressionQuality: 0.85) else { return nil }
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
            return fileName
        } catch {
            return nil
        }
    }
}
#endif
