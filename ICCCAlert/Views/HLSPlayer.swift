import SwiftUI
import WebKit
import Combine

// MARK: - Player Manager
class PlayerManager: ObservableObject {
    static let shared = PlayerManager()
    
    private var activePlayers: [String: WKWebView] = [:]
    private let lock = NSLock()
    private let maxPlayers = 2
    
    private init() {}
    
    func registerPlayer(_ webView: WKWebView, for cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        if activePlayers.count >= maxPlayers {
            if let oldestKey = activePlayers.keys.first {
                releasePlayerInternal(oldestKey)
            }
        }
        
        activePlayers[cameraId] = webView
        print("📹 Registered player for: \(cameraId)")
    }
    
    private func releasePlayerInternal(_ cameraId: String) {
        if let webView = activePlayers.removeValue(forKey: cameraId) {
            webView.stopLoading()
            webView.loadHTMLString("", baseURL: nil)
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

// MARK: - Simple HTML5 Video Player
struct HybridHLSPlayer: View {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    
    var body: some View {
        SimpleHTML5Player(
            streamURL: streamURL,
            cameraId: cameraId,
            isFullscreen: isFullscreen
        )
    }
}

// MARK: - HTML5 Video Player (Native iOS HLS Support)
struct SimpleHTML5Player: UIViewRepresentable {
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
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
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
                    background: #000;
                }
                
                video {
                    width: 100%;
                    height: 100%;
                    object-fit: contain;
                    background: #000;
                }
                
                #live {
                    position: absolute;
                    top: 10px;
                    right: 10px;
                    background: rgba(244, 67, 54, 0.9);
                    color: white;
                    padding: 4px 8px;
                    border-radius: 4px;
                    font-size: 10px;
                    font-weight: 700;
                    font-family: -apple-system, sans-serif;
                    z-index: 10;
                    display: none;
                }
                
                #live.show {
                    display: flex;
                    align-items: center;
                    gap: 4px;
                }
                
                .dot {
                    width: 6px;
                    height: 6px;
                    background: white;
                    border-radius: 50%;
                    animation: pulse 1.5s ease-in-out infinite;
                }
                
                @keyframes pulse {
                    0%, 100% { opacity: 1; }
                    50% { opacity: 0.3; }
                }
                
                #status {
                    position: absolute;
                    bottom: 10px;
                    left: 10px;
                    background: rgba(0, 0, 0, 0.8);
                    color: #4CAF50;
                    padding: 6px 10px;
                    border-radius: 6px;
                    font-size: 11px;
                    font-family: -apple-system, sans-serif;
                    z-index: 10;
                }
                
                #status.error { color: #ff5252; }
            </style>
        </head>
        <body>
            <div id="container">
                <video 
                    id="video"
                    playsinline
                    webkit-playsinline
                    autoplay
                    muted
                    preload="none"
                ></video>
                <div id="live"><span class="dot"></span>LIVE</div>
                <div id="status">Loading...</div>
            </div>
            
            <script>
            (function() {
                'use strict';
                
                const video = document.getElementById('video');
                const status = document.getElementById('status');
                const live = document.getElementById('live');
                const streamUrl = '\(streamURL)';
                
                let playing = false;
                let checkInterval = null;
                let lastTime = 0;
                let stuckCount = 0;
                
                function log(msg, isError = false) {
                    console.log('[Player]', msg);
                    status.textContent = msg;
                    status.className = isError ? 'error' : '';
                }
                
                function init() {
                    log('Connecting...');
                    
                    // Set video source
                    video.src = streamUrl;
                    
                    // Event listeners
                    video.addEventListener('loadstart', () => {
                        log('Loading stream...');
                    });
                    
                    video.addEventListener('loadedmetadata', () => {
                        log('Stream loaded');
                        console.log('Duration:', video.duration);
                        console.log('Seekable:', video.seekable.length);
                    });
                    
                    video.addEventListener('loadeddata', () => {
                        log('Ready to play');
                        video.play().catch(e => {
                            log('Play error: ' + e.message, true);
                        });
                    });
                    
                    video.addEventListener('canplay', () => {
                        log('Can play');
                        if (!playing) {
                            video.play().catch(e => {
                                log('Play error: ' + e.message, true);
                            });
                        }
                    });
                    
                    video.addEventListener('playing', () => {
                        log('Playing');
                        playing = true;
                        live.classList.add('show');
                        startHealthCheck();
                    });
                    
                    video.addEventListener('waiting', () => {
                        log('Buffering...');
                    });
                    
                    video.addEventListener('pause', () => {
                        log('Paused');
                        // Auto-resume if not intentional
                        if (playing) {
                            setTimeout(() => {
                                video.play().catch(() => {});
                            }, 100);
                        }
                    });
                    
                    video.addEventListener('ended', () => {
                        log('Stream ended - reloading');
                        setTimeout(() => {
                            video.load();
                            video.play();
                        }, 1000);
                    });
                    
                    video.addEventListener('stalled', () => {
                        log('Stalled - recovering...');
                        video.load();
                        video.play();
                    });
                    
                    video.addEventListener('error', (e) => {
                        const error = video.error;
                        let msg = 'Error';
                        
                        if (error) {
                            switch(error.code) {
                                case 1: msg = 'ABORTED'; break;
                                case 2: msg = 'NETWORK'; break;
                                case 3: msg = 'DECODE'; break;
                                case 4: msg = 'SRC_NOT_SUPPORTED'; break;
                            }
                            msg += ' (' + error.code + ')';
                        }
                        
                        log(msg, true);
                        live.classList.remove('show');
                    });
                    
                    // Start loading
                    video.load();
                }
                
                function startHealthCheck() {
                    if (checkInterval) return;
                    
                    checkInterval = setInterval(() => {
                        const currentTime = video.currentTime;
                        
                        // Check if video is progressing
                        if (currentTime === lastTime && !video.paused && !video.ended) {
                            stuckCount++;
                            
                            if (stuckCount >= 3) {
                                log('Stuck detected - restarting...');
                                video.load();
                                video.play();
                                stuckCount = 0;
                            }
                        } else {
                            stuckCount = 0;
                        }
                        
                        lastTime = currentTime;
                        
                        // Keep at live edge for live streams
                        if (video.seekable.length > 0) {
                            const liveEnd = video.seekable.end(video.seekable.length - 1);
                            const lag = liveEnd - currentTime;
                            
                            if (lag > 10) {
                                log('Syncing to live...');
                                video.currentTime = liveEnd - 2;
                            }
                        }
                        
                        // Auto-play if paused
                        if (video.paused && !video.ended && video.readyState >= 2) {
                            log('Auto-resuming...');
                            video.play().catch(() => {});
                        }
                        
                    }, 2000);
                }
                
                // Visibility handling
                document.addEventListener('visibilitychange', () => {
                    if (!document.hidden && playing && video.paused) {
                        video.play().catch(() => {});
                    }
                });
                
                // Cleanup
                window.addEventListener('beforeunload', () => {
                    if (checkInterval) {
                        clearInterval(checkInterval);
                    }
                    video.pause();
                    video.src = '';
                });
                
                // Start
                init();
                
            })();
            </script>
        </body>
        </html>
        """
        
        webView.loadHTMLString(html, baseURL: nil)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: SimpleHTML5Player
        
        init(_ parent: SimpleHTML5Player) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("✅ HTML5 player loaded: \(parent.cameraId)")
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