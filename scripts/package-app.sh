#!/bin/bash
# Builds the release binary and assembles a signed .app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> swift build -c release"
swift build -c release --product sn-monitor
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="$ROOT/dist/sn-monitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/sn-monitor" "$APP/Contents/MacOS/sn-monitor"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if codesign --force --sign - "$APP" 2>/dev/null; then
    echo "==> ad-hoc signed"
else
    echo "warning: codesign failed; the app still runs locally" >&2
fi

echo "Built: $APP"
echo "Run:   open \"$APP\""
