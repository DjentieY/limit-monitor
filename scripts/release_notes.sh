#!/bin/bash
# Print the CHANGELOG.md section body for a given version (no header line).
# Usage: scripts/release_notes.sh 0.5.0
set -euo pipefail

VERSION="${1:?usage: release_notes.sh <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

awk -v ver="$VERSION" '
  $0 ~ ("^## \\[" ver "\\]") { grab = 1; next }
  grab && /^## \[/ { exit }
  grab && /^\[[^]]+\]: / { exit }   # stop at trailing link-reference definitions
  grab { print }
' "$ROOT/CHANGELOG.md"
