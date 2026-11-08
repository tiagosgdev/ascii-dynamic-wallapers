#!/bin/zsh
# Builds "ASCII Wallpapers.app" next to this script. The screen saver inside it
# plays the videos in saver-media/; regenerate those with tools/render-saver.sh.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/ASCII Wallpapers.app"
SAVER="$APP/Contents/Resources/ASCII Wallpapers.saver"
STAMP=$(date +%s)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources"

swiftc -O -o "$APP/Contents/MacOS/ASCIIWallpapers" mac/main.swift
cp web/*.html web/scenes.json "$APP/Contents/Resources/"

swiftc -O -emit-library -module-name ASCIIWallpapersSaver \
  -o "$SAVER/Contents/MacOS/ASCIIWallpapersSaver" mac/saver.swift
# The videos are not in the repo. Without them the wallpapers work and the saver has nothing to play.
videos=(saver-media/*.mp4(N))
if (( ${#videos} )); then cp "${videos[@]}" "$SAVER/Contents/Resources/"; fi
echo "pond" > "$SAVER/Contents/Resources/scene.txt"

cat > "$SAVER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.local.asciiwallpapers.saver</string>
  <key>CFBundleName</key><string>ASCII Wallpapers</string>
  <key>CFBundleExecutable</key><string>ASCIIWallpapersSaver</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>1.2</string>
  <key>CFBundleVersion</key><string>$STAMP</string>
  <key>NSPrincipalClass</key><string>ASCIIWallpapersView</string>
</dict>
</plist>
PLIST

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.local.asciiwallpapers</string>
  <key>CFBundleName</key><string>ASCII Wallpapers</string>
  <key>CFBundleExecutable</key><string>ASCIIWallpapers</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$SAVER"
codesign --force --sign - "$APP"
echo "Built $APP"
