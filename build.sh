#!/bin/zsh
# Builds WallpaperLauncher.app. With --install the app is copied to ~/Applications.
set -e
cd "$(dirname "$0")"
APP=build/WallpaperLauncher.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/WallpaperLauncher" Sources/main.swift 2>&1 | grep -v "warning:" || true
[[ -x "$APP/Contents/MacOS/WallpaperLauncher" ]] || { echo "Build failed"; exit 1; }
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>WallpaperLauncher</string>
  <key>CFBundleDisplayName</key><string>Wallpaper Launcher</string>
  <key>CFBundleIdentifier</key><string>local.wallpaperlauncher</string>
  <key>CFBundleExecutable</key><string>WallpaperLauncher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "✓ $APP built"
if [[ "$1" == "--install" ]]; then
  mkdir -p ~/Applications
  pkill -x WallpaperLauncher 2>/dev/null || true
  rm -rf ~/Applications/WallpaperLauncher.app
  cp -R "$APP" ~/Applications/
  echo "✓ installed to ~/Applications – launch with: open ~/Applications/WallpaperLauncher.app"
fi
