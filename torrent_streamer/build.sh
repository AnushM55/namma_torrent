#!/bin/bash

echo "Building Torrent Streamer application..."

# Build Go shared library
echo "Building Go shared library..."
cd go/torrentstreamer
chmod +x build.sh
./build.sh
cd ../..

# Get Flutter dependencies
echo "Getting Flutter dependencies..."
flutter pub get

# Build Android APK
echo "Building Android APK..."
flutter build apk --release --target-platform android-arm64

echo "Build completed! APK is available at: build/app/outputs/flutter-apk/app-release.apk" 