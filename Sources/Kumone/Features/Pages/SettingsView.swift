import SwiftUI
#if os(macOS)
import Combine
#endif

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var account: AccountStore
    @Environment(\.openDestination) private var openDestination
    @Environment(\.dismiss) private var dismiss
    @State private var showAccountHub = false
    @State private var showCustomSources = false
    // Beans 主题/平台组的可展开状态（默认收起，与 Beans 一致）。
    @State private var themeExpanded = false
    @State private var platformExpanded = false
    @ObservedObject private var customSources = CustomAudioSourceStore.shared
    #if os(macOS)
    @AppStorage(SettingsManager.Keys.menuBarPlayer) private var showMenuBarPlayer = false
    @State private var navigationPath: [SettingsPage] = []
    #endif

    private enum SettingsPage: Hashable {
        case storage
        case lyricStyle
        case lyricFilter
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
            Section("账号") {
                // All platform accounts live in AccountHubSheet now (the
                // single account entry point); this section only links to
                // it. The Bilibili workstream adds its hub row on rebase;
                // SettingsView no longer opens LoginSheet directly.
                // 听歌打卡已随设置页删除（P3：Beans 无等价物，用户未把
                // 它放进保留项；打卡的上报函数与开关 key 一并删除）。
                Button {
                    showAccountHub = true
                } label: {
                    HStack {
                        Text("账号登录")
                        Spacer()
                        Text(accountSummary)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // Beans 主题模式组（`ProfileView.themeSection`）：可展开的
            // 主题行；展开后是主题模式分段选择器。Beans 的其余三行无
            // Golia 等价物，不加死开关：沉浸详情界面是 Beans 的详情
            // 页头功能、语言需要整套本地化基建、关闭液态模式需要一
            // 个液态玻璃总闸——三者都不是 Golia 的 `staticMode`，
            // 不得与之合并；深层外观定制（漂浮特效/壁纸/字体等）是
            // 后续 P3 子项。
            Section {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        themeExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "paintpalette.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 28)
                        Text("主题模式")
                        Spacer()
                        Image(systemName: themeExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if themeExpanded {
                    Picker("主题模式", selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.displayName).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            // Beans 平台显示组（`ProfileView.platformSection`）：可展开
            // 的平台行；展开后是各平台显示/隐藏开关，只控制首页切换
            // 器的入口可见性，不动音源开关与平台能力。
            Section {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        platformExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "checklist")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 28)
                        Text("平台显示")
                        Spacer()
                        Image(systemName: platformExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if platformExpanded {
                    PlatformPreferencePicker()
                        .padding(.bottom, 6)
                }
            }

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
                    // D7: these playback behaviours only exist in the iOS
                    // player engine (PlayerServiceIOS); on macOS the rows
                    // would be dead switches.
                    #if os(iOS)
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
                    #endif
                    #if os(iOS)
                    Toggle("播放时防息屏", isOn: $settings.preventDisplaySleepDuringPlayback)
                    Text("播放期间屏幕不自动息屏，暂停或切到后台后恢复")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    ForEach(AudioSourceID.displayOrder, id: \.self) { source in
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
                    Button {
                        showCustomSources = true
                    } label: {
                        HStack {
                            Text("自定义音源")
                            Spacer()
                            Text("\(customSources.sources.count) 个")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .sheet(isPresented: $showCustomSources) {
                        CustomAudioSourcesView()
                    }
                } header: {
                    Text("音源")
                }
            }

            Section("外观") {
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
                    // `.lattice` and `.luminous` are Folia modes: they are
                    // not offered while the master switch is off (the
                    // dispatch falls back to the pre-folia default then).
                    ForEach(NowPlayingMode.allCases.filter { settings.foliaEnabled || ($0 != .lattice && $0 != .luminous) }) { mode in
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
                // Folia 歌词多源 (restored): auto-best search across
                // NetEase / AMLL / QQ / Kugou, the preferred-source
                // tie-break, and the global timeline offset. The lyric
                // filter rows below belong to the same delimited section
                // — re-home into the new settings page with the rest of
                // the lyric rows when the Beans settings replacement
                // lands.
                Toggle("自动使用最佳歌词", isOn: $settings.autoUseBestLyric)
                Text("自动检索网易云、AMLLDB、QQ 和酷狗歌词，若存在完美匹配的逐字歌词则自动优先采用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("歌词匹配优先级", selection: $settings.preferredLyricSource) {
                    ForEach(LyricSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                Text("在多个歌词源都存在高置信度匹配时，优先选择该歌词源的结果")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("全局时间偏移")
                    Spacer()
                    Text("\(settings.globalLyricTimelineOffsetMs)ms")
                        .foregroundStyle(.secondary)
                    Stepper("", value: $settings.globalLyricTimelineOffsetMs, in: -2000...2000, step: 50)
                        .labelsHidden()
                }
                Text("为本设备的所有歌曲整体平移歌词时间轴，补偿蓝牙等输出延迟")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Folia 歌词过滤 (lyricLineRules + staff-credits policy):
                // per-line rules live on their own page; the staff policy
                // lives here. Same delimited section as the multi-source
                // rows above — re-home together when the Beans settings
                // replacement lands.
                NavigationLink(value: SettingsPage.lyricFilter) {
                    Label("歌词过滤", systemImage: "line.3.horizontal.decrease.circle")
                }
                Text("按规则删掉指定歌词行，并处理开头的制作人员信息")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("制作人员信息", selection: $settings.lyricStaffPolicy) {
                    ForEach(LyricStaffPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                Text("歌词开头的作词、作曲等署名行：保留、智能处理或整块隐藏")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.lyricStaffPolicy != .keep {
                    HStack {
                        Text("每行最少停留")
                        Spacer()
                        Text("\(settings.lyricStaffMinDwellSeconds, specifier: "%.1f")秒")
                            .foregroundStyle(.secondary)
                        Stepper("", value: $settings.lyricStaffMinDwellSeconds, in: 0.6...4, step: 0.1)
                            .labelsHidden()
                    }
                    Text("智能模式按这个时间算前奏放不放得下整块署名")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("吸收相邻行", selection: $settings.lyricStaffAbsorbMode) {
                        ForEach(LyricStaffAbsorbMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Text("把署名块前后耗时过短的行并进块里一起处理")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("自定义识别正则（留空用内置词表）", text: $settings.lyricStaffPattern)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    if let error = LyricStaffCredits.patternError(settings.lyricStaffPattern) {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
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
                    NavigationLink(value: SettingsPage.lyricStyle) {
                        Label("歌词样式", systemImage: "textformat")
                    }
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
                    // D6: native blur only backs the iOS karaoke backdrop
                    // and the iOS volume popover; on macOS the toggle would
                    // be a dead switch.
                    #if os(iOS)
                    Toggle("播放页原生模糊", isOn: $settings.playerPageNativeBlur)
                    #endif
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
                    // D7: the entry view is only honoured by the iOS
                    // player engine (PlayerServiceIOS).
                    #if os(iOS)
                    Picker("播放时打开", selection: $settings.playbackEntryView) {
                        ForEach(PlaybackEntryView.allCases) { entry in
                            Text(entry.displayName).tag(entry)
                        }
                    }
                    Text("点播开始播放时打开播放页，还是留在当前页")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #endif
                }.disabled(!settings.foliaEnabled)
            }

            Section("播放页") {
                Toggle("隐藏进度条", isOn: $settings.hidePlayerProgressBar)
                Text("iOS 可用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // D8: the back button is only gated by this setting on
                // iOS; the macOS page always shows its own collapse button.
                #if os(iOS)
                Toggle("始终显示返回按钮", isOn: $settings.alwaysShowPlayerBackButton)
                Text("iOS 可用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
                Toggle("始终显示切歌按钮", isOn: $settings.alwaysShowTrackSwitchButtons)
                Text("只在 FM 模式下显示切歌按钮")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("浮动歌曲卡片", isOn: $settings.stageTrackCardEnabled)
                Text("iOS 可用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("过渡动画-屏幕圆环", isOn: $settings.transitionAnimationRing)
                Text("需先打开「切歌淡入淡出」，只在切歌过渡时出现")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("过渡动画-卡片描边", isOn: $settings.transitionAnimationCard)
                Text("需先打开「切歌淡入淡出」，只在切歌过渡时出现")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Text("Golia")
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
        .sheet(isPresented: $showAccountHub) { AccountHubSheet() }
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
                case .lyricStyle:
                    LyricStyleSettingsView()
                case .lyricFilter:
                    LyricFilterSettingsView()
                }
            }
            #if os(macOS)
            .navigationBarBackButtonHidden()
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    switch page {
                    case .storage: Text("存储空间").font(.headline)
                    case .lyricStyle: Text("歌词样式").font(.headline)
                    case .lyricFilter: Text("歌词过滤").font(.headline)
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

    /// NetEase nickname on the hub entry row (the hub itself shows all
    /// three platforms' states); "未登录" when NetEase is logged out.
    private var accountSummary: String {
        account.profile?.nickname ?? "未登录"
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
            return "Golia, version \(appVersion), build \(build)"
        }
        return "Golia, version \(appVersion)"
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
