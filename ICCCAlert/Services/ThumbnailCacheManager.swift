import Foundation
import UIKit
import WebKit
import Combine

// MARK: - Thumbnail Cache Manager (CRASH-PROOF - MANUAL LOAD ONLY)
class ThumbnailCacheManager: ObservableObject {
    static let shared = ThumbnailCacheManager()
    
    @Published private(set) var thumbnails: [String: UIImage] = [:]
    @Published private(set) var thumbnailTimestamps: [String: Date] = [:]
    @Published private(set) var failedCameras: Set<String> = []
    @Published private(set) var loadingCameras: Set<String> = []
    
    private let cache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    
    // CRITICAL: Only ONE capture at a time
    private var activeFetches: Set<String> = []
    private let lock = NSLock()
    
    // Single shared WebView for ALL captures (reused)
    private var captureWebView: WKWebView?
    private var currentCapture: String?
    private var captureCompletion: ((Bool) -> Void)?
    private var captureTimeout: DispatchWorkItem?
    
    // Cache duration: 3 hours
    private let cacheDuration: TimeInterval = 3 * 60 * 60
    
    private init() {
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = paths[0].appendingPathComponent("CameraThumbnails")
        
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        cache.countLimit = 50 // Reduced
        cache.totalCostLimit = 20 * 1024 * 1024 // 20MB max
        
        loadCachedThumbnails()
        loadTimestamps()
        
        setupMemoryWarning()
        
        DebugLogger.shared.log("🖼️ ThumbnailCacheManager initialized (MANUAL LOAD ONLY)", emoji: "🖼️", color: .blue)
    }
    
    private func setupMemoryWarning() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DebugLogger.shared.log("⚠️ MEMORY WARNING - Clearing thumbnail cache", emoji: "🧹", color: .red)
            self?.handleMemoryWarning()
        }
    }
    
    private func handleMemoryWarning() {
        lock.lock()
        
        // Cancel current capture
        if let timeout = captureTimeout {
            timeout.cancel()
            captureTimeout = nil
        }
        
        // Clear states
        loadingCameras.removeAll()
        activeFetches.removeAll()
        currentCapture = nil
        captureCompletion = nil
        
        // Clean up WebView immediately
        if let webView = captureWebView {
            DispatchQueue.main.async {
                self.destroyWebView(webView)
            }
            captureWebView = nil
        }
        
        // Clear memory cache
        cache.removeAllObjects()
        thumbnails.removeAll()
        
        lock.unlock()
        
        DebugLogger.shared.log("🧹 Thumbnail cache cleared", emoji: "🧹", color: .orange)
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
    
    // MARK: - Manual Load ONLY (No Auto-Load)
    
    func manualLoad(for camera: Camera, completion: @escaping (Bool) -> Void) {
        lock.lock()
        
        // Check if already loading
        if loadingCameras.contains(camera.id) || currentCapture == camera.id {
            lock.unlock()
            completion(false)
            return
        }
        
        // Check if already have fresh thumbnail
        if isThumbnailFresh(for: camera.id), getThumbnail(for: camera.id) != nil {
            lock.unlock()
            completion(true)
            return
        }
        
        // Check if already capturing something
        if currentCapture != nil {
            lock.unlock()
            DebugLogger.shared.log("⚠️ Already capturing - please wait", emoji: "⚠️", color: .orange)
            completion(false)
            return
        }
        
        loadingCameras.insert(camera.id)
        failedCameras.remove(camera.id)
        
        lock.unlock()
        
        DebugLogger.shared.log("🔄 Manual load: \(camera.displayName)", emoji: "🔄", color: .blue)
        
        startCapture(for: camera, completion: completion)
    }
    
    // MARK: - Core Capture Logic (Single WebView)
    
    private func startCapture(for camera: Camera, completion: @escaping (Bool) -> Void) {
        guard let streamURL = camera.webrtcStreamURL else {
            DebugLogger.shared.log("⚠️ No stream URL: \(camera.id)", emoji: "⚠️", color: .orange)
            markAsFailed(camera.id)
            finishCapture(camera.id, success: false, completion: completion)
            return
        }
        
        lock.lock()
        currentCapture = camera.id
        captureCompletion = completion
        activeFetches.insert(camera.id)
        lock.unlock()
        
        DebugLogger.shared.log("📸 Starting capture: \(camera.displayName)", emoji: "📸", color: .blue)
        
        // Setup on main thread
        DispatchQueue.main.async {
            self.setupCaptureWebView(streamURL: streamURL, cameraId: camera.id)
        }
        
        // Timeout: 15 seconds
        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            self.lock.lock()
            let stillActive = self.currentCapture == camera.id
            self.lock.unlock()
            
            if stillActive {
                DebugLogger.shared.log("⏱️ Timeout: \(camera.id)", emoji: "⏱️", color: .orange)
                self.markAsFailed(camera.id)
                self.finishCapture(camera.id, success: false, completion: completion)
            }
        }
        
        lock.lock()
        captureTimeout = timeoutWork
        lock.unlock()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: timeoutWork)
    }
    
    private func setupCaptureWebView(streamURL: String, cameraId: String) {
        // CRITICAL: Destroy existing WebView first
        if let existing = captureWebView {
            destroyWebView(existing)
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
        
        // Add message handler
        let handler = ThumbnailCaptureHandler(cameraId: cameraId, manager: self)
        config.userContentController.add(handler, name: "captureComplete")
        
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.backgroundColor = .black
        webView.isOpaque = true
        webView.alpha = 0.01
        
        // Add to window (off-screen)
        if let window = UIApplication.shared.windows.first {
            window.addSubview(webView)
            webView.frame = CGRect(x: -2000, y: -2000, width: 320, height: 240)
        }
        
        captureWebView = webView
        
        let html = generateCaptureHTML(streamURL: streamURL)
        webView.loadHTMLString(html, baseURL: nil)
    }
    
    private func destroyWebView(_ webView: WKWebView) {
        // CRITICAL: Proper WebView cleanup
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
        
        // Remove all script handlers
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        
        // Remove from superview
        webView.removeFromSuperview()
        
        // Clear data store
        let dataStore = WKWebsiteDataStore.nonPersistent()
        dataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: Date(timeIntervalSince1970: 0),
            completionHandler: {}
        )
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
                            if (!captured) {
                                video.srcObject = e.streams[0];
                            }
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
                
                // Cleanup on page unload
                window.addEventListener('beforeunload', cleanup);
                
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
            markAsFailed(cameraId)
            finishCapture(cameraId, success: false, completion: nil)
            return
        }
        
        let base64String = String(imageDataURL[imageDataURL.index(after: commaIndex)...])
        
        guard let imageData = Data(base64Encoded: base64String),
              let image = UIImage(data: imageData) else {
            DebugLogger.shared.log("❌ Failed to decode", emoji: "❌", color: .red)
            markAsFailed(cameraId)
            finishCapture(cameraId, success: false, completion: nil)
            return
        }
        
        let resizedImage = resizeImage(image, targetWidth: 320)
        
        DispatchQueue.main.async {
            self.thumbnails[cameraId] = resizedImage
            self.cache.setObject(resizedImage, forKey: cameraId as NSString)
            self.thumbnailTimestamps[cameraId] = Date()
            self.failedCameras.remove(cameraId)
            
            DebugLogger.shared.log("✅ Thumbnail saved: \(cameraId)", emoji: "✅", color: .green)
            
            self.saveThumbnail(resizedImage, for: cameraId)
            self.saveTimestamps()
            
            self.finishCapture(cameraId, success: true, completion: nil)
        }
    }
    
    func handleCaptureFailed(cameraId: String) {
        markAsFailed(cameraId)
        finishCapture(cameraId, success: false, completion: nil)
    }
    
    private func finishCapture(_ cameraId: String, success: Bool, completion: ((Bool) -> Void)?) {
        lock.lock()
        
        // Cancel timeout
        if let timeout = captureTimeout {
            timeout.cancel()
            captureTimeout = nil
        }
        
        let captureCompletion = self.captureCompletion
        
        currentCapture = nil
        self.captureCompletion = nil
        activeFetches.remove(cameraId)
        loadingCameras.remove(cameraId)
        
        // Destroy WebView on main thread
        if let webView = captureWebView {
            DispatchQueue.main.async {
                self.destroyWebView(webView)
            }
            captureWebView = nil
        }
        
        lock.unlock()
        
        // Call completions
        DispatchQueue.main.async {
            completion?(success)
            captureCompletion?(success)
        }
    }
    
    private func markAsFailed(_ cameraId: String) {
        failedCameras.insert(cameraId)
        DebugLogger.shared.log("❌ Marked as failed: \(cameraId)", emoji: "❌", color: .red)
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
        loadingCameras.remove(cameraId)
        lock.unlock()
        
        let fileURL = cacheDirectory.appendingPathComponent("\(cameraId).jpg")
        try? fileManager.removeItem(at: fileURL)
    }
    
    func clearAllThumbnails() {
        lock.lock()
        
        // Cancel any active capture
        if let timeout = captureTimeout {
            timeout.cancel()
            captureTimeout = nil
        }
        
        thumbnails.removeAll()
        thumbnailTimestamps.removeAll()
        failedCameras.removeAll()
        cache.removeAllObjects()
        activeFetches.removeAll()
        loadingCameras.removeAll()
        currentCapture = nil
        captureCompletion = nil
        
        lock.unlock()
        
        // Clean up WebView
        if let webView = captureWebView {
            DispatchQueue.main.async {
                self.destroyWebView(webView)
            }
            captureWebView = nil
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