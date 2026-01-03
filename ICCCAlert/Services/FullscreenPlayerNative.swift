import SwiftUI

struct FullscreenPlayerNative: View {
    let camera: Camera
    @Environment(\.presentationMode) var presentationMode
    
    @StateObject private var player: NativeWebRTCPlayer
    @StateObject private var memoryMonitor = MemoryMonitor.shared
    
    @State private var showControls = true
    @State private var showMemoryWarning = false
    
    init(camera: Camera) {
        self.camera = camera
        
        // Initialize player
        _player = StateObject(wrappedValue: NativeWebRTCPlayer(
            cameraId: camera.id,
            streamURL: camera.webrtcStreamURL ?? ""
        ))
    }
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)  // ← Use this instead
            
            // Video view - FIXED: Remove .ignoresSafeArea() from custom view
            NativeWebRTCPlayerView(
                cameraId: camera.id,
                streamURL: camera.webrtcStreamURL ?? ""
            )
            .edgesIgnoringSafeArea(.all)  // ← Use edgesIgnoringSafeArea on UIViewRepresentable
            .onTapGesture {
                withAnimation { showControls.toggle() }
            }
            
            // Loading overlay
            if player.isLoading {
                loadingView
            }
            
            // Error overlay
            if let error = player.errorMessage {
                errorView(message: error)
            }
            
            // Controls overlay
            if showControls {
                controlsOverlay
            }
            
            // Memory warning
            if memoryMonitor.isMemoryWarning || showMemoryWarning {
                memoryWarningOverlay
            }
        }
        .navigationBarHidden(true)
        .statusBar(hidden: !showControls)
        .onAppear {
            DebugLogger.shared.log("📹 Native player appeared: \(camera.displayName)", emoji: "📹", color: .blue)
            setupMemoryMonitoring()
        }
        .onDisappear {
            handleDisappear()
        }
    }
    
    // MARK: - Views
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.5)
            
            Text("Connecting...")
                .font(.headline)
                .foregroundColor(.white)
            
            Text("Memory: \(Int(memoryMonitor.currentMemoryMB))MB")
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
        }
    }
    
    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 50))
                .foregroundColor(.red)
            
            Text("Connection Error")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text(message)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Button(action: {
                presentationMode.wrappedValue.dismiss()
            }) {
                Text("Close")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.red)
                    .cornerRadius(10)
            }
        }
    }
    
    private var controlsOverlay: some View {
        VStack {
            HStack {
                Button(action: {
                    player.stop()
                    
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
                
                // Connection status indicator
                HStack(spacing: 8) {
                    Circle()
                        .fill(player.isConnected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    
                    Text(player.isConnected ? "LIVE" : "Connecting...")
                        .font(.caption)
                        .foregroundColor(.white)
                }
                .padding(8)
                .background(Color.black.opacity(0.6))
                .cornerRadius(8)
            }
            .padding()
            
            Spacer()
            
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
                        
                        // Memory indicator
                        let memMB = Int(memoryMonitor.currentMemoryMB)
                        let memColor: Color = {
                            if memMB > 150 { return .red }
                            else if memMB > 120 { return .orange }
                            else if memMB > 100 { return .yellow }
                            else { return .white.opacity(0.6) }
                        }()
                        
                        Text("\(memMB)MB")
                            .font(.caption2)
                            .foregroundColor(memColor)
                            .fontWeight(memMB > 120 ? .bold : .regular)
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
                    
                    Text("\(Int(memoryMonitor.currentMemoryMB)) MB")
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
    
    // MARK: - Memory Monitoring
    
    private func setupMemoryMonitoring() {
        // Check memory every 10 seconds
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in
            checkMemory()
        }
    }
    
    private func checkMemory() {
        let memoryMB = memoryMonitor.currentMemoryMB
        
        // Show warning at 120MB (much lower than WKWebView)
        if memoryMB > 120 {
            showMemoryWarning = true
            
            // Auto-close at 140MB
            if memoryMB > 140 {
                DebugLogger.shared.log("🚨 Memory too high (\(Int(memoryMB))MB) - closing", emoji: "🚨", color: .red)
                presentationMode.wrappedValue.dismiss()
            }
        } else {
            showMemoryWarning = false
        }
    }
    
    private func handleDisappear() {
        DebugLogger.shared.log("🚪 Native player disappeared - cleanup", emoji: "🚪", color: .orange)
        
        player.stop()
        
        // Force cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            autoreleasepool {}
            URLCache.shared.removeAllCachedResponses()
            
            DebugLogger.shared.log("✅ Native player fully cleaned up", emoji: "✅", color: .green)
        }
    }
}