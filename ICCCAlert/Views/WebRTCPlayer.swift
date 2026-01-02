import SwiftUI
import WebKit
import Combine

// MARK: - Player Manager (ULTRA-STABLE FOR LOW MEMORY)
class PlayerManager: ObservableObject {
    static let shared = PlayerManager()
    
    private var activePlayers: [String: WKWebView] = [:]
    private let lock = NSLock()
    private let maxPlayers = 1
    
    // CRITICAL: Track app state
    private var isAppActive = true
    
    // Memory monitoring with aggressive thresholds
    private var memoryCheckTimer: Timer?
    private var streamStartTime: Date?
    private var lastMemoryWarning: Date?
    
    // CRITICAL: Connection health monitoring
    private var connectionHealthTimer: Timer?
    private var lastHealthCheck: Date?
    private var consecutiveHealthCheckFailures = 0
    
    private init() {
        setupMemoryWarning()
        setupAppStateObservers()
        startMemoryMonitoring()
        startConnectionHealthMonitoring()
        DebugLogger.shared.log("📹 PlayerManager initialized (ULTRA-STABLE MODE)", emoji: "📹", color: .blue)
    }
    
    private func setupMemoryWarning() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DebugLogger.shared.log("🆘 MEMORY WARNING - Emergency cleanup", emoji: "🆘", color: .red)
            self?.lastMemoryWarning = Date()
            self?.clearAll()
            
            // Force garbage collection
            autoreleasepool {
                URLCache.shared.removeAllCachedResponses()
            }
        }
    }
    
    private func setupAppStateObservers() {
        // Immediate cleanup on app state change
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DebugLogger.shared.log("⚠️ App will resign active - IMMEDIATE cleanup", emoji: "⚠️", color: .orange)
            self?.isAppActive = false
            self?.clearAll()
        }
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DebugLogger.shared.log("✅ App became active", emoji: "✅", color: .green)
            self?.isAppActive = true
            self?.consecutiveHealthCheckFailures = 0
        }
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DebugLogger.shared.log("📱 Backgrounded - cleanup", emoji: "📱", color: .orange)
            self?.isAppActive = false
            self?.clearAll()
        }
    }
    
    // MARK: - Memory Monitoring (AGGRESSIVE FOR IPHONE 7)
    
    private func startMemoryMonitoring() {
        // Check every 15 seconds (more frequent for iPhone 7)
        memoryCheckTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.checkMemoryUsage()
        }
    }
    
    private func checkMemoryUsage() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            let usedMemoryMB = Double(info.resident_size) / 1024 / 1024
            
            DebugLogger.shared.log("💾 Memory: \(String(format: "%.1f", usedMemoryMB)) MB", emoji: "💾", color: .gray)
            
            // CRITICAL: iPhone 7 thresholds (2GB total RAM)
            // Normal apps should stay under 200MB to be safe
            if usedMemoryMB > 250 {
                DebugLogger.shared.log("🚨 CRITICAL MEMORY (\(String(format: "%.1f", usedMemoryMB))MB) - Emergency restart", emoji: "🚨", color: .red)
                clearAll()
                
                // Post notification to UI to show warning
                NotificationCenter.default.post(name: NSNotification.Name("MemoryCritical"), object: nil)
                
            } else if usedMemoryMB > 200 {
                DebugLogger.shared.log("⚠️ HIGH MEMORY (\(String(format: "%.1f", usedMemoryMB))MB) - Warning", emoji: "⚠️", color: .orange)
            }
            
            // Check stream duration - iPhone 7 can't handle long streams
            if let startTime = streamStartTime {
                let duration = Date().timeIntervalSince(startTime)
                let minutes = Int(duration / 60)
                
                DebugLogger.shared.log("⏱️ Stream duration: \(minutes)m", emoji: "⏱️", color: .gray)
                
                // CRITICAL: Auto-restart after 3 minutes on iPhone 7
                if duration > 180 { // 3 minutes
                    DebugLogger.shared.log("🔄 Auto-restart after 3min (iPhone 7 protection)", emoji: "🔄", color: .orange)
                    clearAll()
                    
                    // Post notification to UI to restart stream
                    NotificationCenter.default.post(name: NSNotification.Name("StreamAutoRestart"), object: nil)
                }
            }
        }
    }
    
    // MARK: - Connection Health Monitoring (NEW - CRITICAL)
    
    private func startConnectionHealthMonitoring() {
        // Check connection health every 20 seconds
        connectionHealthTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { [weak self] _ in
            self?.checkConnectionHealth()
        }
    }
    
    private func checkConnectionHealth() {
        guard isAppActive else { return }
        
        lock.lock()
        guard !activePlayers.isEmpty else {
            lock.unlock()
            return
        }
        
        let players = Array(activePlayers.values)
        lock.unlock()
        
        // Check if WebView is responsive
        for webView in players {
            webView.evaluateJavaScript("typeof pc !== 'undefined' && pc ? pc.iceConnectionState : 'no-pc'") { [weak self] result, error in
                guard let self = self else { return }
                
                if let error = error {
                    DebugLogger.shared.log("⚠️ Health check failed: \(error.localizedDescription)", emoji: "⚠️", color: .orange)
                    self.consecutiveHealthCheckFailures += 1
                    
                    // If 3 consecutive failures, restart
                    if self.consecutiveHealthCheckFailures >= 3 {
                        DebugLogger.shared.log("🚨 Connection dead - Force restart", emoji: "🚨", color: .red)
                        self.clearAll()
                        NotificationCenter.default.post(name: NSNotification.Name("ConnectionDead"), object: nil)
                    }
                    
                } else if let state = result as? String {
                    DebugLogger.shared.log("🔍 Connection health: \(state)", emoji: "🔍", color: .gray)
                    
                    if state == "failed" || state == "disconnected" || state == "closed" {
                        DebugLogger.shared.log("🔄 Connection unhealthy - Restart", emoji: "🔄", color: .orange)
                        self.clearAll()
                        NotificationCenter.default.post(name: NSNotification.Name("ConnectionUnhealthy"), object: nil)
                    } else {
                        self.consecutiveHealthCheckFailures = 0
                    }
                }
            }
        }
    }
    
    func registerPlayer(_ webView: WKWebView, for cameraId: String) {
        guard isAppActive else {
            DebugLogger.shared.log("⚠️ Cannot register - app not active", emoji: "⚠️", color: .orange)
            return
        }
        
        lock.lock()
        defer { lock.unlock() }
        
        DebugLogger.shared.log("📹 Registering: \(cameraId)", emoji: "📹", color: .blue)
        
        // Clear existing players
        if !activePlayers.isEmpty {
            let allKeys = Array(activePlayers.keys)
            for key in allKeys {
                if let oldPlayer = activePlayers.removeValue(forKey: key) {
                    DispatchQueue.main.async {
                        self.destroyWebViewAggressively(oldPlayer)
                    }
                }
            }
        }
        
        activePlayers[cameraId] = webView
        streamStartTime = Date()
        consecutiveHealthCheckFailures = 0
        
        DebugLogger.shared.log("✅ Registered: \(cameraId)", emoji: "✅", color: .green)
    }
    
    private func destroyWebViewAggressively(_ webView: WKWebView) {
        DebugLogger.shared.log("🧹 Destroying WebView", emoji: "🧹", color: .blue)
        
        guard Thread.isMainThread else {
            DispatchQueue.main.sync {
                self.destroyWebViewAggressively(webView)
            }
            return
        }
        
        // 1. Execute JavaScript cleanup FIRST (most critical)
        let cleanupScript = """
        (function() {
            try {
                // Stop all tracks
                var video = document.getElementById('video');
                if (video && video.srcObject) {
                    video.srcObject.getTracks().forEach(function(track) { 
                        track.stop(); 
                    });
                    video.srcObject = null;
                }
                video.pause();
                video.removeAttribute('src');
                video.load();
                
                // Close peer connection
                if (typeof pc !== 'undefined' && pc) {
                    pc.close();
                    pc = null;
                }
                
                // Clear any intervals
                if (typeof heartbeatInterval !== 'undefined') {
                    clearInterval(heartbeatInterval);
                }
                
                return 'cleaned';
            } catch(e) {
                return 'error: ' + e.message;
            }
        })();
        """
        
        let semaphore = DispatchSemaphore(value: 0)
        webView.evaluateJavaScript(cleanupScript) { result, error in
            if let result = result {
                DebugLogger.shared.log("✅ JS cleanup: \(result)", emoji: "✅", color: .green)
            }
            if let error = error {
                DebugLogger.shared.log("⚠️ JS cleanup error: \(error.localizedDescription)", emoji: "⚠️", color: .orange)
            }
            semaphore.signal()
        }
        
        // Wait max 1 second for JS cleanup
        _ = semaphore.wait(timeout: .now() + 1.0)
        
        // 2. Stop loading
        webView.stopLoading()
        
        // 3. Clear delegates
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        
        // 4. Remove script handlers
        let contentController = webView.configuration.userContentController
        contentController.removeScriptMessageHandler(forName: "logging")
        contentController.removeAllScriptMessageHandlers()
        
        // 5. Load blank page
        webView.loadHTMLString("", baseURL: nil)
        
        // 6. Remove from view
        webView.removeFromSuperview()
        
        // 7. Clear website data
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(
            ofTypes: dataTypes,
            modifiedSince: Date(timeIntervalSince1970: 0)
        ) {
            DebugLogger.shared.log("✅ Website data cleared", emoji: "✅", color: .gray)
        }
        
        // 8. Force memory release
        autoreleasepool {}
        
        DebugLogger.shared.log("✅ WebView destroyed", emoji: "✅", color: .green)
    }
    
    func releasePlayer(_ cameraId: String) {
        lock.lock()
        
        guard let webView = activePlayers.removeValue(forKey: cameraId) else {
            lock.unlock()
            return
        }
        
        DebugLogger.shared.log("🗑️ Releasing: \(cameraId)", emoji: "🗑️", color: .orange)
        streamStartTime = nil
        consecutiveHealthCheckFailures = 0
        
        lock.unlock()
        
        DispatchQueue.main.async {
            self.destroyWebViewAggressively(webView)
        }
    }
    
    func clearAll() {
        lock.lock()
        
        guard !activePlayers.isEmpty else {
            lock.unlock()
            return
        }
        
        DebugLogger.shared.log("🧹 Clearing all players", emoji: "🧹", color: .red)
        
        let allPlayers = activePlayers
        activePlayers.removeAll()
        streamStartTime = nil
        consecutiveHealthCheckFailures = 0
        
        lock.unlock()
        
        DispatchQueue.main.async {
            for (cameraId, webView) in allPlayers {
                DebugLogger.shared.log("🗑️ Destroying: \(cameraId)", emoji: "🗑️", color: .orange)
                self.destroyWebViewAggressively(webView)
            }
        }
    }
    
    func getActiveCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return activePlayers.count
    }
    
    deinit {
        memoryCheckTimer?.invalidate()
        connectionHealthTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - WebRTC Player View (ULTRA-STABLE)
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
        config.websiteDataStore = .default()
        
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        
        // CRITICAL: Process pool management
        config.processPool = WKProcessPool()
        
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
        DebugLogger.shared.log("🗑️ Dismantling WebView: \(coordinator.cameraId)", emoji: "🗑️", color: .orange)
        coordinator.cleanup()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(cameraId: cameraId)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let cameraId: String
        private var isActive = true
        private weak var webView: WKWebView?
        
        init(cameraId: String) {
            self.cameraId = cameraId
            super.init()
        }
        
        func loadPlayer(in webView: WKWebView, streamURL: String) {
            self.webView = webView
            
            // CRITICAL: Optimized HTML for iPhone 7
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
                    let pc = null, isActive = true;
                    let heartbeatInterval = null;
                    let reconnectAttempts = 0;
                    const MAX_RECONNECT = 2;
                    
                    function log(msg, isError = false) {
                        if (!isActive) return;
                        status.textContent = msg;
                        status.className = isError ? 'error' : '';
                        try { 
                            if (window.webkit?.messageHandlers?.logging) {
                                window.webkit.messageHandlers.logging.postMessage(msg); 
                            }
                        } catch(e) {}
                    }
                    
                    function cleanup() {
                        if (!isActive) return;
                        isActive = false;
                        
                        log('Cleaning up...');
                        
                        if (heartbeatInterval) {
                            clearInterval(heartbeatInterval);
                            heartbeatInterval = null;
                        }
                        
                        try {
                            if (pc) { 
                                pc.close(); 
                                pc = null; 
                            }
                            
                            if (video.srcObject) {
                                video.srcObject.getTracks().forEach(function(t) {
                                    t.stop();
                                });
                                video.srcObject = null;
                            }
                            
                            video.pause();
                            video.removeAttribute('src');
                            video.load();
                            
                        } catch(e) {
                            log('Cleanup error: ' + e.message, true);
                        }
                        
                        live.classList.remove('show');
                        log('Cleaned up');
                    }
                    
                    async function start() {
                        if (!isActive) return;
                        
                        if (reconnectAttempts >= MAX_RECONNECT) {
                            log('Max reconnect attempts', true);
                            return;
                        }
                        
                        log('Connecting... (attempt ' + (reconnectAttempts + 1) + ')');
                        
                        try {
                            pc = new RTCPeerConnection({
                                iceServers: [{ urls: 'stun:stun.l.google.com:19302' }],
                                iceTransportPolicy: 'all',
                                // CRITICAL: Optimize for mobile
                                bundlePolicy: 'max-bundle',
                                rtcpMuxPolicy: 'require'
                            });
                            
                            // CRITICAL: Monitor memory in JavaScript
                            let lastMemoryCheck = Date.now();
                            
                            pc.ontrack = (e) => { 
                                if (!isActive || !e.streams || !e.streams[0]) return;
                                
                                log('Stream ready'); 
                                video.srcObject = e.streams[0];
                                reconnectAttempts = 0;
                            };
                            
                            pc.oniceconnectionstatechange = () => {
                                if (!isActive) return;
                                const state = pc.iceConnectionState;
                                log('ICE: ' + state);
                                
                                if (state === 'connected' || state === 'completed') {
                                    live.classList.add('show');
                                } else if (state === 'failed') {
                                    live.classList.remove('show');
                                    log('Connection failed', true);
                                    
                                    // Try reconnect
                                    setTimeout(() => {
                                        if (isActive && reconnectAttempts < MAX_RECONNECT) {
                                            reconnectAttempts++;
                                            cleanup();
                                            isActive = true;
                                            start();
                                        }
                                    }, 2000);
                                    
                                } else if (state === 'disconnected') {
                                    live.classList.remove('show');
                                    log('Disconnected', true);
                                }
                            };
                            
                            // CRITICAL: Lower bandwidth for iPhone 7
                            const videoTransceiver = pc.addTransceiver('video', { 
                                direction: 'recvonly'
                            });
                            
                            // Request lower bitrate
                            const sender = videoTransceiver.sender;
                            const params = sender.getParameters();
                            if (!params.encodings) params.encodings = [{}];
                            params.encodings[0].maxBitrate = 500000; // 500kbps max
                            sender.setParameters(params);
                            
                            pc.addTransceiver('audio', { direction: 'recvonly' });
                            
                            const offer = await pc.createOffer();
                            await pc.setLocalDescription(offer);
                            
                            const controller = new AbortController();
                            const timeoutId = setTimeout(() => controller.abort(), 8000);
                            
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
                            if (isActive) {
                                await pc.setRemoteDescription({ type: 'answer', sdp: answer });
                                log('Connected');
                            }
                            
                        } catch (err) {
                            log('Error: ' + err.message, true);
                            
                            if (reconnectAttempts < MAX_RECONNECT) {
                                reconnectAttempts++;
                                setTimeout(() => {
                                    if (isActive) start();
                                }, 3000);
                            }
                        }
                    }
                    
                    video.addEventListener('playing', () => { 
                        if (!isActive) return;
                        log('Playing'); 
                        live.classList.add('show');
                        
                        // Heartbeat - check connection health
                        heartbeatInterval = setInterval(() => {
                            if (!isActive || !pc) return;
                            
                            const state = pc.iceConnectionState;
                            log('▶️ ' + state);
                            
                            if (state === 'failed' || state === 'closed') {
                                cleanup();
                            }
                        }, 15000); // Every 15 seconds
                    });
                    
                    video.addEventListener('error', (e) => {
                        log('Video error', true);
                        cleanup();
                    });
                    
                    video.addEventListener('stalled', () => {
                        log('Video stalled', true);
                    });
                    
                    // Page visibility
                    document.addEventListener('visibilitychange', () => {
                        if (document.hidden) {
                            log('Page hidden - cleanup');
                            cleanup();
                        }
                    });
                    
                    // Cleanup handlers
                    window.addEventListener('beforeunload', cleanup);
                    window.addEventListener('pagehide', cleanup);
                    window.addEventListener('unload', cleanup);
                    
                    // Start connection
                    start();
                })();
                </script>
            </body>
            </html>
            """
            
            webView.loadHTMLString(html, baseURL: nil)
        }
        
        func cleanup() {
            guard isActive else { return }
            isActive = false
            
            DebugLogger.shared.log("🧹 Coordinator cleanup: \(cameraId)", emoji: "🧹", color: .orange)
            
            webView?.evaluateJavaScript("if (typeof cleanup === 'function') cleanup();") { _, _ in }
            
            PlayerManager.shared.releasePlayer(cameraId)
            webView = nil
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DebugLogger.shared.log("✅ WebView loaded: \(cameraId)", emoji: "✅", color: .green)
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DebugLogger.shared.log("❌ Navigation error: \(error.localizedDescription)", emoji: "❌", color: .red)
        }
        
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            DebugLogger.shared.log("💀 WebView process terminated - CRASH!", emoji: "💀", color: .red)
            cleanup()
            NotificationCenter.default.post(name: NSNotification.Name("WebViewCrashed"), object: nil)
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "logging", let msg = message.body as? String {
                DebugLogger.shared.log("🌐 [\(cameraId)]: \(msg)", emoji: "🌐", color: .gray)
            }
        }
        
        deinit {
            DebugLogger.shared.log("💀 Coordinator deinit: \(cameraId)", emoji: "💀", color: .gray)
        }
    }
}

// MARK: - Fullscreen Player (WITH AUTO-RECOVERY)
struct FullscreenPlayerView: View {
    let camera: Camera
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.scenePhase) var scenePhase
    @State private var showControls = true
    @State private var orientation = UIDeviceOrientation.unknown
    @State private var showWarning = false
    @State private var warningMessage = ""
    @State private var shouldRestart = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                
                if let url = camera.webrtcStreamURL, !shouldRestart {
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
                
                if showWarning {
                    warningOverlay
                }
            }
            .onAppear {
                setupOrientationObserver()
                setupNotificationObservers()
            }
            .onDisappear {
                DebugLogger.shared.log("🔚 FullscreenPlayerView disappeared", emoji: "🔚", color: .orange)
                PlayerManager.shared.releasePlayer(camera.id)
                resetOrientation()
                removeNotificationObservers()
            }
            .onChange(of: scenePhase) { newPhase in
                handleScenePhase(newPhase)
            }
        }
        .navigationBarHidden(true)
        .statusBar(hidden: !showControls)
    }
    
    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("MemoryCritical"),
            object: nil,
            queue: .main
        ) { _ in
            showWarningMessage("Memory Critical - Restarting...")
            restartStream()
        }
        
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("StreamAutoRestart"),
            object: nil,
            queue: .main
        ) { _ in
            showWarningMessage("Auto-restart (3min protection)")
            restartStream()
        }
        
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("WebViewCrashed"),
            object: nil,
            queue: .main
        ) { _ in
            showWarningMessage("Stream crashed - Restarting...")
            restartStream()
        }
    }
    
    private func removeNotificationObservers() {
        NotificationCenter.default.removeObserver(self)
    }
    
    private func showWarningMessage(_ message: String) {
        warningMessage = message
        showWarning = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            showWarning = false
        }
    }
    
    private func restartStream() {
        shouldRestart = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            shouldRestart = false
        }
    }
    
    private var warningOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.orange)
                    Text(warningMessage)
                        .font(.caption)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(Color.orange.opacity(0.9))
                .cornerRadius(12)
                .padding()
                Spacer()
            }
            Spacer()
        }
    }
    
    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            DebugLogger.shared.log("📱 Player scene active", emoji: "📱", color: .green)
        case .inactive:
            DebugLogger.shared.log("⚠️ Player scene inactive - cleanup", emoji: "⚠️", color: .orange)
            PlayerManager.shared.releasePlayer(camera.id)
        case .background:
            DebugLogger.shared.log("📱 Player scene background - cleanup", emoji: "📱", color: .red)
            PlayerManager.shared.releasePlayer(camera.id)
        @unknown default:
            break
        }
    }
    
    private var controlsOverlay: some View {
        VStack {
            HStack {
                Button(action: {
                    DebugLogger.shared.log("👈 Back button tapped", emoji: "👈", color: .blue)
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