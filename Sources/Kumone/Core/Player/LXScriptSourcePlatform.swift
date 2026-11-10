/// Display mapping for LX script source ids → Chinese platform names.
///
/// Display-only: nothing here is consulted by the resolve path
/// (`LXSongSource`, `customScriptResolve`, `UnblockService` are
/// untouched). The ids are the ones scripts declare in their
/// `inited` payload (`sources` keys) and the ones the backend
/// accepts, grounded in two places:
/// - Beans 2.0.3 (`ThirdPartyAudioQuality.supported(providerCode:)`
///   and the LX `getMusicUrl` switch): `kw` 酷我, `kg` 酷狗,
///   `tx` QQ, `wy` 网易, `mg` 咪咕 — plus the canonical LX
///   five-source script (`kw/kg/tx/wy/mg`).
/// - The ikun v26 script itself, which declares `git/kg/kw/tx/wy`.
/// `git` is an extra key in that script whose meaning is unknown,
/// so it is deliberately NOT mapped here: an unmapped declared id
/// is shown in the editor as a raw-id chip instead of a guessed
/// name.
/// 汽水 / 哔哩 have no grounded id: Beans 2.0.3 has no such source
/// code (its editor is a platform *picker*, not a chips list), the
/// canonical LX script has none, and the backend rejects every
/// guessed code for them — so they get no fixed chip. If a script
/// ever declares a new id, it appears as a raw-id chip, and adding
/// a proper name is a one-line change to `known`.
enum LXScriptSourcePlatform {
    /// (source id, Chinese name), in the order the editor shows them.
    static let known: [(id: String, name: String)] = [
        ("wy", "网易"),
        ("tx", "QQ"),
        ("kg", "酷狗"),
        ("kw", "酷我"),
        ("mg", "咪咕"),
    ]

    /// Chinese name for a known source id, or nil for an unknown id.
    static func displayName(for id: String) -> String? {
        known.first(where: { $0.id == id })?.name
    }

    /// True when every known platform is declared (the "全部" chip
    /// highlight rule).
    static func allDeclared(_ declared: Set<String>) -> Bool {
        known.allSatisfy { declared.contains($0.id) }
    }
}
