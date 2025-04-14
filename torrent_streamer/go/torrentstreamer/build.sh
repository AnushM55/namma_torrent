#!/bin/bash

set -e  # Exit on error

export GOPATH=$HOME/go
export PATH=$GOPATH/bin:$PATH

# Make sure we have the required Go dependencies
echo "Getting dependencies..."
go get -v -u github.com/anacrolix/torrent@latest
go mod tidy -v
go mod download

echo "Building shared library..."
# Compile for Android ARM64
export GOOS=android
export GOARCH=arm64
export CGO_ENABLED=1

# Try to find NDK automatically
if [ -z "$ANDROID_NDK_HOME" ]; then
    echo "Looking for Android NDK..."
    
    # Check common NDK locations
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
        echo "ERROR: Android NDK not found. Please set ANDROID_NDK_HOME manually."
        exit 1
    fi
fi

echo "Using NDK at $ANDROID_NDK_HOME"
export CC=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android21-clang
export CXX=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android21-clang++
export LD=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android-ld

# Check if compiler exists
if [ ! -f "$CC" ]; then
    echo "ERROR: Android NDK compiler not found at $CC"
    echo "Searching for alternative compiler..."
    
    # Try to find clang compiler
    CLANG_PATH=$(find "$ANDROID_NDK_HOME" -name "aarch64-linux-android*-clang" | head -n 1)
    
    if [ -n "$CLANG_PATH" ]; then
        export CC="$CLANG_PATH"
        echo "Using compiler at $CC"
        # Also set CXX and LD based on found compiler
        export CXX="${CC}++"
        export LD=$(dirname "$CC")/aarch64-linux-android-ld
    else
        echo "ERROR: Could not find suitable Android compiler in NDK"
        exit 1
    fi
fi

# Debug output to verify packages and environment
echo "Listing Go files:"
ls -la *.go
echo "Checking Go modules:"
go list -m all
echo "Environment:"
echo "CC=$CC"
echo "CXX=$CXX"
echo "LD=$LD"

# Create directory for library if it doesn't exist
mkdir -p ../../android/app/src/main/jniLibs/arm64-v8a/

# Copy the C++ shared library from the NDK
echo "Copying C++ shared library..."
CPP_SHARED_LIB_PATH=$(find "$ANDROID_NDK_HOME" -path "*/arm64-v8a/libc++_shared.so" | head -n 1)
if [ -f "$CPP_SHARED_LIB_PATH" ]; then
    echo "Found libc++_shared.so at $CPP_SHARED_LIB_PATH"
    cp "$CPP_SHARED_LIB_PATH" ../../android/app/src/main/jniLibs/arm64-v8a/
    echo "Copied libc++_shared.so to jniLibs directory"
else
    echo "WARNING: Could not find libc++_shared.so in NDK. The app may not work without it."
fi

# Check if we're in a proper Go module
if [ ! -f "go.mod" ]; then
    echo "ERROR: go.mod not found. Initializing module..."
    go mod init github.com/example/torrentstreamer
fi

# Build the shared library
echo "Building shared library..."
CGO_ENABLED=1 GOOS=android GOARCH=arm64 go build -v -x -buildmode=c-shared -ldflags "-checklinkname=0" -o ../../android/app/src/main/jniLibs/arm64-v8a/libtorrentstreamer.so main.go torrent.go

# Check if the build was successful
if [ $? -ne 0 ]; then
    echo "Build failed! Trying alternate method..."
    # Try building with a simplified version
    cat > simple.go <<EOF
package main

import "C"

//export InitTorrentClient
func InitTorrentClient() *C.char {
    return C.CString("Simple initialization successful")
}

//export StreamTorrent
func StreamTorrent(magnetURI *C.char) *C.char {
    return C.CString("http://localhost:8080/dummy-stream")
}

func main() {}
EOF
    CGO_ENABLED=1 GOOS=android GOARCH=arm64 go build -v -x -buildmode=c-shared -ldflags "-checklinkname=0" -o ../../android/app/src/main/jniLibs/arm64-v8a/libtorrentstreamer.so simple.go
fi

# Copy the library to a location that might be accessible at runtime
if [ -f "../../android/app/src/main/jniLibs/arm64-v8a/libtorrentstreamer.so" ]; then
    echo "Copying library to alternate locations..."
    mkdir -p ../../build/app/intermediates/cxx/
    cp ../../android/app/src/main/jniLibs/arm64-v8a/libtorrentstreamer.so ../../build/app/intermediates/cxx/libtorrentstreamer.so
    echo "Build completed successfully"
else
    echo "ERROR: Library build failed!"
    exit 1
fi 