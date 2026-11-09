import Combine
import SwiftUI

/// Bridges Beans' shared wallpaper and accent preferences into the recovered
/// CiliCili screens. The module's existing glass and scrolling modifiers remain active.
@MainActor
public final class CiliCiliHostAppearance: ObservableObject {
    public static let shared = CiliCiliHostAppearance()
    @Published public private(set) var backdrop: AnyView?
    @Published public private(set) var accent: Color?
    @Published public private(set) var usesLiquidGlass = true

    public func update(backdrop: AnyView?, accent: Color?, usesLiquidGlass: Bool) {
        self.backdrop = backdrop
        self.accent = accent
        self.usesLiquidGlass = usesLiquidGlass
    }
}

struct CiliCiliHostBackdrop: View {
    @ObservedObject private var appearance = CiliCiliHostAppearance.shared
    var body: some View {
        Group {
            if let backdrop = appearance.backdrop { backdrop }
            else { Color(.systemGroupedBackground) }
        }.ignoresSafeArea().allowsHitTesting(false)
    }
}
