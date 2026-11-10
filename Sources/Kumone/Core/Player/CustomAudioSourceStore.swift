import Foundation

/// Stores user-imported custom audio sources, mirroring Beans'
/// `UnblockSourceStore`.
///
/// One JSON blob in UserDefaults under `storeKey`. List order is
/// the resolve order in `UnblockService`. Two bundled scripts are
/// seeded once (酸甜贤 + Golia贤源, see `BuiltInAudioSources`):
/// each seeds only when no copy of the same script is already
/// stored, and deleting a seeded record marks it dismissed so it
/// is never re-seeded. A seeded record is otherwise an ordinary
/// imported source; a leftover record of the removed 2026-11-10
/// built-in is the same.
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
        declaredPlatforms = Self.loadDeclaredPlatforms(from: defaults)
        migrateLegacyBuiltInKeyIfNeeded()
        seedBuiltInSourcesIfNeeded()
        save()
    }

    /// Seeds the two bundled scripts once: 酸甜贤 first, Golia
    /// second (list order is resolve order). Each seeds only when
    /// no copy of the same script is already stored (matched by
    /// backend host, not id, so a user-imported copy suppresses
    /// the seed) and the user has not deleted the seeded record.
    private func seedBuiltInSourcesIfNeeded() {
        var list = sources
        if !defaults.bool(forKey: BuiltInAudioSources.ikunDismissedKey),
           !list.contains(where: { $0.script?.contains(BuiltInAudioSources.ikunBackendHost) == true }) {
            list.append(BuiltInAudioSources.seededIkunSource())
        }
        if !defaults.bool(forKey: BuiltInAudioSources.goliaDismissedKey),
           !list.contains(where: { $0.script?.contains(BuiltInAudioSources.goliaBackendHost) == true }) {
            list.append(BuiltInAudioSources.seededGoliaSource())
        }
        sources = list
    }

    /// One-time migration (built-in removal, 2026-11-10). The removed
    /// built-in ikun source stored an EMPTY key in its script text
    /// and kept the sponsored key in UserDefaults under
    /// "settings.ikunApiKey", which only the removed built-in
    /// injection read. Fold the key back into the script text once,
    /// so the record keeps working as an ordinary imported script,
    /// then drop the device-only key. Idempotent: after the first
    /// run the defaults key is gone, so later loads are no-ops.
    /// Matches by script content (ikun backend host + empty
    /// `API_KEY` placeholder), not by id, so any empty-key copy of
    /// the script is repaired. The key is never logged.
    private func migrateLegacyBuiltInKeyIfNeeded() {
        guard let key = defaults.string(forKey: "settings.ikunApiKey"), !key.isEmpty else { return }
        let placeholder = "const API_KEY = \"\""
        var list = sources
        var changed = false
        for index in list.indices {
            guard let script = list[index].script,
                  script.contains("c.wwwweb.top"),
                  script.contains(placeholder) else { continue }
            list[index].script = script.replacingOccurrences(
                of: placeholder,
                with: "const API_KEY = \"\(Self.jsEscaped(key))\""
            )
            changed = true
        }
        if changed {
            sources = list
        }
        defaults.removeObject(forKey: "settings.ikunApiKey")
    }

    /// Escapes a key for interpolation into a JS double-quoted string.
    private static func jsEscaped(_ key: String) -> String {
        key
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    /// Declared LX source ids per custom source, as reported by the
    /// script itself in its `inited` event (the keys of its
    /// `musicSources` object). Display-only: never consulted by
    /// resolve. Persisted in UserDefaults under `platformsKey` so
    /// the editor shows the last known platforms even before the
    /// source has ever played in this install; refreshed on every
    /// runtime init via `noteDeclaredPlatforms`. Deliberately NOT in
    /// the SettingsBackup allowlist (same category as the sources
    /// blob: derived from user-imported scripts).
    static let platformsKey = "settings.customAudioSourcePlatforms"

    /// Source id → sorted declared LX source ids. A missing entry
    /// means never observed (the editor shows the "first playback"
    /// note); an empty array means observed with no sources.
    @Published private(set) var declaredPlatforms: [String: [String]] = [:]

    private static func loadDeclaredPlatforms(from defaults: UserDefaults) -> [String: [String]] {
        guard let data = defaults.data(forKey: platformsKey),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return decoded
    }

    /// Declared platforms for one source, or nil if never observed.
    func declaredPlatforms(for id: String) -> [String]? {
        declaredPlatforms[id]
    }

    /// Records the platforms a script declared at runtime init.
    /// Called from `LXScriptRuntime.receive(event:payload:)` on the
    /// `inited` event; overwrites any previous entry for the id.
    func noteDeclaredPlatforms(_ ids: [String], for id: String) {
        let sorted = ids.sorted()
        guard declaredPlatforms[id] != sorted else { return }
        declaredPlatforms[id] = sorted
        saveDeclaredPlatforms()
    }

    private func saveDeclaredPlatforms() {
        if let data = try? JSONEncoder().encode(declaredPlatforms) {
            defaults.set(data, forKey: Self.platformsKey)
        }
    }

    /// True when at least one script source is enabled. The
    /// custom-script resolve step and the
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
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        let target = min(max(0, index + offset), max(0, sources.count - 1))
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
        let originalCount = sources.count
        sources.removeAll { $0.id == id }
        // Deleting a seeded record dismisses it, so the next launch
        // does not bring it back. Deleting a user-imported copy
        // does not dismiss anything: the seed may appear as its
        // replacement, and deleting that seed dismisses it.
        if id == BuiltInAudioSources.ikunSourceID {
            defaults.set(true, forKey: BuiltInAudioSources.ikunDismissedKey)
        } else if id == BuiltInAudioSources.goliaSourceID {
            defaults.set(true, forKey: BuiltInAudioSources.goliaDismissedKey)
        }
        // Drop the cached platform chips too, so the persisted cache
        // does not grow with entries for sources that no longer exist.
        if declaredPlatforms.removeValue(forKey: id) != nil {
            saveDeclaredPlatforms()
        }
        save()
        return sources.count != originalCount
    }
}
