import ActivityKit
import RumxsLiveActivityShared
import SwiftUI
import UIKit
import WidgetKit

/// Deep-link destinations for island / lock-screen taps. The literals are
/// fixed, so the URLs always construct.
private enum RumxsLiveActivityLink {
    static let nowPlaying = URL(string: "\(RumxsLiveActivityConstants.urlScheme)://now-playing")!
    static let togglePlay = URL(string: "\(RumxsLiveActivityConstants.urlScheme)://toggle-play")!
    static let next = URL(string: "\(RumxsLiveActivityConstants.urlScheme)://next")!
}

/// Renders the Rumxs Live Activity on the Dynamic Island and the lock
/// screen. v1 has no AppIntents: island and banner controls are Links to
/// `rumxs://` URLs, which the app routes to the player page and the
/// matching action. Island views cannot scroll, so lyrics are the three
/// static lines from the content state, current line emphasized.
struct RumxsLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RumxsLiveActivityAttributes.self) { context in
            RumxsLiveActivityLockScreenView(state: context.state)
                .widgetURL(RumxsLiveActivityLink.nowPlaying)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RumxsLiveActivityArtwork(fileName: context.state.artworkFileName, size: 48)
                        .widgetURL(RumxsLiveActivityLink.nowPlaying)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HStack(spacing: 18) {
                        Link(destination: RumxsLiveActivityLink.togglePlay) {
                            Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        Link(destination: RumxsLiveActivityLink.next) {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.state.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(RumxsLiveActivityWidget.subtitle(for: context.state))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        RumxsLiveActivityLyrics(state: context.state)
                        HStack(spacing: 8) {
                            Text(RumxsLiveActivityWidget.timeText(context.state.progress))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            ProgressView(
                                value: context.state.progress,
                                total: max(context.state.duration, 1)
                            )
                            Text(RumxsLiveActivityWidget.timeText(
                                max(context.state.duration - context.state.progress, 0)
                            ))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        }
                    }
                    .widgetURL(RumxsLiveActivityLink.nowPlaying)
                }
            } compactLeading: {
                RumxsLiveActivityArtwork(fileName: context.state.artworkFileName, size: 24)
            } compactTrailing: {
                Link(destination: RumxsLiveActivityLink.togglePlay) {
                    RumxsLiveActivityWaveform(isPlaying: context.state.isPlaying)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
            } minimal: {
                RumxsLiveActivityArtwork(fileName: context.state.artworkFileName, size: 24)
            }
        }
    }

    static func subtitle(for state: RumxsLiveActivityAttributes.ContentState) -> String {
        [state.artist, state.album].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func timeText(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

/// Cover thumbnail read from the shared container, or a placeholder note.
/// The app writes one `artwork-<trackID>.jpg` per track; a missing file
/// (no App Group entitlement, fetch failed) falls back to the placeholder
/// instead of failing the widget.
private struct RumxsLiveActivityArtwork: View {
    let fileName: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let image = artworkImage() {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.quaternary)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.45, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func artworkImage() -> Image? {
        guard let fileName,
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: RumxsLiveActivityConstants.appGroupIdentifier
              ) else { return nil }
        let url = container
            .appendingPathComponent(RumxsLiveActivityConstants.artworkDirectoryName, isDirectory: true)
            .appendingPathComponent(fileName)
        guard let uiImage = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: uiImage)
    }
}

/// Audio-waveform bars for the collapsed island's trailing side, matching
/// the system Now Playing look: artwork on the left, waveform on the
/// right. Tapping the bars toggles playback via the surrounding Link.
/// The bars render statically when paused (dimmed); while playing they
/// pulse subtly. Island views render remotely and may not run the
/// animation, so the static bar layout is the requirement and the pulse
/// is a bonus.
private struct RumxsLiveActivityWaveform: View {
    let isPlaying: Bool

    /// Relative bar heights, shortest at the edges.
    private static let barHeights: [CGFloat] = [10, 18, 26, 14, 7]

    /// Per-bar pulse amplitude, so neighbouring bars move out of phase.
    private static let pulseScales: [CGFloat] = [1.15, 0.75, 1.1, 0.85, 1.2]

    @State private var isPulsing = false

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Self.barHeights.indices, id: \.self) { index in
                Capsule()
                    .fill(.primary)
                    .frame(width: 3, height: Self.barHeights[index])
                    .scaleEffect(y: isPulsing ? Self.pulseScales[index] : 1, anchor: .center)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.09),
                        value: isPulsing
                    )
            }
        }
        .opacity(isPlaying ? 1 : 0.5)
        .onAppear { isPulsing = isPlaying }
    }
}

/// Previous / current / next lyric lines. Empty lines are skipped so an
/// instrumental break shows nothing instead of blank rows.
private struct RumxsLiveActivityLyrics: View {
    let state: RumxsLiveActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let previous = state.previousLyric, !previous.isEmpty {
                Text(previous)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let current = state.currentLyric, !current.isEmpty {
                Text(current)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            if let next = state.nextLyric, !next.isEmpty {
                Text(next)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// Lock-screen banner: artwork, title, current lyric line, progress and
/// controls. Tapping anywhere but the controls opens the player page via
/// the `widgetURL` on the configuration content.
private struct RumxsLiveActivityLockScreenView: View {
    let state: RumxsLiveActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                RumxsLiveActivityArtwork(fileName: state.artworkFileName, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(RumxsLiveActivityWidget.subtitle(for: state))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let current = state.currentLyric, !current.isEmpty {
                        Text(current)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Link(destination: RumxsLiveActivityLink.togglePlay) {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                Link(destination: RumxsLiveActivityLink.next) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
            }
            ProgressView(value: state.progress, total: max(state.duration, 1))
        }
        .padding(.vertical, 4)
    }
}
