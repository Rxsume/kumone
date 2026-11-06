// Sources/Kumone/Features/Pages/LyricStyleSettingsView.swift
//
// Folia lyrics-style window (VisPlayground), re-implemented in Swift.
//
// Folia's VisPlayground (`components/ponder/surfaces/studio/
// visPlayground.surface.tsx`) is a settings window with a live preview
// that runs the real visualizer renderer over built-in sample lyrics
// (`PreviewPlaceholder.ts`: two sets — 神文之诗, 14.4s loop, and 野芝麻,
// 13.6s loop — each line with per-word timings, translation and
// romanization, plus a background-vocal harmony line), and four tabs:
// 通用 / 背景 / 歌词动画 / 字幕.
//
// The preview here runs the real `LuminousLyricsView` (not a second
// renderer) over the same two sample sets, driven by a `TimelineView`
// clock that loops over the sample duration. The harmony row is the one
// thing the live view cannot render — `LyricLine` has no background-vocal
// field, the parser never produces one — so the preview card draws it as
// an extra subtitle row, only while the harmony is active and the
// harmony switch is on.

import SwiftUI

#if os(iOS)
import UIKit
#endif

// MARK: - Preview samples (Folia `PreviewPlaceholder.ts`, copied verbatim)

/// A harmony (background-vocal) row of a sample line. `LyricLine` has no
/// background-vocal field, so the sample sets carry it alongside the line.
struct LyricStyleHarmony: Hashable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var words: [LyricWord]
    var translation: String?
    var romanization: String?
}

/// One sample line plus its optional harmony row.
struct LyricStylePreviewLine: Hashable {
    var line: LyricLine
    var harmony: LyricStyleHarmony?
}

/// One built-in sample set: four lines looping over `loopDuration`.
struct LyricStylePreviewSample: Hashable {
    var id: String
    var title: String
    var lines: [LyricStylePreviewLine]
    var loopDuration: TimeInterval

    /// The loop position for an elapsed time: `elapsed` modulo the loop
    /// duration, so the clock wraps back to 0 when the set ends (14.4s
    /// for 神文之诗, 13.6s for 野芝麻).
    func loopTime(for elapsed: TimeInterval) -> TimeInterval {
        let mod = elapsed.truncatingRemainder(dividingBy: loopDuration)
        return mod < 0 ? mod + loopDuration : mod
    }

    /// The active line at `time`, scanning from the end like Folia's
    /// `findPreviewPlaceholderLineIndex`: a line counts while the clock
    /// is inside its window (start...end).
    func activeLineIndex(at time: TimeInterval) -> Int? {
        for index in lines.indices.reversed() {
            let line = lines[index].line
            if time >= line.time, time <= line.end { return index }
        }
        return nil
    }

    /// The two lines after `index`, for the subtitle overlay's upcoming
    /// rows.
    func upcomingLines(after index: Int) -> [LyricLine] {
        lines.dropFirst(index + 1).prefix(2).map(\.line)
    }
}

enum LyricStylePreviewSamples {
    static let `default` = LyricStylePreviewSample(
        id: "default",
        title: "神文之诗",
        lines: [
            LyricStylePreviewLine(
                line: LyricLine(
                    id: 0, time: 0.7, end: 3.6,
                    text: "詩情を持たずとも、あなたを現実へと導くその神文の詩を紡ぐ。",
                    translation: "编织那没有诗意，却能将你带到现实的神文之诗。",
                    romaji: "Shijō o motazu tomo, anata o genjitsu e to michibiku sono shinbun no shi o tsumugu.",
                    furigana: nil,
                    words: characterWords("詩情を持たずとも、あなたを現実へと導くその神文の詩を紡ぐ。", start: 0.7, end: 3.6)
                ),
                harmony: LyricStyleHarmony(
                    text: "of course i still love you", start: 1.3, end: 3.1,
                    words: tokenWords(["of", "course", "i", "still", "love", "you"], start: 1.3, end: 3.1),
                    translation: "当然，我依然爱你。",
                    romanization: "of course i still love you"
                )
            ),
            LyricStylePreviewLine(
                line: LyricLine(
                    id: 1, time: 4.2, end: 7.2,
                    text: "Weave that prosaic divine poem that leads you to reality.",
                    translation: "编织那没有诗意，却能将你带到现实的神文之诗。",
                    romaji: "Weave that prosaic divine poem that leads you to reality.",
                    furigana: nil,
                    words: tokenWords(["Weave", "that", "prosaic", "divine", "poem", "that", "leads", "you", "to", "reality."], start: 4.2, end: 7.2)
                ),
                harmony: LyricStyleHarmony(
                    text: "もちろん、今でもあなたを愛してるよ", start: 4.8, end: 6.6,
                    words: characterWords("もちろん、今でもあなたを愛してるよ", start: 4.8, end: 6.6),
                    translation: "当然，我依然爱你。",
                    romanization: "Mochiron, ima demo anata o aishiteru yo."
                )
            ),
            LyricStylePreviewLine(
                line: LyricLine(
                    id: 2, time: 7.8, end: 10.9,
                    text: "Tisse ce poème divin sans poésie qui te mène au réel.",
                    translation: "编织那没有诗意，却能将你带到现实的神文之诗。",
                    romaji: "Tisse ce poème divin sans poésie qui te mène au réel.",
                    furigana: nil,
                    words: tokenWords(["Tisse", "ce", "poème", "divin", "sans", "poésie", "qui", "te", "mène", "au", "réel."], start: 7.8, end: 10.9)
                ),
                harmony: LyricStyleHarmony(
                    text: "もちろん、今でもあなたを愛してるよ", start: 8.4, end: 10.2,
                    words: characterWords("もちろん、今でもあなたを愛してるよ", start: 8.4, end: 10.2),
                    translation: "当然，我依然爱你。",
                    romanization: "Mochiron, ima demo anata o aishiteru yo."
                )
            ),
            LyricStylePreviewLine(
                line: LyricLine(
                    id: 3, time: 11.5, end: 14.4,
                    text: "编织那没有诗意，却能将你带到现实的神文之诗。",
                    translation: "编织那没有诗意，却能将你带到现实的神文之诗。",
                    romaji: "Biānzhī nà méiyǒu shīyì, què néng jiāng nǐ dài dào xiànshí de shénwén zhī shī.",
                    furigana: nil,
                    words: characterWords("编织那没有诗意，却能将你带到现实的神文之诗。", start: 11.5, end: 14.4)
                ),
                harmony: nil
            ),
        ],
        loopDuration: 14.4
    )

    static let reserved = LyricStylePreviewSample(
        id: "reserved",
        title: "野芝麻",
        lines: [
            LyricStylePreviewLine(
                line: LyricLine(
                    id: 0, time: 0, end: 3.1,
                    text: "You and the others who think",
                    translation: "你和那些自以为如此的人",
                    romaji: "You and the others who think",
                    furigana: nil,
                    words: tokenWords(["You", "and", "the", "others", "who", "think"], start: 0, end: 3.1)
                ),
                harmony: nil
            ),
            LyricStylePreviewLine(
                line: LyricLine(
                    id: 1, time: 3.6, end: 6.9,
                    text: "真実のために生きていると思う人たち、",
                    translation: "那些自以为为真理而活的人，",
                    romaji: "Shinjitsu no tame ni ikite iru to omou hitotachi,",
                    furigana: nil,
                    words: characterWords("真実のために生きていると思う人たち、", start: 3.6, end: 6.9)
                ),
                harmony: LyricStyleHarmony(
                    text: "Soon this will all feel like a distant dream.", start: 4.2, end: 6.6,
                    words: tokenWords(["Soon", "this", "will", "all", "feel", "like", "a", "distant", "dream."], start: 4.2, end: 6.6),
                    translation: "很快，这一切都会像一场遥远的梦。",
                    romanization: "Soon this will all feel like a distant dream."
                )
            ),
            LyricStylePreviewLine(
                line: LyricLine(
                    id: 2, time: 7.4, end: 10.3,
                    text: "et, par extension, qui aiment",
                    translation: "并因此爱上一切……",
                    romaji: "et, par extension, ki em",
                    furigana: nil,
                    words: tokenWords(["et,", "par", "extension,", "qui", "aiment"], start: 7.4, end: 10.3)
                ),
                harmony: nil
            ),
            LyricStylePreviewLine(
                line: LyricLine(
                    id: 3, time: 10.8, end: 13.6,
                    text: "一切冰冷的事物。",
                    translation: "all that is cold.",
                    romaji: "Yīqiè bīnglěng de shìwù.",
                    furigana: nil,
                    words: characterWords("一切冰冷的事物。", start: 10.8, end: 13.6)
                ),
                harmony: nil
            ),
        ],
        loopDuration: 13.6
    )

    static let all = [`default`, reserved]

    /// Even split of a line's span across its characters
    /// (`createCharacterWords` in `PreviewPlaceholder.ts`).
    static func characterWords(_ text: String, start: TimeInterval, end: TimeInterval) -> [LyricWord] {
        let chars = Array(text)
        guard !chars.isEmpty else { return [] }
        let duration = end - start
        return chars.enumerated().map { index, char in
            let wordStart = start + duration * Double(index) / Double(chars.count)
            let wordEnd = start + duration * Double(index + 1) / Double(chars.count)
            return LyricWord(text: String(char), start: wordStart, duration: wordEnd - wordStart)
        }
    }

    /// Even split of a line's span across its tokens
    /// (`createTokenWords` in `PreviewPlaceholder.ts`).
    static func tokenWords(_ tokens: [String], start: TimeInterval, end: TimeInterval) -> [LyricWord] {
        guard !tokens.isEmpty else { return [] }
        let duration = end - start
        return tokens.enumerated().map { index, token in
            let wordStart = start + duration * Double(index) / Double(tokens.count)
            let wordEnd = start + duration * Double(index + 1) / Double(tokens.count)
            return LyricWord(text: token, start: wordStart, duration: wordEnd - wordStart)
        }
    }
}

// MARK: - Live preview card

/// The style window's live preview: the real `LuminousLyricsView` over
/// the selected sample set, driven by a `TimelineView` clock that loops
/// over the set's duration. The pause button freezes the clock; the
/// top-left badge names the style being previewed.
struct LyricStylePreviewCard: View {
    @EnvironmentObject private var settings: SettingsManager

    @Binding var sampleID: String

    @State private var anchor = Date()
    @State private var frozenTime: TimeInterval?

    private var sample: LyricStylePreviewSample {
        // `first(where:)` — `first` is a property, not a method, so a
        // trailing closure cannot call it. The fallback must be spelled
        // out: `.default` lives on `LyricStylePreviewSamples`, not on
        // the sample struct itself.
        LyricStylePreviewSamples.all.first(where: { $0.id == sampleID }) ?? LyricStylePreviewSamples.default
    }

    /// The preview clock at `date`: the loop position, or the frozen
    /// position while paused.
    private func previewTime(at date: Date) -> TimeInterval {
        if let frozenTime { return frozenTime }
        return sample.loopTime(for: date.timeIntervalSince(anchor))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(white: 0.08))

            VStack(spacing: 0) {
                TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
                    previewContent(time: previewTime(at: context.date))
                }
                .frame(height: 300)

                HStack {
                    Picker("预览文本", selection: $sampleID) {
                        ForEach(LyricStylePreviewSamples.all, id: \.id) { sample in
                            Text(sample.title).tag(sample.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: sampleID) { _ in
                        anchor = Date()
                        frozenTime = nil
                    }

                    Button {
                        if frozenTime == nil {
                            frozenTime = previewTime(at: Date())
                        } else {
                            anchor = Date().addingTimeInterval(-(frozenTime ?? 0))
                            frozenTime = nil
                        }
                    } label: {
                        Image(systemName: frozenTime == nil ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(.white.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(frozenTime == nil ? "暂停预览" : "继续预览")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }

            Text("流光")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Theme.accent, in: Capsule())
                .padding(12)
        }
    }

    @ViewBuilder
    private func previewContent(time: TimeInterval) -> some View {
        if let activeIndex = sample.activeLineIndex(at: time) {
            let line = sample.lines[activeIndex].line
            let harmony = sample.lines[activeIndex].harmony
            VStack(spacing: 6) {
                LuminousLyricsView(
                    accent: Theme.accent,
                    previewLine: line,
                    previewTime: time,
                    previewUpcoming: sample.upcomingLines(after: activeIndex)
                )
                if let harmony,
                   settings.effectiveSubtitleHarmonyEnabled,
                   time >= harmony.start, time <= harmony.end {
                    Text(harmony.text)
                        .font(.system(size: 15, weight: .medium))
                        .italic()
                        .foregroundColor(.white.opacity(0.55 * settings.effectiveSubtitleOverlayOpacity))
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 8)
                }
            }
        } else {
            Text("…")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#if os(iOS)
/// System font picker (`UIFontPickerViewController`), wrapped for
/// SwiftUI. Picking a font stores its PostScript name as the custom
/// lyric font; cancelling leaves the current one alone.
struct LyricFontPicker: UIViewControllerRepresentable {
    var onPick: (String) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIFontPickerViewController {
        let picker = UIFontPickerViewController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIFontPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIFontPickerViewControllerDelegate {
        var onPick: (String) -> Void
        var onCancel: () -> Void

        init(onPick: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
            if let descriptor = viewController.selectedFontDescriptor {
                onPick(descriptor.postScriptName)
            }
        }

        func fontPickerViewControllerDidCancel(_ viewController: UIFontPickerViewController) {
            onCancel()
        }
    }
}
#endif

// MARK: - The settings window

/// Folia lyrics-style window: live preview on top, four tabs below —
/// 通用 / 背景 / 歌词动画 / 字幕 — no fifth global tab (Folia v0.7.26
/// has five; the global one is desktop-only and is not ported).
///
/// Presented two ways: pushed from Settings (its own NavigationStack)
/// and as a sheet from the luminous layout (the caller wraps it in a
/// `NavigationStack` and passes `showsDoneButton: true`).
///
/// All controls edit the stored values and are disabled while the Folia
/// master switch is off, matching the rest of the Folia settings.
struct LyricStyleSettingsView: View {
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.dismiss) private var dismiss

    var showsDoneButton = false

    @State private var tab: LyricStyleTab = .general
    @State private var sampleID = LyricStylePreviewSamples.default.id
    @State private var showsFontPicker = false

    private enum LyricStyleTab: String, CaseIterable {
        case general
        case background
        case animation
        case subtitle

        var title: String {
            switch self {
            case .general: return "通用"
            case .background: return "背景"
            case .animation: return "歌词动画"
            case .subtitle: return "字幕"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            LyricStylePreviewCard(sampleID: $sampleID)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            Picker("歌词样式", selection: $tab) {
                ForEach(LyricStyleTab.allCases, id: \.self) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if !settings.foliaEnabled {
                Text("Folia 功能已关闭，样式设置不生效。请先在设置里打开“Folia 功能”。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            Form {
                switch tab {
                case .general: generalSection
                case .background: backgroundSection
                case .animation: animationSection
                case .subtitle: subtitleSection
                }
            }
            .disabled(!settings.foliaEnabled)
        }
        .navigationTitle("歌词样式")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showsFontPicker) {
            LyricFontPicker(
                onPick: { name in
                    settings.lyricsCustomFont = name
                    showsFontPicker = false
                },
                onCancel: { showsFontPicker = false }
            )
        }
        #endif
    }

    // MARK: 通用

    private var generalSection: some View {
        Group {
            Section {
                Picker("预览文本", selection: $sampleID) {
                    ForEach(LyricStylePreviewSamples.all, id: \.id) { sample in
                        Text(sample.title).tag(sample.id)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("预览文本")
            }

            Section("字体") {
                Picker("字体", selection: $settings.lyricsFontStyle) {
                    ForEach(LyricsFontStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                #if os(iOS)
                Button {
                    showsFontPicker = true
                } label: {
                    LabeledContent("自定义字体", value: settings.lyricsCustomFont ?? "未选择")
                }
                if settings.lyricsCustomFont != nil {
                    Button("清除自定义字体", role: .destructive) {
                        settings.lyricsCustomFont = nil
                    }
                }
                #else
                TextField("自定义字体（PostScript 名称）", text: Binding(
                    get: { settings.lyricsCustomFont ?? "" },
                    set: { settings.lyricsCustomFont = $0.isEmpty ? nil : $0 }
                ))
                #endif
            } footer: {
                Text("自定义字体优先于上方选择的字体样式；不选则用样式字体。")
            }

            Section("字号") {
                Slider(value: $settings.lyricsFontScale, in: SettingsManager.lyricsFontScaleRange, step: 0.05) {
                    Text("字号")
                } minimumValueLabel: {
                    Text("85%")
                } maximumValueLabel: {
                    Text("140%")
                }
                HStack(spacing: 8) {
                    ForEach([0.9, 1.0, 1.1, 1.25], id: \.self) { value in
                        Button("\(Int(value * 100))%") {
                            settings.lyricsFontScale = value
                        }
                        .buttonStyle(.bordered)
                        .tint(abs(settings.lyricsFontScale - value) < 0.001 ? .accentColor : .secondary)
                    }
                    Spacer()
                    Text("\(Int(settings.lyricsFontScale * 100))%")
                        .foregroundColor(.secondary)
                }
            }

            Section("字重") {
                Toggle("自动字重", isOn: Binding(
                    get: { settings.lyricsFontWeight == nil },
                    set: { auto in settings.lyricsFontWeight = auto ? nil : 700 }
                ))
                if settings.lyricsFontWeight != nil {
                    Slider(value: Binding(
                        get: { settings.lyricsFontWeight ?? 700 },
                        set: { settings.lyricsFontWeight = $0 }
                    ), in: SettingsManager.lyricsFontWeightRange, step: 50) {
                        Text("字重")
                    } minimumValueLabel: {
                        Text("100")
                    } maximumValueLabel: {
                        Text("900")
                    }
                }
            }

            Section("整体透明度") {
                Slider(value: $settings.visualizerOpacity, in: SettingsManager.visualizerOpacityRange, step: 0.05) {
                    Text("整体透明度")
                } minimumValueLabel: {
                    Text("20%")
                } maximumValueLabel: {
                    Text("100%")
                }
            }

            Section {
                Button("恢复默认") {
                    settings.resetLyricStyleSettings()
                }
            } footer: {
                Text("把流光、漫游与歌词样式的全部设置恢复为 Folia 默认值；总开关与其他 Folia 设置不受影响。")
            }
        }
    }

    // MARK: 背景

    private var backgroundSection: some View {
        Group {
            Section {
                Picker("背景模式", selection: $settings.visualizerBackgroundMode) {
                    ForEach(VisualizerBackgroundMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            } header: {
                Text("背景模式")
            }

            if settings.visualizerBackgroundMode == .nomand {
                Section("漫游（半调圆点）") {
                    Picker("效果", selection: $settings.nomandEffect) {
                        ForEach(NomandEffect.allCases) { effect in
                            Text(effect.displayName).tag(effect)
                        }
                    }
                    Slider(value: $settings.nomandHalftoneSize, in: SettingsManager.nomandHalftoneSizeRange, step: 0.05) {
                        Text("圆点大小")
                    } minimumValueLabel: {
                        Text("稀疏")
                    } maximumValueLabel: {
                        Text("密集")
                    }
                    Slider(value: $settings.nomandHalftoneRadius, in: SettingsManager.nomandHalftoneRadiusRange, step: 0.05) {
                        Text("圆点半径")
                    } minimumValueLabel: {
                        Text("0.1")
                    } maximumValueLabel: {
                        Text("2")
                    }
                    Slider(value: $settings.nomandHalftoneContrast, in: SettingsManager.nomandHalftoneContrastRange, step: 0.05) {
                        Text("对比度")
                    } minimumValueLabel: {
                        Text("0")
                    } maximumValueLabel: {
                        Text("1")
                    }
                    Toggle("保留封面原色", isOn: $settings.nomandOriginalColors)
                    Slider(value: $settings.nomandOverlayOpacity, in: SettingsManager.nomandOverlayOpacityRange, step: 0.05) {
                        Text("遮罩透明度")
                    } minimumValueLabel: {
                        Text("0%")
                    } maximumValueLabel: {
                        Text("100%")
                    }
                } footer: {
                    Text("半调圆点由封面实时生成；圆点取主题强调色，空隙取背景色。保留原色时圆点按封面颜色着色。")
                }
            }
        }
    }

    // MARK: 歌词动画

    private var animationSection: some View {
        Group {
            Section {
                Picker("样式", selection: .constant(LyricStyleOption.luminous)) {
                    Text(LyricStyleOption.luminous.displayName).tag(LyricStyleOption.luminous)
                }
            } header: {
                Text("样式")
            } footer: {
                Text("目前只有流光一种样式。")
            }

            Section("流光") {
                Toggle("词旋转", isOn: $settings.classicWordRotation)
                Slider(value: $settings.classicBreathingFloat, in: SettingsManager.classicBreathingFloatRange, step: 0.1) {
                    Text("呼吸浮动")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("2")
                }
                Slider(value: $settings.classicWordSpacing, in: SettingsManager.classicWordSpacingRange, step: 0.1) {
                    Text("词间距")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("2")
                }
                Toggle("避免词重叠", isOn: $settings.classicAvoidOverlap)
            } footer: {
                Text("词旋转与呼吸浮动在静态模式或减弱动态开启时自动关闭。")
            }
        }
    }

    // MARK: 字幕

    private var subtitleSection: some View {
        Group {
            Section {
                Picker("内容模式", selection: Binding(
                    get: { settings.subtitleContentMode },
                    set: { settings.subtitleContentMode = $0 }
                )) {
                    ForEach(SubtitleContentMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Toggle("隐藏译文字幕", isOn: $settings.hideTranslationSubtitle)
                Toggle("和声字幕", isOn: $settings.subtitleHarmonyEnabled)
            } header: {
                Text("内容")
            } footer: {
                Text("内容模式与歌词页的“显示译文 / 罗马音”开关是同一组设置，改一边另一边跟着变。和声字幕只在样式预览里有效——真实歌词没有和声数据。")
            }

            Section("字幕样式") {
                Slider(value: $settings.subtitleOverlayOpacity, in: SettingsManager.subtitleOverlayOpacityRange, step: 0.05) {
                    Text("字幕透明度")
                } minimumValueLabel: {
                    Text("0%")
                } maximumValueLabel: {
                    Text("100%")
                }
                Slider(value: $settings.subtitleFontScale, in: SettingsManager.subtitleFontScaleRange, step: 0.05) {
                    Text("字幕字号")
                } minimumValueLabel: {
                    Text("85%")
                } maximumValueLabel: {
                    Text("140%")
                }
                Toggle("字幕字体跟随歌词", isOn: $settings.subtitleFontFollowsLyrics)
                Toggle("下一句模糊", isOn: $settings.subtitleUpcomingLyricsBlur)
            }
        }
    }
}

/// The visualizer style the style window previews. Only luminous is
/// ported; the picker in the animation tab is a placeholder for the
/// styles that may follow. (Not `LyricAnimationStyle` — that is the
/// row-list animation style in `SettingsManager`.)
private enum LyricStyleOption: String, CaseIterable, Identifiable {
    case luminous

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .luminous: return String(localized: "流光")
        }
    }
}
