import SwiftUI
import AVKit
import AVFoundation
import Combine

// MARK: - Player Manager
class PlayerManager: ObservableObject {
    static let shared = PlayerManager()
    
    private var activePlayers: [String: AVPlayer] = [:]
    private let lock = NSLock()
    private let maxPlayers = 2
    
    private init() {}
    
    func registerPlayer(_ player: AVPlayer, for cameraId: String) {
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
            player.pause()
            player.replaceCurrentItem(with: nil)
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

// MARK: - Live Stream Player
struct HybridHLSPlayer: View {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    
    @StateObject private var viewModel = LivePlayerViewModel()
    
    var body: some View {
        ZStack {
            if let player = viewModel.player {
                VideoPlayer(player: player)
                    .disabled(true)
            } else {
                Color.black
            }
            
            // Status overlay
            if viewModel.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                    Text(viewModel.statusMessage)
                        .font(.caption)
                        .foregroundColor(.white)
                }
                .padding(20)
                .background(Color.black.opacity(0.7))
                .cornerRadius(12)
            }
            
            if viewModel.hasError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                    Text("Connection Issue")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(viewModel.errorMessage)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Button(action: {
                        viewModel.retry(streamURL: streamURL, cameraId: cameraId)
                    }) {
                        Text("Retry")
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.blue)
                            .cornerRadius(8)
                    }
                }
                .padding(24)
                .background(Color.black.opacity(0.85))
                .cornerRadius(16)
            }
            
            // LIVE indicator
            if viewModel.isPlaying && !isFullscreen {
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
        .onAppear {
            viewModel.setup(streamURL: streamURL, cameraId: cameraId)
        }
        .onDisappear {
            viewModel.cleanup()
        }
    }
}

// MARK: - Live Player ViewModel
class LivePlayerViewModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var isLoading = true
    @Published var hasError = false
    @Published var errorMessage = ""
    @Published var isPlaying = false
    @Published var statusMessage = "Connecting..."
    
    private var statusObserver: NSKeyValueObservation?
    private var timeObserver: Any?
    private var stallObserver: NSKeyValueObservation?
    private var playbackLikelyToKeepUpObserver: NSKeyValueObservation?
    private var currentCameraId: String?
    private var keepAliveTimer: Timer?
    private var lastPlaybackCheck: Date?
    
    func setup(streamURL: String, cameraId: String) {
        currentCameraId = cameraId
        lastPlaybackCheck = Date()
        
        guard let url = URL(string: streamURL) else {
            showError("Invalid URL")
            return
        }
        
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("📹 Setting up LIVE stream")
        print("   Camera: \(cameraId)")
        print("   URL: \(streamURL)")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        
        statusMessage = "Loading stream..."
        
        // Create asset for live streaming
        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        
        // CRITICAL: Configure for LIVE streaming
        playerItem.preferredForwardBufferDuration = 2.0
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        
        // Create player
        let avPlayer = AVPlayer(playerItem: playerItem)
        avPlayer.automaticallyWaitsToMinimizeStalling = false
        avPlayer.allowsExternalPlayback = false
        
        // CRITICAL: Set rate to 1.0 for live streams
        avPlayer.rate = 1.0
        
        self.player = avPlayer
        PlayerManager.shared.registerPlayer(avPlayer, for: cameraId)
        
        // Observe player item status
        statusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                self?.handleStatusChange(item)
            }
        }
        
        // Observe stalling
        stallObserver = playerItem.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                if item.isPlaybackBufferEmpty {
                    print("⚠️ Buffer empty - stream stalled")
                    self?.statusMessage = "Buffering..."
                    
                    // Try to restart if stalled for too long
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if item.isPlaybackBufferEmpty && self?.player?.rate == 0 {
                            print("🔄 Forcing playback restart")
                            self?.player?.play()
                        }
                    }
                }
            }
        }
        
        // Observe buffer ready
        playbackLikelyToKeepUpObserver = playerItem.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                if item.isPlaybackLikelyToKeepUp {
                    print("✅ Buffer ready - can play smoothly")
                    self?.statusMessage = "Playing"
                    self?.player?.play()
                }
            }
        }
        
        // Monitor playback position every second
        let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.checkPlaybackHealth(time: time)
        }
        
        // Start playing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            avPlayer.play()
        }
        
        // Keep-alive timer to ensure continuous playback
        startKeepAliveTimer()
        
        // Connection timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            if self.isLoading {
                self.showError("Connection timeout - stream not responding")
            }
        }
        
        DebugLogger.shared.updateCameraStatus(
            cameraId: cameraId,
            status: "Connecting...",
            streamURL: streamURL
        )
    }
    
    private func handleStatusChange(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            isLoading = false
            hasError = false
            isPlaying = true
            statusMessage = "Playing"
            
            print("✅ Stream ready - starting playback")
            
            // Ensure playback starts
            player?.play()
            
            if let cameraId = currentCameraId {
                DebugLogger.shared.updateCameraStatus(
                    cameraId: cameraId,
                    status: "Playing ✅"
                )
            }
            
        case .failed:
            let error = item.error as NSError?
            let errorCode = error?.code ?? 0
            let errorDesc = error?.localizedDescription ?? "Unknown error"
            
            print("❌ Stream failed: \(errorCode) - \(errorDesc)")
            
            showError("Playback error (\(errorCode))")
            
            if let cameraId = currentCameraId {
                DebugLogger.shared.updateCameraStatus(
                    cameraId: cameraId,
                    status: "Error ❌",
                    error: "Code \(errorCode)"
                )
            }
            
        case .unknown:
            isLoading = true
            statusMessage = "Initializing..."
            
        @unknown default:
            break
        }
    }
    
    private func checkPlaybackHealth(time: CMTime) {
        guard let player = player,
              let item = player.currentItem,
              !item.duration.isIndefinite else {
            return
        }
        
        let currentTime = time.seconds
        
        // Check if we're still at live edge for live streams
        if item.duration.isIndefinite || item.duration.seconds > 86400 { // Likely a live stream
            // For live streams, ensure we're not falling too far behind
            if let seekableRange = item.seekableTimeRanges.last?.timeRangeValue {
                let livePosition = seekableRange.end.seconds
                let lag = livePosition - currentTime
                
                if lag > 10 { // More than 10 seconds behind live
                    print("⚠️ Falling behind live edge by \(lag) seconds - jumping forward")
                    player.seek(to: CMTime(seconds: livePosition - 2, preferredTimescale: 1))
                }
            }
        }
        
        // Detect if playback is stuck
        if let lastCheck = lastPlaybackCheck {
            if Date().timeIntervalSince(lastCheck) > 3 {
                // Check if we're actually progressing
                if player.rate == 0 && !item.isPlaybackBufferEmpty {
                    print("🔄 Playback stuck - forcing restart")
                    player.play()
                }
            }
        }
        
        lastPlaybackCheck = Date()
    }
    
    private func startKeepAliveTimer() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self,
                  let player = self.player,
                  let item = player.currentItem else {
                return
            }
            
            // Ensure player keeps playing
            if player.rate == 0 && !item.isPlaybackBufferEmpty && item.isPlaybackLikelyToKeepUp {
                print("🔄 Keep-alive: restarting playback")
                player.play()
            }
            
            // Check if player is healthy
            if item.isPlaybackBufferEmpty {
                print("⚠️ Keep-alive: buffer empty")
            }
        }
    }
    
    private func showError(_ message: String) {
        isLoading = false
        hasError = true
        errorMessage = message
        statusMessage = "Error"
    }
    
    func retry(streamURL: String, cameraId: String) {
        cleanup()
        hasError = false
        isLoading = true
        statusMessage = "Retrying..."
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.setup(streamURL: streamURL, cameraId: cameraId)
        }
    }
    
    func cleanup() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        
        statusObserver?.invalidate()
        statusObserver = nil
        
        stallObserver?.invalidate()
        stallObserver = nil
        
        playbackLikelyToKeepUpObserver?.invalidate()
        playbackLikelyToKeepUpObserver = nil
        
        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        
        player?.pause()
        
        if let cameraId = currentCameraId {
            PlayerManager.shared.releasePlayer(cameraId)
        }
        
        player = nil
        currentCameraId = nil
        lastPlaybackCheck = nil
    }
    
    deinit {
        cleanup()
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
            }
            
            // Top bar
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
                
                Spacer()
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .onDisappear {
            PlayerManager.shared.releasePlayer(camera.id)
        }
    }
}