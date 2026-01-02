import Foundation
import UIKit
import WebKit
import Combine
import SwiftUI

// MARK: - Thumbnail Cache Manager (AGGRESSIVE MEMORY MANAGEMENT + RATE LIMITING)
class ThumbnailCacheManager: ObservableObject {
    static let shared = ThumbnailCacheManager()
    
    @Published private(set) var thumbnails: [String: UIImage] = [:]
    @Published private(set) var thumbnailTimestamps: [String: Date] = [:]
    @Published private(set) var failedCameras: Set<String> = []
    @Published private(set) var loadingCameras: Set<String> = []
    
    private let cache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    
    // CRITICAL: Single capture operation at a time
    private var isCapturing = false
    private let lock = NSLock()
    
    // NEW: Rate limiting properties (prevents rapid-fire crashes)
    private var lastCaptureTime: TimeInterval = 0
    private let minimumCaptureInterval: TimeInterval = 3.0  // 3 seconds between captures
    
    // CRITICAL: Track active WebViews for aggressive cleanup
    private var activeWebViews: Set<WKWebView> = []
    private var captureTimeouts: [String: DispatchWorkItem] = [:]
    
    // Cache duration: 3 hours
    private let cacheDuration: TimeInterval = 3 * 60 * 60
    
    private init() {
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = paths[0].appendingPathComponent("CameraThumbnails")
        
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        cache.countLimit = 30  // Reduced from 50 for low memory
        cache.totalCostLimit = 10 * 1024 * 1024 // Reduced to 10MB
        
        loadCachedThumbnails()
        loadTimestamps()
        
        setupMemoryWarning()
        
        DebugLogger.shared.log("🖼️ ThumbnailCacheManager initialized (LOW MEMORY MODE + RATE LIMITING)", emoji: "🖼️", color: .blue)
    }
    
    private func setupMemoryWarning() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DebugLogger.shared.log("🆘 MEMORY WARNING - Emergency cleanup", emoji: "🆘", color: .red)
            self?.emergencyCleanup()
        }
    }
    
    private func emergencyCleanup() {
        lock.lock()
        
        // Cancel all ongoing captures
        captureTimeouts.values.forEach { $0.cancel() }
        captureTimeouts.removeAll()
        
        // Destroy all active WebViews IMMEDIATELY
        let webViewsToDestroy = Array(activeWebViews)
        activeWebViews.removeAll()
        
        loadingCameras.removeAll()
        isCapturing = false
        
        lock.unlock()
        
        // Destroy WebViews on main thread
        DispatchQueue.main.async {
            webViewsToDestroy.forEach { webView in
                self.destroyWebViewAggressively(webView)
            }
        }
        
        // Clear memory cache but keep disk cache
        cache.removeAllObjects()
        thumbnails.removeAll()
        
        // Force garbage collection hint
        autoreleasepool {}
        
        DebugLogger.shared.log("🧹 Emergency cleanup complete", emoji: "🧹", color: .orange)
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
        return loadingCameras.contains(cameraId)
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
    
    // MARK: - Manual Load ONLY (WITH RATE LIMITING + AGGRESSIVE CLEANUP)
    
    func manualLoad(for camera: Camera, completion: @escaping (Bool) -> Void) {
        lock.lock()
        
        // NEW: Enforce minimum time between captures (prevents rapid-fire crashes)
        let now = Date().timeIntervalSince1970
        let timeSinceLastCapture = now - lastCaptureTime
        
        if timeSinceLastCapture < minimumCaptureInterval {
            let remainingTime = Int(ceil(minimumCaptureInterval - timeSinceLastCapture))
            lock.unlock()
            
            DebugLogger.shared.log("⏳ Too fast! Wait \(remainingTime)s before next capture", emoji: "⏳", color: .orange)
            
            DispatchQueue.main.async {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
            
            completion(false)
            return
        }
        
        // CRITICAL: Block if ANY capture is in progress
        if isCapturing {
            lock.unlock()
            DebugLogger.shared.log("⚠️ Capture blocked - already in progress", emoji: "⚠️", color: .orange)
            completion(false)
            return
        }
        
        // Check if already loading this specific camera
        if loadingCameras.contains(camera.id) {
            lock.unlock()
            DebugLogger.shared.log("⚠️ Already loading this camera", emoji: "⚠️", color: .orange)
            completion(false)
            return
        }
        
        // Check if already have fresh thumbnail
        if isThumbnailFresh(for: camera.id), getThumbnail(for: camera.id) != nil {
            lock.unlock()
            completion(true)
            return
        }
        
        // Mark as loading and capturing
        loadingCameras.insert(camera.id)
        failedCameras.remove(camera.id)
        isCapturing = true
        lastCaptureTime = now  // Record capture start time
        
        lock.unlock()
        
        DebugLogger.shared.log("🔄 Starting capture: \(camera.displayName)", emoji: "🔄", color: .blue)
        
        startCapture(for: camera, completion: completion)
    }
    
    // MARK: - Core Capture Logic (7 SECOND TIMEOUT - AGGRESSIVE)
    
    private func startCapture(for camera: Camera, completion: @escaping (Bool) -> Void) {
        guard let streamURL = camera.webrtcStreamURL else {
            DebugLogger.shared.log("⚠️ No stream URL: \(camera.id)", emoji: "⚠️", color: .orange)
            markAsFailed(camera.id)
            finishCapture(camera.id, success: false, completion: completion)
            return
        }
        
        DebugLogger.shared.log("📸 Attempting capture: \(camera.displayName)", emoji: "📸", color: .blue)
        
        // Create WebView on main thread
        DispatchQueue.main.async {
            self.executeSingleCapture(streamURL: streamURL, cameraId: camera.id, completion: completion)
        }
    }
    
    private func executeSingleCapture(streamURL: String, cameraId: String, completion: @escaping (Bool) -> Void) {
        // Create configuration
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        config.websiteDataStore = .nonPersistent()
        
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        
        // Create temporary handler
        let handler = ThumbnailCaptureHandler(cameraId: cameraId) { [weak self] success, imageData in
            guard let self = self else { return }
            
            // Cancel timeout
            self.lock.lock()
            if let timeout = self.captureTimeouts[cameraId] {
                timeout.cancel()
                self.captureTimeouts.removeValue(forKey: cameraId)
            }
            self.lock.unlock()
            
            if success, let imageData = imageData {
                DebugLogger.shared.log("✅ Capture succeeded: \(cameraId)", emoji: "✅", color: .green)
                self.processCapturedImage(cameraId: cameraId, imageDataURL: imageData, completion: completion)
            } else {
                DebugLogger.shared.log("❌ Capture failed: \(cameraId)", emoji: "❌", color: .red)
                self.markAsFailed(cameraId)
                self.finishCapture(cameraId, success: false, completion: completion)
            }
        }
        
        config.userContentController.add(handler, name: "captureComplete")
        
        // Create WebView with smaller frame for lower memory
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 240, height: 180), configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.backgroundColor = .black
        webView.isOpaque = true
        webView.alpha = 0.01
        
        // Track WebView
        lock.lock()
        activeWebViews.insert(webView)
        lock.unlock()
        
        // Add off-screen
        if let window = UIApplication.shared.windows.first {
            window.addSubview(webView)
            webView.frame = CGRect(x: -2000, y: -2000, width: 240, height: 180)
        }
        
        let html = generateCaptureHTML(streamURL: streamURL)
        webView.loadHTMLString(html, baseURL: nil)
        
        // CRITICAL: 7 second timeout (reduced from 10) with aggressive cleanup
        let timeoutWork = DispatchWorkItem { [weak self, weak webView] in
            guard let self = self, let webView = webView else { return }
            
            DebugLogger.shared.log("⏱️ Timeout - destroying WebView", emoji: "⏱️", color: .orange)
            
            // Remove from tracking
            self.lock.lock()
            self.activeWebViews.remove(webView)
            self.captureTimeouts.removeValue(forKey: cameraId)
            self.lock.unlock()
            
            self.destroyWebViewAggressively(webView)
            
            // Check if still capturing
            self.lock.lock()
            let stillCapturing = self.isCapturing && self.loadingCameras.contains(cameraId)
            self.lock.unlock()
            
            if stillCapturing {
                DebugLogger.shared.log("❌ Capture timeout: \(cameraId)", emoji: "❌", color: .red)
                self.markAsFailed(cameraId)
                self.finishCapture(cameraId, success: false, completion: completion)
            }
        }
        
        lock.lock()
        captureTimeouts[cameraId] = timeoutWork
        lock.unlock()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.0, execute: timeoutWork)
    }
    
    private func generateCaptureHTML(streamURL: String) -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <style>
                * { margin: 0; padding: 0; }
                body { width: 240px; height: 180px; background: #000; }
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
                let pc = null, captured = false, cleaned = false;
                
                function cleanup() {
                    if (cleaned) return;
                    cleaned = true;
                    try {
                        if (pc) { pc.close(); pc = null; }
                        if (video.srcObject) {
                            video.srcObject.getTracks().forEach(t => t.stop());
                            video.srcObject = null;
                        }
                        video.src = '';
                        video.load();
                    } catch(e) {}
                }
                
                function fail() {
                    cleanup();
                    if (window.webkit?.messageHandlers?.captureComplete) {
                        window.webkit.messageHandlers.captureComplete.postMessage({ success: false });
                    }
                }
                
                async function start() {
                    try {
                        pc = new RTCPeerConnection({ 
                            iceServers: [{ urls: 'stun:stun.l.google.com:19302' }],
                            iceTransportPolicy: 'all'
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
                        setTimeout(() => controller.abort(), 6000);
                        
                        const res = await fetch('\(streamURL)', {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/sdp' },
                            body: offer.sdp,
                            signal: controller.signal
                        });
                        
                        if (!res.ok) throw new Error('Server error: ' + res.status);
                        
                        const answer = await res.text();
                        await pc.setRemoteDescription({ type: 'answer', sdp: answer });
                        
                    } catch(err) {
                        fail();
                    }
                }
                
                video.addEventListener('playing', () => {
                    if (captured) return;
                    captured = true;
                    
                    setTimeout(() => {
                        try {
                            canvas.width = 240;
                            canvas.height = 180;
                            ctx.drawImage(video, 0, 0, 240, 180);
                            const imageData = canvas.toDataURL('image/jpeg', 0.5);
                            
                            cleanup();
                            
                            if (window.webkit?.messageHandlers?.captureComplete) {
                                window.webkit.messageHandlers.captureComplete.postMessage({
                                    success: true,
                                    imageData: imageData
                                });
                            }
                        } catch(err) {
                            fail();
                        }
                    }, 300);
                });
                
                video.addEventListener('error', () => fail());
                
                start();
            })();
            </script>
        </body>
        </html>
        """
    }
    
    private func destroyWebViewAggressively(_ webView: WKWebView) {
        // CRITICAL: Aggressive WebView destruction for low memory devices
        
        // 1. Stop all loading
        webView.stopLoading()
        
        // 2. Clear delegates
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        
        // 3. Remove all script handlers
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        
        // 4. Load blank page to release resources
        webView.loadHTMLString("", baseURL: nil)
        
        // 5. Remove from superview
        webView.removeFromSuperview()
        
        // 6. Clear website data
        let dataStore = WKWebsiteDataStore.nonPersistent()
        dataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: Date(timeIntervalSince1970: 0),
            completionHandler: {}
        )
        
        // 7. Force memory release hint
        autoreleasepool {}
        
        DebugLogger.shared.log("🧹 WebView destroyed aggressively", emoji: "🧹", color: .gray)
    }
    
    // MARK: - Process Captured Image
    
    private func processCapturedImage(cameraId: String, imageDataURL: String, completion: @escaping (Bool) -> Void) {
        DebugLogger.shared.log("📷 Processing capture: \(cameraId)", emoji: "📷", color: .green)
        
        guard let commaIndex = imageDataURL.firstIndex(of: ",") else {
            DebugLogger.shared.log("❌ Invalid image data", emoji: "❌", color: .red)
            markAsFailed(cameraId)
            finishCapture(cameraId, success: false, completion: completion)
            return
        }
        
        let base64String = String(imageDataURL[imageDataURL.index(after: commaIndex)...])
        
        guard let imageData = Data(base64Encoded: base64String),
              let image = UIImage(data: imageData) else {
            DebugLogger.shared.log("❌ Failed to decode", emoji: "❌", color: .red)
            markAsFailed(cameraId)
            finishCapture(cameraId, success: false, completion: completion)
            return
        }
        
        // Reduced size for low memory
        let resizedImage = resizeImage(image, targetWidth: 240)
        
        DispatchQueue.main.async {
            self.thumbnails[cameraId] = resizedImage
            self.cache.setObject(resizedImage, forKey: cameraId as NSString)
            self.thumbnailTimestamps[cameraId] = Date()
            self.failedCameras.remove(cameraId)
            
            DebugLogger.shared.log("✅ Thumbnail saved: \(cameraId)", emoji: "✅", color: .green)
            
            self.saveThumbnail(resizedImage, for: cameraId)
            self.saveTimestamps()
            
            self.finishCapture(cameraId, success: true, completion: completion)
        }
    }
    
    private func finishCapture(_ cameraId: String, success: Bool, completion: ((Bool) -> Void)?) {
        lock.lock()
        loadingCameras.remove(cameraId)
        captureTimeouts.removeValue(forKey: cameraId)
        lock.unlock()
        
        // Add 0.5 second cooldown before allowing next capture
        // This prevents race conditions and gives WebView time to fully cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.lock.lock()
            self.isCapturing = false
            self.lock.unlock()
            DebugLogger.shared.log("✅ Ready for next capture", emoji: "✅", color: .green)
        }
        
        DebugLogger.shared.log("🏁 Capture finished: \(cameraId) - \(success ? "SUCCESS" : "FAILED")", emoji: "🏁", color: success ? .green : .red)
        
        DispatchQueue.main.async {
            completion?(success)
        }
    }
    
    private func markAsFailed(_ cameraId: String) {
        DispatchQueue.main.async {
            self.failedCameras.insert(cameraId)
            DebugLogger.shared.log("❌ Marked as failed: \(cameraId)", emoji: "❌", color: .red)
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
            guard let data = image.jpegData(compressionQuality: 0.6) else { return }
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
        emergencyCleanup()
        
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

// MARK: - Capture Handler (Simplified)
class ThumbnailCaptureHandler: NSObject, WKScriptMessageHandler {
    let cameraId: String
    let callback: (Bool, String?) -> Void
    
    init(cameraId: String, callback: @escaping (Bool, String?) -> Void) {
        self.cameraId = cameraId
        self.callback = callback
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "captureComplete",
              let dict = message.body as? [String: Any] else {
            callback(false, nil)
            return
        }
        
        if let success = dict["success"] as? Bool, success,
           let imageData = dict["imageData"] as? String {
            callback(true, imageData)
        } else {
            callback(false, nil)
        }
    }
}