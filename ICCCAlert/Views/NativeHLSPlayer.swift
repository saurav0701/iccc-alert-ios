import SwiftUI
import WebKit

// MARK: - Enhanced WebView Player with hls.js
struct EnhancedWebViewPlayer: UIViewRepresentable {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        
        // Enable hardware acceleration
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        
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
        // Using latest hls.js for better fMP4 support
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
                    top: 10px; 
                    right: 10px;
                    background: rgba(0,0,0,0.8); 
                    color: #4CAF50;
                    padding: 6px 12px; 
                    font-size: 11px; 
                    border-radius: 6px;
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    font-weight: 600;
                    z-index: 10;
                    display: flex;
                    align-items: center;
                    gap: 6px;
                }
                .status-dot {
                    width: 8px;
                    height: 8px;
                    border-radius: 50%;
                    background: #4CAF50;
                    animation: pulse 2s infinite;
                }
                @keyframes pulse {
                    0%, 100% { opacity: 1; }
                    50% { opacity: 0.5; }
                }
                #error {
                    position: absolute;
                    top: 50%;
                    left: 50%;
                    transform: translate(-50%, -50%);
                    background: rgba(0,0,0,0.9);
                    color: #ff6b6b;
                    padding: 20px;
                    border-radius: 12px;
                    text-align: center;
                    display: none;
                    max-width: 80%;
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
                <div id="error"></div>
            </div>
            
            <script>
                (function() {
                    'use strict';
                    
                    const video = document.getElementById('video');
                    const status = document.getElementById('status');
                    const errorDiv = document.getElementById('error');
                    const streamUrl = '\(streamURL)';
                    
                    let hls;
                    let retryCount = 0;
                    const maxRetries = 3;
                    
                    function updateStatus(text, isError = false) {
                        const dot = status.querySelector('.status-dot');
                        const span = status.querySelector('span');
                        
                        span.textContent = text;
                        
                        if (isError) {
                            status.style.background = 'rgba(255, 107, 107, 0.9)';
                            dot.style.background = '#ff6b6b';
                        } else {
                            status.style.background = 'rgba(0,0,0,0.8)';
                            dot.style.background = '#4CAF50';
                        }
                    }
                    
                    function showError(message) {
                        errorDiv.textContent = message;
                        errorDiv.style.display = 'block';
                        updateStatus('Error', true);
                    }
                    
                    function hideError() {
                        errorDiv.style.display = 'none';
                    }
                    
                    function initPlayer() {
                        if (Hls.isSupported()) {
                            hls = new Hls({
                                debug: false,
                                enableWorker: true,
                                lowLatencyMode: true,
                                backBufferLength: 30,
                                maxBufferLength: 30,
                                maxMaxBufferLength: 60,
                                maxBufferSize: 60 * 1000 * 1000,
                                maxBufferHole: 0.5,
                                highBufferWatchdogPeriod: 2,
                                nudgeOffset: 0.1,
                                nudgeMaxRetry: 3,
                                maxFragLookUpTolerance: 0.25,
                                liveSyncDurationCount: 3,
                                liveMaxLatencyDurationCount: 10,
                                liveDurationInfinity: false,
                                enableSoftwareAES: true,
                                manifestLoadingTimeOut: 10000,
                                manifestLoadingMaxRetry: 3,
                                manifestLoadingRetryDelay: 1000,
                                levelLoadingTimeOut: 10000,
                                levelLoadingMaxRetry: 4,
                                fragLoadingTimeOut: 20000,
                                fragLoadingMaxRetry: 6
                            });
                            
                            hls.loadSource(streamUrl);
                            hls.attachMedia(video);
                            
                            hls.on(Hls.Events.MANIFEST_PARSED, function() {
                                updateStatus('Playing');
                                hideError();
                                video.play().catch(e => {
                                    console.error('Play error:', e);
                                    updateStatus('Play failed', true);
                                });
                            });
                            
                            hls.on(Hls.Events.ERROR, function(event, data) {
                                console.error('HLS Error:', data.type, data.details);
                                
                                if (data.fatal) {
                                    switch(data.type) {
                                        case Hls.ErrorTypes.NETWORK_ERROR:
                                            updateStatus('Network error', true);
                                            if (retryCount < maxRetries) {
                                                retryCount++;
                                                setTimeout(() => {
                                                    updateStatus('Retrying...');
                                                    hls.startLoad();
                                                }, 1000 * retryCount);
                                            } else {
                                                showError('Network error - max retries reached');
                                            }
                                            break;
                                        case Hls.ErrorTypes.MEDIA_ERROR:
                                            updateStatus('Media error', true);
                                            hls.recoverMediaError();
                                            break;
                                        default:
                                            showError('Fatal error: ' + data.details);
                                            hls.destroy();
                                            break;
                                    }
                                }
                            });
                            
                            hls.on(Hls.Events.FRAG_LOADED, function() {
                                retryCount = 0; // Reset on success
                            });
                            
                        } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
                            // Fallback to native HLS
                            video.src = streamUrl;
                            video.addEventListener('loadedmetadata', function() {
                                updateStatus('Playing (Native)');
                                video.play();
                            });
                        } else {
                            showError('HLS not supported');
                        }
                    }
                    
                    video.addEventListener('playing', function() {
                        updateStatus('Live');
                        hideError();
                    });
                    
                    video.addEventListener('waiting', function() {
                        updateStatus('Buffering...');
                    });
                    
                    video.addEventListener('stalled', function() {
                        updateStatus('Stalled', true);
                    });
                    
                    video.addEventListener('error', function(e) {
                        const error = video.error;
                        if (error) {
                            showError('Video error: ' + error.code);
                        }
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
            print("❌ WebView failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Replace HybridHLSPlayer with WebView-first approach
struct OptimizedHLSPlayer: View {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    
    var body: some View {
        EnhancedWebViewPlayer(
            streamURL: streamURL,
            cameraId: cameraId,
            isFullscreen: isFullscreen
        )
    }
}

// Update CameraThumbnail to use new player
struct UpdatedCameraThumbnail: View {
    let camera: Camera
    @State private var shouldLoad = false
    
    var body: some View {
        ZStack {
            if let streamURL = camera.streamURL, camera.isOnline {
                if shouldLoad {
                    OptimizedHLSPlayer(
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