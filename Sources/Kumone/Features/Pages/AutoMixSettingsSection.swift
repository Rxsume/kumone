#if os(macOS)
import SwiftUI

struct AutoMixSettingsSection: View {
    @EnvironmentObject private var settings: SettingsManager

    var body: some View {
        Section("AutoMix") {
            Toggle("AutoMix", isOn: $settings.automixEnabled)
            Text("让歌曲丝滑衔接，让听感更流畅")
                .font(.caption)
                .foregroundStyle(.secondary)
            if settings.automixEnabled {
                Toggle("自动过渡", isOn: $settings.automixTransitionsEnabled)
                Picker("过渡模式", selection: $settings.transitionMode) {
                    ForEach(TransitionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                if settings.transitionMode == .crossfade {
                    HStack {
                        Text("最长淡入淡出")
                        Spacer()
                        Text("\(Int(settings.crossfadeMaxSeconds)) 秒")
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $settings.crossfadeMaxSeconds,
                        in: SettingsManager.crossfadeMaxSecondsRange,
                        step: 1
                    )
                    HStack {
                        Text("2 秒")
                        Spacer()
                        Text("12 秒")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Toggle(isOn: $settings.automixOrderEnabled) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("智能顺序")
                        Text("按歌曲契合度排序，会增加网络用量。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("智能顺序")
                .accessibilityHint("按歌曲契合度排序，会增加网络用量。")
                Toggle("响度均衡", isOn: $settings.loudnessCompensationEnabled)
                Picker("响度模式", selection: $settings.replayGainMode) {
                    ForEach(ReplayGainMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                #if arch(arm64)
                StemTransitionSettings()
                #endif
            }
        }
    }
}

/// Only these controls need model state; download progress never reaches the form root.
private struct StemTransitionSettings: View {
    @EnvironmentObject private var settings: SettingsManager
    @ObservedObject private var downloader = StemModelDownloader.shared

    var body: some View {
        Toggle(isOn: Binding(
            get: { settings.automixStemsEnabled && downloader.vocalsInstalled },
            set: { settings.automixStemsEnabled = $0 }
        )) {
            VStack(alignment: .leading, spacing: 4) {
                Text("增强过渡")
                Text("分离人声与伴奏，让衔接更自然。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!downloader.vocalsInstalled)
        .accessibilityLabel("增强过渡")
        .accessibilityHint("分离人声与伴奏，让衔接更自然。")
        StemModelsSettingsSection()
        Text("下载后可用，耗电较高。")
            .font(.caption)
            .foregroundStyle(.secondary)
            // On a single view, so the models are hashed once per appearance.
            .task {
                downloader.refresh()
                await downloader.verifyInstalled()
            }
    }
}
#endif
