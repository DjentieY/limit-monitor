# Claude Limits — macOS menu bar app (spec)

Always-visible macOS menu bar app showing Claude subscription rate-limit usage —
5-hour session window, weekly window, and any scoped/promotional limits (e.g. the
current "Fable" weekly promo) — with local macOS notifications when a limit window
resets. Single user, local-only, no telemetry, no third-party dependencies.

## Data source (verified live 2026-07-16 on this machine)

- **Credentials**: macOS Keychain item, read via
  `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`
  → JSON `{"claudeAiOauth": {"accessToken": "...", "refreshToken": "...", "expiresAt": <ms epoch>, ...}}`.
  Reading via `/usr/bin/security` works silently (verified — no GUI prompt, the item
  was created by the same tool). Fallback if the keychain read fails:
  `~/.claude/.credentials.json` (same shape, often stale — check `expiresAt`).
- **Endpoint**: `GET https://api.anthropic.com/api/oauth/usage` with headers
  `Authorization: Bearer <accessToken>` and `anthropic-beta: oauth-2025-04-20`.
  Timeout 15 s. Returns HTTP 200 + JSON — real captured response in
  `fixtures/usage_sample.json` (source of truth for parsing).
- **Primary data**: the `limits` array. Each element:
  - `kind`: `"session"` | `"weekly_all"` | `"weekly_scoped"` | unknown future kinds
  - `group`: `"session"` | `"weekly"` | ...
  - `percent`: integer utilization 0–100+
  - `severity`: `"normal"` | other values (treat non-"normal" as warning)
  - `resets_at`: ISO 8601 **with 6-digit fractional seconds** and `+00:00` offset,
    e.g. `2026-07-16T22:59:59.947432+00:00`; may be `null`
  - `scope`: `null` | `{"model": {"id": ..., "display_name": "Fable"}, "surface": ...}`
  - `is_active`: bool
  Unknown `kind`s MUST render generically (humanized kind + scope display name) —
  this is how future promo limits appear without code changes.
  If `limits` is missing or empty, synthesize entries from legacy top-level
  `five_hour` / `seven_day` (`{utilization, resets_at}`).
- **Token expiry**: if `expiresAt` has passed or the API returns 401 → "token
  expired" state: keep showing last known data + warning; the fix is simply using
  Claude Code (it refreshes the keychain). Do NOT implement OAuth refresh here
  (refresh-token rotation would race with Claude Code). Never log or print tokens.

## UI (menu bar, AppKit `NSStatusItem`, UI language: Russian)

- **Levels** (Core enum, shared by status item, menu and notifications):
  green `percent < 50`, yellow `50–74`, orange `75–89`, red `>= 90` (100 % is
  always red). A non-`"normal"` `severity` bumps the level to at least orange.
- Status item: `NSAttributedString` title on the status button — one segment per
  limit in API order, joined by ` || `. Each segment is
  `<windowLabel>●<percent>%[ <scopeName>]` where the `●` is colored by THAT
  limit's level (`NSColor.systemGreen/…Yellow/…Orange/…Red`) and the rest of the
  segment keeps the default label color. Window labels: `session` → `5h`,
  `weekly_all`/`weekly_scoped` → `7d`, unknown kind → by `group` (`session` →
  `5h`, `weekly` → `7d`) else the raw kind. Scoped limits append the scope
  `display_name` after the percent. Example:
  `5h●10% || 7d●23% || 7d●39% Fable`. If data is stale (last successful fetch
  > 10 min ago) or token expired, prepend `⚠` before the first segment.
- Menu (rebuilt after each poll; disabled info rows on top; each info row is an
  `attributedTitle` prefixed with `● ` colored by that limit's level):
  - `● 5-часовой: 10% · сброс в 01:59 (через 2 ч 14 мин)`
  - `● Недельный (все модели): 23% · сброс пт 10:59`
  - `● Недельный · Fable: 39% · сброс пт 10:59`
  - a limit at `percent >= 100` reads `исчерпан · возобновится …` instead of the
    percent+`сброс` form: `● 5-часовой: исчерпан · возобновится в 22:59 (через 2 ч)`
  - separator
  - `Обновлено: 14:32` — or the error/staleness line:
    `Токен истёк — открой Claude Code` / `Нет сети · данные от 14:32`
  - `Обновить сейчас` (⌘R)
  - `Уведомления о лимитах` — checkbox, default ON, persisted in
    `UserDefaults` key `notifyOnReset`; governs BOTH reset and exhaustion
    notifications
  - `Запускать при входе` — checkbox backed by `SMAppService.mainApp`
    (register/unregister; reflect `.status`)
  - separator, `Выход` (⌘Q)
- Kind → label mapping: `session` → `5-часовой`, `weekly_all` → `Недельный (все
  модели)`, `weekly_scoped` → `Недельный · <display_name>`, unknown →
  `<humanized kind> [· <display_name>]`.
- Times: absolute local time via `DateFormatter` (locale `ru_RU`; same-day → HH:mm,
  else weekday + HH:mm) plus relative `(через …)` via `RelativeDateTimeFormatter`.

## Notifications (`UserNotifications`)

- **Identifier timestamp normalization**: the live API recomputes `resets_at` on
  every request with sub-second jitter that straddles minute boundaries (observed:
  `22:59:59.9` vs `23:00:00.1` for the same window), so identifiers must NOT embed
  the raw string. `<stamp>` below = parsed `resets_at` rounded to the **nearest
  minute**, re-serialized as `yyyy-MM-dd'T'HH:mm:ss+00:00` (UTC), e.g.
  `2026-07-16T23:00:00+00:00`; empty string when `resets_at` is null/unparseable.
  Raw `resets_at` is kept for display only.
- On each successful poll, build the desired set of **pre-scheduled local
  notifications**: for every limit with `resets_at` in the future and
  `percent >= 1`, schedule a `UNNotificationRequest` at `resets_at + 5 s`
  (`UNCalendarDateTrigger` from UTC date components with `timeZone` pinned, so a
  later wall-clock timezone change cannot move the fire instant; `repeats: false`)
  with identifier `reset|<kind>|<scopeName>|<stamp>`. Title: `Лимиты Claude обновились`;
  body: `5-часовое окно сброшено — можно работать.` / `Недельный лимит сброшен.` /
  `Недельный лимит Fable сброшен.` (generic for unknown kinds). Default sound.
- Reconcile: fetch pending requests, remove those with `reset|` prefix that are no
  longer in the desired set, add missing ones. Pre-scheduling means the alert fires
  on time even if the Mac is offline at reset moment; identifiers dedupe repeats.
- If `notifyOnReset` is off → remove all pending `reset|*` requests, schedule none.
- **Exhaustion notifications**: when a poll shows a limit with `percent >= 100`,
  deliver an immediate notification (`trigger: nil`), identifier
  `exhausted|<kind>|<scopeName>|<stamp>` (same normalized stamp — dedup must
  survive the per-request `resets_at` jitter). The title NAMES the limit:
  `Claude: 5-часовой лимит исчерпан` / `Claude: недельный лимит исчерпан` /
  `Claude: недельный лимит Fable исчерпан` (unknown kinds:
  `Claude: лимит <label> исчерпан`). Body: `Возобновится через 2 ч 14 мин
  (в 22:59).`; if `resets_at` is null → `Время возобновления неизвестно.`
  Dedup across polls AND app restarts: persist notified
  identifiers in `UserDefaults` key `exhaustedNotified` (`[String: Bool]`); notify
  only if the identifier is absent; prune entries whose stamp has passed, and drop
  entries with an empty/unparseable stamp (null `resets_at`) as soon as no
  currently-exhausted limit produces the same identifier — otherwise a future
  null-`resets_at` exhaustion of that limit would be suppressed forever.
  Governed by the same `notifyOnReset` toggle.
- Request authorization (`.alert, .sound`) once at startup.
- **Gotcha**: `UNUserNotificationCenter.current()` **crashes** in a process that is
  not part of an `.app` bundle. Guard all UserNotifications *and* `SMAppService`
  code behind a `isRunningInBundle` check (`Bundle.main.bundlePath.hasSuffix(".app")`).
  When run unbundled (dev mode), skip notifications with a stderr warning.

## Behavior

- Poll every 60 s (`Timer`, tolerance 10 s, `.common` run-loop mode) + immediately
  at launch + on wake from sleep (`NSWorkspace.shared.notificationCenter`,
  `NSWorkspace.didWakeNotification`).
- Re-read credentials from the keychain on every poll (Claude Code rotates them).
- Network/keychain errors: keep last data, mark stale; never crash on malformed
  JSON — parse defensively, skip broken entries.
- `--check` CLI mode (runs before any AppKit/NSApplication setup): read creds,
  fetch usage, print a plain-text table of parsed limits + the title string +
  planned notification schedule, exit 0 (1 on failure). No tokens in output.
  This is the e2e smoke test.
- App is menu-bar-only: `LSUIElement = true`, no Dock icon, no windows.

## Architecture & project layout

Pure logic separated from AppKit so it is testable:

- `Package.swift` — swift-tools-version **5.10** (avoids Swift 6 strict-concurrency
  build noise on the 6.3 toolchain), `platforms: [.macOS(.v13)]`, three targets:
  - `ClaudeLimitsCore` (library): models, JSON parsing (`limits` + legacy fallback),
    ISO-8601 date parsing, level computation (green/yellow/orange/red), label/title
    formatting (title as plain segments + per-segment level; AppKit layer does the
    attributed-string coloring), notification planning — scheduled resets AND
    immediate exhaustions with dedup
    (`plan(limits:now:alreadyNotified:) -> (scheduled, immediate, prunedNotified)`),
    credential JSON parsing. No AppKit/UserNotifications imports.
  - `claude-limits` (executable): AppKit status item app + `--check` mode; depends
    on Core. Keychain read via `Process` (`/usr/bin/security`), fetch via
    `URLSession`.
  - `checks` (executable): assertion-based test runner over
    `fixtures/usage_sample.json` (path resolved relative to CWD = repo root; fail
    with a clear message if missing). No XCTest (Xcode is not installed — CLT only).
- `scripts/make_app.sh` — `swift build -c release`, assemble
  `build/Claude Limits.app` (Contents/MacOS/claude-limits + Info.plist:
  `CFBundleIdentifier=com.vladlaiho.claude-limits`, `CFBundleName=Claude Limits`,
  `CFBundleShortVersionString=1.0.0`, `LSUIElement=true`,
  `LSMinimumSystemVersion=13.0`), `codesign --force -s -` (ad-hoc). With
  `--install`: `ditto` to `~/Applications/Claude Limits.app` (kill running instance
  first, do not relaunch).
- `README.md` — Russian, short: what it is, install (`./scripts/make_app.sh
  --install`, then `open ~/Applications/Claude\ Limits.app`), how notifications
  work, token-expired note, uninstall.

## Date parsing (known trap)

`resets_at` has **6-digit** fractional seconds; `ISO8601DateFormatter` with
`.withFractionalSeconds` is unreliable for that. Use `DateFormatter` with
`en_US_POSIX` locale, UTC-agnostic format `yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX`, with
fallbacks (`.SSSXXXXX`, no fraction, plain `ISO8601DateFormatter`). Must round-trip
every `resets_at` in the fixture (checks assert non-nil and correct ordering).

## `checks` must cover (assertion style, exit non-zero on failure)

1. Fixture parses into exactly 3 limits with kinds session/weekly_all/weekly_scoped,
   percents 10/23/39, scope display_name "Fable" on the third.
2. All fixture `resets_at` parse to non-nil dates; session reset < weekly resets.
3. Legacy fallback: fixture with `limits` removed synthesizes 2 entries from
   `five_hour`/`seven_day`.
4. Title formatting: fixture → segments `5h●10%`, `7d●23%`, `7d●39% Fable`
   joined by ` || `, per-segment levels green/green/green; a limit bumped to 95
   makes its segment's level red (others unchanged); stale/expired state adds
   `⚠` before the first segment; unknown kind with `group: weekly` gets window
   label `7d`.
5. Labels: RU mapping incl. unknown kind fallback.
6. Notification planning: given fixture limits and a `now` before resets, plans 3
   scheduled reset notifications with correct (minute-rounded, canonical-stamp)
   identifiers; two jittered `resets_at` straddling a minute boundary map to ONE
   identifier; `percent = 0` limit is skipped; past `resets_at` skipped.
7. Credentials JSON parsing incl. `expiresAt` validity check.
8. Level mapping: 0/49 → green, 50/74 → yellow, 75/89 → orange, 90/100/120 → red;
   non-"normal" severity at 10 % → orange.
9. Exhaustion planning: a limit at 100 % yields exactly one immediate notification
   with identifier `exhausted|…`, a title naming the limit (e.g.
   `Claude: 5-часовой лимит исчерпан`) and RU body containing the reset time; the
   same identifier in `alreadyNotified` → nothing planned; identifiers whose
   stamp passed are returned as prunable; an empty-stamp (null `resets_at`)
   identifier is kept while its limit is still exhausted and dropped once it is not.

## Style

- Swift, no third-party dependencies; frameworks: Foundation, AppKit,
  UserNotifications, ServiceManagement.
- No force unwraps outside `checks`; no `print` of secrets; concise code, no
  comment noise. Menu strings exactly as specified (Russian).
