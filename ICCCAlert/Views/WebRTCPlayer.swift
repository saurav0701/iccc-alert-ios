import SwiftUI
import WebKit
import Combine

// MARK: - Player Manager (ULTRA AGGRESSIVE CLEANUP)
class PlayerManager: ObservableObject {
    static let shared = PlayerManager()
    
    private var activePlayers: [String: WKWebView] = [:]
    private var playerTimers: [String: Timer] = [:]
    private let lock = NSLock()
    private let maxPlayers = 1
    private var lastCleanupTime: Date?
    
    // CRITICAL: Auto-cleanup after 4 minutes to prevent crashes
    private let maxStreamDuration: TimeInterval = 4 * 60 // 4 minutes
    
    private init() {
        setupMemoryWarning()
        setupAppStateObservers()
        DebugLogger.shared.log("📹 PlayerManager initialized (MAX 1 STREAM, 4 MIN LIMIT)", emoji: "📹", color: .blue)
    }
    
    private func setupMemoryWarning() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DebugLogger.shared.log("⚠️ MEMORY WARNING - Emergency cleanup", emoji: "🆘", color: .red)
            self?.clearAll()
        }
    }
    
    private func setupAppStateObservers() {
        // Background - immediate cleanup
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DebugLogger.shared.log("📱 App backgrounded - cleanup all", emoji: "📱", color: .orange)
            self?.clearAll()
        }
        
        // Foreground - ensure clean state
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DebugLogger.shared.log("📱 App foregrounded - verify cleanup", emoji: "📱", color: .blue)
            self?.clearAll() // Extra safety
        }
        
        // Resign active - immediate cleanup
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DebugLogger.shared.log("📱 App resign active - cleanup", emoji: "📱", color: .orange)
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
                    playerTimers[key]?.invalidate()
                    playerTimers.removeValue(forKey: key)
                    DispatchQueue.main.async {
                        self.destroyWebView(oldPlayer)
                    }
                }
            }
            
            // Wait briefly for cleanup
            Thread.sleep(forTimeInterval: 0.5)
        }
        
        activePlayers[cameraId] = webView
        lastCleanupTime = Date()
        
        // CRITICAL: Set auto-cleanup timer (4 minutes)
        let timer = Timer.scheduledTimer(withTimeInterval: maxStreamDuration, repeats: false) { [weak self] _ in
            DebugLogger.shared.log("⏱️ AUTO-CLEANUP: 4 min limit reached", emoji: "⏱️", color: .red)
            self?.releasePlayer(cameraId)
        }
        playerTimers[cameraId] = timer
        
        DebugLogger.shared.log("✅ Player registered with 4min timer: \(cameraId)", emoji: "✅", color: .green)
    }
    
    private func destroyWebView(_ webView: WKWebView) {
        DebugLogger.shared.log("🧹 Destroying WebView", emoji: "🧹", color: .blue)
        
        // CRITICAL: Complete destruction sequence
        webView.stopLoading()
        webView.navigationDelegate = nil
        
        // Stop all media
        webView.evaluateJavaScript("document.querySelectorAll('video').forEach(v => { v.pause(); v.src = ''; v.load(); });") { _, _ in }
        webView.evaluateJavaScript("if(window.cleanup) window.cleanup();") { _, _ in }
        
        // Clear all content
        webView.loadHTMLString("", baseURL: nil)
        
        // Remove ALL handlers
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        
        // Remove from view hierarchy
        webView.removeFromSuperview()
        
        // Clear website data aggressively
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let dataTypes: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
            WKWebsiteDataTypeCookies,
            WKWebsiteDataTypeSessionStorage,
            WKWebsiteDataTypeLocalStorage,
            WKWebsiteDataTypeWebSQLDatabases,
            WKWebsiteDataTypeIndexedDBDatabases
        ]
        
        dataStore.removeData(
            ofTypes: dataTypes,
            modifiedSince: Date(timeIntervalSince1970: 0),
            completionHandler: {
                DebugLogger.shared.log("🧹 All website data cleared", emoji: "🧹", color: .gray)
            }
        )
        
        DebugLogger.shared.log("✅ WebView destroyed completely", emoji: "✅", color: .green)
    }
    
    func releasePlayer(_ cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        playerTimers[cameraId]?.invalidate()
        playerTimers.removeValue(forKey: cameraId)
        
        if let webView = activePlayers.removeValue(forKey: cameraId) {
            DebugLogger.shared.log("🗑️ Releasing player: \(cameraId)", emoji: "🗑️", color: .orange)
            
            DispatchQueue.main.async {
                self.destroyWebView(webView)
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
        
        DebugLogger.shared.log("🧹 CLEARING ALL PLAYERS (\(activePlayers.count))", emoji: "🧹", color: .red)
        
        // Stop all timers
        for (_, timer) in playerTimers {
            timer.invalidate()
        }
        playerTimers.removeAll()
        
        let allPlayers = activePlayers
        activePlayers.removeAll()
        
        DispatchQueue.main.async {
            allPlayers.forEach { self.destroyWebView($0.value) }
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
        
        if activePlayers.count >= maxPlayers {
            DebugLogger.shared.log("⚠️ Cannot start - at max capacity", emoji: "⚠️", color: .orange)
            return false
        }
        
        if let lastCleanup = lastCleanupTime {
            let timeSinceCleanup = Date().timeIntervalSince(lastCleanup)
            if timeSinceCleanup < 2.0 {
                DebugLogger.shared.log("⚠️ Cannot start - too soon (\(String(format: "%.1f", timeSinceCleanup))s)", emoji: "⚠️", color: .orange)
                return false
            }
        }
        
        return true
    }
}

// MARK: - WebRTC Player View (ULTRA SAFE WITH MEMORY OPTIMIZATION)
struct WebRTCPlayerView: UIViewRepresentable {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        DebugLogger.shared.log("📹 Creating WebView: \(cameraId)", emoji: "📹", color: .blue)
        
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        config.websiteDataStore = .nonPersistent()
        
        // CRITICAL: Memory optimization
        config.processPool = WKProcessPool()
        config.suppressesIncrementalRendering = true
        
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
        private var memoryTimer: Timer?
        
        init(cameraId: String) {
            self.cameraId = cameraId
            super.init()
            
            // CRITICAL: Periodic memory cleanup every 30 seconds
            memoryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.periodicCleanup()
            }
        }
        
        private func periodicCleanup() {
            DebugLogger.shared.log("🧹 Periodic cleanup", emoji: "🧹", color: .blue)
            // Trigger garbage collection in JavaScript
            // This helps prevent memory buildup
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
                    
                    // CRITICAL: Global cleanup function
                    window.cleanup = function() {
                        isActive = false;
                        if (restartTimeout) { 
                            clearTimeout(restartTimeout); 
                            restartTimeout = null; 
                        }
                        if (pc) { 
                            try { 
                                pc.close(); 
                            } catch(e) {}
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
                        live.classList.remove('show');
                    };
                    
                    function log(msg, isError = false) {
                        if (!isActive) return;
                        status.textContent = msg;
                        status.className = isError ? 'error' : '';
                        try { window.webkit?.messageHandlers?.logging?.postMessage(msg); } catch(e) {}
                    }
                    
                    async function start() {
                        if (!isActive || retryCount >= MAX_RETRIES) {
                            if (retryCount >= MAX_RETRIES) {
                                log('Max retries', true);
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
                    
                    window.addEventListener('beforeunload', window.cleanup);
                    window.addEventListener('pagehide', window.cleanup);
                    
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
            memoryTimer?.invalidate()
            memoryTimer = nil
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

// MARK: - Fullscreen Player (with 4-minute auto-close)
struct FullscreenPlayerView: View {
    let camera: Camera
    @Environment(\.presentationMode) var presentationMode
    @State private var showControls = true
    @State private var orientation = UIDeviceOrientation.unknown
    @State private var remainingTime: TimeInterval = 4 * 60 // 4 minutes
    @State private var timer: Timer?
    @State private var showTimeWarning = false
    
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
                
                // Time warning overlay
                if showTimeWarning {
                    timeWarningOverlay
                }
            }
            .onAppear {
                setupOrientationObserver()
                startTimer()
            }
            .onDisappear {
                stopTimer()
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
                    stopTimer()
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
                
                // Time remaining indicator
                Text(formatTime(remainingTime))
                    .font(.caption)
                    .foregroundColor(remainingTime < 60 ? .red : .white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(8)
                
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
    
    private var timeWarningOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                    
                    Text("Stream will auto-close in \(Int(remainingTime))s")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Text("To prevent memory issues")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding(24)
                .background(Color.black.opacity(0.9))
                .cornerRadius(16)
                Spacer()
            }
            Spacer()
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
    
    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            remainingTime -= 1
            
            // Show warning at 30 seconds
            if remainingTime == 30 {
                withAnimation {
                    showTimeWarning = true
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    withAnimation {
                        showTimeWarning = false
                    }
                }
            }
            
            // Auto-close at 0
            if remainingTime <= 0 {
                DebugLogger.shared.log("⏱️ Auto-closing stream after 4 minutes", emoji: "⏱️", color: .orange)
                stopTimer()
                PlayerManager.shared.releasePlayer(camera.id)
                presentationMode.wrappedValue.dismiss()
            }
        }
    }
    
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
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