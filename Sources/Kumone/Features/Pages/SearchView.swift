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
            let (songResult, artistResult, albumResult, playlistResult, qqSongs, kgSongs) =
                await (songsTask, artistsTask, albumsTask, playlistsTask, qqSongsTask, kgSongsTask)
            guard generation == requestGeneration else { return }
            songs = mergePlatformSongs(netEase: songResult?.songs ?? [], qq: qqSongs, kugou: kgSongs)
            artists = artistResult?.artists ?? []
            albums = albumResult?.albums ?? []
            playlists = playlistResult?.playlists ?? []
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
            let result = try? await MusicAPI.search(trimmed, type: .artists, limit: 50)
            guard generation == requestGeneration else { return }
            if let result { artists = result.artists ?? artists } else { loadedTabs.remove(tab) }
        case .albums:
            let result = try? await MusicAPI.search(trimmed, type: .albums, limit: 50)
            guard generation == requestGeneration else { return }
            if let result { albums = result.albums ?? albums } else { loadedTabs.remove(tab) }
        case .playlists:
            let result = try? await MusicAPI.search(trimmed, type: .playlists, limit: 50)
            guard generation == requestGeneration else { return }
            if let result { playlists = result.playlists ?? playlists } else { loadedTabs.remove(tab) }
        }
    }

    // MARK: - Cross-platform song search (Beans QQ/Kugou, v1: songs only)

    /// Artists/albums/playlists tabs stay NetEase-only: Golia's
    /// artist/album detail pages are NetEase-ID-based, so a QQ/Kugou
    /// artist or album card would navigate to a dead NetEase detail
    /// page. Songs carry everything playback needs (platform + key),
    /// so only songs go cross-platform in v1.
    ///
    /// Each search runs only when its source toggle is on
    /// (`enabledAudioSourceIDs` — both are opt-in script backends, off
    /// by default), and a platform failure returns [] instead of
    /// throwing, so it can never fail the tab: NetEase results stand.

    private func searchQQSongs(keyword: String) async -> [Track] {
        guard SettingsManager.shared.enabledAudioSourceIDs.contains(.qqmusic) else { return [] }
        guard let results = try? await QQMusicAPI.shared.searchSongs(keyword: keyword, limit: 30) else { return [] }
        return results.compactMap { song in
            guard !song.title.isEmpty else { return nil }
            let key: String
            if let mediaMid = song.mediaMid, !mediaMid.isEmpty {
                key = "\(song.songmid)|\(mediaMid)"
            } else {
                key = song.songmid
            }
            return Track.platform(
                source: .qqmusic, songKey: key, name: song.title,
                artistNames: song.artistNames, albumName: song.albumName,
                albumPicURL: song.albumPicURL, durationMS: song.durationMS)
        }
    }

    private func searchKugouSongs(keyword: String) async -> [Track] {
        guard SettingsManager.shared.enabledAudioSourceIDs.contains(.kugou) else { return [] }
        guard let results = try? await KugouMusicAPI.shared.searchSongs(keyword: keyword, limit: 30) else { return [] }
        return results.compactMap { song in
            guard !song.title.isEmpty, !song.hash.isEmpty else { return nil }
            let key: String
            if let audioId = song.albumAudioId, !audioId.isEmpty,
               let albumId = song.albumId, !albumId.isEmpty {
                key = "\(song.hash)|\(audioId)|\(albumId)"
            } else {
                key = song.hash
            }
            return Track.platform(
                source: .kugou, songKey: key, name: song.title,
                artistNames: song.artistNames, albumName: song.albumName,
                albumPicURL: song.albumPicURL, durationMS: song.durationMS)
        }
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
        case .songs: return model.songs.isEmpty
        case .artists: return model.artists.isEmpty
        case .albums: return model.albums.isEmpty
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
            if !model.artists.isEmpty {
                Shelf(title: "歌手", seeAll: { model.tab = .artists }) {
                    artistCards(model.artists.prefix(8))
                }
            }
            if !model.albums.isEmpty {
                Shelf(title: "专辑", seeAll: { model.tab = .albums }) {
                    albumCards(model.albums.prefix(8))
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
            }
            .padding(.horizontal, Theme.Layout.contentInset)
        case .albums:
            CardGrid {
                albumCards(model.albums)
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
