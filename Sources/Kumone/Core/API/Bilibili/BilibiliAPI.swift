import CryptoKit
import Foundation

// API mapping adapted from CeruMusic ceru.bilibili 1.0.2 (MIT).
// See Sources/Kumone/Resources/CeruBilibili-LICENSE.txt for attribution.
//
// Ported from Beans 2.0.3 (`Beans/BilibiliAPI.swift`). Phase 1 keeps
// only the transport, QR login and account surface: `setCookie`,
// `raw`/`get`, `encode`/`text`/`image`, `accountInfo`/`account`,
// `loginQR`/`pollQR`/`completeQRLogin`/`crossDomainCookies`.
// Song/search/playback/collection APIs and the SMS login path are
// phase 2 (Bilibili as a music source, then the video feed).
// `BeansDiagnostics` calls are dropped — Golia has no such singleton.
struct BilibiliError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Bilibili API. The actor owns the session cookie, the QR login state
/// and the WBI fingerprint. Playback stays on the music player; this
/// actor never touches `MPNowPlayingSession`.
actor BilibiliAPI {
    static let shared = BilibiliAPI()
    nonisolated static let headers = [
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "Referer": "https://www.bilibili.com/", "Origin": "https://www.bilibili.com"
    ]
    private let session: URLSession
    private var cookie = ""
    private var restoredSession = false
    private var pendingQRLogin: (key: String, values: [String: String], redirect: URL?)?
    private var fingerprint = ""
    private var wbiKey = ""
    private var wbiDate = Date.distantPast
    private var cache: [String: (Date, [String: Any])] = [:]
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config)
    }
    func setCookie(_ value: String) {
        cookie = BilibiliProtocol.normalizeCookie(value)
        restoredSession = true
        pendingQRLogin = nil
        cache.removeAll()
        wbiKey = ""
    }
    func raw(_ url: URL, cookieOverride: String? = nil) async throws -> ([String: Any], HTTPURLResponse) {
        if cookieOverride == nil, !restoredSession {
            let saved = await BilibiliAuth.shared.cookieHeader
            if !restoredSession {
                setCookie(saved)
                restoredSession = true
            }
        }
        var request = URLRequest(url: url)
        Self.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let cookies = [cookieOverride ?? cookie, fingerprint].filter { !$0.isEmpty }.joined(separator: "; ")
        if !cookies.isEmpty { request.setValue(cookies, forHTTPHeaderField: "Cookie") }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BilibiliError(message: "哔哩哔哩请求失败（HTTP \(status ?? 0)）")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BilibiliError(message: "哔哩哔哩返回了无法识别的数据")
        }
        return (object, http)
    }
    func get(_ path: String, _ query: [String: String] = [:], signed: Bool = false, identity: Bool = false, ttl: Double = 0) async throws -> [String: Any] {
        let key = path + query.keys.sorted().map { $0 + "=" + query[$0]! }.joined(separator: "&")
        if ttl > 0, let entry = cache[key], Date().timeIntervalSince(entry.0) < ttl { return entry.1 }
        if identity && fingerprint.isEmpty {
            let fp = try await get("/x/frontend/finger/spi")
            if let b3 = fp["b_3"] as? String, let b4 = fp["b_4"] as? String {
                fingerprint = "buvid3=\(b3); buvid4=\(b4)"
            }
        }
        var values = query
        if signed {
            if wbiKey.isEmpty || Date().timeIntervalSince(wbiDate) > 3600 {
                let nav = try await get("/x/web-interface/nav")
                let img = nav["wbi_img"] as? [String: Any] ?? [:]
                let parts = ["img_url", "sub_url"].map { URL(string: img[$0] as? String ?? "")?.deletingPathExtension().lastPathComponent ?? "" }.joined()
                let chars = Array(parts)
                let mixin = [46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,27,43,5,49,33,9,42,19,29,28,14,39,12,38,41,13,37,48,7,16,24,55,40,61,26,17,0,1,60,51,30,4,22,25,54,21,56,59,6,63,57,62,11,36,20,34,44,52]
                guard chars.count >= 64 else { throw BilibiliError(message: "无法取得 B 站签名参数") }
                wbiKey = String(mixin.prefix(32).map { chars[$0] })
                wbiDate = Date()
            }
            values["wts"] = String(Int(Date().timeIntervalSince1970))
            values = values.mapValues { $0.filter { !"!'()*".contains($0) } }
            let encoded = values.keys.sorted().map { Self.encode($0) + "=" + Self.encode(values[$0]!) }.joined(separator: "&")
            values["w_rid"] = Insecure.MD5.hash(data: Data((encoded + wbiKey).utf8)).map { String(format: "%02x", $0) }.joined()
        }
        var components = URLComponents(string: "https://api.bilibili.com" + path)!
        components.percentEncodedQuery = values.keys.sorted().map { Self.encode($0) + "=" + Self.encode(values[$0]!) }.joined(separator: "&")
        let (root, _) = try await raw(components.url!)
        let code = (root["code"] as? NSNumber)?.intValue ?? -1
        let data = root["data"] as? [String: Any] ?? root["result"] as? [String: Any] ?? [:]
        guard code == 0 || (path == "/x/web-interface/nav" && code == -101 && data["wbi_img"] != nil) else {
            let message: String
            switch code {
            case -101: message = "请先登录哔哩哔哩账号"
            case -352, -412: message = "哔哩哔哩暂时限制了请求，请稍后重试"
            case -403, -10403: message = "当前账号无权访问该内容"
            case -404: message = "视频或收藏夹已删除或不可访问"
            default: message = root["message"] as? String ?? "平台请求失败"
            }
            throw BilibiliError(message: "\(message)（\(code)）")
        }
        if ttl > 0 {
            if cache.count >= 160, let oldest = cache.min(by: { $0.value.0 < $1.value.0 })?.key { cache.removeValue(forKey: oldest) }
            cache[key] = (Date(), data)
        }
        return data
    }
    nonisolated private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")) ?? ""
    }
    nonisolated static func text(_ value: Any?) -> String {
        let string = value as? String ?? (value as? NSNumber)?.stringValue ?? ""
        return string.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&nbsp;", with: " ")
    }
    nonisolated static func image(_ value: Any?) -> URL? {
        let s = text(value)
        guard !s.isEmpty else { return nil }
        let normalized = s.hasPrefix("//") ? "https:" + s : s.replacingOccurrences(of: "http://", with: "https://")
        return URL(string: normalized)
    }
    func account(cookie value: String) async throws -> String {
        try await accountInfo(cookie: value).nickname
    }
    func accountInfo(cookie value: String) async throws -> (nickname: String, mid: String, avatar: URL?) {
        let (root,_) = try await raw(URL(string:"https://api.bilibili.com/x/web-interface/nav")!,cookieOverride:value)
        guard let data = root["data"] as? [String:Any], data["isLogin"] as? Bool == true else { throw BilibiliError(message:"B站登录凭据已过期或无效") }
        return (Self.text(data["uname"]), Self.text(data["mid"]), Self.image(data["face"]))
    }
    func loginQR() async throws -> (url: String, key: String) {
        let (root,_) = try await raw(URL(string:"https://passport.bilibili.com/x/passport-login/web/qrcode/generate")!)
        guard let data=root["data"] as? [String:Any],let url=data["url"] as? String, let key=data["qrcode_key"] as? String,
              let parsed=URL(string:url),parsed.scheme == "https",let host=parsed.host,host == "bilibili.com" || host.hasSuffix(".bilibili.com") else { throw BilibiliError(message:"无法生成 B站登录二维码") }
        pendingQRLogin = nil
        return (url,key)
    }
    func pollQR(_ key: String) async throws -> (code: Int, cookie: String) {
        if pendingQRLogin?.key == key { return try await completeQRLogin(key) }
        var components = URLComponents(string: "https://passport.bilibili.com/x/passport-login/web/qrcode/poll")!
        components.queryItems = [URLQueryItem(name: "qrcode_key", value: key)]
        let (root, response) = try await raw(components.url!)
        guard (root["code"] as? NSNumber)?.intValue == 0,
              let data = root["data"] as? [String: Any], let code = (data["code"] as? NSNumber)?.intValue else {
            throw BilibiliError(message: "B站扫码状态异常，请刷新二维码")
        }
        guard code == 0 else { return (code, "") }
        let redirect = (data["url"] as? String).flatMap(BilibiliProtocol.loginURL)
        pendingQRLogin = (key, BilibiliProtocol.responseCookies(response), redirect)
        return try await completeQRLogin(key)
    }

    private func completeQRLogin(_ key: String) async throws -> (code: Int, cookie: String) {
        guard let pending = pendingQRLogin, pending.key == key else { throw CancellationError() }
        var values = pending.values
        if let redirect = pending.redirect {
            values.merge(BilibiliProtocol.queryCookies(from: redirect)) { current, _ in current }
            if values["SESSDATA"] == nil {
                values.merge(try await crossDomainCookies(from: redirect)) { current, _ in current }
            }
        }
        guard pendingQRLogin?.key == key else { throw CancellationError() }
        pendingQRLogin = (key, values, pending.redirect)
        return (0, BilibiliProtocol.cookieHeader(values))
    }

    private func crossDomainCookies(from url: URL) async throws -> [String: String] {
        guard url.path.lowercased().contains("crossdomain") else { return [:] }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        let exchange = URLSession(configuration: config, delegate: BilibiliLoginRedirectDelegate(), delegateQueue: nil)
        defer { exchange.invalidateAndCancel() }
        var next: URL? = url
        var values: [String: String] = [:]
        for _ in 0..<5 {
            try Task.checkCancellation()
            guard let current = next, BilibiliProtocol.loginURL(current.absoluteString) != nil else { break }
            var request = URLRequest(url: current)
            Self.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            let (_, response) = try await exchange.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
                throw BilibiliError(message: "扫码已确认，但登录凭据交换失败，请刷新二维码重试")
            }
            values.merge(BilibiliProtocol.responseCookies(http)) { _, latest in latest }
            if values["SESSDATA"] != nil { return values }
            guard let location = http.value(forHTTPHeaderField: "Location"),
                  let redirect = URL(string: location, relativeTo: current)?.absoluteURL,
                  BilibiliProtocol.loginURL(redirect.absoluteString) != nil else { break }
            values.merge(BilibiliProtocol.queryCookies(from: redirect)) { _, latest in latest }
            next = redirect
        }
        return values
    }
}
