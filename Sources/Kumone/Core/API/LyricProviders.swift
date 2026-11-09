import Foundation

// Folia lyrics multi-source auto-match, ported natively to Swift.
// Contract file for the parallel provider work: the QQ, AMLL and Kugou
// providers live in their own files and conform to `LyricProvider` below.
//
// Provider type names this file expects (rename here if the provider files
// name their types differently — the coordinator owns that at merge time):
//   NetEase — `NetEaseLyricProvider` (defined below, in this file)
//   QQ      — `QQLyricProvider`
//   AMLL    — `AMLLLyricProvider`
//   Kugou   — `KugouLyricProvider`
//
// Selection rules (Folia `autoMatchBestLyric.ts`): sources are tried in
// order — preferred source first, then `LyricSource.tableOrder` — with a 5s
// budget each. The first word-by-word result wins immediately; the first
// line-timed result is kept as a fallback while later sources are tried; a
// pure-music verdict ends the pick immediately. Only after a pass with no
// word-by-word winner does the track's alias (its original name) get a
// second pass. There is no alternate-artist retry: `Track` carries no
// alternate artist, and Folia's comes from a caller-supplied callback with
// no equivalent here.

/// A lyrics backend. `fetch` searches that backend for the track and
/// returns the best matching lyric it has, or nil when it has nothing
/// usable. Providers check `Task.isCancelled` between steps so the
/// per-source timeout in `LyricMultiSource` can stop a slow source.
///
/// `Sendable`: `LyricMultiSource` captures the provider in a task-group
/// child task, which requires a `@Sendable` closure. All providers are
/// stateless structs, so this is trivially satisfied — and the package
/// builds in Swift 6 language mode (swift-tools-version 6.2, no
/// `swiftLanguageVersions` override), where a non-Sendable capture here
/// would be a hard compile error, not a warning.
protocol LyricProvider: Sendable {
    var source: LyricSource { get }
    func fetch(for track: Track) async -> LyricCandidate?
}

/// One backend's answer for a track.
struct LyricCandidate {
    let source: LyricSource
    let response: LyricResponse
    /// Word-by-word (verbatim) timing is present, so karaoke highlighting
    /// can use the service's own timing.
    let isWordByWord: Bool
    /// The backend says the song has no lyrics (pure music).
    let isPureMusic: Bool
}

enum LyricSource: String, CaseIterable, Identifiable {
    case netease, qq, amll, kugou

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .netease: return String(localized: "网易云音乐")
        case .qq: return String(localized: "QQ音乐")
        case .amll: return String(localized: "AMLL")
        case .kugou: return String(localized: "酷狗音乐")
        }
    }

    /// Folia's source table order (`lyricSources.ts`): the order sources are
    /// tried after the user's preferred source.
    static let tableOrder: [LyricSource] = [.netease, .amll, .qq, .kugou]
}

// MARK: - Match scoring (Folia `matchScore.ts`)

enum LyricMatch {
    /// Weights: title 45 / artist 25 / album 30. Thresholds: title ≥ 0.65,
    /// artist ≥ 0.5, album ≥ 0.65. Duration multiplier: 1.0 (≤1s), 0.95
    /// (≤3s), 0.75 (≤5s), 0.35 (≤10s), 0.1 (beyond), unknown → 0.9. The
    /// identity score is capped at 74 when the title misses or neither the
    /// artist nor the album matches. Accepted iff the title matched, the
    /// artist or album matched, and the score is ≥ 75.
    ///
    /// `title` / `artist` / `album` / `duration` describe the *candidate*
    /// (the song a source found); `track` is the song being played.
    static func evaluate(title: String, artist: String, album: String?,
                         duration: TimeInterval?, track: Track) -> (score: Double, accepted: Bool) {
        let titleSimilarity = similarity(title, track.name, normalizer: normalizeTitle)
        let titleScore = titleSimilarity * 45

        let targetArtist = track.artistNames
        let artistSim = targetArtist.trimmingCharacters(in: .whitespaces).isEmpty
            ? 1 : artistSimilarity(targetArtist, artist)
        let artistScore = artistSim * 25

        // Folia treats "Unknown Album" as no album at all.
        let searchAlbum = (album ?? "").trimmingCharacters(in: .whitespaces)
        let hasSearchAlbum = !searchAlbum.isEmpty
            && searchAlbum.lowercased() != "unknown album"
        let targetAlbum = track.album.name.trimmingCharacters(in: .whitespaces)
        let hasTargetAlbum = !targetAlbum.isEmpty
        let albumSimilarity: Double? = (hasTargetAlbum && hasSearchAlbum)
            ? similarity(targetAlbum, searchAlbum, normalizer: normalizeTitle) : nil
        let albumScore = albumSimilarity.map { $0 * 30 } ?? (hasTargetAlbum ? 0 : 30)

        let durationMult = durationMultiplier(
            targetMs: track.duration * 1000,
            searchMs: (duration ?? 0) * 1000)

        let titleMatched = titleSimilarity >= 0.65
        let artistMatched = targetArtist.trimmingCharacters(in: .whitespaces).isEmpty
            || artistSim >= 0.5
        let albumMatched: Bool? = !hasTargetAlbum ? nil
            : (hasSearchAlbum ? (albumSimilarity ?? 0) >= 0.65 : nil)
        let hasReliableIdentityMatch = artistMatched || albumMatched == true
        let identityScore = titleScore + artistScore + albumScore
        let cappedIdentityScore = (!titleMatched || !hasReliableIdentityMatch)
            ? min(identityScore, 74) : identityScore
        let finalScore = cappedIdentityScore * durationMult
        let score = min(100, max(0, finalScore.rounded()))

        let accepted = titleMatched && hasReliableIdentityMatch && score >= 75
        return (score, accepted)
    }

    // MARK: Normalization

    /// Folia `normalizeLyricMatchText`: lowercase, strip punctuation and
    /// symbols, collapse whitespace. Approximation: Folia also converts
    /// kana to romaji (wanakana) and traditional to simplified Chinese
    /// (OpenCC); neither exists in Swift, so CJK text compares as written
    /// and kana compares as kana.
    private static func normalizeText(_ value: String) -> String {
        let stripped = value.unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
        }
        let collapsed = String(String.UnicodeScalarView(stripped))
            .lowercased()
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }

    /// Folia `normalizeTitleForMatch`: strip feat. credits and bracketed
    /// asides, except bracketed version markers (remix, live, …), which are
    /// kept — the same as Folia, so a "(Remix)" title still scores against
    /// a plain one only through the similarity itself.
    private static func normalizeTitle(_ value: String) -> String {
        var text = value
        // "(feat. X)" / "[ft. X]" / "（feat. X）" — bracketed feature credits.
        text = text.replacing(#/[\(\[（【]\s*(?:feat|featuring|ft)\.?\s+[^\)\]）】]+[\)\]）】]/#.ignoresCase(), with: "")
        // A trailing "feat. X" outside brackets.
        text = text.replacing(#/\b(?:feat|featuring|ft)\.?\s+.+$/#.ignoresCase(), with: "")
        // Other bracketed asides are dropped; bracketed version markers stay.
        text = text.replacing(#/[\(\[（【]([^\)\]）】]+)[\)\]）】]/#.ignoresCase()) { match in
            String(match.1).contains(versionMarkerPattern) ? String(match.0) : ""
        }
        return normalizeText(text)
    }

    private static let versionMarkerPattern =
        #/instrumental|inst|off\s*vocal|karaoke|remix|mix|version|ver\.?|cover|live|edit|arrange|伴奏|カラオケ|インスト|リミックス|remaster|remastered/#.ignoresCase()

    /// Folia `stringSimilarity`: exact → 1, containment → length ratio,
    /// else Jaccard over the character sets.
    private static func similarity(_ s1: String, _ s2: String,
                                   normalizer: (String) -> String) -> Double {
        let n1 = normalizer(s1)
        let n2 = normalizer(s2)
        if n1.isEmpty || n2.isEmpty { return 0 }
        if n1 == n2 { return 1 }
        if n1.contains(n2) || n2.contains(n1) {
            return Double(min(n1.count, n2.count)) / Double(max(n1.count, n2.count))
        }
        let set1 = Set(n1)
        let set2 = Set(n2)
        let union = set1.union(set2).count
        return union > 0 ? Double(set1.intersection(set2).count) / Double(union) : 0
    }

    /// Folia `splitArtistsForMatch` + `calculateArtistSimilarity`: split
    /// on commas, &, 、, /, feat./ft./featuring and 与, match tokens, and
    /// give the main (first) artist a 0.7 floor when it matches.
    private static func splitArtists(_ text: String) -> [String] {
        let flattened = text.replacing(#/\b(?:feat|featuring|ft)\.?/#.ignoresCase(), with: ",")
        return flattened.components(separatedBy: CharacterSet(charactersIn: ",&、/与"))
            .map(normalizeText)
            .filter { !$0.isEmpty }
    }

    private static func artistSimilarity(_ target: String, _ search: String) -> Double {
        let tArtists = splitArtists(target)
        let sArtists = splitArtists(search)
        if tArtists.isEmpty || sArtists.isEmpty {
            return similarity(target, search, normalizer: normalizeText)
        }
        func tokenMatches(_ a1: String, _ a2: String) -> Bool {
            a1 == a2
                || (a1.count >= 3 && a2.contains(a1))
                || (a2.count >= 3 && a1.contains(a2))
        }
        var matchCount = 0
        for a1 in tArtists {
            if sArtists.contains(where: { tokenMatches(a1, $0) }) { matchCount += 1 }
        }
        let tokenSim = Double(matchCount) / Double(max(tArtists.count, sArtists.count))
        let mainMatched = tArtists.first.map { t0 in
            sArtists.first.map { tokenMatches(t0, $0) } ?? false
        } ?? false
        let mainBonus = mainMatched ? max(tokenSim, 0.7) : tokenSim
        return max(mainBonus, similarity(target, search, normalizer: normalizeText))
    }

    private static func durationMultiplier(targetMs: Double, searchMs: Double) -> Double {
        if targetMs <= 0 || searchMs <= 0 { return 0.9 }
        let diff = abs(targetMs - searchMs)
        if diff <= 1000 { return 1 }
        if diff <= 3000 { return 0.95 }
        if diff <= 5000 { return 0.75 }
        if diff <= 10000 { return 0.35 }
        return 0.1
    }
}

// MARK: - Multi-source orchestration (Folia `autoMatchBestLyric.ts`)

enum LyricMultiSource {
    /// Per-source budget: one slow backend must not block the whole pick.
    static let perSourceTimeout: TimeInterval = 5

    /// Best lyric across the sources, or nil when no source has usable
    /// lyrics. Word-by-word wins immediately; a line-timed result is kept
    /// as the fallback while later sources are tried; a pure-music verdict
    /// ends the pick immediately.
    static func fetch(for track: Track, preferred: LyricSource) async -> LyricResponse? {
        // First pass under the track's own name.
        let first = await runPass(for: track, preferred: preferred)
        switch first {
        case .wordByWord(let response), .pureMusic(let response):
            return response
        case .lineFallback, .none:
            break
        }

        // Original-name retry (Folia `searchAlias`): the song's own
        // provider may list it under another title. Only when the first
        // pass found no word-by-word lyric — and never when the alias
        // would drop an instrumental marker the title carries.
        guard let alias = track.alias.first(where: { !$0.isEmpty && $0 != track.name }),
              !dropsInstrumentalMarker(title: track.name, alias: alias),
              let renamed = renamed(track, to: alias) else {
            return first.response
        }
        let second = await runPass(for: renamed, preferred: preferred)
        switch second {
        case .wordByWord(let response):
            return response
        case .pureMusic(let response):
            // Folia: an alias-pass pure-music verdict only wins when the
            // first pass found nothing at all.
            return first.response ?? response
        case .lineFallback(let response):
            return first.response ?? response
        case .none:
            return first.response
        }
    }

    // MARK: One pass

    private enum PassResult {
        case wordByWord(LyricResponse)
        case pureMusic(LyricResponse)
        case lineFallback(LyricResponse)
        case none

        var response: LyricResponse? {
            switch self {
            case .wordByWord(let response), .pureMusic(let response),
                    .lineFallback(let response):
                return response
            case .none:
                return nil
            }
        }
    }

    private static func runPass(for track: Track, preferred: LyricSource) async -> PassResult {
        var fallback: LyricResponse?
        for source in [preferred] + LyricSource.tableOrder.filter({ $0 != preferred }) {
            guard !Task.isCancelled else { break }
            guard let provider = provider(for: source) else { continue }
            guard let candidate = await fetchWithTimeout(provider: provider, track: track) else { continue }
            // A pure-music verdict from a source ends the pick immediately.
            // (Every source here can return word-by-word lyrics, so there
            // is no lines-only source whose verdict would be weaker.)
            if candidate.isPureMusic {
                return .pureMusic(candidate.response)
            }
            guard hasRenderableLyrics(candidate.response) else { continue }
            if candidate.isWordByWord {
                return .wordByWord(candidate.response)
            }
            if fallback == nil { fallback = candidate.response }
        }
        if let fallback { return .lineFallback(fallback) }
        return .none
    }

    private static func provider(for source: LyricSource) -> (any LyricProvider)? {
        switch source {
        case .netease: return NetEaseLyricProvider()
        case .qq: return QQLyricProvider()
        case .amll: return AMLLLyricProvider()
        case .kugou: return KugouLyricProvider()
        }
    }

    /// One source's fetch bounded by `perSourceTimeout`: whichever of the
    /// fetch or the timer finishes first wins, and the loser is cancelled.
    /// Providers check `Task.isCancelled` between steps, so a timed-out
    /// fetch stops promptly instead of lingering in the background.
    private static func fetchWithTimeout(provider: any LyricProvider, track: Track) async -> LyricCandidate? {
        await withTaskGroup(of: LyricCandidate?.self) { group in
            group.addTask { await provider.fetch(for: track) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(perSourceTimeout * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// A response counts as lyrics only when it carries a timed main body
    /// (line or verbatim); a translation-only body has nothing to sing.
    private static func hasRenderableLyrics(_ response: LyricResponse) -> Bool {
        let lrc = response.lrc?.lyric?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let yrc = response.yrc?.lyric?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !lrc.isEmpty || !yrc.isEmpty
    }

    private static let instrumentalMarker =
        #/instrumental|\binst\b|off\s*vocal|karaoke|伴奏|カラオケ|インスト/#.ignoresCase()

    private static func dropsInstrumentalMarker(title: String, alias: String) -> Bool {
        title.contains(instrumentalMarker) && !alias.contains(instrumentalMarker)
    }

    /// `Track` has no memberwise initializer (custom Decodable init), so
    /// the alias pass renames it through its own Codable round-trip. Any
    /// failure just skips the retry.
    private static func renamed(_ track: Track, to title: String) -> Track? {
        guard let data = try? JSONEncoder().encode(track),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        object["name"] = title
        guard let renamed = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(Track.self, from: renamed)
    }
}

// MARK: - NetEase provider

/// NetEase is the track's own platform here: fetch by the NetEase song id
/// through the existing `MusicAPI.lyric(id:)`, unchanged for other callers.
struct NetEaseLyricProvider: LyricProvider {
    var source: LyricSource { .netease }

    func fetch(for track: Track) async -> LyricCandidate? {
        // Platform tracks carry a negative stable-hash id, never a
        // NetEase song id: querying NetEase with it can only burn the
        // per-source budget, and a false pure-music verdict would end
        // the whole pick before the track's own platform provider runs.
        // QQ/Kugou tracks get their lyrics from their own provider,
        // AMLL, or Kugou instead.
        guard track.platformSource == nil else { return nil }
        guard let response = try? await MusicAPI.lyric(id: track.id) else { return nil }
        guard !Task.isCancelled else { return nil }
        let isWordByWord = !(response.yrc?.lyric?.isEmpty ?? true)
        let isPureMusic = response.nolyric == true
        guard isPureMusic || isWordByWord || !(response.lrc?.lyric?.isEmpty ?? true) else { return nil }
        return LyricCandidate(source: .netease, response: response,
                              isWordByWord: isWordByWord, isPureMusic: isPureMusic)
    }
}
