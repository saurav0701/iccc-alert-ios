import SwiftUI
import WebKit

// MARK: - Stable WebView HLS Player
struct WebViewHLSPlayer: UIViewRepresentable {
    let streamURL: String
    let cameraName: String
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    let isFullscreen: Bool // New parameter
    
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
        
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        // Only load if not already loaded
        if webView.url == nil {
            let html = generateHTML()
            webView.loadHTMLString(html, baseURL: nil)
        }
    }
    
    private func generateHTML() -> String {
        let autoplay = isFullscreen ? "true" : "false"
        let controls = isFullscreen ? "controls" : ""
        let muted = isFullscreen ? "" : "muted"
        
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                * { margin: 0; padding: 0; }
                body { 
                    background: #000;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    height: 100vh;
                    overflow: hidden;
                }
                video {
                    width: 100%;
                    height: 100%;
                    object-fit: contain;
                }
            </style>
        </head>
        <body>
            <video id="player" autoplay playsinline \(muted) \(controls)></video>
            <script src="https://cdn.jsdelivr.net/npm/hls.js@1.4.12"></script>
            <script>
                const video = document.getElementById('player');
                const videoSrc = '\(streamURL)';
                
                let hls;
                let retryCount = 0;
                const maxRetries = 5;
                
                function initPlayer() {
                    if (Hls.isSupported()) {
                        hls = new Hls({
                            enableWorker: true,
                            lowLatencyMode: false,
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
                            debug: false
                        });
                        
                        hls.loadSource(videoSrc);
                        hls.attachMedia(video);
                        
                        hls.on(Hls.Events.MANIFEST_PARSED, function() {
                            video.play().then(() => {
                                window.webkit.messageHandlers.streamReady.postMessage('ready');
                                retryCount = 0;
                            }).catch(e => {
                                console.log('Play error:', e);
                                if (retryCount < maxRetries) {
                                    retryCount++;
                                    setTimeout(() => video.play(), 1000);
                                }
                            });
                        });
                        
                        hls.on(Hls.Events.ERROR, function(event, data) {
                            console.log('HLS Error:', data.type, data.details);
                            
                            if (data.fatal) {
                                switch(data.type) {
                                    case Hls.ErrorTypes.NETWORK_ERROR:
                                        console.log('Network error, attempting recovery...');
                                        if (retryCount < maxRetries) {
                                            retryCount++;
                                            setTimeout(() => {
                                                hls.startLoad();
                                            }, 1000);
                                        } else {
                                            window.webkit.messageHandlers.streamError.postMessage('Network error: ' + data.details);
                                        }
                                        break;
                                    case Hls.ErrorTypes.MEDIA_ERROR:
                                        console.log('Media error, attempting recovery...');
                                        hls.recoverMediaError();
                                        break;
                                    default:
                                        window.webkit.messageHandlers.streamError.postMessage('Fatal error: ' + data.details);
                                        break;
                                }
                            }
                        });
                        
                        // Keep stream alive
                        setInterval(() => {
                            if (video.paused && !video.ended) {
                                video.play().catch(e => console.log('Keepalive play failed:', e));
                            }
                        }, 5000);
                        
                    } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
                        // Native HLS support (Safari)
                        video.src = videoSrc;
                        video.addEventListener('loadedmetadata', function() {
                            video.play().then(() => {
                                window.webkit.messageHandlers.streamReady.postMessage('ready');
                            });
                        });
                        video.addEventListener('error', function(e) {
                            window.webkit.messageHandlers.streamError.postMessage('Native playback error: ' + e.message);
                        });
                    }
                }
                
                // Start player
                initPlayer();
                
                // Handle visibility changes
                document.addEventListener('visibilitychange', function() {
                    if (document.hidden) {
                        if (hls) hls.stopLoad();
                    } else {
                        if (hls) hls.startLoad();
                        video.play();
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
        
        init(_ parent: WebViewHLSPlayer) {
            self.parent = parent
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            DispatchQueue.main.async {
                if message.name == "streamReady" {
                    self.parent.isLoading = false
                    self.parent.errorMessage = nil
                } else if message.name == "streamError" {
                    self.parent.isLoading = false
                    self.parent.errorMessage = message.body as? String ?? "Stream error"
                }
            }
        }
    }
}

// MARK: - Camera Thumbnail (Grid Preview)
struct CameraThumbnail: View {
    let camera: Camera
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    
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
                
                if isLoading {
                    ZStack {
                        Color.black.opacity(0.7)
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
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
                        Text("LIVE")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.red)
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