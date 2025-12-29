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

// MARK: - Enhanced WebView Player with hls.js (PRIMARY SOLUTION FOR fMP4)
struct EnhancedWebViewPlayer: UIViewRepresentable {
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
        // Using hls.js 1.5.7 with optimized settings for fMP4/H.265
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
                    background: rgba(0,0,0,0.85); 
                    color: #4CAF50;
                    padding: 8px 14px; 
                    font-size: 12px; 
                    border-radius: 8px;
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    font-weight: 600;
                    z-index: 10;
                    display: flex;
                    align-items: center;
                    gap: 8px;
                    backdrop-filter: blur(10px);
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
                    50% { opacity: 0.6; transform: scale(0.9); }
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
                }
                @keyframes spin {
                    to { transform: rotate(360deg); }
                }
            </style>
        </head>
        <body>
            <div id="container">
                <video id="video" playsinline webkit-playsinline muted controls></video>
                <div id="status">
                    <div class="status-dot"></div>
                    <span>Loading...</span>
                </div>
                <div id="loading">
                    <div class="spinner"></div>
                </div>
            </div>
            
            <script>
                (function() {
                    'use strict';
                    
                    const video = document.getElementById('video');
                    const status = document.getElementById('status');
                    const loading = document.getElementById('loading');
                    const streamUrl = '\(streamURL)';
                    
                    let hls;
                    let retryCount = 0;
                    const maxRetries = 5;
                    
                    function updateStatus(text, color = '#4CAF50') {
                        const dot = status.querySelector('.status-dot');
                        const span = status.querySelector('span');
                        span.textContent = text;
                        dot.style.background = color;
                        status.style.color = color;
                    }
                    
                    function hideLoading() {
                        loading.style.display = 'none';
                    }
                    
                    function showLoading() {
                        loading.style.display = 'block';
                    }
                    
                    function initPlayer() {
                        console.log('Initializing hls.js for fMP4/H.265 stream');
                        
                        if (Hls.isSupported()) {
                            hls = new Hls({
                                debug: false,
                                enableWorker: true,
                                lowLatencyMode: true,
                                
                                // Buffer settings optimized for live streaming
                                backBufferLength: 20,
                                maxBufferLength: 30,
                                maxMaxBufferLength: 60,
                                maxBufferSize: 60 * 1000 * 1000,
                                maxBufferHole: 0.5,
                                highBufferWatchdogPeriod: 2,
                                nudgeOffset: 0.1,
                                nudgeMaxRetry: 5,
                                maxFragLookUpTolerance: 0.25,
                                
                                // Live stream settings
                                liveSyncDurationCount: 3,
                                liveMaxLatencyDurationCount: 10,
                                liveDurationInfinity: false,
                                
                                // Critical for fMP4 support
                                enableSoftwareAES: true,
                                
                                // Retry settings
                                manifestLoadingTimeOut: 10000,
                                manifestLoadingMaxRetry: 5,
                                manifestLoadingRetryDelay: 1000,
                                manifestLoadingMaxRetryTimeout: 64000,
                                
                                levelLoadingTimeOut: 10000,
                                levelLoadingMaxRetry: 6,
                                levelLoadingRetryDelay: 1000,
                                levelLoadingMaxRetryTimeout: 64000,
                                
                                fragLoadingTimeOut: 20000,
                                fragLoadingMaxRetry: 8,
                                fragLoadingRetryDelay: 1000,
                                fragLoadingMaxRetryTimeout: 64000,
                                
                                // Additional stability settings
                                startFragPrefetch: true,
                                testBandwidth: false
                            });
                            
                            hls.loadSource(streamUrl);
                            hls.attachMedia(video);
                            
                            hls.on(Hls.Events.MANIFEST_PARSED, function() {
                                console.log('✅ Manifest parsed successfully');
                                updateStatus('▶ Playing', '#4CAF50');
                                hideLoading();
                                
                                video.play().catch(e => {
                                    console.error('Play error:', e);
                                    updateStatus('⚠ Tap to play', '#FFA500');
                                });
                            });
                            
                            hls.on(Hls.Events.FRAG_LOADED, function() {
                                retryCount = 0; // Reset on successful fragment load
                                hideLoading();
                            });
                            
                            hls.on(Hls.Events.ERROR, function(event, data) {
                                console.error('HLS Error:', data.type, data.details, data.fatal);
                                
                                if (data.fatal) {
                                    switch(data.type) {
                                        case Hls.ErrorTypes.NETWORK_ERROR:
                                            console.log('Network error - attempting recovery...');
                                            updateStatus('⚠ Network error', '#FFA500');
                                            
                                            if (retryCount < maxRetries) {
                                                retryCount++;
                                                showLoading();
                                                setTimeout(() => {
                                                    console.log('Retry attempt:', retryCount);
                                                    hls.startLoad();
                                                }, 1000 * Math.min(retryCount, 3));
                                            } else {
                                                updateStatus('❌ Connection lost', '#ff6b6b');
                                                hideLoading();
                                            }
                                            break;
                                            
                                        case Hls.ErrorTypes.MEDIA_ERROR:
                                            console.log('Media error - recovering...');
                                            updateStatus('⚠ Recovering...', '#FFA500');
                                            hls.recoverMediaError();
                                            break;
                                            
                                        default:
                                            console.error('Fatal error:', data.details);
                                            updateStatus('❌ Error: ' + data.details, '#ff6b6b');
                                            hideLoading();
                                            
                                            // Try to restart after fatal error
                                            if (retryCount < maxRetries) {
                                                retryCount++;
                                                setTimeout(() => {
                                                    hls.destroy();
                                                    initPlayer();
                                                }, 3000);
                                            }
                                            break;
                                    }
                                } else if (data.type === Hls.ErrorTypes.MEDIA_ERROR) {
                                    // Non-fatal media errors
                                    console.log('Non-fatal media error, attempting recovery');
                                    hls.recoverMediaError();
                                }
                            });
                            
                            // Monitor playback health
                            hls.on(Hls.Events.BUFFER_APPENDING, function() {
                                hideLoading();
                            });
                            
                            hls.on(Hls.Events.LEVEL_LOADED, function(event, data) {
                                console.log('Level loaded:', data.details.totalduration, 'seconds');
                            });
                            
                        } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
                            // Fallback to native HLS (may not work well with fMP4)
                            console.log('Using native HLS player');
                            video.src = streamUrl;
                            video.addEventListener('loadedmetadata', function() {
                                updateStatus('▶ Playing (Native)', '#4CAF50');
                                hideLoading();
                                video.play();
                            });
                        } else {
                            updateStatus('❌ HLS not supported', '#ff6b6b');
                            hideLoading();
                        }
                    }
                    
                    // Video event handlers
                    video.addEventListener('playing', function() {
                        updateStatus('🔴 LIVE', '#ff0000');
                        hideLoading();
                    });
                    
                    video.addEventListener('waiting', function() {
                        updateStatus('⏳ Buffering...', '#FFA500');
                        showLoading();
                    });
                    
                    video.addEventListener('stalled', function() {
                        console.warn('Video stalled');
                        updateStatus('⚠ Stalled', '#FFA500');
                    });
                    
                    video.addEventListener('error', function(e) {
                        const error = video.error;
                        if (error) {
                            console.error('Video error:', error.code, error.message);
                            updateStatus('❌ Video error: ' + error.code, '#ff6b6b');
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
                    
                    // Initialize player
                    initPlayer();
                    
                    // Cleanup on page unload
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
        var parent: EnhancedWebViewPlayer
        
        init(_ parent: EnhancedWebViewPlayer) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("✅ WebView loaded for: \(parent.cameraId)")
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("❌ WebView navigation failed: \(error.localizedDescription)")
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("❌ WebView provisional navigation failed: \(error.localizedDescription)")
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
                    EnhancedWebViewPlayer(
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
                EnhancedWebViewPlayer(
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