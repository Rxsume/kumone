import Combine
import Foundation
import os.log
import Security

/// QQ Music login state, adapted from Beans' `QQMusicAuth`
/// (reverse-engineered from `wp_MusicApi util/login_qq_scan.js`).
///
/// Two login paths, with webview cookie import as the primary one:
/// 1. **Webview / manual cookie import** (`importCookies`): the wiring
///    worker reads the QQ cookies out of a `WKWebView` (or pasted text)
///    and hands the dict over. No backend involved.
/// 2. **QR scan** (`fetchQRCode` / `poll`): `ptqrshow` -> `ptqrlogin`
///    polling -> `check_sig` chain -> `graph.qq.com` OAuth authorize
///    -> `musicu.fcg QQConnectLogin` exchanging the code for a
///    `musickey`. Exposed in `LoginSheet` next to web login and
///    Cookie import; still not the primary path (Beans itself never
///    wired it into its login sheet).
///
/// Storage differs from Beans on purpose: Beans kept the cookie dict in
/// `UserDefaults`. Here credentials live
/// ONLY in the Keychain (service `sb.moe.kumone.qqmusic`, generic
/// password, not synchronizable, accessible after first unlock);
/// `nickname` / `vipBadge` are display strings and may stay in
/// `UserDefaults`. Nothing credential-like is ever written to
/// `UserDefaults`, and no credential is ever logged.
///
/// The class is `@MainActor`: `@Published` state is only ever mutated
/// on the main actor, and API-layer callers reach it with
/// `await QQMusicAuth.shared.<member>`.
@MainActor
final class QQMusicAuth: ObservableObject {
    static let shared = QQMusicAuth()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var nickname = ""
    /// QQ Music membership badge: nil none / "VIP" / "SVIP" (best effort
    /// after login; a failed fetch never blocks login or playback).
    @Published private(set) var vipBadge: String?

    private static let log = Logger(subsystem: "sb.moe.kumone", category: "qq-music")

    private static let keychainService = "sb.moe.kumone.qqmusic"
    private static let keychainAccount = "cookies"
    private static let nicknameDefaultsKey = "sb.moe.kumone.qqmusic.nickname"
    private static let vipDefaultsKey = "sb.moe.kumone.qqmusic.vip"

    /// The User-Agent Beans sends for QQ CDN playback (see
    /// `playbackHeaders`); the login/QR flow uses `ua` below instead.
    private static let playbackUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:80.0) Gecko/20100101 Firefox/80.0"
    private static let ua =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    private var cookies: [String: String] = [:]
    private var qrsig = ""

    private let defaults = UserDefaults.standard
    private let session: URLSession
    private let redirectBlocker = QQMusicNoRedirectDelegate()

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: config, delegate: redirectBlocker, delegateQueue: nil)
        if let saved = Self.keychainLoadCookies(), !saved.isEmpty {
            cookies = saved
            isLoggedIn = true
            nickname = defaults.string(forKey: Self.nicknameDefaultsKey) ?? ""
            vipBadge = defaults.string(forKey: Self.vipDefaultsKey)
        }
    }

    // MARK: - Login state

    /// Login account ID. QQ login normally uses `uin`; WeChat login
    /// normally uses `wxuin`.
    var uin: String {
        Self.normalizedUIN(Self.accountID(from: cookies))
    }

    /// Raw account ID (keeps the `o` prefix; playlist add/remove
    /// endpoints need it). Falls back to `wxuin` for WeChat web login,
    /// which has no `uin`.
    var rawUin: String {
        Self.accountID(from: cookies)
    }

    var isWeChatLogin: Bool {
        Self.hasUsableAccountID(cookies["wxuin"]) || !(cookies["wxopenid"] ?? "").isEmpty
    }

    /// QQ playlist endpoints' QQ account ID. WeChat login usually has no
    /// usable QQ `uin`; returns 0 then and lets the official endpoints
    /// identify the account from the `wxuin` / `wxopenid` cookies.
    var playlistUin: String {
        if isWeChatLogin,
           !Self.hasUsableAccountID(cookies["p_uin"]),
           !Self.hasUsableAccountID(cookies["pt2gguin"]) {
            return Self.normalizedUIN(cookies["wxuin"] ?? "0")
        }
        for key in ["uin", "p_uin", "pt2gguin"] {
            guard let value = cookies[key],
                  Self.hasUsableAccountID(value) else { continue }
            return Self.normalizedUIN(value)
        }
        return "0"
    }

    /// Account-ID candidates for the playlist endpoints. With WeChat
    /// login `wxuin` must be tried too: some accounts' playlist/liked
    /// endpoints return nothing on `uin=0` + cookies alone.
    var playlistIdentityCandidates: [String] {
        let rawValues = [
            cookies["p_uin"],
            cookies["pt2gguin"],
            cookies["uin"],
            cookies["wxuin"],
            playlistUin,
            "0",
        ]
        return rawValues.compactMap { value -> String? in
            guard let value, Self.hasUsableAccountID(value) || value == "0" else { return nil }
            return Self.normalizedUIN(value)
        }.reduce(into: [String]()) { result, value in
            if !result.contains(value) { result.append(value) }
        }
    }

    /// `g_tk` (signature for write endpoints; QQ/WeChat login both
    /// prefer the music-domain credential).
    var gtk: Int {
        let key = cookies["qqmusic_key"]
            ?? cookies["qm_keyst"]
            ?? cookies["wxskey"]
            ?? cookies["p_skey"]
            ?? cookies["skey"]
            ?? ""
        return key.isEmpty ? 5381 : Self.hash5381(key)
    }

    /// Playback `authst`. The vkey flow prefers the music-domain
    /// credential; `p_skey` is only the legacy fallback.
    var loginKey: String {
        cookies["qm_keyst"] ?? cookies["qqmusic_key"] ?? cookies["music_key"]
            ?? cookies["wxskey"] ?? cookies["musickey"] ?? cookies["p_skey"] ?? ""
    }

    /// Cookie string sent to `u.y.qq.com` (with `qqmusic_key`, VIP
    /// playback success is highest).
    var cookieHeader: String {
        makeCookieHeader(includeCompatibilityUIN: true)
    }

    /// Same as `cookieHeader` without the compatibility `uin=wxuin`
    /// injection, for the playlist endpoints: some QQ endpoints read
    /// `uin` first and return empty playlists when handed a `wxuin`
    /// as if it were a QQ `uin`.
    var playlistCookieHeader: String {
        makeCookieHeader(includeCompatibilityUIN: false)
    }

    private func makeCookieHeader(includeCompatibilityUIN: Bool) -> String {
        let order = [
            "uin", "wxuin", "p_uin", "wxopenid",
            "qm_keyst", "qqmusic_key", "music_key", "wxskey", "wx_skey",
            "musickey", "p_skey", "skey", "pt4_token",
        ]
        var pairs: [String] = order.compactMap { key in
            guard let value = cookies[key], !value.isEmpty else { return nil }
            return "\(key)=\(value)"
        }
        // Old saved WeChat state may only have `wxuin`; some QQ
        // endpoints still only read `uin`.
        if includeCompatibilityUIN,
           !Self.hasUsableAccountID(cookies["uin"]),
           let wxuin = cookies["wxuin"],
           !wxuin.isEmpty {
            pairs.insert("uin=\(wxuin)", at: 0)
        }
        return pairs.joined(separator: "; ")
    }

    /// Headers for `AVPlayer` on QQ CDN URLs: Cookie + Referer
    /// `https://y.qq.com/` + the User-Agent Beans uses for QQ CDN
    /// playback. Without Referer/Cookie, QQ CDN streams commonly stall
    /// then fail with AVFoundation -11849 on older systems.
    var playbackHeaders: [String: String] {
        var headers: [String: String] = [
            "User-Agent": Self.playbackUserAgent,
            "Referer": "https://y.qq.com/",
        ]
        let cookie = cookieHeader
        if !cookie.isEmpty {
            headers["Cookie"] = cookie
        }
        return headers
    }

    func logout() {
        cookies = [:]
        qrsig = ""
        Self.keychainDeleteCookies()
        defaults.removeObject(forKey: Self.nicknameDefaultsKey)
        defaults.removeObject(forKey: Self.vipDefaultsKey)
        isLoggedIn = false
        nickname = ""
        vipBadge = nil
    }

    /// Called by the API layer when it sees the login is dead (HTTP 401
    /// on an authenticated call, or a vkey response with no `midurlinfo`
    /// at all while logged in). Clears the Keychain and drops the
    /// logged-in state; the UI then shows the logged-out state. It is
    /// deliberately NOT called for a plain empty `purl`: a non-VIP
    /// account legitimately gets no playable URL for VIP tracks.
    func sessionExpired() {
        cookies = [:]
        qrsig = ""
        Self.keychainDeleteCookies()
        defaults.removeObject(forKey: Self.nicknameDefaultsKey)
        defaults.removeObject(forKey: Self.vipDefaultsKey)
        isLoggedIn = false
        nickname = ""
        vipBadge = nil
    }

    // MARK: - Web login / cookie import

    /// Web login (`WKWebView` read) or pasted-cookie import. This is the
    /// primary login path; the QR path below is secondary.
    func importCookies(_ dict: [String: String], nickname: String?) {
        guard !dict.isEmpty else { return }
        cookies = dict
        let resolvedNickname = nickname ?? Self.fallbackNickname(dict)
        isLoggedIn = true
        self.nickname = resolvedNickname
        Self.keychainSaveCookies(cookies)
        defaults.set(resolvedNickname, forKey: Self.nicknameDefaultsKey)
        NotificationCenter.default.post(name: .qqMusicLoginDidUpdate, object: nil)
        // Refresh the membership badge and real nickname after login
        // (failures degrade silently).
        Task { await self.fetchVIPStatus() }
        Task { await self.fetchProfile() }
    }

    /// What a web-login cookie dict is missing, so the UI can tell a QQ
    /// login failure from a WeChat one. Nil means the dict looks like a
    /// usable login.
    static func loginValidationMessage(_ dict: [String: String]) -> String? {
        guard hasUsableAccountID(accountID(from: dict)) else {
            return "未读取到 QQ/微信账号标识，请确认网页登录已经完成"
        }

        let credentialKeys = [
            "p_skey", "skey", "qqmusic_key", "qm_keyst",
            "music_key", "wxskey", "wx_skey", "musickey",
        ]
        guard credentialKeys.contains(where: { !(dict[$0] ?? "").isEmpty }) else {
            return "已读取到账号，但缺少 QQ 音乐登录凭证，请在网页中重新登录后再同步"
        }
        return nil
    }

    /// Whether the cookie dict holds a usable login, accepting QQ
    /// login's `uin` and WeChat login's `wxuin` alike.
    static func hasValidLogin(_ dict: [String: String]) -> Bool {
        Self.loginValidationMessage(dict) == nil
    }

    /// Cookie names the web login cares about (filter when reading from
    /// `WKWebView`).
    static let webCookieNames: Set<String> = [
        "uin", "wxuin", "p_uin", "wxopenid", "skey", "p_skey",
        "qqmusic_key", "qm_keyst", "music_key", "wxskey", "wx_skey",
        "musickey", "pt4_token", "pt2gguin", "pt_login_sig", "pt4_aid",
        "qmusic_s", "pgv_pvid", "pgv_info", "ptnick", "nick", "nickname",
    ]

    /// Parses a full Cookie string copied from a browser: `"a=b; c=d"`.
    static func parseCookieHeader(_ header: String) -> [String: String] {
        var dict: [String: String] = [:]
        for part in header.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = kv[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !value.isEmpty {
                dict[key] = value
            }
        }
        return dict
    }

    /// Display nickname from a QQ/WeChat account ID; prefers the
    /// `ptnick_*` / `nick` cookie ptlogin issued.
    static func fallbackNickname(_ dict: [String: String]) -> String {
        if let key = dict.keys.first(where: { $0.hasPrefix("ptnick") }),
           let raw = dict[key], !raw.isEmpty {
            return raw.removingPercentEncoding ?? raw
        }
        if let nick = dict["nick"], !nick.isEmpty { return nick }
        let clean = normalizedUIN(accountID(from: dict))
        return clean.isEmpty ? "QQ音乐用户" : "QQ音乐用户 \(clean)"
    }

    private static func accountID(from cookies: [String: String]) -> String {
        for key in ["uin", "wxuin", "pt2gguin"] {
            guard let value = cookies[key],
                  hasUsableAccountID(value) else { continue }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "0"
    }

    private static func hasUsableAccountID(_ raw: String?) -> Bool {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return false }
        return value != "0" && value != "o0"
    }

    private static func normalizedUIN(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        return value.hasPrefix("o") ? String(value.dropFirst()) : value
    }

    // MARK: - QR login

    enum ScanState: Equatable {
        case waiting
        case scanned
        case success(String)   // nickname
        case expired
        case error(String)
    }

    /// One `ptqrlogin` poll's next step, derived purely from the
    /// parsed response code. Kept separate from `poll()` so the
    /// mapping is unit-testable without the network:
    /// - `"0"` + check_sig URL -> `.authorize` (caller runs
    ///   `completeOAuth`); `"0"` without a URL is a login failure.
    /// - `"65"` / `"68"` -> `.expired` (code expired / invalid).
    /// - `"67"` -> `.scanned` (scanned, awaiting phone confirmation).
    /// - `"66"` and anything else -> `.waiting` (Beans parity: an
    ///   unknown code keeps polling until the server expires the
    ///   code, instead of failing the login outright).
    enum PollOutcome: Equatable {
        case waiting
        case scanned
        case expired
        case authorize(url: String, nickname: String)
        case error(String)
    }

    nonisolated static func pollOutcome(
        for parsed: (code: String, url: String?, nickname: String)
    ) -> PollOutcome {
        switch parsed.code {
        case "0":
            guard let url = parsed.url else {
                return .error("登录成功但凭证获取失败")
            }
            return .authorize(url: url, nickname: parsed.nickname)
        case "65", "68":
            return .expired
        case "67":
            return .scanned
        case "66":
            return .waiting
        default:
            return .waiting
        }
    }

    /// Fetches the QR code image (PNG) and saves `qrsig` for polling.
    /// Secondary path; webview cookie import is primary.
    func fetchQRCode() async throws -> Data {
        qrsig = ""
        var comps = URLComponents(string: "https://ssl.ptlogin2.qq.com/ptqrshow")!
        comps.queryItems = [
            URLQueryItem(name: "appid", value: "716027609"),
            URLQueryItem(name: "e", value: "2"),
            URLQueryItem(name: "l", value: "M"),
            URLQueryItem(name: "s", value: "3"),
            URLQueryItem(name: "d", value: "72"),
            URLQueryItem(name: "v", value: "4"),
            URLQueryItem(name: "t", value: String(format: "%.6f", Double.random(in: 0...1))),
            URLQueryItem(name: "daid", value: "383"),
            URLQueryItem(name: "pt_3rd_aid", value: "100497308"),
        ]
        var request = URLRequest(url: comps.url!)
        request.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        request.setValue("https://xui.ptlogin2.qq.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw QQMusicError.loginFailed("获取 QQ 二维码失败，请检查网络后重试")
        }
        // Without this, an error page (HTML) would be handed to the UI
        // as a QR image and show as a broken white square.
        guard data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
            throw QQMusicError.loginFailed("获取 QQ 二维码失败，请检查网络后重试")
        }
        collectCookies(from: response)
        guard let qr = cookies["qrsig"], !qr.isEmpty else {
            throw QQMusicError.loginFailed("获取 QQ 二维码失败，请检查网络后重试")
        }
        qrsig = qr
        return data
    }

    /// One poll of the scan state (the caller repeats it, ~3 s apart).
    func poll() async throws -> ScanState {
        guard !qrsig.isEmpty else { return .expired }
        var comps = URLComponents(string: "https://ssl.ptlogin2.qq.com/ptqrlogin")!
        comps.queryItems = [
            URLQueryItem(name: "u1", value: "https://graph.qq.com/oauth2.0/login_jump"),
            URLQueryItem(name: "ptqrtoken", value: "\(Self.hash33(qrsig))"),
            URLQueryItem(name: "ptredirect", value: "0"),
            URLQueryItem(name: "h", value: "1"),
            URLQueryItem(name: "t", value: "1"),
            URLQueryItem(name: "g", value: "1"),
            URLQueryItem(name: "from_ui", value: "1"),
            URLQueryItem(name: "ptlang", value: "2052"),
            URLQueryItem(name: "action", value: "0-0-\(Int(Date().timeIntervalSince1970 * 1000))"),
            URLQueryItem(name: "js_ver", value: "22080914"),
            URLQueryItem(name: "js_type", value: "1"),
            URLQueryItem(name: "login_sig", value: ""),
            URLQueryItem(name: "pt_uistyle", value: "40"),
            URLQueryItem(name: "aid", value: "716027609"),
            URLQueryItem(name: "daid", value: "383"),
            URLQueryItem(name: "pt_3rd_aid", value: "100497308"),
            URLQueryItem(name: "o1vId", value: "49283d5cbb01a744d46314da4608d929"),
        ]
        var request = URLRequest(url: comps.url!)
        request.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        request.setValue("https://xui.ptlogin2.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue("qrsig=\(qrsig)", forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        collectCookies(from: response)
        guard let text = String(data: data, encoding: .utf8),
              let parsed = Self.parsePTUI(text) else {
            return .error("QQ 登录接口异常，请重试")
        }
        switch Self.pollOutcome(for: parsed) {
        case .authorize(let url, let scannedNickname):
            do {
                try await completeOAuth(redirectURL: url)
            } catch {
                return .error(error.localizedDescription)
            }
            let resolvedNickname = scannedNickname
            nickname = resolvedNickname
            isLoggedIn = true
            Self.keychainSaveCookies(cookies)
            defaults.set(resolvedNickname, forKey: Self.nicknameDefaultsKey)
            Task { await self.fetchVIPStatus() }
            Task { await self.fetchProfile() }
            return .success(resolvedNickname)
        case .expired:
            return .expired
        case .scanned:
            return .scanned
        case .waiting:
            return .waiting
        case .error(let message):
            return .error(message)
        }
    }

    // MARK: - OAuth -> musickey

    private func completeOAuth(redirectURL: String) async throws {
        // The check_sig redirect chain must carry qrsig (ptlogin2.qq.com
        // domain), or the check fails and no skey/p_skey comes back.
        var loginCookie = cookieHeader
        if !qrsig.isEmpty {
            loginCookie = "qrsig=\(qrsig)" + (loginCookie.isEmpty ? "" : "; " + loginCookie)
        }
        // 1. Walk the check_sig redirect chain, collecting skey / p_skey
        // (max 6 hops).
        var current = redirectURL
        for _ in 0..<6 {
            guard let url = URL(string: current) else { break }
            var request = URLRequest(url: url)
            request.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
            request.setValue("https://xui.ptlogin2.qq.com/", forHTTPHeaderField: "Referer")
            request.setValue(loginCookie, forHTTPHeaderField: "Cookie")
            let (_, response) = try await session.data(for: request)
            collectCookies(from: response)
            loginCookie = cookieHeader
            if !qrsig.isEmpty {
                loginCookie = "qrsig=\(qrsig)" + (loginCookie.isEmpty ? "" : "; " + loginCookie)
            }
            guard let http = response as? HTTPURLResponse,
                  (300...399).contains(http.statusCode),
                  let location = http.value(forHTTPHeaderField: "Location"),
                  !location.isEmpty else { break }
            if let locURL = URL(string: location), locURL.scheme != nil {
                current = location
            } else if let base = URL(string: current),
                      let resolved = URL(string: location, relativeTo: base) {
                current = resolved.absoluteString
            } else {
                break
            }
        }

        // 2. graph.qq.com oauth2 authorize, exchanging the session for a code.
        loginCookie = cookieHeader
        let gtk = Self.hash5381(cookies["qqmusic_key"] ?? cookies["p_skey"] ?? cookies["skey"] ?? "")
        let fields: [String: String] = [
            "response_type": "code",
            "client_id": "100497308",
            "redirect_uri": "https://y.qq.com/portal/wx_redirect.html?login_type=1&surl=https://y.qq.com/",
            "scope": "all",
            "state": "state",
            "switch": "",
            "from_ptlogin": "1",
            "src": "1",
            "update_auth": "1",
            "openapi": "80901010_1030",
            "g_tk": "\(gtk)",
            "auth_time": "\(Int(Date().timeIntervalSince1970 * 1000))",
            "ui": "DFEC5395-9E69-4D3E-96A6-300BB770874D",
        ]
        var authRequest = URLRequest(url: URL(string: "https://graph.qq.com/oauth2.0/authorize")!)
        authRequest.httpMethod = "POST"
        authRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        authRequest.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        authRequest.setValue("https://graph.qq.com/", forHTTPHeaderField: "Referer")
        authRequest.setValue(loginCookie, forHTTPHeaderField: "Cookie")
        authRequest.httpBody = Self.formEncode(fields).data(using: .utf8)
        let (_, authResponse) = try await session.data(for: authRequest)
        collectCookies(from: authResponse)
        guard let http = authResponse as? HTTPURLResponse,
              let location = http.value(forHTTPHeaderField: "Location"),
              let code = Self.extractCode(from: location) else {
            throw QQMusicError.loginFailed("QQ 授权失败，请重新扫码")
        }

        // 3. musicu.fcg QQConnectLogin exchanges the code for a musickey
        // (persisted as login cookies).
        loginCookie = cookieHeader
        let body = "{\"comm\":{\"g_tk\":5381,\"platform\":\"yqq\",\"ct\":24,\"cv\":0},\"req\":{\"module\":\"QQConnectLogin.LoginServer\",\"method\":\"QQLogin\",\"param\":{\"code\":\"\(code)\"}}}"
        var loginRequest = URLRequest(url: URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg")!)
        loginRequest.httpMethod = "POST"
        loginRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        loginRequest.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        loginRequest.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        loginRequest.setValue(loginCookie, forHTTPHeaderField: "Cookie")
        loginRequest.httpBody = body.data(using: .utf8)
        let (loginData, loginResponse) = try await session.data(for: loginRequest)
        collectCookies(from: loginResponse)
        // Some QQ login responses put the music-domain credential in the
        // JSON body instead of Set-Cookie; persist it explicitly.
        if let json = try? JSONSerialization.jsonObject(with: loginData) as? [String: Any],
           let req = json["req"] as? [String: Any],
           let data = req["data"] as? [String: Any] {
            if let musicKey = data["musickey"] as? String, !musicKey.isEmpty {
                cookies["musickey"] = musicKey
                cookies["qm_keyst"] = musicKey
                cookies["qqmusic_key"] = musicKey
            }
            if let musicID = data["musicid"] as? Int, musicID > 0 {
                cookies["uin"] = "\(musicID)"
            } else if let musicID = data["musicid"] as? String, !musicID.isEmpty {
                cookies["uin"] = musicID
            }
        }
    }

    // MARK: - Membership status

    /// Fetches the QQ Music membership badge (`music.member.getVipInfo`).
    /// Best effort: a failure or missing fields leaves the badge nil and
    /// never blocks login or playback.
    func fetchVIPStatus() async {
        guard isLoggedIn, !uin.isEmpty, uin != "0" else {
            if vipBadge != nil {
                vipBadge = nil
                defaults.removeObject(forKey: Self.vipDefaultsKey)
            }
            return
        }
        do {
            let payload: [String: Any] = [
                "comm": ["ct": 24, "cv": 0, "uin": uin],
                "req_0": [
                    "module": "music.member.getVipInfo",
                    "method": "get_vip_info",
                    "param": ["uin": uin],
                ],
            ]
            let json = try await musicu(payload)
            let badge = Self.parseVIPBadge(json)
            if badge != vipBadge {
                vipBadge = badge
                if let badge {
                    defaults.set(badge, forKey: Self.vipDefaultsKey)
                } else {
                    defaults.removeObject(forKey: Self.vipDefaultsKey)
                }
            }
        } catch {
            // Best effort: endpoint flakiness must not affect login/playback.
        }
    }

    /// Recursively scans a response for membership fields (response
    /// shapes vary): an `svip` field > 0 / true -> SVIP; a `vipType` /
    /// `vip_type` > 0 -> VIP.
    private static func parseVIPBadge(_ json: [String: Any]) -> String? {
        var vipLevel = 0
        var svipFlag = false
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                for (key, v) in dict {
                    let lower = key.lowercased()
                    if lower.contains("svip") {
                        if let n = v as? Int, n > 0 { svipFlag = true }
                        if let b = v as? Bool, b { svipFlag = true }
                    } else if lower == "viptype" || lower == "vip_type" {
                        if let n = v as? Int, n > 0 { vipLevel = max(vipLevel, n) }
                    }
                    walk(v)
                }
            } else if let arr = value as? [Any] {
                arr.forEach(walk)
            }
        }
        walk(json)
        if svipFlag || vipLevel >= 11 { return "SVIP" }
        if vipLevel > 0 { return "VIP" }
        return nil
    }

    /// Fetches the real QQ Music nickname (`fcg_get_profile_homepage`;
    /// called after scan/web/cookie login; failures silently keep the
    /// previous nickname).
    func fetchProfile() async {
        guard isLoggedIn, !uin.isEmpty, uin != "0" else { return }
        do {
            let urlString = "https://c.y.qq.com/rsc/fcgi-bin/fcg_get_profile_homepage.fcg?cid=205360838&userid=\(uin)&reqfrom=1&g_tk=5381&loginUin=\(uin)&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8&notice=0&platform=yqq.json&needNewCode=0"
            guard let url = URL(string: urlString) else { return }
            var request = URLRequest(url: url)
            request.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
            request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let code = obj["code"] as? Int ?? -1
            // code 1000 = profile endpoint unavailable; not "logged out",
            // fall through to the cookie fallback below.
            guard code == 0 || code == 1000 else { return }
            if let nick = Self.extractNickname(obj), !nick.isEmpty, nick != nickname {
                nickname = nick
                defaults.set(nick, forKey: Self.nicknameDefaultsKey)
                return
            }
            // Fall back to the ptlogin-issued ptnick_* cookie.
            if let key = cookies.keys.first(where: { $0.hasPrefix("ptnick") }),
               let raw = cookies[key], !raw.isEmpty {
                let nick = raw.removingPercentEncoding ?? raw
                if nick != nickname {
                    nickname = nick
                    defaults.set(nick, forKey: Self.nicknameDefaultsKey)
                }
            }
        } catch {
            // Best effort: endpoint flakiness must not affect login.
        }
    }

    /// Extracts a nickname from a profile-homepage response
    /// (`data.mymusic.info.nick` first, then a recursive `nick` /
    /// `nickname` search).
    private static func extractNickname(_ json: [String: Any]) -> String? {
        if let data = json["data"] as? [String: Any],
           let mymusic = data["mymusic"] as? [String: Any],
           let info = mymusic["info"] as? [String: Any],
           let nick = info["nick"] as? String, !nick.isEmpty {
            return nick
        }
        var found: String?
        func walk(_ value: Any) {
            if found != nil { return }
            if let dict = value as? [String: Any] {
                if let nick = dict["nick"] as? String, !nick.isEmpty, !nick.contains("QQ音乐用户") { found = nick; return }
                if let nick = dict["nickname"] as? String, !nick.isEmpty, !nick.contains("QQ音乐用户") { found = nick; return }
                for (_, v) in dict { walk(v) }
            } else if let arr = value as? [Any] {
                for v in arr { walk(v) }
            }
        }
        walk(json)
        return found
    }

    /// `musicu.fcg` POST carrying the current login cookies.
    private func musicu(_ payload: [String: Any]) async throws -> [String: Any] {
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let url = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") else {
            throw QQMusicError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QQMusicError.invalidResponse
        }
        return obj
    }

    // MARK: - Keychain (cookies only)

    /// Keychain shape mirrors `LoginKeyStore.keychain`:
    /// generic password, not synchronizable, accessible
    /// after first unlock on this device only.
    private static func keychainLoadCookies() -> [String: String]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              !dict.isEmpty
        else { return nil }
        return dict
    }

    private static func keychainSaveCookies(_ cookies: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: cookies) else { return }
        keychainDeleteCookies()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    private static func keychainDeleteCookies() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrSynchronizable as String: false,
        ] as CFDictionary)
    }

    // MARK: - Helpers

    private func collectCookies(from response: URLResponse) {
        guard let http = response as? HTTPURLResponse,
              let url = http.url,
              let headers = http.allHeaderFields as? [String: String] else { return }
        let setCookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        for cookie in setCookies where !cookie.name.isEmpty {
            cookies[cookie.name] = cookie.value
        }
    }

    /// Parses a `ptuiCB('66','','0','','')` JSONP callback. Compatible
    /// with both historical shapes: `code,url,'0',msg,nick` and
    /// `code,'0',url,msg,nick`. Internal (not private) so the QR scan
    /// tests can feed it fixture callbacks; pure, hence `nonisolated`.
    nonisolated static func parsePTUI(_ text: String) -> (code: String, url: String?, nickname: String)? {
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")") else { return nil }
        let inner = text[text.index(after: open)..<close]
        let parts = inner.split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
        }
        guard parts.count >= 5 else { return nil }
        let url: String
        if parts[1].hasPrefix("http") {
            url = parts[1]
        } else {
            url = parts.count > 2 ? parts[2] : ""
        }
        return (parts[0], url.isEmpty ? nil : url, parts[4])
    }

    private static func extractCode(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value else { return nil }
        return code
    }

    private static func formEncode(_ fields: [String: String]) -> String {
        fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    /// JS: `e += (e << 5) + t.charCodeAt(n); return 2147483647 & e`
    /// (e starts at 0) — ptqrtoken. JS `e` is an IEEE-754 double (the
    /// accumulation is not truncated to 32 bits), so this must be
    /// simulated with Double or long qrsigs overflow Int64 and the
    /// ptqrtoken comes out wrong.
    static func hash33(_ t: String) -> Int {
        var e: Double = 0
        for unit in t.utf16 {
            e = e + Double(Self.toInt32Shift(e)) + Double(unit)
        }
        return Int(Self.toInt32(e) & 0x7FFF_FFFF)
    }

    /// wp_MusicApi's `f()`: n starts at 5381, key is skey/qqmusic_key —
    /// used for the OAuth `g_tk`.
    static func hash5381(_ t: String) -> Int {
        var e: Double = 5381
        for unit in t.utf16 {
            e = e + Double(Self.toInt32Shift(e)) + Double(unit)
        }
        return Int(Self.toInt32(e) & 0x7FFF_FFFF)
    }

    /// JS `ToInt32(d) << 5` (32-bit signed truncation).
    private static func toInt32Shift(_ d: Double) -> Int32 {
        let u = Self.toUInt32(d)
        return Int32(bitPattern: u &* 32)
    }

    /// JS `ToInt32(d)`: modulo 2^32, then signed 32-bit.
    private static func toInt32(_ d: Double) -> Int32 {
        Int32(bitPattern: Self.toUInt32(d))
    }

    private static func toUInt32(_ d: Double) -> UInt32 {
        var r = d.truncatingRemainder(dividingBy: 4294967296.0)
        if r < 0 { r += 4294967296.0 }
        return UInt32(r)
    }
}

extension Notification.Name {
    /// Posted when a cookie import completes (primary login path).
    static let qqMusicLoginDidUpdate = Notification.Name("sb.moe.kumone.qqmusic.loginDidUpdate")
}

/// Blocks automatic redirects so the OAuth authorize step can read the
/// `code` out of the `Location` header itself.
private final class QQMusicNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
