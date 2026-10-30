#!/bin/bash
set -euo pipefail

# Run on macOS, not through a cross-compiler. Never packages user configuration.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${1:-$(uname -m)}"
case "$ARCH" in
  arm64) NODE_ARCH=arm64; NODE_SHA=bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057 ;;
  x64|x86_64) ARCH=x86_64; NODE_ARCH=x64; NODE_SHA=1462cb3b3046b815cf8ea436d3da450ec1a9f11dac7e5a46b0ada5305d7e8097 ;;
  *) echo 'Supported architectures: arm64, x86_64' >&2; exit 2 ;;
esac
[[ "$(uname -s)" == Darwin ]] || { echo 'This build requires macOS and Xcode command line tools.' >&2; exit 2; }
[[ "$(uname -m)" == "$ARCH" ]] || { echo 'Use a matching Mac runner so native smoke tests actually execute.' >&2; exit 2; }
NODE_VERSION=24.21.0
OUT="$ROOT/tools/macos-worker/build/$NODE_ARCH"
[[ ! -e "$OUT" ]] || { echo "Build output already exists: $OUT. Choose a clean checkout." >&2; exit 2; }
mkdir -p "$OUT/download" "$OUT/dist"
APP="$OUT/FORNAI Worker.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/runtime"
ARCHIVE="node-v$NODE_VERSION-darwin-$NODE_ARCH.tar.gz"
curl --fail --location --proto '=https' --tlsv1.2 --retry 3 "https://nodejs.org/download/release/v$NODE_VERSION/$ARCHIVE" -o "$OUT/download/$ARCHIVE"
echo "$NODE_SHA  $OUT/download/$ARCHIVE" | shasum -a 256 -c -
tar -xzf "$OUT/download/$ARCHIVE" -C "$OUT/download"
NODE_ROOT="$OUT/download/node-v$NODE_VERSION-darwin-$NODE_ARCH"
cp "$NODE_ROOT/bin/node" "$APP/Contents/Resources/runtime/node"
cp "$NODE_ROOT/LICENSE" "$APP/Contents/Resources/runtime/NODE-LICENSE.txt"
cp "$ROOT/scripts/worker-runtime.mjs" "$ROOT/scripts/tray-worker.mjs" "$APP/Contents/Resources/runtime/"
cp "$ROOT/tools/macos-worker/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/tools/macos-worker/Resources/fornai_logo.png" "$APP/Contents/Resources/fornai_logo.png"
plutil -lint "$APP/Contents/Info.plist"

# Platform icon compilation: preserve the artwork's proportions and cream canvas.
ICONSET="$OUT/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 64 128 256 512 1024; do
  sips -s format png --resampleHeightWidthMax "$size" "$APP/Contents/Resources/fornai_logo.png" --out "$OUT/icon-$size.png" >/dev/null
  sips --padToHeightWidth "$size" "$size" --padColor FFF9F0 "$OUT/icon-$size.png" >/dev/null
done
for size in 16 32 128 256 512; do
  cp "$OUT/icon-$size.png" "$ICONSET/icon_${size}x${size}.png"
  double=$((size*2))
  cp "$OUT/icon-$double.png" "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil --convert icns "$ICONSET" --output "$APP/Contents/Resources/AppIcon.icns"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
xcrun swiftc -swift-version 5 -parse-as-library -O -sdk "$SDK" -target "$ARCH-apple-macosx13.5" \
  "$ROOT"/tools/macos-worker/Sources/*.swift -o "$APP/Contents/MacOS/FornaiWorker"
chmod 755 "$APP/Contents/MacOS/FornaiWorker" "$APP/Contents/Resources/runtime/node"
# Keep the original verified Node signature. Ad-hoc outer signing needs no paid
# Developer ID. This is not notarization and does not disable Gatekeeper.
codesign --verify --strict "$APP/Contents/Resources/runtime/node"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
lipo "$APP/Contents/MacOS/FornaiWorker" -verify_arch "$ARCH"
lipo "$APP/Contents/Resources/runtime/node" -verify_arch "$ARCH"
NODE="$APP/Contents/Resources/runtime/node"
[[ "$("$NODE" --version)" == "v$NODE_VERSION" ]]
xcrun swiftc -swift-version 5 -parse-as-library -sdk "$SDK" -target "$ARCH-apple-macosx13.5" \
  "$ROOT/tools/macos-worker/Sources/Policy.swift" "$ROOT/tools/macos-worker/Tests/PolicyTests.swift" -o "$OUT/policy-tests"
"$OUT/policy-tests"
"$NODE" --test "$ROOT/tests/worker-runtime.test.mjs" "$ROOT/tests/worker-agent.test.mjs" "$ROOT/tests/worker-repository.test.mjs" "$ROOT/tests/tray-worker.test.mjs" "$ROOT/tests/worker-renewal.test.mjs"
"$APP/Contents/MacOS/FornaiWorker" --self-test --screenshot "$OUT/dist/fornai-worker-macos-$NODE_ARCH.png"
ZIP="$OUT/dist/fornai-worker-macos-$NODE_ARCH.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$OUT/dist" && shasum -a 256 "fornai-worker-macos-$NODE_ARCH.zip" > "fornai-worker-macos-$NODE_ARCH.sha256")
printf 'macOS package verified: %s\n' "$ZIP"
