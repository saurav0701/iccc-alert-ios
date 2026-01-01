import Foundation
import UIKit
import WebKit
import Combine

// MARK: - Thumbnail Cache Manager (Smart Queue Management)
class ThumbnailCacheManager: ObservableObject {
    static let shared = ThumbnailCacheManager()
    
    @Published private(set) var thumbnails: [String: UIImage] = [:]
    
    private let cache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private var activeFetches: Set<String> = []
    private var captureWebViews: [String: WKWebView] = [:]
    private let lock = NSLock()
    
    // Smart rate limiting
    private var lastFetchTime: [String: Date] = [:]
    private let minFetchInterval: TimeInterval = 2.0
    private var activeWebViewCount = 0
    private let maxConcurrentWebViews = 3 // Allow 3 concurrent captures
    private var fetchQueue: [Camera] = [] // Simple FIFO queue
    
    private init() {
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = paths[0].appendingPathComponent("CameraThumbnails")
        
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        cache.countLimit = 100
        cache.totalCostLimit = 30 * 1024 * 1024 // 30MB
        
        loadCachedThumbnails()
        
        DebugLogger.shared.log("🖼️ ThumbnailCacheManager initialized", emoji: "🖼️", color: .blue)
    }
    
    // MARK: - Get Thumbnail
    
    func getThumbnail(for cameraId: String) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        
        if let cached = cache.object(forKey: cameraId as NSString) {
            return cached
        }
        
        return thumbnails[cameraId]
    }
    
    // MARK: - Fetch Thumbnail (Smart Queue)
    
    func fetchThumbnail(for camera: Camera, force: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        
        // Check if already fetching
        if activeFetches.contains(camera.id) && !force {
            return
        }
        
        // Check if already cached (unless forcing refresh)
        if !force && getThumbnail(for: camera.id) != nil {
            return
        }
        
        // Rate limiting check
        if let lastFetch = lastFetchTime[camera.id] {
            let timeSinceLastFetch = Date().timeIntervalSince(lastFetch)
            if timeSinceLastFetch < minFetchInterval && !force {
                return
            }
        }
        
        // Check concurrent limit
        if activeWebViewCount >= maxConcurrentWebViews {
            // Add to queue if not already queued
            if !fetchQueue.contains(where: { $0.id == camera.id }) {
                fetchQueue.append(camera)
                DebugLogger.shared.log("📋 Queued: \(camera.displayName) (queue: \(fetchQueue.count))", emoji: "📋", color: .gray)
            }
            return
        }
        
        // Start fetch immediately
        startFetch(for: camera)
    }
    
    private func startFetch(for camera: Camera) {
        activeFetches.insert(camera.id)
        lastFetchTime[camera.id] = Date()
        activeWebViewCount += 1
        
        DebugLogger.shared.log("📸 Capturing [\(activeWebViewCount)/\(maxConcurrentWebViews)]: \(camera.displayName)", emoji: "📸", color: .blue)
        
        DispatchQueue.main.async {
            self.captureFromStream(camera: camera)
        }
    }
    
    private func processQueue() {
        lock.lock()
        
        // Process as many items as we have slots
        while activeWebViewCount < maxConcurrentWebViews && !fetchQueue.isEmpty {
            let camera = fetchQueue.removeFirst()
            
            // Skip if already cached or fetching
            if getThumbnail(for: camera.id) != nil || activeFetches.contains(camera.id) {
                continue
            }
            
            lock.unlock()
            startFetch(for: camera)
            lock.lock()
        }
        
        lock.unlock()
    }
    
    // MARK: - Capture from Stream
    
    private func captureFromStream(camera: Camera) {
        guard let streamURL = camera.webrtcStreamURL else {
            DebugLogger.shared.log("⚠️ No stream URL for: \(camera.displayName)", emoji: "⚠️", color: .orange)
            finishFetch(for: camera.id)
            return
        }
        
        // Create invisible WebView for capture
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        config.websiteDataStore = .nonPersistent()
        
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        
        // Setup capture callback
        config.userContentController.add(
            ThumbnailCaptureHandler(cameraId: camera.id, manager: self),
            name: "captureComplete"
        )
        
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.backgroundColor = .black
        webView.isOpaque = true
        webView.alpha = 0.01
        
        // Add to window hierarchy (invisible)
        DispatchQueue.main.async {
            if let window = UIApplication.shared.windows.first {
                window.addSubview(webView)
                webView.frame = CGRect(x: -1000, y: -1000, width: 320, height: 240)
            }
        }
        
        lock.lock()
        captureWebViews[camera.id] = webView
        lock.unlock()
        
        // Load stream HTML
        let html = generateCaptureHTML(streamURL: streamURL)
        webView.loadHTMLString(html, baseURL: nil)
        
        // Timeout after 10 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            guard let self = self else { return }
            
            self.lock.lock()
            let stillActive = self.activeFetches.contains(camera.id)
            self.lock.unlock()
            
            if stillActive {
                DebugLogger.shared.log("⏱️ Timeout: \(camera.displayName)", emoji: "⏱️", color: .orange)
                self.cleanupCaptureWebView(for: camera.id)
                self.finishFetch(for: camera.id)
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
                * { margin: 0; padding: 0; }
                body { width: 320px; height: 240px; background: #000; overflow: hidden; }
                video { width: 100%; height: 100%; object-fit: cover; }
                canvas { display: none; }
            </style>
        </head>
        <body>
            <video id="video" playsinline autoplay muted></video>
            <canvas id="canvas"></canvas>
            <script>
            (function() {
                const video = document.getElementById('video');
                const canvas = document.getElementById('canvas');
                const ctx = canvas.getContext('2d');
                const streamUrl = '\(streamURL)';
                let pc = null, captured = false;
                
                async function start() {
                    try {
                        pc = new RTCPeerConnection({
                            iceServers: [{ urls: 'stun:stun.l.google.com:19302' }]
                        });
                        
                        pc.ontrack = (e) => { video.srcObject = e.streams[0]; };
                        
                        pc.addTransceiver('video', { direction: 'recvonly' });
                        pc.addTransceiver('audio', { direction: 'recvonly' });
                        
                        const offer = await pc.createOffer();
                        await pc.setLocalDescription(offer);
                        
                        const controller = new AbortController();
                        setTimeout(() => controller.abort(), 8000);
                        
                        const res = await fetch(streamUrl, {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/sdp' },
                            body: offer.sdp,
                            signal: controller.signal
                        });
                        
                        if (!res.ok) throw new Error('Server: ' + res.status);
                        
                        const answer = await res.text();
                        await pc.setRemoteDescription({ type: 'answer', sdp: answer });
                        
                    } catch(err) {
                        if (window.webkit?.messageHandlers?.captureComplete) {
                            window.webkit.messageHandlers.captureComplete.postMessage({ 
                                success: false, error: err.toString()
                            });
                        }
                    }
                }
                
                video.addEventListener('playing', () => {
                    if (captured) return;
                    captured = true;
                    
                    setTimeout(() => {
                        try {
                            const width = video.videoWidth || 320;
                            const height = video.videoHeight || 240;
                            
                            canvas.width = width;
                            canvas.height = height;
                            ctx.drawImage(video, 0, 0, width, height);
                            
                            const imageData = canvas.toDataURL('image/jpeg', 0.75);
                            
                            if (window.webkit?.messageHandlers?.captureComplete) {
                                window.webkit.messageHandlers.captureComplete.postMessage({
                                    success: true, imageData: imageData
                                });
                            }
                        } catch(err) {
                            if (window.webkit?.messageHandlers?.captureComplete) {
                                window.webkit.messageHandlers.captureComplete.postMessage({ 
                                    success: false, error: err.toString()
                                });
                            }
                        }
                    }, 500);
                });
                
                start();
            })();
            </script>
        </body>
        </html>
        """
    }
    
    // MARK: - Handle Captured Image
    
    func handleCapturedImage(cameraId: String, imageDataURL: String) {
        DebugLogger.shared.log("📷 Captured: \(cameraId)", emoji: "📷", color: .green)
        
        guard let commaIndex = imageDataURL.firstIndex(of: ",") else {
            cleanupCaptureWebView(for: cameraId)
            finishFetch(for: cameraId)
            return
        }
        
        let base64String = String(imageDataURL[imageDataURL.index(after: commaIndex)...])
        
        guard let imageData = Data(base64Encoded: base64String),
              let image = UIImage(data: imageData) else {
            cleanupCaptureWebView(for: cameraId)
            finishFetch(for: cameraId)
            return
        }
        
        // Normalize and resize image
        let normalizedImage = normalizeImage(image)
        let resizedImage = resizeImageToFit(normalizedImage, targetSize: CGSize(width: 320, height: 240))
        
        // Save to cache
        DispatchQueue.main.async {
            self.thumbnails[cameraId] = resizedImage
            self.cache.setObject(resizedImage, forKey: cameraId as NSString)
            
            DebugLogger.shared.log("✅ Saved thumbnail: \(cameraId)", emoji: "✅", color: .green)
            
            // Save to disk asynchronously
            self.saveThumbnail(resizedImage, for: cameraId)
            
            // Cleanup
            self.cleanupCaptureWebView(for: cameraId)
            self.finishFetch(for: cameraId)
        }
    }
    
    // MARK: - Image Processing
    
    private func normalizeImage(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        
        UIGraphicsBeginImageContextWithOptions(image.size, true, 1.0)
        defer { UIGraphicsEndImageContext() }
        
        image.draw(in: CGRect(origin: .zero, size: image.size))
        return UIGraphicsGetImageFromCurrentImageContext() ?? image
    }
    
    private func resizeImageToFit(_ image: UIImage, targetSize: CGSize) -> UIImage {
        let widthRatio = targetSize.width / image.size.width
        let heightRatio = targetSize.height / image.size.height
        let scale = min(widthRatio, heightRatio)
        
        let scaledSize = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        
        UIGraphicsBeginImageContextWithOptions(targetSize, true, 1.0)
        defer { UIGraphicsEndImageContext() }
        
        // Fill background with black
        UIColor.black.setFill()
        UIRectFill(CGRect(origin: .zero, size: targetSize))
        
        // Center the image
        let origin = CGPoint(
            x: (targetSize.width - scaledSize.width) / 2,
            y: (targetSize.height - scaledSize.height) / 2
        )
        
        image.draw(in: CGRect(origin: origin, size: scaledSize))
        return UIGraphicsGetImageFromCurrentImageContext() ?? image
    }
    
    // MARK: - Cleanup & Queue Management
    
    func finishFetch(for cameraId: String) {
        lock.lock()
        activeFetches.remove(cameraId)
        activeWebViewCount -= 1
        lock.unlock()
        
        // Process queue immediately
        processQueue()
    }
    
    func cleanupCaptureWebView(for cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        if let webView = captureWebViews.removeValue(forKey: cameraId) {
            DispatchQueue.main.async {
                webView.stopLoading()
                webView.loadHTMLString("", baseURL: nil)
                webView.configuration.userContentController.removeAllScriptMessageHandlers()
                webView.removeFromSuperview()
            }
        }
    }
    
    // MARK: - Disk Persistence
    
    private func saveThumbnail(_ image: UIImage, for cameraId: String) {
        DispatchQueue.global(qos: .utility).async {
            guard let data = image.jpegData(compressionQuality: 0.75) else { return }
            let fileURL = self.cacheDirectory.appendingPathComponent("\(cameraId).jpg")
            try? data.write(to: fileURL)
        }
    }
    
    private func loadCachedThumbnails() {
        DispatchQueue.global(qos: .utility).async {
            guard let files = try? self.fileManager.contentsOfDirectory(
                at: self.cacheDirectory,
                includingPropertiesForKeys: nil
            ) else { return }
            
            var loadedCount = 0
            
            for file in files where file.pathExtension == "jpg" {
                let cameraId = file.deletingPathExtension().lastPathComponent
                
                if let data = try? Data(contentsOf: file),
                   let image = UIImage(data: data) {
                    let normalized = self.normalizeImage(image)
                    
                    DispatchQueue.main.async {
                        self.thumbnails[cameraId] = normalized
                        self.cache.setObject(normalized, forKey: cameraId as NSString)
                    }
                    
                    loadedCount += 1
                }
            }
            
            DispatchQueue.main.async {
                DebugLogger.shared.log("📦 Loaded \(loadedCount) cached thumbnails", emoji: "📦", color: .blue)
            }
        }
    }
    
    func clearThumbnail(for cameraId: String) {
        lock.lock()
        thumbnails.removeValue(forKey: cameraId)
        cache.removeObject(forKey: cameraId as NSString)
        lock.unlock()
        
        cleanupCaptureWebView(for: cameraId)
        
        let fileURL = cacheDirectory.appendingPathComponent("\(cameraId).jpg")
        try? fileManager.removeItem(at: fileURL)
    }
    
    func clearAllThumbnails() {
        lock.lock()
        thumbnails.removeAll()
        cache.removeAllObjects()
        activeFetches.removeAll()
        fetchQueue.removeAll()
        let webViews = captureWebViews
        captureWebViews.removeAll()
        activeWebViewCount = 0
        lock.unlock()
        
        for (cameraId, _) in webViews {
            cleanupCaptureWebView(for: cameraId)
        }
        
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        DebugLogger.shared.log("🗑️ Cleared all thumbnails", emoji: "🗑️", color: .red)
    }
    
    func clearChannelThumbnails() {
        lock.lock()
        thumbnails.removeAll()
        fetchQueue.removeAll()
        lock.unlock()
        
        DebugLogger.shared.log("🧹 Cleared channel thumbnails from memory", emoji: "🧹", color: .orange)
    }
}

// MARK: - Handlers
class ThumbnailCaptureHandler: NSObject, WKScriptMessageHandler {
    let cameraId: String
    weak var manager: ThumbnailCacheManager?
    
    init(cameraId: String, manager: ThumbnailCacheManager) {
        self.cameraId = cameraId
        self.manager = manager
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "captureComplete",
              let dict = message.body as? [String: Any] else { return }
        
        if let success = dict["success"] as? Bool, success,
           let imageData = dict["imageData"] as? String {
            manager?.handleCapturedImage(cameraId: cameraId, imageDataURL: imageData)
        } else {
            manager?.cleanupCaptureWebView(for: cameraId)
            manager?.finishFetch(for: cameraId)
        }
    }
}