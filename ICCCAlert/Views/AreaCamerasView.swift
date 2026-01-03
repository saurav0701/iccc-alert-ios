import SwiftUI

struct AreaCamerasView: View {
    let area: String
    @StateObject private var cameraManager = CameraManager.shared
    // REMOVED: thumbnailCache - no longer needed
    @State private var searchText = ""
    @State private var showOnlineOnly = true
    @State private var gridMode: GridViewMode = .grid2x2
    @State private var selectedCamera: Camera? = nil
    @State private var showStreamBlockedAlert = false
    @State private var streamBlockMessage = ""
    @State private var canOpenStream = true
    @State private var currentMemory: Double = 0
    @Environment(\.scenePhase) var scenePhase
    
    var cameras: [Camera] {
        var result = cameraManager.getCameras(forArea: area)
        if showOnlineOnly { result = result.filter { $0.isOnline } }
        if !searchText.isEmpty {
            result = result.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchText) ||
                $0.location.localizedCaseInsensitiveContains(searchText)
            }
        }
        return result.sorted { $0.displayName < $1.displayName }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Memory indicator
            memoryIndicator
            
            statsBar
            filterBar
            
            cameras.isEmpty ? AnyView(emptyView) : AnyView(cameraGridView)
        }
        .navigationTitle(area)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarItems(trailing:
            Menu {
                Picker("Layout", selection: $gridMode) {
                    ForEach(GridViewMode.allCases) { mode in
                        Label(mode.rawValue, systemImage: mode.icon).tag(mode)
                    }
                }
            } label: {
                Image(systemName: gridMode.icon).font(.system(size: 18))
            }
        )
        .fullScreenCover(item: $selectedCamera) { camera in
            FullscreenPlayerEnhanced(camera: camera)
                .onDisappear {
                    canOpenStream = false
                    
                    DebugLogger.shared.log("🧹 Stream closed - cleanup", emoji: "🧹", color: .orange)
                    
                    // Aggressive cleanup after stream
                    PlayerManager.shared.clearAll()
                    URLCache.shared.removeAllCachedResponses()
                    
                    for _ in 0..<5 {
                        autoreleasepool {}
                    }
                    
                    // Check memory after cleanup
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.checkMemory()
                        
                        let memAfterCleanup = self.currentMemory
                        DebugLogger.shared.log("📊 Memory after cleanup: \(String(format: "%.1f", memAfterCleanup))MB", emoji: "📊", color: .blue)
                    }
                    
                    // Longer cooldown (5 seconds)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                        self.canOpenStream = true
                        DebugLogger.shared.log("✅ Ready for next stream", emoji: "✅", color: .green)
                    }
                }
        }
        .alert(isPresented: $showStreamBlockedAlert) {
            Alert(
                title: Text("Cannot Open Stream"),
                message: Text(streamBlockMessage),
                dismissButton: .default(Text("OK"))
            )
        }
        .onAppear {
            DebugLogger.shared.log("📹 AreaCamerasView appeared: \(area)", emoji: "📹", color: .blue)
            checkMemory()
            
            let initialMem = currentMemory
            DebugLogger.shared.log("📊 Initial memory: \(String(format: "%.1f", initialMem))MB", emoji: "📊", color: .blue)
            
            // Start memory monitoring (every 3 seconds)
            Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
                checkMemory()
            }
        }
        .onDisappear {
            DebugLogger.shared.log("🚪 AreaCamerasView disappeared", emoji: "🚪", color: .orange)
            PlayerManager.shared.clearAll()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                PlayerManager.shared.clearAll()
            }
        }
        .onChange(of: gridMode) { _ in
            PlayerManager.shared.clearAll()
        }
    }
    
    private var memoryIndicator: some View {
        HStack {
            Image(systemName: "memorychip")
                .font(.system(size: 14))
                .foregroundColor(memoryColor)
            
            Text("\(Int(currentMemory)) MB")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(memoryColor)
            
            if currentMemory > 80 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.red)
            }
            
            Spacer()
            
            if currentMemory > 80 {
                Button("Clear Cache") {
                    performMemoryCleanup()
                }
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.orange)
                .foregroundColor(.white)
                .cornerRadius(6)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(memoryColor.opacity(0.1))
    }
    
    private var memoryColor: Color {
        if currentMemory > 100 { return .red }
        if currentMemory > 80 { return .orange }
        if currentMemory > 60 { return .yellow }
        return .green
    }
    
    private func checkMemory() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_,
                         task_flavor_t(MACH_TASK_BASIC_INFO),
                         $0,
                         &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            let newMemory = Double(info.resident_size) / 1024 / 1024
            
            DispatchQueue.main.async {
                self.currentMemory = newMemory
            }
            
            // Auto cleanup if too high
            if newMemory > 100 {
                DebugLogger.shared.log("🚨 AUTO CLEANUP at \(String(format: "%.1f", newMemory))MB", emoji: "🚨", color: .red)
                performMemoryCleanup()
            }
        }
    }
    
    private func performMemoryCleanup() {
        DebugLogger.shared.log("🧹 Manual memory cleanup", emoji: "🧹", color: .orange)
        
        let beforeMem = currentMemory
        
        // Stop all players
        PlayerManager.shared.clearAll()
        
        // Clear event images
        EventImageLoader.shared.clearCache()
        
        // Clear URL cache
        URLCache.shared.removeAllCachedResponses()
        
        // Force GC (10 cycles)
        for _ in 0..<10 {
            autoreleasepool {}
        }
        
        // Recheck after cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            checkMemory()
            let afterMem = self.currentMemory
            let saved = beforeMem - afterMem
            DebugLogger.shared.log("📊 Cleanup freed: \(String(format: "%.1f", saved))MB (\(String(format: "%.1f", beforeMem))MB → \(String(format: "%.1f", afterMem))MB)", emoji: "📊", color: .green)
        }
    }
    
    private var statsBar: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "video.fill").foregroundColor(.blue)
                Text("\(cameras.count) camera\(cameras.count == 1 ? "" : "s")")
                    .font(.subheadline).fontWeight(.medium)
            }
            Spacer()
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text("\(cameras.filter { $0.isOnline }.count)").font(.subheadline).foregroundColor(.secondary)
                }
                HStack(spacing: 4) {
                    Circle().fill(Color.gray).frame(width: 8, height: 8)
                    Text("\(cameras.filter { !$0.isOnline }.count)").font(.subheadline).foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .shadow(color: Color.black.opacity(0.05), radius: 2, y: 2)
    }
    
    private var filterBar: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.gray)
                TextField("Search cameras...", text: $searchText).textFieldStyle(PlainTextFieldStyle())
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.gray)
                    }
                }
            }
            .padding(12).background(Color(.systemGray6)).cornerRadius(10).padding(.horizontal)
            
            HStack {
                Toggle(isOn: $showOnlineOnly) {
                    HStack(spacing: 8) {
                        Image(systemName: showOnlineOnly ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(showOnlineOnly ? .green : .gray)
                        Text("Show Online Only").font(.subheadline)
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: .green))
                .onChange(of: showOnlineOnly) { _ in
                    PlayerManager.shared.clearAll()
                }
            }
            .padding(.horizontal)
            
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                    .font(.system(size: 14))
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("🎥 NO thumbnails - Tap camera icon to stream")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fontWeight(.medium)
                    
                    Text("Streams auto-refresh every 90s • Max 1 stream at a time")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.blue.opacity(0.05))
            .cornerRadius(8)
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
    }
    
    private var cameraGridView: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: gridMode.columns), spacing: 12) {
                ForEach(cameras, id: \.id) { camera in
                    CameraGridCardFixed(camera: camera, mode: gridMode)
                        .onTapGesture {
                            handleCameraTap(camera)
                        }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }
    
    private func handleCameraTap(_ camera: Camera) {
        guard camera.isOnline else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        
        // CRITICAL: Check memory BEFORE opening stream
        checkMemory()
        
        DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "📹", color: .blue)
        DebugLogger.shared.log("🎬 User tapped: \(camera.displayName)", emoji: "🎬", color: .blue)
        DebugLogger.shared.log("📊 Current memory: \(String(format: "%.1f", currentMemory))MB", emoji: "📊", color: .blue)
        
        if currentMemory > 90 {
            streamBlockMessage = "Memory too high (\(Int(currentMemory))MB). Tap 'Clear Cache' first."
            showStreamBlockedAlert = true
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            DebugLogger.shared.log("🚫 BLOCKED: Memory too high", emoji: "🚫", color: .red)
            return
        }
        
        if !canOpenStream {
            streamBlockMessage = "Please wait 5 seconds before opening another stream."
            showStreamBlockedAlert = true
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            DebugLogger.shared.log("🚫 BLOCKED: Cooldown active", emoji: "🚫", color: .orange)
            return
        }
        
        if PlayerManager.shared.getActiveCount() > 0 {
            streamBlockMessage = "Another stream is already playing. Close it first."
            showStreamBlockedAlert = true
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            DebugLogger.shared.log("🚫 BLOCKED: Stream already active", emoji: "🚫", color: .orange)
            return
        }
        
        DebugLogger.shared.log("✅ Opening stream...", emoji: "✅", color: .green)
        DebugLogger.shared.log("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", emoji: "📹", color: .blue)
        
        canOpenStream = false
        
        // Small delay to ensure UI is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.selectedCamera = camera
        }
    }
    
    private var emptyView: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle().fill(Color.gray.opacity(0.1)).frame(width: 100, height: 100)
                Image(systemName: searchText.isEmpty ? "video.slash" : "magnifyingglass")
                    .font(.system(size: 50)).foregroundColor(.gray)
            }
            Text(searchText.isEmpty ? "No Cameras" : "No Results").font(.title2).fontWeight(.bold)
            Text(searchText.isEmpty ? (showOnlineOnly ? "No online cameras" : "No cameras found") : "No matches")
                .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}