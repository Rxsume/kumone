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
        var request = URLRequest(url: latestAPI)
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
