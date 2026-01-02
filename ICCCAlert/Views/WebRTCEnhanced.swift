import SwiftUI
import WebKit
import Combine

// MARK: - Stream Configuration (ULTRA CONSERVATIVE)
struct StreamConfig {
    static let maxStreamDuration: TimeInterval = 180 // 3 minutes (reduced from 5)
    static let memoryThresholdMB: Double = 200 // Trigger cleanup at 200MB
    static let memoryCheckInterval: TimeInterval = 10.0 // Check every 10 seconds
}


// MARK: - Stream Session (CRASH PREVENTION)
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
    
    init(cameraId: String, streamURL: String) {
        self.id = UUID().uuidString
        self.cameraId = cameraId
        self.streamURL = streamURL
    }
    
    func start() -> WKWebView {
        // CRITICAL: If WebView already exists, destroy it first
        if let existingWebView = webView {
            DebugLogger.shared.log("⚠️ Destroying existing WebView before creating new one", emoji: "⚠️", color: .orange)
            destroyWebView(existingWebView)
            webView = nil
        }
        
        isActive = true
        startTime = Date()
        secondsRemaining = Int(StreamConfig.maxStreamDuration)
        
        // Create fresh WebView
        let wv = createWebView()
        self.webView = wv
        
        // Create coordinator
        let coord = StreamCoordinator(cameraId: cameraId)
        self.coordinator = coord
        
        wv.navigationDelegate = coord
        wv.configuration.userContentController.add(coord, name: "logging")
        
        coord.loadPlayer(in: wv, streamURL: streamURL)
        
        // Setup timers
        setupRestartTimer()
        setupMemoryMonitoring()
        
        DebugLogger.shared.log("▶️ Stream started: \(cameraId)", emoji: "▶️", color: .green)
        
        return wv
    }
    
    private func createWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        config.websiteDataStore = .nonPersistent()
        
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        
        // CRITICAL: Suppress rendering to save memory
        config.suppressesIncrementalRendering = true
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.backgroundColor = .black
        webView.isOpaque = true
        
        return webView
    }
    
    private func setupRestartTimer() {
        restartTimer?.invalidate()
        countdownTimer?.invalidate()
        
        // Countdown timer (updates UI)
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let startTime = self.startTime else { return }
            
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
    
    private func setupMemoryMonitoring() {
        memoryCheckTimer?.invalidate()
        
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
        
        if kerr == KERN_SUCCESS {
            let usedMemoryMB = Double(info.resident_size) / 1024 / 1024
            
            // If memory exceeds threshold during streaming, force restart
            if usedMemoryMB > StreamConfig.memoryThresholdMB {
                DebugLogger.shared.log("🚨 MEMORY CRITICAL: \(String(format: "%.1f", usedMemoryMB))MB - Force restart", emoji: "🚨", color: .red)
                triggerRestart()
            }
        }
    }
    
    private func triggerRestart() {
        DebugLogger.shared.log("🔄 Auto-restart triggered", emoji: "🔄", color: .orange)
        needsRestart = true
        stop()
    }
    
    func stop() {
        DebugLogger.shared.log("⏹️ Stopping stream: \(cameraId)", emoji: "⏹️", color: .orange)
        
        isActive = false
        
        // Invalidate all timers
        restartTimer?.invalidate()
        countdownTimer?.invalidate()
        memoryCheckTimer?.invalidate()
        
        restartTimer = nil
        countdownTimer = nil
        memoryCheckTimer = nil
        
        // Cleanup coordinator FIRST
        if let coord = coordinator, let wv = webView {
            wv.configuration.userContentController.removeScriptMessageHandler(forName: "logging")
            coord.cleanup()
        }
        coordinator = nil
        
        // Destroy WebView
        if let wv = webView {
            destroyWebView(wv)
        }
        webView = nil
        startTime = nil
        
        // Force memory release
        autoreleasepool {}
        
        DebugLogger.shared.log("✅ Stream stopped and cleaned up", emoji: "✅", color: .green)
    }
    
    private func destroyWebView(_ webView: WKWebView) {
        DebugLogger.shared.log("🧹 Destroying WebView", emoji: "🧹", color: .gray)
        
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
        
        autoreleasepool {}
    }
    
    deinit {
        stop()
        DebugLogger.shared.log("♻️ StreamSession deinitialized", emoji: "♻️", color: .gray)
    }
}

// MARK: - Stream Coordinator
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
                    } catch(e) {}
                    
                    live.classList.remove('show');
                }
                
                window.addEventListener('beforeunload', cleanup);
                window.addEventListener('pagehide', cleanup);
                
                async function start() {
                    try {
                        pc = new RTCPeerConnection({
                            iceServers: [{ urls: 'stun:stun.l.google.com:19302' }]
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
                        
                        if (!res.ok) throw new Error('Server error');
                        
                        const answer = await res.text();
                        if (!cleanupDone) {
                            await pc.setRemoteDescription({ type: 'answer', sdp: answer });
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
        DebugLogger.shared.log("♻️ Coordinator deinitialized", emoji: "♻️", color: .gray)
    }
}