import Foundation
import UIKit
import Combine
import WebKit

// MARK: - Thumbnail Cache Manager
class ThumbnailCacheManager: ObservableObject {
    static let shared = ThumbnailCacheManager()
    
    @Published private(set) var thumbnails: [String: UIImage] = [:]
    
    private let cache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private let maxCacheSize = 100 * 1024 * 1024 // 100MB max cache
    private var activeFetches: [String: Task<Void, Never>] = [:]
    private let fetchQueue = DispatchQueue(label: "com.iccc.thumbnailFetch", qos: .utility)
    private let lock = NSLock()
    
    private init() {
        // Setup cache directory
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = paths[0].appendingPathComponent("CameraThumbnails")
        
        // Create directory if needed
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        // Configure NSCache
        cache.countLimit = 200 // Max 200 images in memory
        cache.totalCostLimit = maxCacheSize
        
        // Load existing thumbnails from disk
        loadCachedThumbnails()
        
        DebugLogger.shared.log("🖼️ ThumbnailCacheManager initialized", emoji: "🖼️", color: .blue)
    }
    
    // MARK: - Get Thumbnail
    
    func getThumbnail(for cameraId: String) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        
        // Check memory cache first
        if let cached = cache.object(forKey: cameraId as NSString) {
            return cached
        }
        
        // Check published dictionary
        return thumbnails[cameraId]
    }
    
    // MARK: - Fetch Thumbnail from Stream
    
    func fetchThumbnail(for camera: Camera, force: Bool = false) {
        lock.lock()
        let existingTask = activeFetches[camera.id]
        lock.unlock()
        
        // Don't fetch if already in progress
        if existingTask != nil && !force {
            return
        }
        
        // Don't fetch if we already have a recent thumbnail and not forcing
        if !force && getThumbnail(for: camera.id) != nil {
            return
        }
        
        let task = Task { @MainActor in
            await performFetch(for: camera)
        }
        
        lock.lock()
        activeFetches[camera.id] = task
        lock.unlock()
    }
    
    @MainActor
    private func performFetch(for camera: Camera) async {
        guard let streamURL = camera.webrtcStreamURL else {
            DebugLogger.shared.log("⚠️ No stream URL for camera: \(camera.id)", emoji: "⚠️", color: .orange)
            removeFetchTask(for: camera.id)
            return
        }
        
        do {
            // Create a temporary webview to capture frame
            let image = try await captureFrameFromStream(streamURL: streamURL, cameraId: camera.id)
            
            // Save to cache
            saveThumbnail(image, for: camera.id)
            
            // Update published state
            thumbnails[camera.id] = image
            cache.setObject(image, forKey: camera.id as NSString)
            
            DebugLogger.shared.log("✅ Thumbnail captured: \(camera.id)", emoji: "✅", color: .green)
            
        } catch {
            DebugLogger.shared.log("❌ Failed to capture thumbnail: \(error.localizedDescription)", emoji: "❌", color: .red)
        }
        
        removeFetchTask(for: camera.id)
    }
    
    private func captureFrameFromStream(streamURL: String, cameraId: String) async throws -> UIImage {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                let config = WKWebViewConfiguration()
                config.allowsInlineMediaPlayback = true
                config.mediaTypesRequiringUserActionForPlayback = []
                config.websiteDataStore = .nonPersistent()
                
                let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 360), configuration: config)
                
                let html = self.generateCaptureHTML(streamURL: streamURL)
                webView.loadHTMLString(html, baseURL: nil)
                
                // Wait 3 seconds for stream to start, then capture
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    let captureConfig = WKSnapshotConfiguration()
                    captureConfig.rect = CGRect(x: 0, y: 0, width: 640, height: 360)
                    
                    webView.takeSnapshot(with: captureConfig) { image, error in
                        // Cleanup immediately
                        webView.stopLoading()
                        webView.loadHTMLString("", baseURL: nil)
                        
                        if let image = image {
                            continuation.resume(returning: image)
                        } else {
                            continuation.resume(throwing: error ?? NSError(domain: "ThumbnailCapture", code: -1))
                        }
                    }
                }
                
                // Timeout after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    webView.stopLoading()
                    continuation.resume(throwing: NSError(domain: "ThumbnailCapture", code: -2, userInfo: [NSLocalizedDescriptionKey: "Timeout"]))
                }
            }
        }
    }
    
    private func generateCaptureHTML(streamURL: String) -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                html, body { width: 100%; height: 100%; overflow: hidden; background: #000; }
                video { width: 100%; height: 100%; object-fit: cover; }
            </style>
        </head>
        <body>
            <video id="video" playsinline autoplay muted></video>
            <script>
            (async function() {
                const video = document.getElementById('video');
                const pc = new RTCPeerConnection({
                    iceServers: [{ urls: 'stun:stun.l.google.com:19302' }]
                });
                
                pc.ontrack = (e) => { video.srcObject = e.streams[0]; };
                pc.addTransceiver('video', { direction: 'recvonly' });
                pc.addTransceiver('audio', { direction: 'recvonly' });
                
                const offer = await pc.createOffer();
                await pc.setLocalDescription(offer);
                
                const res = await fetch('\(streamURL)', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/sdp' },
                    body: offer.sdp
                });
                
                if (res.ok) {
                    const answer = await res.text();
                    await pc.setRemoteDescription({ type: 'answer', sdp: answer });
                }
            })();
            </script>
        </body>
        </html>
        """
    }
    
    // MARK: - Disk Persistence
    
    private func saveThumbnail(_ image: UIImage, for cameraId: String) {
        fetchQueue.async {
            guard let data = image.jpegData(compressionQuality: 0.7) else { return }
            
            let fileURL = self.cacheDirectory.appendingPathComponent("\(cameraId).jpg")
            try? data.write(to: fileURL)
        }
    }
    
    private func loadCachedThumbnails() {
        fetchQueue.async {
            guard let files = try? self.fileManager.contentsOfDirectory(at: self.cacheDirectory, includingPropertiesForKeys: nil) else {
                return
            }
            
            DispatchQueue.main.async {
                for file in files where file.pathExtension == "jpg" {
                    let cameraId = file.deletingPathExtension().lastPathComponent
                    
                    if let data = try? Data(contentsOf: file),
                       let image = UIImage(data: data) {
                        self.thumbnails[cameraId] = image
                        self.cache.setObject(image, forKey: cameraId as NSString)
                    }
                }
                
                DebugLogger.shared.log("📦 Loaded \(self.thumbnails.count) cached thumbnails", emoji: "📦", color: .blue)
            }
        }
    }
    
    // MARK: - Cleanup
    
    func clearThumbnail(for cameraId: String) {
        lock.lock()
        thumbnails.removeValue(forKey: cameraId)
        cache.removeObject(forKey: cameraId as NSString)
        lock.unlock()
        
        let fileURL = cacheDirectory.appendingPathComponent("\(cameraId).jpg")
        try? fileManager.removeItem(at: fileURL)
    }
    
    func clearAllThumbnails() {
        lock.lock()
        thumbnails.removeAll()
        cache.removeAllObjects()
        lock.unlock()
        
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        DebugLogger.shared.log("🗑️ All thumbnails cleared", emoji: "🗑️", color: .red)
    }
    
    private func removeFetchTask(for cameraId: String) {
        lock.lock()
        activeFetches.removeValue(forKey: cameraId)
        lock.unlock()
    }
    
    // MARK: - Batch Operations
    
    func prefetchThumbnails(for cameras: [Camera], maxConcurrent: Int = 3) {
        let onlineCameras = cameras.filter { $0.isOnline && getThumbnail(for: $0.id) == nil }
        
        // Limit concurrent fetches
        let batch = Array(onlineCameras.prefix(maxConcurrent))
        
        for camera in batch {
            fetchThumbnail(for: camera)
        }
    }
}