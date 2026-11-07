// Sources/Kumone/Core/Player/NomandDitherer.swift
//
// Folia nomand (漫游) background, re-implemented with Core Image.
//
// Folia renders nomand as WebGL Paper shaders over the current song's
// cover (`components/visualizer/backgrounds/nomand/`). The GLSL is
// closed-source, so every effect below is re-derived natively from the
// observed behaviour and the Folia setting names/defaults — no shader
// code is copied. A WebGL shader is not portable to SwiftUI, and writing
// a Metal shader per background is out of scope, so this port uses Core
// Image only.
//
// The five effects and what the native version does with each:
//
//   halftone-dots （半调网点）: the cover becomes a halftone-dot pattern;
//       the dots take the theme accent colour (or keep the cover's own
//       colours when `originalColors` is on), the gaps take the theme
//       background colour, and a theme-background veil at
//       `overlayOpacity` (0.35 by default) sits on top. Implemented with
//       Core Image's built-in `CIDotScreen` filter (iOS 9+), which is
//       exactly a halftone-dot filter: `inputWidth` is the dot spacing,
//       `inputSharpness` the dot hardness. The mapping from Folia's
//       tuning to the filter:
//
//         dot spacing  = 4 + (1 − size) × 24        (size 0.5 → 16px)
//         dot sharpness = clamp(radius × 0.5, 0.05, 1)  (radius 1.25 → 0.625)
//         dot contrast = 1 + contrast               (contrast 0.4 → 1.4)
//
//       The colour mapping is plain compositing, not a mask (whose
//       channel `CIBlendWithMask` reads is easy to get wrong):
//
//         originalColors = false:
//             accent dots  = accent  × inverted(dot)   (dots where the cover is dark)
//             background   = bg      × dot             (bg where the cover is light)
//             result       = accent dots + background
//         originalColors = true:
//             result       = dot × cover               (the cover darkened by the
//                                                        dot pattern; CIDotScreen
//                                                        is grayscale, so the dots
//                                                        themselves cannot keep
//                                                        the cover's colours)
//
//   dithering （像素画）: ordered Bayer-matrix dithering. The cover's
//       luminance is quantised to `colorSteps` levels against a tiled
//       Bayer threshold matrix (2×2 / 4×4 / 8×8, Folia default 8×8,
//       cell size 3px), then mapped across a three-stop palette —
//       background → accent → highlight — or, with `originalColors`,
//       the cover's own colours scaled by the quantised luminance.
//       Implemented with a `CIColorKernel` taking the cover plus a tiled
//       Bayer threshold image (built as a small grayscale `CGImage`,
//       tiled with `CIAffineTile`).
//
//   fluted-glass （纹理玻璃）: vertical fluted (ribbed) glass. The cover
//       is refracted by a vertical sinusoidal UV warp (rib spacing from
//       `size`, amplitude from `distortion`), blurred (`blur`), and
//       tinted toward the theme colours. Folia's shader also adds
//       prismatic shadows (0.25), highlights (0.1) and edge light
//       (0.25); the native version approximates all three with one
//       light vertical gradient overlay — accent at 0.10 alpha on top,
//       secondary at 0.25 alpha at the bottom — composited over the
//       warped cover. There is no separate edge-light pass; the shadow
//       end of the gradient stands in for it.
//
//   paper-texture （纸张纹理）: SIMPLIFIED approximation. Folia's Paper
//       shader layers crumples, folds and fibre grain over the cover;
//       reproducing the crumple/fold displacement field natively is out
//       of scope. What this port does: displace the cover with a
//       smooth analytic sine warp (a warp kernel returns coordinates
//       only and cannot sample a noise image, so the displacement is
//       a pure function of the destination coordinate; `roughness`
//       sets the displacement strength, up to ~5px at the Folia
//       default 0.42), add a fine fibre-grain overlay at `fiber`
//       strength, and slightly desaturate by `contrast`. No crumples,
//       no folds, no torn edges.
//
//   lens-distortion （镜头畸变）: radial warp centred on the cover —
//       `bulge` > 0 magnifies the centre, < 0 pinches it (barrel/pinch
//       by sign), fading to identity at `spread` × half the long side —
//       plus chromatic dispersion: the warped image is rendered three
//       times with slightly different warp radii (scaled by
//       `spread` × `dispersion`) and the R/G/B channels are recombined
//       (`CIColorMatrix` per channel, added). The cover is edge-clamped
//       (`CIAffineClamp`) first so the warp never samples transparent
//       pixels.
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

/// Bayer dither matrix size for the dithering effect.
enum NomandDitheringType: String, CaseIterable, Identifiable {
    /// 2×2 Bayer matrix.
    case twoByTwo = "2x2"
    /// 4×4 Bayer matrix.
    case fourByFour = "4x4"
    /// 8×8 Bayer matrix (Folia default).
    case eightByEight = "8x8"

    var id: String { rawValue }
}

/// Nomand background rendering of a cover image, per Folia's nomand
/// background. Dispatches on `Tuning.effect`; halftone-dots is the
/// default and its render is unchanged from the original port.
enum NomandDitherer {

    /// The tuning that decides what the nomand background looks like.
    /// Colours are compared by their RGBA components (not object
    /// identity) so two equal colours hash and compare equal.
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

        /// Which nomand effect to render.
        var effect: NomandEffect = .halftoneDots

        /// Dithering highlight colour (third palette stop, after
        /// background → accent). `nil` means "same as `accent`" — a
        /// stored-property default cannot reference the sibling
        /// `accent`, so the fallback lives here instead of in the
        /// declaration. Only used by dithering.
        var highlight: PlatformColor? = nil
        /// Fluted-glass shadow colour. `nil` means "same as
        /// `background`" (same Swift limitation as `highlight`).
        /// Only used by fluted-glass.
        var secondary: PlatformColor? = nil

        /// Dithering Bayer matrix size (Folia default 8×8).
        var ditheringType: NomandDitheringType = .eightByEight
        /// Dithering cell size in pixels (0.5–20, Folia default 3).
        var ditheringSize: Double = 3
        /// Dithering palette levels (1–7, Folia default 4).
        var ditheringColorSteps: Int = 4
        /// Dithering: keep the cover's own colours, quantised, instead
        /// of mapping to the background / accent / highlight palette.
        var ditheringOriginalColors: Bool = false
        /// Dithering: flip the luminance before quantising.
        var ditheringInverted: Bool = false

        /// Fluted-glass rib spacing (0.1–1): larger packs ribs tighter.
        var flutedGlassSize: Double = 0.5
        /// Fluted-glass refraction strength (0–1).
        var flutedGlassDistortion: Double = 0.5
        /// Fluted-glass blur (0–1), scaled to pixels.
        var flutedGlassBlur: Double = 0.08

        /// Paper-texture contrast (0–1): drives the desaturation.
        var paperTextureContrast: Double = 0.32
        /// Paper-texture roughness (0–1): displacement strength and
        /// noise smoothness.
        var paperTextureRoughness: Double = 0.42
        /// Paper-texture fibre grain strength (0–1).
        var paperTextureFiber: Double = 0.3

        /// Halftone: invert the dot pattern before the colour mapping.
        /// Folia's halftone baseline is flipped relative to dithering,
        /// so this is a plain inversion of the dot-screen input.
        var halftoneDotsInverted: Bool = false

        /// Lens-distortion influence radius (0–1): fraction of half the
        /// cover's long side.
        var lensDistortionSpread: Double = 0.45
        /// Lens-distortion centre magnification (−1–1): positive bulges
        /// the centre out, negative pinches it in.
        var lensDistortionBulge: Double = 0.3
        /// Lens-distortion chromatic dispersion (0–1).
        var lensDistortionDispersion: Double = 0.65

        /// Resolved dithering highlight: the explicit colour, else accent.
        var resolvedHighlight: PlatformColor { highlight ?? accent }
        /// Resolved fluted-glass shadow colour: explicit, else background.
        var resolvedSecondary: PlatformColor { secondary ?? background }

        static func == (lhs: Tuning, rhs: Tuning) -> Bool {
            lhs.size == rhs.size
                && lhs.radius == rhs.radius
                && lhs.contrast == rhs.contrast
                && lhs.originalColors == rhs.originalColors
                && rgba(lhs.accent) == rgba(rhs.accent)
                && rgba(lhs.background) == rgba(rhs.background)
                && lhs.effect == rhs.effect
                && rgba(lhs.resolvedHighlight) == rgba(rhs.resolvedHighlight)
                && rgba(lhs.resolvedSecondary) == rgba(rhs.resolvedSecondary)
                && lhs.ditheringType == rhs.ditheringType
                && lhs.ditheringSize == rhs.ditheringSize
                && lhs.ditheringColorSteps == rhs.ditheringColorSteps
                && lhs.ditheringOriginalColors == rhs.ditheringOriginalColors
                && lhs.ditheringInverted == rhs.ditheringInverted
                && lhs.flutedGlassSize == rhs.flutedGlassSize
                && lhs.flutedGlassDistortion == rhs.flutedGlassDistortion
                && lhs.flutedGlassBlur == rhs.flutedGlassBlur
                && lhs.paperTextureContrast == rhs.paperTextureContrast
                && lhs.paperTextureRoughness == rhs.paperTextureRoughness
                && lhs.paperTextureFiber == rhs.paperTextureFiber
                && lhs.halftoneDotsInverted == rhs.halftoneDotsInverted
                && lhs.lensDistortionSpread == rhs.lensDistortionSpread
                && lhs.lensDistortionBulge == rhs.lensDistortionBulge
                && lhs.lensDistortionDispersion == rhs.lensDistortionDispersion
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
            hasher.combine(effect)
            let highlightRGBA = rgba(resolvedHighlight)
            hasher.combine(highlightRGBA.r)
            hasher.combine(highlightRGBA.g)
            hasher.combine(highlightRGBA.b)
            hasher.combine(highlightRGBA.a)
            let secondaryRGBA = rgba(resolvedSecondary)
            hasher.combine(secondaryRGBA.r)
            hasher.combine(secondaryRGBA.g)
            hasher.combine(secondaryRGBA.b)
            hasher.combine(secondaryRGBA.a)
            hasher.combine(ditheringType)
            hasher.combine(ditheringSize)
            hasher.combine(ditheringColorSteps)
            hasher.combine(ditheringOriginalColors)
            hasher.combine(ditheringInverted)
            hasher.combine(flutedGlassSize)
            hasher.combine(flutedGlassDistortion)
            hasher.combine(flutedGlassBlur)
            hasher.combine(paperTextureContrast)
            hasher.combine(paperTextureRoughness)
            hasher.combine(paperTextureFiber)
            hasher.combine(halftoneDotsInverted)
            hasher.combine(lensDistortionSpread)
            hasher.combine(lensDistortionBulge)
            hasher.combine(lensDistortionDispersion)
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

    /// Cache key for a render: song id + effect + every tuning value +
    /// colours, so a settings tweak re-renders.
    static func cacheKey(songID: String?, tuning: Tuning) -> String {
        let accent = rgba(tuning.accent)
        let background = rgba(tuning.background)
        let highlight = rgba(tuning.resolvedHighlight)
        let secondary = rgba(tuning.resolvedSecondary)
        return [
            songID ?? "",
            tuning.effect.rawValue,
            String(format: "%.3f", tuning.size),
            String(format: "%.3f", tuning.radius),
            String(format: "%.3f", tuning.contrast),
            tuning.originalColors ? "orig" : "mapped",
            String(format: "%.3f,%.3f,%.3f,%.3f", accent.r, accent.g, accent.b, accent.a),
            String(format: "%.3f,%.3f,%.3f,%.3f", background.r, background.g, background.b, background.a),
            String(format: "%.3f,%.3f,%.3f,%.3f", highlight.r, highlight.g, highlight.b, highlight.a),
            String(format: "%.3f,%.3f,%.3f,%.3f", secondary.r, secondary.g, secondary.b, secondary.a),
            tuning.ditheringType.rawValue,
            String(format: "%.3f", tuning.ditheringSize),
            String(tuning.ditheringColorSteps),
            tuning.ditheringOriginalColors ? "dorig" : "dmapped",
            tuning.ditheringInverted ? "dinv" : "dnoinv",
            String(format: "%.3f", tuning.flutedGlassSize),
            String(format: "%.3f", tuning.flutedGlassDistortion),
            String(format: "%.3f", tuning.flutedGlassBlur),
            String(format: "%.3f", tuning.paperTextureContrast),
            String(format: "%.3f", tuning.paperTextureRoughness),
            String(format: "%.3f", tuning.paperTextureFiber),
            tuning.halftoneDotsInverted ? "hinv" : "hnoinv",
            String(format: "%.3f", tuning.lensDistortionSpread),
            String(format: "%.3f", tuning.lensDistortionBulge),
            String(format: "%.3f", tuning.lensDistortionDispersion),
        ].joined(separator: "|")
    }

    private static let cache = NSCache<NSString, PlatformImage>()
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// The nomand image for a cover, or `nil` when it cannot be rendered.
    /// Call from a background queue — a full-cover filter is not cheap.
    /// Results are cached, so repeated calls with the same key are free.
    /// The name is kept for the existing call site (`NomandBackgroundView`);
    /// the effect rendered is `tuning.effect`.
    static func halftoneImage(for cover: PlatformImage, songID: String?, tuning: Tuning) -> PlatformImage? {
        let key = cacheKey(songID: songID, tuning: tuning)
        if let cached = cache.object(forKey: key as NSString) { return cached }
        let rendered: PlatformImage?
        switch tuning.effect {
        case .halftoneDots:
            rendered = render(cover: cover, tuning: tuning)
        case .dithering:
            rendered = renderDithering(cover: cover, tuning: tuning)
        case .flutedGlass:
            rendered = renderFlutedGlass(cover: cover, tuning: tuning)
        case .paperTexture:
            rendered = renderPaperTexture(cover: cover, tuning: tuning)
        case .lensDistortion:
            rendered = renderLensDistortion(cover: cover, tuning: tuning)
        }
        guard let rendered else { return nil }
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
    /// SwiftUI `Image`) applies the orientation, so the nomand render
    /// must too.
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

    /// Downscaled cover (capped at ~1024px on the long side, like the
    /// halftone path) plus its extent and source scale, shared by the
    /// non-halftone effects.
    private static func preparedCover(_ cover: PlatformImage) -> (ciCover: CIImage, extent: CGRect, scale: CGFloat)? {
        guard let source = sourceImage(cover) else { return nil }
        let cgImage = source.cgImage
        // Cap the render at ~1024px on the long side: the nomand image
        // is a background, and a full-resolution filter is pure waste.
        let maxSide: CGFloat = 1024
        let scale = min(1, maxSide / max(CGFloat(cgImage.width), CGFloat(cgImage.height)))
        var ciCover = CIImage(cgImage: cgImage)
        if scale < 1 {
            ciCover = ciCover.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return (ciCover, ciCover.extent, source.scale)
    }

    /// Render a `CIImage` back to a `PlatformImage` at the source's scale.
    private static func platformImage(from ciImage: CIImage, extent: CGRect, scale: CGFloat) -> PlatformImage? {
        guard let output = context.createCGImage(ciImage, from: extent) else { return nil }
        #if os(iOS)
        return UIImage(cgImage: output, scale: scale, orientation: .up)
        #else
        return NSImage(cgImage: output, size: NSSize(width: CGFloat(output.width), height: CGFloat(output.height)))
        #endif
    }

    // MARK: Halftone dots

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

        // `halftoneDotsInverted`: Folia's halftone baseline is flipped
        // relative to dithering, so invert the dot pattern itself before
        // the colour mapping. Off by default — existing tunings render
        // exactly as before.
        if tuning.halftoneDotsInverted {
            let invert = CIFilter(name: "CIColorInvert")
            invert?.setValue(dots, forKey: kCIInputImageKey)
            if let inverted = invert?.outputImage { dots = inverted }
        }

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

    // MARK: Dithering

    /// Bayer threshold values in row-major order for a matrix size.
    private static func bayerMatrix(for type: NomandDitheringType) -> (values: [Int], size: Int) {
        switch type {
        case .twoByTwo:
            return ([0, 2, 3, 1], 2)
        case .fourByFour:
            return ([
                0, 8, 2, 10,
                12, 4, 14, 6,
                3, 11, 1, 9,
                15, 7, 13, 5,
            ], 4)
        case .eightByEight:
            return ([
                0, 32, 8, 40, 2, 34, 10, 42,
                48, 16, 56, 24, 50, 18, 58, 26,
                12, 44, 4, 36, 14, 46, 6, 38,
                60, 28, 52, 20, 62, 30, 54, 22,
                3, 35, 11, 43, 1, 33, 9, 41,
                51, 19, 59, 27, 49, 17, 57, 25,
                15, 47, 7, 39, 13, 45, 5, 37,
                63, 31, 55, 23, 61, 29, 53, 21,
            ], 8)
        }
    }

    /// The Bayer threshold pattern as a small grayscale `CIImage`
    /// (threshold = (value + 0.5) / count, so it sits mid-step).
    private static func bayerThresholdImage(for type: NomandDitheringType) -> CIImage? {
        let (values, n) = bayerMatrix(for: type)
        let count = n * n
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            bytes[i] = UInt8((Double(values[i]) + 0.5) / Double(count) * 255.0)
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                width: n, height: n,
                bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: n,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: 0),
                provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return CIImage(cgImage: cgImage)
    }

    /// Ordered-dither kernel: quantise the cover luminance to `steps`
    /// levels against the tiled Bayer threshold, then map across the
    /// background → accent → highlight palette (or scale the cover's own
    /// colours by the quantised luminance when `original` is on).
    /// `steps` = 1 is a plain threshold (`lum >= t ? 1 : 0`).
    private static let ditherKernel: CIColorKernel? = CIColorKernel(source:
        """
        kernel vec4 ditherKernel(__sample cover, __sample threshold, vec3 bg, vec3 front, vec3 high, float steps, float inverted, float original) {
            float lum = dot(cover.rgb, vec3(0.299, 0.587, 0.114));
            if (inverted > 0.5) { lum = 1.0 - lum; }
            float t = threshold.r;
            float levels = max(steps, 1.0);
            float q;
            if (levels < 1.5) {
                q = step(t, lum);
            } else {
                q = floor(lum * (levels - 1.0) + t) / (levels - 1.0);
            }
            vec3 col;
            if (original > 0.5) {
                col = cover.rgb * q;
            } else if (q < 0.5) {
                col = mix(bg, front, q * 2.0);
            } else {
                col = mix(front, high, (q - 0.5) * 2.0);
            }
            return vec4(col, cover.a);
        }
        """
    )

    private static func renderDithering(cover: PlatformImage, tuning: Tuning) -> PlatformImage? {
        guard let prepared = preparedCover(cover),
              let threshold = bayerThresholdImage(for: tuning.ditheringType),
              let kernel = ditherKernel else { return nil }
        let (ciCover, extent, scale) = prepared

        // Scale the threshold pattern so one Bayer cell is
        // `ditheringSize` pixels, then tile it over the whole extent.
        let scaledThreshold = threshold.transformed(
            by: CGAffineTransform(scaleX: CGFloat(tuning.ditheringSize), y: CGFloat(tuning.ditheringSize)))
        let tile = CIFilter(name: "CIAffineTile")
        tile?.setValue(scaledThreshold, forKey: kCIInputImageKey)
        tile?.setValue(CGAffineTransform.identity, forKey: kCIInputTransformKey)
        guard let tiledThreshold = tile?.outputImage else { return nil }

        let bg = rgba(tuning.background)
        let front = rgba(tuning.accent)
        let high = rgba(tuning.resolvedHighlight)
        guard let result = kernel.apply(
            extent: extent,
            roiCallback: { _, rect in rect },
            arguments: [
                ciCover,
                tiledThreshold,
                CIVector(x: bg.r, y: bg.g, z: bg.b),
                CIVector(x: front.r, y: front.g, z: front.b),
                CIVector(x: high.r, y: high.g, z: high.b),
                NSNumber(value: tuning.ditheringColorSteps),
                NSNumber(value: tuning.ditheringInverted ? 1.0 : 0.0),
                NSNumber(value: tuning.ditheringOriginalColors ? 1.0 : 0.0),
            ])
        else { return nil }
        return platformImage(from: result.cropped(to: extent), extent: extent, scale: scale)
    }

    // MARK: Fluted glass

    /// Vertical sinusoidal refraction: vertical ribs refract the cover
    /// horizontally, the offset varying sinusoidally across x.
    private static let flutedGlassWarpKernel: CIWarpKernel? = CIWarpKernel(source:
        """
        kernel vec2 flutedWarp(vec2 dest, float ribPeriod, float amplitude) {
            float offset = sin(dest.x / ribPeriod * 6.2831853) * amplitude;
            return dest + vec2(offset, 0.0);
        }
        """
    )

    private static func renderFlutedGlass(cover: PlatformImage, tuning: Tuning) -> PlatformImage? {
        guard let prepared = preparedCover(cover),
              let kernel = flutedGlassWarpKernel else { return nil }
        let (ciCover, extent, scale) = prepared

        // Rib spacing: larger `size` packs the ribs tighter (same
        // direction as the halftone size mapping); the refraction
        // amplitude is at most half a rib period.
        let ribPeriod = 8 + (1 - tuning.flutedGlassSize) * 56
        let amplitude = tuning.flutedGlassDistortion * ribPeriod * 0.5
        guard var result = kernel.apply(
            extent: extent,
            roiCallback: { _, rect in rect.insetBy(dx: -CGFloat(amplitude), dy: 0) },
            arguments: [ciCover, NSNumber(value: ribPeriod), NSNumber(value: amplitude)])
        else { return nil }

        // Blur: Folia's blur param (0–1) scaled to pixels.
        let blurRadius = tuning.flutedGlassBlur * 24
        if blurRadius > 0.01 {
            let blur = CIFilter(name: "CIGaussianBlur")
            blur?.setValue(result, forKey: kCIInputImageKey)
            blur?.setValue(blurRadius, forKey: kCIInputRadiusKey)
            if let blurred = blur?.outputImage { result = blurred.cropped(to: extent) }
        }

        // Prismatic edge/highlight approximation (see the file header):
        // one light vertical gradient — accent at Folia's highlight
        // strength (0.1) on top, secondary at its shadow strength
        // (0.25) at the bottom — composited over the warped cover. The
        // edge-light constant (0.25) has no separate pass; the shadow
        // end of the gradient stands in for it.
        let accent = rgba(tuning.accent)
        let secondary = rgba(tuning.resolvedSecondary)
        let gradient = CIFilter(name: "CILinearGradient")
        gradient?.setValue(CIVector(x: extent.midX, y: extent.maxY), forKey: "inputPoint0")
        gradient?.setValue(CIVector(x: extent.midX, y: extent.minY), forKey: "inputPoint1")
        gradient?.setValue(CIColor(red: accent.r, green: accent.g, blue: accent.b, alpha: 0.10), forKey: "inputColor0")
        gradient?.setValue(CIColor(red: secondary.r, green: secondary.g, blue: secondary.b, alpha: 0.25), forKey: "inputColor1")
        if let gradientImage = gradient?.outputImage?.cropped(to: extent) {
            let over = CIFilter(name: "CISourceOverCompositing")
            over?.setValue(gradientImage, forKey: kCIInputImageKey)
            over?.setValue(result, forKey: kCIInputBackgroundImageKey)
            if let composited = over?.outputImage { result = composited.cropped(to: extent) }
        }

        return platformImage(from: result, extent: extent, scale: scale)
    }

    // MARK: Paper texture

    /// Smooth analytic displacement: two low-frequency sine fields
    /// whose phase is itself modulated, so the warp undulates slowly
    /// like paper grain instead of repeating a grid. A warp kernel
    /// returns coordinates only — it cannot sample an image — so the
    /// displacement must be a pure function of `dest`, not a noise
    /// texture (an earlier draft sampled a blurred-noise image here;
    /// that cannot compile as a warp kernel).
    private static let paperWarpKernel: CIWarpKernel? = CIWarpKernel(source:
        """
        kernel vec2 paperWarp(vec2 dest, float amount) {
            vec2 d = dest * 0.004;
            float ox = sin(d.y * 3.1 + sin(d.x * 1.7) * 2.0);
            float oy = cos(d.x * 2.3 + sin(d.y * 1.3) * 2.0);
            return dest + vec2(ox, oy) * amount;
        }
        """
    )

    /// Fine fibre grain: high-frequency noise, desaturated to gray, at
    /// low alpha set by `strength`.
    private static func fibreGrain(extent: CGRect, strength: Double) -> CIImage? {
        guard strength > 0.01 else { return nil }
        guard let random = CIFilter(name: "CIRandomGenerator")?.outputImage else { return nil }
        let blur = CIFilter(name: "CIGaussianBlur")
        blur?.setValue(random, forKey: kCIInputImageKey)
        blur?.setValue(1.0, forKey: kCIInputRadiusKey)
        guard let blurred = blur?.outputImage else { return nil }
        let matrix = CIFilter(name: "CIColorMatrix")
        matrix?.setValue(blurred, forKey: kCIInputImageKey)
        matrix?.setValue(CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0), forKey: "inputRVector")
        matrix?.setValue(CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0), forKey: "inputGVector")
        matrix?.setValue(CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0), forKey: "inputBVector")
        matrix?.setValue(CIVector(x: 0, y: 0, z: 0, w: strength * 0.35), forKey: "inputAVector")
        return matrix?.outputImage?.cropped(to: extent)
    }

    private static func renderPaperTexture(cover: PlatformImage, tuning: Tuning) -> PlatformImage? {
        guard let prepared = preparedCover(cover),
              let kernel = paperWarpKernel else { return nil }
        let (ciCover, extent, scale) = prepared

        // Displacement: roughness sets the strength (up to ~5px at
        // the Folia default 0.42). The warp itself is analytic — see
        // paperWarpKernel — so there is no noise image to build here.
        let displacement = tuning.paperTextureRoughness * 12
        // For a warp kernel the first argument is the image being
        // warped; the kernel's own parameters follow in order.
        guard var warped = kernel.apply(
            extent: extent,
            roiCallback: { _, rect in
                rect.insetBy(dx: -CGFloat(displacement), dy: -CGFloat(displacement))
            },
            arguments: [ciCover, NSNumber(value: displacement)])
        else { return nil }

        // Slight desaturation by contrast.
        let saturation = 1 - tuning.paperTextureContrast * 0.35
        let controls = CIFilter(name: "CIColorControls")
        controls?.setValue(warped, forKey: kCIInputImageKey)
        controls?.setValue(saturation, forKey: kCIInputSaturationKey)
        if let desaturated = controls?.outputImage { warped = desaturated }

        // Fibre grain overlay on top.
        if let grain = fibreGrain(extent: extent, strength: tuning.paperTextureFiber) {
            let over = CIFilter(name: "CISourceOverCompositing")
            over?.setValue(grain, forKey: kCIInputImageKey)
            over?.setValue(warped, forKey: kCIInputBackgroundImageKey)
            if let composited = over?.outputImage { warped = composited.cropped(to: extent) }
        }

        return platformImage(from: warped.cropped(to: extent), extent: extent, scale: scale)
    }

    // MARK: Lens distortion

    /// Radial warp around `center`: inside `radius` the source
    /// coordinate is pulled toward the centre by `bulge` (positive =
    /// magnification, negative = pinch), fading quadratically to
    /// identity at the radius. Branchless so a zero radius is safe
    /// (the falloff is 0 everywhere, the warp is the identity).
    private static let lensWarpKernel: CIWarpKernel? = CIWarpKernel(source:
        """
        kernel vec2 lensWarp(vec2 dest, vec2 center, float radius, float bulge) {
            vec2 d = dest - center;
            float rn = length(d) / radius;
            float falloff = max(0.0, 1.0 - rn * rn);
            float s = 1.0 - bulge * falloff;
            return center + d * s;
        }
        """
    )

    private static func renderLensDistortion(cover: PlatformImage, tuning: Tuning) -> PlatformImage? {
        guard let prepared = preparedCover(cover),
              let kernel = lensWarpKernel else { return nil }
        let (ciCover, extent, scale) = prepared

        // No spread means no distortion: skip the warp entirely (and
        // keep a zero radius out of the kernel's division).
        let radius = tuning.lensDistortionSpread * 0.5 * max(extent.width, extent.height)
        guard radius >= 1 else {
            return platformImage(from: ciCover, extent: extent, scale: scale)
        }

        // Clamp the edges so the warp never samples transparent pixels
        // (a pinch samples outside the extent near the edges).
        let clamp = CIFilter(name: "CIAffineClamp")
        clamp?.setValue(ciCover, forKey: kCIInputImageKey)
        clamp?.setValue(CGAffineTransform.identity, forKey: kCIInputTransformKey)
        guard let clamped = clamp?.outputImage else { return nil }

        let center = CIVector(x: extent.midX, y: extent.midY)
        // Chromatic dispersion: the R and B passes use slightly
        // different warp radii (scaled by spread × dispersion).
        let delta = tuning.lensDistortionSpread * tuning.lensDistortionDispersion * 0.08

        func warped(radiusScale: Double) -> CIImage? {
            kernel.apply(
                extent: extent,
                roiCallback: { _, rect in rect.insetBy(dx: -CGFloat(radius), dy: -CGFloat(radius)) },
                arguments: [
                    clamped,
                    center,
                    NSNumber(value: radius * radiusScale),
                    NSNumber(value: tuning.lensDistortionBulge),
                ])
        }

        guard let red = warped(radiusScale: 1 + delta),
              let green = warped(radiusScale: 1),
              let blue = warped(radiusScale: 1 - delta) else { return nil }

        /// Keep one colour channel of `image`, zeroing the other two
        /// (alpha untouched, so the three passes add cleanly).
        func channel(_ image: CIImage, keepRed: Bool, keepGreen: Bool, keepBlue: Bool) -> CIImage? {
            let matrix = CIFilter(name: "CIColorMatrix")
            matrix?.setValue(image, forKey: kCIInputImageKey)
            matrix?.setValue(CIVector(x: keepRed ? 1 : 0, y: 0, z: 0, w: 0), forKey: "inputRVector")
            matrix?.setValue(CIVector(x: 0, y: keepGreen ? 1 : 0, z: 0, w: 0), forKey: "inputGVector")
            matrix?.setValue(CIVector(x: 0, y: 0, z: keepBlue ? 1 : 0, w: 0), forKey: "inputBVector")
            matrix?.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            return matrix?.outputImage
        }

        guard let rOnly = channel(red, keepRed: true, keepGreen: false, keepBlue: false),
              let gOnly = channel(green, keepRed: false, keepGreen: true, keepBlue: false),
              let bOnly = channel(blue, keepRed: false, keepGreen: false, keepBlue: true) else { return nil }
        let addRG = CIFilter(name: "CIAdditionCompositing")
        addRG?.setValue(rOnly, forKey: kCIInputImageKey)
        addRG?.setValue(gOnly, forKey: kCIInputBackgroundImageKey)
        guard let rg = addRG?.outputImage else { return nil }
        let addRGB = CIFilter(name: "CIAdditionCompositing")
        addRGB?.setValue(rg, forKey: kCIInputImageKey)
        addRGB?.setValue(bOnly, forKey: kCIInputBackgroundImageKey)
        guard let result = addRGB?.outputImage else { return nil }
        return platformImage(from: result.cropped(to: extent), extent: extent, scale: scale)
    }
}
