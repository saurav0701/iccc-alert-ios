import SwiftUI
import WebKit
import Combine

// MARK: - WebRTC Player View (Proper RTCPeerConnection)
struct WebRTCPlayerView: UIViewControllerRepresentable {
    let streamURL: URL
    let cameraId: String
    let onError: ((Error) -> Void)?
    
    func makeUIViewController(context: Context) -> WKWebViewController {
        let controller = WKWebViewController(
            streamURL: streamURL.absoluteString,
            cameraId: cameraId
        )
        controller.onError = onError
        return controller
    }
    
    func updateUIViewController(_ uiViewController: WKWebViewController, context: Context) {}
    
    static func dismantleUIViewController(_ uiViewController: WKWebViewController, coordinator: ()) {
        uiViewController.cleanup()
    }
}

// MARK: - WebRTC WebKit Controller
class WKWebViewController: UIViewController {
    private var webView: WKWebView!
    private let streamURL: String
    private let cameraId: String
    var onError: ((Error) -> Void)?
    
    init(streamURL: String, cameraId: String) {
        self.streamURL = streamURL
        self.cameraId = cameraId
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .black
        
        // Create WebKit configuration
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        config.websiteDataStore = .nonPersistent()
        
        // Memory optimization
        config.processPool = WKProcessPool()
        config.suppressesIncrementalRendering = true
        
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        
        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.backgroundColor = .black
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = true
        view.addSubview(webView)
        
        // Load WebRTC page
        loadWebRTCPage()
    }
    
    private func loadWebRTCPage() {
        let htmlContent = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>WebRTC Stream</title>
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                html, body { width: 100%; height: 100%; overflow: hidden; background: #000; }
                #videoContainer { width: 100%; height: 100%; display: flex; align-items: center; justify-content: center; background: #000; }
                video { width: 100%; height: 100%; object-fit: contain; background-color: #000; }
                #status { position: absolute; top: 10px; left: 10px; color: white; font-size: 12px; background-color: rgba(0, 0, 0, 0.8); padding: 8px; border-radius: 4px; font-family: -apple-system; }
                #error { position: absolute; top: 10px; right: 10px; color: #ff5252; font-size: 12px; background-color: rgba(0, 0, 0, 0.9); padding: 8px; border-radius: 4px; font-family: -apple-system; max-width: 300px; }
                #live { position: absolute; top: 10px; right: 10px; background: rgba(244,67,54,0.9); color: white; padding: 4px 8px; border-radius: 4px; font-weight: 700; font-size: 10px; display: none; align-items: center; gap: 4px; font-family: -apple-system; }
                #live.show { display: flex; }
                .dot { width: 6px; height: 6px; background: white; border-radius: 50%; animation: pulse 1.5s ease-in-out infinite; }
                @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.3; } }
            </style>
        </head>
        <body>
            <div id="videoContainer">
                <video id="video" playsinline autoplay muted></video>
            </div>
            <div id="status">Connecting...</div>
            <div id="error"></div>
            <div id="live"><span class="dot"></span>LIVE</div>
            
            <script>
            (function() {
                const video = document.getElementById('video');
                const statusDiv = document.getElementById('status');
                const errorDiv = document.getElementById('error');
                const liveDiv = document.getElementById('live');
                const streamUrl = '\(streamURL)';
                
                let pc = null;
                let reconnectTimeout = null;
                let retryCount = 0;
                const MAX_RETRIES = 2;
                let isActive = true;
                
                // Global cleanup function
                window.cleanup = function() {
                    isActive = false;
                    if (reconnectTimeout) {
                        clearTimeout(reconnectTimeout);
                        reconnectTimeout = null;
                    }
                    if (pc) {
                        try { pc.close(); } catch(e) {}
                        pc = null;
                    }
                    if (video.srcObject) {
                        try {
                            video.srcObject.getTracks().forEach(t => {
                                try { t.stop(); } catch(e) {}
                            });
                            video.srcObject = null;
                        } catch(e) {}
                    }
                    video.pause();
                    video.src = '';
                    video.load();
                    liveDiv.classList.remove('show');
                };
                
                function log(msg, isError = false) {
                    if (!isActive) return;
                    if (isError) {
                        errorDiv.textContent = msg;
                        errorDiv.style.display = 'block';
                        statusDiv.textContent = msg;
                    } else {
                        statusDiv.textContent = msg;
                        errorDiv.style.display = 'none';
                    }
                    console.log('[WebRTC] ' + msg);
                }
                
                async function startConnection() {
                    if (!isActive || retryCount >= MAX_RETRIES) {
                        if (retryCount >= MAX_RETRIES) {
                            log('Max retries reached', true);
                        }
                        return;
                    }
                    
                    if (pc) {
                        try { pc.close(); } catch(e) {}
                        pc = null;
                    }
                    
                    log('Connecting...');
                    liveDiv.classList.remove('show');
                    
                    try {
                        pc = new RTCPeerConnection({
                            iceServers: [{ urls: 'stun:stun.l.google.com:19302' }],
                            bundlePolicy: 'max-bundle',
                            rtcpMuxPolicy: 'require'
                        });
                        
                        pc.ontrack = (e) => {
                            if (isActive) {
                                log('Stream received');
                                video.srcObject = e.streams[0];
                                retryCount = 0;
                            }
                        };
                        
                        pc.oniceconnectionstatechange = () => {
                            if (!isActive) return;
                            const state = pc.iceConnectionState;
                            
                            if (state === 'connected' || state === 'completed') {
                                log('Connected');
                                liveDiv.classList.add('show');
                                retryCount = 0;
                            } else if (state === 'failed' || state === 'disconnected') {
                                log('Connection ' + state);
                                liveDiv.classList.remove('show');
                                
                                retryCount++;
                                if (isActive && retryCount < MAX_RETRIES) {
                                    log('Retry ' + retryCount + '/' + MAX_RETRIES);
                                    reconnectTimeout = setTimeout(startConnection, 3000);
                                } else if (retryCount >= MAX_RETRIES) {
                                    log('Failed - max retries', true);
                                }
                            }
                        };
                        
                        pc.addTransceiver('video', { direction: 'recvonly' });
                        pc.addTransceiver('audio', { direction: 'recvonly' });
                        
                        const offer = await pc.createOffer();
                        await pc.setLocalDescription(offer);
                        
                        const controller = new AbortController();
                        const timeoutId = setTimeout(() => controller.abort(), 10000);
                        
                        const res = await fetch(streamUrl, {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/sdp' },
                            body: offer.sdp,
                            signal: controller.signal
                        });
                        
                        clearTimeout(timeoutId);
                        
                        if (!res.ok) {
                            throw new Error('Server error: ' + res.status);
                        }
                        
                        const answer = await res.text();
                        if (isActive && pc) {
                            await pc.setRemoteDescription({ type: 'answer', sdp: answer });
                        }
                        
                    } catch (err) {
                        log('Error: ' + err.message, true);
                        retryCount++;
                        if (isActive && retryCount < MAX_RETRIES) {
                            log('Retry ' + retryCount + '/' + MAX_RETRIES);
                            reconnectTimeout = setTimeout(startConnection, 5000);
                        } else {
                            log('Failed: ' + err.message, true);
                        }
                    }
                }
                
                video.addEventListener('playing', () => {
                    if (isActive) {
                        log('Playing');
                        liveDiv.classList.add('show');
                    }
                });
                
                video.addEventListener('error', (e) => {
                    log('Video playback error', true);
                });
                
                video.addEventListener('pause', () => {
                    if (isActive && pc && (pc.iceConnectionState === 'failed' || pc.iceConnectionState === 'disconnected')) {
                        log('Stream lost, reconnecting...');
                    }
                });
                
                window.addEventListener('beforeunload', window.cleanup);
                window.addEventListener('pagehide', window.cleanup);
                
                // Start initial connection
                startConnection();
                
            })();
            </script>
        </body>
        </html>
        """
        
        webView.loadHTMLString(htmlContent, baseURL: nil)
    }
    
    func cleanup() {
        webView.stopLoading()
        webView.evaluateJavaScript("window.cleanup();") { _, _ in }
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }
    
    deinit {
        cleanup()
    }
}

