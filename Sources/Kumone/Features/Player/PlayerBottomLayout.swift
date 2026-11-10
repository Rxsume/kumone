import SwiftUI

// MARK: - 播放页底部布局自由拖动 (Folia)
//
// Beans 的拖动编辑器 (Beans/PlayerLayout.swift + PlayerView.swift 的
// `layoutMode`) 的 Golia 版，只做用户点名的底部两件：进度条、控制按钮。
// Beans 有 20 个可调部件 (含旋转/透明度)；这里只做 XY + 缩放。
//
// 指示线不在内：Golia 播放页没有底部指示线，唯一的指示线是页面顶部
// 的下拉关闭手柄 (NowPlayingPresentation.dragIndicator)，动它会破坏
// 下拉关闭，所以不进编辑器。
//
// 存储：UserDefaults JSON (`settings.folia.playerBottomLayoutData`)，
// 防抖 0.12 秒保存，重启后保留；默认值全是 identity，现有外观不变。

/// 底部可自由调整的部件。
enum PlayerBottomLayoutPart: String, CaseIterable, Identifiable {
    case progress
    case controls

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .progress: return String(localized: "进度条")
        case .controls: return String(localized: "控制按钮")
        }
    }
}

/// 单个部件的自定义位置 (相对默认位置的偏移) 与缩放。
struct PlayerBottomLayoutEntry: Codable, Equatable {
    var x: CGFloat = 0
    var y: CGFloat = 0
    /// 部件大小缩放 (1 为原始大小)。
    var scale: CGFloat = 1

    init(x: CGFloat = 0, y: CGFloat = 0, scale: CGFloat = 1) {
        self.x = x
        self.y = y
        self.scale = scale
    }

    /// 兼容旧存档 (老版本没有新增字段时使用默认值)。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decodeIfPresent(CGFloat.self, forKey: .x) ?? 0
        y = try container.decodeIfPresent(CGFloat.self, forKey: .y) ?? 0
        scale = try container.decodeIfPresent(CGFloat.self, forKey: .scale) ?? 1
    }
}

/// 播放页底部布局调整存储 (UserDefaults JSON，持久化)。
enum PlayerBottomLayoutStore {
    static let dataKey = "settings.folia.playerBottomLayoutData"
    private static var pendingSave: DispatchWorkItem?

    static let xRange: ClosedRange<CGFloat> = -140 ... 140
    static let yRange: ClosedRange<CGFloat> = -300 ... 300
    static let scaleRange: ClosedRange<CGFloat> = 0.5 ... 1.5

    static func load() -> [String: PlayerBottomLayoutEntry] {
        guard let raw = UserDefaults.standard.string(forKey: dataKey),
              let data = raw.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: PlayerBottomLayoutEntry].self, from: data) else {
            return [:]
        }
        return dict
    }

    static func save(_ dict: [String: PlayerBottomLayoutEntry]) {
        pendingSave?.cancel()
        let snapshot = dict
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(snapshot),
                  let raw = String(data: data, encoding: .utf8) else { return }
            UserDefaults.standard.set(raw, forKey: dataKey)
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    static func saveImmediately(_ dict: [String: PlayerBottomLayoutEntry]) {
        pendingSave?.cancel()
        if let data = try? JSONEncoder().encode(dict),
           let raw = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(raw, forKey: dataKey)
        }
    }

    static func reset() {
        pendingSave?.cancel()
        UserDefaults.standard.removeObject(forKey: dataKey)
    }

    /// 各部件默认位置 / 大小：identity，现有外观不变。
    static func defaultEntry(for part: PlayerBottomLayoutPart) -> PlayerBottomLayoutEntry {
        PlayerBottomLayoutEntry()
    }

    /// 显示时钳制，避免拖出屏幕或缩到不可见。
    static func clamped(_ entry: PlayerBottomLayoutEntry) -> PlayerBottomLayoutEntry {
        PlayerBottomLayoutEntry(
            x: min(max(entry.x, xRange.lowerBound), xRange.upperBound),
            y: min(max(entry.y, yRange.lowerBound), yRange.upperBound),
            scale: min(max(entry.scale, scaleRange.lowerBound), scaleRange.upperBound)
        )
    }
}

/// 底部布局的实时数据源：播放页和编辑器共用同一个实例，编辑器里的
/// 改动立即反映到播放页上。
@MainActor
final class PlayerBottomLayoutModel: ObservableObject {
    static let shared = PlayerBottomLayoutModel()

    @Published private(set) var entries: [String: PlayerBottomLayoutEntry] = PlayerBottomLayoutStore.load()

    private init() {}

    func entry(for part: PlayerBottomLayoutPart) -> PlayerBottomLayoutEntry {
        entries[part.rawValue] ?? PlayerBottomLayoutStore.defaultEntry(for: part)
    }

    func set(_ entry: PlayerBottomLayoutEntry, for part: PlayerBottomLayoutPart) {
        entries[part.rawValue] = PlayerBottomLayoutStore.clamped(entry)
        PlayerBottomLayoutStore.save(entries)
    }

    func reset(_ part: PlayerBottomLayoutPart) {
        entries[part.rawValue] = nil
        PlayerBottomLayoutStore.save(entries)
    }

    func resetAll() {
        entries = [:]
        PlayerBottomLayoutStore.reset()
    }
}

/// 应用自定义位置与缩放。只在 iOS 上生效：编辑器是 iOS 入口，macOS
/// 的播放页底部保持原样，不受备份里带过来的值影响。
struct PlayerBottomLayoutTransform: ViewModifier {
    let part: PlayerBottomLayoutPart
    let entry: PlayerBottomLayoutEntry

    func body(content: Content) -> some View {
        #if os(iOS)
        let display = PlayerBottomLayoutStore.clamped(entry)
        content
            .scaleEffect(display.scale)
            .offset(x: display.x, y: display.y)
        #else
        content
        #endif
    }
}

#if os(iOS)
/// 底部布局编辑器：悬浮窗实时预览 + 滑杆微调 + 一键恢复默认。
/// 从设置页 Folia 分区进入。预览里是真实的进度条与控制按钮行
/// (跟随真实播放进度)，不是占位图；预览里的拖动只在预览内实时
/// 生效，松手后写入存储，播放页随之更新。
struct PlayerBottomLayoutEditor: View {
    @ObservedObject private var model = PlayerBottomLayoutModel.shared
    @State private var selectedPart: PlayerBottomLayoutPart = .progress
    @GestureState private var dragTranslation = CGSize.zero
    @GestureState private var pinchScale: CGFloat = 1
    @State private var draggingPart: PlayerBottomLayoutPart?
    @State private var pinchingPart: PlayerBottomLayoutPart?

    var body: some View {
        Form {
            Section {
                previewCard
                Text("在预览里直接拖动进度条或控制按钮移动位置，双指捏合缩放；也可以用下面的滑杆微调。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("实时预览")
            }

            Section {
                Picker("部件", selection: $selectedPart) {
                    ForEach(PlayerBottomLayoutPart.allCases) { part in
                        Text(part.displayName).tag(part)
                    }
                }
                .pickerStyle(.segmented)
                layoutSlider("X", value: selectedEntry.x, range: PlayerBottomLayoutStore.xRange)
                layoutSlider("Y", value: selectedEntry.y, range: PlayerBottomLayoutStore.yRange)
                layoutSlider("大小", value: selectedEntry.scale, range: PlayerBottomLayoutStore.scaleRange, step: 0.05, format: "%.2f")
                HStack {
                    Button {
                        model.reset(selectedPart)
                    } label: {
                        Label("恢复当前部件默认", systemImage: "arrow.counterclockwise")
                    }
                    Spacer()
                    Button("全部恢复默认", role: .destructive) {
                        model.resetAll()
                    }
                }
            } header: {
                Text(selectedPart.displayName)
            }

            Section {
                Text("调整实时保存，返回播放页即可看到；重启后保留。播放页顶部的指示线是下拉关闭手柄，不参与布局调整。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(String(localized: "底部布局"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 选中部件的绑定 (滑杆读写，实时保存)。
    private var selectedEntry: Binding<PlayerBottomLayoutEntry> {
        Binding(
            get: { model.entry(for: selectedPart) },
            set: { model.set($0, for: selectedPart) }
        )
    }

    /// 悬浮窗预览：深色底 + 真实进度条与控制按钮行。
    private var previewCard: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.12), Color(white: 0.02)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(spacing: 17) {
                previewPart(.progress) {
                    NowPlayingScrubber(accent: Theme.accent)
                        .allowsHitTesting(false)
                }
                previewPart(.controls) {
                    CompactTransportControls()
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .environmentObject(PlayerService.shared)
        .environmentObject(SettingsManager.shared)
    }

    /// 预览里的一个部件：应用布局变换，支持直接拖动 (XY) 与捏合 (缩放)。
    private func previewPart<Content: View>(
        _ part: PlayerBottomLayoutPart,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let base = model.entry(for: part)
        let live = PlayerBottomLayoutEntry(
            x: base.x + (draggingPart == part ? dragTranslation.width : 0),
            y: base.y + (draggingPart == part ? dragTranslation.height : 0),
            scale: base.scale * (pinchingPart == part ? pinchScale : 1)
        )
        return content()
            .contentShape(Rectangle())
            .modifier(PlayerBottomLayoutTransform(part: part, entry: live))
            .overlay {
                if selectedPart == part {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 1)
                        .padding(-6)
                }
            }
            .gesture(
                DragGesture()
                    .updating($dragTranslation) { value, state, _ in
                        state = value.translation
                    }
                    .onChanged { _ in
                        draggingPart = part
                    }
                    .onEnded { value in
                        draggingPart = nil
                        let current = model.entry(for: part)
                        model.set(
                            PlayerBottomLayoutEntry(
                                x: current.x + value.translation.width,
                                y: current.y + value.translation.height,
                                scale: current.scale
                            ),
                            for: part
                        )
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .updating($pinchScale) { value, state, _ in
                        state = value
                    }
                    .onChanged { _ in
                        pinchingPart = part
                    }
                    .onEnded { value in
                        pinchingPart = nil
                        let current = model.entry(for: part)
                        model.set(
                            PlayerBottomLayoutEntry(x: current.x, y: current.y, scale: current.scale * value),
                            for: part
                        )
                    }
            )
            .onTapGesture {
                selectedPart = part
            }
    }

    private func layoutSlider(
        _ title: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        step: CGFloat = 1,
        format: String = "%.0f"
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue, specifier: format)")
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }
}
#endif
