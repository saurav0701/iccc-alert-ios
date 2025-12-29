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

// MARK: - Fixed HLS Player with Proper H.265 Support
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
                * {
                    margin: 0;
                    padding: 0;
                    box-sizing: border-box;
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
                .overlay {
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
                    background: rgba(0,0,0,0.8);
                    border-radius: 12px;
                    max-width: 80%;
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
                #status {
                    position: absolute;
                    bottom: 10px;
                    left: 10px;
                    background: rgba(0,0,0,0.7);
                    color: #4CAF50;
                    padding: 6px 10px;
                    font-size: 11px;
                    border-radius: 4px;
                    font-family: monospace;
                }
            </style>
        </head>
        <body>
            <div id="container">
                <video id="video" playsinline webkit-playsinline muted></video>
                <div id="loading" class="overlay">
                    <div class="spinner"></div>
                    <div>Loading...</div>
                </div>
                <div id="error" class="overlay">
                    <div style="font-size: 36px; margin-bottom: 10px;">⚠️</div>
                    <div id="errorText" style="font-weight: bold; margin-bottom: 8px;">Stream Error</div>
                    <div id="errorDetail" style="font-size: 12px; opacity: 0.8;"></div>
                </div>
                <div id="status">Initializing...</div>
            </div>
            
            <script src="https://cdn.jsdelivr.net/npm/hls.js@1.4.12/dist/hls.min.js"></script>
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
                    let maxRetries = 3;
                    let isDestroyed = false;
                    let healthCheckInterval = null;
                    let lastUpdate = Date.now();
                    let useNativePlayer = false;
                    
                    window.addEventListener('beforeunload', cleanup);
                    window.addEventListener('pagehide', cleanup);
                    
                    function updateStatus(msg, color) {
                        if (isDestroyed) return;
                        status.textContent = msg;
                        status.style.color = color || '#4CAF50';
                        console.log('[Player]', msg);
                        
                        try {
                            window.webkit.messageHandlers.logger.postMessage({
                                camera: '\(cameraId)',
                                status: msg,
                                url: streamUrl
                            });
                        } catch(e) {}
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
                        
                        updateStatus('Cleaning up...', '#ff9800');
                        
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
                            video.removeAttribute('src');
                            video.load();
                        } catch(e) {
                            console.error('Video cleanup error:', e);
                        }
                    }
                    
                    // ✅ CRITICAL FIX: Try native player FIRST on iOS
                    function initPlayer() {
                        if (isDestroyed) return;
                        
                        updateStatus('Starting player...');
                        
                        // ✅ Check if native HLS is supported (it is on iOS!)
                        if (video.canPlayType('application/vnd.apple.mpegurl')) {
                            updateStatus('Using native iOS HLS player (supports H.264 & H.265)');
                            useNativeHls();
                        } else if (typeof Hls !== 'undefined' && Hls.isSupported()) {
                            updateStatus('Using HLS.js (H.264 only)');
                            useHlsJs();
                        } else {
                            showError('Not Supported', 'HLS playback unavailable on this device');
                        }
                    }
                    
                    // ✅ Native iOS player - supports both H.264 and H.265!
                    function useNativeHls() {
                        if (isDestroyed) return;
                        
                        showLoading();
                        video.src = streamUrl;
                        
                        video.addEventListener('loadeddata', function() {
                            if (isDestroyed) return;
                            hideLoading();
                            updateStatus('✅ Native HLS playing (H.264/H.265 supported)');
                            video.play().catch(e => console.error('Play error:', e));
                            startHealthCheck();
                        });
                        
                        video.addEventListener('error', function() {
                            if (isDestroyed) return;
                            
                            let msg = 'Stream Error';
                            let detail = 'Cannot load stream';
                            
                            if (video.error) {
                                console.error('Video error code:', video.error.code, video.error.message);
                                
                                switch(video.error.code) {
                                    case 1: // MEDIA_ERR_ABORTED
                                        msg = 'Stream Aborted';
                                        detail = 'Stream loading was aborted';
                                        break;
                                    case 2: // MEDIA_ERR_NETWORK
                                        msg = 'Network Error';
                                        detail = 'Cannot reach stream server. Check network.';
                                        break;
                                    case 3: // MEDIA_ERR_DECODE
                                        msg = 'Decode Error';
                                        detail = 'Stream format issue (check server encoding)';
                                        break;
                                    case 4: // MEDIA_ERR_SRC_NOT_SUPPORTED
                                        msg = 'Stream Format Not Supported';
                                        detail = 'The stream format or codec is not supported';
                                        break;
                                    default:
                                        detail = 'Error code: ' + video.error.code;
                                }
                            }
                            
                            showError(msg, detail);
                        });
                        
                        video.load();
                    }
                    
                    // HLS.js fallback (only works for H.264)
                    function useHlsJs() {
                        if (isDestroyed) return;
                        
                        try {
                            hls = new Hls({
                                debug: false,
                                enableWorker: false,
                                maxBufferLength: 10,
                                maxMaxBufferLength: 20,
                                maxBufferSize: 10 * 1000 * 1000,
                                maxBufferHole: 0.5,
                                manifestLoadingTimeOut: 10000,
                                manifestLoadingMaxRetry: 2,
                                levelLoadingTimeOut: 10000,
                                fragLoadingTimeOut: 20000,
                                fragLoadingMaxRetry: 3,
                                enableSoftwareAES: true,
                                startPosition: -1,
                                fragLoadingMaxRetryTimeout: 64000,
                                levelLoadingMaxRetryTimeout: 64000,
                                xhrSetup: function(xhr) {
                                    xhr.withCredentials = false;
                                }
                            });
                            
                            hls.on(Hls.Events.MANIFEST_PARSED, function(event, data) {
                                if (isDestroyed) return;
                                updateStatus('Manifest loaded (' + data.levels.length + ' levels)');
                                hideLoading();
                                hls.currentLevel = 0;
                                
                                video.play().then(function() {
                                    updateStatus('✅ Playing (HLS.js - H.264 only)');
                                    startHealthCheck();
                                }).catch(function(e) {
                                    console.error('Play error:', e);
                                    setTimeout(function() {
                                        if (!isDestroyed) video.play();
                                    }, 500);
                                });
                            });
                            
                            hls.on(Hls.Events.FRAG_LOADED, function() {
                                if (isDestroyed) return;
                                lastUpdate = Date.now();
                            });
                            
                            hls.on(Hls.Events.ERROR, function(event, data) {
                                if (isDestroyed) return;
                                
                                console.error('HLS Error:', data.type, data.details, data.fatal);
                                
                                if (data.fatal) {
                                    switch(data.type) {
                                        case Hls.ErrorTypes.NETWORK_ERROR:
                                            if (retryCount < maxRetries) {
                                                retryCount++;
                                                updateStatus('Network error, retry ' + retryCount, '#ff9800');
                                                setTimeout(function() {
                                                    if (!isDestroyed) hls.startLoad();
                                                }, 2000);
                                            } else {
                                                showError('Network Error', 'Cannot load stream from server');
                                            }
                                            break;
                                            
                                        case Hls.ErrorTypes.MEDIA_ERROR:
                                            // ✅ FIXED: Don't assume H.265, try native player instead
                                            if (data.details.includes('Decode') || data.details.includes('frag')) {
                                                updateStatus('⚠️ HLS.js decode error, trying native player...', '#ff9800');
                                                cleanup();
                                                setTimeout(function() {
                                                    if (!isDestroyed) {
                                                        useNativePlayer = true;
                                                        useNativeHls();
                                                    }
                                                }, 500);
                                            } else if (retryCount < maxRetries) {
                                                retryCount++;
                                                updateStatus('Media error, recovering...', '#ff9800');
                                                hls.recoverMediaError();
                                            } else {
                                                showError('Media Error', 'Stream format issue');
                                            }
                                            break;
                                            
                                        default:
                                            showError('Playback Error', data.details || 'Unknown error');
                                            break;
                                    }
                                }
                            });
                            
                            hls.loadSource(streamUrl);
                            hls.attachMedia(video);
                            showLoading();
                            
                        } catch(e) {
                            console.error('HLS setup error:', e);
                            showError('Setup Failed', e.message);
                        }
                    }
                    
                    function startHealthCheck() {
                        if (healthCheckInterval) return;
                        
                        healthCheckInterval = setInterval(function() {
                            if (isDestroyed) return;
                            
                            const timeSinceUpdate = Date.now() - lastUpdate;
                            
                            if (!video.paused && !video.ended) {
                                if (timeSinceUpdate > 15000) {
                                    updateStatus('Stream stalled, reloading...', '#ff9800');
                                    if (hls) {
                                        hls.stopLoad();
                                        hls.startLoad();
                                        lastUpdate = Date.now();
                                    }
                                }
                            }
                        }, 5000);
                    }
                    
                    video.addEventListener('waiting', function() {
                        if (!isDestroyed) updateStatus('Buffering...', '#ff9800');
                    });
                    
                    video.addEventListener('playing', function() {
                        if (!isDestroyed) {
                            updateStatus('✅ Playing');
                            hideLoading();
                            lastUpdate = Date.now();
                        }
                    });
                    
                    video.addEventListener('pause', function() {
                        if (!isDestroyed && !video.ended) {
                            updateStatus('Paused', '#ff9800');
                        }
                    });
                    
                    showLoading();
                    
                    // ✅ Wait for HLS.js to load before initializing
                    if (typeof Hls === 'undefined') {
                        setTimeout(initPlayer, 200);
                    } else {
                        initPlayer();
                    }
                    
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
                
                if status.contains("Error") || status.contains("Codec Not Supported") {
                    DebugLogger.shared.log(logMessage, emoji: "❌", color: .red)
                } else if status.contains("Playing") || status.contains("✅") {
                    DebugLogger.shared.log(logMessage, emoji: "✅", color: .green)
                } else if status.contains("Buffering") {
                    DebugLogger.shared.log(logMessage, emoji: "⏳", color: .orange)
                } else {
                    DebugLogger.shared.log(logMessage, emoji: "📹", color: .blue)
                }
            }
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("✅ WebView loaded for: \(parent.cameraId)")
            DebugLogger.shared.log("WebView loaded: \(parent.cameraId)", emoji: "📱", color: .blue)
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("❌ WebView navigation failed: \(error.localizedDescription)")
            DebugLogger.shared.log("WebView failed: \(parent.cameraId) - \(error.localizedDescription)", emoji: "❌", color: .red)
        }
        
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            print("⚠️ WebView process terminated for: \(parent.cameraId)")
            DebugLogger.shared.log("WebView crashed: \(parent.cameraId)", emoji: "💥", color: .red)
            DispatchQueue.main.async {
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