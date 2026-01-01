import SwiftUI
import WebKit
import Combine

// MARK: - Player Manager (ULTIMATE SAFETY)
class PlayerManager: ObservableObject {
    static let shared = PlayerManager()
    
    private var activePlayers: [String: WKWebView] = [:]
    private var playerCreationTimes: [String: Date] = [:]
    private let lock = NSRecursiveLock() // ✅ Changed to recursive lock
    
    private let maxPlayers = 1
    private var cleanupInProgress: Set<String> = []
    private var messageHandlersAdded: Set<String> = [] // ✅ Track which handlers exist
    
    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        
        print("🎬 PlayerManager initialized")
    }
    
    @objc private func handleMemoryWarning() {
        print("⚠️ Memory warning - clearing all players")
        clearAll()
    }
    
    func registerPlayer(_ webView: WKWebView, for cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        print("📹 Registering: \(cameraId)")
        
        // Remove old player for same camera
        if let oldPlayer = activePlayers.removeValue(forKey: cameraId) {
            print("🗑️ Removing old player: \(cameraId)")
            playerCreationTimes.removeValue(forKey: cameraId)
            
            // Schedule cleanup without holding lock
            DispatchQueue.main.async { [weak self] in
                self?.cleanupWebViewSafely(oldPlayer, cameraId: cameraId)
            }
        }
        
        // Enforce capacity
        while activePlayers.count >= maxPlayers {
            if let oldestKey = playerCreationTimes.min(by: { $0.value < $1.value })?.key,
               let oldPlayer = activePlayers.removeValue(forKey: oldestKey) {
                print("🗑️ Capacity limit: removing \(oldestKey)")
                playerCreationTimes.removeValue(forKey: oldestKey)
                
                DispatchQueue.main.async { [weak self] in
                    self?.cleanupWebViewSafely(oldPlayer, cameraId: oldestKey)
                }
            } else {
                break
            }
        }
        
        activePlayers[cameraId] = webView
        playerCreationTimes[cameraId] = Date()
        
        print("✅ Registered: \(cameraId) (Active: \(activePlayers.count))")
    }
    
    private func cleanupWebViewSafely(_ webView: WKWebView, cameraId: String) {
        lock.lock()
        
        // Prevent double cleanup
        if cleanupInProgress.contains(cameraId) {
            lock.unlock()
            print("⚠️ Already cleaning: \(cameraId)")
            return
        }
        cleanupInProgress.insert(cameraId)
        
        let hasHandler = messageHandlersAdded.contains(cameraId)
        messageHandlersAdded.remove(cameraId)
        
        lock.unlock()
        
        // All cleanup on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Stop loading
            webView.stopLoading()
            
            // Clear content
            webView.loadHTMLString("", baseURL: nil)
            
            // Remove message handler ONLY if we added it
            if hasHandler {
                let controller = webView.configuration.userContentController
                
                // Remove all script message handlers to be safe
                controller.removeAllScriptMessageHandlers()
            }
            
            // Remove from superview
            webView.removeFromSuperview()
            
            // Mark cleanup done
            self.lock.lock()
            self.cleanupInProgress.remove(cameraId)
            self.lock.unlock()
            
            print("🧹 Cleaned: \(cameraId)")
        }
    }
    
    func releasePlayer(_ cameraId: String) {
        lock.lock()
        
        guard let webView = activePlayers.removeValue(forKey: cameraId) else {
            lock.unlock()
            return
        }
        
        playerCreationTimes.removeValue(forKey: cameraId)
        lock.unlock()
        
        cleanupWebViewSafely(webView, cameraId: cameraId)
        print("🗑️ Released: \(cameraId)")
    }
    
    func clearAll() {
        lock.lock()
        let players = activePlayers
        activePlayers.removeAll()
        playerCreationTimes.removeAll()
        lock.unlock()
        
        for (cameraId, webView) in players {
            cleanupWebViewSafely(webView, cameraId: cameraId)
        }
        
        print("🧹 Cleared all (\(players.count))")
    }
    
    func markMessageHandlerAdded(_ cameraId: String) {
        lock.lock()
        messageHandlersAdded.insert(cameraId)
        lock.unlock()
    }
    
    func getActivePlayerCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return activePlayers.count
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - WebRTC Player View (SAFE INITIALIZATION)
struct WebRTCPlayerView: UIViewRepresentable {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        print("🎬 makeUIView: \(cameraId)")
        
        // Create configuration
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        config.websiteDataStore = .nonPersistent()
        
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        
        // Create WebView
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.backgroundColor = .black
        webView.isOpaque = true
        webView.navigationDelegate = context.coordinator
        
        // ✅ CRITICAL: Add message handler with tracking
        let controller = webView.configuration.userContentController
        controller.add(context.coordinator, name: "logging")
        PlayerManager.shared.markMessageHandlerAdded(cameraId)
        
        // ✅ Register player FIRST
        PlayerManager.shared.registerPlayer(webView, for: cameraId)
        
        // ✅ Load HTML after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak coordinator = context.coordinator] in
            guard let coordinator = coordinator, !coordinator.isCleanedUp else { return }
            coordinator.loadPlayer(in: webView, streamURL: streamURL)
        }
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        // Do nothing
    }
    
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        print("🔚 dismantleUIView: \(coordinator.cameraId)")
        coordinator.cleanup()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(cameraId: cameraId)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let cameraId: String
        private(set) var isCleanedUp = false
        private let lock = NSLock()
        
        init(cameraId: String) {
            self.cameraId = cameraId
            super.init()
        }
        
        func loadPlayer(in webView: WKWebView, streamURL: String) {
            lock.lock()
            guard !isCleanedUp else {
                lock.unlock()
                print("⚠️ Already cleaned, skip load: \(cameraId)")
                return
            }
            lock.unlock()
            
            let html = generateHTML(streamURL: streamURL)
            webView.loadHTMLString(html, baseURL: nil)
        }
        
        private func generateHTML(streamURL: String) -> String {
            return """
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1.0">
                <style>
                    * { margin: 0; padding: 0; box-sizing: border-box; }
                    html, body { width: 100%; height: 100%; overflow: hidden; background: #000; }
                    video { width: 100%; height: 100%; object-fit: contain; }
                    #live { position: absolute; top: 10px; right: 10px; background: rgba(244,67,54,0.9);
                            color: white; padding: 4px 8px; border-radius: 4px; font: 700 10px sans-serif;
                            display: none; align-items: center; gap: 4px; z-index: 10; }
                    #live.show { display: flex; }
                    .dot { width: 6px; height: 6px; background: white; border-radius: 50%;
                           animation: pulse 1.5s ease-in-out infinite; }
                    @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.3; } }
                    #status { position: absolute; bottom: 10px; left: 10px; background: rgba(0,0,0,0.8);
                              color: #4CAF50; padding: 6px 10px; border-radius: 6px;
                              font: 11px sans-serif; z-index: 10; }
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
                    
                    let pc = null;
                    let restartTimeout = null;
                    let isActive = true;
                    let retryCount = 0;
                    const MAX_RETRIES = 2;
                    
                    function safeLog(msg, isError) {
                        if (!isActive) return;
                        
                        try {
                            status.textContent = msg;
                            status.className = isError ? 'error' : '';
                            
                            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.logging) {
                                window.webkit.messageHandlers.logging.postMessage(msg);
                            }
                        } catch(e) {
                            console.error('Log error:', e);
                        }
                    }
                    
                    function cleanup() {
                        if (restartTimeout) {
                            clearTimeout(restartTimeout);
                            restartTimeout = null;
                        }
                        
                        if (pc) {
                            try {
                                pc.close();
                            } catch(e) {
                                console.error('PC close error:', e);
                            }
                            pc = null;
                        }
                        
                        if (video.srcObject) {
                            try {
                                const tracks = video.srcObject.getTracks();
                                tracks.forEach(track => {
                                    try { track.stop(); } catch(e) {}
                                });
                                video.srcObject = null;
                            } catch(e) {
                                console.error('Video cleanup error:', e);
                            }
                        }
                        
                        try {
                            live.classList.remove('show');
                        } catch(e) {}
                    }
                    
                    async function start() {
                        if (!isActive || retryCount >= MAX_RETRIES) {
                            if (retryCount >= MAX_RETRIES) {
                                safeLog('Connection failed', true);
                            }
                            return;
                        }
                        
                        cleanup();
                        safeLog('Connecting...', false);
                        
                        try {
                            pc = new RTCPeerConnection({
                                iceServers: [{ urls: 'stun:stun.l.google.com:19302' }],
                                bundlePolicy: 'max-bundle',
                                rtcpMuxPolicy: 'require'
                            });
                            
                            pc.ontrack = function(e) {
                                if (!isActive) return;
                                
                                if (e.streams && e.streams.length > 0) {
                                    safeLog('Stream ready', false);
                                    video.srcObject = e.streams[0];
                                    retryCount = 0;
                                }
                            };
                            
                            pc.oniceconnectionstatechange = function() {
                                if (!isActive || !pc) return;
                                
                                const state = pc.iceConnectionState;
                                
                                if (state === 'connected' || state === 'completed') {
                                    safeLog('Connected', false);
                                    try { live.classList.add('show'); } catch(e) {}
                                } else if (state === 'failed' || state === 'disconnected') {
                                    safeLog(state === 'failed' ? 'Failed' : 'Disconnected', true);
                                    try { live.classList.remove('show'); } catch(e) {}
                                    
                                    retryCount++;
                                    if (isActive && retryCount < MAX_RETRIES) {
                                        const delay = 3000 * retryCount;
                                        restartTimeout = setTimeout(start, delay);
                                    }
                                }
                            };
                            
                            pc.addTransceiver('video', { direction: 'recvonly' });
                            pc.addTransceiver('audio', { direction: 'recvonly' });
                            
                            const offer = await pc.createOffer();
                            await pc.setLocalDescription(offer);
                            
                            const controller = new AbortController();
                            const timeoutId = setTimeout(function() { controller.abort(); }, 10000);
                            
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
                            await pc.setRemoteDescription({ type: 'answer', sdp: answer });
                            
                        } catch(err) {
                            safeLog('Error: ' + err.message, true);
                            retryCount++;
                            
                            if (isActive && retryCount < MAX_RETRIES) {
                                const delay = 5000 * retryCount;
                                restartTimeout = setTimeout(start, delay);
                            }
                        }
                    }
                    
                    video.addEventListener('playing', function() {
                        if (isActive) {
                            safeLog('Playing', false);
                            try { live.classList.add('show'); } catch(e) {}
                        }
                    });
                    
                    video.addEventListener('error', function(e) {
                        if (isActive) {
                            safeLog('Video error', true);
                        }
                    });
                    
                    window.addEventListener('beforeunload', function() {
                        isActive = false;
                        cleanup();
                    });
                    
                    window.addEventListener('error', function(e) {
                        console.error('Window error:', e);
                        return true;
                    });
                    
                    // Start
                    setTimeout(start, 100);
                })();
                </script>
            </body>
            </html>
            """
        }
        
        func cleanup() {
            lock.lock()
            guard !isCleanedUp else {
                lock.unlock()
                return
            }
            isCleanedUp = true
            lock.unlock()
            
            print("🧹 Coordinator cleanup: \(cameraId)")
            PlayerManager.shared.releasePlayer(cameraId)
        }
        
        // MARK: - WKNavigationDelegate
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("✅ Page loaded: \(cameraId)")
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("❌ Navigation failed: \(error.localizedDescription)")
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("❌ Provisional failed: \(error.localizedDescription)")
        }
        
        // MARK: - WKScriptMessageHandler
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "logging" {
                if let msg = message.body as? String {
                    print("🌐 [\(cameraId)]: \(msg)")
                }
            }
        }
        
        deinit {
            print("💀 Coordinator deinit: \(cameraId)")
        }
    }
}

// MARK: - Fullscreen Player
struct FullscreenPlayerView: View {
    let camera: Camera
    @Environment(\.presentationMode) var presentationMode
    @State private var showControls = true
    @State private var hasAppeared = false
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let url = camera.webrtcStreamURL {
                if hasAppeared {
                    WebRTCPlayerView(
                        streamURL: url,
                        cameraId: camera.id,
                        isFullscreen: true
                    )
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation { showControls.toggle() }
                    }
                } else {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                }
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 50))
                        .foregroundColor(.orange)
                    Text("Stream not available")
                        .foregroundColor(.white)
                }
            }
            
            if showControls {
                VStack {
                    HStack {
                        Button(action: dismissView) {
                            HStack(spacing: 8) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 18, weight: .semibold))
                                Text("Back")
                                    .font(.headline)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(10)
                        }
                        
                        Spacer()
                    }
                    .padding()
                    
                    Spacer()
                    
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
                    }
                    .padding()
                }
            }
        }
        .navigationBarHidden(true)
        .statusBar(hidden: !showControls)
        .onAppear {
            print("📱 Fullscreen appeared: \(camera.displayName)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                hasAppeared = true
            }
        }
        .onDisappear {
            print("🚪 Fullscreen disappeared: \(camera.displayName)")
            hasAppeared = false
            PlayerManager.shared.releasePlayer(camera.id)
        }
    }
    
    private func dismissView() {
        print("👈 Dismissing fullscreen")
        hasAppeared = false
        PlayerManager.shared.releasePlayer(camera.id)
        presentationMode.wrappedValue.dismiss()
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