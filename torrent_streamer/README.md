# Torrent Streamer

A Flutter application for streaming torrents on Android devices. This app uses Golang via Foreign Function Interface (FFI) to handle torrent downloads and streaming.

## Features

- Stream torrents directly from magnet links
- Open streams in external video players
- Local processing (no client-server setup required)

## Requirements

- Flutter SDK
- Go 1.16+
- Android NDK
- Android SDK

## Build Instructions

### 1. Set up Flutter

Make sure you have Flutter installed and set up for Android development.

```
flutter doctor
```

### 2. Build the Go shared library

Navigate to the Go code directory and build the shared library:

```
cd go/torrentstreamer
chmod +x build.sh
./build.sh
```

This will compile the Go code into a shared library and place it in the appropriate Android directory.

### 3. Build the Flutter application

From the root directory:

```
flutter pub get
flutter build apk --release
```

This will create a release APK targeting arm64 devices.

## Architecture

- **Flutter UI**: Provides the user interface for entering magnet links and showing streaming info
- **Go Backend**: Handles torrent downloading and streaming via FFI
- **Local HTTP Server**: Created inside the app to serve the video stream

## Libraries Used

- Flutter: UI framework
- flutter_ffi: For communicating with Go code
- anacrolix/torrent: Go library for handling torrents
- url_launcher: For opening streams in external video players
- permission_handler: For managing Android permissions

## Notes

- This app requires storage and internet permissions to function properly
- Designed for ARM64 Android devices
- Performance may vary depending on your network connection and the size of the torrent
