import Foundation
import UIKit
import WebKit
import Combine

// MARK: - Thumbnail Cache Manager (Crash-Proof with Smart Queue)
class ThumbnailCacheManager: ObservableObject {
    static let shared = ThumbnailCacheManager()
    
    @Published private(set) var thumbnails: [String: UIImage] = [:]
    @Published private(set) var thumbnailTimestamps: [String: Date] = [:]
    @Published private(set) var failedCameras: Set<String> = []
    @Published private(set) var loadingCameras: Set<String> = []
    
    private let cache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    
    // CRITICAL: Strict concurrency limits
    private var activeFetches: Set<String> = []
    private var pendingQueue: [(Camera, ((Bool) -> Void)?)] = []
    private let lock = NSLock()
    
    // Single shared WebView for ALL captures (reused)
    private var captureWebView: WKWebView?
    private var currentCapture: String?
    private var captureCompletion: ((Bool) -> Void)?
    
    // Retry tracking
    private var retryAttempts: [String: Int] = [:]
    private let maxAutoRetries = 2
    
    // Cache duration: 3 hours
    private let cacheDuration: TimeInterval = 3 * 60 * 60
    
    // CRITICAL: Only 1 concurrent capture at a time
    private let maxConcurrentCaptures = 1
    
    private var processingTimer: Timer?
    
    private init() {
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = paths[0].appendingPathComponent("CameraThumbnails")
        
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        cache.countLimit = 100 // Reduced from 200
        cache.totalCostLimit = 30 * 1024 * 1024 // Reduced to 30MB
        
        loadCachedThumbnails()
        loadTimestamps()
        
        // Start queue processor
        startQueueProcessor()
        
        DebugLogger.shared.log("🖼️ ThumbnailCacheManager initialized (crash-proof mode)", emoji: "🖼️", color: .blue)
    }
    
    // MARK: - Queue Processor
    
    private func startQueueProcessor() {
        processingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.processQueue()
        }
    }
    
    private func processQueue() {
        lock.lock()
        
        // Check if we can process next item
        guard activeFetches.count < maxConcurrentCaptures,
              !pendingQueue.isEmpty,
              currentCapture == nil else {
            lock.unlock()
            return
        }
        
        // Get next camera from queue
        let (camera, completion) = pendingQueue.removeFirst()
        lock.unlock()
        
        // Process this capture
        _startCapture(for: camera, completion: completion)
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
    
    func isLoading(for cameraId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return loadingCameras.contains(cameraId) || currentCapture == cameraId
    }
    
    func hasFailed(for cameraId: String) -> Bool {
        return failedCameras.contains(cameraId)
    }
    
    func isThumbnailFresh(for cameraId: String) -> Bool {
        guard let timestamp = thumbnailTimestamps[cameraId] else {
            return false
        }
        
        let age = Date().timeIntervalSince(timestamp)
        return age < cacheDuration
    }
    
    // MARK: - Auto Fetch (Queue-Based)
    
    func autoFetchThumbnail(for camera: Camera) {
        guard camera.isOnline else { return }
        
        // Don't auto-load if already have fresh thumbnail
        if isThumbnailFresh(for: camera.id) {
            return
        }
        
        // Don't auto-load if already loading or failed too many times
        lock.lock()
        let isLoading = loadingCameras.contains(camera.id) || currentCapture == camera.id
        let attempts = retryAttempts[camera.id] ?? 0
        let isQueued = pendingQueue.contains(where: { $0.0.id == camera.id })
        lock.unlock()
        
        if isLoading || attempts >= maxAutoRetries || isQueued {
            return
        }
        
        // Add to queue
        lock.lock()
        pendingQueue.append((camera, nil))
        loadingCameras.insert(camera.id)
        lock.unlock()
    }
    
    // MARK: - Manual Refresh
    
    func manualRefresh(for camera: Camera, completion: @escaping (Bool) -> Void) {
        // Reset retry counter
        retryAttempts[camera.id] = 0
        failedCameras.remove(camera.id)
        
        DebugLogger.shared.log("🔄 Manual refresh: \(camera.displayName)", emoji: "🔄", color: .blue)
        
        // Add to front of queue (priority)
        lock.lock()
        pendingQueue.insert((camera, completion), at: 0)
        loadingCameras.insert(camera.id)
        lock.unlock()
    }
    
    // MARK: - Core Capture Logic (Single WebView)
    
    private func _startCapture(for camera: Camera, completion: ((Bool) -> Void)?) {
        guard let streamURL = camera.webrtcStreamURL else {
            DebugLogger.shared.log("⚠️ No stream URL: \(camera.id)", emoji: "⚠️", color: .orange)
            markAsFailed(camera.id, isManual: completion != nil)
            finishCapture(camera.id, success: false, completion: completion)
            return
        }
        
        lock.lock()
        currentCapture = camera.id
        captureCompletion = completion
        activeFetches.insert(camera.id)
        lock.unlock()
        
        DebugLogger.shared.log("📸 Starting capture: \(camera.displayName)", emoji: "📸", color: .blue)
        
        // Use or create the shared WebView
        DispatchQueue.main.async {
            self.setupCaptureWebView(streamURL: streamURL, cameraId: camera.id)
        }
        
        // Timeout: 12 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) { [weak self] in
            guard let self = self else { return }
            
            self.lock.lock()
            let stillActive = self.currentCapture == camera.id
            self.lock.unlock()
            
            if stillActive {
                DebugLogger.shared.log("⏱️ Timeout: \(camera.id)", emoji: "⏱️", color: .orange)
                self.markAsFailed(camera.id, isManual: completion != nil)
                self.finishCapture(camera.id, success: false, completion: completion)
            }
        }
    }
    
    private func setupCaptureWebView(streamURL: String, cameraId: String) {
        // Clean up existing WebView if any
        if let existing = captureWebView {
            existing.stopLoading()
            existing.loadHTMLString("", baseURL: nil)
            existing.configuration.userContentController.removeAllScriptMessageHandlers()
            existing.removeFromSuperview()
            captureWebView = nil
        }
        
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        config.websiteDataStore = .nonPersistent()
        
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        
        config.userContentController.add(
            ThumbnailCaptureHandler(cameraId: cameraId, manager: self),
            name: "captureComplete"
        )
        
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.backgroundColor = .black
        webView.isOpaque = true
        webView.alpha = 0.01
        
        if let window = UIApplication.shared.windows.first {
            window.addSubview(webView)
            webView.frame = CGRect(x: -1000, y: -1000, width: 320, height: 240)
        }
        
        captureWebView = webView
        
        let html = generateCaptureHTML(streamURL: streamURL)
        webView.loadHTMLString(html, baseURL: nil)
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
                body { width: 320px; height: 240px; background: #000; }
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
                let pc = null;
                let captured = false;
                
                async function start() {
                    try {
                        pc = new RTCPeerConnection({
                            iceServers: [{ urls: 'stun:stun.l.google.com:19302' }]
                        });
                        
                        pc.ontrack = (e) => {
                            video.srcObject = e.streams[0];
                        };
                        
                        pc.addTransceiver('video', { direction: 'recvonly' });
                        pc.addTransceiver('audio', { direction: 'recvonly' });
                        
                        const offer = await pc.createOffer();
                        await pc.setLocalDescription(offer);
                        
                        const controller = new AbortController();
                        const timeoutId = setTimeout(() => controller.abort(), 10000);
                        
                        const res = await fetch(streamUrl, {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/sdp' },
                            body: offer.sdp,
                            signal: controller.signal
                        });
                        
                        clearTimeout(timeoutId);
                        
                        if (!res.ok) throw new Error('Server error');
                        
                        const answer = await res.text();
                        await pc.setRemoteDescription({ type: 'answer', sdp: answer });
                        
                    } catch(err) {
                        if (window.webkit?.messageHandlers?.captureComplete) {
                            window.webkit.messageHandlers.captureComplete.postMessage({ 
                                success: false,
                                error: err.toString()
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
                            
                            const imageData = canvas.toDataURL('image/jpeg', 0.7);
                            
                            if (window.webkit?.messageHandlers?.captureComplete) {
                                window.webkit.messageHandlers.captureComplete.postMessage({
                                    success: true,
                                    imageData: imageData
                                });
                            }
                            
                            // Clean up immediately after capture
                            if (pc) {
                                pc.close();
                                pc = null;
                            }
                            if (video.srcObject) {
                                video.srcObject.getTracks().forEach(t => t.stop());
                                video.srcObject = null;
                            }
                        } catch(err) {
                            if (window.webkit?.messageHandlers?.captureComplete) {
                                window.webkit.messageHandlers.captureComplete.postMessage({ 
                                    success: false,
                                    error: err.toString()
                                });
                            }
                        }
                    }, 300);
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
        DebugLogger.shared.log("📷 Received capture: \(cameraId)", emoji: "📷", color: .green)
        
        guard let commaIndex = imageDataURL.firstIndex(of: ",") else {
            DebugLogger.shared.log("❌ Invalid image data", emoji: "❌", color: .red)
            markAsFailed(cameraId, isManual: false)
            finishCapture(cameraId, success: false, completion: nil)
            return
        }
        
        let base64String = String(imageDataURL[imageDataURL.index(after: commaIndex)...])
        
        guard let imageData = Data(base64Encoded: base64String),
              let image = UIImage(data: imageData) else {
            DebugLogger.shared.log("❌ Failed to decode", emoji: "❌", color: .red)
            markAsFailed(cameraId, isManual: false)
            finishCapture(cameraId, success: false, completion: nil)
            return
        }
        
        let resizedImage = resizeImage(image, targetWidth: 320)
        
        DispatchQueue.main.async {
            self.thumbnails[cameraId] = resizedImage
            self.cache.setObject(resizedImage, forKey: cameraId as NSString)
            self.thumbnailTimestamps[cameraId] = Date()
            
            // Success - reset retry counter
            self.retryAttempts[cameraId] = 0
            self.failedCameras.remove(cameraId)
            
            DebugLogger.shared.log("✅ Thumbnail saved: \(cameraId)", emoji: "✅", color: .green)
            
            self.saveThumbnail(resizedImage, for: cameraId)
            self.saveTimestamps()
            
            self.finishCapture(cameraId, success: true, completion: nil)
        }
    }
    
    func handleCaptureFailed(cameraId: String) {
        markAsFailed(cameraId, isManual: false)
        finishCapture(cameraId, success: false, completion: nil)
    }
    
    private func finishCapture(_ cameraId: String, success: Bool, completion: ((Bool) -> Void)?) {
        lock.lock()
        let captureCompletion = self.captureCompletion
        
        currentCapture = nil
        self.captureCompletion = nil
        activeFetches.remove(cameraId)
        loadingCameras.remove(cameraId)
        lock.unlock()
        
        // Call completion
        DispatchQueue.main.async {
            completion?(success)
            captureCompletion?(success)
        }
    }
    
    // MARK: - Mark as Failed
    
    private func markAsFailed(_ cameraId: String, isManual: Bool) {
        if !isManual {
            let attempts = (retryAttempts[cameraId] ?? 0) + 1
            retryAttempts[cameraId] = attempts
            
            if attempts >= maxAutoRetries {
                failedCameras.insert(cameraId)
                DebugLogger.shared.log("❌ Max retries: \(cameraId)", emoji: "❌", color: .red)
            }
        } else {
            failedCameras.insert(cameraId)
        }
    }
    
    // MARK: - Image Utilities
    
    private func resizeImage(_ image: UIImage, targetWidth: CGFloat) -> UIImage {
        let scale = targetWidth / image.size.width
        let targetHeight = image.size.height * scale
        let targetSize = CGSize(width: targetWidth, height: targetHeight)
        
        UIGraphicsBeginImageContextWithOptions(targetSize, true, 1.0)
        image.draw(in: CGRect(origin: .zero, size: targetSize))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return resizedImage ?? image
    }
    
    // MARK: - Disk Persistence
    
    private func saveThumbnail(_ image: UIImage, for cameraId: String) {
        DispatchQueue.global(qos: .background).async {
            guard let data = image.jpegData(compressionQuality: 0.7) else { return }
            let fileURL = self.cacheDirectory.appendingPathComponent("\(cameraId).jpg")
            try? data.write(to: fileURL)
        }
    }
    
    private func saveTimestamps() {
        DispatchQueue.global(qos: .background).async {
            let timestamps = self.thumbnailTimestamps.mapValues { $0.timeIntervalSince1970 }
            UserDefaults.standard.set(timestamps, forKey: "thumbnail_timestamps")
        }
    }
    
    private func loadTimestamps() {
        if let saved = UserDefaults.standard.dictionary(forKey: "thumbnail_timestamps") as? [String: TimeInterval] {
            thumbnailTimestamps = saved.mapValues { Date(timeIntervalSince1970: $0) }
        }
    }
    
    private func loadCachedThumbnails() {
        DispatchQueue.global(qos: .background).async {
            guard let files = try? self.fileManager.contentsOfDirectory(
                at: self.cacheDirectory,
                includingPropertiesForKeys: nil
            ) else {
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
    
    func clearThumbnail(for cameraId: String) {
        lock.lock()
        thumbnails.removeValue(forKey: cameraId)
        thumbnailTimestamps.removeValue(forKey: cameraId)
        cache.removeObject(forKey: cameraId as NSString)
        failedCameras.remove(cameraId)
        retryAttempts.removeValue(forKey: cameraId)
        
        // Remove from queue if present
        pendingQueue.removeAll(where: { $0.0.id == cameraId })
        loadingCameras.remove(cameraId)
        lock.unlock()
        
        let fileURL = cacheDirectory.appendingPathComponent("\(cameraId).jpg")
        try? fileManager.removeItem(at: fileURL)
    }
    
    func clearAllThumbnails() {
        lock.lock()
        thumbnails.removeAll()
        thumbnailTimestamps.removeAll()
        failedCameras.removeAll()
        retryAttempts.removeAll()
        cache.removeAllObjects()
        activeFetches.removeAll()
        pendingQueue.removeAll()
        loadingCameras.removeAll()
        currentCapture = nil
        captureCompletion = nil
        lock.unlock()
        
        // Clean up WebView
        if let webView = captureWebView {
            DispatchQueue.main.async {
                webView.stopLoading()
                webView.loadHTMLString("", baseURL: nil)
                webView.configuration.userContentController.removeAllScriptMessageHandlers()
                webView.removeFromSuperview()
            }
            captureWebView = nil
        }
        
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        UserDefaults.standard.removeObject(forKey: "thumbnail_timestamps")
        
        DebugLogger.shared.log("🗑️ All thumbnails cleared", emoji: "🗑️", color: .red)
    }
    
    func clearChannelThumbnails() {
        // Just clear from memory, keep cache
        lock.lock()
        let keysToRemove = Array(thumbnails.keys)
        lock.unlock()
        
        for key in keysToRemove {
            cache.removeObject(forKey: key as NSString)
        }
        
        DebugLogger.shared.log("🧹 Channel thumbnails cleared from memory", emoji: "🧹", color: .orange)
    }
    
    deinit {
        processingTimer?.invalidate()
    }
}

// MARK: - Capture Handler
class ThumbnailCaptureHandler: NSObject, WKScriptMessageHandler {
    let cameraId: String
    weak var manager: ThumbnailCacheManager?
    
    init(cameraId: String, manager: ThumbnailCacheManager) {
        self.cameraId = cameraId
        self.manager = manager
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "captureComplete",
              let dict = message.body as? [String: Any] else {
            manager?.handleCaptureFailed(cameraId: cameraId)
            return
        }
        
        if let success = dict["success"] as? Bool, success,
           let imageData = dict["imageData"] as? String {
            manager?.handleCapturedImage(cameraId: cameraId, imageDataURL: imageData)
        } else {
            manager?.handleCaptureFailed(cameraId: cameraId)
        }
    }
}