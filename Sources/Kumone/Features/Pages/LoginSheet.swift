import CoreImage.CIFilterBuiltins
import SwiftUI
import WebKit

/// Folia platform logins (folia-full-ios-port). Shown in LoginSheet under
/// "更多平台" and reachable from Settings → 账号. Each platform keeps its
/// own session; none of them touches the NetEase `AccountStore`.
enum ProviderLogin: String, CaseIterable, Identifiable {
    case qqmusic = "QQ音乐"
    case kugou = "酷狗"

    var id: String { rawValue }
}

struct LoginSheet: View {
    // NetEase sign-in is Beans' web login now (NetEaseWebLoginPanel):
    // the Kumone QR/SMS flow (Mode/startLogin/sendCode/loginWithCode)
    // was deleted in the Beans-settings-home port. `Phase` stays: the
    // Kugou QR flow shares it via `platformQRCard`.
    private enum Phase: Equatable {
        case loading
        case waiting          // 801
        case scanned(String)  // 802, nickname
        case expired          // 800
        case success
        case failed(String)
    }

    // Folia platform login (nil = NetEase web login below).
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

    init(initialProvider: ProviderLogin? = nil) {
        _provider = State(initialValue: initialProvider)
    }

    @EnvironmentObject private var toasts: ToastCenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            if let provider {
                providerHeader(for: provider)
                providerSection(for: provider)
            } else {
                SyncedLoginButtons(onFinished: { signedIn in
                    if signedIn { dismiss() }
                })
                .padding(.horizontal, 24)

                // NetEase sign-in is Beans' web login (NetEaseWebLoginPanel).
                // The sheet title lives inside the panel. There is no
                // provider list here anymore: AccountHubSheet is the single
                // account entry point and opens this sheet per provider.
                NetEaseWebLoginPanel()
                    .padding(.top, 28)
            }

            Button("取消") {
                dismiss()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .padding(.bottom, 20)
        }
        .frame(width: provider == .kugou ? 320 : 480)
        .overlay(alignment: .top) {
            if let toast = toasts.current { ToastView(toast: toast).padding(.top, 8) }
        }
        .onAppear {
            if let provider { startProvider(provider) }
        }
        .onDisappear {
            kgPollTask?.cancel()
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
            }
        }
    }

    private func startProvider(_ item: ProviderLogin) {
        switch item {
        // QQ web login loads y.qq.com on appear; sync is manual.
        case .qqmusic: break
        case .kugou: startKugouLogin()
        }
    }



    /// Shared QR card for the platform logins (driven by the caller's own
    /// phase/image state).
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
