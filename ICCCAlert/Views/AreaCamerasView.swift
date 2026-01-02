import SwiftUI

struct AreaCamerasView: View {
    let area: String
    @StateObject private var cameraManager = CameraManager.shared
    @StateObject private var thumbnailCache = ThumbnailCacheManager.shared
    @State private var searchText = ""
    @State private var showOnlineOnly = true
    @State private var gridMode: GridViewMode = .grid2x2
    @State private var selectedCamera: Camera? = nil
    @State private var showStreamBlockedAlert = false
    @State private var streamBlockMessage = ""
    @State private var canOpenStream = true
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
    FullscreenPlayerNative(camera: camera)
        .onDisappear {
            // CRITICAL: Prevent stream opening immediately after close
            canOpenStream = false
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.canOpenStream = true
                DebugLogger.shared.log("✅ Ready for next stream", emoji: "✅", color: .green)
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
            
            // Enhanced info banner
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                    .font(.system(size: 14))
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tap thumbnail to load preview")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fontWeight(.medium)
                    
                    Text("Wait for preview before playing stream (5 second interval)")
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
        
        // CRITICAL: Check if we can open stream (cooldown after previous stream)
        if !canOpenStream {
            streamBlockMessage = "Please wait a moment before opening another stream. This prevents crashes on low memory devices."
            showStreamBlockedAlert = true
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        
        // CRITICAL: Check if thumbnail is being captured
        if thumbnailCache.isLoading(for: camera.id) {
            streamBlockMessage = "Thumbnail capture in progress. Wait a few seconds before playing stream."
            showStreamBlockedAlert = true
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        
        // CRITICAL: Check if ANY thumbnail capture is in progress
        if !thumbnailCache.loadingCameras.isEmpty {
            let loadingCameraIds = thumbnailCache.loadingCameras.joined(separator: ", ")
            DebugLogger.shared.log("⚠️ Thumbnail capture active: \(loadingCameraIds)", emoji: "⚠️", color: .orange)
            
            streamBlockMessage = "Another camera thumbnail is loading. Please wait."
            showStreamBlockedAlert = true
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        
        // Check if other streams are active
        if PlayerManager.shared.getActiveCount() > 0 {
            streamBlockMessage = "Another stream is already playing. Close it first."
            showStreamBlockedAlert = true
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        
        // CRITICAL: Add 2 second delay to ensure any lingering resources are freed
        DebugLogger.shared.log("▶️ Opening player for: \(camera.displayName)", emoji: "▶️", color: .green)
        
        // Disable further taps temporarily
        canOpenStream = false
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.selectedCamera = camera
            
            // Re-enable after another 3 seconds (total 5 second protection)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                self.canOpenStream = true
            }
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