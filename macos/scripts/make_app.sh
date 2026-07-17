#!/bin/bash
# Build "Limit Monitor.app" (menu bar app) from the SwiftPM release binary.
# Usage: ./scripts/make_app.sh [--install]
# Env:
#   LM_VERSION  override the version (default: repo-root VERSION file)
#   LM_BUILD    CFBundleVersion build number (default: 1)
#   LM_ARCHS    space-separated arch list for a universal build, e.g. "arm64 x86_64"
#               (default: empty = native build)
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${LM_VERSION:-$(cat ../VERSION 2>/dev/null || echo 0.0.0)}"
BUILD="${LM_BUILD:-1}"
ARCHS="${LM_ARCHS:-}"

# VERSION is interpolated into the Info.plist heredoc below — reject anything
# that is not a plain semver so nothing can be expanded at build time.
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+.][0-9A-Za-z.-]+)?$ ]] \
	|| { echo "error: invalid version '$VERSION' (expected semver)" >&2; exit 1; }

if [[ -n "$ARCHS" ]]; then
	ARCH_FLAGS=()
	for a in $ARCHS; do ARCH_FLAGS+=(--arch "$a"); done
	swift build -c release "${ARCH_FLAGS[@]}"
	BIN=".build/apple/Products/Release/limit-monitor"
	# Only ever fall back to a final product, never a per-arch intermediate.
	[[ -f "$BIN" ]] || BIN="$(find .build -path '*apple/Products/Release/limit-monitor' -type f 2>/dev/null | head -1)"
	[[ -f "$BIN" ]] || { echo "error: universal product not found under .build" >&2; exit 1; }
	for a in $ARCHS; do
		lipo -archs "$BIN" | grep -qw "$a" \
			|| { echo "error: $BIN is missing requested arch $a" >&2; exit 1; }
	done
else
	swift build -c release
	BIN=".build/release/limit-monitor"
	[[ -f "$BIN" ]] || { echo "error: built binary not found at $BIN" >&2; exit 1; }
fi

APP="build/Limit Monitor.app"

rm -rf "$APP" "build/Claude Limits.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/limit-monitor"

cat > "$APP/Contents/Info.plist" <<PLIST
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
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${BUILD}</string>
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
echo "Built: $APP (v${VERSION}${ARCHS:+, archs: $ARCHS})"

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
