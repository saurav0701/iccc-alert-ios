import SwiftUI
import AVKit
import AVFoundation
import Combine

// MARK: - Player Manager (Enhanced with better lifecycle management)
class PlayerManager: ObservableObject {
    static let shared = PlayerManager()
    
    private var activePlayers: [String: AVPlayer] = [:]
    private var playerItems: [String: AVPlayerItem] = [:]
    private let lock = NSLock()
    private let maxPlayers = 4
    
    private init() {}
    
    func registerPlayer(_ player: AVPlayer, item: AVPlayerItem, for cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        // Clean up oldest player if we hit the limit
        if activePlayers.count >= maxPlayers {
            if let oldestKey = activePlayers.keys.sorted().first {
                releasePlayerInternal(oldestKey)
            }
        }
        
        activePlayers[cameraId] = player
        playerItems[cameraId] = item
        print("📹 Registered player for: \(cameraId) (Total: \(activePlayers.count))")
    }
    
    private func releasePlayerInternal(_ cameraId: String) {
        if let player = activePlayers.removeValue(forKey: cameraId) {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        playerItems.removeValue(forKey: cameraId)
        print("🗑️ Released player: \(cameraId)")
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
    
    func pauseAll() {
        lock.lock()
        defer { lock.unlock() }
        
        activePlayers.values.forEach { $0.pause() }
        print("⏸️ Paused all players")
    }
}

// MARK: - H.264 Player View (Production-Ready)
struct H264PlayerView: View {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    
    @StateObject private var viewModel: PlayerViewModel
    
    init(streamURL: String, cameraId: String, isFullscreen: Bool) {
        self.streamURL = streamURL
        self.cameraId = cameraId
        self.isFullscreen = isFullscreen
        self._viewModel = StateObject(wrappedValue: PlayerViewModel(streamURL: streamURL, cameraId: cameraId))
    }
    
    var body: some View {
        ZStack {
            Color.black
            
            // Video Layer
            if let player = viewModel.player {
                VideoPlayerWrapper(player: player)
            }
            
            // Overlay Layer
            overlayContent
        }
        .onAppear {
            viewModel.setupPlayer()
        }
        .onDisappear {
            viewModel.cleanup()
        }
    }
    
    @ViewBuilder
    private var overlayContent: some View {
        switch viewModel.playerState {
        case .loading:
            loadingOverlay
            
        case .buffering:
            bufferingOverlay
            
        case .error:
            errorOverlay
            
        case .failed:
            failedOverlay
            
        case .playing:
            if !isFullscreen {
                liveIndicator
            }
            
        case .paused:
            EmptyView()
        }
    }
    
    private var loadingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.2)
            
            Text("Connecting...")
                .font(.caption)
                .foregroundColor(.white)
            
            if viewModel.retryCount > 0 {
                Text("Attempt \(viewModel.retryCount + 1)")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .padding(20)
        .background(Color.black.opacity(0.7))
        .cornerRadius(12)
    }
    
    private var bufferingOverlay: some View {
        VStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
            Text("Buffering...")
                .font(.caption)
                .foregroundColor(.white)
        }
        .padding(16)
        .background(Color.black.opacity(0.6))
        .cornerRadius(8)
    }
    
    private var errorOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(.orange)
            
            Text("Connection Issue")
                .font(.headline)
                .foregroundColor(.white)
            
            Text(viewModel.errorMessage)
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal)
            
            Button(action: { viewModel.manualRetry() }) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text("Retry Now")
                        .font(.subheadline)
                        .bold()
                }
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.blue)
                .cornerRadius(8)
            }
        }
        .padding(20)
        .background(Color.black.opacity(0.8))
        .cornerRadius(12)
    }
    
    private var failedOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(.red)
            
            Text("Stream Unavailable")
                .font(.headline)
                .foregroundColor(.white)
            
            Text(viewModel.errorMessage)
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button(action: { viewModel.manualRetry() }) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text("Try Again")
                        .font(.subheadline)
                        .bold()
                }
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.blue)
                .cornerRadius(8)
            }
        }
        .padding(24)
        .background(Color.black.opacity(0.85))
        .cornerRadius(12)
    }
    
    private var liveIndicator: some View {
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

// MARK: - VideoPlayer Wrapper (Prevents crashes)
struct VideoPlayerWrapper: UIViewControllerRepresentable {
    let player: AVPlayer
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspect
        controller.view.backgroundColor = .black
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        // Update only if player changed
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}

// MARK: - Player ViewModel (Production-Ready)
class PlayerViewModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var playerState: PlayerState = .loading
    @Published var retryCount = 0
    @Published var errorMessage = ""
    
    private let streamURL: String
    private let cameraId: String
    private var statusObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private let maxRetries = 5
    private var retryTimer: Timer?
    private var stallTimer: Timer?
    private var hasPlayedSuccessfully = false
    
    enum PlayerState {
        case loading
        case playing
        case paused
        case buffering
        case error
        case failed
    }
    
    init(streamURL: String, cameraId: String) {
        self.streamURL = streamURL
        self.cameraId = cameraId
    }
    
    func setupPlayer() {
        guard let url = URL(string: streamURL) else {
            handleError("Invalid stream URL", canRetry: false)
            return
        }
        
        print("📹 Setting up H.264 player for: \(cameraId)")
        print("   URL: \(streamURL)")
        
        playerState = .loading
        
        // Create asset with specific resource loader options for HLS
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
            "AVURLAssetHTTPHeaderFieldsKey": [
                "Accept": "*/*",
                "User-Agent": "Mozilla/5.0"
            ]
        ])
        
        // Create player item with optimized settings
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 1.0
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        
        // Create player with optimized settings
        let avPlayer = AVPlayer(playerItem: playerItem)
        avPlayer.allowsExternalPlayback = false
        avPlayer.automaticallyWaitsToMinimizeStalling = false
        avPlayer.preventsDisplaySleepDuringVideoPlayback = true
        
        self.player = avPlayer
        PlayerManager.shared.registerPlayer(avPlayer, item: playerItem, for: cameraId)
        
        // Setup observers
        setupStatusObserver(for: playerItem)
        setupNotifications(for: playerItem)
        setupTimeObserver(for: avPlayer)
        
        // Start playback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            avPlayer.play()
            self?.startConnectionTimeout()
        }
    }
    
    private func setupStatusObserver(for playerItem: AVPlayerItem) {
        statusObservation = playerItem.observe(\.status, options: [.new, .old]) { [weak self] item, change in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                switch item.status {
                case .readyToPlay:
                    print("✅ Player ready: \(self.cameraId)")
                    self.playerState = .playing
                    self.hasPlayedSuccessfully = true
                    self.retryCount = 0
                    self.cancelRetryTimer()
                    self.player?.play()
                    
                case .failed:
                    let errorMsg = item.error?.localizedDescription ?? "Playback failed"
                    print("❌ Player failed: \(errorMsg)")
                    self.handleError(errorMsg, canRetry: true)
                    
                case .unknown:
                    if self.playerState != .loading {
                        self.playerState = .loading
                    }
                    
                @unknown default:
                    break
                }
            }
        }
    }
    
    private func setupTimeObserver(for player: AVPlayer) {
        // Monitor playback progress to detect stalls
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            
            // If we're in playing state and time is progressing, everything is good
            if self.playerState == .playing && time.seconds > 0 {
                self.cancelStallTimer()
            }
        }
    }
    
    private func setupNotifications(for playerItem: AVPlayerItem) {
        // Playback failure
        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: playerItem)
            .sink { [weak self] notification in
                guard let self = self else { return }
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self.handleError(error?.localizedDescription ?? "Playback interrupted", canRetry: true)
            }
            .store(in: &cancellables)
        
        // Playback stalled
        NotificationCenter.default.publisher(for: .AVPlayerItemPlaybackStalled, object: playerItem)
            .sink { [weak self] _ in
                guard let self = self else { return }
                print("⚠️ Playback stalled: \(self.cameraId)")
                
                if self.hasPlayedSuccessfully {
                    self.playerState = .buffering
                    self.startStallRecovery()
                } else {
                    self.handleError("Stream not responding", canRetry: true)
                }
            }
            .store(in: &cancellables)
        
        // New access log (indicates data is flowing)
        NotificationCenter.default.publisher(for: .AVPlayerItemNewAccessLogEntry, object: playerItem)
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.playerState != .playing && self.player?.rate ?? 0 > 0 {
                    self.playerState = .playing
                    self.hasPlayedSuccessfully = true
                    self.cancelStallTimer()
                }
            }
            .store(in: &cancellables)
        
        // Error log
        NotificationCenter.default.publisher(for: .AVPlayerItemNewErrorLogEntry, object: playerItem)
            .sink { [weak self] notification in
                guard let self = self else { return }
                if let item = notification.object as? AVPlayerItem,
                   let errorLog = item.errorLog(),
                   let lastEvent = errorLog.events.last {
                    print("⚠️ Stream error: \(lastEvent.errorComment ?? "Unknown")")
                }
            }
            .store(in: &cancellables)
    }
    
    private func startConnectionTimeout() {
        cancelRetryTimer()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.playerState == .loading && !self.hasPlayedSuccessfully {
                self.handleError("Connection timeout", canRetry: true)
            }
        }
    }
    
    private func startStallRecovery() {
        cancelStallTimer()
        stallTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.playerState == .buffering {
                print("🔄 Attempting stall recovery")
                self.player?.pause()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.player?.play()
                }
            }
        }
    }
    
    private func handleError(_ message: String, canRetry: Bool) {
        errorMessage = message
        
        guard canRetry && retryCount < maxRetries else {
            playerState = .failed
            errorMessage = retryCount >= maxRetries ? "Connection failed after \(maxRetries) attempts" : message
            return
        }
        
        playerState = .error
        retryCount += 1
        
        print("⚠️ Error (attempt \(retryCount)/\(maxRetries)): \(message)")
        
        // Exponential backoff: 2s, 4s, 6s, 8s, 10s
        let delay = min(Double(retryCount) * 2.0, 10.0)
        
        cancelRetryTimer()
        retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.retryConnection()
        }
    }
    
    func manualRetry() {
        print("🔄 Manual retry requested")
        retryCount = 0
        hasPlayedSuccessfully = false
        retryConnection()
    }
    
    private func retryConnection() {
        print("🔄 Retrying connection: \(cameraId)")
        
        cleanup(keepRetryCount: true)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.setupPlayer()
        }
    }
    
    private func cancelRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = nil
    }
    
    private func cancelStallTimer() {
        stallTimer?.invalidate()
        stallTimer = nil
    }
    
    func cleanup(keepRetryCount: Bool = false) {
        cancelRetryTimer()
        cancelStallTimer()
        
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        
        statusObservation?.invalidate()
        statusObservation = nil
        
        player?.pause()
        player = nil
        
        PlayerManager.shared.releasePlayer(cameraId)
        cancellables.removeAll()
        
        if !keepRetryCount {
            retryCount = 0
        }
        hasPlayedSuccessfully = false
    }
    
    deinit {
        cleanup()
    }
}

// MARK: - Camera Thumbnail with Tap-to-Load
struct CameraThumbnail: View {
    let camera: Camera
    @State private var shouldLoad = false
    
    var body: some View {
        ZStack {
            if let streamURL = camera.streamURL, camera.isOnline {
                if shouldLoad {
                    H264PlayerView(
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
            // Auto-load for single camera views
            // For grid views, wait for tap
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
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation {
                shouldLoad = true
            }
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
                    .font(.system(size: 28))
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
                H264PlayerView(
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
                            .background(Color.black.opacity(0.3))
                            .clipShape(Circle())
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