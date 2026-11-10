import Foundation

/// Stores user-imported custom audio sources, mirroring Beans'
/// `UnblockSourceStore`, plus the one built-in source
/// (`BuiltInAudioSources.ikunSource`, fixed id `builtin-ikun`,
/// always first in the list).
///
/// One JSON blob in UserDefaults under `storeKey`. The built-in
/// record is stored too — its script text carries an EMPTY API key,
/// so the blob stays key-free. List order is the resolve order in
/// `UnblockService`.
///
/// Security: the blob may contain imported scripts with private keys
/// inside them, so `storeKey` is permanently excluded from
/// SettingsBackup (same category as Keychain logins). See the
/// allowlist comment in `SettingsBackup.swift` (added with PR #31).
///
/// `@MainActor` like `SettingsManager`: `@Published` state is only
/// ever mutated from the UI. `UnblockService` reads the list from a
/// background task via `MainActor.run`, which returns a value-type
/// snapshot (an `[CustomAudioSource]` of `Sendable` structs).
@MainActor
final class CustomAudioSourceStore: ObservableObject {
    static let shared = CustomAudioSourceStore()

    /// UserDefaults key for the JSON `[CustomAudioSource]` blob.
    /// Deliberately NOT in the SettingsBackup allowlist.
    static let storeKey = "settings.customAudioSources"

    @Published var sources: [CustomAudioSource] {
        didSet { save() }
    }

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = storeKey) {
        self.defaults = defaults
        self.key = key
        let saved: [CustomAudioSource]
        if let data = defaults.data(forKey: key),
           let list = try? JSONDecoder().decode([CustomAudioSource].self, from: data) {
            saved = list
        } else {
            saved = []
        }
        // Dedup by id on load (first wins).
        var seen = Set<String>()
        sources = saved.filter { seen.insert($0.id).inserted }
        ensureBuiltInSource()
        save()
    }

    /// Guarantees the built-in ikun source exists, first in the list.
    /// Called on every load: an existing built-in record keeps its
    /// `enabled` / `quality` / `name` but its script is refreshed
    /// from code (source of truth), so an app update can ship a newer
    /// script without touching the toggle. A user who already imported
    /// the same script (same name, random UUID) has that copy ADOPTED
    /// as the built-in source — same id, same script refresh, moved
    /// to index 0 — so the sponsored-key field exists for it instead
    /// of the built-in row silently never appearing.
    func ensureBuiltInSource() {
        if let index = sources.firstIndex(where: { $0.id == BuiltInAudioSources.ikunID }) {
            var list = sources
            var refreshed = list[index]
            refreshed.script = BuiltInAudioSources.ikunScript
            list.remove(at: index)
            list.insert(refreshed, at: 0)
            sources = list
            return
        }
        if let index = sources.firstIndex(where: { $0.name == BuiltInAudioSources.ikunName }) {
            // Adopt only a real copy of this script (same backend):
            // an unrelated script that merely shares the name is
            // left alone, and no built-in row is added for it.
            guard let script = sources[index].script,
                  script.contains(BuiltInAudioSources.ikunBackendHost) else { return }
            var list = sources
            var adopted = list[index]
            // Preserve the key the user already had inside the
            // imported text: move it to the device-only key store
            // before the script is refreshed from code (which carries
            // an empty key). The key field then shows it, and future
            // rotations work from the field.
            if let key = BuiltInAudioSources.apiKeyInScript(script), !key.isEmpty {
                defaults.set(key, forKey: BuiltInAudioSources.apiKeyDefaultsKey)
                if defaults === UserDefaults.standard {
                    // Production uses UserDefaults.standard: keep the
                    // SettingsManager-published value in sync so the
                    // SecureField shows the moved key. Test suites use
                    // an isolated defaults and skip this (no shared
                    // state is touched there).
                    SettingsManager.shared.ikunApiKey = key
                }
            }
            adopted.id = BuiltInAudioSources.ikunID
            adopted.script = BuiltInAudioSources.ikunScript
            list.remove(at: index)
            list.insert(adopted, at: 0)
            sources = list
            return
        }
        var list = sources
        list.insert(BuiltInAudioSources.ikunSource(), at: 0)
        sources = list
    }

    /// True when at least one script source (built-in or imported) is
    /// enabled. The custom-script resolve step and the
    /// `canResolveUnblockedTracks` gate read this, so playback via
    /// scripts does not depend on any built-in source toggle.
    var hasEnabledScriptSources: Bool {
        sources.contains { $0.enabled && $0.script?.isEmpty == false }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sources) {
            defaults.set(data, forKey: key)
        }
    }

    func addSource(_ source: CustomAudioSource) {
        upsert(source)
    }

    func addSources(_ newSources: [CustomAudioSource]) {
        guard !newSources.isEmpty else { return }
        var merged = sources
        for source in newSources {
            if let index = merged.firstIndex(where: { $0.id == source.id }) {
                merged[index] = source
            } else {
                merged.append(source)
            }
        }
        sources = merged
        save()
    }

    func upsert(_ source: CustomAudioSource) {
        var merged = sources
        if let index = merged.firstIndex(where: { $0.id == source.id }) {
            merged[index] = source
        } else {
            merged.append(source)
        }
        sources = merged
        save()
    }

    func moveSource(id: String, by offset: Int) {
        // The built-in source stays pinned at index 0.
        guard !BuiltInAudioSources.isBuiltIn(id: id) else { return }
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        var target = min(max(0, index + offset), max(0, sources.count - 1))
        if let first = sources.first,
           BuiltInAudioSources.isBuiltIn(id: first.id),
           target == 0 {
            target = 1
        }
        guard target != index else { return }
        var reordered = sources
        let item = reordered.remove(at: index)
        reordered.insert(item, at: target)
        sources = reordered
        save()
    }

    func updateEnabled(id: String, enabled: Bool) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        var updated = sources
        updated[index].enabled = enabled
        sources = updated
        save()
    }

    /// Sets every imported source's quality (the global third-party
    /// quality picker in Settings). Resolve keeps reading each source's
    /// own `quality`, so the per-source editor can still override
    /// afterwards; this is only the bulk setter.
    func updateQualityForAll(_ quality: String) {
        guard !sources.isEmpty else { return }
        var updated = sources
        for index in updated.indices {
            updated[index].quality = quality
        }
        sources = updated
        save()
    }

    @discardableResult
    func removeSource(id: String) -> Bool {
        // The built-in source cannot be deleted (only switched off);
        // otherwise a reinstall would be the only way to get it back.
        guard !BuiltInAudioSources.isBuiltIn(id: id) else { return false }
        let originalCount = sources.count
        sources.removeAll { $0.id == id }
        save()
        return sources.count != originalCount
    }
}
