import SwiftUI

enum VideoDetailTheme {
    // Inner scroll/Tab surfaces must remain clear when the Beans wallpaper is
    // supplied by the content host; otherwise they cover it with an opaque fill.
    static var background: Color {
        CiliCiliHostAppearance.shared.backdrop == nil ? Color(.systemGroupedBackground) : .clear
    }

    static let surface = Color(.secondarySystemGroupedBackground)

    static let secondarySurface = Color(.tertiarySystemGroupedBackground)
}
