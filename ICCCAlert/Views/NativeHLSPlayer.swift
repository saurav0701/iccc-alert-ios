import SwiftUI
import WebKit

// MARK: - Player Manager
class PlayerManager: ObservableObject {
    static let shared = PlayerManager()
    
    private var activeWebViews: [String: WKWebView] = [:]
    private let lock = NSLock()
    private let maxPlayers = 2
    
    private init() {}
    
    func registerWebView(_ webView: WKWebView, for cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        if activeWebViews.count >= maxPlayers {
            if let oldestKey = activeWebViews.keys.first {
                releaseWebViewInternal(oldestKey)
            }
        }
        
        activeWebViews[cameraId] = webView
        print("📹 Registered WebView for: \(cameraId)")
    }
    
    private func releaseWebViewInternal(_ cameraId: String) {
        if let webView = activeWebViews.removeValue(forKey: cameraId) {
            webView.stopLoading()
            webView.loadHTMLString("", baseURL: nil)
            print("🗑️ Released WebView: \(cameraId)")
        }
    }
    
    func releaseWebView(_ cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        releaseWebViewInternal(cameraId)
    }
    
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        
        activeWebViews.keys.forEach { releaseWebViewInternal($0) }
        print("🧹 Cleared all WebViews")
    }
}

// MARK: - Enhanced WebView Player with hls.js
struct HLSWebViewPlayer: UIViewRepresentable {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.backgroundColor = .black
        webView.isOpaque = false
        webView.navigationDelegate = context.coordinator
        
        PlayerManager.shared.registerWebView(webView, for: cameraId)
        
        loadPlayer(in: webView)
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    private func loadPlayer(in webView: WKWebView) {
        // Using hls.js CDN version for better codec support
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                * {
                    margin: 0;
                    padding: 0;
                    box-sizing: border-box;
                    -webkit-user-select: none;
                    -webkit-touch-callout: none;
                }
                html, body {
                    width: 100%;
                    height: 100%;
                    overflow: hidden;
                    background: #000;
                }
                #container {
                    width: 100vw;
                    height: 100vh;
                    position: relative;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                }
                video {
                    width: 100%;
                    height: 100%;
                    object-fit: contain;
                    background: #000;
                }
                #loading, #error {
                    position: absolute;
                    top: 50%;
                    left: 50%;
                    transform: translate(-50%, -50%);
                    color: white;
                    font-family: -apple-system, sans-serif;
                    text-align: center;
                    padding: 20px;
                    display: none;
                    z-index: 10;
                }
                .spinner {
                    border: 3px solid rgba(255,255,255,0.3);
                    border-top: 3px solid white;
                    border-radius: 50%;
                    width: 40px;
                    height: 40px;
                    animation: spin 1s linear infinite;
                    margin: 0 auto 10px;
                }
                @keyframes spin {
                    0% { transform: rotate(0deg); }
                    100% { transform: rotate(360deg); }
                }
            </style>
        </head>
        <body>
            <div id="container">
                <video id="video" playsinline webkit-playsinline muted></video>
                <div id="loading">
                    <div class="spinner"></div>
                    <div>Loading...</div>
                </div>
                <div id="error">
                    <div style="font-size: 40px; margin-bottom: 10px;">⚠️</div>
                    <div id="errorText">Stream unavailable</div>
                </div>
            </div>
            
            <script src="https://cdn.jsdelivr.net/npm/hls.js@1.4.12"></script>
            <script>
                const video = document.getElementById('video');
                const loading = document.getElementById('loading');
                const errorDiv = document.getElementById('error');
                const errorText = document.getElementById('errorText');
                const streamUrl = '\(streamURL)';
                
                let hls = null;
                let retryCount = 0;
                let maxRetries = 3;
                let retryTimer = null;
                let playAttempts = 0;
                
                loading.style.display = 'block';
                
                function initPlayer() {
                    console.log('🎬 Initializing player for:', streamUrl);
                    
                    // Check if hls.js is supported
                    if (Hls.isSupported()) {
                        console.log('✅ hls.js supported - using it');
                        useHlsJs();
                    } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
                        console.log('✅ Native HLS supported - using native');
                        useNativeHls();
                    } else {
                        handleError('HLS not supported on this device');
                    }
                }
                
                function useHlsJs() {
                    if (hls) {
                        hls.destroy();
                    }
                    
                    hls = new Hls({
                        debug: false,
                        enableWorker: true,
                        lowLatencyMode: false,
                        backBufferLength: 30,
                        maxBufferLength: 30,
                        maxMaxBufferLength: 60,
                        maxBufferSize: 60 * 1000 * 1000,
                        maxBufferHole: 0.5,
                        highBufferWatchdogPeriod: 2,
                        nudgeOffset: 0.1,
                        nudgeMaxRetry: 5,
                        maxFragLookUpTolerance: 0.25,
                        liveSyncDurationCount: 3,
                        liveMaxLatencyDurationCount: 10,
                        liveDurationInfinity: true,
                        manifestLoadingTimeOut: 10000,
                        manifestLoadingMaxRetry: 3,
                        manifestLoadingRetryDelay: 1000,
                        levelLoadingTimeOut: 10000,
                        levelLoadingMaxRetry: 4,
                        levelLoadingRetryDelay: 1000,
                        fragLoadingTimeOut: 20000,
                        fragLoadingMaxRetry: 6,
                        fragLoadingRetryDelay: 1000,
                        startFragPrefetch: true,
                        xhrSetup: function(xhr, url) {
                            xhr.setRequestHeader('Cache-Control', 'no-cache');
                        }
                    });
                    
                    hls.loadSource(streamUrl);
                    hls.attachMedia(video);
                    
                    hls.on(Hls.Events.MANIFEST_PARSED, () => {
                        console.log('📋 Manifest parsed');
                        loading.style.display = 'none';
                        
                        video.play().then(() => {
                            console.log('▶️ Playing');
                            errorDiv.style.display = 'none';
                            retryCount = 0;
                        }).catch(e => {
                            console.error('Play failed:', e);
                            if (playAttempts < 3) {
                                playAttempts++;
                                setTimeout(() => video.play(), 500);
                            } else {
                                handleError('Cannot start playback');
                            }
                        });
                    });
                    
                    hls.on(Hls.Events.ERROR, (event, data) => {
                        console.error('❌ HLS Error:', data.type, data.details, data.fatal);
                        
                        if (data.fatal) {
                            switch(data.type) {
                                case Hls.ErrorTypes.NETWORK_ERROR:
                                    console.log('Network error - attempting recovery');
                                    if (retryCount < maxRetries) {
                                        retryCount++;
                                        setTimeout(() => {
                                            hls.startLoad();
                                        }, 1000);
                                    } else {
                                        handleError('Network error - stream unavailable');
                                    }
                                    break;
                                    
                                case Hls.ErrorTypes.MEDIA_ERROR:
                                    console.log('Media error - attempting recovery');
                                    if (retryCount < maxRetries) {
                                        retryCount++;
                                        hls.recoverMediaError();
                                    } else {
                                        // Try native HLS as fallback
                                        console.log('Switching to native HLS');
                                        useNativeHls();
                                    }
                                    break;
                                    
                                default:
                                    handleError('Fatal error: ' + data.details);
                                    break;
                            }
                        }
                    });
                    
                    hls.on(Hls.Events.FRAG_LOADED, () => {
                        loading.style.display = 'none';
                    });
                }
                
                function useNativeHls() {
                    console.log('Using native HLS playback');
                    
                    if (hls) {
                        hls.destroy();
                        hls = null;
                    }
                    
                    video.src = streamUrl;
                    video.load();
                    
                    video.addEventListener('loadeddata', () => {
                        loading.style.display = 'none';
                        video.play().catch(e => {
                            console.error('Native play failed:', e);
                            handleError('Cannot play stream');
                        });
                    });
                    
                    video.addEventListener('error', (e) => {
                        console.error('Native video error:', video.error);
                        
                        let msg = 'Stream error';
                        if (video.error) {
                            switch(video.error.code) {
                                case 1: msg = 'Loading aborted'; break;
                                case 2: msg = 'Network error'; break;
                                case 3: msg = 'Decode error - format not supported'; break;
                                case 4: msg = 'Stream not found'; break;
                            }
                        }
                        
                        handleError(msg);
                    });
                }
                
                // Video event handlers
                video.addEventListener('waiting', () => {
                    console.log('⏳ Buffering');
                    loading.style.display = 'block';
                });
                
                video.addEventListener('playing', () => {
                    console.log('▶️ Playing');
                    loading.style.display = 'none';
                    errorDiv.style.display = 'none';
                });
                
                video.addEventListener('stalled', () => {
                    console.log('⚠️ Stalled');
                });
                
                video.addEventListener('suspend', () => {
                    console.log('⏸️ Suspended');
                });
                
                function handleError(msg) {
                    console.error('💥 Final error:', msg);
                    loading.style.display = 'none';
                    errorDiv.style.display = 'block';
                    errorText.textContent = msg;
                }
                
                // Cleanup
                window.addEventListener('pagehide', () => {
                    if (hls) hls.destroy();
                    video.pause();
                    video.src = '';
                });
                
                // Start
                initPlayer();
            </script>
        </body>
        </html>
        """
        
        webView.loadHTMLString(html, baseURL: nil)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: HLSWebViewPlayer
        
        init(_ parent: HLSWebViewPlayer) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("✅ WebView loaded for: \(parent.cameraId)")
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("❌ WebView failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Camera Thumbnail
struct CameraThumbnail: View {
    let camera: Camera
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var shouldLoad = false
    
    var body: some View {
        ZStack {
            if let streamURL = camera.streamURL, camera.isOnline {
                if shouldLoad {
                    HLSWebViewPlayer(
                        streamURL: streamURL,
                        cameraId: camera.id,
                        isFullscreen: false,
                        isLoading: $isLoading,
                        errorMessage: $errorMessage
                    )
                } else {
                    placeholderView
                }
                
                if !isLoading && errorMessage == nil && shouldLoad {
                    liveIndicator
                }
            } else {
                offlineView
            }
        }
        .onAppear {
            shouldLoad = false
        }
        .onDisappear {
            shouldLoad = false
            PlayerManager.shared.releaseWebView(camera.id)
        }
    }
    
    private var placeholderView: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.blue.opacity(0.3),
                    Color.blue.opacity(0.1)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            VStack(spacing: 8) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.blue)
                Text("Tap to preview")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
        }
        .onTapGesture {
            shouldLoad = true
        }
    }
    
    private var liveIndicator: some View {
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
    
    private var offlineView: some View {
        ZStack {
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
    }
}

// MARK: - Fullscreen Player
struct HLSPlayerView: View {
    let camera: Camera
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let streamURL = camera.streamURL {
                HLSWebViewPlayer(
                    streamURL: streamURL,
                    cameraId: camera.id,
                    isFullscreen: true,
                    isLoading: $isLoading,
                    errorMessage: $errorMessage
                )
                .ignoresSafeArea()
            }
            
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(camera.displayName)
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        HStack(spacing: 8) {
                            Circle()
                                .fill(camera.isOnline ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            
                            Text(camera.area)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                    .padding()
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(10)
                    
                    Spacer()
                    
                    Button(action: {
                        PlayerManager.shared.releaseWebView(camera.id)
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
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .onDisappear {
            PlayerManager.shared.releaseWebView(camera.id)
        }
    }
}