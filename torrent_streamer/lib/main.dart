import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
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
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _magnetController = TextEditingController();
  String _status = 'Not initialized';
  bool _isLoading = false;
  bool _isInitialized = false;
  
  String _torrentHash = '';
  List<TorrentFile> _files = [];
  TorrentFile? _selectedFile;
  String _localFilePath = '';
  double _downloadProgress = 0.0;
  bool _isDownloading = false;
  bool _downloadComplete = false;
  Timer? _progressTimer;
  
  String? _downloadDirectory;

  VideoPlayerController? _videoController;
  ChewieController? _chewieController;

  @override
  void initState() {
    super.initState();
    _requestPermissionsAndInit();
  }

  // Request permissions and initialize
  Future<void> _requestPermissionsAndInit() async {
    setState(() {
      _status = 'Requesting permissions...';
      _isLoading = true;
    });
    
    // Request all files access permission
    if (Platform.isAndroid) {
      // Check if we already have permissions
      if (!await Permission.manageExternalStorage.isGranted) {
        // Show explanation dialog
        if (mounted) {
          await showDialog(
            context: context,
            barrierDismissible: false,
            builder: (BuildContext context) {
              return AlertDialog(
                title: const Text('Storage Permission Required'),
                content: const SingleChildScrollView(
                  child: ListBody(
                    children: [
                      Text('This app needs full storage access to:'),
                      SizedBox(height: 8),
                      Text('• Download torrent files to your device'),
                      Text('• Save files to your selected location'),
                      Text('• Read and play downloaded media files'),
                      SizedBox(height: 12),
                      Text('You will need to enable "Allow management of all files" in the next screen.'),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    child: const Text('OPEN SETTINGS'),
                    onPressed: () {
                      Navigator.of(context).pop();
                      openAppSettings();
                    },
                  ),
                ],
              );
            },
          );
        }
        
        // Request the permission
        await Permission.manageExternalStorage.request();
      }
    }
    
    // Load saved directory and initialize
    await _loadSavedDirectory();
  }
  
  // Load saved directory
  Future<void> _loadSavedDirectory() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      _downloadDirectory = prefs.getString('downloadDirectory');
    });
    
    // Get default download directory if none is set
    if (_downloadDirectory == null) {
      await _selectDefaultDownloadDirectory();
    } else {
      // Verify the directory still exists
      final dir = Directory(_downloadDirectory!);
      if (!await dir.exists()) {
        await _selectDefaultDownloadDirectory();
      } else {
        _initializeFFI();
      }
    }
  }
  
  // Select default download directory
  Future<void> _selectDefaultDownloadDirectory() async {
    try {
      // Get the Downloads directory
      Directory? downloadsDir;
      
      if (Platform.isAndroid) {
        // Try to use the standard Downloads directory
        downloadsDir = Directory('/storage/emulated/0/Download');
        if (!await downloadsDir.exists()) {
          // Fall back to Documents
          downloadsDir = Directory('/storage/emulated/0/Documents');
        }
        if (!await downloadsDir.exists()) {
          // Final fallback to app's external storage
          downloadsDir = await getExternalStorageDirectory();
        }
      } else {
        // On iOS, use the documents directory
        final appDir = await getApplicationDocumentsDirectory();
        downloadsDir = Directory('${appDir.path}/Downloads');
        await downloadsDir.create(recursive: true);
      }
      
      if (downloadsDir != null) {
        await _saveDownloadDirectory(downloadsDir.path);
        _initializeFFI();
      } else {
        setState(() {
          _status = 'Error: Could not find a valid download directory';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _status = 'Error finding download directory: $e';
        _isLoading = false;
      });
    }
  }
  
  // Select a custom download directory
  Future<void> _selectDownloadDirectory() async {
    try {
      setState(() {
        _status = 'Please select a folder...';
        _isLoading = true;
      });
      
      // Use FilePicker to select a directory
      String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
      
      if (selectedDirectory != null) {
        await _saveDownloadDirectory(selectedDirectory);
        
        // Shutdown existing torrent client
        if (_isInitialized) {
          TorrentFFI.shutdown();
          _isInitialized = false;
        }
        
        // Re-initialize with new directory
        await _initializeFFI();
      } else {
        setState(() {
          _status = 'Directory selection canceled';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _status = 'Error selecting directory: $e';
        _isLoading = false;
      });
    }
  }

  // Initialize FFI with simplified error handling
  Future<void> _initializeFFI() async {
    setState(() {
      _status = 'Initializing...';
      _isLoading = true;
    });

    try {
      final result = await TorrentFFI.initialize(
        customDownloadDirectory: _downloadDirectory,
      );

      print('FFI initialization result: $result');

      setState(() {
        _status = result;
        _isLoading = false;
        _isInitialized = result.contains('successfully');
      });
    } catch (e) {
      setState(() {
        _status = 'Error initializing torrent client: $e';
        _isLoading = false;
        _isInitialized = false;
      });
    }
  }

  // Save the download directory
  Future<void> _saveDownloadDirectory(String directory) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString('downloadDirectory', directory);
    setState(() {
      _downloadDirectory = directory;
    });
  }

  @override
  void dispose() {
    _magnetController.dispose();
    _disposeVideoControllers();
    _stopProgressTracking();
    if (_isInitialized) {
      TorrentFFI.shutdown();
    }
    super.dispose();
  }

  void _disposeVideoControllers() {
    _chewieController?.dispose();
    _videoController?.dispose();
    _chewieController = null;
    _videoController = null;
  }

  // Process a magnet link
  void _processMagnetLink() {
    if (_magnetController.text.isEmpty) {
      setState(() {
        _status = 'Please enter a magnet link';
      });
      return;
    }

    setState(() {
      _status = 'Adding torrent & getting info...';
      _isLoading = true;
      _files = [];
      _selectedFile = null;
      _localFilePath = '';
      _downloadProgress = 0.0;
      _downloadComplete = false;
      _isDownloading = false;
      _torrentHash = '';
      _disposeVideoControllers();
      _stopProgressTracking();
    });

    try {
      // Call the new function to get the hash directly
      final result = TorrentFFI.addTorrentAndGetInfoHash(_magnetController.text);
      
      // Check for errors returned from Go
      if (result.startsWith('Error:')) {
        setState(() {
          _status = result;
          _isLoading = false;
        });
        return;
      }
      
      // Store the hash
      _torrentHash = result;
      
      setState(() {
        _status = 'Fetching file list for hash: $_torrentHash';
      });
      
      if (_torrentHash.isNotEmpty) {
        _fetchFileList();
      } else {
        // Should not happen if Go returns empty string only on non-error
        setState(() {
          _status = 'Error: Did not receive torrent hash';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _status = 'Error processing magnet: $e';
        _isLoading = false;
      });
    }
  }
  
  // Fetch the list of files in the torrent
  void _fetchFileList() {
    try {
      final jsonString = TorrentFFI.listTorrentFiles(_torrentHash);
      final dynamic jsonData = json.decode(jsonString);
      
      if (jsonData is List) {
        final files = jsonData.map((item) => TorrentFile.fromJson(item)).toList();
        
        setState(() {
          _files = files;
          _status = 'Found ${_files.length} files. Select a file to download.';
          _isLoading = false;
        });
      } else if (jsonData is String && jsonData.startsWith('Error:')) {
        setState(() {
          _status = jsonData; // Show error from Go
          _isLoading = false;
        });
      } else {
        setState(() {
          _status = 'Error: Unexpected file list format';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _status = 'Error fetching file list: $e';
        _isLoading = false;
      });
    }
  }
  
  // Select a file
  void _selectFile(TorrentFile file) {
    setState(() {
      _selectedFile = file;
      _status = 'Ready to download: ${file.name}';
      _localFilePath = '';
      _downloadProgress = 0.0;
      _downloadComplete = false;
      _isDownloading = false;
      _disposeVideoControllers();
      _stopProgressTracking();
    });
  }
  
  void _stopProgressTracking() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }
  
  // Start downloading the selected file
  void _downloadSelectedFile() {
    if (_selectedFile == null) return;
    
    setState(() {
      _isLoading = true;
      _isDownloading = true;
      _downloadProgress = 0.0;
      _downloadComplete = false;
      _status = 'Starting download for: ${_selectedFile!.name}';
    });
    
    try {
      final result = TorrentFFI.downloadTorrentFile(_torrentHash, _selectedFile!.index.toString());
      
      // Check if the result looks like an error message
      if (result.startsWith('Error:')) {
        setState(() {
          _status = result;
          _isLoading = false;
          _isDownloading = false;
        });
        return;
      }
      
      // Store the local file path
      _localFilePath = result;
      
      // Start tracking download progress
      _trackDownloadProgress();
      
    } catch (e) {
      setState(() {
        _status = 'Error starting download: $e';
        _isLoading = false;
        _isDownloading = false;
      });
    }
  }
  
  // Track the download progress
  void _trackDownloadProgress() {
    // Cancel any existing timer
    _stopProgressTracking();
    
    // Create a new timer to poll for progress
    _progressTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_selectedFile == null) {
        _stopProgressTracking();
        return;
      }
      try {
        final progressJson = TorrentFFI.getDownloadProgress(_torrentHash, _selectedFile!.index.toString());
        final progressData = json.decode(progressJson);
        
        // Check for errors from Go
        if (progressData is String && progressData.startsWith('Error:')) {
          setState(() {
            _status = progressData;
            _isDownloading = false; // Stop showing progress bar on error
            _isLoading = false;
          });
          _stopProgressTracking();
          return;
        }
        
        // Check if the response is a map (expected)
        if (progressData is Map<String, dynamic>) {
          setState(() {
            _downloadProgress = (progressData['progress'] as num).toDouble(); 
            _status = 'Downloading: ${_downloadProgress.toStringAsFixed(2)}% (${_formatBytes(progressData['completed'] as int)}/${_formatBytes(progressData['total'] as int)})';
            
            if (progressData['done'] as bool) {
              _downloadComplete = true;
              _isDownloading = false;
              _isLoading = false;
              _status = 'Download complete: ${_selectedFile!.name}';
              _stopProgressTracking();
            }
          });
        } else {
           throw Exception('Unexpected progress format: $progressData');
        }
        
      } catch (e) {
        print('Error tracking progress: $e');
        // Optionally update status to show tracking error
         setState(() {
           _status = 'Error checking progress: $e';
           _isDownloading = false; // Stop showing progress bar
         });
         _stopProgressTracking(); 
      }
    });
  }
  
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(2)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
  
  // Play the downloaded file with better error handling
  Future<void> _playLocalFile() async {
    if (_localFilePath.isEmpty || !_downloadComplete) return;
    
    setState(() {
      _isLoading = true;
      _status = 'Loading video from local file...';
    });
    
    try {
      _disposeVideoControllers();
      
      // Print detailed debugging info
      print("Attempting to play file: $_localFilePath");
      
      // Check if file exists
      File fileToPlay = File(_localFilePath);
      bool fileExists = await fileToPlay.exists();
      
      if (!fileExists) {
        print("File not found at original path: $_localFilePath");
        
        // First try common alternates - the file might be in a subdirectory
        final fileName = path.basename(_localFilePath);
        final parentDir = Directory(path.dirname(_localFilePath));
        
        // List of places to look for the file
        List<String> possiblePaths = [];
        
        // Look for common structures
        if (await parentDir.exists()) {
          // Try looking in subdirectories with the same name as the file (without extension)
          final fileNameWithoutExt = fileName.contains('.') 
              ? fileName.substring(0, fileName.lastIndexOf('.')) 
              : fileName;
          
          final subDir = Directory(path.join(parentDir.path, fileNameWithoutExt));
          if (await subDir.exists()) {
            possiblePaths.add(path.join(subDir.path, fileName));
          }
          
          // Also try looking for the file directly in subdirectories
          try {
            await for (final entity in parentDir.list(recursive: true)) {
              if (entity is File && path.basename(entity.path) == fileName) {
                possiblePaths.add(entity.path);
                break;
              }
            }
          } catch (e) {
            print("Error searching subdirectories: $e");
          }
        }
        
        // Check if any of the possible paths exist
        for (final possiblePath in possiblePaths) {
          print("Checking alternative path: $possiblePath");
          final possibleFile = File(possiblePath);
          if (await possibleFile.exists()) {
            print("Found file at: $possiblePath");
            fileToPlay = possibleFile;
            fileExists = true;
            
            // Update the stored path for future reference
            _localFilePath = possiblePath;
            break;
          }
        }
        
        // If still not found, try the more exhaustive directory search
        if (!fileExists) {
          try {
            // Try to handle case-sensitivity and path normalization issues
            final directory = Directory(path.dirname(_localFilePath));
            
            if (!await directory.exists()) {
              print("Parent directory doesn't exist: ${directory.path}");
              throw Exception('Directory not found: ${directory.path}');
            }
            
            print("Searching directory and subdirectories: ${directory.path}");
            
            bool fileFound = false;
            String? foundPath;
            
            // Deeper recursive search
            try {
              await for (final entity in directory.list(recursive: true)) {
                if (entity is File) {
                  final entityName = path.basename(entity.path);
                  print("Checking file: $entityName");
                  
                  if (entityName.toLowerCase() == fileName.toLowerCase()) {
                    foundPath = entity.path;
                    print("Found matching file: $foundPath");
                    fileFound = true;
                    break;
                  }
                }
              }
              
              if (!fileFound) {
                // Try one level up
                final parentOfParent = Directory(path.dirname(directory.path));
                if (await parentOfParent.exists()) {
                  await for (final entity in parentOfParent.list(recursive: true)) {
                    if (entity is File) {
                      final entityName = path.basename(entity.path);
                      if (entityName.toLowerCase() == fileName.toLowerCase()) {
                        foundPath = entity.path;
                        print("Found matching file in parent directory: $foundPath");
                        fileFound = true;
                        break;
                      }
                    }
                  }
                }
              }
              
              if (!fileFound) {
                throw Exception('File not found at $_localFilePath and no similar files found');
              }
            } catch (e) {
              print("Error while searching directory: $e");
              throw Exception('File not found and error searching directory: $e');
            }
            
            // Update file with found path
            if (foundPath != null) {
              fileToPlay = File(foundPath);
              fileExists = await fileToPlay.exists();
              if (!fileExists) {
                throw Exception('File found but then disappeared at: $foundPath');
              }
              // Update the stored path for future reference
              _localFilePath = foundPath;
            }
          } catch (e) {
            print("Error in fallback file search: $e");
            throw Exception('Unable to locate file: $e');
          }
        }
      }
      
      // Check file size to ensure it's a valid file
      final fileSize = await fileToPlay.length();
      print("File exists: $fileExists, Size: $fileSize bytes");
      
      if (fileSize == 0) {
        throw Exception('File exists but is empty (0 bytes)');
      }
      
      // Create the video controller with explicit file path
      _videoController = VideoPlayerController.file(fileToPlay);
      
      // Initialize with timeout and error handling
      bool initialized = false;
      try {
        await _videoController!.initialize().timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            throw Exception('Video initialization timed out after 15 seconds');
          },
        );
        initialized = true;
      } catch (e) {
        print("Error initializing video controller: $e");
        throw Exception('Failed to initialize video: $e');
      }
      
      if (!initialized) {
        throw Exception('Video failed to initialize');
      }
      
      print("Video controller initialized successfully");
      print("Video dimensions: ${_videoController!.value.size}");
      print("Video duration: ${_videoController!.value.duration}");
      
      _chewieController = ChewieController(
        videoPlayerController: _videoController!,
        autoPlay: true,
        looping: false,
        allowMuting: true,
        allowPlaybackSpeedChanging: true,
        showControls: true,
        aspectRatio: _videoController!.value.aspectRatio != 0 ? 
            _videoController!.value.aspectRatio : 16/9,
        errorBuilder: (context, errorMessage) {
          print("Chewie error: $errorMessage");
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Error: $errorMessage',
                  style: const TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _playLocalFile,
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        },
      );
      
      setState(() {
        _isLoading = false;
        _status = 'Playing: ${_selectedFile?.name}';
      });
    } catch (e) {
      print("Error playing local file: $e");
      setState(() {
        _status = 'Error playing local file: $e';
        _isLoading = false;
        _disposeVideoControllers();
      });
      
      // Display a dialog with detailed error and options to help troubleshoot
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('File Access Error'),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Unable to access the file: $_localFilePath'),
                  const SizedBox(height: 8),
                  Text('Error: $e'),
                  const SizedBox(height: 16),
                  const Text('Troubleshooting steps:', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text('• Check if the download completed successfully'),
                  const Text('• Try downloading the file again'),
                  const Text('• Check your device settings for media permissions'),
                  if (_downloadDirectory != null) ...[
                    const SizedBox(height: 16),
                    Text('Current download directory: $_downloadDirectory'),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('CLOSE'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  if (_selectedFile != null) {
                    _downloadSelectedFile();
                  }
                },
                child: const Text('REDOWNLOAD'),
              ),
            ],
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Torrent Streamer'),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder),
            tooltip: 'Change Download Folder',
            onPressed: _isLoading ? null : _selectDownloadDirectory,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Permissions',
            onPressed: () => openAppSettings(),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Display current download directory
            if (_downloadDirectory != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Download Directory:',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        Text(
                          _downloadDirectory!,
                          style: Theme.of(context).textTheme.bodyMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            TextField(
              controller: _magnetController,
              decoration: const InputDecoration(
                labelText: 'Magnet Link',
                hintText: 'Paste magnet link here',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _isLoading || !_isInitialized ? null : _processMagnetLink,
              child: const Text('Process Torrent'),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  _status,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
            if (_isDownloading && !_downloadComplete) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: _downloadProgress / 100,
                backgroundColor: Colors.grey[300],
                valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary),
              ),
              const SizedBox(height: 8),
              Text('${_downloadProgress.toStringAsFixed(2)}%', 
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
            const SizedBox(height: 16),
            if (_isLoading && _chewieController == null && !_isDownloading)
              const Center(child: CircularProgressIndicator())
            else if (_chewieController != null)
              Expanded(
                child: AspectRatio(
                  aspectRatio: _chewieController!.aspectRatio ?? 16 / 9,
                  child: Chewie(controller: _chewieController!),
                ),
              )
            else if (_files.isNotEmpty)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Available Files:',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.builder(
                        itemCount: _files.length,
                        itemBuilder: (context, index) {
                          final file = _files[index];
                          return ListTile(
                            leading: Icon(file.icon),
                            title: Text(file.name),
                            subtitle: Text(file.formattedSize),
                            selected: _selectedFile?.index == file.index,
                            onTap: () => _selectFile(file),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            
            if (_selectedFile != null && _chewieController == null) ...[
              const SizedBox(height: 16),
              if (_downloadComplete) 
                ElevatedButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: Text('Play ${_selectedFile!.name}'),
                  onPressed: _playLocalFile,
                )
              else
                ElevatedButton.icon(
                  icon: const Icon(Icons.download),
                  label: Text(_isDownloading ? 'Downloading...' : 'Download ${_selectedFile!.name}'),
                  onPressed: _isDownloading ? null : _downloadSelectedFile,
                ),
            ],
          ],
        ),
      ),
    );
  }
}
