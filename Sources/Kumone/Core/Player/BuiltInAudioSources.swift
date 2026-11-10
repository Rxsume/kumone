import Foundation

/// Bundled custom audio sources, shipped with the app and seeded
/// into `CustomAudioSourceStore` on first launch (or when no copy
/// of the same script is present). The seeded records are ordinary
/// imported sources: editable, movable, deletable. Deleting one
/// marks it dismissed so it is never re-seeded.
///
/// Security: the ikun script below is the user's sponsored script
/// with its private key blanked (`API_KEY = ""`). The key itself is
/// NEVER committed to the repo, never logged, and never backed up:
/// the user pastes it once in the source editor ("赞助密钥" field),
/// which writes it into the stored script text on device only.
/// The Golia script ships verbatim; its key is the script's own
/// public shared key, distributed with the script itself.
/// The GD script ships verbatim; it calls a public API with no key.
enum BuiltInAudioSources {
    /// Backend host of the ikun script; used to recognise any copy
    /// of it (seeded or user-imported) so it is never seeded twice.
    static let ikunBackendHost = "c.wwwweb.top"

    /// Backend host of the Golia script; same dedup purpose.
    static let goliaBackendHost = "lxmusicapi.onrender.com"

    /// Backend host of the GD script; same dedup purpose.
    static let gdBackendHost = "music-api.gdstudio.xyz"

    /// Fixed ids of the seeded records.
    static let ikunSourceID = "builtin-ikun"
    static let goliaSourceID = "builtin-golia"
    static let gdSourceID = "builtin-gd"

    /// UserDefaults flags set when the user deletes a seeded record.
    static let ikunDismissedKey = "settings.builtinIkunDismissed"
    static let goliaDismissedKey = "settings.builtinGoliaDismissed"
    static let gdDismissedKey = "settings.builtinGdDismissed"

    /// 酸甜贤音源 v26 (ikunshare), key blanked. Declares git/kg/kw/
    /// tx/wy; POSTs to the ikun backend with an X-Api-Key header.
    static let ikunScript = #"""
/*!
 * @name 酸甜贤音源
 * @description vx：gumson 过期时间
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
"""#

    /// Golia贤源 v1.2.0 (Huibq), verbatim. Declares kw/kg/tx/wy/mg;
    /// GETs the public backend with an X-Request-Key header.
    static let goliaScript = #"""
/*!
 * @name Golia贤源
 * @description Github搜索“Rumexs音乐音源”，禁止批量下载！
 * @version v1.2.0
 * @author Huibq
 */
const DEV_ENABLE = false
const API_URL = 'https://lxmusicapi.onrender.com'
const API_KEY = 'share-v3'
const MUSIC_QUALITY = {
  kw: ['128k', '320k'],
  kg: ['128k', '320k'],
  tx: ['128k', '320k'],
  wy: ['128k', '320k'],
  mg: ['128k', '320k'],
}
const MUSIC_SOURCE = Object.keys(MUSIC_QUALITY)
const { EVENT_NAMES, request, on, send, utils, env, version } = globalThis.lx
const httpFetch = (url, options = { method: 'GET' }) => {
  return new Promise((resolve, reject) => {
    request(url, options, (err, resp) => {
      if (err) return reject(err)
      resolve(resp)
    })
  })
}
const handleGetMusicUrl = async (source, musicInfo, quality) => {
  const songId = musicInfo.hash ?? musicInfo.songmid

  const request = await httpFetch(`${API_URL}/url/${source}/${songId}/${quality}`, {
    method: 'GET',
    headers: {
      'Content-Type': 'application/json',
      'User-Agent': `${env ? `lx-music-${env}/${version}` : `lx-usic-request/${version}`}`,
      'X-Request-Key': API_KEY,
    },
  })
  const { body } = request
  if (!body || isNaN(Number(body.code))) throw new Error('unknow error')
  switch (body.code) {
    case 0:
      return body.url
    case 1:
      throw new Error('block ip')
    case 2:
      throw new Error('get music url failed')
    case 4:
      throw new Error('internal server error')
    case 5:
      throw new Error('too many requests')
    case 6:
      throw new Error('param error')
    default:
      throw new Error(body.msg ?? 'unknow error')
  }
}
const musicSources = {}
MUSIC_SOURCE.forEach(item => {
  musicSources[item] = {
    name: item,
    type: 'music',
    actions: ['musicUrl'],
    qualitys: MUSIC_QUALITY[item],
  }
})
on(EVENT_NAMES.request, ({ action, source, info }) => {
  switch (action) {
    case 'musicUrl':
      if (env != 'mobile') {
        console.group(`Handle Action(musicUrl)`)
        console.log('source', source)
        console.log('quality', info.type)
        console.log('musicInfo', info.musicInfo)
        console.groupEnd()
      } else {
        console.log(`Handle Action(musicUrl)`)
        console.log('source', source)
        console.log('quality', info.type)
        console.log('musicInfo', info.musicInfo)
      }
      return handleGetMusicUrl(source, info.musicInfo, info.type)
        .then(data => Promise.resolve(data))
        .catch(err => Promise.reject(err))
    default:
      console.error(`action(${action}) not support`)
      return Promise.reject('action not support')
  }
})
send(EVENT_NAMES.inited, { status: true, openDevTools: DEV_ENABLE, sources: musicSources })
"""#

    /// GD音乐台聚合音源 v1.0.0 (Pax), verbatim. Declares wy/tx/kw/
    /// kg/mg; GETs the public GD API (music-api.gdstudio.xyz)
    /// with no key. Third fallback backend; all five platforms
    /// with lossless qualities (flac/flac24bit).
    static let gdScript = #"""
/**
 * @name GD音乐台聚合音源
 * @description 洛雪音乐自定义源：用 GD音乐台(music.gdstudio.xyz) 的公开聚合 API 解析播放链接，仅限个人非商业使用，使用请注明出处“GD音乐台(music.gdstudio.xyz)”。注意：TVBox 的 MTV1 / csp_MusicGuard 是闭源 jar，无法直接转成洛雪源，这里用 GD API 覆盖网易云 / QQ / 酷我 / 酷狗 / 咪咕，和你截图里的 GD音乐台是同一条线。
 * @version 1.0.0
 * @author Pax
 * @homepage https://music.gdstudio.xyz
 */

const { EVENT_NAMES, request, on, send } = globalThis.lx

// GD 公开 API，站长要求注明出处，个人非商业使用
// 搜索: ?types=search&source=netease&tencent&kuwo...&name=关键词
// 取链: ?types=url&source=netease&id=曲目ID&br=128/192/320/740/999
// 740 = 16bit 无损，999 = 24bit 无损
const API_BASE = 'https://music-api.gdstudio.xyz/api.php'

// 洛雪音质 -> GD br
const QUALITY_MAP = {
  '128k': '128',
  '320k': '320',
  flac: '740',
  flac24bit: '999',
}

// 洛雪源 key -> GD source 参数
const SOURCE_MAP = {
  wy: 'netease', // 网易云音乐，对应截图里的 GD音乐台 / 念心
  tx: 'tencent', // QQ音乐，对应截图里的 VKeys / HYW
  kw: 'kuwo', // 酷我音乐，对应截图里的 念心 / 星海
  kg: 'kugou', // 酷狗音乐
  mg: 'migu', // 咪咕音乐，对应截图里的 咪咕
}

const httpRequest = (url, options = {}) => new Promise((resolve, reject) => {
  request(url, options, (err, resp) => {
    if (err) return reject(err)
    resolve(resp.body)
  })
})

const getSongId = (musicInfo) => {
  // 洛雪传过来的 ID 字段在不同源不一样，按顺序取
  return musicInfo.songmid || musicInfo.hash || musicInfo.id || musicInfo.songId || ''
}

const handleGetMusicUrl = async (source, musicInfo, quality) => {
  const gdSource = SOURCE_MAP[source]
  if (!gdSource) throw new Error('unsupported source: ' + source)

  const songId = getSongId(musicInfo)
  if (!songId) throw new Error('no song id')

  const br = QUALITY_MAP[quality] || '320'
  const url = `${API_BASE}?types=url&source=${gdSource}&id=${encodeURIComponent(songId)}&br=${br}`

  const data = await httpRequest(url, {
    method: 'GET',
    headers: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      Referer: 'https://music.gdstudio.xyz/',
    },
    timeout: 10000,
  })

  // GD 返回 { url, br, size }
  const playUrl = typeof data === 'string' ? data : data && data.url
  if (!playUrl || !/^https?:/.test(playUrl)) {
    throw new Error('get music url failed: ' + JSON.stringify(data || ''))
  }
  return playUrl
}

const musicSources = {}
for (const key of Object.keys(SOURCE_MAP)) {
  const names = {
    wy: '网易云音乐',
    tx: 'QQ音乐',
    kw: '酷我音乐',
    kg: '酷狗音乐',
    mg: '咪咕音乐',
  }
  musicSources[key] = {
    name: names[key],
    type: 'music',
    actions: ['musicUrl'],
    qualitys: ['128k', '320k', 'flac', 'flac24bit'],
  }
}

on(EVENT_NAMES.request, ({ source, action, info }) => {
  if (action !== 'musicUrl') return Promise.reject('action not support: ' + action)
  return handleGetMusicUrl(source, info.musicInfo, info.type).catch((err) => {
    console.log('[GD音乐台]', source, info.type, err)
    return Promise.reject(err)
  })
})

send(EVENT_NAMES.inited, {
  status: true,
  openDevTools: false,
  sources: musicSources,
})
"""#

    /// The seeded ikun record: first in resolve order (paid source,
    /// widest quality ladder). Matches what the import parser
    /// produces for the same script (`@name` → name, kind script,
    /// empty template, 320k default).
    static func seededIkunSource() -> CustomAudioSource {
        CustomAudioSource(
            id: ikunSourceID,
            name: "酸甜贤音源",
            kind: "script",
            template: "",
            quality: "320k",
            script: ikunScript,
            enabled: true
        )
    }

    /// The seeded Golia record: second in resolve order. Adds the
    /// 咪咕 leg the ikun script does not declare.
    static func seededGoliaSource() -> CustomAudioSource {
        CustomAudioSource(
            id: goliaSourceID,
            name: "Golia贤源",
            kind: "script",
            template: "",
            quality: "320k",
            script: goliaScript,
            enabled: true
        )
    }

    /// The seeded GD record: third in resolve order (independent
    /// public backend, no key needed).
    static func seededGdSource() -> CustomAudioSource {
        CustomAudioSource(
            id: gdSourceID,
            name: "GD音乐台聚合音源",
            kind: "script",
            template: "",
            quality: "320k",
            script: gdScript,
            enabled: true
        )
    }

    /// Reads the `API_KEY` value out of a script, if it declares
    /// one (double or single quotes). Nil when the script has no
    /// `API_KEY` assignment at all.
    static func apiKey(in script: String) -> String? {
        // The value may contain JS-escaped characters (\" \\ \' \n \r)
        // written by settingApiKey, so the capture must allow
        // backslash escapes inside the quotes instead of stopping
        // at the first quote character.
        let pattern = #"const API_KEY\s*=\s*(?:"((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)')"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: script,
                  range: NSRange(script.startIndex..., in: script)
              ) else {
            return nil
        }
        let group = match.range(at: 1).location != NSNotFound ? 1 : 2
        guard let valueRange = Range(match.range(at: group), in: script) else {
            return nil
        }
        return unescapeJS(String(script[valueRange]))
    }

    /// Undo the JS string escapes `settingApiKey` writes, one pass
    /// left to right so `\\` is not unescaped twice.
    private static func unescapeJS(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        var escaped = false
        for ch in value {
            if escaped {
                switch ch {
                case "n": out.append("\n")
                case "r": out.append("\r")
                default: out.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        if escaped { out.append("\\") }
        return out
    }

    /// Writes `key` into the script's `API_KEY` assignment,
    /// JS-escaped for the surrounding quotes. Returns the new
    /// script, or nil when the script declares no `API_KEY`.
    static func settingApiKey(_ key: String, in script: String) -> String? {
        // Same escape-aware capture as apiKey: the stored value may
        // itself contain \" or \\ from a previous write, so the
        // range to replace must span the whole quoted value.
        let pattern = #"const API_KEY\s*=\s*(?:"((?:\\.|[^"\\])*)"|'((?:\\.|[^'\\])*)')"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: script,
                  range: NSRange(script.startIndex..., in: script)
              ) else {
            return nil
        }
        let group = match.range(at: 1).location != NSNotFound ? 1 : 2
        guard let valueRange = Range(match.range(at: group), in: script) else {
            return nil
        }
        // Replace only the captured value range (not a regex
        // template, so `$` or `\` in a key cannot be reinterpreted).
        // The value is always written double-quoted; valid JS
        // either way.
        let escaped = key
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        var updated = script
        updated.replaceSubrange(valueRange, with: escaped)
        return updated
    }
}
