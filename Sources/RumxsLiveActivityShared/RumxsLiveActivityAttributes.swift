import Foundation

/// Shared constants for the Rumxs Live Activity. This file lives in the
/// RumxsLiveActivityShared library, the one module both the app
/// (KumoneCore) and the RumxsLiveActivity widget extension import.
/// ActivityKit matches an activity to its widget by the attributes
/// type's identity, so the type must be defined in exactly one module:
/// compiling the same source file into two targets creates two distinct
/// types with the same name and the island stays empty.
public enum RumxsLiveActivityConstants {
    /// URL scheme for island / lock-screen taps. `rumxs://now-playing` opens
    /// the player page; `rumxs://toggle-play`, `rumxs://next` and
    /// `rumxs://previous` perform the action and land on the player page.
    public static let urlScheme = "rumxs"
    /// App Group shared by the app and the widget extension. Artwork
    /// thumbnails live here; both targets carry the entitlement.
    public static let appGroupIdentifier = "group.sb.moe.kumone"
    /// Subdirectory of the shared container holding artwork thumbnails.
    public static let artworkDirectoryName = "LiveActivity"
}

#if os(iOS)
import ActivityKit

/// The Dynamic Island / Live Activity for the current track.
///
/// The content state is deliberately small: text and numbers only, no image
/// data. Artwork travels as a thumbnail file in the shared container and the
/// state only names it, so updates stay cheap and the island never waits on
/// a download.
@available(iOS 16.1, *)
public struct RumxsLiveActivityAttributes: ActivityAttributes, Codable, Hashable, Sendable {
    /// The track this activity was requested for. Track changes end the old
    /// activity and request a new one, so this stays accurate.
    public var trackID: Int

    public init(trackID: Int) {
        self.trackID = trackID
    }

    public struct ContentState: Codable, Hashable, Sendable {
        public var title: String
        public var artist: String
        public var album: String
        /// File name of the ~120px JPEG thumbnail in the shared container's
        /// LiveActivity directory, e.g. "artwork-123456.jpg". Nil shows the
        /// placeholder note icon in the widget.
        public var artworkFileName: String?
        public var isPlaying: Bool
        /// Playback position in seconds at the time of this update.
        public var progress: TimeInterval
        public var duration: TimeInterval
        /// Lyric lines around the current line. The island cannot scroll, so
        /// only these three static lines are shown, current line emphasized.
        public var previousLyric: String?
        public var currentLyric: String?
        public var nextLyric: String?

        public init(
            title: String,
            artist: String,
            album: String,
            artworkFileName: String?,
            isPlaying: Bool,
            progress: TimeInterval,
            duration: TimeInterval,
            previousLyric: String?,
            currentLyric: String?,
            nextLyric: String?
        ) {
            self.title = title
            self.artist = artist
            self.album = album
            self.artworkFileName = artworkFileName
            self.isPlaying = isPlaying
            self.progress = progress
            self.duration = duration
            self.previousLyric = previousLyric
            self.currentLyric = currentLyric
            self.nextLyric = nextLyric
        }
    }
}
#endif
