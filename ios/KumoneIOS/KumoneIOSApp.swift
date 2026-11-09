import SwiftUI
import KumoneIOSFeature

@main
struct KumoneIOSApp: App {
    @UIApplicationDelegateAdaptor(DownloadAppDelegate.self) private var downloadDelegate

    init() {
        // Re-register user-installed fonts (Beans `appearanceSection`,
        // P3 3/3) and prune wallpaper entries whose files are gone.
        Task { @MainActor in
            FontManager.reinstallIfNeeded()
            let settings = SettingsManager.shared
            settings.wallpaperPaths = WallpaperStore.prunedPaths(settings.wallpaperPaths)
            if !settings.backgroundImagePathLight.isEmpty,
               WallpaperStore.image(at: settings.backgroundImagePathLight) == nil {
                settings.backgroundImagePathLight = ""
            }
            if !settings.backgroundImagePathDark.isEmpty,
               WallpaperStore.image(at: settings.backgroundImagePathDark) == nil {
                settings.backgroundImagePathDark = ""
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            IOSMainWindow()
        }
    }
}

final class DownloadAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        OfflineDownloadEvents.handleBackgroundSession(identifier: identifier, completion: completionHandler)
    }
}

// MARK: - CarPlay

import CarPlay
import UIKit

/// CarPlay template scene delegate — instantiated automatically by UIApplicationSceneManifest in Info.plist.
/// It just forwards the connect/disconnect callbacks into `CarPlayConnector` inside KumoneCore;
/// the app target itself stays as a thin bridge and owns no CarPlay logic of its own.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {}

extension CarPlaySceneDelegate {
    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        CarPlayConnector.shared.didConnect(
            interfaceController: interfaceController,
            window: scene.carWindow
        )
    }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController
    ) {
        CarPlayConnector.shared.didDisconnect()
    }
}
