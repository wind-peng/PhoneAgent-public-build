#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build Payload *.tipa
SDK=$(xcrun --sdk iphoneos --show-sdk-path)

build_variant() {
  local out=$1 ent=$2 bid=$3 name=$4 port=$5
  local app="build/$out/PhoneAgent.app"
  mkdir -p "$app"
  xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=15.0 \
    -fobjc-arc -O1 -Wall -Wno-deprecated-declarations -DPORT=$port \
    -framework UIKit -framework Foundation -framework CoreGraphics \
    -framework Vision -framework AVFoundation -framework CoreVideo \
    -o "$app/PhoneAgent" src/main.m
  cp Info.plist "$app/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bid" "$app/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $name" "$app/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $name" "$app/Info.plist"
  ldid -S"$ent" "$app/PhoneAgent"
  rm -rf Payload && mkdir Payload
  cp -R "$app" Payload/
  zip -qr "$out.tipa" Payload
  rm -rf Payload
}

# 变体一:完整权限(去沙盒)。变体二:保留沙盒,用来对比 IOSurface 能不能用。
build_variant PhoneAgent    entitlements.plist    com.example.phoneagent    PhoneAgent 8200
build_variant PhoneAgent-SB entitlements-sb.plist com.example.phoneagent.sb PA-SB      8201
ls -l *.tipa
