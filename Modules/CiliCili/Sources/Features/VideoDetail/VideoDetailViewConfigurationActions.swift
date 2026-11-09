import Foundation

@MainActor
struct VideoDetailViewConfigurationActions {
    let seedVideo: VideoItem
    let playbackOptions: VideoDetailPlaybackOptions
    let dependencies: AppDependencies
    let holder: VideoDetailViewModelHolder
    var entryContext: VideoEntryContext? = nil

    func configureViewModel() {
        holder.configure(
            seedVideo: seedVideo,
            api: dependencies.api,
            libraryStore: dependencies.libraryStore,
            sessionStore: dependencies.sessionStore,
            sponsorBlockService: dependencies.sponsorBlockService,
            playbackOptions: playbackOptions
        )
        holder.viewModel?.installVideoEntryContext(entryContext)
    }
}
