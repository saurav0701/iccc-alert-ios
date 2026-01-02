import SwiftUI
import WebKit
import Combine

// MARK: - Player Manager (ULTRA STRICT - ZERO TOLERANCE)
class PlayerManager: ObservableObject {
    static let shared = PlayerManager()
    
    private var activePlayers: [String: WKWebView] = [:]
    private let lock = NSLock()
    private let maxPlayers = 1 // ABSOLUTE MAXIMUM
    private var lastCleanupTime: Date?
    
    private init() {
        setupMemoryWarning()
        DebugLogger.shared.log("📹 PlayerManager initialized (MAX 1 STREAM)", emoji: "📹", color: .blue)
    }
    
    private func setupMemoryWarning() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DebugLogger.shared.log("⚠️ MEMORY WARNING - Stopping all players", emoji: "🧹", color: .red)
            self?.clearAll()
        }
    }
    
    func registerPlayer(_ webView: WKWebView, for cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        DebugLogger.shared.log("📹 Registering player: \(cameraId)", emoji: "📹", color: .blue)
        
        // CRITICAL: Force cleanup of ALL existing players first
        if !activePlayers.isEmpty {
            DebugLogger.shared.log("⚠️ Forcing cleanup of existing players", emoji: "⚠️", color: .orange)
            let allKeys = Array(activePlayers.keys)
            for key in allKeys {
                if let oldPlayer = activePlayers.removeValue(forKey: key) {
                    DispatchQueue.main.async {
                        self.cleanupWebView(oldPlayer)
                    }
                }
            }
            
            // Wait briefly for cleanup
            Thread.sleep(forTimeInterval: 0.5)
        }
        
        activePlayers[cameraId] = webView
        lastCleanupTime = Date()
        
        DebugLogger.shared.log("✅ Player registered: \(cameraId) (Active: \(activePlayers.count)/\(maxPlayers))", emoji: "✅", color: .green)
    }
    
    private func cleanupWebView(_ webView: WKWebView) {
        DebugLogger.shared.log("🧹 Cleaning up WebView", emoji: "🧹", color: .blue)
        
        // CRITICAL: Complete destruction sequence
        webView.stopLoading()
        webView.navigationDelegate = nil
        
        // Clear all content
        webView.loadHTMLString("", baseURL: nil)
        
        // Remove ALL handlers
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        
        // Remove from view hierarchy
        webView.removeFromSuperview()
        
        // Clear website data
        let dataStore = WKWebsiteDataStore.nonPersistent()
        dataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: Date(timeIntervalSince1970: 0),
            completionHandler: {
                DebugLogger.shared.log("🧹 Website data cleared", emoji: "🧹", color: .gray)
            }
        )
        
        DebugLogger.shared.log("✅ WebView cleanup complete", emoji: "✅", color: .green)
    }
    
    func releasePlayer(_ cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        if let webView = activePlayers.removeValue(forKey: cameraId) {
            DebugLogger.shared.log("🗑️ Releasing player: \(cameraId)", emoji: "🗑️", color: .orange)
            
            DispatchQueue.main.async {
                self.cleanupWebView(webView)
            }
            
            lastCleanupTime = Date()
        }
    }
    
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        
        if activePlayers.isEmpty {
            return
        }
        
        DebugLogger.shared.log("🧹 Clearing ALL players (\(activePlayers.count))", emoji: "🧹", color: .red)
        
        let allPlayers = activePlayers
        activePlayers.removeAll()
        
        DispatchQueue.main.async {
            allPlayers.forEach { self.cleanupWebView($0.value) }
        }
        
        lastCleanupTime = Date()
        
        DebugLogger.shared.log("✅ All players cleared", emoji: "✅", color: .green)
    }
    
    func getActiveCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return activePlayers.count
    }
    
    func canStartNewPlayer() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        // Check if we're at max capacity
        if activePlayers.count >= maxPlayers {
            DebugLogger.shared.log("⚠️ Cannot start new player - at max capacity", emoji: "⚠️", color: .orange)
            return false
        }
        
        // Check if cleanup happened recently (wait at least 2 seconds)
        if let lastCleanup = lastCleanupTime {
            let timeSinceCleanup = Date().timeIntervalSince(lastCleanup)
            if timeSinceCleanup < 2.0 {
                DebugLogger.shared.log("⚠️ Cannot start new player - too soon after cleanup (\(String(format: "%.1f", timeSinceCleanup))s)", emoji: "⚠️", color: .orange)
                return false
            }
        }
        
        return true
    }
}

// MARK: - WebRTC Player View (ULTRA SAFE)
struct WebRTCPlayerView: UIViewRepresentable {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        DebugLogger.shared.log("📹 Creating WebView for: \(cameraId)", emoji: "📹", color: .blue)
        
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
        
        webView.configuration.userContentController.add(context.coordinator, name: "logging")
        
        PlayerManager.shared.registerPlayer(webView, for: cameraId)
        context.coordinator.loadPlayer(in: webView, streamURL: streamURL)
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        DebugLogger.shared.log("🗑️ Dismantling WebView", emoji: "🗑️", color: .orange)
        coordinator.cleanup()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(cameraId: cameraId)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let cameraId: String
        private var retryCount = 0
        private let maxRetries = 2
        private var isActive = true
        
        init(cameraId: String) {
            self.cameraId = cameraId
        }
        
        func loadPlayer(in webView: WKWebView, streamURL: String) {
            let html = """
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
                <style>
                    * { margin: 0; padding: 0; box-sizing: border-box; }
                    html, body { width: 100%; height: 100%; overflow: hidden; background: #000; }
                    video { width: 100%; height: 100%; object-fit: contain; background: #000; }
                    #live { position: absolute; top: 10px; right: 10px; background: rgba(244,67,54,0.9);
                            color: white; padding: 4px 8px; border-radius: 4px; font: 700 10px -apple-system;
                            z-index: 10; display: none; align-items: center; gap: 4px; }
                    #live.show { display: flex; }
                    .dot { width: 6px; height: 6px; background: white; border-radius: 50%;
                           animation: pulse 1.5s ease-in-out infinite; }
                    @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.3; } }
                    #status { position: absolute; bottom: 10px; left: 10px; background: rgba(0,0,0,0.8);
                              color: #4CAF50; padding: 6px 10px; border-radius: 6px;
                              font: 11px -apple-system; z-index: 10; }
                    #status.error { color: #ff5252; }
                </style>
            </head>
            <body>
                <video id="video" playsinline autoplay muted></video>
                <div id="live"><span class="dot"></span>LIVE</div>
                <div id="status">Connecting...</div>
                <script>
                (function() {
                    const video = document.getElementById('video');
                    const status = document.getElementById('status');
                    const live = document.getElementById('live');
                    const streamUrl = '\(streamURL)';
                    let pc = null, restartTimeout = null, isActive = true;
                    let retryCount = 0;
                    const MAX_RETRIES = 2;
                    
                    function log(msg, isError = false) {
                        if (!isActive) return;
                        status.textContent = msg;
                        status.className = isError ? 'error' : '';
                        try { window.webkit?.messageHandlers?.logging?.postMessage(msg); } catch(e) {}
                    }
                    
                    function cleanup() {
                        isActive = false;
                        if (restartTimeout) { 
                            clearTimeout(restartTimeout); 
                            restartTimeout = null; 
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
                        live.classList.remove('show');
                    }
                    
                    async function start() {
                        if (!isActive || retryCount >= MAX_RETRIES) {
                            if (retryCount >= MAX_RETRIES) {
                                log('Max retries - giving up', true);
                            }
                            return;
                        }
                        
                        if (pc) {
                            try { pc.close(); } catch(e) {}
                            pc = null;
                        }
                        
                        log('Connecting...');
                        
                        try {
                            pc = new RTCPeerConnection({
                                iceServers: [{ urls: 'stun:stun.l.google.com:19302' }],
                                bundlePolicy: 'max-bundle', 
                                rtcpMuxPolicy: 'require'
                            });
                            
                            pc.ontrack = (e) => { 
                                if (isActive) { 
                                    log('Stream ready'); 
                                    video.srcObject = e.streams[0]; 
                                    retryCount = 0;
                                } 
                            };
                            
                            pc.oniceconnectionstatechange = () => {
                                if (!isActive) return;
                                
                                const state = pc.iceConnectionState;
                                
                                if (state === 'connected' || state === 'completed') {
                                    log('Connected'); 
                                    live.classList.add('show');
                                    retryCount = 0;
                                } else if (state === 'failed' || state === 'disconnected') {
                                    log('Connection ' + state); 
                                    live.classList.remove('show');
                                    
                                    retryCount++;
                                    if (isActive && retryCount < MAX_RETRIES) {
                                        log('Retry ' + retryCount + '/' + MAX_RETRIES);
                                        restartTimeout = setTimeout(start, 3000);
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
                            
                            if (!res.ok) throw new Error('Server: ' + res.status);
                            
                            const answer = await res.text();
                            if (isActive) {
                                await pc.setRemoteDescription({ type: 'answer', sdp: answer });
                            }
                            
                        } catch (err) {
                            log('Error: ' + err.message, true);
                            retryCount++;
                            if (isActive && retryCount < MAX_RETRIES) {
                                log('Retry ' + retryCount + '/' + MAX_RETRIES);
                                restartTimeout = setTimeout(start, 5000);
                            }
                        }
                    }
                    
                    video.addEventListener('playing', () => { 
                        if (isActive) { 
                            log('Playing'); 
                            live.classList.add('show'); 
                        } 
                    });
                    
                    video.addEventListener('error', (e) => {
                        log('Video error', true);
                    });
                    
                    window.addEventListener('beforeunload', cleanup);
                    window.addEventListener('pagehide', cleanup);
                    
                    start();
                })();
                </script>
            </body>
            </html>
            """
            
            webView.loadHTMLString(html, baseURL: nil)
        }
        
        func cleanup() {
            isActive = false
            PlayerManager.shared.releasePlayer(cameraId)
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DebugLogger.shared.log("✅ WebView loaded: \(cameraId)", emoji: "✅", color: .green)
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DebugLogger.shared.log("❌ Navigation error: \(error.localizedDescription)", emoji: "❌", color: .red)
            
            if retryCount < maxRetries {
                retryCount += 1
            }
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "logging", let msg = message.body as? String {
                DebugLogger.shared.log("🌐 [\(cameraId)]: \(msg)", emoji: "🌐", color: .gray)
            }
        }
    }
}

// MARK: - Fullscreen Player (with Proper Cleanup)
struct FullscreenPlayerView: View {
    let camera: Camera
    @Environment(\.presentationMode) var presentationMode
    @State private var showControls = true
    @State private var orientation = UIDeviceOrientation.unknown
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                
                if let url = camera.webrtcStreamURL {
                    WebRTCPlayerView(streamURL: url, cameraId: camera.id, isFullscreen: true)
                        .ignoresSafeArea()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .onTapGesture {
                            withAnimation { showControls.toggle() }
                        }
                }
                
                if showControls {
                    controlsOverlay
                }
            }
            .onAppear {
                setupOrientationObserver()
            }
            .onDisappear {
                PlayerManager.shared.releasePlayer(camera.id)
                resetOrientation()
            }
        }
        .navigationBarHidden(true)
        .statusBar(hidden: !showControls)
    }
    
    private var controlsOverlay: some View {
        VStack {
            HStack {
                Button(action: {
                    PlayerManager.shared.releasePlayer(camera.id)
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold))
                        Text("Back").font(.headline)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(10)
                }
                
                Spacer()
                
                Button(action: toggleOrientation) {
                    Image(systemName: isLandscape ? "arrow.up.left.and.arrow.down.right" : "arrow.left.and.right")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                        .padding(12)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(10)
                }
            }
            .padding()
            
            Spacer()
            
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(camera.displayName).font(.headline).foregroundColor(.white)
                    HStack(spacing: 8) {
                        Circle().fill(camera.isOnline ? Color.green : Color.red).frame(width: 8, height: 8)
                        Text(camera.area).font(.caption).foregroundColor(.white.opacity(0.8))
                    }
                }
                .padding()
                .background(Color.black.opacity(0.6))
                .cornerRadius(10)
                Spacer()
            }
            .padding()
        }
        .transition(.opacity)
    }
    
    private var isLandscape: Bool {
        orientation.isLandscape
    }
    
    private func setupOrientationObserver() {
        NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            orientation = UIDevice.current.orientation
        }
    }
    
    private func toggleOrientation() {
        if isLandscape {
            UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
        } else {
            UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
        }
        UIViewController.attemptRotationToDeviceOrientation()
    }
    
    private func resetOrientation() {
        UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
        UIViewController.attemptRotationToDeviceOrientation()
    }
}

// MARK: - Grid Modes
enum GridViewMode: String, CaseIterable, Identifiable {
    case list = "List", grid2x2 = "2×2", grid3x3 = "3×3", grid4x4 = "4×4"
    
    var id: String { rawValue }
    var columns: Int {
        switch self {
        case .list: return 1
        case .grid2x2: return 2
        case .grid3x3: return 3
        case .grid4x4: return 4
        }
    }
    var icon: String {
        switch self {
        case .list: return "list.bullet"
        case .grid2x2: return "square.grid.2x2"
        case .grid3x3: return "square.grid.3x3"
        case .grid4x4: return "square.grid.4x4"
        }
    }
}