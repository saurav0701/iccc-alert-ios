import SwiftUI
import AVKit
import AVFoundation
import WebKit
import Combine

// MARK: - Player Manager
class PlayerManager: ObservableObject {
    static let shared = PlayerManager()
    
    private var activePlayers: [String: Any] = [:] // Can hold AVPlayer or WKWebView
    private let lock = NSLock()
    private let maxPlayers = 2
    
    private init() {}
    
    func registerPlayer(_ player: Any, for cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        if activePlayers.count >= maxPlayers {
            if let oldestKey = activePlayers.keys.first {
                releasePlayerInternal(oldestKey)
            }
        }
        
        activePlayers[cameraId] = player
        print("📹 Registered player for: \(cameraId)")
    }
    
    private func releasePlayerInternal(_ cameraId: String) {
        if let player = activePlayers.removeValue(forKey: cameraId) {
            if let avPlayer = player as? AVPlayer {
                avPlayer.pause()
                avPlayer.replaceCurrentItem(with: nil)
            } else if let webView = player as? WKWebView {
                webView.stopLoading()
                webView.loadHTMLString("", baseURL: nil)
            }
            print("🗑️ Released player: \(cameraId)")
        }
    }
    
    func releasePlayer(_ cameraId: String) {
        lock.lock()
        defer { lock.unlock() }
        releasePlayerInternal(cameraId)
    }
    
    func releaseWebView(_ cameraId: String) {
        releasePlayer(cameraId)
    }
    
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        
        activePlayers.keys.forEach { releasePlayerInternal($0) }
        print("🧹 Cleared all players")
    }
}

// MARK: - Hybrid Player (Native with WebView Fallback)
struct HybridHLSPlayer: View {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    
    @State private var playerMode: PlayerMode = .native
    @State private var hasNativeFailed = false
    
    enum PlayerMode {
        case native
        case webview
    }
    
    var body: some View {
        ZStack {
            if playerMode == .native && !hasNativeFailed {
                NativeAVPlayerView(
                    streamURL: streamURL,
                    cameraId: cameraId,
                    isFullscreen: isFullscreen,
                    onFatalError: {
                        // Native player failed, switch to WebView
                        print("⚠️ Native player failed for \(cameraId), switching to WebView")
                        hasNativeFailed = true
                        playerMode = .webview
                    }
                )
            } else {
                SimpleWebViewPlayer(
                    streamURL: streamURL,
                    cameraId: cameraId,
                    isFullscreen: isFullscreen
                )
            }
        }
    }
}

// MARK: - Native AVPlayer View
struct NativeAVPlayerView: View {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    let onFatalError: () -> Void
    
    @State private var player: AVPlayer?
    @State private var isLoading = true
    @State private var hasError = false
    @State private var errorMessage = ""
    @State private var observer: PlayerObserver?
    @State private var cancellables = Set<AnyCancellable>()
    @State private var retryCount = 0
    
    var body: some View {
        ZStack {
            if let player = player {
                VideoPlayer(player: player)
            } else {
                Color.black
            }
            
            // Loading overlay
            if isLoading && !hasError {
                VStack(spacing: 8) {
                    ProgressView()
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
                    Text(errorMessage)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(Color.black.opacity(0.8))
                .cornerRadius(10)
            }
            
            // LIVE indicator
            if !isLoading && !hasError && !isFullscreen {
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
            triggerFatalError("Invalid URL")
            return
        }
        
        print("📹 Setting up native AVPlayer for: \(cameraId)")
        
        let playerItem = AVPlayerItem(url: url)
        playerItem.preferredForwardBufferDuration = 3.0
        
        let avPlayer = AVPlayer(playerItem: playerItem)
        avPlayer.allowsExternalPlayback = false
        avPlayer.automaticallyWaitsToMinimizeStalling = true
        
        self.player = avPlayer
        PlayerManager.shared.registerPlayer(avPlayer, for: cameraId)
        
        // Setup observer
        let newObserver = PlayerObserver()
        newObserver.onStatusChange = { status in
            switch status {
            case .readyToPlay:
                isLoading = false
                hasError = false
                retryCount = 0
                print("✅ Native player ready: \(cameraId)")
                avPlayer.play()
                
            case .failed:
                handleFailure(playerItem.error)
                
            case .unknown:
                isLoading = true
                
            @unknown default:
                break
            }
        }
        
        newObserver.onError = { error in
            handleFailure(error)
        }
        
        newObserver.observe(playerItem: playerItem)
        self.observer = newObserver
        
        // Monitor notifications
        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: playerItem)
            .sink { notification in
                if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                    handleFailure(error)
                }
            }
            .store(in: &cancellables)
        
        NotificationCenter.default.publisher(for: .AVPlayerItemNewAccessLogEntry, object: playerItem)
            .sink { _ in
                isLoading = false
                hasError = false
            }
            .store(in: &cancellables)
        
        // Auto-play
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            avPlayer.play()
        }
        
        // Timeout fallback (switch to WebView if native fails after 10 seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
            if isLoading {
                print("⏱️ Native player timeout, switching to WebView")
                triggerFatalError("Native player timeout")
            }
        }
    }
    
    private func handleFailure(_ error: Error?) {
        isLoading = false
        hasError = true
        
        let nsError = error as NSError?
        let errorCode = nsError?.code ?? 0
        
        print("❌ Native player error: \(errorCode) - \(error?.localizedDescription ?? "unknown")")
        
        // Error -12642: kCMFormatDescriptionError (incompatible format)
        // Error -11800: AVFoundation generic error
        // These indicate the stream format is incompatible with AVPlayer
        if errorCode == -12642 || errorCode == -11800 || errorCode == -12645 {
            errorMessage = "Format incompatible"
            
            // Immediate fallback to WebView for format errors
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                triggerFatalError("Incompatible stream format")
            }
        } else {
            errorMessage = error?.localizedDescription ?? "Playback failed"
            
            // Retry once for network errors
            if retryCount < 1 {
                retryCount += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    cleanup()
                    setupPlayer()
                }
            } else {
                // After retry, fall back to WebView
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    triggerFatalError("Playback failed after retry")
                }
            }
        }
    }
    
    private func triggerFatalError(_ reason: String) {
        print("🔄 Triggering fallback to WebView: \(reason)")
        cleanup()
        onFatalError()
    }
    
    private func cleanup() {
        player?.pause()
        observer?.stopObserving()
        observer = nil
        PlayerManager.shared.releasePlayer(cameraId)
        player = nil
        cancellables.removeAll()
    }
}

// MARK: - Simple WebView Player (Fallback)
struct SimpleWebViewPlayer: UIViewRepresentable {
    let streamURL: String
    let cameraId: String
    let isFullscreen: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.backgroundColor = .black
        webView.isOpaque = false
        webView.navigationDelegate = context.coordinator
        
        PlayerManager.shared.registerPlayer(webView, for: cameraId)
        
        loadPlayer(in: webView)
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.loadHTMLString("", baseURL: nil)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    private func loadPlayer(in webView: WKWebView) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <style>
                * { margin: 0; padding: 0; box-sizing: border-box; }
                html, body { width: 100%; height: 100%; overflow: hidden; background: #000; }
                #container { width: 100vw; height: 100vh; position: relative; }
                video { width: 100%; height: 100%; object-fit: contain; background: #000; }
                #status {
                    position: absolute; bottom: 10px; left: 10px;
                    background: rgba(0,0,0,0.7); color: #4CAF50;
                    padding: 6px 10px; font-size: 11px; border-radius: 4px;
                    font-family: monospace; z-index: 10;
                }
            </style>
        </head>
        <body>
            <div id="container">
                <video id="video" playsinline webkit-playsinline muted autoplay controls></video>
                <div id="status">WebView Fallback</div>
            </div>
            
            <script>
                (function() {
                    'use strict';
                    
                    const video = document.getElementById('video');
                    const status = document.getElementById('status');
                    const streamUrl = '\(streamURL)';
                    
                    function log(msg) {
                        console.log('[WebView Player]', msg);
                        status.textContent = msg;
                    }
                    
                    // Use native iOS HLS player (supports H.265)
                    log('Loading stream...');
                    video.src = streamUrl;
                    
                    video.addEventListener('loadeddata', function() {
                        log('✅ Playing (WebView)');
                        video.play().catch(e => {
                            log('Play error: ' + e.message);
                        });
                    });
                    
                    video.addEventListener('error', function(e) {
                        log('❌ Error: ' + (video.error ? video.error.code : 'unknown'));
                    });
                    
                    video.addEventListener('playing', function() {
                        log('✅ Playing');
                    });
                    
                    video.addEventListener('waiting', function() {
                        log('⏳ Buffering...');
                    });
                    
                    video.load();
                    
                })();
            </script>
        </body>
        </html>
        """
        
        webView.loadHTMLString(html, baseURL: nil)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: SimpleWebViewPlayer
        
        init(_ parent: SimpleWebViewPlayer) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("✅ WebView loaded for: \(parent.cameraId)")
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("❌ WebView failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Player Observer
class PlayerObserver: NSObject {
    var onStatusChange: ((AVPlayerItem.Status) -> Void)?
    var onError: ((Error?) -> Void)?
    
    private var statusObservation: NSKeyValueObservation?
    
    func observe(playerItem: AVPlayerItem) {
        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                self?.onStatusChange?(item.status)
                
                if item.status == .failed, let error = item.error {
                    self?.onError?(error)
                }
            }
        }
    }
    
    func stopObserving() {
        statusObservation?.invalidate()
        statusObservation = nil
    }
    
    deinit {
        stopObserving()
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
                    HybridHLSPlayer(
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
        .onAppear {
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

// MARK: - Fullscreen Player
struct HLSPlayerView: View {
    let camera: Camera
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let streamURL = camera.streamURL {
                HybridHLSPlayer(
                    streamURL: streamURL,
                    cameraId: camera.id,
                    isFullscreen: true
                )
                .ignoresSafeArea()
            }
            
            // Top bar
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
        }
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .onDisappear {
            PlayerManager.shared.releasePlayer(camera.id)
        }
    }
}