import AVFoundation
import Foundation

#if os(iOS)
/// (Re-)applies the audio session category with the current mix
/// preference (Beans `playbackSection`: 与其他音频同时播放).
///
/// Lives here — not in `PlaybackEngine` — because that file is
/// macOS-only (the whole file sits inside `#if os(macOS)`), so an
/// `#if os(iOS)` method inside it can never compile on either
/// platform; the P3b version of this method was dead code there.
/// Reads the raw default instead of `SettingsManager.shared`:
/// the callers include @MainActor contexts and engine start, and
/// this helper must not touch @MainActor state. Called on engine
/// start and whenever the setting changes.
enum AudioSessionCategory {
    static func apply() {
        let mix = UserDefaults.standard.bool(forKey: SettingsManager.Keys.mixWithOtherAudio)
        let options: AVAudioSession.CategoryOptions = mix ? [.mixWithOthers] : []
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio, options: options)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}
#endif
