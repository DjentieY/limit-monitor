#!/bin/sh
# limit-monitor installer (macOS): builds Limit Monitor.app from source and
# installs it into ~/Applications. Building locally means no quarantine
# attribute is ever set, so Gatekeeper is not involved.
set -eu

REPO="https://github.com/DjentieY/limit-monitor"
APP_NAME="Limit Monitor.app"

err() { printf 'error: %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || err "macOS only for now (Windows/Linux tray is on the roadmap)"

if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
  err "Swift toolchain not found. Run: xcode-select --install  (then re-run this script)"
fi
command -v git >/dev/null 2>&1 || err "git not found"

WORKDIR=$(mktemp -d /tmp/limit-monitor.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

echo "==> Cloning $REPO"
git clone --depth 1 --quiet "$REPO" "$WORKDIR/limit-monitor"

echo "==> Building (swift build -c release) and installing to ~/Applications"
cd "$WORKDIR/limit-monitor/macos"
./scripts/make_app.sh --install

echo "==> Launching"
open "$HOME/Applications/$APP_NAME"

cat <<'EOF'

Done. Look at your menu bar: 5h●42% │ 7d●29% │ ...
(with Codex/Cursor logged in too: Cl·5h●42% │ 7d●29% ‖ Cx·5h●12% ‖ Cu·Auto●2% │ API●6%)
Next steps:
  1. Click "Allow" on the notification permission prompt.
  2. Enable autostart via the app menu («Запускать при входе»).
If the bar shows ⚠ — that provider's token expired; just use Claude Code
(run codex, open Cursor) once and it refreshes itself.
EOF
