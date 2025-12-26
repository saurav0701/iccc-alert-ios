import SwiftUI
import WebKit

// MARK: - Enhanced Stable WebView HLS Player
struct WebViewHLSPlayer: UIViewRepresentable {
    let streamURL: String
    let cameraName: String
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    let isFullscreen: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = false
        
        // Enable optimizations
        configuration.preferences.javaScriptEnabled = true
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        
        // Add message handlers
        webView.configuration.userContentController.add(context.coordinator, name: "streamReady")
        webView.configuration.userContentController.add(context.coordinator, name: "streamError")
        webView.configuration.userContentController.add(context.coordinator, name: "streamLog")
        
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        // Only load if URL changed or not loaded yet
        if context.coordinator.lastLoadedURL != streamURL {
            context.coordinator.lastLoadedURL = streamURL
            let html = generateHTML()
            webView.loadHTMLString(html, baseURL: nil)
        }
    }
    
    private func generateHTML() -> String {
        // For thumbnail view, we want autoplay but muted
        // For fullscreen, we want controls and sound
        let autoplayAttr = "autoplay"
        let mutedAttr = isFullscreen ? "" : "muted"
        let controlsAttr = isFullscreen ? "controls" : ""
        let playsinlineAttr = "playsinline"
        let preloadAttr = "preload=\"auto\""
        
        // Shorter timeout for fullscreen (better responsiveness)
        let manifestTimeout = isFullscreen ? "8000" : "15000"
        let fragTimeout = isFullscreen ? "15000" : "30000"
        
        return """
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
                body { 
                    background: #000;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    height: 100vh;
                    width: 100vw;
                    overflow: hidden;
                    position: fixed;
                }
                #player {
                    width: 100%;
                    height: 100%;
                    object-fit: contain;
                    background: #000;
                }
            </style>
        </head>
        <body>
            <video id="player" \(autoplayAttr) \(playsinlineAttr) \(mutedAttr) \(controlsAttr) \(preloadAttr)></video>
            <script src="https://cdn.jsdelivr.net/npm/hls.js@1.5.13/dist/hls.min.js"></script>
            <script>
                const video = document.getElementById('player');
                const videoSrc = '\(streamURL)';
                const isFullscreen = \(isFullscreen ? "true" : "false");
                
                let hls = null;
                let retryCount = 0;
                const maxRetries = 5;
                let isDestroyed = false;
                let playbackStallTimer = null;
                let lastPlaybackTime = 0;
                let stallCheckCount = 0;
                
                function log(msg) {
                    console.log(msg);
                    try {
                        window.webkit.messageHandlers.streamLog.postMessage(msg);
                    } catch(e) {}
                }
                
                function cleanup() {
                    if (playbackStallTimer) clearInterval(playbackStallTimer);
                    if (hls) {
                        log('🧹 Cleaning up HLS instance');
                        try {
                            hls.destroy();
                        } catch(e) {
                            log('⚠️ Error destroying HLS: ' + e.message);
                        }
                        hls = null;
                    }
                }
                
                function startStallDetection() {
                    if (playbackStallTimer) clearInterval(playbackStallTimer);
                    
                    // More aggressive stall detection in fullscreen
                    const checkInterval = isFullscreen ? 5000 : 10000;
                    
                    playbackStallTimer = setInterval(() => {
                        if (isDestroyed || !video || video.paused) return;
                        
                        const currentTime = video.currentTime;
                        
                        // If playback hasn't progressed
                        if (currentTime > 0 && currentTime === lastPlaybackTime) {
                            stallCheckCount++;
                            
                            // If stalled for 2 consecutive checks (10 seconds), recover
                            if (stallCheckCount >= 2) {
                                log('⚠️ PLAYBACK STALLED! Attempting recovery...');
                                
                                if (hls) {
                                    // Try to recover by reloading
                                    hls.stopLoad();
                                    setTimeout(() => {
                                        if (hls && !isDestroyed) {
                                            hls.startLoad(-1);
                                            video.play().catch(e => log('Stall recovery play failed: ' + e.message));
                                        }
                                    }, 500);
                                }
                                
                                stallCheckCount = 0;
                            }
                        } else {
                            stallCheckCount = 0;
                        }
                        
                        lastPlaybackTime = currentTime;
                    }, checkInterval);
                }
                
                function initPlayer() {
                    if (isDestroyed) return;
                    
                    cleanup();
                    
                    log('🎬 Initializing player: ' + videoSrc + ' (fullscreen=' + isFullscreen + ')');
                    
                    if (Hls.isSupported()) {
                        log('✅ HLS.js is supported');
                        
                        hls = new Hls({
                            debug: false,
                            enableWorker: true,
                            lowLatencyMode: false,
                            backBufferLength: 90,
                            maxBufferLength: isFullscreen ? 40 : 20,
                            maxMaxBufferLength: isFullscreen ? 80 : 40,
                            maxBufferSize: 80 * 1000 * 1000,
                            maxBufferHole: 0.5,
                            highBufferWatchdogPeriod: 3,
                            nudgeOffset: 0.1,
                            nudgeMaxRetry: 10,
                            maxFragLookUpTolerance: 0.25,
                            liveSyncDurationCount: 3,
                            liveMaxLatencyDurationCount: isFullscreen ? 15 : 5,
                            liveDurationInfinity: false,
                            startLevel: -1,
                            autoStartLoad: true,
                            capLevelToPlayerSize: !isFullscreen,
                            manifestLoadingTimeOut: parseInt('\(manifestTimeout)'),
                            manifestLoadingMaxRetry: 6,
                            manifestLoadingRetryDelay: 1000,
                            levelLoadingTimeOut: parseInt('\(manifestTimeout)'),
                            levelLoadingMaxRetry: 6,
                            levelLoadingRetryDelay: 1000,
                            fragLoadingTimeOut: parseInt('\(fragTimeout)'),
                            fragLoadingMaxRetry: 10,
                            fragLoadingRetryDelay: 1000,
                            startFragPrefetch: true,
                            testBandwidth: true,
                        });
                        
                        hls.on(Hls.Events.MEDIA_ATTACHED, function() {
                            log('📎 Media attached');
                        });
                        
                        hls.on(Hls.Events.MANIFEST_PARSED, function(event, data) {
                            log('✅ Manifest parsed, levels: ' + data.levels.length);
                            
                            // Start stall detection
                            startStallDetection();
                            
                            // Try to play
                            video.play()
                                .then(() => {
                                    log('▶️ Video playing successfully');
                                    window.webkit.messageHandlers.streamReady.postMessage('ready');
                                    retryCount = 0;
                                })
                                .catch(e => {
                                    log('⚠️ Play error: ' + e.message);
                                    if (retryCount < maxRetries) {
                                        retryCount++;
                                        setTimeout(() => {
                                            video.play().catch(err => log('Retry play failed: ' + err.message));
                                        }, 1500);
                                    } else {
                                        window.webkit.messageHandlers.streamError.postMessage('Failed to start playback: ' + e.message);
                                    }
                                });
                        });
                        
                        hls.on(Hls.Events.ERROR, function(event, data) {
                            log('❌ HLS Error: ' + data.type + ' - ' + data.details + (data.fatal ? ' [FATAL]' : ''));
                            
                            if (data.fatal) {
                                switch(data.type) {
                                    case Hls.ErrorTypes.NETWORK_ERROR:
                                        log('🔴 Fatal network error, attempting recovery...');
                                        if (retryCount < maxRetries) {
                                            retryCount++;
                                            const delay = Math.min(1000 * retryCount, 5000);
                                            log('🔄 Retrying in ' + delay + 'ms (attempt ' + retryCount + '/' + maxRetries + ')');
                                            setTimeout(() => {
                                                if (hls && !isDestroyed) {
                                                    try {
                                                        hls.startLoad(-1);
                                                        video.play().catch(e => log('Recovery play failed: ' + e.message));
                                                    } catch(e) {
                                                        log('startLoad failed: ' + e.message);
                                                    }
                                                }
                                            }, delay);
                                        } else {
                                            log('❌ Max retries reached for network error');
                                            window.webkit.messageHandlers.streamError.postMessage('Network error: ' + data.details);
                                        }
                                        break;
                                        
                                    case Hls.ErrorTypes.MEDIA_ERROR:
                                        log('🔴 Fatal media error, attempting recovery...');
                                        if (retryCount < maxRetries) {
                                            retryCount++;
                                            if (hls && !isDestroyed) {
                                                try {
                                                    hls.recoverMediaError();
                                                    setTimeout(() => {
                                                        video.play().catch(e => log('Media recovery play failed: ' + e.message));
                                                    }, 500);
                                                } catch(e) {
                                                    log('recoverMediaError failed: ' + e.message);
                                                }
                                            }
                                        } else {
                                            log('❌ Max retries reached for media error');
                                            window.webkit.messageHandlers.streamError.postMessage('Media error: ' + data.details);
                                        }
                                        break;
                                        
                                    default:
                                        log('❌ Fatal error, cannot recover: ' + data.details);
                                        window.webkit.messageHandlers.streamError.postMessage('Fatal error: ' + data.details);
                                        break;
                                }
                            } else {
                                // Non-fatal errors - just log them
                                if (isFullscreen) {
                                    log('⚠️ Non-fatal error: ' + data.details);
                                }
                            }
                        });
                        
                        hls.on(Hls.Events.FRAG_LOADED, function(event, data) {
                            if (isFullscreen) {
                                log('📦 Fragment #' + data.frag.sn + ' loaded');
                            }
                        });
                        
                        hls.on(Hls.Events.BUFFER_APPENDED, function() {
                            if (isFullscreen) {
                                log('✅ Buffer appended');
                            }
                        });
                        
                        hls.on(Hls.Events.BUFFER_EOS, function() {
                            log('⚠️ Buffer End Of Stream');
                        });
                        
                        // Load and attach
                        hls.loadSource(videoSrc);
                        hls.attachMedia(video);
                        
                    } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
                        // Native HLS support (Safari)
                        log('🍎 Using native HLS support');
                        
                        video.src = videoSrc;
                        
                        video.addEventListener('loadedmetadata', function() {
                            log('✅ Native HLS: metadata loaded');
                            video.play()
                                .then(() => {
                                    log('▶️ Native HLS: playing');
                                    window.webkit.messageHandlers.streamReady.postMessage('ready');
                                })
                                .catch(e => {
                                    log('❌ Native HLS play error: ' + e.message);
                                    window.webkit.messageHandlers.streamError.postMessage('Playback error: ' + e.message);
                                });
                        });
                        
                        video.addEventListener('error', function(e) {
                            log('❌ Native HLS error: ' + (video.error ? video.error.message : 'unknown'));
                            window.webkit.messageHandlers.streamError.postMessage('Native playback error');
                        });
                        
                        video.load();
                    } else {
                        log('❌ HLS not supported on this device');
                        window.webkit.messageHandlers.streamError.postMessage('HLS not supported');
                    }
                }
                
                // Handle video events
                video.addEventListener('waiting', function() {
                    log('⏳ Video is buffering...');
                });
                
                video.addEventListener('playing', function() {
                    log('▶️ Video is playing');
                    lastPlaybackTime = video.currentTime;
                });
                
                video.addEventListener('pause', function() {
                    log('⏸️ Video paused');
                });
                
                video.addEventListener('ended', function() {
                    log('🏁 Video ended');
                });
                
                video.addEventListener('stalled', function() {
                    log('⚠️ Video stalled - network issue');
                    
                    // Try to recover from stall
                    if (hls && !isDestroyed) {
                        setTimeout(() => {
                            log('🔄 Attempting stall recovery...');
                            hls.stopLoad();
                            setTimeout(() => {
                                if (hls && !isDestroyed) {
                                    hls.startLoad(-1);
                                }
                            }, 500);
                        }, 2000);
                    }
                });
                
                video.addEventListener('error', function() {
                    if (video.error) {
                        const errorCodes = ['', 'ABORTED', 'NETWORK', 'DECODE', 'SRC_NOT_SUPPORTED'];
                        const errorCode = errorCodes[video.error.code] || 'UNKNOWN';
                        log('❌ Video element error: ' + errorCode + ' - ' + video.error.message);
                    }
                });
                
                video.addEventListener('canplay', function() {
                    log('✅ Video can start playing');
                });
                
                video.addEventListener('loadeddata', function() {
                    log('📊 Video data loaded');
                });
                
                // Start player
                initPlayer();
                
                // Keep stream alive - aggressive recovery for fullscreen
                const keepAliveInterval = isFullscreen ? 2000 : 5000;
                let keepAlive = setInterval(() => {
                    if (isDestroyed) {
                        clearInterval(keepAlive);
                        return;
                    }
                    
                    // Check if video is paused unexpectedly
                    if (video.paused && !video.ended && video.readyState >= 2) {
                        log('⚠️ Video paused unexpectedly, resuming...');
                        video.play().catch(e => log('Resume play failed: ' + e.message));
                    }
                    
                    // Check if we're stuck buffering
                    if (video.readyState < 3 && !video.paused) {
                        log('⚠️ Video stuck in buffering state');
                    }
                }, keepAliveInterval);
                
                // Handle visibility changes
                document.addEventListener('visibilitychange', function() {
                    if (document.hidden) {
                        log('📱 Page hidden');
                        if (!isFullscreen && hls) {
                            hls.stopLoad();
                        }
                    } else {
                        log('📱 Page visible');
                        if (hls && !isDestroyed) {
                            setTimeout(() => {
                                if (hls) {
                                    hls.startLoad(-1);
                                    video.play().catch(e => log('Resume after visibility failed: ' + e.message));
                                }
                            }, 500);
                        }
                    }
                });
                
                // Cleanup on unload
                window.addEventListener('beforeunload', function() {
                    log('🧹 Cleaning up before unload');
                    isDestroyed = true;
                    if (playbackStallTimer) clearInterval(playbackStallTimer);
                    if (keepAlive) clearInterval(keepAlive);
                    cleanup();
                });
            </script>
        </body>
        </html>
        """
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: WebViewHLSPlayer
        var lastLoadedURL: String = ""
        
        init(_ parent: WebViewHLSPlayer) {
            self.parent = parent
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            DispatchQueue.main.async {
                switch message.name {
                case "streamReady":
                    print("✅ Stream ready: \(self.parent.cameraName)")
                    self.parent.isLoading = false
                    self.parent.errorMessage = nil
                    
                case "streamError":
                    let error = message.body as? String ?? "Stream error"
                    print("❌ Stream error for \(self.parent.cameraName): \(error)")
                    self.parent.isLoading = false
                    self.parent.errorMessage = error
                    
                case "streamLog":
                    if let log = message.body as? String {
                        if self.parent.isFullscreen {
                            print("📹 [\(self.parent.cameraName)] \(log)")
                        }
                    }
                    
                default:
                    break
                }
            }
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("📄 WebView loaded for: \(parent.cameraName)")
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("❌ WebView navigation failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.parent.errorMessage = "Navigation failed: \(error.localizedDescription)"
                self.parent.isLoading = false
            }
        }
    }
}