import SwiftUI
import WebKit
import Combine

// MARK: - ULTRA LOW MEMORY Stream Configuration
struct StreamConfig {
    static let maxStreamDuration: TimeInterval = 90  // 90 seconds
    static let memoryThresholdMB: Double = 120
    static let emergencyMemoryThresholdMB: Double = 150
    static let memoryCheckInterval: TimeInterval = 2.0  // Check every 2 seconds
    
    // Video quality settings
    static let videoMaxBitrate: Int = 500_000  // 500 kbps
    static let videoMaxFramerate: Int = 15  // 15 fps
}

// MARK: - Stream Session with DETAILED LOGGING
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
    
    private var isCleaningUp = false
    private var isDestroyed = false
    
    // Memory tracking
    private var baselineMemoryMB: Double = 0
    private var peakMemoryMB: Double = 0
    
    init(cameraId: String, streamURL: String) {
        self.id = UUID().uuidString
        self.cameraId = cameraId
        self.streamURL = streamURL
        
        baselineMemoryMB = getCurrentMemoryUsage()
        peakMemoryMB = baselineMemoryMB
        
        DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "🎬", color: .blue)
        DebugLogger.shared.log("🎬 StreamSession created", emoji: "🎬", color: .blue)
        DebugLogger.shared.log("   Camera: \(cameraId)", emoji: "📹", color: .gray)
        DebugLogger.shared.log("   Baseline memory: \(String(format: "%.1f", baselineMemoryMB))MB", emoji: "📊", color: .gray)
        DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "🎬", color: .blue)
    }
    
    func start() -> WKWebView {
        guard !isDestroyed else {
            DebugLogger.shared.log("❌ Cannot start destroyed session", emoji: "❌", color: .red)
            return createDummyWebView()
        }
        
        let currentMem = getCurrentMemoryUsage()
        DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "▶️", color: .green)
        DebugLogger.shared.log("▶️ Starting stream", emoji: "▶️", color: .green)
        DebugLogger.shared.log("   Memory before start: \(String(format: "%.1f", currentMem))MB", emoji: "📊", color: .gray)
        
        if currentMem > StreamConfig.emergencyMemoryThresholdMB {
            DebugLogger.shared.log("🚨 Memory too high to start: \(String(format: "%.1f", currentMem))MB", emoji: "🚨", color: .red)
            DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "▶️", color: .green)
            return createDummyWebView()
        }
        
        if webView != nil {
            DebugLogger.shared.log("⚠️ WebView exists - destroying first", emoji: "⚠️", color: .orange)
            immediateCleanup()
            Thread.sleep(forTimeInterval: 0.5)
        }
        
        isActive = true
        startTime = Date()
        secondsRemaining = Int(StreamConfig.maxStreamDuration)
        
        // Create WebView
        let wv = createWebView()
        self.webView = wv
        
        DebugLogger.shared.log("✅ WebView created", emoji: "✅", color: .green)
        
        // Create coordinator
        let coord = StreamCoordinator(cameraId: cameraId)
        self.coordinator = coord
        
        wv.navigationDelegate = coord
        wv.configuration.userContentController.add(coord, name: "logging")
        
        // Load player
        coord.loadLowMemoryPlayer(in: wv, streamURL: streamURL)
        
        DebugLogger.shared.log("✅ Player HTML loaded", emoji: "✅", color: .green)
        
        // Setup timers
        setupRestartTimer()
        setupMemoryMonitoring()
        
        let memAfterCreate = getCurrentMemoryUsage()
        DebugLogger.shared.log("📊 Memory after WebView: \(String(format: "%.1f", memAfterCreate))MB (+\(String(format: "%.1f", memAfterCreate - currentMem))MB)", emoji: "📊", color: .blue)
        DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "▶️", color: .green)
        
        return wv
    }
    
    private func createWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.suppressesIncrementalRendering = true
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.backgroundColor = .black
        webView.isOpaque = true
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
        
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.startTime else { return }
            
            let elapsed = Date().timeIntervalSince(startTime)
            let remaining = Int(StreamConfig.maxStreamDuration - elapsed)
            
            DispatchQueue.main.async {
                self.secondsRemaining = max(0, remaining)
            }
        }
        
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
        
        // Track peak
        if usedMemoryMB > peakMemoryMB {
            peakMemoryMB = usedMemoryMB
        }
        
        // Update global monitor
        DispatchQueue.main.async {
            MemoryMonitor.shared.currentMemoryMB = usedMemoryMB
        }
        
        // Log every 10 seconds
        if let startTime = startTime {
            let elapsed = Int(Date().timeIntervalSince(startTime))
            if elapsed % 10 == 0 && elapsed > 0 {
                DebugLogger.shared.log("📊 Stream @\(elapsed)s: \(String(format: "%.1f", usedMemoryMB))MB (peak: \(String(format: "%.1f", peakMemoryMB))MB, growth: +\(String(format: "%.1f", memoryGrowth))MB)", emoji: "📊", color: .blue)
            }
        }
        
        // Emergency stop at 150MB
        if usedMemoryMB > StreamConfig.emergencyMemoryThresholdMB {
            DebugLogger.shared.log("🚨 EMERGENCY: \(String(format: "%.1f", usedMemoryMB))MB (growth: +\(String(format: "%.1f", memoryGrowth))MB) - FORCE STOP", emoji: "🚨", color: .red)
            
            DispatchQueue.main.async {
                self.emergencyStop()
            }
            return
        }
        
        // Regular restart at 120MB
        if usedMemoryMB > StreamConfig.memoryThresholdMB {
            DebugLogger.shared.log("⚠️ Memory high: \(String(format: "%.1f", usedMemoryMB))MB (growth: +\(String(format: "%.1f", memoryGrowth))MB) - Triggering restart", emoji: "⚠️", color: .orange)
            
            DispatchQueue.main.async {
                self.triggerRestart()
            }
        }
    }
    
    private func emergencyStop() {
        DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "🚨", color: .red)
        DebugLogger.shared.log("🚨 EMERGENCY STOP", emoji: "🚨", color: .red)
        DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "🚨", color: .red)
        
        immediateCleanup()
        
        for _ in 0..<5 {
            autoreleasepool {}
        }
        
        URLCache.shared.removeAllCachedResponses()
        
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
        
        let memBeforeStop = getCurrentMemoryUsage()
        DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "⏹️", color: .orange)
        DebugLogger.shared.log("⏹️ Stopping stream", emoji: "⏹️", color: .orange)
        DebugLogger.shared.log("   Memory before stop: \(String(format: "%.1f", memBeforeStop))MB", emoji: "📊", color: .gray)
        DebugLogger.shared.log("   Peak memory: \(String(format: "%.1f", peakMemoryMB))MB", emoji: "📊", color: .gray)
        DebugLogger.shared.log("   Total growth: +\(String(format: "%.1f", peakMemoryMB - baselineMemoryMB))MB", emoji: "📊", color: .gray)
        
        immediateCleanup()
        
        let memAfterStop = getCurrentMemoryUsage()
        DebugLogger.shared.log("   Memory after stop: \(String(format: "%.1f", memAfterStop))MB", emoji: "📊", color: .gray)
        DebugLogger.shared.log("   Freed: \(String(format: "%.1f", memBeforeStop - memAfterStop))MB", emoji: "📊", color: .green)
        DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "⏹️", color: .orange)
    }
    
    private func immediateCleanup() {
        guard !isCleaningUp else { return }
        isCleaningUp = true
        
        isActive = false
        
        restartTimer?.invalidate()
        countdownTimer?.invalidate()
        memoryCheckTimer?.invalidate()
        
        restartTimer = nil
        countdownTimer = nil
        memoryCheckTimer = nil
        
        if let coord = coordinator {
            if let wv = webView {
                wv.configuration.userContentController.removeScriptMessageHandler(forName: "logging")
            }
            coord.cleanup()
        }
        coordinator = nil
        
        if let wv = webView {
            destroyWebViewUltraAggressive(wv)
        }
        webView = nil
        startTime = nil
        
        for _ in 0..<3 {
            autoreleasepool {}
        }
        
        isCleaningUp = false
    }
    
    private func destroyWebViewUltraAggressive(_ webView: WKWebView) {
        DebugLogger.shared.log("🧹 Destroying WebView", emoji: "🧹", color: .gray)
        
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        
        let cleanupJS = """
        (function() {
            try {
                document.querySelectorAll('video, audio').forEach(el => {
                    el.pause();
                    el.src = '';
                    el.load();
                    if (el.srcObject) {
                        el.srcObject.getTracks().forEach(t => t.stop());
                        el.srcObject = null;
                    }
                });
                
                if (window.pc) {
                    window.pc.close();
                    window.pc = null;
                }
                
                document.body.innerHTML = '';
                
                if (window.gc) window.gc();
            } catch(e) {}
        })();
        """
        
        webView.evaluateJavaScript(cleanupJS, completionHandler: nil)
        webView.loadHTMLString("", baseURL: nil)
        webView.removeFromSuperview()
        
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let dataStore = WKWebsiteDataStore.nonPersistent()
        dataStore.removeData(
            ofTypes: dataTypes,
            modifiedSince: Date(timeIntervalSince1970: 0)
        ) {}
        
        for _ in 0..<3 {
            autoreleasepool {}
        }
    }
    
    deinit {
        DebugLogger.shared.log("♻️ StreamSession deinit", emoji: "♻️", color: .gray)
        
        isDestroyed = true
        
        if !isCleaningUp {
            immediateCleanup()
        }
    }
}

// MARK: - Stream Coordinator
class StreamCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let cameraId: String
    private var isActive = true
    
    init(cameraId: String) {
        self.cameraId = cameraId
    }
    
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
                
                console.log('🎬 Player initialized');
                
                function cleanup() {
                    if (cleanupDone) return;
                    cleanupDone = true;
                    
                    console.log('🧹 Cleanup started');
                    
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
                    } catch(e) {
                        console.error('Cleanup error:', e);
                    }
                    
                    live.classList.remove('show');
                    
                    if (window.gc) window.gc();
                    
                    console.log('✅ Cleanup done');
                }
                
                window.addEventListener('beforeunload', cleanup);
                window.addEventListener('pagehide', cleanup);
                
                async function start() {
                    try {
                        console.log('🔄 Creating RTCPeerConnection');
                        
                        window.pc = new RTCPeerConnection({
                            iceServers: [{ urls: 'stun:stun.l.google.com:19302' }],
                            bundlePolicy: 'max-bundle',
                            rtcpMuxPolicy: 'require'
                        });
                        
                        window.pc.ontrack = (e) => { 
                            if (!cleanupDone) {
                                console.log('✅ Track received');
                                video.srcObject = e.streams[0];
                                live.classList.add('show');
                            }
                        };
                        
                        window.pc.oniceconnectionstatechange = () => {
                            const state = window.pc.iceConnectionState;
                            console.log('ICE state:', state);
                            if (state === 'failed' || state === 'disconnected' || state === 'closed') {
                                cleanup();
                            }
                        };
                        
                        const videoTransceiver = window.pc.addTransceiver('video', { 
                            direction: 'recvonly'
                        });
                        
                        const sender = videoTransceiver.sender;
                        if (sender && sender.setParameters) {
                            const params = sender.getParameters();
                            if (params.encodings && params.encodings[0]) {
                                params.encodings[0].maxBitrate = \(StreamConfig.videoMaxBitrate);
                                params.encodings[0].maxFramerate = \(StreamConfig.videoMaxFramerate);
                                sender.setParameters(params);
                                console.log('✅ Quality settings applied: 500kbps, 15fps');
                            }
                        }
                        
                        window.pc.addTransceiver('audio', { direction: 'recvonly' });
                        
                        const offer = await window.pc.createOffer();
                        await window.pc.setLocalDescription(offer);
                        
                        console.log('📤 Sending offer to:', streamUrl);
                        
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
                        console.log('📥 Received answer');
                        
                        if (!cleanupDone) {
                            await window.pc.setRemoteDescription({ type: 'answer', sdp: answer });
                            console.log('✅ Stream connected');
                        }
                    } catch(err) {
                        console.error('❌ Stream error:', err);
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
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DebugLogger.shared.log("✅ WebView navigation finished", emoji: "✅", color: .green)
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DebugLogger.shared.log("❌ WebView error: \(error.localizedDescription)", emoji: "❌", color: .red)
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "logging", let msg = message.body as? String {
            DebugLogger.shared.log("🌐 JS: \(msg)", emoji: "🌐", color: .gray)
        }
    }
    
    deinit {
        cleanup()
    }
}