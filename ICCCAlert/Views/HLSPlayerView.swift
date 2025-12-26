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
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = false
        
        // Enable optimizations
        configuration.preferences.javaScriptEnabled = true
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        
        // Add message handlers
        webView.configuration.userContentController.add(context.coordinator, name: "streamReady")
        webView.configuration.userContentController.add(context.coordinator, name: "streamError")
        webView.configuration.userContentController.add(context.coordinator, name: "streamLog")
        
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        // Only load if URL changed or not loaded yet
        if context.coordinator.lastLoadedURL != streamURL {
            context.coordinator.lastLoadedURL = streamURL
            let html = generateHTML()
            webView.loadHTMLString(html, baseURL: nil)
        }
    }
    
    private func generateHTML() -> String {
        // For thumbnail view, we want autoplay but muted
        // For fullscreen, we want controls and sound
        let autoplayAttr = "autoplay"
        let mutedAttr = isFullscreen ? "" : "muted"
        let controlsAttr = isFullscreen ? "controls" : ""
        let playsinlineAttr = "playsinline"
        
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
            <video id="player" \(autoplayAttr) \(playsinlineAttr) \(mutedAttr) \(controlsAttr)></video>
            <script src="https://cdn.jsdelivr.net/npm/hls.js@1.5.13/dist/hls.min.js"></script>
            <script>
                const video = document.getElementById('player');
                const videoSrc = '\(streamURL)';
                
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
                        log('Cleaning up HLS instance');
                        hls.destroy();
                        hls = null;
                    }
                }
                
                function initPlayer() {
                    if (isDestroyed) return;
                    
                    cleanup();
                    
                    log('Initializing player for: ' + videoSrc);
                    
                    if (Hls.isSupported()) {
                        log('HLS.js is supported');
                        
                        hls = new Hls({
                            debug: false,
                            enableWorker: true,
                            lowLatencyMode: true,
                            backBufferLength: 90,
                            maxBufferLength: 30,
                            maxMaxBufferLength: 60,
                            maxBufferSize: 60 * 1000 * 1000,
                            maxBufferHole: 0.5,
                            highBufferWatchdogPeriod: 2,
                            nudgeOffset: 0.1,
                            nudgeMaxRetry: 3,
                            maxFragLookUpTolerance: 0.25,
                            liveSyncDurationCount: 3,
                            liveMaxLatencyDurationCount: 10,
                            liveDurationInfinity: false,
                            startLevel: -1,
                            autoStartLoad: true,
                            capLevelToPlayerSize: false,
                            manifestLoadingTimeOut: 10000,
                            manifestLoadingMaxRetry: 3,
                            manifestLoadingRetryDelay: 1000,
                            levelLoadingTimeOut: 10000,
                            levelLoadingMaxRetry: 3,
                            fragLoadingTimeOut: 20000,
                            fragLoadingMaxRetry: 3,
                        });
                        
                        hls.on(Hls.Events.MEDIA_ATTACHED, function() {
                            log('Media attached');
                        });
                        
                        hls.on(Hls.Events.MANIFEST_PARSED, function(event, data) {
                            log('Manifest parsed, levels: ' + data.levels.length);
                            
                            // Try to play
                            video.play()
                                .then(() => {
                                    log('Video playing successfully');
                                    window.webkit.messageHandlers.streamReady.postMessage('ready');
                                    retryCount = 0;
                                })
                                .catch(e => {
                                    log('Play error: ' + e.message);
                                    if (retryCount < maxRetries) {
                                        retryCount++;
                                        setTimeout(() => {
                                            video.play().catch(err => log('Retry play failed: ' + err.message));
                                        }, 1000);
                                    } else {
                                        window.webkit.messageHandlers.streamError.postMessage('Failed to start playback: ' + e.message);
                                    }
                                });
                        });
                        
                        hls.on(Hls.Events.ERROR, function(event, data) {
                            log('HLS Error: ' + data.type + ' - ' + data.details);
                            
                            if (data.fatal) {
                                switch(data.type) {
                                    case Hls.ErrorTypes.NETWORK_ERROR:
                                        log('Fatal network error, attempting recovery...');
                                        if (retryCount < maxRetries) {
                                            retryCount++;
                                            setTimeout(() => {
                                                if (hls && !isDestroyed) {
                                                    hls.startLoad();
                                                }
                                            }, 1000 * retryCount);
                                        } else {
                                            window.webkit.messageHandlers.streamError.postMessage('Network error: ' + data.details);
                                        }
                                        break;
                                        
                                    case Hls.ErrorTypes.MEDIA_ERROR:
                                        log('Fatal media error, attempting recovery...');
                                        if (hls && !isDestroyed) {
                                            hls.recoverMediaError();
                                        }
                                        break;
                                        
                                    default:
                                        log('Fatal error, cannot recover: ' + data.details);
                                        window.webkit.messageHandlers.streamError.postMessage('Fatal error: ' + data.details);
                                        break;
                                }
                            }
                        });
                        
                        hls.on(Hls.Events.FRAG_LOADED, function(event, data) {
                            log('Fragment loaded: ' + data.frag.sn);
                        });
                        
                        // Load and attach
                        hls.loadSource(videoSrc);
                        hls.attachMedia(video);
                        
                    } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
                        // Native HLS support (Safari)
                        log('Using native HLS support');
                        
                        video.src = videoSrc;
                        
                        video.addEventListener('loadedmetadata', function() {
                            log('Native HLS: metadata loaded');
                            video.play()
                                .then(() => {
                                    log('Native HLS: playing');
                                    window.webkit.messageHandlers.streamReady.postMessage('ready');
                                })
                                .catch(e => {
                                    log('Native HLS play error: ' + e.message);
                                    window.webkit.messageHandlers.streamError.postMessage('Playback error: ' + e.message);
                                });
                        });
                        
                        video.addEventListener('error', function(e) {
                            log('Native HLS error: ' + (video.error ? video.error.message : 'unknown'));
                            window.webkit.messageHandlers.streamError.postMessage('Native playback error');
                        });
                        
                        video.load();
                    } else {
                        log('HLS not supported on this device');
                        window.webkit.messageHandlers.streamError.postMessage('HLS not supported');
                    }
                }
                
                // Handle video events
                video.addEventListener('waiting', function() {
                    log('Video is waiting for data');
                });
                
                video.addEventListener('playing', function() {
                    log('Video is playing');
                });
                
                video.addEventListener('pause', function() {
                    log('Video paused');
                });
                
                video.addEventListener('ended', function() {
                    log('Video ended');
                });
                
                video.addEventListener('stalled', function() {
                    log('Video stalled');
                });
                
                // Start player
                initPlayer();
                
                // Keep stream alive - try to resume if paused
                setInterval(() => {
                    if (!isDestroyed && video.paused && !video.ended) {
                        log('Video paused unexpectedly, attempting to resume');
                        video.play().catch(e => log('Resume play failed: ' + e.message));
                    }
                }, 5000);
                
                // Handle visibility changes
                document.addEventListener('visibilitychange', function() {
                    if (document.hidden) {
                        log('Page hidden');
                        if (hls) {
                            hls.stopLoad();
                        }
                    } else {
                        log('Page visible');
                        if (hls && !isDestroyed) {
                            hls.startLoad();
                            video.play().catch(e => log('Resume after visibility change failed: ' + e.message));
                        }
                    }
                });
                
                // Cleanup on unload
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
        
        init(_ parent: WebViewHLSPlayer) {
            self.parent = parent
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            DispatchQueue.main.async {
                switch message.name {
                case "streamReady":
                    print("✅ Stream ready: \(self.parent.cameraName)")
                    self.parent.isLoading = false
                    self.parent.errorMessage = nil
                    
                case "streamError":
                    let error = message.body as? String ?? "Stream error"
                    print("❌ Stream error for \(self.parent.cameraName): \(error)")
                    self.parent.isLoading = false
                    self.parent.errorMessage = error
                    
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
            print("❌ WebView navigation failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.parent.errorMessage = "Navigation failed: \(error.localizedDescription)"
                self.parent.isLoading = false
            }
        }
    }
}

// MARK: - Camera Thumbnail (Grid Preview) - WITH FIXES
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
                    cameraName: camera.displayName,
                    isLoading: $isLoading,
                    errorMessage: $errorMessage,
                    isFullscreen: false
                )
                .id("\(camera.id)-\(retryCount)") // Force reload on retry
                
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
                        Color.black.opacity(0.8)
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.orange)
                            
                            Text("Stream Error")
                                .font(.caption)
                                .foregroundColor(.white)
                            
                            Button(action: {
                                errorMessage = nil
                                isLoading = true
                                retryCount += 1
                            }) {
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
                // Offline state
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
            
            // Live badge
            if camera.isOnline {
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

// MARK: - Fullscreen HLS Player View - WITH FIXES
struct HLSPlayerView: View {
    let camera: Camera
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var retryCount = 0
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
                .id("fullscreen-\(camera.id)-\(retryCount)") // Force reload on retry
                .ignoresSafeArea()
            } else {
                errorView("Stream URL not available")
            }
            
            // Loading overlay
            if isLoading {
                loadingView
            }
            
            // Header overlay
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
                    .background(Color.black.opacity(0.6))
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
            
            // Error view
            if let error = errorMessage {
                errorView(error)
            }
        }
        .navigationBarHidden(true)
    }
    
    private var loadingView: some View {
        VStack(spacing: 20) {
            if #available(iOS 15.0, *) {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
            } else {
                ProgressView()
                    .scaleEffect(1.5)
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            }
            
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.8))
    }
}