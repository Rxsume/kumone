import SwiftUI

/// Album page for a QQ/Kugou search hit. Mirrors `AlbumDetailView`'s
/// visual language (cover + name + artist, "N 首 · publish date"
/// line, description section, 播放全部, `TrackListView`, other-albums
/// shelf, loading skeleton + error + retry), but everything loads
/// from the platform APIs — there is no NetEase ID behind these
/// albums.
///
/// Deliberately absent: subscribe/download buttons (NetEase-only
/// concepts). The artist name is plain text except on the QQ
/// mid-based path, where the detail response carries the artist mid
/// and the name links to `PlatformArtistDetailView`.
struct PlatformAlbumDetailView: View {
    let album: PlatformAlbumSummary

    @State private var detail: QQMusicAlbumDetail?
    @State private var tracks: [Track] = []
    @State private var otherAlbums: [PlatformAlbumSummary] = []
    @State private var artistMid: String?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showFullDescription = false
    @State private var loadGeneration = 0

    private let player = PlayerService.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var isCompact: Bool {
        #if os(iOS)
        return LayoutSizeClass.isCompact(horizontal: horizontalSizeClass, vertical: verticalSizeClass,
                                         fallback: UIDevice.current.userInterfaceIdiom == .phone)
        #else
        return false
        #endif
    }

    /// Header fields: the detail response wins on the QQ mid path,
    /// otherwise the search summary is all there is.
    private var displayName: String { detail?.name ?? album.name }
    private var displayArtistName: String { detail?.artistName ?? album.artistName }
    private var coverURL: URL? { detail?.picURL ?? album.picURL }
    private var publishDate: String? { detail?.publishDate }
    private var albumDescription: String? { detail?.description }

    var body: some View {
        TrackListScrollView(trackIDs: tracks.map(\.id), spacing: isCompact ? 16 : 20) {
            VStack(alignment: .leading, spacing: isCompact ? 16 : 20) {
                if !isLoading, errorMessage == nil {
                    if isCompact {
                        compactHeader.padding(.horizontal, 16).padding(.top, 12)
                    } else {
                        regularHeader.padding(.horizontal, Theme.Layout.contentInset).padding(.top, 16)
                    }
                } else if isLoading {
                    loadingHeader
                } else if let errorMessage {
                    ErrorStateView(message: errorMessage) { Task { await load() } }
                        .frame(minHeight: 400)
                }
            }
        } rows: { layout in
            // Platform tracks carry no NetEase context: play with the
            // `.none` default, like search results do.
            TrackListView(tracks: tracks, layout: layout)
                .padding(.horizontal, isCompact ? 6 : Theme.Layout.contentInset - 10)
        } footer: {
            VStack(alignment: .leading, spacing: isCompact ? 16 : 20) {
                if !otherAlbums.isEmpty {
                    SectionHeader(title: "该歌手的其他专辑")
                        .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)
                        .padding(.top, 12)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                            ForEach(otherAlbums) { item in
                                NavigationLink {
                                    PlatformAlbumDetailView(album: item)
                                } label: {
                                    CoverCardBody(
                                        coverURL: item.picURL,
                                        title: item.name,
                                        subtitle: nil
                                    )
                                }
                                .buttonStyle(.interactiveCard)
                            }
                            Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                        }
                    }
                }
                PlayerClearanceSpacer()
            }
        }
        #if os(macOS)
        .navigationTitle(displayName)
        #else
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await load()
        }
    }

    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            switch album.source {
            case .qqmusic:
                if let mid = album.platformID, !mid.isEmpty {
                    let loaded = try await QQMusicAPI.shared.albumDetail(mid: mid)
                    guard generation == loadGeneration, !Task.isCancelled else { return }
                    detail = loaded
                    artistMid = loaded.artistMid
                    tracks = loaded.songs.compactMap(Track.fromQQSong)
                } else {
                    // Name-only fallback hit: no mid, so no detail
                    // endpoint — reconstruct the track list from song
                    // search (see the helper below).
                    tracks = await qqAlbumSongsByNameFallback()
                }
                // Other-albums shelf, QQ only. `artistMid` is nil on
                // the name-based path; the call still works by name.
                if let others = try? await QQMusicAPI.shared.artistAlbums(
                    name: album.artistName, mid: artistMid) {
                    guard generation == loadGeneration, !Task.isCancelled else { return }
                    otherAlbums = others
                        .filter { !isCurrentAlbum($0) }
                        .map {
                            PlatformAlbumSummary(source: .qqmusic, name: $0.name, artistName: $0.artistName,
                                                 picURL: $0.picURL, platformID: $0.mid)
                        }
                }
            case .kugou:
                // Kugou has no album-detail endpoint; the album's songs
                // come from a name lookup. No other-albums shelf on
                // this path (no authorID is carried here).
                let songs = try await KugouMusicAPI.shared.albumSongsByName(
                    albumName: album.name, artistName: album.artistName)
                guard generation == loadGeneration, !Task.isCancelled else { return }
                tracks = songs.compactMap(Track.fromKugouSong)
            default:
                break
            }
            isLoading = false
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Excludes the album this page is showing from the other-albums
    /// shelf: by mid when both sides have one, otherwise by name.
    private func isCurrentAlbum(_ other: QQMusicAlbum) -> Bool {
        if let otherMid = other.mid, let currentMid = album.platformID,
           !otherMid.isEmpty, !currentMid.isEmpty {
            return otherMid == currentMid
        }
        return other.name == album.name
    }

    /// Name-based fallback for QQ albums without a mid: search songs
    /// for "artist album", then the album name alone, and keep only
    /// the songs whose album + artist match this album.
    private func qqAlbumSongsByNameFallback() async -> [Track] {
        let fold: (String) -> String = { $0.lowercased().filter { !$0.isWhitespace } }
        let wantAlbum = fold(album.name)
        let wantArtist = fold(album.artistName)
        for query in ["\(album.artistName) \(album.name)", album.name] {
            guard let results = try? await QQMusicAPI.shared.searchSongs(keyword: query, limit: 100) else { continue }
            let matched = results.filter { song in
                fold(song.albumName) == wantAlbum
                    && (wantArtist.isEmpty || song.artistNames.contains { fold($0) == wantArtist })
            }
            if !matched.isEmpty {
                return matched.compactMap(Track.fromQQSong)
            }
        }
        return []
    }

    // MARK: - Compact Header

    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                CachedAsyncImage(url: coverURL)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text(displayName)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(3)

                    artistNameView(fontSize: 13)

                    Text(countLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let description = albumDescription, !description.isEmpty {
                Button {
                    showFullDescription = true
                } label: {
                    HStack(spacing: 4) {
                        Text(description.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showFullDescription) {
                    NavigationStack {
                        ScrollView {
                            Text(description)
                                .font(.system(size: 14))
                                .padding(20)
                        }
                        .navigationTitle("专辑简介")
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                Button("完成") { showFullDescription = false }
                            }
                        }
                    }
                }
            }

            // Compact Action Bar
            HStack(spacing: 10) {
                Button {
                    player.play(tracks: tracks, source: .none)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("播放全部 (\(tracks.count))")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Theme.accentGradient, in: Capsule())
                    .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
                }
                .buttonStyle(.pressable)
                .disabled(tracks.isEmpty)
            }
        }
    }

    // MARK: - Regular Header

    private var regularHeader: some View {
        HStack(alignment: .bottom, spacing: 24) {
            CachedAsyncImage(url: coverURL)
                .frame(width: 200, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)

            VStack(alignment: .leading, spacing: 8) {
                Text(album.source.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(displayName)
                    .font(.title.weight(.bold))
                    .lineLimit(2)

                artistNameView(fontSize: 14)

                Text(countLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)

                if let description = albumDescription, !description.isEmpty {
                    Button {
                        showFullDescription = true
                    } label: {
                        Text(description.replacingOccurrences(of: "\n", with: " "))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showFullDescription, arrowEdge: .bottom) {
                        ScrollView {
                            Text(description)
                                .font(.system(size: 13))
                                .padding(16)
                                .frame(width: 380, alignment: .leading)
                        }
                        .frame(maxHeight: 400)
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 10) {
                    Button {
                        player.play(tracks: tracks, source: .none)
                    } label: {
                        Label("播放", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Theme.accentGradient, in: Capsule())
                            .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
                    }
                    .buttonStyle(.pressable)
                    .disabled(tracks.isEmpty)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 210)
    }

    private var countLine: String {
        if let publishDate, !publishDate.isEmpty {
            return "\(tracks.count) 首 · \(publishDate)"
        }
        return "\(tracks.count) 首"
    }

    /// The artist name links to the platform artist page only on the
    /// QQ mid-based path, where the detail response carries the
    /// artist mid; everywhere else it is plain text.
    @ViewBuilder
    private func artistNameView(fontSize: CGFloat) -> some View {
        if album.source == .qqmusic, let artistMid, !artistMid.isEmpty {
            NavigationLink {
                PlatformArtistDetailView(artist: PlatformArtistSummary(
                    source: .qqmusic, name: displayArtistName, picURL: nil, platformID: artistMid))
            } label: {
                Text(displayArtistName)
                    .font(.system(size: fontSize, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
        } else {
            Text(displayArtistName)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var loadingHeader: some View {
        HStack(alignment: .top, spacing: isCompact ? 14 : 24) {
            SkeletonView(cornerRadius: isCompact ? Theme.Radius.standard : Theme.Radius.large)
                .frame(width: isCompact ? 120 : 200, height: isCompact ? 120 : 200)

            VStack(alignment: .leading, spacing: 10) {
                SkeletonView(cornerRadius: 4).frame(width: 80, height: 14)
                SkeletonView(cornerRadius: 4).frame(maxWidth: isCompact ? 160 : 200, minHeight: 14, maxHeight: 14)
                SkeletonView(cornerRadius: 4).frame(width: 120, height: 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)
        .padding(.top, isCompact ? 12 : 16)
    }
}
