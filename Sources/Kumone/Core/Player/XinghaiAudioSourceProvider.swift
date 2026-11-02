import Foundation

/// Native re-implementation of the Xinghai aggregate backend used by
/// several LX Music custom-source scripts (Kuliao, Molan, Huibi,
/// HelloWorld). Resolves a NetEase song ID directly to a playback URL;
/// no cross-platform search is involved.
///
/// Endpoint (from the scripts):
///   GET {host}/lx/api/?source=netease&songmid=<netease id>&quality=320k
///       &name=<title>&singer=<artist>&albumName=<album>
///   response: {"code": 200, "url": "<playback url>"}
/// Primary host first, backup host second. The variant that also sends
/// an `X-Token`/`X-Client` header pair is deliberately not used here:
/// the no-token variant is what the Kuliao/Molan scripts call. The
/// 320k quality is fixed, matching the existing pyncmd provider's
/// fixed `br=320`.
struct XinghaiAudioSourceProvider: AudioSourceProvider {
    let id: AudioSourceID = .xinghai
    let displayName = AudioSourceID.xinghai.displayName

    private let httpClient: AudioSourceClient

    /// Primary host first, backup host second.
    private static let hosts = [
        "https://yy.zddyr.top/lx/api/",
        "https://zrcdy.dpdns.org/lx/api/",
    ]

    init(httpClient: AudioSourceClient = .shared) {
        self.httpClient = httpClient
    }

    func resolve(track: Track) async throws -> ResolvedAudioSource? {
        var lastError: Error?
        for host in Self.hosts {
            guard let url = Self.requestURL(host: host, track: track) else { continue }
            do {
                let data = try await httpClient.data(
                    from: url,
                    source: id,
                    operation: "resolve"
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

    private static func requestURL(host: String, track: Track) -> URL? {
        var components = URLComponents(string: host)
        components?.queryItems = [
            URLQueryItem(name: "source", value: "netease"),
            URLQueryItem(name: "songmid", value: String(track.id)),
            URLQueryItem(name: "quality", value: "320k"),
            URLQueryItem(name: "name", value: track.name),
            URLQueryItem(name: "singer", value: track.artists.first?.name ?? ""),
            URLQueryItem(name: "albumName", value: track.album.name),
        ]
        return components?.url
    }

    /// Xinghai answers `code: 200` with the URL at the top level.
    /// The nested `data.url` shape is accepted as a fallback.
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
