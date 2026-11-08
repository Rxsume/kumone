import Foundation

// 飞牛音乐（fnOS 自托管 NAS）音源：按标题 + 歌手搜索，再用现成的
// AudioSourceTrackMatcher.matches 比对（标题、歌手、时长 ±5 秒），
// 命中后返回流地址 {base}/music/api/v1/track/stream?trackGUID=<guid>。
//
// 与现有四个音源不同：它们只用网易 ID 直接换 URL，不做跨平台搜索；
// 飞牛没有网易 ID，必须先搜歌再匹配（匹配器就是为这种场景准备的，
// 见 AudioSourceProvider.swift 的注释）。
//
// 协议来源：Folia v0.7.27 `src/services/onlineMusic/fnmusic/`
// （`fnmusicProvider.ts`：搜索 GET /music/api/v1/search/track?q=&page=&size=
// → { total, list }；播放 GET /music/api/v1/track/stream?trackGUID=；
// 只有 standard 一档，无音质选项）。搜索请求带
// `Cookie: music-token=<token>`（FNMusicSession 内部处理）。
//
// 接线前提（见 INTEGRATION-fnmusic.md）：
//  1. `AudioSourceID` 末尾要先追加 `.fnmusic` case，本文件才能编译；
//  2. 本文件只返回流地址 URL，不发播放请求——AVPlayer 播普通 URL
//     不会带 Cookie，播放时补 Cookie 头需后续一小步
//     （AVAssetResourceLoaderDelegate），不要在本文件里绕过去；
//  3. 未登录时 resolve 返回 nil（不抛错），UnblockService 会继续试
//     下一个音源；搜索本身失败（网络/401 等）则抛错，由
//     UnblockService 记一条失败日志后继续试下一个音源。
struct FNMusicAudioSourceProvider: AudioSourceProvider {
    let id: AudioSourceID = .fnmusic
    let displayName = AudioSourceID.fnmusic.displayName

    private let session: FNMusicSession

    init(session: FNMusicSession = .shared) {
        self.session = session
    }

    func resolve(track: Track) async throws -> ResolvedAudioSource? {
        // 未登录：静默跳过（不抛错、不打扰其他音源）。
        guard session.isAuthenticated else { return nil }
        let keyword = AudioSourceTrackMatcher.keyword(for: track)
        guard !keyword.isEmpty else { return nil }

        let page = try await session.searchTracks(keyword: keyword, page: 1, size: 10)
        for candidate in page.tracks {
            guard AudioSourceTrackMatcher.matches(
                track: track,
                title: candidate.title,
                artist: candidate.artists.joined(separator: " / "),
                durationMS: candidate.durationMS
            ) else { continue }
            guard let url = session.streamURL(trackGUID: candidate.id) else { continue }
            // 只返回流地址：Folia 里 track/stream 的响应体形状与
            // hls:// → /api/stream/unified 转 m3u8 的转换都在主进程桥内，
            // 稀疏克隆内无法核实；首次真机联调须确认该 URL 可直接播，
            // 见 INTEGRATION-fnmusic.md 第 3 节。
            return ResolvedAudioSource(id: id, displayName: displayName, url: url)
        }
        return nil
    }
}
