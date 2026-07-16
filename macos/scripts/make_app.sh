#!/bin/bash
# Build "Claude Limits.app" (menu bar app) from the SwiftPM release binary.
# Usage: ./scripts/make_app.sh [--install]
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

APP="build/Claude Limits.app"
BIN=".build/release/claude-limits"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/claude-limits"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.vladlaiho.claude-limits</string>
	<key>CFBundleName</key>
	<string>Claude Limits</string>
	<key>CFBundleExecutable</key>
	<string>claude-limits</string>
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
    pkill -x claude-limits 2>/dev/null || true
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Claude Limits.app"
    ditto "$APP" "$HOME/Applications/Claude Limits.app"
    echo "Installed: $HOME/Applications/Claude Limits.app (not relaunched)"
fi
