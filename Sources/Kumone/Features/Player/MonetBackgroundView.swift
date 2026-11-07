// Sources/Kumone/Features/Player/MonetBackgroundView.swift
//
// Folia `monet` （莫奈） background, re-implemented with Core Image.
//
// Folia source: `components/visualizer/backgrounds/monet/`
// (`MonetBackground.tsx`). Folia bakes the cover once into a static
// 1920x1080 poster (a blurred, graded, duotone-washed cover) and
// then only animates a slow drift over it — no per-frame shader work.
// The Paper/WebGL poster pipeline is closed-source, so the grade is
// re-derived here with Core Image: Gaussian blur, a per-pixel
// grayscale / saturation / duotone-wash kernel, and SwiftUI overlay
// gradients on top.
//
// The bake happens once per track + tuning + colours on a background
// queue (see `MonetBaker`, patterned on `NomandDitherer`: NSCache +
// shared CIContext) and is cached, so a track change costs one
// render. While a new bake is in flight the previous image stays up —
// no flash to a plain background — and the new one fades in. The
// drift is a `TimelineView`-driven translate + breathing scale on a
// 240s sine/cosine loop: an approximation of Folia's 240s Web
// Animations noise track, which cannot be reproduced exactly without
// the original keyframes. Bake resolution is capped at 1280px on the
// long side (not Folia's full 1920 — this is a phone background).

import CoreImage
import Foundation
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// How the baked Monet poster is laid out.
public enum MonetLayout: String, CaseIterable {
    /// Full-bleed poster + readability gradient.
    case fullOverlay
    /// Poster in a left pane under a horizontal gradient mask.
    case halfPaneGradient
}

/// Where the duotone wash accent colour comes from.
public enum MonetWashColorMode: String, CaseIterable {
    case theme
    case custom
}

/// Monet tuning, with Folia's defaults.
public struct MonetTuning: Hashable, Equatable {
    public var layout: MonetLayout = .fullOverlay
    /// Blur radius in px at the 1920 reference width (0–60); scaled
    /// to the bake resolution when rendering.
    public var blurPx: Double = 6
    /// Opacity of the diagonal overlay gradient (0–1).
    public var overlayOpacity: Double = 0.74
    /// Mix toward luminance (0–1).
    public var grayscale: Double = 0
    /// Saturation scale about luminance (0–2).
    public var saturation: Double = 1.05
    /// Duotone wash mix amount (0–1).
    public var wash: Double = 0.34
    /// Half-pane horizontal shift in points (-40–40).
    public var halfPaneOffsetX: Double = 0
    public var washColorMode: MonetWashColorMode = .theme
    public var washCustomColorHex: String = "#8fb7ff"
    public var driftEnabled: Bool = true
    /// Drift strength (0–1).
    public var driftStrength: Double = 0.5
    public var streaksEnabled: Bool = true

    public init(
        layout: MonetLayout = .fullOverlay,
        blurPx: Double = 6,
        overlayOpacity: Double = 0.74,
        grayscale: Double = 0,
        saturation: Double = 1.05,
        wash: Double = 0.34,
        halfPaneOffsetX: Double = 0,
        washColorMode: MonetWashColorMode = .theme,
        washCustomColorHex: String = "#8fb7ff",
        driftEnabled: Bool = true,
        driftStrength: Double = 0.5,
        streaksEnabled: Bool = true
    ) {
        self.layout = layout
        self.blurPx = blurPx
        self.overlayOpacity = overlayOpacity
        self.grayscale = grayscale
        self.saturation = saturation
        self.wash = wash
        self.halfPaneOffsetX = halfPaneOffsetX
        self.washColorMode = washColorMode
        self.washCustomColorHex = washCustomColorHex
        self.driftEnabled = driftEnabled
        self.driftStrength = driftStrength
        self.streaksEnabled = streaksEnabled
    }
}

/// Folia `monet` background: the cover baked once into a graded,
/// duotone-washed poster, with overlay gradients, streaks, and a slow
/// drift on top.
public struct MonetBackgroundView: View {
    public var cover: PlatformImage?
    public var background: Color
    public var primary: Color
    public var accent: Color
    public var secondary: Color
    public var tuning: MonetTuning
    public var isStatic: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var baked: PlatformImage?

    public init(
        cover: PlatformImage?,
        background: Color,
        primary: Color,
        accent: Color,
        secondary: Color,
        tuning: MonetTuning = MonetTuning(),
        isStatic: Bool = false
    ) {
        self.cover = cover
        self.background = background
        self.primary = primary
        self.accent = accent
        self.secondary = secondary
        self.tuning = tuning
        self.isStatic = isStatic
    }

    /// What triggers a re-bake: the cover image itself, any tuning
    /// value, or any colour.
    private struct Request: Hashable {
        var coverID: ObjectIdentifier?
        var tuning: MonetTuning
        var background: RGBA
        var primary: RGBA
        var accent: RGBA
    }

    private struct RGBA: Hashable {
        var r: Double
        var g: Double
        var b: Double
        var a: Double
    }

    private var request: Request {
        Request(
            coverID: cover.map { ObjectIdentifier($0) },
            tuning: tuning,
            background: Self.rgba(background),
            primary: Self.rgba(primary),
            accent: Self.rgba(accent)
        )
    }

    private static func rgba(_ color: Color) -> RGBA {
        let components = MonetBaker.rgba(MonetBaker.platformColor(color))
        return RGBA(
            r: Double(components.r), g: Double(components.g),
            b: Double(components.b), a: Double(components.a)
        )
    }

    /// Parse a `#rrggbb` hex string into a platform colour, or `nil`
    /// when it is not a valid 6-digit hex colour.
    public static func hexColor(_ hex: String) -> PlatformColor? {
        var string = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 6, let value = UInt32(string, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xff) / 255
        let g = CGFloat((value >> 8) & 0xff) / 255
        let b = CGFloat(value & 0xff) / 255
        #if os(iOS)
        return UIColor(red: r, green: g, blue: b, alpha: 1)
        #else
        return NSColor(red: r, green: g, blue: b, alpha: 1)
        #endif
    }

    /// The baked poster as a SwiftUI `Image` on either platform.
    private func bakedImage(_ image: PlatformImage) -> Image {
        Image(platformImage: image)
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                // Theme gradient fallback: shown when there is no
                // cover (no bake), and underneath the poster otherwise.
                LinearGradient(
                    colors: [primary, secondary],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                if let baked {
                    switch tuning.layout {
                    case .fullOverlay:
                        posterView(baked, size: geo.size)
                    case .halfPaneGradient:
                        halfPaneView(baked, size: geo.size)
                    }
                }
                overlayGradients
                if tuning.streaksEnabled {
                    streaks(size: geo.size)
                }
            }
        }
        .task(id: request) {
            guard let cover else {
                baked = nil
                return
            }
            let backgroundColor = MonetBaker.platformColor(background)
            let primaryColor = MonetBaker.platformColor(primary)
            let accentColor = MonetBaker.platformColor(accent)
            let tuning = tuning
            let rendered = await Task.detached(priority: .userInitiated) {
                MonetBaker.bakedImage(
                    for: cover,
                    background: backgroundColor,
                    primary: primaryColor,
                    accent: accentColor,
                    tuning: tuning
                )
            }.value
            // A newer request may have started while this bake ran;
            // only the latest one may assign.
            guard !Task.isCancelled else { return }
            baked = rendered
        }
        .animation(.easeInOut(duration: 0.3), value: baked != nil)
    }

    // MARK: - Poster

    /// Full-bleed poster with the slow drift (unless static or drift
    /// is off). The base 1.08x scale keeps the edges covered at the
    /// full drift offset; the breathing scale rides on top of it.
    private func posterView(_ image: PlatformImage, size: CGSize) -> some View {
        Group {
            if tuning.driftEnabled && !isStatic {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let phase = 2 * Double.pi * t / 240.0
                    let strength = tuning.driftStrength
                    bakedImage(image)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(1.08 + 0.02 * strength * (0.5 + 0.5 * sin(phase * 2)))
                        .offset(
                            x: CGFloat(sin(phase) * 0.034 * strength) * size.width,
                            y: CGFloat(cos(phase * 0.7) * 0.034 * strength) * size.height
                        )
                }
            } else {
                bakedImage(image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .transition(.opacity)
    }

    /// Left pane: the poster at 60–72% of the container width (wider
    /// as the position moves right), centred at
    /// `50 + halfPaneOffsetX` percent of the width (clamped 10–90),
    /// faded out toward its right edge by a horizontal gradient mask.
    /// Opacity 0.7 in light mode, 0.3 in dark mode.
    private func halfPaneView(_ image: PlatformImage, size: CGSize) -> some View {
        let positionFraction = min(max(50 + tuning.halfPaneOffsetX, 10), 90) / 100
        let paneWidthFraction = 0.60 + 0.12 * (positionFraction - 0.10) / 0.80
        return bakedImage(image)
            .resizable()
            .scaledToFill()
            .frame(width: size.width * paneWidthFraction, height: size.height)
            .clipped()
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: 0.7),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .opacity(colorScheme == .dark ? 0.3 : 0.7)
            .position(x: size.width * positionFraction, y: size.height / 2)
    }

    // MARK: - Overlays (SwiftUI, not baked)

    /// Diagonal accent → background → primary gradient at
    /// `overlayOpacity` (half-pane: `overlayOpacity` x 0.16), plus the
    /// left-to-right readability gradient (background 0.18 → 0.82)
    /// for the full-overlay layout.
    private var overlayGradients: some View {
        Group {
            let overlayFactor = tuning.layout == .halfPaneGradient
                ? tuning.overlayOpacity * 0.16
                : tuning.overlayOpacity
            LinearGradient(
                stops: [
                    .init(color: accent.opacity(overlayFactor), location: 0),
                    .init(color: background.opacity(overlayFactor), location: 0.5),
                    .init(color: primary.opacity(overlayFactor), location: 1),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if tuning.layout == .fullOverlay {
                LinearGradient(
                    stops: [
                        .init(color: background.opacity(0.18), location: 0),
                        .init(color: background.opacity(0.82), location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
    }

    /// 18 vertical 1px bars at deterministic pseudo-random x
    /// positions, white at low opacity.
    private func streaks(size: CGSize) -> some View {
        ZStack {
            ForEach(0..<18, id: \.self) { index in
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 1, height: size.height)
                    .position(x: Self.streakX(index, width: size.width), y: size.height / 2)
            }
        }
    }

    private static func streakX(_ index: Int, width: CGFloat) -> CGFloat {
        let hash = sin(Double(index) * 12.9898 + 78.233) * 43758.5453
        let fraction = hash - floor(hash)
        return CGFloat(fraction) * width
    }
}

// MARK: - Baker

/// Renders the Monet poster once per cover + tuning + colours, on a
/// background queue, and caches it. Patterned on `NomandDitherer`.
private enum MonetBaker {

    private static let cache = NSCache<NSString, PlatformImage>()
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Long side of the bake in px: Folia bakes at 1920, but this is
    /// a phone background, so 1280 is plenty.
    private static let maxSide: CGFloat = 1280

    /// RGBA components of a platform colour, for hashing, cache keys
    /// and building solid-colour `CIImage`s.
    static func rgba(_ color: PlatformColor) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        // `CIColor(color:)` returns `CIColor?` on macOS but a plain
        // `CIColor` on iOS, so the unwrap is platform-conditional.
        #if os(iOS)
        let ciColor = CIColor(color: color)
        #else
        guard let ciColor = CIColor(color: color) else { return (0, 0, 0, 1) }
        #endif
        return (ciColor.red, ciColor.green, ciColor.blue, ciColor.alpha)
    }

    static func platformColor(_ color: Color) -> PlatformColor {
        #if os(iOS)
        return UIColor(color)
        #else
        return NSColor(color)
        #endif
    }

    private static func cacheKey(
        coverID: ObjectIdentifier,
        tuning: MonetTuning,
        background: PlatformColor,
        primary: PlatformColor,
        accent: PlatformColor
    ) -> String {
        let backgroundRGBA = rgba(background)
        let primaryRGBA = rgba(primary)
        let accentRGBA = rgba(accent)
        func components(_ c: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)) -> String {
            String(format: "%.3f,%.3f,%.3f,%.3f", c.r, c.g, c.b, c.a)
        }
        return [
            String(coverID.hashValue),
            tuning.layout.rawValue,
            String(format: "%.3f", tuning.blurPx),
            String(format: "%.3f", tuning.grayscale),
            String(format: "%.3f", tuning.saturation),
            String(format: "%.3f", tuning.wash),
            tuning.washColorMode.rawValue,
            tuning.washCustomColorHex,
            components(backgroundRGBA),
            components(primaryRGBA),
            components(accentRGBA),
        ].joined(separator: "|")
    }

    /// The baked poster for a cover, or `nil` when it cannot be
    /// rendered. Call from a background queue. Results are cached, so
    /// repeated calls with the same key are free.
    static func bakedImage(
        for cover: PlatformImage,
        background: PlatformColor,
        primary: PlatformColor,
        accent: PlatformColor,
        tuning: MonetTuning
    ) -> PlatformImage? {
        let coverID = ObjectIdentifier(cover)
        let key = cacheKey(
            coverID: coverID, tuning: tuning,
            background: background, primary: primary, accent: accent
        )
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard let rendered = render(
            cover: cover,
            background: background, primary: primary, accent: accent,
            tuning: tuning
        ) else { return nil }
        cache.setObject(rendered, forKey: key as NSString)
        return rendered
    }

    static func clearCache() {
        cache.removeAllObjects()
    }

    // MARK: - Rendering

    /// The cover as a correctly oriented `CGImage` plus its scale.
    /// `cgImageRef` is the raw bitmap, so a cover whose EXIF
    /// orientation is not `.up` would come out rotated — the displayed
    /// cover (via SwiftUI `Image`) applies the orientation, so the
    /// poster must too.
    private static func sourceImage(_ cover: PlatformImage) -> (cgImage: CGImage, scale: CGFloat)? {
        #if os(iOS)
        if cover.imageOrientation == .up, let cgImage = cover.cgImage {
            return (cgImage, cover.scale)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = cover.scale
        let renderer = UIGraphicsImageRenderer(size: cover.size, format: format)
        let normalized = renderer.image { _ in
            cover.draw(in: CGRect(origin: .zero, size: cover.size))
        }
        guard let cgImage = normalized.cgImage else { return nil }
        return (cgImage, cover.scale)
        #else
        guard let cgImage = cover.cgImageRef else { return nil }
        return (cgImage, 1)
        #endif
    }

    private static func render(
        cover: PlatformImage,
        background: PlatformColor,
        primary: PlatformColor,
        accent: PlatformColor,
        tuning: MonetTuning
    ) -> PlatformImage? {
        guard let source = sourceImage(cover) else { return nil }
        let cgImage = source.cgImage
        // Cap the bake at 1280px on the long side, keeping the cover's
        // aspect (the view displays it scaledToFill).
        let scale = min(1, maxSide / max(CGFloat(cgImage.width), CGFloat(cgImage.height)))
        var ciCover = CIImage(cgImage: cgImage)
        if scale < 1 {
            ciCover = ciCover.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let extent = ciCover.extent

        // Fill the theme background colour, then draw the cover over
        // it, cropped-cover (fill).
        let backgroundRGBA = rgba(background)
        let backgroundSolid = CIImage(color: CIColor(
            red: backgroundRGBA.r, green: backgroundRGBA.g,
            blue: backgroundRGBA.b, alpha: backgroundRGBA.a
        )).cropped(to: extent)
        let composited = CIFilter(name: "CISourceOverCompositing")
        composited?.setValue(ciCover, forKey: kCIInputImageKey)
        composited?.setValue(backgroundSolid, forKey: kCIInputBackgroundImageKey)
        guard var image = composited?.outputImage?.cropped(to: extent) else { return nil }

        // Gaussian blur. `blurPx` is specified at Folia's 1920
        // reference width, so it is scaled to the bake resolution.
        let bakeScale = Double(max(extent.width, extent.height)) / 1920.0
        let blurRadius = max(0, tuning.blurPx * bakeScale)
        if blurRadius > 0 {
            let blur = CIFilter(name: "CIGaussianBlur")
            blur?.setValue(image, forKey: kCIInputImageKey)
            blur?.setValue(blurRadius, forKey: kCIInputRadiusKey)
            guard let blurred = blur?.outputImage?.cropped(to: extent) else { return nil }
            image = blurred
        }

        // Per-pixel grade: grayscale mix, saturation about luminance,
        // then the duotone wash. Shadow / highlight are the darker /
        // lighter of background / primary; the wash accent is the
        // theme accent, or the custom hex when that mode is on.
        let primaryRGBA = rgba(primary)
        let backgroundLum = 0.2126 * backgroundRGBA.r + 0.7152 * backgroundRGBA.g + 0.0722 * backgroundRGBA.b
        let primaryLum = 0.2126 * primaryRGBA.r + 0.7152 * primaryRGBA.g + 0.0722 * primaryRGBA.b
        let shadowRGBA = backgroundLum <= primaryLum ? backgroundRGBA : primaryRGBA
        let highlightRGBA = backgroundLum <= primaryLum ? primaryRGBA : backgroundRGBA
        let accentRGBA = rgba(accent)
        let washRGBA: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)
        if tuning.washColorMode == .custom,
           let custom = MonetBackgroundView.hexColor(tuning.washCustomColorHex) {
            washRGBA = rgba(custom)
        } else {
            washRGBA = accentRGBA
        }

        guard let kernel = CIColorKernel(source: monetGradeKernelSource) else { return nil }
        let graded = kernel.apply(
            extent: extent,
            roiCallback: { _, rect in rect },
            arguments: [
                image,
                CIVector(x: shadowRGBA.r, y: shadowRGBA.g, z: shadowRGBA.b, w: shadowRGBA.a),
                CIVector(x: highlightRGBA.r, y: highlightRGBA.g, z: highlightRGBA.b, w: highlightRGBA.a),
                CIVector(x: washRGBA.r, y: washRGBA.g, z: washRGBA.b, w: washRGBA.a),
                NSNumber(value: tuning.grayscale),
                NSNumber(value: tuning.saturation),
                NSNumber(value: tuning.wash),
            ]
        )
        guard let result = graded else { return nil }

        guard let output = context.createCGImage(result, from: extent) else { return nil }
        #if os(iOS)
        return UIImage(cgImage: output, scale: source.scale, orientation: .up)
        #else
        return NSImage(cgImage: output, size: NSSize(width: CGFloat(output.width), height: CGFloat(output.height)))
        #endif
    }
}

// MARK: - Grade kernel

/// Per-pixel grade: mix toward luminance by `grayscale`, scale
/// saturation about luminance by `saturation`, then apply the duotone
/// wash — luminance <= 0.55 mixes the shadow colour toward the wash
/// accent, above 0.55 it mixes the wash accent toward the highlight —
/// at strength `wash`.
private let monetGradeKernelSource = """
kernel vec4 monetGrade(__sample pixel, vec4 shadow, vec4 highlight, vec4 washColor, float grayscale, float saturation, float wash) {
    float lum = dot(pixel.rgb, vec3(0.2126, 0.7152, 0.0722));
    vec3 graded = mix(pixel.rgb, vec3(lum), grayscale);
    graded = vec3(lum) + (graded - vec3(lum)) * saturation;
    vec3 duotone = lum <= 0.55
        ? mix(shadow.rgb, washColor.rgb, lum / 0.55)
        : mix(washColor.rgb, highlight.rgb, (lum - 0.55) / 0.45);
    vec3 outColor = mix(graded, duotone, wash);
    return vec4(outColor, pixel.a);
}
"""
