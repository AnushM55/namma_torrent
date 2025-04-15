import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';

// Function type definitions for FFI
typedef InitTorrentClientFunc = Pointer<Utf8> Function(
    Pointer<Utf8> cacheDir, Pointer<Utf8> downloadDir);
typedef InitTorrentClientDart = Pointer<Utf8> Function(
    Pointer<Utf8> cacheDir, Pointer<Utf8> downloadDir);

typedef ShutdownTorrentClientFunc = Pointer<Utf8> Function();
typedef ShutdownTorrentClientDart = Pointer<Utf8> Function();

typedef AddTorrentAndGetInfoHashFunc = Pointer<Utf8> Function(Pointer<Utf8> magnetURI);
typedef AddTorrentAndGetInfoHashDart = Pointer<Utf8> Function(Pointer<Utf8> magnetURI);

typedef GetStreamURLFunc = Pointer<Utf8> Function(
    Pointer<Utf8> infoHash, Pointer<Utf8> fileIndex);
typedef GetStreamURLDart = Pointer<Utf8> Function(
    Pointer<Utf8> infoHash, Pointer<Utf8> fileIndex);

typedef ListTorrentFilesFunc = Pointer<Utf8> Function(Pointer<Utf8> infoHash);
typedef ListTorrentFilesDart = Pointer<Utf8> Function(Pointer<Utf8> infoHash);

typedef DownloadTorrentFileFunc = Pointer<Utf8> Function(
    Pointer<Utf8> infoHash, Pointer<Utf8> fileIndex);
typedef DownloadTorrentFileDart = Pointer<Utf8> Function(
    Pointer<Utf8> infoHash, Pointer<Utf8> fileIndex);

typedef GetDownloadProgressFunc = Pointer<Utf8> Function(
    Pointer<Utf8> infoHash, Pointer<Utf8> fileIndex);
typedef GetDownloadProgressDart = Pointer<Utf8> Function(
    Pointer<Utf8> infoHash, Pointer<Utf8> fileIndex);

class TorrentFFI {
  static late DynamicLibrary _lib;
  static late InitTorrentClientDart _initTorrentClient;
  static late ShutdownTorrentClientDart _shutdownTorrentClient;
  static late AddTorrentAndGetInfoHashDart _addTorrentAndGetInfoHash;
  static late GetStreamURLDart _getStreamURL;
  static late ListTorrentFilesDart _listTorrentFiles;
  static late DownloadTorrentFileDart _downloadTorrentFile;
  static late GetDownloadProgressDart _getDownloadProgress;

  static Future<String> initialize({String? customDownloadDir}) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final cachePath = (await getTemporaryDirectory()).path;

      // Load the shared library
      _lib = Platform.isAndroid
          ? DynamicLibrary.open("libtorrentstreamer.so")
          : DynamicLibrary.process();

      // Get function pointers
      _initTorrentClient = _lib
          .lookupFunction<InitTorrentClientFunc, InitTorrentClientDart>(
              'InitTorrentClient');
      _shutdownTorrentClient = _lib.lookupFunction<
          ShutdownTorrentClientFunc,
          ShutdownTorrentClientDart>('ShutdownTorrentClient');
      _addTorrentAndGetInfoHash = _lib.lookupFunction<
          AddTorrentAndGetInfoHashFunc,
          AddTorrentAndGetInfoHashDart>('AddTorrentAndGetInfoHash');
      _getStreamURL = _lib.lookupFunction<GetStreamURLFunc, GetStreamURLDart>(
          'GetStreamURL');
      _listTorrentFiles = _lib.lookupFunction<ListTorrentFilesFunc,
          ListTorrentFilesDart>('ListTorrentFiles');
      _downloadTorrentFile = _lib.lookupFunction<DownloadTorrentFileFunc,
          DownloadTorrentFileDart>('DownloadTorrentFile');
      _getDownloadProgress = _lib.lookupFunction<GetDownloadProgressFunc,
          GetDownloadProgressDart>('GetDownloadProgress');

      // Initialize the torrent client
      final cacheDir = cachePath.toNativeUtf8();
      final downloadDir = (customDownloadDir ?? '').toNativeUtf8();
      final result = _initTorrentClient(cacheDir, downloadDir);
      final resultString = result.toDartString();

      // Free allocated memory
      calloc.free(cacheDir);
      calloc.free(downloadDir);
      calloc.free(result);

      return resultString;
    } catch (e) {
      return "Error initializing torrent FFI: $e";
    }
  }

  static String shutdown() {
    try {
      final result = _shutdownTorrentClient();
      final resultString = result.toDartString();
      calloc.free(result);
      return resultString;
    } catch (e) {
      return "Error shutting down torrent client: $e";
    }
  }

  static Future<String> addTorrentAndGetInfoHash(String magnetUri) async {
    try {
      final magnetUtf8 = magnetUri.toNativeUtf8();
      final result = _addTorrentAndGetInfoHash(magnetUtf8);
      final resultString = result.toDartString();

      // Free allocated memory
      calloc.free(magnetUtf8);
      calloc.free(result);

      return resultString;
    } catch (e) {
      return "Error adding torrent: $e";
    }
  }

  static Future<String> getStreamURL(String infoHash, String fileIndex) async {
    try {
      final infoHashUtf8 = infoHash.toNativeUtf8();
      final fileIndexUtf8 = fileIndex.toNativeUtf8();
      final result = _getStreamURL(infoHashUtf8, fileIndexUtf8);
      final resultString = result.toDartString();

      // Free allocated memory
      calloc.free(infoHashUtf8);
      calloc.free(fileIndexUtf8);
      calloc.free(result);

      return resultString;
    } catch (e) {
      return "Error getting stream URL: $e";
    }
  }

  static Future<String> listTorrentFiles(String infoHash) async {
    try {
      final infoHashUtf8 = infoHash.toNativeUtf8();
      final result = _listTorrentFiles(infoHashUtf8);
      final resultString = result.toDartString();

      // Free allocated memory
      calloc.free(infoHashUtf8);
      calloc.free(result);

      return resultString;
    } catch (e) {
      return "Error listing torrent files: $e";
    }
  }

  static Future<String> downloadTorrentFile(
      String infoHash, String fileIndex) async {
    try {
      final infoHashUtf8 = infoHash.toNativeUtf8();
      final fileIndexUtf8 = fileIndex.toNativeUtf8();
      final result = _downloadTorrentFile(infoHashUtf8, fileIndexUtf8);
      final resultString = result.toDartString();

      // Free allocated memory
      calloc.free(infoHashUtf8);
      calloc.free(fileIndexUtf8);
      calloc.free(result);

      return resultString;
    } catch (e) {
      return "Error downloading torrent file: $e";
    }
  }

  static Future<String> getDownloadProgress(
      String infoHash, String fileIndex) async {
    try {
      final infoHashUtf8 = infoHash.toNativeUtf8();
      final fileIndexUtf8 = fileIndex.toNativeUtf8();
      final result = _getDownloadProgress(infoHashUtf8, fileIndexUtf8);
      final resultString = result.toDartString();

      // Free allocated memory
      calloc.free(infoHashUtf8);
      calloc.free(fileIndexUtf8);
      calloc.free(result);

      return resultString;
    } catch (e) {
      return "Error getting download progress: $e";
    }
  }
} 