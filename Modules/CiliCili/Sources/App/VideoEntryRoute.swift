import SwiftUI

// A navigation value owns the list snapshot; another tab cannot overwrite it.
nonisolated struct VideoEntryContext: Hashable, Sendable {
    let title: String
    let videos: [VideoItem]
}

nonisolated struct VideoEntryRoute: Hashable, Sendable {
    let video: VideoItem
    let context: VideoEntryContext
}

private struct VideoEntryContextKey: EnvironmentKey {
    static let defaultValue: VideoEntryContext? = nil
}
private struct OpenVideoEntryActionKey: EnvironmentKey {
    static let defaultValue: ((VideoEntryRoute) -> Void)? = nil
}
extension EnvironmentValues {
    var videoEntryContext: VideoEntryContext? {
        get { self[VideoEntryContextKey.self] }
        set { self[VideoEntryContextKey.self] = newValue }
    }
    var openVideoEntryAction: ((VideoEntryRoute) -> Void)? {
        get { self[OpenVideoEntryActionKey.self] }
        set { self[OpenVideoEntryActionKey.self] = newValue }
    }
}
