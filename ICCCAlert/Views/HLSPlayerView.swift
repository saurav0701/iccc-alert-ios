import SwiftUI
import AVKit
import AVFoundation

// MARK: - Player Manager (Maximum 2 concurrent players to prevent crashes)
class HLSPlayerManager: ObservableObject {
    static let shared = HLSPlayerManager()
    
    private var activePlayers: [String: AVPlayer] = [:]
    private let lock = NSLock()
    private let maxPlayers = 2 // Strict limit: only 2 concurrent streams
    
    @Published var activePlayerCount = 0
    
    private init() {
        // Monitor memory warnings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }
    
    @objc private func handleMemoryWarning() {
        print("⚠️ MEMORY WARNING - Releasing all players")
        releaseAllPlayers()
    }
    
    func getPlayer(for cameraId: String, streamURL: URL) -> AVPlayer? {
        lock.lock()
        defer { 
            lock.unlock()
            updatePlayerCount()
        }
        
        // Return existing player if available
        if let existingPlayer = activePlayers[cameraId] {
            print("♻️ Reusing player for: \(cameraId)")
            return existingPlayer
        }
        
        // Check player limit
        if activePlayers.count >= maxPlayers {
            print("⚠️ Player limit reached (\(maxPlayers)), cannot create new player")
            return nil
        }
        
        // Create new player
        let player = AVPlayer(url: streamURL)
        player.allowsExternalPlayback = false
        player.automaticallyWaitsToMinimizeStalling = true
        
        activePlayers[cameraId] = player
        print("✅ Created player for: \(cameraId) (Total: \(activePlayers.count))")
        
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
        
        // Stop playback
        player.pause()
        player.replaceCurrentItem(with: nil)
        
        print("🗑️ Released player: \(cameraId) (Remaining: \(activePlayers.count))")
    }
    
    func releaseAllPlayers() {
        lock.lock()
        defer { 
            lock.unlock()
            updatePlayerCount()
        }
        
        print("🧹 Releasing all players (\(activePlayers.count))")
        
        activePlayers.forEach { (id, player) in
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        
        activePlayers.removeAll()
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

// MARK: - HLS Player View
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
        
        // Try to get or create player
        if let player = playerManager.getPlayer(for: cameraId, streamURL: streamURL) {
            controller.player = player
            
            if autoPlay {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    player.play()
                }
            }
        } else {
            // Player limit reached
            context.coordinator.showError = true
        }
        
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
    
    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.cleanup()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(cameraId: cameraId)
    }
    
    class Coordinator {
        let cameraId: String
        var showError = false
        
        init(cameraId: String) {
            self.cameraId = cameraId
        }
        
        func cleanup() {
            HLSPlayerManager.shared.releasePlayer(for: cameraId)
        }
    }
}

// MARK: - Camera Thumbnail (Static - No Auto-Loading)
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

// MARK: - Fullscreen Player View
struct FullscreenHLSPlayerView: View {
    let camera: Camera
    @Environment(\.presentationMode) var presentationMode
    @StateObject private var playerManager = HLSPlayerManager.shared
    
    @State private var showError = false
    @State private var errorMessage = ""
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let streamURL = camera.streamURL, let url = URL(string: streamURL) {
                if playerManager.activePlayerCount >= 2 {
                    // Player limit reached
                    playerLimitView
                } else {
                    HLSPlayerView(streamURL: url, cameraId: camera.id, autoPlay: true)
                        .ignoresSafeArea()
                }
            } else {
                errorView(message: "Stream URL not available")
            }
            
            // Close button overlay
            VStack {
                HStack {
                    Button(action: {
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .semibold))
                            Text("Back")
                                .font(.headline)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(10)
                    }
                    
                    Spacer()
                }
                .padding()
                
                Spacer()
                
                // Camera info overlay
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
            // Cleanup when dismissed
            playerManager.releasePlayer(for: camera.id)
        }
    }
    
    private var playerLimitView: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            
            Text("Player Limit Reached")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text("Only 2 cameras can play simultaneously.\nClose another camera first.")
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