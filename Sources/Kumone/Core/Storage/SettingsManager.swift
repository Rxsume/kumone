import SwiftUI

enum AudioQuality: String, CaseIterable, Identifiable {
    case standard
    case higher
    case exhigh
    case lossless
    case hires

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return String(localized: "标准")
        case .higher: return String(localized: "较高")
        case .exhigh: return String(localized: "极高")
        case .lossless: return String(localized: "无损")
        case .hires: return "Hi-Res"
        }
    }

    var badge: String {
        switch self {
        case .standard: return String(localized: "标准")
        case .higher: return String(localized: "较高")
        case .exhigh: return String(localized: "极高")
        case .lossless: return String(localized: "无损")
        case .hires: return String(localized: "高解析")
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case auto, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return String(localized: "跟随系统")
        case .light: return String(localized: "浅色")
        case .dark: return String(localized: "深色")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// What to show above Japanese lyrics.
enum LyricsAnnotation: String, CaseIterable, Identifiable {
    case off
    case romaji
    case furigana

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return String(localized: "关闭")
        case .romaji: return String(localized: "罗马音")
        case .furigana: return String(localized: "汉字读音")
        }
    }
}

public enum NowPlayingMode: String, CaseIterable, Identifiable {
    case vinyl
    case classic
    case immersive
    case minimal
    /// Folia Lattice (P2): cover-wall grid on top, big-lyrics card below.
    /// iOS only in practice — macOS offers only vinyl/classic in its
    /// picker, and the macOS compact dispatch falls through to classic.
    case lattice

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .vinyl: return String(localized: "黑胶模式")
        case .classic: return String(localized: "经典模式")
        case .immersive: return String(localized: "沉浸模式")
        case .minimal: return String(localized: "简洁模式")
        case .lattice: return String(localized: "格子模式")
        }
    }
}

/// Layout used by the full-width now-playing page — iPhone landscape and
/// iPad — where `NowPlayingMode`'s compact layouts no longer apply. Kept
/// separate so a phone in portrait can stay on 黑胶 while landscape opens on
/// a lyrics-first page.
public enum LandscapeNowPlayingStyle: String, CaseIterable, Identifiable {
    /// Artwork and transport on the left, lyrics on the right (the original
    /// full-width page).
    case classic
    /// Lyrics fill the page, with a small header and a floating transport
    /// capsule at the bottom.
    case immersive

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .classic: return String(localized: "经典双栏")
        case .immersive: return String(localized: "沉浸歌词")
        }
    }
}

/// How lyric lines animate as they become current. `fade` cross-fades lines;
/// `karaokeZoom` scales the active word (needs verbatim lyrics); `lineHighlight`
/// emphasises the whole current line; `none` switches lines without animation.
enum LyricAnimationStyle: String, CaseIterable, Identifiable {
    case none
    case fade
    case karaokeZoom
    case lineHighlight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return String(localized: "无动画")
        case .fade: return String(localized: "淡入")
        case .karaokeZoom: return String(localized: "逐字放大")
        case .lineHighlight: return String(localized: "逐行高亮")
        }
    }
}

/// Where a track goes when added from a list: the end of the queue, or right
/// after the current track (the historical behaviour).
enum QueueAddBehavior: String, CaseIterable, Identifiable {
    case append
    case next

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .append: return String(localized: "追加到队尾")
        case .next: return String(localized: "插到下一首")
        }
    }
}

/// Which view opens when playback starts from a list.
enum PlaybackEntryView: String, CaseIterable, Identifiable {
    case nowPlaying
    case stay

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nowPlaying: return String(localized: "打开播放页")
        case .stay: return String(localized: "保持当前页")
        }
    }
}

/// One transport button in the player bar / now-playing controls. The order of
/// `allCases` is the default bar layout.
enum PlayerControlSlot: String, CaseIterable, Identifiable {
    case shuffle
    case previous
    case playPause
    case next
    case repeatMode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shuffle: return String(localized: "随机")
        case .previous: return String(localized: "上一首")
        case .playPause: return String(localized: "播放/暂停")
        case .next: return String(localized: "下一首")
        case .repeatMode: return String(localized: "循环")
        }
    }
}

/// How one track hands over to the next. `crossfade` forces a plain
/// crossfade; `automix` lets the planner pick the best plan.
///
/// Dual-platform: macOS AutoMix uses it, and the iOS dual-deck crossfade
/// engine (Folia P2/P3) reads the same setting.
enum TransitionMode: String, CaseIterable, Identifiable {
    case crossfade
    case automix

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .crossfade: return String(localized: "淡入淡出")
        case .automix: return String(localized: "Automix 智能混音")
        }
    }
}

/// How ReplayGain loudness levelling applies. `auto` is the existing
/// analysis-based compensation; `track`/`album` group by the track's own
/// ReplayGain tags when present (falling back to the analysed value).
///
/// Dual-platform: macOS reads it in `PlayerService`, iOS in
/// `PlayerServiceIOS` (per-track `AVPlayer.volume` gain). iOS defaults to
/// `.off` — compensation only applies once the user turns it on.
enum ReplayGainMode: String, CaseIterable, Identifiable {
    case off
    case auto
    case track
    case album

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return String(localized: "关闭")
        case .auto: return String(localized: "自动")
        case .track: return String(localized: "按单曲")
        case .album: return String(localized: "按专辑")
        }
    }
}

@MainActor
final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    /// Internal rather than private: `AudioCache` reads its own limit straight
    /// from `UserDefaults` before any settings object exists, and must spell
    /// the key the same way.
    enum Keys {
        static let quality = "settings.audioQuality"
        static let appearance = "settings.appearance"
        static let nowPlayingMode = "settings.nowPlayingMode"
        static let landscapeNowPlayingStyle = "settings.landscapeNowPlayingStyle"
        static let openAlbumOnArtworkClick = "settings.openAlbumOnArtworkClick"
        static let showTranslation = "settings.showLyricsTranslation"
        static let showRomaji = "settings.showLyricsRomaji"  // migrated to `annotation`
        static let annotation = "settings.lyricsAnnotation"
        static let verbatimLyrics = "settings.verbatimLyrics"
        static let volume = "settings.volume"
        static let fmMode = "settings.fmMode"
        static let unblock = "settings.enableUnblock"
        static let unblockSources = "settings.enabledUnblockSources"
        static let autoCheckUpdates = "settings.autoCheckUpdates"
        static let desktopLyrics = "settings.showDesktopLyrics"
        #if os(macOS)
        static let menuBarPlayer = "settings.showMenuBarPlayer"
        static let automix = "settings.automixEnabled"
        static let automixTransitions = "settings.automixTransitions"
        static let automixOrder = "settings.automixOrder"
        static let automixStems = "settings.automixStems"
        static let loudnessCompensation = "settings.loudnessCompensation"
        static let audioCacheLimit = "settings.audioCacheLimit"
        static let outputDevice = "settings.outputDeviceUID"
        #endif
        static let desktopLyricsCentered = "settings.desktopLyricsCentered"
        static let mainWindowAmbientBackground = "settings.showMainWindowAmbientBackground"
        static let mainWindowAmbientBackgroundIntensity = "settings.mainWindowAmbientBackgroundIntensity"
        static let enableAudioCache = "settings.enableAudioCache"
        static let audioCacheSizeMB = "settings.audioCacheSizeMB"
        static let audioCacheAutomatic = "settings.audioCacheAutomatic"
        static let lyricAnimationStyle = "settings.lyricAnimationStyle"
        static let themePreset = "settings.themePreset"
        static let customTheme = "settings.customTheme"
        static let preferCustomTheme = "settings.preferCustomTheme"
        static let songThemeAutoSwitch = "settings.songThemeAutoSwitch"
        static let homeDynamicBackground = "settings.homeDynamicBackground"
        static let playerPageNativeBlur = "settings.playerPageNativeBlur"
        static let staticMode = "settings.staticMode"
        static let reduceMotionBackground = "settings.reduceMotionBackground"
        static let reduceMotionTransitions = "settings.reduceMotionTransitions"
        static let reduceMotionMicroMotion = "settings.reduceMotionMicroMotion"
        static let playbackFadeEnabled = "settings.playbackFadeEnabled"
        static let queueAddBehavior = "settings.queueAddBehavior"
        static let autoSkipUnplayable = "settings.autoSkipUnplayable"
        static let playbackEntryView = "settings.playbackEntryView"
        static let playerPageTintIntensity = "settings.playerPageTintIntensity"
        static let hidePlayerProgressBar = "settings.hidePlayerProgressBar"
        static let alwaysShowPlayerBackButton = "settings.alwaysShowPlayerBackButton"
        static let alwaysShowTrackSwitchButtons = "settings.alwaysShowTrackSwitchButtons"
        static let playerControlSlots = "settings.playerControlSlots"
        static let stageTrackCardEnabled = "settings.stageTrackCardEnabled"
        static let transitionAnimationRing = "settings.transitionAnimationRing"
        static let transitionAnimationCard = "settings.transitionAnimationCard"
        #if os(iOS)
        static let preventDisplaySleep = "settings.preventDisplaySleepDuringPlayback"
        static let iosCrossfadeEnabled = "settings.iosCrossfadeEnabled"
        #endif
        static let transitionMode = "settings.transitionMode"
        static let crossfadeMaxSeconds = "settings.crossfadeMaxSeconds"
        static let replayGainMode = "settings.replayGainMode"
        static let foliaEnabled = "settings.foliaEnabled"
    }

    @Published var audioQuality: AudioQuality {
        didSet { UserDefaults.standard.set(audioQuality.rawValue, forKey: Keys.quality) }
    }

    static let audioCacheSizeRangeMB = 100...10_000
    static let audioCacheSizeStepMB = 100

    /// Use locally stored audio files before resolving a remote source and
    /// retain completed remote playback for future requests.
    @Published var enableAudioCache: Bool {
        didSet { UserDefaults.standard.set(enableAudioCache, forKey: Keys.enableAudioCache) }
    }

    /// Size the song cache from the device's free space instead of
    /// `audioCacheSizeMB`; see `AutomaticCacheLimit`.
    @Published var audioCacheAutomatic: Bool {
        didSet { UserDefaults.standard.set(audioCacheAutomatic, forKey: Keys.audioCacheAutomatic) }
    }

    static func normalizedAudioCacheSizeMB(_ value: Int) -> Int {
        let boundedValue = min(
            max(value, audioCacheSizeRangeMB.lowerBound),
            audioCacheSizeRangeMB.upperBound
        )
        let distanceFromLowerBound = boundedValue - audioCacheSizeRangeMB.lowerBound
        return audioCacheSizeRangeMB.lowerBound
            + Int((Double(distanceFromLowerBound) / Double(audioCacheSizeStepMB)).rounded())
                * audioCacheSizeStepMB
    }

    @Published var audioCacheSizeMB: Int {
        didSet {
            let normalizedValue = Self.normalizedAudioCacheSizeMB(audioCacheSizeMB)
            guard normalizedValue == audioCacheSizeMB else {
                audioCacheSizeMB = normalizedValue
                return
            }
            UserDefaults.standard.set(audioCacheSizeMB, forKey: Keys.audioCacheSizeMB)
        }
    }

    @Published var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    @Published var nowPlayingMode: NowPlayingMode {
        didSet { UserDefaults.standard.set(nowPlayingMode.rawValue, forKey: Keys.nowPlayingMode) }
    }

    @Published var landscapeNowPlayingStyle: LandscapeNowPlayingStyle {
        didSet {
            UserDefaults.standard.set(
                landscapeNowPlayingStyle.rawValue, forKey: Keys.landscapeNowPlayingStyle
            )
        }
    }

    @Published var openAlbumOnArtworkClick: Bool {
        didSet { UserDefaults.standard.set(openAlbumOnArtworkClick, forKey: Keys.openAlbumOnArtworkClick) }
    }

    @Published var showLyricsTranslation: Bool {
        didSet { UserDefaults.standard.set(showLyricsTranslation, forKey: Keys.showTranslation) }
    }

    /// Check for updates on launch. When off, no update sheet appears
    /// automatically; the user can still check manually (#42).
    @Published var autoCheckUpdates: Bool {
        didSet {
            UserDefaults.standard.set(autoCheckUpdates, forKey: Keys.autoCheckUpdates)
            #if os(macOS)
            UpdaterManager.shared.setAutomaticChecks(autoCheckUpdates)
            #endif
        }
    }

    /// Reading shown for Japanese lyrics: a romaji line above, furigana over
    /// the kanji, or nothing.
    @Published var lyricsAnnotation: LyricsAnnotation {
        didSet { UserDefaults.standard.set(lyricsAnnotation.rawValue, forKey: Keys.annotation) }
    }

    /// Karaoke-style word-by-word highlighting: the service's own timing when the
    /// song has verbatim (yrc) lyrics, else the line's time spread across its
    /// characters.
    @Published var verbatimLyrics: Bool {
        didSet { UserDefaults.standard.set(verbatimLyrics, forKey: Keys.verbatimLyrics) }
    }

    /// Resolve gray tracks from third-party sources (unblock-style).
    @Published var enableUnblock: Bool {
        didSet { UserDefaults.standard.set(enableUnblock, forKey: Keys.unblock) }
    }

    /// Built-in third-party sources eligible for gray-track resolution.
    @Published var enabledAudioSourceIDs: Set<AudioSourceID> {
        didSet {
            UserDefaults.standard.set(
                enabledAudioSourceIDs.map(\.rawValue).sorted(),
                forKey: Keys.unblockSources
            )
        }
    }

    var canResolveUnblockedTracks: Bool {
        enableUnblock && !enabledAudioSourceIDs.isEmpty
    }

    /// Floating desktop lyrics window (LyricsX-style).
    @Published var showDesktopLyrics: Bool {
        didSet { UserDefaults.standard.set(showDesktopLyrics, forKey: Keys.desktopLyrics) }
    }
    #if os(macOS)

    /// The AutoMix master switch. Off means no per-track analysis at all, and
    /// every sub-setting below is inert. Opt-in: AutoMix costs CPU (analysis),
    /// sometimes network (the order's candidates) and sometimes GPU (stems),
    /// so it does not turn itself on. macOS-only for now (spec §7).
    @Published var automixEnabled: Bool {
        didSet { UserDefaults.standard.set(automixEnabled, forKey: Keys.automix) }
    }

    /// Beat-matched / crossfaded hand-overs between queue tracks. Off still
    /// gives gapless playback, and off is *only* a statement about the seam:
    /// analysis still runs when another sub-setting below wants it.
    @Published var automixTransitionsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(automixTransitionsEnabled,
                                      forKey: Keys.automixTransitions)
        }
    }

    /// The `.autoMix` queue order — reorder the queue by how well the seams
    /// come out. It scores candidates, which means downloading tracks the
    /// listener has not asked for yet, so it is off by default even under an
    /// AutoMix that is on.
    @Published var automixOrderEnabled: Bool {
        didSet { UserDefaults.standard.set(automixOrderEnabled, forKey: Keys.automixOrder) }
    }

    /// Let a hand-over separate stems on the GPU. Real money in heat and
    /// battery, and it needs a model on disk, so it is opt-in on top of
    /// opt-in; without it every gesture plays its whole-mix form.
    @Published var automixStemsEnabled: Bool {
        didSet { UserDefaults.standard.set(automixStemsEnabled, forKey: Keys.automixStems) }
    }

    /// Even out mastering loudness differences between songs, so the next
    /// track does not arrive several dB louder. Needs AutoMix's per-track
    /// analysis, so it is inert while AutoMix is off.
    @Published var loudnessCompensationEnabled: Bool {
        didSet {
            UserDefaults.standard.set(loudnessCompensationEnabled,
                                      forKey: Keys.loudnessCompensation)
        }
    }

    /// Audio cache LRU limit in bytes; 0 = unlimited. AudioCache reads the
    /// same defaults key at startup and receives changes from here.
    @Published var audioCacheLimit: Int64 {
        didSet {
            UserDefaults.standard.set(audioCacheLimit, forKey: Keys.audioCacheLimit)
            Task { await EngineAudioCache.shared.setLimitBytes(audioCacheLimit) }
        }
    }

    /// CoreAudio UID of the chosen output device; "" follows the system
    /// default. UID rather than the numeric AudioDeviceID, which is not
    /// stable across launches. Written by `AudioOutputController`.
    @Published var outputDeviceUID: String {
        didSet { UserDefaults.standard.set(outputDeviceUID, forKey: Keys.outputDevice) }
    }
    #endif

    /// Lock the desktop-lyrics capsule to the horizontal centre of the screen
    /// instead of the free-drag position (#48).
    @Published var desktopLyricsCentered: Bool {
        didSet { UserDefaults.standard.set(desktopLyricsCentered, forKey: Keys.desktopLyricsCentered) }
    }

    nonisolated static let mainWindowAmbientBackgroundIntensityRange = 0.5...1.5

    #if os(macOS)
    /// Default song-cache ceiling, shared with `AudioCache` so the two cannot
    /// disagree about what "unset" means.
    nonisolated static let defaultAudioCacheLimit: Int64 = 2_147_483_648  // 2 GB
    #endif

    /// Artwork-tinted overlay on the main app interface.
    @Published var showMainWindowAmbientBackground: Bool {
        didSet {
            UserDefaults.standard.set(
                showMainWindowAmbientBackground,
                forKey: Keys.mainWindowAmbientBackground
            )
        }
    }

    /// Multiplier applied to the main interface's artwork tint.
    @Published var mainWindowAmbientBackgroundIntensity: Double {
        didSet {
            UserDefaults.standard.set(
                mainWindowAmbientBackgroundIntensity,
                forKey: Keys.mainWindowAmbientBackgroundIntensity
            )
        }
    }

    // MARK: - Folia visual / playback settings

    /// Master switch for all Folia visual / playback settings in this
    /// section. Off restores the pre-folia behaviour (what the app did
    /// at bb21dd8, before PR #8): every `effective*` property below
    /// returns its pre-folia value. The stored values are kept, so
    /// turning it back on restores the user's choices.
    @Published var foliaEnabled: Bool {
        didSet { UserDefaults.standard.set(foliaEnabled, forKey: Keys.foliaEnabled) }
    }

    /// Lyric line animation style on the now-playing page.
    @Published var lyricAnimationStyle: LyricAnimationStyle {
        didSet { UserDefaults.standard.set(lyricAnimationStyle.rawValue, forKey: Keys.lyricAnimationStyle) }
    }

    /// Lyric animation with the master switch off: the pre-folia
    /// word wipe (verbatim word-by-word alphas) is the `.fade` style.
    var effectiveLyricAnimationStyle: LyricAnimationStyle {
        foliaEnabled ? lyricAnimationStyle : .fade
    }

    /// Built-in colour theme preset id; "default" follows the system light/dark
    /// artwork tint, "custom" uses `customThemeJSON`.
    @Published var themePresetID: String {
        didSet { UserDefaults.standard.set(themePresetID, forKey: Keys.themePreset) }
    }

    /// Theme preset with the master switch off: `"default"`, whose
    /// colours are the pre-folia ones (`Theme.accent` over the
    /// fallback artwork tint). No custom theme existed before PR #8.
    var effectiveThemePresetID: String {
        foliaEnabled ? themePresetID : "default"
    }

    /// JSON-encoded custom theme (see `ThemePreset`), empty when none is saved.
    @Published var customThemeJSON: String {
        didSet { UserDefaults.standard.set(customThemeJSON, forKey: Keys.customTheme) }
    }

    /// Custom theme JSON with the master switch off: none was saved
    /// before PR #8, so there is no custom theme.
    var effectiveCustomThemeJSON: String {
        foliaEnabled ? customThemeJSON : ""
    }

    /// Prefer the custom theme over the current song's artwork theme.
    @Published var preferCustomTheme: Bool {
        didSet { UserDefaults.standard.set(preferCustomTheme, forKey: Keys.preferCustomTheme) }
    }

    /// Prefer-custom-theme with the master switch off: no custom
    /// theme existed before PR #8, so there is nothing to prefer.
    var effectivePreferCustomTheme: Bool {
        foliaEnabled ? preferCustomTheme : false
    }

    /// Let the now-playing page and main interface follow the current song's
    /// artwork palette. Off keeps the default theme colours.
    @Published var songThemeAutoSwitch: Bool {
        didSet { UserDefaults.standard.set(songThemeAutoSwitch, forKey: Keys.songThemeAutoSwitch) }
    }

    /// Song-theme auto-switch with the master switch off: pre-folia
    /// the now-playing page always followed the artwork palette, so
    /// it stays on.
    var effectiveSongThemeAutoSwitch: Bool {
        foliaEnabled ? songThemeAutoSwitch : true
    }

    /// Home page artwork-tinted dynamic background, separate from the main
    /// interface ambient background switch.
    @Published var homeDynamicBackground: Bool {
        didSet { UserDefaults.standard.set(homeDynamicBackground, forKey: Keys.homeDynamicBackground) }
    }

    /// Home dynamic background with the master switch off: pre-folia
    /// the ambient gradient was unconditional, so it stays on.
    var effectiveHomeDynamicBackground: Bool {
        foliaEnabled ? homeDynamicBackground : true
    }

    /// Native blur (ultraThinMaterial) behind the now-playing page.
    @Published var playerPageNativeBlur: Bool {
        didSet { UserDefaults.standard.set(playerPageNativeBlur, forKey: Keys.playerPageNativeBlur) }
    }

    /// Native blur with the master switch off: pre-folia the blurred
    /// artwork layer and the ultraThinMaterial popover were
    /// unconditional, so it stays on.
    var effectivePlayerPageNativeBlur: Bool {
        foliaEnabled ? playerPageNativeBlur : true
    }

    /// Static mode: a master switch that stills ambient transitions, vinyl
    /// rotation and lyric animations (on top of the system Reduce Motion).
    @Published var staticMode: Bool {
        didSet { UserDefaults.standard.set(staticMode, forKey: Keys.staticMode) }
    }

    /// Static mode with the master switch off: it did not exist
    /// before PR #8.
    var effectiveStaticMode: Bool {
        foliaEnabled ? staticMode : false
    }

    /// Reduce-motion overrides, per area. `nil` means "follow the system"
    /// (`Platform.isReduceMotionEnabled`).
    @Published var reduceMotionBackground: Bool? {
        didSet { Self.setOptionalBool(reduceMotionBackground, forKey: Keys.reduceMotionBackground) }
    }

    @Published var reduceMotionTransitions: Bool? {
        didSet { Self.setOptionalBool(reduceMotionTransitions, forKey: Keys.reduceMotionTransitions) }
    }

    @Published var reduceMotionMicroMotion: Bool? {
        didSet { Self.setOptionalBool(reduceMotionMicroMotion, forKey: Keys.reduceMotionMicroMotion) }
    }

    /// Effective Reduce Motion per area: the manual override, else the system.
    /// With the Folia master switch off the overrides are inert — pre-folia
    /// there were no per-area overrides — so the system value applies.
    var effectiveReduceMotionBackground: Bool {
        (foliaEnabled ? reduceMotionBackground : nil) ?? Platform.isReduceMotionEnabled
    }

    var effectiveReduceMotionTransitions: Bool {
        (foliaEnabled ? reduceMotionTransitions : nil) ?? Platform.isReduceMotionEnabled
    }

    var effectiveReduceMotionMicroMotion: Bool {
        (foliaEnabled ? reduceMotionMicroMotion : nil) ?? Platform.isReduceMotionEnabled
    }

    private static func setOptionalBool(_ value: Bool?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Short volume ramp on pause/resume instead of an abrupt cut.
    @Published var playbackFadeEnabled: Bool {
        didSet { UserDefaults.standard.set(playbackFadeEnabled, forKey: Keys.playbackFadeEnabled) }
    }

    /// Pause/resume fade with the master switch off: pre-folia the
    /// volume cut in and out at once, with no ramp.
    var effectivePlaybackFadeEnabled: Bool {
        foliaEnabled ? playbackFadeEnabled : false
    }

    /// Default behaviour when adding a track from a list.
    @Published var queueAddBehavior: QueueAddBehavior {
        didSet { UserDefaults.standard.set(queueAddBehavior.rawValue, forKey: Keys.queueAddBehavior) }
    }

    /// Queue-add behaviour with the master switch off: `.next`, the
    /// historical behaviour (insert after the current track).
    var effectiveQueueAddBehavior: QueueAddBehavior {
        foliaEnabled ? queueAddBehavior : .next
    }

    /// Skip unplayable tracks automatically (VIP-only, region-locked, removed).
    /// Network failures never skip.
    @Published var autoSkipUnplayable: Bool {
        didSet { UserDefaults.standard.set(autoSkipUnplayable, forKey: Keys.autoSkipUnplayable) }
    }

    /// Auto-skip with the master switch off: pre-folia an unplayable
    /// track just failed instead of skipping to the next one.
    var effectiveAutoSkipUnplayable: Bool {
        foliaEnabled ? autoSkipUnplayable : false
    }

    /// Which view opens when playback starts from a list.
    @Published var playbackEntryView: PlaybackEntryView {
        didSet { UserDefaults.standard.set(playbackEntryView.rawValue, forKey: Keys.playbackEntryView) }
    }

    /// Playback entry view with the master switch off: `.stay` —
    /// auto-opening the now-playing page (B8) is new; pre-folia
    /// playback stayed on the list it started from.
    var effectivePlaybackEntryView: PlaybackEntryView {
        foliaEnabled ? playbackEntryView : .stay
    }

    static let playerPageTintIntensityRange = 0.5...1.5

    /// Multiplier applied to the now-playing page's artwork tint.
    @Published var playerPageTintIntensity: Double {
        didSet {
            UserDefaults.standard.set(playerPageTintIntensity, forKey: Keys.playerPageTintIntensity)
        }
    }

    /// Player-page tint intensity with the master switch off: 1.0
    /// returns the extracted colours unchanged; pre-folia there was
    /// no intensity scaling.
    var effectivePlayerPageTintIntensity: Double {
        foliaEnabled ? playerPageTintIntensity : 1
    }

    /// Hide the progress bar / scrubber on the now-playing page.
    @Published var hidePlayerProgressBar: Bool {
        didSet { UserDefaults.standard.set(hidePlayerProgressBar, forKey: Keys.hidePlayerProgressBar) }
    }

    /// Hide-progress-bar with the master switch off: the scrubber
    /// was unconditional before PR #8, so it stays shown.
    var effectiveHidePlayerProgressBar: Bool {
        foliaEnabled ? hidePlayerProgressBar : false
    }

    /// Always show the back button on the now-playing page.
    @Published var alwaysShowPlayerBackButton: Bool {
        didSet {
            UserDefaults.standard.set(alwaysShowPlayerBackButton, forKey: Keys.alwaysShowPlayerBackButton)
        }
    }

    /// Always-show-back-button with the master switch off: pre-folia
    /// the button only appeared where the compact layouts show
    /// their classic chrome.
    var effectiveAlwaysShowPlayerBackButton: Bool {
        foliaEnabled ? alwaysShowPlayerBackButton : false
    }

    /// Always show the previous/next buttons on the now-playing page.
    @Published var alwaysShowTrackSwitchButtons: Bool {
        didSet {
            UserDefaults.standard.set(alwaysShowTrackSwitchButtons, forKey: Keys.alwaysShowTrackSwitchButtons)
        }
    }

    /// Always-show-track-switch-buttons with the master switch off:
    /// pre-folia FM mode swapped the previous slot for dislike, so
    /// the buttons only show outside FM.
    var effectiveAlwaysShowTrackSwitchButtons: Bool {
        foliaEnabled ? alwaysShowTrackSwitchButtons : false
    }

    /// Transport buttons shown in the player bar, as slot ids in order.
    @Published var playerControlSlots: [String] {
        didSet { UserDefaults.standard.set(playerControlSlots, forKey: Keys.playerControlSlots) }
    }

    /// Transport slots with the master switch off: the full fixed
    /// set (shuffle, previous, play/pause, next, repeat), which is
    /// what the pre-folia transport bar showed.
    var effectivePlayerControlSlots: [String] {
        foliaEnabled ? playerControlSlots : PlayerControlSlot.allCases.map(\.rawValue)
    }

    /// Floating song card on the now-playing page (tap to return to the page).
    @Published var stageTrackCardEnabled: Bool {
        didSet { UserDefaults.standard.set(stageTrackCardEnabled, forKey: Keys.stageTrackCardEnabled) }
    }

    /// Floating song card with the master switch off: it did not
    /// exist before PR #8.
    var effectiveStageTrackCardEnabled: Bool {
        foliaEnabled ? stageTrackCardEnabled : false
    }

    /// Transition animations while a handover plays: a ring on screen…
    @Published var transitionAnimationRing: Bool {
        didSet { UserDefaults.standard.set(transitionAnimationRing, forKey: Keys.transitionAnimationRing) }
    }

    /// Transition-animation ring with the master switch off: it did
    /// not exist before PR #8.
    var effectiveTransitionAnimationRing: Bool {
        foliaEnabled ? transitionAnimationRing : false
    }

    /// …and an outline around the song card.
    @Published var transitionAnimationCard: Bool {
        didSet { UserDefaults.standard.set(transitionAnimationCard, forKey: Keys.transitionAnimationCard) }
    }

    /// Transition-animation card outline with the master switch off:
    /// it did not exist before PR #8.
    var effectiveTransitionAnimationCard: Bool {
        foliaEnabled ? transitionAnimationCard : false
    }

    #if os(iOS)
    /// Keep the screen awake while playing.
    @Published var preventDisplaySleepDuringPlayback: Bool {
        didSet {
            UserDefaults.standard.set(preventDisplaySleepDuringPlayback, forKey: Keys.preventDisplaySleep)
        }
    }

    /// Prevent-display-sleep with the master switch off: pre-folia
    /// nothing held the idle timer while playing.
    var effectivePreventDisplaySleepDuringPlayback: Bool {
        foliaEnabled ? preventDisplaySleepDuringPlayback : false
    }

    /// iOS crossfade (Folia P2/P3): cut between songs with a dual-deck
    /// overlap instead of a hard cut. Default off — the single-`AVPlayer`
    /// path is used until the user turns it on.
    @Published var iosCrossfadeEnabled: Bool {
        didSet { UserDefaults.standard.set(iosCrossfadeEnabled, forKey: Keys.iosCrossfadeEnabled) }
    }

    /// iOS crossfade with the master switch off: pre-folia iOS
    /// played through a single `AVPlayer` with hard cuts.
    var effectiveIosCrossfadeEnabled: Bool {
        foliaEnabled ? iosCrossfadeEnabled : false
    }
    #endif

    static let crossfadeMaxSecondsRange = 2.0...12.0

    /// Handover mode: plain crossfade, or the planner's full Automix.
    @Published var transitionMode: TransitionMode {
        didSet { UserDefaults.standard.set(transitionMode.rawValue, forKey: Keys.transitionMode) }
    }

    /// Handover mode with the master switch off: `.automix` —
    /// pre-folia `plannerConfig` was `Config.standard`, and
    /// `.automix` leaves the config exactly as base.
    var effectiveTransitionMode: TransitionMode {
        foliaEnabled ? transitionMode : .automix
    }

    /// Longest crossfade the planner may use, in seconds.
    @Published var crossfadeMaxSeconds: Double {
        didSet {
            UserDefaults.standard.set(crossfadeMaxSeconds, forKey: Keys.crossfadeMaxSeconds)
        }
    }

    /// Longest crossfade with the master switch off: pre-folia there
    /// was no such setting and the fallback fade was capped at 6 s.
    /// Inert in practice — `.automix` mode ignores the cap, and the
    /// iOS engine is off with the master switch off.
    var effectiveCrossfadeMaxSeconds: Double {
        foliaEnabled ? crossfadeMaxSeconds : 6
    }

    /// ReplayGain loudness levelling mode.
    @Published var replayGainMode: ReplayGainMode {
        didSet { UserDefaults.standard.set(replayGainMode.rawValue, forKey: Keys.replayGainMode) }
    }

    /// ReplayGain mode with the master switch off: iOS had no
    /// ReplayGain before PR #8 (`.off`); macOS keeps its shipped
    /// analysis-based compensation (`.auto`).
    var effectiveReplayGainMode: ReplayGainMode {
        guard foliaEnabled else {
            #if os(iOS)
            return .off
            #else
            return .auto
            #endif
        }
        return replayGainMode
    }

    /// Now-playing mode with the Folia master switch off: `.lattice` is a
    /// Folia (P2) mode, so it falls back to the pre-folia default
    /// (`.immersive`); vinyl/classic/immersive/minimal predate Folia and
    /// pass through unchanged.
    var effectiveNowPlayingMode: NowPlayingMode {
        guard foliaEnabled || nowPlayingMode != .lattice else { return .immersive }
        return nowPlayingMode
    }

    private init() {
        let defaults = UserDefaults.standard
        audioQuality = defaults.string(forKey: Keys.quality).flatMap(AudioQuality.init) ?? .exhigh
        enableAudioCache = defaults.object(forKey: Keys.enableAudioCache) as? Bool ?? true
        // A size somebody chose stays chosen; the untouched default becomes automatic.
        audioCacheAutomatic = defaults.object(forKey: Keys.audioCacheAutomatic) as? Bool
            ?? (defaults.object(forKey: Keys.audioCacheSizeMB) as? Int).map { $0 == AudioCache.defaultMaximumSizeMB } ?? true
        let storedAudioCacheSizeMB = defaults.object(forKey: Keys.audioCacheSizeMB) as? Int
            ?? AudioCache.defaultMaximumSizeMB
        let normalizedAudioCacheSizeMB = Self.normalizedAudioCacheSizeMB(storedAudioCacheSizeMB)
        audioCacheSizeMB = normalizedAudioCacheSizeMB
        defaults.set(normalizedAudioCacheSizeMB, forKey: Keys.audioCacheSizeMB)
        appearance = defaults.string(forKey: Keys.appearance).flatMap(AppAppearance.init) ?? .auto
        nowPlayingMode = defaults.string(forKey: Keys.nowPlayingMode).flatMap(NowPlayingMode.init) ?? .immersive
        landscapeNowPlayingStyle = defaults.string(forKey: Keys.landscapeNowPlayingStyle)
            .flatMap(LandscapeNowPlayingStyle.init) ?? .classic
        openAlbumOnArtworkClick = defaults.object(forKey: Keys.openAlbumOnArtworkClick) as? Bool ?? true
        showLyricsTranslation = defaults.object(forKey: Keys.showTranslation) as? Bool ?? true
        // Carry over the old on/off romaji toggle for anyone who had it on.
        lyricsAnnotation = defaults.string(forKey: Keys.annotation).flatMap(LyricsAnnotation.init)
            ?? (defaults.bool(forKey: Keys.showRomaji) ? .romaji : .off)
        verbatimLyrics = defaults.object(forKey: Keys.verbatimLyrics) as? Bool ?? true
        enableUnblock = defaults.object(forKey: Keys.unblock) as? Bool ?? true
        if let rawSourceIDs = defaults.stringArray(forKey: Keys.unblockSources) {
            enabledAudioSourceIDs = Set(rawSourceIDs.compactMap(AudioSourceID.init))
        } else {
            // Script-backend sources are opt-in, except ikun, the
            // preferred source, which is on by default: a user who never
            // touched the source switches keeps pyncmd + ikun.
            enabledAudioSourceIDs = Set(
                AudioSourceID.allCases.filter { !$0.isScriptBackend }
            )
        }
        autoCheckUpdates = defaults.object(forKey: Keys.autoCheckUpdates) as? Bool ?? true
        showDesktopLyrics = defaults.object(forKey: Keys.desktopLyrics) as? Bool ?? false
        #if os(macOS)
        automixEnabled = defaults.object(forKey: Keys.automix) as? Bool ?? false
        automixTransitionsEnabled =
            defaults.object(forKey: Keys.automixTransitions) as? Bool ?? true
        automixOrderEnabled = defaults.object(forKey: Keys.automixOrder) as? Bool ?? false
        automixStemsEnabled = defaults.object(forKey: Keys.automixStems) as? Bool ?? false
        loudnessCompensationEnabled =
            defaults.object(forKey: Keys.loudnessCompensation) as? Bool ?? true
        audioCacheLimit = (defaults.object(forKey: Keys.audioCacheLimit) as? Int64)
            ?? Self.defaultAudioCacheLimit
        outputDeviceUID = defaults.string(forKey: Keys.outputDevice) ?? ""
        #endif
        desktopLyricsCentered = defaults.object(forKey: Keys.desktopLyricsCentered) as? Bool ?? false
        showMainWindowAmbientBackground = defaults.object(
            forKey: Keys.mainWindowAmbientBackground
        ) as? Bool ?? true
        let storedAmbientBackgroundIntensity = defaults.object(
            forKey: Keys.mainWindowAmbientBackgroundIntensity
        ) as? Double ?? 1
        mainWindowAmbientBackgroundIntensity = min(
            max(storedAmbientBackgroundIntensity, Self.mainWindowAmbientBackgroundIntensityRange.lowerBound),
            Self.mainWindowAmbientBackgroundIntensityRange.upperBound
        )
        foliaEnabled = defaults.object(forKey: Keys.foliaEnabled) as? Bool ?? true
        lyricAnimationStyle = defaults.string(forKey: Keys.lyricAnimationStyle)
            .flatMap(LyricAnimationStyle.init) ?? .fade
        themePresetID = defaults.string(forKey: Keys.themePreset) ?? "default"
        customThemeJSON = defaults.string(forKey: Keys.customTheme) ?? ""
        preferCustomTheme = defaults.object(forKey: Keys.preferCustomTheme) as? Bool ?? false
        songThemeAutoSwitch = defaults.object(forKey: Keys.songThemeAutoSwitch) as? Bool ?? true
        homeDynamicBackground = defaults.object(forKey: Keys.homeDynamicBackground) as? Bool ?? true
        playerPageNativeBlur = defaults.object(forKey: Keys.playerPageNativeBlur) as? Bool ?? true
        staticMode = defaults.object(forKey: Keys.staticMode) as? Bool ?? false
        reduceMotionBackground = defaults.object(forKey: Keys.reduceMotionBackground) as? Bool
        reduceMotionTransitions = defaults.object(forKey: Keys.reduceMotionTransitions) as? Bool
        reduceMotionMicroMotion = defaults.object(forKey: Keys.reduceMotionMicroMotion) as? Bool
        playbackFadeEnabled = defaults.object(forKey: Keys.playbackFadeEnabled) as? Bool ?? true
        queueAddBehavior = defaults.string(forKey: Keys.queueAddBehavior)
            .flatMap(QueueAddBehavior.init) ?? .next
        autoSkipUnplayable = defaults.object(forKey: Keys.autoSkipUnplayable) as? Bool ?? true
        playbackEntryView = defaults.string(forKey: Keys.playbackEntryView)
            .flatMap(PlaybackEntryView.init) ?? .nowPlaying
        let storedTintIntensity = defaults.object(forKey: Keys.playerPageTintIntensity) as? Double ?? 1
        playerPageTintIntensity = min(
            max(storedTintIntensity, Self.playerPageTintIntensityRange.lowerBound),
            Self.playerPageTintIntensityRange.upperBound
        )
        hidePlayerProgressBar = defaults.object(forKey: Keys.hidePlayerProgressBar) as? Bool ?? false
        alwaysShowPlayerBackButton =
            defaults.object(forKey: Keys.alwaysShowPlayerBackButton) as? Bool ?? false
        alwaysShowTrackSwitchButtons =
            defaults.object(forKey: Keys.alwaysShowTrackSwitchButtons) as? Bool ?? false
        playerControlSlots = defaults.stringArray(forKey: Keys.playerControlSlots)
            ?? PlayerControlSlot.allCases.map(\.rawValue)
        stageTrackCardEnabled = defaults.object(forKey: Keys.stageTrackCardEnabled) as? Bool ?? false
        transitionAnimationRing = defaults.object(forKey: Keys.transitionAnimationRing) as? Bool ?? false
        transitionAnimationCard = defaults.object(forKey: Keys.transitionAnimationCard) as? Bool ?? false
        #if os(iOS)
        preventDisplaySleepDuringPlayback =
            defaults.object(forKey: Keys.preventDisplaySleep) as? Bool ?? true
        iosCrossfadeEnabled =
            defaults.object(forKey: Keys.iosCrossfadeEnabled) as? Bool ?? false
        #endif
        transitionMode = defaults.string(forKey: Keys.transitionMode)
            .flatMap(TransitionMode.init) ?? .automix
        let storedCrossfadeMaxSeconds = defaults.object(forKey: Keys.crossfadeMaxSeconds) as? Double ?? 8
        crossfadeMaxSeconds = min(
            max(storedCrossfadeMaxSeconds, Self.crossfadeMaxSecondsRange.lowerBound),
            Self.crossfadeMaxSecondsRange.upperBound
        )
        // iOS defaults to .off: the per-track volume trim only applies once
        // the user turns it on. macOS keeps its shipped .auto default.
        #if os(iOS)
        replayGainMode = defaults.string(forKey: Keys.replayGainMode)
            .flatMap(ReplayGainMode.init) ?? .off
        #else
        replayGainMode = defaults.string(forKey: Keys.replayGainMode)
            .flatMap(ReplayGainMode.init) ?? .auto
        #endif
    }
}
