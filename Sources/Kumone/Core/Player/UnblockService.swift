import AVFoundation
import Foundation
import os.log

/// Resolves gray tracks, trying sources in this order: ikun first (the
/// preferred source), then the direct pyncmd source, then the remaining
/// providers (Haitangw / Xinghai, which resolve by NetEase ID directly
/// with no search step, then the Beans platform providers Kugou / QQ,
/// which resolve by cross-platform search + match and short-circuit
/// when `track.platformSource` is their own ID).
///
/// Kuwo was removed: Kuwo's unauthenticated convert_url
/// endpoint answers VIP tracks with a ~11s spoken prompt clip ("use the
/// latest Kuwo app") instead of the song, and the clip is playable, so
/// it used to be returned as if it were the track. Every resolved URL
/// is therefore checked here: if the audio it points at is far shorter
/// than the track, it is treated as a prompt/trial clip and the next
/// source is tried. A probe that errors or times out never rejects a
/// URL — it only rejects a clip whose duration is actually known.
enum UnblockService {
    private static let log = Logger(subsystem: "sb.moe.kumone", category: "audio-source")
    private static let httpClient = AudioSourceClient.shared
    private static let ikunProvider = IkunAudioSourceProvider()
    private static let fallbackProviders: [any AudioSourceProvider] = [
        HaitangwAudioSourceProvider(),
        XinghaiAudioSourceProvider(),
        // Folia platform providers, appended last so the existing order
        // is untouched. Kugou first: its anonymous search needs no
        // backend and no login, so it can resolve out of the box; QQ
        // only resolves once its login is configured.
        KugouAudioSourceProvider(),
        QQMusicAudioSourceProvider(),
    ]

    struct Resolution {
        let source: ResolvedAudioSource?
        let attemptedSources: Set<AudioSourceID>
    }

    static func resolve(
        _ track: Track,
        enabledSources: Set<AudioSourceID>,
        excluding attemptedSources: Set<AudioSourceID>
    ) async -> Resolution {
        var newlyAttemptedSources = Set<AudioSourceID>()
        guard !Task.isCancelled else { return Resolution(source: nil, attemptedSources: []) }
        // User-imported LX script sources FIRST, before the platform
        // rule: the user asked for the imported script to replace
        // 酸甜贤 as the default playback source. If every script
        // fails, the ladder continues exactly as today. The
        // `enableUnblock` gate lives at the call sites (PlayerService
        // / PlayerServiceIOS only call `resolve` when unblocking is
        // allowed), so it is not re-checked here. Order within the
        // step is the user's list order in the store.
        let customSources = await MainActor.run { CustomAudioSourceStore.shared.sources }
            .filter { $0.enabled && $0.script?.isEmpty == false }
        if !customSources.isEmpty, !attemptedSources.contains(.customScript) {
            newlyAttemptedSources.insert(.customScript)
            for source in customSources {
                guard !Task.isCancelled else { break }
                guard let scriptURL = await customScriptResolve(track, source: source) else { continue }
                let resolved = ResolvedAudioSource(id: .customScript, displayName: source.name, url: scriptURL)
                if await isUsable(resolved, track: track) {
                    return Resolution(source: resolved, attemptedSources: newlyAttemptedSources)
                }
            }
        }
        // Platform tracks resolve through the NetEase ladder FIRST:
        // the user asked for 酸甜贤 as the default playback source for
        // songs from all platforms ("搜索全平台歌曲播放音源酸甜贤").
        // Discovery stays cross-platform; only playback defaults to
        // ikun. The track is matched to the same song on NetEase and
        // resolved through ikun, then the rest of the NetEase ladder
        // (pyncmd, Haitangw, Xinghai), then the other platform's
        // provider (Kugou for QQ tracks, QQ for Kugou tracks); only
        // when none of those can resolve it does the flow fall through
        // to the generic chain below. Background: QQ's vkey endpoint
        // only issues playback URLs to logged-in sessions — live-probed
        // 2026-11-09, anonymous vkey answers code 0 with an empty purl
        // for every song and tier — so a logged-out QQ account gets no
        // QQ URL at all. Deliberately not gated on the ikun toggle:
        // this is the platform playback rule the user asked for.
        if track.platformSource == .qqmusic || track.platformSource == .kugou,
           let resolved = await platformTrackViaFallbacks(track) {
            return Resolution(source: resolved, attemptedSources: newlyAttemptedSources)
        }
        if enabledSources.contains(.ikun), !attemptedSources.contains(.ikun) {
            newlyAttemptedSources.insert(.ikun)
            do {
                if let resolved = try await ikunProvider.resolve(track: track),
                   await isUsable(resolved, track: track) {
                    return Resolution(
                        source: resolved,
                        attemptedSources: newlyAttemptedSources
                    )
                }
            } catch {
                logFailure(source: .ikun, operation: "resolve", error: error)
            }
        }

        if enabledSources.contains(.pyncmd), !attemptedSources.contains(.pyncmd) {
            newlyAttemptedSources.insert(.pyncmd)
            do {
                let resolved = try await pyncmd(track)
                if await isUsable(resolved, track: track) {
                    return Resolution(
                        source: resolved,
                        attemptedSources: newlyAttemptedSources
                    )
                }
            } catch {
                if Task.isCancelled { return Resolution(source: nil, attemptedSources: newlyAttemptedSources) }
                logFailure(source: .pyncmd, operation: "resolve", error: error)
            }
        }

        for provider in fallbackProviders where enabledSources.contains(provider.id)
            && !attemptedSources.contains(provider.id) {
            guard !Task.isCancelled else { break }
            newlyAttemptedSources.insert(provider.id)
            do {
                if let resolved = try await provider.resolve(track: track),
                   await isUsable(resolved, track: track) {
                    return Resolution(source: resolved, attemptedSources: newlyAttemptedSources)
                }
            } catch {
                if Task.isCancelled { break }
                logFailure(source: provider.id, operation: "resolve", error: error)
            }
        }
        return Resolution(source: nil, attemptedSources: newlyAttemptedSources)
    }

    /// Matches a QQ/Kugou track to the same song on NetEase and resolves
    /// it through the NetEase ladder (ikun, pyncmd, Haitangw, Xinghai),
    /// then through the other platform's provider (Kugou for QQ tracks,
    /// QQ for Kugou tracks). Nil when nothing resolves — the failure is
    /// surfaced, never a wrong song.
    ///
    /// The ladder matters: before this change only ikun was tried for
    /// the matched NetEase track, and the generic chain below retried
    /// the same providers with the platform track's own
    /// (negative-hash) id, which can never resolve — so any song ikun
    /// alone refused was unplayable even when another NetEase source
    /// had it. The cross-platform step matters for VIP songs: the four
    /// NetEase sources all refuse Jay Chou's catalog (ikun: url empty;
    /// pyncmd: empty; Haitangw: APP_UPGRADE_REQUIRED; Xinghai: 502 —
    /// live-probed 2026-11-09 for 晴天, NetEase id 186016), while
    /// Kugou's anonymous search returns the studio recording first
    /// (269s, 叶惠美）. A logged-in QQ session stays the sure path for
    /// VIP songs when the other platform cannot resolve them either.
    private static func platformTrackViaFallbacks(_ track: Track) async -> ResolvedAudioSource? {
        guard let match = await matchedNetEaseTrack(for: track) else { return nil }
        // NetEase ladder on the matched track, ikun first.
        if let resolved = try? await ikunProvider.resolve(track: match),
           await isUsable(resolved, track: match) {
            log.info("platform track via ikun: matched NetEase id=\(match.id, privacy: .public) for \"\(track.name, privacy: .public)\"")
            return resolved
        }
        if let resolved = try? await pyncmd(match),
           await isUsable(resolved, track: match) {
            log.info("platform track via pyncmd: matched NetEase id=\(match.id, privacy: .public) for \"\(track.name, privacy: .public)\"")
            return resolved
        }
        for provider in [HaitangwAudioSourceProvider(), XinghaiAudioSourceProvider()] as [any AudioSourceProvider] {
            guard !Task.isCancelled else { break }
            if let resolved = try? await provider.resolve(track: match),
               await isUsable(resolved, track: match) {
                log.info("platform track via \(provider.id.rawValue, privacy: .public): matched NetEase id=\(match.id, privacy: .public) for \"\(track.name, privacy: .public)\"")
                return resolved
            }
        }
        // The other platform's provider: Kugou's anonymous search can
        // match + resolve songs the NetEase ladder refuses. For a
        // Kugou track the QQ provider is the symmetric fallback (its
        // vkey needs a QQ login, like any QQ direct resolve).
        let otherProvider: any AudioSourceProvider =
            track.platformSource == .qqmusic ? KugouAudioSourceProvider() : QQMusicAudioSourceProvider()
        if let resolved = try? await otherProvider.resolve(track: track),
           await isUsable(resolved, track: track) {
            log.info("platform track via \(otherProvider.id.rawValue, privacy: .public): cross-platform match for \"\(track.name, privacy: .public)\"")
            return resolved
        }
        return nil
    }

    /// Matches a platform track to the same song on NetEase
    /// (cross-platform search + match). Nil when nothing matches —
    /// the failure is surfaced, never a wrong song. Factored out of
    /// `platformTrackViaFallbacks` so the custom script step can
    /// reuse the same match.
    private static func matchedNetEaseTrack(for track: Track) async -> Track? {
        let keyword = AudioSourceTrackMatcher.keyword(for: track)
        guard !keyword.isEmpty else { return nil }
        guard let result = try? await MusicAPI.search(keyword, type: .songs, limit: 10),
              let candidates = result.songs,
              let match = candidates.first(where: {
                  AudioSourceTrackMatcher.matchesNetEase(
                      track: track, title: $0.name,
                      artist: $0.artists.map(\.name).joined(separator: "/"),
                      durationMS: $0.durationMS)
              }),
              match.id > 0
        else { return nil }
        return match
    }

    /// Tries one imported script for a track, in identity order:
    /// the track's own platform id first (QQ songmid / Kugou hash),
    /// then the NetEase id — directly for NetEase tracks, or via the
    /// matched NetEase track for platform tracks (whose own id is a
    /// negative stable hash that no source can resolve). First
    /// non-nil URL wins; the `isUsable` clip check is applied by the
    /// caller. Quality is the source's own quality (default `320k`).
    private static func customScriptResolve(_ track: Track, source: CustomAudioSource) async -> URL? {
        let quality = source.quality
        let albumName = track.album.name
        let albumID = String(track.album.id)
        if track.platformSource == .qqmusic, let key = track.platformSongKey, !key.isEmpty {
            // `songmid[|mediaMid]`
            let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let qqMid = parts[0]
            let qqMediaMid = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
            if let url = await LXScriptRunner.shared.resolve(
                source: source, songSource: .qq, songID: qqMid,
                qqMid: qqMid, qqMediaMid: qqMediaMid,
                name: track.name, artists: track.artistNames,
                albumName: albumName, albumID: albumID, quality: quality
            ) { return url }
        }
        if track.platformSource == .kugou, let key = track.platformSongKey, !key.isEmpty {
            // `hash[|albumAudioId|albumId]`
            let hash = key.split(separator: "|").first.map(String.init) ?? key
            if let url = await LXScriptRunner.shared.resolve(
                source: source, songSource: .kugou, songID: hash,
                kugouID: hash,
                name: track.name, artists: track.artistNames,
                albumName: albumName, albumID: albumID, quality: quality
            ) { return url }
        }
        if track.id > 0 {
            return await LXScriptRunner.shared.resolve(
                source: source, songSource: .netease, songID: String(track.id),
                name: track.name, artists: track.artistNames,
                albumName: albumName, albumID: albumID, quality: quality
            )
        }
        if let matched = await matchedNetEaseTrack(for: track) {
            return await LXScriptRunner.shared.resolve(
                source: source, songSource: .netease, songID: String(matched.id),
                name: track.name, artists: track.artistNames,
                albumName: albumName, albumID: albumID, quality: quality
            )
        }
        return nil
    }

    /// True unless the URL is known to point at a clip far shorter than
    /// the track (a VIP prompt or trial snippet). Unknown durations are
    /// accepted: a slow or uncooperative host must not make a playable
    /// track unplayable.
    private static func isUsable(_ resolved: ResolvedAudioSource, track: Track) async -> Bool {
        guard track.durationMS >= 90_000,
              let seconds = await probedDurationSeconds(for: resolved.url),
              seconds > 0
        else { return true }
        let expectedSeconds = Double(track.durationMS) / 1_000.0
        guard seconds < expectedSeconds * 0.5 else { return true }
        log.info(
            "source=\(resolved.id.rawValue, privacy: .public) skipping short clip duration=\(seconds, privacy: .public) expected=\(expectedSeconds, privacy: .public)"
        )
        return false
    }

    /// Loads the remote asset's duration, giving up after 5 seconds so a
    /// slow host delays resolution no longer than it would today.
    private static func probedDurationSeconds(for url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        return await withTaskGroup(of: Double?.self) { group in
            group.addTask {
                guard let duration = try? await asset.load(.duration) else { return nil }
                let seconds = duration.seconds
                return seconds.isFinite ? seconds : nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func pyncmd(_ track: Track) async throws -> ResolvedAudioSource {
        let urlString = "https://music-api.gdstudio.xyz/api.php?types=url&source=\(Upstream.tag)&id=\(track.id)&br=320"
        let data = try await httpClient.data(
            from: urlString,
            source: .pyncmd,
            operation: "resolve"
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AudioSourceProviderError.invalidResponse
        }
        guard let bitrate = object["br"] as? Int, bitrate > 0 else {
            throw AudioSourceProviderError.missingBitrate
        }
        guard let urlValue = object["url"] as? String else {
            throw AudioSourceProviderError.missingStreamURL
        }
        guard let url = URL(string: urlValue.replacingOccurrences(of: "http://", with: "https://")) else {
            throw AudioSourceProviderError.invalidURL
        }
        return ResolvedAudioSource(id: .pyncmd, displayName: AudioSourceID.pyncmd.displayName, url: url)
    }

    private static func logFailure(source: AudioSourceID, operation: String, error: Error) {
        log.error(
            "source=\(source.rawValue, privacy: .public) operation=\(operation, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
    }
}
