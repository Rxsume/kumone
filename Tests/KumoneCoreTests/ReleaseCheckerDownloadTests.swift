import Testing
@testable import KumoneCore
import Foundation
import os

/// Coverage for the updater's no-VPN auto-select (`ReleaseChecker`
/// download candidates + direct probe): pure selection logic, and the
/// HEAD probe against a stubbed URLSession — no real network.
///
/// Serialized: the probe stub holds process-wide state (canned status /
/// error), so parallel tests would race each other's configuration.
@Suite("ReleaseCheckerDownload", .serialized)
struct ReleaseCheckerDownloadTests {

    private let ipaURL = URL(string: "https://github.com/Rxsume/kumone/releases/download/Golia-0.3.29-build-760/Golia-iOS-0.3.29-custom.ipa")!

    // MARK: - Candidate selection (pure, no network)

    @Test func reachableDirectIsTheOnlyCandidate() {
        let candidates = ReleaseChecker.downloadCandidates(for: ipaURL, directReachable: true)
        #expect(candidates.count == 1)
        #expect(candidates.first?.url == ipaURL)
        #expect(candidates.first?.mirrorHost == nil)
    }

    @Test func unreachableDirectFallsBackToMirrorsInOrder() {
        let candidates = ReleaseChecker.downloadCandidates(for: ipaURL, directReachable: false)
        #expect(candidates.count == ReleaseChecker.downloadMirrorPrefixes.count)
        #expect(candidates.first?.mirrorHost == "ghfast.top")
        #expect(candidates.first?.url.absoluteString == "https://ghfast.top/" + ipaURL.absoluteString)
        // Every candidate keeps the same asset path, only the prefix differs.
        for candidate in candidates {
            #expect(candidate.url.absoluteString.hasSuffix(ipaURL.absoluteString))
            #expect(candidate.mirrorHost != nil)
        }
        // Order follows downloadMirrorPrefixes exactly.
        let hosts = candidates.compactMap(\.mirrorHost)
        #expect(hosts == ReleaseChecker.downloadMirrorPrefixes.map { URL(string: $0)?.host ?? $0 })
    }

    // MARK: - Direct probe (stubbed session, no network)

    @Test func probeSucceedsOn2xx() async {
        let session = stubbedSession(statusCode: 200)
        #expect(await ReleaseChecker.isDirectReachable(ipaURL, session: session))
    }

    @Test func probeFailsOn404() async {
        let session = stubbedSession(statusCode: 404)
        #expect(await ReleaseChecker.isDirectReachable(ipaURL, session: session) == false)
    }

    @Test func probeFailsOnTimeout() async {
        let session = stubbedSession(error: URLError(.timedOut))
        #expect(await ReleaseChecker.isDirectReachable(ipaURL, session: session) == false)
    }

    @Test func probeFailsOnUnreachableHost() async {
        let session = stubbedSession(error: URLError(.cannotFindHost))
        #expect(await ReleaseChecker.isDirectReachable(ipaURL, session: session) == false)
    }

    @Test func probeSendsHEAD() async {
        let session = stubbedSession(statusCode: 200)
        _ = await ReleaseChecker.isDirectReachable(ipaURL, session: session)
        #expect(ProbeStub.lastMethod() == "HEAD")
    }

    private func stubbedSession(statusCode: Int = 200, error: (any Error)? = nil) -> URLSession {
        ProbeStub.configure(statusCode: statusCode, error: error)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProbeStub.self]
        return URLSession(configuration: configuration)
    }
}

/// Stub URLProtocol for the direct-reachability probe: answers a canned
/// status (or fails with a canned error) and records the request method.
private final class ProbeStub: URLProtocol, @unchecked Sendable {
    private struct State {
        var statusCode = 200
        var error: (any Error)?
        var lastMethod: String?
    }
    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func configure(statusCode: Int, error: (any Error)?) {
        state.withLock { $0 = State(statusCode: statusCode, error: error, lastMethod: nil) }
    }

    static func lastMethod() -> String? {
        state.withLock { $0.lastMethod }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (statusCode, error) = Self.state.withLock { state in
            state.lastMethod = request.httpMethod
            return (state.statusCode, state.error)
        }
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode,
                                       httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
}
