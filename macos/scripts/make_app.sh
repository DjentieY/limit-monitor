#!/bin/bash
# Build "Limit Monitor.app" (menu bar app) from the SwiftPM release binary.
# Usage: ./scripts/make_app.sh [--install]
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

APP="build/Limit Monitor.app"
BIN=".build/release/limit-monitor"

rm -rf "$APP" "build/Claude Limits.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/limit-monitor"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.vladlaiho.limit-monitor</string>
	<key>CFBundleName</key>
	<string>Limit Monitor</string>
	<key>CFBundleExecutable</key>
	<string>limit-monitor</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
</dict>
</plist>
PLIST

codesign --force -s - "$APP"
echo "Built: $APP"

if [[ "${1:-}" == "--install" ]]; then
    # v0.1 shipped as "Claude Limits.app"/claude-limits — remove and kill both
    # generations so an upgrade never leaves two menu bar items behind.
    HAD_V01=0
    if [[ -d "$HOME/Applications/Claude Limits.app" ]]; then HAD_V01=1; fi
    pkill -x claude-limits 2>/dev/null || true
    pkill -x limit-monitor 2>/dev/null || true
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Claude Limits.app" "$HOME/Applications/Limit Monitor.app"
    ditto "$APP" "$HOME/Applications/Limit Monitor.app"
    echo "Installed: $HOME/Applications/Limit Monitor.app (not relaunched)"
    if [[ "$HAD_V01" == 1 ]]; then
        # SMAppService registrations are per-bundle-id and cannot be migrated.
        echo "Upgrade note: the old Claude Limits.app login item does not carry over —"
        echo "re-enable autostart in the new app menu («Запускать при входе») and remove"
        echo "the stale 'Claude Limits' entry in System Settings → Login Items."
    fi
fi
