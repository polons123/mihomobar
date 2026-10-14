#!/bin/bash
set -e
cd "$(dirname "$0")"
APP=MihomoBar.app
rm -rf $APP; mkdir -p $APP/Contents/MacOS
# универсальный бинарь (Apple Silicon + Intel), минимум macOS 14
for A in arm64 x86_64; do swiftc -O -target $A-apple-macos14.0 -o /tmp/MihomoBar-$A MihomoBar.swift; done
lipo -create /tmp/MihomoBar-arm64 /tmp/MihomoBar-x86_64 -output $APP/Contents/MacOS/MihomoBar
rm -f /tmp/MihomoBar-arm64 /tmp/MihomoBar-x86_64
mkdir -p $APP/Contents/Resources
cp install.sh mihomo-ctl AppIcon.icns $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>MihomoBar</string>
<key>CFBundleIdentifier</key><string>local.mihomobar</string>
<key>CFBundleExecutable</key><string>MihomoBar</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
P
codesign --force --sign - $APP
echo built $APP

# DMG: приложение + ярлык «Программы» (./build.sh dmg)
if [ "${1:-}" = dmg ]; then
  rm -rf dmg-root MihomoBar.dmg; mkdir dmg-root
  cp -R $APP dmg-root/; ln -s /Applications dmg-root/Applications
  hdiutil create -quiet -volname MihomoBar -srcfolder dmg-root -ov -format UDZO MihomoBar.dmg
  rm -rf dmg-root; echo built MihomoBar.dmg
fi
