import SwiftUI

/// 主题乐园：配色主题预设选择与自定义主题编辑器 (Folia V3/V4/V8)。
///
/// - 预设列表：点选即写 `SettingsManager.themePresetID`。
/// - 自定义编辑：取色器 + 强度滑杆，保存后写
///   `SettingsManager.customThemeJSON`，并把 `themePresetID` 置为 `"custom"`。
/// - 恢复默认：把预设置回 `"default"` 并关闭优先自定义主题；已保存的
///   自定义主题不删除，仍可在预设列表里重新选中。
///
/// 本页只读写设置与做主题编解码；主题如何应用到播放页/主界面由
/// `ThemePreset.resolvedTheme(settings:palette:)` 的调用方决定。
struct ThemeParkView: View {
    @EnvironmentObject private var settings: SettingsManager

    @State private var draftAccent: Color = Theme.accent
    @State private var draftTint: Color = ArtworkColors.fallback.primary
    @State private var draftIntensity: Double = 1
    @State private var savedMessageShown = false

    var body: some View {
        Form {
            Section {
                ForEach(ThemePreset.allPresetIDs, id: \.self) { presetID in
                    presetRow(presetID)
                }
            } header: {
                Text("配色主题预设")
            } footer: {
                Text("歌曲主题自动切换开启时，切歌会跟随封面取色；优先自定义主题开启或选中「自定义」时，改用保存的自定义主题。")
            }

            Section("编辑自定义主题") {
                ColorPicker("强调色", selection: $draftAccent)
                ColorPicker("背景色", selection: $draftTint)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("背景色强度")
                        Spacer()
                        Text("\(Int(draftIntensity * 100))%")
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $draftIntensity,
                        in: SettingsManager.mainWindowAmbientBackgroundIntensityRange,
                        step: 0.1
                    )
                    HStack {
                        Text("50%")
                        Spacer()
                        Text("150%")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Toggle("优先使用自定义主题", isOn: $settings.preferCustomTheme)
                Text("开启后，保存的自定义主题优先于歌曲封面取色与所选预设。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                previewRow
            }

            Section {
                Button("保存为自定义预设") {
                    saveCustomTheme()
                }

                Button("恢复默认", role: .destructive) {
                    restoreDefaults()
                }
            } footer: {
                if savedMessageShown {
                    Text("已保存为自定义主题。")
                }
            }
        }
        .navigationTitle("主题乐园")
        .onAppear {
            syncDraftFromSelection()
        }
        .onChange(of: settings.themePresetID) { _ in
            syncDraftFromSelection()
        }
    }

    // MARK: - Preset list

    private func presetRow(_ presetID: String) -> some View {
        let preset = ThemePreset.preset(id: presetID)
        let isSelected = settings.themePresetID == presetID
        let savedCustom = ThemePreset.customTheme(from: settings)
        let accentColor = presetID == "custom" ? (savedCustom?.accent.color ?? preset.accent.color) : preset.accent.color
        let tintColor = presetID == "custom" ? (savedCustom?.tint.color ?? preset.tint.color) : preset.tint.color
        return Button {
            settings.themePresetID = presetID
        } label: {
            HStack(spacing: 12) {
                HStack(spacing: -6) {
                    Circle()
                        .fill(accentColor)
                        .frame(width: 24, height: 24)
                    Circle()
                        .fill(tintColor)
                        .frame(width: 24, height: 24)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.displayName)
                        .foregroundStyle(.primary)
                    if presetID == "custom" && savedCustom == nil {
                        Text("尚未保存自定义主题")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Preview

    private var previewRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("预览")
                .font(.caption)
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                LinearGradient(
                    colors: [draftTint, draftAccent.opacity(0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                HStack(spacing: 8) {
                    Circle()
                        .fill(draftAccent)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("正在播放的歌曲")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Text("强调色与背景色预览")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
            }
            .frame(height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Actions

    /// Loads the editor draft from the current selection: the saved custom
    /// theme when `"custom"` is selected (or one exists), otherwise the
    /// selected built-in preset.
    private func syncDraftFromSelection() {
        if settings.themePresetID == "custom",
           let custom = ThemePreset.customTheme(from: settings) {
            draftAccent = custom.accent.color
            draftTint = custom.tint.color
            draftIntensity = custom.intensity
            return
        }
        let preset = ThemePreset.preset(id: settings.themePresetID)
        draftAccent = preset.accent.color
        draftTint = preset.tint.color
        draftIntensity = preset.intensity
    }

    private func saveCustomTheme() {
        let theme = ThemePreset(
            id: "custom",
            accent: ThemeColor(draftAccent),
            tint: ThemeColor(draftTint),
            intensity: draftIntensity
        )
        guard let json = theme.encodeToJSON() else { return }
        settings.customThemeJSON = json
        settings.themePresetID = "custom"
        savedMessageShown = true
        ToastCenter.shared.show(String(localized: "已保存为自定义主题"))
    }

    /// Back to the default preset; the saved custom theme is kept so it can
    /// be re-selected from the preset list.
    private func restoreDefaults() {
        settings.themePresetID = "default"
        settings.preferCustomTheme = false
        draftAccent = ThemePreset.defaultPreset.accent.color
        draftTint = ThemePreset.defaultPreset.tint.color
        draftIntensity = ThemePreset.defaultPreset.intensity
        savedMessageShown = false
    }
}
