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

---

# v0.4 — Custom providers: balances & quotas via providers.json (2026-07-17)

Config-driven providers on top of the v0.2 multi-provider architecture.
`research/providers.md` is NORMATIVE for endpoint shapes, field names and traps
of every adapter; the fixtures listed below are the parsing source of truth.
Built-in adapters: `openrouter`, `deepseek`, `moonshot`, `zhipu`; built-in
presets over the generic engine: `siliconflow`, `novita`; plus `generic-http`
for anything else. OpenAI/Anthropic have NO balance API (admin spend-reports
deferred); Groq/Mistral/Cerebras/Together/Fireworks are console-only —
documented in README, not implemented.

## Config file

- Path: `~/.config/limit-monitor/providers.json`; env var `LIMIT_MONITOR_PROVIDERS`
  overrides the full path (testing/e2e). Missing file / zero enabled
  entries → feature silently inactive (`--check` prints one line
  `custom: нет ~/.config/limit-monitor/providers.json`). Malformed JSON → one
  disabled menu row `providers.json: ошибка разбора` (never a crash).
- Schema: top-level `version` (must be 1; other → config-error state),
  `defaults { pollSeconds }` (default 300), `providers: []`. Entry fields:
  - `id` — slug `[a-z0-9-]+`, unique, no `|` (invalid/duplicate → that entry
    in config-error state). Used in notification identifiers and state keys.
  - `name` (menu), `label` (bar group prefix, 1–8 chars).
  - `kind` — `openrouter` | `deepseek` | `moonshot` | `zhipu` | `siliconflow` |
    `novita` | `generic-http`; unknown → config-error entry.
  - `enabled` (default true; false → entry skipped entirely, not even shown).
  - `key` — EXACTLY one of `literal` / `env` / `command` (zero or >1 →
    config-error). `command` runs via `/bin/sh -c`, timeout 10 s, stdout
    trimmed; resolved on EVERY poll; failure → provider error state
    `ключ: команда не выполнилась`. `env` is unreliable for Finder-launched
    apps (launchd env) — README must recommend `command` + Keychain
    (`security find-generic-password -w`).
  - `host` — `intl` (default) | `cn`, honored by moonshot/zhipu/siliconflow.
  - `pollSeconds` per entry (fallback: defaults → 300; clamp min 60).
  - `request` / `extract` / `display` / `thresholds` — generic-http (see
    below); presets siliconflow/novita are internally expanded generic
    configs, user supplies only key/host/thresholds.
  - `thresholds { warn, critical }` — balance-mode levels; defaults 5.0 / 1.0.
- A malformed ENTRY degrades only that provider (menu:
  `<name>: ошибка конфига — <reason>`); the rest keep working.
- Permissions: if the file is readable by group/others → warning line in
  `--check` AND one disabled menu row
  `providers.json доступен другим (chmod 600)`. Never auto-chmod.
- The file may contain literal keys: NEVER log/print its contents; `--check`
  prints only the key SOURCE (`env OPENROUTER_API_KEY` / `command` /
  `literal`), never values.

## Generic engine (`generic-http`; presets build on it)

- `request`: `url`, `method` (only GET in v0.4), `headers` (map),
  `timeoutSeconds` (default 15). Placeholder `${KEY}` is substituted in the
  url and in header VALUES (zhipu-style raw-key auth is expressible as
  `"Authorization": "${KEY}"`).
- `extract`: `balance { path, scale=1.0, clampMin? }`,
  `limit { path, scale=1.0 }`, `percentUsed { path }`, `okFlag { path }`.
  Dot-path: split on `.`, integer segment = array index
  (`balance_infos.0.total_balance`, `total.val`, `credits`). A value may be a
  JSON number OR a decimal STRING (strip thousands `,`); parse with `Decimal`.
  Missing/unparseable required path → parse-error state.
- Display-mode resolution: `percentUsed` present → percent-mode (value is
  percent USED, round to Int). Else `balance`+`limit` (limit > 0) →
  percent-mode with `used% = round(100 * (limit - balance) / limit)`. Else
  `balance` → balance-mode. None → config-error.
- Levels: percent-mode → standard v0.1 levels. Balance-mode, on remaining:
  `> warn` → green; `≤ warn` → orange; `≤ critical` → red; `≤ 0` → red AND
  exhausted. `okFlag == false` → red AND exhausted regardless of amount.
- Segments (config providers have no window label): percent-mode `●37%`;
  balance-mode `●$23.45`. Currency: USD→`$`, CNY→`¥`, EUR→`€` prefixes, other
  codes → `23.45 XXX`. Amounts: 2 decimals below 1000, `$1.2k` at ≥ 1000,
  negative `-$2.31`. Menu rows: `● <Name>: 37%` (+ ` · сброс …` when a reset
  is known) / `● <Name>: осталось $23.45`; exhausted → `● <Name>: баланс
  исчерпан` / percent form per v0.1.
- `LimitEntry.provider` = config `id`; generic kind = `custom`.

## Built-in adapters (shapes per research/providers.md §1–6)

- **openrouter** — `GET https://openrouter.ai/api/v1/key`, `Authorization:
  Bearer ${KEY}`. If `data.limit != null` → ONE percent entry:
  `used% = round(100 * (limit - limit_remaining) / limit)`, window label by
  `limit_reset`: daily→`1d`, weekly→`7d`, monthly→`1m`, null→none; no reset
  instant is available → no reset notification. If `limit == null` → secondary
  `GET /api/v1/credits`: balance = `total_credits - total_usage` (Decimal;
  prefer optional `data.remaining_balance` when present). 401/403 on /credits
  → info state `OpenRouter: баланс недоступен этому ключу` (NOT a --check
  failure). Body `{"success":false,"error":"Access denied by security
  policy."}` (any endpoint, RU geo-block) → blocked state `OpenRouter
  недоступен (гео-блокировка)` — keep last data, IS a --check failure. NEVER
  print `data.label` (echoes the key). All numeric fields nullable — Optional
  everywhere.
- **deepseek** — `GET https://api.deepseek.com/user/balance`, Bearer. Amounts
  are decimal STRINGS. Prefer `balance_infos` entry with currency `USD`, else
  first. `is_available == false` → red + exhausted. Currency from the entry.
- **moonshot** — host intl→`api.moonshot.ai` (USD) / cn→`api.moonshot.cn`
  (CNY); `GET /v1/users/me/balance`, Bearer; read `data.available_balance`
  (number). Error envelope `{error:{type:"invalid_authentication_error"}}` →
  bad-key state `ключ отклонён (нужен platform-ключ этого региона)`.
- **zhipu** — host intl→`api.z.ai` / cn→`open.bigmodel.cn`;
  `GET /api/monitor/usage/quota/limit`; headers `Authorization: ${KEY}` (RAW,
  no Bearer), `Accept-Language: en-US,en`. Errors arrive as HTTP 200: `success
  == false` + `code == 1001` → bad-key; `code == 500` && `msg` contains
  "coding plan" (case-insensitive) → no-plan state `нет Coding Plan
  (PAYG-ключ)`. Success → `data.limits[]` (accept `type` or legacy `name`):
  `TOKENS_LIMIT` → percent entries: `percentage` = percent USED (round);
  window from `unit` (3=hours, 4=days, 5=months, 6=weeks) × `number` → label
  via the codex rule (`5h`, `7d`, months→`1m`); `nextResetTime` (epoch MS) →
  resets_at → standard reset notifications (minute-rounded stamps).
  `TIME_LIMIT` (Поиск/MCP counter) → menu-only percent row labelled
  `Поиск/MCP`, EXCLUDED from the bar. Trap: `usage` = LIMIT, `currentValue` =
  used — but only `percentage` is consumed. All fields optional-tolerant.
- **Presets**: siliconflow — `GET https://api.siliconflow.{com|cn}/v1/user/info`,
  Bearer, balance = `data.totalBalance` (decimal string; currency USD/.com,
  CNY/.cn); novita — `GET https://api.novita.ai/openapi/v1/billing/balance/detail`,
  Bearer, balance = `availableBalance` string × 0.0001 USD.

## Multi-provider integration

- Display order: claude, codex, cursor, then config providers in file order.
- Bar group prefixes (>1 active provider): `Cl·`/`Cx·`/`Cu·` and `<label>·`
  for config providers (e.g. `OR·●$74.75 ‖ GLM·5h●37% │ 7d●12%`).
  Single-active → no prefix, as before.
- Polling per entry (default 300 s), independent runtimes, stale/error
  isolation, per-provider ⚠ — all per v0.2 rules.
- Notification identifiers: `reset|<id>|<kind>||<stamp>`,
  `exhausted|<id>|<kind>||<stamp>`; balance exhaustion uses kind `custom` and
  an EMPTY stamp — v0.1 empty-stamp dedup semantics apply (kept while
  exhausted, dropped after recovery).
- Notification texts: reset — title `Лимиты <Name> обновились`, body
  `<Name>: лимит <label> сброшен.`; percent ≥100 — title `<Name>: лимит
  <label> исчерпан`, v0.1 body forms; balance exhausted — title `<Name>:
  баланс исчерпан`, body `Осталось <formatted>.` (e.g. `Осталось $0.00.`).

## `--check` (v0.4 addition)

- Section per enabled config provider: key source (never values), host, fetch,
  parsed table, planned notifications. Missing config → single `custom:` line.
- Exit contract: config-error, key-resolution failure, bad-key, no-plan,
  blocked, fetch/parse failure of an ENABLED provider → exit 1. Missing config
  file, `enabled:false`, and the OpenRouter credits-denied info state → NOT
  failures.

## `checks` additions (fixture-driven)

21. Config parsing: `providers_config_sample.json` → 5 enabled providers
    (openrouter literal / deepseek env / zhipu command / siliconflow preset /
    generic-http hyperbolic), kimi entry skipped (`enabled:false`), thresholds
    and pollSeconds resolved; `providers_config_invalid.json` → per-entry
    config-errors (two key sources; unknown kind; `|` in id) without crash.
22. Dot-path/Decimal: array-index path, thousands-comma string, scales 0.0001
    / 0.01 / −0.01 with `clampMin: 0`, missing path → nil.
23. openrouter: key fixture → percent entry 26% used, window `1m`; credits
    fixture → balance `$74.75`; geo-403 fixture → blocked state.
24. deepseek: sample → `$23.45` USD, green at default thresholds; unavailable
    variant → red + exhausted, CNY formatting `¥0.00`.
25. moonshot: sample → `$12.35`; auth-error envelope → bad-key.
26. zhipu: sample → TOKENS 5h 37% + weekly 7d 12% with resets_at parsed from
    epoch-ms and minute-rounded identifiers, TIME_LIMIT 7% menu-only (absent
    from bar segments); 1001 fixture → bad-key; coding-plan-500 fixture →
    no-plan.
27. presets: siliconflow sample → `$23.50`; novita sample → `$123.45`.
28. Balance formatting/levels: `$`/`¥`/`XXX` codes, `$1.2k`, thresholds
    green/orange/red, ≤0 → red+exhausted, `okFlag:false` → red+exhausted.
29. Balance-exhaustion notification: identifier `exhausted|<id>|custom||`
    (empty stamp), RU texts, dedup semantics; zhipu reset notification
    identifiers minute-rounded.
30. Multi-provider title: `Cl·… ‖ OR·●$74.75 ‖ GLM·5h●37% │ 7d●12%`; a single
    active config provider alone → no prefix.

## Fixtures (already authored by the orchestrator — use as-is, do not modify)

`providers_config_sample.json`, `providers_config_invalid.json`,
`openrouter_key_sample.json`, `openrouter_key_nolimit.json`,
`openrouter_credits_sample.json`, `openrouter_geo403.json`,
`deepseek_balance_sample.json`, `deepseek_balance_unavailable.json`,
`moonshot_balance_sample.json`, `moonshot_error_auth.json`,
`zhipu_quota_sample.json`, `zhipu_error_1001.json`, `zhipu_error_noplan.json`,
`siliconflow_user_info_sample.json`, `novita_balance_sample.json`.

## Docs (v0.4)

- README: new "Custom providers (balances)" section — config path, a short
  example, security notes (chmod 600; `command` + Keychain over `env`), the
  support matrix (built-ins, presets, generic recipes for Hyperbolic/xAI,
  document-only: Groq/Mistral/Cerebras/Together/Fireworks console-only;
  OpenAI/Anthropic have no balance API — admin spend-reports planned), pointer
  to `examples/providers.example.json` (create it: sample config with env-key
  entries for all built-ins + one generic recipe, no real keys). Tick the
  Roadmap checkbox for "Any provider, any balance".
- llms-install.md: mention `--check` covers configured custom providers.

---

# v0.5 — Settings window, provider toggles, snapshot/--status, desktop card (2026-07-17)

Owner feature request: clicking the status item must give access to Settings
where providers can be enabled/disabled with CHECKBOXES. Plus the researched
widget fallback (`research/widget.md` is NORMATIVE: a real WidgetKit .appex is
BLOCKED under ad-hoc signing by the chronod identity gate — do NOT attempt it;
the conserved recipe activates only with an Apple-issued identity): snapshot
file, `--status [--json]`, NSPanel desktop card.

## Settings window («Настройки…»)

- Menu gains item `Настройки…` (⌘,) directly above the final separator +
  `Выход`. Opens ONE reusable NSWindow (recreate if closed), title
  `Limit Monitor — настройки`, fixed width ≈ 380, auto height, not resizable,
  `NSApp.activate` + `makeKeyAndOrderFront` (LSUIElement apps must activate
  explicitly). Plain AppKit (no SwiftUI — keep zero-dep style).
- Section `Провайдеры` — one CHECKBOX per known provider:
  - Built-ins always listed: `Claude`, `Codex`, `Cursor`.
  - Custom: one row per entry of providers.json (config `name`), shown only
    when the config has entries (incl. entries with `enabled:false` — shown
    unchecked-and-disabled with tooltip `выключен в providers.json`).
  - Checkbox state persisted in UserDefaults `disabledProviders: [String]`
    (provider ids; built-ins use `claude`/`codex`/`cursor`). Effective
    enablement: built-in → creds present && NOT disabled; custom → config
    `enabled` && NOT disabled.
  - Unchecking applies IMMEDIATELY: polling stops, bar segments and menu rows
    disappear, snapshot excludes it, pending `reset|<id>|*` notifications are
    removed right away (explicit reconcile on toggle — this complements the
    replan-only-on-success rule), no new notifications. Checking re-enables
    and triggers an immediate poll of that provider.
  - All providers may be disabled: the status item then shows static `LM`
    (menu stays reachable, incl. Настройки).
  - Below the checkboxes: a hint line with the config path
    `~/.config/limit-monitor/providers.json` and a button
    `Показать в Finder` (NSWorkspace reveal; disabled when the file does not
    exist).
- Section `Общие` — mirrors of the existing menu toggles (same UserDefaults,
  two-way sync): `Уведомления о лимитах`, `Запускать при входе`,
  `Виджет на рабочем столе` (new, below).
- `--check` reflects disabled providers with line `<id>: отключён в настройках`
  (skipped, NOT a failure).

## Widget-ready snapshot + `--status`

- After every poll cycle the app atomically (temp file + rename) writes
  `~/Library/Application Support/limit-monitor/widget-snapshot.json`:
  ```json
  { "version": 2, "generatedAt": "2026-07-17T09:00:00+00:00", "providers": [
    { "id": "claude", "name": "Claude", "label": "Cl", "stale": false, "limits": [
      { "kind": "session", "windowLabel": "5h", "percent": 9, "text": "9%",
        "level": "green", "resetsAt": "2026-07-17T09:30:00+00:00", "exhausted": false },
      { "kind": "weekly_scoped", "scopeName": "Fable", "windowLabel": "7d",
        "percent": 39, "text": "39%", "level": "green",
        "resetsAt": "2026-07-20T08:00:00+00:00", "exhausted": false } ] },
    { "id": "codex", "name": "Codex", "label": "Cx", "stale": false, "limits": [
      { "kind": "session", "windowLabel": "5h", "windowMinutes": 335, "percent": 20,
        "text": "20%", "level": "green", "resetsAt": "2026-07-17T13:00:00+00:00",
        "exhausted": false } ] },
    { "id": "deepseek", "name": "DeepSeek", "label": "DS", "stale": false, "limits": [
      { "kind": "custom", "text": "$23.45", "level": "green", "exhausted": false } ] } ] }
  ```
  Schema **v2** is fully NEUTRAL: the provider-level `label` (bar prefix) stays,
  but each row drops the localized `label` and instead carries neutral structural
  fields — `kind`, `scopeName` (brand/model, e.g. `Fable`), `windowLabel`,
  `windowMinutes` (raw window size; classifies codex/config labels at
  ±60/±1440 tolerance), `percent`/balance `text`, `level`, `resetsAt`. Readers
  reconstruct the display label at render time in their own locale. Only providers
  with data; disabled providers excluded; NO secrets ever (numbers, neutral tokens
  and ISO UTC times only — never a localized string). `--check` ALSO writes the
  snapshot on success (so agents get a fresh file without the GUI).
- New CLI modes (before any AppKit setup, like `--check`):
  - `--status` — human RU table rendered FROM the snapshot file (per provider:
    rows with percent/balance, level word, reset time; header
    `Обновлено: HH:mm` + suffix `(устарело)` when `generatedAt` older than
    15 min). No network.
  - `--status --json` — print the snapshot file verbatim. Exit 0.
  - Snapshot missing/unreadable → RU line `снапшот недоступен — запусти
    Limit Monitor или limit-monitor --check` + exit 2.
- README: document `--status --json` as the agent/SwiftBar/xbar/Raycast
  integration point (one-line SwiftBar plugin example).

## Desktop card (NSPanel — the ad-hoc-compatible "widget")

- Toggle `Виджет на рабочем столе` (menu + settings; UserDefaults
  `desktopCard`, default OFF).
- Non-activating NSPanel (`.nonactivatingPanel`), NSVisualEffectView material
  `.hudWindow`, corner radius 12, `isMovableByWindowBackground = true`,
  position persisted in UserDefaults `cardOrigin` (default: top-right of the
  main screen, 16 px margins; clamp into the visible frame on restore),
  `level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)`
  (above desktop icons, below normal windows),
  `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]` —
  per research/widget.md risk table (no Mission Control flicker).
- Content, rebuilt after every poll from the same merged model as the menu:
  per enabled provider with data — header line (provider name, ⚠ when
  stale/expired) and one row per limit: colored dot (same level colors),
  label, value (`9%` / `$23.45` / `∞`), short reset time (`до 12:30`).
  Compact system font; ~260 pt wide.
- The card never takes focus, never appears in the Dock/app switcher, closes
  when the toggle is switched off. No WidgetKit, no .appex, platforms stay
  `.v13`.

## `checks` additions (31–35)

31. Snapshot builder: fixture-driven providers (claude fixture + a balance
    custom) → schema-v1 JSON: version 1, ISO-8601 UTC `generatedAt`/`resetsAt`,
    level strings, exhausted flags; output contains NO `sk-`, `eyJ`, `Bearer`
    substrings.
32. Snapshot round-trip: builder output parses back; staleness rule
    (generatedAt older than 15 min vs fixed now → stale).
33. `disabledProviders` filtering: a disabled provider is excluded from title
    segments, menu model, notification desired-set AND snapshot; its pending
    `reset|<id>|*` identifiers become removable in the reconcile plan.
34. Settings model: toggle off → on yields an immediate-poll request for
    exactly that provider (Core-level model, no AppKit).
35. `--status` rendering: given a snapshot fixture — human table contains RU
    labels, level words and `(устарело)` for an old generatedAt; `--status
    --json` output is byte-identical to the file.

## Docs (v0.5)

- README Features: settings window with provider checkboxes; desktop card;
  `--status --json`. Roadmap: tick the macOS-widget item, rewording it to
  `desktop card + snapshot/status JSON (real WidgetKit widget requires an
  Apple-signed build — recipe conserved in research/widget.md)`.
- llms-install.md: `--status --json` for agents (prefer it over `--check` for
  frequent polling — no network).

---

# v0.6 — Internationalization: English default + Russian (2026-07-17)

The UI is currently Russian-only while the repo/README are English. v0.6 makes
**English the default** and keeps Russian, selected automatically by the system
language. Approved via the dev-v2 design loop (concept-roaster APPROVED, 8/10).
No behavior changes beyond wording/locale; all providers, notifications,
settings and snapshot semantics stay as specified above.

## Mechanism — a code catalog in Core (NOT `.strings`/`.lproj`)

- Each user-facing string has an EN and a RU production selected by an
  **exhaustive `switch (lang, …)`** in `LimitMonitorCore`. No resource bundles,
  no `Bundle.module` (fragile for a CLT-only, ad-hoc-signed SPM executable; and
  `checks` must call formatting functions directly). Exhaustiveness makes "every
  key has EN and RU" a compile-time guarantee. Core stays **Foundation-only**.
- Shapes: small **domain enums** with a direct `text(_ lang: Language) -> String`
  method — `MenuStr`, `NotifStr`, `StatusStr`, `StateStr`, `ConfigStr`,
  `NetErrStr`, `ChromeStr` (atomic/templated strings; parameters are typed
  associated values, e.g. `percentWithReset(label:percent:Int,reset:String)`).
  Heavily-branched composites (`Labels.*`, `TimeFormat.*`) stay **functions
  taking `lang`**. No `Localizable` protocol (never used polymorphically).

## `Language` seam

- `public enum Language: String { case en, ru }` in `LimitMonitorCore/Language.swift`.
  `static func resolve(preferred: [String] = Locale.preferredLanguages) -> Language`:
  **EN default**; `.ru` iff `preferred.first?.lowercased()` has prefix `ru`
  (uses `preferredLanguages`, the ordered UI-language list, NOT region). Pure and
  injectable — `checks` drive both locales deterministically regardless of the CI
  machine locale.
- **Explicit threading, per process, no global.** Every localizable Core entry
  point gains `_ lang: Language` as its **last** parameter. The shell resolves
  **one** `let lang` at launch and threads it down. No ambient mutable
  `CurrentLanguage` (would break `checks` determinism). The three surfaces (GUI,
  `--check`, `--status`) are separate process invocations — each resolves one
  language.

## Surface decisions

- **`--check` → ALWAYS English.** It is the e2e/CI/agent diagnostic surface;
  stable English is locale-independent, greppable, reproducible. Rewrite its
  ~25 local console literals RU→EN inline (single-language; `CheckMode` calls
  Core helpers with `lang = .en`), delete the RU pluralization hack
  (`segmentsWord` сегмент/сегмента/сегментов → "1 segment"/"N segments"), and
  drop `ru_RU` from its stamp formatter for `en_US_POSIX`.
- **`--status` → the reader's locale L.** Chrome (`Updated:`/`Обновлено:`,
  `(stale)`/`(устарело)`, level words, `resets`/`сброс`, `exhausted`/`исчерпан`)
  AND each row **label** are produced at render time in L.
- **Menu, notifications, settings window, desktop card → localized (EN default + RU).**
  Preserve the EXACT existing RU wording as the RU arm; do not reword RU.

## Snapshot is fully NEUTRAL (schema v2) — the load-bearing correctness fix

The snapshot file is written by TWO processes (GUI in system locale; `--check`
pinned to EN, which also rewrites it on success). A baked localized `label`
would depend on who last wrote the file, so `--status` could print a mixed
ru/en table. Therefore:

- `WidgetSnapshot.build` takes **no `lang`** and emits only neutral fields.
  `LimitRow` **drops `label`** and gains **`scopeName: String?`** (neutral
  brand/model name, e.g. `Fable`) **and `windowMinutes: Int?`** (neutral raw
  window size — REQUIRED: codex/config-windowed labels are classified from the
  raw minutes with tolerance ±60/±1440, which the rounded `windowLabel` loses;
  without it a 335-min window that the menu shows as `5-часовой` would render as
  `Окно 6 ч` in `--status`). `WidgetSnapshot.currentVersion = 2`; the parser
  rejects any version ≠ 2.
- Labels are reconstructed at each reader's render from a shared neutral
  `LabelDescriptor(providerId, kind, scopeName, windowLabel, windowMinutes,
  isBalance, name)`. `Labels.menuLabel(descriptor:_ lang:)` is the single
  decision tree; the live path feeds it from a `LimitEntry`, the `--status` path
  from a `LimitRow`. One switch, two feeders — no drift, live menu labels
  unchanged.
- `--status --json` stays a verbatim byte copy. Agents key off structural
  fields (`kind`/`scopeName`/`level`/`percent`/`resetsAt`); there is no
  language-bearing field. Ephemeral file (rewritten each poll) → no migration; a
  stale v1 file is rejected and `--status` prints the missing-snapshot hint
  until the next poll writes v2.

## Neutral (never localized)

Bar prefixes `Cl·/Cx·/Cu·` and 2-char labels; window labels `5h/7d/Auto/API/OnD`;
`TitleFormatter` segments; `BalanceFormat`; level tokens `green/yellow/orange/red`;
`N%`; `$23.45`; `∞`; **the app brand name `Limit Monitor`** (`CFBundleName`,
window titles, the desktop-card `Limit Monitor:` prefix — a proper noun). Note:
the app is `LSUIElement`, so there is no standard App menu (no auto `About/Quit
<name>`), and the notification-permission prompt is OS-localized. All snapshot
structural fields and all identifiers stay neutral.

## `checks` additions

- **§36 resolver**: `resolve(preferred:)` — `["ru-RU"]/["ru"]→.ru`,
  `["en-US"]/["de-DE",…]/[]→.en`.
- **§37 both-locale wording**: existing RU asserts (5/9/14/19/35) gain EN
  mirrors; add EN+RU for `MenuText.infoRow`, reset/exhausted titles+bodies
  (claude/codex/cursor/config/balance), `TimeFormat.relative`+`absolute`
  (`через …`/`in …`, `сейчас`/`now`), `StatusCommand` chrome + `levelWord`,
  `MenuStr`/`StateStr`, `ConfigStr` (spot).
- **§38 snapshot v2 + bilingual `--status`**: snapshot is neutral (no `label`;
  has `scopeName`+`windowMinutes`); `--status` render in `.en` vs `.ru` from the
  SAME neutral snapshot yields correct labels incl. a codex window at a
  tolerance boundary (335 min → `5-часовой`/`5-hour`, NOT `Окно 6 ч`).
- **§39 `--status` locale wiring**: drive `StatusCommand.output/render` through a
  `resolve(preferred:)` override and assert output locale (Core-reachable). NOTE:
  `--check` (`CheckMode`) lives in the shell target and is NOT reachable from
  `checks` — its EN pinning is covered by inline literals + Core calls pinned to
  `.en`, not a resolve-override test.
- **Fix existing §32**: the version-rejection sentinel at `checks/main.swift`
  currently uses `version:2` as the rejected case — after the bump it must use a
  different rejected version (e.g. `3`). **Regenerate** `fixtures/
  widget_snapshot_sample.json` to schema v2 (drop `label`, add `scopeName` +
  `windowMinutes`, `version:2`) or §35 hits a FATAL exit.
- Estimate: ~+100 asserts → ~525 total. The compiler proves key completeness;
  `checks` spot-check wording.

## Migration (no big-bang)

Newly-parameterized Core functions get a **transitional `lang: Language = .ru`
default** so un-migrated callers keep emitting RU and the 424 existing asserts
stay green at each step. Order: (0) seam + §36; (1) Core leaves in dependency
order `TimeFormat → Labels(+LabelDescriptor) → MenuText → Notifications →
StatusCommand → WidgetSnapshot(v2) → ProvidersConfig/ConfigAdapters`, adding EN
arms + EN asserts as each lands; (2) shell threads real L (GUI resolves once;
`CheckMode` pins `.en`; `StatusMode` resolves system; pollers thread lang);
(3) **remove the transitional defaults** so the compiler flags any un-threaded
call site; final both-locale `checks` pass. `swift run checks` green after every
sub-step. `TimeFormat` (EN `DateFormatter` set + gating the RU-only quirks
`lowercased(with: ruLocale)`, month-dot strip, `в` preposition) is the fiddliest
file. One file per commit.

## Deferred to v0.7

A manual Auto/EN/RU picker in Settings (the seam is pre-wired; the deferred cost
is live re-render of the status item/menu/card and re-texting already-scheduled
`reset|*` notifications — orthogonal to the i18n core).

## Docs (v0.6)

- README: note that the UI is English by default and switches to Russian on a
  Russian system; drop the "UI currently Russian" caveat.
- llms-install.md / README status section: the snapshot's **structural fields**
  (`kind`/`scopeName`/`level`/`percent`/`resetsAt`) are the agent contract — the
  `label` field is gone; do not grep display strings.
- Update the v0.5 snapshot JSON example above to schema v2 (no `label`; add
  `scopeName`, `windowMinutes`).
