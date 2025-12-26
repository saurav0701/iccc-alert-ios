import SwiftUI
import WebKit
import AVFoundation

// ✅ FIXED: WebView caching to prevent destruction
class WebViewStore {
    static let shared = WebViewStore()
    var webViews: [String: WKWebView] = [:]
    
    func clearCache() {
        webViews.removeAll()
    }
}

// ✅ FIXED: Audio session configuration (iOS needs this even for silent videos)
class AudioSessionManager {
    static let shared = AudioSessionManager()
    
    func configure() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // ✅ Allows video playback without audio
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try audioSession.setActive(true)
            print("✅ Audio session configured for video playback")
        } catch {
            print("❌ Failed to configure audio session: \(error)")
        }
    }
}

// MARK: - WebView HLS Player (Fixed + Optimized)
struct WebViewHLSPlayer: UIViewRepresentable {
    let streamURL: String
    let cameraName: String
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    let isFullscreen: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        // ✅ FIXED: Check cache first
        if let cached = WebViewStore.shared.webViews[streamURL] {
            print("♻️ Reusing cached WebView for: \(cameraName)")
            cached.navigationDelegate = context.coordinator
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
        
        // Add message handlers
        webView.configuration.userContentController.add(context.coordinator, name: "streamReady")
        webView.configuration.userContentController.add(context.coordinator, name: "streamError")
        webView.configuration.userContentController.add(context.coordinator, name: "streamLog")
        
        // ✅ FIXED: Cache the WebView
        WebViewStore.shared.webViews[streamURL] = webView
        
        // ✅ Configure audio session
        AudioSessionManager.shared.configure()
        
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        // ✅ FIXED: Only load if URL changed
        if context.coordinator.lastLoadedURL != streamURL {
            context.coordinator.lastLoadedURL = streamURL
            let html = generateHTML()
            webView.loadHTMLString(html, baseURL: nil)
            print("📹 Loading stream for: \(cameraName)")
        }
    }
    
    private func generateHTML() -> String {
        // ✅ Simplified: No autoplay in thumbnails, only in fullscreen
        let autoplayAttr = isFullscreen ? "autoplay" : ""
        let mutedAttr = "muted" // ✅ Always muted (no audio in streams)
        let controlsAttr = isFullscreen ? "controls" : ""
        let playsinlineAttr = "playsinline"
        let preloadAttr = isFullscreen ? "preload=\"auto\"" : "preload=\"none\""
        
        let manifestTimeout = isFullscreen ? "8000" : "20000"
        let fragTimeout = isFullscreen ? "15000" : "40000"
        
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
                const maxRetries = 5;
                let isDestroyed = false;
                let playbackStallTimer = null;
                let lastPlaybackTime = 0;
                let stallCheckCount = 0;
                
                function log(msg) {
                    console.log(msg);
                    try {
                        window.webkit.messageHandlers.streamLog.postMessage(msg);
                    } catch(e) {}
                }
                
                function cleanup() {
                    if (playbackStallTimer) clearInterval(playbackStallTimer);
                    if (hls) {
                        log('🧹 Cleaning up HLS instance');
                        try {
                            hls.destroy();
                        } catch(e) {
                            log('⚠️ Error destroying HLS: ' + e.message);
                        }
                        hls = null;
                    }
                }
                
                function startStallDetection() {
                    if (!isFullscreen) return; // Only monitor fullscreen playback
                    if (playbackStallTimer) clearInterval(playbackStallTimer);
                    
                    playbackStallTimer = setInterval(() => {
                        if (isDestroyed || !video || video.paused) return;
                        
                        const currentTime = video.currentTime;
                        if (currentTime > 0 && currentTime === lastPlaybackTime) {
                            stallCheckCount++;
                            if (stallCheckCount >= 2) {
                                log('⚠️ PLAYBACK STALLED! Attempting recovery...');
                                if (hls) {
                                    hls.stopLoad();
                                    setTimeout(() => {
                                        if (hls && !isDestroyed) {
                                            hls.startLoad(-1);
                                            video.play().catch(e => log('Stall recovery failed: ' + e.message));
                                        }
                                    }, 500);
                                }
                                stallCheckCount = 0;
                            }
                        } else {
                            stallCheckCount = 0;
                        }
                        lastPlaybackTime = currentTime;
                    }, 5000);
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
                            backBufferLength: 90,
                            maxBufferLength: isFullscreen ? 40 : 10,
                            maxMaxBufferLength: isFullscreen ? 80 : 20,
                            maxBufferSize: 80 * 1000 * 1000,
                            maxBufferHole: 0.5,
                            highBufferWatchdogPeriod: 3,
                            nudgeOffset: 0.1,
                            nudgeMaxRetry: 10,
                            maxFragLookUpTolerance: 0.25,
                            liveSyncDurationCount: 3,
                            liveMaxLatencyDurationCount: isFullscreen ? 15 : 10,
                            liveDurationInfinity: false,
                            startLevel: -1,
                            autoStartLoad: true,
                            capLevelToPlayerSize: !isFullscreen,
                            manifestLoadingTimeOut: parseInt('\(manifestTimeout)'),
                            manifestLoadingMaxRetry: 6,
                            manifestLoadingRetryDelay: 1000,
                            levelLoadingTimeOut: parseInt('\(manifestTimeout)'),
                            levelLoadingMaxRetry: 6,
                            levelLoadingRetryDelay: 1000,
                            fragLoadingTimeOut: parseInt('\(fragTimeout)'),
                            fragLoadingMaxRetry: 10,
                            fragLoadingRetryDelay: 1000,
                            startFragPrefetch: true,
                            testBandwidth: true,
                        });
                        
                        hls.on(Hls.Events.MANIFEST_PARSED, function(event, data) {
                            log('✅ Manifest parsed');
                            startStallDetection();
                            
                            if (isFullscreen) {
                                video.play()
                                    .then(() => {
                                        log('▶️ Playing');
                                        window.webkit.messageHandlers.streamReady.postMessage('ready');
                                        retryCount = 0;
                                    })
                                    .catch(e => {
                                        log('⚠️ Play error: ' + e.message);
                                        if (retryCount < maxRetries) {
                                            retryCount++;
                                            setTimeout(() => {
                                                video.play().catch(err => log('Retry failed: ' + err.message));
                                            }, 1500);
                                        } else {
                                            window.webkit.messageHandlers.streamError.postMessage('Failed to start: ' + e.message);
                                        }
                                    });
                            } else {
                                // Thumbnail loaded, notify ready
                                window.webkit.messageHandlers.streamReady.postMessage('ready');
                            }
                        });
                        
                        hls.on(Hls.Events.ERROR, function(event, data) {
                            if (data.fatal) {
                                log('❌ Fatal error: ' + data.type + ' - ' + data.details);
                                
                                if (data.type === Hls.ErrorTypes.NETWORK_ERROR) {
                                    if (retryCount < maxRetries) {
                                        retryCount++;
                                        const delay = Math.min(1000 * retryCount, 5000);
                                        setTimeout(() => {
                                            if (hls && !isDestroyed) {
                                                hls.startLoad(-1);
                                                if (isFullscreen) {
                                                    video.play().catch(e => log('Recovery failed: ' + e.message));
                                                }
                                            }
                                        }, delay);
                                    } else {
                                        window.webkit.messageHandlers.streamError.postMessage('Network error');
                                    }
                                } else if (data.type === Hls.ErrorTypes.MEDIA_ERROR) {
                                    if (retryCount < maxRetries) {
                                        retryCount++;
                                        hls.recoverMediaError();
                                    } else {
                                        window.webkit.messageHandlers.streamError.postMessage('Media error');
                                    }
                                }
                            }
                        });
                        
                        hls.loadSource(videoSrc);
                        hls.attachMedia(video);
                        
                    } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
                        video.src = videoSrc;
                        video.addEventListener('loadedmetadata', function() {
                            window.webkit.messageHandlers.streamReady.postMessage('ready');
                            if (isFullscreen) {
                                video.play().catch(e => 
                                    window.webkit.messageHandlers.streamError.postMessage('Play error')
                                );
                            }
                        });
                        video.load();
                    }
                }
                
                video.addEventListener('stalled', function() {
                    if (hls && !isDestroyed && isFullscreen) {
                        setTimeout(() => {
                            hls.stopLoad();
                            setTimeout(() => { if (hls) hls.startLoad(-1); }, 500);
                        }, 2000);
                    }
                });
                
                initPlayer();
                
                // Only keep-alive in fullscreen
                let keepAlive = null;
                if (isFullscreen) {
                    keepAlive = setInterval(() => {
                        if (isDestroyed) {
                            clearInterval(keepAlive);
                            return;
                        }
                        if (video.paused && !video.ended && video.readyState >= 2) {
                            video.play().catch(e => log('Resume failed'));
                        }
                    }, 3000);
                }
                
                window.addEventListener('beforeunload', function() {
                    isDestroyed = true;
                    if (playbackStallTimer) clearInterval(playbackStallTimer);
                    if (keepAlive) clearInterval(keepAlive);
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
        
        init(_ parent: WebViewHLSPlayer) {
            self.parent = parent
        }
        
        // ✅ NEW: Reload function without destroying view
        func reload(_ webView: WKWebView) {
            let html = parent.generateHTML()
            webView.loadHTMLString(html, baseURL: nil)
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
                self.parent.errorMessage = "Navigation failed"
                self.parent.isLoading = false
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
                // ✅ REMOVED: .id() - Let WebView cache handle it
                WebViewHLSPlayer(
                    streamURL: streamURL,
                    cameraName: camera.displayName,
                    isLoading: $isLoading,
                    errorMessage: $errorMessage,
                    isFullscreen: false
                )
                .onAppear {
                    loadTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { _ in
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
                // ✅ REMOVED: .id() - Stable WebView, no recreation
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
                    autoHideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
                        withAnimation {
                            showControls = false
                        }
                    }
                }
                .onDisappear {
                    autoHideTimer?.invalidate()
                }
                .onTapGesture {
                    withAnimation {
                        showControls.toggle()
                    }
                    autoHideTimer?.invalidate()
                    if showControls {
                        autoHideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
                            withAnimation {
                                showControls = false
                            }
                        }
                    }
                }
            } else {
                errorView("Stream URL not available")
            }
            
            if isLoading {
                loadingView
            }
            
            if showControls {
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
            
            if let error = errorMessage {
                errorView(error)
            }
        }
        .navigationBarHidden(true)
        .statusBar(hidden: !showControls)
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