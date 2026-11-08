import Foundation

/// Configuration for Spotify login (OAuth) and the read-only Web API client.
///
/// The Client ID and Redirect URI are user-supplied settings, not constants:
/// Folia's own client_id lives in `electron/spotify/signIn.cjs`, which is not
/// in the sparse checkout, so its value could not be verified — and reusing
/// another app's client_id would be wrong anyway. Golia must be registered
/// as its own app in the Spotify Developer Dashboard (see
/// INTEGRATION-spotify.md). Both settings default to empty; while either is
/// empty the Spotify login entry must stay disabled.
struct SpotifyConfiguration {
    /// UserDefaults key for the Spotify app's Client ID. The `settings.*`
    /// naming follows `SettingsManager.Keys`.
    static let clientIDKey = "settings.spotifyClientID"
    /// UserDefaults key for the Redirect URI registered for that app.
    static let redirectURIKey = "settings.spotifyRedirectURI"

    /// Suggested Redirect URI to show as placeholder text in Settings and to
    /// register in the Spotify Developer Dashboard. This is only a
    /// suggestion: it is never used as a fallback — an empty Redirect URI
    /// setting means "not configured".
    ///
    /// The scheme is deliberately `golia-spotify`, not `golia`: `golia://`
    /// is the Live Activity deep-link scheme, owned by a separate removal
    /// PR and untouched by this change.
    static let suggestedRedirectURI = "golia-spotify://callback"

    /// Scopes requested at authorize time. Read-only plus profile: enough
    /// to browse/search, list the user's playlists and liked tracks, and
    /// read the profile. No write scopes, no playback scopes.
    static let scopes = [
        "playlist-read-private",
        "user-library-read",
        "user-read-private",
        "user-read-email",
    ]

    static let authorizeURL = URL(string: "https://accounts.spotify.com/authorize")!
    static let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!
    static let webAPIBaseURL = URL(string: "https://api.spotify.com/v1")!

    /// The Client ID as typed in Settings (trimmed). Empty means not configured.
    var clientID: String {
        UserDefaults.standard.string(forKey: Self.clientIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// The Redirect URI as typed in Settings (trimmed). Empty means not configured.
    var redirectURI: String {
        UserDefaults.standard.string(forKey: Self.redirectURIKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// True only when both values are present. The login entry must be
    /// disabled (with a hint) while this is false.
    var isConfigured: Bool { !clientID.isEmpty && !redirectURI.isEmpty }

    /// The custom URL scheme taken from the Redirect URI, for
    /// `ASWebAuthenticationSession`. Nil unless the Redirect URI is a
    /// well-formed URL with a non-HTTP(S) scheme — an http(s) Redirect URI
    /// cannot be caught by the app without Associated Domains, so it does
    /// not count as configured for login.
    var callbackScheme: String? {
        guard let url = URL(string: redirectURI),
              let scheme = url.scheme?.lowercased(),
              scheme != "http", scheme != "https",
              !scheme.isEmpty else { return nil }
        return scheme
    }

    /// True when login can actually start: configured and the Redirect URI
    /// yields a usable callback scheme.
    var canLogIn: Bool { isConfigured && callbackScheme != nil }
}
