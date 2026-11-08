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

import CoreGraphics
import PhotosUI
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
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
    /// is inside its window (start...end). The window is widened by a
    /// hair (1e-9s) so a loop time that lands a floating-point epsilon
    /// below a line's start — e.g. `loopTime(for: 15.1)` coming back a
    /// hair under 0.7 instead of exactly 0.7 — still finds its line
    /// instead of returning nil for a frame.
    func activeLineIndex(at time: TimeInterval) -> Int? {
        let epsilon: TimeInterval = 1e-9
        for index in lines.indices.reversed() {
            let line = lines[index].line
            if time >= line.time - epsilon, time <= line.end + epsilon { return index }
        }
        return nil
    }

    /// The line to show at `time`, holding the last line that started
    /// when the clock is between lines (the sample sets leave ~0.6s gaps
    /// between lines), and the first line before it starts — so the
    /// preview never blanks out mid-loop.
    func holdingLineIndex(at time: TimeInterval) -> Int {
        let epsilon: TimeInterval = 1e-9
        var held = 0
        for index in lines.indices {
            if time >= lines[index].line.time - epsilon { held = index } else { break }
        }
        return held
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
    /// The user-uploaded background image, loaded once per stored file
    /// name like the player page does — the monet/nomand previews show it
    /// when their source selects it (D10c).
    @State private var uploadedPreviewImage: PlatformImage?

    /// Procedural stand-in cover for the preview, which has no song
    /// artwork: a dark field with accent/white discs and a light band, so
    /// the cover-driven backgrounds (nomand effects, the monet bake, the
    /// common blurred cover) have tonal and colour variation to render.
    /// Generated once; 400×400 is plenty for a 300pt-tall preview card.
    private static let sampleCover: PlatformImage? = makeSampleCover()

    private static func makeSampleCover() -> PlatformImage? {
        let size = 400
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        context.setFillColor(CGColor(srgbRed: 0.10, green: 0.12, blue: 0.20, alpha: 1))
        context.fill(rect)
        // Light diagonal band for tonal range.
        context.saveGState()
        context.translateBy(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
        context.rotate(by: .pi / 4)
        context.setFillColor(CGColor(gray: 0.85, alpha: 0.9))
        context.fill(CGRect(x: -CGFloat(size), y: -30, width: CGFloat(size) * 2, height: 60))
        context.restoreGState()
        // Accent + white discs for colour and luminance contrast.
        context.setFillColor(PlatformColor(Theme.accent).cgColor)
        context.fillEllipse(in: CGRect(x: 60, y: 60, width: 200, height: 200))
        context.setFillColor(CGColor(gray: 0.95, alpha: 1))
        context.fillEllipse(in: CGRect(x: 230, y: 220, width: 120, height: 120))
        context.setFillColor(CGColor(gray: 0.35, alpha: 1))
        context.fillEllipse(in: CGRect(x: 40, y: 270, width: 90, height: 90))
        guard let cgImage = context.makeImage() else { return nil }
        #if os(iOS)
        return PlatformImage(cgImage: cgImage)
        #else
        return PlatformImage(cgImage: cgImage, size: NSSize(width: size, height: size))
        #endif
    }

    /// The cover for a cover-driven preview background: the uploaded image
    /// when the mode's source selects it and one is stored, else the
    /// procedural sample cover (the preview has no song artwork).
    private func previewCover(for source: BackgroundImageSource) -> PlatformImage? {
        if source == .uploadedGlobal, let uploadedPreviewImage {
            return uploadedPreviewImage
        }
        return Self.sampleCover
    }

    /// Whether preview backgrounds are still: static mode, the background
    /// reduce-motion override (the same flag as the player page's
    /// `backgroundIsStatic`, D4), or the preview's own pause button.
    private var previewBackgroundIsStatic: Bool {
        settings.effectiveStaticMode || settings.effectiveReduceMotionBackground || frozenTime != nil
    }

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
                // `.animation`, not `.periodic`: the periodic schedule is
                // the one PR #13 proved stalls in this app (it froze the
                // player lyrics in build 556) — this card still used it,
                // so its clock froze at ~0s and the preview showed "…"
                // forever.
                ZStack {
                    previewBackground
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                        previewContent(time: previewTime(at: context.date))
                    }
                }
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .task(id: settings.effectiveUploadedBackgroundImageName) {
                    // Load once per stored file name, off the main actor:
                    // the file read + image decode must not hitch the
                    // preview. A missing file loads as nil and the
                    // previews fall back to the sample cover.
                    let name = settings.effectiveUploadedBackgroundImageName
                    uploadedPreviewImage = await Task.detached(priority: .userInitiated) {
                        VisualizerBackgroundImageStore.loadImage(named: name)
                    }.value
                }

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

    /// The selected background behind the preview lyrics, drawn with the
    /// theme colours. Folia's preview shows the live background, so the
    /// mode's character should read here too: cover-driven modes render
    /// over a procedural sample cover (the uploaded image when their
    /// source selects it), and the drift/motion follows the same static
    /// flag as the player page (D10).
    @ViewBuilder
    private var previewBackground: some View {
        switch settings.effectiveVisualizerBackgroundMode {
        case .latent:
            #if os(iOS)
            LatentBackgroundView(
                primary: Theme.accent,
                secondary: ArtworkColors.fallback.secondary,
                accent: Theme.accent,
                background: ArtworkColors.fallback.secondary,
                isPlaying: false,
                isStatic: previewBackgroundIsStatic,
                tuning: settings.latentTuning
            )
            #else
            ArtworkColors.fallback.secondary
            #endif
        case .nomand:
            // D10b: the selected nomand effect, rendered by the real
            // view over the sample cover (or the upload) — not a plain
            // colour. Same tuning as the player page's backdrop.
            NomandBackgroundView(
                cover: previewCover(for: settings.effectiveNomandImageSource),
                songID: "preview",
                tuning: NomandDitherer.Tuning(
                    size: settings.effectiveNomandHalftoneSize,
                    radius: settings.effectiveNomandHalftoneRadius,
                    contrast: settings.effectiveNomandHalftoneContrast,
                    originalColors: settings.effectiveNomandOriginalColors,
                    accent: PlatformColor(Theme.accent),
                    background: PlatformColor(ArtworkColors.fallback.secondary),
                    effect: settings.effectiveNomandEffect,
                    highlight: PlatformColor(Theme.accent),
                    secondary: PlatformColor(Theme.accent),
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
                background: ArtworkColors.fallback.secondary
            )
        case .common:
            CommonBackgroundView(
                cover: Self.sampleCover,
                background: ArtworkColors.fallback.secondary,
                primary: Theme.accent,
                secondary: ArtworkColors.fallback.secondary,
                accent: Theme.accent,
                opacity: settings.effectiveCommonOpacity,
                useCoverColorBg: settings.effectiveCommonUseCoverColorBg,
                disableVignette: settings.effectiveCommonDisableVignette,
                disableGeometric: settings.effectiveCommonDisableGeometric,
                isStatic: previewBackgroundIsStatic
            )
        case .monet:
            MonetBackgroundView(
                cover: previewCover(for: settings.effectiveMonetBackgroundSource),
                background: ArtworkColors.fallback.secondary,
                primary: Theme.accent,
                accent: Theme.accent,
                secondary: ArtworkColors.fallback.secondary,
                tuning: settings.monetTuning,
                isStatic: previewBackgroundIsStatic
            )
        case .url:
            if let url = settings.selectedUrlBackground.flatMap({ URL(string: $0.url) }) {
                #if os(iOS)
                UrlBackgroundView(url: url)
                #else
                ArtworkColors.fallback.secondary
                #endif
            } else {
                ArtworkColors.fallback.secondary
            }
        case .sora:
            #if os(iOS)
            SoraBackgroundView(
                primary: Theme.accent,
                accent: Theme.accent,
                background: ArtworkColors.fallback.secondary,
                isStatic: previewBackgroundIsStatic,
                blank: settings.effectiveSoraBlank
            )
            #else
            ArtworkColors.fallback.secondary
            #endif
        case .none:
            ArtworkColors.fallback.secondary
        }
    }

    @ViewBuilder
    private func previewContent(time: TimeInterval) -> some View {
        // The holding line, not the active one: between lines the clock
        // is in a ~0.6s gap, and the old code drew "…" there — with the
        // clock frozen at ~0s that was the preview's permanent state.
        let activeIndex = sample.holdingLineIndex(at: time)
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
                    .padding(.horizontal, settings.effectiveSubtitleHarmonyBackgroundEnabled ? 10 : 0)
                    .padding(.vertical, settings.effectiveSubtitleHarmonyBackgroundEnabled ? 4 : 0)
                    .background {
                        if settings.effectiveSubtitleHarmonyBackgroundEnabled {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.black.opacity(0.35))
                        }
                    }
                    .padding(.bottom, 8)
            }
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
                // `UIFontDescriptor` has no PostScript-name property; go
                // through `UIFont`, whose `fontName` is the PostScript name.
                onPick(UIFont(descriptor: descriptor, size: 0).fontName)
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
    @State private var showsSubtitleFontPicker = false
    @State private var newUrlText = ""
    @State private var backgroundImagePickerItem: PhotosPickerItem?

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

    /// Tabs with live settings on this platform. On macOS the luminous
    /// player page — the only consumer of the background / lyric-style /
    /// subtitle settings — does not exist, so only the 通用 tab (preview
    /// text + reset) is offered (D6). The other tabs' section code stays
    /// in the `switch` below so it still compiles on both platforms, and
    /// the preview card above keeps rendering.
    private var visibleTabs: [LyricStyleTab] {
        #if os(iOS)
        LyricStyleTab.allCases
        #else
        [.general]
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            LyricStylePreviewCard(sampleID: $sampleID)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            Picker("歌词样式", selection: $tab) {
                ForEach(visibleTabs, id: \.self) { tab in
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
        .sheet(isPresented: $showsSubtitleFontPicker) {
            LyricFontPicker(
                onPick: { name in
                    settings.subtitleCustomFont = name
                    showsSubtitleFontPicker = false
                },
                onCancel: { showsSubtitleFontPicker = false }
            )
        }
        #endif
    }

    /// Global lyric timeline offset label (Folia B12): negative shifts
    /// lyrics earlier, positive shifts them later.
    private var lyricOffsetLabel: String {
        let ms = settings.globalLyricTimelineOffsetMs
        if ms == 0 { return "关闭" }
        if ms < 0 { return "提前 \(-ms) 毫秒" }
        return "延后 \(ms) 毫秒"
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

            #if os(macOS)
            Section {
                Text("歌词字体、字号与透明度只在 iOS 流光播放页生效，macOS 播放页不读取这些设置。")
                    .foregroundColor(.secondary)
            }
            #endif
            #if os(iOS)
            Section {
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
            } header: {
                Text("字体")
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
            #endif

            // NOTE: there is no Section(title:content:footer:) overload —
            // a string title with a footer does not compile, so the title
            // goes in header: like the font Section above.
            Section {
                Slider(value: Binding(
                    get: { Double(settings.globalLyricTimelineOffsetMs) },
                    set: { settings.globalLyricTimelineOffsetMs = Int($0) }
                ), in: -2000...2000, step: 50) {
                    Text("时间轴偏移")
                } minimumValueLabel: {
                    Text("-2s")
                } maximumValueLabel: {
                    Text("+2s")
                }
                HStack {
                    Text(lyricOffsetLabel)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("归零") {
                        settings.globalLyricTimelineOffsetMs = 0
                    }
                    .buttonStyle(.bordered)
                    .tint(settings.globalLyricTimelineOffsetMs == 0 ? .secondary : .accentColor)
                    .disabled(settings.globalLyricTimelineOffsetMs == 0)
                }
            } header: {
                Text("时间轴偏移")
            } footer: {
                Text("歌词整体提前或延后，解决某首歌词对不上拍的问题；仅在 Folia 总开关开启时生效。")
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
            } footer: {
                Text(backgroundModeFooter)
            }

            switch settings.visualizerBackgroundMode {
            case .latent:
                latentSection
            case .nomand:
                nomandSection
            case .common:
                commonSection
            case .monet:
                monetSection
            case .sora:
                soraSection
            case .url:
                urlSection
            case .none:
                Section {
                    Text("播放页使用纯色背景，不渲染任何效果。")
                        .foregroundColor(.secondary)
                }
            }

            if settings.visualizerBackgroundMode == .monet
                || settings.visualizerBackgroundMode == .nomand {
                uploadedImageSection
            }
        }
    }

    private var backgroundModeFooter: String {
        switch settings.visualizerBackgroundMode {
        case .latent:
            return "隐现：封面取色的流动烟雾与半调像素层，默认背景。"
        case .nomand:
            return "漫游：封面经选中的图片效果渲染的静态背景。"
        case .common:
            return "通用：主题纯色，可叠加模糊封面与漂移的几何图形。"
        case .monet:
            return "莫奈：封面烘焙成的静态海报，可加灰度、染色与漂移。"
        case .url:
            return "嵌入：在播放页内嵌一个网页，仅支持 https 网址。"
        case .sora:
            return "空：漂移闪烁的星空。"
        case .none:
            return "无背景：纯色播放页。"
        }
    }

    // MARK: 隐现

    private var latentSection: some View {
        Group {
            Section {
                Picker("显示图层", selection: $settings.latentDisplayMode) {
                    ForEach(LatentDisplayMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Picker("颜色来源", selection: $settings.latentColorSource) {
                    ForEach(LatentColorSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                Toggle("增强节拍响应", isOn: $settings.latentEnhancedBeatResponse)
                Toggle("可读性叠色", isOn: $settings.latentOverlayEnabled)
                if settings.latentOverlayEnabled {
                    Slider(value: $settings.latentOverlayOpacity, in: SettingsManager.latentOpacityRange, step: 0.05) {
                        Text("叠色透明度 \(Int(settings.latentOverlayOpacity * 100))%")
                    } minimumValueLabel: {
                        Text("0%")
                    } maximumValueLabel: {
                        Text("100%")
                    }
                }
            } header: {
                Text("隐现背景")
            } footer: {
                Text("叠加封面取色的像素与流体着色器，并使用大范围音频速度响应。")
            }

            Section {
                Slider(value: $settings.latentDitheringSpeed, in: SettingsManager.latentSpeedRange, step: 0.1) {
                    Text("基础速度 \(settings.latentDitheringSpeed, specifier: "%.1f")")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("2")
                }
                Slider(value: $settings.latentDitheringAudioSpeed, in: SettingsManager.latentSpeedRange, step: 0.1) {
                    Text("音频响应最大速度 \(settings.latentDitheringAudioSpeed, specifier: "%.1f")")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("2")
                }
                Slider(value: $settings.latentDitheringSize, in: SettingsManager.latentDitheringSizeRange, step: 0.25) {
                    Text("像素尺寸 \(settings.latentDitheringSize, specifier: "%.2f")")
                } minimumValueLabel: {
                    Text("0.5")
                } maximumValueLabel: {
                    Text("8")
                }
                Slider(value: $settings.latentDitheringOpacity, in: SettingsManager.latentOpacityRange, step: 0.05) {
                    Text("像素层透明度 \(Int(settings.latentDitheringOpacity * 100))%")
                } minimumValueLabel: {
                    Text("0%")
                } maximumValueLabel: {
                    Text("100%")
                }
            } header: {
                Text("像素背景")
            }

            Section {
                Slider(value: $settings.latentMeshSpeed, in: SettingsManager.latentSpeedRange, step: 0.1) {
                    Text("基础速度 \(settings.latentMeshSpeed, specifier: "%.1f")")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("2")
                }
                Slider(value: $settings.latentMeshAudioSpeed, in: SettingsManager.latentSpeedRange, step: 0.1) {
                    Text("音频响应最大速度 \(settings.latentMeshAudioSpeed, specifier: "%.1f")")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("2")
                }
                Slider(value: $settings.latentMeshDistortion, in: SettingsManager.latentMeshDistortionRange, step: 0.05) {
                    Text("流体扭曲 \(settings.latentMeshDistortion, specifier: "%.2f")")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("2")
                }
                Slider(value: $settings.latentMeshSwirl, in: SettingsManager.latentMeshSwirlRange, step: 0.05) {
                    Text("流体旋涡 \(settings.latentMeshSwirl, specifier: "%.2f")")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("1")
                }
            } header: {
                Text("流体背景")
            }
        }
    }

    // MARK: 漫游

    private var nomandSection: some View {
        Group {
            Section {
                Picker("效果", selection: $settings.nomandEffect) {
                    ForEach(NomandEffect.allCases) { effect in
                        Text(effect.displayName).tag(effect)
                    }
                }
                Picker("图片来源", selection: $settings.nomandImageSource) {
                    ForEach(BackgroundImageSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                Toggle("可读性叠色", isOn: $settings.nomandOverlayEnabled)
                if settings.nomandOverlayEnabled {
                    Slider(value: $settings.nomandOverlayOpacity, in: SettingsManager.nomandOverlayOpacityRange, step: 0.05) {
                        Text("叠色透明度 \(Int(settings.nomandOverlayOpacity * 100))%")
                    } minimumValueLabel: {
                        Text("0%")
                    } maximumValueLabel: {
                        Text("100%")
                    }
                }
            } header: {
                Text("漫游")
            } footer: {
                Text("封面经选中的图片效果渲染；未上传图片时，已上传图片会回退为封面。")
            }

            switch settings.nomandEffect {
            case .halftoneDots:
                Section {
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
                    Toggle("反色", isOn: $settings.nomandHalftoneDotsInverted)
                } header: {
                    Text("半调网点")
                } footer: {
                    Text("半调圆点由封面实时生成；圆点取主题强调色，空隙取背景色。保留原色时圆点按封面颜色着色。")
                }
            case .dithering:
                Section {
                    Picker("矩阵", selection: $settings.nomandDitheringType) {
                        ForEach(NomandDitheringType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    Slider(value: $settings.nomandDitheringSize, in: SettingsManager.nomandDitheringSizeRange, step: 0.5) {
                        Text("像素尺寸 \(settings.nomandDitheringSize, specifier: "%.1f")")
                    } minimumValueLabel: {
                        Text("0.5")
                    } maximumValueLabel: {
                        Text("20")
                    }
                    Slider(value: Binding(
                        get: { Double(settings.nomandDitheringColorSteps) },
                        set: { settings.nomandDitheringColorSteps = Int($0.rounded()) }
                    ), in: 1.0...7.0, step: 1) {
                        Text("色彩阶数 \(settings.nomandDitheringColorSteps)")
                    } minimumValueLabel: {
                        Text("1")
                    } maximumValueLabel: {
                        Text("7")
                    }
                    Toggle("保留原色", isOn: $settings.nomandDitheringOriginalColors)
                    Toggle("反色", isOn: $settings.nomandDitheringInverted)
                } header: {
                    Text("像素画")
                } footer: {
                    Text("封面化作 Bayer 抖动的像素图案，按主题色量化；保留原色时按封面颜色着色。")
                }
            case .flutedGlass:
                Section {
                    Slider(value: $settings.nomandFlutedGlassSize, in: SettingsManager.nomandFlutedGlassSizeRange, step: 0.05) {
                        Text("纹理尺寸 \(settings.nomandFlutedGlassSize, specifier: "%.2f")")
                    } minimumValueLabel: {
                        Text("0.1")
                    } maximumValueLabel: {
                        Text("1")
                    }
                    Slider(value: $settings.nomandFlutedGlassDistortion, in: SettingsManager.nomandFlutedGlassDistortionRange, step: 0.05) {
                        Text("折射强度 \(settings.nomandFlutedGlassDistortion, specifier: "%.2f")")
                    } minimumValueLabel: {
                        Text("0")
                    } maximumValueLabel: {
                        Text("1")
                    }
                    Slider(value: $settings.nomandFlutedGlassBlur, in: SettingsManager.nomandFlutedGlassBlurRange, step: 0.01) {
                        Text("模糊 \(settings.nomandFlutedGlassBlur, specifier: "%.2f")")
                    } minimumValueLabel: {
                        Text("0")
                    } maximumValueLabel: {
                        Text("1")
                    }
                } header: {
                    Text("纹理玻璃")
                } footer: {
                    Text("封面透过竖纹玻璃呈现，棱镜边缘带柔和的高光。")
                }
            case .paperTexture:
                Section {
                    Slider(value: $settings.nomandPaperTextureContrast, in: SettingsManager.nomandPaperTextureContrastRange, step: 0.05) {
                        Text("对比度 \(settings.nomandPaperTextureContrast, specifier: "%.2f")")
                    } minimumValueLabel: {
                        Text("0")
                    } maximumValueLabel: {
                        Text("1")
                    }
                    Slider(value: $settings.nomandPaperTextureRoughness, in: SettingsManager.nomandPaperTextureRoughnessRange, step: 0.05) {
                        Text("粗糙度 \(settings.nomandPaperTextureRoughness, specifier: "%.2f")")
                    } minimumValueLabel: {
                        Text("0")
                    } maximumValueLabel: {
                        Text("1")
                    }
                    Slider(value: $settings.nomandPaperTextureFiber, in: SettingsManager.nomandPaperTextureFiberRange, step: 0.05) {
                        Text("纤维量 \(settings.nomandPaperTextureFiber, specifier: "%.2f")")
                    } minimumValueLabel: {
                        Text("0")
                    } maximumValueLabel: {
                        Text("1")
                    }
                } header: {
                    Text("纸张纹理")
                } footer: {
                    Text("封面印在带纤维纹理的纸面上，纸纹会轻微扭曲画面。")
                }
            case .lensDistortion:
                Section {
                    Slider(value: $settings.nomandLensDistortionSpread, in: SettingsManager.nomandLensDistortionSpreadRange, step: 0.05) {
                        Text("扩散范围 \(settings.nomandLensDistortionSpread, specifier: "%.2f")")
                    } minimumValueLabel: {
                        Text("0")
                    } maximumValueLabel: {
                        Text("1")
                    }
                    Slider(value: $settings.nomandLensDistortionBulge, in: SettingsManager.nomandLensDistortionBulgeRange, step: 0.05) {
                        Text("中心凸起 \(settings.nomandLensDistortionBulge, specifier: "%.2f")")
                    } minimumValueLabel: {
                        Text("-1")
                    } maximumValueLabel: {
                        Text("1")
                    }
                    Slider(value: $settings.nomandLensDistortionDispersion, in: SettingsManager.nomandLensDistortionDispersionRange, step: 0.05) {
                        Text("色散 \(settings.nomandLensDistortionDispersion, specifier: "%.2f")")
                    } minimumValueLabel: {
                        Text("0")
                    } maximumValueLabel: {
                        Text("1")
                    }
                } header: {
                    Text("镜头畸变")
                } footer: {
                    Text("封面经镜头弯曲，中心鼓起、边缘带色散。")
                }
            }
        }
    }

    // MARK: 通用

    private var commonSection: some View {
        Section {
            Toggle("使用封面颜色背景", isOn: $settings.commonUseCoverColorBg)
            if settings.commonUseCoverColorBg {
                Slider(value: $settings.commonOpacity, in: SettingsManager.commonOpacityRange, step: 0.05) {
                    Text("主题色透明度 \(Int(settings.commonOpacity * 100))%")
                } minimumValueLabel: {
                    Text("0%")
                } maximumValueLabel: {
                    Text("100%")
                }
            }
            Toggle("显示暗角", isOn: Binding(
                get: { !settings.commonDisableVignette },
                set: { settings.commonDisableVignette = !$0 }
            ))
            Toggle("显示几何图形", isOn: Binding(
                get: { !settings.commonDisableGeometric },
                set: { settings.commonDisableGeometric = !$0 }
            ))
        } header: {
            Text("通用背景")
        } footer: {
            Text("主题纯色背景，可选叠加模糊封面与随音频起伏的几何图形和粒子。")
        }
    }

    // MARK: 莫奈

    private var monetSection: some View {
        Group {
            Section {
                Picker("背景来源", selection: $settings.monetBackgroundSource) {
                    ForEach(BackgroundImageSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                Picker("布局", selection: $settings.monetBackgroundLayout) {
                    Text("完整覆盖").tag(MonetLayout.fullOverlay)
                    Text("半幅渐变").tag(MonetLayout.halfPaneGradient)
                }
                Slider(value: $settings.monetBackgroundBlurPx, in: SettingsManager.monetBackgroundBlurPxRange, step: 2) {
                    Text("模糊 \(settings.monetBackgroundBlurPx, specifier: "%.0f")")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("60")
                }
                Slider(value: $settings.monetBackgroundOverlayOpacity, in: SettingsManager.monetBackgroundOverlayOpacityRange, step: 0.02) {
                    Text("叠加透明度 \(Int(settings.monetBackgroundOverlayOpacity * 100))%")
                } minimumValueLabel: {
                    Text("0%")
                } maximumValueLabel: {
                    Text("100%")
                }
                Slider(value: $settings.monetBackgroundGrayscale, in: SettingsManager.monetBackgroundGrayscaleRange, step: 0.02) {
                    Text("灰度 \(settings.monetBackgroundGrayscale, specifier: "%.2f")")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("1")
                }
                Slider(value: $settings.monetBackgroundSaturation, in: SettingsManager.monetBackgroundSaturationRange, step: 0.05) {
                    Text("饱和度 \(settings.monetBackgroundSaturation, specifier: "%.2f")")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("2")
                }
                Slider(value: $settings.monetBackgroundWash, in: SettingsManager.monetBackgroundWashRange, step: 0.02) {
                    Text("染色 \(settings.monetBackgroundWash, specifier: "%.2f")")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("1")
                }
                if settings.monetBackgroundLayout == .halfPaneGradient {
                    Slider(value: $settings.monetBackgroundHalfPaneOffsetX, in: SettingsManager.monetBackgroundHalfPaneOffsetXRange, step: 2) {
                        Text("半幅横向偏移 \(settings.monetBackgroundHalfPaneOffsetX, specifier: "%.0f")")
                    } minimumValueLabel: {
                        Text("-40")
                    } maximumValueLabel: {
                        Text("40")
                    }
                }
            } header: {
                Text("莫奈背景")
            } footer: {
                Text("封面烘焙成的静态海报；未上传图片时，已上传图片会回退为封面。")
            }

            Section {
                Picker("染色颜色", selection: $settings.monetBackgroundWashColorMode) {
                    Text("主题").tag(MonetWashColorMode.theme)
                    Text("自定义").tag(MonetWashColorMode.custom)
                }
                if settings.monetBackgroundWashColorMode == .custom {
                    TextField("#rrggbb", text: $settings.monetBackgroundWashCustomColor)
                        .disableAutocorrection(true)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                Toggle("漂移", isOn: $settings.monetBackgroundDriftEnabled)
                if settings.monetBackgroundDriftEnabled {
                    Slider(value: $settings.monetBackgroundDriftStrength, in: SettingsManager.monetBackgroundDriftStrengthRange, step: 0.05) {
                        Text("漂移幅度 \(settings.monetBackgroundDriftStrength, specifier: "%.2f")")
                    } minimumValueLabel: {
                        Text("0")
                    } maximumValueLabel: {
                        Text("1")
                    }
                }
                Toggle("竖纹", isOn: $settings.monetBackgroundStreaksEnabled)
            } header: {
                Text("莫奈效果")
            } footer: {
                Text("自定义染色颜色须为 #rrggbb 格式；格式不对时用主题强调色代替。")
            }
        }
    }

    // MARK: 空

    private var soraSection: some View {
        Section {
            Toggle("仅显示纯色", isOn: $settings.soraBlank)
        } header: {
            Text("空背景")
        } footer: {
            Text("不再渲染星空，只显示静态纯色画面：夜间纯黑，日间纯白。")
        }
    }

    // MARK: 嵌入

    private var urlSection: some View {
        Section {
            HStack {
                TextField("https://…", text: $newUrlText)
                    .disableAutocorrection(true)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Button("添加") { addUrlBackground() }
                    .disabled(newUrlText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if settings.urlBackgroundList.isEmpty {
                Text("还没有保存的网页。添加一个 https 网址，在播放页内嵌显示。")
                    .foregroundColor(.secondary)
            }
            ForEach(settings.urlBackgroundList) { item in
                Button {
                    settings.urlBackgroundSelectedID = item.id
                } label: {
                    HStack {
                        Text(item.note)
                            .lineLimit(1)
                        Spacer()
                        if settings.urlBackgroundSelectedID == item.id {
                            Text("已选").foregroundColor(.secondary)
                        }
                    }
                }
            }
            .onDelete(perform: deleteUrlBackgrounds)
        } header: {
            Text("嵌入背景")
        } footer: {
            Text("仅支持 https 网址（系统传输安全限制）；点按一行可切换选中，左滑可删除。")
        }
    }

    /// Adds the typed URL to the saved list and selects it. Folia
    /// prepends `https://` when no scheme is given and accepts only
    /// http(s); here only https is accepted — cleartext http is blocked
    /// by App Transport Security without an entitlement exception.
    private func addUrlBackground() {
        var text = newUrlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), url.scheme == "https", url.host != nil else { return }
        let item = UrlBackgroundItem(url: url.absoluteString, note: url.absoluteString)
        settings.urlBackgroundList.append(item)
        settings.urlBackgroundSelectedID = item.id
        newUrlText = ""
    }

    private func deleteUrlBackgrounds(at offsets: IndexSet) {
        var list = settings.urlBackgroundList
        let deletedIDs = offsets.map { list[$0].id }
        list.remove(atOffsets: offsets)
        settings.urlBackgroundList = list
        if let selected = settings.urlBackgroundSelectedID, deletedIDs.contains(selected) {
            settings.urlBackgroundSelectedID = list.first?.id
        }
    }

    // MARK: 上传图片

    private var uploadedImageSection: some View {
        Section {
            PhotosPicker(selection: $backgroundImagePickerItem, matching: .images) {
                Text(settings.uploadedBackgroundImageName == nil ? "上传图片" : "更换图片")
            }
            .onChange(of: backgroundImagePickerItem?.itemIdentifier) { _ in
                guard let item = backgroundImagePickerItem else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let name = VisualizerBackgroundImageStore.save(data: data)
                    else {
                        backgroundImagePickerItem = nil
                        return
                    }
                    settings.uploadedBackgroundImageName = name
                    backgroundImagePickerItem = nil
                }
            }
            if settings.uploadedBackgroundImageName != nil {
                Button("清除已上传图片", role: .destructive) {
                    VisualizerBackgroundImageStore.delete(named: settings.uploadedBackgroundImageName)
                    settings.uploadedBackgroundImageName = nil
                    if settings.monetBackgroundSource == .uploadedGlobal {
                        settings.monetBackgroundSource = .coverDerived
                    }
                    if settings.nomandImageSource == .uploadedGlobal {
                        settings.nomandImageSource = .coverDerived
                    }
                }
            }
        } header: {
            Text("背景图片")
        } footer: {
            Text("一张全局图片，供莫奈与漫游共用：选“已上传图片”时替代封面作为来源；未上传时回退为封面。PNG、JPEG 与 GIF 可用；WebP 与 SVG 系统无法解码。")
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

            Section {
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
            } header: {
                Text("流光")
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
                // D2/D3: the harmony rows are preview-only — the real
                // subtitle overlay has no harmony row and the parser
                // produces no harmony data for real songs — so both
                // toggles are disabled (keys kept) instead of looking live.
                Toggle("和声字幕", isOn: $settings.subtitleHarmonyEnabled)
                    .disabled(true)
                Text("仅样式预览有效")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("下句行数：\(settings.subtitleUpcomingLineCount)", value: $settings.subtitleUpcomingLineCount, in: SettingsManager.subtitleUpcomingLineCountRange)
                Toggle("字幕背景", isOn: $settings.subtitleBackgroundEnabled)
                if settings.subtitleHarmonyEnabled {
                    Toggle("和声字幕背景", isOn: $settings.subtitleHarmonyBackgroundEnabled)
                        .disabled(true)
                    Text("仅样式预览有效")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("内容")
            } footer: {
                Text("内容模式与歌词页的“显示译文 / 罗马音”开关是同一组设置，改一边另一边跟着变。和声字幕只在样式预览里有效——真实歌词没有和声数据。字幕叠加只在流光播放页显示，格子模式不显示字幕叠加。")
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
                if !settings.subtitleFontFollowsLyrics {
                    Picker("字幕字体", selection: $settings.subtitleFontStyle) {
                        ForEach(LyricsFontStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    Toggle("字幕自动字重", isOn: Binding(
                        get: { settings.subtitleFontWeight == nil },
                        set: { auto in settings.subtitleFontWeight = auto ? nil : 400 }
                    ))
                    if settings.subtitleFontWeight != nil {
                        Slider(value: Binding(
                            get: { settings.subtitleFontWeight ?? 400 },
                            set: { settings.subtitleFontWeight = $0 }
                        ), in: SettingsManager.lyricsFontWeightRange, step: 50) {
                            Text("字幕字重")
                        } minimumValueLabel: {
                            Text("100")
                        } maximumValueLabel: {
                            Text("900")
                        }
                    }
                    #if os(iOS)
                    Button {
                        showsSubtitleFontPicker = true
                    } label: {
                        LabeledContent("字幕自定义字体", value: settings.subtitleCustomFont ?? "未选择")
                    }
                    if settings.subtitleCustomFont != nil {
                        Button("清除字幕自定义字体", role: .destructive) {
                            settings.subtitleCustomFont = nil
                        }
                    }
                    #else
                    TextField("字幕自定义字体（PostScript 名称）", text: Binding(
                        get: { settings.subtitleCustomFont ?? "" },
                        set: { settings.subtitleCustomFont = $0.isEmpty ? nil : $0 }
                    ))
                    #endif
                }
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
