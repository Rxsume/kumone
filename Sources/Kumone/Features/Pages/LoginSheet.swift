import CoreImage.CIFilterBuiltins
import SwiftUI
import WebKit

/// Folia platform logins (folia-full-ios-port). Shown in LoginSheet under
/// "更多平台" and reachable from Settings → 账号. Each platform keeps its
/// own session; none of them touches the NetEase `AccountStore`.
enum ProviderLogin: String, CaseIterable, Identifiable {
    case qqmusic = "QQ音乐"
    case kugou = "酷狗"
    case fnmusic = "飞牛音乐"
    case spotify = "Spotify"
    case appleMusic = "Apple Music"

    var id: String { rawValue }
}

struct LoginSheet: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case qr = "扫码登录"
        case sms = "手机验证码"

        var id: String { rawValue }
    }

    private enum Phase: Equatable {
        case loading
        case waiting          // 801
        case scanned(String)  // 802, nickname
        case expired          // 800
        case success
        case failed(String)
    }

    @State private var mode: Mode = .qr
    @State private var phase: Phase = .loading
    @State private var qrImage: PlatformImage?
    @State private var unikey: String?
    @State private var pollTask: Task<Void, Never>?

    // Folia platform login (nil = NetEase qr/sms above).
    @State private var provider: ProviderLogin?
    // QQ Music web login (Beans QQWebLoginSheet / QQLoginSheet): the
    // WKWebView holds the y.qq.com session; login is synced by reading
    // its cookie store, with manual Cookie-header paste as fallback.
    // No QR poll task: nothing polls until the user taps "同步登录状态".
    private enum QQLoginMode: String, CaseIterable, Identifiable {
        case web = "网页登录"
        case paste = "粘贴 Cookie"
        var id: String { rawValue }
    }
    @State private var qqLoginMode: QQLoginMode = .web
    @State private var qqCookieText = ""
    @State private var qqMessage: String?
    @State private var qqSyncing = false
    @State private var qqPageLoaded = false
    // Kugou QR login.
    @State private var kgPhase: Phase = .loading
    @State private var kgQRImage: PlatformImage?
    @State private var kgKey: String?
    @State private var kgPollTask: Task<Void, Never>?
    // FNMusic form login.
    @State private var fnBase = FNMusicSession.shared.serverBase ?? ""
    @State private var fnUsername = FNMusicSession.shared.username ?? ""
    @State private var fnPassword = ""
    @State private var fnLoggingIn = false
    @State private var fnMessage: String?
    // Spotify OAuth login.
    @State private var spLoggingIn = false
    @State private var spMessage: String?
    // Apple Music (MusicKit) login.
    @State private var amLoggingIn = false
    @State private var amMessage: String?

    init(initialProvider: ProviderLogin? = nil) {
        _provider = State(initialValue: initialProvider)
    }

    // SMS login
    @State private var phone = ""
    @State private var code = ""
    @State private var smsCooldown = 0
    @State private var smsSending = false
    @State private var smsLoggingIn = false
    @State private var smsMessage: String?
    @State private var cooldownTask: Task<Void, Never>?

    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var toasts: ToastCenter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 20) {
            if let provider {
                providerHeader(for: provider)
                providerSection(for: provider)
            } else {
                VStack(spacing: 6) {
                    Text("登录账号")
                        .font(.title3.weight(.semibold))
                    Picker("", selection: $mode) {
                        ForEach(Mode.allCases) { mode in
                            Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                    .padding(.top, 6)
                }
                .padding(.top, 28)

                SyncedLoginButtons(onStart: { pollTask?.cancel() }, onFinished: { signedIn in
                    if signedIn { dismiss() }
                    else if mode == .qr, !account.isLoggedIn { startLogin(reusingKey: true) }
                })
                .padding(.horizontal, 24)

                switch mode {
                case .qr:
                    qrSection
                case .sms:
                    smsSection
                }

                providerListSection
            }

            Button("取消") {
                dismiss()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .padding(.bottom, 20)
        }
        .frame(width: provider == .qqmusic ? 480 : 320)
        .overlay(alignment: .top) {
            if let toast = toasts.current { ToastView(toast: toast).padding(.top, 8) }
        }
        .onAppear {
            if let provider { startProvider(provider) }
            else { startLogin() }
        }
        .onDisappear {
            pollTask?.cancel()
            cooldownTask?.cancel()
            kgPollTask?.cancel()
        }
        // Coming back from the official app (single-device flow): if polling
        // died while we were in the background, pick it up again.
        .onChange(of: scenePhase) { _ in
            guard provider == nil, scenePhase == .active, mode == .qr else { return }
            if case .failed = phase { startLogin(reusingKey: true) }
            else if pollTask == nil || pollTask?.isCancelled == true { startLogin(reusingKey: true) }
        }
        .onChange(of: mode) { _ in
            if provider == nil, mode == .qr, case .failed = phase { startLogin(reusingKey: true) }
        }
        .onChange(of: provider) { _ in
            if let provider { startProvider(provider) }
        }
    }

    // MARK: - Folia platform logins

    private func providerHeader(for item: ProviderLogin) -> some View {
        HStack {
            Button {
                kgPollTask?.cancel()
                provider = nil
            } label: {
                Label("返回", systemImage: "chevron.left")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            Spacer()
            Text(item.rawValue)
                .font(.title3.weight(.semibold))
            Spacer()
            Color.clear.frame(width: 52, height: 1)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
    }

    private func providerSection(for item: ProviderLogin) -> some View {
        Group {
            switch item {
            case .qqmusic: qqSection
            case .kugou: kugouSection
            case .fnmusic: fnmusicSection
            case .spotify: spotifySection
            case .appleMusic: appleMusicSection
            }
        }
    }

    private var providerListSection: some View {
        VStack(spacing: 2) {
            Text("更多平台")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.bottom, 2)
            ForEach(ProviderLogin.allCases) { item in
                Button {
                    provider = item
                } label: {
                    HStack {
                        Text(item.rawValue)
                            .font(.system(size: 14))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
            Text("QQ / 酷狗直连官方登录，无需自托管后端；飞牛连自己的 NAS；Spotify 需填 Client ID；Apple Music 需粘贴 Developer Token。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 4)
        }
    }

    private func startProvider(_ item: ProviderLogin) {
        switch item {
        // QQ web login loads y.qq.com on appear; sync is manual.
        case .qqmusic: break
        case .kugou: startKugouLogin()
        case .fnmusic, .spotify, .appleMusic: break
        }
    }

    /// Shared QR card for the platform logins (same layout as the NetEase
    /// `qrSection` card, driven by the caller's own phase/image state).
    private func platformQRCard(image: PlatformImage?, phase: Phase, waitingText: String, onRefresh: @escaping () -> Void) -> some View {
        VStack(spacing: 20) {
            Text(waitingText)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white)
                    .frame(width: 208, height: 208)
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)

                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 180, height: 180)
                        .blur(radius: platformOverlayVisible(phase) ? 3 : 0)
                } else {
                    ProgressView()
                }

                if platformOverlayVisible(phase) {
                    VStack(spacing: 10) {
                        switch phase {
                        case .expired:
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(Theme.accent)
                            Text("二维码已失效")
                                .font(.system(size: 12, weight: .medium))
                            Button("刷新") { onRefresh() }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.accent)
                                .controlSize(.small)
                        case .scanned(let nickname):
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(.green)
                            Text("已扫码")
                                .font(.system(size: 13, weight: .semibold))
                            Text("\(nickname)，请在手机上确认")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        default:
                            EmptyView()
                        }
                    }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            Group {
                switch phase {
                case .loading:
                    Text("正在获取二维码…")
                case .waiting:
                    Text(waitingText)
                case .scanned:
                    Text("等待手机确认…")
                case .expired:
                    Text("二维码已失效，请刷新")
                case .success:
                    Text("登录成功！")
                case .failed(let message):
                    Text(message).foregroundStyle(Theme.accent)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            #if os(iOS)
            Text("只有一台设备？截图二维码，到官方 App 的扫一扫里选择相册识别，然后回到这里即可")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            #endif
        }
    }

    private func platformOverlayVisible(_ phase: Phase) -> Bool {
        switch phase {
        case .expired, .scanned: return true
        default: return false
        }
    }

    // MARK: - QQ Music (Beans: web login + manual Cookie paste)

    private var qqSection: some View {
        VStack(spacing: 16) {
            Picker("登录方式", selection: $qqLoginMode) {
                ForEach(QQLoginMode.allCases) { mode in
                    Text(LocalizedStringKey(mode.rawValue)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .padding(.horizontal, 28)

            switch qqLoginMode {
            case .web: qqWebPanel
            case .paste: qqPastePanel
            }
        }
        .frame(minHeight: 300)
    }

    /// Beans QQWebLoginPanel: WKWebView opens y.qq.com; the user logs in
    /// on the page, then taps "同步登录状态" to read the webview's cookie
    /// store into `QQMusicAuth`. No backend, no QR polling.
    private var qqWebPanel: some View {
        VStack(spacing: 12) {
            Text("在下方网页右上角点「登录」，完成后手动点击下方「同步登录状态」")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            ZStack {
                QQWebView(onLoaded: { qqPageLoaded = true })
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(height: 320)
                    .padding(.horizontal, 24)
                if !qqPageLoaded {
                    ProgressView("正在加载 QQ 音乐…")
                }
            }

            if let qqMessage {
                Text(qqMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Button {
                syncQQCookies()
            } label: {
                Group {
                    if qqSyncing {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Label("同步登录状态", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(
                    Capsule().fill(!qqSyncing ? AnyShapeStyle(Theme.accentGradient)
                                              : AnyShapeStyle(Color.secondary.opacity(0.25)))
                )
            }
            .buttonStyle(.pressable).disabled(qqSyncing)
            .padding(.horizontal, 28).padding(.top, 2)
        }
    }

    /// Reads the WKWebView cookie store (qq.com cookies only) and hands
    /// them to `QQMusicAuth`; `loginValidationMessage` decides whether
    /// the login state is actually usable.
    private func syncQQCookies() {
        qqSyncing = true
        qqMessage = nil
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            var dict: [String: String] = [:]
            for cookie in cookies where cookie.domain.lowercased().hasSuffix("qq.com") {
                dict[cookie.name] = cookie.value
            }
            DispatchQueue.main.async {
                qqSyncing = false
                if let issue = QQMusicAuth.loginValidationMessage(dict) {
                    qqMessage = issue
                } else {
                    QQMusicAuth.shared.importCookies(dict, nickname: nil)
                    ToastCenter.shared.show(String(localized: "QQ音乐已登录"))
                    dismiss()
                }
            }
        }
    }

    /// Beans QQCookieImportPanel: paste a full Cookie header copied from
    /// a desktop browser (y.qq.com → F12 → Network → Request Headers).
    private var qqPastePanel: some View {
        VStack(spacing: 12) {
            Text("电脑浏览器打开 https://y.qq.com 登录 QQ 后，按 F12 → Network → 刷新页面，点任意请求，复制 Request Headers 里的整段 Cookie 粘贴到下方")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            TextEditor(text: $qqCookieText)
                .font(.system(size: 12, design: .monospaced))
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(height: 160)
                .padding(.horizontal, 24)

            if let qqMessage {
                Text(qqMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Button {
                importQQCookieText()
            } label: {
                Label("导入 Cookie", systemImage: "arrow.down.doc")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Capsule().fill(AnyShapeStyle(Theme.accentGradient)))
            }
            .buttonStyle(.pressable)
            .padding(.horizontal, 28).padding(.top, 2)
        }
    }

    private func importQQCookieText() {
        let dict = QQMusicAuth.parseCookieHeader(qqCookieText)
        guard QQMusicAuth.hasValidLogin(dict) else {
            qqMessage = "Cookie 格式或登录态无效，请确认已完整复制"
            return
        }
        QQMusicAuth.shared.importCookies(dict, nickname: nil)
        ToastCenter.shared.show(String(localized: "QQ音乐已登录"))
        dismiss()
    }

    // MARK: - Kugou (Beans: direct QR login, no backend)

    private var kugouSection: some View {
        platformQRCard(image: kgQRImage, phase: kgPhase, waitingText: "使用酷狗 App 扫码登录") {
            startKugouLogin()
        }
    }

    /// Beans KugouLoginSheet: `qrKey` gives a login URL rendered as a QR
    /// code here (Golia's `generateQR`, same as the NetEase flow), then
    /// `pollQR` every 2s until confirmed/expired. `pollQR` saves the
    /// login into `KugouMusicAuth` on confirmation, so the UI only has
    /// to toast and dismiss. Transient network errors are tolerated.
    private func startKugouLogin() {
        kgPollTask?.cancel()
        kgPhase = .loading
        kgQRImage = nil
        kgPollTask = Task {
            do {
                KugouMusicAuth.shared.prepareDevice()
                let login = try await KugouMusicAPI.shared.qrKey()
                kgKey = login.key
                kgQRImage = Self.generateQR(from: login.url)
                kgPhase = .waiting
                var consecutiveErrors = 0
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    do {
                        // Type inferred from pollQR: works whether A nests
                        // QRState in KugouMusicAPI (as Beans does) or not.
                        let state = try await KugouMusicAPI.shared.pollQR(key: login.key)
                        consecutiveErrors = 0
                        switch state {
                        case .waiting:
                            if case .waiting = kgPhase {} else { kgPhase = .waiting }
                        case .scanned:
                            kgPhase = .scanned("")
                        case .confirmed:
                            kgPhase = .success
                            ToastCenter.shared.show(String(localized: "酷狗已登录"))
                            dismiss()
                            return
                        case .expired:
                            kgPhase = .expired
                            kgKey = nil
                            return
                        }
                    } catch {
                        consecutiveErrors += 1
                        if consecutiveErrors >= 15 { throw error }
                        continue
                    }
                }
            } catch {
                if !Task.isCancelled { kgPhase = .failed(error.localizedDescription) }
            }
        }
    }

    // MARK: - FNMusic

    private var fnmusicSection: some View {
        VStack(spacing: 16) {
            Text("登录飞牛音乐，连接你自己的 NAS")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 20)
                    TextField("服务器地址，例如 http://192.168.1.10:5666", text: $fnBase)
                        .textFieldStyle(.plain).font(.system(size: 15))
                        #if os(iOS)
                        .keyboardType(.URL).textContentType(.URL)
                        .autocapitalization(.none).autocorrectionDisabled()
                        #endif
                }
                .fieldChrome()

                HStack(spacing: 10) {
                    Image(systemName: "person")
                        .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 20)
                    TextField("账号", text: $fnUsername)
                        .textFieldStyle(.plain).font(.system(size: 15))
                        #if os(iOS)
                        .autocapitalization(.none).autocorrectionDisabled()
                        #endif
                }
                .fieldChrome()

                HStack(spacing: 10) {
                    Image(systemName: "lock")
                        .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 20)
                    SecureField("密码", text: $fnPassword)
                        .textFieldStyle(.plain).font(.system(size: 15))
                }
                .fieldChrome()
            }
            .padding(.horizontal, 28)

            if let fnMessage {
                Text(fnMessage)
                    .font(.system(size: 12)).foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
            }

            Button {
                loginFNMusic()
            } label: {
                Group {
                    if fnLoggingIn {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Text("登录")
                    }
                }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(
                    Capsule().fill(canLoginFNMusic ? AnyShapeStyle(Theme.accentGradient)
                                                    : AnyShapeStyle(Color.secondary.opacity(0.25)))
                )
            }
            .buttonStyle(.pressable).disabled(!canLoginFNMusic)
            .padding(.horizontal, 28).padding(.top, 2)
        }
        .frame(minHeight: 300)
    }

    private var canLoginFNMusic: Bool {
        !fnLoggingIn && !fnBase.trimmingCharacters(in: .whitespaces).isEmpty
            && !fnUsername.trimmingCharacters(in: .whitespaces).isEmpty
            && !fnPassword.isEmpty
    }

    private func loginFNMusic() {
        fnLoggingIn = true
        fnMessage = nil
        Task {
            defer { fnLoggingIn = false }
            do {
                let user = try await FNMusicSession.shared.login(base: fnBase, username: fnUsername, password: fnPassword)
                ToastCenter.shared.show(String(localized: "飞牛音乐已登录，欢迎回来，\(user.nickname)"))
                dismiss()
            } catch {
                fnMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Spotify

    private var spotifySection: some View {
        VStack(spacing: 16) {
            Text("用 Spotify 账号登录（浏览器授权），只浏览、搜索与查看歌单，不能播放。")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if !SpotifyConfiguration().canLogIn {
                Text("需先在 Spotify Developer Dashboard 注册应用，并在设置 → Spotify 里填入 Client ID 与 Redirect URI。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Button {
                loginSpotify()
            } label: {
                Group {
                    if spLoggingIn {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Text("登录 Spotify")
                    }
                }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(
                    Capsule().fill(SpotifyConfiguration().canLogIn && !spLoggingIn
                        ? AnyShapeStyle(Theme.accentGradient)
                        : AnyShapeStyle(Color.secondary.opacity(0.25)))
                )
            }
            .buttonStyle(.pressable).disabled(!SpotifyConfiguration().canLogIn || spLoggingIn)
            .padding(.horizontal, 28).padding(.top, 2)
            if let spMessage {
                Text(spMessage)
                    .font(.system(size: 12)).foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
            }
        }
        .frame(minHeight: 200)
    }

    private func loginSpotify() {
        spLoggingIn = true
        spMessage = nil
        Task {
            defer { spLoggingIn = false }
            do {
                let profile = try await SpotifyAuthSession.shared.beginLogin()
                ToastCenter.shared.show(String(localized: "Spotify 已登录，欢迎回来，\(profile.displayName ?? "")"))
                dismiss()
            } catch {
                spMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Apple Music

    private var appleMusicSection: some View {
        VStack(spacing: 16) {
            Text("用 Apple ID 登录 Apple Music（系统授权），只浏览目录与曲库，不播放。")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if let blocker = AppleMusicSession.shared.loginBlocker {
                Text(appleMusicBlockerText(blocker))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Button {
                loginAppleMusic()
            } label: {
                Group {
                    if amLoggingIn {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Text("登录 Apple Music")
                    }
                }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(
                    Capsule().fill(AppleMusicSession.shared.loginBlocker == nil && !amLoggingIn
                        ? AnyShapeStyle(Theme.accentGradient)
                        : AnyShapeStyle(Color.secondary.opacity(0.25)))
                )
            }
            .buttonStyle(.pressable).disabled(AppleMusicSession.shared.loginBlocker != nil || amLoggingIn)
            .padding(.horizontal, 28).padding(.top, 2)
            if let amMessage {
                Text(amMessage)
                    .font(.system(size: 12)).foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
            }
        }
        .frame(minHeight: 200)
    }

    private func appleMusicBlockerText(_ blocker: AppleMusicSession.LoginBlocker) -> String {
        switch blocker {
        case .missingDeveloperToken:
            return "需先在设置 → 账号 → Apple Music 里粘贴 Developer Token（用自己的 Apple Developer MusicKit 凭据签发）。"
        case .developerTokenExpired:
            return "Developer Token 已过期，请重新签发并粘贴。"
        case .notAuthorized:
            return "已在系统设置里拒绝 Apple Music 访问，请去设置 → 隐私与安全性里允许。"
        case .missingUserToken:
            return "点下方按钮登录 Apple Music。"
        }
    }

    private func loginAppleMusic() {
        amLoggingIn = true
        amMessage = nil
        Task {
            defer { amLoggingIn = false }
            do {
                try await AppleMusicSession.shared.signIn()
                ToastCenter.shared.show(String(localized: "Apple Music 已登录"))
                dismiss()
            } catch {
                amMessage = error.localizedDescription
            }
        }
    }

    // MARK: - QR

    private var qrSection: some View {
        VStack(spacing: 20) {
            Text("使用官方 App 扫码登录")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white)
                    .frame(width: 208, height: 208)
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)

                if let qrImage {
                    Image(platformImage: qrImage)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 180, height: 180)
                        .blur(radius: overlayVisible ? 3 : 0)
                } else {
                    ProgressView()
                }

                if overlayVisible {
                    VStack(spacing: 10) {
                        switch phase {
                        case .expired:
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(Theme.accent)
                            Text("二维码已失效")
                                .font(.system(size: 12, weight: .medium))
                            Button("刷新") {
                                startLogin()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                            .controlSize(.small)
                        case .scanned(let nickname):
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(.green)
                            Text("已扫码")
                                .font(.system(size: 13, weight: .semibold))
                            Text("\(nickname)，请在手机上确认")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        default:
                            EmptyView()
                        }
                    }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            Group {
                switch phase {
                case .loading:
                    Text("正在获取二维码…")
                case .waiting:
                    Text("打开官方 App，扫一扫登录")
                case .scanned:
                    Text("等待手机确认…")
                case .expired:
                    Text("二维码已失效，请刷新")
                case .success:
                    Text("登录成功！")
                case .failed(let message):
                    Text(message).foregroundStyle(Theme.accent)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            #if os(iOS)
            Text("只有一台设备？截图二维码，到官方 App 的扫一扫里选择相册识别，然后回到这里即可")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            #endif
        }
    }

    private var overlayVisible: Bool {
        switch phase {
        case .expired, .scanned: return true
        default: return false
        }
    }

    /// Starts (or resumes) the QR login. Polling tolerates transient network
    /// errors (the app being backgrounded while the user scans) instead of
    /// giving up on the first failure.
    private func startLogin(reusingKey: Bool = false) {
        pollTask?.cancel()
        let existingKey = reusingKey ? unikey : nil
        if existingKey == nil {
            phase = .loading
            qrImage = nil
        } else {
            phase = .waiting
        }
        pollTask = Task {
            do {
                let key: String
                if let existingKey {
                    key = existingKey
                } else {
                    key = try await MusicAPI.qrKey()
                    unikey = key
                    guard let loginURL = MusicAPI.qrLoginURL(unikey: key) else { throw MusicAPIError.notConfigured }
                    qrImage = Self.generateQR(from: loginURL)
                    phase = .waiting
                }

                var consecutiveErrors = 0
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(1.2))
                    let check: MusicAPI.QRCheckResponse
                    do {
                        check = try await MusicAPI.qrCheck(unikey: key)
                        consecutiveErrors = 0
                    } catch {
                        consecutiveErrors += 1
                        if consecutiveErrors >= 15 { throw error }
                        continue
                    }
                    switch check.code {
                    case 800:
                        phase = .expired
                        unikey = nil
                        return
                    case 801:
                        if case .waiting = phase {} else { phase = .waiting }
                    case 802:
                        phase = .scanned(check.nickname ?? "")
                    case 803:
                        phase = .success
                        await account.bootstrap()
                        ToastCenter.shared.show(String(localized: "欢迎回来，\(account.profile?.nickname ?? "")"))
                        dismiss()
                        return
                    default:
                        break
                    }
                }
            } catch {
                if !Task.isCancelled {
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - SMS

    private var smsSection: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                Text("可能被风控拦截而不可用，推荐使用扫码登录")
                    .font(.system(size: 11.5))
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 28)

            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "iphone")
                        .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 20)
                    Text("+86").font(.system(size: 15, weight: .medium))
                    Rectangle().fill(.quaternary).frame(width: 1, height: 20)
                    TextField("手机号", text: $phone)
                        .textFieldStyle(.plain).font(.system(size: 15))
                        #if os(iOS)
                        .keyboardType(.phonePad).textContentType(.telephoneNumber)
                        #endif
                }
                .fieldChrome()

                HStack(spacing: 10) {
                    TextField("验证码", text: $code)
                        .textFieldStyle(.plain).font(.system(size: 15))
                        #if os(iOS)
                        .keyboardType(.numberPad).textContentType(.oneTimeCode)
                        #endif
                    Button {
                        sendCode()
                    } label: {
                        Group {
                            if smsSending {
                                ProgressView().controlSize(.small)
                            } else if smsCooldown > 0 {
                                Text("\(smsCooldown)s").monospacedDigit()
                            } else {
                                Text("获取验证码")
                            }
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(canSendCode ? Theme.accent : .secondary)
                    }
                    .buttonStyle(.plain).disabled(!canSendCode)
                }
                .fieldChrome()
            }
            .padding(.horizontal, 28)

            if let smsMessage {
                Text(smsMessage)
                    .font(.system(size: 12)).foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
            }

            Button {
                loginWithCode()
            } label: {
                Group {
                    if smsLoggingIn {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Text("登录")
                    }
                }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(
                    Capsule().fill(canLogin ? AnyShapeStyle(Theme.accentGradient)
                                            : AnyShapeStyle(Color.secondary.opacity(0.25)))
                )
            }
            .buttonStyle(.pressable).disabled(!canLogin)
            .padding(.horizontal, 28).padding(.top, 2)
        }
        .frame(minHeight: 300)
    }

    private var canSendCode: Bool { !smsSending && smsCooldown == 0 && phone.count >= 11 }
    private var canLogin: Bool { !smsLoggingIn && phone.count >= 11 && code.count >= 4 }


    private func sendCode() {
        smsSending = true
        smsMessage = nil
        Task {
            defer { smsSending = false }
            do {
                try await MusicAPI.sendSMSCode(phone: phone)
                smsMessage = String(localized: "验证码已发送")
                smsCooldown = 60
                cooldownTask?.cancel()
                cooldownTask = Task {
                    while smsCooldown > 0, !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        smsCooldown -= 1
                    }
                }
            } catch {
                smsMessage = error.localizedDescription
            }
        }
    }

    private func loginWithCode() {
        smsLoggingIn = true
        smsMessage = nil
        Task {
            defer { smsLoggingIn = false }
            do {
                try await MusicAPI.loginCellphone(phone: phone, captcha: code)
                pollTask?.cancel()
                await account.bootstrap()
                ToastCenter.shared.show(String(localized: "欢迎回来，\(account.profile?.nickname ?? "")"))
                dismiss()
            } catch {
                smsMessage = error.localizedDescription
            }
        }
    }

    private static func generateQR(from string: String) -> PlatformImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: cgImage, size: NSSize(width: 180, height: 180))
        #elseif os(iOS)
        return UIImage(cgImage: cgImage)
        #endif
    }
}

// MARK: - QQ web login view (Beans QQWebView, adapted)

/// Opens y.qq.com inside the app so the user can log in on the page.
/// The session cookies stay in the default `WKWebsiteDataStore` and are
/// read back by `LoginSheet.syncQQCookies` — nothing is scraped from
/// the page itself. iOS uses `UIViewRepresentable`, macOS `NSViewRepresentable`.
#if os(iOS)
struct QQWebView: UIViewRepresentable {
    let onLoaded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLoaded: onLoaded) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        webView.navigationDelegate = context.coordinator
        if let url = URL(string: "https://y.qq.com/") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onLoaded: () -> Void

        init(onLoaded: @escaping () -> Void) { self.onLoaded = onLoaded }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async { self.onLoaded() }
        }
    }
}
#elseif os(macOS)
struct QQWebView: NSViewRepresentable {
    let onLoaded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLoaded: onLoaded) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        webView.navigationDelegate = context.coordinator
        if let url = URL(string: "https://y.qq.com/") {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onLoaded: () -> Void

        init(onLoaded: @escaping () -> Void) { self.onLoaded = onLoaded }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async { self.onLoaded() }
        }
    }
}
#endif

private extension View {
    func fieldChrome() -> some View {
        self
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.06), lineWidth: 1))
    }
}
