import Foundation
import UIKit
import WebKit
import Combine
import SwiftUI

// MARK: - Thumbnail Cache Manager (SINGLE ATTEMPT - NO RETRIES)
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
    
    // Cache duration: 3 hours
    private let cacheDuration: TimeInterval = 3 * 60 * 60
    
    private init() {
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = paths[0].appendingPathComponent("CameraThumbnails")
        
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        cache.countLimit = 50
        cache.totalCostLimit = 20 * 1024 * 1024 // 20MB max
        
        loadCachedThumbnails()
        loadTimestamps()
        
        setupMemoryWarning()
        
        DebugLogger.shared.log("🖼️ ThumbnailCacheManager initialized (SINGLE ATTEMPT MODE)", emoji: "🖼️", color: .blue)
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
        
        loadingCameras.removeAll()
        isCapturing = false
        
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
    
    // MARK: - Manual Load ONLY (SINGLE ATTEMPT)
    
    func manualLoad(for camera: Camera, completion: @escaping (Bool) -> Void) {
        lock.lock()
        
        // CRITICAL: Block if ANY capture is in progress
        if isCapturing {
            lock.unlock()
            DebugLogger.shared.log("⚠️ Capture already in progress - blocked", emoji: "⚠️", color: .orange)
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
        failedCameras.remove(camera.id) // Clear previous failure
        isCapturing = true
        
        lock.unlock()
        
        DebugLogger.shared.log("🔄 Starting capture (SINGLE ATTEMPT): \(camera.displayName)", emoji: "🔄", color: .blue)
        
        startCapture(for: camera, completion: completion)
    }
    
    // MARK: - Core Capture Logic (SINGLE ATTEMPT - 10 SECOND TIMEOUT)
    
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
        
        // Create WebView
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.backgroundColor = .black
        webView.isOpaque = true
        webView.alpha = 0.01
        
        // Add off-screen
        if let window = UIApplication.shared.windows.first {
            window.addSubview(webView)
            webView.frame = CGRect(x: -2000, y: -2000, width: 320, height: 240)
        }
        
        let html = generateCaptureHTML(streamURL: streamURL)
        webView.loadHTMLString(html, baseURL: nil)
        
        // CRITICAL: 10 second timeout - NO RETRIES
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak webView] in
            guard let webView = webView else { return }
            
            DebugLogger.shared.log("⏱️ Timeout reached - destroying WebView", emoji: "⏱️", color: .orange)
            self.destroyWebView(webView)
            
            // Check if still capturing (means timeout occurred before success)
            self.lock.lock()
            let stillCapturing = self.isCapturing && self.loadingCameras.contains(cameraId)
            self.lock.unlock()
            
            if stillCapturing {
                DebugLogger.shared.log("❌ Capture timeout: \(cameraId)", emoji: "❌", color: .red)
                self.markAsFailed(cameraId)
                self.finishCapture(cameraId, success: false, completion: completion)
            }
        }
    }
    
    private func generateCaptureHTML(streamURL: String) -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
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
                        pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:stun.l.google.com:19302' }] });
                        pc.ontrack = (e) => { if (!captured) video.srcObject = e.streams[0]; };
                        pc.addTransceiver('video', { direction: 'recvonly' });
                        pc.addTransceiver('audio', { direction: 'recvonly' });
                        
                        const offer = await pc.createOffer();
                        await pc.setLocalDescription(offer);
                        
                        const controller = new AbortController();
                        setTimeout(() => controller.abort(), 8000);
                        
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
                        console.error('Capture error:', err);
                        fail();
                    }
                }
                
                video.addEventListener('playing', () => {
                    if (captured) return;
                    captured = true;
                    
                    setTimeout(() => {
                        try {
                            canvas.width = video.videoWidth || 320;
                            canvas.height = video.videoHeight || 240;
                            ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
                            const imageData = canvas.toDataURL('image/jpeg', 0.6);
                            
                            cleanup();
                            
                            if (window.webkit?.messageHandlers?.captureComplete) {
                                window.webkit.messageHandlers.captureComplete.postMessage({
                                    success: true,
                                    imageData: imageData
                                });
                            }
                        } catch(err) {
                            console.error('Canvas error:', err);
                            fail();
                        }
                    }, 400);
                });
                
                video.addEventListener('error', () => fail());
                
                start();
            })();
            </script>
        </body>
        </html>
        """
    }
    
    private func destroyWebView(_ webView: WKWebView) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.removeFromSuperview()
        
        let dataStore = WKWebsiteDataStore.nonPersistent()
        dataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: Date(timeIntervalSince1970: 0),
            completionHandler: {}
        )
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
        
        let resizedImage = resizeImage(image, targetWidth: 320)
        
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
        isCapturing = false
        lock.unlock()
        
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
        thumbnails.removeAll()
        thumbnailTimestamps.removeAll()
        failedCameras.removeAll()
        cache.removeAllObjects()
        loadingCameras.removeAll()
        isCapturing = false
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