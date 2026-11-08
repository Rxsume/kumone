#if os(iOS)
import Foundation
import RumxsLiveActivityShared

/// Handles `golia://` URLs (and legacy `rumxs://` URLs) opened from the
/// Live Activity island / lock screen (and anywhere else the scheme is
/// opened). The player page is driven by `PlayerService.showNowPlaying`,
/// which `IOSMainWindow` already presents, so routing is just setting
/// state / calling the existing player actions. Unknown hosts are ignored.
@MainActor
enum RumxsDeepLink {
    static func handle(_ url: URL, player: PlayerService) {
        guard url.scheme == RumxsLiveActivityConstants.urlScheme
            || url.scheme == "rumxs" else { return }
        switch url.host {
        case "player":
            player.showNowPlaying = true
        case "now-playing":
            player.showNowPlaying = true
        case "toggle-play":
            player.togglePlayPause()
            player.showNowPlaying = true
        case "next":
            player.next()
            player.showNowPlaying = true
        case "previous":
            player.previous()
            player.showNowPlaying = true
        default:
            break
        }
    }
}
#endif
