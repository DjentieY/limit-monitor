# limit-monitor

Menu-bar monitor for your AI subscription rate limits. See at a glance how much
of your Claude 5-hour window, weekly window and promotional limits is left —
and get a native notification the moment a window resets or hits 100%.

```
●42% 5h·●29% 7d·●51% Fable
```

Each limit gets its own colored dot: green &lt;50%, yellow ≥50%, orange ≥75%,
red ≥90%. Unknown/promotional limit kinds (like the current "Fable" weekly
promo) are picked up dynamically from the API — new promos appear in the bar
without an app update.

**Today:** macOS menu bar app for Claude (native Swift, zero dependencies).
**Roadmap:** Windows/Linux tray via a shared Go core; Codex and Cursor adapters.

## Features

- 5-hour session, weekly, and any scoped/promotional Claude limits, straight
  from the same API endpoint the official `/usage` screen uses
- Colored per-limit dots in the menu bar + detailed dropdown with reset times
- **Reset notifications** — pre-scheduled at the exact reset moment, so they
  fire on time even if you are offline
- **Exhaustion notifications** — one (deduplicated) alert when a limit hits
  100%, naming the limit and when it comes back
- Read-only by design: it never refreshes or mutates your OAuth token, so it
  can never desync Claude Code's session
- No telemetry, no third-party dependencies; the only network call is
  `GET api.anthropic.com/api/oauth/usage`

## Install (macOS)

Requires macOS 13+, [Claude Code](https://claude.com/claude-code) logged in,
and the Xcode Command Line Tools (`xcode-select --install`).

```sh
curl -fsSL https://raw.githubusercontent.com/DjentieY/limit-monitor/main/install.sh | sh
```

The script builds the app locally, installs `Claude Limits.app` into
`~/Applications` and launches it. Building locally means the app is never
quarantined — no Gatekeeper friction, no $99/yr certificate. Click **Allow**
on the notification permission prompt, and enable autostart via the app menu.

## Install with your AI coding agent

Paste this into Claude Code, Cursor, Codex — any coding agent running on the
target Mac:

```text
Install limit-monitor, a macOS menu bar app showing my Claude rate limits:
1. Run: curl -fsSL https://raw.githubusercontent.com/DjentieY/limit-monitor/main/install.sh | sh
2. If it fails because the Swift toolchain is missing, run `xcode-select --install`, wait for it to finish, then retry step 1.
3. Verify: "$HOME/Applications/Claude Limits.app/Contents/MacOS/claude-limits" --check must exit 0 and print a table of parsed limits.
4. Tell me to click "Allow" on the macOS notification permission prompt, and that autostart can be enabled via the app's menu («Запускать при входе»).
Detailed agent instructions, troubleshooting and uninstall: https://raw.githubusercontent.com/DjentieY/limit-monitor/main/llms-install.md
```

Agents can also use the app binary as a quota API before starting long
autonomous runs: `claude-limits --check` prints all current limits and exits 0.

## How it works

The app reads the OAuth token Claude Code already stores on your machine
(macOS Keychain item `Claude Code-credentials`, fallback
`~/.claude/.credentials.json`) via `/usr/bin/security`, and polls
`GET https://api.anthropic.com/api/oauth/usage` every 60 s. The `limits[]`
array in the response drives everything: percents, levels, reset schedules,
notification planning.

If the token has expired the app shows `⚠` and keeps the last data — just use
Claude Code and it refreshes the token itself. The app deliberately never
performs an OAuth refresh (a third-party refresh can rotate the token from
under Claude Code and force you to re-login).

Notes:

- UI language is currently Russian; localization is planned.
- The app is ad-hoc signed. macOS ties notification permission to the signing
  identity, so after an update you may be asked for notification permission
  again.

## Uninstall

Uncheck «Запускать при входе» in the app menu (removes the login item), quit
the app, then:

```sh
rm -rf ~/Applications/"Claude Limits.app"
```

## Repository layout

- `macos/` — the Swift app (SPM package: pure-logic core, AppKit shell,
  assertion-based checks; `macos/SPEC.md` is the binding spec)
- `install.sh` — one-line installer (build from source, no quarantine)
- `llms-install.md` — install instructions written for AI coding agents
- `research/` — landscape research memo behind the design decisions

## License

MIT
