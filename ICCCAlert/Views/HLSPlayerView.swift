import SwiftUI
import WebKit
import AVFoundation

// ✅ CRITICAL FIX: Simplified WebView caching
class WebViewStore {
    static let shared = WebViewStore()
    
    private struct CachedWebView {
        let webView: WKWebView
        let createdAt: Date
        var lastAccessTime: Date
    }
    
    private var cache: [String: CachedWebView] = [:]
    private let lock = NSLock()
    
    func getWebView(for cameraId: String) -> WKWebView? {
        lock.lock()
        defer { lock.unlock() }
        
        guard var cached = cache[cameraId] else { return nil }
        
        let age = Date().timeIntervalSince1970 - cached.createdAt.timeIntervalSince1970
        if age > 300 { // 5 minutes
            cleanupWebView(cached.webView)
            cache.removeValue(forKey: cameraId)
            return nil
        }
        
        cached.lastAccessTime = Date()
        cache[cameraId] = cached
        
        print("✅ Reusing WebView: \(cameraId)")
        return cached.webView
    }
    
    func cacheWebView(_ webView: WKWebView, for cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        if cache.count >= 10 {
            if let oldest = cache.min(by: { $0.value.lastAccessTime < $1.value.lastAccessTime }) {
                cleanupWebView(oldest.value.webView)
                cache.removeValue(forKey: oldest.key)
            }
        }
        
        cache[cameraId] = CachedWebView(
            webView: webView,
            createdAt: Date(),
            lastAccessTime: Date()
        )
        print("💾 Cached WebView: \(cameraId)")
    }
    
    private func cleanupWebView(_ webView: WKWebView) {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }
    
    func clearAll() {
        lock.lock()
        defer { lock.unlock()
        cache.values.forEach { cleanupWebView($0.webView) }
        cache.removeAll()
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
            print("❌ Audio session error: \(error)")
        }
    }
}

// MARK: - WebView HLS Player (COMPLETELY REWRITTEN)
struct WebViewHLSPlayer: UIViewRepresentable {
    let streamURL: String
    let cameraId: String
    let cameraName: String
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    let isFullscreen: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        
        // ✅ CRITICAL: Enable media playback
        if #available(iOS 14.0, *) {
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        
        // Add message handlers
        let contentController = webView.configuration.userContentController
        contentController.add(context.coordinator, name: "streamReady")
        contentController.add(context.coordinator, name: "streamError")
        contentController.add(context.coordinator, name: "streamLog")
        
        AudioSessionManager.shared.configure()
        
        print("🆕 Created WebView: \(cameraName)")
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        // ✅ CRITICAL: Only load once or when URL changes
        guard context.coordinator.currentURL != streamURL else {
            return
        }
        
        // Prevent rapid reloads
        let now = Date().timeIntervalSince1970
        if now - context.coordinator.lastLoadTime < 2.0 {
            print("⚠️ Throttling reload: \(cameraName)")
            return
        }
        
        context.coordinator.currentURL = streamURL
        context.coordinator.lastLoadTime = now
        
        let html = generateHTML()
        webView.loadHTMLString(html, baseURL: URL(string: "https://cdn.jsdelivr.net"))
        
        print("📹 Loading: \(cameraName) | Fullscreen: \(isFullscreen)")
    }
    
    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        print("📤 Dismantled: \(coordinator.parent.cameraName)")
    }
    
    private func generateHTML() -> String {
        // ✅ CRITICAL: Proper video attributes
        let autoplay = isFullscreen ? "autoplay" : ""
        let muted = "muted" // Always muted initially
        let controls = isFullscreen ? "controls" : ""
        let playsinline = "playsinline webkit-playsinline"
        
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                html, body { 
                    width: 100%; 
                    height: 100%; 
                    overflow: hidden;
                    background: #000;
                }
                body {
                    display: flex;
                    justify-content: center;
                    align-items: center;
                }
                #player {
                    width: 100%;
                    height: 100%;
                    object-fit: contain;
                }
            </style>
        </head>
        <body>
            <video id="player" \(playsinline) \(muted) \(autoplay) \(controls)></video>
            <script src="https://cdn.jsdelivr.net/npm/hls.js@1.5.13/dist/hls.min.js"></script>
            <script>
                (function() {
                    const video = document.getElementById('player');
                    const streamURL = '\(streamURL)';
                    const isFullscreen = \(isFullscreen ? "true" : "false");
                    
                    let hls = null;
                    let retryCount = 0;
                    const MAX_RETRIES = 5;
                    
                    function log(msg) {
                        console.log('[HLS] ' + msg);
                        try {
                            window.webkit?.messageHandlers?.streamLog?.postMessage(msg);
                        } catch(e) {}
                    }
                    
                    function notifyError(msg) {
                        log('ERROR: ' + msg);
                        try {
                            window.webkit?.messageHandlers?.streamError?.postMessage(msg);
                        } catch(e) {}
                    }
                    
                    function notifyReady() {
                        log('Stream ready');
                        try {
                            window.webkit?.messageHandlers?.streamReady?.postMessage('ready');
                        } catch(e) {}
                    }
                    
                    function cleanup() {
                        if (hls) {
                            try {
                                hls.destroy();
                                hls = null;
                                log('HLS cleaned up');
                            } catch(e) {
                                log('Cleanup error: ' + e.message);
                            }
                        }
                    }
                    
                    function initHLS() {
                        cleanup();
                        
                        log('Initializing HLS for: ' + streamURL);
                        
                        if (Hls.isSupported()) {
                            try {
                                hls = new Hls({
                                    debug: false,
                                    enableWorker: true,
                                    lowLatencyMode: false,
                                    
                                    // ✅ CRITICAL: Very conservative buffering
                                    maxBufferLength: isFullscreen ? 60 : 30,
                                    maxMaxBufferLength: isFullscreen ? 120 : 60,
                                    maxBufferSize: 100 * 1000 * 1000,
                                    maxBufferHole: 2.0,
                                    
                                    // ✅ CRITICAL: Generous timeouts for slow streams
                                    manifestLoadingTimeOut: 30000,
                                    manifestLoadingMaxRetry: 6,
                                    manifestLoadingRetryDelay: 2000,
                                    
                                    levelLoadingTimeOut: 30000,
                                    levelLoadingMaxRetry: 6,
                                    levelLoadingRetryDelay: 2000,
                                    
                                    fragLoadingTimeOut: 30000,
                                    fragLoadingMaxRetry: 6,
                                    fragLoadingRetryDelay: 2000,
                                    
                                    // ✅ Let HLS.js choose best quality
                                    startLevel: -1,
                                    autoStartLoad: true,
                                    
                                    // ✅ CRITICAL: Don't cap quality for thumbnails
                                    capLevelToPlayerSize: false,
                                    
                                    // ✅ Live stream settings
                                    liveSyncDurationCount: 3,
                                    liveMaxLatencyDurationCount: 10,
                                    maxLiveSyncPlaybackRate: 1,
                                    
                                    // ✅ Enable prefetch
                                    startFragPrefetch: true,
                                    testBandwidth: true,
                                    
                                    // ✅ CRITICAL: XHR setup for CORS
                                    xhrSetup: function(xhr, url) {
                                        xhr.withCredentials = false;
                                    }
                                });
                                
                                // Error handling
                                hls.on(Hls.Events.ERROR, function(event, data) {
                                    log('HLS Error: ' + data.type + ' - ' + data.details);
                                    
                                    if (data.fatal) {
                                        switch(data.type) {
                                            case Hls.ErrorTypes.NETWORK_ERROR:
                                                log('Network error, attempting recovery...');
                                                if (retryCount < MAX_RETRIES) {
                                                    retryCount++;
                                                    setTimeout(function() {
                                                        log('Retry ' + retryCount + '/' + MAX_RETRIES);
                                                        hls.startLoad();
                                                    }, 3000 * retryCount);
                                                } else {
                                                    notifyError('Network error after ' + MAX_RETRIES + ' retries');
                                                    cleanup();
                                                }
                                                break;
                                                
                                            case Hls.ErrorTypes.MEDIA_ERROR:
                                                log('Media error, attempting recovery...');
                                                if (retryCount < MAX_RETRIES) {
                                                    retryCount++;
                                                    setTimeout(function() {
                                                        log('Media recovery ' + retryCount + '/' + MAX_RETRIES);
                                                        hls.recoverMediaError();
                                                    }, 2000);
                                                } else {
                                                    notifyError('Media error after ' + MAX_RETRIES + ' retries');
                                                    cleanup();
                                                }
                                                break;
                                                
                                            default:
                                                notifyError('Fatal error: ' + data.details);
                                                cleanup();
                                                break;
                                        }
                                    }
                                });
                                
                                // Success events
                                hls.on(Hls.Events.MANIFEST_PARSED, function(event, data) {
                                    log('Manifest parsed - ' + data.levels.length + ' quality levels');
                                    retryCount = 0;
                                    notifyReady();
                                    
                                    if (isFullscreen) {
                                        video.play().then(function() {
                                            log('Playback started');
                                        }).catch(function(e) {
                                            log('Play error: ' + e.message);
                                        });
                                    }
                                });
                                
                                hls.on(Hls.Events.FRAG_LOADED, function(event, data) {
                                    log('Fragment loaded: ' + data.frag.sn);
                                });
                                
                                // Load stream
                                hls.loadSource(streamURL);
                                hls.attachMedia(video);
                                
                                log('HLS initialized successfully');
                                
                            } catch(e) {
                                log('HLS init error: ' + e.message);
                                notifyError('Initialization failed: ' + e.message);
                            }
                            
                        } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
                            log('Using native HLS');
                            
                            video.src = streamURL;
                            
                            video.addEventListener('loadedmetadata', function() {
                                log('Native HLS loaded');
                                notifyReady();
                                if (isFullscreen) {
                                    video.play().catch(function(e) {
                                        notifyError('Play error: ' + e.message);
                                    });
                                }
                            });
                            
                            video.addEventListener('error', function(e) {
                                let errorMsg = 'Playback error';
                                if (video.error) {
                                    errorMsg += ' (code: ' + video.error.code + ')';
                                }
                                log(errorMsg);
                                notifyError(errorMsg);
                            });
                            
                            video.load();
                            
                        } else {
                            notifyError('HLS not supported');
                        }
                    }
                    
                    // ✅ Prevent video pause/stop on visibility change
                    document.addEventListener('visibilitychange', function() {
                        if (!document.hidden && video.paused && hls) {
                            log('Tab visible - resuming playback');
                            video.play().catch(function(e) {
                                log('Resume error: ' + e.message);
                            });
                        }
                    });
                    
                    // Start initialization
                    initHLS();
                    
                    // Cleanup on unload
                    window.addEventListener('beforeunload', cleanup);
                })();
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
        var currentURL: String = ""
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
                    print("✅ Stream ready: \(self.parent.cameraName)")
                    
                case "streamError":
                    let error = message.body as? String ?? "Stream error"
                    self.parent.isLoading = false
                    self.parent.errorMessage = error
                    print("❌ Stream error [\(self.parent.cameraName)]: \(error)")
                    
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
            print("📄 Page loaded: \(parent.cameraName)")
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.errorMessage = "Page load failed"
                self.parent.isLoading = false
                print("❌ Navigation failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Camera Thumbnail
struct CameraThumbnail: View {
    let camera: Camera
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var retryCount = 0
    
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
                .id("thumb_\(camera.id)")
                
                if isLoading && errorMessage == nil {
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
                        VStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.orange)
                            
                            Text("Stream Error")
                                .font(.caption2)
                                .foregroundColor(.white)
                            
                            Button(action: retryStream) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.clockwise")
                                    Text("Retry")
                                }
                                .font(.caption2)
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue)
                                .cornerRadius(6)
                            }
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
    
    private func retryStream() {
        retryCount += 1
        isLoading = true
        errorMessage = nil
        print("🔄 Retrying stream: \(camera.displayName) (attempt \(retryCount))")
    }
}

// MARK: - Fullscreen Player
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