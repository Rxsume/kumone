import Foundation

/// Native re-implementation of the ikun resolve-url endpoint used by
/// several LX Music custom-source scripts (Annie, Molan, Kuliao, Huibi,
/// HelloWorld). Resolves a NetEase song ID directly to a playback URL;
/// no cross-platform search is involved.
///
/// Endpoint (from the scripts): POST https://c.wwwweb.top/music/url
///   body: {"source": "wy", "musicId": <netease id>, "quality": "320k"}
///   response: {"code": 200, "url": "<playback url>"}
/// The 320k quality is fixed, matching the existing pyncmd provider's
/// fixed `br=320`: fallback resolution does not follow the app's
/// audio-quality setting, it just needs a playable URL.
struct IkunAudioSourceProvider: AudioSourceProvider {
    let id: AudioSourceID = .ikun
    let displayName = AudioSourceID.ikun.displayName

    private let httpClient: AudioSourceClient

    init(httpClient: AudioSourceClient = .shared) {
        self.httpClient = httpClient
    }

    func resolve(track: Track) async throws -> ResolvedAudioSource? {
        guard let url = URL(string: "https://c.wwwweb.top/music/url") else {
            throw AudioSourceError.invalidURL
        }
        let data = try await httpClient.postJSON(
            to: url,
            source: id,
            operation: "resolve",
            body: ["source": "wy", "musicId": track.id, "quality": "320k"]
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streamURL = Self.streamURL(from: object)
        else { throw AudioSourceProviderError.invalidResponse }

        return ResolvedAudioSource(id: id, displayName: displayName, url: streamURL)
    }

    /// Accepts the top-level `url` field the scripts read, and the nested
    /// `data.url` shape some deployments return. A present non-200 `code`
    /// is a failure, not a URL.
    private static func streamURL(from object: [String: Any]) -> URL? {
        if let code = object["code"] as? Int, code != 200 { return nil }
        var urlString = object["url"] as? String
        if urlString == nil, let data = object["data"] as? [String: Any] {
            urlString = data["url"] as? String
        }
        if urlString == nil {
            urlString = object["data"] as? String
        }
        guard let urlString,
              let url = URL(string: urlString),
              let scheme = url.scheme, scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }
}
