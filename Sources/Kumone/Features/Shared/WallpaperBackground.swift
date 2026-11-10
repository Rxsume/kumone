#if os(iOS)
import SwiftUI

/// Which appearance a wallpaper / background colour applies to.
/// Beans splits light/dark the same way (`BeansWallpaperAppearance`).
enum WallpaperAppearanceTarget: String, CaseIterable, Identifiable {
    case light = "浅色"
    case dark = "深色"

    var id: String { rawValue }
    var colorScheme: ColorScheme { self == .light ? .light : .dark }
}

/// Home background layer: the active wallpaper image (with blur and
/// a legibility gradient, like Beans' `GlassBackdrop`) or the custom
/// background colour (fading gradient, same as Beans), for the
/// current appearance. Draws nothing when neither is set, so the
/// default background shows through.
///
/// Consumers: `IOSMainWindow` paints it behind the whole tab
/// interface when `backgroundSyncAll` is on; `HomeView` paints it
/// behind the home feed only when sync is off — the same split as
/// Beans' `backgroundSyncAll` ("同步到搜索 / 音乐库 / 我的").
struct WallpaperBackgroundView: View {
    @EnvironmentObject private var settings: SettingsManager
    @Environment(\.colorScheme) private var colorScheme
    /// Decoded once per active path — reading + decoding a user photo
    /// on every body evaluation would jank scrolling.
    @State private var image: UIImage?

    private var activeImagePath: String {
        colorScheme == .dark ? settings.backgroundImagePathDark : settings.backgroundImagePathLight
    }

    private var activeBackgroundHex: String {
        colorScheme == .dark ? settings.backgroundHexDark : settings.backgroundHexLight
    }

    private var overlay: [Color] {
        colorScheme == .dark
            ? [.black.opacity(0.35), .black.opacity(0.55)]
            : [.black.opacity(0.08), .black.opacity(0.18)]
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: settings.homeWallpaperBlur)
                LinearGradient(colors: overlay, startPoint: .top, endPoint: .bottom)
            } else if let color = Color(hex: activeBackgroundHex) {
                LinearGradient(
                    colors: [color.opacity(0.9), color.opacity(0.55)],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
        .task(id: activeImagePath) {
            image = WallpaperStore.image(at: activeImagePath)
        }
    }
}
#endif
