# limit-monitor — installation instructions for AI coding agents

You are an AI coding agent asked to install **limit-monitor** — a macOS menu
bar app that shows the user's Claude subscription rate limits (5-hour window,
weekly window, promotional/scoped limits) with colored per-limit dots and
native notifications on window reset and 100% exhaustion.

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

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/DjentieY/limit-monitor/main/install.sh | sh
```

Equivalent manual steps if you prefer explicit control:

```sh
git clone --depth 1 https://github.com/DjentieY/limit-monitor /tmp/limit-monitor
cd /tmp/limit-monitor/macos
./scripts/make_app.sh --install     # builds, ad-hoc signs, installs to ~/Applications
open "$HOME/Applications/Claude Limits.app"
```

## Verify (must pass before reporting success)

```sh
"$HOME/Applications/Claude Limits.app/Contents/MacOS/claude-limits" --check
```

Must exit 0 and print a table of parsed limits plus the menu-bar title string
(e.g. `●42% 5h·●29% 7d·●51% Fable`). This performs a real end-to-end fetch
against `api.anthropic.com` using the user's stored token. Never print or log
token values.

Also confirm the process is running: `pgrep -f "Claude Limits.app"`.

## Tell the user after installing

- Click **Allow** on the macOS notification permission prompt (needed for the
  reset/exhaustion notifications).
- Autostart at login: enable «Запускать при входе» in the app's dropdown menu.
- `⚠` in the menu bar means the stored token expired — using Claude Code once
  refreshes it automatically; the app never refreshes tokens itself.
- The app is ad-hoc signed: after a future update macOS may re-ask for
  notification permission. This is expected.

## Troubleshooting

- **`--check` exits 1 with a credentials error**: Claude Code is not logged
  in on this machine, or the Keychain read was denied. Fall back to checking
  `~/.claude/.credentials.json`.
- **`--check` reports HTTP 401**: token expired — run any Claude Code command,
  then retry.
- **Keychain permission dialog appears**: expected on some setups; the user
  should click "Always Allow".
- **Build errors**: ensure Command Line Tools are current
  (`softwareupdate --list` / reinstall `xcode-select --install`). The package
  needs Swift 5.10+ (tools-version), macOS 13+.

## Uninstall

1. Uncheck «Запускать при входе» in the app menu (removes the SMAppService
   login item).
2. Quit the app (menu → «Выход»).
3. `rm -rf ~/Applications/"Claude Limits.app"`
4. Optional: `defaults delete com.vladlaiho.claude-limits` to drop settings.
