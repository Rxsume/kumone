import SwiftUI

extension Color {
    /// "#RRGGBB" / "RRGGBB" (an 8-digit "#RRGGBBAA" also parses,
    /// alpha is ignored). Returns nil for anything else.
    init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6 || cleaned.count == 8,
              let value = UInt64(cleaned.prefix(6), radix: 16)
        else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// "#RRGGBB" in sRGB. Unresolvable colors read as black.
    /// (Named `rgbHexString`, not `hexString`: `ArtworkPalette.swift`
    /// already declares a private `Color.hexString`.)
    var rgbHexString: String {
        // SwiftUI `Color.cgColor` IS optional (unlike
        // `PlatformColor.cgColor`, which is non-optional in this
        // toolchain — see the PR #37 lesson — so no `?` there);
        // `cgColor.components` is itself `[CGFloat]?`, hence the
        // `guard let` on it.
        guard let components = self.cgColor?.components else { return "#000000" }
        let rgb: (CGFloat, CGFloat, CGFloat)
        if components.count >= 3 {
            rgb = (components[0], components[1], components[2])
        } else if components.count == 2 {
            // Grayscale: [white, alpha].
            rgb = (components[0], components[0], components[0])
        } else {
            return "#000000"
        }
        return String(
            format: "#%02X%02X%02X",
            Int((rgb.0 * 255).rounded()),
            Int((rgb.1 * 255).rounded()),
            Int((rgb.2 * 255).rounded())
        )
    }
}
