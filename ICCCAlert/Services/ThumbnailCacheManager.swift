import Foundation
import UIKit
import WebKit
import Combine

// MARK: - Thumbnail Cache Manager (CRASH-PROOF VERSION)
class ThumbnailCacheManager: ObservableObject {
    static let shared = ThumbnailCacheManager()
    
    @Published private(set) var thumbnails: [String: UIImage] = [:]
    @Published private(set) var thumbnailTimestamps: [String: Date] = [:]
    @Published private(set) var failedCameras: Set<String> = []
    @Published private(set) var loadingCameras: Set<String> = []
    
    private let cache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private var activeFetches: Set<String> = []
    private var captureWebViews: [String: WKWebView] = [:]
    private let lock = NSLock()
    
    // Retry tracking
    private var retryAttempts: [String: Int] = [:]
    private let maxAutoRetries = 2 // Reduced from 3
    
    // Cache duration: 3 hours
    private let cacheDuration: TimeInterval = 3 * 60 * 60
    
    // ✅ CRITICAL: Strict limits to prevent crashes
    private let maxConcurrentFetches = 2 // Reduced from 3
    private var fetchQueue: [Camera] = []
    private var isFetchQueueProcessing = false
    
    // ✅ Timeout tracking
    private var captureTimeouts: [String: DispatchWorkItem] = [:]
    
    private init() {
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = paths[0].appendingPathComponent("CameraThumbnails")
        
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        cache.countLimit = 100 // Reduced from 200
        cache.totalCostLimit = 30 * 1024 * 1024 // Reduced to 30MB
        
        loadCachedThumbnails()
        loadTimestamps()
        
        // ✅ Monitor memory warnings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        
        DebugLogger.shared.log("🖼️ ThumbnailCacheManager initialized (Crash-Proof)", emoji: "🖼️", color: .blue)
    }
    
    @objc private func handleMemoryWarning() {
        DebugLogger.shared.log("⚠️ Memory warning - clearing thumbnail cache", emoji: "⚠️", color: .orange)
        
        lock.lock()
        
        // Cancel all pending fetches
        for workItem in captureTimeouts.values {
            workItem.cancel()
        }
        captureTimeouts.removeAll()
        
        // Clear all active webviews
        let webViews = captureWebViews
        captureWebViews.removeAll()
        
        lock.unlock()
        
        // Cleanup webviews on main thread
        DispatchQueue.main.async {
            for (cameraId, webView) in webViews {
                self.cleanupWebViewSafely(webView, cameraId: cameraId)
            }
        }
        
        // Clear in-memory cache
        cache.removeAllObjects()
        
        DebugLogger.shared.log("🧹 Thumbnail cache cleared due to memory pressure", emoji: "🧹", color: .orange)
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
        return loadingCameras.contains(cameraId)
    }
    
    func hasFailed(for cameraId: String) -> Bool {
        return failedCameras.contains(cameraId)
    }
    
    // MARK: - Check if Thumbnail is Fresh
    
    func isThumbnailFresh(for cameraId: String) -> Bool {
        guard let timestamp = thumbnailTimestamps[cameraId] else {
            return false
        }
        
        let age = Date().timeIntervalSince(timestamp)
        return age < cacheDuration
    }
    
    // MARK: - Check if Should Auto-Load
    
    private func shouldAutoLoad(for cameraId: String) -> Bool {
        // Don't auto-load if already have fresh thumbnail
        if isThumbnailFresh(for: cameraId) {
            return false
        }
        
        // Don't auto-load if already loading
        if loadingCameras.contains(cameraId) {
            return false
        }
        
        // Don't auto-load if exceeded retry attempts
        if let attempts = retryAttempts[cameraId], attempts >= maxAutoRetries {
            return false
        }
        
        return true
    }
    
    // MARK: - Auto Fetch (Queue-Based)
    
    func autoFetchThumbnail(for camera: Camera) {
        guard camera.isOnline else { return }
        guard shouldAutoLoad(for: camera.id) else { return }
        
        lock.lock()
        
        // Check if at capacity
        if activeFetches.count >= maxConcurrentFetches {
            // Add to queue
            if !fetchQueue.contains(where: { $0.id == camera.id }) {
                fetchQueue.append(camera)
            }
            lock.unlock()
            return
        }
        
        lock.unlock()
        
        // Small delay to prevent all thumbnails loading at once
        let delay = Double.random(in: 0.1...0.5)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.fetchThumbnail(for: camera, isManual: false)
        }
    }
    
    // MARK: - Process Queue
    
    private func processQueue() {
        lock.lock()
        
        guard !isFetchQueueProcessing else {
            lock.unlock()
            return
        }
        
        guard activeFetches.count < maxConcurrentFetches else {
            lock.unlock()
            return
        }
        
        guard let nextCamera = fetchQueue.first else {
            lock.unlock()
            return
        }
        
        fetchQueue.removeFirst()
        isFetchQueueProcessing = true
        
        lock.unlock()
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.fetchThumbnail(for: nextCamera, isManual: false) { _ in
                self.lock.lock()
                self.isFetchQueueProcessing = false
                self.lock.unlock()
                
                // Process next item
                self.processQueue()
            }
        }
    }
    
    // MARK: - Manual Refresh
    
    func manualRefresh(for camera: Camera, completion: @escaping (Bool) -> Void) {
        // Reset retry counter
        retryAttempts[camera.id] = 0
        failedCameras.remove(camera.id)
        
        DebugLogger.shared.log("🔄 Manual refresh: \(camera.displayName)", emoji: "🔄", color: .blue)
        
        fetchThumbnail(for: camera, isManual: true, completion: completion)
    }
    
    // MARK: - Core Fetch Logic
    
    private func fetchThumbnail(for camera: Camera, isManual: Bool, completion: ((Bool) -> Void)? = nil) {
        lock.lock()
        
        // Check if already fetching
        if activeFetches.contains(camera.id) {
            lock.unlock()
            completion?(false)
            return
        }
        
        // Check capacity
        if activeFetches.count >= maxConcurrentFetches && !isManual {
            lock.unlock()
            
            // Add to queue for later
            lock.lock()
            if !fetchQueue.contains(where: { $0.id == camera.id }) {
                fetchQueue.append(camera)
            }
            lock.unlock()
            
            completion?(false)
            return
        }
        
        activeFetches.insert(camera.id)
        lock.unlock()
        
        DispatchQueue.main.async {
            self.loadingCameras.insert(camera.id)
        }
        
        let logPrefix = isManual ? "🔧" : "📸"
        DebugLogger.shared.log("\(logPrefix) Loading thumbnail: \(camera.displayName)", emoji: logPrefix, color: .blue)
        
        DispatchQueue.main.async {
            self.captureFromStream(camera: camera, isManual: isManual) { success in
                DispatchQueue.main.async {
                    self.loadingCameras.remove(camera.id)
                }
                completion?(success)
                
                // Process next in queue
                self.processQueue()
            }
        }
    }
    
    // MARK: - Capture from Stream
    
    private func captureFromStream(camera: Camera, isManual: Bool, completion: @escaping (Bool) -> Void) {
        guard let streamURL = camera.webrtcStreamURL else {
            DebugLogger.shared.log("⚠️ No stream URL: \(camera.id)", emoji: "⚠️", color: .orange)
            markAsFailed(camera.id, isManual: isManual)
            removeFetchTask(for: camera.id)
            completion(false)
            return
        }
        
        // ✅ Check if webview already exists (memory leak prevention)
        lock.lock()
        if let existingWebView = captureWebViews[camera.id] {
            lock.unlock()
            DebugLogger.shared.log("⚠️ WebView already exists for \(camera.id), cleaning up", emoji: "⚠️", color: .orange)
            cleanupCaptureWebView(for: camera.id)
            
            // Small delay before creating new one
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.createCaptureWebView(camera: camera, streamURL: streamURL, isManual: isManual, completion: completion)
            }
            return
        }
        lock.unlock()
        
        createCaptureWebView(camera: camera, streamURL: streamURL, isManual: isManual, completion: completion)
    }
    
    private func createCaptureWebView(camera: Camera, streamURL: String, isManual: Bool, completion: @escaping (Bool) -> Void) {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        config.websiteDataStore = .nonPersistent()
        
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        
        config.userContentController.add(
            ThumbnailCaptureHandler(cameraId: camera.id, manager: self, completion: completion),
            name: "captureComplete"
        )
        
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.backgroundColor = .black
        webView.isOpaque = true
        webView.alpha = 0.01
        
        DispatchQueue.main.async {
            if let window = UIApplication.shared.windows.first {
                window.addSubview(webView)
                webView.frame = CGRect(x: -1000, y: -1000, width: 320, height: 240)
            }
        }
        
        lock.lock()
        captureWebViews[camera.id] = webView
        lock.unlock()
        
        let html = generateCaptureHTML(streamURL: streamURL)
        webView.loadHTMLString(html, baseURL: nil)
        
        // ✅ Timeout with proper cleanup
        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            self.lock.lock()
            let stillActive = self.activeFetches.contains(camera.id)
            self.lock.unlock()
            
            if stillActive {
                DebugLogger.shared.log("⏱️ Timeout: \(camera.id)", emoji: "⏱️", color: .orange)
                self.markAsFailed(camera.id, isManual: isManual)
                self.cleanupCaptureWebView(for: camera.id)
                self.removeFetchTask(for: camera.id)
                completion(false)
            }
        }
        
        lock.lock()
        captureTimeouts[camera.id] = timeoutWork
        lock.unlock()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 12.0, execute: timeoutWork)
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
                let cleanedUp = false;
                
                function cleanup() {
                    if (cleanedUp) return;
                    cleanedUp = true;
                    
                    try {
                        if (pc) {
                            pc.close();
                            pc = null;
                        }
                        if (video.srcObject) {
                            video.srcObject.getTracks().forEach(t => t.stop());
                            video.srcObject = null;
                        }
                    } catch(e) {
                        console.error('Cleanup error:', e);
                    }
                }
                
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
                        
                        if (!res.ok) throw new Error('Server error: ' + res.status);
                        
                        const answer = await res.text();
                        await pc.setRemoteDescription({ type: 'answer', sdp: answer });
                        
                    } catch(err) {
                        cleanup();
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
                            
                            cleanup();
                            
                            if (window.webkit?.messageHandlers?.captureComplete) {
                                window.webkit.messageHandlers.captureComplete.postMessage({
                                    success: true,
                                    imageData: imageData
                                });
                            }
                        } catch(err) {
                            cleanup();
                            if (window.webkit?.messageHandlers?.captureComplete) {
                                window.webkit.messageHandlers.captureComplete.postMessage({ 
                                    success: false,
                                    error: err.toString()
                                });
                            }
                        }
                    }, 500);
                });
                
                window.addEventListener('beforeunload', cleanup);
                
                start();
            })();
            </script>
        </body>
        </html>
        """
    }
    
    // MARK: - Handle Captured Image
    
    func handleCapturedImage(cameraId: String, imageDataURL: String, completion: @escaping (Bool) -> Void) {
        // Cancel timeout
        lock.lock()
        captureTimeouts[cameraId]?.cancel()
        captureTimeouts.removeValue(forKey: cameraId)
        lock.unlock()
        
        DebugLogger.shared.log("📷 Received capture: \(cameraId)", emoji: "📷", color: .green)
        
        guard let commaIndex = imageDataURL.firstIndex(of: ",") else {
            DebugLogger.shared.log("❌ Invalid image data: \(cameraId)", emoji: "❌", color: .red)
            markAsFailed(cameraId, isManual: false)
            cleanupCaptureWebView(for: cameraId)
            removeFetchTask(for: cameraId)
            completion(false)
            return
        }
        
        let base64String = String(imageDataURL[imageDataURL.index(after: commaIndex)...])
        
        guard let imageData = Data(base64Encoded: base64String),
              let image = UIImage(data: imageData) else {
            DebugLogger.shared.log("❌ Failed to decode: \(cameraId)", emoji: "❌", color: .red)
            markAsFailed(cameraId, isManual: false)
            cleanupCaptureWebView(for: cameraId)
            removeFetchTask(for: cameraId)
            completion(false)
            return
        }
        
        let orientedImage = fixImageOrientation(image)
        let resizedImage = resizeImage(orientedImage, targetWidth: 320)
        
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
            
            self.cleanupCaptureWebView(for: cameraId)
            self.removeFetchTask(for: cameraId)
            
            completion(true)
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
            } else {
                DebugLogger.shared.log("⚠️ Failed (\(attempts)/\(maxAutoRetries)): \(cameraId)", emoji: "⚠️", color: .orange)
            }
        } else {
            failedCameras.insert(cameraId)
            DebugLogger.shared.log("❌ Manual refresh failed: \(cameraId)", emoji: "❌", color: .red)
        }
    }
    
    // MARK: - Image Utilities
    
    private func fixImageOrientation(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up {
            return image
        }
        
        UIGraphicsBeginImageContextWithOptions(image.size, true, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let normalizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return normalizedImage ?? image
    }
    
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
    
    // MARK: - Cleanup
    
    private func cleanupWebViewSafely(_ webView: WKWebView, cameraId: String) {
        DispatchQueue.main.async {
            webView.stopLoading()
            webView.loadHTMLString("", baseURL: nil)
            
            // Remove all message handlers safely
            let userContentController = webView.configuration.userContentController
            userContentController.removeScriptMessageHandler(forName: "captureComplete")
            
            webView.removeFromSuperview()
            
            DebugLogger.shared.log("🧹 Cleaned up webview: \(cameraId)", emoji: "🧹", color: .gray)
        }
    }
    
    func cleanupCaptureWebView(for cameraId: String) {
        lock.lock()
        
        // Cancel timeout
        captureTimeouts[cameraId]?.cancel()
        captureTimeouts.removeValue(forKey: cameraId)
        
        guard let webView = captureWebViews.removeValue(forKey: cameraId) else {
            lock.unlock()
            return
        }
        
        lock.unlock()
        
        cleanupWebViewSafely(webView, cameraId: cameraId)
    }
    
    func removeFetchTask(for cameraId: String) {
        lock.lock()
        activeFetches.remove(cameraId)
        lock.unlock()
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
                        let orientedImage = self.fixImageOrientation(image)
                        self.thumbnails[cameraId] = orientedImage
                        self.cache.setObject(orientedImage, forKey: cameraId as NSString)
                    }
                }
                
                DebugLogger.shared.log("📦 Loaded \(self.thumbnails.count) cached thumbnails", emoji: "📦", color: .blue)
            }
        }
    }
    
    func clearThumbnail(for cameraId: String) {
        lock.lock()
        
        // Cancel any ongoing capture
        captureTimeouts[cameraId]?.cancel()
        captureTimeouts.removeValue(forKey: cameraId)
        
        thumbnails.removeValue(forKey: cameraId)
        thumbnailTimestamps.removeValue(forKey: cameraId)
        cache.removeObject(forKey: cameraId as NSString)
        failedCameras.remove(cameraId)
        retryAttempts.removeValue(forKey: cameraId)
        
        lock.unlock()
        
        cleanupCaptureWebView(for: cameraId)
        
        let fileURL = cacheDirectory.appendingPathComponent("\(cameraId).jpg")
        try? fileManager.removeItem(at: fileURL)
    }
    
    func clearAllThumbnails() {
        lock.lock()
        
        // Cancel all timeouts
        for workItem in captureTimeouts.values {
            workItem.cancel()
        }
        captureTimeouts.removeAll()
        
        thumbnails.removeAll()
        thumbnailTimestamps.removeAll()
        failedCameras.removeAll()
        retryAttempts.removeAll()
        cache.removeAllObjects()
        activeFetches.removeAll()
        fetchQueue.removeAll()
        
        let webViews = captureWebViews
        captureWebViews.removeAll()
        
        lock.unlock()
        
        // Cleanup all webviews
        for (cameraId, webView) in webViews {
            cleanupWebViewSafely(webView, cameraId: cameraId)
        }
        
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        UserDefaults.standard.removeObject(forKey: "thumbnail_timestamps")
        
        DebugLogger.shared.log("🗑️ All thumbnails cleared", emoji: "🗑️", color: .red)
    }
    
    func clearChannelThumbnails() {
        lock.lock()
        let keysToRemove = Array(thumbnails.keys)
        lock.unlock()
        
        for key in keysToRemove {
            cache.removeObject(forKey: key as NSString)
        }
        
        DebugLogger.shared.log("🧹 Channel thumbnails cleared from memory", emoji: "🧹", color: .orange)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - Capture Handler
class ThumbnailCaptureHandler: NSObject, WKScriptMessageHandler {
    let cameraId: String
    weak var manager: ThumbnailCacheManager?
    let completion: (Bool) -> Void
    
    init(cameraId: String, manager: ThumbnailCacheManager, completion: @escaping (Bool) -> Void) {
        self.cameraId = cameraId
        self.manager = manager
        self.completion = completion
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "captureComplete",
              let dict = message.body as? [String: Any] else {
            manager?.cleanupCaptureWebView(for: cameraId)
            manager?.removeFetchTask(for: cameraId)
            completion(false)
            return
        }
        
        if let success = dict["success"] as? Bool, success,
           let imageData = dict["imageData"] as? String {
            manager?.handleCapturedImage(cameraId: cameraId, imageDataURL: imageData, completion: completion)
        } else {
            manager?.cleanupCaptureWebView(for: cameraId)
            manager?.removeFetchTask(for: cameraId)
            completion(false)
        }
    }
}