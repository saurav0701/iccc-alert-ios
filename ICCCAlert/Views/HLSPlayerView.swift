import SwiftUI
import WebKit
import AVFoundation

// ✅ CRITICAL FIX: Unified WebView caching with proper lifecycle
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
    private let cacheExpiration: TimeInterval = 600
    private let maxCacheSize = 12
    private let lock = NSLock()
    
    // ✅ Use cameraId as the ONLY key (no fullscreen/thumbnail distinction)
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

// MARK: - WebView HLS Player (FIXED)
struct WebViewHLSPlayer: UIViewRepresentable {
    let streamURL: String
    let cameraId: String
    let cameraName: String
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    let isFullscreen: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        // ✅ Use cameraId as the ONLY cache key
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
        // ✅ Only reload if URL changed AND sufficient time passed
        guard context.coordinator.lastLoadedURL != streamURL else {
            return
        }
        
        let now = Date().timeIntervalSince1970
        if now - context.coordinator.lastLoadTime < 5.0 {
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
                            
                            // ✅ FIXED: More conservative buffering for thumbnails
                            maxBufferLength: isFullscreen ? 30 : 15,
                            maxMaxBufferLength: isFullscreen ? 60 : 30,
                            maxBufferSize: 60 * 1000 * 1000,
                            maxBufferHole: 1.0,
                            backBufferLength: isFullscreen ? 20 : 0,
                            
                            // ✅ FIXED: Longer timeouts
                            manifestLoadingTimeOut: 20000,
                            manifestLoadingMaxRetry: 4,
                            manifestLoadingRetryDelay: 1000,
                            
                            levelLoadingTimeOut: 20000,
                            levelLoadingMaxRetry: 4,
                            levelLoadingRetryDelay: 1000,
                            
                            fragLoadingTimeOut: 20000,
                            fragLoadingMaxRetry: 4,
                            fragLoadingRetryDelay: 1000,
                            
                            startLevel: -1,
                            autoStartLoad: true,
                            capLevelToPlayerSize: !isFullscreen,
                            
                            liveSyncDurationCount: 3,
                            liveMaxLatencyDurationCount: 10,
                            
                            startFragPrefetch: true,
                            testBandwidth: true,
                        });
                        
                        hls.on(Hls.Events.ERROR, function(event, data) {
                            if (data.fatal) {
                                log('❌ Fatal error: ' + data.type + ' - ' + data.details);
                                
                                switch(data.type) {
                                    case Hls.ErrorTypes.NETWORK_ERROR:
                                        if (retryCount < maxRetries) {
                                            retryCount++;
                                            log('🔄 Network retry ' + retryCount + '/' + maxRetries);
                                            setTimeout(() => {
                                                if (hls && !isDestroyed) {
                                                    hls.startLoad();
                                                }
                                            }, 2000 * retryCount);
                                        } else {
                                            window.webkit.messageHandlers.streamError.postMessage('Network connection failed');
                                        }
                                        break;
                                        
                                    case Hls.ErrorTypes.MEDIA_ERROR:
                                        if (retryCount < maxRetries) {
                                            retryCount++;
                                            log('🔄 Media retry ' + retryCount + '/' + maxRetries);
                                            hls.recoverMediaError();
                                        } else {
                                            window.webkit.messageHandlers.streamError.postMessage('Media playback failed');
                                        }
                                        break;
                                        
                                    default:
                                        window.webkit.messageHandlers.streamError.postMessage('Stream failed: ' + data.details);
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
                        
                        // ✅ FIXED: Monitor stalls and buffer underruns
                        hls.on(Hls.Events.BUFFER_APPENDING, function() {
                            log('📦 Buffer appending');
                        });
                        
                        hls.on(Hls.Events.BUFFER_EOS, function() {
                            log('✅ Buffer end of stream');
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

// MARK: - Camera Thumbnail (FIXED)
struct CameraThumbnail: View {
    let camera: Camera
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    
    // ✅ CRITICAL: Stable identifier based on camera ID only
    private var viewId: String {
        "thumbnail_\(camera.id)"
    }
    
    var body: some View {
        ZStack {
            if let streamURL = camera.streamURL, camera.isOnline {
                WebViewHLSPlayer(
                    streamURL: streamURL,
                    cameraId: camera.id,
                    cameraName: camera.displayName,
                    isLoading: $isLoading,
                    errorMessage: $errorMessage,
                    isFullscreen: false
                )
                .id(viewId)
                
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

// MARK: - Fullscreen HLS Player View (FIXED)
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
                    cameraId: camera.id,
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
            // ✅ FIXED: Increased to 5 seconds to avoid interference
            autoHideTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
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