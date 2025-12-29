import SwiftUI
import AVKit
import AVFoundation

// MARK: - Native Player Manager (H.265 Compatible)
class NativePlayerManager: ObservableObject {
    static let shared = NativePlayerManager()
    
    private var activePlayers: [String: AVPlayer] = [:]
    private var playerObservers: [String: NSKeyValueObservation] = [:]
    private let lock = NSLock()
    private let maxPlayers = 2
    
    private init() {}
    
    func getPlayer(for cameraId: String, url: URL) -> AVPlayer {
        lock.lock()
        defer { lock.unlock() }
        
        // Return existing player if available
        if let existingPlayer = activePlayers[cameraId] {
            print("♻️ Reusing existing player for: \(cameraId)")
            return existingPlayer
        }
        
        // Limit concurrent players for memory management
        if activePlayers.count >= maxPlayers {
            if let oldestKey = activePlayers.keys.first {
                releasePlayerInternal(oldestKey)
            }
        }
        
        // Create new AVPlayer with optimal settings
        let playerItem = AVPlayerItem(url: url)
        playerItem.preferredForwardBufferDuration = 3.0
        
        let player = AVPlayer(playerItem: playerItem)
        player.allowsExternalPlayback = false
        player.automaticallyWaitsToMinimizeStalling = true
        
        activePlayers[cameraId] = player
        
        print("📹 Created native AVPlayer for: \(cameraId)")
        print("   URL: \(url.absoluteString)")
        
        return player
    }
    
    private func releasePlayerInternal(_ cameraId: String) {
        if let player = activePlayers.removeValue(forKey: cameraId) {
            player.pause()
            player.replaceCurrentItem(with: nil)
            
            // Remove observer
            playerObservers.removeValue(forKey: cameraId)
            
            print("🗑️ Released native player: \(cameraId)")
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
        print("🧹 Cleared all native players")
    }
}

// MARK: - Native HLS Player (Thumbnail View)
struct NativeHLSPlayerThumbnail: View {
    let streamURL: String
    let cameraId: String
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var hasError = false
    @State private var statusMessage = "Initializing..."
    
    var body: some View {
        ZStack {
            if let player = player {
                VideoPlayer(player: player)
                    .onAppear {
                        player.play()
                    }
            } else {
                Color.black
            }
            
            // Loading overlay
            if isLoading && !hasError {
                VStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    
                    Text("Loading...")
                        .font(.caption)
                        .foregroundColor(.white)
                }
                .padding()
                .background(Color.black.opacity(0.7))
                .cornerRadius(10)
            }
            
            // Error overlay
            if hasError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.orange)
                    
                    Text("Stream Error")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                    
                    Text(statusMessage)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(Color.black.opacity(0.8))
                .cornerRadius(10)
            }
            
            // LIVE indicator (only show when playing)
            if !isLoading && !hasError {
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
            setupPlayer()
        }
        .onDisappear {
            cleanup()
        }
    }
    
    private func setupPlayer() {
        guard let url = URL(string: streamURL) else {
            hasError = true
            statusMessage = "Invalid URL"
            return
        }
        
        DebugLogger.shared.log("📹 Setting up native player for: \(cameraId)", emoji: "📹", color: .blue)
        DebugLogger.shared.log("   URL: \(streamURL)", emoji: "🔗", color: .gray)
        
        // Get player from manager
        let avPlayer = NativePlayerManager.shared.getPlayer(for: cameraId, url: url)
        self.player = avPlayer
        
        // Observe player status
        avPlayer.currentItem?.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
        
        // Monitor playback
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: avPlayer.currentItem,
            queue: .main
        ) { notification in
            handlePlaybackError(notification)
        }
        
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewAccessLogEntry,
            object: avPlayer.currentItem,
            queue: .main
        ) { _ in
            isLoading = false
            hasError = false
            DebugLogger.shared.log("✅ Stream playing: \(cameraId)", emoji: "✅", color: .green)
        }
        
        // Auto-play
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            avPlayer.play()
        }
    }
    
    private func handlePlaybackError(_ notification: Notification) {
        isLoading = false
        hasError = true
        
        if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
            statusMessage = error.localizedDescription
            DebugLogger.shared.log("❌ Playback error: \(error.localizedDescription)", emoji: "❌", color: .red)
        } else {
            statusMessage = "Cannot load stream"
            DebugLogger.shared.log("❌ Unknown playback error", emoji: "❌", color: .red)
        }
    }
    
    private func cleanup() {
        player?.pause()
        NativePlayerManager.shared.releasePlayer(cameraId)
        player = nil
        
        NotificationCenter.default.removeObserver(self)
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "status",
           let playerItem = object as? AVPlayerItem {
            
            switch playerItem.status {
            case .readyToPlay:
                isLoading = false
                hasError = false
                DebugLogger.shared.log("✅ Player ready: \(cameraId)", emoji: "✅", color: .green)
                
            case .failed:
                isLoading = false
                hasError = true
                
                if let error = playerItem.error {
                    statusMessage = error.localizedDescription
                    DebugLogger.shared.log("❌ Player failed: \(error.localizedDescription)", emoji: "❌", color: .red)
                } else {
                    statusMessage = "Playback failed"
                }
                
            case .unknown:
                isLoading = true
                
            @unknown default:
                break
            }
        }
    }
}

// MARK: - Native HLS Fullscreen Player
struct NativeHLSPlayerFullscreen: View {
    let camera: Camera
    @Environment(\.presentationMode) var presentationMode
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var hasError = false
    @State private var errorMessage = ""
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let player = player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }
            
            // Loading overlay
            if isLoading && !hasError {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    
                    Text("Loading Stream...")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Text(camera.displayName)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding(24)
                .background(Color.black.opacity(0.7))
                .cornerRadius(16)
            }
            
            // Error overlay
            if hasError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.orange)
                    
                    Text("Stream Error")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Button(action: {
                        retry()
                    }) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Retry")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.blue)
                        .cornerRadius(10)
                    }
                }
                .padding(24)
                .background(Color.black.opacity(0.8))
                .cornerRadius(16)
            }
            
            // Top bar (camera info + close button)
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
                        cleanup()
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
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            cleanup()
        }
    }
    
    private func setupPlayer() {
        guard let streamURL = camera.streamURL,
              let url = URL(string: streamURL) else {
            hasError = true
            errorMessage = "Invalid stream URL"
            return
        }
        
        DebugLogger.shared.log("📹 Opening fullscreen player: \(camera.displayName)", emoji: "📹", color: .blue)
        DebugLogger.shared.log("   URL: \(streamURL)", emoji: "🔗", color: .gray)
        
        // Get player from manager
        let avPlayer = NativePlayerManager.shared.getPlayer(for: camera.id, url: url)
        self.player = avPlayer
        
        // Observe player status
        avPlayer.currentItem?.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
        
        // Monitor errors
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: avPlayer.currentItem,
            queue: .main
        ) { notification in
            handlePlaybackError(notification)
        }
        
        // Monitor successful playback
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewAccessLogEntry,
            object: avPlayer.currentItem,
            queue: .main
        ) { _ in
            isLoading = false
            hasError = false
            DebugLogger.shared.log("✅ Fullscreen stream playing", emoji: "✅", color: .green)
        }
        
        // Auto-play
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            avPlayer.play()
        }
    }
    
    private func handlePlaybackError(_ notification: Notification) {
        isLoading = false
        hasError = true
        
        if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
            errorMessage = error.localizedDescription
            DebugLogger.shared.log("❌ Fullscreen playback error: \(error.localizedDescription)", emoji: "❌", color: .red)
        } else {
            errorMessage = "Cannot load stream. Check your network connection."
        }
    }
    
    private func retry() {
        hasError = false
        isLoading = true
        cleanup()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            setupPlayer()
        }
    }
    
    private func cleanup() {
        player?.pause()
        NativePlayerManager.shared.releasePlayer(camera.id)
        player = nil
        
        NotificationCenter.default.removeObserver(self)
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "status",
           let playerItem = object as? AVPlayerItem {
            
            switch playerItem.status {
            case .readyToPlay:
                isLoading = false
                hasError = false
                DebugLogger.shared.log("✅ Fullscreen player ready", emoji: "✅", color: .green)
                
            case .failed:
                isLoading = false
                hasError = true
                
                if let error = playerItem.error {
                    errorMessage = error.localizedDescription
                    DebugLogger.shared.log("❌ Fullscreen player failed: \(error.localizedDescription)", emoji: "❌", color: .red)
                } else {
                    errorMessage = "Playback failed"
                }
                
            case .unknown:
                isLoading = true
                
            @unknown default:
                break
            }
        }
    }
}

// MARK: - Camera Thumbnail (Updated to use Native Player)
struct CameraThumbnail: View {
    let camera: Camera
    @State private var shouldLoad = false
    
    var body: some View {
        ZStack {
            if let streamURL = camera.streamURL, camera.isOnline {
                if shouldLoad {
                    NativeHLSPlayerThumbnail(
                        streamURL: streamURL,
                        cameraId: camera.id
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
            NativePlayerManager.shared.releasePlayer(camera.id)
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

// MARK: - Fullscreen Player View (Updated)
struct HLSPlayerView: View {
    let camera: Camera
    
    var body: some View {
        NativeHLSPlayerFullscreen(camera: camera)
    }
}