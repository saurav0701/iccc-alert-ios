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
        print("📹 Registered WebRTC player for: \(cameraId)")
    }
    
    private func releasePlayerInternal(_ cameraId: String) {
        if let webView = activePlayers.removeValue(forKey: cameraId) {
            webView.stopLoading()
            webView.loadHTMLString("", baseURL: nil)
            print("🗑️ Released WebRTC player: \(cameraId)")
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
        print("🧹 Cleared all WebRTC players")
    }
}

// MARK: - WebRTC Player
struct WebRTCPlayer: View {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    
    var body: some View {
        WebRTCPlayerView(
            streamURL: streamURL,
            cameraId: cameraId,
            isFullscreen: isFullscreen
        )
    }
}

// MARK: - WebRTC Player View
struct WebRTCPlayerView: UIViewRepresentable {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        
        // Enable WebRTC
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.backgroundColor = .black
        webView.isOpaque = true
        webView.navigationDelegate = context.coordinator
        
        // Allow camera/mic permissions (needed for WebRTC)
        webView.configuration.userContentController.add(context.coordinator, name: "logging")
        
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
                #status.warning { color: #FFC107; }
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
                ></video>
                <div id="live"><span class="dot"></span>LIVE</div>
                <div id="status">Connecting...</div>
            </div>
            
            <script>
            (function() {
                'use strict';
                
                const video = document.getElementById('video');
                const status = document.getElementById('status');
                const live = document.getElementById('live');
                const streamUrl = '\(streamURL)';
                
                let pc = null;
                let restartTimeout = null;
                
                function log(msg, type = 'info') {
                    console.log('[WebRTC]', msg);
                    status.textContent = msg;
                    status.className = type === 'error' ? 'error' : type === 'warning' ? 'warning' : '';
                    
                    // Send to Swift
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.logging) {
                        window.webkit.messageHandlers.logging.postMessage(msg);
                    }
                }
                
                function cleanup() {
                    if (restartTimeout) {
                        clearTimeout(restartTimeout);
                        restartTimeout = null;
                    }
                    
                    if (pc) {
                        pc.close();
                        pc = null;
                    }
                    
                    live.classList.remove('show');
                }
                
                async function start() {
                    cleanup();
                    
                    log('Creating peer connection...');
                    
                    pc = new RTCPeerConnection({
                        iceServers: [{
                            urls: 'stun:stun.l.google.com:19302'
                        }]
                    });
                    
                    pc.ontrack = (evt) => {
                        log('Received track');
                        video.srcObject = evt.streams[0];
                    };
                    
                    pc.oniceconnectionstatechange = () => {
                        log('ICE state: ' + pc.iceConnectionState, 'info');
                        
                        if (pc.iceConnectionState === 'connected') {
                            log('Connected');
                            live.classList.add('show');
                        } else if (pc.iceConnectionState === 'disconnected' || 
                                   pc.iceConnectionState === 'failed') {
                            log('Connection lost - reconnecting...', 'warning');
                            live.classList.remove('show');
                            restartTimeout = setTimeout(start, 2000);
                        }
                    };
                    
                    try {
                        // Add transceiver for receiving video
                        pc.addTransceiver('video', { direction: 'recvonly' });
                        pc.addTransceiver('audio', { direction: 'recvonly' });
                        
                        log('Creating offer...');
                        const offer = await pc.createOffer();
                        await pc.setLocalDescription(offer);
                        
                        log('Sending offer to server...');
                        const response = await fetch(streamUrl, {
                            method: 'POST',
                            headers: {
                                'Content-Type': 'application/sdp'
                            },
                            body: offer.sdp
                        });
                        
                        if (!response.ok) {
                            throw new Error('Server returned ' + response.status);
                        }
                        
                        const answer = await response.text();
                        
                        log('Received answer, setting remote description...');
                        await pc.setRemoteDescription({
                            type: 'answer',
                            sdp: answer
                        });
                        
                        log('WebRTC negotiation complete');
                        
                    } catch (err) {
                        log('Error: ' + err.message, 'error');
                        restartTimeout = setTimeout(start, 5000);
                    }
                }
                
                // Auto-play when video can play
                video.addEventListener('loadedmetadata', () => {
                    log('Stream ready');
                    video.play().catch(e => {
                        log('Play error: ' + e.message, 'warning');
                    });
                });
                
                video.addEventListener('playing', () => {
                    log('Playing');
                    live.classList.add('show');
                });
                
                video.addEventListener('pause', () => {
                    log('Paused');
                    // Auto-resume
                    setTimeout(() => {
                        if (!video.ended) {
                            video.play().catch(() => {});
                        }
                    }, 100);
                });
                
                // Cleanup on page unload
                window.addEventListener('beforeunload', () => {
                    cleanup();
                    video.srcObject = null;
                });
                
                // Visibility handling
                document.addEventListener('visibilitychange', () => {
                    if (!document.hidden && video.paused && !video.ended) {
                        video.play().catch(() => {});
                    }
                });
                
                // Start WebRTC
                start();
                
            })();
            </script>
        </body>
        </html>
        """
        
        webView.loadHTMLString(html, baseURL: nil)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: WebRTCPlayerView
        
        init(_ parent: WebRTCPlayerView) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("✅ WebRTC player loaded: \(parent.cameraId)")
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("❌ WebView failed: \(error.localizedDescription)")
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "logging", let msg = message.body as? String {
                print("🌐 WebRTC: \(msg)")
            }
        }
    }
}

// MARK: - Update Camera Model to use WebRTC
extension Camera {
    // WebRTC stream URL
    var webrtcStreamURL: String? {
        return getWebRTCStreamURL(for: groupId, cameraIp: ip, cameraId: id)
    }
    
    private func getWebRTCStreamURL(for groupId: Int, cameraIp: String, cameraId: String) -> String? {
        let serverURLs: [Int: String] = [
            5: "http://103.208.173.131:8889",
            6: "http://103.208.173.147:8889",
            7: "http://103.208.173.163:8889",
            8: "http://a5va.bccliccc.in:8889",
            9: "http://a5va.bccliccc.in:8889",
            10: "http://a6va.bccliccc.in:8889",
            11: "http://103.208.173.195:8889",
            12: "http://a9va.bccliccc.in:8889",
            13: "http://a10va.bccliccc.in:8889",
            14: "http://103.210.88.195:8889",
            15: "http://103.210.88.211:8889",
            16: "http://103.208.173.179:8889",
            22: "http://103.208.173.211:8889"
        ]
        
        guard let serverURL = serverURLs[groupId] else {
            print("❌ No WebRTC server URL for groupId: \(groupId)")
            return nil
        }
        
        // Use camera IP as stream path
        if !cameraIp.isEmpty {
            let url = "\(serverURL)/\(cameraIp)/whep"
            print("✅ WebRTC URL: \(url)")
            return url
        }
        
        // Fallback to camera ID
        let fallbackUrl = "\(serverURL)/\(cameraId)/whep"
        print("⚠️ WebRTC URL (ID-based fallback): \(fallbackUrl)")
        return fallbackUrl
    }
}

// MARK: - Camera Thumbnail (Updated)
struct CameraThumbnail: View {
    let camera: Camera
    @State private var shouldLoad = false
    
    var body: some View {
        ZStack {
            if let streamURL = camera.webrtcStreamURL, camera.isOnline {
                if shouldLoad {
                    WebRTCPlayer(
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

// MARK: - Fullscreen Player (Updated)
struct HLSPlayerView: View {
    let camera: Camera
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let streamURL = camera.webrtcStreamURL {
                WebRTCPlayer(
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