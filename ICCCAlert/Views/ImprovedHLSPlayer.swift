import SwiftUI
import AVKit
import AVFoundation
import WebKit
import Combine

// MARK: - Player Manager
class PlayerManager: ObservableObject {
    static let shared = PlayerManager()
    
    private var activePlayers: [String: Any] = [:]
    private let lock = NSLock()
    private let maxPlayers = 2
    
    private init() {}
    
    func registerPlayer(_ player: Any, for cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        if activePlayers.count >= maxPlayers {
            if let oldestKey = activePlayers.keys.first {
                releasePlayerInternal(oldestKey)
            }
        }
        
        activePlayers[cameraId] = player
        print("📹 Registered player for: \(cameraId)")
    }
    
    private func releasePlayerInternal(_ cameraId: String) {
        if let player = activePlayers.removeValue(forKey: cameraId) {
            if let avPlayer = player as? AVPlayer {
                avPlayer.pause()
                avPlayer.replaceCurrentItem(with: nil)
            } else if let webView = player as? WKWebView {
                webView.stopLoading()
                webView.loadHTMLString("", baseURL: nil)
            }
            print("🗑️ Released player: \(cameraId)")
        }
    }
    
    func releasePlayer(_ cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        releasePlayerInternal(cameraId)
    }
    
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        
        activePlayers.keys.forEach { releasePlayerInternal($0) }
        print("🧹 Cleared all players")
    }
}

// MARK: - Hybrid Player with H.264 Support
struct HybridHLSPlayer: View {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    
    @State private var playerMode: PlayerMode = .native
    @State private var hasNativeFailed = false
    @State private var showRetryButton = false
    
    enum PlayerMode {
        case native
        case webview
    }
    
    var body: some View {
        ZStack {
            if playerMode == .native && !hasNativeFailed {
                ImprovedAVPlayerView(
                    streamURL: streamURL,
                    cameraId: cameraId,
                    isFullscreen: isFullscreen,
                    onFatalError: { error in
                        print("⚠️ Native player failed: \(error), switching to WebView")
                        hasNativeFailed = true
                        playerMode = .webview
                    },
                    onRetryNeeded: {
                        showRetryButton = true
                    }
                )
            } else {
                H264WebViewPlayer(
                    streamURL: streamURL,
                    cameraId: cameraId,
                    isFullscreen: isFullscreen,
                    onRetryNeeded: {
                        showRetryButton = true
                    }
                )
            }
            
            // Retry Button Overlay
            if showRetryButton {
                VStack {
                    Spacer()
                    Button(action: {
                        retryPlayback()
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.system(size: 20))
                            Text("Retry Stream")
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.blue)
                        .cornerRadius(25)
                        .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 2)
                    }
                    .padding(.bottom, 20)
                }
            }
        }
    }
    
    private func retryPlayback() {
        showRetryButton = false
        hasNativeFailed = false
        playerMode = .native
    }
}

// MARK: - Improved AVPlayer with H.264 Support
struct ImprovedAVPlayerView: View {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    let onFatalError: (String) -> Void
    let onRetryNeeded: () -> Void
    
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var hasError = false
    @State private var errorMessage = ""
    @State private var observer: PlayerObserver?
    @State private var cancellables = Set<AnyCancellable>()
    @State private var retryCount = 0
    @State private var stallTimer: Timer?
    @State private var lastPlaybackTime: CMTime = .zero
    
    private let maxRetries = 3
    private let retryDelay: TimeInterval = 2.0
    private let stallCheckInterval: TimeInterval = 5.0
    
    var body: some View {
        ZStack {
            if let player = player {
                VideoPlayer(player: player)
                    .onAppear {
                        startStallMonitoring()
                    }
            } else {
                Color.black
            }
            
            // Loading overlay
            if isLoading && !hasError {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.2)
                    Text("Loading H.264 Stream...")
                        .font(.caption)
                        .foregroundColor(.white)
                    if retryCount > 0 {
                        Text("Retry \(retryCount)/\(maxRetries)")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                .padding(20)
                .background(Color.black.opacity(0.7))
                .cornerRadius(12)
            }
            
            // Error overlay
            if hasError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.orange)
                    
                    Text("Stream Error")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                    
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                    
                    if retryCount < maxRetries {
                        Text("Retrying...")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
                .padding(20)
                .background(Color.black.opacity(0.85))
                .cornerRadius(12)
            }
            
            // LIVE indicator
            if !isLoading && !hasError && !isFullscreen {
                VStack {
                    HStack {
                        Spacer()
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 6, height: 6)
                            Text("LIVE")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(4)
                        .padding(8)
                    }
                    Spacer()
                }
            }
        }
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            cleanup()
        }
    }
    
    private func setupPlayer() {
        guard let url = URL(string: streamURL) else {
            handleFatalError("Invalid stream URL")
            return
        }
        
        print("📹 Setting up H.264 AVPlayer for: \(cameraId)")
        
        // Configure AVPlayer for H.264 streaming
        let playerItem = AVPlayerItem(url: url)
        
        // Optimize for live streaming
        playerItem.preferredForwardBufferDuration = 3.0
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        
        let avPlayer = AVPlayer(playerItem: playerItem)
        avPlayer.allowsExternalPlayback = false
        avPlayer.automaticallyWaitsToMinimizeStalling = true
        
        // Enable audio for H.264 streams
        avPlayer.isMuted = false
        avPlayer.volume = 0.0 // Start muted, user can unmute
        
        self.player = avPlayer
        PlayerManager.shared.registerPlayer(avPlayer, for: cameraId)
        
        // Setup observer
        let newObserver = PlayerObserver()
        newObserver.onStatusChange = { status in
            handleStatusChange(status, playerItem: playerItem, player: avPlayer)
        }
        
        newObserver.onError = { error in
            handlePlaybackError(error)
        }
        
        newObserver.observe(playerItem: playerItem)
        self.observer = newObserver
        
        // Monitor playback notifications
        setupNotificationObservers(playerItem: playerItem)
        
        // Auto-play after brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.attemptPlayback(player: avPlayer)
        }
        
        // Timeout protection
        setupTimeoutProtection()
    }
    
    private func handleStatusChange(_ status: AVPlayerItem.Status, playerItem: AVPlayerItem, player: AVPlayer) {
        DispatchQueue.main.async {
            switch status {
            case .readyToPlay:
                print("✅ H.264 stream ready: \(self.cameraId)")
                self.isLoading = false
                self.hasError = false
                self.retryCount = 0
                self.attemptPlayback(player: player)
                
            case .failed:
                self.handlePlaybackError(playerItem.error)
                
            case .unknown:
                self.isLoading = true
                
            @unknown default:
                break
            }
        }
    }
    
    private func setupNotificationObservers(playerItem: AVPlayerItem) {
        // Failed to play to end time
        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: playerItem)
            .sink { notification in
                if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                    print("❌ Playback failed to end: \(error.localizedDescription)")
                    self.handlePlaybackError(error)
                }
            }
            .store(in: &cancellables)
        
        // New access log entry (successful data loading)
        NotificationCenter.default.publisher(for: .AVPlayerItemNewAccessLogEntry, object: playerItem)
            .sink { _ in
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.hasError = false
                }
            }
            .store(in: &cancellables)
        
        // Stalled playback
        NotificationCenter.default.publisher(for: .AVPlayerItemPlaybackStalled, object: playerItem)
            .sink { _ in
                print("⚠️ Playback stalled for: \(self.cameraId)")
                self.handleStall()
            }
            .store(in: &cancellables)
    }
    
    private func startStallMonitoring() {
        stallTimer?.invalidate()
        stallTimer = Timer.scheduledTimer(withTimeInterval: stallCheckInterval, repeats: true) { [self] _ in
            guard let player = self.player else { return }
            
            let currentTime = player.currentTime()
            if currentTime == self.lastPlaybackTime && player.rate == 0 {
                print("⚠️ Detected playback stall")
                self.handleStall()
            }
            self.lastPlaybackTime = currentTime
        }
    }
    
    private func handleStall() {
        guard let player = player else { return }
        
        DispatchQueue.main.async {
            // Try to resume playback
            if player.rate == 0 {
                print("🔄 Attempting to resume stalled playback")
                self.attemptPlayback(player: player)
            }
        }
    }
    
    private func attemptPlayback(player: AVPlayer) {
        player.play()
        
        // Verify playback started
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if player.rate == 0 && !self.hasError {
                print("⚠️ Playback didn't start, retrying...")
                player.play()
            }
        }
    }
    
    private func setupTimeoutProtection() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
            if self.isLoading && !self.hasError {
                print("⏱️ Playback timeout for: \(self.cameraId)")
                self.handlePlaybackError(NSError(
                    domain: "AVPlayer",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Stream timeout"]
                ))
            }
        }
    }
    
    private func handlePlaybackError(_ error: Error?) {
        DispatchQueue.main.async {
            self.isLoading = false
            self.hasError = true
            
            let nsError = error as NSError?
            let errorCode = nsError?.code ?? 0
            
            print("❌ Playback error [\(errorCode)]: \(error?.localizedDescription ?? "unknown")")
            
            // Categorize error
            let errorType = self.categorizeError(errorCode)
            self.errorMessage = self.getUserFriendlyError(errorType, code: errorCode)
            
            // Decide on retry strategy
            if self.shouldRetry(errorType) && self.retryCount < self.maxRetries {
                self.scheduleRetry()
            } else if self.shouldFallbackToWebView(errorType) {
                self.handleFatalError(self.errorMessage)
            } else {
                // Show retry button
                self.onRetryNeeded()
            }
        }
    }
    
    private enum ErrorType {
        case network
        case format
        case timeout
        case unknown
    }
    
    private func categorizeError(_ code: Int) -> ErrorType {
        switch code {
        case -1009, -1001, -1005, -1004: // Network errors
            return .network
        case -12642, -11800, -12645: // Format errors
            return .format
        case -1: // Timeout
            return .timeout
        default:
            return .unknown
        }
    }
    
    private func getUserFriendlyError(_ type: ErrorType, code: Int) -> String {
        switch type {
        case .network:
            return "Network error. Check connection."
        case .format:
            return "H.264 format issue. Trying alternative..."
        case .timeout:
            return "Stream timeout. Retrying..."
        case .unknown:
            return "Playback error [\(code)]"
        }
    }
    
    private func shouldRetry(_ type: ErrorType) -> Bool {
        switch type {
        case .network, .timeout, .unknown:
            return true
        case .format:
            return false // Format errors won't fix with retry
        }
    }
    
    private func shouldFallbackToWebView(_ type: ErrorType) -> Bool {
        return type == .format
    }
    
    private func scheduleRetry() {
        retryCount += 1
        print("🔄 Scheduling retry \(retryCount)/\(maxRetries)")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) {
            self.hasError = false
            self.cleanup()
            self.setupPlayer()
        }
    }
    
    private func handleFatalError(_ reason: String) {
        print("🔄 Fatal error, switching to WebView: \(reason)")
        cleanup()
        onFatalError(reason)
    }
    
    private func cleanup() {
        stallTimer?.invalidate()
        stallTimer = nil
        player?.pause()
        observer?.stopObserving()
        observer = nil
        cancellables.removeAll()
        player = nil
    }
}

// MARK: - H.264 WebView Player
struct H264WebViewPlayer: UIViewRepresentable {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    let onRetryNeeded: () -> Void
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.backgroundColor = .black
        webView.isOpaque = false
        webView.navigationDelegate = context.coordinator
        
        PlayerManager.shared.registerPlayer(webView, for: cameraId)
        
        loadPlayer(in: webView)
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.loadHTMLString("", baseURL: nil)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    private func loadPlayer(in webView: WKWebView) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                html, body { 
                    width: 100%; 
                    height: 100%; 
                    overflow: hidden; 
                    background: #000; 
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
                }
                #container { 
                    width: 100vw; 
                    height: 100vh; 
                    position: relative; 
                    display: flex;
                    align-items: center;
                    justify-content: center;
                }
                video { 
                    width: 100%; 
                    height: 100%; 
                    object-fit: contain; 
                    background: #000; 
                }
                #status {
                    position: absolute; 
                    bottom: 10px; 
                    left: 10px;
                    background: rgba(0,0,0,0.8); 
                    color: #4CAF50;
                    padding: 8px 12px; 
                    font-size: 11px; 
                    border-radius: 6px;
                    font-family: monospace; 
                    z-index: 10;
                    max-width: 80%;
                }
                .error { color: #ff5252; }
                .warning { color: #ffa726; }
                #loading {
                    position: absolute;
                    top: 50%;
                    left: 50%;
                    transform: translate(-50%, -50%);
                    color: white;
                    font-size: 14px;
                    display: none;
                }
                .spinner {
                    border: 3px solid rgba(255,255,255,0.3);
                    border-radius: 50%;
                    border-top: 3px solid white;
                    width: 40px;
                    height: 40px;
                    animation: spin 1s linear infinite;
                    margin: 0 auto 10px;
                }
                @keyframes spin {
                    0% { transform: rotate(0deg); }
                    100% { transform: rotate(360deg); }
                }
            </style>
        </head>
        <body>
            <div id="container">
                <video id="video" playsinline webkit-playsinline muted autoplay controls></video>
                <div id="loading">
                    <div class="spinner"></div>
                    <div>Loading H.264 Stream...</div>
                </div>
                <div id="status">Initializing WebView Player</div>
            </div>
            
            <script>
                (function() {
                    'use strict';
                    
                    const video = document.getElementById('video');
                    const status = document.getElementById('status');
                    const loading = document.getElementById('loading');
                    const streamUrl = '\(streamURL)';
                    
                    let retryCount = 0;
                    const maxRetries = 3;
                    let retryTimeout = null;
                    
                    function log(msg, type = 'info') {
                        console.log('[H.264 WebView]', msg);
                        status.textContent = msg;
                        status.className = type;
                        
                        if (type === 'error' || type === 'warning') {
                            loading.style.display = 'none';
                        }
                    }
                    
                    function showLoading(show) {
                        loading.style.display = show ? 'block' : 'none';
                    }
                    
                    function loadStream() {
                        log('Loading H.264 stream...');
                        showLoading(true);
                        
                        // Use native iOS HLS player (supports all H.264 profiles)
                        video.src = streamUrl;
                        video.load();
                        
                        // Timeout protection
                        setTimeout(() => {
                            if (video.readyState < 2) {
                                log('⏱️ Stream timeout, retrying...', 'warning');
                                retryStream();
                            }
                        }, 15000);
                    }
                    
                    function retryStream() {
                        if (retryCount >= maxRetries) {
                            log('❌ Max retries reached', 'error');
                            showLoading(false);
                            return;
                        }
                        
                        retryCount++;
                        log(`🔄 Retry ${retryCount}/${maxRetries}...`, 'warning');
                        
                        clearTimeout(retryTimeout);
                        retryTimeout = setTimeout(() => {
                            video.src = '';
                            video.load();
                            setTimeout(loadStream, 500);
                        }, 2000);
                    }
                    
                    // Event: Can play
                    video.addEventListener('canplay', function() {
                        log('✅ H.264 stream ready');
                        showLoading(false);
                        retryCount = 0;
                    });
                    
                    // Event: Playing
                    video.addEventListener('playing', function() {
                        log('▶️ Playing (H.264)');
                        showLoading(false);
                    });
                    
                    // Event: Waiting/Buffering
                    video.addEventListener('waiting', function() {
                        log('⏳ Buffering...', 'warning');
                        showLoading(true);
                    });
                    
                    // Event: Stalled
                    video.addEventListener('stalled', function() {
                        log('⚠️ Stream stalled', 'warning');
                        setTimeout(() => {
                            if (video.paused) {
                                video.play().catch(e => {
                                    log('Play error: ' + e.message, 'error');
                                });
                            }
                        }, 1000);
                    });
                    
                    // Event: Error
                    video.addEventListener('error', function(e) {
                        const errorCode = video.error ? video.error.code : 'unknown';
                        const errorMsg = getErrorMessage(errorCode);
                        log('❌ ' + errorMsg, 'error');
                        showLoading(false);
                        
                        if (shouldRetry(errorCode)) {
                            retryStream();
                        }
                    });
                    
                    function getErrorMessage(code) {
                        switch(code) {
                            case 1: return 'Playback aborted';
                            case 2: return 'Network error';
                            case 3: return 'Decode error';
                            case 4: return 'Format not supported';
                            default: return 'Error code: ' + code;
                        }
                    }
                    
                    function shouldRetry(code) {
                        // Retry on network errors, not on format errors
                        return code === 2;
                    }
                    
                    // Auto-resume on visibility change
                    document.addEventListener('visibilitychange', function() {
                        if (!document.hidden && video.paused) {
                            video.play().catch(e => console.log('Resume failed:', e));
                        }
                    });
                    
                    // Start loading
                    loadStream();
                    
                })();
            </script>
        </body>
        </html>
        """
        
        webView.loadHTMLString(html, baseURL: nil)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: H264WebViewPlayer
        
        init(_ parent: H264WebViewPlayer) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("✅ H.264 WebView loaded for: \(parent.cameraId)")
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("❌ H.264 WebView failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Player Observer
class PlayerObserver: NSObject {
    var onStatusChange: ((AVPlayerItem.Status) -> Void)?
    var onError: ((Error?) -> Void)?
    
    private var statusObservation: NSKeyValueObservation?
    
    func observe(playerItem: AVPlayerItem) {
        statusObservation = playerItem.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            DispatchQueue.main.async {
                self?.onStatusChange?(item.status)
                
                if item.status == .failed, let error = item.error {
                    self?.onError?(error)
                }
            }
        }
    }
    
    func stopObserving() {
        statusObservation?.invalidate()
        statusObservation = nil
    }
    
    deinit {
        stopObserving()
    }
}

// MARK: - Camera Thumbnail
struct CameraThumbnail: View {
    let camera: Camera
    @State private var shouldLoad = false
    
    var body: some View {
        ZStack {
            if let streamURL = camera.streamURL, camera.isOnline {
                if shouldLoad {
                    HybridHLSPlayer(
                        streamURL: streamURL,
                        cameraId: camera.id,
                        isFullscreen: false
                    )
                } else {
                    placeholderView
                }
            } else {
                offlineView
            }
        }
        .onAppear {
            shouldLoad = false
        }
        .onDisappear {
            shouldLoad = false
            PlayerManager.shared.releasePlayer(camera.id)
        }
    }
    
    private var placeholderView: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.blue.opacity(0.3),
                    Color.blue.opacity(0.1)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            VStack(spacing: 8) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.blue)
                Text("Tap to preview")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
        }
        .onTapGesture {
            shouldLoad = true
        }
    }
    
    private var offlineView: some View {
        ZStack {
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
                Text("Offline")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
    }
}

// MARK: - Fullscreen Player
struct HLSPlayerView: View {
    let camera: Camera
    @Environment(\.presentationMode) var presentationMode
    @State private var showControls = true
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let streamURL = camera.streamURL {
                HybridHLSPlayer(
                    streamURL: streamURL,
                    cameraId: camera.id,
                    isFullscreen: true
                )
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation {
                        showControls.toggle()
                    }
                }
            }
            
            // Top bar
            if showControls {
                VStack {
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
                                
                                Text("• H.264")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.8))
                            }
                        }
                        .padding()
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(10)
                        
                        Spacer()
                        
                        Button(action: {
                            PlayerManager.shared.releasePlayer(camera.id)
                            presentationMode.wrappedValue.dismiss()
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.white)
                                .padding()
                        }
                    }
                    .padding()
                    .transition(.move(edge: .top).combined(with: .opacity))
                    
                    Spacer()
                }
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .onDisappear {
            PlayerManager.shared.releasePlayer(camera.id)
        }
    }
}