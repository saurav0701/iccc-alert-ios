import SwiftUI
import WebKit 

struct FullscreenPlayerEnhanced: View {
    let camera: Camera
    @Environment(\.presentationMode) var presentationMode
    
    @StateObject private var session: StreamSession
    @StateObject private var memoryMonitor = MemoryMonitor.shared
    
    @State private var showControls = true
    @State private var isRestarting = false
    @State private var showCrashWarning = false
    @State private var showEmergencyStop = false
    @State private var emergencyMessage = ""
    
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
            
            if showEmergencyStop {
                emergencyStopView
            } else if isRestarting {
                restartingView
            } else {
                WebRTCPlayerEnhanced(session: session)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation { showControls.toggle() }
                    }
            }
            
            if showControls && !showEmergencyStop {
                controlsOverlay
            }
            
            if (memoryMonitor.isMemoryWarning || showCrashWarning) && !showEmergencyStop {
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
        .onChange(of: memoryMonitor.currentMemoryMB) { memoryMB in
            handleMemoryChange(memoryMB)
        }
        .onChange(of: session.isActive) { active in
            // ✅ NEW: Notify memory monitor of streaming state
            MemoryMonitor.shared.setStreamingActive(active)
            
            // If session becomes inactive without restart, it's an emergency stop
            if !active && !session.needsRestart && !isRestarting {
                showEmergencyStopScreen()
            }
        }
        .onAppear {
            DebugLogger.shared.log("📹 Player appeared: \(camera.displayName)", emoji: "📹", color: .blue)
            
            // ✅ NEW: Notify that streaming started
            NotificationCenter.default.post(name: NSNotification.Name("StreamingStarted"), object: nil)
            MemoryMonitor.shared.setStreamingActive(true)
        }
        .onDisappear {
            handleDisappear()
        }
    }
    
    private func handleMemoryChange(_ memoryMB: Double) {
        // ✅ FIXED: More conservative thresholds for low-RAM devices
        // Critical threshold (200MB for streaming) - show urgent warning
        if memoryMB > 200 {
            DebugLogger.shared.log("🚨 CRITICAL MEMORY: \(String(format: "%.1f", memoryMB))MB", emoji: "🚨", color: .red)
            showCrashWarning = true
            
            // Emergency restart after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if self.memoryMonitor.currentMemoryMB > 200 {
                    self.showEmergencyStopScreen()
                }
            }
        }
        // Warning threshold (170MB) - show warning, trigger restart
        else if memoryMB > 170 {
            DebugLogger.shared.log("⚠️ High memory: \(String(format: "%.1f", memoryMB))MB - Restart", emoji: "⚠️", color: .orange)
            showCrashWarning = true
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                if self.memoryMonitor.currentMemoryMB > 170 {
                    self.performRestart()
                    self.showCrashWarning = false
                }
            }
        }
        else {
            showCrashWarning = false
        }
    }
    
    private func showEmergencyStopScreen() {
        DebugLogger.shared.log("🚨 EMERGENCY STOP TRIGGERED", emoji: "🚨", color: .red)
        
        emergencyMessage = "Memory usage reached critical levels (\(Int(memoryMonitor.currentMemoryMB))MB). Stream stopped to prevent crash."
        showEmergencyStop = true
        
        // Force cleanup
        session.stop()
        
        // Aggressive memory cleanup
        for _ in 0..<5 {
            autoreleasepool {}
        }
        URLCache.shared.removeAllCachedResponses()
        
        // Auto-dismiss after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            self.presentationMode.wrappedValue.dismiss()
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
                        
                        // Memory indicator with color coding
                        let memMB = Int(memoryMonitor.currentMemoryMB)
                        let memColor: Color = {
                            if memMB > 200 { return .red }
                            else if memMB > 170 { return .orange }
                            else if memMB > 140 { return .yellow }
                            else { return .white.opacity(0.6) }
                        }()
                        
                        Text("\(memMB)MB")
                            .font(.caption2)
                            .foregroundColor(memColor)
                            .fontWeight(memMB > 170 ? .bold : .regular)
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
            
            Text("Memory: \(Int(memoryMonitor.currentMemoryMB))MB")
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
            
            Text("This prevents crashes on low memory devices")
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
        }
    }
    
    private var emergencyStopView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.2))
                    .frame(width: 100, height: 100)
                
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.red)
            }
            
            Text("Emergency Stop")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text(emergencyMessage)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            
            Text("Returning to camera list...")
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))
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
                    
                    if showCrashWarning {
                        Text("Auto-refreshing...")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.9))
                    }
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
        guard !isRestarting else { return }
        
        DebugLogger.shared.log("🔄 Performing restart", emoji: "🔄", color: .orange)
        
        isRestarting = true
        
        // Stop current session
        session.stop()
        
        // Wait 3 seconds for complete cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            // Force aggressive memory cleanup
            for _ in 0..<5 {
                autoreleasepool {}
            }
            
            URLCache.shared.removeAllCachedResponses()
            
            // Check memory before restart
            let currentMem = self.memoryMonitor.currentMemoryMB
            DebugLogger.shared.log("📊 Pre-restart memory: \(String(format: "%.1f", currentMem))MB", emoji: "📊", color: .blue)
            
            if currentMem > 190 {
                // Too high to restart safely
                self.showEmergencyStopScreen()
                return
            }
            
            // Start new session
            _ = self.session.start()
            self.isRestarting = false
            
            DebugLogger.shared.log("✅ Restart complete", emoji: "✅", color: .green)
        }
    }
    
    private func handleDisappear() {
        DebugLogger.shared.log("🚪 Player disappeared - cleanup", emoji: "🚪", color: .orange)
        
        // ✅ NEW: Notify that streaming stopped
        NotificationCenter.default.post(name: NSNotification.Name("StreamingStopped"), object: nil)
        MemoryMonitor.shared.setStreamingActive(false)
        
        session.stop()
        
        // Aggressive cleanup on dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            for _ in 0..<5 {
                autoreleasepool {}
            }
            
            URLCache.shared.removeAllCachedResponses()
            
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