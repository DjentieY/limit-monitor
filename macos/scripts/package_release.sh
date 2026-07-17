#!/bin/bash
# Build an ad-hoc-signed "Limit Monitor.app" and zip it for a GitHub Release.
# Native build (no Xcode required — matches the project's CLT-only philosophy and
# the arm64 GitHub runner). Intel users build from source via install.sh.
# Output: macos/dist/Limit-Monitor-<version>-macos-<arch>.zip (+ .sha256)
set -euo pipefail

cd "$(dirname "$0")/.."   # macos/

VERSION="${LM_VERSION:-$(cat ../VERSION 2>/dev/null || echo 0.0.0)}"

LM_VERSION="$VERSION" ./scripts/make_app.sh

ARCH="$(uname -m)"                       # arm64 on Apple Silicon
NAME="Limit-Monitor-${VERSION}-macos-${ARCH}"

DIST="dist"
rm -rf "$DIST"
mkdir -p "$DIST"

# Guard against shipping a mislabeled slice.
GOT="$(lipo -archs "build/Limit Monitor.app/Contents/MacOS/limit-monitor")"
if [[ "$GOT" != *"$ARCH"* ]]; then
	echo "error: built binary arch ($GOT) does not include $ARCH" >&2
	exit 1
fi

# ditto produces a macOS-correct archive that preserves the bundle + signature.
ditto -c -k --sequesterRsrc --keepParent "build/Limit Monitor.app" "$DIST/${NAME}.zip"
( cd "$DIST" && shasum -a 256 "${NAME}.zip" > "${NAME}.zip.sha256" )

echo "Packaged: $DIST/${NAME}.zip"
cat "$DIST/${NAME}.zip.sha256"
