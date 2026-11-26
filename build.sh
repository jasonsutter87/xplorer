#!/bin/zsh
# Builds Xplorer.app and (with --install) copies it to ~/Applications.
set -e
cd "$(dirname "$0")"
APP=build/Xplorer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -target arm64-apple-macos13.0 Sources/*.swift -o "$APP/Contents/MacOS/Xplorer"
[ -f build/AppIcon.icns ] || swift scripts/make_icon.swift build/AppIcon.iconset >/dev/null && iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Xplorer</string>
  <key>CFBundleDisplayName</key><string>Xplorer</string>
  <key>CFBundleIdentifier</key><string>local.xplorer</string>
  <key>CFBundleExecutable</key><string>Xplorer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>Folder</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Default</string>
    <key>LSItemContentTypes</key><array><string>public.folder</string><string>public.volume</string></array>
  </dict></array>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP"
echo "Built $APP"
if [[ "$1" == "--install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/Xplorer.app
  cp -R "$APP" ~/Applications/
  echo "Installed to ~/Applications/Xplorer.app"
fi
