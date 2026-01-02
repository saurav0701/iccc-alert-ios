import SwiftUI

// MARK: - Enhanced Fullscreen Player with Auto-Restart
struct FullscreenPlayerEnhanced: View {
    let camera: Camera
    @Environment(\.presentationMode) var presentationMode
    
    @StateObject private var session: StreamSession
    @StateObject private var memoryMonitor = MemoryMonitor.shared
    
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
            
            if memoryMonitor.isMemoryWarning {
                memoryWarningOverlay
            }
        }
        .navigationBarHidden(true)
        .statusBar(hidden: !showControls)
        .onChange(of: session.needsRestart) { needs in
            if needs {
                performRestart()
            }
        }
        .onDisappear {
            session.stop()
        }
    }
    
    private var controlsOverlay: some View {
        VStack {
            HStack {
                Button(action: {
                    session.stop()
                    presentationMode.wrappedValue.dismiss()
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
                
                // Restart countdown
                if session.secondsRemaining > 0 {
                    Text(formatTime(session.secondsRemaining))
                        .font(.caption)
                        .foregroundColor(.white)
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
            
            Text("Restarting stream...")
                .font(.headline)
                .foregroundColor(.white)
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
    
    private func performRestart() {
        isRestarting = true
        
        // Stop current session
        session.stop()
        
        // Wait for cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            // Start new session
            _ = session.start()
            isRestarting = false
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
        // Cleanup is handled by StreamSession
    }
    
    func makeCoordinator() -> Coordinator {
        return Coordinator()
    }
    
    class Coordinator: NSObject {
        // Empty - session handles everything
    }
}