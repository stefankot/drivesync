#!/bin/bash
# Buduje DriveSync.app (aplikacja paska menu). Użycie: ./make-app.sh [katalog-wyjściowy]
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-build}"
APP="$OUT/DriveSync.app"

swift build -c release 2>&1 | tail -1
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/drivesync "$APP/Contents/MacOS/drivesync"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>pl.drivesync.app</string>
  <key>CFBundleName</key><string>DriveSync</string>
  <key>CFBundleDisplayName</key><string>DriveSync</string>
  <key>CFBundleExecutable</key><string>drivesync</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key><string>DriveSync kopiuje Twoje Biurko na Dysk Google.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>DriveSync kopiuje Twoje Dokumenty na Dysk Google.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>DriveSync kopiuje Twoje Pobrane na Dysk Google.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" 2>/dev/null
echo "$APP"
