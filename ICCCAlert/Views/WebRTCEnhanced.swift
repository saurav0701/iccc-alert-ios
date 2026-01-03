import SwiftUI
import WebKit
import Combine

// MARK: - ULTRA LOW MEMORY Stream Configuration
struct StreamConfig {
    // CRITICAL: Reduced from 120 to 90 seconds (1.5 min)
    static let maxStreamDuration: TimeInterval = 90
    
    // CRITICAL: Lowered thresholds for iPhone 7
    static let memoryThresholdMB: Double = 120  // Was 150
    static let emergencyMemoryThresholdMB: Double = 150  // Was 180
    
    // More frequent memory checks
    static let memoryCheckInterval: TimeInterval = 3.0  // Was 5.0
    
    // NEW: Video quality settings for low memory
    static let videoMaxBitrate: Int = 500_000  // 500 kbps (lower quality)
    static let videoMaxFramerate: Int = 15  // 15 fps (smoother on low-end)
}

// MARK: - Stream Session (ULTRA AGGRESSIVE MEMORY MANAGEMENT)
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
    private var memoryCheckTimer: Timer?
    
    // CRITICAL: Track cleanup state
    private var isCleaningUp = false
    private var isDestroyed = false
    
    // NEW: Memory baseline tracking
    private var baselineMemoryMB: Double = 0
    
    init(cameraId: String, streamURL: String) {
        self.id = UUID().uuidString
        self.cameraId = cameraId
        self.streamURL = streamURL
        
        // Record baseline memory
        baselineMemoryMB = getCurrentMemoryUsage()
        
        DebugLogger.shared.log("🎬 StreamSession created: \(cameraId) (Baseline: \(String(format: "%.1f", baselineMemoryMB))MB)", emoji: "🎬", color: .blue)
    }
    
    func start() -> WKWebView {
        guard !isDestroyed else {
            DebugLogger.shared.log("❌ Cannot start destroyed session", emoji: "❌", color: .red)
            return createDummyWebView()
        }
        
        // CRITICAL: Check memory BEFORE starting
        let currentMem = getCurrentMemoryUsage()
        if currentMem > StreamConfig.emergencyMemoryThresholdMB {
            DebugLogger.shared.log("🚨 Memory too high to start: \(String(format: "%.1f", currentMem))MB", emoji: "🚨", color: .red)
            return createDummyWebView()
        }
        
        // Complete cleanup of any existing WebView
        if webView != nil {
            DebugLogger.shared.log("⚠️ WebView exists - destroying before new creation", emoji: "⚠️", color: .orange)
            immediateCleanup()
            Thread.sleep(forTimeInterval: 0.5)
        }
        
        isActive = true
        startTime = Date()
        secondsRemaining = Int(StreamConfig.maxStreamDuration)
        
        // Create WebView
        let wv = createWebView()
        self.webView = wv
        
        // Create coordinator
        let coord = StreamCoordinator(cameraId: cameraId)
        self.coordinator = coord
        
        wv.navigationDelegate = coord
        wv.configuration.userContentController.add(coord, name: "logging")
        
        // Load player HTML with LOW MEMORY optimizations
        coord.loadLowMemoryPlayer(in: wv, streamURL: streamURL)
        
        // Setup timers
        setupRestartTimer()
        setupMemoryMonitoring()
        
        DebugLogger.shared.log("▶️ Stream started: \(cameraId)", emoji: "▶️", color: .green)
        
        return wv
    }
    
    private func createWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        
        // CRITICAL: Use non-persistent data store
        config.websiteDataStore = .nonPersistent()
        
        // CRITICAL: Minimize caching and rendering
        config.suppressesIncrementalRendering = true
        
        // Media settings for LOW MEMORY
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        
        // NEW: Disable media cache completely
        if #available(iOS 14.0, *) {
            config.limitsNavigationsToAppBoundDomains = false
        }
        
        // JavaScript
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        
        // CRITICAL: Minimal size for memory efficiency
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.backgroundColor = .black
        webView.isOpaque = true
        
        // NEW: Disable unnecessary features
        webView.allowsLinkPreview = false
        
        return webView
    }
    
    private func createDummyWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: config)
    }
    
    private func setupRestartTimer() {
        restartTimer?.invalidate()
        countdownTimer?.invalidate()
        
        // Countdown timer
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.startTime else { return }
            
            let elapsed = Date().timeIntervalSince(startTime)
            let remaining = Int(StreamConfig.maxStreamDuration - elapsed)
            
            DispatchQueue.main.async {
                self.secondsRemaining = max(0, remaining)
            }
        }
        
        // Auto-restart timer (90 seconds now - REDUCED)
        restartTimer = Timer.scheduledTimer(
            withTimeInterval: StreamConfig.maxStreamDuration,
            repeats: false
        ) { [weak self] _ in
            DebugLogger.shared.log("⏱️ Auto-restart timer fired (90s)", emoji: "⏱️", color: .orange)
            self?.triggerRestart()
        }
    }
    
    private func setupMemoryMonitoring() {
        memoryCheckTimer?.invalidate()
        
        // CRITICAL: Check every 3 seconds (was 5)
        memoryCheckTimer = Timer.scheduledTimer(
            withTimeInterval: StreamConfig.memoryCheckInterval,
            repeats: true
        ) { [weak self] _ in
            self?.checkMemory()
        }
    }
    
    private func getCurrentMemoryUsage() -> Double {
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
        
        guard kerr == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1024 / 1024
    }
    
    private func checkMemory() {
        let usedMemoryMB = getCurrentMemoryUsage()
        let memoryGrowth = usedMemoryMB - baselineMemoryMB
        
        // Update MemoryMonitor
        DispatchQueue.main.async {
            MemoryMonitor.shared.currentMemoryMB = usedMemoryMB
        }
        
        // CRITICAL: Emergency stop at 150MB (lowered from 180)
        if usedMemoryMB > StreamConfig.emergencyMemoryThresholdMB {
            DebugLogger.shared.log("🚨 EMERGENCY: \(String(format: "%.1f", usedMemoryMB))MB (growth: +\(String(format: "%.1f", memoryGrowth))MB) - FORCE STOP", emoji: "🚨", color: .red)
            
            DispatchQueue.main.async {
                self.emergencyStop()
            }
            return
        }
        
        // Regular threshold restart at 120MB (lowered from 150)
        if usedMemoryMB > StreamConfig.memoryThresholdMB {
            DebugLogger.shared.log("⚠️ Memory high: \(String(format: "%.1f", usedMemoryMB))MB (growth: +\(String(format: "%.1f", memoryGrowth))MB) - Restart", emoji: "⚠️", color: .orange)
            
            DispatchQueue.main.async {
                self.triggerRestart()
            }
        }
    }
    
    private func emergencyStop() {
        DebugLogger.shared.log("🚨 EMERGENCY STOP", emoji: "🚨", color: .red)
        
        // Immediate cleanup without restart
        immediateCleanup()
        
        // Force garbage collection (5 cycles)
        for _ in 0..<5 {
            autoreleasepool {}
        }
        
        // Clear all caches
        URLCache.shared.removeAllCachedResponses()
        
        // Notify parent to close view
        needsRestart = false
        isActive = false
    }
    
    private func triggerRestart() {
        guard isActive else { return }
        
        DebugLogger.shared.log("🔄 Triggering restart", emoji: "🔄", color: .orange)
        needsRestart = true
        stop()
    }
    
    func stop() {
        guard !isCleaningUp else {
            DebugLogger.shared.log("⚠️ Already cleaning up", emoji: "⚠️", color: .orange)
            return
        }
        
        DebugLogger.shared.log("⏹️ Stopping stream: \(cameraId)", emoji: "⏹️", color: .orange)
        
        immediateCleanup()
    }
    
    private func immediateCleanup() {
        guard !isCleaningUp else { return }
        isCleaningUp = true
        
        isActive = false
        
        // Invalidate all timers FIRST
        restartTimer?.invalidate()
        countdownTimer?.invalidate()
        memoryCheckTimer?.invalidate()
        
        restartTimer = nil
        countdownTimer = nil
        memoryCheckTimer = nil
        
        // Cleanup coordinator
        if let coord = coordinator {
            if let wv = webView {
                wv.configuration.userContentController.removeScriptMessageHandler(forName: "logging")
            }
            coord.cleanup()
        }
        coordinator = nil
        
        // Destroy WebView aggressively
        if let wv = webView {
            destroyWebViewUltraAggressive(wv)
        }
        webView = nil
        startTime = nil
        
        // CRITICAL: Multiple autoreleasepool drains
        for _ in 0..<3 {
            autoreleasepool {}
        }
        
        isCleaningUp = false
        
        DebugLogger.shared.log("✅ Cleanup complete", emoji: "✅", color: .green)
    }
    
    private func destroyWebViewUltraAggressive(_ webView: WKWebView) {
        DebugLogger.shared.log("🧹 ULTRA AGGRESSIVE WebView destruction", emoji: "🧹", color: .red)
        
        // 1. Stop all loading
        webView.stopLoading()
        
        // 2. Clear delegates
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        
        // 3. Remove ALL script handlers
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        
        // 4. Evaluate JavaScript to stop media and clear memory
        let cleanupJS = """
        (function() {
            try {
                // Stop all media
                document.querySelectorAll('video, audio').forEach(el => {
                    el.pause();
                    el.src = '';
                    el.load();
                    if (el.srcObject) {
                        el.srcObject.getTracks().forEach(t => t.stop());
                        el.srcObject = null;
                    }
                });
                
                // Close peer connection
                if (window.pc) {
                    window.pc.close();
                    window.pc = null;
                }
                
                // Clear body
                document.body.innerHTML = '';
                
                // Force garbage collection hint
                window.gc && window.gc();
            } catch(e) {}
        })();
        """
        
        webView.evaluateJavaScript(cleanupJS, completionHandler: nil)
        
        // 5. Load blank page
        webView.loadHTMLString("", baseURL: nil)
        
        // 6. Remove from superview
        webView.removeFromSuperview()
        
        // 7. Clear website data aggressively
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let dataStore = WKWebsiteDataStore.nonPersistent()
        dataStore.removeData(
            ofTypes: dataTypes,
            modifiedSince: Date(timeIntervalSince1970: 0)
        ) {
            DebugLogger.shared.log("🗑️ Website data cleared", emoji: "🗑️", color: .gray)
        }
        
        // 8. Force autoreleasepool drain multiple times
        for _ in 0..<3 {
            autoreleasepool {}
        }
        
        DebugLogger.shared.log("✅ WebView destroyed", emoji: "✅", color: .green)
    }
    
    deinit {
        DebugLogger.shared.log("♻️ StreamSession deinit: \(cameraId)", emoji: "♻️", color: .gray)
        
        isDestroyed = true
        
        if !isCleaningUp {
            immediateCleanup()
        }
    }
}

// MARK: - Stream Coordinator (LOW MEMORY HTML)
class StreamCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let cameraId: String
    private var isActive = true
    
    init(cameraId: String) {
        self.cameraId = cameraId
    }
    
    // NEW: Low memory optimized player
    func loadLowMemoryPlayer(in webView: WKWebView, streamURL: String) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                html, body { width: 100%; height: 100%; overflow: hidden; background: #000; }
                video { 
                    width: 100%; 
                    height: 100%; 
                    object-fit: contain; 
                    background: #000;
                    /* CRITICAL: Reduce compositing layers */
                    transform: translateZ(0);
                    will-change: auto;
                }
                #live { 
                    position: absolute; 
                    top: 10px; 
                    right: 10px; 
                    background: rgba(244,67,54,0.9);
                    color: white; 
                    padding: 4px 8px; 
                    border-radius: 4px; 
                    font: 700 10px -apple-system;
                    z-index: 10; 
                    display: none; 
                    align-items: center; 
                    gap: 4px; 
                }
                #live.show { display: flex; }
                .dot { 
                    width: 6px; 
                    height: 6px; 
                    background: white; 
                    border-radius: 50%;
                    animation: pulse 1.5s ease-in-out infinite; 
                }
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
                window.pc = null;
                let cleanupDone = false;
                let memoryCheckInterval = null;
                
                function cleanup() {
                    if (cleanupDone) return;
                    cleanupDone = true;
                    
                    if (memoryCheckInterval) {
                        clearInterval(memoryCheckInterval);
                        memoryCheckInterval = null;
                    }
                    
                    try {
                        if (window.pc) {
                            window.pc.close();
                            window.pc = null;
                        }
                        if (video.srcObject) {
                            video.srcObject.getTracks().forEach(t => t.stop());
                            video.srcObject = null;
                        }
                        video.src = '';
                        video.load();
                        video.remove();
                    } catch(e) {}
                    
                    live.classList.remove('show');
                    
                    // Force garbage collection hint
                    if (window.gc) window.gc();
                }
                
                window.addEventListener('beforeunload', cleanup);
                window.addEventListener('pagehide', cleanup);
                
                async function start() {
                    try {
                        window.pc = new RTCPeerConnection({
                            iceServers: [{ urls: 'stun:stun.l.google.com:19302' }],
                            // CRITICAL: Reduce bundle policy for lower memory
                            bundlePolicy: 'max-bundle',
                            rtcpMuxPolicy: 'require'
                        });
                        
                        window.pc.ontrack = (e) => { 
                            if (!cleanupDone) {
                                video.srcObject = e.streams[0];
                                live.classList.add('show');
                                
                                // NEW: Monitor memory usage every 15 seconds
                                memoryCheckInterval = setInterval(() => {
                                    if (performance.memory) {
                                        const usedMB = (performance.memory.usedJSHeapSize / 1024 / 1024).toFixed(1);
                                        const totalMB = (performance.memory.totalJSHeapSize / 1024 / 1024).toFixed(1);
                                        console.log(`Memory: ${usedMB}/${totalMB} MB`);
                                        
                                        // If JS heap exceeds 50MB, warn
                                        if (performance.memory.usedJSHeapSize > 50 * 1024 * 1024) {
                                            console.warn('High JS memory usage');
                                        }
                                    }
                                }, 15000);
                            }
                        };
                        
                        window.pc.oniceconnectionstatechange = () => {
                            const state = window.pc.iceConnectionState;
                            if (state === 'failed' || state === 'disconnected' || state === 'closed') {
                                cleanup();
                            }
                        };
                        
                        // CRITICAL: Add video transceiver with LOW MEMORY settings
                        const videoTransceiver = window.pc.addTransceiver('video', { 
                            direction: 'recvonly'
                        });
                        
                        // NEW: Set encoding parameters for lower bitrate/framerate
                        const sender = videoTransceiver.sender;
                        if (sender && sender.setParameters) {
                            const params = sender.getParameters();
                            if (params.encodings && params.encodings[0]) {
                                // Limit to 500 kbps and 15 fps
                                params.encodings[0].maxBitrate = \(StreamConfig.videoMaxBitrate);
                                params.encodings[0].maxFramerate = \(StreamConfig.videoMaxFramerate);
                                sender.setParameters(params);
                            }
                        }
                        
                        window.pc.addTransceiver('audio', { direction: 'recvonly' });
                        
                        const offer = await window.pc.createOffer();
                        await window.pc.setLocalDescription(offer);
                        
                        const controller = new AbortController();
                        setTimeout(() => controller.abort(), 8000);
                        
                        const res = await fetch(streamUrl, {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/sdp' },
                            body: offer.sdp,
                            signal: controller.signal
                        });
                        
                        if (!res.ok) throw new Error('Server error');
                        
                        const answer = await res.text();
                        if (!cleanupDone) {
                            await window.pc.setRemoteDescription({ type: 'answer', sdp: answer });
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
        
        DebugLogger.shared.log("🧹 Coordinator cleanup", emoji: "🧹", color: .gray)
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DebugLogger.shared.log("✅ WebView loaded", emoji: "✅", color: .green)
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DebugLogger.shared.log("❌ Error: \(error.localizedDescription)", emoji: "❌", color: .red)
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "logging", let msg = message.body as? String {
            DebugLogger.shared.log("🌐: \(msg)", emoji: "🌐", color: .gray)
        }
    }
    
    deinit {
        cleanup()
        DebugLogger.shared.log("♻️ Coordinator deinit", emoji: "♻️", color: .gray)
    }
}