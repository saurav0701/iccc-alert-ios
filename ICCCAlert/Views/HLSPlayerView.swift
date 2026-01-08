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

// MARK: - HLS Player View (Using AVPlayer)
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
        
        // Create asset with optimized settings for live streaming
        let asset = AVURLAsset(url: streamURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
            "AVURLAssetHTTPHeaderFieldsKey": [
                "Connection": "keep-alive",
                "Accept": "*/*"
            ]
        ])
        
        // Create player item with live streaming optimizations
        let playerItem = AVPlayerItem(asset: asset)
        
        // Critical: Reduce buffer duration for live streams (Android uses 3-5 seconds)
        playerItem.preferredForwardBufferDuration = 3.0
        
        // Prevent buffering when paused (saves bandwidth)
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        
        // Create player
        let player = AVPlayer(playerItem: playerItem)
        player.allowsExternalPlayback = false
        player.automaticallyWaitsToMinimizeStalling = true
        
        // IMPORTANT: For live streams, disable audio processing that can cause delays
        if #available(iOS 15.0, *) {
            player.audiovisualBackgroundPlaybackPolicy = .pauses
        }
        
        controller.player = player
        
        // Setup observers
        context.coordinator.setupObservers(player: player, controller: controller)
        
        if autoPlay {
            // Delay play slightly to ensure stream is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                player.play()
            }
        }
        
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
    
    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.cleanup()
        uiViewController.player?.pause()
        uiViewController.player?.replaceCurrentItem(with: nil)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(cameraId: cameraId, playerState: $playerState)
    }
    
    class Coordinator: NSObject {
        let cameraId: String
        @Binding var playerState: PlayerState
        
        private var statusObserver: NSKeyValueObservation?
        private var timeControlObserver: NSKeyValueObservation?
        private var bufferEmptyObserver: NSKeyValueObservation?
        private var likelyToKeepUpObserver: NSKeyValueObservation?
        private weak var player: AVPlayer?
        private var retryCount = 0
        private let maxRetries = 3
        private var retryTimer: Timer?
        
        init(cameraId: String, playerState: Binding<PlayerState>) {
            self.cameraId = cameraId
            self._playerState = playerState
        }
        
        func setupObservers(player: AVPlayer, controller: AVPlayerViewController) {
            self.player = player
            
            // Observe playback status
            statusObserver = player.observe(\.currentItem?.status, options: [.new]) { [weak self] player, _ in
                guard let self = self, let item = player.currentItem else { return }
                
                switch item.status {
                case .readyToPlay:
                    print("✅ HLS Player ready: \(self.cameraId)")
                    self.retryCount = 0
                    DispatchQueue.main.async {
                        self.playerState = .playing
                    }
                    
                case .failed:
                    if let error = item.error {
                        print("❌ HLS Player failed: \(error.localizedDescription)")
                        DispatchQueue.main.async {
                            self.playerState = .failed(error.localizedDescription)
                        }
                        self.attemptRetry()
                    }
                    
                case .unknown:
                    break
                    
                @unknown default:
                    break
                }
            }
            
            // Observe time control status (playing/paused/buffering)
            timeControlObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                switch player.timeControlStatus {
                case .playing:
                    print("▶️ Playing: \(self?.cameraId ?? "")")
                    
                case .paused:
                    print("⏸️ Paused: \(self?.cameraId ?? "")")
                    
                case .waitingToPlayAtSpecifiedRate:
                    print("🔄 Buffering: \(self?.cameraId ?? "")")
                    DispatchQueue.main.async {
                        self?.playerState = .loading
                    }
                    
                @unknown default:
                    break
                }
            }
            
            // Observe buffer empty (indicates stalling)
            bufferEmptyObserver = player.observe(\.currentItem?.isPlaybackBufferEmpty, options: [.new]) { [weak self] player, _ in
                if player.currentItem?.isPlaybackBufferEmpty == true {
                    print("⚠️ Buffer empty, stream stalling")
                }
            }
            
            // Observe likely to keep up
            likelyToKeepUpObserver = player.observe(\.currentItem?.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] player, _ in
                if player.currentItem?.isPlaybackLikelyToKeepUp == true {
                    print("✅ Stream recovered, likely to keep up")
                }
            }
            
            // Setup notifications
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
        }
        
        @objc private func playerItemFailedToPlayToEndTime(notification: Notification) {
            if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                print("❌ Failed to play to end: \(error.localizedDescription)")
                attemptRetry()
            }
        }
        
        @objc private func playerItemPlaybackStalled() {
            print("⚠️ Playback stalled for \(cameraId)")
            
            // For live streams, seek to live edge when stalled
            guard let player = player, let item = player.currentItem else { return }
            
            let seekableRanges = item.seekableTimeRanges
            if let lastRange = seekableRanges.last?.timeRangeValue {
                let livePosition = CMTimeAdd(lastRange.start, lastRange.duration)
                print("🔄 Seeking to live edge...")
                
                player.seek(to: livePosition, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                    if finished {
                        print("✅ Seeked to live edge")
                        player.play()
                    }
                }
            }
        }
        
        private func attemptRetry() {
            guard retryCount < maxRetries else {
                print("❌ Max retries reached for \(cameraId)")
                DispatchQueue.main.async {
                    self.playerState = .failed("Stream unavailable after \(self.maxRetries) attempts")
                }
                return
            }
            
            retryCount += 1
            print("🔄 Retry attempt \(retryCount)/\(maxRetries) for \(cameraId)")
            
            DispatchQueue.main.async {
                self.playerState = .retrying(self.retryCount)
            }
            
            // Wait before retrying
            retryTimer?.invalidate()
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                guard let self = self, let player = self.player else { return }
                
                // Try seeking to live edge first
                if let item = player.currentItem {
                    let seekableRanges = item.seekableTimeRanges
                    if let lastRange = seekableRanges.last?.timeRangeValue {
                        let livePosition = CMTimeAdd(lastRange.start, lastRange.duration)
                        player.seek(to: livePosition) { finished in
                            if finished {
                                player.play()
                            }
                        }
                        return
                    }
                }
                
                // If seeking doesn't work, recreate player item
                print("🔄 Recreating player item...")
                if let url = player.currentItem?.asset as? AVURLAsset {
                    let newAsset = AVURLAsset(url: url.url, options: [
                        AVURLAssetPreferPreciseDurationAndTimingKey: false
                    ])
                    let newItem = AVPlayerItem(asset: newAsset)
                    newItem.preferredForwardBufferDuration = 3.0
                    newItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
                    player.replaceCurrentItem(with: newItem)
                    player.play()
                }
            }
        }
        
        func cleanup() {
            retryTimer?.invalidate()
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

// MARK: - WebRTC Player View (Using WKWebView) - Simplified for MediaMTX
struct WebRTCPlayerView: UIViewRepresentable {
    let streamURL: URL
    let cameraId: String
    @Binding var playerState: PlayerState
    
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.navigationDelegate = context.coordinator
        
        // Load the MediaMTX WebRTC page directly
        print("📡 Loading WebRTC stream: \(streamURL.absoluteString)")
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
            print("🔄 Loading WebRTC page for \(cameraId)")
            DispatchQueue.main.async {
                self.playerState = .loading
            }
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("✅ WebRTC page loaded for \(cameraId)")
            
            // Give the page a moment to initialize
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.playerState = .playing
            }
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("❌ WebRTC page failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.playerState = .failed(error.localizedDescription)
            }
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("❌ WebRTC provisional navigation failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.playerState = .failed("Cannot connect to camera. Please check if camera is online.")
            }
        }
    }
}

// MARK: - Camera Extension for WebRTC URL
// extension Camera {
//     // WebRTC stream URL - matches your MediaMTX server format
//     var webrtcStreamURL: String? {
//         let serverURLs: [Int: String] = [
//             5: "http://103.208.173.131:8889",
//             6: "http://103.208.173.147:8889",
//             7: "http://103.208.173.163:8889",
//             8: "http://a5va.bccliccc.in:8889",
//             9: "http://a5va.bccliccc.in:8889",
//             10: "http://a6va.bccliccc.in:8889",
//             11: "http://103.208.173.195:8889",
//             12: "http://a9va.bccliccc.in:8889",
//             13: "http://a10va.bccliccc.in:8889",
//             14: "http://103.210.88.195:8889",
//             15: "http://103.210.88.211:8889",
//             16: "http://103.208.173.179:8889",
//             22: "http://103.208.173.211:8889"
//         ]
        
//         guard let serverURL = serverURLs[groupId] else {
//             print("❌ No WebRTC server for groupId: \(groupId)")
//             return nil
//         }
        
//         // Use IP address as stream path
//         if !ip.isEmpty {
//             return "\(serverURL)/\(ip)/"
//         }
        
//         // Fallback to camera ID
//         return "\(serverURL)/\(id)/"
//     }
// }

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
            
            // Player based on stream type
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
            
            // Status overlay
            if case .loading = playerState {
                loadingOverlay
            } else if case .retrying(let count) = playerState {
                retryingOverlay(attempt: count)
            } else if case .failed(let message) = playerState {
                failedOverlay(message: message)
            }
            
            // Controls overlay
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
        }
    }
    
    private var loadingOverlay: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.5)
            
            Text("Connecting to camera...")
                .foregroundColor(.white)
                .font(.headline)
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
            // Top bar
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
                
                // Stream type toggle
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
        playerState = .loading
        withAnimation {
            streamType = .hls
        }
    }
    
    private func switchToWebRTC() {
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