#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Duo More Thing.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/obj"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"

echo "→ metal (shader is compiled at runtime, no toolchain needed)"
cp "$ROOT/Shaders/Fold.metal" "$APP/Contents/Resources/Fold.metal"
if xcrun -sdk macosx metal -O3 -c "$ROOT/Shaders/Fold.metal" -o "$BUILD/obj/Fold.air" 2>/dev/null; then
  xcrun -sdk macosx metallib "$BUILD/obj/Fold.air" -o "$APP/Contents/Resources/default.metallib"
fi

echo "→ swift"
swiftc -O \
  -target arm64-apple-macos26.0 \
  -framework AppKit -framework Metal -framework MetalKit \
  -framework MetalPerformanceShaders -framework ScreenCaptureKit -framework IOKit \
  "$ROOT"/Sources/*.swift \
  -o "$APP/Contents/MacOS/DuoMoreThing"

echo "→ codesign"
codesign --force --sign - --timestamp=none "$APP" >/dev/null

if [ "${1:-}" = "install" ]; then
  pkill -f "Duo More Thing.app/Contents/MacOS/DuoMoreThing" 2>/dev/null || true
  rm -rf "/Applications/Duo More Thing.app"
  cp -R "$APP" "/Applications/Duo More Thing.app"
  echo "✓ /Applications/Duo More Thing.app"
  echo "  (Screen Recording permission is bound to the path and code signature —"
  echo "   macOS may ask for it again after a reinstall)"
  exit 0
fi

echo "✓ $APP"
