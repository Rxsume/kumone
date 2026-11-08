import SwiftUI

/// Artist page for a QQ/Kugou search hit. Mirrors `ArtistDetailView`'s
/// visual language (compact/regular headers, circular pic, counts,
/// 播放热门, 热门单曲 with a compact `TrackListView`, album shelf),
/// but everything loads from the platform APIs — there is no NetEase
/// ID behind these artists.
///
/// Deliberately absent: follow button, similar artists, bio. No
/// endpoints exist for those on either platform, so the header shows
/// only what the APIs return (name, picture, song/album counts).
struct PlatformArtistDetailView: View {
    let artist: PlatformArtistSummary

    @State private var hotSongs: [Track] = []
    @State private var albums: [PlatformAlbumSummary] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

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

    var body: some View {
        TrackListScrollView(trackIDs: hotSongs.map(\.id), style: .compact, spacing: isCompact ? 16 : 26) {
            VStack(alignment: .leading, spacing: isCompact ? 16 : 26) {
                if !isLoading, errorMessage == nil {
                    if isCompact {
                        compactHeader.padding(.horizontal, 16).padding(.top, 12)
                    } else {
                        regularHeader.padding(.horizontal, Theme.Layout.contentInset).padding(.top, 16)
                    }
                    if !hotSongs.isEmpty {
                        SectionHeader(title: "热门单曲")
                            .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)
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
            TrackListView(tracks: hotSongs, style: .compact, layout: layout)
                .padding(.horizontal, isCompact ? 6 : Theme.Layout.contentInset - 10)
        } footer: {
            VStack(alignment: .leading, spacing: isCompact ? 16 : 26) {
                if !albums.isEmpty {
                    SectionHeader(title: "专辑")
                        .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                            ForEach(albums) { album in
                                albumCard(album)
                            }
                            Spacer().frame(width: (isCompact ? 16 : Theme.Layout.contentInset) - 16)
                        }
                    }
                }
                PlayerClearanceSpacer()
            }
        }
        #if os(macOS)
        .navigationTitle(artist.name)
        #else
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            switch artist.source {
            case .qqmusic:
                async let songsTask = QQMusicAPI.shared.artistSongs(
                    name: artist.name, mid: artist.platformID)
                async let albumsTask = QQMusicAPI.shared.artistAlbums(
                    name: artist.name, mid: artist.platformID)
                let (songs, qqAlbums) = try await (songsTask, albumsTask)
                hotSongs = songs.compactMap(Track.fromQQSong)
                albums = qqAlbums.map {
                    PlatformAlbumSummary(source: .qqmusic, name: $0.name, artistName: $0.artistName,
                                         picURL: $0.picURL, platformID: $0.mid)
                }
            case .kugou:
                let songs: [KugouMusicSong]
                if let authorID = artist.platformID, !authorID.isEmpty {
                    songs = try await KugouMusicAPI.shared.artistSongs(authorID: authorID)
                } else {
                    // Name-only fallback hit (aggregated from song
                    // search, no author id): fall back to a name search.
                    songs = try await KugouMusicAPI.shared.artistSongsByName(name: artist.name)
                }
                hotSongs = songs.compactMap(Track.fromKugouSong)
                albums = KugouMusicAPI.albums(from: songs).map {
                    PlatformAlbumSummary(source: .kugou, name: $0.name, artistName: $0.artistName,
                                         picURL: $0.picURL, platformID: $0.albumId)
                }
            default:
                hotSongs = []
                albums = []
            }
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Compact Header

    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                CachedAsyncImage(url: artist.picURL)
                    .frame(width: 100, height: 100)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 5) {
                    Text(artist.name)
                        .font(.system(size: 18, weight: .bold))
                        .lineLimit(2)
                    Text(artist.source.displayName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("\(hotSongs.count) 首歌曲 · \(albums.count) 张专辑")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            // Compact Action Bar
            HStack(spacing: 10) {
                Button {
                    player.play(tracks: hotSongs, source: .none)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("播放热门")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Theme.accentGradient, in: Capsule())
                    .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
                }
                .buttonStyle(.pressable)
                .disabled(hotSongs.isEmpty)
            }
        }
    }

    // MARK: - Regular Header

    private var regularHeader: some View {
        HStack(alignment: .center, spacing: 28) {
            CachedAsyncImage(url: artist.picURL)
                .frame(width: 180, height: 180)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)

            VStack(alignment: .leading, spacing: 8) {
                Text(artist.source.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(artist.name)
                    .font(.largeTitle.weight(.bold))
                Text("\(hotSongs.count) 首歌曲 · \(albums.count) 张专辑")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 6)

                HStack(spacing: 10) {
                    Button {
                        player.play(tracks: hotSongs, source: .none)
                    } label: {
                        Label("播放热门", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Theme.accentGradient, in: Capsule())
                            .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
                    }
                    .buttonStyle(.pressable)
                    .disabled(hotSongs.isEmpty)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func albumCard(_ album: PlatformAlbumSummary) -> some View {
        NavigationLink {
            PlatformAlbumDetailView(album: album)
        } label: {
            CoverCardBody(
                coverURL: album.picURL,
                title: album.name,
                subtitle: nil
            )
        }
        .buttonStyle(.interactiveCard)
    }

    private var loadingHeader: some View {
        HStack(alignment: .center, spacing: isCompact ? 14 : 24) {
            SkeletonView(cornerRadius: isCompact ? 50 : 90)
                .clipShape(Circle())
                .frame(width: isCompact ? 100 : 180, height: isCompact ? 100 : 180)

            VStack(alignment: .leading, spacing: 10) {
                SkeletonView(cornerRadius: 4).frame(maxWidth: isCompact ? 150 : 180, minHeight: 14, maxHeight: 14)
                SkeletonView(cornerRadius: 4).frame(width: 100, height: 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, isCompact ? 16 : Theme.Layout.contentInset)
        .padding(.top, isCompact ? 12 : 16)
    }
}
