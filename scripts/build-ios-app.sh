#!/bin/bash
# Build the unsigned iOS app (ChiakiApp.ipa) on top of scripts/build-ios.sh output.
# Requires macOS with Xcode and xcodegen. Sign/sideload with AltStore or SideStore.

set -xe

cd "$(dirname "${BASH_SOURCE[0]}")/../ios"
xcodegen generate
xcodebuild -project ChiakiApp.xcodeproj -scheme ChiakiApp -configuration Release \
	-sdk iphoneos -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

rm -rf Payload ChiakiApp.ipa
mkdir Payload
cp -R build/Build/Products/Release-iphoneos/ChiakiApp.app Payload/
zip -qry ChiakiApp.ipa Payload
