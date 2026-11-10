import Foundation
import Testing
@testable import KumoneCore

@Suite("Custom audio source tests")
struct CustomAudioSourceTests {
    // MARK: - Parser

    @Test func parsesJSONDictWithScript() throws {
        let json = """
        {"name": "JSON Source", "kind": "script", "script": "globalThis.lx.on('x', () => {})", "quality": "320k"}
        """
        let sources = try CustomAudioSourceImportParser.parse(text: json)
        #expect(sources.count == 1)
        #expect(sources[0].name == "JSON Source")
        #expect(sources[0].kind == "script")
        #expect(sources[0].script?.contains("globalThis.lx") == true)
    }

    @Test func parsesJSONArray() throws {
        let json = """
        [{"name": "First", "template": "https://example.com/{id}"}, {"name": "Second", "template": "https://example.com/{id}"}]
        """
        let sources = try CustomAudioSourceImportParser.parse(text: json)
        #expect(sources.count == 2)
        #expect(sources.map(\.name) == ["First", "Second"])
    }

    @Test func parsesLXScriptWithNameHeader() throws {
        let script = """
        /*!
         * @name Stub Source
         * @version v1
         */
        const {EVENT_NAMES, on} = globalThis.lx;
        on(EVENT_NAMES.request, ({action}) => Promise.reject("no"));
        """
        let sources = try CustomAudioSourceImportParser.parse(text: script)
        #expect(sources.count == 1)
        #expect(sources[0].name == "Stub Source")
        #expect(sources[0].kind == "script")
        #expect(sources[0].script == script)
    }

    @Test func parsesServerScriptConfig() throws {
        // NOTE: the config regex is non-greedy, so the template value
        // must not itself contain `{...}` placeholders (same as Beans).
        let text = """
        const SERVER_SCRIPT_CONFIG = {"name": "Config Source", "template": "https://example.com/play", "quality": "320k"};
        """
        let sources = try CustomAudioSourceImportParser.parse(text: text)
        #expect(sources.count == 1)
        #expect(sources[0].name == "Config Source")
        #expect(sources[0].template == "https://example.com/play")
    }

    @Test func parsesHeaderStyleTemplate() throws {
        let text = """
        /*!
         * @name Header Source
         * @template https://example.com/url?source={source}&songId={id}&quality={quality}
         */
        """
        let sources = try CustomAudioSourceImportParser.parse(text: text)
        #expect(sources.count == 1)
        #expect(sources[0].name == "Header Source")
        #expect(sources[0].template.hasPrefix("https://example.com/url") == true)
    }

    @Test func emptyInputThrows() {
        #expect(throws: CustomAudioSourceImportError.self) {
            try CustomAudioSourceImportParser.parse(text: "  \n ")
        }
    }

    @Test func garbageInputThrowsUnsupported() {
        #expect(throws: CustomAudioSourceImportError.self) {
            try CustomAudioSourceImportParser.parse(text: "hello world this is not a source")
        }
    }

    // MARK: - Model

    @Test func lenientDecodingAppliesDefaults() throws {
        let data = #"{"name": "Bare"}"#.data(using: .utf8)!
        let source = try JSONDecoder().decode(CustomAudioSource.self, from: data)
        #expect(!source.id.isEmpty)
        #expect(source.name == "Bare")
        #expect(source.kind == "keyword")
        #expect(source.template == "")
        #expect(source.urlPath == "url")
        #expect(source.quality == "320k")
        #expect(source.script == nil)
        #expect(source.enabled == true)
    }

    // MARK: - Store

    /// A fresh store seeds the two bundled scripts (酸甜贤 first,
    /// Golia second). The ikun script ships with its private key
    /// blanked; the Golia script ships verbatim.
    @Test @MainActor func freshStoreSeedsBothBuiltInSources() {
        let suite = "com.test.FreshStoreTests"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not create test UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = CustomAudioSourceStore(defaults: defaults)
        #expect(store.sources.count == 2)
        let ikun = store.sources[0]
        #expect(ikun.id == BuiltInAudioSources.ikunSourceID)
        #expect(ikun.name == "酸甜贤音源")
        #expect(ikun.kind == "script")
        #expect(ikun.template == "")
        #expect(ikun.quality == "320k")
        #expect(ikun.enabled == true)
        #expect(ikun.script?.contains(BuiltInAudioSources.ikunBackendHost) == true)
        #expect(ikun.script?.contains("const API_KEY = \"\"") == true)
        let golia = store.sources[1]
        #expect(golia.id == BuiltInAudioSources.goliaSourceID)
        #expect(golia.name == "Golia贤源")
        #expect(golia.kind == "script")
        #expect(golia.script?.contains(BuiltInAudioSources.goliaBackendHost) == true)
        #expect(store.hasEnabledScriptSources == true)

        // Reloading does not seed a second copy.
        let reloaded = CustomAudioSourceStore(defaults: defaults)
        #expect(reloaded.sources.count == 2)
        #expect(reloaded.sources.map(\.id) == [BuiltInAudioSources.ikunSourceID, BuiltInAudioSources.goliaSourceID])
    }

    /// A stored copy of one script suppresses only that seed; the
    /// other still seeds. (The stored copy stands in for the user's
    /// imported ikun script, key already inside it.)
    @Test @MainActor func seedingSkipsScriptAlreadyStored() {
        let suite = "com.test.SeedSkipTests"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not create test UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let imported = CustomAudioSource(
            name: "我的酸甜贤",
            kind: "script",
            template: "",
            script: "const API_URL = \"https://c.wwwweb.top\";\nconst API_KEY = \"ALREADY-IN-SCRIPT\";"
        )
        guard let data = try? JSONEncoder().encode([imported]) else {
            Issue.record("could not encode imported source")
            return
        }
        defaults.set(data, forKey: CustomAudioSourceStore.storeKey)

        let store = CustomAudioSourceStore(defaults: defaults)
        #expect(store.sources.count == 2)
        #expect(store.sources[0].id == imported.id)
        #expect(store.sources[0].script?.contains("ALREADY-IN-SCRIPT") == true)
        #expect(store.sources[1].id == BuiltInAudioSources.goliaSourceID)
    }

    /// Deleting a seeded record dismisses it: it never comes back
    /// on reload, while the other seed is untouched.
    @Test @MainActor func deletingSeededSourceDismissesIt() {
        let suite = "com.test.SeedDismissTests"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not create test UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = CustomAudioSourceStore(defaults: defaults)
        #expect(store.sources.count == 2)
        #expect(store.removeSource(id: BuiltInAudioSources.ikunSourceID) == true)
        #expect(defaults.bool(forKey: BuiltInAudioSources.ikunDismissedKey) == true)

        let reloaded = CustomAudioSourceStore(defaults: defaults)
        #expect(reloaded.sources.count == 1)
        #expect(reloaded.sources.first?.id == BuiltInAudioSources.goliaSourceID)
    }

    // MARK: - Built-in API_KEY helpers

    /// Fake placeholder keys only, never a real key.
    @Test func builtInApiKeyReadsAndWritesBothQuoteStyles() {
        let ikun = BuiltInAudioSources.ikunScript
        #expect(BuiltInAudioSources.apiKey(in: ikun) == "")
        let keyed = BuiltInAudioSources.settingApiKey("TEST-KEY-123", in: ikun)
        #expect(keyed?.contains("const API_KEY = \"TEST-KEY-123\"") == true)
        #expect(BuiltInAudioSources.apiKey(in: keyed ?? "") == "TEST-KEY-123")

        let golia = BuiltInAudioSources.goliaScript
        #expect(BuiltInAudioSources.apiKey(in: golia) == "share-v3")
        let goliaKeyed = BuiltInAudioSources.settingApiKey("TEST-KEY-456", in: golia)
        #expect(BuiltInAudioSources.apiKey(in: goliaKeyed ?? "") == "TEST-KEY-456")

        #expect(BuiltInAudioSources.apiKey(in: "const x = 1;") == nil)
        #expect(BuiltInAudioSources.settingApiKey("TEST-KEY-123", in: "const x = 1;") == nil)
    }

    /// `$` and `\` in a key must survive the write verbatim (the
    /// write replaces the captured value range, not a regex
    /// template, so they cannot be reinterpreted).
    @Test func builtInApiKeyRoundTripsSpecialCharacters() {
        let script = "const API_KEY = \"\";"
        let key = "A$0\\B\"C'D"
        let keyed = BuiltInAudioSources.settingApiKey(key, in: script)
        #expect(BuiltInAudioSources.apiKey(in: keyed ?? "") == key)
    }

    @Test @MainActor func storeRoundTripPreservesScript() {
        let suite = "com.test.CustomAudioSourceTests"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not create test UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let source = CustomAudioSource(
            name: "测试音源",
            kind: "script",
            template: "",
            script: "const x = '你好世界'; // non-ASCII must survive the blob"
        )
        let store = CustomAudioSourceStore(defaults: defaults)
        // A fresh store already seeds the two built-in sources.
        #expect(store.sources.count == 2)
        store.addSources([source])
        #expect(store.sources.count == 3)
        #expect(store.sources.first(where: { $0.id == source.id })?.name == "测试音源")

        let reloaded = CustomAudioSourceStore(defaults: defaults)
        #expect(reloaded.sources.count == 3)
        #expect(reloaded.sources.first(where: { $0.id == source.id })?.script == source.script)

        reloaded.updateEnabled(id: source.id, enabled: false)
        #expect(reloaded.sources.first(where: { $0.id == source.id })?.enabled == false)
        // The added source sits last, so moving it one slot down is a no-op.
        reloaded.moveSource(id: source.id, by: 1)
        #expect(reloaded.sources.count == 3)
        #expect(reloaded.sources.first(where: { $0.id == source.id }) != nil)
        #expect(reloaded.removeSource(id: source.id) == true)
        #expect(reloaded.sources.count == 2)
    }

    // MARK: - Legacy built-in key migration (one-time, 2026-11-10)

    /// An empty-key copy of the ikun script plus the legacy
    /// device-only key: the key is folded back into the script text
    /// once, and the defaults key is dropped. (TEST-KEY-123 is a
    /// fake placeholder for this test, never a real key.)
    @Test @MainActor func migrationFoldsLegacyKeyIntoEmptyKeyScript() {
        let suite = "com.test.LegacyKeyMigrationTests"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not create test UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let source = CustomAudioSource(
            name: "ikun 音源",
            kind: "script",
            template: "",
            script: """
            const API_URL = "https://c.wwwweb.top";
            const API_KEY = "";
            """
        )
        guard let data = try? JSONEncoder().encode([source]) else {
            Issue.record("could not encode imported source")
            return
        }
        defaults.set(data, forKey: CustomAudioSourceStore.storeKey)
        defaults.set("TEST-KEY-123", forKey: "settings.ikunApiKey")

        let store = CustomAudioSourceStore(defaults: defaults)
        // The ikun seed is suppressed (the stored copy already has
        // the host), but the Golia seed still appends behind it.
        #expect(store.sources.count == 2)
        #expect(store.sources.first?.script?.contains("const API_KEY = \"TEST-KEY-123\"") == true)
        #expect(store.sources.first?.script?.contains("const API_KEY = \"\"") == false)
        #expect(defaults.string(forKey: "settings.ikunApiKey") == nil)
    }

    /// A script that already carries its key is untouched, but the
    /// legacy defaults key is still dropped (one-time cleanup).
    @Test @MainActor func migrationLeavesKeyedScriptUntouched() {
        let suite = "com.test.LegacyKeyMigrationKeyedTests"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not create test UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let script = """
        const API_URL = "https://c.wwwweb.top";
        const API_KEY = "ALREADY-IN-SCRIPT";
        """
        let source = CustomAudioSource(name: "ikun 音源", kind: "script", template: "", script: script)
        guard let data = try? JSONEncoder().encode([source]) else {
            Issue.record("could not encode imported source")
            return
        }
        defaults.set(data, forKey: CustomAudioSourceStore.storeKey)
        defaults.set("TEST-KEY-123", forKey: "settings.ikunApiKey")

        let store = CustomAudioSourceStore(defaults: defaults)
        #expect(store.sources.first?.script == script)
        #expect(defaults.string(forKey: "settings.ikunApiKey") == nil)
    }

    /// A non-ikun script is untouched, and the legacy key is dropped.
    @Test @MainActor func migrationSkipsNonIkunScripts() {
        let suite = "com.test.LegacyKeyMigrationOtherTests"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not create test UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let script = "const API_KEY = \"\";"
        let source = CustomAudioSource(name: "Other", kind: "script", template: "", script: script)
        guard let data = try? JSONEncoder().encode([source]) else {
            Issue.record("could not encode imported source")
            return
        }
        defaults.set(data, forKey: CustomAudioSourceStore.storeKey)
        defaults.set("TEST-KEY-123", forKey: "settings.ikunApiKey")

        let store = CustomAudioSourceStore(defaults: defaults)
        // The "Other" script carries no ikun host, so both built-in
        // seeds append behind it; the legacy key is still dropped.
        #expect(store.sources.count == 3)
        #expect(store.sources.first(where: { $0.name == "Other" })?.script == script)
        #expect(defaults.string(forKey: "settings.ikunApiKey") == nil)
    }

    // MARK: - Runner (stub script, no network)

    /// A stub LX script that answers `musicUrl` with a constant URL
    /// without touching the network. Never a real user script: no
    /// secrets, no backend, no network call.
    private static let stubScript = """
    const {EVENT_NAMES, on, send} = globalThis.lx;
    on(EVENT_NAMES.request, ({action, source, info}) => {
        if (action === "musicUrl") {
            return Promise.resolve("https://example.com/song.mp3");
        }
        return Promise.reject("unsupported action");
    });
    send(EVENT_NAMES.inited, {status: true, sources: {wy: {name: "wy", type: "music", actions: ["musicUrl"], qualitys: ["320k"]}}});
    """

    @Test func runnerResolvesStubScriptWithoutNetwork() async {
        let source = CustomAudioSource(name: "Stub", kind: "script", template: "", script: Self.stubScript)
        let url = await LXScriptRunner.shared.resolve(
            source: source,
            songSource: .netease,
            songID: "123",
            name: "Test Song",
            artists: "Test Artist",
            quality: "320k"
        )
        #expect(url?.absoluteString == "https://example.com/song.mp3")
    }

    @Test func runnerReturnsNilForBrokenScript() async {
        let source = CustomAudioSource(name: "Broken", kind: "script", template: "", script: "this is not valid js {{{")
        let url = await LXScriptRunner.shared.resolve(
            source: source,
            songSource: .netease,
            songID: "123",
            name: "Test Song",
            artists: "Test Artist",
            quality: "320k"
        )
        #expect(url == nil)
    }

    @Test func runnerReturnsNilForScriptWithoutEntryPoint() async {
        let source = CustomAudioSource(name: "NoEntry", kind: "script", template: "", script: "const x = 1;")
        let url = await LXScriptRunner.shared.resolve(
            source: source,
            songSource: .netease,
            songID: "123",
            name: "Test Song",
            artists: "Test Artist",
            quality: "320k"
        )
        #expect(url == nil)
    }

    // MARK: - Declared platform chips (display-only)

    @Test func platformMappingCoversKnownIds() {
        #expect(LXScriptSourcePlatform.displayName(for: "wy") == "网易")
        #expect(LXScriptSourcePlatform.displayName(for: "tx") == "QQ")
        #expect(LXScriptSourcePlatform.displayName(for: "kg") == "酷狗")
        #expect(LXScriptSourcePlatform.displayName(for: "kw") == "酷我")
        #expect(LXScriptSourcePlatform.displayName(for: "mg") == "咪咕")
        // Unmapped ids render as raw-id chips, never guessed names:
        // `git` is an extra key in the ikun script; 汽水 / 哔哩
        // have no grounded source id at all.
        #expect(LXScriptSourcePlatform.displayName(for: "git") == nil)
        #expect(LXScriptSourcePlatform.displayName(for: "qishui") == nil)
        #expect(LXScriptSourcePlatform.displayName(for: "bilibili") == nil)
        #expect(LXScriptSourcePlatform.displayName(for: "") == nil)
    }

    @Test func platformAllDeclaredRequiresAllFive() {
        #expect(LXScriptSourcePlatform.allDeclared(["wy", "tx", "kg", "kw", "mg"]) == true)
        #expect(LXScriptSourcePlatform.allDeclared(["wy", "tx", "kg", "kw"]) == false)
        #expect(LXScriptSourcePlatform.allDeclared([]) == false)
        // Extra unknown ids do not complete the set.
        #expect(LXScriptSourcePlatform.allDeclared(["wy", "tx", "kg", "kw", "git"]) == false)
    }

    @Test @MainActor func declaredPlatformsCacheRoundTripsAndClearsOnRemove() {
        let suite = "com.test.DeclaredPlatformsTests"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not create test UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let source = CustomAudioSource(name: "Cache", kind: "script", template: "", script: "const x = 1;")
        let store = CustomAudioSourceStore(defaults: defaults)
        #expect(store.declaredPlatforms(for: source.id) == nil)
        store.noteDeclaredPlatforms(["wy", "tx"], for: source.id)
        #expect(store.declaredPlatforms(for: source.id) == ["tx", "wy"])

        let reloaded = CustomAudioSourceStore(defaults: defaults)
        #expect(reloaded.declaredPlatforms(for: source.id) == ["tx", "wy"])

        store.addSource(source)
        #expect(store.removeSource(id: source.id) == true)
        #expect(store.declaredPlatforms(for: source.id) == nil)
    }

    /// A script whose `inited` payload declares wy + kw: the
    /// runtime's `receive` caches the ids on the shared store, so
    /// the editor chips can show them. The source must be in the
    /// shared store for the note to land (test stubs are skipped).
    private static let probeScript = """
    const {EVENT_NAMES, on, send} = globalThis.lx;
    on(EVENT_NAMES.request, ({action}) => Promise.reject("no"));
    send(EVENT_NAMES.inited, {status: true, sources: {wy: {name: "wy", type: "music", actions: ["musicUrl"], qualitys: ["320k"]}, kw: {name: "kw", type: "music", actions: ["musicUrl"], qualitys: ["320k"]}}});
    """

    @Test @MainActor func runtimeInitedCachesDeclaredPlatforms() async {
        let source = CustomAudioSource(name: "CacheProbe", kind: "script", template: "", script: Self.probeScript)
        let store = CustomAudioSourceStore.shared
        store.addSource(source)
        defer { _ = store.removeSource(id: source.id) }

        if LXScriptRuntime(source: source, script: Self.probeScript) == nil {
            Issue.record("could not create runtime")
            return
        }
        // `receive` hops to the main actor; poll briefly.
        let deadline = Date().addingTimeInterval(5)
        while store.declaredPlatforms(for: source.id) == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(store.declaredPlatforms(for: source.id) == ["kw", "wy"])
    }

    // MARK: - Kuwo fallback in customScriptResolve

    /// Rejects the NetEase leg and resolves the Kuwo leg: proves the
    /// kw attempt runs after wy fails. No network: the stub answers
    /// purely from the requested `source` code.
    private static let wyFailsKwResolvesScript = """
    const {EVENT_NAMES, on, send} = globalThis.lx;
    on(EVENT_NAMES.request, ({action, source, info}) => {
        if (action !== "musicUrl") return Promise.reject("unsupported action");
        if (source === "wy") return Promise.reject("no wy link");
        if (source === "kw") return Promise.resolve("https://example.com/kw-song.mp3");
        return Promise.reject("unsupported source");
    });
    send(EVENT_NAMES.inited, {status: true, sources: {wy: {name: "wy", type: "music", actions: ["musicUrl"], qualitys: ["320k"]}, kw: {name: "kw", type: "music", actions: ["musicUrl"], qualitys: ["320k"]}}});
    """

    private func jayChouQingTian() -> Track {
        Track(
            id: 186016, name: "晴天",
            artists: [ArtistRef(id: 0, name: "周杰伦")],
            album: AlbumRef(id: 0, name: "叶惠美", picUrl: nil),
            durationMS: 269_000, alias: [], transNames: [], fee: 0, mvID: 0,
            trackNo: 0, disc: nil, noCopyright: false, isCloud: false,
            embeddedPrivilege: nil
        )
    }

    @Test func kuwoSongSourceRawValue() {
        #expect(LXSongSource.kuwo.rawValue == "kw")
        #expect(LXSongSource(rawValue: "kw") == .kuwo)
    }

    @Test func customScriptResolveFallsBackToKuwoAfterNetEase() async {
        let source = CustomAudioSource(name: "KwFallback", kind: "script", template: "", script: Self.wyFailsKwResolvesScript)
        let url = await UnblockService.customScriptResolve(jayChouQingTian(), source: source)
        #expect(url?.absoluteString == "https://example.com/kw-song.mp3")
    }

    @Test func customScriptResolveUsesNetEaseFirst() async {
        let source = CustomAudioSource(name: "WyFirst", kind: "script", template: "", script: Self.stubScript)
        let url = await UnblockService.customScriptResolve(jayChouQingTian(), source: source)
        #expect(url?.absoluteString == "https://example.com/song.mp3")
    }

    // MARK: - Share import (.js / .txt opened into the app)

    private static let sharedScript = """
    /*!
     * @name Shared Source
     * @version v1
     */
    const {EVENT_NAMES, on} = globalThis.lx;
    on(EVENT_NAMES.request, ({action}) => Promise.reject("no"));
    """

    private static let unnamedScript = """
    const {EVENT_NAMES, on} = globalThis.lx;
    on(EVENT_NAMES.request, ({action}) => Promise.reject("no"));
    """

    @MainActor
    private func freshShareStore(suite: String) -> (CustomAudioSourceStore, UserDefaults)? {
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not create test UserDefaults suite")
            return nil
        }
        defaults.removePersistentDomain(forName: suite)
        return (CustomAudioSourceStore(defaults: defaults), defaults)
    }

    @Test @MainActor func shareImportAddsLXScript() {
        guard let (store, defaults) = freshShareStore(suite: "com.test.ShareImportTests") else { return }
        defer { defaults.removePersistentDomain(forName: "com.test.ShareImportTests") }

        #expect(store.sources.count == 2)
        let outcome = SharedAudioSourceImport.importScript(text: Self.sharedScript, fileName: "shared", store: store)
        #expect(outcome == .imported(name: "Shared Source"))
        #expect(store.sources.count == 3)
        #expect(store.sources.last?.name == "Shared Source")
        #expect(store.sources.last?.enabled == true)
    }

    @Test @MainActor func shareImportUsesFileNameWithoutNameHeader() {
        guard let (store, defaults) = freshShareStore(suite: "com.test.ShareImportFileNameTests") else { return }
        defer { defaults.removePersistentDomain(forName: "com.test.ShareImportFileNameTests") }

        let outcome = SharedAudioSourceImport.importScript(text: Self.unnamedScript, fileName: "my-script", store: store)
        #expect(outcome == .imported(name: "my-script"))
    }

    @Test @MainActor func shareImportRejectsGarbage() {
        guard let (store, defaults) = freshShareStore(suite: "com.test.ShareImportGarbageTests") else { return }
        defer { defaults.removePersistentDomain(forName: "com.test.ShareImportGarbageTests") }

        #expect(SharedAudioSourceImport.importScript(text: "hello world this is not a source", fileName: "x", store: store) == .invalid)
        #expect(store.sources.count == 2)
    }

    @Test @MainActor func shareImportDedupsByNameAndContent() {
        guard let (store, defaults) = freshShareStore(suite: "com.test.ShareImportDedupTests") else { return }
        defer { defaults.removePersistentDomain(forName: "com.test.ShareImportDedupTests") }

        #expect(SharedAudioSourceImport.importScript(text: Self.sharedScript, fileName: "shared", store: store) == .imported(name: "Shared Source"))
        #expect(store.sources.count == 3)
        #expect(SharedAudioSourceImport.importScript(text: Self.sharedScript, fileName: "shared", store: store) == .duplicate(name: "Shared Source"))
        #expect(store.sources.count == 3)
        // Same script text under a different file name: the parsed name
        // differs, but the content is identical, so it still dedups.
        #expect(SharedAudioSourceImport.importScript(text: Self.unnamedScript, fileName: "first", store: store) == .imported(name: "first"))
        #expect(store.sources.count == 4)
        #expect(SharedAudioSourceImport.importScript(text: Self.unnamedScript, fileName: "second", store: store) == .duplicate(name: "second"))
        #expect(store.sources.count == 4)
    }

    @Test @MainActor func shareImportFileURLReadsJsFileAndRejectsPy() {
        guard let (store, defaults) = freshShareStore(suite: "com.test.ShareImportFileTests") else { return }
        defer { defaults.removePersistentDomain(forName: "com.test.ShareImportFileTests") }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let jsURL = directory.appendingPathComponent("shared.js")
        let pyURL = directory.appendingPathComponent("shared.py")
        try? Self.sharedScript.write(to: jsURL, atomically: true, encoding: .utf8)
        try? Self.sharedScript.write(to: pyURL, atomically: true, encoding: .utf8)

        #expect(SharedAudioSourceImport.importFile(at: jsURL, store: store) == .imported(name: "Shared Source"))
        #expect(SharedAudioSourceImport.importFile(at: pyURL, store: store) == .invalid)
        #expect(store.sources.count == 3)
    }
}
