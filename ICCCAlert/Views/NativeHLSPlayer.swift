import SwiftUI
import AVKit
import AVFoundation

class PlayerManager: ObservableObject {
    static let shared = PlayerManager()
    
    private var players: [String: AVPlayer] = [:]
    private var playerItems: [String: AVPlayerItem] = [:]
    private let lock = NSLock()
    private let maxPlayers = 4 
    
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
   
        if players.count >= maxPlayers {
            let oldestKey = players.keys.first!
            if let oldPlayer = players.removeValue(forKey: oldestKey) {
                oldPlayer.pause()
                oldPlayer.replaceCurrentItem(with: nil)
                playerItems.removeValue(forKey: oldestKey)
                print("🗑️ Removed old player: \(oldestKey)")
            }
        }
        
        // Create player item with proper configuration for HLS
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetHTTPHeaderFieldsKey: [
                "User-Agent": "ICCCAlert/1.0",
                "Accept": "*/*"
            ],
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        
        let playerItem = AVPlayerItem(asset: asset)
        
        // Configure player item for better HLS streaming
        playerItem.preferredForwardBufferDuration = 5.0
        if #available(iOS 14.0, *) {
            playerItem.startsOnFirstEligibleVariant = true
        }
        
        let player = AVPlayer(playerItem: playerItem)
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = false
        
        // Store both player and item
        players[cameraId] = player
        playerItems[cameraId] = playerItem
        
        print("🆕 Created new player for: \(cameraId)")
        print("   URL: \(url.absoluteString)")
        
        return player
    }
    
    func releasePlayer(_ cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        if let player = players[cameraId] {
            player.pause()
            player.replaceCurrentItem(with: nil)
            players.removeValue(forKey: cameraId)
            playerItems.removeValue(forKey: cameraId)
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
        playerItems.removeAll()
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
        
        // Validate URL scheme
        if url.scheme != "https" && url.scheme != "http" {
            DispatchQueue.main.async {
                self.errorMessage = "Invalid URL scheme. Only HTTP/HTTPS supported."
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
        private var accessLogObserver: Any?
        private var errorLogObserver: Any?
        
        init(_ parent: NativeVideoPlayer) {
            self.parent = parent
        }
        
        func setupObservers(for player: AVPlayer) {
            cleanup()
            
            guard let playerItem = player.currentItem else { return }
            
            // Observe status
            statusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard let self = self else { return }
                
                DispatchQueue.main.async {
                    switch item.status {
                    case .readyToPlay:
                        print("✅ Player ready: \(self.parent.cameraId)")
                        self.parent.isLoading = false
                        self.parent.errorMessage = nil
                        
                    case .failed:
                        print("❌ Player failed: \(self.parent.cameraId)")
                        if let error = item.error {
                            self.handlePlaybackError(error)
                        } else {
                            self.parent.errorMessage = "Unknown playback error"
                        }
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
                        if let reason = player.reasonForWaitingToPlay {
                            print("   Reason: \(reason.rawValue)")
                        }
                        self.parent.isLoading = true
                        
                    @unknown default:
                        break
                    }
                }
            }
            
            // Observe errors
            errorObserver = playerItem.observe(\.error, options: [.new]) { [weak self] item, _ in
                guard let self = self, let error = item.error else { return }
                
                DispatchQueue.main.async {
                    self.handlePlaybackError(error)
                    self.parent.isLoading = false
                }
            }
            
            // Observe access log for detailed debugging
            accessLogObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemNewAccessLogEntry,
                object: playerItem,
                queue: .main
            ) { [weak self] _ in
                if let accessLog = playerItem.accessLog(),
                   let lastEvent = accessLog.events.last {
                    print("📊 Access Log for \(self?.parent.cameraId ?? "unknown"):")
                    print("   URI: \(lastEvent.uri ?? "N/A")")
                    print("   Server Address: \(lastEvent.serverAddress ?? "N/A")")
                    print("   Playback Type: \(lastEvent.playbackType ?? "N/A")")
                    if let errorLog = playerItem.errorLog() {
                        print("⚠️ Error log has \(errorLog.events.count) events")
                    }
                }
            }
            
            // Observe error log
            errorLogObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemNewErrorLogEntry,
                object: playerItem,
                queue: .main
            ) { [weak self] _ in
                guard let self = self else { return }
                if let errorLog = playerItem.errorLog(),
                   let lastEvent = errorLog.events.last {
                    print("❌ Error Log for \(self.parent.cameraId):")
                    print("   Error: \(lastEvent.errorComment ?? "N/A")")
                    print("   Status Code: \(lastEvent.errorStatusCode)")
                    print("   Domain: \(lastEvent.errorDomain ?? "N/A")")
                    
                    DispatchQueue.main.async {
                        if lastEvent.errorStatusCode == -12938 {
                            self.parent.errorMessage = "Connection failed. Check stream URL and network."
                        } else {
                            self.parent.errorMessage = lastEvent.errorComment ?? "Stream error (\(lastEvent.errorStatusCode))"
                        }
                    }
                }
            }
        }
        
        private func handlePlaybackError(_ error: Error) {
            let nsError = error as NSError
            print("❌ Playback error details:")
            print("   Domain: \(nsError.domain)")
            print("   Code: \(nsError.code)")
            print("   Description: \(nsError.localizedDescription)")
            
            // Provide user-friendly error messages
            let userMessage: String
            switch nsError.code {
            case -1100: // kCFURLErrorFileDoesNotExist
                userMessage = "Stream not found. Camera may be offline."
            case -1001: // kCFURLErrorTimedOut
                userMessage = "Connection timed out. Check your network."
            case -1009: // kCFURLErrorNotConnectedToInternet
                userMessage = "No internet connection."
            case -1200: // kCFURLErrorSecureConnectionFailed
                userMessage = "Secure connection failed. Stream may use HTTP."
            case -12938: // CoreMedia error
                userMessage = "Cannot load stream. Format may not be supported."
            case -11800: // AVFoundation error
                userMessage = "Playback failed. Stream format issue."
            default:
                userMessage = "Stream error: \(nsError.localizedDescription)"
            }
            
            parent.errorMessage = userMessage
        }
        
        func cleanup() {
            statusObserver?.invalidate()
            timeControlObserver?.invalidate()
            errorObserver?.invalidate()
            
            if let observer = accessLogObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = errorLogObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            
            statusObserver = nil
            timeControlObserver = nil
            errorObserver = nil
            accessLogObserver = nil
            errorLogObserver = nil
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
                            print("   Stream URL: \(streamURL)")
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
                Text("Loading stream...")
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
                
                Text(error)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(3)
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
                .onAppear {
                    print("🎬 Fullscreen player appeared")
                    print("   Camera: \(camera.displayName)")
                    print("   Stream URL: \(streamURL)")
                }
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
            
            Text("Connecting to stream...")
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
            
            if let streamURL = camera.streamURL {
                Text("URL: \(streamURL)")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.horizontal)
                    .lineLimit(2)
            }
            
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