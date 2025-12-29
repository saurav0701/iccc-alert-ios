import SwiftUI
import WebKit

// MARK: - Player Manager (Memory Safe)
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
            webView.configuration.userContentController.removeAllUserScripts()
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

// MARK: - FINAL Chrome-Identical HLS Player
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
        
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.processPool = WKProcessPool()
        
        let contentController = config.userContentController
        contentController.add(context.coordinator, name: "logger")
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.backgroundColor = .black
        webView.isOpaque = false
        webView.navigationDelegate = context.coordinator
        
        webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        
        PlayerManager.shared.registerWebView(webView, for: cameraId)
        
        loadPlayer(in: webView)
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.loadHTMLString("", baseURL: nil)
    }
    
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
                * { margin: 0; padding: 0; box-sizing: border-box; }
                html, body { width: 100%; height: 100%; overflow: hidden; background: #000; }
                #container { width: 100vw; height: 100vh; position: relative; display: flex; align-items: center; justify-content: center; }
                video { width: 100%; height: 100%; object-fit: contain; background: #000; }
                .overlay {
                    position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%);
                    color: white; font-family: -apple-system, sans-serif; text-align: center;
                    padding: 20px; display: none; z-index: 10;
                    background: rgba(0,0,0,0.8); border-radius: 12px; max-width: 80%;
                }
                .spinner {
                    border: 3px solid rgba(255,255,255,0.3); border-top: 3px solid white;
                    border-radius: 50%; width: 40px; height: 40px;
                    animation: spin 1s linear infinite; margin: 0 auto 10px;
                }
                @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
                #status {
                    position: absolute; bottom: 10px; left: 10px;
                    background: rgba(0,0,0,0.7); color: #4CAF50;
                    padding: 6px 10px; font-size: 11px; border-radius: 4px; font-family: monospace;
                }
            </style>
        </head>
        <body>
            <div id="container">
                <video id="video" playsinline webkit-playsinline muted autoplay></video>
                <div id="loading" class="overlay">
                    <div class="spinner"></div>
                    <div>Loading stream...</div>
                </div>
                <div id="error" class="overlay">
                    <div style="font-size: 36px; margin-bottom: 10px;">⚠️</div>
                    <div id="errorText" style="font-weight: bold; margin-bottom: 8px;">Stream Error</div>
                    <div id="errorDetail" style="font-size: 12px; opacity: 0.8;"></div>
                </div>
                <div id="status">Initializing...</div>
            </div>
            
            <script src="https://cdn.jsdelivr.net/npm/hls.js@1.5.15/dist/hls.min.js"></script>
            <script>
                (function() {
                    'use strict';
                    
                    const video = document.getElementById('video');
                    const loading = document.getElementById('loading');
                    const errorDiv = document.getElementById('error');
                    const errorText = document.getElementById('errorText');
                    const errorDetail = document.getElementById('errorDetail');
                    const status = document.getElementById('status');
                    const streamUrl = '\(streamURL)';
                    
                    let hls = null;
                    let retryCount = 0;
                    let maxRetries = 5;
                    let isDestroyed = false;
                    let healthCheckInterval = null;
                    let lastUpdate = Date.now();
                    let playbackStarted = false;
                    
                    window.addEventListener('beforeunload', cleanup);
                    window.addEventListener('pagehide', cleanup);
                    
                    function log(msg) {
                        console.log('[HLS Player]', msg);
                        try {
                            window.webkit.messageHandlers.logger.postMessage({
                                camera: '\(cameraId)',
                                status: msg,
                                url: streamUrl
                            });
                        } catch(e) {}
                    }
                    
                    function updateStatus(msg, color) {
                        if (isDestroyed) return;
                        status.textContent = msg;
                        status.style.color = color || '#4CAF50';
                        log(msg);
                    }
                    
                    function showLoading() {
                        if (isDestroyed) return;
                        loading.style.display = 'block';
                        errorDiv.style.display = 'none';
                    }
                    
                    function hideLoading() {
                        if (isDestroyed) return;
                        loading.style.display = 'none';
                    }
                    
                    function showError(title, detail) {
                        if (isDestroyed) return;
                        hideLoading();
                        errorDiv.style.display = 'block';
                        errorText.textContent = title;
                        errorDetail.textContent = detail || '';
                        updateStatus('Error: ' + title, '#f44336');
                    }
                    
                    function cleanup() {
                        if (isDestroyed) return;
                        isDestroyed = true;
                        
                        log('Cleaning up...');
                        
                        if (healthCheckInterval) {
                            clearInterval(healthCheckInterval);
                            healthCheckInterval = null;
                        }
                        
                        if (hls) {
                            try {
                                hls.destroy();
                            } catch(e) {
                                console.error('HLS cleanup error:', e);
                            }
                            hls = null;
                        }
                        
                        try {
                            video.pause();
                            video.src = '';
                            video.load();
                        } catch(e) {
                            console.error('Video cleanup error:', e);
                        }
                    }
                    
                    // ✅ CRITICAL: Use HLS.js FIRST (exactly like Chrome)
                    function initPlayer() {
                        if (isDestroyed) return;
                        
                        log('Initializing player...');
                        log('Stream URL: ' + streamUrl);
                        
                        // Wait for HLS.js to load
                        if (typeof Hls === 'undefined') {
                            setTimeout(initPlayer, 100);
                            return;
                        }
                        
                        // ✅ Try HLS.js first (Chrome's behavior)
                        if (Hls.isSupported()) {
                            log('Using HLS.js (Chrome-compatible mode)');
                            useHlsJs();
                        } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
                            log('Fallback: Native iOS HLS');
                            useNativeHls();
                        } else {
                            showError('Not Supported', 'HLS playback unavailable');
                        }
                    }
                    
                    // ✅ HLS.js player (Chrome-identical configuration)
                    function useHlsJs() {
                        if (isDestroyed) return;
                        
                        try {
                            log('Creating HLS.js instance...');
                            
                            hls = new Hls({
                                debug: false,
                                enableWorker: true,
                                lowLatencyMode: false,
                                
                                // Buffer settings (Chrome-like)
                                maxBufferLength: 30,
                                maxMaxBufferLength: 600,
                                maxBufferSize: 60 * 1000 * 1000,
                                maxBufferHole: 0.5,
                                
                                // Loading settings
                                manifestLoadingTimeOut: 20000,
                                manifestLoadingMaxRetry: 6,
                                manifestLoadingRetryDelay: 1000,
                                levelLoadingTimeOut: 20000,
                                levelLoadingMaxRetry: 6,
                                levelLoadingRetryDelay: 1000,
                                fragLoadingTimeOut: 30000,
                                fragLoadingMaxRetry: 6,
                                fragLoadingRetryDelay: 1000,
                                
                                // Start configuration
                                startLevel: -1,
                                autoStartLoad: true,
                                startPosition: -1,
                                
                                // Codec support
                                enableSoftwareAES: true,
                                
                                // Error recovery
                                fragLoadingMaxRetryTimeout: 64000,
                                levelLoadingMaxRetryTimeout: 64000,
                                manifestLoadingMaxRetryTimeout: 64000,
                                
                                // CORS
                                xhrSetup: function(xhr, url) {
                                    xhr.withCredentials = false;
                                }
                            });
                            
                            log('HLS.js instance created');
                            
                            // Event: Manifest parsed
                            hls.on(Hls.Events.MANIFEST_PARSED, function(event, data) {
                                if (isDestroyed) return;
                                
                                log('✅ Manifest parsed: ' + data.levels.length + ' quality levels');
                                
                                // Log codec info
                                if (data.levels.length > 0) {
                                    const level = data.levels[0];
                                    log('Video codec: ' + (level.videoCodec || 'unknown'));
                                    log('Audio codec: ' + (level.audioCodec || 'unknown'));
                                }
                                
                                hideLoading();
                                
                                // Auto-play
                                video.play().then(function() {
                                    log('✅ Playback started');
                                    updateStatus('✅ Playing', '#4CAF50');
                                    playbackStarted = true;
                                    startHealthCheck();
                                }).catch(function(e) {
                                    log('Play error: ' + e.message);
                                    setTimeout(function() {
                                        if (!isDestroyed && !playbackStarted) {
                                            video.play();
                                        }
                                    }, 500);
                                });
                            });
                            
                            // Event: Level switched
                            hls.on(Hls.Events.LEVEL_SWITCHED, function(event, data) {
                                if (isDestroyed) return;
                                log('Quality switched to level ' + data.level);
                            });
                            
                            // Event: Fragment loaded
                            hls.on(Hls.Events.FRAG_LOADED, function(event, data) {
                                if (isDestroyed) return;
                                lastUpdate = Date.now();
                            });
                            
                            // Event: Error
                            hls.on(Hls.Events.ERROR, function(event, data) {
                                if (isDestroyed) return;
                                
                                log('❌ HLS Error: ' + data.type + ' - ' + data.details + ' (fatal: ' + data.fatal + ')');
                                
                                if (data.fatal) {
                                    switch(data.type) {
                                        case Hls.ErrorTypes.NETWORK_ERROR:
                                            log('Network error detected');
                                            if (retryCount < maxRetries) {
                                                retryCount++;
                                                updateStatus('Network error, retry ' + retryCount + '/' + maxRetries, '#ff9800');
                                                setTimeout(function() {
                                                    if (!isDestroyed) {
                                                        log('Retrying...');
                                                        hls.startLoad();
                                                    }
                                                }, 1000 * retryCount);
                                            } else {
                                                showError('Network Error', 
                                                    'Cannot reach stream server after ' + maxRetries + ' attempts');
                                            }
                                            break;
                                            
                                        case Hls.ErrorTypes.MEDIA_ERROR:
                                            log('Media error detected: ' + data.details);
                                            if (retryCount < maxRetries) {
                                                retryCount++;
                                                updateStatus('Media error, recovering... (' + retryCount + '/' + maxRetries + ')', '#ff9800');
                                                log('Attempting recovery...');
                                                hls.recoverMediaError();
                                            } else {
                                                log('⚠️ HLS.js failed, trying native player...');
                                                updateStatus('Switching to native player...', '#ff9800');
                                                cleanup();
                                                setTimeout(function() {
                                                    if (!isDestroyed) {
                                                        useNativeHls();
                                                    }
                                                }, 1000);
                                            }
                                            break;
                                            
                                        default:
                                            showError('Playback Error', 
                                                'Stream error: ' + data.details);
                                            break;
                                    }
                                }
                            });
                            
                            // Load stream
                            log('Loading stream...');
                            hls.loadSource(streamUrl);
                            hls.attachMedia(video);
                            showLoading();
                            
                        } catch(e) {
                            log('❌ HLS.js setup failed: ' + e.message);
                            showError('Setup Failed', 'Could not initialize player: ' + e.message);
                        }
                    }
                    
                    // Native iOS player (fallback)
                    function useNativeHls() {
                        if (isDestroyed) return;
                        
                        log('🍎 Using native iOS HLS player');
                        showLoading();
                        
                        video.src = streamUrl;
                        
                        video.addEventListener('loadeddata', function() {
                            if (isDestroyed) return;
                            log('✅ Native player: data loaded');
                            hideLoading();
                            updateStatus('✅ Native iOS player active');
                            video.play().catch(e => log('Play error: ' + e.message));
                            playbackStarted = true;
                            startHealthCheck();
                        }, { once: true });
                        
                        video.addEventListener('error', function(e) {
                            if (isDestroyed) return;
                            
                            let msg = 'Stream Error';
                            let detail = 'Cannot load stream';
                            
                            if (video.error) {
                                log('❌ Native player error code: ' + video.error.code);
                                
                                switch(video.error.code) {
                                    case 1:
                                        msg = 'Playback Aborted';
                                        detail = 'Stream loading was aborted';
                                        break;
                                    case 2:
                                        msg = 'Network Error';
                                        detail = 'Cannot reach stream server';
                                        break;
                                    case 3:
                                        msg = 'Decode Error';
                                        detail = 'Cannot decode stream. Check server codec configuration.';
                                        break;
                                    case 4:
                                        msg = 'Format Not Supported';
                                        detail = 'Stream format not supported. Server needs H.264 codec.';
                                        break;
                                }
                            }
                            
                            showError(msg, detail);
                        }, { once: true });
                        
                        video.load();
                    }
                    
                    function startHealthCheck() {
                        if (healthCheckInterval) return;
                        
                        healthCheckInterval = setInterval(function() {
                            if (isDestroyed) return;
                            
                            const timeSinceUpdate = Date.now() - lastUpdate;
                            
                            if (!video.paused && !video.ended) {
                                if (timeSinceUpdate > 30000) {
                                    log('⚠️ Stream stalled, reloading...');
                                    updateStatus('Stream stalled, reloading...', '#ff9800');
                                    
                                    if (hls) {
                                        hls.stopLoad();
                                        setTimeout(function() {
                                            if (!isDestroyed) {
                                                hls.startLoad();
                                                lastUpdate = Date.now();
                                            }
                                        }, 500);
                                    }
                                }
                            }
                        }, 5000);
                    }
                    
                    // Video events
                    video.addEventListener('waiting', function() {
                        if (!isDestroyed) updateStatus('Buffering...', '#ff9800');
                    });
                    
                    video.addEventListener('playing', function() {
                        if (!isDestroyed) {
                            updateStatus('✅ Playing');
                            hideLoading();
                            lastUpdate = Date.now();
                            playbackStarted = true;
                        }
                    });
                    
                    video.addEventListener('pause', function() {
                        if (!isDestroyed && !video.ended) {
                            updateStatus('Paused', '#ff9800');
                        }
                    });
                    
                    video.addEventListener('stalled', function() {
                        if (!isDestroyed) {
                            log('⚠️ Video stalled');
                            updateStatus('Stream stalled...', '#ff9800');
                        }
                    });
                    
                    // Start
                    showLoading();
                    log('Stream URL: ' + streamUrl);
                    initPlayer();
                    
                })();
            </script>
        </body>
        </html>
        """
        
        webView.loadHTMLString(html, baseURL: nil)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: HLSWebViewPlayer
        
        init(_ parent: HLSWebViewPlayer) {
            self.parent = parent
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "logger", let body = message.body as? [String: Any] {
                let camera = body["camera"] as? String ?? "unknown"
                let status = body["status"] as? String ?? "unknown"
                
                let logMessage = "[\(camera)] \(status)"
                
                if status.contains("Error") || status.contains("❌") {
                    DebugLogger.shared.log(logMessage, emoji: "❌", color: .red)
                } else if status.contains("Playing") || status.contains("✅") {
                    DebugLogger.shared.log(logMessage, emoji: "✅", color: .green)
                } else if status.contains("Buffering") || status.contains("stalled") {
                    DebugLogger.shared.log(logMessage, emoji: "⏳", color: .orange)
                } else {
                    DebugLogger.shared.log(logMessage, emoji: "📹", color: .blue)
                }
            }
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("✅ WebView loaded for: \(parent.cameraId)")
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("❌ WebView navigation failed: \(error.localizedDescription)")
        }
        
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            print("💥 WebView crashed for: \(parent.cameraId)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                PlayerManager.shared.releaseWebView(self.parent.cameraId)
            }
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