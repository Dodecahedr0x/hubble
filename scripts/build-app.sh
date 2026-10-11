#!/bin/zsh
# Builds a release Hubble.app in ./build
set -euo pipefail
cd "$(dirname "$0")/.."

# Universal binary (Apple silicon + Intel).
ARCHS=(--arch arm64 --arch x86_64)
VERSION="${VERSION:-1.0}"
swift build -c release "${ARCHS[@]}"
APP=build/Hubble.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release "${ARCHS[@]}" --show-bin-path)/Hubble" "$APP/Contents/MacOS/Hubble"

ICONSET=build/AppIcon.iconset
if [[ ! -f build/AppIcon.icns ]]; then
  mkdir -p "$ICONSET"
  swift scripts/make-icon.swift build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Hubble</string>
  <key>CFBundleDisplayName</key><string>Hubble</string>
  <key>CFBundleIdentifier</key><string>app.hubble.diskscope</string>
  <key>CFBundleExecutable</key><string>Hubble</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key><string>Hubble measures folder sizes to find what fills your disk.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Hubble measures folder sizes to find what fills your disk.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Hubble measures folder sizes to find what fills your disk.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Hubble measures folder sizes to find what fills your disk.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>Hubble measures folder sizes to find what fills your disk.</string>
</dict></plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
