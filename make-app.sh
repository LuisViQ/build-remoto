#!/usr/bin/env bash
# Compila e instala o "Build Remoto.app" em ~/Applications
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="$HOME/Applications/Build Remoto.app"
TMP=$(mktemp -d)
swift make-icon.swift "$TMP/icon.png"
mkdir -p "$TMP/icon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$TMP/icon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$TMP/icon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
iconutil -c icns "$TMP/icon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/BuildRemoto "$APP/Contents/MacOS/BuildRemoto"
cp Resources/realm-motor.cjs "$APP/Contents/Resources/realm-motor.cjs"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Build Remoto</string>
  <key>CFBundleDisplayName</key><string>Build Remoto</string>
  <key>CFBundleIdentifier</key><string>dev.buildremoto.app</string>
  <key>CFBundleExecutable</key><string>BuildRemoto</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP"
rm -rf "$TMP"
echo "✓ Instalado em $APP"
