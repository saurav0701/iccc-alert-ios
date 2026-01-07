import SwiftUI
import AVKit
import AVFoundation

// MARK: - Stream Type
enum StreamType: String {
    case hls = "HLS"
    case webrtc = "WebRTC"
}

// MARK: - Player State
enum PlayerState {
    case loading
    case playing
    case paused
    case failed(Error)
    case retrying(Int)
}

// MARK: - Player Manager (4 Concurrent Players)
class HLSPlayerManager: ObservableObject {
    static let shared = HLSPlayerManager()
    
    private var activePlayers: [String: AVPlayer] = [:]
    private var playerObservers: [String: NSKeyValueObservation] = [:]
    private let lock = NSLock()
    private let maxPlayers = 4
    
    @Published var activePlayerCount = 0
    
    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }
    
    @objc private func handleMemoryWarning() {
        print("⚠️ MEMORY WARNING - Releasing extra players")
        lock.lock()
        defer { lock.unlock() }
        
        if activePlayers.count > 2 {
            let toRemove = Array(activePlayers.keys.dropFirst(activePlayers.count - 2))
            toRemove.forEach { id in
                if let player = activePlayers.removeValue(forKey: id) {
                    cleanupPlayer(player)
                    playerObservers.removeValue(forKey: id)
                }
            }
        }
        
        updatePlayerCount()
    }
    
    @objc private func handleBackground() {
        pauseAllPlayers()
    }
    
    func canCreatePlayer(for cameraId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        if activePlayers[cameraId] != nil {
            return true
        }
        
        return activePlayers.count < maxPlayers
    }
    
    func getPlayer(for cameraId: String, streamURL: URL, preferredBufferDuration: TimeInterval = 3.0) -> AVPlayer? {
        lock.lock()
        defer { 
            lock.unlock()
            updatePlayerCount()
        }
        
        if let existingPlayer = activePlayers[cameraId] {
            print("♻️ Reusing player: \(cameraId)")
            return existingPlayer
        }
        
        if activePlayers.count >= maxPlayers {
            print("⚠️ Player limit reached (\(maxPlayers))")
            return nil
        }
        
        let asset = AVURLAsset(url: streamURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
            "AVURLAssetHTTPHeaderFieldsKey": [
                "Connection": "keep-alive"
            ]
        ])
        
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = preferredBufferDuration
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        
        let player = AVPlayer(playerItem: playerItem)
        player.allowsExternalPlayback = false
        player.automaticallyWaitsToMinimizeStalling = true
        
        let observer = player.observe(\.currentItem?.status, options: [.new]) { player, _ in
            guard let status = player.currentItem?.status else { return }
            
            switch status {
            case .readyToPlay:
                print("✅ Player ready: \(cameraId)")
            case .failed:
                if let error = player.currentItem?.error {
                    print("❌ Player failed: \(cameraId) - \(error.localizedDescription)")
                }
            case .unknown:
                break
            @unknown default:
                break
            }
        }
        
        activePlayers[cameraId] = player
        playerObservers[cameraId] = observer
        
        print("✅ Created player: \(cameraId) (total: \(activePlayers.count))")
        
        return player
    }
    
    func releasePlayer(for cameraId: String) {
        lock.lock()
        defer { 
            lock.unlock()
            updatePlayerCount()
        }
        
        guard let player = activePlayers.removeValue(forKey: cameraId) else {
            return
        }
        
        cleanupPlayer(player)
        playerObservers.removeValue(forKey: cameraId)
        
        print("🗑️ Released: \(cameraId) (remaining: \(activePlayers.count))")
    }
    
    func releaseAllPlayers() {
        lock.lock()
        
        print("🧹 Releasing ALL players (\(activePlayers.count))")
        
        activePlayers.forEach { (_, player) in
            cleanupPlayer(player)
        }
        
        activePlayers.removeAll()
        playerObservers.removeAll()
        
        lock.unlock()
        
        updatePlayerCount()
        print("✅ All players released")
    }
    
    func pauseAllPlayers() {
        lock.lock()
        defer { lock.unlock() }
        
        activePlayers.values.forEach { $0.pause() }
        print("⏸️ Paused all players")
    }
    
    private func cleanupPlayer(_ player: AVPlayer) {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
    
    private func updatePlayerCount() {
        DispatchQueue.main.async {
            self.activePlayerCount = self.activePlayers.count
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - HLS Player View with Error Handling & Auto-Recovery
struct HLSPlayerView: UIViewControllerRepresentable {
    let streamURL: URL
    let cameraId: String
    let autoPlay: Bool
    let streamType: StreamType
    let onError: ((Error) -> Void)?
    
    @StateObject private var playerManager = HLSPlayerManager.shared
    
    init(streamURL: URL, cameraId: String, autoPlay: Bool, streamType: StreamType, onError: ((Error) -> Void)? = nil) {
        self.streamURL = streamURL
        self.cameraId = cameraId
        self.autoPlay = autoPlay
        self.streamType = streamType
        self.onError = onError
    }
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = false
        controller.videoGravity = .resizeAspect
        
        let bufferDuration: TimeInterval = streamType == .hls ? 3.0 : 2.0
        
        if let player = playerManager.getPlayer(for: cameraId, streamURL: streamURL, preferredBufferDuration: bufferDuration) {
            controller.player = player
            
            context.coordinator.setupPlayer(player: player)
            
            if autoPlay {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    player.play()
                    context.coordinator.startMonitoring(player: player)
                }
            }
        } else {
            print("❌ Cannot create player (limit reached)")
            onError?(NSError(domain: "Player limit reached", code: -1))
        }
        
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
    
    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.cleanup()
        
        uiViewController.player?.pause()
        uiViewController.player?.replaceCurrentItem(with: nil)
        uiViewController.player = nil
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(cameraId: cameraId, streamURL: streamURL, streamType: streamType, onError: onError)
    }
    
    class Coordinator {
        let cameraId: String
        let streamURL: URL
        let streamType: StreamType
        let onError: ((Error) -> Void)?
        
        private var stallTimer: Timer?
        private var retryCount = 0
        private let maxRetries = 3
        private var isMonitoring = false
        private weak var player: AVPlayer?
        private var statusObserver: NSKeyValueObservation?
        private var itemObserver: NSKeyValueObservation?
        
        init(cameraId: String, streamURL: URL, streamType: StreamType, onError: ((Error) -> Void)?) {
            self.cameraId = cameraId
            self.streamURL = streamURL
            self.streamType = streamType
            self.onError = onError
        }
        
        func setupPlayer(player: AVPlayer) {
            self.player = player
            
            // Observe player item status changes
            statusObserver = player.observe(\.currentItem?.status, options: [.new]) { [weak self] player, _ in
                guard let self = self, let item = player.currentItem else { return }
                
                switch item.status {
                case .failed:
                    if let error = item.error {
                        print("❌ Player item failed: \(error.localizedDescription)")
                        self.handleError(error)
                    }
                case .readyToPlay:
                    print("✅ Player item ready to play")
                    self.retryCount = 0
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
            
            // Observe player item changes
            itemObserver = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
                self?.setupItemObservers()
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
        
        private func setupItemObservers() {
            guard let item = player?.currentItem else { return }
            
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(playerItemFailedToPlayToEndTime),
                name: .AVPlayerItemFailedToPlayToEndTime,
                object: item
            )
            
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(playerItemPlaybackStalled),
                name: .AVPlayerItemPlaybackStalled,
                object: item
            )
        }
        
        @objc private func playerItemFailedToPlayToEndTime(notification: Notification) {
            if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                print("❌ Failed to play to end: \(error.localizedDescription)")
                handleError(error)
            }
        }
        
        @objc private func playerItemPlaybackStalled() {
            print("⚠️ Playback stalled for \(cameraId)")
            attemptRecovery()
        }
        
        func startMonitoring(player: AVPlayer) {
            guard !isMonitoring else { return }
            isMonitoring = true
            
            stallTimer?.invalidate()
            
            stallTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self, weak player] _ in
                guard let self = self, let player = player else { return }
                
                // Check if player is stalled
                if player.rate == 0 && player.currentItem?.status == .readyToPlay {
                    print("⚠️ Player stalled, checking...")
                    
                    // Check if the item has seekable ranges (indicates it's a valid stream)
                    if let item = player.currentItem, !item.seekableTimeRanges.isEmpty {
                        self.attemptRecovery()
                    }
                }
            }
        }
        
        private func handleError(_ error: Error) {
            print("❌ Handling error for \(cameraId): \(error.localizedDescription)")
            
            // Notify parent view
            DispatchQueue.main.async {
                self.onError?(error)
            }
            
            // Attempt recovery
            attemptRecovery()
        }
        
        private func attemptRecovery() {
            guard retryCount < maxRetries else {
                print("❌ Max retries reached for \(cameraId)")
                stallTimer?.invalidate()
                return
            }
            
            retryCount += 1
            print("🔄 Retry attempt \(retryCount)/\(maxRetries) for \(cameraId)")
            
            guard let player = player else { return }
            
            // Try to recover by seeking to live edge
            if let item = player.currentItem {
                let seekableRanges = item.seekableTimeRanges
                if let lastRange = seekableRanges.last?.timeRangeValue {
                    let seekTime = CMTimeAdd(lastRange.start, lastRange.duration)
                    
                    player.seek(to: seekTime) { [weak self] finished in
                        if finished {
                            print("✅ Seeked to live edge")
                            player.play()
                        } else {
                            print("❌ Seek failed")
                            self?.recreatePlayer()
                        }
                    }
                } else {
                    recreatePlayer()
                }
            } else {
                recreatePlayer()
            }
        }
        
        private func recreatePlayer() {
            print("🔄 Recreating player for \(cameraId)")
            
            guard let player = player else { return }
            
            // Release old player
            HLSPlayerManager.shared.releasePlayer(for: cameraId)
            
            // Small delay before recreating
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self = self else { return }
                
                if let newPlayer = HLSPlayerManager.shared.getPlayer(
                    for: self.cameraId,
                    streamURL: self.streamURL,
                    preferredBufferDuration: self.streamType == .hls ? 3.0 : 2.0
                ) {
                    self.setupPlayer(player: newPlayer)
                    newPlayer.play()
                    self.startMonitoring(player: newPlayer)
                }
            }
        }
        
        func cleanup() {
            isMonitoring = false
            stallTimer?.invalidate()
            stallTimer = nil
            
            statusObserver?.invalidate()
            itemObserver?.invalidate()
            
            NotificationCenter.default.removeObserver(self)
            
            HLSPlayerManager.shared.releasePlayer(for: cameraId)
        }
        
        deinit {
            cleanup()
        }
    }
}

// MARK: - Camera Thumbnail
struct CameraThumbnailView: View {
    let camera: Camera
    let isGridView: Bool
    
    var body: some View {
        ZStack {
            if camera.isOnline {
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

// MARK: - Fullscreen Player with HLS/WebRTC Toggle & Error Handling
struct FullscreenHLSPlayerView: View {
    let camera: Camera
    @Environment(\.presentationMode) var presentationMode
    @StateObject private var playerManager = HLSPlayerManager.shared
    
    @State private var streamType: StreamType = .hls
    @State private var showStreamTypeSelector = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var isRetrying = false
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let streamURL = getStreamURL() {
                if !playerManager.canCreatePlayer(for: camera.id) {
                    playerLimitView
                } else {
                    HLSPlayerView(
                        streamURL: streamURL,
                        cameraId: camera.id,
                        autoPlay: true,
                        streamType: streamType,
                        onError: handlePlayerError
                    )
                    .ignoresSafeArea()
                }
            } else {
                errorView(message: "Stream URL not available")
            }
            
            // Error overlay
            if showError, let errorMessage = errorMessage {
                errorOverlay(message: errorMessage)
            }
            
            // Controls overlay
            VStack {
                HStack {
                    Button(action: {
                        playerManager.releasePlayer(for: camera.id)
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    
                    Spacer()
                    
                    // Stream type toggle
                    if camera.webrtcStreamURL != nil {
                        Button(action: switchStreamType) {
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
                        .disabled(isRetrying)
                    }
                }
                .padding()
                
                Spacer()
                
                // Camera info
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(camera.displayName)
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                            Text(camera.area)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                            
                            if isRetrying {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.7)
                                Text("Retrying...")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.8))
                            }
                        }
                    }
                    .padding()
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(10)
                    
                    Spacer()
                }
                .padding()
            }
        }
        .navigationBarHidden(true)
        .onDisappear {
            playerManager.releasePlayer(for: camera.id)
        }
    }
    
    private func getStreamURL() -> URL? {
        switch streamType {
        case .hls:
            if let urlString = camera.streamURL {
                return URL(string: urlString)
            }
        case .webrtc:
            if let urlString = camera.webrtcStreamURL {
                return URL(string: urlString)
            }
        }
        return nil
    }
    
    private func handlePlayerError(_ error: Error) {
        print("❌ Player error: \(error.localizedDescription)")
        
        errorMessage = error.localizedDescription
        showError = true
        
        // Auto-hide error after 5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            showError = false
        }
        
        // If HLS fails and WebRTC is available, try switching
        if streamType == .hls && camera.webrtcStreamURL != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if showError {
                    print("🔄 Auto-switching to WebRTC fallback")
                    switchStreamType()
                }
            }
        }
    }
    
    private func switchStreamType() {
        isRetrying = true
        playerManager.releasePlayer(for: camera.id)
        
        streamType = streamType == .hls ? .webrtc : .hls
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isRetrying = false
        }
    }
    
    private func errorOverlay(message: String) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                
                Text(message)
                    .font(.caption)
                    .foregroundColor(.white)
                
                Spacer()
                
                Button(action: { showError = false }) {
                    Image(systemName: "xmark")
                        .foregroundColor(.white)
                        .font(.caption)
                }
            }
            .padding()
            .background(Color.red.opacity(0.8))
            .cornerRadius(10)
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .transition(.move(edge: .top))
        .animation(.easeInOut, value: showError)
    }
    
    private var playerLimitView: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            
            Text("Too Many Active Streams")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text("Close some cameras first (max 4 active)")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button(action: {
                presentationMode.wrappedValue.dismiss()
            }) {
                Text("Close")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(Color.blue)
                    .cornerRadius(10)
            }
            .padding(.top)
        }
    }
    
    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.red)
            
            Text("Playback Error")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text(message)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            if camera.webrtcStreamURL != nil && streamType == .hls {
                Button(action: switchStreamType) {
                    Text("Try WebRTC")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(Color.blue)
                        .cornerRadius(10)
                }
            }
        }
    }
}