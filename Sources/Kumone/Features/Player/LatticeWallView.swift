import SwiftUI

/// Folia Lattice (P2) cover wall: the current queue as a grid of cover
/// tiles, modelled on Folia's PosterWall/wallLayout. The currently-playing
/// tile is marked with an accent ring and a 播放中 badge; tapping any tile
/// jumps to that track. No visualizer themes, no hover states — one static
/// grid style only.
enum LatticeWallLayout {
    /// Number of cover columns that fit `width` with tiles at least
    /// `minTile` wide and `spacing` between them.
    static func columns(for width: CGFloat, minTile: CGFloat = 76, spacing: CGFloat = 8) -> Int {
        guard width > 0 else { return 1 }
        return max(1, Int((width + spacing) / (minTile + spacing)))
    }

    /// Tile side for `columns` across `width` with `spacing` between tiles.
    static func tileSize(for width: CGFloat, columns: Int, spacing: CGFloat = 8) -> CGFloat {
        guard columns > 0 else { return 0 }
        return max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
    }
}

struct LatticeWallView: View {
    let queue: [Track]
    let currentTrackID: Int?
    let onSelect: (Track) -> Void

    var body: some View {
        if queue.isEmpty {
            Text("播放队列为空")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geo in
                let columns = LatticeWallLayout.columns(for: geo.size.width)
                let tile = LatticeWallLayout.tileSize(for: geo.size.width, columns: columns)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.fixed(tile), spacing: 8),
                                count: columns
                            ),
                            spacing: 8
                        ) {
                            ForEach(queue) { track in
                                tileView(track, size: tile)
                                    .id(track.id)
                            }
                        }
                    }
                    .onAppear {
                        // Land on the playing tile: the grid lays out a turn
                        // later, like the lyrics list's adoptCursor.
                        guard let currentTrackID else { return }
                        DispatchQueue.main.async {
                            withAnimation {
                                proxy.scrollTo(currentTrackID, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }

    private func tileView(_ track: Track, size: CGFloat) -> some View {
        let isCurrent = track.id == currentTrackID
        return Button {
            onSelect(track)
        } label: {
            CachedAsyncImage(url: track.album.picUrl?.resizedImageURL(96), animated: false)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.white, lineWidth: 2)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if isCurrent {
                        Text("播放中")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.6), in: Capsule())
                            .padding(4)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(track.name)
    }
}
