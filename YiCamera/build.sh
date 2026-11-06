#!/bin/zsh
# Builds "Yi Camera.app" next to this script. Needs only the Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")"

# Use the newest installed SDK that this Swift compiler can actually load.
for candidate in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk "$(xcrun --show-sdk-path 2>/dev/null)" 2>/dev/null | sort -rV); do
  if echo 'import AppKit' | swiftc -sdk "$candidate" -typecheck - 2>/dev/null; then export SDKROOT="$candidate"; break; fi
done
echo "Using SDK: ${SDKROOT:-default}"

APP="Yi Camera.app"
BUILD=.build
rm -rf "$APP" "$BUILD"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos13.0 Sources/*.swift -o "$BUILD/YiCamera-$arch"
done
lipo -create "$BUILD"/YiCamera-* -output "$APP/Contents/MacOS/YiCamera"

swift -swift-version 5 Tools/make_icon.swift "$BUILD/icon.png"
ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$BUILD/icon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$BUILD/icon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Yi Camera</string>
  <key>CFBundleDisplayName</key><string>Yi Camera</string>
  <key>CFBundleIdentifier</key><string>local.yicamera.viewer</string>
  <key>CFBundleExecutable</key><string>YiCamera</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Local viewer for a yi-hack camera. No cloud, no ads.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Yi Camera connects to your camera on your home network to show its live video.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
