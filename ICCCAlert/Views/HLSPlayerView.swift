import SwiftUI
import AVKit
import AVFoundation
import WebKit

// MARK: - Stream Type
enum StreamType: String, CaseIterable {
    case hls = "HLS"
    case webrtc = "WebRTC"
}

// MARK: - Player State
enum PlayerState {
    case loading
    case playing
    case paused
    case failed(String)
    case retrying(Int)
}

struct OptimizedHLSPlayerView: UIViewControllerRepresentable {
    let streamURL: URL
    let cameraId: String
    let autoPlay: Bool
    @Binding var playerState: PlayerState
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        controller.videoGravity = .resizeAspect
        
        DebugLogger.shared.log("🎬 Creating HLS player for: \(cameraId)", emoji: "🎬", color: .blue)
        DebugLogger.shared.log("   URL: \(streamURL.absoluteString)", emoji: "🔗", color: .blue)
        
        // ✅ FIX 1: Proper asset configuration for Low-Latency HLS
        let asset = AVURLAsset(url: streamURL, options: [
            // Critical for live streams
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
            // Allow HTTP (already in Info.plist but reinforcing)
            "AVURLAssetHTTPHeaderFieldsKey": [:] as [String: String]
        ])
        
        let playerItem = AVPlayerItem(asset: asset)
        
        // ✅ FIX 2: Configure for Low-Latency HLS (MediaMTX default)
        if #available(iOS 14.0, *) {
            // Allow low-latency mode
            playerItem.preferredMaximumResolution = .zero  // Auto-select best quality
            playerItem.startsOnFirstEligibleVariant = true
            
            // ✅ CRITICAL: Configure for live edge seeking
            playerItem.automaticallyPreservesTimeOffsetFromLive = true
            playerItem.configuredTimeOffsetFromLive = .zero  // Stay at live edge
        }
        
        // ✅ FIX 3: Relaxed buffering for live streams
        playerItem.preferredForwardBufferDuration = 2.0  // Reduced from 3.0
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        
        // ✅ FIX 4: Create player with proper configuration
        let player = AVPlayer(playerItem: playerItem)
        player.allowsExternalPlayback = false
        player.automaticallyWaitsToMinimizeStalling = true  // Changed to true
        
        // ✅ FIX 5: Configure for live playback
        if #available(iOS 15.0, *) {
            player.audiovisualBackgroundPlaybackPolicy = .pauses
        }
        
        // ✅ FIX 6: Set initial playback rate (important for live streams)
        player.rate = 1.0
        
        controller.player = player
        context.coordinator.setupObservers(player: player, controller: controller)
        
        if autoPlay {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                DebugLogger.shared.log("▶️ Starting playback: \(cameraId)", emoji: "▶️", color: .green)
                player.play()
            }
        }
        
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
    
    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        DebugLogger.shared.log("🗑️ Cleaning up player: \(coordinator.cameraId)", emoji: "🗑️", color: .gray)
        coordinator.cleanup()
        uiViewController.player?.pause()
        uiViewController.player?.replaceCurrentItem(with: nil)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(cameraId: cameraId, playerState: $playerState, streamURL: streamURL)
    }
    
    class Coordinator: NSObject {
        let cameraId: String
        let streamURL: URL
        @Binding var playerState: PlayerState
        
        private var statusObserver: NSKeyValueObservation?
        private var timeControlObserver: NSKeyValueObservation?
        private var bufferEmptyObserver: NSKeyValueObservation?
        private var likelyToKeepUpObserver: NSKeyValueObservation?
        private weak var player: AVPlayer?
        private var retryCount = 0
        private let maxRetries = 5  // Increased from 3
        private var retryTimer: Timer?
        private var stallRecoveryTimer: Timer?
        
        init(cameraId: String, playerState: Binding<PlayerState>, streamURL: URL) {
            self.cameraId = cameraId
            self._playerState = playerState
            self.streamURL = streamURL
        }
        
        func setupObservers(player: AVPlayer, controller: AVPlayerViewController) {
            self.player = player
            
            // Status observer with detailed error handling
            statusObserver = player.observe(\.currentItem?.status, options: [.new, .old]) { [weak self] player, change in
                guard let self = self, let item = player.currentItem else { return }
                
                switch item.status {
                case .readyToPlay:
                    DebugLogger.shared.log("✅ PLAYER READY: \(self.cameraId)", emoji: "✅", color: .green)
                    
                    // ✅ FIX: Check if it's a live stream
                    if item.duration.isIndefinite {
                        DebugLogger.shared.log("📡 LIVE STREAM detected", emoji: "📡", color: .blue)
                    }
                    
                    self.retryCount = 0
                    DispatchQueue.main.async {
                        self.playerState = .playing
                    }
                    
                case .failed:
                    self.handlePlayerError(item: item)
                    
                case .unknown:
                    DebugLogger.shared.log("⚠️ Player status UNKNOWN: \(self.cameraId)", emoji: "❓", color: .yellow)
                    break
                    
                @unknown default:
                    break
                }
            }
            
            // Time control observer
            timeControlObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                guard let self = self else { return }
                
                switch player.timeControlStatus {
                case .playing:
                    DebugLogger.shared.log("▶️ PLAYING: \(self.cameraId)", emoji: "▶️", color: .green)
                    DispatchQueue.main.async {
                        self.playerState = .playing
                    }
                    self.stallRecoveryTimer?.invalidate()
                    
                case .paused:
                    DebugLogger.shared.log("⏸️ PAUSED: \(self.cameraId)", emoji: "⏸️", color: .gray)
                    
                case .waitingToPlayAtSpecifiedRate:
                    DebugLogger.shared.log("🔄 BUFFERING: \(self.cameraId)", emoji: "🔄", color: .yellow)
                    if let reason = player.reasonForWaitingToPlay {
                        DebugLogger.shared.log("   Reason: \(reason.rawValue)", emoji: "💭", color: .yellow)
                    }
                    DispatchQueue.main.async {
                        self.playerState = .loading
                    }
                    
                    // ✅ FIX: Start stall recovery timer
                    self.startStallRecoveryTimer()
                    
                @unknown default:
                    break
                }
            }
            
            // Buffer observers
            bufferEmptyObserver = player.observe(\.currentItem?.isPlaybackBufferEmpty, options: [.new]) { [weak self] player, _ in
                if player.currentItem?.isPlaybackBufferEmpty == true {
                    DebugLogger.shared.log("⚠️ Buffer EMPTY: \(self?.cameraId ?? "")", emoji: "📦", color: .orange)
                    self?.startStallRecoveryTimer()
                }
            }
            
            likelyToKeepUpObserver = player.observe(\.currentItem?.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] player, _ in
                if player.currentItem?.isPlaybackLikelyToKeepUp == true {
                    DebugLogger.shared.log("✅ Likely to keep up: \(self?.cameraId ?? "")", emoji: "✅", color: .green)
                    self?.stallRecoveryTimer?.invalidate()
                }
            }
            
            // Notifications
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(playerItemFailedToPlayToEndTime),
                name: .AVPlayerItemFailedToPlayToEndTime,
                object: player.currentItem
            )
            
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(playerItemPlaybackStalled),
                name: .AVPlayerItemPlaybackStalled,
                object: player.currentItem
            )
            
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(playerItemNewErrorLogEntry),
                name: .AVPlayerItemNewErrorLogEntry,
                object: player.currentItem
            )
            
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(newAccessLogEntry),
                name: .AVPlayerItemNewAccessLogEntry,
                object: player.currentItem
            )
        }
        
        private func handlePlayerError(item: AVPlayerItem) {
            if let error = item.error as NSError? {
                DebugLogger.shared.log("❌ PLAYER FAILED: \(self.cameraId)", emoji: "❌", color: .red)
                DebugLogger.shared.log("   Error: \(error.localizedDescription)", emoji: "❌", color: .red)
                DebugLogger.shared.log("   Domain: \(error.domain)", emoji: "🔍", color: .orange)
                DebugLogger.shared.log("   Code: \(error.code)", emoji: "🔢", color: .orange)
                
                // ✅ FIX: Better error analysis
                let errorMessage = self.analyzeError(error)
                
                DispatchQueue.main.async {
                    self.playerState = .failed(errorMessage)
                }
                
                self.attemptRetry()
            }
        }
        
        private func analyzeError(_ error: NSError) -> String {
            switch error.code {
            case -1022:
                return "HTTP connection blocked. Check network settings."
            case -1003:
                return "Server not reachable. Check URL: \(streamURL.absoluteString)"
            case -1009:
                return "No internet connection"
            case -11800:
                return "Stream format not supported. MediaMTX may not be transcoding correctly."
            case -11867:
                return "Cannot decode stream. Possible codec issue with MediaMTX output."
            case -12660:
                return "Stream not available. Camera may be offline."
            case -12880:
                return "Media data corrupted. MediaMTX may be having issues."
            default:
                return error.localizedDescription
            }
        }
        
        // ✅ FIX: Stall recovery timer
        private func startStallRecoveryTimer() {
            stallRecoveryTimer?.invalidate()
            
            stallRecoveryTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                DebugLogger.shared.log("⚠️ Stall timeout - attempting recovery", emoji: "⚠️", color: .orange)
                self.recoverFromStall()
            }
        }
        
        // ✅ FIX: Smart stall recovery
        private func recoverFromStall() {
            guard let player = player, let item = player.currentItem else { return }
            
            if item.duration.isIndefinite {
                // Live stream - seek to live edge
                DebugLogger.shared.log("📡 Seeking to live edge...", emoji: "📡", color: .yellow)
                
                let seekableRanges = item.seekableTimeRanges
                if let lastRange = seekableRanges.last?.timeRangeValue {
                    let livePosition = CMTimeAdd(lastRange.start, lastRange.duration)
                    
                    player.seek(to: livePosition, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                        if finished {
                            DebugLogger.shared.log("✅ Seeked to live edge", emoji: "✅", color: .green)
                            player.play()
                        } else {
                            DebugLogger.shared.log("❌ Seek failed", emoji: "❌", color: .red)
                            self?.attemptRetry()
                        }
                    }
                } else {
                    DebugLogger.shared.log("⚠️ No seekable ranges", emoji: "⚠️", color: .orange)
                    attemptRetry()
                }
            } else {
                // VOD stream - just retry
                attemptRetry()
            }
        }
        
        @objc private func playerItemNewErrorLogEntry(notification: Notification) {
            guard let item = notification.object as? AVPlayerItem,
                  let errorLog = item.errorLog() else { return }
            
            for event in errorLog.events {
                DebugLogger.shared.log("❌ HLS Error Event:", emoji: "❌", color: .red)
                DebugLogger.shared.log("   URI: \(event.uri ?? "nil")", emoji: "🔗", color: .orange)
                DebugLogger.shared.log("   Server: \(event.serverAddress ?? "nil")", emoji: "🖥️", color: .orange)
                DebugLogger.shared.log("   Code: \(event.errorStatusCode)", emoji: "🔢", color: .orange)
                
                if let comment = event.errorComment {
                    DebugLogger.shared.log("   Comment: \(comment)", emoji: "💬", color: .orange)
                }
            }
        }
        
        @objc private func newAccessLogEntry(notification: Notification) {
            guard let item = notification.object as? AVPlayerItem,
                  let accessLog = item.accessLog() else { return }
            
            if let lastEvent = accessLog.events.last {
                DebugLogger.shared.log("📊 HLS Stats: \(cameraId)", emoji: "📊", color: .blue)
                DebugLogger.shared.log("   Bitrate: \(lastEvent.indicatedBitrate)", emoji: "📶", color: .blue)
                DebugLogger.shared.log("   Stalls: \(lastEvent.numberOfStalls)", emoji: "⏸️", color: .blue)
            }
        }
        
        @objc private func playerItemFailedToPlayToEndTime(notification: Notification) {
            if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                DebugLogger.shared.log("❌ Failed to play to end: \(error.localizedDescription)", emoji: "❌", color: .red)
                attemptRetry()
            }
        }
        
        @objc private func playerItemPlaybackStalled() {
            DebugLogger.shared.log("⚠️ Playback STALLED: \(cameraId)", emoji: "⚠️", color: .orange)
            recoverFromStall()
        }
        
        private func attemptRetry() {
            guard retryCount < maxRetries else {
                DebugLogger.shared.log("❌ MAX RETRIES (\(maxRetries)) reached: \(cameraId)", emoji: "❌", color: .red)
                DispatchQueue.main.async {
                    self.playerState = .failed("Stream unavailable after \(self.maxRetries) attempts")
                }
                return
            }
            
            retryCount += 1
            DebugLogger.shared.log("🔄 RETRY \(retryCount)/\(maxRetries): \(cameraId)", emoji: "🔄", color: .yellow)
            
            DispatchQueue.main.async {
                self.playerState = .retrying(self.retryCount)
            }
            
            retryTimer?.invalidate()
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                guard let self = self, let player = self.player else { return }
                
                DebugLogger.shared.log("🔄 Recreating player item...", emoji: "🔄", color: .yellow)
                
                let newAsset = AVURLAsset(url: self.streamURL, options: [
                    AVURLAssetPreferPreciseDurationAndTimingKey: false
                ])
                
                let newItem = AVPlayerItem(asset: newAsset)
                
                if #available(iOS 14.0, *) {
                    newItem.preferredMaximumResolution = .zero
                    newItem.startsOnFirstEligibleVariant = true
                    newItem.automaticallyPreservesTimeOffsetFromLive = true
                    newItem.configuredTimeOffsetFromLive = .zero
                }
                
                newItem.preferredForwardBufferDuration = 2.0
                newItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
                
                player.replaceCurrentItem(with: newItem)
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    player.play()
                }
            }
        }
        
        func cleanup() {
            retryTimer?.invalidate()
            stallRecoveryTimer?.invalidate()
            statusObserver?.invalidate()
            timeControlObserver?.invalidate()
            bufferEmptyObserver?.invalidate()
            likelyToKeepUpObserver?.invalidate()
            NotificationCenter.default.removeObserver(self)
        }
        
        deinit {
            cleanup()
        }
    }
}

// MARK: - WebRTC Player View with Debug Logging
struct WebRTCPlayerView: UIViewRepresentable {
    let streamURL: URL
    let cameraId: String
    @Binding var playerState: PlayerState
    
    func makeUIView(context: Context) -> WKWebView {
        DebugLogger.shared.log("🌐 Creating WebRTC player: \(cameraId)", emoji: "🌐", color: .blue)
        DebugLogger.shared.log("   URL: \(streamURL.absoluteString)", emoji: "🔗", color: .blue)
        
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.navigationDelegate = context.coordinator
        
        let request = URLRequest(url: streamURL)
        webView.load(request)
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(cameraId: cameraId, playerState: $playerState)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        let cameraId: String
        @Binding var playerState: PlayerState
        
        init(cameraId: String, playerState: Binding<PlayerState>) {
            self.cameraId = cameraId
            self._playerState = playerState
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DebugLogger.shared.log("🔄 Loading WebRTC page: \(cameraId)", emoji: "🔄", color: .yellow)
            DispatchQueue.main.async {
                self.playerState = .loading
            }
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DebugLogger.shared.log("✅ WebRTC page loaded: \(cameraId)", emoji: "✅", color: .green)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.playerState = .playing
            }
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DebugLogger.shared.log("❌ WebRTC page failed: \(error.localizedDescription)", emoji: "❌", color: .red)
            DispatchQueue.main.async {
                self.playerState = .failed(error.localizedDescription)
            }
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DebugLogger.shared.log("❌ WebRTC provisional failed: \(error.localizedDescription)", emoji: "❌", color: .red)
            DispatchQueue.main.async {
                self.playerState = .failed("Cannot connect to camera. Please check if camera is online.")
            }
        }
    }
}

// MARK: - Unified Camera Player View
struct UnifiedCameraPlayerView: View {
    let camera: Camera
    @Environment(\.presentationMode) var presentationMode
    
    @State private var streamType: StreamType = .hls
    @State private var playerState: PlayerState = .loading
    @State private var showControls = true
    @State private var hideControlsTask: DispatchWorkItem?
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            Group {
                if streamType == .hls {
                    if let urlString = camera.streamURL, let url = URL(string: urlString) {
                        OptimizedHLSPlayerView(
                            streamURL: url,
                            cameraId: camera.id,
                            autoPlay: true,
                            playerState: $playerState
                        )
                    } else {
                        errorView(message: "HLS stream URL not available")
                    }
                } else {
                    if let urlString = camera.webrtcStreamURL, let url = URL(string: urlString) {
                        WebRTCPlayerView(
                            streamURL: url,
                            cameraId: camera.id,
                            playerState: $playerState
                        )
                    } else {
                        errorView(message: "WebRTC stream URL not available")
                    }
                }
            }
            
            if case .loading = playerState {
                loadingOverlay
            } else if case .retrying(let count) = playerState {
                retryingOverlay(attempt: count)
            } else if case .failed(let message) = playerState {
                failedOverlay(message: message)
            }
            
            if showControls {
                controlsOverlay
                    .transition(.opacity)
            }
        }
        .navigationBarHidden(true)
        .onTapGesture {
            withAnimation {
                showControls.toggle()
            }
            if showControls {
                scheduleHideControls()
            }
        }
        .onAppear {
            scheduleHideControls()
            logCameraInfo()
        }
    }
    
    private func logCameraInfo() {
        DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "📹", color: .blue)
        DebugLogger.shared.log("📹 Opening Camera Player", emoji: "📹", color: .blue)
        DebugLogger.shared.log("   Name: \(camera.displayName)", emoji: "📝", color: .blue)
        DebugLogger.shared.log("   ID: \(camera.id)", emoji: "🆔", color: .blue)
        DebugLogger.shared.log("   IP: \(camera.ip.isEmpty ? "MISSING!" : camera.ip)", emoji: camera.ip.isEmpty ? "⚠️" : "🌐", color: camera.ip.isEmpty ? .red : .blue)
        DebugLogger.shared.log("   Group: \(camera.groupId)", emoji: "👥", color: .blue)
        DebugLogger.shared.log("   Area: \(camera.area)", emoji: "📍", color: .blue)
        DebugLogger.shared.log("   Status: \(camera.status)", emoji: camera.isOnline ? "🟢" : "🔴", color: camera.isOnline ? .green : .red)
        DebugLogger.shared.log("   HLS: \(camera.streamURL ?? "nil")", emoji: "🎬", color: camera.streamURL != nil ? .green : .red)
        DebugLogger.shared.log("   WebRTC: \(camera.webrtcStreamURL ?? "nil")", emoji: "🌐", color: camera.webrtcStreamURL != nil ? .green : .red)
        DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "📹", color: .blue)
    }
    
    private var loadingOverlay: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.5)
            
            Text("Connecting to camera...")
                .foregroundColor(.white)
                .font(.headline)
            
            Text(streamType == .hls ? "Loading HLS stream" : "Loading WebRTC stream")
                .foregroundColor(.white.opacity(0.7))
                .font(.caption)
        }
    }
    
    private func retryingOverlay(attempt: Int) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.5)
            
            Text("Retrying... (Attempt \(attempt)/3)")
                .foregroundColor(.white)
                .font(.headline)
            
            Text("Please wait...")
                .foregroundColor(.white.opacity(0.7))
                .font(.caption)
        }
    }
    
    private func failedOverlay(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            
            Text("Connection Failed")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text(message)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            HStack(spacing: 16) {
                if streamType == .hls && camera.webrtcStreamURL != nil {
                    Button(action: { switchToWebRTC() }) {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Try WebRTC")
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                } else if streamType == .webrtc && camera.streamURL != nil {
                    Button(action: { switchToHLS() }) {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("Try HLS")
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                }
                
                Button(action: { presentationMode.wrappedValue.dismiss() }) {
                    Text("Close")
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            }
        }
    }
    
    private var controlsOverlay: some View {
        VStack {
            HStack {
                Button(action: { presentationMode.wrappedValue.dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.white)
                        .shadow(radius: 3)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text(camera.displayName)
                        .font(.headline)
                        .foregroundColor(.white)
                        .shadow(radius: 2)
                    
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text(camera.area)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.9))
                    }
                }
                
                Spacer()
                
                if camera.webrtcStreamURL != nil && camera.streamURL != nil {
                    Menu {
                        Button(action: { switchToHLS() }) {
                            Label("HLS Stream", systemImage: "play.tv")
                        }
                        
                        Button(action: { switchToWebRTC() }) {
                            Label("WebRTC Stream", systemImage: "antenna.radiowaves.left.and.right")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: streamType == .hls ? "play.tv" : "antenna.radiowaves.left.and.right")
                            Text(streamType.rawValue)
                        }
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.8))
                        .cornerRadius(16)
                    }
                }
            }
            .padding()
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0.7), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            
            Spacer()
        }
    }
    
    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.red)
            
            Text("Stream Unavailable")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text(message)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
    
    private func switchToHLS() {
        DebugLogger.shared.log("🔄 Switching to HLS stream", emoji: "🔄", color: .blue)
        playerState = .loading
        withAnimation {
            streamType = .hls
        }
    }
    
    private func switchToWebRTC() {
        DebugLogger.shared.log("🔄 Switching to WebRTC stream", emoji: "🔄", color: .blue)
        playerState = .loading
        withAnimation {
            streamType = .webrtc
        }
    }
    
    private func scheduleHideControls() {
        hideControlsTask?.cancel()
        
        let task = DispatchWorkItem {
            withAnimation {
                showControls = false
            }
        }
        
        hideControlsTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: task)
    }
}