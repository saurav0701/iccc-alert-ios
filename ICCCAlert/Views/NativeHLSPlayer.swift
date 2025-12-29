import SwiftUI
import AVKit
import AVFoundation
import Combine

// MARK: - Crash-Proof Player Manager
class PlayerManager: ObservableObject {
    static let shared = PlayerManager()
    
    private var players: [String: PlayerContainer] = [:]
    private let queue = DispatchQueue(label: "com.app.playermanager", attributes: .concurrent)
    
    private init() {}
    
    func getOrCreatePlayer(for cameraId: String, url: String) -> PlayerContainer? {
        var container: PlayerContainer?
        
        queue.sync {
            if let existing = players[cameraId] {
                container = existing
            } else {
                container = PlayerContainer(cameraId: cameraId, url: url)
                queue.async(flags: .barrier) { [weak self] in
                    self?.players[cameraId] = container
                }
            }
        }
        
        return container
    }
    
    func removePlayer(for cameraId: String) {
        queue.async(flags: .barrier) { [weak self] in
            if let container = self?.players.removeValue(forKey: cameraId) {
                DispatchQueue.main.async {
                    container.destroy()
                }
            }
        }
    }
    
    func removeAll() {
        queue.async(flags: .barrier) { [weak self] in
            let containers = self?.players.values ?? []
            self?.players.removeAll()
            
            DispatchQueue.main.async {
                containers.forEach { $0.destroy() }
            }
        }
    }
    
    func pauseAll() {
        queue.sync {
            players.values.forEach { $0.pause() }
        }
    }
}

// MARK: - Player Container (Safe wrapper)
class PlayerContainer {
    let cameraId: String
    let url: String
    private(set) var player: AVPlayer?
    private var statusObserver: NSKeyValueObservation?
    private var timeObserver: Any?
    private var isDestroyed = false
    
    init(cameraId: String, url: String) {
        self.cameraId = cameraId
        self.url = url
    }
    
    func setupIfNeeded() -> AVPlayer? {
        guard !isDestroyed, player == nil else { return player }
        
        guard let videoURL = URL(string: url) else {
            print("❌ Invalid URL: \(url)")
            return nil
        }
        
        let asset = AVURLAsset(url: videoURL)
        let playerItem = AVPlayerItem(asset: asset)
        
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.allowsExternalPlayback = false
        newPlayer.automaticallyWaitsToMinimizeStalling = false
        
        self.player = newPlayer
        return newPlayer
    }
    
    func pause() {
        guard !isDestroyed else { return }
        player?.pause()
    }
    
    func play() {
        guard !isDestroyed else { return }
        player?.play()
    }
    
    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        
        // Remove observers first
        statusObserver?.invalidate()
        statusObserver = nil
        
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        
        // Stop playback
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        
        print("🗑️ Destroyed player: \(cameraId)")
    }
    
    deinit {
        destroy()
    }
}

// MARK: - Safe Video Player View
struct SafeVideoPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspect
        controller.view.backgroundColor = .black
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        // Only update if different
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
    
    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: ()) {
        uiViewController.player = nil
    }
}

// MARK: - Simplified Player State
enum StreamState: Equatable {
    case idle
    case loading
    case playing
    case buffering
    case error(String)
    case failed(String)
}

// MARK: - H.264 Player View (Crash-Proof)
struct H264PlayerView: View {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    
    @StateObject private var viewModel: StreamViewModel
    
    init(streamURL: String, cameraId: String, isFullscreen: Bool) {
        self.streamURL = streamURL
        self.cameraId = cameraId
        self.isFullscreen = isFullscreen
        self._viewModel = StateObject(wrappedValue: StreamViewModel(
            streamURL: streamURL,
            cameraId: cameraId
        ))
    }
    
    var body: some View {
        ZStack {
            Color.black
            
            if let player = viewModel.player {
                SafeVideoPlayerView(player: player)
            }
            
            overlayView
        }
        .onAppear {
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
    }
    
    @ViewBuilder
    private var overlayView: some View {
        switch viewModel.state {
        case .idle:
            EmptyView()
            
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.5)
                Text("Connecting...")
                    .foregroundColor(.white)
                    .font(.caption)
            }
            .padding(24)
            .background(Color.black.opacity(0.7))
            .cornerRadius(12)
            
        case .playing:
            if !isFullscreen {
                VStack {
                    HStack {
                        Spacer()
                        liveIndicator
                    }
                    Spacer()
                }
            }
            
        case .buffering:
            VStack(spacing: 8) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                Text("Buffering...")
                    .foregroundColor(.white)
                    .font(.caption)
            }
            .padding(16)
            .background(Color.black.opacity(0.6))
            .cornerRadius(8)
            
        case .error(let message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.orange)
                
                Text("Connection Issue")
                    .font(.headline)
                    .foregroundColor(.white)
                
                Text(message)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                Button(action: { viewModel.retry() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                        Text("Retry")
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .cornerRadius(8)
                }
            }
            .padding(24)
            .background(Color.black.opacity(0.8))
            .cornerRadius(12)
            
        case .failed(let message):
            VStack(spacing: 16) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.red)
                
                Text("Stream Unavailable")
                    .font(.headline)
                    .foregroundColor(.white)
                
                Text(message)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                Button(action: { viewModel.retry() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                        Text("Try Again")
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
    }
    
    private var liveIndicator: some View {
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
        .padding(8)
    }
}

// MARK: - Stream ViewModel (Simplified & Safe)
class StreamViewModel: ObservableObject {
    @Published var state: StreamState = .idle
    @Published var player: AVPlayer?
    
    private let streamURL: String
    private let cameraId: String
    private var container: PlayerContainer?
    private var cancellables = Set<AnyCancellable>()
    private var retryCount = 0
    private let maxRetries = 3
    private var workItem: DispatchWorkItem?
    
    // Observers
    private var statusObserver: NSKeyValueObservation?
    private var timeObserver: Any?
    private var notificationObservers: [NSObjectProtocol] = []
    
    init(streamURL: String, cameraId: String) {
        self.streamURL = streamURL
        self.cameraId = cameraId
    }
    
    func start() {
        guard state == .idle || state == .failed("") else { return }
        
        state = .loading
        setupPlayer()
    }
    
    func stop() {
        cleanup()
    }
    
    func retry() {
        retryCount = 0
        cleanup()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.start()
        }
    }
    
    private func setupPlayer() {
        // Get or create container
        container = PlayerManager.shared.getOrCreatePlayer(for: cameraId, url: streamURL)
        
        guard let container = container,
              let player = container.setupIfNeeded() else {
            state = .failed("Invalid stream configuration")
            return
        }
        
        self.player = player
        
        // Setup observers safely
        setupObservers(for: player)
        
        // Start playback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            player.play()
            self?.scheduleTimeout()
        }
    }
    
    private func setupObservers(for player: AVPlayer) {
        guard let item = player.currentItem else { return }
        
        // Status observer
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                self?.handleStatusChange(item.status, item: item)
            }
        }
        
        // Time observer (check if actually playing)
        let interval = CMTime(seconds: 1.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            
            if player.rate > 0 && self.state != .playing {
                self.state = .playing
                self.retryCount = 0
                self.cancelTimeout()
            }
        }
        
        // Notifications
        let stalled = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.handleStall()
        }
        
        let failed = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            self?.handleError(error?.localizedDescription ?? "Playback failed")
        }
        
        notificationObservers = [stalled, failed]
    }
    
    private func handleStatusChange(_ status: AVPlayerItem.Status, item: AVPlayerItem) {
        switch status {
        case .readyToPlay:
            print("✅ Player ready: \(cameraId)")
            // State will be set to playing by time observer
            
        case .failed:
            let error = item.error?.localizedDescription ?? "Unknown error"
            print("❌ Player failed: \(error)")
            handleError(error)
            
        case .unknown:
            break
            
        @unknown default:
            break
        }
    }
    
    private func handleStall() {
        print("⚠️ Playback stalled: \(cameraId)")
        
        if state == .playing {
            state = .buffering
            
            // Try to recover
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self = self, self.state == .buffering else { return }
                
                self.player?.pause()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.player?.play()
                }
            }
        }
    }
    
    private func handleError(_ message: String) {
        cancelTimeout()
        
        if retryCount < maxRetries {
            retryCount += 1
            state = .error(message)
            
            print("⚠️ Retry \(retryCount)/\(maxRetries): \(message)")
            
            // Auto-retry
            let delay = Double(retryCount) * 2.0
            workItem = DispatchWorkItem { [weak self] in
                self?.attemptRetry()
            }
            
            if let workItem = workItem {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            }
        } else {
            state = .failed("Connection failed after \(maxRetries) attempts")
        }
    }
    
    private func attemptRetry() {
        cleanup(keepState: false)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.setupPlayer()
        }
    }
    
    private func scheduleTimeout() {
        cancelTimeout()
        
        workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.state == .loading else { return }
            self.handleError("Connection timeout")
        }
        
        if let workItem = workItem {
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: workItem)
        }
    }
    
    private func cancelTimeout() {
        workItem?.cancel()
        workItem = nil
    }
    
    private func cleanup(keepState: Bool = true) {
        cancelTimeout()
        
        // Remove time observer
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        
        // Remove status observer
        statusObserver?.invalidate()
        statusObserver = nil
        
        // Remove notification observers
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
        
        // Stop player
        player?.pause()
        
        if !keepState {
            state = .idle
        }
        
        cancellables.removeAll()
    }
    
    deinit {
        cleanup()
        PlayerManager.shared.removePlayer(for: cameraId)
    }
}

// MARK: - Camera Thumbnail
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
        .onDisappear {
            shouldLoad = false
            PlayerManager.shared.removePlayer(for: camera.id)
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
                Text("Tap to load")
                    .font(.caption)
                    .foregroundColor(.blue)
            }
        }
        .contentShape(Rectangle())
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
                    .font(.system(size: 28))
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
                    .padding(12)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(10)
                    
                    Spacer()
                    
                    Button(action: {
                        PlayerManager.shared.removePlayer(for: camera.id)
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.black.opacity(0.3))
                            .clipShape(Circle())
                    }
                }
                .padding()
                
                Spacer()
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .onDisappear {
            PlayerManager.shared.removePlayer(for: camera.id)
        }
    }
}