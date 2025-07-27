import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'torrent_ffi.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Torrent Streamer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class TorrentFile {
  final String name;
  final String path;
  final int size;
  final int index;
  final String mimeType;

  TorrentFile({
    required this.name,
    required this.path,
    required this.size,
    required this.index,
    required this.mimeType,
  });

  factory TorrentFile.fromJson(Map<String, dynamic> json) {
    return TorrentFile(
      name: json['name'] as String,
      path: json['path'] as String,
      size: json['size'] as int,
      index: json['index'] as int,
      mimeType: json['mimeType'] as String,
    );
  }

  String get formattedSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(2)} KB';
    if (size < 1024 * 1024 * 1024) return '${(size / (1024 * 1024)).toStringAsFixed(2)} MB';
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  bool get isVideo {
    return mimeType.startsWith('video/');
  }

  bool get isAudio {
    return mimeType.startsWith('audio/');
  }

  bool get isImage {
    return mimeType.startsWith('image/');
  }

  IconData get icon {
    if (isVideo) return Icons.video_file;
    if (isAudio) return Icons.audio_file;
    if (isImage) return Icons.image;
    return Icons.insert_drive_file;
  }
}

class HomePage extends StatefulWidget {
  const HomePage({Key? key}) : super(key: key);

  @override
  HomePageState createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  final TextEditingController _magnetController = TextEditingController();
  String _statusMessage = "Enter a magnet link to begin";
  String? _torrentHash;
  List<dynamic> _filesList = [];
  String? _selectedFilePath;
  String? _selectedFileIndex;
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  bool _isInitialized = false;
  bool _isDownloading = false;
  bool _isStreaming = false;
  double _downloadProgress = 0.0;
  Timer? _progressTimer;
  String? _streamUrl;

  @override
  void initState() {
    super.initState();
    _initializeTorrentClient();
  }

  @override
  void dispose() {
    _videoController?.dispose();
    _chewieController?.dispose();
    _progressTimer?.cancel();
    TorrentFFI.shutdown();
    super.dispose();
  }

  Future<void> _initializeTorrentClient() async {
    // Request storage permission
    await _requestPermissions();

    // Initialize the torrent client
    final result = await TorrentFFI.initialize();
    setState(() {
      _statusMessage = "Torrent client initialized: $result";
      _isInitialized = true;
    });
  }

  Future<void> _requestPermissions() async {
    final deviceInfo = DeviceInfoPlugin();
    if (await Permission.storage.request().isGranted) {
      // Storage permission granted
    }

    // For Android 13 and above, request media permissions
    final androidInfo = await deviceInfo.androidInfo;
    if (androidInfo.version.sdkInt >= 33) {
      await Permission.photos.request();
      await Permission.videos.request();
      await Permission.audio.request();
    }
  }

  Future<void> _processMagnetLink() async {
    final magnetLink = _magnetController.text.trim();
    if (magnetLink.isEmpty) {
      setState(() {
        _statusMessage = "Please enter a magnet link";
      });
      return;
    }

    setState(() {
      _statusMessage = "Processing magnet link...";
      _filesList = [];
      _torrentHash = null;
      _selectedFilePath = null;
      _selectedFileIndex = null;
      _downloadProgress = 0.0;
      _isDownloading = false;
      _isStreaming = false;
      _streamUrl = null;
    });

    final result = await TorrentFFI.addTorrentAndGetInfoHash(magnetLink);
    if (result.startsWith("Error")) {
      setState(() {
        _statusMessage = result;
      });
      return;
    }

    setState(() {
      _torrentHash = result;
      _statusMessage = "Torrent added. Fetching file list...";
    });

    _fetchFileList();
  }

  Future<void> _fetchFileList() async {
    if (_torrentHash == null) {
      setState(() {
        _statusMessage = "Error: No torrent hash available";
      });
      return;
    }

    final result = await TorrentFFI.listTorrentFiles(_torrentHash!);
    if (result.startsWith("Error")) {
      setState(() {
        _statusMessage = result;
      });
      return;
    }

    try {
      final files = jsonDecode(result);
      setState(() {
        _filesList = files;
        _statusMessage = "Found ${_filesList.length} files. Select one to stream or download.";
      });
    } catch (e) {
      setState(() {
        _statusMessage = "Error parsing file list: $e";
      });
    }
  }

  Future<void> _selectFileToDownload(int index) async {
    final fileIndex = _filesList[index]['index'].toString();
    setState(() {
      _selectedFileIndex = fileIndex;
      _statusMessage = "Downloading file: ${_filesList[index]['name']}";
      _isDownloading = true;
      _isStreaming = false;
      _downloadProgress = 0.0;
    });

    // Start downloading the file
    final result = await TorrentFFI.downloadTorrentFile(_torrentHash!, fileIndex);
    if (result.startsWith("Error")) {
      setState(() {
        _statusMessage = result;
        _isDownloading = false;
      });
      return;
    }

    setState(() {
      _selectedFilePath = result;
    });

    // Start tracking download progress
    _startProgressTracking();
  }

  Future<void> _selectFileToStream(int index) async {
    final fileIndex = _filesList[index]['index'].toString();
    setState(() {
      _selectedFileIndex = fileIndex;
      _statusMessage = "Preparing to stream: ${_filesList[index]['name']}";
      _isDownloading = false;
      _isStreaming = true;
      _downloadProgress = 0.0;
    });

    // Get the stream URL
    final result = await TorrentFFI.getStreamURL(_torrentHash!, fileIndex);
    if (result.startsWith("Error")) {
      setState(() {
        _statusMessage = result;
        _isStreaming = false;
      });
      return;
    }

    setState(() {
      _streamUrl = result;
      _statusMessage = "Stream ready. Starting player...";
    });

    // Start the video player with the stream URL
    _initializePlayer(_streamUrl!, true);
    
    // Start tracking download progress in the background
    _startProgressTracking();
  }

  void _startProgressTracking() {
    // Cancel any existing timer
    _progressTimer?.cancel();

    // Start a new timer to update progress
    _progressTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (_torrentHash == null || _selectedFileIndex == null) {
        timer.cancel();
        return;
      }

      final progressResult = await TorrentFFI.getDownloadProgress(
          _torrentHash!, _selectedFileIndex!);
      
      if (progressResult.startsWith("Error")) {
        // Error tracking progress: $progressResult
        return;
      }

      try {
        final progress = jsonDecode(progressResult);
        final double progressValue = double.parse(progress["Progress"].toString());
        
        setState(() {
          _downloadProgress = progressValue;
          
          // If download is complete and we have a file path, initialize the player
          if (_downloadProgress >= 1.0 && 
              _selectedFilePath != null && 
              _isDownloading &&
              _videoController == null) {
            _initializePlayer(_selectedFilePath!, false);
            _statusMessage = "Download complete. Playing file...";
          }
        });
        
        // Stop the timer if the download is complete
        if (_downloadProgress >= 1.0 && !_isStreaming) {
          timer.cancel();
        }
      } catch (e) {
        // Error parsing progress: $e
      }
    });
  }

  Future<void> _initializePlayer(String source, bool isStream) async {
    // Dispose of any existing controllers
    _videoController?.dispose();
    _chewieController?.dispose();

    try {
      if (isStream) {
        // For streaming, use network source
        _videoController = VideoPlayerController.networkUrl(Uri.parse(source));
      } else {
        // For local file, use file source
        _videoController = VideoPlayerController.file(File(source));
      }

      await _videoController!.initialize();
      
      _chewieController = ChewieController(
        videoPlayerController: _videoController!,
        autoPlay: true,
        looping: false,
        aspectRatio: _videoController!.value.aspectRatio,
        errorBuilder: (context, errorMessage) {
          return Center(
            child: Text(
              'Error: $errorMessage',
              style: const TextStyle(color: Colors.white),
            ),
          );
        },
      );
      
      setState(() {});
    } catch (e) {
      setState(() {
        _statusMessage = "Error initializing player: $e";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isStreaming ? "Torrent Streamer" : "Torrent Downloader"),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _magnetController,
              decoration: const InputDecoration(
                labelText: 'Enter Magnet Link',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _isInitialized ? _processMagnetLink : null,
              child: const Text('Process Magnet Link'),
            ),
            const SizedBox(height: 16),
            Text(
              _statusMessage,
              style: const TextStyle(fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            if (_isDownloading || _isStreaming)
              Column(
                children: [
                  LinearProgressIndicator(value: _downloadProgress),
                  const SizedBox(height: 8),
                  Text(
                    '${(_downloadProgress * 100).toStringAsFixed(1)}%',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            const SizedBox(height: 16),
            Expanded(
              child: _filesList.isNotEmpty
                  ? ListView.builder(
                      itemCount: _filesList.length,
                      itemBuilder: (context, index) {
                        final file = _filesList[index];
                        final isVideo = file['mimeType'].toString().startsWith('video/');
                        
                        return Card(
                          child: ListTile(
                            title: Text(file['name'] ?? 'Unknown'),
                            subtitle: Text('Size: ${_formatSize(file['size'] ?? 0)}'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Download button
                                IconButton(
                                  icon: const Icon(Icons.download),
                                  onPressed: _isDownloading || _isStreaming 
                                      ? null 
                                      : () => _selectFileToDownload(index),
                                  tooltip: 'Download',
                                ),
                                // Stream button (only for video files)
                                if (isVideo)
                                  IconButton(
                                    icon: const Icon(Icons.play_circle),
                                    onPressed: _isDownloading || _isStreaming 
                                        ? null 
                                        : () => _selectFileToStream(index),
                                    tooltip: 'Stream',
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    )
                  : const Center(
                      child: Text('No files to display'),
                    ),
            ),
            if (_chewieController != null)
              Container(
                height: 240,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                ),
                child: Chewie(controller: _chewieController!),
              ),
          ],
        ),
      ),
    );
  }

  String _formatSize(int bytes) {
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    double size = bytes.toDouble();
    
    while (size >= 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }
    
    return '${size.toStringAsFixed(2)} ${suffixes[i]}';
  }
}
