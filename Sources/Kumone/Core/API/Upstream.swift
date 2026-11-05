import Foundation
import os

/// Request endpoints, fixed at build time (no first-launch setup).
enum Upstream {

    /// Stored endpoint configuration.
    struct Hosts: Codable, Equatable, Sendable {
        /// Web, login and the encrypted API: `music.<api>.com`.
        let api: Int
        /// Signed audio and images: `*.music.<cdn>.net`.
        let cdn: Int
    }

    /// Fixed endpoint values — the answers the first-launch check used to
    /// collect (163 = "£", 126 = "~"), now baked in at build time.
    private static let apiTarget = 163
    private static let cdnTarget = 126

    /// Mutable only so tests can substitute placeholder hosts (see
    /// `TestUpstream`); production always uses the fixed values above.
    private static let state = OSAllocatedUnfairLock<Hosts?>(initialState: Hosts(api: apiTarget, cdn: cdnTarget))

    static var hosts: Hosts? { state.withLock { $0 } }

    /// Test-only override of the endpoint configuration (in-memory only).
    static func configure(_ hosts: Hosts) {
        state.withLock { $0 = hosts }
    }

    // MARK: - Hosts

    static var webHost: String? { hosts.map { "music.\($0.api).com" } }
    static var interfaceHost: String? { hosts.map { "interface.music.\($0.api).com" } }
    /// Suffix every audio CDN host ends with, leading dot included.
    static var cdnSuffix: String? { hosts.map { ".music.\($0.cdn).net" } }

    static func webURL(_ pathAndQuery: String) -> URL? {
        webHost.flatMap { URL(string: "https://\($0)\(pathAndQuery)") }
    }

    static func songPageURL(id: Int) -> URL? { webURL("/#/song?id=\(id)") }

    // MARK: - Protocol identifiers

    /// Source identifier used in request headers, cache keys, offline records
    /// and account scopes.
    static let tag = unshift("ofufbtf")

    private static func unshift(_ shifted: String) -> String {
        String(String.UnicodeScalarView(shifted.unicodeScalars.compactMap { Unicode.Scalar($0.value - 1) }))
    }

    /// Client name for the User-Agent.
    static var clientName: String { tag.prefix(1).uppercased() + tag.dropFirst() + "Music" }

    /// The scope offline downloads and sync records carry for an account.
    static func accountScope(userID: Int) -> String { "\(tag):\(userID)" }
}
