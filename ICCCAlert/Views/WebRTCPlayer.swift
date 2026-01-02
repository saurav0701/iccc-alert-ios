import SwiftUI
import WebKit
import Combine

// MARK: - Player Manager (LOW MEMORY MODE - AGGRESSIVE CLEANUP)
class PlayerManager: ObservableObject {
    static let shared = PlayerManager()
    
    private var activePlayers: [String: WKWebView] = [:]
    private let lock = NSLock()
    private let maxPlayers = 1
    
    // Memory monitoring
    private var memoryCheckTimer: Timer?
    private var streamStartTime: Date?
    
    private init() {
        setupMemoryWarning()
        setupAppStateObservers()
        startMemoryMonitoring()
        DebugLogger.shared.log("📹 PlayerManager initialized (LOW MEMORY MODE)", emoji: "📹", color: .blue)
    }
    
    private func setupMemoryWarning() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DebugLogger.shared.log("🆘 MEMORY WARNING - Emergency player cleanup", emoji: "🆘", color: .red)
            self?.clearAll()
        }
    }
    
    private func setupAppStateObservers() {
        // Background - cleanup
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DebugLogger.shared.log("📱 Backgrounded - cleanup players", emoji: "📱", color: .orange)
            self?.clearAll()
        }
        
        // Foreground - log
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DebugLogger.shared.log("📱 Foregrounded", emoji: "📱", color: .blue)
        }
    }
    
    // MARK: - Memory Monitoring (NEW - CRITICAL FOR LOW RAM)
    
    private func startMemoryMonitoring() {
        memoryCheckTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
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
            
            // CRITICAL: On iPhone 7 (2GB RAM), if app uses > 300MB, start aggressive cleanup
            if usedMemoryMB > 300 {
                DebugLogger.shared.log("⚠️ HIGH MEMORY - Clearing players", emoji: "⚠️", color: .orange)
                clearAll()
            }
            
            // Check stream duration - restart after 4 minutes to prevent memory buildup
            if let startTime = streamStartTime {
                let duration = Date().timeIntervalSince(startTime)
                if duration > 240 { // 4 minutes
                    DebugLogger.shared.log("⏱️ Stream running >4min - Restart recommended", emoji: "⏱️", color: .orange)
                    // Don't auto-restart (user should manually), but warn
                }
            }
        }
    }
    
    func registerPlayer(_ webView: WKWebView, for cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        DebugLogger.shared.log("📹 Registering: \(cameraId)", emoji: "📹", color: .blue)
        
        // Clear existing players first
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
        
        DebugLogger.shared.log("✅ Registered: \(cameraId)", emoji: "✅", color: .green)
    }
    
    private func destroyWebViewAggressively(_ webView: WKWebView) {
        DebugLogger.shared.log("🧹 Destroying WebView (aggressive)", emoji: "🧹", color: .blue)
        
        // 1. Stop loading
        webView.stopLoading()
        
        // 2. Clear delegates
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        
        // 3. Remove script handlers
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        
        // 4. Load blank page to release video resources
        webView.loadHTMLString("", baseURL: nil)
        
        // 5. Remove from view hierarchy
        webView.removeFromSuperview()
        
        // 6. Clear website data
        let dataStore = WKWebsiteDataStore.nonPersistent()
        dataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: Date(timeIntervalSince1970: 0),
            completionHandler: {}
        )
        
        // 7. Force autoreleasepool drain
        autoreleasepool {}
        
        DebugLogger.shared.log("✅ WebView destroyed", emoji: "✅", color: .green)
    }
    
    func releasePlayer(_ cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        if let webView = activePlayers.removeValue(forKey: cameraId) {
            DebugLogger.shared.log("🗑️ Releasing: \(cameraId)", emoji: "🗑️", color: .orange)
            
            streamStartTime = nil
            
            DispatchQueue.main.async {
                self.destroyWebViewAggressively(webView)
            }
        }
    }
    
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        
        if activePlayers.isEmpty {
            return
        }
        
        DebugLogger.shared.log("🧹 Clearing all players", emoji: "🧹", color: .red)
        
        let allPlayers = activePlayers
        activePlayers.removeAll()
        streamStartTime = nil
        
        DispatchQueue.main.async {
            allPlayers.forEach { self.destroyWebViewAggressively($0.value) }
        }
    }
    
    func getActiveCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return activePlayers.count
    }
    
    deinit {
        memoryCheckTimer?.invalidate()
    }
}

// MARK: - WebRTC Player View (MEMORY OPTIMIZED)
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
        
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        
        // Suppress media cache to reduce memory
        config.suppressesIncrementalRendering = true
        
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
                    let pc = null, isActive = true;
                    let memoryCheckInterval = null;
                    
                    function log(msg, isError = false) {
                        if (!isActive) return;
                        status.textContent = msg;
                        status.className = isError ? 'error' : '';
                        try { window.webkit?.messageHandlers?.logging?.postMessage(msg); } catch(e) {}
                    }
                    
                    function cleanup() {
                        isActive = false;
                        if (memoryCheckInterval) clearInterval(memoryCheckInterval);
                        try {
                            if (pc) { pc.close(); pc = null; }
                            if (video.srcObject) {
                                video.srcObject.getTracks().forEach(t => t.stop());
                                video.srcObject = null;
                            }
                            video.src = '';
                            video.load();
                        } catch(e) {}
                        live.classList.remove('show');
                    }
                    
                    async function start() {
                        if (!isActive) return;
                        
                        log('Connecting...');
                        
                        try {
                            pc = new RTCPeerConnection({
                                iceServers: [{ urls: 'stun:stun.l.google.com:19302' }],
                                iceTransportPolicy: 'all'
                            });
                            
                            pc.ontrack = (e) => { 
                                if (isActive) { 
                                    log('Stream ready'); 
                                    video.srcObject = e.streams[0]; 
                                } 
                            };
                            
                            pc.oniceconnectionstatechange = () => {
                                if (!isActive) return;
                                const state = pc.iceConnectionState;
                                if (state === 'connected' || state === 'completed') {
                                    log('Connected'); 
                                    live.classList.add('show');
                                } else if (state === 'failed' || state === 'disconnected') {
                                    log('Disconnected', true); 
                                    live.classList.remove('show');
                                }
                            };
                            
                            pc.addTransceiver('video', { direction: 'recvonly' });
                            pc.addTransceiver('audio', { direction: 'recvonly' });
                            
                            const offer = await pc.createOffer();
                            await pc.setLocalDescription(offer);
                            
                            const res = await fetch(streamUrl, {
                                method: 'POST', 
                                headers: { 'Content-Type': 'application/sdp' }, 
                                body: offer.sdp
                            });
                            
                            if (!res.ok) throw new Error('Server error');
                            
                            const answer = await res.text();
                            if (isActive) {
                                await pc.setRemoteDescription({ type: 'answer', sdp: answer });
                            }
                            
                        } catch (err) {
                            log('Error: ' + err.message, true);
                        }
                    }
                    
                    video.addEventListener('playing', () => { 
                        if (isActive) { 
                            log('Playing'); 
                            live.classList.add('show');
                            
                            // Start memory check (every 30 seconds)
                            memoryCheckInterval = setInterval(() => {
                                if (performance.memory) {
                                    const usedMB = (performance.memory.usedJSHeapSize / 1024 / 1024).toFixed(1);
                                    log('Playing | Mem: ' + usedMB + 'MB');
                                }
                            }, 30000);
                        } 
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
            DebugLogger.shared.log("❌ Error: \(error.localizedDescription)", emoji: "❌", color: .red)
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "logging", let msg = message.body as? String {
                DebugLogger.shared.log("🌐 [\(cameraId)]: \(msg)", emoji: "🌐", color: .gray)
            }
        }
    }
}

// MARK: - Fullscreen Player (MEMORY OPTIMIZED)
struct FullscreenPlayerView: View {
    let camera: Camera
    @Environment(\.presentationMode) var presentationMode
    @State private var showControls = true
    @State private var orientation = UIDeviceOrientation.unknown
    @State private var showMemoryWarning = false
    
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
                
                if showMemoryWarning {
                    memoryWarningOverlay
                }
            }
            .onAppear {
                setupOrientationObserver()
                setupMemoryWarning()
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
    
    private var memoryWarningOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.orange)
                    Text("High Memory Usage")
                        .font(.caption)
                        .foregroundColor(.white)
                    Text("Consider restarting")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.8))
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
    
    private func setupMemoryWarning() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            showMemoryWarning = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                showMemoryWarning = false
            }
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