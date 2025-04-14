import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';

// Function typedefs for FFI - moved to top level
typedef InitTorrentClientFunc = Pointer<Utf8> Function(Pointer<Utf8> cacheDir, Pointer<Utf8> customDownloadDir);
typedef InitTorrentClientDart = Pointer<Utf8> Function(Pointer<Utf8> cacheDir, Pointer<Utf8> customDownloadDir);

typedef ShutdownTorrentClientFunc = Pointer<Utf8> Function();
typedef ShutdownTorrentClientDart = Pointer<Utf8> Function();

// Rename StreamTorrent to AddTorrentAndGetInfoHash
typedef AddTorrentAndGetInfoHashFunc = Pointer<Utf8> Function(Pointer<Utf8>);
typedef AddTorrentAndGetInfoHashDart = Pointer<Utf8> Function(Pointer<Utf8>);

typedef ListTorrentFilesFunc = Pointer<Utf8> Function(Pointer<Utf8>);
typedef ListTorrentFilesDart = Pointer<Utf8> Function(Pointer<Utf8>);

typedef DownloadTorrentFileFunc = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef DownloadTorrentFileDart = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);

typedef GetDownloadProgressFunc = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef GetDownloadProgressDart = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);

class TorrentFFI {
  static late DynamicLibrary _dylib;
  static bool _initialized = false;

  // Function pointers
  static late InitTorrentClientDart _initTorrentClient;
  static late ShutdownTorrentClientDart _shutdownTorrentClient;
  static late AddTorrentAndGetInfoHashDart _addTorrentAndGetInfoHash; // Renamed
  static late ListTorrentFilesDart _listTorrentFiles;
  static late DownloadTorrentFileDart _downloadTorrentFile;
  static late GetDownloadProgressDart _getDownloadProgress;

  // Initialize the FFI
  static Future<String> initialize({String? customDownloadDirectory}) async {
    if (_initialized) {
      return "FFI already initialized";
    }

    try {
      // Load the dynamic library
      if (Platform.isAndroid) {
        // Try several possible locations for the library
        List<String> possiblePaths = [
          "libtorrentstreamer.so",
          "/data/data/com.github.torrent_streamer/lib/libtorrentstreamer.so",
          "/data/app/com.github.torrent_streamer/lib/arm64-v8a/libtorrentstreamer.so",
        ];
        
        DynamicLibrary? lib;
        String error = "";
        
        for (final path in possiblePaths) {
          try {
            lib = DynamicLibrary.open(path);
            if (lib != null) {
              _dylib = lib;
              break;
            }
          } catch (e) {
            error += "Failed to load from $path: $e\n";
          }
        }
        
        if (lib == null) {
          return "Failed to load libtorrentstreamer.so from any location. Errors: $error";
        }
      } else {
        // For debugging on other platforms
        final appDir = await getApplicationDocumentsDirectory();
        final libPath = '${appDir.path}/libtorrentstreamer.so';
        _dylib = DynamicLibrary.open(libPath);
      }

      // Get function pointers
      _initTorrentClient = _dylib
          .lookup<NativeFunction<InitTorrentClientFunc>>('InitTorrentClient')
          .asFunction();

      _shutdownTorrentClient = _dylib
          .lookup<NativeFunction<ShutdownTorrentClientFunc>>('ShutdownTorrentClient')
          .asFunction();

      // Use the new function name
      _addTorrentAndGetInfoHash = _dylib
          .lookup<NativeFunction<AddTorrentAndGetInfoHashFunc>>('AddTorrentAndGetInfoHash')
          .asFunction();
          
      _listTorrentFiles = _dylib
          .lookup<NativeFunction<ListTorrentFilesFunc>>('ListTorrentFiles')
          .asFunction();
          
      _downloadTorrentFile = _dylib
          .lookup<NativeFunction<DownloadTorrentFileFunc>>('DownloadTorrentFile')
          .asFunction();
          
      _getDownloadProgress = _dylib
          .lookup<NativeFunction<GetDownloadProgressFunc>>('GetDownloadProgress')
          .asFunction();

      _initialized = true;

      // Get the app's cache directory
      final cacheDir = await getTemporaryDirectory();
      final cacheDirUtf8 = cacheDir.path.toNativeUtf8();
      
      // Prepare the custom download directory pointer
      Pointer<Utf8> customDirUtf8;
      if (customDownloadDirectory != null && customDownloadDirectory.isNotEmpty) {
        customDirUtf8 = customDownloadDirectory.toNativeUtf8();
      } else {
        customDirUtf8 = "".toNativeUtf8();
      }

      // Initialize the torrent client with the cache directory and custom download directory
      final result = _initTorrentClient(cacheDirUtf8, customDirUtf8);
      String resultString = result.toDartString();
      
      // Free the allocated memory
      calloc.free(cacheDirUtf8);
      calloc.free(customDirUtf8);
      calloc.free(result);
      
      return resultString;
    } catch (e) {
      return "Error initializing FFI: $e";
    }
  }

  // Shutdown the torrent client
  static String shutdown() {
    if (!_initialized) {
      return "FFI not initialized";
    }

    try {
      final result = _shutdownTorrentClient();
      String resultString = result.toDartString();
      calloc.free(result);
      return resultString;
    } catch (e) {
      return "Error shutting down torrent client: $e";
    }
  }

  // Add a torrent and get its info hash
  static String addTorrentAndGetInfoHash(String magnetURI) {
    if (!_initialized) {
      return "FFI not initialized";
    }

    try {
      final magnetURIUtf8 = magnetURI.toNativeUtf8();
      final result = _addTorrentAndGetInfoHash(magnetURIUtf8); // Use renamed function
      String resultString = result.toDartString();
      
      // Free the allocated memory
      calloc.free(magnetURIUtf8);
      calloc.free(result);
      
      // Result is now the info hash or an error message
      return resultString;
    } catch (e) {
      return "Error adding torrent: $e";
    }
  }
  
  // List files in a torrent
  static String listTorrentFiles(String infoHash) {
    if (!_initialized) {
      return "FFI not initialized";
    }

    try {
      final infoHashUtf8 = infoHash.toNativeUtf8();
      final result = _listTorrentFiles(infoHashUtf8);
      String resultString = result.toDartString();
      
      // Free the allocated memory
      calloc.free(infoHashUtf8);
      calloc.free(result);
      
      return resultString;
    } catch (e) {
      return "Error listing torrent files: $e";
    }
  }

  // Download a file from a torrent
  static String downloadTorrentFile(String infoHash, String fileIndex) {
    if (!_initialized) {
      return "FFI not initialized";
    }

    try {
      final infoHashUtf8 = infoHash.toNativeUtf8();
      final fileIndexUtf8 = fileIndex.toNativeUtf8();
      final result = _downloadTorrentFile(infoHashUtf8, fileIndexUtf8);
      String resultString = result.toDartString();
      
      // Free the allocated memory
      calloc.free(infoHashUtf8);
      calloc.free(fileIndexUtf8);
      calloc.free(result);
      
      return resultString;
    } catch (e) {
      return "Error downloading torrent file: $e";
    }
  }
  
  // Get the download progress for a file
  static String getDownloadProgress(String infoHash, String fileIndex) {
    if (!_initialized) {
      return "FFI not initialized";
    }

    try {
      final infoHashUtf8 = infoHash.toNativeUtf8();
      final fileIndexUtf8 = fileIndex.toNativeUtf8();
      final result = _getDownloadProgress(infoHashUtf8, fileIndexUtf8);
      String resultString = result.toDartString();
      
      // Free the allocated memory
      calloc.free(infoHashUtf8);
      calloc.free(fileIndexUtf8);
      calloc.free(result);
      
      return resultString;
    } catch (e) {
      return "Error getting download progress: $e";
    }
  }
} 