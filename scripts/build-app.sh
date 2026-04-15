#!/bin/bash
# build-app.sh — Build "Masko Code.app" bundle from SwiftPM binary and resources.
#
# Run from the repo root. Produces `./build/Masko Code.app`.
# Codesigns with Alex's consistent identifier so TCC entries don't duplicate.
#
# lexabu fork patches applied (see git log):
# - LocalServer.swift binds loopback only
# - /install endpoint returns 410 Gone (CORS attack surface removed)
# - Sparkle auto-update disabled (no SUFeedURL, AppUpdater.init short-circuited)
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"
BUILD_DIR="$REPO_ROOT/build"
APP_PATH="$BUILD_DIR/Masko Code.app"
CODESIGN_IDENT="com.alexabushanab.MaskoCode"

echo "==> Building release binary (arm64)…"
swift build -c release --arch arm64

BIN_DIR="$REPO_ROOT/.build/release"
BIN="$BIN_DIR/masko-code"
RESOURCE_BUNDLE="$BIN_DIR/masko-code_masko-code.bundle"
SPARKLE_FRAMEWORK="$BIN_DIR/Sparkle.framework"

if [[ ! -x "$BIN" ]]; then
  echo "error: binary not found at $BIN" >&2
  exit 1
fi
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "error: resource bundle not found at $RESOURCE_BUNDLE" >&2
  exit 1
fi
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
  echo "error: Sparkle framework not found at $SPARKLE_FRAMEWORK" >&2
  exit 1
fi

echo "==> Assembling $APP_PATH …"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"
mkdir -p "$APP_PATH/Contents/Frameworks"

cp "$BIN" "$APP_PATH/Contents/MacOS/masko-code"
chmod +x "$APP_PATH/Contents/MacOS/masko-code"

cp "$REPO_ROOT/Info.plist" "$APP_PATH/Contents/Info.plist"

# AppIcon.icns goes in Resources/ per CFBundleIconFile=AppIcon
cp "$REPO_ROOT/Sources/Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"

# SwiftPM resource bundle — matches upstream layout at Contents/Resources.
# Bundle.module lookup works here because Foundation's Bundle(path:) search
# resolves .app-bundled sub-bundles relative to the main bundle's Resources.
cp -R "$RESOURCE_BUNDLE" "$APP_PATH/Contents/Resources/masko-code_masko-code.bundle"

# Sparkle framework (kept linked even though AppUpdater.init is short-circuited —
# removing it would require patching Package.swift and MaskoDesktopApp.swift imports)
cp -R "$SPARKLE_FRAMEWORK" "$APP_PATH/Contents/Frameworks/Sparkle.framework"

echo "==> Codesigning with identifier $CODESIGN_IDENT …"
# Deep-sign frameworks first, then the .app
codesign --force --deep --sign - \
  --identifier "$CODESIGN_IDENT" \
  "$APP_PATH/Contents/Frameworks/Sparkle.framework"
codesign --force --deep --sign - \
  --identifier "$CODESIGN_IDENT" \
  "$APP_PATH"

echo "==> Verifying signature …"
codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1 | tail -5 || true

echo ""
echo "✅ Built: $APP_PATH"
echo "   Bundle identifier (Info.plist): com.masko.desktop"
echo "   Codesign identifier (TCC key):  $CODESIGN_IDENT"
