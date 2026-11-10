import SwiftUI

struct SleepTimerMenu: View {
    @ObservedObject private var player: PlayerService
    @ObservedObject private var sleepTimer: SleepTimer
    /// Icon-only label for the circular player-page buttons (no text,
    /// same 44pt circle as the neighbouring buttons).
    private let iconOnly: Bool

    init(player: PlayerService, iconOnly: Bool = false) {
        _player = ObservedObject(wrappedValue: player)
        _sleepTimer = ObservedObject(wrappedValue: player.sleepTimer)
        self.iconOnly = iconOnly
    }

    var body: some View {
        Menu {
            if let activeStatus {
                Label(activeStatus, systemImage: "timer")
                    .disabled(true)
                Divider()
            }

            ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                Button(String(localized: "\(minutes) 分钟")) {
                    sleepTimer.schedule(afterMinutes: minutes)
                }
                .disabled(!player.hasCurrentTrack)
            }

            Button {
                sleepTimer.scheduleAtEndOfCurrentTrack()
            } label: {
                Label("当前歌曲结束时停止", systemImage: "music.note")
            }
            .disabled(!player.hasCurrentTrack)

            if sleepTimer.state.isActive {
                Divider()
                Button("取消睡眠定时", role: .destructive) {
                    sleepTimer.cancel()
                }
            }
        } label: {
            if iconOnly {
                Image(systemName: sleepTimer.state.isActive ? "timer.circle.fill" : "timer")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(sleepTimer.state.isActive ? Theme.accent : .white.opacity(0.72))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.08), in: Circle())
                    .accessibilityLabel(menuTitle)
            } else {
                Label(menuTitle, systemImage: sleepTimer.state.isActive ? "timer.circle.fill" : "timer")
            }
        }
        .disabled(!player.hasCurrentTrack && !sleepTimer.state.isActive)
    }

    private var menuTitle: String {
        switch sleepTimer.state {
        case .inactive:
            return String(localized: "睡眠定时")
        case .countdown:
            return String.localizedStringWithFormat(
                String(localized: "睡眠定时（剩余 %@）"),
                remainingDuration
            )
        case .endOfCurrentTrack:
            return String(localized: "睡眠定时（本曲结束）")
        }
    }

    private var activeStatus: String? {
        switch sleepTimer.state {
        case .inactive:
            return nil
        case .countdown:
            return String.localizedStringWithFormat(
                String(localized: "剩余 %@"),
                remainingDuration
            )
        case .endOfCurrentTrack:
            return String(localized: "将在当前歌曲结束时停止")
        }
    }

    private var remainingDuration: String {
        guard case .countdown(let deadline) = sleepTimer.state else { return "" }
        return Formatters.duration(max(0, deadline.timeIntervalSinceNow))
    }
}
