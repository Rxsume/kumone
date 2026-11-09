import SwiftUI
import UniformTypeIdentifiers
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
    @State private var playbackExpanded = false
    // P3 3/3 深层外观：壁纸选择器、字体导入器、壁纸作用的外观。
    #if os(iOS)
    @State private var showWallpaperPicker = false
    @State private var wallpaperAppearanceTarget = WallpaperAppearanceTarget.light
    #endif
    @State private var showFontImporter = false
    @State private var installedFontName = FontManager.installedFontName
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

            // Beans 主题模式组（`ProfileView.themeSection` + 深层外观
            // `appearanceSection`，P3 1/3 + 3/3）：可展开的主题行；
            // 展开后是主题模式分段选择器与深层外观定制（强调色、
            // 底栏文字、悬浮底栏几何、主页背景/壁纸、全局字体）。
            // Beans 其余行无 Golia 等价物，不加死开关：沉浸详情界面
            // 是 Beans 的详情页头功能、语言需要整套本地化基建、关
            // 闭液态模式需要一个液态玻璃总闸——三者都不是 Golia 的
            // `staticMode`，不得与之合并；全局 UI 样式是 Beans 玻璃
            // 容器风格（Golia 的玻璃样式按系统版本固定在 compatGlass
            // 里）；注释/主文字颜色是 Beans 的全局文字色（Golia 用
            // 系统语义色，没有单一改写点）；问候定制在 Beans 里已是
            // 死代码（`if false`）；隐藏用户名/排序按钮/平台列表/
            // 刷新按钮/VIP 图标在 Golia 首页都没有对应 UI（首页没有
            // 用户名、排序与刷新按钮，平台切换器是唯一的切换入口，
            // 歌曲行不画 VIP 徽标）。
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

                    Divider()

                    // 自定义强调色：写 `settings.customAccentHex`，
                    // `Theme.accent` / `accentDeep` / `accentGradient`
                    // 直接读这个 key，全 App 即时换色。
                    HStack {
                        Text("自定义强调色")
                        Spacer()
                        ColorPicker("", selection: Binding(
                            get: { Color(hex: settings.customAccentHex) ?? Theme.accent },
                            set: { settings.customAccentHex = $0.rgbHexString }
                        ))
                        .labelsHidden()
                    }
                    HStack {
                        Button("恢复预设") {
                            settings.customAccentHex = ""
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        Spacer()
                        Text(settings.customAccentHex.isEmpty ? "使用预设主题" : "已自定义")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    #if os(iOS)
                    Divider()

                    Toggle("底栏显示文字", isOn: $settings.tabLabelsVisible)
                    Text("关闭后悬浮底栏只显示图标")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()

                    // 悬浮底栏几何：Beans 的“低系统悬浮底栏”滑杆，
                    // 作用于 Golia 的 GlassTabBar（它在所有 iOS 版本
                    // 都是悬浮底栏；Beans 只在 iOS 26 以下用自己的悬
                    // 浮底栏，所以那边加了 `#unavailable(iOS 26)` 门，
                    // Golia 不加）。
                    HStack {
                        Text("悬浮底栏")
                            .font(.headline)
                        Spacer()
                        Button("默认") {
                            settings.legacyTabBarCornerRadius = 32
                            settings.legacyTabBarWidth = 420
                            settings.legacyTabBarOffsetX = 0
                            settings.legacyTabBarOffsetY = 0
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                    }
                    appearanceSlider(
                        title: "圆润度",
                        valueText: "\(Int(settings.legacyTabBarCornerRadius))",
                        value: $settings.legacyTabBarCornerRadius,
                        range: SettingsManager.legacyTabBarCornerRadiusRange
                    )
                    appearanceSlider(
                        title: "长度",
                        valueText: "\(Int(settings.legacyTabBarWidth))",
                        value: $settings.legacyTabBarWidth,
                        range: SettingsManager.legacyTabBarWidthRange
                    )
                    appearanceSlider(
                        title: "X 位置",
                        valueText: signedIntText(settings.legacyTabBarOffsetX),
                        value: $settings.legacyTabBarOffsetX,
                        range: SettingsManager.legacyTabBarOffsetXRange
                    )
                    appearanceSlider(
                        title: "Y 位置",
                        valueText: signedIntText(settings.legacyTabBarOffsetY),
                        value: $settings.legacyTabBarOffsetY,
                        range: SettingsManager.legacyTabBarOffsetYRange
                    )

                    Divider()

                    // 主页背景：背景模式（浅色/深色）+ 背景颜色 +
                    // 上传壁纸 + 壁纸库 + 模糊度。壁纸只作用于首页
                    // 之外的页面时看“同步”开关。
                    Picker("背景模式", selection: $wallpaperAppearanceTarget) {
                        ForEach(WallpaperAppearanceTarget.allCases) { target in
                            Text(target.rawValue).tag(target)
                        }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("背景颜色")
                        Spacer()
                        ColorPicker("", selection: Binding(
                            get: { wallpaperBackgroundColor },
                            set: { setWallpaperBackgroundColor($0) }
                        ))
                        .labelsHidden()
                    }
                    HStack {
                        Button {
                            showWallpaperPicker = true
                        } label: {
                            HStack {
                                Text("上传壁纸（可多张）")
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if !settings.wallpaperPaths.isEmpty {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                            spacing: 10
                        ) {
                            ForEach(settings.wallpaperPaths, id: \.self) { path in
                                wallpaperCell(path: path)
                            }
                        }
                    } else {
                        Text("还没有壁纸，上传后会显示在这里")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        if !wallpaperActiveImagePath.isEmpty {
                            Button("清除当前背景") {
                                clearWallpaperBackgroundImage()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                        Spacer()
                        Text(wallpaperActiveImagePath.isEmpty ? "当前：默认背景" : "当前：已应用壁纸")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("同步到搜索 / 音乐库 / 我的", isOn: $settings.backgroundSyncAll)
                    HStack {
                        Button("恢复默认背景") {
                            settings.backgroundHexLight = ""
                            settings.backgroundHexDark = ""
                            settings.backgroundImagePathLight = ""
                            settings.backgroundImagePathDark = ""
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        Spacer()
                    }
                    HStack {
                        Text("主页壁纸模糊度")
                        Spacer()
                        Text("\(Int(settings.homeWallpaperBlur))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.homeWallpaperBlur, in: 0...30, step: 1)
                        .tint(Theme.accent)
                    #endif

                    Divider()

                    // 全局字体：上传 ttf/otf 安装并注册（`FontManager`），
                    // 恢复默认清除。已安装字体会出现在歌词字体选择器
                    // （系统字体选择器列出已注册字体）里；Golia 没有
                    // Beans 那种全 App 字体入口（`BeansFont.appFont`），
                    // 全 App 换字要另立项逐处接线，这里只做安装/注册。
                    HStack {
                        Text("全局字体")
                        Spacer()
                        Text(installedFontName ?? "系统默认")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("上传字体") {
                            showFontImporter = true
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        Button("恢复默认字体") {
                            FontManager.clear()
                            installedFontName = nil
                            ToastCenter.shared.show("已恢复系统默认字体")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        Spacer()
                    }
                }
            }
            .fileImporter(
                isPresented: $showFontImporter,
                allowedContentTypes: [.font]
            ) { result in
                importFontFile(result)
            }
            #if os(iOS)
            .sheet(isPresented: $showWallpaperPicker) {
                WallpaperPhotoPicker { data in
                    if let path = WallpaperStore.addWallpaper(data: data) {
                        settings.wallpaperPaths.append(path)
                    }
                }
            }
            #endif

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
            // （Golia 无触感基建，加开关会是死开关）。被取代的 Golia
            // 旧行（音质 Picker、灰色歌曲解锁、淡入淡出、加歌默认行
            // 为、自动跳过、防息屏、ReplayGain、音源开关、AutoMix）随
            // 旧节删除——key 仍在 SettingsManager 里，引擎继续按已存
            // 值工作，平台切换器仍自动开对应音源。
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
                            PlaybackEngine.applyAudioSessionCategory()
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
                    Toggle("第三方播放会员歌提醒", isOn: $settings.showThirdPartySourceNotice)
                    Text("第三方音源播出会员歌曲时弹出提醒")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    // MARK: - P3 3/3 深层外观 helpers

    /// "+12" / "-5" / "0" for the floating tab bar offset sliders
    /// (Beans' `signedIntText`).
    private func signedIntText(_ value: Double) -> String {
        let intValue = Int(value.rounded())
        if intValue == 0 { return "0" }
        return intValue > 0 ? "+\(intValue)" : "\(intValue)"
    }

    /// Label + value + slider row (Beans' `settingsSlider`).
    private func appearanceSlider(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: 1)
                .tint(Theme.accent)
        }
    }

    #if os(iOS)
    /// Stored background colour for the selected appearance target,
    /// as a `Color` for the picker (unset reads as the system
    /// background, like Beans' fallback to its default background).
    private var wallpaperBackgroundColor: Color {
        let hex = wallpaperAppearanceTarget == .light
            ? settings.backgroundHexLight : settings.backgroundHexDark
        return Color(hex: hex) ?? Color(UIColor.systemBackground)
    }

    private func setWallpaperBackgroundColor(_ color: Color) {
        let hex = color.rgbHexString
        if wallpaperAppearanceTarget == .light {
            settings.backgroundHexLight = hex
        } else {
            settings.backgroundHexDark = hex
        }
    }

    /// Active wallpaper path for the selected appearance target.
    private var wallpaperActiveImagePath: String {
        wallpaperAppearanceTarget == .light
            ? settings.backgroundImagePathLight : settings.backgroundImagePathDark
    }

    private func clearWallpaperBackgroundImage() {
        if wallpaperAppearanceTarget == .light {
            settings.backgroundImagePathLight = ""
        } else {
            settings.backgroundImagePathDark = ""
        }
    }

    /// Wallpaper library cell (Beans' `wallpaperCell`): tap applies
    /// the wallpaper to the selected appearance; the active one gets
    /// an accent border + checkmark; the × button deletes the file
    /// and drops it from the library (and from the active slot if it
    /// was active).
    private func wallpaperCell(path: String) -> some View {
        let isActive = path == wallpaperActiveImagePath
        return ZStack(alignment: .topTrailing) {
            Button {
                if wallpaperAppearanceTarget == .light {
                    settings.backgroundImagePathLight = path
                } else {
                    settings.backgroundImagePathDark = path
                }
            } label: {
                Group {
                    if let img = WallpaperStore.image(at: path) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.secondary.opacity(0.2)
                    }
                }
                .frame(height: 108)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isActive ? Theme.accent : Color.clear, lineWidth: 2)
                }
                .overlay(alignment: .bottomTrailing) {
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.accent)
                            .background { Circle().fill(Color(UIColor.systemBackground)) }
                            .padding(5)
                    }
                }
            }
            .buttonStyle(.plain)

            Button {
                WallpaperStore.deleteWallpaper(at: path)
                settings.wallpaperPaths.removeAll { $0 == path }
                if settings.backgroundImagePathLight == path {
                    settings.backgroundImagePathLight = ""
                }
                if settings.backgroundImagePathDark == path {
                    settings.backgroundImagePathDark = ""
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background { Circle().fill(Color(UIColor.systemBackground)) }
                    .clipShape(Circle())
                    .contentShape(Circle())
                    .padding(6)
            }
            .buttonStyle(.plain)
            .zIndex(2)
        }
    }
    #endif

    /// Install a user-picked font file (`.fileImporter` hands over a
    /// security-scoped URL, same pattern as the custom-source
    /// importer). Shows the installed name or a failure toast.
    private func importFontFile(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            ToastCenter.shared.show("字体导入失败：\(error.localizedDescription)")
        case .success(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard url.pathExtension.lowercased() == "ttf"
                    || url.pathExtension.lowercased() == "otf"
                    || url.pathExtension.lowercased() == "ttc"
            else {
                ToastCenter.shared.show("请选择 ttf / otf 字体文件")
                return
            }
            if let name = FontManager.install(from: url) {
                installedFontName = name
                ToastCenter.shared.show("字体已应用：\(name)")
            } else {
                ToastCenter.shared.show("字体安装失败，请使用 ttf / otf 文件")
            }
        }
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
