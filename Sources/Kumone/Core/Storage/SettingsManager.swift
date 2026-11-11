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
    /// Folia classic visualizer ("流光", P1 of the luminous port): one big
    /// lyric line at a time, words glowing one by one over the
    /// cover-derived halftone background. iOS compact only, like lattice.
    case luminous

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .vinyl: return String(localized: "黑胶模式")
        case .classic: return String(localized: "经典模式")
        case .immersive: return String(localized: "沉浸模式")
        case .minimal: return String(localized: "简洁模式")
        case .lattice: return String(localized: "格子模式")
        case .luminous: return String(localized: "流光")
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

/// Lyric typeface family for the Folia luminous lyrics (and the Lattice
/// card). Mirrors Folia's `Theme['fontStyle']` (`sans` / `serif` / `mono`)
/// from `useTypographySettingsStore`.
enum LyricsFontStyle: String, CaseIterable, Identifiable {
    case sans
    case serif
    case mono

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sans: return String(localized: "无衬线")
        case .serif: return String(localized: "衬线")
        case .mono: return String(localized: "等宽")
        }
    }

    /// SwiftUI font design for the style; a custom font name (when set) is
    /// resolved by the caller with `Font.custom` instead.
    var design: Font.Design {
        switch self {
        case .sans: return .default
        case .serif: return .serif
        case .mono: return .monospaced
        }
    }
}

/// Which background the luminous (流光) now-playing page uses.
/// Folia's six modes (`BuiltinVisualizerBackgroundMode`), in Folia's
/// registry order, plus the Golia-only `none` (plain dark page) kept
/// for users who chose it before the other modes were ported.
/// `latent` is Folia's default background mode (`DEFAULT_VISUALIZER_
/// BACKGROUND_MODE = 'latent'`): the flowing smoke + warp-dither field
/// from the reference video. `nomand` is the cover through one of five
/// Paper shaders; `common` is the theme colour + blurred cover +
/// drifting shapes; `monet` is a baked cover poster; `url` embeds a
/// webpage; `sora` is a drifting starfield.
enum VisualizerBackgroundMode: String, CaseIterable, Identifiable {
    case common
    case monet
    case nomand
    case latent
    case url
    case sora
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .common: return String(localized: "通用")
        case .monet: return String(localized: "莫奈")
        case .nomand: return String(localized: "漫游")
        case .latent: return String(localized: "潜流（流动烟雾）")
        case .url: return String(localized: "嵌入（网页）")
        case .sora: return String(localized: "空（星空）")
        case .none: return String(localized: "无背景")
        }
    }
}

/// Nomand background effect. Folia's five Paper shaders
/// (`NomandBackgroundEffectSettings.tsx`: dithering / fluted-glass /
/// paper-texture / halftone-dots / lens-distortion), re-implemented
/// natively with Core Image (see `NomandDitherer`); the GLSL itself is
/// closed-source, so each effect is a native re-derivation, not a copy.
enum NomandEffect: String, CaseIterable, Identifiable {
    case dithering
    case flutedGlass
    case paperTexture
    case halftoneDots
    case lensDistortion

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dithering: return String(localized: "像素画")
        case .flutedGlass: return String(localized: "纹理玻璃")
        case .paperTexture: return String(localized: "纸张纹理")
        case .halftoneDots: return String(localized: "半调网点")
        case .lensDistortion: return String(localized: "镜头畸变")
        }
    }
}

/// Latent (隐现) display layers: Folia's `displayMode`
/// ('dithering' | 'mesh' | 'both'). `dithering` is the pixel layer
/// alone, `mesh` the fluid layer alone, `both` the two stacked.
enum LatentDisplayMode: String, CaseIterable, Identifiable {
    case dithering
    case mesh
    case both

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dithering: return String(localized: "像素")
        case .mesh: return String(localized: "流体")
        case .both: return String(localized: "混合")
        }
    }
}

/// Latent (隐现) colour source: Folia's `colorSource`
/// ('cover-theme' | 'cover-only').
enum LatentColorSource: String, CaseIterable, Identifiable {
    case coverTheme
    case coverOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .coverTheme: return String(localized: "封面与主题")
        case .coverOnly: return String(localized: "仅封面取色")
        }
    }
}

/// The latent tuning as one value (Folia's `latent_background_tuning`).
/// Built by `SettingsManager.latentTuning` from the `effective*`
/// properties; the renderer only ever sees this struct, never the store.
///
/// Lives here, not in LatentBackgroundView.swift: that file is
/// `#if os(iOS)`, and the shared SettingsManager is compiled for macOS
/// too — a type it uses must not be defined inside an iOS-only file
/// (macOS build fails with "cannot find type in scope", PR #18 run #53).
struct LatentTuning: Equatable {
    var displayMode: LatentDisplayMode = .both
    var colorSource: LatentColorSource = .coverTheme
    var overlayEnabled: Bool = true
    var overlayOpacity: Double = 0.35
    var ditheringSpeed: Double = 0.1
    var ditheringAudioSpeed: Double = 1.2
    var ditheringSize: Double = 2.5
    var ditheringOpacity: Double = 0.55
    var meshSpeed: Double = 0.3
    var meshAudioSpeed: Double = 2.0
    var meshDistortion: Double = 0.8
    var meshSwirl: Double = 0.1
    var enhancedBeatResponse: Bool = true
}

/// Source image for the monet / nomand backgrounds: the current song's
/// cover, or the single user-uploaded global image (shared by both
/// modes, like Folia's `monet_background_image`).
enum BackgroundImageSource: String, CaseIterable, Identifiable {
    case coverDerived
    case uploadedGlobal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .coverDerived: return String(localized: "封面")
        case .uploadedGlobal: return String(localized: "已上传图片")
        }
    }
}

/// One saved webpage for the `url` (嵌入) background: Folia's
/// `UrlBackgroundItem { id, url, note }`, stored as JSON in UserDefaults.
struct UrlBackgroundItem: Codable, Equatable, Identifiable {
    var id: String
    var url: String
    var note: String

    init(id: String = UUID().uuidString, url: String, note: String) {
        self.id = id
        self.url = url
        self.note = note
    }
}

/// What the subtitle overlay under the luminous line shows. This is a
/// derived view of the two pre-existing lyric settings (see
/// `SettingsManager.subtitleContentMode`): translation ↔
/// `showLyricsTranslation`, romaji ↔ `lyricsAnnotation == .romaji`.
enum SubtitleContentMode: String, CaseIterable, Identifiable {
    case translation
    case romaji
    case both
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .translation: return String(localized: "译文")
        case .romaji: return String(localized: "罗马音")
        case .both: return String(localized: "两者")
        case .none: return String(localized: "无")
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
        // Folia 歌词多源 (restored): auto-best-lyric search across
        // NetEase / AMLL / QQ / Kugou, and the preferred source when
        // several sources match with high confidence.
        static let autoUseBestLyric = "settings.autoUseBestLyric"
        static let preferredLyricSource = "settings.preferredLyricSource"
        // Folia 歌词过滤 (lyricLineRules + staff-credits policy):
        // per-line regex rules, leading staff-block policy, min dwell,
        // absorb mode, custom staff pattern.
        static let lyricLineRules = "settings.lyricLineRules"
        static let lyricStaffPolicy = "settings.lyricStaffPolicy"
        static let lyricStaffMinDwellSeconds = "settings.lyricStaffMinDwellSeconds"
        static let lyricStaffAbsorbMode = "settings.lyricStaffAbsorbMode"
        static let lyricStaffPattern = "settings.lyricStaffPattern"
        static let volume = "settings.volume"
        static let fmMode = "settings.fmMode"
        static let unblock = "settings.enableUnblock"
        static let unblockSources = "settings.enabledUnblockSources"

        // Folia B12: global lyric timeline offset, milliseconds, ±2000.
        static let globalLyricTimelineOffsetMs = "settings.globalLyricTimelineOffsetMs"
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
        #if os(iOS)
        static let soundEffectPreset = "settings.soundEffectPreset"
        static let customEqualizerGains = "settings.customEqualizerGains"
        #endif
        static let lyricAnimationStyle = "settings.lyricAnimationStyle"
        static let homePlatform = "settings.homePlatform"
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
        // Beans `playbackSection` (P3 2/3).
        static let mixWithOtherAudio = "settings.mixWithOtherAudio"
        static let autoResumeLastPlayback = "settings.autoResumeLastPlayback"
        static let showThirdPartySourceNotice = "settings.showThirdPartySourceNotice"
        // Folia auto-hide (restored): 3s idle fade of the player chrome.
        static let autoHidePlayerChrome = "settings.autoHidePlayerChrome"
        // Beans `appearanceSection` (P3 3/3): deep appearance
        // customization. All `settings.*` (Golia namespace, never
        // `beans.*`); the file I/O lives in `WallpaperStore` /
        // `FontManager`, the state lives here like P3a/P3b.
        static let customAccentHex = "settings.customAccentHex"
        static let tabLabelsVisible = "settings.tabLabelsVisible"
        static let legacyTabBarCornerRadius = "settings.legacyTabBarCornerRadius"
        static let legacyTabBarWidth = "settings.legacyTabBarWidth"
        static let legacyTabBarOffsetX = "settings.legacyTabBarOffsetX"
        static let legacyTabBarOffsetY = "settings.legacyTabBarOffsetY"
        static let homeWallpaperBlur = "settings.homeWallpaperBlur"
        static let backgroundSyncAll = "settings.backgroundSyncAll"
        static let backgroundHexLight = "settings.backgroundHexLight"
        static let backgroundHexDark = "settings.backgroundHexDark"
        static let backgroundImagePathLight = "settings.backgroundImagePathLight"
        static let backgroundImagePathDark = "settings.backgroundImagePathDark"
        static let wallpaperPaths = "settings.wallpaperPaths"
        // Installed global font (PostScript name), managed by
        // `FontManager`. Not a settings row's key — the font rows read
        // it through `FontManager.installedFontName`.
        static let customFontName = "settings.customFontName"
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
        // Folia luminous (流光) classic tuning.
        static let classicWordRotation = "settings.classicWordRotation"
        static let classicBreathingFloat = "settings.classicBreathingFloat"
        static let classicWordSpacing = "settings.classicWordSpacing"
        static let classicAvoidOverlap = "settings.classicAvoidOverlap"
        // Folia nomand (漫游) halftone background.
        static let visualizerBackgroundMode = "settings.visualizerBackgroundMode"
        static let nomandEffect = "settings.nomandEffect"
        static let nomandHalftoneSize = "settings.nomandHalftoneSize"
        static let nomandHalftoneRadius = "settings.nomandHalftoneRadius"
        static let nomandHalftoneContrast = "settings.nomandHalftoneContrast"
        static let nomandOriginalColors = "settings.nomandOriginalColors"
        static let nomandOverlayOpacity = "settings.nomandOverlayOpacity"
        static let nomandOverlayEnabled = "settings.nomandOverlayEnabled"
        static let nomandImageSource = "settings.nomandImageSource"
        static let nomandDitheringType = "settings.nomandDitheringType"
        static let nomandDitheringSize = "settings.nomandDitheringSize"
        static let nomandDitheringColorSteps = "settings.nomandDitheringColorSteps"
        static let nomandDitheringOriginalColors = "settings.nomandDitheringOriginalColors"
        static let nomandDitheringInverted = "settings.nomandDitheringInverted"
        static let nomandFlutedGlassSize = "settings.nomandFlutedGlassSize"
        static let nomandFlutedGlassDistortion = "settings.nomandFlutedGlassDistortion"
        static let nomandFlutedGlassBlur = "settings.nomandFlutedGlassBlur"
        static let nomandPaperTextureContrast = "settings.nomandPaperTextureContrast"
        static let nomandPaperTextureRoughness = "settings.nomandPaperTextureRoughness"
        static let nomandPaperTextureFiber = "settings.nomandPaperTextureFiber"
        static let nomandHalftoneDotsInverted = "settings.nomandHalftoneDotsInverted"
        static let nomandLensDistortionSpread = "settings.nomandLensDistortionSpread"
        static let nomandLensDistortionBulge = "settings.nomandLensDistortionBulge"
        static let nomandLensDistortionDispersion = "settings.nomandLensDistortionDispersion"
        // Folia latent (隐现) background tuning.
        static let latentDisplayMode = "settings.latentDisplayMode"
        static let latentColorSource = "settings.latentColorSource"
        static let latentDynamicOnlyInPlayer = "settings.latentDynamicOnlyInPlayer"
        static let latentEnhancedBeatResponse = "settings.latentEnhancedBeatResponse"
        static let latentDitheringSpeed = "settings.latentDitheringSpeed"
        static let latentDitheringAudioSpeed = "settings.latentDitheringAudioSpeed"
        static let latentDitheringSize = "settings.latentDitheringSize"
        static let latentDitheringOpacity = "settings.latentDitheringOpacity"
        static let latentMeshSpeed = "settings.latentMeshSpeed"
        static let latentMeshAudioSpeed = "settings.latentMeshAudioSpeed"
        static let latentMeshDistortion = "settings.latentMeshDistortion"
        static let latentMeshSwirl = "settings.latentMeshSwirl"
        static let latentOverlayEnabled = "settings.latentOverlayEnabled"
        static let latentOverlayOpacity = "settings.latentOverlayOpacity"
        // Folia common (通用) background.
        static let commonOpacity = "settings.commonOpacity"
        static let commonUseCoverColorBg = "settings.commonUseCoverColorBg"
        static let commonDisableVignette = "settings.commonDisableVignette"
        static let commonDisableGeometric = "settings.commonDisableGeometric"
        // Folia monet (莫奈) background.
        static let monetBackgroundSource = "settings.monetBackgroundSource"
        static let monetBackgroundLayout = "settings.monetBackgroundLayout"
        static let monetBackgroundBlurPx = "settings.monetBackgroundBlurPx"
        static let monetBackgroundOverlayOpacity = "settings.monetBackgroundOverlayOpacity"
        static let monetBackgroundGrayscale = "settings.monetBackgroundGrayscale"
        static let monetBackgroundSaturation = "settings.monetBackgroundSaturation"
        static let monetBackgroundWash = "settings.monetBackgroundWash"
        static let monetBackgroundHalfPaneOffsetX = "settings.monetBackgroundHalfPaneOffsetX"
        static let monetBackgroundWashColorMode = "settings.monetBackgroundWashColorMode"
        static let monetBackgroundWashCustomColor = "settings.monetBackgroundWashCustomColor"
        static let monetBackgroundDriftEnabled = "settings.monetBackgroundDriftEnabled"
        static let monetBackgroundDriftStrength = "settings.monetBackgroundDriftStrength"
        static let monetBackgroundStreaksEnabled = "settings.monetBackgroundStreaksEnabled"
        // Folia sora (空) background.
        static let soraBlank = "settings.soraBlank"
        // Folia url (嵌入) background: a list of saved webpages + the
        // selected one, stored as JSON.
        static let urlBackgroundList = "settings.urlBackgroundList"
        static let urlBackgroundSelectedID = "settings.urlBackgroundSelectedID"
        // The single user-uploaded background image (monet + nomand share
        // it, like Folia's `monet_background_image`): the file name under
        // Application Support; the bytes live in
        // `VisualizerBackgroundImageStore`, not in UserDefaults.
        static let uploadedBackgroundImageName = "settings.uploadedBackgroundImageName"
        // Folia lyric-style window (VisPlayground).
        static let lyricsFontStyle = "settings.lyricsFontStyle"
        static let lyricsFontScale = "settings.lyricsFontScale"
        static let lyricsFontWeight = "settings.lyricsFontWeight"
        static let lyricsCustomFont = "settings.lyricsCustomFont"
        static let visualizerOpacity = "settings.visualizerOpacity"
        static let subtitleFontScale = "settings.subtitleFontScale"
        static let subtitleOverlayOpacity = "settings.subtitleOverlayOpacity"
        static let subtitleUpcomingLyricsBlur = "settings.subtitleUpcomingLyricsBlur"
        static let hideTranslationSubtitle = "settings.hideTranslationSubtitle"
        static let subtitleFontFollowsLyrics = "settings.subtitleFontFollowsLyrics"
        static let subtitleHarmonyEnabled = "settings.subtitleHarmonyEnabled"
        static let subtitleUpcomingLineCount = "settings.subtitleUpcomingLineCount"
        static let subtitleBackgroundEnabled = "settings.subtitleBackgroundEnabled"
        static let subtitleHarmonyBackgroundEnabled = "settings.subtitleHarmonyBackgroundEnabled"
        static let subtitleFontStyle = "settings.subtitleFontStyle"
        static let subtitleFontWeight = "settings.subtitleFontWeight"
        static let subtitleCustomFont = "settings.subtitleCustomFont"
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

    /// Auto-search NetEase, AMLL, QQ and Kugou lyrics and prefer a
    /// perfectly-matching verbatim lyric when one exists (Folia
    /// "自动使用最佳歌词", default on).
    @Published var autoUseBestLyric: Bool {
        didSet { UserDefaults.standard.set(autoUseBestLyric, forKey: Keys.autoUseBestLyric) }
    }

    /// When several sources have a high-confidence match, prefer this
    /// source's result (Folia "歌词匹配优先级", default NetEase).
    @Published var preferredLyricSource: LyricSource {
        didSet { UserDefaults.standard.set(preferredLyricSource.rawValue, forKey: Keys.preferredLyricSource) }
    }

    /// Per-line filter rules (Folia "歌词过滤"): a line is removed when
    /// any enabled rule matches its full text. Stored as a JSON array;
    /// the defaults reproduce the strips the parser used to apply.
    @Published var lyricLineRules: [LyricLineRule] {
        didSet { UserDefaults.standard.set(LyricFilterSettings.encodeRules(lyricLineRules), forKey: Keys.lyricLineRules) }
    }

    /// What happens to the leading staff block (Folia 制作人员信息:
    /// 保留 / 智能 / 隐藏, default smart).
    @Published var lyricStaffPolicy: LyricStaffPolicy {
        didSet { UserDefaults.standard.set(lyricStaffPolicy.rawValue, forKey: Keys.lyricStaffPolicy) }
    }

    /// Shortest time a staff line gets to stay on screen (Folia
    /// "每行最少停留", 0.6–4 s, default 1.5 s).
    @Published var lyricStaffMinDwellSeconds: Double {
        didSet { UserDefaults.standard.set(lyricStaffMinDwellSeconds, forKey: Keys.lyricStaffMinDwellSeconds) }
    }

    /// Whether lines adjacent to the staff block are pulled into it
    /// (Folia 吸收相邻行: 不吸收 / 仅之前 / 前后都吸收, default off).
    @Published var lyricStaffAbsorbMode: LyricStaffAbsorbMode {
        didSet { UserDefaults.standard.set(lyricStaffAbsorbMode.rawValue, forKey: Keys.lyricStaffAbsorbMode) }
    }

    /// Custom staff-detection regex; empty means the built-in word list
    /// (Folia "自定义识别正则").
    @Published var lyricStaffPattern: String {
        didSet { UserDefaults.standard.set(lyricStaffPattern, forKey: Keys.lyricStaffPattern) }
    }

    /// Best-lyric search with the master switch off: pre-rollback the
    /// app fetched NetEase lyrics only, so the multi-source search
    /// stays off.
    var effectiveAutoUseBestLyric: Bool {
        foliaEnabled ? autoUseBestLyric : false
    }

    /// Preferred lyric source with the master switch off: NetEase,
    /// the pre-folia behaviour.
    var effectivePreferredLyricSource: LyricSource {
        foliaEnabled ? preferredLyricSource : .netease
    }

    /// Filter rules with the master switch off: the built-in strips
    /// only, the pre-filter behaviour.
    var effectiveLyricLineRules: [LyricLineRule] {
        foliaEnabled ? lyricLineRules : LyricLineRule.defaultRules
    }

    /// Staff policy with the master switch off: keep, the pre-filter
    /// behaviour (no block is ever hidden or retimed).
    var effectiveLyricStaffPolicy: LyricStaffPolicy {
        foliaEnabled ? lyricStaffPolicy : .keep
    }

    /// Staff min dwell with the master switch off: the default (it only
    /// matters while the policy can act).
    var effectiveLyricStaffMinDwellSeconds: Double {
        foliaEnabled ? lyricStaffMinDwellSeconds : LyricFilterSettings.defaultMinDwellSeconds
    }

    /// Staff absorb mode with the master switch off: off.
    var effectiveLyricStaffAbsorbMode: LyricStaffAbsorbMode {
        foliaEnabled ? lyricStaffAbsorbMode : .off
    }

    /// Staff pattern with the master switch off: empty (built-in list).
    var effectiveLyricStaffPattern: String {
        foliaEnabled ? lyricStaffPattern : ""
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
        enableUnblock
            && (!enabledAudioSourceIDs.isEmpty
                || CustomAudioSourceStore.shared.hasEnabledScriptSources)
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

    // Folia luminous / nomand / lyric-style defaults (Folia v0.7.26:
    // `DEFAULT_CLASSIC_TUNING`, `DEFAULT_NOMAND_BACKGROUND_TUNING`,
    // `useTypographySettingsStore`). Kept as static constants so tests can
    // pin them, and so the master-switch-off fallbacks have one source of
    // truth with the stored defaults.
    nonisolated static let defaultClassicWordRotation = true
    nonisolated static let defaultClassicBreathingFloat = 1.0
    nonisolated static let defaultClassicWordSpacing = 0.7
    nonisolated static let defaultClassicAvoidOverlap = false
    nonisolated static let defaultVisualizerBackgroundMode = VisualizerBackgroundMode.latent
    nonisolated static let defaultNomandEffect = NomandEffect.halftoneDots
    nonisolated static let defaultNomandHalftoneSize = 0.5
    nonisolated static let defaultNomandHalftoneRadius = 1.25
    nonisolated static let defaultNomandHalftoneContrast = 0.4
    nonisolated static let defaultNomandOriginalColors = false
    nonisolated static let defaultNomandOverlayOpacity = 0.35
    nonisolated static let defaultNomandOverlayEnabled = true
    nonisolated static let defaultNomandImageSource = BackgroundImageSource.coverDerived
    nonisolated static let defaultNomandDitheringType = NomandDitheringType.eightByEight
    nonisolated static let defaultNomandDitheringSize = 3.0
    nonisolated static let defaultNomandDitheringColorSteps = 4
    nonisolated static let defaultNomandDitheringOriginalColors = false
    nonisolated static let defaultNomandDitheringInverted = false
    nonisolated static let defaultNomandFlutedGlassSize = 0.5
    nonisolated static let defaultNomandFlutedGlassDistortion = 0.5
    nonisolated static let defaultNomandFlutedGlassBlur = 0.08
    nonisolated static let defaultNomandPaperTextureContrast = 0.32
    nonisolated static let defaultNomandPaperTextureRoughness = 0.42
    nonisolated static let defaultNomandPaperTextureFiber = 0.3
    nonisolated static let defaultNomandHalftoneDotsInverted = false
    nonisolated static let defaultNomandLensDistortionSpread = 0.45
    nonisolated static let defaultNomandLensDistortionBulge = 0.3
    nonisolated static let defaultNomandLensDistortionDispersion = 0.65
    // Folia latent (隐现) defaults (`DEFAULT_LATENT_BACKGROUND_TUNING`).
    nonisolated static let defaultLatentDisplayMode = LatentDisplayMode.both
    nonisolated static let defaultLatentColorSource = LatentColorSource.coverTheme
    nonisolated static let defaultLatentDynamicOnlyInPlayer = true
    nonisolated static let defaultLatentEnhancedBeatResponse = true
    nonisolated static let defaultLatentDitheringSpeed = 0.1
    nonisolated static let defaultLatentDitheringAudioSpeed = 1.2
    nonisolated static let defaultLatentDitheringSize = 2.5
    nonisolated static let defaultLatentDitheringOpacity = 0.55
    nonisolated static let defaultLatentMeshSpeed = 0.3
    nonisolated static let defaultLatentMeshAudioSpeed = 2.0
    nonisolated static let defaultLatentMeshDistortion = 0.8
    nonisolated static let defaultLatentMeshSwirl = 0.1
    nonisolated static let defaultLatentOverlayEnabled = true
    nonisolated static let defaultLatentOverlayOpacity = 0.35
    // Folia common (通用) defaults.
    nonisolated static let defaultCommonOpacity = 0.75
    nonisolated static let defaultCommonUseCoverColorBg = false
    nonisolated static let defaultCommonDisableVignette = false
    nonisolated static let defaultCommonDisableGeometric = false
    // Folia monet (莫奈) defaults (`DEFAULT_MONET_BACKGROUND_TUNING`).
    nonisolated static let defaultMonetBackgroundSource = BackgroundImageSource.coverDerived
    nonisolated static let defaultMonetBackgroundLayout = MonetLayout.fullOverlay
    nonisolated static let defaultMonetBackgroundBlurPx = 6.0
    nonisolated static let defaultMonetBackgroundOverlayOpacity = 0.74
    nonisolated static let defaultMonetBackgroundGrayscale = 0.0
    nonisolated static let defaultMonetBackgroundSaturation = 1.05
    nonisolated static let defaultMonetBackgroundWash = 0.34
    nonisolated static let defaultMonetBackgroundHalfPaneOffsetX = 0.0
    nonisolated static let defaultMonetBackgroundWashColorMode = MonetWashColorMode.theme
    nonisolated static let defaultMonetBackgroundWashCustomColor = "#8fb7ff"
    nonisolated static let defaultMonetBackgroundDriftEnabled = true
    nonisolated static let defaultMonetBackgroundDriftStrength = 0.5
    nonisolated static let defaultMonetBackgroundStreaksEnabled = true
    // Folia sora (空) default.
    nonisolated static let defaultSoraBlank = false
    nonisolated static let defaultLyricsFontStyle = LyricsFontStyle.sans
    nonisolated static let defaultLyricsFontScale = 1.0
    nonisolated static let defaultVisualizerOpacity = 1.0
    nonisolated static let defaultSubtitleFontScale = 1.0
    nonisolated static let defaultSubtitleOverlayOpacity = 0.6
    nonisolated static let defaultSubtitleUpcomingLyricsBlur = true
    nonisolated static let defaultHideTranslationSubtitle = false
    nonisolated static let defaultSubtitleFontFollowsLyrics = true
    nonisolated static let defaultSubtitleHarmonyEnabled = true
    nonisolated static let defaultSubtitleUpcomingLineCount = 2
    nonisolated static let defaultSubtitleBackgroundEnabled = false
    nonisolated static let defaultSubtitleHarmonyBackgroundEnabled = false
    nonisolated static let defaultSubtitleFontStyle = LyricsFontStyle.sans

    nonisolated static let classicBreathingFloatRange = 0.0...2.0
    nonisolated static let classicWordSpacingRange = 0.0...2.0
    nonisolated static let nomandHalftoneSizeRange = 0.1...1.0
    nonisolated static let nomandHalftoneRadiusRange = 0.1...2.0
    nonisolated static let nomandHalftoneContrastRange = 0.0...1.0
    nonisolated static let nomandOverlayOpacityRange = 0.0...1.0
    nonisolated static let nomandDitheringSizeRange = 0.5...20.0
    nonisolated static let nomandDitheringColorStepsRange = 1...7
    nonisolated static let nomandFlutedGlassSizeRange = 0.1...1.0
    nonisolated static let nomandFlutedGlassDistortionRange = 0.0...1.0
    nonisolated static let nomandFlutedGlassBlurRange = 0.0...1.0
    nonisolated static let nomandPaperTextureContrastRange = 0.0...1.0
    nonisolated static let nomandPaperTextureRoughnessRange = 0.0...1.0
    nonisolated static let nomandPaperTextureFiberRange = 0.0...1.0
    nonisolated static let nomandLensDistortionSpreadRange = 0.0...1.0
    nonisolated static let nomandLensDistortionBulgeRange = -1.0...1.0
    nonisolated static let nomandLensDistortionDispersionRange = 0.0...1.0
    nonisolated static let latentSpeedRange = 0.0...2.0
    nonisolated static let latentDitheringSizeRange = 0.5...8.0
    nonisolated static let latentOpacityRange = 0.0...1.0
    nonisolated static let latentMeshDistortionRange = 0.0...2.0
    nonisolated static let latentMeshSwirlRange = 0.0...1.0
    nonisolated static let commonOpacityRange = 0.0...1.0
    nonisolated static let monetBackgroundBlurPxRange = 0.0...60.0
    nonisolated static let monetBackgroundOverlayOpacityRange = 0.0...1.0
    nonisolated static let monetBackgroundGrayscaleRange = 0.0...1.0
    nonisolated static let monetBackgroundSaturationRange = 0.0...2.0
    nonisolated static let monetBackgroundWashRange = 0.0...1.0
    nonisolated static let monetBackgroundHalfPaneOffsetXRange = -40.0...40.0
    nonisolated static let monetBackgroundDriftStrengthRange = 0.0...1.0
    nonisolated static let lyricsFontScaleRange = 0.85...1.4
    nonisolated static let lyricsFontWeightRange = 100.0...900.0
    nonisolated static let visualizerOpacityRange = 0.2...1.0
    nonisolated static let subtitleFontScaleRange = 0.85...1.4
    nonisolated static let subtitleOverlayOpacityRange = 0.0...1.0
    nonisolated static let subtitleUpcomingLineCountRange = 0...2

    nonisolated static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// A `#rrggbb` colour string, or `defaultValue` when the stored value
    /// is not one (a hand-edited default, or a colour from an older build).
    nonisolated static func normalizedHexColor(_ value: String?, default defaultValue: String) -> String {
        guard let value, value.count == 7, value.hasPrefix("#"),
              value.dropFirst().allSatisfy({ $0.isHexDigit })
        else { return defaultValue }
        return value
    }

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

    /// Home-page platform: which service's feed the home page shows.
    /// NetEase by default, which preserves today's behaviour.
    @Published var homePlatform: HomePlatform {
        didSet { UserDefaults.standard.set(homePlatform.rawValue, forKey: Keys.homePlatform) }
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

    private static func setOptionalDouble(_ value: Double?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func setOptionalString(_ value: String?, forKey key: String) {
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

    /// Beans `playbackSection` (P3 2/3): play alongside other apps'
    /// audio instead of silencing them. Not Folia-gated.
    @Published var mixWithOtherAudio: Bool {
        didSet { UserDefaults.standard.set(mixWithOtherAudio, forKey: Keys.mixWithOtherAudio) }
    }

    /// Beans `playbackSection` (P3 2/3): resume the last unfinished
    /// song on launch. Not Folia-gated.
    @Published var autoResumeLastPlayback: Bool {
        didSet { UserDefaults.standard.set(autoResumeLastPlayback, forKey: Keys.autoResumeLastPlayback) }
    }

    /// Beans `playbackSection` (P3 2/3): toast when a third-party
    /// source plays a VIP song. Not Folia-gated.
    @Published var showThirdPartySourceNotice: Bool {
        didSet { UserDefaults.standard.set(showThirdPartySourceNotice, forKey: Keys.showThirdPartySourceNotice) }
    }

    /// Folia auto-hide (restored): hide the now-playing page chrome
    /// (scrubber, transport and top buttons) after 3 seconds without
    /// interaction; tap the page to bring it back. Default off.
    @Published var autoHidePlayerChrome: Bool {
        didSet { UserDefaults.standard.set(autoHidePlayerChrome, forKey: Keys.autoHidePlayerChrome) }
    }

    /// Auto-hide with the master switch off: the chrome never hides.
    var effectiveAutoHidePlayerChrome: Bool {
        foliaEnabled ? autoHidePlayerChrome : false
    }

    // MARK: - Beans `appearanceSection` (P3 3/3)

    /// Custom accent colour as "#RRGGBB"; empty means the default
    /// brand red. Read by `Theme.accent` (via UserDefaults, not via
    /// this property — `Theme` is nonisolated and this class is
    /// @MainActor). Not Folia-gated.
    @Published var customAccentHex: String {
        didSet { UserDefaults.standard.set(customAccentHex, forKey: Keys.customAccentHex) }
    }

    /// Show the text label under each GlassTabBar icon. Not
    /// Folia-gated.
    @Published var tabLabelsVisible: Bool {
        didSet { UserDefaults.standard.set(tabLabelsVisible, forKey: Keys.tabLabelsVisible) }
    }

    static let legacyTabBarCornerRadiusRange = 18.0...42.0
    static let legacyTabBarWidthRange = 300.0...420.0
    static let legacyTabBarOffsetXRange = -40.0...40.0
    static let legacyTabBarOffsetYRange = -36.0...36.0

    /// Floating tab bar geometry (Beans' "低系统悬浮底栏" sliders,
    /// ported to Golia's `GlassTabBar`, which is the floating bar on
    /// every iOS version here — Beans gates them to iOS <26 because
    /// iOS 26+ uses the system bar). Width default 420 (not Beans'
    /// 356): 420 is the slider max, i.e. today's full-width look.
    @Published var legacyTabBarCornerRadius: Double {
        didSet { UserDefaults.standard.set(legacyTabBarCornerRadius, forKey: Keys.legacyTabBarCornerRadius) }
    }

    @Published var legacyTabBarWidth: Double {
        didSet { UserDefaults.standard.set(legacyTabBarWidth, forKey: Keys.legacyTabBarWidth) }
    }

    @Published var legacyTabBarOffsetX: Double {
        didSet { UserDefaults.standard.set(legacyTabBarOffsetX, forKey: Keys.legacyTabBarOffsetX) }
    }

    @Published var legacyTabBarOffsetY: Double {
        didSet { UserDefaults.standard.set(legacyTabBarOffsetY, forKey: Keys.legacyTabBarOffsetY) }
    }

    /// Home wallpaper blur radius (0...30pt). Only visible when a
    /// wallpaper image is applied. Not Folia-gated.
    @Published var homeWallpaperBlur: Double {
        didSet { UserDefaults.standard.set(homeWallpaperBlur, forKey: Keys.homeWallpaperBlur) }
    }

    /// Apply the home background (colour / wallpaper) to search,
    /// library and 我的 as well. Off = home only. Not Folia-gated.
    @Published var backgroundSyncAll: Bool {
        didSet { UserDefaults.standard.set(backgroundSyncAll, forKey: Keys.backgroundSyncAll) }
    }

    /// Custom home background colour ("#RRGGBB", empty = unset) for
    /// the light / dark appearance. Not Folia-gated.
    @Published var backgroundHexLight: String {
        didSet { UserDefaults.standard.set(backgroundHexLight, forKey: Keys.backgroundHexLight) }
    }

    @Published var backgroundHexDark: String {
        didSet { UserDefaults.standard.set(backgroundHexDark, forKey: Keys.backgroundHexDark) }
    }

    /// Active wallpaper file path ("", unset) for the light / dark
    /// appearance. Paths live under Documents/Wallpapers; the files
    /// are managed by `WallpaperStore`. Not Folia-gated.
    @Published var backgroundImagePathLight: String {
        didSet { UserDefaults.standard.set(backgroundImagePathLight, forKey: Keys.backgroundImagePathLight) }
    }

    @Published var backgroundImagePathDark: String {
        didSet { UserDefaults.standard.set(backgroundImagePathDark, forKey: Keys.backgroundImagePathDark) }
    }

    /// Wallpaper library: all uploaded wallpaper file paths.
    @Published var wallpaperPaths: [String] {
        didSet { UserDefaults.standard.set(wallpaperPaths, forKey: Keys.wallpaperPaths) }
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

    /// Track-change fade (restored 切歌淡入淡出, single-engine):
    /// fade the outgoing track out and the incoming one in, with a
    /// short silence gap in between — no overlap, the dual-deck
    /// crossfade stays deleted. Default off.
    @Published var iosCrossfadeEnabled: Bool {
        didSet { UserDefaults.standard.set(iosCrossfadeEnabled, forKey: Keys.iosCrossfadeEnabled) }
    }

    /// Track-change fade with the master switch off: pre-folia iOS
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

    /// Now-playing mode with the Folia master switch off: `.lattice` and
    /// `.luminous` are Folia modes, so they fall back to the pre-folia
    /// default (`.immersive`); vinyl/classic/immersive/minimal predate
    /// Folia and pass through unchanged.
    var effectiveNowPlayingMode: NowPlayingMode {
        guard foliaEnabled || (nowPlayingMode != .lattice && nowPlayingMode != .luminous) else {
            return .immersive
        }
        return nowPlayingMode
    }

    // MARK: - Folia luminous (流光) classic tuning

    /// classic: let words rotate to their deterministic random angle.
    @Published var classicWordRotation: Bool {
        didSet { UserDefaults.standard.set(classicWordRotation, forKey: Keys.classicWordRotation) }
    }

    /// classic word rotation with the master switch off: the Folia default.
    var effectiveClassicWordRotation: Bool {
        foliaEnabled ? classicWordRotation : Self.defaultClassicWordRotation
    }

    /// classic: whole-line breathing float multiplier (0–2, 0 = still).
    @Published var classicBreathingFloat: Double {
        didSet { UserDefaults.standard.set(classicBreathingFloat, forKey: Keys.classicBreathingFloat) }
    }

    /// classic breathing float with the master switch off: the Folia default.
    var effectiveClassicBreathingFloat: Double {
        foliaEnabled ? classicBreathingFloat : Self.defaultClassicBreathingFloat
    }

    /// classic: word spacing multiplier (0–2) applied to the computed gap
    /// between neighbouring words.
    @Published var classicWordSpacing: Double {
        didSet { UserDefaults.standard.set(classicWordSpacing, forKey: Keys.classicWordSpacing) }
    }

    /// classic word spacing with the master switch off: the Folia default.
    var effectiveClassicWordSpacing: Double {
        foliaEnabled ? classicWordSpacing : Self.defaultClassicWordSpacing
    }

    /// classic: space words by how far they actually reach when scaled,
    /// turned and offset, so none overlaps another.
    @Published var classicAvoidOverlap: Bool {
        didSet { UserDefaults.standard.set(classicAvoidOverlap, forKey: Keys.classicAvoidOverlap) }
    }

    /// classic avoid-overlap with the master switch off: the Folia default.
    var effectiveClassicAvoidOverlap: Bool {
        foliaEnabled ? classicAvoidOverlap : Self.defaultClassicAvoidOverlap
    }

    // MARK: - Folia nomand (漫游) halftone background

    /// Background behind the luminous now-playing page.
    @Published var visualizerBackgroundMode: VisualizerBackgroundMode {
        didSet {
            UserDefaults.standard.set(visualizerBackgroundMode.rawValue, forKey: Keys.visualizerBackgroundMode)
        }
    }

    /// Background mode with the master switch off: the Folia default.
    var effectiveVisualizerBackgroundMode: VisualizerBackgroundMode {
        foliaEnabled ? visualizerBackgroundMode : Self.defaultVisualizerBackgroundMode
    }

    /// Nomand effect. Only halftone-dots is ported for now.
    @Published var nomandEffect: NomandEffect {
        didSet { UserDefaults.standard.set(nomandEffect.rawValue, forKey: Keys.nomandEffect) }
    }

    /// Nomand effect with the master switch off: the Folia default.
    var effectiveNomandEffect: NomandEffect {
        foliaEnabled ? nomandEffect : Self.defaultNomandEffect
    }

    /// Halftone dot size (0.1–1): larger values pack the dots tighter.
    @Published var nomandHalftoneSize: Double {
        didSet { UserDefaults.standard.set(nomandHalftoneSize, forKey: Keys.nomandHalftoneSize) }
    }

    /// Halftone dot size with the master switch off: the Folia default.
    var effectiveNomandHalftoneSize: Double {
        foliaEnabled ? nomandHalftoneSize : Self.defaultNomandHalftoneSize
    }

    /// Halftone dot radius (0.1–2): larger values make harder, rounder dots.
    @Published var nomandHalftoneRadius: Double {
        didSet { UserDefaults.standard.set(nomandHalftoneRadius, forKey: Keys.nomandHalftoneRadius) }
    }

    /// Halftone dot radius with the master switch off: the Folia default.
    var effectiveNomandHalftoneRadius: Double {
        foliaEnabled ? nomandHalftoneRadius : Self.defaultNomandHalftoneRadius
    }

    /// Halftone contrast (0–1): how hard the dot pattern cuts.
    @Published var nomandHalftoneContrast: Double {
        didSet { UserDefaults.standard.set(nomandHalftoneContrast, forKey: Keys.nomandHalftoneContrast) }
    }

    /// Halftone contrast with the master switch off: the Folia default.
    var effectiveNomandHalftoneContrast: Double {
        foliaEnabled ? nomandHalftoneContrast : Self.defaultNomandHalftoneContrast
    }

    /// Keep the cover's own colours in the halftone dots instead of mapping
    /// them to the theme accent / background.
    @Published var nomandOriginalColors: Bool {
        didSet { UserDefaults.standard.set(nomandOriginalColors, forKey: Keys.nomandOriginalColors) }
    }

    /// Original colours with the master switch off: the Folia default.
    var effectiveNomandOriginalColors: Bool {
        foliaEnabled ? nomandOriginalColors : Self.defaultNomandOriginalColors
    }

    /// Theme-background veil over the halftone layer (0–1).
    @Published var nomandOverlayOpacity: Double {
        didSet { UserDefaults.standard.set(nomandOverlayOpacity, forKey: Keys.nomandOverlayOpacity) }
    }

    /// Overlay opacity with the master switch off: the Folia default.
    var effectiveNomandOverlayOpacity: Double {
        foliaEnabled ? nomandOverlayOpacity : Self.defaultNomandOverlayOpacity
    }

    /// Readability tint on/off for the nomand layer (Folia
    /// `overlayEnabled`); the opacity above is only used when this is on.
    @Published var nomandOverlayEnabled: Bool {
        didSet { UserDefaults.standard.set(nomandOverlayEnabled, forKey: Keys.nomandOverlayEnabled) }
    }

    /// Nomand overlay on/off with the master switch off: the Folia default.
    var effectiveNomandOverlayEnabled: Bool {
        foliaEnabled ? nomandOverlayEnabled : Self.defaultNomandOverlayEnabled
    }

    /// Source image for the nomand shaders: the current cover, or the
    /// uploaded global image.
    @Published var nomandImageSource: BackgroundImageSource {
        didSet { UserDefaults.standard.set(nomandImageSource.rawValue, forKey: Keys.nomandImageSource) }
    }

    /// Nomand image source with the master switch off: the Folia default.
    var effectiveNomandImageSource: BackgroundImageSource {
        foliaEnabled ? nomandImageSource : Self.defaultNomandImageSource
    }

    /// Dithering (像素画) Bayer matrix size.
    @Published var nomandDitheringType: NomandDitheringType {
        didSet { UserDefaults.standard.set(nomandDitheringType.rawValue, forKey: Keys.nomandDitheringType) }
    }

    /// Dithering type with the master switch off: the Folia default.
    var effectiveNomandDitheringType: NomandDitheringType {
        foliaEnabled ? nomandDitheringType : Self.defaultNomandDitheringType
    }

    /// Dithering cell size (0.5–20).
    @Published var nomandDitheringSize: Double {
        didSet { UserDefaults.standard.set(nomandDitheringSize, forKey: Keys.nomandDitheringSize) }
    }

    /// Dithering cell size with the master switch off: the Folia default.
    var effectiveNomandDitheringSize: Double {
        foliaEnabled ? nomandDitheringSize : Self.defaultNomandDitheringSize
    }

    /// Dithering palette steps (1–7).
    @Published var nomandDitheringColorSteps: Int {
        didSet { UserDefaults.standard.set(nomandDitheringColorSteps, forKey: Keys.nomandDitheringColorSteps) }
    }

    /// Dithering palette steps with the master switch off: the Folia default.
    var effectiveNomandDitheringColorSteps: Int {
        foliaEnabled ? nomandDitheringColorSteps : Self.defaultNomandDitheringColorSteps
    }

    /// Dithering: keep the image's own colours instead of the theme palette.
    @Published var nomandDitheringOriginalColors: Bool {
        didSet { UserDefaults.standard.set(nomandDitheringOriginalColors, forKey: Keys.nomandDitheringOriginalColors) }
    }

    /// Dithering original colours with the master switch off: the Folia default.
    var effectiveNomandDitheringOriginalColors: Bool {
        foliaEnabled ? nomandDitheringOriginalColors : Self.defaultNomandDitheringOriginalColors
    }

    /// Dithering: invert the luminance before dithering.
    @Published var nomandDitheringInverted: Bool {
        didSet { UserDefaults.standard.set(nomandDitheringInverted, forKey: Keys.nomandDitheringInverted) }
    }

    /// Dithering inversion with the master switch off: the Folia default.
    var effectiveNomandDitheringInverted: Bool {
        foliaEnabled ? nomandDitheringInverted : Self.defaultNomandDitheringInverted
    }

    /// Fluted-glass (纹理玻璃) rib spacing (0.1–1).
    @Published var nomandFlutedGlassSize: Double {
        didSet { UserDefaults.standard.set(nomandFlutedGlassSize, forKey: Keys.nomandFlutedGlassSize) }
    }

    /// Fluted-glass rib spacing with the master switch off: the Folia default.
    var effectiveNomandFlutedGlassSize: Double {
        foliaEnabled ? nomandFlutedGlassSize : Self.defaultNomandFlutedGlassSize
    }

    /// Fluted-glass refraction strength (0–1).
    @Published var nomandFlutedGlassDistortion: Double {
        didSet { UserDefaults.standard.set(nomandFlutedGlassDistortion, forKey: Keys.nomandFlutedGlassDistortion) }
    }

    /// Fluted-glass refraction with the master switch off: the Folia default.
    var effectiveNomandFlutedGlassDistortion: Double {
        foliaEnabled ? nomandFlutedGlassDistortion : Self.defaultNomandFlutedGlassDistortion
    }

    /// Fluted-glass blur (0–1).
    @Published var nomandFlutedGlassBlur: Double {
        didSet { UserDefaults.standard.set(nomandFlutedGlassBlur, forKey: Keys.nomandFlutedGlassBlur) }
    }

    /// Fluted-glass blur with the master switch off: the Folia default.
    var effectiveNomandFlutedGlassBlur: Double {
        foliaEnabled ? nomandFlutedGlassBlur : Self.defaultNomandFlutedGlassBlur
    }

    /// Paper-texture (纸张纹理) contrast (0–1).
    @Published var nomandPaperTextureContrast: Double {
        didSet { UserDefaults.standard.set(nomandPaperTextureContrast, forKey: Keys.nomandPaperTextureContrast) }
    }

    /// Paper-texture contrast with the master switch off: the Folia default.
    var effectiveNomandPaperTextureContrast: Double {
        foliaEnabled ? nomandPaperTextureContrast : Self.defaultNomandPaperTextureContrast
    }

    /// Paper-texture grain (0–1).
    @Published var nomandPaperTextureRoughness: Double {
        didSet { UserDefaults.standard.set(nomandPaperTextureRoughness, forKey: Keys.nomandPaperTextureRoughness) }
    }

    /// Paper-texture grain with the master switch off: the Folia default.
    var effectiveNomandPaperTextureRoughness: Double {
        foliaEnabled ? nomandPaperTextureRoughness : Self.defaultNomandPaperTextureRoughness
    }

    /// Paper-texture fibre amount (0–1).
    @Published var nomandPaperTextureFiber: Double {
        didSet { UserDefaults.standard.set(nomandPaperTextureFiber, forKey: Keys.nomandPaperTextureFiber) }
    }

    /// Paper-texture fibre with the master switch off: the Folia default.
    var effectiveNomandPaperTextureFiber: Double {
        foliaEnabled ? nomandPaperTextureFiber : Self.defaultNomandPaperTextureFiber
    }

    /// Halftone-dots: invert the luminance before the dot screen.
    @Published var nomandHalftoneDotsInverted: Bool {
        didSet { UserDefaults.standard.set(nomandHalftoneDotsInverted, forKey: Keys.nomandHalftoneDotsInverted) }
    }

    /// Halftone-dots inversion with the master switch off: the Folia default.
    var effectiveNomandHalftoneDotsInverted: Bool {
        foliaEnabled ? nomandHalftoneDotsInverted : Self.defaultNomandHalftoneDotsInverted
    }

    /// Lens-distortion (镜头畸变) dispersion reach (0–1).
    @Published var nomandLensDistortionSpread: Double {
        didSet { UserDefaults.standard.set(nomandLensDistortionSpread, forKey: Keys.nomandLensDistortionSpread) }
    }

    /// Lens-distortion reach with the master switch off: the Folia default.
    var effectiveNomandLensDistortionSpread: Double {
        foliaEnabled ? nomandLensDistortionSpread : Self.defaultNomandLensDistortionSpread
    }

    /// Lens-distortion centre bulge (+) / pinch (−), −1–1.
    @Published var nomandLensDistortionBulge: Double {
        didSet { UserDefaults.standard.set(nomandLensDistortionBulge, forKey: Keys.nomandLensDistortionBulge) }
    }

    /// Lens-distortion bulge with the master switch off: the Folia default.
    var effectiveNomandLensDistortionBulge: Double {
        foliaEnabled ? nomandLensDistortionBulge : Self.defaultNomandLensDistortionBulge
    }

    /// Lens-distortion chromatic dispersion (0–1).
    @Published var nomandLensDistortionDispersion: Double {
        didSet { UserDefaults.standard.set(nomandLensDistortionDispersion, forKey: Keys.nomandLensDistortionDispersion) }
    }

    /// Lens-distortion dispersion with the master switch off: the Folia default.
    var effectiveNomandLensDistortionDispersion: Double {
        foliaEnabled ? nomandLensDistortionDispersion : Self.defaultNomandLensDistortionDispersion
    }

    // MARK: - Folia common (通用) background

    /// Theme-colour layer opacity (0–1) when the blurred-cover layer is on.
    @Published var commonOpacity: Double {
        didSet { UserDefaults.standard.set(commonOpacity, forKey: Keys.commonOpacity) }
    }

    /// Common opacity with the master switch off: the Folia default.
    var effectiveCommonOpacity: Double {
        foliaEnabled ? commonOpacity : Self.defaultCommonOpacity
    }

    /// Show the blurred-cover fluid layer under the theme colour.
    @Published var commonUseCoverColorBg: Bool {
        didSet { UserDefaults.standard.set(commonUseCoverColorBg, forKey: Keys.commonUseCoverColorBg) }
    }

    /// Cover-colour layer with the master switch off: the Folia default.
    var effectiveCommonUseCoverColorBg: Bool {
        foliaEnabled ? commonUseCoverColorBg : Self.defaultCommonUseCoverColorBg
    }

    /// Hide the radial vignette (stored as its opposite, like Folia's
    /// `disable_visualizer_vignette`).
    @Published var commonDisableVignette: Bool {
        didSet { UserDefaults.standard.set(commonDisableVignette, forKey: Keys.commonDisableVignette) }
    }

    /// Vignette off with the master switch off: the Folia default.
    var effectiveCommonDisableVignette: Bool {
        foliaEnabled ? commonDisableVignette : Self.defaultCommonDisableVignette
    }

    /// Hide the geometric shapes and particles (stored as its opposite,
    /// like Folia's `disable_visualizer_geometric_background`).
    @Published var commonDisableGeometric: Bool {
        didSet { UserDefaults.standard.set(commonDisableGeometric, forKey: Keys.commonDisableGeometric) }
    }

    /// Geometric shapes off with the master switch off: the Folia default.
    var effectiveCommonDisableGeometric: Bool {
        foliaEnabled ? commonDisableGeometric : Self.defaultCommonDisableGeometric
    }

    // MARK: - Folia latent (隐现) background tuning

    /// Latent display layers: pixel / fluid / both (Folia `displayMode`).
    @Published var latentDisplayMode: LatentDisplayMode {
        didSet { UserDefaults.standard.set(latentDisplayMode.rawValue, forKey: Keys.latentDisplayMode) }
    }

    /// Latent display layers with the master switch off: the Folia default.
    var effectiveLatentDisplayMode: LatentDisplayMode {
        foliaEnabled ? latentDisplayMode : Self.defaultLatentDisplayMode
    }

    /// Latent colour source: cover + theme, or cover only.
    @Published var latentColorSource: LatentColorSource {
        didSet { UserDefaults.standard.set(latentColorSource.rawValue, forKey: Keys.latentColorSource) }
    }

    /// Latent colour source with the master switch off: the Folia default.
    var effectiveLatentColorSource: LatentColorSource {
        foliaEnabled ? latentColorSource : Self.defaultLatentColorSource
    }

    /// Animate the latent background only on the player page; elsewhere
    /// (the style-window preview) it stays frozen. Folia's
    /// `dynamicOnlyInPlayer`.
    ///
    /// D1: the settings toggle for this was removed — there is no
    /// non-player latent surface in the app for it to gate (the only other
    /// latent surface is the style-window preview, which has its own
    /// pause button), so the switch could never do anything observable.
    /// The key, default and effective property stay for compatibility.
    @Published var latentDynamicOnlyInPlayer: Bool {
        didSet { UserDefaults.standard.set(latentDynamicOnlyInPlayer, forKey: Keys.latentDynamicOnlyInPlayer) }
    }

    /// Dynamic-only-in-player with the master switch off: the Folia default.
    var effectiveLatentDynamicOnlyInPlayer: Bool {
        foliaEnabled ? latentDynamicOnlyInPlayer : Self.defaultLatentDynamicOnlyInPlayer
    }

    /// Boost the latent speeds on beat onsets (Folia
    /// `enhancedBeatResponse`).
    @Published var latentEnhancedBeatResponse: Bool {
        didSet { UserDefaults.standard.set(latentEnhancedBeatResponse, forKey: Keys.latentEnhancedBeatResponse) }
    }

    /// Enhanced beat response with the master switch off: the Folia default.
    var effectiveLatentEnhancedBeatResponse: Bool {
        foliaEnabled ? latentEnhancedBeatResponse : Self.defaultLatentEnhancedBeatResponse
    }

    /// Pixel (dithering) base speed (0–2).
    @Published var latentDitheringSpeed: Double {
        didSet { UserDefaults.standard.set(latentDitheringSpeed, forKey: Keys.latentDitheringSpeed) }
    }

    /// Pixel base speed with the master switch off: the Folia default.
    var effectiveLatentDitheringSpeed: Double {
        foliaEnabled ? latentDitheringSpeed : Self.defaultLatentDitheringSpeed
    }

    /// Pixel audio max speed (0–2): the speed the audio amount eases toward.
    @Published var latentDitheringAudioSpeed: Double {
        didSet { UserDefaults.standard.set(latentDitheringAudioSpeed, forKey: Keys.latentDitheringAudioSpeed) }
    }

    /// Pixel audio max speed with the master switch off: the Folia default.
    var effectiveLatentDitheringAudioSpeed: Double {
        foliaEnabled ? latentDitheringAudioSpeed : Self.defaultLatentDitheringAudioSpeed
    }

    /// Pixel (dithering) size (0.5–8).
    @Published var latentDitheringSize: Double {
        didSet { UserDefaults.standard.set(latentDitheringSize, forKey: Keys.latentDitheringSize) }
    }

    /// Pixel size with the master switch off: the Folia default.
    var effectiveLatentDitheringSize: Double {
        foliaEnabled ? latentDitheringSize : Self.defaultLatentDitheringSize
    }

    /// Pixel layer opacity (0–1) when the fluid layer is also shown.
    @Published var latentDitheringOpacity: Double {
        didSet { UserDefaults.standard.set(latentDitheringOpacity, forKey: Keys.latentDitheringOpacity) }
    }

    /// Pixel layer opacity with the master switch off: the Folia default.
    var effectiveLatentDitheringOpacity: Double {
        foliaEnabled ? latentDitheringOpacity : Self.defaultLatentDitheringOpacity
    }

    /// Fluid (mesh) base speed (0–2).
    @Published var latentMeshSpeed: Double {
        didSet { UserDefaults.standard.set(latentMeshSpeed, forKey: Keys.latentMeshSpeed) }
    }

    /// Fluid base speed with the master switch off: the Folia default.
    var effectiveLatentMeshSpeed: Double {
        foliaEnabled ? latentMeshSpeed : Self.defaultLatentMeshSpeed
    }

    /// Fluid audio max speed (0–2).
    @Published var latentMeshAudioSpeed: Double {
        didSet { UserDefaults.standard.set(latentMeshAudioSpeed, forKey: Keys.latentMeshAudioSpeed) }
    }

    /// Fluid audio max speed with the master switch off: the Folia default.
    var effectiveLatentMeshAudioSpeed: Double {
        foliaEnabled ? latentMeshAudioSpeed : Self.defaultLatentMeshAudioSpeed
    }

    /// Fluid distortion (0–2).
    @Published var latentMeshDistortion: Double {
        didSet { UserDefaults.standard.set(latentMeshDistortion, forKey: Keys.latentMeshDistortion) }
    }

    /// Fluid distortion with the master switch off: the Folia default.
    var effectiveLatentMeshDistortion: Double {
        foliaEnabled ? latentMeshDistortion : Self.defaultLatentMeshDistortion
    }

    /// Fluid swirl (0–1).
    @Published var latentMeshSwirl: Double {
        didSet { UserDefaults.standard.set(latentMeshSwirl, forKey: Keys.latentMeshSwirl) }
    }

    /// Fluid swirl with the master switch off: the Folia default.
    var effectiveLatentMeshSwirl: Double {
        foliaEnabled ? latentMeshSwirl : Self.defaultLatentMeshSwirl
    }

    /// Readability tint over the latent layers (Folia `overlayEnabled`).
    @Published var latentOverlayEnabled: Bool {
        didSet { UserDefaults.standard.set(latentOverlayEnabled, forKey: Keys.latentOverlayEnabled) }
    }

    /// Readability tint with the master switch off: the Folia default.
    var effectiveLatentOverlayEnabled: Bool {
        foliaEnabled ? latentOverlayEnabled : Self.defaultLatentOverlayEnabled
    }

    /// Readability tint opacity (0–1).
    @Published var latentOverlayOpacity: Double {
        didSet { UserDefaults.standard.set(latentOverlayOpacity, forKey: Keys.latentOverlayOpacity) }
    }

    /// Readability tint opacity with the master switch off: the Folia default.
    var effectiveLatentOverlayOpacity: Double {
        foliaEnabled ? latentOverlayOpacity : Self.defaultLatentOverlayOpacity
    }

    /// The latent tuning as one value, for the renderer. Read from the
    /// `effective*` properties so the master switch and the stored
    /// values stay in one place.
    var latentTuning: LatentTuning {
        LatentTuning(
            displayMode: effectiveLatentDisplayMode,
            colorSource: effectiveLatentColorSource,
            overlayEnabled: effectiveLatentOverlayEnabled,
            overlayOpacity: effectiveLatentOverlayOpacity,
            ditheringSpeed: effectiveLatentDitheringSpeed,
            ditheringAudioSpeed: effectiveLatentDitheringAudioSpeed,
            ditheringSize: effectiveLatentDitheringSize,
            ditheringOpacity: effectiveLatentDitheringOpacity,
            meshSpeed: effectiveLatentMeshSpeed,
            meshAudioSpeed: effectiveLatentMeshAudioSpeed,
            meshDistortion: effectiveLatentMeshDistortion,
            meshSwirl: effectiveLatentMeshSwirl,
            enhancedBeatResponse: effectiveLatentEnhancedBeatResponse
        )
    }

    // MARK: - Folia monet (莫奈) background

    /// Source image for the monet poster: the current cover, or the
    /// uploaded global image.
    @Published var monetBackgroundSource: BackgroundImageSource {
        didSet { UserDefaults.standard.set(monetBackgroundSource.rawValue, forKey: Keys.monetBackgroundSource) }
    }

    /// Monet image source with the master switch off: the Folia default.
    var effectiveMonetBackgroundSource: BackgroundImageSource {
        foliaEnabled ? monetBackgroundSource : Self.defaultMonetBackgroundSource
    }

    /// Monet layout: full-bleed poster, or the picture in a left pane.
    @Published var monetBackgroundLayout: MonetLayout {
        didSet { UserDefaults.standard.set(monetBackgroundLayout.rawValue, forKey: Keys.monetBackgroundLayout) }
    }

    /// Monet layout with the master switch off: the Folia default.
    var effectiveMonetBackgroundLayout: MonetLayout {
        foliaEnabled ? monetBackgroundLayout : Self.defaultMonetBackgroundLayout
    }

    /// Monet bake blur in px (0–60).
    @Published var monetBackgroundBlurPx: Double {
        didSet { UserDefaults.standard.set(monetBackgroundBlurPx, forKey: Keys.monetBackgroundBlurPx) }
    }

    /// Monet blur with the master switch off: the Folia default.
    var effectiveMonetBackgroundBlurPx: Double {
        foliaEnabled ? monetBackgroundBlurPx : Self.defaultMonetBackgroundBlurPx
    }

    /// Monet overlay gradient strength (0–1).
    @Published var monetBackgroundOverlayOpacity: Double {
        didSet { UserDefaults.standard.set(monetBackgroundOverlayOpacity, forKey: Keys.monetBackgroundOverlayOpacity) }
    }

    /// Monet overlay strength with the master switch off: the Folia default.
    var effectiveMonetBackgroundOverlayOpacity: Double {
        foliaEnabled ? monetBackgroundOverlayOpacity : Self.defaultMonetBackgroundOverlayOpacity
    }

    /// Monet desaturation (0–1).
    @Published var monetBackgroundGrayscale: Double {
        didSet { UserDefaults.standard.set(monetBackgroundGrayscale, forKey: Keys.monetBackgroundGrayscale) }
    }

    /// Monet desaturation with the master switch off: the Folia default.
    var effectiveMonetBackgroundGrayscale: Double {
        foliaEnabled ? monetBackgroundGrayscale : Self.defaultMonetBackgroundGrayscale
    }

    /// Monet saturation multiplier (0–2).
    @Published var monetBackgroundSaturation: Double {
        didSet { UserDefaults.standard.set(monetBackgroundSaturation, forKey: Keys.monetBackgroundSaturation) }
    }

    /// Monet saturation with the master switch off: the Folia default.
    var effectiveMonetBackgroundSaturation: Double {
        foliaEnabled ? monetBackgroundSaturation : Self.defaultMonetBackgroundSaturation
    }

    /// Monet duotone wash mix (0–1).
    @Published var monetBackgroundWash: Double {
        didSet { UserDefaults.standard.set(monetBackgroundWash, forKey: Keys.monetBackgroundWash) }
    }

    /// Monet wash mix with the master switch off: the Folia default.
    var effectiveMonetBackgroundWash: Double {
        foliaEnabled ? monetBackgroundWash : Self.defaultMonetBackgroundWash
    }

    /// Monet half-pane image X offset (−40–40).
    @Published var monetBackgroundHalfPaneOffsetX: Double {
        didSet { UserDefaults.standard.set(monetBackgroundHalfPaneOffsetX, forKey: Keys.monetBackgroundHalfPaneOffsetX) }
    }

    /// Monet half-pane offset with the master switch off: the Folia default.
    var effectiveMonetBackgroundHalfPaneOffsetX: Double {
        foliaEnabled ? monetBackgroundHalfPaneOffsetX : Self.defaultMonetBackgroundHalfPaneOffsetX
    }

    /// Monet wash accent source: theme accent, or a custom colour.
    @Published var monetBackgroundWashColorMode: MonetWashColorMode {
        didSet { UserDefaults.standard.set(monetBackgroundWashColorMode.rawValue, forKey: Keys.monetBackgroundWashColorMode) }
    }

    /// Monet wash accent source with the master switch off: the Folia default.
    var effectiveMonetBackgroundWashColorMode: MonetWashColorMode {
        foliaEnabled ? monetBackgroundWashColorMode : Self.defaultMonetBackgroundWashColorMode
    }

    /// Monet custom wash accent, `#rrggbb`.
    @Published var monetBackgroundWashCustomColor: String {
        didSet { UserDefaults.standard.set(monetBackgroundWashCustomColor, forKey: Keys.monetBackgroundWashCustomColor) }
    }

    /// Monet custom wash accent with the master switch off: the Folia default.
    var effectiveMonetBackgroundWashCustomColor: String {
        foliaEnabled ? monetBackgroundWashCustomColor : Self.defaultMonetBackgroundWashCustomColor
    }

    /// Monet slow pan/zoom drift on/off.
    @Published var monetBackgroundDriftEnabled: Bool {
        didSet { UserDefaults.standard.set(monetBackgroundDriftEnabled, forKey: Keys.monetBackgroundDriftEnabled) }
    }

    /// Monet drift on/off with the master switch off: the Folia default.
    var effectiveMonetBackgroundDriftEnabled: Bool {
        foliaEnabled ? monetBackgroundDriftEnabled : Self.defaultMonetBackgroundDriftEnabled
    }

    /// Monet drift amplitude (0–1).
    @Published var monetBackgroundDriftStrength: Double {
        didSet { UserDefaults.standard.set(monetBackgroundDriftStrength, forKey: Keys.monetBackgroundDriftStrength) }
    }

    /// Monet drift amplitude with the master switch off: the Folia default.
    var effectiveMonetBackgroundDriftStrength: Double {
        foliaEnabled ? monetBackgroundDriftStrength : Self.defaultMonetBackgroundDriftStrength
    }

    /// Monet vertical streaks on/off.
    @Published var monetBackgroundStreaksEnabled: Bool {
        didSet { UserDefaults.standard.set(monetBackgroundStreaksEnabled, forKey: Keys.monetBackgroundStreaksEnabled) }
    }

    /// Monet streaks on/off with the master switch off: the Folia default.
    var effectiveMonetBackgroundStreaksEnabled: Bool {
        foliaEnabled ? monetBackgroundStreaksEnabled : Self.defaultMonetBackgroundStreaksEnabled
    }

    /// The monet tuning as one value, for the renderer.
    var monetTuning: MonetTuning {
        MonetTuning(
            layout: effectiveMonetBackgroundLayout,
            blurPx: effectiveMonetBackgroundBlurPx,
            overlayOpacity: effectiveMonetBackgroundOverlayOpacity,
            grayscale: effectiveMonetBackgroundGrayscale,
            saturation: effectiveMonetBackgroundSaturation,
            wash: effectiveMonetBackgroundWash,
            halfPaneOffsetX: effectiveMonetBackgroundHalfPaneOffsetX,
            washColorMode: effectiveMonetBackgroundWashColorMode,
            washCustomColorHex: effectiveMonetBackgroundWashCustomColor,
            driftEnabled: effectiveMonetBackgroundDriftEnabled,
            driftStrength: effectiveMonetBackgroundDriftStrength,
            streaksEnabled: effectiveMonetBackgroundStreaksEnabled
        )
    }

    // MARK: - Folia sora (空) background

    /// Sora: skip the starfield and show only the solid colour.
    @Published var soraBlank: Bool {
        didSet { UserDefaults.standard.set(soraBlank, forKey: Keys.soraBlank) }
    }

    /// Sora blank with the master switch off: the Folia default.
    var effectiveSoraBlank: Bool {
        foliaEnabled ? soraBlank : Self.defaultSoraBlank
    }

    // MARK: - Folia url (嵌入) background

    /// Saved webpages for the url background (Folia's
    /// `url_background_list`), stored as JSON.
    @Published var urlBackgroundList: [UrlBackgroundItem] {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(urlBackgroundList), forKey: Keys.urlBackgroundList)
        }
    }

    /// Saved webpages with the master switch off: none (the url
    /// background falls back to the plain page).
    var effectiveUrlBackgroundList: [UrlBackgroundItem] {
        foliaEnabled ? urlBackgroundList : []
    }

    /// The selected saved webpage id, or nil for none.
    @Published var urlBackgroundSelectedID: String? {
        didSet { Self.setOptionalString(urlBackgroundSelectedID, forKey: Keys.urlBackgroundSelectedID) }
    }

    /// The selected webpage with the master switch off: none.
    var effectiveUrlBackgroundSelectedID: String? {
        foliaEnabled ? urlBackgroundSelectedID : nil
    }

    /// The selected saved webpage, or nil when there is none.
    var selectedUrlBackground: UrlBackgroundItem? {
        effectiveUrlBackgroundList.first(where: { $0.id == effectiveUrlBackgroundSelectedID })
    }

    // MARK: - Uploaded background image (monet + nomand)

    /// File name of the user-uploaded background image under
    /// Application Support, or nil when none is stored. The bytes live in
    /// `VisualizerBackgroundImageStore`, not in UserDefaults.
    @Published var uploadedBackgroundImageName: String? {
        didSet { Self.setOptionalString(uploadedBackgroundImageName, forKey: Keys.uploadedBackgroundImageName) }
    }

    /// The uploaded image with the master switch off: none (the
    /// backgrounds fall back to the cover).
    var effectiveUploadedBackgroundImageName: String? {
        foliaEnabled ? uploadedBackgroundImageName : nil
    }

    // MARK: - Folia lyric-style window (VisPlayground)

    /// Lyric typeface family for the luminous lyrics and the Lattice card.
    @Published var lyricsFontStyle: LyricsFontStyle {
        didSet { UserDefaults.standard.set(lyricsFontStyle.rawValue, forKey: Keys.lyricsFontStyle) }
    }

    /// Lyric font style with the master switch off: the Folia default.
    var effectiveLyricsFontStyle: LyricsFontStyle {
        foliaEnabled ? lyricsFontStyle : Self.defaultLyricsFontStyle
    }

    /// Lyric font-size scale (0.85–1.4), applied to the luminous font-size
    /// formula and to the Lattice card sizes.
    @Published var lyricsFontScale: Double {
        didSet { UserDefaults.standard.set(lyricsFontScale, forKey: Keys.lyricsFontScale) }
    }

    /// Lyric font-size scale with the master switch off: the Folia default.
    var effectiveLyricsFontScale: Double {
        foliaEnabled ? lyricsFontScale : Self.defaultLyricsFontScale
    }

    /// Global lyric timeline offset in milliseconds, ±2000 (Folia B12):
    /// shifts every lyric line/word timestamp for songs whose lyrics
    /// run off-beat. 0 means off. Applied in `loadLyrics`/`applyLyrics`
    /// right after `LyricsParser.parse`.
    @Published var globalLyricTimelineOffsetMs: Int {
        didSet { UserDefaults.standard.set(globalLyricTimelineOffsetMs, forKey: Keys.globalLyricTimelineOffsetMs) }
    }

    /// Offset with the master switch off: 0, the pre-folia behaviour.
    var effectiveGlobalLyricTimelineOffsetMs: Int {
        foliaEnabled ? globalLyricTimelineOffsetMs : 0
    }

    /// Lyric font weight (100–900) when auto weight is off; `nil` means
    /// automatic (the visualizer's own default weight, 700 for luminous).
    @Published var lyricsFontWeight: Double? {
        didSet { Self.setOptionalDouble(lyricsFontWeight, forKey: Keys.lyricsFontWeight) }
    }

    /// Lyric font weight with the master switch off: automatic.
    var effectiveLyricsFontWeight: Double? {
        foliaEnabled ? lyricsFontWeight : nil
    }

    /// Custom lyric font (PostScript name from the system font picker);
    /// `nil` means the selected font style.
    @Published var lyricsCustomFont: String? {
        didSet { Self.setOptionalString(lyricsCustomFont, forKey: Keys.lyricsCustomFont) }
    }

    /// Custom lyric font with the master switch off: none.
    var effectiveLyricsCustomFont: String? {
        foliaEnabled ? lyricsCustomFont : nil
    }

    /// Overall opacity of the visualizer lyrics (0.2–1).
    @Published var visualizerOpacity: Double {
        didSet { UserDefaults.standard.set(visualizerOpacity, forKey: Keys.visualizerOpacity) }
    }

    /// Visualizer opacity with the master switch off: the Folia default.
    var effectiveVisualizerOpacity: Double {
        foliaEnabled ? visualizerOpacity : Self.defaultVisualizerOpacity
    }

    /// Subtitle font-size scale (0.85–1.4).
    @Published var subtitleFontScale: Double {
        didSet { UserDefaults.standard.set(subtitleFontScale, forKey: Keys.subtitleFontScale) }
    }

    /// Subtitle font-size scale with the master switch off: the Folia default.
    var effectiveSubtitleFontScale: Double {
        foliaEnabled ? subtitleFontScale : Self.defaultSubtitleFontScale
    }

    /// Subtitle overlay opacity (0–1): how strongly the translation /
    /// upcoming-line rows read against the background.
    @Published var subtitleOverlayOpacity: Double {
        didSet { UserDefaults.standard.set(subtitleOverlayOpacity, forKey: Keys.subtitleOverlayOpacity) }
    }

    /// Subtitle overlay opacity with the master switch off: the Folia default.
    var effectiveSubtitleOverlayOpacity: Double {
        foliaEnabled ? subtitleOverlayOpacity : Self.defaultSubtitleOverlayOpacity
    }

    /// Blur the upcoming-line preview rows in the subtitle overlay.
    @Published var subtitleUpcomingLyricsBlur: Bool {
        didSet {
            UserDefaults.standard.set(subtitleUpcomingLyricsBlur, forKey: Keys.subtitleUpcomingLyricsBlur)
        }
    }

    /// Upcoming-line blur with the master switch off: the Folia default.
    var effectiveSubtitleUpcomingLyricsBlur: Bool {
        foliaEnabled ? subtitleUpcomingLyricsBlur : Self.defaultSubtitleUpcomingLyricsBlur
    }

    /// Hide the translation row in the subtitle overlay even when the
    /// content mode would show it.
    @Published var hideTranslationSubtitle: Bool {
        didSet { UserDefaults.standard.set(hideTranslationSubtitle, forKey: Keys.hideTranslationSubtitle) }
    }

    /// Hide-translation with the master switch off: the Folia default.
    var effectiveHideTranslationSubtitle: Bool {
        foliaEnabled ? hideTranslationSubtitle : Self.defaultHideTranslationSubtitle
    }

    /// Subtitle typeface follows the lyric font style instead of sans.
    @Published var subtitleFontFollowsLyrics: Bool {
        didSet {
            UserDefaults.standard.set(subtitleFontFollowsLyrics, forKey: Keys.subtitleFontFollowsLyrics)
        }
    }

    /// Subtitle-follows-lyrics with the master switch off: the Folia default.
    var effectiveSubtitleFontFollowsLyrics: Bool {
        foliaEnabled ? subtitleFontFollowsLyrics : Self.defaultSubtitleFontFollowsLyrics
    }

    /// Show the harmony (background-vocal) subtitle row when the lyrics
    /// carry one. The parser does not produce harmony data for real songs,
    /// so this only takes effect in the style window's live preview.
    @Published var subtitleHarmonyEnabled: Bool {
        didSet { UserDefaults.standard.set(subtitleHarmonyEnabled, forKey: Keys.subtitleHarmonyEnabled) }
    }

    /// Harmony subtitles with the master switch off: the Folia default.
    var effectiveSubtitleHarmonyEnabled: Bool {
        foliaEnabled ? subtitleHarmonyEnabled : Self.defaultSubtitleHarmonyEnabled
    }

    /// How many upcoming lines the subtitle overlay shows (0–2).
    @Published var subtitleUpcomingLineCount: Int {
        didSet { UserDefaults.standard.set(subtitleUpcomingLineCount, forKey: Keys.subtitleUpcomingLineCount) }
    }

    /// Upcoming-line count with the master switch off: the Folia default.
    var effectiveSubtitleUpcomingLineCount: Int {
        foliaEnabled ? subtitleUpcomingLineCount : Self.defaultSubtitleUpcomingLineCount
    }

    /// Draw a dim rounded background behind the subtitle overlay, so the
    /// rows read against a busy cover instead of floating on it.
    @Published var subtitleBackgroundEnabled: Bool {
        didSet { UserDefaults.standard.set(subtitleBackgroundEnabled, forKey: Keys.subtitleBackgroundEnabled) }
    }

    /// Subtitle background with the master switch off: the Folia default.
    var effectiveSubtitleBackgroundEnabled: Bool {
        foliaEnabled ? subtitleBackgroundEnabled : Self.defaultSubtitleBackgroundEnabled
    }

    /// Draw a dim rounded background behind the harmony (background-vocal)
    /// subtitle row. The parser does not produce harmony data for real
    /// songs, so this only takes effect in the style window's live preview.
    @Published var subtitleHarmonyBackgroundEnabled: Bool {
        didSet {
            UserDefaults.standard.set(subtitleHarmonyBackgroundEnabled, forKey: Keys.subtitleHarmonyBackgroundEnabled)
        }
    }

    /// Harmony background with the master switch off: the Folia default.
    var effectiveSubtitleHarmonyBackgroundEnabled: Bool {
        foliaEnabled ? subtitleHarmonyBackgroundEnabled : Self.defaultSubtitleHarmonyBackgroundEnabled
    }

    /// Subtitle typeface when it does not follow the lyric font.
    @Published var subtitleFontStyle: LyricsFontStyle {
        didSet { UserDefaults.standard.set(subtitleFontStyle.rawValue, forKey: Keys.subtitleFontStyle) }
    }

    /// Subtitle font style with the master switch off: the Folia default.
    var effectiveSubtitleFontStyle: LyricsFontStyle {
        foliaEnabled ? subtitleFontStyle : Self.defaultSubtitleFontStyle
    }

    /// Subtitle font weight (100–900) when not following the lyric font;
    /// `nil` means automatic (regular).
    @Published var subtitleFontWeight: Double? {
        didSet { Self.setOptionalDouble(subtitleFontWeight, forKey: Keys.subtitleFontWeight) }
    }

    /// Subtitle font weight with the master switch off: automatic.
    var effectiveSubtitleFontWeight: Double? {
        foliaEnabled ? subtitleFontWeight : nil
    }

    /// Custom subtitle font (PostScript name from the system font picker);
    /// `nil` means the selected subtitle font style.
    @Published var subtitleCustomFont: String? {
        didSet { Self.setOptionalString(subtitleCustomFont, forKey: Keys.subtitleCustomFont) }
    }

    /// Custom subtitle font with the master switch off: none.
    var effectiveSubtitleCustomFont: String? {
        foliaEnabled ? subtitleCustomFont : nil
    }

    /// What the subtitle overlay shows, derived from the two pre-existing
    /// lyric settings (Folia's VisPlayground content mode maps onto the
    /// same two toggles): translation ↔ `showLyricsTranslation`, romaji ↔
    /// `lyricsAnnotation == .romaji`. Setting it writes both back, so the
    /// rest of the app's lyric views stay in agreement.
    var subtitleContentMode: SubtitleContentMode {
        get {
            switch (showLyricsTranslation, lyricsAnnotation) {
            case (true, .romaji): return .both
            case (true, _): return .translation
            case (false, .romaji): return .romaji
            case (false, _): return .none
            }
        }
        set {
            switch newValue {
            case .translation:
                showLyricsTranslation = true
                lyricsAnnotation = .off
            case .romaji:
                showLyricsTranslation = false
                lyricsAnnotation = .romaji
            case .both:
                showLyricsTranslation = true
                lyricsAnnotation = .romaji
            case .none:
                showLyricsTranslation = false
                lyricsAnnotation = .off
            }
        }
    }

    /// Reset every Folia luminous / nomand / lyric-style setting to its
    /// Folia default (the style window's "默认" button). The master switch
    /// and the pre-existing Folia settings are untouched.
    func resetLyricStyleSettings() {
        classicWordRotation = Self.defaultClassicWordRotation
        classicBreathingFloat = Self.defaultClassicBreathingFloat
        classicWordSpacing = Self.defaultClassicWordSpacing
        classicAvoidOverlap = Self.defaultClassicAvoidOverlap
        visualizerBackgroundMode = Self.defaultVisualizerBackgroundMode
        nomandEffect = Self.defaultNomandEffect
        nomandHalftoneSize = Self.defaultNomandHalftoneSize
        nomandHalftoneRadius = Self.defaultNomandHalftoneRadius
        nomandHalftoneContrast = Self.defaultNomandHalftoneContrast
        nomandOriginalColors = Self.defaultNomandOriginalColors
        nomandOverlayOpacity = Self.defaultNomandOverlayOpacity
        nomandOverlayEnabled = Self.defaultNomandOverlayEnabled
        nomandImageSource = Self.defaultNomandImageSource
        nomandDitheringType = Self.defaultNomandDitheringType
        nomandDitheringSize = Self.defaultNomandDitheringSize
        nomandDitheringColorSteps = Self.defaultNomandDitheringColorSteps
        nomandDitheringOriginalColors = Self.defaultNomandDitheringOriginalColors
        nomandDitheringInverted = Self.defaultNomandDitheringInverted
        nomandFlutedGlassSize = Self.defaultNomandFlutedGlassSize
        nomandFlutedGlassDistortion = Self.defaultNomandFlutedGlassDistortion
        nomandFlutedGlassBlur = Self.defaultNomandFlutedGlassBlur
        nomandPaperTextureContrast = Self.defaultNomandPaperTextureContrast
        nomandPaperTextureRoughness = Self.defaultNomandPaperTextureRoughness
        nomandPaperTextureFiber = Self.defaultNomandPaperTextureFiber
        nomandHalftoneDotsInverted = Self.defaultNomandHalftoneDotsInverted
        nomandLensDistortionSpread = Self.defaultNomandLensDistortionSpread
        nomandLensDistortionBulge = Self.defaultNomandLensDistortionBulge
        nomandLensDistortionDispersion = Self.defaultNomandLensDistortionDispersion
        latentDisplayMode = Self.defaultLatentDisplayMode
        latentColorSource = Self.defaultLatentColorSource
        latentDynamicOnlyInPlayer = Self.defaultLatentDynamicOnlyInPlayer
        latentEnhancedBeatResponse = Self.defaultLatentEnhancedBeatResponse
        latentDitheringSpeed = Self.defaultLatentDitheringSpeed
        latentDitheringAudioSpeed = Self.defaultLatentDitheringAudioSpeed
        latentDitheringSize = Self.defaultLatentDitheringSize
        latentDitheringOpacity = Self.defaultLatentDitheringOpacity
        latentMeshSpeed = Self.defaultLatentMeshSpeed
        latentMeshAudioSpeed = Self.defaultLatentMeshAudioSpeed
        latentMeshDistortion = Self.defaultLatentMeshDistortion
        latentMeshSwirl = Self.defaultLatentMeshSwirl
        latentOverlayEnabled = Self.defaultLatentOverlayEnabled
        latentOverlayOpacity = Self.defaultLatentOverlayOpacity
        commonOpacity = Self.defaultCommonOpacity
        commonUseCoverColorBg = Self.defaultCommonUseCoverColorBg
        commonDisableVignette = Self.defaultCommonDisableVignette
        commonDisableGeometric = Self.defaultCommonDisableGeometric
        monetBackgroundSource = Self.defaultMonetBackgroundSource
        monetBackgroundLayout = Self.defaultMonetBackgroundLayout
        monetBackgroundBlurPx = Self.defaultMonetBackgroundBlurPx
        monetBackgroundOverlayOpacity = Self.defaultMonetBackgroundOverlayOpacity
        monetBackgroundGrayscale = Self.defaultMonetBackgroundGrayscale
        monetBackgroundSaturation = Self.defaultMonetBackgroundSaturation
        monetBackgroundWash = Self.defaultMonetBackgroundWash
        monetBackgroundHalfPaneOffsetX = Self.defaultMonetBackgroundHalfPaneOffsetX
        monetBackgroundWashColorMode = Self.defaultMonetBackgroundWashColorMode
        monetBackgroundWashCustomColor = Self.defaultMonetBackgroundWashCustomColor
        monetBackgroundDriftEnabled = Self.defaultMonetBackgroundDriftEnabled
        monetBackgroundDriftStrength = Self.defaultMonetBackgroundDriftStrength
        monetBackgroundStreaksEnabled = Self.defaultMonetBackgroundStreaksEnabled
        soraBlank = Self.defaultSoraBlank
        urlBackgroundList = []
        urlBackgroundSelectedID = nil
        // The uploaded image is deliberately NOT cleared by a reset:
        // Folia's per-mode resets leave `monet_background_image` alone,
        // and re-uploading is the only way to get it back.
        lyricsFontStyle = Self.defaultLyricsFontStyle
        lyricsFontScale = Self.defaultLyricsFontScale
        lyricsFontWeight = nil
        globalLyricTimelineOffsetMs = 0
        autoUseBestLyric = true
        preferredLyricSource = .netease
        lyricLineRules = LyricLineRule.defaultRules
        lyricStaffPolicy = .smart
        lyricStaffMinDwellSeconds = LyricFilterSettings.defaultMinDwellSeconds
        lyricStaffAbsorbMode = .off
        lyricStaffPattern = ""
        lyricsCustomFont = nil
        visualizerOpacity = Self.defaultVisualizerOpacity
        subtitleFontScale = Self.defaultSubtitleFontScale
        subtitleOverlayOpacity = Self.defaultSubtitleOverlayOpacity
        subtitleUpcomingLyricsBlur = Self.defaultSubtitleUpcomingLyricsBlur
        hideTranslationSubtitle = Self.defaultHideTranslationSubtitle
        subtitleFontFollowsLyrics = Self.defaultSubtitleFontFollowsLyrics
        subtitleHarmonyEnabled = Self.defaultSubtitleHarmonyEnabled
        subtitleUpcomingLineCount = Self.defaultSubtitleUpcomingLineCount
        subtitleBackgroundEnabled = Self.defaultSubtitleBackgroundEnabled
        subtitleHarmonyBackgroundEnabled = Self.defaultSubtitleHarmonyBackgroundEnabled
        subtitleFontStyle = Self.defaultSubtitleFontStyle
        subtitleFontWeight = nil
        subtitleCustomFont = nil
        subtitleContentMode = .translation
    }

    /// Re-read every setting from UserDefaults into the @Published
    /// properties — the same assignments `init()` performs. Swift
    /// cannot call an instance method before all stored properties
    /// are initialized, so `init()` keeps its own copy of this body;
    /// keep the two in sync when adding a setting (a backup
    /// round-trip test guards the mechanism). Used by settings
    /// restore: after the backup's values are written to
    /// UserDefaults, this makes the running app pick them up
    /// without a restart. Assigning the properties fires their
    /// `didSet`, which writes the same values back — harmless; the
    /// two side-effecting setters (audio-cache limit, macOS auto
    /// update checks) are idempotent for unchanged values.
    func reloadFromUserDefaults() {
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
        homePlatform = defaults.string(forKey: Keys.homePlatform)
            .flatMap(HomePlatform.init) ?? .netease
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
        // Folia luminous (流光) classic tuning.
        classicWordRotation = defaults.object(forKey: Keys.classicWordRotation) as? Bool
            ?? Self.defaultClassicWordRotation
        classicBreathingFloat = Self.clamped(
            defaults.object(forKey: Keys.classicBreathingFloat) as? Double
                ?? Self.defaultClassicBreathingFloat,
            to: Self.classicBreathingFloatRange
        )
        classicWordSpacing = Self.clamped(
            defaults.object(forKey: Keys.classicWordSpacing) as? Double
                ?? Self.defaultClassicWordSpacing,
            to: Self.classicWordSpacingRange
        )
        classicAvoidOverlap = defaults.object(forKey: Keys.classicAvoidOverlap) as? Bool
            ?? Self.defaultClassicAvoidOverlap
        // Folia nomand (漫游) halftone background.
        visualizerBackgroundMode = defaults.string(forKey: Keys.visualizerBackgroundMode)
            .flatMap(VisualizerBackgroundMode.init) ?? Self.defaultVisualizerBackgroundMode
        nomandEffect = defaults.string(forKey: Keys.nomandEffect)
            .flatMap(NomandEffect.init) ?? Self.defaultNomandEffect
        nomandHalftoneSize = Self.clamped(
            defaults.object(forKey: Keys.nomandHalftoneSize) as? Double
                ?? Self.defaultNomandHalftoneSize,
            to: Self.nomandHalftoneSizeRange
        )
        nomandHalftoneRadius = Self.clamped(
            defaults.object(forKey: Keys.nomandHalftoneRadius) as? Double
                ?? Self.defaultNomandHalftoneRadius,
            to: Self.nomandHalftoneRadiusRange
        )
        nomandHalftoneContrast = Self.clamped(
            defaults.object(forKey: Keys.nomandHalftoneContrast) as? Double
                ?? Self.defaultNomandHalftoneContrast,
            to: Self.nomandHalftoneContrastRange
        )
        nomandOriginalColors = defaults.object(forKey: Keys.nomandOriginalColors) as? Bool
            ?? Self.defaultNomandOriginalColors
        nomandOverlayOpacity = Self.clamped(
            defaults.object(forKey: Keys.nomandOverlayOpacity) as? Double
                ?? Self.defaultNomandOverlayOpacity,
            to: Self.nomandOverlayOpacityRange
        )
        nomandOverlayEnabled = defaults.object(forKey: Keys.nomandOverlayEnabled) as? Bool
            ?? Self.defaultNomandOverlayEnabled
        nomandImageSource = defaults.string(forKey: Keys.nomandImageSource)
            .flatMap(BackgroundImageSource.init) ?? Self.defaultNomandImageSource
        nomandDitheringType = defaults.string(forKey: Keys.nomandDitheringType)
            .flatMap(NomandDitheringType.init) ?? Self.defaultNomandDitheringType
        nomandDitheringSize = Self.clamped(
            defaults.object(forKey: Keys.nomandDitheringSize) as? Double
                ?? Self.defaultNomandDitheringSize,
            to: Self.nomandDitheringSizeRange
        )
        nomandDitheringColorSteps = min(
            max(
                defaults.object(forKey: Keys.nomandDitheringColorSteps) as? Int
                    ?? Self.defaultNomandDitheringColorSteps,
                Self.nomandDitheringColorStepsRange.lowerBound
            ),
            Self.nomandDitheringColorStepsRange.upperBound
        )
        nomandDitheringOriginalColors = defaults.object(forKey: Keys.nomandDitheringOriginalColors) as? Bool
            ?? Self.defaultNomandDitheringOriginalColors
        nomandDitheringInverted = defaults.object(forKey: Keys.nomandDitheringInverted) as? Bool
            ?? Self.defaultNomandDitheringInverted
        nomandFlutedGlassSize = Self.clamped(
            defaults.object(forKey: Keys.nomandFlutedGlassSize) as? Double
                ?? Self.defaultNomandFlutedGlassSize,
            to: Self.nomandFlutedGlassSizeRange
        )
        nomandFlutedGlassDistortion = Self.clamped(
            defaults.object(forKey: Keys.nomandFlutedGlassDistortion) as? Double
                ?? Self.defaultNomandFlutedGlassDistortion,
            to: Self.nomandFlutedGlassDistortionRange
        )
        nomandFlutedGlassBlur = Self.clamped(
            defaults.object(forKey: Keys.nomandFlutedGlassBlur) as? Double
                ?? Self.defaultNomandFlutedGlassBlur,
            to: Self.nomandFlutedGlassBlurRange
        )
        nomandPaperTextureContrast = Self.clamped(
            defaults.object(forKey: Keys.nomandPaperTextureContrast) as? Double
                ?? Self.defaultNomandPaperTextureContrast,
            to: Self.nomandPaperTextureContrastRange
        )
        nomandPaperTextureRoughness = Self.clamped(
            defaults.object(forKey: Keys.nomandPaperTextureRoughness) as? Double
                ?? Self.defaultNomandPaperTextureRoughness,
            to: Self.nomandPaperTextureRoughnessRange
        )
        nomandPaperTextureFiber = Self.clamped(
            defaults.object(forKey: Keys.nomandPaperTextureFiber) as? Double
                ?? Self.defaultNomandPaperTextureFiber,
            to: Self.nomandPaperTextureFiberRange
        )
        nomandHalftoneDotsInverted = defaults.object(forKey: Keys.nomandHalftoneDotsInverted) as? Bool
            ?? Self.defaultNomandHalftoneDotsInverted
        nomandLensDistortionSpread = Self.clamped(
            defaults.object(forKey: Keys.nomandLensDistortionSpread) as? Double
                ?? Self.defaultNomandLensDistortionSpread,
            to: Self.nomandLensDistortionSpreadRange
        )
        nomandLensDistortionBulge = Self.clamped(
            defaults.object(forKey: Keys.nomandLensDistortionBulge) as? Double
                ?? Self.defaultNomandLensDistortionBulge,
            to: Self.nomandLensDistortionBulgeRange
        )
        nomandLensDistortionDispersion = Self.clamped(
            defaults.object(forKey: Keys.nomandLensDistortionDispersion) as? Double
                ?? Self.defaultNomandLensDistortionDispersion,
            to: Self.nomandLensDistortionDispersionRange
        )
        // Folia latent (隐现) background tuning.
        latentDisplayMode = defaults.string(forKey: Keys.latentDisplayMode)
            .flatMap(LatentDisplayMode.init) ?? Self.defaultLatentDisplayMode
        latentColorSource = defaults.string(forKey: Keys.latentColorSource)
            .flatMap(LatentColorSource.init) ?? Self.defaultLatentColorSource
        latentDynamicOnlyInPlayer = defaults.object(forKey: Keys.latentDynamicOnlyInPlayer) as? Bool
            ?? Self.defaultLatentDynamicOnlyInPlayer
        latentEnhancedBeatResponse = defaults.object(forKey: Keys.latentEnhancedBeatResponse) as? Bool
            ?? Self.defaultLatentEnhancedBeatResponse
        latentDitheringSpeed = Self.clamped(
            defaults.object(forKey: Keys.latentDitheringSpeed) as? Double
                ?? Self.defaultLatentDitheringSpeed,
            to: Self.latentSpeedRange
        )
        latentDitheringAudioSpeed = Self.clamped(
            defaults.object(forKey: Keys.latentDitheringAudioSpeed) as? Double
                ?? Self.defaultLatentDitheringAudioSpeed,
            to: Self.latentSpeedRange
        )
        latentDitheringSize = Self.clamped(
            defaults.object(forKey: Keys.latentDitheringSize) as? Double
                ?? Self.defaultLatentDitheringSize,
            to: Self.latentDitheringSizeRange
        )
        latentDitheringOpacity = Self.clamped(
            defaults.object(forKey: Keys.latentDitheringOpacity) as? Double
                ?? Self.defaultLatentDitheringOpacity,
            to: Self.latentOpacityRange
        )
        latentMeshSpeed = Self.clamped(
            defaults.object(forKey: Keys.latentMeshSpeed) as? Double
                ?? Self.defaultLatentMeshSpeed,
            to: Self.latentSpeedRange
        )
        latentMeshAudioSpeed = Self.clamped(
            defaults.object(forKey: Keys.latentMeshAudioSpeed) as? Double
                ?? Self.defaultLatentMeshAudioSpeed,
            to: Self.latentSpeedRange
        )
        latentMeshDistortion = Self.clamped(
            defaults.object(forKey: Keys.latentMeshDistortion) as? Double
                ?? Self.defaultLatentMeshDistortion,
            to: Self.latentMeshDistortionRange
        )
        latentMeshSwirl = Self.clamped(
            defaults.object(forKey: Keys.latentMeshSwirl) as? Double
                ?? Self.defaultLatentMeshSwirl,
            to: Self.latentMeshSwirlRange
        )
        latentOverlayEnabled = defaults.object(forKey: Keys.latentOverlayEnabled) as? Bool
            ?? Self.defaultLatentOverlayEnabled
        latentOverlayOpacity = Self.clamped(
            defaults.object(forKey: Keys.latentOverlayOpacity) as? Double
                ?? Self.defaultLatentOverlayOpacity,
            to: Self.latentOpacityRange
        )
        // Folia common (通用) background.
        commonOpacity = Self.clamped(
            defaults.object(forKey: Keys.commonOpacity) as? Double
                ?? Self.defaultCommonOpacity,
            to: Self.commonOpacityRange
        )
        commonUseCoverColorBg = defaults.object(forKey: Keys.commonUseCoverColorBg) as? Bool
            ?? Self.defaultCommonUseCoverColorBg
        commonDisableVignette = defaults.object(forKey: Keys.commonDisableVignette) as? Bool
            ?? Self.defaultCommonDisableVignette
        commonDisableGeometric = defaults.object(forKey: Keys.commonDisableGeometric) as? Bool
            ?? Self.defaultCommonDisableGeometric
        // Folia monet (莫奈) background.
        monetBackgroundSource = defaults.string(forKey: Keys.monetBackgroundSource)
            .flatMap(BackgroundImageSource.init) ?? Self.defaultMonetBackgroundSource
        monetBackgroundLayout = defaults.string(forKey: Keys.monetBackgroundLayout)
            .flatMap(MonetLayout.init) ?? Self.defaultMonetBackgroundLayout
        monetBackgroundBlurPx = Self.clamped(
            defaults.object(forKey: Keys.monetBackgroundBlurPx) as? Double
                ?? Self.defaultMonetBackgroundBlurPx,
            to: Self.monetBackgroundBlurPxRange
        )
        monetBackgroundOverlayOpacity = Self.clamped(
            defaults.object(forKey: Keys.monetBackgroundOverlayOpacity) as? Double
                ?? Self.defaultMonetBackgroundOverlayOpacity,
            to: Self.monetBackgroundOverlayOpacityRange
        )
        monetBackgroundGrayscale = Self.clamped(
            defaults.object(forKey: Keys.monetBackgroundGrayscale) as? Double
                ?? Self.defaultMonetBackgroundGrayscale,
            to: Self.monetBackgroundGrayscaleRange
        )
        monetBackgroundSaturation = Self.clamped(
            defaults.object(forKey: Keys.monetBackgroundSaturation) as? Double
                ?? Self.defaultMonetBackgroundSaturation,
            to: Self.monetBackgroundSaturationRange
        )
        monetBackgroundWash = Self.clamped(
            defaults.object(forKey: Keys.monetBackgroundWash) as? Double
                ?? Self.defaultMonetBackgroundWash,
            to: Self.monetBackgroundWashRange
        )
        monetBackgroundHalfPaneOffsetX = Self.clamped(
            defaults.object(forKey: Keys.monetBackgroundHalfPaneOffsetX) as? Double
                ?? Self.defaultMonetBackgroundHalfPaneOffsetX,
            to: Self.monetBackgroundHalfPaneOffsetXRange
        )
        monetBackgroundWashColorMode = defaults.string(forKey: Keys.monetBackgroundWashColorMode)
            .flatMap(MonetWashColorMode.init) ?? Self.defaultMonetBackgroundWashColorMode
        monetBackgroundWashCustomColor = Self.normalizedHexColor(
            defaults.string(forKey: Keys.monetBackgroundWashCustomColor),
            default: Self.defaultMonetBackgroundWashCustomColor
        )
        monetBackgroundDriftEnabled = defaults.object(forKey: Keys.monetBackgroundDriftEnabled) as? Bool
            ?? Self.defaultMonetBackgroundDriftEnabled
        monetBackgroundDriftStrength = Self.clamped(
            defaults.object(forKey: Keys.monetBackgroundDriftStrength) as? Double
                ?? Self.defaultMonetBackgroundDriftStrength,
            to: Self.monetBackgroundDriftStrengthRange
        )
        monetBackgroundStreaksEnabled = defaults.object(forKey: Keys.monetBackgroundStreaksEnabled) as? Bool
            ?? Self.defaultMonetBackgroundStreaksEnabled
        // Folia sora (空) background.
        soraBlank = defaults.object(forKey: Keys.soraBlank) as? Bool
            ?? Self.defaultSoraBlank
        // Folia url (嵌入) background.
        urlBackgroundList = defaults.data(forKey: Keys.urlBackgroundList)
            .flatMap { try? JSONDecoder().decode([UrlBackgroundItem].self, from: $0) } ?? []
        urlBackgroundSelectedID = defaults.string(forKey: Keys.urlBackgroundSelectedID)
        // Uploaded background image (monet + nomand share it).
        uploadedBackgroundImageName = defaults.string(forKey: Keys.uploadedBackgroundImageName)
        // Folia lyric-style window (VisPlayground).
        lyricsFontStyle = defaults.string(forKey: Keys.lyricsFontStyle)
            .flatMap(LyricsFontStyle.init) ?? Self.defaultLyricsFontStyle
        lyricsFontScale = Self.clamped(
            defaults.object(forKey: Keys.lyricsFontScale) as? Double
                ?? Self.defaultLyricsFontScale,
            to: Self.lyricsFontScaleRange
        )
        globalLyricTimelineOffsetMs = min(max(
            defaults.object(forKey: Keys.globalLyricTimelineOffsetMs) as? Int ?? 0,
            -2000), 2000)
        if let storedWeight = defaults.object(forKey: Keys.lyricsFontWeight) as? Double {
            lyricsFontWeight = Self.clamped(storedWeight, to: Self.lyricsFontWeightRange)
        } else {
            lyricsFontWeight = nil
        }
        lyricsCustomFont = defaults.string(forKey: Keys.lyricsCustomFont)
        visualizerOpacity = Self.clamped(
            defaults.object(forKey: Keys.visualizerOpacity) as? Double
                ?? Self.defaultVisualizerOpacity,
            to: Self.visualizerOpacityRange
        )
        subtitleFontScale = Self.clamped(
            defaults.object(forKey: Keys.subtitleFontScale) as? Double
                ?? Self.defaultSubtitleFontScale,
            to: Self.subtitleFontScaleRange
        )
        subtitleOverlayOpacity = Self.clamped(
            defaults.object(forKey: Keys.subtitleOverlayOpacity) as? Double
                ?? Self.defaultSubtitleOverlayOpacity,
            to: Self.subtitleOverlayOpacityRange
        )
        subtitleUpcomingLyricsBlur = defaults.object(forKey: Keys.subtitleUpcomingLyricsBlur) as? Bool
            ?? Self.defaultSubtitleUpcomingLyricsBlur
        hideTranslationSubtitle = defaults.object(forKey: Keys.hideTranslationSubtitle) as? Bool
            ?? Self.defaultHideTranslationSubtitle
        subtitleFontFollowsLyrics = defaults.object(forKey: Keys.subtitleFontFollowsLyrics) as? Bool
            ?? Self.defaultSubtitleFontFollowsLyrics
        subtitleHarmonyEnabled = defaults.object(forKey: Keys.subtitleHarmonyEnabled) as? Bool
            ?? Self.defaultSubtitleHarmonyEnabled
        subtitleUpcomingLineCount = min(max(
            defaults.object(forKey: Keys.subtitleUpcomingLineCount) as? Int
                ?? Self.defaultSubtitleUpcomingLineCount,
            Self.subtitleUpcomingLineCountRange.lowerBound),
            Self.subtitleUpcomingLineCountRange.upperBound)
        subtitleBackgroundEnabled = defaults.object(forKey: Keys.subtitleBackgroundEnabled) as? Bool
            ?? Self.defaultSubtitleBackgroundEnabled
        subtitleHarmonyBackgroundEnabled = defaults.object(forKey: Keys.subtitleHarmonyBackgroundEnabled) as? Bool
            ?? Self.defaultSubtitleHarmonyBackgroundEnabled
        subtitleFontStyle = defaults.string(forKey: Keys.subtitleFontStyle)
            .flatMap(LyricsFontStyle.init) ?? Self.defaultSubtitleFontStyle
        if let storedWeight = defaults.object(forKey: Keys.subtitleFontWeight) as? Double {
            subtitleFontWeight = Self.clamped(storedWeight, to: Self.lyricsFontWeightRange)
        } else {
            subtitleFontWeight = nil
        }
        subtitleCustomFont = defaults.string(forKey: Keys.subtitleCustomFont)
        // Beans settings port (P3b/P3c) keys — mirrors the init() assignments.
        mixWithOtherAudio = defaults.object(forKey: Keys.mixWithOtherAudio) as? Bool ?? false
        autoResumeLastPlayback = defaults.object(forKey: Keys.autoResumeLastPlayback) as? Bool ?? false
        autoHidePlayerChrome = defaults.object(forKey: Keys.autoHidePlayerChrome) as? Bool ?? false
        showThirdPartySourceNotice = defaults.object(forKey: Keys.showThirdPartySourceNotice) as? Bool ?? true
        customAccentHex = defaults.string(forKey: Keys.customAccentHex) ?? ""
        tabLabelsVisible = defaults.object(forKey: Keys.tabLabelsVisible) as? Bool ?? true
        legacyTabBarCornerRadius = Self.clamped(
            defaults.object(forKey: Keys.legacyTabBarCornerRadius) as? Double ?? 32,
            to: Self.legacyTabBarCornerRadiusRange)
        legacyTabBarWidth = Self.clamped(
            defaults.object(forKey: Keys.legacyTabBarWidth) as? Double ?? 420,
            to: Self.legacyTabBarWidthRange)
        legacyTabBarOffsetX = Self.clamped(
            defaults.object(forKey: Keys.legacyTabBarOffsetX) as? Double ?? 0,
            to: Self.legacyTabBarOffsetXRange)
        legacyTabBarOffsetY = Self.clamped(
            defaults.object(forKey: Keys.legacyTabBarOffsetY) as? Double ?? 0,
            to: Self.legacyTabBarOffsetYRange)
        homeWallpaperBlur = min(max(defaults.object(forKey: Keys.homeWallpaperBlur) as? Double ?? 0, 0), 30)
        backgroundSyncAll = defaults.object(forKey: Keys.backgroundSyncAll) as? Bool ?? true
        backgroundHexLight = defaults.string(forKey: Keys.backgroundHexLight) ?? ""
        backgroundHexDark = defaults.string(forKey: Keys.backgroundHexDark) ?? ""
        backgroundImagePathLight = defaults.string(forKey: Keys.backgroundImagePathLight) ?? ""
        backgroundImagePathDark = defaults.string(forKey: Keys.backgroundImagePathDark) ?? ""
        wallpaperPaths = defaults.stringArray(forKey: Keys.wallpaperPaths) ?? []
        // customFontName has no SettingsManager property — FontManager reads
        // Keys.customFontName directly, so there is nothing to reload here.
    }

    #if os(iOS)
    @Published var soundEffectPreset: SoundEffectPreset {
        didSet {
            UserDefaults.standard.set(soundEffectPreset.rawValue, forKey: Keys.soundEffectPreset)
            publishSoundEffectParameters()
        }
    }

    @Published private(set) var customEqualizerGains: [Float] {
        didSet {
            let normalized = EqualizerConfiguration(gains: customEqualizerGains).gains
            guard normalized == customEqualizerGains else {
                customEqualizerGains = normalized
                return
            }
            UserDefaults.standard.set(
                normalized.map(Double.init), forKey: Keys.customEqualizerGains)
            if soundEffectPreset == .custom { publishSoundEffectParameters() }
        }
    }

    var customEqualizerConfiguration: EqualizerConfiguration {
        EqualizerConfiguration(gains: customEqualizerGains)
    }

    var isCustomEqualizerEnabled: Bool {
        soundEffectPreset == .custom
    }

    func selectSoundEffect(_ preset: SoundEffectPreset) {
        soundEffectPreset = preset
    }

    func setCustomEqualizerEnabled(_ isEnabled: Bool) {
        if isEnabled {
            soundEffectPreset = .custom
        } else if soundEffectPreset == .custom {
            soundEffectPreset = .original
        }
    }

    func updateCustomEqualizerGain(at index: Int, to value: Float) {
        guard customEqualizerGains.indices.contains(index) else { return }
        var gains = customEqualizerGains
        gains[index] = min(
            max(value, EqualizerConfiguration.gainRange.lowerBound),
            EqualizerConfiguration.gainRange.upperBound)
        customEqualizerGains = gains
        if soundEffectPreset != .custom { soundEffectPreset = .custom }
    }

    func resetCustomEqualizer() {
        customEqualizerGains = EqualizerConfiguration.flat.gains
        if soundEffectPreset != .custom { soundEffectPreset = .custom }
    }

    private func publishSoundEffectParameters() {
        SoundEffectParameterStore.publish(SoundEffectParameters(
            preset: soundEffectPreset,
            custom: customEqualizerConfiguration))
    }
    #endif

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
        autoUseBestLyric = defaults.object(forKey: Keys.autoUseBestLyric) as? Bool ?? true
        preferredLyricSource = defaults.string(forKey: Keys.preferredLyricSource)
            .flatMap(LyricSource.init) ?? .netease
        lyricLineRules = LyricFilterSettings.decodeRules(from: defaults.string(forKey: Keys.lyricLineRules))
        lyricStaffPolicy = defaults.string(forKey: Keys.lyricStaffPolicy)
            .flatMap(LyricStaffPolicy.init) ?? .smart
        lyricStaffMinDwellSeconds = LyricFilterSettings.clampedDwell(
            defaults.object(forKey: Keys.lyricStaffMinDwellSeconds) as? Double
                ?? LyricFilterSettings.defaultMinDwellSeconds)
        lyricStaffAbsorbMode = defaults.string(forKey: Keys.lyricStaffAbsorbMode)
            .flatMap(LyricStaffAbsorbMode.init) ?? .off
        lyricStaffPattern = defaults.string(forKey: Keys.lyricStaffPattern) ?? ""
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
        homePlatform = defaults.string(forKey: Keys.homePlatform)
            .flatMap(HomePlatform.init) ?? .netease
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
        // Beans `playbackSection` (P3 2/3).
        mixWithOtherAudio = defaults.object(forKey: Keys.mixWithOtherAudio) as? Bool ?? false
        autoResumeLastPlayback = defaults.object(forKey: Keys.autoResumeLastPlayback) as? Bool ?? false
        autoHidePlayerChrome = defaults.object(forKey: Keys.autoHidePlayerChrome) as? Bool ?? false
        showThirdPartySourceNotice = defaults.object(forKey: Keys.showThirdPartySourceNotice) as? Bool ?? true
        // Beans `appearanceSection` (P3 3/3).
        customAccentHex = defaults.string(forKey: Keys.customAccentHex) ?? ""
        tabLabelsVisible = defaults.object(forKey: Keys.tabLabelsVisible) as? Bool ?? true
        legacyTabBarCornerRadius = Self.clamped(
            defaults.object(forKey: Keys.legacyTabBarCornerRadius) as? Double ?? 32,
            to: Self.legacyTabBarCornerRadiusRange)
        legacyTabBarWidth = Self.clamped(
            defaults.object(forKey: Keys.legacyTabBarWidth) as? Double ?? 420,
            to: Self.legacyTabBarWidthRange)
        legacyTabBarOffsetX = Self.clamped(
            defaults.object(forKey: Keys.legacyTabBarOffsetX) as? Double ?? 0,
            to: Self.legacyTabBarOffsetXRange)
        legacyTabBarOffsetY = Self.clamped(
            defaults.object(forKey: Keys.legacyTabBarOffsetY) as? Double ?? 0,
            to: Self.legacyTabBarOffsetYRange)
        homeWallpaperBlur = min(max(defaults.object(forKey: Keys.homeWallpaperBlur) as? Double ?? 0, 0), 30)
        backgroundSyncAll = defaults.object(forKey: Keys.backgroundSyncAll) as? Bool ?? true
        backgroundHexLight = defaults.string(forKey: Keys.backgroundHexLight) ?? ""
        backgroundHexDark = defaults.string(forKey: Keys.backgroundHexDark) ?? ""
        backgroundImagePathLight = defaults.string(forKey: Keys.backgroundImagePathLight) ?? ""
        backgroundImagePathDark = defaults.string(forKey: Keys.backgroundImagePathDark) ?? ""
        wallpaperPaths = defaults.stringArray(forKey: Keys.wallpaperPaths) ?? []
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
        // Folia luminous (流光) classic tuning.
        classicWordRotation = defaults.object(forKey: Keys.classicWordRotation) as? Bool
            ?? Self.defaultClassicWordRotation
        classicBreathingFloat = Self.clamped(
            defaults.object(forKey: Keys.classicBreathingFloat) as? Double
                ?? Self.defaultClassicBreathingFloat,
            to: Self.classicBreathingFloatRange
        )
        classicWordSpacing = Self.clamped(
            defaults.object(forKey: Keys.classicWordSpacing) as? Double
                ?? Self.defaultClassicWordSpacing,
            to: Self.classicWordSpacingRange
        )
        classicAvoidOverlap = defaults.object(forKey: Keys.classicAvoidOverlap) as? Bool
            ?? Self.defaultClassicAvoidOverlap
        // Folia nomand (漫游) halftone background.
        visualizerBackgroundMode = defaults.string(forKey: Keys.visualizerBackgroundMode)
            .flatMap(VisualizerBackgroundMode.init) ?? Self.defaultVisualizerBackgroundMode
        nomandEffect = defaults.string(forKey: Keys.nomandEffect)
            .flatMap(NomandEffect.init) ?? Self.defaultNomandEffect
        nomandHalftoneSize = Self.clamped(
            defaults.object(forKey: Keys.nomandHalftoneSize) as? Double
                ?? Self.defaultNomandHalftoneSize,
            to: Self.nomandHalftoneSizeRange
        )
        nomandHalftoneRadius = Self.clamped(
            defaults.object(forKey: Keys.nomandHalftoneRadius) as? Double
                ?? Self.defaultNomandHalftoneRadius,
            to: Self.nomandHalftoneRadiusRange
        )
        nomandHalftoneContrast = Self.clamped(
            defaults.object(forKey: Keys.nomandHalftoneContrast) as? Double
                ?? Self.defaultNomandHalftoneContrast,
            to: Self.nomandHalftoneContrastRange
        )
        nomandOriginalColors = defaults.object(forKey: Keys.nomandOriginalColors) as? Bool
            ?? Self.defaultNomandOriginalColors
        nomandOverlayOpacity = Self.clamped(
            defaults.object(forKey: Keys.nomandOverlayOpacity) as? Double
                ?? Self.defaultNomandOverlayOpacity,
            to: Self.nomandOverlayOpacityRange
        )
        nomandOverlayEnabled = defaults.object(forKey: Keys.nomandOverlayEnabled) as? Bool
            ?? Self.defaultNomandOverlayEnabled
        nomandImageSource = defaults.string(forKey: Keys.nomandImageSource)
            .flatMap(BackgroundImageSource.init) ?? Self.defaultNomandImageSource
        nomandDitheringType = defaults.string(forKey: Keys.nomandDitheringType)
            .flatMap(NomandDitheringType.init) ?? Self.defaultNomandDitheringType
        nomandDitheringSize = Self.clamped(
            defaults.object(forKey: Keys.nomandDitheringSize) as? Double
                ?? Self.defaultNomandDitheringSize,
            to: Self.nomandDitheringSizeRange
        )
        nomandDitheringColorSteps = min(
            max(
                defaults.object(forKey: Keys.nomandDitheringColorSteps) as? Int
                    ?? Self.defaultNomandDitheringColorSteps,
                Self.nomandDitheringColorStepsRange.lowerBound
            ),
            Self.nomandDitheringColorStepsRange.upperBound
        )
        nomandDitheringOriginalColors = defaults.object(forKey: Keys.nomandDitheringOriginalColors) as? Bool
            ?? Self.defaultNomandDitheringOriginalColors
        nomandDitheringInverted = defaults.object(forKey: Keys.nomandDitheringInverted) as? Bool
            ?? Self.defaultNomandDitheringInverted
        nomandFlutedGlassSize = Self.clamped(
            defaults.object(forKey: Keys.nomandFlutedGlassSize) as? Double
                ?? Self.defaultNomandFlutedGlassSize,
            to: Self.nomandFlutedGlassSizeRange
        )
        nomandFlutedGlassDistortion = Self.clamped(
            defaults.object(forKey: Keys.nomandFlutedGlassDistortion) as? Double
                ?? Self.defaultNomandFlutedGlassDistortion,
            to: Self.nomandFlutedGlassDistortionRange
        )
        nomandFlutedGlassBlur = Self.clamped(
            defaults.object(forKey: Keys.nomandFlutedGlassBlur) as? Double
                ?? Self.defaultNomandFlutedGlassBlur,
            to: Self.nomandFlutedGlassBlurRange
        )
        nomandPaperTextureContrast = Self.clamped(
            defaults.object(forKey: Keys.nomandPaperTextureContrast) as? Double
                ?? Self.defaultNomandPaperTextureContrast,
            to: Self.nomandPaperTextureContrastRange
        )
        nomandPaperTextureRoughness = Self.clamped(
            defaults.object(forKey: Keys.nomandPaperTextureRoughness) as? Double
                ?? Self.defaultNomandPaperTextureRoughness,
            to: Self.nomandPaperTextureRoughnessRange
        )
        nomandPaperTextureFiber = Self.clamped(
            defaults.object(forKey: Keys.nomandPaperTextureFiber) as? Double
                ?? Self.defaultNomandPaperTextureFiber,
            to: Self.nomandPaperTextureFiberRange
        )
        nomandHalftoneDotsInverted = defaults.object(forKey: Keys.nomandHalftoneDotsInverted) as? Bool
            ?? Self.defaultNomandHalftoneDotsInverted
        nomandLensDistortionSpread = Self.clamped(
            defaults.object(forKey: Keys.nomandLensDistortionSpread) as? Double
                ?? Self.defaultNomandLensDistortionSpread,
            to: Self.nomandLensDistortionSpreadRange
        )
        nomandLensDistortionBulge = Self.clamped(
            defaults.object(forKey: Keys.nomandLensDistortionBulge) as? Double
                ?? Self.defaultNomandLensDistortionBulge,
            to: Self.nomandLensDistortionBulgeRange
        )
        nomandLensDistortionDispersion = Self.clamped(
            defaults.object(forKey: Keys.nomandLensDistortionDispersion) as? Double
                ?? Self.defaultNomandLensDistortionDispersion,
            to: Self.nomandLensDistortionDispersionRange
        )
        // Folia latent (隐现) background tuning.
        latentDisplayMode = defaults.string(forKey: Keys.latentDisplayMode)
            .flatMap(LatentDisplayMode.init) ?? Self.defaultLatentDisplayMode
        latentColorSource = defaults.string(forKey: Keys.latentColorSource)
            .flatMap(LatentColorSource.init) ?? Self.defaultLatentColorSource
        latentDynamicOnlyInPlayer = defaults.object(forKey: Keys.latentDynamicOnlyInPlayer) as? Bool
            ?? Self.defaultLatentDynamicOnlyInPlayer
        latentEnhancedBeatResponse = defaults.object(forKey: Keys.latentEnhancedBeatResponse) as? Bool
            ?? Self.defaultLatentEnhancedBeatResponse
        latentDitheringSpeed = Self.clamped(
            defaults.object(forKey: Keys.latentDitheringSpeed) as? Double
                ?? Self.defaultLatentDitheringSpeed,
            to: Self.latentSpeedRange
        )
        latentDitheringAudioSpeed = Self.clamped(
            defaults.object(forKey: Keys.latentDitheringAudioSpeed) as? Double
                ?? Self.defaultLatentDitheringAudioSpeed,
            to: Self.latentSpeedRange
        )
        latentDitheringSize = Self.clamped(
            defaults.object(forKey: Keys.latentDitheringSize) as? Double
                ?? Self.defaultLatentDitheringSize,
            to: Self.latentDitheringSizeRange
        )
        latentDitheringOpacity = Self.clamped(
            defaults.object(forKey: Keys.latentDitheringOpacity) as? Double
                ?? Self.defaultLatentDitheringOpacity,
            to: Self.latentOpacityRange
        )
        latentMeshSpeed = Self.clamped(
            defaults.object(forKey: Keys.latentMeshSpeed) as? Double
                ?? Self.defaultLatentMeshSpeed,
            to: Self.latentSpeedRange
        )
        latentMeshAudioSpeed = Self.clamped(
            defaults.object(forKey: Keys.latentMeshAudioSpeed) as? Double
                ?? Self.defaultLatentMeshAudioSpeed,
            to: Self.latentSpeedRange
        )
        latentMeshDistortion = Self.clamped(
            defaults.object(forKey: Keys.latentMeshDistortion) as? Double
                ?? Self.defaultLatentMeshDistortion,
            to: Self.latentMeshDistortionRange
        )
        latentMeshSwirl = Self.clamped(
            defaults.object(forKey: Keys.latentMeshSwirl) as? Double
                ?? Self.defaultLatentMeshSwirl,
            to: Self.latentMeshSwirlRange
        )
        latentOverlayEnabled = defaults.object(forKey: Keys.latentOverlayEnabled) as? Bool
            ?? Self.defaultLatentOverlayEnabled
        latentOverlayOpacity = Self.clamped(
            defaults.object(forKey: Keys.latentOverlayOpacity) as? Double
                ?? Self.defaultLatentOverlayOpacity,
            to: Self.latentOpacityRange
        )
        // Folia common (通用) background.
        commonOpacity = Self.clamped(
            defaults.object(forKey: Keys.commonOpacity) as? Double
                ?? Self.defaultCommonOpacity,
            to: Self.commonOpacityRange
        )
        commonUseCoverColorBg = defaults.object(forKey: Keys.commonUseCoverColorBg) as? Bool
            ?? Self.defaultCommonUseCoverColorBg
        commonDisableVignette = defaults.object(forKey: Keys.commonDisableVignette) as? Bool
            ?? Self.defaultCommonDisableVignette
        commonDisableGeometric = defaults.object(forKey: Keys.commonDisableGeometric) as? Bool
            ?? Self.defaultCommonDisableGeometric
        // Folia monet (莫奈) background.
        monetBackgroundSource = defaults.string(forKey: Keys.monetBackgroundSource)
            .flatMap(BackgroundImageSource.init) ?? Self.defaultMonetBackgroundSource
        monetBackgroundLayout = defaults.string(forKey: Keys.monetBackgroundLayout)
            .flatMap(MonetLayout.init) ?? Self.defaultMonetBackgroundLayout
        monetBackgroundBlurPx = Self.clamped(
            defaults.object(forKey: Keys.monetBackgroundBlurPx) as? Double
                ?? Self.defaultMonetBackgroundBlurPx,
            to: Self.monetBackgroundBlurPxRange
        )
        monetBackgroundOverlayOpacity = Self.clamped(
            defaults.object(forKey: Keys.monetBackgroundOverlayOpacity) as? Double
                ?? Self.defaultMonetBackgroundOverlayOpacity,
            to: Self.monetBackgroundOverlayOpacityRange
        )
        monetBackgroundGrayscale = Self.clamped(
            defaults.object(forKey: Keys.monetBackgroundGrayscale) as? Double
                ?? Self.defaultMonetBackgroundGrayscale,
            to: Self.monetBackgroundGrayscaleRange
        )
        monetBackgroundSaturation = Self.clamped(
            defaults.object(forKey: Keys.monetBackgroundSaturation) as? Double
                ?? Self.defaultMonetBackgroundSaturation,
            to: Self.monetBackgroundSaturationRange
        )
        monetBackgroundWash = Self.clamped(
            defaults.object(forKey: Keys.monetBackgroundWash) as? Double
                ?? Self.defaultMonetBackgroundWash,
            to: Self.monetBackgroundWashRange
        )
        monetBackgroundHalfPaneOffsetX = Self.clamped(
            defaults.object(forKey: Keys.monetBackgroundHalfPaneOffsetX) as? Double
                ?? Self.defaultMonetBackgroundHalfPaneOffsetX,
            to: Self.monetBackgroundHalfPaneOffsetXRange
        )
        monetBackgroundWashColorMode = defaults.string(forKey: Keys.monetBackgroundWashColorMode)
            .flatMap(MonetWashColorMode.init) ?? Self.defaultMonetBackgroundWashColorMode
        monetBackgroundWashCustomColor = Self.normalizedHexColor(
            defaults.string(forKey: Keys.monetBackgroundWashCustomColor),
            default: Self.defaultMonetBackgroundWashCustomColor
        )
        monetBackgroundDriftEnabled = defaults.object(forKey: Keys.monetBackgroundDriftEnabled) as? Bool
            ?? Self.defaultMonetBackgroundDriftEnabled
        monetBackgroundDriftStrength = Self.clamped(
            defaults.object(forKey: Keys.monetBackgroundDriftStrength) as? Double
                ?? Self.defaultMonetBackgroundDriftStrength,
            to: Self.monetBackgroundDriftStrengthRange
        )
        monetBackgroundStreaksEnabled = defaults.object(forKey: Keys.monetBackgroundStreaksEnabled) as? Bool
            ?? Self.defaultMonetBackgroundStreaksEnabled
        // Folia sora (空) background.
        soraBlank = defaults.object(forKey: Keys.soraBlank) as? Bool
            ?? Self.defaultSoraBlank
        // Folia url (嵌入) background.
        urlBackgroundList = defaults.data(forKey: Keys.urlBackgroundList)
            .flatMap { try? JSONDecoder().decode([UrlBackgroundItem].self, from: $0) } ?? []
        urlBackgroundSelectedID = defaults.string(forKey: Keys.urlBackgroundSelectedID)
        // Uploaded background image (monet + nomand share it).
        uploadedBackgroundImageName = defaults.string(forKey: Keys.uploadedBackgroundImageName)
        // Folia lyric-style window (VisPlayground).
        lyricsFontStyle = defaults.string(forKey: Keys.lyricsFontStyle)
            .flatMap(LyricsFontStyle.init) ?? Self.defaultLyricsFontStyle
        lyricsFontScale = Self.clamped(
            defaults.object(forKey: Keys.lyricsFontScale) as? Double
                ?? Self.defaultLyricsFontScale,
            to: Self.lyricsFontScaleRange
        )
        globalLyricTimelineOffsetMs = min(max(
            defaults.object(forKey: Keys.globalLyricTimelineOffsetMs) as? Int ?? 0,
            -2000), 2000)
        if let storedWeight = defaults.object(forKey: Keys.lyricsFontWeight) as? Double {
            lyricsFontWeight = Self.clamped(storedWeight, to: Self.lyricsFontWeightRange)
        } else {
            lyricsFontWeight = nil
        }
        lyricsCustomFont = defaults.string(forKey: Keys.lyricsCustomFont)
        visualizerOpacity = Self.clamped(
            defaults.object(forKey: Keys.visualizerOpacity) as? Double
                ?? Self.defaultVisualizerOpacity,
            to: Self.visualizerOpacityRange
        )
        subtitleFontScale = Self.clamped(
            defaults.object(forKey: Keys.subtitleFontScale) as? Double
                ?? Self.defaultSubtitleFontScale,
            to: Self.subtitleFontScaleRange
        )
        subtitleOverlayOpacity = Self.clamped(
            defaults.object(forKey: Keys.subtitleOverlayOpacity) as? Double
                ?? Self.defaultSubtitleOverlayOpacity,
            to: Self.subtitleOverlayOpacityRange
        )
        subtitleUpcomingLyricsBlur = defaults.object(forKey: Keys.subtitleUpcomingLyricsBlur) as? Bool
            ?? Self.defaultSubtitleUpcomingLyricsBlur
        hideTranslationSubtitle = defaults.object(forKey: Keys.hideTranslationSubtitle) as? Bool
            ?? Self.defaultHideTranslationSubtitle
        subtitleFontFollowsLyrics = defaults.object(forKey: Keys.subtitleFontFollowsLyrics) as? Bool
            ?? Self.defaultSubtitleFontFollowsLyrics
        subtitleHarmonyEnabled = defaults.object(forKey: Keys.subtitleHarmonyEnabled) as? Bool
            ?? Self.defaultSubtitleHarmonyEnabled
        subtitleUpcomingLineCount = min(max(
            defaults.object(forKey: Keys.subtitleUpcomingLineCount) as? Int
                ?? Self.defaultSubtitleUpcomingLineCount,
            Self.subtitleUpcomingLineCountRange.lowerBound),
            Self.subtitleUpcomingLineCountRange.upperBound)
        subtitleBackgroundEnabled = defaults.object(forKey: Keys.subtitleBackgroundEnabled) as? Bool
            ?? Self.defaultSubtitleBackgroundEnabled
        subtitleHarmonyBackgroundEnabled = defaults.object(forKey: Keys.subtitleHarmonyBackgroundEnabled) as? Bool
            ?? Self.defaultSubtitleHarmonyBackgroundEnabled
        subtitleFontStyle = defaults.string(forKey: Keys.subtitleFontStyle)
            .flatMap(LyricsFontStyle.init) ?? Self.defaultSubtitleFontStyle
        if let storedWeight = defaults.object(forKey: Keys.subtitleFontWeight) as? Double {
            subtitleFontWeight = Self.clamped(storedWeight, to: Self.lyricsFontWeightRange)
        } else {
            subtitleFontWeight = nil
        }
        subtitleCustomFont = defaults.string(forKey: Keys.subtitleCustomFont)
        #if os(iOS)
        soundEffectPreset = SoundEffectPreferences.preset(
            from: defaults, key: Keys.soundEffectPreset)
        customEqualizerGains = SoundEffectPreferences.customConfiguration(
            from: defaults, key: Keys.customEqualizerGains).gains
        publishSoundEffectParameters()
        #endif
    }
}
