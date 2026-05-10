#!/usr/bin/env bash
# Build front-mac as a release binary, then wrap it in a menubar-only .app bundle.
# Output: front-mac/build/Mac GPU Monitor.app
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Mac GPU Monitor.app"

ARCH="$(uname -m)"
case "$ARCH" in
    arm64) SWIFT_ARCH="arm64" ;;
    x86_64) SWIFT_ARCH="x86_64" ;;
    *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

echo "==> swift build -c release --arch $SWIFT_ARCH"
swift build -c release --arch "$SWIFT_ARCH"

BIN="$(swift build -c release --arch "$SWIFT_ARCH" --show-bin-path)/MacGPUMonitorTray"
if [[ ! -x "$BIN" ]]; then
    echo "executable not found at $BIN" >&2
    exit 1
fi

echo "==> packaging into $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/mac-gpu-monitor-tray"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/../assets/MacOS_GPU.png" "$APP/Contents/Resources/gpu.png"

# SwiftPM bundles resources into a separate "MacGPUMonitorTray_MacGPUMonitorTray.bundle"
# next to the executable when using .process. Copy that too so Bundle.module
# resolves at runtime inside the .app.
PKG_BUNDLE_DIR="$(swift build -c release --arch "$SWIFT_ARCH" --show-bin-path)"
if compgen -G "$PKG_BUNDLE_DIR/*.bundle" > /dev/null; then
    for b in "$PKG_BUNDLE_DIR"/*.bundle; do
        cp -R "$b" "$APP/Contents/MacOS/"
    done
fi

echo "==> done: $APP"
echo
echo "Run:"
echo "    open '$APP'"
echo
echo "Or from CLI:"
echo "    '$APP/Contents/MacOS/mac-gpu-monitor-tray' --backend-url http://127.0.0.1:9133"
