import SwiftUI

@MainActor
final class HomeViewModel: ObservableObject {
    /// Shared so the loaded page survives sidebar switches (no skeleton flash).
    static let shared = HomeViewModel()

    enum State {
        case idle, loading, loaded
        case error(String)
    }

    /// The personalized radar family — global playlist IDs whose content is
    /// generated per logged-in account (same list YesPlayMusic special-cases).
    static let radarPlaylistIDs = [
        3_136_952_023, // 私人雷达
        2_829_883_282, // 华语私人雷达
        2_829_816_518, // 欧美私人雷达
        2_829_896_389, // 日系私人雷达
    ]

    struct RadarPlaylist: Identifiable, Hashable {
        let id: Int
        let title: String
        let subtitle: String?
        let coverURL: String?
    }

    @Published var state: State = .idle
    @Published var currentPlatform: HomePlatform = .netease
    @Published var recommendPlaylists: [PlaylistSummary] = []
    @Published var radarPlaylists: [RadarPlaylist] = []
    @Published var toplists: [ToplistItem] = []
    @Published var newAlbums: [AlbumSummary] = []
    @Published var topArtists: [ArtistSummary] = []
    @Published var dailyFirstCover: String?
    /// QQ/Kugou home feed for the active platform; empty on NetEase.
    @Published var platformPlaylists: [PlatformPlaylistSummary] = []
    @Published var platformToplists: [PlatformToplistItem] = []

    func load(platform: HomePlatform, loggedIn: Bool) async {
        if case .loaded = state, platform == currentPlatform { return }
        state = .loading
        currentPlatform = platform

        if platform == .netease {
            async let playlistsTask = fetchRecommendPlaylists(loggedIn: loggedIn)
            async let toplistsTask = try? MusicAPI.toplists()
            async let albumsTask = try? MusicAPI.newAlbums(limit: 20)
            async let artistsTask = try? MusicAPI.topArtists()

            let playlists = await playlistsTask
            recommendPlaylists = playlists
            toplists = (await toplistsTask ?? []).filter {
                [19_723_756, 3_779_629, 2_884_035, 3_778_678, 60198].contains($0.id)
            }
            newAlbums = await albumsTask ?? []
            let artists = await artistsTask ?? []
            topArtists = Array(artists.shuffled().prefix(6))

            if loggedIn {
                if let daily = try? await MusicAPI.dailyRecommendSongs() {
                    dailyFirstCover = daily.first?.album.picUrl
                }
                await loadRadarPlaylists()
            }

            state = playlists.isEmpty && newAlbums.isEmpty ? .error(String(localized: "网络连接失败")) : .loaded
            return
        }

        // QQ/Kugou: recommended playlists + charts only. New albums,
        // top artists, radar and the login feature cards are
        // NetEase-only — neither platform has a usable endpoint for
        // them, so those sections are hidden instead of faked.
        async let playlistsTask = fetchPlatformPlaylists(platform: platform)
        async let toplistsTask = fetchPlatformToplists(platform: platform)
        platformPlaylists = await playlistsTask
        platformToplists = await toplistsTask
        state = platformPlaylists.isEmpty && platformToplists.isEmpty
            ? .error(String(localized: "网络连接失败")) : .loaded
    }

    func reload(platform: HomePlatform, loggedIn: Bool) async {
        state = .idle
        await load(platform: platform, loggedIn: loggedIn)
    }

    private func fetchPlatformPlaylists(platform: HomePlatform) async -> [PlatformPlaylistSummary] {
        switch platform {
        case .netease:
            return []
        case .qqmusic:
            return (try? await QQMusicAPI.shared.recommendPlaylists(limit: 12))?.map {
                PlatformPlaylistSummary(source: .qqmusic, platformID: $0.id, name: $0.name,
                                        coverURL: $0.coverURL, trackCount: $0.trackCount)
            } ?? []
        case .kugou:
            return (try? await KugouMusicAPI.shared.recommendPlaylists(limit: 12))?.map {
                PlatformPlaylistSummary(source: .kugou, platformID: $0.id, name: $0.name,
                                        coverURL: $0.coverURL, trackCount: $0.trackCount)
            } ?? []
        }
    }

    private func fetchPlatformToplists(platform: HomePlatform) async -> [PlatformToplistItem] {
        switch platform {
        case .netease:
            return []
        case .qqmusic:
            return (try? await QQMusicAPI.shared.topLists())?.map {
                PlatformToplistItem(
                    source: .qqmusic, platformID: $0.id, name: $0.name,
                    coverURL: $0.coverURL,
                    subtitle: $0.subTitle.isEmpty
                        ? $0.topSongNames.joined(separator: " / ") : $0.subTitle)
            } ?? []
        case .kugou:
            return (try? await KugouMusicAPI.shared.topLists(limit: 10))?.map {
                PlatformToplistItem(
                    source: .kugou, platformID: $0.id, name: $0.name,
                    coverURL: $0.coverURL,
                    subtitle: $0.updateFrequency.isEmpty ? nil : $0.updateFrequency)
            } ?? []
        }
    }

    private func loadRadarPlaylists() async {
        let briefs = await withTaskGroup(of: (Int, MusicAPI.PlaylistBrief.Body?).self) { group in
            for id in Self.radarPlaylistIDs {
                group.addTask {
                    (id, try? await MusicAPI.playlistBrief(id: id))
                }
            }
            var byID: [Int: MusicAPI.PlaylistBrief.Body] = [:]
            for await (id, brief) in group {
                if let brief { byID[id] = brief }
            }
            return byID
        }
        radarPlaylists = Self.radarPlaylistIDs.compactMap { id in
            guard let brief = briefs[id] else { return nil }
            // Names arrive as "今天从《…》听起|私人雷达" — split into title/subtitle.
            let parts = (brief.name ?? "").components(separatedBy: "|")
            let title = parts.count > 1 ? parts.last! : (brief.name ?? String(localized: "雷达歌单"))
            let subtitle = parts.count > 1 ? parts.dropLast().joined(separator: "|") : nil
            return RadarPlaylist(id: id, title: title, subtitle: subtitle, coverURL: brief.coverImgUrl)
        }
    }

    private func fetchRecommendPlaylists(loggedIn: Bool) async -> [PlaylistSummary] {
        if loggedIn {
            async let recommend = try? MusicAPI.recommendResource()
            async let personalized = try? MusicAPI.personalizedPlaylists(limit: 30)
            let head = await recommend ?? []
            let tail = await personalized ?? []
            var seen = Set<Int>()
            return (head + tail).filter { seen.insert($0.id).inserted }
        }
        return (try? await MusicAPI.personalizedPlaylists(limit: 30)) ?? []
    }
}

struct HomeView: View {
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var player: PlayerService
    @StateObject private var model = HomeViewModel.shared
    @ObservedObject private var settings = SettingsManager.shared

    /// `.task(id:)` needs an `Equatable` id; tuples cannot conform to
    /// `Equatable` in Swift, so the (loggedIn, platform) pair gets a
    /// tiny struct instead.
    private struct FeedTaskID: Equatable {
        let loggedIn: Bool
        let platform: HomePlatform
    }

    var body: some View {
        ScrollView {
            switch model.state {
            case .idle, .loading:
                loadingBody
            case .error(let message):
                ErrorStateView(message: message) {
                    Task { await model.reload(platform: settings.homePlatform, loggedIn: account.isLoggedIn) }
                }
                .frame(minHeight: 400)
            case .loaded:
                loadedBody
            }
        }
        .navigationTitle("推荐")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(HomePlatform.allCases) { platform in
                        Button {
                            selectPlatform(platform)
                        } label: {
                            if platform == settings.homePlatform {
                                Label(platform.displayName, systemImage: "checkmark")
                            } else {
                                Text(platform.displayName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(settings.homePlatform.displayName)
                            .font(.headline)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                    }
                    .contentShape(Rectangle())
                }
            }
        }
        .task(id: FeedTaskID(loggedIn: account.isLoggedIn, platform: settings.homePlatform)) {
            await model.load(platform: settings.homePlatform, loggedIn: account.isLoggedIn)
        }
    }

    /// Switching home platform also opts into that platform's content:
    /// its source toggle is enabled so its songs actually play (and
    /// appear in search). NetEase has no toggle. Picking the platform
    /// is an explicit choice, so this is the same opt-in as flipping
    /// the toggle in Settings → 音源 by hand.
    private func selectPlatform(_ platform: HomePlatform) {
        guard platform != settings.homePlatform else { return }
        settings.homePlatform = platform
        if let source = platform.sourceID,
           !settings.enabledAudioSourceIDs.contains(source) {
            settings.enabledAudioSourceIDs.insert(source)
        }
    }

    private var loadingBody: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.sectionSpacing) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(0..<3, id: \.self) { _ in
                        SkeletonView(cornerRadius: Theme.Radius.large)
                            .frame(width: 230, height: 132)
                    }
                }
            }
            SkeletonShelf()
            SkeletonShelf()
        }
        .padding(Theme.Layout.contentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadedBody: some View {
        LazyVStack(alignment: .leading, spacing: Theme.Layout.sectionSpacing) {
            if settings.homePlatform == .netease {
                netEaseSections
            } else {
                platformSections
            }

            PlayerClearanceSpacer()
        }
        .padding(.top, Theme.Layout.pageTopPadding)
        .padding(.bottom, Theme.Layout.contentInset - 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Today's NetEase feed, byte-identical behaviour: feature cards,
    /// recommended playlists, radar, charts, new albums, top artists.
    private var netEaseSections: some View {
        Group {
            // Anonymous users go straight to recommended playlists;
            // the login entry lives in the sidebar / 我的 tab only.
            if account.isLoggedIn {
                featureCards
                    .padding(.top, 8)
            }

            if !model.recommendPlaylists.isEmpty {
                Shelf(title: "推荐歌单", rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(Array(model.recommendPlaylists.prefix(12).enumerated()), id: \.element.id) { index, playlist in
                        playlistCard(playlist)
                            .staggeredAppearance(index: index, id: "home-rec-\(playlist.id)")
                    }
                }
            }

            if !model.radarPlaylists.isEmpty {
                Shelf(title: "雷达歌单", rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(model.radarPlaylists) { radar in
                        NavigationLink(value: Destination.radarPlaylist(radar.id)) {
                            CoverCardBody(
                                coverURL: radar.coverURL?.resizedImageURL(384),
                                title: radar.title,
                                subtitle: radar.subtitle,
                                titleLineLimit: Theme.Layout.shelfTitleLineLimit
                            ) {
                                playPlaylist(radar.id)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !model.toplists.isEmpty {
                Shelf(title: "排行榜", seeAll: nil, rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(model.toplists) { toplist in
                        NavigationLink(value: Destination.playlist(toplist.id)) {
                            toplistCard(toplist)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !model.newAlbums.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Layout.sectionHeaderSpacing) {
                    SectionHeader(title: "新碟上架")
                        .padding(.horizontal, Theme.Layout.contentInset)
                    GeometryReader { geometry in
                        let size = Theme.Layout.fittedShelfCardSize(availableWidth: geometry.size.width, leadingInset: Theme.Layout.contentInset)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 16) {
                                ForEach(model.newAlbums) { album in
                                    albumCard(album, size: size)
                                }
                            }
                            .padding(.horizontal, Theme.Layout.contentInset)
                            .frame(height: Theme.Layout.coverShelfHeight)
                        }
                        .shelfEdgeClip()
                    }
                    .frame(height: Theme.Layout.coverShelfHeight)
                }
            }

            if !model.topArtists.isEmpty {
                Shelf(title: "推荐歌手", rowHeight: Theme.Layout.artistShelfHeight) {
                    ForEach(model.topArtists) { artist in
                        artistCard(artist)
                    }
                }
            }
        }
    }

    /// QQ/Kugou feed: recommended playlists + charts only. There is no
    /// platform playlist/chart detail page, so tapping a card plays
    /// its songs directly. New albums / top artists / radar / feature
    /// cards are NetEase-only and hidden here.
    private var platformSections: some View {
        Group {
            if !model.platformPlaylists.isEmpty {
                Shelf(title: "推荐歌单", rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(Array(model.platformPlaylists.prefix(12).enumerated()), id: \.element.id) { index, playlist in
                        platformPlaylistCard(playlist)
                            .staggeredAppearance(index: index, id: "home-platform-rec-\(playlist.id)")
                    }
                }
            }

            if !model.platformToplists.isEmpty {
                Shelf(title: "排行榜", seeAll: nil, rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(model.platformToplists) { toplist in
                        platformToplistCard(toplist)
                    }
                }
            }
        }
    }

    // MARK: - Feature cards

    private var featureCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                Color.clear.frame(width: max(0, Theme.Layout.contentInset - 16), height: 1)
                if account.isLoggedIn {
                    NavigationLink(value: Destination.daily) {
                        FeatureCard(
                            title: "每日推荐",
                            subtitle: "根据你的口味生成",
                            icon: "calendar",
                            coverURL: model.dailyFirstCover?.resizedImageURL(512),
                            showsDate: true
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        player.startFM()
                    } label: {
                        FeatureCard(
                            title: "私人漫游",
                            subtitle: "从喜欢的歌开始漫游",
                            icon: "wave.3.right.circle.fill",
                            gradient: [Color(red: 0.16, green: 0.20, blue: 0.42),
                                       Color(red: 0.36, green: 0.24, blue: 0.62)]
                        )
                    }
                    .buttonStyle(.interactiveCard)

                    Button {
                        startHeartbeatMode()
                    } label: {
                        FeatureCard(
                            title: "心动模式",
                            subtitle: "你的红心歌曲和相似推荐",
                            icon: "heart.circle.fill",
                            gradient: [Color(red: 0.85, green: 0.19, blue: 0.41),
                                       Color(red: 0.98, green: 0.42, blue: 0.34)]
                        )
                    }
                    .buttonStyle(.interactiveCard)
                }
                Color.clear.frame(width: max(0, Theme.Layout.contentInset - 16), height: 1)
            }
            .padding(.vertical, 6)
        }
        .compatScrollClipDisabled()
        .shelfEdgeClip()
    }

    private func startHeartbeatMode() {
        guard let likedList = account.likedSongsPlaylist else { return }
        Task {
            guard let seed = account.likedTrackIDs.randomElement() else {
                ToastCenter.shared.show(String(localized: "先收藏一些喜欢的歌曲吧"))
                return
            }
            do {
                let tracks = try await MusicAPI.intelligenceList(songID: seed, playlistID: likedList.id)
                guard !tracks.isEmpty else {
                    ToastCenter.shared.show(String(localized: "心动模式暂时不可用"))
                    return
                }
                player.play(tracks: tracks, source: .playlist(likedList.id),
                            context: .heartbeat)
                ToastCenter.shared.show(String(localized: "已开启心动模式"))
            } catch {
                ToastCenter.shared.show(error.localizedDescription)
            }
        }
    }

    // MARK: - Cards

    private func playlistCard(_ playlist: PlaylistSummary) -> some View {
        NavigationLink(value: Destination.playlist(playlist.id)) {
            CoverCardBody(
                coverURL: playlist.coverURL?.resizedImageURL(384),
                title: playlist.name,
                subtitle: playlist.copywriter,
                playCount: playlist.playCount,
                titleLineLimit: Theme.Layout.shelfTitleLineLimit
            ) {
                playPlaylist(playlist.id)
            }
        }
        .buttonStyle(.plain)
    }

    private func albumCard(_ album: AlbumSummary, size: CGFloat) -> some View {
        NavigationLink(value: Destination.album(album.id)) {
            CoverCardBody(
                coverURL: album.picUrl?.resizedImageURL(384),
                title: album.name,
                subtitle: album.artistName,
                size: size,
                titleLineLimit: Theme.Layout.shelfTitleLineLimit
            ) {
                Task {
                    if let detail = try? await MusicAPI.album(id: album.id) {
                        player.play(tracks: detail.songs, source: .album(album.id),
                                    context: .album(id: album.id, name: album.name))
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func artistCard(_ artist: ArtistSummary) -> some View {
        NavigationLink(value: Destination.artist(artist.id)) {
            VStack(spacing: 10) {
                CachedAsyncImage(url: artist.picUrl?.resizedImageURL(256))
                    .frame(width: 128, height: 128)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                Text(artist.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(width: 140)
        }
        .buttonStyle(.plain)
    }

    private func toplistCard(_ toplist: ToplistItem) -> some View {
        toplistCard(coverURL: toplist.coverImgUrl?.resizedImageURL(384),
                    name: toplist.name, subtitle: toplist.updateFrequency)
    }

    /// Shared chart card body (NetEase + platform charts). Platform
    /// covers are used raw — `resizedImageURL` appends a NetEase
    /// `param=` size query that other CDNs ignore at best.
    private func toplistCard(coverURL: URL?, name: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(url: coverURL)
                    .frame(width: Theme.Layout.cardSize, height: Theme.Layout.cardSize)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(8)
                }
            }
            .frame(width: Theme.Layout.cardSize, height: Theme.Layout.cardSize)
            Text(name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(width: Theme.Layout.cardSize, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func platformPlaylistCard(_ playlist: PlatformPlaylistSummary) -> some View {
        Button {
            playPlatformPlaylist(playlist)
        } label: {
            CoverCardBody(
                coverURL: playlist.coverURL,
                title: playlist.name,
                subtitle: playlist.trackCount.map { "\($0)首" },
                titleLineLimit: Theme.Layout.shelfTitleLineLimit
            ) {
                playPlatformPlaylist(playlist)
            }
        }
        .buttonStyle(.plain)
    }

    private func platformToplistCard(_ toplist: PlatformToplistItem) -> some View {
        Button {
            playPlatformToplist(toplist)
        } label: {
            toplistCard(coverURL: toplist.coverURL, name: toplist.name, subtitle: toplist.subtitle)
        }
        .buttonStyle(.plain)
    }

    /// Tap-to-play for a platform playlist card: there is no platform
    /// playlist detail page, so the songs are fetched and played
    /// directly. An empty result shows a toast instead of silence.
    private func playPlatformPlaylist(_ playlist: PlatformPlaylistSummary) {
        Task {
            let songs: [Track]
            switch playlist.source {
            case .qqmusic:
                songs = (try? await QQMusicAPI.shared.playlistSongs(listID: playlist.platformID))?
                    .compactMap(Track.fromQQSong) ?? []
            case .kugou:
                songs = (try? await KugouMusicAPI.shared.playlistSongs(listID: playlist.platformID))?
                    .compactMap(Track.fromKugouSong) ?? []
            default:
                songs = []
            }
            guard !songs.isEmpty else {
                ToastCenter.shared.show(String(localized: "这个歌单暂时没有可播放的歌曲"))
                return
            }
            player.play(tracks: songs, source: .none)
        }
    }

    private func playPlatformToplist(_ toplist: PlatformToplistItem) {
        Task {
            let songs: [Track]
            switch toplist.source {
            case .qqmusic:
                songs = (try? await QQMusicAPI.shared.topListSongs(topid: toplist.platformID))?
                    .compactMap(Track.fromQQSong) ?? []
            case .kugou:
                songs = (try? await KugouMusicAPI.shared.rankSongs(rankID: toplist.platformID))?
                    .compactMap(Track.fromKugouSong) ?? []
            default:
                songs = []
            }
            guard !songs.isEmpty else {
                ToastCenter.shared.show(String(localized: "这个榜单暂时没有可播放的歌曲"))
                return
            }
            player.play(tracks: songs, source: .none)
        }
    }

    private func playPlaylist(_ id: Int) {
        Task {
            guard let detail = try? await MusicAPI.playlistDetail(id: id) else { return }
            var tracks = detail.playlist.tracks
            if tracks.isEmpty {
                let ids = detail.playlist.trackIds.map(\.id)
                tracks = (try? await MusicAPI.songDetails(ids: Array(ids.prefix(500))))?.songs ?? []
            }
            player.play(tracks: tracks, source: .playlist(id),
                        context: .playlist(id: id, name: detail.playlist.name))
        }
    }
}

// MARK: - Feature card

struct FeatureCard: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let icon: String
    var coverURL: URL?
    var gradient: [Color] = [Color(red: 0.75, green: 0.16, blue: 0.22),
                             Color(red: 0.95, green: 0.35, blue: 0.28)]
    var showsDate = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let coverURL {
                CachedAsyncImage(url: coverURL)
                    .frame(width: 230, height: 132)
                LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.68)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [.white.opacity(0.18), .clear],
                               center: .topLeading, startRadius: 0, endRadius: 220)
            }

            VStack(alignment: .leading, spacing: 3) {
                ZStack {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                    if showsDate {
                        Text("\(Calendar.current.component(.day, from: .now))")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(y: 3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            .padding(14)
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        }
        .frame(width: 230, height: 132)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }
}

/// Card body without its own Button wrapper (for use inside NavigationLink).
struct CoverCardBody: View {
    let coverURL: URL?
    let title: String
    var subtitle: String?
    var playCount: Int = 0
    var size: CGFloat = Theme.Layout.cardSize
    var titleLineLimit = 2
    var onPlay: (() -> Void)?

    @State private var isHovering = false
    @Environment(\.flexibleCardWidth) private var flexibleWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            artwork
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                )
                .overlay(alignment: .topTrailing) {
                    if playCount > 0 {
                        PlayCountBadge(count: playCount)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let onPlay {
                        PlayOverlayButton(visible: isHovering, action: onPlay)
                            .padding(8)
                    }
                }

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(titleLineLimit)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)
                .frame(maxWidth: flexibleWidth ? .infinity : size, alignment: .leading)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: flexibleWidth ? .infinity : size, alignment: .leading)
            }
        }
        .frame(maxWidth: flexibleWidth ? .infinity : size, alignment: .leading)
        .contentShape(Rectangle())
        #if os(macOS)
        .onHover { isHovering = $0 }
        #endif
    }

    @ViewBuilder
    private var artwork: some View {
        if flexibleWidth {
            CachedAsyncImage(url: coverURL)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
        } else {
            CachedAsyncImage(url: coverURL)
                .frame(width: size, height: size)
        }
    }
}
