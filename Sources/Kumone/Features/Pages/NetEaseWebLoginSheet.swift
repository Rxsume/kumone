import SwiftUI
import WebKit

/// NetEase sign-in via Beans' web login (`NetEaseWebLoginPanel`).
///
/// Ported from Beans (`NetEaseWebLoginSheet.swift`, `LoginView.swift`) and
/// adapted to Golia: a `WKWebView` opens `music.163.com/#/login`, the user
/// signs in on the page, then taps "同步登录状态" to read the web view's
/// cookie store. The cookies are verified against an isolated client before
/// they touch the shared session (the same pattern as
/// `AccountStore.importLogin`), then committed and bootstrapped. Replaces
/// the Kumone QR/SMS sign-in flow (deleted from `LoginSheet` /
/// `MusicAPI` in the Beans-settings-home port).
///
/// Beans styling (`BeansFont`, Beans colors, `BeansHaptics`,
/// `GlassPressButtonStyle`) is replaced by Golia's `Theme` /
/// `ToastCenter`; the `WebKit` view follows the existing `QQWebView`
/// pattern (iOS `UIViewRepresentable` + macOS `NSViewRepresentable`,
/// desktop Safari user agent).
struct NetEaseWebLoginPanel: View {
    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss

    @State private var pageLoaded = false
    @State private var syncing = false
    @State private var message = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("登录账号")
                .font(.title3.weight(.semibold))
            Text("在下方网页中完成网易云登录，完成后手动点击下方「同步登录状态」")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            ZStack {
                NetEaseWebView(onLoaded: { pageLoaded = true })
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(height: 320)
                    .padding(.horizontal, 24)
                if !pageLoaded {
                    ProgressView("正在加载网易云音乐…")
                }
            }

            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Button {
                syncNow()
            } label: {
                Group {
                    if syncing {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Label("同步登录状态", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    Capsule().fill(!syncing ? AnyShapeStyle(Theme.accentGradient)
                                            : AnyShapeStyle(Color.secondary.opacity(0.25)))
                )
            }
            .buttonStyle(.pressable)
            .disabled(syncing)
            .padding(.horizontal, 28)
            .padding(.top, 2)
        }
        .frame(minHeight: 300)
    }

    private func syncNow() {
        syncing = true
        message = ""
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            var dict: [String: String] = [:]
            for cookie in cookies where cookie.domain.contains("music.163.com")
                || cookie.domain.contains(".163.com") {
                dict[cookie.name] = cookie.value
            }
            Task { @MainActor in
                syncing = false
                guard !(dict["MUSIC_U"] ?? "").isEmpty else {
                    message = "未检测到有效登录态，请先在网页中完成网易云登录"
                    return
                }
                do {
                    // Verify against an isolated client first: a stale or
                    // wrong cookie must never clobber the live session.
                    let candidate = MusicClient(configuration: .ephemeral, persistsCookies: false)
                    candidate.setCookies(dict)
                    guard let verified = try await MusicAPI.userAccount(using: candidate) else {
                        throw MusicAPIError.needLogin
                    }
                    try MusicClient.shared.replaceAuthentication(with: candidate.authenticationCookies())
                    await account.bootstrap()
                    ToastCenter.shared.show(String(localized: "欢迎回来，\(verified.nickname)"))
                    dismiss()
                } catch {
                    message = "同步账号失败：\(error.localizedDescription)"
                }
            }
        }
    }
}

/// The NetEase login page in a web view. Same dual-platform shape as
/// `QQWebView` in `LoginSheet.swift`.
struct NetEaseWebView: View {
    var onLoaded: () -> Void = {}

    var body: some View {
        #if os(iOS)
        _NetEaseWebView(onLoaded: onLoaded)
        #elseif os(macOS)
        _NetEaseWebView(onLoaded: onLoaded)
        #else
        EmptyView()
        #endif
    }
}

#if os(iOS)
private struct _NetEaseWebView: UIViewRepresentable {
    var onLoaded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLoaded: onLoaded) }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        if let url = URL(string: "https://music.163.com/#/login") {
            view.load(URLRequest(url: url))
        }
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onLoaded: () -> Void

        init(onLoaded: @escaping () -> Void) {
            self.onLoaded = onLoaded
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoaded()
        }
    }
}
#elseif os(macOS)
private struct _NetEaseWebView: NSViewRepresentable {
    var onLoaded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLoaded: onLoaded) }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        if let url = URL(string: "https://music.163.com/#/login") {
            view.load(URLRequest(url: url))
        }
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onLoaded: () -> Void

        init(onLoaded: @escaping () -> Void) {
            self.onLoaded = onLoaded
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoaded()
        }
    }
}
#endif
