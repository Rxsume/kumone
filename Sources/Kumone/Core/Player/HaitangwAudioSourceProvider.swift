import Foundation

/// Native re-implementation of the Haitangw / Changqing resolve-url
/// endpoint used by several LX Music custom-source scripts (Annie,
/// HelloWorld, Molan, Huibi). Resolves a NetEase song ID directly to a
/// playback URL; no cross-platform search is involved.
///
/// Endpoint (from the scripts): POST {host}/music/resolve-url
///   body: {"source": "wy", "rid": "<netease id>", "level": "exhigh"}
///   response: {"code": 0, "data": {"url": "<playback url>"}}
/// Primary host first, backup host second, mirroring the scripts'
/// dual-host `htsResolveUrl` helper. The `exhigh` level is fixed
/// (320k tier), matching the existing pyncmd provider's fixed `br=320`.
struct HaitangwAudioSourceProvider: AudioSourceProvider {
    let id: AudioSourceID = .haitangw
    let displayName = AudioSourceID.haitangw.displayName

    private let httpClient: AudioSourceClient

    /// Primary host first, backup host second.
    private static let hosts = [
        "https://musicserver.haitangw.cc/v1/music/resolve-url",
        "https://qt.haitangw.net/v1/music/resolve-url",
    ]

    init(httpClient: AudioSourceClient = .shared) {
        self.httpClient = httpClient
    }

    func resolve(track: Track) async throws -> ResolvedAudioSource? {
        var lastError: Error?
        for host in Self.hosts {
            guard let url = URL(string: host) else { continue }
            do {
                let data = try await httpClient.postJSON(
                    to: url,
                    source: id,
                    operation: "resolve",
                    body: ["source": "wy", "rid": String(track.id), "level": "exhigh"]
                )
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let streamURL = Self.streamURL(from: object)
                else { throw AudioSourceProviderError.invalidResponse }

                return ResolvedAudioSource(id: id, displayName: displayName, url: streamURL)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? AudioSourceProviderError.invalidResponse
    }

    /// Haitangw answers `code: 0` with the URL under `data.url`.
    /// The top-level `url` shape is accepted as a fallback.
    private static func streamURL(from object: [String: Any]) -> URL? {
        if let code = object["code"] as? Int, code != 0 { return nil }
        var urlString: String?
        if let data = object["data"] as? [String: Any] {
            urlString = data["url"] as? String
        }
        if urlString == nil {
            urlString = object["url"] as? String ?? object["data"] as? String
        }
        guard let urlString,
              let url = URL(string: urlString),
              let scheme = url.scheme, scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }
}
