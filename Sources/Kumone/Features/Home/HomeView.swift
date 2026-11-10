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
    /// QQ-only home sections (radar songs, hot chart songs, hot
    /// artists); empty on NetEase/Kugou.
    @Published var platformRecommendSongs: [Track] = []
    @Published var platformHotSongs: [Track] = []
    @Published var platformHotArtists: [PlatformArtistSummary] = []
    /// QQ/Kugou daily recommendations ("每日推荐"); empty on NetEase.
    @Published var platformDailySongs: [Track] = []

    func load(platform: HomePlatform, loggedIn: Bool) async {
        if case .loaded = state, platform == currentPlatform { return }
        state = .loading
        currentPlatform = platform
        // QQ-only sections never survive a platform switch.
        platformRecommendSongs = []
        platformHotSongs = []
        platformHotArtists = []
        platformDailySongs = []

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

        // QQ: recommended songs (radar) + recommended playlists +
        // hot songs + charts + hot artists. Kugou: daily
        // recommendations + recommended playlists + charts — it has
        // no verified endpoint for the other three, so those sections
        // stay hidden instead of faked. New albums / NetEase radar
        // playlists / feature cards are NetEase-only.
        async let playlistsTask = fetchPlatformPlaylists(platform: platform)
        async let toplistsTask = fetchPlatformToplists(platform: platform)
        async let dailyTask = fetchPlatformDailySongs(platform: platform)
        if platform == .qqmusic {
            async let recommendTask = fetchPlatformRecommendSongs()
            async let hotSongsTask = fetchPlatformHotSongs()
            async let hotArtistsTask = fetchPlatformHotArtists()
            platformRecommendSongs = await recommendTask
            platformHotSongs = await hotSongsTask
            platformHotArtists = await hotArtistsTask
        }
        platformPlaylists = await playlistsTask
        platformToplists = await toplistsTask
        platformDailySongs = await dailyTask
        state = platformPlaylists.isEmpty && platformToplists.isEmpty
            && platformRecommendSongs.isEmpty && platformHotSongs.isEmpty
            && platformHotArtists.isEmpty && platformDailySongs.isEmpty
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

    /// QQ-only: recommended songs from the radar feed. `Track`
    /// carries `platformSource` (.qqmusic), so tapping a row plays
    /// through the PR #29 ikun fallback like any other QQ track.
    private func fetchPlatformRecommendSongs() async -> [Track] {
        (try? await QQMusicAPI.shared.radarSongs(limit: 20))?.compactMap(Track.fromQQSong) ?? []
    }

    /// QQ-only: hot songs — the top of the 巅峰榜·热歌 chart.
    private func fetchPlatformHotSongs() async -> [Track] {
        (try? await QQMusicAPI.shared.hotSongs(limit: 15))?.compactMap(Track.fromQQSong) ?? []
    }

    /// QQ-only: hot artists from the popularity-ordered singer list.
    private func fetchPlatformHotArtists() async -> [PlatformArtistSummary] {
        (try? await QQMusicAPI.shared.hotArtists(limit: 12))?.map {
            PlatformArtistSummary(source: .qqmusic, name: $0.name, picURL: $0.picURL, platformID: $0.mid)
        } ?? []
    }

    /// Daily recommendations for the QQ/Kugou home feed ("每日推荐"):
    /// QQ mixes the tops of the three charts (Beans
    /// `QQMusicAPI.recommendSongs`); Kugou uses its daily endpoint,
    /// with a hot-songs search fallback when it comes back empty
    /// (Beans `DiscoverView.loadKugouDailySongs`). `Track` carries
    /// `platformSource`, so rows play through the PR #29 ikun
    /// fallback like any other platform track.
    private func fetchPlatformDailySongs(platform: HomePlatform) async -> [Track] {
        switch platform {
        case .netease:
            return []
        case .qqmusic:
            return (try? await QQMusicAPI.shared.recommendSongs(limit: 30))?.compactMap(Track.fromQQSong) ?? []
        case .kugou:
            if let daily = try? await KugouMusicAPI.shared.everydayRecommend(limit: 30), !daily.isEmpty {
                return daily.compactMap(Track.fromKugouSong)
            }
            return (try? await KugouMusicAPI.shared.searchSongs(keyword: "热门歌曲", limit: 30))?
                .compactMap(Track.fromKugouSong) ?? []
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
    @ObservedObject private var platformPrefs = PlatformPreferenceStore.shared
    /// Kugou login state, only to dim the 私人漫游 card while
    /// logged out (the card itself is always shown, Beans-style).
    @ObservedObject private var kugouAuth = KugouMusicAuth.shared

    /// `.task(id:)` needs an `Equatable` id; tuples cannot conform to
    /// `Equatable` in Swift, so the (loggedIn, platform) pair gets a
    /// tiny struct instead.
    private struct FeedTaskID: Equatable {
        let loggedIn: Bool
        let platform: HomePlatform
    }

    /// `.topBarLeading` does not exist on macOS; `.navigation` is the
    /// macOS toolbar leading slot (same pattern as MainWindow.swift).
    private var platformSwitcherPlacement: ToolbarItemPlacement {
        #if os(macOS)
        return .navigation
        #else
        return .topBarLeading
        #endif
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
        // Wallpaper background (Beans `appearanceSection`, P3 3/3):
        // only when "同步到搜索 / 音乐库 / 我的" is OFF — when it is
        // on, `IOSMainWindow` paints the same layer behind all tabs.
        #if os(iOS)
        .background {
            if !settings.backgroundSyncAll {
                WallpaperBackgroundView()
            }
        }
        #endif
        .navigationTitle("推荐")
        .toolbar {
            ToolbarItem(placement: platformSwitcherPlacement) {
                Menu {
                    // 切换器只列设置页“平台显示”里启用的平台，按保存的
                    // 顺序；只控制入口可见性，不动音源开关与平台能力。
                    ForEach(platformPrefs.orderedEnabledPlatforms) { platform in
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
        // 当前平台在设置页被隐藏时回落到第一个可见平台（设置页改
        // 动时经 onChange 立刻生效；首页重现时经 onAppear 兜底）。
        .onAppear {
            settings.homePlatform = platformPrefs.ensureVisible(settings.homePlatform)
        }
        .onChange(of: platformPrefs.selectedRaw) { _ in
            settings.homePlatform = platformPrefs.ensureVisible(settings.homePlatform)
        }
    }

    /// Switching home platform only changes what the home page shows.
    /// It never touches playback sources: there is no per-platform
    /// playback setting anymore (the Settings → 音源 toggles were
    /// removed by the Beans settings port), and every track resolves
    /// through the same ladder in `UnblockService` whatever platform
    /// is selected.
    private func selectPlatform(_ platform: HomePlatform) {
        guard platform != settings.homePlatform else { return }
        settings.homePlatform = platform
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

    /// QQ home feed, Beans 图3 order: 每日推荐大卡 / 排行榜 / 热门歌手 /
    /// 推荐歌单 / 推荐 / 热门歌曲. Kugou keeps its own order (私人漫游 card /
    /// 每日推荐 / 推荐歌单 / 排行榜). Song rows play through the normal queue
    /// (PR #29 ikun fallback); playlist and chart cards play their
    /// songs directly, as before — there is no platform playlist/chart
    /// detail page. A section whose fetch failed is hidden, never
    /// faked.
    private var platformSections: some View {
        Group {
            if model.currentPlatform == .qqmusic {
                qqHomeSections
            } else {
                kugouHomeSections
            }
        }
    }

    /// QQ home in Beans 图3 order: the daily hero card first, then
    /// horizontal chart cards, then circular artists. The remaining
    /// sections (推荐歌单 / 推荐 / 热门歌曲) keep their data and layout,
    /// just below — only the order changed, no fetch logic.
    private var qqHomeSections: some View {
        Group {
            if !model.platformDailySongs.isEmpty {
                qqDailyHeroCard
                    .padding(.horizontal, Theme.Layout.contentInset)
            }

            if !model.platformToplists.isEmpty {
                Shelf(title: "排行榜", seeAll: nil, rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(model.platformToplists) { toplist in
                        platformToplistCard(toplist)
                    }
                }
            }

            if !model.platformHotArtists.isEmpty {
                Shelf(title: "热门歌手", rowHeight: Theme.Layout.artistShelfHeight) {
                    ForEach(model.platformHotArtists) { artist in
                        platformArtistCard(artist)
                    }
                }
            }

            if !model.platformPlaylists.isEmpty {
                Shelf(title: "推荐歌单", rowHeight: Theme.Layout.coverShelfHeight) {
                    ForEach(Array(model.platformPlaylists.prefix(12).enumerated()), id: \.element.id) { index, playlist in
                        platformPlaylistCard(playlist)
                            .staggeredAppearance(index: index, id: "home-platform-rec-\(playlist.id)")
                    }
                }
            }

            if !model.platformRecommendSongs.isEmpty {
                platformSongListSection(title: "推荐", tracks: model.platformRecommendSongs)
            }

            if !model.platformHotSongs.isEmpty {
                platformSongListSection(title: "热门歌曲", tracks: model.platformHotSongs)
            }
        }
    }

    /// QQ 每日推荐大封面卡（Beans 图3）：第一首歌的封面做背景，
    /// 点进每日推荐列表（PlatformDailySongsView，复用 TrackListView）。
    private var qqDailyHeroCard: some View {
        NavigationLink {
            PlatformDailySongsView(tracks: model.platformDailySongs)
        } label: {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(url: model.platformDailySongs.first?.album.picUrl?.resizedImageURL(1024))
                    .frame(maxWidth: .infinity)
                    .frame(height: 190)
                    .clipped()
                LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.68)],
                               startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 4) {
                    Text("每日推荐")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                    Text("\(model.platformDailySongs.count) 首 · 每天 6:00 更新")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(16)
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                Image(systemName: "calendar")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Kugou home feed, unchanged order: 私人漫游 card / 每日推荐 /
    /// 推荐歌单 / 排行榜.
    private var kugouHomeSections: some View {
        Group {
            kugouFeatureCards

            if !model.platformDailySongs.isEmpty {
                platformSongListSection(title: "每日推荐", tracks: model.platformDailySongs)
            }

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

    /// QQ-only song rows ("每日推荐" / "推荐" / "热门歌曲"): compact `TrackListView`
    /// rows, same shape as artist hot songs — artwork, title, artist,
    /// no album column. Tapping plays the row through the normal queue.
    private func platformSongListSection(title: LocalizedStringKey, tracks: [Track]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Layout.sectionHeaderSpacing) {
            SectionHeader(title: title)
                .padding(.horizontal, Theme.Layout.contentInset)
            TrackListView(tracks: tracks, style: .compact)
                .padding(.horizontal, Theme.Layout.contentInset - 10)
        }
    }

    /// Kugou-only feature cards ("推荐" row in Beans' Kugou home):
    /// a single 私人漫游 card. Beans shows it always and toasts
    /// when logged out; here it is dimmed while logged out so the
    /// state is visible before tapping, and the tap still toasts.
    private var kugouFeatureCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                Color.clear.frame(width: max(0, Theme.Layout.contentInset - 16), height: 1)
                Button {
                    startKugouPersonalFM()
                } label: {
                    FeatureCard(
                        title: "私人漫游",
                        subtitle: "从喜欢的歌开始漫游",
                        icon: "wave.3.right.circle.fill",
                        gradient: [Color(red: 0.08, green: 0.46, blue: 0.82),
                                   Color(red: 0.18, green: 0.72, blue: 0.72)]
                    )
                }
                .buttonStyle(.interactiveCard)
                .opacity(kugouAuth.isLoggedIn ? 1 : 0.45)
                Color.clear.frame(width: max(0, Theme.Layout.contentInset - 16), height: 1)
            }
            .padding(.vertical, 6)
        }
        .compatScrollClipDisabled()
        .shelfEdgeClip()
    }

    /// Kugou 私人漫游 (Beans `DiscoverView.startKugouPersonalFM`):
    /// login-gated in the API itself (`personalFM` returns [] when
    /// logged out); the toast names the missing login instead of
    /// failing silently. An empty result means even the API's
    /// 每日推荐 fallback came back empty.
    private func startKugouPersonalFM() {
        Task {
            guard await KugouMusicAuth.shared.isLoggedIn else {
                ToastCenter.shared.show(String(localized: "请先登录酷狗音乐"))
                return
            }
            do {
                let songs = try await KugouMusicAPI.shared.personalFM(limit: 12)
                let tracks = songs.compactMap(Track.fromKugouSong)
                guard !tracks.isEmpty else {
                    ToastCenter.shared.show(String(localized: "私人漫游暂时没有推荐"))
                    return
                }
                player.play(tracks: tracks, source: .none)
                ToastCenter.shared.show(String(localized: "已开启私人漫游"))
            } catch {
                ToastCenter.shared.show(String(localized: "私人漫游加载失败"))
            }
        }
    }

    /// QQ-only artist circles ("热门歌手"), mirroring SearchView's
    /// `platformArtistCards`: opens `PlatformArtistDetailView`, never
    /// the NetEase artist page.
    private func platformArtistCard(_ artist: PlatformArtistSummary) -> some View {
        NavigationLink {
            PlatformArtistDetailView(artist: artist)
        } label: {
            VStack(spacing: 10) {
                CachedAsyncImage(url: artist.picURL)
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

    /// QQ 每日推荐列表：从首页每日推荐大卡点进来。歌已在首页取好，
/// 这里只展示（TrackListView）+ 播放全部，不再请求一次。
/// Header mirrors DailySongsView (NetEase), with the QQ subtitle.
struct PlatformDailySongsView: View {
    let tracks: [Track]

    private let player = PlayerService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                    .padding(.horizontal, Theme.Layout.contentInset)
                    .padding(.top, 16)
                TrackListView(tracks: tracks, style: .compact)
                    .padding(.horizontal, Theme.Layout.contentInset - 10)
                PlayerClearanceSpacer()
            }
        }
        .navigationTitle("每日推荐")
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            CachedAsyncImage(url: tracks.first?.album.picUrl?.resizedImageURL(1024))
                .frame(height: 220)
                .frame(maxWidth: .infinity)
                .clipped()
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.72)],
                           startPoint: .top, endPoint: .bottom)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("每日推荐")
                        .font(.system(size: 30, weight: .bold))
                    Text("\(tracks.count) 首 · 每天 6:00 更新")
                        .font(.system(size: 12))
                        .opacity(0.7)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 3, y: 1)

                Spacer()

                Button {
                    player.play(tracks: tracks, source: .none)
                } label: {
                    Label("播放全部", systemImage: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(Theme.accentGradient, in: Capsule())
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                }
                .buttonStyle(.pressable)
            }
            .padding(20)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
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
