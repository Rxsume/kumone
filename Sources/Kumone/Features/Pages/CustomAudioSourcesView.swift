import SwiftUI
import UniformTypeIdentifiers

/// Manages user-imported custom audio sources (LX Music-style JS
/// scripts), mirroring Beans' `ThirdPartySourceManagerSheet`.
///
/// Import modes: paste text, remote URL, local file. Imported scripts
/// are stored on device only (see `CustomAudioSourceStore`) and are
/// never committed to the repo or included in a settings backup.
///
/// Trust note shown in the sheet: a script runs with network access,
/// so only import scripts from sources you trust.
struct CustomAudioSourcesView: View {
    @ObservedObject private var store = CustomAudioSourceStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var importMode: ImportMode = .paste
    @State private var importText = ""
    @State private var importURL = ""
    @State private var importStatus: String?
    @State private var importErrorMessage = ""
    @State private var showImportErrorAlert = false
    @State private var showFileImporter = false
    @State private var editingSource: CustomAudioSource?

    private enum ImportMode: String, CaseIterable, Identifiable {
        case paste
        case link
        case file

        var id: String { rawValue }

        var title: String {
            switch self {
            case .paste: return "文本"
            case .link: return "链接"
            case .file: return "文件"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("支持本地文件、远程 URL 和粘贴文本。支持 LX Music 风格的 JS 音源脚本；在线导入后会保存本地副本。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("脚本运行时可以联网，只从你信任的来源导入。列表顺序即播放时的解析顺序。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("导入与管理")
                }

                Section {
                    Picker("导入方式", selection: $importMode) {
                        ForEach(ImportMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch importMode {
                    case .paste:
                        TextEditor(text: $importText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 140)
                    case .link:
                        TextField("https://…", text: $importURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    case .file:
                        Text("选择本地的 JSON / JS / TXT 文件。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("识别并导入") {
                        importCurrentInput()
                    }
                    .disabled(importMode == .paste && importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || importMode == .link && importURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let importStatus {
                        Text(importStatus)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Text("支持 JSON 数组、单个配置、`SERVER_SCRIPT_CONFIG` 片段，以及 `@name` / `@template` 头部格式。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("导入音源")
                }

                Section {
                    if store.sources.isEmpty {
                        Text("还没有导入音源。粘贴 LX 脚本后点「识别并导入」。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.sources) { source in
                        SourceRow(
                            source: source,
                            onToggle: { store.updateEnabled(id: source.id, enabled: $0) },
                            onEdit: { editingSource = source },
                            onMoveUp: { store.moveSource(id: source.id, by: -1) },
                            onMoveDown: { store.moveSource(id: source.id, by: 1) },
                            onDelete: { _ = store.removeSource(id: source.id) }
                        )
                    }
                } header: {
                    HStack {
                        Text("音源列表")
                        Spacer()
                        Text("\(store.sources.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("自定义音源")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.json, .plainText, .item]
            ) { result in
                importFile(result)
            }
            .alert("导入失败", isPresented: $showImportErrorAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(importErrorMessage)
            }
            .sheet(item: $editingSource) { source in
                SourceEditorSheet(source: source) { updated in
                    store.upsert(updated)
                    editingSource = nil
                }
            }
        }
    }

    private func importCurrentInput() {
        switch importMode {
        case .file:
            showFileImporter = true
            return
        case .paste, .link:
            break
        }
        Task { @MainActor in
            do {
                let parsed: [CustomAudioSource]
                switch importMode {
                case .paste:
                    parsed = try CustomAudioSourceImportParser.parse(text: importText)
                case .link:
                    guard let url = URL(string: importURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        throw CustomAudioSourceImportError.invalidURL
                    }
                    parsed = try await CustomAudioSourceImportParser.fetch(url: url)
                case .file:
                    return
                }
                finishImport(parsed)
            } catch {
                showImportError(error)
            }
        }
    }

    private func importFile(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            showImportError(error)
        case .success(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let parsed = try CustomAudioSourceImportParser.parse(fileURL: url)
                finishImport(parsed)
            } catch {
                showImportError(error)
            }
        }
    }

    private func finishImport(_ sources: [CustomAudioSource]) {
        // Fresh UUIDs, as in Beans: re-importing the same script
        // creates a new record rather than colliding.
        var imported = sources
        for index in imported.indices {
            imported[index].id = UUID().uuidString
        }
        store.addSources(imported)
        importText = ""
        importURL = ""
        importStatus = "已导入 \(imported.count) 个音源"
    }

    private func showImportError(_ error: Error) {
        importErrorMessage = error.localizedDescription
        showImportErrorAlert = true
    }
}

private struct SourceRow: View {
    let source: CustomAudioSource
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onEdit) {
                Label("编辑", systemImage: "slider.horizontal.3")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            Button(action: onMoveUp) {
                Label("上移", systemImage: "chevron.up")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            Button(action: onMoveDown) {
                Label("下移", systemImage: "chevron.down")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            Button(action: onDelete) {
                Label("删除", systemImage: "trash")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            Toggle("", isOn: Binding(get: { source.enabled }, set: onToggle))
                .labelsHidden()
        }
    }

    private var subtitle: String {
        if source.kind == "script" || source.script != nil {
            return "脚本 · \(source.quality)"
        }
        return "\(source.kind) · \(source.quality)"
    }
}

private struct SourceEditorSheet: View {
    @State private var draft: CustomAudioSource
    let onSave: (CustomAudioSource) -> Void
    @Environment(\.dismiss) private var dismiss

    private static let qualityOptions: [(value: String, label: String)] = [
        ("128k", "128k"),
        ("192k", "192k"),
        ("320k", "320k"),
        ("flac", "FLAC"),
        ("flac24bit", "FLAC 24-bit"),
        ("hires", "Hi-Res"),
        ("master", "Master"),
    ]

    init(source: CustomAudioSource, onSave: @escaping (CustomAudioSource) -> Void) {
        _draft = State(initialValue: source)
        self.onSave = onSave
    }

    private var qualityOptions: [(value: String, label: String)] {
        var options = Self.qualityOptions
        if !options.contains(where: { $0.value == draft.quality }) {
            options.insert((draft.quality, draft.quality), at: 0)
        }
        return options
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("音源名称", text: $draft.name)
                }
                Section("音质") {
                    Picker("音质", selection: $draft.quality) {
                        ForEach(qualityOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                }
                if draft.script != nil || draft.kind == "script" {
                    Section("脚本内容") {
                        TextEditor(text: Binding(
                            get: { draft.script ?? "" },
                            set: { draft.script = $0 }
                        ))
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 220)
                    }
                }
                if !draft.template.isEmpty {
                    Section("URL 模板") {
                        TextField("模板", text: $draft.template)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                Section {
                    Toggle("启用", isOn: $draft.enabled)
                }
            }
            .navigationTitle("编辑音源")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
