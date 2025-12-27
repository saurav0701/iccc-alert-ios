import SwiftUI
import WebKit
import AVFoundation

// ✅ OPTIMIZED: Conservative caching strategy
class WebViewStore {
    static let shared = WebViewStore()
    
    private struct CachedWebView {
        let webView: WKWebView
        let createdAt: Date
        let cameraId: String
        var lastAccessTime: Date
        var isActive: Bool
    }
    
    private var cache: [String: CachedWebView] = [:]
    private let cacheExpiration: TimeInterval = 300 // 5 minutes
    private let maxCacheSize = 6 // Reduced from 12
    private let lock = NSLock()
    
    func getWebView(for cameraId: String, streamURL: String) -> WKWebView? {
        lock.lock()
        defer { lock.unlock() }
        
        guard var cached = cache[cameraId] else { return nil }
        
        let age = Date().timeIntervalSince1970 - cached.createdAt.timeIntervalSince1970
        if age > cacheExpiration {
            print("♻️ Cache expired for: \(cameraId)")
            cleanupWebView(cached.webView)
            cache.removeValue(forKey: cameraId)
            return nil
        }
        
        cached.lastAccessTime = Date()
        cached.isActive = true
        cache[cameraId] = cached
        
        print("✅ Reusing cached WebView for: \(cameraId) (age: \(Int(age))s)")
        return cached.webView
    }
    
    func cacheWebView(_ webView: WKWebView, for cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        if cache[cameraId] != nil {
            print("⚠️ WebView already cached for: \(cameraId)")
            return
        }
        
        if cache.count >= maxCacheSize {
            let inactiveEntries = cache.filter { !$0.value.isActive }
                .sorted { $0.value.lastAccessTime < $1.value.lastAccessTime }
            
            if let oldestKey = inactiveEntries.first?.key {
                if let old = cache.removeValue(forKey: oldestKey) {
                    print("🗑️ Removing old inactive cache: \(oldestKey)")
                    cleanupWebView(old.webView)
                }
            }
        }
        
        cache[cameraId] = CachedWebView(
            webView: webView,
            createdAt: Date(),
            cameraId: cameraId,
            lastAccessTime: Date(),
            isActive: true
        )
        print("💾 Cached new WebView for: \(cameraId) (total: \(cache.count))")
    }
    
    func markInactive(_ cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        if var cached = cache[cameraId] {
            cached.isActive = false
            cache[cameraId] = cached
            print("📤 Marked WebView as inactive: \(cameraId)")
        }
    }
    
    private func cleanupWebView(_ webView: WKWebView) {
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.loadHTMLString("", baseURL: nil)
    }
    
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        
        cache.values.forEach { cleanupWebView($0.webView) }
        cache.removeAll()
        print("🧹 Cleared all cached WebViews")
    }
    
    func clearInactive() {
        lock.lock()
        defer { lock.unlock() }
        
        let inactive = cache.filter { !$0.value.isActive }
        inactive.forEach { key, cached in
            cleanupWebView(cached.webView)
            cache.removeValue(forKey: key)
        }
        print("🧹 Cleared \(inactive.count) inactive WebViews")
    }
}

class AudioSessionManager {
    static let shared = AudioSessionManager()
    
    func configure() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            print("❌ Failed to configure audio session: \(error)")
        }
    }
}

// MARK: - WebView HLS Player (HEAVILY OPTIMIZED)
struct WebViewHLSPlayer: UIViewRepresentable {
    let streamURL: String
    let cameraId: String
    let cameraName: String
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    let isFullscreen: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        if let cached = WebViewStore.shared.getWebView(for: cameraId, streamURL: streamURL) {
            print("♻️ Reusing cached WebView for: \(cameraName)")
            cached.navigationDelegate = context.coordinator
            setupMessageHandlers(for: cached, coordinator: context.coordinator)
            return cached
        }
        
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = false
        
        // ✅ Enable CORS and media playback
        if #available(iOS 14.0, *) {
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        }
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        
        setupMessageHandlers(for: webView, coordinator: context.coordinator)
        WebViewStore.shared.cacheWebView(webView, for: cameraId)
        AudioSessionManager.shared.configure()
        
        print("🆕 Created new WebView for: \(cameraName)")
        return webView
    }
    
    private func setupMessageHandlers(for webView: WKWebView, coordinator: Coordinator) {
        let controller = webView.configuration.userContentController
        
        controller.removeScriptMessageHandler(forName: "streamReady")
        controller.removeScriptMessageHandler(forName: "streamError")
        controller.removeScriptMessageHandler(forName: "streamLog")
        
        controller.add(coordinator, name: "streamReady")
        controller.add(coordinator, name: "streamError")
        controller.add(coordinator, name: "streamLog")
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastLoadedURL != streamURL else {
            return
        }
        
        let now = Date().timeIntervalSince1970
        if now - context.coordinator.lastLoadTime < 3.0 {
            print("⚠️ Preventing rapid reload for: \(cameraName)")
            return
        }
        
        if webView.isLoading {
            print("⚠️ WebView still loading, skipping reload for: \(cameraName)")
            return
        }
        
        context.coordinator.lastLoadedURL = streamURL
        context.coordinator.lastLoadTime = now
        
        let html = generateHTML()
        webView.loadHTMLString(html, baseURL: nil)
        print("📹 Loading stream for: \(cameraName) (fullscreen: \(isFullscreen))")
    }
    
    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        WebViewStore.shared.markInactive(coordinator.parent.cameraId)
        print("📤 WebView dismantled (kept in cache): \(coordinator.parent.cameraName)")
    }
    
    private func generateHTML() -> String {
        // ✅ CRITICAL: Only autoplay in fullscreen, thumbnails are muted and paused
        let autoplayAttr = isFullscreen ? "autoplay" : ""
        let mutedAttr = "muted" // Always muted initially
        let controlsAttr = isFullscreen ? "controls" : ""
        let playsinlineAttr = "playsinline"
        let preloadAttr = isFullscreen ? "preload=\"auto\"" : "preload=\"none\""
        
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                body { 
                    background: #000;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    height: 100vh;
                    width: 100vw;
                    overflow: hidden;
                    position: fixed;
                }
                #player {
                    width: 100%;
                    height: 100%;
                    object-fit: contain;
                    background: #000;
                }
                .error-overlay {
                    position: absolute;
                    top: 50%;
                    left: 50%;
                    transform: translate(-50%, -50%);
                    color: #fff;
                    text-align: center;
                    background: rgba(0,0,0,0.8);
                    padding: 20px;
                    border-radius: 10px;
                    display: none;
                }
            </style>
        </head>
        <body>
            <video id="player" \(autoplayAttr) \(playsinlineAttr) \(mutedAttr) \(controlsAttr) \(preloadAttr)></video>
            <div id="error" class="error-overlay"></div>
            <script src="https://cdn.jsdelivr.net/npm/hls.js@1.5.13/dist/hls.min.js"></script>
            <script>
                const video = document.getElementById('player');
                const errorDiv = document.getElementById('error');
                const videoSrc = '\(streamURL)';
                const isFullscreen = \(isFullscreen ? "true" : "false");
                
                let hls = null;
                let retryCount = 0;
                const maxRetries = 5;
                let isDestroyed = false;
                let loadStartTime = Date.now();
                
                function log(msg) {
                    console.log(msg);
                    try {
                        window.webkit.messageHandlers.streamLog.postMessage(msg);
                    } catch(e) {}
                }
                
                function showError(msg) {
                    errorDiv.textContent = msg;
                    errorDiv.style.display = 'block';
                    window.webkit.messageHandlers.streamError.postMessage(msg);
                }
                
                function cleanup() {
                    if (hls) {
                        log('🧹 Cleaning up HLS instance');
                        try {
                            hls.stopLoad();
                            hls.detachMedia();
                            hls.destroy();
                        } catch(e) {
                            log('⚠️ Error destroying HLS: ' + e.message);
                        }
                        hls = null;
                    }
                }
                
                function initPlayer() {
                    if (isDestroyed) return;
                    cleanup();
                    
                    loadStartTime = Date.now();
                    log('🎬 Initializing player: ' + videoSrc);
                    
                    if (Hls.isSupported()) {
                        hls = new Hls({
                            debug: false,
                            enableWorker: true,
                            lowLatencyMode: false,
                            
                            // ✅ OPTIMIZED: Much more conservative for thumbnails
                            maxBufferLength: isFullscreen ? 30 : 10,
                            maxMaxBufferLength: isFullscreen ? 60 : 20,
                            maxBufferSize: 30 * 1000 * 1000, // 30MB max
                            maxBufferHole: 1.0,
                            backBufferLength: isFullscreen ? 10 : 0,
                            
                            // ✅ CRITICAL: Much longer timeouts for slow connections
                            manifestLoadingTimeOut: 30000, // 30 seconds
                            manifestLoadingMaxRetry: 6,
                            manifestLoadingRetryDelay: 2000,
                            
                            levelLoadingTimeOut: 30000,
                            levelLoadingMaxRetry: 6,
                            levelLoadingRetryDelay: 2000,
                            
                            fragLoadingTimeOut: 30000,
                            fragLoadingMaxRetry: 6,
                            fragLoadingRetryDelay: 2000,
                            
                            // ✅ OPTIMIZED: Start with lowest quality for thumbnails
                            startLevel: isFullscreen ? -1 : 0,
                            autoStartLoad: true,
                            capLevelToPlayerSize: !isFullscreen,
                            
                            liveSyncDurationCount: 3,
                            liveMaxLatencyDurationCount: 10,
                            
                            startFragPrefetch: isFullscreen,
                            testBandwidth: isFullscreen,
                            
                            // ✅ NEW: Enable CORS credentials
                            xhrSetup: function(xhr, url) {
                                xhr.withCredentials = false; // Try without credentials first
                            }
                        });
                        
                        // ✅ CRITICAL: Timeout check
                        const loadTimeout = setTimeout(() => {
                            if (!hls || hls.media.readyState < 2) {
                                log('⏱️ Load timeout after 45s');
                                showError('Connection timeout - stream may be slow or unavailable');
                            }
                        }, 45000);
                        
                        hls.on(Hls.Events.ERROR, function(event, data) {
                            if (data.fatal) {
                                clearTimeout(loadTimeout);
                                log('❌ Fatal error: ' + data.type + ' - ' + data.details);
                                
                                switch(data.type) {
                                    case Hls.ErrorTypes.NETWORK_ERROR:
                                        if (retryCount < maxRetries) {
                                            retryCount++;
                                            const delay = Math.min(2000 * retryCount, 10000);
                                            log('🔄 Network retry ' + retryCount + '/' + maxRetries + ' in ' + (delay/1000) + 's');
                                            
                                            setTimeout(() => {
                                                if (hls && !isDestroyed) {
                                                    hls.startLoad();
                                                }
                                            }, delay);
                                        } else {
                                            showError('Network error - please check connection');
                                        }
                                        break;
                                        
                                    case Hls.ErrorTypes.MEDIA_ERROR:
                                        if (retryCount < maxRetries) {
                                            retryCount++;
                                            log('🔄 Media retry ' + retryCount + '/' + maxRetries);
                                            hls.recoverMediaError();
                                        } else {
                                            showError('Media playback failed');
                                        }
                                        break;
                                        
                                    default:
                                        showError('Stream error: ' + data.details);
                                        break;
                                }
                            } else if (data.details === Hls.ErrorDetails.BUFFER_STALLED_ERROR) {
                                log('⚠️ Buffer stalled - network may be slow');
                            }
                        });
                        
                        hls.on(Hls.Events.MANIFEST_PARSED, function(event, data) {
                            clearTimeout(loadTimeout);
                            const loadTime = ((Date.now() - loadStartTime) / 1000).toFixed(1);
                            log('✅ Manifest parsed in ' + loadTime + 's, levels: ' + data.levels.length);
                            
                            // Log available quality levels
                            data.levels.forEach((level, i) => {
                                log('   Level ' + i + ': ' + level.width + 'x' + level.height + ' @ ' + Math.round(level.bitrate/1000) + 'kbps');
                            });
                            
                            window.webkit.messageHandlers.streamReady.postMessage('ready');
                            retryCount = 0;
                            
                            if (isFullscreen) {
                                video.play()
                                    .then(() => log('▶️ Playing'))
                                    .catch(e => log('⚠️ Play error: ' + e.message));
                            }
                        });
                        
                        hls.on(Hls.Events.LEVEL_SWITCHED, function(event, data) {
                            const level = hls.levels[data.level];
                            log('🎥 Quality: ' + level.width + 'x' + level.height);
                        });
                        
                        hls.loadSource(videoSrc);
                        hls.attachMedia(video);
                        
                    } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
                        // Native HLS support (iOS Safari)
                        log('📱 Using native HLS');
                        video.src = videoSrc;
                        
                        const nativeTimeout = setTimeout(() => {
                            if (video.readyState < 2) {
                                showError('Connection timeout');
                            }
                        }, 45000);
                        
                        video.addEventListener('loadedmetadata', function() {
                            clearTimeout(nativeTimeout);
                            const loadTime = ((Date.now() - loadStartTime) / 1000).toFixed(1);
                            log('✅ Native HLS loaded in ' + loadTime + 's');
                            window.webkit.messageHandlers.streamReady.postMessage('ready');
                            
                            if (isFullscreen) {
                                video.play().catch(e => 
                                    log('⚠️ Play error: ' + e.message)
                                );
                            }
                        });
                        
                        video.addEventListener('error', function(e) {
                            clearTimeout(nativeTimeout);
                            log('❌ Native HLS error: ' + (video.error ? video.error.message : 'unknown'));
                            showError('Stream unavailable');
                        });
                        
                        video.load();
                    } else {
                        showError('HLS not supported on this device');
                    }
                }
                
                // ✅ Monitor video health
                video.addEventListener('waiting', function() {
                    log('⏳ Buffering...');
                });
                
                video.addEventListener('playing', function() {
                    log('▶️ Playing smoothly');
                });
                
                video.addEventListener('stalled', function() {
                    log('⚠️ Stream stalled');
                });
                
                initPlayer();
                
                window.addEventListener('beforeunload', function() {
                    isDestroyed = true;
                    cleanup();
                });
            </script>
        </body>
        </html>
        """
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: WebViewHLSPlayer
        var lastLoadedURL: String = ""
        var lastLoadTime: TimeInterval = 0
        
        init(_ parent: WebViewHLSPlayer) {
            self.parent = parent
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            DispatchQueue.main.async {
                switch message.name {
                case "streamReady":
                    self.parent.isLoading = false
                    self.parent.errorMessage = nil
                case "streamError":
                    let error = message.body as? String ?? "Stream error"
                    self.parent.isLoading = false
                    self.parent.errorMessage = error
                    print("❌ Stream error for \(self.parent.cameraName): \(error)")
                case "streamLog":
                    if let log = message.body as? String {
                        print("📹 [\(self.parent.cameraName)] \(log)")
                    }
                default:
                    break
                }
            }
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("📄 WebView loaded for: \(parent.cameraName)")
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.errorMessage = "Failed to load stream"
                self.parent.isLoading = false
                print("❌ WebView navigation failed: \(error.localizedDescription)")
            }
        }
    }
}