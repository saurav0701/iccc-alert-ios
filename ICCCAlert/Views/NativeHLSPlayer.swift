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

// MARK: - Enhanced WebView Player with Codec Support
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
                #debug {
                    position: absolute;
                    bottom: 10px;
                    left: 10px;
                    background: rgba(0,0,0,0.7);
                    color: white;
                    padding: 8px;
                    font-size: 10px;
                    border-radius: 4px;
                    max-width: 90%;
                    word-wrap: break-word;
                }
            </style>
        </head>
        <body>
            <div id="container">
                <video id="video" playsinline webkit-playsinline muted autoplay></video>
                <div id="loading">
                    <div class="spinner"></div>
                    <div>Loading stream...</div>
                </div>
                <div id="error">
                    <div style="font-size: 40px; margin-bottom: 10px;">⚠️</div>
                    <div id="errorText">Stream unavailable</div>
                    <div id="errorDetail" style="font-size: 12px; margin-top: 10px; opacity: 0.7;"></div>
                </div>
                <div id="debug"></div>
            </div>
            
            <script src="https://cdn.jsdelivr.net/npm/hls.js@1.4.12/dist/hls.min.js" crossorigin="anonymous"></script>
            <script>
                const video = document.getElementById('video');
                const loading = document.getElementById('loading');
                const errorDiv = document.getElementById('error');
                const errorText = document.getElementById('errorText');
                const errorDetail = document.getElementById('errorDetail');
                const debugDiv = document.getElementById('debug');
                const streamUrl = '\(streamURL)';
                
                let hls = null;
                let retryCount = 0;
                let maxRetries = 5;
                let playAttempts = 0;
                let initAttempts = 0;
                let stallCount = 0;
                let lastFragTime = Date.now();
                let stallCheckInterval = null;
                
                loading.style.display = 'block';
                
                function log(msg) {
                    console.log(msg);
                    debugDiv.textContent = msg;
                }
                
                log('🎬 Initializing: ' + streamUrl);
                
                function initPlayer() {
                    initAttempts++;
                    
                    if (typeof Hls === 'undefined') {
                        if (initAttempts < 50) {
                            setTimeout(initPlayer, 100);
                            return;
                        } else {
                            handleError('Library failed to load', 'hls.js could not be loaded');
                            return;
                        }
                    }
                    
                    log('✅ hls.js loaded');
                    
                    if (Hls.isSupported()) {
                        log('📱 Using hls.js');
                        useHlsJs();
                    } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
                        log('📱 Using native HLS');
                        useNativeHls();
                    } else {
                        handleError('HLS not supported', 'Device cannot play HLS streams');
                    }
                }
                
                function useHlsJs() {
                    if (hls) {
                        hls.destroy();
                    }
                    
                    // ✅ CRITICAL: Optimized config for codec compatibility
                    hls = new Hls({
                        debug: false,
                        enableWorker: true,
                        lowLatencyMode: false,
                        
                        // ✅ Buffer settings - prevent 3-second stops
                        maxBufferLength: 15,              // Reduced from 30
                        maxMaxBufferLength: 30,           // Reduced from 60
                        maxBufferSize: 20 * 1000 * 1000,  // 20MB
                        maxBufferHole: 0.3,               // More aggressive hole jumping
                        
                        // ✅ Fragment settings - better handling
                        highBufferWatchdogPeriod: 3,
                        nudgeOffset: 0.05,
                        nudgeMaxRetry: 10,
                        maxFragLookUpTolerance: 0.5,
                        
                        // ✅ Live stream settings
                        liveSyncDurationCount: 2,          // Reduced for faster sync
                        liveMaxLatencyDurationCount: 6,     // Reduced
                        liveDurationInfinity: false,        // Better for some streams
                        
                        // ✅ Loading timeouts
                        manifestLoadingTimeOut: 20000,
                        manifestLoadingMaxRetry: 4,
                        manifestLoadingRetryDelay: 1000,
                        levelLoadingTimeOut: 20000,
                        levelLoadingMaxRetry: 4,
                        levelLoadingRetryDelay: 1000,
                        fragLoadingTimeOut: 30000,         // Increased for slow streams
                        fragLoadingMaxRetry: 6,
                        fragLoadingRetryDelay: 1000,
                        
                        // ✅ Start settings
                        startPosition: -1,                  // Start from live edge
                        startFragPrefetch: true,
                        testBandwidth: false,               // Skip bandwidth test
                        
                        // ✅ CRITICAL: Disable worker for codec compatibility
                        enableSoftwareAES: true,
                        
                        xhrSetup: function(xhr, url) {
                            xhr.withCredentials = false;
                        }
                    });
                    
                    hls.loadSource(streamUrl);
                    hls.attachMedia(video);
                    
                    // Track fragment loading
                    hls.on(Hls.Events.FRAG_LOADED, (event, data) => {
                        lastFragTime = Date.now();
                        stallCount = 0;
                        loading.style.display = 'none';
                        log('✅ Playing: frag ' + data.frag.sn);
                    });
                    
                    hls.on(Hls.Events.MANIFEST_PARSED, (event, data) => {
                        log('📋 Manifest: ' + data.levels.length + ' levels');
                        
                        // ✅ Force lowest quality for compatibility
                        if (data.levels.length > 0) {
                            hls.currentLevel = 0;
                            log('📊 Using level 0 for compatibility');
                        }
                        
                        loading.style.display = 'none';
                        
                        video.play().then(() => {
                            log('▶️ Playback started');
                            errorDiv.style.display = 'none';
                            retryCount = 0;
                            startStallMonitor();
                        }).catch(e => {
                            if (playAttempts < 3) {
                                playAttempts++;
                                setTimeout(() => video.play(), 500);
                            } else {
                                handleError('Cannot start', e.message);
                            }
                        });
                    });
                    
                    hls.on(Hls.Events.ERROR, (event, data) => {
                        console.error('HLS Error:', data.type, data.details, data.fatal);
                        log('❌ Error: ' + data.details);
                        
                        if (data.fatal) {
                            switch(data.type) {
                                case Hls.ErrorTypes.NETWORK_ERROR:
                                    if (retryCount < maxRetries) {
                                        retryCount++;
                                        log('🔄 Retry ' + retryCount + '/' + maxRetries);
                                        setTimeout(() => hls.startLoad(), 1000 * retryCount);
                                    } else {
                                        handleError('Network error', 'Cannot load stream');
                                    }
                                    break;
                                    
                                case Hls.ErrorTypes.MEDIA_ERROR:
                                    if (retryCount < maxRetries) {
                                        retryCount++;
                                        log('🔄 Media recovery ' + retryCount);
                                        
                                        if (data.details === 'bufferStalledError' || 
                                            data.details === 'bufferAppendError') {
                                            // Buffer issue - try swapping codec
                                            hls.swapAudioCodec();
                                            hls.recoverMediaError();
                                        } else {
                                            hls.recoverMediaError();
                                        }
                                    } else {
                                        // ✅ Last resort: try native player
                                        log('⚠️ Trying native HLS');
                                        if (hls) hls.destroy();
                                        useNativeHls();
                                    }
                                    break;
                                    
                                default:
                                    handleError('Playback error', data.details);
                                    break;
                            }
                        }
                    });
                    
                    // ✅ Monitor for codec issues
                    hls.on(Hls.Events.BUFFER_APPENDING, () => {
                        log('📦 Appending buffer');
                    });
                    
                    hls.on(Hls.Events.BUFFER_APPENDED, () => {
                        log('✅ Buffer appended');
                    });
                }
                
                function useNativeHls() {
                    log('📱 Native HLS mode');
                    
                    if (hls) {
                        hls.destroy();
                        hls = null;
                    }
                    
                    video.src = streamUrl;
                    video.load();
                    
                    video.addEventListener('loadeddata', () => {
                        log('✅ Native: loaded');
                        loading.style.display = 'none';
                        video.play().catch(e => {
                            handleError('Cannot play', e.message);
                        });
                    });
                    
                    video.addEventListener('error', (e) => {
                        let msg = 'Stream error';
                        let detail = '';
                        if (video.error) {
                            switch(video.error.code) {
                                case 3: 
                                    msg = 'Decode error';
                                    detail = 'Stream codec not supported by device';
                                    break;
                                case 4: 
                                    msg = 'Not found';
                                    detail = 'Stream URL not accessible';
                                    break;
                                default:
                                    detail = 'Error code: ' + video.error.code;
                            }
                        }
                        handleError(msg, detail);
                    });
                }
                
                // ✅ Stall monitor - detect when stream stops
                function startStallMonitor() {
                    if (stallCheckInterval) clearInterval(stallCheckInterval);
                    
                    stallCheckInterval = setInterval(() => {
                        const timeSinceLastFrag = Date.now() - lastFragTime;
                        
                        if (timeSinceLastFrag > 10000 && !video.paused) {
                            stallCount++;
                            log('⚠️ Stalled ' + stallCount + 'x');
                            
                            if (stallCount > 2 && hls) {
                                log('🔄 Recovering from stall');
                                hls.startLoad();
                                lastFragTime = Date.now();
                            }
                        }
                    }, 5000);
                }
                
                // Video event handlers
                video.addEventListener('waiting', () => {
                    log('⏳ Buffering');
                    loading.style.display = 'block';
                });
                
                video.addEventListener('playing', () => {
                    log('▶️ Playing');
                    loading.style.display = 'none';
                    errorDiv.style.display = 'none';
                });
                
                video.addEventListener('pause', () => {
                    if (!video.ended) {
                        log('⏸️ Paused unexpectedly');
                        // Auto-resume
                        setTimeout(() => {
                            if (video.paused && !video.ended) {
                                video.play();
                            }
                        }, 1000);
                    }
                });
                
                video.addEventListener('stalled', () => {
                    log('⚠️ Stream stalled');
                });
                
                function handleError(msg, detail) {
                    log('💥 ' + msg);
                    loading.style.display = 'none';
                    errorDiv.style.display = 'block';
                    errorText.textContent = msg;
                    if (detail) {
                        errorDetail.textContent = detail;
                    }
                    if (stallCheckInterval) clearInterval(stallCheckInterval);
                }
                
                // Cleanup
                window.addEventListener('pagehide', () => {
                    if (stallCheckInterval) clearInterval(stallCheckInterval);
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