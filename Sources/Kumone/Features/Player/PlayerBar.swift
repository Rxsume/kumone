import SwiftUI

struct PlayerBar: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var settings: SettingsManager

    /// Folia capsule state: hover expands after ~20ms, collapses ~100ms
    /// after hover ends; pauses auto-expand. Nil while no hover timer runs.
    @State private var capsuleExpanded = false
    @State private var capsuleIsHovering = false
    @State private var capsuleHoverTask: Task<Void, Never>?

    var body: some View {
        if settings.foliaEnabled {
            floatingCapsuleBar
        } else {
            legacyBar
        }
    }

    // MARK: - Folia floating capsule

    /// Centered floating capsule (max 512pt, 32pt off the bottom). The
    /// collapsed capsule *is* the progress bar; hovering expands it to
    /// the title + transport + progress rows. No cover art, no artist,
    /// no quality tag, no volume popover, no route picker and no settings
    /// gear — Folia carries none of those in the capsule; they live on
    /// the player page. Whole-capsule tap opens the player page (PR #18);
    /// inner buttons claim their own taps, and a press on the scrubber
    /// track seeks instead of opening the page.
    private var floatingCapsuleBar: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 860
            let width = capsuleExpanded
                ? min(Theme.Layout.floatingCapsuleMaxWidth, max(0, proxy.size.width - 40))
                : min(
                    Theme.Layout.floatingCapsuleMaxWidth,
                    proxy.size.width * (compact
                        ? Theme.Layout.floatingCapsuleCollapsedWidthFractionCompact
                        : Theme.Layout.floatingCapsuleCollapsedWidthFractionRegular)
                )
            Group {
                if capsuleExpanded {
                    expandedCapsuleContent
                } else {
                    collapsedCapsuleContent
                }
            }
            .frame(width: max(width, 120))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .animation(AppAnimation.standard, value: capsuleExpanded)
        }
        .frame(height: capsuleExpanded
            ? Theme.Layout.floatingCapsuleExpandedHeight : 48)
        .frame(maxWidth: .infinity)
        .padding(.bottom, Theme.Layout.floatingCapsuleBottomMargin)
        .background(alignment: .bottom) { bottomFade }
        .onAppear {
            if !player.isPlaying { capsuleExpanded = true }
        }
        .onChange(of: player.isPlaying) { isPlaying in
            // Folia auto-expands the capsule when paused.
            if !isPlaying { capsuleExpanded = true }
        }
    }

    /// Hover in expands after ~20ms; hover out collapses ~100ms later,
    /// unless playback is paused (a paused capsule stays expanded).
    private func scheduleCapsuleHover(_ hovering: Bool) {
        capsuleIsHovering = hovering
        capsuleHoverTask?.cancel()
        if hovering {
            capsuleHoverTask = Task {
                try? await Task.sleep(nanoseconds: 20_000_000)
                guard !Task.isCancelled else { return }
                capsuleExpanded = true
            }
        } else {
            capsuleHoverTask = Task {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
                if player.isPlaying { capsuleExpanded = false }
            }
        }
    }

    /// Collapsed resting state: the scrubber lane is the whole capsule
    /// (current time, 6px track, duration, 10px mono labels; the thumb
    /// only appears on hover/drag). A drag on the track seeks; the bar
    /// tap below only fires for presses outside the track, so a scrub
    /// never also opens the player page.
    private var collapsedCapsuleContent: some View {
        ScrubberLane()
            .padding(.horizontal, 14)
            .frame(height: 48)
            .compatGlass(interactive: true, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
            .contentShape(Capsule())
            .onTapGesture { openNowPlaying() }
            .onHover { hovering in scheduleCapsuleHover(hovering) }
    }

    /// Expanded state: title row (14pt semibold, truncated; prev/next
    /// chevrons at the edges), 48pt accent play/pause with exactly two
    /// slot buttons, and the progress row at the bottom.
    private var expandedCapsuleContent: some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                capsuleChevron(icon: "chevron.left", disabled: player.isFMMode, label: "上一首") {
                    player.previous()
                }
                Text(player.currentTrack?.name ?? String(localized: "未在播放"))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
                capsuleChevron(icon: "chevron.right", disabled: false, label: "下一首") {
                    player.next()
                }
            }
            HStack(spacing: 16) {
                capsuleSlotControl(capsuleModeSlot)
                capsulePlayPauseButton
                capsuleLyricsSlotButton
            }
            ScrubberLane()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .compatGlass(interactive: true, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
        .contentShape(Capsule())
        .onTapGesture { openNowPlaying() }
        .onHover { hovering in scheduleCapsuleHover(hovering) }
    }

    /// The one mode slot in the capsule: repeat first, shuffle second
    /// (each only when its slot is enabled); repeat when neither is, so
    /// the capsule always carries exactly two slot buttons.
    private var capsuleModeSlot: PlayerControlSlot {
        if PlayerControlSlot.isSelected(.repeatMode, in: settings) { return .repeatMode }
        if PlayerControlSlot.isSelected(.shuffle, in: settings) { return .shuffle }
        return .repeatMode
    }

    /// Title-row chevron: 16px, faded in on hover, or pinned visible by
    /// the always-show-track-switch-buttons setting.
    private func capsuleChevron(icon: String, disabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(disabled)
        .opacity(settings.effectiveAlwaysShowTrackSwitchButtons || capsuleIsHovering ? 1 : 0)
        .animation(AppAnimation.quick, value: capsuleIsHovering)
        .accessibilityLabel(label)
    }

    /// One capsule slot button (20px icon). FM mode keeps its dislike
    /// button in place of the shuffle slot, as the legacy bar does.
    @ViewBuilder
    private func capsuleSlotControl(_ slot: PlayerControlSlot) -> some View {
        switch slot {
        case .shuffle:
            if player.isFMMode {
                PlayerIconButton(icon: "trash", size: 20) {
                    player.fmTrash()
                }
                .help("不喜欢，换一首")
            } else {
                PlayerIconButton(
                    icon: queueOrderIcon, size: 20,
                    isActive: queueOrderIsActive,
                    action: cycleQueueOrder
                )
                .help(queueOrderHelp)
            }
        case .repeatMode:
            if player.isFMMode {
                Image(systemName: "wave.3.right.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26, height: 26)
                    .help("私人漫游中")
            } else {
                PlayerIconButton(
                    icon: player.repeatMode == .one ? "repeat.1" : "repeat", size: 20,
                    isActive: player.repeatMode != .off
                ) {
                    player.cycleRepeatMode()
                }
                .help("循环模式")
            }
        case .previous:
            PlayerIconButton(icon: "backward.fill", size: 20, disabled: player.isFMMode) {
                player.previous()
            }
        case .next:
            PlayerIconButton(icon: "forward.fill", size: 20) {
                player.next()
            }
        case .playPause:
            capsulePlayPauseButton
        }
    }

    /// The lyrics-panel slot: the second capsule slot (Rumxs has no
    /// lyrics-timeline slot; the panel toggle is its equivalent).
    private var capsuleLyricsSlotButton: some View {
        PlayerIconButton(
            icon: "quote.bubble", size: 20,
            isActive: player.activePanel == .lyrics
        ) {
            player.activePanel = player.activePanel == .lyrics ? nil : .lyrics
        }
        .help("歌词")
    }

    /// 48pt accent play/pause circle (the legacy bar's is 30pt).
    private var capsulePlayPauseButton: some View {
        Button {
            player.togglePlayPause()
        } label: {
            ZStack {
                Circle()
                    .fill(Theme.accentGradient)
                    .frame(width: 48, height: 48)
                    .shadow(color: Theme.accent.opacity(0.35), radius: 5, y: 1)
                if player.isBuffering && player.isPlaying {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.opacity)
                }
            }
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
    }

    // MARK: - Legacy full-width bar (foliaEnabled off)

    private var legacyBar: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 860
            HStack(spacing: 12) {
                songInfoSection(compact: compact)
                    .frame(width: compact ? 180 : 252, alignment: .leading)
                centerSection
                    .frame(maxWidth: .infinity)
                optionsSection(compact: compact)
            }
            .padding(.horizontal, 14)
        }
        .frame(height: Theme.Layout.playerBarHeight)
        .compatGlass(interactive: true, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
        // Folia's capsule onClick: tapping anywhere on the bar that is
        // not a control opens the full now-playing page. The buttons
        // inside the bar (like / transport / panels / volume) and the
        // scrubber's drag gesture claim their own touches, so this
        // gesture only fires for the title, artwork, gaps and empty
        // space — the SwiftUI equivalent of Folia's `stopPropagation()`
        // on its capsule controls. `.contentShape` makes the gaps
        // between sections tappable too, not just the visible content.
        .contentShape(Capsule())
        .onTapGesture { openNowPlaying() }
        // Keep the capsule clear of the window's rounded corners so the inner
        // and outer radii don't visually merge (#88).
        .padding(.horizontal, 20)
        .padding(.bottom, Theme.Layout.playerBarBottomMargin)
        .background(alignment: .bottom) { bottomFade }
    }

    // MARK: - Left: artwork + titles + like

    private func songInfoSection(compact: Bool) -> some View {
        HStack(spacing: 10) {
            artworkButton
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    MarqueeText(
                        text: player.currentTrack?.name ?? String(localized: "未在播放"),
                        hugsText: true
                    )
                    .frame(height: 17)
                    if player.currentTrack?.fee == 1 {
                        VIPBadge()
                    }
                }
                Text(player.currentTrack?.artistNames ?? "Kumone")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // Only as wide as the title and artist need, so the like button
            // follows the title however wide the bar is.
            .layoutPriority(1)
            if let track = player.currentTrack {
                LikeButton(trackID: track.id)
            }
            Spacer(minLength: 0)
        }
    }

    /// Opens the full now-playing page, the way the artwork button
    /// always has; the bar-wide tap gesture shares this one path.
    private func openNowPlaying() {
        guard player.hasCurrentTrack else { return }
        withAnimation(AppAnimation.smooth) {
            player.showNowPlaying = true
        }
    }

    private var artworkButton: some View {
        Button {
            openNowPlaying()
        } label: {
            CachedAsyncImage(url: player.currentTrack?.album.picUrl?.resizedImageURL(128))
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        }
        .buttonStyle(.pressable)
        .noFocusRing()
        .help("打开播放页")
    }

    // MARK: - Queue-order control

    /// The queue-order button's three platform-dependent values. macOS cycles
    /// `listed → shuffled → autoMix`; iOS has no AutoMix and toggles shuffle.

    private var queueOrderIcon: String {
        #if os(macOS)
        player.queueOrder.symbolName
        #else
        "shuffle"
        #endif
    }

    private var queueOrderIsActive: Bool {
        #if os(macOS)
        player.queueOrder != .listed
        #else
        player.shuffleEnabled
        #endif
    }

    private var queueOrderHelp: LocalizedStringKey {
        #if os(macOS)
        player.queueOrder.controlHelp
        #else
        "随机播放"
        #endif
    }

    private func cycleQueueOrder() {
        #if os(macOS)
        player.cycleQueueOrder()
        #else
        player.toggleShuffle()
        #endif
    }

    // MARK: - Center: transport + scrubber

    private var centerSection: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                // FM mode keeps its dislike button in place of the shuffle
                // slot (it is not a slot, so it is always shown there).
                if player.isFMMode {
                    PlayerIconButton(icon: "trash", size: 12) {
                        player.fmTrash()
                    }
                    .help("不喜欢，换一首")
                }
                // C8: the transport buttons render in the configured slot
                // order and subset.
                ForEach(PlayerControlSlot.effectiveSlots(from: settings)) { slot in
                    playerBarSlotControl(slot)
                }
            }
            ScrubberLane()
        }
        .padding(.vertical, 5)
        .opacity(player.hasCurrentTrack ? 1 : 0.5)
    }

    /// C8: the button for one control slot in the player bar, or nothing
    /// when the slot has no button in the current mode (shuffle in FM is
    /// the trash button above). Actions and disabled states are the ones
    /// the bar had before slots existed.
    @ViewBuilder
    private func playerBarSlotControl(_ slot: PlayerControlSlot) -> some View {
        switch slot {
        case .shuffle:
            if !player.isFMMode {
                // One control for all three queue orders: the third state
                // is a *kind* of shuffle, so it lives inside the shuffle
                // button rather than beside it. The cycle skips it wherever
                // it could do nothing (AutoMix off, order off), which
                // leaves the familiar two-state button untouched there —
                // and iOS, which has no AutoMix at all, keeps the plain
                // two-state shuffle toggle. Only the three values below
                // differ per platform; the button itself is one button.
                PlayerIconButton(
                    icon: queueOrderIcon, size: 12,
                    isActive: queueOrderIsActive,
                    action: cycleQueueOrder
                )
                .help(queueOrderHelp)
            }
        case .previous:
            PlayerIconButton(icon: "backward.fill", size: 14, disabled: player.isFMMode) {
                player.previous()
            }
        case .playPause:
            playPauseButton
        case .next:
            PlayerIconButton(icon: "forward.fill", size: 14) {
                player.next()
            }
        case .repeatMode:
            if player.isFMMode {
                Image(systemName: "wave.3.right.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26, height: 26)
                    .help("私人漫游中")
            } else {
                PlayerIconButton(
                    icon: player.repeatMode == .one ? "repeat.1" : "repeat", size: 12,
                    isActive: player.repeatMode != .off
                ) {
                    player.cycleRepeatMode()
                }
                .help("循环模式")
            }
        }
    }

    private var playPauseButton: some View {
        Button {
            player.togglePlayPause()
        } label: {
            ZStack {
                Circle()
                    .fill(Theme.accentGradient)
                    .frame(width: 30, height: 30)
                    .shadow(color: Theme.accent.opacity(0.35), radius: 5, y: 1)
                if player.isBuffering && player.isPlaying {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(.white)
                        .contentTransition(.opacity)
                }
            }
        }
        .buttonStyle(.pressable)
        .padding(.horizontal, 2)
    }

    // MARK: - Right: quality / panels / volume

    private func optionsSection(compact: Bool) -> some View {
        HStack(spacing: 4) {
            if !compact, let level = player.servedQuality,
               let quality = AudioQuality(rawValue: level) {
                QualityTag(text: quality.badge)
                    .padding(.trailing, 2)
            } else if !compact, player.unblockSource != nil {
                QualityTag(text: String(localized: "音源"))
                    .padding(.trailing, 2)
                    .help("来自 \(player.unblockSource ?? "")")
            }
            PlayerIconButton(
                icon: "quote.bubble", size: 13,
                isActive: player.activePanel == .lyrics
            ) {
                player.activePanel = player.activePanel == .lyrics ? nil : .lyrics
            }
            .help("歌词")
            PlayerIconButton(
                icon: "inset.filled.bottomthird.square", size: 13,
                isActive: settings.showDesktopLyrics
            ) {
                settings.showDesktopLyrics.toggle()
            }
            .help("桌面歌词")
            PlayerIconButton(
                icon: "list.bullet", size: 13,
                isActive: player.activePanel == .queue,
                disabled: player.isFMMode
            ) {
                player.activePanel = player.activePanel == .queue ? nil : .queue
            }
            .help("播放队列")
            #if os(macOS)
            RoutePickerButton(diameter: 26, glyphSize: 13,
                              tint: .secondary, background: .clear)
            #endif
            VolumeControl()
        }
    }

    private var bottomFade: some View {
        LinearGradient(
            colors: [
                Platform.windowBackgroundColor.opacity(0),
                Platform.windowBackgroundColor.opacity(0.25),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: 50)
        .allowsHitTesting(false)
    }
}

// MARK: - Icon button
#if os(macOS)

/// How the one queue-order control presents each state. Here rather than on
/// the enum itself so `QueueOrder` stays a pure Core type: three transports
/// (this bar, the now-playing page, the Dock menu) read the same two answers.
extension QueueOrder {
    /// `wand.and.stars` for AutoMix: it reads as "smart shuffle" next to the
    /// plain `shuffle` arrows, and the accent tint the button applies to any
    /// non-listed state carries the rest.
    var symbolName: String {
        switch self {
        case .listed, .shuffled: return "shuffle"
        case .autoMix: return "wand.and.stars"
        }
    }

    /// Tooltip / menu wording for the state the control is *in*.
    var controlHelp: LocalizedStringKey {
        switch self {
        case .listed, .shuffled: return "随机播放"
        case .autoMix: return "AutoMix 顺序"
        }
    }

    /// The Dock menu names all three states — it is a list of them rather than
    /// a button standing in one, so `listed` gets a word of its own.
    var menuTitle: String {
        switch self {
        case .listed: return String(localized: "列表顺序")
        case .shuffled: return String(localized: "随机播放")
        case .autoMix: return String(localized: "AutoMix 顺序")
        }
    }
}
#endif

struct PlayerIconButton: View {
    let icon: String
    var size: CGFloat = 14
    var isActive = false
    var showsActiveBackground = true
    var disabled = false
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isActive ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(backgroundColor)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .onHover { isHovering = $0 }
        .animation(AppAnimation.quick, value: isHovering)
    }

    private var backgroundColor: Color {
        let base: Color = colorScheme == .dark ? .white : .black
        if isHovering, !disabled { return base.opacity(0.08) }
        if isActive, showsActiveBackground { return base.opacity(0.05) }
        return .clear
    }
}

// MARK: - Like button

struct LikeButton: View {
    let trackID: Int
    var size: CGFloat = 13
    var showsActiveBackground = true

    @EnvironmentObject private var account: AccountStore

    var body: some View {
        let liked = account.isLiked(trackID)
        PlayerIconButton(
            icon: liked ? "heart.fill" : "heart", size: size,
            isActive: liked,
            showsActiveBackground: showsActiveBackground
        ) {
            Task { await account.toggleLike(trackID: trackID) }
        }
        .help(liked ? String(localized: "取消喜欢") : String(localized: "喜欢"))
    }
}

// MARK: - Scrubber

struct ScrubberLane: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var clock = PlayerService.shared.clock
    @Environment(\.colorScheme) private var colorScheme

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragProgress: Double = 0

    private var fraction: Double {
        guard player.duration > 0 else { return 0 }
        let value = isDragging ? dragProgress : clock.progress
        return min(max(value / player.duration, 0), 1)
    }

    var body: some View {
        HStack(spacing: 8) {
            timeLabel(isDragging ? dragProgress : clock.progress)
            track
            timeLabel(player.duration)
        }
        .frame(maxWidth: 460)
    }

    private func timeLabel(_ value: TimeInterval) -> some View {
        Text(Formatters.duration(value))
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 34)
    }

    private var track: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.18) : .black.opacity(0.15))
                    .frame(height: 3.5)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(3.5, width * fraction), height: 3.5)
                Circle()
                    .fill(.white)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                    .offset(x: width * fraction - thumbDiameter / 2)
                    .opacity(isHovering || isDragging ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard player.duration > 0 else { return }
                        isDragging = true
                        player.isScrubbing = true
                        dragProgress = min(max(value.location.x / width, 0), 1) * player.duration
                    }
                    .onEnded { _ in
                        player.seek(to: dragProgress)
                        isDragging = false
                        player.isScrubbing = false
                    }
            )
        }
        .frame(height: 14)
        .onHover { hovering in
            withAnimation(AppAnimation.quick) { isHovering = hovering }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.72), value: isDragging)
    }

    private var thumbDiameter: CGFloat {
        isDragging ? 12 : (isHovering ? 10 : 8)
    }
}

// MARK: - Volume

struct VolumeControl: View {
    @EnvironmentObject private var player: PlayerService
    @State private var showPopover = false

    var body: some View {
        PlayerIconButton(icon: volumeIcon, size: 13) {
            showPopover.toggle()
        }
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            VolumeSlider()
                .padding(.vertical, 12)
                .padding(.horizontal, 10)
        }
        .help("音量")
    }

    private var volumeIcon: String {
        switch player.volume {
        case 0: return "speaker.slash"
        case ..<0.4: return "speaker.wave.1"
        case ..<0.75: return "speaker.wave.2"
        default: return "speaker.wave.3"
        }
    }
}

struct VolumeSlider: View {
    @EnvironmentObject private var player: PlayerService
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.18) : .black.opacity(0.15))
                    .frame(width: 4)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 4, height: max(4, height * CGFloat(player.volume)))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        player.volume = Float(min(max(1 - value.location.y / height, 0), 1))
                    }
            )
        }
        .frame(width: 22, height: 110)
    }
}
