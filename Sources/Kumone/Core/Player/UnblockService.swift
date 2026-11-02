import AVFoundation
import Foundation
import os.log

/// Resolves gray tracks, trying sources in this order: ikun first (the
/// preferred source), then the direct pyncmd source, then the remaining
/// script-backend providers (Haitangw / Xinghai), which resolve by
/// NetEase ID directly, with no search step.
///
/// Kugou and Kuwo were removed: Kuwo's unauthenticated convert_url
/// endpoint answers VIP tracks with a ~11s spoken prompt clip ("use the
/// latest Kuwo app") instead of the song, and the clip is playable, so
/// it used to be returned as if it were the track. Every resolved URL
/// is therefore checked here: if the audio it points at is far shorter
/// than the track, it is treated as a prompt/trial clip and the next
/// source is tried. A probe that errors or times out never rejects a
/// URL — it only rejects a clip whose duration is actually known.
enum UnblockService {
    private static let log = Logger(subsystem: "im.missuo.kumone", category: "audio-source")
    private static let httpClient = AudioSourceClient.shared
    private static let ikunProvider = IkunAudioSourceProvider()
    private static let fallbackProviders: [any AudioSourceProvider] = [
        HaitangwAudioSourceProvider(),
        XinghaiAudioSourceProvider(),
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
                logFailure(source: .pyncmd, operation: "resolve", error: error)
            }
        }

        for provider in fallbackProviders where enabledSources.contains(provider.id)
            && !attemptedSources.contains(provider.id) {
            newlyAttemptedSources.insert(provider.id)
            do {
                if let resolved = try await provider.resolve(track: track),
                   await isUsable(resolved, track: track) {
                    return Resolution(source: resolved, attemptedSources: newlyAttemptedSources)
                }
            } catch {
                logFailure(source: provider.id, operation: "resolve", error: error)
            }
        }
        return Resolution(source: nil, attemptedSources: newlyAttemptedSources)
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
        let urlString = "https://music-api.gdstudio.xyz/api.php?types=url&source=netease&id=\(track.id)&br=320"
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
