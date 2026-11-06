import SwiftUI
#if os(macOS)
import Combine
#endif

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var account: AccountStore
    @Environment(\.openDestination) private var openDestination
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @AppStorage(SettingsManager.Keys.menuBarPlayer) private var showMenuBarPlayer = false
    @State private var navigationPath: [SettingsPage] = []
    #endif

    private enum SettingsPage: Hashable {
        case storage
        case themePark
        #if os(macOS)
        case shortcuts
        #endif
    }

    var body: some View {
        #if os(macOS)
        NavigationStack(path: $navigationPath) { settingsForm }
            .toolbar {
                if !navigationPath.isEmpty {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            _ = navigationPath.popLast()
                        } label: {
                            Label("返回", systemImage: "chevron.backward")
                        }
                        .labelStyle(.iconOnly)
                    }
                }
            }
            .background(SettingsWindowToolbar(onClose: { navigationPath.removeAll() }))
            .frame(width: 520, height: 620)
            .overlay(alignment: .top) { SettingsToastOverlay() }
        #else
        settingsForm
        #endif
    }

    private var settingsForm: some View {
        Form {
            Section("播放") {
                Picker("音质", selection: $settings.audioQuality) {
                    ForEach(AudioQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                Text("无损与 Hi-Res 需要黑胶 VIP，未开通时自动回落到可用音质")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("灰色歌曲解锁", isOn: $settings.enableUnblock)
                Text("无版权或下架歌曲将从已启用音源中匹配播放")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Group {
                    Toggle("暂停/播放淡入淡出", isOn: $settings.playbackFadeEnabled)
                    Text("暂停与恢复播放时音量短暂淡入淡出，避免声音突变")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("加歌默认行为", selection: $settings.queueAddBehavior) {
                        ForEach(QueueAddBehavior.allCases) { behavior in
                            Text(behavior.displayName).tag(behavior)
                        }
                    }
                    Toggle("无法播放自动跳过", isOn: $settings.autoSkipUnplayable)
                    Text("无法播放的歌曲自动跳到下一首")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #if os(iOS)
                    Toggle("播放时防息屏", isOn: $settings.preventDisplaySleepDuringPlayback)
                    Text("播放期间屏幕不自动息屏，暂停或切到后台后恢复")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("切歌淡入淡出", isOn: $settings.iosCrossfadeEnabled)
                    Text("切歌时两首歌重叠淡入淡出；关闭后恢复原来的直接切歌")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if settings.iosCrossfadeEnabled {
                        Picker("过渡模式", selection: $settings.transitionMode) {
                            ForEach(TransitionMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        if settings.transitionMode == .crossfade {
                            HStack {
                                Text("最长淡入淡出")
                                Spacer()
                                Text("\(Int(settings.crossfadeMaxSeconds)) 秒")
                                    .foregroundStyle(.secondary)
                            }
                            Slider(
                                value: $settings.crossfadeMaxSeconds,
                                in: SettingsManager.crossfadeMaxSecondsRange,
                                step: 1
                            )
                            HStack {
                                Text("2 秒")
                                Spacer()
                                Text("12 秒")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    #endif
                    Picker("响度平衡（ReplayGain）", selection: $settings.replayGainMode) {
                        ForEach(ReplayGainMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Text("按单曲或专辑统一播放响度；iOS 上只对已缓存分析过的歌曲生效")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }.disabled(!settings.foliaEnabled)
            }
            #if os(macOS)

            AutoMixSettingsSection()
            #endif

            if settings.enableUnblock {
                Section {
                    ForEach(AudioSourceID.allCases, id: \.self) { source in
                        Toggle(source.displayName, isOn: Binding(
                            get: { settings.enabledAudioSourceIDs.contains(source) },
                            set: { isEnabled in
                                if isEnabled {
                                    settings.enabledAudioSourceIDs.insert(source)
                                } else {
                                    settings.enabledAudioSourceIDs.remove(source)
                                }
                            }
                        ))
                    }
                } header: {
                    Text("音源")
                }
            }

            Section("外观") {
                Picker("主题", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.displayName).tag(appearance)
                    }
                }
                #if os(macOS)
                // macOS only renders two now-playing layouts — 黑胶 and the
                // regular page; the iOS 沉浸/简洁 options all fall back to the
                // regular page here, so offering four was misleading (#105).
                // Map any non-vinyl value onto 经典模式 so a stored default (e.g.
                // 沉浸模式) still shows a valid selection.
                Picker("播放页模式", selection: Binding(
                    get: { settings.nowPlayingMode == .vinyl ? .vinyl : .classic },
                    set: { settings.nowPlayingMode = $0 }
                )) {
                    Text(NowPlayingMode.vinyl.displayName).tag(NowPlayingMode.vinyl)
                    Text(NowPlayingMode.classic.displayName).tag(NowPlayingMode.classic)
                }
                #else
                Picker("播放页模式", selection: $settings.nowPlayingMode) {
                    ForEach(NowPlayingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Picker("横屏播放页样式", selection: $settings.landscapeNowPlayingStyle) {
                    ForEach(LandscapeNowPlayingStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                Text("iPhone 横放或 iPad 打开播放页时使用；竖屏仍按上面的「播放页模式」")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
                Toggle("点击封面打开专辑", isOn: $settings.openAlbumOnArtworkClick)
                Toggle("显示歌词翻译", isOn: $settings.showLyricsTranslation)
                Toggle("逐字歌词（卡拉OK）", isOn: $settings.verbatimLyrics)
                Picker("日文歌词读音", selection: $settings.lyricsAnnotation) {
                    ForEach(LyricsAnnotation.allCases) { annotation in
                        Text(annotation.displayName).tag(annotation)
                    }
                }
                Text("罗马音在歌词上方另起一行，汉字读音把假名标在汉字正上方；缺少官方罗马音时自动生成读音")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("主界面环境色", isOn: $settings.showMainWindowAmbientBackground)
                if settings.showMainWindowAmbientBackground {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("背景色强度")
                            Spacer()
                            Text("\(Int(settings.mainWindowAmbientBackgroundIntensity * 100))%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $settings.mainWindowAmbientBackgroundIntensity,
                            in: SettingsManager.mainWindowAmbientBackgroundIntensityRange,
                            step: 0.1
                        )
                        HStack {
                            Text("50%")
                            Spacer()
                            Text("150%")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                #if os(macOS)
                Toggle("桌面歌词", isOn: $settings.showDesktopLyrics)
                if settings.showDesktopLyrics {
                    Toggle("桌面歌词水平居中", isOn: $settings.desktopLyricsCentered)
                }
                Text("在屏幕上悬浮显示当前歌词，可拖动调整位置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
                Toggle("Folia 功能", isOn: $settings.foliaEnabled)
                Text("关闭后恢复到 Folia 功能加入前的行为；已保存的设置不会丢失，重新打开即可恢复")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Group {
                    Picker("歌词动画样式", selection: $settings.lyricAnimationStyle) {
                        ForEach(LyricAnimationStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    Picker("配色主题预设", selection: $settings.themePresetID) {
                        Text("默认").tag("default")
                        Text("暮色").tag("dusk")
                        Text("海洋").tag("ocean")
                        Text("林深").tag("forest")
                        Text("玫瑰").tag("rose")
                        Text("自定义").tag("custom")
                    }
                    NavigationLink(value: SettingsPage.themePark) {
                        Label("主题乐园", systemImage: "paintpalette")
                    }
                    Toggle("歌曲主题自动切换", isOn: $settings.songThemeAutoSwitch)
                    Text("切歌时播放页与主界面跟随当前歌曲封面取色，关闭后使用默认配色")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("优先使用自定义主题", isOn: $settings.preferCustomTheme)
                    Toggle("静态模式", isOn: $settings.staticMode)
                    Text("关闭动态效果（环境色过渡、黑胶旋转、歌词动效）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("减弱动态-背景", selection: $settings.reduceMotionBackground) {
                        Text("跟随系统").tag(nil as Bool?)
                        Text("开").tag(true as Bool?)
                        Text("关").tag(false as Bool?)
                    }
                    Picker("减弱动态-过渡", selection: $settings.reduceMotionTransitions) {
                        Text("跟随系统").tag(nil as Bool?)
                        Text("开").tag(true as Bool?)
                        Text("关").tag(false as Bool?)
                    }
                    Picker("减弱动态-微动效", selection: $settings.reduceMotionMicroMotion) {
                        Text("跟随系统").tag(nil as Bool?)
                        Text("开").tag(true as Bool?)
                        Text("关").tag(false as Bool?)
                    }
                    Text("未选择时跟随系统减弱动态设置")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("首页动态背景", isOn: $settings.homeDynamicBackground)
                    Toggle("播放页原生模糊", isOn: $settings.playerPageNativeBlur)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("播放页背景着色强度")
                            Spacer()
                            Text("\(Int(settings.playerPageTintIntensity * 100))%")
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $settings.playerPageTintIntensity,
                            in: SettingsManager.playerPageTintIntensityRange,
                            step: 0.1
                        )
                        HStack {
                            Text("50%")
                            Spacer()
                            Text("150%")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Picker("播放时打开", selection: $settings.playbackEntryView) {
                        ForEach(PlaybackEntryView.allCases) { entry in
                            Text(entry.displayName).tag(entry)
                        }
                    }
                    Text("点播开始播放时打开播放页，还是留在当前页")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }.disabled(!settings.foliaEnabled)
            }

            Section("播放页") {
                Toggle("隐藏进度条", isOn: $settings.hidePlayerProgressBar)
                Toggle("始终显示返回按钮", isOn: $settings.alwaysShowPlayerBackButton)
                Toggle("始终显示切歌按钮", isOn: $settings.alwaysShowTrackSwitchButtons)
                Toggle("浮动歌曲卡片", isOn: $settings.stageTrackCardEnabled)
                Toggle("过渡动画-屏幕圆环", isOn: $settings.transitionAnimationRing)
                Toggle("过渡动画-卡片描边", isOn: $settings.transitionAnimationCard)
                #if os(iOS)
                Text("iOS 需引擎移植后才生效")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }
            .disabled(!settings.foliaEnabled)

            Section("播放器控制槽位") {
                ForEach(PlayerControlSlot.allCases) { slot in
                    Toggle(slot.displayName, isOn: Binding(
                        get: { settings.playerControlSlots.contains(slot.rawValue) },
                        set: { isOn in
                            var slots = Set(settings.playerControlSlots)
                            if isOn {
                                slots.insert(slot.rawValue)
                            } else {
                                slots.remove(slot.rawValue)
                            }
                            settings.playerControlSlots = PlayerControlSlot.allCases
                                .map(\.rawValue)
                                .filter { slots.contains($0) }
                        }
                    ))
                }
            }
            .disabled(!settings.foliaEnabled)

            Section("存储") {
                NavigationLink(value: SettingsPage.storage) {
                    Label("存储空间", systemImage: "internaldrive")
                }
            }

            #if os(macOS)
            Section("通用") {
                Toggle("在菜单栏显示", isOn: $showMenuBarPlayer)
                NavigationLink(value: SettingsPage.shortcuts) {
                    Label("快捷键", systemImage: "keyboard")
                }
            }
            #endif

            SyncSettingsSection()

            Section("账号") {
                if let profile = account.profile {
                    LabeledContent("当前账号", value: profile.nickname)
                    Button("退出登录", role: .destructive) {
                        Task {
                            do { try await AccountStore.shared.logout() }
                            catch { ToastCenter.shared.show(error.localizedDescription) }
                        }
                    }
                } else {
                    Text("未登录")
                        .foregroundStyle(.secondary)
                }
            }

            if showsUpdateControls {
                Section("更新") {
                    Toggle("启动时自动检查更新", isOn: $settings.autoCheckUpdates)
                    Text("关闭后启动不再自动弹出更新提示，仍可手动检查更新")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #if os(iOS)
                    if DistributionChannel.current == .sideload {
                        Button {
                            IOSUpdater.shared.check(interactive: true)
                        } label: {
                            Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                        }
                        Text("装有 TrollStore（巨魔）可在应用内一键自动安装；否则可下载 IPA 用侧载工具重装（登录状态与设置保留）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    #endif
                }
            }

            Section {
                VStack(spacing: 2) {
                    Text("Rumxs")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(appVersionAndBuild)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
                .padding(.bottom, 32)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(appVersionAccessibilityLabel)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .formStyle(.grouped)
        .navigationDestination(for: SettingsPage.self) { page in
            Group {
                switch page {
                case .storage:
                    StorageSpaceView {
                        #if os(iOS)
                        dismiss()
                        #endif
                        openDestination(.downloaded)
                    }
                #if os(macOS)
                case .shortcuts:
                    ShortcutSettingsView()
                #endif
                case .themePark:
                    ThemeParkView()
                }
            }
            #if os(macOS)
            .navigationBarBackButtonHidden()
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    switch page {
                    case .storage: Text("存储空间").font(.headline)
                    case .themePark: Text("主题乐园").font(.headline)
                    case .shortcuts: Text("快捷键").font(.headline)
                    }
                }
            }
            #endif
        }
    }

    /// Sparkle on macOS; on iOS only sideload builds carry an updater.
    private var showsUpdateControls: Bool {
        #if os(iOS)
        return DistributionChannel.current.allowsSelfUpdate
        #else
        return true
        #endif
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private var appBuild: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    /// "0.1.0 (2)": version, then build in brackets, both read from the bundle.
    private var appVersionAndBuild: String {
        guard let build = appBuild, !build.isEmpty else { return appVersion }
        return "\(appVersion) (\(build))"
    }

    private var appVersionAccessibilityLabel: String {
        if let build = appBuild, !build.isEmpty {
            return "Rumxs, version \(appVersion), build \(build)"
        }
        return "Rumxs, version \(appVersion)"
    }

}

#if os(macOS)
private struct SettingsToastOverlay: View {
    @ObservedObject private var toasts = ToastCenter.shared

    var body: some View {
        Group {
            if let toast = toasts.current {
                ToastView(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 12)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.spring(duration: 0.3), value: toasts.current)
        .allowsHitTesting(false)
    }
}

/// Keep navigation and the title in the native, compact titlebar toolbar.
/// Settings scenes retain their view state when closed, so reset the path here.
struct SettingsWindowToolbar: NSViewRepresentable {
    let onClose: () -> Void

    func makeNSView(context: Context) -> ToolbarHost {
        let view = ToolbarHost()
        view.onClose = onClose
        return view
    }

    func updateNSView(_ nsView: ToolbarHost, context: Context) {
        nsView.onClose = onClose
        nsView.updateToolbar()
    }

    final class ToolbarHost: NSView {
        var onClose: () -> Void = {}
        private var closeObserver: AnyCancellable?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            closeObserver = window.map { window in
                NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
                    .sink { [weak self] _ in self?.onClose() }
            }
            updateToolbar()
        }

        func updateToolbar() {
            guard let window, window.toolbarStyle != .unifiedCompact else { return }
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window, window.toolbarStyle != .unifiedCompact else { return }
                window.toolbarStyle = .unifiedCompact
            }
        }
    }
}
#endif
