import SwiftUI
import WebKit
import AVFoundation

// ✅ CRITICAL FIX: Stable WebView caching with proper lifecycle management
class WebViewStore {
    static let shared = WebViewStore()
    
    private struct CachedWebView {
        let webView: WKWebView
        let createdAt: Date
        let streamURL: String
        var lastAccessTime: Date
    }
    
    private var cache: [String: CachedWebView] = [:]
    private let cacheExpiration: TimeInterval = 600 // 10 minutes (increased from 5)
    private let maxCacheSize = 15 // Increased from 10
    private let lock = NSLock()
    
    // ✅ CRITICAL: Track which WebViews are currently in use
    private var activeWebViews: Set<String> = []
    
    func markActive(_ key: String) {
        lock.lock()
        activeWebViews.insert(key)
        lock.unlock()
    }
    
    func markInactive(_ key: String) {
        lock.lock()
        activeWebViews.remove(key)
        lock.unlock()
    }
    
    func getWebView(for key: String, streamURL: String) -> WKWebView? {
        lock.lock()
        defer { lock.unlock() }
        
        guard var cached = cache[key] else { return nil }
        
        // Check if expired or URL changed
        let age = Date().timeIntervalSince1970 - cached.createdAt.timeIntervalSince1970
        if age > cacheExpiration || cached.streamURL != streamURL {
            print("♻️ Cache expired or URL changed for: \(key)")
            cleanupWebView(cached.webView)
            cache.removeValue(forKey: key)
            return nil
        }
        
        // Update last access time
        cached.lastAccessTime = Date()
        cache[key] = cached
        
        print("✅ Reusing cached WebView for: \(key) (age: \(Int(age))s)")
        return cached.webView
    }
    
    func cacheWebView(_ webView: WKWebView, for key: String, streamURL: String) {
        lock.lock()
        defer { lock.unlock() }
        
        // Don't cache if already exists
        if cache[key] != nil {
            print("⚠️ WebView already cached for: \(key)")
            return
        }
        
        // Remove oldest INACTIVE entries if at capacity
        if cache.count >= maxCacheSize {
            // Find inactive entries sorted by last access time
            let inactiveEntries = cache.filter { !activeWebViews.contains($0.key) }
                .sorted { $0.value.lastAccessTime < $1.value.lastAccessTime }
            
            if let oldestKey = inactiveEntries.first?.key {
                if let old = cache.removeValue(forKey: oldestKey) {
                    print("🗑️ Removing old inactive cache: \(oldestKey)")
                    cleanupWebView(old.webView)
                }
            } else if let oldestKey = cache.min(by: { $0.value.lastAccessTime < $1.value.lastAccessTime })?.key {
                // If all are active, remove oldest by access time
                if let old = cache.removeValue(forKey: oldestKey) {
                    print("🗑️ Removing oldest cache (all active): \(oldestKey)")
                    cleanupWebView(old.webView)
                }
            }
        }
        
        cache[key] = CachedWebView(
            webView: webView,
            createdAt: Date(),
            streamURL: streamURL,
            lastAccessTime: Date()
        )
        print("💾 Cached new WebView for: \(key) (total: \(cache.count))")
    }
    
    func removeWebView(for key: String) {
        lock.lock()
        defer { lock.unlock() }
        
        activeWebViews.remove(key)
        
        // Don't immediately remove - let it stay in cache for reuse
        // Only mark as inactive
        print("📤 Marked WebView as inactive: \(key)")
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
        activeWebViews.removeAll()
        print("🧹 Cleared all cached WebViews")
    }
    
    func clearInactive() {
        lock.lock()
        defer { lock.unlock() }
        
        let inactive = cache.filter { !activeWebViews.contains($0.key) }
        inactive.forEach { key, cached in
            cleanupWebView(cached.webView)
            cache.removeValue(forKey: key)
        }
        print("🧹 Cleared \(inactive.count) inactive WebViews")
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
        } catch {
            print("❌ Failed to configure audio session: \(error)")
        }
    }
}

// MARK: - WebView HLS Player (STABILITY FIXED)
struct WebViewHLSPlayer: UIViewRepresentable {
    let streamURL: String
    let cameraName: String
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    let isFullscreen: Bool
    
    // ✅ CRITICAL: Use @State to maintain stable identity across updates
    @State private var webViewIdentifier = UUID()
    
    func makeUIView(context: Context) -> WKWebView {
        let cacheKey = "\(cameraName)_\(isFullscreen ? "full" : "thumb")"
        
        // Mark as active
        WebViewStore.shared.markActive(cacheKey)
        
        // Try to reuse cached WebView
        if let cached = WebViewStore.shared.getWebView(for: cacheKey, streamURL: streamURL) {
            print("♻️ Reusing cached WebView for: \(cameraName)")
            cached.navigationDelegate = context.coordinator
            
            // Re-add message handlers if needed
            setupMessageHandlers(for: cached, coordinator: context.coordinator)
            
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
        setupMessageHandlers(for: webView, coordinator: context.coordinator)
        
        // Cache it
        WebViewStore.shared.cacheWebView(webView, for: cacheKey, streamURL: streamURL)
        
        AudioSessionManager.shared.configure()
        
        print("🆕 Created new WebView for: \(cameraName)")
        
        return webView
    }
    
    private func setupMessageHandlers(for webView: WKWebView, coordinator: Coordinator) {
        let controller = webView.configuration.userContentController
        
        // Remove existing handlers first to prevent duplicates
        controller.removeScriptMessageHandler(forName: "streamReady")
        controller.removeScriptMessageHandler(forName: "streamError")
        controller.removeScriptMessageHandler(forName: "streamLog")
        
        // Add handlers
        controller.add(coordinator, name: "streamReady")
        controller.add(coordinator, name: "streamError")
        controller.add(coordinator, name: "streamLog")
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        // ✅ CRITICAL: Only reload if URL actually changed AND sufficient time has passed
        guard context.coordinator.lastLoadedURL != streamURL else {
            return
        }
        
        // ✅ CRITICAL: Prevent rapid reloads (increased to 3 seconds)
        let now = Date().timeIntervalSince1970
        if now - context.coordinator.lastLoadTime < 3.0 {
            print("⚠️ Preventing rapid reload for: \(cameraName) (last load: \(Int(now - context.coordinator.lastLoadTime))s ago)")
            return
        }
        
        // ✅ Only reload if not currently loading
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
        // ✅ Don't destroy WebView immediately - let cache manage it
        let cacheKey = "\(coordinator.parent.cameraName)_\(coordinator.parent.isFullscreen ? "full" : "thumb")"
        
        // Just mark as inactive
        WebViewStore.shared.markInactive(cacheKey)
        
        print("📤 WebView dismantled (kept in cache): \(coordinator.parent.cameraName)")
    }
    
    private func generateHTML() -> String {
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
                            
                            maxBufferLength: isFullscreen ? 20 : 5,
                            maxMaxBufferLength: isFullscreen ? 30 : 10,
                            maxBufferSize: 40 * 1000 * 1000,
                            maxBufferHole: 0.5,
                            backBufferLength: 10,
                            
                            manifestLoadingTimeOut: 10000,
                            manifestLoadingMaxRetry: 3,
                            manifestLoadingRetryDelay: 500,
                            
                            levelLoadingTimeOut: 10000,
                            levelLoadingMaxRetry: 3,
                            levelLoadingRetryDelay: 500,
                            
                            fragLoadingTimeOut: 15000,
                            fragLoadingMaxRetry: 3,
                            fragLoadingRetryDelay: 500,
                            
                            startLevel: 0,
                            autoStartLoad: true,
                            capLevelToPlayerSize: true,
                            
                            liveSyncDurationCount: 3,
                            liveMaxLatencyDurationCount: 10,
                            
                            startFragPrefetch: isFullscreen,
                            testBandwidth: isFullscreen,
                        });
                        
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
                        
                        hls.loadSource(videoSrc);
                        hls.attachMedia(video);
                        
                    } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
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
                    }
                }
                
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

// MARK: - Camera Thumbnail (Grid Preview) - STABILITY IMPROVED
struct CameraThumbnail: View {
    let camera: Camera
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var loadTimer: Timer? = nil
    
    // ✅ CRITICAL: Stable identifier prevents recreation
    private let viewId = UUID()
    
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
                .id(viewId) // ✅ CRITICAL: Stable ID prevents recreation
                .onAppear {
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