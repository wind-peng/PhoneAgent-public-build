#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build Payload PhoneAgent.tipa
APP=build/PhoneAgent.app
mkdir -p "$APP"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=15.0 \
  -fobjc-arc -O1 -Wall -Wno-deprecated-declarations \
  -framework UIKit -framework Foundation -framework CoreGraphics -framework Vision -framework AVFoundation -framework CoreVideo \
  -o "$APP/PhoneAgent" src/main.m
cp Info.plist "$APP/Info.plist"
ldid -Sentitlements.plist "$APP/PhoneAgent"
mkdir Payload
cp -R "$APP" Payload/
zip -qr PhoneAgent.tipa Payload
ls -l PhoneAgent.tipa
