// Sources/Kumone/DesignSystem/BeansCoverPalette.swift
//
// Beans player-page palette (ported from Beans-Music `CoverPalette.swift`):
// dominant-cover extraction by hue-bucket clustering, then a full
// player-page palette derived from it in HSL space — background
// gradient, control accent, text and secondary colours all follow the
// cover, Apple Music style.
//
// This complements Golia's `ArtworkColors` (two-colour HSB extraction
// used by the Folia backgrounds): the Beans palette is what the Beans
// player page itself renders with — the blurred-cover gradient, the
// ambient glow, the progress bar and the transport accents.
//
// Shared code (CoreGraphics + SwiftUI only): no UIKit, no AppKit, so it
// compiles for both targets. The extractor works on the raw `CGImage`
// (via `PlatformImage.cgImageRef`), the same way `ArtworkPalette` does.

import CoreGraphics
import SwiftUI

/// 0~1 RGB colour, with the HSL round-trip Beans derives its palette with.
struct BeansRGBColor: Equatable {
    var r: Double
    var g: Double
    var b: Double

    var color: Color { Color(red: r, green: g, blue: b) }

    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    var isDark: Bool { luminance < 0.5 }

    func toHSL() -> (h: Double, s: Double, l: Double) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        var h: Double = 0
        if delta > 0 {
            if maxC == r {
                h = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == g {
                h = 60 * ((b - r) / delta + 2)
            } else {
                h = 60 * ((r - g) / delta + 4)
            }
        }
        if h < 0 { h += 360 }
        let l = (maxC + minC) / 2
        let s = delta == 0 ? 0 : delta / (1 - abs(2 * l - 1))
        return (h, s, l)
    }

    static func fromHSL(h: Double, s: Double, l: Double) -> BeansRGBColor {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = h / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double)
        switch Int(hp) {
        case 0: (r1, g1, b1) = (c, x, 0)
        case 1: (r1, g1, b1) = (x, c, 0)
        case 2: (r1, g1, b1) = (0, c, x)
        case 3: (r1, g1, b1) = (0, x, c)
        case 4: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        let m = l - c / 2
        return BeansRGBColor(r: r1 + m, g: g1 + m, b: b1 + m)
    }

    func withSaturation(_ s: Double) -> BeansRGBColor {
        let hsl = toHSL()
        return BeansRGBColor.fromHSL(h: hsl.h, s: s, l: hsl.l)
    }

    func withLightness(_ l: Double) -> BeansRGBColor {
        let hsl = toHSL()
        return BeansRGBColor.fromHSL(h: hsl.h, s: hsl.s, l: l)
    }
}

/// The full Beans player-page palette, all derived from one dominant colour.
struct BeansCoverPalette {
    var backgroundTop: Color
    var backgroundBottom: Color
    var accent: Color
    var accentSoft: Color
    var text: Color
    var secondary: Color
    var glassTint: Color

    /// No cover / extraction failed: fall back to the neutral artwork
    /// colours with the fixed theme accent, so every scene stays readable.
    static func fallback(colorScheme: ColorScheme) -> BeansCoverPalette {
        let accent = Theme.accent
        return BeansCoverPalette(
            backgroundTop: ArtworkColors.fallback.primary,
            backgroundBottom: ArtworkColors.fallback.secondary,
            accent: accent,
            accentSoft: accent.opacity(0.28),
            text: .white,
            secondary: .white.opacity(0.66),
            glassTint: accent
        )
    }

    /// Build the palette from the cover's dominant colour: background
    /// desaturated (fits large areas), accent saturated (buttons /
    /// progress / highlight), text black-or-white by background luminance.
    /// The player page always renders dark (`.preferredColorScheme(.dark)`),
    /// so callers pass `.dark`.
    static func make(dominant: BeansRGBColor?, colorScheme: ColorScheme) -> BeansCoverPalette {
        guard let c = dominant else { return fallback(colorScheme: colorScheme) }
        let dark = colorScheme == .dark

        let bgBase = c.withSaturation(dark ? 0.26 : 0.32)
        let bgTop = bgBase.withLightness(dark ? 0.20 : 0.74)
        let bgBottom = bgBase.withLightness(dark ? 0.08 : 0.56)

        let accentRGB = c.withSaturation(dark ? 0.68 : 0.62).withLightness(dark ? 0.72 : 0.50)
        let accent = accentRGB.color

        let text: Color = bgTop.luminance > 0.52
            ? Color(red: 0.11, green: 0.11, blue: 0.13)
            : Color(red: 0.98, green: 0.98, blue: 0.99)

        return BeansCoverPalette(
            backgroundTop: bgTop.color,
            backgroundBottom: bgBottom.color,
            accent: accent,
            accentSoft: accent.opacity(0.26),
            text: text,
            secondary: text.opacity(0.66),
            glassTint: accent
        )
    }
}

/// Dominant-colour extraction (Beans' `PaletteExtractor`): shrink the
/// cover to 48x48, cluster pixels into 16 hue buckets, take the biggest
/// cluster's weighted average. Pure CPU, one pass per artwork — results
/// are cached by key, like `ArtworkPalette.extract`.
enum BeansPaletteExtractor {
    private static var cache: [String: BeansRGBColor] = [:]

    /// Cached dominant colour for an artwork image, or nil when the image
    /// has no usable pixels. Only successful extractions are cached.
    static func dominantColor(from image: PlatformImage, cacheKey: String) -> BeansRGBColor? {
        if let cached = cache[cacheKey] {
            return cached
        }
        guard let cgImage = image.cgImageRef,
              let dominant = dominantColor(in: cgImage) else {
            return nil
        }
        if cache.count > 200 { cache.removeAll() }
        cache[cacheKey] = dominant
        return dominant
    }

    /// The raw extraction, without caching. Exposed for tests.
    static func dominantColor(in cgImage: CGImage) -> BeansRGBColor? {
        let size = 48
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(
            data: &pixels, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        var buckets = Array(repeating: (count: 0, r: 0.0, g: 0.0, b: 0.0), count: 16)
        for i in 0..<(size * size) {
            let off = i * 4
            let a = Double(pixels[off + 3]) / 255
            guard a > 0.85 else { continue }
            let r = Double(pixels[off]) / 255
            let g = Double(pixels[off + 1]) / 255
            let b = Double(pixels[off + 2]) / 255
            let hsl = BeansRGBColor(r: r, g: g, b: b).toHSL()
            // Filter pure black / pure white / near-black pixels so they
            // cannot pollute the dominant colour.
            guard hsl.l > 0.09, hsl.l < 0.93 else { continue }
            let bucket = min(15, Int(hsl.h / 360 * 16))
            let weight = 0.30 + hsl.s * 0.70
            buckets[bucket].count += 1
            buckets[bucket].r += r * weight
            buckets[bucket].g += g * weight
            buckets[bucket].b += b * weight
        }
        guard let best = buckets.max(by: { $0.count < $1.count }), best.count > 0 else { return nil }
        let n = Double(best.count)
        return BeansRGBColor(r: best.r / n, g: best.g / n, b: best.b / n)
    }
}
