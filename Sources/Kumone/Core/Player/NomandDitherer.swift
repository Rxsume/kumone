// Sources/Kumone/Core/Player/NomandDitherer.swift
//
// Folia nomand (漫游) background, re-implemented with Core Image.
//
// Folia renders nomand as a WebGL HalftoneDots shader over the current
// song's cover (`components/visualizer/backgrounds/nomand/`): the cover
// is turned into a halftone-dot pattern, the dots take the theme accent
// colour (or keep the cover's own colours when `originalColors` is on),
// the gaps take the theme background colour, and a theme-background veil
// at `overlayOpacity` (0.35 by default) sits on top.
//
// A WebGL shader is not portable to SwiftUI, and writing a Metal shader
// for one background is out of scope — so this port uses Core Image's
// built-in `CIDotScreen` filter (iOS 9+), which is exactly a halftone-dot
// filter: `inputWidth` is the dot spacing, `inputSharpness` the dot
// hardness. The mapping from Folia's tuning to the filter:
//
//   dot spacing  = 4 + (1 − size) × 24        (size 0.5 → 16px)
//   dot sharpness = clamp(radius × 0.5, 0.05, 1)  (radius 1.25 → 0.625)
//   dot contrast = 1 + contrast               (contrast 0.4 → 1.4)
//
// The colour mapping is plain compositing, not a mask (whose channel
// `CIBlendWithMask` reads is easy to get wrong):
//
//   originalColors = false:
//       accent dots  = accent  × inverted(dot)   (dots where the cover is dark)
//       background   = bg      × dot             (bg where the cover is light)
//       result       = accent dots + background
//   originalColors = true:
//       result       = dot × cover               (the cover darkened by the
//                                                  dot pattern; CIDotScreen
//                                                  is grayscale, so the dots
//                                                  themselves cannot keep
//                                                  the cover's colours)
//
// Rendering a full-cover filter is done once per track on a background
// queue (never the main thread) and the result is cached by song id +
// tuning + colours, so a track change costs one render and a settings
// tweak only re-renders when a tuning value actually changed.

import CoreImage
import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Halftone-dot rendering of a cover image, per Folia's nomand background.
enum NomandDitherer {

    /// The tuning that decides what the halftone looks like. Colours are
    /// compared by their RGBA components (not object identity) so two
    /// equal colours hash and compare equal.
    struct Tuning: Hashable {
        /// Halftone dot size (0.1–1): larger values pack the dots tighter.
        var size: Double = 0.5
        /// Halftone dot radius (0.1–2): larger values make harder dots.
        var radius: Double = 1.25
        /// Halftone contrast (0–1): how hard the dot pattern cuts.
        var contrast: Double = 0.4
        /// Keep the cover's own colours instead of mapping to accent / bg.
        var originalColors: Bool = false
        /// Dot colour when `originalColors` is off.
        var accent: PlatformColor
        /// Gap colour when `originalColors` is off.
        var background: PlatformColor

        static func == (lhs: Tuning, rhs: Tuning) -> Bool {
            lhs.size == rhs.size
                && lhs.radius == rhs.radius
                && lhs.contrast == rhs.contrast
                && lhs.originalColors == rhs.originalColors
                && rgba(lhs.accent) == rgba(rhs.accent)
                && rgba(lhs.background) == rgba(rhs.background)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(size)
            hasher.combine(radius)
            hasher.combine(contrast)
            hasher.combine(originalColors)
            // Tuples are not Hashable: combine the four components
            // one by one instead of the tuple itself.
            let accentRGBA = rgba(accent)
            hasher.combine(accentRGBA.r)
            hasher.combine(accentRGBA.g)
            hasher.combine(accentRGBA.b)
            hasher.combine(accentRGBA.a)
            let backgroundRGBA = rgba(background)
            hasher.combine(backgroundRGBA.r)
            hasher.combine(backgroundRGBA.g)
            hasher.combine(backgroundRGBA.b)
            hasher.combine(backgroundRGBA.a)
        }
    }

    /// RGBA components of a platform colour, for hashing, cache keys and
    /// building solid-colour `CIImage`s.
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

    /// Dot spacing in pixels for a `size` (0.1–1).
    static func dotSpacing(for size: Double) -> Double {
        4 + (1 - size) * 24
    }

    /// `CIDotScreen` sharpness for a `radius` (0.1–2).
    static func dotSharpness(for radius: Double) -> Double {
        min(max(radius * 0.5, 0.05), 1)
    }

    /// `CIColorControls` contrast for a Folia `contrast` (0–1).
    static func contrastValue(for contrast: Double) -> Double {
        1 + contrast
    }

    /// Cache key for a render: song id + tuning + colours.
    static func cacheKey(songID: String?, tuning: Tuning) -> String {
        let accent = rgba(tuning.accent)
        let background = rgba(tuning.background)
        return [
            songID ?? "",
            String(format: "%.3f", tuning.size),
            String(format: "%.3f", tuning.radius),
            String(format: "%.3f", tuning.contrast),
            tuning.originalColors ? "orig" : "mapped",
            String(format: "%.3f,%.3f,%.3f,%.3f", accent.r, accent.g, accent.b, accent.a),
            String(format: "%.3f,%.3f,%.3f,%.3f", background.r, background.g, background.b, background.a),
        ].joined(separator: "|")
    }

    private static let cache = NSCache<NSString, PlatformImage>()
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// The halftone image for a cover, or `nil` when it cannot be rendered.
    /// Call from a background queue — a full-cover filter is not cheap.
    /// Results are cached, so repeated calls with the same key are free.
    static func halftoneImage(for cover: PlatformImage, songID: String?, tuning: Tuning) -> PlatformImage? {
        let key = cacheKey(songID: songID, tuning: tuning)
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard let rendered = render(cover: cover, tuning: tuning) else { return nil }
        cache.setObject(rendered, forKey: key as NSString)
        return rendered
    }

    static func clearCache() {
        cache.removeAllObjects()
    }

    // MARK: - Rendering

    /// The cover as a correctly oriented `CGImage` plus its scale.
    /// `cgImageRef` is the raw bitmap, so a cover whose EXIF orientation
    /// is not `.up` would come out rotated — the displayed cover (via
    /// SwiftUI `Image`) applies the orientation, so the halftone must too.
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

    private static func render(cover: PlatformImage, tuning: Tuning) -> PlatformImage? {
        guard let source = sourceImage(cover) else { return nil }
        let cgImage = source.cgImage
        // Cap the render at ~1024px on the long side: the halftone is a
        // background, and a full-resolution filter is pure waste.
        let maxSide: CGFloat = 1024
        let scale = min(1, maxSide / max(CGFloat(cgImage.width), CGFloat(cgImage.height)))
        var ciCover = CIImage(cgImage: cgImage)
        if scale < 1 {
            ciCover = ciCover.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let extent = ciCover.extent

        let dotScreen = CIFilter(name: "CIDotScreen")
        dotScreen?.setValue(ciCover, forKey: kCIInputImageKey)
        dotScreen?.setValue(dotSpacing(for: tuning.size), forKey: kCIInputWidthKey)
        dotScreen?.setValue(0, forKey: kCIInputAngleKey)
        dotScreen?.setValue(dotSharpness(for: tuning.radius), forKey: kCIInputSharpnessKey)
        guard var dots = dotScreen?.outputImage else { return nil }

        let contrast = CIFilter(name: "CIColorControls")
        contrast?.setValue(dots, forKey: kCIInputImageKey)
        contrast?.setValue(contrastValue(for: tuning.contrast), forKey: kCIInputContrastKey)
        if let contrasted = contrast?.outputImage { dots = contrasted }

        let result: CIImage
        if tuning.originalColors {
            // The cover darkened by the dot pattern (see the file header:
            // CIDotScreen is grayscale, so the dots cannot keep colour).
            let multiply = CIFilter(name: "CIMultiplyCompositing")
            multiply?.setValue(dots, forKey: kCIInputImageKey)
            multiply?.setValue(ciCover, forKey: kCIInputBackgroundImageKey)
            guard let multiplied = multiply?.outputImage else { return nil }
            result = multiplied.cropped(to: extent)
        } else {
            let accent = rgba(tuning.accent)
            let background = rgba(tuning.background)
            let accentSolid = CIImage(color: CIColor(red: accent.r, green: accent.g, blue: accent.b, alpha: accent.a))
                .cropped(to: extent)
            let bgSolid = CIImage(color: CIColor(red: background.r, green: background.g, blue: background.b, alpha: background.a))
                .cropped(to: extent)
            let inverted = CIFilter(name: "CIColorInvert")
            inverted?.setValue(dots, forKey: kCIInputImageKey)
            guard let invertedDots = inverted?.outputImage else { return nil }

            let accentDots = CIFilter(name: "CIMultiplyCompositing")
            accentDots?.setValue(invertedDots, forKey: kCIInputImageKey)
            accentDots?.setValue(accentSolid, forKey: kCIInputBackgroundImageKey)
            let bgGaps = CIFilter(name: "CIMultiplyCompositing")
            bgGaps?.setValue(dots, forKey: kCIInputImageKey)
            bgGaps?.setValue(bgSolid, forKey: kCIInputBackgroundImageKey)
            guard let accentLayer = accentDots?.outputImage,
                  let bgLayer = bgGaps?.outputImage else { return nil }
            let add = CIFilter(name: "CIAdditionCompositing")
            add?.setValue(accentLayer, forKey: kCIInputImageKey)
            add?.setValue(bgLayer, forKey: kCIInputBackgroundImageKey)
            guard let added = add?.outputImage else { return nil }
            result = added.cropped(to: extent)
        }

        guard let output = context.createCGImage(result, from: extent) else { return nil }
        #if os(iOS)
        return UIImage(cgImage: output, scale: source.scale, orientation: .up)
        #else
        return NSImage(cgImage: output, size: NSSize(width: CGFloat(output.width), height: CGFloat(output.height)))
        #endif
    }
}
