import SwiftUI

/// Account hub (Beans `AccountHubSheet`, adapted): one card per platform,
/// replacing the Settings page's account area and `LoginSheet`'s provider
/// list as the single account entry point. NetEase reads
/// `AccountStore.profile` (Beans' `AuthStore.user` is not used); QQ and
/// Kugou read their own auth singletons. Each card opens that platform's
/// login sheet when logged out, or asks for logout confirmation when
/// logged in; logging out also clears the platform's web-login data
/// (`WebLoginDataCleaner`), so the next login starts clean.
///
/// Styling is Golia's own (`Theme.accent`, `ToastCenter`); Beans'
/// `BeansFont`/Beans colors/`BeansHaptics`/glass surfaces and brand
/// images are not used — Golia has no brand assets, so each card shows
/// a first-character tile instead. No `VIPBadgeView` in Golia either;
/// the membership badge is a plain capsule.
///
/// Bilibili card: added on the rebase over main 2ca91b8 (PR #39),
/// same shape as the QQ/Kugou cards; login opens `LoginSheet` with
/// `ProviderLogin.bilibili` (QR flow). No web-login data to clear on
/// logout — the QR login keeps its session in the Keychain only.
struct AccountHubSheet: View {
    @EnvironmentObject private var account: AccountStore
    @ObservedObject private var qqAuth = QQMusicAuth.shared
    @ObservedObject private var kgAuth = KugouMusicAuth.shared
    @ObservedObject private var blAuth = BilibiliAuth.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showNeteaseLogin = false
    @State private var showQQLogin = false
    @State private var showKugouLogin = false
    @State private var showBilibiliLogin = false
    @State private var confirmNeteaseLogout = false
    @State private var confirmQQLogout = false
    @State private var confirmKugouLogout = false
    @State private var confirmBilibiliLogout = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("账号")
                        .font(.headline)
                        .padding(.horizontal, 16)
                    neteaseCard
                    qqCard
                    kugouCard
                    bilibiliCard
                }
                .padding(16)
            }
            .navigationTitle("账号登录")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showNeteaseLogin) { LoginSheet() }
        .sheet(isPresented: $showQQLogin) { LoginSheet(initialProvider: .qqmusic) }
        .sheet(isPresented: $showKugouLogin) { LoginSheet(initialProvider: .kugou) }
        .sheet(isPresented: $showBilibiliLogin) { LoginSheet(initialProvider: .bilibili) }
        .confirmationDialog("退出网易云登录？", isPresented: $confirmNeteaseLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                Task {
                    do {
                        try await AccountStore.shared.logout()
                        WebLoginDataCleaner.clearNetEase()
                        ToastCenter.shared.show("已退出网易云账号")
                    } catch {
                        ToastCenter.shared.show(error.localizedDescription)
                    }
                }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("退出 QQ 音乐？", isPresented: $confirmQQLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                qqAuth.logout()
                WebLoginDataCleaner.clearQQMusic()
                ToastCenter.shared.show("已退出 QQ 音乐")
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("退出酷狗音乐？", isPresented: $confirmKugouLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                kgAuth.logout()
                WebLoginDataCleaner.clearKugou()
                ToastCenter.shared.show("已退出酷狗音乐")
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("退出哔哩哔哩登录？", isPresented: $confirmBilibiliLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                blAuth.logout()
                ToastCenter.shared.show("已退出哔哩哔哩账号")
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var neteaseCard: some View {
        let profile = account.profile
        return accountCard(
            title: "网易云音乐",
            iconLetter: "网",
            status: profile.map { $0.nickname.isEmpty ? "已登录" : $0.nickname } ?? "未登录 · 网页登录同步歌单",
            badge: (profile?.vipType ?? 0) > 0 ? "VIP" : nil,
            isLoggedIn: profile != nil,
            onTap: {
                if profile != nil { confirmNeteaseLogout = true } else { showNeteaseLogin = true }
            }
        )
    }

    private var qqCard: some View {
        accountCard(
            title: "QQ 音乐",
            iconLetter: "Q",
            status: qqAuth.isLoggedIn
                ? (qqAuth.nickname.isEmpty ? "已登录" : qqAuth.nickname)
                : "未登录 · 网页 / 扫码 / Cookie 登录",
            badge: qqAuth.isLoggedIn ? qqAuth.vipBadge : nil,
            isLoggedIn: qqAuth.isLoggedIn,
            onTap: {
                if qqAuth.isLoggedIn { confirmQQLogout = true } else { showQQLogin = true }
            }
        )
    }

    private var kugouCard: some View {
        accountCard(
            title: "酷狗音乐",
            iconLetter: "酷",
            status: kgAuth.isLoggedIn
                ? (kgAuth.nickname.isEmpty ? "已登录" : kgAuth.nickname)
                : "未登录 · App 扫码同步歌单",
            badge: kgAuth.isLoggedIn && kgAuth.vipType > 0 ? "VIP" : nil,
            isLoggedIn: kgAuth.isLoggedIn,
            onTap: {
                if kgAuth.isLoggedIn { confirmKugouLogout = true } else { showKugouLogin = true }
            }
        )
    }

    private var bilibiliCard: some View {
        accountCard(
            title: "哔哩哔哩",
            iconLetter: "哔",
            status: blAuth.isLoggedIn
                ? (blAuth.nickname.isEmpty ? "已登录" : blAuth.nickname)
                : "未登录 · App 扫码登录",
            badge: nil,
            isLoggedIn: blAuth.isLoggedIn,
            onTap: {
                if blAuth.isLoggedIn { confirmBilibiliLogout = true } else { showBilibiliLogin = true }
            }
        )
    }

    private func accountCard(
        title: String,
        iconLetter: String,
        status: String,
        badge: String?,
        isLoggedIn: Bool,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.accent.opacity(0.12))
                        .frame(width: 48, height: 48)
                    Text(iconLetter)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 6) {
                        Text(status)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.accent, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                }
                Spacer()
                Text(isLoggedIn ? "退出" : "登录")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isLoggedIn ? .red : Theme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(.quaternary.opacity(0.4), in: Capsule())
            }
            .padding(14)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
