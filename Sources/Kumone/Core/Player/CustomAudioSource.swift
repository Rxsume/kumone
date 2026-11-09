import Foundation

/// A user-imported custom audio source, mirroring Beans'
/// `ThirdPartySource` (UnblockSourceStore.swift).
///
/// `kind` is `"script"` for LX Music-style JS sources and `"keyword"`
/// for URL-template sources. MVP resolves script sources only; the
/// `template`/`urlPath` fields are kept so template sources can be
/// added later without a migration.
///
/// Imported scripts live only on device, in the store's UserDefaults
/// blob (`CustomAudioSourceStore.storeKey`). They are never committed
/// to the repo and are permanently excluded from SettingsBackup: a
/// script may contain the user's private sponsored key.
struct CustomAudioSource: Identifiable, Codable, Hashable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var kind: String = "keyword"
    var template: String
    var urlPath: String = "url"
    var headers: [String: String] = [:]
    var quality: String = "320k"
    var script: String?
    var enabled: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, name, kind, template, urlPath, headers, quality, script, enabled
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        kind: String = "keyword",
        template: String,
        urlPath: String = "url",
        headers: [String: String] = [:],
        quality: String = "320k",
        script: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.template = template
        self.urlPath = urlPath
        self.headers = headers
        self.quality = quality
        self.script = script
        self.enabled = enabled
    }

    /// Lenient decoding, mirroring Beans: a missing field falls back
    /// to a sensible default instead of failing the whole list.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "未命名音源"
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "keyword"
        template = try container.decodeIfPresent(String.self, forKey: .template) ?? ""
        urlPath = try container.decodeIfPresent(String.self, forKey: .urlPath) ?? "url"
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        quality = try container.decodeIfPresent(String.self, forKey: .quality) ?? headers["quality"] ?? "320k"
        script = try container.decodeIfPresent(String.self, forKey: .script)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}
