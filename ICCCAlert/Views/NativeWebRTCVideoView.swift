import SwiftUI
import WebRTC

// MARK: - Native WebRTC Video View (SwiftUI Wrapper)
struct NativeWebRTCVideoView: UIViewRepresentable {
    let videoTrack: RTCVideoTrack?
    
    func makeUIView(context: Context) -> RTCMTLVideoView {
        let videoView = RTCMTLVideoView(frame: .zero)
        videoView.contentMode = .scaleAspectFit
        videoView.backgroundColor = .black
        videoView.videoContentMode = .scaleAspectFit
        
        DebugLogger.shared.log("📺 Video view created", emoji: "📺", color: .blue)
        
        return videoView
    }
    
    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        // Remove previous track
        context.coordinator.currentTrack?.remove(uiView)
        
        // Add new track
        if let track = videoTrack {
            track.add(uiView)
            context.coordinator.currentTrack = track
            DebugLogger.shared.log("✅ Video track attached", emoji: "✅", color: .green)
        }
    }
    
    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.currentTrack?.remove(uiView)
        coordinator.currentTrack = nil
        DebugLogger.shared.log("🗑️ Video view dismantled", emoji: "🗑️", color: .gray)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var currentTrack: RTCVideoTrack?
    }
}

// MARK: - Loading/Error States View
struct VideoStateView: View {
    let state: VideoState
    
    enum VideoState {
        case connecting
        case error(String)
        case disconnected
    }
    
    var body: some View {
        ZStack {
            Color.black
            
            VStack(spacing: 16) {
                switch state {
                case .connecting:
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                    Text("Connecting...")
                        .foregroundColor(.white)
                        .font(.headline)
                    
                case .error(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.red)
                    Text("Connection Error")
                        .foregroundColor(.white)
                        .font(.headline)
                    Text(message)
                        .foregroundColor(.white.opacity(0.7))
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    
                case .disconnected:
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 50))
                        .foregroundColor(.gray)
                    Text("Disconnected")
                        .foregroundColor(.white)
                        .font(.headline)
                }
            }
        }
    }
}