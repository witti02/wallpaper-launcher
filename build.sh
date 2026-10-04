#!/bin/zsh
# Builds WallpaperLauncher.app.
#   --install  also copies the app to ~/Applications
#   --release  builds a universal binary and zips it to build/WallpaperLauncher-<version>.zip
set -e
cd "$(dirname "$0")"
APP=build/WallpaperLauncher.app
VERSION=1.1.0
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN="$APP/Contents/MacOS/WallpaperLauncher"
if [[ "$1" == "--release" ]]; then
  # Universal binary (Apple silicon + Intel) for distribution.
  for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target $arch-apple-macos14 -o "build/WallpaperLauncher-$arch" Sources/*.swift 2>&1 | grep -v "warning:" || true
    [[ -x "build/WallpaperLauncher-$arch" ]] || { echo "Build failed ($arch)"; exit 1; }
  done
  lipo -create build/WallpaperLauncher-arm64 build/WallpaperLauncher-x86_64 -output "$BIN"
  rm build/WallpaperLauncher-arm64 build/WallpaperLauncher-x86_64
else
  swiftc -O -swift-version 5 -o "$BIN" Sources/*.swift 2>&1 | grep -v "warning:" || true
fi
[[ -x "$BIN" ]] || { echo "Build failed"; exit 1; }
# App icon: Resources/AppIcon.png (regenerate with: swift Scripts/make-icon.swift Resources/AppIcon.png)
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>WallpaperLauncher</string>
  <key>CFBundleDisplayName</key><string>Wallpaper Launcher</string>
  <key>CFBundleIdentifier</key><string>local.wallpaperlauncher</string>
  <key>CFBundleExecutable</key><string>WallpaperLauncher</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
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
  touch ~/Applications/WallpaperLauncher.app  # refresh Finder's icon cache
  echo "✓ installed to ~/Applications – launch with: open ~/Applications/WallpaperLauncher.app"
fi
if [[ "$1" == "--release" ]]; then
  ZIP="build/WallpaperLauncher-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP" "$ZIP"
  echo "✓ $ZIP ($(lipo -archs "$BIN"))"
fi
