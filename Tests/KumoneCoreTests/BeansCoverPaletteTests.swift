import CoreGraphics
import SwiftUI
import Testing
@testable import KumoneCore

/// Coverage for the Beans player-page palette (`BeansCoverPalette`):
/// HSL round-trip, dominant-colour extraction on synthetic artwork,
/// palette derivation and fallback. Pure logic — no UI, no network.
@Suite("Beans cover palette")
struct BeansCoverPaletteTests {

    // MARK: - Helpers

    /// A solid-colour bitmap, built with CoreGraphics only.
    private func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat, width: Int = 64, height: Int = 64) -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Luminance of a SwiftUI colour, resolved through the platform colour.
    private func luminance(of color: Color) -> Double? {
        guard let components = PlatformColor(color).cgColor.components,
              components.count >= 3 else { return nil }
        return 0.2126 * Double(components[0])
            + 0.7152 * Double(components[1])
            + 0.0722 * Double(components[2])
    }

    // MARK: - HSL math

    @Test("HSL round-trip preserves the colour")
    func hslRoundTripPreservesColour() {
        for rgb in [
            BeansRGBColor(r: 0.9, g: 0.2, b: 0.3),
            BeansRGBColor(r: 0.1, g: 0.7, b: 0.4),
            BeansRGBColor(r: 0.2, g: 0.3, b: 0.9),
            BeansRGBColor(r: 0.5, g: 0.5, b: 0.5),
        ] {
            let hsl = rgb.toHSL()
            let back = BeansRGBColor.fromHSL(h: hsl.h, s: hsl.s, l: hsl.l)
            #expect(abs(back.r - rgb.r) < 0.01)
            #expect(abs(back.g - rgb.g) < 0.01)
            #expect(abs(back.b - rgb.b) < 0.01)
        }
    }

    @Test("withLightness sets the HSL lightness it is asked for")
    func withLightnessSetsLightness() {
        let red = BeansRGBColor(r: 1, g: 0, b: 0)
        #expect(abs(red.withLightness(0.2).toHSL().l - 0.2) < 0.01)
        #expect(abs(red.withLightness(0.72).toHSL().l - 0.72) < 0.01)
        #expect(abs(red.withSaturation(0.26).toHSL().s - 0.26) < 0.01)
    }

    // MARK: - Dominant-colour extraction

    @Test("dominant colour of a solid red cover is red")
    func dominantColorFindsTheSolidColour() {
        let dominant = BeansPaletteExtractor.dominantColor(in: solidImage(red: 1, green: 0, blue: 0))
        let colour = try? #require(dominant)
        #expect((colour?.r ?? 0) > 0.8)
        #expect((colour?.r ?? 0) > (colour?.g ?? 0))
        #expect((colour?.r ?? 0) > (colour?.b ?? 0))
    }

    @Test("dominant colour of a solid blue cover is blue")
    func dominantColorFindsBlue() {
        let dominant = BeansPaletteExtractor.dominantColor(in: solidImage(red: 0, green: 0.2, blue: 1))
        let colour = try? #require(dominant)
        #expect((colour?.b ?? 0) > 0.8)
        #expect((colour?.b ?? 0) > (colour?.r ?? 0))
    }

    @Test("near-black pixels cannot pollute the dominant colour")
    func dominantColorIgnoresNearBlack() {
        // Left half black, right half red: the black half must not win.
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: 64, height: 64,
            bitsPerComponent: 8, bytesPerRow: 64 * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 32, y: 0, width: 32, height: 64))
        let image = context.makeImage()!
        let dominant = BeansPaletteExtractor.dominantColor(in: image)
        let colour = try? #require(dominant)
        #expect((colour?.r ?? 0) > 0.8)
    }

    // MARK: - Palette derivation

    @Test("no dominant colour falls back to the theme accent")
    func paletteFallsBackWithoutDominant() {
        let palette = BeansCoverPalette.make(dominant: nil, colorScheme: .dark)
        #expect(palette.accent == Theme.accent)
        #expect(palette.backgroundTop == ArtworkColors.fallback.primary)
        #expect(palette.backgroundBottom == ArtworkColors.fallback.secondary)
    }

    @Test("dark-mode palette is lighter at the top and the accent is the brightest")
    func darkPaletteOrdering() throws {
        let palette = BeansCoverPalette.make(
            dominant: BeansRGBColor(r: 0.9, g: 0.2, b: 0.3), colorScheme: .dark)
        let top = try #require(luminance(of: palette.backgroundTop))
        let bottom = try #require(luminance(of: palette.backgroundBottom))
        let accent = try #require(luminance(of: palette.accent))
        #expect(top > bottom)
        #expect(accent > top)
    }

    @Test("text is near-white on a dark-mode background")
    func darkPaletteTextIsLight() throws {
        let palette = BeansCoverPalette.make(
            dominant: BeansRGBColor(r: 0.9, g: 0.2, b: 0.3), colorScheme: .dark)
        let text = try #require(luminance(of: palette.text))
        #expect(text > 0.9)
    }

    // MARK: - Layout metrics

    @Test("cover size follows the Beans rule")
    func coverSizeFollowsBeansRule() {
        #expect(abs(BeansPlayerLayout.coverSize(for: CGSize(width: 390, height: 844)) - 234) < 0.001)
        #expect(abs(BeansPlayerLayout.coverSize(for: CGSize(width: 1024, height: 768)) - 280) < 0.001)
        #expect(abs(BeansPlayerLayout.coverSize(for: CGSize(width: 320, height: 568)) - 192) < 0.001)
    }
}
