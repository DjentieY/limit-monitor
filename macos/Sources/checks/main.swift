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

eq(Labels.resetTitle(forProvider: Provider.claude), "Лимиты Claude обновились", "14. claude reset title")
eq(Labels.resetTitle(forProvider: Provider.codex), "Лимиты Codex обновились", "14. codex reset title")
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
eq(Labels.resetTitle(forProvider: Provider.cursor), "Лимиты Cursor обновились", "19. cursor reset title")
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
