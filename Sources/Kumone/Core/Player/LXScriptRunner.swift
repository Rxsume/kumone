import CommonCrypto
import CryptoKit
import Foundation
import JavaScriptCore
import os.log

/// LX Music-style script source runner, ported from Beans'
/// `LXScriptSourceRunner.swift`.
///
/// One `JSContext` per source script, confined to that runtime's
/// serial queue (`JSContext` is not thread-safe). The native side is
/// an `NSObject` conforming to `JSExport` protocols, installed as the
/// JS global `lx`. Scripts can only reach the network through
/// `lx.request` (and the `fetch`/`customFetch` wrappers around it);
/// there is no file-system, Keychain, pasteboard, or native-API
/// access.
///
/// Concurrency audit (Swift 6): the bridge classes are plain
/// `NSObject` subclasses. They are marked `@unchecked Sendable`
/// because every `JSValue` they touch is only ever touched on the
/// owning runtime's serial queue — `request`'s URLSession completion
/// hops back onto that queue before calling the JS callback (via the
/// `LXScriptCallbackBox` carrier), and all bridge state is immutable
/// after `init` except the `weak runtime` back-reference, which is
/// only read from JS on the runtime queue. `LXScriptRuntime`'s
/// `handlers` dict is likewise only mutated/read on its queue, and
/// `invokeRequest`'s result crosses the semaphore boundary behind an
/// `NSLock`. `LXScriptRunner`'s cache is only touched on its serial
/// `runtimeQueue`.
///
/// Debug logs record source names/ids only, never script text.
@objc protocol LXScriptBufferExports: JSExport {
    func from(_ text: String, _ encoding: String) -> NSDictionary
    func bufToString(_ buffer: JSValue?, _ encoding: String) -> String
}

@objc protocol LXScriptUtilsExports: JSExport {
    var buffer: LXScriptBufferBridge { get }
    var crypto: LXScriptCryptoBridge { get }
}

@objc protocol LXScriptCryptoExports: JSExport {
    func md5(_ value: String) -> String
    func aesEncrypt(_ data: String, _ mode: String, _ key: String, _ iv: String) -> NSDictionary
}

@objc protocol LXScriptBridgeExports: JSExport {
    func request(_ url: String, _ options: JSValue?, _ callback: JSValue?)
    func on(_ event: String, _ handler: JSValue)
    func send(_ event: String, _ payload: JSValue?)
    var EVENT_NAMES: NSDictionary { get }
    var env: NSDictionary { get }
    var utils: LXScriptUtilsBridge { get }
    var version: String { get }
    var currentScriptInfo: NSDictionary { get }
}

@objc protocol LXScriptDoneExports: JSExport {
    func resolve(_ value: JSValue?)
    func reject(_ value: JSValue?)
}

/// A JS callback carried across the `URLSession` completion boundary.
/// The wrapped `JSValue` is only ever invoked on the owning runtime's
/// serial queue; the box itself is just a carrier.
private final class LXScriptCallbackBox: @unchecked Sendable {
    let value: JSValue
    init(_ value: JSValue) { self.value = value }
}

final class LXScriptBufferBridge: NSObject, LXScriptBufferExports, @unchecked Sendable {
    func from(_ text: String, _ encoding: String) -> NSDictionary {
        Self.dictionary(for: data(from: text, encoding: encoding))
    }

    func bufToString(_ buffer: JSValue?, _ encoding: String) -> String {
        guard let data = data(from: buffer) else {
            return buffer?.toString() ?? ""
        }
        switch encoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "base64":
            return data.base64EncodedString()
        case "hex":
            return data.map { String(format: "%02x", $0) }.joined()
        case "utf-8", "utf8":
            return String(data: data, encoding: .utf8) ?? ""
        default:
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    static func dictionary(for data: Data) -> NSDictionary {
        [
            "__beansBuffer": true,
            "base64": data.base64EncodedString(),
            "hex": data.map { String(format: "%02x", $0) }.joined(),
            "text": String(data: data, encoding: .utf8) ?? ""
        ]
    }

    private func data(from text: String, encoding: String) -> Data {
        switch encoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "base64":
            return Data(base64Encoded: text, options: [.ignoreUnknownCharacters]) ?? Data()
        case "hex":
            var value = text
                .replacingOccurrences(of: "0x", with: "")
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
            if !value.count.isMultiple(of: 2) {
                value = "0" + value
            }
            var result = Data()
            var index = value.startIndex
            while index < value.endIndex {
                let next = value.index(index, offsetBy: 2)
                if let byte = UInt8(value[index..<next], radix: 16) {
                    result.append(byte)
                }
                index = next
            }
            return result
        default:
            return Data(text.utf8)
        }
    }

    private func data(from buffer: JSValue?) -> Data? {
        guard let object = buffer?.toObject() else { return nil }
        let dictionary: [String: Any]
        if let value = object as? [String: Any] {
            dictionary = value
        } else if let value = object as? NSDictionary {
            dictionary = value.reduce(into: [String: Any]()) { result, pair in
                if let key = pair.key as? String {
                    result[key] = pair.value
                }
            }
        } else if let text = object as? String {
            return Data(text.utf8)
        } else {
            return nil
        }

        if let base64 = dictionary["base64"] as? String,
           let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]) {
            return data
        }
        if let hex = dictionary["hex"] as? String {
            return data(from: hex, encoding: "hex")
        }
        if let text = dictionary["text"] as? String {
            return Data(text.utf8)
        }
        return nil
    }
}

final class LXScriptUtilsBridge: NSObject, LXScriptUtilsExports, @unchecked Sendable {
    let buffer = LXScriptBufferBridge()
    let crypto = LXScriptCryptoBridge()
}

final class LXScriptCryptoBridge: NSObject, LXScriptCryptoExports, @unchecked Sendable {
    func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func aesEncrypt(_ data: String, _ mode: String, _ key: String, _ iv: String) -> NSDictionary {
        let input = Data(data.utf8)
        let keyData = normalize(Data(key.utf8))
        let ivData = normalize(Data(iv.utf8))
        let usesECB = mode.lowercased().contains("ecb")
        let options = usesECB
            ? CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode)
            : CCOptions(kCCOptionPKCS7Padding)

        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var outputLength: size_t = 0
        let status = keyData.withUnsafeBytes { keyBytes in
            ivData.withUnsafeBytes { ivBytes in
                input.withUnsafeBytes { inputBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        options,
                        keyBytes.baseAddress,
                        keyData.count,
                        usesECB ? nil : ivBytes.baseAddress,
                        inputBytes.baseAddress,
                        input.count,
                        &output,
                        output.count,
                        &outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            return LXScriptBufferBridge.dictionary(for: Data())
        }
        return LXScriptBufferBridge.dictionary(for: Data(output.prefix(outputLength)))
    }

    private func normalize(_ data: Data) -> Data {
        if data.count == kCCKeySizeAES128 {
            return data
        }
        if data.count > kCCKeySizeAES128 {
            return data.prefix(kCCKeySizeAES128)
        }
        return data + Data(repeating: 0, count: kCCKeySizeAES128 - data.count)
    }
}

final class LXScriptDoneBridge: NSObject, LXScriptDoneExports, @unchecked Sendable {
    var onResolve: ((Any?) -> Void)?
    var onReject: ((String) -> Void)?
    private var finished = false

    func resolve(_ value: JSValue?) {
        guard !finished else { return }
        finished = true
        onResolve?(value?.toObject())
    }

    func reject(_ value: JSValue?) {
        guard !finished else { return }
        finished = true
        onReject?(value?.toString() ?? "Script rejected")
    }
}

final class LXScriptBridge: NSObject, LXScriptBridgeExports, @unchecked Sendable {
    private let runtimeQueue: DispatchQueue
    private let session: URLSession
    weak var runtime: LXScriptRuntime?

    let EVENT_NAMES: NSDictionary = [
        "request": "request",
        "inited": "inited",
        "updateAlert": "updateAlert"
    ]

    let env: NSDictionary = [
        "platform": "ios",
        "os": "iOS",
        "device": "iPhone",
        "isMobile": true
    ]

    let utils = LXScriptUtilsBridge()
    let version: String
    let currentScriptInfo: NSDictionary

    init(runtimeQueue: DispatchQueue, source: CustomAudioSource, script: String) {
        self.runtimeQueue = runtimeQueue
        self.version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.3.29"
        self.currentScriptInfo = [
            "name": source.name,
            "version": source.headers["version"] ?? "",
            "rawScript": script
        ]
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    func request(_ url: String, _ options: JSValue?, _ callback: JSValue?) {
        guard let callback else { return }
        let callbackBox = LXScriptCallbackBox(callback)
        let requestOptions = dictionary(from: options?.toObject())
        guard let requestURL = URL(string: url) else {
            runtimeQueue.async {
                callbackBox.value.call(withArguments: [[ "message": "Invalid URL" ], NSNull()])
            }
            return
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = (requestOptions["method"] as? String)?.uppercased() ?? "GET"
        if let timeout = requestOptions["timeout"] as? NSNumber {
            request.timeoutInterval = timeout.doubleValue / 1000.0 > 0 ? timeout.doubleValue / 1000.0 : request.timeoutInterval
        } else if let timeout = requestOptions["timeout"] as? Double {
            request.timeoutInterval = timeout > 0 ? timeout / 1000.0 : request.timeoutInterval
        }

        let headers = dictionary(from: requestOptions["headers"])
        if !headers.isEmpty {
            for (key, value) in headers {
                request.setValue(String(describing: value), forHTTPHeaderField: key)
            }
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("lx-music", forHTTPHeaderField: "User-Agent")
        }
        if let body = requestOptions["body"] {
            if let bodyData = body as? Data {
                request.httpBody = bodyData
            } else if let string = body as? String {
                request.httpBody = string.data(using: .utf8)
            } else {
                let dict = dictionary(from: body)
                if dict["__beansBuffer"] as? Bool == true,
                   let base64 = dict["base64"] as? String {
                    request.httpBody = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters])
                } else if JSONSerialization.isValidJSONObject(dict),
                          let data = try? JSONSerialization.data(withJSONObject: dict) {
                    request.httpBody = data
                    if request.value(forHTTPHeaderField: "Content-Type") == nil {
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    }
                }
            }
        }

        // Only Sendable values cross into the completion handler: the
        // response type is pre-extracted, and the JS callback travels
        // in its box. The callback is invoked back on the runtime
        // queue, never on the URLSession thread.
        let responseType = requestOptions["responseType"] as? String
        let queue = runtimeQueue
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            queue.async {
                if let error {
                    callbackBox.value.call(withArguments: [[ "message": error.localizedDescription ], NSNull()])
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    callbackBox.value.call(withArguments: [[ "message": "No HTTP response" ], NSNull()])
                    return
                }
                let parsed = self.parseBody(data)
                let body: Any = responseType?.lowercased() == "text" ? parsed.text : parsed.value
                let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                    result[String(describing: pair.key)] = String(describing: pair.value)
                }
                let responseObject: [String: Any] = [
                    "statusCode": http.statusCode,
                    "headers": headers,
                    "body": body,
                    "bodyText": parsed.text,
                    "ok": (200..<300).contains(http.statusCode)
                ]
                if http.statusCode >= 400 {
                    callbackBox.value.call(withArguments: [[ "message": "HTTP \(http.statusCode)" ], responseObject])
                } else {
                    callbackBox.value.call(withArguments: [NSNull(), responseObject])
                }
            }
        }.resume()
    }

    func on(_ event: String, _ handler: JSValue) {
        runtime?.register(handler: handler, for: event)
    }

    func send(_ event: String, _ payload: JSValue?) {
        runtime?.receive(event: event, payload: payload?.toObject())
    }

    private func parseBody(_ data: Data?) -> (value: Any, text: String) {
        guard let data else { return (NSNull(), "") }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? data.base64EncodedString()
        if let json = try? JSONSerialization.jsonObject(with: data) {
            return (json, text)
        }
        return (text, text)
    }

    private func dictionary(from raw: Any?) -> [String: Any] {
        if let value = raw as? [String: Any] {
            return value
        }
        if let value = raw as? NSDictionary {
            return value.reduce(into: [String: Any]()) { result, pair in
                if let key = pair.key as? String {
                    result[key] = pair.value
                }
            }
        }
        return [:]
    }
}

final class LXScriptRuntime: @unchecked Sendable {
    private static let log = Logger(subsystem: "sb.moe.kumone", category: "audio-source")

    private let sourceID: String
    private let queue = DispatchQueue(label: "sb.moe.kumone.LXScriptRuntime")
    private let context: JSContext
    private let bridge: LXScriptBridge
    private var handlers: [String: JSValue] = [:]

    init?(source: CustomAudioSource, script: String) {
        sourceID = source.id
        guard let context = JSContext() else { return nil }
        self.context = context
        self.bridge = LXScriptBridge(runtimeQueue: queue, source: source, script: script)
        self.bridge.runtime = self

        context.exceptionHandler = { _, exception in
            if let exception {
                Self.log.debug("custom script exception: \(exception, privacy: .public)")
            }
        }

        context.setObject(bridge, forKeyedSubscript: "lx" as NSString)
        var initialized = false
        queue.sync {
            context.evaluateScript("if (typeof globalThis === 'undefined') { var globalThis = this; }")
            context.evaluateScript("if (typeof global === 'undefined') { globalThis.global = globalThis; }")
            context.evaluateScript("if (typeof self === 'undefined') { globalThis.self = globalThis; }")
            context.evaluateScript("if (typeof globalThis.lx === 'undefined') { globalThis.lx = lx; }")
            // Full no-op console: LX scripts call group/groupEnd
            // (ikun calls console.groupEnd() on every musicUrl, Golia
            // calls console.group() when env !== 'mobile') and a
            // missing method throws, rejecting the whole invocation —
            // every built-in script failed to resolve any track until
            // these were added. The list covers the methods scripts
            // in the wild use; anything else stays undefined, as in
            // a bare JSContext.
            context.evaluateScript("if (typeof console === 'undefined') { globalThis.console = { log: function() {}, info: function() {}, debug: function() {}, warn: function() {}, error: function() {}, group: function() {}, groupEnd: function() {}, groupCollapsed: function() {}, table: function() {}, trace: function() {}, time: function() {}, timeEnd: function() {}, timeLog: function() {}, count: function() {}, countReset: function() {}, assert: function() {}, clear: function() {}, dir: function() {}, dirxml: function() {} }; }")
            context.evaluateScript("if (typeof module === 'undefined') { var module = { exports: {} }; var exports = module.exports; }")
            context.evaluateScript("""
            (function() {
                var nativeLX = globalThis.lx || lx;
                var beansEnv = {
                    platform: nativeLX.env && nativeLX.env.platform ? nativeLX.env.platform : 'ios',
                    os: nativeLX.env && nativeLX.env.os ? nativeLX.env.os : 'iOS',
                    device: nativeLX.env && nativeLX.env.device ? nativeLX.env.device : 'iPhone',
                    isMobile: true
                };
                beansEnv.toString = function() {
                    return String(this.platform || 'ios');
                };
                globalThis.lx = {
                    EVENT_NAMES: nativeLX.EVENT_NAMES,
                    env: beansEnv,
                    utils: nativeLX.utils,
                    version: nativeLX.version,
                    currentScriptInfo: nativeLX.currentScriptInfo,
                    on: function(event, handler) {
                        return nativeLX.on(event, handler);
                    },
                    send: function(event, payload) {
                        return nativeLX.send(event, payload);
                    },
                    request: function(url, options, callback) {
                        if (typeof options === 'function') {
                            callback = options;
                            options = {};
                        }
                        if (typeof callback === 'function') {
                            return nativeLX.request(url, options || {}, callback);
                        }
                        return new Promise(function(resolve, reject) {
                            nativeLX.request(url, options || {}, function(error, response) {
                                if (error && error.message) reject(error);
                                else resolve(response);
                            });
                        });
                    }
                };
                if (typeof globalThis.fetch !== 'function') {
                    globalThis.fetch = function(url, options) {
                        return globalThis.lx.request(url, options || {}).then(function(response) {
                            return {
                                ok: response.ok,
                                status: response.statusCode,
                                statusCode: response.statusCode,
                                headers: response.headers,
                                text: function() {
                                    return Promise.resolve(response.bodyText || String(response.body || ''));
                                },
                                json: function() {
                                    return Promise.resolve(
                                        typeof response.body === 'string'
                                            ? JSON.parse(response.body)
                                            : response.body
                                    );
                                }
                            };
                        });
                    };
                }
                if (typeof globalThis.customFetch !== 'function') {
                    globalThis.customFetch = function(url, options) {
                        return globalThis.lx.request(url, options || {}).then(function(response) {
                            if (response && typeof response.bodyText === 'string') {
                                return response.bodyText;
                            }
                            if (response && typeof response.body === 'string') {
                                return response.body;
                            }
                            return JSON.stringify(response && response.body ? response.body : {});
                        });
                    };
                }
                if (typeof globalThis.Buffer === 'undefined') {
                    var makeBeansBuffer = function(value, encoding) {
                        if (value && value.__beansBuffer) {
                            return value;
                        }
                        var text = value === null || typeof value === 'undefined'
                            ? ''
                            : String(value);
                        var buffer = nativeLX.utils.buffer.from(text, encoding || 'utf8');
                        buffer.toString = function(outputEncoding) {
                            return nativeLX.utils.buffer.bufToString(buffer, outputEncoding || 'utf8');
                        };
                        return buffer;
                    };
                    globalThis.Buffer = {
                        from: makeBeansBuffer,
                        isBuffer: function(value) {
                            return !!(value && value.__beansBuffer);
                        }
                    };
                }
                if (typeof Promise.any !== 'function') {
                    Promise.any = function(iterable) {
                        return new Promise(function(resolve, reject) {
                            var values = Array.prototype.slice.call(iterable || []);
                            if (!values.length) {
                                reject(new Error('All promises were rejected'));
                                return;
                            }
                            var pending = values.length;
                            var errors = [];
                            values.forEach(function(value, index) {
                                Promise.resolve(value).then(resolve, function(error) {
                                    errors[index] = error;
                                    pending -= 1;
                                    if (pending === 0) {
                                        reject(new Error('All promises were rejected'));
                                    }
                                });
                            });
                        });
                    };
                }
                if (!JSON.__beansOriginalParse) {
                    JSON.__beansOriginalParse = JSON.parse;
                    JSON.parse = function(value) {
                        return value !== null && typeof value === 'object'
                            ? value
                            : JSON.__beansOriginalParse(value);
                    };
                }
            })();
            """)
            context.evaluateScript("globalThis.cerumusic = { request: function(url, options, callback) { return globalThis.lx.request(url, options, callback); }, utils: globalThis.lx.utils, env: globalThis.lx.env, version: globalThis.lx.version, currentScriptInfo: globalThis.lx.currentScriptInfo, NoticeCenter: function() {}, stopRequests: function() {} }; ")
            _ = context.evaluateScript(script)
            if context.exception == nil {
                _ = context.evaluateScript("globalThis.__beansPlugin = module.exports;")
                _ = context.evaluateScript("globalThis.__beansMusicPlugin = globalThis.MusicPlugin || {};")
                initialized = context.exception == nil
            }
        }
        if !initialized { return nil }
    }

    func register(handler: JSValue, for event: String) {
        handlers[event] = handler
    }

    func receive(event: String, payload: Any?) {
        guard event == "inited" else { return }
        // The script declares the platforms it supports in the
        // `sources` dictionary (keys are LX source ids, e.g. wy/tx).
        // Record them for the editor's "支持平台" chips (display
        // only — resolve never reads this cache).
        var ids: [String]?
        if let dict = payload as? [String: Any], let sources = dict["sources"] as? [String: Any] {
            ids = sources.keys.sorted()
        } else if let dict = payload as? NSDictionary,
                  let sources = dict["sources"] as? NSDictionary {
            ids = sources.allKeys.compactMap { $0 as? String }.sorted()
        }
        guard let ids else { return }
        Self.log.debug("custom script initialised: \(self.sourceID, privacy: .public) sources=\(ids.joined(separator: ","), privacy: .public)")
        let id = sourceID
        Task { @MainActor in
            // Only remember ids for sources the user actually has:
            // test stubs and one-off runtimes must not pollute the
            // persisted cache with ids no editor will ever look up.
            let store = CustomAudioSourceStore.shared
            guard store.sources.contains(where: { $0.id == id }) else { return }
            store.noteDeclaredPlatforms(ids, for: id)
        }
    }

    func invokeRequest(payload: [String: Any], timeout: TimeInterval = 12) -> Any? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Any?
        let resultLock = NSLock()
        let done = LXScriptDoneBridge()
        done.onResolve = { value in
            resultLock.lock()
            result = value
            resultLock.unlock()
            semaphore.signal()
        }
        done.onReject = { _ in
            semaphore.signal()
        }

        queue.async {
            let handler = self.handlers["request"]
            let resolverKind = self.context.evaluateScript("""
            (function() {
                if (typeof __beansPlugin !== 'undefined' && typeof __beansPlugin.musicUrl === 'function') {
                    return 'musicUrl';
                }
                if (typeof __beansMusicPlugin !== 'undefined' && typeof __beansMusicPlugin.getMusicUrl === 'function') {
                    return 'musicPluginGetMusicUrl';
                }
                if (typeof __beansPlugin !== 'undefined' && typeof __beansPlugin.getMusicUrl === 'function') {
                    return 'pluginGetMusicUrl';
                }
                return '';
            })()
            """)?.toString() ?? ""
            guard handler != nil || !resolverKind.isEmpty else {
                Self.log.debug("custom script has no musicUrl entry point: \(self.sourceID, privacy: .public)")
                semaphore.signal()
                return
            }
            if let handler {
                self.context.setObject(handler, forKeyedSubscript: "__beansHandler" as NSString)
            }
            self.context.setObject(payload as NSDictionary, forKeyedSubscript: "__beansPayload" as NSString)
            self.context.setObject(done, forKeyedSubscript: "__beansDone" as NSString)
            let invocation: String
            if handler != nil {
                invocation = "__beansHandler(__beansPayload)"
            } else {
                switch resolverKind {
                case "musicPluginGetMusicUrl":
                    invocation = "__beansMusicPlugin.getMusicUrl(__beansPayload.source, __beansPayload.info.musicInfo.musicId || __beansPayload.info.musicInfo.songmid || __beansPayload.info.musicInfo.id, __beansPayload.info.type)"
                case "pluginGetMusicUrl":
                    invocation = "__beansPlugin.getMusicUrl(__beansPayload.source, __beansPayload.info.musicInfo.musicId || __beansPayload.info.musicInfo.songmid || __beansPayload.info.musicInfo.id, __beansPayload.info.type)"
                default:
                    invocation = "__beansPlugin.musicUrl(__beansPayload.source, __beansPayload.info.musicInfo, __beansPayload.info.type)"
                }
            }
            _ = self.context.evaluateScript("""
            (function() {
                try {
                    Promise.resolve(
                        \(invocation)
                    ).then(
                        function(value) { __beansDone.resolve(value); },
                        function(error) { __beansDone.reject(error && error.message ? error.message : String(error)); }
                    );
                } catch (error) {
                    __beansDone.reject(error && error.message ? error.message : String(error));
                }
            })();
            """)
            if self.context.exception != nil {
                Self.log.debug("custom script invocation exception: \(self.sourceID, privacy: .public)")
                semaphore.signal()
            }
        }

        let deadline = DispatchTime.now() + timeout
        if semaphore.wait(timeout: deadline) == .timedOut {
            Self.log.debug("custom script invocation timed out: \(self.sourceID, privacy: .public) \(Int(timeout), privacy: .public)s")
        }
        resultLock.lock()
        let finalResult = result
        resultLock.unlock()
        return finalResult
    }
}

/// LX provider code for the script payload: `wy` NetEase, `tx` QQ,
/// `kg` Kugou, `kw` Kuwo. (Beans calls this `SongSource`; Golia has
/// no such type, so the runner defines its own.) Only codes the
/// backend accepts are listed: `mg`/`git`/`qs`/`bi`/`qishui`/
/// `bilibili` are all rejected by the backend (code 500
/// "unsupported source") and deliberately have no case here.
enum LXSongSource: String, Sendable {
    case netease = "wy"
    case qq = "tx"
    case kugou = "kg"
    case kuwo = "kw"
}

final class LXScriptRunner: @unchecked Sendable {
    static let shared = LXScriptRunner()

    private let runtimeQueue = DispatchQueue(label: "sb.moe.kumone.LXScriptRunner")
    private var cache: [String: LXScriptRuntime] = [:]

    private init() {}

    /// Asks the script for a playback URL. Returns nil when the script
    /// has a syntax error, has no `musicUrl` entry point, rejects, or
    /// times out (12 s). Never touches the network itself — any
    /// network call happens inside the script via `lx.request`.
    /// The `musicInfo` payload is deliberately over-populated so
    /// scripts written against any LX variant find their field.
    func resolve(
        source: CustomAudioSource,
        songSource: LXSongSource,
        songID: String,
        qqMid: String? = nil,
        qqMediaMid: String? = nil,
        kugouID: String? = nil,
        name: String,
        artists: String,
        albumName: String = "",
        albumID: String = "",
        quality: String
    ) async -> URL? {
        await withCheckedContinuation { continuation in
            runtimeQueue.async {
                continuation.resume(returning: self.resolveSync(
                    source: source,
                    songSource: songSource,
                    songID: songID,
                    qqMid: qqMid,
                    qqMediaMid: qqMediaMid,
                    kugouID: kugouID,
                    name: name,
                    artists: artists,
                    albumName: albumName,
                    albumID: albumID,
                    quality: quality
                ))
            }
        }
    }

    private func resolveSync(
        source: CustomAudioSource,
        songSource: LXSongSource,
        songID: String,
        qqMid: String?,
        qqMediaMid: String?,
        kugouID: String?,
        name: String,
        artists: String,
        albumName: String,
        albumID: String,
        quality: String
    ) -> URL? {
        guard source.script?.isEmpty == false else { return nil }
        // Scripts are evaluated verbatim, key and all: the text
        // itself is the runtime cache key, so editing the script
        // (or the key inside it) busts the cache. A script without
        // a usable key runs as-is and fails closed (403 → nil → the
        // ladder continues).
        let runtime = runtime(for: source, script: source.script ?? "")
        let payload: [String: Any] = [
            "action": "musicUrl",
            "source": songSource.rawValue,
            "info": [
                "type": quality,
                "musicInfo": musicInfoPayload(
                    songSource: songSource,
                    songID: songID,
                    qqMid: qqMid,
                    qqMediaMid: qqMediaMid,
                    kugouID: kugouID,
                    name: name,
                    artists: artists,
                    albumName: albumName,
                    albumID: albumID
                )
            ]
        ]
        guard let raw = runtime?.invokeRequest(payload: payload),
              let urlString = extractURLString(from: raw),
              let url = URL(string: urlString)
        else { return nil }
        return url
    }

    private func runtime(for source: CustomAudioSource, script: String) -> LXScriptRuntime? {
        let key = "\(source.id)|\(script.hashValue)"
        if let cached = cache[key] { return cached }
        guard let runtime = LXScriptRuntime(source: source, script: script) else { return nil }
        cache[key] = runtime
        return runtime
    }

    private func musicInfoPayload(
        songSource: LXSongSource,
        songID: String,
        qqMid: String?,
        qqMediaMid: String?,
        kugouID: String?,
        name: String,
        artists: String,
        albumName: String,
        albumID: String
    ) -> [String: Any] {
        let qqSongMid = qqMid?.trimmingCharacters(in: .whitespacesAndNewlines)
        let qqSongMediaMid = qqMediaMid?.trimmingCharacters(in: .whitespacesAndNewlines)
        let primaryID = (songSource == .qq ? qqSongMid : nil) ?? songID
        let resolvedHash = (songSource == .kugou ? kugouID : nil) ?? songID
        let artistList = artists
            .split(whereSeparator: { $0 == "/" || $0 == "&" || $0 == "," })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return [
            "id": songID,
            "songId": songID,
            "musicId": primaryID,
            "musicrid": songID,
            "mid": qqSongMid ?? primaryID,
            "songmid": qqSongMid ?? primaryID,
            "mediaId": qqSongMediaMid ?? primaryID,
            "media_mid": qqSongMediaMid ?? primaryID,
            "mediaMid": qqSongMediaMid ?? primaryID,
            "strMediaMid": qqSongMediaMid ?? primaryID,
            "copyrightId": songID,
            "contentId": songID,
            "hash": resolvedHash,
            "rid": songID,
            "name": name,
            "songName": name,
            "singer": artists,
            "artist": artists,
            "artists": artistList,
            "source": songSource.rawValue,
            "album": albumName,
            "albumName": albumName,
            "albumId": albumID,
            "albumAudioId": "",
            "interval": "",
            "_types": [String: Any](),
            "meta": [String: Any]()
        ]
    }

    private func extractURLString(from raw: Any) -> String? {
        if let string = raw as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                return trimmed
            }
            if trimmed.hasPrefix("//") {
                return "https:" + trimmed
            }
            if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")),
               let data = trimmed.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) {
                return extractURLString(from: object)
            }
            return nil
        }
        if let array = raw as? [Any] {
            for item in array {
                if let url = extractURLString(from: item) {
                    return url
                }
            }
            return nil
        }
        if let nsArray = raw as? NSArray {
            for item in nsArray {
                if let url = extractURLString(from: item) {
                    return url
                }
            }
            return nil
        }
        if let dict = raw as? [String: Any] {
            let paths = [
                "musicUrl",
                "musicurl",
                "music",
                "url",
                "play_url",
                "playUrl",
                "src",
                "audioUrl",
                "audio_url",
                "link",
                "purl",
                "data.url",
                "data.musicUrl",
                "data.musicurl",
                "data.music",
                "data.play_url",
                "data.playUrl",
                "data.src",
                "data.audioUrl",
                "data.audio_url",
                "data.link",
                "result.url",
                "result.musicUrl",
                "result.musicurl",
                "result.music",
                "result.play_url",
                "result.playUrl",
                "result.src",
                "result.audioUrl",
                "result.link"
            ]
            for path in paths {
                if let value = valueAtPath(dict, path),
                   let url = extractURLString(from: value) {
                    return url
                }
            }
            // Some sources return a wrapper with a provider-specific key.
            // Recurse only through likely payload containers to avoid picking a cover URL.
            for key in ["data", "result", "response", "body", "payload", "musicInfo"] {
                if let value = dict[key],
                   let url = extractURLString(from: value) {
                    return url
                }
            }
        }
        if let nsDict = raw as? NSDictionary {
            let dict = nsDict.reduce(into: [String: Any]()) { result, pair in
                if let key = pair.key as? String {
                    result[key] = pair.value
                }
            }
            return extractURLString(from: dict)
        }
        return nil
    }

    private func valueAtPath(_ obj: Any, _ path: String) -> Any? {
        var current: Any = obj
        for key in path.split(separator: ".") {
            if let dict = current as? [String: Any], let next = dict[String(key)] {
                current = next
            } else if let dict = current as? NSDictionary, let next = dict[String(key)] {
                current = next
            } else {
                return nil
            }
        }
        return current
    }
}
