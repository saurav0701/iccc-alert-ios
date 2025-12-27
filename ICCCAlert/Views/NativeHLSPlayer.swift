import SwiftUI
import AVKit
import AVFoundation

// ✅ COMPLETE REWRITE: Use native AVPlayer instead of WebView
// This is MUCH more stable and efficient for HLS streams

// MARK: - Player Manager (Singleton for resource management)
class PlayerManager: ObservableObject {
    static let shared = PlayerManager()
    
    private var players: [String: AVPlayer] = [:]
    private let lock = NSLock()
    private let maxPlayers = 4 // Only allow 4 concurrent players
    
    private init() {
        setupAudioSession()
    }
    
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("❌ Audio session setup failed: \(error)")
        }
    }
    
    func getPlayer(for cameraId: String, url: URL) -> AVPlayer {
        lock.lock()
        defer { lock.unlock() }
        
        if let existing = players[cameraId] {
            print("♻️ Reusing player for: \(cameraId)")
            return existing
        }
        
        // Clean up if we have too many players
        if players.count >= maxPlayers {
            let oldestKey = players.keys.first!
            if let oldPlayer = players.removeValue(forKey: oldestKey) {
                oldPlayer.pause()
                oldPlayer.replaceCurrentItem(with: nil)
                print("🗑️ Removed old player: \(oldestKey)")
            }
        }
        
        let player = AVPlayer(url: url)
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = false
        
        players[cameraId] = player
        print("🆕 Created new player for: \(cameraId)")
        return player
    }
    
    func releasePlayer(_ cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        if let player = players[cameraId] {
            player.pause()
            player.replaceCurrentItem(with: nil)
            players.removeValue(forKey: cameraId)
            print("📤 Released player: \(cameraId)")
        }
    }
    
    func pausePlayer(_ cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        players[cameraId]?.pause()
    }
    
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        
        players.values.forEach { player in
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        players.removeAll()
        print("🧹 Cleared all players")
    }
}

// MARK: - Native Video Player View
struct NativeVideoPlayer: UIViewControllerRepresentable {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.showsPlaybackControls = isFullscreen
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = false
        
        guard let url = URL(string: streamURL) else {
            DispatchQueue.main.async {
                self.errorMessage = "Invalid stream URL"
                self.isLoading = false
            }
            return controller
        }
        
        let player = PlayerManager.shared.getPlayer(for: cameraId, url: url)
        controller.player = player
        
        // Add observer for player status
        context.coordinator.setupObservers(for: player)
        
        // Auto-play for fullscreen only
        if isFullscreen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                player.play()
            }
        }
        
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        // Only update if URL changed
        guard let currentURL = (uiViewController.player?.currentItem?.asset as? AVURLAsset)?.url,
              currentURL.absoluteString != streamURL else {
            return
        }
        
        // URL changed, create new player
        guard let url = URL(string: streamURL) else { return }
        
        let player = PlayerManager.shared.getPlayer(for: cameraId, url: url)
        uiViewController.player = player
        context.coordinator.setupObservers(for: player)
        
        if isFullscreen {
            player.play()
        }
    }
    
    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.cleanup()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator {
        var parent: NativeVideoPlayer
        private var statusObserver: NSKeyValueObservation?
        private var timeControlObserver: NSKeyValueObservation?
        private var errorObserver: NSKeyValueObservation?
        
        init(_ parent: NativeVideoPlayer) {
            self.parent = parent
        }
        
        func setupObservers(for player: AVPlayer) {
            cleanup()
            
            // Observe status
            statusObserver = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard let self = self else { return }
                
                DispatchQueue.main.async {
                    switch item.status {
                    case .readyToPlay:
                        print("✅ Player ready: \(self.parent.cameraId)")
                        self.parent.isLoading = false
                        self.parent.errorMessage = nil
                        
                    case .failed:
                        print("❌ Player failed: \(self.parent.cameraId)")
                        let error = item.error?.localizedDescription ?? "Unknown error"
                        self.parent.errorMessage = error
                        self.parent.isLoading = false
                        
                    case .unknown:
                        print("⏳ Player loading: \(self.parent.cameraId)")
                        self.parent.isLoading = true
                        
                    @unknown default:
                        break
                    }
                }
            }
            
            // Observe playback state
            timeControlObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                guard let self = self else { return }
                
                DispatchQueue.main.async {
                    switch player.timeControlStatus {
                    case .playing:
                        print("▶️ Playing: \(self.parent.cameraId)")
                        self.parent.isLoading = false
                        
                    case .paused:
                        print("⏸️ Paused: \(self.parent.cameraId)")
                        
                    case .waitingToPlayAtSpecifiedRate:
                        print("⏳ Buffering: \(self.parent.cameraId)")
                        self.parent.isLoading = true
                        
                    @unknown default:
                        break
                    }
                }
            }
            
            // Observe errors
            errorObserver = player.currentItem?.observe(\.error, options: [.new]) { [weak self] item, _ in
                guard let self = self, let error = item.error else { return }
                
                DispatchQueue.main.async {
                    print("❌ Playback error: \(error.localizedDescription)")
                    self.parent.errorMessage = error.localizedDescription
                    self.parent.isLoading = false
                }
            }
        }
        
        func cleanup() {
            statusObserver?.invalidate()
            timeControlObserver?.invalidate()
            errorObserver?.invalidate()
            statusObserver = nil
            timeControlObserver = nil
            errorObserver = nil
        }
        
        deinit {
            cleanup()
        }
    }
}

// MARK: - Camera Thumbnail (Using Native Player)
struct CameraThumbnail: View {
    let camera: Camera
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var shouldLoad = false
    @State private var isVisible = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let streamURL = camera.streamURL, camera.isOnline {
                    if shouldLoad {
                        NativeVideoPlayer(
                            streamURL: streamURL,
                            cameraId: camera.id,
                            isFullscreen: false,
                            isLoading: $isLoading,
                            errorMessage: $errorMessage
                        )
                        .onAppear {
                            print("📹 Thumbnail appeared: \(camera.displayName)")
                        }
                        .onDisappear {
                            print("📤 Thumbnail disappeared: \(camera.displayName)")
                            PlayerManager.shared.pausePlayer(camera.id)
                        }
                    } else {
                        placeholderView
                    }
                    
                    if isLoading && shouldLoad {
                        loadingOverlay
                    }
                    
                    if let error = errorMessage {
                        errorOverlay(error)
                    }
                    
                    if !isLoading && errorMessage == nil && shouldLoad {
                        liveIndicator
                    }
                } else {
                    offlineView
                }
            }
            .onChange(of: geometry.frame(in: .global).minY) { minY in
                let screenHeight = UIScreen.main.bounds.height
                let isInView = minY > -geometry.size.height && minY < screenHeight
                
                if isInView && !isVisible {
                    isVisible = true
                    // Delay loading to stagger multiple thumbnails
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        shouldLoad = true
                    }
                } else if !isInView && isVisible {
                    isVisible = false
                    // Pause when scrolled out of view
                    PlayerManager.shared.pausePlayer(camera.id)
                }
            }
        }
    }
    
    private var placeholderView: some View {
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
                Image(systemName: "video.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.gray)
                Text("Tap to load")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
        }
        .onTapGesture {
            shouldLoad = true
        }
    }
    
    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.6)
            VStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                Text("Loading...")
                    .font(.caption2)
                    .foregroundColor(.white)
            }
        }
    }
    
    private func errorOverlay(_ error: String) -> some View {
        ZStack {
            Color.black.opacity(0.8)
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.orange)
                
                Text("Stream Error")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                
                Text(error.prefix(50))
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
                
                Button(action: {
                    errorMessage = nil
                    isLoading = true
                    shouldLoad = false
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        PlayerManager.shared.releasePlayer(camera.id)
                        shouldLoad = true
                    }
                }) {
                    Text("Retry")
                        .font(.system(size: 10))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color.blue)
                        .cornerRadius(4)
                }
                .padding(.top, 4)
            }
            .padding(8)
        }
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

// MARK: - Fullscreen Player View
struct HLSPlayerView: View {
    let camera: Camera
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let streamURL = camera.streamURL {
                NativeVideoPlayer(
                    streamURL: streamURL,
                    cameraId: camera.id,
                    isFullscreen: true,
                    isLoading: $isLoading,
                    errorMessage: $errorMessage
                )
                .ignoresSafeArea()
            } else {
                errorView("Stream URL not available")
            }
            
            // Close button
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
            
            if isLoading {
                loadingView
            }
            
            if let error = errorMessage {
                errorView(error)
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .onDisappear {
            PlayerManager.shared.releasePlayer(camera.id)
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
            
            Text("Connecting...")
                .font(.headline)
                .foregroundColor(.white)
            
            Text(camera.displayName)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.7))
    }
    
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            
            Text("Stream Error")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text(message)
                .font(.body)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            HStack(spacing: 16) {
                Button(action: {
                    errorMessage = nil
                    isLoading = true
                    PlayerManager.shared.releasePlayer(camera.id)
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
                
                Button(action: {
                    presentationMode.wrappedValue.dismiss()
                }) {
                    HStack {
                        Image(systemName: "arrow.left")
                        Text("Back")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.gray)
                    .cornerRadius(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.8))
    }
}