import SwiftUI
import WidgetKit

/// Widget extension bundle: only the Live Activity widget. No home-screen
/// widgets in v1.
@main
struct RumxsLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        RumxsLiveActivityWidget()
    }
}
