import SwiftUI
import AVKit
import AVFoundation
import Combine

// MARK: - Player Manager (Enhanced with better lifecycle management)
class PlayerManager: ObservableObject {
    static let shared = PlayerManager()
    
    private var activePlayers: [String: AVPlayer] = [:]
    private let lock = NSLock()
    private let maxPlayers = 4 // Increased for 2x2 grid
    
    private init() {}
    
    func registerPlayer(_ player: AVPlayer, for cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        // Clean up oldest player if we hit the limit
        if activePlayers.count >= maxPlayers {
            if let oldestKey = activePlayers.keys.sorted().first {
                releasePlayerInternal(oldestKey)
            }
        }
        
        activePlayers[cameraId] = player
        print("📹 Registered player for: \(cameraId) (Total: \(activePlayers.count))")
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
        print("🧹 Cleared all players (\(activePlayers.count) total)")
    }
    
    func pauseAll() {
        lock.lock()
        defer { lock.unlock() }
        
        activePlayers.values.forEach { $0.pause() }
        print("⏸️ Paused all players")
    }
}

// MARK: - H.264 Player View (Production-Ready, iOS 14+ Compatible)
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
            // Video Layer
            if let player = viewModel.player {
                VideoPlayer(player: player)
                    .disabled(true)
            } else {
                Color.black
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
            
            Text("Loading stream...")
                .font(.caption)
                .foregroundColor(.white)
            
            if viewModel.retryCount > 0 {
                Text("Attempt \(viewModel.retryCount + 1) of 3")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .padding(20)
        .background(Color.black.opacity(0.7))
        .cornerRadius(12)
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
                .lineLimit(2)
            
            if viewModel.showRetryButton {
                Button(action: { viewModel.retryConnection() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                        Text("Retry")
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
            
            Text("Unable to connect after 3 attempts")
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            
            Button(action: { viewModel.retryConnection() }) {
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

// MARK: - Player ViewModel (iOS 14+ Compatible)
class PlayerViewModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var playerState: PlayerState = .loading
    @Published var retryCount = 0
    @Published var errorMessage = ""
    @Published var showRetryButton = false
    
    private let streamURL: String
    private let cameraId: String
    private var observer: PlayerObserver?
    private var cancellables = Set<AnyCancellable>()
    private let maxRetries = 3
    private let retryDelay: TimeInterval = 2.0
    
    enum PlayerState {
        case loading
        case playing
        case paused
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
        
        // Create player item with optimized settings for H.264
        let playerItem = AVPlayerItem(url: url)
        playerItem.preferredForwardBufferDuration = 2.0
        
        // Create player
        let avPlayer = AVPlayer(playerItem: playerItem)
        avPlayer.allowsExternalPlayback = false
        avPlayer.automaticallyWaitsToMinimizeStalling = true
        
        self.player = avPlayer
        PlayerManager.shared.registerPlayer(avPlayer, for: cameraId)
        
        // Setup observer
        setupObserver(for: playerItem)
        
        // Setup notifications
        setupNotifications(for: playerItem)
        
        // Auto-play with delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            avPlayer.play()
        }
        
        // Timeout check
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
            if self?.playerState == .loading {
                self?.handleError("Connection timeout", canRetry: true)
            }
        }
    }
    
    private func setupObserver(for playerItem: AVPlayerItem) {
        let newObserver = PlayerObserver()
        
        newObserver.onStatusChange = { [weak self] status in
            guard let self = self else { return }
            
            switch status {
            case .readyToPlay:
                print("✅ H.264 player ready: \(self.cameraId)")
                self.playerState = .playing
                self.retryCount = 0
                self.showRetryButton = false
                self.player?.play()
                
            case .failed:
                if let error = playerItem.error {
                    self.handleError(error.localizedDescription, canRetry: true)
                } else {
                    self.handleError("Playback failed", canRetry: true)
                }
                
            case .unknown:
                self.playerState = .loading
                
            @unknown default:
                break
            }
        }
        
        newObserver.onError = { [weak self] error in
            self?.handleError(error?.localizedDescription ?? "Unknown error", canRetry: true)
        }
        
        newObserver.observe(playerItem: playerItem)
        self.observer = newObserver
    }
    
    private func setupNotifications(for playerItem: AVPlayerItem) {
        // Handle playback failure
        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: playerItem)
            .sink { [weak self] notification in
                if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                    self?.handleError(error.localizedDescription, canRetry: true)
                }
            }
            .store(in: &cancellables)
        
        // Handle stalled playback
        NotificationCenter.default.publisher(for: .AVPlayerItemPlaybackStalled, object: playerItem)
            .sink { [weak self] _ in
                guard let self = self else { return }
                print("⚠️ Playback stalled for: \(self.cameraId)")
                self.playerState = .error
                self.errorMessage = "Stream buffering..."
                
                // Auto-retry after brief delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    if self.playerState == .error {
                        self.player?.play()
                    }
                }
            }
            .store(in: &cancellables)
        
        // Handle successful playback start
        NotificationCenter.default.publisher(for: .AVPlayerItemNewAccessLogEntry, object: playerItem)
            .sink { [weak self] _ in
                if self?.playerState != .playing {
                    self?.playerState = .playing
                    self?.showRetryButton = false
                }
            }
            .store(in: &cancellables)
    }
    
    private func handleError(_ message: String, canRetry: Bool) {
        print("❌ Player error: \(message) (retry: \(retryCount)/\(maxRetries))")
        
        errorMessage = message
        
        if canRetry && retryCount < maxRetries {
            playerState = .error
            showRetryButton = false
            
            // Auto-retry with exponential backoff
            let delay = retryDelay * Double(retryCount + 1)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.retryConnection()
            }
        } else {
            playerState = .failed
            showRetryButton = true
        }
    }
    
    func retryConnection() {
        print("🔄 Retrying connection for: \(cameraId) (attempt \(retryCount + 1))")
        
        retryCount += 1
        cleanup()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.setupPlayer()
        }
    }
    
    func cleanup() {
        player?.pause()
        observer?.stopObserving()
        observer = nil
        PlayerManager.shared.releasePlayer(cameraId)
        player = nil
        cancellables.removeAll()
    }
    
    deinit {
        cleanup()
    }
}

// MARK: - Player Observer
class PlayerObserver: NSObject {
    var onStatusChange: ((AVPlayerItem.Status) -> Void)?
    var onError: ((Error?) -> Void)?
    
    private var statusObservation: NSKeyValueObservation?
    
    func observe(playerItem: AVPlayerItem) {
        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
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

// MARK: - Camera Thumbnail (Production Version)
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
                    .font(.system(size: 28))
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
                H264PlayerView(
                    streamURL: streamURL,
                    cameraId: camera.id,
                    isFullscreen: true
                )
                .ignoresSafeArea()
            }
            
            // Top bar with close button
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