import SwiftUI
import Combine

/// 用户选择需要在首页切换器里显示的平台。只控制入口可见性，不删除
/// 平台能力：搜索、播放、歌单仍按音源开关走（见 `HomeView.selectPlatform`
/// 的注释）。改编自 Beans 的 `PlatformPreferenceStore`（2.0.3）：Beans
/// 的店管五个 `SearchProvider`（含汽水/Bilibili）；Golia 的店只管三个
/// `HomePlatform`，键用 `settings.*` 命名空间，不用 `beans.*`。
///
/// Bilibili 衔接：店按 `HomePlatform.allCases` 归一化，未见过的 case
/// 默认启用，所以平行工作流加 `.bilibili` 时它自动出现在选择器里，
/// 不用再改这个文件；`HomeView` 的切换器与本店的 `orderedEnabledPlatforms`
/// 同步，Bilibili 行也随之出现。
@MainActor
final class PlatformPreferenceStore: ObservableObject {
    static let shared = PlatformPreferenceStore()

    private static let enabledKey = "settings.enabledHomePlatforms.v1"
    private static let orderKey = "settings.homePlatformOrder.v1"
    /// 见过的平台 rawValue。只凭 enabled 集分不清“用户关掉的”和
    /// “新加的”——新 case（不在 seen 里）默认启用，见过之后再关
    /// 就一直保持关着。
    private static let seenKey = "settings.homePlatformsSeen.v1"

    @Published private(set) var selectedRaw: Set<String>
    @Published var orderedRaw: [String]

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.enabledKey) ?? []
        let seen = Set(UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? [])
        let all = Set(HomePlatform.allCases.map(\.rawValue))
        var selected = saved.isEmpty ? all : Set(saved)
        // 新平台（平行工作流加的 case）第一次出现时默认启用。
        selected.formUnion(all.subtracting(seen))
        selectedRaw = selected
        orderedRaw = UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? []
        UserDefaults.standard.set(Array(all), forKey: Self.seenKey)
        normalize()
        normalizeOrder()
    }

    /// 切换器里实际显示的平台：按保存的顺序，只含已启用的；全关时
    /// 兜底回网易云，保证切换器永远不空。
    var orderedEnabledPlatforms: [HomePlatform] {
        let list = orderedPlatforms.filter { selectedRaw.contains($0.rawValue) }
        return list.isEmpty ? [.netease] : list
    }

    var orderedPlatforms: [HomePlatform] {
        orderedRaw.compactMap(HomePlatform.init(rawValue:))
    }

    func isEnabled(_ platform: HomePlatform) -> Bool {
        selectedRaw.contains(platform.rawValue)
    }

    func set(_ platform: HomePlatform, enabled: Bool) {
        if enabled {
            selectedRaw.insert(platform.rawValue)
        } else if selectedRaw.count > 1 {
            // 至少留一个启用平台，否则切换器无处可去。
            selectedRaw.remove(platform.rawValue)
        }
        normalize()
        save()
    }

    /// 当前平台被隐藏时回落到第一个可见平台；已可见时原样返回。
    func ensureVisible(_ platform: HomePlatform) -> HomePlatform {
        isEnabled(platform) ? platform : orderedEnabledPlatforms.first ?? .netease
    }

    func resetToDefault() {
        selectedRaw = Set(HomePlatform.allCases.map(\.rawValue))
        resetOrder()
        save()
    }

    func resetOrder() {
        orderedRaw = HomePlatform.allCases.map(\.rawValue)
        saveOrder()
        objectWillChange.send()
    }

    func movePlatforms(from offsets: IndexSet, to destination: Int) {
        orderedRaw.move(fromOffsets: offsets, toOffset: destination)
        normalizeOrder()
        saveOrder()
        objectWillChange.send()
    }

    private func normalize() {
        let allowed = Set(HomePlatform.allCases.map(\.rawValue))
        selectedRaw = selectedRaw.intersection(allowed)
        if selectedRaw.isEmpty {
            selectedRaw = [HomePlatform.netease.rawValue]
        }
    }

    private func save() {
        UserDefaults.standard.set(Array(selectedRaw), forKey: Self.enabledKey)
    }

    private func normalizeOrder() {
        let defaults = HomePlatform.allCases.map(\.rawValue)
        var result = orderedRaw.filter { defaults.contains($0) }
        for raw in defaults where !result.contains(raw) {
            result.append(raw)
        }
        orderedRaw = result
    }

    private func saveOrder() {
        UserDefaults.standard.set(orderedRaw, forKey: Self.orderKey)
    }
}

private extension HomePlatform {
    /// 选择器行的装饰图标（Golia 没有各平台的品牌图，用 SF Symbols）。
    var pickerIcon: String {
        switch self {
        case .netease: return "music.note"
        case .qqmusic: return "music.note.list"
        case .kugou: return "waveform"
        }
    }
}

/// Beans `PlatformPreferencePicker` 的 Golia 版：每行一个平台，点按
/// 切换显示/隐藏；样式是 Golia 设置页的普通 Form 行，不用 Beans 的
/// 玻璃卡片/品牌图/`BeansFont`。排序手柄暂不提供（Beans 的选择器
/// 本身也没有）；顺序由店里的 `movePlatforms` 管，P4 需要时再接 UI。
struct PlatformPreferencePicker: View {
    @ObservedObject private var store = PlatformPreferenceStore.shared

    var body: some View {
        VStack(spacing: 2) {
            ForEach(store.orderedPlatforms) { platform in
                Button {
                    store.set(platform, enabled: !store.isEnabled(platform))
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: platform.pickerIcon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(platform.displayName)
                                .font(.body)
                            Text(store.isEnabled(platform) ? "已显示" : "已隐藏")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: store.isEnabled(platform) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(store.isEnabled(platform) ? Theme.accent : .secondary)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
