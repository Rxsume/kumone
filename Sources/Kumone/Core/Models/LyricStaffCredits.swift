// Sources/Kumone/Core/Models/LyricStaffCredits.swift
//
// Folia staff-credits handling, ported to Swift (Folia
// `staffCredits.ts` + `staffCreditsPolicy.ts` + `staffCreditsDecision.ts`
// + `staffCreditsAbsorb.ts` + `staffCreditsRewrite.ts`).
//
// The leading 作词/作曲/编曲 (staff / credits) block of a song: detect
// it, then keep it, hide it, or spread it across the intro (smart),
// decided by the intro-time budget. Runs inside `LyricsParser.parse`
// after the per-line filter rules, so the two mechanisms compose.
//
// Deliberately NOT ported:
// - Folia's interlude stripping/rebuilding (`isInterludeLine`,
// `finalizeParsedLyricLines`): Golia has no interlude lines — its
// lines are just timed lines — so there is nothing to strip.
// - Folia's `isSpacedStaffLine` (no-colon staff like "编曲 某某"): it is
// only used for the pure-music-prompt context, never for leading-block
// detection.
// - Folia's `ensureLyricDataRenderHints`: render hints are Folia's own
// renderer state; Golia's renderer reads `LyricLine` directly.
// - Intro-duration reflow has no separate renderer hook in Golia, so it
// happens here at parse time instead: a `retime` verdict rescales the
// staff lines' time/end/word timings inside the parsed lines (the same
// arithmetic as Folia's `retimeLine`, including its per-word rescale),
// which is exactly what the renderer then displays.

import Foundation

/// What happens to the leading staff block (Folia `LyricStaffPolicy`).
enum LyricStaffPolicy: String, Codable, CaseIterable, Identifiable {
case keep, smart, hide

var id: String { rawValue}

var displayName: String {
switch self {
case.keep: return "保留"
case.smart: return "智能"
case.hide: return "隐藏"
}
}
}

/// Whether lines adjacent to the staff block are pulled into it
/// (Folia `LyricStaffAbsorbMode`). The test is a single line's duration
/// (under "每行最少停留"), not its word count.
enum LyricStaffAbsorbMode: String, Codable, CaseIterable, Identifiable {
case off, before, both

var id: String { rawValue}

var displayName: String {
switch self {
case.off: return "不吸收"
case.before: return "仅之前"
case.both: return "前后都吸收"
}
}
}

enum LyricStaffVerdict {
case none, keep, retime, hide
}

struct LyricStaffDecision {
var verdict: LyricStaffVerdict
/// Staff lines hit, not counting absorbed lines.
var blockLineCount: Int
/// Seconds from the block's start to the first lyric line.
var windowSeconds: TimeInterval
/// Seconds needed to show all display lines at min dwell.
var requiredSeconds: TimeInterval
/// Indexes judged to be staff lines.
var staffIndexes: [Int]
/// All indexes the block occupies, incl. separators and absorbed
/// lines; hiding removes this whole group.
var memberIndexes: [Int]
var absorbedLineCount: Int
var absorbedIndexes: [Int]
}

struct StaffCreditBlock {
/// Indexes judged to be staff lines.
var staffIndexes: [Int]
/// All indexes the block occupies, incl. block-internal and
/// block-trailing separator lines, plus absorbed lines.
var memberIndexes: [Int]
/// Index of the first real lyric line after the block; nil when the
/// whole song is staff lines.
var firstLyricIndex: Int?
/// Lines tolerated before the block (usually a title line).
var headerLineCount: Int
/// Lines absorbed into the block, ascending; empty from detection,
/// filled by absorb.
var absorbedIndexes: [Int]
}

enum LyricStaffCredits {
/// Buffer left between the last staff line and the first lyric line,
/// so the switch is not face-to-face (Folia `TAIL_MARGIN_SECONDS`).
static let tailMarginSeconds: TimeInterval = 1

/// The word list comes from staff fields actually seen in lyric
/// files; it stays loose, and the "colon + short pre-colon part +
/// leading block only" triple constraint is what holds back false
/// positives (Folia `STAFF_ROLE_KEYWORDS`).
static let roleKeywords: [String] = [
"作词", "作曲", "词", "曲",
"编曲", "制作人", "演唱", "吉他",
"贝斯", "混音", "母带", "录音",
"监制", "出品", "策划", "统筹",
"设计", "宣传", "运营", "总监",
"鸣谢", "工作室", "版权", "发行",
"艺人统筹", "制作总监", "总顾问", "出品人",
"总监制", "战略", "视觉", "资产管理",
"总策划", "音乐总监", "制作统筹", "音乐版权",
"创意顾问", "平面设计", "宣传物料", "黑胶设计",
"项目总统筹", "艺人协力", "项目协力", "策略行销",
"视觉统筹", "媒介", "宣传营销", "联合出品",
"协办单位", "宣发合作伙伴", "独家短视频平台", "主题歌音乐专辑工作团队",
"工作室负责人", "协作", "平面摄影师", "海报设计团队",
"企划", "和声编写", "画师", "场景画师",
"PV底图", "美工", "题字", "视频",
"人声后期", "PV", "封面", "单曲封面",
"单曲封面及标准字设计", "单曲封面摄影", "歌词字幕", "歌手",
"原唱", "和声", "弦乐", "键盘",
"鼓", "制作", "Producer", "Composer",
"Lyricist", "Arranger", "Vocal", "Guitar",
"Bass", "Mixing", "Mastering", "Recording",
"Arrangement", "Lyrics", "Music",
]

/// Signature-free English staff phrasing (Folia `STAFF_BY_PREFIX`).
static let staffByPrefixPattern = #"^\s*(?:produced|written|composed|arranged|mixed|mastered|recorded|performed)\s+by\s+\S"#

/// The UI's custom-pattern example, not the built-in rule itself
/// (the built-in rule is too long to be a useful example).
static let staffPatternExample = #"^(?:作词|作曲|编曲|制作人|混音|母带)\s*[:：]"#

private static func escapeRegExp(_ value: String) -> String {
NSRegularExpression.escapedPattern(for: value)
}

/// The built-in staff-line test (Folia `BUILT_IN_STAFF_PATTERN`):
/// the keyword must anchor the start of the pre-colon part, followed
/// only by another keyword or a Latin alias — never by Chinese text,
/// which is what keeps "鼓起勇气：向前走" (a lyric line) out while
/// "录音棚 Recording Studio：…" still matches through the structural
/// continuation below.
static func builtInStaffRegex() -> NSRegularExpression? {
let group = "(?:\(roleKeywords.map(escapeRegExp).joined(separator: "|")))"
let latinAlias = #"(?:\s*[A-Za-z][A-Za-z0-9 .&'/-]*)?"#
let pattern = #"^\s*[\[（(【]?\s*\#(group)(?:\s*[/、&+,，·・和]?\s*\#(group))*\#(latinAlias)\s*[\]）)】]?\s*[:：]\s*\S"#
return try? NSRegularExpression(pattern: pattern, options:.caseInsensitive)
}

/// Why a custom staff pattern is invalid, or nil (Folia
/// `getLyricStaffPatternError`).
static func patternError(_ pattern: String?) -> String? {
let normalized = pattern?.trimmingCharacters(in:.whitespacesAndNewlines)?? ""
guard!normalized.isEmpty else { return nil}
do {
_ = try NSRegularExpression(pattern: normalized, options:.caseInsensitive)
return nil
} catch {
return error.localizedDescription
}
}

/// The staff-line matcher: an empty pattern uses the built-in word
/// list; a filled one replaces the built-in rule wholesale (the
/// position constraints still apply). An invalid custom pattern falls
/// back to the built-in list (Folia `createStaffCreditMatcher`).
static func staffMatcher(pattern: String?) -> (LyricLine) -> Bool {
let normalized = pattern?.trimmingCharacters(in:.whitespacesAndNewlines)?? ""
let custom: NSRegularExpression? = normalized.isEmpty
? nil: try? NSRegularExpression(pattern: normalized, options:.caseInsensitive)
let builtIn = builtInStaffRegex()
let byPrefix = try? NSRegularExpression(pattern: staffByPrefixPattern, options:.caseInsensitive)
return { line in
let text = line.text.trimmingCharacters(in:.whitespaces)
guard!text.isEmpty else { return false}
if let custom {
let range = NSRange(text.startIndex..., in: text)
return custom.firstMatch(in: text, options: [], range: range)!= nil
}
let range = NSRange(text.startIndex..., in: text)
if let builtIn, builtIn.firstMatch(in: text, options: [], range: range)!= nil { return true}
if let byPrefix, byPrefix.firstMatch(in: text, options: [], range: range)!= nil { return true}
return false
}
}

/// Only symbols, punctuation or decorative characters, and short
/// ("#", "//", "---") — staff blocks use them as separators.
static func isFillerLine(_ line: LyricLine) -> Bool {
let text = line.text.trimmingCharacters(in:.whitespaces)
guard!text.isEmpty else { return true}
guard text.count <= 8 else { return false}
return text.unicodeScalars.allSatisfy { scalar in
!CharacterSet.letters.contains(scalar) &&!CharacterSet.decimalDigits.contains(scalar)
}
}

/// "Field name + colon + content" shape. The field name is capped at
/// 60 characters because bilingual credits run long; the safety net
/// is not the length but that this rule only fires inside a leading
/// block, right after a dictionary hit, with at least two lines in a
/// row. Sentence punctuation in the field name disqualifies it
/// (Folia `isColonShaped`).
static func isColonShaped(_ line: LyricLine) -> Bool {
let text = line.text.trimmingCharacters(in:.whitespaces)
guard let regex = try? NSRegularExpression(pattern: #"^[^:：，。！？；…!?]{1,60}[:：]\s*\S"#) else { return false}
let range = NSRange(text.startIndex..., in: text)
return regex.firstMatch(in: text, options: [], range: range)!= nil
}

/// A title line often sits at index 0 ("歌名 - 歌手"), so the
/// detector tolerates it before the staff block.
private static func isHeaderLike(_ line: LyricLine, title: String?, artist: String?) -> Bool {
let text = line.text.trimmingCharacters(in:.whitespaces)
guard!text.isEmpty else { return true}
if text.range(of: #"\s[-–—]\s"#, options:.regularExpression)!= nil { return true}
if let title,!title.trimmingCharacters(in:.whitespaces).isEmpty, text.contains(title.trimmingCharacters(in:.whitespaces)) { return true}
if let artist,!artist.trimmingCharacters(in:.whitespaces).isEmpty, text.contains(artist.trimmingCharacters(in:.whitespaces)) { return true}
return false
}

/// Detects the leading staff block (Folia `detectLeadingStaffBlock`).
/// A block needs at least 2 staff lines, at least 2 dictionary hits
/// to establish "this is a credits block", and a trailing structural
/// run of at least 2 lines — a lone structural line is more likely a
/// lyric ("他说：我爱你") than a credit.
static func detectLeadingStaffBlock(
_ lines: [LyricLine],
isStaffLine: (LyricLine) -> Bool,
maxHeaderLines: Int = 2,
minStaffLines: Int = 2,
minDictionaryHits: Int = 2,
minTrailingStructuralRun: Int = 2,
title: String? = nil,
artist: String? = nil
) -> StaffCreditBlock? {
var cursor = 0
var headerLineCount = 0
while cursor < lines.count &&!isStaffLine(lines[cursor]) {
if isFillerLine(lines[cursor]) {
cursor += 1
continue
}
guard headerLineCount < maxHeaderLines, isHeaderLike(lines[cursor], title: title, artist: artist) else {
return nil
}
headerLineCount += 1
cursor += 1
}
guard cursor < lines.count else { return nil}

struct Accepted {
let index: Int
let fromDictionary: Bool
let leadingFiller: [Int]
}
var accepted: [Accepted] = []
var dictionaryHits = 0
var pendingFiller: [Int] = []
var scan = cursor
while scan < lines.count {
let line = lines[scan]
if isFillerLine(line) {
pendingFiller.append(scan)
scan += 1
continue
}
let fromDictionary = isStaffLine(line)
let isStructural = dictionaryHits >= minDictionaryHits && isColonShaped(line)
guard fromDictionary || isStructural else { break}
if fromDictionary { dictionaryHits += 1}
accepted.append(Accepted(index: scan, fromDictionary: fromDictionary, leadingFiller: pendingFiller))
pendingFiller = []
scan += 1
}

// A trailing run of structurally-continued lines shorter than the
// minimum goes back: "指挥 Conductor：X" always comes in a group,
// a lone lyric line does not.
var trailingStructural = 0
while trailingStructural < accepted.count &&!accepted[accepted.count - 1 - trailingStructural].fromDictionary {
trailingStructural += 1
}
if trailingStructural > 0 && trailingStructural < minTrailingStructuralRun {
accepted.removeLast(trailingStructural)
pendingFiller = []
}

// A single-line block is never touched: one lone credit line
// does not spam, and misjudging it would delete a real lyric.
guard accepted.count >= minStaffLines else { return nil}

let staffIndexes = accepted.map(\.index)
var memberIndexes = accepted.flatMap { [...$0.leadingFiller, $0.index]}
// Separator lines right after the block travel with it, or hiding
// the block would leave a run of orphaned "#" lines behind.
memberIndexes.append(contentsOf: pendingFiller)

let lastMemberIndex = memberIndexes[memberIndexes.count - 1]
var firstLyricIndex: Int? = nil
for index in (lastMemberIndex + 1)..<lines.count where!isFillerLine(lines[index]) {
firstLyricIndex = index
break
}
return StaffCreditBlock(
staffIndexes: staffIndexes,
memberIndexes: memberIndexes,
firstLyricIndex: firstLyricIndex,
headerLineCount: headerLineCount,
absorbedIndexes: []
)
}

/// Pulls lines adjacent to the block into it (Folia
/// `absorbAdjacentLines`): `before` scans backwards only, `both`
/// scans both ways. The test is a single line's duration (under
/// "每行最少停留"), not its word count. There is no line-count cap:
/// the boundary is decided by "too short" alone.
static func absorbAdjacentLines(
_ lines: [LyricLine],
block: StaffCreditBlock,
mode: LyricStaffAbsorbMode,
maxDuration: TimeInterval
) -> StaffCreditBlock {
guard mode!=.off,!block.staffIndexes.isEmpty else { return block}
func isShortLine(_ line: LyricLine) -> Bool {
!isFillerLine(line) && line.end - line.time < maxDuration
}
let memberSet = Set(block.memberIndexes)
let blockStart = block.memberIndexes[0]
let lastMember = block.memberIndexes[block.memberIndexes.count - 1]
func collectShortRun(from start: Int, step: Int) -> [Int] {
var taken: [Int] = []
var index = start
while index >= 0 && index < lines.count {
guard!memberSet.contains(index), isShortLine(lines[index]) else { break}
taken.append(index)
index += step
}
return taken
}
var absorbed = collectShortRun(from: blockStart - 1, step: -1)
if mode ==.both {
// Keep the last line: absorbing the whole song would leave no
// "first lyric line" and the decision would degrade to keep.
let lastIndex = lines.count - 1
let backward = collectShortRun(from: min(lastMember + 1, lastIndex), step: 1)
.filter { $0 < lastIndex}
absorbed.append(contentsOf: backward)
}
guard!absorbed.isEmpty else { return block}
let absorbedIndexes = absorbed.sorted()
var memberIndexes = (block.memberIndexes + absorbedIndexes).sorted()
for index in (memberIndexes[memberIndexes.count - 1] + 1)..<lines.count {
guard isFillerLine(lines[index]) else { break}
memberIndexes.append(index)
}
// After collecting the trailing fillers, the next line is a real
// lyric line. The block eating to the end of the array takes no
// first lyric, and the decision degrades to keep, same as the
// detector's own handling.
let nextIndex = memberIndexes[memberIndexes.count - 1] + 1
let firstLyricIndex: Int? = nextIndex < lines.count? nextIndex: nil
return StaffCreditBlock(
staffIndexes: block.staffIndexes,
memberIndexes: memberIndexes,
firstLyricIndex: firstLyricIndex,
headerLineCount: block.headerLineCount,
absorbedIndexes: absorbedIndexes
)
}

/// The intro-time budget (Folia `resolveStaffDecision`): the block
/// fits when the intro window covers every display line at min dwell
/// plus the tail margin. When the whole song is staff lines there is
/// no "intro" and nothing else to show, so it stays.
static func resolveDecision(
_ lines: [LyricLine],
block: StaffCreditBlock,
minDwell: TimeInterval
) -> LyricStaffDecision {
let displayIndexes = (block.staffIndexes + block.absorbedIndexes).sorted()
let displayLines = displayIndexes.map { lines[$0]}
let blockLineCount = block.staffIndexes.count
let windowStart = lines[block.memberIndexes[0]].time
let firstLyric = block.firstLyricIndex.map { lines[$0]}
let base = LyricStaffDecision(
verdict:.none,
blockLineCount: blockLineCount,
windowSeconds: 0,
requiredSeconds: TimeInterval(displayLines.count) * minDwell + tailMarginSeconds,
staffIndexes: block.staffIndexes,
memberIndexes: block.memberIndexes,
absorbedLineCount: block.absorbedIndexes.count,
absorbedIndexes: block.absorbedIndexes
)
guard let firstLyric else {
let lastLine = lines[lines.count - 1]
var decision = base
decision.verdict =.keep
decision.windowSeconds = max(0, lastLine.end - windowStart)
return decision
}
let windowSeconds = max(0, firstLyric.time - windowStart)
var decision = base
decision.windowSeconds = windowSeconds
guard windowSeconds >= base.requiredSeconds else {
decision.verdict =.hide
return decision
}
// Only retime when the original stamps are too dense; a block
// the author already spaced out stays exactly as written.
let windowEnd = firstLyric.time - tailMarginSeconds
var needsRetime = false
for index in displayLines.indices {
let nextStart = index + 1 < displayLines.count
? displayLines[index + 1].time: windowEnd
if nextStart - displayLines[index].time < minDwell {
needsRetime = true
break
}
}
decision.verdict = needsRetime?.retime:.keep
return decision
}

/// Rescales one line (and its word timings) into a new slot (Folia
/// `retimeLine`): the words' text joined is still the line's text, so
/// the karaoke wipe keeps mapping one opacity to one character.
/// Translation/romaji/furigana carry no timings and are untouched.
static func retimeLine(_ line: LyricLine, startTime: TimeInterval, endTime: TimeInterval) -> LyricLine {
let originalSpan = max(line.end - line.time, 0.001)
let scale = (endTime - startTime) / originalSpan
let shift: (TimeInterval) -> TimeInterval = { time in
startTime + (time - line.time) * scale
}
return LyricLine(
id: line.id,
time: startTime,
end: endTime,
text: line.text,
translation: line.translation,
romaji: line.romaji,
furigana: line.furigana,
words: line.words?.map { word in
LyricWord(
text: word.text,
start: shift(word.start),
duration: word.duration * scale)
}
)
}

/// Turns a decision into new lines (Folia `rebuildStaffLines`): a
/// `retime` verdict spreads the staff + absorbed lines evenly across
/// the intro window (each slot at least min dwell); any other
/// removal verdict drops the whole member group. Separator lines do
/// not survive a retime: they only separated staff on the original
/// timeline and would just take up slots.
static func rebuildLines(
_ lines: [LyricLine],
block: StaffCreditBlock,
decision: LyricStaffDecision,
minDwell: TimeInterval
) -> [LyricLine] {
let memberIndexes = Set(block.memberIndexes)
let spreadIndexes = (block.staffIndexes + block.absorbedIndexes).sorted()
let spreadLines = spreadIndexes.map { lines[$0]}
let windowStart = lines[block.memberIndexes[0]].time
let firstLyric = block.firstLyricIndex.map { lines[$0]}
let windowEnd = firstLyric
? firstLyric.time - tailMarginSeconds
: spreadLines[spreadLines.count - 1].end
let replacement: [LyricLine]
if decision.verdict ==.retime {
replacement = spreadLines.enumerated().map { index, line in
let slot = max((windowEnd - windowStart) / TimeInterval(spreadLines.count), minDwell)
return retimeLine(
line,
startTime: windowStart + TimeInterval(index) * slot,
endTime: windowStart + TimeInterval(index + 1) * slot)
}
} else {
replacement = []
}
var next: [LyricLine] = []
for (index, line) in lines.enumerated() {
guard!memberIndexes.contains(index) else {
if index == block.memberIndexes[0] {
next.append(contentsOf: replacement)
}
continue
}
next.append(line)
}
return next
}

/// Applies the staff policy to parsed lines (Folia
/// `applyLyricStaffPolicy`): `keep` is a no-op; `hide` removes the
/// detected block with no absorb and no budget decision; `smart`
/// absorbs first (the budget must be computed on the absorbed block),
/// then keeps, retimes, or hides by the intro-time budget.
static func applyPolicy(_ lines: [LyricLine], settings: LyricFilterSettings) -> [LyricLine] {
guard settings.staffPolicy!=.keep,!lines.isEmpty else { return lines}
let minDwell = LyricFilterSettings.clampedDwell(settings.staffMinDwellSeconds)
let matcher = staffMatcher(pattern: settings.staffPattern)
guard var block = detectLeadingStaffBlock(
lines, isStaffLine: matcher, title: settings.title, artist: settings.artist
) else { return lines}
if settings.staffPolicy ==.hide {
let memberIndexes = Set(block.memberIndexes)
return lines.enumerated().filter {!memberIndexes.contains($0.offset)}.map(\.element)
}
block = absorbAdjacentLines(lines, block: block, mode: settings.staffAbsorbMode, maxDuration: minDwell)
let decision = resolveDecision(lines, block: block, minDwell: minDwell)
guard decision.verdict ==.hide || decision.verdict ==.retime else { return lines}
return rebuildLines(lines, block: block, decision: decision, minDwell: minDwell)
}
}
