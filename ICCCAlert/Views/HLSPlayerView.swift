import SwiftUI
import WebKit

// MARK: - Fixed Stable WebView HLS Player
struct WebViewHLSPlayer: UIViewRepresentable {
    let streamURL: String
    let cameraName: String
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    let isFullscreen: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        DebugLogger.shared.log("🔧 makeUIView called for \(cameraName)", emoji: "🔧", color: .blue)
        
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = false
        
        // Enable JavaScript
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
        
        DebugLogger.shared.log("✅ WebView created successfully", emoji: "✅", color: .green)
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        // Only load if URL changed or not loaded yet
        if context.coordinator.lastLoadedURL != streamURL {
            DebugLogger.shared.log("🔄 Loading new URL: \(streamURL)", emoji: "🔄", color: .blue)
            context.coordinator.lastLoadedURL = streamURL
            let html = generateHTML()
            webView.loadHTMLString(html, baseURL: nil)
        }
    }
    
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        DebugLogger.shared.log("🗑️ Dismantling WebView", emoji: "🗑️", color: .orange)
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "streamReady")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "streamError")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "streamLog")
        uiView.stopLoading()
        uiView.loadHTMLString("", baseURL: nil)
    }
    
    private func generateHTML() -> String {
        let autoplayAttr = "autoplay"
        let mutedAttr = isFullscreen ? "" : "muted"
        let controlsAttr = isFullscreen ? "controls" : ""
        let playsinlineAttr = "playsinline"
        let preloadAttr = "preload=\"auto\""
        
        let manifestTimeout = isFullscreen ? "8000" : "15000"
        let fragTimeout = isFullscreen ? "15000" : "30000"
        
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                * { 
                    margin: 0; 
                    padding: 0; 
                    box-sizing: border-box;
                    -webkit-touch-callout: none;
                    -webkit-user-select: none;
                }
                body { 
                    background: #000;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    height: 100vh;
                    width: 100vw;
                    overflow: hidden;
                    position: fixed;
                    touch-action: none;
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
                console.log('📱 HTML loaded');
                window.webkit.messageHandlers.streamLog.postMessage('📱 HTML loaded');
                
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
                    } catch(e) {
                        console.error('Failed to send log:', e);
                    }
                }
                
                log('🎬 Starting player initialization');
                log('   URL: ' + videoSrc);
                log('   Fullscreen: ' + isFullscreen);
                
                // Prevent any page navigation
                document.addEventListener('touchmove', function(e) {
                    e.preventDefault();
                }, { passive: false });
                
                document.addEventListener('click', function(e) {
                    log('👆 Click detected on: ' + e.target.tagName);
                }, true);
                
                function cleanup() {
                    if (hls) {
                        log('🧹 Cleaning up HLS');
                        try {
                            hls.destroy();
                        } catch(e) {
                            log('⚠️ Cleanup error: ' + e.message);
                        }
                        hls = null;
                    }
                }
                
                function initPlayer() {
                    if (isDestroyed) {
                        log('⚠️ Cannot init - destroyed');
                        return;
                    }
                    
                    cleanup();
                    log('🔧 Initializing HLS.js player');
                    
                    if (Hls.isSupported()) {
                        log('✅ HLS.js is supported');
                        
                        hls = new Hls({
                            debug: false,
                            enableWorker: true,
                            lowLatencyMode: false,
                            maxBufferLength: 30,
                            maxMaxBufferLength: 60,
                            manifestLoadingTimeOut: parseInt('\(manifestTimeout)'),
                            manifestLoadingMaxRetry: 3,
                            levelLoadingTimeOut: parseInt('\(manifestTimeout)'),
                            fragLoadingTimeOut: parseInt('\(fragTimeout)'),
                            fragLoadingMaxRetry: 6,
                            startFragPrefetch: true,
                        });
                        
                        log('🔌 Attaching media to video element');
                        hls.attachMedia(video);
                        
                        hls.on(Hls.Events.MEDIA_ATTACHED, function() {
                            log('✅ Media attached successfully');
                            log('🔍 Loading source: ' + videoSrc);
                            hls.loadSource(videoSrc);
                        });
                        
                        hls.on(Hls.Events.MANIFEST_PARSED, function(event, data) {
                            log('✅ MANIFEST PARSED!');
                            log('   Levels: ' + data.levels.length);
                            
                            video.play()
                                .then(() => {
                                    log('▶️ PLAYBACK STARTED!');
                                    window.webkit.messageHandlers.streamReady.postMessage('ready');
                                    retryCount = 0;
                                })
                                .catch(e => {
                                    log('❌ Play failed: ' + e.message);
                                    if (retryCount < maxRetries) {
                                        retryCount++;
                                        log('🔄 Retry ' + retryCount + '/' + maxRetries);
                                        setTimeout(() => {
                                            video.play().catch(err => log('❌ Retry failed: ' + err.message));
                                        }, 1000);
                                    } else {
                                        window.webkit.messageHandlers.streamError.postMessage('Play failed: ' + e.message);
                                    }
                                });
                        });
                        
                        hls.on(Hls.Events.FRAG_LOADED, function(event, data) {
                            log('📦 Fragment loaded (sn: ' + data.frag.sn + ')');
                        });
                        
                        hls.on(Hls.Events.ERROR, function(event, data) {
                            log('❌ HLS ERROR: ' + data.type + ' - ' + data.details);
                            
                            if (data.fatal) {
                                log('💀 FATAL ERROR!');
                                
                                if (data.type === Hls.ErrorTypes.NETWORK_ERROR) {
                                    log('🌐 Network error - attempting recovery');
                                    if (retryCount < maxRetries) {
                                        retryCount++;
                                        setTimeout(() => {
                                            if (hls && !isDestroyed) {
                                                hls.startLoad();
                                            }
                                        }, 1000);
                                    } else {
                                        window.webkit.messageHandlers.streamError.postMessage('Network error');
                                    }
                                } else if (data.type === Hls.ErrorTypes.MEDIA_ERROR) {
                                    log('🎥 Media error - attempting recovery');
                                    if (retryCount < maxRetries) {
                                        retryCount++;
                                        hls.recoverMediaError();
                                    } else {
                                        window.webkit.messageHandlers.streamError.postMessage('Media error');
                                    }
                                }
                            }
                        });
                        
                    } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
                        log('📱 Using native HLS support');
                        video.src = videoSrc;
                        
                        video.addEventListener('loadedmetadata', function() {
                            log('✅ Metadata loaded (native)');
                            video.play()
                                .then(() => {
                                    log('▶️ Playing (native)');
                                    window.webkit.messageHandlers.streamReady.postMessage('ready');
                                })
                                .catch(e => {
                                    log('❌ Play error (native): ' + e.message);
                                    window.webkit.messageHandlers.streamError.postMessage('Play error');
                                });
                        });
                        
                        video.load();
                    } else {
                        log('❌ HLS NOT SUPPORTED!');
                        window.webkit.messageHandlers.streamError.postMessage('HLS not supported');
                    }
                }
                
                // Video event listeners
                video.addEventListener('loadstart', function() {
                    log('⏳ Load start');
                });
                
                video.addEventListener('loadeddata', function() {
                    log('✅ Data loaded');
                });
                
                video.addEventListener('canplay', function() {
                    log('✅ Can play');
                });
                
                video.addEventListener('playing', function() {
                    log('▶️ Playing event');
                });
                
                video.addEventListener('waiting', function() {
                    log('⏳ Waiting for data');
                });
                
                video.addEventListener('stalled', function() {
                    log('⚠️ Stalled');
                });
                
                video.addEventListener('error', function(e) {
                    log('❌ Video error: ' + (video.error ? video.error.message : 'unknown'));
                });
                
                video.addEventListener('pause', function() {
                    log('⏸️ Paused');
                });
                
                video.addEventListener('ended', function() {
                    log('🏁 Ended');
                });
                
                // Start player
                log('🚀 Calling initPlayer()');
                initPlayer();
                
                // Keep-alive
                setInterval(() => {
                    if (!isDestroyed && video.paused && !video.ended && video.readyState >= 2) {
                        log('🔄 Auto-resuming paused video');
                        video.play().catch(e => log('❌ Auto-resume failed: ' + e.message));
                    }
                }, 3000);
                
                window.addEventListener('beforeunload', function() {
                    log('🛑 Page unloading');
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
        
        init(_ parent: WebViewHLSPlayer) {
            self.parent = parent
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            DispatchQueue.main.async {
                switch message.name {
                case "streamReady":
                    DebugLogger.shared.log("✅ Stream ready signal received", emoji: "✅", color: .green)
                    self.parent.isLoading = false
                    self.parent.errorMessage = nil
                    
                case "streamError":
                    let error = message.body as? String ?? "Stream error"
                    DebugLogger.shared.log("❌ Stream error: \(error)", emoji: "❌", color: .red)
                    self.parent.isLoading = false
                    self.parent.errorMessage = error
                    
                case "streamLog":
                    if let log = message.body as? String {
                        DebugLogger.shared.log(log, emoji: "📹", color: .blue)
                    }
                    
                default:
                    break
                }
            }
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DebugLogger.shared.log("📄 WebView navigation finished", emoji: "📄", color: .blue)
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DebugLogger.shared.log("❌ WebView navigation failed: \(error.localizedDescription)", emoji: "❌", color: .red)
            DispatchQueue.main.async {
                self.parent.errorMessage = "Navigation failed"
                self.parent.isLoading = false
            }
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DebugLogger.shared.log("❌ WebView provisional navigation failed: \(error.localizedDescription)", emoji: "❌", color: .red)
        }
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Only allow the initial HTML load (type = .other)
            if navigationAction.navigationType == .other {
                DebugLogger.shared.log("✅ Allowing navigation (type: other)", emoji: "✅", color: .green)
                decisionHandler(.allow)
            } else {
                DebugLogger.shared.log("🚫 Blocking navigation (type: \(navigationAction.navigationType.rawValue))", emoji: "🚫", color: .orange)
                decisionHandler(.cancel)
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
                .id("\(camera.id)-\(retryCount)")
                .onAppear {
                    DebugLogger.shared.log("👁️ Thumbnail appeared: \(camera.displayName)", emoji: "👁️", color: .blue)
                    loadTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { _ in
                        if isLoading && errorMessage == nil {
                            DebugLogger.shared.log("⏱️ Thumbnail load timeout", emoji: "⏱️", color: .orange)
                            isLoading = false
                        }
                    }
                }
                .onDisappear {
                    DebugLogger.shared.log("👋 Thumbnail disappeared: \(camera.displayName)", emoji: "👋", color: .gray)
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
                            
                            Button(action: {
                                DebugLogger.shared.log("🔄 Retrying thumbnail: \(camera.displayName)", emoji: "🔄", color: .blue)
                                errorMessage = nil
                                isLoading = true
                                retryCount += 1
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 10))
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
}

// MARK: - Fullscreen Player
struct HLSPlayerView: View {
    let camera: Camera
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var retryCount = 0
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
                .id("fullscreen-\(camera.id)-\(retryCount)")
                .ignoresSafeArea()
                .onAppear {
                    DebugLogger.shared.log("🎬 Fullscreen appeared: \(camera.displayName)", emoji: "🎬", color: .green)
                    DebugLogger.shared.log("   Stream URL: \(streamURL)", emoji: "🔗", color: .gray)
                    
                    autoHideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
                        withAnimation {
                            showControls = false
                        }
                    }
                }
                .onDisappear {
                    DebugLogger.shared.log("👋 Fullscreen disappeared", emoji: "👋", color: .orange)
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
                            DebugLogger.shared.log("👆 Close button tapped", emoji: "👆", color: .blue)
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
            
            HStack(spacing: 16) {
                Button(action: {
                    DebugLogger.shared.log("🔄 Retry button tapped", emoji: "🔄", color: .blue)
                    errorMessage = nil
                    isLoading = true
                    retryCount += 1
                }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Retry")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .cornerRadius(10)
                }
                
                Button(action: {
                    DebugLogger.shared.log("👆 Back button tapped", emoji: "👆", color: .blue)
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.gray)
                    .cornerRadius(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.8))
    }
}