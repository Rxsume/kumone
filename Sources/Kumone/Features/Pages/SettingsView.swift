import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import Combine
#endif

#if os(iOS)
/// The iOS Settings sheet: its navigation stack, title and 完成 button around
/// `SettingsView`. Present it from the app's root (`presentSettingsSheet`).
///
/// Presented from inside the Library tab, the sheet was re-hosted whenever
/// the tab view updated, so changing a setting from a pushed page (picking a
/// sound effect, say) reset the stack and popped the page back to the root.
/// It also keeps the stack apart from `SettingsView`, which re-renders on
/// every settings change.
struct SettingsSheet: View {
    var titleDisplayMode: NavigationBarItem.TitleDisplayMode = .automatic
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openDestination) private var openDestination
    @State private var path: [SettingsView.SettingsPage] = []

    var body: some View {
        NavigationStack(path: $path) {
            SettingsView()
                .navigationTitle("设置")
                .navigationBarTitleDisplayMode(titleDisplayMode)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
                .navigationDestination(for: SettingsView.SettingsPage.self) { page in
                    switch page {
                    case .storage:
                        StorageSpaceView {
                            dismiss()
                            openDestination(.downloaded)
                        }
                    case .soundEffects:
                        SoundEffectsPage()
                    case .lyricStyle:
                        LyricStyleSettingsView()
                    case .lyricFilter:
                        LyricFilterSettingsView()
                    case .themePark:
                        ThemeParkView()
                    }
                }
        }
    }
}
#endif

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsManager
    @EnvironmentObject private var account: AccountStore
    @Environment(\.openDestination) private var openDestination
    @State private var showAccountHub = false
    @State private var showCustomSources = false
    // Beans 平台/播放组的可展开状态（默认收起，与 Beans 一致）。
    @State private var platformExpanded = false
    @State private var playbackExpanded = false
    @State private var appearanceFoliaExpanded = false
    @ObservedObject private var customSources = CustomAudioSourceStore.shared
    #if os(macOS)
    @AppStorage(SettingsManager.Keys.menuBarPlayer) private var showMenuBarPlayer = false
    @State private var navigationPath: [SettingsPage] = []
    #endif

    fileprivate enum SettingsPage: Hashable {
        case storage
        case themePark
        #if os(iOS)
        case soundEffects
        #endif
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
        // Navigation lives in `SettingsSheet`, which observes no settings.
        settingsForm
        #endif
    }

    private var settingsForm: some View {
        Form {
            Section("账号") {
                // All platform accounts live in AccountHubSheet now (the
                // single account entry point); this section only links to
                // it. SettingsView no longer opens LoginSheet directly.
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

            // Beans 播放设置组（`ProfileView.playbackSection`，可展开；
            // 默认收起，与 Beans 一致）。行的取舍：播放音质 pill 选择
            // 器（写 `settings.audioQuality`，与 Beans 的五档一一对应）、
            // 第三方音源音质 pill 选择器（写进各自定义音源的 quality，
            // 解析仍读各源自己的 quality）、自定义音源管理行（Golia
            // 的 `CustomAudioSourcesView`，不换 Beans 的
            // `ThirdPartySourceManagerSheet`），及三项新开关（与其他音
            // 频同时播放、启动续播、第三方会员歌提醒）。未搬：120Hz 高
            // 刷新（Beans 里强制开启、无 Golia 等价物）、触感反馈
            // （Golia 无触感基建，加开关会是死开关）。Golia 旧行里
            // 的淡入淡出、加歌默认行为、自动跳过、防息屏、ReplayGain
            // 与切歌淡入淡出后来按照片恢复在下面（key 与引擎一直都
            // 在）；过渡模式 AutoMix 未恢复——它要双引擎过渡规划器，
            // 那套还删着，单加 Picker 会是死开关。
            Section {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        playbackExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 28)
                        Text("播放设置")
                        Spacer()
                        Image(systemName: playbackExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if playbackExpanded {
                    #if os(iOS)
                    Toggle("与其他音频同时播放", isOn: $settings.mixWithOtherAudio)
                        .onChange(of: settings.mixWithOtherAudio) { _ in
                            AudioSessionCategory.apply()
                        }
                    Text("播放时允许其他 App 的音频继续播放")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #endif
                    Toggle("启动时自动播放上次歌曲", isOn: $settings.autoResumeLastPlayback)
                    Text("打开软件后自动恢复上次未播放完的歌曲")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    QualityPillPicker(
                        title: "播放音质",
                        hint: "按列表选择，无法使用时会由平台自动降级。",
                        options: AudioQuality.allCases.map { (value: $0.rawValue, label: $0.displayName) },
                        selection: Binding(
                            get: { settings.audioQuality.rawValue },
                            set: { settings.audioQuality = AudioQuality(rawValue: $0) ?? .exhigh }
                        )
                    )
                    #if os(iOS)
                    NavigationLink(value: SettingsPage.soundEffects) {
                        HStack {
                            Text("音效")
                            Spacer()
                            Text(settings.soundEffectPreset.displayName)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityValue(settings.soundEffectPreset.displayName)
                    .accessibilityIdentifier("settingsSoundEffectsButton")
                    #endif
                    Toggle("第三方播放会员歌提醒", isOn: $settings.showThirdPartySourceNotice)
                    Text("第三方音源播出会员歌曲时弹出提醒")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // P6: 灰色歌曲解锁是第三方音源的总闸
                    // (`unblockEnabled = enableUnblock &&
                    // !enabledAudioSourceIDs.isEmpty`)，备份恢复也能把它
                    // 关掉；P3b 删了它的旧行后一旦关掉就再也打不开了，
                    // 所以它必须留一个可见开关，放在自定义音源行上面。
                    Toggle("灰色歌曲解锁", isOn: $settings.enableUnblock)
                    Text("无版权或下架歌曲将从已启用音源中匹配播放")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Group {
                        // Restored playback rows (the old Section("播放")
                        // rows deleted by the Beans playback-settings
                        // port, 10fd00a): the engines and keys survived,
                        // only the rows were gone. The 切歌淡入淡出 toggle
                        // below is the restored iosCrossfadeEnabled key,
                        // now driving a single-engine fade (no overlap).
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
                        Toggle("切歌淡入淡出", isOn: $settings.iosCrossfadeEnabled)
                        Text("切歌时先淡出再淡入，两首歌之间有短暂间隙；关闭后恢复原来的直接切歌")
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
                    QualityPillPicker(
                        title: "第三方音源音质",
                        hint: "会优先按所选音质解析第三方音源，不可用时会自动降级；写入全部已导入音源。",
                        options: CustomAudioSource.qualityOptions,
                        selection: thirdPartyQualitySelection
                    )
                    .disabled(customSources.sources.isEmpty)
                    if customSources.sources.isEmpty {
                        Text("导入自定义音源后可用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // 外观 + Folia 合并为一格可展开卡片（与「平台显示」/
            // 「播放设置」同一形式；默认收起）。行与 key 都不动，
            // 只把两个 Section 的内容收进展开区。
            Section {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        appearanceFoliaExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "paintpalette")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 28)
                        Text("外观 / Folia")
                        Spacer()
                        Image(systemName: appearanceFoliaExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if appearanceFoliaExpanded {
                    // Beans 外观行已移除（自定义强调色/底栏/壁纸/字体）；
                    // 只留 Golia 自带的主题切换。
                    Picker("主题模式", selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.displayName).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)

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
                        // Folia 歌词过滤 (lyricLineRules + staff-credits policy):
                        // per-line rules live on their own page; the staff policy
                        // lives here.
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
                        Picker("歌词动画样式", selection: $settings.lyricAnimationStyle) {
                            ForEach(LyricAnimationStyle.allCases) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        NavigationLink(value: SettingsPage.lyricStyle) {
                            Label("歌词样式", systemImage: "textformat")
                        }
                        Picker("配色主题预设", selection: $settings.themePresetID) {
                            Text("默认").tag("default")
                            Text("暮色").tag("dusk")
                            Text("海洋").tag("ocean")
                            Text("林深").tag("forest")
                            Text("玫瑰").tag("rose")
                            Text("自定义").tag("custom")
                        }
                        // The theme actually in effect (see `activeThemeCaption`):
                        // the preset picker alone cannot show it, because
                        // song-theme auto-switch short-circuits the preset and
                        // "custom" with no saved theme falls back to default.
                        Text(activeThemeCaption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        NavigationLink(value: SettingsPage.themePark) {
                            Label("主题乐园", systemImage: "paintpalette")
                        }
                        Toggle("歌曲主题自动切换", isOn: $settings.songThemeAutoSwitch)
                        Text("切歌时播放页与主界面跟随当前歌曲封面取色，关闭后使用默认配色")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Toggle("优先使用自定义主题", isOn: $settings.preferCustomTheme)
                    // Folia 歌词多源 (restored; re-homed here from
                    // PR #40的 section on the rebase over main
                    // 2ca91b8): auto-best search across NetEase /
                    // AMLL / QQ / Kugou, the preferred-source
                    // tie-break, and the global timeline offset.
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
                    Group {
                        Toggle("隐藏进度条", isOn: $settings.hidePlayerProgressBar)
                        Text("iOS 可用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Toggle("自动隐藏播放控件", isOn: $settings.autoHidePlayerChrome)
                        Text("3 秒无操作后隐藏进度条、播放按钮和顶部按钮，点一下屏幕即可恢复")
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
                        // P6: 旧文案“需先打开「切歌淡入淡出」”指向的过渡模式
                        // 选择器（AutoMixSettingsSection 的“过渡模式”）已不在
                        // 设置页里；iOS 上 `PlayerServiceIOS.transitionInProgress`
                        // 在 PR #36 单引擎回退后恒为 false，圆环目前只在 macOS
                        // 的 AutoMix 切歌过渡进行时出现。
                        Text("只在切歌过渡进行时短暂出现；iOS 单引擎播放时不产生过渡")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Toggle("过渡动画-卡片描边", isOn: $settings.transitionAnimationCard)
                        Text("只在切歌过渡进行时短暂出现；iOS 单引擎播放时不产生过渡")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }.disabled(!settings.foliaEnabled)
                    Group {
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
                    }.disabled(!settings.foliaEnabled)
                }
            }

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

            SettingsBackupSection()

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
        #if os(macOS)
        .navigationDestination(for: SettingsPage.self) { page in
            Group {
                switch page {
                case .storage:
                    StorageSpaceView {
                        openDestination(.downloaded)
                    }
                case .shortcuts:
                    ShortcutSettingsView()
                case .lyricStyle:
                    LyricStyleSettingsView()
                case .lyricFilter:
                    LyricFilterSettingsView()
                case .themePark:
                    ThemeParkView()
                }
            }
            .navigationBarBackButtonHidden()
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    switch page {
                    case .storage: Text("存储空间").font(.headline)
                    case .themePark: Text("主题乐园").font(.headline)
                    case .lyricStyle: Text("歌词样式").font(.headline)
                    case .lyricFilter: Text("歌词过滤").font(.headline)
                    case .shortcuts: Text("快捷键").font(.headline)
                    }
                }
            }
        }
        #endif
    }

    /// The theme actually in effect, by the same priority as
    /// `ThemePreset.resolvedTheme` (custom > song artwork > preset),
    /// resolved without an artwork palette — this page has none, so with
    /// song-theme auto-switch on the caption reads 跟随封面: the palette
    /// wins whenever a song with artwork is playing, and the preset below
    /// it is what shows while nothing is. Reads the effective values, so
    /// the caption stays true with the Folia master switch off too.
    private var activeThemeCaption: String {
        if ThemePreset.customTheme(from: settings) != nil,
           settings.effectivePreferCustomTheme || settings.effectiveThemePresetID == "custom" {
            return "当前：自定义"
        }
        if settings.effectiveSongThemeAutoSwitch {
            return "当前：跟随封面"
        }
        return "当前：\(ThemePreset.preset(id: settings.effectiveThemePresetID).displayName)"
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

    /// The global third-party quality picker: the first imported
    /// source's quality (the common one when all agree), "320k" when
    /// nothing is imported. Writing sets all sources' quality
    /// (`CustomAudioSourceStore.updateQualityForAll`); resolve keeps
    /// reading each source's own `quality`, so the per-source editor
    /// can still override afterwards.
    private var thirdPartyQualitySelection: Binding<String> {
        Binding(
            get: { customSources.sources.first?.quality ?? "320k" },
            set: { customSources.updateQualityForAll($0) }
        )
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

/// Horizontal pill picker for a quality setting (Beans
/// `playbackQualitySection` / `ThirdPartyAudioQuality`, adapted to
/// Golia's `Theme`).
private struct QualityPillPicker: View {
    let title: String
    let hint: String
    let options: [(value: String, label: String)]
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(options, id: \.value) { option in
                        Button {
                            selection = option.value
                        } label: {
                            HStack(spacing: 4) {
                                if selection == option.value {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                }
                                Text(option.label)
                                    .font(.subheadline)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(selection == option.value ? Theme.accent.opacity(0.15) : Color.secondary.opacity(0.12))
                            )
                            .foregroundStyle(selection == option.value ? Theme.accent : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
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
