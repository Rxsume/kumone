import SwiftUI

// MARK: - 听歌排行

/// 歌手榜的一行：把 `/user/record` 的单曲记录按歌手汇总而来，
///
/// 网易云没有单独的“歌手排行”接口，同一首歌有多个歌手时播放次数计入每一位歌手。
struct ArtistRankingEntry: Identifiable {
    var id: Int { artistID }
    let artistID: Int
    let name: String
    let playCount: Int
    let tracks: [Track]
}

enum RankingAggregation {
    /// Aggregate per-artist play counts from the song records of one period.
    /// A track with several artists credits its play count to each of them.
    static func artistRanking(from records: [PlayRecordItem]) -> [ArtistRankingEntry] {
        var byArtist: [Int: (name: String, playCount: Int, tracks: [Track])] = [:]
        for record in records {
            for artist in record.song.artists {
                var entry = byArtist[artist.id] ?? (name: artist.name, playCount: 0, tracks: [])
                entry.playCount += record.playCount
                entry.tracks.append(record.song)
                byArtist[artist.id] = entry
            }
        }
        return byArtist.map { id, entry in
            ArtistRankingEntry(artistID: id, name: entry.name, playCount: entry.playCount,
                               tracks: entry.tracks)
        }.sorted { $0.playCount > $1.playCount }
    }
}

struct RankingView: View {
    @State private var records: [PlayRecordItem] = []
    @State private var week = true
    @State private var tab = 0
    @State private var isLoading = true

    @EnvironmentObject private var account: AccountStore
    @ObservedObject private var scrobble = ScrobbleStore.shared
    private let player = PlayerService.shared

    private var artistRanking: [ArtistRankingEntry] {
        RankingAggregation.artistRanking(from: records)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                scrobbleSection

                HStack {
                    Picker("", selection: $week) {
                        Text("最近一周").tag(true)
                        Text("所有时间").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)

                    Spacer()

                    if tab == 0 {
                        Button {
                            player.play(tracks: records.map(\.song), source: .none, context: .recents)
                        } label: {
                            Label("播放全部", systemImage: "play.fill")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Theme.accentGradient, in: Capsule())
                        }
                        .buttonStyle(.pressable)
                        .disabled(records.isEmpty)
                    }
                }

                Picker("", selection: $tab) {
                    Text("单曲").tag(0)
                    Text("歌手").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else if records.isEmpty {
                    EmptyStateView(icon: "chart.bar", title: "暂无排行数据",
                                   subtitle: "开启听歌打卡后，播放记录会上报，排行才会更新")
                        .frame(minHeight: 300)
                } else if tab == 0 {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(records.enumerated()), id: \.element.song.id) { index, record in
                            TrackRow(
                                track: record.song,
                                index: index + 1,
                                style: .compact,
                                trailingText: String(localized: "\(record.playCount) 次")
                            ) {
                                player.play(tracks: records.map(\.song), source: .none,
                                            startAt: record.song, context: .recents)
                            }
                        }
                    }
                } else {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(artistRanking.enumerated()), id: \.element.artistID) { index, entry in
                            artistRow(at: index, entry: entry)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Layout.contentInset)
            .padding(.top, 12)
            PlayerClearanceSpacer()
        }
        .navigationTitle("听歌排行")
        .task(id: week) {
            await load()
        }
    }

    /// The scrobble toggle lives on this page, not in Settings: reporting is
    /// what feeds this ranking, so the switch sits next to the data it feeds.
    /// Off by default — nothing is reported until the user turns it on here.
    private var scrobbleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("听歌打卡", isOn: $scrobble.isEnabled)
                .font(.system(size: 14, weight: .semibold))
            Text("开启后，播放网易云歌曲会上报听歌记录，用于生成听歌排行与最近播放；关闭后不再上报。排行数据来自网易云音乐账号，QQ / 酷狗没有对应的排行接口。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func artistRow(at index: Int, entry: ArtistRankingEntry) -> some View {
        Button {
            player.play(tracks: entry.tracks, source: .none, context: .recents)
        } label: {
            HStack(spacing: 12) {
                Text("\(index + 1)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(index < 3 ? Theme.accent : .secondary)
                    .frame(width: 24, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text("\(entry.tracks.count) 首上榜")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(entry.playCount) 次")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        guard let uid = account.profile?.userId else {
            isLoading = false
            return
        }
        isLoading = records.isEmpty
        records = (try? await MusicAPI.playRecords(uid: uid, week: week)) ?? []
        isLoading = false
    }
}
