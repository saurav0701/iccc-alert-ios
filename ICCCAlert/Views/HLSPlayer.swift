import SwiftUI
import AVKit
import AVFoundation
import WebKit
import Combine

// MARK: - Player Manager
class PlayerManager: ObservableObject {
    static let shared = PlayerManager()
    
    private var activePlayers: [String: Any] = [:]
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
    
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        
        activePlayers.keys.forEach { releasePlayerInternal($0) }
        print("🧹 Cleared all players")
    }
}

// MARK: - Main Player (WebView-First for Live Streaming)
struct HybridHLSPlayer: View {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    
    var body: some View {
        // Always use WebView with HLS.js for live streaming
        HLSJSPlayer(
            streamURL: streamURL,
            cameraId: cameraId,
            isFullscreen: isFullscreen
        )
    }
}

// MARK: - HLS.js WebView Player (Optimized for Live)
struct HLSJSPlayer: UIViewRepresentable {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        
        // Disable caching for live streams
        config.websiteDataStore = .nonPersistent()
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.backgroundColor = .black
        webView.isOpaque = false
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
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <script src="https://cdn.jsdelivr.net/npm/hls.js@1.5.8"></script>
            <style>
                * { 
                    margin: 0; 
                    padding: 0; 
                    box-sizing: border-box; 
                    -webkit-tap-highlight-color: transparent;
                }
                html, body { 
                    width: 100%; 
                    height: 100%; 
                    overflow: hidden; 
                    background: #000; 
                    position: fixed;
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
                    bottom: 10px; 
                    left: 10px;
                    background: rgba(0,0,0,0.8); 
                    color: #4CAF50;
                    padding: 4px 8px; 
                    font-size: 10px; 
                    border-radius: 4px;
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    z-index: 10;
                    pointer-events: none;
                }
                #live-indicator {
                    position: absolute;
                    top: 10px;
                    right: 10px;
                    background: rgba(255,0,0,0.8);
                    color: white;
                    padding: 4px 8px;
                    font-size: 10px;
                    border-radius: 4px;
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    font-weight: bold;
                    z-index: 10;
                    display: none;
                    pointer-events: none;
                }
                #live-indicator.active {
                    display: block;
                }
                .dot {
                    width: 6px;
                    height: 6px;
                    background: white;
                    border-radius: 50%;
                    display: inline-block;
                    margin-right: 4px;
                    animation: pulse 1.5s ease-in-out infinite;
                }
                @keyframes pulse {
                    0%, 100% { opacity: 1; }
                    50% { opacity: 0.3; }
                }
            </style>
        </head>
        <body>
            <div id="container">
                <video id="video" playsinline webkit-playsinline muted autoplay></video>
                <div id="live-indicator"><span class="dot"></span>LIVE</div>
                <div id="status">Initializing...</div>
            </div>
            
            <script>
                (function() {
                    'use strict';
                    
                    const video = document.getElementById('video');
                    const status = document.getElementById('status');
                    const liveIndicator = document.getElementById('live-indicator');
                    const streamUrl = '\(streamURL)';
                    
                    let hls = null;
                    let isPlaying = false;
                    
                    function log(msg, isError = false) {
                        console.log('[HLS.js]', msg);
                        status.textContent = msg;
                        status.style.color = isError ? '#f44336' : '#4CAF50';
                    }
                    
                    function initHLS() {
                        if (Hls.isSupported()) {
                            log('HLS.js supported ✓');
                            
                            hls = new Hls({
                                // Low-latency live streaming configuration
                                enableWorker: true,
                                lowLatencyMode: true,
                                backBufferLength: 10,           // Keep minimal back buffer
                                maxBufferLength: 3,             // Very small forward buffer (3 seconds)
                                maxMaxBufferLength: 5,          // Cap at 5 seconds
                                maxBufferSize: 5 * 1000 * 1000, // 5MB buffer
                                maxBufferHole: 0.2,             // Tolerate small gaps
                                highBufferWatchdogPeriod: 1,    // Monitor buffer frequently
                                liveSyncDurationCount: 2,       // Stay close to live edge
                                liveMaxLatencyDurationCount: 5, // Max latency before sync
                                liveDurationInfinity: false,
                                manifestLoadingTimeOut: 10000,
                                manifestLoadingMaxRetry: 3,
                                manifestLoadingRetryDelay: 500,
                                levelLoadingTimeOut: 10000,
                                levelLoadingMaxRetry: 4,
                                levelLoadingRetryDelay: 500,
                                fragLoadingTimeOut: 20000,
                                fragLoadingMaxRetry: 6,
                                fragLoadingRetryDelay: 500,
                                startPosition: -1,              // Start at live edge
                                autoStartLoad: true,
                                debug: false
                            });
                            
                            hls.loadSource(streamUrl);
                            hls.attachMedia(video);
                            
                            // HLS.js event handlers
                            hls.on(Hls.Events.MANIFEST_PARSED, function() {
                                log('Stream ready');
                                video.play().then(() => {
                                    log('Playing');
                                    isPlaying = true;
                                    liveIndicator.classList.add('active');
                                }).catch(e => {
                                    log('Play failed: ' + e.message, true);
                                });
                            });
                            
                            hls.on(Hls.Events.ERROR, function(event, data) {
                                if (data.fatal) {
                                    switch(data.type) {
                                        case Hls.ErrorTypes.NETWORK_ERROR:
                                            log('Network error, retrying...', true);
                                            hls.startLoad();
                                            break;
                                        case Hls.ErrorTypes.MEDIA_ERROR:
                                            log('Media error, recovering...', true);
                                            hls.recoverMediaError();
                                            break;
                                        default:
                                            log('Fatal error: ' + data.type, true);
                                            liveIndicator.classList.remove('active');
                                            setTimeout(() => {
                                                log('Restarting stream...');
                                                hls.destroy();
                                                initHLS();
                                            }, 3000);
                                            break;
                                    }
                                } else if (data.details === 'bufferStalledError') {
                                    log('Buffer stalled, syncing...');
                                    // Force sync to live edge
                                    const duration = video.duration;
                                    if (duration && isFinite(duration)) {
                                        const liveEdge = duration - 0.5;
                                        if (video.currentTime < liveEdge - 2) {
                                            video.currentTime = liveEdge;
                                        }
                                    }
                                }
                            });
                            
                            hls.on(Hls.Events.FRAG_LOADED, function() {
                                // Keep near live edge
                                const duration = video.duration;
                                if (duration && isFinite(duration) && isPlaying) {
                                    const lag = duration - video.currentTime;
                                    if (lag > 5) {
                                        // More than 5 seconds behind, jump to live
                                        video.currentTime = duration - 1;
                                        log('Synced to live');
                                    }
                                }
                            });
                            
                        } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
                            // iOS native HLS
                            log('Using native HLS');
                            video.src = streamUrl;
                            video.load();
                            
                            video.addEventListener('loadedmetadata', function() {
                                log('Stream ready');
                                video.play().then(() => {
                                    log('Playing (native)');
                                    isPlaying = true;
                                    liveIndicator.classList.add('active');
                                }).catch(e => {
                                    log('Play failed: ' + e.message, true);
                                });
                            });
                            
                            video.addEventListener('error', function() {
                                log('Playback error', true);
                                liveIndicator.classList.remove('active');
                            });
                        }
                    }
                    
                    // Video event handlers
                    video.addEventListener('playing', function() {
                        log('Playing');
                        liveIndicator.classList.add('active');
                    });
                    
                    video.addEventListener('waiting', function() {
                        log('Buffering...');
                    });
                    
                    video.addEventListener('pause', function() {
                        if (isPlaying) {
                            // Auto-resume if unintentional pause
                            video.play();
                        }
                    });
                    
                    video.addEventListener('stalled', function() {
                        log('Stream stalled, recovering...');
                        if (hls) {
                            hls.startLoad();
                        }
                    });
                    
                    // Monitor buffer health
                    setInterval(() => {
                        if (hls && isPlaying) {
                            const bufferInfo = hls.bufferLength;
                            if (bufferInfo < 0.5) {
                                log('Low buffer: ' + bufferInfo.toFixed(1) + 's');
                            }
                        }
                    }, 2000);
                    
                    // Initialize
                    initHLS();
                    
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
        var parent: HLSJSPlayer
        
        init(_ parent: HLSJSPlayer) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("✅ HLS.js player loaded for: \(parent.cameraId)")
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
                    HybridHLSPlayer(
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
                HybridHLSPlayer(
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