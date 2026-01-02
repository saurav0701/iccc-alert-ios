import SwiftUI
import WebKit
import Combine

// MARK: - AUTO-RESTART CONFIGURATION
struct StreamConfig {
    static let maxStreamDuration: TimeInterval = 300 // 5 minutes
    static let thumbnailTimeout: TimeInterval = 8 // 8 seconds
    static let memoryThresholdMB: Double = 250 // Aggressive threshold
    static let maxConcurrentStreams = 1
}

// MARK: - Memory Monitor (Singleton)
class MemoryMonitor: ObservableObject {
    static let shared = MemoryMonitor()
    
    @Published var currentMemoryMB: Double = 0
    @Published var isMemoryWarning: Bool = false
    
    private var timer: Timer?
    
    private init() {
        startMonitoring()
        setupMemoryWarning()
    }
    
    private func setupMemoryWarning() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isMemoryWarning = true
            self?.handleMemoryWarning()
        }
    }
    
    private func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.updateMemoryUsage()
        }
    }
    
    private func updateMemoryUsage() {
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
            currentMemoryMB = Double(info.resident_size) / 1024 / 1024
            
            if currentMemoryMB > StreamConfig.memoryThresholdMB {
                handleMemoryWarning()
            }
        }
    }
    
    private func handleMemoryWarning() {
        DebugLogger.shared.log("🆘 MEMORY WARNING - Triggering cleanup", emoji: "🆘", color: .red)
        
        // Cleanup all players
        PlayerManager.shared.emergencyCleanup()
        
        // Cleanup thumbnails
        ThumbnailCacheManager.shared.emergencyCleanup()
        
        // Force system cleanup
        URLCache.shared.removeAllCachedResponses()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.isMemoryWarning = false
        }
    }
    
    deinit {
        timer?.invalidate()
    }
}

// MARK: - WebView Pool (Reuse & Cleanup)
class WebViewPool {
    static let shared = WebViewPool()
    
    private var availableWebViews: [WKWebView] = []
    private var activeWebViews: Set<WKWebView> = []
    private let lock = NSLock()
    private let maxPoolSize = 2
    
    private init() {}
    
    func getWebView() -> WKWebView {
        lock.lock()
        defer { lock.unlock() }
        
        if let webView = availableWebViews.first {
            availableWebViews.removeFirst()
            activeWebViews.insert(webView)
            DebugLogger.shared.log("♻️ Reusing pooled WebView", emoji: "♻️", color: .green)
            return webView
        }
        
        let webView = createFreshWebView()
        activeWebViews.insert(webView)
        return webView
    }
    
    func returnWebView(_ webView: WKWebView) {
        lock.lock()
        defer { lock.unlock() }
        
        activeWebViews.remove(webView)
        
        // Clean before returning to pool
        cleanWebView(webView)
        
        if availableWebViews.count < maxPoolSize {
            availableWebViews.append(webView)
            DebugLogger.shared.log("♻️ Returned WebView to pool", emoji: "♻️", color: .blue)
        } else {
            destroyWebView(webView)
        }
    }
    
    func destroyAll() {
        lock.lock()
        let all = activeWebViews + availableWebViews
        activeWebViews.removeAll()
        availableWebViews.removeAll()
        lock.unlock()
        
        all.forEach { destroyWebView($0) }
    }
    
    private func createFreshWebView() -> WKWebView {
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
        webView.backgroundColor = .black
        webView.isOpaque = true
        
        return webView
    }
    
    private func cleanWebView(_ webView: WKWebView) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
    }
    
    private func destroyWebView(_ webView: WKWebView) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        
        // Critical: Remove ALL script handlers to break retain cycles
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()
        
        // Clear website data
        let dataStore = WKWebsiteDataStore.nonPersistent()
        dataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: Date(timeIntervalSince1970: 0),
            completionHandler: {}
        )
    }
}

// MARK: - Stream Session (Auto-Restart)
class StreamSession: ObservableObject {
    let id: String
    let cameraId: String
    let streamURL: String
    
    @Published var isActive = false
    @Published var needsRestart = false
    @Published var secondsRemaining: Int = 0
    
    private var webView: WKWebView?
    private var coordinator: WebRTCPlayerView.Coordinator?
    private var startTime: Date?
    private var restartTimer: Timer?
    private var countdownTimer: Timer?
    
    init(cameraId: String, streamURL: String) {
        self.id = UUID().uuidString
        self.cameraId = cameraId
        self.streamURL = streamURL
    }
    
    func start() -> WKWebView {
        guard webView == nil else { return webView! }
        
        isActive = true
        startTime = Date()
        secondsRemaining = Int(StreamConfig.maxStreamDuration)
        
        // Get WebView from pool
        let wv = WebViewPool.shared.getWebView()
        self.webView = wv
        
        // Create coordinator with proper cleanup callback
        let coord = WebRTCPlayerView.Coordinator(
            cameraId: cameraId,
            onCleanup: { [weak self] in
                self?.handleCoordinatorCleanup()
            }
        )
        self.coordinator = coord
        
        // Setup coordinator
        wv.navigationDelegate = coord
        wv.configuration.userContentController.add(coord, name: "logging")
        
        // Load stream
        coord.loadPlayer(in: wv, streamURL: streamURL)
        
        // Setup auto-restart timer
        setupRestartTimer()
        
        DebugLogger.shared.log("▶️ Stream session started: \(cameraId)", emoji: "▶️", color: .green)
        
        return wv
    }
    
    private func setupRestartTimer() {
        restartTimer?.invalidate()
        
        // Countdown timer (updates UI every second)
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard let startTime = self.startTime else { return }
            
            let elapsed = Date().timeIntervalSince(startTime)
            let remaining = Int(StreamConfig.maxStreamDuration - elapsed)
            
            self.secondsRemaining = max(0, remaining)
        }
        
        // Auto-restart timer
        restartTimer = Timer.scheduledTimer(
            withTimeInterval: StreamConfig.maxStreamDuration,
            repeats: false
        ) { [weak self] _ in
            self?.triggerRestart()
        }
    }
    
    private func triggerRestart() {
        DebugLogger.shared.log("🔄 Auto-restart triggered for: \(cameraId)", emoji: "🔄", color: .orange)
        needsRestart = true
        stop()
    }
    
    func stop() {
        DebugLogger.shared.log("⏹️ Stopping stream session: \(cameraId)", emoji: "⏹️", color: .orange)
        
        isActive = false
        restartTimer?.invalidate()
        countdownTimer?.invalidate()
        
        // Cleanup coordinator FIRST (breaks retain cycles)
        if let coord = coordinator {
            coord.cleanup()
            if let wv = webView {
                wv.configuration.userContentController.removeScriptMessageHandler(forName: "logging")
            }
        }
        coordinator = nil
        
        // Return WebView to pool (will be cleaned)
        if let wv = webView {
            WebViewPool.shared.returnWebView(wv)
        }
        webView = nil
        startTime = nil
    }
    
    private func handleCoordinatorCleanup() {
        DebugLogger.shared.log("🧹 Coordinator cleanup callback", emoji: "🧹", color: .gray)
    }
    
    deinit {
        stop()
    }
}

// MARK: - Enhanced Player Manager
extension PlayerManager {
    func createSession(for camera: Camera) -> StreamSession? {
        guard let streamURL = camera.webrtcStreamURL else { return nil }
        
        // Force cleanup of existing sessions
        clearAll()
        
        let session = StreamSession(cameraId: camera.id, streamURL: streamURL)
        return session
    }
    
    func emergencyCleanup() {
        lock.lock()
        let players = Array(activePlayers.values)
        activePlayers.removeAll()
        streamStartTime = nil
        lock.unlock()
        
        DebugLogger.shared.log("🆘 EMERGENCY CLEANUP - Destroying all players", emoji: "🆘", color: .red)
        
        // Destroy all WebViews
        players.forEach { destroyWebViewAggressively($0) }
        
        // Destroy pool
        WebViewPool.shared.destroyAll()
        
        // Force memory hint
        autoreleasepool {}
    }
}

// MARK: - Enhanced WebRTC Player View
struct WebRTCPlayerView: UIViewRepresentable {
    let session: StreamSession
    let isFullscreen: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        return session.start()
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        // Cleanup is handled by StreamSession
    }
    
    func makeCoordinator() -> Coordinator {
        // Coordinator is created by StreamSession
        return Coordinator(cameraId: session.cameraId, onCleanup: {})
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let cameraId: String
        let onCleanup: () -> Void
        private var isActive = true
        
        init(cameraId: String, onCleanup: @escaping () -> Void) {
            self.cameraId = cameraId
            self.onCleanup = onCleanup
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
                </style>
            </head>
            <body>
                <video id="video" playsinline autoplay muted></video>
                <div id="live"><span class="dot"></span>LIVE</div>
                <script>
                (function() {
                    const video = document.getElementById('video');
                    const live = document.getElementById('live');
                    const streamUrl = '\(streamURL)';
                    let pc = null;
                    let cleanupDone = false;
                    
                    function cleanup() {
                        if (cleanupDone) return;
                        cleanupDone = true;
                        
                        try {
                            if (pc) {
                                pc.close();
                                pc = null;
                            }
                            if (video.srcObject) {
                                video.srcObject.getTracks().forEach(t => t.stop());
                                video.srcObject = null;
                            }
                            video.src = '';
                            video.load();
                        } catch(e) {
                            console.error('Cleanup error:', e);
                        }
                        
                        live.classList.remove('show');
                    }
                    
                    // Ensure cleanup on page unload
                    window.addEventListener('beforeunload', cleanup);
                    window.addEventListener('pagehide', cleanup);
                    
                    async function start() {
                        try {
                            pc = new RTCPeerConnection({
                                iceServers: [{ urls: 'stun:stun.l.google.com:19302' }],
                                iceTransportPolicy: 'all'
                            });
                            
                            pc.ontrack = (e) => { 
                                if (!cleanupDone) {
                                    video.srcObject = e.streams[0];
                                    live.classList.add('show');
                                }
                            };
                            
                            pc.oniceconnectionstatechange = () => {
                                const state = pc.iceConnectionState;
                                if (state === 'failed' || state === 'disconnected') {
                                    cleanup();
                                }
                            };
                            
                            pc.addTransceiver('video', { direction: 'recvonly' });
                            pc.addTransceiver('audio', { direction: 'recvonly' });
                            
                            const offer = await pc.createOffer();
                            await pc.setLocalDescription(offer);
                            
                            const controller = new AbortController();
                            setTimeout(() => controller.abort(), 8000);
                            
                            const res = await fetch(streamUrl, {
                                method: 'POST',
                                headers: { 'Content-Type': 'application/sdp' },
                                body: offer.sdp,
                                signal: controller.signal
                            });
                            
                            if (!res.ok) throw new Error('Server error: ' + res.status);
                            
                            const answer = await res.text();
                            if (!cleanupDone) {
                                await pc.setRemoteDescription({ type: 'answer', sdp: answer });
                            }
                        } catch(err) {
                            console.error('Stream error:', err);
                            cleanup();
                        }
                    }
                    
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
            
            DebugLogger.shared.log("🧹 Coordinator cleanup: \(cameraId)", emoji: "🧹", color: .gray)
            onCleanup()
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
        
        deinit {
            cleanup()
        }
    }
}

// MARK: - Enhanced Fullscreen Player with Auto-Restart
struct FullscreenPlayerView: View {
    let camera: Camera
    @Environment(\.presentationMode) var presentationMode
    
    @StateObject private var session: StreamSession
    @StateObject private var memoryMonitor = MemoryMonitor.shared
    
    @State private var showControls = true
    @State private var isRestarting = false
    
    init(camera: Camera) {
        self.camera = camera
        _session = StateObject(wrappedValue: StreamSession(
            cameraId: camera.id,
            streamURL: camera.webrtcStreamURL ?? ""
        ))
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if isRestarting {
                restartingView
            } else {
                WebRTCPlayerView(session: session, isFullscreen: true)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation { showControls.toggle() }
                    }
            }
            
            if showControls {
                controlsOverlay
            }
            
            if memoryMonitor.isMemoryWarning {
                memoryWarningOverlay
            }
        }
        .navigationBarHidden(true)
        .statusBar(hidden: !showControls)
        .onChange(of: session.needsRestart) { needs in
            if needs {
                performRestart()
            }
        }
        .onDisappear {
            session.stop()
        }
    }
    
    private var controlsOverlay: some View {
        VStack {
            HStack {
                Button(action: {
                    session.stop()
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Back").font(.headline)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(10)
                }
                
                Spacer()
                
                // Restart countdown
                if session.secondsRemaining > 0 {
                    Text(formatTime(session.secondsRemaining))
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.orange.opacity(0.8))
                        .cornerRadius(8)
                }
                
                // Manual restart button
                Button(action: { performRestart() }) {
                    Image(systemName: "arrow.clockwise")
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
    
    private var restartingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.5)
            
            Text("Restarting stream...")
                .font(.headline)
                .foregroundColor(.white)
        }
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
                    
                    Text("High Memory")
                        .font(.caption)
                        .foregroundColor(.white)
                    
                    Text("\(Int(memoryMonitor.currentMemoryMB)) MB")
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
    
    private func performRestart() {
        isRestarting = true
        
        // Stop current session
        session.stop()
        
        // Wait for cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            // Start new session
            _ = session.start()
            isRestarting = false
        }
    }
    
    private func formatTime(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Enhanced Thumbnail Cache Manager
extension ThumbnailCacheManager {
    func emergencyCleanup() {
        lock.lock()
        
        // Cancel all captures
        captureTimeouts.values.forEach { $0.cancel() }
        captureTimeouts.removeAll()
        
        // Destroy WebViews
        let webViewsToDestroy = Array(activeWebViews)
        activeWebViews.removeAll()
        
        loadingCameras.removeAll()
        isCapturing = false
        
        lock.unlock()
        
        DispatchQueue.main.async {
            webViewsToDestroy.forEach { webView in
                self.destroyWebViewAggressively(webView)
            }
        }
        
        // Clear memory cache
        cache.removeAllObjects()
        thumbnails.removeAll()
        
        autoreleasepool {}
        
        DebugLogger.shared.log("🧹 Emergency thumbnail cleanup complete", emoji: "🧹", color: .orange)
    }
}

// MARK: - App Delegate for Background Handling
class AppDelegate: NSObject, UIApplicationDelegate {
    func applicationDidEnterBackground(_ application: UIApplication) {
        DebugLogger.shared.log("📱 App entering background - cleanup", emoji: "📱", color: .orange)
        
        // Stop all streams
        PlayerManager.shared.emergencyCleanup()
        
        // Stop thumbnail captures
        ThumbnailCacheManager.shared.emergencyCleanup()
        
        // Clear URL cache
        URLCache.shared.removeAllCachedResponses()
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        DebugLogger.shared.log("📱 App entering foreground", emoji: "📱", color: .green)
        
        // Force reconnect WebSocket
        if AuthManager.shared.isAuthenticated {
            WebSocketService.shared.reconnect()
        }
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        DebugLogger.shared.log("🛑 App terminating - final cleanup", emoji: "🛑", color: .red)
        
        PlayerManager.shared.emergencyCleanup()
        ThumbnailCacheManager.shared.emergencyCleanup()
        WebViewPool.shared.destroyAll()
    }
}

// MARK: - Enhanced App with Lifecycle Management
@main
struct ICCCAlertApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var authManager = AuthManager.shared
    @StateObject private var webSocketService = WebSocketService.shared
    @StateObject private var subscriptionManager = SubscriptionManager.shared
    @StateObject private var memoryMonitor = MemoryMonitor.shared
    
    @Environment(\.scenePhase) var scenePhase
    
    var body: some Scene {
        WindowGroup {
            if authManager.isAuthenticated {
                ContentView()
                    .environmentObject(authManager)
                    .environmentObject(webSocketService)
                    .environmentObject(subscriptionManager)
            } else {
                LoginView()
                    .environmentObject(authManager)
            }
        }
        .onChange(of: scenePhase) { newPhase in
            handleScenePhaseChange(newPhase)
        }
    }
    
    private func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            DebugLogger.shared.log("📱 App active", emoji: "📱", color: .green)
            
        case .inactive:
            DebugLogger.shared.log("📱 App inactive - cleanup", emoji: "📱", color: .orange)
            PlayerManager.shared.clearAll()
            
        case .background:
            DebugLogger.shared.log("📱 App background - aggressive cleanup", emoji: "📱", color: .red)
            PlayerManager.shared.emergencyCleanup()
            ThumbnailCacheManager.shared.emergencyCleanup()
            
        @unknown default:
            break
        }
    }
}