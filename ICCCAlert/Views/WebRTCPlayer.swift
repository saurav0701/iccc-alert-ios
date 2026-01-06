import SwiftUI
import WebKit
import Combine

// MARK: - Enhanced Player Manager (Crash-Proof with Limits)
class PlayerManager: ObservableObject {
    static let shared = PlayerManager()
    
    private var activePlayers: [String: WKWebView] = [:]
    private let lock = NSLock()
    private let maxPlayers = 1 // Only allow 1 active player at a time
    private var isCleaningUp = false
    
    private init() {}
    
    func registerPlayer(_ webView: WKWebView, for cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        guard !isCleaningUp else {
            print("⚠️ Cleanup in progress, rejecting registration")
            return
        }
        
        // Remove old player if exists
        if let oldPlayer = activePlayers[cameraId] {
            cleanupWebView(oldPlayer)
            activePlayers.removeValue(forKey: cameraId)
        }
        
        // Clear all other players (only 1 active at a time)
        for (id, player) in activePlayers {
            cleanupWebView(player)
            activePlayers.removeValue(forKey: id)
            print("🗑️ Cleared previous player: \(id)")
        }
        
        activePlayers[cameraId] = webView
        print("📹 Registered: \(cameraId) (Total: \(activePlayers.count))")
    }
    
    private func cleanupWebView(_ webView: WKWebView) {
        DispatchQueue.main.async {
            // Stop all loading
            webView.stopLoading()
            
            // Clear content
            webView.loadHTMLString("", baseURL: nil)
            
            // Remove all script handlers
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
            
            // Clear cache
            let dataStore = WKWebsiteDataStore.default()
            let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
            let date = Date(timeIntervalSince1970: 0)
            dataStore.removeData(ofTypes: dataTypes, modifiedSince: date) { }
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
        
        guard !isCleaningUp else {
            print("⚠️ Already cleaning up")
            return
        }
        
        isCleaningUp = true
        print("🧹 Clearing all players (\(activePlayers.count))")
        
        activePlayers.forEach { (id, webView) in
            cleanupWebView(webView)
            print("🗑️ Cleared: \(id)")
        }
        activePlayers.removeAll()
        
        // Reset cleanup flag after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.lock.lock()
            self.isCleaningUp = false
            self.lock.unlock()
        }
        
        print("✅ All players cleared")
    }
    
    func getActivePlayerCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return activePlayers.count
    }
}

// MARK: - WebRTC Player View (Simplified & Crash-Proof)
struct WebRTCPlayerView: UIViewRepresentable {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        
        // Use non-persistent data store to prevent memory buildup
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
        
        // Add logging handler
        webView.configuration.userContentController.add(context.coordinator, name: "logging")
        
        // Register with PlayerManager
        PlayerManager.shared.registerPlayer(webView, for: cameraId)
        
        // Load player HTML
        loadPlayer(in: webView)
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.cleanup()
        PlayerManager.shared.releasePlayer(coordinator.cameraId)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(cameraId: cameraId)
    }
    
    private func loadPlayer(in webView: WKWebView) {
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
                let restartCount = 0;
                const MAX_RESTARTS = 3;
                
                function log(msg, isError = false) {
                    if (!isActive) return;
                    status.textContent = msg;
                    status.className = isError ? 'error' : '';
                    try { 
                        window.webkit?.messageHandlers?.logging?.postMessage(msg); 
                    } catch(e) {}
                }
                
                function cleanup() {
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
                    live.classList.remove('show');
                }
                
                async function start() {
                    if (!isActive) return;
                    
                    if (restartCount >= MAX_RESTARTS) {
                        log('Max retries reached', true);
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
                            if (isActive && e.streams && e.streams[0]) { 
                                log('Stream ready'); 
                                video.srcObject = e.streams[0];
                                restartCount = 0; // Reset on success
                            } 
                        };
                        
                        pc.oniceconnectionstatechange = () => {
                            if (!isActive) return;
                            const state = pc.iceConnectionState;
                            
                            if (state === 'connected') {
                                log('Connected'); 
                                live.classList.add('show');
                            } else if (state === 'disconnected' || state === 'failed') {
                                log('Connection lost'); 
                                live.classList.remove('show');
                                if (isActive) {
                                    restartCount++;
                                    restartTimeout = setTimeout(start, 3000);
                                }
                            } else if (state === 'closed') {
                                log('Connection closed');
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
                            body: offer.sdp,
                            signal: AbortSignal.timeout(10000) // 10s timeout
                        });
                        
                        if (!res.ok) throw new Error('Server: ' + res.status);
                        
                        const answer = await res.text();
                        await pc.setRemoteDescription({ type: 'answer', sdp: answer });
                        
                    } catch (err) {
                        log('Error: ' + err.message, true);
                        if (isActive && restartCount < MAX_RESTARTS) {
                            restartCount++;
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
                
                video.addEventListener('pause', () => {
                    setTimeout(() => { 
                        if (isActive && !video.ended && video.paused) {
                            video.play().catch(() => {});
                        } 
                    }, 100);
                });
                
                window.addEventListener('beforeunload', () => { 
                    isActive = false; 
                    cleanup(); 
                });
                
                document.addEventListener('visibilitychange', () => { 
                    if (document.hidden) {
                        // Pause when hidden to save resources
                        cleanup();
                    } else if (!video.paused || video.ended) {
                        // Resume when visible
                        start();
                    }
                });
                
                // Start playback
                start();
            })();
            </script>
        </body>
        </html>
        """
        
        webView.loadHTMLString(html, baseURL: nil)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let cameraId: String
        
        init(cameraId: String) {
            self.cameraId = cameraId
        }
        
        func cleanup() {
            print("🧹 Coordinator cleanup: \(cameraId)")
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("✅ Loaded: \(cameraId)")
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("❌ Error: \(error.localizedDescription)")
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "logging", let msg = message.body as? String {
                print("🌐 [\(cameraId)]: \(msg)")
            }
        }
    }
}

// MARK: - Camera Thumbnail (NO AUTO-LOADING - Click to View)
struct CameraThumbnail: View {
    let camera: Camera
    let isGridView: Bool
    
    var body: some View {
        ZStack {
            if camera.isOnline {
                // Show play button - NO auto-loading
                playButtonView
            } else {
                offlineView
            }
        }
    }
    
    private var playButtonView: some View {
        ZStack {
            LinearGradient(
                colors: [Color.blue.opacity(0.3), Color.blue.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            VStack(spacing: 8) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: isGridView ? 32 : 40))
                    .foregroundColor(.blue)
                
                Text("Tap to view")
                    .font(.caption)
                    .foregroundColor(.blue)
                    .fontWeight(.medium)
            }
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
                    .font(.system(size: isGridView ? 24 : 28))
                    .foregroundColor(.gray)
                
                Text("Offline")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
    }
}

// MARK: - Fullscreen Player (Single Active Player)
struct FullscreenPlayerView: View {
    let camera: Camera
    @Environment(\.presentationMode) var presentationMode
    @State private var showControls = true
    @State private var isFullscreen = false
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let url = camera.webrtcStreamURL {
                WebRTCPlayerView(streamURL: url, cameraId: camera.id, isFullscreen: true)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation { showControls.toggle() }
                    }
            }
            
            if showControls {
                controlsOverlay
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(isFullscreen)
        .onDisappear {
            // Clean up when dismissed
            PlayerManager.shared.releasePlayer(camera.id)
        }
    }
    
    private var controlsOverlay: some View {
        VStack {
            HStack {
                Button(action: {
                    PlayerManager.shared.releasePlayer(camera.id)
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Back")
                            .font(.headline)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(10)
                }
                
                Spacer()
                
                Button(action: { isFullscreen.toggle() }) {
                    Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
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
        .transition(.opacity)
    }
}

// MARK: - Grid Modes
enum GridViewMode: String, CaseIterable, Identifiable {
    case list = "List"
    case grid2x2 = "2×2"
    case grid3x3 = "3×3"
    
    var id: String { rawValue }
    
    var columns: Int {
        switch self {
        case .list: return 1
        case .grid2x2: return 2
        case .grid3x3: return 3
        }
    }
    
    var icon: String {
        switch self {
        case .list: return "list.bullet"
        case .grid2x2: return "square.grid.2x2"
        case .grid3x3: return "square.grid.3x3"
        }
    }
}

// MARK: - Area Cameras View (NO AUTO-LOADING THUMBNAILS)
struct AreaCamerasView: View {
    let area: String
    @StateObject private var cameraManager = CameraManager.shared
    @State private var searchText = ""
    @State private var showOnlineOnly = true
    @State private var gridMode: GridViewMode = .grid2x2
    @State private var selectedCamera: Camera? = nil
    @Environment(\.scenePhase) var scenePhase
    
    var cameras: [Camera] {
        var result = cameraManager.getCameras(forArea: area)
        if showOnlineOnly { 
            result = result.filter { $0.isOnline } 
        }
        if !searchText.isEmpty {
            result = result.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText) ||
                $0.location.localizedCaseInsensitiveContains(searchText)
            }
        }
        return result.sorted { $0.displayName < $1.displayName }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            statsBar
            filterBar
            cameras.isEmpty ? AnyView(emptyView) : AnyView(cameraGridView)
        }
        .navigationTitle(area)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Layout", selection: $gridMode) {
                        ForEach(GridViewMode.allCases) { mode in
                            Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                        }
                    }
                } label: {
                    Image(systemName: gridMode.icon).font(.system(size: 18))
                }
            }
        }
        .fullScreenCover(item: $selectedCamera) { camera in
            FullscreenPlayerView(camera: camera)
        }
        .onDisappear { 
            // Clean up all players when leaving this view
            PlayerManager.shared.clearAll() 
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background || phase == .inactive {
                // Clean up when app goes to background
                PlayerManager.shared.clearAll()
            }
        }
    }
    
    private var statsBar: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "video.fill")
                    .foregroundColor(.blue)
                Text("\(cameras.count) camera\(cameras.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("\(cameras.filter { $0.isOnline }.count)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 8, height: 8)
                    Text("\(cameras.filter { !$0.isOnline }.count)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .shadow(color: Color.black.opacity(0.05), radius: 2, y: 2)
    }
    
    private var filterBar: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                
                TextField("Search cameras...", text: $searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(12)
            .background(Color(.systemGray6))
            .cornerRadius(10)
            .padding(.horizontal)
            
            HStack {
                Toggle(isOn: $showOnlineOnly) {
                    HStack(spacing: 8) {
                        Image(systemName: showOnlineOnly ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(showOnlineOnly ? .green : .gray)
                        Text("Show Online Only")
                            .font(.subheadline)
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: .green))
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
    }
    
    private var cameraGridView: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: gridMode.columns),
                spacing: 12
            ) {
                ForEach(cameras, id: \.id) { camera in
                    CameraGridCard(camera: camera, mode: gridMode)
                        .onTapGesture {
                            if camera.isOnline {
                                // Clean up any existing players before opening new one
                                PlayerManager.shared.clearAll()
                                
                                // Small delay to ensure cleanup completes
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    selectedCamera = camera
                                }
                            } else {
                                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                            }
                        }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }
    
    private var emptyView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            ZStack {
                Circle()
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: 100, height: 100)
                
                Image(systemName: searchText.isEmpty ? "video.slash" : "magnifyingglass")
                    .font(.system(size: 50))
                    .foregroundColor(.gray)
            }
            
            Text(searchText.isEmpty ? "No Cameras" : "No Results")
                .font(.title2)
                .fontWeight(.bold)
            
            Text(searchText.isEmpty ? 
                 (showOnlineOnly ? "No online cameras in this area" : "No cameras found in this area") : 
                 "No cameras match your search")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Camera Grid Card
struct CameraGridCard: View {
    let camera: Camera
    let mode: GridViewMode
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Thumbnail - NO auto-loading, just placeholder
            CameraThumbnail(camera: camera, isGridView: mode != .list)
                .frame(height: height)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(camera.isOnline ? Color.blue.opacity(0.3) : Color.gray.opacity(0.3), lineWidth: 1)
                )
            
            VStack(alignment: .leading, spacing: 4) {
                Text(camera.displayName)
                    .font(titleFont)
                    .fontWeight(.medium)
                    .lineLimit(mode == .list ? 2 : 1)
                    .foregroundColor(.primary)
                
                HStack(spacing: 4) {
                    Circle()
                        .fill(camera.isOnline ? Color.green : Color.gray)
                        .frame(width: dotSize, height: dotSize)
                    
                    Text(camera.location.isEmpty ? camera.area : camera.location)
                        .font(subtitleFont)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
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
        }
    }
    
    private var padding: CGFloat {
        switch mode {
        case .list: return 12
        case .grid2x2: return 10
        case .grid3x3: return 8
        }
    }
    
    private var titleFont: Font {
        switch mode {
        case .list: return .subheadline
        case .grid2x2: return .caption
        case .grid3x3: return .caption2
        }
    }
    
    private var subtitleFont: Font {
        switch mode {
        case .list: return .caption
        case .grid2x2: return .caption2
        case .grid3x3: return .system(size: 10)
        }
    }
    
    private var dotSize: CGFloat {
        switch mode {
        case .list: return 6
        case .grid2x2: return 5
        case .grid3x3: return 4
        }
    }
}