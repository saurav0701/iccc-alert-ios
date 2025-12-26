import SwiftUI
import WebKit
import AVFoundation

// ✅ FIXED: Smart WebView caching with expiration and cleanup
class WebViewStore {
    static let shared = WebViewStore()
    
    private struct CachedWebView {
        let webView: WKWebView
        let createdAt: Date
        let streamURL: String
    }
    
    private var cache: [String: CachedWebView] = [:]
    private let cacheExpiration: TimeInterval = 300 // 5 minutes
    private let maxCacheSize = 10
    private let lock = NSLock()
    
    func getWebView(for key: String, streamURL: String) -> WKWebView? {
        lock.lock()
        defer { lock.unlock() }
        
        guard let cached = cache[key] else { return nil }
        
        // Check if expired or URL changed
        let age = Date().timeIntervalSince(cached.createdAt)
        if age > cacheExpiration || cached.streamURL != streamURL {
            print("♻️ Cache expired or URL changed for: \(key)")
            cleanupWebView(cached.webView)
            cache.removeValue(forKey: key)
            return nil
        }
        
        return cached.webView
    }
    
    func cacheWebView(_ webView: WKWebView, for key: String, streamURL: String) {
        lock.lock()
        defer { lock.unlock() }
        
        // Remove oldest if at capacity
        if cache.count >= maxCacheSize {
            if let oldestKey = cache.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
                if let old = cache.removeValue(forKey: oldestKey) {
                    cleanupWebView(old.webView)
                }
            }
        }
        
        cache[key] = CachedWebView(webView: webView, createdAt: Date(), streamURL: streamURL)
    }
    
    func removeWebView(for key: String) {
        lock.lock()
        defer { lock.unlock() }
        
        if let cached = cache.removeValue(forKey: key) {
            cleanupWebView(cached.webView)
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
}

// ✅ Audio session configuration
class AudioSessionManager {
    static let shared = AudioSessionManager()
    
    func configure() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try audioSession.setActive(true)
            print("✅ Audio session configured")
        } catch {
            print("❌ Failed to configure audio session: \(error)")
        }
    }
}

// MARK: - WebView HLS Player (Fixed)
struct WebViewHLSPlayer: UIViewRepresentable {
    let streamURL: String
    let cameraName: String
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    let isFullscreen: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        let cacheKey = "\(cameraName)_\(isFullscreen ? "full" : "thumb")"
        
        // Try to reuse cached WebView
        if let cached = WebViewStore.shared.getWebView(for: cacheKey, streamURL: streamURL) {
            print("♻️ Reusing cached WebView for: \(cameraName)")
            cached.navigationDelegate = context.coordinator
            return cached
        }
        
        // Create new WebView
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = false
        
        if #available(iOS 14.0, *) {
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        }
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        
        // Add message handlers
        webView.configuration.userContentController.add(context.coordinator, name: "streamReady")
        webView.configuration.userContentController.add(context.coordinator, name: "streamError")
        webView.configuration.userContentController.add(context.coordinator, name: "streamLog")
        
        // Cache it
        WebViewStore.shared.cacheWebView(webView, for: cacheKey, streamURL: streamURL)
        
        AudioSessionManager.shared.configure()
        
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        // Always reload for fullscreen (fresh stream)
        if isFullscreen || context.coordinator.lastLoadedURL != streamURL {
            context.coordinator.lastLoadedURL = streamURL
            let html = generateHTML()
            webView.loadHTMLString(html, baseURL: nil)
            print("📹 Loading stream for: \(cameraName) (fullscreen: \(isFullscreen))")
        }
    }
    
    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        // Clean up when view is removed
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "streamReady")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "streamError")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "streamLog")
    }
    
    private func generateHTML() -> String {
        // ✅ CRITICAL FIX: Proper HLS.js configuration for iOS
        let autoplayAttr = isFullscreen ? "autoplay" : ""
        let mutedAttr = "muted"
        let controlsAttr = isFullscreen ? "controls" : ""
        let playsinlineAttr = "playsinline"
        let preloadAttr = isFullscreen ? "preload=\"auto\"" : "preload=\"metadata\""
        
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
            </style>
        </head>
        <body>
            <video id="player" \(autoplayAttr) \(playsinlineAttr) \(mutedAttr) \(controlsAttr) \(preloadAttr)></video>
            <script src="https://cdn.jsdelivr.net/npm/hls.js@1.5.13/dist/hls.min.js"></script>
            <script>
                const video = document.getElementById('player');
                const videoSrc = '\(streamURL)';
                const isFullscreen = \(isFullscreen ? "true" : "false");
                
                let hls = null;
                let retryCount = 0;
                const maxRetries = 3;
                let isDestroyed = false;
                
                function log(msg) {
                    console.log(msg);
                    try {
                        window.webkit.messageHandlers.streamLog.postMessage(msg);
                    } catch(e) {}
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
                    if (video) {
                        video.pause();
                        video.removeAttribute('src');
                        video.load();
                    }
                }
                
                function initPlayer() {
                    if (isDestroyed) return;
                    cleanup();
                    
                    log('🎬 Initializing player: ' + videoSrc);
                    
                    if (Hls.isSupported()) {
                        hls = new Hls({
                            debug: false,
                            enableWorker: true,
                            lowLatencyMode: false,
                            
                            // ✅ CRITICAL: Optimized buffer settings for iOS
                            maxBufferLength: isFullscreen ? 20 : 5,
                            maxMaxBufferLength: isFullscreen ? 30 : 10,
                            maxBufferSize: 40 * 1000 * 1000, // 40MB max
                            maxBufferHole: 0.5,
                            
                            // ✅ CRITICAL: Reduce back buffer to prevent memory issues
                            backBufferLength: 10,
                            
                            // ✅ CRITICAL: Faster fragment loading timeouts
                            manifestLoadingTimeOut: 10000,
                            manifestLoadingMaxRetry: 3,
                            manifestLoadingRetryDelay: 500,
                            
                            levelLoadingTimeOut: 10000,
                            levelLoadingMaxRetry: 3,
                            levelLoadingRetryDelay: 500,
                            
                            fragLoadingTimeOut: 15000,
                            fragLoadingMaxRetry: 3,
                            fragLoadingRetryDelay: 500,
                            
                            // ✅ Start at lowest quality for fast startup
                            startLevel: 0,
                            autoStartLoad: true,
                            capLevelToPlayerSize: true,
                            
                            // ✅ Aggressive live sync
                            liveSyncDurationCount: 3,
                            liveMaxLatencyDurationCount: 10,
                            
                            startFragPrefetch: isFullscreen,
                            testBandwidth: isFullscreen,
                        });
                        
                        // ✅ CRITICAL: Proper error recovery
                        hls.on(Hls.Events.ERROR, function(event, data) {
                            if (data.fatal) {
                                log('❌ Fatal error: ' + data.type + ' - ' + data.details);
                                
                                switch(data.type) {
                                    case Hls.ErrorTypes.NETWORK_ERROR:
                                        log('⚠️ Network error - attempting recovery');
                                        if (retryCount < maxRetries) {
                                            retryCount++;
                                            setTimeout(() => {
                                                if (hls && !isDestroyed) {
                                                    log('🔄 Retry ' + retryCount + '/' + maxRetries);
                                                    hls.startLoad();
                                                }
                                            }, 1000 * retryCount);
                                        } else {
                                            window.webkit.messageHandlers.streamError.postMessage('Network connection failed');
                                            cleanup();
                                        }
                                        break;
                                        
                                    case Hls.ErrorTypes.MEDIA_ERROR:
                                        log('⚠️ Media error - attempting recovery');
                                        if (retryCount < maxRetries) {
                                            retryCount++;
                                            hls.recoverMediaError();
                                        } else {
                                            window.webkit.messageHandlers.streamError.postMessage('Media playback failed');
                                            cleanup();
                                        }
                                        break;
                                        
                                    default:
                                        log('❌ Unrecoverable error: ' + data.details);
                                        window.webkit.messageHandlers.streamError.postMessage('Stream failed: ' + data.details);
                                        cleanup();
                                        break;
                                }
                            } else if (data.details === Hls.ErrorDetails.BUFFER_STALLED_ERROR) {
                                log('⚠️ Buffer stalled - clearing and reloading');
                                if (hls) {
                                    hls.stopLoad();
                                    setTimeout(() => {
                                        if (hls && !isDestroyed) hls.startLoad(-1);
                                    }, 500);
                                }
                            }
                        });
                        
                        hls.on(Hls.Events.MANIFEST_PARSED, function(event, data) {
                            log('✅ Manifest parsed, levels: ' + data.levels.length);
                            window.webkit.messageHandlers.streamReady.postMessage('ready');
                            retryCount = 0;
                            
                            if (isFullscreen) {
                                video.play()
                                    .then(() => log('▶️ Playing'))
                                    .catch(e => log('⚠️ Play error: ' + e.message));
                            }
                        });
                        
                        // ✅ Monitor buffer health
                        hls.on(Hls.Events.FRAG_LOADED, function(event, data) {
                            if (isFullscreen && data.stats.loading.first > 5000) {
                                log('⚠️ Slow fragment load: ' + data.stats.loading.first + 'ms');
                            }
                        });
                        
                        hls.loadSource(videoSrc);
                        hls.attachMedia(video);
                        
                    } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
                        // Native HLS support (Safari)
                        video.src = videoSrc;
                        video.addEventListener('loadedmetadata', function() {
                            log('✅ Native HLS loaded');
                            window.webkit.messageHandlers.streamReady.postMessage('ready');
                            if (isFullscreen) {
                                video.play().catch(e => 
                                    window.webkit.messageHandlers.streamError.postMessage('Play error')
                                );
                            }
                        });
                        video.addEventListener('error', function() {
                            log('❌ Native HLS error');
                            window.webkit.messageHandlers.streamError.postMessage('Stream error');
                        });
                        video.load();
                    } else {
                        log('❌ HLS not supported');
                        window.webkit.messageHandlers.streamError.postMessage('HLS not supported');
                    }
                }
                
                // ✅ Handle stalls and errors
                video.addEventListener('stalled', function() {
                    log('⚠️ Video stalled');
                    if (hls && !isDestroyed && isFullscreen) {
                        setTimeout(() => {
                            hls.stopLoad();
                            setTimeout(() => { if (hls) hls.startLoad(-1); }, 500);
                        }, 1000);
                    }
                });
                
                video.addEventListener('waiting', function() {
                    log('⏳ Video waiting for data');
                });
                
                video.addEventListener('playing', function() {
                    log('▶️ Video playing');
                });
                
                video.addEventListener('pause', function() {
                    log('⏸️ Video paused');
                });
                
                // ✅ Initialize player
                initPlayer();
                
                // ✅ Cleanup on unload
                window.addEventListener('beforeunload', function() {
                    isDestroyed = true;
                    cleanup();
                });
                
                // ✅ Page visibility handling
                document.addEventListener('visibilitychange', function() {
                    if (document.hidden) {
                        log('📱 Page hidden - pausing');
                        if (video && !video.paused) video.pause();
                    } else if (isFullscreen) {
                        log('📱 Page visible - resuming');
                        if (video && video.paused) video.play().catch(e => log('Resume failed'));
                    }
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
                    if self.parent.isFullscreen, let log = message.body as? String {
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

// MARK: - Camera Thumbnail (Grid Preview)
struct CameraThumbnail: View {
    let camera: Camera
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var loadTimer: Timer? = nil
    
    var body: some View {
        ZStack {
            if let streamURL = camera.streamURL, camera.isOnline {
                WebViewHLSPlayer(
                    streamURL: streamURL,
                    cameraName: camera.displayName,
                    isLoading: $isLoading,
                    errorMessage: $errorMessage,
                    isFullscreen: false
                )
                .onAppear {
                    // Longer timeout for thumbnails
                    loadTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { _ in
                        if isLoading && errorMessage == nil {
                            isLoading = false
                        }
                    }
                }
                .onDisappear {
                    loadTimer?.invalidate()
                }
                
                if isLoading {
                    ZStack {
                        Color.black.opacity(0.7)
                        VStack(spacing: 8) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            Text("Loading...")
                                .font(.caption2)
                                .foregroundColor(.white)
                        }
                    }
                }
                
                if let error = errorMessage {
                    ZStack {
                        Color.black.opacity(0.9)
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.orange)
                            
                            Text("Stream Error")
                                .font(.caption2)
                                .foregroundColor(.white)
                            
                            Text(error)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.7))
                                .lineLimit(2)
                                .padding(.horizontal, 4)
                        }
                        .padding(8)
                    }
                }
            } else {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.gray.opacity(0.3),
                        Color.gray.opacity(0.1)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                
                VStack(spacing: 8) {
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.gray)
                    Text("Offline")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            
            if camera.isOnline && !isLoading && errorMessage == nil {
                VStack {
                    HStack {
                        Spacer()
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 6, height: 6)
                            Text("LIVE")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(4)
                        .padding(6)
                    }
                    Spacer()
                }
            }
        }
    }
}

// MARK: - Fullscreen HLS Player View
struct HLSPlayerView: View {
    let camera: Camera
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var showControls = true
    @State private var autoHideTimer: Timer? = nil
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let streamURL = camera.streamURL {
                WebViewHLSPlayer(
                    streamURL: streamURL,
                    cameraName: camera.displayName,
                    isLoading: $isLoading,
                    errorMessage: $errorMessage,
                    isFullscreen: true
                )
                .ignoresSafeArea()
                .onAppear {
                    AudioSessionManager.shared.configure()
                    resetAutoHideTimer()
                }
                .onDisappear {
                    autoHideTimer?.invalidate()
                    // Clean up cache for this camera when leaving fullscreen
                    WebViewStore.shared.removeWebView(for: "\(camera.displayName)_full")
                }
                .onTapGesture {
                    withAnimation {
                        showControls.toggle()
                    }
                    resetAutoHideTimer()
                }
            } else {
                errorView("Stream URL not available")
            }
            
            if isLoading {
                loadingView
            }
            
            if showControls {
                controlsOverlay
            }
            
            if let error = errorMessage {
                errorView(error)
            }
        }
        .navigationBarHidden(true)
        .statusBar(hidden: !showControls)
    }
    
    private func resetAutoHideTimer() {
        autoHideTimer?.invalidate()
        if showControls {
            autoHideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
                withAnimation {
                    showControls = false
                }
            }
        }
    }
    
    private var controlsOverlay: some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(camera.displayName)
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    HStack(spacing: 8) {
                        Text(camera.area)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                        
                        Circle()
                            .fill(camera.isOnline ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        
                        Text(camera.isOnline ? "Live" : "Offline")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                .padding()
                .background(Color.black.opacity(0.7))
                .cornerRadius(10)
                
                Spacer()
                
                Button(action: {
                    presentationMode.wrappedValue.dismiss()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.white)
                        .padding()
                }
            }
            .padding()
            .transition(.move(edge: .top))
            
            Spacer()
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
            
            Text("Connecting to stream...")
                .font(.headline)
                .foregroundColor(.white)
            
            Text(camera.displayName)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.8))
    }
    
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            
            Text("Stream Error")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text(message)
                .font(.body)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button(action: {
                presentationMode.wrappedValue.dismiss()
            }) {
                HStack {
                    Image(systemName: "arrow.left")
                    Text("Go Back")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.blue)
                .cornerRadius(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.8))
    }
}