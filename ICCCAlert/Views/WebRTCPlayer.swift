import SwiftUI
import WebKit
import Combine

// MARK: - Player Manager (Crash-Proof with Limits)
class PlayerManager: ObservableObject {
    static let shared = PlayerManager()
    
    private var activePlayers: [String: WKWebView] = [:]
    private let lock = NSLock()
    private let maxPlayers = 2 // Reduced to 2 concurrent streams max
    
    private init() {}
    
    func registerPlayer(_ webView: WKWebView, for cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        // Clean up old player if exists
        if let oldPlayer = activePlayers[cameraId] {
            cleanupWebView(oldPlayer)
            activePlayers.removeValue(forKey: cameraId)
        }
        
        // Enforce strict limit
        if activePlayers.count >= maxPlayers {
            if let oldestKey = activePlayers.keys.sorted().first {
                if let oldPlayer = activePlayers.removeValue(forKey: oldestKey) {
                    cleanupWebView(oldPlayer)
                }
            }
        }
        
        activePlayers[cameraId] = webView
        print("📹 Registered: \(cameraId) (Active: \(activePlayers.count)/\(maxPlayers))")
    }
    
    private func cleanupWebView(_ webView: WKWebView) {
        DispatchQueue.main.async {
            webView.stopLoading()
            webView.loadHTMLString("", baseURL: nil)
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
        }
    }
    
    func releasePlayer(_ cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        if let webView = activePlayers.removeValue(forKey: cameraId) {
            cleanupWebView(webView)
            print("🗑️ Released: \(cameraId)")
        }
    }
    
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        
        activePlayers.forEach { cleanupWebView($0.value) }
        activePlayers.removeAll()
        print("🧹 Cleared all players")
    }
}

// MARK: - WebRTC Player View (Crash-Proof)
struct WebRTCPlayerView: UIViewRepresentable {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    
    func makeUIView(context: Context) -> WKWebView {
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
        webView.navigationDelegate = context.coordinator
        
        webView.configuration.userContentController.add(context.coordinator, name: "logging")
        
        PlayerManager.shared.registerPlayer(webView, for: cameraId)
        context.coordinator.loadPlayer(in: webView, streamURL: streamURL)
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.cleanup()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(cameraId: cameraId)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let cameraId: String
        private var retryCount = 0
        private let maxRetries = 3
        
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
                    let pc = null, restartTimeout = null, isActive = true, retryCount = 0;
                    const MAX_RETRIES = 3;
                    
                    function log(msg, isError = false) {
                        if (!isActive) return;
                        status.textContent = msg;
                        status.className = isError ? 'error' : '';
                        try { window.webkit?.messageHandlers?.logging?.postMessage(msg); } catch(e) {}
                    }
                    
                    function cleanup() {
                        if (restartTimeout) { clearTimeout(restartTimeout); restartTimeout = null; }
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
                                video.srcObject.getTracks().forEach(t => {
                                    try { t.stop(); } catch(e) {}
                                }); 
                                video.srcObject = null; 
                            } catch(e) {
                                console.error('Video cleanup error:', e);
                            }
                        }
                        live.classList.remove('show');
                    }
                    
                    async function start() {
                        if (!isActive || retryCount >= MAX_RETRIES) {
                            if (retryCount >= MAX_RETRIES) {
                                log('Max retries reached', true);
                            }
                            return;
                        }
                        
                        cleanup();
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
                                    retryCount = 0; // Reset on success
                                } 
                            };
                            
                            pc.oniceconnectionstatechange = () => {
                                if (!isActive) return;
                                if (pc.iceConnectionState === 'connected') {
                                    log('Connected'); 
                                    live.classList.add('show');
                                } else if (pc.iceConnectionState === 'failed') {
                                    log('Connection failed'); 
                                    live.classList.remove('show');
                                    retryCount++;
                                    if (isActive && retryCount < MAX_RETRIES) {
                                        restartTimeout = setTimeout(start, 3000);
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
                            await pc.setRemoteDescription({ type: 'answer', sdp: answer });
                            
                        } catch (err) {
                            log('Error: ' + err.message, true);
                            retryCount++;
                            if (isActive && retryCount < MAX_RETRIES) {
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
                    
                    window.addEventListener('beforeunload', () => { 
                        isActive = false; 
                        cleanup(); 
                    });
                    
                    start();
                })();
                </script>
            </body>
            </html>
            """
            
            webView.loadHTMLString(html, baseURL: nil)
        }
        
        func cleanup() {
            PlayerManager.shared.releasePlayer(cameraId)
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("✅ Loaded: \(cameraId)")
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("❌ Navigation Error: \(error.localizedDescription)")
            
            // Don't retry automatically on navigation failures
            if retryCount < maxRetries {
                retryCount += 1
            }
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "logging", let msg = message.body as? String {
                print("🌐 [\(cameraId)]: \(msg)")
            }
        }
    }
}

import SwiftUI

// MARK: - Camera Thumbnail (Auto-loads on appear with proper orientation)
struct CameraThumbnail: View {
    let camera: Camera
    let isGridView: Bool
    @StateObject private var thumbnailCache = ThumbnailCacheManager.shared
    @State private var isLoading = false
    @State private var hasFailed = false
    @State private var hasAttemptedLoad = false
    
    var body: some View {
        ZStack {
            if let thumbnail = thumbnailCache.getThumbnail(for: camera.id) {
                // Show cached thumbnail with proper orientation
                thumbnailImageView(thumbnail)
            } else if !camera.isOnline {
                // Offline state
                offlineView
            } else if hasFailed {
                // Failed to load
                failedView
            } else if isLoading {
                // Loading state
                loadingView
            } else {
                // Placeholder - will auto-load
                placeholderView
            }
        }
        .contentShape(Rectangle())
        .onAppear {
            // Auto-load thumbnail when view appears
            if !hasAttemptedLoad && camera.isOnline {
                loadThumbnail()
            }
        }
    }
    
    private func thumbnailImageView(_ image: UIImage) -> some View {
        // Fix orientation before displaying
        let orientedImage = fixImageOrientation(image)
        
        return Image(uiImage: orientedImage)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .clipped()
    }
    
    private var loadingView: some View {
        ZStack {
            LinearGradient(
                colors: [Color.blue.opacity(0.3), Color.blue.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            VStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                    .scaleEffect(isGridView ? 0.8 : 1.0)
                
                if !isGridView {
                    Text("Loading snapshot...")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
            }
        }
    }
    
    private var placeholderView: some View {
        ZStack {
            LinearGradient(
                colors: [Color.blue.opacity(0.3), Color.blue.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            VStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.system(size: isGridView ? 24 : 32))
                    .foregroundColor(.blue)
                
                if !isGridView {
                    Text("Loading...")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
        }
    }
    
    private var failedView: some View {
        ZStack {
            LinearGradient(
                colors: [Color.orange.opacity(0.3), Color.orange.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: isGridView ? 20 : 24))
                    .foregroundColor(.orange)
                
                if !isGridView {
                    Text("Tap to retry")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
        }
        .onTapGesture {
            hasFailed = false
            hasAttemptedLoad = false
            loadThumbnail()
        }
    }
    
    private var offlineView: some View {
        ZStack {
            LinearGradient(
                colors: [Color.gray.opacity(0.3), Color.gray.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            VStack(spacing: 6) {
                Image(systemName: "video.slash.fill")
                    .font(.system(size: isGridView ? 20 : 24))
                    .foregroundColor(.gray)
                
                Text("Offline")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
        }
    }
    
    // MARK: - Load Thumbnail
    
    private func loadThumbnail() {
        guard !isLoading, !hasAttemptedLoad, camera.isOnline else { return }
        
        hasAttemptedLoad = true
        isLoading = true
        hasFailed = false
        
        DebugLogger.shared.log("📸 Auto-loading thumbnail for: \(camera.displayName)", emoji: "📸", color: .blue)
        
        // Start loading
        thumbnailCache.fetchThumbnail(for: camera)
        
        // Timeout after 15 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
            if isLoading && thumbnailCache.getThumbnail(for: camera.id) == nil {
                isLoading = false
                hasFailed = true
                DebugLogger.shared.log("⏱️ Thumbnail load timeout for: \(camera.displayName)", emoji: "⏱️", color: .orange)
            } else {
                isLoading = false
            }
        }
    }
    
    // MARK: - Fix Image Orientation
    
    private func fixImageOrientation(_ image: UIImage) -> UIImage {
        // If image is already in correct orientation, return it
        if image.imageOrientation == .up {
            return image
        }
        
        // Normalize the image orientation
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let normalizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return normalizedImage ?? image
    }
}

// MARK: - Fullscreen Player (with Landscape Support)
struct FullscreenPlayerView: View {
    let camera: Camera
    @Environment(\.presentationMode) var presentationMode
    @State private var showControls = true
    @State private var orientation = UIDeviceOrientation.unknown
    
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
            }
            .onAppear {
                setupOrientationObserver()
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

// MARK: - Grid Modes (Unchanged)
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

// MARK: - Camera Grid Card (Unchanged)
struct CameraGridCard: View {
    let camera: Camera
    let mode: GridViewMode
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CameraThumbnail(camera: camera, isGridView: mode != .list)
                .frame(height: height)
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(camera.isOnline ? Color.blue.opacity(0.3) : Color.gray.opacity(0.3), lineWidth: 1))
            
            VStack(alignment: .leading, spacing: 4) {
                Text(camera.displayName).font(titleFont).fontWeight(.medium)
                    .lineLimit(mode == .list ? 2 : 1).foregroundColor(.primary)
                HStack(spacing: 4) {
                    Circle().fill(camera.isOnline ? Color.green : Color.gray).frame(width: dotSize, height: dotSize)
                    Text(camera.location.isEmpty ? camera.area : camera.location)
                        .font(subtitleFont).foregroundColor(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, mode == .list ? 0 : 4)
        }
        .padding(padding)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 5, y: 2)
        .opacity(camera.isOnline ? 1 : 0.6)
    }
    
    private var height: CGFloat {
        switch mode {
        case .list: return 140
        case .grid2x2: return 120
        case .grid3x3: return 100
        case .grid4x4: return 80
        }
    }
    
    private var padding: CGFloat {
        switch mode {
        case .list: return 12
        case .grid2x2: return 10
        case .grid3x3: return 8
        case .grid4x4: return 6
        }
    }
    
    private var titleFont: Font {
        switch mode {
        case .list: return .subheadline
        case .grid2x2: return .caption
        case .grid3x3: return .caption2
        case .grid4x4: return .system(size: 10)
        }
    }
    
    private var subtitleFont: Font {
        switch mode {
        case .list: return .caption
        case .grid2x2: return .caption2
        case .grid3x3: return .system(size: 10)
        case .grid4x4: return .system(size: 9)
        }
    }
    
    private var dotSize: CGFloat {
        switch mode {
        case .list: return 6
        case .grid2x2: return 5
        case .grid3x3, .grid4x4: return 4
        }
    }
}