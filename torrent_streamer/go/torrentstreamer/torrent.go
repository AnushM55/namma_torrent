package main

/*
#include <stdlib.h>
#include <string.h>
*/
import "C"
import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/anacrolix/torrent"
)

var (
	client      *torrent.Client
	clientLock  sync.Mutex
	torrents    = make(map[string]*torrent.Torrent)
	downloadDir string
	httpServer  *http.Server
	serverPort  int
)

type TorrentFile struct {
	Name     string `json:"name"`
	Path     string `json:"path"`
	Size     int64  `json:"size"`
	Index    int    `json:"index"`
	MimeType string `json:"mimeType"`
}

// Find an available port for the HTTP server
func findAvailablePort(startPort int) (int, error) {
	for port := startPort; port < startPort+100; port++ {
		listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err == nil {
			listener.Close()
			return port, nil
		}
	}
	return 0, fmt.Errorf("no available ports found")
}

// Stream handler function
func streamHandler(w http.ResponseWriter, r *http.Request) {
	// Extract hash and fileIndex from request
	hash := r.URL.Query().Get("hash")
	fileIndexStr := r.URL.Query().Get("file")

	if hash == "" || fileIndexStr == "" {
		http.Error(w, "Missing hash or file parameter", http.StatusBadRequest)
		return
	}

	// Lock access to torrents map
	clientLock.Lock()
	t, exists := torrents[hash]
	clientLock.Unlock()

	if !exists {
		http.Error(w, "Torrent not found", http.StatusNotFound)
		return
	}

	fileIndex, err := strconv.Atoi(fileIndexStr)
	if err != nil {
		http.Error(w, "Invalid file index", http.StatusBadRequest)
		return
	}

	files := t.Files()
	if fileIndex < 0 || fileIndex >= len(files) {
		http.Error(w, fmt.Sprintf("File index out of range (0-%d)", len(files)-1), http.StatusBadRequest)
		return
	}

	file := files[fileIndex]

	// Set content type based on file extension
	contentType := getMimeType(file.DisplayPath())
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Content-Length", fmt.Sprintf("%d", file.Length()))
	w.Header().Set("Accept-Ranges", "bytes")

	// Parse range header for seeking support
	var start, end int64
	rangeHeader := r.Header.Get("Range")
	if rangeHeader != "" {
		if strings.HasPrefix(rangeHeader, "bytes=") {
			rangeStr := rangeHeader[6:]
			rangeParts := strings.Split(rangeStr, "-")
			if len(rangeParts) == 2 {
				start, _ = strconv.ParseInt(rangeParts[0], 10, 64)
				if rangeParts[1] != "" {
					end, _ = strconv.ParseInt(rangeParts[1], 10, 64)
				} else {
					end = file.Length() - 1
				}

				if end >= file.Length() {
					end = file.Length() - 1
				}

				w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, file.Length()))
				w.WriteHeader(http.StatusPartialContent)
			}
		}
	} else {
		end = file.Length() - 1
	}

	// Priority boost
	file.SetPriority(torrent.PiecePriorityHigh)

	// Create a reader for the file
	reader := file.NewReader()
	defer reader.Close()

	// Seek to the start position if needed
	if start > 0 {
		reader.Seek(start, io.SeekStart)
	}

	// Stream the data
	_, err = io.CopyN(w, reader, end-start+1)
	if err != nil {
		fmt.Printf("Error streaming file: %s\n", err.Error())
	}
}

//export InitTorrentClient
func InitTorrentClient(cacheDir *C.char, customDownloadDir *C.char) *C.char {
	clientLock.Lock()
	defer clientLock.Unlock()

	if client != nil {
		// Properly clean up existing client
		for _, t := range torrents {
			t.Drop()
		}
		torrents = make(map[string]*torrent.Torrent)
		client.Close()
		client = nil
	}

	// Stop any existing HTTP server
	if httpServer != nil {
		httpServer.Close()
		httpServer = nil
	}

	// Get the cache directory from the Flutter app
	cacheDirGo := C.GoString(cacheDir)
	if cacheDirGo == "" {
		return C.CString("Error: Cache directory path is empty")
	}

	// Set download directory (prefer custom directory if provided)
	customDownloadDirGo := C.GoString(customDownloadDir)

	if customDownloadDirGo != "" {
		downloadDir = customDownloadDirGo
		fmt.Printf("Using custom download directory: %s\n", downloadDir)
	} else {
		// Default to Download folder on external storage
		downloadDir = "/storage/emulated/0/Download"
		if _, err := os.Stat(downloadDir); os.IsNotExist(err) {
			// Fall back to app cache directory
			downloadDir = filepath.Join(cacheDirGo, "torrentstreamer_downloads")
		}
		fmt.Printf("Using default download directory: %s\n", downloadDir)
	}

	// Create the download directory if it doesn't exist
	err := os.MkdirAll(downloadDir, 0700)
	if err != nil {
		return C.CString(fmt.Sprintf("Error creating download dir: %s", err.Error()))
	}

	// Test write permission
	testFile := filepath.Join(downloadDir, ".write_test")
	err = os.WriteFile(testFile, []byte("test"), 0600)
	if err != nil {
		return C.CString(fmt.Sprintf("Error: Cannot write to download directory: %s", err.Error()))
	}
	os.Remove(testFile)

	// Create a directory for torrent data in the app's cache directory
	tmpDir := filepath.Join(cacheDirGo, "torrentstreamer_data")
	err = os.MkdirAll(tmpDir, 0700)
	if err != nil {
		return C.CString(fmt.Sprintf("Error creating torrent data dir: %s", err.Error()))
	}

	// Create a torrent client config
	config := torrent.NewDefaultClientConfig()
	config.DataDir = downloadDir // Use the download directory for storing torrent data
	config.DisableIPv6 = true
	config.DisableTCP = false // Enable TCP connections (more reliable)
	config.DisableUTP = true  // Disable UDP (more compatible with restricted networks)
	config.NoDHT = false
	config.NoUpload = false
	config.Seed = false

	// Create the torrent client
	client, err = torrent.NewClient(config)
	if err != nil {
		return C.CString(fmt.Sprintf("Error creating torrent client: %s", err.Error()))
	}

	// Start HTTP server for streaming on a free port
	serverPort, err = findAvailablePort(8080)
	if err != nil {
		return C.CString(fmt.Sprintf("Error finding available port: %s", err.Error()))
	}

	// Setup HTTP handlers
	mux := http.NewServeMux()
	mux.HandleFunc("/stream", streamHandler)

	// Create HTTP server
	httpServer = &http.Server{
		Addr:    fmt.Sprintf("127.0.0.1:%d", serverPort),
		Handler: mux,
	}

	// Start HTTP server in a goroutine
	go func() {
		if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			fmt.Printf("HTTP server error: %s\n", err.Error())
		}
	}()

	fmt.Printf("HTTP server started on port %d\n", serverPort)

	return C.CString(fmt.Sprintf("Torrent client initialized successfully. Download directory: %s, Streaming on port: %d", downloadDir, serverPort))
}

//export ShutdownTorrentClient
func ShutdownTorrentClient() *C.char {
	clientLock.Lock()
	defer clientLock.Unlock()

	if client == nil {
		return C.CString("Torrent client not initialized")
	}

	// Close all torrents
	for _, t := range torrents {
		t.Drop()
	}
	torrents = make(map[string]*torrent.Torrent)

	// Close the client
	client.Close()
	client = nil

	// Shutdown HTTP server if it exists
	if httpServer != nil {
		ctx, cancel := contextWithTimeout(5 * time.Second)
		defer cancel()
		httpServer.Shutdown(ctx)
		httpServer = nil
	}

	return C.CString("Torrent client shut down successfully")
}

// Create a context with timeout for server shutdown
func contextWithTimeout(timeout time.Duration) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), timeout)
}

//export AddTorrentAndGetInfoHash
func AddTorrentAndGetInfoHash(magnetURI *C.char) *C.char {
	clientLock.Lock()
	defer clientLock.Unlock()

	if client == nil {
		return C.CString("Error: Torrent client not initialized")
	}

	inputURIGo := C.GoString(magnetURI)
	fmt.Printf("Processing input: %s\n", inputURIGo)

	var t *torrent.Torrent
	var err error

	// Check if it's a magnet URI or HTTP URL
	if strings.HasPrefix(inputURIGo, "magnet:") {
		// It's a magnet URI
		t, err = client.AddMagnet(inputURIGo)
	} else if strings.HasPrefix(inputURIGo, "http://") || strings.HasPrefix(inputURIGo, "https://") {
		// It's an HTTP URL - we need to reject this with a better error message
		return C.CString("Error: Direct HTTP/HTTPS torrent links are not supported. Please use a magnet link instead.")
	} else {
		// Unknown format
		return C.CString("Error: Invalid input format. Please provide a valid magnet URI.")
	}

	if err != nil {
		return C.CString(fmt.Sprintf("Error adding torrent: %s", err.Error()))
	}

	if t == nil {
		return C.CString("Error: Failed to create torrent (nil torrent object)")
	}

	// Wait for info
	select {
	case <-t.GotInfo():
		// Store the torrent
		infoHash := t.InfoHash().HexString()
		torrents[infoHash] = t
		fmt.Printf("Successfully added torrent with hash: %s\n", infoHash)
		return C.CString(infoHash)
	case <-time.After(30 * time.Second):
		return C.CString("Error: Timed out waiting for torrent info")
	}
}

//export GetStreamURL
func GetStreamURL(infoHash *C.char, fileIndex *C.char) *C.char {
	clientLock.Lock()
	defer clientLock.Unlock()

	if client == nil {
		return C.CString("Error: Torrent client not initialized")
	}

	infoHashGo := C.GoString(infoHash)
	fileIndexGo := C.GoString(fileIndex)

	// Verify torrent exists
	_, exists := torrents[infoHashGo]
	if !exists {
		return C.CString(fmt.Sprintf("Error: Torrent with hash %s not found", infoHashGo))
	}

	// Return the streaming URL
	streamURL := fmt.Sprintf("http://127.0.0.1:%d/stream?hash=%s&file=%s",
		serverPort, infoHashGo, fileIndexGo)

	return C.CString(streamURL)
}

//export ListTorrentFiles
func ListTorrentFiles(infoHash *C.char) *C.char {
	clientLock.Lock()
	defer clientLock.Unlock()

	if client == nil {
		return C.CString("Error: Torrent client not initialized")
	}

	infoHashGo := C.GoString(infoHash)

	t, exists := torrents[infoHashGo]
	if !exists {
		return C.CString(fmt.Sprintf("Error: Torrent with hash %s not found", infoHashGo))
	}

	files := getFilesList(t)
	jsonFiles, err := json.Marshal(files)
	if err != nil {
		return C.CString(fmt.Sprintf("Error marshaling file list: %s", err.Error()))
	}

	return C.CString(string(jsonFiles))
}

//export DownloadTorrentFile
func DownloadTorrentFile(infoHash *C.char, fileIndex *C.char) *C.char {
	clientLock.Lock()
	defer clientLock.Unlock()

	if client == nil {
		return C.CString("Error: Torrent client not initialized")
	}

	infoHashGo := C.GoString(infoHash)
	fileIndexGo := C.GoString(fileIndex)

	// Get the torrent
	t, exists := torrents[infoHashGo]
	if !exists {
		return C.CString(fmt.Sprintf("Error: Torrent with hash %s not found", infoHashGo))
	}

	// Convert file index to int
	fileIdx, err := strconv.Atoi(fileIndexGo)
	if err != nil {
		return C.CString(fmt.Sprintf("Error: Invalid file index: %s", err.Error()))
	}

	// Additional safety check for parsing "null"
	if fileIndexGo == "null" || fileIndexGo == "" {
		return C.CString("Error: Invalid file index: received empty or null value")
	}

	// Get the files list
	files := t.Files()

	// Check if file index is valid
	if fileIdx < 0 || fileIdx >= len(files) {
		return C.CString(fmt.Sprintf("Error: File index out of range (0-%d)", len(files)-1))
	}

	// Get the file
	file := files[fileIdx]

	// IMPORTANT: Preserve directory structure from torrent
	// Get the full display path which might include directories
	fullDisplayPath := file.DisplayPath()

	// Create the directory structure in the download location
	destPath := filepath.Join(downloadDir, fullDisplayPath)
	destDir := filepath.Dir(destPath)

	// Create all necessary directories
	err = os.MkdirAll(destDir, 0700)
	if err != nil {
		return C.CString(fmt.Sprintf("Error creating directory structure: %s", err.Error()))
	}

	// Log the full path for debugging
	fmt.Printf("Download path: %s\n", destPath)

	// Set high priority for this file
	file.SetPriority(torrent.PiecePriorityHigh)

	// Check if file is already completed
	if file.BytesCompleted() == file.Length() {
		// Verify file exists at expected location
		if _, err := os.Stat(destPath); err == nil {
			return C.CString(destPath)
		}

		// If file is complete but doesn't exist at expected location,
		// we need to check if it exists in the root download directory
		// (for backward compatibility with previous downloads)

		// Try the old-style path with hash prefix
		legacyFileName := fmt.Sprintf("%s_%s", infoHashGo[:8], filepath.Base(fullDisplayPath))
		legacyPath := filepath.Join(downloadDir, legacyFileName)

		if _, err := os.Stat(legacyPath); err == nil {
			return C.CString(legacyPath)
		}

		// Also try just the filename in the download directory
		simplePath := filepath.Join(downloadDir, filepath.Base(fullDisplayPath))
		if _, err := os.Stat(simplePath); err == nil {
			return C.CString(simplePath)
		}

		// Also try to find it in subdirectories by walking the download directory
		var foundPath string
		filepath.Walk(downloadDir, func(path string, info os.FileInfo, err error) error {
			if err != nil {
				return nil // Skip errors
			}
			if !info.IsDir() && filepath.Base(path) == filepath.Base(fullDisplayPath) {
				foundPath = path
				return filepath.SkipDir // Stop walking once found
			}
			return nil
		})

		if foundPath != "" {
			return C.CString(foundPath)
		}

		fmt.Printf("File is reported complete but doesn't exist at expected locations\n")
	}

	// Start a goroutine to encourage the download
	go func() {
		<-t.GotInfo() // Make sure info is available

		// Keep this goroutine running to monitor download
		fmt.Printf("Download goroutine started for file %d to %s\n", fileIdx, destPath)

		// Check if download is active
		completeTimer := time.NewTicker(5 * time.Second)
		defer completeTimer.Stop()

		for {
			select {
			case <-completeTimer.C:
				completed := file.BytesCompleted()
				total := file.Length()

				// If complete, try to ensure the file is properly saved
				if completed == total && total > 0 {
					fmt.Printf("Download complete for %s\n", destPath)
					return
				}

				// Log progress
				var progress float64 = 0
				if total > 0 {
					progress = float64(completed) / float64(total) * 100
				}
				fmt.Printf("Download progress: %.2f%% (%d/%d bytes)\n", progress, completed, total)
			}
		}
	}()

	// Return the local path where the file should be downloaded
	return C.CString(destPath)
}

// Helper function to sanitize filenames
func sanitizeFileName(name string) string {
	// Replace characters that might cause issues on various filesystems
	invalidChars := []string{"<", ">", ":", "\"", "/", "\\", "|", "?", "*"}
	result := name

	for _, char := range invalidChars {
		result = strings.ReplaceAll(result, char, "_")
	}

	// Limit filename length
	if len(result) > 200 {
		ext := filepath.Ext(result)
		result = result[:200-len(ext)] + ext
	}

	return result
}

//export GetDownloadProgress
func GetDownloadProgress(infoHash *C.char, fileIndex *C.char) *C.char {
	clientLock.Lock()
	defer clientLock.Unlock()

	if client == nil {
		return C.CString("Error: Torrent client not initialized")
	}

	infoHashGo := C.GoString(infoHash)
	fileIndexGo := C.GoString(fileIndex)

	// Get the torrent
	t, exists := torrents[infoHashGo]
	if !exists {
		return C.CString(fmt.Sprintf("Error: Torrent with hash %s not found", infoHashGo))
	}

	// Convert file index to int
	fileIdx, err := strconv.Atoi(fileIndexGo)
	if err != nil {
		return C.CString(fmt.Sprintf("Error: Invalid file index: %s", err.Error()))
	}

	// Additional safety check for parsing "null"
	if fileIndexGo == "null" || fileIndexGo == "" {
		return C.CString("Error: Invalid file index: received empty or null value")
	}

	// Get the files list
	files := t.Files()

	// Check if file index is valid
	if fileIdx < 0 || fileIdx >= len(files) {
		return C.CString(fmt.Sprintf("Error: File index out of range (0-%d)", len(files)-1))
	}

	// Get the file
	file := files[fileIdx]

	// Calculate progress
	completed := file.BytesCompleted()
	total := file.Length()
	var progress float64 = 0
	if total > 0 {
		progress = float64(completed) / float64(total) * 100
	}

	// Create response
	response := struct {
		Completed int64   `json:"completed"`
		Total     int64   `json:"total"`
		Progress  float64 `json:"progress"`
		Done      bool    `json:"done"`
	}{
		Completed: completed,
		Total:     total,
		Progress:  progress,
		Done:      completed == total && total > 0, // Ensure Done is true only if total > 0
	}

	jsonResponse, err := json.Marshal(response)
	if err != nil {
		return C.CString(fmt.Sprintf("Error marshaling progress: %s", err.Error()))
	}

	return C.CString(string(jsonResponse))
}

//export FreeString
func FreeString(str *C.char) {
	C.free(unsafe.Pointer(str))
}

// Helper function to get list of files from a torrent
func getFilesList(t *torrent.Torrent) []TorrentFile {
	var files []TorrentFile
	filesList := t.Files()

	// If no files found, return empty list
	if len(filesList) == 0 {
		fmt.Printf("Warning: No files found in torrent %s\n", t.InfoHash().HexString())
		return files
	}

	for i, file := range filesList {
		// Skip any invalid files
		if file == nil {
			fmt.Printf("Warning: Nil file at index %d\n", i)
			continue
		}

		displayPath := file.DisplayPath()
		if displayPath == "" {
			displayPath = fmt.Sprintf("Unknown_File_%d", i)
		}

		files = append(files, TorrentFile{
			Name:     filepath.Base(displayPath),
			Path:     displayPath,
			Size:     file.Length(),
			Index:    i,
			MimeType: getMimeType(displayPath),
		})
	}

	return files
}

// Helper function to get MIME type based on file extension
func getMimeType(filePath string) string {
	ext := filepath.Ext(filePath)
	switch ext {
	case ".mp4":
		return "video/mp4"
	case ".mkv":
		return "video/x-matroska"
	case ".avi":
		return "video/x-msvideo"
	case ".mov":
		return "video/quicktime"
	case ".wmv":
		return "video/x-ms-wmv"
	case ".flv":
		return "video/x-flv"
	case ".webm":
		return "video/webm"
	case ".mp3":
		return "audio/mpeg"
	case ".wav":
		return "audio/wav"
	case ".flac":
		return "audio/flac"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".png":
		return "image/png"
	case ".gif":
		return "image/gif"
	case ".txt":
		return "text/plain"
	case ".pdf":
		return "application/pdf"
	default:
		return "application/octet-stream"
	}
}
