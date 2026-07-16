import Foundation
import ClaudeLimitsCore

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

// -- Fixture (CWD must be the repo root) ------------------------------------

let fixturePath = "fixtures/usage_sample.json"
guard FileManager.default.fileExists(atPath: fixturePath),
      let fixtureData = FileManager.default.contents(atPath: fixturePath) else {
    print("FATAL: \(fixturePath) not found/unreadable — run `swift run checks` from the repo root")
    exit(2)
}

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

let segments = TitleFormatter.segments(for: limits)
eq(segments.map(\.text), ["●10% 5h", "●23% 7d", "●39% Fable"], "4. title segments")
eq(segments.map(\.level), [Level.green, .green, .green], "4. per-segment levels green/green/green")
eq(TitleFormatter.plainTitle(for: limits, stale: false), "●10% 5h·●23% 7d·●39% Fable",
   "4. plain title joined by ·")
var bumped = limits
bumped[2].percent = 95
let bumpedSegments = TitleFormatter.segments(for: bumped)
eq(bumpedSegments[2].level, Level.red, "4. limit bumped to 95 → its segment red")
eq(bumpedSegments[2].text, "●95% Fable", "4. bumped segment text")
eq(bumpedSegments[0].level, Level.green, "4. other segments unchanged (first)")
eq(bumpedSegments[1].level, Level.green, "4. other segments unchanged (second)")
check(TitleFormatter.plainTitle(for: limits, stale: true).hasPrefix("⚠●10% 5h"),
      "4. stale/expired state adds ⚠ before first segment")

// -- 5. RU labels ---------------------------------------------------------------

eq(Labels.menuLabel(for: limits[0]), "5-часовой", "5. session label")
eq(Labels.menuLabel(for: limits[1]), "Недельный (все модели)", "5. weekly_all label")
eq(Labels.menuLabel(for: limits[2]), "Недельный · Fable", "5. weekly_scoped label")
let unknownScoped = LimitEntry(kind: "mega_promo", percent: 5, scopeDisplayName: "Zap")
let unknownBare = LimitEntry(kind: "mega_promo", percent: 5)
eq(Labels.menuLabel(for: unknownScoped), "Mega promo · Zap", "5. unknown kind + scope label")
eq(Labels.menuLabel(for: unknownBare), "Mega promo", "5. unknown kind bare label (humanized)")
eq(Labels.shortLabel(for: limits[0]), "5h", "5. short label session")
eq(Labels.shortLabel(for: limits[1]), "7d", "5. short label weekly_all")
eq(Labels.shortLabel(for: limits[2]), "Fable", "5. short label scoped = display_name")
eq(Labels.shortLabel(for: unknownScoped), "Zap", "5. short label unknown w/ scope")
eq(Labels.shortLabel(for: unknownBare), "mega_promo", "5. short label unknown = raw kind")

// -- 6. Reset notification planning --------------------------------------------

let now = ISODateParser.parse("2026-07-16T20:00:00.000000+00:00")!
let plan = NotificationPlanner.plan(limits: limits, now: now, alreadyNotified: [:])
eq(plan.scheduled.count, 3, "6. plans 3 scheduled reset notifications")
eq(plan.scheduled.map(\.identifier), [
    "reset|session||2026-07-16T23:00:00+00:00",
    "reset|weekly_all||2026-07-18T08:00:00+00:00",
    "reset|weekly_scoped|Fable|2026-07-18T08:00:00+00:00",
], "6. reset identifiers use minute-rounded canonical stamp")
let jitterA = limits[0].withResetsAt("2026-07-16T22:59:59.939319+00:00")
let jitterB = limits[0].withResetsAt("2026-07-16T23:00:00.108296+00:00")
eq(NotificationPlanner.resetIdentifier(for: jitterA),
   NotificationPlanner.resetIdentifier(for: jitterB),
   "6. jittered resets_at across minute boundary → one reset identifier")
eq(NotificationPlanner.resetIdentifier(for: jitterA), "reset|session||2026-07-16T23:00:00+00:00",
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
    eq(item.identifier, "exhausted|session||2026-07-16T23:00:00+00:00", "9. exhausted identifier")
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
eq(planNull.immediate.first?.identifier, "exhausted|session||", "9. null resets_at identifier")
let nullId = "exhausted|session||"
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
