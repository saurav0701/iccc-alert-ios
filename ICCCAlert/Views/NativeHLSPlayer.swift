import SwiftUI
import AVKit
import AVFoundation
import WebKit
import Combine

// MARK: - Player Manager (Thread-Safe)
class PlayerManager: ObservableObject {
    static let shared = PlayerManager()
    
    private var activePlayers: [String: Any] = [:]
    private let lock = NSRecursiveLock() // Use recursive lock to prevent deadlocks
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
        guard let player = activePlayers.removeValue(forKey: cameraId) else { return }
        
        // Safely release different player types
        if let avPlayer = player as? AVPlayer {
            avPlayer.pause()
            avPlayer.replaceCurrentItem(with: nil)
        } else if let webView = player as? WKWebView {
            webView.stopLoading()
            webView.configuration.userContentController.removeAllUserScripts()
            webView.loadHTMLString("", baseURL: nil)
        }
        
        print("🗑️ Released player: \(cameraId)")
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
        
        let keys = Array(activePlayers.keys) // Copy keys to avoid mutation during iteration
        keys.forEach { releasePlayerInternal($0) }
        
        print("🧹 Cleared all players")
    }
}

// MARK: - Hybrid Player (Crash-Proof)
struct HybridHLSPlayer: View {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    
    @State private var playerMode: PlayerMode = .webview // Start with WebView (most reliable)
    @State private var hasNativeFailed = false
    
    enum PlayerMode {
        case native
        case webview
    }
    
    var body: some View {
        ZStack {
            // Always use WebView for maximum compatibility
            SimpleWebViewPlayer(
                streamURL: streamURL,
                cameraId: cameraId,
                isFullscreen: isFullscreen
            )
        }
    }
}

// MARK: - Simple WebView Player (Most Reliable)
struct SimpleWebViewPlayer: UIViewRepresentable {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        
        // Enable media playback
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.backgroundColor = .black
        webView.isOpaque = false
        webView.navigationDelegate = context.coordinator
        
        // Add message handler for logging
        webView.configuration.userContentController.add(context.coordinator, name: "logger")
        
        PlayerManager.shared.registerPlayer(webView, for: cameraId)
        
        loadPlayer(in: webView)
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.configuration.userContentController.removeAllUserScripts()
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
                    background: rgba(0,0,0,0.8); border-radius: 12px;
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
                    padding: 6px 10px; font-size: 11px; border-radius: 4px;
                    font-family: monospace; z-index: 10;
                }
                .live-badge {
                    position: absolute; top: 10px; right: 10px;
                    background: rgba(0,0,0,0.7); color: white;
                    padding: 4px 8px; font-size: 10px; border-radius: 4px;
                    font-family: -apple-system, sans-serif; font-weight: bold;
                    display: none; z-index: 10;
                }
                .live-dot {
                    display: inline-block; width: 8px; height: 8px;
                    background: #ff0000; border-radius: 50%;
                    margin-right: 4px; animation: pulse 1.5s infinite;
                }
                @keyframes pulse {
                    0%, 100% { opacity: 1; }
                    50% { opacity: 0.5; }
                }
            </style>
        </head>
        <body>
            <div id="container">
                <video id="video" playsinline webkit-playsinline muted autoplay\(isFullscreen ? "" : "")></video>
                <div id="loading" class="overlay">
                    <div class="spinner"></div>
                    <div>Loading stream...</div>
                </div>
                <div id="error" class="overlay" style="display: none;">
                    <div style="font-size: 36px; margin-bottom: 10px;">⚠️</div>
                    <div id="errorText" style="font-weight: bold; margin-bottom: 8px;">Stream Error</div>
                    <div id="errorDetail" style="font-size: 12px; opacity: 0.8;"></div>
                </div>
                <div id="status">Initializing...</div>
                <div class="live-badge" id="liveBadge">
                    <span class="live-dot"></span>LIVE
                </div>
            </div>
            
            <script>
                (function() {
                    'use strict';
                    
                    const video = document.getElementById('video');
                    const loading = document.getElementById('loading');
                    const errorDiv = document.getElementById('error');
                    const errorText = document.getElementById('errorText');
                    const errorDetail = document.getElementById('errorDetail');
                    const status = document.getElementById('status');
                    const liveBadge = document.getElementById('liveBadge');
                    const streamUrl = '\(streamURL)';
                    
                    let retryCount = 0;
                    let maxRetries = 3;
                    let isDestroyed = false;
                    let playbackStarted = false;
                    
                    function log(msg) {
                        console.log('[Player]', msg);
                        status.textContent = msg;
                        
                        try {
                            window.webkit.messageHandlers.logger.postMessage({
                                camera: '\(cameraId)',
                                status: msg,
                                url: streamUrl
                            });
                        } catch(e) {}
                    }
                    
                    function showLoading() {
                        loading.style.display = 'block';
                        errorDiv.style.display = 'none';
                        liveBadge.style.display = 'none';
                    }
                    
                    function hideLoading() {
                        loading.style.display = 'none';
                    }
                    
                    function showError(title, detail) {
                        hideLoading();
                        errorDiv.style.display = 'block';
                        errorText.textContent = title;
                        errorDetail.textContent = detail || '';
                        liveBadge.style.display = 'none';
                        status.style.color = '#f44336';
                    }
                    
                    function showLive() {
                        hideLoading();
                        errorDiv.style.display = 'none';
                        liveBadge.style.display = '\(isFullscreen ? "none" : "block")';
                        status.style.color = '#4CAF50';
                    }
                    
                    function cleanup() {
                        if (isDestroyed) return;
                        isDestroyed = true;
                        
                        try {
                            video.pause();
                            video.src = '';
                            video.load();
                        } catch(e) {
                            console.error('Cleanup error:', e);
                        }
                    }
                    
                    window.addEventListener('beforeunload', cleanup);
                    window.addEventListener('pagehide', cleanup);
                    
                    function initPlayer() {
                        if (isDestroyed) return;
                        
                        log('Loading stream...');
                        showLoading();
                        
                        // Use iOS native HLS player
                        video.src = streamUrl;
                        
                        // Event: Data loaded
                        video.addEventListener('loadeddata', function() {
                            if (isDestroyed) return;
                            
                            log('✅ Stream ready');
                            hideLoading();
                            
                            // Auto-play
                            video.play().then(function() {
                                log('✅ Playing');
                                playbackStarted = true;
                                showLive();
                            }).catch(function(e) {
                                log('Play error: ' + e.message);
                                
                                // Retry play after a moment
                                setTimeout(function() {
                                    if (!isDestroyed && !playbackStarted) {
                                        video.play();
                                    }
                                }, 500);
                            });
                        }, { once: true });
                        
                        // Event: Playing
                        video.addEventListener('playing', function() {
                            if (!isDestroyed) {
                                log('✅ Playing');
                                playbackStarted = true;
                                showLive();
                            }
                        });
                        
                        // Event: Waiting/Buffering
                        video.addEventListener('waiting', function() {
                            if (!isDestroyed) {
                                log('⏳ Buffering...');
                            }
                        });
                        
                        // Event: Pause
                        video.addEventListener('pause', function() {
                            if (!isDestroyed && !video.ended) {
                                log('Paused');
                            }
                        });
                        
                        // Event: Stalled
                        video.addEventListener('stalled', function() {
                            if (!isDestroyed) {
                                log('⚠️ Stream stalled');
                            }
                        });
                        
                        // Event: Error
                        video.addEventListener('error', function(e) {
                            if (isDestroyed) return;
                            
                            let msg = 'Stream Error';
                            let detail = 'Cannot load stream';
                            
                            if (video.error) {
                                const code = video.error.code;
                                log('❌ Error code: ' + code);
                                
                                switch(code) {
                                    case 1:
                                        msg = 'Playback Aborted';
                                        detail = 'Stream loading was aborted';
                                        break;
                                    case 2:
                                        msg = 'Network Error';
                                        detail = 'Cannot reach stream server';
                                        
                                        // Retry on network errors
                                        if (retryCount < maxRetries) {
                                            retryCount++;
                                            log('Retry ' + retryCount + '/' + maxRetries + '...');
                                            setTimeout(function() {
                                                if (!isDestroyed) {
                                                    video.load();
                                                }
                                            }, 2000 * retryCount);
                                            return;
                                        }
                                        break;
                                    case 3:
                                        msg = 'Decode Error';
                                        detail = 'Cannot decode stream';
                                        break;
                                    case 4:
                                        msg = 'Format Not Supported';
                                        detail = 'Stream format not supported';
                                        break;
                                }
                            }
                            
                            showError(msg, detail);
                        }, { once: false });
                        
                        // Load video
                        video.load();
                    }
                    
                    // Start
                    log('Initializing...');
                    initPlayer();
                    
                })();
            </script>
        </body>
        </html>
        """
        
        webView.loadHTMLString(html, baseURL: nil)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: SimpleWebViewPlayer
        
        init(_ parent: SimpleWebViewPlayer) {
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
                } else if status.contains("Buffering") || status.contains("⏳") {
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
            print("💥 WebView crashed for: \(parent.cameraId) - reloading")
            
            // Reload on crash
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                webView.reload()
            }
        }
    }
}

// MARK: - Camera Thumbnail (Crash-Proof)
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

// MARK: - Fullscreen Player (Crash-Proof)
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