import SwiftUI
import AVKit
import AVFoundation

// MARK: - Stream Type
enum StreamType: String {
    case hls = "HLS"
    case alternative = "Alternative"
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
                "Connection": "keep-alive",
                "User-Agent": "ICCC-Alert-iOS/1.0"
            ]
        ])
        
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = preferredBufferDuration
        playerItem.preferredMaximumResolution = CGSize(width: 1920, height: 1080)
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        
        let player = AVPlayer(playerItem: playerItem)
        player.allowsExternalPlayback = false
        player.automaticallyWaitsToMinimizeStalling = true
        
        let observer: NSKeyValueObservation? = player.observe(\.currentItem?.status, options: [.new]) { player, _ in
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
    
    func forceRecreatePlayer(for cameraId: String) {
        lock.lock()
        defer { 
            lock.unlock()
            updatePlayerCount()
        }
        
        if let player = activePlayers.removeValue(forKey: cameraId) {
            cleanupPlayer(player)
            playerObservers.removeValue(forKey: cameraId)
            print("🧹 Force-released (corrupted): \(cameraId)")
        }
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
        
        let bufferDuration: TimeInterval = streamType == .hls ? 3.0 : 3.0
        
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
        private let maxRetries = 6  // Increased from 3 to 6
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
                        print("❌ CODEC/PLAYBACK ERROR: \(error.localizedDescription)")
                        print("   Error code: \((error as NSError).code)")
                        print("   Domain: \((error as NSError).domain)")
                        // Check for codec errors (12000 range)
                        if (error as NSError).code >= 12000 && (error as NSError).code < 13000 {
                            print("⚠️ DETECTED CODEC ERROR - will recreate player")
                        }
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
            
            stallTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self, weak player] _ in
                guard let self = self, let player = player else { return }
                
                // Check for player item errors (codec errors, etc)
                if let item = player.currentItem {
                    if item.status == .failed {
                        print("⚠️ Detected failed item status during monitoring - triggering recovery")
                        self.attemptRecovery()
                        return
                    }
                }
                
                // Check if player is stalled (not playing and ready)
                if player.rate == 0 && player.currentItem?.status == .readyToPlay {
                    // Check if the item has seekable ranges (indicates it's a valid stream)
                    if let item = player.currentItem, !item.seekableTimeRanges.isEmpty {
                        print("⚠️ Player stalled (not playing) - attempting recovery")
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
                print("❌ Max retries reached for \(cameraId) - stream unavailable")
                stallTimer?.invalidate()
                return
            }
            
            retryCount += 1
            // Exponential backoff: 2s, 4s, 8s, 16s, 32s, 60s
            let delaySeconds = min(pow(2.0, Double(retryCount)), 60.0)
            print("🔄 Retry attempt \(retryCount)/\(maxRetries) for \(cameraId) (waiting \(Int(delaySeconds))s)")
            
            guard let player = player else { return }
            
            // Check if player item is in failed state
            if let item = player.currentItem, item.status == .failed {
                print("⚠️ PlayerItem is in FAILED state - need to recreate")
                // Player item is corrupted, need complete recreation
                DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
                    self?.recreatePlayer()
                }
                return
            }
            
            // Try to recover by seeking to live edge
            if let item = player.currentItem, item.status == .readyToPlay {
                let seekableRanges = item.seekableTimeRanges
                if let lastRange = seekableRanges.last?.timeRangeValue {
                    let seekTime = CMTimeAdd(lastRange.start, lastRange.duration)
                    
                    print("📍 Seeking to live edge...")
                    player.seek(to: seekTime) { [weak self] finished in
                        if finished {
                            print("✅ Seeked to live edge - Retry \(self?.retryCount ?? 0)/\(self?.maxRetries ?? 0)")
                            player.play()
                        } else {
                            print("❌ Seek failed - scheduling next attempt")
                            // Schedule next retry with exponential backoff
                            DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) {
                                self?.attemptRecovery()
                            }
                        }
                    }
                } else {
                    print("❌ No seekable ranges - recreating player")
                    // No seekable ranges, player item is bad
                    DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
                        self?.recreatePlayer()
                    }
                }
            } else {
                print("⚠️ PlayerItem not ready - recreating")
                // PlayerItem not in ready state, need recreation
                DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
                    self?.recreatePlayer()
                }
            }
        }
        
        private func recreatePlayer() {
            print("🔄 Recreating player for \(cameraId) (Retry \(retryCount)/\(maxRetries))")
            
            stallTimer?.invalidate()
            stallTimer = nil
            
            guard let player = player else { return }
            
            // Proper cleanup of old player and item
            player.pause()
            player.replaceCurrentItem(with: nil)
            
            // Force release old player completely
            HLSPlayerManager.shared.forceRecreatePlayer(for: cameraId)
            self.player = nil
            
            // Wait before creating new player
            let delaySeconds = min(pow(2.0, Double(retryCount + 1)), 60.0)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
                guard let self = self else { return }
                
                print("🔧 Creating new player after \(Int(delaySeconds))s delay...")
                
                if let newPlayer = HLSPlayerManager.shared.getPlayer(
                    for: self.cameraId,
                    streamURL: self.streamURL,
                    preferredBufferDuration: self.streamType == .hls ? 3.0 : 2.0
                ) {
                    self.player = newPlayer
                    self.setupPlayer(player: newPlayer)
                    
                    // Wait a bit more before playing
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        print("▶️ Starting playback on recreated player")
                        newPlayer.play()
                        self.startMonitoring(player: newPlayer)
                    }
                } else {
                    print("❌ Failed to create new player - limit reached")
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
                                Image(systemName: streamType == .hls ? "play.tv" : "play.circle.fill")
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
        case .alternative:
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
        
        // Auto-hide error after 10 seconds (longer display time)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            showError = false
        }
        
        // REMOVED: Auto-switching to WebRTC
        // HLS has proper retry logic now - let it exhaust retries first
        // User can manually switch if needed
    }
    
    private func switchStreamType() {
        isRetrying = true
        playerManager.releasePlayer(for: camera.id)
        
        streamType = streamType == .hls ? .alternative : .hls
        
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
                    Text("Try Alternative Stream")
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