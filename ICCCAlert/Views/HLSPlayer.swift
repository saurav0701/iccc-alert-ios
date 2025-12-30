import SwiftUI
import AVKit
import AVFoundation
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

// MARK: - Main Player Component
struct HybridHLSPlayer: View {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    
    var body: some View {
        LowLatencyHLSPlayer(
            streamURL: streamURL,
            cameraId: cameraId,
            isFullscreen: isFullscreen
        )
    }
}

// MARK: - Low-Latency HLS Player
struct LowLatencyHLSPlayer: UIViewRepresentable {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        config.websiteDataStore = .nonPersistent()
        
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.backgroundColor = .black
        webView.isOpaque = true
        webView.navigationDelegate = context.coordinator
        
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        
        PlayerManager.shared.registerPlayer(webView, for: cameraId)
        loadPlayer(in: webView, coordinator: context.coordinator)
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "logger")
        uiView.stopLoading()
        uiView.loadHTMLString("", baseURL: nil)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    private func loadPlayer(in webView: WKWebView, coordinator: Coordinator) {
        guard let url = URL(string: streamURL) else {
            print("❌ Invalid stream URL: \(streamURL)")
            return
        }
        
        let scheme = url.scheme ?? "http"
        let host = url.host ?? ""
        let port = url.port.map { ":\($0)" } ?? ""
        let baseURL = "\(scheme)://\(host)\(port)"
        let pathComponents = url.path.components(separatedBy: "/").filter { !$0.isEmpty && $0 != "index.m3u8" }
        let streamPath = pathComponents.joined(separator: "/")
        
        print("📹 MediaMTX LL-HLS Player:")
        print("   Base: \(baseURL)")
        print("   Path: \(streamPath)")
        print("   Full: \(streamURL)")
        
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <title>LL-HLS Player</title>
            <script src="\(baseURL)/\(streamPath)/hls.min.js"></script>
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
                
                .badge {
                    position: absolute;
                    z-index: 10;
                    pointer-events: none;
                    font-family: -apple-system, sans-serif;
                    border-radius: 4px;
                    padding: 4px 8px;
                    font-size: 10px;
                    font-weight: 600;
                }
                
                #live {
                    top: 8px;
                    right: 8px;
                    background: rgba(244, 67, 54, 0.95);
                    color: white;
                    display: none;
                    align-items: center;
                    gap: 4px;
                }
                
                #live.active { display: flex; }
                
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
                    bottom: 8px;
                    left: 8px;
                    background: rgba(0, 0, 0, 0.85);
                    color: #4CAF50;
                    max-width: 80vw;
                }
                
                #status.error { color: #ff5252; }
                #status.warning { color: #ffa726; }
                
                #loader {
                    position: absolute;
                    top: 50%;
                    left: 50%;
                    transform: translate(-50%, -50%);
                    display: none;
                    flex-direction: column;
                    align-items: center;
                    gap: 12px;
                    background: rgba(0, 0, 0, 0.85);
                    padding: 20px;
                    border-radius: 12px;
                }
                
                #loader.visible { display: flex; }
                
                .spinner {
                    width: 36px;
                    height: 36px;
                    border: 3px solid rgba(255, 255, 255, 0.3);
                    border-top-color: white;
                    border-radius: 50%;
                    animation: spin 0.8s linear infinite;
                }
                
                @keyframes spin {
                    to { transform: rotate(360deg); }
                }
                
                .loader-text {
                    color: white;
                    font-size: 12px;
                    font-family: -apple-system, sans-serif;
                }
            </style>
        </head>
        <body>
            <div id="container">
                <video id="video" playsinline webkit-playsinline muted autoplay preload="none"></video>
                <div id="live" class="badge"><span class="dot"></span>LIVE</div>
                <div id="status" class="badge">Loading...</div>
                <div id="loader">
                    <div class="spinner"></div>
                    <span class="loader-text">Buffering...</span>
                </div>
            </div>
            
            <script>
            (function() {
                'use strict';
                
                const video = document.getElementById('video');
                const status = document.getElementById('status');
                const live = document.getElementById('live');
                const loader = document.getElementById('loader');
                
                const streamUrl = '\(streamURL)';
                const cameraId = '\(cameraId)';
                
                let hls = null;
                let playing = false;
                let retries = 0;
                let maxRetries = 5;
                let lastBufferTime = 0;
                
                function log(msg, level = 'info') {
                    console.log('[LL-HLS]', msg);
                    status.textContent = msg;
                    status.className = 'badge ' + level;
                    
                    try {
                        window.webkit.messageHandlers.logger.postMessage({
                            cameraId: cameraId,
                            status: msg,
                            level: level,
                            streamURL: streamUrl
                        });
                    } catch(e) {}
                }
                
                function showLoader() {
                    loader.classList.add('visible');
                    lastBufferTime = Date.now();
                }
                
                function hideLoader() {
                    loader.classList.remove('visible');
                }
                
                function init() {
                    if (Hls.isSupported()) {
                        log('Starting LL-HLS player...');
                        
                        hls = new Hls({
                            debug: false,
                            enableWorker: true,
                            lowLatencyMode: true,
                            
                            // CRITICAL: Low-Latency HLS settings
                            backBufferLength: 0,
                            maxBufferLength: 2,
                            maxMaxBufferLength: 3,
                            maxBufferSize: 5 * 1000 * 1000,
                            maxBufferHole: 0.3,
                            highBufferWatchdogPeriod: 1,
                            nudgeOffset: 0.1,
                            nudgeMaxRetry: 3,
                            maxFragLookUpTolerance: 0.1,
                            
                            liveSyncDurationCount: 1,
                            liveMaxLatencyDurationCount: 3,
                            liveDurationInfinity: false,
                            
                            // Start at live edge
                            startPosition: -1,
                            autoStartLoad: true,
                            
                            // Timeouts
                            manifestLoadingTimeOut: 8000,
                            manifestLoadingMaxRetry: 3,
                            manifestLoadingRetryDelay: 500,
                            levelLoadingTimeOut: 8000,
                            levelLoadingMaxRetry: 4,
                            levelLoadingRetryDelay: 500,
                            fragLoadingTimeOut: 15000,
                            fragLoadingMaxRetry: 6,
                            fragLoadingRetryDelay: 500,
                            
                            startLevel: -1,
                            capLevelToPlayerSize: false,
                            abrEwmaDefaultEstimate: 500000
                        });
                        
                        setupEvents();
                        hls.loadSource(streamUrl);
                        hls.attachMedia(video);
                        
                    } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
                        log('Using native HLS...');
                        video.src = streamUrl;
                        setupNativeEvents();
                        video.load();
                    } else {
                        log('HLS not supported', 'error');
                    }
                }
                
                function setupEvents() {
                    hls.on(Hls.Events.MANIFEST_PARSED, (e, data) => {
                        log('Stream ready');
                        video.play()
                            .then(() => {
                                playing = true;
                                retries = 0;
                                live.classList.add('active');
                                hideLoader();
                                log('Playing');
                            })
                            .catch(err => log('Play failed: ' + err.message, 'error'));
                    });
                    
                    hls.on(Hls.Events.FRAG_LOADED, () => {
                        hideLoader();
                        
                        // Keep at live edge for LL-HLS
                        if (video.duration && isFinite(video.duration)) {
                            const lag = video.duration - video.currentTime;
                            if (lag > 4) {
                                log('Syncing to live...');
                                video.currentTime = video.duration - 0.5;
                            }
                        }
                    });
                    
                    hls.on(Hls.Events.ERROR, (e, data) => {
                        if (data.fatal) {
                            live.classList.remove('active');
                            handleError(data);
                        } else if (data.details === 'bufferStalledError') {
                            log('Stalled, syncing...', 'warning');
                            if (video.duration) {
                                video.currentTime = Math.max(0, video.duration - 1);
                            }
                        }
                    });
                }
                
                function handleError(data) {
                    console.error('Fatal error:', data);
                    
                    if (retries >= maxRetries) {
                        log('Max retries reached', 'error');
                        return;
                    }
                    
                    retries++;
                    
                    switch(data.type) {
                        case Hls.ErrorTypes.NETWORK_ERROR:
                            log(`Network error, retry ${retries}/${maxRetries}...`, 'warning');
                            showLoader();
                            setTimeout(() => hls.startLoad(), 1000 * retries);
                            break;
                            
                        case Hls.ErrorTypes.MEDIA_ERROR:
                            log('Media error, recovering...', 'warning');
                            hls.recoverMediaError();
                            showLoader();
                            break;
                            
                        default:
                            log('Fatal error: ' + data.details, 'error');
                            setTimeout(() => {
                                cleanup();
                                retries = 0;
                                init();
                            }, 3000);
                            break;
                    }
                }
                
                function setupNativeEvents() {
                    video.addEventListener('loadedmetadata', () => {
                        log('Stream ready (native)');
                        video.play()
                            .then(() => {
                                playing = true;
                                live.classList.add('active');
                                hideLoader();
                                log('Playing (native)');
                            })
                            .catch(err => log('Play failed: ' + err.message, 'error'));
                    });
                    
                    video.addEventListener('error', () => {
                        const err = video.error;
                        log('Error: ' + (err ? err.code : 'unknown'), 'error');
                        live.classList.remove('active');
                    });
                }
                
                // Common video events
                video.addEventListener('playing', () => {
                    log('Playing');
                    playing = true;
                    live.classList.add('active');
                    hideLoader();
                });
                
                video.addEventListener('waiting', () => {
                    showLoader();
                });
                
                video.addEventListener('pause', () => {
                    if (playing) {
                        video.play().catch(() => {});
                    }
                });
                
                video.addEventListener('stalled', () => {
                    log('Stalled', 'warning');
                    showLoader();
                    if (hls) hls.startLoad();
                });
                
                // Monitor buffer health
                setInterval(() => {
                    if (hls && playing && video.buffered.length > 0) {
                        const buffered = video.buffered.end(0) - video.currentTime;
                        if (buffered < 0.5) {
                            log('Low buffer: ' + buffered.toFixed(2) + 's', 'warning');
                        }
                    }
                }, 3000);
                
                function cleanup() {
                    if (hls) {
                        hls.destroy();
                        hls = null;
                    }
                    video.src = '';
                    playing = false;
                }
                
                document.addEventListener('visibilitychange', () => {
                    if (!document.hidden && !playing) {
                        video.play().catch(() => {});
                    }
                });
                
                window.addEventListener('beforeunload', cleanup);
                window.addEventListener('pagehide', cleanup);
                
                // Start
                init();
                
            })();
            </script>
        </body>
        </html>
        """
        
        webView.loadHTMLString(html, baseURL: URL(string: baseURL))
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: LowLatencyHLSPlayer
        
        init(_ parent: LowLatencyHLSPlayer) {
            self.parent = parent
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "logger",
               let dict = message.body as? [String: Any],
               let cameraId = dict["cameraId"] as? String,
               let status = dict["status"] as? String {
                
                let level = dict["level"] as? String ?? "info"
                let streamURL = dict["streamURL"] as? String
                let error = level == "error" ? status : nil
                
                DebugLogger.shared.updateCameraStatus(
                    cameraId: cameraId,
                    status: status,
                    streamURL: streamURL,
                    error: error
                )
            }
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("✅ LL-HLS player loaded: \(parent.cameraId)")
            webView.configuration.userContentController.add(self, name: "logger")
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