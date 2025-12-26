import SwiftUI
import WebKit

// MARK: - Fixed Stable WebView HLS Player
struct WebViewHLSPlayer: UIViewRepresentable {
    let streamURL: String
    let cameraName: String
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    let isFullscreen: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = false
        
        // Enable JavaScript (no deprecation warning on iOS 14+)
        if #available(iOS 14.0, *) {
            configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        }
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        
        // Add message handlers
        webView.configuration.userContentController.add(context.coordinator, name: "streamReady")
        webView.configuration.userContentController.add(context.coordinator, name: "streamError")
        webView.configuration.userContentController.add(context.coordinator, name: "streamLog")
        
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        // Only load if URL changed or not loaded yet
        if context.coordinator.lastLoadedURL != streamURL {
            context.coordinator.lastLoadedURL = streamURL
            let html = generateHTML()
            webView.loadHTMLString(html, baseURL: nil)
        }
    }
    
    private func generateHTML() -> String {
        let autoplayAttr = "autoplay"
        let mutedAttr = isFullscreen ? "" : "muted"
        let controlsAttr = isFullscreen ? "controls" : ""
        let playsinlineAttr = "playsinline"
        let preloadAttr = "preload=\"auto\""
        
        let manifestTimeout = isFullscreen ? "8000" : "15000"
        let fragTimeout = isFullscreen ? "15000" : "30000"
        
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                body { 
                    background: #000;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    height: 100vh;
                    width: 100vw;
                    overflow: hidden;
                    position: fixed;
                }
                #player {
                    width: 100%;
                    height: 100%;
                    object-fit: contain;
                    background: #000;
                }
            </style>
        </head>
        <body>
            <video id="player" \(autoplayAttr) \(playsinlineAttr) \(mutedAttr) \(controlsAttr) \(preloadAttr)></video>
            <script src="https://cdn.jsdelivr.net/npm/hls.js@1.5.13/dist/hls.min.js"></script>
            <script>
                const video = document.getElementById('player');
                const videoSrc = '\(streamURL)';
                const isFullscreen = \(isFullscreen ? "true" : "false");
                
                let hls = null;
                let retryCount = 0;
                const maxRetries = 5;
                let isDestroyed = false;
                let playbackStallTimer = null;
                let lastPlaybackTime = 0;
                let stallCheckCount = 0;
                
                function log(msg) {
                    console.log(msg);
                    try {
                        window.webkit.messageHandlers.streamLog.postMessage(msg);
                    } catch(e) {}
                }
                
                function cleanup() {
                    if (playbackStallTimer) clearInterval(playbackStallTimer);
                    if (hls) {
                        log('🧹 Cleaning up HLS instance');
                        try {
                            hls.destroy();
                        } catch(e) {
                            log('⚠️ Error destroying HLS: ' + e.message);
                        }
                        hls = null;
                    }
                }
                
                function startStallDetection() {
                    if (playbackStallTimer) clearInterval(playbackStallTimer);
                    const checkInterval = isFullscreen ? 5000 : 10000;
                    
                    playbackStallTimer = setInterval(() => {
                        if (isDestroyed || !video || video.paused) return;
                        
                        const currentTime = video.currentTime;
                        if (currentTime > 0 && currentTime === lastPlaybackTime) {
                            stallCheckCount++;
                            if (stallCheckCount >= 2) {
                                log('⚠️ PLAYBACK STALLED! Attempting recovery...');
                                if (hls) {
                                    hls.stopLoad();
                                    setTimeout(() => {
                                        if (hls && !isDestroyed) {
                                            hls.startLoad(-1);
                                            video.play().catch(e => log('Stall recovery play failed: ' + e.message));
                                        }
                                    }, 500);
                                }
                                stallCheckCount = 0;
                            }
                        } else {
                            stallCheckCount = 0;
                        }
                        lastPlaybackTime = currentTime;
                    }, checkInterval);
                }
                
                function initPlayer() {
                    if (isDestroyed) return;
                    cleanup();
                    
                    log('🎬 Initializing player: ' + videoSrc);
                    
                    if (Hls.isSupported()) {
                        hls = new Hls({
                            debug: false,
                            enableWorker: true,
                            lowLatencyMode: false,
                            backBufferLength: 90,
                            maxBufferLength: isFullscreen ? 40 : 20,
                            maxMaxBufferLength: isFullscreen ? 80 : 40,
                            maxBufferSize: 80 * 1000 * 1000,
                            maxBufferHole: 0.5,
                            highBufferWatchdogPeriod: 3,
                            nudgeOffset: 0.1,
                            nudgeMaxRetry: 10,
                            maxFragLookUpTolerance: 0.25,
                            liveSyncDurationCount: 3,
                            liveMaxLatencyDurationCount: isFullscreen ? 15 : 5,
                            liveDurationInfinity: false,
                            startLevel: -1,
                            autoStartLoad: true,
                            capLevelToPlayerSize: !isFullscreen,
                            manifestLoadingTimeOut: parseInt('\(manifestTimeout)'),
                            manifestLoadingMaxRetry: 6,
                            manifestLoadingRetryDelay: 1000,
                            levelLoadingTimeOut: parseInt('\(manifestTimeout)'),
                            levelLoadingMaxRetry: 6,
                            levelLoadingRetryDelay: 1000,
                            fragLoadingTimeOut: parseInt('\(fragTimeout)'),
                            fragLoadingMaxRetry: 10,
                            fragLoadingRetryDelay: 1000,
                            startFragPrefetch: true,
                            testBandwidth: true,
                        });
                        
                        hls.on(Hls.Events.MANIFEST_PARSED, function(event, data) {
                            log('✅ Manifest parsed');
                            startStallDetection();
                            
                            video.play()
                                .then(() => {
                                    log('▶️ Playing');
                                    window.webkit.messageHandlers.streamReady.postMessage('ready');
                                    retryCount = 0;
                                })
                                .catch(e => {
                                    log('⚠️ Play error: ' + e.message);
                                    if (retryCount < maxRetries) {
                                        retryCount++;
                                        setTimeout(() => {
                                            video.play().catch(err => log('Retry failed: ' + err.message));
                                        }, 1500);
                                    } else {
                                        window.webkit.messageHandlers.streamError.postMessage('Failed to start: ' + e.message);
                                    }
                                });
                        });
                        
                        hls.on(Hls.Events.ERROR, function(event, data) {
                            if (data.fatal) {
                                log('❌ Fatal error: ' + data.type + ' - ' + data.details);
                                
                                if (data.type === Hls.ErrorTypes.NETWORK_ERROR) {
                                    if (retryCount < maxRetries) {
                                        retryCount++;
                                        const delay = Math.min(1000 * retryCount, 5000);
                                        setTimeout(() => {
                                            if (hls && !isDestroyed) {
                                                hls.startLoad(-1);
                                                video.play().catch(e => log('Recovery failed: ' + e.message));
                                            }
                                        }, delay);
                                    } else {
                                        window.webkit.messageHandlers.streamError.postMessage('Network error');
                                    }
                                } else if (data.type === Hls.ErrorTypes.MEDIA_ERROR) {
                                    if (retryCount < maxRetries) {
                                        retryCount++;
                                        hls.recoverMediaError();
                                    } else {
                                        window.webkit.messageHandlers.streamError.postMessage('Media error');
                                    }
                                }
                            }
                        });
                        
                        hls.loadSource(videoSrc);
                        hls.attachMedia(video);
                        
                    } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
                        video.src = videoSrc;
                        video.addEventListener('loadedmetadata', function() {
                            video.play()
                                .then(() => window.webkit.messageHandlers.streamReady.postMessage('ready'))
                                .catch(e => window.webkit.messageHandlers.streamError.postMessage('Play error'));
                        });
                        video.load();
                    }
                }
                
                video.addEventListener('stalled', function() {
                    if (hls && !isDestroyed) {
                        setTimeout(() => {
                            hls.stopLoad();
                            setTimeout(() => { if (hls) hls.startLoad(-1); }, 500);
                        }, 2000);
                    }
                });
                
                initPlayer();
                
                const keepAliveInterval = isFullscreen ? 2000 : 5000;
                let keepAlive = setInterval(() => {
                    if (isDestroyed) {
                        clearInterval(keepAlive);
                        return;
                    }
                    if (video.paused && !video.ended && video.readyState >= 2) {
                        video.play().catch(e => log('Resume failed'));
                    }
                }, keepAliveInterval);
                
                window.addEventListener('beforeunload', function() {
                    isDestroyed = true;
                    if (playbackStallTimer) clearInterval(playbackStallTimer);
                    if (keepAlive) clearInterval(keepAlive);
                    cleanup();
                });
            </script>
        </body>
        </html>
        """
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: WebViewHLSPlayer
        var lastLoadedURL: String = ""
        
        init(_ parent: WebViewHLSPlayer) {
            self.parent = parent
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            DispatchQueue.main.async {
                switch message.name {
                case "streamReady":
                    self.parent.isLoading = false
                    self.parent.errorMessage = nil
                case "streamError":
                    let error = message.body as? String ?? "Stream error"
                    self.parent.isLoading = false
                    self.parent.errorMessage = error
                case "streamLog":
                    if self.parent.isFullscreen, let log = message.body as? String {
                        print("📹 [\(self.parent.cameraName)] \(log)")
                    }
                default:
                    break
                }
            }
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("📄 WebView loaded for: \(parent.cameraName)")
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.errorMessage = "Navigation failed"
                self.parent.isLoading = false
            }
        }
    }
}

// MARK: - Camera Thumbnail (Grid Preview) - MEMORY SAFE
struct CameraThumbnail: View {
    let camera: Camera
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var retryCount = 0
    @State private var loadTimer: Timer? = nil
    @State private var isActive = false
    
    var body: some View {
        ZStack {
            if let streamURL = camera.streamURL, camera.isOnline, isActive {
                WebViewHLSPlayer(
                    streamURL: streamURL,
                    cameraName: camera.displayName,
                    isLoading: $isLoading,
                    errorMessage: $errorMessage,
                    isFullscreen: false
                )
                .id("\(camera.id)-\(retryCount)")
                .onAppear {
                    isActive = true
                    loadTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { _ in
                        if isLoading && errorMessage == nil {
                            isLoading = false
                        }
                    }
                }
                .onDisappear {
                    isActive = false
                    loadTimer?.invalidate()
                    loadTimer = nil
                }
                
                if isLoading {
                    ZStack {
                        Color.black.opacity(0.7)
                        VStack(spacing: 8) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            Text("Loading...")
                                .font(.caption2)
                                .foregroundColor(.white)
                        }
                    }
                }
                
                if let error = errorMessage {
                    ZStack {
                        Color.black.opacity(0.9)
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.orange)
                            
                            Text("Stream Error")
                                .font(.caption2)
                                .foregroundColor(.white)
                            
                            Button(action: {
                                errorMessage = nil
                                isLoading = true
                                retryCount += 1
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 10))
                                    Text("Retry")
                                }
                                .font(.caption2)
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue)
                                .cornerRadius(6)
                            }
                        }
                        .padding(8)
                    }
                }
            } else {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.gray.opacity(0.3),
                        Color.gray.opacity(0.1)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                
                VStack(spacing: 8) {
                    Image(systemName: "video.slash.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.gray)
                    Text(camera.isOnline ? "No Stream" : "Offline")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            
            if camera.isOnline && !isLoading && errorMessage == nil && isActive {
                VStack {
                    HStack {
                        Spacer()
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 6, height: 6)
                            Text("LIVE")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(4)
                        .padding(6)
                    }
                    Spacer()
                }
            }
        }
    }
}

// MARK: - Fullscreen HLS Player View - SAFE VERSION
struct HLSPlayerView: View {
    let camera: Camera
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var retryCount = 0
    @State private var showControls = true
    @State private var autoHideTimer: Timer? = nil
    @State private var isPlayerActive = false
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let streamURL = camera.streamURL, isPlayerActive {
                WebViewHLSPlayer(
                    streamURL: streamURL,
                    cameraName: camera.displayName,
                    isLoading: $isLoading,
                    errorMessage: $errorMessage,
                    isFullscreen: true
                )
                .id("fullscreen-\(camera.id)-\(retryCount)")
                .ignoresSafeArea()
                .onAppear {
                    isPlayerActive = true
                    autoHideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
                        withAnimation {
                            showControls = false
                        }
                    }
                }
                .onDisappear {
                    isPlayerActive = false
                    autoHideTimer?.invalidate()
                    autoHideTimer = nil
                }
                .onTapGesture {
                    withAnimation {
                        showControls.toggle()
                    }
                    autoHideTimer?.invalidate()
                    if showControls {
                        autoHideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
                            withAnimation {
                                showControls = false
                            }
                        }
                    }
                }
            } else {
                errorView("Stream URL not available")
            }
            
            if isLoading {
                loadingView
            }
            
            if showControls {
                VStack {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(camera.displayName)
                                .font(.headline)
                                .foregroundColor(.white)
                            
                            HStack(spacing: 8) {
                                Text(camera.area)
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.8))
                                
                                Circle()
                                    .fill(camera.isOnline ? Color.green : Color.red)
                                    .frame(width: 8, height: 8)
                                
                                Text(camera.isOnline ? "Live" : "Offline")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.8))
                            }
                        }
                        .padding()
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(10)
                        
                        Spacer()
                        
                        Button(action: {
                            isPlayerActive = false
                            presentationMode.wrappedValue.dismiss()
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.white)
                                .padding()
                        }
                    }
                    .padding()
                    .transition(.move(edge: .top))
                    
                    Spacer()
                }
            }
            
            if let error = errorMessage {
                errorView(error)
            }
        }
        .navigationBarHidden(true)
        .statusBar(hidden: !showControls)
        .onAppear {
            isPlayerActive = true
        }
        .onDisappear {
            isPlayerActive = false
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
            
            Text("Connecting to stream...")
                .font(.headline)
                .foregroundColor(.white)
            
            Text(camera.displayName)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.8))
    }
    
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            
            Text("Stream Error")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text(message)
                .font(.body)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            HStack(spacing: 16) {
                Button(action: {
                    errorMessage = nil
                    isLoading = true
                    retryCount += 1
                }) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Retry")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .cornerRadius(10)
                }
                
                Button(action: {
                    isPlayerActive = false
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack {
                        Image(systemName: "xmark")
                        Text("Close")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.gray)
                    .cornerRadius(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.8))
    }
}

// MARK: - Area Cameras View - SAFE VERSION
struct AreaCamerasView: View {
    let area: String
    @StateObject private var cameraManager = CameraManager.shared
    
    @State private var searchText = ""
    @State private var showOnlineOnly = false
    @State private var selectedCamera: Camera? = nil
    @State private var gridLayout: GridLayout = .grid2x2
    @State private var refreshID = UUID()
    @State private var isNavigationActive = true
    
    enum GridLayout: String, CaseIterable, Identifiable {
        case list = "List"
        case grid2x2 = "2×2 Grid"
        case grid3x3 = "3×3 Grid"
        
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
    
    var cameras: [Camera] {
        guard isNavigationActive else { return [] }
        
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
    
    var onlineCount: Int {
        cameras.filter { $0.isOnline }.count
    }
    
    var totalCount: Int {
        cameraManager.getCameras(forArea: area).count
    }
    
    var body: some View {
        VStack(spacing: 0) {
            statsBar
            filterBar
            
            if cameras.isEmpty {
                emptyView
            } else {
                cameraGridView
            }
        }
        .navigationTitle(area)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Layout", selection: $gridLayout) {
                        ForEach(GridLayout.allCases) { layout in
                            Label(layout.rawValue, systemImage: layout.icon)
                                .tag(layout)
                        }
                    }
                } label: {
                    Image(systemName: gridLayout.icon)
                        .font(.system(size: 18))
                }
            }
        }
        .fullScreenCover(item: $selectedCamera) { camera in
            HLSPlayerView(camera: camera)
        }
        .id(refreshID)
        .onAppear {
            isNavigationActive = true
            DebugLogger.shared.log("📹 AreaCamerasView appeared for \(area)", emoji: "📹", color: .blue)
            DebugLogger.shared.log("   Total cameras: \(totalCount)", emoji: "📊", color: .gray)
            DebugLogger.shared.log("   Online: \(onlineCount)", emoji: "🟢", color: .green)
        }
        .onDisappear {
            isNavigationActive = false
            DebugLogger.shared.log("📹 AreaCamerasView disappeared for \(area)", emoji: "📹", color: .gray)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CamerasUpdated"))) { _ in
            guard isNavigationActive else { return }
            DebugLogger.shared.log("🔄 AreaCamerasView: Cameras updated", emoji: "🔄", color: .blue)
            refreshID = UUID()
        }
    }

    private var statsBar: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "video.fill")
                    .foregroundColor(.blue)
                Text("\(cameras.count) \(cameras.count == 1 ? "camera" : "cameras")")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("\(onlineCount)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 8, height: 8)
                    Text("\(totalCount - onlineCount)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 2)
    }

    private var filterBar: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                
                TextField("Search cameras...", text: $searchText)
                    .textFieldStyle(PlainTextFieldStyle())
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                
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
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: gridLayout.columns),
                spacing: 12
            ) {
                ForEach(cameras) { camera in
                    CameraCard(camera: camera, layout: gridLayout)
                        .onTapGesture {
                            guard isNavigationActive else { return }
                            
                            if camera.isOnline {
                                selectedCamera = camera
                            } else {
                                DebugLogger.shared.log("⚠️ Cannot play offline camera: \(camera.displayName)", emoji: "⚠️", color: .orange)
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
            
            if !searchText.isEmpty || showOnlineOnly {
                Button(action: {
                    searchText = ""
                    showOnlineOnly = false
                }) {
                    HStack {
                        Image(systemName: "xmark.circle")
                        Text("Clear Filters")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .cornerRadius(10)
                }
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Camera Card - SAFE VERSION
struct CameraCard: View {
    let camera: Camera
    let layout: AreaCamerasView.GridLayout
    @State private var cardIsActive = true
    
    var cardHeight: CGFloat {
        switch layout {
        case .list: return 180
        case .grid2x2: return 140
        case .grid3x3: return 100
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if cardIsActive {
                CameraThumbnail(camera: camera)
                    .frame(height: cardHeight)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(camera.isOnline ? Color.blue.opacity(0.3) : Color.gray.opacity(0.3), lineWidth: 1)
                    )
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: cardHeight)
                    .cornerRadius(12)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(camera.displayName)
                    .font(layout == .list ? .body : (layout == .grid2x2 ? .caption : .caption2))
                    .fontWeight(.medium)
                    .lineLimit(layout == .grid3x3 ? 1 : 2)
                    .foregroundColor(.primary)
                
                HStack(spacing: 4) {
                    Circle()
                        .fill(camera.isOnline ? Color.green : Color.gray)
                        .frame(width: 6, height: 6)
                    
                    Text(camera.location.isEmpty ? camera.area : camera.location)
                        .font(.system(size: layout == .grid3x3 ? 9 : 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(layout == .grid3x3 ? 8 : 12)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
        .opacity(camera.isOnline ? 1 : 0.6)
        .onAppear {
            cardIsActive = true
        }
        .onDisappear {
            cardIsActive = false
        }
    }
}

// MARK: - Preview Provider
struct AreaCamerasView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            AreaCamerasView(area: "barora")
        }
    }
}