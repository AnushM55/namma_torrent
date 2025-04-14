#!/bin/bash

echo "Setting up debug environment for Torrent Streamer..."

# Check for ANDROID_NDK_HOME
if [ -z "$ANDROID_NDK_HOME" ]; then
    echo "ANDROID_NDK_HOME is not set. Attempting to find NDK..."
    
    # Look for NDK in common locations
    POSSIBLE_NDK_PATHS=(
        "$HOME/Android/Sdk/ndk/25.2.9519653" 
        "$HOME/Android/Sdk/ndk-bundle"
        "$HOME/Android/Sdk/ndk/21.4.7075529"
        "$HOME/Android/Sdk/ndk/22.1.7171670"
        "$HOME/Android/Sdk/ndk/23.1.7779620"
        "$HOME/Android/Sdk/ndk/24.0.8215888"
        "$HOME/Android/Sdk/ndk/25.0.8775105"
        "$ANDROID_HOME/ndk-bundle"
        "$ANDROID_HOME/ndk/21.4.7075529"
        "$ANDROID_HOME/ndk/22.1.7171670" 
        "$ANDROID_HOME/ndk/23.1.7779620"
        "$ANDROID_HOME/ndk/24.0.8215888"
        "$ANDROID_HOME/ndk/25.0.8775105"
    )
    
    for NDK_PATH in "${POSSIBLE_NDK_PATHS[@]}"
    do
        if [ -d "$NDK_PATH" ]; then
            export ANDROID_NDK_HOME="$NDK_PATH"
            echo "Found NDK at $ANDROID_NDK_HOME"
            break
        fi
    done
    
    if [ -z "$ANDROID_NDK_HOME" ]; then
        echo "WARNING: Android NDK not found automatically."
        echo "Please set ANDROID_NDK_HOME manually if build fails."
    else
        echo "Exporting ANDROID_NDK_HOME=$ANDROID_NDK_HOME"
    fi
fi

# Add extra debug option to find library issues
export FLUTTER_EXTRA_ARGS="--verbose"

# Build Go shared library with debug flags
echo "Building Go shared library for debugging..."
cd go/torrentstreamer
chmod +x build.sh
./build.sh
cd ../..

# Manually copy the library to more locations where Flutter might look for it
echo "Copying library to multiple locations..."
mkdir -p android/app/build/intermediates/cmake/debug/obj/arm64-v8a/
cp android/app/src/main/jniLibs/arm64-v8a/libtorrentstreamer.so android/app/build/intermediates/cmake/debug/obj/arm64-v8a/

# Check if library was built
if [ ! -f "android/app/src/main/jniLibs/arm64-v8a/libtorrentstreamer.so" ]; then
    echo "ERROR: Failed to build libtorrentstreamer.so"
    exit 1
fi

# Install Flutter dependencies
echo "Getting Flutter dependencies..."
flutter pub get

# Run in debug mode with special debug mode for FFI
echo "Starting app in debug mode..."
flutter run --debug

echo "Debug session ended" 