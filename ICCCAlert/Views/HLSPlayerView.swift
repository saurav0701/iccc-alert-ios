import SwiftUI
import AVKit
import AVFoundation

// MARK: - Stream Type
enum StreamType {
    case hls
    case webrtc
}

// MARK: - Player Manager (IMPROVED - 4 Concurrent Players)
class HLSPlayerManager: ObservableObject {
    static let shared = HLSPlayerManager()
    
    private var activePlayers: [String: AVPlayer] = [:]
    private var playerObservers: [String: NSKeyValueObservation] = [:]
    private let lock = NSLock()
    private let maxPlayers = 4 // Allow up to 4 concurrent players
    
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
        
        // Return existing player
        if let existingPlayer = activePlayers[cameraId] {
            print("♻️ Reusing player: \(cameraId)")
            return existingPlayer
        }
        
        // Check limit
        if activePlayers.count >= maxPlayers {
            print("⚠️ Player limit reached (\(maxPlayers))")
            return nil
        }
        
        // Create new player with optimized settings
        let asset = AVURLAsset(url: streamURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
            "AVURLAssetHTTPHeaderFieldsKey": [
                "Connection": "keep-alive"
            ]
        ])
        
        let playerItem = AVPlayerItem(asset: asset)
        
        // Optimized buffer settings for live streaming
        playerItem.preferredForwardBufferDuration = preferredBufferDuration
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        
        let player = AVPlayer(playerItem: playerItem)
        player.allowsExternalPlayback = false
        player.automaticallyWaitsToMinimizeStalling = true
        
        // Add observer for playback status
        let observer = player.observe(\.currentItem?.status, options: [.new]) { [weak self] player, change in
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
        
        activePlayers.forEach { (id, player) in
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

// MARK: - HLS Player View (IMPROVED with Auto-Recovery)
struct HLSPlayerView: UIViewControllerRepresentable {
    let streamURL: URL
    let cameraId: String
    let autoPlay: Bool
    let streamType: StreamType
    
    @StateObject private var playerManager = HLSPlayerManager.shared
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = false
        controller.videoGravity = .resizeAspect
        
        // Use shorter buffer for live streams
        let bufferDuration: TimeInterval = streamType == .hls ? 3.0 : 2.0
        
        if let player = playerManager.getPlayer(for: cameraId, streamURL: streamURL, preferredBufferDuration: bufferDuration) {
            controller.player = player
            
            if autoPlay {
                // Delay play slightly to allow buffering
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    player.play()
                    
                    // Monitor for stalls
                    context.coordinator.monitorPlayback(player: player)
                }
            }
        } else {
            print("❌ Cannot create player (limit reached)")
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
        Coordinator(cameraId: cameraId, streamURL: streamURL, streamType: streamType)
    }
    
    class Coordinator {
        let cameraId: String
        let streamURL: URL
        let streamType: StreamType
        private var stallTimer: Timer?
        private var retryCount = 0
        private let maxRetries = 3
        
        init(cameraId: String, streamURL: URL, streamType: StreamType) {
            self.cameraId = cameraId
            self.streamURL = streamURL
            self.streamType = streamType
        }
        
        func monitorPlayback(player: AVPlayer) {
            // Cancel existing timer
            stallTimer?.invalidate()
            
            // Check if playback is progressing
            stallTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self, weak player] _ in
                guard let self = self, let player = player else { return }
                
                if player.rate == 0 && player.currentItem?.status == .readyToPlay {
                    print("⚠️ Playback stalled for \(self.cameraId), attempting recovery...")
                    
                    if self.retryCount < self.maxRetries {
                        self.retryCount += 1
                        
                        // Try to resume
                        player.seek(to: CMTime.zero)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            player.play()
                        }
                    } else {
                        print("❌ Max retries reached for \(self.cameraId)")
                        self.stallTimer?.invalidate()
                    }
                }
            }
        }
        
        func cleanup() {
            stallTimer?.invalidate()
            HLSPlayerManager.shared.releasePlayer(for: cameraId)
        }
    }
}

// MARK: - Camera Thumbnail (Static Placeholder)
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

// MARK: - Fullscreen Player with HLS/WebRTC Toggle
struct FullscreenHLSPlayerView: View {
    let camera: Camera
    @Environment(\.presentationMode) var presentationMode
    @StateObject private var playerManager = HLSPlayerManager.shared
    
    @State private var streamType: StreamType = .hls
    @State private var showStreamTypeSelector = false
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let streamURL = getStreamURL() {
                if !playerManager.canCreatePlayer(for: camera.id) {
                    playerLimitView
                } else {
                    HLSPlayerView(streamURL: streamURL, cameraId: camera.id, autoPlay: true, streamType: streamType)
                        .ignoresSafeArea()
                }
            } else {
                errorView(message: "Stream URL not available")
            }
            
            // Controls overlay
            VStack {
                HStack {
                    // Close button
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
                    
                    // Stream type toggle (only if WebRTC available)
                    if camera.webrtcStreamURL != nil {
                        Button(action: {
                            streamType = streamType == .hls ? .webrtc : .hls
                            playerManager.releasePlayer(for: camera.id)
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: streamType == .hls ? "play.tv" : "antenna.radiowaves.left.and.right")
                                Text(streamType == .hls ? "HLS" : "WebRTC")
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
        }
    }
}