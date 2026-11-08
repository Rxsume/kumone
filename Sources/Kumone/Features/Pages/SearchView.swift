import SwiftUI

@MainActor
final class SearchViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case all = "综合"
        case songs = "单曲"
        case artists = "歌手"
        case albums = "专辑"
        case playlists = "歌单"

        var id: String { rawValue }
    }

    var query: String
    @Published var tab: Tab = .all
    @Published var songs: [Track] = []
    @Published var artists: [ArtistSummary] = []
    @Published var albums: [AlbumSummary] = []
    @Published var playlists: [PlaylistSummary] = []
    /// QQ/Kugou artist/album hits for the same query. Empty unless the
    /// user enabled the source toggle; rendered after the NetEase
    /// cards and opening the platform detail pages.
    @Published var platformArtists: [PlatformArtistSummary] = []
    @Published var platformAlbums: [PlatformAlbumSummary] = []
    @Published var loadedTabs: Set<Tab> = []
    @Published private var loadingTabs: Set<Tab> = []
    /// Bumped on every query change so responses to an older query are dropped.
    private var generation = 0

    var isLoading: Bool { !loadingTabs.isEmpty }

    init(query: String) {
        self.query = query
    }

    func setQuery(_ newQuery: String) {
        guard newQuery != query else { return }
        query = newQuery
        generation &+= 1
        loadedTabs.removeAll()
        loadingTabs.removeAll()
        songs = []
        artists = []
        albums = []
        playlists = []
        platformArtists = []
        platformAlbums = []
    }

    func load(tab: Tab) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !loadedTabs.contains(tab) else { return }
        let requestGeneration = generation
        loadedTabs.insert(tab)
        loadingTabs.insert(tab)
        defer {
            if generation == requestGeneration { loadingTabs.remove(tab) }
        }

        // A failed request leaves the tab unloaded so submitting again retries
        // instead of keeping an empty result for this query.
        switch tab {
        case .all:
            async let songsTask = try? MusicAPI.search(trimmed, type: .songs, limit: 12)
            async let artistsTask = try? MusicAPI.search(trimmed, type: .artists, limit: 10)
            async let albumsTask = try? MusicAPI.search(trimmed, type: .albums, limit: 10)
            async let playlistsTask = try? MusicAPI.search(trimmed, type: .playlists, limit: 10)
            async let qqSongsTask = searchQQSongs(keyword: trimmed)
            async let kgSongsTask = searchKugouSongs(keyword: trimmed)
            async let qqArtistsTask = searchQQArtists(keyword: trimmed, limit: 10)
            async let kgArtistsTask = searchKugouArtists(keyword: trimmed, limit: 10)
            async let qqAlbumsTask = searchQQAlbums(keyword: trimmed, limit: 10)
            async let kgAlbumsTask = searchKugouAlbums(keyword: trimmed, limit: 10)
            let (songResult, artistResult, albumResult, playlistResult, qqSongs, kgSongs,
                 qqArtists, kgArtists, qqAlbums, kgAlbums) =
                await (songsTask, artistsTask, albumsTask, playlistsTask, qqSongsTask, kgSongsTask,
                       qqArtistsTask, kgArtistsTask, qqAlbumsTask, kgAlbumsTask)
            guard generation == requestGeneration else { return }
            songs = mergePlatformSongs(netEase: songResult?.songs ?? [], qq: qqSongs, kugou: kgSongs)
            artists = artistResult?.artists ?? []
            albums = albumResult?.albums ?? []
            playlists = playlistResult?.playlists ?? []
            platformArtists = mergePlatformArtists(netEase: artists, qq: qqArtists, kugou: kgArtists, cap: 10)
            platformAlbums = mergePlatformAlbums(netEase: albums, qq: qqAlbums, kugou: kgAlbums, cap: 10)
            if songResult == nil || artistResult == nil || albumResult == nil || playlistResult == nil {
                loadedTabs.remove(tab)
            }
        case .songs:
            async let netEaseTask = try? MusicAPI.search(trimmed, type: .songs, limit: 100)
            async let qqSongsTask = searchQQSongs(keyword: trimmed)
            async let kgSongsTask = searchKugouSongs(keyword: trimmed)
            let (result, qqSongs, kgSongs) = await (netEaseTask, qqSongsTask, kgSongsTask)
            guard generation == requestGeneration else { return }
            if let result {
                songs = mergePlatformSongs(netEase: result.songs ?? songs, qq: qqSongs, kugou: kgSongs)
            } else { loadedTabs.remove(tab) }
        case .artists:
            async let netEaseTask = try? MusicAPI.search(trimmed, type: .artists, limit: 50)
            async let qqArtistsTask = searchQQArtists(keyword: trimmed, limit: 30)
            async let kgArtistsTask = searchKugouArtists(keyword: trimmed, limit: 40)
            let (result, qqArtists, kgArtists) = await (netEaseTask, qqArtistsTask, kgArtistsTask)
            guard generation == requestGeneration else { return }
            if let result { artists = result.artists ?? artists } else { loadedTabs.remove(tab) }
            platformArtists = mergePlatformArtists(netEase: artists, qq: qqArtists, kugou: kgArtists)
        case .albums:
            async let netEaseTask = try? MusicAPI.search(trimmed, type: .albums, limit: 50)
            async let qqAlbumsTask = searchQQAlbums(keyword: trimmed, limit: 30)
            async let kgAlbumsTask = searchKugouAlbums(keyword: trimmed, limit: 40)
            let (result, qqAlbums, kgAlbums) = await (netEaseTask, qqAlbumsTask, kgAlbumsTask)
            guard generation == requestGeneration else { return }
            if let result { albums = result.albums ?? albums } else { loadedTabs.remove(tab) }
            platformAlbums = mergePlatformAlbums(netEase: albums, qq: qqAlbums, kugou: kgAlbums)
        case .playlists:
            let result = try? await MusicAPI.search(trimmed, type: .playlists, limit: 50)
            guard generation == requestGeneration else { return }
            if let result { playlists = result.playlists ?? playlists } else { loadedTabs.remove(tab) }
        }
    }

    // MARK: - Cross-platform search (Beans QQ/Kugou)

    /// Songs, artists and albums go cross-platform: platform hits are
    /// appended after the NetEase ones and open the platform detail
    /// pages (`PlatformArtistDetailView` / `PlatformAlbumDetailView`),
    /// which carry everything playback needs (platform + key). Only
    /// the playlists tab stays NetEase-only — there is no platform
    /// playlist detail page.
    ///
    /// Each search runs only when its source toggle is on
    /// (`enabledAudioSourceIDs` — both are opt-in script backends, off
    /// by default), and a platform failure returns [] instead of
    /// throwing, so it can never fail the tab: NetEase results stand.

    private func searchQQSongs(keyword: String) async -> [Track] {
        guard SettingsManager.shared.enabledAudioSourceIDs.contains(.qqmusic) else { return [] }
        guard let results = try? await QQMusicAPI.shared.searchSongs(keyword: keyword, limit: 30) else { return [] }
        return results.compactMap(Track.fromQQSong)
    }

    private func searchKugouSongs(keyword: String) async -> [Track] {
        guard SettingsManager.shared.enabledAudioSourceIDs.contains(.kugou) else { return [] }
        guard let results = try? await KugouMusicAPI.shared.searchSongs(keyword: keyword, limit: 30) else { return [] }
        return results.compactMap(Track.fromKugouSong)
    }

    private func searchQQArtists(keyword: String, limit: Int) async -> [PlatformArtistSummary] {
        guard SettingsManager.shared.enabledAudioSourceIDs.contains(.qqmusic) else { return [] }
        guard let results = try? await QQMusicAPI.shared.searchArtists(keyword: keyword, limit: limit) else { return [] }
        return results.map {
            PlatformArtistSummary(source: .qqmusic, name: $0.name, picURL: $0.picURL, platformID: $0.mid)
        }
    }

    private func searchKugouArtists(keyword: String, limit: Int) async -> [PlatformArtistSummary] {
        guard SettingsManager.shared.enabledAudioSourceIDs.contains(.kugou) else { return [] }
        guard let results = try? await KugouMusicAPI.shared.searchArtists(keyword: keyword, limit: limit) else { return [] }
        return results.map {
            PlatformArtistSummary(source: .kugou, name: $0.name, picURL: $0.picURL, platformID: $0.authorID)
        }
    }

    private func searchQQAlbums(keyword: String, limit: Int) async -> [PlatformAlbumSummary] {
        guard SettingsManager.shared.enabledAudioSourceIDs.contains(.qqmusic) else { return [] }
        guard let results = try? await QQMusicAPI.shared.searchAlbums(keyword: keyword, limit: limit) else { return [] }
        return results.map {
            PlatformAlbumSummary(source: .qqmusic, name: $0.name, artistName: $0.artistName,
                                 picURL: $0.picURL, platformID: $0.mid)
        }
    }

    private func searchKugouAlbums(keyword: String, limit: Int) async -> [PlatformAlbumSummary] {
        guard SettingsManager.shared.enabledAudioSourceIDs.contains(.kugou) else { return [] }
        guard let results = try? await KugouMusicAPI.shared.searchAlbums(keyword: keyword, limit: limit) else { return [] }
        return results.map {
            PlatformAlbumSummary(source: .kugou, name: $0.name, artistName: $0.artistName,
                                 picURL: $0.picURL, platformID: $0.albumId)
        }
    }

    /// Platform artists go after the NetEase artists, in QQ-then-Kugou
    /// order, skipping any whose normalized name already appears in
    /// the NetEase list (or earlier in the merge). `cap` bounds the
    /// merged platform list (the .all tab caps at 10); the dedicated
    /// tab takes everything the searches returned.
    private func mergePlatformArtists(
        netEase: [ArtistSummary], qq: [PlatformArtistSummary], kugou: [PlatformArtistSummary],
        cap: Int? = nil
    ) -> [PlatformArtistSummary] {
        var seen = Set(netEase.map { normalizedName($0.name) })
        var merged: [PlatformArtistSummary] = []
        for artist in qq + kugou {
            let key = normalizedName(artist.name)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(artist)
            if let cap, merged.count >= cap { break }
        }
        return merged
    }

    /// Same append-after + dedup for albums, keyed on normalized
    /// "album|artist" so a same-name album by another artist survives.
    private func mergePlatformAlbums(
        netEase: [AlbumSummary], qq: [PlatformAlbumSummary], kugou: [PlatformAlbumSummary],
        cap: Int? = nil
    ) -> [PlatformAlbumSummary] {
        var seen = Set(netEase.map { normalizedAlbumKey(name: $0.name, artist: $0.artistName) })
        var merged: [PlatformAlbumSummary] = []
        for album in qq + kugou {
            let key = normalizedAlbumKey(name: album.name, artist: album.artistName)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(album)
            if let cap, merged.count >= cap { break }
        }
        return merged
    }

    private func normalizedName(_ value: String) -> String {
        value.lowercased().filter { !$0.isWhitespace }
    }

    private func normalizedAlbumKey(name: String, artist: String) -> String {
        normalizedName(name) + "|" + normalizedName(artist)
    }

    /// Platform songs go after the NetEase songs, in QQ-then-Kugou
    /// order, skipping any whose normalized (title + first artist)
    /// already appears in the NetEase list (or earlier in the merge).
    private func mergePlatformSongs(netEase: [Track], qq: [Track], kugou: [Track]) -> [Track] {
        var seen = Set(netEase.map { normalizedSongKey(title: $0.name, artist: $0.artists.first?.name ?? "") })
        var merged = netEase
        for track in qq + kugou {
            let key = normalizedSongKey(title: track.name, artist: track.artists.first?.name ?? "")
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            merged.append(track)
        }
        return merged
    }

    private func normalizedSongKey(title: String, artist: String) -> String {
        let fold: (String) -> String = { $0.lowercased().filter { !$0.isWhitespace } }
        return fold(title) + "|" + fold(artist)
    }
}

struct SearchView: View {
    @StateObject private var model: SearchViewModel
    @State private var searchText: String = ""

    init(query: String) {
        _model = StateObject(wrappedValue: SearchViewModel(query: query))
        _searchText = State(initialValue: query)
    }

    var body: some View {
        searchContent
        #if os(iOS)
        // iPad enters SearchView from the sidebar, where the desktop window
        // toolbar search field is unavailable. On macOS, MainWindow owns the
        // only search field and navigates here with its submitted query.
        // Keep the field pinned under the title. The default drawer collapses
        // until the page scrolls, and the empty search page has nothing to
        // scroll, so the field stayed hidden on the iPhone Search tab.
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "搜索歌曲、歌手、专辑、歌单"
        )
        .onSubmit(of: .search) {
            model.setQuery(searchText)
            Task { await model.load(tab: model.tab) }
        }
        .onChange(of: searchText) { newValue in
            model.setQuery(newValue)
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if searchText == newValue {
                    await model.load(tab: model.tab)
                }
            }
        }
        #endif
        .navigationTitle(searchText.isEmpty ? "搜索" : String(localized: "搜索：\(searchText)"))
        .task(id: model.tab) {
            await model.load(tab: model.tab)
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        #if os(macOS)
        if model.tab == .songs, !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            TrackListScrollView(trackIDs: model.songs.map(\.id)) {
                VStack(spacing: 20) {
                    tabPicker
                    if model.isLoading && currentEmpty {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                    }
                }
            } rows: { layout in
                TrackListView(tracks: model.songs, layout: layout)
                    .padding(.horizontal, Theme.Layout.contentInset - 10)
            } footer: {
                PlayerClearanceSpacer()
            }
        } else {
            mixedResults.clipped()
        }
        #else
        mixedResults
        #endif
    }

    private var mixedResults: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    tabPicker

                    if model.isLoading && currentEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        tabContent
                    }
                } else {
                    emptySearchPrompt
                }
                PlayerClearanceSpacer()
            }
        }
    }

    private var tabPicker: some View {
        Picker("", selection: $model.tab) {
            ForEach(SearchViewModel.Tab.allCases) { tab in
                Text(LocalizedStringKey(tab.rawValue)).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, Theme.Layout.contentInset)
        .padding(.top, 12)
    }

    private var emptySearchPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.top, 60)
            Text("探索海量华语流行与经典音乐")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("输入歌曲名称、歌手名或歌单关键字开始搜索")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
    }

    private var currentEmpty: Bool {
        switch model.tab {
        case .all: return model.songs.isEmpty && model.artists.isEmpty
            && model.platformArtists.isEmpty && model.platformAlbums.isEmpty
        case .songs: return model.songs.isEmpty
        case .artists: return model.artists.isEmpty && model.platformArtists.isEmpty
        case .albums: return model.albums.isEmpty && model.platformAlbums.isEmpty
        case .playlists: return model.playlists.isEmpty
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch model.tab {
        case .all:
            if !model.songs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "单曲") {
                        model.tab = .songs
                    }
                    .padding(.horizontal, Theme.Layout.contentInset)
                    TrackListView(tracks: Array(model.songs.prefix(6)))
                        .padding(.horizontal, Theme.Layout.contentInset - 10)
                }
            }
            if !model.artists.isEmpty || !model.platformArtists.isEmpty {
                Shelf(title: "歌手", seeAll: { model.tab = .artists }) {
                    artistCards(model.artists.prefix(8))
                    platformArtistCards(model.platformArtists)
                }
            }
            if !model.albums.isEmpty || !model.platformAlbums.isEmpty {
                Shelf(title: "专辑", seeAll: { model.tab = .albums }) {
                    albumCards(model.albums.prefix(8))
                    platformAlbumCards(model.platformAlbums)
                }
            }
            if !model.playlists.isEmpty {
                Shelf(title: "歌单", seeAll: { model.tab = .playlists }) {
                    playlistCards(model.playlists.prefix(8))
                }
            }
            if currentEmpty, !model.isLoading {
                EmptyStateView(icon: "magnifyingglass", title: "没有找到相关结果")
                    .frame(minHeight: 300)
            }
        case .songs:
            TrackListView(tracks: model.songs)
                .padding(.horizontal, Theme.Layout.contentInset - 10)
        case .artists:
            CardGrid(minWidth: 140) {
                artistCards(model.artists)
                platformArtistCards(model.platformArtists)
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        case .albums:
            CardGrid {
                albumCards(model.albums)
                platformAlbumCards(model.platformAlbums)
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        case .playlists:
            CardGrid {
                playlistCards(model.playlists)
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        }
    }

    private func artistCards(_ items: some Collection<ArtistSummary>) -> some View {
        ForEach(Array(items)) { artist in
            NavigationLink {
                ArtistDetailView(artistID: artist.id)
            } label: {
                VStack(spacing: 10) {
                    CachedAsyncImage(url: artist.picUrl?.resizedImageURL(256))
                        .frame(width: 128, height: 128)
                        .clipShape(Circle())
                    Text(artist.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .frame(width: 140)
            }
            .buttonStyle(.plain)
        }
    }

    private func albumCards(_ items: some Collection<AlbumSummary>) -> some View {
        ForEach(Array(items)) { album in
            NavigationLink {
                AlbumDetailView(albumID: album.id)
            } label: {
                CoverCardBody(
                    coverURL: album.picUrl?.resizedImageURL(384),
                    title: album.name,
                    subtitle: album.artistName
                )
            }
            .buttonStyle(.plain)
        }
    }

    /// Same circular-image layout as `artistCards`, with a small
    /// source caption under the name so a QQ/Kugou hit is
    /// distinguishable from a NetEase one. Opens the platform
    /// artist page, never the NetEase one.
    private func platformArtistCards(_ items: [PlatformArtistSummary]) -> some View {
        ForEach(items) { artist in
            NavigationLink {
                PlatformArtistDetailView(artist: artist)
            } label: {
                VStack(spacing: 10) {
                    // Platform covers are already sized by the API
                    // (QQ 300px, Kugou 300/400px); the NetEase
                    // `?param=` resize convention does not apply.
                    CachedAsyncImage(url: artist.picURL)
                        .frame(width: 128, height: 128)
                        .clipShape(Circle())
                    VStack(spacing: 2) {
                        Text(artist.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(artist.source.displayName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: 140)
            }
            .buttonStyle(.plain)
        }
    }

    /// Same `CoverCardBody` as `albumCards`, with a small source
    /// caption underneath. Opens the platform album page.
    private func platformAlbumCards(_ items: [PlatformAlbumSummary]) -> some View {
        ForEach(items) { album in
            NavigationLink {
                PlatformAlbumDetailView(album: album)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    CoverCardBody(
                        coverURL: album.picURL,
                        title: album.name,
                        subtitle: album.artistName
                    )
                    Text(album.source.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func playlistCards(_ items: some Collection<PlaylistSummary>) -> some View {
        ForEach(Array(items)) { playlist in
            NavigationLink {
                PlaylistDetailView(playlistID: playlist.id)
            } label: {
                CoverCardBody(
                    coverURL: playlist.coverURL?.resizedImageURL(384),
                    title: playlist.name,
                    playCount: playlist.playCount
                )
            }
            .buttonStyle(.plain)
        }
    }
}
