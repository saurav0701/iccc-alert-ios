import Foundation
import UIKit
import WebKit
import Combine

// MARK: - Thumbnail Cache Manager (Captures from WebRTC Stream)
class ThumbnailCacheManager: ObservableObject {
    static let shared = ThumbnailCacheManager()
    
    @Published private(set) var thumbnails: [String: UIImage] = [:]
    
    private let cache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private var activeFetches: Set<String> = []
    private var captureWebViews: [String: WKWebView] = [:]
    private let lock = NSLock()
    
    private init() {
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = paths[0].appendingPathComponent("CameraThumbnails")
        
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
        cache.countLimit = 200
        cache.totalCostLimit = 50 * 1024 * 1024 // 50MB
        
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
    
    // MARK: - Fetch Thumbnail (Capture from WebRTC Stream)
    
    func fetchThumbnail(for camera: Camera, force: Bool = false) {
        lock.lock()
        let isAlreadyFetching = activeFetches.contains(camera.id)
        lock.unlock()
        
        if isAlreadyFetching && !force {
            return
        }
        
        if !force && getThumbnail(for: camera.id) != nil {
            return
        }
        
        lock.lock()
        activeFetches.insert(camera.id)
        lock.unlock()
        
        DebugLogger.shared.log("📸 Starting stream capture for: \(camera.id)", emoji: "📸", color: .blue)
        
        DispatchQueue.main.async {
            self.captureFromStream(camera: camera)
        }
    }
    
    // MARK: - Capture from Stream
    
    private func captureFromStream(camera: Camera) {
        guard let streamURL = camera.webrtcStreamURL else {
            DebugLogger.shared.log("⚠️ No stream URL for: \(camera.id)", emoji: "⚠️", color: .orange)
            removeFetchTask(for: camera.id)
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
        
        // Setup capture callback BEFORE creating WebView
        config.userContentController.add(
            ThumbnailCaptureHandler(cameraId: camera.id, manager: self),
            name: "captureComplete"
        )
        
        // Add console log handler
        let consoleScript = """
        console.log = function(message) {
            window.webkit.messageHandlers.consoleLog.postMessage(String(message));
        };
        console.error = function(message) {
            window.webkit.messageHandlers.consoleLog.postMessage('ERROR: ' + String(message));
        };
        """
        let consoleScriptHandler = WKUserScript(source: consoleScript, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        config.userContentController.addUserScript(consoleScriptHandler)
        config.userContentController.add(
            ConsoleLogHandler(cameraId: camera.id),
            name: "consoleLog"
        )
        
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.backgroundColor = .black
        webView.isOpaque = true
        
        lock.lock()
        captureWebViews[camera.id] = webView
        lock.unlock()
        
        // Load stream HTML with auto-capture
        let html = generateCaptureHTML(streamURL: streamURL)
        webView.loadHTMLString(html, baseURL: nil)
        
        // Timeout after 15 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
            guard let self = self else { return }
            
            self.lock.lock()
            let stillActive = self.activeFetches.contains(camera.id)
            self.lock.unlock()
            
            if stillActive {
                DebugLogger.shared.log("⏱️ Capture timeout for: \(camera.id)", emoji: "⏱️", color: .orange)
                self.cleanupCaptureWebView(for: camera.id)
                self.removeFetchTask(for: camera.id)
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
                
                console.log('🎬 Starting capture for stream:', streamUrl);
                
                async function start() {
                    try {
                        console.log('📡 Creating RTCPeerConnection...');
                        pc = new RTCPeerConnection({
                            iceServers: [{ urls: 'stun:stun.l.google.com:19302' }]
                        });
                        
                        pc.ontrack = (e) => {
                            console.log('📹 Received track, setting srcObject');
                            video.srcObject = e.streams[0];
                        };
                        
                        pc.oniceconnectionstatechange = () => {
                            console.log('🔗 ICE state:', pc.iceConnectionState);
                        };
                        
                        pc.addTransceiver('video', { direction: 'recvonly' });
                        pc.addTransceiver('audio', { direction: 'recvonly' });
                        
                        const offer = await pc.createOffer();
                        await pc.setLocalDescription(offer);
                        
                        console.log('📤 Sending offer to server...');
                        const res = await fetch(streamUrl, {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/sdp' },
                            body: offer.sdp
                        });
                        
                        if (!res.ok) {
                            console.error('❌ Server error:', res.status);
                            throw new Error('Server error: ' + res.status);
                        }
                        
                        const answer = await res.text();
                        console.log('📥 Received answer from server');
                        await pc.setRemoteDescription({ type: 'answer', sdp: answer });
                        console.log('✅ Connection setup complete');
                        
                    } catch(err) {
                        console.error('❌ Stream error:', err);
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.captureComplete) {
                            window.webkit.messageHandlers.captureComplete.postMessage({ 
                                success: false,
                                error: err.toString()
                            });
                        }
                    }
                }
                
                // Capture frame when video starts playing
                video.addEventListener('loadedmetadata', () => {
                    console.log('📊 Video metadata loaded:', video.videoWidth + 'x' + video.videoHeight);
                });
                
                video.addEventListener('playing', () => {
                    console.log('▶️ Video playing!');
                    if (captured) {
                        console.log('⚠️ Already captured, skipping');
                        return;
                    }
                    captured = true;
                    
                    setTimeout(() => {
                        try {
                            console.log('📸 Capturing frame...');
                            canvas.width = video.videoWidth || 320;
                            canvas.height = video.videoHeight || 240;
                            ctx.drawImage(video, 0, 0);
                            
                            const imageData = canvas.toDataURL('image/jpeg', 0.8);
                            console.log('✅ Frame captured, size:', imageData.length, 'bytes');
                            
                            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.captureComplete) {
                                window.webkit.messageHandlers.captureComplete.postMessage({
                                    success: true,
                                    imageData: imageData
                                });
                                console.log('📤 Image sent to Swift');
                            } else {
                                console.error('❌ webkit.messageHandlers not available');
                            }
                        } catch(err) {
                            console.error('❌ Capture error:', err);
                            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.captureComplete) {
                                window.webkit.messageHandlers.captureComplete.postMessage({ 
                                    success: false,
                                    error: err.toString()
                                });
                            }
                        }
                    }, 500);
                });
                
                video.addEventListener('error', (e) => {
                    console.error('❌ Video error:', e);
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
        DebugLogger.shared.log("📷 Received capture for: \(cameraId)", emoji: "📷", color: .green)
        
        // Parse base64 data URL
        guard let commaIndex = imageDataURL.firstIndex(of: ",") else {
            DebugLogger.shared.log("❌ Invalid image data for: \(cameraId)", emoji: "❌", color: .red)
            cleanupCaptureWebView(for: cameraId)
            removeFetchTask(for: cameraId)
            return
        }
        
        let base64String = String(imageDataURL[imageDataURL.index(after: commaIndex)...])
        
        guard let imageData = Data(base64Encoded: base64String),
              let image = UIImage(data: imageData) else {
            DebugLogger.shared.log("❌ Failed to decode image for: \(cameraId)", emoji: "❌", color: .red)
            cleanupCaptureWebView(for: cameraId)
            removeFetchTask(for: cameraId)
            return
        }
        
        // Resize to save memory
        let resizedImage = resizeImage(image, targetWidth: 320)
        
        // Save to cache
        DispatchQueue.main.async {
            self.thumbnails[cameraId] = resizedImage
            self.cache.setObject(resizedImage, forKey: cameraId as NSString)
            
            DebugLogger.shared.log("✅ Thumbnail saved: \(cameraId) (\(Int(image.size.width))x\(Int(image.size.height)))", emoji: "✅", color: .green)
            
            // Save to disk
            self.saveThumbnail(resizedImage, for: cameraId)
            
            // Cleanup
            self.cleanupCaptureWebView(for: cameraId)
            self.removeFetchTask(for: cameraId)
        }
    }
    
    // MARK: - Cleanup
    
    func cleanupCaptureWebView(for cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        if let webView = captureWebViews.removeValue(forKey: cameraId) {
            DispatchQueue.main.async {
                webView.stopLoading()
                webView.loadHTMLString("", baseURL: nil)
                webView.configuration.userContentController.removeAllScriptMessageHandlers()
            }
            DebugLogger.shared.log("🧹 Cleaned up capture webview for: \(cameraId)", emoji: "🧹", color: .gray)
        }
    }
    
    func removeFetchTask(for cameraId: String) {
        lock.lock()
        activeFetches.remove(cameraId)
        lock.unlock()
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
            guard let data = image.jpegData(compressionQuality: 0.8) else { return }
            
            let fileURL = self.cacheDirectory.appendingPathComponent("\(cameraId).jpg")
            try? data.write(to: fileURL)
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
        let webViews = captureWebViews
        captureWebViews.removeAll()
        lock.unlock()
        
        for (cameraId, _) in webViews {
            cleanupCaptureWebView(for: cameraId)
        }
        
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        
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
            DebugLogger.shared.log("❌ Invalid message format for: \(cameraId)", emoji: "❌", color: .red)
            return
        }
        
        if let success = dict["success"] as? Bool, success,
           let imageData = dict["imageData"] as? String {
            DebugLogger.shared.log("✅ JavaScript capture successful for: \(cameraId)", emoji: "✅", color: .green)
            manager?.handleCapturedImage(cameraId: cameraId, imageDataURL: imageData)
        } else {
            let error = dict["error"] as? String ?? "Unknown error"
            DebugLogger.shared.log("❌ Capture failed for: \(cameraId) - \(error)", emoji: "❌", color: .red)
            manager?.cleanupCaptureWebView(for: cameraId)
            manager?.removeFetchTask(for: cameraId)
        }
    }
}

// MARK: - Console Log Handler
class ConsoleLogHandler: NSObject, WKScriptMessageHandler {
    let cameraId: String
    
    init(cameraId: String) {
        self.cameraId = cameraId
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let logMessage = message.body as? String {
            DebugLogger.shared.log("[\(cameraId)] \(logMessage)", emoji: "🌐", color: .gray)
        }
    }
}