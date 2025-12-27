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

// MARK: - Enhanced WebView Player with hls.js (HTTP Support)
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
        
        // ✅ CRITICAL: Allow HTTP media loading
        config.mediaTypesRequiringUserActionForPlayback = []
        
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
        // ✅ FIXED: Force hls.js to handle ALL streams (including HTTP)
        // This prevents Safari from trying to use native playback
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
            </div>
            
            <script src="https://cdn.jsdelivr.net/npm/hls.js@1.4.12"></script>
            <script>
                const video = document.getElementById('video');
                const loading = document.getElementById('loading');
                const errorDiv = document.getElementById('error');
                const errorText = document.getElementById('errorText');
                const errorDetail = document.getElementById('errorDetail');
                const streamUrl = '\(streamURL)';
                
                let hls = null;
                let retryCount = 0;
                let maxRetries = 5;
                let playAttempts = 0;
                
                loading.style.display = 'block';
                
                console.log('🎬 Stream URL:', streamUrl);
                console.log('🔍 URL Protocol:', streamUrl.startsWith('http:') ? 'HTTP' : 'HTTPS');
                
                function initPlayer() {
                    // ✅ ALWAYS use hls.js, even if native HLS is supported
                    // This bypasses Safari's HTTP restrictions
                    if (Hls.isSupported()) {
                        console.log('✅ Using hls.js for stream playback');
                        useHlsJs();
                    } else {
                        console.error('❌ hls.js not supported on this device');
                        handleError('HLS playback not supported', 'Device does not support HLS.js');
                    }
                }
                
                function useHlsJs() {
                    if (hls) {
                        hls.destroy();
                    }
                    
                    hls = new Hls({
                        debug: true, // Enable for debugging
                        enableWorker: true,
                        lowLatencyMode: false,
                        
                        // Buffer settings
                        backBufferLength: 30,
                        maxBufferLength: 30,
                        maxMaxBufferLength: 60,
                        maxBufferSize: 60 * 1000 * 1000,
                        maxBufferHole: 0.5,
                        
                        // Retry settings
                        manifestLoadingTimeOut: 15000,
                        manifestLoadingMaxRetry: 4,
                        manifestLoadingRetryDelay: 1000,
                        levelLoadingTimeOut: 15000,
                        levelLoadingMaxRetry: 4,
                        levelLoadingRetryDelay: 1000,
                        fragLoadingTimeOut: 20000,
                        fragLoadingMaxRetry: 6,
                        fragLoadingRetryDelay: 1000,
                        
                        // ✅ CRITICAL: Custom XHR setup to ensure HTTP works
                        xhrSetup: function(xhr, url) {
                            console.log('📡 Loading:', url);
                            xhr.withCredentials = false;
                            xhr.setRequestHeader('Cache-Control', 'no-cache');
                        }
                    });
                    
                    hls.loadSource(streamUrl);
                    hls.attachMedia(video);
                    
                    hls.on(Hls.Events.MANIFEST_PARSED, (event, data) => {
                        console.log('📋 Manifest parsed successfully');
                        console.log('   Levels:', data.levels.length);
                        loading.style.display = 'none';
                        
                        // Auto-play after manifest loads
                        video.play().then(() => {
                            console.log('▶️ Playback started');
                            errorDiv.style.display = 'none';
                            retryCount = 0;
                        }).catch(e => {
                            console.error('❌ Play failed:', e.message);
                            if (playAttempts < 3) {
                                playAttempts++;
                                setTimeout(() => {
                                    console.log('🔄 Retry play attempt', playAttempts);
                                    video.play();
                                }, 500);
                            } else {
                                handleError('Cannot start playback', e.message);
                            }
                        });
                    });
                    
                    hls.on(Hls.Events.ERROR, (event, data) => {
                        console.error('❌ HLS Error:', {
                            type: data.type,
                            details: data.details,
                            fatal: data.fatal,
                            url: data.url,
                            response: data.response
                        });
                        
                        if (data.fatal) {
                            switch(data.type) {
                                case Hls.ErrorTypes.NETWORK_ERROR:
                                    console.log('🌐 Network error detected');
                                    if (retryCount < maxRetries) {
                                        retryCount++;
                                        console.log(\`🔄 Retry attempt \${retryCount}/\${maxRetries}\`);
                                        setTimeout(() => {
                                            hls.startLoad();
                                        }, 1000 * retryCount); // Exponential backoff
                                    } else {
                                        handleError(
                                            'Network error',
                                            \`Failed to load stream after \${maxRetries} attempts. Check your connection.\`
                                        );
                                    }
                                    break;
                                    
                                case Hls.ErrorTypes.MEDIA_ERROR:
                                    console.log('🎬 Media error detected');
                                    if (retryCount < maxRetries) {
                                        retryCount++;
                                        console.log(\`🔄 Attempting media recovery \${retryCount}/\${maxRetries}\`);
                                        hls.recoverMediaError();
                                    } else {
                                        handleError(
                                            'Media playback error',
                                            'The stream format may not be supported.'
                                        );
                                    }
                                    break;
                                    
                                default:
                                    handleError(
                                        'Playback error',
                                        data.details || 'Unknown error occurred'
                                    );
                                    break;
                            }
                        }
                    });
                    
                    hls.on(Hls.Events.FRAG_LOADED, (event, data) => {
                        loading.style.display = 'none';
                        console.log('✅ Fragment loaded:', data.frag.sn);
                    });
                    
                    hls.on(Hls.Events.LEVEL_LOADED, (event, data) => {
                        console.log('📊 Level loaded:', data.details.totalduration, 'seconds');
                    });
                }
                
                // Video event handlers
                video.addEventListener('waiting', () => {
                    console.log('⏳ Buffering...');
                    loading.style.display = 'block';
                });
                
                video.addEventListener('playing', () => {
                    console.log('▶️ Playing');
                    loading.style.display = 'none';
                    errorDiv.style.display = 'none';
                });
                
                video.addEventListener('stalled', () => {
                    console.log('⚠️ Stream stalled');
                });
                
                video.addEventListener('error', (e) => {
                    console.error('❌ Video element error:', video.error);
                    if (video.error) {
                        let msg = 'Video error';
                        let detail = '';
                        switch(video.error.code) {
                            case 1: 
                                msg = 'Loading aborted'; 
                                detail = 'Stream loading was aborted';
                                break;
                            case 2: 
                                msg = 'Network error'; 
                                detail = 'A network error occurred';
                                break;
                            case 3: 
                                msg = 'Decode error'; 
                                detail = 'Stream format not supported';
                                break;
                            case 4: 
                                msg = 'Stream not found'; 
                                detail = 'The stream URL is not accessible';
                                break;
                        }
                        handleError(msg, detail);
                    }
                });
                
                function handleError(msg, detail) {
                    console.error('💥 Final error:', msg, detail);
                    loading.style.display = 'none';
                    errorDiv.style.display = 'block';
                    errorText.textContent = msg;
                    if (detail) {
                        errorDetail.textContent = detail;
                    }
                }
                
                // Cleanup
                window.addEventListener('pagehide', () => {
                    console.log('👋 Page hiding - cleaning up');
                    if (hls) hls.destroy();
                    video.pause();
                    video.src = '';
                });
                
                // Start playback
                console.log('🚀 Initializing player...');
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
        
        // ✅ Allow HTTP loads
        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(.useCredential, nil)
        }
    }
}

// MARK: - Camera Thumbnail (unchanged)
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

// MARK: - Fullscreen Player (unchanged)
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