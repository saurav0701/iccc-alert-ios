import SwiftUI
import AVKit
import AVFoundation
import WebKit
import Combine

// MARK: - Player Manager
class PlayerManager: ObservableObject {
    static let shared = PlayerManager()
    
    private var activePlayers: [String: Any] = [:] // Can hold AVPlayer or WKWebView
    private let lock = NSLock()
    private let maxPlayers = 2
    
    private init() {}
    
    func registerPlayer(_ player: Any, for cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        if activePlayers.count >= maxPlayers {
            if let oldestKey = activePlayers.keys.first {
                releasePlayerInternal(oldestKey)
            }
        }
        
        activePlayers[cameraId] = player
        print("📹 Registered player for: \(cameraId)")
    }
    
    private func releasePlayerInternal(_ cameraId: String) {
        if let player = activePlayers.removeValue(forKey: cameraId) {
            if let avPlayer = player as? AVPlayer {
                avPlayer.pause()
                avPlayer.replaceCurrentItem(with: nil)
            } else if let webView = player as? WKWebView {
                webView.stopLoading()
                webView.loadHTMLString("", baseURL: nil)
            }
            print("🗑️ Released player: \(cameraId)")
        }
    }
    
    func releasePlayer(_ cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        releasePlayerInternal(cameraId)
    }
    
    func releaseWebView(_ cameraId: String) {
        releasePlayer(cameraId)
    }
    
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        
        activePlayers.keys.forEach { releasePlayerInternal($0) }
        print("🧹 Cleared all players")
    }
}

// MARK: - Adaptive Player with H.264 Fallback
struct AdaptiveHLSPlayer: UIViewRepresentable {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.backgroundColor = .black
        webView.isOpaque = true
        webView.navigationDelegate = context.coordinator
        
        PlayerManager.shared.registerPlayer(webView, for: cameraId)
        
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
        // Smart player that tries H.264 stream first, with comprehensive error handling
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <script src="https://cdn.jsdelivr.net/npm/hls.js@1.5.7"></script>
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                html, body { 
                    width: 100%; 
                    height: 100%; 
                    overflow: hidden; 
                    background: #000; 
                    -webkit-tap-highlight-color: transparent;
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                }
                #container { 
                    width: 100vw; 
                    height: 100vh; 
                    position: relative; 
                }
                video { 
                    width: 100%; 
                    height: 100%; 
                    object-fit: contain; 
                    background: #000; 
                }
                #status {
                    position: absolute; 
                    top: \(isFullscreen ? "50px" : "10px"); 
                    right: 10px;
                    background: rgba(0,0,0,0.9); 
                    color: #4CAF50;
                    padding: 10px 16px; 
                    font-size: 13px; 
                    border-radius: 8px;
                    font-weight: 600;
                    z-index: 10;
                    display: flex;
                    align-items: center;
                    gap: 8px;
                    backdrop-filter: blur(10px);
                    border: 1px solid rgba(76, 175, 80, 0.3);
                }
                .status-dot {
                    width: 8px;
                    height: 8px;
                    border-radius: 50%;
                    background: #4CAF50;
                    animation: pulse 2s infinite;
                }
                @keyframes pulse {
                    0%, 100% { opacity: 1; transform: scale(1); }
                    50% { opacity: 0.6; transform: scale(0.85); }
                }
                #loading {
                    position: absolute;
                    top: 50%;
                    left: 50%;
                    transform: translate(-50%, -50%);
                    text-align: center;
                }
                .spinner {
                    width: 50px;
                    height: 50px;
                    border: 4px solid rgba(255,255,255,0.1);
                    border-top-color: #4CAF50;
                    border-radius: 50%;
                    animation: spin 1s linear infinite;
                    margin: 0 auto;
                }
                @keyframes spin {
                    to { transform: rotate(360deg); }
                }
                .loading-text {
                    color: #fff;
                    margin-top: 16px;
                    font-size: 14px;
                    opacity: 0.8;
                }
                #error-overlay {
                    position: absolute;
                    top: 50%;
                    left: 50%;
                    transform: translate(-50%, -50%);
                    background: rgba(0,0,0,0.95);
                    color: #fff;
                    padding: 30px;
                    border-radius: 16px;
                    text-align: center;
                    display: none;
                    max-width: 80%;
                    border: 2px solid #ff6b6b;
                }
                .error-icon {
                    font-size: 48px;
                    margin-bottom: 16px;
                }
                .error-title {
                    font-size: 18px;
                    font-weight: bold;
                    margin-bottom: 8px;
                    color: #ff6b6b;
                }
                .error-message {
                    font-size: 14px;
                    opacity: 0.8;
                    line-height: 1.5;
                }
                #retry-btn {
                    margin-top: 20px;
                    padding: 12px 24px;
                    background: #4CAF50;
                    color: white;
                    border: none;
                    border-radius: 8px;
                    font-size: 16px;
                    font-weight: 600;
                    cursor: pointer;
                }
            </style>
        </head>
        <body>
            <div id="container">
                <video id="video" playsinline webkit-playsinline muted controls></video>
                <div id="status">
                    <div class="status-dot"></div>
                    <span>Connecting...</span>
                </div>
                <div id="loading">
                    <div class="spinner"></div>
                    <div class="loading-text">Loading stream...</div>
                </div>
                <div id="error-overlay">
                    <div class="error-icon">⚠️</div>
                    <div class="error-title">Stream Error</div>
                    <div class="error-message"></div>
                    <button id="retry-btn">Retry</button>
                </div>
            </div>
            
            <script>
                (function() {
                    'use strict';
                    
                    const video = document.getElementById('video');
                    const status = document.getElementById('status');
                    const loading = document.getElementById('loading');
                    const errorOverlay = document.getElementById('error-overlay');
                    const errorMessage = errorOverlay.querySelector('.error-message');
                    const retryBtn = document.getElementById('retry-btn');
                    
                    // Try H.264 stream first (better compatibility)
                    const baseUrl = '\(streamURL)'.replace('/index.m3u8', '');
                    const h264Url = baseUrl + '/video0_stream.m3u8'; // H.264 variant
                    const mainUrl = '\(streamURL)'; // Main playlist (might be H.265)
                    
                    let hls;
                    let retryCount = 0;
                    const maxRetries = 3;
                    let currentUrl = h264Url;
                    let hasTriedH264 = false;
                    let hasTriedMain = false;
                    
                    function updateStatus(text, color = '#4CAF50') {
                        const dot = status.querySelector('.status-dot');
                        const span = status.querySelector('span');
                        span.textContent = text;
                        dot.style.background = color;
                        status.style.color = color;
                        status.style.borderColor = color + '4D';
                    }
                    
                    function hideLoading() {
                        loading.style.display = 'none';
                    }
                    
                    function showLoading(text = 'Loading stream...') {
                        loading.style.display = 'block';
                        loading.querySelector('.loading-text').textContent = text;
                    }
                    
                    function showError(title, message) {
                        errorOverlay.style.display = 'block';
                        errorOverlay.querySelector('.error-title').textContent = title;
                        errorMessage.textContent = message;
                        hideLoading();
                    }
                    
                    function hideError() {
                        errorOverlay.style.display = 'none';
                    }
                    
                    function tryFallbackStream() {
                        if (!hasTriedH264) {
                            console.log('Trying H.264 stream...');
                            hasTriedH264 = true;
                            currentUrl = h264Url;
                            return true;
                        }
                        
                        if (!hasTriedMain) {
                            console.log('Trying main stream...');
                            hasTriedMain = true;
                            currentUrl = mainUrl;
                            return true;
                        }
                        
                        return false;
                    }
                    
                    function initPlayer() {
                        console.log('Initializing player with:', currentUrl);
                        showLoading();
                        hideError();
                        updateStatus('Connecting...', '#FFA500');
                        
                        if (hls) {
                            hls.destroy();
                        }
                        
                        if (Hls.isSupported()) {
                            hls = new Hls({
                                debug: false,
                                enableWorker: true,
                                lowLatencyMode: true,
                                
                                // Aggressive retry settings
                                manifestLoadingTimeOut: 15000,
                                manifestLoadingMaxRetry: 6,
                                manifestLoadingRetryDelay: 500,
                                manifestLoadingMaxRetryTimeout: 64000,
                                
                                levelLoadingTimeOut: 15000,
                                levelLoadingMaxRetry: 8,
                                levelLoadingRetryDelay: 500,
                                
                                fragLoadingTimeOut: 30000,
                                fragLoadingMaxRetry: 10,
                                fragLoadingRetryDelay: 500,
                                
                                // Buffer settings
                                backBufferLength: 15,
                                maxBufferLength: 30,
                                maxMaxBufferLength: 60,
                                maxBufferHole: 0.5,
                                
                                // Live settings
                                liveSyncDurationCount: 3,
                                liveMaxLatencyDurationCount: 10,
                                
                                enableSoftwareAES: true,
                                startFragPrefetch: true,
                                testBandwidth: false
                            });
                            
                            hls.loadSource(currentUrl);
                            hls.attachMedia(video);
                            
                            hls.on(Hls.Events.MANIFEST_PARSED, function(event, data) {
                                console.log('✅ Manifest parsed:', data);
                                updateStatus('▶ Playing', '#4CAF50');
                                hideLoading();
                                hideError();
                                
                                video.play().catch(e => {
                                    console.error('Play error:', e);
                                    updateStatus('Tap to play', '#FFA500');
                                });
                            });
                            
                            hls.on(Hls.Events.FRAG_LOADED, function() {
                                retryCount = 0;
                                hideLoading();
                            });
                            
                            hls.on(Hls.Events.ERROR, function(event, data) {
                                console.error('HLS Error:', {
                                    type: data.type,
                                    details: data.details,
                                    fatal: data.fatal,
                                    error: data.error
                                });
                                
                                if (data.fatal) {
                                    switch(data.type) {
                                        case Hls.ErrorTypes.NETWORK_ERROR:
                                            if (data.details === 'manifestLoadError' || 
                                                data.details === 'manifestLoadTimeOut') {
                                                // Manifest failed - try fallback
                                                if (tryFallbackStream()) {
                                                    setTimeout(() => initPlayer(), 1000);
                                                } else {
                                                    showError(
                                                        'Connection Failed',
                                                        'Cannot reach camera stream. Check network connection.'
                                                    );
                                                    updateStatus('❌ Offline', '#ff6b6b');
                                                }
                                            } else if (retryCount < maxRetries) {
                                                retryCount++;
                                                updateStatus('⚠ Reconnecting...', '#FFA500');
                                                showLoading('Reconnecting...');
                                                setTimeout(() => hls.startLoad(), 1000 * retryCount);
                                            } else {
                                                showError(
                                                    'Connection Lost',
                                                    'Stream disconnected. Tap retry to reconnect.'
                                                );
                                                updateStatus('❌ Disconnected', '#ff6b6b');
                                            }
                                            break;
                                            
                                        case Hls.ErrorTypes.MEDIA_ERROR:
                                            console.log('Media error, attempting recovery...');
                                            if (data.details === 'bufferAppendError' || 
                                                data.details === 'bufferAppendingError') {
                                                // Codec incompatibility - try fallback
                                                if (tryFallbackStream()) {
                                                    setTimeout(() => initPlayer(), 1000);
                                                } else {
                                                    showError(
                                                        'Codec Not Supported',
                                                        'This device cannot decode the video format (H.265). Contact admin for H.264 stream.'
                                                    );
                                                    updateStatus('❌ Unsupported', '#ff6b6b');
                                                }
                                            } else {
                                                updateStatus('⚠ Recovering...', '#FFA500');
                                                hls.recoverMediaError();
                                            }
                                            break;
                                            
                                        default:
                                            console.error('Fatal error:', data.details);
                                            if (tryFallbackStream()) {
                                                setTimeout(() => initPlayer(), 1000);
                                            } else {
                                                showError(
                                                    'Playback Error',
                                                    data.details || 'Unknown error occurred'
                                                );
                                                updateStatus('❌ Error', '#ff6b6b');
                                            }
                                            break;
                                    }
                                }
                            });
                            
                        } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
                            // Native HLS fallback
                            console.log('Using native HLS player');
                            video.src = currentUrl;
                            video.addEventListener('loadedmetadata', function() {
                                updateStatus('▶ Playing', '#4CAF50');
                                hideLoading();
                                video.play();
                            });
                        } else {
                            showError('Not Supported', 'HLS playback not supported on this device');
                            updateStatus('❌ Unsupported', '#ff6b6b');
                        }
                    }
                    
                    // Video event handlers
                    video.addEventListener('playing', function() {
                        updateStatus('🔴 LIVE', '#ff0000');
                        hideLoading();
                        hideError();
                    });
                    
                    video.addEventListener('waiting', function() {
                        updateStatus('⏳ Buffering', '#FFA500');
                        showLoading('Buffering...');
                    });
                    
                    video.addEventListener('stalled', function() {
                        console.warn('Video stalled');
                        updateStatus('⚠ Stalled', '#FFA500');
                    });
                    
                    video.addEventListener('error', function(e) {
                        const error = video.error;
                        if (error) {
                            console.error('Video error:', error.code, error.message);
                            
                            let errorMsg = '';
                            switch(error.code) {
                                case 1: errorMsg = 'Playback aborted'; break;
                                case 2: errorMsg = 'Network error'; break;
                                case 3: 
                                    errorMsg = 'Video codec not supported (H.265). Need H.264 stream.';
                                    if (tryFallbackStream()) {
                                        setTimeout(() => initPlayer(), 1000);
                                        return;
                                    }
                                    break;
                                case 4: errorMsg = 'Video format not supported'; break;
                                default: errorMsg = 'Unknown error';
                            }
                            
                            showError('Video Error', errorMsg);
                            updateStatus('❌ Error ' + error.code, '#ff6b6b');
                        }
                    });
                    
                    video.addEventListener('pause', function() {
                        if (!video.seeking) {
                            updateStatus('⏸ Paused', '#808080');
                        }
                    });
                    
                    video.addEventListener('loadstart', function() {
                        showLoading();
                    });
                    
                    video.addEventListener('canplay', function() {
                        hideLoading();
                    });
                    
                    // Retry button
                    retryBtn.addEventListener('click', function() {
                        retryCount = 0;
                        hasTriedH264 = false;
                        hasTriedMain = false;
                        currentUrl = h264Url;
                        initPlayer();
                    });
                    
                    // Initialize player
                    initPlayer();
                    
                    // Cleanup
                    window.addEventListener('beforeunload', function() {
                        if (hls) {
                            hls.destroy();
                        }
                    });
                    
                })();
            </script>
        </body>
        </html>
        """
        
        webView.loadHTMLString(html, baseURL: nil)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: AdaptiveHLSPlayer
        
        init(_ parent: AdaptiveHLSPlayer) {
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
    @State private var shouldLoad = false
    
    var body: some View {
        ZStack {
            if let streamURL = camera.streamURL, camera.isOnline {
                if shouldLoad {
                    AdaptiveHLSPlayer(
                        streamURL: streamURL,
                        cameraId: camera.id,
                        isFullscreen: false
                    )
                } else {
                    placeholderView
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
            PlayerManager.shared.releasePlayer(camera.id)
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
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let streamURL = camera.streamURL {
                AdaptiveHLSPlayer(
                    streamURL: streamURL,
                    cameraId: camera.id,
                    isFullscreen: true
                )
                .ignoresSafeArea()
            }
            
            // Top bar
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
                        PlayerManager.shared.releasePlayer(camera.id)
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
            PlayerManager.shared.releasePlayer(camera.id)
        }
    }
}