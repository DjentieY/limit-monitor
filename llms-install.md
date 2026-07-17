# limit-monitor — installation instructions for AI coding agents

You are an AI coding agent asked to install **limit-monitor** — a macOS menu
bar app that shows the user's Claude subscription rate limits (5-hour window,
weekly window, promotional/scoped limits) and, when present on the machine,
the Codex rate limits (`~/.codex/auth.json`) and the Cursor billing-cycle
usage (Auto+Composer / API / on-demand buckets, token read from Cursor's
local state) — with colored per-limit dots and native notifications on window
reset and 100% exhaustion.

## Preconditions (check in this order)

1. **OS**: `uname -s` must print `Darwin`. Anything else → stop and tell the
   user only macOS is supported today (Windows/Linux tray is on the roadmap).
2. **Swift toolchain**: `xcode-select -p` and `swift --version` must succeed.
   If not: run `xcode-select --install`, tell the user to confirm the GUI
   dialog, wait for completion, re-check.
3. **Claude Code logged in**: the app reads the OAuth token Claude Code
   stores. Verify one of:
   - `security find-generic-password -s "Claude Code-credentials" -w`
     exits 0 (do NOT print the output — it contains tokens), or
   - `~/.claude/.credentials.json` exists.
   If neither: tell the user to run `claude` and log in first.
4. **Codex (optional)**: if `~/.codex/auth.json` exists, Codex limits appear
   automatically as a second provider — nothing to configure. Its absence is
   fine; `--check` will report `codex: неактивен (нет ~/.codex/auth.json)`.
5. **Cursor (optional)**: if Cursor is installed and logged in (its
   `state.vscdb` under `~/Library/Application Support/Cursor/` holds a session
   token), Cursor usage appears automatically as another provider. The app
   reads that database strictly read-only via `/usr/bin/sqlite3` — it is never
   copied or written. Absence is fine; `--check` reports
   `cursor: неактивен (нет Cursor)`.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/DjentieY/limit-monitor/main/install.sh | sh
```

Equivalent manual steps if you prefer explicit control:

```sh
git clone --depth 1 https://github.com/DjentieY/limit-monitor /tmp/limit-monitor
cd /tmp/limit-monitor/macos
./scripts/make_app.sh --install     # builds, ad-hoc signs, installs to ~/Applications
open "$HOME/Applications/Limit Monitor.app"
```

Installing over the old v0.1 `Claude Limits.app` is handled: the installer
kills and removes both generations before copying the new bundle. One thing
does not carry over — the old app's login item (SMAppService registrations
are per-bundle-id): if the user had autostart enabled, tell them to re-enable
«Запускать при входе» in the new app and to remove the stale "Claude Limits"
entry in System Settings → Login Items.

## Verify (must pass before reporting success)

```sh
"$HOME/Applications/Limit Monitor.app/Contents/MacOS/limit-monitor" --check
```

Must exit 0 and print a section per provider with a table of parsed limits
plus the menu-bar title string (e.g. `5h●42% │ 7d●29% │ 7d●51% Fable`, Cursor
buckets as `Auto●2% │ API●6%`). Exit 0 means every ACTIVE provider fetched and
parsed successfully; an inactive provider (no Codex creds / no Cursor on the
machine) is reported as a single `codex: неактивен (…)` /
`cursor: неактивен (нет Cursor)` line and is NOT a failure. This performs a
real end-to-end fetch against `api.anthropic.com` (and `chatgpt.com` /
`cursor.com` when those providers are active) using the user's stored tokens.
Never print or log token values.

`--check` also covers custom providers configured in
`~/.config/limit-monitor/providers.json` (balances/quotas — OpenRouter,
DeepSeek, Kimi, GLM, etc.): a section per enabled entry that must fetch and
parse for exit 0, with the key SOURCE shown (`env NAME` / `command` /
`literal`) but never key values. A missing config file prints
`custom: нет ~/.config/limit-monitor/providers.json` and is NOT a failure.
Providers the user unchecked in the app's settings window are reported as
`<id>: отключён в настройках` and skipped — also NOT a failure.

Also confirm the process is running: `pgrep -f "Limit Monitor.app"`.

## Polling limits later (agents): prefer `--status --json` over `--check`

For repeated quota checks during long autonomous runs use

```sh
"$HOME/Applications/Limit Monitor.app/Contents/MacOS/limit-monitor" --status --json
```

It prints the snapshot the running app refreshes after every poll
(`~/Library/Application Support/limit-monitor/widget-snapshot.json`:
per-provider percents/balances, level names, ISO-8601 reset times — never
credentials) and makes NO network calls, so it is safe to run every few
seconds. `--status` without `--json` prints a human-readable table instead.
Exit 2 with `снапшот недоступен — запусти Limit Monitor или limit-monitor
--check` means no snapshot exists yet: launch the app or run `--check` once
(a successful `--check` also writes the snapshot). Reserve `--check` for
install verification and troubleshooting — it hits the real APIs on every
invocation.

## Tell the user after installing

- Click **Allow** on the macOS notification permission prompt (needed for the
  reset/exhaustion notifications).
- Autostart at login: enable «Запускать при входе» in the app's dropdown menu.
- `⚠` in the menu bar means that provider's stored token expired — using
  Claude Code (running `codex`, opening Cursor) once refreshes it
  automatically; the app never refreshes tokens itself.
- With several providers active the bar shows prefixed groups:
  `Cl·… ┃ Cx·… ┃ Cu·…` (separators configurable in Settings).
- The app is ad-hoc signed: after a future update macOS may re-ask for
  notification permission. This is expected.

## Troubleshooting

- **`--check` exits 1 with a claude credentials line**: Claude Code is not
  logged in on this machine, or the Keychain read was denied. Fall back to
  checking `~/.claude/.credentials.json`.
- **`--check` reports HTTP 401 for claude**: token expired — run any Claude
  Code command, then retry.
- **`--check` reports HTTP 401 for codex**: run any `codex` command (it
  refreshes its own token), then retry.
- **`--check` reports 401/403 for cursor**: the stored session token expired —
  open Cursor once (it refreshes its own token), then retry.
- **`cursor: неактивен (нет Cursor)`**: Cursor is not installed or not logged
  in on this machine. Not an error.
- **`codex: неактивен (API-key режим — план-лимитов нет)`**: the user's
  `auth.json` only has `OPENAI_API_KEY` — API-key accounts have no plan rate
  limits to show. Not an error.
- **Codex/Cursor parse error**: `--check` prints the response's JSON key tree
  (keys and array counts only, never values) — include it when reporting the
  issue.
- **Keychain permission dialog appears**: expected on some setups; the user
  should click "Always Allow".
- **Build errors**: ensure Command Line Tools are current
  (`softwareupdate --list` / reinstall `xcode-select --install`). The package
  needs Swift 5.10+ (tools-version), macOS 13+.

## Uninstall

1. Uncheck «Запускать при входе» in the app menu (removes the SMAppService
   login item).
2. Quit the app (menu → «Выход»).
3. `rm -rf ~/Applications/"Limit Monitor.app" ~/Applications/"Claude Limits.app"`
   (the second path covers pre-rename installs).
4. Optional: `defaults delete com.vladlaiho.limit-monitor` and
   `defaults delete com.vladlaiho.claude-limits` to drop settings.
