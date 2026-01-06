import SwiftUI
import WebKit 

struct FullscreenPlayerEnhanced: View {
    let camera: Camera
    @Environment(\.presentationMode) var presentationMode
    
    @StateObject private var session: StreamSession
    
    @State private var showControls = true
    @State private var isRestarting = false
    
    init(camera: Camera) {
        self.camera = camera
        _session = StateObject(wrappedValue: StreamSession(
            cameraId: camera.id,
            streamURL: camera.webrtcStreamURL ?? ""
        ))
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if isRestarting {
                restartingView
            } else {
                WebRTCPlayerEnhanced(session: session)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation { showControls.toggle() }
                    }
            }
            
            if showControls {
                controlsOverlay
            }
        }
        .navigationBarHidden(true)
        .statusBar(hidden: !showControls)
        .onChange(of: session.needsRestart) { needs in
            if needs {
                performRestart()
            }
        }
        .onAppear {
            DebugLogger.shared.log("📹 Player appeared: \(camera.displayName)", emoji: "📹", color: .blue)
        }
        .onDisappear {
            handleDisappear()
        }
    }
    
    private var controlsOverlay: some View {
        VStack {
            HStack {
                Button(action: {
                    session.stop()
                    
                    // Delay dismiss for cleanup
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
                
                // Countdown timer (shows 2 min)
                if session.secondsRemaining > 0 {
                    VStack(spacing: 2) {
                        Text(formatTime(session.secondsRemaining))
                            .font(.caption)
                            .foregroundColor(.white)
                        
                        Text("auto-refresh")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.8))
                    .cornerRadius(8)
                }
                
                // Manual restart button
                Button(action: { performRestart() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                        .padding(12)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(10)
                }
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
    
    private var restartingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.5)
            
            Text("Refreshing stream...")
                .font(.headline)
                .foregroundColor(.white)
        }
    }
    
    private func performRestart() {
        guard !isRestarting else { return }
        
        DebugLogger.shared.log("🔄 Performing restart", emoji: "🔄", color: .orange)
        
        isRestarting = true
        
        // Stop current session
        session.stop()
        
        // Wait 3 seconds for complete cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            // Force cleanup
            autoreleasepool {
                URLCache.shared.removeAllCachedResponses()
            }
            
            // Start new session
            _ = self.session.start()
            self.isRestarting = false
            
            DebugLogger.shared.log("✅ Restart complete", emoji: "✅", color: .green)
        }
    }
    
    private func handleDisappear() {
        DebugLogger.shared.log("🚪 Player disappeared - cleanup", emoji: "🚪", color: .orange)
        
        session.stop()
        
        // Cleanup on dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            autoreleasepool {
                URLCache.shared.removeAllCachedResponses()
            }
            
            DebugLogger.shared.log("✅ Player fully cleaned up", emoji: "✅", color: .green)
        }
    }
    
    private func formatTime(_ seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Enhanced WebRTC Player View
struct WebRTCPlayerEnhanced: UIViewRepresentable {
    let session: StreamSession
    
    func makeUIView(context: Context) -> WKWebView {
        return session.start()
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        DebugLogger.shared.log("🗑️ Dismantling WebRTC player", emoji: "🗑️", color: .gray)
        // Cleanup is handled by StreamSession
    }
    
    func makeCoordinator() -> Coordinator {
        return Coordinator()
    }
    
    class Coordinator: NSObject {}
}