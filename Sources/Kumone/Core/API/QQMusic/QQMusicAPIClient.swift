import Foundation
import os.log

/// Errors from the QQ Music backend (`qq-music-api`, self-hosted) and from
/// the anonymous `u.y.qq.com` musicu endpoint. No error case carries a
/// credential or a session token.
enum QQMusicError: LocalizedError, Equatable {
    /// No backend base URL is configured (settings key is empty).
    case notConfigured
    case invalidResponse
    case invalidURL
    case httpStatus(Int)
    /// A request carrying a session was refused with HTTP 401.
    case unauthorized
    /// The backend has no route for this operation (HTTP 404, or the
    /// serverless 501 "not implemented" body). Callers treat this as
    /// "capability not declared", not as a failure.
    case routeNotFound(String)
    case rateLimited(retryAfterMS: Int?)
    /// The QQ account has hit its signed-in device limit (upstream code
    /// 20279). The user must clear devices in the QQ Music app
    /// (Settings -> Device Management).
    case deviceLimit
    /// A QR check failed for a backend-reported reason (the message is
    /// the backend's own `code 800: <message> (stage …, reason …)` line).
    case loginFailed(String)
    /// The backend answered normally but issued no stream for this
    /// account at any quality tier (and no preview, if one was asked).
    case notPlayable
    case transport(URLError.Code)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "QQ Music backend is not configured"
        case .invalidResponse:
            return "Invalid QQ Music response"
        case .invalidURL:
            return "Invalid QQ Music URL"
        case .httpStatus(let status):
            return "QQ Music HTTP status \(status)"
        case .unauthorized:
            return "QQ Music login required"
        case .routeNotFound(let operation):
            return "QQ Music backend has no \(operation) route"
        case .rateLimited:
            return "QQ Music rate limited"
        case .deviceLimit:
            return "QQ Music device limit reached (20279)"
        case .loginFailed(let message):
            return message
        case .notPlayable:
            return "QQMusicApi gave no play link for this song"
        case .transport(let code):
            return "QQ Music network error \(code.rawValue)"
        }
    }
}

/// Thin transport for QQ Music: one small client that carries the opaque
/// `qqmusic_session=<token>` string, separate from `AudioSourceClient`
/// (which never carries login state) and from `MusicClient` (which only
/// understands NetEase `MUSIC_U` cookies).
///
/// Two transports live here, mirroring Folia's `qqTransport.ts`:
/// - Backend requests go to the user-configured self-hosted `qq-music-api`
///   base URL, with the session sent as `?cookie=<session>` (iOS has no
///   same-origin deployment, so the header form Folia uses for same-origin
///   bases does not apply; the query form is the only cross-origin form).
///   Every backend request also carries `timestamp=<ms>`.
/// - Anonymous search goes straight to `u.y.qq.com` musicu, with no
///   session and no backend involved.
struct QQMusicAPIClient {
    static let shared = QQMusicAPIClient()

    private static let log = Logger(subsystem: "sb.moe.kumone", category: "qq-music")
    private static let musicuURLString = "https://u.y.qq.com/cgi-bin/musicu.fcg"

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 70
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Backend requests

    /// Sends one `qq-music-api` request and returns the decoded JSON body
    /// as a dictionary. `operation` is the path (for example
    /// `/login/qr/key`); `params` become query items; a non-nil `payload`
    /// makes it a POST with a JSON body.
    ///
    /// - Parameters:
    ///   - baseURL: the configured backend base URL, trailing slash removed.
    ///   - sessionString: the stored `qqmusic_session=<token>` string, or
    ///     nil for an anonymous call.
    ///   - timeout: per-request timeout. Folia allows up to 70 s for
    ///     playback (`music_play`) because the backend itself chains up to
    ///     four QQ calls; login calls use the shorter default.
    func backend(
        _ operation: String,
        baseURL: URL,
        params: [String: String] = [:],
        payload: [String: Any]? = nil,
        sessionString: String? = nil,
        timeout: TimeInterval = 30
    ) async throws -> [String: Any] {
        var components = URLComponents(url: baseURL.appendingPathComponent(operation), resolvingAgainstBaseURL: false)
        var queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        if let sessionString, !sessionString.isEmpty {
            queryItems.append(URLQueryItem(name: "cookie", value: sessionString))
        }
        queryItems.append(URLQueryItem(name: "timestamp", value: String(Int(Date().timeIntervalSince1970 * 1_000))))
        components?.queryItems = queryItems
        guard let url = components?.url else { throw QQMusicError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        if let payload {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }

        let data = try await execute(request, operation: operation)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QQMusicError.invalidResponse
        }
        return object
    }

    // MARK: - Anonymous musicu search

    /// Searches QQ Music anonymously through `u.y.qq.com` musicu, the same
    /// call Folia's `searchQQSongs` (qqLyricProvider.ts) makes: method
    /// `DoSearchForQQMusicLite` on `music.search.SearchCgiService`, with
    /// `search_type: 7` (songs; `0` is refused upstream with code 2001).
    /// No session is sent and no backend is involved.
    func searchMusicu(keyword: String, page: Int = 1, pageSize: Int = 20) async throws -> [QQMusicTrack] {
        guard let url = URL(string: Self.musicuURLString) else { throw QQMusicError.invalidURL }
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let query = String(trimmed.prefix(60))

        // search_id mirrors Folia: a random 14-digit-ish number plus the
        // millisecond time of day.
        let millisOfDay = Int(Date().timeIntervalSince1970 * 1_000) % 86_400_000
        let searchID = String(UInt64.random(in: 0..<100_000_000_000_000) + UInt64(millisOfDay))

        let param: [String: Any] = [
            "search_id": searchID,
            "remoteplace": "search.android.keyboard",
            "query": query,
            "search_type": 7,
            "num_per_page": pageSize,
            "page_num": page,
            "highlight": 0,
            "nqc_flag": 0,
            "page_id": 1,
            "grp": 1,
        ]
        // comm mirrors Folia's lyric-provider musicu call (ct 11,
        // tmeAppID "qqmusiclight").
        let comm: [String: Any] = [
            "ct": 11,
            "cv": "1003006",
            "v": "1003006",
            "os_ver": "15",
            "phonetype": "24122RKC7C",
            "rom": "Redmi/miro/miro:15/AE3A.240806.005/OS2.0.102.0.VOMCNXM:user/release-keys",
            "tmeAppID": "qqmusiclight",
            "nettype": "NETWORK_WIFI",
            "udid": "0",
            "uid": "0",
        ]
        let body: [String: Any] = [
            "comm": comm,
            "request": [
                "method": "DoSearchForQQMusicLite",
                "module": "music.search.SearchCgiService",
                "param": param,
            ] as [String: Any],
        ]

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("tmeLoginType=-1;", forHTTPHeaderField: "Cookie")
        request.setValue("okhttp/3.14.9", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await execute(request, operation: "musicu-search")
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["code"] as? Int) == 0,
              let requestNode = object["request"] as? [String: Any],
              (requestNode["code"] as? Int) == 0,
              let requestData = requestNode["data"] as? [String: Any],
              let bodyNode = requestData["body"] as? [String: Any],
              let items = bodyNode["item_song"] as? [[String: Any]]
        else { throw QQMusicError.invalidResponse }

        return items.compactMap { QQMusicTrack(musicuItem: $0) }
    }

    // MARK: - Execution

    private func execute(_ request: URLRequest, operation: String) async throws -> Data {
        let startedAt = Date()
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                logFailure(operation: operation, url: request.url, detail: "non-http", startedAt: startedAt)
                throw QQMusicError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                let detail = "status=\(httpResponse.statusCode)"
                logFailure(operation: operation, url: request.url, detail: detail, startedAt: startedAt)
                throw Self.error(for: httpResponse, data: data, operation: operation)
            }
            return data
        } catch let error as QQMusicError {
            throw error
        } catch let error as URLError {
            logFailure(operation: operation, url: request.url, detail: "url-error=\(error.code.rawValue)", startedAt: startedAt)
            throw QQMusicError.transport(error.code)
        } catch {
            logFailure(operation: operation, url: request.url, detail: "unexpected", startedAt: startedAt)
            throw error
        }
    }

    /// Maps an HTTP failure to the matching error. 404 means the backend
    /// has no such route (old backend: "capability not declared"); the
    /// serverless 501 with the fixed "is not implemented by the serverless
    /// runtime." message means the same thing.
    private static func error(for response: HTTPURLResponse, data: Data, operation: String) -> QQMusicError {
        switch response.statusCode {
        case 401:
            return .unauthorized
        case 404:
            return .routeNotFound(operation)
        case 429:
            return .rateLimited(retryAfterMS: retryAfterMS(from: response, data: data))
        case 501:
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = object["message"] as? String,
               message.contains("is not implemented by the serverless runtime.") {
                return .routeNotFound(operation)
            }
            return .httpStatus(501)
        default:
            return .httpStatus(response.statusCode)
        }
    }

    /// The backend reports backoff in the 429 body (`retryAfterMs`) and in
    /// the `Retry-After` header (seconds); either may be absent.
    private static func retryAfterMS(from response: HTTPURLResponse, data: Data) -> Int? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ms = object["retryAfterMs"] as? Int, ms >= 0 {
            return ms
        }
        if let raw = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
           let seconds = Int(raw), seconds >= 0 {
            return seconds * 1_000
        }
        return nil
    }

    private func logFailure(operation: String, url: URL?, detail: String, startedAt: Date) {
        let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1_000)
        Self.log.error(
            "operation=\(operation, privacy: .public) host=\(url?.host ?? "", privacy: .public) detail=\(detail, privacy: .public) elapsed-ms=\(elapsedMS, privacy: .public)"
        )
    }
}
