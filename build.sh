#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build Payload *.tipa
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
APP=build/PhoneAgent.app
EXT=$APP/PlugIns/PhoneAgentBroadcast.appex
mkdir -p "$EXT"

# 主 App
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=15.0 \
  -fobjc-arc -O1 -Wall -Wno-deprecated-declarations -Isrc \
  -framework UIKit -framework Foundation -framework CoreGraphics \
  -framework Vision -framework AVFoundation -framework CoreVideo -framework ReplayKit \
  -framework AudioToolbox -framework UserNotifications -framework Speech -framework PhotosUI -framework PDFKit -framework UniformTypeIdentifiers -framework ImageIO -framework CoreImage \
  -o "$APP/PhoneAgent" src/main.m
cp Info.plist "$APP/Info.plist"
cp AppIcon60x60@2x.png AppIcon60x60@3x.png AppIcon1024x1024.png "$APP/"

# 广播扩展(入口必须是 NSExtensionMain)
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=15.0 \
  -fobjc-arc -O1 -Wall -fapplication-extension -Isrc \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -framework Foundation -framework ReplayKit -framework CoreMedia \
  -framework CoreImage -framework CoreVideo -framework ImageIO -framework CoreGraphics \
  -o "$EXT/PhoneAgentBroadcast" src/ext.m
cp ext-Info.plist "$EXT/Info.plist"

ldid -Sentitlements-ext.plist "$EXT/PhoneAgentBroadcast"
ldid -Sentitlements.plist "$APP/PhoneAgent"

mkdir Payload
cp -R "$APP" Payload/
zip -qr PhoneAgent.tipa Payload
ls -l PhoneAgent.tipa
