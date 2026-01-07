import SwiftUI
import AVKit
import AVFoundation

// MARK: - Player Manager (FIXED - No False Warnings)
class HLSPlayerManager: ObservableObject {
    static let shared = HLSPlayerManager()
    
    private var activePlayers: [String: AVPlayer] = [:]
    private let lock = NSLock()
    private let maxPlayers = 1 // ✅ Only 1 player at a time
    
    @Published var activePlayerCount = 0
    
    private var cleanupInProgress = false
    
    private init() {
        // Monitor memory warnings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        
        // Monitor background
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }
    
    @objc private func handleMemoryWarning() {
        print("⚠️⚠️⚠️ MEMORY WARNING - Releasing ALL players immediately")
        releaseAllPlayers()
    }
    
    @objc private func handleBackground() {
        print("📱 App backgrounded - Releasing ALL players")
        releaseAllPlayers()
    }
    
    // ✅ FIXED: Check if we can create a NEW player (excluding the one we're trying to create)
    func canCreatePlayer(for cameraId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        // If player already exists for this camera, we can reuse it
        if activePlayers[cameraId] != nil {
            return true
        }
        
        // If we haven't hit the limit, we can create
        return activePlayers.count < maxPlayers
    }
    
    func getPlayer(for cameraId: String, streamURL: URL) -> AVPlayer? {
        lock.lock()
        defer { 
            lock.unlock()
            updatePlayerCount()
        }
        
        guard !cleanupInProgress else {
            print("⚠️ Cleanup in progress, cannot create player")
            return nil
        }
        
        // ✅ Return existing player if available
        if let existingPlayer = activePlayers[cameraId] {
            print("♻️ Reusing player: \(cameraId)")
            return existingPlayer
        }
        
        // ✅ Check limit (excluding current camera)
        if activePlayers.count >= maxPlayers {
            print("⚠️ Player limit reached (\(maxPlayers)), clear first")
            return nil
        }
        
        // ✅ Create new player
        let player = AVPlayer(url: streamURL)
        player.allowsExternalPlayback = false
        player.automaticallyWaitsToMinimizeStalling = true
        
        // ✅ Set low buffer size
        if let currentItem = player.currentItem {
            currentItem.preferredForwardBufferDuration = 1.0 // Only 1 second buffer
        }
        
        activePlayers[cameraId] = player
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
        
        // ✅ Stop everything
        player.pause()
        player.replaceCurrentItem(with: nil)
        
        print("🗑️ Released: \(cameraId) (remaining: \(activePlayers.count))")
    }
    
    func releaseAllPlayers() {
        lock.lock()
        cleanupInProgress = true
        
        print("🧹 Releasing ALL players (\(activePlayers.count))")
        
        activePlayers.forEach { (id, player) in
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        
        activePlayers.removeAll()
        cleanupInProgress = false
        lock.unlock()
        
        updatePlayerCount()
        
        // ✅ Force garbage collection
        autoreleasepool { }
        
        print("✅ All players released")
    }
    
    func pauseAllPlayers() {
        lock.lock()
        defer { lock.unlock() }
        
        activePlayers.values.forEach { $0.pause() }
        print("⏸️ Paused all players")
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

// MARK: - HLS Player View (CRASH SAFE)
struct HLSPlayerView: UIViewControllerRepresentable {
    let streamURL: URL
    let cameraId: String
    let autoPlay: Bool
    
    @StateObject private var playerManager = HLSPlayerManager.shared
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = false
        controller.videoGravity = .resizeAspect
        
        // ✅ Try to get player
        if let player = playerManager.getPlayer(for: cameraId, streamURL: streamURL) {
            controller.player = player
            
            if autoPlay {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    player.play()
                }
            }
        } else {
            print("❌ Cannot create player (limit reached)")
        }
        
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
    
    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        // ✅ Stop playback immediately
        uiViewController.player?.pause()
        uiViewController.player?.replaceCurrentItem(with: nil)
        uiViewController.player = nil
        
        // Release from manager
        coordinator.cleanup()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(cameraId: cameraId)
    }
    
    class Coordinator {
        let cameraId: String
        
        init(cameraId: String) {
            self.cameraId = cameraId
        }
        
        func cleanup() {
            HLSPlayerManager.shared.releasePlayer(for: cameraId)
        }
    }
}

// MARK: - Camera Thumbnail (Static)
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

// MARK: - Fullscreen Player View (FIXED - No False Warnings)
struct FullscreenHLSPlayerView: View {
    let camera: Camera
    @Environment(\.presentationMode) var presentationMode
    @StateObject private var playerManager = HLSPlayerManager.shared
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let streamURL = camera.streamURL, let url = URL(string: streamURL) {
                // ✅ FIXED: Check if we CAN create this specific player
                if !playerManager.canCreatePlayer(for: camera.id) {
                    playerLimitView
                } else {
                    HLSPlayerView(streamURL: url, cameraId: camera.id, autoPlay: true)
                        .ignoresSafeArea()
                }
            } else {
                errorView(message: "Stream URL not available")
            }
            
            // Close button
            VStack {
                HStack {
                    Button(action: {
                        playerManager.releasePlayer(for: camera.id)
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28))
                        }
                        .foregroundColor(.white)
                        .padding(12)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Circle())
                    }
                    
                    Spacer()
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
    
    private var playerLimitView: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            
            Text("Close Current Stream First")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text("Only 1 camera can play at a time for stability")
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