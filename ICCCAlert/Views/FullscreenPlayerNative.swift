import SwiftUI
import WebRTC

struct FullscreenPlayerNative: View {
    let camera: Camera
    @Environment(\.presentationMode) var presentationMode
    
    @StateObject private var webRTCService: NativeWebRTCService
    @StateObject private var memoryMonitor = MemoryMonitor.shared
    
    @State private var showControls = true
    @State private var showMemoryWarning = false
    
    init(camera: Camera) {
        self.camera = camera

        let streamURL = camera.webrtcStreamURL ?? ""
        _webRTCService = StateObject(wrappedValue: NativeWebRTCService(
            streamURL: streamURL,
            cameraId: camera.id
        ))
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // Video content
            if let videoTrack = webRTCService.remoteVideoTrack {
                NativeWebRTCVideoView(videoTrack: videoTrack)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation { showControls.toggle() }
                    }
            } else {
                // Show loading/error state
                VideoStateView(state: connectionStateView)
                    .ignoresSafeArea()
            }
            
            // Controls overlay
            if showControls {
                controlsOverlay
            }
            
            // Memory warning
            if showMemoryWarning {
                memoryWarningOverlay
            }
        }
        .navigationBarHidden(true)
        .statusBar(hidden: !showControls)
        .onAppear {
            DebugLogger.shared.log("📹 Player appeared: \(camera.displayName)", emoji: "📹", color: .blue)
            webRTCService.connect()
        }
        .onDisappear {
            handleDisappear()
        }
        .onChange(of: memoryMonitor.currentMemoryMB) { memoryMB in
            handleMemoryChange(memoryMB)
        }
    }
    
    private var connectionStateView: VideoStateView.VideoState {
        if webRTCService.isConnected {
            return .connecting // Shouldn't show, but fallback
        }
        
        switch webRTCService.connectionState {
        case .new, .checking:
            return .connecting
        case .failed:
            return .error("Failed to connect to stream")
        case .disconnected:
            return .disconnected
        case .closed:
            return .error("Connection closed")
        default:
            return .connecting
        }
    }
    
    private var controlsOverlay: some View {
        VStack {
            // Top controls
            HStack {
                Button(action: {
                    webRTCService.disconnect()
                    
                    // Small delay for cleanup
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.presentationMode.wrappedValue.dismiss()
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                        Text("Back").font(.headline)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(10)
                }
                
                Spacer()
                
                // Connection status
                HStack(spacing: 8) {
                    Circle()
                        .fill(webRTCService.isConnected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    
                    Text(webRTCService.isConnected ? "LIVE" : "Connecting...")
                        .font(.caption)
                        .foregroundColor(.white)
                }
                .padding(8)
                .background(Color.black.opacity(0.6))
                .cornerRadius(8)
                
                Spacer().frame(width: 12)
                
                // Memory indicator
                let memMB = Int(webRTCService.memoryUsageMB)
                let memColor: Color = {
                    if memMB > 180 { return .red }
                    else if memMB > 150 { return .orange }
                    else if memMB > 120 { return .yellow }
                    else { return .white.opacity(0.6) }
                }()
                
                Text("\(memMB)MB")
                    .font(.caption2)
                    .foregroundColor(memColor)
                    .fontWeight(memMB > 150 ? .bold : .regular)
                    .padding(8)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(8)
            }
            .padding()
            
            Spacer()
            
            // Bottom info
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
                        
                        // Connection state
                        Text("• \(connectionStateText)")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.6))
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
    
    private var connectionStateText: String {
        switch webRTCService.connectionState {
        case .new: return "New"
        case .checking: return "Checking"
        case .connected: return "Connected"
        case .completed: return "Connected"
        case .failed: return "Failed"
        case .disconnected: return "Disconnected"
        case .closed: return "Closed"
        default: return "Unknown"
        }
    }
    
    private var memoryWarningOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.orange)
                    
                    Text("High Memory")
                        .font(.caption)
                        .foregroundColor(.white)
                        .fontWeight(.semibold)
                    
                    Text("\(Int(webRTCService.memoryUsageMB)) MB")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding()
                .background(Color.orange.opacity(0.9))
                .cornerRadius(12)
                .padding()
                Spacer()
            }
            Spacer()
        }
    }
    
    private func handleMemoryChange(_ memoryMB: Double) {
        // Show warning at 150MB
        if memoryMB > 150 {
            showMemoryWarning = true
            DebugLogger.shared.log("⚠️ Memory: \(Int(memoryMB))MB", emoji: "⚠️", color: .orange)
        } else {
            showMemoryWarning = false
        }
        
        // Native WebRTC service handles auto-disconnect at 180MB
    }
    
    private func handleDisappear() {
        DebugLogger.shared.log("🚪 Player disappeared - cleanup", emoji: "🚪", color: .orange)
        
        webRTCService.disconnect()
        
        // Cleanup after short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            autoreleasepool {}
            URLCache.shared.removeAllCachedResponses()
            
            DebugLogger.shared.log("✅ Player fully cleaned up", emoji: "✅", color: .green)
        }
    }
}

// MARK: - Preview
#if DEBUG
struct FullscreenPlayerNative_Previews: PreviewProvider {
    static var previews: some View {
        let testCamera = Camera(
            category: "camera",
            id: "test-123",
            ip: "192.168.1.100",
            Id: 1,
            deviceId: 1,
            Name: "Test Camera",
            name: "Test Camera",
            latitude: "0.0",
            longitude: "0.0",
            status: "online",
            groupId: 5,
            area: "Test Area",
            transporter: "Test",
            location: "Test Location",
            lastUpdate: "2025-01-02"
        )
        
        FullscreenPlayerNative(camera: testCamera)
    }
}
#endif