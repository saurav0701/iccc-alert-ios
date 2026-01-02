import Foundation
import UIKit
import WebKit
import Combine
import SwiftUI

// MARK: - CRASH-PROOF Thumbnail Cache Manager
class ThumbnailCacheManager: ObservableObject {
    static let shared = ThumbnailCacheManager()
    
    @Published private(set) var thumbnails: [String: UIImage] = [:]
    @Published private(set) var thumbnailTimestamps: [String: Date] = [:]
    @Published private(set) var failedCameras: Set<String> = []
    @Published private(set) var loadingCameras: Set<String> = []
    
    private let cache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    
    // CRITICAL: Separate queue for ALL thumbnail operations
    private let captureQueue = DispatchQueue(label: "com.iccc.thumbnail.capture", qos: .userInitiated)
    private let cleanupQueue = DispatchQueue(label: "com.iccc.thumbnail.cleanup", qos: .utility)
    
    // FIXED: Per-camera state tracking (not global)
    private var activeCaptureStates: [String: CaptureState] = [:]
    private let stateLock = NSLock()
    
    // Rate limiting
    private var lastCaptureTime: TimeInterval = 0
    private let minimumCaptureInterval: TimeInterval = 3.0
    
    // Cache duration: 3 hours
    private let cacheDuration: TimeInterval = 3 * 60 * 60
    
    private init() {
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = paths[0].appendingPathComponent("CameraThumbnails")
        
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        cache.countLimit = 30
        cache.totalCostLimit = 10 * 1024 * 1024
        
        loadCachedThumbnails()
        loadTimestamps()
        setupMemoryWarning()
        
        DebugLogger.shared.log("🖼️ ThumbnailCacheManager initialized (CRASH-PROOF)", emoji: "🖼️", color: .blue)
    }
    
    // MARK: - Capture State Management
    
    private class CaptureState {
        weak var webView: WKWebView?
        weak var handler: ThumbnailCaptureHandler?
        var timeoutWork: DispatchWorkItem?
        let startTime: Date
        var isCleanedUp: Bool = false
        
        init(webView: WKWebView, handler: ThumbnailCaptureHandler, timeoutWork: DispatchWorkItem) {
            self.webView = webView
            self.handler = handler
            self.timeoutWork = timeoutWork
            self.startTime = Date()
        }
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
        DebugLogger.shared.log("🧹 Starting emergency cleanup", emoji: "🧹", color: .orange)
        
        stateLock.lock()
        let allStates = activeCaptureStates.values.map { $0 }
        activeCaptureStates.removeAll()
        stateLock.unlock()
        
        DispatchQueue.main.async {
            self.loadingCameras.removeAll()
        }
        
        // Cancel all timeouts first
        allStates.forEach { $0.timeoutWork?.cancel() }
        
        // Cleanup WebViews on background queue with delay
        cleanupQueue.async {
            allStates.forEach { state in
                if let webView = state.webView {
                    DispatchQueue.main.async {
                        self.safeDestroyWebView(webView)
                    }
                }
            }
        }
        
        // Clear memory cache
        cache.removeAllObjects()
        thumbnails.removeAll()
        
        DebugLogger.shared.log("✅ Emergency cleanup complete", emoji: "✅", color: .green)
    }
    
    // MARK: - Public API
    
    func getThumbnail(for cameraId: String) -> UIImage? {
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
    
    func isThumbnailFresh(for cameraId: String) -> Bool {
        guard let timestamp = thumbnailTimestamps[cameraId] else {
            return false
        }
        let age = Date().timeIntervalSince(timestamp)
        return age < cacheDuration
    }
    
    // MARK: - Manual Load (CRASH-PROOF)
    
    func manualLoad(for camera: Camera, completion: @escaping (Bool) -> Void) {
        // Check rate limiting
        let now = Date().timeIntervalSince1970
        let timeSinceLastCapture = now - lastCaptureTime
        
        if timeSinceLastCapture < minimumCaptureInterval {
            let remainingTime = Int(ceil(minimumCaptureInterval - timeSinceLastCapture))
            DebugLogger.shared.log("⏳ Rate limit: wait \(remainingTime)s", emoji: "⏳", color: .orange)
            
            DispatchQueue.main.async {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                completion(false)
            }
            return
        }
        
        // Check if already loading
        stateLock.lock()
        let isAlreadyLoading = activeCaptureStates[camera.id] != nil
        stateLock.unlock()
        
        if isAlreadyLoading {
            DebugLogger.shared.log("⚠️ Already loading: \(camera.id)", emoji: "⚠️", color: .orange)
            completion(false)
            return
        }
        
        // Check if fresh thumbnail exists
        if isThumbnailFresh(for: camera.id), getThumbnail(for: camera.id) != nil {
            DebugLogger.shared.log("✅ Using cached thumbnail", emoji: "✅", color: .green)
            completion(true)
            return
        }
        
        // Start capture on dedicated queue
        captureQueue.async {
            self.performCapture(for: camera, completion: completion)
        }
    }
    
    // MARK: - Capture Implementation (ISOLATED)
    
    private func performCapture(for camera: Camera, completion: @escaping (Bool) -> Void) {
        guard let streamURL = camera.webrtcStreamURL else {
            DebugLogger.shared.log("❌ No stream URL", emoji: "❌", color: .red)
            markAsFailed(camera.id)
            completion(false)
            return
        }
        
        lastCaptureTime = Date().timeIntervalSince1970
        
        DispatchQueue.main.async {
            self.loadingCameras.insert(camera.id)
            self.failedCameras.remove(camera.id)
        }
        
        DebugLogger.shared.log("📸 Starting capture: \(camera.displayName)", emoji: "📸", color: .blue)
        
        // Create WebView on main thread
        DispatchQueue.main.async {
            self.createAndExecuteCapture(streamURL: streamURL, cameraId: camera.id, completion: completion)
        }
    }
    
    private func createAndExecuteCapture(streamURL: String, cameraId: String, completion: @escaping (Bool) -> Void) {
        // Create configuration
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        config.websiteDataStore = .nonPersistent()
        
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        
        // CRITICAL: Use weak capture in handler to prevent retain cycles
        let handler = ThumbnailCaptureHandler(cameraId: cameraId) { [weak self] success, imageData in
            guard let self = self else { return }
            
            // Process result on capture queue
            self.captureQueue.async {
                self.handleCaptureResult(cameraId: cameraId, success: success, imageData: imageData, completion: completion)
            }
        }
        
        // Add handler BEFORE creating WebView
        config.userContentController.add(handler, name: "captureComplete")
        
        // Create WebView
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 240, height: 180), configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.backgroundColor = .black
        webView.isOpaque = true
        webView.alpha = 0.01
        
        // Add to window (off-screen)
        if let window = UIApplication.shared.windows.first {
            window.addSubview(webView)
            webView.frame = CGRect(x: -2000, y: -2000, width: 240, height: 180)
        }
        
        // Create timeout work item
        let timeoutWork = DispatchWorkItem { [weak self, weak webView] in
            guard let self = self else { return }
            
            DebugLogger.shared.log("⏱️ Capture timeout: \(cameraId)", emoji: "⏱️", color: .orange)
            
            // Cleanup on main thread
            DispatchQueue.main.async {
                if let wv = webView {
                    self.safeDestroyWebView(wv)
                }
                
                self.captureQueue.async {
                    self.finishCapture(cameraId: cameraId, success: false, completion: completion)
                }
            }
        }
        
        // Store state
        stateLock.lock()
        activeCaptureStates[cameraId] = CaptureState(webView: webView, handler: handler, timeoutWork: timeoutWork)
        stateLock.unlock()
        
        // Load HTML
        let html = generateCaptureHTML(streamURL: streamURL)
        webView.loadHTMLString(html, baseURL: nil)
        
        // Schedule timeout (7 seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.0, execute: timeoutWork)
    }
    
    private func handleCaptureResult(cameraId: String, success: Bool, imageData: String?, completion: @escaping (Bool) -> Void) {
        // Remove state
        stateLock.lock()
        let state = activeCaptureStates.removeValue(forKey: cameraId)
        stateLock.unlock()
        
        // Cancel timeout
        state?.timeoutWork?.cancel()
        
        // Cleanup WebView on main thread
        if let webView = state?.webView {
            DispatchQueue.main.async {
                self.safeDestroyWebView(webView)
            }
        }
        
        if success, let imageData = imageData {
            DebugLogger.shared.log("✅ Capture succeeded: \(cameraId)", emoji: "✅", color: .green)
            processCapturedImage(cameraId: cameraId, imageDataURL: imageData, completion: completion)
        } else {
            DebugLogger.shared.log("❌ Capture failed: \(cameraId)", emoji: "❌", color: .red)
            markAsFailed(cameraId)
            finishCapture(cameraId: cameraId, success: false, completion: completion)
        }
    }
    
    // MARK: - Safe WebView Destruction (NO CRASHES)
    
    private func safeDestroyWebView(_ webView: WKWebView) {
        // Must be called on main thread
        assert(Thread.isMainThread, "safeDestroyWebView must be called on main thread")
        
        // 1. Stop loading immediately
        webView.stopLoading()
        
        // 2. Clear delegates
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        
        // 3. CRITICAL: Remove script handlers by name (not removeAll)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "captureComplete")
        
        // 4. Remove from superview BEFORE loading blank
        webView.removeFromSuperview()
        
        // 5. Load blank page (with delay to ensure JS cleanup)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            webView.loadHTMLString("", baseURL: nil)
            
            // 6. Clear website data after another delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let dataStore = WKWebsiteDataStore.nonPersistent()
                dataStore.removeData(
                    ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                    modifiedSince: Date(timeIntervalSince1970: 0),
                    completionHandler: {}
                )
            }
        }
        
        DebugLogger.shared.log("🧹 WebView safely destroyed", emoji: "🧹", color: .gray)
    }
    
    // MARK: - HTML Generation
    
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
                            iceServers: [{ urls: 'stun:stun.l.google.com:19302' }]
                        });
                        
                        pc.ontrack = (e) => { 
                            if (!captured) video.srcObject = e.streams[0];
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
                
                video.addEventListener('error', fail);
                window.addEventListener('beforeunload', cleanup);
                
                start();
            })();
            </script>
        </body>
        </html>
        """
    }
    
    // MARK: - Image Processing
    
    private func processCapturedImage(cameraId: String, imageDataURL: String, completion: @escaping (Bool) -> Void) {
        guard let commaIndex = imageDataURL.firstIndex(of: ",") else {
            markAsFailed(cameraId)
            finishCapture(cameraId: cameraId, success: false, completion: completion)
            return
        }
        
        let base64String = String(imageDataURL[imageDataURL.index(after: commaIndex)...])
        
        guard let imageData = Data(base64Encoded: base64String),
              let image = UIImage(data: imageData) else {
            markAsFailed(cameraId)
            finishCapture(cameraId: cameraId, success: false, completion: completion)
            return
        }
        
        let resizedImage = resizeImage(image, targetWidth: 240)
        
        DispatchQueue.main.async {
            self.thumbnails[cameraId] = resizedImage
            self.cache.setObject(resizedImage, forKey: cameraId as NSString)
            self.thumbnailTimestamps[cameraId] = Date()
            self.failedCameras.remove(cameraId)
            
            self.saveThumbnail(resizedImage, for: cameraId)
            self.saveTimestamps()
            
            self.finishCapture(cameraId: cameraId, success: true, completion: completion)
        }
    }
    
    private func finishCapture(_ cameraId: String, success: Bool, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            self.loadingCameras.remove(cameraId)
            
            DebugLogger.shared.log("🏁 Capture finished: \(cameraId) - \(success ? "SUCCESS" : "FAILED")", emoji: "🏁", color: success ? .green : .red)
            
            completion(success)
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
            ) else { return }
            
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
        thumbnails.removeValue(forKey: cameraId)
        thumbnailTimestamps.removeValue(forKey: cameraId)
        cache.removeObject(forKey: cameraId as NSString)
        failedCameras.remove(cameraId)
        loadingCameras.remove(cameraId)
        
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
        let keysToRemove = Array(thumbnails.keys)
        
        for key in keysToRemove {
            cache.removeObject(forKey: key as NSString)
        }
        
        DebugLogger.shared.log("🧹 Channel thumbnails cleared from memory", emoji: "🧹", color: .orange)
    }
}

// MARK: - Capture Handler (WEAK REFERENCES)
class ThumbnailCaptureHandler: NSObject, WKScriptMessageHandler {
    let cameraId: String
    let callback: (Bool, String?) -> Void
    
    init(cameraId: String, callback: @escaping (Bool, String?) -> Void) {
        self.cameraId = cameraId
        self.callback = callback
        super.init()
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