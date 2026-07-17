import Foundation
import LimitMonitorCore

var passes = 0
var failures = 0

func check(_ condition: Bool, _ message: String) {
    if condition {
        passes += 1
        print("ok   \(message)")
    } else {
        failures += 1
        print("FAIL \(message)")
    }
}

func eq<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual == expected {
        passes += 1
        print("ok   \(message)")
    } else {
        failures += 1
        print("FAIL \(message): got \(actual), expected \(expected)")
    }
}

func loadFixture(_ path: String) -> Data {
    guard FileManager.default.fileExists(atPath: path),
          let data = FileManager.default.contents(atPath: path) else {
        print("FATAL: \(path) not found/unreadable — run `swift run checks` from the package root (macos/)")
        exit(2)
    }
    return data
}

// -- Fixtures (CWD must be the package root) ----------------------------------

let fixtureData = loadFixture("fixtures/usage_sample.json")
let codexFixtureData = loadFixture("fixtures/codex_usage_sample.json")
let codexAliasData = loadFixture("fixtures/codex_usage_alias.json")
let cursorFixtureData = loadFixture("fixtures/cursor_usage_summary_sample.json")
let cursorOnDemandData = loadFixture("fixtures/cursor_usage_summary_ondemand.json")

// -- 1. Fixture parses into 3 limits -----------------------------------------

let limits = UsageParser.parseLimits(data: fixtureData)
guard limits.count == 3 else {
    print("FATAL: fixture parsed into \(limits.count) limits, expected 3")
    exit(1)
}
eq(limits.map(\.kind), ["session", "weekly_all", "weekly_scoped"], "1. kinds in API order")
eq(limits.map(\.percent), [10, 23, 39], "1. percents 10/23/39")
eq(limits[2].scopeDisplayName, "Fable", "1. scope display_name Fable on third limit")
eq(limits[0].scopeDisplayName, nil, "1. session has no scope")
eq(limits.map(\.provider), ["claude", "claude", "claude"], "1. claude parser stamps provider claude")

// -- 2. Date parsing (6-digit fractional seconds trap) ------------------------

check(limits.allSatisfy { $0.resetsAt != nil }, "2. all fixture resets_at parse non-nil")
let utc = DateFormatter()
utc.locale = Locale(identifier: "en_US_POSIX")
utc.timeZone = TimeZone(secondsFromGMT: 0)
utc.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
eq(utc.string(from: limits[0].resetsAt!), "2026-07-16T22:59:59", "2. session resets_at exact UTC instant")
eq(utc.string(from: limits[1].resetsAt!), "2026-07-18T07:59:59", "2. weekly_all resets_at exact UTC instant")
check(limits[0].resetsAt! < limits[1].resetsAt! && limits[0].resetsAt! < limits[2].resetsAt!,
      "2. session reset earlier than both weekly resets")

// -- 3. Legacy fallback -------------------------------------------------------

var legacyRoot = (try? JSONSerialization.jsonObject(with: fixtureData)) as? [String: Any] ?? [:]
legacyRoot.removeValue(forKey: "limits")
let legacy = UsageParser.parseLimits(root: legacyRoot)
eq(legacy.count, 2, "3. legacy fallback synthesizes 2 entries")
eq(legacy.map(\.kind), ["session", "weekly_all"], "3. legacy kinds")
eq(legacy.map(\.percent), [10, 23], "3. legacy percents from utilization")
check(legacy.allSatisfy { $0.resetsAt != nil }, "3. legacy resets_at parsed")

// -- 4. Title formatting ------------------------------------------------------

eq(TitleFormatter.separator, " \u{2502} ", "4. segment separator is U+2502")
eq(TitleFormatter.providerSeparator, " \u{2016} ", "4. provider separator is U+2016")
let segments = TitleFormatter.segments(for: limits)
eq(segments.map(\.text), ["5h●10%", "7d●23%", "7d●39% Fable"], "4. title segments")
eq(segments.map(\.level), [Level.green, .green, .green], "4. per-segment levels green/green/green")
eq(TitleFormatter.plainTitle(for: limits, stale: false),
   "5h●10% \u{2502} 7d●23% \u{2502} 7d●39% Fable",
   "4. plain title joined by \u{2502}")
var bumped = limits
bumped[2].percent = 95
let bumpedSegments = TitleFormatter.segments(for: bumped)
eq(bumpedSegments[2].level, Level.red, "4. limit bumped to 95 → its segment red")
eq(bumpedSegments[2].text, "7d●95% Fable", "4. bumped segment text")
eq(bumpedSegments[0].level, Level.green, "4. other segments unchanged (first)")
eq(bumpedSegments[1].level, Level.green, "4. other segments unchanged (second)")
check(TitleFormatter.plainTitle(for: limits, stale: true).hasPrefix("⚠5h●10%"),
      "4. stale/expired state adds ⚠ before first segment")

// -- 5. RU labels ---------------------------------------------------------------

eq(Labels.menuLabel(for: limits[0]), "5-часовой", "5. session label")
eq(Labels.menuLabel(for: limits[1]), "Недельный (все модели)", "5. weekly_all label")
eq(Labels.menuLabel(for: limits[2]), "Недельный · Fable", "5. weekly_scoped label")
let unknownScoped = LimitEntry(kind: "mega_promo", percent: 5, scopeDisplayName: "Zap")
let unknownBare = LimitEntry(kind: "mega_promo", percent: 5)
eq(Labels.menuLabel(for: unknownScoped), "Mega promo · Zap", "5. unknown kind + scope label")
eq(Labels.menuLabel(for: unknownBare), "Mega promo", "5. unknown kind bare label (humanized)")
eq(Labels.windowLabel(for: limits[0]), "5h", "5. window label session")
eq(Labels.windowLabel(for: limits[1]), "7d", "5. window label weekly_all")
eq(Labels.windowLabel(for: limits[2]), "7d", "5. window label weekly_scoped = 7d")
eq(Labels.windowLabel(for: unknownScoped), "mega_promo", "5. window label unknown w/o group = raw kind")
eq(Labels.windowLabel(for: unknownBare), "mega_promo", "5. window label unknown = raw kind")
let unknownWeekly = LimitEntry(kind: "mega_promo", group: "weekly", percent: 5, scopeDisplayName: "Zap")
eq(Labels.windowLabel(for: unknownWeekly), "7d", "5. window label unknown w/ weekly group = 7d")
eq(TitleFormatter.segments(for: [unknownWeekly]).map(\.text), ["7d●5% Zap"], "5. unknown weekly segment")

// -- 6. Reset notification planning --------------------------------------------

let now = ISODateParser.parse("2026-07-16T20:00:00.000000+00:00")!
let plan = NotificationPlanner.plan(limits: limits, now: now, alreadyNotified: [:])
eq(plan.scheduled.count, 3, "6. plans 3 scheduled reset notifications")
eq(plan.scheduled.map(\.identifier), [
    "reset|claude|session||2026-07-16T23:00:00+00:00",
    "reset|claude|weekly_all||2026-07-18T08:00:00+00:00",
    "reset|claude|weekly_scoped|Fable|2026-07-18T08:00:00+00:00",
], "6. reset identifiers: provider-prefixed, minute-rounded canonical stamp")
let jitterA = limits[0].withResetsAt("2026-07-16T22:59:59.939319+00:00")
let jitterB = limits[0].withResetsAt("2026-07-16T23:00:00.108296+00:00")
eq(NotificationPlanner.resetIdentifier(for: jitterA),
   NotificationPlanner.resetIdentifier(for: jitterB),
   "6. jittered resets_at across minute boundary → one reset identifier")
eq(NotificationPlanner.resetIdentifier(for: jitterA), "reset|claude|session||2026-07-16T23:00:00+00:00",
   "6. jittered stamp normalizes to the boundary minute")
check(abs(plan.scheduled[0].fireDate.timeIntervalSince(limits[0].resetsAt!) - 5) < 0.01,
      "6. fires at resets_at + 5 s")
eq(plan.scheduled[0].title, "Лимиты Claude обновились", "6. reset title")
eq(plan.scheduled[0].body, "5-часовое окно сброшено — можно работать.", "6. session reset body")
eq(plan.scheduled[1].body, "Недельный лимит сброшен.", "6. weekly_all reset body")
eq(plan.scheduled[2].body, "Недельный лимит Fable сброшен.", "6. weekly_scoped reset body")
eq(plan.immediate.count, 0, "6. no exhaustion at fixture percents")
var zeroed = limits
zeroed[0].percent = 0
eq(NotificationPlanner.plan(limits: zeroed, now: now, alreadyNotified: [:]).scheduled.count, 2,
   "6. percent = 0 limit skipped")
let afterAll = ISODateParser.parse("2026-07-19T00:00:00.000000+00:00")!
eq(NotificationPlanner.plan(limits: limits, now: afterAll, alreadyNotified: [:]).scheduled.count, 0,
   "6. past resets_at skipped")

// -- 7. Credentials parsing ------------------------------------------------------

let credsJSON = #"{"claudeAiOauth":{"accessToken":"sk-check-fake","refreshToken":"r","expiresAt":1789000000000,"scopes":["user:inference"],"subscriptionType":"max"}}"#
let creds = CredentialsParser.parse(data: Data(credsJSON.utf8))
check(creds != nil, "7. credentials JSON parses")
eq(creds?.accessToken, "sk-check-fake", "7. accessToken extracted")
if let creds {
    check(!creds.isExpired(now: Date(timeIntervalSince1970: 1_789_000_000 - 100)),
          "7. not expired before expiresAt")
    check(creds.isExpired(now: Date(timeIntervalSince1970: 1_789_000_000 + 100)),
          "7. expired after expiresAt (ms epoch honored)")
}
check(CredentialsParser.parse(data: Data("{}".utf8)) == nil, "7. missing claudeAiOauth → nil")
check(CredentialsParser.parse(data: Data(#"{"claudeAiOauth":{"expiresAt":1}}"#.utf8)) == nil,
      "7. missing accessToken → nil")
let noExpiry = CredentialsParser.parse(data: Data(#"{"claudeAiOauth":{"accessToken":"x"}}"#.utf8))
check(noExpiry?.isExpired(now: Date()) == false, "7. no expiresAt → treated as not expired")

// -- 8. Level mapping -------------------------------------------------------------

eq(Level.level(percent: 0, severity: "normal"), Level.green, "8. 0 → green")
eq(Level.level(percent: 49, severity: "normal"), Level.green, "8. 49 → green")
eq(Level.level(percent: 50, severity: "normal"), Level.yellow, "8. 50 → yellow")
eq(Level.level(percent: 74, severity: "normal"), Level.yellow, "8. 74 → yellow")
eq(Level.level(percent: 75, severity: "normal"), Level.orange, "8. 75 → orange")
eq(Level.level(percent: 89, severity: "normal"), Level.orange, "8. 89 → orange")
eq(Level.level(percent: 90, severity: "normal"), Level.red, "8. 90 → red")
eq(Level.level(percent: 100, severity: "normal"), Level.red, "8. 100 → red")
eq(Level.level(percent: 120, severity: "normal"), Level.red, "8. 120 → red")
eq(Level.level(percent: 10, severity: "overloaded"), Level.orange, "8. non-normal severity at 10% → orange")
eq(Level.level(percent: 95, severity: "overloaded"), Level.red, "8. non-normal severity keeps red")

// -- 9. Exhaustion planning ---------------------------------------------------------

var exhausted = limits
exhausted[0].percent = 100
let plan9 = NotificationPlanner.plan(limits: exhausted, now: now, alreadyNotified: [:])
eq(plan9.immediate.count, 1, "9. limit at 100% → exactly one immediate notification")
if let item = plan9.immediate.first {
    eq(item.identifier, "exhausted|claude|session||2026-07-16T23:00:00+00:00", "9. exhausted identifier")
    eq(NotificationPlanner.exhaustedIdentifier(for: exhausted[0].withResetsAt("2026-07-16T23:00:00.308656+00:00")),
       item.identifier, "9. exhausted identifier stable under resets_at jitter")
    eq(item.title, "Claude: 5-часовой лимит исчерпан", "9. title names the limit")
    check(item.body.hasPrefix("Возобновится через "), "9. RU body starts with Возобновится через")
    let expectedAbs = TimeFormat.absolute(exhausted[0].resetsAt!, now: now)
    check(item.body.contains(expectedAbs) && item.body.hasSuffix("."), "9. body contains the reset time")
    let plan9b = NotificationPlanner.plan(limits: exhausted, now: now,
                                          alreadyNotified: [item.identifier: true])
    eq(plan9b.immediate.count, 0, "9. identifier in alreadyNotified → nothing planned")
    let pastId = "exhausted|session||2026-07-10T00:00:00.000000+00:00"
    let plan9c = NotificationPlanner.plan(limits: exhausted, now: now,
                                          alreadyNotified: [pastId: true, item.identifier: true])
    check(plan9c.prunedNotified[pastId] == nil, "9. past resets_at pruned (incl. legacy raw-stamp keys)")
    check(plan9c.prunedNotified[item.identifier] == true, "9. identifier with future resets_at kept")
}
var nullReset = exhausted[0]
nullReset.resetsAt = nil
nullReset.resetsAtRaw = nil
let planNull = NotificationPlanner.plan(limits: [nullReset], now: now, alreadyNotified: [:])
eq(planNull.immediate.first?.body, "Время возобновления неизвестно.", "9. null resets_at body")
eq(planNull.immediate.first?.identifier, "exhausted|claude|session||", "9. null resets_at identifier")
let nullId = "exhausted|claude|session||"
let planNull2 = NotificationPlanner.plan(limits: [nullReset], now: now, alreadyNotified: [nullId: true])
eq(planNull2.immediate.count, 0, "9. null-stamp identifier deduped while still exhausted")
check(planNull2.prunedNotified[nullId] == true, "9. null-stamp entry kept while limit still exhausted")
let planNull3 = NotificationPlanner.plan(limits: limits, now: now, alreadyNotified: [nullId: true])
check(planNull3.prunedNotified[nullId] == nil, "9. null-stamp entry dropped once limit no longer exhausted")
let weeklyExhaustedTitle = Labels.exhaustedTitle(for: LimitEntry(kind: "weekly_all", percent: 100))
eq(weeklyExhaustedTitle, "Claude: недельный лимит исчерпан", "9. weekly_all exhausted title")
eq(Labels.exhaustedTitle(for: exhausted[2].withPercent(100)), "Claude: недельный лимит Fable исчерпан",
   "9. scoped exhausted title")
eq(Labels.exhaustedTitle(for: unknownScoped), "Claude: лимит Mega promo · Zap исчерпан",
   "9. unknown kind exhausted title")

// menu rows (exhausted vs normal form)
let exhaustedRow = MenuText.infoRow(for: exhausted[0], now: now)
check(exhaustedRow.hasPrefix("5-часовой: исчерпан · возобновится "), "9. exhausted menu row form")
check(!exhaustedRow.contains("%"), "9. exhausted row has no percent")
let normalRow = MenuText.infoRow(for: limits[0], now: now)
check(normalRow.hasPrefix("5-часовой: 10% · сброс в ") && normalRow.contains("(через "),
      "9. near menu row has absolute + relative time")
let weeklyRow = MenuText.infoRow(for: limits[1], now: now)
check(weeklyRow.hasPrefix("Недельный (все модели): 23% · сброс ") && !weeklyRow.contains("(через"),
      "9. far menu row uses weekday form without relative")

// -- 10. Codex usage parsing (canonical + alias fixtures) -------------------------

// The fixtures are authored to normalize IDENTICALLY for this exact `now`
// (2026-07-16T12:00:00Z, epoch 1784203200) — see SPEC.
let codexNow = Date(timeIntervalSince1970: 1_784_203_200)
let codexLimits = CodexUsageParser.parseLimits(data: codexFixtureData, now: codexNow)
guard codexLimits.count == 3 else {
    print("FATAL: codex fixture parsed into \(codexLimits.count) limits, expected 3")
    exit(1)
}
eq(codexLimits.map(\.kind), ["session", "weekly_all", "weekly_scoped"], "10. codex kinds")
eq(codexLimits.map(\.percent), [12, 40, 55], "10. codex percents 12/40/55")
eq(codexLimits.map(\.provider), ["codex", "codex", "codex"], "10. codex provider stamped")
eq(codexLimits.map(\.windowMinutes), [300, 10080, 10080], "10. codex window minutes")
eq(codexLimits.map { Labels.windowLabel(for: $0) }, ["5h", "7d", "7d"], "10. codex window labels 5h/7d/7d")
eq(codexLimits[2].scopeDisplayName, "Spark", "10. codex scoped name Spark")
eq(codexLimits[0].resetsAt?.timeIntervalSince1970, 1_784_210_400, "10. primary reset = now + 7200 s")
eq(codexLimits[1].resetsAt?.timeIntervalSince1970, 1_784_635_200, "10. secondary reset = now + 432000 s")
eq(codexLimits[2].resetsAt?.timeIntervalSince1970, 1_784_635_200, "10. scoped reset = now + 432000 s")
let codexAlias = CodexUsageParser.parseLimits(data: codexAliasData, now: codexNow)
eq(codexAlias, codexLimits, "10. alias fixture normalizes identically to canonical fixture")

// key-tree diagnostics never leak values
let treeSample = #"{"rate_limit":{"secret_value":"XYZZY"},"arr":[1,2,3]}"#
let tree = JSONKeyTree.describe(data: Data(treeSample.utf8))
check(tree.contains("secret_value") && tree.contains("arr [3]") && !tree.contains("XYZZY"),
      "10. JSON key tree prints keys and array counts, never values")

// -- 11. Provider-prefixed identifiers + legacy key tolerance ---------------------

let codexPlan = NotificationPlanner.plan(limits: codexLimits, now: codexNow, alreadyNotified: [:])
eq(codexPlan.scheduled.map(\.identifier), [
    "reset|codex|session||2026-07-16T14:00:00+00:00",
    "reset|codex|weekly_all||2026-07-21T12:00:00+00:00",
    "reset|codex|weekly_scoped|Spark|2026-07-21T12:00:00+00:00",
], "11. codex reset identifiers are provider-prefixed")
let mergedPlan = NotificationPlanner.plan(limits: limits + codexLimits, now: codexNow, alreadyNotified: [:])
eq(mergedPlan.scheduled.count, 6, "11. merged claude+codex plan covers both providers")
eq(mergedPlan.scheduled[0].title, "Лимиты Claude обновились", "11. claude entries keep claude reset title")
eq(mergedPlan.scheduled[3].title, "Лимиты Codex обновились", "11. codex entries get codex reset title")
let legacyPast = "exhausted|session||2026-07-10T00:00:00+00:00"
let legacyFuture = "exhausted|session||2026-07-20T00:00:00+00:00"
let legacyJunk = "exhausted|session||"
let legacyPrune = NotificationPlanner.plan(
    limits: limits + codexLimits,
    now: codexNow,
    alreadyNotified: [legacyPast: true, legacyFuture: true, legacyJunk: true]
)
check(legacyPrune.prunedNotified[legacyPast] == nil, "11. legacy 4-part key with passed stamp pruned")
check(legacyPrune.prunedNotified[legacyFuture] == true, "11. legacy 4-part key with future stamp kept")
check(legacyPrune.prunedNotified[legacyJunk] == nil,
      "11. legacy 4-part key without stamp dropped when no current identifier matches")

// -- 12. Multi-provider title ------------------------------------------------------

let bothGroups = [
    ProviderGroup(provider: Provider.claude, limits: limits, stale: false),
    ProviderGroup(provider: Provider.codex, limits: codexLimits, stale: false),
]
eq(TitleFormatter.plainTitle(groups: bothGroups),
   "Cl·5h●10% \u{2502} 7d●23% \u{2502} 7d●39% Fable"
   + " \u{2016} "
   + "Cx·5h●12% \u{2502} 7d●40% \u{2502} 7d●55% Spark",
   "12. two active providers → Cl·/Cx· groups joined by \u{2016}")
eq(TitleFormatter.plainTitle(groups: [ProviderGroup(provider: Provider.claude, limits: limits, stale: false)]),
   "5h●10% \u{2502} 7d●23% \u{2502} 7d●39% Fable",
   "12. single provider → plain title without prefix")
let staleCodexGroups = [
    ProviderGroup(provider: Provider.claude, limits: limits, stale: false),
    ProviderGroup(provider: Provider.codex, limits: codexLimits, stale: true),
]
check(TitleFormatter.plainTitle(groups: staleCodexGroups).contains(" \u{2016} ⚠Cx·"),
      "12. stale provider contributes ⚠ before its group prefix")
let emptyCodexGroups = [
    ProviderGroup(provider: Provider.claude, limits: limits, stale: false),
    ProviderGroup(provider: Provider.codex, limits: [], stale: false),
]
check(TitleFormatter.plainTitle(groups: emptyCodexGroups).hasSuffix(" \u{2016} Cx·…"),
      "12. active provider without data yet renders Cx·…")

// -- 13. JWT payload decode + codex auth.json parsing ------------------------------

func base64url(_ string: String) -> String {
    Data(string.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
let jwtHeader = base64url(#"{"alg":"none","typ":"JWT"}"#)
let flatJWT = jwtHeader + "." + base64url(#"{"chatgpt_account_id":"acct-42"}"#) + "."
eq(JWTDecoder.chatGPTAccountID(fromJWT: flatJWT), "acct-42", "13. top-level chatgpt_account_id claim extracted")
let nestedJWT = jwtHeader + "."
    + base64url(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"acct-77"}}"#) + ".sig"
eq(JWTDecoder.chatGPTAccountID(fromJWT: nestedJWT), "acct-77", "13. nested api.openai.com/auth claim extracted")
eq(JWTDecoder.chatGPTAccountID(fromJWT: "garbage"), nil, "13. garbage token → nil, no crash")
eq(JWTDecoder.chatGPTAccountID(fromJWT: "a.%%%.c"), nil, "13. non-base64 payload → nil, no crash")
eq(JWTDecoder.chatGPTAccountID(fromJWT: jwtHeader + "." + base64url("[1,2]") + "."), nil,
   "13. non-object payload → nil, no crash")

let oauthAuthJSON = #"{"auth_mode":"chatgpt","last_refresh":"2026-07-16T09:00:00.000Z","tokens":{"access_token":"tok","account_id":"acct-direct"}}"#
if case .oauth(let auth) = CodexAuthParser.parse(data: Data(oauthAuthJSON.utf8)) {
    check(true, "13. auth.json with tokens.access_token → oauth state")
    eq(auth.accountID, "acct-direct", "13. tokens.account_id preferred")
    eq(auth.lastRefresh.map { utc.string(from: $0) }, "2026-07-16T09:00:00", "13. last_refresh parsed")
} else {
    check(false, "13. auth.json with tokens.access_token → oauth state")
}
let jwtFallbackJSON = #"{"tokens":{"access_token":"tok","id_token":"\#(flatJWT)"}}"#
if case .oauth(let auth) = CodexAuthParser.parse(data: Data(jwtFallbackJSON.utf8)) {
    eq(auth.accountID, "acct-42", "13. account_id falls back to id_token JWT claim")
} else {
    check(false, "13. account_id falls back to id_token JWT claim")
}
eq(CodexAuthParser.parse(data: Data(#"{"OPENAI_API_KEY":"sk-x"}"#.utf8)), CodexAuthState.apiKeyOnly,
   "13. OPENAI_API_KEY-only auth.json → API-key mode")
eq(CodexAuthParser.parse(data: Data("{}".utf8)), CodexAuthState.invalid, "13. empty auth.json → invalid")
eq(CodexAuthParser.parse(data: Data("not json".utf8)), CodexAuthState.invalid, "13. non-JSON auth.json → invalid")

// -- 14. Codex RU labels & notification texts ---------------------------------------

eq(Labels.resetTitle(for: limits[0]), "Лимиты Claude обновились", "14. claude reset title")
eq(Labels.resetTitle(for: codexLimits[0]), "Лимиты Codex обновились", "14. codex reset title")
eq(Labels.menuLabel(for: codexLimits[0]), "5-часовой", "14. codex ≈300 min label")
eq(Labels.menuLabel(for: codexLimits[1]), "Недельный", "14. codex ≈10080 min label")
eq(Labels.menuLabel(for: codexLimits[2]), "Недельный · Spark", "14. codex scoped label appends name")
let codexOddWindow = LimitEntry(provider: Provider.codex, kind: "window_180m", percent: 5, windowMinutes: 180)
eq(Labels.menuLabel(for: codexOddWindow), "Окно 3 ч", "14. codex window-label fallback Окно 3 ч")
eq(Labels.windowLabel(for: codexOddWindow), "3h", "14. codex 180-min bar label 3h")
let codexDayWindow = LimitEntry(provider: Provider.codex, kind: "window_4320m", percent: 5, windowMinutes: 4320)
eq(Labels.menuLabel(for: codexDayWindow), "Окно 3 дн", "14. codex multi-day window label")
eq(Labels.windowLabel(for: codexDayWindow), "3d", "14. codex multi-day bar label")
eq(Labels.exhaustedTitle(for: codexLimits[0].withPercent(100)), "Codex: 5-часовой лимит исчерпан",
   "14. codex session exhausted title")
eq(Labels.exhaustedTitle(for: codexLimits[1].withPercent(100)), "Codex: недельный лимит исчерпан",
   "14. codex weekly exhausted title")
eq(Labels.exhaustedTitle(for: codexLimits[2].withPercent(100)), "Codex: недельный лимит Spark исчерпан",
   "14. codex scoped exhausted title")
eq(Labels.exhaustedTitle(for: codexOddWindow.withPercent(100)), "Codex: лимит Окно 3 ч исчерпан",
   "14. codex generic exhausted title")
eq(Labels.resetBody(for: codexLimits[0]), "Codex: 5-часовое окно сброшено — можно работать.",
   "14. codex session reset body")
eq(Labels.resetBody(for: codexLimits[1]), "Codex: недельный лимит сброшен.", "14. codex weekly reset body")
eq(Labels.resetBody(for: codexLimits[2]), "Codex: недельный лимит Spark сброшен.",
   "14. codex scoped reset body")
eq(Labels.resetBody(for: codexOddWindow), "Codex: лимит Окно 3 ч сброшен.", "14. codex generic reset body")

// -- 15. Cursor sample fixture → Auto/API buckets -----------------------------------

let cursorLimits = CursorUsageParser.parseLimits(data: cursorFixtureData)
guard cursorLimits.count == 2 else {
    print("FATAL: cursor fixture parsed into \(cursorLimits.count) limits, expected 2")
    exit(1)
}
eq(cursorLimits.map(\.kind), ["cursor_auto", "cursor_api"], "15. cursor kinds auto/api")
eq(cursorLimits.map(\.percent), [2, 6], "15. cursor percents 2/6 (rounded from 1.527…/6.466…)")
eq(cursorLimits.map(\.provider), ["cursor", "cursor"], "15. cursor provider stamped")
check(cursorLimits.allSatisfy { $0.resetsAt != nil }, "15. billingCycleEnd parses")
eq(utc.string(from: cursorLimits[0].resetsAt!), "2026-08-07T05:27:30",
   "15. resets_at = billingCycleEnd exact UTC instant")
eq(cursorLimits[0].resetsAt, cursorLimits[1].resetsAt, "15. both buckets reset at billingCycleEnd")
eq(cursorLimits.map { Labels.windowLabel(for: $0) }, ["Auto", "API"], "15. window labels Auto/API")
check(!cursorLimits.contains { $0.kind == "cursor_on_demand" },
      "15. onDemand.enabled == false → no on-demand entry")

// -- 16. Cursor on-demand fixture ----------------------------------------------------

let cursorOnDemand = CursorUsageParser.parseLimits(data: cursorOnDemandData)
guard cursorOnDemand.count == 3 else {
    print("FATAL: cursor on-demand fixture parsed into \(cursorOnDemand.count) limits, expected 3")
    exit(1)
}
eq(cursorOnDemand.map(\.kind), ["cursor_auto", "cursor_api", "cursor_on_demand"], "16. kinds incl. on-demand")
eq(cursorOnDemand.map(\.percent), [92, 96, 75], "16. percents 92/96/75 (on-demand = 100 * 1500 / 2000)")
eq(cursorOnDemand.map(\.level), [Level.red, .red, .orange], "16. levels red/red/orange")
eq(Labels.windowLabel(for: cursorOnDemand[2]), "OnD", "16. on-demand window label OnD")
eq(cursorOnDemand.map(\.unlimited), [false, false, false], "16. bounded buckets are not unlimited")

// null/0 on-demand limit → OnD●∞, green, excluded from notifications
var odRoot = (try? JSONSerialization.jsonObject(with: cursorOnDemandData)) as? [String: Any] ?? [:]
var odIndividual = odRoot["individualUsage"] as? [String: Any] ?? [:]
var odOnDemand = odIndividual["onDemand"] as? [String: Any] ?? [:]
odOnDemand["limit"] = NSNull()
odIndividual["onDemand"] = odOnDemand
odRoot["individualUsage"] = odIndividual
let odUnlimited = CursorUsageParser.parseLimits(root: odRoot)
eq(odUnlimited.count, 3, "16. null on-demand limit keeps 3 entries")
check(odUnlimited[2].unlimited, "16. null on-demand limit → unlimited entry")
eq(TitleFormatter.segments(for: [odUnlimited[2]]).map(\.text), ["OnD●∞"], "16. unlimited on-demand segment OnD●∞")
eq(odUnlimited[2].level, Level.green, "16. unlimited on-demand level green")
let odPlanNow = ISODateParser.parse("2026-07-16T20:00:00.000000+00:00")!
let odPlan = NotificationPlanner.plan(limits: [odUnlimited[2]], now: odPlanNow, alreadyNotified: [:])
eq(odPlan.scheduled.count + odPlan.immediate.count, 0,
   "16. unlimited on-demand excluded from notification planning")
odOnDemand["limit"] = 0
odIndividual["onDemand"] = odOnDemand
odRoot["individualUsage"] = odIndividual
check(CursorUsageParser.parseLimits(root: odRoot)[2].unlimited, "16. zero on-demand limit → unlimited too")

// -- 17. Display-message fallback -----------------------------------------------------

var strippedRoot = (try? JSONSerialization.jsonObject(with: cursorFixtureData)) as? [String: Any] ?? [:]
var strippedIndividual = strippedRoot["individualUsage"] as? [String: Any] ?? [:]
var strippedPlan = strippedIndividual["plan"] as? [String: Any] ?? [:]
strippedPlan.removeValue(forKey: "totalPercentUsed")
strippedPlan.removeValue(forKey: "apiPercentUsed")
strippedPlan.removeValue(forKey: "autoPercentUsed")
strippedIndividual["plan"] = strippedPlan
strippedRoot["individualUsage"] = strippedIndividual
let recovered = CursorUsageParser.parseLimits(root: strippedRoot)
eq(recovered.map(\.kind), ["cursor_auto", "cursor_api"], "17. fallback keeps both buckets")
eq(recovered.map(\.percent), [2, 6], "17. Auto 2 / API 6 recovered from display messages")
var noSources = strippedRoot
noSources.removeValue(forKey: "autoModelSelectedDisplayMessage")
noSources.removeValue(forKey: "namedModelSelectedDisplayMessage")
eq(CursorUsageParser.parseLimits(root: noSources).map(\.kind), [],
   "17. both percent sources missing → buckets skipped, no crash")

// -- 18. JWT sub extraction + cookie recipe -------------------------------------------

let cursorJWT = jwtHeader + "." + base64url(#"{"sub":"google-oauth2|123"}"#) + ".sig"
eq(CursorAuth.subClaim(fromJWT: cursorJWT), "google-oauth2|123", "18. sub claim extracted")
eq(CursorAuth.cookieValue(fromDBValue: cursorJWT), "google-oauth2|123::\(cursorJWT)",
   "18. cookie value <sub>::<token>")
eq(CursorAuth.cookieValue(fromDBValue: "\"\(cursorJWT)\""), "google-oauth2|123::\(cursorJWT)",
   "18. JSON-quoted DB value unquoted before decoding")
eq(CursorAuth.subClaim(fromJWT: "garbage"), nil, "18. garbage token → nil, no crash")
eq(CursorAuth.subClaim(fromJWT: "a.b"), nil, "18. 2-segment token → nil, no crash")
eq(CursorAuth.cookieValue(fromDBValue: "a.%%%.c"), nil, "18. non-base64 payload → nil, no crash")
eq(CursorAuth.subClaim(fromJWT: jwtHeader + "." + base64url(#"{"sub":""}"#) + "."), nil,
   "18. empty sub → nil")
eq(CursorAuth.unquote("  \"abc\"\n"), "abc", "18. unquote strips quotes and whitespace")
eq(CursorAuth.unquote("abc"), "abc", "18. unquote leaves raw values alone")

// -- 19. Cursor RU labels, notification texts, isUnlimited ----------------------------

eq(Labels.menuLabel(for: cursorLimits[0]), "Auto+Composer", "19. RU label Auto+Composer")
eq(Labels.menuLabel(for: cursorLimits[1]), "API-модели", "19. RU label API-модели")
eq(Labels.menuLabel(for: cursorOnDemand[2]), "On-demand", "19. RU label On-demand")
eq(Labels.resetTitle(for: cursorLimits[0]), "Лимиты Cursor обновились", "19. cursor reset title")
eq(Labels.resetBody(for: cursorLimits[0]), "Cursor: лимит Auto+Composer сброшен.", "19. auto reset body")
eq(Labels.resetBody(for: cursorLimits[1]), "Cursor: лимит API сброшен.", "19. api reset body")
eq(Labels.resetBody(for: cursorOnDemand[2]), "Cursor: лимит on-demand сброшен.", "19. on-demand reset body")
eq(Labels.exhaustedTitle(for: cursorLimits[0].withPercent(100)), "Cursor: лимит Auto+Composer исчерпан",
   "19. auto exhausted title")
eq(Labels.exhaustedTitle(for: cursorLimits[1].withPercent(100)), "Cursor: лимит API исчерпан",
   "19. api exhausted title")
eq(Labels.exhaustedTitle(for: cursorOnDemand[2].withPercent(100)), "Cursor: лимит on-demand исчерпан",
   "19. on-demand exhausted title")
let cursorPlan = NotificationPlanner.plan(limits: cursorLimits, now: odPlanNow, alreadyNotified: [:])
eq(cursorPlan.scheduled.map(\.identifier), [
    "reset|cursor|cursor_auto||2026-08-07T05:28:00+00:00",
    "reset|cursor|cursor_api||2026-08-07T05:28:00+00:00",
], "19. cursor reset identifiers: provider-prefixed, minute-rounded stamp")
let cursorRow = MenuText.infoRow(for: cursorLimits[0], now: odPlanNow)
eq(cursorRow, "Auto+Composer: 2% · сброс \(TimeFormat.absolute(cursorLimits[0].resetsAt!, now: odPlanNow))",
   "19. menu row form for billing-cycle reset")
check(!cursorRow.contains("(через"), "19. far reset has no relative part")
let farAbsolute = TimeFormat.absolute(cursorLimits[0].resetsAt!, now: odPlanNow)
check(farAbsolute.range(of: #"^\d{1,2} [а-яё]+ \d{2}:\d{2}$"#, options: .regularExpression) != nil,
      "19. beyond-a-week absolute form is 'd MMM HH:mm' (e.g. 7 авг 08:27), got '\(farAbsolute)'")

var unlimitedRoot = (try? JSONSerialization.jsonObject(with: cursorFixtureData)) as? [String: Any] ?? [:]
unlimitedRoot["isUnlimited"] = true
let unlimitedLimits = CursorUsageParser.parseLimits(root: unlimitedRoot)
eq(unlimitedLimits.count, 1, "19. isUnlimited → single entry")
let unlimitedSegments = TitleFormatter.segments(for: unlimitedLimits)
eq(unlimitedSegments.map(\.text), ["∞"], "19. isUnlimited → single ∞ segment")
eq(unlimitedSegments.map(\.level), [Level.green], "19. ∞ segment green")
eq(TitleFormatter.plainTitle(for: unlimitedLimits, stale: false), "∞", "19. unlimited plain title")
let unlimitedPlan = NotificationPlanner.plan(limits: unlimitedLimits, now: odPlanNow, alreadyNotified: [:])
eq(unlimitedPlan.scheduled.count + unlimitedPlan.immediate.count, 0,
   "19. unlimited → zero planned notifications")
eq(MenuText.infoRow(for: unlimitedLimits[0], now: odPlanNow), "Cursor: безлимит", "19. unlimited menu row")

// -- 20. Three-provider title ---------------------------------------------------------

let threeGroups = [
    ProviderGroup(provider: Provider.claude, limits: limits, stale: false),
    ProviderGroup(provider: Provider.codex, limits: codexLimits, stale: false),
    ProviderGroup(provider: Provider.cursor, limits: cursorLimits, stale: false),
]
eq(TitleFormatter.plainTitle(groups: threeGroups),
   "Cl·5h●10% \u{2502} 7d●23% \u{2502} 7d●39% Fable"
   + " \u{2016} "
   + "Cx·5h●12% \u{2502} 7d●40% \u{2502} 7d●55% Spark"
   + " \u{2016} "
   + "Cu·Auto●2% \u{2502} API●6%",
   "20. three providers → Cl· ‖ Cx· ‖ Cu· in that order")
eq(TitleFormatter.plainTitle(groups: [ProviderGroup(provider: Provider.cursor, limits: cursorLimits, stale: false)]),
   "Auto●2% \u{2502} API●6%",
   "20. cursor-only → no prefix")
eq(Provider.sortIndex(Provider.claude) < Provider.sortIndex(Provider.codex)
   && Provider.sortIndex(Provider.codex) < Provider.sortIndex(Provider.cursor), true,
   "20. display order claude < codex < cursor")

// -- 21. providers.json config parsing ------------------------------------------

let providersConfigData = loadFixture("fixtures/providers_config_sample.json")
let providersConfigInvalidData = loadFixture("fixtures/providers_config_invalid.json")

guard case .parsed(let providersConfig) = ProvidersConfigParser.parse(data: providersConfigData) else {
    print("FATAL: providers_config_sample.json did not parse")
    exit(1)
}
eq(providersConfig.providers.count, 5, "21. sample config → 5 enabled providers")
eq(providersConfig.providers.map(\.id), ["openrouter", "deepseek", "glm", "sf", "hyper"],
   "21. file order kept, kimi (enabled:false) skipped entirely")
eq(providersConfig.disabledEntries.map(\.name), ["Kimi"],
   "21. enabled:false entry surfaces for the settings window (v0.5), runtime untouched")
eq(providersConfig.errors.count, 0, "21. sample config has no entry errors")
eq(providersConfig.providers.map(\.kind),
   [ConfigProviderKind.openrouter, .deepseek, .zhipu, .siliconflow, .genericHTTP],
   "21. kinds openrouter/deepseek/zhipu/siliconflow/generic-http")

let orProvider = providersConfig.providers[0]
let dsProvider = providersConfig.providers[1]
let glmProvider = providersConfig.providers[2]
let sfProvider = providersConfig.providers[3]
let hyProvider = providersConfig.providers[4]
if case .literal = orProvider.key {
    check(true, "21. openrouter key is a literal")
} else {
    check(false, "21. openrouter key is a literal")
}
eq(orProvider.key.sourceDescription, "literal", "21. literal source description (no value)")
eq(dsProvider.key, KeySource.env("DEEPSEEK_API_KEY"), "21. deepseek env key")
eq(dsProvider.key.sourceDescription, "env DEEPSEEK_API_KEY", "21. env source description names the variable")
eq(glmProvider.key, KeySource.command("echo test-key"), "21. zhipu command key")
eq(glmProvider.key.sourceDescription, "command", "21. command source description (no command text)")
eq(glmProvider.host, ProviderHost.intl, "21. zhipu host intl")
eq(providersConfig.providers.map(\.pollSeconds), [300, 300, 600, 300, 300],
   "21. pollSeconds resolved: defaults 300, glm per-entry 600")
eq(dsProvider.thresholds, ProviderThresholds(warn: 3, critical: Decimal(string: "0.5")!),
   "21. deepseek thresholds 3/0.5")
eq(orProvider.thresholds, ProviderThresholds(warn: 5, critical: 1), "21. default thresholds 5/1")
eq(sfProvider.request?.url, "https://api.siliconflow.com/v1/user/info",
   "21. siliconflow preset expanded to the intl URL")
eq(sfProvider.extract?.balance?.path, "data.totalBalance", "21. siliconflow preset balance path")
eq(sfProvider.display?.currency, "USD", "21. siliconflow intl currency USD")
eq(hyProvider.extract?.balance?.scale, Decimal(string: "0.01")!, "21. hyperbolic generic scale 0.01")
eq(hyProvider.titlePrefix, "Hy·", "21. config bar prefix is <label>·")

guard case .parsed(let invalidConfig) = ProvidersConfigParser.parse(data: providersConfigInvalidData) else {
    print("FATAL: providers_config_invalid.json did not parse")
    exit(1)
}
eq(invalidConfig.providers.count, 0, "21. invalid config yields no providers")
eq(invalidConfig.errors.count, 3, "21. three per-entry config errors, no crash")
eq(invalidConfig.errors.map(\.name), ["TwoKeys", "Mystery", "BadId"], "21. errors keep entry names")
check(invalidConfig.errors[0].reason.contains("literal/env/command"),
      "21. two key sources → key config-error")
check(invalidConfig.errors[1].reason.contains("kind"), "21. unknown kind → config-error")
check(invalidConfig.errors[2].reason.contains("id"), "21. | in id → config-error")
eq(invalidConfig.errors[1].menuRow, "Mystery: ошибка конфига — неизвестный kind: quantum-ledger",
   "21. config-error menu row form")
check(ProviderState.configError("x").isCheckFailure, "21. config-error IS a --check failure")
check(ProviderState.keyError(KeyResolutionStrings.commandFailed).isCheckFailure,
      "21. key-resolution failure IS a --check failure")
eq(MenuText.stateRow(name: "GLM", state: .keyError(KeyResolutionStrings.commandFailed)),
   "GLM: ключ: команда не выполнилась", "21. key-command failure RU row")
eq(ProvidersConfigParser.parse(data: Data("not json".utf8)), ProvidersConfigParser.ParseResult.malformed,
   "21. malformed JSON → .malformed, never a crash")
eq(ProvidersConfigParser.parse(data: Data(#"{"version":2,"providers":[]}"#.utf8)),
   ProvidersConfigParser.ParseResult.unsupportedVersion, "21. version != 1 → unsupported")
let clampJSON = #"{"version":1,"defaults":{"pollSeconds":10},"providers":[{"id":"x1","name":"X","label":"X","kind":"deepseek","key":{"env":"E"},"pollSeconds":10},{"id":"x2","name":"Y","label":"Y","kind":"deepseek","key":{"env":"E"}}]}"#
guard case .parsed(let clampConfig) = ProvidersConfigParser.parse(data: Data(clampJSON.utf8)) else {
    print("FATAL: clamp config did not parse")
    exit(1)
}
eq(clampConfig.providers.map(\.pollSeconds), [60, 60],
   "21. pollSeconds clamped to min 60 (per-entry and defaults)")
let dupJSON = #"{"version":1,"providers":[{"id":"dup","name":"First","label":"F1","kind":"deepseek","key":{"env":"E"}},{"id":"dup","name":"Second","label":"F2","kind":"deepseek","key":{"env":"E"}}]}"#
guard case .parsed(let dupConfig) = ProvidersConfigParser.parse(data: Data(dupJSON.utf8)) else {
    print("FATAL: duplicate-id config did not parse")
    exit(1)
}
eq(dupConfig.providers.map(\.id), ["dup"], "21. duplicate id: first entry still parses")
eq(dupConfig.errors.map(\.reason), ["дублирующийся id"], "21. duplicate id: second entry → config-error")
eq(dupConfig.errors.first?.name, "Second", "21. duplicate-id error keeps the entry name")

// -- 22. Dot-path extraction + Decimal ---------------------------------------------

let pathJSON = #"{"a":[{"v":"1,234.56"},{"v":42}],"total":{"val":"-2317"},"credits":2350,"flag":true}"#
let pathRoot = (try? JSONSerialization.jsonObject(with: Data(pathJSON.utf8))) ?? [:]
eq(JSONPath.decimal(at: "a.0.v", in: pathRoot), Decimal(string: "1234.56")!,
   "22. array-index path + thousands-comma string")
eq(JSONPath.decimal(at: "a.1.v", in: pathRoot), Decimal(42), "22. JSON number via dot-path")
eq(JSONPath.decimal(at: "total.val", in: pathRoot), Decimal(-2317), "22. nested decimal string")
eq(JSONPath.decimal(at: "a.5.v", in: pathRoot), nil, "22. out-of-range array index → nil")
eq(JSONPath.decimal(at: "nope.x", in: pathRoot), nil, "22. missing path → nil")
eq(JSONPath.decimal(at: "flag", in: pathRoot), nil, "22. boolean is not a number")
eq(JSONPath.bool(at: "flag", in: pathRoot), true, "22. okFlag-style bool extraction")
eq(FieldSpec(path: "credits", scale: Decimal(string: "0.01")!).resolve(in: pathRoot),
   Decimal(string: "23.5")!, "22. hyperbolic cents scale 0.01")
let novitaRoot = (try? JSONSerialization.jsonObject(with: Data(#"{"availableBalance":"1234500"}"#.utf8))) ?? [:]
eq(FieldSpec(path: "availableBalance", scale: Decimal(string: "0.0001")!).resolve(in: novitaRoot),
   Decimal(string: "123.45")!, "22. novita 1/10000-USD scale 0.0001 stays exact in Decimal")
eq(FieldSpec(path: "total.val", scale: Decimal(string: "-0.01")!, clampMin: 0).resolve(in: pathRoot),
   Decimal(string: "23.17")!, "22. xAI inverted-sign scale −0.01")
let xaiPositiveRoot = (try? JSONSerialization.jsonObject(with: Data(#"{"total":{"val":"100"}}"#.utf8))) ?? [:]
eq(FieldSpec(path: "total.val", scale: Decimal(string: "-0.01")!, clampMin: 0).resolve(in: xaiPositiveRoot),
   Decimal(0), "22. clampMin 0 floors a negative result")

// -- 23. OpenRouter adapter ----------------------------------------------------------

let orKeyData = loadFixture("fixtures/openrouter_key_sample.json")
let orKeyNoLimitData = loadFixture("fixtures/openrouter_key_nolimit.json")
let orCreditsData = loadFixture("fixtures/openrouter_credits_sample.json")
let orGeoData = loadFixture("fixtures/openrouter_geo403.json")

if case .entries(let orKeyEntries) = OpenRouterAdapter.parseKey(data: orKeyData, httpStatus: 200, provider: orProvider),
   orKeyEntries.count == 1 {
    let entry = orKeyEntries[0]
    eq(entry.percent, 26, "23. /key percent used = round(100·(100−74.5)/100) = 26")
    eq(Labels.windowLabel(for: entry), "1m", "23. limit_reset monthly → window label 1m")
    eq(entry.provider, "openrouter", "23. entry provider = config id")
    eq(entry.resetsAt, nil, "23. /key has no reset instant → no reset notification")
    eq(entry.level, Level.green, "23. 26% → green")
    eq(TitleFormatter.segments(for: [entry]).map(\.text), ["1m●26%"], "23. /key segment 1m●26%")
    eq(MenuText.infoRow(for: entry), "OpenRouter: 26%", "23. percent menu row without reset")
} else {
    check(false, "23. /key with limit → one percent entry")
}
eq(OpenRouterAdapter.parseKey(data: orKeyNoLimitData, httpStatus: 200, provider: orProvider),
   AdapterResult.needsCredits, "23. limit null → falls back to /credits")
if case .entries(let orCreditEntries) = OpenRouterAdapter.parseCredits(data: orCreditsData, httpStatus: 200, provider: orProvider),
   orCreditEntries.count == 1 {
    eq(orCreditEntries[0].balanceText, "$74.75", "23. credits balance 100.5 − 25.75 = $74.75 (Decimal)")
    eq(orCreditEntries[0].level, Level.green, "23. balance green at default thresholds")
    eq(TitleFormatter.segments(for: orCreditEntries).map(\.text), ["●$74.75"], "23. balance segment ●$74.75")
    eq(MenuText.infoRow(for: orCreditEntries[0]), "OpenRouter: осталось $74.75", "23. balance menu row")
} else {
    check(false, "23. /credits → one balance entry")
}
eq(OpenRouterAdapter.parseKey(data: orGeoData, httpStatus: 403, provider: orProvider),
   AdapterResult.state(.blocked), "23. geo-403 body → blocked state (not bad-key)")
eq(OpenRouterAdapter.parseKey(data: Data("<html>cf challenge</html>".utf8), httpStatus: 403, provider: orProvider),
   AdapterResult.state(.fetchError("HTTP 403 (не-JSON ответ)")),
   "23. non-JSON 403 (Cloudflare challenge) → fetch-error, not bad-key")
eq(OpenRouterAdapter.parseKey(data: Data(#"{"error":{"message":"invalid key"}}"#.utf8), httpStatus: 401, provider: orProvider),
   AdapterResult.state(.badKey("ключ отклонён")), "23. JSON-bodied 401 → bad-key")
eq(OpenRouterAdapter.parseCredits(data: orGeoData, httpStatus: 403, provider: orProvider),
   AdapterResult.state(.blocked), "23. geo body on /credits → blocked too")
eq(MenuText.stateRow(name: "OpenRouter", state: .blocked), "OpenRouter недоступен (гео-блокировка)",
   "23. blocked RU row")
check(ProviderState.blocked.isCheckFailure, "23. blocked IS a --check failure")
eq(OpenRouterAdapter.parseCredits(data: orCreditsData, httpStatus: 401, provider: orProvider),
   AdapterResult.state(.info("баланс недоступен этому ключу")), "23. credits 401 → info state")
eq(MenuText.stateRow(name: "OpenRouter", state: .info("баланс недоступен этому ключу")),
   "OpenRouter: баланс недоступен этому ключу", "23. info RU row")
check(!ProviderState.info("баланс недоступен этому ключу").isCheckFailure,
      "23. credits-denied info state is NOT a --check failure")

// -- 24. DeepSeek adapter -------------------------------------------------------------

let dsSampleData = loadFixture("fixtures/deepseek_balance_sample.json")
let dsUnavailableData = loadFixture("fixtures/deepseek_balance_unavailable.json")

if case .entries(let dsEntries) = DeepSeekAdapter.parse(data: dsSampleData, httpStatus: 200, provider: dsProvider),
   dsEntries.count == 1 {
    eq(dsEntries[0].balanceText, "$23.45", "24. decimal-string balance → $23.45")
    eq(dsEntries[0].level, Level.green, "24. green at thresholds")
    eq(dsEntries[0].isExhausted, false, "24. is_available=true → not exhausted")
} else {
    check(false, "24. deepseek sample → one balance entry")
}
let dsMultiJSON = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"1.00"},{"currency":"USD","total_balance":"7.00"}]}"#
if case .entries(let dsMultiEntries) = DeepSeekAdapter.parse(data: Data(dsMultiJSON.utf8), httpStatus: 200, provider: dsProvider),
   dsMultiEntries.count == 1 {
    eq(dsMultiEntries[0].balanceText, "$7.00", "24. USD entry preferred over first (CNY)")
} else {
    check(false, "24. multi-currency deepseek → one entry")
}
if case .entries(let dsBadEntries) = DeepSeekAdapter.parse(data: dsUnavailableData, httpStatus: 200, provider: dsProvider),
   dsBadEntries.count == 1 {
    eq(dsBadEntries[0].balanceText, "¥0.00", "24. CNY formatting ¥0.00")
    eq(dsBadEntries[0].level, Level.red, "24. is_available=false → red")
    check(dsBadEntries[0].isExhausted, "24. is_available=false → exhausted")
} else {
    check(false, "24. deepseek unavailable → one balance entry")
}

// -- 25. Moonshot adapter ---------------------------------------------------------------

let msSampleData = loadFixture("fixtures/moonshot_balance_sample.json")
let msAuthErrorData = loadFixture("fixtures/moonshot_error_auth.json")

let moonCfgJSON = #"{"version":1,"providers":[{"id":"kimi","name":"Kimi","label":"Ki","kind":"moonshot","key":{"env":"K"}},{"id":"kimi-cn","name":"KimiCN","label":"Kc","kind":"moonshot","host":"cn","key":{"env":"K"}}]}"#
guard case .parsed(let moonConfig) = ProvidersConfigParser.parse(data: Data(moonCfgJSON.utf8)),
      moonConfig.providers.count == 2 else {
    print("FATAL: moonshot test config did not parse")
    exit(1)
}
if case .entries(let msEntries) = MoonshotAdapter.parse(data: msSampleData, httpStatus: 200, provider: moonConfig.providers[0]),
   msEntries.count == 1 {
    eq(msEntries[0].balanceText, "$12.35", "25. available_balance 12.34567 → $12.35 (intl = USD)")
    eq(msEntries[0].level, Level.green, "25. green at default thresholds")
} else {
    check(false, "25. moonshot sample → one balance entry")
}
if case .entries(let msCNEntries) = MoonshotAdapter.parse(data: msSampleData, httpStatus: 200, provider: moonConfig.providers[1]) {
    eq(msCNEntries.first?.balanceText, "¥12.35", "25. cn host → CNY formatting")
} else {
    check(false, "25. moonshot cn host → entry")
}
eq(MoonshotAdapter.parse(data: msAuthErrorData, httpStatus: 401, provider: moonConfig.providers[0]),
   AdapterResult.state(.badKey("ключ отклонён (нужен platform-ключ этого региона)")),
   "25. auth-error envelope → bad-key state")
eq(MenuText.stateRow(name: "Kimi", state: .badKey("ключ отклонён (нужен platform-ключ этого региона)")),
   "Kimi: ключ отклонён (нужен platform-ключ этого региона)", "25. bad-key RU row")
check(ProviderState.badKey("x").isCheckFailure, "25. bad-key IS a --check failure")

// -- 26. Zhipu adapter --------------------------------------------------------------------

let zhipuSampleData = loadFixture("fixtures/zhipu_quota_sample.json")
let zhipu1001Data = loadFixture("fixtures/zhipu_error_1001.json")
let zhipuNoPlanData = loadFixture("fixtures/zhipu_error_noplan.json")

var glmEntries: [LimitEntry] = []
if case .entries(let parsed) = ZhipuAdapter.parse(data: zhipuSampleData, httpStatus: 200, provider: glmProvider) {
    glmEntries = parsed
}
guard glmEntries.count == 3 else {
    print("FATAL: zhipu fixture parsed into \(glmEntries.count) entries, expected 3")
    exit(1)
}
eq(glmEntries.map(\.percent), [37, 12, 7], "26. percents 37/12/7 (37.4/12.0/6.6 rounded)")
eq(glmEntries.map(\.kind), ["window_300m", "window_10080m", "time_limit"], "26. kinds from unit×number")
eq(glmEntries.map(\.windowMinutes), [300, 10080, 43200], "26. window minutes 5h/1w/1mo")
eq(glmEntries.prefix(2).map { Labels.windowLabel(for: $0) }, ["5h", "7d"], "26. bar labels 5h/7d")
eq(glmEntries.map(\.menuOnly), [false, false, true], "26. TIME_LIMIT is menu-only")
eq(TitleFormatter.segments(for: glmEntries).map(\.text), ["5h●37%", "7d●12%"],
   "26. TIME_LIMIT absent from bar segments")
eq(glmEntries.map { Labels.menuLabel(for: $0) }, ["5-часовой", "Недельный", "Поиск/MCP"],
   "26. RU menu labels incl. Поиск/MCP")
check(glmEntries.allSatisfy { $0.resetsAt != nil }, "26. nextResetTime epoch-ms parsed for all rows")
eq(utc.string(from: glmEntries[0].resetsAt!), "2026-07-21T10:30:00", "26. 5h reset instant from epoch ms")
eq(utc.string(from: glmEntries[1].resetsAt!), "2026-07-26T10:30:00", "26. weekly reset instant")
let glmPlan = NotificationPlanner.plan(limits: glmEntries, now: codexNow, alreadyNotified: [:])
eq(glmPlan.scheduled.map(\.identifier), [
    "reset|glm|window_300m||2026-07-21T10:30:00+00:00",
    "reset|glm|window_10080m||2026-07-26T10:30:00+00:00",
    "reset|glm|time_limit||2026-08-12T07:30:00+00:00",
], "26. reset identifiers: config id, empty scope, minute-rounded stamps")
eq(glmPlan.scheduled[0].title, "Лимиты GLM обновились", "26. reset title uses config name")
eq(glmPlan.scheduled[0].body, "GLM: лимит 5-часовой сброшен.", "26. reset body names the window")
eq(MenuText.infoRow(for: glmEntries[2], now: codexNow),
   "Поиск/MCP: 7% · сброс \(TimeFormat.absolute(glmEntries[2].resetsAt!, now: codexNow))",
   "26. Поиск/MCP menu row form")
var zhipuAliasRoot = (try? JSONSerialization.jsonObject(with: zhipuSampleData)) as? [String: Any] ?? [:]
var zhipuAliasData0 = zhipuAliasRoot["data"] as? [String: Any] ?? [:]
let zhipuAliasLimits = (zhipuAliasData0["limits"] as? [[String: Any]] ?? []).map { item -> [String: Any] in
    var copy = item
    if let type = copy.removeValue(forKey: "type") { copy["name"] = type }
    return copy
}
zhipuAliasData0["limits"] = zhipuAliasLimits
zhipuAliasRoot["data"] = zhipuAliasData0
let zhipuAliasData = (try? JSONSerialization.data(withJSONObject: zhipuAliasRoot)) ?? Data()
if case .entries(let aliasEntries) = ZhipuAdapter.parse(data: zhipuAliasData, httpStatus: 200, provider: glmProvider) {
    eq(aliasEntries.count, 3, "26. legacy `name` accepted as `type` alias")
    eq(aliasEntries.map(\.percent), glmEntries.map(\.percent), "26. alias parse identical percents")
} else {
    check(false, "26. name-alias fixture parses")
}
eq(ZhipuAdapter.parse(data: zhipu1001Data, httpStatus: 200, provider: glmProvider),
   AdapterResult.state(.badKey("ключ отклонён")), "26. HTTP-200 code 1001 → bad-key")
eq(ZhipuAdapter.parse(data: zhipuNoPlanData, httpStatus: 200, provider: glmProvider),
   AdapterResult.state(.noPlan), "26. code 500 + \"coding plan\" → no-plan")
eq(MenuText.stateRow(name: "GLM", state: .noPlan), "GLM: нет Coding Plan (PAYG-ключ)", "26. no-plan RU row")
check(ProviderState.noPlan.isCheckFailure, "26. no-plan IS a --check failure")

// -- 27. Presets: siliconflow + novita over the generic engine -----------------------------

let sfSampleData = loadFixture("fixtures/siliconflow_user_info_sample.json")
let novitaSampleData = loadFixture("fixtures/novita_balance_sample.json")

if case .entries(let sfEntries) = GenericAdapter.parse(data: sfSampleData, httpStatus: 200, provider: sfProvider),
   sfEntries.count == 1 {
    eq(sfEntries[0].balanceText, "$23.50", "27. siliconflow totalBalance string → $23.50")
    eq(sfEntries[0].level, Level.green, "27. green at default thresholds")
} else {
    check(false, "27. siliconflow sample → one balance entry")
}
let novitaCfgJSON = #"{"version":1,"providers":[{"id":"novita","name":"Novita","label":"Nv","kind":"novita","key":{"env":"NOVITA_API_KEY"}}]}"#
guard case .parsed(let novitaConfig) = ProvidersConfigParser.parse(data: Data(novitaCfgJSON.utf8)),
      novitaConfig.providers.count == 1 else {
    print("FATAL: novita test config did not parse")
    exit(1)
}
if case .entries(let nvEntries) = GenericAdapter.parse(data: novitaSampleData, httpStatus: 200, provider: novitaConfig.providers[0]),
   nvEntries.count == 1 {
    eq(nvEntries[0].balanceText, "$123.45", "27. novita availableBalance × 0.0001 → $123.45")
} else {
    check(false, "27. novita sample → one balance entry")
}
eq(ConfigRequestBuilder.primary(for: novitaConfig.providers[0], key: "K1")?.url,
   "https://api.novita.ai/openapi/v1/billing/balance/detail", "27. novita preset URL")
eq(ConfigRequestBuilder.primary(for: glmProvider, key: "K1")?.headers["Authorization"], "K1",
   "27. zhipu raw-key Authorization header (no Bearer)")
eq(ConfigRequestBuilder.primary(for: moonConfig.providers[1], key: "K1")?.url,
   "https://api.moonshot.cn/v1/users/me/balance", "27. moonshot cn host URL")
eq(ConfigRequestBuilder.substitute("Bearer ${KEY}", key: "K1"), "Bearer K1", "27. ${KEY} substitution")
eq(ConfigRequestBuilder.redactedDisplayURL("https://api.example.com/v1/balance?api_key=sk-literal&x=1"),
   "https://api.example.com/v1/balance?…",
   "27. display URL: query (may hardcode a literal key) collapsed to ?…")
eq(ConfigRequestBuilder.redactedDisplayURL("https://api.example.com/v1/balance"),
   "https://api.example.com/v1/balance", "27. display URL without query unchanged")

// generic display-mode resolution: percentUsed → percent-mode; balance+limit → percent-mode
let pctCfgJSON = #"{"version":1,"providers":[{"id":"pct","name":"Pct","label":"Pc","kind":"generic-http","key":{"env":"E"},"request":{"url":"https://example.com/u"},"extract":{"percentUsed":{"path":"used_percent"},"okFlag":{"path":"ok"}}},{"id":"ratio","name":"Ratio","label":"Ra","kind":"generic-http","key":{"env":"E"},"request":{"url":"https://example.com/u"},"extract":{"balance":{"path":"b"},"limit":{"path":"l"}}}]}"#
guard case .parsed(let genericConfig) = ProvidersConfigParser.parse(data: Data(pctCfgJSON.utf8)),
      genericConfig.providers.count == 2 else {
    print("FATAL: generic percent test config did not parse")
    exit(1)
}
if case .entries(let pctEntries) = GenericAdapter.parse(data: Data(#"{"used_percent":37.4,"ok":true}"#.utf8),
                                                        httpStatus: 200, provider: genericConfig.providers[0]),
   pctEntries.count == 1 {
    eq(pctEntries[0].percent, 37, "27. percentUsed path → percent-mode 37")
    eq(TitleFormatter.segments(for: pctEntries).map(\.text), ["●37%"],
       "27. config percent segment has no window label (●37%)")
    eq(pctEntries[0].level, Level.green, "27. percent-mode uses standard levels")
} else {
    check(false, "27. generic percentUsed → one percent entry")
}
if case .entries(let flaggedEntries) = GenericAdapter.parse(data: Data(#"{"used_percent":10,"ok":false}"#.utf8),
                                                            httpStatus: 200, provider: genericConfig.providers[0]),
   flaggedEntries.count == 1 {
    check(flaggedEntries[0].level == .red && flaggedEntries[0].isExhausted,
          "27. okFlag=false in percent-mode → red + exhausted")
} else {
    check(false, "27. generic percentUsed with okFlag=false parses")
}
if case .entries(let ratioEntries) = GenericAdapter.parse(data: Data(#"{"b":30,"l":120}"#.utf8),
                                                          httpStatus: 200, provider: genericConfig.providers[1]),
   ratioEntries.count == 1 {
    eq(ratioEntries[0].percent, 75, "27. balance+limit → used% = round(100·(120−30)/120) = 75")
    eq(ratioEntries[0].level, Level.orange, "27. derived percent maps to standard levels")
    eq(ratioEntries[0].balanceText, nil, "27. balance+limit renders as percent, not balance")
} else {
    check(false, "27. generic balance+limit → one percent entry")
}
if case .entries(let bareBalance) = GenericAdapter.parse(data: Data(#"{"b":30}"#.utf8),
                                                         httpStatus: 200, provider: genericConfig.providers[1]),
   bareBalance.count == 1 {
    eq(bareBalance[0].balanceText, "$30.00", "27. limit missing at runtime → balance-mode fallback")
} else {
    check(false, "27. generic balance without limit → balance entry")
}
eq(GenericAdapter.parse(data: Data("{}".utf8), httpStatus: 200, provider: genericConfig.providers[1]),
   AdapterResult.state(.parseError("нет поля b")), "27. missing required path → parse-error state")
check(ProviderState.parseError("x").isCheckFailure && ProviderState.fetchError("x").isCheckFailure,
      "27. fetch/parse errors ARE --check failures")

// -- 28. Balance formatting + balance-mode levels --------------------------------------------

eq(BalanceFormat.text(Decimal(string: "23.45")!, currency: "USD"), "$23.45", "28. USD prefix")
eq(BalanceFormat.text(0, currency: "CNY"), "¥0.00", "28. CNY prefix, always 2 decimals")
eq(BalanceFormat.text(Decimal(string: "12.5")!, currency: "EUR"), "€12.50", "28. EUR prefix")
eq(BalanceFormat.text(Decimal(string: "23.45")!, currency: "XYZ"), "23.45 XYZ", "28. unknown code → suffix form")
eq(BalanceFormat.text(Decimal(string: "1234.5")!, currency: "USD"), "$1.2k", "28. ≥ 1000 → $1.2k")
eq(BalanceFormat.text(1000, currency: "USD"), "$1.0k", "28. exactly 1000 → $1.0k")
eq(BalanceFormat.text(Decimal(string: "-2.31")!, currency: "USD"), "-$2.31", "28. negative -$2.31")
eq(BalanceFormat.text(Decimal(string: "-1250")!, currency: "XYZ"), "-1.3k XYZ", "28. negative thousands, code suffix")
let defaultThresholds = ProviderThresholds()
let lvHigh = BalanceLevels.evaluate(remaining: 10, thresholds: defaultThresholds, okFlag: nil)
check(lvHigh.level == .green && !lvHigh.exhausted, "28. > warn → green")
let lvWarn = BalanceLevels.evaluate(remaining: 5, thresholds: defaultThresholds, okFlag: nil)
check(lvWarn.level == .orange && !lvWarn.exhausted, "28. = warn → orange")
let lvCrit = BalanceLevels.evaluate(remaining: 1, thresholds: defaultThresholds, okFlag: nil)
check(lvCrit.level == .red && !lvCrit.exhausted, "28. = critical → red, not exhausted")
let lvZero = BalanceLevels.evaluate(remaining: 0, thresholds: defaultThresholds, okFlag: nil)
check(lvZero.level == .red && lvZero.exhausted, "28. ≤ 0 → red + exhausted")
let lvNegative = BalanceLevels.evaluate(remaining: -3, thresholds: defaultThresholds, okFlag: nil)
check(lvNegative.level == .red && lvNegative.exhausted, "28. negative → red + exhausted")
let lvFlagged = BalanceLevels.evaluate(remaining: 100, thresholds: defaultThresholds, okFlag: false)
check(lvFlagged.level == .red && lvFlagged.exhausted, "28. okFlag=false → red + exhausted at any amount")
let lvOk = BalanceLevels.evaluate(remaining: 100, thresholds: defaultThresholds, okFlag: true)
check(lvOk.level == .green && !lvOk.exhausted, "28. okFlag=true → normal thresholds")

// -- 29. Balance-exhaustion notifications -----------------------------------------------------

if case .entries(let exhaustedBalance) = DeepSeekAdapter.parse(data: dsUnavailableData, httpStatus: 200, provider: dsProvider) {
    let planBalance = NotificationPlanner.plan(limits: exhaustedBalance, now: codexNow, alreadyNotified: [:])
    eq(planBalance.scheduled.count, 0, "29. balance entries plan no reset notifications")
    eq(planBalance.immediate.count, 1, "29. exhausted balance → one immediate notification")
    if let item = planBalance.immediate.first {
        eq(item.identifier, "exhausted|deepseek|custom||", "29. identifier exhausted|<id>|custom|| (empty stamp)")
        eq(item.title, "DeepSeek: баланс исчерпан", "29. RU exhaustion title")
        eq(item.body, "Осталось ¥0.00.", "29. RU body with the formatted remainder")
        let planAgain = NotificationPlanner.plan(limits: exhaustedBalance, now: codexNow,
                                                 alreadyNotified: [item.identifier: true])
        eq(planAgain.immediate.count, 0, "29. already-notified balance exhaustion not re-planned")
        check(planAgain.prunedNotified[item.identifier] == true,
              "29. empty-stamp identifier kept while still exhausted")
        if case .entries(let healthyBalance) = DeepSeekAdapter.parse(data: dsSampleData, httpStatus: 200, provider: dsProvider) {
            let planRecovered = NotificationPlanner.plan(limits: healthyBalance, now: codexNow,
                                                         alreadyNotified: [item.identifier: true])
            check(planRecovered.prunedNotified[item.identifier] == nil,
                  "29. empty-stamp identifier dropped after recovery")
        } else {
            check(false, "29. healthy deepseek entries for recovery step")
        }
    }
} else {
    check(false, "29. deepseek unavailable → entries for exhaustion planning")
}
eq(NotificationPlanner.normalizedResetStamp(Date(timeIntervalSince1970: 1_784_629_799.7)),
   "2026-07-21T10:30:00+00:00", "29. epoch-ms jitter rounds to the minute (zhipu stamps)")

// -- 30. Multi-provider title with config providers --------------------------------------------

var orBalanceEntry: LimitEntry?
if case .entries(let parsed) = OpenRouterAdapter.parseCredits(data: orCreditsData, httpStatus: 200, provider: orProvider) {
    orBalanceEntry = parsed.first
}
if let orBalanceEntry {
    let mixedGroups = [
        ProviderGroup(provider: Provider.claude, limits: limits, stale: false),
        ProviderGroup(provider: orProvider.id, limits: [orBalanceEntry], stale: false,
                      titlePrefix: orProvider.titlePrefix),
        ProviderGroup(provider: glmProvider.id, limits: glmEntries, stale: false,
                      titlePrefix: glmProvider.titlePrefix),
    ]
    eq(TitleFormatter.plainTitle(groups: mixedGroups),
       "Cl·5h●10% \u{2502} 7d●23% \u{2502} 7d●39% Fable"
       + " \u{2016} " + "OR·●$74.75"
       + " \u{2016} " + "GLM·5h●37% \u{2502} 7d●12%",
       "30. Cl· ‖ OR· ‖ GLM· merged title with config label prefixes")
    eq(TitleFormatter.plainTitle(groups: [
        ProviderGroup(provider: orProvider.id, limits: [orBalanceEntry], stale: false,
                      titlePrefix: orProvider.titlePrefix),
    ]), "●$74.75", "30. single active config provider → no prefix")
    check(TitleFormatter.plainTitle(groups: [
        ProviderGroup(provider: Provider.claude, limits: limits, stale: false),
        ProviderGroup(provider: glmProvider.id, limits: glmEntries, stale: true,
                      titlePrefix: glmProvider.titlePrefix),
    ]).contains(" \u{2016} ⚠GLM·"), "30. stale config provider gets ⚠ before its label prefix")
} else {
    check(false, "30. openrouter balance entry available for the title merge")
}

// -- 31. Widget snapshot builder (schema v1) ----------------------------------------------------

let snapshotNow = ISODateParser.parse("2026-07-16T20:00:00.000000+00:00")!
var dsExhaustedEntries: [LimitEntry] = []
if case .entries(let parsed) = DeepSeekAdapter.parse(data: dsUnavailableData, httpStatus: 200, provider: dsProvider) {
    dsExhaustedEntries = parsed
}
guard dsExhaustedEntries.count == 1 else {
    print("FATAL: deepseek unavailable fixture did not yield the balance entry for snapshot checks")
    exit(1)
}
let snapshotGroups = [
    ProviderGroup(provider: Provider.claude, limits: limits, stale: false),
    ProviderGroup(provider: dsProvider.id, limits: dsExhaustedEntries, stale: false,
                  titlePrefix: dsProvider.titlePrefix),
]
let snapshot = WidgetSnapshot.build(groups: snapshotGroups, now: snapshotNow)
eq(snapshot.version, 1, "31. schema version 1")
eq(snapshot.generatedAt, "2026-07-16T20:00:00+00:00", "31. generatedAt ISO-8601 UTC")
eq(snapshot.providers.map(\.id), ["claude", "deepseek"], "31. provider ids in display order")
eq(snapshot.providers.map(\.name), ["Claude", "DeepSeek"], "31. provider names (config name for custom)")
eq(snapshot.providers.map(\.label), ["Cl", "DS"], "31. bar labels without the trailing ·")
eq(snapshot.providers.map(\.stale), [false, false], "31. per-provider stale flags")
let snapshotClaudeRows = snapshot.providers[0].limits
eq(snapshotClaudeRows.map(\.kind), ["session", "weekly_all", "weekly_scoped"], "31. claude row kinds")
eq(snapshotClaudeRows[0].label, "5-часовой", "31. RU label on the row")
eq(snapshotClaudeRows[0].windowLabel, "5h", "31. window label 5h")
eq(snapshotClaudeRows[0].percent, 10, "31. percent field")
eq(snapshotClaudeRows[0].text, "10%", "31. text field for percent rows")
eq(snapshotClaudeRows[0].level, "green", "31. level string green")
eq(snapshotClaudeRows[0].resetsAt, "2026-07-16T22:59:59+00:00",
   "31. resetsAt ISO-8601 UTC, seconds precision (fraction dropped)")
eq(snapshotClaudeRows[0].exhausted, false, "31. exhausted flag false")
eq(snapshotClaudeRows[2].label, "Недельный · Fable", "31. scoped RU label carries the scope")
eq(snapshotClaudeRows[2].text, "39%", "31. scoped text is the bare percent")
let snapshotBalanceRow = snapshot.providers[1].limits[0]
eq(snapshotBalanceRow.kind, "custom", "31. balance row kind custom")
eq(snapshotBalanceRow.label, "DeepSeek", "31. balance row label = provider name")
eq(snapshotBalanceRow.windowLabel, nil, "31. balance row has no windowLabel")
eq(snapshotBalanceRow.percent, nil, "31. balance row has no percent")
eq(snapshotBalanceRow.text, "¥0.00", "31. balance row text is the formatted remainder")
eq(snapshotBalanceRow.level, "red", "31. exhausted balance level red")
eq(snapshotBalanceRow.exhausted, true, "31. exhausted flag true")
eq(snapshotBalanceRow.resetsAt, nil, "31. balance row has no resetsAt")
let snapshotWithEmpty = snapshotGroups + [ProviderGroup(provider: Provider.codex, limits: [], stale: false)]
eq(WidgetSnapshot.build(groups: snapshotWithEmpty, now: snapshotNow).providers.map(\.id),
   ["claude", "deepseek"], "31. provider without data excluded from the snapshot")
guard let snapshotData = snapshot.encode(),
      let snapshotText = String(data: snapshotData, encoding: .utf8) else {
    print("FATAL: snapshot did not encode")
    exit(1)
}
check(snapshotText.contains("\"version\""), "31. encoded snapshot is schema-v1 JSON")
check(!snapshotText.contains("sk-") && !snapshotText.contains("eyJ") && !snapshotText.contains("Bearer"),
      "31. snapshot output contains no sk-/eyJ/Bearer substrings")

// -- 32. Snapshot round-trip + staleness --------------------------------------------------------

eq(WidgetSnapshot.parse(data: snapshotData), snapshot, "32. builder output parses back (round-trip)")
check(WidgetSnapshot.parse(data: Data("not json".utf8)) == nil, "32. garbage snapshot → nil, no crash")
check(WidgetSnapshot.parse(data: Data(#"{"version":2,"generatedAt":"x","providers":[]}"#.utf8)) == nil,
      "32. unknown snapshot version rejected")
check(!snapshot.isStale(now: snapshotNow.addingTimeInterval(14 * 60)),
      "32. generatedAt 14 min old → fresh")
check(snapshot.isStale(now: snapshotNow.addingTimeInterval(15 * 60 + 1)),
      "32. generatedAt older than 15 min → stale")
check(WidgetSnapshot(version: 1, generatedAt: "garbage", providers: []).isStale(now: snapshotNow),
      "32. unparseable generatedAt → stale")

// -- 33. disabledProviders filtering ------------------------------------------------------------

let disabledSet: Set<String> = ["deepseek"]
let filteredGroups = ProviderFilter.groups(snapshotGroups, disabled: disabledSet)
eq(filteredGroups.map(\.provider), ["claude"], "33. disabled provider dropped from the groups")
check(!TitleFormatter.plainTitle(groups: filteredGroups).contains("¥")
      && !TitleFormatter.plainTitle(groups: filteredGroups).contains("DS·"),
      "33. title segments exclude the disabled provider")
let filteredMenuRows = filteredGroups.flatMap { group in
    group.limits.map { MenuText.infoRow(for: $0, now: snapshotNow) }
}
check(filteredMenuRows.count == 3 && !filteredMenuRows.contains { $0.contains("DeepSeek") },
      "33. menu model rows exclude the disabled provider")
let filteredPlan = NotificationPlanner.plan(
    limits: ProviderFilter.limits(limits + dsExhaustedEntries, disabled: disabledSet),
    now: snapshotNow,
    alreadyNotified: [:]
)
check(!filteredPlan.scheduled.contains { $0.identifier.contains("|deepseek|") },
      "33. notification desired-set excludes the disabled provider")
eq(filteredPlan.immediate.count, 0, "33. exhausted balance of a disabled provider not notified")
eq(WidgetSnapshot.build(groups: snapshotGroups, now: snapshotNow, disabled: disabledSet).providers.map(\.id),
   ["claude"], "33. snapshot excludes the disabled provider")
let pendingIdentifiers = [
    "reset|deepseek|custom||2026-07-18T08:00:00+00:00",
    "reset|claude|session||2026-07-16T23:00:00+00:00",
    "exhausted|deepseek|custom||",
]
eq(NotificationReconciler.removableResetIdentifiers(
    pending: pendingIdentifiers,
    desired: ["reset|claude|session||2026-07-16T23:00:00+00:00"],
    removalScope: ["claude"],
    knownProviders: ["claude", "deepseek"],
    disabled: disabledSet
), ["reset|deepseek|custom||2026-07-18T08:00:00+00:00"],
   "33. pending reset|<id>|* of a disabled provider removable in the reconcile plan")
eq(NotificationReconciler.removableResetIdentifiers(
    pending: pendingIdentifiers,
    desired: ["reset|claude|session||2026-07-16T23:00:00+00:00"],
    removalScope: ["claude"],
    knownProviders: ["claude", "deepseek"],
    disabled: []
), [], "33. same pending kept while the provider is enabled but unreported")

// -- 34. Settings toggle model (immediate poll on re-enable) ------------------------------------

let reEnableOutcome = ProviderSettings.setEnabled(true, provider: "codex", disabled: ["codex", "deepseek"])
eq(reEnableOutcome.disabled, Set(["deepseek"]), "34. re-enabling removes the id from disabledProviders")
eq(reEnableOutcome.immediatePoll, ["codex"],
   "34. toggle off → on yields an immediate poll of exactly that provider")
eq(reEnableOutcome.reconcileNow, false, "34. re-enabling needs no immediate reconcile")
let disableOutcome = ProviderSettings.setEnabled(false, provider: "cursor", disabled: ["deepseek"])
eq(disableOutcome.disabled, Set(["deepseek", "cursor"]), "34. disabling adds the id")
eq(disableOutcome.immediatePoll, [], "34. disabling polls nothing")
eq(disableOutcome.reconcileNow, true, "34. disabling requests an immediate notification reconcile")
let noopOutcome = ProviderSettings.setEnabled(true, provider: "claude", disabled: ["deepseek"])
eq(noopOutcome.immediatePoll, [], "34. enabling an already-enabled provider polls nothing")
eq(noopOutcome.disabled, Set(["deepseek"]), "34. no-op toggle keeps the set")
eq(ProviderSettings.disabledDefaultsKey, "disabledProviders", "34. UserDefaults key per SPEC")

// -- 35. --status rendering ----------------------------------------------------------------------

let statusFixtureData = loadFixture("fixtures/widget_snapshot_sample.json")
guard let statusSnapshot = WidgetSnapshot.parse(data: statusFixtureData) else {
    print("FATAL: widget_snapshot_sample.json did not parse")
    exit(1)
}
let statusFreshNow = ISODateParser.parse("2026-07-17T08:05:00+00:00")!
let statusStaleNow = ISODateParser.parse("2026-07-17T08:30:00+00:00")!
let staleTable = StatusCommand.render(snapshot: statusSnapshot, now: statusStaleNow)
check(staleTable.hasPrefix("Обновлено: ") && staleTable.contains("(устарело)"),
      "35. old generatedAt → header suffix (устарело)")
check(!StatusCommand.render(snapshot: statusSnapshot, now: statusFreshNow).contains("(устарело)"),
      "35. fresh generatedAt → no (устарело)")
check(staleTable.contains("5-часовой") && staleTable.contains("Недельный (все модели)"),
      "35. table contains RU labels")
check(staleTable.contains("зелёный") && staleTable.contains("жёлтый") && staleTable.contains("красный"),
      "35. table contains RU level words")
check(staleTable.contains("9%") && staleTable.contains("¥0.00"),
      "35. rows carry percent and balance values")
check(staleTable.contains("исчерпан"), "35. exhausted row marked исчерпан")
check(staleTable.contains("⚠ DeepSeek [DS]"), "35. stale provider header gets ⚠")
check(staleTable.contains("Claude [Cl]") && !staleTable.contains("⚠ Claude"),
      "35. fresh provider header has no ⚠")
let statusHumanOut = StatusCommand.output(fileData: statusFixtureData, json: false, now: statusStaleNow)
eq(statusHumanOut.exitCode, 0, "35. --status exit 0 with a snapshot present")
eq(String(data: statusHumanOut.stdout, encoding: .utf8), staleTable + "\n",
   "35. --status prints exactly the rendered table")
let statusJSONOut = StatusCommand.output(fileData: statusFixtureData, json: true, now: statusStaleNow)
eq(statusJSONOut.exitCode, 0, "35. --status --json exit 0")
check(statusJSONOut.stdout == statusFixtureData, "35. --status --json byte-identical to the file")
let statusMissingOut = StatusCommand.output(fileData: nil, json: false, now: statusStaleNow)
eq(statusMissingOut.exitCode, 2, "35. missing snapshot → exit 2")
eq(String(data: statusMissingOut.stdout, encoding: .utf8),
   "снапшот недоступен — запусти Limit Monitor или limit-monitor --check\n",
   "35. missing snapshot → RU hint line")
eq(StatusCommand.output(fileData: Data("junk".utf8), json: true, now: statusStaleNow).exitCode, 2,
   "35. unreadable snapshot → exit 2 in --json mode too")

extension LimitEntry {
    func withPercent(_ p: Int) -> LimitEntry {
        var copy = self
        copy.percent = p
        return copy
    }

    func withResetsAt(_ raw: String) -> LimitEntry {
        var copy = self
        copy.resetsAtRaw = raw
        copy.resetsAt = ISODateParser.parse(raw)
        return copy
    }
}

print("")
print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
