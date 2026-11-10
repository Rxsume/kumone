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
        store.addSources([source])
        // The built-in ikun source is always pinned first, so the
        // store holds two sources: builtin + the imported one.
        #expect(store.sources.count == 2)
        #expect(store.sources.first?.id == BuiltInAudioSources.ikunID)
        #expect(store.sources.first(where: { $0.id == source.id })?.name == "测试音源")

        let reloaded = CustomAudioSourceStore(defaults: defaults)
        #expect(reloaded.sources.count == 2)
        #expect(reloaded.sources.first?.id == BuiltInAudioSources.ikunID)
        #expect(reloaded.sources.first(where: { $0.id == source.id })?.script == source.script)

        reloaded.updateEnabled(id: source.id, enabled: false)
        #expect(reloaded.sources.first(where: { $0.id == source.id })?.enabled == false)
        #expect(reloaded.sources.first?.enabled == true)
        // The imported source is already last, so moving it down is
        // a no-op; the built-in source stays pinned at index 0.
        reloaded.moveSource(id: source.id, by: 1)
        #expect(reloaded.sources.count == 2)
        #expect(reloaded.sources.first(where: { $0.id == source.id }) != nil)
        #expect(reloaded.removeSource(id: source.id) == true)
        #expect(reloaded.sources.count == 1)
        #expect(reloaded.sources.first?.id == BuiltInAudioSources.ikunID)
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

    // MARK: - Built-in ikun source

    @Test func builtinScriptHasEmptyKeyPlaceholder() {
        #expect(BuiltInAudioSources.ikunScript.contains("const API_KEY = \"\""))
        #expect(BuiltInAudioSources.ikunScript.contains("@version v26"))
        // The request URL is built from the API_URL constant, not a
        // literal: `const API_URL = "https://c.wwwweb.top"` plus
        // `` `${API_URL}/music/url` `` in the fetch call.
        #expect(BuiltInAudioSources.ikunScript.contains("const API_URL = \"https://c.wwwweb.top\""))
        #expect(BuiltInAudioSources.ikunScript.contains("${API_URL}/music/url"))
    }

    @Test func builtinKeyInjectionReplacesPlaceholderOnly() {
        let source = BuiltInAudioSources.ikunSource()
        let effective = BuiltInAudioSources.effectiveScript(for: source, apiKey: "test-key-123")
        #expect(effective.contains("const API_KEY = \"test-key-123\""))
        #expect(!effective.contains("const API_KEY = \"\""))
        #expect(effective != BuiltInAudioSources.ikunScript)
    }

    @Test func builtinScriptWithoutKeyIsUnchanged() {
        let source = BuiltInAudioSources.ikunSource()
        #expect(BuiltInAudioSources.effectiveScript(for: source, apiKey: "") == BuiltInAudioSources.ikunScript)
        #expect(BuiltInAudioSources.effectiveScript(for: source, apiKey: nil) == BuiltInAudioSources.ikunScript)
    }

    @Test func keyInjectionSkipsNonBuiltinSources() {
        let other = CustomAudioSource(name: "Other", kind: "script", template: "", script: "const API_KEY = \"\";")
        #expect(BuiltInAudioSources.effectiveScript(for: other, apiKey: "test-key-123") == "const API_KEY = \"\";")
    }

    @Test func keyEscapingKeepsScriptValid() {
        let source = BuiltInAudioSources.ikunSource()
        let effective = BuiltInAudioSources.effectiveScript(for: source, apiKey: "a\"b\\c")
        #expect(effective.contains("const API_KEY = \"a\\\"b\\\\c\""))
    }

    @Test @MainActor func builtinIkunSourceIsEnsuredFirst() {
        let suite = "com.test.BuiltinIkunTests"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not create test UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = CustomAudioSourceStore(defaults: defaults)
        #expect(store.sources.count == 1)
        #expect(store.sources.first?.id == BuiltInAudioSources.ikunID)
        #expect(store.sources.first?.name == BuiltInAudioSources.ikunName)
        #expect(store.sources.first?.enabled == true)
        #expect(store.sources.first?.script == BuiltInAudioSources.ikunScript)
        #expect(store.hasEnabledScriptSources == true)
        #expect(store.removeSource(id: BuiltInAudioSources.ikunID) == false)
        #expect(store.sources.count == 1)
        store.updateEnabled(id: BuiltInAudioSources.ikunID, enabled: false)
        #expect(store.hasEnabledScriptSources == false)
    }

    @Test @MainActor func builtinIkunSkippedWhenSameNameAlreadyImported() {
        let suite = "com.test.BuiltinIkunNameGateTests"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not create test UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let imported = CustomAudioSource(
            name: BuiltInAudioSources.ikunName,
            kind: "script",
            template: "",
            script: "const x = 1;"
        )
        guard let data = try? JSONEncoder().encode([imported]) else {
            Issue.record("could not encode imported source")
            return
        }
        defaults.set(data, forKey: CustomAudioSourceStore.storeKey)

        let store = CustomAudioSourceStore(defaults: defaults)
        #expect(store.sources.count == 1)
        #expect(store.sources.first?.id != BuiltInAudioSources.ikunID)
    }

    @Test @MainActor func builtinIkunRefreshPreservesToggleAndQuality() {
        let suite = "com.test.BuiltinIkunRefreshTests"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not create test UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = CustomAudioSourceStore(defaults: defaults)
        var stale = BuiltInAudioSources.ikunSource(quality: "flac", enabled: false)
        stale.script = "const stale = true;"
        store.upsert(stale)

        let reloaded = CustomAudioSourceStore(defaults: defaults)
        #expect(reloaded.sources.count == 1)
        #expect(reloaded.sources.first?.script == BuiltInAudioSources.ikunScript)
        #expect(reloaded.sources.first?.quality == "flac")
        #expect(reloaded.sources.first?.enabled == false)
    }

    @Test func apiKeyInScriptExtractsKey() {
        #expect(BuiltInAudioSources.apiKeyInScript("const API_KEY = \"TEST-KEY-123\";") == "TEST-KEY-123")
        #expect(BuiltInAudioSources.apiKeyInScript("const API_KEY = \"\";") == nil)
        #expect(BuiltInAudioSources.apiKeyInScript("const x = 1;") == nil)
        #expect(BuiltInAudioSources.apiKeyInScript(nil) == nil)
        #expect(BuiltInAudioSources.apiKeyInScript(BuiltInAudioSources.ikunScript) == nil)
    }

    @Test @MainActor func storeAdoptsSameNamedImportedIkunSource() {
        let suite = "com.test.BuiltinIkunAdoptionTests"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not create test UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        // An imported copy of the v26 script: same @name, same
        // backend, key still inside the text. (TEST-KEY-123 is a
        // fake placeholder for this test, never a real key.)
        let imported = CustomAudioSource(
            name: BuiltInAudioSources.ikunName,
            kind: "script",
            template: "",
            quality: "flac",
            script: """
            const API_URL = "https://c.wwwweb.top";
            const API_KEY = "TEST-KEY-123";
            """,
            enabled: false
        )
        guard let data = try? JSONEncoder().encode([imported]) else {
            Issue.record("could not encode imported source")
            return
        }
        defaults.set(data, forKey: CustomAudioSourceStore.storeKey)

        let store = CustomAudioSourceStore(defaults: defaults)
        #expect(store.sources.count == 1)
        #expect(store.sources.first?.id == BuiltInAudioSources.ikunID)
        #expect(store.sources.first?.name == BuiltInAudioSources.ikunName)
        #expect(store.sources.first?.script == BuiltInAudioSources.ikunScript)
        #expect(store.sources.first?.quality == "flac")
        #expect(store.sources.first?.enabled == false)
        #expect(defaults.string(forKey: BuiltInAudioSources.apiKeyDefaultsKey) == "TEST-KEY-123")
        #expect(store.removeSource(id: BuiltInAudioSources.ikunID) == false)
    }

    @Test @MainActor func storeAdoptsSameNamedImportedIkunSourceWithoutKey() {
        let suite = "com.test.BuiltinIkunAdoptionNoKeyTests"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not create test UserDefaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let imported = CustomAudioSource(
            name: BuiltInAudioSources.ikunName,
            kind: "script",
            template: "",
            script: """
            const API_URL = "https://c.wwwweb.top";
            const API_KEY = "";
            """
        )
        guard let data = try? JSONEncoder().encode([imported]) else {
            Issue.record("could not encode imported source")
            return
        }
        defaults.set(data, forKey: CustomAudioSourceStore.storeKey)

        let store = CustomAudioSourceStore(defaults: defaults)
        #expect(store.sources.count == 1)
        #expect(store.sources.first?.id == BuiltInAudioSources.ikunID)
        #expect(store.sources.first?.script == BuiltInAudioSources.ikunScript)
        #expect(defaults.string(forKey: BuiltInAudioSources.apiKeyDefaultsKey) == nil)
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

        #expect(store.sources.count == 1)
        let outcome = SharedAudioSourceImport.importScript(text: Self.sharedScript, fileName: "shared", store: store)
        #expect(outcome == .imported(name: "Shared Source"))
        #expect(store.sources.count == 2)
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
        #expect(store.sources.count == 1)
    }

    @Test @MainActor func shareImportDedupsByNameAndContent() {
        guard let (store, defaults) = freshShareStore(suite: "com.test.ShareImportDedupTests") else { return }
        defer { defaults.removePersistentDomain(forName: "com.test.ShareImportDedupTests") }

        #expect(SharedAudioSourceImport.importScript(text: Self.sharedScript, fileName: "shared", store: store) == .imported(name: "Shared Source"))
        #expect(store.sources.count == 2)
        #expect(SharedAudioSourceImport.importScript(text: Self.sharedScript, fileName: "shared", store: store) == .duplicate(name: "Shared Source"))
        #expect(store.sources.count == 2)
        // Same script text under a different file name: the parsed name
        // differs, but the content is identical, so it still dedups.
        #expect(SharedAudioSourceImport.importScript(text: Self.unnamedScript, fileName: "first", store: store) == .imported(name: "first"))
        #expect(store.sources.count == 3)
        #expect(SharedAudioSourceImport.importScript(text: Self.unnamedScript, fileName: "second", store: store) == .duplicate(name: "second"))
        #expect(store.sources.count == 3)
    }

    @Test @MainActor func shareImportSkipsBuiltinIkun() {
        guard let (store, defaults) = freshShareStore(suite: "com.test.ShareImportBuiltinTests") else { return }
        defer { defaults.removePersistentDomain(forName: "com.test.ShareImportBuiltinTests") }

        let outcome = SharedAudioSourceImport.importScript(text: BuiltInAudioSources.ikunScript, fileName: "ikun", store: store)
        #expect(outcome == .duplicate(name: BuiltInAudioSources.ikunName))
        #expect(store.sources.count == 1)
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
        #expect(store.sources.count == 2)
    }
}
