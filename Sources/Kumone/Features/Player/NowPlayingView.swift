import SwiftUI

/// Auto-hide state for the now-playing page chrome (Folia
/// `usePlayerChromeAutoHide`: idle timeout exactly 3000 ms). One model
/// owns the timer so every layout and transport control resets the
/// same clock; the page injects it as an environment object so the
/// transport subviews can reset it too. Only the chrome fades — lyrics,
/// artwork and backgrounds never do. (Restored: removed by the Folia
/// rollback, PR #36.)
@MainActor
final class ChromeAutoHideModel: ObservableObject {
    /// Idle time before the chrome fades out (Folia: exactly 3000 ms).
    static let idleTimeoutNanoseconds: UInt64 = 3_000_000_000

    @Published var controlsVisible = true
    /// Whether auto-hide is in effect (setting on + Folia master on).
    var autoHideEnabled = false

    private var hideTask: Task<Void, Never>?

    /// Restart the idle timer and show the chrome. While auto-hide is
    /// off this just leaves the chrome visible.
    func resetTimer() {
        hideTask?.cancel()
        hideTask = nil
        controlsVisible = true
        guard autoHideEnabled else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: Self.idleTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            controlsVisible = false
        }
    }

    /// Show the chrome and restart the idle timer (tap-to-reveal).
    func showAndResetTimer() {
        resetTimer()
    }

    /// Stop the timer and leave the chrome visible (page dismissed).
    func stop() {
        hideTask?.cancel()
        hideTask = nil
        controlsVisible = true
    }
}

/// Immersive full-window now-playing page: artwork-tinted gradient backdrop,
/// large artwork on the left, big synced lyrics on the right.
struct NowPlayingView: View {
    let onOpenDestination: (Destination) -> Void

    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var lyricsCursor = PlayerService.shared.lyricsCursor
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var settings: SettingsManager
    #if os(macOS)
    @EnvironmentObject private var artworkStore: NowPlayingArtworkStore
    #endif
    #if os(iOS)
    @Environment(\.dismissNowPlayingAction) private var dismissNowPlayingAction
    @Environment(\.dismissNowPlayingDragAction) private var dismissNowPlayingDragAction
    #endif

    #if os(iOS)
    @State private var loadedArtwork = CachedImageState()
    @State private var loadedArtworkColors: ArtworkColors = .fallback
    /// The user-uploaded background image (monet + nomand share it),
    /// loaded once per stored file name — never per body evaluation.
    @State private var uploadedBackgroundImage: PlatformImage?
    #endif
    @State private var activeIndex: Int?
    @State private var isUserScrolling = false
    @State private var showLyricsOnMobile = false
    @State private var showQueueOnMobile = false
    /// Horizontal swipe offset on the classic cover (Beans swipe-to-switch).
    @State private var classicSwipeOffset: CGFloat = 0
    /// Auto-hide model for the page chrome (Folia 3s idle fade).
    @StateObject private var chromeAutoHide = ChromeAutoHideModel()
    #if os(iOS)
    /// Folia lyric-style window (VisPlayground) sheet, opened from the
    /// luminous layout's panel button.
    @State private var showLyricStyleSettings = false
    @State private var showSoundEffects = false
    #endif

    var body: some View {
        GeometryReader { geo in
            let isCompact = geo.size.width < 720
            ZStack {
                backdrop(isCompact: isCompact)

                if isCompact {
                    compactLayout(size: geo.size)
                } else {
                    #if os(iOS)
                    switch settings.landscapeNowPlayingStyle {
                    case .classic:
                        regularLayout(size: geo.size)
                    case .immersive:
                        landscapeImmersiveLayout(size: geo.size)
                    }
                    #else
                    regularLayout(size: geo.size)
                    #endif
                }

            }
            // Pin to the screen width so an intrinsically-wide child can never
            // stretch the ZStack and push the corner overlays off-screen.
            .frame(width: geo.size.width)
            #if os(macOS)
            .overlay(alignment: .topTrailing) {
                // Toward the top-trailing corner, level with the window
                // buttons (#128): a 36pt bubble whose center matches the 14pt
                // traffic lights (y 19…33 inside the 52pt titlebar). Clear of
                // the leading corner, where the sidebar toggle sits on the
                // page below.
                collapseButton(diameter: 36, glyphSize: 14)
                    .padding(.top, 8)
                    .padding(.trailing, 24)
            }
            #else
            .overlay(alignment: .topLeading) {
                // C7: the setting pins the back button visible even where the
                // compact layouts would otherwise hide it.
                if settings.effectiveAlwaysShowPlayerBackButton || showsClassicChrome(isCompact: isCompact) {
                    collapseButton(diameter: 36, glyphSize: 14)
                        .padding(.top, 20)
                        .padding(.leading, 20)
                        .opacity(chromeAutoHide.controlsVisible ? 1 : 0)
                        .allowsHitTesting(chromeAutoHide.controlsVisible)
                        .animation(AppAnimation.standard, value: chromeAutoHide.controlsVisible)
                }
            }
            #endif
            .overlay(alignment: .topTrailing) {
                if isCompact, showsClassicChrome(isCompact: isCompact) {
                    HStack(spacing: 8) {
                        #if os(iOS)
                        SoundEffectsButton(
                            action: { showSoundEffects = true },
                            diameter: 36,
                            glyphSize: 14
                        )
                        #endif

                        Button {
                            withAnimation(AppAnimation.standard) {
                                showLyricsOnMobile.toggle()
                            }
                        } label: {
                            Image(systemName: showLyricsOnMobile ? "music.note" : "quote.bubble")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(showLyricsOnMobile ? themeAccent : .white.opacity(0.85))
                                .frame(width: 36, height: 36)
                                .background(.white.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.pressable)
                    }
                    .padding(.top, 20)
                    .padding(.trailing, 20)
                    .opacity(chromeAutoHide.controlsVisible ? 1 : 0)
                    .allowsHitTesting(chromeAutoHide.controlsVisible)
                    .animation(AppAnimation.standard, value: chromeAutoHide.controlsVisible)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // C9: floating song card (tap returns to the main view).
                if settings.effectiveStageTrackCardEnabled, player.hasCurrentTrack {
                    StageTrackCard(
                        accent: themeAccent,
                        // C11: the card outline while a handover plays.
                        transitionHighlighted: settings.effectiveTransitionAnimationCard && transitionInProgress
                    ) {
                        withAnimation(AppAnimation.standard) {
                            showLyricsOnMobile = false
                            showQueueOnMobile = false
                        }
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 108)
                    .opacity(chromeAutoHide.controlsVisible ? 1 : 0)
                    .allowsHitTesting(chromeAutoHide.controlsVisible)
                    .animation(AppAnimation.standard, value: chromeAutoHide.controlsVisible)
                }
            }
            .overlay {
                // C11: the transition ring floats over the page while a
                // handover plays; inert until a transition signal exists.
                TransitionAnimationView(isTransitioning: transitionInProgress, accent: themeAccent)
            }
            .overlay {
                // Auto-hide: when the chrome is hidden, any tap on the
                // page brings it back. Lyrics, artwork and backgrounds
                // never fade — only the chrome does.
                if !chromeAutoHide.controlsVisible {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { chromeAutoHide.showAndResetTimer() }
                        .accessibilityLabel("显示播放控件")
                        .accessibilityAddTraits(.isButton)
                }
            }
            #if os(iOS)
            .overlay {
                if settings.nowPlayingMode == .minimal && showQueueOnMobile {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { showQueueOnMobile = false }
                        .accessibilityLabel("关闭播放列表")
                        .accessibilityAddTraits(.isButton)
                }
            }
            #endif
        }
        #if os(macOS)
        // The window toolbar is hidden while this page is up, but SwiftUI keeps
        // reserving its safe area, which pushed the whole immersive layout —
        // close button included — a toolbar's height down from the window top.
        // iOS keeps its safe area: there the inset is the status bar / notch.
        .ignoresSafeArea()
        #endif
        .preferredColorScheme(.dark)
        .environmentObject(chromeAutoHide)
        .onAppear {
            chromeAutoHide.autoHideEnabled = settings.effectiveAutoHidePlayerChrome
            chromeAutoHide.resetTimer()
        }
        .onChange(of: settings.effectiveAutoHidePlayerChrome) { enabled in
            chromeAutoHide.autoHideEnabled = enabled
            chromeAutoHide.resetTimer()
        }
        .onChange(of: player.currentTrack?.id) { _ in
            chromeAutoHide.resetTimer()
        }
        .onDisappear {
            chromeAutoHide.stop()
        }
        #if os(iOS)
        .soundEffectsPresentation(
            isPresented: $showSoundEffects,
            settings: settings
        )
        .modifier(OfflinePlaybackAlert(player: player, onDownloads: { onOpenDestination(.downloaded) },
            enabled: player.showNowPlaying && !(settings.nowPlayingMode == .minimal && showQueueOnMobile)))
        .modifier(MeteredDownloadAlert(enabled: player.showNowPlaying && !(settings.nowPlayingMode == .minimal && showQueueOnMobile)))
        #endif
        #if os(iOS)
        .task(id: currentArtworkURL) {
            await loadArtwork()
        }
        .task(id: settings.effectiveUploadedBackgroundImageName) {
            // Load once per stored file name, off the main actor: the
            // file read + image decode must not hitch the player page.
            // A missing file (reinstall keeps the name, not the file)
            // loads as nil and the backgrounds fall back to the cover.
            let name = settings.effectiveUploadedBackgroundImageName
            uploadedBackgroundImage = await Task.detached(priority: .userInitiated) {
                VisualizerBackgroundImageStore.loadImage(named: name)
            }.value
        }
        #endif
        #if os(iOS)
        .onAppear {
            showLyricsOnMobile = settings.nowPlayingMode == .immersive
            showQueueOnMobile = false
        }
        .onChange(of: settings.nowPlayingMode) { _ in
            showLyricsOnMobile = settings.nowPlayingMode == .immersive
            showQueueOnMobile = false
        }
        .onChange(of: player.currentTrack?.id) { _ in
            if settings.nowPlayingMode == .minimal || settings.nowPlayingMode == .vinyl {
                showLyricsOnMobile = false
            }
        }
        #endif
        #if os(macOS)
        .onExitCommand {
            close()
        }
        #endif
    }

    private var hasLyricsColumn: Bool {
        if let lyrics = player.lyrics, !lyrics.isEmpty { return true }
        return player.lyrics == nil // still loading — keep layout stable
    }

    private func close() {
        #if os(iOS)
        if let dismissNowPlayingAction {
            dismissNowPlayingAction()
        } else {
            withAnimation(NowPlayingPresentationMetrics.presentationAnimation) {
                player.showNowPlaying = false
            }
        }
        #else
        player.showNowPlaying = false
        #endif
    }

    private func showsClassicChrome(isCompact: Bool) -> Bool {
        #if os(iOS)
        return !isCompact || settings.nowPlayingMode == .classic
        #else
        return true
        #endif
    }

    /// Collapse back to the browse UI. Shared by both platforms so the macOS
    /// layout can park it beside the window buttons (#128).
    private func collapseButton(diameter: CGFloat, glyphSize: CGFloat) -> some View {
        Button {
            close()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: diameter, height: diameter)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.pressable)
    }

    /// Jump straight to the line the song is on. Used when the view appears,
    /// where waiting for the next line change would leave the lyrics parked at
    /// the top. Scrolling is deferred a turn: the list has not laid out yet
    /// while `onAppear` runs, and `scrollTo` on an unlaid list does nothing.
    private func adoptCursor(proxy: ScrollViewProxy) {
        let index = lyricsCursor.activeIndex
        activeIndex = index
        guard let index else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(index, anchor: .center)
        }
    }

    // MARK: - Backdrop

    private var artworkImage: PlatformImage? {
        #if os(macOS)
        artworkStore.artwork
        #else
        loadedArtwork.image(for: currentArtworkURL)
        #endif
    }

    /// Raw artwork palette for theme resolution, or nil when no artwork is
    /// loaded — nil (not `.fallback`) is what lets a non-default preset win
    /// when nothing is playing.
    private var artworkPalette: ArtworkColors? {
        #if os(macOS)
        artworkStore.artwork == nil ? nil : artworkStore.colors
        #else
        artworkImage == nil ? nil : loadedArtworkColors
        #endif
    }

    /// C12/C14: the effective theme (custom → song artwork → selected
    /// preset). The default preset with no saved custom theme resolves to
    /// the pre-existing colours — `Theme.accent` over the fallback palette,
    /// or the artwork palette while song-theme auto-switch is on — so the
    /// default look is unchanged.
    private var theme: ResolvedTheme {
        ThemePreset.resolvedTheme(settings: settings, palette: artworkPalette)
    }

    /// Accent colour for controls and highlights, from the resolved theme.
    private var themeAccent: Color { theme.accent }

    private var colors: ArtworkColors {
        let base = ArtworkColors(primary: theme.tint, secondary: theme.secondaryTint)
        // C10: the player-page tint intensity multiplies the theme's own
        // intensity — the artwork theme's intensity is 1, so artwork-derived
        // pages behave exactly as before, while preset/custom themes (whose
        // intensity used to replace the slider outright) now scale with it
        // too. Default 1.0 leaves the default appearance unchanged.
        let intensity = theme.intensity * settings.effectivePlayerPageTintIntensity
        return tintedColors(base, intensity: intensity)
    }

    /// C11: whether a hand-over is currently playing, from the player's
    /// published signal: true from the playhead entering the overlap (or
    /// the midpoint, whichever first) until the engine reports completion
    /// or the transition is disarmed. On macOS this is the AutoMix engine;
    /// on iOS the single-engine player never overlaps tracks, so it stays
    /// false there (PR #36 rollback).
    private var transitionInProgress: Bool {
        player.transitionInProgress
    }

    /// Beans player-page palette, derived from the cover's dominant colour
    /// (hue-bucket extraction, cached per artwork — see
    /// `BeansPaletteExtractor`). The page always renders dark
    /// (`.preferredColorScheme(.dark)`), so the palette is built for
    /// `.dark`; with no artwork it falls back to the neutral colours +
    /// fixed theme accent.
    private var beansPalette: BeansCoverPalette {
        let dominant: BeansRGBColor?
        #if os(iOS)
        if let image = artworkImage, let urlString = player.currentTrack?.album.picUrl {
            dominant = BeansPaletteExtractor.dominantColor(from: image, cacheKey: urlString)
        } else {
            dominant = nil
        }
        #else
        dominant = artworkStore.artwork.flatMap {
            BeansPaletteExtractor.dominantColor(from: $0, cacheKey: String(player.currentTrack?.id ?? 0))
        }
        #endif
        return BeansCoverPalette.make(dominant: dominant, colorScheme: .dark)
    }

    /// Scales an artwork palette toward the neutral fallback (intensity < 1)
    /// or past it (intensity > 1), so 1.0 returns the extracted colours
    /// unchanged. Component math, not opacity: the backdrop gradient is
    /// opaque, so there is nothing underneath to show through.
    private func tintedColors(_ colors: ArtworkColors, intensity: Double) -> ArtworkColors {
        guard intensity != 1 else { return colors }
        let amount = intensity - 1 // -0.5 ... 0.5
        return ArtworkColors(
            primary: shifted(colors.primary, from: ArtworkColors.fallback.primary, by: amount),
            secondary: shifted(colors.secondary, from: ArtworkColors.fallback.secondary, by: amount)
        )
    }

    /// `color + (color - base) * amount`: amount 0 returns `color`, -1
    /// returns `base`, positive values push past `color` away from `base`.
    private func shifted(_ color: Color, from base: Color, by amount: Double) -> Color {
        guard amount != 0,
              let mine = PlatformColor(color).cgColor.components,
              let other = PlatformColor(base).cgColor.components,
              mine.count >= 4, other.count >= 4
        else { return color }
        func clamped(_ value: CGFloat) -> Double {
            min(max(Double(value), 0), 1)
        }
        return Color(
            red: clamped(mine[0] + (mine[0] - other[0]) * CGFloat(amount)),
            green: clamped(mine[1] + (mine[1] - other[1]) * CGFloat(amount)),
            blue: clamped(mine[2] + (mine[2] - other[2]) * CGFloat(amount)),
            opacity: clamped(mine[3])
        )
    }

    /// Ambient colour transitions still in static mode, or when the
    /// background reduce-motion override says so (C4/C5).
    private var backdropAnimation: Animation? {
        settings.effectiveStaticMode || settings.effectiveReduceMotionBackground
            ? nil : .easeInOut(duration: 0.8)
    }

    /// Line motion (activation springs, scroll-to-line) stills in static
    /// mode, with the "no animation" lyric style, or when transitions are
    /// reduced (C4/C5/C15).
    private var lyricAnimationsEnabled: Bool {
        !settings.effectiveStaticMode
            && settings.effectiveLyricAnimationStyle != .none
            && !settings.effectiveReduceMotionTransitions
    }

    /// Returns `animation` unless lyric motion is stilled, in which case nil
    /// (the view jumps straight to its final state).
    private func lyricAnimation(_ animation: Animation) -> Animation? {
        lyricAnimationsEnabled ? animation : nil
    }

    /// Source image for a background that takes cover-or-uploaded: the
    /// uploaded image when the mode's source says so and one is stored,
    /// else the current cover (Folia's uploaded-first-with-cover-fallback).
    #if os(iOS)
    private func backgroundSourceImage(for source: BackgroundImageSource) -> PlatformImage? {
        if source == .uploadedGlobal, let uploadedBackgroundImage {
            return uploadedBackgroundImage
        }
        return artworkImage
    }
    #endif

    /// The selected saved webpage as a URL, or nil when there is none.
    private var selectedUrlBackgroundURL: URL? {
        settings.selectedUrlBackground.flatMap { URL(string: $0.url) }
    }

    /// Backgrounds freeze in static mode, or when the background
    /// reduce-motion override says so (C4/C5). This deliberately reads the
    /// *background* override, not the micro-motion one: micro-motion stills
    /// small movements (vinyl spin, the play/pause pulse, the marquee,
    /// lyric word float) but must not freeze the whole luminous backdrop.
    private var backgroundIsStatic: Bool {
        settings.effectiveStaticMode || settings.effectiveReduceMotionBackground
    }

    /// The page backdrop. In luminous mode (compact, iOS) the selected
    /// Folia background replaces the artwork gradient — two ambient
    /// layers stacked would wash the page out grey — or a plain dark
    /// colour when the background mode is none. Every other mode keeps
    /// the gradient.
    @ViewBuilder
    private func backdrop(isCompact: Bool) -> some View {
        #if os(iOS)
        if isCompact, settings.effectiveNowPlayingMode == .luminous {
            switch settings.effectiveVisualizerBackgroundMode {
            case .latent:
                // Folia's default background: the flowing latent field.
                // The palette is the cover-extracted tint pair plus the
                // theme accent; the view blends the remaining mesh stops.
                LatentBackgroundView(
                    primary: colors.primary,
                    secondary: colors.secondary,
                    accent: themeAccent,
                    background: colors.secondary,
                    isPlaying: player.isPlaying,
                    isStatic: backgroundIsStatic,
                    tuning: settings.latentTuning
                )
                .ignoresSafeArea()
            case .nomand:
                NomandBackgroundView(
                    cover: backgroundSourceImage(for: settings.effectiveNomandImageSource),
                    songID: player.currentTrack.map { String($0.id) },
                    tuning: NomandDitherer.Tuning(
                        size: settings.effectiveNomandHalftoneSize,
                        radius: settings.effectiveNomandHalftoneRadius,
                        contrast: settings.effectiveNomandHalftoneContrast,
                        originalColors: settings.effectiveNomandOriginalColors,
                        accent: PlatformColor(themeAccent),
                        background: PlatformColor(colors.secondary),
                        effect: settings.effectiveNomandEffect,
                        highlight: PlatformColor(colors.primary),
                        secondary: PlatformColor(theme.secondaryTint),
                        ditheringType: settings.effectiveNomandDitheringType,
                        ditheringSize: settings.effectiveNomandDitheringSize,
                        ditheringColorSteps: settings.effectiveNomandDitheringColorSteps,
                        ditheringOriginalColors: settings.effectiveNomandDitheringOriginalColors,
                        ditheringInverted: settings.effectiveNomandDitheringInverted,
                        flutedGlassSize: settings.effectiveNomandFlutedGlassSize,
                        flutedGlassDistortion: settings.effectiveNomandFlutedGlassDistortion,
                        flutedGlassBlur: settings.effectiveNomandFlutedGlassBlur,
                        paperTextureContrast: settings.effectiveNomandPaperTextureContrast,
                        paperTextureRoughness: settings.effectiveNomandPaperTextureRoughness,
                        paperTextureFiber: settings.effectiveNomandPaperTextureFiber,
                        halftoneDotsInverted: settings.effectiveNomandHalftoneDotsInverted,
                        lensDistortionSpread: settings.effectiveNomandLensDistortionSpread,
                        lensDistortionBulge: settings.effectiveNomandLensDistortionBulge,
                        lensDistortionDispersion: settings.effectiveNomandLensDistortionDispersion
                    ),
                    overlayOpacity: settings.effectiveNomandOverlayEnabled
                        ? settings.effectiveNomandOverlayOpacity : 0,
                    background: colors.secondary
                )
                .ignoresSafeArea()
            case .common:
                // The live band levels are polled here (main actor) and
                // handed down; the view itself only drifts its shapes.
                TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: backgroundIsStatic)) { _ in
                    CommonBackgroundView(
                        cover: artworkImage,
                        background: colors.secondary,
                        primary: colors.primary,
                        secondary: colors.secondary,
                        accent: themeAccent,
                        songID: player.currentTrack.map { String($0.id) },
                        opacity: settings.effectiveCommonOpacity,
                        useCoverColorBg: settings.effectiveCommonUseCoverColorBg,
                        disableVignette: settings.effectiveCommonDisableVignette,
                        disableGeometric: settings.effectiveCommonDisableGeometric,
                        isStatic: backgroundIsStatic,
                        audioLevels: (
                            bass: AudioSpectrum.shared.level(at: 0),
                            lowMid: AudioSpectrum.shared.level(at: 1),
                            mid: AudioSpectrum.shared.level(at: 2),
                            treble: AudioSpectrum.shared.level(at: 3)
                        )
                    )
                }
                .ignoresSafeArea()
            case .monet:
                MonetBackgroundView(
                    cover: backgroundSourceImage(for: settings.effectiveMonetBackgroundSource),
                    background: colors.secondary,
                    primary: colors.primary,
                    accent: themeAccent,
                    secondary: colors.secondary,
                    tuning: settings.monetTuning,
                    isStatic: backgroundIsStatic
                )
                .ignoresSafeArea()
            case .url:
                if let url = selectedUrlBackgroundURL {
                    UrlBackgroundView(url: url)
                        .ignoresSafeArea()
                } else {
                    colors.secondary
                        .ignoresSafeArea()
                }
            case .sora:
                SoraBackgroundView(
                    primary: colors.primary,
                    accent: themeAccent,
                    background: colors.secondary,
                    isStatic: backgroundIsStatic,
                    blank: settings.effectiveSoraBlank
                )
                .ignoresSafeArea()
            case .none:
                colors.secondary
                    .ignoresSafeArea()
            }
        } else {
            gradientBackdrop
        }
        #else
        gradientBackdrop
        #endif
    }

    private var gradientBackdrop: some View {
        ZStack {
            #if os(iOS)
            // Beans blurred-cover layer, gated by the existing native-blur
            // setting: the cover itself, pre-blurred once per track, washed
            // with its own gradient. Off, the plain artwork gradient below
            // shows (the pre-Beans behaviour).
            if settings.effectivePlayerPageNativeBlur, let artworkImage {
                BeansCoverBlurBackground(
                    image: artworkImage,
                    cacheKey: player.currentTrack?.album.picUrl ?? "",
                    primary: colors.primary,
                    secondary: colors.secondary,
                    scheme: .dark,
                    isStatic: backgroundIsStatic
                )
            }
            #endif
            LinearGradient(
                colors: [colors.primary, colors.secondary],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            // Beans ambient glow: two cover-coloured blobs drifting behind
            // the content. Still in static mode / Reduce Motion background.
            if !backgroundIsStatic {
                BeansAmbientGlowView(
                    accent: beansPalette.accent,
                    secondary: beansPalette.secondary,
                    isPlaying: player.isPlaying,
                    dustMode: .off,
                    dustDensity: 1,
                    dustSize: 1,
                    breath: 0.6
                )
            }
            RadialGradient(
                colors: [.white.opacity(0.12), .clear],
                center: .topLeading, startRadius: 0, endRadius: 700
            )
            LinearGradient(
                colors: [.clear, .black.opacity(0.35)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .animation(backdropAnimation, value: colors)
    }

    #if os(iOS)
    private var currentArtworkURL: URL? {
        player.currentTrack?.album.picUrl?.resizedImageURL(768)
    }

    private func loadArtwork() async {
        loadedArtworkColors = .fallback
        guard let urlString = player.currentTrack?.album.picUrl,
              let url = currentArtworkURL else {
            loadedArtwork = CachedImageState()
            return
        }
        loadedArtwork = CachedImageState(url: url)
        let image = await ImageCache.shared.image(for: url) { preview in
            applyArtwork(preview, for: url, cacheKey: urlString)
        }
        if let image { applyArtwork(image, for: url, cacheKey: urlString) }
    }

    private func applyArtwork(_ image: PlatformImage, for url: URL, cacheKey: String) {
        guard !Task.isCancelled, currentArtworkURL == url else { return }
        loadedArtwork.finish(image, for: url)
        loadedArtworkColors = ArtworkPalette.extract(from: image, cacheKey: cacheKey)
    }
    #endif

    // MARK: - Layouts

    private func regularLayout(size: CGSize) -> some View {
        // Everything below the artwork needs ~300pt; shrink the artwork on
        // short displays (iPhone landscape) instead of clipping it.
        let artworkSize = max(120, min(340, size.width * 0.32, size.height - 300))
        // Cap the two-column band and centre it. Spreading each column to
        // `.infinity` across an ultra-wide display (iPad landscape, ~1368pt)
        // left the left column's content floating in an oversized half and a
        // wide blank gutter on the right (#62).
        let maxBandWidth: CGFloat = hasLyricsColumn ? 1040 : 560
        return HStack(spacing: 0) {
            leftColumn(artworkSize: artworkSize)
                .frame(maxWidth: .infinity)
            if hasLyricsColumn {
                lyricsColumn
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: maxBandWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 48)
        .padding(.vertical, size.height < 500 ? 24 : 40)
    }

    #if os(iOS)
    /// Full-screen karaoke page for iPhone landscape / iPad. The scrubber is
    /// deliberately absent: the sung line and its wipe own the middle of the
    /// screen, the track sits at the bottom-left and the transport at the
    /// bottom-right, over a slowly drifting artwork backdrop.
    private func landscapeImmersiveLayout(size: CGSize) -> some View {
        ZStack {
            AnimatedKaraokeBackdrop(
                image: artworkImage, colors: colors,
                // A full-screen blur redrawn 24 times a second is not worth it
                // while nothing moves or the queue covers the lyrics.
                isPaused: !player.isPlaying || showQueueOnMobile
            )

            VStack(spacing: 0) {
                landscapeUtilityRow
                    .padding(.top, 18)
                    .padding(.trailing, 24)

                Group {
                    if showQueueOnMobile {
                        CompactQueueContent()
                            .transition(.opacity)
                    } else {
                        lyricsScroll(
                            topInset: max(12, size.height * 0.06),
                            bottomInset: max(20, size.height * 0.10),
                            horizontalPadding: 60,
                            karaoke: true
                        )
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.2), value: showQueueOnMobile)

                HStack(alignment: .center, spacing: 14) {
                    landscapeNowPlayingMetadata
                    Spacer(minLength: 12)
                    landscapeTransportRow
                }
                .padding(.horizontal, 28)
                .padding(.bottom, max(16, size.height * 0.03))
            }
        }
    }

    private var landscapeUtilityRow: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)

            SoundEffectsButton(action: { showSoundEffects = true })

            circleButton(
                icon: "list.bullet", size: 15,
                tint: showQueueOnMobile ? themeAccent : nil
            ) {
                withAnimation(AppAnimation.standard) {
                    showQueueOnMobile.toggle()
                }
            }
            .accessibilityLabel(showQueueOnMobile ? "关闭播放队列" : "显示播放队列")

            RoutePickerButton(diameter: 40, glyphSize: 16)
        }
        .opacity(chromeAutoHide.controlsVisible ? 1 : 0)
        .allowsHitTesting(chromeAutoHide.controlsVisible)
        .animation(AppAnimation.standard, value: chromeAutoHide.controlsVisible)
    }

    private var landscapeNowPlayingMetadata: some View {
        HStack(spacing: 12) {
            artworkView(size: 52, shadowRadius: 10, cornerRadius: 12)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(player.currentTrack?.name ?? "")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if player.currentTrack?.fee == 1 {
                        VIPBadge()
                    }
                }
                if let track = player.currentTrack {
                    NowPlayingTrackDestinationLinks(
                        track: track,
                        font: .system(size: 12),
                        color: .white.opacity(0.62),
                        onOpenDestination: onOpenDestination
                    )
                    .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
        .opacity(chromeAutoHide.controlsVisible ? 1 : 0)
        .allowsHitTesting(chromeAutoHide.controlsVisible)
        .animation(AppAnimation.standard, value: chromeAutoHide.controlsVisible)
    }

    private var landscapeTransportRow: some View {
        HStack(spacing: 14) {
            // C8: only the configured slots render (shuffle / repeat have no
            // button in this row, so those slots do not affect it).
            if PlayerControlSlot.isSelected(.previous, in: settings) {
                circleButton(icon: "backward.fill", size: 18) {
                    player.previous()
                }
                .accessibilityLabel("上一首")
            }

            if PlayerControlSlot.isSelected(.playPause, in: settings) {
                playPauseButton(diameter: 50, glyphSize: 20)
            }

            if PlayerControlSlot.isSelected(.next, in: settings) {
                circleButton(icon: "forward.fill", size: 18) {
                    player.next()
                }
                .accessibilityLabel("下一首")
            }

            if let track = player.currentTrack {
                let liked = account.isLiked(track.id)
                Button {
                    Task { await account.toggleLike(trackID: track.id) }
                } label: {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(liked ? themeAccent : .white.opacity(0.85))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(liked ? "取消喜欢" : "喜欢")
            } else {
                // Keep the trailing slot so the transport never shifts.
                Color.clear.frame(width: 40, height: 40)
            }
        }
        .accessibilityIdentifier("landscapeTransportRow")
        .opacity(chromeAutoHide.controlsVisible ? 1 : 0)
        .allowsHitTesting(chromeAutoHide.controlsVisible)
        .animation(AppAnimation.standard, value: chromeAutoHide.controlsVisible)
        .onTapGesture { chromeAutoHide.resetTimer() }
    }

    /// A continuously moving backdrop for the karaoke page: the blurred cover
    /// drifts and breathes while two artwork-tinted glows slide across it.
    ///
    /// `TimelineView` drives the phase rather than a `repeatForever`
    /// animation on `@State`: the artwork image arrives asynchronously, and an
    /// image inserted after the animation started inherited its end value and
    /// stayed still — the reported "动态背景不动".
    private struct AnimatedKaraokeBackdrop: View {
        let image: PlatformImage?
        let colors: ArtworkColors
        var isPaused = false

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @EnvironmentObject private var settings: SettingsManager

        private static let cycle: TimeInterval = 18

        /// The drifting backdrop stills in static mode, or when the
        /// background reduce-motion override says so (C4/C5).
        private var motionStilled: Bool {
            reduceMotion || settings.effectiveStaticMode || settings.effectiveReduceMotionBackground
        }

        var body: some View {
            // Reduce Motion holds the backdrop at its rest pose instead of
            // redrawing a full-screen blur 24 times a second.
            TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: motionStilled || isPaused)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let sway = motionStilled ? 0 : sin(t * 2 * .pi / Self.cycle)
                let breathe = motionStilled ? 0 : cos(t * 2 * .pi / (Self.cycle * 0.78))

                GeometryReader { geo in
                    ZStack {
                        LinearGradient(
                            colors: [colors.primary, colors.secondary],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )

                        // B3: with native blur off, the blurred artwork layer
                        // is omitted outright (an unblurred 1.5x cover would
                        // read as a smear); the tinted gradients remain.
                        if settings.effectivePlayerPageNativeBlur, let image {
                            Image(platformImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(
                                    width: geo.size.width * 1.5,
                                    height: geo.size.height * 1.5
                                )
                                .blur(radius: 70)
                                .drawingGroup()
                                .rotationEffect(.degrees(2.5 * sway))
                                .scaleEffect(1.02 + 0.08 * breathe)
                                .offset(
                                    x: geo.size.width * 0.06 * sway,
                                    y: geo.size.height * 0.05 * breathe
                                )
                                .opacity(0.62)
                        }

                        RadialGradient(
                            colors: [colors.primary.opacity(0.55), .clear],
                            center: .center, startRadius: 0,
                            endRadius: geo.size.width * 0.75
                        )
                        .frame(width: geo.size.width * 1.2, height: geo.size.width * 1.2)
                        .offset(
                            x: -geo.size.width * 0.28 + 60 * sway,
                            y: -geo.size.height * 0.22 + 40 * breathe
                        )
                        .blendMode(.plusLighter)
                        .drawingGroup()

                        RadialGradient(
                            colors: [colors.secondary.opacity(0.5), .clear],
                            center: .center, startRadius: 0,
                            endRadius: geo.size.width * 0.7
                        )
                        .frame(width: geo.size.width, height: geo.size.width)
                        .offset(
                            x: geo.size.width * 0.3 - 50 * breathe,
                            y: geo.size.height * 0.25 - 30 * sway
                        )
                        .blendMode(.plusLighter)
                        .drawingGroup()

                        LinearGradient(
                            colors: [.black.opacity(0.16), .black.opacity(0.5)],
                            startPoint: .top, endPoint: .bottom
                        )
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                }
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
        }
    }
    #endif

    @ViewBuilder
    private func compactLayout(size: CGSize) -> some View {
        #if os(iOS)
        switch settings.effectiveNowPlayingMode {
        case .vinyl:
            vinylCompactLayout(size: size)
        case .classic:
            classicCompactLayout(size: size)
        case .immersive:
            immersiveCompactLayout(size: size)
        case .minimal:
            minimalCompactLayout(size: size)
        case .lattice:
            latticeCompactLayout(size: size)
        case .luminous:
            luminousCompactLayout(size: size)
        }
        #else
        switch settings.nowPlayingMode {
        case .vinyl:
            vinylCompactLayout(size: size)
        default:
            classicCompactLayout(size: size)
        }
        #endif
    }

    #if os(iOS)
    /// Folia Lattice (P2): cover wall on top, big-lyrics card below,
    /// transport at the bottom. The wall *is* the queue — tap a tile to
    /// jump to that track — and the card is one static big-text style
    /// rendered on Canvas (no WebGL/PixiJS).
    ///
    /// Chosen as a compact-layout mode rather than a separate page so the
    /// existing backdrop, chrome rules and transport keep working
    /// unchanged. The queue toggle in the transport swaps the wall for
    /// the queue list (`CompactQueueContent`), like the other compact
    /// layouts do.
    private func latticeCompactLayout(size: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // The classic chrome overlays stay hidden in this mode (like
                // vinyl), so the header carries its own back button —
                // unless the always-show setting already puts one in the
                // overlay, in which case a second chevron would double up.
                if !settings.effectiveAlwaysShowPlayerBackButton {
                    collapseButton(diameter: 36, glyphSize: 14)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.currentTrack?.name ?? String(localized: "正在播放"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let artist = player.currentTrack?.artistNames, !artist.isEmpty {
                        Text(artist)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.top, 20)
            .padding(.horizontal, 20)
            .opacity(chromeAutoHide.controlsVisible ? 1 : 0)
            .allowsHitTesting(chromeAutoHide.controlsVisible)
            .animation(AppAnimation.standard, value: chromeAutoHide.controlsVisible)

            Group {
                if showQueueOnMobile {
                    CompactQueueContent()
                        .transition(.opacity)
                } else {
                    LatticeWallView(
                        queue: player.queue,
                        currentTrackID: player.currentTrack?.id,
                        onSelect: { player.jumpTo($0) }
                    )
                }
            }
            .frame(height: min(max(size.height * 0.30, 150), 260))
            .padding(.top, 12)

            LatticeLyricsCard(
                lyrics: player.lyrics,
                activeIndex: lyricsCursor.activeIndex,
                accent: themeAccent,
                tint: theme.tint,
                showTranslation: settings.showLyricsTranslation,
                showRomaji: settings.lyricsAnnotation == .romaji,
                animate: player.isPlaying && !settings.effectiveStaticMode,
                fontScale: settings.effectiveLyricsFontScale,
                // D9: the lattice card used to hardcode `.system` fonts and
                // ignore the lyric-style settings — the font, word-motion
                // and opacity settings now flow in, like the luminous view.
                fontStyle: settings.effectiveLyricsFontStyle,
                fontWeight: settings.effectiveLyricsFontWeight.map(Font.Weight.fromFoliaValue) ?? .bold,
                customFontName: settings.effectiveLyricsCustomFont,
                wordRotation: settings.effectiveClassicWordRotation,
                breathingFloat: settings.effectiveClassicBreathingFloat,
                wordSpacing: CGFloat(settings.effectiveClassicWordSpacing),
                avoidOverlap: settings.effectiveClassicAvoidOverlap,
                opacity: settings.effectiveVisualizerOpacity
            )
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Spacer(minLength: 8)

            immersiveControls
        }
        .frame(width: max(size.width - 64, 0))
        .padding(.horizontal, 32)
    }

    /// Folia classic (流光): full-screen big lyrics, one line at a time,
    /// words glowing in turn over the nomand halftone cover background
    /// (see `backdrop(isCompact:)`). The header mirrors the lattice
    /// layout's — the classic chrome overlays stay hidden in this mode,
    /// so it carries its own back button. The queue toggle swaps the
    /// lyrics for the queue list, like the other compact layouts.
    /// The bottom row carries the queue toggle on the left and the
    /// lyric-style window button (Settings2) on the right.
    private func luminousCompactLayout(size: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if !settings.effectiveAlwaysShowPlayerBackButton {
                    collapseButton(diameter: 36, glyphSize: 14)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.currentTrack?.name ?? String(localized: "正在播放"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if let artist = player.currentTrack?.artistNames, !artist.isEmpty {
                        Text(artist)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.top, 20)
            .padding(.horizontal, 20)
            .opacity(chromeAutoHide.controlsVisible ? 1 : 0)
            .allowsHitTesting(chromeAutoHide.controlsVisible)
            .animation(AppAnimation.standard, value: chromeAutoHide.controlsVisible)

            Group {
                if showQueueOnMobile {
                    CompactQueueContent()
                        .transition(.opacity)
                } else {
                    LuminousLyricsView(accent: themeAccent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 8)

            VStack(spacing: 17) {
                // C6: the progress bar hides with the setting.
                if !settings.effectiveHidePlayerProgressBar {
                    NowPlayingScrubber()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                CompactTransportControls()
                HStack(spacing: 0) {
                    Button {
                        withAnimation(AppAnimation.standard) {
                            showQueueOnMobile.toggle()
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(showQueueOnMobile ? themeAccent : .white.opacity(0.72))
                            .frame(width: 44, height: 44)
                            .background(.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel(showQueueOnMobile ? "关闭播放队列" : "显示播放队列")
                    .accessibilityAddTraits(showQueueOnMobile ? .isSelected : [])

                    Spacer()

                    SleepTimerMenu(player: player, iconOnly: true)

                    Spacer()

                    Button {
                        showLyricStyleSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(.white.opacity(0.72))
                            .frame(width: 44, height: 44)
                            .background(.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("歌词样式")
                }
            }
            .padding(.top, 14)
            .padding(.bottom, 10)
            .padding(.horizontal, 20)
            .opacity(chromeAutoHide.controlsVisible ? 1 : 0)
            .allowsHitTesting(chromeAutoHide.controlsVisible)
            .animation(AppAnimation.standard, value: chromeAutoHide.controlsVisible)
            .onTapGesture { chromeAutoHide.resetTimer() }
        }
        .frame(width: max(size.width - 64, 0))
        .padding(.horizontal, 32)
        .sheet(isPresented: $showLyricStyleSettings) {
            NavigationStack {
                LyricStyleSettingsView(showsDoneButton: true)
            }
        }
    }
    #endif

    private func vinylCompactLayout(size: CGSize) -> some View {
        let discDimension = min(size.width - 64, size.height * 0.42, 320)
        let showsVinyl = !showLyricsOnMobile && !showQueueOnMobile

        return VStack(spacing: 0) {
            #if os(iOS)
            Color.clear.frame(
                height: NowPlayingPresentationMetrics.immersiveHeaderTopInset
            )

            CompactTrackHeader(
                showsExpandedArtwork: showsVinyl,
                accent: themeAccent,
                onOpenDestination: onOpenDestination
            )
                .padding(.bottom, 10)
                .opacity(chromeAutoHide.controlsVisible ? 1 : 0)
                .allowsHitTesting(chromeAutoHide.controlsVisible)
                .animation(AppAnimation.standard, value: chromeAutoHide.controlsVisible)
            #else
            Spacer().frame(height: 30)
            trackMetaView
                .padding(.bottom, 10)
            #endif

            ZStack {
                if showsVinyl {
                    VStack(spacing: 12) {
                        Spacer(minLength: 4)

                        VinylTurntableView(
                            artworkImage: artworkImage,
                            isPlaying: player.isPlaying,
                            trackId: player.currentTrack?.id,
                            size: discDimension,
                            onTap: {
                                withAnimation(AppAnimation.standard) {
                                    showLyricsOnMobile = true
                                }
                            },
                            onNextTrack: {
                                player.next()
                            },
                            onPreviousTrack: {
                                player.previous()
                            }
                        )
                        .accessibilityIdentifier("vinylTurntable")

                        MiniLyricsView(onOpen: {
                            withAnimation(AppAnimation.standard) {
                                showLyricsOnMobile = true
                            }
                        })
                        .frame(maxWidth: .infinity, maxHeight: 70)

                        Spacer(minLength: 0)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else if showQueueOnMobile {
                    #if os(iOS)
                    CompactQueueContent()
                        .transition(.opacity)
                    #else
                    lyricsColumn
                        .transition(.opacity)
                    #endif
                } else {
                    #if os(iOS)
                    IOSImmersiveLyricsColumn()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(AppAnimation.standard) {
                                showLyricsOnMobile = false
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 1.05)))
                    #else
                    lyricsColumn
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(AppAnimation.standard) {
                                showLyricsOnMobile = false
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 1.05)))
                    #endif
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            #if os(iOS)
            immersiveControls
            #else
            VStack(spacing: 12) {
                // C6: the progress bar hides with the setting.
                if !settings.effectiveHidePlayerProgressBar {
                    NowPlayingScrubber()
                        .padding(.horizontal, 24)
                }
                controls()
            }
            .padding(.bottom, 24)
            #endif
        }
        .frame(width: max(size.width - 64, 0))
        .padding(.horizontal, 32)
    }

    private func classicCompactLayout(size: CGSize) -> some View {
        let artworkDim = BeansPlayerLayout.coverSize(for: size)
        return VStack(spacing: 20) {
            Spacer().frame(height: 44)
            if showLyricsOnMobile {
                lyricsColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            } else {
                VStack(spacing: 20) {
                    beansCoverPresentation(size: artworkDim)
                    trackMetaView
                    MiniLyricsView {
                        withAnimation(AppAnimation.standard) {
                            showLyricsOnMobile = true
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // Beans swipe-to-switch: the whole album panel slides with
                // the finger and fades slightly; past the threshold the
                // track changes and the panel springs back.
                .offset(x: classicSwipeOffset)
                .opacity(1 - min(abs(classicSwipeOffset) / BeansPlayerLayout.swipeFadeDistance, 0.35))
                .gesture(classicSwipeGesture)
                .transition(.opacity)
            }
            VStack(spacing: BeansPlayerLayout.deckSpacing) {
                // C6: the progress bar hides with the setting.
                if !settings.effectiveHidePlayerProgressBar {
                    NowPlayingScrubber(accent: beansPalette.accent, showsSeekPills: true)
                        .padding(.horizontal, 24)
                }
                controls()
            }
            .padding(.bottom, 24)
            .opacity(chromeAutoHide.controlsVisible ? 1 : 0)
            .allowsHitTesting(chromeAutoHide.controlsVisible)
            .animation(AppAnimation.standard, value: chromeAutoHide.controlsVisible)
            .onTapGesture { chromeAutoHide.resetTimer() }
        }
        .padding(.horizontal, 16)
    }

    /// Beans cover presentation (Beans' `classicAlbumPanel`): the artwork
    /// with its accent/secondary halo glow and a glass tray behind it.
    /// The halos are static — Beans holds them still in its current code.
    private func beansCoverPresentation(size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(beansPalette.accent.opacity(0.24))
                .frame(
                    width: size * BeansPlayerLayout.haloAccentScale,
                    height: size * BeansPlayerLayout.haloAccentScale
                )
                .blur(radius: 46)
            Circle()
                .fill(beansPalette.secondary.opacity(0.15))
                .frame(
                    width: size * BeansPlayerLayout.haloSecondaryScale,
                    height: size * BeansPlayerLayout.haloSecondaryScale
                )
                .blur(radius: 40)
            RoundedRectangle(
                cornerRadius: BeansPlayerLayout.coverCornerRadius(for: size),
                style: .continuous
            )
            .fill(.ultraThinMaterial)
            .frame(
                width: size * BeansPlayerLayout.coverTrayScale,
                height: size * BeansPlayerLayout.coverTrayScale
            )
            .shadow(color: .black.opacity(0.28), radius: 26, y: 12)
            artworkView(size: size)
        }
    }

    /// Horizontal swipe on the classic cover switches tracks (Beans'
    /// swipe-to-switch): left = next, right = previous. Only a mostly
    /// horizontal drag past the threshold counts; anything else springs
    /// the panel back to place.
    private var classicSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in
                let x = value.translation.width
                if abs(x) > abs(value.translation.height) {
                    classicSwipeOffset = x
                }
            }
            .onEnded { value in
                let x = value.translation.width
                defer {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        classicSwipeOffset = 0
                    }
                }
                guard abs(x) > BeansPlayerLayout.swipeThreshold,
                      abs(x) > abs(value.translation.height) else { return }
                if x < 0 {
                    player.next()
                } else {
                    player.previous()
                }
            }
    }

    #if os(iOS)
    private func immersiveCompactLayout(size: CGSize) -> some View {
        let artworkDimension = min(size.width - 112, size.height * 0.3, 250)
        let showsExpandedArtwork = !showLyricsOnMobile && !showQueueOnMobile

        return VStack(spacing: 0) {
            Color.clear.frame(
                height: NowPlayingPresentationMetrics.immersiveHeaderTopInset
            )

            CompactTrackHeader(
                showsExpandedArtwork: showsExpandedArtwork,
                accent: themeAccent,
                onOpenDestination: onOpenDestination,
                onTapArtwork: collapseImmersiveArtwork
            )
            .padding(.bottom, 14)
            .opacity(chromeAutoHide.controlsVisible ? 1 : 0)
            .allowsHitTesting(chromeAutoHide.controlsVisible)
            .animation(AppAnimation.standard, value: chromeAutoHide.controlsVisible)

            ZStack {
                immersiveArtworkContent(artworkDimension: artworkDimension)
                    .opacity(showsExpandedArtwork ? 1 : 0)
                    .allowsHitTesting(showsExpandedArtwork)
                    .accessibilityHidden(!showsExpandedArtwork)

                if showQueueOnMobile {
                    CompactQueueContent()
                        .transition(.opacity)
                } else {
                    IOSImmersiveLyricsColumn()
                        .opacity(showLyricsOnMobile ? 1 : 0)
                        .allowsHitTesting(showLyricsOnMobile)
                        .accessibilityHidden(!showLyricsOnMobile)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            immersiveControls
        }
        .frame(width: max(size.width - 64, 0))
        .padding(.horizontal, 32)
        .overlayPreferenceValue(ImmersiveArtworkFramePreferenceKey.self) { frames in
            GeometryReader { proxy in
                if let compactAnchor = frames[.compact],
                   let expandedAnchor = frames[.expanded] {
                    let compactFrame = proxy[compactAnchor]
                    let expandedFrame = proxy[expandedAnchor]
                    let targetFrame = showsExpandedArtwork ? expandedFrame : compactFrame
                    let targetCenterX = showsExpandedArtwork
                        ? size.width / 2
                        : compactFrame.midX

                    immersiveArtworkSurface(isExpanded: showsExpandedArtwork)
                        .frame(width: targetFrame.width, height: targetFrame.height)
                        .position(x: targetCenterX, y: targetFrame.midY)
                        .accessibilityIdentifier("immersiveArtwork")
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var immersiveControls: some View {
        VStack(spacing: 17) {
            // The source caption lives here for lattice/immersive;
            // vinyl already shows it in trackMetaView, so it is
            // hidden there to avoid showing it twice.
            if settings.effectiveNowPlayingMode != .vinyl {
                sourceCaption
            }
            // C6: the progress bar hides with the setting.
            if !settings.effectiveHidePlayerProgressBar {
                NowPlayingScrubber(accent: beansPalette.accent)
            }
            CompactTransportControls()
            CompactSecondaryControls(
                accent: themeAccent,
                showsLyrics: showLyricsOnMobile,
                showsQueue: showQueueOnMobile,
                onToggleLyrics: toggleImmersiveLyrics,
                onToggleQueue: toggleImmersiveQueue,
                onOpenSoundEffects: { showSoundEffects = true }
            )
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
        .accessibilityIdentifier("immersiveControls")
        .opacity(chromeAutoHide.controlsVisible ? 1 : 0)
        .allowsHitTesting(chromeAutoHide.controlsVisible)
        .animation(AppAnimation.standard, value: chromeAutoHide.controlsVisible)
        .onTapGesture { chromeAutoHide.resetTimer() }
    }

    private func immersiveArtworkContent(artworkDimension: CGFloat) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 8)
            Color.clear
                .frame(width: artworkDimension, height: artworkDimension)
                .anchorPreference(
                    key: ImmersiveArtworkFramePreferenceKey.self,
                    value: .bounds
                ) { [.expanded: $0] }
            MiniLyricsView(onOpen: showImmersiveLyrics)
                .frame(maxWidth: .infinity, maxHeight: 96)
            Spacer(minLength: 0)
        }
    }

    private func immersiveArtworkSurface(isExpanded: Bool) -> some View {
        Group {
            if let artworkImage {
                Image(platformImage: artworkImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.white.opacity(isExpanded ? 0.06 : 0.1))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: isExpanded ? 48 : 18, weight: .light))
                            .foregroundStyle(.white.opacity(isExpanded ? 0.3 : 0.45))
                    }
            }
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: isExpanded ? 18 : 12,
                style: .continuous
            )
        )
        .shadow(
            color: .black.opacity(isExpanded ? 0.45 : 0.22),
            radius: isExpanded ? 36 : 10,
            y: isExpanded ? 18 : 4
        )
    }

    private func toggleImmersiveLyrics() {
        withAnimation(ImmersiveArtworkTransition.animation) {
            if showQueueOnMobile {
                showQueueOnMobile = false
                showLyricsOnMobile = true
            } else {
                showLyricsOnMobile.toggle()
            }
        }
    }

    private func showImmersiveLyrics() {
        withAnimation(ImmersiveArtworkTransition.animation) {
            showQueueOnMobile = false
            showLyricsOnMobile = true
        }
    }

    /// Tapping the top-left cover while lyrics/queue are up returns to the
    /// expanded artwork — the Apple Music gesture requested in #50. Idempotent,
    /// so a tap while already expanded is a harmless no-op.
    private func collapseImmersiveArtwork() {
        guard showLyricsOnMobile || showQueueOnMobile else { return }
        withAnimation(ImmersiveArtworkTransition.animation) {
            showLyricsOnMobile = false
            showQueueOnMobile = false
        }
    }

    private func toggleImmersiveQueue() {
        withAnimation(ImmersiveArtworkTransition.animation) {
            showQueueOnMobile.toggle()
        }
    }

    private func minimalCompactLayout(size: CGSize) -> some View {
        let contentWidth = max(size.width - 64, 0)
        let artworkDimension = min(contentWidth, size.height * 0.52, 378)

        return VStack(spacing: 0) {
            ZStack(alignment: .top) {
                Color.clear
                MinimalTrackInfoRow(
                    accent: themeAccent,
                    onOpenDestination: onOpenDestination,
                    onOpenSoundEffects: { showSoundEffects = true },
                    metadataOnly: true
                )
                    .padding(.top, NowPlayingPresentationMetrics.immersiveHeaderTopInset)
                    .opacity(showLyricsOnMobile ? 1 : 0)
                    .accessibilityHidden(!showLyricsOnMobile)
            }
            .frame(height: 90)

            ZStack(alignment: .top) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggleMinimalLyrics)

                artworkView(size: artworkDimension)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggleMinimalLyrics)
                    .accessibilityIdentifier("immersiveArtwork")
                    .accessibilityLabel("显示歌词")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { toggleMinimalLyrics() }
                    .opacity(showLyricsOnMobile ? 0 : 1)
                    .allowsHitTesting(!showLyricsOnMobile)

                IOSMinimalLyricsColumn {
                    showLyricsOnMobile = false
                }
                .opacity(showLyricsOnMobile ? 1 : 0)
                .allowsHitTesting(showLyricsOnMobile)
                .accessibilityHidden(!showLyricsOnMobile)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .simultaneousGesture(
                minimalDismissGesture,
                including: showLyricsOnMobile ? .none : .all
            )
            .padding(.bottom, 20)

            minimalControls
        }
        .frame(width: contentWidth)
        .padding(.horizontal, 32)
        .padding(.bottom, 32)
        .animation(.easeInOut(duration: 0.22), value: showLyricsOnMobile)
    }

    private var minimalControls: some View {
        VStack(spacing: 22) {
            ZStack {
                MinimalTrackInfoRow(accent: themeAccent, onOpenDestination: onOpenDestination, onOpenSoundEffects: { showSoundEffects = true })
                    .opacity(showLyricsOnMobile ? 0 : 1)
                    .allowsHitTesting(!showLyricsOnMobile)
                    .accessibilityHidden(showLyricsOnMobile)
                MinimalTrackInfoRow(
                    accent: themeAccent,
                    onOpenDestination: onOpenDestination,
                    onOpenSoundEffects: { showSoundEffects = true },
                    actionsOnly: true
                )
                    .opacity(showLyricsOnMobile ? 1 : 0)
                    .allowsHitTesting(showLyricsOnMobile)
                    .accessibilityHidden(!showLyricsOnMobile)
            }
            .frame(height: 44)
            // C6: the progress bar hides with the setting.
            if !settings.effectiveHidePlayerProgressBar {
                NowPlayingScrubber(accent: beansPalette.accent)
                    .padding(.horizontal, 2)
                    .padding(.top, 16)
            }
            MinimalTransportControls(
                accent: themeAccent,
                backdrop: colors,
                showQueue: $showQueueOnMobile,
                onOpenDestination: onOpenDestination
            )
                .padding(.horizontal, 2)
        }
        .accessibilityIdentifier("immersiveControls")
    }

    private func toggleMinimalLyrics() {
        guard showLyricsOnMobile || player.lyrics?.isEmpty == false else { return }
        showLyricsOnMobile.toggle()
    }

    private var minimalDismissGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                guard let dismissNowPlayingDragAction else { return }
                let translation = value.translation
                let isDownward = translation.height > 0
                    && abs(translation.height) > abs(translation.width)
                dismissNowPlayingDragAction.onChanged(isDownward ? translation.height : 0)
            }
            .onEnded { value in
                guard let dismissNowPlayingDragAction else { return }
                let translation = value.translation
                let isDownward = translation.height > 0
                    && abs(translation.height) > abs(translation.width)
                dismissNowPlayingDragAction.onEnded(
                    isDownward ? translation.height : 0,
                    isDownward ? value.predictedEndTranslation.height : 0
                )
            }
    }
    #endif

    // MARK: - Views

    private func artworkView(
        size: CGFloat,
        shadowRadius: CGFloat = 36,
        cornerRadius: CGFloat = 18
    ) -> some View {
        Group {
            if settings.openAlbumOnArtworkClick,
               let album = player.currentTrack?.album, album.id > 0, !album.name.isEmpty {
                Button {
                    onOpenDestination(.album(album.id))
                } label: {
                    artworkSurface(size: size, shadowRadius: shadowRadius, cornerRadius: cornerRadius)
                }
                .buttonStyle(.plain)
                .noFocusRing()
                .accessibilityLabel("打开专辑：\(album.name)")
            } else {
                artworkSurface(size: size, shadowRadius: shadowRadius, cornerRadius: cornerRadius)
            }
        }
    }

    private func artworkSurface(
        size: CGFloat,
        shadowRadius: CGFloat = 36,
        cornerRadius: CGFloat = 18
    ) -> some View {
        ZStack {
            Rectangle()
                .fill(.white.opacity(0.06))
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.white.opacity(0.3))
                )
            if let artworkImage {
                Image(platformImage: artworkImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            // Beans cover presentation: a hairline border plus the top
            // glass highlight over the artwork.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.28), lineWidth: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.28), .white.opacity(0.03), .clear],
                        startPoint: .top, endPoint: .center
                    )
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: shadowRadius, y: shadowRadius * 0.5)
        .animation(
            settings.effectiveStaticMode || settings.effectiveReduceMotionTransitions
                ? nil : .easeIn(duration: 0.25),
            value: artworkImage != nil
        )
        .scaleEffect(player.isPlaying ? 1 : 0.95)
        // The play/pause pulse is a micro-motion (C4/C5).
        .animation(
            settings.effectiveStaticMode || settings.effectiveReduceMotionMicroMotion
                ? nil : AppAnimation.bouncy,
            value: player.isPlaying
        )
    }

    /// The third-party source the current track resolved from, if
    /// any. The only place on iOS that names it persistently: the
    /// toast is transient and the macOS bar shows it only as a hover
    /// tooltip. Hidden for direct NetEase tracks, where there is no
    /// third-party source to name.
    @ViewBuilder
    private var sourceCaption: some View {
        if let source = player.unblockSource {
            Text("来自 \(source)")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
    }

    private var trackMetaView: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text(player.currentTrack?.name ?? "")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if player.currentTrack?.fee == 1 {
                    VIPBadge()
                }
            }
            if let track = player.currentTrack {
                NowPlayingTrackDestinationLinks(
                    track: track,
                    font: .system(size: 13.5),
                    color: .white.opacity(0.65),
                    onOpenDestination: onOpenDestination
                )
            }
            sourceCaption
        }
        .frame(maxWidth: 400)
    }

    private func leftColumn(artworkSize: CGFloat) -> some View {
        VStack(spacing: 26) {
            Spacer()

            if settings.nowPlayingMode == .vinyl {
                VinylTurntableView(
                    artworkImage: artworkImage,
                    isPlaying: player.isPlaying,
                    trackId: player.currentTrack?.id,
                    size: artworkSize,
                    onTap: {
                        player.togglePlayPause()
                    },
                    onNextTrack: {
                        player.next()
                    },
                    onPreviousTrack: {
                        player.previous()
                    }
                )
            } else {
                artworkView(size: artworkSize)
            }
            trackMetaView

            VStack(spacing: 14) {
                // C6: the progress bar hides with the setting.
                if !settings.effectiveHidePlayerProgressBar {
                    NowPlayingScrubber()
                        .frame(maxWidth: 380)
                }
                controls(showsSoundEffects: true)
            }

            Spacer()
        }
        .padding(.trailing, hasLyricsColumn ? 30 : 0)
    }

    private func controls(showsSoundEffects: Bool = false) -> some View {
        // Equal-width slots so the row always fits the screen: fixed-size
        // buttons in a plain HStack summed wider than a phone (≈430pt with the
        // like button), overflowing the layout and shoving the overlays and
        // metadata off the right edge. `maxWidth: .infinity` per control makes
        // the row scale to any width instead.
        HStack(spacing: 0) {
            // The like slot stays even when the track is briefly unavailable:
            // adding or removing it re-divides the equal-width row, which made
            // every other control jump sideways during a track change. It is
            // not a control slot, so it is always shown.
            Group {
                if let track = player.currentTrack {
                    let liked = account.isLiked(track.id)
                    circleButton(
                        icon: liked ? "heart.fill" : "heart",
                        size: 15, tint: liked ? themeAccent : nil
                    ) {
                        Task { await account.toggleLike(trackID: track.id) }
                    }
                    .accessibilityLabel(liked ? "取消喜欢" : "喜欢")
                } else {
                    Color.clear.frame(width: 40, height: 40)
                }
            }
            .frame(maxWidth: .infinity)

            // C8: the transport buttons render in the configured slot order
            // and subset. FM mode keeps its dislike button in place of the
            // shuffle slot (it is not a slot, so it is always shown there).
            if player.isFMMode {
                circleButton(icon: "trash", size: 14) {
                    player.fmTrash()
                }
                .accessibilityLabel("不喜欢")
                .frame(maxWidth: .infinity)
            }
            ForEach(PlayerControlSlot.effectiveSlots(from: settings)) { slot in
                // The route picker is not a slot; it keeps its old place
                // immediately before the repeat button, or at the end of the
                // row when repeat is hidden.
                if slot == .repeatMode {
                    RoutePickerButton(diameter: 40, glyphSize: 15)
                        .frame(maxWidth: .infinity)
                    // The sound-effects button is not a slot either; it keeps
                    // upstream's place right after the route picker, before repeat.
                    #if os(iOS)
                    if showsSoundEffects {
                        SoundEffectsButton(
                            action: { showSoundEffects = true },
                            diameter: 40,
                            glyphSize: 15
                        )
                        .frame(maxWidth: .infinity)
                    }
                    #endif
                }
                transportSlotControl(slot)
                    .frame(maxWidth: .infinity)
            }
            if !PlayerControlSlot.effectiveSlots(from: settings).contains(.repeatMode) {
                RoutePickerButton(diameter: 40, glyphSize: 15)
                    .frame(maxWidth: .infinity)
                #if os(iOS)
                if showsSoundEffects {
                    SoundEffectsButton(
                        action: { showSoundEffects = true },
                        diameter: 40,
                        glyphSize: 15
                    )
                    .frame(maxWidth: .infinity)
                }
                #endif
            }
        }
        .accessibilityIdentifier("nowPlayingTransport")
    }

    /// C8: the button for one control slot, or nothing when the slot has no
    /// button in the current mode (shuffle in FM is the trash button above;
    /// previous in FM only with the C7 pin). Actions and disabled states are
    /// the ones the row had before slots existed.
    @ViewBuilder
    private func transportSlotControl(_ slot: PlayerControlSlot) -> some View {
        switch slot {
        case .shuffle:
            if !player.isFMMode {
                // All three queue orders on the one button; the cycle skips
                // AutoMix wherever it could do nothing (AutoMix off, order
                // off), so this row keeps its present width and its two-state
                // behaviour there — as it does on iOS, which has no AutoMix at
                // all. Only the three values below differ per platform.
                circleButton(
                    icon: queueOrderIcon, size: 14,
                    tint: queueOrderIsActive ? themeAccent : nil,
                    action: cycleQueueOrder
                )
                #if os(macOS)
                .accessibilityLabel(player.queueOrder.controlHelp)
                #else
                .accessibilityLabel("随机播放")
                .accessibilityAddTraits(player.shuffleEnabled ? .isSelected : [])
                #endif
            }
        case .previous:
            // C7: the setting pins the previous button visible even where FM
            // mode would otherwise swap its slot for dislike.
            if !player.isFMMode || settings.effectiveAlwaysShowTrackSwitchButtons {
                circleButton(icon: "backward.fill", size: 16) {
                    player.previous()
                }
                .accessibilityLabel("上一首")
            }
        case .playPause:
            playPauseButton()
        case .next:
            circleButton(icon: "forward.fill", size: 16) {
                player.next()
            }
            .accessibilityLabel("下一首")
        case .repeatMode:
            if player.isFMMode {
                Image(systemName: "wave.3.right.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 40, height: 40)
            } else {
                circleButton(
                    icon: player.repeatMode == .one ? "repeat.1" : "repeat",
                    size: 14,
                    tint: player.repeatMode != .off ? themeAccent : nil
                ) {
                    player.cycleRepeatMode()
                }
                .accessibilityLabel("循环播放")
                .accessibilityValue(repeatModeAccessibilityValue)
            }
        }
    }

    private func playPauseButton(diameter: CGFloat = 58, glyphSize: CGFloat = 21) -> some View {
        Button {
            player.togglePlayPause()
        } label: {
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: diameter, height: diameter)
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: glyphSize, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .contentTransition(.opacity)
            }
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
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

    /// Spoken state of the repeat button, which cycles three modes.
    private var repeatModeAccessibilityValue: Text {
        switch player.repeatMode {
        case .off: return Text("不循环")
        case .all: return Text("列表循环")
        case .one: return Text("单曲循环")
        }
    }

    private var queueOrderIsActive: Bool {
        #if os(macOS)
        player.queueOrder != .listed
        #else
        player.shuffleEnabled
        #endif
    }

    private func cycleQueueOrder() {
        #if os(macOS)
        player.cycleQueueOrder()
        #else
        player.toggleShuffle()
        #endif
    }

    private func circleButton(icon: String, size: CGFloat,
                              tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint ?? .white.opacity(0.8))
                .frame(width: 40, height: 40)
                .background(.white.opacity(0.1), in: Circle())
        }
        .buttonStyle(.pressable)
    }

    // MARK: - Lyrics column

    @ViewBuilder
    private var lyricsColumn: some View {
        lyricsScroll(topInset: 200, bottomInset: 240, horizontalPadding: 24)
    }

    /// The scrolling lyric list shared by the regular page and the
    /// landscape immersive page. Insets are the space parked above and below
    /// the lines so the active one can sit mid-viewport; the short landscape
    /// page needs them much smaller than a full-height window does.
    @ViewBuilder
    private func lyricsScroll(
        topInset: CGFloat,
        bottomInset: CGFloat,
        horizontalPadding: CGFloat,
        karaoke: Bool = false
    ) -> some View {
        if let lyrics = player.lyrics, !lyrics.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: karaoke ? .center : .leading,
                               spacing: karaoke ? 20 : 26) {
                        Color.clear.frame(height: topInset)
                        ForEach(lyrics.lines) { line in
                            Group {
                                if karaoke {
                                    landscapeKaraokeLine(line, isActive: line.id == activeIndex)
                                } else {
                                    bigLyricLine(line, isActive: line.id == activeIndex)
                                }
                            }
                            .id(line.id)
                        }
                        Color.clear.frame(height: bottomInset)
                    }
                    .padding(.horizontal, horizontalPadding)
                }
                // Inside the per-track identity so a mid-flick track change
                // tears the tracking down with the list and clears the flag.
                .lyricsScrollTracking(isUserScrolling: $isUserScrolling)
                // A new track gets a fresh list: reusing the old scroll view
                // crossfaded the outgoing and incoming lines on top of each
                // other for one frame while `lyrics` reloaded.
                .id(player.currentTrack?.id)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.12),
                            .init(color: .black, location: 0.85),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .onChange(of: lyricsCursor.activeIndex) { index in
                    guard index != activeIndex else { return }
                    activeIndex = index
                    guard !isUserScrolling, let index else { return }
                    withAnimation(lyricAnimation(.spring(response: 0.8, dampingFraction: 0.85))) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
                .onAppear {
                    // The cursor only fires on a line change, which can be many
                    // seconds away — on re-entering the page, adopt where the
                    // song already is instead of waiting for the next line.
                    adoptCursor(proxy: proxy)
                }
                .onChange(of: player.currentTrack?.id) { _ in
                    activeIndex = nil
                    isUserScrolling = false
                }
            }
        } else if player.lyrics?.isInstrumental == true {
            VStack(spacing: 10) {
                Image(systemName: "music.quarternote.3")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.white.opacity(0.4))
                Text("纯音乐，请欣赏")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func bigLyricLine(_ line: LyricLine, isActive: Bool) -> some View {
        Button {
            player.seek(to: line.time)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                if settings.lyricsAnnotation == .romaji, let romaji = line.romaji {
                    Text(romaji)
                        .font(.system(size: isActive ? 15 : 13, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                }
                LyricMainText(
                    line: line, isActive: isActive,
                    size: isActive ? 26 : 20, weight: isActive ? .bold : .semibold,
                    verbatim: settings.verbatimLyrics
                )
                if settings.showLyricsTranslation, let translation = line.translation {
                    Text(translation)
                        .font(.system(size: isActive ? 16 : 14, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .blur(radius: isActive || isUserScrolling ? 0 : 0.6)
            .scaleEffect(isActive ? 1.02 : 1, anchor: .leading)
        }
        .buttonStyle(.plain)
        .animation(lyricAnimation(.spring(response: 0.4, dampingFraction: 0.8)), value: isActive)
        .animation(lyricAnimation(.easeOut(duration: 0.25)), value: isUserScrolling)
    }

    /// Centre-aligned karaoke line for the landscape page. The active line is
    /// large and carries the verbatim wipe like a KTV subtitle; the neighbours
    /// stay smaller and dimmer so the eye follows the sung line.
    private func landscapeKaraokeLine(_ line: LyricLine, isActive: Bool) -> some View {
        Button {
            player.seek(to: line.time)
        } label: {
            VStack(spacing: 7) {
                if settings.lyricsAnnotation == .romaji, let romaji = line.romaji {
                    Text(romaji)
                        .font(.system(size: isActive ? 16 : 13, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.3))
                }
                LyricMainText(
                    line: line, isActive: isActive,
                    size: isActive ? 32 : 21,
                    weight: isActive ? .bold : .medium,
                    verbatim: settings.verbatimLyrics,
                    alignment: .center
                )
                if settings.showLyricsTranslation, let translation = line.translation {
                    Text(translation)
                        .font(.system(size: isActive ? 17 : 14, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.72 : 0.3))
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .opacity(isActive ? 1 : 0.6)
            .scaleEffect(isActive ? 1 : 0.97)
            .blur(radius: isActive || isUserScrolling ? 0 : 0.4)
            .shadow(color: .black.opacity(isActive ? 0.45 : 0),
                    radius: isActive ? 18 : 0, y: isActive ? 6 : 0)
        }
        .buttonStyle(.plain)
        .animation(lyricAnimation(.spring(response: 0.4, dampingFraction: 0.85)), value: isActive)
        .animation(lyricAnimation(.easeOut(duration: 0.25)), value: isUserScrolling)
    }
}


/// The main lyric line. Renders karaoke-style per-character highlighting from
/// verbatim (`yrc`) timings, driven live by the player, when the line is active
/// and verbatim data exists; otherwise a plain line.
///
/// Whether the line carries furigana is `LyricText`'s decision; the wipe is
/// handed down as per-character opacity so it reads the same either way.
struct LyricMainText: View {
    let line: LyricLine
    let isActive: Bool
    let size: CGFloat
    let weight: Font.Weight
    let verbatim: Bool
    var inactiveOpacity: Double = 0.45
    var alignment: NSTextAlignment = .left

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    @ObservedObject private var windowVisibility = MainWindowVisibility.shared

    /// The word-by-word wipe only runs for styles that animate word by word;
    /// `none` and `lineHighlight` render the line as a unit (C15).
    private var usesWordWipe: Bool {
        settings.effectiveLyricAnimationStyle == .fade
            || settings.effectiveLyricAnimationStyle == .karaokeZoom
    }

    var body: some View {
        if isActive, verbatim, usesWordWipe, let words = line.words, !words.isEmpty {
            #if os(macOS)
            // The wipe runs on a display link inside the host: a per-frame
            // SwiftUI value here re-measured the page's whole layout while a
            // verbatim line was up (see KaraokeLyricLine).
            KaraokeLyricLine(
                line: line,
                words: words,
                size: size,
                weight: weight,
                alignment: alignment,
                playing: player.isPlaying && windowVisibility.isVisible
            )
            #else
            TimelineView(.animation(
                minimumInterval: 1 / 30,
                paused: !player.isPlaying || !windowVisibility.isVisible
            )) { _ in
                let alphas = Self.alphas(for: line, words: words, at: player.livePlaybackTime)
                LyricText(
                    line: line, size: size, weight: weight, color: .white,
                    alignment: alignment,
                    alphas: alphas
                )
                // C15 karaokeZoom: the line grows as its words are sung,
                // driven by the same verbatim timings as the wipe. Every
                // other style reads scale 1 (no visible change), so the
                // default `fade` behaviour is untouched.
                .scaleEffect(
                    karaokeZoomScale(alphas: alphas),
                    anchor: alignment == .center ? .center : .leading
                )
            }
            #endif
        } else {
            LyricText(
                line: line, size: size, weight: weight,
                color: .white.opacity(isActive ? 1 : inactiveOpacity),
                alignment: alignment
            )
            // C15 lineHighlight: the active line sits on a highlight bar.
            .lineHighlight(when: settings.effectiveLyricAnimationStyle == .lineHighlight && isActive)
        }
    }

    /// Whole-line scale for the karaokeZoom style: 1.0 at the line's start,
    /// growing to 1.05 as the last word is sung. On macOS the wipe runs on
    /// the display-link host, so there is no per-frame SwiftUI value to
    /// scale with — the style falls back to the wipe alone there.
    private func karaokeZoomScale(alphas: [Double]) -> CGFloat {
        guard settings.effectiveLyricAnimationStyle == .karaokeZoom,
              !settings.effectiveStaticMode, !alphas.isEmpty else { return 1 }
        let sung = alphas.filter { $0 > 0.9 }.count
        return 1 + 0.05 * CGFloat(sung) / CGFloat(alphas.count)
    }

    /// One opacity per character of `line.text`: sung characters are bright,
    /// the current one fades in, unsung stay dim. A word's time is shared by
    /// its letters; punctuation and spaces take none and light up with the
    /// character before them (or the first one, when they open the line).
    static func alphas(for line: LyricLine, words: [LyricWord], at time: TimeInterval) -> [Double] {
        let unsung = 0.28
        var out: [Double] = []
        for word in words {
            let chars = Array(word.text)
            guard !chars.isEmpty else { continue }
            let letters = chars.indices.filter { chars[$0].isLetter || chars[$0].isNumber }
            let slots = letters.isEmpty ? Array(chars.indices) : letters
            // A token the service timed at nothing still ramps, over 50 ms.
            let per = max(word.duration, 0.05) / Double(slots.count)
            var lit: [Int: Double] = [:]
            for (slot, index) in slots.enumerated() {
                let frac = min(max((time - (word.start + per * Double(slot))) / per, 0), 1)
                lit[index] = unsung + (1 - unsung) * frac
            }
            let opening = lit[slots[0]] ?? unsung
            for index in chars.indices {
                out.append(lit[index] ?? out.last ?? opening)
            }
        }
        // The words' text joined is the line's text; should they ever differ,
        // keep one opacity per character of the line.
        let joined = words.map(\.text).joined()
        guard joined.count != line.text.count else { return out }
        let leading = joined.count - joined.drop(while: \.isWhitespace).count
        return Array(out.dropFirst(leading).prefix(line.text.count))
    }
}

private extension View {
    /// C15: the lineHighlight lyric style puts the active line on a soft
    /// highlight bar; every other style leaves the line untouched.
    @ViewBuilder
    func lineHighlight(when highlighted: Bool) -> some View {
        if highlighted {
            self
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(0.14))
                )
        } else {
            self
        }
    }
}

#if os(iOS)
private struct IOSImmersiveLyricsColumn: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var lyricsCursor = PlayerService.shared.lyricsCursor
    @EnvironmentObject private var settings: SettingsManager

    @State private var activeIndex: Int?
    @State private var isUserScrolling = false

    /// Line motion stills in static mode, with the "no animation" lyric
    /// style, or when transitions are reduced (C4/C5/C15).
    private var lyricAnimationsEnabled: Bool {
        !settings.effectiveStaticMode
            && settings.effectiveLyricAnimationStyle != .none
            && !settings.effectiveReduceMotionTransitions
    }

    /// Returns `animation` unless lyric motion is stilled, in which case nil
    /// (the view jumps straight to its final state).
    private func lyricAnimation(_ animation: Animation) -> Animation? {
        lyricAnimationsEnabled ? animation : nil
    }

    var body: some View {
        Group {
            if let lyrics = player.lyrics, !lyrics.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 22) {
                            Color.clear.frame(height: 72)
                            ForEach(lyrics.lines) { line in
                                lyricLine(
                                    line,
                                    isActive: line.id == activeIndex
                                )
                                .id(line.id)
                            }
                            Color.clear.frame(height: 96)
                        }
                        .padding(.horizontal, 4)
                    }
                    .mask(edgeMask)
                    .accessibilityIdentifier("syncedLyricsScroll")
                    .onChange(of: lyricsCursor.activeIndex) { index in
                        guard index != activeIndex else { return }
                        activeIndex = index
                        guard !isUserScrolling, let index else { return }
                        withAnimation(lyricAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.38))) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                    .onAppear {
                        adoptCursor(proxy: proxy)
                    }
                    .onChange(of: player.currentTrack?.id) { _ in
                        activeIndex = nil
                    }
                    .lyricsScrollTracking(isUserScrolling: $isUserScrolling) {
                        guard let activeIndex else { return }
                        withAnimation(lyricAnimation(.spring(response: 0.45, dampingFraction: 0.85))) {
                            proxy.scrollTo(activeIndex, anchor: .center)
                        }
                    }
                }
            } else if player.lyrics?.isInstrumental == true {
                VStack(spacing: 10) {
                    Image(systemName: "music.quarternote.3")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("纯音乐，请欣赏")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }


    /// Jump straight to the line the song is on. Used when the view appears,
    /// where waiting for the next line change would leave the lyrics parked at
    /// the top. Scrolling is deferred a turn: the list has not laid out yet
    /// while `onAppear` runs, and `scrollTo` on an unlaid list does nothing.
    private func adoptCursor(proxy: ScrollViewProxy) {
        let index = lyricsCursor.activeIndex
        activeIndex = index
        guard let index else { return }
        DispatchQueue.main.async {
            withAnimation(lyricAnimation(.spring(response: 0.5, dampingFraction: 0.85))) {
                proxy.scrollTo(index, anchor: .center)
            }
        }
    }

    private var edgeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.85),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func lyricLine(_ line: LyricLine, isActive: Bool) -> some View {
        Button {
            player.seek(to: line.time)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                if settings.lyricsAnnotation == .romaji, let romaji = line.romaji {
                    Text(romaji)
                        .font(.system(size: isActive ? 15 : 13, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.75 : 0.4))
                }

                LyricMainText(
                    line: line,
                    isActive: isActive,
                    size: isActive ? 26 : 21,
                    weight: isActive ? .bold : .semibold,
                    verbatim: settings.verbatimLyrics
                )

                if settings.showLyricsTranslation, let translation = line.translation {
                    Text(translation)
                        .font(.system(size: isActive ? 16 : 14, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.75 : 0.4))
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .blur(radius: isActive || isUserScrolling ? 0 : 0.4)
            .scaleEffect(isActive ? 1.02 : 1.0, anchor: .leading)
        }
        .buttonStyle(.plain)
        .animation(lyricAnimation(.spring(response: 0.35, dampingFraction: 0.85)), value: isActive)
        .animation(lyricAnimation(.easeOut(duration: 0.25)), value: isUserScrolling)
    }
}

// MARK: - Compact now-playing sections

private enum ImmersiveArtworkTransition {
    /// A time-based ease-out curve stays fluid at the display's native refresh rate.
    static let animation = Animation.timingCurve(
        0.16,
        1,
        0.3,
        1,
        duration: 0.42
    )
    static let compactArtworkDimension: CGFloat = 62
    static let compactHeaderSpacing: CGFloat = 13
    static let expandedMetadataOffset = -(
        compactArtworkDimension + compactHeaderSpacing
    )
}

private enum ImmersiveArtworkFrame: Hashable {
    case compact
    case expanded
}

private struct ImmersiveArtworkFramePreferenceKey: PreferenceKey {
    static var defaultValue: [ImmersiveArtworkFrame: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [ImmersiveArtworkFrame: Anchor<CGRect>],
        nextValue: () -> [ImmersiveArtworkFrame: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct CompactTrackHeader: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @State private var showAddToPlaylist = false

    let showsExpandedArtwork: Bool
    /// Resolved theme accent, passed down from NowPlayingView (C12/C14).
    let accent: Color
    let onOpenDestination: (Destination) -> Void
    /// Tap handler for the compact cover (used to collapse lyrics back to
    /// artwork). The real image floats above this placeholder with hit-testing
    /// disabled, so taps land here.
    var onTapArtwork: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: ImmersiveArtworkTransition.compactHeaderSpacing) {
            Color.clear
                .frame(
                    width: ImmersiveArtworkTransition.compactArtworkDimension,
                    height: ImmersiveArtworkTransition.compactArtworkDimension
                )
                .anchorPreference(
                    key: ImmersiveArtworkFramePreferenceKey.self,
                    value: .bounds
                ) { [.compact: $0] }
                .contentShape(Rectangle())
                .onTapGesture { onTapArtwork?() }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(player.currentTrack?.name ?? "")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if player.currentTrack?.fee == 1 {
                        VIPBadge()
                    }
                }
                if let track = player.currentTrack {
                    NowPlayingTrackDestinationLinks(
                        track: track,
                        font: .subheadline,
                        color: .white.opacity(0.62),
                        onOpenDestination: onOpenDestination
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(
                x: showsExpandedArtwork
                    ? ImmersiveArtworkTransition.expandedMetadataOffset
                    : 0
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("immersiveTrackMetadata")

            if let track = player.currentTrack {
                let liked = account.isLiked(track.id)
                HStack(spacing: 0) {
                    Button {
                        Task { await account.toggleLike(trackID: track.id) }
                    } label: {
                        Image(systemName: liked ? "heart.fill" : "heart")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(liked ? accent : .white.opacity(0.88))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel(liked ? "取消收藏" : "收藏")
                    .accessibilityIdentifier("immersiveFavoriteButton")

                    Menu {
                        TrackDownloadActions(track: track, showsIcons: true)
                        Divider()
                        Button {
                            player.addToPlayNext(track)
                        } label: {
                            Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }

                        Button {
                            showAddToPlaylist = true
                        } label: {
                            Label("加入歌单…", systemImage: "music.note.list")
                        }

                        Divider()

                        #if os(iOS)
                        SleepTimerMenu(player: player)

                        Divider()
                        #endif

                        Button {
                            Platform.copyToPasteboard(
                                string: Upstream.songPageURL(id: track.id)?.absoluteString ?? ""
                            )
                            ToastCenter.shared.show(String(localized: "链接已复制"))
                        } label: {
                            Label("复制链接", systemImage: "link")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("更多操作")
                    .accessibilityIdentifier("immersiveMoreMenu")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = player.currentTrack {
                AddToPlaylistSheet(track: track)
            }
        }
    }
}

private struct CompactTransportControls: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager

    var body: some View {
        HStack(spacing: 0) {
            // C7: the setting pins the previous button visible even where
            // FM mode would otherwise swap its slot for dislike.
            // C8: each transport button renders only when its slot is on.
            if player.isFMMode, settings.effectiveAlwaysShowTrackSwitchButtons,
               PlayerControlSlot.isSelected(.previous, in: settings) {
                Button {
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 25, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 58)
                }
                .accessibilityLabel("上一首")
            }

            if PlayerControlSlot.isSelected(.previous, in: settings) {
                Button {
                    if player.isFMMode { player.fmTrash() } else { player.previous() }
                } label: {
                    Image(systemName: player.isFMMode ? "trash" : "backward.fill")
                        .font(.system(size: 25, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 58)
                }
                .accessibilityLabel(player.isFMMode ? "不喜欢" : "上一首")
            }

            if PlayerControlSlot.isSelected(.playPause, in: settings) {
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 36, weight: .bold))
                        .contentTransition(.opacity)
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
                .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
            }

            if PlayerControlSlot.isSelected(.next, in: settings) {
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 25, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 58)
                }
                .accessibilityLabel("下一首")
            }
        }
        .foregroundStyle(.white)
        .buttonStyle(.pressable)
    }
}

#if os(iOS)
private struct CompactVolumePopover: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 16, weight: .medium))

            GeometryReader { geo in
                let height = geo.size.height
                let fraction = min(max(CGFloat(player.volume), 0), 1)
                ZStack(alignment: .bottom) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(0.82))
                        .frame(height: height * fraction)
                }
                .frame(width: isDragging ? 12 : 8)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            updateVolume(at: value.location.y, height: height)
                        }
                        .onEnded { value in
                            updateVolume(at: value.location.y, height: height)
                            isDragging = false
                        }
                )
                .animation(.spring(response: 0.24, dampingFraction: 0.82), value: isDragging)
            }
            .frame(width: 32, height: 132)
            .accessibilityElement()
            .accessibilityLabel("音量")
            .accessibilityValue("\(Int((player.volume * 100).rounded()))%")
            .accessibilityAdjustableAction(adjustVolume)

            Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: 14, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        // B3: with native blur off, a plain translucent fill replaces the
        // ultraThinMaterial behind the popover.
        .background(
            settings.effectivePlayerPageNativeBlur
                ? AnyShapeStyle(.ultraThinMaterial)
                : AnyShapeStyle(.white.opacity(0.16)),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(alignment: .bottom) {
            Triangle()
                .fill(.white.opacity(0.18))
                .frame(width: 16, height: 8)
                .offset(y: 8)
        }
    }

    private func updateVolume(at location: CGFloat, height: CGFloat) {
        guard height > 0 else { return }
        player.volume = Float(min(max(1 - location / height, 0), 1))
    }

    private func adjustVolume(_ direction: AccessibilityAdjustmentDirection) {
        let step: Float = 0.05
        switch direction {
        case .increment:
            player.volume = min(player.volume + step, 1)
        case .decrement:
            player.volume = max(player.volume - step, 0)
        @unknown default:
            break
        }
    }
}

private struct CompactSecondaryControls: View {
    @EnvironmentObject private var player: PlayerService
    @State private var showsVolumeControl = false
    /// Resolved theme accent, passed down from NowPlayingView (C12/C14).
    let accent: Color
    let showsLyrics: Bool
    let showsQueue: Bool
    let onToggleLyrics: () -> Void
    let onToggleQueue: () -> Void
    let onOpenSoundEffects: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            secondaryButton(
                icon: showsLyrics && !showsQueue ? "quote.bubble.fill" : "quote.bubble",
                label: showsLyrics ? "显示封面" : "显示歌词",
                isActive: showsLyrics && !showsQueue
            ) {
                onToggleLyrics()
            }

            RoutePickerButton(diameter: 44, glyphSize: 17)
                .frame(maxWidth: .infinity)

            SoundEffectsButton(
                action: onOpenSoundEffects,
                diameter: 44,
                glyphSize: 17
            )
            .frame(maxWidth: .infinity)

            secondaryButton(
                icon: volumeIcon,
                label: showsVolumeControl ? "关闭音量控制" : "显示音量控制",
                isActive: showsVolumeControl
            ) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    showsVolumeControl.toggle()
                }
            }
            .overlay(alignment: .bottom) {
                if showsVolumeControl {
                    CompactVolumePopover()
                        .offset(y: -44)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                        .zIndex(1)
                }
            }

            SleepTimerMenu(player: player, iconOnly: true)
                .frame(maxWidth: .infinity)

            secondaryButton(
                icon: "list.bullet",
                label: showsQueue ? "关闭播放队列" : "显示播放队列",
                isActive: showsQueue
            ) {
                onToggleQueue()
            }
        }
    }

    private var volumeIcon: String {
        let volume = player.volume
        if volume == 0 { return "speaker.slash" }
        if volume < 0.5 { return "speaker.wave.1" }
        return "speaker.wave.2"
    }

    private func secondaryButton(
        icon: String,
        label: LocalizedStringKey,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isActive ? accent : .white.opacity(0.72))
                .frame(width: 44, height: 44)
                .background(.white.opacity(0.08), in: Circle())
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
        }
    }
}
#endif

private struct CompactQueueContent: View {
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                modeButton(
                    icon: "arrow.right",
                    label: "顺序播放",
                    isActive: !player.shuffleEnabled && player.repeatMode == .off,
                    action: enableSequentialPlayback
                )
                modeButton(
                    icon: "shuffle",
                    label: player.shuffleEnabled ? "关闭随机播放" : "随机播放",
                    isActive: player.shuffleEnabled,
                    action: player.toggleShuffle
                )
                modeButton(
                    icon: "repeat",
                    label: "列表循环",
                    isActive: player.repeatMode == .all
                ) {
                    player.repeatMode = player.repeatMode == .all ? .off : .all
                }
                modeButton(
                    icon: "repeat.1",
                    label: "单曲循环",
                    isActive: player.repeatMode == .one
                ) {
                    player.repeatMode = player.repeatMode == .one ? .off : .one
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text("继续播放")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(player.upcomingTracks.count) 首")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.46))
            }

            if player.upcomingTracks.isEmpty {
                VStack(spacing: 8) {
                    PlaybackHandoffList()
                    Image(systemName: "list.bullet")
                        .font(.system(size: 28, weight: .light))
                    Text("播放队列是空的")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        PlaybackHandoffList()
                            .padding(.bottom, 4)
                        ForEach(
                            Array(player.upcomingTracks.prefix(100).enumerated()),
                            id: \.offset
                        ) { index, track in
                            CompactQueueRow(track: track, upcomingIndex: index)
                        }
                    }
                }
                .mask(
                    LinearGradient(
                        colors: [.black, .black, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .padding(.top, 6)
    }

    private func modeButton(
        icon: String,
        label: LocalizedStringKey,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isActive ? Color.black.opacity(0.76) : .white.opacity(0.76))
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(
                    isActive ? AnyShapeStyle(.white.opacity(0.66)) : AnyShapeStyle(.white.opacity(0.1)),
                    in: Capsule()
                )
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func enableSequentialPlayback() {
        if player.shuffleEnabled {
            player.toggleShuffle()
        }
        player.repeatMode = .off
    }
}

private struct CompactQueueRow: View {
    let track: Track
    let upcomingIndex: Int

    @EnvironmentObject private var player: PlayerService

    var body: some View {
        Button {
            player.jumpToUpcoming(at: upcomingIndex, matching: track.id)
        } label: {
            HStack(spacing: 11) {
                CachedAsyncImage(url: track.album.picUrl?.resizedImageURL(120), animated: false)
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Text(track.artistNames)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text(Formatters.duration(track.duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.36))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(track.name)，\(track.artistNames)")
    }
}



private struct IOSMinimalLyricsColumn: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var clock = PlayerService.shared.clock
    @EnvironmentObject private var settings: SettingsManager

    let onClose: () -> Void

    @State private var activeIndex: Int?
    @State private var selectedIndex: Int?
    @State private var nearestIndex: Int?
    @State private var lineCenters: [Int: CGFloat] = [:]
    @State private var isDragging = false
    @State private var suppressesAutoScroll = false
    @State private var scrollSettleTask: Task<Void, Never>?
    @State private var selectionTimeoutTask: Task<Void, Never>?

    /// Line motion stills in static mode, with the "no animation" lyric
    /// style, or when transitions are reduced (C4/C5/C15).
    private var lyricAnimationsEnabled: Bool {
        !settings.effectiveStaticMode
            && settings.effectiveLyricAnimationStyle != .none
            && !settings.effectiveReduceMotionTransitions
    }

    /// Returns `animation` unless lyric motion is stilled, in which case nil
    /// (the view jumps straight to its final state).
    private func lyricAnimation(_ animation: Animation) -> Animation? {
        lyricAnimationsEnabled ? animation : nil
    }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let lyrics = player.lyrics, !lyrics.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                Color.clear.frame(height: geometry.size.height / 2)
                                ForEach(lyrics.lines) { line in
                                    lyricLine(
                                        line,
                                        isActive: line.id == activeIndex,
                                        isSelected: line.id == selectedIndex,
                                        availableWidth: geometry.size.width
                                    ) {
                                        guard let selectedIndex else {
                                            closeLyrics()
                                            return
                                        }
                                        guard selectedIndex == line.id else {
                                            returnToActiveLine(proxy: proxy)
                                            return
                                        }
                                        selectionTimeoutTask?.cancel()
                                        selectionTimeoutTask = nil
                                        suppressesAutoScroll = true
                                        player.seek(to: line.time) {
                                            suppressesAutoScroll = false
                                        }
                                        activeIndex = line.id
                                        self.selectedIndex = nil
                                        nearestIndex = nil
                                    }
                                    .id(line.id)
                                    .background {
                                        GeometryReader { lineGeometry in
                                            Color.clear.preference(
                                                key: MinimalLyricCentersKey.self,
                                                value: [
                                                    line.id: lineGeometry.frame(
                                                        in: .named("immersiveLyrics")
                                                    ).midY
                                                ]
                                            )
                                        }
                                    }
                                }
                                Color.clear.frame(height: geometry.size.height / 2)
                            }
                            .padding(.horizontal, 2)
                        }
                        .coordinateSpace(name: "immersiveLyrics")
                        .mask(edgeMask)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: closeLyrics)
                        .accessibilityIdentifier("syncedLyricsScroll")
                        .onPreferenceChange(MinimalLyricCentersKey.self) { centers in
                            lineCenters = centers
                            guard isDragging || scrollSettleTask != nil else { return }
                            nearestIndex = nearestLine(
                                to: geometry.size.height / 2,
                                in: centers
                            )
                            guard !isDragging else { return }
                            scheduleScrollSelection(
                                guideY: geometry.size.height / 2,
                                proxy: proxy
                            )
                        }
                        .onAppear {
                            activeIndex = lyrics.activeIndex(at: clock.progress + 0.2)
                            if let activeIndex {
                                Task { @MainActor in
                                    await Task.yield()
                                    proxy.scrollTo(activeIndex, anchor: .center)
                                }
                            }
                        }
                        .onChange(of: clock.progress) { _ in
                            let index = lyrics.activeIndex(at: clock.progress + 0.2)
                            guard index != activeIndex else { return }
                            activeIndex = index
                            guard !suppressesAutoScroll,
                                  !isDragging, scrollSettleTask == nil,
                                  selectedIndex == nil, let index else { return }
                            withAnimation(lyricAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.38))) {
                                proxy.scrollTo(index, anchor: .center)
                            }
                        }
                        .onChange(of: player.currentTrack?.id) { _ in
                            activeIndex = nil
                            selectedIndex = nil
                            nearestIndex = nil
                            suppressesAutoScroll = false
                            scrollSettleTask?.cancel()
                            scrollSettleTask = nil
                            selectionTimeoutTask?.cancel()
                            selectionTimeoutTask = nil
                        }
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { _ in
                                    if !isDragging {
                                        scrollSettleTask?.cancel()
                                        scrollSettleTask = nil
                                        selectionTimeoutTask?.cancel()
                                        selectionTimeoutTask = nil
                                        selectedIndex = nil
                                        isDragging = true
                                    }
                                    nearestIndex = nearestLine(
                                        to: geometry.size.height / 2,
                                        in: lineCenters
                                    )
                                }
                                .onEnded { _ in
                                    isDragging = false
                                    scheduleScrollSelection(
                                        guideY: geometry.size.height / 2,
                                        proxy: proxy
                                    )
                                }
                        )
                        .overlay {
                            selectionGuide(lyrics: lyrics)
                        }
                    }
                } else if player.lyrics?.isInstrumental == true {
                    VStack(spacing: 10) {
                        Image(systemName: "music.quarternote.3")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(.white.opacity(0.4))
                        Text("纯音乐，请欣赏")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: closeLyrics)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onDisappear {
            scrollSettleTask?.cancel()
            selectionTimeoutTask?.cancel()
        }
    }

    @ViewBuilder
    private func selectionGuide(lyrics: ParsedLyrics) -> some View {
        let isScrolling = isDragging || scrollSettleTask != nil
        if let index = isScrolling ? nearestIndex : selectedIndex,
           lyrics.lines.indices.contains(index) {
            HStack(spacing: 8) {
                if isScrolling {
                    Canvas { context, size in
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: size.height / 2))
                        path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                        context.stroke(
                            path,
                            with: .color(.white.opacity(0.45)),
                            style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                        )
                    }
                    .frame(height: 1)
                } else {
                    Spacer()
                }

                Text(Formatters.duration(lyrics.lines[index].time))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.72))
                    .offset(x: 25)
            }
            .padding(.horizontal, 2)
            .allowsHitTesting(false)
        }
    }

    private func nearestLine(to guideY: CGFloat, in centers: [Int: CGFloat]) -> Int? {
        centers.min { abs($0.value - guideY) < abs($1.value - guideY) }?.key
    }

    private func scheduleScrollSelection(guideY: CGFloat, proxy: ScrollViewProxy) {
        scrollSettleTask?.cancel()
        // ponytail: iOS 16 has no scroll phase API; replace with onScrollPhaseChange
        // when the deployment target reaches iOS 18.
        scrollSettleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let selection = nearestLine(to: guideY, in: lineCenters) ?? nearestIndex
            selectedIndex = selection
            nearestIndex = selection
            scrollSettleTask = nil
            guard let selection else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                proxy.scrollTo(selection, anchor: .center)
            }
            scheduleSelectionTimeout(proxy: proxy)
        }
    }

    private func scheduleSelectionTimeout(proxy: ScrollViewProxy) {
        selectionTimeoutTask?.cancel()
        selectionTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, selectedIndex != nil else { return }
            returnToActiveLine(proxy: proxy)
        }
    }

    private func returnToActiveLine(proxy: ScrollViewProxy) {
        selectionTimeoutTask?.cancel()
        selectionTimeoutTask = nil
        selectedIndex = nil
        nearestIndex = nil
        guard let activeIndex else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            proxy.scrollTo(activeIndex, anchor: .center)
        }
    }

    private func closeLyrics() {
        scrollSettleTask?.cancel()
        scrollSettleTask = nil
        selectionTimeoutTask?.cancel()
        selectionTimeoutTask = nil
        selectedIndex = nil
        nearestIndex = nil
        isDragging = false
        onClose()
    }

    private var edgeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.85),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func lyricLine(
        _ line: LyricLine,
        isActive: Bool,
        isSelected: Bool,
        availableWidth: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                if settings.lyricsAnnotation == .romaji, let romaji = line.romaji {
                    Text(romaji)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                        .fixedSize(horizontal: false, vertical: true)
                        .scaleEffect(isActive ? 1.02 : 12.0 / 13.0, anchor: .leading)
                }

                LyricMainText(
                    line: line, isActive: isActive,
                    size: 17, weight: .bold,
                    verbatim: settings.verbatimLyrics
                )
                    .fixedSize(horizontal: false, vertical: true)
                    .scaleEffect(isActive ? 1.02 : 16.0 / 17.0, anchor: .leading)

                if settings.showLyricsTranslation, let translation = line.translation {
                    Text(translation)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.7 : 0.35))
                        .fixedSize(horizontal: false, vertical: true)
                        .scaleEffect(isActive ? 1.02 : 12.0 / 13.0, anchor: .leading)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(isSelected ? 0.14 : 0))
            )
            .contentShape(Rectangle())
            .padding(.trailing, availableWidth * (1 - 1 / 1.02))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(lyricAnimation(.spring(response: 0.28, dampingFraction: 0.9)), value: isActive)
        .animation(lyricAnimation(.easeOut(duration: 0.18)), value: isSelected)
    }
}

private struct MinimalLyricCentersKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

// MARK: - Minimal track info row

private struct MinimalTrackInfoRow: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var account: AccountStore
    @State private var showAddToPlaylist = false
    @State private var airPlayRequest = 0
    /// Resolved theme accent, passed down from NowPlayingView (C12/C14).
    let accent: Color
    let onOpenDestination: (Destination) -> Void
    let onOpenSoundEffects: () -> Void
    var metadataOnly = false
    var actionsOnly = false

    var body: some View {
        Group {
            if metadataOnly {
                metadata(alignment: .center, textAlignment: .center)
                    .padding(.horizontal, 48)
            } else if actionsOnly {
                if let track = player.currentTrack {
                    HStack {
                        favoriteButton(for: track)
                        Spacer()
                        SoundEffectsButton(
                            action: onOpenSoundEffects,
                            diameter: 44,
                            glyphSize: 18,
                            showsBackground: false
                        )
                        moreMenu(for: track)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    metadata(alignment: .leading, textAlignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let track = player.currentTrack {
                        favoriteButton(for: track)
                        SoundEffectsButton(
                            action: onOpenSoundEffects,
                            diameter: 44,
                            glyphSize: 18,
                            showsBackground: false
                        )
                        moreMenu(for: track)
                    }
                }
            }
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let track = player.currentTrack {
                AddToPlaylistSheet(track: track)
            }
        }
    }

    private func metadata(
        alignment: HorizontalAlignment,
        textAlignment: TextAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            HStack(spacing: 6) {
                Text(player.currentTrack?.name ?? "")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if player.currentTrack?.fee == 1 {
                    VIPBadge()
                }
            }
            if let track = player.currentTrack {
                NowPlayingTrackDestinationLinks(
                    track: track,
                    font: .footnote,
                    color: .white.opacity(0.62),
                    onOpenDestination: onOpenDestination
                )
            }
        }
        .multilineTextAlignment(textAlignment)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("immersiveTrackMetadata")
    }

    private func favoriteButton(for track: Track) -> some View {
        let liked = account.isLiked(track.id)
        return Button {
            Task { await account.toggleLike(trackID: track.id) }
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(liked ? accent : .white.opacity(0.88))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(liked ? "取消收藏" : "收藏")
        .accessibilityIdentifier("immersiveFavoriteButton")
    }

    private func moreMenu(for track: Track) -> some View {
        Menu {
            TrackDownloadActions(track: track, showsIcons: true)
            Divider()
            Button {
                airPlayRequest += 1
            } label: {
                Label("AirPlay", systemImage: "airplayaudio")
            }

            Button {
                player.addToPlayNext(track)
            } label: {
                Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
            }

            Button {
                showAddToPlaylist = true
            } label: {
                Label("加入歌单…", systemImage: "music.note.list")
            }

            Divider()

            #if os(iOS)
            SleepTimerMenu(player: player)

            Divider()
            #endif

            Button {
                Platform.copyToPasteboard(
                    string: Upstream.songPageURL(id: track.id)?.absoluteString ?? ""
                )
                ToastCenter.shared.show(String(localized: "链接已复制"))
            } label: {
                Label("复制链接", systemImage: "link")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("更多操作")
        .accessibilityIdentifier("immersiveMoreMenu")
        .background {
            RoutePickerButton(
                diameter: 1, glyphSize: 1, request: airPlayRequest,
                tint: .clear, background: .clear
            )
            .opacity(0.01)
        }
    }
}

private struct MinimalTransportControls: View {
    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    /// Resolved theme accent, passed down from NowPlayingView (C12/C14).
    let accent: Color
    let backdrop: ArtworkColors
    @Binding var showQueue: Bool
    let onOpenDestination: (Destination) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button {
                showQueue = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityLabel("播放列表")
            .accessibilityIdentifier("immersivePlaylistButton")
                .frame(maxWidth: .infinity)

            // C7: the setting pins the previous button visible even where
            // FM mode would otherwise swap its slot for dislike.
            // C8: each transport button renders only when its slot is on.
            if player.isFMMode, settings.effectiveAlwaysShowTrackSwitchButtons,
               PlayerControlSlot.isSelected(.previous, in: settings) {
                Button {
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 25, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 58)
                }
                .accessibilityLabel("上一首")
            }

            if PlayerControlSlot.isSelected(.previous, in: settings) {
                Button {
                    if player.isFMMode { player.fmTrash() } else { player.previous() }
                } label: {
                    Image(systemName: player.isFMMode ? "trash" : "backward.fill")
                        .font(.system(size: 25, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 58)
                }
                .accessibilityLabel(player.isFMMode ? "不喜欢" : "上一首")
            }

            if PlayerControlSlot.isSelected(.playPause, in: settings) {
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 38, weight: .bold))
                        .contentTransition(.opacity)
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
                .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
            }

            if PlayerControlSlot.isSelected(.next, in: settings) {
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 25, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 58)
                }
                .accessibilityLabel("下一首")
            }

            // The one playback-mode button stands for both the shuffle and
            // the repeat slot, so it shows when either is on.
            if PlayerControlSlot.isSelected(.shuffle, in: settings)
                || PlayerControlSlot.isSelected(.repeatMode, in: settings) {
                playbackModeButton
                    .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(.white)
        .buttonStyle(.pressable)
        .sheet(isPresented: $showQueue) {
            queueSheet
                .modifier(OfflinePlaybackAlert(player: player, onDownloads: {
                    showQueue = false
                    onOpenDestination(.downloaded)
                }, enabled: showQueue && player.showNowPlaying))
                .modifier(MeteredDownloadAlert(enabled: showQueue && player.showNowPlaying))
        }
    }

    @ViewBuilder
    private var queueSheet: some View {
        if #available(iOS 16.4, *) {
            IOSPlaybackQueueView(backdrop: backdrop)
                .presentationDetents([.fraction(0.5)])
                .presentationBackgroundInteraction(.enabled)
        } else {
            IOSPlaybackQueueView(backdrop: backdrop)
                .presentationDetents([.fraction(0.5)])
        }
    }

    @ViewBuilder
    private var playbackModeButton: some View {
        if player.isFMMode {
            Color.clear
                .frame(height: 44)
        } else {
            Button {
                player.cyclePlaybackMode()
            } label: {
                Image(systemName: playbackModeIcon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(playbackModeTint)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playbackModeLabel)
        }
    }

    private var playbackModeIcon: String {
        if player.shuffleEnabled { return "shuffle" }
        switch player.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private var playbackModeTint: Color {
        (player.shuffleEnabled || player.repeatMode != .off)
            ? accent
            : .white.opacity(0.88)
    }

    private var playbackModeLabel: LocalizedStringKey {
        if player.shuffleEnabled { return "随机播放" }
        switch player.repeatMode {
        case .off: return "顺序播放"
        case .all: return "列表循环"
        case .one: return "单曲循环"
        }
    }
}


#endif


// MARK: - Scrubber (white-on-dark variant)

struct NowPlayingScrubber: View {
    @EnvironmentObject private var player: PlayerService
    @ObservedObject private var clock = PlayerService.shared.clock

    /// Beans accent fill for the played portion (nil keeps the white fill).
    var accent: Color? = nil
    /// Beans ±15s seek pills flanking the time labels.
    var showsSeekPills: Bool = false

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragProgress: Double = 0

    private var fraction: Double {
        guard player.duration > 0 else { return 0 }
        let value = isDragging ? dragProgress : clock.progress
        return min(max(value / player.duration, 0), 1)
    }

    private var fillColor: Color { accent ?? .white }

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.25))
                        .frame(height: 4)
                    Capsule()
                        .fill(fillColor)
                        .frame(width: max(4, width * fraction), height: 4)
                    Circle()
                        .fill(.white)
                        .frame(width: thumbDiameter, height: thumbDiameter)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(x: width * fraction - thumbDiameter / 2)
                        .opacity(isHovering || isDragging ? 1 : 0)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard player.duration > 0 else { return }
                            // A long scrub must not hide the chrome
                            // mid-drag; every move restarts the idle timer.
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

            HStack(spacing: 6) {
                if showsSeekPills {
                    seekPill("gobackward.15") { seekBy(-15) }
                }
                Text(Formatters.duration(isDragging ? dragProgress : clock.progress))
                Spacer()
                Text(Formatters.duration(player.duration))
                if showsSeekPills {
                    seekPill("goforward.15") { seekBy(15) }
                }
            }
            .font(.system(size: 10.5).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    private var thumbDiameter: CGFloat {
        isDragging ? 13 : (isHovering ? 11 : 9)
    }

    private func seekPill(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 30, height: 22)
                .background(.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(icon == "gobackward.15" ? "后退 15 秒" : "前进 15 秒")
    }

    private func seekBy(_ seconds: TimeInterval) {
        guard player.duration > 0 else { return }
        player.seek(to: min(max(clock.progress + seconds, 0), player.duration))
    }
}

// MARK: - Mini lyrics (compact now-playing)

/// Three synced lyric lines (previous / current / next) filling the gap
/// between the track meta and the transport controls on compact layouts.
/// Tapping opens the full lyrics page.
struct MiniLyricsView: View {
    let onOpen: () -> Void

    @EnvironmentObject private var player: PlayerService
    @EnvironmentObject private var settings: SettingsManager
    @ObservedObject private var lyricsCursor = PlayerService.shared.lyricsCursor

    /// Line motion stills in static mode, with the "no animation" lyric
    /// style, or when transitions are reduced (C4/C5/C15).
    private var lyricAnimationsEnabled: Bool {
        !settings.effectiveStaticMode
            && settings.effectiveLyricAnimationStyle != .none
            && !settings.effectiveReduceMotionTransitions
    }

    /// Returns `animation` unless lyric motion is stilled, in which case nil
    /// (the view jumps straight to its final state).
    private func lyricAnimation(_ animation: Animation) -> Animation? {
        lyricAnimationsEnabled ? animation : nil
    }

    private var lines: (previous: LyricLine?, current: LyricLine?, next: LyricLine?) {
        guard let lyrics = player.lyrics, !lyrics.isEmpty else { return (nil, nil, nil) }
        guard let index = lyricsCursor.activeIndex else {
            return (nil, nil, lyrics.lines.first)
        }
        let all = lyrics.lines
        return (
            index > 0 ? all[index - 1] : nil,
            all[index],
            index + 1 < all.count ? all[index + 1] : nil
        )
    }

    var body: some View {
        let (previous, current, next) = lines
        Group {
            if current != nil || next != nil {
                VStack(spacing: 12) {
                    line(previous, emphasized: false)
                    line(current, emphasized: true)
                    line(next, emphasized: false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)
                .animation(lyricAnimation(.spring(response: 0.4, dampingFraction: 0.85)), value: current?.id)
            } else {
                Color.clear
            }
        }
    }

    @ViewBuilder
    private func line(_ line: LyricLine?, emphasized: Bool) -> some View {
        Text(line?.text.isEmpty == false ? line!.text : " ")
            .font(.system(size: emphasized ? 17 : 14, weight: emphasized ? .bold : .medium))
            .foregroundStyle(.white.opacity(emphasized ? 1 : 0.45))
            .lineLimit(1)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .id(line?.id)
            .transition(
                lyricAnimationsEnabled
                    ? .opacity.combined(with: .move(edge: .bottom))
                    : .identity
            )
    }
}

// MARK: - C8: player control slots

extension PlayerControlSlot {
    /// Slots to render, in the stored order. Unknown ids are dropped,
    /// duplicates collapsed, and an empty selection falls back to the full
    /// default set so playback stays possible.
    @MainActor
    static func effectiveSlots(from settings: SettingsManager) -> [PlayerControlSlot] {
        var seen = Set<String>()
        let slots = settings.effectivePlayerControlSlots.compactMap { raw -> PlayerControlSlot? in
            guard !seen.contains(raw), let slot = PlayerControlSlot(rawValue: raw) else { return nil }
            seen.insert(raw)
            return slot
        }
        return slots.isEmpty ? allCases : slots
    }

    /// Whether this slot is rendered, under the same empty-fallback rule.
    @MainActor
    static func isSelected(_ slot: PlayerControlSlot, in settings: SettingsManager) -> Bool {
        effectiveSlots(from: settings).contains(slot)
    }
}
