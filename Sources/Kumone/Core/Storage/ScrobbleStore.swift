import Foundation
import SwiftUI

/// 打卡上报（scrobble）开关的专用 Store。
///
/// 恢复自 PR #42 删掉的“听歌打卡”：播放网易云歌曲时向服务端上报听歌
/// 记录（`/feedback/weblog` 的 `startplay` / `play` 两条 weblog），上报
/// 后服务端才会计入听歌排行与最近播放。故意不放在 `SettingsManager` 里
/// —— 设置页正由另一批工作重组，这里只给排行页内用；键沿用旧的
/// `settings.neteaseScrobbleEnabled`，但默认值改为关：用户在排行页手动
/// 打开后才上报。旧版本里开过开关的用户（本机已存 `true`）会保持开启。
@MainActor
final class ScrobbleStore: ObservableObject {
    static let shared = ScrobbleStore()

    static let userDefaultsKey = "settings.neteaseScrobbleEnabled"

    /// Off by default: the user turns it on in the ranking page.
    @AppStorage("settings.neteaseScrobbleEnabled") var isEnabled = false

    private init() {}
}
