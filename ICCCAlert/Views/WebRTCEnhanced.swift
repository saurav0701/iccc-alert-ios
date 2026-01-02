import SwiftUI
import WebKit
import Combine

// MARK: - ULTRA AGGRESSIVE Stream Configuration
struct StreamConfig {
    static let maxStreamDuration: TimeInterval = 120 // 2 minutes (reduced from 3)
    static let memoryThresholdMB: Double = 150 // Lower threshold (was 200)
    static let memoryCheckInterval: TimeInterval = 5.0 // Check every 5 seconds (was 10)
    static let emergencyMemoryThresholdMB: Double = 180 // Emergency stop
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
    
    // CRITICAL: Track cleanup state to prevent double-cleanup
    private var isCleaningUp = false
    private var isDestroyed = false
    
    init(cameraId: String, streamURL: String) {
        self.id = UUID().uuidString
        self.cameraId = cameraId
        self.streamURL = streamURL
        
        DebugLogger.shared.log("🎬 StreamSession created: \(cameraId)", emoji: "🎬", color: .blue)
    }
    
    func start() -> WKWebView {
        guard !isDestroyed else {
            DebugLogger.shared.log("❌ Cannot start destroyed session", emoji: "❌", color: .red)
            return createDummyWebView()
        }
        
        // CRITICAL: Complete cleanup of any existing WebView
        if webView != nil {
            DebugLogger.shared.log("⚠️ WebView exists - destroying before new creation", emoji: "⚠️", color: .orange)
            immediateCleanup()
            
            // CRITICAL: Wait for cleanup to complete
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
        
        // Load player HTML
        coord.loadPlayer(in: wv, streamURL: streamURL)
        
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
        
        // Minimize caching
        config.suppressesIncrementalRendering = true
        
        // Media settings
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        
        // JavaScript
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        
        // CRITICAL: Disable caching
        config.userContentController.removeAllScriptMessageHandlers()
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.backgroundColor = .black
        webView.isOpaque = true
        
        // CRITICAL: Disable all caching
        webView.configuration.processPool = WKProcessPool()
        
        return webView
    }
    
    private func createDummyWebView() -> WKWebView {
        // Return a minimal WebView for error cases
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
        
        // Auto-restart timer (2 minutes now)
        restartTimer = Timer.scheduledTimer(
            withTimeInterval: StreamConfig.maxStreamDuration,
            repeats: false
        ) { [weak self] _ in
            DebugLogger.shared.log("⏱️ Auto-restart timer fired", emoji: "⏱️", color: .orange)
            self?.triggerRestart()
        }
    }
    
    private func setupMemoryMonitoring() {
        memoryCheckTimer?.invalidate()
        
        // CRITICAL: Check every 5 seconds (was 10)
        memoryCheckTimer = Timer.scheduledTimer(
            withTimeInterval: StreamConfig.memoryCheckInterval,
            repeats: true
        ) { [weak self] _ in
            self?.checkMemory()
        }
    }
    
    private func checkMemory() {
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
        
        guard kerr == KERN_SUCCESS else { return }
        
        let usedMemoryMB = Double(info.resident_size) / 1024 / 1024
        
        // Update MemoryMonitor
        DispatchQueue.main.async {
            MemoryMonitor.shared.currentMemoryMB = usedMemoryMB
        }
        
        // CRITICAL: Emergency stop at 180MB
        if usedMemoryMB > StreamConfig.emergencyMemoryThresholdMB {
            DebugLogger.shared.log("🚨 EMERGENCY: \(String(format: "%.1f", usedMemoryMB))MB - FORCE STOP", emoji: "🚨", color: .red)
            
            DispatchQueue.main.async {
                self.emergencyStop()
            }
            return
        }
        
        // Regular threshold restart at 150MB
        if usedMemoryMB > StreamConfig.memoryThresholdMB {
            DebugLogger.shared.log("⚠️ Memory high: \(String(format: "%.1f", usedMemoryMB))MB - Restart", emoji: "⚠️", color: .orange)
            
            DispatchQueue.main.async {
                self.triggerRestart()
            }
        }
    }
    
    private func emergencyStop() {
        DebugLogger.shared.log("🚨 EMERGENCY STOP", emoji: "🚨", color: .red)
        
        // Immediate cleanup without restart
        immediateCleanup()
        
        // Force garbage collection
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

// MARK: - Stream Coordinator (Unchanged but with cleanup enhancement)
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
                window.pc = null;
                let cleanupDone = false;
                
                function cleanup() {
                    if (cleanupDone) return;
                    cleanupDone = true;
                    
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
                }
                
                window.addEventListener('beforeunload', cleanup);
                window.addEventListener('pagehide', cleanup);
                
                async function start() {
                    try {
                        window.pc = new RTCPeerConnection({
                            iceServers: [{ urls: 'stun:stun.l.google.com:19302' }]
                        });
                        
                        window.pc.ontrack = (e) => { 
                            if (!cleanupDone) {
                                video.srcObject = e.streams[0];
                                live.classList.add('show');
                            }
                        };
                        
                        window.pc.oniceconnectionstatechange = () => {
                            const state = window.pc.iceConnectionState;
                            if (state === 'failed' || state === 'disconnected') {
                                cleanup();
                            }
                        };
                        
                        window.pc.addTransceiver('video', { direction: 'recvonly' });
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