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
        // Platform tracks resolve through ikun FIRST: the user asked for
        // 酸甜贤 as the default playback source for songs from all
        // platforms ("搜索全平台歌曲播放音源酸甜贤"). Discovery stays
        // cross-platform; only playback defaults to ikun. The track is
        // matched to the same song on NetEase and resolved through
        // ikun; only when ikun cannot match or resolve it does the flow
        // fall through to the platform's own provider below. Background:
        // QQ's vkey endpoint only issues playback URLs to logged-in
        // sessions — live-probed 2026-11-09, anonymous vkey answers
        // code 0 with an empty purl for every song and tier — so a
        // logged-out QQ account gets no QQ URL at all. Deliberately not
        // gated on the ikun toggle: this is the platform playback rule
        // the user asked for.
        if track.platformSource == .qqmusic || track.platformSource == .kugou,
           let resolved = await platformTrackViaIkun(track) {
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
    /// it through ikun. Nil when there is no confident match or ikun
    /// has no URL — the failure is surfaced, never a wrong song.
    private static func platformTrackViaIkun(_ track: Track) async -> ResolvedAudioSource? {
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
        guard let resolved = try? await ikunProvider.resolve(track: match),
              await isUsable(resolved, track: match)
        else { return nil }
        log.info("platform track via ikun: matched NetEase id=\(match.id, privacy: .public) for \"\(track.name, privacy: .public)\"")
        return resolved
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
