#!/bin/bash
# Build chiaki-lib + deps for iOS arm64 and package as ChiakiLib.xcframework.
# Requires macOS with Xcode, cmake, ninja and python3 with protobuf.

set -xe

BUILD_DIR="${BUILD_DIR:-build-ios}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-15.0}"

cmake -S . -B "$BUILD_DIR" -G Ninja \
	-DCMAKE_SYSTEM_NAME=iOS \
	-DCMAKE_OSX_ARCHITECTURES=arm64 \
	-DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCHIAKI_ENABLE_TESTS=OFF \
	-DCHIAKI_ENABLE_CLI=OFF \
	-DCHIAKI_ENABLE_GUI=OFF \
	-DCHIAKI_ENABLE_SETSU=OFF \
	-DCHIAKI_ENABLE_FFMPEG_DECODER=OFF \
	-DCHIAKI_ENABLE_PI_DECODER=OFF \
	-DCHIAKI_ENABLE_SPEEX=OFF \
	-DCHIAKI_LIB_ENABLE_OPUS=OFF \
	-DCHIAKI_LIB_OPENSSL_EXTERNAL_PROJECT=ON \
	-DCHIAKI_LIB_JSONC_EXTERNAL_PROJECT=ON \
	-DCHIAKI_LIB_MINIUPNPC_EXTERNAL_PROJECT=ON \
	-DCHIAKI_ENABLE_STEAM_SHORTCUT=OFF \
	-DCHIAKI_ENABLE_STEAMDECK_NATIVE=OFF

cmake --build "$BUILD_DIR" --target chiaki-lib

# Merge chiaki and all its static deps into one archive
OUT="$BUILD_DIR/ios-out"
rm -rf "$OUT" && mkdir -p "$OUT/include"
# skip OpenSSL's build tree, its installed copies are used instead
LIBS=$(find "$BUILD_DIR" -name '*.a' -not -path "$OUT/*" -not -path '*/OpenSSL-ExternalProject-prefix/*')
echo "$LIBS"
libtool -static -o "$OUT/libchiaki.a" $LIBS
cp -R lib/include/chiaki "$OUT/include/"
cp "$BUILD_DIR/lib/include/chiaki/config.h" "$OUT/include/chiaki/"

rm -rf "$BUILD_DIR/ChiakiLib.xcframework"
xcodebuild -create-xcframework -library "$OUT/libchiaki.a" -headers "$OUT/include" -output "$BUILD_DIR/ChiakiLib.xcframework"
