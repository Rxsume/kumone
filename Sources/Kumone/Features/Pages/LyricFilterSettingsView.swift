// Sources/Kumone/Features/Pages/LyricFilterSettingsView.swift
//
// Folia lyric filtering settings (Folia `LyricFilterSettingsModal` +
// `lyric-filter/`): the per-line filter rules. The staff-credits policy
// itself lives on the 歌词 section of SettingsView; this page is only
// the rule list.
//
// A rule removes a line when it matches the line's full text. Rules are
// stored as a JSON array under `settings.lyricLineRules`; at most 50.
// An invalid regex never crashes lyric loading — the rule is skipped and
// the error shows here.

import SwiftUI

struct LyricFilterSettingsView: View {
    @EnvironmentObject private var settings: SettingsManager
    @State private var draftRule: LyricLineRule?
    @State private var showingResetConfirm = false

    var body: some View {
        List {
            Section {
                Text("删掉符合规则的歌词行。规则按顺序试，一行命中任意一条启用的规则就会被删掉；删掉的是整行（歌词、翻译、读音和逐字时间一起走），剩下的行时间不变。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("规则") {
                ForEach($settings.lyricLineRules) { $rule in
                    HStack {
                        Toggle("", isOn: $rule.isOn)
                            .labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ruleSummary(rule))
                                .font(.body)
                                .lineLimit(1)
                            Text(rule.shape.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let error = LyricFilter.ruleError(rule) {
                                Text(error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { draftRule = rule }
                }
                .onDelete { settings.lyricLineRules.remove(atOffsets: $0) }
                .onMove { settings.lyricLineRules.move(fromOffsets: $0, toOffset: $1) }
            }
            Section {
                Menu("添加规则") {
                    Button("开头是") { addRule(shape: .starts) }
                    Button("包含") { addRule(shape: .contains) }
                    Button("整行是") { addRule(shape: .whole) }
                    Button("结尾是") { addRule(shape: .ends) }
                    Button("正则表达式") { addRule(shape: .written) }
                    Divider()
                    Button("预设：版权声明") { addPreset("copyright") }
                    Button("预设：歌词来源") { addPreset("lyricSource") }
                }
                .disabled(settings.lyricLineRules.count >= LyricFilterSettings.maxRules)
                Button("恢复默认", role: .destructive) {
                    showingResetConfirm = true
                }
                if settings.lyricLineRules.count >= LyricFilterSettings.maxRules {
                    Text("已达到 50 条上限，删掉一条才能再加")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("默认只有一条：删掉没有署名的“作词：无 / 作曲：无”行。")
            }
        }
        .navigationTitle("歌词过滤")
        .toolbar {
            #if os(iOS)
            EditButton()
            #endif
        }
        .sheet(item: $draftRule) { rule in
            LyricRuleEditorView(
                rule: rule,
                onSave: { updated in
                    if let index = settings.lyricLineRules.firstIndex(where: { $0.id == updated.id }) {
                        settings.lyricLineRules[index] = updated
                    }
                    draftRule = nil
                },
                onDelete: {
                    settings.lyricLineRules.removeAll { $0.id == rule.id }
                    draftRule = nil
                }
            )
        }
        .confirmationDialog("恢复默认规则？", isPresented: $showingResetConfirm) {
            Button("恢复默认", role: .destructive) {
                settings.lyricLineRules = LyricLineRule.defaultRules
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("现在的规则会被默认规则替换。")
        }
    }

    private func ruleSummary(_ rule: LyricLineRule) -> String {
        if rule.shape == .preset {
            return LyricLineRule.presetDisplayName(rule.text)
        }
        let first = rule.text.components(separatedBy: .newlines).first ?? ""
        let words = LyricFilter.ruleWords(rule.text)
        if words.count > 1 {
            return "\(first) 等 \(words.count) 个词"
        }
        return first.isEmpty ? "（空规则）" : first
    }

    private func addRule(shape: LyricLineRule.Shape) {
        guard settings.lyricLineRules.count < LyricFilterSettings.maxRules else { return }
        let rule = LyricLineRule(shape: shape, text: "")
        settings.lyricLineRules.append(rule)
        draftRule = rule
    }

    private func addPreset(_ id: String) {
        guard settings.lyricLineRules.count < LyricFilterSettings.maxRules else { return }
        let rule = LyricLineRule(shape: .preset, text: id)
        settings.lyricLineRules.append(rule)
        draftRule = rule
    }
}

/// One rule's editor (Folia's rule row editor): shape, words or
/// expression, colon and edges-only switches, invalid-regex note.
private struct LyricRuleEditorView: View {
    @State private var edited: LyricLineRule
    @Environment(\.dismiss) private var dismiss
    let onSave: (LyricLineRule) -> Void
    let onDelete: () -> Void

    init(rule: LyricLineRule, onSave: @escaping (LyricLineRule) -> Void, onDelete: @escaping () -> Void) {
        self._edited = State(initialValue: rule)
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("启用", isOn: $edited.isOn)
                    Picker("匹配方式", selection: $edited.shape) {
                        ForEach(LyricLineRule.Shape.allCases, id: \.self) { shape in
                            Text(shape.displayName).tag(shape)
                        }
                    }
                }
                Section {
                    if edited.shape == .preset {
                        Picker("预设", selection: $edited.text) {
                            ForEach(LyricLineRule.presets, id: \.0) { preset in
                                Text(LyricLineRule.presetDisplayName(preset.0)).tag(preset.0)
                            }
                        }
                        Text("命中预设里任意一个词的行会被删掉")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if edited.shape == .written {
                        TextField("正则表达式", text: $edited.text)
                            .font(.system(.body, design: .monospaced))
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                        Text("按正则表达式匹配整行歌词；写错了这条规则会被跳过，不会让歌词加载失败")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let error = LyricFilter.ruleError(edited) {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    } else {
                        TextEditor(text: $edited.text)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 120)
                        Text("每行一个词；一行命中任意一个词就算匹配")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    if edited.shape == .starts {
                        Toggle("后面跟冒号", isOn: $edited.colon)
                        Text("只删“词 + 冒号”的行，例如“作词：”")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("只删开头和结尾的歌词行", isOn: $edited.edgesOnly)
                    Text("打开后，歌曲中间的歌词行不会被这条规则删掉")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("删除这条规则", role: .destructive) {
                        onDelete()
                    }
                }
            }
            .navigationTitle("编辑规则")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(edited)
                    }
                }
            }
        }
    }
}
