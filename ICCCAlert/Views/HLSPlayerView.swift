import SwiftUI
import WebKit

// MARK: - CRITICAL FIX: Stable WebView Player with Proper Lifecycle
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
        
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        // CRITICAL: Only load if URL actually changed
        if context.coordinator.lastLoadedURL != streamURL {
            context.coordinator.lastLoadedURL = streamURL
            let html = generateHTML()
            webView.loadHTMLString(html, baseURL: nil)
        }
    }
    
    private func generateHTML() -> String {
        let autoplayAttr = "autoplay"
        let mutedAttr = isFullscreen ? "" : "muted"
        let controlsAttr = isFullscreen ? "controls" : ""
        let playsinlineAttr = "playsinline webkit-playsinline"
        
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                html, body { 
                    background: #000;
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
                const isFullscreen = \(isFullscreen ? "true" : "false");
                
                let hls = null;
                let retryCount = 0;
                const maxRetries = 5;
                let isDestroyed = false;
                
                function log(msg) {
                    console.log(msg);
                    try {
                        window.webkit.messageHandlers.streamLog.postMessage(msg);
                    } catch(e) {}
                }
                
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
                    if (isDestroyed) return;
                    cleanup();
                    
                    log('🎬 Init: ' + videoSrc);
                    
                    if (Hls.isSupported()) {
                        hls = new Hls({
                            debug: false,
                            enableWorker: true,
                            lowLatencyMode: false,
                            backBufferLength: 90,
                            maxBufferLength: 30,
                            maxMaxBufferLength: 60,
                            manifestLoadingTimeOut: 10000,
                            manifestLoadingMaxRetry: 4,
                            levelLoadingTimeOut: 10000,
                            fragLoadingTimeOut: 20000,
                            fragLoadingMaxRetry: 6,
                        });
                        
                        hls.on(Hls.Events.MANIFEST_PARSED, function() {
                            log('✅ Manifest parsed');
                            
                            video.play()
                                .then(() => {
                                    log('▶️ Playing');
                                    window.webkit.messageHandlers.streamReady.postMessage('ready');
                                    retryCount = 0;
                                })
                                .catch(e => {
                                    log('⚠️ Play failed: ' + e.message);
                                    if (retryCount < maxRetries) {
                                        retryCount++;
                                        setTimeout(() => video.play(), 1000);
                                    }
                                });
                        });
                        
                        hls.on(Hls.Events.ERROR, function(event, data) {
                            if (data.fatal) {
                                log('❌ Fatal: ' + data.type + ' - ' + data.details);
                                
                                if (data.type === Hls.ErrorTypes.NETWORK_ERROR) {
                                    if (retryCount < maxRetries) {
                                        retryCount++;
                                        setTimeout(() => {
                                            if (hls && !isDestroyed) {
                                                hls.startLoad(-1);
                                            }
                                        }, 2000);
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
                            video.play()
                                .then(() => window.webkit.messageHandlers.streamReady.postMessage('ready'))
                                .catch(e => window.webkit.messageHandlers.streamError.postMessage('Play error'));
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
                case "streamLog":
                    if self.parent.isFullscreen, let log = message.body as? String {
                        print("📹 [\(self.parent.cameraName)] \(log)")
                    }
                default:
                    break
                }
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
                    cameraName: camera.displayName,
                    isLoading: $isLoading,
                    errorMessage: $errorMessage,
                    isFullscreen: false
                )
                .id("\(camera.id)-\(retryCount)")
                
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

// MARK: - CRITICAL FIX: Fullscreen Player with Navigation Safety
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
                    setupAutoHide()
                }
                .onDisappear {
                    autoHideTimer?.invalidate()
                }
                .onTapGesture {
                    withAnimation {
                        showControls.toggle()
                    }
                    setupAutoHide()
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
    
    private func setupAutoHide() {
        autoHideTimer?.invalidate()
        if showControls {
            autoHideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
                withAnimation {
                    showControls = false
                }
            }
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