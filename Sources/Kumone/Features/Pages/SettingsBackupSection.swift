import SwiftUI
import UniformTypeIdentifiers

/// "备份与恢复" section in Settings: export all settings to a JSON
/// file (share sheet / Save to Files), import one back.
///
/// Export never includes logins, passwords or tokens (see
/// `SettingsBackup`); import validates the file first, asks for
/// confirmation before overwriting anything, and only applies known
/// settings keys. Runs on iOS and macOS alike.
struct SettingsBackupSection: View {
    @State private var exportURL: URL?
    @State private var showImporter = false
    @State private var pendingBackup: SettingsBackup.ValidatedBackup?
    @State private var showConfirmRestore = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        Section("备份与恢复") {
            Button {
                exportTapped()
            } label: {
                Label("导出设置备份", systemImage: "square.and.arrow.up")
            }

            // ShareLink needs a file URL; it appears after an export is
            // generated, and its sheet offers Save to Files plus any
            // installed handler (AirDrop, Files, chat apps…).
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("分享备份文件", systemImage: "square.and.arrow.up.on.square")
                }
            }

            Button("从文件恢复设置…") {
                showImporter = true
            }

            Text("只备份设置，不含登录账号、密码与 Token。恢复会覆盖当前全部设置，恢复前会请你确认；登录状态不受影响。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                importPicked(url)
            case .failure(let error):
                fail(error.localizedDescription)
            }
        }
        .alert("恢复设置", isPresented: $showConfirmRestore) {
            Button("恢复", role: .destructive) {
                if let backup = pendingBackup {
                    let result = SettingsBackup.apply(backup)
                    pendingBackup = nil
                    var message = "已恢复 \(result.appliedCount) 项设置"
                    if result.skippedUnknownCount > 0 || result.skippedTypeMismatchCount > 0 {
                        message += "（跳过 \(result.skippedUnknownCount + result.skippedTypeMismatchCount) 项无法识别的内容）"
                    }
                    ToastCenter.shared.show(message)
                }
            }
            Button("取消", role: .cancel) {
                pendingBackup = nil
            }
        } message: {
            if let backup = pendingBackup {
                Text(confirmationMessage(for: backup))
            }
        }
        .alert("无法恢复", isPresented: $showError) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func confirmationMessage(for backup: SettingsBackup.ValidatedBackup) -> String {
        var parts: [String] = []
        if let version = backup.appVersion, !version.isEmpty {
            var line = "来自 Golia \(version)"
            if let build = backup.build, !build.isEmpty { line += " (build \(build))" }
            parts.append(line)
        }
        if let date = backup.exportedAt {
            parts.append("导出于 \(date.formatted(date: .long, time: .shortened))")
        }
        parts.append("将用它覆盖当前设置（\(backup.values.count) 项）")
        if backup.unknownKeyCount > 0 || backup.typeMismatchCount > 0 {
            parts.append("其中 \(backup.unknownKeyCount + backup.typeMismatchCount) 项无法识别，会被跳过")
        }
        parts.append("登录状态不受影响。")
        return parts.joined(separator: "，")
    }

    private func exportTapped() {
        guard let data = SettingsBackup.exportData() else {
            fail(String(localized: "导出失败，请重试"))
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(SettingsBackup.exportFileName())
        do {
            try data.write(to: url, options: .atomic)
            exportURL = url
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func importPicked(_ url: URL) {
        // File-picker URLs are security-scoped: take access, read, release.
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            fail(error.localizedDescription)
            return
        }
        do {
            let backup = try SettingsBackup.validate(data)
            if backup.values.isEmpty {
                fail(String(localized: "这个备份里没有可恢复的设置"))
                return
            }
            pendingBackup = backup
            showConfirmRestore = true
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        showError = true
    }
}
