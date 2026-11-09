import SwiftUI

@MainActor
struct VideoDetailViewActionsBuilder {
    let seedVideo: VideoItem
    let playbackOptions: VideoDetailPlaybackOptions
    let dependencies: AppDependencies
    let holder: VideoDetailViewModelHolder
    let dismiss: DismissAction
    let onRequestClose: (() -> Void)?
    let onPopOne: (() -> Void)?
    var entryContext: VideoEntryContext? = nil

    var actions: VideoDetailViewActions {
        VideoDetailViewActions(
            configuration: configurationActions,
            close: closeActions
        )
    }

    private var configurationActions: VideoDetailViewConfigurationActions {
        VideoDetailViewConfigurationActions(
            seedVideo: seedVideo,
            playbackOptions: playbackOptions,
            dependencies: dependencies,
            holder: holder,
            entryContext: entryContext
        )
    }

    private var closeActions: VideoDetailViewCloseActions {
        VideoDetailViewCloseActions(
            holder: holder,
            dismiss: dismiss,
            onRequestClose: onRequestClose,
            onPopOne: onPopOne
        )
    }
}
