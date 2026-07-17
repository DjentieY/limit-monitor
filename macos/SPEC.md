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

---

# v0.2 — Multi-provider + Codex adapter + rename (2026-07-16)

This section SUPERSEDES specific v0.1 points where stated. Everything not
mentioned stays as specified above.

## Rename (supersedes bundle/target naming above)

- App: `Limit Monitor.app`, `CFBundleName=Limit Monitor`,
  `CFBundleIdentifier=com.vladlaiho.limit-monitor`, executable target and binary
  `limit-monitor` (was `claude-limits`), Core module `LimitMonitorCore` (was
  `ClaudeLimitsCore`). `checks` target keeps its name.
- `make_app.sh --install` removes BOTH `~/Applications/Claude Limits.app` (old)
  and `~/Applications/Limit Monitor.app` before `ditto`, and kills running
  instances of both binary names. Loss of the old UserDefaults domain is
  accepted (worst case: one duplicate exhaustion notification after upgrade).
- Update repo-root `README.md`, `install.sh`, `llms-install.md`: new app/binary
  paths (`"$HOME/Applications/Limit Monitor.app/Contents/MacOS/limit-monitor"
  --check`), uninstall covers both app names, features mention Codex.

## Multi-provider architecture

- Providers: `claude` (existing behavior) and `codex`. A provider is ACTIVE when
  its credential artifact exists: claude — Keychain item or
  `~/.claude/.credentials.json`; codex — `$CODEX_HOME/auth.json` (default
  `~/.codex/auth.json`) containing `tokens.access_token`. An `auth.json` with
  only `OPENAI_API_KEY` = API-key mode → provider INACTIVE with reason, shown as
  a disabled menu row `Codex: API-key режим — план-лимитов нет`.
- `LimitEntry` gains `provider: String` (`"claude"`/`"codex"`).
- Notification identifiers gain a provider segment (supersedes v0.1 format):
  `reset|<provider>|<kind>|<scopeName>|<stamp>` and
  `exhausted|<provider>|<kind>|<scopeName>|<stamp>`. Legacy 4-part keys persisted
  in `exhaustedNotified` must not crash pruning: parseable-stamp keys prune when
  passed; the rest are dropped when no current identifier matches.
- Polling: independent per provider — claude every 60 s (unchanged), codex every
  180 s (gentler: WAF sensitivity). One provider failing/stale must not mark the
  other stale. First fetch of each at launch and on wake.
- Display order: claude limits first, then codex.
- **Segment separator** (supersedes v0.1 `·` and the ` || ` interim): segments
  within a provider are joined by ` │ ` (U+2502), `TitleFormatter.separator`.
  Provider groups are joined by ` ‖ ` (U+2016), `TitleFormatter.providerSeparator`.
- Title (status item): with ONE active provider — single-provider format, no
  prefix, e.g. `5h●45% │ 7d●30% │ 7d●52% Fable`. With >1 active: provider groups
  joined by ` ‖ `, each group prefixed `Cl·` / `Cx·` / `Cu·`, e.g.
  `Cl·5h●45% │ 7d●30% ‖ Cx·5h●12% │ 7d●40%`. A provider in stale/expired state
  contributes `⚠` before its group prefix (single provider: before first
  segment, as in v0.1).
- Menu with >1 active provider: disabled bold header rows `Claude` / `Codex`
  above each provider's limit rows; single provider — no header. Per-provider
  error lines: `Токен Codex истёк — запусти codex` / existing claude line.
- Notification texts get provider-aware wording: claude strings stay EXACTLY as
  in v0.1; codex: reset title `Лимиты Codex обновились`, bodies
  `Codex: 5-часовое окно сброшено — можно работать.` / `Codex: недельный лимит
  сброшен.` / generic `Codex: лимит <label> сброшен.`; exhausted titles
  `Codex: 5-часовой лимит исчерпан` / `Codex: недельный лимит исчерпан` /
  `Codex: лимит <label> исчерпан`, same body forms as claude.

## Codex provider (data source)

No live fixture was capturable on this machine (no `auth.json` here) — schema is
community-documented (CodexBar, ccusage, codex-cli-usage) and field names vary
across versions, so the parser MUST be alias-tolerant and `--check` MUST provide
diagnosis output good enough to debug remotely.

- **Creds**: `$CODEX_HOME/auth.json` (default `~/.codex/auth.json`):
  `{auth_mode?, last_refresh?, tokens: {access_token, refresh_token?, id_token?,
  account_id?}, OPENAI_API_KEY?}`. NEVER write the file, NEVER refresh tokens
  (rotation invalidates codex's own refresh token), never log/print tokens.
  `account_id` fallback: base64url-decode the JWT payload of `id_token` (then
  `access_token`) and read claim `chatgpt_account_id` (also check
  `https://api.openai.com/auth` nested claims); tolerate absence — then send no
  account header.
- **Request**: `GET https://chatgpt.com/backend-api/wham/usage`; on HTTP 404 (or
  400) retry once with `/backend-api/codex/usage`. Headers:
  `Authorization: Bearer <access_token>`, `ChatGPT-Account-Id: <account_id>` (if
  known), `Accept: application/json`, `Origin: https://chatgpt.com`,
  `Referer: https://chatgpt.com/`, browser-like Safari `User-Agent` (WAF trips on
  bot-looking UAs). Timeout 15 s.
- **Parse (alias-tolerant at every level)**: windows may sit under `rate_limit`
  / `rate_limits` or top-level. `primary_window`/`primary` → session-like;
  `secondary_window`/`secondary` → weekly-like; `additional_rate_limits[]`
  (each with `name`/`label`/`display_name` + window fields) → scoped entries.
  Field aliases:
  - percent used: `used_percent` | `percent_used` | `100 - percent_left` |
    `100 - percent_remaining` (round to Int)
  - reset time: `resets_at` (ISO8601 or epoch seconds) | `reset_at` |
    `reset_time_ms` (ms epoch) | now + `resets_in_seconds` |
    now + `reset_after_seconds`
  - window size: `window_minutes` | `limit_window_seconds / 60`
  Kind mapping: primary → `session` when window ≈ ≤6 h (or missing), secondary →
  `weekly_all` when window ≈ 7 d (or missing); otherwise generic kind
  `window_<minutes>m`. Window label: `h = round(wm/60)`, `h < 48` → `"\(h)h"`,
  else `"\(round(wm/1440))d"`; defaults `5h` / `7d` when wm missing. RU menu
  labels: ≈300 min → `5-часовой`, ≈10080 min → `Недельный`, else `Окно N ч` /
  `Окно N дн`; scoped appends ` · <name>`.
- **Errors**: HTTP 401 → codex token-expired state (menu:
  `Токен Codex истёк — запусти codex`; codex refreshes it on next use). Parse
  failure → provider error state; `--check` prints the response's JSON key tree
  (keys and array counts ONLY, depth ≤ 3, NO values — values could embed ids) to
  make remote debugging possible.
- **Fixtures**: `fixtures/codex_usage_sample.json` (canonical:
  `rate_limit.primary_window.used_percent/resets_in_seconds/window_minutes` etc.
  + one `additional_rate_limits` entry) and `fixtures/codex_usage_alias.json`
  (variant: top-level `primary`/`secondary`, `percent_left`, `reset_time_ms`,
  `limit_window_seconds`). Both must normalize to the same shape. The fixtures
  are authored to normalize IDENTICALLY (including reset instants) for a fixed
  `now = 2026-07-16T12:00:00Z` (epoch 1784203200): percents 12/40/55, window
  labels `5h`/`7d`/`7d`, scoped name `Spark`; the alias `reset_time_ms` values
  equal `(1784203200 + resets_in_seconds) * 1000` of the canonical fixture.
  `checks` must use exactly this `now`.

## `--check` (v0.2, supersedes)

- Section per ACTIVE provider: creds source, token validity (claude: expiresAt;
  codex: last_refresh age if present), fetch, parsed table, per-provider title
  group, planned notifications. Providers without creds → single line
  `codex: неактивен (нет ~/.codex/auth.json)`.
- Exit 0 iff EVERY active provider fetched and parsed successfully (an inactive
  provider is not a failure). This is the contract agents/friends verify.

## `checks` additions (fixture-driven)

10. Codex canonical fixture → 3 entries (session/weekly_all/scoped) with correct
    percents, reset dates, window labels `5h`/`7d`, scoped name; alias fixture →
    identical normalized output (modulo reset dates derived from a fixed `now`).
11. Provider-prefixed identifiers (`reset|codex|session||<stamp>`); legacy
    4-part `exhaustedNotified` keys survive pruning without crash and get
    dropped/pruned per the rules above.
12. Multi-provider title: claude fixture (3) + codex fixture (3) →
    `Cl·…` ‖ `Cx·…` grouping; single provider → no prefix (regression on the
    existing plain-title checks).
13. JWT payload decode: synthetic unsigned JWT with `chatgpt_account_id` claim →
    extracted; garbage token → nil, no crash.
14. Codex RU labels & notification texts (`Лимиты Codex обновились`,
    `Codex: 5-часовой лимит исчерпан`, window-label fallback `Окно 3 ч`).

---

# v0.3 — Cursor provider (2026-07-16)

Third provider `cursor` on top of the v0.2 multi-provider architecture. Prefix
`Cu·`; display order: claude, codex, cursor. Verified LIVE on this machine
2026-07-16: real response captured in `fixtures/cursor_usage_summary_sample.json`
(PII scrubbed), synthetic edge-case in `fixtures/cursor_usage_summary_ondemand.json`.
The fixtures are the parsing source of truth.

## Creds (SQLite, strictly read-only)

- Access token lives in
  `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` — a
  SQLite DB that is huge (5.6 GB here) and actively written by Cursor. NEVER
  copy it, never open read-write. Read via `Process` (same pattern as
  `/usr/bin/security`):
  `/usr/bin/sqlite3 -readonly "<db>" "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken';"`
  — the indexed point lookup is fast even at that size; timeout 5 s. The value
  may be a raw JWT or a JSON-quoted string — strip surrounding double quotes.
- Provider ACTIVE iff the DB exists and the query returns a non-empty token.
  Otherwise INACTIVE: menu/`--check` line `cursor: неактивен (нет Cursor)`.
- **Cookie recipe (verified live)**: base64url-decode the JWT payload, read
  claim `sub` (e.g. `google-oauth2|1234567890`). Cookie:
  `WorkosCursorSessionToken=<sub>::<accessToken>` — raw `::` join, no percent
  encoding. No email/account id needed. Re-read the token from the DB on every
  poll (Cursor rotates it). NEVER log/print the token, `sub`, or the assembled
  cookie; `--check` may report shape only (e.g. `JWT, 3 сегмента, sub найден`).

## Request

- `GET https://cursor.com/api/usage-summary`, timeout 15 s. Headers:
  `Cookie: WorkosCursorSessionToken=<sub>::<token>`, `Accept: application/json`,
  `Origin: https://cursor.com`, `Referer: https://cursor.com/dashboard`, and the
  same browser-like Safari `User-Agent` as the codex provider (WAF).
- Poll every 300 s (billing-cycle data moves slowly; be gentle with the web
  endpoint). First fetch at launch and on wake, per v0.2. Per-provider
  stale/error isolation per v0.2.
- HTTP 401/403 → cursor token-expired state: menu line
  `Токен Cursor истёк — открой Cursor`, keep last data, per-provider ⚠.

## Parse → buckets (no windows — everything resets at `billingCycleEnd`)

Response shape (see fixtures): `billingCycleStart`/`billingCycleEnd` (ISO 8601
with milliseconds + `Z` — the v0.1 date parser's `.SSSXXXXX` fallback covers
it), `membershipType`, `isUnlimited`, display strings
`autoModelSelectedDisplayMessage`/`namedModelSelectedDisplayMessage`,
`individualUsage.plan {used, limit, remaining, autoPercentUsed, apiPercentUsed,
totalPercentUsed}`, `individualUsage.onDemand {enabled, used, limit, remaining}`.

Cursor has NO session/weekly windows. Every bucket's `resets_at` =
`billingCycleEnd`. Buckets, in this order:

1. **Auto+Composer** — kind `cursor_auto`, window label `Auto`, RU label
   `Auto+Composer`. Percent = `round(plan.totalPercentUsed)` — this matches the
   integer Cursor itself shows in Auto mode (1.527… → 2 %, cf.
   `autoModelSelectedDisplayMessage`). KNOWN TRAP: do NOT use
   `plan.autoPercentUsed` — different denominator, does not match the UI.
2. **API** — kind `cursor_api`, window label `API`, RU label `API-модели`.
   Percent = `round(plan.apiPercentUsed)` (6.466… → 6 %, cf.
   `namedModelSelectedDisplayMessage`).
3. **On-demand** — kind `cursor_on_demand`, window label `OnD`, RU label
   `On-demand`. Present ONLY when `onDemand.enabled == true`. Percent =
   `round(100 * used / limit)`; `limit` null or 0 → unlimited on-demand:
   segment `OnD●∞`, level green, excluded from notification planning.

- **Fallback**: if a bucket's numeric percent field is missing/unparseable,
  extract the first integer before `%` from the corresponding display message
  (`"You've used 2% of your included total usage"` → 2). Both sources missing →
  skip the bucket defensively (never crash).
- `isUnlimited == true` (top-level) → provider contributes a single segment `∞`
  (green), menu row `Cursor: безлимит`, no notifications planned.
- Title group: `Cu·Auto●2% │ API●6%` (+ ` │ OnD●75%` when on-demand active) —
  the v0.1 segment format with the bucket name as window label, no scope suffix.
  Cursor-only active → no `Cu·` prefix (v0.2 single-provider rule).
- Menu rows use the standard v0.1 forms, e.g.
  `● Auto+Composer: 2% · сброс 7 авг 08:27`; exhausted form per v0.1.
- `LimitEntry.provider = "cursor"`. Identifiers per v0.2 format:
  `reset|cursor|cursor_auto||<stamp>` etc. (minute-rounded stamp as usual).

## Notifications (cursor wording)

- Reset: title `Лимиты Cursor обновились`; bodies
  `Cursor: лимит Auto+Composer сброшен.` / `Cursor: лимит API сброшен.` /
  `Cursor: лимит on-demand сброшен.` (generic: `Cursor: лимит <label> сброшен.`).
- Exhausted: titles `Cursor: лимит Auto+Composer исчерпан` /
  `Cursor: лимит API исчерпан` / `Cursor: лимит on-demand исчерпан`; body forms
  as v0.1.

## `--check` (v0.3 addition)

- Cursor section per the v0.2 per-provider format: creds source (DB path found,
  token shape only — never values), fetch, parsed bucket table, title group,
  planned notifications. Inactive → `cursor: неактивен (нет Cursor)`. Cursor is
  live-verifiable on this machine — exit-0 contract includes it when active.

## `checks` additions (fixture-driven)

15. Sample fixture → exactly 2 entries: `cursor_auto` 2 % and `cursor_api` 6 %
    (rounding from 1.527…/6.466…), both resetting at parsed
    `2026-08-07T05:27:30Z`, window labels `Auto`/`API`;
    `onDemand.enabled == false` → no on-demand entry.
16. On-demand fixture → 3 entries: 92 % (red) / 96 % (red) / 75 % (orange);
    on-demand percent computed as `100 * 1500 / 2000`.
17. Display-message fallback: sample fixture with the numeric percent fields
    stripped → Auto 2 / API 6 recovered from the display strings.
18. JWT `sub` extraction: synthetic unsigned JWT with sub `google-oauth2|123` +
    token `T` → cookie value `google-oauth2|123::T`; garbage / 2-segment token →
    nil, no crash; JSON-quoted DB value is unquoted before decoding.
19. Cursor RU labels + notification texts; `isUnlimited` variant → single `∞`
    segment, green, zero planned notifications.
20. Three-provider title: `Cl·… ‖ Cx·… ‖ Cu·…` in that order; cursor-only →
    no prefix (`Auto●2% │ API●6%`).
