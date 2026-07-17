# limit-monitor

Menu-bar monitor for your AI subscription rate limits. See at a glance how much
of your Claude, Codex and Cursor rate limits is left — 5-hour session, weekly,
promotional, billing-cycle — and get a native notification the moment a window
resets or hits 100%.

```
5h●42% │ 7d●29% │ 7d●51% Fable
```

and with several providers logged in:

```
Cl·5h●42% │ 7d●29% │ 7d●51% Fable ‖ Cx·5h●12% │ 7d●40% ‖ Cu·Auto●2% │ API●6%
```

Each limit gets its own colored dot: green &lt;50%, yellow ≥50%, orange ≥75%,
red ≥90%. Unknown/promotional limit kinds (like the current "Fable" weekly
promo) are picked up dynamically from the API — new promos appear in the bar
without an app update.

**Today:** macOS menu bar app for Claude, Codex and Cursor (native Swift, zero
dependencies). **Next:** any provider that has a balance — see
[Roadmap](#roadmap).

## Features

- 5-hour session, weekly, and any scoped/promotional Claude limits, straight
  from the same API endpoint the official `/usage` screen uses
- **Codex limits** in the same bar: if `~/.codex/auth.json` exists, the Codex
  5-hour/weekly windows appear as a second `Cx·` group (polled gently, every
  3 minutes); providers are independent — one failing never hides the other
- **Cursor limits** too: if Cursor is installed and logged in, your
  Auto+Composer, API and (when enabled) on-demand usage for the current
  billing cycle shows up as a `Cu·` group — the session token is read from
  Cursor's local state, strictly read-only, polled every 5 minutes
- Colored per-limit dots in the menu bar + detailed dropdown with reset times
- **Reset notifications** — pre-scheduled at the exact reset moment, so they
  fire on time even if you are offline
- **Exhaustion notifications** — one (deduplicated) alert when a limit hits
  100%, naming the limit and when it comes back
- Read-only by design: it never refreshes or mutates your Claude, Codex or
  Cursor tokens, so it can never desync those tools' own sessions
- No telemetry, no third-party dependencies; the only network calls are
  `GET api.anthropic.com/api/oauth/usage` and, when the respective creds
  exist, `GET chatgpt.com/backend-api/wham/usage` and
  `GET cursor.com/api/usage-summary`

## Roadmap

- [ ] **Codex + Cursor adapters** in the macOS app (in progress) — one bar for
  all your coding-agent subscriptions
- [ ] **Any provider, any balance** — pluggable adapters for every place your
  AI money lives: API credit balances (OpenAI API, Anthropic API, OpenRouter, …)
  and the model developers' own platforms — Moonshot (Kimi), Zhipu (GLM),
  Alibaba (Qwen), DeepSeek, and friends. If it exposes a balance or a quota,
  it should fit in the bar.
- [ ] **macOS widget** — Notification Center / sidebar widget (WidgetKit) for a
  quick glance without touching the menu bar
- [ ] **Cross-platform core** — shared Go core + Windows/Linux tray apps
- [ ] UI localization (menu is currently Russian) and a README screenshot

## Install (macOS)

Requires macOS 13+, [Claude Code](https://claude.com/claude-code) logged in,
and the Xcode Command Line Tools (`xcode-select --install`).

```sh
curl -fsSL https://raw.githubusercontent.com/DjentieY/limit-monitor/main/install.sh | sh
```

The script builds the app locally, installs `Limit Monitor.app` into
`~/Applications` and launches it (upgrading from the old `Claude Limits.app`
removes it first). If the old app had autostart enabled, re-enable
«Запускать при входе» in the new app's menu and remove the orphaned
"Claude Limits" entry in System Settings → Login Items — login-item
registrations are tied to the bundle id and cannot be migrated. Building
locally means the app is never quarantined — no Gatekeeper friction, no
$99/yr certificate. Click **Allow** on the notification permission prompt,
and enable autostart via the app menu.

## Install with your AI coding agent

Paste this into Claude Code, Cursor, Codex — any coding agent running on the
target Mac:

```text
Install limit-monitor, a macOS menu bar app showing my Claude, Codex and Cursor rate limits:
1. Run: curl -fsSL https://raw.githubusercontent.com/DjentieY/limit-monitor/main/install.sh | sh
2. If it fails because the Swift toolchain is missing, run `xcode-select --install`, wait for it to finish, then retry step 1.
3. Verify: "$HOME/Applications/Limit Monitor.app/Contents/MacOS/limit-monitor" --check must exit 0 and print a table of parsed limits.
4. Tell me to click "Allow" on the macOS notification permission prompt, and that autostart can be enabled via the app's menu («Запускать при входе»).
Detailed agent instructions, troubleshooting and uninstall: https://raw.githubusercontent.com/DjentieY/limit-monitor/main/llms-install.md
```

Agents can also use the app binary as a quota API before starting long
autonomous runs: `limit-monitor --check` prints all current limits per
provider (Claude, plus Codex and Cursor when their credentials exist on the
machine) and exits 0.

## How it works

The app reads the OAuth token Claude Code already stores on your machine
(macOS Keychain item `Claude Code-credentials`, fallback
`~/.claude/.credentials.json`) via `/usr/bin/security`, and polls
`GET https://api.anthropic.com/api/oauth/usage` every 60 s. The `limits[]`
array in the response drives everything: percents, levels, reset schedules,
notification planning.

For Codex it reads `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`) and polls
`GET https://chatgpt.com/backend-api/wham/usage` every 180 s with browser-like
headers (falling back to `/backend-api/codex/usage` on older backends). An
`auth.json` in API-key mode has no plan limits — the app says so and stays
quiet.

For Cursor it reads the session token from Cursor's local `state.vscdb`
(strictly read-only, via `/usr/bin/sqlite3 -readonly` — the database is never
copied or written) and polls `GET https://cursor.com/api/usage-summary` every
300 s. Cursor has no rolling windows: the Auto+Composer, API and (when
enabled) on-demand buckets all reset at the end of the billing cycle, and an
unlimited plan shows as a single green `∞`.

With one provider active the bar shows plain segments; with several, groups
are prefixed `Cl·` / `Cx·` / `Cu·` and joined by `‖`.

If a token has expired the app shows `⚠` on that provider's group and keeps
the last data — just use Claude Code (run `codex`, open Cursor) and each tool
refreshes its own token. The app deliberately never performs an OAuth refresh
(a third-party refresh can rotate the token from under Claude Code / codex /
Cursor and force you to re-login).

Notes:

- UI language is currently Russian; localization is planned.
- The app is ad-hoc signed. macOS ties notification permission to the signing
  identity, so after an update you may be asked for notification permission
  again.

## Uninstall

Uncheck «Запускать при входе» in the app menu (removes the login item), quit
the app, then (the second path covers pre-rename installs):

```sh
rm -rf ~/Applications/"Limit Monitor.app" ~/Applications/"Claude Limits.app"
```

## Repository layout

- `macos/` — the Swift app (SPM package: pure-logic core, AppKit shell,
  assertion-based checks; `macos/SPEC.md` is the binding spec)
- `install.sh` — one-line installer (build from source, no quarantine)
- `llms-install.md` — install instructions written for AI coding agents
- `research/` — landscape research memo behind the design decisions

## License

MIT
