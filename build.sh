#!/bin/zsh
# Builds build/Clawde.app: compiles the Swift sources for Apple silicon and
# Intel (set ARCHS=arm64 for a quicker build of just one), writes the bundle's
# Info.plist and icon, and signs it ad hoc so macOS will launch it.
set -euo pipefail
cd "${0:A:h}"

APP=build/Clawde.app
VERSION=${VERSION:-1.0.0}
ARCHS=(${=ARCHS:-arm64 x86_64})
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

slices=()
for arch in $ARCHS; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos14.0" \
    -framework AppKit -framework IOKit -framework ApplicationServices -framework ServiceManagement \
    -o "build/obj/Clawde-$arch" Sources/*.swift
  slices+=("build/obj/Clawde-$arch")
done
lipo -create -output "$APP/Contents/MacOS/Clawde" $slices

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Clawde</string>
  <key>CFBundleDisplayName</key><string>Clawde</string>
  <key>CFBundleIdentifier</key><string>io.github.t1anhe.clawde</string>
  <key>CFBundleExecutable</key><string>Clawde</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>An unofficial fan-made pet. Clawd is Anthropic's mascot.</string>
  <key>NSAppleEventsUsageDescription</key><string>Clawde asks Music or Spotify whether a song is playing, so Clawd can put its headphones on.</string>
</dict>
</plist>
PLIST

# Clawd's animations, as tools/import_clawd.py converted them.
cp Resources/clawd-animations.json "$APP/Contents/Resources/"

ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
"$APP/Contents/MacOS/Clawde" --iconset "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "built $APP ($ARCHS)"
