import Foundation

/// Looks up the latest GitHub release. iOS has no Sparkle, so Settings
/// offers a manual check that links to the release page for re-sideloading.
///
/// Source of truth is the **fork** (Rxsume/kumone), never upstream
/// (missuo/kumone): the fork's builds are published as GitHub Releases by
/// the unsigned-iOS workflow (see .github/workflows/build-ios-unsigned.yml),
/// tagged `Golia-<version>-build-<build>` — e.g. `Golia-0.3.28-build-565`.
/// Tags with the legacy `Rumxs-` prefix (published before the rename)
/// are still accepted by `parseTag`.
/// Every fork build shares one dotted version and differs only in its
/// CFBundleVersion build number, so "is there an update" must compare
/// builds too, not just versions.
///
/// Mirror fallback (ported from Folia 0.7.27, `electron/updateCheckMirrors.cjs`):
/// when GitHub itself cannot be read (common on mainland China networks),
/// the version check falls back to public GitHub proxies, racing all four
/// at once; the first that answers with a plausible tag wins. The proxy is
/// trusted for the *version only*: a mirror-discovered release carries no
/// IPA URL, so the updater falls back to opening the releases page instead
/// of downloading a file a proxy handed over — a misbehaving proxy can at
/// worst report a wrong version, never hand over a file to install.
enum ReleaseChecker {
    struct Release {
        let version: String
        /// Build number parsed from the release tag (`Golia-…-build-<n>`,
        /// or the legacy `Rumxs-…-build-<n>`),
        /// nil for tags that carry no build (e.g. plain `v0.3.28`).
        let build: Int?
        /// The release page (fallback download link).
        let url: URL
        /// Direct download URL of the iOS IPA asset, when present.
        let ipaURL: URL?

        /// Stable identity for the "don't remind me again" dismissal,
        /// e.g. "0.3.28-565". A newer build gets a new identity and
        /// re-prompts.
        var identifier: String {
            build.map { "\(version)-\($0)" } ?? version
        }

        /// "0.3.28 (build 565)" when the tag carries a build number.
        var displayVersion: String {
            build.map { "\(version) (build \($0))" } ?? version
        }
    }

    static let repo = "Rxsume/kumone"
    static let releasesPage = URL(string: "https://github.com/Rxsume/kumone/releases/latest")!
    static let latestAPI = URL(string: "https://api.github.com/repos/Rxsume/kumone/releases/latest")!

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// This install's CFBundleVersion build number (the commit count the
    /// unsigned-iOS workflow stamps). 0 when unreadable.
    static var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    /// "0.3.28 (build 565)" for the update sheet.
    static var currentDisplayVersion: String {
        currentBuild > 0 ? "\(currentVersion) (build \(currentBuild))" : currentVersion
    }

    static func latest() async throws -> Release {
        // Direct GitHub first, exactly as before.
        do {
            return try await fetchRelease(from: latestAPI)
        } catch {
            // GitHub unreadable: ask the mirrors for the version only.
            // If no mirror answers either, throw GitHub's original error
            // (Folia's `discoverUpdateVersion` does the same).
            if let mirrored = await fetchTagViaMirrors() {
                return Release(version: mirrored.version, build: mirrored.build,
                              url: releasesPage, ipaURL: nil)
            }
            throw error
        }
    }

    /// Fetch a full release (tag + page URL + IPA asset URL) from a
    /// GitHub API endpoint. Used for the direct check, where the response
    /// is trusted; mirror responses never come through here.
    private static func fetchRelease(from apiURL: URL) async throws -> Release {
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        // A fork with no releases yet answers 404 with a {"message": ...}
        // body that has no tag_name. Treat any non-2xx as "no release"
        // instead of a decoding crash, so the launch check just stays
        // silent and the manual check shows a retryable error.
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MusicAPIError.decoding("release")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let html = obj["html_url"] as? String, let url = URL(string: html)
        else { throw MusicAPIError.decoding("release") }
        let (version, build) = parseTag(tag)
        let assets = obj["assets"] as? [[String: Any]] ?? []
        let ipa = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".ipa") == true }
        let ipaURL = (ipa?["browser_download_url"] as? String).flatMap(URL.init)
        return Release(version: version, build: build, url: url, ipaURL: ipaURL)
    }

    /// Public GitHub proxies the version check falls back to (Folia 0.7.27,
    /// `UPDATE_CHECK_MIRROR_PREFIXES`). Each takes the full GitHub API URL
    /// after its own address. `ghfast.top` refuses requests from outside
    /// mainland China; the others answer from anywhere — racing all of
    /// them means one refusing simply loses. `gh.ddlc.top` is an extra
    /// documented public proxy (listed by moretools.app); it answers 429
    /// from this VM's egress, so it is unverified for the API path — it
    /// fails fast and the race just moves on.
    private static let mirrorPrefixes = [
        "https://ghfast.top/",
        "https://edgeone.gh-proxy.com/",
        "https://gh-proxy.com/",
        "https://ghproxy.net/",
        "https://gh.ddlc.top/",
    ]

    /// Mirrors used ONLY for the explicit "加速下载 IPA（代理镜像）"
    /// button — never for the version check and never silently. Each
    /// one was verified 2026-11-08 to serve the real Golia IPA asset
    /// (HTTP 206 + ZIP magic on a ranged GET of the release file).
    /// They are a different set from `mirrorPrefixes` on purpose:
    /// several of them do not proxy api.github.com at all (githubproxy.cc
    /// answers the API URL with an HTML page, cors.isteed.cc 403s it),
    /// while `ghfast.top` refuses the API from outside mainland China
    /// yet serves release assets fine. `ghfast.top` is first because it
    /// is CN-optimized — the user's network — and refuses elsewhere,
    /// which is exactly the audience for the accelerated button.
    static let downloadMirrorPrefixes = [
        "https://ghfast.top/",
        "https://gh-proxy.com/",
        "https://edgeone.gh-proxy.com/",
        "https://ghproxy.net/",
        "https://githubproxy.cc/",
        "https://cors.isteed.cc/",
    ]

    /// Race the mirrors for the latest tag; first plausible answer wins,
    /// nil when none answers. Only the tag is read from a mirror — never
    /// an asset URL (see the `latest()` invariant above).
    private static func fetchTagViaMirrors() async -> (version: String, build: Int?)? {
        let mirrorURLs = mirrorPrefixes.compactMap { URL(string: $0 + latestAPI.absoluteString) }
        guard !mirrorURLs.isEmpty else { return nil }
        return await withTaskGroup(of: (version: String, build: Int?)?.self) { group in
            for url in mirrorURLs {
                group.addTask { await fetchTag(from: url) }
            }
            while let result = await group.next() {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    /// One mirror attempt: fetch, require 2xx, read `tag_name`, and only
    /// accept it when it looks like a real fork release tag. Any failure
    /// (network, status, decode, implausible tag) is nil — the race just
    /// waits for another mirror instead of failing on the first one.
    private static func fetchTag(from mirrorURL: URL) async -> (version: String, build: Int?)? {
        var request = URLRequest(url: mirrorURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String,
                  isPlausibleReleaseTag(tag)
            else { return nil }
            return parseTag(tag)
        } catch {
            return nil
        }
    }

    /// Strict tag check for mirror answers only (the direct path stays
    /// lenient, as before): after stripping an optional `v` and the
    /// `Golia-`/`Rumxs-` release-name prefix, the tag must be a dotted
    /// numeric version (`0.3.29`), optionally with `-build-<n>`. Anything
    /// else a proxy answers is not treated as a release.
    private static func isPlausibleReleaseTag(_ tag: String) -> Bool {
        var stripped = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        stripped = stripReleaseNamePrefix(stripped)
        let parts = stripped.split(separator: "-build-", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return false }
        let numbers = parts[0].split(separator: ".")
        guard numbers.count == 3, numbers.allSatisfy({ Int($0) != nil }) else { return false }
        if parts.count == 2 { guard Int(parts[1]) != nil else { return false } }
        return true
    }

    /// Parse a release tag into (version, build). Fork tags look like
    /// `Golia-0.3.28-build-565` (legacy `Rumxs-0.3.28-build-565` tags from
    /// before the rename are accepted too); plain `v0.3.28` / `0.3.28`
    /// tags (and any other shape) yield a version with no build.
    static func parseTag(_ tag: String) -> (version: String, build: Int?) {
        let stripped = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        if let range = stripped.range(of: "-build-") {
            var version = String(stripped[..<range.lowerBound])
            version = stripReleaseNamePrefix(version)
            return (version, Int(String(stripped[range.upperBound...])))
        }
        var version = stripped
        version = stripReleaseNamePrefix(version)
        return (version, nil)
    }

    /// Strip the release-name prefix: new `Golia-` tags, or legacy
    /// `Rumxs-` tags published before the rename — both stay valid.
    private static func stripReleaseNamePrefix(_ version: String) -> String {
        if version.hasPrefix("Golia-") { return String(version.dropFirst("Golia-".count)) }
        if version.hasPrefix("Rumxs-") { return String(version.dropFirst("Rumxs-".count)) }
        return version
    }

    /// True when `remote` is newer than `local` (numeric dotted compare).
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = remote.split(separator: ".").map { Int($0) ?? 0 }
        let b = local.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// True when the remote release is newer than this install. A newer
    /// dotted version always wins; when the versions are equal, a higher
    /// build number wins (the fork's normal case: same 0.3.x, newer build).
    /// A release tag with no build number can only win on version, never
    /// on build.
    static func isNewerRelease(_ remote: Release) -> Bool {
        if isNewer(remote.version, than: currentVersion) { return true }
        if isNewer(currentVersion, than: remote.version) { return false }
        // Equal versions: compare builds.
        guard let remoteBuild = remote.build else { return false }
        return remoteBuild > currentBuild
    }
}
