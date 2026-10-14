#!/bin/bash
set -e
cd "$(dirname "$0")"
APP=MihomoBar.app
rm -rf $APP; mkdir -p $APP/Contents/MacOS
swiftc -O -o $APP/Contents/MacOS/MihomoBar MihomoBar.swift
cat > $APP/Contents/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>MihomoBar</string>
<key>CFBundleIdentifier</key><string>local.mihomobar</string>
<key>CFBundleExecutable</key><string>MihomoBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
</dict></plist>
P
codesign --force --sign - $APP
echo built $APP
