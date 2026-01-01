import Foundation
import UIKit
import WebKit
import Combine

// MARK: - Thumbnail Cache Manager (Ultra Safe - No Crashes)
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
    
    // ✅ ULTRA STRICT: Only 1 WebView, longer delays
    private let maxConcurrentFetches = 1
    private let maxActiveWebViews = 1  // Changed from 2 to 1
    private var captureQueue: [String] = []
    
    // ✅ Capture timeout reduced to avoid hanging
    private let captureTimeout: TimeInterval = 10.0  // Reduced from 15
    
    // ✅ Memory pressure detection
    private var isUnderMemoryPressure = false
    private var memoryWarningObserver: NSObjectProtocol?
    
    // ✅ Global kill switch
    private var isEnabled = true
    
    private init() {
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = paths[0].appendingPathComponent("CameraThumbnails")
        
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        // ✅ Even more aggressive limits
        cache.countLimit = 30      // Reduced from 50
        cache.totalCostLimit = 15 * 1024 * 1024 // Reduced from 20MB to 15MB
        
        loadCachedThumbnails()
        loadTimestamps()
        setupMemoryWarning()
        
        DebugLogger.shared.log("🖼️ ThumbnailCacheManager initialized (ultra-safe mode)", emoji: "🖼️", color: .blue)
    }
    
    // MARK: - Memory Warning Handler
    
    private func setupMemoryWarning() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMemoryWarning()
        }
    }
    
    private func handleMemoryWarning() {
        DebugLogger.shared.log("⚠️ MEMORY WARNING - Emergency shutdown!", emoji: "🧹", color: .red)
        
        isUnderMemoryPressure = true
        isEnabled = false  // ✅ Disable all thumbnail loading
        
        // 1. Stop ALL captures immediately
        stopAllCaptures()
        
        // 2. Clear everything from memory
        captureQueue.removeAll()
        cache.removeAllObjects()
        thumbnails.removeAll()
        thumbnailTimestamps.removeAll()
        loadingCameras.removeAll()
        
        DebugLogger.shared.log("🧹 Emergency cleanup: Cleared all thumbnails from memory", emoji: "🧹", color: .orange)
        
        // 3. Re-enable after 30 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.isUnderMemoryPressure = false
            self?.isEnabled = true
            DebugLogger.shared.log("✅ Thumbnail loading re-enabled", emoji: "✅", color: .green)
        }
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
    
    // MARK: - Check if Should Load
    
    private func shouldLoad(for cameraId: String) -> Bool {
        // ✅ CRITICAL: Global kill switch
        if !isEnabled {
            return false
        }
        
        // ✅ CRITICAL: Don't load if under memory pressure
        if isUnderMemoryPressure {
            return false
        }
        
        // Don't load if already have thumbnail
        if thumbnails[cameraId] != nil {
            return false
        }
        
        // Don't load if already loading
        if loadingCameras.contains(cameraId) {
            return false
        }
        
        // Don't load if already failed (manual refresh only)
        if failedCameras.contains(cameraId) {
            return false
        }
        
        // ✅ Check active fetches
        lock.lock()
        let currentFetches = activeFetches.count
        lock.unlock()
        
        if currentFetches >= maxConcurrentFetches {
            return false
        }
        
        return true
    }
    
    // MARK: - Auto Fetch (Queue-Based)
    
    func autoFetchThumbnail(for camera: Camera) {
        guard camera.isOnline else { return }
        guard isEnabled else { return }
        guard !isUnderMemoryPressure else { return }
        
        // Check if should load
        guard shouldLoad(for: camera.id) else {
            return
        }
        
        // ✅ Add to queue instead of immediate fetch
        lock.lock()
        if !captureQueue.contains(camera.id) {
            captureQueue.append(camera.id)
        }
        lock.unlock()
        
        // Process queue
        processQueue()
    }
    
    // ✅ Process Queue (One at a Time with Longer Delays)
    private func processQueue() {
        lock.lock()
        
        // Check if we can process
        guard activeFetches.count < maxConcurrentFetches else {
            lock.unlock()
            return
        }
        
        // Get next item from queue
        guard let cameraId = captureQueue.first else {
            lock.unlock()
            return
        }
        
        captureQueue.removeFirst()
        lock.unlock()
        
        // Find camera
        if let camera = CameraManager.shared.getCameraById(cameraId) {
            // ✅ Add 1-second delay between fetches (increased from immediate)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.fetchThumbnail(for: camera, isManual: false)
            }
        }
    }
    
    // MARK: - Manual Refresh
    
    func manualRefresh(for camera: Camera, completion: @escaping (Bool) -> Void) {
        // ✅ Don't allow manual refresh under memory pressure or if disabled
        if isUnderMemoryPressure || !isEnabled {
            DebugLogger.shared.log("⚠️ Manual refresh blocked: System disabled", emoji: "⚠️", color: .orange)
            completion(false)
            return
        }
        
        // Remove from failed state
        failedCameras.remove(camera.id)
        
        DebugLogger.shared.log("🔄 Manual refresh: \(camera.displayName)", emoji: "🔄", color: .blue)
        
        fetchThumbnail(for: camera, isManual: true, completion: completion)
    }
    
    // MARK: - Core Fetch Logic (with Safety Checks)
    
    private func fetchThumbnail(for camera: Camera, isManual: Bool, completion: ((Bool) -> Void)? = nil) {
        // ✅ Safety check
        guard isEnabled && !isUnderMemoryPressure else {
            completion?(false)
            return
        }
        
        lock.lock()
        let isAlreadyFetching = activeFetches.contains(camera.id)
        lock.unlock()
        
        if isAlreadyFetching {
            completion?(false)
            return
        }
        
        // ✅ Enforce STRICT WebView limit (only 1)
        lock.lock()
        if captureWebViews.count >= maxActiveWebViews {
            // Clean up ALL WebViews
            let allWebViews = captureWebViews
            captureWebViews.removeAll()
            lock.unlock()
            
            for (_, webView) in allWebViews {
                cleanupWebView(webView)
            }
        } else {
            lock.unlock()
        }
        
        lock.lock()
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
                
                // ✅ Process next in queue after longer delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {  // Increased from 1s
                    self.processQueue()
                }
            }
        }
    }
    
    // MARK: - Capture from Stream (with Aggressive Cleanup)
    
    private func captureFromStream(camera: Camera, isManual: Bool, completion: @escaping (Bool) -> Void) {
        guard let streamURL = camera.webrtcStreamURL else {
            DebugLogger.shared.log("⚠️ No stream URL: \(camera.id)", emoji: "⚠️", color: .orange)
            markAsFailed(camera.id)
            removeFetchTask(for: camera.id)
            completion(false)
            return
        }
        
        // ✅ Use minimal configuration
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        config.websiteDataStore = .nonPersistent()
        
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        
        config.suppressesIncrementalRendering = true
        
        // ✅ Crash handler
        let handler = ThumbnailCaptureHandler(cameraId: camera.id, manager: self, completion: completion)
        config.userContentController.add(handler, name: "captureComplete")
        
        // ✅ Even smaller size to reduce memory
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 240, height: 180), configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.backgroundColor = .black
        webView.isOpaque = true
        webView.alpha = 0.01
        
        // ✅ Store weak reference
        lock.lock()
        captureWebViews[camera.id] = webView
        lock.unlock()
        
        // ✅ Generate HTML
        let html = generateCaptureHTML(streamURL: streamURL)
        
        // ✅ Load in autoreleasepool to prevent memory buildup
        autoreleasepool {
            webView.loadHTMLString(html, baseURL: nil)
        }
        
        // ✅ Shorter timeout (10 seconds instead of 15)
        DispatchQueue.main.asyncAfter(deadline: .now() + captureTimeout) { [weak self] in
            guard let self = self else { return }
            
            self.lock.lock()
            let stillActive = self.activeFetches.contains(camera.id)
            self.lock.unlock()
            
            if stillActive {
                DebugLogger.shared.log("⏱️ Timeout: \(camera.id)", emoji: "⏱️", color: .orange)
                self.markAsFailed(camera.id)
                self.cleanupCaptureWebView(for: camera.id)
                self.removeFetchTask(for: camera.id)
                completion(false)
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
                body { width: 240px; height: 180px; background: #000; overflow: hidden; }
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
                let timeout = null;
                
                // ✅ Force cleanup after 8 seconds
                timeout = setTimeout(() => {
                    if (!captured && window.webkit?.messageHandlers?.captureComplete) {
                        window.webkit.messageHandlers.captureComplete.postMessage({ 
                            success: false,
                            error: 'Timeout'
                        });
                    }
                }, 8000);
                
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
                        const timeoutId = setTimeout(() => controller.abort(), 7000);
                        
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
                    
                    if (timeout) clearTimeout(timeout);
                    
                    setTimeout(() => {
                        try {
                            const width = video.videoWidth || 240;
                            const height = video.videoHeight || 180;
                            
                            canvas.width = width;
                            canvas.height = height;
                            ctx.drawImage(video, 0, 0, width, height);
                            
                            const imageData = canvas.toDataURL('image/jpeg', 0.5);  // Reduced quality
                            
                            if (window.webkit?.messageHandlers?.captureComplete) {
                                window.webkit.messageHandlers.captureComplete.postMessage({
                                    success: true,
                                    imageData: imageData
                                });
                            }
                            
                            // Cleanup
                            if (pc) {
                                pc.close();
                                pc = null;
                            }
                            video.srcObject = null;
                            
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
    
    func handleCapturedImage(cameraId: String, imageDataURL: String, completion: @escaping (Bool) -> Void) {
        DebugLogger.shared.log("📷 Received capture: \(cameraId)", emoji: "📷", color: .green)
        
        guard let commaIndex = imageDataURL.firstIndex(of: ",") else {
            DebugLogger.shared.log("❌ Invalid image data: \(cameraId)", emoji: "❌", color: .red)
            markAsFailed(cameraId)
            cleanupCaptureWebView(for: cameraId)
            removeFetchTask(for: cameraId)
            completion(false)
            return
        }
        
        let base64String = String(imageDataURL[imageDataURL.index(after: commaIndex)...])
        
        guard let imageData = Data(base64Encoded: base64String),
              let image = UIImage(data: imageData) else {
            DebugLogger.shared.log("❌ Failed to decode: \(cameraId)", emoji: "❌", color: .red)
            markAsFailed(cameraId)
            cleanupCaptureWebView(for: cameraId)
            removeFetchTask(for: cameraId)
            completion(false)
            return
        }
        
        // ✅ Process in autoreleasepool
        autoreleasepool {
            let orientedImage = fixImageOrientation(image)
            let resizedImage = resizeImage(orientedImage, targetWidth: 240)  // Smaller size
            
            DispatchQueue.main.async {
                self.thumbnails[cameraId] = resizedImage
                self.cache.setObject(resizedImage, forKey: cameraId as NSString)
                self.thumbnailTimestamps[cameraId] = Date()
                
                self.failedCameras.remove(cameraId)
                
                DebugLogger.shared.log("✅ Thumbnail saved: \(cameraId)", emoji: "✅", color: .green)
                
                self.saveThumbnail(resizedImage, for: cameraId)
                self.saveTimestamps()
                
                self.cleanupCaptureWebView(for: cameraId)
                self.removeFetchTask(for: cameraId)
                
                completion(true)
            }
        }
    }
    
    // MARK: - Mark as Failed
    
    private func markAsFailed(_ cameraId: String) {
        failedCameras.insert(cameraId)
        DebugLogger.shared.log("❌ Failed to load: \(cameraId)", emoji: "❌", color: .red)
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
    
    private func cleanupWebView(_ webView: WKWebView) {
        autoreleasepool {
            webView.stopLoading()
            webView.loadHTMLString("", baseURL: nil)
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
            webView.removeFromSuperview()
        }
    }
    
    func cleanupCaptureWebView(for cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        if let webView = captureWebViews.removeValue(forKey: cameraId) {
            DispatchQueue.main.async {
                self.cleanupWebView(webView)
            }
        }
    }
    
    func removeFetchTask(for cameraId: String) {
        lock.lock()
        activeFetches.remove(cameraId)
        lock.unlock()
    }
    
    // ✅ Stop ALL active captures (emergency)
    func stopAllCaptures() {
        lock.lock()
        let allWebViews = captureWebViews
        captureWebViews.removeAll()
        activeFetches.removeAll()
        captureQueue.removeAll()
        lock.unlock()
        
        DispatchQueue.main.async {
            for (_, webView) in allWebViews {
                self.cleanupWebView(webView)
            }
        }
        
        DebugLogger.shared.log("🛑 Stopped all captures", emoji: "🛑", color: .red)
    }
    
    // MARK: - Disk Persistence
    
    private func saveThumbnail(_ image: UIImage, for cameraId: String) {
        DispatchQueue.global(qos: .background).async {
            autoreleasepool {
                guard let data = image.jpegData(compressionQuality: 0.6) else { return }  // Lower quality
                let fileURL = self.cacheDirectory.appendingPathComponent("\(cameraId).jpg")
                try? data.write(to: fileURL)
            }
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
                autoreleasepool {
                    for file in files where file.pathExtension == "jpg" {
                        let cameraId = file.deletingPathExtension().lastPathComponent
                        
                        if let data = try? Data(contentsOf: file),
                           let image = UIImage(data: data) {
                            let orientedImage = self.fixImageOrientation(image)
                            self.thumbnails[cameraId] = orientedImage
                            self.cache.setObject(orientedImage, forKey: cameraId as NSString)
                        }
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
        lock.unlock()
        
        cleanupCaptureWebView(for: cameraId)
        
        let fileURL = cacheDirectory.appendingPathComponent("\(cameraId).jpg")
        try? fileManager.removeItem(at: fileURL)
    }
    
    func clearAllThumbnails() {
        stopAllCaptures()
        
        lock.lock()
        thumbnails.removeAll()
        thumbnailTimestamps.removeAll()
        failedCameras.removeAll()
        cache.removeAllObjects()
        captureQueue.removeAll()
        lock.unlock()
        
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
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        stopAllCaptures()
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