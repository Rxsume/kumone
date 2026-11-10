import Foundation

/// Built-in custom audio source: the ikun (酸甜贤) LX script, shipped
/// in the app so playback no longer depends on the user re-importing
/// it after every reinstall (a reinstall wipes the imported-script
/// blob in UserDefaults).
///
/// The script text is the user's v26 script verbatim, except the
/// sponsored API key is EMPTY here (`const API_KEY = "";`). The key
/// is never in the repo: the user pastes it once in Settings →
/// 自定义音源 → 内置源详情 → 赞助密钥， stored only on device under
/// `settings.ikunApiKey`, and injected into a copy of the script at
/// runtime by `LXScriptRunner` before the script is evaluated.
/// `settings.ikunApiKey` is NOT in the SettingsBackup allowlist and
/// NOT in the SyncedPreferences table, same as the imported-script
/// blob (`settings.customAudioSources`).
///
/// The built-in source lives in `CustomAudioSourceStore` like any
/// imported source (fixed id `builtin-ikun`, always first), so it
/// resolves through the same first step in `UnblockService.resolve` —
/// no separate priority channel.
enum BuiltInAudioSources {
    /// Fixed id of the built-in ikun source. Imported scripts get
    /// fresh UUIDs (`finishImport`), so they can never collide.
    static let ikunID = "builtin-ikun"

    /// Display name, matching the script's own `@name`.
    static let ikunName = "酸甜贤音源"

    /// The exact line in `ikunScript` holding the key placeholder.
    /// Key injection replaces this line only.
    static let apiKeyPlaceholder = "const API_KEY = \"\";"

    /// UserDefaults key for the sponsored key. Device-only: NOT in
    /// the SettingsBackup allowlist, NOT a synced preference.
    /// `SettingsManager.Keys.ikunApiKey` points at this string.
    static let apiKeyDefaultsKey = "settings.ikunApiKey"

    /// The built-in source record, as stored in
    /// `CustomAudioSourceStore` (first position, enabled by default).
    /// `quality` / `enabled` are preserved across script refreshes
    /// by the store; the script itself is always this file's text.
    static func ikunSource(quality: String = "320k", enabled: Bool = true) -> CustomAudioSource {
        CustomAudioSource(
            id: ikunID,
            name: ikunName,
            kind: "script",
            template: "",
            quality: quality,
            script: ikunScript,
            enabled: enabled
        )
    }

    static func isBuiltIn(id: String) -> Bool {
        id == ikunID
    }

    /// The sponsored key as stored on this device, or "".
    /// Read straight from UserDefaults: `LXScriptRunner` evaluates
    /// scripts off the main actor, so it must not go through the
    /// `@MainActor` `SettingsManager`.
    static var storedAPIKey: String {
        UserDefaults.standard.string(forKey: apiKeyDefaultsKey) ?? ""
    }

    /// Returns the script text to evaluate for `source`: for the
    /// built-in ikun source, the sponsored key is substituted into
    /// the empty `API_KEY` placeholder; every other source is
    /// returned unchanged. Pass `apiKey` explicitly in tests;
    /// `nil` reads the stored key. The returned text is also the
    /// runtime cache key in `LXScriptRunner`, so changing the key
    /// naturally busts the cached runtime. The key is never logged.
    static func effectiveScript(for source: CustomAudioSource, apiKey: String? = nil) -> String {
        guard let script = source.script, !script.isEmpty else { return "" }
        guard source.id == ikunID else { return script }
        let key = apiKey ?? storedAPIKey
        guard !key.isEmpty else { return script }
        return script.replacingOccurrences(
            of: apiKeyPlaceholder,
            with: "const API_KEY = \"\(jsEscaped(key))\";"
        )
    }

    /// Escapes a key for interpolation into a JS double-quoted string.
    static func jsEscaped(_ key: String) -> String {
        key
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    /// The ikun v26 LX script, verbatim except `API_KEY` is empty
    /// (see the file header). No backslashes, no `"""`, so it is
    /// safe in a Swift multiline literal.
    static let ikunScript = """
    /*!
     * @name 酸甜贤音源
     * @description By：酸甜贤 过期时间
     * @version v26
     * @author ikunshare
     */

    const DEV_ENABLE = false
    const UPDATE_ENABLE = true
    const API_URL = "https://c.wwwweb.top"
    const API_KEY = ""
    const SCRIPT_MD5 = "d8a5ffde7accc82905263a18392d96f5";
    const MUSIC_QUALITY = JSON.parse('{"git":["128k","320k","flac"],"kg":["128k","320k","flac","flac24bit","hires","atmos","master"],"kw":["128k","320k","flac","flac24bit","hires"],"tx":["128k","320k","flac","flac24bit","hires","atmos","atmos_plus","master"],"wy":["128k","320k","flac","flac24bit","hires","atmos","master"]}');

    const MUSIC_SOURCE = Object.keys(MUSIC_QUALITY);
    const {EVENT_NAMES, request, on, send, utils, env, version} = globalThis.lx;

    const httpFetch = (url, options = {method: "GET"}) => {
        return new Promise((resolve, reject) => {
            request(url, options, (err, resp) => {
                if (err) return reject(err);
                resolve(resp);
            });
        });
    };

    const handleGetMusicUrl = async (source, musicInfo, quality) => {
        const songId = musicInfo.hash ?? musicInfo.songmid;
        const request = await httpFetch(
            `${API_URL}/music/url`,
            {
                method: "POST",
                headers: {
                    "Content-Type": "application/json",
                    "User-Agent": `${
                        env ? `lx-music-${env}/${version}` : `lx-music-request/${version}`
                    }`,
                    "X-Api-Key": API_KEY,
                },
                body: {
                    source: source,
                    musicId: songId,
                    quality: quality,
                },
                follow_max: 5,
            }
        );
        const {body} = request;
        if (!body || isNaN(Number(body.code))) throw new Error("unknow error");
        if (env !== "mobile") console.groupEnd();
        switch (body.code) {
            case 200:
                return body.url;
            case 403:
                throw new Error("鉴权失败");
            case 429:
                throw new Error("请求过速");
            case 500:
                throw new Error(`获取URL失败, ${body.message ?? "未知错误"}`);
            default:
                throw new Error(body.message ?? "未知错误");
        }
    };

    const checkUpdate = async () => {
        const request = await httpFetch(
            `${API_URL}/script/lxmusic?checkUpdate=${SCRIPT_MD5}&key=${API_KEY}`,
            {
                method: "GET",
                headers: {
                    "Content-Type": "application/json",
                    "User-Agent": `${
                        env ? `lx-music-${env}/${version}` : `lx-music-request/${version}`
                    }`,
                },
            }
        );
        const {body} = request;

        if (!body || body.code !== 200) console.log("checkUpdate failed");
        else {
            if (body.data != null) {
                globalThis.lx.send(lx.EVENT_NAMES.updateAlert, {
                    log: body.data.updateMsg,
                    updateUrl: body.data.updateUrl,
                });
            }
        }
    };

    const musicSources = {};
    MUSIC_SOURCE.forEach((item) => {
        musicSources[item] = {
            name: item,
            type: "music",
            actions: ["musicUrl"],
            qualitys: MUSIC_QUALITY[item],
        };
    });

    on(EVENT_NAMES.request, ({action, source, info}) => {
        switch (action) {
            case "musicUrl":
                return handleGetMusicUrl(source, info.musicInfo, info.type)
                    .then((data) => Promise.resolve(data))
                    .catch((err) => Promise.reject(err));
            default:
                return Promise.reject("action not support");
        }
    });

    if (UPDATE_ENABLE) checkUpdate();

    send(EVENT_NAMES.inited, {
        status: true,
        openDevTools: DEV_ENABLE,
        sources: musicSources,
    });
    """
}
