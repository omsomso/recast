#!/bin/sh
# Builds Recast.app into build/. Uses Xcode's toolchain when Xcode is installed (the Command Line Tools don't
# include the macOS 26 SDK that SwiftUI's Liquid Glass needs).
set -eu
cd "$(dirname "$0")"
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun swift build -c release --product Recast
bin="$(xcrun swift build -c release --show-bin-path)/Recast"
app="build/Recast.app"
version="$(cat VERSION)"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Recast"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"; fi
cp Sources/CLame/COPYING "$app/Contents/Resources/LAME-COPYING.txt"
cp "Sources/COggVorbis/libvorbis-1.3.7/COPYING" "$app/Contents/Resources/libvorbis-COPYING.txt"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Recast</string>
  <key>CFBundleDisplayName</key><string>Recast</string>
  <key>CFBundleIdentifier</key><string>local.recast.app</string>
  <key>CFBundleExecutable</key><string>Recast</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Recast by omso. GNU GPL v3 or later. MP3 encoding: LAME 3.100 (LGPL). Ogg Vorbis: libvorbis 1.3.7 (BSD).</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Audio</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.audio</string><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
# Ad-hoc signature: enough for a local app; not for distribution.
codesign --force --sign - "$app"
echo "Built $(pwd)/$app"
