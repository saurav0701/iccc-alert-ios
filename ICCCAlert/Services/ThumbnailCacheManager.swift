import Foundation
import UIKit
import WebKit
import Combine
import SwiftUI

// MARK: - Thumbnail Cache Manager (ULTRA AGGRESSIVE - CRASH PREVENTION)
class ThumbnailCacheManager: ObservableObject {
    static let shared = ThumbnailCacheManager()
    
    @Published private(set) var thumbnails: [String: UIImage] = [:]
    @Published private(set) var thumbnailTimestamps: [String: Date] = [:]
    @Published private(set) var failedCameras: Set<String> = []
    @Published private(set) var loadingCameras: Set<String> = []
    
    private let cache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    
    // CRITICAL: Absolute single capture lock
    private var globalCaptureLock = false
    private let lock = NSLock()
    
    // AGGRESSIVE: Rate limiting (prevent rapid crashes)
    private var lastCaptureTime: TimeInterval = 0
    private let minimumCaptureInterval: TimeInterval = 5.0  // Increased to 5 seconds
    
    // CRITICAL: Track active WebView (ONLY ONE ALLOWED)
    private var activeWebView: WKWebView?
    private var captureTimeout: DispatchWorkItem?
    
    // Cache duration: 3 hours
    private let cacheDuration: TimeInterval = 3 * 60 * 60
    
    // CRITICAL: Crash prevention timer
    private var emergencyTimer: Timer?
    
    private init() {
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = paths[0].appendingPathComponent("CameraThumbnails")
        
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        cache.countLimit = 20  // Further reduced for safety
        cache.totalCostLimit = 8 * 1024 * 1024 // 8MB only
        
        loadCachedThumbnails()
        loadTimestamps()
        
        setupMemoryWarning()
        setupEmergencyTimer()
        
        DebugLogger.shared.log("🖼️ ThumbnailCache: ULTRA LOW MEMORY MODE", emoji: "🖼️", color: .blue)
    }
    
    private func setupMemoryWarning() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DebugLogger.shared.log("🆘 MEMORY WARNING - EMERGENCY", emoji: "🆘", color: .red)
            self?.emergencyCleanup()
        }
    }
    
    // NEW: Emergency safety timer (destroys stale captures)
    private func setupEmergencyTimer() {
        emergencyTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.checkForStalledCaptures()
        }
    }
    
    private func checkForStalledCaptures() {
        lock.lock()
        
        // If capture is locked for >15 seconds, force cleanup
        if globalCaptureLock {
            let now = Date().timeIntervalSince1970
            if (now - lastCaptureTime) > 15 {
                DebugLogger.shared.log("🚨 STALLED CAPTURE DETECTED - FORCE CLEANUP", emoji: "🚨", color: .red)
                
                if let webView = activeWebView {
                    destroyWebViewImmediately(webView)
                    activeWebView = nil
                }
                
                globalCaptureLock = false
                loadingCameras.removeAll()
                
                lock.unlock()
                return
            }
        }
        
        lock.unlock()
    }
    
    private func emergencyCleanup() {
        lock.lock()
        
        // Cancel timeout
        captureTimeout?.cancel()
        captureTimeout = nil
        
        // Destroy active WebView IMMEDIATELY
        if let webView = activeWebView {
            destroyWebViewImmediately(webView)
            activeWebView = nil
        }
        
        loadingCameras.removeAll()
        globalCaptureLock = false
        
        lock.unlock()
        
        // Clear memory cache
        cache.removeAllObjects()
        thumbnails.removeAll()
        
        // Force memory release
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
    
    // MARK: - Manual Load ONLY (ULTRA SAFE)
    
    func manualLoad(for camera: Camera, completion: @escaping (Bool) -> Void) {
        lock.lock()
        
        // CRITICAL: Rate limiting check
        let now = Date().timeIntervalSince1970
        let timeSinceLastCapture = now - lastCaptureTime
        
        if timeSinceLastCapture < minimumCaptureInterval {
            let remainingTime = Int(ceil(minimumCaptureInterval - timeSinceLastCapture))
            lock.unlock()
            
            DebugLogger.shared.log("⏳ Wait \(remainingTime)s before next capture", emoji: "⏳", color: .orange)
            
            DispatchQueue.main.async {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
            
            completion(false)
            return
        }
        
        // CRITICAL: Global capture lock (only ONE capture at a time)
        if globalCaptureLock {
            lock.unlock()
            DebugLogger.shared.log("⚠️ CAPTURE BLOCKED - Already in progress", emoji: "⚠️", color: .orange)
            completion(false)
            return
        }
        
        // Check if already have fresh thumbnail
        if isThumbnailFresh(for: camera.id), getThumbnail(for: camera.id) != nil {
            lock.unlock()
            completion(true)
            return
        }
        
        // Mark as loading
        loadingCameras.insert(camera.id)
        failedCameras.remove(camera.id)
        globalCaptureLock = true
        lastCaptureTime = now
        
        lock.unlock()
        
        DebugLogger.shared.log("🔄 Starting capture: \(camera.displayName)", emoji: "🔄", color: .blue)
        
        startCapture(for: camera, completion: completion)
    }
    
    // MARK: - Core Capture Logic (5 SECOND TIMEOUT - ULTRA AGGRESSIVE)
    
    private func startCapture(for camera: Camera, completion: @escaping (Bool) -> Void) {
        guard let streamURL = camera.webrtcStreamURL else {
            DebugLogger.shared.log("⚠️ No stream URL", emoji: "⚠️", color: .orange)
            markAsFailed(camera.id)
            finishCapture(camera.id, success: false, completion: completion)
            return
        }
        
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
            self.captureTimeout?.cancel()
            self.captureTimeout = nil
            self.lock.unlock()
            
            if success, let imageData = imageData {
                DebugLogger.shared.log("✅ Capture succeeded", emoji: "✅", color: .green)
                self.processCapturedImage(cameraId: cameraId, imageDataURL: imageData, completion: completion)
            } else {
                DebugLogger.shared.log("❌ Capture failed", emoji: "❌", color: .red)
                self.markAsFailed(cameraId)
                self.finishCapture(cameraId, success: false, completion: completion)
            }
        }
        
        config.userContentController.add(handler, name: "captureComplete")
        
        // Create WebView with MINIMAL frame
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 200, height: 150), configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.backgroundColor = .black
        webView.isOpaque = true
        webView.alpha = 0.01
        
        // Store active WebView
        lock.lock()
        activeWebView = webView
        lock.unlock()
        
        // Add off-screen
        if let window = UIApplication.shared.windows.first {
            window.addSubview(webView)
            webView.frame = CGRect(x: -3000, y: -3000, width: 200, height: 150)
        }
        
        let html = generateCaptureHTML(streamURL: streamURL)
        webView.loadHTMLString(html, baseURL: nil)
        
        // CRITICAL: 5 second timeout (reduced from 7) with IMMEDIATE cleanup
        let timeoutWork = DispatchWorkItem { [weak self, weak webView] in
            guard let self = self else { return }
            
            DebugLogger.shared.log("⏱️ TIMEOUT - Force destroy", emoji: "⏱️", color: .orange)
            
            if let webView = webView {
                self.destroyWebViewImmediately(webView)
            }
            
            self.lock.lock()
            self.activeWebView = nil
            self.captureTimeout = nil
            let stillCapturing = self.globalCaptureLock && self.loadingCameras.contains(cameraId)
            self.lock.unlock()
            
            if stillCapturing {
                self.markAsFailed(cameraId)
                self.finishCapture(cameraId, success: false, completion: completion)
            }
        }
        
        lock.lock()
        captureTimeout = timeoutWork
        lock.unlock()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: timeoutWork)
    }
    
    private func generateCaptureHTML(streamURL: String) -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <style>
                * { margin: 0; padding: 0; }
                body { width: 200px; height: 150px; background: #000; }
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
                            iceServers: [{ urls: 'stun:stun.l.google.com:19302' }]
                        });
                        
                        pc.ontrack = (e) => { 
                            if (!captured) {
                                video.srcObject = e.streams[0]; 
                            }
                        };
                        
                        pc.addTransceiver('video', { direction: 'recvonly' });
                        
                        const offer = await pc.createOffer();
                        await pc.setLocalDescription(offer);
                        
                        const controller = new AbortController();
                        setTimeout(() => controller.abort(), 4000);
                        
                        const res = await fetch('\(streamURL)', {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/sdp' },
                            body: offer.sdp,
                            signal: controller.signal
                        });
                        
                        if (!res.ok) throw new Error('Server error');
                        
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
                            canvas.width = 200;
                            canvas.height = 150;
                            ctx.drawImage(video, 0, 0, 200, 150);
                            const imageData = canvas.toDataURL('image/jpeg', 0.4);
                            
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
                    }, 200);
                });
                
                video.addEventListener('error', () => fail());
                
                start();
            })();
            </script>
        </body>
        </html>
        """
    }
    
    private func destroyWebViewImmediately(_ webView: WKWebView) {
        // ULTRA AGGRESSIVE DESTRUCTION
        
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        
        // Load blank to release video
        webView.loadHTMLString("", baseURL: nil)
        
        // Remove from view
        webView.removeFromSuperview()
        
        // Clear data
        let dataStore = WKWebsiteDataStore.nonPersistent()
        dataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: Date(timeIntervalSince1970: 0),
            completionHandler: {}
        )
        
        // Force release
        autoreleasepool {}
        
        DebugLogger.shared.log("🧹 WebView destroyed", emoji: "🧹", color: .gray)
    }
    
    // MARK: - Process Captured Image
    
    private func processCapturedImage(cameraId: String, imageDataURL: String, completion: @escaping (Bool) -> Void) {
        guard let commaIndex = imageDataURL.firstIndex(of: ",") else {
            markAsFailed(cameraId)
            finishCapture(cameraId, success: false, completion: completion)
            return
        }
        
        let base64String = String(imageDataURL[imageDataURL.index(after: commaIndex)...])
        
        guard let imageData = Data(base64Encoded: base64String),
              let image = UIImage(data: imageData) else {
            markAsFailed(cameraId)
            finishCapture(cameraId, success: false, completion: completion)
            return
        }
        
        let resizedImage = resizeImage(image, targetWidth: 200)
        
        DispatchQueue.main.async {
            self.thumbnails[cameraId] = resizedImage
            self.cache.setObject(resizedImage, forKey: cameraId as NSString)
            self.thumbnailTimestamps[cameraId] = Date()
            self.failedCameras.remove(cameraId)
            
            self.saveThumbnail(resizedImage, for: cameraId)
            self.saveTimestamps()
            
            self.finishCapture(cameraId, success: true, completion: completion)
        }
    }
    
    private func finishCapture(_ cameraId: String, success: Bool, completion: ((Bool) -> Void)?) {
        lock.lock()
        
        // Destroy WebView
        if let webView = activeWebView {
            destroyWebViewImmediately(webView)
            activeWebView = nil
        }
        
        loadingCameras.remove(cameraId)
        captureTimeout = nil
        
        lock.unlock()
        
        // Add 1 second cooldown before allowing next capture
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.lock.lock()
            self.globalCaptureLock = false
            self.lock.unlock()
            DebugLogger.shared.log("✅ Ready for next capture", emoji: "✅", color: .green)
        }
        
        DebugLogger.shared.log("🏁 Capture finished: \(success ? "SUCCESS" : "FAILED")", emoji: "🏁", color: success ? .green : .red)
        
        DispatchQueue.main.async {
            completion?(success)
        }
    }
    
    private func markAsFailed(_ cameraId: String) {
        DispatchQueue.main.async {
            self.failedCameras.insert(cameraId)
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
            guard let data = image.jpegData(compressionQuality: 0.5) else { return }
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
        
        DebugLogger.shared.log("🧹 Memory thumbnails cleared", emoji: "🧹", color: .orange)
    }
    
    deinit {
        emergencyTimer?.invalidate()
    }
}

// MARK: - Capture Handler
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