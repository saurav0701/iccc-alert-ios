import SwiftUI
import AVKit
import AVFoundation

// MARK: - Player Manager with Better Format Handling
class PlayerManager: ObservableObject {
    static let shared = PlayerManager()
    
    private var players: [String: AVPlayer] = [:]
    private let lock = NSLock()
    private let maxPlayers = 2
    
    private init() {
        setupAudioSession()
    }
    
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers, .allowAirPlay])
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
   
        if players.count >= maxPlayers {
            let oldestKey = players.keys.first!
            releasePlayerInternal(oldestKey)
        }
        
        // Use minimal options to let AVFoundation handle format detection
        let asset = AVURLAsset(url: url)
        
        // Load asset properties asynchronously
        asset.loadValuesAsynchronously(forKeys: ["playable", "tracks"]) {
            var error: NSError?
            let status = asset.statusOfValue(forKey: "playable", error: &error)
            
            if status == .loaded {
                print("✅ Asset loaded successfully for \(cameraId)")
            } else if status == .failed {
                print("❌ Asset failed to load: \(error?.localizedDescription ?? "unknown")")
            }
        }
        
        let playerItem = AVPlayerItem(asset: asset)
        
        // Minimal buffer settings - let iOS decide
        playerItem.preferredForwardBufferDuration = 5.0
        
        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = false
        
        players[cameraId] = player
        print("🆕 Created new player for: \(cameraId)")
        
        return player
    }
    
    private func releasePlayerInternal(_ cameraId: String) {
        if let player = players.removeValue(forKey: cameraId) {
            player.pause()
            player.replaceCurrentItem(with: nil)
            print("🗑️ Removed player: \(cameraId)")
        }
    }
    
    func releasePlayer(_ cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        releasePlayerInternal(cameraId)
    }
    
    func pausePlayer(_ cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        players[cameraId]?.pause()
    }
    
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        
        players.keys.forEach { releasePlayerInternal($0) }
        print("🧹 Cleared all players")
    }
}

// MARK: - Simple Native Player (Minimal Approach)
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
                self.errorMessage = "Invalid URL"
                self.isLoading = false
            }
            return controller
        }
        
        let player = PlayerManager.shared.getPlayer(for: cameraId, url: url)
        controller.player = player
        
        context.coordinator.setupObservers(for: player)
        
        if isFullscreen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                player.play()
            }
        }
        
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
    
    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.cleanup()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator {
        var parent: NativeVideoPlayer
        private var observations: [NSKeyValueObservation] = []
        private var notificationObservers: [Any] = []
        
        init(_ parent: NativeVideoPlayer) {
            self.parent = parent
        }
        
        func setupObservers(for player: AVPlayer) {
            cleanup()
            
            guard let item = player.currentItem else { return }
            
            // Status observer
            observations.append(
                item.observe(\.status) { [weak self] item, _ in
                    guard let self = self else { return }
                    DispatchQueue.main.async {
                        switch item.status {
                        case .readyToPlay:
                            print("✅ Ready: \(self.parent.cameraId)")
                            self.parent.isLoading = false
                            self.parent.errorMessage = nil
                            
                        case .failed:
                            print("❌ Failed: \(self.parent.cameraId)")
                            self.handleError(item.error)
                            
                        case .unknown:
                            self.parent.isLoading = true
                            
                        @unknown default:
                            break
                        }
                    }
                }
            )
            
            // Error observer
            observations.append(
                item.observe(\.error) { [weak self] item, _ in
                    guard let self = self, let error = item.error else { return }
                    DispatchQueue.main.async {
                        self.handleError(error)
                    }
                }
            )
            
            // Stalled notification
            let stalledObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemPlaybackStalled,
                object: item,
                queue: .main
            ) { [weak self] _ in
                print("⚠️ Stalled: \(self?.parent.cameraId ?? "")")
            }
            notificationObservers.append(stalledObserver)
        }
        
        private func handleError(_ error: Error?) {
            guard let error = error else { return }
            let nsError = error as NSError
            
            print("❌ Error -\(nsError.code): \(nsError.localizedDescription)")
            
            let message: String
            switch nsError.code {
            case -11867:
                message = "Stream format not supported by iOS. Server needs to re-encode video."
            case -12938, -12939, -12940:
                message = "Invalid stream format. Contact server admin."
            case -1100:
                message = "Stream not found. Camera offline?"
            case -1001:
                message = "Connection timeout. Check network."
            case -1009:
                message = "No internet connection."
            default:
                message = "Error \(nsError.code): Stream unavailable"
            }
            
            parent.errorMessage = message
            parent.isLoading = false
        }
        
        func cleanup() {
            observations.forEach { $0.invalidate() }
            observations.removeAll()
            
            notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
            notificationObservers.removeAll()
        }
        
        deinit {
            cleanup()
        }
    }
}

// MARK: - Camera Thumbnail
struct CameraThumbnail: View {
    let camera: Camera
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var shouldLoad = false
    
    var body: some View {
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
                } else {
                    placeholderView
                }
                
                if isLoading && shouldLoad && errorMessage == nil {
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
        .onAppear {
            // Don't auto-load thumbnails - wait for user tap
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
                    Color.gray.opacity(0.3),
                    Color.gray.opacity(0.1)
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
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
        }
    }
    
    private func errorOverlay(_ error: String) -> some View {
        ZStack {
            Color.black.opacity(0.9)
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.orange)
                
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                    .lineLimit(4)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                
                Button(action: {
                    errorMessage = nil
                    isLoading = true
                    shouldLoad = false
                    PlayerManager.shared.releasePlayer(camera.id)
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        shouldLoad = true
                    }
                }) {
                    Text("Retry")
                        .font(.system(size: 12))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.blue)
                        .cornerRadius(6)
                }
            }
            .padding()
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

// MARK: - Fullscreen Player
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
                errorView("No stream URL")
            }
            
            // Header with close button
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
            
            if isLoading && errorMessage == nil {
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
            
            Text("Loading stream...")
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
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            
            VStack(spacing: 12) {
                Text("Stream Unavailable")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text(message)
                    .font(.body)
                    .foregroundColor(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                
                if message.contains("-11867") || message.contains("format") {
                    VStack(spacing: 8) {
                        Text("Technical Details:")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                        
                        Text("The video server is using an incompatible encoding format. The server administrator needs to re-encode streams to H.264/AAC format for iOS compatibility.")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                    .padding(.top, 8)
                }
            }
            
            HStack(spacing: 16) {
                Button(action: {
                    errorMessage = nil
                    isLoading = true
                    PlayerManager.shared.releasePlayer(camera.id)
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        isLoading = true
                    }
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
                    PlayerManager.shared.releasePlayer(camera.id)
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
        .background(Color.black.opacity(0.9))
    }
}