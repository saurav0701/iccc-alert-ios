import SwiftUI
import AVKit
import AVFoundation

// MARK: - HLS Player View

struct HLSPlayerView: View {
    let camera: Camera
    @StateObject private var playerManager = HLSPlayerManager()
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if playerManager.isLoading {
                loadingView
            } else if let error = playerManager.errorMessage {
                errorView(error)
            } else {
                VideoPlayer(player: playerManager.player)
                    .ignoresSafeArea()
            }
            
            // Status Overlay
            VStack {
                HStack {
                    // Camera Info
                    VStack(alignment: .leading, spacing: 4) {
                        Text(camera.displayName)
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        HStack(spacing: 8) {
                            Text(camera.area)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                            
                            Circle()
                                .fill(statusColor)
                                .frame(width: 8, height: 8)
                            
                            Text(playerManager.status)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                    .padding()
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(10)
                    
                    Spacer()
                    
                    // Close Button
                    Button(action: {
                        playerManager.stop()
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
                
                // Reconnect Button (if error)
                if playerManager.errorMessage != nil {
                    Button(action: {
                        playerManager.reconnect(camera: camera)
                    }) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Reconnect")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.blue)
                        .cornerRadius(10)
                    }
                    .padding(.bottom, 40)
                }
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            playerManager.play(camera: camera)
        }
        .onDisappear {
            playerManager.stop()
        }
    }
    
    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)
            
            Text("Connecting to stream...")
                .font(.headline)
                .foregroundColor(.white)
            
            Text(camera.displayName)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
        }
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
        }
    }
    
    private var statusColor: Color {
        switch playerManager.status.lowercased() {
        case "live": return .green
        case "loading", "connecting": return .yellow
        case "error", "offline": return .red
        default: return .gray
        }
    }
}

// MARK: - HLS Player Manager

class HLSPlayerManager: ObservableObject {
    @Published var player: AVPlayer?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var status = "Connecting"
    
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var currentCamera: Camera?
    
    func play(camera: Camera) {
        guard let streamURL = camera.streamURL else {
            errorMessage = "Stream URL not available for this camera"
            status = "Error"
            return
        }
        
        guard let url = URL(string: streamURL) else {
            errorMessage = "Invalid stream URL"
            status = "Error"
            return
        }
        
        currentCamera = camera
        isLoading = true
        errorMessage = nil
        status = "Connecting"
        
        print("📹 HLSPlayer: Starting stream for \(camera.displayName)")
        print("   URL: \(streamURL)")
        
        // Create player item
        playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        
        // Observe player status
        statusObserver = playerItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                self?.handlePlayerStatus(item.status)
            }
        }
        
        // Start playback
        player?.play()
        
        // Set timeout for connection
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            if self?.isLoading == true {
                self?.errorMessage = "Connection timeout - Stream may be unavailable"
                self?.status = "Timeout"
                self?.isLoading = false
            }
        }
    }
    
    func stop() {
        player?.pause()
        player = nil
        playerItem = nil
        statusObserver?.invalidate()
        statusObserver = nil
        
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        
        print("📹 HLSPlayer: Stream stopped")
    }
    
    func reconnect(camera: Camera) {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.play(camera: camera)
        }
    }
    
    private func handlePlayerStatus(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            isLoading = false
            errorMessage = nil
            self.status = "Live"
            print("✅ HLSPlayer: Stream ready")
            
        case .failed:
            isLoading = false
            let error = playerItem?.error?.localizedDescription ?? "Unknown error"
            errorMessage = "Failed to load stream: \(error)"
            self.status = "Error"
            print("❌ HLSPlayer: Stream failed - \(error)")
            
        case .unknown:
            break
            
        @unknown default:
            break
        }
    }
    
    deinit {
        stop()
    }
}