// Sources/Kumone/Features/Player/BeansPlayerLayout.swift
//
// Beans player-page layout metrics (from Beans-Music `PlayerLayout.swift`
// and `PlayerView.swift`): the fixed geometry the Beans album page is
// built on — cover size rule, deck spacing, halo scales.
//
// Only the *defaults* are ported here. Beans also lets the user drag
// every component to a custom x/y/scale and persists it
// (`PlayerLayoutStore` + the `Layoutable` modifier + the layout toolbar);
// that editor is a separate feature and is deliberately NOT part of
// this step — the metrics below are the values the editor itself falls
// back to when the user has never moved anything.

import SwiftUI

/// Fixed layout metrics for the Beans-style player page.
enum BeansPlayerLayout {
    /// Cover size: fixed rule, independent of layout timing —
    /// `min(280, width * 0.60, height * 0.44)`.
    static func coverSize(for size: CGSize) -> CGFloat {
        min(280, min(size.width * 0.60, size.height * 0.44))
    }

    /// Spacing of the bottom deck stack (progress + transport +
    /// secondary row), matching Beans' `controlDeck` / `immersiveControls`.
    static let deckSpacing: CGFloat = 17

    /// Corner radius for a square cover: 8% of its size, capped at 24pt.
    static func coverCornerRadius(for coverSize: CGFloat) -> CGFloat {
        min(24, coverSize * 0.08)
    }

    /// Halo glow discs behind the cover, as multiples of the cover size
    /// (Beans' `classicAlbumPanel`: accent 1.38x, secondary 1.10x).
    static let haloAccentScale: CGFloat = 1.38
    static let haloSecondaryScale: CGFloat = 1.10

    /// Glass tray behind the cover, as a multiple of the cover size.
    static let coverTrayScale: CGFloat = 1.10

    /// Horizontal swipe distance that switches tracks (Beans' cover drag).
    static let swipeThreshold: CGFloat = 60

    /// Parallax fade while swiping: opacity falls to 0.65 at 260pt.
    static let swipeFadeDistance: CGFloat = 260
}
