import SwiftUI

/// C9: a floating song card on the now-playing page. It shows the current
/// track's artwork, title and artist; tapping it returns to the page's main
/// view (the caller closes any lyrics / queue overlay it opened). The card
/// itself is inert unless mounted — `NowPlayingView` only mounts it while
/// `settings.effectiveStageTrackCardEnabled` is on.
struct StageTrackCard: View {
    /// Resolved theme accent, passed down from NowPlayingView (C12/C14).
    let accent: Color
    /// C11: while a handover plays, the card wears the theme accent as an
    /// outline instead of its quiet border.
    var transitionHighlighted = false
    let onTap: () -> Void

    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                CachedAsyncImage(url: player.currentTrack?.album.picUrl?.resizedImageURL(128))
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.currentTrack?.name ?? String(localized: "未在播放"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(player.currentTrack?.artistNames ?? "Kumone")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                .frame(maxWidth: 180, alignment: .leading)

                if player.isPlaying {
                    Image(systemName: "waveform")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(accent)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .compatGlass(material: settings.effectiveGlassMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        transitionHighlighted ? accent : .white.opacity(0.15),
                        lineWidth: transitionHighlighted ? 2 : 0.5
                    )
            )
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("回到播放页：\(player.currentTrack?.name ?? "")")
    }
}
