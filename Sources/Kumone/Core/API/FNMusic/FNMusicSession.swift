import CryptoKit
import Foundation
import os.log
import Security

// 飞牛音乐 (fnOS) 会话持有者：表单登录 + Cookie 会话 + 数据层。
//
// 协议来源：Folia v0.7.27 `src/services/onlineMusic/fnmusic/`
// （`fnmusicProvider.ts` / `fnmusicTransport.ts`；主进程桥
// `electron/fnmusic/fnmusicApiBridge.cjs` 不在稀疏克隆内，桥内细节
// ——如 track/stream 的响应体形状——以本文件注释标注的为准，不编造）。
//
//  - 登录：POST {base}/music/api/v1/user/password-login，
//    body { username, password: sha256(password), deviceId }，
//    成功响应信封 { code, msg, data }，data = { userToken, user }。
//    code ∈ {0, 200} 为成功；120001 = 账号或密码错误。
//  - 认证：之后所有请求带 `Cookie: music-token=<userToken>`。
//    HTTP 401/403 或业务码 401/403 = token 失效，需重新登录。
//  - 不走 MusicClient：它只认网易 MUSIC_U，且 host/加密全是网易专用的。
//
// 存放：服务器地址与账号名（非敏感）放 UserDefaults；userToken 与
// deviceId 放 Keychain（见 FNMusicKeychain）。密码只在登录调用内
// 出现一次（算完 SHA-256 即丢弃），不落盘。不要把 token/密码放进
// UserDefaults，也不要放进 cookies.json（那是网易 MusicClient 的
// 明文文件）。

enum FNMusicError: LocalizedError {
    case invalidBaseURL
    case notConfigured
    case notAuthenticated
    case badCredentials
    case authExpired
    case httpStatus(Int)
    case network(URLError)
    case invalidResponse(String?)
    case keychainFailure

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "Invalid FNMusic server URL"
        case .notConfigured: return "FNMusic server is not configured"
        case .notAuthenticated: return "FNMusic is not logged in"
        case .badCredentials: return "Wrong FNMusic username or password (code 120001)"
        case .authExpired: return "FNMusic login has expired, please log in again"
        case .httpStatus(let status): return "FNMusic HTTP status \(status)"
        case .network(let error): return "FNMusic network error \(error.code.rawValue)"
        case .invalidResponse(let message): return message ?? "Invalid FNMusic response"
        case .keychainFailure: return "FNMusic could not access the Keychain"
        }
    }
}

/// 飞牛音乐账号（登录响应 `data.user` 的归一化结果；字段名取自 Folia
/// `normalizeFnMusicUser`：guid/id/uid/account/username，
/// name/nickname/account）。
struct FNMusicUser: Codable, Hashable, Sendable {
    let id: String
    let nickname: String
    let username: String
}

/// 飞牛音乐曲目（搜索结果的归一化结果；字段名取自 Folia
/// `normalizeFnMusicSong`：guid/id/mediaId，title/trackName/name，
/// artists[{guid,name}] 或字符串数组，duration/durationMs（毫秒），
/// album{guid,name,coverId}，coverId）。
struct FNMusicTrack: Codable, Hashable, Sendable {
    let id: String
    let title: String
    let artists: [String]
    let durationMS: Int
    let albumName: String
    let coverId: String
}

/// 飞牛音乐歌单（字段名取自 Folia `collectionOf('playlist')`：
/// guid/id，name/title，coverId，description/summary，
/// trackCount/track_total/songCount/trackTotal）。
struct FNMusicPlaylist: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let coverId: String
    let trackCount: Int?
    let description: String
}

/// 喜欢的歌曲：`GET /music/api/v1/favorite-track/list` 只给出曲目 id
///（trackGUID/guid/id），Folia 也是只读 id（`getLikedSongIds`）。
/// `complete == false` 表示中途失败或超过页数上限，未读到的歌不能
/// 当作“已取消喜欢”处理。
struct FNMusicLikedTracks: Sendable {
    let ids: [String]
    let complete: Bool
}

/// 飞牛音乐会话：持有 base/token/deviceId，对外提供登录、登出、
/// 带 Cookie 的请求与数据层（搜索 / 歌单 / 喜欢列表）。
///
/// 线程安全：与 MusicClient 同款做法——`@unchecked Sendable` +
/// 敏感值不放内存可变状态：token/deviceId 每次读写都走 Keychain，
/// base/username 读 UserDefaults；登录成功后先落盘再更新内存快照。
final class FNMusicSession: @unchecked Sendable {
    static let shared = FNMusicSession()

    // MARK: - 存储键

    /// 服务器地址（用户填写，局域网 IP / DDNS / Tailscale 域名均可）。
    /// 非敏感，放 UserDefaults。默认 ""（未配置）。
    static let baseURLDefaultsKey = "settings.fnmusicServerURL"
    /// 账号名。非敏感，放 UserDefaults。默认 ""。
    static let usernameDefaultsKey = "settings.fnmusicUsername"
    /// 登录后缓存的用户 id / 昵称（仅供界面展示，非敏感）。
    static let userIDDefaultsKey = "settings.fnmusicUserID"
    static let nicknameDefaultsKey = "settings.fnmusicNickname"

    private static let log = Logger(subsystem: "sb.moe.kumone", category: "fnmusic")

    private let session: URLSession
    private let defaults: UserDefaults
    private let lock = NSLock()
    /// 登录后内存里的账号快照（与 UserDefaults 里的 userID/nickname 同步写）。
    private var _currentUser: FNMusicUser?

    init(session: URLSession? = nil, defaults: UserDefaults = .standard) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 15
            self.session = URLSession(configuration: configuration)
        }
        self.defaults = defaults
    }

    // MARK: - 登录态

    /// 用户填的服务器地址（已规范化：去首尾空白/斜杠、无 scheme 时补 http://）。
    var serverBase: String? {
        guard let raw = defaults.string(forKey: Self.baseURLDefaultsKey),
              !raw.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return Self.normalizeBase(raw)
    }

    var username: String? {
        defaults.string(forKey: Self.usernameDefaultsKey)
    }

    var currentUser: FNMusicUser? {
        lock.withLock { _currentUser } ?? restoredUser()
    }

    /// 有 base 且 Keychain 里有 token 才算登录（不发网络请求校验）。
    var isAuthenticated: Bool {
        serverBase != nil && FNMusicKeychain.loadToken() != nil
    }

    /// 401/403 就是 token 失效（Folia：HTTP 401/403 或业务码 401/403）。
    static func isAuthFailure(statusCode: Int?, businessCode: Int?) -> Bool {
        statusCode == 401 || statusCode == 403 || businessCode == 401 || businessCode == 403
    }

    // MARK: - 登录 / 退出

    /// 表单登录：POST {base}/music/api/v1/user/password-login，
    /// body { username, password: sha256(password), deviceId }。
    /// 成功后 base/username/user 存 UserDefaults，token 存 Keychain。
    /// 密码只在本次调用内使用，不落盘。
    @discardableResult
    func login(base: String, username: String, password: String) async throws -> FNMusicUser {
        guard let normalizedBase = Self.normalizeBase(base),
              let baseURL = URL(string: normalizedBase),
              let scheme = baseURL.scheme, scheme == "http" || scheme == "https",
              baseURL.host != nil
        else { throw FNMusicError.invalidBaseURL }

        let deviceId = try FNMusicKeychain.loadOrCreateDeviceID()
        let passwordHash = SHA256.hash(data: Data(password.utf8))
            .map { String(format: "%02x", $0) }.joined()
        guard let url = URL(string: normalizedBase + "/music/api/v1/user/password-login") else {
            throw FNMusicError.invalidBaseURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": username,
            "password": passwordHash,
            "deviceId": deviceId,
        ])

        let data = try await executeUnauthenticated(request, operation: "user/password-login")
        let payload = try Self.payload(of: data, operation: "user/password-login")
        guard let object = payload as? [String: Any] else {
            throw FNMusicError.invalidResponse("Login response has no data object")
        }
        // 成功响应 { userToken, user }；userToken 缺失即登录未成功。
        guard let token = object["userToken"] as? String, !token.isEmpty else {
            throw FNMusicError.invalidResponse("Login response has no userToken")
        }
        let user = FNMusicUser(
            id: Self.stringField(object["user"], keys: ["guid", "id", "uid", "account", "username"])
                ?? username,
            nickname: Self.stringField(object["user"], keys: ["name", "nickname", "account", "username"])
                ?? username,
            username: username
        )
        // 先落盘再更新内存态（仿 MusicClient.replaceAuthentication 的顺序）。
        FNMusicKeychain.saveToken(token)
        defaults.set(normalizedBase, forKey: Self.baseURLDefaultsKey)
        defaults.set(username, forKey: Self.usernameDefaultsKey)
        defaults.set(user.id, forKey: Self.userIDDefaultsKey)
        defaults.set(user.nickname, forKey: Self.nicknameDefaultsKey)
        lock.withLock { _currentUser = user }
        return user
    }

    /// 退出登录：只清本地态（token + 账号快照），保留 base 与 username
    /// 供下次登录表单回填。Folia 稀疏克隆内看不到服务端登出接口路径
    /// （桥操作名只有 `logout`，无路径），故不编造登出请求、不调接口。
    func logout() {
        FNMusicKeychain.deleteToken()
        defaults.removeObject(forKey: Self.userIDDefaultsKey)
        defaults.removeObject(forKey: Self.nicknameDefaultsKey)
        lock.withLock { _currentUser = nil }
    }

    // MARK: - 播放地址

    /// 流地址：{base}/music/api/v1/track/stream?trackGUID=<guid>。
    /// 只拼 URL，不发请求（Folia 里 track/stream 的响应体形状与
    /// hls:// → /api/stream/unified 转 m3u8 的转换都在主进程桥内，
    /// 稀疏克隆内无法核实；见 INTEGRATION-fnmusic.md 第 3 节）。
    /// 注意：该 URL 本身不带任何凭据，AVPlayer 播它时不会带 Cookie，
    /// 播放接线另见集成说明。
    func streamURL(trackGUID: String) -> URL? {
        guard let base = serverBase,
              var components = URLComponents(string: base + "/music/api/v1/track/stream")
        else { return nil }
        components.queryItems = [URLQueryItem(name: "trackGUID", value: trackGUID)]
        return components.url
    }

    // MARK: - 数据层（只做数据，不写 UI）

    /// 搜索歌曲：GET /music/api/v1/search/track?q=&page=&size=
    /// → { total, list }（page 从 1 起；list 缺失按空列表处理）。
    func searchTracks(keyword: String, page: Int = 1, size: Int = 10) async throws -> (tracks: [FNMusicTrack], total: Int) {
        let payload = try await perform(
            path: "/music/api/v1/search/track",
            query: ["q": keyword, "page": String(max(1, page)), "size": String(size)],
            operation: "search/track"
        )
        let (list, total) = Self.pageList(of: payload)
        return (list.compactMap(Self.parseTrack), total)
    }

    /// 我的歌单：GET /music/api/v1/playlist/list?page=&size= → { total, list }。
    func userPlaylists(page: Int = 1, size: Int = 50) async throws -> (playlists: [FNMusicPlaylist], total: Int) {
        let payload = try await perform(
            path: "/music/api/v1/playlist/list",
            query: ["page": String(max(1, page)), "size": String(size)],
            operation: "playlist/list"
        )
        let (list, total) = Self.pageList(of: payload)
        return (list.compactMap(Self.parsePlaylist), total)
    }

    /// 我喜欢的歌曲 id 全量：GET /music/api/v1/favorite-track/list?page=&size=
    /// 分页循环（Folia：每页 100，最多 20 页；页不满或累计数达到 total 即
    /// 读完）。只读到尾才 complete == true，中途失败必须报 false。
    func likedTracks(pageSize: Int = 100, maxPages: Int = 20) async throws -> FNMusicLikedTracks {
        var ids: [String] = []
        var complete = false
        do {
            for page in 1...max(1, maxPages) {
                let payload = try await perform(
                    path: "/music/api/v1/favorite-track/list",
                    query: ["page": String(page), "size": String(pageSize)],
                    operation: "favorite-track/list"
                )
                let (list, total) = Self.pageList(of: payload)
                ids += list.compactMap { item in
                    Self.stringField(item, keys: ["trackGUID", "guid", "id"])
                }.filter { !$0.isEmpty }
                if list.count < pageSize { complete = true; break }
                if total > 0 && ids.count >= total { complete = true; break }
            }
        } catch {
            Self.log.error("operation=favorite-track/list error=\(error.localizedDescription, privacy: .public)")
            // 中途失败：已读到的 id 照常返回，但 complete 必须为 false。
            return FNMusicLikedTracks(ids: ids, complete: false)
        }
        return FNMusicLikedTracks(ids: ids, complete: complete)
    }

    // MARK: - 带 Cookie 的请求

    /// 发一次带 `Cookie: music-token=<token>` 的认证请求，返回信封里
    /// `data` 字段的内容（信封 { code, msg, data }；code ∈ {0, 200}
    /// 为成功；120001 = 账号或密码错误；401/403 = token 失效）。
    /// 顶层直接是数组时（个别列表接口）按 data 本身返回。
    func perform(
        path: String,
        method: String = "GET",
        query: [String: String] = [:],
        jsonBody: [String: Any]? = nil,
        operation: String
    ) async throws -> Any? {
        guard let base = serverBase else { throw FNMusicError.notConfigured }
        guard let token = FNMusicKeychain.loadToken() else { throw FNMusicError.notAuthenticated }
        var components = URLComponents(string: base + path)
        if !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else { throw FNMusicError.invalidBaseURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.httpMethod = method
        request.setValue("music-token=\(token)", forHTTPHeaderField: "Cookie")
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        let data = try await execute(request, token: token, operation: operation)
        return try Self.payload(of: data, operation: operation)
    }

    // MARK: - 内部

    /// 服务器地址规范化：去空白与末尾斜杠，无 scheme 时补 http://。
    /// （Folia 主进程也会规范化地址；不成形的地址报 invalid-base。）
    static func normalizeBase(_ raw: String) -> String? {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        if !base.contains("://") { base = "http://" + base }
        guard let url = URL(string: base),
              let scheme = url.scheme, scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return base
    }

    private func restoredUser() -> FNMusicUser? {
        guard let id = defaults.string(forKey: Self.userIDDefaultsKey),
              let nickname = defaults.string(forKey: Self.nicknameDefaultsKey)
        else { return nil }
        let user = FNMusicUser(id: id, nickname: nickname, username: username ?? nickname)
        lock.withLock { _currentUser = user }
        return user
    }

    /// token 失效时清掉本地 token（仿 Folia signInRanOut：只删本次
    /// 校验时用的 token；登录态随即变未登录，界面提示重新登录）。
    private func invalidateToken() {
        FNMusicKeychain.deleteToken()
        defaults.removeObject(forKey: Self.userIDDefaultsKey)
        defaults.removeObject(forKey: Self.nicknameDefaultsKey)
        lock.withLock { _currentUser = nil }
    }

    private func execute(_ request: URLRequest, token: String, operation: String) async throws -> Data {
        let startedAt = Date()
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw FNMusicError.invalidResponse("Non-HTTP response for \(operation)")
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                if Self.isAuthFailure(statusCode: httpResponse.statusCode, businessCode: nil) {
                    invalidateToken()
                    throw FNMusicError.authExpired
                }
                Self.log.error("operation=\(operation, privacy: .public) status=\(httpResponse.statusCode, privacy: .public) elapsed-ms=\(Int(Date().timeIntervalSince(startedAt) * 1_000), privacy: .public)")
                throw FNMusicError.httpStatus(httpResponse.statusCode)
            }
            return data
        } catch let error as FNMusicError {
            throw error
        } catch let error as URLError {
            throw FNMusicError.network(error)
        }
    }

    /// 登录请求（无 Cookie）：401/403 与业务码都按信封处理；网络层
    /// 失败直接抛，不清任何已存 token（登录失败不应踢掉旧登录）。
    private func executeUnauthenticated(_ request: URLRequest, operation: String) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw FNMusicError.invalidResponse("Non-HTTP response for \(operation)")
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                if Self.isAuthFailure(statusCode: httpResponse.statusCode, businessCode: nil) {
                    throw FNMusicError.authExpired
                }
                throw FNMusicError.httpStatus(httpResponse.statusCode)
            }
            return data
        } catch let error as FNMusicError {
            throw error
        } catch let error as URLError {
            throw FNMusicError.network(error)
        }
    }

    /// 解信封 { code, msg, data }：code ∈ {0, 200} 成功；
    /// 120001 → badCredentials；401/403 → authExpired；其余 → invalidResponse。
    /// 顶层是数组时直接当 data 返回（Folia pageList 的兼容分支）。
    private static func payload(of data: Data, operation: String) throws -> Any? {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw FNMusicError.invalidResponse("Unparseable response for \(operation)")
        }
        if let array = json as? [Any] { return array }
        guard let object = json as? [String: Any] else {
            throw FNMusicError.invalidResponse("Unexpected response shape for \(operation)")
        }
        guard let code = intField(object["code"]) else {
            // 无 code 字段：当作裸 data 对象返回（不猜它是哪个接口的信封）。
            return object
        }
        let message = object["msg"] as? String
        switch code {
        case 0, 200:
            return object["data"]
        case 120001:
            throw FNMusicError.badCredentials
        case 401, 403:
            throw FNMusicError.authExpired
        default:
            throw FNMusicError.invalidResponse(message ?? "FNMusic error code \(code) for \(operation)")
        }
    }

    /// 列表接口信封：{ total, list }，或直接是数组；list 缺失按空列表，
    /// total 缺失按 list 长度（Folia pageList 的兼容规则）。
    private static func pageList(of payload: Any?) -> (list: [[String: Any]], total: Int) {
        if let array = payload as? [Any] {
            let list = array.compactMap { $0 as? [String: Any] }
            return (list, list.count)
        }
        guard let object = payload as? [String: Any] else { return ([], 0) }
        let list = (object["list"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let total = intField(object["total"]) ?? list.count
        return (list, total)
    }

    private static func parseTrack(_ item: [String: Any]) -> FNMusicTrack? {
        guard let id = stringField(item, keys: ["guid", "id", "mediaId"]), !id.isEmpty else { return nil }
        let artists = artistsOf(item["artists"])
        let album = item["album"] as? [String: Any] ?? [:]
        return FNMusicTrack(
            id: id,
            title: stringField(item, keys: ["title", "trackName", "name"]) ?? "",
            artists: artists,
            durationMS: intField(item["duration"] ?? item["durationMs"]) ?? 0,
            albumName: stringField(album, keys: ["name"]) ?? (stringField(item, keys: ["albumName"]) ?? ""),
            coverId: stringField(item, keys: ["coverId"]) ?? (stringField(album, keys: ["coverId"]) ?? "")
        )
    }

    private static func parsePlaylist(_ item: [String: Any]) -> FNMusicPlaylist? {
        guard let id = stringField(item, keys: ["guid", "id"]), !id.isEmpty else { return nil }
        return FNMusicPlaylist(
            id: id,
            name: stringField(item, keys: ["name", "title"]) ?? "",
            coverId: stringField(item, keys: ["coverId"]) ?? "",
            trackCount: intField(item["trackCount"] ?? item["track_total"] ?? item["songCount"] ?? item["trackTotal"]),
            description: stringField(item, keys: ["description", "summary"]) ?? ""
        )
    }

    /// artists 可能是 [{guid,name}]，也可能是字符串数组（Folia artistsOf 的兼容规则）。
    private static func artistsOf(_ value: Any?) -> [String] {
        guard let array = value as? [Any] else { return [] }
        var seen = Set<String>()
        var names: [String] = []
        for entry in array {
            let name: String
            if let string = entry as? String {
                name = string
            } else if let dict = entry as? [String: Any] {
                name = stringField(dict, keys: ["name", "artistName"]) ?? ""
            } else {
                continue
            }
            guard !name.isEmpty, !seen.contains(name) else { continue }
            seen.insert(name)
            names.append(name)
        }
        return names
    }

    /// 多候选字段名取第一个非空字符串（值可能是字符串或数字）。
    private static func stringField(_ value: Any?, keys: [String]) -> String? {
        guard let dict = value as? [String: Any] else {
            if let string = value as? String, !string.isEmpty { return string }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }
        for key in keys {
            guard let raw = dict[key] else { continue }
            if let string = raw as? String, !string.isEmpty { return string }
            if let number = raw as? NSNumber { return number.stringValue }
        }
        return nil
    }

    /// 数值字段：Int / Double / 数字字符串都接受（Folia countOf 的兼容规则）。
    private static func intField(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double, double.isFinite { return Int(double) }
        if let string = value as? String, let int = Int(string) { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}

// MARK: - Keychain（token + deviceId）

/// 飞牛音乐专用的最小 Keychain 助手。
///
/// 项目里没有可直接复用的通用 Keychain 助手：`LoginKeyStore.keychain`
/// 是同步登录专用的（service 写死 `sb.moe.kumone.sync-login-key`、
/// account 是 key 的 UUID），`SyncDeviceIdentity` 是同步设备标识专用的
///（service `sb.moe.kumone.sync-device`）。两者都不宜借给飞牛用，
/// 故本文件内另起一个飞牛专用的 service；不改共享文件。
/// deviceId：32 位 hex（16 随机字节），生成一次后复用——Folia 明确要求
/// 复用已存值，避免每次登录都在 NAS 设备列表里新增一台。
enum FNMusicKeychain {
    private static let service = "sb.moe.kumone.fnmusic"
    private static let tokenAccount = "music-token"
    private static let deviceIDAccount = "device-id"

    static func loadToken() -> String? {
        load(account: tokenAccount)
    }

    static func saveToken(_ token: String) {
        save(token, account: tokenAccount)
    }

    static func deleteToken() {
        delete(account: tokenAccount)
    }

    /// 读不到就生成一个 32 位 hex 写回；Keychain 不可用时抛错
    /// （不退回内存随机值，否则每次登录都会在 NAS 上注册新设备）。
    static func loadOrCreateDeviceID() throws -> String {
        if let existing = load(account: deviceIDAccount), existing.count == 32 {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw FNMusicError.keychainFailure
        }
        let deviceId = bytes.map { String(format: "%02x", $0) }.joined()
        save(deviceId, account: deviceIDAccount)
        return deviceId
    }

    private static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func save(_ value: String, account: String) {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(value.utf8),
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: false,
            ]
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary)
        }
    }

    private static func delete(account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ] as CFDictionary)
    }
}
