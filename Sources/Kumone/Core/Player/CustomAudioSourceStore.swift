import Foundation

/// Stores user-imported custom audio sources, mirroring Beans'
/// `UnblockSourceStore`.
///
/// One JSON blob in UserDefaults under `storeKey`. No built-in sources
/// are ever stored — the list only ever holds what the user imported.
/// List order is the user's manual order and the resolve order in
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
        save()
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

    @discardableResult
    func removeSource(id: String) -> Bool {
        let originalCount = sources.count
        sources.removeAll { $0.id == id }
        save()
        return sources.count != originalCount
    }
}
