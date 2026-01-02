import SwiftUI
import WebKit
import Combine

// MARK: - Stream Configuration
struct StreamConfig {
    static let maxStreamDuration: TimeInterval = 300 // 5 minutes - adjust per device
    static let thumbnailTimeout: TimeInterval = 8
    static let memoryThresholdMB: Double = 250 // Trigger cleanup at 250MB
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
            
            // Trigger cleanup if memory exceeds threshold
            if currentMemoryMB > StreamConfig.memoryThresholdMB {
                handleMemoryWarning()
            }
        }
    }
    
    private func handleMemoryWarning() {
        DebugLogger.shared.log("🆘 MEMORY WARNING - Cleanup triggered", emoji: "🆘", color: .red)
        
        // Stop all active streams
        PlayerManager.shared.clearAll()
        
        // Clear thumbnail cache from memory
        ThumbnailCacheManager.shared.clearChannelThumbnails()
        
        // Clear URL cache
        URLCache.shared.removeAllCachedResponses()
        
        // Destroy WebView pool
        WebViewPool.shared.destroyAll()
        
        // Reset warning after delay
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
        
        // Try to reuse from pool
        if let webView = availableWebViews.first {
            availableWebViews.removeFirst()
            activeWebViews.insert(webView)
            DebugLogger.shared.log("♻️ Reusing WebView from pool", emoji: "♻️", color: .green)
            return webView
        }
        
        // Create new if pool is empty
        let webView = createFreshWebView()
        activeWebViews.insert(webView)
        DebugLogger.shared.log("🆕 Creating new WebView", emoji: "🆕", color: .blue)
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
            // Pool is full, destroy
            destroyWebView(webView)
        }
    }
    
    func destroyAll() {
        lock.lock()
        let all = activeWebViews + availableWebViews
        activeWebViews.removeAll()
        availableWebViews.removeAll()
        lock.unlock()
        
        DebugLogger.shared.log("🧹 Destroying all WebViews in pool", emoji: "🧹", color: .red)
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
        webView.scrollView.bounces = false
        webView.backgroundColor = .black
        webView.isOpaque = true
        
        return webView
    }
    
    private func cleanWebView(_ webView: WKWebView) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    
        webView.configuration.userContentController.removeAllScriptMessageHandlers()

        webView.loadHTMLString("", baseURL: nil)
    }
    
    private func destroyWebView(_ webView: WKWebView) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()

        let dataStore = WKWebsiteDataStore.nonPersistent()
        dataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: Date(timeIntervalSince1970: 0),
            completionHandler: {}
        )
        
        DebugLogger.shared.log("🧹 WebView destroyed", emoji: "🧹", color: .gray)
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
    private var coordinator: StreamCoordinator?
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
        
        let wv = WebViewPool.shared.getWebView()
        self.webView = wv
        
        // Create coordinator
        let coord = StreamCoordinator(cameraId: cameraId)
        self.coordinator = coord

        wv.navigationDelegate = coord
        wv.configuration.userContentController.add(coord, name: "logging")
        
        coord.loadPlayer(in: wv, streamURL: streamURL)
        
        // Setup auto-restart timer
        setupRestartTimer()
        
        DebugLogger.shared.log("▶️ Stream session started: \(cameraId)", emoji: "▶️", color: .green)
        
        return wv
    }
    
    private func setupRestartTimer() {
        restartTimer?.invalidate()
        countdownTimer?.invalidate()
        
        // Countdown timer (updates UI every second)
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.startTime else { return }
            
            let elapsed = Date().timeIntervalSince(startTime)
            let remaining = Int(StreamConfig.maxStreamDuration - elapsed)
            
            self.secondsRemaining = max(0, remaining)
        }
        
        // Auto-restart timer (triggers at max duration)
        restartTimer = Timer.scheduledTimer(
            withTimeInterval: StreamConfig.maxStreamDuration,
            repeats: false
        ) { [weak self] _ in
            self?.triggerRestart()
        }
    }
    
    private func triggerRestart() {
        DebugLogger.shared.log("🔄 Auto-restart triggered: \(cameraId)", emoji: "🔄", color: .orange)
        needsRestart = true
        stop()
    }
    
    func stop() {
        DebugLogger.shared.log("⏹️ Stopping stream session: \(cameraId)", emoji: "⏹️", color: .orange)
        
        isActive = false
        restartTimer?.invalidate()
        countdownTimer?.invalidate()
        
        // Cleanup coordinator FIRST (breaks retain cycles)
        if let coord = coordinator, let wv = webView {
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "logging")
            coord.cleanup()
        }
        coordinator = nil
  
        if let wv = webView {
            WebViewPool.shared.returnWebView(wv)
        }
        webView = nil
        startTime = nil
    }
    
    deinit {
        stop()
    }
}

class StreamCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
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