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
        #expect(store.sources.count == 1)

        let reloaded = CustomAudioSourceStore(defaults: defaults)
        #expect(reloaded.sources.count == 1)
        #expect(reloaded.sources.first?.name == "测试音源")
        #expect(reloaded.sources.first?.script == source.script)

        reloaded.updateEnabled(id: source.id, enabled: false)
        #expect(reloaded.sources.first?.enabled == false)
        reloaded.moveSource(id: source.id, by: 1)
        #expect(reloaded.sources.count == 1)
        #expect(reloaded.removeSource(id: source.id) == true)
        #expect(reloaded.sources.isEmpty)
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
}
