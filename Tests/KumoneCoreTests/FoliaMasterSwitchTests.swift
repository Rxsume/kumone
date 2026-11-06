import Testing
@testable import KumoneCore
import Foundation

/// Coverage for the Folia master switch (`SettingsManager.foliaEnabled`):
/// with the switch on, every `effective*` property returns the stored
/// value; with it off, every one returns the pre-folia behaviour (what the
/// app did at bb21dd8, before PR #8). Pure logic — no UI.
///
/// The tests mutate the shared `SettingsManager` (and its `UserDefaults`
/// backing store), so the suite is serial and every test restores the
/// values it found on entry.
@Suite(.serialized)
@MainActor
struct FoliaMasterSwitchTests {

    // MARK: - Snapshot / restore

    /// Every folia stored value plus the master switch, as found on entry.
    /// `@MainActor` because `take()` / `restore()` touch
    /// `SettingsManager.shared`, which is MainActor-isolated (a nested type
    /// does not inherit the outer suite's isolation).
    @MainActor
    private struct Snapshot {
        var foliaEnabled: Bool
        var lyricAnimationStyle: LyricAnimationStyle
        var themePresetID: String
        var customThemeJSON: String
        var preferCustomTheme: Bool
        var songThemeAutoSwitch: Bool
        var homeDynamicBackground: Bool
        var playerPageNativeBlur: Bool
        var staticMode: Bool
        var reduceMotionBackground: Bool?
        var reduceMotionTransitions: Bool?
        var reduceMotionMicroMotion: Bool?
        var playbackFadeEnabled: Bool
        var queueAddBehavior: QueueAddBehavior
        var autoSkipUnplayable: Bool
        var playbackEntryView: PlaybackEntryView
        var playerPageTintIntensity: Double
        var hidePlayerProgressBar: Bool
        var alwaysShowPlayerBackButton: Bool
        var alwaysShowTrackSwitchButtons: Bool
        var playerControlSlots: [String]
        var stageTrackCardEnabled: Bool
        var transitionAnimationRing: Bool
        var transitionAnimationCard: Bool
        var transitionMode: TransitionMode
        var crossfadeMaxSeconds: Double
        var replayGainMode: ReplayGainMode
        #if os(iOS)
        // Defaults so `take()` can build the snapshot without the iOS-only
        // fields in the argument list (`#if` cannot split a call's
        // arguments) and assign them right after instead.
        var preventDisplaySleepDuringPlayback: Bool = false
        var iosCrossfadeEnabled: Bool = false
        #endif

        static func take() -> Snapshot {
            let s = SettingsManager.shared
            var snap = Snapshot(
                foliaEnabled: s.foliaEnabled,
                lyricAnimationStyle: s.lyricAnimationStyle,
                themePresetID: s.themePresetID,
                customThemeJSON: s.customThemeJSON,
                preferCustomTheme: s.preferCustomTheme,
                songThemeAutoSwitch: s.songThemeAutoSwitch,
                homeDynamicBackground: s.homeDynamicBackground,
                playerPageNativeBlur: s.playerPageNativeBlur,
                staticMode: s.staticMode,
                reduceMotionBackground: s.reduceMotionBackground,
                reduceMotionTransitions: s.reduceMotionTransitions,
                reduceMotionMicroMotion: s.reduceMotionMicroMotion,
                playbackFadeEnabled: s.playbackFadeEnabled,
                queueAddBehavior: s.queueAddBehavior,
                autoSkipUnplayable: s.autoSkipUnplayable,
                playbackEntryView: s.playbackEntryView,
                playerPageTintIntensity: s.playerPageTintIntensity,
                hidePlayerProgressBar: s.hidePlayerProgressBar,
                alwaysShowPlayerBackButton: s.alwaysShowPlayerBackButton,
                alwaysShowTrackSwitchButtons: s.alwaysShowTrackSwitchButtons,
                playerControlSlots: s.playerControlSlots,
                stageTrackCardEnabled: s.stageTrackCardEnabled,
                transitionAnimationRing: s.transitionAnimationRing,
                transitionAnimationCard: s.transitionAnimationCard,
                transitionMode: s.transitionMode,
                crossfadeMaxSeconds: s.crossfadeMaxSeconds,
                replayGainMode: s.replayGainMode
            )
            #if os(iOS)
            snap.preventDisplaySleepDuringPlayback = s.preventDisplaySleepDuringPlayback
            snap.iosCrossfadeEnabled = s.iosCrossfadeEnabled
            #endif
            return snap
        }

        func restore() {
            let s = SettingsManager.shared
            s.foliaEnabled = foliaEnabled
            s.lyricAnimationStyle = lyricAnimationStyle
            s.themePresetID = themePresetID
            s.customThemeJSON = customThemeJSON
            s.preferCustomTheme = preferCustomTheme
            s.songThemeAutoSwitch = songThemeAutoSwitch
            s.homeDynamicBackground = homeDynamicBackground
            s.playerPageNativeBlur = playerPageNativeBlur
            s.staticMode = staticMode
            s.reduceMotionBackground = reduceMotionBackground
            s.reduceMotionTransitions = reduceMotionTransitions
            s.reduceMotionMicroMotion = reduceMotionMicroMotion
            s.playbackFadeEnabled = playbackFadeEnabled
            s.queueAddBehavior = queueAddBehavior
            s.autoSkipUnplayable = autoSkipUnplayable
            s.playbackEntryView = playbackEntryView
            s.playerPageTintIntensity = playerPageTintIntensity
            s.hidePlayerProgressBar = hidePlayerProgressBar
            s.alwaysShowPlayerBackButton = alwaysShowPlayerBackButton
            s.alwaysShowTrackSwitchButtons = alwaysShowTrackSwitchButtons
            s.playerControlSlots = playerControlSlots
            s.stageTrackCardEnabled = stageTrackCardEnabled
            s.transitionAnimationRing = transitionAnimationRing
            s.transitionAnimationCard = transitionAnimationCard
            s.transitionMode = transitionMode
            s.crossfadeMaxSeconds = crossfadeMaxSeconds
            s.replayGainMode = replayGainMode
            #if os(iOS)
            s.preventDisplaySleepDuringPlayback = preventDisplaySleepDuringPlayback
            s.iosCrossfadeEnabled = iosCrossfadeEnabled
            #endif
        }
    }

    /// Stored values that differ from the shipped defaults, so "effective
    /// == stored" is a real check rather than a coincidence. With
    /// `provingOff`, the three values whose shipped default already equals
    /// their pre-folia value are flipped to the other side, so "effective
    /// == pre-folia default" proves the override instead of a passthrough.
    private func applyStoredValues(provingOff: Bool) {
        let s = SettingsManager.shared
        s.lyricAnimationStyle = .karaokeZoom
        s.themePresetID = "ocean"
        let custom = ThemePreset(
            id: "custom",
            accent: ThemeColor(red: 1, green: 0, blue: 0),
            tint: ThemeColor(red: 0, green: 0, blue: 1)
        )
        s.customThemeJSON = custom.encodeToJSON() ?? ""
        s.preferCustomTheme = true
        s.songThemeAutoSwitch = false
        s.homeDynamicBackground = false
        s.playerPageNativeBlur = false
        s.staticMode = true
        s.playbackFadeEnabled = provingOff ? true : false
        s.queueAddBehavior = .append
        s.autoSkipUnplayable = provingOff ? true : false
        s.playbackEntryView = .nowPlaying
        s.playerPageTintIntensity = 0.5
        s.hidePlayerProgressBar = true
        s.alwaysShowPlayerBackButton = true
        s.alwaysShowTrackSwitchButtons = true
        s.playerControlSlots = ["playPause"]
        s.stageTrackCardEnabled = true
        s.transitionAnimationRing = true
        s.transitionAnimationCard = true
        s.transitionMode = .crossfade
        s.crossfadeMaxSeconds = 12
        s.replayGainMode = .track
        #if os(iOS)
        s.preventDisplaySleepDuringPlayback = provingOff ? true : false
        s.iosCrossfadeEnabled = true
        #endif
    }

    // MARK: - Master on: effective == stored

    @Test func masterOnReturnsStoredValues() {
        let saved = Snapshot.take()
        defer { saved.restore() }
        let s = SettingsManager.shared
        applyStoredValues(provingOff: false)
        s.reduceMotionBackground = true
        s.reduceMotionTransitions = false
        s.reduceMotionMicroMotion = true
        s.foliaEnabled = true

        #expect(s.effectiveLyricAnimationStyle == .karaokeZoom)
        #expect(s.effectiveThemePresetID == "ocean")
        #expect(!s.effectiveCustomThemeJSON.isEmpty)
        #expect(s.effectivePreferCustomTheme == true)
        #expect(s.effectiveSongThemeAutoSwitch == false)
        #expect(s.effectiveHomeDynamicBackground == false)
        #expect(s.effectivePlayerPageNativeBlur == false)
        #expect(s.effectiveStaticMode == true)
        #expect(s.effectiveReduceMotionBackground == true)
        #expect(s.effectiveReduceMotionTransitions == false)
        #expect(s.effectiveReduceMotionMicroMotion == true)
        #expect(s.effectivePlaybackFadeEnabled == false)
        #expect(s.effectiveQueueAddBehavior == .append)
        #expect(s.effectiveAutoSkipUnplayable == false)
        #expect(s.effectivePlaybackEntryView == .nowPlaying)
        #expect(s.effectivePlayerPageTintIntensity == 0.5)
        #expect(s.effectiveHidePlayerProgressBar == true)
        #expect(s.effectiveAlwaysShowPlayerBackButton == true)
        #expect(s.effectiveAlwaysShowTrackSwitchButtons == true)
        #expect(s.effectivePlayerControlSlots == ["playPause"])
        #expect(s.effectiveStageTrackCardEnabled == true)
        #expect(s.effectiveTransitionAnimationRing == true)
        #expect(s.effectiveTransitionAnimationCard == true)
        #expect(s.effectiveTransitionMode == .crossfade)
        #expect(s.effectiveCrossfadeMaxSeconds == 12)
        #expect(s.effectiveReplayGainMode == .track)
        #if os(iOS)
        #expect(s.effectivePreventDisplaySleepDuringPlayback == false)
        #expect(s.effectiveIosCrossfadeEnabled == true)
        #endif
    }

    // MARK: - Master off: effective == pre-folia defaults (bb21dd8)

    @Test func masterOffReturnsPreFoliaDefaults() {
        let saved = Snapshot.take()
        defer { saved.restore() }
        let s = SettingsManager.shared
        applyStoredValues(provingOff: true)
        // Overrides deliberately set to the opposite of the system value,
        // so falling back to the system proves they are inert.
        let system = Platform.isReduceMotionEnabled
        s.reduceMotionBackground = !system
        s.reduceMotionTransitions = !system
        s.reduceMotionMicroMotion = !system
        s.foliaEnabled = false

        #expect(s.effectiveLyricAnimationStyle == .fade)
        #expect(s.effectiveThemePresetID == "default")
        #expect(s.effectiveCustomThemeJSON == "")
        #expect(s.effectivePreferCustomTheme == false)
        #expect(s.effectiveSongThemeAutoSwitch == true)
        #expect(s.effectiveHomeDynamicBackground == true)
        #expect(s.effectivePlayerPageNativeBlur == true)
        #expect(s.effectiveStaticMode == false)
        #expect(s.effectiveReduceMotionBackground == system)
        #expect(s.effectiveReduceMotionTransitions == system)
        #expect(s.effectiveReduceMotionMicroMotion == system)
        #expect(s.effectivePlaybackFadeEnabled == false)
        #expect(s.effectiveQueueAddBehavior == .next)
        #expect(s.effectiveAutoSkipUnplayable == false)
        #expect(s.effectivePlaybackEntryView == .stay)
        #expect(s.effectivePlayerPageTintIntensity == 1)
        #expect(s.effectiveHidePlayerProgressBar == false)
        #expect(s.effectiveAlwaysShowPlayerBackButton == false)
        #expect(s.effectiveAlwaysShowTrackSwitchButtons == false)
        #expect(s.effectivePlayerControlSlots == PlayerControlSlot.allCases.map(\.rawValue))
        #expect(s.effectiveStageTrackCardEnabled == false)
        #expect(s.effectiveTransitionAnimationRing == false)
        #expect(s.effectiveTransitionAnimationCard == false)
        #expect(s.effectiveTransitionMode == .automix)
        #expect(s.effectiveCrossfadeMaxSeconds == 6)
        #if os(iOS)
        #expect(s.effectiveReplayGainMode == .off)
        #expect(s.effectivePreventDisplaySleepDuringPlayback == false)
        #expect(s.effectiveIosCrossfadeEnabled == false)
        #else
        #expect(s.effectiveReplayGainMode == .auto)
        #endif
    }

    // MARK: - Master switch drives the theme path end to end

    @Test func resolvedThemeFollowsMasterSwitch() {
        let saved = Snapshot.take()
        defer { saved.restore() }
        let s = SettingsManager.shared
        let custom = ThemePreset(
            id: "custom",
            accent: ThemeColor(red: 1, green: 0, blue: 0),
            tint: ThemeColor(red: 0, green: 0, blue: 1)
        )
        s.customThemeJSON = custom.encodeToJSON() ?? ""
        s.preferCustomTheme = true
        s.themePresetID = "ocean"
        s.songThemeAutoSwitch = false

        s.foliaEnabled = true
        #expect(ThemePreset.resolvedTheme(settings: s, palette: nil).source == .custom)
        s.foliaEnabled = false
        #expect(ThemePreset.resolvedTheme(settings: s, palette: nil).source == .preset("default"))

        s.preferCustomTheme = false
        s.customThemeJSON = ""
        s.foliaEnabled = true
        #expect(ThemePreset.resolvedTheme(settings: s, palette: nil).source == .preset("ocean"))
        s.foliaEnabled = false
        #expect(ThemePreset.resolvedTheme(settings: s, palette: nil).source == .preset("default"))
    }

    // MARK: - Master switch persists

    @Test func masterSwitchPersistsInUserDefaults() {
        let saved = Snapshot.take()
        defer { saved.restore() }
        let s = SettingsManager.shared
        s.foliaEnabled = false
        #expect(UserDefaults.standard.bool(forKey: "settings.foliaEnabled") == false)
        s.foliaEnabled = true
        #expect(UserDefaults.standard.bool(forKey: "settings.foliaEnabled") == true)
    }
}
